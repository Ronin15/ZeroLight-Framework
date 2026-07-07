// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! SDL_GPU renderer facade for app/game code.
//! CPU render prep happens before swapchain acquisition; the acquired section
//! stays limited to upload, render-pass encoding, and command submission.
//! TextureId values are generational handles backed by renderer-owned slots.

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const LoadedImage = @import("../assets/image.zig").LoadedImage;
const build_options = @import("build_options");
const Camera2D = @import("camera.zig").Camera2D;
const config = @import("../config.zig");
const logging = @import("../core/logging.zig");
const log = logging.render;
const gpu_buffer = @import("gpu/buffer.zig");
const gpu_device = @import("gpu/device.zig");
const gpu_pipeline = @import("gpu/sprite_pipeline.zig");
const gpu_tilemap = @import("gpu/tilemap_pipeline.zig");
const gpu_texture = @import("gpu/texture.zig");
const resources = @import("resources.zig");
const resolution = @import("../app/resolution.zig");
const sdl = @import("../platform/sdl.zig");
const sprite_batch = @import("sprite_batch.zig");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const c = sdl.c;

const initial_batch_vertices = 4096 * 6;
const initial_batch_commands = initial_batch_vertices / 6;

pub const TextureId = resources.TextureId;
pub const Rect = sprite_batch.Rect;
pub const CoordinateSpace = sprite_batch.CoordinateSpace;
pub const RenderDomain = sprite_batch.RenderDomain;
pub const RenderOrder = sprite_batch.RenderOrder;
pub const UiDepth = sprite_batch.UiDepth;
pub const UiStackOrder = sprite_batch.UiStackOrder;
pub const DebugDepth = sprite_batch.DebugDepth;
pub const Sprite = sprite_batch.Sprite;
pub const SpritePrepStats = sprite_batch.SpritePrepStats;
// Re-exported so world/render-prep code can build retained static vertices
// without importing the render/gpu boundary.
pub const Position = sprite_batch.Position;
pub const Uv = sprite_batch.Uv;
pub const VertexColor = sprite_batch.VertexColor;
pub const VertexColumns = sprite_batch.VertexColumns;
pub const VertexColumnsConst = sprite_batch.VertexColumnsConst;
pub const writeWorldSpriteQuad = sprite_batch.writeWorldSpriteQuad;
const DrawGroup = sprite_batch.DrawGroup;
const DrawSource = sprite_batch.DrawSource;
const Material = sprite_batch.Material;
pub const TilemapParams = sprite_batch.TilemapParams;
const CoordinatePresentation = sprite_batch.CoordinatePresentation;

pub const FrameResult = enum {
    submitted,
    skipped_no_swapchain,
};

pub const TileDataId = resources.TileDataId;

/// One queued tile-data cell edit: write `value` at `element_index` of the layer
/// buffer `buffer`. Game code accumulates these on tile changes and flushes them
/// to the GPU once per frame at the render boundary.
pub const TileDataEdit = struct {
    buffer: TileDataId,
    element_index: usize,
    value: u32,
};

// One GPU vertex buffer + its upload transfer buffer per SoA column. The three
// buffers are bound together at slots 0/1/2 (Position/Uv/VertexColor); they grow,
// stage, and release as a unit so their capacities never diverge.
const VertexStreams = struct {
    position: *c.SDL_GPUBuffer,
    uv: *c.SDL_GPUBuffer,
    color: *c.SDL_GPUBuffer,
    position_transfer: *c.SDL_GPUTransferBuffer,
    uv_transfer: *c.SDL_GPUTransferBuffer,
    color_transfer: *c.SDL_GPUTransferBuffer,
    position_bytes: u32,
    uv_bytes: u32,
    color_bytes: u32,
};

// Creates the three column buffers + three transfer buffers for `vertex_capacity`
// vertices. Each create has its own errdefer so a mid-sequence failure releases
// the partially built set.
fn createVertexStreams(device: *c.SDL_GPUDevice, vertex_capacity: usize) !VertexStreams {
    const position_bytes = try gpu_buffer.columnBytes(vertex_capacity, @sizeOf(Position));
    const uv_bytes = try gpu_buffer.columnBytes(vertex_capacity, @sizeOf(Uv));
    const color_bytes = try gpu_buffer.columnBytes(vertex_capacity, @sizeOf(VertexColor));

    const position = try gpu_buffer.createVertexBuffer(device, position_bytes);
    errdefer c.SDL_ReleaseGPUBuffer(device, position);
    const uv = try gpu_buffer.createVertexBuffer(device, uv_bytes);
    errdefer c.SDL_ReleaseGPUBuffer(device, uv);
    const color = try gpu_buffer.createVertexBuffer(device, color_bytes);
    errdefer c.SDL_ReleaseGPUBuffer(device, color);

    const position_transfer = try gpu_buffer.createVertexTransferBuffer(device, position_bytes);
    errdefer c.SDL_ReleaseGPUTransferBuffer(device, position_transfer);
    const uv_transfer = try gpu_buffer.createVertexTransferBuffer(device, uv_bytes);
    errdefer c.SDL_ReleaseGPUTransferBuffer(device, uv_transfer);
    const color_transfer = try gpu_buffer.createVertexTransferBuffer(device, color_bytes);
    errdefer c.SDL_ReleaseGPUTransferBuffer(device, color_transfer);

    return .{
        .position = position,
        .uv = uv,
        .color = color,
        .position_transfer = position_transfer,
        .uv_transfer = uv_transfer,
        .color_transfer = color_transfer,
        .position_bytes = position_bytes,
        .uv_bytes = uv_bytes,
        .color_bytes = color_bytes,
    };
}

fn releaseVertexStreams(device: *c.SDL_GPUDevice, streams: VertexStreams) void {
    c.SDL_ReleaseGPUTransferBuffer(device, streams.position_transfer);
    c.SDL_ReleaseGPUTransferBuffer(device, streams.uv_transfer);
    c.SDL_ReleaseGPUTransferBuffer(device, streams.color_transfer);
    c.SDL_ReleaseGPUBuffer(device, streams.position);
    c.SDL_ReleaseGPUBuffer(device, streams.uv);
    c.SDL_ReleaseGPUBuffer(device, streams.color);
}

