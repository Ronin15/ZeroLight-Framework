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
//!
//! Populated-cell lookup: a row-major dense grid over a bounded,
//! camera-relative window (`DenseCellLookup`), direct-indexed rather than
//! hashed, so consecutive `cell.x` values at a fixed `cell.y` land on
//! consecutive flat indices. `queryNeighbors` exploits exactly that: it loads
//! 4 cells' `starts`/`ends` per batch with a plain contiguous
//! `simd.loadUint4` and tests occupancy with one `simd.equalUint4` compare
//! (see its doc comment). See `max_dense_window_side_cells`'s doc comment for
//! how the window is sized and the assumption it rests on.

const std = @import("std");
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const cognition_halo_chunks = @import("../simulation_scope.zig").cognition_halo_chunks;
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

/// Fixed cap on the camera-visible region's own span, in spatial-index cells,
/// added on top of the cognition-halo margin when sizing the dense window.
/// Camera zoom is hardcoded to 1.0 everywhere in today's production code
/// (`game_demo_state.zig`), so the visible region's cell span has no live,
/// reachable path to grow beyond this assumed worst case right now; see
/// `SpatialIndexSystem.reserve`'s doc comment for the margin math this
/// combines with, and `max_dense_window_side_cells`'s doc comment for the
/// caveat on how long that assumption holds.
pub const max_expected_visible_window_cells: u32 = 256;

/// Fixed capacity the dense window's side length is reserved to, independent
/// of any world config.
///
/// Camera zoom is hardcoded to 1.0 in today's production code, but zoom-out is
/// a planned future feature for this genre (top-down, multi-agent AI battles
/// with 2048+ NPCs) with no min-zoom value decided yet. Rather than size only
/// to today's literal zoom=1.0 state and have to redo this the moment zoom
/// ships, this ceiling is sized by extrapolating a reasonable future zoom
/// range for the genre (~0.2-0.25x is typical) combined with a generously
/// large display: at 0.2x zoom on a ~20000x8600px display, the visible window
/// alone reaches roughly 3125x1350 cells, and adding the ~512-cell halo margin
/// at this project's real defaults gives roughly 3637x1862 cells needed. 4096
/// covers that with real headroom (4096x4096 cells is ~134MB at 8 bytes/cell
/// entry — a trivial one-time reserve).
///
/// This is still a documented, revisit-when-decided assumption, not a
/// proven-forever bound: if/when camera zoom becomes an adjustable, designed
/// feature, this constant and the debug-assert-based invariant in
/// `buildEntriesAndRanges` must be revisited against that feature's actual
/// designed min-zoom value, not left as-is.
pub const max_dense_window_side_cells: u32 = 4096;

/// World-config inputs the dense window's halo-margin formula needs. Callers
/// (the pipeline) already hold these from the loaded WorldSystem; this struct
/// keeps spatial_index.zig decoupled from importing WorldSystem itself.
pub const DenseWindowGeometry = struct {
    cell_size: f32 = 32.0,
    chunk_size_tiles: u16 = 16,
    tile_size: f32 = 32.0,
};

/// Row-major dense grid over a bounded, camera-relative window, re-anchored
/// every build to that step's own populated-cell bounding box (not to
/// absolute world coordinates) so a fixed-size buffer represents any camera
/// position without growing. `starts`/`ends` are u32 (population/entries
/// counts are bounded well under u32 by movement_body_capacity; assert the
/// narrowing cast at write time). `start == end` at a slot means "not
/// populated" — buildEntriesAndRanges never emits an empty [start,end), so
/// this sentinel can't collide with a real range.
pub const DenseCellLookup = struct {
    starts: std.ArrayList(u32) = .empty,
    ends: std.ArrayList(u32) = .empty,
    // Flat indices written by the last build; cleared at the start of the
    // next build before that build's new writes land. Capacity == population
    // capacity (same bound as entries/ranges), so this never grows the
    // O(window) direction — clear cost tracks populated-cell count, not
    // window area. THIS is the mechanism that keeps per-step clear cost
    // bounded by population, not by window area — get this right, it's the
    // main way this design could quietly regress despite passing tests.
    touched: std.ArrayList(usize) = .empty,
    origin: SpatialCell = .{ .x = 0, .y = 0 },
    width: u32 = 0,
    height: u32 = 0,
    capacity_cells_x: u32 = 0,
    capacity_cells_y: u32 = 0,

    fn reserve(self: *DenseCellLookup, allocator: std.mem.Allocator, width: u32, height: u32, population_capacity: usize) !void {
        const total = @as(usize, width) * @as(usize, height);
        try self.starts.ensureTotalCapacity(allocator, total);
        try self.ends.ensureTotalCapacity(allocator, total);
        self.starts.appendNTimesAssumeCapacity(0, total);
        self.ends.appendNTimesAssumeCapacity(0, total);
        try self.touched.ensureTotalCapacity(allocator, population_capacity);
        self.capacity_cells_x = width;
        self.capacity_cells_y = height;
    }

    fn clearTouched(self: *DenseCellLookup) void {
        for (self.touched.items) |idx| {
            self.starts.items[idx] = 0;
            self.ends.items[idx] = 0;
        }
        self.touched.clearRetainingCapacity();
    }

    fn deinit(self: *DenseCellLookup, allocator: std.mem.Allocator) void {
        self.starts.deinit(allocator);
        self.ends.deinit(allocator);
        self.touched.deinit(allocator);
        self.* = undefined;
    }
};

