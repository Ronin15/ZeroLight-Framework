// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! The steering agent grid, `grid_bucket` and `grid_sort`: snapshot rows bucketed by cell in
//! sampled cell-key bands, sorted, and indexed by a band directory the avoidance pass
//! queries. Free functions over `*SteeringSystem`; its step calls `buildAgentGrid`.

const std = @import("std");
const runtime_perf_log = @import("../../../app/runtime_perf_log.zig");
const BatchSelection = @import("../../../app/thread_system.zig").BatchSelection;
const PaddedSlot = @import("../../../app/thread_system.zig").PaddedSlot;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const inlineBatch = @import("../../../app/thread_system.zig").inlineBatch;
const setSlotCount = @import("../../../app/thread_system.zig").setSlotCount;
const thread_shared_record_alignment = @import("../../../app/thread_system.zig").thread_shared_record_alignment;
const math = @import("../../../core/math.zig");
const simd = @import("../../../core/simd.zig");
const pdqSort = @import("../../../core/sort.zig").pdq;
const steering_range_alignment_items = @import("system.zig").steering_range_alignment_items;
const min_spatial_cell_size = @import("system.zig").min_spatial_cell_size;
const max_bands = @import("system.zig").max_bands;
const StageThreads = @import("system.zig").StageThreads;
const SteeringStats = @import("system.zig").SteeringStats;
const SteeringSystem = @import("system.zig").SteeringSystem;
const BandRow = @import("system.zig").BandRow;
const ConstAgentSnapshotSlice = @import("system.zig").ConstAgentSnapshotSlice;

/// The agent grid over the snapshot's rows with a body: entries sorted by (cell_y, cell_x,
/// row) and one range per occupied cell. Serial (also when no stage can get a worker), one
/// fill and one sort in a single band. Threaded, the main thread samples the band splitters, `grid_bucket` places each range's
/// entries by band in its window, then `grid_sort` gathers, sorts, and splits each band in
/// its own slice; each stage runs inline or on workers as its tuner selects. A cell lies in
/// one band and the bands follow cell order, so every cell holds the same entries in the
/// same order for any splitters and partition.
pub fn buildAgentGrid(self: *SteeringSystem, threads: StageThreads, stats: *SteeringStats) void {
    const stage = StageThreads.withWorkers(threads) orelse {
        buildAgentGridDirect(self);
        if (comptime runtime_perf_log.enabled) stats.perf.grid_bucket_batch = inlineBatch(self.agent_snapshot_rows.len, steering_range_alignment_items);
        return;
    };
    const splitters = chooseGridSplitters(self.agentSnapshotSliceConst(), self.spatial_cell_size);
    const selection = stage.stage(&self.grid_bucket_tuner).select(self.agent_snapshot_rows.len, steering_range_alignment_items);
    buildAgentGridBanded(self, stage, selection, splitters, stats);
}

// The serial grid: one fill and one sort, every cell range in the directory's one band.
fn buildAgentGridDirect(self: *SteeringSystem) void {
    const agent_count = self.agent_snapshot_rows.len;
    std.debug.assert(self.agent_cell_entries.capacity >= agent_count and self.agent_cell_ranges.capacity >= agent_count);
    self.agent_cell_entries.items.len = agent_count;
    self.agent_cell_ranges.items.len = agent_count;
    self.agent_cell_entries.items.len = fillCellEntries(self.agentSnapshotSliceConst(), self.spatial_cell_size, 0, agent_count, self.agent_cell_entries.items);
    const range_count = sortCellEntries(self.agent_cell_entries.items, self.agent_cell_ranges.items, 0);
    self.agent_cell_ranges.items.len = range_count;
    self.agent_grid = .{};
    self.agent_grid.bands[0] = .{ .start = 0, .range_count = range_count };
}

