// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared static-collider rows: one row per static navigation obstacle (an entity with a
//! movement body, collision bounds, and a static collision response), holding its
//! committed world AABB, its level, and the cell span it covers, listed per (level, chunk)
//! in entity-index order. A second, query tier lists each row once more, in the cell of its
//! size class that holds its min-corner cell, for box queries; per chunk, an anchor block
//! marks which cells of the classes no larger than a chunk hold such an entry, so a query
//! probes only those. Rows change only at the
//! structural-commit seam: the step's entity changes are captured into a persistent dirty
//! list right after the commit and applied by `sync` from the entities' final state, so
//! each changed entity costs its own footprint chunks (none when its chunks are unchanged)
//! and at most one query entry, never the static count. Readers (nav, steering) take a
//! `ColliderView`.

const std = @import("std");
const builtin = @import("builtin");
const math = @import("../../core/math.zig");
const logging = @import("../../core/logging.zig");
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const Dispatch = @import("../../app/thread_system.zig").Dispatch;
const StageControls = @import("../../app/thread_system.zig").StageControls;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const SimulationFrame = @import("../simulation.zig").SimulationFrame;
const ChunkListMap = @import("chunk_list_map.zig").ChunkListMap;
const chunkKey = @import("chunk_list_map.zig").chunkKey;
const keyChunk = @import("chunk_list_map.zig").keyChunk;
const keyLevel = @import("chunk_list_map.zig").keyLevel;
const no_entry = @import("chunk_list_map.zig").no_entry;
const no_value = @import("chunk_list_map.zig").no_value;
const max_chunk_size_tiles = @import("../world_system.zig").max_chunk_size_tiles;
const ChunkGeometry = @import("../world_terrain.zig").ChunkGeometry;

const no_row: u32 = std.math.maxInt(u32);

/// Query size classes: class k's cells are 2^k cells on an edge, k up to the class whose
/// one cell covers a level (at most 32, the log2 of a u32 level edge).
pub const max_query_classes: usize = 33;
pub const QueryClassMask = std.bit_set.Integer(max_query_classes);

// Bit offset of class `class`'s cells in the anchor block of a chunk 2^`shift` cells on an
// edge: each finer class k holds 4^(shift - k) cells.
fn anchorClassOffset(shift: u6, class: u6) usize {
    std.debug.assert(class <= shift + 1);
    const all: usize = @as(usize, 1) << (2 * (shift + 1));
    return (all - (@as(usize, 1) << (2 * (shift + 1 - class)))) / 3;
}

const max_anchor_chunk_shift: u6 = std.math.log2_int(u16, max_chunk_size_tiles);
const max_anchor_bits: usize = anchorClassOffset(max_anchor_chunk_shift, max_anchor_chunk_shift + 1);
const anchor_block_words: usize = (max_anchor_bits + 63) / 64;

comptime {
    std.debug.assert(std.math.isPowerOfTwo(max_chunk_size_tiles));
    std.debug.assert(anchor_block_words * 64 >= max_anchor_bits);
    // `AnchorBlock.set_bits` counts every bit.
    std.debug.assert(max_anchor_bits <= std.math.maxInt(u16));
}

/// One chunk's anchors over the query classes no larger than a chunk: a bit per class cell
/// of the chunk, set exactly when that cell's query list is non-empty, and the set-bit
/// count. Class k's cells start at `anchorClassOffset`, one row of 2^(shift - k) bits per
/// class-cell row, so no row straddles a word.
/// The bits are raw words, not `std.bit_set`: the box-query walk tests one per class cell,
/// and std's per-bit methods measured the serial steering step about 9% slower (Debug,
/// steering-static-dense at 16 statics per chunk, 12.15 -> 13.29 ms).
pub const AnchorBlock = struct {
    words: [anchor_block_words]u64,
    set_bits: u16,
};

const empty_anchor_block = AnchorBlock{ .words = @splat(0), .set_bits = 0 };

// A fine query key's chunk-tier key and anchor-block bit.
const AnchorBit = struct { chunk_key: u64, bit: usize };

/// The cell grid rows are placed on: `cell_size` world units per cell over `grid`, a
/// level's cells cut into power-of-two chunks (the nav tiling). Its cell and chunk counts
/// fit u32 (`validateChunkGrid`).
pub const ColliderGeometry = struct {
    cell_size: f32,
    grid: ChunkGeometry,

    pub fn init(cell_size: f32, cells_x: u32, cells_y: u32, chunk_tiles: u16) ColliderGeometry {
        return .{ .cell_size = cell_size, .grid = ChunkGeometry.init(cells_x, cells_y, chunk_tiles) };
    }

    /// The inclusive cells the half-open `aabb` covers, clamped to the grid: its min
    /// corner's cell to the last cell before its max edge (`math.lastCellOfSpan`).
    pub fn footprint(self: ColliderGeometry, aabb: math.Aabb) CellSpan {
        return .{
            .min_x = math.worldPosToCell(aabb.min_x, self.cell_size, self.grid.width),
            .min_y = math.worldPosToCell(aabb.min_y, self.cell_size, self.grid.height),
            .max_x = math.lastCellOfSpan(aabb.min_x, aabb.max_x, self.cell_size, self.grid.width),
            .max_y = math.lastCellOfSpan(aabb.min_y, aabb.max_y, self.cell_size, self.grid.height),
        };
    }

    /// The query class whose single cell covers the whole level: the smallest k with
    /// 2^k >= max(width, height).
    pub fn topQueryClass(self: ColliderGeometry) u6 {
        return std.math.log2_int_ceil(u32, @max(self.grid.width, self.grid.height, 1));
    }

    // The world edge of a class-`class` cell: an exact power-of-two scale of the cell size,
    // formed only here.
    fn classEdge(self: ColliderGeometry, class: u6) f32 {
        return self.cell_size * @as(f32, @floatFromInt(@as(u64, 1) << class));
    }

    // Class-`class` cells per row of the level.
    fn classCellsX(self: ColliderGeometry, class: u6) u64 {
        return (@as(u64, self.grid.width) + (@as(u64, 1) << class) - 1) >> class;
    }

    /// The smallest class below `top` whose cell edge covers `aabb` on both axes, tested
    /// in f32 exactly as `ColliderView.queryBox` bounds its walk; otherwise `top`
    /// (non-finite extents included). At most `top + 1` iterations.
    pub fn queryClass(self: ColliderGeometry, top: u6, aabb: math.Aabb) u6 {
        var class: u6 = 0;
        while (class < top) : (class += 1) {
            const edge = self.classEdge(class);
            if (aabb.max_x - edge <= aabb.min_x and aabb.max_y - edge <= aabb.min_y) return class;
        }
        return top;
    }

    /// The query-tier key of a row on `level` in class `class` whose clamped footprint
    /// starts at `cells`' min corner: the class-`class` cell holding that corner.
    pub fn queryKey(self: ColliderGeometry, level: u16, class: u6, cells: CellSpan) u64 {
        const cell = (@as(u64, cells.min_y) >> class) * self.classCellsX(class) + (@as(u64, cells.min_x) >> class);
        // A class cell index is below the level's cell count, which `validateChunkGrid`
        // keeps below 2^32.
        return queryCellKey(level, class, @intCast(cell));
    }

    // The chunk-tier key and anchor-block bit of query key `key`, whose class is no larger
    // than a chunk. O(1).
    fn anchorBit(self: ColliderGeometry, key: u64) AnchorBit {
        const class: u6 = @intCast((key >> 48) & 0x3f);
        const level = keyLevel(key & query_class_clear_mask);
        const cell: u64 = keyChunk(key);
        const shift: u6 = self.grid.shift;
        std.debug.assert(class <= shift);
        const cells_x = self.classCellsX(class);
        const cell_x = cell % cells_x;
        const cell_y = cell / cells_x;
        const per_chunk_shift: u6 = shift - class;
        const cell_mask = (@as(u64, 1) << per_chunk_shift) - 1;
        // Chunk indices stay below the level's chunk count, under 2^32.
        const chunk: u32 = @intCast((cell_y >> per_chunk_shift) * self.grid.chunks_x + (cell_x >> per_chunk_shift));
        const bit = anchorClassOffset(shift, class) + @as(usize, @intCast(((cell_y & cell_mask) << per_chunk_shift) + (cell_x & cell_mask)));
        return .{ .chunk_key = chunkKey(level, chunk), .bit = bit };
    }

    fn chunkRect(self: ColliderGeometry, placement: Placement) ChunkRect {
        const shift = self.grid.shift;
        return .{
            .level = placement.level,
            .chunks_x = self.grid.chunks_x,
            .min_x = placement.cells.min_x >> shift,
            .min_y = placement.cells.min_y >> shift,
            .max_x = placement.cells.max_x >> shift,
            .max_y = placement.cells.max_y >> shift,
        };
    }
};

// The inclusive chunk rectangle a placement covers on its level; `contains` tests a
// `chunkKey` for `ChunkListMap.unlinkOwnerOutside`.
const ChunkRect = struct {
    level: u16,
    chunks_x: u32,
    min_x: u32,
    min_y: u32,
    max_x: u32,
    max_y: u32,

    fn count(self: ChunkRect) usize {
        return (@as(usize, self.max_x) - self.min_x + 1) * (@as(usize, self.max_y) - self.min_y + 1);
    }

    fn holds(self: ChunkRect, chunk_x: u32, chunk_y: u32) bool {
        return chunk_x >= self.min_x and chunk_x <= self.max_x and chunk_y >= self.min_y and chunk_y <= self.max_y;
    }

    pub fn contains(self: ChunkRect, key: u64) bool {
        const chunk = keyChunk(key);
        return keyLevel(key) == self.level and self.holds(chunk % self.chunks_x, chunk / self.chunks_x);
    }

    fn eql(self: ChunkRect, other: ChunkRect) bool {
        return self.level == other.level and self.min_x == other.min_x and self.min_y == other.min_y and self.max_x == other.max_x and self.max_y == other.max_y;
    }

    // Chunks `self` and `other` share (zero across levels).
    fn overlap(self: ChunkRect, other: ChunkRect) usize {
        if (self.level != other.level) return 0;
        const min_x = @max(self.min_x, other.min_x);
        const min_y = @max(self.min_y, other.min_y);
        const max_x = @min(self.max_x, other.max_x);
        const max_y = @min(self.max_y, other.max_y);
        if (min_x > max_x or min_y > max_y) return 0;
        return (@as(usize, max_x) - min_x + 1) * (@as(usize, max_y) - min_y + 1);
    }
};

/// The query-tier key of class-`class` cell `cell` on `level`: the class in bits 48-53
/// over a `chunkKey`, tier bits 62-63 clear.
pub fn queryCellKey(level: u16, class: u6, cell: u32) u64 {
    return (@as(u64, class) << 48) | chunkKey(level, cell);
}

// Clears a query key's class bits, leaving its `chunkKey`.
const query_class_clear_mask: u64 = ~(@as(u64, 0x3f) << 48);

// Appends a query key to an anchor-edit list the sync's reserve sized.
fn appendAnchorEdit(edits: *std.ArrayList(u64), key: u64) void {
    std.debug.assert(edits.items.len < edits.capacity);
    edits.appendAssumeCapacity(key);
}

// `ChunkListMap.unlinkOwnerOutside` keep set that keeps nothing.
const KeepNone = struct {
    pub fn contains(_: KeepNone, _: u64) bool {
        return false;
    }
};

// A row's query class and query-tier key.
const QueryPlacement = struct { class: u6, key: u64 };

// One pending index's row after the sync: its placement, AABB, and query class and key,
// or null for no row.
const PlannedRow = struct { placement: Placement, aabb: math.Aabb, query_class: u6, query_key: u64 };

/// An inclusive cell rectangle.
pub const CellSpan = struct { min_x: u32, min_y: u32, max_x: u32, max_y: u32 };

/// Where a row sits: its level and the cells it covers.
pub const Placement = struct { level: u16, cells: CellSpan };

/// One entity's row change at the last sync: its placement before (null when it had no
/// row) and after (null when it has none now).
pub const ColliderChange = struct {
    entity: EntityId,
    old: ?Placement,
    new: ?Placement,
};

const Row = struct {
    entity: EntityId,
    level: u16,
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
    cell_min_x: u32,
    cell_min_y: u32,
    cell_max_x: u32,
    cell_max_y: u32,
};

/// The bounds of one `ColliderView.queryBox` walk: at most `max_hits` hits and `max_work`
/// steps (chunk and cell visits plus entries read).
pub const BoxQueryLimits = struct { max_hits: u16, max_work: u16 };

/// Packed hit AABBs, each slice at least `max_hits` long.
pub const BoxHits = struct { min_x: []f32, min_y: []f32, max_x: []f32, max_y: []f32 };

/// One `queryBox` walk's hits written, entries read, and steps taken.
pub const BoxQueryCounts = struct { hits: u16 = 0, entries: u16 = 0, work: u16 = 0 };

/// Read-only rows and chunk lists for readers between seams, safe for concurrent reads:
/// nothing here mutates. Valid until the next `sync` or `rebuild`.
pub const ColliderView = struct {
    /// Null for a system never rebuilt (it holds no rows).
    geometry: ?ColliderGeometry = null,
    lists: ?*const ChunkListMap = null,
    chunk_reader: ChunkListMap.Reader = .{},
    query_reader: ChunkListMap.Reader = .{},
    query_class_mask: QueryClassMask = .empty,
    query_top_class: u6 = 0,
    /// Anchor blocks by the id a chunk-tier key holds as its value.
    anchor_blocks: []const AnchorBlock = &.{},
    level: []const u16 = &.{},
    min_x: []const f32 = &.{},
    min_y: []const f32 = &.{},
    max_x: []const f32 = &.{},
    max_y: []const f32 = &.{},
    cell_min_x: []const u32 = &.{},
    cell_min_y: []const u32 = &.{},
    cell_max_x: []const u32 = &.{},
    cell_max_y: []const u32 = &.{},

    /// Whether any row covers a cell of `chunk` on `level`. O(1) expected.
    pub fn chunkHasRows(self: ColliderView, level: u16, chunk: u32) bool {
        return self.chunk_reader.head(chunkKey(level, chunk)) != no_entry;
    }

    /// The rows covering a cell of `chunk` on `level`, in entity-index order.
    pub fn chunkRows(self: ColliderView, level: u16, chunk: u32) ChunkListMap.Iterator {
        const lists = self.lists orelse return .{ .owners = &.{}, .next_entries = &.{}, .entry = no_entry };
        return lists.iterator(chunkKey(level, chunk));
    }

    pub fn rowCells(self: ColliderView, row: u32) CellSpan {
        return .{ .min_x = self.cell_min_x[row], .min_y = self.cell_min_y[row], .max_x = self.cell_max_x[row], .max_y = self.cell_max_y[row] };
    }

    /// Writes into `hits`, in query order, the AABB of every row on `level` that meets the
    /// closed `box`, each once: classes descending, so a walk stopped by either limit has
    /// kept the larger rows and dropped the smaller; within a class, for classes no larger
    /// than a chunk, the box's chunks in (y, x) order, each skipped when no row of a class
    /// no larger than a chunk is anchored there, then that chunk's class cells in (y, x)
    /// order, probing only cells whose anchor bit is set; for larger classes, the cells in
    /// (y, x) order; within a cell, entity-index order. Every chunk visit, cell visit, and
    /// entry read is one step; the walk stops before a step once it has taken `max_work`
    /// steps or written `max_hits` hits. Reads only: no allocation, safe on workers. Work
    /// depends on the box and the rows near it, never on the row count.
    // SIMD verdict: scalar. One bit test per cell, hash probes only on set bits, and
    // pointer-chasing list walks; the four-compare reject is fused into the walk.
    pub fn queryBox(self: ColliderView, level: u16, box: math.Aabb, limits: BoxQueryLimits, hits: BoxHits) BoxQueryCounts {
        std.debug.assert(hits.min_x.len >= limits.max_hits and hits.min_y.len >= limits.max_hits);
        std.debug.assert(hits.max_x.len >= limits.max_hits and hits.max_y.len >= limits.max_hits);
        const geometry = self.geometry orelse return .{};
        var walk = BoxWalk{
            .view = &self,
            .geometry = geometry,
            .level = level,
            .box = box,
            .limits = limits,
            .hits = hits,
        };
        var classes = self.query_class_mask.iterator(.{ .direction = .reverse });
        while (classes.next()) |class| {
            std.debug.assert(class <= self.query_top_class);
            if (!walk.walkClass(@intCast(class))) break;
        }
        return walk.counts;
    }
};

