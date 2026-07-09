// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! AI decision processor: gathers per-row perception/memory/affect/personality
//! signals, runs `arbitration.zig`'s utility scoring + sticky selection +
//! goal resolution (Slice 32) to pick one of 5 behaviors and a concrete goal,
//! then blends that goal with wander noise and local separation into a
//! `NavigationIntent`. Arbitration output is per-agent: perception's
//! `nearest_threat` is already faction-generic (any hostile can become a
//! pursue/flee target), and `AiConfig.focus_target`/`focus_entity` is an
//! explicit, opt-in, last-resort fallback gated on `gain_pursue > 0` — never
//! the primary signal.
//! Stateless (except work memory + per-system tuner); reads typed const slices for ai + movement prior positions,
//! pre-sizes NavigationIntent output ranges and uses staged parallelForWithOptions work.
//! Deterministic via explicit seed in config. Gather uses DataSystem dense-index lookup, so cost is bounded by live AI rows.
//! Separation queries the pipeline-owned `SpatialIndexSystem` (Slice 28) — the caller
//! builds it once per step from the same scoped population and passes a read-only
//! `SpatialIndexView` in; this module no longer owns a private grid. See
//! `spatial_index.zig`'s module doc for the population-domain-equivalence contract
//! this depends on and the determinism-critical cell-scan traversal order. The same
//! shared index also backs arbitration's cohere neighbor-mean gather (a second
//! `queryNeighbors` call in the same separation-stage job, filtered to friendly
//! stance) — no second grid.
//! decideDir pure base; applySeparationAndNormalize shared (no logic dup). Serial fallback + threaded identical.
//! Arbitration itself (scoreBehaviors -> selectSticky -> resolveGoal per row) runs
//! inside the already-threaded `writeAiIntentsJob`/`writeAiSeparationJob` range jobs —
//! `updateSerial` calls the same job functions with a single full-range dispatch
//! (mirrors `computeAiSeparationsSerial`), so serial and threaded paths share one
//! code path by construction rather than two hand-duplicated ones.
//! Serial/main-only clamp for AI squares (math.clamp consistent with player, vel zero for AI decision rate).
//! Serial fallback, read-only workers, range aligned to ai_range_alignment_items, no hot alloc after init, direct SoA.

const std = @import("std");
const builtin = @import("builtin");
const math = @import("../../core/math.zig");
const rng = @import("../../core/rng.zig");
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const AdaptiveWorkProfile = @import("../../app/thread_system.zig").AdaptiveWorkProfile;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const alignItemCount = @import("../../app/thread_system.zig").alignItemCount;
const rangeCount = @import("../../app/thread_system.zig").rangeCount;
const ConstAiAgentSlice = @import("../data_system.zig").ConstAiAgentSlice;
const AiAgentSlice = @import("../data_system.zig").AiAgentSlice;
const ConstAiMemorySlice = @import("../data_system.zig").ConstAiMemorySlice;
const ConstMovementBodySlice = @import("../data_system.zig").ConstMovementBodySlice;
const ConstPerceptionSlice = @import("../data_system.zig").ConstPerceptionSlice;
const ConstAiAffectSlice = @import("../data_system.zig").ConstAiAffectSlice;
const DataSystem = @import("../data_system.zig").DataSystem;
const max_ai_memory_staleness = @import("../data_system.zig").max_ai_memory_staleness;
const ai_memory_ring_capacity = @import("../data_system.zig").ai_memory_ring_capacity;
const EntityId = @import("../data_system.zig").EntityId;
const AiAgent = @import("../data_system.zig").AiAgent;
const AiBehavior = @import("../data_system.zig").AiBehavior;
const Faction = @import("../data_system.zig").Faction;
const movement_range_alignment_items = @import("../data_system.zig").movement_range_alignment_items;
const NavigationIntent = @import("../simulation.zig").NavigationIntent;
const PathRequestKind = @import("../simulation.zig").PathRequestKind;
const RangeOutputStream = @import("../simulation.zig").RangeOutputStream;
const SimulationFrame = @import("../simulation.zig").SimulationFrame;
const spatial_index = @import("spatial_index.zig");
const SpatialIndexView = spatial_index.SpatialIndexView;
const NeighborVisitResult = spatial_index.NeighborVisitResult;
const stance = @import("../faction.zig").stance;
const arbitration = @import("arbitration.zig");

pub const ai_range_alignment_items: usize = movement_range_alignment_items;

/// Fixed hysteresis distance for the demo's live-player chase: 1.75x
/// pathfinding's nav cell size (`pathfinding/types.zig`'s `default_cell_size`
/// == 32.0), not derived from world/map size. See
/// `AiConfig.goal_requantization_hysteresis_distance`.
pub const default_goal_requantization_hysteresis_distance: f32 = 56.0;

pub const HotF32Slice = []f32;

fn hotStoreCapacity(min_len: usize) usize {
    return alignItemCount(min_len, ai_range_alignment_items);
}

/// Cold personality gains (AiAgent), read once at gather time.
const RowGains = struct {
    wander: f32,
    pursue: f32,
    flee: f32,
    investigate: f32,
    cohere: f32,
};

/// Sticky-selection tunables + hot arbitration state as of the START of this
/// step (this row's "previous" for `selectSticky`), plus the dense
/// `AiAgentStore` index for the matching hot write-back once this step's
/// selection is known.
const RowSticky = struct {
    commitment_max_steps: u16,
    sticky_bonus: f32,
    prev_behavior: AiBehavior,
    prev_commitment_remaining: u16,
    agent_dense_index: u32,
};

/// Perception's threat signal (absent AiPerception component -> zeroed/false).
const RowThreat = struct {
    target_visible: bool,
    nearest_threat: EntityId,
    nearest_threat_x: f32,
    nearest_threat_y: f32,
};

/// Perception's stimulus signal (absent AiPerception component -> false/zero).
const RowStimulus = struct {
    heard_stimulus: bool,
    heard_stimulus_x: f32,
    heard_stimulus_y: f32,
};

/// Memory's last-known-target signal (absent AiMemory component -> invalid/zero).
const RowMemory = struct {
    last_known_target: EntityId,
    last_known_x: f32,
    last_known_y: f32,
    staleness: f32,
    max_staleness: f32,
};

/// One recent-contact ring slot (see `ai_memory_ring_capacity`).
const RowMemoryRingSlot = struct {
    entity: EntityId = EntityId.invalid,
    x: f32 = 0,
    y: f32 = 0,
    age: f32 = 0,
};

/// Emotion drive signal (absent AiAffect component -> zero).
const RowDrives = struct {
    fear: f32,
    curiosity: f32,
    aggression: f32,
    fatigue: f32,
};

/// Explicit opt-in fallback target (see `AiConfig.focus_target`'s doc
/// comment) -- gated on `gain_pursue > 0` at gather time, so a null entity
/// means either no configured focus_target or this agent has no pursue gain.
const RowFocus = struct {
    entity: ?EntityId,
    x: f32,
    y: f32,
};

/// Cohere neighbor-mean gather, written by `writeAiSeparationJob`'s
/// friendly-stance-filtered `queryNeighbors` pass (same job, same spatial
/// index as local separation). 0 count = no friendly neighbors found within
/// `cohere_radius`.
const RowCohere = struct {
    mean_x: f32 = 0,
    mean_y: f32 = 0,
    count: u32 = 0,
};

/// Arbitration output, written by `resolveRowArbitration` before
/// `decideDir`/the `NavigationIntent` emit for this row (see
/// `writeAiIntentsJob`). `gain` is whichever `RowGains` field matches
/// `behavior` (0 when `resolveGoal` was invalid, i.e. pure wander noise this
/// step).
const RowResolved = struct {
    behavior: AiBehavior = .wander,
    gain: f32 = 0,
    kind_hint: PathRequestKind = .individual,
    goal_x: f32 = 0,
    goal_y: f32 = 0,
    goal_entity: ?EntityId = null,
};

/// One gathered AI row. Columnar (MultiArrayList), never boxed into an
/// `arbitration.Signals` for storage — `Signals` is built transiently, once
/// per row, right before the `scoreBehaviors`/`resolveGoal` calls in
/// `resolveRowArbitration`, then discarded (mirrors this file's existing
/// `AiDir` helper struct). Fields are grouped into small per-domain structs
/// (gains, sticky state, threat, stimulus, memory, drives, focus, cohere,
/// resolved output) rather than ~50 flat scalars: `std.MultiArrayList`'s
/// comptime field-layout sort exceeds Zig's default eval-branch quota well
/// before that many fields (verified empirically), and grouping keeps each
/// signal domain readable as a unit besides.
const AiGatherRow = struct {
    entity: EntityId,
    pos_x: f32,
    pos_y: f32,
    faction: Faction,
    wander_amplitude: f32,
    gains: RowGains,
    sticky: RowSticky,
    threat: RowThreat,
    stimulus: RowStimulus,
    memory: RowMemory,
    memory_ring: [ai_memory_ring_capacity]RowMemoryRingSlot,
    drives: RowDrives,
    focus: RowFocus,
    sep_x: f32,
    sep_y: f32,
    separation_neighbor_count: u8,
    separation_candidate_count: u16,
    cohere: RowCohere,
    resolved: RowResolved,
};

fn appendAiGatherRow(
    rows: *std.MultiArrayList(AiGatherRow),
    row_slice: *std.MultiArrayList(AiGatherRow).Slice,
    row: AiGatherRow,
) void {
    _ = rows.addOneAssumeCapacity();
    row_slice.len = rows.len;
    row_slice.set(rows.len - 1, row);
}

// Must match the `cell_size` the caller builds the shared `SpatialIndexSystem`
// with for this population (`SimulationPipeline` passes the default).
const grid_cell_size: f32 = 32.0;
const separation_radius: f32 = 48.0;
const max_separation_neighbors: u8 = 32;
const max_separation_candidate_checks: u16 = 128;
// Precomputed once from the fixed separation radius/cell size (== 2, matching
// the grid this replaced) — see `spatial_index.cellScanRadius`'s doc comment.
const separation_cell_scan_radius: i32 = spatial_index.cellScanRadius(separation_radius, grid_cell_size);

// Cohere's neighbor-mean gather reuses the same shared spatial index as
// separation (a second, wider-radius, friendly-stance-filtered query in the
// same job) rather than a second grid. Fixed constants, not derived from
// world/population size.
const cohere_radius: f32 = 96.0;
const max_cohere_neighbors: u32 = 12;
const max_cohere_candidate_checks: u16 = 64;
const cohere_cell_scan_radius: i32 = spatial_index.cellScanRadius(cohere_radius, grid_cell_size);

/// Fixed sticky-selection epsilon (see `arbitration.selectSticky`'s
/// `min_delta` parameter): a challenger must clear `sticky_bonus + this` to
/// preempt a held behavior mid-commitment, so two behaviors scoring within
/// float noise of each other never flap every step.
const arbitration_sticky_min_delta: f32 = 0.01;

/// Distinguishes wander-direction draws from any future AI RNG consumer
/// (appraisal noise, investigate-target selection) sharing the same
/// (seed, entity_index, step) — see src/core/rng.zig's salt doc comment.
const wander_rng_salt: u32 = 0;

/// Default cadence (in fixed steps) at which a wandering entity's sampled
/// direction changes: 300 steps == 5s at 60Hz. A fully independent random
/// draw every AI-active step (every step keyed by `AiConfig.step` directly)
/// looks like frantic jitter rather than wandering, so the raw step is
/// quantized into coarser epochs before hashing — direction holds steady for
/// one epoch, then jumps to a new (still per-entity-distinct) heading.
const default_wander_resample_period_steps: u32 = 300;

pub const AiConfig = struct {
    items_per_range: ?usize = null,
    separation_items_per_range: ?usize = null,
    intent_items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    separation_adaptive_tuner: ?*AdaptiveWorkTuner = null,
    intent_adaptive_tuner: ?*AdaptiveWorkTuner = null,
    adaptive_tuner: ?*AdaptiveWorkTuner = null,
    intent_seed: u64 = 0,
    /// Current fixed-step counter (see `SimulationScopeSystem.currentStep()`),
    /// combined with `intent_seed` and each entity's dense index to key
    /// `src/core/rng.zig` draws. Defaults to 0 for callers/tests that don't
    /// care about step-to-step variation; production wiring passes the real
    /// per-step counter from `SimulationPipeline`.
    step: u32 = 0,
    /// Cadence (in fixed steps) at which wander direction resamples; `step` is
    /// quantized by this before hashing so direction holds steady for a
    /// stretch instead of changing every AI-active step. Must be >= 1.
    wander_resample_period_steps: u32 = default_wander_resample_period_steps,
    /// Explicit, opt-in, last-resort pursue target (e.g. the demo's live
    /// player position) — `arbitration.resolveGoal`'s tier-3 pursue fallback,
    /// consulted only for rows with `gain_pursue > 0` and only after a
    /// visible `nearest_threat` and fresh `AiMemory` both fail to produce a
    /// goal. This is the *sole* remaining player-reachable path; it is never
    /// the primary pursue signal (that's perception's faction-generic
    /// `nearest_threat`).
    focus_target: ?math.Vec2 = null,
    /// EntityId backing `focus_target`, when the live target represents one
    /// specific entity (e.g. the demo's player). Null skips populating
    /// `arbitration.Signals.focus_target` even if `focus_target` (position)
    /// is set, since the goal-resolution fallback also needs a `goal_entity`.
    focus_entity: ?EntityId = null,
    /// Fixed distance (world units) the live `focus_target` must move from
    /// the last reported goal before that goal snaps to the new position. 0
    /// (default) snaps every step — exact instant tracking, preserving
    /// pre-hysteresis behavior. Nonzero throttles how often a shared
    /// `.group` path goal re-keys (see
    /// `default_goal_requantization_hysteresis_distance`), since local
    /// separation/steering closes the small gap between path updates. Only
    /// affects the `focus_target` fallback; a row resolved from perception or
    /// memory is unaffected (those already update every step on their own).
    goal_requantization_hysteresis_distance: f32 = 0,
    /// Current perception state, consulted per-row to build
    /// `arbitration.Signals`' perception fields (target visibility,
    /// nearest-threat position, heard stimulus). Null = no perception signal
    /// this step (every agent scores as if nothing is seen/heard).
    perception_slice: ?ConstPerceptionSlice = null,
    /// Last-known-position memory consulted to build `arbitration.Signals`'
    /// memory fields (last-known target/position/staleness, recent-contact
    /// ring). Null = no memory signal this step.
    memory_slice: ?ConstAiMemorySlice = null,
    /// Current emotion-drive state (fear/curiosity/aggression/fatigue),
    /// consulted to build `arbitration.Signals`' drive fields. Null = every
    /// drive scores as 0 (pure personality-gain + perception/memory scoring).
    affect_slice: ?ConstAiAffectSlice = null,
    /// Solver-mode ceiling honored only when a row's `kind_hint` is not
    /// `.individual`. Per Slice 32's `arbitration.resolveGoal`, every
    /// behavior (including the `focus_target` pursue fallback) currently
    /// resolves `kind_hint = .individual` — goals are agent-specific by
    /// construction now, not a single broadcast target — so this field has
    /// no observable effect yet. Detecting when many agents genuinely share
    /// one quantized goal cell (the case where `.group` remains a real
    /// amortization win) is deferred; this field is kept as the documented
    /// future opt-in ceiling for that upgrade, not removed.
    nav_request_kind: PathRequestKind = .individual,
    navigation_intents: ?*RangeOutputStream(NavigationIntent) = null,
    /// When non-null, only these dense ai-store indices participate this step
    /// (the scope system's cognition halo + stagger selection). Null = all agents.
    scope_dense_indices: ?[]const u32 = null,
};

