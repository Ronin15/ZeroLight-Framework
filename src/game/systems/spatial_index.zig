// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Pipeline-owned shared spatial index (Slice 28). Builds one uniform grid per
//! fixed step from the cognition-scoped population and exposes a bounded,
//! radius-parameterized neighbor-query API. Replaces the private per-step grid
//! `AiSystem` used to build for separation and is the substrate future
//! perception queries (Slice 29) reuse instead of building a second grid.
//! Collision broadphase is intentionally NOT ported onto this index: it runs a
//! tuned sweep-and-prune order (`systems/collision.zig`) that is a different,
//! already-tuned algorithm, not a duplicate grid build.
//!
//! Scope: indexes only the cognition-scoped population passed via
//! `SpatialIndexConfig.scope_dense_indices` (halo + stagger gated), not every
//! movement body — every current and planned consumer already gates on that
//! same set, so indexing the full population would spend build cost on
//! entities nothing queries this step. A future consumer that needs a broader
//! candidate pool is the intentional widening point, not an oversight.
//!
//! Population-domain contract (also documented in `ai.zig`): `build`/`buildSerial`
//! walk `scope_dense_indices` (or all ai agents) resolving
//! `data.movementBodyDenseIndex(entity) orelse continue`, exactly mirroring
//! `AiSystem.gatherAiData`'s selection. This is a deliberate duplicate gather
//! (not shared code): it keeps both systems' call shapes independent while
//! guaranteeing row-index equivalence by construction — index row `i` and
//! `AiSystem.rows` row `i` refer to the same agent, so query results plug
//! straight into AI's arrays with zero translation.
//!
//! Determinism-critical: floating-point neighbor-direction summation is not
//! associative, so callers that need bit-exact parity with a per-cell scan
//! depend on `queryNeighbors` visiting candidates in exactly cell_y-outer,
//! cell_x-inner, ascending-stored-index-within-cell order. This falls out of
//! `entries` being sorted with a cell-major (y then x), index-minor comparator
//! and ranges walked in that same cell order — do not silently change the scan
//! order (e.g. to x-outer) without re-checking every consumer's parity tests.
//!
//! Build shape: the per-entity gather (`spatialGatherJob`/`buildSerial`'s loop)
//! is a scattered, branchy dense-index lookup with a real skip, so it stays
//! scalar — the same shape as `AiSystem.gatherAiData` and the scope system's AI
//! gather job. Cell assignment is deliberately deferred to a separate dense
//! pass (`assignCellsDense`) over the merged, contiguous `rows` columns, run 4
//! rows at a time through `simd.floorToI4` with a scalar tail: gather into
//! packed SoA scratch, then vectorize the dense math, per
//! `docs/coding-standards.md`'s SIMD section.

const std = @import("std");
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const AdaptiveWorkProfile = @import("../../app/thread_system.zig").AdaptiveWorkProfile;
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const alignItemCount = @import("../../app/thread_system.zig").alignItemCount;
const rangeCount = @import("../../app/thread_system.zig").rangeCount;
const ConstAiAgentSlice = @import("../data_system.zig").ConstAiAgentSlice;
const ConstMovementBodySlice = @import("../data_system.zig").ConstMovementBodySlice;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const movement_range_alignment_items = @import("../data_system.zig").movement_range_alignment_items;

pub const spatial_index_range_alignment_items: usize = movement_range_alignment_items;

const thread_shared_record_alignment: usize = 64;

pub const SpatialCell = struct {
    x: i32,
    y: i32,
};

pub const SpatialEntry = struct {
    cell: SpatialCell,
    index: usize,
};

pub const SpatialCellRange = struct {
    cell: SpatialCell,
    start: usize,
    end: usize,
};

pub const SpatialIndexConfig = struct {
    /// World-unit size of one grid cell. Callers that share a population (AI
    /// today) must agree on this with their query's `cellScanRadius` call.
    cell_size: f32 = 32.0,
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    /// When non-null, only these dense ai-store indices participate this step
    /// (mirrors `AiConfig.scope_dense_indices`). Null = all ai agents.
    scope_dense_indices: ?[]const u32 = null,
};

pub const NeighborQueryLimits = struct {
    radius: f32,
    max_candidate_checks: u16,
};

pub const NeighborVisitResult = enum { keep_going, stop };

pub const NeighborQueryStats = struct {
    candidate_checks: u16 = 0,
};

pub const NeighborVisitFn = *const fn (context: *anyopaque, candidate_index: usize, dx: f32, dy: f32, dist2: f32) NeighborVisitResult;

pub const SpatialIndexStats = struct {
    entity_count: usize = 0,
    batch: BatchStats = .{},
};

