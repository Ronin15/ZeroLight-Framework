// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared static-collider rows: one row per static navigation obstacle (an entity with a
//! movement body, collision bounds, and a static collision response), holding its
//! committed world AABB, its level, and the cell span it covers. Each chunk of a level
//! that has held a static owns one payload: nav span columns in entity-index order, and,
//! for classes no larger than a chunk, the query AABBs of statics anchored in that chunk.
//! Coarser classes keep one directory per class, a cell's float run in its slot. Anchor
//! words live on the chunk payload. Rows change only at the structural-commit seam: the
//! step's entity changes are captured into a persistent dirty list right after the commit
//! and applied by `sync` from the entities' final state, so each changed entity costs the
//! chunks and query cells it enters, leaves, or rewrites, never the static count. Readers
//! (nav, steering) take a `ColliderView`.

const std = @import("std");
const builtin = @import("builtin");
const runtime_perf_log = @import("../../app/runtime_perf_log.zig");
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const logging = @import("../../core/logging.zig");
const pdq = @import("../../core/sort.zig").pdq;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const rebuild_tuner_config = @import("../../app/thread_system.zig").rebuild_tuner_config;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const Dispatch = @import("../../app/thread_system.zig").Dispatch;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const StageControls = @import("../../app/thread_system.zig").StageControls;
const StageThreads = @import("../../app/thread_system.zig").StageThreads;
const runShaped = @import("../../app/thread_system.zig").runShaped;
const rangeCount = @import("../../app/thread_system.zig").rangeCount;
const StageShape = @import("../../app/thread_system.zig").StageShape;
const PaddedSlot = @import("../../app/thread_system.zig").PaddedSlot;
const SlotList = @import("../../app/thread_system.zig").SlotList;
const changedCapacities = @import("../../app/thread_system.zig").changedCapacities;
const setSlotCount = @import("../../app/thread_system.zig").setSlotCount;
const setRowCount = @import("../../app/thread_system.zig").setRowCount;
const compactRowWindows = @import("../../app/thread_system.zig").compactRowWindows;
const maxRangeCount = @import("../../app/thread_system.zig").maxRangeCount;
const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;
const banded_sort = @import("banded_sort.zig");
const band_count = banded_sort.band_count;
const BandOffsets = banded_sort.BandOffsets;
const OwnedBands = banded_sort.OwnedBands;
const StampedTable = @import("../stamped_table.zig").StampedTable;
const hashTableSlots = @import("../stamped_table.zig").hashTableSlots;
const hashTableShift = @import("../stamped_table.zig").hashTableShift;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const StaticObstacle = @import("../data_system/types.zig").StaticObstacle;
const StaticObstacleColumns = @import("../data_system/types.zig").StaticObstacleColumns;
const SimulationFrame = @import("../simulation.zig").SimulationFrame;
const ChunkDirectory = @import("chunk_list_map.zig").ChunkDirectory;
const chunkKey = @import("chunk_list_map.zig").chunkKey;
const keyChunk = @import("chunk_list_map.zig").keyChunk;
const keyLevel = @import("chunk_list_map.zig").keyLevel;
const empty_block = @import("chunk_list_map.zig").empty_block;
const max_payload_classes = @import("chunk_list_map.zig").max_payload_classes;
const PayloadSlabs = @import("chunk_list_map.zig").PayloadSlabs;
const PayloadSlot = @import("chunk_list_map.zig").PayloadSlot;
const OrdinalClaims = @import("chunk_list_map.zig").OrdinalClaims;
const splice_range_alignment_items = @import("chunk_list_map.zig").splice_range_alignment_items;
const max_chunk_size_tiles = @import("../world/system.zig").max_chunk_size_tiles;
const ChunkGeometry = @import("../world/terrain.zig").ChunkGeometry;

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
const anchor_block_words: usize = @divCeil(max_anchor_bits, 64);

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

    fn classCellsY(self: ColliderGeometry, class: u6) u64 {
        return (@as(u64, self.grid.height) + (@as(u64, 1) << class) - 1) >> class;
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

    // `queryClass` of the lanes below `count`, bit-identical lane for lane: each lane's
    // smallest class below `top` whose cell edge covers its AABB on both axes, else `top`.
    // Stops once every live lane has its class: at most `top + 1` iterations.
    fn queryClass4(self: ColliderGeometry, top: u6, min_x: simd.Float4, min_y: simd.Float4, max_x: simd.Float4, max_y: simd.Float4, count: usize) simd.Int4 {
        var classes = simd.splatInt4(top);
        var unresolved = simd.lanesBelow(count);
        var class: u6 = 0;
        while (class < top and unresolved != 0) : (class += 1) {
            const edge = simd.splatFloat4(self.classEdge(class));
            const covers = simd.lessEqualFloat4(max_x - edge, min_x) & simd.lessEqualFloat4(max_y - edge, min_y);
            const resolved = simd.maskBits(covers) & unresolved;
            classes = simd.selectInt4(@bitCast(resolved), simd.splatInt4(class), classes);
            unresolved &= ~resolved;
        }
        return classes;
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

// The inclusive chunk rectangle a placement covers on its level.
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

    fn eql(self: ChunkRect, other: ChunkRect) bool {
        return self.level == other.level and self.min_x == other.min_x and self.min_y == other.min_y and self.max_x == other.max_x and self.max_y == other.max_y;
    }
};

/// The query-tier key of class-`class` cell `cell` on `level`: the class in bits 48-53
/// over a `chunkKey`, tier bits 62-63 clear.
pub fn queryCellKey(level: u16, class: u6, cell: u32) u64 {
    return (@as(u64, class) << 48) | chunkKey(level, cell);
}

// Clears a query key's class bits, leaving its `chunkKey`.
const query_class_clear_mask: u64 = ~(@as(u64, 0x3f) << 48);

fn queryKeyLevel(key: u64) u16 {
    return keyLevel(key & query_class_clear_mask);
}

// A row's query class and query-tier key.
const QueryPlacement = struct { class: u6, key: u64 };

/// An inclusive cell rectangle.
pub const CellSpan = struct { min_x: u32, min_y: u32, max_x: u32, max_y: u32 };

/// Where a row sits: its level and the cells it covers.
pub const Placement = struct { level: u16, cells: CellSpan };

/// A row's placement before a sync, with its box: the box readers built keys and overlaps from.
pub const OldPlacement = struct { level: u16, cells: CellSpan, aabb: math.Aabb };

/// One entity's row change at the last sync: its placement before (null when it had no
/// row) and after (null when it has none now).
pub const ColliderChange = struct {
    entity: EntityId,
    old: ?OldPlacement,
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

/// One query cell's records inside a chunk: `bit` order, then entity index. `start` indexes
/// the chunk's query columns.
const QueryGroup = struct { bit: u16, start: u32, count: u32 };

/// Span columns and query columns of one chunk, plus the anchor words. Slices are the
/// columns of the payload slot `slot` holds; `nav_len` and `query_len` are the live
/// prefixes.
const StaticChunk = struct {
    slot: PayloadSlot = .none,
    nav_len: u32 = 0,
    nav_cap: u32 = 0,
    query_len: u32 = 0,
    query_cap: u32 = 0,
    group_len: u32 = 0,
    anchors: AnchorBlock = empty_anchor_block,
    nav_entity: []u32 = &.{},
    nav_min_x: []u32 = &.{},
    nav_min_y: []u32 = &.{},
    nav_max_x: []u32 = &.{},
    nav_max_y: []u32 = &.{},
    query_entity: []u32 = &.{},
    query_bit: []u16 = &.{},
    query_min_x: []f32 = &.{},
    query_min_y: []f32 = &.{},
    query_max_x: []f32 = &.{},
    query_max_y: []f32 = &.{},
    groups: []QueryGroup = &.{},
};

/// One coarse cell's query AABBs, entity-index order. Slices are the columns of the payload
/// slot `slot` holds; `len` is the live prefix.
const QueryRun = struct {
    slot: PayloadSlot = .none,
    len: u32 = 0,
    cap: u32 = 0,
    entity: []u32 = &.{},
    min_x: []f32 = &.{},
    min_y: []f32 = &.{},
    max_x: []f32 = &.{},
    max_y: []f32 = &.{},
};

const ChunkDir = ChunkDirectory(StaticChunk, false);
const CoarseDir = ChunkDirectory(QueryRun, false);

// The old columns of a chunk or cell that held no block.
const empty_chunk = StaticChunk{};
const empty_run = QueryRun{};

/// The stages `rebuild` and `sync` dispatch, each with its last batch shape: a rebuild runs
/// every one but `apply`, a sync every one but `select`.
pub const ColliderStage = enum { select, plan, touch, group, apply, rewrite, install };

/// The stages `rebuild` runs, each under its own tuner.
pub const RebuildStage = enum { select, plan, touch, group, rewrite, install };

/// The stages `sync` runs, each under its own tuner, separate from the rebuild's.
pub const SyncStage = enum { plan, touch, group, apply, rewrite, install };

// A rebuild's or sync's thread system and the shared range controls; each stage dispatches
// under its own tuner.
const ColliderThreads = StageThreads(StageControls);

/// The nav spans listed on one chunk, entity-index order. Empty when the chunk has none.
pub const ChunkSpans = struct {
    entity: []const u32 = &.{},
    min_x: []const u32 = &.{},
    min_y: []const u32 = &.{},
    max_x: []const u32 = &.{},
    max_y: []const u32 = &.{},
};

/// Read-only chunk runs for readers between seams, safe for concurrent reads: nothing here
/// mutates. Valid until the next `sync` or `rebuild`.
pub const ColliderView = struct {
    /// Null for a system never rebuilt (it holds no rows).
    geometry: ?ColliderGeometry = null,
    chunks: ?*const ChunkDir = null,
    coarse: ?*const [max_query_classes]CoarseDir = null,
    query_class_mask: QueryClassMask = .empty,
    query_top_class: u6 = 0,
    /// Bumps when `rebuild` or a `sync` that applies changes installs rows.
    revision: u64 = 0,
    /// Entity index to row pool id, or `no_row`. Valid with the rest of the view.
    row_of_index: []const u32 = &.{},
    /// Row pool entity column. Valid with the rest of the view.
    row_entity: []const EntityId = &.{},
    /// Row-pool AABB written at sync. Query columns are a copy of this rect, not a second source.
    row_min_x: []const f32 = &.{},
    row_min_y: []const f32 = &.{},
    row_max_x: []const f32 = &.{},
    row_max_y: []const f32 = &.{},
    /// `changesThisStep` for this revision. Empty after a rebuild.
    changes: []const ColliderChange = &.{},

    /// Whether any span covers a cell of `chunk` on `level`. O(1).
    pub fn chunkHasRows(self: ColliderView, level: u16, chunk: u32) bool {
        const payload = self.chunkPayload(level, chunk) orelse return false;
        return payload.nav_len != 0;
    }

    /// The spans covering a cell of `chunk` on `level`, in entity-index order.
    pub fn chunkRows(self: ColliderView, level: u16, chunk: u32) ChunkSpans {
        const payload = self.chunkPayload(level, chunk) orelse return .{};
        const count: usize = payload.nav_len;
        return .{
            .entity = payload.nav_entity[0..count],
            .min_x = payload.nav_min_x[0..count],
            .min_y = payload.nav_min_y[0..count],
            .max_x = payload.nav_max_x[0..count],
            .max_y = payload.nav_max_y[0..count],
        };
    }

    fn chunkPayload(self: ColliderView, level: u16, chunk: u32) ?*const StaticChunk {
        const chunks = self.chunks orelse return null;
        const block = chunks.slot(level, chunk);
        if (block == empty_block) return null;
        return chunks.payloadConst(block);
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
    // SIMD verdict: the anchor walk and the chunk search stay scalar. The row
    // overlap test is the masked compare. The compact stays scalar because the
    // stop depends on the mask.
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
        walk.walkClasses();
        return walk.counts;
    }

    /// Every indexed row on `level` meeting the closed `box`, each once, in `queryBox` order.
    /// Writes `min(hits, out_entity.len)` and returns the full hit count. No hit cap. The
    /// out slices share one length. Reads only. Debug `span_ids` records every row the walk
    /// reads; ReleaseFast has no recorder.
    pub fn collectOverlaps(
        self: ColliderView,
        level: u16,
        box: math.Aabb,
        out_entity: []u32,
        out_min_x: []f32,
        out_min_y: []f32,
        out_max_x: []f32,
        out_max_y: []f32,
        span_ids: if (builtin.mode == .debug) ?*SpanIds else void,
    ) usize {
        std.debug.assert(out_min_x.len == out_entity.len and out_min_y.len == out_entity.len);
        std.debug.assert(out_max_x.len == out_entity.len and out_max_y.len == out_entity.len);
        const geometry = self.geometry orelse return 0;
        var overlaps = OverlapWrite{
            .entity = out_entity,
            .min_x = out_min_x,
            .min_y = out_min_y,
            .max_x = out_max_x,
            .max_y = out_max_y,
        };
        var unused: [0]f32 = .{};
        var walk = BoxWalk{
            .view = &self,
            .geometry = geometry,
            .level = level,
            .box = box,
            .uncapped = true,
            .overlaps = &overlaps,
            .hits = .{ .min_x = &unused, .min_y = &unused, .max_x = &unused, .max_y = &unused },
        };
        if (comptime builtin.mode == .debug) walk.span_ids = span_ids;
        walk.walkClasses();
        return overlaps.hits;
    }
};

/// No span recorder. ReleaseFast `collectOverlaps` takes no recorder argument.
pub fn idleSpanIds() if (builtin.mode == .debug) ?*SpanIds else void {
    if (comptime builtin.mode == .debug) return null;
    return {};
}

/// Debug id sink for one range's uncapped walks. A span is appended whole or not at all.
pub const SpanIds = struct {
    ids: *std.ArrayList(u32),
    /// Ids the range's walks have read, skipped spans included; equals `ids.items.len`
    /// until a span does not fit. Growing `ids` to it holds the range on its replay.
    required: *usize,
};

const OverlapWrite = struct {
    entity: []u32,
    min_x: []f32,
    min_y: []f32,
    max_x: []f32,
    max_y: []f32,
    hits: usize = 0,
};

// The inclusive class-`class` cells one fine-class chunk visit walks.
const ClassCells = struct { class: u6, cells_x: u64, min_x: u64, min_y: u64, max_x: u64, max_y: u64 };

// One `queryBox` walk in progress. Every step method returns false once the walk stops.
const BoxWalk = struct {
    view: *const ColliderView,
    geometry: ColliderGeometry,
    level: u16,
    box: math.Aabb,
    limits: BoxQueryLimits = .{ .max_hits = 0, .max_work = 0 },
    hits: BoxHits,
    counts: BoxQueryCounts = .{},
    uncapped: bool = false,
    overlaps: ?*OverlapWrite = null,
    span_ids: ?*SpanIds = null,

    fn canStep(self: *const BoxWalk) bool {
        if (self.uncapped) return true;
        return self.counts.work < self.limits.max_work and self.counts.hits < self.limits.max_hits;
    }

    fn walkClasses(self: *BoxWalk) void {
        var classes = self.view.query_class_mask.iterator(.{ .direction = .reverse });
        while (classes.next()) |class| {
            std.debug.assert(class <= self.view.query_top_class);
            if (!self.walkClass(@intCast(class))) break;
        }
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
        // A class cell lies in one chunk. The chunk's anchor words mark the class cells
        // that hold a query record; a chunk with none set holds none.
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
                const payload = self.view.chunkPayload(self.level, chunk) orelse continue;
                if (payload.anchors.set_bits == 0) continue;
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
                if (!self.walkAnchoredCells(cells, payload, class_offset, per_chunk_shift)) return false;
            }
        }
        return true;
    }

    // Steps each cell of `cells` (inside one chunk). A clear anchor bit skips. A set bit
    // scans that bit's query columns. One binary search per chunk visit finds the first
    // group at or after the walk's first cell; the cursor then only moves forward. The
    // search is not a work step.
    fn walkAnchoredCells(self: *BoxWalk, cells: ClassCells, payload: *const StaticChunk, class_offset: usize, per_chunk_shift: u6) bool {
        const cell_mask = (@as(u64, 1) << per_chunk_shift) - 1;
        const words = &payload.anchors.words;
        const groups = payload.groups[0..payload.group_len];
        const first_bit: u16 = @intCast(class_offset + @as(usize, @intCast((cells.min_y & cell_mask) << per_chunk_shift)) + @as(usize, @intCast(cells.min_x & cell_mask)));
        var cursor = std.sort.lowerBound(QueryGroup, groups, first_bit, orderGroupBit);
        var cell_y = cells.min_y;
        while (cell_y <= cells.max_y) : (cell_y += 1) {
            const row_bit = class_offset + @as(usize, @intCast((cell_y & cell_mask) << per_chunk_shift));
            var cell_x = cells.min_x;
            while (cell_x <= cells.max_x) : (cell_x += 1) {
                if (!self.canStep()) return false;
                self.counts.work += 1;
                const bit = row_bit + @as(usize, @intCast(cell_x & cell_mask));
                if ((words[bit >> 6] >> @intCast(bit & 63)) & 1 == 0) continue;
                const bit_id: u16 = @intCast(bit);
                while (cursor < groups.len and groups[cursor].bit < bit_id) cursor += 1;
                std.debug.assert(cursor < groups.len and groups[cursor].bit == bit_id);
                if (self.uncapped) {
                    const row_last: u16 = @intCast(row_bit + @as(usize, @intCast(cells.max_x & cell_mask)));
                    var end_cursor = cursor;
                    while (end_cursor + 1 < groups.len and groups[end_cursor + 1].bit <= row_last and groups[end_cursor + 1].start == groups[end_cursor].start + groups[end_cursor].count) {
                        end_cursor += 1;
                    }
                    const first = groups[cursor];
                    const last = groups[end_cursor];
                    const span: u32 = last.start + last.count - first.start;
                    if (!self.scanUncapped(payload.query_entity[first.start..], payload.query_min_x[first.start..], payload.query_min_y[first.start..], payload.query_max_x[first.start..], payload.query_max_y[first.start..], span)) return false;
                    const extra: u64 = groups[end_cursor].bit - bit_id;
                    self.counts.work += @intCast(extra);
                    cell_x += extra;
                    cursor = end_cursor + 1;
                    continue;
                }
                if (!self.scanQuery(payload, groups[cursor].start, groups[cursor].count)) return false;
                cursor += 1;
            }
        }
        return true;
    }

    fn walkCells(self: *BoxWalk, class: u6, cells_x: u64, min_x: u64, min_y: u64, max_x: u64, max_y: u64) bool {
        const coarse = self.view.coarse orelse return true;
        var cell_y = min_y;
        while (cell_y <= max_y) : (cell_y += 1) {
            var cell_x = min_x;
            while (cell_x <= max_x) : (cell_x += 1) {
                if (!self.canStep()) return false;
                self.counts.work += 1;
                // Class cell indices stay below the level's cell count, under 2^32.
                const cell: u32 = @intCast(cell_y * cells_x + cell_x);
                const block = coarse[class].slot(self.level, cell);
                if (block == empty_block) continue;
                if (!self.scanRun(coarse[class].payloadConst(block))) return false;
            }
        }
        return true;
    }

    fn scanQuery(self: *BoxWalk, payload: *const StaticChunk, start: u32, count: u32) bool {
        if (self.uncapped) return self.scanUncapped(payload.query_entity[start..], payload.query_min_x[start..], payload.query_min_y[start..], payload.query_max_x[start..], payload.query_max_y[start..], count);
        return self.scanCapped(payload.query_min_x[start..], payload.query_min_y[start..], payload.query_max_x[start..], payload.query_max_y[start..], count);
    }

    fn scanRun(self: *BoxWalk, run: *const QueryRun) bool {
        if (self.uncapped) return self.scanUncapped(run.entity, run.min_x, run.min_y, run.max_x, run.max_y, run.len);
        return self.scanCapped(run.min_x, run.min_y, run.max_x, run.max_y, run.len);
    }

    fn scanUncapped(self: *BoxWalk, entity: []const u32, min_x: []const f32, min_y: []const f32, max_x: []const f32, max_y: []const f32, count: u32) bool {
        if (count == 0) return true;
        if (!self.scanUncappedLanes(entity, min_x, min_y, max_x, max_y, count)) return false;
        self.recordSpan(entity, count);
        return true;
    }

    // Debug only: the span's entity indices, whole or not at all. A span past the list's
    // capacity is counted and skipped and the walk goes on, so one grow sizes the replay.
    // Not an overlap test.
    fn recordSpan(self: *BoxWalk, entity: []const u32, count: u32) void {
        if (comptime builtin.mode != .debug) return;
        const record = self.span_ids orelse return;
        const n: usize = count;
        std.debug.assert(record.required.* >= record.ids.items.len);
        const read = record.required.* + n;
        record.required.* = read;
        // `read` only grows, so once one span is skipped every later one is too.
        if (read > record.ids.capacity) return;
        const start = record.ids.items.len;
        record.ids.appendNTimesAssumeCapacity(0, n);
        @memcpy(record.ids.items[start..][0..n], entity[0..n]);
    }

    // The capped walk (`queryBox`). Same overlap kernel. The group stops at the work
    // budget, and a hit that fills the cap drops the later lanes.
    fn scanCapped(self: *BoxWalk, min_x: []const f32, min_y: []const f32, max_x: []const f32, max_y: []const f32, count: u32) bool {
        const bounds = splatBox(self.box);
        var index: usize = 0;
        const end: usize = count;
        while (index < end) {
            if (!self.canStep()) return false;
            const room: usize = self.limits.max_work - self.counts.work;
            if (room == 0) return false;
            const group = @min(simd.lane_count, end - index, room);
            const row_min_x = if (group == simd.lane_count) simd.loadFloat4(min_x[index..]) else simd.loadFloat4Prefix(min_x[index..], group);
            const row_min_y = if (group == simd.lane_count) simd.loadFloat4(min_y[index..]) else simd.loadFloat4Prefix(min_y[index..], group);
            const row_max_x = if (group == simd.lane_count) simd.loadFloat4(max_x[index..]) else simd.loadFloat4Prefix(max_x[index..], group);
            const row_max_y = if (group == simd.lane_count) simd.loadFloat4(max_y[index..]) else simd.loadFloat4Prefix(max_y[index..], group);
            const mask = overlapMaskLanes(row_min_x, row_min_y, row_max_x, row_max_y, bounds, group);
            for (0..group) |lane| {
                if (!self.canStep()) return false;
                self.counts.work += 1;
                self.counts.entries += 1;
                if (!laneSet(mask, lane)) continue;
                const row_min_x_lane = laneFloat(row_min_x, lane);
                const row_min_y_lane = laneFloat(row_min_y, lane);
                const row_max_x_lane = laneFloat(row_max_x, lane);
                const row_max_y_lane = laneFloat(row_max_y, lane);
                const at = self.counts.hits;
                self.hits.min_x[at] = row_min_x_lane;
                self.hits.min_y[at] = row_min_y_lane;
                self.hits.max_x[at] = row_max_x_lane;
                self.hits.max_y[at] = row_max_y_lane;
                self.counts.hits += 1;
            }
            index += group;
        }
        return true;
    }

    fn scanUncappedLanes(self: *BoxWalk, entity: []const u32, min_x: []const f32, min_y: []const f32, max_x: []const f32, max_y: []const f32, count: u32) bool {
        const over = self.overlaps.?;
        const bounds = splatBox(self.box);
        var index: usize = 0;
        const end: usize = count;
        while (index + simd.lane_count <= end) : (index += simd.lane_count) {
            const row_min_x = simd.loadFloat4(min_x[index..]);
            const row_min_y = simd.loadFloat4(min_y[index..]);
            const row_max_x = simd.loadFloat4(max_x[index..]);
            const row_max_y = simd.loadFloat4(max_y[index..]);
            const ids = simd.loadUint4(entity[index..]);
            const mask = overlapMaskLanes(row_min_x, row_min_y, row_max_x, row_max_y, bounds, simd.lane_count);
            if (mask == 0) continue;
            if (mask == simd.lanesBelow(simd.lane_count) and over.hits + simd.lane_count <= over.entity.len) {
                const at = over.hits;
                simd.storeUint4Slice(over.entity[at..], ids);
                simd.storeFloat4Slice(over.min_x[at..], row_min_x);
                simd.storeFloat4Slice(over.min_y[at..], row_min_y);
                simd.storeFloat4Slice(over.max_x[at..], row_max_x);
                simd.storeFloat4Slice(over.max_y[at..], row_max_y);
                over.hits += simd.lane_count;
            } else self.storeMaskedHits(over, ids, row_min_x, row_min_y, row_max_x, row_max_y, mask, simd.lane_count);
        }
        if (index == end) return true;
        const group = end - index;
        const row_min_x = simd.loadFloat4Prefix(min_x[index..], group);
        const row_min_y = simd.loadFloat4Prefix(min_y[index..], group);
        const row_max_x = simd.loadFloat4Prefix(max_x[index..], group);
        const row_max_y = simd.loadFloat4Prefix(max_y[index..], group);
        const ids = simd.loadUint4Prefix(entity[index..], group);
        const mask = overlapMaskLanes(row_min_x, row_min_y, row_max_x, row_max_y, bounds, group);
        if (mask != 0) self.storeMaskedHits(over, ids, row_min_x, row_min_y, row_max_x, row_max_y, mask, group);
        return true;
    }

    fn storeMaskedHits(self: *BoxWalk, over: *OverlapWrite, ids: simd.Uint4, row_min_x: simd.Float4, row_min_y: simd.Float4, row_max_x: simd.Float4, row_max_y: simd.Float4, mask: simd.MaskBits, count: usize) void {
        _ = self;
        const entity = simd.toUintArray(ids);
        const min_x = simd.toFloatArray(row_min_x);
        const min_y = simd.toFloatArray(row_min_y);
        const max_x = simd.toFloatArray(row_max_x);
        const max_y = simd.toFloatArray(row_max_y);
        for (0..count) |lane| {
            if (!laneSet(mask, lane)) continue;
            if (over.hits < over.entity.len) {
                const at = over.hits;
                over.entity[at] = entity[lane];
                over.min_x[at] = min_x[lane];
                over.min_y[at] = min_y[lane];
                over.max_x[at] = max_x[lane];
                over.max_y[at] = max_y[lane];
            }
            over.hits += 1;
        }
    }
};

fn laneFloat(vector: simd.Float4, lane: usize) f32 {
    return switch (lane) {
        0 => vector[0],
        1 => vector[1],
        2 => vector[2],
        else => vector[3],
    };
}

fn laneSet(mask: simd.MaskBits, lane: usize) bool {
    return mask & (@as(simd.MaskBits, 1) << @as(simd.LaneIndex, @intCast(lane))) != 0;
}

const BoxLanes = struct { max_x: simd.Float4, min_x: simd.Float4, max_y: simd.Float4, min_y: simd.Float4 };

fn splatBox(box: math.Aabb) BoxLanes {
    return .{
        .max_x = simd.splatFloat4(box.max_x),
        .min_x = simd.splatFloat4(box.min_x),
        .max_y = simd.splatFloat4(box.max_y),
        .min_y = simd.splatFloat4(box.min_y),
    };
}

fn overlapMaskLanes(row_min_x: simd.Float4, row_min_y: simd.Float4, row_max_x: simd.Float4, row_max_y: simd.Float4, box: BoxLanes, count: usize) simd.MaskBits {
    const inside = simd.lessEqualFloat4(row_min_x, box.max_x) &
        simd.greaterEqualFloat4(row_max_x, box.min_x) &
        simd.lessEqualFloat4(row_min_y, box.max_y) &
        simd.greaterEqualFloat4(row_max_y, box.min_y);
    return simd.maskBits(inside) & simd.lanesBelow(count);
}