pub const Renderer = struct {
    /// Headroom reserved for debug-overlay sprite commands submitted after
    /// game-state render enqueue (FPS prefix + digit glyphs). `Engine` adds this
    /// on top of gameplay reservation after all stacked states render.
    pub const kOverlayCommandHeadroom: usize = 16;

    /// Headroom for stacked-state UI rects/text submitted after gameplay enqueue
    /// (pause panel, menus) before the debug overlay reserve in `Engine`.
    pub const kStackedStateUiHeadroom: usize = 32;

    // `Engine`'s post-render top-up (`spriteCommandCount() + kOverlayCommandHeadroom`)
    // reserves against the same grow-only `command_high_water` as the state's own
    // upfront reserve, without the caller re-adding `kStackedStateUiHeadroom`. This
    // stays allocation-free only because `std.ArrayList.ensureTotalCapacity`'s
    // amortized growth on the state's reserve already covers the extra headroom,
    // which requires stacked-UI headroom to be at least double the overlay headroom.
    // See "engine overlay top-up after stacked UI fully consumes its headroom stays
    // allocation-free" for the empirical proof this depends on too.
    comptime {
        std.debug.assert(kStackedStateUiHeadroom >= 2 * kOverlayCommandHeadroom);
    }

    /// Upper bound on composited layers in one tilemap draw's window. Tied to
    /// `world_system.zig`'s `k_max_dense_submit_stack_cap` by a comptime assert in
    /// that file (which already imports this module, so the assert lives there
    /// to avoid an import cycle).
    pub const k_max_tilemap_window_layers: usize = 32;

    /// Cap on separate tilemap composite draw calls in one frame. In the
    /// shipped default config this always resolves to 1 (only the active
    /// level's own actor depth is ever an interleave point); more buckets only
    /// appear when something (a sparse tile, a dynamic depth) needs to render
    /// sandwiched between two dense layers this frame. Sized to the
    /// mathematically-proven worst case rather than a defensive guess:
    /// `partitionDenseCompositeBuckets` can never produce more buckets than
    /// submitted dense layers, which `world_system.zig` already hard-caps at
    /// `k_max_dense_submit_stack_cap` — tied to that constant by a comptime
    /// assert in that file (which already imports this module, avoiding an
    /// import cycle).
    pub const k_max_dense_composite_draws: usize = 32;

    /// One tilemap draw's composited layer window: up to
    /// `k_max_tilemap_window_layers` element offsets into a combined tile-data
    /// buffer, topmost layer first. The fragment shader walks these in order and
    /// stops at the first opaque cell.
    pub const TilemapWindowLayers = struct {
        count: u8 = 0,
        offsets: [k_max_tilemap_window_layers]u32 = @splat(0),
    };

    /// Fills `params.layer_meta`/`layer_offsets` from `window` right before the
    /// fragment uniform push. Pure and GPU-free so it is unit-testable headlessly.
    pub fn applyWindowLayers(params: *TilemapParams, window: TilemapWindowLayers) void {
        std.debug.assert(window.count <= k_max_tilemap_window_layers);
        params.layer_meta[0] = @intCast(window.count);
        for (0..window.count) |i| {
            params.layer_offsets[i] = window.offsets[i];
        }
    }

    allocator: std.mem.Allocator,
    device: *c.SDL_GPUDevice,
    window: *c.SDL_Window,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    tilemap_pipeline: *c.SDL_GPUGraphicsPipeline,
    sampler: *c.SDL_GPUSampler,
    vertex_streams: VertexStreams,
    batch_capacity_vertices: usize,
    texture_slots: std.ArrayList(TextureSlot) = .empty,
    // GPU-driven tilemap tile-data: one graphics-storage-read buffer per dense
    // layer (a row-major copy of the world's dense_tile_ids). Renderer-owned so
    // world keeps only opaque handles and never crosses the render/gpu boundary.
    tile_data_buffers: std.ArrayList(*c.SDL_GPUBuffer) = .empty,
    // World-constant grid/atlas uniform per tile-data buffer (parallel to
    // tile_data_buffers). Kept here rather than on each DrawGroup so the per-frame
    // draw-group sort/coalesce/merge stays small.
    tile_data_params: std.ArrayList(TilemapParams) = .empty,
    // Cell count per tile-data buffer (parallel to tile_data_buffers) so the
    // dig-edit upload boundary can reject an out-of-range element_index before it
    // becomes an out-of-bounds GPU buffer write.
    tile_data_counts: std.ArrayList(u32) = .empty,
    // Grow-only scratch resolving queued tile-data edits (handles) to GPU buffers
    // for one batched dig upload per frame.
    tile_edit_scratch: std.ArrayList(gpu_buffer.StorageRegion) = .empty,
    tile_edit_transfer: ?*c.SDL_GPUTransferBuffer = null,
    tile_edit_transfer_byte_size: u32 = 0,
    tile_edits_pending: bool = false,
    batch: sprite_batch.SpriteBatch,
    white_texture: TextureId = TextureId.invalid,
    first_free_texture_slot: ?u32 = null,
    resolution_policy: resolution.ResolutionPolicy = .{},
    current_presentation: ?resolution.Presentation = null,
    last_logged_presentation: ?resolution.Presentation = null,
    clear_color: config.Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    viewport_width: u32 = 0,
    viewport_height: u32 = 0,
    window_claimed: bool = true,
    // Retained static world geometry: world-space vertices uploaded once and
    // re-uploaded only when `static_dirty` (visible set change, dig/build). The
    // GPU buffer persists across frames; the per-frame draw list interleaves
    // these spans with the dynamic batch by render order.
    static_streams: ?VertexStreams = null,
    static_capacity_vertices: usize = 0,
    static_positions: std.ArrayListUnmanaged(Position) = .empty,
    static_uvs: std.ArrayListUnmanaged(Uv) = .empty,
    static_colors: std.ArrayListUnmanaged(VertexColor) = .empty,
    static_groups: std.ArrayListUnmanaged(DrawGroup) = .empty,
    static_dirty: bool = false,
    // Per-frame side table for tilemap DrawGroup.window_slot: which composited
    // layer offsets each static tilemap span reads this frame. Reset by
    // beginStaticGeometry; populated by appendStaticTilemapSpan.
    tilemap_window_layers: [k_max_dense_composite_draws]TilemapWindowLayers = undefined,
    tilemap_window_layer_count: usize = 0,
    draw_list: std.ArrayListUnmanaged(DrawGroup) = .empty,
    // Reserved upper bounds feeding the merged draw list. `draw_list` is sized to
    // their sum so the per-frame merge stays allocation-free.
    reserved_dynamic_groups: usize = 0,
    reserved_static_spans: usize = 0,
    // Grow-only peaks observed by `reserveSpriteCommands` / draw-list reservation.
    command_high_water: usize = 0,
    draw_list_high_water: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        window: *c.SDL_Window,
        assets: AssetStore,
        app_config: config.AppConfig,
    ) !Renderer {
        try validateConfig(app_config);

        const device = try gpu_device.createDevice(@intCast(build_options.gpu_shader_formats), app_config.gpu_debug);
        errdefer c.SDL_DestroyGPUDevice(device);

        try gpu_device.claimWindow(device, window);
        errdefer c.SDL_ReleaseWindowFromGPUDevice(device, window);

        try gpu_device.configureSwapchain(device, window, app_config);

        const sampler = gpu_device.createSampler(device) catch |err| {
            return err;
        };
        errdefer c.SDL_ReleaseGPUSampler(device, sampler);

        const vertex_streams = try createVertexStreams(device, initial_batch_vertices);
        errdefer releaseVertexStreams(device, vertex_streams);

        const target_format = c.SDL_GetGPUSwapchainTextureFormat(device, window);
        const shader_set = try gpu_pipeline.selectShaderSet(device, @intCast(build_options.gpu_shader_formats));
        log.debug("selected SDL_GPU shader set: format={s} vertex=\"{s}\" fragment=\"{s}\"", .{
            gpu_pipeline.shaderFormatName(shader_set.format),
            shader_set.vertex_path,
            shader_set.fragment_path,
        });
        const pipeline = try gpu_pipeline.createSpritePipeline(allocator, device, assets, target_format, shader_set);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

        const tilemap_pipeline = try gpu_tilemap.createTilemapPipeline(
            allocator,
            device,
            assets,
            target_format,
            gpu_tilemap.shaderSetForFormat(shader_set.format),
        );
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, tilemap_pipeline);

        var renderer = Renderer{
            .allocator = allocator,
            .device = device,
            .window = window,
            .pipeline = pipeline,
            .tilemap_pipeline = tilemap_pipeline,
            .sampler = sampler,
            .vertex_streams = vertex_streams,
            .batch_capacity_vertices = initial_batch_vertices,
            .batch = sprite_batch.SpriteBatch.init(allocator),
            .resolution_policy = app_config.resolution_policy,
        };
        try renderer.reserveBatchStorage(initial_batch_commands, initial_batch_vertices, initial_batch_commands);
        errdefer renderer.deinitBatchStorage();

        const white_pixel = [_]u8{ 255, 255, 255, 255 };
        renderer.white_texture = try renderer.createInternalTextureFromPixels(white_pixel[0..], 1, 1, gpu_texture.bytes_per_pixel);
        return renderer;
    }

    pub fn deinit(self: *Renderer) void {
        self.waitForIdle();

        for (self.texture_slots.items) |slot| {
            if (slot.alive) {
                c.SDL_ReleaseGPUTexture(self.device, slot.texture.?);
            }
        }
        self.texture_slots.deinit(self.allocator);
        for (self.tile_data_buffers.items) |buffer| {
            c.SDL_ReleaseGPUBuffer(self.device, buffer);
        }
        self.tile_data_buffers.deinit(self.allocator);
        self.tile_data_params.deinit(self.allocator);
        self.tile_data_counts.deinit(self.allocator);
        self.tile_edit_scratch.deinit(self.allocator);
        if (self.tile_edit_transfer) |transfer| {
            c.SDL_ReleaseGPUTransferBuffer(self.device, transfer);
            self.tile_edit_transfer = null;
        }
        self.deinitBatchStorage();
        self.static_positions.deinit(self.allocator);
        self.static_uvs.deinit(self.allocator);
        self.static_colors.deinit(self.allocator);
        self.static_groups.deinit(self.allocator);
        self.draw_list.deinit(self.allocator);
        if (self.static_streams) |streams| releaseVertexStreams(self.device, streams);

        releaseVertexStreams(self.device, self.vertex_streams);
        c.SDL_ReleaseGPUSampler(self.device, self.sampler);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.tilemap_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline);
        if (self.window_claimed) {
            c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);
            self.window_claimed = false;
        }
        c.SDL_DestroyGPUDevice(self.device);
    }

    pub fn waitForIdle(self: *Renderer) void {
        _ = c.SDL_WaitForGPUIdle(self.device);
    }

    pub fn beginFrame(self: *Renderer, clear_color: config.Color) void {
        self.batch.beginFrame();
        self.clear_color = clear_color;
    }

    pub fn submitOrderedSprite(self: *Renderer, sprite: Sprite) !void {
        try self.batch.drawSprite(sprite);
    }

    /// Grows batch storage to hold `command_capacity` ordered sprite commands.
    /// Setup-time and grow-only (never shrinks); call before relying on
    /// allocation-free render frames.
    pub fn reserveSpriteCommands(self: *Renderer, command_capacity: usize) !void {
        if (command_capacity > self.command_high_water) {
            const vertex_capacity = try std.math.mul(usize, command_capacity, 6);
            try self.reserveBatchStorage(command_capacity, vertex_capacity, command_capacity);
            // CPU-only test renderers leave `batch_capacity_vertices` at 0; GPU
            // streams grow at `ensureFrameBatchCapacity` on the first real frame.
            if (self.batch_capacity_vertices > 0) {
                try self.ensureBatchCapacity(vertex_capacity);
            }
            self.command_high_water = command_capacity;
            self.reserved_dynamic_groups = command_capacity;
            try self.ensureDrawListReservation();
        }
        self.batch.frame_reserved = true;
    }

    pub fn spriteCommandCount(self: *const Renderer) usize {
        return self.batch.commands.items.len;
    }

    pub fn submitOrderedRectInSpace(self: *Renderer, rect: Rect, color: config.Color, order: RenderOrder, coordinate_space: CoordinateSpace) !void {
        try self.submitOrderedSprite(.{
            .texture = self.white_texture,
            .dest = rect,
            .tint = color,
            .order = order,
            .coordinate_space = coordinate_space,
        });
    }

    pub fn setCamera(self: *Renderer, camera: Camera2D) void {
        self.batch.setCamera(camera);
    }

    /// Begins replacing the retained static geometry for this and following
    /// frames. Producers call this only when the static set changes (visible set
    /// change, dig/build), then append spans; the buffer re-uploads once. When
    /// not called, the existing static geometry persists and is reused.
    pub fn beginStaticGeometry(self: *Renderer) void {
        self.static_positions.clearRetainingCapacity();
        self.static_uvs.clearRetainingCapacity();
        self.static_colors.clearRetainingCapacity();
        self.static_groups.clearRetainingCapacity();
        self.tilemap_window_layer_count = 0;
        self.static_dirty = true;
    }

    /// Reserves retained static storage. Setup/grow-only; call before relying on
    /// allocation-free static rebuilds.
    pub fn reserveStaticGeometry(self: *Renderer, vertex_capacity: usize, span_capacity: usize) !void {
        try self.static_positions.ensureTotalCapacity(self.allocator, vertex_capacity);
        try self.static_uvs.ensureTotalCapacity(self.allocator, vertex_capacity);
        try self.static_colors.ensureTotalCapacity(self.allocator, vertex_capacity);
        try self.static_groups.ensureTotalCapacity(self.allocator, span_capacity);
        self.reserved_static_spans = span_capacity;
        try self.ensureDrawListReservation();
    }

    // Sizes the merged draw list to the combined dynamic + static span budget so
    // the per-frame `mergeDrawList` never reallocates.
    fn ensureDrawListReservation(self: *Renderer) !void {
        const total = try std.math.add(usize, self.reserved_dynamic_groups, self.reserved_static_spans);
        if (total <= self.draw_list_high_water) return;
        try self.draw_list.ensureTotalCapacity(self.allocator, total);
        self.draw_list_high_water = total;
    }

    /// Appends one retained world-space quad that composites `window_layers`
    /// (topmost-first offsets into a combined tile-data buffer) via the tilemap
    /// pipeline: the fragment shader walks them per pixel, stopping at the first
    /// opaque cell, and samples `atlas_texture`. `vertices` are the quad's
    /// world-space corners (6). Must be called between `beginStaticGeometry` and
    /// the next `endFrame`. At most `k_max_dense_composite_draws` calls are
    /// allowed between two `beginStaticGeometry` calls.
    pub fn appendStaticTilemapSpan(
        self: *Renderer,
        atlas_texture: TextureId,
        order: RenderOrder,
        vertices: VertexColumnsConst,
        tile_data: TileDataId,
        window_layers: TilemapWindowLayers,
    ) !void {
        const vertex_count = vertices.positions.len;
        std.debug.assert(vertices.uvs.len == vertex_count and vertices.colors.len == vertex_count);
        if (vertex_count == 0) return;
        if (self.tilemap_window_layer_count >= k_max_dense_composite_draws) return error.TooManyTilemapWindowDraws;
        const end = try std.math.add(usize, self.static_positions.items.len, vertex_count);
        const first_vertex = std.math.cast(u32, self.static_positions.items.len) orelse return error.StaticGeometryTooLarge;
        _ = std.math.cast(u32, end) orelse return error.StaticGeometryTooLarge;
        try self.static_positions.appendSlice(self.allocator, vertices.positions);
        try self.static_uvs.appendSlice(self.allocator, vertices.uvs);
        try self.static_colors.appendSlice(self.allocator, vertices.colors);
        const window_slot: u8 = @intCast(self.tilemap_window_layer_count);
        self.tilemap_window_layers[window_slot] = window_layers;
        self.tilemap_window_layer_count += 1;
        try self.static_groups.append(self.allocator, .{
            .source = .static,
            .material = .tilemap,
            .texture = atlas_texture,
            .presentation = .world,
            .order = order,
            .first_vertex = first_vertex,
            .vertex_count = @intCast(vertex_count),
            .tile_data = tile_data,
            .window_slot = window_slot,
        });
        self.static_dirty = true;
    }

    pub fn drawablePixelScale(self: *const Renderer) f32 {
        const presentation = self.current_presentation orelse return 1.0;
        const scale_x = @as(f32, @floatFromInt(presentation.drawable_size.width)) /
            @as(f32, @floatFromInt(presentation.window_size.width));
        const scale_y = @as(f32, @floatFromInt(presentation.drawable_size.height)) /
            @as(f32, @floatFromInt(presentation.window_size.height));
        return @max(1.0, @max(scale_x, scale_y));
    }

    pub fn destroyTexture(self: *Renderer, id: TextureId) void {
        const slot = self.resolveTextureSlot(id) orelse return;
        if (slot.internal) return;

        self.retireTextureSlot(id.index, slot);
    }

    pub fn textureDesc(self: *const Renderer, id: TextureId) ?resources.TextureDesc {
        const slot = self.resolveTextureSlotConst(id) orelse return null;
        return slot.desc;
    }

    fn textureResolver(self: *const Renderer) sprite_batch.TextureResolver {
        return .{
            .context = self,
            .resolve = resolveTextureDescForBatch,
        };
    }

    const AcquiredFrame = struct {
        command_buffer: *c.SDL_GPUCommandBuffer,
        swapchain_texture: *c.SDL_GPUTexture,
        width: u32,
        height: u32,
    };

    /// Acquires a command buffer and swapchain texture, handling the
    /// no-swapchain and zero-size cases internally (canceling, or submitting an
    /// empty frame). Returns null when the frame should be skipped; on success
    /// the caller owns `command_buffer` and records into it. The helper's own
    /// pre-acquisition errdefer is fully resolved before any return, so the
    /// returned command buffer carries no pending cleanup — post-acquisition
    /// error paths are explicit (`finishAcquiredCommandBufferAfterError`).
    /// `recovery` only tunes the log text.
    fn acquireSwapchainFrame(self: *Renderer, recovery: bool) !?AcquiredFrame {
        const command_buffer = c.SDL_AcquireGPUCommandBuffer(self.device) orelse {
            return sdlError("SDL_AcquireGPUCommandBuffer");
        };
        var command_buffer_finished = false;
        var swapchain_acquired = false;
        // Before a swapchain texture is acquired, canceling the command buffer is
        // enough cleanup.
        errdefer if (!command_buffer_finished and !swapchain_acquired) {
            _ = c.SDL_CancelGPUCommandBuffer(command_buffer);
        };

        var swapchain_texture: ?*c.SDL_GPUTexture = null;
        var width: u32 = 0;
        var height: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(command_buffer, self.window, &swapchain_texture, &width, &height)) {
            return sdlError("SDL_WaitAndAcquireGPUSwapchainTexture");
        }

        if (swapchainUnavailable(swapchain_texture)) {
            _ = c.SDL_CancelGPUCommandBuffer(command_buffer);
            command_buffer_finished = true;
            return null;
        }
        const acquired_swapchain_texture = swapchain_texture.?;
        swapchain_acquired = true;

        if (width == 0 or height == 0) {
            if (recovery) {
                log.warn("acquired SDL_GPU swapchain texture with invalid size {}x{} during recovery; submitting empty frame", .{ width, height });
            } else {
                log.warn("acquired SDL_GPU swapchain texture with invalid size {}x{}; submitting empty frame", .{ width, height });
            }
            if (!c.SDL_SubmitGPUCommandBuffer(command_buffer)) {
                command_buffer_finished = true;
                return sdlError("SDL_SubmitGPUCommandBuffer");
            }
            command_buffer_finished = true;
            return null;
        }

        self.viewport_width = width;
        self.viewport_height = height;
        return AcquiredFrame{
            .command_buffer = command_buffer,
            .swapchain_texture = acquired_swapchain_texture,
            .width = width,
            .height = height,
        };
    }

    pub fn endFrame(self: *Renderer, thread_system: ?*ThreadSystem) !FrameResult {
        try self.ensureFrameBatchCapacity();
        const window_size = try self.currentWindowSize();
        // Cheap pre-acquire probe: a zero/invalid drawable means there is no
        // swapchain yet, so skip the frame before doing any prep. Presentation is
        // computed (and logged) exactly once below, from the acquired size, so a
        // single resize does not emit two "presentation changed" debug lines.
        _ = self.currentDrawableSize() catch |err| switch (err) {
            error.InvalidDrawableSize => return .skipped_no_swapchain,
            else => return err,
        };
        // Sorting, texture metadata snapshots, and optional worker vertex prep
        // happen before acquiring the swapchain to keep the acquired window short.
        try self.prepareFrameCommands(thread_system);
        // Unified draw list: retained static spans + dynamic groups, ordered and
        // coalesced. Rebuilt every frame because the dynamic groups change; the
        // static buffer itself only re-uploads when `static_dirty`.
        try mergeDrawList(&self.draw_list, self.allocator, self.static_groups.items, self.batch.draw_groups.items);
        const upload_static = self.static_dirty and self.static_positions.items.len > 0;
        // Staging before swapchain acquisition is safe across frames in flight
        // only because the transfer buffer is mapped with cycle=true (see
        // gpu/buffer.zig): the map rotates to fresh backing storage rather than
        // overwriting bytes a prior frame's copy pass may still reference. The
        // static buffer uses the same cycle=true upload, only when dirty.
        if (self.batch.positions.items.len > 0) {
            try self.stageVertices();
        }
        if (upload_static) {
            try self.stageStaticVertices();
        }

        const frame = try self.acquireSwapchainFrame(false) orelse return .skipped_no_swapchain;
        const command_buffer = frame.command_buffer;
        const acquired_swapchain_texture = frame.swapchain_texture;
        const presentation = self.updatePresentation(window_size, .{
            .width = frame.width,
            .height = frame.height,
        });

        const upload_dynamic = self.batch.positions.items.len > 0;
        const upload_tile_edits = self.tile_edits_pending and self.tile_edit_scratch.items.len > 0;
        if (upload_dynamic or upload_static or upload_tile_edits) {
            self.recordFrameCopyPass(command_buffer, .{
                .dynamic = upload_dynamic,
                .static_vertices = upload_static,
                .tile_edits = upload_tile_edits,
            }) catch {
                return finishAcquiredCommandBufferAfterError(command_buffer, "SDL_BeginGPUCopyPass");
            };
        }
        // The static buffer now holds current data on the GPU; reuse it until the
        // next change marks it dirty again.
        self.static_dirty = false;

        var color_target = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
        color_target.texture = acquired_swapchain_texture;
        color_target.clear_color = .{
            .r = self.clear_color.r,
            .g = self.clear_color.g,
            .b = self.clear_color.b,
            .a = self.clear_color.a,
        };
        color_target.load_op = c.SDL_GPU_LOADOP_CLEAR;
        color_target.store_op = c.SDL_GPU_STOREOP_STORE;

        const render_pass = c.SDL_BeginGPURenderPass(command_buffer, &color_target, 1, null) orelse {
            return finishAcquiredCommandBufferAfterError(command_buffer, "SDL_BeginGPURenderPass");
        };
        if (self.draw_list.items.len > 0) {
            applyDrawableViewport(render_pass, presentation);

            // Bind the pipeline on material change, the source buffer on source
            // change, push the presentation uniform on presentation change, then
            // draw each group in order. Vertex-buffer bindings and pushed uniforms
            // persist across pipeline binds, so both materials share the camera
            // vertex uniform pushed by applyGroupPresentation.
            var active_source: ?DrawSource = null;
            var active_presentation: ?CoordinatePresentation = null;
            var active_material: ?Material = null;
            var active_texture: ?TextureId = null;
            for (self.draw_list.items) |group| {
                const texture = self.resolveTextureSlot(group.texture) orelse continue;
                const streams = switch (group.source) {
                    .dynamic => self.vertex_streams,
                    .static => self.static_streams orelse continue,
                };
                const tile_buffer: ?*c.SDL_GPUBuffer = switch (group.material) {
                    .sprite => null,
                    .tilemap => self.tileDataBuffer(group.tile_data) orelse continue,
                };

                if (active_material == null or active_material.? != group.material) {
                    c.SDL_BindGPUGraphicsPipeline(render_pass, switch (group.material) {
                        .sprite => self.pipeline,
                        .tilemap => self.tilemap_pipeline,
                    });
                    active_material = group.material;
                }

                if (active_source == null or active_source.? != group.source) {
                    // Slot order is correctness-critical: index 0/1/2 must match the
                    // pipeline's buffer_slot 0/1/2 (Position/Uv/VertexColor).
                    var bindings = [_]c.SDL_GPUBufferBinding{
                        .{ .buffer = streams.position, .offset = 0 },
                        .{ .buffer = streams.uv, .offset = 0 },
                        .{ .buffer = streams.color, .offset = 0 },
                    };
                    c.SDL_BindGPUVertexBuffers(render_pass, 0, &bindings, bindings.len);
                    active_source = group.source;
                }

                if (shouldApplyPresentationState(&active_presentation, group.presentation)) {
                    applyGroupPresentation(render_pass, command_buffer, presentation, group.presentation, self.batch.camera);
                }
                // Bind the texture/sampler only on a real texture change; SDL_GPU
                // keeps the binding across pipeline switches, so consecutive groups
                // sharing a texture skip a redundant bind (matters at many groups).
                // This is only safe because the sprite and tilemap pipelines share
                // the same fragment sampler slot (fragment samplers, first_slot 0);
                // a third material with a different sampler layout must not assume it.
                if (active_texture == null or
                    active_texture.?.index != group.texture.index or
                    active_texture.?.generation != group.texture.generation)
                {
                    var sampler_binding = c.SDL_GPUTextureSamplerBinding{
                        .texture = texture.texture.?,
                        .sampler = self.sampler,
                    };
                    c.SDL_BindGPUFragmentSamplers(render_pass, 0, &sampler_binding, 1);
                    active_texture = group.texture;
                }

                if (group.material == .tilemap) {
                    // Rebind the storage buffer for every tilemap group: on Metal the
                    // storage-buffer slot shifts when the bound pipeline's UBO count
                    // differs, and an unconditional rebind is correct on every backend.
                    var storage = tile_buffer.?;
                    c.SDL_BindGPUFragmentStorageBuffers(render_pass, 0, &storage, 1);
                    var params = self.tileDataParams(group.tile_data);
                    // The per-buffer params carry only the world-constant grid/atlas
                    // geometry; the per-draw composited layer window (which offsets
                    // into a possibly-shared buffer this group reads) is set here.
                    applyWindowLayers(&params, self.tilemap_window_layers[group.window_slot]);
                    c.SDL_PushGPUFragmentUniformData(command_buffer, 0, &params, @sizeOf(TilemapParams));
                }

                c.SDL_DrawGPUPrimitives(render_pass, group.vertex_count, 1, group.first_vertex, 0);
            }
        }

        c.SDL_EndGPURenderPass(render_pass);

        if (!c.SDL_SubmitGPUCommandBuffer(command_buffer)) {
            return sdlError("SDL_SubmitGPUCommandBuffer");
        }
        return .submitted;
    }

    pub fn submitSwapchainRecoveryFrame(self: *Renderer, clear_color: config.Color) !FrameResult {
        self.clear_color = clear_color;
        const window_size = try self.currentWindowSize();
        const frame = try self.acquireSwapchainFrame(true) orelse return .skipped_no_swapchain;
        const command_buffer = frame.command_buffer;
        _ = self.updatePresentation(window_size, .{
            .width = frame.width,
            .height = frame.height,
        });

        var color_target = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
        color_target.texture = frame.swapchain_texture;
        color_target.clear_color = .{
            .r = clear_color.r,
            .g = clear_color.g,
            .b = clear_color.b,
            .a = clear_color.a,
        };
        color_target.load_op = c.SDL_GPU_LOADOP_CLEAR;
        color_target.store_op = c.SDL_GPU_STOREOP_STORE;

        const render_pass = c.SDL_BeginGPURenderPass(command_buffer, &color_target, 1, null) orelse {
            return finishAcquiredCommandBufferAfterError(command_buffer, "SDL_BeginGPURenderPass");
        };
        c.SDL_EndGPURenderPass(render_pass);

        if (!c.SDL_SubmitGPUCommandBuffer(command_buffer)) {
            return sdlError("SDL_SubmitGPUCommandBuffer");
        }
        return .submitted;
    }

    fn currentWindowSize(self: *Renderer) !resolution.WindowSize {
        var window_width: c_int = 0;
        var window_height: c_int = 0;
        if (!c.SDL_GetWindowSize(self.window, &window_width, &window_height)) {
            return sdlError("SDL_GetWindowSize");
        }
        if (window_width <= 0 or window_height <= 0) return error.InvalidWindowSize;

        return .{
            .width = @intCast(window_width),
            .height = @intCast(window_height),
        };
    }

    fn currentDrawableSize(self: *Renderer) !resolution.DrawableSize {
        var drawable_width: c_int = 0;
        var drawable_height: c_int = 0;
        if (!c.SDL_GetWindowSizeInPixels(self.window, &drawable_width, &drawable_height)) {
            return sdlError("SDL_GetWindowSizeInPixels");
        }
        if (drawable_width <= 0 or drawable_height <= 0) return error.InvalidDrawableSize;

        return .{
            .width = @intCast(drawable_width),
            .height = @intCast(drawable_height),
        };
    }

    fn updatePresentation(
        self: *Renderer,
        window_size: resolution.WindowSize,
        drawable_size: resolution.DrawableSize,
    ) resolution.Presentation {
        // computePresentation only fails on a zero window, drawable, or logical
        // size. All three are validated non-zero before reaching here: window and
        // drawable sizes by the callers (currentWindowSize/currentDrawableSize and
        // the post-acquire zero check), and resolution_policy.logical_size at
        // startup via AppConfig.validate. The failure path is unreachable.
        const presentation = resolution.computePresentation(
            self.resolution_policy,
            window_size,
            drawable_size,
        ) catch unreachable;
        self.current_presentation = presentation;
        self.logPresentationChange(presentation);
        return presentation;
    }

    fn logPresentationChange(self: *Renderer, presentation: resolution.Presentation) void {
        if (!logging.enabled(.debug)) return;
        if (self.last_logged_presentation) |last| {
            if (presentationsMatch(last, presentation)) return;
        }

        const pixel_density = c.SDL_GetWindowPixelDensity(self.window);
        const display_scale = c.SDL_GetWindowDisplayScale(self.window);
        const viewport = presentation.viewport;
        log.debug(
            "presentation changed: window={}x{} drawable={}x{} logical={}x{} scale_mode={s} viewport=({}, {}) {}x{} scale={d:.3}x{d:.3} pixel_density={d:.3} display_scale={d:.3}",
            .{
                presentation.window_size.width,
                presentation.window_size.height,
                presentation.drawable_size.width,
                presentation.drawable_size.height,
                presentation.policy.logical_size.width,
                presentation.policy.logical_size.height,
                @tagName(presentation.policy.scale_mode),
                viewport.x,
                viewport.y,
                viewport.width,
                viewport.height,
                viewport.scale_x,
                viewport.scale_y,
                pixel_density,
                display_scale,
            },
        );
        self.last_logged_presentation = presentation;
    }

    pub fn createTextureFromPixels(
        self: *Renderer,
        pixels: []const u8,
        width: u32,
        height: u32,
        pitch: usize,
    ) !TextureId {
        return try self.createTextureFromPixelsInternal(pixels, width, height, pitch, false);
    }

    /// Uploads decoded startup images in one GPU command buffer. Returned slice
    /// is allocated with `allocator` and owned by the caller until each
    /// `TextureId` is destroyed.
    pub fn createTexturesFromPixelsBatch(self: *Renderer, allocator: std.mem.Allocator, images: []const LoadedImage) ![]TextureId {
        if (images.len == 0) return try allocator.alloc(TextureId, 0);

        const items = try self.allocator.alloc(gpu_texture.BatchUploadItem, images.len);
        defer self.allocator.free(items);
        for (images, items) |image, *item| {
            item.* = .{
                .pixels = image.pixels,
                .width = image.width,
                .height = image.height,
                .pitch = image.pitch,
            };
        }

        const uploaded = try gpu_texture.uploadTexturesBatch(self.allocator, self.device, items);
        defer self.allocator.free(uploaded);

        const ids = try allocator.alloc(TextureId, images.len);
        errdefer allocator.free(ids);
        var registered_count: usize = 0;
        errdefer for (ids[0..registered_count]) |id| {
            self.destroyTexture(id);
        };
        errdefer for (uploaded[registered_count..]) |texture| {
            c.SDL_ReleaseGPUTexture(self.device, texture.texture);
        };
        for (uploaded, ids) |texture, *id| {
            id.* = try self.registerTexture(texture, false);
            registered_count += 1;
        }
        return ids;
    }

    /// Creates a renderer-owned tile-data storage buffer from a row-major tile
    /// array (one `u32` per cell) and returns its handle. `params` is the
    /// world-constant grid/atlas uniform, stored alongside so draw groups carry only
    /// the handle. A generic multi-buffer registry: `WorldSystem` registers one
    /// entry holding every dense layer's cells concatenated, built once at world
    /// load; draw groups distinguish layers via a per-draw cell offset instead of
    /// a distinct buffer per layer.
    pub fn createTileDataBuffer(self: *Renderer, tiles: []const u32, params: TilemapParams) !TileDataId {
        const cell_count = std.math.cast(u32, tiles.len) orelse return error.TileDataBufferTooLarge;
        const buffer = try gpu_buffer.uploadStorageData(self.device, tiles);
        errdefer c.SDL_ReleaseGPUBuffer(self.device, buffer);
        const index = std.math.cast(u32, self.tile_data_buffers.items.len) orelse return error.TooManyTileDataBuffers;
        if (index == @intFromEnum(TileDataId.invalid)) return error.TooManyTileDataBuffers;
        try self.tile_data_buffers.append(self.allocator, buffer);
        errdefer _ = self.tile_data_buffers.pop();
        try self.tile_data_params.append(self.allocator, params);
        errdefer _ = self.tile_data_params.pop();
        try self.tile_data_counts.append(self.allocator, cell_count);
        log.debug("created tilemap tile-data buffer {d}: {d} cells", .{ index, tiles.len });
        return @enumFromInt(index);
    }

    /// Queues a batch of single-cell tile edits (the dig path) for upload during
    /// the next `endFrame` copy pass. Edits whose handle no longer resolves are
    /// skipped. The scratch list resolves handles to buffers and is grow-only.
    pub fn uploadTileDataEdits(self: *Renderer, edits: []const TileDataEdit) !void {
        if (edits.len == 0) return;
        // Grow-only append: pending edits are held until the post-acquire copy pass
        // runs so a skipped swapchain frame does not drop dig updates.
        try self.tile_edit_scratch.ensureTotalCapacity(self.allocator, self.tile_edit_scratch.items.len + edits.len);
        for (edits) |edit| {
            const buffer = self.tileDataBuffer(edit.buffer) orelse continue;
            const element_count = self.tileDataCount(edit.buffer);
            if (edit.element_index >= element_count) {
                log.warn("dropped tile-data edit: cell {d} out of range for buffer {d}", .{
                    edit.element_index,
                    @intFromEnum(edit.buffer),
                });
                continue;
            }
            self.tile_edit_scratch.appendAssumeCapacity(.{
                .buffer = buffer,
                .element_index = edit.element_index,
                .element_count = element_count,
                .value = edit.value,
            });
        }
        self.tile_edits_pending = self.tile_edit_scratch.items.len > 0;
    }

    /// Releases every renderer-owned tile-data storage buffer and resets the
    /// parallel handle/params/count lists. Required before rebuilding the dense
    /// tilemap when the renderer outlives the world that created the buffers; app
    /// shutdown goes through `deinit`, which performs the same release.
    pub fn releaseTileDataBuffers(self: *Renderer) void {
        for (self.tile_data_buffers.items) |buffer| {
            c.SDL_ReleaseGPUBuffer(self.device, buffer);
        }
        self.tile_data_buffers.clearRetainingCapacity();
        self.tile_data_params.clearRetainingCapacity();
        self.tile_data_counts.clearRetainingCapacity();
        self.tile_edit_scratch.clearRetainingCapacity();
        self.tile_edits_pending = false;
        if (self.tile_edit_transfer) |transfer| {
            c.SDL_ReleaseGPUTransferBuffer(self.device, transfer);
            self.tile_edit_transfer = null;
            self.tile_edit_transfer_byte_size = 0;
        }
    }

    fn ensureTileEditTransfer(self: *Renderer, required_bytes: u32) !void {
        if (self.tile_edit_transfer) |transfer| {
            if (self.tile_edit_transfer_byte_size >= required_bytes) return;
            c.SDL_ReleaseGPUTransferBuffer(self.device, transfer);
            self.tile_edit_transfer = null;
            self.tile_edit_transfer_byte_size = 0;
        }
        self.tile_edit_transfer = try gpu_buffer.createVertexTransferBuffer(self.device, required_bytes);
        self.tile_edit_transfer_byte_size = required_bytes;
    }

    fn tileDataBuffer(self: *const Renderer, id: TileDataId) ?*c.SDL_GPUBuffer {
        if (id == .invalid) return null;
        const index = @intFromEnum(id);
        if (index >= self.tile_data_buffers.items.len) return null;
        return self.tile_data_buffers.items[index];
    }

    fn tileDataCount(self: *const Renderer, id: TileDataId) u32 {
        if (id == .invalid) return 0;
        const index = @intFromEnum(id);
        if (index >= self.tile_data_counts.items.len) return 0;
        return self.tile_data_counts.items[index];
    }

    // Direct load: only called for a tilemap group whose `tile_data` already
    // resolved to a buffer this frame, so the parallel params entry is present.
    fn tileDataParams(self: *const Renderer, id: TileDataId) TilemapParams {
        return self.tile_data_params.items[@intFromEnum(id)];
    }

    fn createInternalTextureFromPixels(
        self: *Renderer,
        pixels: []const u8,
        width: u32,
        height: u32,
        pitch: usize,
    ) !TextureId {
        return try self.createTextureFromPixelsInternal(pixels, width, height, pitch, true);
    }

    fn createTextureFromPixelsInternal(
        self: *Renderer,
        pixels: []const u8,
        width: u32,
        height: u32,
        pitch: usize,
        internal: bool,
    ) !TextureId {
        const texture = try gpu_texture.uploadFromPixels(self.allocator, self.device, pixels, width, height, pitch);
        errdefer c.SDL_ReleaseGPUTexture(self.device, texture.texture);
        return try self.registerTexture(texture, internal);
    }

    pub fn replaceTextureFromPixels(
        self: *Renderer,
        id: TextureId,
        pixels: []const u8,
        width: u32,
        height: u32,
        pitch: usize,
    ) !void {
        const slot = self.resolveTextureSlot(id) orelse return error.InvalidTexture;
        if (slot.internal) return error.InvalidTexture;

        const next_texture = try gpu_texture.uploadFromPixels(self.allocator, self.device, pixels, width, height, pitch);
        errdefer c.SDL_ReleaseGPUTexture(self.device, next_texture.texture);

        c.SDL_ReleaseGPUTexture(self.device, slot.texture.?);
        slot.texture = next_texture.texture;
        slot.desc = next_texture.desc;
    }

    fn registerTexture(self: *Renderer, texture: UploadedTexture, internal: bool) !TextureId {
        if (self.first_free_texture_slot) |index| {
            const slot = &self.texture_slots.items[@intCast(index)];
            const generation = slot.generation;
            self.first_free_texture_slot = slot.next_free;
            slot.* = .{
                .texture = texture.texture,
                .desc = texture.desc,
                .generation = generation,
                .alive = true,
                .internal = internal,
                .next_free = null,
            };
            return TextureId.init(index, generation) catch unreachable;
        }

        if (self.texture_slots.items.len >= std.math.maxInt(u32)) return error.TooManyTextures;
        const index: u32 = @intCast(self.texture_slots.items.len);
        try self.texture_slots.append(self.allocator, .{
            .texture = texture.texture,
            .desc = texture.desc,
            .generation = 1,
            .alive = true,
            .internal = internal,
            .next_free = null,
        });
        return TextureId.init(index, 1) catch unreachable;
    }

    fn resolveTextureSlot(self: *Renderer, id: TextureId) ?*TextureSlot {
        if (!id.isValid()) return null;
        const index: usize = @intCast(id.index);
        if (index >= self.texture_slots.items.len) return null;

        const slot = &self.texture_slots.items[index];
        if (!slot.alive) return null;
        if (!id.matches(id.index, slot.generation)) return null;
        return slot;
    }

    fn resolveTextureSlotConst(self: *const Renderer, id: TextureId) ?*const TextureSlot {
        if (!id.isValid()) return null;
        const index: usize = @intCast(id.index);
        if (index >= self.texture_slots.items.len) return null;

        const slot = &self.texture_slots.items[index];
        if (!slot.alive) return null;
        if (!id.matches(id.index, slot.generation)) return null;
        return slot;
    }

    fn retireTextureSlot(self: *Renderer, index: u32, slot: *TextureSlot) void {
        std.debug.assert(slot.alive);
        c.SDL_ReleaseGPUTexture(self.device, slot.texture.?);
        // Retired slots keep their index but advance generation, invalidating
        // stale TextureId values while allowing slot reuse without path lookup.
        retireTextureSlotForReuse(slot, self.first_free_texture_slot);
        self.first_free_texture_slot = index;
    }

    fn reserveBatchStorage(
        self: *Renderer,
        command_capacity: usize,
        vertex_capacity: usize,
        draw_group_capacity: usize,
    ) !void {
        try self.batch.reserveStorage(command_capacity, vertex_capacity, draw_group_capacity);
    }

    fn deinitBatchStorage(self: *Renderer) void {
        self.batch.deinit();
    }

    fn ensureFrameBatchCapacity(self: *Renderer) !void {
        const command_count = self.batch.commands.items.len;
        if (command_count == 0) return;
        if (comptime @import("builtin").mode == .Debug) {
            std.debug.assert(command_count <= self.command_high_water);
        }
        if (command_count <= self.command_high_water) return;

        const needed_vertices = try std.math.mul(usize, command_count, 6);
        try self.batch.ensureFrameStorage();
        try self.ensureBatchCapacity(needed_vertices);
    }

    fn ensureBatchCapacity(self: *Renderer, needed_vertices: usize) !void {
        if (needed_vertices <= self.batch_capacity_vertices) return;

        var new_capacity = self.batch_capacity_vertices;
        while (new_capacity < needed_vertices) {
            new_capacity *= 2;
        }

        // Growth requires a full GPU idle below, stalling the pipeline. Large
        // scenes should reserve vertex capacity up front; warn so an unreserved
        // runtime grow-and-stall is visible rather than silent.
        log.warn("growing vertex batch capacity {} -> {} vertices (GPU stall); reserve capacity to avoid this", .{ self.batch_capacity_vertices, new_capacity });

        // Build the full new three-buffer set before idling and releasing the old,
        // so a creation failure leaves the live streams untouched.
        const new_streams = try createVertexStreams(self.device, new_capacity);
        errdefer releaseVertexStreams(self.device, new_streams);

        _ = c.SDL_WaitForGPUIdle(self.device);
        releaseVertexStreams(self.device, self.vertex_streams);

        self.vertex_streams = new_streams;
        self.batch_capacity_vertices = new_capacity;
    }

    fn stageVertices(self: *Renderer) !void {
        const streams = self.vertex_streams;
        try gpu_buffer.stageVertices(self.device, streams.position_transfer, streams.position_bytes, std.mem.sliceAsBytes(self.batch.positions.items));
        try gpu_buffer.stageVertices(self.device, streams.uv_transfer, streams.uv_bytes, std.mem.sliceAsBytes(self.batch.uvs.items));
        try gpu_buffer.stageVertices(self.device, streams.color_transfer, streams.color_bytes, std.mem.sliceAsBytes(self.batch.colors.items));
    }

    const FrameCopyPassWork = struct {
        dynamic: bool = false,
        static_vertices: bool = false,
        tile_edits: bool = false,
    };

    fn recordFrameCopyPass(
        self: *Renderer,
        command_buffer: *c.SDL_GPUCommandBuffer,
        work: FrameCopyPassWork,
    ) !void {
        var copy_pass_scope = try gpu_buffer.CopyPassScope.begin(command_buffer);
        defer copy_pass_scope.end();

        // Every vertex-stream upload below is a full-buffer rewrite, so each
        // passes `cycle=true` independently of what else shares this pass.
        // Tile-data storage edits are excluded — they target retained
        // per-layer buffers with partial writes.
        if (work.dynamic) {
            const streams = self.vertex_streams;
            try gpu_buffer.recordVertexUploadInPass(
                copy_pass_scope.pass,
                streams.position_transfer,
                streams.position_bytes,
                streams.position,
                streams.position_bytes,
                std.mem.sliceAsBytes(self.batch.positions.items),
                true,
            );
            try gpu_buffer.recordVertexUploadInPass(
                copy_pass_scope.pass,
                streams.uv_transfer,
                streams.uv_bytes,
                streams.uv,
                streams.uv_bytes,
                std.mem.sliceAsBytes(self.batch.uvs.items),
                true,
            );
            try gpu_buffer.recordVertexUploadInPass(
                copy_pass_scope.pass,
                streams.color_transfer,
                streams.color_bytes,
                streams.color,
                streams.color_bytes,
                std.mem.sliceAsBytes(self.batch.colors.items),
                true,
            );
        }

        if (work.static_vertices) {
            const streams = self.static_streams.?;
            try gpu_buffer.recordVertexUploadInPass(
                copy_pass_scope.pass,
                streams.position_transfer,
                streams.position_bytes,
                streams.position,
                streams.position_bytes,
                std.mem.sliceAsBytes(self.static_positions.items),
                true,
            );
            try gpu_buffer.recordVertexUploadInPass(
                copy_pass_scope.pass,
                streams.uv_transfer,
                streams.uv_bytes,
                streams.uv,
                streams.uv_bytes,
                std.mem.sliceAsBytes(self.static_uvs.items),
                true,
            );
            try gpu_buffer.recordVertexUploadInPass(
                copy_pass_scope.pass,
                streams.color_transfer,
                streams.color_bytes,
                streams.color,
                streams.color_bytes,
                std.mem.sliceAsBytes(self.static_colors.items),
                true,
            );
        }

        if (work.tile_edits) {
            const required_bytes = try gpu_buffer.storageByteSize(self.tile_edit_scratch.items.len);
            try self.ensureTileEditTransfer(required_bytes);
            const transfer = self.tile_edit_transfer.?;
            // Stage immediately before the copy, after swapchain acquire (matches
            // the working `world` branch timing for dig cell uploads).
            try gpu_buffer.stageStorageRegions(
                self.device,
                transfer,
                self.tile_edit_transfer_byte_size,
                self.tile_edit_scratch.items,
            );
            try gpu_buffer.recordStorageRegionsInPass(
                copy_pass_scope.pass,
                transfer,
                self.tile_edit_transfer_byte_size,
                self.tile_edit_scratch.items,
            );
            self.tile_edits_pending = false;
            self.tile_edit_scratch.clearRetainingCapacity();
        }
    }

    // Grows the retained static buffer to hold `needed_vertices` (the dense-layer
    // tilemap quads, 6 per layer). Grow-only and created lazily on first upload; it
    // grows only when a dense layer is added, so the GPU-idle stall below is a rare,
    // few-vertex structural event rather than a per-frame cost.
    fn ensureStaticCapacity(self: *Renderer, needed_vertices: usize) !void {
        if (self.static_streams != null and needed_vertices <= self.static_capacity_vertices) return;

        var new_capacity = if (self.static_capacity_vertices == 0) needed_vertices else self.static_capacity_vertices;
        while (new_capacity < needed_vertices) {
            new_capacity *= 2;
        }

        const new_streams = try createVertexStreams(self.device, new_capacity);
        errdefer releaseVertexStreams(self.device, new_streams);

        if (self.static_streams) |streams| {
            _ = c.SDL_WaitForGPUIdle(self.device);
            releaseVertexStreams(self.device, streams);
        }

        self.static_streams = new_streams;
        self.static_capacity_vertices = new_capacity;
    }

    fn stageStaticVertices(self: *Renderer) !void {
        try self.ensureStaticCapacity(self.static_positions.items.len);
        const streams = self.static_streams.?;
        try gpu_buffer.stageVertices(self.device, streams.position_transfer, streams.position_bytes, std.mem.sliceAsBytes(self.static_positions.items));
        try gpu_buffer.stageVertices(self.device, streams.uv_transfer, streams.uv_bytes, std.mem.sliceAsBytes(self.static_uvs.items));
        try gpu_buffer.stageVertices(self.device, streams.color_transfer, streams.color_bytes, std.mem.sliceAsBytes(self.static_colors.items));
    }

    pub fn spritePrepStats(self: *const Renderer) SpritePrepStats {
        return self.batch.lastPrepStats();
    }

    fn prepareFrameCommands(self: *Renderer, thread_system: ?*ThreadSystem) !void {
        _ = self.batch.buildAssumeCapacity(self.textureResolver(), thread_system, .{});
    }
};

