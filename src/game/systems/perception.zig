// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! AI perception substrate: gathers the cognition-scoped subset of
//! AI agents that also carry an `AiPerception` component, queries the shared
//! `SpatialIndexSystem` for nearby hostile candidates, applies a
//! squared-form field-of-view test and a bounded line-of-sight raycast, and
//! writes the winning `nearest_threat`/`target_visible`/`last_seen_x/y`/
//! `facing_x/y` hot columns back onto `DataSystem`'s `PerceptionStore`.
//! Emits `entity_perceived`/`entity_lost` `SimulationEvent`s on transitions,
//! derived on the main thread after the parallel compute pass from the
//! per-row `prev_*`/`final_nearest_threat_*` columns the workers already
//! write (`emitTransitionEvents`) — no per-range event scratch.
//!
//! Two-index-space contract (population-domain equivalence with
//! `spatial_index.zig`, mirrors `ai.zig`'s cross-file contract): this
//! system's own gather is a FILTERED SUBSET of the scoped population (only
//! entities that also carry `AiPerception`), so it cannot reuse its own row
//! index as `SpatialIndexView.queryNeighbors`'s self-exclusion index. Instead
//! it duplicates the same scoped walk `SpatialIndexSystem`/`AiSystem` use
//! (`candidate_dense_indices`/`scope_dense_indices` +
//! `movementBodyDenseIndex(entity) orelse continue`, identical skip, identical
//! order) to build a `candidates` side table (entity/faction/level) aligned 1:1
//! with `spatial`'s own row order, and records each observer row's position in
//! *that* full-population walk as `spatial_self_index` — the value actually
//! passed to `queryNeighbors`. Pipeline passes the unstaggered halo as
//! `candidate_dense_indices` and the think set as `scope_dense_indices`; a null
//! candidate list walks `scope_dense_indices` for both (tests / benches).
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
//! sign-split) is not supported.
//!
//! Scalar exceptions (each documented again at its call site): the spatial
//! cell-scan traversal and stance lookup (shared spatial-index infra; branchy and a
//! 4-value enum table index, not float math), the small (<= 17) per-agent
//! nearest-candidate sort (irreducibly small/branchy, does not scale with
//! population), and the bounded LOS raycast (early-exit grid/DDA walk, one
//! scattered cell lookup per visited cell). The per-cell blocked test reads
//! the world's chunk terrain directly (`WorldSystem.levelBlocksMovement`,
//! O(1): the chunk's composed-bits entry plus one bit), so perception keeps
//! no LOS state and a same-step terrain edit occludes with no reaction.
//!
//! Threaded writes: each worker range writes only its own gather rows' hot
//! columns in `PerceptionStore` and its rows' `final_nearest_threat_*`
//! columns (disjoint per entity, since gather rows are 1:1 with entities and
//! ranges partition row indices), plus its own padded `range_stats` slot,
//! which also tallies the range's transition-event count. Nothing appendable
//! is shared, so nothing partition-sized needs reserving. After the join the
//! main thread derives the events from the now-immutable `prev_*`/`final_*`
//! columns in row order and appends them as one range
//! (`emitTransitionEvents`); concatenating ranges in ascending order already
//! equals row order, so this is byte-identical to the former per-range merge.
//! Serial and threaded paths share every vectorized helper
//! (`computeFacingDense`, `filterFovSurvivors`, the transition `equalInt4`
//! pass) and the same per-range compute function
//! (`computePerceptionRange`) — see the serial/threaded parity test.

const std = @import("std");
const builtin = @import("builtin");
const math = @import("../../core/math.zig");
const logging = @import("../../core/logging.zig");
const simd = @import("../../core/simd.zig");
const stance = @import("../faction.zig").stance;
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const AdaptiveWorkTunerConfig = @import("../../app/thread_system.zig").AdaptiveWorkTunerConfig;
const BatchSelection = @import("../../app/thread_system.zig").BatchSelection;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const alignItemCount = @import("../../app/thread_system.zig").alignItemCount;
const maxRangeCount = @import("../../app/thread_system.zig").maxRangeCount;
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
const WorldStimulus = @import("../simulation.zig").WorldStimulus;
const stimulusHearingScore = @import("../simulation.zig").stimulusHearingScore;
const spatial_index_mod = @import("spatial_index.zig");
const SpatialIndexView = spatial_index_mod.SpatialIndexView;
const NeighborVisitResult = spatial_index_mod.NeighborVisitResult;

pub const perception_range_alignment_items: usize = movement_range_alignment_items;

// Range alignment only; batch time gate comes from AdaptiveWorkTunerConfig defaults.
const perception_adaptive_tuner_config = AdaptiveWorkTunerConfig{
    .initial_range_items = 64,
    .smallest_range_items = perception_range_alignment_items,
};

fn hotStoreCapacity(min_len: usize) usize {
    return alignItemCount(min_len, perception_range_alignment_items);
}

// Mirrors ai.zig's max_separation_neighbors/max_separation_candidate_checks
// shape: a small fixed candidate buffer bounded by a scan-cost ceiling.
const max_perception_candidates: u8 = 16;
// Runtime perf logging (perception_candidate_checks) measured ~32 candidate
// visits/observer on average in a populated demo, ~94% rejected by the
// stance filter (mostly same-faction, e.g. cohere-clustered) before ever
// reaching sensed_count -- the query pays their dx/dy/dist2 cost regardless
// of rejection. 64 (mirrors ai.zig's max_cohere_candidate_checks, half of
// max_separation_candidate_checks) keeps ~2x headroom over the observed
// average while bounding the worst case a dense same-faction cluster can
// force onto one observer's query, instead of leaving it at 128 (~4x
// headroom) with no measured need for that much slack.
const max_perception_candidate_checks: u16 = 64;
const max_perception_scratch: usize = max_perception_candidates + 1; // + player

// "Moving" gate for facing derivation: 1.0 units/sec, compared against
// speed-squared so the dense pass never needs a sqrt to decide.
const facing_speed_squared_threshold: f32 = 1.0;
const facing_normalize_epsilon: f32 = 1.0e-6;

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
    /// Think/observer set: dense ai-store indices that may write `PerceptionStore`
    /// this step (stagger-filtered cognition). Null = all agents on the single-list
    /// path, or all halo rows when `candidate_dense_indices` is set. Pipeline
    /// passes `ai_cognition_indices`.
    scope_dense_indices: ?[]const u32 = null,
    /// Halo/candidate set: unstaggered cognition-halo indices walked into
    /// `candidates` (1:1 with spatial rows). Null = walk `scope_dense_indices`
    /// for both candidates and observers (single-list tests / benches). Pipeline
    /// always passes `ai_halo_indices`.
    candidate_dense_indices: ?[]const u32 = null,
    /// Optional player entity, resolved by the caller once per step (null if
    /// no player entity exists yet).
    player_candidate: ?PlayerPerceptionCandidate = null,
    /// This step's merged world stimuli (`frame.stimuli.mergedItems()`), read
    /// by the hearing pass folded into `computeOneAgent`.
    stimuli: []const WorldStimulus = &.{},
    /// Deterministic per-step cap on emitted perception events, enforced by
    /// this system itself in row order (see the module doc's threaded-writes
    /// note and `emitTransitionEvents`) rather than letting
    /// `SimulationEvents`'s own capacity check throw.
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
    // `PerceptionRangeStats`. These make the LOS volume visible to
    // `src/benchmarks/perception.zig` rather than hide it inside aggregate
    // step timing.
    los_checks: usize = 0,
    los_blocked: usize = 0,
    // Total spatial-index candidates visited across every observer this step,
    // hostile-stance or not (mirrors `ai_separation_candidate_checks`) —
    // isolates the query's own traversal cost from `sensed_count`'s
    // post-FOV-filter selectivity signal, so a locally dense same-faction
    // cluster that gets visited-then-rejected by the stance check is visible
    // here even though it never reaches `sensed_count`.
    candidate_checks: usize = 0,
    perceived_events: usize = 0,
    lost_events: usize = 0,
    dropped_events: usize = 0,
    batch: BatchStats = .{},
};