fn orderGroupBit(bit: u16, group: QueryGroup) std.math.Order {
    return std.math.order(bit, group.bit);
}

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
    // Set for a dirty index whose runs must be rewritten. A chunk fill drops records whose
    // entity carries this generation and merges the planned inserts; an index whose bytes
    // did not change is left out, so another static rewriting the chunk keeps the record.
    relink_stamp: std.ArrayList(u32) = .empty,
    relink_generation: u32 = 1,
    changes: std.ArrayList(ColliderChange) = .empty,
    // Sync scratch, high-water, per pending index in order: its new row's AABB and cells
    // (the plan lanes' output; `plan_inputs` holds its inputs), and its plan.
    sync_rows: std.MultiArrayList(SyncRow) = .{},
    sync_plan: std.ArrayList(SyncPlan) = .empty,
    chunks: ChunkDir = .{},
    coarse: [max_query_classes]CoarseDir = @splat(.{}),
    // Chunk and coarse payload bytes, one slot per occupied block; freed slots pool for
    // reuse and the slabs go with the system.
    payloads: PayloadSlabs = .{},
    // The running call's claims and releases per slab class and directory.
    claim_tally: ClaimTally = .{},
    chunk_items: std.ArrayList(ChunkItem) = .empty,
    coarse_items: std.ArrayList(CoarseItem) = .empty,
    nav_inserts: std.ArrayList(SpanInsert) = .empty,
    query_inserts: std.ArrayList(AabbInsert) = .empty,
    coarse_inserts: std.ArrayList(AabbInsert) = .empty,
    // Where the fill finds the call's items, band by band, and their fill units.
    item_bands: ItemBands = .{},
    // The stage scratch a rebuild frees before the swap (`freeRebuildScratch`) and a sync
    // keeps at its high-water. A rebuild's select writes each range's statics into its
    // window of `plan_inputs`; the main thread compacts them to ranks `[0, S)` in
    // entity-index order, each static's row. A sync packs each pending index's static there.
    plan_inputs: std.MultiArrayList(PlanInput) = .{},
    select_tallies: SlotList(SelectTally) = .empty,
    // Per plan item (rank or pending index): its query class, and its touches' offsets in
    // each tier past its plan range's base (`PlanTally`).
    plan_class: std.ArrayList(u16) = .empty,
    plan_item_count: usize = 0,
    plan_items_per_range: usize = 1,
    plan_touch_local: [tier_count]std.ArrayList(u32) = @splat(.empty),
    plan_tallies: SlotList(PlanTally) = .empty,
    // Each tier's touches in plan order, and staged by band per touch range, with each
    // range's band offsets into its staging window, absolute. Each touch range's window
    // starts on its own cache line (`touchWindowStart`).
    chunk_touches: TouchList(ChunkTouch) = .empty,
    chunk_staging: TouchList(ChunkTouch) = .empty,
    coarse_touches: TouchList(CoarseTouch) = .empty,
    coarse_staging: TouchList(CoarseTouch) = .empty,
    touch_band_offsets: [tier_count]SlotList(BandOffsets) = @splat(.empty),
    touch_splitters: [tier_count]TouchSplitters = @splat(@splat(0)),
    // Per tier, band b's touches start at `touch_start[tier][b]` of the tier's touch order;
    // its items, inserts, and level entries take windows there, the coarse tier's level
    // entries past the chunk tier's. Its resource entries take
    // `resource_entries[entry_start[tier][b]..entry_start[tier][b + 1]]`, one per resource it
    // can use.
    touch_start: [tier_count][band_count + 1]u32 = @splat(@splat(0)),
    // Band b's key table: `group_slots[region_start[tier][b]..region_start[tier][b + 1]]`.
    region_start: [tier_count][band_count + 1]usize = @splat(@splat(0)),
    entry_start: [tier_count][band_count + 1]usize = @splat(@splat(0)),
    group_slots: std.ArrayList(GroupSlot) = .empty,
    group_generation: u32 = 0,
    group_tallies: SlotList(GroupTally) = .empty,
    resource_entries: std.ArrayList(ResourceEntry) = .empty,
    level_entries: std.ArrayList(u32) = .empty,
    // Rows per query class, and the classes holding any row (refreshed after every sync
    // and rebuild).
    query_class_rows: [max_query_classes]u32 = @splat(0),
    query_class_mask: QueryClassMask = .empty,
    query_top_class: u6 = 0,
    revision: u64 = 0,
    // `sync`'s stage tuners and `rebuild`'s (each samples once per rebuild, carried across
    // rebuilds), the shared range controls (production runs adaptive; benches pin a fixed
    // partition), and each stage's last batch shape.
    tuners: std.EnumArray(SyncStage, AdaptiveWorkTuner) = .initFill(AdaptiveWorkTuner.init(.{})),
    rebuild_tuners: std.EnumArray(RebuildStage, AdaptiveWorkTuner) = .initFill(AdaptiveWorkTuner.init(rebuild_tuner_config)),
    splice_controls: StageControls = .{},
    last_batches: std.EnumArray(ColliderStage, BatchStats) = .initFill(.{}),
    perf: Perf = .{},
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
    /// The first row-pool growth is logged once.
    row_growth_logged: bool = false,
    /// The first payload growth (`Perf.payload_grows`) is logged once.
    payload_growth_logged: bool = false,

    /// Kept only with `runtime_perf_log.enabled`, across rebuilds: row-pool growths, and
    /// payload growths (a level's directory opened, a block pool grown, a payload slab
    /// allocated, or one of sync's stage scratch lists grown).
    pub const Perf = if (runtime_perf_log.enabled) struct {
        row_grows: u64 = 0,
        payload_grows: u64 = 0,
    } else struct {};

    pub fn init(allocator: std.mem.Allocator) StaticColliderSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StaticColliderSystem) void {
        for (&self.coarse) |*dir| dir.deinit(self.allocator);
        self.chunks.deinit(self.allocator);
        self.payloads.deinit(self.allocator);
        self.freeRebuildScratch();
        self.sync_plan.deinit(self.allocator);
        self.sync_rows.deinit(self.allocator);
        self.changes.deinit(self.allocator);
        self.relink_stamp.deinit(self.allocator);
        self.dirty_entity.deinit(self.allocator);
        self.dirty_stamp.deinit(self.allocator);
        self.pending_dirty.deinit(self.allocator);
        self.row_of_index.deinit(self.allocator);
        self.row_free.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.* = undefined;
    }

    // The rows' AABB and cell columns, where a rebuild's plan lanes store each rank's row.
    fn rowLaneOutputs(self: *const StaticColliderSystem) LaneOutputs {
        return .{
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
            .chunks = &self.chunks,
            .coarse = &self.coarse,
            .query_class_mask = self.query_class_mask,
            .query_top_class = self.query_top_class,
            .revision = self.revision,
            .row_of_index = self.row_of_index.items,
            .row_entity = self.row_entity,
            .row_min_x = self.row_min_x,
            .row_min_y = self.row_min_y,
            .row_max_x = self.row_max_x,
            .row_max_y = self.row_max_y,
            .changes = self.changes.items,
        };
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

    /// Replaces every row with the statics `data` holds now, placed on `geometry`, and
    /// builds each footprint chunk's span and query columns. An error leaves the system
    /// unchanged. Drops pending changes. Each stage runs on `thread_system`'s workers under
    /// its own rebuild tuner (one sample per rebuild; the tuners carry across rebuilds and
    /// never reach sync's), or inline as one range without one: `select` (every entity
    /// slot's static, packed by range), `plan` (each static's row, footprint, query class,
    /// and touch counts in lanes), `touch` (each footprint chunk and coarse cell, placed by
    /// band), `group` (each band's key table zeroed, then its chunks and cells into items,
    /// their inserts, payload claims, and levels), `rewrite` (the fill), and `install`. Main
    /// holds the reserves, prefixes over ranges and bands, the claim merge, one open per
    /// level touched, and two ns-per-item passes: the per-index reset and the window
    /// compaction.
    pub fn rebuild(self: *StaticColliderSystem, data: *const DataSystem, geometry: ColliderGeometry, thread_system: ?*ThreadSystem) error{OutOfMemory}!void {
        std.debug.assert(geometry.grid.chunk_tiles != 0 and std.math.isPowerOfTwo(geometry.grid.chunk_tiles));
        // Anchor words hold the fine classes of a chunk up to this edge.
        std.debug.assert(geometry.grid.chunk_tiles <= max_chunk_size_tiles);
        var fresh = self.freshFor(geometry);
        errdefer fresh.deinit();
        const stages = fresh.rebuildStages(thread_system);
        try fresh.prepareRebuild(data, stages);
        fresh.finishRebuild(stages);
        self.deinit();
        self.* = fresh;
    }

    // An empty system on `geometry` carrying `self`'s revision, growth logs and counters,
    // tuners, and stage controls.
    fn freshFor(self: *const StaticColliderSystem, geometry: ColliderGeometry) StaticColliderSystem {
        var fresh = StaticColliderSystem.init(self.allocator);
        fresh.geometry = geometry;
        fresh.revision = self.revision +% 1;
        fresh.query_top_class = geometry.topQueryClass();
        fresh.row_growth_logged = self.row_growth_logged;
        fresh.payload_growth_logged = self.payload_growth_logged;
        if (comptime runtime_perf_log.enabled) fresh.perf = self.perf;
        fresh.tuners = self.tuners;
        fresh.rebuild_tuners = self.rebuild_tuners;
        fresh.splice_controls = self.splice_controls;
        return fresh;
    }

    // The thread system and range controls a rebuild's stages dispatch on; each stage takes
    // its own rebuild tuner (`rebuildDispatch`).
    fn rebuildStages(self: *const StaticColliderSystem, thread_system: ?*ThreadSystem) ?ColliderThreads {
        const threads = thread_system orelse return null;
        return .{ .thread_system = threads, .config = self.splice_controls };
    }

    // Rebuild stage `stage`'s dispatch of `item_count` items under its own tuner, or null
    // (inline) without a thread system or items: an empty stage selects nothing and touches
    // no tuner. Only rebuild tuners are reachable here.
    fn rebuildDispatch(self: *StaticColliderSystem, threads: ?ColliderThreads, stage: RebuildStage, item_count: usize) ?Dispatch {
        const stages = threads orelse return null;
        if (item_count == 0) return null;
        return stages.stage(self.rebuild_tuners.getPtr(stage));
    }

    // Every rebuild stage before the fill, and every reserve: after it nothing fails.
    fn prepareRebuild(self: *StaticColliderSystem, data: *const DataSystem, stages: ?ColliderThreads) error{OutOfMemory}!void {
        const touches = try self.planStatics(data, stages);
        try self.groupFootprints(stages, touches, self.touchSplitters());
    }

    // `select` and `plan`: every static's row, and each tier's touch count.
    fn planStatics(self: *StaticColliderSystem, data: *const DataSystem, stages: ?ColliderThreads) error{OutOfMemory}!TierCounts {
        // Every entity index `data` holds, as `reserveForCommit` sizes them.
        const slot_count = data.slots.items.len;
        try self.reserveIndices(slot_count);
        try self.reserveSelect(slot_count);
        self.selectStatics(data, stages, slot_count);
        const static_count = self.plan_inputs.len;
        try self.reserveRebuildRows(static_count);
        try self.reservePlan(static_count, plan_range_alignment_items);
        self.planRows(stages, static_count);
        return self.mergePlanTallies();
    }

    // `touch` and `group` under the band `splitters` of each tier, then the growth seam
    // before the fill. Every id and layout is the same for any splitters, range size, and
    // worker count but the block and slot ids, which follow the bands.
    fn groupFootprints(self: *StaticColliderSystem, stages: ?ColliderThreads, touches: TierCounts, splitters: [tier_count]TouchSplitters) error{OutOfMemory}!void {
        const static_count = self.rows.len;
        // The touch windows are sized from the selection the dispatch runs; an error past it
        // discards this system and the tuner's selection with it (`rebuild`).
        const dispatch = self.rebuildDispatch(stages, .touch, static_count);
        const shape = StageShape.select(dispatch, static_count, touch_range_alignment_items);
        try self.reserveTouches(touches, shape.range_count);
        self.touch_splitters = splitters;
        self.touchFootprints(dispatch, shape, .rebuild);
        try self.reserveGroup(touches);
        self.groupTouches(self.rebuildDispatch(stages, .group, tierTotal(touches)), touches);
        try self.reservePayloads();
    }

    // The fill, its claims, and the install, then the scratch freed. Allocates nothing.
    fn finishRebuild(self: *StaticColliderSystem, stages: ?ColliderThreads) void {
        self.rewriteItems(self.rebuildDispatch(stages, .rewrite, self.item_bands.unitCount()), self.resource_entries.items);
        self.commitClaims();
        self.installItems(self.rebuildDispatch(stages, .install, self.item_bands.itemCount()));
        self.freeRebuildScratch();
    }

    // Frees a rebuild's stage scratch and the item lists; nothing in them outlives the call.
    fn freeRebuildScratch(self: *StaticColliderSystem) void {
        self.plan_inputs.clearAndFree(self.allocator);
        self.select_tallies.clearAndFree(self.allocator);
        self.plan_class.clearAndFree(self.allocator);
        for (&self.plan_touch_local) |*local| local.clearAndFree(self.allocator);
        self.plan_tallies.clearAndFree(self.allocator);
        self.chunk_touches.clearAndFree(self.allocator);
        self.chunk_staging.clearAndFree(self.allocator);
        self.coarse_touches.clearAndFree(self.allocator);
        self.coarse_staging.clearAndFree(self.allocator);
        for (&self.touch_band_offsets) |*offsets| offsets.clearAndFree(self.allocator);
        self.group_slots.clearAndFree(self.allocator);
        self.group_tallies.clearAndFree(self.allocator);
        self.resource_entries.clearAndFree(self.allocator);
        self.level_entries.clearAndFree(self.allocator);
        self.chunk_items.clearAndFree(self.allocator);
        self.coarse_items.clearAndFree(self.allocator);
        self.nav_inserts.clearAndFree(self.allocator);
        self.query_inserts.clearAndFree(self.allocator);
        self.coarse_inserts.clearAndFree(self.allocator);
    }

    // The select's windows: one per range over `slot_count` slots, each range's statics at
    // its start, and a tally per range. Lane-aligned, as the plan lanes read the columns.
    fn reserveSelect(self: *StaticColliderSystem, slot_count: usize) error{OutOfMemory}!void {
        try self.plan_inputs.ensureTotalCapacity(self.allocator, std.mem.alignForward(usize, slot_count, select_range_alignment_items));
        try self.select_tallies.ensureTotalCapacity(self.allocator, maxRangeCount(slot_count, select_range_alignment_items));
        std.debug.assert(self.plan_inputs.capacity >= slot_count);
        setRowCount(PlanInput, &self.plan_inputs, slot_count);
    }

    // `select`: every entity slot's static into its range's window, then the windows
    // compacted on main, so `plan_inputs` holds the statics in entity-index order.
    fn selectStatics(self: *StaticColliderSystem, data: *const DataSystem, stages: ?ColliderThreads, slot_count: usize) void {
        const dispatch = self.rebuildDispatch(stages, .select, slot_count);
        const shape = StageShape.select(dispatch, slot_count, select_range_alignment_items);
        std.debug.assert(shape.range_count <= self.select_tallies.capacity);
        setSlotCount(SelectTally, &self.select_tallies, shape.range_count);
        var job = SelectJob{
            .data = data,
            .columns = data.staticObstacleColumns(),
            .inputs = PlanColumns.of(&self.plan_inputs),
            .tallies = self.select_tallies.items,
            .items_per_range = shape.items_per_range,
        };
        self.last_batches.set(.select, runShaped(dispatch, shape, slot_count, select_range_alignment_items, &job, selectJob));
        compactRowWindows(PlanInput, SelectTally, &self.plan_inputs, self.select_tallies.items, shape.items_per_range);
    }

    // Rows `[0, static_count)`, each the rank of its static in entity-index order. The free
    // list's capacity covers every row; nothing is pushed. Geometric and counted.
    fn reserveRebuildRows(self: *StaticColliderSystem, static_count: usize) error{OutOfMemory}!void {
        // At most one static per entity slot, and slots stay below maxInt(u32).
        std.debug.assert(static_count < no_row);
        if (static_count > self.rows.capacity) {
            try self.rows.ensureTotalCapacity(self.allocator, static_count);
            // The pool moved: the column views follow it before anything else can fail.
            self.refreshColumns();
            self.countRowGrowth();
        }
        try self.row_free.ensureTotalCapacity(self.allocator, self.rows.capacity);
        setRowCount(Row, &self.rows, static_count);
        self.refreshColumns();
    }

    // The plan's per-item columns over `item_count` plan items and its per-range tallies at
    // the stage's `alignment`.
    fn reservePlan(self: *StaticColliderSystem, item_count: usize, alignment: usize) error{OutOfMemory}!void {
        try self.plan_class.ensureTotalCapacity(self.allocator, item_count);
        for (&self.plan_touch_local) |*local| try local.ensureTotalCapacity(self.allocator, item_count);
        try self.plan_tallies.ensureTotalCapacity(self.allocator, maxRangeCount(item_count, alignment));
        self.plan_class.items.len = item_count;
        for (&self.plan_touch_local) |*local| local.items.len = item_count;
    }

    // `plan`: each rank's row, `row_of_index`, query class, touch offsets, and its range's
    // touch and class counts.
    fn planRows(self: *StaticColliderSystem, stages: ?ColliderThreads, static_count: usize) void {
        const dispatch = self.rebuildDispatch(stages, .plan, static_count);
        const shape = StageShape.select(dispatch, static_count, plan_range_alignment_items);
        std.debug.assert(shape.range_count <= self.plan_tallies.capacity);
        setSlotCount(PlanTally, &self.plan_tallies, shape.range_count);
        self.plan_item_count = static_count;
        self.plan_items_per_range = shape.items_per_range;
        var job = PlanJob{ .colliders = self, .inputs = PlanColumns.of(&self.plan_inputs), .outputs = self.rowLaneOutputs() };
        self.last_batches.set(.plan, runShaped(dispatch, shape, static_count, plan_range_alignment_items, &job, planJob));
    }

    // Each plan range's touch bases in each tier, and the rows per query class, in range
    // order. A total of 2^31 touches or more fails as `OutOfMemory`, so every count the
    // later stages index fits u32. O(ranges * classes).
    fn mergePlanTallies(self: *StaticColliderSystem) error{OutOfMemory}!TierCounts {
        var totals: [tier_count]u64 = @splat(0);
        for (self.plan_tallies.items) |slot| {
            for (&totals, slot.value.touches) |*total, touches| total.* += touches;
        }
        if (totals[chunk_tier] + totals[coarse_tier] >= max_touches) return error.OutOfMemory;
        var bases: [tier_count]u32 = @splat(0);
        self.query_class_rows = @splat(0);
        for (self.plan_tallies.items) |*slot| {
            slot.value.bases = bases;
            // Below the checked total.
            for (&bases, slot.value.touches) |*base, touches| base.* += @intCast(touches);
            // A rebuild's range counts its ranks, under `no_row`.
            for (&self.query_class_rows, slot.value.class_delta) |*rows, added| rows.* += @intCast(added);
        }
        self.refreshQueryClassMask();
        return bases;
    }

    // Each tier's touch scratch and staging over `range_count` touch ranges, each range's
    // window rounded up to a cache line (at most a line's worth of padding per range), and
    // the ranges' band offsets.
    fn reserveTouches(self: *StaticColliderSystem, touches: TierCounts, range_count: usize) error{OutOfMemory}!void {
        const chunk_len = touchExtent(ChunkTouch, touches[chunk_tier], range_count);
        const coarse_len = touchExtent(CoarseTouch, touches[coarse_tier], range_count);
        try self.chunk_touches.ensureTotalCapacity(self.allocator, chunk_len);
        try self.chunk_staging.ensureTotalCapacity(self.allocator, chunk_len);
        try self.coarse_touches.ensureTotalCapacity(self.allocator, coarse_len);
        try self.coarse_staging.ensureTotalCapacity(self.allocator, coarse_len);
        for (&self.touch_band_offsets) |*offsets| try offsets.ensureTotalCapacity(self.allocator, range_count);
        self.chunk_touches.items.len = chunk_len;
        self.chunk_staging.items.len = chunk_len;
        self.coarse_touches.items.len = coarse_len;
        self.coarse_staging.items.len = coarse_len;
    }

    // The band splitters of each tier: the band quantiles of the first-touch keys of a fixed
    // sample of ranks (`banded_sort.sampleSlot`), so they never depend on the partition.
    // Fixed work on main.
    fn touchSplitters(self: *const StaticColliderSystem) [tier_count]TouchSplitters {
        const geometry = self.geometry.?;
        const shift = geometry.grid.shift;
        const static_count = self.rows.len;
        var chunk_samples: [banded_sort.splitter_sample_count]u64 = undefined;
        var coarse_samples: [banded_sort.splitter_sample_count]u64 = undefined;
        var chunk_count: usize = 0;
        var coarse_count: usize = 0;
        for (0..banded_sort.sampleCount(static_count)) |sample| {
            const rank: u32 = @intCast(banded_sort.sampleSlot(sample, static_count));
            const placement = self.rowPlacement(rank);
            const rect = geometry.chunkRect(placement);
            chunk_samples[chunk_count] = chunkKey(placement.level, rect.min_y * rect.chunks_x + rect.min_x);
            chunk_count += 1;
            // A query class fits u6.
            const class: u6 = @intCast(self.plan_class.items[rank]);
            if (class <= shift) continue;
            coarse_samples[coarse_count] = geometry.queryKey(placement.level, class, placement.cells);
            coarse_count += 1;
        }
        return .{
            ChunkTouchSort.splittersFromSamples(chunk_samples[0..chunk_count]),
            CoarseTouchSort.splittersFromSamples(coarse_samples[0..coarse_count]),
        };
    }

    // `touch` at `shape` over the plan items: each one's touches (`emitTouches` of a rank,
    // `emitPendingTouches` of a pending index), written in plan order into its range's
    // line-aligned window, then placed by band into the same staging window.
    fn touchFootprints(self: *StaticColliderSystem, dispatch: ?Dispatch, shape: StageShape, source: TouchSource) void {
        for (&self.touch_band_offsets) |*offsets| {
            std.debug.assert(shape.range_count <= offsets.capacity);
            setSlotCount(BandOffsets, offsets, shape.range_count);
        }
        var job = TouchJob{ .colliders = self, .range_count = shape.range_count, .source = source };
        self.last_batches.set(.touch, runShaped(dispatch, shape, self.plan_item_count, touch_range_alignment_items, &job, touchJob));
    }

    // Each tier's band starts over every touch range's band offsets (O(ranges * bands)), each
    // band's key table region and resource entry window, and the group's item, insert,
    // entry, level, and tally windows. A region holds a band's keys plus one level marker per
    // item at load at most 1/2. A band's entries are one per resource it uses, at most
    // `entries_per_touch` per touch and its tier's resource count, so they total O(bands *
    // resources) whatever the touches. The table grows uninitialized: each band zeros its
    // own region on its worker before its first claim (`BandTable.init`), so main writes no
    // slot.
    fn reserveGroup(self: *StaticColliderSystem, touches: TierCounts) error{OutOfMemory}!void {
        var slots: usize = 0;
        var entries: usize = 0;
        for (0..tier_count) |tier| {
            var counts: [band_count]u32 = @splat(0);
            for (self.touch_band_offsets[tier].items) |slot| {
                const offsets = &slot.value.offsets;
                for (&counts, offsets[0..band_count], offsets[1..]) |*count, start, end| count.* += end - start;
            }
            const starts = &self.touch_start[tier];
            const regions = &self.region_start[tier];
            const entry_starts = &self.entry_start[tier];
            starts[0] = 0;
            for (counts, 0..) |count, band| {
                starts[band + 1] = starts[band] + count;
                regions[band] = slots;
                entry_starts[band] = entries;
                if (count != 0) slots += try hashTableSlots(2 * @as(usize, count));
                entries += @min(entries_per_touch * @as(usize, count), tier_resource_count[tier]);
            }
            regions[band_count] = slots;
            entry_starts[band_count] = entries;
            std.debug.assert(starts[band_count] == touches[tier]);
        }
        const table_len = self.group_slots.items.len;
        if (slots > table_len) {
            try self.group_slots.ensureTotalCapacity(self.allocator, slots);
            self.group_slots.items.len = slots;
        }
        const touch_total = @as(usize, touches[chunk_tier]) + touches[coarse_tier];
        try self.chunk_items.ensureTotalCapacity(self.allocator, touches[chunk_tier]);
        try self.coarse_items.ensureTotalCapacity(self.allocator, touches[coarse_tier]);
        try self.nav_inserts.ensureTotalCapacity(self.allocator, touches[chunk_tier]);
        try self.query_inserts.ensureTotalCapacity(self.allocator, touches[chunk_tier]);
        try self.coarse_inserts.ensureTotalCapacity(self.allocator, touches[coarse_tier]);
        try self.resource_entries.ensureTotalCapacity(self.allocator, entries);
        try self.level_entries.ensureTotalCapacity(self.allocator, touch_total);
        try self.group_tallies.ensureTotalCapacity(self.allocator, tier_count * band_count);
        self.chunk_items.items.len = touches[chunk_tier];
        self.coarse_items.items.len = touches[coarse_tier];
        self.nav_inserts.items.len = touches[chunk_tier];
        self.query_inserts.items.len = touches[chunk_tier];
        self.coarse_inserts.items.len = touches[coarse_tier];
        self.resource_entries.items.len = entries;
        self.level_entries.items.len = touch_total;
    }

    // `group` under `dispatch`: each range owns, per tier, the bands starting in its span of
    // the touches, in a new generation of the key table.
    fn groupTouches(self: *StaticColliderSystem, dispatch: ?Dispatch, touches: TierCounts) void {
        const touch_total = tierTotal(touches);
        const shape = StageShape.select(dispatch, touch_total, group_range_alignment_items);
        std.debug.assert(self.group_tallies.capacity >= tier_count * band_count);
        setSlotCount(GroupTally, &self.group_tallies, tier_count * band_count);
        GroupTable.advance(self.group_slots.items, &self.group_generation);
        var job = GroupJob{ .colliders = self, .range_count = shape.range_count };
        self.last_batches.set(.group, runShaped(dispatch, shape, touch_total, group_range_alignment_items, &job, groupJob));
    }

    // The group's merge and the growth seam before the fill: each tier's item and unit
    // starts per band; each resource entry's claim and release bases, band by band in order,
    // so every claim ordinal and release position is its band's base plus its first-touch
    // rank there; one open per (band, level) entry of a fresh block; and one reserve per slab
    // class and directory claimed. O(bands + entries + levels + classes). Grown slabs and
    // block pools count as payload growth as they grow, and stay on error.
    fn reservePayloads(self: *StaticColliderSystem) error{OutOfMemory}!void {
        for (self.group_tallies.items) |slot| if (slot.value.overflow) return error.OutOfMemory;
        const bands = &self.item_bands;
        var units: usize = 0;
        var claims: [resource_count]u32 = @splat(0);
        var releases: [resource_count]u32 = @splat(0);
        for (0..tier_count) |tier| {
            bands.item_start[tier][0] = 0;
            for (0..band_count) |band| {
                const tally = self.group_tallies.items[tier * band_count + band].value;
                bands.band_base[tier][band] = self.touch_start[tier][band];
                bands.item_start[tier][band + 1] = bands.item_start[tier][band] + tally.items;
                bands.unit_start[tier][band] = units;
                units += tally.units;
                const window = self.entryWindow(tier, band)[0..tally.entries];
                for (window) |*entry| {
                    // Claims and releases stay below the touch count, under 2^31.
                    entry.claim_base = claims[entry.resource];
                    claims[entry.resource] += entry.claims;
                    entry.release_base = releases[entry.resource];
                    releases[entry.resource] += entry.releases;
                }
            }
            bands.unit_start[tier][band_count] = units;
        }
        for (0..tier_count) |tier| {
            for (0..band_count) |band| {
                const tally = self.group_tallies.items[tier * band_count + band].value;
                const levels = self.level_entries.items[self.levelWindow(tier, band)..][0..tally.levels];
                for (levels) |entry| switch (tier) {
                    chunk_tier => try self.openChunkLevel(@intCast(entry)),
                    // A coarse entry is `class << 16 | level`.
                    else => try self.openCoarseLevel(@intCast(entry >> 16), @truncate(entry)),
                };
            }
        }
        const tally = &self.claim_tally;
        tally.* = .{};
        const slabs_before = self.payloads.slab_count;
        defer self.countPayloadGrowth(self.payloads.slab_count - slabs_before);
        for (claims[0..max_payload_classes], releases[0..max_payload_classes], 0..) |count, released, class| {
            if (count == 0 and released == 0) continue;
            tally.slot_classes.set(class);
            tally.slot_claims[class] = count;
            tally.slot_releases[class] = released;
            // A release fits the class's free list, which covers every id.
            if (count != 0) try self.payloads.reserve(self.allocator, @intCast(class), count);
        }
        tally.chunk_blocks = .{ .claims = claims[chunk_directory_resource], .releases = releases[chunk_directory_resource] };
        try self.reserveBlocks(&self.chunks, tally.chunk_blocks.claims);
        for (0..max_query_classes) |class| {
            const resource = coarseDirectoryResource(@intCast(class));
            if (claims[resource] == 0 and releases[resource] == 0) continue;
            tally.coarse_classes.set(class);
            tally.coarse_blocks[class] = .{ .claims = claims[resource], .releases = releases[resource] };
            try self.reserveBlocks(&self.coarse[class], claims[resource]);
        }
    }

    // Band `band`'s resource entry window of `tier`.
    fn entryWindow(self: *StaticColliderSystem, tier: usize, band: usize) []ResourceEntry {
        return self.resource_entries.items[self.entry_start[tier][band]..self.entry_start[tier][band + 1]];
    }

    // Band `band`'s first level entry of `tier`: its touch start, the coarse tier's past the
    // chunk tier's.
    fn levelWindow(self: *const StaticColliderSystem, tier: usize, band: usize) usize {
        return self.tierTouchBase(tier) + self.touch_start[tier][band];
    }

    fn tierTouchBase(self: *const StaticColliderSystem, tier: usize) usize {
        return if (tier == chunk_tier) 0 else self.touch_start[chunk_tier][band_count];
    }

    // `install` under `dispatch`: each range owns, per tier, the bands whose first item lies
    // in its span of the items, and installs their fresh blocks and writes their releases.
    fn installItems(self: *StaticColliderSystem, dispatch: ?Dispatch) void {
        const item_count = self.item_bands.itemCount();
        const shape = StageShape.select(dispatch, item_count, install_range_alignment_items);
        var job = InstallJob{ .colliders = self, .range_count = shape.range_count };
        self.last_batches.set(.install, runShaped(dispatch, shape, item_count, install_range_alignment_items, &job, installJob));
    }

    // The plan lanes over plan items `[start, end)`, from the packed inputs: each static's
    // AABB (as `math.aabbFromOffsetSize`), footprint cells (as `math.worldPosToCell` and `math.lastCellOfSpan`),
    // chunk rect touch count, coarse touch count, and query class (as `queryClass`), stored
    // to `outputs`, its touch counts to `plan_touch_local` (the scan or the sync's decision
    // turns them into offsets), and its class to `plan_class`.
    // SIMD verdict: lanes, the last group one masked batch.
    fn planLanes(self: *StaticColliderSystem, inputs: PlanColumns, outputs: LaneOutputs, start: usize, end: usize) void {
        const geometry = self.geometry.?;
        const grid = geometry.grid;
        // Cells to chunks as `chunkRect`, `>> shift`: the chunk edge is a power of two
        // (`rebuild`), so the shift equals the division bit for bit.
        std.debug.assert(@as(u32, 1) << grid.shift == grid.chunk_tiles);
        const chunk_shift: u5 = grid.shift;
        const one = simd.splatUint4(1);
        const top_fine_class = simd.splatInt4(grid.shift);
        const chunk_counts = self.plan_touch_local[chunk_tier].items;
        const coarse_counts = self.plan_touch_local[coarse_tier].items;
        var group = start;
        while (group < end) : (group += simd.lane_count) {
            const count = end - group;
            const min_x = simd.loadFloat4Lanes(inputs.x[group..], count) + simd.loadFloat4Lanes(inputs.offset_x[group..], count);
            const min_y = simd.loadFloat4Lanes(inputs.y[group..], count) + simd.loadFloat4Lanes(inputs.offset_y[group..], count);
            const max_x = min_x + simd.loadFloat4Lanes(inputs.size_x[group..], count);
            const max_y = min_y + simd.loadFloat4Lanes(inputs.size_y[group..], count);
            simd.storeFloat4Lanes(outputs.min_x[group..], min_x, count);
            simd.storeFloat4Lanes(outputs.min_y[group..], min_y, count);
            simd.storeFloat4Lanes(outputs.max_x[group..], max_x, count);
            simd.storeFloat4Lanes(outputs.max_y[group..], max_y, count);
            // Clamped cells lie in `[0, edge - 1]`, so non-negative.
            const cell_min_x: simd.Uint4 = @bitCast(simd.worldPosToCell4(min_x, geometry.cell_size, grid.width));
            const cell_min_y: simd.Uint4 = @bitCast(simd.worldPosToCell4(min_y, geometry.cell_size, grid.height));
            const cell_max_x: simd.Uint4 = @bitCast(simd.lastCellOfSpan4(min_x, max_x, geometry.cell_size, grid.width));
            const cell_max_y: simd.Uint4 = @bitCast(simd.lastCellOfSpan4(min_y, max_y, geometry.cell_size, grid.height));
            simd.storeUint4Lanes(outputs.cell_min_x[group..], cell_min_x, count);
            simd.storeUint4Lanes(outputs.cell_min_y[group..], cell_min_y, count);
            simd.storeUint4Lanes(outputs.cell_max_x[group..], cell_max_x, count);
            simd.storeUint4Lanes(outputs.cell_max_y[group..], cell_max_y, count);
            // The chunk rect's count: a level's chunks number below 2^32.
            const chunks_wide = (cell_max_x >> @splat(chunk_shift)) - (cell_min_x >> @splat(chunk_shift)) + one;
            const chunks_high = (cell_max_y >> @splat(chunk_shift)) - (cell_min_y >> @splat(chunk_shift)) + one;
            simd.storeUint4Lanes(chunk_counts[group..], chunks_wide * chunks_high, count);
            const classes = geometry.queryClass4(self.query_top_class, min_x, min_y, max_x, max_y, count);
            const coarse = simd.selectInt4(simd.greaterThanInt4(classes, top_fine_class), simd.splatInt4(1), simd.splatInt4(0));
            simd.storeUint4Lanes(coarse_counts[group..], @bitCast(coarse), count);
            // A class lies in `[0, 32]`, so non-negative and below 2^16.
            simd.storeUint4LanesU16(self.plan_class.items[group..], @bitCast(classes), count);
        }
    }

    // The plan's scan over ranks `[start, end)`: each rank's row entity and level, its
    // `row_of_index` entry, its touches' offsets in its range (over the counts the lanes
    // stored), and the range's touch and class counts.
    // SIMD verdict: scalar. A running prefix (a data dependency on the running total), and a
    // class histogram and `row_of_index`, scattered writes; the copies are `@memcpy`.
    fn planScan(self: *StaticColliderSystem, inputs: PlanColumns, start: usize, end: usize, tally: *PlanTally) void {
        @memcpy(self.row_entity[start..end], inputs.entity[start..end]);
        @memcpy(self.row_level[start..end], inputs.level[start..end]);
        var running: [tier_count]u64 = @splat(0);
        for (start..end) |rank| {
            // Ranks stay below the row count, under `no_row`.
            self.row_of_index.items[inputs.entity[rank].index] = @intCast(rank);
            for (&self.plan_touch_local, &running) |*local, *total| {
                const touches = local.items[rank];
                // Read only once the main thread's merge keeps the total below 2^31.
                local.items[rank] = @truncate(total.*);
                total.* += touches;
            }
            tally.class_delta[self.plan_class.items[rank]] += 1;
        }
        tally.touches = running;
    }

    // The offset of rank `rank`'s first touch of `tier` in the tier's plan order; the
    // tier's touch count past the last rank.
    fn touchOffset(self: *const StaticColliderSystem, tier: usize, rank: usize) usize {
        if (rank == self.plan_item_count) return self.tierTouchCount(tier);
        const base = self.plan_tallies.items[rank / self.plan_items_per_range].value.bases[tier];
        return @as(usize, base) + self.plan_touch_local[tier].items[rank];
    }

    // The tier's touch count: the last plan range's base plus its touches.
    fn tierTouchCount(self: *const StaticColliderSystem, tier: usize) usize {
        const last = self.plan_tallies.items[self.plan_tallies.items.len - 1].value;
        // Below the merge's checked total.
        return @as(usize, last.bases[tier]) + @as(usize, @intCast(last.touches[tier]));
    }

    // The touches of ranks `[start, end)` in rank order, written from `at` in each tier: each
    // footprint chunk row-major, the query record on its anchor chunk, then a coarse class's
    // query cell. Returns each tier's end.
    // SIMD verdict: scalar. A variable emission per rank (a compaction), with integer key and
    // anchor packing.
    fn emitTouches(self: *StaticColliderSystem, start: usize, end: usize, at: [tier_count]usize) [tier_count]usize {
        var cursor = at;
        for (start..end) |rank| {
            // Ranks stay below the row count, under `no_row`.
            const row: u32 = @intCast(rank);
            // A query class fits u6.
            const class: u6 = @intCast(self.plan_class.items[rank]);
            self.emitInserts(self.row_entity[rank].index, self.rowPlacement(row), self.rowAabb(row), class, &cursor);
        }
        return cursor;
    }

    // The touches of pending indices `[start, end)` in plan order, written from `at` in each
    // tier: each relinked index's removals from its old row's footprint chunks (its query
    // record's on the old anchor chunk) and old coarse cell, then its new row's inserts as
    // `emitTouches`. Resolves each add's row, the claim at its ordinal of the row ids, which
    // nothing changes until the main thread commits them after the group. Returns each
    // tier's end.
    // SIMD verdict: scalar, as `emitTouches`, plus one point read per add.
    fn emitPendingTouches(self: *StaticColliderSystem, start: usize, end: usize, at: [tier_count]usize) [tier_count]usize {
        const geometry = self.geometry.?;
        const shift = geometry.grid.shift;
        const rows = self.rowIds();
        const inputs = PlanColumns.of(&self.plan_inputs);
        const outputs = LaneOutputs.ofSyncRows(&self.sync_rows);
        var cursor = at;
        for (start..end) |index| {
            const plan = &self.sync_plan.items[index];
            if (plan.has_new and plan.old_row == no_row) {
                const tally = self.plan_tallies.items[index / self.plan_items_per_range].value;
                plan.row = rows.claimedId(@as(usize, tally.add_base) + plan.add_local);
            }
            if (!plan.relink) continue;
            const entity = self.pending_dirty.items[index];
            if (plan.old_rect) |rect| {
                const old_query = plan.old_query.?;
                const anchor: ?u64 = if (old_query.class <= shift) geometry.anchorBit(old_query.key).chunk_key else null;
                var chunk_y = rect.min_y;
                while (chunk_y <= rect.max_y) : (chunk_y += 1) {
                    var chunk_x = rect.min_x;
                    while (chunk_x <= rect.max_x) : (chunk_x += 1) {
                        const key = chunkKey(rect.level, chunk_y * rect.chunks_x + chunk_x);
                        self.chunk_touches.items[cursor[chunk_tier]] = .{ .key = key, .entity = entity, .bit = 0, .insert = false, .query_record = if (anchor) |chunk_key| chunk_key == key else false, .cells = no_cells, .aabb = no_aabb };
                        cursor[chunk_tier] += 1;
                    }
                }
                if (old_query.class > shift) {
                    self.coarse_touches.items[cursor[coarse_tier]] = .{ .key = old_query.key, .entity = entity, .insert = false, .aabb = no_aabb };
                    cursor[coarse_tier] += 1;
                }
            }
            if (plan.has_new) {
                // A query class fits u6.
                const class: u6 = @intCast(self.plan_class.items[index]);
                self.emitInserts(entity, outputs.placement(inputs.level[index], index), outputs.aabb(index), class, &cursor);
            }
        }
        return cursor;
    }

    // One row's insert touches at `cursor`: each footprint chunk row-major, the query record
    // on its anchor chunk, then a coarse class's query cell.
    fn emitInserts(self: *StaticColliderSystem, entity: u32, placement: Placement, aabb: math.Aabb, class: u6, cursor: *[tier_count]usize) void {
        const geometry = self.geometry.?;
        const shift = geometry.grid.shift;
        const query_key = geometry.queryKey(placement.level, class, placement.cells);
        const anchor: ?AnchorBit = if (class <= shift) geometry.anchorBit(query_key) else null;
        const rect = geometry.chunkRect(placement);
        var chunk_y = rect.min_y;
        while (chunk_y <= rect.max_y) : (chunk_y += 1) {
            var chunk_x = rect.min_x;
            while (chunk_x <= rect.max_x) : (chunk_x += 1) {
                const key = chunkKey(rect.level, chunk_y * rect.chunks_x + chunk_x);
                const query_record = if (anchor) |bit| bit.chunk_key == key else false;
                self.chunk_touches.items[cursor[chunk_tier]] = .{
                    .key = key,
                    .entity = entity,
                    // An anchor bit indexes the u16-counted anchor block.
                    .bit = if (query_record) @intCast(anchor.?.bit) else 0,
                    .insert = true,
                    .query_record = query_record,
                    .cells = placement.cells,
                    .aabb = aabb,
                };
                cursor[chunk_tier] += 1;
            }
        }
        if (class > shift) {
            self.coarse_touches.items[cursor[coarse_tier]] = .{ .key = query_key, .entity = entity, .insert = true, .aabb = aabb };
            cursor[coarse_tier] += 1;
        }
    }

    // One chunk-tier group band: its touches' chunks into items in first-touch order, each
    // with its installed block and record counts, counting each touch's insert or removal
    // (pass 1); each item's payload plan and claims and releases, insert windows, fill
    // units, and a fresh block's level marker (pass 2); then the inserts (pass 3), and the
    // band's tally. A chunk's inserts arrive in entity order. Reads the directory only.
    // SIMD verdict: scalar. Hash point lookups per touch, first-touch item creation, and a
    // cursor scatter (a data dependency on each item's cursor).
    fn groupChunkBand(self: *StaticColliderSystem, band: usize) void {
        const start = self.touch_start[chunk_tier][band];
        const count = self.touch_start[chunk_tier][band + 1] - start;
        var table = BandTable.init(self, chunk_tier, band, count);
        const items = self.chunk_items.items[start..][0..count];
        const source = ChunkTouchSort.WindowSource{ .staging = self.chunk_staging.items, .band_offsets = self.touch_band_offsets[chunk_tier].items, .window_stride = 0 };
        var item_count: u32 = 0;
        for (0..source.rangeCount()) |range_index| {
            for (source.segment(range_index, band)) |touch| {
                const claimed = table.claim(touch.key);
                if (claimed.fresh) {
                    table.slots[claimed.slot].item = item_count;
                    items[item_count] = self.chunkItemOf(touch.key);
                    item_count += 1;
                }
                const item = &items[table.slots[claimed.slot].item];
                // A removal names a record its chunk lists, so the chunk holds a block.
                std.debug.assert(touch.insert or item.old_block != empty_block);
                countChunkRecords(item, touch.insert, touch.query_record);
            }
        }
        var entries = BandEntries{ .window = self.entryWindow(chunk_tier, band), .base = self.entry_start[chunk_tier][band] };
        const level_window = self.level_entries.items[self.levelWindow(chunk_tier, band)..][0..count];
        var levels: u32 = 0;
        var nav_at = start;
        var query_at = start;
        var units: usize = 0;
        for (items[0..item_count]) |*item| {
            item.payload_plan = self.planChunkPayload(item, &entries) catch {
                self.group_tallies.items[chunk_tier * band_count + band].value = .{ .overflow = true };
                return;
            };
            item.nav_insert_at = nav_at;
            item.nav_cursor = nav_at;
            nav_at += item.nav_insert_count;
            item.query_insert_at = query_at;
            item.query_cursor = query_at;
            query_at += item.query_insert_count;
            item.unit_local = units;
            units += item.fillUnits();
            if (item.old_block == empty_block and table.claim(level_marker_bit | item.level).fresh) {
                level_window[levels] = item.level;
                levels += 1;
            }
        }
        for (0..source.rangeCount()) |range_index| {
            for (source.segment(range_index, band)) |touch| {
                if (!touch.insert) continue;
                const item = &items[table.itemOf(touch.key)];
                self.nav_inserts.items[item.nav_cursor] = .{ .entity = touch.entity, .min_x = touch.cells.min_x, .min_y = touch.cells.min_y, .max_x = touch.cells.max_x, .max_y = touch.cells.max_y };
                item.nav_cursor += 1;
                if (!touch.query_record) continue;
                self.query_inserts.items[item.query_cursor] = .{ .entity = touch.entity, .bit = touch.bit, .min_x = touch.aabb.min_x, .min_y = touch.aabb.min_y, .max_x = touch.aabb.max_x, .max_y = touch.aabb.max_y };
                item.query_cursor += 1;
            }
        }
        for (items[0..item_count]) |item| {
            std.debug.assert(item.nav_cursor == item.nav_insert_at + item.nav_insert_count);
            std.debug.assert(item.query_cursor == item.query_insert_at + item.query_insert_count);
        }
        self.group_tallies.items[chunk_tier * band_count + band].value = .{ .items = item_count, .units = units, .entries = entries.count, .levels = levels };
    }

    // One coarse-tier group band, as `groupChunkBand`: its cells' items, each item's payload
    // plan, claims and releases, insert window, fill units, and a fresh block's level
    // marker, then the inserts.
    // SIMD verdict: scalar, as `groupChunkBand`.
    fn groupCoarseBand(self: *StaticColliderSystem, band: usize) void {
        const start = self.touch_start[coarse_tier][band];
        const count = self.touch_start[coarse_tier][band + 1] - start;
        var table = BandTable.init(self, coarse_tier, band, count);
        const items = self.coarse_items.items[start..][0..count];
        const source = CoarseTouchSort.WindowSource{ .staging = self.coarse_staging.items, .band_offsets = self.touch_band_offsets[coarse_tier].items, .window_stride = 0 };
        var item_count: u32 = 0;
        for (0..source.rangeCount()) |range_index| {
            for (source.segment(range_index, band)) |touch| {
                const claimed = table.claim(touch.key);
                if (claimed.fresh) {
                    table.slots[claimed.slot].item = item_count;
                    items[item_count] = self.coarseItemOf(touch.key);
                    item_count += 1;
                }
                const item = &items[table.slots[claimed.slot].item];
                // A removal names a record its cell lists, so the cell holds a block.
                std.debug.assert(touch.insert or item.old_block != empty_block);
                if (touch.insert) item.insert_count += 1 else item.remove_count += 1;
            }
        }
        var entries = BandEntries{ .window = self.entryWindow(coarse_tier, band), .base = self.entry_start[coarse_tier][band] };
        const level_window = self.level_entries.items[self.levelWindow(coarse_tier, band)..][0..count];
        var levels: u32 = 0;
        var insert_at = start;
        var units: usize = 0;
        for (items[0..item_count]) |*item| {
            item.payload_plan = self.planCoarsePayload(item, &entries) catch {
                self.group_tallies.items[coarse_tier * band_count + band].value = .{ .overflow = true };
                return;
            };
            item.insert_at = insert_at;
            item.cursor = insert_at;
            insert_at += item.insert_count;
            item.unit_local = units;
            units += item.fillUnits();
            const level_entry = @as(u32, item.class) << 16 | item.level;
            if (item.old_block == empty_block and table.claim(level_marker_bit | level_entry).fresh) {
                level_window[levels] = level_entry;
                levels += 1;
            }
        }
        for (0..source.rangeCount()) |range_index| {
            for (source.segment(range_index, band)) |touch| {
                if (!touch.insert) continue;
                const item = &items[table.itemOf(touch.key)];
                self.coarse_inserts.items[item.cursor] = .{ .entity = touch.entity, .min_x = touch.aabb.min_x, .min_y = touch.aabb.min_y, .max_x = touch.aabb.max_x, .max_y = touch.aabb.max_y };
                item.cursor += 1;
            }
        }
        for (items[0..item_count]) |item| std.debug.assert(item.cursor == item.insert_at + item.insert_count);
        self.group_tallies.items[coarse_tier * band_count + band].value = .{ .items = item_count, .units = units, .entries = entries.count, .levels = levels };
    }

    // The item of chunk key `key`: its installed block, if any, and that block's record
    // counts.
    fn chunkItemOf(self: *const StaticColliderSystem, key: u64) ChunkItem {
        const level = keyLevel(key);
        const chunk = keyChunk(key);
        const block = self.chunks.slot(level, chunk);
        var item = ChunkItem{ .level = level, .slot = chunk, .old_block = block };
        if (block != empty_block) {
            const old = self.chunks.payloadConst(block);
            item.old_nav = old.nav_len;
            item.old_query = old.query_len;
        }
        return item;
    }

    // The item of query key `key`, as `chunkItemOf`.
    fn coarseItemOf(self: *const StaticColliderSystem, key: u64) CoarseItem {
        // A query key's class bits hold a class below 64.
        const class: u6 = @intCast((key >> 48) & 0x3f);
        const level = queryKeyLevel(key);
        const cell = keyChunk(key);
        const block = self.coarse[class].slot(level, cell);
        var item = CoarseItem{ .class = class, .level = level, .slot = cell, .old_block = block };
        if (block != empty_block) item.old_len = self.coarse[class].payloadConst(block).len;
        return item;
    }

    // An item's payload: emptied when no record remains (its block and slot released), in
    // place when its slot's columns hold the kept records plus every insert, otherwise a
    // fresh slot of the smallest class holding geometric columns, releasing the old slot,
    // or claiming a block for a chunk holding none. Each claim and release takes the next
    // ordinal of its resource in the band. Records past a u32 column's power of two fail as
    // `OutOfMemory`, which the band reports for `reservePayloads` to return.
    fn planChunkPayload(self: *const StaticColliderSystem, item: *const ChunkItem, entries: *BandEntries) error{OutOfMemory}!PayloadPlan {
        const nav_need = item.navLen();
        const query_need = item.queryLen();
        var plan = PayloadPlan{};
        if (item.old_block != empty_block) {
            const old = self.chunks.payloadConst(item.old_block);
            // Every block holding records holds a slot.
            std.debug.assert(!old.slot.isNone());
            plan.old_slot = old.slot;
            if (nav_need == 0) {
                // A query record sits in its anchor chunk, inside its row's footprint.
                std.debug.assert(query_need == 0);
                plan.kind = .emptied;
                plan.block = entries.release(chunk_directory_resource);
                plan.slot_release = entries.release(old.slot.class);
                return plan;
            }
            if (nav_need <= old.nav_cap and query_need <= old.query_cap) {
                plan.kind = .in_place;
                return plan;
            }
            plan.slot_release = entries.release(old.slot.class);
        } else {
            // A chunk with no block is listed only by an insert.
            std.debug.assert(nav_need != 0);
            plan.block = entries.claim(chunk_directory_resource);
        }
        plan.cap = try geometric(nav_need);
        plan.query_cap = try geometric(query_need);
        plan.slab_class = try PayloadSlabs.classFor(chunkPayloadBytes(plan.cap, plan.query_cap));
        plan.slot = entries.claim(plan.slab_class);
        return plan;
    }

    // A coarse item's payload, as `planChunkPayload`.
    fn planCoarsePayload(self: *const StaticColliderSystem, item: *const CoarseItem, entries: *BandEntries) error{OutOfMemory}!PayloadPlan {
        const need = item.len();
        const directory = coarseDirectoryResource(item.class);
        var plan = PayloadPlan{};
        if (item.old_block != empty_block) {
            const old = self.coarse[item.class].payloadConst(item.old_block);
            // Every block holding records holds a slot.
            std.debug.assert(!old.slot.isNone());
            plan.old_slot = old.slot;
            if (need == 0) {
                plan.kind = .emptied;
                plan.block = entries.release(directory);
                plan.slot_release = entries.release(old.slot.class);
                return plan;
            }
            if (need <= old.cap) {
                plan.kind = .in_place;
                return plan;
            }
            plan.slot_release = entries.release(old.slot.class);
        } else {
            // A cell with no block is listed only by an insert.
            std.debug.assert(need != 0);
            plan.block = entries.claim(directory);
        }
        plan.cap = try geometric(need);
        plan.slab_class = try PayloadSlabs.classFor(queryRunBytes(plan.cap));
        plan.slot = entries.claim(plan.slab_class);
        return plan;
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
        try self.relink_stamp.ensureTotalCapacity(self.allocator, index_count);
        try self.pending_dirty.ensureTotalCapacity(self.allocator, index_count);
        const added = index_count - self.row_of_index.items.len;
        self.row_of_index.appendNTimesAssumeCapacity(no_row, added);
        self.dirty_stamp.appendNTimesAssumeCapacity(0, added);
        self.dirty_entity.appendNTimesAssumeCapacity(EntityId.invalid, added);
        self.relink_stamp.appendNTimesAssumeCapacity(0, added);
    }

    // The row pool as ordinal claims: free rows newest first, then fresh rows from the
    // pool's end. The free list's capacity covers every row, so every release fits.
    fn rowIds(self: *const StaticColliderSystem) OrdinalClaims {
        return .{
            .free = self.row_free,
            // Rows stay below `no_row`.
            .next_id = @intCast(self.rows.len),
            .id_limit = @intCast(@min(self.rows.capacity, no_row - 1)),
        };
    }

    // Makes `adds` ordinal row claims fit: grows the pool's capacity, geometrically and
    // counted, and the free list's with it. Rows past the pool's length stay undefined until
    // `commitRowClaims`. A total reaching `no_row` fails as `OutOfMemory`.
    fn reserveRowClaims(self: *StaticColliderSystem, adds: usize) error{OutOfMemory}!void {
        const needed = try self.rowIds().idsNeeded(adds);
        if (needed > self.rows.capacity) {
            try self.rows.ensureTotalCapacity(self.allocator, @max(needed, self.rows.capacity *| 2));
            // The pool moved: the column views follow it before anything else can fail.
            self.refreshColumns();
            self.countRowGrowth();
        }
        try self.row_free.ensureTotalCapacity(self.allocator, self.rows.capacity);
    }

    // Takes the first `adds` row ordinals, which `touch` read: pops the free rows they took
    // and extends the pool over the fresh ones, for `apply` to write. O(1).
    fn commitRowClaims(self: *StaticColliderSystem, adds: usize) void {
        var ids = self.rowIds();
        ids.commitClaims(adds);
        self.row_free.items.len = ids.free.items.len;
        setRowCount(Row, &self.rows, ids.next_id);
        self.refreshColumns();
    }

    // Adds the `releases` rows `apply` wrote past the free list's end. O(1).
    fn commitRowReleases(self: *StaticColliderSystem, releases: usize) void {
        std.debug.assert(self.row_free.items.len + releases <= self.row_free.capacity);
        self.row_free.items.len += releases;
    }

    fn countRowGrowth(self: *StaticColliderSystem) void {
        if (comptime runtime_perf_log.enabled) self.perf.row_grows += 1;
        if (self.row_growth_logged) return;
        self.row_growth_logged = true;
        if (comptime logging.enabled(.info)) logging.game.info("static collider rows grew", .{});
    }

    fn countPayloadGrowth(self: *StaticColliderSystem, count: usize) void {
        if (count == 0) return;
        if (comptime runtime_perf_log.enabled) self.perf.payload_grows += count;
        if (self.payload_growth_logged) return;
        self.payload_growth_logged = true;
        if (comptime logging.enabled(.info)) logging.game.info("static collider chunk payloads grew", .{});
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

    /// Applies every captured change from `data`'s final state. Each stage runs on
    /// `thread_system`'s workers under its own sync tuner, or inline as one range below its
    /// gate: `plan` (each pending index's static packed by its id, its new row in lanes, and
    /// whether its rows' chunks, AABB, or query key change), `touch` (each changed index's
    /// removals from its old chunks and cells and inserts into its new ones, placed by band,
    /// and each add's claimed row), `group` (each band's chunks and cells into items, with
    /// their payload claims and releases), `apply` (the rows, `row_of_index`, row releases,
    /// and the change list), `rewrite` (the fill), and `install`. A row whose chunks, AABB,
    /// and query key are unchanged is written in place and rewrites nothing. Main holds the
    /// reserves, prefixes over ranges and bands, the claim merge, one open per level a fresh
    /// block enters, and O(1) commits per row pool, slab class, and directory. On error
    /// nothing is installed and the dirty list stays for the next sync; reserved storage
    /// stays. The change list resets on every call.
    pub fn sync(self: *StaticColliderSystem, data: *const DataSystem, thread_system: *ThreadSystem) error{OutOfMemory}!void {
        self.changes.clearRetainingCapacity();
        self.last_batches = .initFill(.{});
        if (self.pending_dirty.items.len == 0) return;
        const threads = ColliderThreads{ .thread_system = thread_system, .config = self.splice_controls };
        try self.prepareSync(data, threads);
        self.finishSync(threads);
        self.revision +%= 1;
    }

    // Every sync stage before `apply`, and every reserve: after it nothing fails. Each stage
    // scratch list a reserve grows counts as one payload growth, on error too.
    fn prepareSync(self: *StaticColliderSystem, data: *const DataSystem, threads: ColliderThreads) error{OutOfMemory}!void {
        // `plan` stamped the relinked indices.
        errdefer self.bumpRelinkGeneration();
        const before = self.syncScratchCapacities();
        defer self.countPayloadGrowth(changedCapacities(&before, &self.syncScratchCapacities()));
        const touches = try self.planSync(data, threads);
        try self.groupPending(threads, touches, self.pendingTouchSplitters());
    }

    // `plan` over the pending indices, its merge, and the row claim and change reserves:
    // each tier's touch count.
    fn planSync(self: *StaticColliderSystem, data: *const DataSystem, threads: ColliderThreads) error{OutOfMemory}!TierCounts {
        const pending = self.pending_dirty.items.len;
        try self.reserveSyncPlan(pending);
        self.planPending(data, threads, pending);
        const counts = try self.mergePendingTallies();
        try self.reserveRowClaims(counts.adds);
        try self.changes.ensureTotalCapacity(self.allocator, pending);
        return counts.touches;
    }

    // The sync's `touch` and `group` under the band `splitters` of each tier, then the
    // growth seam before `apply`, as `groupFootprints`: every row, record, and layout is the
    // same for any splitters, range size, and worker count but the block and slot ids.
    fn groupPending(self: *StaticColliderSystem, threads: ColliderThreads, touches: TierCounts, splitters: [tier_count]TouchSplitters) error{OutOfMemory}!void {
        const pending = self.plan_item_count;
        // The touch windows are sized from the selection the dispatch runs.
        const dispatch = self.syncDispatch(threads, .touch, pending);
        const shape = StageShape.select(dispatch, pending, touch_range_alignment_items);
        try self.reserveTouches(touches, shape.range_count);
        self.touch_splitters = splitters;
        self.touchFootprints(dispatch, shape, .sync);
        try self.reserveGroup(touches);
        self.groupTouches(self.syncDispatch(threads, .group, tierTotal(touches)), touches);
        try self.reservePayloads();
    }

    // The row claims `touch` read, `apply`, the fill, and the install, each with its
    // commits, then the dirty list cleared. Allocates nothing.
    fn finishSync(self: *StaticColliderSystem, threads: ColliderThreads) void {
        const pending = self.plan_item_count;
        const rows = self.pendingRowCounts();
        self.commitRowClaims(rows.adds);
        std.debug.assert(self.changes.capacity >= pending);
        self.changes.items.len = pending;
        self.applyPending(self.syncDispatch(threads, .apply, pending));
        self.commitRowReleases(rows.releases);
        self.mergeClassDeltas();
        self.rewriteItems(self.syncDispatch(threads, .rewrite, self.item_bands.unitCount()), self.resource_entries.items);
        self.commitClaims();
        self.installItems(self.syncDispatch(threads, .install, self.item_bands.itemCount()));
        self.commitReleases();
        self.finishPending();
    }

    // Sync stage `stage`'s dispatch of `item_count` items under its own tuner, or null
    // (inline) for no items: an empty stage selects nothing and touches no tuner.
    fn syncDispatch(self: *StaticColliderSystem, threads: ColliderThreads, stage: SyncStage, item_count: usize) ?Dispatch {
        if (item_count == 0) return null;
        return threads.stage(self.tuners.getPtr(stage));
    }

    // The capacities of every list a sync reserves, whose growth counts as payload growth.
    fn syncScratchCapacities(self: *const StaticColliderSystem) [23]usize {
        return .{
            self.plan_inputs.capacity,           self.sync_rows.capacity,           self.sync_plan.capacity,
            self.plan_class.capacity,            self.plan_touch_local[0].capacity, self.plan_touch_local[1].capacity,
            self.plan_tallies.capacity,          self.chunk_touches.capacity,       self.chunk_staging.capacity,
            self.coarse_touches.capacity,        self.coarse_staging.capacity,      self.touch_band_offsets[0].capacity,
            self.touch_band_offsets[1].capacity, self.group_slots.capacity,         self.group_tallies.capacity,
            self.resource_entries.capacity,      self.level_entries.capacity,       self.chunk_items.capacity,
            self.coarse_items.capacity,          self.nav_inserts.capacity,         self.query_inserts.capacity,
            self.coarse_inserts.capacity,        self.changes.capacity,
        };
    }

    // The sync plan's scratch, one entry per pending index, its columns lane-aligned.
    fn reserveSyncPlan(self: *StaticColliderSystem, pending: usize) error{OutOfMemory}!void {
        const capacity = std.mem.alignForward(usize, pending, sync_plan_range_alignment_items);
        try self.plan_inputs.ensureTotalCapacity(self.allocator, capacity);
        try self.sync_rows.ensureTotalCapacity(self.allocator, capacity);
        try self.sync_plan.ensureTotalCapacity(self.allocator, pending);
        try self.reservePlan(pending, sync_plan_range_alignment_items);
        setRowCount(PlanInput, &self.plan_inputs, pending);
        setRowCount(SyncRow, &self.sync_rows, pending);
        self.sync_plan.items.len = pending;
    }

    // `plan` over the pending indices: each one's static packed by its id, its new row in
    // lanes, the relink decision, and its range's touch, add, release, and class counts.
    fn planPending(self: *StaticColliderSystem, data: *const DataSystem, threads: ColliderThreads, pending: usize) void {
        const dispatch = self.syncDispatch(threads, .plan, pending);
        const shape = StageShape.select(dispatch, pending, sync_plan_range_alignment_items);
        std.debug.assert(shape.range_count <= self.plan_tallies.capacity);
        setSlotCount(PlanTally, &self.plan_tallies, shape.range_count);
        self.plan_item_count = pending;
        self.plan_items_per_range = shape.items_per_range;
        var job = SyncPlanJob{
            .colliders = self,
            .data = data,
            .columns = data.staticObstacleColumns(),
            .inputs = PlanColumns.of(&self.plan_inputs),
            .outputs = LaneOutputs.ofSyncRows(&self.sync_rows),
        };
        self.last_batches.set(.plan, runShaped(dispatch, shape, pending, sync_plan_range_alignment_items, &job, syncPlanJob));
    }

    // Packs pending indices `[start, end)`: each one's static through its captured id, or
    // `no_obstacle` (an invalid entity) when the id no longer names a static.
    // SIMD verdict: scalar. One point read per store per pending index: sparse maintenance
    // over the changed set, the one gather that packs the lanes' inputs.
    fn packPending(self: *const StaticColliderSystem, data: *const DataSystem, columns: StaticObstacleColumns, inputs: PlanColumns, start: usize, end: usize) void {
        for (start..end) |at| {
            const index = self.pending_dirty.items[at];
            inputs.put(at, data.staticObstacle(self.dirty_entity.items[index], columns) orelse no_obstacle);
        }
    }

    // The sync's decision over pending indices `[start, end)`: each one's old row, its new
    // row from the lanes' output, whether its chunks, AABB, or query key change (a relink,
    // stamped so the fill drops its records), its touches' offsets in its range (over the
    // new row's counts the lanes stored), its add or release ordinal there, and its range's
    // touch, add, release, and class counts.
    // SIMD verdict: scalar. Point reads of each index's old row and a branchy relink
    // decision (sparse maintenance over the changed set), with a running prefix.
    fn decidePending(self: *StaticColliderSystem, inputs: PlanColumns, outputs: LaneOutputs, start: usize, end: usize, tally: *PlanTally) void {
        const geometry = self.geometry.?;
        const shift = geometry.grid.shift;
        var running: [tier_count]u64 = @splat(0);
        for (start..end) |at| {
            const index = self.pending_dirty.items[at];
            const old_row = self.row_of_index.items[index];
            const has_new = inputs.entity[at].isValid();
            var plan = SyncPlan{ .old_row = old_row, .row = if (has_new) old_row else no_row, .has_new = has_new };
            var old_aabb: math.Aabb = no_aabb;
            if (old_row != no_row) {
                const placement = self.rowPlacement(old_row);
                old_aabb = self.rowAabb(old_row);
                plan.old = .{ .level = placement.level, .cells = placement.cells, .aabb = old_aabb };
                plan.old_rect = geometry.chunkRect(placement);
                plan.old_query = self.queryPlacement(placement, old_aabb);
            }
            // The lanes' counts of the new row's touches.
            var touches: [tier_count]u64 = .{ self.plan_touch_local[chunk_tier].items[at], self.plan_touch_local[coarse_tier].items[at] };
            var new_class: ?u6 = null;
            if (has_new) {
                // A query class fits u6.
                const class: u6 = @intCast(self.plan_class.items[at]);
                new_class = class;
                const placement = outputs.placement(inputs.level[at], at);
                const key = geometry.queryKey(placement.level, class, placement.cells);
                plan.relink = if (plan.old_rect) |old_rect| !(old_rect.eql(geometry.chunkRect(placement)) and plan.old_query.?.key == key and std.meta.eql(old_aabb, outputs.aabb(at))) else true;
                if (old_row == no_row) {
                    // Adds stay below the pending count, under u32.
                    plan.add_local = tally.adds;
                    tally.adds += 1;
                }
            } else {
                plan.relink = old_row != no_row;
                touches = @splat(0);
                if (old_row != no_row) {
                    plan.release_local = tally.releases;
                    tally.releases += 1;
                }
            }
            if (plan.old_query) |old| {
                if (new_class == null or new_class.? != old.class) tally.class_delta[old.class] -= 1;
            }
            if (new_class) |class| {
                if (plan.old_query == null or plan.old_query.?.class != class) tally.class_delta[class] += 1;
            }
            if (plan.relink) {
                self.relink_stamp.items[index] = self.relink_generation;
                if (plan.old_rect) |old_rect| {
                    touches[chunk_tier] += old_rect.count();
                    touches[coarse_tier] += @intFromBool(plan.old_query.?.class > shift);
                }
            } else touches = @splat(0);
            for (&self.plan_touch_local, &running, touches) |*local, *total, count| {
                // Read only once the main thread's merge keeps the total below 2^31.
                local.items[at] = @truncate(total.*);
                total.* += count;
            }
            self.sync_plan.items[at] = plan;
        }
        tally.touches = running;
    }

    // Each sync plan range's touch bases in each tier and its add and release bases, in
    // range order. A total of 2^31 touches or more fails as `OutOfMemory`. O(ranges).
    fn mergePendingTallies(self: *StaticColliderSystem) error{OutOfMemory}!PendingCounts {
        var totals: [tier_count]u64 = @splat(0);
        for (self.plan_tallies.items) |slot| {
            for (&totals, slot.value.touches) |*total, touches| total.* += touches;
        }
        if (totals[chunk_tier] + totals[coarse_tier] >= max_touches) return error.OutOfMemory;
        var counts = PendingCounts{};
        for (self.plan_tallies.items) |*slot| {
            const tally = &slot.value;
            tally.bases = counts.touches;
            // Below the checked total.
            for (&counts.touches, tally.touches) |*base, touches| base.* += @intCast(touches);
            tally.add_base = counts.adds;
            counts.adds += tally.adds;
            tally.release_base = counts.releases;
            counts.releases += tally.releases;
        }
        return counts;
    }

    // The sync's adds and releases: the last plan range's bases plus its counts.
    fn pendingRowCounts(self: *const StaticColliderSystem) struct { adds: usize, releases: usize } {
        const last = self.plan_tallies.items[self.plan_tallies.items.len - 1].value;
        return .{ .adds = @as(usize, last.add_base) + last.adds, .releases = @as(usize, last.release_base) + last.releases };
    }

    // The band splitters of each tier over the sync's touches, as `touchSplitters`: the band
    // quantiles of the first touch keys of a fixed sample of pending indices, skipping one
    // without a touch in the tier. Fixed work on main.
    fn pendingTouchSplitters(self: *StaticColliderSystem) [tier_count]TouchSplitters {
        const geometry = self.geometry.?;
        const shift = geometry.grid.shift;
        const pending = self.plan_item_count;
        const inputs = PlanColumns.of(&self.plan_inputs);
        const outputs = LaneOutputs.ofSyncRows(&self.sync_rows);
        var chunk_samples: [banded_sort.splitter_sample_count]u64 = undefined;
        var coarse_samples: [banded_sort.splitter_sample_count]u64 = undefined;
        var chunk_count: usize = 0;
        var coarse_count: usize = 0;
        for (0..banded_sort.sampleCount(pending)) |sample| {
            const at = banded_sort.sampleSlot(sample, pending);
            const plan = self.sync_plan.items[at];
            if (!plan.relink) continue;
            const new_placement: ?Placement = if (plan.has_new) outputs.placement(inputs.level[at], at) else null;
            const rect = plan.old_rect orelse geometry.chunkRect(new_placement.?);
            chunk_samples[chunk_count] = chunkKey(rect.level, rect.min_y * rect.chunks_x + rect.min_x);
            chunk_count += 1;
            if (plan.old_query) |old| if (old.class > shift) {
                coarse_samples[coarse_count] = old.key;
                coarse_count += 1;
                continue;
            };
            const placement = new_placement orelse continue;
            // A query class fits u6.
            const class: u6 = @intCast(self.plan_class.items[at]);
            if (class <= shift) continue;
            coarse_samples[coarse_count] = geometry.queryKey(placement.level, class, placement.cells);
            coarse_count += 1;
        }
        return .{
            ChunkTouchSort.splittersFromSamples(chunk_samples[0..chunk_count]),
            CoarseTouchSort.splittersFromSamples(coarse_samples[0..coarse_count]),
        };
    }

    // `apply` under `dispatch` over the pending indices.
    fn applyPending(self: *StaticColliderSystem, dispatch: ?Dispatch) void {
        const pending = self.plan_item_count;
        const shape = StageShape.select(dispatch, pending, apply_range_alignment_items);
        var job = ApplyJob{ .colliders = self, .inputs = PlanColumns.of(&self.plan_inputs), .outputs = LaneOutputs.ofSyncRows(&self.sync_rows), .range_count = shape.range_count };
        self.last_batches.set(.apply, runShaped(dispatch, shape, pending, apply_range_alignment_items, &job, applyJob));
    }

    // Pending indices `[start, end)`: each one's new row written at its row (its old row, or
    // its add's claimed one) with its `row_of_index` entry, or its old row released at its
    // position past the free list's end; and its change.
    // SIMD verdict: scalar. Scattered writes at each index's row, entry, and release
    // position: sparse maintenance over the changed set.
    fn applyRange(self: *StaticColliderSystem, inputs: PlanColumns, outputs: LaneOutputs, start: usize, end: usize) void {
        const rows = self.rowIds();
        for (start..end) |at| {
            const plan = self.sync_plan.items[at];
            const index = self.pending_dirty.items[at];
            var change = ColliderChange{ .entity = self.dirty_entity.items[index], .old = plan.old, .new = null };
            if (plan.has_new) {
                const placement = outputs.placement(inputs.level[at], at);
                std.debug.assert(plan.row < self.rows.len);
                self.writeRow(plan.row, inputs.entity[at], placement, outputs.aabb(at));
                self.row_of_index.items[index] = plan.row;
                change.new = placement;
            } else if (plan.old_row != no_row) {
                const tally = self.plan_tallies.items[at / self.plan_items_per_range].value;
                rows.releaseAt(@as(usize, tally.release_base) + plan.release_local, plan.old_row);
                self.row_of_index.items[index] = no_row;
            }
            self.changes.items[at] = change;
        }
    }

    // Adds each plan range's class deltas to the rows per class, in range order. O(ranges *
    // classes).
    fn mergeClassDeltas(self: *StaticColliderSystem) void {
        for (self.plan_tallies.items) |slot| {
            for (&self.query_class_rows, slot.value.class_delta) |*rows, delta| {
                // A range removes only rows its class holds, so every prefix stays non-negative.
                const total = @as(i64, rows.*) + delta;
                std.debug.assert(total >= 0);
                rows.* = @intCast(total);
            }
        }
        self.refreshQueryClassMask();
    }

    // The chunk rewrite stage: one dispatch fills every planned chunk and coarse item
    // (`item_bands`) under `dispatch`, or inline as one range without one. `entries` holds
    // the claim bases the items' ordinals are relative to.
    fn rewriteItems(self: *StaticColliderSystem, dispatch: ?Dispatch, entries: []const ResourceEntry) void {
        const units = self.item_bands.unitCount();
        if (units == 0) return;
        var job = RewriteJob{ .colliders = self, .entries = entries, .range_count = 0 };
        const shape = StageShape.select(dispatch, units, splice_range_alignment_items);
        job.range_count = shape.range_count;
        self.last_batches.set(.rewrite, runShaped(dispatch, shape, units, splice_range_alignment_items, &job, rewriteJob));
    }

    // Reserves `claims` ordinal block claims in `dir`. A grown block pool counts as one
    // payload growth from the capacity before the reserve, on error too, as the slabs do.
    fn reserveBlocks(self: *StaticColliderSystem, dir: anytype, claims: u32) error{OutOfMemory}!void {
        if (claims == 0) return;
        const before = dir.blocks.capacity;
        defer if (dir.blocks.capacity != before) self.countPayloadGrowth(1);
        try dir.reserveClaims(self.allocator, claims);
    }

    // The call's claims, once the fill has read them. O(classes and directories used).
    fn commitClaims(self: *StaticColliderSystem) void {
        const tally = &self.claim_tally;
        var classes = tally.slot_classes.iterator(.{});
        while (classes.next()) |class| self.payloads.commitClaims(@intCast(class), tally.slot_claims[class]);
        self.chunks.commitClaims(tally.chunk_blocks.claims);
        var directories = tally.coarse_classes.iterator(.{});
        while (directories.next()) |class| self.coarse[class].commitClaims(tally.coarse_blocks[class].claims);
    }

    // The call's releases, once install has written them. O(classes and directories used).
    fn commitReleases(self: *StaticColliderSystem) void {
        const tally = &self.claim_tally;
        var classes = tally.slot_classes.iterator(.{});
        while (classes.next()) |class| self.payloads.commitReleases(@intCast(class), tally.slot_releases[class]);
        self.chunks.commitReleases(tally.chunk_blocks.releases);
        var directories = tally.coarse_classes.iterator(.{});
        while (directories.next()) |class| self.coarse[class].commitReleases(tally.coarse_blocks[class].releases);
    }

    // Writes the item's descriptor in its block: an in-place item's live one; a replacing
    // item's old block, after reading its old columns; a fresh chunk's claimed block,
    // written whole. A fresh slot or block is the claim at its entry's base in `entries` plus
    // its ordinal there. An emptied item writes nothing; install releases its block and slot.
    fn fillChunkItem(self: *StaticColliderSystem, index: usize, entries: []const ResourceEntry) void {
        const item = &self.chunk_items.items[index];
        const plan = item.payload_plan;
        if (plan.kind == .emptied) return;
        const nav = self.nav_inserts.items[item.nav_insert_at..][0..item.nav_insert_count];
        const query = self.query_inserts.items[item.query_insert_at..][0..item.query_insert_count];
        pdq(SpanInsert, nav, {}, spanLess);
        pdq(AabbInsert, query, {}, aabbLess);
        const stamps = self.relink_stamp.items;
        const generation = self.relink_generation;
        const payload = switch (plan.kind) {
            .emptied => unreachable,
            .in_place => in_place: {
                const live = self.chunks.payloadMut(item.old_block);
                live.nav_len = rewriteRecords(NavRecords, .of(live), .of(live), live.nav_len, nav, stamps, generation, true);
                live.query_len = rewriteRecords(QueryRecords, .of(live), .of(live), live.query_len, query, stamps, generation, true);
                break :in_place live;
            },
            .fresh_slot => fresh: {
                const slot = PayloadSlot{ .class = plan.slab_class, .id = self.payloads.claimedId(plan.slab_class, plan.slot.claimOrdinal(entries)) };
                const columns = splitChunk(self.payloads.bytesOf(slot), slot, plan.cap, plan.query_cap);
                var old_nav = NavRecords.of(&empty_chunk);
                var old_query = QueryRecords.of(&empty_chunk);
                var old_nav_len: u32 = 0;
                var old_query_len: u32 = 0;
                const target = if (item.old_block == empty_block) claimed: {
                    item.block = self.chunks.claimedBlock(plan.block.claimOrdinal(entries));
                    break :claimed self.chunks.writeClaimed(item.block, columns);
                } else replaced: {
                    const live = self.chunks.payloadMut(item.old_block);
                    old_nav = .of(live);
                    old_query = .of(live);
                    old_nav_len = live.nav_len;
                    old_query_len = live.query_len;
                    live.* = columns;
                    break :replaced live;
                };
                target.nav_len = mergeForward(NavRecords, .of(target), old_nav, old_nav_len, nav, stamps, generation);
                target.query_len = mergeForward(QueryRecords, .of(target), old_query, old_query_len, query, stamps, generation);
                break :fresh target;
            },
        };
        std.debug.assert(payload.nav_len == item.navLen() and payload.query_len == item.queryLen());
        emitGroups(payload);
    }

    fn fillCoarseItem(self: *StaticColliderSystem, index: usize, entries: []const ResourceEntry) void {
        const item = &self.coarse_items.items[index];
        const plan = item.payload_plan;
        if (plan.kind == .emptied) return;
        const dir = &self.coarse[item.class];
        const inserts = self.coarse_inserts.items[item.insert_at..][0..item.insert_count];
        pdq(AabbInsert, inserts, {}, entityLess);
        const stamps = self.relink_stamp.items;
        const generation = self.relink_generation;
        const run = switch (plan.kind) {
            .emptied => unreachable,
            .in_place => in_place: {
                const live = dir.payloadMut(item.old_block);
                live.len = rewriteRecords(RunRecords, .of(live), .of(live), live.len, inserts, stamps, generation, true);
                break :in_place live;
            },
            .fresh_slot => fresh: {
                const slot = PayloadSlot{ .class = plan.slab_class, .id = self.payloads.claimedId(plan.slab_class, plan.slot.claimOrdinal(entries)) };
                const columns = splitQueryRun(self.payloads.bytesOf(slot), slot, plan.cap);
                var old = RunRecords.of(&empty_run);
                var old_len: u32 = 0;
                const target = if (item.old_block == empty_block) claimed: {
                    item.block = dir.claimedBlock(plan.block.claimOrdinal(entries));
                    break :claimed dir.writeClaimed(item.block, columns);
                } else replaced: {
                    const live = dir.payloadMut(item.old_block);
                    old = .of(live);
                    old_len = live.len;
                    live.* = columns;
                    break :replaced live;
                };
                target.len = mergeForward(RunRecords, .of(target), old, old_len, inserts, stamps, generation);
                break :fresh target;
            },
        };
        std.debug.assert(run.len == item.len());
    }

    // Clears the applied dirty list and retires the call's relink stamps.
    fn finishPending(self: *StaticColliderSystem) void {
        self.pending_dirty.clearRetainingCapacity();
        self.dirty_generation +%= 1;
        if (self.dirty_generation == 0) {
            @memset(self.dirty_stamp.items, 0);
            self.dirty_generation = 1;
        }
        self.bumpRelinkGeneration();
    }

    fn bumpRelinkGeneration(self: *StaticColliderSystem) void {
        self.relink_generation +%= 1;
        if (self.relink_generation == 0) {
            @memset(self.relink_stamp.items, 0);
            self.relink_generation = 1;
        }
    }

    // `level`'s chunk directory, opened once; an opening counts as payload growth.
    fn openChunkLevel(self: *StaticColliderSystem, level: u16) error{OutOfMemory}!void {
        const slot_count = self.geometry.?.grid.chunkCount();
        const before = self.chunks.slotCount(level);
        try self.chunks.openLevel(self.allocator, level, slot_count);
        if (self.chunks.slotCount(level) != before) self.countPayloadGrowth(1);
    }

    // Class `class`'s coarse directory of `level`, opened once; an opening counts as payload
    // growth. A level whose class cells reach `empty_block` fails as `OutOfMemory`.
    fn openCoarseLevel(self: *StaticColliderSystem, class: u6, level: u16) error{OutOfMemory}!void {
        const slot_count = try self.coarseSlotCount(class);
        const before = self.coarse[class].slotCount(level);
        try self.coarse[class].openLevel(self.allocator, level, slot_count);
        if (self.coarse[class].slotCount(level) != before) self.countPayloadGrowth(1);
    }

    fn coarseSlotCount(self: *const StaticColliderSystem, class: u6) error{OutOfMemory}!usize {
        const geometry = self.geometry.?;
        const count = geometry.classCellsX(class) * geometry.classCellsY(class);
        if (count >= empty_block) return error.OutOfMemory;
        // Below `empty_block`.
        return @intCast(count);
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
};

// One pending index's sync plan, from `plan` (`row` of an add from `touch`).
const SyncPlan = struct {
    // Its row before the sync, or `no_row`.
    old_row: u32,
    // Its row after: the old row, an add's claimed row, or `no_row`.
    row: u32,
    // Whether it is a static now; its new row is its `sync_rows` entry.
    has_new: bool,
    // Whether its rows' chunks, AABB, or query key change, so the chunks and cells of both
    // rewrite it.
    relink: bool = false,
    // The old row's placement and box, chunk rect, and query class and key.
    old: ?OldPlacement = null,
    old_rect: ?ChunkRect = null,
    old_query: ?QueryPlacement = null,
    // An add's claim ordinal and a release's position past its plan range's base.
    add_local: u32 = 0,
    release_local: u32 = 0,
};

// A sync's touches per tier, adds, and releases.
const PendingCounts = struct {
    touches: TierCounts = @splat(0),
    adds: u32 = 0,
    releases: u32 = 0,
};

// The new row of each pending index: the plan lanes' AABB and cells. Its entity and level
// are its packed input's.
const SyncRow = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
    cell_min_x: u32,
    cell_min_y: u32,
    cell_max_x: u32,
    cell_max_y: u32,
};

// The plan lanes' output columns: a rebuild's rows, or a sync's `sync_rows`.
const LaneOutputs = struct {
    min_x: []f32,
    min_y: []f32,
    max_x: []f32,
    max_y: []f32,
    cell_min_x: []u32,
    cell_min_y: []u32,
    cell_max_x: []u32,
    cell_max_y: []u32,

    fn ofSyncRows(rows: *std.MultiArrayList(SyncRow)) LaneOutputs {
        const columns = rows.slice();
        return .{
            .min_x = columns.items(.min_x),
            .min_y = columns.items(.min_y),
            .max_x = columns.items(.max_x),
            .max_y = columns.items(.max_y),
            .cell_min_x = columns.items(.cell_min_x),
            .cell_min_y = columns.items(.cell_min_y),
            .cell_max_x = columns.items(.cell_max_x),
            .cell_max_y = columns.items(.cell_max_y),
        };
    }

    // Item `at`'s placement on `level`.
    fn placement(self: LaneOutputs, level: u16, at: usize) Placement {
        return .{ .level = level, .cells = .{ .min_x = self.cell_min_x[at], .min_y = self.cell_min_y[at], .max_x = self.cell_max_x[at], .max_y = self.cell_max_y[at] } };
    }

    fn aabb(self: LaneOutputs, at: usize) math.Aabb {
        return .{ .min_x = self.min_x[at], .min_y = self.min_y[at], .max_x = self.max_x[at], .max_y = self.max_y[at] };
    }
};

// A pending index whose id names no static: packed with an invalid entity, its other inputs
// zero so the lanes stay finite.
const no_obstacle = PlanInput{ .entity = EntityId.invalid, .level = 0, .x = 0, .y = 0, .offset_x = 0, .offset_y = 0, .size_x = 0, .size_y = 0 };
// A removal touch's unused footprint and AABB.
const no_cells = CellSpan{ .min_x = 0, .min_y = 0, .max_x = 0, .max_y = 0 };
const no_aabb = math.Aabb{ .min_x = 0, .min_y = 0, .max_x = 0, .max_y = 0 };

const SpanInsert = struct {
    entity: u32,
    min_x: u32,
    min_y: u32,
    max_x: u32,
    max_y: u32,
};

const AabbInsert = struct {
    entity: u32,
    bit: u16 = 0,
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
};

// One claim or release of a group band: its resource entry's index in `resource_entries`
// and its ordinal among the entry's claims or releases.
const EntryOrdinal = struct {
    entry: u32 = 0,
    ordinal: u32 = 0,

    // The claim's ordinal in its resource: the entry's claim base plus its own.
    fn claimOrdinal(self: EntryOrdinal, entries: []const ResourceEntry) usize {
        return @as(usize, entries[self.entry].claim_base) + self.ordinal;
    }

    // The release's position past its resource's free list: the entry's release base plus
    // its own.
    fn releasePosition(self: EntryOrdinal, entries: []const ResourceEntry) usize {
        return @as(usize, entries[self.entry].release_base) + self.ordinal;
    }
};

// How the fill and install treat one item's payload, planned by the group.
const PayloadPlan = struct {
    kind: enum { fresh_slot, in_place, emptied } = .fresh_slot,
    // The installed payload's slot, released when the item replaces or empties it.
    old_slot: PayloadSlot = .none,
    // A fresh slot's class and its column capacities: nav (or a coarse run's) and query.
    slab_class: u8 = 0,
    cap: u32 = 0,
    query_cap: u32 = 0,
    // A fresh slot's claim in its class, and the old slot's release in its own.
    slot: EntryOrdinal = .{},
    slot_release: EntryOrdinal = .{},
    // In the directory: the block claim of an item with no block, or the old block's
    // release when emptied.
    block: EntryOrdinal = .{},
};

// One resource's claims and releases in one group band, and, from the main thread's merge,
// the bases of their ordinals and positions in the resource.
const ResourceEntry = struct {
    resource: u16 = 0,
    claims: u32 = 0,
    releases: u32 = 0,
    claim_base: u32 = 0,
    release_base: u32 = 0,
};

// Resource ids of a call's claims: each payload slab class, then the chunk directory, then
// each coarse class's directory.
const chunk_directory_resource: u16 = max_payload_classes;
const resource_count: usize = max_payload_classes + 1 + max_query_classes;

fn coarseDirectoryResource(class: u6) u16 {
    return chunk_directory_resource + 1 + @as(u16, class);
}

// One call's claim and release totals per payload slab class and per directory, from the
// main thread's merge, committed after the fill and the install.
const ClaimTally = struct {
    slot_claims: [max_payload_classes]u32 = @splat(0),
    slot_releases: [max_payload_classes]u32 = @splat(0),
    // Slab classes with a claim or a release this call.
    slot_classes: std.StaticBitSet(max_payload_classes) = .empty,
    chunk_blocks: BlockTally = .{},
    coarse_blocks: [max_query_classes]BlockTally = @splat(.{}),
    // Coarse directories with a claim or a release this call.
    coarse_classes: QueryClassMask = .empty,
};

const BlockTally = struct {
    claims: u32 = 0,
    releases: u32 = 0,
};

// Installs one planned item into `dir`: a fresh block's slot, or the planned releases at
// their positions (`entries`).
fn installItem(comptime Dir: type, dir: *Dir, payloads: *const PayloadSlabs, entries: []const ResourceEntry, level: u16, slot: u32, old_block: u32, block: u32, plan: PayloadPlan) void {
    switch (plan.kind) {
        .in_place => {},
        .emptied => {
            dir.setSlot(level, slot, empty_block);
            dir.releaseBlockAt(plan.block.releasePosition(entries), old_block);
            payloads.releaseAt(plan.old_slot, plan.slot_release.releasePosition(entries));
        },
        .fresh_slot => if (old_block == empty_block) {
            dir.setSlot(level, slot, block);
        } else payloads.releaseAt(plan.old_slot, plan.slot_release.releasePosition(entries)),
    }
}

const ChunkItem = struct {
    level: u16,
    slot: u32,
    // The item's first fill unit past its band's (`ItemBands.unit_start`).
    unit_local: usize = 0,
    old_block: u32 = empty_block,
    // The claimed block of an item with no block, resolved by the fill.
    block: u32 = empty_block,
    payload_plan: PayloadPlan = .{},
    old_nav: u32 = 0,
    old_query: u32 = 0,
    nav_insert_at: u32 = 0,
    nav_insert_count: u32 = 0,
    nav_cursor: u32 = 0,
    query_insert_at: u32 = 0,
    query_insert_count: u32 = 0,
    query_cursor: u32 = 0,
    // Listed records of relinked rows, which the rewrite drops.
    nav_remove_count: u32 = 0,
    query_remove_count: u32 = 0,

    // The rewritten lengths: kept old records plus inserts.
    fn navLen(self: ChunkItem) usize {
        std.debug.assert(self.nav_remove_count <= self.old_nav);
        return @as(usize, self.old_nav - self.nav_remove_count) + self.nav_insert_count;
    }

    fn queryLen(self: ChunkItem) usize {
        std.debug.assert(self.query_remove_count <= self.old_query);
        return @as(usize, self.old_query - self.query_remove_count) + self.query_insert_count;
    }

    // The fill's work units once planned: its old records and inserts plus one; an emptied
    // item's fill returns at once, so it is one.
    fn fillUnits(self: ChunkItem) usize {
        if (self.payload_plan.kind == .emptied) return 1;
        return @as(usize, self.old_nav) + self.nav_insert_count + self.old_query + self.query_insert_count + 1;
    }
};

// One touch of `item`: an insert, or a removal of a listed record, of a nav span and,
// for `query_record`, its query record.
fn countChunkRecords(item: *ChunkItem, insert: bool, query_record: bool) void {
    if (insert) {
        item.nav_insert_count += 1;
        item.query_insert_count += @intFromBool(query_record);
    } else {
        item.nav_remove_count += 1;
        item.query_remove_count += @intFromBool(query_record);
    }
}

const CoarseItem = struct {
    class: u6,
    level: u16,
    slot: u32,
    // The item's first fill unit past its band's (`ItemBands.unit_start`).
    unit_local: usize = 0,
    old_block: u32 = empty_block,
    // The claimed block of an item with no block, resolved by the fill.
    block: u32 = empty_block,
    payload_plan: PayloadPlan = .{},
    old_len: u32 = 0,
    insert_at: u32 = 0,
    insert_count: u32 = 0,
    cursor: u32 = 0,
    // Listed records of relinked rows, which the rewrite drops.
    remove_count: u32 = 0,

    // The rewritten length: kept old records plus inserts.
    fn len(self: CoarseItem) usize {
        std.debug.assert(self.remove_count <= self.old_len);
        return @as(usize, self.old_len - self.remove_count) + self.insert_count;
    }

    // The fill's work units once planned, as `ChunkItem.fillUnits`.
    fn fillUnits(self: CoarseItem) usize {
        if (self.payload_plan.kind == .emptied) return 1;
        return @as(usize, self.old_len) + self.insert_count + 1;
    }
};

const RewriteJob = struct {
    colliders: *StaticColliderSystem,
    entries: []const ResourceEntry,
    range_count: usize,
};

// A range fills every item whose first unit lies in it, tier by tier.
fn rewriteJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *RewriteJob = @ptrCast(@alignCast(context));
    const colliders = job.colliders;
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= colliders.item_bands.unitCount());
    fillTierRange(ChunkItem, colliders, colliders.chunk_items.items, chunk_tier, range, job.entries, StaticColliderSystem.fillChunkItem);
    fillTierRange(CoarseItem, colliders, colliders.coarse_items.items, coarse_tier, range, job.entries, StaticColliderSystem.fillCoarseItem);
}

