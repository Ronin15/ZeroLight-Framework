// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! `WorldSystem`'s render path: the render window's sparse tile list, the GPU tile
//! store sync of the window's dense layers, and the static dense and dynamic sparse
//! submits. Free functions over `*WorldSystem`, whose render methods forward here.

const std = @import("std");
const RuntimeAssets = @import("../../assets/runtime_assets.zig").RuntimeAssets;
const Rect = @import("../../render/renderer.zig").Rect;
const RenderOrder = @import("../../render/renderer.zig").RenderOrder;
const Renderer = @import("../../render/renderer.zig").Renderer;
const TileStoreError = @import("../../render/renderer.zig").TileStoreError;
const tileStoreBlockElements = @import("../../render/renderer.zig").tileStoreBlockElements;
const tile_store_max_side = @import("../../render/renderer.zig").tile_store_max_side;
const Sprite = @import("../../render/renderer.zig").Sprite;
const sprite_batch = @import("../../render/sprite_batch.zig");
const Position = @import("../../render/renderer.zig").Position;
const Uv = @import("../../render/renderer.zig").Uv;
const VertexColor = @import("../../render/renderer.zig").VertexColor;
const writeWorldSpriteQuad = @import("../../render/renderer.zig").writeWorldSpriteQuad;
const TextureId = @import("../../render/resources.zig").TextureId;
const world_gpu_tiles = @import("gpu_tiles.zig");
const log = @import("../../core/logging.zig").game;
const logging = @import("../../core/logging.zig");
const no_sparse_tile = @import("terrain.zig").no_sparse_tile;
const WorldSystem = @import("system.zig").WorldSystem;
const TileId = @import("system.zig").TileId;
const ViewWindow = @import("system.zig").ViewWindow;

/// Vertical dense-floor render visibility policy: the levels whose dense layers are
/// resident in the world's GPU tile store and submitted, and whose sparse tiles
/// draw. Re-submit fires when `dense_quads_dirty`, `active_level`, or this window
/// changes.
pub const DenseLayerRenderWindow = struct {
    /// Inclusive count of world levels below `active_level` to submit.
    levels_below: u16 = 6,
    /// Optional: when underground (`active_level > 0`), also submit one level
    /// above the player. Off by default — whole-layer tilemaps cannot do per-cell
    /// shaft cull, so enabling this redraws the full ceiling plane and breaks the
    /// render slice following the player down. Hole see-through from the surface
    /// uses `levels_below` while `active_level == 0`.
    ceiling_when_underground: bool = false,

    pub fn levelInWindow(
        self: DenseLayerRenderWindow,
        active_level: u16,
        world_level: u16,
        max_world_level: u16,
    ) bool {
        if (self.ceiling_when_underground and active_level > 0 and world_level == active_level - 1) {
            return true;
        }
        if (world_level < active_level) return false;
        const deep_limit = @min(
            @as(u32, active_level) +% @as(u32, self.levels_below),
            @as(u32, max_world_level),
        );
        return @as(u32, world_level) <= deep_limit;
    }
};

/// The render window's levels around an active level: what the sparse list, the GPU
/// residency, and the static submit each record they last built against.
pub const RenderLevels = struct {
    active_level: u16,
    window: DenseLayerRenderWindow,

    fn eql(self: RenderLevels, other: ?RenderLevels) bool {
        return if (other) |levels| std.meta.eql(self, levels) else false;
    }
};

/// One visibility update: its window and the levels its sparse list holds.
pub const VisibleView = struct {
    window: ViewWindow,
    levels: RenderLevels,
};

// One contiguous run of window sparse tiles that share a render depth, as a slice
// of `SparseWindow.tiles`.
const SparseDepthRange = struct {
    depth: i32,
    start: u32,
    count: u32,
};

/// The sparse tiles the render window draws: those on the window's levels inside
/// its tile bounds, ordered by (depth, cell, tile id), with one range per distinct
/// depth. Rebuilt by the window update when the window moves or `dirty` is set
/// (a tile added or removed inside the current window, or a removal that moved a
/// row the list holds); render-only.
pub const SparseWindow = struct {
    tiles: std.ArrayList(u32) = .empty,
    ranges: std.ArrayList(SparseDepthRange) = .empty,
    dirty: bool = true,

    pub fn deinit(self: *SparseWindow, allocator: std.mem.Allocator) void {
        self.ranges.deinit(allocator);
        self.tiles.deinit(allocator);
    }
};

/// Render-path state of the dense window, sized at the GPU sync's plan to the
/// window's layer count so the frame's submit allocates nothing. Render-only.
pub const DenseRenderScratch = struct {
    // The window's layers, topmost first (`collectDenseSubmitLayers`).
    desired: std.ArrayList(u32) = .empty,
    // Resident layers, deepest first, and their render depths (ascending).
    layers: std.ArrayList(u32) = .empty,
    layer_depths: std.ArrayList(i32) = .empty,
    // render_prep's interleave candidates and per-gap flags.
    interleave: std.ArrayList(i32) = .empty,
    gap_filled: std.ArrayList(bool) = .empty,
    buckets: std.ArrayList(WorldSystem.DenseCompositeBucket) = .empty,
    // The interleave depths the last submit cut against.
    submitted_interleave: std.ArrayList(i32) = .empty,

    pub fn deinit(self: *DenseRenderScratch, allocator: std.mem.Allocator) void {
        self.desired.deinit(allocator);
        self.layers.deinit(allocator);
        self.layer_depths.deinit(allocator);
        self.interleave.deinit(allocator);
        self.gap_filled.deinit(allocator);
        self.buckets.deinit(allocator);
        self.submitted_interleave.deinit(allocator);
    }

    // Room for a resident set of `count` layers in every per-frame list.
    fn reserve(self: *DenseRenderScratch, allocator: std.mem.Allocator, count: usize) error{OutOfMemory}!void {
        try self.layers.ensureTotalCapacity(allocator, count);
        try self.layer_depths.ensureTotalCapacity(allocator, count);
        try self.interleave.ensureTotalCapacity(allocator, count);
        try self.gap_filled.ensureTotalCapacity(allocator, count);
        try self.buckets.ensureTotalCapacity(allocator, count);
        try self.submitted_interleave.ensureTotalCapacity(allocator, count);
    }
};

/// Sets the render chunk window, the GPU directory side for the rect's size, and
/// the active level it renders around, and rebuilds the window's sparse list.
/// O(1) when the window, level, and `render_window` are unchanged and no tile was
/// added inside the window; otherwise O(window levels × window chunks + V log V)
/// for the V sparse
/// tiles in the window, never depending on the world's sparse count, level size,
/// or depth. Out of memory leaves the window and its sparse list as they were and
/// the next call retries.
pub fn setVisibleChunksForWorldRect(self: *WorldSystem, rect: Rect, overscan_chunks: u16, active_level: u16) error{OutOfMemory}!void {
    if (self.levelCount() == 0) return;
    const render_side = renderSideForRect(self, rect, overscan_chunks);
    const view = VisibleView{
        .window = self.viewWindowForWorldRect(rect, overscan_chunks),
        .levels = .{ .active_level = active_level, .window = self.render_window },
    };
    if (!self.sparse_window.dirty and self.visible != null and std.meta.eql(self.visible.?, view)) {
        self.render_side = render_side;
        return;
    }

    // Count, reserve, then commit: an allocation failure changes nothing.
    const tile_count = walkWindowSparseTiles(self, view, null);
    try self.sparse_window.tiles.ensureTotalCapacity(self.allocator, tile_count);
    try self.sparse_window.ranges.ensureTotalCapacity(self.allocator, tile_count);

    self.render_side = render_side;
    self.visible = view;
    fillWindowSparseTiles(self, view, tile_count);
    self.sparse_window.dirty = false;
}

// Counts the sparse tiles on the view's levels inside its tile bounds, appending
// each to `out` (reserved for them) when given. Walks only the chunks under the
// tile bounds, never the overscan ring: O(window levels × those chunks + their
// sparse tiles).
// SIMD verdict: scalar. A linked-list walk per chunk with a bounds test per tile.
fn walkWindowSparseTiles(self: *const WorldSystem, view: VisibleView, out: ?*std.ArrayList(u32)) usize {
    const levels = renderWindowLevels(self, view.levels.active_level) orelse return 0;
    const geom = self.chunkGeometry();
    const sparse = self.sparse_tiles.slice();
    const sparse_cells = sparse.items(.cell_index);
    const sparse_next = sparse.items(.chunk_next);
    const tiles = view.window.tiles;
    const width: u32 = self.width;
    const min_cx = @as(u32, tiles.min_x) >> geom.shift;
    const max_cx = (@as(u32, tiles.max_x) - 1) >> geom.shift;
    const min_cy = @as(u32, tiles.min_y) >> geom.shift;
    const max_cy = (@as(u32, tiles.max_y) - 1) >> geom.shift;
    var count: usize = 0;
    var level = levels.first;
    while (level <= levels.last) : (level += 1) {
        if (!view.levels.window.levelInWindow(view.levels.active_level, @intCast(level), levels.max_level)) continue;
        const heads = self.level_terrain.items[level].sparse_heads;
        var cy = min_cy;
        while (cy <= max_cy) : (cy += 1) {
            var cx = min_cx;
            while (cx <= max_cx) : (cx += 1) {
                var row = heads[cy * geom.chunks_x + cx];
                while (row != no_sparse_tile) : (row = sparse_next[row]) {
                    const cell = sparse_cells[row];
                    if (!tiles.contains(cell % width, cell / width)) continue;
                    if (out) |list| list.appendAssumeCapacity(row);
                    count += 1;
                }
            }
        }
    }
    return count;
}

// Fills the reserved sparse window with the `tile_count` tiles
// `walkWindowSparseTiles` counted, sorts them by (depth, cell, tile id), and
// builds one range per distinct depth. Allocation-free; an empty window skips
// the walk and sort.
fn fillWindowSparseTiles(self: *WorldSystem, view: VisibleView, tile_count: usize) void {
    const tiles = &self.sparse_window.tiles;
    const ranges = &self.sparse_window.ranges;
    std.debug.assert(tiles.capacity >= tile_count and ranges.capacity >= tile_count);
    tiles.clearRetainingCapacity();
    ranges.clearRetainingCapacity();
    if (tile_count == 0) return;
    const sparse = self.sparse_tiles.slice();
    const order = SparseWindowOrder{
        .depths = sparse.items(.depth_value),
        .cells = sparse.items(.cell_index),
        .tile_ids = sparse.items(.tile_id),
    };
    _ = walkWindowSparseTiles(self, view, tiles);
    std.debug.assert(tiles.items.len == tile_count);
    std.mem.sort(u32, tiles.items, order, SparseWindowOrder.lessThan);

    var start: usize = 0;
    while (start < tiles.items.len) {
        const depth = order.depths[tiles.items[start]];
        var end = start + 1;
        while (end < tiles.items.len and order.depths[tiles.items[end]] == depth) : (end += 1) {}
        // Window tiles index `sparse_tiles`, whose indices fit u32.
        ranges.appendAssumeCapacity(.{ .depth = depth, .start = @intCast(start), .count = @intCast(end - start) });
        start = end;
    }
}

// Draw order of window sparse tiles: depth, then cell, then tile id. Never the
// tile's index, so removing and moving rows cannot change what draws on top.
const SparseWindowOrder = struct {
    depths: []const i32,
    cells: []const u32,
    tile_ids: []const TileId,

    fn lessThan(self: SparseWindowOrder, lhs: u32, rhs: u32) bool {
        if (self.depths[lhs] != self.depths[rhs]) return self.depths[lhs] < self.depths[rhs];
        if (self.cells[lhs] != self.cells[rhs]) return self.cells[lhs] < self.cells[rhs];
        return self.tile_ids[lhs] < self.tile_ids[rhs];
    }
};

// A power-of-two side covering every chunk window a rect of this size touches:
// its chunk span plus one for alignment and the overscan on both sides, clamped
// to the level's chunk grid. Depends only on the rect size, so a pan keeps it.
fn renderSideForRect(self: *const WorldSystem, rect: Rect, overscan_chunks: u16) u32 {
    const geom = self.chunkGeometry();
    const chunk_px = @as(f32, @floatFromInt(geom.chunk_tiles)) * self.tile_size;
    const overscan = 1 + 2 * @as(u32, overscan_chunks);
    const span_x = rectChunkSpan(rect.w, chunk_px, geom.chunks_x) + overscan;
    const span_y = rectChunkSpan(rect.h, chunk_px, geom.chunks_y) + overscan;
    const grid_side = std.math.ceilPowerOfTwoAssert(u32, @max(geom.chunks_x, geom.chunks_y));
    const max_side = @min(grid_side, tile_store_max_side);
    return @min(std.math.ceilPowerOfTwo(u32, @max(span_x, span_y)) catch max_side, max_side);
}

