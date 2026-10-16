// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! The shared neighbor index: one per pipeline, built each step from a handed population
//! and read by every neighbor query that step. Slot k of the population is its row; a slot
//! whose entity has no movement body holds no entry. Entries are sorted by
//! (cell_y, cell_x, slot), so each populated cell's entries are contiguous, and carry the
//! slot's previous position, entity, faction, and level in entry order.
//!
//! A query scans the cells within its radius cell_y outer, cell_x inner, and visits each
//! cell's entries in slot order; consumers that sum floats depend on that order. A band's
//! cells in one cell row's aligned 64-cell span form a row segment with an occupancy mask,
//! found by (cell_y, span) through a band directory and a per-band hash table: a query
//! probes once per row piece, empty cells cost nothing, and no storage follows the
//! populated extent.
//!
//! Serial build (also when no stage can get a worker): one fill and one sort in a single
//! band. Threaded, the main thread samples the band splitters, `index_bucket` resolves each
//! range's slots and places their keys by band in its window, and `index_sort` sorts each
//! band in its own slice and writes its cells, table, and entries; each stage runs inline or
//! on workers as its own tuner selects. A cell lies in one band and the bands follow key
//! order, so the entries, and every cell's entries, are identical for any splitters and
//! partition.
//!
//! Collision broadphase keeps its own sweep-and-prune order and does not use this index.

const std = @import("std");
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const Dispatch = @import("../../app/thread_system.zig").Dispatch;
const PaddedSlot = @import("../../app/thread_system.zig").PaddedSlot;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const SlotList = @import("../../app/thread_system.zig").SlotList;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const inlineBatch = @import("../../app/thread_system.zig").inlineBatch;
const maxRangeCount = @import("../../app/thread_system.zig").maxRangeCount;
const setRowCount = @import("../../app/thread_system.zig").setRowCount;
const setSlotCount = @import("../../app/thread_system.zig").setSlotCount;
const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;
const ConstMovementBodySlice = @import("../data_system.zig").ConstMovementBodySlice;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const Faction = @import("../data_system.zig").Faction;
const movement_range_alignment_items = @import("../data_system.zig").movement_range_alignment_items;

pub const spatial_index_range_alignment_items: usize = movement_range_alignment_items;

// Partition width of the threaded build, not a capacity: the index is the same for any
// band count and splitters, and a range's band histogram stays on the worker stack.
const band_count: usize = 64;
// Population slots sampled per step for the band splitters: four per band, a fixed count.
// Balance only.
const splitter_sample_count: usize = 4 * band_count;
// The golden ratio's fractional part in 0.64 fixed point.
const sample_fraction_step: u64 = 0x9E3779B97F4A7C15;

/// The rows one build indexes: slot k is `entities[rows[k]]`, or `entities[k]` without
/// `rows`. Read during the build only.
pub const IndexPopulation = struct {
    entities: []const EntityId,
    rows: ?[]const u32 = null,

    fn len(self: IndexPopulation) usize {
        return if (self.rows) |rows| rows.len else self.entities.len;
    }

    fn entity(self: IndexPopulation, slot: usize) EntityId {
        return self.entities[if (self.rows) |rows| rows[slot] else slot];
    }
};

pub const SpatialIndexConfig = struct {
    /// World-unit side of one cell, finite and positive; a query's scan radius in cells
    /// derives from it.
    cell_size: f32 = 32.0,
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
};

const StageThreads = @import("../../app/thread_system.zig").StageThreads(SpatialIndexConfig);

pub const NeighborVisitResult = enum { keep_going, stop };

pub const NeighborQueryStats = struct {
    candidate_checks: u16 = 0,
};

/// One neighbor query: the entries strictly within `radius` of `(x, y)`, visited in scan
/// order (see the module doc). Every scanned entry but `self` counts as a candidate check
/// before its radius test; the scan stops before the check that would pass
/// `max_candidate_checks`.
pub const NeighborQuery = struct {
    x: f32,
    y: f32,
    /// Finite and at least 0.
    radius: f32,
    max_candidate_checks: u16,
    /// Skipped without counting as a candidate.
    self: EntityId = EntityId.invalid,
};

pub const SpatialIndexStats = struct {
    /// Entries built: the population's slots with a movement body.
    entity_count: usize = 0,
    bucket_batch: BatchStats = .{},
    sort_batch: BatchStats = .{},
};

// The populated cells of one build's bands, found by key.
const BandDirectory = struct {
    splitters: [band_count - 1]CellKey = @splat(max_cell_key),
    // 0 for the serial build's one band, else `band_count - 1`.
    splitter_count: usize = 0,
    bands: [band_count]BandExtent = @splat(.{}),

    // A cell's band is the count of splitters at or below it; the splitters are
    // nondecreasing, so the bands follow key order and every cell lies in exactly one.
    fn bandOfCell(self: *const BandDirectory, cell: CellKey) usize {
        return std.sort.partitionPoint(CellKey, self.splitters[0..self.splitter_count], cell, splitterAtOrBelow);
    }

    // One predicate call per probe, as `agent_grid`'s directory measured faster than
    // `std.sort.upperBound`'s order wrapper.
    fn splitterAtOrBelow(cell: CellKey, splitter: CellKey) bool {
        return cellKeyOrder(cell, splitter) != .lt;
    }
};

// Band b's entries, cells, and segments start at `start` in their lists; its table is
// `segment_table[2 * start, 2 * (start + entry_count))`, at most half full.
const BandExtent = struct {
    start: u32 = 0,
    entry_count: u32 = 0,
    cell_count: u32 = 0,
    segment_count: u32 = 0,
};

