// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! AI perception substrate (Slice 29): gathers the cognition-scoped subset of
//! AI agents that also carry an `AiPerception` component, queries the shared
//! `SpatialIndexSystem` (Slice 28) for nearby hostile candidates, applies a
//! squared-form field-of-view test and a bounded line-of-sight raycast, and
//! writes the winning `nearest_threat`/`target_visible`/`last_seen_x/y`/
//! `facing_x/y` hot columns back onto `DataSystem`'s `PerceptionStore`.
//! Emits `entity_perceived`/`entity_lost` `SimulationEvent`s on transitions,
//! range-owned during the parallel compute pass and merged deterministically
//! afterward — same gather -> parallel compute -> per-range emit -> merge
//! shape as `ai.zig`/`collision.zig`.
//!
//! Two-index-space contract (population-domain equivalence with
//! `spatial_index.zig`, mirrors `ai.zig`'s cross-file contract): this
//! system's own gather is a FILTERED SUBSET of the scoped population (only
//! entities that also carry `AiPerception`), so it cannot reuse its own row
//! index as `SpatialIndexView.queryNeighbors`'s self-exclusion index. Instead
//! it duplicates the same scoped walk `SpatialIndexSystem`/`AiSystem` use
//! (`scope_dense_indices` + `movementBodyDenseIndex(entity) orelse continue`,
//! identical skip, identical order) to build a `candidates` side table
//! (entity/faction/level) aligned 1:1 with `spatial`'s own row order, and
//! records each observer row's position in *that* full-population walk as
//! `spatial_self_index` — the value actually passed to `queryNeighbors`.
//! `perception_dense_index` is the unrelated, separate index: the entity's
//! own row in `PerceptionStore`, used only to write results back.
//! `std.debug.assert(self.candidates.len == spatial.pos_x.len)` is the
//! population-domain guard (Debug/ReleaseSafe only, mirrors `ai.zig`).
//!
//! Sign convention: `SpatialIndexView.queryNeighbors` hands its visitor
//! `dx/dy = origin - candidate`. This system negates that once, at the single
//! choke point inside `perceptionNeighborVisit`, into `to_x/to_y = candidate -
//! observer` ("vector toward the candidate") before buffering — every
//! downstream consumer (FOV dot product, LOS endpoint, last-seen position,
//! and the player-candidate merge, which is built the same way) reads that
//! one convention with no further sign flips.
//!
//! FOV test stays in squared form (no sqrt/normalize/divide): `facing_x/y` is
//! already unit-length (derived once per step by `computeFacingDense`, a
//! dense SIMD pass over the gathered rows' velocity columns — see its doc
//! comment), so `dot(facing, to) > 0 AND dot(facing, to)^2 > cos_half_fov^2 *
//! dist_squared` is equivalent to a true angle compare given `cos_half_fov >=
//! 0`, which `AiPerception`'s `fov_half_angle_radians <= pi/2` cap guarantees
//! (see `data_system/perception.zig`). A wider-than-90-degree cone (needing a
//! sign-split) is explicitly out of scope for this slice.
//!
//! Scalar exceptions (each documented again at its call site): the spatial
//! cell-scan traversal and stance lookup (Slice 28 shared infra; branchy and a
//! 4-value enum table index, not float math), the small (<= 17) per-agent
//! nearest-candidate sort (irreducibly small/branchy, does not scale with
//! population), and the bounded LOS raycast (early-exit, one scattered cell
//! lookup per sample). The per-sample blocked test itself is an O(1) read
//! into `LevelBlockedSlot`'s per-level bitmap cache (`level_blocked`, built by
//! `ensureLevelBlockedCachesForObservers`/`ensureLevelBlockedCache` at most
//! once per distinct observer level per step), not
//! `WorldSystem.levelBlocksMovement`'s own per-call linear scan over the
//! world's sparse tiles — see `LevelBlockedSlot`'s doc comment for why this is
//! a bespoke cache rather than a reuse of `pathfinding/nav_grid.zig`'s
//! `NavGrid`, and `src/benchmarks/perception.zig`'s `perception`/
//! `perception-los-dense` groups for the before/after cost proof.
//!
//! Threaded writes: each worker range writes only its own gather rows' hot
//! columns in `PerceptionStore` (disjoint per entity, since gather rows are
//! 1:1 with entities and ranges partition row indices) and appends events
//! only into its own reserved, exactly-sized event scratch buffer
//! (`range_len * 2` — an identity-swap transition emits at most two events per
//! row, so this can never overflow, unlike collision's broadphase estimate).
//! Serial and threaded paths share every vectorized helper
//! (`computeFacingDense`, `filterFovSurvivors`, the transition `equalInt4`
//! pass) and the same per-range compute function
//! (`computePerceptionRange`) — see the serial/threaded parity test.

const std = @import("std");
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const stance = @import("../faction.zig").stance;
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
const Faction = @import("../data_system.zig").Faction;
const PerceptionSlice = @import("../data_system.zig").PerceptionSlice;
const movement_range_alignment_items = @import("../data_system.zig").movement_range_alignment_items;
const WorldSystem = @import("../world_system.zig").WorldSystem;
const SimulationEvent = @import("../simulation.zig").SimulationEvent;
const SimulationEvents = @import("../simulation.zig").SimulationEvents;
const spatial_index_mod = @import("spatial_index.zig");
const SpatialIndexView = spatial_index_mod.SpatialIndexView;
const NeighborVisitResult = spatial_index_mod.NeighborVisitResult;

pub const perception_range_alignment_items: usize = movement_range_alignment_items;

fn hotStoreCapacity(min_len: usize) usize {
    return alignItemCount(min_len, perception_range_alignment_items);
}

// Mirrors ai.zig's max_separation_neighbors/max_separation_candidate_checks
// shape: a small fixed candidate buffer bounded by a scan-cost ceiling.
const max_perception_candidates: u8 = 16;
const max_perception_candidate_checks: u16 = 128;
const max_perception_scratch: usize = max_perception_candidates + 1; // + player

// "Moving" gate for facing derivation: 1.0 units/sec, compared against
// speed-squared so the dense pass never needs a sqrt to decide.
const facing_speed_squared_threshold: f32 = 1.0;
const facing_normalize_epsilon: f32 = 1.0e-6;

// Defensive ceiling on LOS raycast sample count. AiPerception.vision_range is
// itself capped (max_ai_perception_vision_range) which already keeps the
// normal ceil(distance / tile_size) step count small; this is a second,
// independent bound.
const los_max_steps: u32 = 32;

const player_candidate_sentinel: usize = std.math.maxInt(usize);

const default_max_events_per_step: usize = 512;

const invalid_index_bits: i32 = @bitCast(EntityId.invalid.index);
const invalid_generation_bits: i32 = @bitCast(EntityId.invalid.generation);

pub const PlayerPerceptionCandidate = struct {
    entity: EntityId,
    pos_x: f32,
    pos_y: f32,
    faction: Faction,
    level: u16,
};

pub const PerceptionConfig = struct {
    /// When non-null, only these dense ai-store indices participate this step
    /// (the scope system's cognition halo + stagger selection). Null = all
    /// agents. Mirrors `AiConfig.scope_dense_indices`/
    /// `SpatialIndexConfig.scope_dense_indices` exactly (population-domain
    /// contract — see the module doc).
    scope_dense_indices: ?[]const u32 = null,
    /// Optional player entity, resolved by the caller once per step (null if
    /// no player entity exists yet).
    player_candidate: ?PlayerPerceptionCandidate = null,
    /// Deterministic per-step cap on emitted perception events, enforced by
    /// this system itself (see the module doc's threaded-writes note and
    /// `mergePerceptionEvents`) rather than letting `SimulationEvents`'s own
    /// capacity check throw.
    max_events_per_step: usize = default_max_events_per_step,
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    adaptive_tuner: ?*AdaptiveWorkTuner = null,
};

pub const PerceptionStats = struct {
    observer_count: usize = 0,
    candidate_population_count: usize = 0,
    // FOV-surviving hostile candidates summed across every observer this step
    // (post range/FOV gate, pre-LOS) — a selectivity signal for how much the
    // spatial-index + FOV filter narrows the candidate population before the
    // LOS raycast has to run at all.
    sensed_count: usize = 0,
    // Observers whose `target_visible` resolved true this step (LOS actually
    // confirmed a nearest threat), summed across every range.
    nearest_threat_found_count: usize = 0,
    // `hasLineOfSight` call count and how many of those returned blocked,
    // summed across every range — see the per-range accumulation note on
    // `PerceptionRangeStats`. `hasLineOfSight` samples are O(1) lookups into
    // `PerceptionSystem.level_blocked`'s per-level bitmap cache (see that
    // struct's doc comment), not raw `WorldSystem.levelBlocksMovement` calls,
    // so these counters exist to make the LOS sample volume visible to
    // `src/benchmarks/perception.zig` rather than let it hide inside aggregate
    // step timing.
    los_checks: usize = 0,
    los_blocked: usize = 0,
    perceived_events: usize = 0,
    lost_events: usize = 0,
    dropped_events: usize = 0,
    batch: BatchStats = .{},
};

// Per-range accumulator for the LOS/sensed/found counters above. Each range
// job owns one slot (indexed by `range.index`, mirrors `event_ranges`), writes
// to a local `PerceptionRangeStats` value throughout its own
// `computeOneAgent` calls, and stores it once at the end of
// `computePerceptionRange` — a single write per range, so no atomics or
// padding are needed (unlike the event scratch buffers, nothing appends
// concurrently into a range's slot).
const PerceptionRangeStats = struct {
    sensed_count: usize = 0,
    nearest_threat_found: usize = 0,
    los_checks: usize = 0,
    los_blocked: usize = 0,
};

const CandidateRow = struct {
    entity: EntityId,
    faction: Faction,
    level: u16,
};

fn appendCandidateRow(
    rows: *std.MultiArrayList(CandidateRow),
    row_slice: *std.MultiArrayList(CandidateRow).Slice,
    row: CandidateRow,
) void {
    _ = rows.addOneAssumeCapacity();
    row_slice.len = rows.len;
    row_slice.set(rows.len - 1, row);
}