// Stable comparator for the unified draw list: by render order only, so equal
// orders keep append order (static spans are appended before dynamic groups,
// preserving the prior world-before-dynamic tie-break at the same depth).
fn drawGroupOrderLessThan(_: void, a: DrawGroup, b: DrawGroup) bool {
    const a_domain = @intFromEnum(a.order.domain);
    const b_domain = @intFromEnum(b.order.domain);
    if (a_domain != b_domain) return a_domain < b_domain;
    return a.order.depth < b.order.depth;
}

// Coalesces adjacent draw groups sharing source, texture, and presentation that
// are contiguous in their buffer. Compacts in place; returns the new length.
fn coalesceDrawList(items: []DrawGroup) usize {
    if (items.len == 0) return 0;
    var write: usize = 0;
    for (items[1..]) |group| {
        const cur = &items[write];
        // Only sprite groups coalesce; each tilemap group binds its own storage
        // buffer + uniform, so it must stay a distinct draw.
        if (cur.material == .sprite and group.material == .sprite and
            cur.source == group.source and
            cur.presentation == group.presentation and
            cur.texture.index == group.texture.index and
            cur.texture.generation == group.texture.generation and
            cur.first_vertex + cur.vertex_count == group.first_vertex)
        {
            cur.vertex_count += group.vertex_count;
        } else {
            write += 1;
            items[write] = group;
        }
    }
    return write + 1;
}