/// One step's built index, read-only. Valid until the next build or reserve of its system.
pub const SpatialIndexView = struct {
    /// Entry-order columns: a visit's entry index reads them.
    x: []const f32,
    y: []const f32,
    entity: []const EntityId,
    faction: []const Faction,
    level: []const u16,
    cells: []const SpatialCell,
    segments: []const RowSegment,
    segment_table: []const u32,
    directory: *const BandDirectory,
    cell_size: f32,

    /// Visits `query`'s neighbors in scan order through `visitor`, a pointer to a value
    /// with `visit(entry: u32, dx: f32, dy: f32, dist2: f32) NeighborVisitResult`, where
    /// `dx, dy` is the query point minus the entry's position. `.stop` ends the whole
    /// query. Scans the `2r + 1` cell rows of its box, r = ceil(radius / cell_size), with one
    /// probe per row piece: a row's run within one 64-cell span and one band.
    pub fn queryNeighbors(self: SpatialIndexView, query: NeighborQuery, visitor: anytype) NeighborQueryStats {
        std.debug.assert(std.math.isFinite(query.radius) and query.radius >= 0);
        var stats = NeighborQueryStats{};
        if (self.entity.len == 0) return stats;
        const scan = cellScanRadius(query.radius, self.cell_size);
        const own = cellForPosition(query.x, query.y, self.cell_size);
        const lanes = QueryLanes.init(query);
        // Cell keys are i32: widen the box, then clamp it to the key range.
        const key_min: i64 = std.math.minInt(i32);
        const key_max: i64 = std.math.maxInt(i32);
        // Clamped to the i32 range.
        const min_x: i32 = @intCast(std.math.clamp(@as(i64, own.cell_x) - scan, key_min, key_max));
        const max_x: i32 = @intCast(std.math.clamp(@as(i64, own.cell_x) + scan, key_min, key_max));
        const min_y: i32 = @intCast(std.math.clamp(@as(i64, own.cell_y) - scan, key_min, key_max));
        const max_y: i32 = @intCast(std.math.clamp(@as(i64, own.cell_y) + scan, key_min, key_max));
        // Keys ascend through the box's rows and pieces, so the band only advances: one
        // search, then at most `band_count - 1` steps per query.
        var band = self.directory.bandOfCell(.{ .cell_y = min_y, .cell_x = min_x });
        var cell_y: i64 = min_y;
        while (cell_y <= max_y) : (cell_y += 1) {
            // In [min_y, max_y], both i32.
            const row_y: i32 = @intCast(cell_y);
            var piece_lo: i64 = min_x;
            while (piece_lo <= max_x) {
                // piece_lo is in [min_x, max_x], both i32.
                const key = CellKey{ .cell_y = row_y, .cell_x = @intCast(piece_lo) };
                // A row crosses the splitters in order as cell_x grows.
                while (band < self.directory.splitter_count and cellKeyOrder(key, self.directory.splitters[band]) != .lt) band += 1;
                // The piece ends at the box, its segment's last cell, or before the band's
                // next splitter in this row; the splitter is above `key`, so past piece_lo.
                // In i64: the last span's end is exactly `maxInt(i32)`.
                var piece_hi: i64 = @min(max_x, segment_cells * @divFloor(piece_lo, segment_cells) + segment_cells - 1);
                if (band < self.directory.splitter_count) {
                    const splitter = self.directory.splitters[band];
                    if (splitter.cell_y == row_y and splitter.cell_x <= piece_hi) piece_hi = @as(i64, splitter.cell_x) - 1;
                }
                // Both in [min_x, max_x], i32.
                const cells = self.pieceCells(band, row_y, @intCast(piece_lo), @intCast(piece_hi));
                piece_lo = piece_hi + 1;
                if (cells.len == 0) continue;
                // The piece's cells are adjacent, so their entries are one run.
                if (self.visitEntries(query, lanes, cells[0].start, cells[cells.len - 1].end, visitor, &stats)) return stats;
            }
        }
        return stats;
    }

    // Band `band`'s cells in row `cell_y` from `lo_x` to `hi_x`, a span inside one segment,
    // in cell_x order. Scalar: a dependent, scattered probe chain and a bit rank.
    fn pieceCells(self: SpatialIndexView, band: usize, cell_y: i32, lo_x: i32, hi_x: i32) []const SpatialCell {
        std.debug.assert(lo_x <= hi_x and @divFloor(lo_x, segment_cells) == @divFloor(hi_x, segment_cells));
        const segment = self.findSegment(band, cell_y, @divFloor(lo_x, segment_cells)) orelse return &.{};
        // `@mod` by 64 is in [0, 63].
        const lo_bit: u6 = @intCast(@mod(lo_x, segment_cells));
        const hi_bit: u6 = @intCast(@mod(hi_x, segment_cells));
        // The bits below lo_bit, and the bits lo_bit..hi_bit, as plain shifts: once per piece,
        // where `setRangeValue`'s general range checks do not pay.
        const below = (@as(u64, 1) << lo_bit) - 1;
        const through_hi = ~@as(u64, 0) >> (63 - hi_bit);
        const rank = @popCount(segment.occupied.mask & below);
        const count = @popCount(segment.occupied.mask & through_hi & ~below);
        return self.cells[segment.first_cell + rank ..][0..count];
    }

    // Scalar: a probe is a short chain of scattered, data-dependent loads.
    fn findSegment(self: SpatialIndexView, band: usize, cell_y: i32, segment_x: i32) ?RowSegment {
        const extent = self.directory.bands[band];
        if (extent.segment_count == 0) return null;
        const table_len = 2 * @as(usize, extent.entry_count);
        const table = self.segment_table[2 * @as(usize, extent.start) ..][0..table_len];
        var slot = tableSlot(cell_y, segment_x, table_len);
        while (true) {
            const stored = table[slot];
            if (stored == 0) return null;
            const segment = self.segments[stored - 1];
            if (segment.cell_y == cell_y and segment.segment_x == segment_x) return segment;
            slot += 1;
            if (slot == table_len) slot = 0;
        }
    }

    // The distance test runs in lanes over the contiguous entry columns, with the scalar
    // tail; lanes are then taken in entry order for the self skip, the check, and the visit.
    // Returns true when the query ends.
    fn visitEntries(self: SpatialIndexView, query: NeighborQuery, lanes: QueryLanes, start: u32, end: u32, visitor: anytype, stats: *NeighborQueryStats) bool {
        var entry: usize = start;
        const vector_end = start + simd.vectorizedEnd(end - start);
        while (entry < vector_end) : (entry += simd.lane_count) {
            const dx = simd.subFloat4(lanes.x, simd.loadFloat4(self.x[entry..]));
            const dy = simd.subFloat4(lanes.y, simd.loadFloat4(self.y[entry..]));
            const dist2 = simd.lengthSquared2Float4(dx, dy);
            const inside = simd.lessThanFloat4(dist2, lanes.radius2);
            inline for (0..simd.lane_count) |lane| {
                if (self.visitEntry(query, entry + lane, inside[lane], dx[lane], dy[lane], dist2[lane], visitor, stats)) return true;
            }
        }
        return self.visitEntriesScalar(query, lanes.radius2[0], entry, end, visitor, stats);
    }

    // `visitEntries` one entry at a time: its tail, and its parity reference.
    fn visitEntriesScalar(self: SpatialIndexView, query: NeighborQuery, radius2: f32, start: usize, end: usize, visitor: anytype, stats: *NeighborQueryStats) bool {
        for (start..end) |entry| {
            const dx = query.x - self.x[entry];
            const dy = query.y - self.y[entry];
            const dist2 = dx * dx + dy * dy;
            if (self.visitEntry(query, entry, dist2 < radius2, dx, dy, dist2, visitor, stats)) return true;
        }
        return false;
    }

    fn visitEntry(self: SpatialIndexView, query: NeighborQuery, entry: usize, inside: bool, dx: f32, dy: f32, dist2: f32, visitor: anytype, stats: *NeighborQueryStats) bool {
        // The index compare rejects every other entry with one u32 compare.
        const candidate = self.entity[entry];
        if (candidate.index == query.self.index and candidate.eql(query.self)) return false;
        if (stats.candidate_checks >= query.max_candidate_checks) return true;
        stats.candidate_checks += 1;
        if (!inside) return false;
        // Entries are below the slot count, at most maxInt(u32) (`SpatialIndexSystem.beginBuild`).
        return visitor.visit(@as(u32, @intCast(entry)), dx, dy, dist2) == .stop;
    }
};

// A query's point and squared radius in every lane, splatted once per query.
const QueryLanes = struct {
    x: simd.Float4,
    y: simd.Float4,
    radius2: simd.Float4,

    fn init(query: NeighborQuery) QueryLanes {
        return .{ .x = simd.splatFloat4(query.x), .y = simd.splatFloat4(query.y), .radius2 = simd.splatFloat4(query.radius * query.radius) };
    }
};

// Cells per row segment: one occupancy bit each.
const segment_cells = 64;
const SegmentMask = std.bit_set.Integer(segment_cells);

// One band's populated cells in row `cell_y` within cells
// `[segment_cells * segment_x, segment_cells * segment_x + segment_cells - 1]`: bit
// `cell_x mod segment_cells` per cell, which are `cells[first_cell..]` in cell_x order,
// one per set bit.
const RowSegment = struct {
    cell_y: i32,
    segment_x: i32,
    first_cell: u32,
    occupied: SegmentMask,
};

// A populated cell and its entries `[start, end)`.
const SpatialCell = struct {
    cell_y: i32,
    cell_x: i32,
    start: u32,
    end: u32,
};

// A spatial cell, ordered by (cell_y, cell_x).
const CellKey = struct {
    cell_y: i32,
    cell_x: i32,
};

// The largest cell key; splitters at it leave the bands after them empty.
const max_cell_key = CellKey{ .cell_y = std.math.maxInt(i32), .cell_x = std.math.maxInt(i32) };

// `cell` against `key` in (cell_y, cell_x) order. Plain comparisons: per-field
// `std.math.order` calls measure slower on a per-query lookup (`agent_grid`).
fn cellKeyOrder(cell: CellKey, key: CellKey) std.math.Order {
    if (cell.cell_y != key.cell_y) return if (cell.cell_y < key.cell_y) .lt else .gt;
    if (cell.cell_x != key.cell_x) return if (cell.cell_x < key.cell_x) .lt else .gt;
    return .eq;
}

fn cellKeyLessThan(_: void, lhs: CellKey, rhs: CellKey) bool {
    return cellKeyOrder(lhs, rhs) == .lt;
}

// A segment's slot in a band's table of `table_len` slots: a 64-bit integer hash of
// (cell_y, segment_x), scaled to the table without a division.
fn tableSlot(cell_y: i32, segment_x: i32, table_len: usize) usize {
    const packed_key = (@as(u64, @as(u32, @bitCast(cell_y))) << 32) | @as(u32, @bitCast(segment_x));
    // The high word of hash * table_len is below table_len.
    return @intCast(std.math.mulWide(u64, std.hash.int(packed_key), table_len) >> 64);
}

// An entry's sort key: total over a build, since slots are distinct.
const SortKey = struct {
    cell_y: i32,
    cell_x: i32,
    slot: u32,

    fn cell(self: SortKey) CellKey {
        return .{ .cell_y = self.cell_y, .cell_x = self.cell_x };
    }
};

fn sortKeyLessThan(_: void, lhs: SortKey, rhs: SortKey) bool {
    if (lhs.cell_y != rhs.cell_y) return lhs.cell_y < rhs.cell_y;
    if (lhs.cell_x != rhs.cell_x) return lhs.cell_x < rhs.cell_x;
    return lhs.slot < rhs.slot;
}

// One population slot as resolved this build; `entity` is invalid for a slot with no
// movement body.
const SlotRow = struct {
    entity: EntityId,
    x: f32,
    y: f32,
    level: u16,
    faction: Faction,
};

const EntryRow = struct {
    x: f32,
    y: f32,
    entity: EntityId,
    faction: Faction,
    level: u16,
};

// With a 16-slot range alignment every bucket range's windows start on a cache line.
const SlotRowList = std.array_list.Aligned(SlotRow, .fromByteUnits(thread_shared_record_alignment));
const SortKeyList = std.array_list.Aligned(SortKey, .fromByteUnits(thread_shared_record_alignment));

comptime {
    std.debug.assert(spatial_index_range_alignment_items * @sizeOf(SlotRow) % thread_shared_record_alignment == 0);
    std.debug.assert(spatial_index_range_alignment_items * @sizeOf(SortKey) % thread_shared_record_alignment == 0);
}

// A bucket range's keys before each band: band b's are `[offsets[b], offsets[b + 1])` of its
// staging window.
const BandOffsets = struct {
    offsets: [band_count + 1]u32 = @splat(0),
};

const BandTally = struct {
    cell_count: u32 = 0,
    segment_count: u32 = 0,
};

comptime {
    for ([_]type{ BandOffsets, BandTally }) |T| std.debug.assert(@sizeOf(PaddedSlot(T)) % thread_shared_record_alignment == 0);
}

// The two stages of a threaded build, each under its own tuner.
const BuildStages = struct {
    bucket: Dispatch,
    sort: Dispatch,
};