// `grid_bucket` over the snapshot rows in `selection`'s ranges into the `max_bands` bands
// of `splitters` (nondecreasing), then `grid_sort` over the bands; the main thread lays
// out the band slices and the band directory.
fn buildAgentGridBanded(self: *SteeringSystem, stage: StageThreads, selection: BatchSelection, splitters: [max_bands - 1]CellKey, stats: *SteeringStats) void {
    const agent_count = self.agent_snapshot_rows.len;
    for (splitters[0 .. max_bands - 2], splitters[1..]) |lower, upper| std.debug.assert(cellKeyOrder(upper, lower) != .lt);
    std.debug.assert(self.agent_cell_entries.capacity >= agent_count and self.agent_cell_ranges.capacity >= agent_count);
    std.debug.assert(self.agent_cell_staging.capacity >= agent_count);
    self.agent_cell_entries.items.len = agent_count;
    self.agent_cell_ranges.items.len = agent_count;
    self.agent_cell_staging.items.len = agent_count;
    setSlotCount(BandRow, &self.band_rows, selection.range_count);
    self.agent_grid = .{ .splitters = splitters, .splitter_count = max_bands - 1 };
    var bucket = BucketJob{
        .agents = self.agentSnapshotSliceConst(),
        .cell_size = self.spatial_cell_size,
        .grid = &self.agent_grid,
        .scratch = self.agent_cell_entries.items,
        .staging = self.agent_cell_staging.items,
        .items_per_range = selection.items_per_range,
        .band_rows = self.band_rows.items,
    };
    const bucket_batch = stage.stage(&self.grid_bucket_tuner).run(selection, agent_count, steering_range_alignment_items, &bucket, bucketJob);
    if (comptime runtime_perf_log.enabled) stats.perf.grid_bucket_batch = bucket_batch;

    // Each band's slice starts after every range's entries of the earlier bands.
    var band_start: [max_bands + 1]usize = @splat(0);
    for (self.band_rows.items) |slot| {
        for (&band_start, slot.value.offsets) |*start, range_offset| start.* += range_offset;
    }

    // A fixed shape (an explicit range size) sorts one band per range.
    var sort_stage = stage.stage(&self.grid_sort_tuner);
    if (stage.config.items_per_range != null) sort_stage.items_per_range = 1;
    const sort_selection = sort_stage.select(max_bands, 1);
    setSlotCount(GridSortTally, &self.grid_sort_tallies, max_bands);
    var sort = SortJob{
        .staging = self.agent_cell_staging.items,
        .band_rows = self.band_rows.items,
        .bucket_items_per_range = selection.items_per_range,
        .band_start = band_start,
        .entries = self.agent_cell_entries.items,
        .ranges = self.agent_cell_ranges.items,
        .tallies = self.grid_sort_tallies.items,
        .range_count = sort_selection.range_count,
    };
    const sort_batch = sort_stage.run(sort_selection, max_bands, 1, &sort, sortJob);
    if (comptime runtime_perf_log.enabled) stats.perf.grid_sort_batch = sort_batch;

    self.agent_cell_entries.items.len = band_start[max_bands];
    for (&self.agent_grid.bands, self.grid_sort_tallies.items, band_start[0..max_bands]) |*band, slot, band_entry_start| {
        band.* = .{ .start = band_entry_start, .range_count = slot.value.range_count };
    }
}

pub const GridSortTally = struct {
    range_count: usize = 0,
};

comptime {
    std.debug.assert(@sizeOf(PaddedSlot(GridSortTally)) % thread_shared_record_alignment == 0);
}

// A spatial cell, ordered by (cell_y, cell_x).
const CellKey = struct {
    cell_y: i32,
    cell_x: i32,
};

// `cell` against `key` in (cell_y, cell_x) order, as `std.sort`'s searches compare. Plain
// comparisons: per-field `std.math.order` calls measure slower on this per-query lookup.
fn cellKeyOrder(cell: CellKey, key: CellKey) std.math.Order {
    if (cell.cell_y != key.cell_y) return if (cell.cell_y < key.cell_y) .lt else .gt;
    if (cell.cell_x != key.cell_x) return if (cell.cell_x < key.cell_x) .lt else .gt;
    return .eq;
}