// The inclusive class-`class` cells one fine-class chunk visit walks.
const ClassCells = struct { class: u6, cells_x: u64, min_x: u64, min_y: u64, max_x: u64, max_y: u64 };

// One `queryBox` walk in progress. Every step method returns false once the walk stops.
const BoxWalk = struct {
    view: *const ColliderView,
    geometry: ColliderGeometry,
    level: u16,
    box: math.Aabb,
    limits: BoxQueryLimits,
    hits: BoxHits,
    counts: BoxQueryCounts = .{},

    fn canStep(self: *const BoxWalk) bool {
        return self.counts.work < self.limits.max_work and self.counts.hits < self.limits.max_hits;
    }

    // Walks class `class`'s cells overlapping [box.min - edge, box.max]: every row of the
    // class meeting the box has its anchor cell there (`ColliderGeometry.queryClass`).
    fn walkClass(self: *BoxWalk, class: u6) bool {
        const geometry = self.geometry;
        const edge = geometry.classEdge(class);
        // Class coordinates in u64: a class may reach 32.
        const min_x = @as(u64, math.worldPosToCell(self.box.min_x - edge, geometry.cell_size, geometry.grid.width)) >> class;
        const min_y = @as(u64, math.worldPosToCell(self.box.min_y - edge, geometry.cell_size, geometry.grid.height)) >> class;
        const max_x = @as(u64, math.worldPosToCell(self.box.max_x, geometry.cell_size, geometry.grid.width)) >> class;
        const max_y = @as(u64, math.worldPosToCell(self.box.max_y, geometry.cell_size, geometry.grid.height)) >> class;
        const cells_x = geometry.classCellsX(class);
        const chunk_shift: u6 = geometry.grid.shift;
        if (class > chunk_shift) return self.walkCells(class, cells_x, min_x, min_y, max_x, max_y);
        // A class cell lies in one chunk, whose anchor block (the chunk-tier key's value)
        // marks the class cells holding a query entry; a chunk without one holds none.
        const per_chunk_shift = chunk_shift - class;
        const chunks_x = geometry.grid.chunks_x;
        const class_offset = anchorClassOffset(chunk_shift, class);
        var chunk_y = min_y >> per_chunk_shift;
        while (chunk_y <= max_y >> per_chunk_shift) : (chunk_y += 1) {
            var chunk_x = min_x >> per_chunk_shift;
            while (chunk_x <= max_x >> per_chunk_shift) : (chunk_x += 1) {
                if (!self.canStep()) return false;
                self.counts.work += 1;
                // Chunk indices stay below the level's chunk count, under 2^32.
                const chunk: u32 = @intCast(chunk_y * chunks_x + chunk_x);
                const block = self.view.chunk_reader.value(chunkKey(self.level, chunk));
                if (block == no_value) continue;
                const first_x = chunk_x << per_chunk_shift;
                const first_y = chunk_y << per_chunk_shift;
                const last_x = first_x + (@as(u64, 1) << per_chunk_shift) - 1;
                const last_y = first_y + (@as(u64, 1) << per_chunk_shift) - 1;
                const cells = ClassCells{
                    .class = class,
                    .cells_x = cells_x,
                    .min_x = @max(min_x, first_x),
                    .min_y = @max(min_y, first_y),
                    .max_x = @min(max_x, last_x),
                    .max_y = @min(max_y, last_y),
                };
                if (!self.walkAnchoredCells(cells, &self.view.anchor_blocks[block].words, class_offset, per_chunk_shift)) return false;
            }
        }
        return true;
    }

    // Steps each cell of `cells` (inside one chunk) and walks the query list only of a cell
    // whose bit is set in the chunk's anchor `words`: a clear bit means an absent key.
    fn walkAnchoredCells(self: *BoxWalk, cells: ClassCells, words: *const [anchor_block_words]u64, class_offset: usize, per_chunk_shift: u6) bool {
        const cell_mask = (@as(u64, 1) << per_chunk_shift) - 1;
        const max_work = self.limits.max_work;
        const max_hits = self.limits.max_hits;
        var cell_y = cells.min_y;
        while (cell_y <= cells.max_y) : (cell_y += 1) {
            // A class cell's bit is below the block's bit count, so it fits usize.
            const row_bit = class_offset + @as(usize, @intCast((cell_y & cell_mask) << per_chunk_shift));
            var cell_x = cells.min_x;
            while (cell_x <= cells.max_x) : (cell_x += 1) {
                if (self.counts.work >= max_work or self.counts.hits >= max_hits) return false;
                self.counts.work += 1;
                const bit = row_bit + @as(usize, @intCast(cell_x & cell_mask));
                if ((words[bit >> 6] >> @intCast(bit & 63)) & 1 == 0) continue;
                // Class cell indices stay below the level's cell count, under 2^32.
                const cell: u32 = @intCast(cell_y * cells.cells_x + cell_x);
                if (!self.walkList(self.view.query_reader.head(queryCellKey(self.level, cells.class, cell)))) return false;
            }
        }
        return true;
    }

    fn walkCells(self: *BoxWalk, class: u6, cells_x: u64, min_x: u64, min_y: u64, max_x: u64, max_y: u64) bool {
        var cell_y = min_y;
        while (cell_y <= max_y) : (cell_y += 1) {
            var cell_x = min_x;
            while (cell_x <= max_x) : (cell_x += 1) {
                if (!self.canStep()) return false;
                self.counts.work += 1;
                // Class cell indices stay below the level's cell count, under 2^32.
                const cell: u32 = @intCast(cell_y * cells_x + cell_x);
                if (!self.walkList(self.view.query_reader.head(queryCellKey(self.level, class, cell)))) return false;
            }
        }
        return true;
    }

    fn walkList(self: *BoxWalk, first: u32) bool {
        const view = self.view;
        const reader = &view.query_reader;
        const box = self.box;
        var entry = first;
        while (entry != no_entry) : (entry = reader.next_entries[entry]) {
            if (!self.canStep()) return false;
            self.counts.work += 1;
            self.counts.entries += 1;
            const row = reader.owners[entry];
            const row_min_x = view.min_x[row];
            const row_min_y = view.min_y[row];
            const row_max_x = view.max_x[row];
            const row_max_y = view.max_y[row];
            if (row_min_x <= box.max_x and row_max_x >= box.min_x and row_min_y <= box.max_y and row_max_y >= box.min_y) {
                const at = self.counts.hits;
                self.hits.min_x[at] = row_min_x;
                self.hits.min_y[at] = row_min_y;
                self.hits.max_x[at] = row_max_x;
                self.hits.max_y[at] = row_max_y;
                self.counts.hits += 1;
            }
        }
        return true;
    }
};

