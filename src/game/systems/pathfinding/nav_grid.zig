// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Static per-level navigation grid: composes one Z-floor's blocked mask from
//! DataSystem static bodies (level 0) and the world mask, owns chunk-local
//! component labels, and supports the bounded incremental remask used by digs.

const std = @import("std");
const math = @import("../../../core/math.zig");
const simd = @import("../../../core/simd.zig");
const DataSystem = @import("../../data_system.zig").DataSystem;
const EntityId = @import("../../data_system.zig").EntityId;
const WorldSystem = @import("../../world_system.zig").WorldSystem;
const types = @import("types.zig");
const default_cell_size = types.default_cell_size;
const default_nav_chunk_tiles = types.default_nav_chunk_tiles;
const no_cell = types.no_cell;
const no_component = types.no_component;
const GridCell = types.GridCell;
const NavSpan = types.NavSpan;
const NavCellEdit = types.NavCellEdit;
const tileIndexClamped = types.tileIndexClamped;
const setLen = types.setLen;
const neighbor_dirs = types.neighbor_dirs;
const rect_edge_epsilon = types.rect_edge_epsilon;

pub const NavGrid = struct {
    // Static navigation grid for ONE level (Z-floor). Derived from DataSystem
    // collision rows (level 0 only) and this level's composed world mask. Owns
    // CHUNK-LOCAL component labels (a flood never crosses a chunk border) for cheap
    // intra-chunk reachability; cross-chunk reachability is expressed only via the
    // abstract portal/link graph. All levels share the same dimensions/cell_size and
    // chunk_tiles; the owning NavGraph holds one NavGrid per level.
    level: u16 = 0,
    cell_size: f32 = default_cell_size,
    width: usize = 0,
    height: usize = 0,
    // Abstract chunk side length (cells). Shared with the owning NavGraph so a flood
    // and the graph agree on chunk boundaries.
    chunk_tiles: u16 = default_nav_chunk_tiles,
    blocked_count: usize = 0,
    blocked: std.ArrayList(bool) = .empty,
    // Chunk-local component labels, encoded chunk_id * (chunk_tiles^2 + 1) + local
    // (local 1..m within the chunk, 0 reserved for no_component). A chunk's labels
    // depend only on its own mask, so recomputing a dirty chunk matches a full rebuild.
    components: std.ArrayList(u32) = .empty,
    component_queue: std.ArrayList(usize) = .empty,
    // Level-0 static-body coverage, rasterized once when markStaticBodies runs at a full
    // build. Static bodies are constant between rebuilds, so an incremental remask reads
    // this O(1) per cell instead of re-scanning every static body (and its entity-index
    // lookup) per cell. Empty on non-zero levels (they never source collision bodies).
    static_blocked: std.ArrayList(bool) = .empty,

    pub fn deinit(self: *NavGrid, allocator: std.mem.Allocator) void {
        self.static_blocked.deinit(allocator);
        self.component_queue.deinit(allocator);
        self.components.deinit(allocator);
        self.blocked.deinit(allocator);
        self.* = undefined;
    }

    // Sizes this level's arrays and clears them. Dimensions are assigned by the owning
    // NavGraph so every level stays consistent.
    pub fn prepare(
        self: *NavGrid,
        allocator: std.mem.Allocator,
        level: u16,
        width: usize,
        height: usize,
        cell_size: f32,
        chunk_tiles: u16,
    ) !void {
        self.level = level;
        self.cell_size = cell_size;
        self.width = width;
        self.height = height;
        self.chunk_tiles = @max(@as(u16, 1), chunk_tiles);
        const cell_count = self.cellCount();
        try setLen(&self.blocked, allocator, cell_count);
        try setLen(&self.components, allocator, cell_count);
        // A component flood never leaves its chunk, so the BFS queue only ever holds at
        // most one chunk's cells — size it to chunk_tiles^2, not the whole level.
        const ct: usize = self.chunk_tiles;
        try self.component_queue.ensureTotalCapacity(allocator, ct * ct);
        @memset(self.blocked.items, false);
        @memset(self.components.items, no_component);
        self.blocked_count = 0;
        self.component_queue.clearRetainingCapacity();
    }

    // Marks DataSystem static collision bodies as blocked. Only level 0 consumes
    // collision bodies (the demo's entities live on the ground floor); other
    // levels source obstacles purely from their world mask.
    pub fn markStaticBodies(self: *NavGrid, allocator: std.mem.Allocator, data: *const DataSystem) !void {
        const bounds = data.collisionBoundsSliceConst();
        const responses = data.collisionResponseSliceConst();
        // Build the per-cell coverage cache alongside the live mask so an incremental
        // remask is O(1) per cell. Same rect->cell rule as the mask, so the cache and a
        // full mark agree exactly (the remask-vs-rebuild parity tests guard this).
        try setLen(&self.static_blocked, allocator, self.cellCount());
        @memset(self.static_blocked.items, false);
        // Build entity→bounds-index map once (O(n) over bounds) so the per-static-body
        // lookup below is O(1) instead of O(n) per entity, avoiding a quadratic scan.
        var bounds_map = std.AutoHashMap(EntityId, usize).init(allocator);
        defer bounds_map.deinit();
        for (bounds.entities, 0..) |entity, i| {
            try bounds_map.put(entity, i);
        }
        for (responses.entities, 0..) |entity, response_index| {
            if (responses.mobilities[response_index] != .static) continue;
            const bounds_index = bounds_map.get(entity) orelse continue;
            const body = data.movementBodyConst(entity) orelse continue;
            const rect = rectFromBounds(body.position.x, body.position.y, bounds, bounds_index);
            self.markBlockedRectSimd(rect.min_x, rect.min_y, rect.max_x, rect.max_y);
            self.rasterizeStaticCoverage(rect);
        }
    }

    // Sets the static-coverage cache true for every cell a static body's world rect
    // overlaps, using the same clamped rect->cell mapping as markBlockedRectSimd and
    // staticBodyCoversNavCell so all three agree on which cells a body covers.
    fn rasterizeStaticCoverage(self: *NavGrid, rect: StaticBodyRect) void {
        const min_cell = self.worldToCellClamped(.{ .x = rect.min_x, .y = rect.min_y });
        const max_cell = self.worldToCellClamped(.{ .x = @max(rect.min_x, rect.max_x - rect_edge_epsilon), .y = @max(rect.min_y, rect.max_y - rect_edge_epsilon) });
        const cx0: usize = @intCast(@min(min_cell.x, max_cell.x));
        const cx1: usize = @intCast(@max(min_cell.x, max_cell.x));
        const cy0: usize = @intCast(@min(min_cell.y, max_cell.y));
        const cy1: usize = @intCast(@max(min_cell.y, max_cell.y));
        var cy = cy0;
        while (cy <= cy1) : (cy += 1) {
            var cx = cx0;
            while (cx <= cx1) : (cx += 1) {
                self.static_blocked.items[cy * self.width + cx] = true;
            }
        }
    }

    pub fn cellCount(self: *const NavGrid) usize {
        return self.width * self.height;
    }

    pub fn valid(self: *const NavGrid) bool {
        return self.width != 0 and self.height != 0 and self.blocked.items.len == self.cellCount();
    }

    pub fn worldToCellClamped(self: *const NavGrid, value: math.Vec2) GridCell {
        const max_x: i32 = @intCast(self.width - 1);
        const max_y: i32 = @intCast(self.height - 1);
        const raw_x: i32 = math.floorToI32(value.x / self.cell_size);
        const raw_y: i32 = math.floorToI32(value.y / self.cell_size);
        return .{
            .x = std.math.clamp(raw_x, 0, max_x),
            .y = std.math.clamp(raw_y, 0, max_y),
        };
    }

    pub fn cellCenter(self: *const NavGrid, index: usize) math.Vec2 {
        const x = index % self.width;
        const y = index / self.width;
        return .{
            .x = (@as(f32, @floatFromInt(x)) + 0.5) * self.cell_size,
            .y = (@as(f32, @floatFromInt(y)) + 0.5) * self.cell_size,
        };
    }

    pub fn indexForCell(self: *const NavGrid, cell: GridCell) ?usize {
        if (cell.x < 0 or cell.y < 0) return null;
        const x: usize = @intCast(cell.x);
        const y: usize = @intCast(cell.y);
        if (x >= self.width or y >= self.height) return null;
        return y * self.width + x;
    }

    pub fn isBlockedIndex(self: *const NavGrid, index: usize) bool {
        std.debug.assert(index < self.blocked.items.len);
        return self.blocked.items[index];
    }

    pub fn isBlockedCell(self: *const NavGrid, cell: GridCell) bool {
        const index = self.indexForCell(cell) orelse return true;
        return self.isBlockedIndex(index);
    }

    // Whether a diagonal step from (cx,cy) to (nx,ny) is corner-blocked: an agent may move
    // diagonally only when BOTH shared orthogonal neighbors are open (no squeezing through a
    // corner). All four coordinates MUST be valid in-grid cells — callers bounds-check the
    // destination first — so this indexes the mask directly without re-running indexForCell.
    pub inline fn diagonalCornerBlocked(self: *const NavGrid, cx: i32, cy: i32, nx: i32, ny: i32) bool {
        const w: i32 = @intCast(self.width);
        return self.blocked.items[@intCast(cy * w + nx)] or self.blocked.items[@intCast(ny * w + cx)];
    }

    pub fn markBlockedRectSimd(self: *NavGrid, min_x: f32, min_y: f32, max_x: f32, max_y: f32) void {
        if (!self.valid()) return;
        const min_cell = self.worldToCellClamped(.{ .x = min_x, .y = min_y });
        const max_cell = self.worldToCellClamped(.{ .x = @max(min_x, max_x - rect_edge_epsilon), .y = @max(min_y, max_y - rect_edge_epsilon) });
        const row_start: usize = @intCast(@min(min_cell.y, max_cell.y));
        const row_end: usize = @intCast(@max(min_cell.y, max_cell.y));
        const col_start_i = @min(min_cell.x, max_cell.x);
        const col_end_i = @max(min_cell.x, max_cell.x);
        const col_start: usize = @intCast(col_start_i);
        const col_end: usize = @intCast(col_end_i);

        const all_blocked: simd.Mask4 = @splat(true);
        var y = row_start;
        while (y <= row_end) : (y += 1) {
            var x = col_start;
            // The loop guard keeps every lane within [col_start, col_end], so all lanes are
            // always in range — no per-lane mask needed; the scalar tail covers the remainder.
            // Genuine vector op: load the lane window, count lanes not yet set (only those
            // increment blocked_count), then store all-true in one vector write.
            while (x + simd.lane_count <= col_end + 1) : (x += simd.lane_count) {
                const base = y * self.width + x;
                const window = self.blocked.items[base .. base + simd.lane_count];
                const before: simd.Mask4 = window[0..simd.lane_count].*;
                const already: u32 = simd.countTrue(before);
                self.blocked_count += simd.lane_count - @as(usize, already);
                window[0..simd.lane_count].* = all_blocked;
            }
            while (x <= col_end) : (x += 1) {
                self.markBlockedIndex(y * self.width + x);
            }
        }
    }

    pub fn markBlockedIndex(self: *NavGrid, index: usize) void {
        if (!self.blocked.items[index]) {
            self.blocked.items[index] = true;
            self.blocked_count += 1;
        }
    }

    // Composes this level's blocked mask from the world's dense bands and sparse
    // obstacles by iterating those columns directly. Dense bands cost
    // O(bands x cells) inherently; sparse obstacles cost O(sparse) total. This
    // avoids polling levelBlocksMovement per cell, which rescanned every sparse
    // obstacle for every cell (O(cells x sparse)).
    pub fn markWorldObstacles(self: *NavGrid, world: *const WorldSystem) void {
        if (@as(usize, self.level) >= world.levelCount()) return;
        for (0..world.denseLayerCount()) |layer_index| {
            if (world.denseLayerLevel(layer_index) != self.level) continue;
            for (0..world.height) |y_usize| {
                const y: u16 = @intCast(y_usize);
                for (0..world.width) |x_usize| {
                    const x: u16 = @intCast(x_usize);
                    if (!world.denseTileBlocksMovement(layer_index, x, y)) continue;
                    self.markWorldCell(world, x, y);
                }
            }
        }
        for (0..world.sparseTileCount()) |sparse_index| {
            if (world.sparseTileLevel(sparse_index) != self.level) continue;
            if (!world.sparseTileBlocksMovement(sparse_index)) continue;
            const cell = world.sparseTileCellCoord(sparse_index);
            self.markWorldCell(world, cell.x, cell.y);
        }
    }

    pub fn markWorldCell(self: *NavGrid, world: *const WorldSystem, x: u16, y: u16) void {
        const rect = world.cellRect(x, y) orelse return;
        self.markBlockedRectSimd(rect.x, rect.y, rect.x + rect.w, rect.y + rect.h);
    }

    // Re-derives the blocked mask of EVERY cell in one chunk from the world + static bodies,
    // so a dirty chunk is correct regardless of which individual cells the caller enumerated
    // (coalesced rects, or upstream-coalesced batches). Uses the same per-cell source rule as
    // the full mark, so a remask is byte-identical to a full rebuild. Returns the net change in
    // blocked-cell count WITHOUT touching `blocked_count`, so this is safe to run on a worker
    // thread for a chunk it exclusively owns; the caller sums the deltas and applies them to
    // `blocked_count` once after the (possibly threaded) remask completes.
    pub fn remaskChunkFromWorld(self: *NavGrid, chunk_id: u32, data: *const DataSystem, world: *const WorldSystem) isize {
        const b = self.chunkBounds(chunk_id);
        var delta: isize = 0;
        var y = b.y0;
        while (y < b.y1) : (y += 1) {
            var x = b.x0;
            while (x < b.x1) : (x += 1) {
                const index = y * self.width + x;
                const value = self.navCellBlockedFromSources(data, world, x, y);
                if (self.blocked.items[index] == value) continue;
                self.blocked.items[index] = value;
                delta += if (value) 1 else -1;
            }
        }
        return delta;
    }

    // Nav-cell range overlapping an edited world tile's rect (clamped to the grid).
    // The inverse of markWorldCell: which nav cells must be recomputed for this edit.
    pub fn navSpanForTile(self: *const NavGrid, world: *const WorldSystem, edit: NavCellEdit) ?NavSpan {
        const rect = world.cellRect(edit.x, edit.y) orelse return null;
        const min_cell = self.worldToCellClamped(.{ .x = rect.x, .y = rect.y });
        const max_cell = self.worldToCellClamped(.{
            .x = @max(rect.x, rect.x + rect.w - rect_edge_epsilon),
            .y = @max(rect.y, rect.y + rect.h - rect_edge_epsilon),
        });
        return .{
            .min_x = @intCast(@min(min_cell.x, max_cell.x)),
            .min_y = @intCast(@min(min_cell.y, max_cell.y)),
            .max_x = @intCast(@max(min_cell.x, max_cell.x)),
            .max_y = @intCast(@max(min_cell.y, max_cell.y)),
        };
    }

    // Recomputes one nav cell's blocked state from the authoritative static sources:
    // any world tile overlapping the cell that blocks movement, or (level 0 only) any
    // static collision body covering it. Mirrors what markWorldObstacles/
    // markStaticBodies would set for this cell, so the incremental result is identical
    // to a full recompose for the cell.
    pub fn navCellBlockedFromSources(self: *const NavGrid, data: *const DataSystem, world: *const WorldSystem, ncx: usize, ncy: usize) bool {
        if (@as(usize, self.level) < world.levelCount()) {
            const min_x = @as(f32, @floatFromInt(ncx)) * self.cell_size;
            const min_y = @as(f32, @floatFromInt(ncy)) * self.cell_size;
            const tx0 = tileIndexClamped(min_x, world.tile_size, world.width);
            const tx1 = tileIndexClamped(min_x + self.cell_size - rect_edge_epsilon, world.tile_size, world.width);
            const ty0 = tileIndexClamped(min_y, world.tile_size, world.height);
            const ty1 = tileIndexClamped(min_y + self.cell_size - rect_edge_epsilon, world.tile_size, world.height);
            var ty = ty0;
            while (ty <= ty1) : (ty += 1) {
                var tx = tx0;
                while (tx <= tx1) : (tx += 1) {
                    if (world.levelBlocksMovement(self.level, tx, ty)) return true;
                }
            }
        }
        return self.level == 0 and self.staticBodyCoversNavCell(data, ncx, ncy);
    }

    // Whether any static collision body covers nav cell (ncx, ncy), using the same
    // cell-coverage rule as markStaticBodies/markBlockedRectSimd so the incremental
    // remask exactly matches a full mark. Bounded by the static-body count.
    pub fn staticBodyCoversNavCell(self: *const NavGrid, data: *const DataSystem, ncx: usize, ncy: usize) bool {
        // Fast path: the coverage cache built at the last full mark. Static bodies are
        // constant between rebuilds, so this is authoritative and O(1).
        if (self.static_blocked.items.len == self.cellCount()) {
            return self.static_blocked.items[ncy * self.width + ncx];
        }
        // Fallback: scan static bodies directly (cache not yet built for this grid).
        const bounds = data.collisionBoundsSliceConst();
        const responses = data.collisionResponseSliceConst();
        for (responses.entities, 0..) |entity, response_index| {
            if (responses.mobilities[response_index] != .static) continue;
            const rect = staticBodyWorldRect(data, bounds, entity) orelse continue;
            const min_cell = self.worldToCellClamped(.{ .x = rect.min_x, .y = rect.min_y });
            const max_cell = self.worldToCellClamped(.{ .x = @max(rect.min_x, rect.max_x - rect_edge_epsilon), .y = @max(rect.min_y, rect.max_y - rect_edge_epsilon) });
            const cx0: usize = @intCast(@min(min_cell.x, max_cell.x));
            const cx1: usize = @intCast(@max(min_cell.x, max_cell.x));
            const cy0: usize = @intCast(@min(min_cell.y, max_cell.y));
            const cy1: usize = @intCast(@max(min_cell.y, max_cell.y));
            if (ncx >= cx0 and ncx <= cx1 and ncy >= cy0 and ncy <= cy1) return true;
        }
        return false;
    }

    pub fn chunksX(self: *const NavGrid) usize {
        return (self.width + self.chunk_tiles - 1) / self.chunk_tiles;
    }

    pub fn chunksY(self: *const NavGrid) usize {
        return (self.height + self.chunk_tiles - 1) / self.chunk_tiles;
    }

    pub fn chunkOfCell(self: *const NavGrid, index: usize) u32 {
        const cx = (index % self.width) / self.chunk_tiles;
        const cy = (index / self.width) / self.chunk_tiles;
        return @intCast(cy * self.chunksX() + cx);
    }

    pub const ChunkBounds = struct { x0: usize, y0: usize, x1: usize, y1: usize };

    // Cell rect [x0,x1) x [y0,y1) of one chunk, clamped to the grid. The single source of
    // the chunk_id -> cell-rect convention shared by remask and component re-flood.
    pub fn chunkBounds(self: *const NavGrid, chunk_id: u32) ChunkBounds {
        const cx_count = self.chunksX();
        const cx = chunk_id % cx_count;
        const cy = chunk_id / cx_count;
        const x0 = cx * self.chunk_tiles;
        const y0 = cy * self.chunk_tiles;
        return .{
            .x0 = x0,
            .y0 = y0,
            .x1 = @min(x0 + self.chunk_tiles, self.width),
            .y1 = @min(y0 + self.chunk_tiles, self.height),
        };
    }

    // Per-chunk label stride: chunk_tiles^2 + 1 (max local labels per chunk, plus the
    // reserved 0). Keeps encoded labels of different chunks disjoint.
    pub fn chunkLabelStride(self: *const NavGrid) u64 {
        const ct: u64 = self.chunk_tiles;
        return ct * ct + 1;
    }

    // Labels every open cell with a CHUNK-LOCAL component id, chunk by chunk. Because a
    // flood never leaves its chunk and labels encode the chunk, a full relabel produces
    // the same labels the per-chunk incremental relabel does.
    pub fn buildComponents(self: *NavGrid) void {
        // No whole-array clear needed: recomputeChunkComponents clears each chunk's own
        // cells before re-flooding, and every cell belongs to exactly one chunk.
        const chunk_count = self.chunksX() * self.chunksY();
        var chunk_id: u32 = 0;
        while (chunk_id < chunk_count) : (chunk_id += 1) {
            self.recomputeChunkComponents(chunk_id, &self.component_queue);
        }
    }

    // Clears one chunk's cells to no_component and re-floods them with chunk-local
    // labels. Idempotent and self-contained: a chunk's result depends only on its own
    // mask, so the incremental update re-runs this for each dirty chunk. `queue` is the
    // BFS scratch — `&self.component_queue` on the serial path, or a per-worker queue when
    // dirty chunks are re-flooded in parallel (the flood writes only this chunk's cells).
    pub fn recomputeChunkComponents(self: *NavGrid, chunk_id: u32, queue: *std.ArrayList(usize)) void {
        const b = self.chunkBounds(chunk_id);
        var y = b.y0;
        while (y < b.y1) : (y += 1) {
            var x = b.x0;
            while (x < b.x1) : (x += 1) {
                self.components.items[y * self.width + x] = no_component;
            }
        }
        const base: u64 = @as(u64, chunk_id) * self.chunkLabelStride();
        var local: u32 = 1;
        y = b.y0;
        while (y < b.y1) : (y += 1) {
            var x = b.x0;
            while (x < b.x1) : (x += 1) {
                const index = y * self.width + x;
                if (self.blocked.items[index] or self.components.items[index] != no_component) continue;
                const label = base + local;
                std.debug.assert(label < no_cell);
                self.floodComponent(index, @intCast(label), queue);
                local += 1;
            }
        }
    }

    pub fn floodComponent(self: *NavGrid, start_index: usize, component: u32, queue: *std.ArrayList(usize)) void {
        // A flood never leaves its chunk, so the queue only needs chunk_tiles^2 capacity; the
        // appendAssumeCapacity calls below rely on the caller having reserved at least that.
        std.debug.assert(queue.capacity >= @as(usize, self.chunk_tiles) * self.chunk_tiles);
        queue.clearRetainingCapacity();
        queue.appendAssumeCapacity(start_index);
        self.components.items[start_index] = component;
        const start_chunk = self.chunkOfCell(start_index);
        var read_index: usize = 0;
        while (read_index < queue.items.len) : (read_index += 1) {
            const current = queue.items[read_index];
            const current_x: i32 = @intCast(current % self.width);
            const current_y: i32 = @intCast(current / self.width);
            for (neighbor_dirs) |dir| {
                const next_cell = GridCell{ .x = current_x + dir.x, .y = current_y + dir.y };
                const next_index = self.indexForCell(next_cell) orelse continue;
                // Chunk-local: a flood stays inside the start cell's chunk; cross-chunk
                // reachability is carried by the abstract portal graph instead.
                if (self.chunkOfCell(next_index) != start_chunk) continue;
                if (self.blocked.items[next_index] or self.components.items[next_index] != no_component) continue;
                // next_cell is in-bounds, so its component coords are too; the helper indexes
                // the orthogonal diagonal cells directly instead of via isBlockedCell.
                if (dir.diagonal and self.diagonalCornerBlocked(current_x, current_y, next_cell.x, next_cell.y)) {
                    continue;
                }
                self.components.items[next_index] = component;
                queue.appendAssumeCapacity(next_index);
            }
        }
    }

    // True only when both cells share a chunk-local component, i.e. a local path
    // exists entirely within one chunk. Cross-chunk reachability routes through the
    // abstract graph, never through this predicate.
    pub fn connected(self: *const NavGrid, a: usize, b: usize) bool {
        return self.components.items[a] != no_component and self.components.items[a] == self.components.items[b];
    }

    pub fn componentOf(self: *const NavGrid, index: usize) u32 {
        return self.components.items[index];
    }

    // Projects a blocked goal cell to the nearest open cell on this level within a
    // bounded radius. Returns the open index, or null if none is reachable.
    pub fn projectToNearestOpen(self: *const NavGrid, cell: GridCell, radius: i32) ?usize {
        if (self.indexForCell(cell)) |index| {
            if (!self.isBlockedIndex(index)) return index;
        }
        var ring: i32 = 1;
        while (ring <= radius) : (ring += 1) {
            var dy: i32 = -ring;
            while (dy <= ring) : (dy += 1) {
                var dx: i32 = -ring;
                while (dx <= ring) : (dx += 1) {
                    // Only walk the ring perimeter; interior rings were checked.
                    if (@abs(dx) != ring and @abs(dy) != ring) continue;
                    const candidate = GridCell{ .x = cell.x + dx, .y = cell.y + dy };
                    const index = self.indexForCell(candidate) orelse continue;
                    if (!self.isBlockedIndex(index)) return index;
                }
            }
        }
        return null;
    }
};
pub const StaticBodyRect = struct { min_x: f32, min_y: f32, max_x: f32, max_y: f32 };