// Per-range accumulator for the LOS/sensed/found counters above and the
// range's transition-event count. Each range job owns one slot (indexed by
// `range.index`), writes to a local `PerceptionRangeStats` value throughout
// its own `computeOneAgent` calls, and stores it once at the end of
// `computePerceptionRange` — a single write per range, so no atomics are
// needed. It is 48 bytes (6 `usize` fields), so two adjacent slots would
// otherwise share a 64-byte cache line; concurrently running worker ranges
// writing their final stats into adjacent slots would then false-share that
// line, so `PerceptionRangeStatsSlot` pads each slot to a full line.
const PerceptionRangeStats = struct {
    sensed_count: usize = 0,
    nearest_threat_found: usize = 0,
    los_checks: usize = 0,
    los_blocked: usize = 0,
    // Total spatial-index candidates visited across every observer this range
    // processed, hostile-stance or not (mirrors `ai_separation_candidate_checks`
    // in `ai.zig`) -- distinct from `sensed_count` (post-FOV survivors): this
    // counts the query's own traversal cost before any stance/FOV filtering,
    // so a locally dense same-faction cluster (e.g. cohere-formed) that gets
    // visited-then-rejected shows up here even though it never reaches
    // `sensed_count`.
    candidate_checks: usize = 0,
    // Uncapped `entity_lost` + `entity_perceived` events this range's rows
    // will produce (`transitionEventCount`), counted by the worker on the row
    // it just wrote so the main-thread emit (`emitTransitionEvents`) knows the
    // step total, and so the cap, before it walks the columns.
    transition_events: usize = 0,
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
    hearing_range: f32,
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

const PerceptionRangeStatsSlot = struct {
    // Each worker writes only its assigned slot, once, at the end of its
    // range (see `PerceptionRangeStats`'s doc comment). Padding keeps that
    // write off shared cache lines across concurrently running ranges.
    stats: PerceptionRangeStats = .{},
    padding: [paddingForCacheLine(PerceptionRangeStats)]u8 = @splat(0),
};

const PerceptionRangeStatsSlotList = std.ArrayListAligned(PerceptionRangeStatsSlot, .fromByteUnits(thread_shared_record_alignment));

fn paddingForCacheLine(comptime T: type) usize {
    const rem = @sizeOf(T) % thread_shared_record_alignment;
    return if (rem == 0) 0 else thread_shared_record_alignment - rem;
}

fn serialBatch(count: usize) BatchStats {
    return .{ .ran_inline = true, .item_count = count, .range_count = if (count > 0) 1 else 0, .items_per_range = count };
}

pub const PerceptionSystem = struct {
    allocator: std.mem.Allocator,
    // Gathered work memory (main-thread only; workers read only copies in
    // job context, except their own rows' `final_nearest_threat_*` columns
    // and their own padded `range_stats` slot).
    candidates: std.MultiArrayList(CandidateRow) = .{},
    rows: std.MultiArrayList(PerceptionGatherRow) = .{},
    range_stats: PerceptionRangeStatsSlotList = .empty,
    /// Once-only flag for the emit-cap drop warn. The pipeline's derived share makes a
    /// drop impossible by construction; the cap and `dropped_events` stay as the
    /// shared-frame safety net.
    dropped_events_warned: bool = false,
    compute_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(perception_adaptive_tuner_config),
    pub fn init(allocator: std.mem.Allocator) PerceptionSystem {
        return .{
            .allocator = allocator,
            .compute_tuner = AdaptiveWorkTuner.init(perception_adaptive_tuner_config),
        };
    }

    pub fn deinit(self: *PerceptionSystem) void {
        self.range_stats.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.candidates.deinit(self.allocator);
        self.* = undefined;
    }

    /// Sizes candidate/observer rows and the per-range stats tallies
    /// (`maxRangeCount`, every partition the tuner can pick) for `pop` agents;
    /// nothing partition-sized remains, so `update`/`updateSerial` allocate
    /// nothing after this under any `items_per_range`. Grow-only; re-run by
    /// the pipeline's population seam.
    pub fn reserve(self: *PerceptionSystem, pop: usize) !void {
        if (pop == 0) return;
        const cap = hotStoreCapacity(pop);
        try self.candidates.ensureTotalCapacity(self.allocator, cap);
        try self.rows.ensureTotalCapacity(self.allocator, cap);
        try self.prepareRangeStats(maxRangeCount(cap, perception_range_alignment_items));
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
        try self.gatherPerceptionData(ai_agents, movement, data, perception_slice, config.scope_dense_indices, config.candidate_dense_indices);
        const observer_count = self.rows.len;
        if (observer_count == 0) return .{ .candidate_population_count = self.candidates.len };

        // Population-domain contract with spatial_index.zig (see module doc):
        // the shared index built for this step must have gathered the
        // identical row count as this system's own full-population candidate
        // walk. Debug/ReleaseSafe-only guard, compiles out in ReleaseFast.
        std.debug.assert(self.candidates.len == spatial.pos_x.len);

        self.computeFacingDense(perception_slice);

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
        // Grow-only safety net for unreserved standalone use; after `reserve`
        // it never allocates (`selection.range_count <= maxRangeCount(cap, 16)`).
        try self.prepareRangeStats(selection.range_count);

        var job = self.buildJobContext(perception_slice, spatial, world, config.player_candidate, config.stimuli, selection.range_count);
        const batch = thread_system.parallelForWithOptions(observer_count, &job, writePerceptionRangeJob, .{
            .max_worker_threads = selection.worker_threads,
            .range_alignment_items = perception_range_alignment_items,
            .adaptive_tuner = selection.active_tuner,
            .selected_profile = selection.profile,
        });

        const totals = self.sumRangeStats(selection.range_count);
        const merge = try self.emitTransitionEvents(&job, events, totals.transition_events, config.max_events_per_step);
        return .{
            .observer_count = observer_count,
            .candidate_population_count = self.candidates.len,
            .sensed_count = totals.sensed_count,
            .nearest_threat_found_count = totals.nearest_threat_found,
            .los_checks = totals.los_checks,
            .los_blocked = totals.los_blocked,
            .candidate_checks = totals.candidate_checks,
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
        try self.gatherPerceptionData(ai_agents, movement, data, perception_slice, config.scope_dense_indices, config.candidate_dense_indices);
        const observer_count = self.rows.len;
        if (observer_count == 0) return .{ .candidate_population_count = self.candidates.len };

        std.debug.assert(self.candidates.len == spatial.pos_x.len);

        self.computeFacingDense(perception_slice);

        const range_count: usize = 1;
        try self.prepareRangeStats(range_count);

        var job = self.buildJobContext(perception_slice, spatial, world, config.player_candidate, config.stimuli, range_count);
        computePerceptionRange(&job, .{ .index = 0, .start = 0, .end = observer_count });

        const totals = self.sumRangeStats(range_count);
        const merge = try self.emitTransitionEvents(&job, events, totals.transition_events, config.max_events_per_step);
        return .{
            .observer_count = observer_count,
            .candidate_population_count = self.candidates.len,
            .sensed_count = totals.sensed_count,
            .nearest_threat_found_count = totals.nearest_threat_found,
            .los_checks = totals.los_checks,
            .los_blocked = totals.los_blocked,
            .candidate_checks = totals.candidate_checks,
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
        stimuli: []const WorldStimulus,
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
            .hearing_range = rows.items(.hearing_range),
            .stimuli = stimuli,
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
            .player_candidate = player_candidate,
            .range_stats = self.range_stats.items[0..range_count],
        };
    }

    // Population-domain contract with spatial_index.zig/ai.zig (see module
    // doc): walks `candidate_dense_indices` (halo) or `scope_dense_indices`
    // (single-list / all agents) resolving `data.movementBodyDenseIndex(entity)
    // orelse continue`, in the exact same order SpatialIndexSystem's own gather
    // does — a deliberate duplicate gather, not shared code, so `candidates`
    // row `i` and `spatial`'s row `i` refer to the same agent. Observer rows
    // are the subset that carry `AiPerception` and, on the dual-list path,
    // also appear in the think set (`scope_dense_indices`, two-pointer).
    fn gatherPerceptionData(
        self: *PerceptionSystem,
        ai_agents: ConstAiAgentSlice,
        movement: ConstMovementBodySlice,
        data: *const DataSystem,
        perception_slice: PerceptionSlice,
        scope_dense_indices: ?[]const u32,
        candidate_dense_indices: ?[]const u32,
    ) !void {
        self.clearWork();
        const spatial_indices = candidate_dense_indices orelse scope_dense_indices;
        const think_indices: ?[]const u32 = if (candidate_dense_indices) |halo|
            (scope_dense_indices orelse halo)
        else
            spatial_indices;
        const n = if (spatial_indices) |idx| idx.len else ai_agents.entities.len;
        if (n == 0) return;
        const observer_cap = if (think_indices) |idx| idx.len else n;
        try self.candidates.ensureTotalCapacity(self.allocator, hotStoreCapacity(n));
        try self.rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(observer_cap));

        var candidate_slice = self.candidates.slice();
        var row_slice = self.rows.slice();
        var k: usize = 0;
        var think_k: usize = 0;
        var spatial_row_index: usize = 0;
        while (k < n) : (k += 1) {
            const i: usize = if (spatial_indices) |idx| idx[k] else k;
            const ai_index: u32 = @intCast(i);
            const ent = ai_agents.entities[i];
            const mi = data.movementBodyDenseIndex(ent) orelse {
                if (think_indices) |think| {
                    if (think_k < think.len and think[think_k] == ai_index) think_k += 1;
                }
                continue;
            };

            const ent_faction = data.factionConst(ent) orelse .neutral;
            const ent_level = data.worldLevelConst(ent) orelse 0;
            appendCandidateRow(&self.candidates, &candidate_slice, .{
                .entity = ent,
                .faction = ent_faction,
                .level = ent_level,
            });

            const in_think_set = if (think_indices) |think|
                think_k < think.len and think[think_k] == ai_index
            else
                true;
            if (in_think_set) {
                if (think_indices != null) think_k += 1;
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
                        .hearing_range = perception_slice.hearing_range[perception_index],
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
            }

            spatial_row_index += 1;
        }
        if (think_indices) |think| std.debug.assert(think_k == think.len);
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

    // Sizes/resets `range_stats` to `range_count` slots before dispatch
    // (reserve-before-dispatch), so every range job has a pre-existing slot to
    // write its single accumulated `PerceptionRangeStats` value into.
    fn prepareRangeStats(self: *PerceptionSystem, range_count: usize) !void {
        try self.range_stats.ensureTotalCapacity(self.allocator, range_count);
        while (self.range_stats.items.len < range_count) self.range_stats.appendAssumeCapacity(.{});
        for (self.range_stats.items[0..range_count]) |*slot| slot.stats = .{};
    }

    fn sumRangeStats(self: *const PerceptionSystem, range_count: usize) PerceptionRangeStats {
        var totals = PerceptionRangeStats{};
        for (self.range_stats.items[0..range_count]) |slot| {
            totals.sensed_count += slot.stats.sensed_count;
            totals.nearest_threat_found += slot.stats.nearest_threat_found;
            totals.los_checks += slot.stats.los_checks;
            totals.los_blocked += slot.stats.los_blocked;
            totals.candidate_checks += slot.stats.candidate_checks;
            totals.transition_events += slot.stats.transition_events;
        }
        return totals;
    }

    /// Main-thread transition emit after the parallel/serial compute pass.
    /// `total` is the workers' uncapped event count
    /// (`PerceptionRangeStats.transition_events`); this system's own
    /// deterministic per-step cap keeps the first `max_events_per_step` in
    /// row order (`entity_lost` before `entity_perceived` within a row),
    /// truncating the tail rather than letting `SimulationEvents`'s own
    /// capacity check throw. One pass over the immutable `prev_*`/`final_*`
    /// columns (`simd.equalInt4`, scalar tail) writes them as one range; the
    /// pass is skipped outright when nothing is emitted. Row order equals the
    /// former range-ascending concatenation, so the output is byte-identical
    /// under every partition.
    fn emitTransitionEvents(
        self: *PerceptionSystem,
        job: *const PerceptionJobContext,
        events: *SimulationEvents,
        total: usize,
        max_events_per_step: usize,
    ) !PerceptionEventMergeResult {
        const capped_total = @min(total, max_events_per_step);
        const dropped = total - capped_total;

        const first_range = try events.appendRangeCounts(1);
        events.addCount(first_range, capped_total);
        try events.prefixAppendedRanges(first_range);

        var sink = TransitionSink{ .writer = events.rangeWriter(first_range), .remaining = capped_total };
        if (capped_total > 0) {
            const n = job.entities.len;
            const prev_index = job.prev_nearest_threat_index;
            const prev_generation = job.prev_nearest_threat_generation;
            const final_index = job.final_nearest_threat_index;
            const final_generation = job.final_nearest_threat_generation;
            var i: usize = 0;
            const vend = simd.vectorizedEnd(n);
            while (i < vend and sink.remaining > 0) : (i += simd.lane_count) {
                const idx_equal = simd.equalInt4(simd.loadInt4(prev_index[i..]), simd.loadInt4(final_index[i..]));
                const gen_equal = simd.equalInt4(simd.loadInt4(prev_generation[i..]), simd.loadInt4(final_generation[i..]));
                const unchanged = idx_equal & gen_equal;
                inline for (0..simd.lane_count) |lane| {
                    if (!unchanged[lane]) {
                        sink.write(
                            job.entities[i + lane],
                            reconstructEntityId(prev_index[i + lane], prev_generation[i + lane]),
                            reconstructEntityId(final_index[i + lane], final_generation[i + lane]),
                        );
                    }
                }
            }
            while (i < n and sink.remaining > 0) : (i += 1) {
                if (prev_index[i] != final_index[i] or prev_generation[i] != final_generation[i]) {
                    sink.write(
                        job.entities[i],
                        reconstructEntityId(prev_index[i], prev_generation[i]),
                        reconstructEntityId(final_index[i], final_generation[i]),
                    );
                }
            }
        }
        // Declared count == written count: `sink` stops at exactly
        // `capped_total` because the workers' tally and this pass read the
        // same immutable columns (`RangeWriter.finish` asserts it).
        sink.writer.finish();
        events.finishWrite();
        events.stats.dropped += dropped;
        if (dropped > 0 and !self.dropped_events_warned) {
            self.dropped_events_warned = true;
            if (comptime logging.enabled(.warn) and !builtin.is_test) logging.game.warn(
                "perception: {d} events dropped past the per-step share of {d}",
                .{ dropped, max_events_per_step },
            );
        }

        return .{ .perceived = sink.perceived, .lost = sink.lost, .dropped = dropped };
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
    hearing_range: []const f32,
    stimuli: []const WorldStimulus,
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
    player_candidate: ?PlayerPerceptionCandidate,
    range_stats: []PerceptionRangeStatsSlot,
};

fn writePerceptionRangeJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *PerceptionJobContext = @ptrCast(@alignCast(context));
    // Dual worker asserts (mirror affect.zig / collision.zig): range.index vs
    // dispatched range count AND range.end vs the observer buffer this job walks.
    // Guards the reserve-before-dispatch invariant: prepareRangeStats must
    // have sized range_stats to at least this dispatch's range count.
    std.debug.assert(range.index < job.range_stats.len);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.entities.len);
    computePerceptionRange(job, range);
}

/// Shared per-range compute: scalar per-agent neighbor query/FOV/LOS/writeback
/// (`computeOneAgent`), then a tally of the transition events the row just
/// written will produce (`transitionEventCount`); the events themselves are
/// emitted after the join by `PerceptionSystem.emitTransitionEvents`. Called
/// identically by the threaded dispatch and the serial single-range path —
/// see the module doc's serial/threaded parity note.
fn computePerceptionRange(job: *PerceptionJobContext, range: ParallelRange) void {
    // Local accumulator, not a pointer into job.range_stats: only one write
    // (below) ever lands per range, so concurrently running ranges never
    // touch each other's slot mid-accumulation.
    var range_stats = PerceptionRangeStats{};
    for (range.start..range.end) |i| {
        computeOneAgent(job, i, &range_stats);
        range_stats.transition_events += transitionEventCount(
            reconstructEntityId(job.prev_nearest_threat_index[i], job.prev_nearest_threat_generation[i]),
            reconstructEntityId(job.final_nearest_threat_index[i], job.final_nearest_threat_generation[i]),
        );
    }
    job.range_stats[range.index].stats = range_stats;
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

/// Scalar: the spatial cell-scan traversal itself (shared spatial-index infra) and
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

// Branchy comparator resolving an entity per compare. Scalar: each observer
// sorts at most max_perception_scratch survivors, a tiny batch; total work
// grows with observers, which the threaded perception ranges spread.
fn survivorLessThan(ctx: SurvivorSortContext, lhs: usize, rhs: usize) bool {
    const lhs_dist2 = ctx.scratch.dist2[lhs];
    const rhs_dist2 = ctx.scratch.dist2[rhs];
    if (lhs_dist2 != rhs_dist2) return lhs_dist2 < rhs_dist2;
    return resolveCandidate(ctx, lhs).entity.index < resolveCandidate(ctx, rhs).entity.index;
}

// One ray's cell reads on one level, resolved once per ray. Out-of-world cells
// block (fail closed). `across_*` offsets to the cell across the grid line a ray
// runs exactly along (0, 0 when it runs along none).
const RayCells = struct {
    terrain: WorldSystem.LevelBlockedView,
    width: i32,
    height: i32,
    across_x: i32,
    across_y: i32,

    fn blocked(self: RayCells, x: i32, y: i32) bool {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return true;
        // In [0, width) x [0, height) per the check above, so both fit u16.
        const cell_x: u16 = @intCast(x);
        const cell_y: u16 = @intCast(y);
        return self.terrain.blocked.get(self.terrain.geom.chunkOf(cell_x, cell_y), self.terrain.geom.localOf(cell_x, cell_y));
    }

    // The cell across the ray's grid line; a line on the world edge has none.
    fn acrossBlocked(self: RayCells, x: i32, y: i32) bool {
        if (self.across_x == 0 and self.across_y == 0) return false;
        const across_x = x + self.across_x;
        const across_y = y + self.across_y;
        if (across_x < 0 or across_y < 0) return false;
        return self.blocked(across_x, across_y);
    }
};

/// LOS raycast: a grid walk from the observer's cell to the target's cell that
/// checks every cell the segment touches after leaving the observer, exiting on
/// the first blocked one. The observer's own cell is never checked; the
/// target's is.
/// - Through an exact grid corner, both side cells are checked before the
///   diagonal step, so a ray never slips between two blocked cells that meet at
///   a corner (pathfinding's no-corner-cutting rule).
/// - A ray running exactly along a grid line also checks the in-world cells
///   across the line.
/// With both endpoint cells open (and endpoints off grid corners), A to B
/// equals B to A. Crossing order compares f64 products of boundary distances,
/// exact for cell-aligned endpoints, so corner ties are found exactly and
/// nothing accumulates along the ray. An axis step visits one cell and a corner
/// step two, so an arriving walk takes exactly |dcx| + |dcy| visits; one that
/// has not arrived by then fails closed. The level's blocked bits are resolved
/// once per ray; an invalid level or a point off the world is blocked. Scalar:
/// one branchy, scattered lookup per cell.
fn hasLineOfSight(world: *const WorldSystem, level: u16, ox: f32, oy: f32, tx: f32, ty: f32) bool {
    if (ox == tx and oy == ty) return true;

    const terrain = world.levelBlockedView(level) orelse return false;
    const start_cell = world.cellContaining(ox, oy) orelse return false;
    const end_cell = world.cellContaining(tx, ty) orelse return false;

    const tile_size = world.tile_size;
    // A ray on a vertical (horizontal) grid line touches the column (row) across
    // it; `cellContaining` puts the ray's own cells right of (below) the line.
    const cells = RayCells{
        .terrain = terrain,
        .width = world.width,
        .height = world.height,
        .across_x = if (ox == tx and @mod(ox, tile_size) == 0) -1 else 0,
        .across_y = if (oy == ty and @mod(oy, tile_size) == 0) -1 else 0,
    };

    var cell_x: i32 = start_cell.x;
    var cell_y: i32 = start_cell.y;
    const end_x: i32 = end_cell.x;
    const end_y: i32 = end_cell.y;
    if (cells.acrossBlocked(cell_x, cell_y)) return false;
    if (cell_x == end_x and cell_y == end_y) return !cells.blocked(end_x, end_y);

    const step_x: i32 = if (tx > ox) 1 else if (tx < ox) -1 else 0;
    const step_y: i32 = if (ty > oy) 1 else if (ty < oy) -1 else 0;
    const origin_x: f64 = ox;
    const origin_y: f64 = oy;
    const extent_x: f64 = @abs(@as(f64, tx) - origin_x);
    const extent_y: f64 = @abs(@as(f64, ty) - origin_y);
    const tile: f64 = tile_size;
    const ray_cell_count: u32 = @abs(end_x - cell_x) + @abs(end_y - cell_y);

    var visited: u32 = 0;
    while (visited < ray_cell_count) {
        // Distance to the next grid line on each axis; the ray crosses x first
        // when to_x / extent_x < to_y / extent_y, compared without dividing. An
        // axis the ray never crosses is infinitely far (its extent is 0, so the
        // other product is 0).
        const to_x: f64 = if (step_x > 0)
            @as(f64, @floatFromInt(cell_x + 1)) * tile - origin_x
        else if (step_x < 0)
            origin_x - @as(f64, @floatFromInt(cell_x)) * tile
        else
            std.math.inf(f64);
        const to_y: f64 = if (step_y > 0)
            @as(f64, @floatFromInt(cell_y + 1)) * tile - origin_y
        else if (step_y < 0)
            origin_y - @as(f64, @floatFromInt(cell_y)) * tile
        else
            std.math.inf(f64);
        const cross_x = to_x * extent_y;
        const cross_y = to_y * extent_x;
        if (cross_x < cross_y) {
            cell_x += step_x;
            visited += 1;
        } else if (cross_y < cross_x) {
            cell_y += step_y;
            visited += 1;
        } else {
            // Exact corner. Its side cells touch the ray unless the corner is the
            // observer's own point.
            if (to_x > 0 and (cells.blocked(cell_x + step_x, cell_y) or cells.blocked(cell_x, cell_y + step_y))) return false;
            cell_x += step_x;
            cell_y += step_y;
            visited += 2;
        }
        if (cells.blocked(cell_x, cell_y) or cells.acrossBlocked(cell_x, cell_y)) return false;
        if (cell_x == end_x and cell_y == end_y) return true;
    }
    return false;
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
    const query_stats = job.spatial.queryNeighbors(
        ox,
        oy,
        self_index,
        scan_radius,
        .{ .radius = vision_range, .max_candidate_checks = max_perception_candidate_checks },
        &visit_ctx,
        perceptionNeighborVisit,
    );
    range_stats.candidate_checks += query_stats.candidate_checks;

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

    // Scalar: a branchy walk with a data-dependent LOS raycast per candidate,
    // over at most max_perception_scratch survivors per observer; total work
    // grows with observers, which the threaded perception ranges spread.
    for (survivors[0..survivor_count]) |slot| {
        const resolved = resolveCandidate(sort_ctx, slot);
        if (resolved.level != observer_level) continue;
        const tx = ox + scratch.to_x[slot];
        const ty = oy + scratch.to_y[slot];
        range_stats.los_checks += 1;
        if (hasLineOfSight(job.world, observer_level, ox, oy, tx, ty)) {
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

    const hearing_range = job.hearing_range[i];
    const hearing_range_sq = hearing_range * hearing_range;
    var heard_stimulus = false;
    var heard_x: f32 = 0;
    var heard_y: f32 = 0;
    // Soft ranking: max intensity / (1 + dist2 * k) among same-level
    // stimuli inside the hard hearing range. Equal intensities reduce to nearest.
    // Kind is not stored on perception columns — bus-only metadata.
    var best_score = -std.math.inf(f32);
    var best_dist2 = std.math.inf(f32);
    for (job.stimuli) |stim| {
        if (stim.level != observer_level) continue;
        if (stim.intensity <= 0) continue;
        const dist2 = math.lengthSquared(.{ .x = stim.position.x - ox, .y = stim.position.y - oy });
        if (dist2 > hearing_range_sq) continue;
        const score = stimulusHearingScore(stim.intensity, dist2);
        if (score > best_score or (score == best_score and dist2 < best_dist2)) {
            heard_stimulus = true;
            best_score = score;
            best_dist2 = dist2;
            heard_x = stim.position.x;
            heard_y = stim.position.y;
        }
    }
    job.perception_slice.heard_stimulus[dense_index] = heard_stimulus;
    job.perception_slice.heard_stimulus_x[dense_index] = heard_x;
    job.perception_slice.heard_stimulus_y[dense_index] = heard_y;

    job.final_nearest_threat_index[i] = @bitCast(nearest_threat.index);
    job.final_nearest_threat_generation[i] = @bitCast(nearest_threat.generation);
}

fn reconstructEntityId(index_bits: i32, generation_bits: i32) EntityId {
    return .{ .index = @bitCast(index_bits), .generation = @bitCast(generation_bits) };
}

/// Transition rules (see module doc): invalid->valid emits only
/// `entity_perceived`; valid->invalid emits only `entity_lost`; a
/// valid->different-valid identity swap emits both, `entity_lost` (the
/// previous target) before `entity_perceived` (the new one), in that order.
/// `prev`/`final` bit-identical (including both invalid) emits nothing. This
/// count and `TransitionSink.write` encode the same rules, so the worker
/// tally and the main-thread emit agree exactly.
fn transitionEventCount(prev: EntityId, final: EntityId) usize {
    if (prev.index == final.index and prev.generation == final.generation) return 0;
    return @as(usize, @intFromBool(prev.isValid())) + @intFromBool(final.isValid());
}

/// Main-thread row-order writer for `emitTransitionEvents`: writes at most
/// `remaining` more events, so a swap truncated with one slot left keeps only
/// its `entity_lost` (the same within-row write-order truncation the former
/// per-range merge applied).
const TransitionSink = struct {
    writer: SimulationEvents.RangeWriter,
    remaining: usize,
    perceived: usize = 0,
    lost: usize = 0,

    fn write(self: *TransitionSink, observer: EntityId, prev: EntityId, final: EntityId) void {
        if (prev.isValid() and self.remaining > 0) {
            self.writer.write(.{ .stage = .domain_reaction, .payload = .{ .entity_lost = .{ .observer = observer, .target = prev } } });
            self.remaining -= 1;
            self.lost += 1;
        }
        if (final.isValid() and self.remaining > 0) {
            self.writer.write(.{ .stage = .domain_reaction, .payload = .{ .entity_perceived = .{ .observer = observer, .target = final } } });
            self.remaining -= 1;
            self.perceived += 1;
        }
    }
};

const StageWorkSelection = BatchSelection;

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
    // Shapes work through the single tuner-owned entry point so pre-sizing and
    // dispatch (parallelForWithOptions) resolve an identical batch shape.
    return thread_system.selectBatchProfile(adaptive_tuner, .{
        .item_count = item_count,
        .items_per_range = items_per_range_override,
        .max_worker_threads = max_worker_threads_override,
        .range_alignment_items = perception_range_alignment_items,
        .adaptive = adaptive,
    });
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
    try data.setAiAgent(entity, .{ .active_behavior = .wander });
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
    try sys.reserve(ai_slice.entities.len, .{});
    _ = try sys.buildSerial(ai_slice, movement_slice, data, .{});
    return sys;
}

fn minimalWorld(allocator: std.mem.Allocator, width: u16, height: u16, tile_size: f32) !WorldSystem {
    var world = WorldSystem{
        .allocator = allocator,
        .width = width,
        .height = height,
        .tile_size = tile_size,
        .chunk_size_tiles = @import("../world_system.zig").max_chunk_size_tiles,
    };
    _ = try world.addLevel(0);
    return world;
}

test "perception production compute tuner uses central gate and range alignment" {
    var system = PerceptionSystem.init(std.testing.allocator);
    defer system.deinit();
    try std.testing.expectEqual((AdaptiveWorkTunerConfig{}).threaded_batch_ns, system.compute_tuner.config.threaded_batch_ns);
    try std.testing.expectEqual(@as(usize, 64), system.compute_tuner.config.initial_range_items);
    try std.testing.expectEqual(perception_range_alignment_items, system.compute_tuner.config.smallest_range_items);
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

test "think observer acquires an off-phase hostile from the halo candidate set" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    // Ally at the origin faces +x; hostile 40 units ahead. Halo is both rows;
    // only the ally thinks this step, so the hostile store must stay untouched.
    const ally = try addObserver(&data, 0, 0, 100, 0, .ally, .{});
    const hostile = try addObserver(&data, 40, 0, -100, 0, .hostile, .{});

    const halo = [_]u32{ 0, 1 };
    const think = [_]u32{0};
    var spatial_sys = SpatialIndexSystem.init(testing.allocator);
    defer spatial_sys.deinit();
    try spatial_sys.reserve(data.aiAgentSliceConst().entities.len, .{});
    _ = try spatial_sys.buildSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data, .{ .scope_dense_indices = &halo });

    var world = try minimalWorld(testing.allocator, 8, 8, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{
        .scope_dense_indices = &think,
        .candidate_dense_indices = &halo,
    });

    try testing.expectEqual(@as(usize, 1), stats.observer_count);
    try testing.expectEqual(@as(usize, 2), stats.candidate_population_count);

    const ally_perception = data.aiPerceptionConst(ally).?;
    try testing.expect(ally_perception.target_visible);
    try testing.expectEqual(hostile.index, ally_perception.nearest_threat.index);

    const hostile_perception = data.aiPerceptionConst(hostile).?;
    try testing.expect(!hostile_perception.target_visible);
    try testing.expectEqual(EntityId.invalid, hostile_perception.nearest_threat);
}

test "off-phase observer acquires the on-phase ally on the reverse think step" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const ally = try addObserver(&data, 0, 0, 100, 0, .ally, .{});
    const hostile = try addObserver(&data, 40, 0, -100, 0, .hostile, .{});

    const halo = [_]u32{ 0, 1 };
    const think = [_]u32{1};
    var spatial_sys = SpatialIndexSystem.init(testing.allocator);
    defer spatial_sys.deinit();
    try spatial_sys.reserve(data.aiAgentSliceConst().entities.len, .{});
    _ = try spatial_sys.buildSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data, .{ .scope_dense_indices = &halo });

    var world = try minimalWorld(testing.allocator, 8, 8, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{
        .scope_dense_indices = &think,
        .candidate_dense_indices = &halo,
    });

    const hostile_perception = data.aiPerceptionConst(hostile).?;
    try testing.expect(hostile_perception.target_visible);
    try testing.expectEqual(ally.index, hostile_perception.nearest_threat.index);

    const ally_perception = data.aiPerceptionConst(ally).?;
    try testing.expect(!ally_perception.target_visible);
    try testing.expectEqual(EntityId.invalid, ally_perception.nearest_threat);
}