/// Submits this frame's resident dense layers as one retained world-space
/// tilemap quad per composite draw: each draw's fragment shader walks a chain of
/// layer directories in the world's GPU tile store from its topmost layer,
/// stopping at the first opaque cell, so a run of layers with nothing sandwiched
/// between them is one draw independent of world size and window depth.
/// `interleave_depths` (sorted ascending, deduplicated) are this frame's cut
/// points: depths something else (a sparse tile, a dynamic entity) needs to
/// render strictly between two dense layers; each splits the stack into another
/// draw. Requires `syncDenseTileStore` for the same `active_level` first.
/// Re-submits on a layer or store change (`dense_quads_dirty`), an
/// `active_level`/window change, or an interleave-depth-set change, never on a
/// pan alone: the quads are full-world, the camera lives in the vertex shader,
/// and the resident chunk window is a store uniform. Allocation-free within the
/// sync's reserve.
pub fn submitStaticDenseGeometry(
    self: *WorldSystem,
    renderer: *Renderer,
    runtime_assets: *const RuntimeAssets,
    active_level: u16,
    interleave_depths: []const i32,
) error{ WorldTilesetTextureUnavailable, OutOfMemory, Overflow, StaticGeometryTooLarge }!void {
    const prepared = runtime_assets.sprite(.world_tileset) orelse return error.WorldTilesetTextureUnavailable;
    const levels = RenderLevels{ .active_level = active_level, .window = self.render_window };
    if (!self.dense_quads_dirty and
        levels.eql(self.submitted_levels) and
        std.mem.eql(i32, self.dense_render.submitted_interleave.items, interleave_depths))
        return;

    // The tilemap atlas params are baked from the world atlas dimensions at init;
    // the bound runtime texture must match. Safe-build only, and only on a
    // re-submit, not still frames.
    if (std.debug.runtime_safety) {
        if (renderer.textureDesc(prepared.texture)) |desc| {
            std.debug.assert(desc.width == self.atlas_texture.width and desc.height == self.atlas_texture.height);
        }
    }

    const layers = self.dense_render.layers.items;
    try self.dense_render.buckets.resize(self.allocator, layers.len);
    try self.dense_render.submitted_interleave.ensureTotalCapacity(self.allocator, interleave_depths.len);
    renderer.beginStaticGeometry();

    if (layers.len > 0) {
        const buckets = self.dense_render.buckets.items;
        const bucket_count = partitionDenseCompositeBuckets(self, layers, interleave_depths, buckets);

        // Only the world-space corners (position) are consumed by the tilemap
        // shader; the source/uv are ignored, so the source rect is a
        // placeholder. Built once and reused for every composite draw.
        const world_w = self.worldWidthPixels();
        const world_h = self.worldHeightPixels();
        var pos: [6]Position = undefined;
        var uv: [6]Uv = undefined;
        var col: [6]VertexColor = undefined;
        writeWorldSpriteQuad(.{
            .texture = TextureId.invalid,
            .source = .{ .x = 0, .y = 0, .w = self.tile_size, .h = self.tile_size },
            .dest = .{ .x = 0, .y = 0, .w = world_w, .h = world_h },
        }, self.atlas_texture, .{ .positions = &pos, .uvs = &uv, .colors = &col });

        for (buckets[0..bucket_count]) |bucket| {
            var window_layers = buildWindowLayers(self, bucket.start, bucket.end);
            // True only for the bucket holding the overall shallowest resident
            // layer (the last bucket, since `layers` is depth-ascending): the
            // fragment shader's rim shadow gates on this, not on its own
            // draw-local `resolved_depth == 0`, since a bucket split for an
            // unrelated interleave point can put a merely hole-revealed tile at
            // `resolved_depth == 0` within its own draw.
            window_layers.is_shallowest_bucket = bucket.end == layers.len;
            // Order = the bucket's own shallowest layer (the last in its range).
            const order = denseLayerOrder(self, layers[bucket.end - 1]);
            try renderer.appendStaticTilemapSpan(
                prepared.texture,
                order,
                .{ .positions = &pos, .uvs = &uv, .colors = &col },
                self.gpu_tiles.store,
                window_layers,
            );
        }
    }

    self.dense_quads_dirty = false;
    self.submitted_levels = levels;
    self.dense_render.submitted_interleave.clearRetainingCapacity();
    self.dense_render.submitted_interleave.appendSliceAssumeCapacity(interleave_depths);
}

/// Cuts `layers` (depth-ascending, deepest first) into composite-draw buckets:
/// a new bucket boundary is placed at every point where an `interleave_depths`
/// value falls strictly between two consecutive layers' depths (or exactly at
/// the shallower one, since nothing may draw between that pair once composited
/// together). `interleave_depths` must be sorted ascending and deduplicated
/// (asserted). Writes bucket ranges into `out` (at least `layers.len` long) and
/// returns the count; every cut consumes at least one layer, so the count never
/// exceeds `layers.len`.
fn partitionDenseCompositeBuckets(
    self: *const WorldSystem,
    layers: []const u32,
    interleave_depths: []const i32,
    out: []WorldSystem.DenseCompositeBucket,
) usize {
    if (layers.len == 0) return 0;
    std.debug.assert(out.len >= layers.len);
    if (std.debug.runtime_safety and interleave_depths.len > 1) {
        for (1..interleave_depths.len) |i| {
            std.debug.assert(interleave_depths[i] > interleave_depths[i - 1]);
        }
    }
    var bucket_count: usize = 0;
    var bucket_start: usize = 0;
    var interleave_index: usize = 0;
    for (1..layers.len + 1) |index| {
        var cut = index == layers.len;
        if (!cut) {
            const prev_depth = denseLayerOrder(self, layers[index - 1]).depth;
            const next_depth = denseLayerOrder(self, layers[index]).depth;
            while (interleave_index < interleave_depths.len and interleave_depths[interleave_index] <= prev_depth) {
                interleave_index += 1;
            }
            if (interleave_index < interleave_depths.len and interleave_depths[interleave_index] <= next_depth) {
                cut = true;
            }
        }
        if (cut) {
            out[bucket_count] = .{ .start = bucket_start, .end = index };
            bucket_count += 1;
            bucket_start = index;
        }
    }
    return bucket_count;
}

/// The chain of one bucket of resident layers (`dense_render.layers[start..end]`,
/// deepest first): its topmost layer's directory and the layer count. The
/// resident layers chain topmost-first, so the walk visits exactly the bucket.
fn buildWindowLayers(self: *const WorldSystem, bucket_start: usize, bucket_end: usize) Renderer.TilemapWindowLayers {
    std.debug.assert(bucket_start < bucket_end);
    const topmost = self.dense_render.layers.items[bucket_end - 1];
    const slot = self.dense_layers.items(.gpu_slot)[topmost];
    return .{
        .first_directory = self.gpu_tiles.slotDirectory(slot),
        .count = @intCast(bucket_end - bucket_start),
    };
}

const RenderWindowLevels = struct { first: u32, last: u32, max_level: u16 };

// The level range `render_window` can hold around `active_level`; callers still
// filter each level with `levelInWindow`. Null for a world with no levels.
fn renderWindowLevels(self: *const WorldSystem, active_level: u16) ?RenderWindowLevels {
    if (self.levelCount() == 0) return null;
    const max_level = self.maxLevelIndex();
    return .{
        .first = if (self.render_window.ceiling_when_underground and active_level > 0) active_level - 1 else active_level,
        .last = @min(@as(u32, active_level) + self.render_window.levels_below, @as(u32, max_level)),
        .max_level = max_level,
    };
}

/// The dense layers of the render window's levels around `active_level`, topmost
/// first (back-to-front reversed), in `dense_render.desired`. Visits only the
/// window's levels through their band lists: O(window layers log window layers).
fn collectDenseSubmitLayers(self: *WorldSystem, active_level: u16) error{OutOfMemory}![]const u32 {
    const desired = &self.dense_render.desired;
    desired.clearRetainingCapacity();
    const levels = renderWindowLevels(self, active_level) orelse return desired.items;
    var count: usize = 0;
    var level = levels.first;
    while (level <= levels.last) : (level += 1) {
        if (!self.render_window.levelInWindow(active_level, @intCast(level), levels.max_level)) continue;
        count += self.level_terrain.items[level].bandLayers().len;
    }
    try desired.ensureTotalCapacity(self.allocator, count);
    level = levels.first;
    while (level <= levels.last) : (level += 1) {
        if (!self.render_window.levelInWindow(active_level, @intCast(level), levels.max_level)) continue;
        desired.appendSliceAssumeCapacity(self.level_terrain.items[level].bandLayers());
    }
    std.mem.sort(u32, desired.items, self, denseLayerIndexLessThan);
    std.mem.reverse(u32, desired.items);
    return desired.items;
}

/// Brings the world's GPU tile store in line with the render window around
/// `active_level`: the dense layers of the window's levels, each over the
/// render chunk window in a toroidal directory chained topmost-first. Layers
/// entering upload their directory and their mixed window chunks' blocks; layers
/// leaving free theirs; a pan across a chunk boundary uploads only the chunks
/// entering; a changed resident chunk uploads once, its word or its whole block;
/// all in the next frame copy pass. Creates the store, content-sized, on first
/// need and whenever the directory side changes; layers past the store's `u32`
/// width are dropped deepest first and reported once. Call once per frame on
/// the main thread before `submitStaticDenseGeometry` and swapchain acquisition.
/// O(1) when nothing changed; O(window chunks) per resident layer changed since the
/// last sync; O(resident layers × window chunks) when the window, level, or layer
/// set moves; never depends on chunks or levels outside the window. Every
/// fallible step (plan, store creation, upload reserve) precedes the mirror
/// commit, and the queue after it cannot fail, so an error leaves residency and
/// change marks for a retry. Claims the
/// store for this frame; the renderer retires it the first frame this is not
/// called, and the next call re-uploads the window into a new store.
pub fn syncDenseTileStore(self: *WorldSystem, renderer: *Renderer, active_level: u16) TileStoreError!void {
    const mirror = &self.gpu_tiles;
    if (mirror.store.isValid() and !renderer.claimTileStore(mirror.store)) resetGpuResidency(self);
    if (self.levelCount() == 0 or self.visible == null) return;
    const sync_plan = try planDenseGpuSync(self, active_level);
    const old_store = mirror.store;
    if (sync_plan.span_count > 0 and (!old_store.isValid() or mirror.store_side != sync_plan.side)) {
        var params = self.tilemap_params;
        params.window = sync_plan.window.uniform();
        // Held from creation: a retry after a failed reserve reuses this empty
        // store instead of creating another. It holds no resident layer yet, and
        // the retry's plan still enters every window layer.
        mirror.store = try renderer.createTileStore(.{
            .element_capacity = @max(1, sync_plan.required_elements),
            .params = params,
            .chunk_shift = self.chunkGeometry().shift,
            .side = sync_plan.side,
        });
        mirror.store_side = sync_plan.side;
    }
    if (sync_plan.span_count > 0) {
        try renderer.reserveTileStoreUploads(mirror.store, sync_plan.required_elements, sync_plan.span_count, sync_plan.value_count);
    }
    commitDenseGpuSync(self, &sync_plan, active_level);
    if (sync_plan.relayout and sync_plan.span_count == 0) {
        // A new layout with nothing resident leaves the old store unclaimed.
        mirror.store = .invalid;
        mirror.store_side = 0;
    }
    if (sync_plan.layers_changed or !std.meta.eql(old_store, mirror.store)) self.dense_quads_dirty = true;
    if (sync_plan.span_count > 0) renderer.queueTileStoreUploads(mirror.store, mirror.spans.items, mirror.values.items);
    if (sync_plan.residency_changed and mirror.store.isValid()) renderer.setTileStoreWindow(mirror.store, mirror.window.uniform());
    if (!mirror.resident_bytes_reported and mirror.store.isValid()) {
        mirror.resident_bytes_reported = true;
        if (comptime logging.enabled(.info)) log.info("GPU tile store: {d} resident layers over {d} window chunks, {d} resident bytes", .{
            mirror.residentLayerCount(),
            mirror.window.count(),
            mirror.residentBytes(),
        });
    }
}

/// The renderer retired the store: nothing is resident any more, so the next
/// sync lays the window out anew and the draws re-submit. O(resident layers).
pub fn resetGpuResidency(self: *WorldSystem) void {
    self.gpu_tiles.reset(self.dense_layers.items(.gpu_slot), self.dense_layers.items(.render_changed));
    self.resident_layers_changed = false;
    self.dense_render.layers.clearRetainingCapacity();
    self.dense_render.layer_depths.clearRetainingCapacity();
    self.gpu_residency_dirty = true;
    self.dense_quads_dirty = true;
}