pub const StaticColliderSystem = struct {
    allocator: std.mem.Allocator,
    geometry: ?ColliderGeometry = null,
    rows: std.MultiArrayList(Row) = .{},
    // Released row ids; capacity always covers every pooled row. An entity index keeps its
    // row while it stays static, across a destroy and a reusing create.
    row_free: std.ArrayList(u32) = .empty,
    // Per entity index, its row or `no_row`.
    row_of_index: std.ArrayList(u32) = .empty,
    // Entity indices whose rows the next `sync` re-derives, in first-capture order, kept
    // across a failed sync; `dirty_stamp[index] == dirty_generation` marks membership and
    // `dirty_entity[index]` holds the index's last captured id.
    pending_dirty: std.ArrayList(u32) = .empty,
    dirty_stamp: std.ArrayList(u32) = .empty,
    dirty_entity: std.ArrayList(EntityId) = .empty,
    dirty_generation: u32 = 1,
    changes: std.ArrayList(ColliderChange) = .empty,
    // Per pending index, in order: its row after the sync. Sync scratch, high-water.
    sync_plan: std.ArrayList(?PlannedRow) = .empty,
    chunk_lists: ChunkListMap,
    // One entry per row, at `ColliderGeometry.queryKey` of its level, class, and footprint.
    query_lists: ChunkListMap,
    // Rows per query class, and the classes holding any row (refreshed after every sync
    // and rebuild).
    query_class_rows: [max_query_classes]u32 = @splat(0),
    query_class_mask: QueryClassMask = .empty,
    query_top_class: u6 = 0,
    // Per chunk holding a query entry of a class no larger than a chunk, its anchor block,
    // by the id its chunk-tier key holds as its value. A block is released, all-zero, when
    // its last bit clears; `anchor_free`'s capacity covers every pooled block.
    anchor_blocks: std.ArrayList(AnchorBlock) = .empty,
    anchor_free: std.ArrayList(u32) = .empty,
    // Sync scratch, high-water: query keys of those classes gained and left this sync.
    anchor_sets: std.ArrayList(u64) = .empty,
    anchor_clears: std.ArrayList(u64) = .empty,
    // The chunk and query lists' splice stages: each its own tuner, sharing the range
    // controls (production runs adaptive; benches pin a fixed partition), and their last
    // batch shapes.
    splice_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    query_splice_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    splice_controls: StageControls = .{},
    last_splice_batch: BatchStats = .{},
    last_query_splice_batch: BatchStats = .{},
    // Column views refreshed whenever the row pool grows.
    row_entity: []EntityId = &.{},
    row_level: []u16 = &.{},
    row_min_x: []f32 = &.{},
    row_min_y: []f32 = &.{},
    row_max_x: []f32 = &.{},
    row_max_y: []f32 = &.{},
    row_cell_min_x: []u32 = &.{},
    row_cell_min_y: []u32 = &.{},
    row_cell_max_x: []u32 = &.{},
    row_cell_max_y: []u32 = &.{},
    /// Telemetry: row-pool growths, logged once.
    row_grows: u64 = 0,
    row_growth_logged: bool = false,
    /// Telemetry: anchor-block pool and anchor-edit scratch growths, logged once.
    anchor_grows: u64 = 0,
    anchor_growth_logged: bool = false,

    pub fn init(allocator: std.mem.Allocator) StaticColliderSystem {
        return .{
            .allocator = allocator,
            .chunk_lists = ChunkListMap.init(allocator, "static collider chunk lists"),
            .query_lists = ChunkListMap.init(allocator, "static collider query lists"),
        };
    }

    pub fn deinit(self: *StaticColliderSystem) void {
        self.anchor_clears.deinit(self.allocator);
        self.anchor_sets.deinit(self.allocator);
        self.anchor_free.deinit(self.allocator);
        self.anchor_blocks.deinit(self.allocator);
        self.query_lists.deinit();
        self.chunk_lists.deinit();
        self.sync_plan.deinit(self.allocator);
        self.changes.deinit(self.allocator);
        self.dirty_entity.deinit(self.allocator);
        self.dirty_stamp.deinit(self.allocator);
        self.pending_dirty.deinit(self.allocator);
        self.row_of_index.deinit(self.allocator);
        self.row_free.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.* = undefined;
    }

    fn refreshColumns(self: *StaticColliderSystem) void {
        const columns = self.rows.slice();
        self.row_entity = columns.items(.entity);
        self.row_level = columns.items(.level);
        self.row_min_x = columns.items(.min_x);
        self.row_min_y = columns.items(.min_y);
        self.row_max_x = columns.items(.max_x);
        self.row_max_y = columns.items(.max_y);
        self.row_cell_min_x = columns.items(.cell_min_x);
        self.row_cell_min_y = columns.items(.cell_min_y);
        self.row_cell_max_x = columns.items(.cell_max_x);
        self.row_cell_max_y = columns.items(.cell_max_y);
    }

    /// O(1).
    pub fn view(self: *const StaticColliderSystem) ColliderView {
        return .{
            .geometry = self.geometry,
            .lists = &self.chunk_lists,
            .chunk_reader = self.chunk_lists.reader(),
            .query_reader = self.query_lists.reader(),
            .query_class_mask = self.query_class_mask,
            .query_top_class = self.query_top_class,
            .anchor_blocks = self.anchor_blocks.items,
            .level = self.row_level,
            .min_x = self.row_min_x,
            .min_y = self.row_min_y,
            .max_x = self.row_max_x,
            .max_y = self.row_max_y,
            .cell_min_x = self.row_cell_min_x,
            .cell_min_y = self.row_cell_min_y,
            .cell_max_x = self.row_cell_max_x,
            .cell_max_y = self.row_cell_max_y,
        };
    }

    /// Live rows.
    pub fn rowCount(self: *const StaticColliderSystem) usize {
        return self.rows.len - self.row_free.items.len;
    }

    /// Whether captured changes wait for a `sync` (a failed sync keeps them). O(1).
    pub fn hasPendingChanges(self: *const StaticColliderSystem) bool {
        return self.pending_dirty.items.len != 0;
    }

    /// Entity indices waiting for a `sync`: the next sync records one change per index.
    pub fn pendingChangeCount(self: *const StaticColliderSystem) usize {
        return self.pending_dirty.items.len;
    }

    /// The row changes the last `sync` applied, valid until the next `sync` or `rebuild`.
    pub fn changesThisStep(self: *const StaticColliderSystem) []const ColliderChange {
        return self.changes.items;
    }

    fn rowPlacement(self: *const StaticColliderSystem, row: u32) Placement {
        return .{ .level = self.row_level[row], .cells = .{
            .min_x = self.row_cell_min_x[row],
            .min_y = self.row_cell_min_y[row],
            .max_x = self.row_cell_max_x[row],
            .max_y = self.row_cell_max_y[row],
        } };
    }

    /// Replaces every row with the statics `data` holds now, placed on `geometry`, built
    /// into fresh storage with both list tiers: an error leaves the system unchanged. Drops
    /// pending changes. O(S log S) for S statics; cold (pipeline init, world replace).
    pub fn rebuild(self: *StaticColliderSystem, data: *const DataSystem, geometry: ColliderGeometry) error{OutOfMemory}!void {
        std.debug.assert(geometry.grid.chunk_tiles != 0 and std.math.isPowerOfTwo(geometry.grid.chunk_tiles));
        // Anchor blocks hold the fine classes of a chunk up to this edge.
        std.debug.assert(geometry.grid.chunk_tiles <= max_chunk_size_tiles);
        var statics: std.ArrayList(EntityId) = .empty;
        defer statics.deinit(self.allocator);
        const responses = data.collisionResponseSliceConst();
        for (responses.entities, responses.mobilities) |entity, mobility| {
            if (mobility != .static or !data.isStaticNavigationObstacle(entity)) continue;
            try statics.append(self.allocator, entity);
        }
        std.sort.pdq(EntityId, statics.items, {}, struct {
            fn lessThan(_: void, a: EntityId, b: EntityId) bool {
                return a.index < b.index;
            }
        }.lessThan);

        var fresh = StaticColliderSystem.init(self.allocator);
        errdefer fresh.deinit();
        fresh.geometry = geometry;
        fresh.query_top_class = geometry.topQueryClass();
        // Growth telemetry spans rebuilds: a growth already logged stays logged.
        fresh.row_growth_logged = self.row_growth_logged;
        fresh.chunk_lists.growth_logged = self.chunk_lists.growth_logged;
        fresh.query_lists.growth_logged = self.query_lists.growth_logged;
        fresh.anchor_growth_logged = self.anchor_growth_logged;
        var index_count: usize = 0;
        var footprint_chunks: usize = 0;
        for (statics.items) |entity| {
            index_count = @max(index_count, @as(usize, entity.index) + 1);
            footprint_chunks += geometry.chunkRect(fresh.placementOf(data, entity).?).count();
        }
        try fresh.reserveIndices(index_count);
        try fresh.ensureFreeRows(statics.items.len);
        try fresh.chunk_lists.reserve(footprint_chunks, footprint_chunks, fresh.rows.len);
        try fresh.query_lists.reserve(statics.items.len, statics.items.len, fresh.rows.len);
        // Ascending entity index, so every row appends at its lists' tails.
        for (statics.items) |entity| {
            const placement = fresh.placementOf(data, entity).?;
            const aabb = data.staticObstacleWorldRect(entity).?;
            const row = fresh.claimRow(entity.index);
            fresh.writeRow(row, entity, placement, aabb);
            const rect = geometry.chunkRect(placement);
            var chunk_y = rect.min_y;
            while (chunk_y <= rect.max_y) : (chunk_y += 1) {
                var chunk_x = rect.min_x;
                while (chunk_x <= rect.max_x) : (chunk_x += 1) fresh.chunk_lists.appendTail(row, chunkKey(rect.level, chunk_y * rect.chunks_x + chunk_x), entity.index);
            }
            const class = geometry.queryClass(fresh.query_top_class, aabb);
            const query_key = geometry.queryKey(placement.level, class, placement.cells);
            fresh.query_lists.appendTail(row, query_key, entity.index);
            fresh.query_class_rows[class] += 1;
            if (class <= geometry.grid.shift) {
                // The row's chunk entries are listed, so its anchor chunk's key exists.
                const anchor = geometry.anchorBit(query_key);
                if (fresh.chunk_lists.value(anchor.chunk_key) == no_value) try fresh.ensureFreeAnchorBlocks(1);
                fresh.setAnchor(anchor);
            }
        }
        fresh.refreshQueryClassMask();
        fresh.splice_tuner = self.splice_tuner;
        fresh.query_splice_tuner = self.query_splice_tuner;
        fresh.splice_controls = self.splice_controls;
        fresh.row_grows += self.row_grows;
        fresh.chunk_lists.grows += self.chunk_lists.grows;
        fresh.query_lists.grows += self.query_lists.grows;
        fresh.anchor_grows += self.anchor_grows;
        self.deinit();
        self.* = fresh;
    }

    // Fixed 33 compares.
    fn refreshQueryClassMask(self: *StaticColliderSystem) void {
        self.query_class_mask = .empty;
        for (self.query_class_rows, 0..) |rows, class| self.query_class_mask.setValue(class, rows != 0);
    }

    // The query class and key of a row with `placement` and `aabb`.
    fn queryPlacement(self: *const StaticColliderSystem, placement: Placement, aabb: math.Aabb) QueryPlacement {
        const geometry = self.geometry.?;
        const class = geometry.queryClass(self.query_top_class, aabb);
        return .{ .class = class, .key = geometry.queryKey(placement.level, class, placement.cells) };
    }

    // `row`'s AABB columns.
    fn rowAabb(self: *const StaticColliderSystem, row: u32) math.Aabb {
        return .{ .min_x = self.row_min_x[row], .min_y = self.row_min_y[row], .max_x = self.row_max_x[row], .max_y = self.row_max_y[row] };
    }

    // Grows the per-index arrays to cover entity indices below `index_count`.
    fn reserveIndices(self: *StaticColliderSystem, index_count: usize) !void {
        if (self.row_of_index.items.len >= index_count) return;
        try self.row_of_index.ensureTotalCapacity(self.allocator, index_count);
        try self.dirty_stamp.ensureTotalCapacity(self.allocator, index_count);
        try self.dirty_entity.ensureTotalCapacity(self.allocator, index_count);
        try self.pending_dirty.ensureTotalCapacity(self.allocator, index_count);
        const added = index_count - self.row_of_index.items.len;
        self.row_of_index.appendNTimesAssumeCapacity(no_row, added);
        self.dirty_stamp.appendNTimesAssumeCapacity(0, added);
        self.dirty_entity.appendNTimesAssumeCapacity(EntityId.invalid, added);
    }

    // Grows the free row list to at least `needed` ids. Geometric and counted.
    fn ensureFreeRows(self: *StaticColliderSystem, needed: usize) !void {
        if (self.row_free.items.len >= needed) return;
        const added = needed - self.row_free.items.len;
        const total = self.rows.len + added;
        // At most one row per entity index, and entity indices are below maxInt(u32).
        std.debug.assert(total < no_row);
        if (total > self.rows.capacity) {
            try self.rows.ensureTotalCapacity(self.allocator, @max(total, self.rows.capacity *| 2));
            // The pool moved: the column views follow it before anything else can fail.
            self.refreshColumns();
            self.countRowGrowth();
        }
        try self.row_free.ensureTotalCapacity(self.allocator, self.rows.capacity);
        // Pushed in descending id order so pops hand out ascending ids.
        const first: u32 = @intCast(self.rows.len);
        for (0..added) |_| self.rows.appendAssumeCapacity(undefined);
        var id: u32 = @intCast(self.rows.len);
        while (id > first) {
            id -= 1;
            self.row_free.appendAssumeCapacity(id);
        }
        self.refreshColumns();
    }

    fn countRowGrowth(self: *StaticColliderSystem) void {
        self.row_grows += 1;
        if (self.row_growth_logged) return;
        self.row_growth_logged = true;
        if (comptime logging.enabled(.info) and !builtin.is_test)
            logging.game.info("static collider rows grew ({} growths so far)", .{self.row_grows});
    }

    fn countAnchorGrowth(self: *StaticColliderSystem) void {
        self.anchor_grows += 1;
        if (self.anchor_growth_logged) return;
        self.anchor_growth_logged = true;
        if (comptime logging.enabled(.info) and !builtin.is_test)
            logging.game.info("static collider anchor blocks grew ({} growths so far)", .{self.anchor_grows});
    }

    // Grows the free anchor-block list to at least `needed` ids, new blocks all-zero.
    // Geometric and counted.
    fn ensureFreeAnchorBlocks(self: *StaticColliderSystem, needed: usize) !void {
        if (self.anchor_free.items.len >= needed) return;
        const added = needed - self.anchor_free.items.len;
        const total = self.anchor_blocks.items.len + added;
        // Block ids stay below `no_value`: exhausting them needs 2^32 - 1 live blocks, so it
        // fails as the allocator does.
        if (total >= no_value) return error.OutOfMemory;
        if (total > self.anchor_blocks.capacity) {
            try self.anchor_blocks.ensureTotalCapacity(self.allocator, @max(total, self.anchor_blocks.capacity *| 2));
            self.countAnchorGrowth();
        }
        try self.anchor_free.ensureTotalCapacity(self.allocator, self.anchor_blocks.capacity);
        // Pushed in descending id order so pops hand out ascending ids.
        const first: u32 = @intCast(self.anchor_blocks.items.len);
        self.anchor_blocks.appendNTimesAssumeCapacity(empty_anchor_block, added);
        var id: u32 = @intCast(self.anchor_blocks.items.len);
        while (id > first) {
            id -= 1;
            self.anchor_free.appendAssumeCapacity(id);
        }
    }

    // Sizes the sync's anchor-edit scratch for `sets` and `clears` edits. Geometric and
    // counted.
    fn reserveAnchorEdits(self: *StaticColliderSystem, sets: usize, clears: usize) !void {
        if (self.anchor_sets.capacity >= sets and self.anchor_clears.capacity >= clears) return;
        try self.anchor_sets.ensureTotalCapacity(self.allocator, sets);
        try self.anchor_clears.ensureTotalCapacity(self.allocator, clears);
        self.countAnchorGrowth();
    }

    // Sets `anchor`'s bit, claiming a free block for its chunk when the chunk has none; the
    // chunk's key exists. O(1).
    fn setAnchor(self: *StaticColliderSystem, anchor: AnchorBit) void {
        var block_id = self.chunk_lists.value(anchor.chunk_key);
        if (block_id == no_value) {
            // The reserve kept a free block for every chunk gaining its first anchor.
            std.debug.assert(self.anchor_free.items.len != 0);
            block_id = self.anchor_free.pop().?;
            std.debug.assert(self.anchor_blocks.items[block_id].set_bits == 0);
            self.chunk_lists.setValue(anchor.chunk_key, block_id);
        }
        const block = &self.anchor_blocks.items[block_id];
        const word = &block.words[anchor.bit >> 6];
        const bit_mask = @as(u64, 1) << @intCast(anchor.bit & 63);
        if (word.* & bit_mask != 0) return;
        word.* |= bit_mask;
        block.set_bits += 1;
    }

    // Clears fine query key `key`'s bit when its list is empty, releasing its chunk's block
    // and value when no bit stays set. A key cleared twice, or left and refilled, comes out
    // exact: emptiness is read from the committed query lists. O(1).
    fn clearAnchor(self: *StaticColliderSystem, key: u64) void {
        if (self.query_lists.head(key) != no_entry) return;
        const anchor = self.geometry.?.anchorBit(key);
        const block_id = self.chunk_lists.value(anchor.chunk_key);
        if (block_id == no_value) return;
        const block = &self.anchor_blocks.items[block_id];
        const word = &block.words[anchor.bit >> 6];
        const bit_mask = @as(u64, 1) << @intCast(anchor.bit & 63);
        if (word.* & bit_mask == 0) return;
        word.* &= ~bit_mask;
        block.set_bits -= 1;
        if (block.set_bits != 0) return;
        std.debug.assert(self.anchor_free.items.len < self.anchor_free.capacity);
        self.anchor_free.appendAssumeCapacity(block_id);
        self.chunk_lists.setValue(anchor.chunk_key, no_value);
    }

    // After the query commit, before the chunk commit (the chunk tier's keys still stand):
    // sets, then clears, so a set never needs a block a later clear frees. O(1) per edit.
    fn applyAnchorEdits(self: *StaticColliderSystem) void {
        const geometry = self.geometry.?;
        for (self.anchor_sets.items) |key| {
            // Each pending index stages once, so a gained key's list holds its row.
            if (std.debug.runtime_safety) std.debug.assert(self.query_lists.head(key) != no_entry);
            self.setAnchor(geometry.anchorBit(key));
        }
        for (self.anchor_clears.items) |key| self.clearAnchor(key);
    }

    /// The commit seam's reserve, before the structural commit: sizes the dirty list and the
    /// per-index arrays to every entity index the commit can produce (the live slot count
    /// plus one per command), so `capture` after the commit allocates nothing.
    pub fn reserveForCommit(self: *StaticColliderSystem, data: *const DataSystem, command_count: usize) error{OutOfMemory}!void {
        // A commit creates at most one entity slot per command.
        try self.reserveIndices(data.slots.items.len + command_count);
    }

    /// Records the committed step's static changes into the dirty list: destroys of a
    /// static, and changes to a body, bounds, response, or level that make or leave an
    /// entity static. Reads only the step's entity change list, so a step without entity
    /// changes costs O(1). Allocation-free after `reserveForCommit`; never fails.
    pub fn capture(self: *StaticColliderSystem, frame: *const SimulationFrame) void {
        const stats = frame.events.stats;
        if (stats.entity_destroyed + stats.component_changed == 0) return;
        for (frame.structural_changes_scratch.items) |change| {
            const entity = switch (change) {
                .entity_created => continue,
                .entity_destroyed => |destroyed| if (destroyed.was_static_navigation_obstacle) destroyed.entity else continue,
                .component_changed => |changed| switch (changed.component) {
                    .movement_body, .collision_bounds, .collision_response, .world_level => if (changed.was_static_navigation_obstacle or changed.is_static_navigation_obstacle) changed.entity else continue,
                    else => continue,
                },
            };
            self.markDirty(entity);
        }
    }

    fn markDirty(self: *StaticColliderSystem, entity: EntityId) void {
        const index = entity.index;
        // `reserveForCommit` sized the per-index arrays before the commit.
        std.debug.assert(index < self.dirty_stamp.items.len);
        self.dirty_entity.items[index] = entity;
        if (self.dirty_stamp.items[index] == self.dirty_generation) return;
        self.dirty_stamp.items[index] = self.dirty_generation;
        std.debug.assert(self.pending_dirty.items.len < self.pending_dirty.capacity);
        self.pending_dirty.appendAssumeCapacity(index);
    }

    /// Applies every captured change from `data`'s final state: per dirty index, its row
    /// follows its last captured id (kept, moved, freed, or claimed), is listed in exactly
    /// the chunks it covers, and has one query entry at its class and anchor cell, marked in
    /// its chunk's anchor block when its class is no larger than a chunk. Records one
    /// `ColliderChange` per dirty index. The main thread does O(1) per change (at most two
    /// anchor edits among it), plus O(1) per footprint chunk of a row whose level or chunks
    /// changed (its unlinks and staged inserts); a row whose level and chunks are unchanged
    /// touches no chunk list, and one whose query key is unchanged touches no query list or
    /// anchor block. The sorted list placement runs in each tier's splice stage, threaded
    /// under `thread_system`; lists and blocks are identical for any partition. Every
    /// reserve runs first: on error nothing changes and the dirty list stays for the next
    /// sync. The change list resets on every call.
    // SIMD verdict: scalar. Per changed entity, gather-bound placement reads
    // (`isStaticNavigationObstacle`, the obstacle rect) and branchy row and list edits.
    pub fn sync(self: *StaticColliderSystem, data: *const DataSystem, thread_system: ?*ThreadSystem) error{OutOfMemory}!void {
        self.changes.clearRetainingCapacity();
        self.last_splice_batch = .{};
        self.last_query_splice_batch = .{};
        const pending = self.pending_dirty.items;
        if (pending.len == 0) return;
        const geometry = self.geometry.?;

        // Plan each dirty index's row and count what the sync claims: rows for adds, chunk
        // entries for chunks entered, removals for chunks left, query entries for keys
        // gained and left, anchor edits for those keys of the classes no larger than a
        // chunk, and anchor blocks for chunks with none (an upper bound).
        try self.sync_plan.ensureTotalCapacity(self.allocator, pending.len);
        self.sync_plan.clearRetainingCapacity();
        var adds: usize = 0;
        var inserts: usize = 0;
        var removals: usize = 0;
        var query_inserts: usize = 0;
        var query_removals: usize = 0;
        var anchor_sets: usize = 0;
        var anchor_clears: usize = 0;
        var new_blocks: usize = 0;
        const chunk_shift = geometry.grid.shift;
        for (pending) |index| {
            const entity = self.dirty_entity.items[index];
            const old_row = self.row_of_index.items[index];
            const old_placement: ?Placement = if (old_row != no_row) self.rowPlacement(old_row) else null;
            const old_rect: ?ChunkRect = if (old_placement) |old| geometry.chunkRect(old) else null;
            const old_query: ?QueryPlacement = if (old_placement) |old| self.queryPlacement(old, self.rowAabb(old_row)) else null;
            const old_query_key: ?u64 = if (old_query) |old| old.key else null;
            const planned: ?PlannedRow = if (self.placementOf(data, entity)) |placement| blk: {
                const aabb = data.staticObstacleWorldRect(entity).?;
                const query = self.queryPlacement(placement, aabb);
                break :blk .{ .placement = placement, .aabb = aabb, .query_class = query.class, .query_key = query.key };
            } else null;
            if (planned) |next| {
                const new_rect = geometry.chunkRect(next.placement);
                if (old_rect == null) adds += 1;
                inserts += new_rect.count() - if (old_rect) |old| new_rect.overlap(old) else 0;
                if (old_query_key != next.query_key) {
                    query_inserts += 1;
                    if (next.query_class <= chunk_shift) {
                        anchor_sets += 1;
                        if (self.chunk_lists.value(geometry.anchorBit(next.query_key).chunk_key) == no_value) new_blocks += 1;
                    }
                }
            }
            if (old_rect) |old| removals += old.count() - if (planned) |next| old.overlap(geometry.chunkRect(next.placement)) else 0;
            if (old_query) |old| {
                if (planned == null or planned.?.query_key != old.key) {
                    query_removals += 1;
                    if (old.class <= chunk_shift) anchor_clears += 1;
                }
            }
            self.sync_plan.appendAssumeCapacity(planned);
        }
        try self.ensureFreeRows(adds);
        try self.chunk_lists.reserve(inserts, inserts, self.rows.len);
        try self.chunk_lists.reserveBatch(inserts, removals);
        try self.query_lists.reserve(query_inserts, query_inserts, self.rows.len);
        try self.query_lists.reserveBatch(query_inserts, query_removals);
        try self.ensureFreeAnchorBlocks(new_blocks);
        try self.reserveAnchorEdits(anchor_sets, anchor_clears);
        try self.changes.ensureTotalCapacity(self.allocator, pending.len);

        self.chunk_lists.beginBatch();
        self.query_lists.beginBatch();
        self.anchor_sets.clearRetainingCapacity();
        self.anchor_clears.clearRetainingCapacity();
        for (pending, self.sync_plan.items) |index, planned| {
            const entity = self.dirty_entity.items[index];
            const old_row = self.row_of_index.items[index];
            var change = ColliderChange{ .entity = entity, .old = null, .new = null };
            // The old row's query class and key, read before `writeRow` replaces its columns.
            var old_query: ?QueryPlacement = null;
            if (old_row != no_row) {
                change.old = self.rowPlacement(old_row);
                old_query = self.queryPlacement(change.old.?, self.rowAabb(old_row));
            }
            if (planned) |next| {
                const row = if (old_row != no_row) old_row else self.claimRow(index);
                const new_rect = geometry.chunkRect(next.placement);
                if (change.old) |old| {
                    const old_rect = geometry.chunkRect(old);
                    if (!new_rect.eql(old_rect)) {
                        if (new_rect.level == old_rect.level) self.chunk_lists.unlinkOwnerOutside(row, new_rect) else self.chunk_lists.unlinkOwnerOutside(row, KeepNone{});
                        self.stageRowChunks(row, entity.index, new_rect, old_rect);
                    }
                } else {
                    self.stageRowChunks(row, entity.index, new_rect, null);
                }
                if (old_query == null or old_query.?.key != next.query_key) {
                    if (old_query) |old| {
                        self.query_lists.unlinkOwnerOutside(row, KeepNone{});
                        self.query_class_rows[old.class] -= 1;
                        if (old.class <= chunk_shift) appendAnchorEdit(&self.anchor_clears, old.key);
                    }
                    self.query_lists.stageInsert(row, next.query_key, entity.index);
                    self.query_class_rows[next.query_class] += 1;
                    if (next.query_class <= chunk_shift) appendAnchorEdit(&self.anchor_sets, next.query_key);
                }
                self.writeRow(row, entity, next.placement, next.aabb);
                change.new = next.placement;
            } else if (old_row != no_row) {
                self.chunk_lists.unlinkOwnerOutside(old_row, KeepNone{});
                self.query_lists.unlinkOwnerOutside(old_row, KeepNone{});
                self.query_class_rows[old_query.?.class] -= 1;
                if (old_query.?.class <= chunk_shift) appendAnchorEdit(&self.anchor_clears, old_query.?.key);
                std.debug.assert(self.row_free.items.len < self.row_free.capacity);
                self.row_free.appendAssumeCapacity(old_row);
                self.row_of_index.items[index] = no_row;
            }
            self.changes.appendAssumeCapacity(change);
        }
        // Query lists first: the anchor edits read their emptiness, and run while the chunk
        // tier still holds every key a block can sit on (its commit drops emptied keys).
        self.last_query_splice_batch = self.query_lists.commitBatch(self.spliceThreads(thread_system, &self.query_splice_tuner));
        self.applyAnchorEdits();
        self.last_splice_batch = self.chunk_lists.commitBatch(self.spliceThreads(thread_system, &self.splice_tuner));
        self.refreshQueryClassMask();

        self.pending_dirty.clearRetainingCapacity();
        self.dirty_generation +%= 1;
        if (self.dirty_generation == 0) {
            @memset(self.dirty_stamp.items, 0);
            self.dirty_generation = 1;
        }
    }

    // A splice stage's threading under `thread_system`, with its own `tuner`.
    fn spliceThreads(self: *const StaticColliderSystem, thread_system: ?*ThreadSystem, tuner: *AdaptiveWorkTuner) ?Dispatch {
        const threads = thread_system orelse return null;
        return Dispatch.init(threads, tuner, self.splice_controls);
    }

    // `entity`'s placement when it is a live static navigation obstacle.
    fn placementOf(self: *const StaticColliderSystem, data: *const DataSystem, entity: EntityId) ?Placement {
        if (!data.isStaticNavigationObstacle(entity)) return null;
        const aabb = data.staticObstacleWorldRect(entity) orelse return null;
        return .{ .level = data.worldLevelConst(entity) orelse 0, .cells = self.geometry.?.footprint(aabb) };
    }

    // Takes a free row for entity index `index`; the reserve grew the free list.
    fn claimRow(self: *StaticColliderSystem, index: u32) u32 {
        std.debug.assert(self.row_free.items.len != 0);
        const row = self.row_free.pop().?;
        std.debug.assert(self.row_of_index.items[index] == no_row);
        self.row_of_index.items[index] = row;
        return row;
    }

    fn writeRow(self: *StaticColliderSystem, row: u32, entity: EntityId, placement: Placement, aabb: math.Aabb) void {
        self.row_entity[row] = entity;
        self.row_level[row] = placement.level;
        self.row_min_x[row] = aabb.min_x;
        self.row_min_y[row] = aabb.min_y;
        self.row_max_x[row] = aabb.max_x;
        self.row_max_y[row] = aabb.max_y;
        self.row_cell_min_x[row] = placement.cells.min_x;
        self.row_cell_min_y[row] = placement.cells.min_y;
        self.row_cell_max_x[row] = placement.cells.max_x;
        self.row_cell_max_y[row] = placement.cells.max_y;
    }

    // Stages `row` into every chunk of `rect` outside `listed` (the chunks it already sits
    // in on the same level, or null). O(1) per chunk of `rect`.
    fn stageRowChunks(self: *StaticColliderSystem, row: u32, order: u32, rect: ChunkRect, listed: ?ChunkRect) void {
        const skip = if (listed) |old| (if (old.level == rect.level) old else null) else null;
        var chunk_y = rect.min_y;
        while (chunk_y <= rect.max_y) : (chunk_y += 1) {
            var chunk_x = rect.min_x;
            while (chunk_x <= rect.max_x) : (chunk_x += 1) {
                if (skip) |old| if (old.holds(chunk_x, chunk_y)) continue;
                self.chunk_lists.stageInsert(row, chunkKey(rect.level, chunk_y * rect.chunks_x + chunk_x), order);
            }
        }
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const StructuralCommand = @import("../data_system.zig").StructuralCommand;
const EntityTemplate = @import("../data_system.zig").EntityTemplate;

// 64 x 64 cells of 32 units in 4-cell chunks: a 16 x 16 chunk grid.
const test_geometry = ColliderGeometry.init(32, 64, 64, 4);

// The placement of entity `index`'s row, or null when it has none.
fn placementOfIndex(colliders: *const StaticColliderSystem, index: u32) ?Placement {
    if (index >= colliders.row_of_index.items.len) return null;
    const row = colliders.row_of_index.items[index];
    if (row == no_row) return null;
    return colliders.rowPlacement(row);
}

// Entries held in the chunk lists.
fn listEntryCount(colliders: *const StaticColliderSystem) usize {
    return colliders.chunk_lists.entries.len - colliders.chunk_lists.entry_free.items.len;
}

fn staticTemplate(position: math.Vec2, size: math.Vec2) EntityTemplate {
    return .{
        .movement_body = .{ .position = position, .previous_position = position },
        .collision_bounds = .{ .size = size },
        .collision_response = .{ .mobility = .static },
    };
}

// The commit seam in order: reserve, commit `commands`, capture, sync.
fn commitForTest(frame: *SimulationFrame, data: *DataSystem, colliders: *StaticColliderSystem, commands: []const StructuralCommand) !void {
    return commitForTestWith(frame, data, colliders, commands, null);
}

// `commitForTest` with the sync's splice stage under `thread_system`.
fn commitForTestWith(frame: *SimulationFrame, data: *DataSystem, colliders: *StaticColliderSystem, commands: []const StructuralCommand, thread_system: ?*ThreadSystem) !void {
    frame.beginStep();
    try colliders.reserveForCommit(data, commands.len);
    try frame.structural_commands.prepareRangeCounts(1);
    frame.structural_commands.addCount(0, commands.len);
    try frame.structural_commands.prefix();
    var writer = frame.structural_commands.rangeWriter(0);
    for (commands) |command| writer.write(command);
    writer.finish();
    frame.structural_commands.finishWrite();
    _ = try frame.applyStructuralCommands(data);
    colliders.capture(frame);
    try colliders.sync(data, thread_system);
}

// Chunks per level on `geometry`.
fn levelChunkCount(geometry: ColliderGeometry) usize {
    return geometry.grid.chunkCount();
}

// A map's empty table slot (no valid key sets both tier bits).
const test_empty_key: u64 = std.math.maxInt(u64);

// Whether `a` and `b` hold identical rows, change lists, list entries (entry ids included)
// of both tiers over `levels` levels, and anchor blocks (block ids included).
fn expectIdenticalLayout(a: *const StaticColliderSystem, b: *const StaticColliderSystem, levels: u16) !void {
    try std.testing.expectEqualSlices(u32, a.row_of_index.items, b.row_of_index.items);
    try std.testing.expectEqual(a.changes.items.len, b.changes.items.len);
    for (a.changes.items, b.changes.items) |change_a, change_b| try std.testing.expectEqual(change_a, change_b);
    const chunk_count = levelChunkCount(a.geometry.?);
    for (0..levels) |level| for (0..chunk_count) |chunk| {
        const key = chunkKey(@intCast(level), @intCast(chunk));
        try expectSameEntries(&a.chunk_lists, &b.chunk_lists, key);
        const block_a = a.chunk_lists.value(key);
        try std.testing.expectEqual(block_a, b.chunk_lists.value(key));
        if (block_a != no_value) try std.testing.expectEqual(a.anchor_blocks.items[block_a], b.anchor_blocks.items[block_a]);
    };
    try std.testing.expectEqual(a.query_lists.live_keys, b.query_lists.live_keys);
    for (a.query_lists.slot_keys) |key| {
        if (key != test_empty_key) try expectSameEntries(&a.query_lists, &b.query_lists, key);
    }
    try std.testing.expectEqual(a.anchor_blocks.items.len, b.anchor_blocks.items.len);
    try std.testing.expectEqualSlices(u32, a.anchor_free.items, b.anchor_free.items);
}

// Whether `key`'s list in `a` and `b` holds the same entries (ids included) and owners.
fn expectSameEntries(a: *const ChunkListMap, b: *const ChunkListMap, key: u64) !void {
    var entry_a = a.head(key);
    var entry_b = b.head(key);
    while (entry_a != no_entry or entry_b != no_entry) {
        try std.testing.expectEqual(entry_a, entry_b);
        try std.testing.expectEqual(a.entry_owner[entry_a], b.entry_owner[entry_b]);
        entry_a = a.entry_next[entry_a];
        entry_b = b.entry_next[entry_b];
    }
}

// Rows listed at (level, chunk), as entity indices in list order.
fn listedIndices(colliders: *const StaticColliderSystem, level: u16, chunk: u32, out: *std.ArrayList(u32)) !void {
    out.clearRetainingCapacity();
    var rows = colliders.view().chunkRows(level, chunk);
    while (rows.next()) |row| try out.append(std.testing.allocator, colliders.row_entity[row].index);
}

// The query tier holds each live row once, at its class and anchor cell, every list
// ascending in entity index; the class counts and mask equal a recount.
fn expectQueryTier(colliders: *const StaticColliderSystem) !void {
    const lists = &colliders.query_lists;
    var class_rows: [max_query_classes]u32 = @splat(0);
    for (colliders.row_of_index.items) |row| {
        if (row == no_row) continue;
        const query = colliders.queryPlacement(colliders.rowPlacement(row), colliders.rowAabb(row));
        class_rows[query.class] += 1;
        const entry = lists.owner_heads.items[row];
        try std.testing.expect(entry != no_entry);
        try std.testing.expectEqual(no_entry, lists.entry_owner_next[entry]);
        try std.testing.expectEqual(query.key, lists.entry_key[entry]);
    }
    try std.testing.expectEqualSlices(u32, &class_rows, &colliders.query_class_rows);
    for (class_rows, 0..) |rows, class| try std.testing.expectEqual(rows != 0, colliders.query_class_mask.isSet(class));
    var entries: usize = 0;
    for (lists.slot_keys, lists.slot_heads) |key, head| {
        if (key == test_empty_key) continue;
        try std.testing.expect(head != no_entry);
        var previous: ?u32 = null;
        var entry = head;
        while (entry != no_entry) : (entry = lists.entry_next[entry]) {
            const index = colliders.row_entity[lists.entry_owner[entry]].index;
            if (previous) |before| try std.testing.expect(before < index);
            previous = index;
            entries += 1;
        }
    }
    try std.testing.expectEqual(colliders.rowCount(), entries);
}

const AnchorWords = [anchor_block_words]u64;

// The anchor bits the present query keys of classes no larger than a chunk imply, per
// chunk-tier key.
fn expectedAnchors(colliders: *const StaticColliderSystem) !std.AutoHashMap(u64, AnchorWords) {
    const geometry = colliders.geometry.?;
    var expected = std.AutoHashMap(u64, AnchorWords).init(std.testing.allocator);
    errdefer expected.deinit();
    for (colliders.query_lists.slot_keys) |key| {
        if (key == test_empty_key) continue;
        const class: u6 = @intCast((key >> 48) & 0x3f);
        if (class > geometry.grid.shift) continue;
        const anchor = geometry.anchorBit(key);
        const words = try expected.getOrPut(anchor.chunk_key);
        if (!words.found_existing) words.value_ptr.* = @splat(0);
        words.value_ptr[anchor.bit >> 6] |= @as(u64, 1) << @intCast(anchor.bit & 63);
    }
    return expected;
}

// I1: a chunk-tier key holds a block exactly when a fine-class query key sits in its
// chunk, with exactly those bits and their count; every pooled block is live once or free
// and all-zero.
fn expectAnchors(colliders: *const StaticColliderSystem) !void {
    var expected = try expectedAnchors(colliders);
    defer expected.deinit();
    const blocks = colliders.anchor_blocks.items;
    var seen = try std.DynamicBitSet.initEmpty(std.testing.allocator, blocks.len);
    defer seen.deinit();
    var live_blocks: usize = 0;
    for (colliders.chunk_lists.slot_keys, colliders.chunk_lists.slot_values) |key, block_id| {
        if (key == test_empty_key) continue;
        const words = expected.get(key) orelse {
            try std.testing.expectEqual(no_value, block_id);
            continue;
        };
        try std.testing.expect(block_id < blocks.len and !seen.isSet(block_id));
        seen.set(block_id);
        try std.testing.expectEqualSlices(u64, &words, &blocks[block_id].words);
        var bits: usize = 0;
        for (words) |word| bits += @popCount(word);
        try std.testing.expectEqual(bits, blocks[block_id].set_bits);
        live_blocks += 1;
    }
    // Every anchored chunk has its chunk-tier key.
    try std.testing.expectEqual(expected.count(), live_blocks);
    for (colliders.anchor_free.items) |block_id| {
        try std.testing.expect(block_id < blocks.len and !seen.isSet(block_id));
        seen.set(block_id);
        try std.testing.expectEqual(empty_anchor_block, blocks[block_id]);
    }
    try std.testing.expectEqual(blocks.len, live_blocks + colliders.anchor_free.items.len);
}

// Whether `a` and `b` hold the same anchor bits per chunk (block ids may differ).
fn expectSameAnchors(a: *const StaticColliderSystem, b: *const StaticColliderSystem) !void {
    var valued: [2]usize = .{ 0, 0 };
    for ([_]*const StaticColliderSystem{ a, b }, &valued) |colliders, *count| {
        for (colliders.chunk_lists.slot_keys, colliders.chunk_lists.slot_values) |key, block_id| {
            if (key != test_empty_key and block_id != no_value) count.* += 1;
        }
    }
    try std.testing.expectEqual(valued[0], valued[1]);
    for (a.chunk_lists.slot_keys, a.chunk_lists.slot_values) |key, block_a| {
        if (key == test_empty_key or block_a == no_value) continue;
        const block_b = b.chunk_lists.value(key);
        try std.testing.expect(block_b != no_value);
        try std.testing.expectEqual(a.anchor_blocks.items[block_a], b.anchor_blocks.items[block_b]);
    }
}

// Whether `a` and `b` hold the same rows, the same lists over `levels` levels, the same
// query tier, and the same anchor bits; each system's tiers and blocks agree with its rows.
fn expectSameRows(a: *const StaticColliderSystem, b: *const StaticColliderSystem, levels: u16) !void {
    try std.testing.expectEqual(a.rowCount(), b.rowCount());
    const index_count = @max(a.row_of_index.items.len, b.row_of_index.items.len);
    for (0..index_count) |index| {
        try std.testing.expectEqual(placementOfIndex(a, @intCast(index)), placementOfIndex(b, @intCast(index)));
    }
    var listed_a: std.ArrayList(u32) = .empty;
    defer listed_a.deinit(std.testing.allocator);
    var listed_b: std.ArrayList(u32) = .empty;
    defer listed_b.deinit(std.testing.allocator);
    const chunk_count = levelChunkCount(a.geometry.?);
    for (0..levels) |level| for (0..chunk_count) |chunk| {
        try listedIndices(a, @intCast(level), @intCast(chunk), &listed_a);
        try listedIndices(b, @intCast(level), @intCast(chunk), &listed_b);
        try std.testing.expectEqualSlices(u32, listed_b.items, listed_a.items);
    };
    try std.testing.expectEqual(listEntryCount(a), listEntryCount(b));
    for ([_]*const StaticColliderSystem{ a, b }) |colliders| {
        try expectQueryTier(colliders);
        try expectAnchors(colliders);
    }
    try std.testing.expectEqual(a.query_lists.live_keys, b.query_lists.live_keys);
    for (a.query_lists.slot_keys) |key| {
        if (key == test_empty_key) continue;
        var owners_a = a.query_lists.iterator(key);
        var owners_b = b.query_lists.iterator(key);
        while (owners_a.next()) |row_a| {
            const row_b = owners_b.next() orelse return error.TestExpectedEqual;
            try std.testing.expectEqual(a.row_entity[row_a].index, b.row_entity[row_b].index);
        }
        try std.testing.expect(owners_b.next() == null);
    }
    try expectSameAnchors(a, b);
}

const SeamFixture = struct {
    data: DataSystem,
    frame: SimulationFrame,
    colliders: StaticColliderSystem,
    geometry: ColliderGeometry,

    fn init() !SeamFixture {
        return initWith(test_geometry);
    }

    fn initWith(geometry: ColliderGeometry) !SeamFixture {
        var fixture = SeamFixture{
            .data = DataSystem.init(std.testing.allocator),
            .frame = SimulationFrame.init(std.testing.allocator),
            .colliders = StaticColliderSystem.init(std.testing.allocator),
            .geometry = geometry,
        };
        errdefer fixture.deinit();
        try fixture.colliders.rebuild(&fixture.data, geometry);
        return fixture;
    }

    fn deinit(self: *SeamFixture) void {
        self.colliders.deinit();
        self.frame.deinit();
        self.data.deinit();
    }

    fn rebuilt(self: *const SeamFixture) !StaticColliderSystem {
        var colliders = StaticColliderSystem.init(std.testing.allocator);
        errdefer colliders.deinit();
        try colliders.rebuild(&self.data, self.geometry);
        return colliders;
    }
};

test "creating a static from a template indexes it once" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    // A 1.5-cell box at a chunk corner covers four chunks.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 112, .y = 112 }, .{ .x = 48, .y = 48 }) }});
    try std.testing.expectEqual(@as(usize, 1), fixture.colliders.rowCount());
    try std.testing.expectEqual(@as(usize, 4), listEntryCount(&fixture.colliders));
    try std.testing.expectEqual(@as(usize, 1), fixture.colliders.changesThisStep().len);
    const change = fixture.colliders.changesThisStep()[0];
    try std.testing.expect(change.old == null);
    try std.testing.expectEqual(CellSpan{ .min_x = 3, .min_y = 3, .max_x = 4, .max_y = 4 }, change.new.?.cells);
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
}

test "a cell-aligned static past 32768 world units covers only its own cell and chunk" {
    // 2048 x 2048 cells of 32 units in 16-cell chunks: the max edge 35,328 sits between
    // cells 1103 and 1104 and chunks 68 and 69, where f32 spacing is about 0.004.
    const far = ColliderGeometry.init(32, 2048, 2048, 16);
    var fixture = try SeamFixture.initWith(far);
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 35_296, .y = 35_296 }, .{ .x = 32, .y = 32 }) }});
    const placement = fixture.colliders.changesThisStep()[0].new.?;
    try std.testing.expectEqual(CellSpan{ .min_x = 1103, .min_y = 1103, .max_x = 1103, .max_y = 1103 }, placement.cells);
    try std.testing.expectEqual(@as(usize, 1), listEntryCount(&fixture.colliders));
    var listed: std.ArrayList(u32) = .empty;
    defer listed.deinit(std.testing.allocator);
    try listedIndices(&fixture.colliders, 0, 68 * far.grid.chunks_x + 68, &listed);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
}