const PerceptionGatherRow = struct {
    entity: EntityId,
    pos_x: f32,
    pos_y: f32,
    velocity_x: f32,
    velocity_y: f32,
    vision_range: f32,
    cos_half_fov: f32,
    faction: Faction,
    level: u16,
    // Row index in the FULL scoped population walk (same order as
    // SpatialIndexSystem/AiSystem's own gather) — passed to
    // `queryNeighbors` as `self_index`. See the module doc's
    // two-index-space contract.
    spatial_self_index: usize,
    // This entity's own row in `PerceptionStore` — used only to write
    // results back, unrelated to `spatial_self_index`.
    perception_dense_index: usize,
    facing_x: f32,
    facing_y: f32,
    prev_nearest_threat_index: i32,
    prev_nearest_threat_generation: i32,
    final_nearest_threat_index: i32,
    final_nearest_threat_generation: i32,
};

fn appendPerceptionGatherRow(
    rows: *std.MultiArrayList(PerceptionGatherRow),
    row_slice: *std.MultiArrayList(PerceptionGatherRow).Slice,
    row: PerceptionGatherRow,
) void {
    _ = rows.addOneAssumeCapacity();
    row_slice.len = rows.len;
    row_slice.set(rows.len - 1, row);
}

const ConstCandidateSlice = struct {
    entities: []const EntityId,
    faction: []const Faction,
    level: []const u16,
};

const thread_shared_record_alignment: usize = 64;

const PerceptionEventRangeBuffer = struct {
    events: std.ArrayList(SimulationEvent) = .empty,

    fn clearRetainingCapacity(self: *PerceptionEventRangeBuffer) void {
        self.events.clearRetainingCapacity();
    }

    fn appendAssumeCapacity(self: *PerceptionEventRangeBuffer, event: SimulationEvent) void {
        self.events.appendAssumeCapacity(event);
    }

    fn deinit(self: *PerceptionEventRangeBuffer, allocator: std.mem.Allocator) void {
        self.events.deinit(allocator);
        self.* = undefined;
    }
};

const PerceptionEventRangeSlot = struct {
    // Each worker writes only its assigned slot. Padding keeps hot append
    // state off shared cache lines across concurrently written range records.
    buffer: PerceptionEventRangeBuffer = .{},
    padding: [paddingForCacheLine(PerceptionEventRangeBuffer)]u8 = [_]u8{0} ** paddingForCacheLine(PerceptionEventRangeBuffer),
};

const PerceptionEventRangeSlotList = std.ArrayListAligned(PerceptionEventRangeSlot, .fromByteUnits(thread_shared_record_alignment));

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
    return .{ .ran_inline = true, .item_count = count, .range_count = if (count > 0) 1 else 0, .items_per_range = count };
}

// Sentinel meaning "never built" so a fresh slot (default-initialized, step 0
// never having run yet) always misses the `built_step == step_counter` check
// below and gets populated the first time its level is touched.
const invalid_build_step: u64 = std.math.maxInt(u64);

// One level's O(1) LOS-blocked lookup cache: a raw world-tile-granularity
// bitmap (`blocked[y * width + x]`), rebuilt at most once per distinct level
// per step (see `PerceptionSystem.ensureLevelBlockedCache`). This exists
// solely to answer `hasLineOfSight`'s per-sample question in O(1) instead of
// `WorldSystem.levelBlocksMovement`'s per-call linear scan over every sparse
// tile in the world (see the module doc's LOS-cost note and
// `src/benchmarks/perception.zig`'s `perception`/`perception-los-dense` split
// that proved the cost). Deliberately NOT a reuse of
// `pathfinding/nav_grid.zig`'s `NavGrid`: that grid's blocked mask is world
// obstacles OR (level 0 only) DataSystem static collision bodies — a
// different, broader set than `levelBlocksMovement`'s world-tiles-only
// contract — and its `cell_size` is only incidentally equal to
// `WorldSystem.tile_size` (two independently-set literals, not an enforced
// invariant), so reusing it would risk both a silent LOS-granularity change
// and a silent LOS-occlusion behavior change. This cache instead mirrors
// `NavGrid.markWorldObstacles`'s shape (dense-band scan + sparse-filtered-to-
// level pass) but stays at raw world-tile granularity with no rect
// rasterization, so it is a direct, provable stand-in for
// `levelBlocksMovement` — see the parity test.
const LevelBlockedSlot = struct {
    // `invalid_build_step` until the first build; thereafter the
    // `PerceptionSystem.step_counter` value as of the last (re)build. A step
    // counter mismatch (a new step ran since) triggers a rebuild before the
    // slot is read again.
    built_step: u64 = invalid_build_step,
    // False for a level index that did not exist in `WorldSystem` at build
    // time (`level_index >= world.levelCount()`), matching
    // `levelBlocksMovement`'s fail-closed contract for an invalid level:
    // `lookupLevelBlocked` returns blocked immediately without ever reading
    // `blocked`.
    valid: bool = false,
    width: u16 = 0,
    height: u16 = 0,
    blocked: std.ArrayList(bool) = .empty,

    fn deinit(self: *LevelBlockedSlot, allocator: std.mem.Allocator) void {
        self.blocked.deinit(allocator);
        self.* = undefined;
    }
};

// O(1) lookup mirroring `WorldSystem.levelBlocksMovement`'s exact external
// contract: an out-of-range level index or out-of-bounds x/y is fail-closed
// (blocked); everything else is the cached bit. `level_blocked` is a
// `PerceptionSystem.level_blocked` snapshot (main-thread-built, worker-read
// only) indexed directly by level.
fn lookupLevelBlocked(level_blocked: []const LevelBlockedSlot, level: u16, x: u16, y: u16) bool {
    if (@as(usize, level) >= level_blocked.len) return true;
    const slot = &level_blocked[level];
    if (!slot.valid) return true;
    if (x >= slot.width or y >= slot.height) return true;
    return slot.blocked.items[@as(usize, y) * @as(usize, slot.width) + @as(usize, x)];
}