// The largest cell key; splitters at it leave the bands after them empty.
const max_cell_key = CellKey{ .cell_y = std.math.maxInt(i32), .cell_x = std.math.maxInt(i32) };
// Snapshot rows sampled per step for the grid's band splitters: four per band, a fixed
// count. Balance only; the grid is the same for any splitters.
const grid_sample_count: usize = 4 * max_bands;
// The golden ratio's fractional part in 0.64 fixed point.
const grid_sample_fraction_step: u64 = 0x9E3779B97F4A7C15;

// One band's cell ranges: `range_count` from `start` in `agent_cell_ranges`.
const CellBand = struct {
    start: usize = 0,
    range_count: usize = 0,
};

/// Which band holds a cell, and where each band's cell ranges are. A cell's band is the
/// count of splitters at or below it; the splitters are nondecreasing, so the bands follow
/// cell order and every cell lies in exactly one. Without splitters there is one band.
pub const AgentGridDirectory = struct {
    splitters: [max_bands - 1]CellKey = @splat(max_cell_key),
    // 0 for the serial grid's one band, else `max_bands - 1`.
    splitter_count: usize = 0,
    bands: [max_bands]CellBand = @splat(.{}),

    fn bandOfCell(self: *const AgentGridDirectory, cell_x: i32, cell_y: i32) usize {
        const cell = CellKey{ .cell_y = cell_y, .cell_x = cell_x };
        return std.sort.partitionPoint(CellKey, self.splitters[0..self.splitter_count], cell, splitterAtOrBelow);
    }

    // `std.sort.upperBound` as one predicate call per probe: its order wrapper measures
    // slower on this per-query lookup.
    fn splitterAtOrBelow(cell: CellKey, splitter: CellKey) bool {
        return cellKeyOrder(cell, splitter) != .lt;
    }

    // The cell ranges of the band holding the cell, sorted by (cell_y, cell_x).
    pub fn rangesOfCell(self: *const AgentGridDirectory, ranges: []const SpatialCellRange, cell_x: i32, cell_y: i32) []const SpatialCellRange {
        const band = self.bands[self.bandOfCell(cell_x, cell_y)];
        return ranges[band.start..][0..band.range_count];
    }
};

// `grid_bucket`: one range of snapshot rows.
const BucketJob = struct {
    agents: ConstAgentSnapshotSlice,
    cell_size: f32,
    // Its splitters, written before dispatch.
    grid: *const AgentGridDirectory,
    // Range r's windows start at `r * items_per_range`.
    scratch: []SpatialCellEntry,
    staging: []SpatialCellEntry,
    items_per_range: usize,
    band_rows: []PaddedSlot(BandRow),
};

// Fills the range's cell entries into its scratch window, then places them in its staging
// window by cell-key band, in row order within a band, and records the band offsets. The
// band search runs twice per entry rather than storing each band: scalar, a six-step
// binary search over two-field keys.
fn bucketJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *BucketJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.band_rows.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end and range.end <= job.agents.len());
    std.debug.assert(range.end <= job.scratch.len and range.end <= job.staging.len);
    std.debug.assert(job.grid.splitter_count == max_bands - 1);
    const filled = job.scratch[range.start..][0..fillCellEntries(job.agents, job.cell_size, range.start, range.end, job.scratch[range.start..range.end])];
    var offsets: [max_bands + 1]u32 = @splat(0);
    for (filled) |entry| offsets[job.grid.bandOfCell(entry.cell_x, entry.cell_y) + 1] += 1;
    for (1..max_bands + 1) |band| offsets[band] += offsets[band - 1];
    job.band_rows[range.index].value.offsets = offsets;
    var cursor = offsets;
    for (filled) |entry| {
        const band = job.grid.bandOfCell(entry.cell_x, entry.cell_y);
        job.staging[range.start + cursor[band]] = entry;
        cursor[band] += 1;
    }
}