test "destroying a template-created static frees every footprint entry" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 100, .y = 100 }, .{ .x = 200, .y = 40 }) }});
    const entity = fixture.colliders.changesThisStep()[0].entity;
    try std.testing.expect(listEntryCount(&fixture.colliders) > 1);
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .destroy_entity = entity }});
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.rowCount());
    try std.testing.expectEqual(@as(usize, 0), listEntryCount(&fixture.colliders));
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.chunk_lists.live_keys);
    const change = fixture.colliders.changesThisStep()[0];
    try std.testing.expect(change.old != null and change.new == null);
}

test "a static's level change moves its row to the new level" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    const entity = fixture.colliders.changesThisStep()[0].entity;
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .set_world_level = .{ .entity = entity, .level = 2 } }});
    try std.testing.expectEqual(@as(u16, 2), placementOfIndex(&fixture.colliders, entity.index).?.level);
    try std.testing.expect(!fixture.colliders.view().chunkHasRows(0, 0));
    try std.testing.expect(fixture.colliders.view().chunkHasRows(2, 0));
    const change = fixture.colliders.changesThisStep()[0];
    try std.testing.expectEqual(@as(u16, 0), change.old.?.level);
    try std.testing.expectEqual(@as(u16, 2), change.new.?.level);
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 3);
}