// Builds the per-frame unified draw list from retained static spans and dynamic
// groups: append (static first), stable-sort by order, then coalesce.
pub fn mergeDrawList(
    out: *std.ArrayListUnmanaged(DrawGroup),
    allocator: std.mem.Allocator,
    static_groups: []const DrawGroup,
    dynamic_groups: []const DrawGroup,
) !void {
    out.clearRetainingCapacity();
    try out.ensureTotalCapacity(allocator, static_groups.len + dynamic_groups.len);
    out.appendSliceAssumeCapacity(static_groups);
    out.appendSliceAssumeCapacity(dynamic_groups);
    // Stability is load-bearing: static groups are appended first so that at equal
    // order they draw before dynamic (world/dense under sparse/entities). Do not
    // swap to an unstable sort without restoring that tie-break another way.
    std.mem.sort(DrawGroup, out.items, {}, drawGroupOrderLessThan);
    out.items.len = coalesceDrawList(out.items);
}

const UploadedTexture = gpu_texture.UploadedTexture;

fn resolveTextureDescForBatch(context: *const anyopaque, id: TextureId) ?resources.TextureDesc {
    const renderer: *const Renderer = @ptrCast(@alignCast(context));
    return renderer.textureDesc(id);
}

const TextureSlot = struct {
    texture: ?*c.SDL_GPUTexture = null,
    desc: resources.TextureDesc = .{ .width = 0, .height = 0 },
    generation: u32 = 1,
    alive: bool = false,
    internal: bool = false,
    next_free: ?u32 = null,
};

