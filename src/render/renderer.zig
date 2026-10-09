// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! SDL_GPU renderer facade for app/game code.
//! CPU render prep happens before swapchain acquisition; the acquired section
//! stays limited to upload, render-pass encoding, and command submission.
//! TextureId values are generational handles backed by renderer-owned slots.

const std = @import("std");
const builtin = @import("builtin");
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
// Re-exported so game/test code can name draw-list types without importing
// sprite_batch.zig outside the render facade.
pub const DrawGroup = sprite_batch.DrawGroup;
const DrawSource = sprite_batch.DrawSource;
pub const Material = sprite_batch.Material;
pub const TilemapParams = sprite_batch.TilemapParams;
const CoordinatePresentation = sprite_batch.CoordinatePresentation;

pub const FrameResult = enum {
    submitted,
    skipped_no_swapchain,
};

pub const TileDataId = resources.TileDataId;
pub const TileStoreSpan = gpu_buffer.StorageSpan;

/// Tile blocks pack two 16-bit tile ids per `u32` element: local cell `i` lives in
/// element `i >> 1`, in the low half when `i` is even. `u32` elements avoid a 16-bit
/// storage extension; `tilemap.frag.glsl`'s `tileAt` is the matching unpack.
pub const tile_data_cells_per_element: usize = 2;
/// Fills the unread high half of a trailing element when the cell count is odd.
pub const tile_data_pad_cell: u16 = std.math.maxInt(u16);

pub fn tileDataElementCount(cell_count: usize) usize {
    return (cell_count + tile_data_cells_per_element - 1) / tile_data_cells_per_element;
}

pub fn tileDataElementIndex(cell_index: usize) usize {
    return cell_index / tile_data_cells_per_element;
}

pub fn packTileDataElement(low_cell: u16, high_cell: u16) u32 {
    return @as(u32, low_cell) | (@as(u32, high_cell) << 16);
}

/// Packs `cells` into `out` (`tileDataElementCount(cells.len)` elements).
pub fn packTileData(cells: []const u16, out: []u32) void {
    std.debug.assert(out.len == tileDataElementCount(cells.len));
    const pair_count = cells.len / tile_data_cells_per_element;
    for (out[0..pair_count], 0..) |*element, pair| {
        element.* = packTileDataElement(cells[pair * 2], cells[pair * 2 + 1]);
    }
    if (pair_count < out.len) {
        out[pair_count] = packTileDataElement(cells[cells.len - 1], tile_data_pad_cell);
    }
}

/// Tile store layout, shared with `tilemap.frag.glsl`. One `u32` buffer holds two
/// allocation classes at absolute element offsets:
/// - a directory per resident layer: `side * side` toroidal words, chunk (cx, cy) at
///   `(cy & (side - 1)) * side + (cx & (side - 1))`, then one link word holding the
///   next deeper resident layer's directory start, or `tile_store_no_link`. A word
///   with `tile_store_uniform_bit` set is a uniform chunk whose tile is the low 16
///   bits; any other word is the absolute element offset of the chunk's block.
/// - a block per resident mixed chunk-layer: `tileStoreBlockElements(chunk_edge)`
///   elements holding the chunk's tiles in local row-major order
///   (`(y % edge) * edge + x % edge`), packed by `packTileData`.
/// A draw reads only chunks inside the window its uniform names; words of chunks
/// outside it are never read.
pub const tile_store_uniform_bit: u32 = 1 << 31;
pub const tile_store_no_link: u32 = std.math.maxInt(u32);
/// Largest element count whose byte size fits SDL's `u32` buffer size and offsets.
/// Below `tile_store_uniform_bit`, so a block offset never reads as uniform.
pub const tile_store_max_elements: u32 = std.math.maxInt(u32) / @sizeOf(gpu_buffer.StorageElement);
/// Largest directory side: the largest power of two whose one directory
/// (`side * side + 1` words) fits `tile_store_max_elements`, so every directory
/// index and the shader's `side * side` fit `u32`.
pub const tile_store_max_side: u32 = 1 << 14;

comptime {
    std.debug.assert(tile_store_max_elements < tile_store_uniform_bit);
    std.debug.assert(@as(u64, tile_store_max_side) * tile_store_max_side + 1 <= tile_store_max_elements);
    std.debug.assert(@as(u64, tile_store_max_side) * 2 * tile_store_max_side * 2 + 1 > tile_store_max_elements);
}

pub fn tileStoreUniformWord(tile: u16) u32 {
    return tile_store_uniform_bit | tile;
}

pub fn tileStoreBlockElements(chunk_edge: u16) u32 {
    return @intCast(tileDataElementCount(@as(usize, chunk_edge) * chunk_edge));
}

/// One world's tile store. `params.layer_meta[2]` is the chunk shift (`log2` of the
/// chunk edge), `params.layer_meta[3]` the directory side, and `params.window` the
/// resident chunk window (`setTileStoreWindow` moves it).
pub const TileStoreDesc = struct {
    element_capacity: u32,
    params: TilemapParams,
};

pub fn validateTileStoreDesc(desc: TileStoreDesc) error{InvalidTileStoreLayout}!void {
    const shift = desc.params.layer_meta[2];
    if (shift < 0 or shift > 4) return error.InvalidTileStoreLayout;
    const side = desc.params.layer_meta[3];
    if (side < 1 or side > tile_store_max_side or !std.math.isPowerOfTwo(@as(u32, @intCast(side)))) {
        return error.InvalidTileStoreLayout;
    }
    const grid_w = desc.params.grid[1];
    const grid_h = desc.params.grid[2];
    if (!(grid_w >= 1 and grid_w <= std.math.maxInt(u16) and grid_h >= 1 and grid_h <= std.math.maxInt(u16))) {
        return error.InvalidTileStoreLayout;
    }
    if (desc.element_capacity < 1 or desc.element_capacity > tile_store_max_elements) {
        return error.InvalidTileStoreLayout;
    }
}

/// Element capacity after growing a store to hold `required` elements: at least
/// double the current capacity, clamped to `tile_store_max_elements`.
fn tileStoreGrownCapacity(current: u32, required: u32) error{GpuBufferTooLarge}!u32 {
    if (required <= current) return current;
    if (required > tile_store_max_elements) return error.GpuBufferTooLarge;
    const doubled = @as(u64, current) * 2;
    return @intCast(@min(@max(@as(u64, required), doubled), tile_store_max_elements));
}

/// The ranges of a grown store's previous contents to copy forward: elements
/// `[0, source_elements)` less the pending spans (sorted), which overwrite theirs in
/// the same copy pass, so no element is written twice.
const GrowthCopySegments = struct {
    spans: []const TileStoreSpan,
    source_elements: u32,
    cursor: u32 = 0,
    span_index: usize = 0,

    fn next(self: *GrowthCopySegments) ?TileStoreSpan {
        while (self.cursor < self.source_elements) {
            if (self.span_index == self.spans.len) {
                const tail = TileStoreSpan{ .dst_element = self.cursor, .count = self.source_elements - self.cursor };
                self.cursor = self.source_elements;
                return tail;
            }
            const span = self.spans[self.span_index];
            if (span.dst_element <= self.cursor) {
                self.cursor = @max(self.cursor, @as(u32, @intCast(@min(span.end(), self.source_elements))));
                self.span_index += 1;
                continue;
            }
            const segment_end = @min(span.dst_element, self.source_elements);
            const segment = TileStoreSpan{ .dst_element = self.cursor, .count = segment_end - self.cursor };
            self.cursor = segment_end;
            return segment;
        }
        return null;
    }
};