/// Read-only per-step slice into DenseCellLookup, embedded in SpatialIndexView.
/// `queryNeighbors` is the sole reader; it indexes `starts`/`ends` directly
/// (batched 4-wide within a row) rather than through a per-cell lookup method,
/// since row-major layout makes consecutive `cell.x` values consecutive flat
/// indices — see `queryNeighbors`'s doc comment.
pub const DenseCellLookupView = struct {
    starts: []const u32,
    ends: []const u32,
    origin: SpatialCell,
    width: u32,
    height: u32,
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
    // O(1) direct-indexed populated-cell lookup, built alongside `ranges`
    // from the exact same data (see `SpatialIndexSystem.buildEntriesAndRanges`
    // and `DenseCellLookup`'s doc comment). `ranges` itself stays (existing
    // parity tests read it directly); this is a second, redundant index over
    // the same rows purely for query-time lookup.
    dense_lookup: DenseCellLookupView,
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
    ///
    /// Occupancy is checked 4 cells at a time within a row: the dense window's
    /// row-major layout means consecutive `cell_x` values at a fixed `cell_y`
    /// are consecutive flat indices into `dense_lookup.starts`/`ends`, so a
    /// plain contiguous `simd.loadUint4` (not a gather) loads 4 lanes at once
    /// and `simd.equalUint4` tests all 4 for "unpopulated" (`start == end`) in
    /// one compare. Each populated lane is then finished scalarly, in ascending
    /// lane order, with the exact same per-entry visiting logic used before
    /// vectorization — this changes only how occupancy is tested, never the
    /// order entries are visited (see the determinism note above). The row's
    /// x-span is first clipped to the dense window's bounds so the batch loop
    /// never reads outside `starts`/`ends`; the row itself is skipped up front
    /// when `cell_y` falls outside the window's y-span, exactly as
    /// `DenseCellLookupView.get` would reject every cell in it today. A row's
    /// clipped span not landing on a multiple of 4 finishes with a plain
    /// scalar per-cell tail.
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

        // Row-independent x clip: the scanned x-span never depends on cell_y,
        // so it is computed once against the dense window's bounds rather than
        // once per row.
        const window_min_x = self.dense_lookup.origin.x;
        const window_max_x = window_min_x + @as(i32, @intCast(self.dense_lookup.width)) - 1;
        const clipped_min_x = @max(own_cell.x - cell_scan_radius, window_min_x);
        const clipped_max_x = @min(own_cell.x + cell_scan_radius, window_max_x);
        if (clipped_min_x > clipped_max_x) return stats;
        const row_x_offset: usize = @intCast(clipped_min_x - window_min_x);
        const n_cells: usize = @intCast(clipped_max_x - clipped_min_x + 1);
        const vectorized_len = simd.vectorizedEnd(n_cells);

        var cell_y = own_cell.y - cell_scan_radius;
        while (cell_y <= own_cell.y + cell_scan_radius) : (cell_y += 1) {
            const rel_y = cell_y - self.dense_lookup.origin.y;
            if (rel_y < 0 or rel_y >= @as(i32, @intCast(self.dense_lookup.height))) continue;
            const row_base = @as(usize, @intCast(rel_y)) * self.dense_lookup.width + row_x_offset;

            var j: usize = 0;
            while (j < vectorized_len) : (j += simd.lane_count) {
                const idx = row_base + j;
                const starts_vec = simd.loadUint4(self.dense_lookup.starts[idx..]);
                const ends_vec = simd.loadUint4(self.dense_lookup.ends[idx..]);
                const unpopulated_mask = simd.equalUint4(starts_vec, ends_vec);
                inline for (0..simd.lane_count) |lane| {
                    if (!unpopulated_mask[lane]) {
                        if (self.visitEntryRange(
                            origin_x,
                            origin_y,
                            self_index,
                            radius2,
                            limits,
                            context,
                            visit_fn,
                            @intCast(starts_vec[lane]),
                            @intCast(ends_vec[lane]),
                            &stats,
                        )) return stats;
                    }
                }
            }
            while (j < n_cells) : (j += 1) {
                const idx = row_base + j;
                const start = self.dense_lookup.starts[idx];
                const end = self.dense_lookup.ends[idx];
                if (start == end) continue;
                if (self.visitEntryRange(
                    origin_x,
                    origin_y,
                    self_index,
                    radius2,
                    limits,
                    context,
                    visit_fn,
                    @intCast(start),
                    @intCast(end),
                    &stats,
                )) return stats;
            }
        }
        return stats;
    }

    /// Visits `entries[start..end]` in ascending stored order with the
    /// unvectorized per-entry logic (self-skip, candidate-check counting/cap,
    /// strict radius prefilter, `visit_fn`). Returns `true` when the whole scan
    /// must stop immediately (either the candidate-check cap was reached or
    /// `visit_fn` returned `.stop`), letting the caller unwind out of the
    /// vectorized-batch, row, and `cell_y` loops in one propagated signal.
    fn visitEntryRange(
        self: SpatialIndexView,
        origin_x: f32,
        origin_y: f32,
        self_index: ?usize,
        radius2: f32,
        limits: NeighborQueryLimits,
        context: *anyopaque,
        visit_fn: NeighborVisitFn,
        start: usize,
        end: usize,
        stats: *NeighborQueryStats,
    ) bool {
        for (self.entries[start..end]) |entry| {
            if (self_index) |self_i| {
                if (entry.index == self_i) continue;
            }
            if (stats.candidate_checks >= limits.max_candidate_checks) return true;
            stats.candidate_checks += 1;

            const dx = origin_x - self.pos_x[entry.index];
            const dy = origin_y - self.pos_y[entry.index];
            const dist2 = dx * dx + dy * dy;
            if (dist2 < radius2) {
                if (visit_fn(context, entry.index, dx, dy, dist2) == .stop) return true;
            }
        }
        return false;
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
    // O(1) query-time index over the same populated cells as `ranges` --
    // rebuilt alongside `ranges` every step, not a separate source of truth.
    // Sized in `reserve` from the halo/world geometry; see `DenseCellLookup`'s
    // doc comment.
    dense_lookup: DenseCellLookup = .{},
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
        self.dense_lookup.deinit(self.allocator);
        self.ranges.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.* = undefined;
    }

    /// Pre-sizes `rows`/`entries`/`ranges`/`dense_lookup` to `capacity`
    /// movement bodies (worst case: one entity per cell) so the per-step
    /// build is allocation-free after init. The threaded per-range gather
    /// slots still warm on their first threaded step, same as
    /// `SimulationScopeSystem.reserve`.
    ///
    /// `geometry` sizes the dense lookup window: the cognition-halo margin
    /// (`2 * cognition_halo_chunks * chunk_size_tiles * tile_size` world
    /// units, converted to cells by `cell_size`) plus a fixed assumed
    /// visible-region span (`max_expected_visible_window_cells`), clamped to
    /// `max_dense_window_side_cells`. At this project's real defaults
    /// (`cognition_halo_chunks` 16, `chunk_size_tiles` 16, `tile_size`/
    /// `cell_size` ~32) the margin alone is 512 cells — see
    /// `max_dense_window_side_cells`'s doc comment for the headroom this
    /// leaves and the assumption it rests on.
    pub fn reserve(self: *SpatialIndexSystem, capacity: usize, geometry: DenseWindowGeometry) !void {
        try self.rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(capacity));
        try self.entries.ensureTotalCapacity(self.allocator, capacity);
        try self.ranges.ensureTotalCapacity(self.allocator, capacity);

        const halo_world_units = 2.0 * @as(f32, @floatFromInt(cognition_halo_chunks)) *
            @as(f32, @floatFromInt(geometry.chunk_size_tiles)) * geometry.tile_size;
        const margin_cells: u32 = @intFromFloat(@ceil(halo_world_units / geometry.cell_size));
        const window_side = @min(margin_cells + max_expected_visible_window_cells, max_dense_window_side_cells);

        try self.dense_lookup.reserve(self.allocator, window_side, window_side, capacity);
    }

    /// Read-only snapshot of the most recently built index.
    pub fn view(self: *const SpatialIndexSystem) SpatialIndexView {
        const slice = self.rows.slice();
        return .{
            .pos_x = slice.items(.pos_x),
            .pos_y = slice.items(.pos_y),
            .entries = self.entries.items,
            .ranges = self.ranges.items,
            .dense_lookup = .{
                .starts = self.dense_lookup.starts.items,
                .ends = self.dense_lookup.ends.items,
                .origin = self.dense_lookup.origin,
                .width = self.dense_lookup.width,
                .height = self.dense_lookup.height,
            },
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
    /// order, then writes the populated ranges into `dense_lookup`, re-anchored
    /// to this step's own populated-cell bounding box. `entries`/`ranges` are
    /// reserved to `self.rows.len` up front (a no-op once `reserve` has already
    /// sized them, matching the reserve-then-ensureTotalCapacity
    /// belt-and-suspenders pattern the other processors use).
    ///
    /// The bounding box fitting inside `dense_lookup`'s reserved capacity is a
    /// program invariant, not a runtime-handled case — `reserve`'s sizing
    /// keeps this comfortably true for every world/camera configuration
    /// reachable in this codebase today (see `max_dense_window_side_cells`'s
    /// doc comment for the caveat on that assumption). If it is ever violated
    /// this asserts rather than silently degrading.
    fn buildEntriesAndRanges(self: *SpatialIndexSystem) !void {
        self.dense_lookup.clearTouched();
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
        if (n == 0) return;

        // min_y/max_y fall out of the cell-major sort (first/last entry); x
        // only sorts within a fixed y, so min_x/max_x need a scan.
        var min_x: i32 = self.entries.items[0].cell.x;
        var max_x: i32 = min_x;
        for (self.entries.items) |entry| {
            min_x = @min(min_x, entry.cell.x);
            max_x = @max(max_x, entry.cell.x);
        }
        const min_y = self.entries.items[0].cell.y;
        const max_y = self.entries.items[self.entries.items.len - 1].cell.y;
        const width: u32 = @intCast(max_x - min_x + 1);
        const height: u32 = @intCast(max_y - min_y + 1);

        std.debug.assert(width <= self.dense_lookup.capacity_cells_x);
        std.debug.assert(height <= self.dense_lookup.capacity_cells_y);

        self.dense_lookup.origin = .{ .x = min_x, .y = min_y };
        self.dense_lookup.width = width;
        self.dense_lookup.height = height;
        // Belt-and-suspenders growth, matching entries/ranges above: `touched`
        // is reserved once in `reserve()` to the configured movement-body
        // capacity (a no-op here in steady state), but a step whose
        // population exceeds that capacity (e.g. `reserve` was called with a
        // deliberately small capacity) still needs at most one touched slot
        // per distinct populated cell, which is bounded by `n`.
        try self.dense_lookup.touched.ensureTotalCapacity(self.allocator, n);

        var entry_index: usize = 0;
        while (entry_index < self.entries.items.len) {
            const cell = self.entries.items[entry_index].cell;
            const start = entry_index;
            while (entry_index < self.entries.items.len and cellsEqual(self.entries.items[entry_index].cell, cell)) {
                entry_index += 1;
            }
            const range = SpatialCellRange{ .cell = cell, .start = start, .end = entry_index };
            self.ranges.appendAssumeCapacity(range);

            std.debug.assert(range.start <= std.math.maxInt(u32) and range.end <= std.math.maxInt(u32));
            const rel_x: u32 = @intCast(cell.x - min_x);
            const rel_y: u32 = @intCast(cell.y - min_y);
            const idx = @as(usize, rel_y) * width + rel_x;
            self.dense_lookup.starts.items[idx] = @intCast(range.start);
            self.dense_lookup.ends.items[idx] = @intCast(range.end);
            self.dense_lookup.touched.appendAssumeCapacity(idx);
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

/// Builds a `SpatialIndexView` over caller-owned fixture data for
/// `queryNeighbors`'s scan/visit/stop-semantics tests, which construct
/// `entries`/`ranges` by hand rather than going through `buildEntriesAndRanges`.
/// `dense_starts`/`dense_ends` are caller-owned scratch sized to at least the
/// populated cells' bounding box; that box is computed here from `ranges` the
/// same way production code does, just without an allocator.
fn makeFixtureView(
    pos_x: []const f32,
    pos_y: []const f32,
    entries: []const SpatialEntry,
    ranges: []const SpatialCellRange,
    dense_starts: []u32,
    dense_ends: []u32,
    cell_size: f32,
) SpatialIndexView {
    var origin = SpatialCell{ .x = 0, .y = 0 };
    var width: u32 = 1;
    var height: u32 = 1;
    if (ranges.len > 0) {
        var min_x = ranges[0].cell.x;
        var max_x = min_x;
        var min_y = ranges[0].cell.y;
        var max_y = min_y;
        for (ranges) |range| {
            min_x = @min(min_x, range.cell.x);
            max_x = @max(max_x, range.cell.x);
            min_y = @min(min_y, range.cell.y);
            max_y = @max(max_y, range.cell.y);
        }
        origin = .{ .x = min_x, .y = min_y };
        width = @intCast(max_x - min_x + 1);
        height = @intCast(max_y - min_y + 1);
    }
    const cell_count = @as(usize, width) * @as(usize, height);
    @memset(dense_starts[0..cell_count], 0);
    @memset(dense_ends[0..cell_count], 0);
    for (ranges) |range| {
        const rel_x: u32 = @intCast(range.cell.x - origin.x);
        const rel_y: u32 = @intCast(range.cell.y - origin.y);
        const idx = @as(usize, rel_y) * width + rel_x;
        dense_starts[idx] = @intCast(range.start);
        dense_ends[idx] = @intCast(range.end);
    }
    return .{
        .pos_x = pos_x,
        .pos_y = pos_y,
        .entries = entries,
        .ranges = ranges,
        .dense_lookup = .{
            .starts = dense_starts[0..cell_count],
            .ends = dense_ends[0..cell_count],
            .origin = origin,
            .width = width,
            .height = height,
        },
        .cell_size = cell_size,
    };
}

const RecordingVisitor = struct {
    visited: [64]usize = undefined,
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
    var dense_starts: [1]u32 = undefined;
    var dense_ends: [1]u32 = undefined;
    const view = makeFixtureView(&pos_x, &pos_y, &entries, &ranges, &dense_starts, &dense_ends, 10.0);

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
    var dense_starts: [1]u32 = undefined;
    var dense_ends: [1]u32 = undefined;
    const view = makeFixtureView(&pos_x, &pos_y, &entries, &ranges, &dense_starts, &dense_ends, 10.0);

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
    var dense_starts: [1]u32 = undefined;
    var dense_ends: [1]u32 = undefined;
    const view = makeFixtureView(&pos_x, &pos_y, &entries, &ranges, &dense_starts, &dense_ends, 10.0);

    var visitor = RecordingVisitor{};
    _ = view.queryNeighbors(5, 0, null, 1, .{ .radius = 100.0, .max_candidate_checks = 128 }, &visitor, RecordingVisitor.record);

    try testing.expectEqualSlices(usize, &.{ 0, 1 }, visitor.visited[0..visitor.count]);
}

/// Builds a `SpatialIndexView` directly from an explicit dense window
/// (`origin`/`width`/`height`/`dense_starts`/`dense_ends`), for the
/// vectorized-batch tests below that need to place unpopulated gaps or
/// out-of-window scan bounds precisely rather than deriving the window from a
/// populated bounding box (as `makeFixtureView` does). `ranges` is left empty
/// since `queryNeighbors` only reads `entries` and `dense_lookup`.
fn makeDenseFixtureView(
    pos_x: []const f32,
    pos_y: []const f32,
    entries: []const SpatialEntry,
    dense_starts: []const u32,
    dense_ends: []const u32,
    origin: SpatialCell,
    width: u32,
    height: u32,
    cell_size: f32,
) SpatialIndexView {
    return .{
        .pos_x = pos_x,
        .pos_y = pos_y,
        .entries = entries,
        .ranges = &[_]SpatialCellRange{},
        .dense_lookup = .{
            .starts = dense_starts,
            .ends = dense_ends,
            .origin = origin,
            .width = width,
            .height = height,
        },
        .cell_size = cell_size,
    };
}

test "queryNeighbors vectorized batch visits mixed populated/unpopulated cells in ascending order across a row" {
    // cell_size 10, one row (cell_y=0) spanning cell_x 0..4 (5 cells, so the
    // 4-wide vectorized batch covers x=0..3 and the scalar tail covers x=4):
    // populated at x=0 (indices 0,1), x=2 (index 2), x=3 (indices 3,4); x=1
    // and x=4 are unpopulated gaps the batch/tail must skip without visiting.
    const pos_x = [_]f32{ 0, 0, 0, 0, 0 };
    const pos_y = [_]f32{ 0, 0, 0, 0, 0 };
    const entries = [_]SpatialEntry{
        .{ .cell = .{ .x = 0, .y = 0 }, .index = 0 },
        .{ .cell = .{ .x = 0, .y = 0 }, .index = 1 },
        .{ .cell = .{ .x = 2, .y = 0 }, .index = 2 },
        .{ .cell = .{ .x = 3, .y = 0 }, .index = 3 },
        .{ .cell = .{ .x = 3, .y = 0 }, .index = 4 },
    };
    const dense_starts = [_]u32{ 0, 0, 2, 3, 0 };
    const dense_ends = [_]u32{ 2, 0, 3, 5, 0 };
    const view = makeDenseFixtureView(&pos_x, &pos_y, &entries, &dense_starts, &dense_ends, .{ .x = 0, .y = 0 }, 5, 1, 10.0);

    var visitor = RecordingVisitor{};
    const stats = view.queryNeighbors(25, 5, null, 2, .{ .radius = 1000.0, .max_candidate_checks = 64 }, &visitor, RecordingVisitor.record);

    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4 }, visitor.visited[0..visitor.count]);
    try testing.expectEqual(@as(u16, 5), stats.candidate_checks);
}

test "queryNeighbors clips a scan radius extending past the dense window's edges without reading out of bounds" {
    // Dense window covers only cell_y=0, cell_x in {0,1}. own_cell resolves to
    // (0,0) and the scan radius (3) reaches x=-3..3 and y=-3..3, far past the
    // window on every side; only the in-window cells may contribute.
    const pos_x = [_]f32{ 0, 0, 0, 0 };
    const pos_y = [_]f32{ 0, 0, 0, 0 };
    const entries = [_]SpatialEntry{
        .{ .cell = .{ .x = 0, .y = 0 }, .index = 0 },
        .{ .cell = .{ .x = 0, .y = 0 }, .index = 1 },
        .{ .cell = .{ .x = 1, .y = 0 }, .index = 2 },
        .{ .cell = .{ .x = 1, .y = 0 }, .index = 3 },
    };
    const dense_starts = [_]u32{ 0, 2 };
    const dense_ends = [_]u32{ 2, 4 };
    const view = makeDenseFixtureView(&pos_x, &pos_y, &entries, &dense_starts, &dense_ends, .{ .x = 0, .y = 0 }, 2, 1, 10.0);

    var visitor = RecordingVisitor{};
    const stats = view.queryNeighbors(5, 5, null, 3, .{ .radius = 1000.0, .max_candidate_checks = 64 }, &visitor, RecordingVisitor.record);

    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, visitor.visited[0..visitor.count]);
    try testing.expectEqual(@as(u16, 4), stats.candidate_checks);
}

test "queryNeighbors scalar tail covers row spans that aren't a multiple of the lane count" {
    const row_lengths = .{ 1, 2, 3, 5, 6, 7 };
    inline for (row_lengths) |n| {
        var pos_x: [n]f32 = undefined;
        var pos_y: [n]f32 = undefined;
        var entries: [n]SpatialEntry = undefined;
        var dense_starts: [n]u32 = undefined;
        var dense_ends: [n]u32 = undefined;
        inline for (0..n) |i| {
            pos_x[i] = 0;
            pos_y[i] = 0;
            entries[i] = .{ .cell = .{ .x = i, .y = 0 }, .index = i };
            dense_starts[i] = i;
            dense_ends[i] = i + 1;
        }
        // own_cell resolves to (0,0); scan_radius == n guarantees the window
        // (width n) clips the scan down to exactly x in [0, n-1].
        const view = makeDenseFixtureView(&pos_x, &pos_y, &entries, &dense_starts, &dense_ends, .{ .x = 0, .y = 0 }, n, 1, 10.0);

        var visitor = RecordingVisitor{};
        const stats = view.queryNeighbors(5, 5, null, n, .{ .radius = 1000.0, .max_candidate_checks = 64 }, &visitor, RecordingVisitor.record);

        var expected: [n]usize = undefined;
        inline for (0..n) |i| expected[i] = i;
        try testing.expectEqualSlices(usize, &expected, visitor.visited[0..visitor.count]);
        try testing.expectEqual(@as(u16, n), stats.candidate_checks);
    }
}

const StoppingVisitor = struct {
    visited: [64]usize = undefined,
    count: usize = 0,
    stop_after: usize,

    fn record(context: *anyopaque, candidate_index: usize, _: f32, _: f32, _: f32) NeighborVisitResult {
        const self: *StoppingVisitor = @ptrCast(@alignCast(context));
        self.visited[self.count] = candidate_index;
        self.count += 1;
        return if (self.count >= self.stop_after) .stop else .keep_going;
    }
};

test "queryNeighbors propagates an early .stop out of a vectorized batch, its row, and the outer scan" {
    // Two-row window (cell_y 0 and 1), row 0 spanning x=0..4 like the batch
    // test above, row 1 also populated at x=0. stop_after=1 fires inside the
    // very first visited cell's range (x=0 has two entries), before the
    // vectorized batch even reaches x=2/x=3, before the scalar tail (x=4),
    // and before row 1 is ever scanned.
    const pos_x = [_]f32{ 0, 0, 0, 0, 0, 0 };
    const pos_y = [_]f32{ 0, 0, 0, 0, 0, 0 };
    const entries = [_]SpatialEntry{
        .{ .cell = .{ .x = 0, .y = 0 }, .index = 0 },
        .{ .cell = .{ .x = 0, .y = 0 }, .index = 1 },
        .{ .cell = .{ .x = 2, .y = 0 }, .index = 2 },
        .{ .cell = .{ .x = 3, .y = 0 }, .index = 3 },
        .{ .cell = .{ .x = 3, .y = 0 }, .index = 4 },
        .{ .cell = .{ .x = 0, .y = 1 }, .index = 5 },
    };
    const dense_starts = [_]u32{
        0, 0, 2, 3, 0, // row y=0: x=0..4
        5, 0, 0, 0, 0, // row y=1: x=0..4
    };
    const dense_ends = [_]u32{
        2, 0, 3, 5, 0,
        6, 0, 0, 0, 0,
    };
    const view = makeDenseFixtureView(&pos_x, &pos_y, &entries, &dense_starts, &dense_ends, .{ .x = 0, .y = 0 }, 5, 2, 10.0);

    var visitor = StoppingVisitor{ .stop_after = 1 };
    _ = view.queryNeighbors(5, 5, null, 4, .{ .radius = 1000.0, .max_candidate_checks = 64 }, &visitor, StoppingVisitor.record);

    try testing.expectEqualSlices(usize, &.{0}, visitor.visited[0..visitor.count]);
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
            try data.setAiAgent(entity, .{ .active_behavior = .wander });
        }
        return .{ .data = data };
    }

    fn deinit(self: *SpatialTestFixture) void {
        self.data.deinit();
    }
};