pub const SpatialIndexSystem = struct {
    allocator: std.mem.Allocator,
    // By population slot.
    slot_rows: SlotRowList = .empty,
    // Sorted entry keys; a threaded build first fills each bucket range's window of it.
    keys: SortKeyList = .empty,
    // A threaded build's band-ordered bucket windows.
    staging: SortKeyList = .empty,
    entries: std.MultiArrayList(EntryRow) = .{},
    // Band b's cells sit in its own slice from its entry start; the rest of the slice is
    // unused.
    cells: std.ArrayList(SpatialCell) = .empty,
    // Band b's row segments, laid out like its cells.
    segments: std.ArrayList(RowSegment) = .empty,
    // Per band, linear-probe slots holding 0 or a segment index + 1. Hand-rolled: a std
    // hash map owns its storage, and each band's table is written by its sort range inside
    // one seam-reserved buffer.
    segment_table: std.ArrayList(u32) = .empty,
    directory: BandDirectory = .{},
    band_offsets: SlotList(BandOffsets) = .empty,
    band_tallies: SlotList(BandTally) = .empty,
    bucket_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    sort_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    cell_size: f32 = (SpatialIndexConfig{}).cell_size,

    pub fn init(allocator: std.mem.Allocator) SpatialIndexSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SpatialIndexSystem) void {
        self.band_tallies.deinit(self.allocator);
        self.band_offsets.deinit(self.allocator);
        self.segment_table.deinit(self.allocator);
        self.segments.deinit(self.allocator);
        self.cells.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.staging.deinit(self.allocator);
        self.keys.deinit(self.allocator);
        self.slot_rows.deinit(self.allocator);
        self.* = undefined;
    }

    /// Sizes every build buffer for a population of `capacity` slots under any partition
    /// the tuners can pick, so a build at or below it allocates nothing. Grow-only; the
    /// pipeline calls it at init and at its population seam.
    pub fn reserve(self: *SpatialIndexSystem, capacity: usize) error{OutOfMemory}!void {
        // The u32 widths are exhausted only past maxInt(u32) slots, which the population
        // cannot reach (`beginBuild`); past it this is allocator exhaustion.
        if (capacity > std.math.maxInt(u32)) return error.OutOfMemory;
        try self.slot_rows.ensureTotalCapacity(self.allocator, capacity);
        try self.keys.ensureTotalCapacity(self.allocator, capacity);
        try self.staging.ensureTotalCapacity(self.allocator, capacity);
        try self.entries.ensureTotalCapacity(self.allocator, capacity);
        try self.cells.ensureTotalCapacity(self.allocator, capacity);
        try self.segments.ensureTotalCapacity(self.allocator, capacity);
        try self.segment_table.ensureTotalCapacity(self.allocator, 2 * capacity);
        try self.band_offsets.ensureTotalCapacity(self.allocator, maxRangeCount(capacity, spatial_index_range_alignment_items));
        try self.band_tallies.ensureTotalCapacity(self.allocator, band_count);
    }

    /// The last build's index.
    pub fn view(self: *const SpatialIndexSystem) SpatialIndexView {
        const entries = self.entries.slice();
        return .{
            .x = entries.items(.x),
            .y = entries.items(.y),
            .entity = entries.items(.entity),
            .faction = entries.items(.faction),
            .level = entries.items(.level),
            .cells = self.cells.items,
            .segments = self.segments.items,
            .segment_table = self.segment_table.items,
            .directory = &self.directory,
            .cell_size = self.cell_size,
        };
    }

    /// Builds the index of `population`'s slots from their previous positions. Both stages
    /// run on workers under the index's tuners, or inline as they select; with no worker
    /// available it builds serially. Allocates only past `reserve`'s capacity, on the
    /// calling thread before any dispatch.
    pub fn build(
        self: *SpatialIndexSystem,
        data: *const DataSystem,
        population: IndexPopulation,
        thread_system: *ThreadSystem,
        config: SpatialIndexConfig,
    ) !SpatialIndexStats {
        const slot_count = try self.beginBuild(population, config);
        if (slot_count == 0) return .{};
        const threads = StageThreads.withWorkers(.{ .thread_system = thread_system, .config = config }) orelse return self.buildDirect(data, population);
        const stages = BuildStages{ .bucket = threads.stage(&self.bucket_tuner), .sort = threads.stage(&self.sort_tuner) };
        return self.buildBanded(data, population, stages, chooseSplitters(data, population, self.cell_size));
    }

    /// `build` on the calling thread alone.
    pub fn buildSerial(self: *SpatialIndexSystem, data: *const DataSystem, population: IndexPopulation, config: SpatialIndexConfig) !SpatialIndexStats {
        const slot_count = try self.beginBuild(population, config);
        if (slot_count == 0) return .{};
        return self.buildDirect(data, population);
    }

    // Clears the last build, so an empty one leaves no cells, and sizes every buffer for
    // `population`. Returns its slot count.
    fn beginBuild(self: *SpatialIndexSystem, population: IndexPopulation, config: SpatialIndexConfig) !usize {
        std.debug.assert(std.math.isFinite(config.cell_size) and config.cell_size > 0);
        self.directory = .{};
        self.cell_size = config.cell_size;
        self.entries.clearRetainingCapacity();
        self.cells.clearRetainingCapacity();
        self.segments.clearRetainingCapacity();
        self.segment_table.clearRetainingCapacity();
        const slot_count = population.len();
        // Slots, entries, cells, and segments are u32. The pipeline's population is its
        // halo, at most the AI rows, at most the entity slots, which `createEntity` refuses
        // past maxInt(u32).
        std.debug.assert(slot_count <= std.math.maxInt(u32));
        try self.reserve(slot_count);
        std.debug.assert(self.slot_rows.capacity >= slot_count and self.keys.capacity >= slot_count and self.staging.capacity >= slot_count);
        self.slot_rows.items.len = slot_count;
        self.keys.items.len = slot_count;
        return slot_count;
    }

    // The serial build: one fill straight into the keys and one band.
    fn buildDirect(self: *SpatialIndexSystem, data: *const DataSystem, population: IndexPopulation) SpatialIndexStats {
        const slot_count = population.len();
        const fill = self.fillContext(data, population);
        // At most slot_count <= maxInt(u32) keys.
        const entry_count: u32 = @intCast(fillSlots(&fill, 0, slot_count, self.keys.items));
        self.setEntryCount(entry_count);
        const counts = self.bandWriter().finishBand(0, entry_count);
        self.directory.bands[0] = .{ .start = 0, .entry_count = entry_count, .cell_count = counts.cell_count, .segment_count = counts.segment_count };
        return .{
            .entity_count = entry_count,
            .bucket_batch = inlineBatch(slot_count, spatial_index_range_alignment_items),
            .sort_batch = inlineBatch(entry_count, spatial_index_range_alignment_items),
        };
    }

    // `index_bucket` over the slots into the bands of `splitters` (nondecreasing), the band
    // starts on the main thread, then `index_sort` over the keys and the band directory.
    fn buildBanded(self: *SpatialIndexSystem, data: *const DataSystem, population: IndexPopulation, stages: BuildStages, splitters: [band_count - 1]CellKey) SpatialIndexStats {
        const slot_count = population.len();
        std.debug.assert(slot_count > 0 and self.slot_rows.items.len == slot_count and self.keys.items.len == slot_count);
        for (splitters[0 .. band_count - 2], splitters[1..]) |lower, upper| std.debug.assert(cellKeyOrder(upper, lower) != .lt);
        const bucket_selection = stages.bucket.select(slot_count, spatial_index_range_alignment_items);
        std.debug.assert(self.band_offsets.capacity >= bucket_selection.range_count and self.band_tallies.capacity >= band_count);
        self.staging.items.len = slot_count;
        setSlotCount(BandOffsets, &self.band_offsets, bucket_selection.range_count);
        self.directory = .{ .splitters = splitters, .splitter_count = band_count - 1 };
        var bucket = BucketJob{
            .fill = self.fillContext(data, population),
            .directory = &self.directory,
            .scratch = self.keys.items,
            .staging = self.staging.items,
            .items_per_range = bucket_selection.items_per_range,
            .band_offsets = self.band_offsets.items,
        };
        var stats = SpatialIndexStats{};
        stats.bucket_batch = stages.bucket.run(bucket_selection, slot_count, spatial_index_range_alignment_items, &bucket, bucketJob);

        // Each band's keys start after every range's keys of the earlier bands.
        var band_start: [band_count + 1]u32 = @splat(0);
        for (self.band_offsets.items) |slot| {
            for (&band_start, slot.value.offsets) |*start, range_offset| start.* += range_offset;
        }
        const entry_count = band_start[band_count];
        self.setEntryCount(entry_count);
        setSlotCount(BandTally, &self.band_tallies, band_count);
        stats.entity_count = entry_count;
        if (entry_count != 0) {
            const sort_selection = stages.sort.select(entry_count, spatial_index_range_alignment_items);
            var sort = SortJob{
                .staging = self.staging.items,
                .band_offsets = self.band_offsets.items,
                .bucket_items_per_range = bucket_selection.items_per_range,
                .band_start = band_start,
                .writer = self.bandWriter(),
                .tallies = self.band_tallies.items,
                .range_count = sort_selection.range_count,
            };
            stats.sort_batch = stages.sort.run(sort_selection, entry_count, spatial_index_range_alignment_items, &sort, sortJob);
        }

        for (&self.directory.bands, self.band_tallies.items, band_start[0..band_count], band_start[1..]) |*band, tally, start, end| {
            band.* = .{ .start = start, .entry_count = end - start, .cell_count = tally.value.cell_count, .segment_count = tally.value.segment_count };
        }
        return stats;
    }

    fn fillContext(self: *SpatialIndexSystem, data: *const DataSystem, population: IndexPopulation) FillContext {
        return .{
            .population = population,
            .data = data,
            .movement = data.movementBodySliceConst(),
            .cell_size = self.cell_size,
            .slot_rows = self.slot_rows.items,
        };
    }

    // Sizes the entry, cell, segment, and table lists for `entry_count` entries, within
    // capacity.
    fn setEntryCount(self: *SpatialIndexSystem, entry_count: u32) void {
        std.debug.assert(self.cells.capacity >= entry_count and self.segments.capacity >= entry_count);
        std.debug.assert(self.segment_table.capacity >= 2 * @as(usize, entry_count));
        setRowCount(EntryRow, &self.entries, entry_count);
        self.cells.items.len = entry_count;
        self.segments.items.len = entry_count;
        self.segment_table.items.len = 2 * @as(usize, entry_count);
    }

    fn bandWriter(self: *SpatialIndexSystem) BandWriter {
        const entries = self.entries.slice();
        return .{
            .keys = self.keys.items,
            .slot_rows = self.slot_rows.items,
            .entry_x = entries.items(.x),
            .entry_y = entries.items(.y),
            .entry_entity = entries.items(.entity),
            .entry_faction = entries.items(.faction),
            .entry_level = entries.items(.level),
            .cells = self.cells.items,
            .segments = self.segments.items,
            .segment_table = self.segment_table.items,
        };
    }
};