/// Converts a world-space query radius into an integer cell-scan radius for a
/// given cell size (ceil-based, so a radius that spans partway into the next
/// cell still scans it). Shared by every consumer of this index so scan radius
/// is computed identically instead of each caller hand-rolling it. Built from
/// `math.floorToI32` (`ceil(x) == -floor(-x)`) rather than a raw float-to-int
/// cast, so it inherits that helper's NaN/inf/out-of-range saturation.
pub fn cellScanRadius(query_radius: f32, cell_size: f32) i32 {
    return -math.floorToI32(-(query_radius / cell_size));
}

/// Immutable snapshot of one step's built index. Workers and query callers
/// read this; nothing here is mutated after `SpatialIndexSystem.build*` returns.
pub const SpatialIndexView = struct {
    pos_x: []const f32,
    pos_y: []const f32,
    entries: []const SpatialEntry,
    ranges: []const SpatialCellRange,
    cell_size: f32,

    /// Scans the `cell_scan_radius` block of cells around `(origin_x, origin_y)`
    /// in cell_y-outer, cell_x-inner order, visiting entries within each found
    /// cell in ascending stored order (see the module doc's determinism note).
    /// `self_index`, when set, is skipped without counting as a candidate.
    /// `candidate_checks` increments before the radius test on every other
    /// scanned entry and the scan stops once it reaches
    /// `limits.max_candidate_checks` (checked before increment, so the entry
    /// that would tip the count over is never processed). The radius prefilter
    /// is strict `<` — an entry exactly at `limits.radius` is excluded and
    /// never reaches `visit_fn`. `visit_fn` receives `origin - candidate` for
    /// `dx`/`dy` and the already-computed `dist2`; returning `.stop` ends the
    /// whole scan immediately (not just the current cell).
    pub fn queryNeighbors(
        self: SpatialIndexView,
        origin_x: f32,
        origin_y: f32,
        self_index: ?usize,
        cell_scan_radius: i32,
        limits: NeighborQueryLimits,
        context: *anyopaque,
        visit_fn: NeighborVisitFn,
    ) NeighborQueryStats {
        const own_cell = cellForPosition(origin_x, origin_y, self.cell_size);
        var stats = NeighborQueryStats{};
        const radius2 = limits.radius * limits.radius;
        var cell_y = own_cell.y - cell_scan_radius;
        while (cell_y <= own_cell.y + cell_scan_radius) : (cell_y += 1) {
            var cell_x = own_cell.x - cell_scan_radius;
            while (cell_x <= own_cell.x + cell_scan_radius) : (cell_x += 1) {
                const range = findCellRange(self.ranges, .{ .x = cell_x, .y = cell_y }) orelse continue;
                for (self.entries[range.start..range.end]) |entry| {
                    if (self_index) |self_i| {
                        if (entry.index == self_i) continue;
                    }
                    if (stats.candidate_checks >= limits.max_candidate_checks) return stats;
                    stats.candidate_checks += 1;

                    const dx = origin_x - self.pos_x[entry.index];
                    const dy = origin_y - self.pos_y[entry.index];
                    const dist2 = dx * dx + dy * dy;
                    if (dist2 < radius2) {
                        if (visit_fn(context, entry.index, dx, dy, dist2) == .stop) return stats;
                    }
                }
            }
        }
        return stats;
    }
};

const SpatialIndexRow = struct {
    entity: EntityId,
    pos_x: f32,
    pos_y: f32,
    cell: SpatialCell,
};

fn appendSpatialRow(
    rows: *std.MultiArrayList(SpatialIndexRow),
    row_slice: *std.MultiArrayList(SpatialIndexRow).Slice,
    row: SpatialIndexRow,
) void {
    _ = rows.addOneAssumeCapacity();
    row_slice.len = rows.len;
    row_slice.set(rows.len - 1, row);
}

fn hotStoreCapacity(min_len: usize) usize {
    return alignItemCount(min_len, spatial_index_range_alignment_items);
}