// Fills `tier`'s items whose first unit lies in `range`: the band holding the range's first
// unit (`upperBound` over the band starts), its first such item (`lowerBound` over the band's
// unit offsets), then on in band order. O(log bands + log items) to locate.
fn fillTierRange(
    comptime Item: type,
    colliders: *StaticColliderSystem,
    items: []const Item,
    tier: usize,
    range: ParallelRange,
    entries: []const ResourceEntry,
    comptime fill: fn (*StaticColliderSystem, usize, []const ResourceEntry) void,
) void {
    const bands = &colliders.item_bands;
    const starts = &bands.unit_start[tier];
    if (range.start >= starts[band_count] or range.end <= starts[0]) return;
    const first_unit = @max(range.start, starts[0]);
    // `starts[0] <= first_unit < starts[band_count]`, so the bound lies in `[1, band_count]`.
    var band = std.sort.upperBound(usize, starts[0..band_count], first_unit, orderUnit) - 1;
    var local = firstItemFrom(Item, bands.bandItems(Item, items, tier, band), first_unit - starts[band]);
    while (band < band_count) : ({
        band += 1;
        local = 0;
    }) {
        const band_items = bands.bandItems(Item, items, tier, band);
        while (local < band_items.len) : (local += 1) {
            if (starts[band] + band_items[local].unit_local >= range.end) return;
            fill(colliders, bands.band_base[tier][band] + local, entries);
        }
    }
}