/// Sizes this frame's GPU tile sync and reserves its growth, the frame's dense
/// render scratch included; re-derives the resident set only when the layer set,
/// active level, level window, chunk window, or directory side changed. Requires
/// a set render window.
pub fn planDenseGpuSync(self: *WorldSystem, active_level: u16) error{OutOfMemory}!world_gpu_tiles.SyncPlan {
    const visible = self.visible.?.window.chunks;
    const geom = self.chunkGeometry();
    const fitted = world_gpu_tiles.fitWindow(self.render_side, visible);
    const window = fitted.window;
    if (!window.eql(visible) and !self.gpu_tiles.window_clip_reported) {
        @branchHint(.cold);
        self.gpu_tiles.window_clip_reported = true;
        log.warn("render chunk window clipped to {d}x{d} chunks; store width", .{ window.width(), window.height() });
    }
    const levels = RenderLevels{ .active_level = active_level, .window = self.render_window };
    const rederive = self.gpu_residency_dirty or
        !levels.eql(self.gpu_resident_levels) or
        !window.eql(self.gpu_tiles.window) or
        fitted.side != self.gpu_tiles.side or
        !self.gpu_tiles.layoutMatchesStore();
    const rows = self.dense_layers.slice();
    const layer_changed: ?[]const bool = if (self.resident_layers_changed) rows.items(.render_changed) else null;
    if (!rederive) {
        return self.gpu_tiles.plan(self.allocator, geom, rows.items(.store), rows.items(.gpu_slot), layer_changed, null);
    }
    const desired = try collectDenseSubmitLayers(self, active_level);
    try self.dense_render.reserve(self.allocator, desired.len);
    const fit = world_gpu_tiles.residentLayerFit(fitted.side, tileStoreBlockElements(geom.chunk_tiles));
    return self.gpu_tiles.plan(self.allocator, geom, rows.items(.store), rows.items(.gpu_slot), layer_changed, .{
        .layers = fitResidentLayers(desired, fit, &self.gpu_tiles.width_drop_reported),
        .window = window,
        .side = fitted.side,
    });
}

// The window layers (topmost first) the store width holds: the first `fit`, so
// the deepest drop. Reports a drop once per world through `reported`.
fn fitResidentLayers(desired: []const u32, fit: usize, reported: *bool) []const u32 {
    const resident = desired[0..@min(desired.len, fit)];
    if (resident.len < desired.len and !reported.*) {
        @branchHint(.cold);
        reported.* = true;
        log.warn("{d} deepest window layers not drawn; store width", .{desired.len - resident.len});
    }
    return resident;
}

/// Applies the sync and, when the resident set moved, rebuilds the resident
/// layers (deepest first) and their depths from the chain. O(resident layers).
pub fn commitDenseGpuSync(self: *WorldSystem, sync_plan: *const world_gpu_tiles.SyncPlan, active_level: u16) void {
    const rows = self.dense_layers.slice();
    self.gpu_tiles.commit(sync_plan, self.chunkGeometry(), rows.items(.store), rows.items(.gpu_slot), rows.items(.render_changed));
    // The commit cleared every resident layer's flag; non-resident ones are never set.
    if (sync_plan.edits) self.resident_layers_changed = false;
    self.gpu_resident_levels = .{ .active_level = active_level, .window = self.render_window };
    self.gpu_residency_dirty = false;
    if (!sync_plan.residency_changed) return;
    const order = self.gpu_tiles.order.items;
    const layers = &self.dense_render.layers;
    const depths = &self.dense_render.layer_depths;
    std.debug.assert(layers.capacity >= order.len and depths.capacity >= order.len);
    layers.clearRetainingCapacity();
    depths.clearRetainingCapacity();
    var index = order.len;
    while (index > 0) {
        index -= 1;
        const layer = self.gpu_tiles.slot_layer.items[order[index]];
        layers.appendAssumeCapacity(layer);
        depths.appendAssumeCapacity(denseLayerOrder(self, layer).depth);
    }
}

/// Submits the window's sparse tiles in depth range `range_index` (below
/// `sparseDepthRangeCount`) through the dynamic ordered stream, in (cell, tile
/// id) order. Sparse tiles stay dynamic (they are sparse and change
/// independently of the dense static field); the renderer merges them with
/// dynamic entities and the static dense spans by render order. O(tiles in the
/// range).
pub fn submitVisibleSparseRange(
    self: *const WorldSystem,
    renderer: *Renderer,
    runtime_assets: *const RuntimeAssets,
    range_index: usize,
) error{ WorldTilesetTextureUnavailable, MissingTileSourceRect, OutOfMemory }!void {
    const prepared = runtime_assets.sprite(.world_tileset) orelse return error.WorldTilesetTextureUnavailable;
    _ = try emitSparseRange(self, renderer, prepared.texture, range_index);
}

/// `submitVisibleSparseRange` into a CPU sprite `batch` instead of a live
/// `Renderer`, for headless parity checks and benches. Returns the sprites written.
pub fn submitVisibleSparseSprites(
    self: *const WorldSystem,
    batch: *sprite_batch.SpriteBatch,
    texture: TextureId,
    range_index: usize,
) error{ MissingTileSourceRect, OutOfMemory }!usize {
    return emitSparseRange(self, batch, texture, range_index);
}

// Builds each window sparse sprite of range `range_index` once and hands it to
// `sink`, a `*Renderer` or a `*SpriteBatch`. Returns the sprites emitted.
fn emitSparseRange(self: *const WorldSystem, sink: anytype, texture: TextureId, range_index: usize) error{ MissingTileSourceRect, OutOfMemory }!usize {
    const range = self.sparse_window.ranges.items[range_index];
    const sparse = self.sparse_tiles.slice();
    const cells = sparse.items(.cell_index);
    const tile_ids = sparse.items(.tile_id);
    for (self.sparse_window.tiles.items[range.start..][0..range.count]) |index| {
        const cell = cells[index];
        const sprite = Sprite{
            .texture = texture,
            .source = self.sourceRect(tile_ids[index]) orelse return error.MissingTileSourceRect,
            .dest = .{
                .x = @as(f32, @floatFromInt(cell % self.width)) * self.tile_size,
                .y = @as(f32, @floatFromInt(cell / self.width)) * self.tile_size,
                .w = self.tile_size,
                .h = self.tile_size,
            },
            .order = RenderOrder.world(range.depth),
        };
        switch (@TypeOf(sink)) {
            *Renderer => try sink.submitOrderedSprite(sprite),
            *sprite_batch.SpriteBatch => try sink.drawSprite(sprite),
            else => @compileError("sparse sprites go to a Renderer or a SpriteBatch"),
        }
    }
    return range.count;
}

/// Flags resident `layer_index` (columns `gpu_slots`, `render_changed`) for the
/// next GPU sync after one of its cells changed; a layer outside the render window
/// uploads whole when it enters. O(1).
pub fn markRenderChanged(self: *WorldSystem, gpu_slots: []const u32, render_changed: []bool, layer_index: usize) void {
    if (gpu_slots[layer_index] == world_gpu_tiles.no_slot) return;
    render_changed[layer_index] = true;
    self.resident_layers_changed = true;
}

/// Whether the current render window draws a sparse tile at (x, y) on `level`:
/// the level is in the window around its active level and the cell is inside
/// its tile bounds. False before a window is set.
pub fn sparseTileInWindow(self: *const WorldSystem, level: u16, x: u16, y: u16) bool {
    const view = self.visible orelse return false;
    if (!view.levels.window.levelInWindow(view.levels.active_level, level, self.maxLevelIndex())) return false;
    return view.window.tiles.contains(x, y);
}

fn denseLayerOrder(self: *const WorldSystem, layer_index: usize) RenderOrder {
    const dense = self.dense_layers.slice();
    return RenderOrder.world(self.worldZForLevel(
        dense.items(.level_index)[layer_index],
        dense.items(.base_z)[layer_index],
        dense.items(.depth_band)[layer_index],
    ));
}

// Depth, then layer index, so equal depths keep layer order whatever the input order.
fn denseLayerIndexLessThan(self: *const WorldSystem, a: u32, b: u32) bool {
    const depth_a = denseLayerOrder(self, a).depth;
    const depth_b = denseLayerOrder(self, b).depth;
    if (depth_a != depth_b) return depth_a < depth_b;
    return a < b;
}

// Chunks a pixel extent spans at most, capped at `chunks`.
fn rectChunkSpan(extent: f32, chunk_px: f32, chunks: u32) u32 {
    if (!(extent > 0)) return 0;
    const span = @ceil(extent / chunk_px);
    if (!(span < @as(f32, @floatFromInt(chunks)))) return chunks;
    return @intFromFloat(span);
}

const TileDataId = @import("../../render/renderer.zig").TileDataId;
const manifest = @import("../../assets/manifest.zig");
const WorldTilesetMeta = @import("../../assets/world_tileset_meta.zig").WorldTilesetMeta;
const TileStoreSpan = @import("../../render/renderer.zig").TileStoreSpan;
const TilemapParams = @import("../../render/renderer.zig").TilemapParams;
const WorldDepth = @import("../render_depth.zig").WorldDepth;
const invalid_tile_id = @import("system.zig").invalid_tile_id;
const level_z_step = @import("system.zig").level_z_step;
const TestGpuStore = @import("test_support.zig").TestGpuStore;
const testWorldMeta = @import("test_support.zig").testWorldMeta;
const testMinimalSurfaceWorld = @import("test_support.zig").testMinimalSurfaceWorld;
const testSyncGpuTiles = @import("test_support.zig").testSyncGpuTiles;
const testShowWholeWorld = @import("test_support.zig").testShowWholeWorld;
const testApplySync = @import("test_support.zig").testApplySync;
const testGpuTile = @import("test_support.zig").testGpuTile;
const expectGpuStoreMatches = @import("test_support.zig").expectGpuStoreMatches;
const expectSparseIndexConsistent = @import("test_support.zig").expectSparseIndexConsistent;

// The window layers around `active_level`, deepest first, copied into `out`.
fn testSubmitLayers(world: *WorldSystem, active_level: u16, out: []u32) ![]u32 {
    const desired = try collectDenseSubmitLayers(world, active_level);
    const layers = out[0..desired.len];
    for (desired, 0..) |layer, index| layers[desired.len - 1 - index] = layer;
    return layers;
}

// Sets the render window to exactly the chunks [min, min + size) on both axes.
fn testShowChunks(world: *WorldSystem, min_x: u16, min_y: u16, size_x: u16, size_y: u16, active_level: u16) !void {
    const chunk_px = @as(f32, @floatFromInt(world.chunk_size_tiles)) * world.tile_size;
    try world.setVisibleChunksForWorldRect(.{
        .x = @as(f32, @floatFromInt(min_x)) * chunk_px,
        .y = @as(f32, @floatFromInt(min_y)) * chunk_px,
        .w = @as(f32, @floatFromInt(size_x)) * chunk_px,
        .h = @as(f32, @floatFromInt(size_y)) * chunk_px,
    }, 0, active_level);
}

// A 16x16 world in 4-tile chunks with `level_count` empty levels; the render
// window holds the active level and one below.
fn testSparseWindowWorld(meta: *const WorldTilesetMeta, allocator: std.mem.Allocator, level_count: u16) !WorldSystem {
    var world = WorldSystem{
        .allocator = allocator,
        .width = 16,
        .height = 16,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
        .render_window = .{ .levels_below = 1 },
    };
    errdefer world.deinit();
    try world.buildCatalog(meta);
    for (0..level_count) |level_index| {
        _ = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
    }
    return world;
}

// Sets the render window to the tiles [x, x + edge) x [0, edge) plus `overscan` chunks.
fn testShowTiles(world: *WorldSystem, x: u16, edge: u16, overscan: u16, active_level: u16) !void {
    const tile_px = world.tile_size;
    try world.setVisibleChunksForWorldRect(.{
        .x = @as(f32, @floatFromInt(x)) * tile_px,
        .y = 0,
        .w = @as(f32, @floatFromInt(edge)) * tile_px,
        .h = @as(f32, @floatFromInt(edge)) * tile_px,
    }, overscan, active_level);
}

const TestSparseKey = struct { depth: i32, cell: u32, tile_id: TileId };

fn testSparseKeyLessThan(_: void, lhs: TestSparseKey, rhs: TestSparseKey) bool {
    if (lhs.depth != rhs.depth) return lhs.depth < rhs.depth;
    if (lhs.cell != rhs.cell) return lhs.cell < rhs.cell;
    return lhs.tile_id < rhs.tile_id;
}

// The window's sparse tiles as (depth, cell, tile id), in list order, into `out`.
fn testWindowSparseKeys(world: *const WorldSystem, out: []TestSparseKey) []TestSparseKey {
    const sparse = world.sparse_tiles.slice();
    const tiles = world.sparse_window.tiles.items;
    for (tiles, out[0..tiles.len]) |index, *key| {
        key.* = .{
            .depth = sparse.items(.depth_value)[index],
            .cell = sparse.items(.cell_index)[index],
            .tile_id = sparse.items(.tile_id)[index],
        };
    }
    return out[0..tiles.len];
}