test "gapped think set two-pointer assigns spatial_self_index for both observers" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    // Halo [A, B, C]; think [A, C] with off-phase B between them. Both on-phase
    // allies face the middle hostile.
    const a = try addObserver(&data, 0, 0, 100, 0, .ally, .{});
    const b = try addObserver(&data, 40, 0, 0, 0, .hostile, .{});
    const c = try addObserver(&data, 80, 0, -100, 0, .ally, .{});

    const halo = [_]u32{ 0, 1, 2 };
    const think = [_]u32{ 0, 2 };
    var spatial_sys = SpatialIndexSystem.init(testing.allocator);
    defer spatial_sys.deinit();
    try spatial_sys.reserve(data.aiAgentSliceConst().entities.len, .{});
    _ = try spatial_sys.buildSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data, .{ .scope_dense_indices = &halo });

    var world = try minimalWorld(testing.allocator, 8, 8, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{
        .scope_dense_indices = &think,
        .candidate_dense_indices = &halo,
    });

    try testing.expectEqual(@as(usize, 2), stats.observer_count);
    try testing.expectEqual(@as(usize, 3), stats.candidate_population_count);
    const self_index = sys.rows.slice().items(.spatial_self_index);
    try testing.expectEqual(@as(usize, 0), self_index[0]);
    try testing.expectEqual(@as(usize, 2), self_index[1]);

    try testing.expect(data.aiPerceptionConst(a).?.target_visible);
    try testing.expectEqual(b.index, data.aiPerceptionConst(a).?.nearest_threat.index);
    try testing.expect(data.aiPerceptionConst(c).?.target_visible);
    try testing.expectEqual(b.index, data.aiPerceptionConst(c).?.nearest_threat.index);
    try testing.expect(!data.aiPerceptionConst(b).?.target_visible);
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