// ---- Build stages -------------------------------------------------------------

fn cellScanRadius(radius: f32, cell_size: f32) i32 {
    // ceil(r / c) == -floor(-r / c), through the saturating `floorToI32`.
    return -math.floorToI32(-(radius / cell_size));
}

fn cellForPosition(x: f32, y: f32, cell_size: f32) CellKey {
    return .{ .cell_y = math.floorToI32(y / cell_size), .cell_x = math.floorToI32(x / cell_size) };
}

const FillContext = struct {
    population: IndexPopulation,
    data: *const DataSystem,
    movement: ConstMovementBodySlice,
    cell_size: f32,
    // Written at the filled slots only.
    slot_rows: []SlotRow,

    // Scalar: a scattered dense-index lookup per component, with a skip.
    fn resolveSlot(self: *const FillContext, slot: usize) SlotRow {
        const entity = self.population.entity(slot);
        const row: SlotRow = if (self.data.movementBodyDenseIndex(entity)) |body| .{
            .entity = entity,
            .x = self.movement.previous_x[body],
            .y = self.movement.previous_y[body],
            .level = self.data.worldLevelConst(entity) orelse 0,
            .faction = self.data.factionConst(entity) orelse .neutral,
        } else .{ .entity = EntityId.invalid, .x = 0, .y = 0, .level = 0, .faction = .neutral };
        self.slot_rows[slot] = row;
        return row;
    }
};

// Resolves slots `[start, end)` into their rows and writes a key to `keys` for each with a
// movement body, in slot order; returns the key count. Cells in lanes over the packed
// positions with a scalar tail, bit for bit `cellForPosition`.
fn fillSlots(fill: *const FillContext, start: usize, end: usize, keys: []SortKey) usize {
    std.debug.assert(start <= end and end <= fill.slot_rows.len and keys.len >= end - start);
    const cell_size_lanes = simd.splatFloat4(fill.cell_size);
    var count: usize = 0;
    var slot = start;
    const vector_end = start + simd.vectorizedEnd(end - start);
    while (slot < vector_end) : (slot += simd.lane_count) {
        var x: [simd.lane_count]f32 = undefined;
        var y: [simd.lane_count]f32 = undefined;
        var has_body: [simd.lane_count]bool = undefined;
        inline for (0..simd.lane_count) |lane| {
            const row = fill.resolveSlot(slot + lane);
            x[lane] = row.x;
            y[lane] = row.y;
            has_body[lane] = row.entity.isValid();
        }
        const cell_x = simd.toIntArray(simd.floorToI4(simd.divFloat4(simd.loadFloat4(&x), cell_size_lanes)));
        const cell_y = simd.toIntArray(simd.floorToI4(simd.divFloat4(simd.loadFloat4(&y), cell_size_lanes)));
        inline for (0..simd.lane_count) |lane| {
            if (has_body[lane]) {
                // A slot is below slot_count <= maxInt(u32).
                keys[count] = .{ .cell_y = cell_y[lane], .cell_x = cell_x[lane], .slot = @intCast(slot + lane) };
                count += 1;
            }
        }
    }
    while (slot < end) : (slot += 1) {
        const row = fill.resolveSlot(slot);
        if (!row.entity.isValid()) continue;
        const cell = cellForPosition(row.x, row.y, fill.cell_size);
        // A slot is below slot_count <= maxInt(u32).
        keys[count] = .{ .cell_y = cell.cell_y, .cell_x = cell.cell_x, .slot = @intCast(slot) };
        count += 1;
    }
    return count;
}

// `index_bucket`: one range of population slots.
const BucketJob = struct {
    fill: FillContext,
    // Its splitters, written before dispatch.
    directory: *const BandDirectory,
    // Range r's windows start at `r * items_per_range`.
    scratch: []SortKey,
    staging: []SortKey,
    items_per_range: usize,
    band_offsets: []PaddedSlot(BandOffsets),
};

// Fills the range's keys into its scratch window, then places them in its staging window
// by band, in slot order within a band, and records the band offsets. The band search runs
// twice per key rather than storing each band: scalar, a six-step binary search.
fn bucketJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *BucketJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.band_offsets.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end and range.end <= job.fill.population.len());
    std.debug.assert(range.end <= job.scratch.len and range.end <= job.staging.len and range.end <= job.fill.slot_rows.len);
    std.debug.assert(job.directory.splitter_count == band_count - 1);
    const filled = job.scratch[range.start..][0..fillSlots(&job.fill, range.start, range.end, job.scratch[range.start..range.end])];
    var offsets: [band_count + 1]u32 = @splat(0);
    for (filled) |key| offsets[job.directory.bandOfCell(key.cell()) + 1] += 1;
    for (1..band_count + 1) |band| offsets[band] += offsets[band - 1];
    job.band_offsets[range.index].value.offsets = offsets;
    var cursor = offsets;
    for (filled) |key| {
        const band = job.directory.bandOfCell(key.cell());
        job.staging[range.start + cursor[band]] = key;
        cursor[band] += 1;
    }
}

// `index_sort`: one range of entry keys. A range owns every nonempty band that starts in
// it, so each band has one owner and the ranges' work follows their key counts.
const SortJob = struct {
    staging: []const SortKey,
    band_offsets: []const PaddedSlot(BandOffsets),
    bucket_items_per_range: usize,
    // Band b's keys, cells, and entries go to `[band_start[b], band_start[b + 1])`.
    band_start: [band_count + 1]u32,
    writer: BandWriter,
    tallies: []PaddedSlot(BandTally),
    range_count: usize,
};

// Each owned band gathers every bucket range's segment of it in range order into its slice
// of the keys, then finishes there.
fn sortJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *SortJob = @ptrCast(@alignCast(context));
    const entry_count = job.band_start[band_count];
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= entry_count);
    std.debug.assert(entry_count <= job.writer.keys.len and entry_count <= job.writer.cells.len and entry_count <= job.writer.entry_x.len);
    std.debug.assert(entry_count <= job.writer.segments.len and 2 * @as(usize, entry_count) <= job.writer.segment_table.len and job.tallies.len == band_count);
    var band = std.sort.partitionPoint(u32, job.band_start[0..band_count], range.start, startsBefore);
    while (band < band_count and job.band_start[band] < range.end) : (band += 1) {
        const start = job.band_start[band];
        const end = job.band_start[band + 1];
        if (start == end) continue;
        var cursor: usize = start;
        for (job.band_offsets, 0..) |slot, bucket_range| {
            const window = job.staging[bucket_range * job.bucket_items_per_range ..];
            const segment = window[slot.value.offsets[band]..slot.value.offsets[band + 1]];
            @memcpy(job.writer.keys[cursor..][0..segment.len], segment);
            cursor += segment.len;
        }
        std.debug.assert(cursor == end);
        job.tallies[band].value = job.writer.finishBand(start, end);
    }
}

fn startsBefore(range_start: usize, band_start: u32) bool {
    return band_start < range_start;
}