pub const PerceptionSystem = struct {
    allocator: std.mem.Allocator,
    // Gathered work memory (main-thread only; workers read only copies in
    // job context, except their own reserved event scratch range).
    candidates: std.MultiArrayList(CandidateRow) = .{},
    rows: std.MultiArrayList(PerceptionGatherRow) = .{},
    event_ranges: PerceptionEventRangeSlotList = .empty,
    range_stats: std.ArrayList(PerceptionRangeStats) = .empty,
    range_take_counts: std.ArrayList(usize) = .empty,
    compute_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    // Per-level LOS-blocked bitmap cache, indexed directly by level (see
    // `LevelBlockedSlot`). Sized/reused across steps (never deinit between
    // steps) — only the per-level `blocked` bitmap contents are refreshed,
    // at most once per distinct level actually touched by an observer this
    // step, via `ensureLevelBlockedCache`.
    level_blocked: std.ArrayList(LevelBlockedSlot) = .empty,
    // Monotonic step marker: incremented once per `update`/`updateSerial`
    // call. A level's cached bitmap is reused for every LOS sample within the
    // same step and rebuilt lazily the first time that level is touched in a
    // later step.
    step_counter: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) PerceptionSystem {
        return .{
            .allocator = allocator,
            .compute_tuner = AdaptiveWorkTuner.init(.{}),
        };
    }

    pub fn deinit(self: *PerceptionSystem) void {
        for (self.level_blocked.items) |*slot| slot.deinit(self.allocator);
        self.level_blocked.deinit(self.allocator);
        self.range_take_counts.deinit(self.allocator);
        self.range_stats.deinit(self.allocator);
        for (self.event_ranges.items) |*slot| slot.buffer.deinit(self.allocator);
        self.event_ranges.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.candidates.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn update(
        self: *PerceptionSystem,
        ai_agents: ConstAiAgentSlice,
        movement: ConstMovementBodySlice,
        spatial: SpatialIndexView,
        world: *const WorldSystem,
        data: *DataSystem,
        events: *SimulationEvents,
        thread_system: *ThreadSystem,
        config: PerceptionConfig,
    ) !PerceptionStats {
        const perception_slice = data.perceptionSlice();
        try self.gatherPerceptionData(ai_agents, movement, data, perception_slice, config.scope_dense_indices);
        const observer_count = self.rows.len;
        if (observer_count == 0) return .{ .candidate_population_count = self.candidates.len };

        // Population-domain contract with spatial_index.zig (see module doc):
        // the shared index built for this step must have gathered the
        // identical row count as this system's own full-population candidate
        // walk. Debug/ReleaseSafe-only guard, compiles out in ReleaseFast.
        std.debug.assert(self.candidates.len == spatial.pos_x.len);

        self.computeFacingDense(perception_slice);
        try self.ensureLevelBlockedCachesForObservers(world);

        const active_tuner: ?*AdaptiveWorkTuner = config.adaptive_tuner orelse
            if (config.adaptive and config.items_per_range == null) &self.compute_tuner else null;
        const selection = selectStageWork(
            thread_system,
            observer_count,
            config.items_per_range,
            config.max_worker_threads,
            config.adaptive,
            active_tuner,
        );
        try self.prepareEventRangeBuffers(selection.range_count, selection.items_per_range, observer_count);
        try self.prepareRangeStats(selection.range_count);

        var job = self.buildJobContext(perception_slice, spatial, world, config.player_candidate, selection.range_count);
        const batch = thread_system.parallelForWithOptions(observer_count, &job, writePerceptionRangeJob, .{
            .max_worker_threads = selection.worker_threads,
            .range_alignment_items = perception_range_alignment_items,
            .adaptive_tuner = selection.active_tuner,
            .selected_profile = selection.profile,
        });

        const merge = try self.mergePerceptionEvents(events, selection.range_count, config.max_events_per_step);
        const totals = self.sumRangeStats(selection.range_count);
        return .{
            .observer_count = observer_count,
            .candidate_population_count = self.candidates.len,
            .sensed_count = totals.sensed_count,
            .nearest_threat_found_count = totals.nearest_threat_found,
            .los_checks = totals.los_checks,
            .los_blocked = totals.los_blocked,
            .perceived_events = merge.perceived,
            .lost_events = merge.lost,
            .dropped_events = merge.dropped,
            .batch = batch,
        };
    }

    pub fn updateSerial(
        self: *PerceptionSystem,
        ai_agents: ConstAiAgentSlice,
        movement: ConstMovementBodySlice,
        spatial: SpatialIndexView,
        world: *const WorldSystem,
        data: *DataSystem,
        events: *SimulationEvents,
        config: PerceptionConfig,
    ) !PerceptionStats {
        const perception_slice = data.perceptionSlice();
        try self.gatherPerceptionData(ai_agents, movement, data, perception_slice, config.scope_dense_indices);
        const observer_count = self.rows.len;
        if (observer_count == 0) return .{ .candidate_population_count = self.candidates.len };

        std.debug.assert(self.candidates.len == spatial.pos_x.len);

        self.computeFacingDense(perception_slice);
        try self.ensureLevelBlockedCachesForObservers(world);

        const range_count: usize = 1;
        try self.prepareEventRangeBuffers(range_count, observer_count, observer_count);
        try self.prepareRangeStats(range_count);

        var job = self.buildJobContext(perception_slice, spatial, world, config.player_candidate, range_count);
        computePerceptionRange(&job, .{ .index = 0, .start = 0, .end = observer_count });

        const merge = try self.mergePerceptionEvents(events, range_count, config.max_events_per_step);
        const totals = self.sumRangeStats(range_count);
        return .{
            .observer_count = observer_count,
            .candidate_population_count = self.candidates.len,
            .sensed_count = totals.sensed_count,
            .nearest_threat_found_count = totals.nearest_threat_found,
            .los_checks = totals.los_checks,
            .los_blocked = totals.los_blocked,
            .perceived_events = merge.perceived,
            .lost_events = merge.lost,
            .dropped_events = merge.dropped,
            .batch = serialBatch(observer_count),
        };
    }

    fn buildJobContext(
        self: *PerceptionSystem,
        perception_slice: PerceptionSlice,
        spatial: SpatialIndexView,
        world: *const WorldSystem,
        player_candidate: ?PlayerPerceptionCandidate,
        range_count: usize,
    ) PerceptionJobContext {
        const candidate_slice = self.candidates.slice();
        const rows = self.rows.slice();
        return .{
            .entities = rows.items(.entity),
            .pos_x = rows.items(.pos_x),
            .pos_y = rows.items(.pos_y),
            .vision_range = rows.items(.vision_range),
            .cos_half_fov = rows.items(.cos_half_fov),
            .faction = rows.items(.faction),
            .level = rows.items(.level),
            .spatial_self_index = rows.items(.spatial_self_index),
            .perception_dense_index = rows.items(.perception_dense_index),
            .facing_x = rows.items(.facing_x),
            .facing_y = rows.items(.facing_y),
            .prev_nearest_threat_index = rows.items(.prev_nearest_threat_index),
            .prev_nearest_threat_generation = rows.items(.prev_nearest_threat_generation),
            .final_nearest_threat_index = rows.items(.final_nearest_threat_index),
            .final_nearest_threat_generation = rows.items(.final_nearest_threat_generation),
            .candidates = .{
                .entities = candidate_slice.items(.entity),
                .faction = candidate_slice.items(.faction),
                .level = candidate_slice.items(.level),
            },
            .perception_slice = perception_slice,
            .spatial = spatial,
            .world = world,
            .level_blocked = self.level_blocked.items,
            .player_candidate = player_candidate,
            .event_ranges = self.event_ranges.items[0..range_count],
            .range_stats = self.range_stats.items[0..range_count],
        };
    }

    // Builds (or, if already current for this step, reuses) every distinct
    // observer level's `LevelBlockedSlot` bitmap, once, on the main thread,
    // before any range job is dispatched — workers only ever read the
    // completed `level_blocked` snapshot handed to them via
    // `PerceptionJobContext`. Walking every gathered row's level (rather than
    // building a separate deduped level list) needs no extra allocation:
    // `ensureLevelBlockedCache` itself is an O(1) no-op for a level already
    // current this step, so revisiting the same level across many rows costs
    // nothing beyond the index read.
    fn ensureLevelBlockedCachesForObservers(self: *PerceptionSystem, world: *const WorldSystem) !void {
        self.step_counter +%= 1;
        const levels = self.rows.items(.level);
        for (levels) |level| try self.ensureLevelBlockedCache(world, level);
    }

    // Rebuilds one level's LOS-blocked bitmap from `world`'s dense bands and
    // sparse obstacles, mirroring `nav_grid.zig`'s `markWorldObstacles` shape
    // (uniform-fill fast path, then a per-dense-layer cell scan, then a
    // sparse-tile pass scoped to this level via `sparseTileIndicesForLevel` —
    // O(sparse tiles on this level), not O(sparse tiles in the whole world))
    // but at raw world-tile granularity — no nav-cell rect rasterization — so
    // the result is a direct, provable stand-in for
    // `WorldSystem.levelBlocksMovement` (see `LevelBlockedSlot`'s doc comment
    // and the parity test). A no-op when the slot is already built for the
    // current `step_counter`. `blocked`'s backing storage is grown once and
    // reused across steps (never deinit/re-init between steps); only its
    // contents are refreshed.
    fn ensureLevelBlockedCache(self: *PerceptionSystem, world: *const WorldSystem, level: u16) !void {
        if (@as(usize, level) >= self.level_blocked.items.len) {
            const new_len = @as(usize, level) + 1;
            try self.level_blocked.ensureTotalCapacity(self.allocator, new_len);
            while (self.level_blocked.items.len < new_len) self.level_blocked.appendAssumeCapacity(.{});
        }
        const slot = &self.level_blocked.items[level];
        if (slot.built_step == self.step_counter) return;

        const cell_count = @as(usize, world.width) * @as(usize, world.height);
        try slot.blocked.ensureTotalCapacity(self.allocator, cell_count);
        slot.blocked.items.len = cell_count;
        slot.width = world.width;
        slot.height = world.height;
        @memset(slot.blocked.items, false);

        // Fail-closed contract for an invalid level index (mirrors
        // levelBlocksMovement's own first check): leave the bitmap all-false
        // but mark the slot invalid, so `lookupLevelBlocked` returns blocked
        // without ever reading `blocked`'s (unpopulated) contents.
        slot.valid = @as(usize, level) < world.levelCount();
        if (!slot.valid) {
            slot.built_step = self.step_counter;
            return;
        }

        for (0..world.denseLayerCount()) |layer_index| {
            if (world.denseLayerLevel(layer_index) != level) continue;
            if (world.denseLayerUniformFillTile(layer_index) != null) {
                if (world.denseTileBlocksMovement(layer_index, 0, 0)) @memset(slot.blocked.items, true);
                continue;
            }
            for (0..world.height) |y_usize| {
                const y: u16 = @intCast(y_usize);
                for (0..world.width) |x_usize| {
                    const x: u16 = @intCast(x_usize);
                    if (!world.denseTileBlocksMovement(layer_index, x, y)) continue;
                    slot.blocked.items[y_usize * world.width + x_usize] = true;
                }
            }
        }
        for (world.sparseTileIndicesForLevel(level)) |sparse_index| {
            if (!world.sparseTileBlocksMovement(sparse_index)) continue;
            const cell = world.sparseTileCellCoord(sparse_index);
            slot.blocked.items[@as(usize, cell.y) * @as(usize, world.width) + @as(usize, cell.x)] = true;
        }

        slot.built_step = self.step_counter;
    }

    // Population-domain contract with spatial_index.zig/ai.zig (see module
    // doc): walks `scope_dense_indices` (or all ai agents) resolving
    // `data.movementBodyDenseIndex(entity) orelse continue`, in the exact
    // same order SpatialIndexSystem/AiSystem's own gathers do — a deliberate
    // duplicate gather, not shared code, so `candidates` row `i` and
    // `spatial`'s row `i` refer to the same agent. This walk does double
    // duty: every surviving entity (regardless of AiPerception) becomes a
    // `candidates` row (so the neighbor-visit callback can resolve
    // faction/level/entity from a spatial row index); entities that also
    // carry `AiPerception` additionally become an observer `rows` entry,
    // capturing `spatial_self_index` (this walk's row count so far) and
    // `perception_dense_index` (the unrelated `PerceptionStore` row).
    fn gatherPerceptionData(
        self: *PerceptionSystem,
        ai_agents: ConstAiAgentSlice,
        movement: ConstMovementBodySlice,
        data: *const DataSystem,
        perception_slice: PerceptionSlice,
        scope_dense_indices: ?[]const u32,
    ) !void {
        self.clearWork();
        const n = if (scope_dense_indices) |idx| idx.len else ai_agents.entities.len;
        if (n == 0) return;
        try self.candidates.ensureTotalCapacity(self.allocator, hotStoreCapacity(n));
        try self.rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(n));

        var candidate_slice = self.candidates.slice();
        var row_slice = self.rows.slice();
        var k: usize = 0;
        var spatial_row_index: usize = 0;
        while (k < n) : (k += 1) {
            const i: usize = if (scope_dense_indices) |idx| idx[k] else k;
            const ent = ai_agents.entities[i];
            const mi = data.movementBodyDenseIndex(ent) orelse continue;

            const ent_faction = data.factionConst(ent) orelse .neutral;
            const ent_level = data.worldLevelConst(ent) orelse 0;
            appendCandidateRow(&self.candidates, &candidate_slice, .{
                .entity = ent,
                .faction = ent_faction,
                .level = ent_level,
            });

            if (data.aiPerceptionDenseIndex(ent)) |perception_index| {
                const prev_nearest = perception_slice.nearest_threat[perception_index];
                appendPerceptionGatherRow(&self.rows, &row_slice, .{
                    .entity = ent,
                    .pos_x = movement.previous_x[mi],
                    .pos_y = movement.previous_y[mi],
                    .velocity_x = movement.velocity_x[mi],
                    .velocity_y = movement.velocity_y[mi],
                    .vision_range = perception_slice.vision_range[perception_index],
                    .cos_half_fov = perception_slice.cos_half_fov[perception_index],
                    .faction = ent_faction,
                    .level = ent_level,
                    .spatial_self_index = spatial_row_index,
                    .perception_dense_index = perception_index,
                    .facing_x = perception_slice.facing_x[perception_index],
                    .facing_y = perception_slice.facing_y[perception_index],
                    .prev_nearest_threat_index = @bitCast(prev_nearest.index),
                    .prev_nearest_threat_generation = @bitCast(prev_nearest.generation),
                    .final_nearest_threat_index = invalid_index_bits,
                    .final_nearest_threat_generation = invalid_generation_bits,
                });
            }

            spatial_row_index += 1;
        }
    }

    fn clearWork(self: *PerceptionSystem) void {
        self.candidates.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
    }

    /// Derives every gathered row's unit facing vector from its previous-step
    /// velocity, run once (main thread, before the compute dispatch) over the
    /// full contiguous `rows` set — same shape as spatial_index.zig's
    /// `assignCellsDense`: a dense batch pass after the scattered/branchy
    /// gather, shared verbatim by both `update` and `updateSerial` so
    /// threaded/serial facing is identical by construction (nothing left to
    /// parity-test between them). Near-stationary agents (speed^2 at or below
    /// `facing_speed_squared_threshold`) hold their previous stored facing
    /// rather than snapping to a noisy near-zero velocity direction. Facing is
    /// scattered back into `PerceptionStore` here too (`perception_dense_index`
    /// is scattered/non-contiguous, so that final step stays a scalar loop).
    fn computeFacingDense(self: *PerceptionSystem, perception_slice: PerceptionSlice) void {
        const rows = self.rows.slice();
        const n = rows.len;
        const velocity_x = rows.items(.velocity_x);
        const velocity_y = rows.items(.velocity_y);
        const facing_x = rows.items(.facing_x);
        const facing_y = rows.items(.facing_y);
        const perception_dense_index = rows.items(.perception_dense_index);

        var i: usize = 0;
        const vend = simd.vectorizedEnd(n);
        const threshold = simd.splatFloat4(facing_speed_squared_threshold);
        while (i < vend) : (i += simd.lane_count) {
            const vx = simd.loadFloat4(velocity_x[i..]);
            const vy = simd.loadFloat4(velocity_y[i..]);
            const prev_fx = simd.loadFloat4(facing_x[i..]);
            const prev_fy = simd.loadFloat4(facing_y[i..]);
            const speed2 = simd.lengthSquared2Float4(vx, vy);
            const moving = simd.greaterThanFloat4(speed2, threshold);
            const normalized = simd.normalizeOrZero2Float4(vx, vy, facing_normalize_epsilon);
            const result_x = simd.selectFloat4(moving, normalized.x, prev_fx);
            const result_y = simd.selectFloat4(moving, normalized.y, prev_fy);
            simd.storeFloat4Slice(facing_x[i..], result_x);
            simd.storeFloat4Slice(facing_y[i..], result_y);
        }
        while (i < n) : (i += 1) {
            const result = computeFacingScalar(velocity_x[i], velocity_y[i], .{ .x = facing_x[i], .y = facing_y[i] });
            facing_x[i] = result.x;
            facing_y[i] = result.y;
        }

        for (0..n) |row_index| {
            const dense = perception_dense_index[row_index];
            perception_slice.facing_x[dense] = facing_x[row_index];
            perception_slice.facing_y[dense] = facing_y[row_index];
        }
    }

    fn prepareEventRangeBuffers(self: *PerceptionSystem, range_count: usize, items_per_range: usize, item_count: usize) !void {
        try self.event_ranges.ensureTotalCapacity(self.allocator, range_count);
        while (self.event_ranges.items.len < range_count) self.event_ranges.appendAssumeCapacity(.{});
        for (self.event_ranges.items[0..range_count], 0..) |*slot, range_index| {
            slot.buffer.clearRetainingCapacity();
            const range_len = rangeLenForIndex(item_count, items_per_range, range_index);
            // Worst case: an identity swap emits two events for one row, so
            // this exact reserve can never overflow (unlike collision's
            // broadphase pair estimate) — no grow-and-replay dance needed.
            try slot.buffer.events.ensureTotalCapacity(self.allocator, range_len * 2);
        }
    }

    // Sizes/resets `range_stats` to `range_count` slots before dispatch (same
    // reserve-before-dispatch shape as `prepareEventRangeBuffers`), so every
    // range job has a pre-existing slot to write its single accumulated
    // `PerceptionRangeStats` value into.
    fn prepareRangeStats(self: *PerceptionSystem, range_count: usize) !void {
        try self.range_stats.ensureTotalCapacity(self.allocator, range_count);
        while (self.range_stats.items.len < range_count) self.range_stats.appendAssumeCapacity(.{});
        for (self.range_stats.items[0..range_count]) |*stats| stats.* = .{};
    }

    fn sumRangeStats(self: *const PerceptionSystem, range_count: usize) PerceptionRangeStats {
        var totals = PerceptionRangeStats{};
        for (self.range_stats.items[0..range_count]) |per_range| {
            totals.sensed_count += per_range.sensed_count;
            totals.nearest_threat_found += per_range.nearest_threat_found;
            totals.los_checks += per_range.los_checks;
            totals.los_blocked += per_range.los_blocked;
        }
        return totals;
    }

    /// Serial merge after the parallel/serial compute pass: sums each range's
    /// real (not worst-case) event count, applies this system's own
    /// deterministic per-step cap in range-ascending, within-range-write-order
    /// (truncating the tail rather than letting `SimulationEvents`'s own
    /// capacity check throw — see the module doc), then re-walks each range's
    /// scratch into `events`'s shared range-output stream.
    fn mergePerceptionEvents(
        self: *PerceptionSystem,
        events: *SimulationEvents,
        range_count: usize,
        max_events_per_step: usize,
    ) !PerceptionEventMergeResult {
        try self.range_take_counts.ensureTotalCapacity(self.allocator, range_count);
        self.range_take_counts.clearRetainingCapacity();

        var total: usize = 0;
        for (self.event_ranges.items[0..range_count]) |*slot| total += slot.buffer.events.items.len;
        const capped_total = @min(total, max_events_per_step);
        const dropped = total - capped_total;

        var remaining = capped_total;
        for (self.event_ranges.items[0..range_count]) |*slot| {
            const take = @min(slot.buffer.events.items.len, remaining);
            self.range_take_counts.appendAssumeCapacity(take);
            remaining -= take;
        }

        const first_range = try events.appendRangeCounts(range_count);
        for (self.range_take_counts.items, 0..) |take, range_index| {
            events.addCount(first_range + range_index, take);
        }
        try events.prefixAppendedRanges(first_range);

        var perceived: usize = 0;
        var lost: usize = 0;
        for (self.event_ranges.items[0..range_count], self.range_take_counts.items, 0..) |*slot, take, range_index| {
            var writer = events.rangeWriter(first_range + range_index);
            for (slot.buffer.events.items[0..take]) |event| {
                writer.write(event);
                switch (event.payload) {
                    .entity_perceived => perceived += 1,
                    .entity_lost => lost += 1,
                    else => {},
                }
            }
            writer.finish();
        }
        events.finishWrite();
        events.stats.dropped += dropped;

        return .{ .perceived = perceived, .lost = lost, .dropped = dropped };
    }
};