test "candidate_checks counts every visited candidate, not just hostile-stance survivors" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 10, 0, .player, .{});
    _ = try addAgent(&data, 10, 0, 0, 0, .neutral);
    _ = try addAgent(&data, 12, 0, 0, 0, .ally);
    _ = try addAgent(&data, 14, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});

    // All 3 candidates (neutral, ally, hostile) sit within the query's scan
    // radius and get visited -- candidate_checks must see all of them, even
    // though only the hostile one survives the stance filter into sensed_count.
    try testing.expect(stats.candidate_checks >= 3);
    try testing.expectEqual(@as(usize, 1), stats.sensed_count);

    const perception = data.aiPerceptionConst(observer).?;
    try testing.expect(perception.target_visible);
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

test "hearing detects an in-range same-level stimulus" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 0, 0, .player, .{ .vision_range = 1, .hearing_range = 50 });

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stimuli = [_]WorldStimulus{.{ .position = .{ .x = 30, .y = 0 }, .intensity = 1, .kind = .dig, .level = 0 }};
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{ .stimuli = &stimuli });

    const perception = data.aiPerceptionConst(observer).?;
    try testing.expect(!perception.target_visible);
    try testing.expect(perception.heard_stimulus);
    try testing.expectEqual(@as(f32, 30), perception.heard_stimulus_x);
    try testing.expectEqual(@as(f32, 0), perception.heard_stimulus_y);
}