test "SpatialIndexSystem serial and threaded builds produce identical rows/entries/ranges/dense_lookup" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var fixture = try SpatialTestFixture.init(testing.allocator, 63);
    defer fixture.deinit();
    const ai_slice = fixture.data.aiAgentSliceConst();
    const move_slice = fixture.data.movementBodySliceConst();

    var serial_sys = SpatialIndexSystem.init(testing.allocator);
    defer serial_sys.deinit();
    try serial_sys.reserve(ai_slice.entities.len, .{});
    const serial_stats = try serial_sys.buildSerial(ai_slice, move_slice, &fixture.data, .{});

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 3, .items_per_range = 8 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var threaded_sys = SpatialIndexSystem.init(testing.allocator);
    defer threaded_sys.deinit();
    try threaded_sys.reserve(ai_slice.entities.len, .{});
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

    try testing.expectEqual(serial_sys.dense_lookup.origin, threaded_sys.dense_lookup.origin);
    try testing.expectEqual(serial_sys.dense_lookup.width, threaded_sys.dense_lookup.width);
    try testing.expectEqual(serial_sys.dense_lookup.height, threaded_sys.dense_lookup.height);
    for (serial_sys.ranges.items) |range| {
        const rel_x: u32 = @intCast(range.cell.x - serial_sys.dense_lookup.origin.x);
        const rel_y: u32 = @intCast(range.cell.y - serial_sys.dense_lookup.origin.y);
        const idx = @as(usize, rel_y) * serial_sys.dense_lookup.width + rel_x;
        try testing.expectEqual(serial_sys.dense_lookup.starts.items[idx], threaded_sys.dense_lookup.starts.items[idx]);
        try testing.expectEqual(serial_sys.dense_lookup.ends.items[idx], threaded_sys.dense_lookup.ends.items[idx]);
    }
}