test "a destroy and a create reusing the index in one commit keep only the new row" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    const old = fixture.colliders.changesThisStep()[0].entity;
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{
        .{ .destroy_entity = old },
        .{ .create_entity = staticTemplate(.{ .x = 1000, .y = 1000 }, .{ .x = 8, .y = 8 }) },
    });
    try std.testing.expectEqual(@as(usize, 1), fixture.colliders.rowCount());
    const change = fixture.colliders.changesThisStep()[0];
    // The slot was reused: one change for the index, from the old row to the new one.
    try std.testing.expectEqual(@as(usize, 1), fixture.colliders.changesThisStep().len);
    try std.testing.expectEqual(old.index, change.entity.index);
    try std.testing.expect(!change.entity.eql(old));
    try std.testing.expectEqual(@as(u32, 1), change.old.?.cells.min_x);
    try std.testing.expectEqual(@as(u32, 31), change.new.?.cells.min_x);
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
}

test "chunk lists stay in entity order under any add/remove order" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var prng = std.Random.DefaultPrng.init(0x5c5);
    const random = prng.random();
    var live: std.ArrayList(EntityId) = .empty;
    defer live.deinit(std.testing.allocator);
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    for (0..12) |_| {
        commands.clearRetainingCapacity();
        // Destroys, moves, mobility flips, and creates, all crowding a few chunks.
        for (live.items) |entity| {
            const position = math.Vec2{ .x = random.float(f32) * 300, .y = random.float(f32) * 300 };
            switch (random.uintLessThan(u8, 4)) {
                0 => try commands.append(std.testing.allocator, .{ .destroy_entity = entity }),
                1 => try commands.append(std.testing.allocator, .{ .set_movement_body = .{ .entity = entity, .body = .{ .position = position, .previous_position = position } } }),
                2 => try commands.append(std.testing.allocator, .{ .set_collision_response = .{ .entity = entity, .response = .{ .mobility = if (random.boolean()) .static else .dynamic } } }),
                else => {},
            }
        }
        for (0..random.uintLessThan(usize, 6)) |_| {
            const position = math.Vec2{ .x = random.float(f32) * 300, .y = random.float(f32) * 300 };
            try commands.append(std.testing.allocator, .{ .create_entity = staticTemplate(position, .{ .x = 10 + random.float(f32) * 60, .y = 10 + random.float(f32) * 60 }) });
        }
        try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, commands.items);
        live.clearRetainingCapacity();
        for (fixture.data.movementBodySliceConst().entities) |entity| try live.append(std.testing.allocator, entity);
        // Every list is ascending in entity index and equals a rebuild's.
        var rebuilt = try fixture.rebuilt();
        defer rebuilt.deinit();
        try expectSameRows(&fixture.colliders, &rebuilt, 1);
        var listed: std.ArrayList(u32) = .empty;
        defer listed.deinit(std.testing.allocator);
        for (0..test_geometry.grid.chunks_x * test_geometry.grid.chunks_x) |chunk| {
            try listedIndices(&fixture.colliders, 0, @intCast(chunk), &listed);
            for (0..listed.items.len -| 1) |at| try std.testing.expect(listed.items[at] < listed.items[at + 1]);
        }
    }
}

test "sync runs out of memory at every allocation and leaves the structure unchanged; the retry applies it, serial and threaded" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    for ([_]?*ThreadSystem{ null, &threads }) |thread_system| try expectSyncOutOfMemorySafe(thread_system);
}

fn expectSyncOutOfMemorySafe(thread_system: ?*ThreadSystem) !void {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var fixture = try SeamFixture.init();
        defer fixture.deinit();
        fixture.colliders.splice_controls = .{ .adaptive = false, .items_per_range = 8 };
        try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) }});
        const moved = fixture.colliders.changesThisStep()[0].entity;
        var before = try fixture.rebuilt();
        defer before.deinit();

        // One commit growing the rows, lists, and anchor blocks past their reserve: a move
        // into a fresh chunk plus new statics, coarse and fine, in fresh chunks.
        var commands: [13]StructuralCommand = undefined;
        commands[0] = .{ .set_movement_body = .{ .entity = moved, .body = .{ .position = .{ .x = 900, .y = 900 }, .previous_position = .{ .x = 900, .y = 900 } } } };
        for (commands[1..9], 0..) |*command, at| command.* = .{ .create_entity = staticTemplate(.{ .x = @floatFromInt(at * 150), .y = 500 }, .{ .x = 140, .y = 140 }) };
        for (commands[9..], 0..) |*command, at| command.* = .{ .create_entity = staticTemplate(.{ .x = @floatFromInt(at * 260 + 10), .y = 1300 }, .{ .x = 20, .y = 20 }) };
        fixture.frame.beginStep();
        try fixture.colliders.reserveForCommit(&fixture.data, commands.len);
        try fixture.frame.structural_commands.prepareRangeCounts(1);
        fixture.frame.structural_commands.addCount(0, commands.len);
        try fixture.frame.structural_commands.prefix();
        var writer = fixture.frame.structural_commands.rangeWriter(0);
        for (commands) |command| writer.write(command);
        writer.finish();
        fixture.frame.structural_commands.finishWrite();
        _ = try fixture.frame.applyStructuralCommands(&fixture.data);
        fixture.colliders.capture(&fixture.frame);

        const blocks_before = fixture.colliders.anchor_blocks.items.len;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = fail_index });
        fixture.colliders.allocator = failing.allocator();
        fixture.colliders.chunk_lists.allocator = failing.allocator();
        fixture.colliders.query_lists.allocator = failing.allocator();
        const result = fixture.colliders.sync(&fixture.data, thread_system);
        fixture.colliders.allocator = std.testing.allocator;
        fixture.colliders.chunk_lists.allocator = std.testing.allocator;
        fixture.colliders.query_lists.allocator = std.testing.allocator;
        if (result) |_| {
            try std.testing.expect(!failing.has_induced_failure);
            if (thread_system != null) try std.testing.expect(!fixture.colliders.last_splice_batch.ran_inline and !fixture.colliders.last_query_splice_batch.ran_inline);
            // The swept sync grew the anchor-block pool.
            try std.testing.expect(fixture.colliders.anchor_blocks.items.len > blocks_before);
            var after = try fixture.rebuilt();
            defer after.deinit();
            try expectSameRows(&fixture.colliders, &after, 1);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try expectSameRows(&fixture.colliders, &before, 1);
            try std.testing.expectEqual(@as(usize, 0), fixture.colliders.changesThisStep().len);
            // The next step's sync, with nothing new captured, applies the kept change.
            try commitForTestWith(&fixture.frame, &fixture.data, &fixture.colliders, &.{}, thread_system);
            try std.testing.expectEqual(commands.len, fixture.colliders.changesThisStep().len);
            var after = try fixture.rebuilt();
            defer after.deinit();
            try expectSameRows(&fixture.colliders, &after, 1);
        }
    }
}

test "sync after reserve allocates nothing (FailingAllocator)" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var templates: [16]StructuralCommand = undefined;
    for (&templates, 0..) |*command, at| command.* = .{ .create_entity = staticTemplate(.{ .x = @floatFromInt(at * 100), .y = 300 }, .{ .x = 90, .y = 90 }) };
    // A static alone in its chunk, destroyed by the measured commit.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 40, .y = 1000 }, .{ .x = 8, .y = 8 }) }});
    const kept = fixture.colliders.changesThisStep()[0].entity;
    const kept_chunk = chunkKey(0, 7 * test_geometry.grid.chunks_x);
    // Warm: create, then destroy, so rows, lists, anchor blocks, and the change list hold
    // their high-water.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &templates);
    var destroys: [16]StructuralCommand = undefined;
    for (fixture.colliders.changesThisStep(), &destroys) |change, *command| command.* = .{ .destroy_entity = change.entity };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &destroys);
    try std.testing.expect(fixture.colliders.chunk_lists.value(kept_chunk) != no_value);

    // The seam's reserve runs with the real allocator before the commit, as the pipeline
    // does; the commit reuses the freed slots, and capture and sync allocate nothing while
    // claiming blocks for the new chunks and releasing the destroyed static's.
    var commands: [17]StructuralCommand = undefined;
    @memcpy(commands[0..16], &templates);
    commands[16] = .{ .destroy_entity = kept };
    fixture.frame.beginStep();
    try fixture.colliders.reserveForCommit(&fixture.data, commands.len);
    try fixture.frame.structural_commands.prepareRangeCounts(1);
    fixture.frame.structural_commands.addCount(0, commands.len);
    try fixture.frame.structural_commands.prefix();
    var writer = fixture.frame.structural_commands.rangeWriter(0);
    for (commands) |command| writer.write(command);
    writer.finish();
    fixture.frame.structural_commands.finishWrite();
    _ = try fixture.frame.applyStructuralCommands(&fixture.data);
    {
        fixture.colliders.allocator = std.testing.failing_allocator;
        fixture.colliders.chunk_lists.allocator = std.testing.failing_allocator;
        fixture.colliders.query_lists.allocator = std.testing.failing_allocator;
        defer {
            fixture.colliders.allocator = std.testing.allocator;
            fixture.colliders.chunk_lists.allocator = std.testing.allocator;
            fixture.colliders.query_lists.allocator = std.testing.allocator;
        }
        fixture.colliders.capture(&fixture.frame);
        try fixture.colliders.sync(&fixture.data, null);
    }
    try std.testing.expectEqual(@as(usize, 16), fixture.colliders.rowCount());
    try std.testing.expectEqual(no_value, fixture.colliders.chunk_lists.value(kept_chunk));
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
}

test "a step with no entity changes captures nothing" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    // A dynamic body's create and move touch no static.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = .{ .movement_body = .{ .position = .{ .x = 5, .y = 5 } } } }});
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.changesThisStep().len);
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.pending_dirty.items.len);
}

// Random statics crowding the first 300 x 300 units (a few chunks each way), sizes up to
// several chunks.
fn randomStatic(random: std.Random) StructuralCommand {
    const position = math.Vec2{ .x = random.float(f32) * 300, .y = random.float(f32) * 300 };
    return .{ .create_entity = staticTemplate(position, .{ .x = 6 + random.float(f32) * 150, .y = 6 + random.float(f32) * 150 }) };
}

// One dense mixed commit over `live`: destroys, moves inside the static's chunks and across
// chunks, level changes, mobility flips, then creates that reuse the freed indices.
fn denseMixedCommands(random: std.Random, data: *const DataSystem, live: []const EntityId, commands: *std.ArrayList(StructuralCommand)) !void {
    commands.clearRetainingCapacity();
    for (live) |entity| {
        const body = data.movementBodyConst(entity).?;
        switch (random.uintLessThan(u8, 7)) {
            0 => try commands.append(std.testing.allocator, .{ .destroy_entity = entity }),
            1 => {
                // One unit over: the chunk rect almost always holds.
                const position = math.Vec2{ .x = body.position.x + 1, .y = body.position.y };
                try commands.append(std.testing.allocator, .{ .set_movement_body = .{ .entity = entity, .body = .{ .position = position, .previous_position = position } } });
            },
            2 => {
                const position = math.Vec2{ .x = random.float(f32) * 300, .y = random.float(f32) * 300 };
                try commands.append(std.testing.allocator, .{ .set_movement_body = .{ .entity = entity, .body = .{ .position = position, .previous_position = position } } });
            },
            3 => try commands.append(std.testing.allocator, .{ .set_world_level = .{ .entity = entity, .level = random.uintLessThan(u16, 3) } }),
            4 => try commands.append(std.testing.allocator, .{ .set_collision_response = .{ .entity = entity, .response = .{ .mobility = if (random.boolean()) .static else .dynamic } } }),
            else => {},
        }
    }
    for (0..random.uintLessThan(usize, 24)) |_| try commands.append(std.testing.allocator, randomStatic(random));
}