// Every range is one depth, ranges ascend by depth, and together they cover the
// window's tiles exactly once in list order.
fn expectSparseRangesCoverWindow(world: *const WorldSystem) !void {
    const depths = world.sparse_tiles.items(.depth_value);
    const tiles = world.sparse_window.tiles.items;
    var next_start: u32 = 0;
    for (0..world.sparseDepthRangeCount()) |range_index| {
        const range = world.sparse_window.ranges.items[range_index];
        try std.testing.expectEqual(next_start, range.start);
        try std.testing.expect(range.count > 0);
        if (range_index > 0) try std.testing.expect(world.sparseDepthRangeAt(range_index - 1) < range.depth);
        try std.testing.expectEqual(range.depth, world.sparseDepthRangeAt(range_index));
        for (tiles[range.start..][0..range.count]) |index| try std.testing.expectEqual(range.depth, depths[index]);
        next_start += range.count;
    }
    try std.testing.expectEqual(tiles.len, next_start);
}

test "the window sparse list holds exactly the window's tiles ordered by depth, then cell, then tile id" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseWindowWorld(&meta, std.testing.allocator, 3);
    defer world.deinit();
    const tree = try world.requireTileByName(&meta, "tree_0");
    const deco = try world.requireTileByName(&meta, "deco_0");

    // Insertion order is neither depth nor cell order, with repeated depths and two
    // tile ids sharing a cell and depth.
    const Placement = struct { level: u16, x: u16, y: u16, tile: TileId, depth: WorldDepth };
    const placements = [_]Placement{
        .{ .level = 0, .x = 5, .y = 2, .tile = tree, .depth = .obstacle },
        .{ .level = 1, .x = 1, .y = 1, .tile = deco, .depth = .floor },
        .{ .level = 0, .x = 2, .y = 2, .tile = deco, .depth = .obstacle },
        .{ .level = 0, .x = 3, .y = 0, .tile = deco, .depth = .effect },
        .{ .level = 0, .x = 3, .y = 0, .tile = tree, .depth = .effect },
        .{ .level = 0, .x = 0, .y = 5, .tile = tree, .depth = .floor },
        .{ .level = 1, .x = 4, .y = 4, .tile = tree, .depth = .floor },
        // Outside: in an overscan chunk but past the tile bounds, outside the
        // chunk window, and on a level below the render window.
        .{ .level = 0, .x = 7, .y = 1, .tile = tree, .depth = .obstacle },
        .{ .level = 0, .x = 13, .y = 13, .tile = tree, .depth = .obstacle },
        .{ .level = 2, .x = 1, .y = 1, .tile = tree, .depth = .obstacle },
    };
    const inside_count = 7;
    var expected: [placements.len]TestSparseKey = undefined;
    for (placements, 0..) |placement, index| {
        _ = try world.addSparseTile(placement.level, placement.x, placement.y, placement.tile, 0, placement.depth);
        expected[index] = .{
            .depth = world.worldZForLevel(placement.level, 0, placement.depth),
            .cell = world.cellIndex(placement.x, placement.y),
            .tile_id = placement.tile,
        };
    }
    std.mem.sort(TestSparseKey, expected[0..inside_count], {}, testSparseKeyLessThan);

    // Tiles [0, 6) with one chunk of overscan: chunks [0, 3) on both axes.
    try testShowTiles(&world, 0, 6, 1, 0);
    try std.testing.expectEqual(@as(usize, inside_count), world.reserveRenderRecords());
    var actual: [placements.len]TestSparseKey = undefined;
    try std.testing.expectEqualSlices(TestSparseKey, expected[0..inside_count], testWindowSparseKeys(&world, &actual));
    try expectSparseRangesCoverWindow(&world);

    // The batch path submits the same tiles, range by range.
    var batch = sprite_batch.SpriteBatch.init(std.testing.allocator);
    defer batch.deinit();
    batch.beginFrame();
    var submitted: usize = 0;
    for (0..world.sparseDepthRangeCount()) |range_index| {
        submitted += try world.submitVisibleSparseSprites(&batch, try TextureId.init(1, 1), range_index);
    }
    try std.testing.expectEqual(@as(usize, inside_count), submitted);
}

test "two same-depth sparse tiles in one window draw in the same order whichever was added first" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    const Placement = struct { x: u16, tile: []const u8 };
    // Same depth: two cells, and two tile ids on one of them.
    const placements = [_]Placement{ .{ .x = 3, .tile = "tree_0" }, .{ .x = 1, .tile = "deco_0" }, .{ .x = 1, .tile = "tree_0" } };
    var orders: [2][placements.len]TestSparseKey = undefined;
    for (&orders, 0..) |*order, pass| {
        var world = try testSparseWindowWorld(&meta, std.testing.allocator, 1);
        defer world.deinit();
        for (0..placements.len) |step| {
            const placement = placements[if (pass == 0) step else placements.len - 1 - step];
            _ = try world.addSparseTile(0, placement.x, 1, try world.requireTileByName(&meta, placement.tile), 0, .obstacle);
        }
        try testShowTiles(&world, 0, 4, 0, 0);
        try std.testing.expectEqual(@as(usize, 1), world.sparseDepthRangeCount());
        _ = testWindowSparseKeys(&world, order);
    }
    try std.testing.expectEqualSlices(TestSparseKey, &orders[0], &orders[1]);
    for (orders[0][1..], 1..) |key, index| try std.testing.expect(testSparseKeyLessThan({}, orders[0][index - 1], key));
}

test "a sparse tile added outside the window leaves the list untouched; one inside appears after the next window update" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseWindowWorld(&meta, std.testing.allocator, 3);
    defer world.deinit();
    const deco = try world.requireTileByName(&meta, "deco_0");
    _ = try world.addSparseTile(0, 1, 1, deco, 0, .obstacle);
    try testShowTiles(&world, 0, 6, 1, 0);
    try std.testing.expectEqualSlices(u32, &.{0}, world.sparse_window.tiles.items);

    // Outside: past the tile bounds in an overscan chunk, and below the level window.
    _ = try world.addSparseTile(0, 7, 1, deco, 0, .effect);
    _ = try world.addSparseTile(2, 1, 1, deco, 0, .effect);
    try std.testing.expect(!world.sparse_window.dirty);
    try testShowTiles(&world, 0, 6, 1, 0);
    try std.testing.expectEqualSlices(u32, &.{0}, world.sparse_window.tiles.items);
    try std.testing.expectEqual(@as(usize, 1), world.sparseDepthRangeCount());

    // Inside, on the level below: listed from the next window update.
    _ = try world.addSparseTile(1, 2, 2, deco, 0, .effect);
    try std.testing.expect(world.sparse_window.dirty);
    try std.testing.expectEqualSlices(u32, &.{0}, world.sparse_window.tiles.items);
    try testShowTiles(&world, 0, 6, 1, 0);
    try std.testing.expect(!world.sparse_window.dirty);
    try std.testing.expectEqualSlices(u32, &.{ 3, 0 }, world.sparse_window.tiles.items);
    try expectSparseRangesCoverWindow(&world);
}

test "a render window change under a still camera relists the window's sparse levels" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseWindowWorld(&meta, std.testing.allocator, 3);
    defer world.deinit();
    const deco = try world.requireTileByName(&meta, "deco_0");
    for (0..3) |level| _ = try world.addSparseTile(@intCast(level), 1, 1, deco, 0, .floor);
    try testShowTiles(&world, 0, 4, 0, 0);
    // Levels 0 and 1, deepest first.
    try std.testing.expectEqualSlices(u32, &.{ 1, 0 }, world.sparse_window.tiles.items);

    world.render_window = .{ .levels_below = 2 };
    try testShowTiles(&world, 0, 4, 0, 0);
    try std.testing.expectEqualSlices(u32, &.{ 2, 1, 0 }, world.sparse_window.tiles.items);
    try expectSparseRangesCoverWindow(&world);
}

test "an active level change under a still camera relists the window's sparse levels" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseWindowWorld(&meta, std.testing.allocator, 3);
    defer world.deinit();
    const deco = try world.requireTileByName(&meta, "deco_0");
    _ = try world.addSparseTile(0, 1, 1, deco, 0, .floor);
    _ = try world.addSparseTile(2, 1, 1, deco, 0, .floor);
    try testShowTiles(&world, 0, 4, 0, 0);
    try std.testing.expectEqualSlices(u32, &.{0}, world.sparse_window.tiles.items);
    // Level 1 renders levels 1 and 2.
    try testShowTiles(&world, 0, 4, 0, 1);
    try std.testing.expectEqualSlices(u32, &.{1}, world.sparse_window.tiles.items);
}

test "an out-of-memory window update leaves the previous window and its sparse list intact (FailingAllocator)" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseWindowWorld(&meta, std.testing.allocator, 1);
    defer world.deinit();
    const deco = try world.requireTileByName(&meta, "deco_0");
    _ = try world.addSparseTile(0, 1, 1, deco, 0, .obstacle);
    // More tiles than the first list's capacity, in the chunks right of the window.
    for (0..64) |index| {
        _ = try world.addSparseTile(0, 8 + @as(u16, @intCast(index % 8)), @intCast(index / 8), deco, 0, .effect);
    }
    try testShowTiles(&world, 0, 4, 0, 0);
    try std.testing.expectEqualSlices(u32, &.{0}, world.sparse_window.tiles.items);
    const region = world.visibleChunkRegion().?;

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    world.allocator = failing.allocator();
    // A pan onto the dense chunks fails: the window and list stay as they were.
    try std.testing.expectError(error.OutOfMemory, testShowTiles(&world, 8, 8, 0, 0));
    try std.testing.expectEqual(region, world.visibleChunkRegion().?);
    try std.testing.expectEqualSlices(u32, &.{0}, world.sparse_window.tiles.items);
    try std.testing.expectEqual(@as(usize, 1), world.sparseDepthRangeCount());

    // An in-window add that cannot be listed keeps the list dirty for the retry.
    world.allocator = std.testing.allocator;
    for (0..64) |_| _ = try world.addSparseTile(0, 2, 2, deco, 0, .effect);
    world.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, testShowTiles(&world, 0, 4, 0, 0));
    try std.testing.expect(world.sparse_window.dirty);
    try std.testing.expectEqualSlices(u32, &.{0}, world.sparse_window.tiles.items);

    world.allocator = std.testing.allocator;
    try testShowTiles(&world, 0, 4, 0, 0);
    try std.testing.expect(!world.sparse_window.dirty);
    try std.testing.expectEqual(@as(usize, 65), world.reserveRenderRecords());
    try testShowTiles(&world, 8, 8, 0, 0);
    try std.testing.expectEqual(@as(usize, 64), world.reserveRenderRecords());
    try expectSparseRangesCoverWindow(&world);
}

test "a warmed window update allocates nothing across pans and an in-window add (FailingAllocator)" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseWindowWorld(&meta, std.testing.allocator, 2);
    defer world.deinit();
    const deco = try world.requireTileByName(&meta, "deco_0");
    for (0..16) |index| {
        const x: u16 = @intCast(index % 16);
        _ = try world.addSparseTile(@intCast(index % 2), x, 1, deco, 0, if (index % 3 == 0) .floor else .effect);
    }
    // Warm the list to the widest window, then add one tile inside the left window.
    try testShowTiles(&world, 0, 16, 0, 0);
    try testShowTiles(&world, 0, 8, 0, 0);
    _ = try world.addSparseTile(1, 3, 3, deco, 0, .marker);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    world.allocator = failing.allocator();
    defer world.allocator = std.testing.allocator;
    try testShowTiles(&world, 0, 8, 0, 0);
    try std.testing.expectEqual(@as(usize, 9), world.reserveRenderRecords());
    try testShowTiles(&world, 8, 8, 0, 0);
    try testShowTiles(&world, 0, 16, 0, 1);
    try testShowTiles(&world, 0, 8, 0, 0);
    try std.testing.expectEqual(@as(usize, 9), world.reserveRenderRecords());
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
}

test "the window sparse list is the same at 1k and 64k tiles outside the window" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    const window_depths = [_]WorldDepth{ .floor, .obstacle, .effect, .marker };
    var lists: [2][8]TestSparseKey = undefined;
    for ([_]usize{ 1_000, 64_000 }, &lists) |outside_count, *list| {
        var world = try testSparseWindowWorld(&meta, std.testing.allocator, 3);
        defer world.deinit();
        const deco = try world.requireTileByName(&meta, "deco_0");
        for (0..8) |index| {
            _ = try world.addSparseTile(0, @intCast(index), 2, deco, 0, window_depths[index % window_depths.len]);
        }
        // Outside: the right half on the window's levels, anywhere on the level
        // below the render window.
        for (0..outside_count) |index| {
            const level: u16 = @intCast(index % 3);
            const x: u16 = @intCast(if (level == 2) index % 16 else 8 + index % 8);
            _ = try world.addSparseTile(level, x, @intCast(index / 3 % 16), deco, 0, window_depths[index % window_depths.len]);
        }
        try testShowTiles(&world, 0, 8, 0, 0);
        try std.testing.expectEqual(@as(usize, 8), world.reserveRenderRecords());
        try std.testing.expectEqual(window_depths.len, world.sparseDepthRangeCount());
        _ = testWindowSparseKeys(&world, list);
    }
    try std.testing.expectEqualSlices(TestSparseKey, &lists[0], &lists[1]);
}