// Writes one band's slice of the sorted keys, cells, table, and entries.
const BandWriter = struct {
    keys: []SortKey,
    slot_rows: []const SlotRow,
    entry_x: []f32,
    entry_y: []f32,
    entry_entity: []EntityId,
    entry_faction: []Faction,
    entry_level: []u16,
    cells: []SpatialCell,
    segments: []RowSegment,
    segment_table: []u32,

    // Sorts the band's keys `[start, end)`, writes one cell per run from `cells[start]` and
    // one row segment per (cell_y, segment_x) run of cells from `segments[start]`, inserts
    // the segments into the band's table, and gathers the entries' payload. pdqsort: the
    // key is total, so an unstable sort is exact. Scalar: a comparison sort, run
    // compaction, probe chains, and record copies.
    fn finishBand(self: BandWriter, start: u32, end: u32) BandTally {
        std.sort.pdq(SortKey, self.keys[start..end], {}, sortKeyLessThan);
        var cell_count: u32 = 0;
        var segment_count: u32 = 0;
        var entry: u32 = start;
        while (entry < end) {
            const cell_start = entry;
            const key = self.keys[entry];
            while (entry < end and self.keys[entry].cell_y == key.cell_y and self.keys[entry].cell_x == key.cell_x) entry += 1;
            const cell_index = start + cell_count;
            self.cells[cell_index] = .{ .cell_y = key.cell_y, .cell_x = key.cell_x, .start = cell_start, .end = entry };
            cell_count += 1;
            const segment_x: i32 = @divFloor(key.cell_x, segment_cells);
            const open = segment_count != 0 and self.segments[start + segment_count - 1].cell_y == key.cell_y and self.segments[start + segment_count - 1].segment_x == segment_x;
            if (!open) {
                self.segments[start + segment_count] = .{ .cell_y = key.cell_y, .segment_x = segment_x, .first_cell = cell_index, .occupied = .empty };
                segment_count += 1;
            }
            // `@mod` by 64 is in [0, 63].
            self.segments[start + segment_count - 1].occupied.set(@intCast(@mod(key.cell_x, segment_cells)));
        }

        const table = self.segment_table[2 * @as(usize, start) .. 2 * @as(usize, end)];
        @memset(table, 0);
        for (start..start + segment_count) |segment_index| {
            const segment = self.segments[segment_index];
            var slot = tableSlot(segment.cell_y, segment.segment_x, table.len);
            while (table[slot] != 0) {
                slot += 1;
                if (slot == table.len) slot = 0;
            }
            // segment_index + 1 <= entry count <= maxInt(u32).
            table[slot] = @intCast(segment_index + 1);
        }

        for (start..end) |index| {
            const row = self.slot_rows[self.keys[index].slot];
            self.entry_x[index] = row.x;
            self.entry_y[index] = row.y;
            self.entry_entity[index] = row.entity;
            self.entry_faction[index] = row.faction;
            self.entry_level[index] = row.level;
        }
        return .{ .cell_count = cell_count, .segment_count = segment_count };
    }
};

// The `band_count - 1` band splitters: the cells at the band quantiles of up to
// `splitter_sample_count` slots (slots without a body skipped), sorted. Every slot when they
// fit the sample, else slots at a golden-ratio sequence of fractions of the slot count,
// which shares no period with a periodic slot order. Fixed work on the main thread; with no
// sampled body every splitter is `max_cell_key`.
fn chooseSplitters(data: *const DataSystem, population: IndexPopulation, cell_size: f32) [band_count - 1]CellKey {
    const slot_count = population.len();
    const sample_count = @min(splitter_sample_count, slot_count);
    const movement = data.movementBodySliceConst();
    var samples: [splitter_sample_count]CellKey = undefined;
    var valid: usize = 0;
    var fraction: u64 = 0;
    for (0..sample_count) |sample| {
        fraction +%= sample_fraction_step;
        // The high word of fraction * slot_count is below slot_count.
        const slot: usize = if (slot_count <= splitter_sample_count) sample else @intCast(std.math.mulWide(u64, fraction, slot_count) >> 64);
        const body = data.movementBodyDenseIndex(population.entity(slot)) orelse continue;
        samples[valid] = cellForPosition(movement.previous_x[body], movement.previous_y[body], cell_size);
        valid += 1;
    }
    var splitters: [band_count - 1]CellKey = @splat(max_cell_key);
    if (valid == 0) return splitters;
    std.sort.pdq(CellKey, samples[0..valid], {}, cellKeyLessThan);
    for (&splitters, 1..) |*splitter, band| splitter.* = samples[band * valid / band_count];
    return splitters;
}

// ---- Tests --------------------------------------------------------------------

const testing = std.testing;
const builtin = @import("builtin");

// A query visitor that records every visit, stopping after `stop_after` visits.
const RecordingVisitor = struct {
    entries: [256]u32 = undefined,
    dx: [256]f32 = undefined,
    dy: [256]f32 = undefined,
    dist2: [256]f32 = undefined,
    count: usize = 0,
    stop_after: usize = std.math.maxInt(usize),

    fn visit(self: *RecordingVisitor, entry: u32, dx: f32, dy: f32, dist2: f32) NeighborVisitResult {
        self.entries[self.count] = entry;
        self.dx[self.count] = dx;
        self.dy[self.count] = dy;
        self.dist2[self.count] = dist2;
        self.count += 1;
        return if (self.count >= self.stop_after) .stop else .keep_going;
    }

    fn visited(self: *const RecordingVisitor) []const u32 {
        return self.entries[0..self.count];
    }

    fn expectEqual(self: *const RecordingVisitor, other: *const RecordingVisitor) !void {
        try testing.expectEqualSlices(u32, self.visited(), other.visited());
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(self.dx[0..self.count]), std.mem.sliceAsBytes(other.dx[0..other.count]));
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(self.dy[0..self.count]), std.mem.sliceAsBytes(other.dy[0..other.count]));
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(self.dist2[0..self.count]), std.mem.sliceAsBytes(other.dist2[0..other.count]));
    }
};

// An AI agent with a movement body at `(x, y)`.
fn addTestBody(data: *DataSystem, x: f32, y: f32) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{ .x = x, .y = y }, .previous_position = .{ .x = x, .y = y }, .velocity = .{}, .speed = 20 });
    try data.setAiAgent(entity, .{ .active_behavior = .wander });
    return entity;
}

// An AI agent with no movement body.
fn addTestBodiless(data: *DataSystem) !EntityId {
    const entity = try data.createEntity();
    try data.setAiAgent(entity, .{ .active_behavior = .wander });
    return entity;
}

fn aiPopulation(data: *const DataSystem) IndexPopulation {
    return .{ .entities = data.aiAgentSliceConst().entities };
}

// Index test layouts of `layout_slot_count` AI agents, every seventh from slot 3 without a
// body: every body in one cell row across about 200 cells; spread over many cell rows; at
// negative coordinates with a NaN y, a -inf x, a +inf y, and a -inf y; every body in one
// cell; a 10x10-cell cluster with one body far outside it; and cells on both sides of
// row-segment edges on both signs in four rows, with one body at each i32 cell extreme.
// Factions and levels vary.
const TestLayout = enum { one_row, spread, negative, one_cell, cluster_outlier, segment_edges };
const segment_edge_cells = [_]i32{ -129, -128, -65, -64, -1, 0, 63, 64, 127, 128 };
const layout_slot_count: usize = 1000;
const layout_cell_size: f32 = 20;
const layout_outlier_slot: usize = layout_slot_count - 1;

fn fillTestLayout(data: *DataSystem, layout: TestLayout) !void {
    var prng = std.Random.DefaultPrng.init(0x6e1d_b4d5);
    const random = prng.random();
    for (0..layout_slot_count) |slot| {
        if (slot % 7 == 3) {
            _ = try addTestBodiless(data);
            continue;
        }
        var x: f32 = 0;
        var y: f32 = 0;
        switch (layout) {
            .one_row => {
                x = random.float(f32) * 4000;
                y = 3 + random.float(f32) * 6;
            },
            .spread => {
                x = random.float(f32) * 120;
                y = random.float(f32) * 640;
            },
            .negative => {
                x = random.float(f32) * 120 - 300;
                y = -20 - random.float(f32) * 640;
            },
            .one_cell => {
                x = 1 + random.float(f32) * 18;
                y = 1 + random.float(f32) * 18;
            },
            .cluster_outlier => {
                x = random.float(f32) * 200;
                y = random.float(f32) * 200;
                if (slot == layout_outlier_slot) {
                    x = 1e6;
                    y = 1e6;
                }
            },
            .segment_edges => {
                const cell_x = segment_edge_cells[slot % segment_edge_cells.len];
                const cell_y: i32 = @as(i32, @intCast(slot / segment_edge_cells.len % 4)) - 2;
                x = (@as(f32, @floatFromInt(cell_x)) + 0.1 + random.float(f32) * 0.8) * layout_cell_size;
                y = (@as(f32, @floatFromInt(cell_y)) + 0.1 + random.float(f32) * 0.8) * layout_cell_size;
                // Finite, and past the i32 cell range on each side.
                if (slot == layout_outlier_slot) {
                    x = 3e38;
                    y = 3e38;
                }
                if (slot == layout_outlier_slot - 1) {
                    x = -3e38;
                    y = -3e38;
                }
            },
        }
        const entity = try addTestBody(data, x, y);
        try data.setFaction(entity, @fromBackingInt(@intCast(slot % 4)));
        if (slot % 5 == 0) try data.setWorldLevel(entity, @intCast(slot % 3));
    }
    if (layout == .negative) {
        // The store refuses non-finite positions; a column write is how one arrives.
        const entities = data.aiAgentSliceConst().entities;
        const movement = data.movementBodySlice();
        movement.previous_y[data.movementBodyDenseIndex(entities[501]).?] = std.math.nan(f32);
        movement.previous_x[data.movementBodyDenseIndex(entities[502]).?] = -std.math.inf(f32);
        movement.previous_y[data.movementBodyDenseIndex(entities[503]).?] = std.math.inf(f32);
        movement.previous_y[data.movementBodyDenseIndex(entities[504]).?] = -std.math.inf(f32);
    }
}

// Explicit band splitter sets, each nondecreasing: all past every cell; all one populated
// cell; populated cells at a stride; the i32 extremes around populated cells; and
// populated cells in equal pairs.
const TestSplitters = enum { all_max, one_cell, stride, extremes, pairs };