test "hearing ignores zero-intensity in-range stimulus" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 0, 0, .player, .{ .vision_range = 1, .hearing_range = 50 });

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stimuli = [_]WorldStimulus{.{ .position = .{ .x = 30, .y = 0 }, .intensity = 0, .kind = .dig, .level = 0 }};
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{ .stimuli = &stimuli });

    try testing.expect(!data.aiPerceptionConst(observer).?.heard_stimulus);
}

test "hearing ignores an out-of-range stimulus" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 0, 0, .player, .{ .vision_range = 1, .hearing_range = 50 });

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stimuli = [_]WorldStimulus{.{ .position = .{ .x = 100, .y = 0 }, .intensity = 1, .kind = .dig, .level = 0 }};
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{ .stimuli = &stimuli });

    try testing.expect(!data.aiPerceptionConst(observer).?.heard_stimulus);
}

test "hearing ignores a stimulus on a different level" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 0, 0, .player, .{ .vision_range = 1, .hearing_range = 50 });

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stimuli = [_]WorldStimulus{.{ .position = .{ .x = 30, .y = 0 }, .intensity = 1, .kind = .dig, .level = 1 }};
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{ .stimuli = &stimuli });

    try testing.expect(!data.aiPerceptionConst(observer).?.heard_stimulus);
}

test "hearing picks the nearest of multiple in-range stimuli" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 0, 0, .player, .{ .vision_range = 1, .hearing_range = 50 });

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stimuli = [_]WorldStimulus{
        .{ .position = .{ .x = 40, .y = 0 }, .intensity = 1, .kind = .dig, .level = 0 },
        .{ .position = .{ .x = 20, .y = 0 }, .intensity = 1, .kind = .dig, .level = 0 },
    };
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{ .stimuli = &stimuli });

    const perception = data.aiPerceptionConst(observer).?;
    try testing.expect(perception.heard_stimulus);
    try testing.expectEqual(@as(f32, 20), perception.heard_stimulus_x);
}

test "hearing intensity ranking prefers louder stimulus over nearer quieter one" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 0, 0, .player, .{ .vision_range = 1, .hearing_range = 100 });

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    // Near quiet footstep at x=10 vs far loud dig at x=50. With k = 1/256^2,
    // intensity dominates modest distance differences within range.
    const stimuli = [_]WorldStimulus{
        .{ .position = .{ .x = 10, .y = 0 }, .intensity = 0.35, .kind = .footstep, .level = 0 },
        .{ .position = .{ .x = 50, .y = 0 }, .intensity = 1.0, .kind = .dig, .level = 0 },
    };
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{ .stimuli = &stimuli });

    const perception = data.aiPerceptionConst(observer).?;
    try testing.expect(perception.heard_stimulus);
    // At k=1/65536: score(0.35, 100) ≈ 0.3495, score(1.0, 2500) ≈ 0.963 → dig wins.
    try testing.expectEqual(@as(f32, 50), perception.heard_stimulus_x);
}

test "hearing acquires non-dig footstep and impact kinds" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 0, 0, .player, .{ .vision_range = 1, .hearing_range = 50 });

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const foot = [_]WorldStimulus{.{ .position = .{ .x = 25, .y = 0 }, .intensity = 0.35, .kind = .footstep, .level = 0 }};
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{ .stimuli = &foot });
    try testing.expect(data.aiPerceptionConst(observer).?.heard_stimulus);
    try testing.expectEqual(@as(f32, 25), data.aiPerceptionConst(observer).?.heard_stimulus_x);

    // Clear heard by running with empty stimuli
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{ .stimuli = &.{} });
    try testing.expect(!data.aiPerceptionConst(observer).?.heard_stimulus);

    const impact = [_]WorldStimulus{.{ .position = .{ .x = 15, .y = 0 }, .intensity = 0.85, .kind = .impact, .level = 0 }};
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{ .stimuli = &impact });
    try testing.expect(data.aiPerceptionConst(observer).?.heard_stimulus);
    try testing.expectEqual(@as(f32, 15), data.aiPerceptionConst(observer).?.heard_stimulus_x);
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
    // nearer candidate but not the straight path down column 0 to the farther
    // one. (A diagonal to (2, 2) would graze the wall's corner and be blocked.)
    _ = try world.setDenseTile(layer, 1, 0, tree);

    const tile_size = world.tile_size;
    const nearer_blocked = try addAgent(&data, tile_size * 2.5, tile_size * 0.5, 0, 0, .hostile);
    const farther_clear = try addAgent(&data, tile_size * 0.5, tile_size * 3.5, 0, 0, .hostile);
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

test "LOS blocks a diagonal ray through a mid-segment occluder's interior, not just its corners" {
    // Regression for a grid-traversal gap: a fixed-step interpolation sampler
    // can jump from one sampled point to the next diagonally without ever
    // landing inside a cell the *continuous* segment's interior actually
    // crosses. Observer (0.7, 0.3) -> target (2.5, 2.1) in tile units is a
    // 45-degree ray (dx == dy == 1.8), but the asymmetric fractional start
    // offsets (0.7 vs 0.3) keep it off the exact grid-corner diagonal, so it
    // has a genuine interior span through cell (2, 1) for roughly
    // t in [0.72, 0.94] -- not the measure-zero corner graze the sibling
    // "skips a blocked nearer candidate" test above exercises (that one is
    // corner-exact: dx == dy with a zero start offset). A correct grid/DDA
    // walk must still visit (2, 1) even though no fixed-step sample at
    // t = 1/3, 2/3, 1 ever lands there.
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const asset_store = @import("../../assets/assets.zig").AssetStore.init(testing.allocator, testing.io, "assets");
    var meta = try @import("../../assets/world_tileset_meta.zig").load(
        testing.allocator,
        asset_store,
        @import("../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();

    // Large bounds keep this test's small (cells 0..2) coordinate area away
    // from `initDemoFromMeta`'s own fixed demo obstacles, same as the sibling
    // LOS test above.
    var world = try WorldSystem.initDemoFromMeta(testing.allocator, &meta, 1024, 1024);
    defer world.deinit();
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;
    const grass = (meta.tileByName("grass") orelse return error.TestExpectedEqual).id;
    const layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    _ = try world.setDenseTile(layer, 2, 1, tree);

    const tile_size = world.tile_size;
    const target = try addAgent(&data, tile_size * 2.5, tile_size * 2.1, 0, 0, .hostile);
    _ = target;
    const observer = try addObserver(&data, tile_size * 0.7, tile_size * 0.3, 1, 1, .player, .{
        .fov_half_angle_radians = std.math.pi / 2.0,
        .vision_range = tile_size * 10,
    });

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});

    const perception = data.aiPerceptionConst(observer).?;
    try testing.expect(!perception.target_visible);
    try testing.expectEqual(EntityId.invalid.index, perception.nearest_threat.index);
}

const WorldTilesetMeta = @import("../../assets/world_tileset_meta.zig").WorldTilesetMeta;
const ChunkForm = @import("../world_terrain.zig").ChunkForm;