fn orderUnit(unit: usize, start: usize) std.math.Order {
    return std.math.order(unit, start);
}

// The first of `items` (ascending in `unit_local`) whose first unit is at or past `unit`.
// Hand-rolled: std's bounds pass each item by value, a whole-struct read racing the other
// ranges' fills of the fields they own; this reads `unit_local` alone.
fn firstItemFrom(comptime Item: type, items: []const Item, unit: usize) usize {
    var low: usize = 0;
    var high: usize = items.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (items[middle].unit_local < unit) low = middle + 1 else high = middle;
    }
    return low;
}

// The touch tiers: footprint chunks, and coarse query cells.
const tier_count: usize = 2;
const chunk_tier: usize = 0;
const coarse_tier: usize = 1;
// A count per tier.
const TierCounts = [tier_count]u32;

// A rebuild's or sync's touches stay below this, so every touch, item, insert, and entry
// index fits u32. A total at it fails as `OutOfMemory`; unreachable, as the touch scratch
// alone would pass 100 GB.
const max_touches: u64 = 1 << 31;
// Resource entries per touch of a band's window: each item claims or releases in at most
// three resources (a fresh slot's class, the old slot's class, and its directory), and a
// band has at most one item per touch.
const entries_per_touch: usize = 3;
// The resources a tier's items use: every slab class, and the chunk directory or each coarse
// class's.
const tier_resource_count = [tier_count]usize{ max_payload_classes + 1, max_payload_classes + max_query_classes };

// Both tiers' touches.
fn tierTotal(touches: TierCounts) usize {
    return @as(usize, touches[chunk_tier]) + touches[coarse_tier];
}

// The range alignment of a stage writing per-item elements of the `rows`' columns and of the
// `elements` types: each range spans at least a cache line of its narrowest written column,
// and at least one lane batch.
fn stageAlignment(comptime rows: []const type, comptime elements: []const type) usize {
    comptime {
        const line = thread_shared_record_alignment;
        var narrowest: usize = line;
        for (rows) |Columns| {
            for (@typeInfo(Columns).@"struct".field_types) |Column| narrowest = @min(narrowest, @as(usize, @sizeOf(Column)));
        }
        for (elements) |Element| narrowest = @min(narrowest, @as(usize, @sizeOf(Element)));
        const items: usize = @max(simd.lane_count, (line + narrowest - 1) / narrowest);
        for (rows) |Columns| {
            for (@typeInfo(Columns).@"struct".field_types) |Column| std.debug.assert(items * @as(usize, @sizeOf(Column)) >= line);
        }
        for (elements) |Element| std.debug.assert(items * @as(usize, @sizeOf(Element)) >= line);
        return items;
    }
}

/// Each rebuild stage's range alignment, from the narrowest column it writes per item
/// (`stageAlignment`): `select` writes the packed plan inputs; `plan` the rows,
/// `row_of_index`, the query class, and the touch offsets; `touch` each tier's touches, a
/// variable count per rank, so each range's windows start their own cache lines
/// (`touchWindowStart`) and the alignment is the lane batch the elements give; `group` the
/// key table, items, inserts, resource and level entries; `rewrite` the payloads, at the
/// splice's; `install` the directory slots.
pub const rebuild_range_alignment = std.EnumArray(RebuildStage, usize).init(.{
    .select = stageAlignment(&.{PlanInput}, &.{}),
    .plan = stageAlignment(&.{Row}, &.{ u32, u16 }),
    .touch = stageAlignment(&.{}, &.{ ChunkTouch, CoarseTouch }),
    .group = stageAlignment(&.{}, &.{ GroupSlot, ChunkItem, CoarseItem, SpanInsert, AabbInsert, ResourceEntry, u32 }),
    .rewrite = splice_range_alignment_items,
    .install = stageAlignment(&.{}, &.{u32}),
});
/// Each sync stage's range alignment, as `rebuild_range_alignment`: `plan` writes the packed
/// inputs (an invalid entity marks a pending index that is no static, so no u8 flag column
/// narrows the range), the new rows, the touch offsets, the query class, and the plans;
/// `touch` as the rebuild's, plus each add's row in its plan; `apply` the changes (rows,
/// `row_of_index`, and row releases are scattered writes at changed indices); `group`,
/// `rewrite`, and `install` as the rebuild's.
pub const sync_range_alignment = std.EnumArray(SyncStage, usize).init(.{
    .plan = stageAlignment(&.{ PlanInput, SyncRow }, &.{ u32, u16, SyncPlan }),
    .touch = stageAlignment(&.{}, &.{ ChunkTouch, CoarseTouch, SyncPlan }),
    .group = rebuild_range_alignment.get(.group),
    .apply = stageAlignment(&.{}, &.{ColliderChange}),
    .rewrite = splice_range_alignment_items,
    .install = rebuild_range_alignment.get(.install),
});
const sync_plan_range_alignment_items = sync_range_alignment.get(.plan);
const apply_range_alignment_items = sync_range_alignment.get(.apply);
const select_range_alignment_items = rebuild_range_alignment.get(.select);
const plan_range_alignment_items = rebuild_range_alignment.get(.plan);
const touch_range_alignment_items = rebuild_range_alignment.get(.touch);
const group_range_alignment_items = rebuild_range_alignment.get(.group);
const install_range_alignment_items = rebuild_range_alignment.get(.install);

comptime {
    // The plan lanes read the select's windows whole, and both stages step whole lane batches.
    std.debug.assert(select_range_alignment_items % simd.lane_count == 0);
    std.debug.assert(plan_range_alignment_items % simd.lane_count == 0);
    std.debug.assert(sync_plan_range_alignment_items % simd.lane_count == 0);
    // The rebuild's and the sync's touch stages share one dispatch path.
    std.debug.assert(sync_range_alignment.get(.touch) == touch_range_alignment_items);
}

// One static's packed plan input: its entity, level, and AABB inputs.
const PlanInput = StaticObstacle;

// `plan_inputs`' columns, sliced once per stage.
const PlanColumns = struct {
    entity: []EntityId,
    level: []u16,
    x: []f32,
    y: []f32,
    offset_x: []f32,
    offset_y: []f32,
    size_x: []f32,
    size_y: []f32,

    fn put(self: PlanColumns, at: usize, input: PlanInput) void {
        self.entity[at] = input.entity;
        self.level[at] = input.level;
        self.x[at] = input.x;
        self.y[at] = input.y;
        self.offset_x[at] = input.offset_x;
        self.offset_y[at] = input.offset_y;
        self.size_x[at] = input.size_x;
        self.size_y[at] = input.size_y;
    }

    fn of(inputs: *std.MultiArrayList(PlanInput)) PlanColumns {
        const columns = inputs.slice();
        return .{
            .entity = columns.items(.entity),
            .level = columns.items(.level),
            .x = columns.items(.x),
            .y = columns.items(.y),
            .offset_x = columns.items(.offset_x),
            .offset_y = columns.items(.offset_y),
            .size_x = columns.items(.size_x),
            .size_y = columns.items(.size_y),
        };
    }
};

// One select range's statics, at the front of its window.
const SelectTally = struct { kept: usize = 0 };

// One plan range's touches per tier, change in rows per query class, and a sync's adds
// and releases; the main thread then writes the range's touch, add, and release bases.
const PlanTally = struct {
    touches: [tier_count]u64 = @splat(0),
    class_delta: [max_query_classes]i64 = @splat(0),
    bases: TierCounts = @splat(0),
    adds: u32 = 0,
    releases: u32 = 0,
    add_base: u32 = 0,
    release_base: u32 = 0,
};

// One footprint chunk of a static, as `touch` emits it: the chunk's key, the static's entity
// index, whether it inserts its records or removes its listed ones, whether its query
// record anchors here, at `bit`, and an insert's footprint and AABB.
const ChunkTouch = struct {
    key: u64,
    entity: u32,
    bit: u16,
    insert: bool,
    query_record: bool,
    cells: CellSpan,
    aabb: math.Aabb,
};

// A coarse-class static's query cell: the cell's key, the static's entity index, whether it
// inserts or removes, and an insert's AABB.
const CoarseTouch = struct {
    key: u64,
    entity: u32,
    insert: bool,
    aabb: math.Aabb,
};