const FrameUniform = extern struct {
    drawable_size: [4]f32,
    position_transform: [4]f32,
};

fn applyDrawableViewport(
    render_pass: *c.SDL_GPURenderPass,
    presentation: resolution.Presentation,
) void {
    var gpu_viewport = c.SDL_GPUViewport{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(presentation.drawable_size.width),
        .h = @floatFromInt(presentation.drawable_size.height),
        .min_depth = 0,
        .max_depth = 1,
    };
    c.SDL_SetGPUViewport(render_pass, &gpu_viewport);
}

fn applyGroupPresentation(
    render_pass: *c.SDL_GPURenderPass,
    command_buffer: *c.SDL_GPUCommandBuffer,
    presentation: resolution.Presentation,
    coordinate_presentation: sprite_batch.CoordinatePresentation,
    camera: Camera2D,
) void {
    pushFrameUniform(command_buffer, presentation, coordinate_presentation, camera);
    switch (coordinate_presentation) {
        // World and logical geometry both clip to the logical viewport.
        .world, .logical => {
            var scissor = scissorForViewport(presentation.viewport, presentation.drawable_size);
            c.SDL_SetGPUScissor(render_pass, &scissor);
        },
        .drawable => {
            var scissor = c.SDL_Rect{
                .x = 0,
                .y = 0,
                .w = @intCast(presentation.drawable_size.width),
                .h = @intCast(presentation.drawable_size.height),
            };
            c.SDL_SetGPUScissor(render_pass, &scissor);
        },
    }
}