fn loadTestTilesetMeta() !WorldTilesetMeta {
    const asset_store = @import("../../assets/assets.zig").AssetStore.init(testing.allocator, testing.io, "assets");
    return @import("../../assets/world_tileset_meta.zig").load(
        testing.allocator,
        asset_store,
        @import("../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
}

const ChunkedObstacleWorld = struct { world: WorldSystem, layer: usize };

// One level in `chunk_size_tiles` chunks with an all-open obstacle layer, so
// multi-chunk LOS tests shrink the chunk rather than grow the world.
fn chunkedObstacleWorld(meta: *const WorldTilesetMeta, width: u16, height: u16, chunk_size_tiles: u16) !ChunkedObstacleWorld {
    var world = WorldSystem{
        .allocator = testing.allocator,
        .width = width,
        .height = height,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = chunk_size_tiles,
    };
    errdefer world.deinit();
    try world.buildCatalog(meta);
    const level = try world.addLevel(0);
    const layer = try world.addDenseLayer(level, 0, .obstacle, try world.requireTileByName(meta, "grass"));
    return .{ .world = world, .layer = layer };
}

// Reference LOS: blocked when a cell that touches the closed segment at some
// t in (0, 1] blocks movement on `level`, skipping the observer's own cell
// unless the target shares it. That is the supercover past the observer:
// corner side cells and the cells across a grid line the ray runs along count.
fn bruteForceLineOfSight(world: *const WorldSystem, level: u16, ox: f32, oy: f32, tx: f32, ty: f32) bool {
    if (ox == tx and oy == ty) return true;
    const start = world.cellContaining(ox, oy).?;
    const end = world.cellContaining(tx, ty).?;
    const same_cell = start.x == end.x and start.y == end.y;
    const tile: f64 = world.tile_size;
    const origin = [2]f64{ ox, oy };
    const delta = [2]f64{ @as(f64, tx) - ox, @as(f64, ty) - oy };
    // One cell of margin covers the cells across a grid line.
    const min_x = @as(usize, @min(start.x, end.x)) -| 1;
    const min_y = @as(usize, @min(start.y, end.y)) -| 1;
    const max_x = @min(@as(usize, @max(start.x, end.x)) + 1, @as(usize, world.width) - 1);
    const max_y = @min(@as(usize, @max(start.y, end.y)) + 1, @as(usize, world.height) - 1);
    for (min_y..max_y + 1) |y| {
        for (min_x..max_x + 1) |x| {
            if (!same_cell and x == start.x and y == start.y) continue;
            const cell_min = [2]f64{ @as(f64, @floatFromInt(x)) * tile, @as(f64, @floatFromInt(y)) * tile };
            if (!segmentTouchesCell(origin, delta, cell_min, tile)) continue;
            if (world.levelBlocksMovement(level, @intCast(x), @intCast(y))) return false;
        }
    }
    return true;
}

// Whether `origin + t * delta` touches the closed cell box at some t in (0, 1].
// The entry and exit bounds are fractions (distance / |delta|) compared by
// cross-multiplication, exact for cell-aligned endpoints.
fn segmentTouchesCell(origin: [2]f64, delta: [2]f64, cell_min: [2]f64, tile: f64) bool {
    var enter_distance: f64 = 0;
    var enter_extent: f64 = 1;
    var exit_distance: f64 = 1;
    var exit_extent: f64 = 1;
    for (0..2) |axis| {
        const low = cell_min[axis] - origin[axis];
        const high = low + tile;
        const d = delta[axis];
        if (d == 0) {
            if (low > 0 or high < 0) return false;
            continue;
        }
        const entry = if (d > 0) low else -high;
        const exit = if (d > 0) high else -low;
        const extent = @abs(d);
        if (entry * enter_extent > enter_distance * extent) {
            enter_distance = entry;
            enter_extent = extent;
        }
        if (exit * exit_extent < exit_distance * extent) {
            exit_distance = exit;
            exit_extent = extent;
        }
    }
    return exit_distance > 0 and enter_distance * exit_extent <= exit_distance * enter_extent;
}

// Whether the segment's line passes within `epsilon` pixels of a grid corner in
// its cell bounding box: for random (not cell-aligned) endpoints the walk and the
// reference may round a near-graze differently, so the parity test skips the ray.
fn rayGrazesGridCorner(world: *const WorldSystem, ox: f32, oy: f32, tx: f32, ty: f32, epsilon: f64) bool {
    const start = world.cellContaining(ox, oy).?;
    const end = world.cellContaining(tx, ty).?;
    const tile: f64 = world.tile_size;
    const dx = @as(f64, tx) - ox;
    const dy = @as(f64, ty) - oy;
    const length = @sqrt(dx * dx + dy * dy);
    if (length == 0) return false;
    for (@min(start.y, end.y)..@as(usize, @max(start.y, end.y)) + 2) |gy| {
        for (@min(start.x, end.x)..@as(usize, @max(start.x, end.x)) + 2) |gx| {
            const px = @as(f64, @floatFromInt(gx)) * tile - ox;
            const py = @as(f64, @floatFromInt(gy)) * tile - oy;
            if (@abs(dx * py - dy * px) / length < epsilon) return true;
        }
    }
    return false;
}

test "a same-step blocking edit between observer and target occludes LOS with no reaction; clearing it restores LOS" {
    var meta = try loadTestTilesetMeta();
    defer meta.deinit();
    var fixture = try chunkedObstacleWorld(&meta, 16, 16, 4);
    defer fixture.world.deinit();
    const world = &fixture.world;
    const tree = try world.requireTileByName(&meta, "tree_0");
    const grass = try world.requireTileByName(&meta, "grass");

    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const tile_size = world.tile_size;
    // Observer in cell (1, 1), target in cell (6, 1): the ray crosses the chunk
    // border at x = 4, where the edit lands.
    _ = try addAgent(&data, tile_size * 6.5, tile_size * 1.5, 0, 0, .hostile);
    const observer = try addObserver(&data, tile_size * 1.5, tile_size * 1.5, 10, 0, .player, .{
        .fov_half_angle_radians = std.math.pi / 2.0,
        .vision_range = tile_size * 10,
    });

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), world, &data, &events, .{});
    try testing.expect(data.aiPerceptionConst(observer).?.target_visible);

    // The edit is the only thing between the two updates: no event, no reaction.
    _ = (try world.setDenseTile(fixture.layer, 4, 1, tree)) orelse return error.TestExpectedEqual;
    events.clearRetainingCapacity();
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), world, &data, &events, .{});
    try testing.expect(!data.aiPerceptionConst(observer).?.target_visible);

    _ = (try world.setDenseTile(fixture.layer, 4, 1, grass)) orelse return error.TestExpectedEqual;
    events.clearRetainingCapacity();
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), world, &data, &events, .{});
    try testing.expect(data.aiPerceptionConst(observer).?.target_visible);
}

// A point at the center of cell (x, y) in tile units, or on its top (left) grid
// line when `on_line` is .y (.x).
fn cellAlignedPoint(tile: f32, x: u16, y: u16, on_line: enum { none, x, y }) [2]f32 {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    return .{
        (if (on_line == .x) fx else fx + 0.5) * tile,
        (if (on_line == .y) fy else fy + 0.5) * tile,
    };
}

test "the LOS walk equals a brute-force supercover over levelBlocksMovement on random and cell-aligned rays across chunk borders" {
    var meta = try loadTestTilesetMeta();
    defer meta.deinit();
    // 42 is not a multiple of the chunk edge: the right and bottom border chunks
    // are partial.
    const side: u16 = 42;
    const chunk_size_tiles: u16 = 4;
    var fixture = try chunkedObstacleWorld(&meta, side, side, chunk_size_tiles);
    defer fixture.world.deinit();
    const world = &fixture.world;
    const tree = try world.requireTileByName(&meta, "tree_0");

    var prng = std.Random.DefaultPrng.init(0x64_6e_31);
    const random = prng.random();
    // Mixed chunks: scattered dense blockers plus sparse blockers.
    for (0..side) |y| {
        for (0..side) |x| {
            if (random.float(f32) < 0.12) _ = try world.setDenseTile(fixture.layer, @intCast(x), @intCast(y), tree);
        }
    }
    for (0..30) |_| {
        _ = try world.addSparseTile(0, random.uintLessThan(u16, side), random.uintLessThan(u16, side), tree, 0, .obstacle);
    }
    // Fully blocked chunks next to open ones, so rays cross every chunk form.
    for ([_][2]u16{ .{ 2, 2 }, .{ 7, 5 }, .{ 3, 8 } }) |chunk| {
        for (0..chunk_size_tiles) |dy| {
            for (0..chunk_size_tiles) |dx| {
                const x: u16 = chunk[0] * chunk_size_tiles + @as(u16, @intCast(dx));
                const y: u16 = chunk[1] * chunk_size_tiles + @as(u16, @intCast(dy));
                _ = try world.setDenseTile(fixture.layer, x, y, tree);
            }
        }
    }
    var form_counts = std.EnumArray(ChunkForm, usize).initFill(0);
    for (0..world.chunkCountPerLevel()) |chunk| form_counts.getPtr(world.levelChunkBlockedForm(0, @intCast(chunk))).* += 1;
    for (form_counts.values) |count| try testing.expect(count > 0);

    const extent = @as(f32, @floatFromInt(side)) * world.tile_size;
    var checked: usize = 0;
    var visible: usize = 0;
    const ray_count: usize = 1000;
    for (0..ray_count) |_| {
        const ox = random.float(f32) * extent;
        const oy = random.float(f32) * extent;
        const tx = random.float(f32) * extent;
        const ty = random.float(f32) * extent;
        if (rayGrazesGridCorner(world, ox, oy, tx, ty, 0.01)) continue;
        const expected = bruteForceLineOfSight(world, 0, ox, oy, tx, ty);
        try testing.expectEqual(expected, hasLineOfSight(world, 0, ox, oy, tx, ty));
        checked += 1;
        visible += @intFromBool(expected);
    }
    try testing.expect(checked > ray_count * 9 / 10);
    try testing.expect(visible > 0 and visible < checked);

    // Cell-aligned rays hit exact ties: centers with odd x and y cell deltas
    // cross a grid corner, and rays along a grid line touch the cells across it.
    // Each runs both ways; with both endpoint cells open the result is symmetric.
    var corner_rays: usize = 0;
    var aligned_visible: usize = 0;
    var aligned_blocked: usize = 0;
    for (0..600) |ray_index| {
        const kind = ray_index % 3;
        const ax = random.uintLessThan(u16, side);
        const ay = random.uintLessThan(u16, side);
        var bx = random.uintLessThan(u16, side);
        var by = random.uintLessThan(u16, side);
        if (kind == 1) by = ay;
        if (kind == 2) bx = ax;
        const a = switch (kind) {
            0 => cellAlignedPoint(world.tile_size, ax, ay, .none),
            1 => cellAlignedPoint(world.tile_size, ax, ay, .y),
            else => cellAlignedPoint(world.tile_size, ax, ay, .x),
        };
        const b = switch (kind) {
            0 => cellAlignedPoint(world.tile_size, bx, by, .none),
            1 => cellAlignedPoint(world.tile_size, bx, by, .y),
            else => cellAlignedPoint(world.tile_size, bx, by, .x),
        };
        if (kind == 0 and (bx -% ax) % 2 == 1 and (by -% ay) % 2 == 1) corner_rays += 1;
        const forward = hasLineOfSight(world, 0, a[0], a[1], b[0], b[1]);
        const backward = hasLineOfSight(world, 0, b[0], b[1], a[0], a[1]);
        try testing.expectEqual(bruteForceLineOfSight(world, 0, a[0], a[1], b[0], b[1]), forward);
        try testing.expectEqual(bruteForceLineOfSight(world, 0, b[0], b[1], a[0], a[1]), backward);
        const a_cell = world.cellContaining(a[0], a[1]).?;
        const b_cell = world.cellContaining(b[0], b[1]).?;
        if (!world.levelBlocksMovement(0, a_cell.x, a_cell.y) and !world.levelBlocksMovement(0, b_cell.x, b_cell.y)) {
            try testing.expectEqual(forward, backward);
        }
        if (forward) aligned_visible += 1 else aligned_blocked += 1;
    }
    try testing.expect(corner_rays > 0);
    try testing.expect(aligned_visible > 0 and aligned_blocked > 0);
}