test "a dense mixed collider sync lists every chunk in entity order, threaded equal to serial and to a rebuild" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    var serial = try SeamFixture.init();
    defer serial.deinit();
    var threaded = try SeamFixture.init();
    defer threaded.deinit();
    threaded.colliders.splice_controls = .{ .adaptive = false, .items_per_range = 8 };
    var prng = std.Random.DefaultPrng.init(0xd5e5);
    const random = prng.random();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    for (0..120) |_| try commands.append(std.testing.allocator, randomStatic(random));
    try commitForTest(&serial.frame, &serial.data, &serial.colliders, commands.items);
    try commitForTestWith(&threaded.frame, &threaded.data, &threaded.colliders, commands.items, &threads);
    var live: std.ArrayList(EntityId) = .empty;
    defer live.deinit(std.testing.allocator);
    var threaded_ranges: usize = 0;
    var threaded_query_ranges: usize = 0;
    for (0..10) |_| {
        live.clearRetainingCapacity();
        for (serial.data.movementBodySliceConst().entities) |entity| try live.append(std.testing.allocator, entity);
        try denseMixedCommands(random, &serial.data, live.items, &commands);
        try commitForTest(&serial.frame, &serial.data, &serial.colliders, commands.items);
        try commitForTestWith(&threaded.frame, &threaded.data, &threaded.colliders, commands.items, &threads);
        try expectIdenticalLayout(&serial.colliders, &threaded.colliders, 3);
        var rebuilt = try serial.rebuilt();
        defer rebuilt.deinit();
        try expectSameRows(&serial.colliders, &rebuilt, 3);
        const batch = threaded.colliders.last_splice_batch;
        if (!batch.ran_inline and batch.range_count > 1) threaded_ranges += 1;
        const query_batch = threaded.colliders.last_query_splice_batch;
        if (!query_batch.ran_inline and query_batch.range_count > 1) threaded_query_ranges += 1;
    }
    try std.testing.expect(threaded_ranges != 0);
    try std.testing.expect(threaded_query_ranges != 0);
}

test "a splice worker cap of zero keeps both splice stages inline on a multi-worker ThreadSystem and lists the same chunks" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var uncapped = try SeamFixture.init();
    defer uncapped.deinit();
    var capped = try SeamFixture.init();
    defer capped.deinit();
    // A fixed partition that runs both splices on workers unless the cap holds them inline.
    uncapped.colliders.splice_controls = .{ .adaptive = false, .items_per_range = 8 };
    capped.colliders.splice_controls = .{ .adaptive = false, .items_per_range = 8, .max_worker_threads = 0 };
    var prng = std.Random.DefaultPrng.init(0xd5e5);
    const random = prng.random();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    for (0..120) |_| try commands.append(std.testing.allocator, randomStatic(random));
    try commitForTestWith(&uncapped.frame, &uncapped.data, &uncapped.colliders, commands.items, &threads);
    try commitForTestWith(&capped.frame, &capped.data, &capped.colliders, commands.items, &threads);
    var live: std.ArrayList(EntityId) = .empty;
    defer live.deinit(std.testing.allocator);
    var threaded_ranges: usize = 0;
    var threaded_query_ranges: usize = 0;
    for (0..10) |_| {
        live.clearRetainingCapacity();
        for (uncapped.data.movementBodySliceConst().entities) |entity| try live.append(std.testing.allocator, entity);
        try denseMixedCommands(random, &uncapped.data, live.items, &commands);
        try commitForTestWith(&uncapped.frame, &uncapped.data, &uncapped.colliders, commands.items, &threads);
        try commitForTestWith(&capped.frame, &capped.data, &capped.colliders, commands.items, &threads);
        try expectIdenticalLayout(&uncapped.colliders, &capped.colliders, 3);
        for ([_][2]BatchStats{
            .{ uncapped.colliders.last_splice_batch, capped.colliders.last_splice_batch },
            .{ uncapped.colliders.last_query_splice_batch, capped.colliders.last_query_splice_batch },
        }) |pair| {
            try std.testing.expectEqual(pair[0].item_count, pair[1].item_count);
            try std.testing.expect(pair[1].ran_inline and pair[1].active_worker_threads == 0);
        }
        const batch = uncapped.colliders.last_splice_batch;
        if (!batch.ran_inline and batch.worker_thread_ranges != 0) threaded_ranges += 1;
        const query_batch = uncapped.colliders.last_query_splice_batch;
        if (!query_batch.ran_inline and query_batch.worker_thread_ranges != 0) threaded_query_ranges += 1;
    }
    try std.testing.expect(threaded_ranges != 0);
    try std.testing.expect(threaded_query_ranges != 0);
}

// Every growth counter's once-only log flag is set.
fn expectGrowthsLogged(colliders: *const StaticColliderSystem) !void {
    try std.testing.expect(colliders.row_growth_logged);
    try std.testing.expect(colliders.chunk_lists.growth_logged);
    try std.testing.expect(colliders.query_lists.growth_logged);
    try std.testing.expect(colliders.anchor_growth_logged);
}

test "a rebuild adds its growths to the row, chunk-list, query-list, and anchor-block growth counters and keeps their logged flags" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var prng = std.Random.DefaultPrng.init(0x9e0);
    const random = prng.random();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    for (0..60) |_| try commands.append(std.testing.allocator, randomStatic(random));
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, commands.items);
    const row_grows = fixture.colliders.row_grows;
    const list_grows = fixture.colliders.chunk_lists.grows;
    const query_grows = fixture.colliders.query_lists.grows;
    const anchor_grows = fixture.colliders.anchor_grows;
    try std.testing.expect(row_grows != 0 and list_grows != 0 and query_grows != 0 and anchor_grows != 0);
    try expectGrowthsLogged(&fixture.colliders);
    // The two list tiers log under distinct names.
    try std.testing.expect(!std.mem.eql(u8, fixture.colliders.chunk_lists.name, fixture.colliders.query_lists.name));

    // A rebuild of the same statics grows as a fresh one does, on top of the earlier count.
    var reference = try fixture.rebuilt();
    defer reference.deinit();
    try fixture.colliders.rebuild(&fixture.data, test_geometry);
    try std.testing.expectEqual(row_grows + reference.row_grows, fixture.colliders.row_grows);
    try std.testing.expectEqual(list_grows + reference.chunk_lists.grows, fixture.colliders.chunk_lists.grows);
    try std.testing.expectEqual(query_grows + reference.query_lists.grows, fixture.colliders.query_lists.grows);
    try std.testing.expectEqual(anchor_grows + reference.anchor_grows, fixture.colliders.anchor_grows);
    try expectGrowthsLogged(&fixture.colliders);

    // A rebuild over no statics keeps the counts and the logged flags.
    var empty = DataSystem.init(std.testing.allocator);
    defer empty.deinit();
    var empty_reference = StaticColliderSystem.init(std.testing.allocator);
    defer empty_reference.deinit();
    try empty_reference.rebuild(&empty, test_geometry);
    const total_rows = fixture.colliders.row_grows;
    const total_lists = fixture.colliders.chunk_lists.grows;
    const total_queries = fixture.colliders.query_lists.grows;
    const total_anchors = fixture.colliders.anchor_grows;
    try fixture.colliders.rebuild(&empty, test_geometry);
    try std.testing.expectEqual(total_rows + empty_reference.row_grows, fixture.colliders.row_grows);
    try std.testing.expectEqual(total_lists + empty_reference.chunk_lists.grows, fixture.colliders.chunk_lists.grows);
    try std.testing.expectEqual(total_queries + empty_reference.query_lists.grows, fixture.colliders.query_lists.grows);
    try std.testing.expectEqual(total_anchors + empty_reference.anchor_grows, fixture.colliders.anchor_grows);
    try expectGrowthsLogged(&fixture.colliders);
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.rowCount());
}

test "a move inside its footprint chunks touches no list" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    // A 3-chunk-wide static, then a move that keeps its chunk rect.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 140, .y = 140 }, .{ .x = 300, .y = 20 }) }});
    const entity = fixture.colliders.changesThisStep()[0].entity;
    var heads_before: [16 * 16]u32 = undefined;
    for (&heads_before, 0..) |*head, chunk| head.* = fixture.colliders.chunk_lists.head(chunkKey(0, @intCast(chunk)));
    const live_before = listEntryCount(&fixture.colliders);
    const position = math.Vec2{ .x = 150, .y = 150 };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .set_movement_body = .{ .entity = entity, .body = .{ .position = position, .previous_position = position } } }});
    const change = fixture.colliders.changesThisStep()[0];
    try std.testing.expect(!std.meta.eql(change.old.?.cells, change.new.?.cells));
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.last_splice_batch.item_count);
    try std.testing.expectEqual(live_before, listEntryCount(&fixture.colliders));
    for (heads_before, 0..) |head, chunk| try std.testing.expectEqual(head, fixture.colliders.chunk_lists.head(chunkKey(0, @intCast(chunk))));
    try std.testing.expectEqual(change.new.?, placementOfIndex(&fixture.colliders, entity.index).?);
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
}

test "a destroy-heavy sync grows no rows" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var creates: [32]StructuralCommand = undefined;
    for (&creates, 0..) |*command, at| command.* = .{ .create_entity = staticTemplate(.{ .x = @floatFromInt(at * 60), .y = 100 }, .{ .x = 8, .y = 8 }) };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &creates);
    const pooled = fixture.colliders.rows.len;
    const grows = fixture.colliders.row_grows;
    var destroys: [32]StructuralCommand = undefined;
    for (fixture.colliders.changesThisStep(), &destroys) |change, *command| command.* = .{ .destroy_entity = change.entity };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &destroys);
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.rowCount());
    try std.testing.expectEqual(pooled, fixture.colliders.rows.len);
    try std.testing.expectEqual(grows, fixture.colliders.row_grows);
}

test "a threaded sync after its reserves allocates nothing on a multi-worker ThreadSystem (FailingAllocator)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    fixture.colliders.splice_controls = .{ .adaptive = false, .items_per_range = 8 };
    // 48 one-cell statics over 48 chunks, each then moved one chunk over and back.
    var creates: [48]StructuralCommand = undefined;
    for (&creates, 0..) |*command, at| command.* = .{ .create_entity = staticTemplate(.{ .x = @floatFromInt((at % 12) * 128 + 4), .y = @floatFromInt((at / 12) * 128 + 4) }, .{ .x = 8, .y = 8 }) };
    try commitForTestWith(&fixture.frame, &fixture.data, &fixture.colliders, &creates, &threads);
    var statics: [48]EntityId = undefined;
    for (fixture.colliders.changesThisStep(), &statics) |change, *entity| entity.* = change.entity;
    var moves: [48]StructuralCommand = undefined;
    for (0..3) |round| {
        for (statics, &moves, 0..) |entity, *command, at| {
            const offset: f32 = if (round % 2 == 0) 128 else 0;
            const position = math.Vec2{ .x = @as(f32, @floatFromInt((at % 12) * 128 + 4)) + offset, .y = @floatFromInt((at / 12) * 128 + 4) };
            command.* = .{ .set_movement_body = .{ .entity = entity, .body = .{ .position = position, .previous_position = position } } };
        }
        if (round < 2) {
            try commitForTestWith(&fixture.frame, &fixture.data, &fixture.colliders, &moves, &threads);
            continue;
        }
        // The seam's reserve runs with the real allocator; capture and sync allocate nothing.
        fixture.frame.beginStep();
        try fixture.colliders.reserveForCommit(&fixture.data, moves.len);
        try fixture.frame.structural_commands.prepareRangeCounts(1);
        fixture.frame.structural_commands.addCount(0, moves.len);
        try fixture.frame.structural_commands.prefix();
        var writer = fixture.frame.structural_commands.rangeWriter(0);
        for (moves) |command| writer.write(command);
        writer.finish();
        fixture.frame.structural_commands.finishWrite();
        _ = try fixture.frame.applyStructuralCommands(&fixture.data);
        fixture.colliders.allocator = std.testing.failing_allocator;
        fixture.colliders.chunk_lists.allocator = std.testing.failing_allocator;
        fixture.colliders.query_lists.allocator = std.testing.failing_allocator;
        defer {
            fixture.colliders.allocator = std.testing.allocator;
            fixture.colliders.chunk_lists.allocator = std.testing.allocator;
            fixture.colliders.query_lists.allocator = std.testing.allocator;
        }
        fixture.colliders.capture(&fixture.frame);
        try fixture.colliders.sync(&fixture.data, &threads);
        try std.testing.expect(!fixture.colliders.last_splice_batch.ran_inline and fixture.colliders.last_splice_batch.range_count > 1);
        try std.testing.expect(!fixture.colliders.last_query_splice_batch.ran_inline and fixture.colliders.last_query_splice_batch.range_count > 1);
        // Every static's anchor moved: 48 sets and 48 clears ran.
        try std.testing.expectEqual(@as(usize, 48), fixture.colliders.anchor_sets.items.len);
        try std.testing.expectEqual(@as(usize, 48), fixture.colliders.anchor_clears.items.len);
    }
    try std.testing.expectEqual(@as(usize, 48), fixture.colliders.rowCount());
    try std.testing.expect(fixture.colliders.anchor_blocks.items.len != 0);
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
}

test "a row pool grow that fails after the pool moved keeps the column views on the live pool" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    // Growing past the pool moves it (allocation 0); growing the free list (allocation 1,
    // after a refused in-place resize) fails.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    fixture.colliders.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, fixture.colliders.ensureFreeRows(fixture.colliders.rows.capacity + 1));
    fixture.colliders.allocator = std.testing.allocator;
    const columns = fixture.colliders.rows.slice();
    try std.testing.expectEqual(columns.items(.level).ptr, fixture.colliders.row_level.ptr);
    try std.testing.expectEqual(columns.items(.entity).ptr, fixture.colliders.row_entity.ptr);
    try std.testing.expectEqual(columns.items(.cell_max_y).ptr, fixture.colliders.row_cell_max_y.ptr);
    // The retry adds rows beside the kept one.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 400, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    try std.testing.expectEqual(@as(usize, 2), fixture.colliders.rowCount());
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
}

fn staticTemplateOn(position: math.Vec2, size: math.Vec2, level: u16) EntityTemplate {
    var template = staticTemplate(position, size);
    template.world_level = level;
    return template;
}

fn moveCommand(entity: EntityId, position: math.Vec2) StructuralCommand {
    return .{ .set_movement_body = .{ .entity = entity, .body = .{ .position = position, .previous_position = position } } };
}

fn resizeCommand(entity: EntityId, size: math.Vec2) StructuralCommand {
    return .{ .set_collision_bounds = .{ .entity = entity, .bounds = .{ .size = size } } };
}

// The entities of the last sync's changes, in change order.
fn changedEntities(colliders: *const StaticColliderSystem, out: []EntityId) void {
    for (colliders.changesThisStep(), out) |change, *entity| entity.* = change.entity;
}

// A size from a tile fraction to beyond a 64-tile level.
fn randomStaticSize(random: std.Random) math.Vec2 {
    const level_edge: f32 = 64 * 32;
    const scale: f32 = switch (random.uintLessThan(u8, 4)) {
        0 => 32,
        1 => 200,
        2 => 1200,
        else => 2 * level_edge,
    };
    return .{ .x = 0.001 + random.float(f32) * scale, .y = 0.001 + random.float(f32) * scale };
}

// A position from left of and above the level to beyond it.
fn randomStaticPosition(random: std.Random) math.Vec2 {
    const level_edge: f32 = 64 * 32;
    return .{ .x = -level_edge / 4 + random.float(f32) * level_edge * 1.5, .y = -level_edge / 4 + random.float(f32) * level_edge * 1.5 };
}