pub const SpatialIndexSystem = struct {
    allocator: std.mem.Allocator,
    // Gathered work memory (main-thread only; workers write only their own
    // reserved range slot). Population order: row `i` is the `i`-th surviving
    // agent walked from `scope_dense_indices` (or all ai agents).
    rows: std.MultiArrayList(SpatialIndexRow) = .{},
    entries: std.ArrayList(SpatialEntry) = .empty,
    ranges: std.ArrayList(SpatialCellRange) = .empty,
    gather_ranges: RowRangeSlotList = .empty,
    build_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    cell_size: f32 = 32.0,

    pub fn init(allocator: std.mem.Allocator) SpatialIndexSystem {
        return .{
            .allocator = allocator,
            .build_tuner = AdaptiveWorkTuner.init(.{}),
        };
    }

    pub fn deinit(self: *SpatialIndexSystem) void {
        for (self.gather_ranges.items) |*slot| slot.buffer.deinit(self.allocator);
        self.gather_ranges.deinit(self.allocator);
        self.ranges.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.* = undefined;
    }

    /// Pre-sizes `rows`/`entries`/`ranges` to `capacity` movement bodies (worst
    /// case: one entity per cell) so the per-step build is allocation-free
    /// after init. The threaded per-range gather slots still warm on their
    /// first threaded step, same as `SimulationScopeSystem.reserve`.
    pub fn reserve(self: *SpatialIndexSystem, capacity: usize) !void {
        try self.rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(capacity));
        try self.entries.ensureTotalCapacity(self.allocator, capacity);
        try self.ranges.ensureTotalCapacity(self.allocator, capacity);
    }

    /// Read-only snapshot of the most recently built index.
    pub fn view(self: *const SpatialIndexSystem) SpatialIndexView {
        const slice = self.rows.slice();
        return .{
            .pos_x = slice.items(.pos_x),
            .pos_y = slice.items(.pos_y),
            .entries = self.entries.items,
            .ranges = self.ranges.items,
            .cell_size = self.cell_size,
        };
    }

    /// Threaded build: gathers the scoped population into `rows` (per-range
    /// compaction, merged in range order so threaded and serial output are
    /// byte-identical), then sorts `entries` and derives `ranges` serially.
    pub fn build(
        self: *SpatialIndexSystem,
        ai_agents: ConstAiAgentSlice,
        movement: ConstMovementBodySlice,
        data: *const DataSystem,
        thread_system: *ThreadSystem,
        config: SpatialIndexConfig,
    ) !SpatialIndexStats {
        self.clearWork();
        self.cell_size = config.cell_size;
        const n = if (config.scope_dense_indices) |idx| idx.len else ai_agents.entities.len;
        if (n == 0) return .{};

        const owned_tuner = if (config.adaptive and config.items_per_range == null) &self.build_tuner else null;
        const selection = selectStageWork(thread_system, n, config.items_per_range, config.max_worker_threads, config.adaptive, owned_tuner);
        try prepareRowRangeBuffers(self.allocator, &self.gather_ranges, n, selection.items_per_range, selection.range_count);
        var context = SpatialGatherContext{
            .ai_entities = ai_agents.entities,
            .movement = movement,
            .data = data,
            .scope_dense_indices = config.scope_dense_indices,
            .ranges = self.gather_ranges.items[0..selection.range_count],
        };
        const batch = thread_system.parallelForWithOptions(n, &context, spatialGatherJob, .{
            .max_worker_threads = selection.worker_threads,
            .range_alignment_items = spatial_index_range_alignment_items,
            .adaptive_tuner = selection.active_tuner,
            .selected_profile = selection.profile,
        });
        try self.mergeRowRanges(self.gather_ranges.items[0..selection.range_count]);

        const gathered = self.rows.len;
        if (gathered == 0) return .{ .entity_count = 0, .batch = batch };
        self.assignCellsDense();
        try self.buildEntriesAndRanges();
        return .{ .entity_count = gathered, .batch = batch };
    }

    /// Serial build: same population selection and cell-major/index-minor
    /// sort as `build`, single pass, no thread system. Drives the serial
    /// bench/test path and the threaded==serial parity checks.
    pub fn buildSerial(
        self: *SpatialIndexSystem,
        ai_agents: ConstAiAgentSlice,
        movement: ConstMovementBodySlice,
        data: *const DataSystem,
        config: SpatialIndexConfig,
    ) !SpatialIndexStats {
        self.clearWork();
        self.cell_size = config.cell_size;
        const n = if (config.scope_dense_indices) |idx| idx.len else ai_agents.entities.len;
        if (n == 0) return .{};

        try self.rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(n));
        var row_slice = self.rows.slice();
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const i: usize = if (config.scope_dense_indices) |idx| idx[k] else k;
            const ent = ai_agents.entities[i];
            const mi = data.movementBodyDenseIndex(ent) orelse continue;
            // Cell is assigned afterward by a dense SIMD pass over the gathered
            // rows (see `assignCellsDense`) — this branchy, scattered-lookup
            // walk only resolves entity + position.
            appendSpatialRow(&self.rows, &row_slice, .{
                .entity = ent,
                .pos_x = movement.previous_x[mi],
                .pos_y = movement.previous_y[mi],
                .cell = .{ .x = 0, .y = 0 },
            });
        }

        const gathered = self.rows.len;
        if (gathered == 0) return .{};
        self.assignCellsDense();
        try self.buildEntriesAndRanges();
        return .{ .entity_count = gathered, .batch = serialBatch(gathered) };
    }

    fn clearWork(self: *SpatialIndexSystem) void {
        self.rows.clearRetainingCapacity();
        self.entries.clearRetainingCapacity();
        self.ranges.clearRetainingCapacity();
    }

    fn mergeRowRanges(self: *SpatialIndexSystem, slots: []RowRangeSlot) !void {
        self.rows.clearRetainingCapacity();
        var total: usize = 0;
        for (slots) |*slot| total += slot.buffer.rows.items.len;
        try self.rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(total));
        var row_slice = self.rows.slice();
        for (slots) |*slot| {
            for (slot.buffer.rows.items) |record| {
                appendSpatialRow(&self.rows, &row_slice, record);
            }
        }
    }

    /// Derives every row's `SpatialCell` from its already-gathered, contiguous
    /// `pos_x`/`pos_y` columns: dense, uniform, branch-light float math over an
    /// SoA column, so it runs 4 rows at a time through `simd.floorToI4` with a
    /// scalar tail, per `docs/coding-standards.md`'s SIMD section. Called after
    /// the scattered/branchy gather (`spatialGatherJob`/`buildSerial`'s loop)
    /// has finished — both leave `.cell` as a placeholder for this pass to fill.
    /// Uses `simd.divFloat4` (true division), not a precomputed reciprocal
    /// multiply, so results are bit-identical to the scalar `cellForPosition`.
    fn assignCellsDense(self: *SpatialIndexSystem) void {
        const slice = self.rows.slice();
        const pos_x = slice.items(.pos_x);
        const pos_y = slice.items(.pos_y);
        const cells = slice.items(.cell);
        const n = cells.len;
        const cell_size_vec = simd.splatFloat4(self.cell_size);
        var i: usize = 0;
        const vend = simd.vectorizedEnd(n);
        while (i < vend) : (i += simd.lane_count) {
            const px = simd.loadFloat4(pos_x[i..]);
            const py = simd.loadFloat4(pos_y[i..]);
            const cx = simd.toIntArray(simd.floorToI4(simd.divFloat4(px, cell_size_vec)));
            const cy = simd.toIntArray(simd.floorToI4(simd.divFloat4(py, cell_size_vec)));
            inline for (0..simd.lane_count) |lane| {
                cells[i + lane] = .{ .x = cx[lane], .y = cy[lane] };
            }
        }
        while (i < n) : (i += 1) {
            cells[i] = cellForPosition(pos_x[i], pos_y[i], self.cell_size);
        }
    }

    /// Builds `entries` (one per row) and derives `ranges` from the sorted
    /// order. `entries`/`ranges` are reserved to `self.rows.len` up front (a
    /// no-op once `reserve` has already sized them, matching the reserve-then-
    /// ensureTotalCapacity belt-and-suspenders pattern the other processors use).
    fn buildEntriesAndRanges(self: *SpatialIndexSystem) !void {
        const n = self.rows.len;
        const cells = self.rows.items(.cell);
        try self.entries.ensureTotalCapacity(self.allocator, n);
        self.entries.clearRetainingCapacity();
        for (0..n) |i| {
            self.entries.appendAssumeCapacity(.{ .cell = cells[i], .index = i });
        }
        std.mem.sort(SpatialEntry, self.entries.items, {}, entryLessThan);

        try self.ranges.ensureTotalCapacity(self.allocator, n);
        self.ranges.clearRetainingCapacity();
        var entry_index: usize = 0;
        while (entry_index < self.entries.items.len) {
            const cell = self.entries.items[entry_index].cell;
            const start = entry_index;
            while (entry_index < self.entries.items.len and cellsEqual(self.entries.items[entry_index].cell, cell)) {
                entry_index += 1;
            }
            self.ranges.appendAssumeCapacity(.{ .cell = cell, .start = start, .end = entry_index });
        }
    }
};