test "LOS through an exact grid corner or along a grid line is blocked by either side cell, in both directions" {
    var meta = try loadTestTilesetMeta();
    defer meta.deinit();
    var fixture = try chunkedObstacleWorld(&meta, 8, 8, 4);
    defer fixture.world.deinit();
    const world = &fixture.world;
    const tree = try world.requireTileByName(&meta, "tree_0");
    const grass = try world.requireTileByName(&meta, "grass");
    const tile = world.tile_size;

    const Case = struct { a: [2]f32, b: [2]f32, side_cells: []const [2]u16 };
    const cases = [_]Case{
        // 45 degrees, cell centers (1, 1) -> (3, 3): corners (2, 2) and (3, 3).
        .{ .a = .{ 1.5, 1.5 }, .b = .{ 3.5, 3.5 }, .side_cells = &.{ .{ 1, 2 }, .{ 2, 1 }, .{ 2, 3 }, .{ 3, 2 } } },
        // Slope 1/2 through the corner (2, 2).
        .{ .a = .{ 0.5, 1.25 }, .b = .{ 4.5, 3.25 }, .side_cells = &.{ .{ 2, 1 }, .{ 1, 2 } } },
        // Along the horizontal grid line y = 2: rows 2 and 1 both touch it.
        .{ .a = .{ 1.5, 2 }, .b = .{ 5.5, 2 }, .side_cells = &.{ .{ 3, 1 }, .{ 3, 2 }, .{ 1, 1 }, .{ 5, 1 } } },
        // Along the vertical grid line x = 2: columns 2 and 1 both touch it.
        .{ .a = .{ 2, 1.5 }, .b = .{ 2, 5.5 }, .side_cells = &.{ .{ 1, 3 }, .{ 2, 3 }, .{ 1, 1 }, .{ 1, 5 } } },
    };
    for (cases) |case| {
        const ax = case.a[0] * tile;
        const ay = case.a[1] * tile;
        const bx = case.b[0] * tile;
        const by = case.b[1] * tile;
        try testing.expect(hasLineOfSight(world, 0, ax, ay, bx, by));
        try testing.expect(hasLineOfSight(world, 0, bx, by, ax, ay));
        for (case.side_cells) |cell| {
            _ = (try world.setDenseTile(fixture.layer, cell[0], cell[1], tree)) orelse return error.TestExpectedEqual;
            try testing.expect(!hasLineOfSight(world, 0, ax, ay, bx, by));
            try testing.expect(!hasLineOfSight(world, 0, bx, by, ax, ay));
            try testing.expect(!bruteForceLineOfSight(world, 0, ax, ay, bx, by));
            _ = (try world.setDenseTile(fixture.layer, cell[0], cell[1], grass)) orelse return error.TestExpectedEqual;
        }
    }
}

test "LOS sees a target farther than 64 cells on open terrain" {
    var world = try minimalWorld(testing.allocator, 160, 1, 32);
    defer world.deinit();
    // 150 cells along one row, across ten chunks, in both directions.
    try testing.expect(hasLineOfSight(&world, 0, 16, 16, 150.5 * 32, 16));
    try testing.expect(hasLineOfSight(&world, 0, 150.5 * 32, 16, 16, 16));
}

test "LOS fails closed on an out-of-range level" {
    var world = try minimalWorld(testing.allocator, 32, 32, 32);
    defer world.deinit();
    // Level 0 is open: a multi-cell and a same-cell ray both see.
    try testing.expect(hasLineOfSight(&world, 0, 16, 16, 20.5 * 32, 7.5 * 32));
    try testing.expect(hasLineOfSight(&world, 0, 16, 16, 20, 20));
    for ([_]u16{ 1, std.math.maxInt(u16) }) |level| {
        try testing.expect(!hasLineOfSight(&world, level, 16, 16, 20.5 * 32, 7.5 * 32));
        try testing.expect(!hasLineOfSight(&world, level, 16, 16, 20, 20));
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
    try testing.expect(sys.dropped_events_warned);

    // The flag is once-only: a later capped step never clears it.
    events.clearRetainingCapacity();
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{
        .max_events_per_step = 1,
    });
    try testing.expect(sys.dropped_events_warned);
}

test "multi-range serial/threaded cap=1 keeps the same survivor under identity-swap + acquire" {
    // Observer A identity-swaps (lost then perceived), observer B acquires.
    // With multi-range dispatch and max_events_per_step=1, both serial and real
    // multi-worker threaded paths must keep the same single survivor event
    // (row order, `entity_lost` before `entity_perceived` within a row — A's
    // lost, row 0's first write).
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    // items_per_range is aligned up to perception_range_alignment_items (16), so
    // a two-observer fixture collapses to one range. Pad with silent fillers so
    // B lands in range 1 while A remains the first writer in range 0.
    const range_items = perception_range_alignment_items;
    const filler_count = range_items - 1; // A + fillers fill range 0; B starts range 1.

    const setupObservers = struct {
        fn run(data: *DataSystem, pad: usize) !struct {
            observer_a: EntityId,
            observer_b: EntityId,
            first_threat: EntityId,
            second_threat: EntityId,
            b_threat: EntityId,
        } {
            // Observer A at origin; first threat nearby, will be swapped out.
            const observer_a = try addObserver(data, 0, 0, 10, 0, .player, .{ .vision_range = 500 });
            const first_threat = try addAgent(data, 10, 0, 0, 0, .hostile);
            // Silent fillers far from every threat so they emit no transitions.
            for (0..pad) |i| {
                const fx: f32 = 4000 + @as(f32, @floatFromInt(i)) * 40;
                _ = try addObserver(data, fx, 4000, 0, 0, .player, .{ .vision_range = 32 });
            }
            // Observer B after the first range so its acquire is a later range write.
            const observer_b = try addObserver(data, 200, 0, 10, 0, .player, .{ .vision_range = 500 });
            // B's threat is created later (after the warm step) so only A has a
            // prev threat for the transition step.
            return .{
                .observer_a = observer_a,
                .observer_b = observer_b,
                .first_threat = first_threat,
                .second_threat = EntityId.invalid,
                .b_threat = EntityId.invalid,
            };
        }
    }.run;

    var serial_data = DataSystem.init(testing.allocator);
    defer serial_data.deinit();
    var threaded_data = DataSystem.init(testing.allocator);
    defer threaded_data.deinit();

    var serial_ids = try setupObservers(&serial_data, filler_count);
    var threaded_ids = try setupObservers(&threaded_data, filler_count);

    var world = try minimalWorld(testing.allocator, 512, 64, 32);
    defer world.deinit();

    // Warm step: A acquires first_threat; fillers and B have no threat yet.
    {
        var spatial = try testSpatialIndex(serial_data.aiAgentSliceConst(), serial_data.movementBodySliceConst(), &serial_data);
        defer spatial.deinit();
        var sys = PerceptionSystem.init(testing.allocator);
        defer sys.deinit();
        var events = SimulationEvents.init(testing.allocator);
        defer events.deinit();
        _ = try sys.updateSerial(serial_data.aiAgentSliceConst(), serial_data.movementBodySliceConst(), spatial.view(), &world, &serial_data, &events, .{});
        try testing.expectEqual(serial_ids.first_threat.index, serial_data.aiPerceptionConst(serial_ids.observer_a).?.nearest_threat.index);
    }
    {
        var spatial = try testSpatialIndex(threaded_data.aiAgentSliceConst(), threaded_data.movementBodySliceConst(), &threaded_data);
        defer spatial.deinit();
        var sys = PerceptionSystem.init(testing.allocator);
        defer sys.deinit();
        var events = SimulationEvents.init(testing.allocator);
        defer events.deinit();
        _ = try sys.updateSerial(threaded_data.aiAgentSliceConst(), threaded_data.movementBodySliceConst(), spatial.view(), &world, &threaded_data, &events, .{});
        try testing.expectEqual(threaded_ids.first_threat.index, threaded_data.aiPerceptionConst(threaded_ids.observer_a).?.nearest_threat.index);
    }

    // Transition step setup: A identity-swaps, B acquires a new hostile.
    inline for (.{ &serial_data, &threaded_data }, .{ &serial_ids, &threaded_ids }) |data, ids| {
        try data.setMovementBody(ids.first_threat, .{ .position = .{ .x = 5000, .y = 0 }, .previous_position = .{ .x = 5000, .y = 0 }, .velocity = .{}, .speed = 0 });
        ids.second_threat = try addAgent(data, 12, 0, 0, 0, .hostile);
        ids.b_threat = try addAgent(data, 210, 0, 0, 0, .hostile);
    }

    // Aligned range size with A..fillers in range 0 and B in range 1: the cap
    // applies in row order after the join, regardless of the partition.
    const multi_range_cfg = PerceptionConfig{
        .items_per_range = range_items,
        .max_worker_threads = 2,
        .adaptive = false,
        .max_events_per_step = 1,
    };

    var serial_spatial = try testSpatialIndex(serial_data.aiAgentSliceConst(), serial_data.movementBodySliceConst(), &serial_data);
    defer serial_spatial.deinit();
    var serial_sys = PerceptionSystem.init(testing.allocator);
    defer serial_sys.deinit();
    var serial_events = SimulationEvents.init(testing.allocator);
    defer serial_events.deinit();
    // updateSerial always uses range_count=1; drive serial through update with
    // max_worker_threads=0 so the same multi-range compute + row-order emit is
    // exercised on both sides.
    var serial_threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 0, .items_per_range = range_items });
    defer serial_threads.deinit();
    const serial_stats = try serial_sys.update(
        serial_data.aiAgentSliceConst(),
        serial_data.movementBodySliceConst(),
        serial_spatial.view(),
        &world,
        &serial_data,
        &serial_events,
        &serial_threads,
        multi_range_cfg,
    );

    var threaded_spatial = try testSpatialIndex(threaded_data.aiAgentSliceConst(), threaded_data.movementBodySliceConst(), &threaded_data);
    defer threaded_spatial.deinit();
    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2, .items_per_range = range_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var threaded_sys = PerceptionSystem.init(testing.allocator);
    defer threaded_sys.deinit();
    var threaded_events = SimulationEvents.init(testing.allocator);
    defer threaded_events.deinit();
    const threaded_stats = try threaded_sys.update(
        threaded_data.aiAgentSliceConst(),
        threaded_data.movementBodySliceConst(),
        threaded_spatial.view(),
        &world,
        &threaded_data,
        &threaded_events,
        &threads,
        multi_range_cfg,
    );

    // Both paths: multi-range, cap=1 survivor is A's entity_lost (row 0's first write).
    try testing.expect(serial_stats.batch.range_count > 1);
    try testing.expect(threaded_stats.batch.range_count > 1);
    try testing.expect(!threaded_stats.batch.ran_inline);

    const serial_merged = serial_events.mergedItems();
    const threaded_merged = threaded_events.mergedItems();
    try testing.expectEqual(@as(usize, 1), serial_merged.len);
    try testing.expectEqual(@as(usize, 1), threaded_merged.len);
    try testing.expectEqualSlices(SimulationEvent, serial_merged, threaded_merged);
    try testing.expectEqual(SimulationEvent{
        .stage = .domain_reaction,
        .payload = .{ .entity_lost = .{ .observer = serial_ids.observer_a, .target = serial_ids.first_threat } },
    }, serial_merged[0]);
    // Cap drops the rest of the multi-kind transitions (A's perceived + B's acquire).
    try testing.expect(serial_stats.dropped_events >= 2);
    try testing.expectEqual(serial_stats.dropped_events, threaded_stats.dropped_events);
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
        _ = try addObserver(&serial_data, fi * 6 + 3, 4, 1, 1, .player, .{ .fov_half_angle_radians = std.math.pi / 2.0, .vision_range = 100, .hearing_range = 5 });
        _ = try addObserver(&threaded_data, fi * 6 + 3, 4, 1, 1, .player, .{ .fov_half_angle_radians = std.math.pi / 2.0, .vision_range = 100, .hearing_range = 5 });
    }

    var serial_spatial = try testSpatialIndex(serial_data.aiAgentSliceConst(), serial_data.movementBodySliceConst(), &serial_data);
    defer serial_spatial.deinit();
    var threaded_spatial = try testSpatialIndex(threaded_data.aiAgentSliceConst(), threaded_data.movementBodySliceConst(), &threaded_data);
    defer threaded_spatial.deinit();

    var world = try minimalWorld(testing.allocator, 512, 64, 32);
    defer world.deinit();

    // Only the observer near x=63 (i=10) is within hearing_range=5 of this stimulus.
    const stimuli = [_]WorldStimulus{.{ .position = .{ .x = 63, .y = 4 }, .intensity = 1, .kind = .dig, .level = 0 }};

    var serial_sys = PerceptionSystem.init(testing.allocator);
    defer serial_sys.deinit();
    var serial_events = SimulationEvents.init(testing.allocator);
    defer serial_events.deinit();
    _ = try serial_sys.updateSerial(serial_data.aiAgentSliceConst(), serial_data.movementBodySliceConst(), serial_spatial.view(), &world, &serial_data, &serial_events, .{ .stimuli = &stimuli });

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
        .stimuli = &stimuli,
    });

    const serial_ai = serial_data.aiAgentSliceConst();
    const threaded_ai = threaded_data.aiAgentSliceConst();
    try testing.expectEqual(serial_ai.entities.len, threaded_ai.entities.len);
    var any_heard = false;
    for (serial_ai.entities, threaded_ai.entities) |serial_entity, threaded_entity| {
        const serial_perception = serial_data.aiPerceptionConst(serial_entity) orelse continue;
        const threaded_perception = threaded_data.aiPerceptionConst(threaded_entity) orelse continue;
        try testing.expectEqual(serial_perception.target_visible, threaded_perception.target_visible);
        try testing.expectEqual(serial_perception.nearest_threat.index, threaded_perception.nearest_threat.index);
        try testing.expectEqual(serial_perception.facing_x, threaded_perception.facing_x);
        try testing.expectEqual(serial_perception.facing_y, threaded_perception.facing_y);
        try testing.expectEqual(serial_perception.heard_stimulus, threaded_perception.heard_stimulus);
        try testing.expectEqual(serial_perception.heard_stimulus_x, threaded_perception.heard_stimulus_x);
        try testing.expectEqual(serial_perception.heard_stimulus_y, threaded_perception.heard_stimulus_y);
        if (serial_perception.heard_stimulus) any_heard = true;
    }
    try testing.expect(any_heard);

    const serial_merged = serial_events.mergedItems();
    const threaded_merged = threaded_events.mergedItems();
    try testing.expectEqualSlices(SimulationEvent, serial_merged, threaded_merged);
}