// Index of `target` in a collision-bounds entity column, or null if absent. Relocated here
// from the pathfinding types leaf: this is its only consumer (staticBodyWorldRect).
fn boundsEntityIndex(entities: []const EntityId, target: EntityId) ?usize {
    for (entities, 0..) |entity, index| {
        if (entity.index == target.index and entity.generation == target.generation) return index;
    }
    return null;
}

// World-space AABB from a body origin and its bounds-column entry. Shared by markStaticBodies
// and staticBodyWorldRect so the full mark and the incremental cell-coverage test derive
// identical offset/size geometry.
fn rectFromBounds(px: f32, py: f32, bounds: anytype, idx: usize) StaticBodyRect {
    const min_x = px + bounds.offset_x[idx];
    const min_y = py + bounds.offset_y[idx];
    return .{ .min_x = min_x, .min_y = min_y, .max_x = min_x + bounds.size_x[idx], .max_y = min_y + bounds.size_y[idx] };
}

// World-space AABB of `entity`'s static collision body, or null if it has no bounds
// or movement body. Shared by markStaticBodies and staticBodyCoversNavCell so the
// full mark and the incremental cell-coverage test derive identical geometry.
pub fn staticBodyWorldRect(data: *const DataSystem, bounds: anytype, entity: EntityId) ?StaticBodyRect {
    const bounds_index = boundsEntityIndex(bounds.entities, entity) orelse return null;
    const body = data.movementBodyConst(entity) orelse return null;
    return rectFromBounds(body.position.x, body.position.y, bounds, bounds_index);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const PathfindingSystem = @import("system.zig").PathfindingSystem;
const test_support = @import("test_support.zig");
const baselineCapacity = test_support.baselineCapacity;
const addNavBody = test_support.addNavBody;

test "pathfinding nav grid blocked set matches per-level composed mask" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const asset_store = @import("../../../assets/assets.zig").AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try @import("../../../assets/world_tileset_meta.zig").load(
        std.testing.allocator,
        asset_store,
        @import("../../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 256, 256);
    defer world.deinit();
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;
    const grass = (meta.tileByName("grass") orelse return error.TestExpectedEqual).id;
    const extra_band = try world.addDenseLayer(0, 0, .obstacle, grass);
    _ = try world.setDenseTile(extra_band, 5, 6, tree);
    _ = try world.setDenseTile(extra_band, 2, 1, tree);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 256, 256, 32);

    var expected_blocked: usize = 0;
    for (0..world.height) |y_usize| {
        const y: u16 = @intCast(y_usize);
        for (0..world.width) |x_usize| {
            const x: u16 = @intCast(x_usize);
            const expect_blocked = world.levelBlocksMovement(0, x, y);
            if (expect_blocked) expected_blocked += 1;
            try std.testing.expectEqual(expect_blocked, system.graph.grid(0).?.isBlockedCell(.{
                .x = @intCast(x),
                .y = @intCast(y),
            }));
        }
    }
    try std.testing.expect(expected_blocked > 0);
    try std.testing.expectEqual(expected_blocked, system.graph.grid(0).?.blocked_count);
}

test "pathfinding nav grid survives degenerate cell size and bounds" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, true);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());

    // cell_size 0 and a non-finite bound would feed inf/NaN into @intFromFloat;
    // the guard collapses to at least a 1x1 grid instead of crashing.
    try system.rebuildStaticNavGrid(&data, std.math.inf(f32), 256, 0);
    try std.testing.expect(system.graph.width >= 1);
    try std.testing.expect(system.graph.height >= 1);
}