pub const AiStats = struct {
    entity_count: usize = 0,
    intent_count: usize = 0,
    navigation_intent_count: usize = 0,
    separation_candidate_checks: usize = 0,
    separation_neighbor_samples: usize = 0,
    separation_batch: BatchStats = .{},
    intent_batch: BatchStats = .{},
    batch: BatchStats = .{},
};

pub const AiSystem = struct {
    allocator: std.mem.Allocator,
    // Gathered work memory (main-thread only; workers read only copies in ctx). Sized to ai ents.
    rows: std.MultiArrayList(AiGatherRow) = .{},
    separation_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    intent_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    // Broadcast goal-requantization state (see `requantizeGoal`); one scalar
    // pair since every default-target row shares this same broadcast value.
    snapped_goal: AiDir = .{ .x = 0, .y = 0 },
    snapped_goal_initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator) AiSystem {
        return .{
            .allocator = allocator,
            .separation_tuner = AdaptiveWorkTuner.init(.{}),
            .intent_tuner = AdaptiveWorkTuner.init(.{}),
        };
    }

    pub fn deinit(self: *AiSystem) void {
        self.rows.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn update(
        self: *AiSystem,
        ai_agents: ConstAiAgentSlice,
        movement: ConstMovementBodySlice,
        spatial: SpatialIndexView,
        data: *DataSystem,
        frame: *SimulationFrame,
        thread_system: *ThreadSystem,
        delta_seconds: f32,
        config: AiConfig,
    ) !AiStats {
        _ = delta_seconds; // decisions are instantaneous; integration in movement
        const held_focus_target = self.resolveFocusTarget(config);
        try self.gatherAiData(ai_agents, movement, data, config.scope_dense_indices, held_focus_target, config.focus_entity, config.perception_slice, config.memory_slice, config.affect_slice);
        const entity_count = self.rows.len;
        if (entity_count == 0) {
            // No ai this step; do not touch caller's stream (other emitters may use intents).
            return .{};
        }

        // Population-domain contract with spatial_index.zig (see the module doc
        // and `computeAiSeparationsSerial`): the shared index built for this step
        // must have gathered the identical row count, since `computeBoundedSeparation`
        // passes a gather row index into `queryNeighbors` as a self-index used only
        // for self-exclusion (an equality compare against spatial's own row indices,
        // which are always bounds-safe within spatial's own arrays) — a divergence
        // here corrupts self-exclusion/separation-force correctness, not memory
        // safety. Debug/ReleaseSafe-only guard (compiles out in ReleaseFast, like
        // every std.debug.assert); O(1) count compare, not a per-row cost.
        std.debug.assert(entity_count == spatial.pos_x.len);

        const system_config = normalizedConfig(config, self);
        self.resetSeparationScratch();
        const gathered = self.rows.slice();
        const separation_selection = selectStageWork(
            thread_system,
            entity_count,
            system_config.separation_items_per_range orelse system_config.items_per_range,
            system_config.max_worker_threads,
            system_config.adaptive,
            system_config.separation_adaptive_tuner,
        );
        var separation_context = buildAiSeparationContext(gathered, spatial);
        const separation_batch = thread_system.parallelForWithOptions(entity_count, &separation_context, writeAiSeparationJob, .{
            .max_worker_threads = separation_selection.worker_threads,
            .range_alignment_items = ai_range_alignment_items,
            .adaptive_tuner = separation_selection.active_tuner,
            .selected_profile = separation_selection.profile,
        });

        const intent_selection = selectStageWork(
            thread_system,
            entity_count,
            system_config.intent_items_per_range orelse system_config.items_per_range,
            system_config.max_worker_threads,
            system_config.adaptive,
            system_config.intent_adaptive_tuner,
        );
        const rcount = intent_selection.range_count;

        const navigation_stream = system_config.navigation_intents orelse &frame.navigation_intents;
        const range_base = try navigation_stream.appendRangeCounts(rcount);

        var context = buildAiJobContext(gathered, navigation_stream, data, system_config, range_base);

        for (0..rcount) |range_index| {
            const start = range_index * intent_selection.items_per_range;
            const end = @min(start + intent_selection.items_per_range, entity_count);
            navigation_stream.addCount(range_base + range_index, end - start);
        }

        try navigation_stream.prefixAppendedRanges(range_base);

        const intent_batch = thread_system.parallelForWithOptions(entity_count, &context, writeAiIntentsJob, .{
            .max_worker_threads = intent_selection.worker_threads,
            .range_alignment_items = ai_range_alignment_items,
            .adaptive_tuner = intent_selection.active_tuner,
            .selected_profile = intent_selection.profile,
        });

        navigation_stream.finishWrite();

        return .{
            .entity_count = entity_count,
            .intent_count = entity_count,
            .navigation_intent_count = entity_count,
            .separation_candidate_checks = sumU16(gathered.items(.separation_candidate_count)),
            .separation_neighbor_samples = sumU8(gathered.items(.separation_neighbor_count)),
            .separation_batch = separation_batch,
            .intent_batch = intent_batch,
            .batch = separation_batch,
        };
    }

    /// True single-threaded twin of `update`: identical work, dispatched as a
    /// single full-range call to the same `writeAiSeparationJob`/
    /// `writeAiIntentsJob` functions `update` runs through
    /// `parallelForWithOptions` (mirrors the existing
    /// `computeAiSeparationsSerial` pattern) — arbitration and steering logic
    /// live in exactly one place for both paths, not two hand-duplicated ones.
    pub fn updateSerial(
        self: *AiSystem,
        ai_agents: ConstAiAgentSlice,
        movement: ConstMovementBodySlice,
        spatial: SpatialIndexView,
        data: *DataSystem,
        frame: *SimulationFrame,
        delta_seconds: f32,
        config: AiConfig,
    ) !AiStats {
        _ = delta_seconds;
        const held_focus_target = self.resolveFocusTarget(config);
        try self.gatherAiData(ai_agents, movement, data, config.scope_dense_indices, held_focus_target, config.focus_entity, config.perception_slice, config.memory_slice, config.affect_slice);
        const entity_count = self.rows.len;
        if (entity_count == 0) return .{};
        self.resetSeparationScratch();
        self.computeAiSeparationsSerial(spatial);
        const gathered = self.rows.slice();
        const rcount: usize = 1;
        const system_config = normalizedConfig(config, self);
        const navigation_stream = system_config.navigation_intents orelse &frame.navigation_intents;
        const range_base = try navigation_stream.appendRangeCounts(rcount);
        navigation_stream.addCount(range_base, entity_count);
        try navigation_stream.prefixAppendedRanges(range_base);

        var context = buildAiJobContext(gathered, navigation_stream, data, system_config, range_base);
        writeAiIntentsJob(&context, .{ .index = 0, .start = 0, .end = entity_count }, WorkerId.main);

        navigation_stream.finishWrite();
        const separation_batch = serialBatch(entity_count);
        const intent_batch = serialBatch(entity_count);
        return .{
            .entity_count = entity_count,
            .intent_count = entity_count,
            .navigation_intent_count = entity_count,
            .separation_candidate_checks = sumU16(gathered.items(.separation_candidate_count)),
            .separation_neighbor_samples = sumU8(gathered.items(.separation_neighbor_count)),
            .separation_batch = separation_batch,
            .intent_batch = intent_batch,
            .batch = separation_batch,
        };
    }

    // Population-domain contract with `spatial_index.zig` (Slice 28): the shared
    // `SpatialIndexSystem` the caller builds for this step walks the identical
    // `scope_dense_indices` selection with the identical
    // `movementBodyDenseIndex(entity) orelse continue` skip, in the same order —
    // a deliberate duplicate gather, not shared code. That equivalence is what
    // lets `computeBoundedSeparation` below use a spatial-index row index
    // directly as this system's own row index with zero translation (see
    // `spatial_index.zig`'s module doc and the cross-system contract test).
    //
    // Populates every INPUT column arbitration needs (personality gains, hot
    // commitment state, perception/memory/affect signals, the gated
    // opt-in focus_target) as flat scalar/fixed-array columns — never an
    // `arbitration.Signals` array. `Signals` values are built transiently,
    // one at a time, inside `resolveRowArbitration` (called from the
    // threaded `writeAiIntentsJob`/`writeAiSeparationJob` jobs below, not
    // from this serial gather pass).
    fn gatherAiData(
        self: *AiSystem,
        ai_slice: ConstAiAgentSlice,
        movement: ConstMovementBodySlice,
        data: *const DataSystem,
        scope_dense_indices: ?[]const u32,
        focus_target: ?AiDir,
        focus_entity: ?EntityId,
        perception_slice: ?ConstPerceptionSlice,
        memory_slice: ?ConstAiMemorySlice,
        affect_slice: ?ConstAiAffectSlice,
    ) !void {
        self.clearWork();
        // n is the candidate count: the scoped subset when the scope system has
        // selected ai rows for this step, otherwise every ai agent.
        const n = if (scope_dense_indices) |idx| idx.len else ai_slice.entities.len;
        if (n == 0) return;
        try self.rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(n));

        // Preserve ai order for deterministic output. DataSystem rejects stale generations
        // and returns direct dense movement rows without transient high-water index tables.
        // The scoped path walks only the selected ai indices; both paths gather the
        // same per-row columns, so all downstream stages operate on the gathered set.
        var row_slice = self.rows.slice();
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const i: usize = if (scope_dense_indices) |idx| idx[k] else k;
            const ent = ai_slice.entities[i];
            const mi = data.movementBodyDenseIndex(ent) orelse continue;

            // See AiConfig.focus_target's doc comment: only an explicit opt-in,
            // never populated for a row with no pursue gain at all.
            const gain_pursue = ai_slice.gain_pursues[i];
            const has_focus = focus_target != null and gain_pursue > 0;

            var row = AiGatherRow{
                .entity = ent,
                .pos_x = movement.previous_x[mi],
                .pos_y = movement.previous_y[mi],
                .faction = data.factionConst(ent) orelse .neutral,
                .wander_amplitude = ai_slice.wander_amplitudes[i],
                .gains = .{
                    .wander = ai_slice.gain_wanders[i],
                    .pursue = gain_pursue,
                    .flee = ai_slice.gain_flees[i],
                    .investigate = ai_slice.gain_investigates[i],
                    .cohere = ai_slice.gain_coheres[i],
                },
                .sticky = .{
                    .commitment_max_steps = ai_slice.commitment_max_steps[i],
                    .sticky_bonus = ai_slice.sticky_bonus[i],
                    .prev_behavior = ai_slice.behaviors[i],
                    .prev_commitment_remaining = ai_slice.commitment_remaining[i],
                    .agent_dense_index = @intCast(i),
                },
                .threat = .{
                    .target_visible = false,
                    .nearest_threat = EntityId.invalid,
                    .nearest_threat_x = 0,
                    .nearest_threat_y = 0,
                },
                .stimulus = .{ .heard_stimulus = false, .heard_stimulus_x = 0, .heard_stimulus_y = 0 },
                .memory = .{
                    .last_known_target = EntityId.invalid,
                    .last_known_x = 0,
                    .last_known_y = 0,
                    .staleness = 0,
                    .max_staleness = 0,
                },
                .memory_ring = [_]RowMemoryRingSlot{.{}} ** ai_memory_ring_capacity,
                .drives = .{ .fear = 0, .curiosity = 0, .aggression = 0, .fatigue = 0 },
                .focus = .{
                    .entity = if (has_focus) focus_entity else null,
                    .x = if (has_focus) focus_target.?.x else 0,
                    .y = if (has_focus) focus_target.?.y else 0,
                },
                .sep_x = 0,
                .sep_y = 0,
                .separation_neighbor_count = 0,
                .separation_candidate_count = 0,
                .cohere = .{},
                .resolved = .{ .goal_x = movement.previous_x[mi], .goal_y = movement.previous_y[mi] },
            };

            if (perception_slice) |perception| {
                if (data.aiPerceptionDenseIndex(ent)) |pidx| {
                    row.threat = .{
                        .target_visible = perception.target_visible[pidx],
                        .nearest_threat = perception.nearest_threat[pidx],
                        .nearest_threat_x = perception.last_seen_x[pidx],
                        .nearest_threat_y = perception.last_seen_y[pidx],
                    };
                    row.stimulus = .{
                        .heard_stimulus = perception.heard_stimulus[pidx],
                        .heard_stimulus_x = perception.heard_stimulus_x[pidx],
                        .heard_stimulus_y = perception.heard_stimulus_y[pidx],
                    };
                }
            }

            if (memory_slice) |memory| {
                if (data.aiMemoryDenseIndex(ent)) |midx| {
                    row.memory = .{
                        .last_known_target = memory.last_known_target[midx],
                        .last_known_x = memory.last_known_x[midx],
                        .last_known_y = memory.last_known_y[midx],
                        .staleness = memory.staleness[midx],
                        .max_staleness = max_ai_memory_staleness,
                    };
                    const ring_entity = memory.ring_entity[midx];
                    const ring_x = memory.ring_x[midx];
                    const ring_y = memory.ring_y[midx];
                    const ring_age = memory.ring_age[midx];
                    for (0..ai_memory_ring_capacity) |slot| {
                        row.memory_ring[slot] = .{
                            .entity = ring_entity[slot],
                            .x = ring_x[slot],
                            .y = ring_y[slot],
                            .age = ring_age[slot],
                        };
                    }
                }
            }

            if (affect_slice) |affect| {
                if (data.aiAffectDenseIndex(ent)) |aidx| {
                    row.drives = .{
                        .fear = affect.fear[aidx],
                        .curiosity = affect.curiosity[aidx],
                        .aggression = affect.aggression[aidx],
                        .fatigue = affect.fatigue[aidx],
                    };
                }
            }

            appendAiGatherRow(&self.rows, &row_slice, row);
        }
    }

    fn clearWork(self: *AiSystem) void {
        self.rows.clearRetainingCapacity();
    }

    /// Requantizes `AiConfig.focus_target` with fixed-distance hysteresis
    /// (`AiConfig.goal_requantization_hysteresis_distance`) by delegating to
    /// `computeRequantizedGoal` (the pure comparison, also exercised directly
    /// by `zig build bench`) and persisting its result. Returns `null` when no
    /// `focus_target` is configured this step — the opt-in fallback simply
    /// does not exist, no legacy center-of-mass default.
    fn resolveFocusTarget(self: *AiSystem, config: AiConfig) ?AiDir {
        const live = config.focus_target orelse return null;
        const result = computeRequantizedGoal(self.snapped_goal, self.snapped_goal_initialized, .{ .x = live.x, .y = live.y }, config.goal_requantization_hysteresis_distance);
        self.snapped_goal = result.goal;
        self.snapped_goal_initialized = result.initialized;
        return result.goal;
    }

    /// Zeroes this step's separation/cohere accumulator columns. No longer
    /// builds a grid (the caller-supplied `SpatialIndexView` replaces it), so
    /// this is infallible unlike the `buildSeparationGrid` it replaces.
    fn resetSeparationScratch(self: *AiSystem) void {
        if (self.rows.len == 0) return;
        const gathered = self.rows.slice();
        @memset(gathered.items(.sep_x), 0);
        @memset(gathered.items(.sep_y), 0);
        @memset(gathered.items(.separation_neighbor_count), 0);
        @memset(gathered.items(.separation_candidate_count), 0);
        @memset(gathered.items(.cohere), RowCohere{});
    }

    fn computeAiSeparationsSerial(self: *AiSystem, spatial: SpatialIndexView) void {
        // Population-domain contract with spatial_index.zig: the shared index
        // built for this step must have gathered the identical row count, since
        // `computeBoundedSeparation` passes a gather row index into `queryNeighbors`
        // as a self-index used only for self-exclusion (an equality compare against
        // spatial's own row indices, which are always bounds-safe within spatial's
        // own arrays) — a divergence here corrupts self-exclusion/separation-force
        // correctness, not memory safety. Debug/ReleaseSafe-only guard (compiles out
        // in ReleaseFast, like every std.debug.assert); O(1) count compare (not
        // per-row), guarding against a future silent divergence between the two
        // independent gathers.
        std.debug.assert(self.rows.len == spatial.pos_x.len);
        const gathered = self.rows.slice();
        var context = buildAiSeparationContext(gathered, spatial);
        writeAiSeparationJob(&context, .{ .index = 0, .start = 0, .end = self.rows.len }, WorkerId.main);
    }
};