fn setSpriteAvailableForTest(runtime_assets: *RuntimeAssets, id: manifest.SpriteAssetId, texture: TextureId) void {
    runtime_assets.sprite_slots[manifest.spriteIndex(id)] = .{
        .status = .available,
        .lease = .{ .id = texture },
    };
}

test "a synced store reads back every resident window tile through splits, edits, re-uniforms, and pans" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 8x8 tiles in 4x4 chunks: a 2x2 chunk grid, every chunk starting uniform.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const level = try world.addLevel(0);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const layer = try world.addDenseLayer(level, 0, .floor, grass);
    var gpu = TestGpuStore{};
    defer gpu.deinit();

    // Entering: one directory, no blocks while every chunk is uniform.
    _ = try testSyncGpuTiles(&world, level);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(usize, 1), world.gpu_tiles.spans.items.len);
    try expectGpuStoreMatches(&world, &gpu);

    // One step splits all four chunks (a multi-chunk change), then edits one of
    // them again in the same step.
    for ([_][2]u16{ .{ 1, 1 }, .{ 6, 0 }, .{ 0, 7 }, .{ 7, 7 }, .{ 2, 1 } }) |cell| {
        _ = try world.setDenseTile(layer, cell[0], cell[1], water);
    }
    _ = try world.clearDenseTile(layer, 2, 1);
    _ = try testSyncGpuTiles(&world, level);
    try testApplySync(&world, &gpu);
    try expectGpuStoreMatches(&world, &gpu);

    // Repeated dig and fill: a chunk returning to one tile frees its block, and the
    // next split reuses it, so the store never grows.
    const high_water = world.gpu_tiles.high_water;
    for (0..3) |_| {
        _ = try world.setDenseTile(layer, 1, 1, grass);
        _ = try world.setDenseTile(layer, 2, 1, grass);
        _ = try testSyncGpuTiles(&world, level);
        try testApplySync(&world, &gpu);
        try expectGpuStoreMatches(&world, &gpu);
        _ = try world.setDenseTile(layer, 3, 3, water);
        _ = try testSyncGpuTiles(&world, level);
        try testApplySync(&world, &gpu);
        try expectGpuStoreMatches(&world, &gpu);
        _ = try world.setDenseTile(layer, 3, 3, grass);
        try std.testing.expectEqual(high_water, world.gpu_tiles.high_water);
    }

    // Pans one chunk at a time around the grid with a 1x1 window: every step reads
    // back, including edits made while a chunk was outside the window.
    const steps = [_][2]u16{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0 } };
    for (steps, 0..) |step, index| {
        try testShowChunks(&world, step[0], step[1], 1, 1, level);
        _ = try world.setDenseTile(layer, @intCast(4 + index % 4), 5, if (index % 2 == 0) water else grass);
        _ = try testSyncGpuTiles(&world, level);
        try testApplySync(&world, &gpu);
        try expectGpuStoreMatches(&world, &gpu);
    }
}

test "an edit outside the window uploads nothing; its chunk reads back edited when it enters" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 16x4 tiles in 4x4 chunks: a 4x1 chunk grid, the window one chunk wide.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 16,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const layer = try world.addDenseLayer(try world.addLevel(0), 0, .floor, grass);
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    try testShowChunks(&world, 0, 0, 1, 1, 0);
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);

    // Chunk 2 is outside the window: its dig uploads nothing.
    _ = try world.setDenseTile(layer, 9, 1, water);
    _ = try testSyncGpuTiles(&world, 0);
    try std.testing.expectEqual(@as(usize, 0), world.gpu_tiles.spans.items.len);

    // The window reaches it: the chunk uploads whole and reads back edited.
    try testShowChunks(&world, 2, 0, 1, 1, 0);
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(?TileId, water), testGpuTile(&world, &gpu, layer, 9, 1));
    try expectGpuStoreMatches(&world, &gpu);
}

test "an evicted layer's edits upload nothing; it reads back edited when it returns" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
        .render_window = .{ .levels_below = 0 },
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const surface = try world.addDenseLayer(try world.addLevel(0), 0, .floor, grass);
    _ = try world.addDenseLayer(try world.addLevel(-level_z_step), 0, .floor, grass);
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);

    // An edit made while resident, then the layer leaves before the next sync: the
    // sync that evicts it uploads only the entering layer's directory.
    _ = try world.setDenseTile(surface, 1, 1, water);
    _ = try testSyncGpuTiles(&world, 1);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(usize, 1), world.gpu_tiles.spans.items.len);
    try std.testing.expectEqual(world_gpu_tiles.no_slot, world.dense_layers.items(.gpu_slot)[surface]);
    // Edits while not resident upload nothing either.
    _ = try world.setDenseTile(surface, 6, 6, water);
    _ = try testSyncGpuTiles(&world, 1);
    try std.testing.expectEqual(@as(usize, 0), world.gpu_tiles.spans.items.len);

    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(?TileId, water), testGpuTile(&world, &gpu, surface, 1, 1));
    try std.testing.expectEqual(@as(?TileId, water), testGpuTile(&world, &gpu, surface, 6, 6));
    try expectGpuStoreMatches(&world, &gpu);
}

test "a reset GPU mirror re-enters every resident layer at the next sync" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 8x8 tiles in 4x4 chunks on two levels, one layer each.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const surface = try world.addDenseLayer(try world.addLevel(0), 0, .floor, grass);
    const below = try world.addDenseLayer(try world.addLevel(-level_z_step), 0, .floor, grass);
    var before = TestGpuStore{};
    defer before.deinit();
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &before);
    // Split one chunk on each layer and sync, then edit once more without a sync.
    _ = try world.setDenseTile(surface, 1, 1, water);
    _ = try world.setDenseTile(below, 6, 6, water);
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &before);
    _ = try world.setDenseTile(surface, 5, 1, water);
    world.gpu_tiles.store = .{ .index = 0, .generation = 1 };
    world.dense_quads_dirty = false;

    // The renderer retired the store: nothing stays resident or drawn.
    resetGpuResidency(&world);
    try std.testing.expect(!world.gpu_tiles.store.isValid());
    for (world.dense_layers.items(.gpu_slot)) |slot| try std.testing.expectEqual(world_gpu_tiles.no_slot, slot);
    try std.testing.expectEqual(@as(usize, 0), world.maxDenseSubmitDrawCount());
    try std.testing.expect(world.dense_quads_dirty);

    // A new store starts empty: the next sync uploads the window whole, the edit
    // made since the last sync included.
    var after = TestGpuStore{};
    defer after.deinit();
    const sync_plan = try testSyncGpuTiles(&world, 0);
    try std.testing.expect(sync_plan.relayout);
    try testApplySync(&world, &after);
    try std.testing.expectEqual(@as(usize, 2), world.maxDenseSubmitDrawCount());
    try std.testing.expectEqual(@as(?TileId, water), testGpuTile(&world, &after, surface, 5, 1));
    try expectGpuStoreMatches(&world, &after);
}

test "after a GPU residency reset the re-submitted static tilemap draws name the store the next sync holds" {
    const allocator = std.testing.allocator;
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 2, 2);
    defer world.deinit();
    var runtime_assets = RuntimeAssets.init(allocator);
    setSpriteAvailableForTest(&runtime_assets, .world_tileset, try TextureId.init(1, 1));
    // Headless: the static-geometry path never dereferences GPU handles.
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
    defer deinitStaticTestRenderer(&renderer);

    const retired = TileDataId{ .index = 0, .generation = 1 };
    world.gpu_tiles.store = retired;
    _ = try testSyncGpuTiles(&world, 0);
    try world.submitStaticDenseGeometry(&renderer, &runtime_assets, 0, &.{});
    try expectStaticTilemapStore(&renderer, retired);

    // A failed claim resets residency; the next sync re-enters the window and
    // creates a store, here the next generation of the same slot.
    resetGpuResidency(&world);
    const replacement = TileDataId{ .index = 0, .generation = 2 };
    _ = try testSyncGpuTiles(&world, 0);
    world.gpu_tiles.store = replacement;
    try world.submitStaticDenseGeometry(&renderer, &runtime_assets, 0, &.{});
    try expectStaticTilemapStore(&renderer, replacement);
}

fn deinitStaticTestRenderer(renderer: *Renderer) void {
    const allocator = renderer.allocator;
    renderer.batch.deinit();
    renderer.static_positions.deinit(allocator);
    renderer.static_uvs.deinit(allocator);
    renderer.static_colors.deinit(allocator);
    renderer.static_groups.deinit(allocator);
    renderer.tilemap_window_layers.deinit(allocator);
    renderer.draw_list.deinit(allocator);
    for (renderer.tile_stores.items) |*store| {
        store.pending_spans.deinit(allocator);
        store.pending_values.deinit(allocator);
    }
    renderer.tile_stores.deinit(allocator);
    renderer.tile_merge_spans.deinit(allocator);
    renderer.tile_merge_values.deinit(allocator);
}

fn expectStaticTilemapStore(renderer: *const Renderer, store: TileDataId) !void {
    var tilemap_draws: usize = 0;
    for (renderer.static_groups.items) |group| {
        if (group.material != .tilemap) continue;
        tilemap_draws += 1;
        try std.testing.expectEqual(store, group.tile_data);
    }
    try std.testing.expect(tilemap_draws > 0);
}

// Registers a store with no GPU buffer in a headless renderer and hands it to
// `world`, laid out for its render window, so syncs validate and queue uploads
// without touching SDL. The capacity covers any test world, so no sync grows it.
fn attachFakeTileStore(renderer: *Renderer, world: *WorldSystem) !*@TypeOf(renderer.tile_stores.items[0]) {
    try renderer.tile_stores.append(renderer.allocator, .{
        .buffer = @ptrFromInt(0x1000),
        .element_capacity = 1 << 20,
        .params = std.mem.zeroes(TilemapParams),
    });
    world.gpu_tiles.store = .{ .index = @intCast(renderer.tile_stores.items.len - 1), .generation = 1 };
    world.gpu_tiles.store_side = world.render_side;
    return &renderer.tile_stores.items[renderer.tile_stores.items.len - 1];
}

test "syncDenseTileStore claims its live store every frame and drops a retired one with its residency" {
    const allocator = std.testing.allocator;
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = allocator,
        .width = 8,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
        .render_window = .{ .levels_below = 0 },
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const layer = try world.addDenseLayer(try world.addLevel(0), 0, .floor, grass);
    // Level 1 holds no layer, so syncing there needs no store and never creates one.
    _ = try world.addLevel(-level_z_step);
    try testShowWholeWorld(&world, 0);

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
    defer deinitStaticTestRenderer(&renderer);
    const store = try attachFakeTileStore(&renderer, &world);

    // Every sync claims the live store, even one with nothing to upload, and moves
    // its window uniform to the render window.
    try world.syncDenseTileStore(&renderer, 0);
    try std.testing.expect(store.claimed);
    try std.testing.expectEqual([4]u32{ 0, 0, 2, 2 }, store.params.window);
    try std.testing.expect(world.dense_layers.items(.gpu_slot)[layer] != world_gpu_tiles.no_slot);
    store.claimed = false;
    try world.syncDenseTileStore(&renderer, 0);
    try std.testing.expect(store.claimed);

    // The renderer retired the store (generation advanced): the next sync drops
    // the stale id and every resident layer, and re-submits the draws.
    store.generation = 2;
    world.dense_quads_dirty = false;
    try world.syncDenseTileStore(&renderer, 1);
    try std.testing.expect(!world.gpu_tiles.store.isValid());
    try std.testing.expectEqual(world_gpu_tiles.no_slot, world.dense_layers.items(.gpu_slot)[layer]);
    try std.testing.expect(world.dense_quads_dirty);
}

test "a sync whose upload reserve fails keeps residency and change marks, and the retry uploads the edit" {
    const allocator = std.testing.allocator;
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = allocator,
        .width = 8,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
        .render_window = .{ .levels_below = 0 },
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const layer = try world.addDenseLayer(try world.addLevel(0), 0, .floor, grass);
    try testShowWholeWorld(&world, 0);
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
    defer deinitStaticTestRenderer(&renderer);
    const store = try attachFakeTileStore(&renderer, &world);
    try world.syncDenseTileStore(&renderer, 0);

    // An edit on the resident layer, then a sync whose upload reserve cannot grow the
    // carried batch: the mirror must not commit, so the edit stays marked.
    _ = try world.setDenseTile(layer, 1, 1, water);
    {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        renderer.allocator = failing.allocator();
        defer renderer.allocator = allocator;
        try std.testing.expectError(error.OutOfMemory, world.syncDenseTileStore(&renderer, 0));
    }
    try std.testing.expect(world.resident_layers_changed and world.dense_layers.items(.render_changed)[layer]);
    try std.testing.expect(world.dense_layers.items(.store)[layer].blockChanged(0));

    // The retry uploads it: the store's pending batch shows what the mirror holds.
    try world.syncDenseTileStore(&renderer, 0);
    try std.testing.expect(!world.resident_layers_changed);
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    try gpu.apply(store.pending_spans.items, store.pending_values.items);
    try expectGpuStoreMatches(&world, &gpu);
    try std.testing.expectEqual(@as(?TileId, water), testGpuTile(&world, &gpu, layer, 1, 1));
}