// ---- Cell math ---------------------------------------------------------------

fn cellForPosition(x: f32, y: f32, cell_size: f32) SpatialCell {
    return .{
        .x = math.floorToI32(x / cell_size),
        .y = math.floorToI32(y / cell_size),
    };
}

fn cellsEqual(lhs: SpatialCell, rhs: SpatialCell) bool {
    return lhs.x == rhs.x and lhs.y == rhs.y;
}

/// Cell-major total order: y then x. Ties broken by `entryLessThan`'s index
/// term. Determinism-critical — see the module doc comment.
fn cellLessThan(lhs: SpatialCell, rhs: SpatialCell) bool {
    if (lhs.y != rhs.y) return lhs.y < rhs.y;
    return lhs.x < rhs.x;
}

fn entryLessThan(_: void, lhs: SpatialEntry, rhs: SpatialEntry) bool {
    if (!cellsEqual(lhs.cell, rhs.cell)) return cellLessThan(lhs.cell, rhs.cell);
    return lhs.index < rhs.index;
}

fn findCellRange(ranges: []const SpatialCellRange, cell: SpatialCell) ?SpatialCellRange {
    var low: usize = 0;
    var high: usize = ranges.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const mid_cell = ranges[mid].cell;
        if (cellsEqual(mid_cell, cell)) return ranges[mid];
        if (cellLessThan(mid_cell, cell)) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return null;
}