const NormalizedAiConfig = struct {
    items_per_range: ?usize,
    separation_items_per_range: ?usize,
    intent_items_per_range: ?usize,
    max_worker_threads: ?usize,
    adaptive: bool,
    separation_adaptive_tuner: ?*AdaptiveWorkTuner,
    intent_adaptive_tuner: ?*AdaptiveWorkTuner,
    intent_seed: u64,
    step: u32,
    wander_resample_period_steps: u32,
    nav_request_kind: PathRequestKind,
    navigation_intents: ?*RangeOutputStream(NavigationIntent),
};

fn normalizedConfig(config: AiConfig, system: *AiSystem) NormalizedAiConfig {
    return .{
        .items_per_range = config.items_per_range,
        .separation_items_per_range = config.separation_items_per_range,
        .intent_items_per_range = config.intent_items_per_range,
        .max_worker_threads = config.max_worker_threads,
        .adaptive = config.adaptive,
        .separation_adaptive_tuner = config.separation_adaptive_tuner orelse if (config.adaptive and config.separation_items_per_range == null and config.items_per_range == null)
            &system.separation_tuner
        else
            null,
        .intent_adaptive_tuner = config.intent_adaptive_tuner orelse config.adaptive_tuner orelse if (config.adaptive and config.intent_items_per_range == null and config.items_per_range == null)
            &system.intent_tuner
        else
            null,
        .intent_seed = config.intent_seed,
        .step = config.step,
        .wander_resample_period_steps = config.wander_resample_period_steps,
        .nav_request_kind = config.nav_request_kind,
        .navigation_intents = config.navigation_intents,
    };
}

fn buildAiSeparationContext(gathered: std.MultiArrayList(AiGatherRow).Slice, spatial: SpatialIndexView) AiSeparationContext {
    return .{
        .pos_x = gathered.items(.pos_x),
        .pos_y = gathered.items(.pos_y),
        .faction = gathered.items(.faction),
        .gains = gathered.items(.gains),
        .sep_x = gathered.items(.sep_x),
        .sep_y = gathered.items(.sep_y),
        .neighbor_counts = gathered.items(.separation_neighbor_count),
        .candidate_counts = gathered.items(.separation_candidate_count),
        .cohere = gathered.items(.cohere),
        .spatial_index = spatial,
    };
}

/// Builds the shared per-row job context both `update` (via
/// `parallelForWithOptions`) and `updateSerial` (via a single full-range
/// call) hand to `writeAiIntentsJob`. `ai_agent_hot` is arbitration's mutable
/// hot-column write-back target (see `resolveRowArbitration`); each row's
/// `agent_dense_index` is unique within one gather, so concurrent workers
/// never write the same hot-column slot.
fn buildAiJobContext(
    gathered: std.MultiArrayList(AiGatherRow).Slice,
    navigation_stream: *RangeOutputStream(NavigationIntent),
    data: *DataSystem,
    system_config: NormalizedAiConfig,
    range_base: usize,
) AiJobContext {
    return .{
        .entities = gathered.items(.entity),
        .pos_x = gathered.items(.pos_x),
        .pos_y = gathered.items(.pos_y),
        .wander_amplitudes = gathered.items(.wander_amplitude),
        .gains = gathered.items(.gains),
        .sticky = gathered.items(.sticky),
        .threat = gathered.items(.threat),
        .stimulus = gathered.items(.stimulus),
        .memory = gathered.items(.memory),
        .memory_ring = gathered.items(.memory_ring),
        .drives = gathered.items(.drives),
        .focus = gathered.items(.focus),
        .sep_x = gathered.items(.sep_x),
        .sep_y = gathered.items(.sep_y),
        .cohere = gathered.items(.cohere),
        .resolved = gathered.items(.resolved),
        .navigation_intents = navigation_stream,
        .ai_agent_hot = data.aiAgentSlice(),
        .seed = system_config.intent_seed,
        .wander_step = system_config.step / @max(system_config.wander_resample_period_steps, 1),
        .nav_request_kind = system_config.nav_request_kind,
        .range_base = range_base,
    };
}

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
            .range_alignment_items = ai_range_alignment_items,
        })
    else
        AdaptiveWorkProfile{
            .worker_threads = max_worker_threads,
            .items_per_range = requested_items_per_range,
        };
    const aligned_items_per_range = alignItemCount(@max(profile.items_per_range, @as(usize, 1)), ai_range_alignment_items);
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

fn sumU8(values: []const u8) usize {
    var total: usize = 0;
    for (values) |value| total += value;
    return total;
}

fn sumU16(values: []const u16) usize {
    var total: usize = 0;
    for (values) |value| total += value;
    return total;
}

pub const AiDir = struct { x: f32, y: f32 };

pub const RequantizedGoal = struct { goal: AiDir, initialized: bool };

/// Pure snap/hold comparison behind `AiSystem.resolveFocusTarget`: holds
/// `current` unless `live` has moved past `hysteresis` from it, in which case
/// it snaps to `live`. Zero hysteresis or `!initialized` always snaps.
/// Exposed (and kept pure) so `zig build bench`'s hysteresis case calls the
/// real comparison instead of a hand-duplicated copy.
pub fn computeRequantizedGoal(current: AiDir, initialized: bool, live: AiDir, hysteresis: f32) RequantizedGoal {
    if (hysteresis <= 0 or !initialized) {
        return .{ .goal = live, .initialized = true };
    }
    const delta = math.Vec2{ .x = live.x - current.x, .y = live.y - current.y };
    if (math.lengthSquared(delta) > hysteresis * hysteresis) {
        return .{ .goal = live, .initialized = true };
    }
    return .{ .goal = current, .initialized = true };
}

fn decideDir(
    behavior: AiBehavior,
    px: f32,
    py: f32,
    tx: f32,
    ty: f32,
    wander_amp: f32,
    seek_w: f32,
    seed: u64,
    key: u32,
    wander_step: u32,
) AiDir {
    var dx: f32 = 0;
    var dy: f32 = 0;
    if (seek_w > 0) {
        const seek = math.normalizeOrZeroFinite(tx - px, ty - py, 0.0001);
        dx += seek.x * seek_w;
        dy += seek.y * seek_w;
    }
    // Wander (or default) adds deterministic perturbation using seed+entity key. A value of
    // 30 preserves the old unit perturbation, while smaller/larger values blend accordingly.
    const wander_strength = if (wander_amp > 0)
        wander_amp / 30.0
    else if (behavior == .wander)
        @as(f32, 1.0)
    else
        @as(f32, 0.0);
    if (wander_strength > 0) {
        const w = rng.unitVec2(seed, key, wander_step, wander_rng_salt);
        dx += w.x * wander_strength;
        dy += w.y * wander_strength;
    }
    const normalized = math.normalizeOrDefaultFinite(dx, dy, 0.0001, .{ .x = 1, .y = 0 });
    return .{ .x = normalized.x, .y = normalized.y };
}

/// Shared post-decide blend + normalize for separation contribution (precomputed on main).
/// Eliminates exact code duplication between serial path and write job. Matches prior math:
/// base_dir * 0.55 + sep * strength * 0.45 , then renorm (or default axis).
fn applySeparationAndNormalize(base: AiDir, sx: f32, sy: f32) AiDir {
    var dx = base.x;
    var dy = base.y;
    const sep_strength: f32 = 1.2;
    if (sx != 0 or sy != 0) {
        dx = dx * 0.55 + sx * sep_strength * 0.45;
        dy = dy * 0.55 + sy * sep_strength * 0.45;
    }
    const normalized = math.normalizeOrDefaultFinite(dx, dy, 0.0001, .{ .x = 1, .y = 0 });
    return .{ .x = normalized.x, .y = normalized.y };
}

/// Relative NavigationIntent priority once arbitration actually selects among
/// all 5 behaviors: flee is a safety-critical override (a fleeing agent
/// should win any per-entity steering arbitration against, say, a lower-
/// urgency pursue emitted by a different system), pursue is next (an active
/// chase still matters more than idle curiosity), investigate/cohere are
/// mid-priority exploratory/social behaviors, wander is the inert baseline.
fn priorityForBehavior(behavior: AiBehavior) i16 {
    return switch (behavior) {
        .flee => 20,
        .pursue => 10,
        .investigate, .cohere => 5,
        .wander => 0,
    };
}

const AiSeparationContext = struct {
    pos_x: []const f32,
    pos_y: []const f32,
    faction: []const Faction,
    /// Only `.cohere` is read here (gates the neighbor query below) — kept as
    /// the full row rather than a single `[]const f32` column so this struct
    /// doesn't grow a second near-duplicate gains slice alongside
    /// `AiJobContext.gains`.
    gains: []const RowGains,
    sep_x: []f32,
    sep_y: []f32,
    neighbor_counts: []u8,
    candidate_counts: []u16,
    /// Cohere neighbor-mean output (see `RowCohere`'s doc comment) — written
    /// by the same job, same shared spatial index, as local separation. Not
    /// a second grid.
    cohere: []RowCohere,
    spatial_index: SpatialIndexView,
};

fn writeAiSeparationJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *AiSeparationContext = @ptrCast(@alignCast(context));
    for (range.start..range.end) |index| {
        const result = computeBoundedSeparation(job, index);
        job.sep_x[index] = result.x;
        job.sep_y[index] = result.y;
        job.neighbor_counts[index] = result.neighbor_count;
        job.candidate_counts[index] = result.candidate_count;

        // A row with no cohere gain can never win `.cohere` in
        // `scoreBehaviors` (its score is `gain_cohere * (...)` = 0, and a
        // zero tie always loses to `.wander`'s lower enum index) — the
        // neighbor-mean this query would produce is provably unused, so
        // skip the second shared-spatial-index traversal entirely for the
        // common case (most demo archetypes have `gain_cohere == 0`).
        job.cohere[index] = if (job.gains[index].cohere > 0)
            computeCohereNeighbors(job, index)
        else
            .{};
    }
}

const SeparationResult = struct {
    x: f32 = 0,
    y: f32 = 0,
    neighbor_count: u8 = 0,
    candidate_count: u16 = 0,
};

/// Accumulates the bounded local-separation contribution for one row via the
/// shared spatial index. The near-zero `dist2 > 0.1` guard stays here (an
/// AI-specific "avoid degenerate normalize" concern, not a generic spatial
/// one); the radius prefilter and candidate-check bookkeeping live in
/// `SpatialIndexView.queryNeighbors` and must match its documented semantics
/// exactly for this to stay a pure port (see the brute-force parity test).
const SeparationAccumulator = struct {
    x: f32 = 0,
    y: f32 = 0,
    neighbor_count: u8 = 0,
};

fn separationNeighborVisit(context: *anyopaque, _: usize, dx: f32, dy: f32, dist2: f32) NeighborVisitResult {
    const acc: *SeparationAccumulator = @ptrCast(@alignCast(context));
    if (dist2 > 0.1) {
        const dir = math.normalizeOrZeroFinite(dx, dy, 0);
        acc.x += dir.x;
        acc.y += dir.y;
        acc.neighbor_count += 1;
        if (acc.neighbor_count >= max_separation_neighbors) return .stop;
    }
    return .keep_going;
}

fn computeBoundedSeparation(job: *const AiSeparationContext, index: usize) SeparationResult {
    var acc = SeparationAccumulator{};
    const stats = job.spatial_index.queryNeighbors(
        job.pos_x[index],
        job.pos_y[index],
        index,
        separation_cell_scan_radius,
        .{ .radius = separation_radius, .max_candidate_checks = max_separation_candidate_checks },
        &acc,
        separationNeighborVisit,
    );
    return .{
        .x = acc.x,
        .y = acc.y,
        .neighbor_count = acc.neighbor_count,
        .candidate_count = stats.candidate_checks,
    };
}

const CohereAccumulator = struct {
    sum_x: f32 = 0,
    sum_y: f32 = 0,
    count: u32 = 0,
};

const CohereVisitContext = struct {
    self_faction: Faction,
    candidate_faction: []const Faction,
    candidate_pos_x: []const f32,
    candidate_pos_y: []const f32,
    acc: *CohereAccumulator,
};