test "the query tier lists every row once at its class and anchor cell, equal to a rebuild" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var prng = std.Random.DefaultPrng.init(0x9a1e);
    const random = prng.random();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    // On a chunk border, class edges exactly, negative, outside the level, larger than the
    // level, and a zero extent (a tiny size absorbed by a large position).
    const placed = [_][4]f32{
        .{ 128, 128, 32, 32 },
        .{ 256, 0, 64, 64 },
        .{ 0, 384, 128, 128 },
        .{ -500, -40, 30, 30 },
        .{ 2500, 2100, 8, 8 },
        .{ 10, 10, 3000, 3000 },
        .{ 1500, 1500, 0.00001, 0.00001 },
    };
    for (placed, 0..) |rect, at| try commands.append(std.testing.allocator, .{ .create_entity = staticTemplateOn(.{ .x = rect[0], .y = rect[1] }, .{ .x = rect[2], .y = rect[3] }, @intCast(at % 3)) });
    try std.testing.expectEqual(@as(f32, 1500), @as(f32, 1500) + @as(f32, 0.00001));
    var live: std.ArrayList(EntityId) = .empty;
    defer live.deinit(std.testing.allocator);
    for (0..5) |round| {
        if (round != 0) {
            commands.clearRetainingCapacity();
            for (live.items) |entity| switch (random.uintLessThan(u8, 5)) {
                0 => try commands.append(std.testing.allocator, moveCommand(entity, randomStaticPosition(random))),
                1 => try commands.append(std.testing.allocator, resizeCommand(entity, randomStaticSize(random))),
                2 => try commands.append(std.testing.allocator, .{ .set_world_level = .{ .entity = entity, .level = random.uintLessThan(u16, 3) } }),
                3 => try commands.append(std.testing.allocator, .{ .destroy_entity = entity }),
                else => {},
            };
        }
        for (0..30) |_| try commands.append(std.testing.allocator, .{ .create_entity = staticTemplateOn(randomStaticPosition(random), randomStaticSize(random), random.uintLessThan(u16, 3)) });
        try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, commands.items);
        live.clearRetainingCapacity();
        for (fixture.data.movementBodySliceConst().entities) |entity| try live.append(std.testing.allocator, entity);
        var rebuilt = try fixture.rebuilt();
        defer rebuilt.deinit();
        try expectSameRows(&fixture.colliders, &rebuilt, 3);
    }
    // Fine and coarse classes both hold rows, the top class included.
    const mask = fixture.colliders.query_class_mask;
    for (0..4) |class| try std.testing.expect(mask.isSet(class));
    try std.testing.expect(mask.isSet(fixture.colliders.query_top_class));
}

const BruteHit = struct { order: [5]u64, entity: u32, aabb: math.Aabb };

fn bruteHitLessThan(_: void, a: BruteHit, b: BruteHit) bool {
    for (a.order, b.order) |order_a, order_b| {
        if (order_a != order_b) return order_a < order_b;
    }
    return a.entity < b.entity;
}

// The rows on `level` meeting the closed `box`, in query order: class descending; for
// classes no larger than a chunk, the anchor chunk (y, x); the anchor cell (y, x); entity
// index.
fn bruteForceHits(colliders: *const StaticColliderSystem, level: u16, box: math.Aabb, out: *std.ArrayList(BruteHit)) !void {
    out.clearRetainingCapacity();
    const geometry = colliders.geometry.?;
    const shift = geometry.grid.shift;
    for (colliders.row_of_index.items) |row| {
        if (row == no_row or colliders.row_level[row] != level) continue;
        const aabb = colliders.rowAabb(row);
        if (!(aabb.min_x <= box.max_x and aabb.max_x >= box.min_x and aabb.min_y <= box.max_y and aabb.max_y >= box.min_y)) continue;
        const class = geometry.queryClass(colliders.query_top_class, aabb);
        const cells = colliders.rowPlacement(row).cells;
        const cell_x = @as(u64, cells.min_x) >> class;
        const cell_y = @as(u64, cells.min_y) >> class;
        const fine = class <= shift;
        const chunk_x = if (fine) cell_x >> (shift - class) else 0;
        const chunk_y = if (fine) cell_y >> (shift - class) else 0;
        const descending_class = max_query_classes - 1 - class;
        try out.append(std.testing.allocator, .{ .order = .{ descending_class, chunk_y, chunk_x, cell_y, cell_x }, .entity = colliders.row_entity[row].index, .aabb = aabb });
    }
    std.sort.pdq(BruteHit, out.items, {}, bruteHitLessThan);
}

// Hit columns for up to `capacity` hits.
const TestHits = struct {
    min_x: []f32,
    min_y: []f32,
    max_x: []f32,
    max_y: []f32,

    fn init(capacity: usize) !TestHits {
        const columns = try std.testing.allocator.alloc(f32, 4 * capacity);
        return .{ .min_x = columns[0..capacity], .min_y = columns[capacity .. 2 * capacity], .max_x = columns[2 * capacity .. 3 * capacity], .max_y = columns[3 * capacity ..] };
    }

    fn deinit(self: TestHits) void {
        std.testing.allocator.free(self.min_x.ptr[0 .. 4 * self.min_x.len]);
    }

    fn hits(self: TestHits) BoxHits {
        return .{ .min_x = self.min_x, .min_y = self.min_y, .max_x = self.max_x, .max_y = self.max_y };
    }

    fn at(self: TestHits, index: usize) math.Aabb {
        return .{ .min_x = self.min_x[index], .min_y = self.min_y[index], .max_x = self.max_x[index], .max_y = self.max_y[index] };
    }
};

const unlimited_work: u16 = std.math.maxInt(u16);

// queryBox over `box` with no binding limit equals the brute force: the hit set, once
// each, in query order.
fn expectQueryMatchesBruteForce(colliders: *const StaticColliderSystem, level: u16, box: math.Aabb, expected: *std.ArrayList(BruteHit), hits: TestHits) !void {
    try bruteForceHits(colliders, level, box, expected);
    const max_hits: u16 = @intCast(hits.min_x.len);
    try std.testing.expect(expected.items.len < max_hits);
    const counts = colliders.view().queryBox(level, box, .{ .max_hits = max_hits, .max_work = unlimited_work }, hits.hits());
    try std.testing.expect(counts.work < unlimited_work);
    try std.testing.expectEqual(expected.items.len, counts.hits);
    for (expected.items, 0..) |hit, index| try std.testing.expectEqual(hit.aabb, hits.at(index));
}

// Boxes around every row (touching each edge from outside), random boxes, and boxes
// outside the level and negative.
fn queryTestBoxes(colliders: *const StaticColliderSystem, random: std.Random, out: *std.ArrayList(math.Aabb)) !void {
    out.clearRetainingCapacity();
    for (colliders.row_of_index.items) |row| {
        if (row == no_row) continue;
        const aabb = colliders.rowAabb(row);
        if (!std.math.isFinite(aabb.max_x) or !std.math.isFinite(aabb.max_y)) continue;
        try out.append(std.testing.allocator, .{ .min_x = aabb.max_x, .min_y = aabb.max_y, .max_x = aabb.max_x + 5, .max_y = aabb.max_y + 5 });
        try out.append(std.testing.allocator, .{ .min_x = aabb.min_x - 5, .min_y = aabb.min_y - 5, .max_x = aabb.min_x, .max_y = aabb.min_y });
        try out.append(std.testing.allocator, .{ .min_x = aabb.max_x, .min_y = aabb.min_y, .max_x = aabb.max_x + 40, .max_y = aabb.min_y + 1 });
        try out.append(std.testing.allocator, .{ .min_x = aabb.min_x + 1, .min_y = aabb.max_y, .max_x = aabb.min_x + 2, .max_y = aabb.max_y + 70 });
    }
    for (0..60) |_| {
        const center = randomStaticPosition(random);
        const half = math.Vec2{ .x = random.float(f32) * 120, .y = random.float(f32) * 120 };
        try out.append(std.testing.allocator, .{ .min_x = center.x - half.x, .min_y = center.y - half.y, .max_x = center.x + half.x, .max_y = center.y + half.y });
    }
    try out.append(std.testing.allocator, .{ .min_x = 3000, .min_y = 3000, .max_x = 3100, .max_y = 3100 });
    try out.append(std.testing.allocator, .{ .min_x = -900, .min_y = -900, .max_x = -800, .max_y = -10 });
    try out.append(std.testing.allocator, .{ .min_x = -100, .min_y = -100, .max_x = 2e38, .max_y = 2e38 });
}

// Rows of every kind the reach test covers, as creates on `levels` levels: class-edge
// extents and just over each edge, a zero extent, an infinite extent, larger than the
// level, negative and outside the level, a row covering a chunk it is not anchored in, and
// random rows.
fn queryReachStatics(random: std.Random, levels: u16, commands: *std.ArrayList(StructuralCommand)) !void {
    commands.clearRetainingCapacity();
    const placed = [_][4]f32{
        .{ 100.5, 37.25, 32, 32 },
        .{ 300.25, 90.5, 64, 64 },
        .{ 610.75, 400.5, 128, 128 },
        .{ 200.5, 700.25, 256, 256 },
        .{ 50.5, 900.5, 32.01, 32.01 },
        .{ 400.5, 950.5, 64.01, 64.01 },
        .{ 800.5, 1000.5, 128.01, 128.01 },
        .{ 1500, 1500, 0.00001, 0.00001 },
        .{ 1e38, 1e38, 3e38, 3e38 },
        .{ 10, 10, 3000, 3000 },
        .{ -300, -300, 40, 40 },
        .{ 2200, 1900, 50, 50 },
        // Anchored in chunk 0, covering chunk 1 too.
        .{ 100, 10, 100, 20 },
    };
    for (placed) |rect| try commands.append(std.testing.allocator, .{ .create_entity = staticTemplate(.{ .x = rect[0], .y = rect[1] }, .{ .x = rect[2], .y = rect[3] }) });
    for (0..80) |_| {
        const size = math.Vec2{ .x = 0.001 + random.float(f32) * 300, .y = 0.001 + random.float(f32) * 300 };
        try commands.append(std.testing.allocator, .{ .create_entity = staticTemplateOn(randomStaticPosition(random), size, random.uintLessThan(u16, levels)) });
    }
}

test "queryBox reaches every row whose AABB meets the box, once, in query order" {
    var prng = std.Random.DefaultPrng.init(0xb0c5);
    const random = prng.random();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    var boxes: std.ArrayList(math.Aabb) = .empty;
    defer boxes.deinit(std.testing.allocator);
    var expected: std.ArrayList(BruteHit) = .empty;
    defer expected.deinit(std.testing.allocator);
    const hits = try TestHits.init(256);
    defer hits.deinit();
    // The test grid, and a level narrower than a chunk (its top class is no larger than a
    // chunk).
    const narrow = ColliderGeometry.init(32, 3, 2, 4);
    try std.testing.expect(narrow.topQueryClass() <= narrow.grid.shift);
    for ([_]ColliderGeometry{ test_geometry, narrow }) |geometry| {
        var fixture = try SeamFixture.initWith(geometry);
        defer fixture.deinit();
        try queryReachStatics(random, 2, &commands);
        try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, commands.items);
        var rebuilt = try fixture.rebuilt();
        defer rebuilt.deinit();
        try expectSameRows(&fixture.colliders, &rebuilt, 2);
        // Fine classes 0..2 and a coarse class hold rows on the test grid.
        if (geometry.grid.width == test_geometry.grid.width) for (0..4) |class| try std.testing.expect(fixture.colliders.query_class_mask.isSet(class));
        try queryTestBoxes(&fixture.colliders, random, &boxes);
        for (boxes.items) |box| for (0..2) |level| {
            try expectQueryMatchesBruteForce(&fixture.colliders, @intCast(level), box, &expected, hits);
            try expectQueryMatchesBruteForce(&rebuilt, @intCast(level), box, &expected, hits);
        };
    }
}

test "queryBox stops at the hit cap and the work budget, as a prefix of the unlimited walk" {
    var prng = std.Random.DefaultPrng.init(0x9f1e);
    const random = prng.random();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try queryReachStatics(random, 1, &commands);
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, commands.items);
    const view = fixture.colliders.view();
    const capacity = 256;
    const full = try TestHits.init(capacity);
    defer full.deinit();
    const partial = try TestHits.init(capacity);
    defer partial.deinit();
    var first_work: std.ArrayList(u16) = .empty;
    defer first_work.deinit(std.testing.allocator);
    const boxes = [_]math.Aabb{
        .{ .min_x = 0, .min_y = 0, .max_x = 900, .max_y = 900 },
        .{ .min_x = 90, .min_y = 0, .max_x = 400, .max_y = 200 },
        .{ .min_x = 140, .min_y = 10, .max_x = 150, .max_y = 20 },
    };
    var expected: std.ArrayList(BruteHit) = .empty;
    defer expected.deinit(std.testing.allocator);
    for (boxes) |box| {
        // The unlimited walk is in the brute force's order, so every stopped walk below is a
        // prefix of it: larger classes kept, smaller dropped.
        try expectQueryMatchesBruteForce(&fixture.colliders, 0, box, &expected, full);
        const all = view.queryBox(0, box, .{ .max_hits = capacity, .max_work = unlimited_work }, full.hits());
        try std.testing.expect(all.hits > 1 and all.hits < capacity and all.work < unlimited_work);
        // Every work budget: exactly that many steps, and a prefix of the hits.
        first_work.clearRetainingCapacity();
        try first_work.append(std.testing.allocator, 0);
        var previous_hits: u16 = 0;
        for (0..all.work + 1) |budget| {
            const counts = view.queryBox(0, box, .{ .max_hits = capacity, .max_work = @intCast(budget) }, partial.hits());
            try std.testing.expectEqual(@as(u16, @intCast(budget)), counts.work);
            try std.testing.expect(counts.hits >= previous_hits);
            for (previous_hits..counts.hits) |_| try first_work.append(std.testing.allocator, @intCast(budget));
            previous_hits = counts.hits;
            for (0..counts.hits) |index| try std.testing.expectEqual(full.at(index), partial.at(index));
        }
        try std.testing.expectEqual(all.hits, previous_hits);
        // Every hit cap: exactly that many hits, stopping at the step that wrote the last.
        for (0..all.hits + 1) |cap| {
            const counts = view.queryBox(0, box, .{ .max_hits = @intCast(cap), .max_work = unlimited_work }, partial.hits());
            try std.testing.expectEqual(@as(u16, @intCast(cap)), counts.hits);
            if (cap < all.hits) try std.testing.expectEqual(first_work.items[cap], counts.work);
            for (0..counts.hits) |index| try std.testing.expectEqual(full.at(index), partial.at(index));
        }
    }
}

test "with the work budget exhausted, a large static is still hit before small ones" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    // A 512-unit wall (a class larger than a chunk) across the box, then a small static in
    // each of the box's 8 x 8 cells (class 0).
    try commands.append(std.testing.allocator, .{ .create_entity = staticTemplate(.{ .x = 128, .y = 128 }, .{ .x = 512, .y = 16 }) });
    for (0..8) |cell_y| for (0..8) |cell_x| {
        const center = math.Vec2{ .x = @floatFromInt(16 + 32 * cell_x), .y = @floatFromInt(16 + 32 * cell_y) };
        try commands.append(std.testing.allocator, .{ .create_entity = staticTemplate(center, .{ .x = 8, .y = 8 }) });
    };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, commands.items);
    try std.testing.expect(fixture.colliders.query_class_mask.isSet(0));
    try std.testing.expect(fixture.colliders.query_class_mask.findLastSet().? > test_geometry.grid.shift);
    const view = fixture.colliders.view();
    const box = math.Aabb{ .min_x = 0, .min_y = 0, .max_x = 255, .max_y = 255 };
    const capacity = 128;
    const hits = try TestHits.init(capacity);
    defer hits.deinit();
    const all = view.queryBox(0, box, .{ .max_hits = capacity, .max_work = unlimited_work }, hits.hits());
    try std.testing.expectEqual(@as(u16, 65), all.hits);
    var wall: ?math.Aabb = null;
    for (0..all.hits) |index| {
        const hit = hits.at(index);
        if (hit.max_x - hit.min_x != 512) continue;
        try std.testing.expect(wall == null);
        wall = hit;
    }

    // A budget far short of the walk over the small statics' cells, and a one-hit cap: each
    // stopped walk still hits the wall first.
    const budget: u16 = 8;
    try std.testing.expect(8 * budget < all.work);
    const short = view.queryBox(0, box, .{ .max_hits = capacity, .max_work = budget }, hits.hits());
    try std.testing.expectEqual(budget, short.work);
    try std.testing.expect(short.hits >= 1 and short.hits < all.hits);
    try std.testing.expectEqual(wall.?, hits.at(0));
    const capped = view.queryBox(0, box, .{ .max_hits = 1, .max_work = unlimited_work }, hits.hits());
    try std.testing.expectEqual(@as(u16, 1), capped.hits);
    try std.testing.expectEqual(wall.?, hits.at(0));
}