const PerceptionEventMergeResult = struct {
    perceived: usize,
    lost: usize,
    dropped: usize,
};

fn computeFacingScalar(vx: f32, vy: f32, prev_facing: math.Vec2) math.Vec2 {
    const speed2 = vx * vx + vy * vy;
    if (speed2 <= facing_speed_squared_threshold) return prev_facing;
    return math.normalizeOrZero(.{ .x = vx, .y = vy }, facing_normalize_epsilon);
}

const PerceptionJobContext = struct {
    entities: []const EntityId,
    pos_x: []const f32,
    pos_y: []const f32,
    vision_range: []const f32,
    cos_half_fov: []const f32,
    faction: []const Faction,
    level: []const u16,
    spatial_self_index: []const usize,
    perception_dense_index: []const usize,
    facing_x: []const f32,
    facing_y: []const f32,
    prev_nearest_threat_index: []const i32,
    prev_nearest_threat_generation: []const i32,
    final_nearest_threat_index: []i32,
    final_nearest_threat_generation: []i32,

    candidates: ConstCandidateSlice,

    perception_slice: PerceptionSlice,
    spatial: SpatialIndexView,
    world: *const WorldSystem,
    // O(1) LOS-blocked lookup cache, main-thread-built before dispatch (see
    // `PerceptionSystem.ensureLevelBlockedCachesForObservers`), read-only for
    // every worker range.
    level_blocked: []const LevelBlockedSlot,
    player_candidate: ?PlayerPerceptionCandidate,
    event_ranges: []PerceptionEventRangeSlot,
    range_stats: []PerceptionRangeStats,
};

fn writePerceptionRangeJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *PerceptionJobContext = @ptrCast(@alignCast(context));
    // Guards the reserve-before-dispatch invariant: prepareEventRangeBuffers
    // must have sized event_ranges to at least this dispatch's range count.
    std.debug.assert(range.index < job.event_ranges.len);
    computePerceptionRange(job, range);
}

/// Shared per-range compute: scalar per-agent neighbor query/FOV/LOS/writeback
/// (`computeOneAgent`), then the dense transition-detection + scalar emit
/// pass (`emitTransitionsForRange`). Called identically by the threaded
/// dispatch and the serial single-range path — see the module doc's
/// serial/threaded parity note.
fn computePerceptionRange(job: *PerceptionJobContext, range: ParallelRange) void {
    // Local accumulator, not a pointer into job.range_stats: only one write
    // (below) ever lands per range, so concurrently running ranges never
    // touch each other's slot mid-accumulation.
    var range_stats = PerceptionRangeStats{};
    for (range.start..range.end) |i| computeOneAgent(job, i, &range_stats);
    emitTransitionsForRange(job, range);
    job.range_stats[range.index] = range_stats;
}

const CandidateScratch = struct {
    candidate_index: [max_perception_scratch]usize = undefined,
    to_x: [max_perception_scratch]f32 = undefined,
    to_y: [max_perception_scratch]f32 = undefined,
    dist2: [max_perception_scratch]f32 = undefined,
    count: usize = 0,

    fn append(self: *CandidateScratch, index: usize, to_x: f32, to_y: f32, dist2: f32) void {
        self.candidate_index[self.count] = index;
        self.to_x[self.count] = to_x;
        self.to_y[self.count] = to_y;
        self.dist2[self.count] = dist2;
        self.count += 1;
    }
};

const NeighborVisitContext = struct {
    observer_faction: Faction,
    candidate_faction: []const Faction,
    scratch: *CandidateScratch,
};