comptime {
    // The flags ride in padding: the touch windows' quanta stay as they were.
    std.debug.assert(@sizeOf(ChunkTouch) == 48 and @sizeOf(CoarseTouch) == 32);
}

fn chunkTouchKey(touch: ChunkTouch) u64 {
    return touch.key;
}

fn coarseTouchKey(touch: CoarseTouch) u64 {
    return touch.key;
}

const ChunkTouchSort = banded_sort.BandedSort(ChunkTouch, chunkTouchKey);
const CoarseTouchSort = banded_sort.BandedSort(CoarseTouch, coarseTouchKey);
const TouchSplitters = ChunkTouchSort.Splitters;

comptime {
    std.debug.assert(TouchSplitters == CoarseTouchSort.Splitters);
}

// One key of a band's table: a chunk or cell key and its item, or a level marker.
const GroupSlot = struct { key: u64, item: u32, stamp: u32 };
const GroupTable = StampedTable(GroupSlot, "key");

fn groupSlotOf(key: u64, stamp: u32) GroupSlot {
    return .{ .key = key, .item = 0, .stamp = stamp };
}

// A level marker key sets bit 63, which no chunk or query key sets.
const level_marker_bit: u64 = 1 << 63;

// One group band's items, fill units, resource entries, and level entries, or an item
// whose records overflow a payload's u32 columns, which fails the call.
const GroupTally = struct {
    items: u32 = 0,
    units: usize = 0,
    entries: u32 = 0,
    levels: u32 = 0,
    overflow: bool = false,
};

// Where the fill and install find a call's items: tier `tier`'s band b holds items
// `[band_base[tier][b], band_base[tier][b] + item_start[tier][b + 1] - item_start[tier][b])`
// of the tier's item list, and its fill units start at `unit_start[tier][b]`, the coarse
// tier's past the chunk tier's.
const ItemBands = struct {
    item_start: [tier_count][band_count + 1]u32 = @splat(@splat(0)),
    unit_start: [tier_count][band_count + 1]usize = @splat(@splat(0)),
    band_base: [tier_count][band_count]u32 = @splat(@splat(0)),

    fn unitCount(self: *const ItemBands) usize {
        return self.unit_start[coarse_tier][band_count];
    }

    fn itemCount(self: *const ItemBands) usize {
        return @as(usize, self.item_start[chunk_tier][band_count]) + self.item_start[coarse_tier][band_count];
    }

    fn bandItems(self: *const ItemBands, comptime Item: type, items: []const Item, tier: usize, band: usize) []const Item {
        return items[self.band_base[tier][band]..][0 .. self.item_start[tier][band + 1] - self.item_start[tier][band]];
    }
};

const SelectJob = struct {
    data: *const DataSystem,
    columns: StaticObstacleColumns,
    inputs: PlanColumns,
    tallies: []PaddedSlot(SelectTally),
    items_per_range: usize,
};

// `select`: one range of entity slots. Keeps each slot's static at the front of the range's
// window, in slot order.
// SIMD verdict: scalar. One slot read (alive, components) and one row read per store per
// entity, a filter with a compaction: the one gather that packs the plan lanes' inputs.
fn selectJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *SelectJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.tallies.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end and range.end <= job.inputs.entity.len and range.end <= job.data.slots.items.len);
    const inputs = job.inputs;
    var kept = range.start;
    for (range.start..range.end) |slot| {
        inputs.put(kept, job.data.staticObstacleAt(slot, job.columns) orelse continue);
        kept += 1;
    }
    job.tallies[range.index].value = .{ .kept = kept - range.start };
}

const PlanJob = struct {
    colliders: *StaticColliderSystem,
    inputs: PlanColumns,
    outputs: LaneOutputs,
};

// `plan`: one range of ranks: the lanes, then the scan.
fn planJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *PlanJob = @ptrCast(@alignCast(context));
    const colliders = job.colliders;
    std.debug.assert(range.index < colliders.plan_tallies.items.len);
    std.debug.assert(range.start == range.index * colliders.plan_items_per_range);
    std.debug.assert(range.start <= range.end and range.end <= colliders.rows.len and range.end <= job.inputs.entity.len);
    std.debug.assert(range.end <= colliders.plan_class.items.len);
    for (colliders.plan_touch_local) |local| std.debug.assert(range.end <= local.items.len);
    colliders.planLanes(job.inputs, job.outputs, range.start, range.end);
    colliders.planScan(job.inputs, range.start, range.end, &colliders.plan_tallies.items[range.index].value);
}

const SyncPlanJob = struct {
    colliders: *StaticColliderSystem,
    data: *const DataSystem,
    columns: StaticObstacleColumns,
    inputs: PlanColumns,
    outputs: LaneOutputs,
};

// A sync's `plan`: one range of pending indices: the pack, the lanes, then the decision.
fn syncPlanJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *SyncPlanJob = @ptrCast(@alignCast(context));
    const colliders = job.colliders;
    std.debug.assert(range.index < colliders.plan_tallies.items.len);
    std.debug.assert(range.start == range.index * colliders.plan_items_per_range);
    std.debug.assert(range.start <= range.end and range.end <= colliders.pending_dirty.items.len);
    std.debug.assert(range.end <= job.inputs.entity.len and range.end <= job.outputs.min_x.len and range.end <= colliders.sync_plan.items.len);
    std.debug.assert(range.end <= colliders.plan_class.items.len);
    for (colliders.plan_touch_local) |local| std.debug.assert(range.end <= local.items.len);
    colliders.packPending(job.data, job.columns, job.inputs, range.start, range.end);
    colliders.planLanes(job.inputs, job.outputs, range.start, range.end);
    colliders.decidePending(job.inputs, job.outputs, range.start, range.end, &colliders.plan_tallies.items[range.index].value);
}

// A touch tier's list, line-aligned so every touch range's window starts a cache line.
fn TouchList(comptime Touch: type) type {
    return std.array_list.Aligned(Touch, .fromByteUnits(thread_shared_record_alignment));
}

// A tier's touches per window quantum: the fewest whose bytes end on a cache line.
fn touchWindowQuantum(comptime Touch: type) usize {
    return comptime thread_shared_record_alignment / std.math.gcd(thread_shared_record_alignment, @sizeOf(Touch));
}

// The start of touch range `range_index`'s window, whose first touch is `first` in plan
// order: `first` past `range_index` quanta of slack, rounded up to the quantum, so every
// range's window starts its own cache line and never reaches the next range's start. O(1).
fn touchWindowStart(comptime Touch: type, first: usize, range_index: usize) usize {
    const quantum = touchWindowQuantum(Touch);
    return std.mem.alignForward(usize, first + range_index * (quantum - 1), quantum);
}

// The extent of a tier's `touches` over `range_count` padded windows.
fn touchExtent(comptime Touch: type, touches: usize, range_count: usize) usize {
    return touches + range_count * (touchWindowQuantum(Touch) - 1);
}

// Whose plan items a `touch` emits: a rebuild's ranks or a sync's pending indices.
const TouchSource = enum { rebuild, sync };

const TouchJob = struct {
    colliders: *StaticColliderSystem,
    range_count: usize,
    source: TouchSource,
};

// `touch`: one range of plan items. Writes their touches in plan order into the range's
// window of each tier (`touchWindowStart`), then places them by band into the same window of
// the tier's staging and records the window's band offsets, absolute.
fn touchJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *TouchJob = @ptrCast(@alignCast(context));
    const colliders = job.colliders;
    std.debug.assert(range.index < job.range_count);
    for (colliders.touch_band_offsets) |offsets| std.debug.assert(range.index < offsets.items.len);
    std.debug.assert(range.start <= range.end and range.end <= colliders.plan_item_count);
    if (job.source == .sync) std.debug.assert(range.end <= colliders.sync_plan.items.len);
    var starts: [tier_count]usize = undefined;
    var ends: [tier_count]usize = undefined;
    for (&starts, &ends, 0..) |*start, *end, tier| {
        const first = colliders.touchOffset(tier, range.start);
        const count = colliders.touchOffset(tier, range.end) - first;
        start.* = switch (tier) {
            chunk_tier => touchWindowStart(ChunkTouch, first, range.index),
            else => touchWindowStart(CoarseTouch, first, range.index),
        };
        end.* = start.* + count;
    }
    std.debug.assert(ends[chunk_tier] <= colliders.chunk_touches.items.len and ends[chunk_tier] <= colliders.chunk_staging.items.len);
    std.debug.assert(ends[coarse_tier] <= colliders.coarse_touches.items.len and ends[coarse_tier] <= colliders.coarse_staging.items.len);
    const written = switch (job.source) {
        .rebuild => colliders.emitTouches(range.start, range.end, starts),
        .sync => colliders.emitPendingTouches(range.start, range.end, starts),
    };
    std.debug.assert(std.mem.eql(usize, &written, &ends));
    colliders.touch_band_offsets[chunk_tier].items[range.index].value = placeWindow(ChunkTouchSort, &colliders.touch_splitters[chunk_tier], colliders.chunk_touches.items, colliders.chunk_staging.items, starts[chunk_tier], ends[chunk_tier]);
    colliders.touch_band_offsets[coarse_tier].items[range.index].value = placeWindow(CoarseTouchSort, &colliders.touch_splitters[coarse_tier], colliders.coarse_touches.items, colliders.coarse_staging.items, starts[coarse_tier], ends[coarse_tier]);
}

// Places `touches[start..end]` by band into `staging[start..end]`; the band offsets are
// absolute in `staging`, so every range's segments read with a window stride of 0.
fn placeWindow(comptime Sort: type, splitters: *const TouchSplitters, touches: anytype, staging: anytype, start: usize, end: usize) BandOffsets {
    var placed = Sort.placeByBand(splitters, touches[start..end], staging[start..end]);
    // Touch offsets stay below `max_touches`.
    for (&placed.offsets) |*offset| offset.* += @intCast(start);
    return placed;
}

const GroupJob = struct {
    colliders: *StaticColliderSystem,
    range_count: usize,
};

// `group`: one range of the touches, chunk tier then coarse tier. The range owns, per tier,
// every nonempty band whose first touch lies in its span, so each band has one owner.
fn groupJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *GroupJob = @ptrCast(@alignCast(context));
    const colliders = job.colliders;
    const chunk_total: usize = colliders.touch_start[chunk_tier][band_count];
    const coarse_total: usize = colliders.touch_start[coarse_tier][band_count];
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= chunk_total + coarse_total);
    std.debug.assert(colliders.group_tallies.items.len == tier_count * band_count);
    std.debug.assert(chunk_total <= colliders.chunk_items.items.len and chunk_total <= colliders.nav_inserts.items.len and chunk_total <= colliders.query_inserts.items.len);
    std.debug.assert(coarse_total <= colliders.coarse_items.items.len and coarse_total <= colliders.coarse_inserts.items.len);
    std.debug.assert(colliders.entry_start[coarse_tier][band_count] <= colliders.resource_entries.items.len);
    std.debug.assert(chunk_total + coarse_total <= colliders.level_entries.items.len);
    var chunk_bands = OwnedBands.init(&colliders.touch_start[chunk_tier], @min(range.start, chunk_total), @min(range.end, chunk_total));
    while (chunk_bands.next()) |band| colliders.groupChunkBand(band);
    var coarse_bands = OwnedBands.init(&colliders.touch_start[coarse_tier], @min(range.start -| chunk_total, coarse_total), @min(range.end -| chunk_total, coarse_total));
    while (coarse_bands.next()) |band| colliders.groupCoarseBand(band);
}

// One band's key table: its region of `group_slots` this call's generation, with room for
// its keys and level markers, at most two per touch. The band's owner zeros the region
// first, O(the band's touches): `reserveGroup` leaves the table uninitialized.
const BandTable = struct {
    slots: []GroupSlot,
    shift: u6,
    generation: u32,
    used: usize = 0,
    budget: usize,

    fn init(colliders: *const StaticColliderSystem, tier: usize, band: usize, touches: u32) BandTable {
        const region = colliders.group_slots.items[colliders.region_start[tier][band]..colliders.region_start[tier][band + 1]];
        // `reserveGroup` sized the region from the band's touches at load at most 1/2.
        std.debug.assert(region.len >= 2 * 2 * @as(usize, touches));
        @memset(std.mem.sliceAsBytes(region), 0);
        return .{ .slots = region, .shift = hashTableShift(region.len), .generation = colliders.group_generation, .budget = 2 * @as(usize, touches) };
    }

    fn claim(self: *BandTable, key: u64) GroupTable.Claim {
        return GroupTable.claim(self.slots, self.shift, self.generation, &self.used, self.budget, key, groupSlotOf) orelse unreachable; // lint:allow catch-unreachable: a band claims at most one key and one level marker per touch, its budget
    }

    // The item of a key this band claimed.
    fn itemOf(self: *BandTable, key: u64) u32 {
        const claimed = self.claim(key);
        std.debug.assert(!claimed.fresh);
        return self.slots[claimed.slot].item;
    }
};

// One band's resource entries in first-use order: its window of `resource_entries` and
// each resource's entry there.
const BandEntries = struct {
    window: []ResourceEntry,
    base: usize,
    count: u32 = 0,
    entry_of: [resource_count]u32 = @splat(unused_resource),

    const unused_resource: u32 = std.math.maxInt(u32);

    // The band's next claim of `resource`: its entry's index in `resource_entries` and its
    // ordinal among the entry's claims.
    fn claim(self: *BandEntries, resource: u16) EntryOrdinal {
        const local = self.entryOf(resource);
        const entry = &self.window[local];
        defer entry.claims += 1;
        // Entry indices stay below `entries_per_touch` times `max_touches`.
        return .{ .entry = @intCast(self.base + local), .ordinal = entry.claims };
    }

    // The band's next release of `resource`, as `claim`.
    fn release(self: *BandEntries, resource: u16) EntryOrdinal {
        const local = self.entryOf(resource);
        const entry = &self.window[local];
        defer entry.releases += 1;
        // Entry indices stay below `entries_per_touch` times `max_touches`.
        return .{ .entry = @intCast(self.base + local), .ordinal = entry.releases };
    }

    fn entryOf(self: *BandEntries, resource: u16) u32 {
        if (self.entry_of[resource] == unused_resource) {
            std.debug.assert(self.count < self.window.len);
            self.entry_of[resource] = self.count;
            self.window[self.count] = .{ .resource = resource };
            self.count += 1;
        }
        return self.entry_of[resource];
    }
};

const InstallJob = struct {
    colliders: *StaticColliderSystem,
    range_count: usize,
};

// `install`: one range of the items, chunk tier then coarse tier. The range owns, per tier,
// every nonempty band whose first item lies in its span; a band's chunks or cells are one key
// window, so owners write disjoint directory slots, blocks, and release positions.
// SIMD verdict: scalar. Per item, a switch on its plan kind and at most a scattered slot
// write and two positional free-list writes.
fn installJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *InstallJob = @ptrCast(@alignCast(context));
    const colliders = job.colliders;
    const bands = &colliders.item_bands;
    const chunk_total: usize = bands.item_start[chunk_tier][band_count];
    const coarse_total: usize = bands.item_start[coarse_tier][band_count];
    const entries = colliders.resource_entries.items;
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= chunk_total + coarse_total);
    var chunk_bands = OwnedBands.init(&bands.item_start[chunk_tier], @min(range.start, chunk_total), @min(range.end, chunk_total));
    while (chunk_bands.next()) |band| {
        for (bands.bandItems(ChunkItem, colliders.chunk_items.items, chunk_tier, band)) |item| {
            installItem(ChunkDir, &colliders.chunks, &colliders.payloads, entries, item.level, item.slot, item.old_block, item.block, item.payload_plan);
        }
    }
    var coarse_bands = OwnedBands.init(&bands.item_start[coarse_tier], @min(range.start -| chunk_total, coarse_total), @min(range.end -| chunk_total, coarse_total));
    while (coarse_bands.next()) |band| {
        for (bands.bandItems(CoarseItem, colliders.coarse_items.items, coarse_tier, band)) |item| {
            installItem(CoarseDir, &colliders.coarse[item.class], &colliders.payloads, entries, item.level, item.slot, item.old_block, item.block, item.payload_plan);
        }
    }
}
const ApplyJob = struct {
    colliders: *StaticColliderSystem,
    inputs: PlanColumns,
    outputs: LaneOutputs,
    range_count: usize,
};

// `apply`: one range of pending indices.
fn applyJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *ApplyJob = @ptrCast(@alignCast(context));
    const colliders = job.colliders;
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= colliders.plan_item_count);
    std.debug.assert(range.end <= colliders.changes.items.len and range.end <= colliders.sync_plan.items.len);
    colliders.applyRange(job.inputs, job.outputs, range.start, range.end);
}

fn spanLess(_: void, a: SpanInsert, b: SpanInsert) bool {
    return a.entity < b.entity;
}

fn aabbLess(_: void, a: AabbInsert, b: AabbInsert) bool {
    if (a.bit != b.bit) return a.bit < b.bit;
    return a.entity < b.entity;
}

fn entityLess(_: void, a: AabbInsert, b: AabbInsert) bool {
    return a.entity < b.entity;
}

fn isRelinked(stamps: []const u32, entity: u32, generation: u32) bool {
    return entity < stamps.len and stamps[entity] == generation;
}

// Drops the relinked records among `old`'s first `old_len` and merges `inserts` (ascending
// in the run's order, none equal to a kept record) into `out`; returns the new length.
// Fresh columns (`!in_place`) take one forward merge, each kept record copied once. In
// place, `out` shares `old`'s columns: the compaction writes at or below the record it
// reads, then the merge runs from the back, writing at or above the next kept record.
// Scalar: a compaction and a merge, each a data dependency on the write cursor.
fn rewriteRecords(comptime Records: type, out: Records, old: Records, old_len: u32, inserts: []const Records.Insert, stamps: []const u32, generation: u32, in_place: bool) u32 {
    if (!in_place) return mergeForward(Records, out, old, old_len, inserts, stamps, generation);
    var kept: usize = 0;
    for (0..old_len) |read| {
        if (isRelinked(stamps, old.entity[read], generation)) continue;
        out.copy(kept, old, read);
        kept += 1;
    }
    const len = kept + inserts.len;
    std.debug.assert(len <= out.entity.len);
    var write = len;
    var record = kept;
    var insert = inserts.len;
    while (insert > 0) {
        write -= 1;
        if (record == 0 or Records.before(out, record - 1, inserts[insert - 1])) {
            insert -= 1;
            out.put(write, inserts[insert]);
        } else {
            record -= 1;
            out.copy(write, out, record);
        }
    }
    std.debug.assert(write == record);
    return @intCast(len);
}

// `rewriteRecords` into columns `old` does not share: kept records and inserts in one
// forward pass.
fn mergeForward(comptime Records: type, out: Records, old: Records, old_len: u32, inserts: []const Records.Insert, stamps: []const u32, generation: u32) u32 {
    std.debug.assert(old_len == 0 or out.entity.ptr != old.entity.ptr);
    var write: usize = 0;
    var insert: usize = 0;
    for (0..old_len) |read| {
        if (isRelinked(stamps, old.entity[read], generation)) continue;
        while (insert < inserts.len and !Records.before(old, read, inserts[insert])) : (insert += 1) {
            out.put(write, inserts[insert]);
            write += 1;
        }
        out.copy(write, old, read);
        write += 1;
    }
    for (inserts[insert..]) |rest| {
        out.put(write, rest);
        write += 1;
    }
    std.debug.assert(write <= out.entity.len);
    return @intCast(write);
}

// A chunk's nav span columns, entity order.
const NavRecords = struct {
    entity: []u32,
    min_x: []u32,
    min_y: []u32,
    max_x: []u32,
    max_y: []u32,

    const Insert = SpanInsert;

    fn of(payload: *const StaticChunk) NavRecords {
        return .{ .entity = payload.nav_entity, .min_x = payload.nav_min_x, .min_y = payload.nav_min_y, .max_x = payload.nav_max_x, .max_y = payload.nav_max_y };
    }

    // Whether record `at` sorts before `insert`.
    fn before(self: NavRecords, at: usize, insert: SpanInsert) bool {
        std.debug.assert(self.entity[at] != insert.entity);
        return self.entity[at] < insert.entity;
    }

    fn copy(self: NavRecords, to: usize, from_records: NavRecords, from: usize) void {
        self.entity[to] = from_records.entity[from];
        self.min_x[to] = from_records.min_x[from];
        self.min_y[to] = from_records.min_y[from];
        self.max_x[to] = from_records.max_x[from];
        self.max_y[to] = from_records.max_y[from];
    }

    fn put(self: NavRecords, at: usize, insert: SpanInsert) void {
        self.entity[at] = insert.entity;
        self.min_x[at] = insert.min_x;
        self.min_y[at] = insert.min_y;
        self.max_x[at] = insert.max_x;
        self.max_y[at] = insert.max_y;
    }
};

// A chunk's query columns, (bit, entity) order.
const QueryRecords = struct {
    entity: []u32,
    bit: []u16,
    min_x: []f32,
    min_y: []f32,
    max_x: []f32,
    max_y: []f32,

    const Insert = AabbInsert;

    fn of(payload: *const StaticChunk) QueryRecords {
        return .{ .entity = payload.query_entity, .bit = payload.query_bit, .min_x = payload.query_min_x, .min_y = payload.query_min_y, .max_x = payload.query_max_x, .max_y = payload.query_max_y };
    }

    fn before(self: QueryRecords, at: usize, insert: AabbInsert) bool {
        std.debug.assert(!(self.bit[at] == insert.bit and self.entity[at] == insert.entity));
        return self.bit[at] < insert.bit or (self.bit[at] == insert.bit and self.entity[at] < insert.entity);
    }

    fn copy(self: QueryRecords, to: usize, from_records: QueryRecords, from: usize) void {
        self.entity[to] = from_records.entity[from];
        self.bit[to] = from_records.bit[from];
        self.min_x[to] = from_records.min_x[from];
        self.min_y[to] = from_records.min_y[from];
        self.max_x[to] = from_records.max_x[from];
        self.max_y[to] = from_records.max_y[from];
    }

    fn put(self: QueryRecords, at: usize, insert: AabbInsert) void {
        self.entity[at] = insert.entity;
        self.bit[at] = insert.bit;
        self.min_x[at] = insert.min_x;
        self.min_y[at] = insert.min_y;
        self.max_x[at] = insert.max_x;
        self.max_y[at] = insert.max_y;
    }
};

// A coarse cell's query columns, entity order.
const RunRecords = struct {
    entity: []u32,
    min_x: []f32,
    min_y: []f32,
    max_x: []f32,
    max_y: []f32,

    const Insert = AabbInsert;

    fn of(run: *const QueryRun) RunRecords {
        return .{ .entity = run.entity, .min_x = run.min_x, .min_y = run.min_y, .max_x = run.max_x, .max_y = run.max_y };
    }

    fn before(self: RunRecords, at: usize, insert: AabbInsert) bool {
        std.debug.assert(self.entity[at] != insert.entity);
        return self.entity[at] < insert.entity;
    }

    fn copy(self: RunRecords, to: usize, from_records: RunRecords, from: usize) void {
        self.entity[to] = from_records.entity[from];
        self.min_x[to] = from_records.min_x[from];
        self.min_y[to] = from_records.min_y[from];
        self.max_x[to] = from_records.max_x[from];
        self.max_y[to] = from_records.max_y[from];
    }

    fn put(self: RunRecords, at: usize, insert: AabbInsert) void {
        self.entity[at] = insert.entity;
        self.min_x[at] = insert.min_x;
        self.min_y[at] = insert.min_y;
        self.max_x[at] = insert.max_x;
        self.max_y[at] = insert.max_y;
    }
};

fn emitGroups(payload: *StaticChunk) void {
    var anchors = empty_anchor_block;
    var group_len: usize = 0;
    var index: usize = 0;
    const len: usize = payload.query_len;
    while (index < len) {
        const bit = payload.query_bit[index];
        const start = index;
        while (index < len and payload.query_bit[index] == bit) index += 1;
        payload.groups[group_len] = .{ .bit = bit, .start = @intCast(start), .count = @intCast(index - start) };
        const word = bit >> 6;
        anchors.words[word] |= @as(u64, 1) << @intCast(bit & 63);
        anchors.set_bits += 1;
        group_len += 1;
    }
    payload.group_len = @intCast(group_len);
    payload.anchors = anchors;
}

// The power-of-two column capacity holding `needed` records; a capacity past 2^31 fails
// as `OutOfMemory`.
fn geometric(needed: usize) error{OutOfMemory}!u32 {
    if (needed == 0) return 0;
    if (needed >= empty_block) return error.OutOfMemory;
    // `needed` is below 2^32.
    return std.math.ceilPowerOfTwo(u32, @intCast(needed)) catch error.OutOfMemory;
}

fn chunkPayloadBytes(nav_cap: u32, query_cap: u32) usize {
    const nav: usize = nav_cap;
    const query: usize = query_cap;
    var offset: usize = 0;
    offset = std.mem.alignForward(usize, offset, @alignOf(u32)) + nav * 5 * @sizeOf(u32);
    offset = std.mem.alignForward(usize, offset, @alignOf(u32)) + query * @sizeOf(u32);
    offset = std.mem.alignForward(usize, offset, @alignOf(u16)) + query * @sizeOf(u16);
    offset = std.mem.alignForward(usize, offset, @alignOf(f32)) + query * 4 * @sizeOf(f32);
    offset = std.mem.alignForward(usize, offset, @alignOf(QueryGroup)) + query * @sizeOf(QueryGroup);
    return offset;
}

fn queryRunBytes(cap: u32) usize {
    const count: usize = cap;
    var offset: usize = 0;
    offset = std.mem.alignForward(usize, offset, @alignOf(u32)) + count * @sizeOf(u32);
    offset = std.mem.alignForward(usize, offset, @alignOf(f32)) + count * 4 * @sizeOf(f32);
    return offset;
}

fn splitChunk(bytes: []align(4) u8, slot: PayloadSlot, nav_cap: u32, query_cap: u32) StaticChunk {
    var offset: usize = 0;
    var payload = StaticChunk{ .slot = slot, .nav_cap = nav_cap, .query_cap = query_cap };
    payload.nav_entity = take(u32, bytes, &offset, nav_cap);
    payload.nav_min_x = take(u32, bytes, &offset, nav_cap);
    payload.nav_min_y = take(u32, bytes, &offset, nav_cap);
    payload.nav_max_x = take(u32, bytes, &offset, nav_cap);
    payload.nav_max_y = take(u32, bytes, &offset, nav_cap);
    payload.query_entity = take(u32, bytes, &offset, query_cap);
    payload.query_bit = take(u16, bytes, &offset, query_cap);
    payload.query_min_x = take(f32, bytes, &offset, query_cap);
    payload.query_min_y = take(f32, bytes, &offset, query_cap);
    payload.query_max_x = take(f32, bytes, &offset, query_cap);
    payload.query_max_y = take(f32, bytes, &offset, query_cap);
    payload.groups = take(QueryGroup, bytes, &offset, query_cap);
    std.debug.assert(offset <= bytes.len);
    return payload;
}

fn splitQueryRun(bytes: []align(4) u8, slot: PayloadSlot, cap: u32) QueryRun {
    var offset: usize = 0;
    return .{
        .slot = slot,
        .cap = cap,
        .entity = take(u32, bytes, &offset, cap),
        .min_x = take(f32, bytes, &offset, cap),
        .min_y = take(f32, bytes, &offset, cap),
        .max_x = take(f32, bytes, &offset, cap),
        .max_y = take(f32, bytes, &offset, cap),
    };
}

fn take(comptime T: type, bytes: []align(4) u8, offset: *usize, count: u32) []T {
    if (count == 0) return &.{};
    offset.* = std.mem.alignForward(usize, offset.*, @alignOf(T));
    const start = offset.*;
    const byte_len = @as(usize, count) * @sizeOf(T);
    offset.* = start + byte_len;
    const aligned: []align(@alignOf(T)) u8 = @alignCast((@as([*]u8, @ptrCast(bytes.ptr)) + start)[0..byte_len]);
    return std.mem.bytesAsSlice(T, aligned);
}

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

// Span records held on every opened chunk.
fn listEntryCount(colliders: *const StaticColliderSystem) usize {
    var total: usize = 0;
    for (0..colliders.chunks.levelCount()) |level| {
        for (0..colliders.chunks.slotCount(@intCast(level))) |chunk| {
            const block = colliders.chunks.slot(@intCast(level), chunk);
            if (block == empty_block) continue;
            total += colliders.chunks.payload(block).nav_len;
        }
    }
    return total;
}

fn occupiedChunkCount(colliders: *const StaticColliderSystem) usize {
    var total: usize = 0;
    for (0..colliders.chunks.levelCount()) |level| {
        for (0..colliders.chunks.slotCount(@intCast(level))) |chunk| {
            if (colliders.chunks.slot(@intCast(level), chunk) != empty_block) total += 1;
        }
    }
    return total;
}

fn chunkPayloadOf(colliders: *const StaticColliderSystem, level: u16, chunk: u32) ?StaticChunk {
    const block = colliders.chunks.slot(level, chunk);
    if (block == empty_block) return null;
    return colliders.chunks.payload(block);
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
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    return commitForTestWith(frame, data, colliders, commands, &serial_threads);
}

// `commitForTest` with the sync's splice stage under `thread_system`.
fn commitForTestWith(frame: *SimulationFrame, data: *DataSystem, colliders: *StaticColliderSystem, commands: []const StructuralCommand, thread_system: *ThreadSystem) !void {
    try commitAndCapture(frame, data, colliders, commands);
    try colliders.sync(data, thread_system);
}

// The commit seam up to the sync: reserve, commit `commands`, capture.
fn commitAndCapture(frame: *SimulationFrame, data: *DataSystem, colliders: *StaticColliderSystem, commands: []const StructuralCommand) !void {
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
}

// Chunks per level on `geometry`.
fn levelChunkCount(geometry: ColliderGeometry) usize {
    return geometry.grid.chunkCount();
}

// Whether `a` and `b` hold identical rows, change lists, and chunk bytes (block and payload
// slot ids included) over `levels` levels.
fn expectIdenticalLayout(a: *const StaticColliderSystem, b: *const StaticColliderSystem, levels: u16) !void {
    try std.testing.expectEqualSlices(u32, a.row_of_index.items, b.row_of_index.items);
    try std.testing.expectEqual(a.changes.items.len, b.changes.items.len);
    for (a.changes.items, b.changes.items) |change_a, change_b| try std.testing.expectEqual(change_a, change_b);
    const chunk_count = levelChunkCount(a.geometry.?);
    for (0..levels) |level| for (0..chunk_count) |chunk| {
        const block_a = a.chunks.slot(@intCast(level), chunk);
        try std.testing.expectEqual(block_a, b.chunks.slot(@intCast(level), chunk));
        if (block_a != empty_block) try expectSameChunkBytes(a.chunks.payload(block_a), b.chunks.payload(block_a));
    };
    for (0..max_query_classes) |class| {
        const class_id: u6 = @intCast(class);
        for (0..levels) |level| {
            const slots = @max(a.coarse[class_id].slotCount(@intCast(level)), b.coarse[class_id].slotCount(@intCast(level)));
            for (0..slots) |cell| {
                const block_a = a.coarse[class_id].slot(@intCast(level), cell);
                const block_b = b.coarse[class_id].slot(@intCast(level), cell);
                try std.testing.expectEqual(block_a == empty_block, block_b == empty_block);
                if (block_a == empty_block) continue;
                try std.testing.expectEqual(block_a, block_b);
                try expectSameRun(a.coarse[class_id].payload(block_a), b.coarse[class_id].payload(block_b));
            }
        }
    }
}