// `grid_sort`: one range of the `max_bands` bands.
const SortJob = struct {
    staging: []const SpatialCellEntry,
    band_rows: []const PaddedSlot(BandRow),
    bucket_items_per_range: usize,
    // Band b's entries and cell ranges go to `[band_start[b], band_start[b + 1])`.
    band_start: [max_bands + 1]usize,
    entries: []SpatialCellEntry,
    ranges: []SpatialCellRange,
    tallies: []PaddedSlot(GridSortTally),
    range_count: usize,
};

// Each band gathers every bucket range's band segment in range order into its slice, sorts
// it, and writes its cell ranges into the same slice of the range list.
fn sortJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *SortJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= max_bands and max_bands <= job.tallies.len);
    std.debug.assert(job.band_start[range.end] <= job.entries.len and job.band_start[range.end] <= job.ranges.len);
    for (range.start..range.end) |band| {
        const start = job.band_start[band];
        const end = job.band_start[band + 1];
        var cursor = start;
        for (job.band_rows, 0..) |slot, bucket_range| {
            const window = job.staging[bucket_range * job.bucket_items_per_range ..];
            const segment = window[slot.value.offsets[band]..slot.value.offsets[band + 1]];
            @memcpy(job.entries[cursor..][0..segment.len], segment);
            cursor += segment.len;
        }
        std.debug.assert(cursor == end);
        job.tallies[band].value = .{ .range_count = sortCellEntries(job.entries[start..end], job.ranges[start..end], start) };
    }
}

pub const SpatialCellEntry = struct {
    cell_x: i32,
    cell_y: i32,
    index: usize,
};

pub const SpatialCellRange = struct {
    cell_x: i32,
    cell_y: i32,
    start: usize,
    end: usize,
};

// Sorts `entries` by (cell_y, cell_x, row) and writes one range per occupied cell to
// `ranges`, its bounds offset by `base` (the slice's position in the entry list). Returns the
// range count, at most the entry count.
fn sortCellEntries(entries: []SpatialCellEntry, ranges: []SpatialCellRange, base: usize) usize {
    std.debug.assert(ranges.len >= entries.len);
    // pdqsort: agents move slowly so order is often nearly sorted; still O(n log n) worst case.
    pdqSort(SpatialCellEntry, entries, {}, spatialCellEntryLessThan);
    var range_count: usize = 0;
    var entry_index: usize = 0;
    while (entry_index < entries.len) {
        const cell_x = entries[entry_index].cell_x;
        const cell_y = entries[entry_index].cell_y;
        const start = entry_index;
        while (entry_index < entries.len and entries[entry_index].cell_x == cell_x and entries[entry_index].cell_y == cell_y) {
            entry_index += 1;
        }
        ranges[range_count] = .{ .cell_x = cell_x, .cell_y = cell_y, .start = base + start, .end = base + entry_index };
        range_count += 1;
    }
    return range_count;
}

// The agent grid's `max_bands - 1` band splitters: the cells at the band quantiles of up to
// `grid_sample_count` snapshot rows (rows without a body skipped), sorted. Every row when
// they fit the sample, else rows at a golden-ratio sequence of fractions of the row count,
// which shares no period with a periodic row order. Fixed work on the main thread; with no
// sampled body every splitter is `max_cell_key`.
fn chooseGridSplitters(agents: ConstAgentSnapshotSlice, cell_size: f32) [max_bands - 1]CellKey {
    const row_count = agents.len();
    const sample_count: usize = @min(grid_sample_count, row_count);
    var samples: [grid_sample_count]SpatialCellEntry = undefined;
    var valid: usize = 0;
    // A 0.64 fixed-point fraction stepped by the golden ratio's fractional part.
    var fraction: u64 = 0;
    for (0..sample_count) |sample| {
        fraction +%= grid_sample_fraction_step;
        // The high word of fraction * row_count is below row_count, so it fits usize.
        const row: usize = if (row_count <= grid_sample_count) sample else @intCast(std.math.mulWide(u64, fraction, row_count) >> 64);
        if (!agents.entity[row].isValid()) continue;
        samples[valid] = .{ .cell_x = spatialCell(agents.x[row], cell_size), .cell_y = spatialCell(agents.y[row], cell_size), .index = row };
        valid += 1;
    }
    var splitters: [max_bands - 1]CellKey = @splat(max_cell_key);
    if (valid == 0) return splitters;
    pdqSort(SpatialCellEntry, samples[0..valid], {}, spatialCellEntryLessThan);
    for (&splitters, 1..) |*splitter, band| {
        const sample = samples[band * valid / max_bands];
        splitter.* = .{ .cell_y = sample.cell_y, .cell_x = sample.cell_x };
    }
    return splitters;
}