/// Scalar: the spatial cell-scan traversal itself (Slice 28 shared infra) and
/// the stance lookup (a 4-value enum table index, not float math) are both
/// branchy/sparse, not dense uniform work, so this callback stays scalar —
/// same shape as ai.zig's `separationNeighborVisit`. Negates
/// `queryNeighbors`'s `origin - candidate` into `candidate - observer` once,
/// here, before buffering (see the module doc's sign-convention note).
fn perceptionNeighborVisit(context: *anyopaque, candidate_index: usize, dx: f32, dy: f32, dist2: f32) NeighborVisitResult {
    const ctx: *NeighborVisitContext = @ptrCast(@alignCast(context));
    if (stance(ctx.observer_faction, ctx.candidate_faction[candidate_index]) != .hostile) return .keep_going;
    ctx.scratch.append(candidate_index, -dx, -dy, dist2);
    if (ctx.scratch.count >= max_perception_candidates) return .stop;
    return .keep_going;
}

/// Dense SIMD FOV filter (pack-then-vectorize over the already-packed
/// `scratch` arrays, per simd.zig's `gatherFloat4` doc comment), with a
/// scalar tail for the `< lane_count` remainder. `facing` is unit-length
/// (from `computeFacingDense`), so `dot(facing, to) > 0 AND dot^2 >
/// cos_half_fov^2 * dist2` is a sqrt/normalize/divide-free angle compare —
/// see the module doc for why the sign sits this way and why squaring is
/// valid here (`cos_half_fov >= 0` always).
fn filterFovSurvivors(
    scratch: *const CandidateScratch,
    facing_x: f32,
    facing_y: f32,
    cos_half_fov: f32,
    survivors: *[max_perception_scratch]usize,
) usize {
    var survivor_count: usize = 0;
    const facing_x_vec = simd.splatFloat4(facing_x);
    const facing_y_vec = simd.splatFloat4(facing_y);
    const cos2_vec = simd.splatFloat4(cos_half_fov * cos_half_fov);
    const zero = simd.splatFloat4(0);

    var i: usize = 0;
    const n = scratch.count;
    const vend = simd.vectorizedEnd(n);
    while (i < vend) : (i += simd.lane_count) {
        const to_x = simd.loadFloat4(scratch.to_x[i..]);
        const to_y = simd.loadFloat4(scratch.to_y[i..]);
        const dist2 = simd.loadFloat4(scratch.dist2[i..]);
        const dot = simd.dotFloat4(facing_x_vec, facing_y_vec, to_x, to_y);
        const positive = simd.greaterThanFloat4(dot, zero);
        const within_cone = simd.greaterThanFloat4(simd.mulFloat4(dot, dot), simd.mulFloat4(cos2_vec, dist2));
        const passed = positive & within_cone;
        inline for (0..simd.lane_count) |lane| {
            if (passed[lane]) {
                survivors[survivor_count] = i + lane;
                survivor_count += 1;
            }
        }
    }
    while (i < n) : (i += 1) {
        if (fovTestScalar(facing_x, facing_y, scratch.to_x[i], scratch.to_y[i], scratch.dist2[i], cos_half_fov)) {
            survivors[survivor_count] = i;
            survivor_count += 1;
        }
    }
    return survivor_count;
}

fn fovTestScalar(facing_x: f32, facing_y: f32, to_x: f32, to_y: f32, dist2: f32, cos_half_fov: f32) bool {
    const dot = facing_x * to_x + facing_y * to_y;
    if (dot <= 0) return false;
    return dot * dot > (cos_half_fov * cos_half_fov) * dist2;
}

const ResolvedCandidate = struct {
    entity: EntityId,
    level: u16,
};

const SurvivorSortContext = struct {
    scratch: *const CandidateScratch,
    candidates: ConstCandidateSlice,
    player_candidate: ?PlayerPerceptionCandidate,
};

fn resolveCandidate(ctx: SurvivorSortContext, slot: usize) ResolvedCandidate {
    const candidate_index = ctx.scratch.candidate_index[slot];
    if (candidate_index == player_candidate_sentinel) {
        const player = ctx.player_candidate.?;
        return .{ .entity = player.entity, .level = player.level };
    }
    return .{ .entity = ctx.candidates.entities[candidate_index], .level = ctx.candidates.level[candidate_index] };
}

// Small (<= max_perception_scratch), branchy comparator resolving an entity
// per compare: irreducibly small and does not scale with population, so this
// sort stays scalar (per-agent candidate counts are bounded by
// max_perception_candidates regardless of world size).
fn survivorLessThan(ctx: SurvivorSortContext, lhs: usize, rhs: usize) bool {
    const lhs_dist2 = ctx.scratch.dist2[lhs];
    const rhs_dist2 = ctx.scratch.dist2[rhs];
    if (lhs_dist2 != rhs_dist2) return lhs_dist2 < rhs_dist2;
    return resolveCandidate(ctx, lhs).entity.index < resolveCandidate(ctx, rhs).entity.index;
}

/// Bounded LOS raycast: fixed-step sampling with an early exit on the first
/// blocked sample. Each sample is a branchy, scattered cell lookup (not
/// dense/uniform), so the step loop itself stays scalar; the per-sample
/// blocked test is `lookupLevelBlocked`'s O(1) bitmap read (see
/// `LevelBlockedSlot`), not a `WorldSystem.levelBlocksMovement` call.
fn hasLineOfSight(world: *const WorldSystem, level_blocked: []const LevelBlockedSlot, level: u16, ox: f32, oy: f32, tx: f32, ty: f32) bool {
    const dx = tx - ox;
    const dy = ty - oy;
    const distance = math.length(.{ .x = dx, .y = dy });
    if (distance <= 0) return true;
    const tile_size = world.tile_size;
    // Ceil via floor negation (`ceil(x) == -floor(-x)`), same idiom as
    // spatial_index.zig's cellScanRadius.
    const raw_steps = -math.floorToI32(-(distance / tile_size));
    const capped_steps: i32 = @min(raw_steps, @as(i32, @intCast(los_max_steps)));
    const step_count: u32 = @intCast(@max(capped_steps, 1));

    var step: u32 = 1;
    while (step <= step_count) : (step += 1) {
        const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(step_count));
        const px = ox + dx * t;
        const py = oy + dy * t;
        const cell = world.cellContaining(px, py) orelse return false;
        if (lookupLevelBlocked(level_blocked, level, cell.x, cell.y)) return false;
    }
    return true;
}

fn computeOneAgent(job: *PerceptionJobContext, i: usize, range_stats: *PerceptionRangeStats) void {
    const ox = job.pos_x[i];
    const oy = job.pos_y[i];
    const vision_range = job.vision_range[i];
    const cos_half_fov = job.cos_half_fov[i];
    const observer_faction = job.faction[i];
    const observer_level = job.level[i];
    const self_index = job.spatial_self_index[i];
    const facing_x = job.facing_x[i];
    const facing_y = job.facing_y[i];

    var scratch = CandidateScratch{};
    var visit_ctx = NeighborVisitContext{
        .observer_faction = observer_faction,
        .candidate_faction = job.candidates.faction,
        .scratch = &scratch,
    };
    const scan_radius = spatial_index_mod.cellScanRadius(vision_range, job.spatial.cell_size);
    _ = job.spatial.queryNeighbors(
        ox,
        oy,
        self_index,
        scan_radius,
        .{ .radius = vision_range, .max_candidate_checks = max_perception_candidate_checks },
        &visit_ctx,
        perceptionNeighborVisit,
    );

    if (job.player_candidate) |player| {
        if (stance(observer_faction, player.faction) == .hostile) {
            const to_x = player.pos_x - ox;
            const to_y = player.pos_y - oy;
            const dist2 = to_x * to_x + to_y * to_y;
            if (dist2 < vision_range * vision_range) {
                scratch.append(player_candidate_sentinel, to_x, to_y, dist2);
            }
        }
    }

    var survivors: [max_perception_scratch]usize = undefined;
    const survivor_count = filterFovSurvivors(&scratch, facing_x, facing_y, cos_half_fov, &survivors);

    const sort_ctx = SurvivorSortContext{
        .scratch = &scratch,
        .candidates = job.candidates,
        .player_candidate = job.player_candidate,
    };
    std.mem.sort(usize, survivors[0..survivor_count], sort_ctx, survivorLessThan);
    range_stats.sensed_count += survivor_count;

    var target_visible = false;
    var nearest_threat = EntityId.invalid;
    var nearest_threat_dist: f32 = std.math.inf(f32);
    var last_seen_x: f32 = 0;
    var last_seen_y: f32 = 0;

    // Small (<= max_perception_scratch), branchy walk with a per-candidate
    // bounded LOS raycast: irreducible, does not scale with population, so
    // this stays scalar.
    for (survivors[0..survivor_count]) |slot| {
        const resolved = resolveCandidate(sort_ctx, slot);
        if (resolved.level != observer_level) continue;
        const tx = ox + scratch.to_x[slot];
        const ty = oy + scratch.to_y[slot];
        range_stats.los_checks += 1;
        if (hasLineOfSight(job.world, job.level_blocked, observer_level, ox, oy, tx, ty)) {
            target_visible = true;
            nearest_threat = resolved.entity;
            nearest_threat_dist = math.length(.{ .x = scratch.to_x[slot], .y = scratch.to_y[slot] });
            last_seen_x = tx;
            last_seen_y = ty;
            break;
        }
        range_stats.los_blocked += 1;
    }
    if (target_visible) range_stats.nearest_threat_found += 1;

    const dense_index = job.perception_dense_index[i];
    job.perception_slice.target_visible[dense_index] = target_visible;
    job.perception_slice.nearest_threat[dense_index] = nearest_threat;
    // Actual distance (not squared): nearest_threat_dist is the directly
    // consumable magnitude a future steering/urgency consumer would want
    // without paying a second sqrt.
    job.perception_slice.nearest_threat_dist[dense_index] = nearest_threat_dist;
    if (target_visible) {
        job.perception_slice.last_seen_x[dense_index] = last_seen_x;
        job.perception_slice.last_seen_y[dense_index] = last_seen_y;
    }
    // last_seen_x/y are deliberately left unchanged when target_visible is
    // false, holding the last real sighting for a future memory slice.

    job.final_nearest_threat_index[i] = @bitCast(nearest_threat.index);
    job.final_nearest_threat_generation[i] = @bitCast(nearest_threat.generation);
}