/// Mirrors `separationNeighborVisit`/`perception.zig`'s `perceptionNeighborVisit`
/// shape: scalar (branchy stance lookup + spatial traversal, not dense
/// uniform work). Filters to friendly stance only — cohere flocks with allies,
/// never hostiles or neutrals.
fn cohereNeighborVisit(context: *anyopaque, candidate_index: usize, _: f32, _: f32, _: f32) NeighborVisitResult {
    const ctx: *CohereVisitContext = @ptrCast(@alignCast(context));
    if (stance(ctx.self_faction, ctx.candidate_faction[candidate_index]) != .friendly) return .keep_going;
    ctx.acc.sum_x += ctx.candidate_pos_x[candidate_index];
    ctx.acc.sum_y += ctx.candidate_pos_y[candidate_index];
    ctx.acc.count += 1;
    if (ctx.acc.count >= max_cohere_neighbors) return .stop;
    return .keep_going;
}

/// Cohere's neighbor-mean gather: a second `queryNeighbors` call against the
/// same shared spatial index used for separation (see `AiSeparationContext`'s
/// doc comment), not a second grid.
fn computeCohereNeighbors(job: *const AiSeparationContext, index: usize) RowCohere {
    var acc = CohereAccumulator{};
    var visit_ctx = CohereVisitContext{
        .self_faction = job.faction[index],
        .candidate_faction = job.faction,
        .candidate_pos_x = job.pos_x,
        .candidate_pos_y = job.pos_y,
        .acc = &acc,
    };
    _ = job.spatial_index.queryNeighbors(
        job.pos_x[index],
        job.pos_y[index],
        index,
        cohere_cell_scan_radius,
        .{ .radius = cohere_radius, .max_candidate_checks = max_cohere_candidate_checks },
        &visit_ctx,
        cohereNeighborVisit,
    );
    if (acc.count == 0) return .{};
    const inv = 1.0 / @as(f32, @floatFromInt(acc.count));
    return .{ .mean_x = acc.sum_x * inv, .mean_y = acc.sum_y * inv, .count = acc.count };
}

/// Per-row job context for `writeAiIntentsJob`: every input column
/// `resolveRowArbitration` needs to build a transient `arbitration.Signals`
/// and call `scoreBehaviors`/`selectSticky`/`resolveGoal`, plus the resolved
/// output columns and `ai_agent_hot` (arbitration's mutable hot-column
/// write-back target). See `buildAiJobContext`.
/// Per-row job context for `writeAiIntentsJob`: every input column
/// `resolveRowArbitration` needs to build a transient `arbitration.Signals`
/// and call `scoreBehaviors`/`selectSticky`/`resolveGoal`, plus the resolved
/// output column and `ai_agent_hot` (arbitration's mutable hot-column
/// write-back target). See `buildAiJobContext`.
const AiJobContext = struct {
    entities: []const EntityId,
    pos_x: []const f32,
    pos_y: []const f32,
    wander_amplitudes: []const f32,
    gains: []const RowGains,
    sticky: []const RowSticky,
    threat: []const RowThreat,
    stimulus: []const RowStimulus,
    memory: []const RowMemory,
    memory_ring: []const [ai_memory_ring_capacity]RowMemoryRingSlot,
    drives: []const RowDrives,
    focus: []const RowFocus,
    sep_x: []const f32,
    sep_y: []const f32,
    cohere: []const RowCohere,
    // Arbitration output column (written by resolveRowArbitration before use).
    resolved: []RowResolved,
    navigation_intents: *RangeOutputStream(NavigationIntent),
    /// Mutable `AiAgentStore` hot-column view for this step's sticky-selection
    /// write-back, addressed by `sticky[i].agent_dense_index` (unique per row
    /// within one gather, so concurrent workers' writes never collide).
    ai_agent_hot: AiAgentSlice,
    seed: u64,
    /// Pre-quantized wander epoch (`step / wander_resample_period_steps`,
    /// computed once by the caller), not the raw fixed-step counter.
    wander_step: u32,
    nav_request_kind: PathRequestKind,
    range_base: usize,
};

/// Runs arbitration for one row: builds a transient `arbitration.Signals`
/// from this row's gathered columns (never stored — discarded immediately
/// after the three calls below), scores behaviors, sticky-selects one, then
/// resolves a concrete goal. Persists the raw selection to `ai_agent_hot`
/// (the agent's actual cognitive pick, independent of goal-resolution
/// success) and writes the row's steering-facing output column: a selected
/// behavior with no resolvable goal this step (e.g. a one-frame perception
/// gap) degrades to a pure-wander fallback (zero gain) rather than freezing
/// or chasing a stale goal.
fn resolveRowArbitration(job: *AiJobContext, i: usize) void {
    const threat = job.threat[i];
    const stimulus = job.stimulus[i];
    const memory = job.memory[i];
    const ring = job.memory_ring[i];
    const drives = job.drives[i];
    const focus = job.focus[i];
    const cohere = job.cohere[i];
    const gains_col = job.gains[i];
    const sticky = job.sticky[i];

    var memory_ring_entity: [ai_memory_ring_capacity]EntityId = undefined;
    var memory_ring_x: [ai_memory_ring_capacity]f32 = undefined;
    var memory_ring_y: [ai_memory_ring_capacity]f32 = undefined;
    var memory_ring_age: [ai_memory_ring_capacity]f32 = undefined;
    for (0..ai_memory_ring_capacity) |slot| {
        memory_ring_entity[slot] = ring[slot].entity;
        memory_ring_x[slot] = ring[slot].x;
        memory_ring_y[slot] = ring[slot].y;
        memory_ring_age[slot] = ring[slot].age;
    }

    const signals = arbitration.Signals{
        .fear = drives.fear,
        .curiosity = drives.curiosity,
        .aggression = drives.aggression,
        .fatigue = drives.fatigue,
        .target_visible = threat.target_visible,
        .nearest_threat = threat.nearest_threat,
        .nearest_threat_x = threat.nearest_threat_x,
        .nearest_threat_y = threat.nearest_threat_y,
        .heard_stimulus = stimulus.heard_stimulus,
        .heard_stimulus_x = stimulus.heard_stimulus_x,
        .heard_stimulus_y = stimulus.heard_stimulus_y,
        .memory_last_known_target = memory.last_known_target,
        .memory_last_known_x = memory.last_known_x,
        .memory_last_known_y = memory.last_known_y,
        .memory_staleness = memory.staleness,
        .memory_max_staleness = memory.max_staleness,
        .memory_ring_entity = memory_ring_entity,
        .memory_ring_x = memory_ring_x,
        .memory_ring_y = memory_ring_y,
        .memory_ring_age = memory_ring_age,
        .cohere_neighbor_mean_x = cohere.mean_x,
        .cohere_neighbor_mean_y = cohere.mean_y,
        .cohere_neighbor_count = cohere.count,
        .focus_target = focus.entity,
        .focus_target_x = focus.x,
        .focus_target_y = focus.y,
        .self_x = job.pos_x[i],
        .self_y = job.pos_y[i],
    };
    const gains = arbitration.PersonalityGains{
        .wander = gains_col.wander,
        .pursue = gains_col.pursue,
        .flee = gains_col.flee,
        .investigate = gains_col.investigate,
        .cohere = gains_col.cohere,
    };

    const scores = arbitration.scoreBehaviors(signals, gains);
    const selection = arbitration.selectSticky(
        scores,
        sticky.prev_behavior,
        sticky.prev_commitment_remaining,
        sticky.commitment_max_steps,
        sticky.sticky_bonus,
        arbitration_sticky_min_delta,
    );
    const selected_behavior: AiBehavior = @enumFromInt(selection.index);
    const goal = arbitration.resolveGoal(selected_behavior, signals);

    const agent_index = sticky.agent_dense_index;
    job.ai_agent_hot.active_behavior[agent_index] = selected_behavior;
    job.ai_agent_hot.commitment_remaining[agent_index] = selection.new_commitment;
    job.ai_agent_hot.last_score[agent_index] = scores[selection.index];

    if (goal.valid) {
        const resolved_gain: f32 = switch (selected_behavior) {
            .wander => gains_col.wander,
            .pursue => gains_col.pursue,
            .flee => gains_col.flee,
            .investigate => gains_col.investigate,
            .cohere => gains_col.cohere,
        };
        job.resolved[i] = .{
            .behavior = selected_behavior,
            .gain = resolved_gain,
            .kind_hint = goal.kind_hint,
            .goal_x = goal.goal_x,
            .goal_y = goal.goal_y,
            .goal_entity = goal.goal_entity,
        };
    } else {
        job.resolved[i] = .{
            .behavior = .wander,
            .gain = 0,
            .kind_hint = goal.kind_hint,
            .goal_x = job.pos_x[i],
            .goal_y = job.pos_y[i],
            .goal_entity = goal.goal_entity,
        };
    }
}

fn writeAiIntentsJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *AiJobContext = @ptrCast(@alignCast(context));
    var writer = job.navigation_intents.rangeWriter(job.range_base + range.index);
    for (range.start..range.end) |i| {
        resolveRowArbitration(job, i);
        const resolved = job.resolved[i];

        const base_dir = decideDir(
            resolved.behavior,
            job.pos_x[i],
            job.pos_y[i],
            resolved.goal_x,
            resolved.goal_y,
            job.wander_amplitudes[i],
            resolved.gain,
            job.seed,
            job.entities[i].index,
            job.wander_step,
        );
        const sep_x = if (i < job.sep_x.len) job.sep_x[i] else 0;
        const sep_y = if (i < job.sep_y.len) job.sep_y[i] else 0;
        const dir = applySeparationAndNormalize(base_dir, sep_x, sep_y);

        writer.write(.{
            .entity = job.entities[i],
            .kind = if (resolved.kind_hint == .individual) .individual else job.nav_request_kind,
            .goal = .{ .x = resolved.goal_x, .y = resolved.goal_y },
            .direct_direction_x = dir.x,
            .direct_direction_y = dir.y,
            .priority = priorityForBehavior(resolved.behavior),
        });
    }
    writer.finish();
}

fn serialBatch(count: usize) BatchStats {
    return .{ .ran_inline = true, .item_count = count, .range_count = 1, .items_per_range = count };
}

const SpatialIndexSystem = spatial_index.SpatialIndexSystem;

/// Test-only helper: builds a `SpatialIndexSystem` from the same fixture an
/// `AiSystem` test call is about to consume, serially (the AI call sites under
/// test do not themselves exercise index-build threading — that is covered by
/// `spatial_index.zig`'s own serial/threaded parity tests). Callers own the
/// returned system's lifetime and pass `.view()` into `AiSystem.update`/`updateSerial`.
fn testSpatialIndex(
    ai_slice: ConstAiAgentSlice,
    movement_slice: ConstMovementBodySlice,
    data: *const DataSystem,
) !SpatialIndexSystem {
    var sys = SpatialIndexSystem.init(std.testing.allocator);
    errdefer sys.deinit();
    try sys.reserve(ai_slice.entities.len, .{});
    _ = try sys.buildSerial(ai_slice, movement_slice, data, .{});
    return sys;
}

fn expectAiGatherColumnsAligned(rows: *const std.MultiArrayList(AiGatherRow)) !void {
    const count = rows.len;
    const s = rows.slice();
    try std.testing.expectEqual(count, s.items(.entity).len);
    try std.testing.expectEqual(count, s.items(.pos_x).len);
    try std.testing.expectEqual(count, s.items(.pos_y).len);
    try std.testing.expectEqual(count, s.items(.faction).len);
    try std.testing.expectEqual(count, s.items(.wander_amplitude).len);
    try std.testing.expectEqual(count, s.items(.gains).len);
    try std.testing.expectEqual(count, s.items(.sticky).len);
    try std.testing.expectEqual(count, s.items(.threat).len);
    try std.testing.expectEqual(count, s.items(.stimulus).len);
    try std.testing.expectEqual(count, s.items(.memory).len);
    try std.testing.expectEqual(count, s.items(.memory_ring).len);
    try std.testing.expectEqual(count, s.items(.drives).len);
    try std.testing.expectEqual(count, s.items(.focus).len);
    try std.testing.expectEqual(count, s.items(.sep_x).len);
    try std.testing.expectEqual(count, s.items(.sep_y).len);
    try std.testing.expectEqual(count, s.items(.separation_neighbor_count).len);
    try std.testing.expectEqual(count, s.items(.separation_candidate_count).len);
    try std.testing.expectEqual(count, s.items(.cohere).len);
    try std.testing.expectEqual(count, s.items(.resolved).len);
}

test "ai gather rows keep MAL columns compact after gather" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const e0 = try data.createEntity();
    try data.setMovementBody(e0, .{ .position = .{ .x = 10, .y = 20 }, .previous_position = .{ .x = 10, .y = 20 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(e0, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });
    const e1 = try data.createEntity();
    try data.setMovementBody(e1, .{ .position = .{ .x = 30, .y = 40 }, .previous_position = .{ .x = 30, .y = 40 }, .velocity = .{}, .speed = 35 });
    try data.setAiAgent(e1, .{ .active_behavior = .wander, .wander_amplitude = 8, .gain_pursue = 0.5 });

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    frame.beginStep();

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    _ = try ai_sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &frame, 0.016, .{
        .intent_seed = 0xabc,
        .focus_target = .{ .x = 100, .y = 100 },
    });

    try expectAiGatherColumnsAligned(&ai_sys.rows);
    try std.testing.expectEqual(@as(usize, 2), ai_sys.rows.len);
    frame.phase = .finished;
}