fn pushFrameUniform(
    command_buffer: *c.SDL_GPUCommandBuffer,
    presentation: resolution.Presentation,
    coordinate_presentation: sprite_batch.CoordinatePresentation,
    camera: Camera2D,
) void {
    var frame_uniform = frameUniformForPresentation(presentation, coordinate_presentation, camera);
    c.SDL_PushGPUVertexUniformData(command_buffer, 0, &frame_uniform, @sizeOf(FrameUniform));
}

fn frameUniformForPresentation(
    presentation: resolution.Presentation,
    coordinate_presentation: sprite_batch.CoordinatePresentation,
    camera: Camera2D,
) FrameUniform {
    const viewport_scale_x = presentation.viewport.scale_x;
    const viewport_scale_y = presentation.viewport.scale_y;
    const viewport_offset_x: f32 = @floatFromInt(presentation.viewport.x);
    const viewport_offset_y: f32 = @floatFromInt(presentation.viewport.y);
    const transform: [4]f32 = switch (coordinate_presentation) {
        // World geometry arrives in world space; fold the camera into the
        // logical viewport affine so `drawable = world*scale + offset` exactly
        // reproduces the former CPU `worldToScreen` path.
        .world => .{
            camera.zoom * viewport_scale_x,
            camera.zoom * viewport_scale_y,
            viewport_offset_x - camera.position.x * camera.zoom * viewport_scale_x,
            viewport_offset_y - camera.position.y * camera.zoom * viewport_scale_y,
        },
        .logical => .{
            viewport_scale_x,
            viewport_scale_y,
            viewport_offset_x,
            viewport_offset_y,
        },
        .drawable => .{ 1, 1, 0, 0 },
    };
    return .{
        .drawable_size = .{
            @floatFromInt(presentation.drawable_size.width),
            @floatFromInt(presentation.drawable_size.height),
            0,
            0,
        },
        .position_transform = transform,
    };
}

fn scissorForViewport(viewport: resolution.Viewport, drawable_size: resolution.DrawableSize) c.SDL_Rect {
    const left = @max(@as(i64, 0), @as(i64, viewport.x));
    const top = @max(@as(i64, 0), @as(i64, viewport.y));
    const right = @min(
        @as(i64, @intCast(drawable_size.width)),
        @as(i64, viewport.x) + @as(i64, @intCast(viewport.width)),
    );
    const bottom = @min(
        @as(i64, @intCast(drawable_size.height)),
        @as(i64, viewport.y) + @as(i64, @intCast(viewport.height)),
    );

    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .w = @intCast(@max(@as(i64, 0), right - left)),
        .h = @intCast(@max(@as(i64, 0), bottom - top)),
    };
}

fn presentationsMatch(lhs: resolution.Presentation, rhs: resolution.Presentation) bool {
    return lhs.window_size.width == rhs.window_size.width and
        lhs.window_size.height == rhs.window_size.height and
        lhs.drawable_size.width == rhs.drawable_size.width and
        lhs.drawable_size.height == rhs.drawable_size.height and
        lhs.policy.logical_size.width == rhs.policy.logical_size.width and
        lhs.policy.logical_size.height == rhs.policy.logical_size.height and
        lhs.policy.scale_mode == rhs.policy.scale_mode;
}

fn validateConfig(app_config: config.AppConfig) !void {
    try app_config.validate();
}

fn swapchainUnavailable(swapchain_texture: ?*c.SDL_GPUTexture) bool {
    return swapchain_texture == null;
}

fn finishAcquiredCommandBufferAfterError(
    command_buffer: *c.SDL_GPUCommandBuffer,
    comptime operation: []const u8,
) error{SdlError} {
    log.err("{s} failed after swapchain acquisition: {s}", .{ operation, c.SDL_GetError() });
    if (!c.SDL_SubmitGPUCommandBuffer(command_buffer)) {
        log.err("SDL_SubmitGPUCommandBuffer failed while releasing acquired swapchain after {s}: {s}", .{ operation, c.SDL_GetError() });
    }
    return error.SdlError;
}

fn shouldApplyPresentationState(
    active_presentation: *?sprite_batch.CoordinatePresentation,
    next_presentation: sprite_batch.CoordinatePresentation,
) bool {
    if (active_presentation.* == next_presentation) return false;
    active_presentation.* = next_presentation;
    return true;
}

fn retireTextureSlotForReuse(slot: *TextureSlot, next_free: ?u32) void {
    slot.texture = null;
    slot.desc = .{ .width = 0, .height = 0 };
    slot.generation = resources.nextGeneration(slot.generation);
    slot.alive = false;
    slot.internal = false;
    slot.next_free = next_free;
}

fn sdlError(comptime operation: []const u8) error{SdlError} {
    return sdl.sdlError(operation);
}

fn testTextureId(index: u32, generation: u32) TextureId {
    return TextureId.init(index, generation) catch unreachable;
}

fn testTextureSlot(texture: *c.SDL_GPUTexture, width: u32, height: u32, generation: u32, internal: bool) TextureSlot {
    return .{
        .texture = texture,
        .desc = .{ .width = width, .height = height },
        .generation = generation,
        .alive = true,
        .internal = internal,
    };
}

test "texture slots reuse retired slots with fresh generations" {
    const allocator = std.testing.allocator;
    var renderer = Renderer{
        .allocator = allocator,
        .device = undefined,
        .window = undefined,
        .pipeline = undefined,
        .tilemap_pipeline = undefined,
        .sampler = undefined,
        .vertex_streams = undefined,
        .batch_capacity_vertices = 0,
        .batch = sprite_batch.SpriteBatch.init(allocator),
    };
    defer renderer.texture_slots.deinit(allocator);

    const first = try renderer.registerTexture(.{
        .texture = @ptrFromInt(1),
        .desc = .{ .width = 16, .height = 16 },
    }, false);

    retireTextureSlotForReuse(&renderer.texture_slots.items[@intCast(first.index)], renderer.first_free_texture_slot);
    renderer.first_free_texture_slot = first.index;

    const second = try renderer.registerTexture(.{
        .texture = @ptrFromInt(2),
        .desc = .{ .width = 32, .height = 8 },
    }, false);

    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expectEqual(resources.nextGeneration(first.generation), second.generation);
    try std.testing.expect(renderer.resolveTextureSlot(first) == null);

    const desc = renderer.textureDesc(second).?;
    try std.testing.expectEqual(@as(u32, 32), desc.width);
    try std.testing.expectEqual(@as(u32, 8), desc.height);
}

test "internal texture slots cannot be destroyed or replaced through public APIs" {
    const allocator = std.testing.allocator;
    var renderer = Renderer{
        .allocator = allocator,
        .device = undefined,
        .window = undefined,
        .pipeline = undefined,
        .tilemap_pipeline = undefined,
        .sampler = undefined,
        .vertex_streams = undefined,
        .batch_capacity_vertices = 0,
        .batch = sprite_batch.SpriteBatch.init(allocator),
    };
    defer renderer.texture_slots.deinit(allocator);

    const texture = try renderer.registerTexture(.{
        .texture = @ptrFromInt(1),
        .desc = .{ .width = 1, .height = 1 },
    }, true);
    renderer.white_texture = texture;

    renderer.destroyTexture(texture);
    try std.testing.expect(renderer.resolveTextureSlot(texture) != null);
    try std.testing.expectError(error.InvalidTexture, renderer.replaceTextureFromPixels(texture, &.{ 255, 255, 255, 255 }, 1, 1, 4));
}

test "drawable presentation uses full drawable scissor and overscan scissor clamps to drawable bounds" {
    const presentation = try resolution.computePresentation(.{}, .{ .width = 1280, .height = 720 }, .{ .width = 2560, .height = 1440 });
    const drawable_scissor = scissorForViewport(.{
        .x = 0,
        .y = 0,
        .width = presentation.drawable_size.width,
        .height = presentation.drawable_size.height,
        .scale_x = 1,
        .scale_y = 1,
    }, presentation.drawable_size);
    try std.testing.expectEqual(@as(c_int, 0), drawable_scissor.x);
    try std.testing.expectEqual(@as(c_int, 0), drawable_scissor.y);
    try std.testing.expectEqual(@as(c_int, 2560), drawable_scissor.w);
    try std.testing.expectEqual(@as(c_int, 1440), drawable_scissor.h);

    const overscan = try resolution.computeViewport(.{
        .logical_size = .{ .width = 1280, .height = 720 },
        .scale_mode = .overscan,
    }, .{ .width = 1024, .height = 768 });
    const overscan_scissor = scissorForViewport(overscan, .{ .width = 1024, .height = 768 });
    try std.testing.expectEqual(@as(c_int, 0), overscan_scissor.x);
    try std.testing.expectEqual(@as(c_int, 0), overscan_scissor.y);
    try std.testing.expectEqual(@as(c_int, 1024), overscan_scissor.w);
    try std.testing.expectEqual(@as(c_int, 768), overscan_scissor.h);
}

test "null swapchain texture preserves skipped no swapchain result path" {
    try std.testing.expect(swapchainUnavailable(null));
    try std.testing.expect(!swapchainUnavailable(@ptrFromInt(1)));
    try std.testing.expectEqual(FrameResult.skipped_no_swapchain, FrameResult.skipped_no_swapchain);
}

test "frame uniforms transform logical coordinates after acquisition" {
    const presentation = try resolution.computePresentation(
        .{},
        .{ .width = 1800, .height = 1130 },
        .{ .width = 3600, .height = 2260 },
    );

    const logical = frameUniformForPresentation(presentation, .logical, .{});
    try std.testing.expectEqual(@as(f32, 3600), logical.drawable_size[0]);
    try std.testing.expectEqual(@as(f32, 2260), logical.drawable_size[1]);
    try std.testing.expectApproxEqAbs(presentation.viewport.scale_x, logical.position_transform[0], 0.001);
    try std.testing.expectApproxEqAbs(presentation.viewport.scale_y, logical.position_transform[1], 0.001);
    try std.testing.expectEqual(@as(f32, @floatFromInt(presentation.viewport.x)), logical.position_transform[2]);
    try std.testing.expectEqual(@as(f32, @floatFromInt(presentation.viewport.y)), logical.position_transform[3]);

    const drawable = frameUniformForPresentation(presentation, .drawable, .{});
    try std.testing.expectEqual(@as(f32, 1), drawable.position_transform[0]);
    try std.testing.expectEqual(@as(f32, 1), drawable.position_transform[1]);
    try std.testing.expectEqual(@as(f32, 0), drawable.position_transform[2]);
    try std.testing.expectEqual(@as(f32, 0), drawable.position_transform[3]);

    // World geometry bakes the camera into the logical viewport affine so the
    // GPU reproduces the former CPU `worldToScreen` then logical-presentation path.
    const camera = Camera2D{ .position = .{ .x = 40, .y = 25 }, .zoom = 2 };
    const world = frameUniformForPresentation(presentation, .world, camera);
    try std.testing.expectApproxEqAbs(camera.zoom * presentation.viewport.scale_x, world.position_transform[0], 0.001);
    try std.testing.expectApproxEqAbs(camera.zoom * presentation.viewport.scale_y, world.position_transform[1], 0.001);
    try std.testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(presentation.viewport.x)) - camera.position.x * camera.zoom * presentation.viewport.scale_x,
        world.position_transform[2],
        0.001,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(presentation.viewport.y)) - camera.position.y * camera.zoom * presentation.viewport.scale_y,
        world.position_transform[3],
        0.001,
    );
}

test "presentation state applies first group and changes only" {
    var active_presentation: ?sprite_batch.CoordinatePresentation = null;

    try std.testing.expect(shouldApplyPresentationState(&active_presentation, .logical));
    try std.testing.expectEqual(sprite_batch.CoordinatePresentation.logical, active_presentation.?);
    try std.testing.expect(!shouldApplyPresentationState(&active_presentation, .logical));
    try std.testing.expect(shouldApplyPresentationState(&active_presentation, .drawable));
    try std.testing.expectEqual(sprite_batch.CoordinatePresentation.drawable, active_presentation.?);
    try std.testing.expect(!shouldApplyPresentationState(&active_presentation, .drawable));
    try std.testing.expect(shouldApplyPresentationState(&active_presentation, .logical));
}