/// Folds a new batch into a store's batch still pending from a skipped frame. Both
/// are sorted and disjoint, and any old and new span are disjoint or nested: a new
/// span covering an old one replaces it, and a new span inside an old one patches
/// the old span's values in place. `out_*` must hold both batches.
fn mergeTileStoreSpans(
    old_spans: []const TileStoreSpan,
    old_values: []u32,
    new_spans: []const TileStoreSpan,
    new_values: []const u32,
    out_spans: *std.ArrayList(TileStoreSpan),
    out_values: *std.ArrayList(u32),
) void {
    std.debug.assert(out_spans.capacity - out_spans.items.len >= old_spans.len + new_spans.len);
    std.debug.assert(out_values.capacity - out_values.items.len >= old_values.len + new_values.len);
    var old_index: usize = 0;
    var old_value: usize = 0;
    var new_index: usize = 0;
    var new_value: usize = 0;
    while (old_index < old_spans.len or new_index < new_spans.len) {
        const take_old = if (new_index == new_spans.len)
            true
        else if (old_index == old_spans.len)
            false
        else blk: {
            const old = old_spans[old_index];
            const new = new_spans[new_index];
            if (old.end() <= new.dst_element) break :blk true;
            if (new.end() <= old.dst_element) break :blk false;
            if (new.dst_element <= old.dst_element and old.end() <= new.end()) {
                old_value += old.count;
                old_index += 1;
                continue;
            }
            std.debug.assert(old.dst_element <= new.dst_element and new.end() <= old.end());
            const patch_start = old_value + (new.dst_element - old.dst_element);
            @memcpy(old_values[patch_start..][0..new.count], new_values[new_value..][0..new.count]);
            new_value += new.count;
            new_index += 1;
            continue;
        };
        if (take_old) {
            const old = old_spans[old_index];
            out_spans.appendAssumeCapacity(old);
            out_values.appendSliceAssumeCapacity(old_values[old_value..][0..old.count]);
            old_value += old.count;
            old_index += 1;
        } else {
            const new = new_spans[new_index];
            out_spans.appendAssumeCapacity(new);
            out_values.appendSliceAssumeCapacity(new_values[new_value..][0..new.count]);
            new_value += new.count;
            new_index += 1;
        }
    }
}

// One world's GPU tile store. A retired slot has a null buffer and a generation
// already advanced past every id issued for it.
const TileStore = struct {
    buffer: ?*c.SDL_GPUBuffer,
    // Generation the slot's current (or next) store is issued under.
    generation: u32 = 1,
    // Set by `createTileStore` and `claimTileStore`; cleared by the `endFrame`
    // sweep, which retires a live store still unclaimed.
    claimed: bool = false,
    element_capacity: u32,
    // Grid, atlas, chunk geometry, and resident window; each draw adds its chain.
    params: TilemapParams,
    // Uploads not yet recorded, sorted and disjoint; values concatenated in span order.
    pending_spans: std.ArrayList(TileStoreSpan) = .empty,
    pending_values: std.ArrayList(u32) = .empty,
    // After a growth not yet recorded: the buffer holding the last recorded contents.
    growth_source: ?*c.SDL_GPUBuffer = null,
    growth_source_elements: u32 = 0,
    // First transfer element of this store's values staged this frame.
    staged_first_element: u32 = 0,

    const released = TileStore{
        .buffer = null,
        .element_capacity = 0,
        .params = std.mem.zeroes(TilemapParams),
    };
};