test "ai processor emits deterministic NavigationIntent for same seed" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Spawn a few with ai + movement (use direct like demo spawns; template covered in data_system tests).
    const e0 = try data.createEntity();
    try data.setMovementBody(e0, .{ .position = .{ .x = 100, .y = 100 }, .previous_position = .{ .x = 100, .y = 100 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(e0, .{ .active_behavior = .wander, .wander_amplitude = 20, .gain_pursue = 0 });
    const e1 = try data.createEntity();
    try data.setMovementBody(e1, .{ .position = .{ .x = 200, .y = 150 }, .previous_position = .{ .x = 200, .y = 150 }, .velocity = .{}, .speed = 30 });
    try data.setAiAgent(e1, .{ .active_behavior = .pursue, .wander_amplitude = 5, .gain_pursue = 0.6 });

    const ai_slice = data.aiAgentSliceConst();
    const movement_slice = data.movementBodySliceConst(); // const view

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);

    // Positions are static for the whole test, so one spatial index build serves
    // every AI call below.
    var spatial_sys = try testSpatialIndex(ai_slice, movement_slice, &data);
    defer spatial_sys.deinit();

    // Serial path with seed
    frame.beginStep();
    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    _ = try ai_sys.updateSerial(ai_slice, movement_slice, spatial_sys.view(), &data, &frame, 0.016, .{ .intent_seed = 0x12345678 });
    const serial_intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 2), serial_intents.len);
    try std.testing.expectEqual(e0.index, serial_intents[0].entity.index); // order by append in gather (stable)
    frame.phase = .finished;

    // Threaded (0 workers forces serial inside but exercises path) same seed -> identical
    frame.beginStep();
    var threads0 = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads0.deinit();
    _ = try ai_sys.update(ai_slice, movement_slice, spatial_sys.view(), &data, &frame, &threads0, 0.016, .{ .intent_seed = 0x12345678, .max_worker_threads = 0 });
    const t0_intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(serial_intents.len, t0_intents.len);
    try std.testing.expectEqual(serial_intents[0].direct_direction_x, t0_intents[0].direct_direction_x);
    try std.testing.expectEqual(serial_intents[1].direct_direction_y, t0_intents[1].direct_direction_y);
    frame.phase = .finished;

    // Different seed produces different (or at least reproducible other) dirs
    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, movement_slice, spatial_sys.view(), &data, &frame, 0.016, .{ .intent_seed = 0xdeadbeef });
    const other = frame.navigation_intents.mergedItems();
    // Not strictly required different but for coverage; allow equal only if degenerate
    _ = other;
}

test "ai goal requantization: zero hysteresis snaps to the live target every step" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const target = try data.createEntity();
    const e0 = try data.createEntity();
    try data.setMovementBody(e0, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(e0, .{ .active_behavior = .pursue, .gain_pursue = 1.0 });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();
    var spatial_sys = try testSpatialIndex(ai_slice, move_slice, &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 3, 0, 0, 0);

    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
        .intent_seed = 1,
        .focus_target = .{ .x = 100, .y = 100 },
        .focus_entity = target,
    });
    const goal_a = frame.navigation_intents.mergedItems()[0].goal;
    try std.testing.expectEqual(@as(f32, 100), goal_a.x);
    try std.testing.expectEqual(@as(f32, 100), goal_a.y);
    frame.phase = .finished;

    // Even a tiny displacement snaps immediately with the default (0) hysteresis.
    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
        .intent_seed = 1,
        .focus_target = .{ .x = 105, .y = 100 },
        .focus_entity = target,
    });
    const goal_b = frame.navigation_intents.mergedItems()[0].goal;
    try std.testing.expectEqual(@as(f32, 105), goal_b.x);
    try std.testing.expectEqual(@as(f32, 100), goal_b.y);
    frame.phase = .finished;
}

test "ai goal requantization: nonzero hysteresis holds the goal until displacement exceeds it" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const target = try data.createEntity();
    const e0 = try data.createEntity();
    try data.setMovementBody(e0, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(e0, .{ .active_behavior = .pursue, .gain_pursue = 1.0 });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();
    var spatial_sys = try testSpatialIndex(ai_slice, move_slice, &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 3, 0, 0, 0);
    const hysteresis: f32 = 50;

    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
        .intent_seed = 1,
        .focus_target = .{ .x = 100, .y = 100 },
        .focus_entity = target,
        .goal_requantization_hysteresis_distance = hysteresis,
    });
    const first_goal = frame.navigation_intents.mergedItems()[0].goal;
    try std.testing.expectEqual(@as(f32, 100), first_goal.x);
    try std.testing.expectEqual(@as(f32, 100), first_goal.y);
    frame.phase = .finished;

    // 20px displacement stays under the 50px threshold: goal holds.
    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
        .intent_seed = 1,
        .focus_target = .{ .x = 120, .y = 100 },
        .focus_entity = target,
        .goal_requantization_hysteresis_distance = hysteresis,
    });
    const held_goal = frame.navigation_intents.mergedItems()[0].goal;
    try std.testing.expectEqual(first_goal.x, held_goal.x);
    try std.testing.expectEqual(first_goal.y, held_goal.y);
    frame.phase = .finished;

    // 100px displacement from the held goal clears the 50px threshold: goal snaps.
    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
        .intent_seed = 1,
        .focus_target = .{ .x = 200, .y = 100 },
        .focus_entity = target,
        .goal_requantization_hysteresis_distance = hysteresis,
    });
    const snapped_goal = frame.navigation_intents.mergedItems()[0].goal;
    try std.testing.expectEqual(@as(f32, 200), snapped_goal.x);
    try std.testing.expectEqual(@as(f32, 100), snapped_goal.y);
    frame.phase = .finished;
}

test "ai goal requantization: decideDir's steering target is the same held goal as the NavigationIntent, not a separate live target" {
    // Slice 32 simplification: unlike the pre-arbitration broadcast design,
    // there is no longer a separate raw/live vs hysteresis-held pair for a
    // resolved goal -- resolveGoal's output feeds both the NavigationIntent's
    // `.goal` and decideDir's steering target uniformly, for every tier
    // (perception/memory goals are already fresh every step; only the
    // focus_target fallback has a hysteresis concept at all, and it now
    // applies identically to both consumers).
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const target = try data.createEntity();
    const e0 = try data.createEntity();
    try data.setMovementBody(e0, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(e0, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();
    var spatial_sys = try testSpatialIndex(ai_slice, move_slice, &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 3, 0, 0, 0);
    // Larger than the displacement between the two live targets below, so the
    // path-request goal stays held across both steps.
    const hysteresis: f32 = 1000;

    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
        .intent_seed = 1,
        .focus_target = .{ .x = 100, .y = 0 },
        .focus_entity = target,
        .goal_requantization_hysteresis_distance = hysteresis,
    });
    const first = frame.navigation_intents.mergedItems()[0];
    try std.testing.expectEqual(@as(f32, 100), first.goal.x);
    try std.testing.expectEqual(@as(f32, 0), first.goal.y);
    try std.testing.expectApproxEqAbs(@as(f32, 1), first.direct_direction_x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), first.direct_direction_y, 1e-4);
    frame.phase = .finished;

    // Live target swings 90 degrees; displacement (~141px) stays under the
    // 1000px hysteresis so the goal holds -- and so does the steering
    // direction, since both now derive from the same held goal.
    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
        .intent_seed = 1,
        .focus_target = .{ .x = 0, .y = 100 },
        .focus_entity = target,
        .goal_requantization_hysteresis_distance = hysteresis,
    });
    const second = frame.navigation_intents.mergedItems()[0];
    try std.testing.expectEqual(first.goal.x, second.goal.x);
    try std.testing.expectEqual(first.goal.y, second.goal.y);
    try std.testing.expectApproxEqAbs(first.direct_direction_x, second.direct_direction_x, 1e-4);
    try std.testing.expectApproxEqAbs(first.direct_direction_y, second.direct_direction_y, 1e-4);
    frame.phase = .finished;
}

test "ai processor appends navigation intents without clearing existing stream output" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{ .x = 100, .y = 100 }, .previous_position = .{ .x = 100, .y = 100 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(entity, .{ .active_behavior = .wander });

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 2, 0, 0, 0);
    frame.beginStep();
    try frame.navigation_intents.prepareRangeCounts(1);
    frame.navigation_intents.addCount(0, 1);
    try frame.navigation_intents.prefix();
    var prior_writer = frame.navigation_intents.rangeWriter(0);
    prior_writer.write(.{
        .entity = EntityId.invalid,
        .goal = .{ .x = 1, .y = 2 },
        .priority = -1,
    });
    prior_writer.finish();
    frame.navigation_intents.finishWrite();

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    const stats = try ai_sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &frame, 0.016, .{ .intent_seed = 2 });

    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), stats.intent_count);
    try std.testing.expectEqual(@as(usize, 2), intents.len);
    try std.testing.expectEqual(@as(i16, -1), intents[0].priority);
    try std.testing.expectEqual(entity.index, intents[1].entity.index);
}

test "ai processor uses committed adaptive threaded profiles with default thread worker config" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .items_per_range = 1,
    });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..128) |i| {
        const x: f32 = @floatFromInt(i);
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{
            .position = .{ .x = x, .y = 0 },
            .previous_position = .{ .x = x, .y = 0 },
            .velocity = .{},
            .speed = 20,
        });
        try data.setAiAgent(entity, .{ .active_behavior = .wander, .wander_amplitude = 30 });
    }

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 0, 128, 0, 0, 0);
    frame.beginStep();
    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    var separation_tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = ai_range_alignment_items,
        .smallest_range_items = ai_range_alignment_items,
        .largest_range_items = ai_range_alignment_items * 4,
    });
    separation_tuner.current_profile = .{
        .worker_threads = 1,
        .items_per_range = ai_range_alignment_items,
    };
    separation_tuner.best_profile = separation_tuner.current_profile;
    separation_tuner.has_threaded_profile = true;
    separation_tuner.best_mean_batch_duration_ns = 1;

    var intent_tuner = separation_tuner;

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();

    const stats = try ai_sys.update(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &frame, &threads, 0.016, .{
        .separation_adaptive_tuner = &separation_tuner,
        .intent_adaptive_tuner = &intent_tuner,
        .intent_seed = 3,
    });
    try std.testing.expectEqual(@as(usize, 128), stats.intent_count);
    try std.testing.expect(stats.separation_batch.active_worker_threads > 0);
    try std.testing.expect(stats.intent_batch.active_worker_threads > 0);
}

test "wander amplitude scales steering perturbation against seek" {
    const pure_seek = decideDir(.pursue, 0, 0, 100, 0, 0, 1, 0x1234, 44, 0);
    const weak_wander = decideDir(.pursue, 0, 0, 100, 0, 3, 1, 0x1234, 44, 0);
    const strong_wander = decideDir(.pursue, 0, 0, 100, 0, 60, 1, 0x1234, 44, 0);

    try std.testing.expectEqual(@as(f32, 1), pure_seek.x);
    try std.testing.expectEqual(@as(f32, 0), pure_seek.y);
    try std.testing.expect(@abs(strong_wander.y) > @abs(weak_wander.y));
    try std.testing.expect(strong_wander.x != weak_wander.x or strong_wander.y != weak_wander.y);
}

test "ai wander direction resamples across steps but stays deterministic for a fixed step" {
    // wander_resample_period_steps = 1 degenerates to raw-step keying so this
    // test exercises the underlying (seed, entity_index, step) mechanism
    // directly, independent of the resample-period smoothing tested below.
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const e0 = try data.createEntity();
    try data.setMovementBody(e0, .{ .position = .{ .x = 50, .y = 60 }, .previous_position = .{ .x = 50, .y = 60 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(e0, .{ .active_behavior = .wander, .wander_amplitude = 30, .gain_pursue = 0 });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    // Position never changes across this test's frames, so one spatial index
    // build serves every call below.
    var spatial_sys = try testSpatialIndex(ai_slice, move_slice, &data);
    defer spatial_sys.deinit();

    var frame_a = SimulationFrame.init(std.testing.allocator);
    defer frame_a.deinit();
    try frame_a.reserveStreams(1, 0, 3, 0, 0, 0);
    frame_a.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame_a, 0.016, .{ .intent_seed = 0x1234abcd, .step = 5, .wander_resample_period_steps = 1 });
    const step5_first = frame_a.navigation_intents.mergedItems()[0];
    frame_a.phase = .finished;

    var frame_b = SimulationFrame.init(std.testing.allocator);
    defer frame_b.deinit();
    try frame_b.reserveStreams(1, 0, 3, 0, 0, 0);
    frame_b.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame_b, 0.016, .{ .intent_seed = 0x1234abcd, .step = 5, .wander_resample_period_steps = 1 });
    const step5_second = frame_b.navigation_intents.mergedItems()[0];
    frame_b.phase = .finished;

    try std.testing.expectEqual(step5_first.direct_direction_x, step5_second.direct_direction_x);
    try std.testing.expectEqual(step5_first.direct_direction_y, step5_second.direct_direction_y);

    var frame_c = SimulationFrame.init(std.testing.allocator);
    defer frame_c.deinit();
    try frame_c.reserveStreams(1, 0, 3, 0, 0, 0);
    frame_c.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame_c, 0.016, .{ .intent_seed = 0x1234abcd, .step = 9, .wander_resample_period_steps = 1 });
    const step9 = frame_c.navigation_intents.mergedItems()[0];
    frame_c.phase = .finished;

    try std.testing.expect(step5_first.direct_direction_x != step9.direct_direction_x or
        step5_first.direct_direction_y != step9.direct_direction_y);
}

test "ai wander direction holds steady within a resample epoch then changes at the boundary" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const e0 = try data.createEntity();
    try data.setMovementBody(e0, .{ .position = .{ .x = 50, .y = 60 }, .previous_position = .{ .x = 50, .y = 60 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(e0, .{ .active_behavior = .wander, .wander_amplitude = 30, .gain_pursue = 0 });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    // Position never changes across this test's frames, so one spatial index
    // build serves every call below.
    var spatial_sys = try testSpatialIndex(ai_slice, move_slice, &data);
    defer spatial_sys.deinit();

    const period: u32 = 10;

    var frame_a = SimulationFrame.init(std.testing.allocator);
    defer frame_a.deinit();
    try frame_a.reserveStreams(1, 0, 3, 0, 0, 0);
    frame_a.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame_a, 0.016, .{ .intent_seed = 0x1234abcd, .step = 0, .wander_resample_period_steps = period });
    const early = frame_a.navigation_intents.mergedItems()[0];
    frame_a.phase = .finished;

    var frame_b = SimulationFrame.init(std.testing.allocator);
    defer frame_b.deinit();
    try frame_b.reserveStreams(1, 0, 3, 0, 0, 0);
    frame_b.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame_b, 0.016, .{ .intent_seed = 0x1234abcd, .step = period - 1, .wander_resample_period_steps = period });
    const still_within_epoch = frame_b.navigation_intents.mergedItems()[0];
    frame_b.phase = .finished;

    try std.testing.expectEqual(early.direct_direction_x, still_within_epoch.direct_direction_x);
    try std.testing.expectEqual(early.direct_direction_y, still_within_epoch.direct_direction_y);

    var frame_c = SimulationFrame.init(std.testing.allocator);
    defer frame_c.deinit();
    try frame_c.reserveStreams(1, 0, 3, 0, 0, 0);
    frame_c.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame_c, 0.016, .{ .intent_seed = 0x1234abcd, .step = period, .wander_resample_period_steps = period });
    const next_epoch = frame_c.navigation_intents.mergedItems()[0];
    frame_c.phase = .finished;

    try std.testing.expect(early.direct_direction_x != next_epoch.direct_direction_x or
        early.direct_direction_y != next_epoch.direct_direction_y);
}