fn testDrawGroup(
    source: DrawSource,
    texture_index: u32,
    presentation: CoordinatePresentation,
    order: RenderOrder,
    first_vertex: u32,
    vertex_count: u32,
) DrawGroup {
    return .{
        .source = source,
        .texture = TextureId.init(texture_index, 1) catch unreachable,
        .presentation = presentation,
        .order = order,
        .first_vertex = first_vertex,
        .vertex_count = vertex_count,
    };
}

test "draw list interleaves static and dynamic by render order across z" {
    const allocator = std.testing.allocator;
    var list: std.ArrayListUnmanaged(DrawGroup) = .empty;
    defer list.deinit(allocator);

    // Static floor (-2) and effect (+1) tiles; a dynamic actor (0) between them.
    const static_groups = [_]DrawGroup{
        testDrawGroup(.static, 0, .world, RenderOrder.world(-2), 0, 6),
        testDrawGroup(.static, 0, .world, RenderOrder.world(1), 6, 6),
    };
    const dynamic_groups = [_]DrawGroup{
        testDrawGroup(.dynamic, 1, .world, RenderOrder.world(0), 0, 6),
    };

    try mergeDrawList(&list, allocator, &static_groups, &dynamic_groups);

    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqual(DrawSource.static, list.items[0].source);
    try std.testing.expectEqual(@as(i32, -2), list.items[0].order.depth);
    try std.testing.expectEqual(DrawSource.dynamic, list.items[1].source);
    try std.testing.expectEqual(@as(i32, 0), list.items[1].order.depth);
    try std.testing.expectEqual(DrawSource.static, list.items[2].source);
    try std.testing.expectEqual(@as(i32, 1), list.items[2].order.depth);
}

test "same-texture dynamic run straddling a static span interleaves by order" {
    const allocator = std.testing.allocator;

    // Two dynamic sprites share one texture but sit at world(-2) and world(1).
    // buildDrawGroups must split them into order-homogeneous groups so a static
    // span at world(0) sorts BETWEEN them in the merged draw list. A single group
    // keyed at the lower depth would draw both dynamic sprites before the span.
    var batch = sprite_batch.SpriteBatch.init(allocator);
    defer batch.deinit();
    try batch.reserveStorage(4, 4 * 6, 4);

    const dynamic_texture = TextureId.init(1, 1) catch unreachable;
    try batch.drawSprite(.{
        .texture = dynamic_texture,
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .order = RenderOrder.world(-2),
    });
    try batch.drawSprite(.{
        .texture = dynamic_texture,
        .dest = .{ .x = 2, .y = 0, .w = 1, .h = 1 },
        .order = RenderOrder.world(1),
    });

    const desc = resources.TextureDesc{ .width = 8, .height = 8 };
    const resolver = sprite_batch.TextureResolver{
        .context = &desc,
        .resolve = struct {
            fn resolve(ctx: *const anyopaque, id: TextureId) ?resources.TextureDesc {
                _ = id;
                return @as(*const resources.TextureDesc, @ptrCast(@alignCast(ctx))).*;
            }
        }.resolve,
    };
    batch.buildSerial(resolver);
    try std.testing.expectEqual(@as(usize, 2), batch.draw_groups.items.len);

    var list: std.ArrayListUnmanaged(DrawGroup) = .empty;
    defer list.deinit(allocator);
    const static_groups = [_]DrawGroup{
        testDrawGroup(.static, 2, .world, RenderOrder.world(0), 0, 6),
    };

    try mergeDrawList(&list, allocator, &static_groups, batch.draw_groups.items);

    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqual(DrawSource.dynamic, list.items[0].source);
    try std.testing.expectEqual(@as(i32, -2), list.items[0].order.depth);
    try std.testing.expectEqual(DrawSource.static, list.items[1].source);
    try std.testing.expectEqual(@as(i32, 0), list.items[1].order.depth);
    try std.testing.expectEqual(DrawSource.dynamic, list.items[2].source);
    try std.testing.expectEqual(@as(i32, 1), list.items[2].order.depth);
}

test "draw list coalesces contiguous same-source same-texture spans" {
    const allocator = std.testing.allocator;
    var list: std.ArrayListUnmanaged(DrawGroup) = .empty;
    defer list.deinit(allocator);

    const static_groups = [_]DrawGroup{
        testDrawGroup(.static, 0, .world, RenderOrder.world(-2), 0, 6),
        testDrawGroup(.static, 0, .world, RenderOrder.world(-2), 6, 12),
    };

    try mergeDrawList(&list, allocator, &static_groups, &.{});

    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(@as(u32, 0), list.items[0].first_vertex);
    try std.testing.expectEqual(@as(u32, 18), list.items[0].vertex_count);
}

test "draw list keeps non-contiguous spans separate" {
    const allocator = std.testing.allocator;
    var list: std.ArrayListUnmanaged(DrawGroup) = .empty;
    defer list.deinit(allocator);

    const static_groups = [_]DrawGroup{
        testDrawGroup(.static, 0, .world, RenderOrder.world(-2), 0, 6),
        testDrawGroup(.static, 0, .world, RenderOrder.world(-2), 12, 6),
    };

    try mergeDrawList(&list, allocator, &static_groups, &.{});

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
}

test "mergeDrawList sorts unsorted underground dense layers back to front" {
    const allocator = std.testing.allocator;
    var list: std.ArrayListUnmanaged(DrawGroup) = .empty;
    defer list.deinit(allocator);

    // `submitStaticDenseGeometry` appends in dense-layer index order (surface
    // grass first), which is not ascending by render depth. The merge must sort
    // so dirt_dark draws first and grass last.
    var grass = testDrawGroup(.static, 0, .world, RenderOrder.world(-2), 0, 6);
    grass.material = .tilemap;
    var dirt = testDrawGroup(.static, 0, .world, RenderOrder.world(-18), 6, 6);
    dirt.material = .tilemap;
    var dirt_dark = testDrawGroup(.static, 0, .world, RenderOrder.world(-34), 12, 6);
    dirt_dark.material = .tilemap;
    const static_groups = [_]DrawGroup{ grass, dirt, dirt_dark };
    const dynamic_groups = [_]DrawGroup{
        testDrawGroup(.dynamic, 1, .world, RenderOrder.world(-1), 0, 6),
    };

    try mergeDrawList(&list, allocator, &static_groups, &dynamic_groups);

    try std.testing.expectEqual(@as(usize, 4), list.items.len);
    try std.testing.expectEqual(@as(i32, -34), list.items[0].order.depth);
    try std.testing.expectEqual(@as(i32, -18), list.items[1].order.depth);
    try std.testing.expectEqual(@as(i32, -2), list.items[2].order.depth);
    try std.testing.expectEqual(@as(i32, -1), list.items[3].order.depth);
}

test "tilemap layer quads interleave with dynamic groups by render order" {
    const allocator = std.testing.allocator;
    var list: std.ArrayListUnmanaged(DrawGroup) = .empty;
    defer list.deinit(allocator);

    // Two dense tilemap layers (floor -2, roof +1) with a dynamic actor (0) between.
    var floor = testDrawGroup(.static, 0, .world, RenderOrder.world(-2), 0, 6);
    floor.material = .tilemap;
    var roof = testDrawGroup(.static, 0, .world, RenderOrder.world(1), 6, 6);
    roof.material = .tilemap;
    const static_groups = [_]DrawGroup{ floor, roof };
    const dynamic_groups = [_]DrawGroup{
        testDrawGroup(.dynamic, 1, .world, RenderOrder.world(0), 0, 6),
    };

    try mergeDrawList(&list, allocator, &static_groups, &dynamic_groups);

    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqual(Material.tilemap, list.items[0].material);
    try std.testing.expectEqual(@as(i32, -2), list.items[0].order.depth);
    try std.testing.expectEqual(Material.sprite, list.items[1].material);
    try std.testing.expectEqual(Material.tilemap, list.items[2].material);
    try std.testing.expectEqual(@as(i32, 1), list.items[2].order.depth);
}

test "contiguous tilemap groups never coalesce" {
    const allocator = std.testing.allocator;
    var list: std.ArrayListUnmanaged(DrawGroup) = .empty;
    defer list.deinit(allocator);

    // Same texture/order and contiguous verts — a sprite pair would coalesce, but
    // each tilemap group binds its own storage buffer, so they stay separate draws.
    var first = testDrawGroup(.static, 0, .world, RenderOrder.world(-2), 0, 6);
    first.material = .tilemap;
    var second = testDrawGroup(.static, 0, .world, RenderOrder.world(-2), 6, 6);
    second.material = .tilemap;
    const static_groups = [_]DrawGroup{ first, second };

    try mergeDrawList(&list, allocator, &static_groups, &.{});
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
}

test "applyWindowLayers fills layer count and topmost-first offsets" {
    var params = TilemapParams{
        .grid = .{ 1, 1, 1, 1 },
        .atlas = .{ 1, 1, 1, 1 },
    };
    var window = Renderer.TilemapWindowLayers{};
    window.count = 3;
    window.offsets[0] = 100;
    window.offsets[1] = 200;
    window.offsets[2] = 300;

    Renderer.applyWindowLayers(&params, window);

    try std.testing.expectEqual(@as(i32, 3), params.layer_meta[0]);
    try std.testing.expectEqual(@as(u32, 100), params.layer_offsets[0]);
    try std.testing.expectEqual(@as(u32, 200), params.layer_offsets[1]);
    try std.testing.expectEqual(@as(u32, 300), params.layer_offsets[2]);
}

// A minimal 6-vertex quad; `appendStaticTilemapSpan` only counts and stores
// vertices, so their contents do not matter for these tests.
fn testStaticQuad() [6]Position {
    return [_]Position{.{ 0, 0 }} ** 6;
}

fn testRenderer(allocator: std.mem.Allocator) Renderer {
    return .{
        .allocator = allocator,
        .device = undefined,
        .window = undefined,
        .pipeline = undefined,
        .tilemap_pipeline = undefined,
        .sampler = undefined,
        .vertex_streams = undefined,
        .batch_capacity_vertices = 0,
        .batch = sprite_batch.SpriteBatch.init(allocator),
    };
}

fn deinitStaticGeometryTestRenderer(renderer: *Renderer, allocator: std.mem.Allocator) void {
    renderer.static_positions.deinit(allocator);
    renderer.static_uvs.deinit(allocator);
    renderer.static_colors.deinit(allocator);
    renderer.static_groups.deinit(allocator);
    renderer.batch.deinit();
}

test "appendStaticTilemapSpan assigns sequential window slots per static-geometry cycle" {
    const allocator = std.testing.allocator;
    var renderer = testRenderer(allocator);
    defer deinitStaticGeometryTestRenderer(&renderer, allocator);

    const positions = testStaticQuad();
    const uvs = [_]Uv{.{ 0, 0 }} ** 6;
    const colors = [_]VertexColor{.{ 1, 1, 1, 1 }} ** 6;
    const vertices = VertexColumnsConst{ .positions = &positions, .uvs = &uvs, .colors = &colors };
    const texture = testTextureId(0, 1);

    renderer.beginStaticGeometry();
    for (0..3) |i| {
        var window = Renderer.TilemapWindowLayers{};
        window.count = 1;
        window.offsets[0] = @intCast(i);
        try renderer.appendStaticTilemapSpan(texture, RenderOrder.world(@intCast(i)), vertices, @enumFromInt(0), window);
    }

    try std.testing.expectEqual(@as(usize, 3), renderer.tilemap_window_layer_count);
    for (0..3) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), renderer.static_groups.items[i].window_slot);
        try std.testing.expectEqual(@as(u32, @intCast(i)), renderer.tilemap_window_layers[i].offsets[0]);
    }

    // A rebuild's beginStaticGeometry resets the slot count -- no leaked slots
    // carry over from the prior cycle.
    renderer.beginStaticGeometry();
    try std.testing.expectEqual(@as(usize, 0), renderer.tilemap_window_layer_count);

    var window = Renderer.TilemapWindowLayers{};
    window.count = 1;
    window.offsets[0] = 99;
    try renderer.appendStaticTilemapSpan(texture, RenderOrder.world(0), vertices, @enumFromInt(0), window);
    try std.testing.expectEqual(@as(usize, 1), renderer.tilemap_window_layer_count);
    try std.testing.expectEqual(@as(u8, 0), renderer.static_groups.items[0].window_slot);
}