// ---- Threaded gather ----------------------------------------------------------

const RowRangeBuffer = struct {
    rows: std.ArrayList(SpatialIndexRow) = .empty,

    fn reset(self: *RowRangeBuffer) void {
        self.rows.clearRetainingCapacity();
    }

    fn deinit(self: *RowRangeBuffer, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.* = undefined;
    }
};

const RowRangeSlot = struct {
    // Padding keeps hot append state off shared cache lines across concurrently
    // written range records.
    buffer: RowRangeBuffer = .{},
    padding: [paddingForCacheLine(RowRangeBuffer)]u8 = [_]u8{0} ** paddingForCacheLine(RowRangeBuffer),
};

const RowRangeSlotList = std.ArrayListAligned(RowRangeSlot, .fromByteUnits(thread_shared_record_alignment));

fn prepareRowRangeBuffers(
    allocator: std.mem.Allocator,
    ranges: *RowRangeSlotList,
    item_count: usize,
    items_per_range: usize,
    range_count: usize,
) !void {
    try ranges.ensureTotalCapacity(allocator, range_count);
    while (ranges.items.len < range_count) ranges.appendAssumeCapacity(.{});
    for (ranges.items[0..range_count], 0..) |*slot, range_index| {
        slot.buffer.reset();
        // Max one emitted row per scanned candidate → reserve the range length
        // exactly, so the job only appends (no overflow, no replay).
        try slot.buffer.rows.ensureTotalCapacity(allocator, rangeLenForIndex(item_count, items_per_range, range_index));
    }
}

const SpatialGatherContext = struct {
    ai_entities: []const EntityId,
    movement: ConstMovementBodySlice,
    data: *const DataSystem,
    scope_dense_indices: ?[]const u32,
    ranges: []RowRangeSlot,
};

/// Scattered/branchy per-entity resolution: `movementBodyDenseIndex` is a
/// dense-index lookup with a real skip (some scoped agents lack a movement
/// body), so this stays scalar — the same shape as `AiSystem.gatherAiData`'s
/// gather and `SimulationScopeSystem`'s AI gather job. Cell assignment is
/// deliberately not done here; it runs afterward as one dense SIMD pass over
/// the merged, contiguous `rows` columns (`assignCellsDense`), which is the
/// "gather into packed SoA scratch, then vectorize the dense math" shape
/// `docs/coding-standards.md`'s SIMD section calls for.
fn spatialGatherJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *SpatialGatherContext = @ptrCast(@alignCast(context));
    // Guards the reserve-before-dispatch invariant: ranges was sized to this dispatch's range count.
    std.debug.assert(range.index < job.ranges.len);
    const buffer = &job.ranges[range.index].buffer;
    for (range.start..range.end) |k| {
        const i: usize = if (job.scope_dense_indices) |idx| idx[k] else k;
        const ent = job.ai_entities[i];
        const mi = job.data.movementBodyDenseIndex(ent) orelse continue;
        buffer.rows.appendAssumeCapacity(.{
            .entity = ent,
            .pos_x = job.movement.previous_x[mi],
            .pos_y = job.movement.previous_y[mi],
            .cell = .{ .x = 0, .y = 0 },
        });
    }
}

// ---- Work selection (mirrors ai.zig/simulation_scope.zig's selectStageWork) ---

const StageWorkSelection = struct {
    profile: AdaptiveWorkProfile,
    items_per_range: usize,
    worker_threads: usize,
    range_count: usize,
    active_tuner: ?*AdaptiveWorkTuner = null,
};