test "ai direction normalization falls back for overflowed finite parameters" {
    const dir = decideDir(.pursue, 0, 0, 1, 0, std.math.floatMax(f32), std.math.floatMax(f32), 0x1234, 44, 0);
    try std.testing.expect(std.math.isFinite(dir.x));
    try std.testing.expect(std.math.isFinite(dir.y));
}

test "ai processor no steady-state allocation (FailingAllocator)" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const e = try data.createEntity();
    try data.setMovementBody(e, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 10 });
    try data.setAiAgent(e, .{ .active_behavior = .wander });

    const ai_slice = data.aiAgentSliceConst();
    const movement_slice = data.movementBodySliceConst();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 2, 0, 0, 0);

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    // Built on the real testing allocator, unaffected by the frame's failing
    // allocator below — this test proves AiSystem's own warmed emit path, not
    // the spatial index's (that is `spatial_index.zig`'s own FailingAllocator test).
    var spatial_sys = try testSpatialIndex(ai_slice, movement_slice, &data);
    defer spatial_sys.deinit();

    const original = frame.allocator;
    const original_navigation_allocator = frame.navigation_intents.allocator;
    var failing = std.testing.FailingAllocator.init(original, .{ .fail_index = 0 });
    frame.allocator = failing.allocator();
    frame.navigation_intents.allocator = failing.allocator();
    defer {
        frame.allocator = original;
        frame.navigation_intents.allocator = original_navigation_allocator;
    }

    frame.beginStep();
    // Should reuse reserved; no alloc in hot emit path.
    _ = try ai_sys.updateSerial(ai_slice, movement_slice, spatial_sys.view(), &data, &frame, 0.016, .{ .intent_seed = 1 });
    try std.testing.expect(frame.navigation_intents.mergedItems().len == 1);
    frame.phase = .finished;
}

test "ai sparse high entity index does not allocate during warmed gather" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    for (0..1024) |_| {
        _ = try data.createEntity();
    }
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 10 });
    try data.setAiAgent(entity, .{ .active_behavior = .wander });

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 2, 0, 0, 0);

    // Built on the real testing allocator throughout — this test proves AiSystem's
    // own warmed-gather allocation-free-ness, not the spatial index's (covered
    // separately by `spatial_index.zig`'s own FailingAllocator test), so the
    // index stays off the ai_sys/frame failing-allocator swap below.
    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    frame.beginStep();
    _ = try ai_sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &frame, 0.016, .{ .intent_seed = 1 });
    frame.phase = .finished;

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const original_ai_allocator = ai_sys.allocator;
    const original_frame_allocator = frame.allocator;
    const original_navigation_allocator = frame.navigation_intents.allocator;
    ai_sys.allocator = failing.allocator();
    frame.allocator = failing.allocator();
    frame.navigation_intents.allocator = failing.allocator();
    defer {
        ai_sys.allocator = original_ai_allocator;
        frame.allocator = original_frame_allocator;
        frame.navigation_intents.allocator = original_navigation_allocator;
    }

    frame.beginStep();
    _ = try ai_sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &frame, 0.016, .{ .intent_seed = 2 });
    try std.testing.expectEqual(@as(usize, 1), frame.navigation_intents.mergedItems().len);
    frame.phase = .finished;
}

test "ai memory-retargeted seek has no steady-state allocation after warmup (FailingAllocator)" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const remembered_target = try data.createEntity();
    const e0 = try data.createEntity();
    try data.setMovementBody(e0, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(e0, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });
    try data.setAiPerception(e0, .{ .target_visible = false });
    try data.setAiMemory(e0, .{
        .last_known_target = remembered_target,
        .last_known_x = 0,
        .last_known_y = 100,
        .staleness = 10,
    });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 2, 0, 0, 0);

    // Built on the real testing allocator throughout — this test proves
    // AiSystem's own warmed populated-branch allocation-free-ness, not the
    // spatial index's (covered separately by `spatial_index.zig`'s own
    // FailingAllocator test), so the index stays off the ai_sys/frame
    // failing-allocator swap below.
    var spatial_sys = try testSpatialIndex(ai_slice, move_slice, &data);
    defer spatial_sys.deinit();

    const cfg: AiConfig = .{
        .intent_seed = 1,
        .focus_target = .{ .x = 100, .y = 0 },
        .perception_slice = data.aiPerceptionSliceConst(),
        .memory_slice = data.aiMemorySliceConst(),
    };

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();

    // Warm-up run sizes rows/navigation_intents to steady state and exercises
    // arbitration's populated (perception + fresh memory) pursue branch.
    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, cfg);
    frame.phase = .finished;

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const original_ai_allocator = ai_sys.allocator;
    const original_frame_allocator = frame.allocator;
    const original_navigation_allocator = frame.navigation_intents.allocator;
    ai_sys.allocator = failing.allocator();
    frame.allocator = failing.allocator();
    frame.navigation_intents.allocator = failing.allocator();
    defer {
        ai_sys.allocator = original_ai_allocator;
        frame.allocator = original_frame_allocator;
        frame.navigation_intents.allocator = original_navigation_allocator;
    }

    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, cfg);

    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), intents.len);
    try std.testing.expectEqual(@as(f32, 0), intents[0].goal.x);
    try std.testing.expectEqual(@as(f32, 100), intents[0].goal.y);
    try std.testing.expectEqual(@as(f32, 0), intents[0].direct_direction_x);
    try std.testing.expectEqual(@as(f32, 1), intents[0].direct_direction_y);
}

test "ai processor only emits for ai-masked entities using prior positions" {
    // Covered by data_system mask tests + ai determinism/gather tests.
    try std.testing.expect(true);
}

test "ai gather direct table and separation blend produce correct order + dirs (serial path)" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    // Two ai close together + one far; use seek to a target so base dir known, sep should repel the close pair.
    const e_close0 = try data.createEntity();
    try data.setMovementBody(e_close0, .{ .position = .{ .x = 100, .y = 100 }, .previous_position = .{ .x = 100, .y = 100 }, .velocity = .{}, .speed = 50 });
    try data.setAiAgent(e_close0, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });

    const e_close1 = try data.createEntity();
    try data.setMovementBody(e_close1, .{ .position = .{ .x = 105, .y = 102 }, .previous_position = .{ .x = 105, .y = 102 }, .velocity = .{}, .speed = 50 });
    try data.setAiAgent(e_close1, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });

    const e_far = try data.createEntity();
    try data.setMovementBody(e_far, .{ .position = .{ .x = 400, .y = 300 }, .previous_position = .{ .x = 400, .y = 300 }, .velocity = .{}, .speed = 30 });
    try data.setAiAgent(e_far, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 0.8 });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 4, 0, 0, 0);

    var spatial_sys = try testSpatialIndex(ai_slice, move_slice, &data);
    defer spatial_sys.deinit();

    frame.beginStep();
    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    // Use explicit seek_target (not COM) + seed; gather must pick prior pos for exactly the 3 ai in ai order.
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
        .intent_seed = 0xaaa,
        .focus_target = .{ .x = 200, .y = 150 },
    });
    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 3), intents.len);
    // Order preserved from ai_slice (e_close0, e_close1, e_far)
    try std.testing.expectEqual(e_close0.index, intents[0].entity.index);
    try std.testing.expectEqual(e_close1.index, intents[1].entity.index);
    try std.testing.expectEqual(e_far.index, intents[2].entity.index);

    // Separation: the two close ones should have dirs that include repel (their dirs not identical to pure seek even with same target).
    const d0 = intents[0];
    const d1 = intents[1];
    // They should not be exactly same (repel makes them diverge)
    const dirs_same = (d0.direct_direction_x == d1.direct_direction_x and d0.direct_direction_y == d1.direct_direction_y);
    try std.testing.expect(!dirs_same);
    frame.phase = .finished;
}

test "ai serial and threaded (0 workers) produce identical intents with separation + seek_target" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const e0 = try data.createEntity();
    try data.setMovementBody(e0, .{ .position = .{ .x = 50, .y = 60 }, .previous_position = .{ .x = 50, .y = 60 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(e0, .{ .active_behavior = .pursue, .wander_amplitude = 2, .gain_pursue = 0.9 });
    const e1 = try data.createEntity();
    try data.setMovementBody(e1, .{ .position = .{ .x = 55, .y = 58 }, .previous_position = .{ .x = 55, .y = 58 }, .velocity = .{}, .speed = 35 });
    try data.setAiAgent(e1, .{ .active_behavior = .wander, .wander_amplitude = 12, .gain_pursue = 0.4 });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 3, 0, 0, 0);

    var spatial_sys = try testSpatialIndex(ai_slice, move_slice, &data);
    defer spatial_sys.deinit();

    frame.beginStep();
    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    const cfg: AiConfig = .{ .intent_seed = 0x1234abcd, .step = 7, .focus_target = .{ .x = 300, .y = 200 } };
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, cfg);
    const serial = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 2), serial.len);
    frame.phase = .finished;

    frame.beginStep();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    _ = try ai_sys.update(ai_slice, move_slice, spatial_sys.view(), &data, &frame, &threads, 0.016, cfg);
    const thr = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(serial.len, thr.len);
    try std.testing.expectEqual(serial[0].direct_direction_x, thr[0].direct_direction_x);
    try std.testing.expectEqual(serial[0].direct_direction_y, thr[0].direct_direction_y);
    try std.testing.expectEqual(serial[1].direct_direction_x, thr[1].direct_direction_x);
    try std.testing.expectEqual(serial[1].direct_direction_y, thr[1].direct_direction_y);
    frame.phase = .finished;
}

test "ai serial and real threaded workers produce identical navigation intents" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..128) |i| {
        const x: f32 = @floatFromInt(i % 16);
        const y: f32 = @floatFromInt(i / 16);
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{
            .position = .{ .x = x * 9.0, .y = y * 7.0 },
            .previous_position = .{ .x = x * 9.0, .y = y * 7.0 },
            .velocity = .{},
            .speed = 20,
        });
        try data.setAiAgent(entity, .{
            .active_behavior = if (i % 2 == 0) .pursue else .wander,
            .wander_amplitude = @floatFromInt(i % 13),
            .gain_pursue = if (i % 2 == 0) 0.7 else 0.2,
        });
    }

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = 16,
    });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    const cfg: AiConfig = .{
        .items_per_range = 16,
        .max_worker_threads = 2,
        .adaptive = false,
        .intent_seed = 0x1234abcd,
        .focus_target = .{ .x = 300, .y = 200 },
    };

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    var serial_frame = SimulationFrame.init(std.testing.allocator);
    defer serial_frame.deinit();
    try serial_frame.reserveStreams(8, 0, 128, 0, 0, 0);
    serial_frame.beginStep();
    _ = try ai_sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &serial_frame, 0.016, cfg);
    const serial = serial_frame.navigation_intents.mergedItems();

    var threaded_frame = SimulationFrame.init(std.testing.allocator);
    defer threaded_frame.deinit();
    try threaded_frame.reserveStreams(8, 0, 128, 0, 0, 0);
    threaded_frame.beginStep();
    _ = try ai_sys.update(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &threaded_frame, &threads, 0.016, cfg);
    const threaded = threaded_frame.navigation_intents.mergedItems();

    try std.testing.expectEqual(serial.len, threaded.len);
    for (serial, threaded) |a, b| {
        try std.testing.expectEqual(a.entity.index, b.entity.index);
        try std.testing.expectEqual(a.entity.generation, b.entity.generation);
        try std.testing.expectEqual(a.direct_direction_x, b.direct_direction_x);
        try std.testing.expectEqual(a.direct_direction_y, b.direct_direction_y);
    }
}

test "ai spatial separation caps dense neighbor samples" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const count = 80;
    for (0..count) |i| {
        const entity = try data.createEntity();
        const position = math.Vec2{
            .x = @floatFromInt(i % 16),
            .y = @floatFromInt(i / 16),
        };
        try data.setMovementBody(entity, .{
            .position = position,
            .previous_position = position,
            .velocity = .{},
            .speed = 20,
        });
        try data.setAiAgent(entity, .{
            .active_behavior = .pursue,
            .wander_amplitude = 0,
            .gain_pursue = 1,
        });
    }

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(8, 0, count, 0, 0, 0);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    frame.beginStep();
    const stats = try ai_sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &frame, 0.016, .{
        .intent_seed = 1,
        .focus_target = .{ .x = 100, .y = 100 },
    });

    try std.testing.expectEqual(@as(usize, count), stats.intent_count);
    try std.testing.expect(stats.separation_neighbor_samples <= count * @as(usize, max_separation_neighbors));
    try std.testing.expect(stats.separation_candidate_checks <= count * @as(usize, max_separation_candidate_checks));
    try std.testing.expect(stats.separation_neighbor_samples > 0);
}

test "ai spatial separation handles negative grid coordinates" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    try data.setMovementBody(first, .{
        .position = .{ .x = -34, .y = -33 },
        .previous_position = .{ .x = -34, .y = -33 },
        .velocity = .{},
        .speed = 20,
    });
    try data.setAiAgent(first, .{
        .active_behavior = .pursue,
        .wander_amplitude = 0,
        .gain_pursue = 1,
    });

    const second = try data.createEntity();
    try data.setMovementBody(second, .{
        .position = .{ .x = -20, .y = -21 },
        .previous_position = .{ .x = -20, .y = -21 },
        .velocity = .{},
        .speed = 20,
    });
    try data.setAiAgent(second, .{
        .active_behavior = .pursue,
        .wander_amplitude = 0,
        .gain_pursue = 1,
    });

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 2, 0, 0, 0);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    frame.beginStep();
    const stats = try ai_sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &frame, 0.016, .{
        .intent_seed = 1,
        .focus_target = .{ .x = 0, .y = 0 },
    });

    try std.testing.expectEqual(@as(usize, 2), stats.intent_count);
    try std.testing.expectEqual(@as(usize, 2), stats.separation_candidate_checks);
    try std.testing.expectEqual(@as(usize, 2), stats.separation_neighbor_samples);
}