fn reconstructEntityId(index_bits: i32, generation_bits: i32) EntityId {
    return .{ .index = @bitCast(index_bits), .generation = @bitCast(generation_bits) };
}

/// Batches the prev-vs-final `EntityId` compare 4 rows at a time via
/// `simd.equalInt4` over the row's contiguous bitcast index/generation
/// columns, feeding a scalar per-row emit — same shape as collision.zig's
/// SIMD Y-overlap filter feeding scalar contact emission. Scalar tail for the
/// `< lane_count` remainder.
fn emitTransitionsForRange(job: *PerceptionJobContext, range: ParallelRange) void {
    const buffer = &job.event_ranges[range.index].buffer;
    var i = range.start;
    while (i + simd.lane_count <= range.end) : (i += simd.lane_count) {
        const prev_idx = simd.loadInt4(job.prev_nearest_threat_index[i..]);
        const prev_gen = simd.loadInt4(job.prev_nearest_threat_generation[i..]);
        const final_idx = simd.loadInt4(job.final_nearest_threat_index[i..]);
        const final_gen = simd.loadInt4(job.final_nearest_threat_generation[i..]);
        const idx_equal = simd.equalInt4(prev_idx, final_idx);
        const gen_equal = simd.equalInt4(prev_gen, final_gen);
        const unchanged = idx_equal & gen_equal;
        inline for (0..simd.lane_count) |lane| {
            if (!unchanged[lane]) {
                emitTransition(
                    buffer,
                    job.entities[i + lane],
                    reconstructEntityId(job.prev_nearest_threat_index[i + lane], job.prev_nearest_threat_generation[i + lane]),
                    reconstructEntityId(job.final_nearest_threat_index[i + lane], job.final_nearest_threat_generation[i + lane]),
                );
            }
        }
    }
    while (i < range.end) : (i += 1) {
        if (job.prev_nearest_threat_index[i] != job.final_nearest_threat_index[i] or
            job.prev_nearest_threat_generation[i] != job.final_nearest_threat_generation[i])
        {
            emitTransition(
                buffer,
                job.entities[i],
                reconstructEntityId(job.prev_nearest_threat_index[i], job.prev_nearest_threat_generation[i]),
                reconstructEntityId(job.final_nearest_threat_index[i], job.final_nearest_threat_generation[i]),
            );
        }
    }
}

/// Transition rules (see module doc): invalid->valid emits only
/// `entity_perceived`; valid->invalid emits only `entity_lost`; a
/// valid->different-valid identity swap emits both, `entity_lost` (the
/// previous target) before `entity_perceived` (the new one), in that order.
/// `prev`/`final` equal (including both invalid) never reaches here — the
/// caller's `unchanged` check already filtered that out.
fn emitTransition(buffer: *PerceptionEventRangeBuffer, observer: EntityId, prev: EntityId, final: EntityId) void {
    if (prev.generation != 0) {
        buffer.appendAssumeCapacity(.{ .stage = .domain_reaction, .payload = .{ .entity_lost = .{ .observer = observer, .target = prev } } });
    }
    if (final.generation != 0) {
        buffer.appendAssumeCapacity(.{ .stage = .domain_reaction, .payload = .{ .entity_perceived = .{ .observer = observer, .target = final } } });
    }
}

const StageWorkSelection = struct {
    profile: AdaptiveWorkProfile,
    items_per_range: usize,
    worker_threads: usize,
    range_count: usize,
    active_tuner: ?*AdaptiveWorkTuner = null,
};

// Mirrors ai.zig/spatial_index.zig/collision.zig's selectStageWork verbatim
// (module-local adaptive-profile resolution), keyed by
// perception_range_alignment_items.
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
            .range_alignment_items = perception_range_alignment_items,
        })
    else
        AdaptiveWorkProfile{
            .worker_threads = max_worker_threads,
            .items_per_range = requested_items_per_range,
        };
    const aligned_items_per_range = alignItemCount(@max(profile.items_per_range, @as(usize, 1)), perception_range_alignment_items);
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

// ---- Tests --------------------------------------------------------------------

const testing = std.testing;
const AiPerception = @import("../data_system.zig").AiPerception;
const SpatialIndexSystem = spatial_index_mod.SpatialIndexSystem;

fn addAgent(
    data: *DataSystem,
    pos_x: f32,
    pos_y: f32,
    velocity_x: f32,
    velocity_y: f32,
    faction: Faction,
) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{
        .position = .{ .x = pos_x, .y = pos_y },
        .previous_position = .{ .x = pos_x, .y = pos_y },
        .velocity = .{ .x = velocity_x, .y = velocity_y },
        .speed = 40,
    });
    try data.setAiAgent(entity, .{ .behavior = .wander });
    try data.setFaction(entity, faction);
    return entity;
}

fn addObserver(
    data: *DataSystem,
    pos_x: f32,
    pos_y: f32,
    velocity_x: f32,
    velocity_y: f32,
    faction: Faction,
    perception: AiPerception,
) !EntityId {
    const entity = try addAgent(data, pos_x, pos_y, velocity_x, velocity_y, faction);
    try data.setAiPerception(entity, perception);
    return entity;
}

fn testSpatialIndex(
    ai_slice: ConstAiAgentSlice,
    movement_slice: ConstMovementBodySlice,
    data: *const DataSystem,
) !SpatialIndexSystem {
    var sys = SpatialIndexSystem.init(testing.allocator);
    errdefer sys.deinit();
    _ = try sys.buildSerial(ai_slice, movement_slice, data, .{});
    return sys;
}

fn minimalWorld(allocator: std.mem.Allocator, width: u16, height: u16, tile_size: f32) !WorldSystem {
    var world = WorldSystem{
        .allocator = allocator,
        .width = width,
        .height = height,
        .tile_size = tile_size,
        .chunk_size_tiles = width,
    };
    _ = try world.addLevel(0);
    return world;
}

test "fovTestScalar accepts squarely ahead, boundary, and rejects squarely behind" {
    // 60-degree half-angle (cos(60) == 0.5), facing +x.
    const cos_half_fov: f32 = 0.5;
    // Squarely ahead: candidate directly along +x.
    try testing.expect(fovTestScalar(1, 0, 10, 0, 100, cos_half_fov));
    // Squarely behind: candidate directly along -x (dot <= 0, rejected before squaring).
    try testing.expect(!fovTestScalar(1, 0, -10, 0, 100, cos_half_fov));
    // Just inside the cone: angle slightly less than 60 degrees.
    const inside = math.rotate2D(.{ .x = 10, .y = 0 }, math.sinCos(std.math.pi / 3.0 - 0.05));
    try testing.expect(fovTestScalar(1, 0, inside.x, inside.y, inside.x * inside.x + inside.y * inside.y, cos_half_fov));
    // Just outside the cone: angle slightly more than 60 degrees.
    const outside = math.rotate2D(.{ .x = 10, .y = 0 }, math.sinCos(std.math.pi / 3.0 + 0.05));
    try testing.expect(!fovTestScalar(1, 0, outside.x, outside.y, outside.x * outside.x + outside.y * outside.y, cos_half_fov));
}

test "filterFovSurvivors matches fovTestScalar lane-for-lane across a packed scratch, including the scalar tail" {
    var scratch = CandidateScratch{};
    // 6 candidates (not a multiple of lane_count 4): exercises the vectorized
    // block (4) and the scalar tail (2) in the same run.
    const facing_x: f32 = 0.6;
    const facing_y: f32 = 0.8;
    const cos_half_fov: f32 = 0.5;
    const cases = [_][2]f32{ .{ 10, 10 }, .{ -5, -5 }, .{ 20, 1 }, .{ 1, 20 }, .{ -8, 3 }, .{ 6, -1 } };
    for (cases, 0..) |c, idx| {
        scratch.append(idx, c[0], c[1], c[0] * c[0] + c[1] * c[1]);
    }

    var survivors: [max_perception_scratch]usize = undefined;
    const survivor_count = filterFovSurvivors(&scratch, facing_x, facing_y, cos_half_fov, &survivors);

    var expected_count: usize = 0;
    for (0..scratch.count) |i| {
        const expect = fovTestScalar(facing_x, facing_y, scratch.to_x[i], scratch.to_y[i], scratch.dist2[i], cos_half_fov);
        const found = std.mem.indexOfScalar(usize, survivors[0..survivor_count], i) != null;
        try testing.expectEqual(expect, found);
        if (expect) expected_count += 1;
    }
    try testing.expectEqual(expected_count, survivor_count);
}

test "computeFacingDense matches computeFacingScalar lane-for-lane, including the scalar tail" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    // 5 rows (not a multiple of lane_count 4): exercises the vectorized block
    // and the one-row scalar tail in the same run. Mix of moving and
    // near-stationary rows so both select branches are covered.
    const velocities = [_][2]f32{ .{ 50, 0 }, .{ 0, 0 }, .{ -30, 40 }, .{ 0.01, 0 }, .{ 0, -20 } };
    const prev_facings = [_][2]f32{ .{ 1, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 } };

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();

    var entities: [velocities.len]EntityId = undefined;
    for (velocities, 0..) |v, i| {
        entities[i] = try addObserver(&data, @floatFromInt(i * 10), 0, v[0], v[1], .neutral, .{});
    }

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();

    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    // Seed prev_facing via a direct perception-slice write (simulating a prior
    // step's output) before the dense pass runs.
    {
        var perception_slice = data.perceptionSlice();
        for (entities, 0..) |ent, i| {
            const dense = data.aiPerceptionDenseIndex(ent).?;
            perception_slice.facing_x[dense] = prev_facings[i][0];
            perception_slice.facing_y[dense] = prev_facings[i][1];
        }
    }

    var world = try minimalWorld(testing.allocator, 8, 8, 32);
    defer world.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});

    for (entities, velocities, prev_facings) |ent, v, prev| {
        const expected = computeFacingScalar(v[0], v[1], .{ .x = prev[0], .y = prev[1] });
        const perception = data.aiPerceptionConst(ent).?;
        try testing.expectEqual(expected.x, perception.facing_x);
        try testing.expectEqual(expected.y, perception.facing_y);
    }
}