test "a new directory side with nothing resident lets the old store go and re-submits the draws" {
    const allocator = std.testing.allocator;
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 16x16 tiles in 4x4 chunks; level 1 holds no layer.
    var world = WorldSystem{
        .allocator = allocator,
        .width = 16,
        .height = 16,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
        .render_window = .{ .levels_below = 0 },
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const layer = try world.addDenseLayer(try world.addLevel(0), 0, .floor, grass);
    _ = try world.addLevel(-level_z_step);
    try testShowChunks(&world, 0, 0, 1, 1, 0);
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
    defer deinitStaticTestRenderer(&renderer);
    const store = try attachFakeTileStore(&renderer, &world);
    try world.syncDenseTileStore(&renderer, 0);
    try std.testing.expect(world.gpu_tiles.store.isValid());
    try std.testing.expectEqual([4]u32{ 0, 0, 1, 1 }, store.params.window);

    // A wider rect needs a larger side; on a level with no layer nothing uploads,
    // so the world stops naming (and claiming) the old store's layout.
    try testShowChunks(&world, 0, 0, 3, 3, 1);
    world.dense_quads_dirty = false;
    try world.syncDenseTileStore(&renderer, 1);
    try std.testing.expect(!world.gpu_tiles.store.isValid());
    try std.testing.expectEqual(world_gpu_tiles.no_slot, world.dense_layers.items(.gpu_slot)[layer]);
    try std.testing.expect(world.dense_quads_dirty);
    try std.testing.expectEqual(@as(usize, 0), world.maxDenseSubmitDrawCount());
}

test "setDenseTile on a resident layer uploads at the next sync; one outside the level window uploads when it enters" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMetaWithUnderground(std.testing.allocator, &meta, 96, 64);
    defer world.deinit();
    world.render_window = .{ .levels_below = 0 };
    const water = try world.requireTileByName(&meta, "water_1");
    const grass = try world.requireTileByName(&meta, "grass");
    const below = world.denseFloorLayerForLevel(1).?;
    var gpu = TestGpuStore{};
    defer gpu.deinit();

    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    // Not resident: nothing uploads.
    _ = try world.setDenseTile(below, 2, 1, grass);
    _ = try testSyncGpuTiles(&world, 0);
    try std.testing.expectEqual(@as(usize, 0), world.gpu_tiles.spans.items.len);
    // Resident: the next sync uploads it; an unchanged tile uploads nothing.
    _ = try world.setDenseTile(0, 1, 0, water);
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(?TileId, water), testGpuTile(&world, &gpu, 0, 1, 0));
    try std.testing.expect((try world.setDenseTile(0, 1, 0, water)) == null);
    _ = try testSyncGpuTiles(&world, 0);
    try std.testing.expectEqual(@as(usize, 0), world.gpu_tiles.spans.items.len);

    _ = try testSyncGpuTiles(&world, 1);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(?TileId, grass), testGpuTile(&world, &gpu, below, 2, 1));
    try expectGpuStoreMatches(&world, &gpu);
}

test "a split chunk uploads its word and whole block; later edits re-upload the block once" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const level = try world.addLevel(0);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const layer = try world.addDenseLayer(level, 0, .floor, grass);
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    _ = try testSyncGpuTiles(&world, level);
    try testApplySync(&world, &gpu);
    // One chunk: a directory of side 1 (one word and the link) at 0, blocks after it.
    const block = world_gpu_tiles.directoryWords(1);

    // Splitting the chunk uploads its directory word and its whole block.
    _ = try world.setDenseTile(layer, 2, 0, water);
    _ = try testSyncGpuTiles(&world, level);
    try std.testing.expectEqualSlices(TileStoreSpan, &.{
        .{ .dst_element = 0, .count = 1 },
        .{ .dst_element = block, .count = 8 },
    }, world.gpu_tiles.spans.items);
    try testApplySync(&world, &gpu);

    // Three edits, one cell twice, then the same frame again: the block uploads
    // whole once, valued from the chunk store, and nothing after.
    _ = try world.setDenseTile(layer, 1, 0, water);
    _ = try world.setDenseTile(layer, 0, 0, water);
    _ = try world.clearDenseTile(layer, 0, 0);
    _ = try testSyncGpuTiles(&world, level);
    try std.testing.expectEqualSlices(TileStoreSpan, &.{
        .{ .dst_element = block, .count = 8 },
    }, world.gpu_tiles.spans.items);
    try testApplySync(&world, &gpu);
    try expectGpuStoreMatches(&world, &gpu);
    _ = try testSyncGpuTiles(&world, level);
    try std.testing.expectEqual(@as(usize, 0), world.gpu_tiles.spans.items.len);
}

test "two resident layers on one level upload to their own directories and blocks" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 3, 1);
    defer world.deinit();
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const layer1 = try world.addDenseLayer(0, 0, .obstacle, water);
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    const slots = world.dense_layers.items(.gpu_slot);
    try std.testing.expect(world.gpu_tiles.slotDirectory(slots[0]) != world.gpu_tiles.slotDirectory(slots[layer1]));

    // Edits in both layers in one frame write separate blocks; neither layer reads
    // the other's cells.
    _ = try world.setDenseTile(0, 2, 0, water);
    _ = try world.setDenseTile(layer1, 0, 0, grass);
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    try expectGpuStoreMatches(&world, &gpu);
    _ = try world.clearDenseTile(0, 2, 0);
    _ = try world.setDenseTile(layer1, 1, 0, grass);
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(usize, 2), world.gpu_tiles.spans.items.len);
    try expectGpuStoreMatches(&world, &gpu);
}

test "a cleared sparse tile no longer blocks and is not in the window list; an unrelated removal keeps the draw order" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testSparseWindowWorld(&meta, std.testing.allocator, 2);
    defer world.deinit();
    const deco = try world.requireTileByName(&meta, "deco_0");
    const tree = try world.requireTileByName(&meta, "tree_0");
    const stone = try world.requireTileByName(&meta, "stone_floor");
    const tunnel = try world.requireTileByName(&meta, "cave_0");

    // Row 0 lies outside the window; the last row lies inside it, so removing row 0
    // moves an in-window row.
    _ = try world.addSparseTile(0, 12, 12, deco, 0, .obstacle);
    _ = try world.addSparseTile(0, 2, 2, tree, 0, .obstacle);
    _ = try world.addSparseTile(0, 2, 2, stone, 0, .floor);
    _ = try world.addSparseTile(1, 3, 1, deco, 0, .obstacle);
    _ = try world.addSparseTile(0, 5, 6, deco, 0, .effect);
    _ = try world.addSparseTile(0, 1, 7, tree, 0, .obstacle);
    try testShowTiles(&world, 0, 8, 0, 0);
    var keys_buf: [8]TestSparseKey = undefined;
    var before_buf: [8]TestSparseKey = undefined;
    const before = testWindowSparseKeys(&world, &before_buf);
    try std.testing.expectEqual(@as(usize, 5), before.len);

    // The unrelated removal moves a window row: the list rebuilds, same draw order.
    try std.testing.expect((try world.clearCellBlocking(0, 12, 12, tunnel)) != null);
    try std.testing.expect(world.sparse_window.dirty);
    try testShowTiles(&world, 0, 8, 0, 0);
    try std.testing.expectEqualSlices(TestSparseKey, before, testWindowSparseKeys(&world, &keys_buf));
    try expectSparseRangesCoverWindow(&world);

    // Clearing (2, 2) drops its blocking tree and keeps the walkable decal.
    try std.testing.expect(world.levelBlocksMovement(0, 2, 2));
    try std.testing.expect((try world.clearCellBlocking(0, 2, 2, tunnel)) != null);
    try std.testing.expect(!world.levelBlocksMovement(0, 2, 2));
    try std.testing.expect(world.sparse_window.dirty);
    try testShowTiles(&world, 0, 8, 0, 0);
    const after = testWindowSparseKeys(&world, &keys_buf);
    try std.testing.expectEqual(@as(usize, 4), after.len);
    const cleared_cell = world.cellIndex(2, 2);
    for (after) |key| try std.testing.expect(key.cell != cleared_cell or key.tile_id == stone);
    try expectSparseRangesCoverWindow(&world);
    try expectSparseIndexConsistent(&world);
}

test "dense layer submit order sorts back to front by render depth" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 4, 4);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    var indices: [3]u32 = .{ 0, 1, 2 };
    std.mem.sort(u32, &indices, &world, denseLayerIndexLessThan);
    try std.testing.expectEqual(@as(i32, -34), denseLayerOrder(&world, indices[0]).depth);
    try std.testing.expectEqual(@as(i32, -18), denseLayerOrder(&world, indices[1]).depth);
    try std.testing.expectEqual(@as(i32, -2), denseLayerOrder(&world, indices[2]).depth);
}

test "underground dense layers append in storage order not ascending render depth" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 4, 4);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    try std.testing.expectEqual(@as(usize, 3), world.denseLayerCount());
    const grass_depth = denseLayerOrder(&world, 0).depth;
    const dirt_depth = denseLayerOrder(&world, 1).depth;
    const dirt_dark_depth = denseLayerOrder(&world, 2).depth;
    // Back-to-front draw order: dirt_dark, dirt, grass (grass on top).
    try std.testing.expect(dirt_dark_depth < dirt_depth and dirt_depth < grass_depth);
    // `submitStaticDenseGeometry` walks dense_layer index order (surface first):
    // depths descend with index, so a linear merge must not assume ascending input.
    try std.testing.expect(grass_depth > dirt_depth and dirt_depth > dirt_dark_depth);
}

test "dense layers order by z level and quads re-submit only on structural change" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);

    const lower_level = try world.addLevel(0);
    const upper_level = try world.addLevel(10);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const lower_layer = try world.addDenseLayer(lower_level, 0, .floor, grass);
    const upper_layer = try world.addDenseLayer(upper_level, 0, .floor, grass);

    // A higher base-z level carries a strictly higher order; the ordered draw list
    // interleaves each dense tilemap quad with dynamic entities by this depth.
    try std.testing.expect(denseLayerOrder(&world, lower_layer).depth < denseLayerOrder(&world, upper_layer).depth);

    // A structural change (new level or layer) arms a quad re-submit.
    try std.testing.expect(world.dense_quads_dirty);
    world.dense_quads_dirty = false;

    // A dig changes tile-data, not quad geometry, so it does not re-arm a re-submit
    // (the GPU buffer is updated directly by the dig hook).
    _ = try world.setDenseTile(lower_layer, 3, 3, water);
    try std.testing.expect(!world.dense_quads_dirty);

    // A pan changes chunk visibility (crops sparse tiles) but not the full-world
    // dense quads, so it does not re-arm a re-submit either.
    try world.setVisibleChunksForWorldRect(.{ .x = 1024, .y = 1024, .w = 128, .h = 128 }, 0, 0);
    try std.testing.expect(!world.dense_quads_dirty);
}

test "dense render window includes six levels below surface play" {
    const window: DenseLayerRenderWindow = .{};
    const max_level: u16 = 31;
    try std.testing.expect(window.levelInWindow(0, 0, max_level));
    try std.testing.expect(window.levelInWindow(0, 6, max_level));
    try std.testing.expect(!window.levelInWindow(0, 7, max_level));
}

test "dense render window skips floors above the player underground" {
    const window: DenseLayerRenderWindow = .{};
    const max_level: u16 = 50;
    try std.testing.expect(!window.levelInWindow(20, 0, max_level));
    try std.testing.expect(!window.levelInWindow(20, 19, max_level));
    try std.testing.expect(window.levelInWindow(20, 20, max_level));
    try std.testing.expect(window.levelInWindow(20, 26, max_level));
    try std.testing.expect(!window.levelInWindow(20, 27, max_level));
}

test "dense render window optional ceiling band is opt-in" {
    const window: DenseLayerRenderWindow = .{ .ceiling_when_underground = true };
    const max_level: u16 = 50;
    try std.testing.expect(window.levelInWindow(20, 19, max_level));
    try std.testing.expect(!window.levelInWindow(20, 18, max_level));
}

test "collectDenseSubmitLayers caps surface play to render window" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    for (0..32) |level_index| {
        const level = try world.addLevel(@intCast(@as(i32, @intCast(level_index)) * level_z_step));
        _ = try world.addDenseLayer(level, 0, .floor, grass);
    }

    var layer_buffer: [64]u32 = undefined;
    const layers = try testSubmitLayers(&world, 0, &layer_buffer);
    const count = layers.len;
    try std.testing.expectEqual(@as(usize, 7), count);
    for (layers[0..count]) |layer_index| {
        const level = world.denseLayerLevel(layer_index);
        try std.testing.expect(level <= 6);
    }
    for (1..count) |sorted_index| {
        try std.testing.expect(
            denseLayerOrder(&world, layers[sorted_index - 1]).depth <
                denseLayerOrder(&world, layers[sorted_index]).depth,
        );
    }
}