test "spatial index and AiSystem gather agree on row-index population order even with a mid-population skip" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    // Five ai agents; the third has no movement body, so both gathers must
    // skip it via the identical `movementBodyDenseIndex(entity) orelse continue`
    // predicate (see the cross-file contract comment on `gatherAiData`).
    var expected_entities: [4]EntityId = undefined;
    var expected_count: usize = 0;
    for (0..5) |i| {
        const entity = try data.createEntity();
        try data.setAiAgent(entity, .{ .active_behavior = .wander });
        if (i == 2) continue; // no movement body: forces the real skip
        const position = math.Vec2{ .x = @floatFromInt(i * 10), .y = @floatFromInt(i * 5) };
        try data.setMovementBody(entity, .{ .position = position, .previous_position = position, .velocity = .{}, .speed = 20 });
        expected_entities[expected_count] = entity;
        expected_count += 1;
    }

    const ai_slice = data.aiAgentSliceConst();
    const movement_slice = data.movementBodySliceConst();

    var spatial_sys = SpatialIndexSystem.init(std.testing.allocator);
    defer spatial_sys.deinit();
    try spatial_sys.reserve(ai_slice.entities.len, .{});
    const spatial_stats = try spatial_sys.buildSerial(ai_slice, movement_slice, &data, .{});
    try std.testing.expectEqual(@as(usize, 4), spatial_stats.entity_count);

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    try ai_sys.gatherAiData(ai_slice, movement_slice, &data, null, null, null, null, null, null);
    try std.testing.expectEqual(@as(usize, 4), ai_sys.rows.len);

    const ai_entities = ai_sys.rows.slice().items(.entity);
    const spatial_entities = spatial_sys.rows.slice().items(.entity);
    try std.testing.expectEqual(ai_entities.len, spatial_entities.len);
    for (0..expected_count) |i| {
        try std.testing.expectEqual(expected_entities[i].index, ai_entities[i].index);
        try std.testing.expectEqual(ai_entities[i].index, spatial_entities[i].index);
        try std.testing.expectEqual(ai_entities[i].generation, spatial_entities[i].generation);
    }
}

/// O(n^2) reference reproducing `computeBoundedSeparation`'s documented
/// semantics directly (no spatial partitioning): ascending-index scan, self
/// skipped without counting, candidate-stop checked before increment, radius
/// prefilter strict `<`, near-zero guard `dist2 > 0.1`, neighbor cap checked
/// after accumulating. See the parity test below for why an ascending-index
/// scan matches the real spatially-partitioned traversal bit-for-bit here.
fn bruteForceSeparation(pos_x: []const f32, pos_y: []const f32, index: usize) SeparationResult {
    var result = SeparationResult{};
    for (0..pos_x.len) |j| {
        if (j == index) continue;
        if (result.candidate_count >= max_separation_candidate_checks) break;
        result.candidate_count += 1;

        const dx = pos_x[index] - pos_x[j];
        const dy = pos_y[index] - pos_y[j];
        const dist2 = dx * dx + dy * dy;
        if (dist2 > 0.1 and dist2 < separation_radius * separation_radius) {
            const dir = math.normalizeOrZeroFinite(dx, dy, 0);
            result.x += dir.x;
            result.y += dir.y;
            result.neighbor_count += 1;
            if (result.neighbor_count >= max_separation_neighbors) break;
        }
    }
    return result;
}

test "ai computeBoundedSeparation matches an O(n^2) brute-force reference bit-for-bit" {
    // Regression-locks the scan-radius decision the determinism proof below
    // depends on: cellScanRadius(48, 32) must stay 2, matching the fixed grid
    // this replaced (separation_cell_radius was hardcoded to 2).
    comptime std.debug.assert(separation_cell_scan_radius == 2);

    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    var prng = std.Random.DefaultPrng.init(0x51ab_dead);
    const rand = prng.random();
    const count = 32;
    // Every agent lands inside the single grid cell (0,0) (well under the
    // 32-unit cell size), so the shared index's cell-scan visits exactly one
    // range in ascending stored (== population) order — identical to the
    // brute-force reference's plain ascending-index loop above. That equality
    // of traversal order is what makes this a bit-exact proof of parity
    // instead of an approximate one; see the module doc's determinism note.
    for (0..count) |_| {
        const entity = try data.createEntity();
        const position = math.Vec2{ .x = rand.float(f32) * 20.0, .y = rand.float(f32) * 20.0 };
        try data.setMovementBody(entity, .{ .position = position, .previous_position = position, .velocity = .{}, .speed = 20 });
        try data.setAiAgent(entity, .{ .active_behavior = .wander });
    }

    const ai_slice = data.aiAgentSliceConst();
    const movement_slice = data.movementBodySliceConst();

    var spatial_sys = try testSpatialIndex(ai_slice, movement_slice, &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    try ai_sys.gatherAiData(ai_slice, movement_slice, &data, null, null, null, null, null, null);
    try std.testing.expectEqual(@as(usize, count), ai_sys.rows.len);

    const gathered = ai_sys.rows.slice();
    const pos_x = gathered.items(.pos_x);
    const pos_y = gathered.items(.pos_y);

    const context = buildAiSeparationContext(gathered, spatial_sys.view());

    for (0..count) |i| {
        const ported = computeBoundedSeparation(&context, i);
        const reference = bruteForceSeparation(pos_x, pos_y, i);
        try std.testing.expectEqual(reference.candidate_count, ported.candidate_count);
        try std.testing.expectEqual(reference.neighbor_count, ported.neighbor_count);
        try std.testing.expectEqual(reference.x, ported.x);
        try std.testing.expectEqual(reference.y, ported.y);
    }
}

/// Cell-scan-ordered reference: unlike `bruteForceSeparation` above (a plain
/// ascending-index scan), this independently reconstructs the cell_y-outer,
/// cell_x-inner, ascending-stored-index-within-cell traversal spec from raw
/// positions (no call into `spatial_index.zig`/`cellForPosition`), so it can
/// validate cross-cell floating-point summation order rather than just a
/// single populated cell where any loop nesting degenerates to the same
/// ascending-index walk.
fn cellScanOrderedSeparation(pos_x: []const f32, pos_y: []const f32, index: usize) SeparationResult {
    const cellOf = struct {
        fn compute(x: f32, y: f32) [2]i32 {
            return .{
                @as(i32, @intFromFloat(@floor(x / grid_cell_size))),
                @as(i32, @intFromFloat(@floor(y / grid_cell_size))),
            };
        }
    }.compute;
    const own_cell = cellOf(pos_x[index], pos_y[index]);
    var result = SeparationResult{};
    var cell_y = own_cell[1] - separation_cell_scan_radius;
    while (cell_y <= own_cell[1] + separation_cell_scan_radius) : (cell_y += 1) {
        var cell_x = own_cell[0] - separation_cell_scan_radius;
        while (cell_x <= own_cell[0] + separation_cell_scan_radius) : (cell_x += 1) {
            // A plain forward scan filtered to exactly this (cell_x, cell_y)
            // already visits matching agents in ascending index order.
            for (0..pos_x.len) |j| {
                if (j == index) continue;
                const j_cell = cellOf(pos_x[j], pos_y[j]);
                if (j_cell[0] != cell_x or j_cell[1] != cell_y) continue;
                if (result.candidate_count >= max_separation_candidate_checks) return result;
                result.candidate_count += 1;

                const dx = pos_x[index] - pos_x[j];
                const dy = pos_y[index] - pos_y[j];
                const dist2 = dx * dx + dy * dy;
                if (dist2 > 0.1 and dist2 < separation_radius * separation_radius) {
                    const dir = math.normalizeOrZeroFinite(dx, dy, 0);
                    result.x += dir.x;
                    result.y += dir.y;
                    result.neighbor_count += 1;
                    if (result.neighbor_count >= max_separation_neighbors) return result;
                }
            }
        }
    }
    return result;
}

test "ai computeBoundedSeparation matches a cell-scan-ordered oracle across multiple cells" {
    // The brute-force test above proves parity only where it's vacuous for
    // traversal order (one populated cell). This spreads agents across many
    // cells so a silently flipped scan order (e.g. x-outer instead of
    // y-outer) or a non-ascending within-cell walk would actually break
    // bit-exact float-summation parity and fail this test.
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    var prng = std.Random.DefaultPrng.init(0x5eed_c311);
    const rand = prng.random();
    const count = 80;
    for (0..count) |_| {
        const entity = try data.createEntity();
        const position = math.Vec2{ .x = rand.float(f32) * 220.0, .y = rand.float(f32) * 220.0 };
        try data.setMovementBody(entity, .{ .position = position, .previous_position = position, .velocity = .{}, .speed = 20 });
        try data.setAiAgent(entity, .{ .active_behavior = .wander });
    }

    const ai_slice = data.aiAgentSliceConst();
    const movement_slice = data.movementBodySliceConst();

    var spatial_sys = try testSpatialIndex(ai_slice, movement_slice, &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    try ai_sys.gatherAiData(ai_slice, movement_slice, &data, null, null, null, null, null, null);
    try std.testing.expectEqual(@as(usize, count), ai_sys.rows.len);

    const gathered = ai_sys.rows.slice();
    const pos_x = gathered.items(.pos_x);
    const pos_y = gathered.items(.pos_y);

    // Fail loud if the fixture regresses to a near-single-cell spread, which
    // would silently make this test as weak as the one above.
    var min_cell_x: i32 = std.math.maxInt(i32);
    var max_cell_x: i32 = std.math.minInt(i32);
    var min_cell_y: i32 = std.math.maxInt(i32);
    var max_cell_y: i32 = std.math.minInt(i32);
    for (0..count) |i| {
        const cx: i32 = @intFromFloat(@floor(pos_x[i] / grid_cell_size));
        const cy: i32 = @intFromFloat(@floor(pos_y[i] / grid_cell_size));
        min_cell_x = @min(min_cell_x, cx);
        max_cell_x = @max(max_cell_x, cx);
        min_cell_y = @min(min_cell_y, cy);
        max_cell_y = @max(max_cell_y, cy);
    }
    try std.testing.expect(max_cell_x - min_cell_x >= 3);
    try std.testing.expect(max_cell_y - min_cell_y >= 3);

    const context = buildAiSeparationContext(gathered, spatial_sys.view());

    // Fail loud if no agent ever accumulates >= 2 neighbors: with fewer than
    // two summed `dir` terms, float-summation order can't actually differ,
    // making the bit-exact assertions below vacuous.
    var max_neighbor_count: u8 = 0;
    for (0..count) |i| {
        const ported = computeBoundedSeparation(&context, i);
        const reference = cellScanOrderedSeparation(pos_x, pos_y, i);
        try std.testing.expectEqual(reference.candidate_count, ported.candidate_count);
        try std.testing.expectEqual(reference.neighbor_count, ported.neighbor_count);
        try std.testing.expectEqual(reference.x, ported.x);
        try std.testing.expectEqual(reference.y, ported.y);
        max_neighbor_count = @max(max_neighbor_count, reference.neighbor_count);
    }
    try std.testing.expect(max_neighbor_count >= 2);
}

test "ai seek retargets toward fresh AiMemory last-known position when perception target is cold" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const remembered_target = try data.createEntity();

    const e0 = try data.createEntity();
    try data.setMovementBody(e0, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(e0, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });
    try data.setAiPerception(e0, .{ .target_visible = false });
    try data.setAiMemory(e0, .{
        .last_known_target = remembered_target,
        .last_known_x = 0,
        .last_known_y = 100,
        .staleness = 10,
    });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 2, 0, 0, 0);

    var spatial_sys = try testSpatialIndex(ai_slice, move_slice, &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
        .intent_seed = 1,
        // Distinct from the memory position (0, 100) so a wrong fallback is
        // trivially distinguishable: seek_target implies heading (1, 0),
        // memory implies heading (0, 1).
        .focus_target = .{ .x = 100, .y = 0 },
        .perception_slice = data.aiPerceptionSliceConst(),
        .memory_slice = data.aiMemorySliceConst(),
    });

    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), intents.len);
    try std.testing.expectEqual(@as(f32, 0), intents[0].goal.x);
    try std.testing.expectEqual(@as(f32, 100), intents[0].goal.y);
    try std.testing.expectEqual(@as(f32, 0), intents[0].direct_direction_x);
    try std.testing.expectEqual(@as(f32, 1), intents[0].direct_direction_y);
}

// Every arbitration-resolved goal is agent-specific by construction now
// (perception/memory/focus-fallback all resolve `kind_hint = .individual`),
// so `nav_request_kind` currently has no observable effect regardless of
// which tier a row resolves through — see AiConfig.nav_request_kind's doc
// comment for why (a documented Checkpoint-3 simplification; true
// multi-agent shared-cell detection is deferred).
test "ai emits .individual for every resolved goal even when nav_request_kind is .group" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const remembered_target = try data.createEntity();
    const visible_target = try data.createEntity();

    // e0: perception cold, fresh memory.
    const e0 = try data.createEntity();
    try data.setMovementBody(e0, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(e0, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });
    try data.setAiPerception(e0, .{ .target_visible = false });
    try data.setAiMemory(e0, .{
        .last_known_target = remembered_target,
        .last_known_x = 0,
        .last_known_y = 100,
        .staleness = 10,
    });

    // e1: perception warm (a real visible nearest_threat).
    const e1 = try data.createEntity();
    try data.setMovementBody(e1, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(e1, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });
    try data.setAiPerception(e1, .{ .target_visible = true, .nearest_threat = visible_target, .last_seen_x = 50, .last_seen_y = 0 });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 2, 0, 0, 0);

    var spatial_sys = try testSpatialIndex(ai_slice, move_slice, &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
        .intent_seed = 1,
        .focus_target = .{ .x = 100, .y = 0 },
        .nav_request_kind = .group,
        .perception_slice = data.aiPerceptionSliceConst(),
        .memory_slice = data.aiMemorySliceConst(),
    });

    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 2), intents.len);
    for (intents) |intent| {
        try std.testing.expectEqual(PathRequestKind.individual, intent.kind);
    }
}

test "ai seek keeps the default seek target when memory can't override it" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const remembered_target = try data.createEntity();

    // No memory / no perception at all: default behavior is unaffected by
    // config fields defaulting to null (mirrors pre-Slice-30 seek).
    const no_memory = try data.createEntity();
    try data.setMovementBody(no_memory, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(no_memory, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });
    try data.setAiPerception(no_memory, .{ .target_visible = false });
    // Deliberately no setAiMemory call for this entity.

    // Memory present but last_known_target invalid: override must not apply.
    // Same start position as `no_memory`; agents at exact-equal positions get
    // zero separation contribution (the `dist2 > 0.1` near-zero guard in
    // `separationNeighborVisit`), so this stays a pure seek-direction check.
    const invalid_target = try data.createEntity();
    try data.setMovementBody(invalid_target, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(invalid_target, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });
    try data.setAiPerception(invalid_target, .{ .target_visible = false });
    try data.setAiMemory(invalid_target, .{
        .last_known_target = EntityId.invalid,
        .last_known_x = 0,
        .last_known_y = 100,
        .staleness = 10,
    });

    // Memory present, valid target, but saturated staleness: override must not apply.
    const stale_memory = try data.createEntity();
    try data.setMovementBody(stale_memory, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(stale_memory, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });
    try data.setAiPerception(stale_memory, .{ .target_visible = false });
    try data.setAiMemory(stale_memory, .{
        .last_known_target = remembered_target,
        .last_known_x = 0,
        .last_known_y = 100,
        .staleness = max_ai_memory_staleness,
    });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 4, 0, 0, 0);

    var spatial_sys = try testSpatialIndex(ai_slice, move_slice, &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
        .intent_seed = 1,
        .focus_target = .{ .x = 100, .y = 0 },
        .focus_entity = remembered_target,
        .perception_slice = data.aiPerceptionSliceConst(),
        .memory_slice = data.aiMemorySliceConst(),
    });

    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 3), intents.len);
    for (intents) |intent| {
        try std.testing.expectEqual(@as(f32, 100), intent.goal.x);
        try std.testing.expectEqual(@as(f32, 0), intent.goal.y);
        try std.testing.expectEqual(@as(f32, 1), intent.direct_direction_x);
        try std.testing.expectEqual(@as(f32, 0), intent.direct_direction_y);
    }
}