fn testSplitters(set: TestSplitters, cells: []const SpatialCell) [band_count - 1]CellKey {
    std.debug.assert(cells.len > 0);
    const min_key = CellKey{ .cell_y = std.math.minInt(i32), .cell_x = std.math.minInt(i32) };
    var splitters: [band_count - 1]CellKey = @splat(max_cell_key);
    for (&splitters, 0..) |*splitter, index| {
        const pick: usize = switch (set) {
            .all_max => continue,
            .one_cell => cells.len / 2,
            .stride, .extremes => index * cells.len / (band_count - 1),
            .pairs => (index / 2) * cells.len / (band_count / 2),
        };
        splitter.* = .{ .cell_y = cells[pick].cell_y, .cell_x = cells[pick].cell_x };
        if (set == .extremes and index < 8) splitter.* = min_key;
        if (set == .extremes and index >= band_count - 9) splitter.* = max_cell_key;
    }
    return splitters;
}

// A copy of a build's entries and of every band's cells, in key order.
const TestCapture = struct {
    x: std.ArrayList(f32) = .empty,
    y: std.ArrayList(f32) = .empty,
    entity: std.ArrayList(EntityId) = .empty,
    faction: std.ArrayList(Faction) = .empty,
    level: std.ArrayList(u16) = .empty,
    cells: std.ArrayList(SpatialCell) = .empty,

    fn capture(system: *const SpatialIndexSystem) !TestCapture {
        var copy = TestCapture{};
        errdefer copy.deinit();
        const index = system.view();
        try copy.x.appendSlice(testing.allocator, index.x);
        try copy.y.appendSlice(testing.allocator, index.y);
        try copy.entity.appendSlice(testing.allocator, index.entity);
        try copy.faction.appendSlice(testing.allocator, index.faction);
        try copy.level.appendSlice(testing.allocator, index.level);
        for (index.directory.bands) |band| try copy.cells.appendSlice(testing.allocator, index.cells[band.start..][0..band.cell_count]);
        return copy;
    }

    fn deinit(self: *TestCapture) void {
        self.cells.deinit(testing.allocator);
        self.level.deinit(testing.allocator);
        self.faction.deinit(testing.allocator);
        self.entity.deinit(testing.allocator);
        self.y.deinit(testing.allocator);
        self.x.deinit(testing.allocator);
    }
};

const parity_query_radii = [_]f32{ 0, 48, 96, 192 };
const parity_query_checks: u16 = 64;
// Cells sampled for the query battery, at a stride over the reference's cells.
const parity_query_cells: usize = 48;

// `system`'s index holds exactly the reference's entries, finds every reference cell
// through its directory and tables with the same range, and answers the query battery
// with the same visits and stats.
fn expectIndexMatches(system: *const SpatialIndexSystem, reference: *const TestCapture, reference_system: *const SpatialIndexSystem) !void {
    const index = system.view();
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(reference.x.items), std.mem.sliceAsBytes(index.x));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(reference.y.items), std.mem.sliceAsBytes(index.y));
    try testing.expectEqualSlices(EntityId, reference.entity.items, index.entity);
    try testing.expectEqualSlices(Faction, reference.faction.items, index.faction);
    try testing.expectEqualSlices(u16, reference.level.items, index.level);
    var cell_count: usize = 0;
    var segment_count: usize = 0;
    for (index.directory.bands) |band| {
        cell_count += band.cell_count;
        segment_count += band.segment_count;
    }
    try testing.expectEqual(reference.cells.items.len, cell_count);
    // One segment per (cell_y, segment_x) the cells hold, plus one per band boundary
    // inside a segment, so at most one per cell.
    var distinct_segments: usize = 0;
    for (reference.cells.items, 0..) |cell, cell_index| {
        if (cell_index == 0) {
            distinct_segments += 1;
            continue;
        }
        const previous = reference.cells.items[cell_index - 1];
        if (previous.cell_y != cell.cell_y or @divFloor(previous.cell_x, segment_cells) != @divFloor(cell.cell_x, segment_cells)) distinct_segments += 1;
    }
    try testing.expect(segment_count >= distinct_segments and segment_count <= cell_count);
    for (reference.cells.items) |cell| {
        const key = CellKey{ .cell_y = cell.cell_y, .cell_x = cell.cell_x };
        const found = index.pieceCells(index.directory.bandOfCell(key), cell.cell_y, cell.cell_x, cell.cell_x);
        try testing.expectEqualSlices(SpatialCell, &.{cell}, found);
    }

    const reference_index = reference_system.view();
    const stride = @max(reference.cells.items.len / parity_query_cells, 1);
    var cell_index: usize = 0;
    while (cell_index < reference.cells.items.len) : (cell_index += stride) {
        const cell = reference.cells.items[cell_index];
        const centre_x = (@as(f32, @floatFromInt(cell.cell_x)) + 0.5) * index.cell_size;
        const centre_y = (@as(f32, @floatFromInt(cell.cell_y)) + 0.5) * index.cell_size;
        for (parity_query_radii) |radius| {
            const query = NeighborQuery{ .x = centre_x, .y = centre_y, .radius = radius, .max_candidate_checks = parity_query_checks, .self = reference.entity.items[cell.start] };
            var expected = RecordingVisitor{};
            const expected_stats = reference_index.queryNeighbors(query, &expected);
            var actual = RecordingVisitor{};
            const actual_stats = index.queryNeighbors(query, &actual);
            try testing.expectEqual(expected_stats, actual_stats);
            try expected.expectEqual(&actual);
        }
    }
}

test "serial and threaded index builds match across layouts, splitters, range sizes, and worker counts" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 3, .items_per_range = 16 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    for (std.meta.tags(TestLayout)) |layout| {
        var data = DataSystem.init(testing.allocator);
        defer data.deinit();
        try fillTestLayout(&data, layout);
        const population = aiPopulation(&data);
        const config = SpatialIndexConfig{ .cell_size = layout_cell_size };

        var reference_system = SpatialIndexSystem.init(testing.allocator);
        defer reference_system.deinit();
        _ = try reference_system.buildSerial(&data, population, config);
        try testing.expectEqual(@as(usize, 0), reference_system.directory.splitter_count);
        var reference = try TestCapture.capture(&reference_system);
        defer reference.deinit();
        try testing.expectEqual(layout == .one_cell, reference.cells.items.len == 1);

        var system = SpatialIndexSystem.init(testing.allocator);
        defer system.deinit();
        var tuners = [2]AdaptiveWorkTuner{ AdaptiveWorkTuner.init(.{}), AdaptiveWorkTuner.init(.{}) };

        // Bucket and sort range sizes and worker counts under the production splitters.
        for ([_]usize{ 1, 3 }) |workers| {
            for ([_]usize{ 16, 64 }) |bucket_items| {
                for ([_]usize{ 16, 1024 }) |sort_items| {
                    const stages = BuildStages{
                        .bucket = Dispatch.init(&threads, &tuners[0], .{ .items_per_range = bucket_items, .max_worker_threads = workers, .adaptive = false }),
                        .sort = Dispatch.init(&threads, &tuners[1], .{ .items_per_range = sort_items, .max_worker_threads = workers, .adaptive = false }),
                    };
                    _ = try system.beginBuild(population, config);
                    const stats = system.buildBanded(&data, population, stages, chooseSplitters(&data, population, system.cell_size));
                    try testing.expect(!stats.bucket_batch.ran_inline);
                    try expectIndexMatches(&system, &reference, &reference_system);
                }
            }
        }

        // Explicit splitter sets over one partition.
        const stages = BuildStages{
            .bucket = Dispatch.init(&threads, &tuners[0], .{ .items_per_range = 64, .max_worker_threads = 3, .adaptive = false }),
            .sort = Dispatch.init(&threads, &tuners[1], .{ .items_per_range = 64, .max_worker_threads = 3, .adaptive = false }),
        };
        for (std.meta.tags(TestSplitters)) |set| {
            _ = try system.beginBuild(population, config);
            const stats = system.buildBanded(&data, population, stages, testSplitters(set, reference.cells.items));
            try testing.expect(!stats.bucket_batch.ran_inline and !stats.sort_batch.ran_inline);
            try expectIndexMatches(&system, &reference, &reference_system);
        }

        // The production build, and a config that allows no worker builds serially.
        const threaded = try system.build(&data, population, &threads, .{ .cell_size = layout_cell_size, .items_per_range = 64, .max_worker_threads = 3, .adaptive = false });
        try testing.expect(!threaded.bucket_batch.ran_inline and !threaded.sort_batch.ran_inline);
        try testing.expectEqual(band_count - 1, system.directory.splitter_count);
        try expectIndexMatches(&system, &reference, &reference_system);
        _ = try system.build(&data, population, &threads, .{ .cell_size = layout_cell_size, .max_worker_threads = 0 });
        try testing.expectEqual(@as(usize, 0), system.directory.splitter_count);
        try expectIndexMatches(&system, &reference, &reference_system);
    }
}

// The most entries any band of `system`'s index holds.
fn largestBandEntries(system: *const SpatialIndexSystem) usize {
    var largest: usize = 0;
    for (system.directory.bands) |band| largest = @max(largest, band.entry_count);
    return largest;
}

test "the threaded index splits a one-row corridor and a cluster with a far outlier across bands" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 3 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    for ([_]TestLayout{ .one_row, .cluster_outlier }) |layout| {
        var data = DataSystem.init(testing.allocator);
        defer data.deinit();
        try fillTestLayout(&data, layout);
        var system = SpatialIndexSystem.init(testing.allocator);
        defer system.deinit();
        const stats = try system.build(&data, aiPopulation(&data), &threads, .{ .cell_size = layout_cell_size, .items_per_range = 64, .max_worker_threads = 3, .adaptive = false });
        try testing.expect(stats.entity_count > 0);
        try testing.expect(largestBandEntries(&system) <= stats.entity_count / 8);
    }
}