test "collectDenseSubmitLayers deep play follows player level not surface" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    for (0..50) |level_index| {
        const level = try world.addLevel(@intCast(@as(i32, @intCast(level_index)) * level_z_step));
        _ = try world.addDenseLayer(level, 0, .floor, grass);
    }

    var layer_buffer: [64]u32 = undefined;
    const layers = try testSubmitLayers(&world, 20, &layer_buffer);
    const count = layers.len;
    try std.testing.expectEqual(@as(usize, 7), count);
    for (layers[0..count]) |layer_index| {
        const level = world.denseLayerLevel(layer_index);
        try std.testing.expect(level >= 20 and level <= 26);
    }
}

test "collectDenseSubmitLayers shifts with player level transitions" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 4, 4);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    var layer_buffer: [64]u32 = undefined;
    var layers = try testSubmitLayers(&world, 0, &layer_buffer);
    const surface_count = layers.len;
    try std.testing.expectEqual(@as(usize, 3), surface_count);
    var saw_surface = false;
    for (layers[0..surface_count]) |layer_index| {
        if (world.denseLayerLevel(layer_index) == 0) saw_surface = true;
    }
    try std.testing.expect(saw_surface);

    layers = try testSubmitLayers(&world, 1, &layer_buffer);
    const dirt_count = layers.len;
    try std.testing.expectEqual(@as(usize, 2), dirt_count);
    for (layers[0..dirt_count]) |layer_index| {
        try std.testing.expect(world.denseLayerLevel(layer_index) >= 1);
    }

    layers = try testSubmitLayers(&world, 2, &layer_buffer);
    const void_count = layers.len;
    try std.testing.expectEqual(@as(usize, 1), void_count);
    try std.testing.expectEqual(@as(u16, 2), world.denseLayerLevel(layers[0]));
}

test "collectDenseSubmitLayers includes every band on an in-window level" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const level = try world.addLevel(0);
    _ = try world.addDenseLayer(level, 0, .floor, grass);
    _ = try world.addDenseLayer(level, 0, .obstacle, grass);

    var layer_buffer: [64]u32 = undefined;
    const layers = try testSubmitLayers(&world, 0, &layer_buffer);
    const count = layers.len;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "denseWindowDepthSpan returns the resident layers' deepest and shallowest depth" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 4, 4);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    // Nothing is resident before the first sync.
    try std.testing.expect(world.denseWindowDepthSpan() == null);
    _ = try testSyncGpuTiles(&world, 0);
    const span = world.denseWindowDepthSpan() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(denseLayerOrder(&world, 2).depth, span.min);
    try std.testing.expectEqual(denseLayerOrder(&world, 0).depth, span.max);
    try std.testing.expectEqual(@as(usize, 3), world.denseWindowLayerDepths().len);

    // The span follows the resident set to the next level at the next sync.
    _ = try testSyncGpuTiles(&world, 1);
    const deeper = world.denseWindowDepthSpan() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(denseLayerOrder(&world, 2).depth, deeper.min);
    try std.testing.expectEqual(denseLayerOrder(&world, 1).depth, deeper.max);
}

test "denseWindowDepthSpan returns null when nothing is in window" {
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = 32,
        .chunk_size_tiles = 2,
    };
    defer world.deinit();

    try std.testing.expect(world.denseWindowDepthSpan() == null);
}

test "partitionDenseCompositeBuckets returns a single bucket with no interleave depths in window" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 4, 4);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    var layer_buffer: [64]u32 = undefined;
    const layers = try testSubmitLayers(&world, 0, &layer_buffer);
    const count = layers.len;

    var buckets: [64]WorldSystem.DenseCompositeBucket = undefined;
    const bucket_count = partitionDenseCompositeBuckets(&world, layers[0..count], &.{}, &buckets);

    try std.testing.expectEqual(@as(usize, 1), bucket_count);
    try std.testing.expectEqual(@as(usize, 0), buckets[0].start);
    try std.testing.expectEqual(count, buckets[0].end);
}

test "partitionDenseCompositeBuckets splits off the ceiling layer at the active level's own actor depth" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
        .render_window = .{ .ceiling_when_underground = true },
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    for (0..5) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        _ = try world.addDenseLayer(level, 0, .floor, grass);
    }

    var layer_buffer: [64]u32 = undefined;
    const layers = try testSubmitLayers(&world, 2, &layer_buffer);
    const count = layers.len;
    try std.testing.expectEqual(@as(usize, 4), count);

    // The active level's own actor depth is the only interleave point — mirrors
    // today's ceiling-vs-window split, now expressed as the general rule.
    const interleave = [_]i32{world.activeLevelActorDepth(2)};
    var buckets: [64]WorldSystem.DenseCompositeBucket = undefined;
    const bucket_count = partitionDenseCompositeBuckets(&world, layers[0..count], &interleave, &buckets);

    try std.testing.expectEqual(@as(usize, 2), bucket_count);
    try std.testing.expectEqual(@as(usize, 3), buckets[0].end - buckets[0].start);
    try std.testing.expectEqual(@as(usize, 1), buckets[1].end - buckets[1].start);
    try std.testing.expectEqual(@as(u16, 1), world.denseLayerLevel(layers[buckets[1].start]));
}

test "partitionDenseCompositeBuckets splits at a synthetic interleave point on a deeper non-active level" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    for (0..7) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        _ = try world.addDenseLayer(level, 0, .floor, grass);
    }

    var layer_buffer: [64]u32 = undefined;
    const layers = try testSubmitLayers(&world, 0, &layer_buffer);
    const count = layers.len;
    try std.testing.expectEqual(@as(usize, 7), count);

    // A synthetic sandwich point (e.g. a sparse tile) between level 5 and level
    // 4's own floor depths — neither is the active level (0) nor the window's
    // shallowest layer. This is the case an active-level-only design would miss.
    const interleave = [_]i32{world.worldZForLevel(5, 0, .effect)};
    var buckets: [64]WorldSystem.DenseCompositeBucket = undefined;
    const bucket_count = partitionDenseCompositeBuckets(&world, layers[0..count], &interleave, &buckets);

    try std.testing.expectEqual(@as(usize, 2), bucket_count);
    try std.testing.expectEqual(@as(usize, 2), buckets[0].end - buckets[0].start);
    try std.testing.expectEqual(@as(usize, 5), buckets[1].end - buckets[1].start);
    try std.testing.expectEqual(@as(u16, 5), world.denseLayerLevel(layers[buckets[0].end - 1]));
    try std.testing.expectEqual(@as(u16, 4), world.denseLayerLevel(layers[buckets[1].start]));
}

test "partitionDenseCompositeBuckets produces one bucket per cut point when every gap is cut" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
        .render_window = .{ .levels_below = 40 },
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const level_count = 40;
    for (0..level_count) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        _ = try world.addDenseLayer(level, 0, .floor, grass);
    }

    var layer_buffer: [64]u32 = undefined;
    const layers = try testSubmitLayers(&world, 0, &layer_buffer);
    try std.testing.expectEqual(@as(usize, level_count), layers.len);

    // One interleave point strictly between every consecutive pair: one bucket per
    // layer, the most a partition can produce.
    var interleave: [level_count - 1]i32 = undefined;
    for (&interleave, 0..) |*depth, i| {
        const deeper = denseLayerOrder(&world, layers[i]).depth;
        const shallower = denseLayerOrder(&world, layers[i + 1]).depth;
        depth.* = deeper + @divTrunc(shallower - deeper, 2);
    }

    var buckets: [64]WorldSystem.DenseCompositeBucket = undefined;
    const bucket_count = partitionDenseCompositeBuckets(&world, layers, &interleave, &buckets);

    try std.testing.expectEqual(@as(usize, level_count), bucket_count);
    for (buckets[0..bucket_count]) |bucket| {
        try std.testing.expectEqual(@as(usize, 1), bucket.end - bucket.start);
    }
}

test "buildWindowLayers names each bucket's topmost resident directory and its layer count" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 4, 4);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);
    _ = try testSyncGpuTiles(&world, 0);

    // Resident layers are deepest first (dirt_dark, dirt, grass); the shader walks
    // a chain topmost first, so a bucket starts at its shallowest layer.
    const layers = world.dense_render.layers.items;
    try std.testing.expectEqual(@as(usize, 3), layers.len);
    const slots = world.dense_layers.items(.gpu_slot);
    const whole = buildWindowLayers(&world, 0, 3);
    try std.testing.expectEqual(world.gpu_tiles.slotDirectory(slots[layers[2]]), whole.first_directory);
    try std.testing.expectEqual(@as(u32, 3), whole.count);
    const deeper = buildWindowLayers(&world, 0, 2);
    try std.testing.expectEqual(world.gpu_tiles.slotDirectory(slots[layers[1]]), deeper.first_directory);
    try std.testing.expectEqual(@as(u32, 2), deeper.count);
}

test "submitStaticDenseGeometry marks only the bucket holding the shallowest submitted layer, regardless of where an unrelated interleave point splits the stack" {
    const allocator = std.testing.allocator;
    var meta = try testWorldMeta();
    defer meta.deinit();

    var world = try testMinimalSurfaceWorld(&meta, 2, 2);
    defer world.deinit();
    const grass = try world.requireTileByName(&meta, "grass");
    const level1 = try world.addLevel(-level_z_step);
    _ = try world.addDenseLayer(level1, 0, .floor, grass);
    _ = try testSyncGpuTiles(&world, 0);

    var runtime_assets = RuntimeAssets.init(allocator);
    setSpriteAvailableForTest(&runtime_assets, .world_tileset, try TextureId.init(1, 1));

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
    defer deinitStaticTestRenderer(&renderer);

    // No interleave points this frame: both layers merge into one bucket,
    // which must be marked shallowest (the common case the rim-shadow effect
    // was originally written for).
    try world.submitStaticDenseGeometry(&renderer, &runtime_assets, 0, &.{});
    try std.testing.expectEqual(@as(usize, 1), renderer.tilemap_window_layers.items.len);
    try std.testing.expect(renderer.tilemap_window_layers.items[0].is_shallowest_bucket);

    // An unrelated interleave point (e.g. a dynamic entity or sparse tile
    // elsewhere on the map, nothing to do with this cell's own geometry)
    // strictly between the two layers' depths splits them into two buckets.
    // The deeper bucket -- exactly what a hole in the surface layer would
    // reveal -- must never be marked shallowest, matching the shader's
    // "tile visible through the hole is left alone" contract regardless of
    // how the CPU happened to bucket the draws this frame.
    world.dense_quads_dirty = true;
    const surface_depth = denseLayerOrder(&world, 0).depth;
    const deeper_depth = denseLayerOrder(&world, 1).depth;
    const cut = deeper_depth + @divTrunc(surface_depth - deeper_depth, 2);
    try world.submitStaticDenseGeometry(&renderer, &runtime_assets, 0, &.{cut});

    try std.testing.expectEqual(@as(usize, 2), renderer.tilemap_window_layers.items.len);
    try std.testing.expect(!renderer.tilemap_window_layers.items[0].is_shallowest_bucket);
    try std.testing.expect(renderer.tilemap_window_layers.items[1].is_shallowest_bucket);
}

test "a dense layer added on a resident level enters the GPU tile store at the next sync" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try testMinimalSurfaceWorld(&meta, 2, 2);
    defer world.deinit();
    const water = try world.requireTileByName(&meta, "water_1");
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(usize, 1), world.gpu_tiles.residentLayerCount());

    const added = try world.addDenseLayer(0, 0, .obstacle, water);
    try std.testing.expectEqual(world_gpu_tiles.no_slot, world.dense_layers.items(.gpu_slot)[added]);
    _ = try world.clearDenseTile(added, 1, 1);
    const sync_plan = try testSyncGpuTiles(&world, 0);
    try std.testing.expectEqual(@as(usize, 1), sync_plan.enter_count);
    try testApplySync(&world, &gpu);
    try std.testing.expect(world.dense_layers.items(.gpu_slot)[added] != world_gpu_tiles.no_slot);
    try std.testing.expectEqual(@as(usize, 2), world.gpu_tiles.residentLayerCount());
    try expectGpuStoreMatches(&world, &gpu);
}

test "a level whose full-level GPU store would overflow u32 is created and renders a window" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 8192x8192 cells in 16-cell chunks: a whole-level directory set and block per
    // chunk would pass the u32 byte width, a window-sized store does not come near.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8192,
        .height = 8192,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 16,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const layer = try world.addDenseLayer(try world.addLevel(0), 0, .floor, grass);
    _ = try world.setDenseTile(layer, 8000, 8000, water);
    try testShowChunks(&world, 499, 499, 2, 2, 0);
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    const sync_plan = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    // One directory of side 4 and the one mixed chunk's block.
    try std.testing.expectEqual(world_gpu_tiles.directoryWords(4) + tileStoreBlockElements(16), sync_plan.required_elements);
    try std.testing.expectEqual(@as(?TileId, water), testGpuTile(&world, &gpu, layer, 8000, 8000));
}