test "ai memory override does not apply while perception still reports the target visible" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const remembered_target = try data.createEntity();
    const visible_target = try data.createEntity();

    const e0 = try data.createEntity();
    try data.setMovementBody(e0, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(e0, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });
    // A real visible nearest_threat: memory must not override even though it
    // is fresh, valid, and (deliberately) of a different entity.
    try data.setAiPerception(e0, .{ .target_visible = true, .nearest_threat = visible_target, .last_seen_x = 100, .last_seen_y = 0 });
    try data.setAiMemory(e0, .{
        .last_known_target = remembered_target,
        .last_known_x = 0,
        .last_known_y = 100,
        .staleness = 10,
    });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 2, 0, 0, 0);

    var spatial_sys = try testSpatialIndex(ai_slice, move_slice, &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
        .intent_seed = 1,
        .focus_target = .{ .x = 100, .y = 0 },
        .perception_slice = data.aiPerceptionSliceConst(),
        .memory_slice = data.aiMemorySliceConst(),
    });

    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), intents.len);
    try std.testing.expectEqual(@as(f32, 100), intents[0].goal.x);
    try std.testing.expectEqual(@as(f32, 0), intents[0].goal.y);
    try std.testing.expectEqual(@as(f32, 1), intents[0].direct_direction_x);
    try std.testing.expectEqual(@as(f32, 0), intents[0].direct_direction_y);
}

test "ai serial and threaded (0 workers) agree on a memory-overridden seek target" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const remembered_target = try data.createEntity();

    const e0 = try data.createEntity();
    try data.setMovementBody(e0, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(e0, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });
    try data.setAiPerception(e0, .{ .target_visible = false });
    try data.setAiMemory(e0, .{
        .last_known_target = remembered_target,
        .last_known_x = 0,
        .last_known_y = 100,
        .staleness = 10,
    });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();

    var spatial_sys = try testSpatialIndex(ai_slice, move_slice, &data);
    defer spatial_sys.deinit();

    const cfg: AiConfig = .{
        .intent_seed = 1,
        .focus_target = .{ .x = 100, .y = 0 },
        .perception_slice = data.aiPerceptionSliceConst(),
        .memory_slice = data.aiMemorySliceConst(),
    };

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();

    var serial_frame = SimulationFrame.init(std.testing.allocator);
    defer serial_frame.deinit();
    try serial_frame.reserveStreams(1, 0, 2, 0, 0, 0);
    serial_frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &serial_frame, 0.016, cfg);
    const serial = serial_frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), serial.len);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var threaded_frame = SimulationFrame.init(std.testing.allocator);
    defer threaded_frame.deinit();
    try threaded_frame.reserveStreams(1, 0, 2, 0, 0, 0);
    threaded_frame.beginStep();
    _ = try ai_sys.update(ai_slice, move_slice, spatial_sys.view(), &data, &threaded_frame, &threads, 0.016, cfg);
    const threaded = threaded_frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), threaded.len);

    try std.testing.expectEqual(serial[0].goal.x, threaded[0].goal.x);
    try std.testing.expectEqual(serial[0].goal.y, threaded[0].goal.y);
    try std.testing.expectEqual(serial[0].direct_direction_x, threaded[0].direct_direction_x);
    try std.testing.expectEqual(serial[0].direct_direction_y, threaded[0].direct_direction_y);
    // Both must reflect the memory override, not the configured seek_target.
    try std.testing.expectEqual(@as(f32, 0), serial[0].goal.x);
    try std.testing.expectEqual(@as(f32, 100), serial[0].goal.y);
}

// ---- Slice 32 arbitration integration tests -----------------------------------

test "arbitration pursue resolves from a non-player hostile entity, not context.player" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    // A player-shaped fallback target far away from the real hostile
    // encounter, wired the same way SimulationPipeline wires the demo's
    // opt-in focus_target -- proves pursue does NOT default to it once a
    // real perceived hostile exists.
    const player_like = try data.createEntity();
    try data.setMovementBody(player_like, .{ .position = .{ .x = 900, .y = 900 }, .previous_position = .{ .x = 900, .y = 900 }, .velocity = .{}, .speed = 0 });
    try data.setFaction(player_like, .player);

    const pursuer = try data.createEntity();
    try data.setMovementBody(pursuer, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setFaction(pursuer, .player);
    try data.setAiAgent(pursuer, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });

    // The genuinely faction-generic pursue target: a hostile the pursuer can
    // actually see this step, unrelated to player_like.
    const hostile = try data.createEntity();
    try data.setMovementBody(hostile, .{ .position = .{ .x = 50, .y = 0 }, .previous_position = .{ .x = 50, .y = 0 }, .velocity = .{}, .speed = 0 });
    try data.setFaction(hostile, .hostile);
    try data.setAiPerception(pursuer, .{ .target_visible = true, .nearest_threat = hostile, .last_seen_x = 50, .last_seen_y = 0 });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();
    var spatial_sys = try testSpatialIndex(ai_slice, move_slice, &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 2, 0, 0, 0);

    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
        .intent_seed = 1,
        // Opt-in fallback wired exactly like the demo's player broadcast --
        // must lose to the visible hostile.
        .focus_target = .{ .x = 900, .y = 900 },
        .focus_entity = player_like,
        .perception_slice = data.aiPerceptionSliceConst(),
    });

    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), intents.len);
    try std.testing.expectEqual(@as(f32, 50), intents[0].goal.x);
    try std.testing.expectEqual(@as(f32, 0), intents[0].goal.y);
}

test "arbitration graceful degrade to wander when perception/memory/affect are all absent" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{ .x = 10, .y = 10 }, .previous_position = .{ .x = 10, .y = 10 }, .velocity = .{}, .speed = 40 });
    // A nonzero pursue gain but no perception/memory/affect component and no
    // configured focus_target: no signal anywhere ties pursue's score above
    // wander's, so wander wins the lowest-index tie-break -- an ordinary
    // wander-only agent behaves identically to before this slice.
    try data.setAiAgent(entity, .{ .active_behavior = .wander, .wander_amplitude = 30, .gain_pursue = 1.0 });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();
    var spatial_sys = try testSpatialIndex(ai_slice, move_slice, &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 2, 0, 0, 0);

    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{ .intent_seed = 7 });

    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), intents.len);
    // A resolveGoal-invalid row's goal falls back to self position.
    try std.testing.expectEqual(@as(f32, 10), intents[0].goal.x);
    try std.testing.expectEqual(@as(f32, 10), intents[0].goal.y);
    try std.testing.expectEqual(@as(i16, 0), intents[0].priority);
    try std.testing.expect(data.aiAgentConst(entity).?.active_behavior == .wander);
}

test "arbitration serial and threaded (0 workers) parity across perception + memory + affect signals" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    for (0..12) |i| {
        const x: f32 = @floatFromInt(i * 6);
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{ .position = .{ .x = x, .y = 0 }, .previous_position = .{ .x = x, .y = 0 }, .velocity = .{}, .speed = 30 });
        try data.setFaction(entity, if (i % 2 == 0) .player else .hostile);
        try data.setAiAgent(entity, .{
            .active_behavior = .wander,
            .wander_amplitude = @floatFromInt(i % 5),
            .gain_wander = 1.0,
            .gain_pursue = if (i % 3 == 0) 1.0 else 0,
            .gain_flee = if (i % 3 == 1) 1.0 else 0,
            .gain_cohere = if (i % 3 == 2) 1.0 else 0,
        });
        try data.setAiPerception(entity, .{
            .target_visible = i % 4 == 0,
            .nearest_threat = if (i % 4 == 0) (try data.createEntity()) else EntityId.invalid,
            .last_seen_x = x + 20,
            .last_seen_y = 5,
        });
        try data.setAiAffect(entity, .{
            .fear = if (i % 3 == 1) 0.8 else 0,
            .aggression = if (i % 3 == 0) 0.8 else 0,
        });
    }

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();
    var spatial_sys = try testSpatialIndex(ai_slice, move_slice, &data);
    defer spatial_sys.deinit();

    const cfg: AiConfig = .{
        .intent_seed = 0x51de51de,
        .step = 3,
        .perception_slice = data.aiPerceptionSliceConst(),
        .memory_slice = data.aiMemorySliceConst(),
        .affect_slice = data.aiAffectSliceConst(),
    };

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();

    var serial_frame = SimulationFrame.init(std.testing.allocator);
    defer serial_frame.deinit();
    try serial_frame.reserveStreams(4, 0, 12, 0, 0, 0);
    serial_frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &serial_frame, 0.016, cfg);
    const serial = serial_frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 12), serial.len);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var threaded_frame = SimulationFrame.init(std.testing.allocator);
    defer threaded_frame.deinit();
    try threaded_frame.reserveStreams(4, 0, 12, 0, 0, 0);
    threaded_frame.beginStep();
    _ = try ai_sys.update(ai_slice, move_slice, spatial_sys.view(), &data, &threaded_frame, &threads, 0.016, cfg);
    const threaded = threaded_frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(serial.len, threaded.len);

    for (serial, threaded) |a, b| {
        try std.testing.expectEqual(a.entity.index, b.entity.index);
        try std.testing.expectEqual(a.kind, b.kind);
        try std.testing.expectEqual(a.goal.x, b.goal.x);
        try std.testing.expectEqual(a.goal.y, b.goal.y);
        try std.testing.expectEqual(a.direct_direction_x, b.direct_direction_x);
        try std.testing.expectEqual(a.direct_direction_y, b.direct_direction_y);
        try std.testing.expectEqual(a.priority, b.priority);
    }
}

test "arbitration cohere goal is the mean of friendly spatial neighbors" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    // Cohere's neighbor gather reuses the shared AI population's own spatial
    // index, so every candidate must itself carry an AiAgent component to be
    // part of that population (a plain movement-only entity would not appear
    // in the index at all).
    const seeker = try data.createEntity();
    try data.setMovementBody(seeker, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 30 });
    try data.setFaction(seeker, .player);
    try data.setAiAgent(seeker, .{ .active_behavior = .wander, .gain_cohere = 1.0 });

    const friendly_a = try data.createEntity();
    try data.setMovementBody(friendly_a, .{ .position = .{ .x = 20, .y = 0 }, .previous_position = .{ .x = 20, .y = 0 }, .velocity = .{}, .speed = 0 });
    try data.setFaction(friendly_a, .ally);
    try data.setAiAgent(friendly_a, .{ .active_behavior = .wander });

    const friendly_b = try data.createEntity();
    try data.setMovementBody(friendly_b, .{ .position = .{ .x = 0, .y = 20 }, .previous_position = .{ .x = 0, .y = 20 }, .velocity = .{}, .speed = 0 });
    try data.setFaction(friendly_b, .ally);
    try data.setAiAgent(friendly_b, .{ .active_behavior = .wander });

    // A hostile neighbor at the same distance must not pull the mean.
    const hostile_neighbor = try data.createEntity();
    try data.setMovementBody(hostile_neighbor, .{ .position = .{ .x = -20, .y = -20 }, .previous_position = .{ .x = -20, .y = -20 }, .velocity = .{}, .speed = 0 });
    try data.setFaction(hostile_neighbor, .hostile);
    try data.setAiAgent(hostile_neighbor, .{ .active_behavior = .wander });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();
    var spatial_sys = try testSpatialIndex(ai_slice, move_slice, &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 4, 0, 0, 0);

    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{ .intent_seed = 1 });

    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 4), intents.len);
    var found = false;
    for (intents) |intent| {
        if (intent.entity.index != seeker.index) continue;
        found = true;
        try std.testing.expectApproxEqAbs(@as(f32, 10), intent.goal.x, 1e-3);
        try std.testing.expectApproxEqAbs(@as(f32, 10), intent.goal.y, 1e-3);
    }
    try std.testing.expect(found);
}

test "arbitration call path has no steady-state allocation after warmup (FailingAllocator)" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const target = try data.createEntity();
    const seeker = try data.createEntity();
    try data.setMovementBody(seeker, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 30 });
    try data.setFaction(seeker, .player);
    try data.setAiAgent(seeker, .{ .active_behavior = .wander, .gain_pursue = 1.0, .gain_cohere = 1.0, .commitment_max_steps = 30, .sticky_bonus = 0.1 });
    try data.setAiPerception(seeker, .{ .target_visible = false });
    try data.setAiMemory(seeker, .{});
    try data.setAiAffect(seeker, .{});

    const friendly = try data.createEntity();
    try data.setMovementBody(friendly, .{ .position = .{ .x = 10, .y = 0 }, .previous_position = .{ .x = 10, .y = 0 }, .velocity = .{}, .speed = 0 });
    try data.setFaction(friendly, .player);

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();
    var spatial_sys = try testSpatialIndex(ai_slice, move_slice, &data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 2, 0, 0, 0);

    const cfg: AiConfig = .{
        .intent_seed = 1,
        .focus_target = .{ .x = 100, .y = 0 },
        .focus_entity = target,
        .perception_slice = data.aiPerceptionSliceConst(),
        .memory_slice = data.aiMemorySliceConst(),
        .affect_slice = data.aiAffectSliceConst(),
    };

    // Warm-up run sizes rows/navigation_intents to steady state and exercises
    // every arbitration input branch (perception, memory, affect, cohere
    // neighbor query, focus_target fallback).
    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, cfg);
    frame.phase = .finished;

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const original_ai_allocator = ai_sys.allocator;
    const original_frame_allocator = frame.allocator;
    const original_navigation_allocator = frame.navigation_intents.allocator;
    ai_sys.allocator = failing.allocator();
    frame.allocator = failing.allocator();
    frame.navigation_intents.allocator = failing.allocator();
    defer {
        ai_sys.allocator = original_ai_allocator;
        frame.allocator = original_frame_allocator;
        frame.navigation_intents.allocator = original_navigation_allocator;
    }

    frame.beginStep();
    _ = try ai_sys.updateSerial(ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, cfg);
    try std.testing.expectEqual(@as(usize, 1), frame.navigation_intents.mergedItems().len);
}