test "a row whose extent equals its class edge is reached from a box touching its max edge" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var prng = std.Random.DefaultPrng.init(0xed6e);
    const random = prng.random();
    var commands: [24]StructuralCommand = undefined;
    // Class edges 32, 64, 128 (no larger than a chunk) and 256, at fractional positions.
    for (&commands, 0..) |*command, at| {
        const edge: f32 = @as(f32, 32) * @as(f32, @floatFromInt(@as(u32, 1) << @intCast(at % 4)));
        const position = math.Vec2{ .x = 100 + @as(f32, @floatFromInt(at)) * 70 + random.float(f32), .y = 60 + @as(f32, @floatFromInt(at)) * 75 + random.float(f32) };
        command.* = .{ .create_entity = staticTemplate(position, .{ .x = edge, .y = edge }) };
    }
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &commands);
    const hits = try TestHits.init(32);
    defer hits.deinit();
    const view = fixture.colliders.view();
    for (fixture.colliders.changesThisStep()) |change| {
        const row = fixture.colliders.row_of_index.items[change.entity.index];
        const aabb = fixture.colliders.rowAabb(row);
        const touching = [_]math.Aabb{
            .{ .min_x = aabb.max_x, .min_y = aabb.max_y, .max_x = aabb.max_x + 1, .max_y = aabb.max_y + 1 },
            .{ .min_x = aabb.max_x, .min_y = aabb.min_y, .max_x = aabb.max_x, .max_y = aabb.min_y },
            .{ .min_x = aabb.min_x, .min_y = aabb.max_y, .max_x = aabb.min_x, .max_y = aabb.max_y + 3 },
        };
        for (touching) |box| {
            const counts = view.queryBox(0, box, .{ .max_hits = 32, .max_work = unlimited_work }, hits.hits());
            var found = false;
            for (0..counts.hits) |index| found = found or std.meta.eql(hits.at(index), aabb);
            try std.testing.expect(found);
        }
    }
}

test "a move across a tile inside its chunks touches only the query tier" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    // A one-tile static in chunk 0, moved one tile over inside the chunk, then inside its
    // tile.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    const entity = fixture.colliders.changesThisStep()[0].entity;
    const block = fixture.colliders.chunk_lists.value(chunkKey(0, 0));
    try std.testing.expect(block != no_value);
    const heads_before = fixture.colliders.chunk_lists.head(chunkKey(0, 0));
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{moveCommand(entity, .{ .x = 72, .y = 40 })});
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.last_splice_batch.item_count);
    try std.testing.expectEqual(@as(usize, 1), fixture.colliders.last_query_splice_batch.item_count);
    try std.testing.expectEqual(heads_before, fixture.colliders.chunk_lists.head(chunkKey(0, 0)));
    // The chunk keeps its block, the bit moved one cell over.
    try std.testing.expectEqual(block, fixture.colliders.chunk_lists.value(chunkKey(0, 0)));
    try std.testing.expectEqual(@as(u16, 1), fixture.colliders.anchor_blocks.items[block].set_bits);
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{moveCommand(entity, .{ .x = 73, .y = 41 })});
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.last_splice_batch.item_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.last_query_splice_batch.item_count);
}

test "the class mask clears when its last row leaves the class" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{
        .{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 50, .y = 50 }) },
        .{ .create_entity = staticTemplate(.{ .x = 400, .y = 40 }, .{ .x = 50, .y = 50 }) },
        .{ .create_entity = staticTemplate(.{ .x = 800, .y = 40 }, .{ .x = 8, .y = 8 }) },
    });
    var statics: [3]EntityId = undefined;
    changedEntities(&fixture.colliders, &statics);
    const mask = &fixture.colliders.query_class_mask;
    try std.testing.expect(mask.isSet(0) and mask.isSet(1));
    try std.testing.expectEqual(@as(usize, 2), mask.count());
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .destroy_entity = statics[0] }});
    try std.testing.expect(mask.isSet(1));
    // The last class-1 row shrinks into class 0.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{resizeCommand(statics[1], .{ .x = 10, .y = 10 })});
    try std.testing.expect(!mask.isSet(1) and mask.isSet(0));
    try std.testing.expectEqual(@as(u32, 0), fixture.colliders.query_class_rows[1]);
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{ .{ .destroy_entity = statics[1] }, .{ .destroy_entity = statics[2] } });
    try std.testing.expectEqual(@as(usize, 0), mask.count());
}

// One random churn commit over `live`: moves within a tile, across tiles of a chunk,
// across chunks, and across levels; resizes across the fine/coarse classes; destroys; and
// creates.
fn anchorChurnCommands(random: std.Random, data: *const DataSystem, live: []const EntityId, commands: *std.ArrayList(StructuralCommand)) !void {
    commands.clearRetainingCapacity();
    for (live) |entity| {
        const body = data.movementBodyConst(entity).?;
        switch (random.uintLessThan(u8, 8)) {
            0 => try commands.append(std.testing.allocator, moveCommand(entity, .{ .x = body.position.x + 0.5, .y = body.position.y })),
            1 => try commands.append(std.testing.allocator, moveCommand(entity, .{ .x = body.position.x + 32, .y = body.position.y })),
            2 => try commands.append(std.testing.allocator, moveCommand(entity, .{ .x = random.float(f32) * 600, .y = random.float(f32) * 600 })),
            3 => try commands.append(std.testing.allocator, .{ .set_world_level = .{ .entity = entity, .level = random.uintLessThan(u16, 3) } }),
            4 => {
                const edge: f32 = if (random.boolean()) 4 + random.float(f32) * 120 else 130 + random.float(f32) * 400;
                try commands.append(std.testing.allocator, resizeCommand(entity, .{ .x = edge, .y = edge }));
            },
            5 => try commands.append(std.testing.allocator, .{ .destroy_entity = entity }),
            else => {},
        }
    }
    for (0..random.uintLessThan(usize, 12)) |_| {
        const size = math.Vec2{ .x = 4 + random.float(f32) * 140, .y = 4 + random.float(f32) * 140 };
        try commands.append(std.testing.allocator, .{ .create_entity = staticTemplate(.{ .x = random.float(f32) * 600, .y = random.float(f32) * 600 }, size) });
    }
}

test "anchor blocks equal a rebuild after random incremental syncs, serial and threaded" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    var serial = try SeamFixture.init();
    defer serial.deinit();
    var threaded = try SeamFixture.init();
    defer threaded.deinit();
    threaded.colliders.splice_controls = .{ .adaptive = false, .items_per_range = 8 };
    const Step = struct {
        fn run(a: *SeamFixture, b: *SeamFixture, thread_system: *ThreadSystem, commands: []const StructuralCommand) !void {
            try commitForTest(&a.frame, &a.data, &a.colliders, commands);
            try commitForTestWith(&b.frame, &b.data, &b.colliders, commands, thread_system);
            try expectIdenticalLayout(&a.colliders, &b.colliders, 3);
            var rebuilt = try a.rebuilt();
            defer rebuilt.deinit();
            try expectSameRows(&a.colliders, &rebuilt, 3);
        }
    };
    // a and c share tile (1, 1), b sits at (2, 1), all in chunk 0; d is alone in chunk
    // (2, 2); e is coarse.
    try Step.run(&serial, &threaded, &threads, &.{
        .{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) },
        .{ .create_entity = staticTemplate(.{ .x = 72, .y = 40 }, .{ .x = 8, .y = 8 }) },
        .{ .create_entity = staticTemplate(.{ .x = 44, .y = 44 }, .{ .x = 8, .y = 8 }) },
        .{ .create_entity = staticTemplate(.{ .x = 300, .y = 300 }, .{ .x = 8, .y = 8 }) },
        .{ .create_entity = staticTemplate(.{ .x = 600, .y = 600 }, .{ .x = 300, .y = 300 }) },
    });
    var named: [5]EntityId = undefined;
    changedEntities(&serial.colliders, &named);
    const a, const b, const c, const d, const e = named;
    // Two rows leave tile (1, 1) in one sync.
    try Step.run(&serial, &threaded, &threads, &.{ moveCommand(a, .{ .x = 200, .y = 40 }), moveCommand(c, .{ .x = 520, .y = 40 }) });
    // a leaves tile (6, 1) and b enters it in one sync.
    try Step.run(&serial, &threaded, &threads, &.{ moveCommand(a, .{ .x = 230, .y = 100 }), moveCommand(b, .{ .x = 200, .y = 40 }) });
    // d's chunk empties: its block is released and its value cleared.
    const d_chunk = chunkKey(0, 2 * test_geometry.grid.chunks_x + 2);
    try std.testing.expect(serial.colliders.chunk_lists.value(d_chunk) != no_value);
    try Step.run(&serial, &threaded, &threads, &.{.{ .set_world_level = .{ .entity = d, .level = 2 } }});
    try std.testing.expectEqual(no_value, serial.colliders.chunk_lists.value(d_chunk));
    try std.testing.expectEqual(no_entry, serial.colliders.chunk_lists.head(d_chunk));
    // b grows coarse and e shrinks fine; then a moves inside its tile.
    try Step.run(&serial, &threaded, &threads, &.{ resizeCommand(b, .{ .x = 300, .y = 300 }), resizeCommand(e, .{ .x = 8, .y = 8 }) });
    try Step.run(&serial, &threaded, &threads, &.{moveCommand(a, .{ .x = 231, .y = 101 })});

    var prng = std.Random.DefaultPrng.init(0xa9c4);
    const random = prng.random();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    var live: std.ArrayList(EntityId) = .empty;
    defer live.deinit(std.testing.allocator);
    for (0..40) |_| try commands.append(std.testing.allocator, .{ .create_entity = staticTemplate(.{ .x = random.float(f32) * 600, .y = random.float(f32) * 600 }, .{ .x = 4 + random.float(f32) * 140, .y = 4 + random.float(f32) * 140 }) });
    try Step.run(&serial, &threaded, &threads, commands.items);
    for (0..12) |_| {
        live.clearRetainingCapacity();
        for (serial.data.movementBodySliceConst().entities) |entity| try live.append(std.testing.allocator, entity);
        try anchorChurnCommands(random, &serial.data, live.items, &commands);
        try Step.run(&serial, &threaded, &threads, commands.items);
    }
    try std.testing.expect(serial.colliders.anchor_blocks.items.len != 0);
}

test "a chunk's anchor block is released when its last anchor leaves and reused by the next" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    const entity = fixture.colliders.changesThisStep()[0].entity;
    // The first move claims a second block before the old one is released.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{moveCommand(entity, .{ .x = 168, .y = 40 })});
    const pooled = fixture.colliders.anchor_blocks.items.len;
    const grows = fixture.colliders.anchor_grows;
    try std.testing.expectEqual(@as(usize, 2), pooled);
    var from_chunk: u32 = 1;
    for (0..8) |step| {
        const to_chunk: u32 = if (step % 2 == 0) 2 else 1;
        const freed = fixture.colliders.anchor_free.items[0];
        try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{moveCommand(entity, .{ .x = @as(f32, @floatFromInt(to_chunk)) * 128 + 40, .y = 40 })});
        // The emptied chunk lost its value and key; the new chunk took the free block.
        try std.testing.expectEqual(no_value, fixture.colliders.chunk_lists.value(chunkKey(0, from_chunk)));
        try std.testing.expectEqual(no_entry, fixture.colliders.chunk_lists.head(chunkKey(0, from_chunk)));
        try std.testing.expectEqual(freed, fixture.colliders.chunk_lists.value(chunkKey(0, to_chunk)));
        try std.testing.expectEqual(pooled, fixture.colliders.anchor_blocks.items.len);
        from_chunk = to_chunk;
    }
    try std.testing.expectEqual(grows, fixture.colliders.anchor_grows);
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
}

test "queryBox skips a covered chunk without anchors" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    // A class-2 row anchored in chunk 0 that also covers chunk 1.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 100, .y = 10 }, .{ .x = 100, .y = 20 }) }});
    const view = fixture.colliders.view();
    try std.testing.expect(view.chunkHasRows(0, 1));
    try std.testing.expectEqual(no_value, fixture.colliders.chunk_lists.value(chunkKey(0, 1)));
    const hits = try TestHits.init(4);
    defer hits.deinit();
    // The box lies in chunk 1; the class-2 walk visits chunks 0 and 1. Chunk 0: a visit,
    // its one cell, one entry; chunk 1: a visit only.
    const counts = view.queryBox(0, .{ .min_x = 140, .min_y = 10, .max_x = 150, .max_y = 20 }, .{ .max_hits = 4, .max_work = unlimited_work }, hits.hits());
    try std.testing.expectEqual(@as(u16, 1), counts.hits);
    try std.testing.expectEqual(@as(u16, 1), counts.entries);
    try std.testing.expectEqual(@as(u16, 4), counts.work);
}

test "a static whose clamped min corner sits in a level's last partial chunk is anchored and found by queryBox" {
    // 10 x 10 cells in 4-cell chunks: the last chunk column and row hold cells 8-9.
    const partial = ColliderGeometry.init(32, 10, 10, 4);
    try std.testing.expect(partial.grid.width % partial.grid.chunk_tiles != 0);
    var fixture = try SeamFixture.initWith(partial);
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{
        // In cell (9, 9), past the level (clamped to cell (9, 9)), and class 1 at (8, 8).
        .{ .create_entity = staticTemplate(.{ .x = 300, .y = 300 }, .{ .x = 8, .y = 8 }) },
        .{ .create_entity = staticTemplate(.{ .x = 500, .y = 700 }, .{ .x = 8, .y = 8 }) },
        .{ .create_entity = staticTemplate(.{ .x = 260, .y = 260 }, .{ .x = 50, .y = 50 }) },
    });
    const corner_chunk = chunkKey(0, 2 * partial.grid.chunks_x + 2);
    const block = fixture.colliders.chunk_lists.value(corner_chunk);
    try std.testing.expect(block != no_value);
    try std.testing.expectEqual(@as(u16, 2), fixture.colliders.anchor_blocks.items[block].set_bits);
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
    var expected: std.ArrayList(BruteHit) = .empty;
    defer expected.deinit(std.testing.allocator);
    const hits = try TestHits.init(8);
    defer hits.deinit();
    const boxes = [_]math.Aabb{
        .{ .min_x = 290, .min_y = 290, .max_x = 310, .max_y = 310 },
        .{ .min_x = 500, .min_y = 700, .max_x = 501, .max_y = 701 },
        .{ .min_x = 0, .min_y = 0, .max_x = 1000, .max_y = 1000 },
    };
    for (boxes) |box| {
        try expectQueryMatchesBruteForce(&fixture.colliders, 0, box, &expected, hits);
        try std.testing.expect(expected.items.len != 0);
        try expectQueryMatchesBruteForce(&rebuilt, 0, box, &expected, hits);
    }
}

test "an anchor-block reserve fails as OutOfMemory at 2^32 - 1 blocks before asking the allocator, and one block short of it reaches the allocator" {
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    colliders.allocator = failing.allocator();
    defer colliders.allocator = std.testing.allocator;
    // The pool reads `held` blocks with room for them all and no free id: the reserve reads
    // only its length and capacity, so no block memory backs the count. Restored before
    // deinit.
    var spare: [1]AnchorBlock = undefined;
    const real_blocks = colliders.anchor_blocks;
    defer colliders.anchor_blocks = real_blocks;
    for ([_]usize{ no_value - 1, no_value - 2 }) |held| {
        colliders.anchor_blocks.items = (&spare).ptr[0..held];
        colliders.anchor_blocks.capacity = no_value - 1;
        try std.testing.expectError(error.OutOfMemory, colliders.ensureFreeAnchorBlocks(1));
        try std.testing.expectEqual(held, colliders.anchor_blocks.items.len);
        try std.testing.expectEqual(@as(usize, 0), colliders.anchor_free.items.len);
        // At the limit nothing is asked of the allocator; one short, the free list's growth is.
        try std.testing.expectEqual(held == no_value - 2, failing.has_induced_failure);
    }
}