fn selectStageWork(
    thread_system: *const ThreadSystem,
    item_count: usize,
    items_per_range_override: ?usize,
    max_worker_threads_override: ?usize,
    adaptive: bool,
    adaptive_tuner: ?*AdaptiveWorkTuner,
) StageWorkSelection {
    const available_workers = thread_system.workerThreadCount();
    const max_worker_threads = @min(max_worker_threads_override orelse available_workers, available_workers);
    const requested_items_per_range = items_per_range_override orelse thread_system.config.items_per_range;
    const active_tuner = if (adaptive and items_per_range_override == null and max_worker_threads > 0)
        adaptive_tuner
    else
        null;
    const profile = if (active_tuner) |tuner|
        tuner.selectProfile(.{
            .item_count = item_count,
            .available_worker_threads = available_workers,
            .max_worker_threads = max_worker_threads,
            .fallback_items_per_range = requested_items_per_range,
            .range_alignment_items = spatial_index_range_alignment_items,
        })
    else
        AdaptiveWorkProfile{
            .worker_threads = max_worker_threads,
            .items_per_range = requested_items_per_range,
        };
    const aligned_items_per_range = alignItemCount(@max(profile.items_per_range, @as(usize, 1)), spatial_index_range_alignment_items);
    const selected_range_count = rangeCount(item_count, aligned_items_per_range);
    const selected_worker_threads = if (selected_range_count <= 1)
        @as(usize, 0)
    else
        @min(profile.worker_threads, @min(max_worker_threads, selected_range_count - 1));
    const items_per_range = if (selected_worker_threads == 0 and active_tuner != null and profile.worker_threads == 0)
        item_count
    else
        aligned_items_per_range;

    return .{
        .profile = .{
            .worker_threads = selected_worker_threads,
            .items_per_range = items_per_range,
        },
        .items_per_range = items_per_range,
        .worker_threads = selected_worker_threads,
        .range_count = rangeCount(item_count, items_per_range),
        .active_tuner = active_tuner,
    };
}

fn paddingForCacheLine(comptime T: type) usize {
    const rem = @sizeOf(T) % thread_shared_record_alignment;
    return if (rem == 0) 0 else thread_shared_record_alignment - rem;
}

fn rangeLenForIndex(item_count: usize, items_per_range: usize, range_index: usize) usize {
    const start = range_index * items_per_range;
    if (start >= item_count) return 0;
    return @min(start + items_per_range, item_count) - start;
}

fn serialBatch(count: usize) BatchStats {
    return .{ .ran_inline = true, .item_count = count, .range_count = 1, .items_per_range = count };
}

// ---- Tests --------------------------------------------------------------------

const testing = std.testing;

fn makeFixtureView(
    pos_x: []const f32,
    pos_y: []const f32,
    entries: []const SpatialEntry,
    ranges: []const SpatialCellRange,
    cell_size: f32,
) SpatialIndexView {
    return .{ .pos_x = pos_x, .pos_y = pos_y, .entries = entries, .ranges = ranges, .cell_size = cell_size };
}

const RecordingVisitor = struct {
    visited: [16]usize = undefined,
    count: usize = 0,

    fn record(context: *anyopaque, candidate_index: usize, _: f32, _: f32, _: f32) NeighborVisitResult {
        const self: *RecordingVisitor = @ptrCast(@alignCast(context));
        self.visited[self.count] = candidate_index;
        self.count += 1;
        return .keep_going;
    }
};

test "cellScanRadius matches AI's fixed 48/32 constant" {
    try testing.expectEqual(@as(i32, 2), cellScanRadius(48.0, 32.0));
    try testing.expectEqual(@as(i32, 0), cellScanRadius(0.0, 32.0));
    try testing.expectEqual(@as(i32, 1), cellScanRadius(32.0, 32.0));
}

test "queryNeighbors visits candidates in ascending stored order, excludes self and strict-boundary radius" {
    // All five points fall in cell (0,0) at cell_size 10, so the whole scan is
    // one range and traversal order is exactly ascending stored index.
    const pos_x = [_]f32{ 0, 3, 5, 4.9, 1 };
    const pos_y = [_]f32{ 0, 0, 0, 0, 0 };
    const entries = [_]SpatialEntry{
        .{ .cell = .{ .x = 0, .y = 0 }, .index = 0 },
        .{ .cell = .{ .x = 0, .y = 0 }, .index = 1 },
        .{ .cell = .{ .x = 0, .y = 0 }, .index = 2 },
        .{ .cell = .{ .x = 0, .y = 0 }, .index = 3 },
        .{ .cell = .{ .x = 0, .y = 0 }, .index = 4 },
    };
    const ranges = [_]SpatialCellRange{.{ .cell = .{ .x = 0, .y = 0 }, .start = 0, .end = 5 }};
    const view = makeFixtureView(&pos_x, &pos_y, &entries, &ranges, 10.0);

    var visitor = RecordingVisitor{};
    const stats = view.queryNeighbors(0, 0, 0, 1, .{ .radius = 5.0, .max_candidate_checks = 128 }, &visitor, RecordingVisitor.record);

    // index 2 sits exactly at radius 5 (dist2 == 25) so the strict `<` prefilter
    // excludes it from `visit_fn` — but it is still a scanned non-self candidate,
    // so it counts toward `candidate_checks` (4 total: indices 1,2,3,4). Index 0
    // is self and is skipped before the count, and never visited even though
    // dist2 == 0.
    try testing.expectEqual(@as(usize, 3), visitor.count);
    try testing.expectEqualSlices(usize, &.{ 1, 3, 4 }, visitor.visited[0..visitor.count]);
    try testing.expectEqual(@as(u16, 4), stats.candidate_checks);
}