test "assignCellsDense matches an independently computed scalar cellForPosition, including the non-multiple-of-4 scalar tail" {
    // 25 is not a multiple of simd.lane_count (4): this exercises the
    // vectorized block (24 rows) AND the scalar tail (1 row) in the same run.
    // cell_size 30 (non-power-of-2) so a reciprocal-multiply implementation of
    // the division would diverge from `divFloat4`'s true division and this
    // test would catch it; a power-of-2 size like the 32 default cannot.
    var fixture = try SpatialTestFixture.init(testing.allocator, 25);
    defer fixture.deinit();
    const ai_slice = fixture.data.aiAgentSliceConst();
    const move_slice = fixture.data.movementBodySliceConst();

    var sys = SpatialIndexSystem.init(testing.allocator);
    defer sys.deinit();
    try sys.reserve(ai_slice.entities.len, .{});
    const stats = try sys.buildSerial(ai_slice, move_slice, &fixture.data, .{ .cell_size = 30.0 });
    try testing.expectEqual(@as(usize, 25), stats.entity_count);

    const rows = sys.rows.slice();
    for (0..sys.rows.len) |i| {
        // Recomputed from the entity's own known input position (the same
        // formula SpatialTestFixture.init used to seed it), independent of
        // anything read back from the system, so this checks ground truth
        // rather than internal self-consistency.
        const entity_index = rows.items(.entity)[i].index;
        const expected_x = @as(f32, @floatFromInt(entity_index % 23)) * 7.0 - 40.0;
        const expected_y = @as(f32, @floatFromInt(entity_index / 23)) * 5.0 - 20.0;
        const expected_cell = cellForPosition(expected_x, expected_y, sys.cell_size);
        try testing.expectEqual(expected_cell, rows.items(.cell)[i]);
    }
}