test "queryNeighbors visits a cell's entries in slot order, skipping self without a check, inside a strict radius" {
    // Every body in cell (0, 0) at cell size 10; slot 2 sits exactly at the radius.
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const self_entity = try addTestBody(&data, 0, 0);
    _ = try addTestBody(&data, 3, 0);
    _ = try addTestBody(&data, 5, 0);
    _ = try addTestBody(&data, 4.9, 0);
    _ = try addTestBody(&data, 1, 0);
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    _ = try system.buildSerial(&data, aiPopulation(&data), .{ .cell_size = 10 });
    const index = system.view();

    var visitor = RecordingVisitor{};
    const stats = index.queryNeighbors(.{ .x = 0, .y = 0, .radius = 5, .max_candidate_checks = 128, .self = self_entity }, &visitor);
    // Slot 2 (dist2 == 25) is checked but not visited; self is neither.
    try testing.expectEqualSlices(u32, &.{ 1, 3, 4 }, visitor.visited());
    try testing.expectEqual(@as(u16, 4), stats.candidate_checks);
    try testing.expectEqual(@as(f32, -3), visitor.dx[0]);
    try testing.expectEqual(@as(f32, 9), visitor.dist2[0]);

    // Without a self, slot 0 is a candidate at distance 0.
    var all = RecordingVisitor{};
    _ = index.queryNeighbors(.{ .x = 0, .y = 0, .radius = 5, .max_candidate_checks = 128 }, &all);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 3, 4 }, all.visited());
}

test "queryNeighbors stops at its check budget before the tipping entry, and on a visitor stop" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const self_entity = try addTestBody(&data, 0, 0);
    _ = try addTestBody(&data, 1, 0);
    _ = try addTestBody(&data, 2, 0);
    _ = try addTestBody(&data, 3, 0);
    // Cell rows below and a cell to the right, past the first cell's entries.
    _ = try addTestBody(&data, 15, 0);
    _ = try addTestBody(&data, 5, 15);
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    _ = try system.buildSerial(&data, aiPopulation(&data), .{ .cell_size = 10 });
    const index = system.view();

    var capped = RecordingVisitor{};
    const capped_stats = index.queryNeighbors(.{ .x = 0, .y = 0, .radius = 100, .max_candidate_checks = 1, .self = self_entity }, &capped);
    try testing.expectEqualSlices(u32, &.{1}, capped.visited());
    try testing.expectEqual(@as(u16, 1), capped_stats.candidate_checks);

    // A stop in the first cell ends the row and the scan.
    var stopped = RecordingVisitor{ .stop_after = 2 };
    const stopped_stats = index.queryNeighbors(.{ .x = 0, .y = 0, .radius = 100, .max_candidate_checks = 64 }, &stopped);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, stopped.visited());
    try testing.expectEqual(@as(u16, 2), stopped_stats.candidate_checks);

    // Unbounded, the scan runs cell_y outer, cell_x inner: (0, 0), (0, 1), then (1, 0).
    var full = RecordingVisitor{};
    _ = index.queryNeighbors(.{ .x = 0, .y = 0, .radius = 100, .max_candidate_checks = 64 }, &full);
    try testing.expectEqual(@as(usize, 6), full.count);
    try testing.expectEqual(@as(f32, 15), index.x[full.entries[4]]);
    try testing.expectEqual(@as(f32, 15), index.y[full.entries[5]]);
}

test "an index over population rows maps each slot to its row's entity and skips bodiless slots" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const near = try addTestBody(&data, 4, 4);
    _ = try addTestBody(&data, 6, 6);
    const bodiless = try addTestBodiless(&data);
    const far = try addTestBody(&data, 12, 4);
    try data.setFaction(far, .hostile);
    try data.setWorldLevel(far, 2);
    _ = bodiless;
    // Agent 1 is outside the rows; agent 2 has no body.
    const rows = [_]u32{ 3, 2, 0 };
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    const stats = try system.buildSerial(&data, .{ .entities = data.aiAgentSliceConst().entities, .rows = &rows }, .{ .cell_size = 10 });
    try testing.expectEqual(@as(usize, 2), stats.entity_count);
    const index = system.view();
    // Cell (0, 0) holds slot 2 (`near`), cell (0, 1) slot 0 (`far`).
    try testing.expectEqualSlices(EntityId, &.{ near, far }, index.entity);
    try testing.expectEqual(Faction.hostile, index.faction[1]);
    try testing.expectEqual(@as(u16, 2), index.level[1]);
    try testing.expectEqual(Faction.neutral, index.faction[0]);
    try testing.expectEqual(@as(u16, 0), index.level[0]);
}

// A query's visits by brute force: every entry whose cell lies in the query's box, in
// ascending entry order (the box scan's (cell_y, cell_x, slot) order), self skipped,
// counted against the budget, then visited inside the strict radius.
fn bruteForceVisits(index: SpatialIndexView, query: NeighborQuery, expected: *RecordingVisitor) NeighborQueryStats {
    var stats = NeighborQueryStats{};
    const scan = cellScanRadius(query.radius, index.cell_size);
    const own = cellForPosition(query.x, query.y, index.cell_size);
    for (0..index.x.len) |entry| {
        if (index.entity[entry].eql(query.self)) continue;
        const cell = cellForPosition(index.x[entry], index.y[entry], index.cell_size);
        if (@abs(@as(i64, cell.cell_x) - own.cell_x) > scan or @abs(@as(i64, cell.cell_y) - own.cell_y) > scan) continue;
        if (stats.candidate_checks >= query.max_candidate_checks) break;
        stats.candidate_checks += 1;
        const dx = query.x - index.x[entry];
        const dy = query.y - index.y[entry];
        const dist2 = dx * dx + dy * dy;
        if (dist2 < query.radius * query.radius) _ = expected.visit(@intCast(entry), dx, dy, dist2);
    }
    return stats;
}

test "queryNeighbors visits exactly a brute-force scan's in-box entries in ascending entry order, up to its check budget" {
    // Bodies over cells -75..74 at cell size 4, in 20 cell rows: radius 300 spans several
    // row segments and bands per row.
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    var prng = std.Random.DefaultPrng.init(0x0b5e_55ed);
    const random = prng.random();
    for (0..200) |_| _ = try addTestBody(&data, random.float(f32) * 600 - 300, random.float(f32) * 80 - 40);
    const population = aiPopulation(&data);
    const config = SpatialIndexConfig{ .cell_size = 4 };

    var serial = SpatialIndexSystem.init(testing.allocator);
    defer serial.deinit();
    _ = try serial.buildSerial(&data, population, config);
    var reference = try TestCapture.capture(&serial);
    defer reference.deinit();

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = if (builtin.single_threaded) 0 else 3 });
    defer threads.deinit();
    var tuners = [2]AdaptiveWorkTuner{ AdaptiveWorkTuner.init(.{}), AdaptiveWorkTuner.init(.{}) };
    var banded = SpatialIndexSystem.init(testing.allocator);
    defer banded.deinit();
    _ = try banded.beginBuild(population, config);
    _ = banded.buildBanded(&data, population, .{
        .bucket = Dispatch.init(&threads, &tuners[0], .{ .items_per_range = 16, .max_worker_threads = 3, .adaptive = false }),
        .sort = Dispatch.init(&threads, &tuners[1], .{ .items_per_range = 16, .max_worker_threads = 3, .adaptive = false }),
    }, testSplitters(.pairs, reference.cells.items));

    for ([_]*const SpatialIndexSystem{ &serial, &banded }) |system| {
        const index = system.view();
        for (0..index.x.len) |origin| {
            for ([_]f32{ 0, 20, 100, 300 }) |radius| {
                for ([_]u16{ 64, 1000 }) |checks| {
                    const query = NeighborQuery{ .x = index.x[origin], .y = index.y[origin], .radius = radius, .max_candidate_checks = checks, .self = index.entity[origin] };
                    var expected = RecordingVisitor{};
                    const expected_stats = bruteForceVisits(index, query, &expected);
                    var actual = RecordingVisitor{};
                    const actual_stats = index.queryNeighbors(query, &actual);
                    try testing.expectEqual(expected_stats, actual_stats);
                    try expected.expectEqual(&actual);
                }
            }
        }
    }
}

