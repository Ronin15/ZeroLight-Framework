// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! SDL_GPU renderer facade for app/game code.
//! CPU render prep happens before swapchain acquisition; the acquired section
//! stays limited to upload, render-pass encoding, and command submission.
//! TextureId values are generational handles backed by renderer-owned slots.

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
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
pub const Vertex = sprite_batch.Vertex;
pub const writeWorldSpriteQuad = sprite_batch.writeWorldSpriteQuad;
const DrawGroup = sprite_batch.DrawGroup;
const DrawSource = sprite_batch.DrawSource;
const CoordinatePresentation = sprite_batch.CoordinatePresentation;

pub const FrameResult = enum {
    submitted,
    skipped_no_swapchain,
};

/// Opaque handle to a renderer-owned tilemap tile-data storage buffer. World and
/// game code hold these per dense layer; the renderer owns the GPU resource.
pub const TileDataId = enum(u32) {
    invalid = std.math.maxInt(u32),
    _,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    device: *c.SDL_GPUDevice,
    window: *c.SDL_Window,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    tilemap_pipeline: *c.SDL_GPUGraphicsPipeline,
    sampler: *c.SDL_GPUSampler,
    vertex_buffer: *c.SDL_GPUBuffer,
    vertex_transfer_buffer: *c.SDL_GPUTransferBuffer,
    batch_capacity_vertices: usize,
    texture_slots: std.ArrayList(TextureSlot) = .empty,
    // GPU-driven tilemap tile-data: one graphics-storage-read buffer per dense
    // layer (a row-major copy of the world's dense_tile_ids). Renderer-owned so
    // world keeps only opaque handles and never crosses the render/gpu boundary.
    tile_data_buffers: std.ArrayList(*c.SDL_GPUBuffer) = .empty,
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
    static_vertex_buffer: ?*c.SDL_GPUBuffer = null,
    static_transfer_buffer: ?*c.SDL_GPUTransferBuffer = null,
    static_capacity_vertices: usize = 0,
    static_vertices: std.ArrayListUnmanaged(Vertex) = .empty,
    static_groups: std.ArrayListUnmanaged(DrawGroup) = .empty,
    static_dirty: bool = false,
    draw_list: std.ArrayListUnmanaged(DrawGroup) = .empty,
    // Reserved upper bounds feeding the merged draw list. `draw_list` is sized to
    // their sum so the per-frame merge stays allocation-free.
    reserved_dynamic_groups: usize = 0,
    reserved_static_spans: usize = 0,

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

        const vertex_buffer = try gpu_buffer.createVertexBuffer(device, initial_batch_vertices);
        errdefer c.SDL_ReleaseGPUBuffer(device, vertex_buffer);

        const vertex_transfer_buffer = try gpu_buffer.createVertexTransferBuffer(device, initial_batch_vertices);
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, vertex_transfer_buffer);

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
            .vertex_buffer = vertex_buffer,
            .vertex_transfer_buffer = vertex_transfer_buffer,
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
        self.deinitBatchStorage();
        self.static_vertices.deinit(self.allocator);
        self.static_groups.deinit(self.allocator);
        self.draw_list.deinit(self.allocator);
        if (self.static_transfer_buffer) |transfer| c.SDL_ReleaseGPUTransferBuffer(self.device, transfer);
        if (self.static_vertex_buffer) |buffer| c.SDL_ReleaseGPUBuffer(self.device, buffer);

        c.SDL_ReleaseGPUTransferBuffer(self.device, self.vertex_transfer_buffer);
        c.SDL_ReleaseGPUBuffer(self.device, self.vertex_buffer);
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
        const vertex_capacity = try std.math.mul(usize, command_capacity, 6);
        try self.reserveBatchStorage(command_capacity, vertex_capacity, command_capacity);
        try self.ensureBatchCapacity(vertex_capacity);
        self.reserved_dynamic_groups = command_capacity;
        try self.ensureDrawListReservation();
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
        self.static_vertices.clearRetainingCapacity();
        self.static_groups.clearRetainingCapacity();
        self.static_dirty = true;
    }

    /// Reserves retained static storage. Setup/grow-only; call before relying on
    /// allocation-free static rebuilds.
    pub fn reserveStaticGeometry(self: *Renderer, vertex_capacity: usize, span_capacity: usize) !void {
        try self.static_vertices.ensureTotalCapacity(self.allocator, vertex_capacity);
        try self.static_groups.ensureTotalCapacity(self.allocator, span_capacity);
        self.reserved_static_spans = span_capacity;
        try self.ensureDrawListReservation();
    }

    // Sizes the merged draw list to the combined dynamic + static span budget so
    // the per-frame `mergeDrawList` never reallocates.
    fn ensureDrawListReservation(self: *Renderer) !void {
        const total = try std.math.add(usize, self.reserved_dynamic_groups, self.reserved_static_spans);
        try self.draw_list.ensureTotalCapacity(self.allocator, total);
    }

    /// Appends one retained world-space span (e.g. a chunk-layer) with its draw
    /// order. `vertices` are world space; the camera is applied by the vertex
    /// uniform at draw time. Must be called between `beginStaticGeometry` and the
    /// next `endFrame`.
    pub fn appendStaticSpan(self: *Renderer, texture: TextureId, order: RenderOrder, vertices: []const Vertex) !void {
        if (vertices.len == 0) return;
        const end = try std.math.add(usize, self.static_vertices.items.len, vertices.len);
        const first_vertex = std.math.cast(u32, self.static_vertices.items.len) orelse return error.StaticGeometryTooLarge;
        _ = std.math.cast(u32, end) orelse return error.StaticGeometryTooLarge;
        try self.static_vertices.appendSlice(self.allocator, vertices);
        try self.static_groups.append(self.allocator, .{
            .source = .static,
            .texture = texture,
            .presentation = .world,
            .order = order,
            .first_vertex = first_vertex,
            .vertex_count = @intCast(vertices.len),
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
        const pre_acquire_drawable_size = self.currentDrawableSize() catch |err| switch (err) {
            error.InvalidDrawableSize => return .skipped_no_swapchain,
            else => return err,
        };
        _ = self.updatePresentation(window_size, pre_acquire_drawable_size);
        // Sorting, texture metadata snapshots, and optional worker vertex prep
        // happen before acquiring the swapchain to keep the acquired window short.
        try self.prepareFrameCommands(thread_system);
        // Unified draw list: retained static spans + dynamic groups, ordered and
        // coalesced. Rebuilt every frame because the dynamic groups change; the
        // static buffer itself only re-uploads when `static_dirty`.
        try mergeDrawList(&self.draw_list, self.allocator, self.static_groups.items, self.batch.draw_groups.items);
        const upload_static = self.static_dirty and self.static_vertices.items.len > 0;
        // Staging before swapchain acquisition is safe across frames in flight
        // only because the transfer buffer is mapped with cycle=true (see
        // gpu/buffer.zig): the map rotates to fresh backing storage rather than
        // overwriting bytes a prior frame's copy pass may still reference. The
        // static buffer uses the same cycle=true upload, only when dirty.
        if (self.batch.vertices.items.len > 0) {
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

        if (self.batch.vertices.items.len > 0) {
            self.recordVertexUpload(command_buffer) catch {
                return finishAcquiredCommandBufferAfterError(command_buffer, "SDL_BeginGPUCopyPass");
            };
        }
        if (upload_static) {
            self.recordStaticVertexUpload(command_buffer) catch {
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
        c.SDL_BindGPUGraphicsPipeline(render_pass, self.pipeline);

        if (self.draw_list.items.len > 0) {
            applyDrawableViewport(render_pass, presentation);

            // Bind the source buffer on source change, push the presentation
            // uniform on presentation change, draw each group in order.
            var active_source: ?DrawSource = null;
            var active_presentation: ?CoordinatePresentation = null;
            for (self.draw_list.items) |group| {
                const texture = self.resolveTextureSlot(group.texture) orelse continue;
                const source_buffer = switch (group.source) {
                    .dynamic => self.vertex_buffer,
                    .static => self.static_vertex_buffer orelse continue,
                };

                if (active_source == null or active_source.? != group.source) {
                    var vertex_binding = c.SDL_GPUBufferBinding{
                        .buffer = source_buffer,
                        .offset = 0,
                    };
                    c.SDL_BindGPUVertexBuffers(render_pass, 0, &vertex_binding, 1);
                    active_source = group.source;
                }

                if (shouldApplyPresentationState(&active_presentation, group.presentation)) {
                    applyGroupPresentation(render_pass, command_buffer, presentation, group.presentation, self.batch.camera);
                }
                var sampler_binding = c.SDL_GPUTextureSamplerBinding{
                    .texture = texture.texture.?,
                    .sampler = self.sampler,
                };
                c.SDL_BindGPUFragmentSamplers(render_pass, 0, &sampler_binding, 1);
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

    /// Creates a renderer-owned tile-data storage buffer from a row-major tile
    /// array (one `u32` per cell) and returns its handle. Built once per dense
    /// layer at world load; the tilemap fragment shader reads it directly.
    pub fn createTileDataBuffer(self: *Renderer, tiles: []const u32) !TileDataId {
        const buffer = try gpu_buffer.uploadStorageData(self.device, tiles);
        errdefer c.SDL_ReleaseGPUBuffer(self.device, buffer);
        const index = std.math.cast(u32, self.tile_data_buffers.items.len) orelse return error.TooManyTileDataBuffers;
        if (index == @intFromEnum(TileDataId.invalid)) return error.TooManyTileDataBuffers;
        try self.tile_data_buffers.append(self.allocator, buffer);
        return @enumFromInt(index);
    }

    /// Uploads a single tile (one cell) into a tile-data buffer — the dig path.
    pub fn uploadTileDataElement(self: *Renderer, id: TileDataId, element_index: usize, value: u32) !void {
        const buffer = self.tileDataBuffer(id) orelse return error.InvalidTileDataBuffer;
        try gpu_buffer.uploadStorageElement(self.device, buffer, element_index, value);
    }

    fn tileDataBuffer(self: *const Renderer, id: TileDataId) ?*c.SDL_GPUBuffer {
        if (id == .invalid) return null;
        const index = @intFromEnum(id);
        if (index >= self.tile_data_buffers.items.len) return null;
        return self.tile_data_buffers.items[index];
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
        const texture = try gpu_texture.uploadFromPixels(self.device, pixels, width, height, pitch);
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

        const next_texture = try gpu_texture.uploadFromPixels(self.device, pixels, width, height, pitch);
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
        const needed_vertices = try std.math.mul(usize, self.batch.commands.items.len, 6);
        if (needed_vertices == 0) return;

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

        const new_vertex_buffer = try gpu_buffer.createVertexBuffer(self.device, new_capacity);
        errdefer c.SDL_ReleaseGPUBuffer(self.device, new_vertex_buffer);

        const new_vertex_transfer_buffer = try gpu_buffer.createVertexTransferBuffer(self.device, new_capacity);
        errdefer c.SDL_ReleaseGPUTransferBuffer(self.device, new_vertex_transfer_buffer);

        _ = c.SDL_WaitForGPUIdle(self.device);
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.vertex_transfer_buffer);
        c.SDL_ReleaseGPUBuffer(self.device, self.vertex_buffer);

        self.vertex_buffer = new_vertex_buffer;
        self.vertex_transfer_buffer = new_vertex_transfer_buffer;
        self.batch_capacity_vertices = new_capacity;
    }

    fn stageVertices(self: *Renderer) !void {
        try gpu_buffer.stageVertices(self.device, self.vertex_transfer_buffer, self.batch.vertices.items);
    }

    fn recordVertexUpload(self: *Renderer, command_buffer: *c.SDL_GPUCommandBuffer) !void {
        try gpu_buffer.recordVertexUpload(command_buffer, self.vertex_transfer_buffer, self.vertex_buffer, self.batch.vertices.items);
    }

    // Grows the retained static buffer to hold `needed_vertices`. Grow-only; the
    // static buffer is created lazily on first non-empty upload. Like the dynamic
    // grow path this stalls on GPU idle, but static rebuilds are infrequent.
    fn ensureStaticCapacity(self: *Renderer, needed_vertices: usize) !void {
        if (self.static_vertex_buffer != null and needed_vertices <= self.static_capacity_vertices) return;

        var new_capacity = if (self.static_capacity_vertices == 0) needed_vertices else self.static_capacity_vertices;
        while (new_capacity < needed_vertices) {
            new_capacity *= 2;
        }

        if (self.static_vertex_buffer != null) {
            // Growing an existing static buffer stalls on GPU idle below. Reserve
            // static capacity up front so this is not hit at runtime.
            log.warn("growing static vertex capacity {} -> {} vertices (GPU stall); reserve capacity to avoid this", .{ self.static_capacity_vertices, new_capacity });
        }

        const new_buffer = try gpu_buffer.createVertexBuffer(self.device, new_capacity);
        errdefer c.SDL_ReleaseGPUBuffer(self.device, new_buffer);
        const new_transfer = try gpu_buffer.createVertexTransferBuffer(self.device, new_capacity);
        errdefer c.SDL_ReleaseGPUTransferBuffer(self.device, new_transfer);

        if (self.static_vertex_buffer != null) {
            _ = c.SDL_WaitForGPUIdle(self.device);
            if (self.static_transfer_buffer) |transfer| c.SDL_ReleaseGPUTransferBuffer(self.device, transfer);
            if (self.static_vertex_buffer) |buffer| c.SDL_ReleaseGPUBuffer(self.device, buffer);
        }

        self.static_vertex_buffer = new_buffer;
        self.static_transfer_buffer = new_transfer;
        self.static_capacity_vertices = new_capacity;
    }

    fn stageStaticVertices(self: *Renderer) !void {
        try self.ensureStaticCapacity(self.static_vertices.items.len);
        try gpu_buffer.stageVertices(self.device, self.static_transfer_buffer.?, self.static_vertices.items);
    }

    fn recordStaticVertexUpload(self: *Renderer, command_buffer: *c.SDL_GPUCommandBuffer) !void {
        try gpu_buffer.recordVertexUpload(command_buffer, self.static_transfer_buffer.?, self.static_vertex_buffer.?, self.static_vertices.items);
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
        if (cur.source == group.source and
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
fn mergeDrawList(
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
        .vertex_buffer = undefined,
        .vertex_transfer_buffer = undefined,
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
        .vertex_buffer = undefined,
        .vertex_transfer_buffer = undefined,
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
        .vertex_buffer = undefined,
        .vertex_transfer_buffer = undefined,
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