test "queryNeighbors stops at max_candidate_checks before processing the tipping candidate" {
    const pos_x = [_]f32{ 0, 1, 2, 3 };
    const pos_y = [_]f32{ 0, 0, 0, 0 };
    const entries = [_]SpatialEntry{
        .{ .cell = .{ .x = 0, .y = 0 }, .index = 0 },
        .{ .cell = .{ .x = 0, .y = 0 }, .index = 1 },
        .{ .cell = .{ .x = 0, .y = 0 }, .index = 2 },
        .{ .cell = .{ .x = 0, .y = 0 }, .index = 3 },
    };
    const ranges = [_]SpatialCellRange{.{ .cell = .{ .x = 0, .y = 0 }, .start = 0, .end = 4 }};
    const view = makeFixtureView(&pos_x, &pos_y, &entries, &ranges, 10.0);

    var visitor = RecordingVisitor{};
    const stats = view.queryNeighbors(0, 0, 0, 1, .{ .radius = 100.0, .max_candidate_checks = 1 }, &visitor, RecordingVisitor.record);

    try testing.expectEqual(@as(usize, 1), visitor.count);
    try testing.expectEqualSlices(usize, &.{1}, visitor.visited[0..visitor.count]);
    try testing.expectEqual(@as(u16, 1), stats.candidate_checks);
}

test "queryNeighbors with no self_index scans every entry including index 0" {
    const pos_x = [_]f32{ 0, 1 };
    const pos_y = [_]f32{ 0, 0 };
    const entries = [_]SpatialEntry{
        .{ .cell = .{ .x = 0, .y = 0 }, .index = 0 },
        .{ .cell = .{ .x = 0, .y = 0 }, .index = 1 },
    };
    const ranges = [_]SpatialCellRange{.{ .cell = .{ .x = 0, .y = 0 }, .start = 0, .end = 2 }};
    const view = makeFixtureView(&pos_x, &pos_y, &entries, &ranges, 10.0);

    var visitor = RecordingVisitor{};
    _ = view.queryNeighbors(5, 0, null, 1, .{ .radius = 100.0, .max_candidate_checks = 128 }, &visitor, RecordingVisitor.record);

    try testing.expectEqualSlices(usize, &.{ 0, 1 }, visitor.visited[0..visitor.count]);
}

const SpatialTestFixture = struct {
    data: DataSystem,

    fn init(allocator: std.mem.Allocator, count: usize) !SpatialTestFixture {
        var data = DataSystem.init(allocator);
        errdefer data.deinit();
        for (0..count) |i| {
            const entity = try data.createEntity();
            const position = math.Vec2{
                .x = @as(f32, @floatFromInt(i % 23)) * 7.0 - 40.0,
                .y = @as(f32, @floatFromInt(i / 23)) * 5.0 - 20.0,
            };
            try data.setMovementBody(entity, .{ .position = position, .previous_position = position, .velocity = .{}, .speed = 20 });
            try data.setAiAgent(entity, .{ .behavior = .wander });
        }
        return .{ .data = data };
    }

    fn deinit(self: *SpatialTestFixture) void {
        self.data.deinit();
    }
};