test "row segments hold each 64-cell span's cells, split where a splitter falls inside one" {
    // One cell row at cell size 10: cells -65 | -64, -1 | 0, 63 | 64 lie in spans -2..1.
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    for ([_]i32{ -65, -64, -1, 0, 63, 64 }) |cell_x| _ = try addTestBody(&data, @as(f32, @floatFromInt(cell_x)) * 10 + 5, 5);
    const population = aiPopulation(&data);
    const config = SpatialIndexConfig{ .cell_size = 10 };

    var serial = SpatialIndexSystem.init(testing.allocator);
    defer serial.deinit();
    _ = try serial.buildSerial(&data, population, config);
    const one_band = serial.view();
    try testing.expectEqual(@as(u32, 4), one_band.directory.bands[0].segment_count);
    const expected = [_]struct { segment_x: i32, first_cell: u32, mask: u64 }{
        .{ .segment_x = -2, .first_cell = 0, .mask = 1 << 63 },
        .{ .segment_x = -1, .first_cell = 1, .mask = 1 | 1 << 63 },
        .{ .segment_x = 0, .first_cell = 3, .mask = 1 | 1 << 63 },
        .{ .segment_x = 1, .first_cell = 5, .mask = 1 },
    };
    for (expected, one_band.segments[0..expected.len]) |want, segment| {
        try testing.expectEqual(@as(i32, 0), segment.cell_y);
        try testing.expectEqual(want.segment_x, segment.segment_x);
        try testing.expectEqual(want.first_cell, segment.first_cell);
        try testing.expectEqual(want.mask, segment.occupied.mask);
    }

    // A splitter at cell 32 gives span 0 one record in each band.
    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = if (builtin.single_threaded) 0 else 2 });
    defer threads.deinit();
    var tuners = [2]AdaptiveWorkTuner{ AdaptiveWorkTuner.init(.{}), AdaptiveWorkTuner.init(.{}) };
    var splitters: [band_count - 1]CellKey = @splat(max_cell_key);
    splitters[0] = .{ .cell_y = 0, .cell_x = 32 };
    var banded = SpatialIndexSystem.init(testing.allocator);
    defer banded.deinit();
    _ = try banded.beginBuild(population, config);
    _ = banded.buildBanded(&data, population, .{
        .bucket = Dispatch.init(&threads, &tuners[0], .{ .items_per_range = 16, .max_worker_threads = 2, .adaptive = false }),
        .sort = Dispatch.init(&threads, &tuners[1], .{ .items_per_range = 16, .max_worker_threads = 2, .adaptive = false }),
    }, splitters);
    const two_bands = banded.view();
    const lower = two_bands.directory.bands[0];
    const upper = two_bands.directory.bands[1];
    try testing.expectEqual(@as(u32, 3), lower.segment_count);
    try testing.expectEqual(@as(u32, 2), upper.segment_count);
    const lower_span = two_bands.segments[lower.start + 2];
    const upper_span = two_bands.segments[upper.start];
    try testing.expectEqual(@as(i32, 0), lower_span.segment_x);
    try testing.expectEqual(@as(u64, 1), lower_span.occupied.mask);
    try testing.expectEqual(@as(i32, 0), upper_span.segment_x);
    try testing.expectEqual(@as(u64, 1 << 63), upper_span.occupied.mask);
    try testing.expectEqual(upper.start, upper_span.first_cell);

    // Both indexes visit every entry, in order, across the split span.
    const query = NeighborQuery{ .x = 325, .y = 5, .radius = 1000, .max_candidate_checks = 64 };
    var one_band_visits = RecordingVisitor{};
    _ = one_band.queryNeighbors(query, &one_band_visits);
    var two_band_visits = RecordingVisitor{};
    _ = two_bands.queryNeighbors(query, &two_band_visits);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5 }, one_band_visits.visited());
    try one_band_visits.expectEqual(&two_band_visits);
}

test "index cells in lanes match cellForPosition, including the scalar tail" {
    // 25 slots: six lane blocks and a one-slot tail. Cell size 30 is not a power of two,
    // so a reciprocal multiply in place of the division would diverge.
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    for (0..25) |slot| {
        _ = try addTestBody(&data, @as(f32, @floatFromInt(slot % 23)) * 7.0 - 40.0, @as(f32, @floatFromInt(slot / 23)) * 5.0 - 20.0);
    }
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    _ = try system.buildSerial(&data, aiPopulation(&data), .{ .cell_size = 30 });

    const index = system.view();
    var keys_checked: usize = 0;
    for (index.cells[0..index.directory.bands[0].cell_count]) |cell| {
        for (cell.start..cell.end) |entry| {
            // Recomputed from the fixture's own formula, not read back from the index.
            const slot = system.keys.items[entry].slot;
            const expected = cellForPosition(@as(f32, @floatFromInt(slot % 23)) * 7.0 - 40.0, @as(f32, @floatFromInt(slot / 23)) * 5.0 - 20.0, 30);
            try testing.expectEqual(expected, CellKey{ .cell_y = cell.cell_y, .cell_x = cell.cell_x });
            keys_checked += 1;
        }
    }
    try testing.expectEqual(@as(usize, 25), keys_checked);
}

test "the entry visit in lanes matches the scalar visit, including NaN and the tail" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    // Nine bodies in cell (0, 0): one NaN position, one exactly at the radius.
    const positions = [_][2]f32{ .{ 1, 1 }, .{ 2, 3 }, .{ 0, 0 }, .{ 4, 4 }, .{ 9, 1 }, .{ 3, 0 }, .{ 5, 5 }, .{ 1, 8 }, .{ 7, 7 } };
    for (positions) |position| _ = try addTestBody(&data, position[0], position[1]);
    data.movementBodySlice().previous_x[4] = std.math.nan(f32);
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    _ = try system.buildSerial(&data, aiPopulation(&data), .{ .cell_size = 10 });
    const index = system.view();
    try testing.expectEqual(@as(u32, 1), index.directory.bands[0].cell_count);

    for (1..positions.len + 1) |length| {
        for ([_]u16{ 2, 64 }) |checks| {
            const query = NeighborQuery{ .x = 2, .y = 1, .radius = 3, .max_candidate_checks = checks, .self = index.entity[1] };
            var lanes = RecordingVisitor{};
            var lane_stats = NeighborQueryStats{};
            const lane_stop = index.visitEntries(query, QueryLanes.init(query), 0, @intCast(length), &lanes, &lane_stats);
            var scalar = RecordingVisitor{};
            var scalar_stats = NeighborQueryStats{};
            const scalar_stop = index.visitEntriesScalar(query, query.radius * query.radius, 0, length, &scalar, &scalar_stats);
            try testing.expectEqual(scalar_stop, lane_stop);
            try testing.expectEqual(scalar_stats, lane_stats);
            try scalar.expectEqual(&lanes);
        }
    }
}

test "a build after a populated one leaves no stale cells, serial and threaded" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    for (0..40) |slot| _ = try addTestBody(&data, @floatFromInt(slot * 3), 0);
    var empty_data = DataSystem.init(testing.allocator);
    defer empty_data.deinit();
    // Slots, none with a body.
    for (0..20) |_| _ = try addTestBodiless(&empty_data);

    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = if (builtin.single_threaded) 0 else 2 });
    defer threads.deinit();

    const empties = [_]IndexPopulation{ aiPopulation(&empty_data), .{ .entities = &.{} } };
    for (empties) |empty| {
        for ([_]bool{ false, true }) |threaded| {
            _ = try system.buildSerial(&data, aiPopulation(&data), .{});
            try testing.expect(system.view().entity.len == 40);
            const stats = if (threaded)
                try system.build(&empty_data, empty, &threads, .{ .items_per_range = 16, .adaptive = false })
            else
                try system.buildSerial(&empty_data, empty, .{});
            try testing.expectEqual(@as(usize, 0), stats.entity_count);
            const index = system.view();
            try testing.expectEqual(@as(usize, 0), index.entity.len);
            for (index.directory.bands) |band| {
                try testing.expectEqual(@as(u32, 0), band.cell_count);
                try testing.expectEqual(@as(u32, 0), band.segment_count);
            }
            var visitor = RecordingVisitor{};
            const query_stats = index.queryNeighbors(.{ .x = 3, .y = 0, .radius = 64, .max_candidate_checks = 64 }, &visitor);
            try testing.expectEqual(@as(usize, 0), visitor.count);
            try testing.expectEqual(@as(u16, 0), query_stats.candidate_checks);
        }
    }
}

test "the index builds correctly above a small reserved capacity" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    for (0..40) |slot| _ = try addTestBody(&data, @floatFromInt(slot * 7), @floatFromInt(slot % 5));
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    try system.reserve(4);
    const stats = try system.buildSerial(&data, aiPopulation(&data), .{});
    try testing.expectEqual(@as(usize, 40), stats.entity_count);
    try testing.expectEqual(@as(usize, 40), system.view().entity.len);
    try testing.expect(system.directory.bands[0].cell_count > 0);
}

test "after reserve, threaded builds at 2 and 4 partitions per stage, a serial build, and a query allocate nothing" {
    // No warm build: the reserve alone covers every partition the tuners can pick.
    if (builtin.single_threaded) return error.SkipZigTest;

    const population_count: usize = 64;
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    for (0..population_count) |slot| {
        _ = try addTestBody(&data, @as(f32, @floatFromInt(slot % 23)) * 7.0 - 40.0, @as(f32, @floatFromInt(slot / 23)) * 5.0 - 20.0);
    }
    const population = aiPopulation(&data);

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    // Without real workers the threaded build runs serially and this proof passes falsely.
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var reference = SpatialIndexSystem.init(testing.allocator);
    defer reference.deinit();
    _ = try reference.buildSerial(&data, population, .{});

    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    try system.reserve(population_count);
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const original_allocator = system.allocator;
    system.allocator = failing.allocator();
    defer system.allocator = original_allocator;

    for ([_]usize{ 32, 16 }) |items_per_range| {
        const stats = try system.build(&data, population, &threads, .{ .items_per_range = items_per_range, .max_worker_threads = 2, .adaptive = false });
        try testing.expectEqual(population_count, stats.entity_count);
        try testing.expect(!stats.bucket_batch.ran_inline and !stats.sort_batch.ran_inline);
        try testing.expectEqual(population_count / items_per_range, stats.bucket_batch.range_count);
        try testing.expectEqual(population_count / items_per_range, stats.sort_batch.range_count);
        try testing.expectEqualSlices(EntityId, reference.view().entity, system.view().entity);
    }
    const serial_stats = try system.buildSerial(&data, population, .{});
    try testing.expectEqual(population_count, serial_stats.entity_count);
    var visitor = RecordingVisitor{};
    _ = system.view().queryNeighbors(.{ .x = 0, .y = 0, .radius = 128, .max_candidate_checks = 16 }, &visitor);
    try testing.expectEqual(@as(usize, 16), visitor.count);
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}