fn expectSameChunkBytes(a: StaticChunk, b: StaticChunk) !void {
    try std.testing.expectEqual(a.slot, b.slot);
    try std.testing.expectEqual(a.nav_len, b.nav_len);
    try std.testing.expectEqual(a.query_len, b.query_len);
    try std.testing.expectEqual(a.group_len, b.group_len);
    try std.testing.expectEqual(a.anchors, b.anchors);
    const nav: usize = a.nav_len;
    const query: usize = a.query_len;
    const groups: usize = a.group_len;
    try std.testing.expectEqualSlices(u32, a.nav_entity[0..nav], b.nav_entity[0..nav]);
    try std.testing.expectEqualSlices(u32, a.nav_min_x[0..nav], b.nav_min_x[0..nav]);
    try std.testing.expectEqualSlices(u32, a.nav_min_y[0..nav], b.nav_min_y[0..nav]);
    try std.testing.expectEqualSlices(u32, a.nav_max_x[0..nav], b.nav_max_x[0..nav]);
    try std.testing.expectEqualSlices(u32, a.nav_max_y[0..nav], b.nav_max_y[0..nav]);
    try std.testing.expectEqualSlices(u32, a.query_entity[0..query], b.query_entity[0..query]);
    try std.testing.expectEqualSlices(u16, a.query_bit[0..query], b.query_bit[0..query]);
    try std.testing.expectEqualSlices(f32, a.query_min_x[0..query], b.query_min_x[0..query]);
    try std.testing.expectEqualSlices(f32, a.query_min_y[0..query], b.query_min_y[0..query]);
    try std.testing.expectEqualSlices(f32, a.query_max_x[0..query], b.query_max_x[0..query]);
    try std.testing.expectEqualSlices(f32, a.query_max_y[0..query], b.query_max_y[0..query]);
    try std.testing.expectEqualSlices(QueryGroup, a.groups[0..groups], b.groups[0..groups]);
}

fn expectSameRun(a: QueryRun, b: QueryRun) !void {
    try std.testing.expectEqual(a.slot, b.slot);
    try std.testing.expectEqual(a.len, b.len);
    const count: usize = a.len;
    try std.testing.expectEqualSlices(u32, a.entity[0..count], b.entity[0..count]);
    try std.testing.expectEqualSlices(f32, a.min_x[0..count], b.min_x[0..count]);
    try std.testing.expectEqualSlices(f32, a.min_y[0..count], b.min_y[0..count]);
    try std.testing.expectEqualSlices(f32, a.max_x[0..count], b.max_x[0..count]);
    try std.testing.expectEqualSlices(f32, a.max_y[0..count], b.max_y[0..count]);
}

// Rows listed at (level, chunk), as entity indices in list order.
fn listedIndices(colliders: *const StaticColliderSystem, level: u16, chunk: u32, out: *std.ArrayList(u32)) !void {
    out.clearRetainingCapacity();
    const spans = colliders.view().chunkRows(level, chunk);
    try out.appendSlice(std.testing.allocator, spans.entity);
}

// The query runs hold each live row once, at its class and anchor cell, every run
// ascending in (bit, entity); the class counts and mask equal a recount. A chunk's anchor
// words are exactly the bits of its query groups.
fn expectQueryTier(colliders: *const StaticColliderSystem) !void {
    const geometry = colliders.geometry.?;
    const shift = geometry.grid.shift;
    var seen = try std.DynamicBitSet.initEmpty(std.testing.allocator, colliders.rows.len);
    defer seen.deinit();
    var class_rows: [max_query_classes]u32 = @splat(0);
    for (0..colliders.chunks.levelCount()) |level| {
        for (0..colliders.chunks.slotCount(@intCast(level))) |chunk| {
            const payload = chunkPayloadOf(colliders, @intCast(level), @intCast(chunk)) orelse continue;
            try expectGroupsMatchAnchors(payload);
            var previous_bit: ?u16 = null;
            var previous_entity: ?u32 = null;
            for (0..payload.query_len) |index| {
                const bit = payload.query_bit[index];
                const entity = payload.query_entity[index];
                if (previous_bit) |before| {
                    try std.testing.expect(bit > before or (bit == before and entity > previous_entity.?));
                }
                previous_bit = bit;
                previous_entity = entity;
                try markQueryRow(colliders, &seen, &class_rows, entity, @intCast(level), @intCast(chunk), bit);
            }
        }
    }
    for (0..max_query_classes) |class| {
        const class_id: u6 = @intCast(class);
        if (class_id <= shift) continue;
        const dir = &colliders.coarse[class_id];
        for (0..dir.levelCount()) |level| {
            for (0..dir.slotCount(@intCast(level))) |cell| {
                const block = dir.slot(@intCast(level), cell);
                if (block == empty_block) continue;
                const run = dir.payload(block);
                var previous: ?u32 = null;
                for (0..run.len) |index| {
                    const entity = run.entity[index];
                    if (previous) |before| try std.testing.expect(before < entity);
                    previous = entity;
                    try markQueryRow(colliders, &seen, &class_rows, entity, @intCast(level), @intCast(cell), null);
                }
            }
        }
    }
    for (colliders.row_of_index.items) |row| {
        if (row == no_row) continue;
        try std.testing.expect(seen.isSet(row));
    }
    try std.testing.expectEqualSlices(u32, &class_rows, &colliders.query_class_rows);
    for (class_rows, 0..) |rows, class| try std.testing.expectEqual(rows != 0, colliders.query_class_mask.isSet(class));
    try std.testing.expectEqual(static_colliders_test_support.liveRowCount(colliders), seen.count());
}

fn markQueryRow(colliders: *const StaticColliderSystem, seen: *std.DynamicBitSet, class_rows: *[max_query_classes]u32, entity: u32, level: u16, slot: u32, bit: ?u16) !void {
    try std.testing.expect(entity < colliders.row_of_index.items.len);
    const row = colliders.row_of_index.items[entity];
    try std.testing.expect(row != no_row and !seen.isSet(row));
    seen.set(row);
    const query = colliders.queryPlacement(colliders.rowPlacement(row), colliders.rowAabb(row));
    class_rows[query.class] += 1;
    const geometry = colliders.geometry.?;
    if (query.class <= geometry.grid.shift) {
        const anchor = geometry.anchorBit(query.key);
        try std.testing.expectEqual(level, keyLevel(anchor.chunk_key));
        try std.testing.expectEqual(slot, keyChunk(anchor.chunk_key));
        try std.testing.expectEqual(bit.?, @as(u16, @intCast(anchor.bit)));
    } else {
        try std.testing.expect(bit == null);
        try std.testing.expectEqual(level, queryKeyLevel(query.key));
        try std.testing.expectEqual(slot, keyChunk(query.key));
    }
}

fn expectGroupsMatchAnchors(payload: StaticChunk) !void {
    var anchors = empty_anchor_block;
    var covered: usize = 0;
    var previous: ?u16 = null;
    for (payload.groups[0..payload.group_len]) |group| {
        if (previous) |before| try std.testing.expect(group.bit > before);
        previous = group.bit;
        try std.testing.expectEqual(covered, group.start);
        covered += group.count;
        anchors.words[group.bit >> 6] |= @as(u64, 1) << @intCast(group.bit & 63);
        anchors.set_bits += 1;
    }
    try std.testing.expectEqual(payload.query_len, covered);
    try std.testing.expectEqual(anchors, payload.anchors);
}

// A chunk's anchor words equal its query groups, every pooled chunk and coarse block is
// installed or free, and every payload slot is held by one live block or free.
fn expectAnchors(colliders: *const StaticColliderSystem) !void {
    try expectPayloadSlotsOwned(colliders);
    try expectBlocksInstalledOrFree(ChunkDir, &colliders.chunks);
    for (&colliders.coarse) |*dir| try expectBlocksInstalledOrFree(CoarseDir, dir);
    for (0..colliders.chunks.levelCount()) |level| {
        for (0..colliders.chunks.slotCount(@intCast(level))) |chunk| {
            const block = colliders.chunks.slot(@intCast(level), chunk);
            if (block != empty_block) try expectGroupsMatchAnchors(colliders.chunks.payload(block));
        }
    }
}

// Every block of `dir` is installed in exactly one slot or free, never both, and a free block
// holds a reset descriptor: no bytes, no slot, no columns.
fn expectBlocksInstalledOrFree(comptime Dir: type, dir: *const Dir) !void {
    var seen = try std.DynamicBitSet.initEmpty(std.testing.allocator, dir.blocks.items.len);
    defer seen.deinit();
    for (0..dir.levelCount()) |level| {
        for (0..dir.slotCount(@intCast(level))) |index| {
            const block = dir.slot(@intCast(level), index);
            if (block == empty_block) continue;
            try std.testing.expect(block < dir.blocks.items.len and !seen.isSet(block));
            seen.set(block);
        }
    }
    for (dir.block_free.items) |block| {
        try std.testing.expect(block < dir.blocks.items.len and !seen.isSet(block));
        seen.set(block);
        try std.testing.expectEqualDeep(Dir.Block{}, dir.blocks.items[block]);
    }
    try std.testing.expectEqual(dir.blocks.items.len, seen.count());
}

// Each slab class's ids below its next id are each held by exactly one live chunk or
// coarse block, or free, never both; a live block holds no bytes of its directory.
fn expectPayloadSlotsOwned(colliders: *const StaticColliderSystem) !void {
    var owned: [max_payload_classes]std.DynamicBitSet = undefined;
    for (&owned, &colliders.payloads.classes) |*ids, held| ids.* = try std.DynamicBitSet.initEmpty(std.testing.allocator, held.claims.next_id);
    defer for (&owned) |*ids| ids.deinit();
    for (0..colliders.chunks.levelCount()) |level| {
        for (0..colliders.chunks.slotCount(@intCast(level))) |chunk| {
            const block = colliders.chunks.slot(@intCast(level), chunk);
            if (block == empty_block) continue;
            try std.testing.expectEqual(@as(usize, 0), colliders.chunks.blockBytes(block).len);
            try ownSlot(&owned, colliders.chunks.payloadConst(block).slot);
        }
    }
    for (&colliders.coarse) |*dir| {
        for (0..dir.levelCount()) |level| {
            for (0..dir.slotCount(@intCast(level))) |cell| {
                const block = dir.slot(@intCast(level), cell);
                if (block == empty_block) continue;
                try std.testing.expectEqual(@as(usize, 0), dir.blockBytes(block).len);
                try ownSlot(&owned, dir.payloadConst(block).slot);
            }
        }
    }
    for (&owned, &colliders.payloads.classes, 0..) |*ids, held, class| {
        for (held.claims.free.items) |id| try ownSlot(&owned, .{ .class = @intCast(class), .id = id });
        try std.testing.expectEqual(@as(usize, held.claims.next_id), ids.count());
    }
}

fn ownSlot(owned: *[max_payload_classes]std.DynamicBitSet, slot: PayloadSlot) !void {
    try std.testing.expect(!slot.isNone());
    const ids = &owned[slot.class];
    try std.testing.expect(slot.id < ids.capacity() and !ids.isSet(slot.id));
    ids.set(slot.id);
}

// Whether `a` and `b` hold the same anchor words per chunk over `levels` (block ids may differ).
fn expectSameAnchors(a: *const StaticColliderSystem, b: *const StaticColliderSystem, levels: u16) !void {
    const chunk_count = levelChunkCount(a.geometry.?);
    for (0..levels) |level| for (0..chunk_count) |chunk| {
        const anchors_a = if (chunkPayloadOf(a, @intCast(level), @intCast(chunk))) |payload| payload.anchors else empty_anchor_block;
        const anchors_b = if (chunkPayloadOf(b, @intCast(level), @intCast(chunk))) |payload| payload.anchors else empty_anchor_block;
        try std.testing.expectEqual(anchors_a, anchors_b);
    };
}

// Whether `a` and `b` hold the same rows, the same lists over `levels` levels, the same
// query tier, and the same anchor bits; each system's tiers and blocks agree with its rows.
fn expectSameRows(a: *const StaticColliderSystem, b: *const StaticColliderSystem, levels: u16) !void {
    try std.testing.expectEqual(static_colliders_test_support.liveRowCount(a), static_colliders_test_support.liveRowCount(b));
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
        // The span bounds nav reads, column by column.
        const spans_a = a.view().chunkRows(@intCast(level), @intCast(chunk));
        const spans_b = b.view().chunkRows(@intCast(level), @intCast(chunk));
        try std.testing.expectEqualSlices(u32, spans_b.min_x, spans_a.min_x);
        try std.testing.expectEqualSlices(u32, spans_b.min_y, spans_a.min_y);
        try std.testing.expectEqualSlices(u32, spans_b.max_x, spans_a.max_x);
        try std.testing.expectEqualSlices(u32, spans_b.max_y, spans_a.max_y);
    };
    try std.testing.expectEqual(listEntryCount(a), listEntryCount(b));
    for ([_]*const StaticColliderSystem{ a, b }) |colliders| {
        try expectQueryTier(colliders);
        try expectAnchors(colliders);
    }
    try expectSameQueries(a, b, levels);
    try expectSameAnchors(a, b, levels);
}

fn expectSameQueries(a: *const StaticColliderSystem, b: *const StaticColliderSystem, levels: u16) !void {
    const chunk_count = levelChunkCount(a.geometry.?);
    for (0..levels) |level| for (0..chunk_count) |chunk| {
        const payload_a = chunkPayloadOf(a, @intCast(level), @intCast(chunk));
        const payload_b = chunkPayloadOf(b, @intCast(level), @intCast(chunk));
        const query_a: usize = if (payload_a) |payload| payload.query_len else 0;
        const query_b: usize = if (payload_b) |payload| payload.query_len else 0;
        try std.testing.expectEqual(query_a, query_b);
        if (query_a == 0) continue;
        try std.testing.expectEqualSlices(u32, payload_a.?.query_entity[0..query_a], payload_b.?.query_entity[0..query_b]);
        try std.testing.expectEqualSlices(u16, payload_a.?.query_bit[0..query_a], payload_b.?.query_bit[0..query_b]);
        try std.testing.expectEqual(payload_a.?.group_len, payload_b.?.group_len);
        try std.testing.expectEqualSlices(QueryGroup, payload_a.?.groups[0..payload_a.?.group_len], payload_b.?.groups[0..payload_b.?.group_len]);
        try std.testing.expectEqualSlices(f32, payload_a.?.query_min_x[0..query_a], payload_b.?.query_min_x[0..query_b]);
        try std.testing.expectEqualSlices(f32, payload_a.?.query_min_y[0..query_a], payload_b.?.query_min_y[0..query_b]);
        try std.testing.expectEqualSlices(f32, payload_a.?.query_max_x[0..query_a], payload_b.?.query_max_x[0..query_b]);
        try std.testing.expectEqualSlices(f32, payload_a.?.query_max_y[0..query_a], payload_b.?.query_max_y[0..query_b]);
    };
    const shift = a.geometry.?.grid.shift;
    for (0..max_query_classes) |class| {
        const class_id: u6 = @intCast(class);
        if (class_id <= shift) continue;
        for (0..levels) |level| {
            const slots = @max(a.coarse[class_id].slotCount(@intCast(level)), b.coarse[class_id].slotCount(@intCast(level)));
            for (0..slots) |cell| {
                const block_a = a.coarse[class_id].slot(@intCast(level), cell);
                const block_b = b.coarse[class_id].slot(@intCast(level), cell);
                const len_a: usize = if (block_a == empty_block) 0 else a.coarse[class_id].payload(block_a).len;
                const len_b: usize = if (block_b == empty_block) 0 else b.coarse[class_id].payload(block_b).len;
                try std.testing.expectEqual(len_a, len_b);
                if (len_a == 0) continue;
                const run_a = a.coarse[class_id].payload(block_a);
                const run_b = b.coarse[class_id].payload(block_b);
                try std.testing.expectEqualSlices(u32, run_a.entity[0..len_a], run_b.entity[0..len_b]);
                try std.testing.expectEqualSlices(f32, run_a.min_x[0..len_a], run_b.min_x[0..len_b]);
                try std.testing.expectEqualSlices(f32, run_a.min_y[0..len_a], run_b.min_y[0..len_b]);
                try std.testing.expectEqualSlices(f32, run_a.max_x[0..len_a], run_b.max_x[0..len_b]);
                try std.testing.expectEqualSlices(f32, run_a.max_y[0..len_a], run_b.max_y[0..len_b]);
            }
        }
    }
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
        try fixture.colliders.rebuild(&fixture.data, geometry, null);
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
        try colliders.rebuild(&self.data, self.geometry, null);
        return colliders;
    }

    // `rebuilt` with the fill on `thread_system` at a fixed partition of `items_per_range`.
    fn rebuiltOn(self: *const SeamFixture, thread_system: *ThreadSystem, items_per_range: usize) !StaticColliderSystem {
        var colliders = StaticColliderSystem.init(std.testing.allocator);
        errdefer colliders.deinit();
        colliders.splice_controls = .{ .adaptive = false, .items_per_range = items_per_range };
        try colliders.rebuild(&self.data, self.geometry, thread_system);
        return colliders;
    }
};

const static_colliders_test_support = @import("static_colliders_test_support.zig");

test "creating a static from a template indexes it once" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    // A 1.5-cell box at a chunk corner covers four chunks.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 112, .y = 112 }, .{ .x = 48, .y = 48 }) }});
    try std.testing.expectEqual(@as(usize, 1), static_colliders_test_support.liveRowCount(fixture.colliders));
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
    try std.testing.expectEqual(@as(usize, 0), static_colliders_test_support.liveRowCount(fixture.colliders));
    try std.testing.expectEqual(@as(usize, 0), listEntryCount(&fixture.colliders));
    try std.testing.expectEqual(@as(usize, 0), occupiedChunkCount(&fixture.colliders));
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
    try std.testing.expectEqual(@as(usize, 1), static_colliders_test_support.liveRowCount(fixture.colliders));
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

// Each change's old placement against `before`, the pre-commit row boxes by entity index
// (null: no row then): present exactly when a row was, with that box bit-exact.
fn expectOldBoxes(colliders: *const StaticColliderSystem, before: []const ?math.Aabb) !void {
    for (colliders.changesThisStep()) |change| {
        const box = before[change.entity.index] orelse {
            try std.testing.expect(change.old == null);
            continue;
        };
        const old = change.old orelse return error.TestExpectedOldPlacement;
        const expected: [4]u32 = @bitCast([4]f32{ box.min_x, box.min_y, box.max_x, box.max_y });
        const actual: [4]u32 = @bitCast([4]f32{ old.aabb.min_x, old.aabb.min_y, old.aabb.max_x, old.aabb.max_y });
        try std.testing.expectEqual(expected, actual);
    }
}

// The row box of each entity index `boxes` covers, or null without a row.
fn rowBoxes(colliders: *const StaticColliderSystem, boxes: []?math.Aabb) void {
    for (boxes, 0..) |*box, index| {
        box.* = null;
        if (index >= colliders.row_of_index.items.len) continue;
        const row = colliders.row_of_index.items[index];
        if (row != no_row) box.* = colliders.rowAabb(row);
    }
}

test "collider change carries the old row's box" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{
        .{ .create_entity = staticTemplate(.{ .x = 40.25, .y = 41.75 }, .{ .x = 8, .y = 8 }) },
        .{ .create_entity = staticTemplate(.{ .x = 300.5, .y = 90.125 }, .{ .x = 20, .y = 6 }) },
        .{ .create_entity = staticTemplate(.{ .x = 600.375, .y = 700.625 }, .{ .x = 8, .y = 8 }) },
    });
    var entities: [3]EntityId = undefined;
    for (fixture.colliders.changesThisStep(), &entities) |change, *entity| entity.* = change.entity;
    var before: [8]?math.Aabb = undefined;
    // A move, a mode-only response change, and a destroy with a create reusing its index.
    rowBoxes(&fixture.colliders, &before);
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{
        .{ .set_movement_body = .{ .entity = entities[0], .body = .{ .position = .{ .x = 200.5, .y = 210.25 }, .previous_position = .{ .x = 200.5, .y = 210.25 } } } },
        .{ .set_collision_response = .{ .entity = entities[1], .response = .{ .mode = .trigger, .mobility = .static } } },
        .{ .destroy_entity = entities[2] },
        .{ .create_entity = staticTemplate(.{ .x = 900.875, .y = 33.5 }, .{ .x = 8, .y = 8 }) },
    });
    try std.testing.expectEqual(@as(usize, 3), fixture.colliders.changesThisStep().len);
    try expectOldBoxes(&fixture.colliders, &before);
    for (fixture.colliders.changesThisStep()) |change| try std.testing.expect(change.old != null and change.new != null);
    // A destroy.
    rowBoxes(&fixture.colliders, &before);
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .destroy_entity = entities[0] }});
    try std.testing.expectEqual(@as(usize, 1), fixture.colliders.changesThisStep().len);
    try std.testing.expect(fixture.colliders.changesThisStep()[0].new == null);
    try expectOldBoxes(&fixture.colliders, &before);
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
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    for ([_]*ThreadSystem{ &serial_threads, &threads }) |thread_system| try expectSyncOutOfMemorySafe(thread_system);
}

fn expectSyncOutOfMemorySafe(thread_system: *ThreadSystem) !void {
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

        const blocks_before = fixture.colliders.chunks.blocks.items.len;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = fail_index });
        fixture.colliders.allocator = failing.allocator();
        const result = fixture.colliders.sync(&fixture.data, thread_system);
        fixture.colliders.allocator = std.testing.allocator;
        if (result) |_| {
            try std.testing.expect(!failing.has_induced_failure);
            if (thread_system.workerThreadCount() != 0) try std.testing.expect(!fixture.colliders.last_batches.get(.rewrite).ran_inline);
            // The swept sync grew the block pool.
            try std.testing.expect(fixture.colliders.chunks.blocks.items.len > blocks_before);
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
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var templates: [16]StructuralCommand = undefined;
    for (&templates, 0..) |*command, at| command.* = .{ .create_entity = staticTemplate(.{ .x = @floatFromInt(at * 100), .y = 300 }, .{ .x = 90, .y = 90 }) };
    // A static alone in its chunk, destroyed by the measured commit.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 40, .y = 1000 }, .{ .x = 8, .y = 8 }) }});
    const kept = fixture.colliders.changesThisStep()[0].entity;
    const kept_chunk: u32 = 7 * test_geometry.grid.chunks_x;
    // Warm: create, then destroy, so rows, the block pool, and the change list hold
    // their high-water.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &templates);
    var destroys: [16]StructuralCommand = undefined;
    for (fixture.colliders.changesThisStep(), &destroys) |change, *command| command.* = .{ .destroy_entity = change.entity };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &destroys);
    try std.testing.expect(fixture.colliders.chunks.slot(0, kept_chunk) != empty_block);

    // The seam's reserve runs with the real allocator before the commit, as the pipeline
    // does. Payload slabs and block pools grow inside the sync's reserve; the fill and
    // install after that allocate nothing while claiming slots and blocks for the new
    // chunks and releasing the destroyed static's.
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
    fixture.colliders.capture(&fixture.frame);
    const threads = syncThreadsFor(&fixture.colliders, &serial_threads);
    try fixture.colliders.prepareSync(&fixture.data, threads);
    {
        // Any new allocation fails.
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        fixture.colliders.allocator = failing.allocator();
        defer fixture.colliders.allocator = std.testing.allocator;
        fixture.colliders.finishSync(threads);
        try std.testing.expect(!failing.has_induced_failure);
    }
    try std.testing.expectEqual(@as(usize, 16), static_colliders_test_support.liveRowCount(fixture.colliders));
    try std.testing.expectEqual(empty_block, fixture.colliders.chunks.slot(0, kept_chunk));
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
        // The rebuild's fill on workers lays out the same blocks and bytes as inline.
        var threaded_rebuilt = try serial.rebuiltOn(&threads, 8);
        defer threaded_rebuilt.deinit();
        try expectIdenticalLayout(&rebuilt, &threaded_rebuilt, 3);
        try std.testing.expect(!threaded_rebuilt.last_batches.get(.rewrite).ran_inline and threaded_rebuilt.last_batches.get(.rewrite).range_count > 1);
        const batch = threaded.colliders.last_batches.get(.rewrite);
        if (!batch.ran_inline and batch.range_count > 1) threaded_ranges += 1;
    }
    try std.testing.expect(threaded_ranges != 0);
}

test "a splice worker cap of zero keeps the chunk splice inline on a multi-worker ThreadSystem and lists the same chunks" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
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
    for (0..10) |_| {
        live.clearRetainingCapacity();
        for (uncapped.data.movementBodySliceConst().entities) |entity| try live.append(std.testing.allocator, entity);
        try denseMixedCommands(random, &uncapped.data, live.items, &commands);
        try commitForTestWith(&uncapped.frame, &uncapped.data, &uncapped.colliders, commands.items, &threads);
        try commitForTestWith(&capped.frame, &capped.data, &capped.colliders, commands.items, &threads);
        try expectIdenticalLayout(&uncapped.colliders, &capped.colliders, 3);
        const capped_batch = capped.colliders.last_batches.get(.rewrite);
        const batch = uncapped.colliders.last_batches.get(.rewrite);
        try std.testing.expectEqual(batch.item_count, capped_batch.item_count);
        try std.testing.expect(capped_batch.ran_inline and capped_batch.active_worker_threads == 0);
        if (!batch.ran_inline and batch.worker_thread_ranges != 0) threaded_ranges += 1;
    }
    try std.testing.expect(threaded_ranges != 0);
}

// Every growth counter's once-only log flag is set.
fn expectGrowthsLogged(colliders: *const StaticColliderSystem) !void {
    try std.testing.expect(colliders.row_growth_logged);
    try std.testing.expect(colliders.payload_growth_logged);
}

test "a rebuild keeps the row and payload growth logs' flags" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var prng = std.Random.DefaultPrng.init(0x9e0);
    const random = prng.random();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    for (0..60) |_| try commands.append(std.testing.allocator, randomStatic(random));
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, commands.items);
    try expectGrowthsLogged(&fixture.colliders);

    // A rebuild of the same statics keeps the logged flags.
    try fixture.colliders.rebuild(&fixture.data, test_geometry, null);
    try expectGrowthsLogged(&fixture.colliders);

    // So does a rebuild over no statics.
    var empty = DataSystem.init(std.testing.allocator);
    defer empty.deinit();
    try fixture.colliders.rebuild(&empty, test_geometry, null);
    try expectGrowthsLogged(&fixture.colliders);
    try std.testing.expectEqual(@as(usize, 0), static_colliders_test_support.liveRowCount(fixture.colliders));
}

test "a move inside its footprint chunks rewrites those spans and no other chunk" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    // A 3-chunk-wide static, then a move that keeps its chunk rect but changes the cells.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 140, .y = 140 }, .{ .x = 300, .y = 20 }) }});
    const entity = fixture.colliders.changesThisStep()[0].entity;
    const live_before = listEntryCount(&fixture.colliders);
    const position = math.Vec2{ .x = 150, .y = 150 };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .set_movement_body = .{ .entity = entity, .body = .{ .position = position, .previous_position = position } } }});
    const change = fixture.colliders.changesThisStep()[0];
    try std.testing.expect(!std.meta.eql(change.old.?.cells, change.new.?.cells));
    try std.testing.expect(fixture.colliders.last_batches.get(.rewrite).item_count > 0);
    try std.testing.expectEqual(live_before, listEntryCount(&fixture.colliders));
    try std.testing.expect(chunkPayloadOf(&fixture.colliders, 0, 15 * 16 + 15) == null);
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
    const capacity = fixture.colliders.rows.capacity;
    var destroys: [32]StructuralCommand = undefined;
    for (fixture.colliders.changesThisStep(), &destroys) |change, *command| command.* = .{ .destroy_entity = change.entity };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &destroys);
    try std.testing.expectEqual(@as(usize, 0), static_colliders_test_support.liveRowCount(fixture.colliders));
    try std.testing.expectEqual(pooled, fixture.colliders.rows.len);
    try std.testing.expectEqual(capacity, fixture.colliders.rows.capacity);
}

test "a sync that empties every block dispatches one fill unit per emptied item" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var creates: [32]StructuralCommand = undefined;
    for (&creates, 0..) |*command, at| command.* = .{ .create_entity = staticTemplate(.{ .x = @floatFromInt(at * 60), .y = 100 }, .{ .x = 8, .y = 8 }) };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &creates);
    // Each installed chunk and coarse block becomes one emptied item, holding at least one
    // record, so the old count of its records plus one would exceed this.
    try std.testing.expectEqual(@as(usize, 1), fixture.colliders.chunks.levelCount());
    var installed: usize = 0;
    for (0..fixture.colliders.chunks.slotCount(0)) |chunk| installed += @intFromBool(fixture.colliders.chunks.slot(0, chunk) != empty_block);
    for (&fixture.colliders.coarse) |*dir| {
        for (0..dir.slotCount(0)) |cell| installed += @intFromBool(dir.slot(0, cell) != empty_block);
    }
    try std.testing.expect(installed > 0);
    var destroys: [32]StructuralCommand = undefined;
    for (fixture.colliders.changesThisStep(), &destroys) |change, *command| command.* = .{ .destroy_entity = change.entity };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &destroys);
    try std.testing.expectEqual(installed, fixture.colliders.last_batches.get(.rewrite).item_count);
    try expectAnchors(&fixture.colliders);
}

test "a block pool that grows before its free list's reserve fails counts as payload growth" {
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    // The pool's capacity is the first allocation, the free list's the second.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    colliders.allocator = failing.allocator();
    defer colliders.allocator = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, colliders.reserveBlocks(&colliders.chunks, 4));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(colliders.chunks.blocks.capacity >= 4);
    try std.testing.expect(colliders.payload_growth_logged);
}

test "a warmed dense sync allocates nothing inline and running every stage on a multi-worker ThreadSystem (FailingAllocator)" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    try expectWarmDenseSyncAllocatesNothing(&serial_threads);
    try expectWarmDenseSyncAllocatesNothing(&threads);
}

fn expectWarmDenseSyncAllocatesNothing(threads: *ThreadSystem) !void {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    fixture.colliders.splice_controls = .{ .adaptive = false, .items_per_range = 8 };
    // 48 one-cell statics over 48 chunks, each then moved one chunk over and back.
    var creates: [48]StructuralCommand = undefined;
    for (&creates, 0..) |*command, at| command.* = .{ .create_entity = staticTemplate(.{ .x = @floatFromInt((at % 12) * 128 + 4), .y = @floatFromInt((at / 12) * 128 + 4) }, .{ .x = 8, .y = 8 }) };
    try commitForTestWith(&fixture.frame, &fixture.data, &fixture.colliders, &creates, threads);
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
            try commitForTestWith(&fixture.frame, &fixture.data, &fixture.colliders, &moves, threads);
            continue;
        }
        // The seam's reserve runs with the real allocator; capture and the whole sync, every
        // reserve warm at the earlier rounds' high-water, allocate nothing.
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
        fixture.colliders.capture(&fixture.frame);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        fixture.colliders.allocator = failing.allocator();
        defer fixture.colliders.allocator = std.testing.allocator;
        try fixture.colliders.sync(&fixture.data, threads);
        try std.testing.expect(!failing.has_induced_failure);
        for (std.meta.tags(SyncStage)) |stage| {
            const batch = fixture.colliders.last_batches.get(static_colliders_test_support.colliderStage(stage));
            try std.testing.expect(batch.item_count != 0);
            if (threads.workerThreadCount() != 0) try std.testing.expect(!batch.ran_inline and batch.range_count > 1);
        }
    }
    try std.testing.expectEqual(@as(usize, 48), static_colliders_test_support.liveRowCount(fixture.colliders));
    try std.testing.expect(fixture.colliders.chunks.blocks.items.len != 0);
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
    try std.testing.expectError(error.OutOfMemory, fixture.colliders.reserveRowClaims(fixture.colliders.rows.capacity + 1));
    fixture.colliders.allocator = std.testing.allocator;
    const columns = fixture.colliders.rows.slice();
    try std.testing.expectEqual(columns.items(.level).ptr, fixture.colliders.row_level.ptr);
    try std.testing.expectEqual(columns.items(.entity).ptr, fixture.colliders.row_entity.ptr);
    try std.testing.expectEqual(columns.items(.cell_max_y).ptr, fixture.colliders.row_cell_max_y.ptr);
    // The retry adds rows beside the kept one.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 400, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    try std.testing.expectEqual(@as(usize, 2), static_colliders_test_support.liveRowCount(fixture.colliders));
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

test "rebuild bumps the collider revision and an empty sync does not" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{ .x = 16, .y = 16 } });
    try data.setCollisionBounds(entity, .{ .size = .{ .x = 16, .y = 16 } });
    try data.setCollisionResponse(entity, .{ .mobility = .static });
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try std.testing.expectEqual(@as(u64, 0), colliders.revision);
    try colliders.rebuild(&data, test_geometry, null);
    const revision = colliders.revision;
    try std.testing.expect(revision != 0);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    try colliders.sync(&data, &threads);
    try std.testing.expectEqual(revision, colliders.revision);
    colliders.markDirty(entity);
    try colliders.sync(&data, &threads);
    try std.testing.expectEqual(revision +% 1, colliders.revision);
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
    const entities = try std.testing.allocator.alloc(u32, hits.min_x.len);
    defer std.testing.allocator.free(entities);
    const view = colliders.view();
    const full = view.collectOverlaps(level, box, entities, hits.min_x, hits.min_y, hits.max_x, hits.max_y, idleSpanIds());
    try std.testing.expectEqual(expected.items.len, full);
    for (expected.items, 0..) |hit, index| {
        try std.testing.expectEqual(hit.entity, entities[index]);
        try std.testing.expectEqual(hit.aabb, hits.at(index));
    }
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