test "SpatialIndexSystem builds correctly above a small reserved capacity" {
    var fixture = try SpatialTestFixture.init(testing.allocator, 40);
    defer fixture.deinit();
    const ai_slice = fixture.data.aiAgentSliceConst();
    const move_slice = fixture.data.movementBodySliceConst();

    var sys = SpatialIndexSystem.init(testing.allocator);
    defer sys.deinit();
    try sys.reserve(4, .{});

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
    try sys.reserve(8, .{});

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
    try sys.reserve(24, .{});

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

    var visitor = RecordingVisitor{};
    _ = sys.view().queryNeighbors(0, 0, null, 4, .{ .radius = 1000.0, .max_candidate_checks = 16 }, &visitor, RecordingVisitor.record);
}

test "queryNeighbors on the dense lookup finds exactly the entities within radius" {
    var fixture = try SpatialTestFixture.init(testing.allocator, 30);
    defer fixture.deinit();
    const ai_slice = fixture.data.aiAgentSliceConst();
    const move_slice = fixture.data.movementBodySliceConst();

    var sys = SpatialIndexSystem.init(testing.allocator);
    defer sys.deinit();
    try sys.reserve(30, .{});
    const stats = try sys.buildSerial(ai_slice, move_slice, &fixture.data, .{});
    try testing.expectEqual(@as(usize, 30), stats.entity_count);

    const view = sys.view();
    const query_radius = 64.0;
    const scan_radius = cellScanRadius(query_radius, sys.cell_size);
    for (0..view.pos_x.len) |origin_i| {
        var visitor = RecordingVisitor{};
        _ = view.queryNeighbors(
            view.pos_x[origin_i],
            view.pos_y[origin_i],
            origin_i,
            scan_radius,
            .{ .radius = query_radius, .max_candidate_checks = 64 },
            &visitor,
            RecordingVisitor.record,
        );

        // Brute-force expected set: every other row strictly within radius,
        // independent of the dense lookup under test.
        var expected: [64]usize = undefined;
        var expected_count: usize = 0;
        for (0..view.pos_x.len) |j| {
            if (j == origin_i) continue;
            const dx = view.pos_x[origin_i] - view.pos_x[j];
            const dy = view.pos_y[origin_i] - view.pos_y[j];
            if (dx * dx + dy * dy < query_radius * query_radius) {
                expected[expected_count] = j;
                expected_count += 1;
            }
        }

        std.mem.sort(usize, expected[0..expected_count], {}, std.sort.asc(usize));
        var visited_sorted = visitor.visited;
        std.mem.sort(usize, visited_sorted[0..visitor.count], {}, std.sort.asc(usize));
        try testing.expectEqualSlices(usize, expected[0..expected_count], visited_sorted[0..visitor.count]);
    }
}