test "PerceptionSystem has no steady-state allocation after warmup (FailingAllocator)" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    _ = try addObserver(&data, 0, 0, 10, 0, .player, .{ .hearing_range = 50 });
    _ = try addAgent(&data, 10, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stimuli = [_]WorldStimulus{.{ .position = .{ .x = 20, .y = 0 }, .intensity = 1, .kind = .dig, .level = 0 }};

    try sys.reserve(2);
    try events.reserve(8, 8);

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const original_system_allocator = sys.allocator;
    const original_events_allocator = events.stream.allocator;
    sys.allocator = failing.allocator();
    events.stream.allocator = failing.allocator();
    defer {
        sys.allocator = original_system_allocator;
        events.stream.allocator = original_events_allocator;
    }

    // `job.stimuli` is a borrowed slice, never copied, so passing it here
    // adds no allocation.
    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{ .stimuli = &stimuli });
    try testing.expectEqual(@as(usize, 1), stats.observer_count);
    try testing.expect(data.aiPerceptionConst(data.aiAgentSliceConst().entities[0]).?.heard_stimulus);
}

test "PerceptionSystem dual-list gather has no steady-state allocation after warmup (FailingAllocator)" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    _ = try addObserver(&data, 0, 0, 100, 0, .ally, .{});
    _ = try addObserver(&data, 40, 0, 0, 0, .hostile, .{});
    _ = try addObserver(&data, 80, 0, -100, 0, .ally, .{});
    _ = try addObserver(&data, 120, 0, 0, 0, .hostile, .{});

    const halo = [_]u32{ 0, 1, 2, 3 };
    const think = [_]u32{ 0, 2 };
    var spatial_sys = SpatialIndexSystem.init(testing.allocator);
    defer spatial_sys.deinit();
    try spatial_sys.reserve(4, .{});
    _ = try spatial_sys.buildSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data, .{ .scope_dense_indices = &halo });
    var world = try minimalWorld(testing.allocator, 8, 8, 32);
    defer world.deinit();

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();
    const cfg: PerceptionConfig = .{
        .scope_dense_indices = &think,
        .candidate_dense_indices = &halo,
    };

    try sys.reserve(4);
    try events.reserve(8, 8);

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const original_system_allocator = sys.allocator;
    const original_events_allocator = events.stream.allocator;
    sys.allocator = failing.allocator();
    events.stream.allocator = failing.allocator();
    defer {
        sys.allocator = original_system_allocator;
        events.stream.allocator = original_events_allocator;
    }

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, cfg);
    try testing.expectEqual(@as(usize, 2), stats.observer_count);
    try testing.expectEqual(@as(usize, 4), stats.candidate_population_count);
    try testing.expectEqual(@as(usize, 4), sys.candidates.len);
    try testing.expectEqual(@as(usize, 2), sys.rows.len);
}

test "PerceptionSystem after reserve alone, threaded updates at 64- then 16-item ranges allocate nothing (FailingAllocator)" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    // Nothing partition-sized is left to reserve, so `reserve`
    // alone (no warm step) covers the tuner's 64-item initial profile and the
    // 16-item alignment floor on the real multi-worker path. 16 hostile
    // non-observers on y = 0 and 96 `.player` observers on y = 10 facing -y:
    // every observer acquires a hostile within 41 units on step 1. 96 rows
    // put 32 in the 64-item partition's second range, which the old per-range
    // event slots (reserved for 16 rows past slot 0) grew in-stage.
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    for (0..16) |h| {
        const fh: f32 = @floatFromInt(h);
        _ = try addAgent(&data, fh * 80, 0, 0, 0, .hostile);
    }
    const observer_total: usize = 96;
    for (0..observer_total) |j| {
        const fj: f32 = @floatFromInt(j);
        _ = try addObserver(&data, fj * 12.5, 10, 0, -10, .player, .{ .fov_half_angle_radians = std.math.pi / 2.0, .vision_range = 100, .hearing_range = 5 });
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

    try sys.reserve(data.aiAgentSliceConst().entities.len);
    try events.reserve(1, 256);

    // resize_fail_index = 0 also catches in-place growth (a resize/remap that
    // would not count as an allocation).
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const original_system_allocator = sys.allocator;
    const original_events_allocator = events.stream.allocator;
    sys.allocator = failing.allocator();
    events.stream.allocator = failing.allocator();
    defer {
        sys.allocator = original_system_allocator;
        events.stream.allocator = original_events_allocator;
    }

    const partitions = [_]usize{ perception_adaptive_tuner_config.initial_range_items, perception_range_alignment_items };
    for (partitions, 0..) |items, step| {
        // Mirrors `SimulationFrame.beginStep`'s per-step reset of `events`.
        events.clearRetainingCapacity();
        const stats = try sys.update(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, &threads, .{
            .items_per_range = items,
            .max_worker_threads = 2,
            .adaptive = false,
        });
        try testing.expectEqual(observer_total, stats.observer_count);
        try testing.expectEqual(rangeCount(observer_total, items), stats.batch.range_count);
        try testing.expect(!stats.batch.ran_inline);
        try testing.expect(stats.batch.active_worker_threads > 0);
        if (step == 0) try testing.expectEqual(observer_total, stats.perceived_events);
    }
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}