// Writes a cell entry to `out` for each row of `[start, end)` with a body, in row order, and
// returns the count: cells over the snapshot's x/y columns in lanes with a scalar tail, bit
// for bit `spatialCell`.
fn fillCellEntries(agents: ConstAgentSnapshotSlice, cell_size: f32, start: usize, end: usize, out: []SpatialCellEntry) usize {
    std.debug.assert(start <= end and end <= agents.len() and out.len >= end - start);
    const cell_size_lanes = simd.splatFloat4(@max(cell_size, min_spatial_cell_size));
    var count: usize = 0;
    var row = start;
    const vector_end = start + simd.vectorizedEnd(end - start);
    while (row < vector_end) : (row += simd.lane_count) {
        const cell_x = simd.toIntArray(simd.floorToI4(simd.divFloat4(simd.loadFloat4(agents.x[row..]), cell_size_lanes)));
        const cell_y = simd.toIntArray(simd.floorToI4(simd.divFloat4(simd.loadFloat4(agents.y[row..]), cell_size_lanes)));
        inline for (0..simd.lane_count) |lane| {
            if (agents.entity[row + lane].isValid()) {
                out[count] = .{ .cell_x = cell_x[lane], .cell_y = cell_y[lane], .index = row + lane };
                count += 1;
            }
        }
    }
    while (row < end) : (row += 1) {
        if (!agents.entity[row].isValid()) continue;
        out[count] = .{ .cell_x = spatialCell(agents.x[row], cell_size), .cell_y = spatialCell(agents.y[row], cell_size), .index = row };
        count += 1;
    }
    return count;
}

fn spatialCellEntryLessThan(_: void, lhs: SpatialCellEntry, rhs: SpatialCellEntry) bool {
    if (lhs.cell_y != rhs.cell_y) return lhs.cell_y < rhs.cell_y;
    if (lhs.cell_x != rhs.cell_x) return lhs.cell_x < rhs.cell_x;
    return lhs.index < rhs.index;
}

// A band holds one range per occupied cell, so the equal key is the cell's range.
pub fn findCellRange(ranges: []const SpatialCellRange, cell_x: i32, cell_y: i32) ?SpatialCellRange {
    const index = std.sort.binarySearch(SpatialCellRange, ranges, CellKey{ .cell_y = cell_y, .cell_x = cell_x }, cellRangeOrder) orelse return null;
    return ranges[index];
}

fn cellRangeOrder(cell: CellKey, range: SpatialCellRange) std.math.Order {
    return cellKeyOrder(cell, .{ .cell_y = range.cell_y, .cell_x = range.cell_x });
}

pub fn spatialCell(value: f32, cell_size: f32) i32 {
    return math.floorToI32(value / @max(cell_size, min_spatial_cell_size));
}

const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const setRowCount = @import("../../../app/thread_system.zig").setRowCount;
const EntityId = @import("../../data_system.zig").EntityId;
const ensureStepCapacity = @import("system.zig").ensureStepCapacity;
const AgentSnapshotRow = @import("system.zig").AgentSnapshotRow;