test "GPU store bytes are the same for the same window at 64 and 512 tiles a side" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var bytes: [2]u64 = undefined;
    for ([_]u16{ 64, 512 }, &bytes) |side, *out| {
        var world = WorldSystem{
            .allocator = std.testing.allocator,
            .width = side,
            .height = side,
            .tile_size = meta.tileSize(),
            .chunk_size_tiles = 16,
            .render_window = .{ .levels_below = 1 },
        };
        defer world.deinit();
        try world.buildCatalog(&meta);
        const grass = try world.requireTileByName(&meta, "grass");
        const water = try world.requireTileByName(&meta, "water_1");
        for (0..3) |level_index| {
            const layer = try world.addDenseLayer(try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step), 0, .floor, grass);
            // Every chunk of the level is mixed.
            for (0..side / 16) |chunk_y| for (0..side / 16) |chunk_x| {
                _ = try world.setDenseTile(layer, @intCast(chunk_x * 16 + 3), @intCast(chunk_y * 16 + 3), water);
            };
        }
        try testShowChunks(&world, 1, 1, 2, 2, 0);
        _ = try testSyncGpuTiles(&world, 0);
        out.* = world.gpu_tiles.residentBytes();
    }
    try std.testing.expectEqual(bytes[0], bytes[1]);
    // Two resident layers: a side-4 directory and four blocks each.
    try std.testing.expectEqual(@as(u64, 2 * (world_gpu_tiles.directoryWords(4) + 4 * tileStoreBlockElements(16)) * 4), bytes[0]);
}

test "GPU residency follows the window and a pan uploads only entering chunks" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    // 32x8 tiles in 4x4 chunks: an 8x2 chunk grid on four levels, two in the window.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 32,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
        .render_window = .{ .levels_below = 1 },
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    var layers: [4]usize = undefined;
    for (&layers, 0..) |*layer, level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        layer.* = try world.addDenseLayer(level, 0, .floor, grass);
        // Every chunk of every level is mixed.
        for (0..8) |chunk_x| for (0..2) |chunk_y| {
            _ = try world.setDenseTile(layer.*, @intCast(chunk_x * 4 + 1), @intCast(chunk_y * 4 + 2), water);
        };
    }
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    const slots = world.dense_layers.items(.gpu_slot);
    const block_elements = tileStoreBlockElements(4);

    // A 2x2 chunk window over levels 0 and 1: two directories and four blocks each;
    // chunks outside the window upload nothing.
    try testShowChunks(&world, 0, 0, 2, 2, 0);
    var sync_plan = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(usize, 2), sync_plan.enter_count);
    try std.testing.expectEqual(@as(usize, 2 * (1 + 4)), world.gpu_tiles.spans.items.len);
    try std.testing.expectEqual(world_gpu_tiles.no_slot, slots[layers[2]]);
    try expectGpuStoreMatches(&world, &gpu);

    // A pan inside the same chunks uploads nothing.
    try world.setVisibleChunksForWorldRect(.{ .x = 3, .y = 3, .w = 2 * 4 * world.tile_size - 6, .h = 2 * 4 * world.tile_size - 6 }, 0, 0);
    sync_plan = try testSyncGpuTiles(&world, 0);
    try std.testing.expectEqual(@as(usize, 0), sync_plan.span_count);

    // A long pan right, one chunk per step: each step uploads the entering column
    // (a word and a block per chunk and layer), frees the leaving column's blocks,
    // and the store's high water stays flat.
    const high_water = world.gpu_tiles.high_water;
    for (1..7) |step| {
        try testShowChunks(&world, @intCast(step), 0, 2, 2, 0);
        sync_plan = try testSyncGpuTiles(&world, 0);
        try testApplySync(&world, &gpu);
        try std.testing.expectEqual(@as(usize, 2 * 2 * 2), world.gpu_tiles.spans.items.len);
        try std.testing.expectEqual(@as(usize, 2 * 2 * (1 + block_elements)), world.gpu_tiles.values.items.len);
        try std.testing.expectEqual(high_water, world.gpu_tiles.high_water);
        try expectGpuStoreMatches(&world, &gpu);
    }

    // Moving down one level: level 0 leaves, level 2 enters, level 1 keeps its
    // directory and rewrites only its link.
    const kept_directory = world.gpu_tiles.slotDirectory(slots[layers[1]]);
    sync_plan = try testSyncGpuTiles(&world, 1);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(usize, 1), sync_plan.enter_count);
    try std.testing.expectEqual(@as(usize, 1), sync_plan.evict_count);
    try std.testing.expectEqual(world_gpu_tiles.no_slot, slots[layers[0]]);
    try std.testing.expectEqual(kept_directory, world.gpu_tiles.slotDirectory(slots[layers[1]]));
    try std.testing.expectEqual(high_water, world.gpu_tiles.high_water);
    try expectGpuStoreMatches(&world, &gpu);
}

test "a window of 80 resident layers composites in one chained draw" {
    const allocator = std.testing.allocator;
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = allocator,
        .width = 4,
        .height = 4,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 2,
        .render_window = .{ .levels_below = 39 },
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    var deepest_floor: usize = 0;
    for (0..40) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        deepest_floor = try world.addDenseLayer(level, 0, .floor, grass);
        const obstacle = try world.addDenseLayer(level, 0, .obstacle, water);
        // Holes everywhere but the deepest floor, so (1, 1) composites through all 80.
        _ = try world.clearDenseTile(obstacle, 1, 1);
        if (level_index + 1 < 40) _ = try world.clearDenseTile(deepest_floor, 1, 1);
    }
    var gpu = TestGpuStore{};
    defer gpu.deinit();
    _ = try testSyncGpuTiles(&world, 0);
    try testApplySync(&world, &gpu);
    try std.testing.expectEqual(@as(usize, 80), world.maxDenseSubmitDrawCount());
    try expectGpuStoreMatches(&world, &gpu);

    var runtime_assets = RuntimeAssets.init(allocator);
    setSpriteAvailableForTest(&runtime_assets, .world_tileset, try TextureId.init(1, 1));
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
    defer deinitStaticTestRenderer(&renderer);
    try world.submitStaticDenseGeometry(&renderer, &runtime_assets, 0, &.{});
    try std.testing.expectEqual(@as(usize, 1), renderer.static_groups.items.len);
    const chain = renderer.tilemap_window_layers.items[0];
    try std.testing.expectEqual(@as(u32, 80), chain.count);
    // The draw's chain reaches the deepest floor's tile through 79 holes.
    const mirror = &world.gpu_tiles;
    try std.testing.expectEqual(@as(?TileId, grass), gpu.composite(world.chunkGeometry(), mirror.side, mirror.window, chain.first_directory, chain.count, invalid_tile_id, 1, 1));
    try std.testing.expectEqual(world.dense_layers.items(.gpu_slot)[deepest_floor], mirror.order.items[mirror.order.items.len - 1]);
}

test "a chunk window wider than the largest directory side is clipped to it and syncs" {
    // Exercises a reported clip: keep its `log.warn` off the test runner's stderr.
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;
    // 40000x1 tiles in 1-tile chunks: a rect over the whole level spans more chunks
    // than any directory side can map. No layer, so no directory is allocated.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 40000,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    _ = try world.addLevel(0);
    try world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 1.0e9, .h = 1.0e9 }, 2, 0);
    try std.testing.expectEqual(tile_store_max_side, world.render_side);
    const sync_plan = try testSyncGpuTiles(&world, 0);
    try std.testing.expectEqual(tile_store_max_side, sync_plan.side);
    try std.testing.expectEqual(tile_store_max_side, world.gpu_tiles.window.width());
    try std.testing.expectEqual(@as(u32, 1), world.gpu_tiles.window.height());
    try std.testing.expect(world.gpu_tiles.window_clip_reported);
    try std.testing.expectEqual(@as(usize, 0), sync_plan.span_count);
}

test "the store width keeps the topmost window layers and reports the drop once" {
    // Exercises a reported clip: keep its `log.warn` off the test runner's stderr.
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;
    const desired = [_]u32{ 7, 3, 5, 1 };
    var reported = false;
    try std.testing.expectEqualSlices(u32, &desired, fitResidentLayers(&desired, 9, &reported));
    try std.testing.expect(!reported);
    // Past the fit, the deepest layers drop and the report latches.
    try std.testing.expectEqualSlices(u32, &.{ 7, 3 }, fitResidentLayers(&desired, 2, &reported));
    try std.testing.expect(reported);
    try std.testing.expectEqualSlices(u32, &.{7}, fitResidentLayers(&desired, 1, &reported));
    try std.testing.expect(reported);
    try std.testing.expectEqual(@as(usize, 0), fitResidentLayers(&desired, 0, &reported).len);
}

test "a store created for a sync that never committed gets the whole window at the next sync" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const water = try world.requireTileByName(&meta, "water_1");
    const layer = try world.addDenseLayer(try world.addLevel(0), 0, .floor, grass);
    _ = try world.setDenseTile(layer, 1, 1, water);
    try testShowChunks(&world, 0, 0, 1, 1, 0);
    world.gpu_tiles.store = .{ .index = 0, .generation = 1 };
    world.gpu_tiles.store_side = world.render_side;
    _ = try testSyncGpuTiles(&world, 0);
    try std.testing.expect(world.gpu_tiles.layoutMatchesStore());

    // A sync at another side created its store and failed before committing,
    // and the window is back at the old side. The mirror's layout describes the
    // old store, so the next sync lays the window out anew rather than uploading
    // only what changed into an empty store.
    world.gpu_tiles.store = .{ .index = 1, .generation = 1 };
    world.gpu_tiles.store_side = world.render_side * 2;
    try std.testing.expect(!world.gpu_tiles.layoutMatchesStore());
    var fresh = TestGpuStore{};
    defer fresh.deinit();
    const sync_plan = try testSyncGpuTiles(&world, 0);
    try std.testing.expect(sync_plan.relayout);
    try testApplySync(&world, &fresh);
    try std.testing.expectEqual(@as(?TileId, water), testGpuTile(&world, &fresh, layer, 1, 1));
    try expectGpuStoreMatches(&world, &fresh);
}

test "the render directory side covers the rect's chunk span plus alignment and overscan, clamped to the grid" {
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 2048,
        .height = 512,
        .tile_size = 32,
        .chunk_size_tiles = 16,
    };
    defer world.deinit();
    _ = try world.addLevel(0);
    // 1280x720 px over 512 px chunks: 3 chunks wide + 1 for alignment.
    try world.setVisibleChunksForWorldRect(.{ .x = 100, .y = 100, .w = 1280, .h = 720 }, 0, 0);
    try std.testing.expectEqual(@as(u32, 4), world.render_side);
    // One chunk of overscan on each side: 3 + 1 + 2.
    try world.setVisibleChunksForWorldRect(.{ .x = 100, .y = 100, .w = 1280, .h = 720 }, 1, 0);
    try std.testing.expectEqual(@as(u32, 8), world.render_side);
    // A rect wider than the level clamps to the grid's power of two (128 chunks).
    try world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 1.0e9, .h = 1.0e9 }, 3, 0);
    try std.testing.expectEqual(@as(u32, 128), world.render_side);
    // Every window the side covers fits it.
    const region = world.visibleChunkRegion().?;
    try std.testing.expect(region.max_exclusive.x - region.min.x <= 128);
}

test "the window sparse list is the same at 8 and 128 levels for the same window" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var lists: [2][3]TestSparseKey = undefined;
    for ([_]u16{ 8, 128 }, &lists) |level_count, *list| {
        var world = WorldSystem{
            .allocator = std.testing.allocator,
            .width = 16,
            .height = 16,
            .tile_size = meta.tileSize(),
            .chunk_size_tiles = 4,
            .render_window = .{ .levels_below = 2 },
        };
        defer world.deinit();
        try world.buildCatalog(&meta);
        const deco = try world.requireTileByName(&meta, "deco_0");
        for (0..level_count) |level_index| {
            const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
            // Two tiles per level, one inside the visible rect and one outside it.
            _ = try world.addSparseTile(level, 1, 1, deco, 0, .obstacle);
            _ = try world.addSparseTile(level, 14, 14, deco, 0, .obstacle);
        }
        try world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 4 * meta.tileSize(), .h = 4 * meta.tileSize() }, 0, 3);
        // Levels 3, 4, 5 are in the window: one tile each.
        try std.testing.expectEqual(@as(usize, 3), world.reserveRenderRecords());
        _ = testWindowSparseKeys(&world, list);
    }
    try std.testing.expectEqualSlices(TestSparseKey, &lists[0], &lists[1]);
}