test "gather uses the full-population spatial row index for self-exclusion, not the filtered observer row index" {
    // X and Z carry AiPerception (observers); Y sits between them in
    // scope_dense_indices but has no AiPerception, so it is a candidate only.
    // If the self_index passed to queryNeighbors were wrongly the filtered
    // observer-row index (1) instead of the true spatial row index (2) for Z,
    // Z's query would self-exclude Y instead of itself, and Y (hostile, right
    // next to Z) would never be found.
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const x = try addObserver(&data, 0, 0, 0, 0, .player, .{});
    const y = try addAgent(&data, 1000, 1000, 0, 0, .hostile);
    // Z moves toward Y (-x direction) so computeFacingDense derives a facing
    // pointed at Y without needing to poke internal fields directly.
    const z = try addObserver(&data, 1010, 1000, -100, 0, .player, .{});

    const scope = [_]u32{ 0, 1, 2 };
    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();

    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{
        .scope_dense_indices = &scope,
    });

    const z_perception = data.aiPerceptionConst(z).?;
    try testing.expect(z_perception.target_visible);
    try testing.expectEqual(y.index, z_perception.nearest_threat.index);

    // X is far from everyone (out of default vision_range) and unaffected.
    const x_perception = data.aiPerceptionConst(x).?;
    try testing.expect(!x_perception.target_visible);
}

test "candidate outside vision_range is never selected" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 10, 0, .player, .{ .vision_range = 50 });
    _ = try addAgent(&data, 200, 0, 0, 0, .hostile); // outside vision_range

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});

    try testing.expect(!data.aiPerceptionConst(observer).?.target_visible);
}

test "FOV gating: candidate outside the cone is not perceived, inside is" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    // Observer moves in +x, so facing settles to (1, 0).
    const observer = try addObserver(&data, 0, 0, 100, 0, .player, .{ .fov_half_angle_radians = std.math.pi / 4.0 });
    // Directly behind the observer: outside any <= 90 degree cone.
    _ = try addAgent(&data, -50, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});
    try testing.expect(!data.aiPerceptionConst(observer).?.target_visible);

    // Now place a candidate directly ahead instead.
    var data2 = DataSystem.init(testing.allocator);
    defer data2.deinit();
    const observer2 = try addObserver(&data2, 0, 0, 100, 0, .player, .{ .fov_half_angle_radians = std.math.pi / 4.0 });
    _ = try addAgent(&data2, 50, 0, 0, 0, .hostile);

    var spatial_sys2 = try testSpatialIndex(data2.aiAgentSliceConst(), data2.movementBodySliceConst(), &data2);
    defer spatial_sys2.deinit();
    var sys2 = PerceptionSystem.init(testing.allocator);
    defer sys2.deinit();
    var events2 = SimulationEvents.init(testing.allocator);
    defer events2.deinit();
    _ = try sys2.updateSerial(data2.aiAgentSliceConst(), data2.movementBodySliceConst(), spatial_sys2.view(), &world, &data2, &events2, .{});
    try testing.expect(data2.aiPerceptionConst(observer2).?.target_visible);
}

test "stance gating: only hostile candidates ever become nearest_threat" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 10, 0, .player, .{});
    _ = try addAgent(&data, 10, 0, 0, 0, .neutral);
    _ = try addAgent(&data, 12, 0, 0, 0, .ally);
    const threat = try addAgent(&data, 14, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});

    const perception = data.aiPerceptionConst(observer).?;
    try testing.expect(perception.target_visible);
    try testing.expectEqual(threat.index, perception.nearest_threat.index);
}

test "same-level gating skips cross-level candidates even when closest" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 10, 0, .player, .{});
    const near_other_level = try addAgent(&data, 5, 0, 0, 0, .hostile);
    try data.setWorldLevel(near_other_level, 1);
    const far_same_level = try addAgent(&data, 40, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    // Level filtering happens before any LOS raycast, so `near_other_level`'s
    // (nonexistent) level 1 never needs a real world level to back it.
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});

    const perception = data.aiPerceptionConst(observer).?;
    try testing.expect(perception.target_visible);
    try testing.expectEqual(far_same_level.index, perception.nearest_threat.index);
}

test "LOS gating skips a blocked nearer candidate in favor of a farther clear one" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    // Real asset-backed tileset (same pattern as
    // pathfinding/nav_grid.zig's own blocked-tile test): a synthetic tile id
    // has no catalog entry, so a real "blocks movement" tile needs the real
    // tileset metadata rather than a hand-poked WorldSystem.
    const asset_store = @import("../../assets/assets.zig").AssetStore.init(testing.allocator, testing.io, "assets");
    var meta = try @import("../../assets/world_tileset_meta.zig").load(
        testing.allocator,
        asset_store,
        @import("../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();

    // A large bounds keeps this test's small (cells 0..3) coordinate area away
    // from `initDemoFromMeta`'s own fixed demo obstacles (sparse "deco" props
    // placed at roughly width/4, height/3 and 3*width/4, 2*height/3), so the
    // only blocking tile in play is the one this test adds below.
    var world = try WorldSystem.initDemoFromMeta(testing.allocator, &meta, 1024, 1024);
    defer world.deinit();
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;
    const grass = (meta.tileByName("grass") orelse return error.TestExpectedEqual).id;
    const layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    // Wall at cell (1, 0): blocks the straight path from the observer to the
    // nearer candidate but not the diagonal path to the farther one (the
    // diagonal ray drops into row 1 before it reaches column 1).
    _ = try world.setDenseTile(layer, 1, 0, tree);

    const tile_size = world.tile_size;
    const nearer_blocked = try addAgent(&data, tile_size * 2.5, tile_size * 0.5, 0, 0, .hostile);
    const farther_clear = try addAgent(&data, tile_size * 2.5, tile_size * 2.5, 0, 0, .hostile);
    const observer = try addObserver(&data, tile_size * 0.5, tile_size * 0.5, 1, 1, .player, .{
        .fov_half_angle_radians = std.math.pi / 2.0,
        .vision_range = tile_size * 10,
    });
    _ = nearer_blocked;

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});

    const perception = data.aiPerceptionConst(observer).?;
    try testing.expect(perception.target_visible);
    try testing.expectEqual(farther_clear.index, perception.nearest_threat.index);
}

test "LevelBlockedSlot cache lookup matches WorldSystem.levelBlocksMovement exactly: dense-blocked, sparse-blocked, open, out-of-range level, out-of-range cell" {
    // Real asset-backed tileset (same pattern as the LOS gating test above):
    // a synthetic tile id has no catalog entry, so a real "blocks movement"
    // tile needs the real tileset metadata rather than a hand-poked
    // WorldSystem.
    const asset_store = @import("../../assets/assets.zig").AssetStore.init(testing.allocator, testing.io, "assets");
    var meta = try @import("../../assets/world_tileset_meta.zig").load(
        testing.allocator,
        asset_store,
        @import("../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();

    // A large bounds keeps this test's small (cells 0..4) coordinate area
    // away from `initDemoFromMeta`'s own fixed demo obstacles (see the LOS
    // gating test's comment), and its mid-cross dense path pattern (which
    // only touches the exact middle row/column), so the only blocking cells
    // in play are the two this test adds below.
    var world = try WorldSystem.initDemoFromMeta(testing.allocator, &meta, 1024, 1024);
    defer world.deinit();
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;
    const grass = (meta.tileByName("grass") orelse return error.TestExpectedEqual).id;
    const layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    _ = try world.setDenseTile(layer, 1, 1, tree); // dense-blocked cell
    _ = try world.addSparseTile(0, 3, 3, tree, 0, .obstacle); // sparse-blocked cell

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    try sys.ensureLevelBlockedCache(&world, 0);
    // Also build a slot for a level that does not exist in `world` (only
    // level 0 was added), so the fail-closed check below exercises
    // `LevelBlockedSlot.valid == false` directly, not just the cheaper
    // `level >= level_blocked.len` early-out (both must fail-closed).
    try sys.ensureLevelBlockedCache(&world, 1);

    const Case = struct { level: u16, x: u16, y: u16 };
    const cases = [_]Case{
        .{ .level = 0, .x = 1, .y = 1 }, // dense-blocked
        .{ .level = 0, .x = 3, .y = 3 }, // sparse-blocked
        .{ .level = 0, .x = 4, .y = 4 }, // open
        .{ .level = 1, .x = 0, .y = 0 }, // built but invalid (world has only level 0)
        .{ .level = 2, .x = 0, .y = 0 }, // never built: out-of-range level_blocked index
        .{ .level = 0, .x = world.width, .y = 0 }, // out-of-range x
        .{ .level = 0, .x = 0, .y = world.height }, // out-of-range y
    };
    for (cases) |c| {
        const expected = world.levelBlocksMovement(c.level, c.x, c.y);
        const actual = lookupLevelBlocked(sys.level_blocked.items, c.level, c.x, c.y);
        try testing.expectEqual(expected, actual);
    }
}

test "player-candidate detection: hostile player within vision/FOV becomes nearest_threat" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 10, 0, .hostile, .{});

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const player = try data.createEntity();
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{
        .player_candidate = .{ .entity = player, .pos_x = 20, .pos_y = 0, .faction = .player, .level = 0 },
    });

    const perception = data.aiPerceptionConst(observer).?;
    try testing.expect(perception.target_visible);
    try testing.expectEqual(player.index, perception.nearest_threat.index);
}

test "transitions: invalid to valid emits entity_perceived" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 10, 0, .player, .{});
    const threat = try addAgent(&data, 10, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});
    try testing.expectEqual(@as(usize, 1), stats.perceived_events);
    try testing.expectEqual(@as(usize, 0), stats.lost_events);
    const merged = events.mergedItems();
    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expectEqual(SimulationEvent{ .stage = .domain_reaction, .payload = .{ .entity_perceived = .{ .observer = observer, .target = threat } } }, merged[0]);
}

test "transitions: valid to invalid emits entity_lost" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 10, 0, .player, .{});
    const threat = try addAgent(&data, 10, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 2048, 2048, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});
    try testing.expect(data.aiPerceptionConst(observer).?.target_visible);
    events.clearRetainingCapacity();

    // Move the threat far outside vision_range and rebuild the spatial index
    // (positions are read from previous_x/y, so update the movement body).
    try data.setMovementBody(threat, .{ .position = .{ .x = 5000, .y = 0 }, .previous_position = .{ .x = 5000, .y = 0 }, .velocity = .{}, .speed = 0 });
    var spatial_sys2 = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys2.deinit();

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys2.view(), &world, &data, &events, .{});
    try testing.expectEqual(@as(usize, 0), stats.perceived_events);
    try testing.expectEqual(@as(usize, 1), stats.lost_events);
    const merged = events.mergedItems();
    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expectEqual(SimulationEvent{ .stage = .domain_reaction, .payload = .{ .entity_lost = .{ .observer = observer, .target = threat } } }, merged[0]);
    try testing.expect(!data.aiPerceptionConst(observer).?.target_visible);
}