test "steering banded agent grid gives every cell the same entries as one band" {
    if (!runtime_perf_log.enabled) return error.SkipZigTest;
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = steering_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    const threaded = StageThreads{ .thread_system = &threads, .config = .{ .items_per_range = steering_range_alignment_items, .max_worker_threads = 3, .adaptive = false } };
    const inline_ranges = StageThreads{ .thread_system = &threads, .config = .{ .items_per_range = steering_range_alignment_items, .max_worker_threads = 0, .adaptive = false } };

    for (std.meta.tags(GridTestLayout)) |layout| {
        var system = SteeringSystem.init(std.testing.allocator);
        defer system.deinit();
        try fillGridTestSnapshot(&system, layout);
        var stats = SteeringStats{};
        buildAgentGrid(&system, inline_ranges, &stats);
        try std.testing.expectEqual(@as(usize, 0), system.agent_grid.splitter_count);
        var reference = try GridTestCells.capture(&system);
        defer reference.deinit();
        try std.testing.expectEqual(layout == .one_cell, reference.ranges.items.len == 1);

        // Both stages inline in their ranges on the main thread.
        const inline_selection = inline_ranges.stage(&system.grid_bucket_tuner).select(system.agent_snapshot_rows.len, steering_range_alignment_items);
        buildAgentGridBanded(&system, inline_ranges, inline_selection, chooseGridSplitters(system.agentSnapshotSliceConst(), system.spatial_cell_size), &stats);
        try std.testing.expect(stats.perf.grid_bucket_batch.ran_inline and stats.perf.grid_bucket_batch.range_count > 1);
        try std.testing.expect(stats.perf.grid_sort_batch.ran_inline);
        try std.testing.expectEqual(max_bands, stats.perf.grid_sort_batch.item_count);
        try expectGridMatches(&system, &reference);

        // A config that allows no worker builds the serial grid.
        stats = .{};
        buildAgentGrid(&system, inline_ranges, &stats);
        try std.testing.expectEqual(@as(usize, 0), system.agent_grid.splitter_count);
        try std.testing.expectEqual(@as(usize, 0), stats.perf.grid_sort_batch.item_count);
        try expectGridMatches(&system, &reference);

        // Explicit splitter sets over the same bucket ranges.
        const selection = threaded.stage(&system.grid_bucket_tuner).select(system.agent_snapshot_rows.len, steering_range_alignment_items);
        for (std.meta.tags(GridTestSplitters)) |set| {
            buildAgentGridBanded(&system, threaded, selection, gridTestSplitters(set, reference.ranges.items), &stats);
            try std.testing.expect(!stats.perf.grid_bucket_batch.ran_inline);
            try std.testing.expectEqual(max_bands, stats.perf.grid_sort_batch.item_count);
            try expectGridMatches(&system, &reference);
        }

        // The production splitters.
        buildAgentGrid(&system, threaded, &stats);
        try std.testing.expect(!stats.perf.grid_bucket_batch.ran_inline and !stats.perf.grid_sort_batch.ran_inline);
        try std.testing.expectEqual(max_bands, stats.perf.grid_sort_batch.item_count);
        try expectGridMatches(&system, &reference);
    }
}

test "steering agent grid splits a one-row corridor and a cluster with a far outlier across bands" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = steering_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    const threaded = StageThreads{ .thread_system = &threads, .config = .{ .items_per_range = steering_range_alignment_items, .max_worker_threads = 3, .adaptive = false } };

    for ([_]GridTestLayout{ .one_row, .cluster_outlier }) |layout| {
        var system = SteeringSystem.init(std.testing.allocator);
        defer system.deinit();
        try fillGridTestSnapshot(&system, layout);
        var stats = SteeringStats{};
        buildAgentGrid(&system, threaded, &stats);
        const entry_count = system.agent_cell_entries.items.len;
        try std.testing.expect(entry_count > 0);
        try std.testing.expect(largestBandEntries(&system) <= entry_count / 8);
    }
}