test "SpatialIndexSystem serial and threaded builds produce identical rows/entries/ranges" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var fixture = try SpatialTestFixture.init(testing.allocator, 63);
    defer fixture.deinit();
    const ai_slice = fixture.data.aiAgentSliceConst();
    const move_slice = fixture.data.movementBodySliceConst();

    var serial_sys = SpatialIndexSystem.init(testing.allocator);
    defer serial_sys.deinit();
    const serial_stats = try serial_sys.buildSerial(ai_slice, move_slice, &fixture.data, .{});

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 3, .items_per_range = 8 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var threaded_sys = SpatialIndexSystem.init(testing.allocator);
    defer threaded_sys.deinit();
    const threaded_stats = try threaded_sys.build(ai_slice, move_slice, &fixture.data, &threads, .{
        .items_per_range = 8,
        .max_worker_threads = 3,
        .adaptive = false,
    });

    try testing.expectEqual(serial_stats.entity_count, threaded_stats.entity_count);
    try testing.expectEqual(serial_sys.rows.len, threaded_sys.rows.len);
    const serial_rows = serial_sys.rows.slice();
    const threaded_rows = threaded_sys.rows.slice();
    for (0..serial_sys.rows.len) |i| {
        try testing.expectEqual(serial_rows.items(.entity)[i].index, threaded_rows.items(.entity)[i].index);
        try testing.expectEqual(serial_rows.items(.pos_x)[i], threaded_rows.items(.pos_x)[i]);
        try testing.expectEqual(serial_rows.items(.pos_y)[i], threaded_rows.items(.pos_y)[i]);
        try testing.expectEqual(serial_rows.items(.cell)[i], threaded_rows.items(.cell)[i]);
    }
    try testing.expectEqual(serial_sys.entries.items.len, threaded_sys.entries.items.len);
    for (serial_sys.entries.items, threaded_sys.entries.items) |a, b| {
        try testing.expectEqual(a.cell, b.cell);
        try testing.expectEqual(a.index, b.index);
    }
    try testing.expectEqual(serial_sys.ranges.items.len, threaded_sys.ranges.items.len);
    for (serial_sys.ranges.items, threaded_sys.ranges.items) |a, b| {
        try testing.expectEqual(a.cell, b.cell);
        try testing.expectEqual(a.start, b.start);
        try testing.expectEqual(a.end, b.end);
    }
}

test "SpatialIndexSystem builds correctly above a small reserved capacity" {
    var fixture = try SpatialTestFixture.init(testing.allocator, 40);
    defer fixture.deinit();
    const ai_slice = fixture.data.aiAgentSliceConst();
    const move_slice = fixture.data.movementBodySliceConst();

    var sys = SpatialIndexSystem.init(testing.allocator);
    defer sys.deinit();
    try sys.reserve(4);

    const stats = try sys.buildSerial(ai_slice, move_slice, &fixture.data, .{});
    try testing.expectEqual(@as(usize, 40), stats.entity_count);
    try testing.expectEqual(@as(usize, 40), sys.entries.items.len);
    try testing.expect(sys.ranges.items.len > 0);
}

test "SpatialIndexSystem empty population yields zero stats and touches nothing" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    var sys = SpatialIndexSystem.init(testing.allocator);
    defer sys.deinit();
    try sys.reserve(8);

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();
    const serial_stats = try sys.buildSerial(ai_slice, move_slice, &data, .{});
    try testing.expectEqual(@as(usize, 0), serial_stats.entity_count);
    try testing.expectEqual(@as(usize, 0), sys.rows.len);
    try testing.expectEqual(@as(usize, 0), sys.entries.items.len);

    if (!@import("builtin").single_threaded) {
        var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 1 });
        defer threads.deinit();
        const threaded_stats = try sys.build(ai_slice, move_slice, &data, &threads, .{});
        try testing.expectEqual(@as(usize, 0), threaded_stats.entity_count);
    }

    // Scoped to an explicit empty index list too (real per-step "nothing in
    // halo this step" case, distinct from "no ai agents exist at all").
    const empty_scope = &[_]u32{};
    const scoped_stats = try sys.buildSerial(ai_slice, move_slice, &data, .{ .scope_dense_indices = empty_scope });
    try testing.expectEqual(@as(usize, 0), scoped_stats.entity_count);
}

test "SpatialIndexSystem has no steady-state allocation after warmup (FailingAllocator)" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var fixture = try SpatialTestFixture.init(testing.allocator, 24);
    defer fixture.deinit();
    const ai_slice = fixture.data.aiAgentSliceConst();
    const move_slice = fixture.data.movementBodySliceConst();

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2, .items_per_range = 6 });
    defer threads.deinit();

    var sys = SpatialIndexSystem.init(testing.allocator);
    defer sys.deinit();
    try sys.reserve(24);

    // Warmup: one threaded build (warms `gather_ranges`) and one serial build.
    _ = try sys.build(ai_slice, move_slice, &fixture.data, &threads, .{ .items_per_range = 6, .max_worker_threads = 2, .adaptive = false });
    _ = try sys.buildSerial(ai_slice, move_slice, &fixture.data, .{});

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const original_allocator = sys.allocator;
    sys.allocator = failing.allocator();
    defer sys.allocator = original_allocator;

    const threaded_stats = try sys.build(ai_slice, move_slice, &fixture.data, &threads, .{ .items_per_range = 6, .max_worker_threads = 2, .adaptive = false });
    try testing.expectEqual(@as(usize, 24), threaded_stats.entity_count);
    const serial_stats = try sys.buildSerial(ai_slice, move_slice, &fixture.data, .{});
    try testing.expectEqual(@as(usize, 24), serial_stats.entity_count);
}