test "transitions: unchanged nearest_threat emits no event" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    _ = try addObserver(&data, 0, 0, 10, 0, .player, .{});
    _ = try addAgent(&data, 10, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});
    events.clearRetainingCapacity();

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});
    try testing.expectEqual(@as(usize, 0), stats.perceived_events);
    try testing.expectEqual(@as(usize, 0), stats.lost_events);
    try testing.expectEqual(@as(usize, 0), events.mergedItems().len);
}

test "transitions: identity swap without passing through invalid emits lost then perceived, in that order" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 10, 0, .player, .{ .vision_range = 500 });
    const first_threat = try addAgent(&data, 10, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 2048, 2048, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});
    try testing.expectEqual(first_threat.index, data.aiPerceptionConst(observer).?.nearest_threat.index);
    events.clearRetainingCapacity();

    // Move the first threat far away and add a second, closer hostile in the
    // same step: nearest_threat swaps identity without an intervening
    // invalid step.
    try data.setMovementBody(first_threat, .{ .position = .{ .x = 5000, .y = 0 }, .previous_position = .{ .x = 5000, .y = 0 }, .velocity = .{}, .speed = 0 });
    const second_threat = try addAgent(&data, 12, 0, 0, 0, .hostile);
    var spatial_sys2 = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys2.deinit();

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys2.view(), &world, &data, &events, .{});
    try testing.expectEqual(@as(usize, 1), stats.perceived_events);
    try testing.expectEqual(@as(usize, 1), stats.lost_events);
    const merged = events.mergedItems();
    try testing.expectEqual(@as(usize, 2), merged.len);
    try testing.expectEqual(SimulationEvent{ .stage = .domain_reaction, .payload = .{ .entity_lost = .{ .observer = observer, .target = first_threat } } }, merged[0]);
    try testing.expectEqual(SimulationEvent{ .stage = .domain_reaction, .payload = .{ .entity_perceived = .{ .observer = observer, .target = second_threat } } }, merged[1]);
    try testing.expectEqual(second_threat.index, data.aiPerceptionConst(observer).?.nearest_threat.index);
}

test "PerceptionSystem enforces its own per-step event cap and records the drop diagnostic" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    _ = try addObserver(&data, 0, 0, 10, 0, .player, .{});
    _ = try addAgent(&data, 10, 0, 0, 0, .hostile);
    _ = try addObserver(&data, 100, 0, 10, 0, .player, .{});
    _ = try addAgent(&data, 110, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 256, 256, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{
        .max_events_per_step = 1,
    });
    try testing.expectEqual(@as(usize, 1), stats.perceived_events + stats.lost_events);
    try testing.expectEqual(@as(usize, 1), stats.dropped_events);
    try testing.expectEqual(@as(usize, 1), events.mergedItems().len);
    try testing.expectEqual(@as(usize, 1), events.stats.dropped);
}

test "serial and threaded PerceptionSystem updates route through identical math" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var serial_data = DataSystem.init(testing.allocator);
    defer serial_data.deinit();
    var threaded_data = DataSystem.init(testing.allocator);
    defer threaded_data.deinit();

    for (0..40) |i| {
        const fi: f32 = @floatFromInt(i);
        const faction: Faction = if (i % 3 == 0) .hostile else .player;
        _ = try addAgent(&serial_data, fi * 6, 0, 0, 0, faction);
        _ = try addAgent(&threaded_data, fi * 6, 0, 0, 0, faction);
    }
    for (0..40) |i| {
        const fi: f32 = @floatFromInt(i);
        _ = try addObserver(&serial_data, fi * 6 + 3, 4, 1, 1, .player, .{ .fov_half_angle_radians = std.math.pi / 2.0, .vision_range = 100 });
        _ = try addObserver(&threaded_data, fi * 6 + 3, 4, 1, 1, .player, .{ .fov_half_angle_radians = std.math.pi / 2.0, .vision_range = 100 });
    }

    var serial_spatial = try testSpatialIndex(serial_data.aiAgentSliceConst(), serial_data.movementBodySliceConst(), &serial_data);
    defer serial_spatial.deinit();
    var threaded_spatial = try testSpatialIndex(threaded_data.aiAgentSliceConst(), threaded_data.movementBodySliceConst(), &threaded_data);
    defer threaded_spatial.deinit();

    var world = try minimalWorld(testing.allocator, 512, 64, 32);
    defer world.deinit();

    var serial_sys = PerceptionSystem.init(testing.allocator);
    defer serial_sys.deinit();
    var serial_events = SimulationEvents.init(testing.allocator);
    defer serial_events.deinit();
    _ = try serial_sys.updateSerial(serial_data.aiAgentSliceConst(), serial_data.movementBodySliceConst(), serial_spatial.view(), &world, &serial_data, &serial_events, .{});

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2, .items_per_range = perception_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var threaded_sys = PerceptionSystem.init(testing.allocator);
    defer threaded_sys.deinit();
    var threaded_events = SimulationEvents.init(testing.allocator);
    defer threaded_events.deinit();
    _ = try threaded_sys.update(threaded_data.aiAgentSliceConst(), threaded_data.movementBodySliceConst(), threaded_spatial.view(), &world, &threaded_data, &threaded_events, &threads, .{
        .items_per_range = perception_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });

    const serial_ai = serial_data.aiAgentSliceConst();
    const threaded_ai = threaded_data.aiAgentSliceConst();
    try testing.expectEqual(serial_ai.entities.len, threaded_ai.entities.len);
    for (serial_ai.entities, threaded_ai.entities) |serial_entity, threaded_entity| {
        const serial_perception = serial_data.aiPerceptionConst(serial_entity) orelse continue;
        const threaded_perception = threaded_data.aiPerceptionConst(threaded_entity) orelse continue;
        try testing.expectEqual(serial_perception.target_visible, threaded_perception.target_visible);
        try testing.expectEqual(serial_perception.nearest_threat.index, threaded_perception.nearest_threat.index);
        try testing.expectEqual(serial_perception.facing_x, threaded_perception.facing_x);
        try testing.expectEqual(serial_perception.facing_y, threaded_perception.facing_y);
    }

    const serial_merged = serial_events.mergedItems();
    const threaded_merged = threaded_events.mergedItems();
    try testing.expectEqualSlices(SimulationEvent, serial_merged, threaded_merged);
}

test "PerceptionSystem has no steady-state allocation after warmup (FailingAllocator)" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    _ = try addObserver(&data, 0, 0, 10, 0, .player, .{});
    _ = try addAgent(&data, 10, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    // Warm up: one full serial run sizes every scratch buffer (candidates,
    // rows, event range scratch, range_take_counts, and the per-level
    // LOS-blocked bitmap cache) to steady state.
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});
    try testing.expect(sys.level_blocked.items.len > 0);
    try testing.expect(sys.level_blocked.items[0].valid);

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const original_system_allocator = sys.allocator;
    const original_events_allocator = events.stream.allocator;
    sys.allocator = failing.allocator();
    events.stream.allocator = failing.allocator();
    defer {
        sys.allocator = original_system_allocator;
        events.stream.allocator = original_events_allocator;
    }

    // The second run's ensureLevelBlockedCache call sees a step_counter
    // mismatch (a new step ran) and rebuilds level 0's bitmap contents, but
    // must not grow `level_blocked` or its `blocked` backing storage — this
    // proves the rebuild-every-touched-step design stays allocation-free,
    // not just the initial reserve.
    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});
    try testing.expectEqual(@as(usize, 1), stats.observer_count);
}

test "PerceptionSystem threaded update has no steady-state allocation after warmup, multi-range (FailingAllocator)" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    // Enough observers to force multiple ranges under items_per_range ==
    // perception_range_alignment_items, exercising prepareEventRangeBuffers's
    // and prepareRangeStats's multi-slot growth loops (only reachable when
    // range_count > 1), which the serial-only proof above never touches.
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    for (0..40) |i| {
        const fi: f32 = @floatFromInt(i);
        const faction: Faction = if (i % 3 == 0) .hostile else .player;
        _ = try addAgent(&data, fi * 6, 0, 0, 0, faction);
    }
    for (0..40) |i| {
        const fi: f32 = @floatFromInt(i);
        _ = try addObserver(&data, fi * 6 + 3, 4, 1, 1, .player, .{ .fov_half_angle_radians = std.math.pi / 2.0, .vision_range = 100 });
    }

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 512, 64, 32);
    defer world.deinit();

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2, .items_per_range = perception_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const config = PerceptionConfig{
        .items_per_range = perception_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    };

    // Warm up: one full threaded run sizes every scratch buffer (candidates,
    // rows, per-range event buffers, per-range stats, range_take_counts, and
    // the per-level LOS-blocked bitmap cache) to steady state at range_count
    // > 1.
    const warmup_stats = try sys.update(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, &threads, config);
    try testing.expect(warmup_stats.batch.range_count > 1);
    try testing.expect(sys.level_blocked.items.len > 0);
    try testing.expect(sys.level_blocked.items[0].valid);

    // Mirror the real per-frame lifecycle (SimulationFrame.beginStep) that
    // resets `events` to steady-state-retained-capacity before every step;
    // without this, `events.range_stats`'s own first_range bookkeeping would
    // keep growing across steps regardless of this system's allocation
    // behavior, which is not what this proof is about.
    events.clearRetainingCapacity();

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const original_system_allocator = sys.allocator;
    const original_events_allocator = events.stream.allocator;
    sys.allocator = failing.allocator();
    events.stream.allocator = failing.allocator();
    defer {
        sys.allocator = original_system_allocator;
        events.stream.allocator = original_events_allocator;
    }

    const stats = try sys.update(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, &threads, config);
    try testing.expectEqual(@as(usize, 40), stats.observer_count);
    try testing.expect(stats.batch.range_count > 1);
}