// GPU buffers a retired tile store held, for the caller to release.
const RetiredTileStore = struct {
    buffer: *c.SDL_GPUBuffer,
    growth_source: ?*c.SDL_GPUBuffer,
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
    pub const k_overlay_command_headroom: usize = 16;

    /// Headroom for stacked-state UI rects/text submitted after gameplay enqueue
    /// (pause panel, menus) before the debug overlay reserve in `Engine`.
    pub const k_stacked_state_ui_headroom: usize = 32;

    // `Engine`'s post-render top-up (`spriteCommandCount() + k_overlay_command_headroom`)
    // reserves against the same grow-only `command_high_water` as the state's own
    // upfront reserve, without the caller re-adding `k_stacked_state_ui_headroom`. This
    // stays allocation-free only because `std.ArrayList.ensureTotalCapacity`'s
    // amortized growth on the state's reserve already covers the extra headroom,
    // which requires stacked-UI headroom to be at least double the overlay headroom.
    // See "engine overlay top-up after stacked UI fully consumes its headroom stays
    // allocation-free" for the empirical proof this depends on too.
    comptime {
        std.debug.assert(k_stacked_state_ui_headroom >= 2 * k_overlay_command_headroom);
    }

    /// One tilemap draw's layers: the directory start of its topmost layer in the
    /// world's tile store and how many layers its chain walks (each directory's link
    /// word names the next deeper one). The fragment shader stops at the first
    /// opaque cell. `is_shallowest_bucket` is true only for the composite draw
    /// holding the frame's overall shallowest submitted dense layer
    /// (`world_system.zig`'s `submitStaticDenseGeometry`): the shader's rim shadow
    /// gates on it rather than on its own draw-local resolved depth, since bucket
    /// splitting for an unrelated interleave point can put a hole-revealed tile at
    /// resolved depth 0 within a deeper draw.
    pub const TilemapWindowLayers = struct {
        first_directory: u32 = 0,
        count: u32 = 0,
        is_shallowest_bucket: bool = false,
    };

    /// Fills the per-draw fields of `params` (`layer_meta[0..2]`, `chain[0]`) from
    /// `window` right before the fragment uniform push. Pure and GPU-free.
    pub fn applyWindowLayers(params: *TilemapParams, window: TilemapWindowLayers) void {
        params.layer_meta[0] = @intCast(window.count);
        params.layer_meta[1] = @intFromBool(window.is_shallowest_bucket);
        params.chain[0] = window.first_directory;
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
    // Per-world GPU tile stores (`createTileStore`), indexed by `TileDataId.index`.
    // Renderer-owned so a world keeps only its non-owning handle. Retired slots are
    // reused from `tile_store_free`, whose capacity always covers every slot.
    tile_stores: std.ArrayList(TileStore) = .empty,
    tile_store_free: std.ArrayList(u32) = .empty,
    // Grow-only scratch for folding a new batch into one carried from a skipped frame.
    tile_merge_spans: std.ArrayList(TileStoreSpan) = .empty,
    tile_merge_values: std.ArrayList(u32) = .empty,
    // Pooled transfer buffer holding every store's pending values for one copy pass.
    tile_upload_transfer: ?*c.SDL_GPUTransferBuffer = null,
    tile_upload_transfer_byte_size: u32 = 0,
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
    static_positions: std.ArrayList(Position) = .empty,
    static_uvs: std.ArrayList(Uv) = .empty,
    static_colors: std.ArrayList(VertexColor) = .empty,
    static_groups: std.ArrayList(DrawGroup) = .empty,
    static_dirty: bool = false,
    // Side table for tilemap DrawGroup.window_slot: the layer chain each static
    // tilemap span reads. Reset by beginStaticGeometry; populated by
    // appendStaticTilemapSpan; reserved with the static spans.
    tilemap_window_layers: std.ArrayList(TilemapWindowLayers) = .empty,
    draw_list: std.ArrayList(DrawGroup) = .empty,
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

        const sampler = try gpu_device.createSampler(device);
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
        for (self.tile_stores.items, 0..) |store, index| {
            // Slot indices fit u32: `reserveTileStoreSlot` refuses past it.
            if (store.buffer != null) self.releaseTileStoreSlot(@intCast(index));
        }
        self.tile_stores.deinit(self.allocator);
        self.tile_store_free.deinit(self.allocator);
        self.tile_merge_spans.deinit(self.allocator);
        self.tile_merge_values.deinit(self.allocator);
        if (self.tile_upload_transfer) |transfer| {
            c.SDL_ReleaseGPUTransferBuffer(self.device, transfer);
            self.tile_upload_transfer = null;
        }
        self.deinitBatchStorage();
        self.static_positions.deinit(self.allocator);
        self.static_uvs.deinit(self.allocator);
        self.static_colors.deinit(self.allocator);
        self.static_groups.deinit(self.allocator);
        self.tilemap_window_layers.deinit(self.allocator);
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
    /// allocation-free render frames. Marks the frame reserved at `command_high_water`,
    /// the same bound `ensureFrameBatchCapacity` grows past, so in perf-diagnostic builds a
    /// frame whose submits exceed it is counted as reservation drift
    /// (`SpriteBatch.commandOverflowGrows`) even when the command list's rounded-up
    /// capacity absorbed them; it still grows in every build.
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
        self.batch.markFrameReserved(self.command_high_water);
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

    /// The 1x1 opaque white texture backing solid tinted quads. Debug viz that
    /// needs a rotated solid quad (vision cones, ring arcs) builds a `Sprite`
    /// over this directly, since `submitOrderedRectInSpace` is axis-aligned only.
    pub fn whiteTexture(self: *const Renderer) TextureId {
        return self.white_texture;
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
        self.tilemap_window_layers.clearRetainingCapacity();
        self.static_dirty = true;
    }

    /// Reserves retained static storage. Setup/grow-only; call before relying on
    /// allocation-free static rebuilds.
    pub fn reserveStaticGeometry(self: *Renderer, vertex_capacity: usize, span_capacity: usize) !void {
        try self.static_positions.ensureTotalCapacity(self.allocator, vertex_capacity);
        try self.static_uvs.ensureTotalCapacity(self.allocator, vertex_capacity);
        try self.static_colors.ensureTotalCapacity(self.allocator, vertex_capacity);
        try self.static_groups.ensureTotalCapacity(self.allocator, span_capacity);
        try self.tilemap_window_layers.ensureTotalCapacity(self.allocator, span_capacity);
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

    /// Appends one retained world-space quad that composites `window_layers` (a
    /// chain of directories in the `tile_data` store, topmost first) via the
    /// tilemap pipeline: the fragment shader walks it per pixel, stopping at the
    /// first opaque cell, and samples `atlas_texture`. `vertices` are the quad's
    /// world-space corners (6). Must be called between `beginStaticGeometry` and
    /// the next `endFrame`. Allocation-free within `reserveStaticGeometry`.
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
        const end = try std.math.add(usize, self.static_positions.items.len, vertex_count);
        const first_vertex = std.math.cast(u32, self.static_positions.items.len) orelse return error.StaticGeometryTooLarge;
        _ = std.math.cast(u32, end) orelse return error.StaticGeometryTooLarge;
        // ensure-then-assumeCapacity so a prior `reserveStaticGeometry` path is
        // allocation-free (FailingAllocator success proof in tests). Unreserved
        // callers still grow here.
        try self.static_positions.ensureTotalCapacity(self.allocator, end);
        try self.static_uvs.ensureTotalCapacity(self.allocator, end);
        try self.static_colors.ensureTotalCapacity(self.allocator, end);
        try self.static_groups.ensureTotalCapacity(self.allocator, self.static_groups.items.len + 1);
        try self.tilemap_window_layers.ensureTotalCapacity(self.allocator, self.tilemap_window_layers.items.len + 1);
        const window_slot = std.math.cast(u32, self.tilemap_window_layers.items.len) orelse return error.StaticGeometryTooLarge;
        self.static_positions.appendSliceAssumeCapacity(vertices.positions);
        self.static_uvs.appendSliceAssumeCapacity(vertices.uvs);
        self.static_colors.appendSliceAssumeCapacity(vertices.colors);
        self.tilemap_window_layers.appendAssumeCapacity(window_layers);
        self.static_groups.appendAssumeCapacity(.{
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

    /// Releases a non-internal texture. Waits for GPU idle first so no in-flight
    /// frame (up to `frames_in_flight`) still samples the handle. Prefer
    /// `destroyTextureAssumeIdle` after an explicit bulk sync (e.g. text retire).
    pub fn destroyTexture(self: *Renderer, id: TextureId) void {
        const slot = self.resolveTextureSlot(id) orelse return;
        if (slot.internal) return;

        self.waitForIdle();
        self.retireTextureSlot(id.index, slot);
    }

    /// Releases a non-internal texture without waiting for GPU idle. Caller must
    /// have already synchronized (or the texture was never submitted). Used by
    /// text bulk-retire after a single `waitForIdle`.
    pub fn destroyTextureAssumeIdle(self: *Renderer, id: TextureId) void {
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

    /// Retires every tile store no owner claimed since the previous `endFrame`
    /// (`claimTileStore`), then prepares, uploads, and draws the frame.
    pub fn endFrame(self: *Renderer, thread_system: ?*ThreadSystem) !FrameResult {
        self.sweepUnclaimedTileStores();
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
        // Tile-store transfer grow (create → WaitForGPUIdle → release-old) and
        // staging also live here so a capacity stall never holds an acquired
        // swapchain and post-acquire work is record-only (matches dynamic verts).
        if (self.batch.positions.items.len > 0) {
            try self.stageVertices();
        }
        if (upload_static) {
            try self.stageStaticVertices();
        }
        const upload_tile_stores = self.tileStoreUploadsPending();
        if (upload_tile_stores) {
            try self.stageTileStoreUploads();
        }

        const frame = try self.acquireSwapchainFrame(false) orelse return .skipped_no_swapchain;
        const command_buffer = frame.command_buffer;
        const acquired_swapchain_texture = frame.swapchain_texture;
        const presentation = self.updatePresentation(window_size, .{
            .width = frame.width,
            .height = frame.height,
        });

        const upload_dynamic = self.batch.positions.items.len > 0;
        if (upload_dynamic or upload_static or upload_tile_stores) {
            self.recordFrameCopyPass(command_buffer, .{
                .dynamic = upload_dynamic,
                .static_vertices = upload_static,
                .tile_stores = upload_tile_stores,
            }) catch |err| {
                log.err("recording frame copy pass failed: {s}", .{@errorName(err)});
                return finishAcquiredCommandBufferAfterError(command_buffer, "copy pass");
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
                    .tilemap => (self.tileStore(group.tile_data) orelse continue).buffer.?,
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
                    var params = self.tileStore(group.tile_data).?.params;
                    // The per-store params carry the grid, atlas, chunk geometry, and
                    // resident window; the per-draw layer chain is set here.
                    applyWindowLayers(&params, self.tilemap_window_layers.items[group.window_slot]);
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
        ) catch unreachable; // lint:allow catch-unreachable: all inputs proven non-zero (see comment above)
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

    /// Creates a world's GPU tile store (layout documented at `tile_store_uniform_bit`) with
    /// `desc.element_capacity` elements and returns its non-owning id, claimed for
    /// the current frame. Contents are undefined until uploads are queued; draws
    /// must read only directories and blocks the owner has written. The owner
    /// claims it every frame it renders (`claimTileStore`); `endFrame` retires it
    /// the first frame nobody does, and its id goes stale.
    pub fn createTileStore(self: *Renderer, desc: TileStoreDesc) !TileDataId {
        try validateTileStoreDesc(desc);
        try self.reserveTileStoreSlot();
        const buffer = try gpu_buffer.createStorageBuffer(self.device, desc.element_capacity);
        const id = self.installTileStore(.{
            .buffer = buffer,
            .element_capacity = desc.element_capacity,
            .params = desc.params,
        });
        log.debug("created tile store {d}: {d} elements", .{ id.index, desc.element_capacity });
        return id;
    }

    /// Keeps the store alive through the next `endFrame`; returns false when `id`
    /// is stale (its store was retired), in which case the owner's GPU contents are
    /// gone and it must create a new store. O(1).
    pub fn claimTileStore(self: *Renderer, id: TileDataId) bool {
        const store = self.tileStore(id) orelse return false;
        store.claimed = true;
        return true;
    }

    /// Moves the store's resident chunk window (min x, min y, max-exclusive x,
    /// max-exclusive y), read by every later draw of the store. No-op when `id` is
    /// stale. O(1).
    pub fn setTileStoreWindow(self: *Renderer, id: TileDataId, window: [4]u32) void {
        const store = self.tileStore(id) orelse return;
        store.params.window = window;
    }

    /// Grows the store to `required_elements` when it is smaller (a new buffer; the
    /// previous contents copy forward in the next frame copy pass, then the old
    /// buffer is released) and reserves room for `span_count` spans of
    /// `value_count` values, so the matching `queueTileStoreUploads` allocates
    /// nothing. Call before swapchain acquisition.
    pub fn reserveTileStoreUploads(self: *Renderer, id: TileDataId, required_elements: u32, span_count: usize, value_count: usize) !void {
        const store = self.tileStore(id) orelse return error.InvalidTileStore;
        if (required_elements > store.element_capacity) try self.growTileStore(store, required_elements);
        try store.pending_spans.ensureUnusedCapacity(self.allocator, span_count);
        try store.pending_values.ensureUnusedCapacity(self.allocator, value_count);
        if (store.pending_spans.items.len > 0) {
            try self.tile_merge_spans.ensureTotalCapacity(self.allocator, store.pending_spans.items.len + span_count);
            try self.tile_merge_values.ensureTotalCapacity(self.allocator, store.pending_values.items.len + value_count);
        }
    }

    /// Queues one upload batch for the store, flushed in the next frame copy pass
    /// and carried across skipped frames. `spans` must be sorted, disjoint, and
    /// inside the store, with `values` holding their elements in span order; every
    /// span of a carried batch must be disjoint from or nested with every new span,
    /// and the newer values win. Allocation-free after `reserveTileStoreUploads`.
    pub fn queueTileStoreUploads(self: *Renderer, id: TileDataId, spans: []const TileStoreSpan, values: []const u32) !void {
        const store = self.tileStore(id) orelse return error.InvalidTileStore;
        try gpu_buffer.validateStorageSpans(spans, values.len, store.element_capacity);
        if (spans.len == 0) return;
        if (store.pending_spans.items.len == 0) {
            try store.pending_spans.appendSlice(self.allocator, spans);
            try store.pending_values.appendSlice(self.allocator, values);
            return;
        }
        self.tile_merge_spans.clearRetainingCapacity();
        self.tile_merge_values.clearRetainingCapacity();
        try self.tile_merge_spans.ensureTotalCapacity(self.allocator, store.pending_spans.items.len + spans.len);
        try self.tile_merge_values.ensureTotalCapacity(self.allocator, store.pending_values.items.len + values.len);
        mergeTileStoreSpans(
            store.pending_spans.items,
            store.pending_values.items,
            spans,
            values,
            &self.tile_merge_spans,
            &self.tile_merge_values,
        );
        std.mem.swap(std.ArrayList(TileStoreSpan), &store.pending_spans, &self.tile_merge_spans);
        std.mem.swap(std.ArrayList(u32), &store.pending_values, &self.tile_merge_values);
    }

    // Makes the next `installTileStore` infallible: a retired slot, or room for a
    // new one in both the store list and the free list (which retire pushes to).
    fn reserveTileStoreSlot(self: *Renderer) error{ OutOfMemory, TooManyTileStores }!void {
        if (self.tile_store_free.items.len > 0) return;
        const appended = std.math.cast(u32, self.tile_stores.items.len) orelse return error.TooManyTileStores;
        if (appended == TileDataId.invalid.index) return error.TooManyTileStores;
        try self.tile_stores.ensureUnusedCapacity(self.allocator, 1);
        try self.tile_store_free.ensureTotalCapacity(self.allocator, self.tile_stores.items.len + 1);
    }

    // Places `store` in a retired slot under that slot's generation, or appends it
    // at generation 1, claimed. Requires `reserveTileStoreSlot`.
    fn installTileStore(self: *Renderer, store: TileStore) TileDataId {
        std.debug.assert(store.buffer != null);
        if (self.tile_store_free.pop()) |index| {
            const slot = &self.tile_stores.items[index];
            std.debug.assert(slot.buffer == null);
            const generation = slot.generation;
            slot.* = store;
            slot.generation = generation;
            slot.claimed = true;
            return .{ .index = index, .generation = generation };
        }
        // `reserveTileStoreSlot` bounded the length below `TileDataId.invalid.index`.
        const index: u32 = @intCast(self.tile_stores.items.len);
        std.debug.assert(self.tile_store_free.capacity >= self.tile_stores.items.len + 1);
        self.tile_stores.appendAssumeCapacity(store);
        const slot = &self.tile_stores.items[index];
        slot.generation = 1;
        slot.claimed = true;
        return .{ .index = index, .generation = 1 };
    }

    // Returns the first live store at or after `cursor` that nobody claimed since
    // the last sweep, clearing the claim of every claimed store it passes. Touches
    // no SDL state.
    fn nextUnclaimedTileStore(self: *Renderer, cursor: u32) ?u32 {
        var index: usize = cursor;
        while (index < self.tile_stores.items.len) : (index += 1) {
            const store = &self.tile_stores.items[index];
            if (store.buffer == null) continue;
            if (store.claimed) {
                store.claimed = false;
                continue;
            }
            // Below the slot count, which fits u32 (`reserveTileStoreSlot`).
            return @intCast(index);
        }
        return null;
    }

    // Retires every store unclaimed since the last sweep, so a destroyed or
    // replaced world's store goes at the first frame it does not render. O(live
    // stores); SDL frees the buffers once in-flight frames finish, so no drain.
    fn sweepUnclaimedTileStores(self: *Renderer) void {
        var cursor: u32 = 0;
        while (self.nextUnclaimedTileStore(cursor)) |index| {
            self.releaseTileStoreSlot(index);
            cursor = index + 1;
        }
    }

    // Retires a live slot without touching SDL: frees its pending upload lists,
    // advances its generation so every issued id goes stale (the
    // `retireTextureSlotForReuse` pattern), and returns it to the free list.
    // Retained draws naming it are skipped from the sweeping `endFrame`'s draw
    // loop onward.
    fn retireTileStoreSlot(self: *Renderer, index: u32) RetiredTileStore {
        const store = &self.tile_stores.items[index];
        const retired = RetiredTileStore{ .buffer = store.buffer.?, .growth_source = store.growth_source };
        store.pending_spans.deinit(self.allocator);
        store.pending_values.deinit(self.allocator);
        const generation = resources.nextGeneration(store.generation);
        store.* = TileStore.released;
        store.generation = generation;
        std.debug.assert(self.tile_store_free.items.len < self.tile_store_free.capacity);
        self.tile_store_free.appendAssumeCapacity(index);
        return retired;
    }

    // Retires a live slot and releases its GPU buffers; SDL defers the free past
    // in-flight frames.
    fn releaseTileStoreSlot(self: *Renderer, index: u32) void {
        const retired = self.retireTileStoreSlot(index);
        c.SDL_ReleaseGPUBuffer(self.device, retired.buffer);
        if (retired.growth_source) |source| c.SDL_ReleaseGPUBuffer(self.device, source);
    }

    fn growTileStore(self: *Renderer, store: *TileStore, required_elements: u32) !void {
        const capacity = try tileStoreGrownCapacity(store.element_capacity, required_elements);
        const grown = try gpu_buffer.createStorageBuffer(self.device, capacity);
        if (store.growth_source == null) {
            store.growth_source = store.buffer;
            store.growth_source_elements = store.element_capacity;
        } else {
            // No frame recorded the replaced buffer; `growth_source` still holds the contents.
            c.SDL_ReleaseGPUBuffer(self.device, store.buffer.?);
        }
        store.buffer = grown;
        store.element_capacity = capacity;
        log.debug("grew tile store to {d} elements", .{capacity});
    }

    fn tileStoreUploadsPending(self: *const Renderer) bool {
        for (self.tile_stores.items) |store| {
            if (store.buffer == null) continue;
            if (store.pending_spans.items.len > 0 or store.growth_source != null) return true;
        }
        return false;
    }

    // Stages every store's pending values into the pooled transfer buffer
    // (cycle=true, so a reused transfer never overwrites an in-flight copy) and
    // records where each store's values start. Pre-acquire; the copy pass only records.
    fn stageTileStoreUploads(self: *Renderer) !void {
        var total: usize = 0;
        for (self.tile_stores.items) |*store| {
            if (store.buffer == null) continue;
            store.staged_first_element = std.math.cast(u32, total) orelse return error.GpuBufferTooLarge;
            total += store.pending_values.items.len;
        }
        if (total == 0) return;
        try self.ensureTileUploadTransfer(try gpu_buffer.storageByteSize(total));
        const transfer = self.tile_upload_transfer.?;
        const mapped = c.SDL_MapGPUTransferBuffer(self.device, transfer, true) orelse {
            return sdlError("SDL_MapGPUTransferBuffer");
        };
        const staged = @as([*]u32, @ptrCast(@alignCast(mapped)))[0..total];
        for (self.tile_stores.items) |store| {
            if (store.buffer == null) continue;
            @memcpy(staged[store.staged_first_element..][0..store.pending_values.items.len], store.pending_values.items);
        }
        c.SDL_UnmapGPUTransferBuffer(self.device, transfer);
    }

    // Mirrors `ensureBatchCapacity`: create the new transfer first, idle the GPU,
    // then release the old one, so a creation failure leaves the live transfer
    // untouched and no in-flight copy still reads a freed buffer.
    fn ensureTileUploadTransfer(self: *Renderer, required_bytes: u32) !void {
        if (self.tile_upload_transfer) |existing| {
            if (self.tile_upload_transfer_byte_size >= required_bytes) return;

            const new_transfer = try gpu_buffer.createVertexTransferBuffer(self.device, required_bytes);
            errdefer c.SDL_ReleaseGPUTransferBuffer(self.device, new_transfer);

            _ = c.SDL_WaitForGPUIdle(self.device);
            c.SDL_ReleaseGPUTransferBuffer(self.device, existing);
            self.tile_upload_transfer = new_transfer;
            self.tile_upload_transfer_byte_size = required_bytes;
            return;
        }

        self.tile_upload_transfer = try gpu_buffer.createVertexTransferBuffer(self.device, required_bytes);
        self.tile_upload_transfer_byte_size = required_bytes;
    }

    fn tileStore(self: *const Renderer, id: TileDataId) ?*TileStore {
        if (!id.isValid()) return null;
        if (id.index >= self.tile_stores.items.len) return null;
        const store = &self.tile_stores.items[id.index];
        if (store.buffer == null or store.generation != id.generation) return null;
        return store;
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

    /// Replaces a non-internal texture's GPU image. Creates the new upload first,
    /// then waits for GPU idle before releasing the old handle so in-flight frames
    /// (up to `frames_in_flight`) never sample a freed texture.
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

        self.waitForIdle();
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
        // Over-submission beyond the reserved `command_high_water` is handled the same
        // way in Debug and ReleaseFast. `drawSprite` already grew the command list if
        // needed and, in a reserved frame of a perf-diagnostic build, counted crossing this
        // same bound as drift (`SpriteBatch.commandOverflowGrows`); this fallback grows prepared/vertex/group
        // storage and the GPU streams before the threaded emit. There is no hard submit
        // bound. A Debug-only assert against `command_high_water` would panic where
        // ReleaseFast regrows.
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
        tile_stores: bool = false,
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
        // Tile-store uploads are excluded: they write retained stores in part.
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

        if (work.tile_stores) {
            // Values were staged pre-acquire; this only records. A grown store first
            // copies its previous contents forward, skipping the elements its
            // pending spans overwrite, so no element is written twice in the pass.
            for (self.tile_stores.items) |*store| {
                const buffer = store.buffer orelse continue;
                if (store.growth_source) |source| {
                    var segments = GrowthCopySegments{
                        .spans = store.pending_spans.items,
                        .source_elements = store.growth_source_elements,
                    };
                    while (segments.next()) |segment| {
                        try gpu_buffer.recordStorageCopyInPass(copy_pass_scope.pass, source, buffer, segment.dst_element, segment.count);
                    }
                }
                if (store.pending_spans.items.len > 0) {
                    try gpu_buffer.recordStorageSpansInPass(
                        copy_pass_scope.pass,
                        self.tile_upload_transfer.?,
                        self.tile_upload_transfer_byte_size,
                        store.staged_first_element,
                        buffer,
                        store.element_capacity,
                        store.pending_spans.items,
                    );
                }
                if (store.growth_source) |source| {
                    c.SDL_ReleaseGPUBuffer(self.device, source);
                    store.growth_source = null;
                }
                store.pending_spans.clearRetainingCapacity();
                store.pending_values.clearRetainingCapacity();
            }
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
    const a_domain = @backingInt(a.order.domain);
    const b_domain = @backingInt(b.order.domain);
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
    out: *std.ArrayList(DrawGroup),
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
    var list: std.ArrayList(DrawGroup) = .empty;
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
    try batch.buildSerial(resolver);
    try std.testing.expectEqual(@as(usize, 2), batch.draw_groups.items.len);

    var list: std.ArrayList(DrawGroup) = .empty;
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
    var list: std.ArrayList(DrawGroup) = .empty;
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
    var list: std.ArrayList(DrawGroup) = .empty;
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
    var list: std.ArrayList(DrawGroup) = .empty;
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
    var list: std.ArrayList(DrawGroup) = .empty;
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
    var list: std.ArrayList(DrawGroup) = .empty;
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

test "packTileData packs two cells per element low half first and pads an odd tail" {
    const cells = [_]u16{ 0x0001, 0x0002, 0xABCD, 0xFFFF, 0x0007 };
    var elements: [tileDataElementCount(cells.len)]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 3), elements.len);
    packTileData(&cells, &elements);

    try std.testing.expectEqual(@as(u32, 0x0002_0001), elements[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFF_ABCD), elements[1]);
    try std.testing.expectEqual(@as(u32, 0x0007) | (@as(u32, tile_data_pad_cell) << 16), elements[2]);

    // Every cell unpacks from its element exactly as tilemap.frag.glsl's tileAt does.
    for (cells, 0..) |cell, flat| {
        const element = elements[tileDataElementIndex(flat)];
        const shift: u5 = @intCast((flat & 1) * 16);
        try std.testing.expectEqual(cell, @as(u16, @truncate(element >> shift)));
    }
}

test "mergeTileStoreSpans replaces covered carried spans and patches nested ones" {
    const allocator = std.testing.allocator;
    // Carried: a directory word (0), a block (8..12), a single element (20).
    const old_spans = [_]TileStoreSpan{
        .{ .dst_element = 0, .count = 1 },
        .{ .dst_element = 8, .count = 4 },
        .{ .dst_element = 20, .count = 1 },
    };
    var old_values = [_]u32{ 1, 10, 11, 12, 13, 2 };
    // New: a whole directory covering element 0, an element inside the carried block,
    // the same single element again, and a disjoint element.
    const new_spans = [_]TileStoreSpan{
        .{ .dst_element = 0, .count = 4 },
        .{ .dst_element = 10, .count = 1 },
        .{ .dst_element = 16, .count = 1 },
        .{ .dst_element = 20, .count = 1 },
    };
    const new_values = [_]u32{ 100, 101, 102, 103, 99, 50, 3 };
    var out_spans: std.ArrayList(TileStoreSpan) = .empty;
    defer out_spans.deinit(allocator);
    var out_values: std.ArrayList(u32) = .empty;
    defer out_values.deinit(allocator);
    try out_spans.ensureTotalCapacity(allocator, old_spans.len + new_spans.len);
    try out_values.ensureTotalCapacity(allocator, old_values.len + new_values.len);

    mergeTileStoreSpans(&old_spans, &old_values, &new_spans, &new_values, &out_spans, &out_values);

    try std.testing.expectEqualSlices(TileStoreSpan, &.{
        .{ .dst_element = 0, .count = 4 },
        .{ .dst_element = 8, .count = 4 },
        .{ .dst_element = 16, .count = 1 },
        .{ .dst_element = 20, .count = 1 },
    }, out_spans.items);
    try std.testing.expectEqualSlices(u32, &.{ 100, 101, 102, 103, 10, 11, 99, 13, 50, 3 }, out_values.items);
    try gpu_buffer.validateStorageSpans(out_spans.items, out_values.items.len, 24);
}

test "growth copy segments skip the elements pending spans overwrite" {
    const spans = [_]TileStoreSpan{
        .{ .dst_element = 0, .count = 2 },
        .{ .dst_element = 5, .count = 1 },
        .{ .dst_element = 9, .count = 4 },
        .{ .dst_element = 20, .count = 1 },
    };
    var segments = GrowthCopySegments{ .spans = &spans, .source_elements = 12 };
    var copied: [3]TileStoreSpan = undefined;
    var count: usize = 0;
    while (segments.next()) |segment| {
        copied[count] = segment;
        count += 1;
    }
    try std.testing.expectEqualSlices(TileStoreSpan, &.{
        .{ .dst_element = 2, .count = 3 },
        .{ .dst_element = 6, .count = 3 },
    }, copied[0..count]);

    var whole = GrowthCopySegments{ .spans = &.{}, .source_elements = 7 };
    try std.testing.expectEqual(TileStoreSpan{ .dst_element = 0, .count = 7 }, whole.next().?);
    try std.testing.expectEqual(@as(?TileStoreSpan, null), whole.next());
}

test "tile store growth at least doubles, covers the request, and clamps to the SDL width" {
    try std.testing.expectEqual(@as(u32, 80), try tileStoreGrownCapacity(80, 80));
    try std.testing.expectEqual(@as(u32, 160), try tileStoreGrownCapacity(80, 81));
    try std.testing.expectEqual(@as(u32, 500), try tileStoreGrownCapacity(80, 500));
    try std.testing.expectEqual(@as(u32, 2), try tileStoreGrownCapacity(1, 2));
    const near_max = tile_store_max_elements - 8;
    try std.testing.expectEqual(tile_store_max_elements, try tileStoreGrownCapacity(near_max - 1000, near_max));
    try std.testing.expectError(error.GpuBufferTooLarge, tileStoreGrownCapacity(80, tile_store_max_elements + 1));
}

test "tile store layout bounds the chunk shift, directory side, grid, and capacity" {
    var params = TilemapParams{ .grid = .{ 16, 10, 6, 65535 }, .atlas = .{ 1, 1, 1, 16 } };
    params.layer_meta[2] = 2;
    params.layer_meta[3] = 4;
    const desc = TileStoreDesc{ .element_capacity = 17, .params = params };
    try validateTileStoreDesc(desc);
    var edge = desc;
    edge.params.layer_meta[3] = @intCast(tile_store_max_side);
    edge.element_capacity = tile_store_max_elements;
    try validateTileStoreDesc(edge);
    edge.params.layer_meta[3] = 1;
    edge.element_capacity = 1;
    try validateTileStoreDesc(edge);

    var wrong = desc;
    wrong.params.layer_meta[3] = 3;
    try std.testing.expectError(error.InvalidTileStoreLayout, validateTileStoreDesc(wrong));
    wrong.params.layer_meta[3] = 0;
    try std.testing.expectError(error.InvalidTileStoreLayout, validateTileStoreDesc(wrong));
    wrong.params.layer_meta[3] = @intCast(tile_store_max_side * 2);
    try std.testing.expectError(error.InvalidTileStoreLayout, validateTileStoreDesc(wrong));
    wrong = desc;
    wrong.params.layer_meta[2] = 5;
    try std.testing.expectError(error.InvalidTileStoreLayout, validateTileStoreDesc(wrong));
    wrong = desc;
    wrong.params.grid[1] = 0;
    try std.testing.expectError(error.InvalidTileStoreLayout, validateTileStoreDesc(wrong));
    wrong = desc;
    wrong.element_capacity = 0;
    try std.testing.expectError(error.InvalidTileStoreLayout, validateTileStoreDesc(wrong));
    wrong.element_capacity = tile_store_max_elements + 1;
    try std.testing.expectError(error.InvalidTileStoreLayout, validateTileStoreDesc(wrong));
    try std.testing.expectEqual(@as(u32, 1), tileStoreBlockElements(1));
    try std.testing.expectEqual(@as(u32, 128), tileStoreBlockElements(16));
}

test "setTileStoreWindow moves a live store's window and ignores a stale id" {
    var renderer = testRenderer(std.testing.allocator);
    defer deinitTileStoreTestRenderer(&renderer);
    const id = try testInstallTileStore(&renderer, 0x1000);
    renderer.setTileStoreWindow(id, .{ 3, 4, 7, 8 });
    try std.testing.expectEqual([4]u32{ 3, 4, 7, 8 }, renderer.tileStore(id).?.params.window);
    renderer.setTileStoreWindow(.{ .index = id.index, .generation = id.generation + 1 }, .{ 0, 0, 1, 1 });
    try std.testing.expectEqual([4]u32{ 3, 4, 7, 8 }, renderer.tileStore(id).?.params.window);
}

test "queueTileStoreUploads folds a carried batch allocation-free after reserve" {
    const allocator = std.testing.allocator;
    var renderer = testRenderer(allocator);
    defer renderer.batch.deinit();
    defer renderer.tile_stores.deinit(allocator);
    defer renderer.tile_merge_spans.deinit(allocator);
    defer renderer.tile_merge_values.deinit(allocator);
    // Fake GPU handle: queueing only validates and records, never touches SDL.
    try renderer.tile_stores.append(allocator, .{
        .buffer = @ptrFromInt(0x1000),
        .element_capacity = 64,
        .params = std.mem.zeroes(TilemapParams),
    });
    const store = &renderer.tile_stores.items[0];
    defer store.pending_spans.deinit(allocator);
    defer store.pending_values.deinit(allocator);
    const id = TileDataId{ .index = 0, .generation = 1 };

    const first_spans = [_]TileStoreSpan{ .{ .dst_element = 3, .count = 1 }, .{ .dst_element = 32, .count = 8 } };
    const first_values = [_]u32{ 7, 0, 1, 2, 3, 4, 5, 6, 7 };
    try renderer.reserveTileStoreUploads(id, 40, first_spans.len, first_values.len);
    // A batch no frame recorded stays pending and the next one folds into it.
    const second_spans = [_]TileStoreSpan{ .{ .dst_element = 3, .count = 1 }, .{ .dst_element = 34, .count = 1 }, .{ .dst_element = 40, .count = 8 } };
    const second_values = [_]u32{ 8, 22, 9, 9, 9, 9, 9, 9, 9, 9 };
    {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        renderer.allocator = failing.allocator();
        defer renderer.allocator = allocator;
        try renderer.queueTileStoreUploads(id, &first_spans, &first_values);
        try std.testing.expectError(error.OutOfMemory, renderer.reserveTileStoreUploads(id, 48, second_spans.len, second_values.len));
    }
    try renderer.reserveTileStoreUploads(id, 48, second_spans.len, second_values.len);
    {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        renderer.allocator = failing.allocator();
        defer renderer.allocator = allocator;
        try renderer.queueTileStoreUploads(id, &second_spans, &second_values);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    }
    try std.testing.expectEqualSlices(TileStoreSpan, &.{
        .{ .dst_element = 3, .count = 1 },
        .{ .dst_element = 32, .count = 8 },
        .{ .dst_element = 40, .count = 8 },
    }, store.pending_spans.items);
    try std.testing.expectEqualSlices(u32, &.{ 8, 0, 1, 22, 3, 4, 5, 6, 7, 9, 9, 9, 9, 9, 9, 9, 9 }, store.pending_values.items);
    // Out of bounds, unsorted, or a stale handle never reaches the queue.
    try std.testing.expectError(error.GpuUploadOutOfBounds, renderer.queueTileStoreUploads(id, &.{.{ .dst_element = 63, .count = 2 }}, &.{ 1, 2 }));
    try std.testing.expectError(error.InvalidTileStore, renderer.queueTileStoreUploads(.{ .index = 1, .generation = 1 }, &.{}, &.{}));
    try std.testing.expectError(error.InvalidTileStore, renderer.queueTileStoreUploads(.{ .index = 0, .generation = 2 }, &.{}, &.{}));
    try std.testing.expectEqual(@as(usize, 3), store.pending_spans.items.len);
}

// Installs a store with a fake GPU handle; the sweep and retire tests only
// record and compare it, never pass it to SDL.
fn testInstallTileStore(renderer: *Renderer, buffer_address: usize) !TileDataId {
    try renderer.reserveTileStoreSlot();
    return renderer.installTileStore(.{
        .buffer = @ptrFromInt(buffer_address),
        .element_capacity = 64,
        .params = std.mem.zeroes(TilemapParams),
    });
}

fn deinitTileStoreTestRenderer(renderer: *Renderer) void {
    for (renderer.tile_stores.items) |*store| {
        store.pending_spans.deinit(renderer.allocator);
        store.pending_values.deinit(renderer.allocator);
    }
    renderer.tile_stores.deinit(renderer.allocator);
    renderer.tile_store_free.deinit(renderer.allocator);
    renderer.tile_merge_spans.deinit(renderer.allocator);
    renderer.tile_merge_values.deinit(renderer.allocator);
    renderer.batch.deinit();
}

test "an unclaimed tile store is retired by the sweep and its id goes stale; a claimed store survives with its claim cleared" {
    var renderer = testRenderer(std.testing.allocator);
    defer deinitTileStoreTestRenderer(&renderer);
    const kept = try testInstallTileStore(&renderer, 0x1000);
    const dropped = try testInstallTileStore(&renderer, 0x2000);
    // Uploads still pending on a retired store are freed with it.
    try renderer.reserveTileStoreUploads(dropped, 8, 1, 2);
    try renderer.queueTileStoreUploads(dropped, &.{.{ .dst_element = 0, .count = 2 }}, &.{ 1, 2 });

    // First sweep: creation claimed both for their first frame.
    try std.testing.expectEqual(@as(?u32, null), renderer.nextUnclaimedTileStore(0));
    // Second sweep: only `kept` was claimed again.
    try std.testing.expect(renderer.claimTileStore(kept));
    try std.testing.expectEqual(@as(?u32, dropped.index), renderer.nextUnclaimedTileStore(0));
    const retired = renderer.retireTileStoreSlot(dropped.index);
    try std.testing.expectEqual(@as(usize, 0x2000), @intFromPtr(retired.buffer));
    try std.testing.expectEqual(@as(?*c.SDL_GPUBuffer, null), retired.growth_source);
    try std.testing.expectEqual(@as(?u32, null), renderer.nextUnclaimedTileStore(dropped.index + 1));

    try std.testing.expect(renderer.tileStore(dropped) == null);
    try std.testing.expect(!renderer.claimTileStore(dropped));
    try std.testing.expectError(error.InvalidTileStore, renderer.queueTileStoreUploads(dropped, &.{}, &.{}));
    const survivor = renderer.tileStore(kept).?;
    try std.testing.expect(!survivor.claimed);
    // Third sweep: `kept` was not claimed this time.
    try std.testing.expectEqual(@as(?u32, kept.index), renderer.nextUnclaimedTileStore(0));
}

test "a tile store retired mid-growth hands back both buffers and leaves a clean slot" {
    var renderer = testRenderer(std.testing.allocator);
    defer deinitTileStoreTestRenderer(&renderer);
    const id = try testInstallTileStore(&renderer, 0x1000);
    // A growth no frame recorded yet: the replaced buffer still holds the contents.
    renderer.tileStore(id).?.growth_source = @ptrFromInt(0x2000);
    renderer.tileStore(id).?.growth_source_elements = 32;

    const retired = renderer.retireTileStoreSlot(id.index);
    try std.testing.expectEqual(@as(usize, 0x1000), @intFromPtr(retired.buffer));
    try std.testing.expectEqual(@as(usize, 0x2000), @intFromPtr(retired.growth_source.?));
    const slot = renderer.tile_stores.items[id.index];
    try std.testing.expectEqual(@as(?*c.SDL_GPUBuffer, null), slot.buffer);
    try std.testing.expectEqual(@as(?*c.SDL_GPUBuffer, null), slot.growth_source);
    try std.testing.expectEqual(@as(u32, 0), slot.growth_source_elements);
    // Nothing is left for the frame copy pass to stage or record.
    try std.testing.expect(!renderer.tileStoreUploadsPending());
    try std.testing.expectEqual(@as(?u32, null), renderer.nextUnclaimedTileStore(0));
}

test "a retired tile store slot is reused under a new generation and the old id stays stale" {
    const allocator = std.testing.allocator;
    var renderer = testRenderer(allocator);
    defer deinitTileStoreTestRenderer(&renderer);
    const first = try testInstallTileStore(&renderer, 0x1000);
    _ = renderer.retireTileStoreSlot(first.index);

    // Reuse, retire, and reuse again allocate nothing once a slot is reserved.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    renderer.allocator = failing.allocator();
    const second = try testInstallTileStore(&renderer, 0x2000);
    _ = renderer.retireTileStoreSlot(second.index);
    const third = try testInstallTileStore(&renderer, 0x3000);
    renderer.allocator = allocator;
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);

    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expectEqual(first.index, third.index);
    try std.testing.expectEqual(resources.nextGeneration(first.generation), second.generation);
    try std.testing.expectEqual(resources.nextGeneration(second.generation), third.generation);
    try std.testing.expectEqual(@as(usize, 1), renderer.tile_stores.items.len);
    try std.testing.expect(renderer.tileStore(first) == null);
    try std.testing.expect(renderer.tileStore(second) == null);
    try std.testing.expect(!renderer.claimTileStore(first));
    try std.testing.expectEqual(@as(usize, 0x3000), @intFromPtr(renderer.tileStore(third).?.buffer.?));
    try std.testing.expect(renderer.claimTileStore(third));

    // A fresh slot is reserved up front, so installing it and retiring it later
    // allocate nothing.
    try renderer.reserveTileStoreSlot();
    failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    renderer.allocator = failing.allocator();
    const fresh = renderer.installTileStore(.{
        .buffer = @ptrFromInt(0x4000),
        .element_capacity = 64,
        .params = std.mem.zeroes(TilemapParams),
    });
    _ = renderer.retireTileStoreSlot(fresh.index);
    _ = renderer.retireTileStoreSlot(third.index);
    renderer.allocator = allocator;
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(u32, 1), fresh.index);
    try std.testing.expectEqual(@as(u32, 1), fresh.generation);
}

test "tileDataElementCount halves cell counts rounding up" {
    try std.testing.expectEqual(@as(usize, 0), tileDataElementCount(0));
    try std.testing.expectEqual(@as(usize, 1), tileDataElementCount(1));
    try std.testing.expectEqual(@as(usize, 1), tileDataElementCount(2));
    try std.testing.expectEqual(@as(usize, 2), tileDataElementCount(3));
}

test "applyWindowLayers fills the draw's layer count, shallowest flag, and topmost directory" {
    var params = TilemapParams{
        .grid = .{ 1, 1, 1, 1 },
        .atlas = .{ 1, 1, 1, 1 },
        .layer_meta = .{ 0, 0, 2, 8 },
        .window = .{ 1, 2, 3, 4 },
    };
    Renderer.applyWindowLayers(&params, .{ .first_directory = 130, .count = 80, .is_shallowest_bucket = true });

    try std.testing.expectEqual([4]i32{ 80, 1, 2, 8 }, params.layer_meta);
    try std.testing.expectEqual(@as(u32, 130), params.chain[0]);
    // The store's window is untouched.
    try std.testing.expectEqual([4]u32{ 1, 2, 3, 4 }, params.window);
}

// A minimal 6-vertex quad; `appendStaticTilemapSpan` only counts and stores
// vertices, so their contents do not matter for these tests.
fn testStaticQuad() [6]Position {
    return @splat(.{ 0, 0 });
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
    renderer.tilemap_window_layers.deinit(allocator);
    renderer.batch.deinit();
}

test "appendStaticTilemapSpan assigns sequential window slots per static-geometry cycle" {
    const allocator = std.testing.allocator;
    var renderer = testRenderer(allocator);
    defer deinitStaticGeometryTestRenderer(&renderer, allocator);

    const positions = testStaticQuad();
    const uvs: [6]Uv = @splat(.{ 0, 0 });
    const colors: [6]VertexColor = @splat(.{ 1, 1, 1, 1 });
    const vertices = VertexColumnsConst{ .positions = &positions, .uvs = &uvs, .colors = &colors };
    const texture = testTextureId(0, 1);

    renderer.beginStaticGeometry();
    for (0..3) |i| {
        const window = Renderer.TilemapWindowLayers{ .first_directory = @intCast(i), .count = 1 };
        try renderer.appendStaticTilemapSpan(texture, RenderOrder.world(@intCast(i)), vertices, TileDataId{ .index = 0, .generation = 1 }, window);
    }

    try std.testing.expectEqual(@as(usize, 3), renderer.tilemap_window_layers.items.len);
    for (0..3) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(i)), renderer.static_groups.items[i].window_slot);
        try std.testing.expectEqual(@as(u32, @intCast(i)), renderer.tilemap_window_layers.items[i].first_directory);
    }

    // A rebuild's beginStaticGeometry resets the side table -- no leaked slots
    // carry over from the prior cycle.
    renderer.beginStaticGeometry();
    try std.testing.expectEqual(@as(usize, 0), renderer.tilemap_window_layers.items.len);
    try renderer.appendStaticTilemapSpan(texture, RenderOrder.world(0), vertices, TileDataId{ .index = 0, .generation = 1 }, .{ .first_directory = 99, .count = 1 });
    try std.testing.expectEqual(@as(usize, 1), renderer.tilemap_window_layers.items.len);
    try std.testing.expectEqual(@as(u32, 0), renderer.static_groups.items[0].window_slot);
}

test "appendStaticTilemapSpan assigns window slots past 255" {
    const allocator = std.testing.allocator;
    var renderer = testRenderer(allocator);
    defer deinitStaticGeometryTestRenderer(&renderer, allocator);

    const positions = testStaticQuad();
    const uvs: [6]Uv = @splat(.{ 0, 0 });
    const colors: [6]VertexColor = @splat(.{ 1, 1, 1, 1 });
    const vertices = VertexColumnsConst{ .positions = &positions, .uvs = &uvs, .colors = &colors };
    const texture = testTextureId(0, 1);
    const span_count: usize = 300;

    renderer.beginStaticGeometry();
    for (0..span_count) |i| {
        const window = Renderer.TilemapWindowLayers{ .first_directory = @intCast(i * 3), .count = 1 };
        try renderer.appendStaticTilemapSpan(texture, RenderOrder.world(@intCast(i)), vertices, TileDataId{ .index = 0, .generation = 1 }, window);
    }
    try std.testing.expectEqual(span_count, renderer.tilemap_window_layers.items.len);
    for (renderer.static_groups.items, 0..) |group, i| {
        try std.testing.expectEqual(@as(u32, @intCast(i)), group.window_slot);
        try std.testing.expectEqual(@as(u32, @intCast(i * 3)), renderer.tilemap_window_layers.items[group.window_slot].first_directory);
    }
}

test "reserved static geometry append and mergeDrawList stay allocation-free" {
    const allocator = std.testing.allocator;
    var renderer = testRenderer(allocator);
    defer deinitStaticGeometryTestRenderer(&renderer, allocator);
    defer renderer.draw_list.deinit(allocator);

    const span_count: usize = 2;
    const vertex_capacity = span_count * 6;
    try renderer.reserveStaticGeometry(vertex_capacity, span_count);

    const positions = testStaticQuad();
    const uvs: [6]Uv = @splat(.{ 0, 0 });
    const colors: [6]VertexColor = @splat(.{ 1, 1, 1, 1 });
    const vertices = VertexColumnsConst{ .positions = &positions, .uvs = &uvs, .colors = &colors };
    const texture = testTextureId(0, 1);
    const window = Renderer.TilemapWindowLayers{ .count = 1 };

    // Reserved-then-append/merge SUCCESS branch under a hard-failing allocator,
    // the window side table included.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const real_allocator = renderer.allocator;
    renderer.allocator = failing.allocator();
    defer renderer.allocator = real_allocator;

    renderer.beginStaticGeometry();
    for (0..span_count) |i| {
        try renderer.appendStaticTilemapSpan(
            texture,
            RenderOrder.world(@intCast(i)),
            vertices,
            TileDataId{ .index = 0, .generation = 1 },
            window,
        );
    }
    try mergeDrawList(&renderer.draw_list, renderer.allocator, renderer.static_groups.items, &.{});

    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(span_count, renderer.static_groups.items.len);
    try std.testing.expectEqual(span_count, renderer.tilemap_window_layers.items.len);
    try std.testing.expectEqual(vertex_capacity, renderer.static_positions.items.len);
    try std.testing.expectEqual(span_count, renderer.draw_list.items.len);
}

test "merge draw list stays allocation-free when reserved to combined size" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList(DrawGroup) = .empty;
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

    // Reserved-then-merge SUCCESS under FailingAllocator (not just capacity equality).
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    try mergeDrawList(&list, failing.allocator(), &static_groups, &dynamic_groups);
    try mergeDrawList(&list, failing.allocator(), &static_groups, &dynamic_groups);

    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(capacity_before, list.capacity);
    // Coalesce merges the two contiguous same-texture static world spans; the
    // two dynamic groups differ in presentation and stay separate → 3 groups.
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
}

test "draw list does not merge across source and keeps static before dynamic at equal order" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList(DrawGroup) = .empty;
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
    try std.testing.expectEqual(@as(usize, 8), renderer.command_high_water);
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
// `gameplay_estimate + k_stacked_state_ui_headroom` up front (mirrors
// `render_prep.spriteCommandCapacity`), stacked UI then submits real sprites,
// and `Engine.renderFrame` tops up with
// `spriteCommandCount() + k_overlay_command_headroom` afterward — a second,
// independent reservation against the same grow-only `command_high_water`.
// This proves the top-up stays allocation-free even when stacked UI fully
// consumes its 32-command headroom, because `ensureTotalCapacity`'s amortized
// (~1.5x) growth on the state's up-front reserve already covers the extra
// `k_overlay_command_headroom` (32 >= 2 * 16 today). If either constant shrinks
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
    try renderer.reserveSpriteCommands(gameplay_estimate + Renderer.k_stacked_state_ui_headroom);
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
    for (0..Renderer.k_stacked_state_ui_headroom) |_| {
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

    const overlay_target = renderer.spriteCommandCount() + Renderer.k_overlay_command_headroom;
    // Sanity: this is genuinely a second, larger ask than the state's own
    // reservation, not a no-op repeat of it.
    try std.testing.expect(overlay_target > gameplay_estimate + Renderer.k_stacked_state_ui_headroom);

    try renderer.reserveSpriteCommands(overlay_target);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(commands_capacity_after_state_reserve, renderer.batch.commands.capacity);
    try std.testing.expectEqual(draw_list_capacity_after_state_reserve, renderer.draw_list.capacity);

    // Debug overlay can then submit up to k_overlay_command_headroom more sprites
    // without overflow or a capacity grow.
    for (0..Renderer.k_overlay_command_headroom) |_| {
        try renderer.submitOrderedSprite(.{
            .texture = white,
            .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
            .order = RenderOrder.world(order),
        });
        order += 1;
    }
    try std.testing.expectEqual(commands_capacity_after_state_reserve, renderer.batch.commands.capacity);
}

test "reserved sprite frame submits allocation-free with no overflow growth (FailingAllocator)" {
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

    const reserved: usize = 8;
    try renderer.reserveSpriteCommands(reserved);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const real_renderer_allocator = renderer.allocator;
    const real_batch_allocator = renderer.batch.allocator;
    renderer.allocator = failing.allocator();
    renderer.batch.allocator = failing.allocator();
    defer {
        renderer.allocator = real_renderer_allocator;
        renderer.batch.allocator = real_batch_allocator;
    }

    // Exactly the declared reservation, not the list's (possibly rounded-up) physical capacity.
    const white = try TextureId.init(0, 1);
    for (0..reserved) |i| {
        try renderer.submitOrderedSprite(.{
            .texture = white,
            .dest = .{ .x = @floatFromInt(i), .y = 0, .w = 1, .h = 1 },
            .order = RenderOrder.world(@intCast(i)),
        });
    }
    try std.testing.expectEqual(reserved, renderer.spriteCommandCount());
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(u64, 0), renderer.batch.commandOverflowGrows());
}

test "submits past the reservation inside the command list's slack count as drift" {
    // Drift diagnostics compile out of shipping builds (`SpriteBatch.ReservationDrift`).
    if (!@import("../app/runtime_perf_log.zig").enabled) return error.SkipZigTest;
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

    // Physical command capacity well past the declared reservation, as std's rounding or
    // an earlier larger batch reserve leaves it.
    try renderer.batch.reserveStorage(32, 32 * 6, 32);
    const reserved: usize = 8;
    try renderer.reserveSpriteCommands(reserved);
    const capacity_before = renderer.batch.commands.capacity;

    const white = try TextureId.init(0, 1);
    for (0..reserved + 2) |i| {
        try renderer.submitOrderedSprite(.{
            .texture = white,
            .dest = .{ .x = @floatFromInt(i), .y = 0, .w = 1, .h = 1 },
            .order = RenderOrder.world(@intCast(i)),
        });
    }
    // The command list never grew, but the frame is past `command_high_water`, which is
    // what makes `ensureFrameBatchCapacity` grow (and can GPU-idle stall): drift, counted
    // once for the frame.
    try std.testing.expectEqual(capacity_before, renderer.batch.commands.capacity);
    try std.testing.expect(renderer.spriteCommandCount() > renderer.command_high_water);
    try std.testing.expectEqual(@as(u64, 1), renderer.batch.commandOverflowGrows());
    try std.testing.expectEqual(@as(usize, 1), renderer.batch.finishPrepStats(.{}).command_overflow_grows);
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

    var linear: std.ArrayList(DrawGroup) = .empty;
    defer linear.deinit(allocator);
    try mergeDrawList(&linear, allocator, &static_groups, &dynamic_groups);

    var sorted: std.ArrayList(DrawGroup) = .empty;
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