test "a move across a tile inside its chunk rewrites that chunk's query bit" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    // A one-tile static in chunk 0, moved one tile over inside the chunk, then inside its
    // tile.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    const entity = fixture.colliders.changesThisStep()[0].entity;
    const block = fixture.colliders.chunks.slot(0, 0);
    try std.testing.expect(block != empty_block);
    const bits_before = fixture.colliders.chunks.payload(block).anchors;
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{moveCommand(entity, .{ .x = 72, .y = 40 })});
    try std.testing.expect(fixture.colliders.last_batches.get(.rewrite).item_count > 0);
    // The chunk keeps its block; the anchor bit moved one cell over.
    try std.testing.expectEqual(block, fixture.colliders.chunks.slot(0, 0));
    const bits_after = fixture.colliders.chunks.payload(block).anchors;
    try std.testing.expectEqual(@as(u16, 1), bits_after.set_bits);
    try std.testing.expect(!std.meta.eql(bits_before, bits_after));
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
    const cells_before = fixture.colliders.view().chunkRows(0, 0);
    const nav_before = cells_before.min_x[0];
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{moveCommand(entity, .{ .x = 73, .y = 41 })});
    try std.testing.expect(fixture.colliders.last_batches.get(.rewrite).item_count > 0);
    try std.testing.expectEqual(nav_before, fixture.colliders.view().chunkRows(0, 0).min_x[0]);
    var rebuilt_again = try fixture.rebuilt();
    defer rebuilt_again.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt_again, 1);
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
    // d's chunk empties: its block is released and its slot cleared.
    const d_chunk: u32 = 2 * test_geometry.grid.chunks_x + 2;
    try std.testing.expect(serial.colliders.chunks.slot(0, d_chunk) != empty_block);
    try Step.run(&serial, &threaded, &threads, &.{.{ .set_world_level = .{ .entity = d, .level = 2 } }});
    try std.testing.expectEqual(empty_block, serial.colliders.chunks.slot(0, d_chunk));
    try std.testing.expect(!serial.colliders.view().chunkHasRows(0, d_chunk));
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
    try std.testing.expect(serial.colliders.chunks.blocks.items.len != 0);
}

test "a chunk's anchor block is released when its last anchor leaves and reused by the next" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    const entity = fixture.colliders.changesThisStep()[0].entity;
    // The first move claims a second block before the old one is released.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{moveCommand(entity, .{ .x = 168, .y = 40 })});
    const pooled = fixture.colliders.chunks.blocks.items.len;
    const capacity = fixture.colliders.chunks.blocks.capacity;
    try std.testing.expectEqual(@as(usize, 2), pooled);
    var from_chunk: u32 = 1;
    for (0..8) |step| {
        const to_chunk: u32 = if (step % 2 == 0) 2 else 1;
        const freed = fixture.colliders.chunks.block_free.items[0];
        try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{moveCommand(entity, .{ .x = @as(f32, @floatFromInt(to_chunk)) * 128 + 40, .y = 40 })});
        // The emptied chunk lost its slot; the new chunk took the free block.
        try std.testing.expectEqual(empty_block, fixture.colliders.chunks.slot(0, from_chunk));
        try std.testing.expect(!fixture.colliders.view().chunkHasRows(0, from_chunk));
        try std.testing.expectEqual(freed, fixture.colliders.chunks.slot(0, to_chunk));
        try std.testing.expectEqual(pooled, fixture.colliders.chunks.blocks.items.len);
        from_chunk = to_chunk;
    }
    try std.testing.expectEqual(capacity, fixture.colliders.chunks.blocks.capacity);
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
}

test "a payload that outgrows its class moves to a larger slot and frees the old one for reuse" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    const block = fixture.colliders.chunks.slot(0, 0);
    const small = fixture.colliders.chunks.payloadConst(block).slot;
    try std.testing.expect(!small.isNone());
    // A second static in the chunk outgrows its one-record columns: the chunk keeps its
    // block and takes a slot of a larger class.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 72, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    try std.testing.expectEqual(block, fixture.colliders.chunks.slot(0, 0));
    const grown = fixture.colliders.chunks.payloadConst(block).slot;
    try std.testing.expect(grown.class > small.class);
    try std.testing.expectEqual(@as(u32, 2), fixture.colliders.chunks.payloadConst(block).nav_len);
    try std.testing.expectEqualSlices(u32, &.{small.id}, fixture.colliders.payloads.classes[small.class].claims.free.items);
    // A static alone in a fresh chunk takes the freed slot.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 296, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    const fresh = fixture.colliders.chunks.slot(0, 2);
    try std.testing.expect(fresh != empty_block);
    try std.testing.expectEqual(small, fixture.colliders.chunks.payloadConst(fresh).slot);
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.payloads.classes[small.class].claims.free.items.len);
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
}

test "an emptied chunk returns its block and payload slot, and the next fresh chunk reuses them" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{
        .{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) },
        .{ .create_entity = staticTemplate(.{ .x = 168, .y = 40 }, .{ .x = 8, .y = 8 }) },
    });
    const leaving = fixture.colliders.changesThisStep()[1].entity;
    const block = fixture.colliders.chunks.slot(0, 1);
    const slot = fixture.colliders.chunks.payloadConst(block).slot;
    try std.testing.expect(block != empty_block and !slot.isNone());
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .destroy_entity = leaving }});
    try std.testing.expectEqual(empty_block, fixture.colliders.chunks.slot(0, 1));
    try std.testing.expectEqualSlices(u32, &.{block}, fixture.colliders.chunks.block_free.items);
    try std.testing.expect(fixture.colliders.chunks.payloadConst(block).slot.isNone());
    try std.testing.expectEqualSlices(u32, &.{slot.id}, fixture.colliders.payloads.classes[slot.class].claims.free.items);
    try expectAnchors(&fixture.colliders);
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 296, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    try std.testing.expectEqual(block, fixture.colliders.chunks.slot(0, 2));
    try std.testing.expectEqual(slot, fixture.colliders.chunks.payloadConst(block).slot);
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.chunks.block_free.items.len);
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
    const covered = fixture.colliders.chunks.payload(fixture.colliders.chunks.slot(0, 1));
    try std.testing.expectEqual(@as(u16, 0), covered.anchors.set_bits);
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
    const corner_chunk: u32 = 2 * partial.grid.chunks_x + 2;
    const block = fixture.colliders.chunks.slot(0, corner_chunk);
    try std.testing.expect(block != empty_block);
    try std.testing.expectEqual(@as(u16, 2), fixture.colliders.chunks.payload(block).anchors.set_bits);
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

test "a block claim reserve fails as OutOfMemory at 2^32 - 1 blocks before asking the allocator, and one block short of it reaches the allocator" {
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    colliders.allocator = failing.allocator();
    defer colliders.allocator = std.testing.allocator;
    // The pool reads `held` blocks with room for them all and no free id: the reserve reads
    // only its length and capacity, so no block memory backs the count. Restored before
    // deinit.
    const Block = @typeInfo(@TypeOf(colliders.chunks.blocks.items)).pointer.child;
    var spare: [1]Block = undefined;
    const real_blocks = colliders.chunks.blocks;
    defer colliders.chunks.blocks = real_blocks;
    for ([_]usize{ empty_block - 1, empty_block - 2 }) |held| {
        colliders.chunks.blocks.items = (&spare).ptr[0..held];
        colliders.chunks.blocks.capacity = empty_block - 1;
        try std.testing.expectError(error.OutOfMemory, colliders.chunks.reserveClaims(colliders.allocator, 1));
        try std.testing.expectEqual(held, colliders.chunks.blocks.items.len);
        try std.testing.expectEqual(@as(usize, 0), colliders.chunks.block_free.items.len);
        // At the limit nothing is asked of the allocator; one short, the free list's growth is.
        try std.testing.expectEqual(held == empty_block - 2, failing.has_induced_failure);
    }
}

test "chunk-ordered, shuffled, and churned statics share per-cell floats and query hits" {
    const positions = [_]math.Vec2{
        .{ .x = 4, .y = 4 },     .{ .x = 36, .y = 4 },   .{ .x = 68, .y = 4 },   .{ .x = 100, .y = 4 },
        .{ .x = 4, .y = 132 },   .{ .x = 36, .y = 132 }, .{ .x = 68, .y = 132 }, .{ .x = 100, .y = 132 },
        .{ .x = 400, .y = 400 }, .{ .x = 520, .y = 80 },
    };
    var ordered_commands: [positions.len]StructuralCommand = undefined;
    for (&ordered_commands, positions) |*command, position| command.* = .{ .create_entity = staticTemplate(position, .{ .x = 8, .y = 8 }) };
    var shuffled_commands = ordered_commands;
    var prng = std.Random.DefaultPrng.init(0x51c);
    prng.random().shuffle(StructuralCommand, &shuffled_commands);

    var ordered = try SeamFixture.init();
    defer ordered.deinit();
    var shuffled = try SeamFixture.init();
    defer shuffled.deinit();
    try commitForTest(&ordered.frame, &ordered.data, &ordered.colliders, &ordered_commands);
    try commitForTest(&shuffled.frame, &shuffled.data, &shuffled.colliders, &shuffled_commands);

    var churned = try SeamFixture.init();
    defer churned.deinit();
    try commitForTest(&churned.frame, &churned.data, &churned.colliders, &ordered_commands);
    var destroys: [4]StructuralCommand = undefined;
    var recreates: [4]StructuralCommand = undefined;
    for (churned.colliders.changesThisStep()[0..4], &destroys, &recreates) |change, *destroy, *recreate| {
        destroy.* = .{ .destroy_entity = change.entity };
        const body = churned.data.movementBodyConst(change.entity).?;
        recreate.* = .{ .create_entity = staticTemplate(body.position, .{ .x = 8, .y = 8 }) };
    }
    try commitForTest(&churned.frame, &churned.data, &churned.colliders, &destroys);
    try commitForTest(&churned.frame, &churned.data, &churned.colliders, &recreates);

    const box = math.Aabb{ .min_x = 0, .min_y = 0, .max_x = 2000, .max_y = 2000 };
    var expected: std.ArrayList(BruteHit) = .empty;
    defer expected.deinit(std.testing.allocator);
    const hits = try TestHits.init(32);
    defer hits.deinit();
    try expectQueryMatchesBruteForce(&ordered.colliders, 0, box, &expected, hits);
    const ordered_hits = try std.testing.allocator.alloc(math.Aabb, expected.items.len);
    defer std.testing.allocator.free(ordered_hits);
    for (expected.items, ordered_hits) |hit, *aabb| aabb.* = hit.aabb;
    try expectQueryMatchesBruteForce(&shuffled.colliders, 0, box, &expected, hits);
    for (expected.items, ordered_hits) |hit, aabb| try std.testing.expectEqual(aabb, hit.aabb);
    try expectQueryMatchesBruteForce(&churned.colliders, 0, box, &expected, hits);
    for (expected.items, ordered_hits) |hit, aabb| try std.testing.expectEqual(aabb, hit.aabb);
    // Entity indices differ across the three builds. Each cell holds one static, so the
    // float runs match.
    try expectSameQueryFloats(&ordered.colliders, &shuffled.colliders, 1);
    try expectSameQueryFloats(&ordered.colliders, &churned.colliders, 1);
}

fn expectSameQueryFloats(a: *const StaticColliderSystem, b: *const StaticColliderSystem, levels: u16) !void {
    const chunk_count = levelChunkCount(a.geometry.?);
    for (0..levels) |level| for (0..chunk_count) |chunk| {
        const payload_a = chunkPayloadOf(a, @intCast(level), @intCast(chunk));
        const payload_b = chunkPayloadOf(b, @intCast(level), @intCast(chunk));
        const query_a: usize = if (payload_a) |payload| payload.query_len else 0;
        const query_b: usize = if (payload_b) |payload| payload.query_len else 0;
        try std.testing.expectEqual(query_a, query_b);
        if (query_a == 0) continue;
        try std.testing.expectEqualSlices(f32, payload_a.?.query_min_x[0..query_a], payload_b.?.query_min_x[0..query_b]);
        try std.testing.expectEqualSlices(f32, payload_a.?.query_min_y[0..query_a], payload_b.?.query_min_y[0..query_b]);
        try std.testing.expectEqualSlices(f32, payload_a.?.query_max_x[0..query_a], payload_b.?.query_max_x[0..query_b]);
        try std.testing.expectEqualSlices(f32, payload_a.?.query_max_y[0..query_a], payload_b.?.query_max_y[0..query_b]);
    };
}

test "a sync that drops a middle static leaves the survivors contiguous" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{
        .{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) },
        .{ .create_entity = staticTemplate(.{ .x = 44, .y = 44 }, .{ .x = 8, .y = 8 }) },
        .{ .create_entity = staticTemplate(.{ .x = 48, .y = 48 }, .{ .x = 8, .y = 8 }) },
    });
    const middle = fixture.colliders.changesThisStep()[1].entity;
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .destroy_entity = middle }});
    const spans = fixture.colliders.view().chunkRows(0, 0);
    try std.testing.expectEqual(@as(usize, 2), spans.entity.len);
    try std.testing.expectEqual(@intFromPtr(spans.entity.ptr) + @sizeOf(u32), @intFromPtr(&spans.entity[1]));
    try std.testing.expectEqual(@intFromPtr(spans.min_x.ptr) + @sizeOf(u32), @intFromPtr(&spans.min_x[1]));
    try std.testing.expectEqualSlices(u32, &.{ 0, 2 }, spans.entity);
    const payload = chunkPayloadOf(&fixture.colliders, 0, 0).?;
    const query_len: usize = payload.query_len;
    try std.testing.expectEqual(@as(usize, 2), query_len);
    const query_min_x = payload.query_min_x[0..query_len];
    const query_entity = payload.query_entity[0..query_len];
    try std.testing.expectEqual(@intFromPtr(query_min_x.ptr) + @sizeOf(f32), @intFromPtr(&query_min_x[1]));
    try std.testing.expectEqual(@intFromPtr(query_entity.ptr) + @sizeOf(u32), @intFromPtr(&query_entity[1]));
    try std.testing.expectEqualSlices(u32, &.{ 0, 2 }, query_entity);
}

test "a chunk rewrite matches across range sizes and worker counts" {
    var prng = std.Random.DefaultPrng.init(0xd00d);
    const random = prng.random();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    for (0..40) |_| try commands.append(std.testing.allocator, randomStatic(random));
    var baseline = try SeamFixture.init();
    defer baseline.deinit();
    try commitForTest(&baseline.frame, &baseline.data, &baseline.colliders, commands.items);
    const ranges = [_]usize{ 1, 8, 64 };
    for (ranges) |items_per_range| {
        var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
        defer threads.deinit();
        var threaded = try SeamFixture.init();
        defer threaded.deinit();
        threaded.colliders.splice_controls = .{ .adaptive = false, .items_per_range = items_per_range };
        try commitForTestWith(&threaded.frame, &threaded.data, &threaded.colliders, commands.items, &threads);
        try expectIdenticalLayout(&baseline.colliders, &threaded.colliders, 1);
        if (items_per_range < 64) try std.testing.expect(!threaded.colliders.last_batches.get(.rewrite).ran_inline);
    }
}

// A warmed move inside one chunk: the seam's reserve, the commit, and the capture run with
// the real allocator; the whole sync then allocates nothing and rewrites the chunk's
// installed columns in place.
fn expectWarmMoveInsideChunkAllocatesNothing(thread_system: *ThreadSystem) !void {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    fixture.colliders.splice_controls = .{ .adaptive = false, .items_per_range = 8 };
    // Eight one-cell statics on two cell rows of chunk 0.
    var creates: [8]StructuralCommand = undefined;
    for (&creates, 0..) |*command, at| command.* = .{ .create_entity = staticTemplate(.{ .x = @floatFromInt((at % 4) * 32 + 4), .y = @floatFromInt((at / 4) * 32 + 4) }, .{ .x = 8, .y = 8 }) };
    try commitForTestWith(&fixture.frame, &fixture.data, &fixture.colliders, &creates, thread_system);
    const moved = fixture.colliders.changesThisStep()[0].entity;
    const positions = [_]math.Vec2{ .{ .x = 68, .y = 68 }, .{ .x = 4, .y = 4 } };
    // Warm: the move there and back, so the columns and the sync scratch hold their high-water.
    for (positions) |position| try commitForTestWith(&fixture.frame, &fixture.data, &fixture.colliders, &.{moveCommand(moved, position)}, thread_system);
    const block = fixture.colliders.chunks.slot(0, 0);
    try std.testing.expect(block != empty_block);
    const columns = fixture.colliders.chunks.payloadConst(block).nav_entity.ptr;

    try commitAndCapture(&fixture.frame, &fixture.data, &fixture.colliders, &.{moveCommand(moved, positions[0])});
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        fixture.colliders.allocator = failing.allocator();
        defer fixture.colliders.allocator = std.testing.allocator;
        try fixture.colliders.sync(&fixture.data, thread_system);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    }
    if (thread_system.workerThreadCount() != 0) try std.testing.expect(!fixture.colliders.last_batches.get(.rewrite).ran_inline);
    try std.testing.expectEqual(@as(usize, 1), fixture.colliders.changesThisStep().len);
    try std.testing.expectEqual(block, fixture.colliders.chunks.slot(0, 0));
    try std.testing.expectEqual(columns, fixture.colliders.chunks.payloadConst(block).nav_entity.ptr);
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
}

test "a warmed move inside one chunk syncs in place and allocates nothing, serial and on a multi-worker ThreadSystem (FailingAllocator)" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    for ([_]*ThreadSystem{ &serial_threads, &threads }) |thread_system| try expectWarmMoveInsideChunkAllocatesNothing(thread_system);
}

test "a sync that shrinks, regrows, and reorders a chunk in place matches a rebuild" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    // Twelve one-cell statics in chunk 0, so its columns hold 16.
    var creates: [12]StructuralCommand = undefined;
    for (&creates, 0..) |*command, at| command.* = .{ .create_entity = staticTemplate(.{ .x = @floatFromInt((at % 4) * 32 + 4), .y = @floatFromInt((at / 4) * 32 + 4) }, .{ .x = 8, .y = 8 }) };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &creates);
    var statics: [12]EntityId = undefined;
    for (fixture.colliders.changesThisStep(), &statics) |change, *entity| entity.* = change.entity;
    const block = fixture.colliders.chunks.slot(0, 0);
    const slot = fixture.colliders.chunks.payloadConst(block).slot;
    const columns = fixture.colliders.chunks.payloadConst(block).nav_entity.ptr;
    // Destroy the first and last, move the second to the last cell, and create two: drops
    // at both ends, a relinked record, and new records merged among the kept.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{
        .{ .destroy_entity = statics[0] },
        .{ .destroy_entity = statics[11] },
        moveCommand(statics[1], .{ .x = 100, .y = 100 }),
        .{ .create_entity = staticTemplate(.{ .x = 68, .y = 100 }, .{ .x = 8, .y = 8 }) },
        .{ .create_entity = staticTemplate(.{ .x = 36, .y = 100 }, .{ .x = 8, .y = 8 }) },
    });
    try std.testing.expectEqual(slot, fixture.colliders.chunks.payloadConst(block).slot);
    try std.testing.expectEqual(columns, fixture.colliders.chunks.payloadConst(block).nav_entity.ptr);
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
    // Every static but one leaves: the chunk shrinks in place.
    var destroys: [10]StructuralCommand = undefined;
    for (statics[2..11], destroys[0..9]) |entity, *command| command.* = .{ .destroy_entity = entity };
    destroys[9] = moveCommand(statics[1], .{ .x = 4, .y = 4 });
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &destroys);
    try std.testing.expectEqual(slot, fixture.colliders.chunks.payloadConst(block).slot);
    try std.testing.expectEqual(columns, fixture.colliders.chunks.payloadConst(block).nav_entity.ptr);
    var shrunk = try fixture.rebuilt();
    defer shrunk.deinit();
    try expectSameRows(&fixture.colliders, &shrunk, 1);
}

test "a chunk at exactly its capacity takes an in-chunk move in place" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    // Sixteen one-cell statics fill chunk 0's sixteen cells, so its columns hold exactly 16.
    var creates: [16]StructuralCommand = undefined;
    for (&creates, 0..) |*command, at| command.* = .{ .create_entity = staticTemplate(.{ .x = @floatFromInt((at % 4) * 32 + 4), .y = @floatFromInt((at / 4) * 32 + 4) }, .{ .x = 8, .y = 8 }) };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &creates);
    const block = fixture.colliders.chunks.slot(0, 0);
    const payload = fixture.colliders.chunks.payload(block);
    try std.testing.expectEqual(@as(u32, 16), payload.nav_len);
    try std.testing.expectEqual(payload.nav_cap, payload.nav_len);
    try std.testing.expectEqual(payload.query_cap, payload.query_len);
    const slot = payload.slot;
    // A move inside its own cell relinks it: one record leaves and one enters, so the
    // full columns hold the result.
    const moved = fixture.colliders.changesThisStep()[5].entity;
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{moveCommand(moved, .{ .x = 52, .y = 52 })});
    try std.testing.expectEqual(@as(usize, 1), fixture.colliders.changesThisStep().len);
    try std.testing.expectEqual(block, fixture.colliders.chunks.slot(0, 0));
    try std.testing.expectEqual(slot, fixture.colliders.chunks.payloadConst(block).slot);
    try std.testing.expectEqual(payload.nav_entity.ptr, fixture.colliders.chunks.payloadConst(block).nav_entity.ptr);
    try std.testing.expectEqual(@as(u32, 16), fixture.colliders.chunks.payloadConst(block).nav_cap);
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
}

fn expectRebuildOutOfMemorySafe(thread_system: *ThreadSystem) !void {
    var prng = std.Random.DefaultPrng.init(0x7eb1);
    const random = prng.random();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    var source = try SeamFixture.init();
    defer source.deinit();
    for (0..24) |_| try commands.append(std.testing.allocator, randomStatic(random));
    try commitForTest(&source.frame, &source.data, &source.colliders, commands.items);
    var target = try SeamFixture.init();
    defer target.deinit();
    commands.clearRetainingCapacity();
    for (0..40) |_| try commands.append(std.testing.allocator, randomStatic(random));
    try commitForTest(&target.frame, &target.data, &target.colliders, commands.items);
    var expected = try target.rebuilt();
    defer expected.deinit();
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var colliders = try source.rebuilt();
        defer colliders.deinit();
        colliders.splice_controls = .{ .adaptive = false, .items_per_range = 8 };
        const revision = colliders.revision;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = fail_index });
        colliders.allocator = failing.allocator();
        const result = colliders.rebuild(&target.data, test_geometry, thread_system);
        colliders.allocator = std.testing.allocator;
        if (result) |_| {
            try std.testing.expect(!failing.has_induced_failure);
            if (thread_system.workerThreadCount() != 0) try std.testing.expect(!colliders.last_batches.get(.rewrite).ran_inline);
            try expectSameRows(&colliders, &expected, 1);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(revision, colliders.revision);
            try expectSameRows(&colliders, &source.colliders, 1);
        }
    }
}

test "rebuild runs out of memory at every allocation and leaves the structure unchanged, inline and on workers" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    try expectRebuildOutOfMemorySafe(&threads);
    // No thread system: the fill runs inline.
    var prng = std.Random.DefaultPrng.init(0x7eb2);
    const random = prng.random();
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    for (0..40) |_| try commands.append(std.testing.allocator, randomStatic(random));
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, commands.items);
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var colliders = StaticColliderSystem.init(std.testing.allocator);
        defer colliders.deinit();
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = fail_index });
        colliders.allocator = failing.allocator();
        const result = colliders.rebuild(&fixture.data, test_geometry, null);
        colliders.allocator = std.testing.allocator;
        if (result) |_| {
            try std.testing.expect(colliders.last_batches.get(.rewrite).ran_inline);
            try expectSameRows(&colliders, &fixture.colliders, 1);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), static_colliders_test_support.liveRowCount(colliders));
        }
    }
}

test "each touch range's window starts its own cache line in both tiers, ends before the next range's, and fits the reserved extent" {
    var prng = std.Random.DefaultPrng.init(0x70c4);
    const random = prng.random();
    inline for (.{ ChunkTouch, CoarseTouch }) |Touch| {
        for (0..64) |_| {
            const range_count = random.intRangeAtMost(usize, 1, 40);
            var first: usize = 0;
            var previous_end: usize = 0;
            for (0..range_count) |range_index| {
                // Coarse ranges often write nothing or one touch; chunk ranges a few.
                const count = random.uintAtMost(usize, 9);
                const start = touchWindowStart(Touch, first, range_index);
                try std.testing.expectEqual(@as(usize, 0), start * @sizeOf(Touch) % thread_shared_record_alignment);
                try std.testing.expect(start >= previous_end);
                previous_end = start + count;
                first += count;
            }
            try std.testing.expect(previous_end <= touchExtent(Touch, first, range_count));
        }
    }
}

// The sync stages' dispatch on `thread_system` under `colliders`' controls, as `sync` builds.
fn syncThreadsFor(colliders: *const StaticColliderSystem, thread_system: *ThreadSystem) ColliderThreads {
    return .{ .thread_system = thread_system, .config = colliders.splice_controls };
}

test "a rebuild samples each stage's own rebuild tuner once, threads a fresh system's first rebuild, carries them to the next, and samples no sync tuner" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var prng = std.Random.DefaultPrng.init(0x51f1);
    const random = prng.random();
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    for (0..120) |_| try commands.append(std.testing.allocator, randomStatic(random));
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, commands.items);
    // Production's controls and untrained tuners, as world create builds the system.
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    var first_ran_inline: std.EnumArray(RebuildStage, bool) = .initFill(true);
    var first_threaded_stages: usize = 0;
    for (1..3) |rebuilds| {
        try colliders.rebuild(&fixture.data, test_geometry, &threads);
        for (std.meta.tags(RebuildStage)) |stage| {
            const batch = colliders.last_batches.get(static_colliders_test_support.colliderStage(stage));
            try std.testing.expect(batch.item_count != 0);
            // The stage selected through its own tuner, at its items and alignment, and
            // recorded one sample per rebuild into it.
            const tuner = colliders.rebuild_tuners.getPtrConst(stage);
            const request = tuner.last_request orelse return error.RebuildStageSkippedItsTuner;
            try std.testing.expectEqual(batch.item_count, request.item_count);
            try std.testing.expectEqual(batch.range_alignment_items, request.range_alignment_items);
            if (rebuilds == 1) {
                // A fresh tuner's first selection is the full pool: every stage with more
                // than one aligned range runs on workers.
                if (rangeCount(batch.item_count, batch.range_alignment_items) > 1) {
                    try std.testing.expect(!batch.ran_inline and batch.active_worker_threads > 0);
                    first_threaded_stages += 1;
                }
                first_ran_inline.set(stage, batch.ran_inline);
                try std.testing.expectEqual(@as(usize, 1), tuner.sample_count);
                continue;
            }
            // The tuner carried over: the second rebuild learns inline, never the fresh
            // full-pool selection. A threaded first sample is a different profile, so the
            // inline sample restarts the window; an inline first sample extends it.
            try std.testing.expect(batch.ran_inline);
            const expected: usize = if (first_ran_inline.get(stage)) 2 else 1;
            try std.testing.expectEqual(expected, tuner.sample_count);
        }
        try std.testing.expect(first_threaded_stages > 0);
        for (std.meta.tags(SyncStage)) |stage| {
            try std.testing.expectEqual(@as(usize, 0), colliders.tuners.get(stage).sample_count);
            try std.testing.expect(colliders.tuners.get(stage).last_request == null);
        }
        try expectSameRows(&colliders, &fixture.colliders, 1);
    }
    // An empty stage selects through no tuner: a rebuild of no entities samples nothing.
    var empty = DataSystem.init(std.testing.allocator);
    defer empty.deinit();
    const before = colliders.rebuild_tuners;
    try colliders.rebuild(&empty, test_geometry, &threads);
    try std.testing.expectEqual(@as(usize, 0), static_colliders_test_support.liveRowCount(colliders));
    for (std.meta.tags(RebuildStage)) |stage| {
        try std.testing.expectEqual(@as(usize, 0), colliders.last_batches.get(static_colliders_test_support.colliderStage(stage)).item_count);
        try std.testing.expectEqual(before.get(stage).sample_count, colliders.rebuild_tuners.get(stage).sample_count);
        try std.testing.expectEqual(before.get(stage).last_request.?.item_count, colliders.rebuild_tuners.get(stage).last_request.?.item_count);
    }
}

// `count` statics on levels below `levels`: sizes from a sliver to past the level (fine and
// coarse classes, chunk borders crossed), positions from off the level to beyond it.
fn appendRandomLeveledStatics(random: std.Random, count: usize, levels: u16, commands: *std.ArrayList(StructuralCommand)) !void {
    for (0..count) |_| {
        const template = staticTemplateOn(randomStaticPosition(random), randomStaticSize(random), random.uintLessThan(u16, levels));
        try commands.append(std.testing.allocator, .{ .create_entity = template });
    }
}

// Whether `a` and `b` hold the same rows, column by column, bit for bit.
fn expectSameRowColumns(a: *const StaticColliderSystem, b: *const StaticColliderSystem) !void {
    try std.testing.expectEqual(a.rows.len, b.rows.len);
    const columns_a = a.rows.slice();
    const columns_b = b.rows.slice();
    inline for (comptime std.meta.tags(std.MultiArrayList(Row).Field)) |field| {
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(columns_a.items(field)), std.mem.sliceAsBytes(columns_b.items(field)));
    }
    try std.testing.expectEqualSlices(u32, &a.query_class_rows, &b.query_class_rows);
}

fn expectSameBits(expected: f32, actual: f32) !void {
    try std.testing.expectEqual(@as(u32, @bitCast(expected)), @as(u32, @bitCast(actual)));
}

// The inclusive cells the half-open `aabb` covers, clamped to the grid: its min corner's
// cell to the last cell before its max edge, the plan lanes' cells in scalar form.
fn scalarFootprint(geometry: ColliderGeometry, aabb: math.Aabb) CellSpan {
    return .{
        .min_x = math.worldPosToCell(aabb.min_x, geometry.cell_size, geometry.grid.width),
        .min_y = math.worldPosToCell(aabb.min_y, geometry.cell_size, geometry.grid.height),
        .max_x = math.lastCellOfSpan(aabb.min_x, aabb.max_x, geometry.cell_size, geometry.grid.width),
        .max_y = math.lastCellOfSpan(aabb.min_y, aabb.max_y, geometry.cell_size, geometry.grid.height),
    };
}

fn planInput(x: f32, y: f32, offset_x: f32, offset_y: f32, size_x: f32, size_y: f32) PlanInput {
    return .{ .entity = EntityId.invalid, .level = 0, .x = x, .y = y, .offset_x = offset_x, .offset_y = offset_y, .size_x = size_x, .size_y = size_y };
}