test "steering agent grid splits rows that alternate between two clusters across bands" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = steering_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    const threaded = StageThreads{ .thread_system = &threads, .config = .{ .items_per_range = steering_range_alignment_items, .max_worker_threads = 3, .adaptive = false } };

    // Row counts at and near power-of-two multiples of the sample count, with the clusters
    // alternating every row and every 16 rows.
    const cases = [_]struct { row_count: usize, period: usize }{
        .{ .row_count = 1024, .period = 2 },
        .{ .row_count = 1030, .period = 2 },
        .{ .row_count = 8192, .period = 32 },
    };
    for (cases) |case| {
        var system = SteeringSystem.init(std.testing.allocator);
        defer system.deinit();
        try fillAlternatingClustersSnapshot(&system, case.row_count, case.period);
        var stats = SteeringStats{};
        buildAgentGrid(&system, threaded, &stats);
        try std.testing.expectEqual(case.row_count, system.agent_cell_entries.items.len);
        try std.testing.expect(largestBandEntries(&system) <= case.row_count / 8);
    }
}

// Agent grid test layouts: every row in one cell row across about 200 cells; spread over
// many cell rows; at negative coordinates with a NaN y, a -inf x, a +inf y, and a -inf y;
// every row in one cell; and a 10x10-cell cluster with one row far outside it.
const GridTestLayout = enum { one_row, spread, negative, one_cell, cluster_outlier };
const grid_test_rows: usize = 1000;
// A row with a body (`fillGridTestSnapshot` drops every seventh from row 3).
const grid_test_outlier_row: usize = grid_test_rows - 1;

// A snapshot of `grid_test_rows` rows in `layout`, every seventh row without a body.
fn fillGridTestSnapshot(system: *SteeringSystem, layout: GridTestLayout) !void {
    try ensureStepCapacity(system, grid_test_rows, 0);
    setRowCount(AgentSnapshotRow, &system.agent_snapshot_rows, grid_test_rows);
    const rows = system.agent_snapshot_rows.slice();
    system.spatial_cell_size = 20;
    var prng = std.Random.DefaultPrng.init(0x6e1d_b4d5);
    const random = prng.random();
    for (rows.items(.entity), rows.items(.x), rows.items(.y), rows.items(.world_level), 0..) |*entity, *x, *y, *level, row| {
        entity.* = if (row % 7 == 3) EntityId.invalid else try EntityId.init(@intCast(row), 1);
        level.* = 0;
        switch (layout) {
            .one_row => {
                x.* = random.float(f32) * 4000;
                y.* = 3 + random.float(f32) * 6;
            },
            .spread => {
                x.* = random.float(f32) * 120;
                y.* = random.float(f32) * 640;
            },
            .negative => {
                x.* = random.float(f32) * 120 - 300;
                y.* = -20 - random.float(f32) * 640;
                if (row == 500) y.* = std.math.nan(f32);
                if (row == 501) x.* = -std.math.inf(f32);
                if (row == 502) y.* = std.math.inf(f32);
                if (row == 503) y.* = -std.math.inf(f32);
            },
            .one_cell => {
                x.* = 1 + random.float(f32) * 18;
                y.* = 1 + random.float(f32) * 18;
            },
            .cluster_outlier => {
                x.* = random.float(f32) * 200;
                y.* = random.float(f32) * 200;
                if (row == grid_test_outlier_row) {
                    x.* = 1e6;
                    y.* = 1e6;
                }
            },
        }
    }
    std.debug.assert(rows.items(.entity)[grid_test_outlier_row].isValid());
}

// `row_count` rows with a body, alternating every `period / 2` rows between two far
// clusters; each cluster's rows fill its block of cells, 32 wide, in row order.
fn fillAlternatingClustersSnapshot(system: *SteeringSystem, row_count: usize, period: usize) !void {
    std.debug.assert(period >= 2 and period % 2 == 0);
    try ensureStepCapacity(system, row_count, 0);
    setRowCount(AgentSnapshotRow, &system.agent_snapshot_rows, row_count);
    const rows = system.agent_snapshot_rows.slice();
    system.spatial_cell_size = 20;
    const run = period / 2;
    for (rows.items(.entity), rows.items(.x), rows.items(.y), rows.items(.world_level), 0..) |*entity, *x, *y, *level, row| {
        entity.* = try EntityId.init(@intCast(row), 1);
        level.* = 0;
        const member = row / period * run + row % run;
        const cluster_y: f32 = if (row % period < run) 0 else 100_000;
        x.* = @floatFromInt(member % 32 * 20 + 10);
        y.* = cluster_y + @as(f32, @floatFromInt(member / 32 * 20 + 10));
    }
}