test "reserve sizes the dense window from cognition halo margin plus fixed visible-window slack" {
    var sys = SpatialIndexSystem.init(testing.allocator);
    defer sys.deinit();
    // halo_world_units = 2 * cognition_halo_chunks(16) * 8 tiles * 4.0 px = 1024;
    // margin_cells = ceil(1024 / 8.0) = 128.
    try sys.reserve(4, .{ .cell_size = 8.0, .chunk_size_tiles = 8, .tile_size = 4.0 });
    const expected_margin_cells: u32 = 128;
    try testing.expectEqual(expected_margin_cells + max_expected_visible_window_cells, sys.dense_lookup.capacity_cells_x);
    try testing.expectEqual(sys.dense_lookup.capacity_cells_x, sys.dense_lookup.capacity_cells_y);
}

test "reserve clamps the dense window to the hard ceiling for a pathological world geometry" {
    var sys = SpatialIndexSystem.init(testing.allocator);
    defer sys.deinit();
    try sys.reserve(4, .{ .cell_size = 1.0, .chunk_size_tiles = 60000, .tile_size = 500.0 });
    try testing.expectEqual(max_dense_window_side_cells, sys.dense_lookup.capacity_cells_x);
    try testing.expectEqual(max_dense_window_side_cells, sys.dense_lookup.capacity_cells_y);
}