test "the plan lanes place every static as the scalar footprint and query class, tails and non-finite extents included" {
    const geometry = test_geometry;
    const cell = geometry.cell_size;
    const chunk_edge = cell * @as(f32, @floatFromInt(geometry.grid.chunk_tiles));
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const inputs = [_]PlanInput{
        planInput(40, 40, 0, 0, 8, 8),
        // Across a chunk corner.
        planInput(chunk_edge - 10, chunk_edge - 10, 0, 0, 20, 20),
        // Extents exactly a class edge, from a cell-aligned min: the smaller class.
        planInput(cell, 2 * cell, 0, 0, 2 * cell, 4 * cell),
        // One ulp past a class edge: the next class.
        planInput(cell, cell, 0, 0, std.math.nextAfter(f32, 2 * cell, inf), cell),
        // A max edge on a cell boundary excludes the cell starting there.
        planInput(0, 0, cell, cell, cell, cell),
        // Coarse: wider than a chunk, and past the whole level.
        planInput(100, 300, -20, 5, 3 * chunk_edge, 10),
        planInput(-500, -500, 0, 0, 5000, 5000),
        // Off the level on both sides.
        planInput(-300, 10, 0, 0, 50, 50),
        planInput(5000, 5000, 0, 0, 50, 50),
        // Non-finite positions and extents.
        planInput(nan, 10, 0, 0, 8, 8),
        planInput(10, 10, 0, 0, inf, 8),
        planInput(10, 10, -inf, 0, 8, 8),
        planInput(10, nan, 0, 0, 8, nan),
        // Empty and inverted extents.
        planInput(64, 64, 0, 0, 0, 0),
        planInput(64, 64, 0, 0, -16, 8),
    };
    const top = geometry.topQueryClass();
    // Every count, so the masked tail holds one to three lanes after whole batches.
    for (1..inputs.len + 1) |count| {
        var colliders = StaticColliderSystem.init(std.testing.allocator);
        defer colliders.deinit();
        colliders.geometry = geometry;
        colliders.query_top_class = top;
        try colliders.plan_inputs.ensureTotalCapacity(std.testing.allocator, count);
        for (inputs[0..count]) |input| colliders.plan_inputs.appendAssumeCapacity(input);
        try colliders.reserveRebuildRows(count);
        try colliders.reservePlan(count, plan_range_alignment_items);
        colliders.planLanes(PlanColumns.of(&colliders.plan_inputs), colliders.rowLaneOutputs(), 0, count);
        for (inputs[0..count], 0..) |input, rank| {
            const aabb = math.aabbFromOffsetSize(.{ .x = input.x, .y = input.y }, .{ .x = input.offset_x, .y = input.offset_y }, .{ .x = input.size_x, .y = input.size_y });
            const row: u32 = @intCast(rank);
            const lanes = colliders.rowAabb(row);
            try expectSameBits(aabb.min_x, lanes.min_x);
            try expectSameBits(aabb.min_y, lanes.min_y);
            try expectSameBits(aabb.max_x, lanes.max_x);
            try expectSameBits(aabb.max_y, lanes.max_y);
            const cells = scalarFootprint(geometry, aabb);
            try std.testing.expectEqual(cells, colliders.rowPlacement(row).cells);
            const class = geometry.queryClass(top, aabb);
            try std.testing.expectEqual(@as(u16, class), colliders.plan_class.items[rank]);
            const rect = geometry.chunkRect(.{ .level = 0, .cells = cells });
            try std.testing.expectEqual(rect.count(), colliders.plan_touch_local[chunk_tier].items[rank]);
            try std.testing.expectEqual(@as(u32, @intFromBool(class > geometry.grid.shift)), colliders.plan_touch_local[coarse_tier].items[rank]);
        }
    }
}

test "a rebuild lays out the same rows, block ids, slot ids, and bytes on workers as inline across range sizes and worker counts" {
    var prng = std.Random.DefaultPrng.init(0x5e1ec7);
    const random = prng.random();
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    try appendRandomLeveledStatics(random, 160, 3, &commands);
    // Non-static slots between the statics: the select's windows keep only statics.
    for (0..40) |index| try commands.append(std.testing.allocator, .{ .create_entity = .{ .movement_body = .{ .position = .{ .x = @floatFromInt(index * 7), .y = 5 } } } });
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, commands.items);
    var inline_rebuilt = try fixture.rebuilt();
    defer inline_rebuilt.deinit();
    try expectSameRows(&inline_rebuilt, &fixture.colliders, 3);
    for ([_]usize{ 0, 2, 3 }) |workers| {
        var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = workers, .items_per_range = 1 });
        defer threads.deinit();
        for ([_]usize{ 1, 8, 64 }) |items_per_range| {
            var rebuilt = try fixture.rebuiltOn(&threads, items_per_range);
            defer rebuilt.deinit();
            try expectIdenticalLayout(&inline_rebuilt, &rebuilt, 3);
            try expectSameRowColumns(&inline_rebuilt, &rebuilt);
            if (workers == 0) continue;
            for (std.meta.tags(ColliderStage)) |stage| {
                const batch = rebuilt.last_batches.get(stage);
                if (batch.item_count > batch.items_per_range) try std.testing.expect(!batch.ran_inline);
            }
        }
    }
}

test "statics spanning chunk borders and coarse classes list every footprint chunk and coarse cell, threaded equal to inline" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    const chunk_edge = test_geometry.cell_size * @as(f32, @floatFromInt(test_geometry.grid.chunk_tiles));
    const placed = [_]struct { position: math.Vec2, size: math.Vec2, level: u16 }{
        // Two by two chunks around a chunk corner.
        .{ .position = .{ .x = chunk_edge - 20, .y = chunk_edge - 20 }, .size = .{ .x = 40, .y = 40 }, .level = 0 },
        // A coarse class wider than a chunk, one level up.
        .{ .position = .{ .x = 10, .y = 10 }, .size = .{ .x = 3 * chunk_edge, .y = 30 }, .level = 1 },
        // The whole level and past it: the top class.
        .{ .position = .{ .x = -100, .y = -100 }, .size = .{ .x = 5000, .y = 5000 }, .level = 0 },
        // One cell on a third level.
        .{ .position = .{ .x = 300, .y = 300 }, .size = .{ .x = 8, .y = 8 }, .level = 2 },
    };
    var commands: [placed.len]StructuralCommand = undefined;
    for (&commands, placed) |*command, static| command.* = .{ .create_entity = staticTemplateOn(static.position, static.size, static.level) };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &commands);
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var threaded = try fixture.rebuiltOn(&threads, 1);
    defer threaded.deinit();
    try expectIdenticalLayout(&rebuilt, &threaded, 3);
    try expectSameRows(&rebuilt, &fixture.colliders, 3);
    try expectQueryTier(&rebuilt);
    // Every footprint chunk lists its static, and no other chunk does.
    var listed: std.ArrayList(u32) = .empty;
    defer listed.deinit(std.testing.allocator);
    var footprint_chunks: usize = 0;
    for (fixture.colliders.changesThisStep()) |change| {
        const placement = placementOfIndex(&rebuilt, change.entity.index).?;
        const rect = test_geometry.chunkRect(placement);
        footprint_chunks += rect.count();
        var chunk_y = rect.min_y;
        while (chunk_y <= rect.max_y) : (chunk_y += 1) {
            var chunk_x = rect.min_x;
            while (chunk_x <= rect.max_x) : (chunk_x += 1) {
                try listedIndices(&rebuilt, placement.level, chunk_y * rect.chunks_x + chunk_x, &listed);
                try std.testing.expect(std.mem.indexOfScalar(u32, listed.items, change.entity.index) != null);
            }
        }
    }
    try std.testing.expectEqual(footprint_chunks, listEntryCount(&rebuilt));
}

test "touch grouping under any band splitters gives the same rows as a rebuild" {
    var prng = std.Random.DefaultPrng.init(0x5b11);
    const random = prng.random();
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    try appendRandomLeveledStatics(random, 150, 3, &commands);
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, commands.items);
    var expected = try fixture.rebuilt();
    defer expected.deinit();
    var random_splitters: TouchSplitters = undefined;
    for (&random_splitters) |*splitter| splitter.* = random.uintLessThan(u64, chunkKey(3, 0));
    std.sort.pdq(u64, &random_splitters, {}, std.sort.asc(u64));
    const splitter_sets = [_]TouchSplitters{
        // Every touch in band 0: one region holds every key, so keys collide there.
        @splat(ChunkTouchSort.max_key),
        // Every touch in the last band.
        @splat(0),
        random_splitters,
        // Every splitter on one level's first chunk: bands 0 and 63 only.
        @splat(chunkKey(1, 0)),
    };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    var base = StaticColliderSystem.init(std.testing.allocator);
    defer base.deinit();
    base.splice_controls = .{ .adaptive = false, .items_per_range = 8 };
    for (splitter_sets) |splitters| {
        for ([_]?*ThreadSystem{ null, &threads }) |thread_system| {
            var built = base.freshFor(test_geometry);
            defer built.deinit();
            const stages = built.rebuildStages(thread_system);
            const touches = try built.planStatics(&fixture.data, stages);
            try built.groupFootprints(stages, touches, .{ splitters, splitters });
            built.finishRebuild(stages);
            try expectSameRows(&built, &expected, 3);
        }
    }
}

test "a rebuild opens the directories of only the levels and coarse classes its statics enter" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    const coarse_size = test_geometry.cell_size * 4 * @as(f32, @floatFromInt(test_geometry.grid.chunk_tiles));
    var commands: [12]StructuralCommand = undefined;
    // Ten fine statics on level 0 and one on level 3, and one coarse static on level 3.
    for (commands[0..10], 0..) |*command, at| command.* = .{ .create_entity = staticTemplateOn(.{ .x = @floatFromInt(at * 150 + 4), .y = 40 }, .{ .x = 8, .y = 8 }, 0) };
    commands[10] = .{ .create_entity = staticTemplateOn(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }, 3) };
    commands[11] = .{ .create_entity = staticTemplateOn(.{ .x = 40, .y = 600 }, .{ .x = coarse_size, .y = 8 }, 3) };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &commands);
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try std.testing.expect(!colliders.payload_growth_logged);
    try colliders.rebuild(&fixture.data, test_geometry, null);
    try std.testing.expect(colliders.payload_growth_logged);
    const chunk_count = test_geometry.grid.chunkCount();
    try std.testing.expectEqual(@as(usize, 4), colliders.chunks.levelCount());
    for ([_]usize{ chunk_count, 0, 0, chunk_count }, 0..) |slots, level| try std.testing.expectEqual(slots, colliders.chunks.slotCount(@intCast(level)));
    const coarse_row = colliders.row_of_index.items[fixture.colliders.changesThisStep()[11].entity.index];
    const coarse_class = colliders.queryPlacement(colliders.rowPlacement(coarse_row), colliders.rowAabb(coarse_row)).class;
    try std.testing.expect(coarse_class > test_geometry.grid.shift);
    for (&colliders.coarse, 0..) |*dir, class| {
        for (0..4) |level| {
            const opened = class == coarse_class and level == 3;
            try std.testing.expectEqual(opened, dir.slotCount(@intCast(level)) != 0);
        }
    }
    try expectSameRows(&colliders, &fixture.colliders, 4);
}

// After every reserve of a rebuild, each reserve again at the sizes it holds and the fill and
// install allocate nothing.
fn expectWarmRebuildAllocatesNothing(thread_system: ?*ThreadSystem, data: *const DataSystem, expected: *const StaticColliderSystem) !void {
    var base = StaticColliderSystem.init(std.testing.allocator);
    defer base.deinit();
    base.splice_controls = .{ .adaptive = false, .items_per_range = 8 };
    var built = base.freshFor(test_geometry);
    defer built.deinit();
    const stages = built.rebuildStages(thread_system);
    try built.prepareRebuild(data, stages);
    {
        // Warm, every reserve finds its capacity, so `select`, `plan`, `touch`, `group`, the
        // fill, and the install all run under the armed allocator.
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        built.allocator = failing.allocator();
        defer built.allocator = std.testing.allocator;
        try built.prepareRebuild(data, stages);
        built.finishRebuild(stages);
        try std.testing.expect(!failing.has_induced_failure);
    }
    try expectIdenticalLayout(expected, &built, 3);
    try expectSameRowColumns(expected, &built);
}

test "a warmed rebuild runs every stage, fills, and installs without allocating, inline and on a multi-worker ThreadSystem (FailingAllocator)" {
    var prng = std.Random.DefaultPrng.init(0xfa11);
    const random = prng.random();
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    try appendRandomLeveledStatics(random, 120, 3, &commands);
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, commands.items);
    var expected = try fixture.rebuilt();
    defer expected.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    for ([_]?*ThreadSystem{ null, &threads }) |thread_system| try expectWarmRebuildAllocatesNothing(thread_system, &fixture.data, &expected);
}
// `collectOverlaps` over `box` into `out`, recording the walk's ids into `ids` in Debug.
fn collectRecorded(view: ColliderView, box: math.Aabb, out: *TestOverlaps, ids: *std.ArrayList(u32), required: *usize) usize {
    if (comptime builtin.mode == .debug) {
        var span_ids = SpanIds{ .ids = ids, .required = required };
        return view.collectOverlaps(0, box, &out.entity, &out.min_x, &out.min_y, &out.max_x, &out.max_y, &span_ids);
    }
    return view.collectOverlaps(0, box, &out.entity, &out.min_x, &out.min_y, &out.max_x, &out.max_y, idleSpanIds());
}

const TestOverlaps = struct {
    entity: [64]u32 = undefined,
    min_x: [64]f32 = undefined,
    min_y: [64]f32 = undefined,
    max_x: [64]f32 = undefined,
    max_y: [64]f32 = undefined,
};

test "a span recorder past its id capacity walks on, keeps every hit, and counts the range's whole need" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    // Eight one-cell statics in eight chunks along a row: the walk reads eight spans.
    var creates: [8]StructuralCommand = undefined;
    for (&creates, 0..) |*command, at| command.* = .{ .create_entity = staticTemplate(.{ .x = @floatFromInt(at * 128 + 4), .y = 4 }, .{ .x = 8, .y = 8 }) };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &creates);
    const view = fixture.colliders.view();
    // Two queries of one range: the first four chunks, then all eight.
    const boxes = [_]math.Aabb{
        .{ .min_x = 0, .min_y = 0, .max_x = 500, .max_y = 20 },
        .{ .min_x = 0, .min_y = 0, .max_x = 1020, .max_y = 20 },
    };
    const expected_hits = [_]usize{ 4, 8 };

    var reference_ids: std.ArrayList(u32) = .empty;
    defer reference_ids.deinit(std.testing.allocator);
    try reference_ids.ensureTotalCapacity(std.testing.allocator, 64);
    var reference_required: usize = 0;
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(std.testing.allocator);
    var required: usize = 0;
    for (boxes, expected_hits) |box, hits| {
        var reference = TestOverlaps{};
        try std.testing.expectEqual(hits, collectRecorded(view, box, &reference, &reference_ids, &reference_required));
        // No room for a single id: every span is skipped, every hit still written.
        var out = TestOverlaps{};
        try std.testing.expectEqual(hits, collectRecorded(view, box, &out, &ids, &required));
        try std.testing.expectEqualSlices(u32, reference.entity[0..hits], out.entity[0..hits]);
    }
    if (comptime builtin.mode == .debug) {
        try std.testing.expectEqual(@as(usize, 12), reference_required);
        try std.testing.expectEqual(reference_required, reference_ids.items.len);
        try std.testing.expectEqual(reference_required, required);
        try std.testing.expectEqual(@as(usize, 0), ids.items.len);
        // One grow to the recorded need holds the replay.
        try ids.ensureTotalCapacity(std.testing.allocator, required);
        required = 0;
        for (boxes) |box| {
            var out = TestOverlaps{};
            _ = collectRecorded(view, box, &out, &ids, &required);
        }
        try std.testing.expectEqualSlices(u32, reference_ids.items, ids.items);
        try std.testing.expectEqual(ids.items.len, required);
    }
}

// The configurations every sync partition test runs: inline (the tuner's own shape on no
// workers, and a fixed partition), then fixed partitions on two and three workers.
const sync_partitions = [_]struct { workers: usize, items_per_range: ?usize }{
    .{ .workers = 0, .items_per_range = null },
    .{ .workers = 0, .items_per_range = 8 },
    .{ .workers = 2, .items_per_range = 1 },
    .{ .workers = 2, .items_per_range = 8 },
    .{ .workers = 2, .items_per_range = 64 },
    .{ .workers = 3, .items_per_range = 1 },
    .{ .workers = 3, .items_per_range = 8 },
    .{ .workers = 3, .items_per_range = 64 },
};

// Seam fixtures and thread systems, one per `sync_partitions` entry, each fixture's
// colliders at its partition.
const SyncPartitions = struct {
    fixtures: [sync_partitions.len]SeamFixture = undefined,
    threads: [sync_partitions.len]ThreadSystem = undefined,
    ready: usize = 0,

    fn init(self: *SyncPartitions) !void {
        errdefer self.deinit();
        for (sync_partitions, 0..) |partition, at| {
            self.threads[at] = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = partition.workers, .items_per_range = 1 });
            self.fixtures[at] = SeamFixture.init() catch |err| {
                self.threads[at].deinit();
                return err;
            };
            self.ready += 1;
            if (partition.items_per_range) |items| self.fixtures[at].colliders.splice_controls = .{ .adaptive = false, .items_per_range = items };
        }
    }

    fn deinit(self: *SyncPartitions) void {
        for (self.fixtures[0..self.ready], self.threads[0..self.ready]) |*fixture, *threads| {
            fixture.deinit();
            threads.deinit();
        }
        self.ready = 0;
    }

    // Commits `commands` through every fixture's seam on its thread system.
    fn commit(self: *SyncPartitions, commands: []const StructuralCommand) !void {
        for (&self.fixtures, &self.threads) |*fixture, *threads| try commitForTestWith(&fixture.frame, &fixture.data, &fixture.colliders, commands, threads);
    }

    // Every partition's sync stage that spanned more than one range ran on workers.
    fn expectStagesThreaded(self: *const SyncPartitions) !void {
        for (sync_partitions, &self.fixtures) |partition, *fixture| {
            if (partition.workers == 0) continue;
            for (std.meta.tags(SyncStage)) |stage| {
                const batch = fixture.colliders.last_batches.get(static_colliders_test_support.colliderStage(stage));
                if (batch.item_count > batch.items_per_range) try std.testing.expect(!batch.ran_inline);
            }
        }
    }
};

test "a sync lays out the same rows, block ids, and slot ids on workers as inline across range sizes and worker counts, and equals a rebuild" {
    var partitions = SyncPartitions{};
    try partitions.init();
    defer partitions.deinit();
    const reference = &partitions.fixtures[0];
    var prng = std.Random.DefaultPrng.init(0x5c1d);
    const random = prng.random();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    for (0..140) |_| try commands.append(std.testing.allocator, randomStatic(random));
    try partitions.commit(commands.items);
    var live: std.ArrayList(EntityId) = .empty;
    defer live.deinit(std.testing.allocator);
    var threaded_stages: std.EnumSet(SyncStage) = .empty;
    for (0..8) |_| {
        live.clearRetainingCapacity();
        for (reference.data.movementBodySliceConst().entities) |entity| try live.append(std.testing.allocator, entity);
        try denseMixedCommands(random, &reference.data, live.items, &commands);
        try partitions.commit(commands.items);
        try partitions.expectStagesThreaded();
        for (partitions.fixtures[1..]) |*fixture| {
            try expectIdenticalLayout(&reference.colliders, &fixture.colliders, 3);
            try expectSameRowColumns(&reference.colliders, &fixture.colliders);
            try std.testing.expectEqualSlices(u32, reference.colliders.row_free.items, fixture.colliders.row_free.items);
        }
        for (std.meta.tags(SyncStage)) |stage| {
            const batch = partitions.fixtures[2].colliders.last_batches.get(static_colliders_test_support.colliderStage(stage));
            if (!batch.ran_inline and batch.range_count > 1) threaded_stages.insert(stage);
        }
        // The incremental structure equals a rebuild of the same statics.
        var rebuilt = try reference.rebuilt();
        defer rebuilt.deinit();
        try expectSameRows(&reference.colliders, &rebuilt, 3);
        try expectSameQueries(&reference.colliders, &rebuilt, 3);
        try expectAnchors(&reference.colliders);
    }
    // Every stage ran across ranges on workers at least once.
    try std.testing.expectEqual(std.meta.tags(SyncStage).len, threaded_stages.count());
}

test "a sync's adds take free rows newest first, then new rows, in pending order, and its releases follow, for any partition" {
    var partitions = SyncPartitions{};
    try partitions.init();
    defer partitions.deinit();
    var creates: [6]StructuralCommand = undefined;
    for (&creates, 0..) |*command, at| command.* = .{ .create_entity = staticTemplate(.{ .x = @floatFromInt(at * 200 + 4), .y = 40 }, .{ .x = 8, .y = 8 }) };
    try partitions.commit(&creates);
    // In pending order, so static k took fresh row k.
    var statics: [6]EntityId = undefined;
    for (partitions.fixtures[0].colliders.changesThisStep(), &statics) |change, *entity| entity.* = change.entity;
    for (&partitions.fixtures) |*fixture| {
        for (statics, 0..) |entity, row| try std.testing.expectEqual(@as(u32, @intCast(row)), fixture.colliders.row_of_index.items[entity.index]);
    }
    // Releases append in pending order.
    try partitions.commit(&.{ .{ .destroy_entity = statics[1] }, .{ .destroy_entity = statics[4] } });
    for (&partitions.fixtures) |*fixture| {
        const changes = fixture.colliders.changesThisStep();
        try std.testing.expectEqual(@as(usize, 2), changes.len);
        var released: [2]u32 = undefined;
        for (changes, &released) |change, *row| row.* = staticRank(&statics, change.entity);
        try std.testing.expectEqualSlices(u32, &released, fixture.colliders.row_free.items);
    }
    // Two bodies that are no statics take the freed entity slots, so the adds below take new
    // entity indices.
    try partitions.commit(&.{ .{ .create_entity = .{ .movement_body = .{ .position = .{ .x = 5, .y = 5 } } } }, .{ .create_entity = .{ .movement_body = .{ .position = .{ .x = 9, .y = 5 } } } } });
    // Three adds and a release in one sync: the adds take the newest free row, then the
    // other, then a new row; the release follows the claims.
    const free_before = [2]u32{ partitions.fixtures[0].colliders.row_free.items[0], partitions.fixtures[0].colliders.row_free.items[1] };
    try partitions.commit(&.{
        .{ .set_collision_response = .{ .entity = statics[0], .response = .{ .mobility = .dynamic } } },
        .{ .create_entity = staticTemplate(.{ .x = 4, .y = 400 }, .{ .x = 8, .y = 8 }) },
        .{ .create_entity = staticTemplate(.{ .x = 204, .y = 400 }, .{ .x = 8, .y = 8 }) },
        .{ .create_entity = staticTemplate(.{ .x = 404, .y = 400 }, .{ .x = 8, .y = 8 }) },
    });
    for (&partitions.fixtures) |*fixture| {
        const colliders = &fixture.colliders;
        var adds: usize = 0;
        for (colliders.changesThisStep()) |change| {
            if (change.new == null) {
                try std.testing.expectEqual(no_row, colliders.row_of_index.items[change.entity.index]);
                continue;
            }
            try std.testing.expect(change.old == null);
            const expected: u32 = if (adds < free_before.len) free_before[free_before.len - 1 - adds] else @intCast(creates.len + adds - free_before.len);
            try std.testing.expectEqual(expected, colliders.row_of_index.items[change.entity.index]);
            adds += 1;
        }
        try std.testing.expectEqual(@as(usize, 3), adds);
        try std.testing.expectEqualSlices(u32, &.{0}, colliders.row_free.items);
        try std.testing.expectEqual(creates.len + 1, colliders.rows.len);
        var rebuilt = try fixture.rebuilt();
        defer rebuilt.deinit();
        try expectSameRows(colliders, &rebuilt, 1);
    }
}

// The rank of `entity` among `statics`.
fn staticRank(statics: []const EntityId, entity: EntityId) u32 {
    for (statics, 0..) |candidate, rank| {
        if (candidate.eql(entity)) return @intCast(rank);
    }
    unreachable;
}

test "a sync opens the directories of only the levels and coarse classes its fresh blocks enter" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try std.testing.expect(!fixture.colliders.payload_growth_logged);
    const coarse_size = test_geometry.cell_size * 4 * @as(f32, @floatFromInt(test_geometry.grid.chunk_tiles));
    var commands: [12]StructuralCommand = undefined;
    // Ten fine statics on level 0 and one on level 3, and one coarse static on level 3.
    for (commands[0..10], 0..) |*command, at| command.* = .{ .create_entity = staticTemplateOn(.{ .x = @floatFromInt(at * 150 + 4), .y = 40 }, .{ .x = 8, .y = 8 }, 0) };
    commands[10] = .{ .create_entity = staticTemplateOn(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }, 3) };
    commands[11] = .{ .create_entity = staticTemplateOn(.{ .x = 40, .y = 600 }, .{ .x = coarse_size, .y = 8 }, 3) };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &commands);
    const colliders = &fixture.colliders;
    try std.testing.expect(colliders.payload_growth_logged);
    const chunk_count = test_geometry.grid.chunkCount();
    try std.testing.expectEqual(@as(usize, 4), colliders.chunks.levelCount());
    for ([_]usize{ chunk_count, 0, 0, chunk_count }, 0..) |slots, level| try std.testing.expectEqual(slots, colliders.chunks.slotCount(@intCast(level)));
    var fine_on_three: ?EntityId = null;
    var coarse_class: ?u6 = null;
    for (colliders.changesThisStep()) |change| {
        const placement = change.new.?;
        if (placement.level != 3) continue;
        const row = colliders.row_of_index.items[change.entity.index];
        const class = colliders.queryPlacement(placement, colliders.rowAabb(row)).class;
        if (class > test_geometry.grid.shift) coarse_class = class else fine_on_three = change.entity;
    }
    const opened_class = coarse_class.?;
    for (&colliders.coarse, 0..) |*dir, class| {
        for (0..4) |level| try std.testing.expectEqual(class == opened_class and level == 3, dir.slotCount(@intCast(level)) != 0);
    }
    // A move to level 2 opens its chunk directory, and nothing else.
    try commitForTest(&fixture.frame, &fixture.data, colliders, &.{.{ .set_world_level = .{ .entity = fine_on_three.?, .level = 2 } }});
    for ([_]usize{ chunk_count, 0, chunk_count, chunk_count }, 0..) |slots, level| try std.testing.expectEqual(slots, colliders.chunks.slotCount(@intCast(level)));
    for (&colliders.coarse, 0..) |*dir, class| {
        for (0..4) |level| try std.testing.expectEqual(class == opened_class and level == 3, dir.slotCount(@intCast(level)) != 0);
    }
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(colliders, &rebuilt, 4);
}

test "a payload whose records pass a u32 column's last power of two fails as OutOfMemory, chunk and coarse" {
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    for ([_]u32{ std.math.maxInt(u32), (1 << 31) + 1 }) |inserts| {
        var window: [2]ResourceEntry = undefined;
        var entries = BandEntries{ .window = &window, .base = 0 };
        const chunk_item = ChunkItem{ .level = 0, .slot = 0, .nav_insert_count = inserts };
        try std.testing.expectError(error.OutOfMemory, colliders.planChunkPayload(&chunk_item, &entries));
        entries = .{ .window = &window, .base = 0 };
        const query_item = ChunkItem{ .level = 0, .slot = 0, .nav_insert_count = 1, .query_insert_count = inserts };
        try std.testing.expectError(error.OutOfMemory, colliders.planChunkPayload(&query_item, &entries));
        entries = .{ .window = &window, .base = 0 };
        const coarse_item = CoarseItem{ .class = 6, .level = 0, .slot = 0, .insert_count = inserts };
        try std.testing.expectError(error.OutOfMemory, colliders.planCoarsePayload(&coarse_item, &entries));
    }
}

test "a group band flagged overflow fails reservePayloads before it opens a level, reserves a slab, or merges a claim" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    const colliders = &fixture.colliders;
    // Chunk band 0 claims a class-0 slot and a block on level 2, which no static entered;
    // chunk band 1 overflowed.
    colliders.touch_start = @splat(@splat(1));
    colliders.touch_start[chunk_tier][0] = 0;
    colliders.entry_start = @splat(@splat(1));
    colliders.entry_start[chunk_tier][0] = 0;
    try std.testing.expect(colliders.resource_entries.capacity >= 1 and colliders.level_entries.capacity >= 1);
    colliders.resource_entries.items.len = 1;
    colliders.resource_entries.items[0] = .{ .resource = 0, .claims = 1 };
    colliders.level_entries.items.len = 1;
    colliders.level_entries.items[0] = 2;
    setSlotCount(GroupTally, &colliders.group_tallies, tier_count * band_count);
    colliders.group_tallies.items[chunk_tier * band_count].value = .{ .items = 1, .units = 1, .entries = 1, .levels = 1 };
    colliders.group_tallies.items[chunk_tier * band_count + 1].value = .{ .overflow = true };
    colliders.claim_tally = .{ .chunk_blocks = .{ .claims = 7 } };
    colliders.item_bands.item_start[chunk_tier][1] = 5;
    const level_count = colliders.chunks.levelCount();
    const slab_count = colliders.payloads.slab_count;
    var class_slabs: [max_payload_classes]usize = undefined;
    for (&class_slabs, &colliders.payloads.classes) |*count, *held| count.* = held.slabs.items.len;

    try std.testing.expectError(error.OutOfMemory, colliders.reservePayloads());
    try std.testing.expectEqual(level_count, colliders.chunks.levelCount());
    try std.testing.expectEqual(@as(usize, 0), colliders.chunks.slotCount(2));
    try std.testing.expectEqual(slab_count, colliders.payloads.slab_count);
    for (class_slabs, &colliders.payloads.classes) |count, *held| try std.testing.expectEqual(count, held.slabs.items.len);
    try std.testing.expectEqual(@as(u32, 7), colliders.claim_tally.chunk_blocks.claims);
    try std.testing.expectEqual(@as(u32, 5), colliders.item_bands.item_start[chunk_tier][1]);
    try std.testing.expectEqual(@as(u32, 0), colliders.resource_entries.items[0].claim_base);
}

// A sync of the pending changes with each tier's touches placed under `splitters`, as `sync`
// runs it with its sampled splitters.
fn syncUnderSplitters(colliders: *StaticColliderSystem, data: *const DataSystem, thread_system: *ThreadSystem, splitters: TouchSplitters) !void {
    try std.testing.expect(colliders.pending_dirty.items.len != 0);
    const threads = syncThreadsFor(colliders, thread_system);
    const touches = try colliders.planSync(data, threads);
    try colliders.groupPending(threads, touches, .{ splitters, splitters });
    colliders.finishSync(threads);
}

test "sync touch grouping under any band splitters gives the same rows as the sampled splitters and a rebuild, removals and emptied chunks included" {
    var prng = std.Random.DefaultPrng.init(0x5b12);
    const random = prng.random();
    var random_splitters: TouchSplitters = undefined;
    for (&random_splitters) |*splitter| splitter.* = random.uintLessThan(u64, chunkKey(3, 0));
    std.sort.pdq(u64, &random_splitters, {}, std.sort.asc(u64));
    const splitter_sets = [_]TouchSplitters{
        // Every touch in band 0: every removal, release, and emptied chunk of a resource in
        // one entry.
        @splat(ChunkTouchSort.max_key),
        // Every touch in the last band.
        @splat(0),
        random_splitters,
        // Every splitter on one level's first chunk: bands 0 and 63 only.
        @splat(chunkKey(1, 0)),
    };
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    const modes = [_]*ThreadSystem{ &serial_threads, &threads };
    var reference = try SeamFixture.init();
    defer reference.deinit();
    // One fixture per splitter set and thread mode.
    var skewed: [splitter_sets.len * modes.len]SeamFixture = undefined;
    var ready: usize = 0;
    defer for (skewed[0..ready]) |*fixture| fixture.deinit();
    for (&skewed) |*fixture| {
        fixture.* = try SeamFixture.init();
        ready += 1;
        fixture.colliders.splice_controls = .{ .adaptive = false, .items_per_range = 8 };
    }
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    try appendRandomLeveledStatics(random, 150, 3, &commands);
    var live: std.ArrayList(EntityId) = .empty;
    defer live.deinit(std.testing.allocator);
    for (0..6) |round| {
        if (round != 0) {
            live.clearRetainingCapacity();
            for (reference.data.movementBodySliceConst().entities) |entity| try live.append(std.testing.allocator, entity);
            try denseMixedCommands(random, &reference.data, live.items, &commands);
        }
        try commitForTest(&reference.frame, &reference.data, &reference.colliders, commands.items);
        for (&skewed, 0..) |*fixture, at| {
            try commitAndCapture(&fixture.frame, &fixture.data, &fixture.colliders, commands.items);
            try syncUnderSplitters(&fixture.colliders, &fixture.data, modes[at % modes.len], splitter_sets[at / modes.len]);
            try expectSameRows(&fixture.colliders, &reference.colliders, 3);
            try expectSameQueries(&fixture.colliders, &reference.colliders, 3);
            try expectSameRowColumns(&fixture.colliders, &reference.colliders);
            try std.testing.expectEqualSlices(u32, reference.colliders.row_free.items, fixture.colliders.row_free.items);
            try expectAnchors(&fixture.colliders);
        }
        var rebuilt = try reference.rebuilt();
        defer rebuilt.deinit();
        try expectSameRows(&reference.colliders, &rebuilt, 3);
        try expectSameQueries(&reference.colliders, &rebuilt, 3);
    }
}