// The most entries any band of `system`'s grid holds.
fn largestBandEntries(system: *const SteeringSystem) usize {
    var largest: usize = 0;
    for (system.agent_grid.bands) |band| {
        var band_entries: usize = 0;
        for (system.agent_cell_ranges.items[band.start..][0..band.range_count]) |range| band_entries += range.end - range.start;
        largest = @max(largest, band_entries);
    }
    return largest;
}

// Explicit band splitter sets, each nondecreasing: all past every cell; all one occupied
// cell; occupied cells at a stride (63 distinct when the grid has as many); the i32 extremes
// around occupied cells; and occupied cells in equal pairs.
const GridTestSplitters = enum { all_max, one_cell, stride, extremes, pairs };

fn gridTestSplitters(set: GridTestSplitters, cells: []const SpatialCellRange) [max_bands - 1]CellKey {
    std.debug.assert(cells.len > 0);
    const min_key = CellKey{ .cell_y = std.math.minInt(i32), .cell_x = std.math.minInt(i32) };
    var splitters: [max_bands - 1]CellKey = @splat(max_cell_key);
    for (&splitters, 0..) |*splitter, index| {
        const pick: usize = switch (set) {
            .all_max => continue,
            .one_cell => cells.len / 2,
            .stride, .extremes => index * cells.len / (max_bands - 1),
            .pairs => (index / 2) * cells.len / (max_bands / 2),
        };
        splitter.* = .{ .cell_y = cells[pick].cell_y, .cell_x = cells[pick].cell_x };
        if (set == .extremes and index < 8) splitter.* = min_key;
        if (set == .extremes and index >= max_bands - 9) splitter.* = max_cell_key;
    }
    return splitters;
}

// A copy of a grid's entries and cell ranges.
const GridTestCells = struct {
    entries: std.ArrayList(SpatialCellEntry) = .empty,
    ranges: std.ArrayList(SpatialCellRange) = .empty,

    fn capture(system: *const SteeringSystem) !GridTestCells {
        var cells = GridTestCells{};
        errdefer cells.deinit();
        try cells.entries.appendSlice(std.testing.allocator, system.agent_cell_entries.items);
        try cells.ranges.appendSlice(std.testing.allocator, system.agent_cell_ranges.items);
        return cells;
    }

    fn deinit(self: *GridTestCells) void {
        self.ranges.deinit(std.testing.allocator);
        self.entries.deinit(std.testing.allocator);
    }
};

// `system`'s grid, looked up through its band directory, holds exactly the reference's cells,
// each with the same entries in the same order.
fn expectGridMatches(system: *const SteeringSystem, reference: *const GridTestCells) !void {
    const grid = &system.agent_grid;
    const band_count: usize = if (grid.splitter_count == 0) 1 else max_bands;
    var range_count: usize = 0;
    for (grid.bands[0..band_count]) |band| range_count += band.range_count;
    try std.testing.expectEqual(reference.ranges.items.len, range_count);
    try std.testing.expectEqualSlices(SpatialCellEntry, reference.entries.items, system.agent_cell_entries.items);
    for (reference.ranges.items) |cell| {
        const band_ranges = grid.rangesOfCell(system.agent_cell_ranges.items, cell.cell_x, cell.cell_y);
        const found = findCellRange(band_ranges, cell.cell_x, cell.cell_y) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(cell.start, found.start);
        try std.testing.expectEqual(cell.end, found.end);
    }
}