test "appendStaticTilemapSpan returns TooManyTilemapWindowDraws past the composite-draw cap" {
    const allocator = std.testing.allocator;
    var renderer = testRenderer(allocator);
    defer deinitStaticGeometryTestRenderer(&renderer, allocator);

    const positions = testStaticQuad();
    const uvs = [_]Uv{.{ 0, 0 }} ** 6;
    const colors = [_]VertexColor{.{ 1, 1, 1, 1 }} ** 6;
    const vertices = VertexColumnsConst{ .positions = &positions, .uvs = &uvs, .colors = &colors };
    const texture = testTextureId(0, 1);
    const window = Renderer.TilemapWindowLayers{ .count = 1 };

    renderer.beginStaticGeometry();
    for (0..Renderer.k_max_dense_composite_draws) |i| {
        try renderer.appendStaticTilemapSpan(texture, RenderOrder.world(@intCast(i)), vertices, @enumFromInt(0), window);
    }
    try std.testing.expectEqual(Renderer.k_max_dense_composite_draws, renderer.tilemap_window_layer_count);

    try std.testing.expectError(
        error.TooManyTilemapWindowDraws,
        renderer.appendStaticTilemapSpan(texture, RenderOrder.world(@intCast(Renderer.k_max_dense_composite_draws)), vertices, @enumFromInt(0), window),
    );
    // The fixed-size table stayed exactly at the cap; the failed call past it
    // neither corrupted it nor grew past bounds.
    try std.testing.expectEqual(Renderer.k_max_dense_composite_draws, renderer.tilemap_window_layer_count);
}

test "merge draw list stays allocation-free when reserved to combined size" {
    const allocator = std.testing.allocator;
    var list: std.ArrayListUnmanaged(DrawGroup) = .empty;
    defer list.deinit(allocator);

    // Reserve to dynamic + static budget (2 + 2), as the renderer reservation does.
    try list.ensureTotalCapacity(allocator, 4);
    const capacity_before = list.capacity;

    const static_groups = [_]DrawGroup{
        testDrawGroup(.static, 0, .world, RenderOrder.world(-2), 0, 6),
        testDrawGroup(.static, 0, .world, RenderOrder.world(-1), 6, 6),
    };
    const dynamic_groups = [_]DrawGroup{
        testDrawGroup(.dynamic, 1, .world, RenderOrder.world(0), 0, 6),
        testDrawGroup(.dynamic, 1, .logical, RenderOrder.ui(.panel), 6, 6),
    };

    try mergeDrawList(&list, allocator, &static_groups, &dynamic_groups);
    try mergeDrawList(&list, allocator, &static_groups, &dynamic_groups);

    try std.testing.expectEqual(capacity_before, list.capacity);
}

test "draw list does not merge across source and keeps static before dynamic at equal order" {
    const allocator = std.testing.allocator;
    var list: std.ArrayListUnmanaged(DrawGroup) = .empty;
    defer list.deinit(allocator);

    const static_groups = [_]DrawGroup{
        testDrawGroup(.static, 0, .world, RenderOrder.world(0), 0, 6),
    };
    const dynamic_groups = [_]DrawGroup{
        testDrawGroup(.dynamic, 0, .world, RenderOrder.world(0), 0, 6),
    };

    try mergeDrawList(&list, allocator, &static_groups, &dynamic_groups);

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(DrawSource.static, list.items[0].source);
    try std.testing.expectEqual(DrawSource.dynamic, list.items[1].source);
}

test "renderer drawable pixel scale follows current presentation" {
    const allocator = std.testing.allocator;
    var renderer = Renderer{
        .allocator = allocator,
        .device = undefined,
        .window = undefined,
        .pipeline = undefined,
        .tilemap_pipeline = undefined,
        .sampler = undefined,
        .vertex_streams = undefined,
        .batch_capacity_vertices = 0,
        .batch = sprite_batch.SpriteBatch.init(allocator),
    };

    try std.testing.expectEqual(@as(f32, 1), renderer.drawablePixelScale());

    renderer.current_presentation = try resolution.computePresentation(
        .{},
        .{ .width = 1280, .height = 720 },
        .{ .width = 2560, .height = 1440 },
    );

    try std.testing.expectEqual(@as(f32, 2), renderer.drawablePixelScale());
}

test "renderer config rejects invalid frame latency" {
    try std.testing.expectError(error.InvalidConfig, validateConfig(.{
        .app_name = "test",
        .window_title = "test",
        .frames_in_flight = 0,
    }));
    try std.testing.expectError(error.InvalidConfig, validateConfig(.{
        .app_name = "test",
        .window_title = "test",
        .frames_in_flight = 4,
    }));
}

test "reserve sprite commands is grow-only and enables allocation-free enqueue" {
    const allocator = std.testing.allocator;
    var renderer = Renderer{
        .allocator = allocator,
        .device = undefined,
        .window = undefined,
        .pipeline = undefined,
        .tilemap_pipeline = undefined,
        .sampler = undefined,
        .vertex_streams = undefined,
        .batch_capacity_vertices = 0,
        .batch = sprite_batch.SpriteBatch.init(allocator),
    };
    defer renderer.batch.deinit();
    defer renderer.draw_list.deinit(allocator);

    try renderer.reserveSpriteCommands(8);
    const capacity_before = renderer.batch.commands.capacity;
    try renderer.reserveSpriteCommands(4);
    try std.testing.expect(renderer.batch.frame_reserved);
    try std.testing.expectEqual(capacity_before, renderer.batch.commands.capacity);

    const white = TextureId.init(0, 1) catch unreachable;
    for (0..4) |i| {
        try renderer.submitOrderedSprite(.{
            .texture = white,
            .dest = .{ .x = @floatFromInt(i), .y = 0, .w = 1, .h = 1 },
            .order = RenderOrder.world(@intCast(i)),
        });
    }
    try std.testing.expectEqual(capacity_before, renderer.batch.commands.capacity);
}

// Traces the two-stage per-frame reserve: a state reserves
// `gameplay_estimate + kStackedStateUiHeadroom` up front (mirrors
// `render_prep.spriteCommandCapacity`), stacked UI then submits real sprites,
// and `Engine.renderFrame` tops up with
// `spriteCommandCount() + kOverlayCommandHeadroom` afterward — a second,
// independent reservation against the same grow-only `command_high_water`.
// This proves the top-up stays allocation-free even when stacked UI fully
// consumes its 32-command headroom, because `ensureTotalCapacity`'s amortized
// (~1.5x) growth on the state's up-front reserve already covers the extra
// `kOverlayCommandHeadroom` (32 >= 2 * 16 today). If either constant shrinks
// that margin, this test is the regression signal.
test "engine overlay top-up after stacked UI fully consumes its headroom stays allocation-free" {
    const allocator = std.testing.allocator;
    var renderer = Renderer{
        .allocator = allocator,
        .device = undefined,
        .window = undefined,
        .pipeline = undefined,
        .tilemap_pipeline = undefined,
        .sampler = undefined,
        .vertex_streams = undefined,
        .batch_capacity_vertices = 0,
        .batch = sprite_batch.SpriteBatch.init(allocator),
    };
    defer renderer.batch.deinit();
    defer renderer.draw_list.deinit(allocator);

    const white = TextureId.init(0, 1) catch unreachable;
    var order: i32 = 0;

    // Zero gameplay sprites isolates the headroom margin itself: with a
    // nonzero gameplay count the amortized growth cushion is dominated by the
    // gameplay term and would stay allocation-free even if the headroom
    // constants no longer covered each other.
    const gameplay_estimate: usize = 0;
    // State's own upfront reservation (render_prep.spriteCommandCapacity's formula).
    try renderer.reserveSpriteCommands(gameplay_estimate + Renderer.kStackedStateUiHeadroom);
    const commands_capacity_after_state_reserve = renderer.batch.commands.capacity;
    const draw_list_capacity_after_state_reserve = renderer.draw_list.capacity;

    for (0..gameplay_estimate) |_| {
        try renderer.submitOrderedSprite(.{
            .texture = white,
            .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
            .order = RenderOrder.world(order),
        });
        order += 1;
    }
    // Worst-case stacked-UI usage: fully consumes the declared headroom.
    for (0..Renderer.kStackedStateUiHeadroom) |_| {
        try renderer.submitOrderedSprite(.{
            .texture = white,
            .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
            .order = RenderOrder.world(order),
        });
        order += 1;
    }
    try std.testing.expectEqual(commands_capacity_after_state_reserve, renderer.batch.commands.capacity);

    // Block both the alloc and remap paths from the very first call so the
    // engine's top-up reservation fails loudly if it needs any real growth.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const real_renderer_allocator = renderer.allocator;
    const real_batch_allocator = renderer.batch.allocator;
    renderer.allocator = failing.allocator();
    renderer.batch.allocator = failing.allocator();
    defer {
        renderer.allocator = real_renderer_allocator;
        renderer.batch.allocator = real_batch_allocator;
    }

    const overlay_target = renderer.spriteCommandCount() + Renderer.kOverlayCommandHeadroom;
    // Sanity: this is genuinely a second, larger ask than the state's own
    // reservation, not a no-op repeat of it.
    try std.testing.expect(overlay_target > gameplay_estimate + Renderer.kStackedStateUiHeadroom);

    try renderer.reserveSpriteCommands(overlay_target);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(commands_capacity_after_state_reserve, renderer.batch.commands.capacity);
    try std.testing.expectEqual(draw_list_capacity_after_state_reserve, renderer.draw_list.capacity);

    // Debug overlay can then submit up to kOverlayCommandHeadroom more sprites
    // without overflow or a capacity grow.
    for (0..Renderer.kOverlayCommandHeadroom) |_| {
        try renderer.submitOrderedSprite(.{
            .texture = white,
            .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
            .order = RenderOrder.world(order),
        });
        order += 1;
    }
    try std.testing.expectEqual(commands_capacity_after_state_reserve, renderer.batch.commands.capacity);
}

test "linear merge matches stable sort for pre-sorted static and dynamic groups" {
    const allocator = std.testing.allocator;
    const static_groups = [_]DrawGroup{
        testDrawGroup(.static, 0, .world, RenderOrder.world(-2), 0, 6),
        testDrawGroup(.static, 0, .world, RenderOrder.world(1), 6, 6),
    };
    const dynamic_groups = [_]DrawGroup{
        testDrawGroup(.dynamic, 1, .world, RenderOrder.world(0), 0, 6),
        testDrawGroup(.dynamic, 1, .logical, RenderOrder.ui(.panel), 6, 6),
    };

    var linear: std.ArrayListUnmanaged(DrawGroup) = .empty;
    defer linear.deinit(allocator);
    try mergeDrawList(&linear, allocator, &static_groups, &dynamic_groups);

    var sorted: std.ArrayListUnmanaged(DrawGroup) = .empty;
    defer sorted.deinit(allocator);
    try sorted.ensureTotalCapacity(allocator, static_groups.len + dynamic_groups.len);
    sorted.appendSliceAssumeCapacity(&static_groups);
    sorted.appendSliceAssumeCapacity(&dynamic_groups);
    std.mem.sort(DrawGroup, sorted.items, {}, drawGroupOrderLessThan);
    sorted.items.len = coalesceDrawList(sorted.items);

    try std.testing.expectEqual(sorted.items.len, linear.items.len);
    for (sorted.items, linear.items) |expected, actual| {
        try std.testing.expectEqual(expected.source, actual.source);
        try std.testing.expectEqual(expected.order.domain, actual.order.domain);
        try std.testing.expectEqual(expected.order.depth, actual.order.depth);
        try std.testing.expectEqual(expected.first_vertex, actual.first_vertex);
        try std.testing.expectEqual(expected.vertex_count, actual.vertex_count);
    }
}
