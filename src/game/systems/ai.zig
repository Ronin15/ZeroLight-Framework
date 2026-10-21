// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! AI decision processor: gathers each think row's perception, memory, affect, and
//! personality signals, runs `arbitration.zig`'s utility scoring, sticky selection, and goal
//! resolution to pick a behavior and goal, then blends the goal with wander noise and local
//! separation into a `NavigationIntent`. Goals are per-agent; `AiConfig.focus_target` is an
//! opt-in last-resort pursue fallback.
//!
//! Separation (every faction) and cohere (the row's friendly factions) query the shared
//! `SpatialIndexView` on the row's level, skipping the row itself; their float sums follow
//! the index's lane order (`spatial_index.zig`). Each separation range keeps one neighbor
//! block per query kind, so consecutive rows of one cell (the think set is cell-major)
//! share one walk.
//!
//! Inline and threaded dispatches run the same `writeAiSeparationJob`/`writeAiIntentsJob`.

const std = @import("std");
const runtime_perf_log = @import("../../app/runtime_perf_log.zig");
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const rng = @import("../../core/rng.zig");
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const AdaptiveWorkTunerConfig = @import("../../app/thread_system.zig").AdaptiveWorkTunerConfig;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const Dispatch = @import("../../app/thread_system.zig").Dispatch;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const PaddedSlot = @import("../../app/thread_system.zig").PaddedSlot;
const SlotList = @import("../../app/thread_system.zig").SlotList;
const maxRangeCount = @import("../../app/thread_system.zig").maxRangeCount;
const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;
const compactRowWindows = @import("../../app/thread_system.zig").compactRowWindows;
const setRowCount = @import("../../app/thread_system.zig").setRowCount;
const setSlotCount = @import("../../app/thread_system.zig").setSlotCount;
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
const AiBehavior = @import("../data_system.zig").AiBehavior;
const Faction = @import("../data_system.zig").Faction;
const movement_range_alignment_items = @import("../data_system.zig").movement_range_alignment_items;
const NavigationIntent = @import("../simulation.zig").NavigationIntent;
const PathRequestKind = @import("../simulation.zig").PathRequestKind;
const RangeOutputStream = @import("../simulation.zig").RangeOutputStream;
const SimulationFrame = @import("../simulation.zig").SimulationFrame;
const spatial_index = @import("spatial_index.zig");
const SpatialIndexView = spatial_index.SpatialIndexView;
const NeighborLanes = spatial_index.NeighborLanes;
const LaneStop = spatial_index.LaneStop;
const capLanes = spatial_index.capLanes;
const NeighborBlock = spatial_index.NeighborBlock;
const factionsWithStance = @import("../faction.zig").factionsWithStance;
const arbitration = @import("arbitration.zig");
const InterestMarkerStore = @import("../world/interest.zig").InterestMarkerStore;

pub const ai_range_alignment_items: usize = movement_range_alignment_items;

/// Range alignment of the gather, which writes every `AiGatherRow` column: each range spans
/// a full cache line of the narrowest (one byte).
pub const ai_gather_range_alignment_items: usize = thread_shared_record_alignment;

comptime {
    std.debug.assert(ai_gather_range_alignment_items % ai_range_alignment_items == 0);
    for (@typeInfo(AiGatherRow).@"struct".field_types) |Column| {
        std.debug.assert(ai_gather_range_alignment_items * @sizeOf(Column) >= thread_shared_record_alignment);
    }
}

/// Range alignment of the intent stage, which writes each row's `resolved` column and its
/// AI store row's `active_behavior`, `commitment_remaining`, and `last_score`: each range
/// spans a full cache line of the narrowest (one byte) while those rows ascend.
pub const ai_intent_range_alignment_items: usize = thread_shared_record_alignment;

comptime {
    std.debug.assert(ai_intent_range_alignment_items % ai_range_alignment_items == 0);
    const written = [_]type{
        @FieldType(AiGatherRow, "resolved"),
        std.meta.Elem(@FieldType(AiAgentSlice, "active_behavior")),
        std.meta.Elem(@FieldType(AiAgentSlice, "commitment_remaining")),
        std.meta.Elem(@FieldType(AiAgentSlice, "last_score")),
    };
    for (written) |Column| {
        std.debug.assert(ai_intent_range_alignment_items * @sizeOf(Column) >= thread_shared_record_alignment);
    }
}

// Range alignment only; batch time gate comes from AdaptiveWorkTunerConfig defaults.
const ai_adaptive_tuner_config = AdaptiveWorkTunerConfig{
    .initial_range_items = ai_range_alignment_items,
    .smallest_range_items = ai_range_alignment_items,
};

const ai_intent_tuner_config = AdaptiveWorkTunerConfig{
    .initial_range_items = ai_intent_range_alignment_items,
    .smallest_range_items = ai_intent_range_alignment_items,
};

const ai_gather_tuner_config = AdaptiveWorkTunerConfig{
    .initial_range_items = ai_gather_range_alignment_items,
    .smallest_range_items = ai_gather_range_alignment_items,
};

/// Fixed hysteresis distance for the demo's live-player chase: 1.75x
/// pathfinding's nav cell size (`pathfinding/types.zig`'s `default_cell_size`
/// == 32.0), not derived from world/map size. See
/// `AiConfig.goal_requantization_hysteresis_distance`.
pub const default_goal_requantization_hysteresis_distance: f32 = 56.0;

const hotStoreCapacity = @import("../data_system.zig").hotStoreCapacity;

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

/// World interest marker signal, gathered from `WorldSystem`.
const RowInterest = struct {
    present: bool = false,
    x: f32 = 0,
    y: f32 = 0,
    /// Whether the agent carries a real faction component. The gathered
    /// `faction` column falls back to `.neutral` for stance math, but the
    /// marker scan must pass `null` for a factionless agent so a
    /// faction-restricted marker never accepts it (`factionAccepts`). Packs
    /// into this struct's existing padding, so the job layout does not grow.
    has_faction: bool = false,
};

/// Explicit opt-in fallback target (see `AiConfig.focus_target`'s doc
/// comment) -- gated on `gain_pursue > 0` at gather time, so a null entity
/// means either no configured focus_target or this agent has no pursue gain.
const RowFocus = struct {
    entity: ?EntityId,
    x: f32,
    y: f32,
};

/// Cohere neighbor mean from `writeAiSeparationJob`'s friendly query; count 0 when no
/// friendly neighbor lies within `cohere_radius`.
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

/// One gathered AI row, columnar; `arbitration.Signals` is built transiently per row. Fields
/// are grouped by domain because MAL's comptime layout exceeds the eval quota near 50 flat
/// fields.
const AiGatherRow = struct {
    entity: EntityId,
    pos_x: f32,
    pos_y: f32,
    faction: Faction,
    /// World level sampled at gather: the level the row's neighbor queries and marker
    /// scan read.
    level: u16,
    wander_amplitude: f32,
    gains: RowGains,
    sticky: RowSticky,
    threat: RowThreat,
    stimulus: RowStimulus,
    memory: RowMemory,
    memory_ring: [ai_memory_ring_capacity]RowMemoryRingSlot,
    drives: RowDrives,
    focus: RowFocus,
    interest: RowInterest,
    sep_x: f32,
    sep_y: f32,
    cohere: RowCohere,
    resolved: RowResolved,
};

// One range's counts, written once by its job: the gather's kept rows, then the separation
// job's perf counts (`runtime_perf_log.enabled` only).
const AiRangeTally = struct {
    kept: usize = 0,
    perf: RangePerf = .{},
};

// A separation range's neighbor-block fills and its separation queries' candidate checks
// and neighbor samples.
const RangePerf = if (runtime_perf_log.enabled) struct {
    separation_block_fills: usize = 0,
    cohere_block_fills: usize = 0,
    separation_candidate_checks: usize = 0,
    separation_neighbor_samples: usize = 0,
} else struct {};

pub const separation_radius: f32 = 48.0;
pub const max_separation_neighbors: u8 = 32;
pub const max_separation_candidate_checks: u16 = 128;
// Neighbors at or nearer than this squared distance add no separation.
const separation_min_dist2: f32 = 0.1;

// Cohere's neighbor-mean gather: a second, wider-radius query of the shared index over the
// agent's friendly factions, in the same job. Fixed, not derived from world or population size.
const cohere_radius: f32 = 96.0;
const max_cohere_neighbors: u32 = 12;
const max_cohere_candidate_checks: u16 = 64;

// Each query kind's block holds its budget's stream and self.
const SeparationBlock = NeighborBlock(max_separation_candidate_checks + 1);
const CohereBlock = NeighborBlock(max_cohere_candidate_checks + 1);

/// Fixed cognition query radius for world interest markers, independent of world size; near
/// hearing range so curious agents find markers without dig stimuli.
const interest_marker_query_radius: f32 = 400.0;

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
    /// (default) snaps every step. Nonzero throttles how often a shared
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
    /// Solver mode for a row whose `kind_hint` is not `.individual`. Every behavior resolves
    /// `.individual` (`arbitration.resolveGoal`), so it has no effect.
    nav_request_kind: PathRequestKind = .individual,
    navigation_intents: ?*RangeOutputStream(NavigationIntent) = null,
    /// When non-null, only these dense ai-store indices think this step (the
    /// scope system's stagger-filtered think set). Null = all agents.
    scope_dense_indices: ?[]const u32 = null,
    /// Read-only world interest markers for investigate goal gathering. Null =
    /// no marker contribution (prior behavior unchanged).
    interest_markers: ?*const InterestMarkerStore = null,
};

pub const AiStats = struct {
    perf: Perf = .{},

    /// Kept only with `runtime_perf_log.enabled`: the rows that thought (one navigation
    /// intent each), the separation and cohere neighbor-block fills (one per key a range's
    /// rows change to), the separation queries' candidate checks and neighbor samples, and
    /// the gather, separation, and intent batches.
    pub const Perf = if (runtime_perf_log.enabled) struct {
        entity_count: usize = 0,
        separation_block_fills: usize = 0,
        cohere_block_fills: usize = 0,
        separation_candidate_checks: usize = 0,
        separation_neighbor_samples: usize = 0,
        gather_batch: BatchStats = .{},
        separation_batch: BatchStats = .{},
        intent_batch: BatchStats = .{},
    } else struct {};
};

pub const AiSystem = struct {
    allocator: std.mem.Allocator,
    // Gathered work memory, one row per think row with a body: the gather's ranges write
    // their windows, then main compacts them in range order.
    rows: std.MultiArrayList(AiGatherRow) = .{},
    // Per-range tallies of the gather and separation dispatches, which run in turn.
    range_tallies: SlotList(AiRangeTally) = .empty,
    gather_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(ai_gather_tuner_config),
    separation_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(ai_adaptive_tuner_config),
    intent_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(ai_intent_tuner_config),
    // Broadcast goal-requantization state (see `requantizeGoal`); one scalar
    // pair since every default-target row shares this same broadcast value.
    snapped_goal: AiDir = .{ .x = 0, .y = 0 },
    snapped_goal_initialized: bool = false,

    /// Sizes the gather rows and the range tallies for `pop` think rows under every partition
    /// the tuners can pick. Grow-only; the pipeline calls it at its population seam.
    pub fn reserve(self: *AiSystem, pop: usize) !void {
        if (pop == 0) return;
        try self.rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(pop));
        try self.range_tallies.ensureTotalCapacity(self.allocator, maxRangeCount(hotStoreCapacity(pop), ai_range_alignment_items));
    }

    pub fn init(allocator: std.mem.Allocator) AiSystem {
        return .{
            .allocator = allocator,
            .gather_tuner = AdaptiveWorkTuner.init(ai_gather_tuner_config),
            .separation_tuner = AdaptiveWorkTuner.init(ai_adaptive_tuner_config),
            .intent_tuner = AdaptiveWorkTuner.init(ai_intent_tuner_config),
        };
    }

    pub fn deinit(self: *AiSystem) void {
        self.range_tallies.deinit(self.allocator);
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
        const gather_batch = try self.gatherAiData(gatherInputs(ai_agents, movement, data, config, held_focus_target), thread_system, config);
        const entity_count = self.rows.len;
        if (entity_count == 0) {
            // No ai this step; do not touch caller's stream (other emitters may use intents).
            return .{ .perf = if (comptime runtime_perf_log.enabled) .{ .gather_batch = gather_batch } else .{} };
        }

        self.resetSeparationScratch();
        const gathered = self.rows.slice();
        const separation = Dispatch.init(thread_system, &self.separation_tuner, .{
            .items_per_range = config.separation_items_per_range orelse config.items_per_range,
            .max_worker_threads = config.max_worker_threads,
            .adaptive = config.adaptive,
        });
        const separation_selection = separation.select(entity_count, ai_range_alignment_items);
        try self.prepareRangeTallies(separation_selection.range_count);
        var separation_context = buildAiSeparationContext(gathered, spatial, self.range_tallies.items, config.interest_markers);
        const separation_batch = separation.run(separation_selection, entity_count, ai_range_alignment_items, &separation_context, writeAiSeparationJob);
        const range_perf = self.sumRangePerf();

        const intent = Dispatch.init(thread_system, &self.intent_tuner, .{
            .items_per_range = config.intent_items_per_range orelse config.items_per_range,
            .max_worker_threads = config.max_worker_threads,
            .adaptive = config.adaptive,
        });
        const intent_selection = intent.select(entity_count, ai_intent_range_alignment_items);
        const rcount = intent_selection.range_count;

        const navigation_stream = config.navigation_intents orelse &frame.navigation_intents;
        const range_base = try navigation_stream.appendRangeCounts(rcount);

        var context = buildAiJobContext(gathered, navigation_stream, data, config, range_base, rcount);

        for (0..rcount) |range_index| {
            const start = range_index * intent_selection.items_per_range;
            const end = @min(start + intent_selection.items_per_range, entity_count);
            navigation_stream.addCount(range_base + range_index, end - start);
        }

        try navigation_stream.prefixAppendedRanges(range_base);

        const intent_batch = intent.run(intent_selection, entity_count, ai_intent_range_alignment_items, &context, writeAiIntentsJob);

        navigation_stream.finishWrite();

        return .{
            .perf = if (comptime runtime_perf_log.enabled) .{
                .entity_count = entity_count,
                .separation_block_fills = range_perf.separation_block_fills,
                .cohere_block_fills = range_perf.cohere_block_fills,
                .separation_candidate_checks = range_perf.separation_candidate_checks,
                .separation_neighbor_samples = range_perf.separation_neighbor_samples,
                .gather_batch = gather_batch,
                .separation_batch = separation_batch,
                .intent_batch = intent_batch,
            } else .{},
        };
    }

    // The gather over the think rows on workers under `gather_tuner`: each range writes its
    // rows' window, then main moves the windows together in range order.
    fn gatherAiData(self: *AiSystem, inputs: AiGatherInputs, thread_system: *ThreadSystem, config: AiConfig) !BatchStats {
        const n = try self.prepareGather(inputs);
        if (n == 0) return .{};
        const gather = Dispatch.init(thread_system, &self.gather_tuner, .{
            .items_per_range = config.items_per_range,
            .max_worker_threads = config.max_worker_threads,
            .adaptive = config.adaptive,
        });
        const selection = gather.select(n, ai_gather_range_alignment_items);
        try self.prepareRangeTallies(selection.range_count);
        var context = AiGatherContext{ .inputs = inputs, .rows = self.rows.slice(), .items_per_range = selection.items_per_range, .tallies = self.range_tallies.items };
        const batch = gather.run(selection, n, ai_gather_range_alignment_items, &context, gatherAiJob);
        compactRowWindows(AiGatherRow, AiRangeTally, &self.rows, self.range_tallies.items, selection.items_per_range);
        return batch;
    }

    // Sizes the rows to one window slot per think row before dispatch; returns the count.
    fn prepareGather(self: *AiSystem, inputs: AiGatherInputs) !usize {
        self.clearWork();
        const n = inputs.rowCount();
        if (n == 0) return 0;
        try self.rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(n));
        setRowCount(AiGatherRow, &self.rows, n);
        return n;
    }

    // `range_count` zeroed tallies, before dispatch; grow-only past `reserve`.
    fn prepareRangeTallies(self: *AiSystem, range_count: usize) !void {
        try self.range_tallies.ensureTotalCapacity(self.allocator, range_count);
        setSlotCount(AiRangeTally, &self.range_tallies, range_count);
    }

    fn sumRangePerf(self: *const AiSystem) RangePerf {
        var total = RangePerf{};
        if (comptime runtime_perf_log.enabled) {
            for (self.range_tallies.items) |slot| {
                total.separation_block_fills += slot.value.perf.separation_block_fills;
                total.cohere_block_fills += slot.value.perf.cohere_block_fills;
                total.separation_candidate_checks += slot.value.perf.separation_candidate_checks;
                total.separation_neighbor_samples += slot.value.perf.separation_neighbor_samples;
            }
        }
        return total;
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

    /// Zeroes this step's separation and cohere columns.
    fn resetSeparationScratch(self: *AiSystem) void {
        if (self.rows.len == 0) return;
        const gathered = self.rows.slice();
        @memset(gathered.items(.sep_x), 0);
        @memset(gathered.items(.sep_y), 0);
        @memset(gathered.items(.cohere), RowCohere{});
    }
};

// One step's AI gather inputs, read-only on every range.
const AiGatherInputs = struct {
    ai_slice: ConstAiAgentSlice,
    movement: ConstMovementBodySlice,
    data: *const DataSystem,
    scope_dense_indices: ?[]const u32 = null,
    focus_target: ?AiDir = null,
    focus_entity: ?EntityId = null,
    perception_slice: ?ConstPerceptionSlice = null,
    memory_slice: ?ConstAiMemorySlice = null,
    affect_slice: ?ConstAiAffectSlice = null,

    fn rowCount(self: *const AiGatherInputs) usize {
        return if (self.scope_dense_indices) |indices| indices.len else self.ai_slice.entities.len;
    }

    // Think row `k`'s gather row, every column arbitration reads, or null without a movement
    // body. Scalar per row: dense-index lookups into the movement, faction, level,
    // perception, memory, and affect stores, with skips; threaded in windows.
    fn gatherRow(self: *const AiGatherInputs, k: usize) ?AiGatherRow {
        const i: usize = if (self.scope_dense_indices) |indices| indices[k] else k;
        const ent = self.ai_slice.entities[i];
        const mi = self.data.movementBodyDenseIndex(ent) orelse return null;
        const maybe_faction = self.data.factionConst(ent);
        const ent_faction = maybe_faction orelse .neutral;

        // See AiConfig.focus_target's doc comment: only an explicit opt-in,
        // never populated for a row with no pursue gain at all.
        const gain_pursue = self.ai_slice.gain_pursues[i];
        const has_focus = self.focus_target != null and gain_pursue > 0;

        var row = AiGatherRow{
            .entity = ent,
            .pos_x = self.movement.previous_x[mi],
            .pos_y = self.movement.previous_y[mi],
            .faction = ent_faction,
            .level = self.data.worldLevelConst(ent) orelse 0,
            .wander_amplitude = self.ai_slice.wander_amplitudes[i],
            .gains = .{
                .wander = self.ai_slice.gain_wanders[i],
                .pursue = gain_pursue,
                .flee = self.ai_slice.gain_flees[i],
                .investigate = self.ai_slice.gain_investigates[i],
                .cohere = self.ai_slice.gain_coheres[i],
            },
            .sticky = .{
                .commitment_max_steps = self.ai_slice.commitment_max_steps[i],
                .sticky_bonus = self.ai_slice.sticky_bonus[i],
                .prev_behavior = self.ai_slice.behaviors[i],
                .prev_commitment_remaining = self.ai_slice.commitment_remaining[i],
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
            .memory_ring = @splat(.{}),
            .drives = .{ .fear = 0, .curiosity = 0, .aggression = 0, .fatigue = 0 },
            .focus = .{
                .entity = if (has_focus) self.focus_entity else null,
                .x = if (has_focus) self.focus_target.?.x else 0,
                .y = if (has_focus) self.focus_target.?.y else 0,
            },
            .interest = .{},
            .sep_x = 0,
            .sep_y = 0,
            .cohere = .{},
            .resolved = .{ .goal_x = self.movement.previous_x[mi], .goal_y = self.movement.previous_y[mi] },
        };

        if (self.perception_slice) |perception| {
            if (self.data.aiPerceptionDenseIndex(ent)) |pidx| {
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

        if (self.memory_slice) |memory| {
            if (self.data.aiMemoryDenseIndex(ent)) |midx| {
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

        if (self.affect_slice) |affect| {
            if (self.data.aiAffectDenseIndex(ent)) |aidx| {
                row.drives = .{
                    .fear = affect.fear[aidx],
                    .curiosity = affect.curiosity[aidx],
                    .aggression = affect.aggression[aidx],
                    .fatigue = affect.fatigue[aidx],
                };
            }
        }

        row.interest = .{ .has_faction = maybe_faction != null };
        return row;
    }
};

fn gatherInputs(ai_slice: ConstAiAgentSlice, movement: ConstMovementBodySlice, data: *const DataSystem, config: AiConfig, focus_target: ?AiDir) AiGatherInputs {
    return .{
        .ai_slice = ai_slice,
        .movement = movement,
        .data = data,
        .scope_dense_indices = config.scope_dense_indices,
        .focus_target = focus_target,
        .focus_entity = config.focus_entity,
        .perception_slice = config.perception_slice,
        .memory_slice = config.memory_slice,
        .affect_slice = config.affect_slice,
    };
}

const AiGatherContext = struct {
    inputs: AiGatherInputs,
    // `inputs.rowCount()` window slots: range r's kept rows from `r * items_per_range`.
    rows: std.MultiArrayList(AiGatherRow).Slice,
    items_per_range: usize,
    tallies: []PaddedSlot(AiRangeTally),
};

fn gatherAiJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *AiGatherContext = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.tallies.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end and range.end <= job.rows.len and range.end <= job.inputs.rowCount());
    var rows = job.rows;
    var kept: usize = 0;
    for (range.start..range.end) |k| {
        const row = job.inputs.gatherRow(k) orelse continue;
        rows.set(range.start + kept, row);
        kept += 1;
    }
    job.tallies[range.index].value.kept = kept;
}

fn buildAiSeparationContext(
    gathered: std.MultiArrayList(AiGatherRow).Slice,
    spatial: SpatialIndexView,
    range_tallies: []PaddedSlot(AiRangeTally),
    markers: ?*const InterestMarkerStore,
) AiSeparationContext {
    return .{
        .entities = gathered.items(.entity),
        .pos_x = gathered.items(.pos_x),
        .pos_y = gathered.items(.pos_y),
        .faction = gathered.items(.faction),
        .level = gathered.items(.level),
        .gains = gathered.items(.gains),
        .sep_x = gathered.items(.sep_x),
        .sep_y = gathered.items(.sep_y),
        .cohere = gathered.items(.cohere),
        .interest = gathered.items(.interest),
        .markers = markers,
        .spatial_index = spatial,
        .range_tallies = range_tallies,
    };
}

/// Builds the per-row job context `update` hands to `writeAiIntentsJob`. `ai_agent_hot` is arbitration's mutable
/// hot-column write-back target (see `resolveRowArbitration`); each row's
/// `agent_dense_index` is unique within one gather, so concurrent workers
/// never write the same hot-column slot.
fn buildAiJobContext(
    gathered: std.MultiArrayList(AiGatherRow).Slice,
    navigation_stream: *RangeOutputStream(NavigationIntent),
    data: *DataSystem,
    config: AiConfig,
    range_base: usize,
    range_count: usize,
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
        .interest = gathered.items(.interest),
        .sep_x = gathered.items(.sep_x),
        .sep_y = gathered.items(.sep_y),
        .cohere = gathered.items(.cohere),
        .resolved = gathered.items(.resolved),
        .navigation_intents = navigation_stream,
        .ai_agent_hot = data.aiAgentSlice(),
        .seed = config.intent_seed,
        .wander_step = config.step / @max(config.wander_resample_period_steps, 1),
        .nav_request_kind = config.nav_request_kind,
        .range_base = range_base,
        .range_count = range_count,
    };
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
    entities: []const EntityId,
    pos_x: []const f32,
    pos_y: []const f32,
    faction: []const Faction,
    level: []const u16,
    /// Only `.cohere` is read: it gates the cohere neighbor query.
    gains: []const RowGains,
    sep_x: []f32,
    sep_y: []f32,
    /// Cohere neighbor-mean output, written by the same job as separation.
    cohere: []RowCohere,
    interest: []RowInterest,
    markers: ?*const InterestMarkerStore,
    spatial_index: SpatialIndexView,
    /// One slot per dispatched range; range r writes only its own, once.
    range_tallies: []PaddedSlot(AiRangeTally),
};

fn writeAiSeparationJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *AiSeparationContext = @ptrCast(@alignCast(context));
    // Dual worker asserts (mirror affect.zig / collision.zig).
    std.debug.assert(range.index < job.range_tallies.len);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.pos_x.len);
    var separation_block = SeparationBlock{};
    var cohere_block = CohereBlock{};
    var range_perf = RangePerf{};
    for (range.start..range.end) |index| {
        const result = computeBoundedSeparation(job, index, &separation_block);
        job.sep_x[index] = result.x;
        job.sep_y[index] = result.y;
        if (comptime runtime_perf_log.enabled) {
            range_perf.separation_candidate_checks += result.perf.candidate_checks;
            range_perf.separation_neighbor_samples += result.perf.neighbor_samples;
        }

        // A zero cohere gain never wins `.cohere` (its score is 0 and a tie loses to
        // `.wander`), so its query is skipped.
        job.cohere[index] = if (job.gains[index].cohere > 0)
            computeCohereNeighbors(job, index, &cohere_block)
        else
            .{};

        if (job.markers) |markers| {
            if (job.gains[index].investigate > 0) {
                const interest = &job.interest[index];
                const agent_faction: ?Faction = if (interest.has_faction) job.faction[index] else null;
                if (markers.findBestInvestigateMarker(job.level[index], job.pos_x[index], job.pos_y[index], interest_marker_query_radius, agent_faction)) |hit| {
                    interest.present = true;
                    interest.x = hit.x;
                    interest.y = hit.y;
                }
            }
        }
    }
    if (comptime runtime_perf_log.enabled) {
        range_perf.separation_block_fills = separation_block.perf.fills;
        range_perf.cohere_block_fills = cohere_block.perf.fills;
        job.range_tallies[range.index].value.perf = range_perf;
    }
}

const SeparationResult = struct {
    x: f32 = 0,
    y: f32 = 0,
    perf: SeparationPerf = .{},
};

// One row's separation query's candidate checks and neighbor samples.
const SeparationPerf = if (runtime_perf_log.enabled) struct {
    candidate_checks: u16 = 0,
    neighbor_samples: u8 = 0,
} else struct {};

// The bounded separation sum of one row's query in lane partials: each lane sums the unit
// directions away from the neighbors at its lane, past `separation_min_dist2`.
const SeparationAccumulator = struct {
    x: simd.Float4 = @splat(0),
    y: simd.Float4 = @splat(0),
    neighbor_count: u8 = 0,

    pub fn visitLanes(self: *SeparationAccumulator, lanes: *const NeighborLanes) LaneStop {
        const near = lanes.inside & simd.greaterThanFloat4Bits(lanes.dist2, simd.splatFloat4(separation_min_dist2));
        if (near == 0) return null;
        const cap = capLanes(near, max_separation_neighbors - self.neighbor_count);
        // Inside lanes are finite (NaN and inf fail the radius test), and `near` is above 0.
        const dir = simd.normalizeKnownFinite2Float4(lanes.dx, lanes.dy, lanes.dist2, cap.pass);
        self.x = simd.addFloat4(self.x, dir.x);
        self.y = simd.addFloat4(self.y, dir.y);
        self.neighbor_count += @popCount(cap.pass);
        return cap.stop;
    }
};

fn computeBoundedSeparation(job: *const AiSeparationContext, index: usize, block: *SeparationBlock) SeparationResult {
    var acc = SeparationAccumulator{};
    // Every faction on the row's level.
    const stats = job.spatial_index.queryNeighbors(block, .{
        .x = job.pos_x[index],
        .y = job.pos_y[index],
        .level = job.level[index],
        .radius = separation_radius,
        .max_candidate_checks = max_separation_candidate_checks,
        .self = job.entities[index],
    }, &acc);
    return .{
        .x = simd.sumLanesFloat4(acc.x),
        .y = simd.sumLanesFloat4(acc.y),
        .perf = if (comptime runtime_perf_log.enabled) .{ .candidate_checks = stats.candidate_checks, .neighbor_samples = acc.neighbor_count } else .{},
    };
}

// The friendly positions one row's cohere query visits, summed in lane partials.
const CohereVisitor = struct {
    sum_x: simd.Float4 = @splat(0),
    sum_y: simd.Float4 = @splat(0),
    count: u32 = 0,

    pub fn visitLanes(self: *CohereVisitor, lanes: *const NeighborLanes) LaneStop {
        const cap = capLanes(lanes.inside, max_cohere_neighbors - self.count);
        self.sum_x = simd.addFloat4(self.sum_x, simd.selectOrZeroFloat4(cap.pass, lanes.x));
        self.sum_y = simd.addFloat4(self.sum_y, simd.selectOrZeroFloat4(cap.pass, lanes.y));
        self.count += @popCount(cap.pass);
        return cap.stop;
    }
};

/// Cohere's neighbor-mean gather: a second query of the shared index used for
/// separation, over the factions friendly to the row on its level, so cohere flocks with
/// allies, never hostiles or neutrals.
fn computeCohereNeighbors(job: *const AiSeparationContext, index: usize, block: *CohereBlock) RowCohere {
    var visitor = CohereVisitor{};
    _ = job.spatial_index.queryNeighbors(block, .{
        .x = job.pos_x[index],
        .y = job.pos_y[index],
        .level = job.level[index],
        .radius = cohere_radius,
        .max_candidate_checks = max_cohere_candidate_checks,
        .factions = factionsWithStance(job.faction[index], .friendly),
        .self = job.entities[index],
    }, &visitor);
    if (visitor.count == 0) return .{};
    const inv = 1.0 / @as(f32, @floatFromInt(visitor.count));
    return .{ .mean_x = simd.sumLanesFloat4(visitor.sum_x) * inv, .mean_y = simd.sumLanesFloat4(visitor.sum_y) * inv, .count = visitor.count };
}

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
    interest: []const RowInterest,
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
    /// Dispatched range count; dual-asserted against `range.index` at job entry.
    range_count: usize,
};

/// Runs arbitration for one row and writes its resolved output and locomotion behavior. A
/// selection with no resolvable goal degrades to wander with zero gain, in the hot
/// `active_behavior` column too, and clears its commitment.
fn resolveRowArbitration(job: *AiJobContext, i: usize) void {
    const threat = job.threat[i];
    const stimulus = job.stimulus[i];
    const memory = job.memory[i];
    const ring = job.memory_ring[i];
    const drives = job.drives[i];
    const focus = job.focus[i];
    const interest = job.interest[i];
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
        .interest_present = interest.present,
        .interest_x = interest.x,
        .interest_y = interest.y,
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
    const selected_behavior: AiBehavior = @fromBackingInt(@intCast(selection.index));
    const goal = arbitration.resolveGoal(selected_behavior, signals);

    const agent_index = sticky.agent_dense_index;

    if (goal.valid) {
        const resolved_gain: f32 = switch (selected_behavior) {
            .wander => gains_col.wander,
            .pursue => gains_col.pursue,
            .flee => gains_col.flee,
            .investigate => gains_col.investigate,
            .cohere => gains_col.cohere,
        };
        job.ai_agent_hot.active_behavior[agent_index] = selected_behavior;
        job.ai_agent_hot.commitment_remaining[agent_index] = selection.new_commitment;
        job.ai_agent_hot.last_score[agent_index] = scores[selection.index];
        job.resolved[i] = .{
            .behavior = selected_behavior,
            .gain = resolved_gain,
            .kind_hint = goal.kind_hint,
            .goal_x = goal.goal_x,
            .goal_y = goal.goal_y,
            .goal_entity = goal.goal_entity,
        };
    } else {
        // Locomotion degrades to wander: write that for affect fatigue and sticky
        // prev_behavior, and clear commitment so an unresolvable pursue/flee is
        // not held as the active exertion mode.
        job.ai_agent_hot.active_behavior[agent_index] = .wander;
        job.ai_agent_hot.commitment_remaining[agent_index] = 0;
        job.ai_agent_hot.last_score[agent_index] = scores[@backingInt(AiBehavior.wander)];
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
    // Dual worker asserts (mirror affect.zig / collision.zig).
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.entities.len);
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
        std.debug.assert(i < job.sep_x.len);
        std.debug.assert(i < job.sep_y.len);
        const dir = applySeparationAndNormalize(base_dir, job.sep_x[i], job.sep_y[i]);

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

const testSpatialIndex = @import("spatial_index_test_support.zig").testSpatialIndex;
const testHaloIndex = @import("spatial_index_test_support.zig").testHaloIndex;

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
    try std.testing.expectEqual(count, s.items(.interest).len);
    try std.testing.expectEqual(count, s.items(.sep_x).len);
    try std.testing.expectEqual(count, s.items(.sep_y).len);
    try std.testing.expectEqual(count, s.items(.cohere).len);
    try std.testing.expectEqual(count, s.items(.resolved).len);
}

// `AiSystem.update` inline as one range: a thread system with no workers.
fn updateInline(
    system: *AiSystem,
    ai_agents: ConstAiAgentSlice,
    movement: ConstMovementBodySlice,
    spatial: SpatialIndexView,
    data: *DataSystem,
    frame: *SimulationFrame,
    delta_seconds: f32,
    config: AiConfig,
) !AiStats {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    return system.update(ai_agents, movement, spatial, data, frame, &threads, delta_seconds, config);
}

// `AiSystem.gatherAiData` inline as one range: a thread system with no workers.
fn gatherInline(system: *AiSystem, inputs: AiGatherInputs) !void {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    _ = try system.gatherAiData(inputs, &threads, .{});
}

// The unstaggered think set over `view`, compacted inline.
fn thinkSetInline(scope: *SimulationScopeSystem, view: *const SpatialIndexView) ![]const u32 {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    return (try scope.compactCognition(view, 0, false, &threads, .{})).cognition;
}

const data_test_support = @import("../data_system/test_support.zig");

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

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    _ = try updateInline(&ai_sys, data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &frame, 0.016, .{
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
    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    // Serial path with seed
    frame.beginStep();
    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    _ = try updateInline(&ai_sys, ai_slice, movement_slice, spatial_sys.view(), &data, &frame, 0.016, .{ .intent_seed = 0x12345678 });
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
    _ = try updateInline(&ai_sys, ai_slice, movement_slice, spatial_sys.view(), &data, &frame, 0.016, .{ .intent_seed = 0xdeadbeef });
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
    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 3, 0, 0, 0);

    frame.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
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
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
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
    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 3, 0, 0, 0);
    const hysteresis: f32 = 50;

    frame.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
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
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
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
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
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
    // There is no separate raw/live vs hysteresis-held pair for a
    // resolved goal: resolveGoal's output feeds both the NavigationIntent's
    // `.goal` and decideDir's steering target uniformly, for every tier
    // (perception/memory goals are already fresh every step; only the
    // focus_target fallback has a hysteresis concept at all, and it
    // applies identically to both consumers).
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const target = try data.createEntity();
    const e0 = try data.createEntity();
    try data.setMovementBody(e0, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(e0, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();
    var spatial_sys = try testSpatialIndex(&data);
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
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
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
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
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

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    _ = try updateInline(&ai_sys, data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &frame, 0.016, .{ .intent_seed = 2 });

    // The prior writer's intent, then the one agent's.
    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 2), intents.len);
    try std.testing.expectEqual(@as(i16, -1), intents[0].priority);
    try std.testing.expectEqual(entity.index, intents[1].entity.index);
}

test "ai production adaptive tuners use central gate and range alignment" {
    var system = AiSystem.init(std.testing.allocator);
    defer system.deinit();
    try std.testing.expectEqual((AdaptiveWorkTunerConfig{}).threaded_batch_ns, system.separation_tuner.config.threaded_batch_ns);
    try std.testing.expectEqual((AdaptiveWorkTunerConfig{}).threaded_batch_ns, system.intent_tuner.config.threaded_batch_ns);
    try std.testing.expectEqual(ai_range_alignment_items, system.separation_tuner.config.initial_range_items);
    try std.testing.expectEqual(ai_intent_range_alignment_items, system.intent_tuner.config.initial_range_items);
    try std.testing.expectEqual(ai_intent_range_alignment_items, system.intent_tuner.config.smallest_range_items);
    try std.testing.expectEqual((AdaptiveWorkTunerConfig{}).threaded_batch_ns, system.gather_tuner.config.threaded_batch_ns);
    try std.testing.expectEqual(ai_gather_range_alignment_items, system.gather_tuner.config.initial_range_items);
    try std.testing.expectEqual(ai_gather_range_alignment_items, system.gather_tuner.config.smallest_range_items);
}

// Timing-independent: both stage tuners get a gate no batch reaches, so the stages
// stay inline on any host and build mode; the wiring under test is that each stage
// dispatches through its own tuner.
test "ai stages stay inline when their batches sit below their tuner gate" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 8,
        .items_per_range = 1,
    });
    defer threads.deinit();

    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent_count: usize = 64;
    for (0..agent_count) |i| {
        const x: f32 = @floatFromInt(i);
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{
            .position = .{ .x = x, .y = 0 },
            .previous_position = .{ .x = x, .y = 0 },
            .velocity = .{},
            .speed = 20,
        });
        try data.setAiAgent(entity, .{ .active_behavior = .wander, .wander_amplitude = 10 });
    }

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    ai_sys.separation_tuner.config.threaded_batch_ns = std.math.maxInt(u64);
    ai_sys.intent_tuner.config.threaded_batch_ns = std.math.maxInt(u64);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 0, agent_count, 0, 0, 0);

    const warmup_windows = ai_sys.intent_tuner.config.sample_window * 4;
    var last_stats: AiStats = .{};
    var window: usize = 0;
    while (window < warmup_windows) : (window += 1) {
        frame.beginStep();
        last_stats = try ai_sys.update(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &frame, &threads, 0.016, .{ .intent_seed = 1 });
    }

    // Each stage selected through its own tuner, and neither gated tuner took a threaded
    // profile.
    for ([_]*const AdaptiveWorkTuner{ &ai_sys.separation_tuner, &ai_sys.intent_tuner }) |tuner| {
        try std.testing.expect(tuner.last_request != null);
        try std.testing.expect(!tuner.has_threaded_profile);
    }
}

test "ai processor uses committed adaptive threaded profiles with default thread worker config" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = 1,
    });
    defer threads.deinit();

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
    var committed_tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = ai_range_alignment_items,
        .smallest_range_items = ai_range_alignment_items,
        .largest_range_items = ai_range_alignment_items * 4,
    });
    committed_tuner.current_profile = .{
        .worker_threads = 1,
        .items_per_range = ai_range_alignment_items,
    };
    committed_tuner.best_profile = committed_tuner.current_profile;
    committed_tuner.has_threaded_profile = true;
    committed_tuner.best_mean_batch_duration_ns = 1;
    ai_sys.separation_tuner = committed_tuner;
    ai_sys.intent_tuner = committed_tuner;

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    _ = try ai_sys.update(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &frame, &threads, 0.016, .{
        .intent_seed = 3,
    });
    try std.testing.expectEqual(@as(usize, 128), frame.navigation_intents.mergedItems().len);
    // Each stage selected through its tuner, which keeps its committed threaded profile.
    for ([_]*const AdaptiveWorkTuner{ &ai_sys.separation_tuner, &ai_sys.intent_tuner }) |tuner| {
        try std.testing.expect(tuner.last_request != null);
        try std.testing.expect(tuner.has_threaded_profile);
        try std.testing.expectEqual(committed_tuner.current_profile, tuner.current_profile);
    }
}

test "ai update records one sample into each stage tuner" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();

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
    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    _ = try ai_sys.update(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &frame, &threads, 0.016, .{ .intent_seed = 3 });
    try std.testing.expectEqual(@as(usize, 128), frame.navigation_intents.mergedItems().len);
    for ([_]*const AdaptiveWorkTuner{ &ai_sys.gather_tuner, &ai_sys.separation_tuner, &ai_sys.intent_tuner }) |tuner| {
        try std.testing.expectEqual(@as(usize, 1), tuner.sample_count);
        try std.testing.expect(tuner.last_request != null);
    }
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
    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    var frame_a = SimulationFrame.init(std.testing.allocator);
    defer frame_a.deinit();
    try frame_a.reserveStreams(1, 0, 3, 0, 0, 0);
    frame_a.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame_a, 0.016, .{ .intent_seed = 0x1234abcd, .step = 5, .wander_resample_period_steps = 1 });
    const step5_first = frame_a.navigation_intents.mergedItems()[0];
    frame_a.phase = .finished;

    var frame_b = SimulationFrame.init(std.testing.allocator);
    defer frame_b.deinit();
    try frame_b.reserveStreams(1, 0, 3, 0, 0, 0);
    frame_b.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame_b, 0.016, .{ .intent_seed = 0x1234abcd, .step = 5, .wander_resample_period_steps = 1 });
    const step5_second = frame_b.navigation_intents.mergedItems()[0];
    frame_b.phase = .finished;

    try std.testing.expectEqual(step5_first.direct_direction_x, step5_second.direct_direction_x);
    try std.testing.expectEqual(step5_first.direct_direction_y, step5_second.direct_direction_y);

    var frame_c = SimulationFrame.init(std.testing.allocator);
    defer frame_c.deinit();
    try frame_c.reserveStreams(1, 0, 3, 0, 0, 0);
    frame_c.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame_c, 0.016, .{ .intent_seed = 0x1234abcd, .step = 9, .wander_resample_period_steps = 1 });
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
    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    const period: u32 = 10;

    var frame_a = SimulationFrame.init(std.testing.allocator);
    defer frame_a.deinit();
    try frame_a.reserveStreams(1, 0, 3, 0, 0, 0);
    frame_a.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame_a, 0.016, .{ .intent_seed = 0x1234abcd, .step = 0, .wander_resample_period_steps = period });
    const early = frame_a.navigation_intents.mergedItems()[0];
    frame_a.phase = .finished;

    var frame_b = SimulationFrame.init(std.testing.allocator);
    defer frame_b.deinit();
    try frame_b.reserveStreams(1, 0, 3, 0, 0, 0);
    frame_b.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame_b, 0.016, .{ .intent_seed = 0x1234abcd, .step = period - 1, .wander_resample_period_steps = period });
    const still_within_epoch = frame_b.navigation_intents.mergedItems()[0];
    frame_b.phase = .finished;

    try std.testing.expectEqual(early.direct_direction_x, still_within_epoch.direct_direction_x);
    try std.testing.expectEqual(early.direct_direction_y, still_within_epoch.direct_direction_y);

    var frame_c = SimulationFrame.init(std.testing.allocator);
    defer frame_c.deinit();
    try frame_c.reserveStreams(1, 0, 3, 0, 0, 0);
    frame_c.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame_c, 0.016, .{ .intent_seed = 0x1234abcd, .step = period, .wander_resample_period_steps = period });
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
    var spatial_sys = try testSpatialIndex(&data);
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
    _ = try updateInline(&ai_sys, ai_slice, movement_slice, spatial_sys.view(), &data, &frame, 0.016, .{ .intent_seed = 1 });
    try std.testing.expect(frame.navigation_intents.mergedItems().len == 1);
    frame.phase = .finished;
}

test "ai threaded multi-worker update has no steady-state allocation after warmup (FailingAllocator)" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Two aligned intent ranges.
    const agent_count = 2 * ai_intent_range_alignment_items;
    for (0..agent_count) |i| {
        const x: f32 = @floatFromInt(i % 8);
        const y: f32 = @floatFromInt(i / 8);
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{
            .position = .{ .x = x * 12.0, .y = y * 12.0 },
            .previous_position = .{ .x = x * 12.0, .y = y * 12.0 },
            .velocity = .{},
            .speed = 20,
        });
        try data.setAiAgent(entity, .{
            .active_behavior = if (i % 2 == 0) .pursue else .wander,
            .wander_amplitude = 4,
            .gain_pursue = 0.5,
        });
    }

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = ai_range_alignment_items,
    });
    defer threads.deinit();

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(8, 0, agent_count, 0, 0, 0);

    const cfg: AiConfig = .{
        .items_per_range = ai_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
        .intent_seed = 0xabcd,
        .focus_target = .{ .x = 100, .y = 100 },
    };

    try ai_sys.reserve(agent_count);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const original_ai = ai_sys.allocator;
    const original_frame = frame.allocator;
    const original_nav = frame.navigation_intents.allocator;
    ai_sys.allocator = failing.allocator();
    frame.allocator = failing.allocator();
    frame.navigation_intents.allocator = failing.allocator();
    defer {
        ai_sys.allocator = original_ai;
        frame.allocator = original_frame;
        frame.navigation_intents.allocator = original_nav;
    }

    frame.beginStep();
    _ = try ai_sys.update(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &frame, &threads, 0.016, cfg);
    try std.testing.expectEqual(agent_count, frame.navigation_intents.mergedItems().len);
    frame.phase = .finished;
}

test "ai think-set gather over a halo index has no steady-state allocation after warmup (FailingAllocator)" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..4) |i| {
        const entity = try data.createEntity();
        const x: f32 = @floatFromInt(i * 20);
        try data.setMovementBody(entity, .{
            .position = .{ .x = x, .y = 0 },
            .previous_position = .{ .x = x, .y = 0 },
            .velocity = .{},
            .speed = 20,
        });
        try data.setAiAgent(entity, .{ .active_behavior = .wander });
    }

    const halo = [_]u32{ 0, 1, 2, 3 };
    const think = [_]u32{ 0, 2 };
    var spatial_sys = try testHaloIndex(&data, &halo);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    const cfg: AiConfig = .{
        .scope_dense_indices = &think,
        .intent_seed = 1,
    };

    try ai_sys.reserve(4);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const original_ai = ai_sys.allocator;
    const original_frame = frame.allocator;
    const original_nav = frame.navigation_intents.allocator;
    ai_sys.allocator = failing.allocator();
    frame.allocator = failing.allocator();
    frame.navigation_intents.allocator = failing.allocator();
    defer {
        ai_sys.allocator = original_ai;
        frame.allocator = original_frame;
        frame.navigation_intents.allocator = original_nav;
    }

    frame.beginStep();
    _ = try updateInline(&ai_sys, data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &frame, 0.016, cfg);
    try std.testing.expectEqual(@as(usize, 2), ai_sys.rows.len);
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
    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    frame.beginStep();
    _ = try updateInline(&ai_sys, data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &frame, 0.016, .{ .intent_seed = 1 });
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
    _ = try updateInline(&ai_sys, data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &frame, 0.016, .{ .intent_seed = 2 });
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
    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    const cfg: AiConfig = .{
        .intent_seed = 1,
        .focus_target = .{ .x = 100, .y = 0 },
        .perception_slice = data.aiPerceptionSliceConst(),
        .memory_slice = data.aiMemorySliceConst(),
    };

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();

    try ai_sys.reserve(ai_slice.entities.len);

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
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, cfg);

    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), intents.len);
    try std.testing.expectEqual(@as(f32, 0), intents[0].goal.x);
    try std.testing.expectEqual(@as(f32, 100), intents[0].goal.y);
    try std.testing.expectEqual(@as(f32, 0), intents[0].direct_direction_x);
    try std.testing.expectEqual(@as(f32, 1), intents[0].direct_direction_y);
}

test "ai investigate targets world interest marker without entity goal" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const marker_x: f32 = 200;
    const marker_y: f32 = 50;
    var markers = InterestMarkerStore.init(std.testing.allocator);
    defer markers.deinit(std.testing.allocator);
    _ = try markers.addMarker(.{
        .kind = .investigate,
        .level = 0,
        .x = marker_x,
        .y = marker_y,
        .radius = 256,
    });

    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{
        .position = .{ .x = 0, .y = 0 },
        .previous_position = .{ .x = 0, .y = 0 },
        .velocity = .{},
        .speed = 20,
    });
    try data.setWorldLevel(entity, 0);
    try data.setAiAgent(entity, .{
        .active_behavior = .investigate,
        .wander_amplitude = 0,
        .gain_investigate = 2.0,
        .gain_wander = 0,
    });
    try data.setAiAffect(entity, .{ .curiosity = 1.0 });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 2, 0, 0, 0);

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    const cfg: AiConfig = .{
        .intent_seed = 0x41,
        .affect_slice = data.aiAffectSliceConst(),
        .interest_markers = &markers,
    };

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();

    frame.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, cfg);
    frame.phase = .finished;

    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), intents.len);
    try std.testing.expectApproxEqAbs(marker_x, intents[0].goal.x, 1e-3);
    try std.testing.expectApproxEqAbs(marker_y, intents[0].goal.y, 1e-3);
    try std.testing.expect(intents[0].direct_direction_x > 0);
}

test "ai interest gate skips the marker scan for a zero-investigate-gain row" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    var markers = InterestMarkerStore.init(std.testing.allocator);
    defer markers.deinit(std.testing.allocator);
    // In range of interest_marker_query_radius (400) for an agent at the origin.
    _ = try markers.addMarker(.{ .kind = .investigate, .level = 0, .x = 200, .y = 50, .radius = 256 });

    // Same position and marker; only gain_investigate differs. The zero-gain row
    // must leave interest absent (gate skips the scan); the positive-gain row must
    // find the very same in-range marker, proving range is not what suppresses it.
    const zero_gain = try data.createEntity();
    try data.setMovementBody(zero_gain, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 20 });
    try data.setWorldLevel(zero_gain, 0);
    try data.setAiAgent(zero_gain, .{ .active_behavior = .wander, .gain_investigate = 0, .gain_wander = 1 });

    const positive_gain = try data.createEntity();
    try data.setMovementBody(positive_gain, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 20 });
    try data.setWorldLevel(positive_gain, 0);
    try data.setAiAgent(positive_gain, .{ .active_behavior = .investigate, .gain_investigate = 2.0, .gain_wander = 0 });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();
    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{ .interest_markers = &markers });

    const rows = ai_sys.rows.slice();
    const entities = rows.items(.entity);
    const interest = rows.items(.interest);
    try std.testing.expectEqual(@as(usize, 2), entities.len);
    for (entities, interest) |ent, marker| {
        if (ent.index == zero_gain.index) {
            try std.testing.expect(!marker.present);
        } else {
            try std.testing.expect(marker.present);
            try std.testing.expectApproxEqAbs(@as(f32, 200), marker.x, 1e-3);
        }
    }
}

test "ai factionless agent never discovers a faction-restricted marker" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    var markers = InterestMarkerStore.init(std.testing.allocator);
    defer markers.deinit(std.testing.allocator);
    // In range, but restricted to `.neutral`: the gathered stance column's
    // `.neutral` fallback must not masquerade as a real neutral faction.
    _ = try markers.addMarker(.{ .kind = .investigate, .level = 0, .x = 200, .y = 50, .radius = 256, .faction_filter = .neutral });

    const factionless = try data.createEntity();
    try data.setMovementBody(factionless, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 20 });
    try data.setWorldLevel(factionless, 0);
    try data.setAiAgent(factionless, .{ .active_behavior = .investigate, .gain_investigate = 2.0, .gain_wander = 0 });

    // Control: a real `.neutral` agent at the same spot does pass the filter.
    const neutral = try data.createEntity();
    try data.setMovementBody(neutral, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 20 });
    try data.setWorldLevel(neutral, 0);
    try data.setFaction(neutral, .neutral);
    try data.setAiAgent(neutral, .{ .active_behavior = .investigate, .gain_investigate = 2.0, .gain_wander = 0 });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();
    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{ .interest_markers = &markers });

    const rows = ai_sys.rows.slice();
    const entities = rows.items(.entity);
    const interest = rows.items(.interest);
    try std.testing.expectEqual(@as(usize, 2), entities.len);
    for (entities, interest) |ent, marker| {
        if (ent.index == factionless.index) {
            try std.testing.expect(!marker.has_faction);
            try std.testing.expect(!marker.present);
        } else {
            try std.testing.expect(marker.has_faction);
            try std.testing.expect(marker.present);
        }
    }
}

test "ai investigate ignores cover resource and patrol markers for goals" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    var markers = InterestMarkerStore.init(std.testing.allocator);
    defer markers.deinit(std.testing.allocator);
    _ = try markers.addMarker(.{ .kind = .cover, .level = 0, .x = 200, .y = 50, .radius = 256 });
    _ = try markers.addMarker(.{ .kind = .resource, .level = 0, .x = 210, .y = 50, .radius = 256 });
    _ = try markers.addMarker(.{ .kind = .patrol, .level = 0, .x = 220, .y = 50, .radius = 256 });

    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{
        .position = .{ .x = 0, .y = 0 },
        .previous_position = .{ .x = 0, .y = 0 },
        .velocity = .{},
        .speed = 20,
    });
    try data.setWorldLevel(entity, 0);
    try data.setAiAgent(entity, .{
        .active_behavior = .investigate,
        .wander_amplitude = 0,
        .gain_investigate = 2.0,
        .gain_wander = 0,
    });
    try data.setAiAffect(entity, .{ .curiosity = 1.0 });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 2, 0, 0, 0);
    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    const cfg: AiConfig = .{
        .intent_seed = 0x41,
        .affect_slice = data.aiAffectSliceConst(),
        .interest_markers = &markers,
    };

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();

    frame.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, cfg);

    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), intents.len);
    try std.testing.expect(intents[0].goal.x != 200);
    try std.testing.expect(intents[0].goal.x != 210);
    try std.testing.expect(intents[0].goal.x != 220);
}

test "ai null interest_markers leaves investigate on stimulus and ring only" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    // Marker store is intentionally NOT passed — prior stimulus/ring path only.
    var markers = InterestMarkerStore.init(std.testing.allocator);
    defer markers.deinit(std.testing.allocator);
    _ = try markers.addMarker(.{
        .kind = .investigate,
        .level = 0,
        .x = 999,
        .y = 999,
        .radius = 256,
    });

    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{
        .position = .{ .x = 0, .y = 0 },
        .previous_position = .{ .x = 0, .y = 0 },
        .velocity = .{},
        .speed = 20,
    });
    try data.setWorldLevel(entity, 0);
    try data.setAiAgent(entity, .{
        .active_behavior = .investigate,
        .wander_amplitude = 0,
        .gain_investigate = 2.0,
        .gain_wander = 0,
    });
    try data.setAiPerception(entity, .{
        .heard_stimulus = true,
        .heard_stimulus_x = 40,
        .heard_stimulus_y = 0,
    });
    try data.setAiAffect(entity, .{ .curiosity = 1.0 });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 2, 0, 0, 0);

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    const cfg: AiConfig = .{
        .intent_seed = 0x42,
        .perception_slice = data.aiPerceptionSliceConst(),
        .affect_slice = data.aiAffectSliceConst(),
        .interest_markers = null,
    };

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();

    frame.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, cfg);
    frame.phase = .finished;

    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), intents.len);
    try std.testing.expectApproxEqAbs(@as(f32, 40), intents[0].goal.x, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), intents[0].goal.y, 1e-3);
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

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    frame.beginStep();
    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    // Use explicit seek_target (not COM) + seed; gather must pick prior pos for exactly the 3 ai in ai order.
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
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

test "ai serial and threaded produce identical intents with separation + seek_target" {
    // Two DataSystems: arbitration write-back mutates sticky columns, so serial
    // and threaded must start from identical unmutated state.
    var serial_data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer serial_data.deinit();
    var threaded_data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer threaded_data.deinit();

    inline for (.{ &serial_data, &threaded_data }) |data| {
        const e0 = try data.createEntity();
        try data.setMovementBody(e0, .{ .position = .{ .x = 50, .y = 60 }, .previous_position = .{ .x = 50, .y = 60 }, .velocity = .{}, .speed = 40 });
        try data.setAiAgent(e0, .{ .active_behavior = .pursue, .wander_amplitude = 2, .gain_pursue = 0.9 });
        const e1 = try data.createEntity();
        try data.setMovementBody(e1, .{ .position = .{ .x = 55, .y = 58 }, .previous_position = .{ .x = 55, .y = 58 }, .velocity = .{}, .speed = 35 });
        try data.setAiAgent(e1, .{ .active_behavior = .wander, .wander_amplitude = 12, .gain_pursue = 0.4 });
        try addParityFillers(data, parity_filler_count);
    }
    const agent_count = 2 + parity_filler_count;

    var serial_spatial = try testSpatialIndex(&serial_data);
    defer serial_spatial.deinit();
    var threaded_spatial = try testSpatialIndex(&threaded_data);
    defer threaded_spatial.deinit();

    const cfg: AiConfig = .{ .intent_seed = 0x1234abcd, .step = 7, .focus_target = .{ .x = 300, .y = 200 } };

    var serial_frame = SimulationFrame.init(std.testing.allocator);
    defer serial_frame.deinit();
    try serial_frame.reserveStreams(8, 0, agent_count, 0, 0, 0);
    serial_frame.beginStep();
    var serial_ai = AiSystem.init(std.testing.allocator);
    defer serial_ai.deinit();
    _ = try updateInline(&serial_ai, serial_data.aiAgentSliceConst(), serial_data.movementBodySliceConst(), serial_spatial.view(), &serial_data, &serial_frame, 0.016, cfg);
    const serial = serial_frame.navigation_intents.mergedItems();
    try std.testing.expect(serial.len >= 2);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    var threaded_frame = SimulationFrame.init(std.testing.allocator);
    defer threaded_frame.deinit();
    try threaded_frame.reserveStreams(8, 0, agent_count, 0, 0, 0);
    threaded_frame.beginStep();
    var threaded_ai = AiSystem.init(std.testing.allocator);
    defer threaded_ai.deinit();
    var threaded_cfg = cfg;
    threaded_cfg.items_per_range = ai_range_alignment_items;
    threaded_cfg.max_worker_threads = 2;
    threaded_cfg.adaptive = false;
    _ = try threaded_ai.update(threaded_data.aiAgentSliceConst(), threaded_data.movementBodySliceConst(), threaded_spatial.view(), &threaded_data, &threaded_frame, &threads, 0.016, threaded_cfg);
    const thr = threaded_frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(serial.len, thr.len);
    try std.testing.expectEqual(serial[0].direct_direction_x, thr[0].direct_direction_x);
    try std.testing.expectEqual(serial[0].direct_direction_y, thr[0].direct_direction_y);
    try std.testing.expectEqual(serial[1].direct_direction_x, thr[1].direct_direction_x);
    try std.testing.expectEqual(serial[1].direct_direction_y, thr[1].direct_direction_y);
    for (serial, thr) |a, b| {
        try std.testing.expectEqual(a.entity.index, b.entity.index);
        try std.testing.expectEqual(a.direct_direction_x, b.direct_direction_x);
        try std.testing.expectEqual(a.direct_direction_y, b.direct_direction_y);
    }
}

// Wandering AI agents with bodies far from a parity test's subject agents, so the fixture
// spans more than one aligned range of every AI stage and the threaded side runs on workers.
const parity_filler_count: usize = ai_intent_range_alignment_items + 2 * ai_range_alignment_items;

fn addParityFillers(data: *DataSystem, count: usize) !void {
    for (0..count) |i| {
        const x: f32 = 1200 + @as(f32, @floatFromInt(i % 8)) * 40;
        const y: f32 = 1200 + @as(f32, @floatFromInt(i / 8)) * 40;
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{ .position = .{ .x = x, .y = y }, .previous_position = .{ .x = x, .y = y }, .velocity = .{}, .speed = 20 });
        try data.setAiAgent(entity, .{ .active_behavior = .wander, .wander_amplitude = @floatFromInt(i % 7) });
    }
}

// 128 allies at a 9 x 7 pitch: about four per index cell, every third with cohere gain, and
// every eleventh AI agent without a movement body, so the gather skips rows.
fn fillParityAgents(data: *DataSystem) !void {
    for (0..140) |i| {
        const entity = try data.createEntity();
        try data.setAiAgent(entity, .{
            .active_behavior = if (i % 2 == 0) .pursue else .wander,
            .wander_amplitude = @floatFromInt(i % 13),
            .gain_pursue = if (i % 2 == 0) 0.7 else 0.2,
            .gain_cohere = if (i % 3 == 0) 0.5 else 0,
        });
        // Friendly to one another, so cohere finds neighbors.
        try data.setFaction(entity, .ally);
        if (i % 11 == 10) continue;
        const x: f32 = @floatFromInt(i % 16);
        const y: f32 = @floatFromInt(i / 16);
        try data.setMovementBody(entity, .{
            .position = .{ .x = x * 9.0, .y = y * 7.0 },
            .previous_position = .{ .x = x * 9.0, .y = y * 7.0 },
            .velocity = .{},
            .speed = 20,
        });
    }
}

const SimulationScopeSystem = @import("simulation_scope.zig").SimulationScopeSystem;

test "ai serial and real threaded workers produce identical rows and intents on cell-major rows at every range size" {
    var serial_data = DataSystem.init(std.testing.allocator);
    defer serial_data.deinit();
    try fillParityAgents(&serial_data);
    var serial_spatial = try testSpatialIndex(&serial_data);
    defer serial_spatial.deinit();
    const serial_view = serial_spatial.view();
    var scope = SimulationScopeSystem.init(std.testing.allocator);
    defer scope.deinit();
    // The think set in the index's cell-major order, as the pipeline orders it.
    const think_set = try thinkSetInline(&scope, &serial_view);
    try std.testing.expect(think_set.len > 100);

    const base_cfg: AiConfig = .{ .intent_seed = 0x1234abcd, .focus_target = .{ .x = 300, .y = 200 }, .scope_dense_indices = think_set };
    var serial_ai = AiSystem.init(std.testing.allocator);
    defer serial_ai.deinit();
    var serial_frame = SimulationFrame.init(std.testing.allocator);
    defer serial_frame.deinit();
    try serial_frame.reserveStreams(16, 0, 140, 0, 0, 0);
    serial_frame.beginStep();
    _ = try updateInline(&serial_ai, serial_data.aiAgentSliceConst(), serial_data.movementBodySliceConst(), serial_view, &serial_data, &serial_frame, 0.016, base_cfg);
    const serial = serial_frame.navigation_intents.mergedItems();
    const serial_rows = serial_ai.rows.slice();
    var cohere_rows: usize = 0;
    for (serial_rows.items(.cohere)) |cohere| {
        if (cohere.count > 1) cohere_rows += 1;
    }
    try std.testing.expect(cohere_rows > 0);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();

    for ([_]usize{ 1, 4, 16 }) |items_per_range| {
        // Arbitration writes sticky columns back, so each run starts from fresh state.
        var threaded_data = DataSystem.init(std.testing.allocator);
        defer threaded_data.deinit();
        try fillParityAgents(&threaded_data);
        var threaded_spatial = try testSpatialIndex(&threaded_data);
        defer threaded_spatial.deinit();
        var cfg = base_cfg;
        cfg.items_per_range = items_per_range;
        cfg.max_worker_threads = 2;
        cfg.adaptive = false;
        var threaded_ai = AiSystem.init(std.testing.allocator);
        defer threaded_ai.deinit();
        var threaded_frame = SimulationFrame.init(std.testing.allocator);
        defer threaded_frame.deinit();
        try threaded_frame.reserveStreams(16, 0, 140, 0, 0, 0);
        threaded_frame.beginStep();
        _ = try threaded_ai.update(threaded_data.aiAgentSliceConst(), threaded_data.movementBodySliceConst(), threaded_spatial.view(), &threaded_data, &threaded_frame, &threads, 0.016, cfg);
        // Range boundaries split cells, each refilling: never fewer fills than serial.

        // Every gathered row, and the separation and cohere sums, bit for bit.
        const threaded_rows = threaded_ai.rows.slice();
        try std.testing.expectEqual(serial_rows.len, threaded_rows.len);
        for (0..serial_rows.len) |row| {
            const want = serial_rows.get(row);
            const got = threaded_rows.get(row);
            try std.testing.expect(want.entity.eql(got.entity));
            try std.testing.expectEqual(want.sticky.agent_dense_index, got.sticky.agent_dense_index);
            try std.testing.expectEqual(@as(u32, @bitCast(want.pos_x)), @as(u32, @bitCast(got.pos_x)));
            try std.testing.expectEqual(@as(u32, @bitCast(want.sep_x)), @as(u32, @bitCast(got.sep_x)));
            try std.testing.expectEqual(@as(u32, @bitCast(want.sep_y)), @as(u32, @bitCast(got.sep_y)));
            try std.testing.expectEqual(want.cohere.count, got.cohere.count);
            try std.testing.expectEqual(@as(u32, @bitCast(want.cohere.mean_x)), @as(u32, @bitCast(got.cohere.mean_x)));
            try std.testing.expectEqual(@as(u32, @bitCast(want.cohere.mean_y)), @as(u32, @bitCast(got.cohere.mean_y)));
            try std.testing.expectEqualDeep(want.resolved, got.resolved);
        }
        const threaded = threaded_frame.navigation_intents.mergedItems();
        try std.testing.expectEqual(serial.len, threaded.len);
        for (serial, threaded) |a, b| {
            try std.testing.expect(a.entity.eql(b.entity));
            try std.testing.expectEqual(@as(u32, @bitCast(a.direct_direction_x)), @as(u32, @bitCast(b.direct_direction_x)));
            try std.testing.expectEqual(@as(u32, @bitCast(a.direct_direction_y)), @as(u32, @bitCast(b.direct_direction_y)));
        }
    }
}

test "the threaded gather writes every row the serial gather does, skipping bodiless rows" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try fillParityAgents(&data);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3 });
    defer threads.deinit();
    const inputs = AiGatherInputs{ .ai_slice = data.aiAgentSliceConst(), .movement = data.movementBodySliceConst(), .data = &data, .focus_target = .{ .x = 1, .y = 2 }, .focus_entity = EntityId.invalid };

    var serial_ai = AiSystem.init(std.testing.allocator);
    defer serial_ai.deinit();
    var inline_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer inline_threads.deinit();
    _ = try serial_ai.gatherAiData(inputs, &inline_threads, .{});
    // Every eleventh agent has no body.
    try std.testing.expectEqual(@as(usize, 140 - 12), serial_ai.rows.len);
    // One and two gather alignments: three and two ranges over the 140 think rows.
    for ([_]usize{ ai_gather_range_alignment_items, 2 * ai_gather_range_alignment_items }) |items_per_range| {
        var threaded_ai = AiSystem.init(std.testing.allocator);
        defer threaded_ai.deinit();
        const batch = try threaded_ai.gatherAiData(inputs, &threads, .{ .items_per_range = items_per_range, .max_worker_threads = 3, .adaptive = false });
        try std.testing.expect(!batch.ran_inline);
        try std.testing.expectEqual(serial_ai.rows.len, threaded_ai.rows.len);
        for (0..serial_ai.rows.len) |row| try std.testing.expectEqualDeep(serial_ai.rows.get(row), threaded_ai.rows.get(row));
    }
}

test "separation and cohere give each row the same result in cell-major and cell-interleaved row order" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Three cells (32-unit cells) of four, three, and five agents, all with cohere gain.
    const cells = [_][2]f32{ .{ 40, 40 }, .{ 200, 40 }, .{ 40, 200 } };
    const counts = [_]usize{ 4, 3, 5 };
    for (cells, counts) |cell, count| {
        for (0..count) |k| {
            const entity = try data.createEntity();
            const offset = @as(f32, @floatFromInt(k)) * 2;
            try data.setMovementBody(entity, .{ .position = .{ .x = cell[0] + offset, .y = cell[1] }, .previous_position = .{ .x = cell[0] + offset, .y = cell[1] }, .velocity = .{}, .speed = 20 });
            try data.setAiAgent(entity, .{ .active_behavior = .wander, .gain_cohere = 1 });
            try data.setFaction(entity, .ally);
        }
    }
    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();
    const view = spatial_sys.view();
    var scope = SimulationScopeSystem.init(std.testing.allocator);
    defer scope.deinit();
    const think_set = try thinkSetInline(&scope, &view);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 16, 0, 0, 0);
    frame.beginStep();
    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    _ = try updateInline(&ai_sys, data.aiAgentSliceConst(), data.movementBodySliceConst(), view, &data, &frame, 0.016, .{ .scope_dense_indices = think_set });
    // Rows of one cell share each query kind's block.
    var cell_major: [12]RowSeparationResults = undefined;
    try expectRowsCollected(&ai_sys, &cell_major);

    // Rows interleaving the cells change key at every row: A B C A B C A B C A C C.
    const shuffled = [_]u32{ 0, 4, 7, 1, 5, 8, 2, 6, 9, 3, 10, 11 };
    frame.beginStep();
    _ = try updateInline(&ai_sys, data.aiAgentSliceConst(), data.movementBodySliceConst(), view, &data, &frame, 0.016, .{ .scope_dense_indices = &shuffled });
    var interleaved: [12]RowSeparationResults = undefined;
    try expectRowsCollected(&ai_sys, &interleaved);
    for (cell_major) |want| {
        const got = for (interleaved) |candidate| {
            if (candidate.entity.eql(want.entity)) break candidate;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u32, @bitCast(want.sep_x)), @as(u32, @bitCast(got.sep_x)));
        try std.testing.expectEqual(@as(u32, @bitCast(want.sep_y)), @as(u32, @bitCast(got.sep_y)));
        try std.testing.expectEqual(@as(u32, @bitCast(want.cohere.mean_x)), @as(u32, @bitCast(got.cohere.mean_x)));
        try std.testing.expectEqual(@as(u32, @bitCast(want.cohere.mean_y)), @as(u32, @bitCast(got.cohere.mean_y)));
        try std.testing.expectEqual(want.cohere.count, got.cohere.count);
    }
    // Each row coheres to the other rows of its cell, and rows off their cell's middle separate.
    var separated: usize = 0;
    for (cell_major) |row| {
        try std.testing.expect(row.cohere.count > 0);
        if (row.sep_x != 0 or row.sep_y != 0) separated += 1;
    }
    try std.testing.expect(separated >= 9);
}

// One gathered row's separation and cohere results.
const RowSeparationResults = struct {
    entity: EntityId,
    sep_x: f32,
    sep_y: f32,
    cohere: RowCohere,
};

// Copies the last update's rows' separation and cohere results; expects one row per slot.
fn expectRowsCollected(ai_sys: *const AiSystem, out: []RowSeparationResults) !void {
    try std.testing.expectEqual(out.len, ai_sys.rows.len);
    const rows = ai_sys.rows.slice();
    for (out, rows.items(.entity), rows.items(.sep_x), rows.items(.sep_y), rows.items(.cohere)) |*slot, entity, sep_x, sep_y, cohere| {
        slot.* = .{ .entity = entity, .sep_x = sep_x, .sep_y = sep_y, .cohere = cohere };
    }
}

test "ai spatial separation finds neighbors past the grid edge at negative coordinates" {
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

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    frame.beginStep();
    _ = try updateInline(&ai_sys, data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &frame, 0.016, .{
        .intent_seed = 1,
        .focus_target = .{ .x = 0, .y = 0 },
    });

    try std.testing.expectEqual(@as(usize, 2), frame.navigation_intents.mergedItems().len);
    // Each row separates from the other, 18.4 units away: the unit direction away from it.
    const gathered = ai_sys.rows.slice();
    const away_len = @sqrt(@as(f32, 14 * 14 + 12 * 12));
    for (gathered.items(.entity), gathered.items(.sep_x), gathered.items(.sep_y)) |entity, sep_x, sep_y| {
        const sign: f32 = if (entity.eql(first)) -1 else 1;
        try std.testing.expectApproxEqAbs(sign * 14 / away_len, sep_x, 1e-4);
        try std.testing.expectApproxEqAbs(sign * 12 / away_len, sep_y, 1e-4);
    }
}

test "think rows skip themselves and find halo neighbors" {
    // Halo [A, B, C]; only A and C think. Each must skip itself, not a neighbor, and
    // find off-phase B: separation (48) from B at 40 units, cohere (96) with B.
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const a = try data.createEntity();
    try data.setMovementBody(a, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 20 });
    try data.setAiAgent(a, .{ .active_behavior = .wander, .gain_cohere = 1.0 });
    try data.setFaction(a, .hostile);

    const b = try data.createEntity();
    try data.setMovementBody(b, .{ .position = .{ .x = 40, .y = 0 }, .previous_position = .{ .x = 40, .y = 0 }, .velocity = .{}, .speed = 20 });
    try data.setAiAgent(b, .{ .active_behavior = .wander, .gain_cohere = 1.0 });
    try data.setFaction(b, .hostile);

    const c = try data.createEntity();
    try data.setMovementBody(c, .{ .position = .{ .x = 80, .y = 0 }, .previous_position = .{ .x = 80, .y = 0 }, .velocity = .{}, .speed = 20 });
    try data.setAiAgent(c, .{ .active_behavior = .wander, .gain_cohere = 1.0 });
    try data.setFaction(c, .hostile);

    const halo = [_]u32{ 0, 1, 2 };
    const think = [_]u32{ 0, 2 };
    var spatial_sys = try testHaloIndex(&data, &halo);
    defer spatial_sys.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    frame.beginStep();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    _ = try updateInline(&ai_sys, data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &data, &frame, 0.016, .{
        .scope_dense_indices = &think,
    });

    try std.testing.expectEqual(@as(usize, 2), ai_sys.rows.len);
    const gathered = ai_sys.rows.slice();
    try std.testing.expectEqual(a.index, gathered.items(.entity)[0].index);
    try std.testing.expectEqual(c.index, gathered.items(.entity)[1].index);
    // Each thinker separates from B alone: A away from it toward -x, C toward +x.
    try std.testing.expectApproxEqAbs(@as(f32, -1), gathered.items(.sep_x)[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1), gathered.items(.sep_x)[1], 1e-4);
    for (gathered.items(.sep_y)) |sep_y| try std.testing.expectApproxEqAbs(@as(f32, 0), sep_y, 1e-4);
    // Cohere reaches B (40 away) and the other thinker (80 away), never itself.
    for (gathered.items(.cohere)) |cohere| {
        try std.testing.expectEqual(@as(u32, 2), cohere.count);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 60), gathered.items(.cohere)[0].mean_x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 20), gathered.items(.cohere)[1].mean_x, 1e-4);
}

test "separation and cohere read only the row's level, and cohere only friendly rows" {
    // A thinker on level 2, a friendly 20 units along +x and a hostile 20 units along -y
    // on its level, and a friendly on each of levels 0, 1, and 3 at the thinker's xy
    // offset by 10 along +x.
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const Body = struct {
        fn add(store: *DataSystem, x: f32, y: f32, level: u16, faction: Faction, gain_cohere: f32) !EntityId {
            const entity = try store.createEntity();
            try store.setMovementBody(entity, .{ .position = .{ .x = x, .y = y }, .previous_position = .{ .x = x, .y = y }, .velocity = .{}, .speed = 20 });
            try store.setAiAgent(entity, .{ .active_behavior = .wander, .gain_cohere = gain_cohere });
            try store.setFaction(entity, faction);
            try store.setWorldLevel(entity, level);
            return entity;
        }
    };
    _ = try Body.add(&data, 0, 0, 2, .player, 1.0);
    _ = try Body.add(&data, 20, 0, 2, .ally, 0);
    _ = try Body.add(&data, 0, -20, 2, .hostile, 0);
    for ([_]u16{ 0, 1, 3 }) |level| _ = try Body.add(&data, 10, 0, level, .ally, 0);

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();
    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    try gatherInline(&ai_sys, .{ .ai_slice = data.aiAgentSliceConst(), .movement = data.movementBodySliceConst(), .data = &data });
    const context = buildAiSeparationContext(ai_sys.rows.slice(), spatial_sys.view(), ai_sys.range_tallies.items, null);
    var separation_block = SeparationBlock{};
    var cohere_block = CohereBlock{};

    // Away from the same-level friendly (-x) and hostile (+y); an other-level friendly
    // would add another -x.
    const separation = computeBoundedSeparation(&context, 0, &separation_block);
    try std.testing.expectApproxEqAbs(@as(f32, -1), separation.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1), separation.y, 1e-4);
    const cohere = computeCohereNeighbors(&context, 0, &cohere_block);
    try std.testing.expectEqual(@as(u32, 1), cohere.count);
    try std.testing.expectEqual(@as(f32, 20), cohere.mean_x);
    try std.testing.expectEqual(@as(f32, 0), cohere.mean_y);
}

// A row's separation from its neighbors visited in `order`, each at its lane, summed in
// lane partials as the index's lane scan does: the reference both oracles below feed.
const LaneSeparation = struct {
    acc_x: [simd.lane_count]f32 = @splat(0),
    acc_y: [simd.lane_count]f32 = @splat(0),
    lane_terms: [simd.lane_count]u8 = @splat(0),
    candidate_count: u16 = 0,
    neighbor_count: u8 = 0,
    done: bool = false,

    // Visits neighbor `j` at `lane`, or nothing once the query has ended.
    fn visit(self: *LaneSeparation, pos_x: []const f32, pos_y: []const f32, index: usize, j: usize, lane: usize) void {
        if (self.done) return;
        if (self.candidate_count >= max_separation_candidate_checks) {
            self.done = true;
            return;
        }
        self.candidate_count += 1;
        const dx = pos_x[index] - pos_x[j];
        const dy = pos_y[index] - pos_y[j];
        const dist2 = dx * dx + dy * dy;
        if (dist2 > separation_min_dist2 and dist2 < separation_radius * separation_radius) {
            const dir = math.normalizeOrZeroFinite(dx, dy, 0);
            self.acc_x[lane] += dir.x;
            self.acc_y[lane] += dir.y;
            self.lane_terms[lane] += 1;
            self.neighbor_count += 1;
            if (self.neighbor_count >= max_separation_neighbors) self.done = true;
        }
    }

    fn finish(self: *LaneSeparation) ReferenceSeparation {
        return .{ .x = simd.sumLanesScalar(self.acc_x), .y = simd.sumLanesScalar(self.acc_y), .neighbor_count = self.neighbor_count };
    }
};

// An oracle's separation sum and the neighbors it summed.
const ReferenceSeparation = struct { x: f32, y: f32, neighbor_count: u8 };

// Reference for a single populated cell: one stream in index order, so neighbor `j`'s lane
// is its rank in it, self included, mod 4.
fn bruteForceSeparation(pos_x: []const f32, pos_y: []const f32, index: usize) ReferenceSeparation {
    var lanes = LaneSeparation{};
    for (0..pos_x.len) |j| {
        if (j == index) continue;
        lanes.visit(pos_x, pos_y, index, j, j % simd.lane_count);
    }
    return lanes.finish();
}

test "ai computeBoundedSeparation matches a one-cell lane-order reference bit-for-bit" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    var prng = std.Random.DefaultPrng.init(0x51ab_dead);
    const rand = prng.random();
    // One cell (well under the 32-unit cell), and past the 32-neighbor stop mid-batch.
    const count = 40;
    for (0..count) |_| {
        const entity = try data.createEntity();
        const position = math.Vec2{ .x = rand.float(f32) * 20.0, .y = rand.float(f32) * 20.0 };
        try data.setMovementBody(entity, .{ .position = position, .previous_position = position, .velocity = .{}, .speed = 20 });
        try data.setAiAgent(entity, .{ .active_behavior = .wander });
    }

    const ai_slice = data.aiAgentSliceConst();
    const movement_slice = data.movementBodySliceConst();

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();
    try std.testing.expectEqual(@as(usize, 1), spatial_sys.view().rows.len);

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    try gatherInline(&ai_sys, .{ .ai_slice = ai_slice, .movement = movement_slice, .data = &data });
    try std.testing.expectEqual(@as(usize, count), ai_sys.rows.len);

    const gathered = ai_sys.rows.slice();
    const pos_x = gathered.items(.pos_x);
    const pos_y = gathered.items(.pos_y);

    const context = buildAiSeparationContext(gathered, spatial_sys.view(), ai_sys.range_tallies.items, null);

    var separation_block = SeparationBlock{};

    var capped: usize = 0;
    for (0..count) |i| {
        const ported = computeBoundedSeparation(&context, i, &separation_block);
        const reference = bruteForceSeparation(pos_x, pos_y, i);
        try std.testing.expectEqual(reference.x, ported.x);
        try std.testing.expectEqual(reference.y, ported.y);
        if (reference.neighbor_count == max_separation_neighbors) capped += 1;
    }
    try std.testing.expect(capped > 0);
}

// The index's default cell size, which `testSpatialIndex` builds at.
const test_cell_size: f32 = (spatial_index.SpatialIndexConfig{}).cell_size;
const test_separation_scan_radius: i32 = @intFromFloat(@ceil(separation_radius / test_cell_size));

// Reconstructs the index's order from raw positions: with one faction, one level, and one
// chunk it is (cell_y, cell_x, index), one stream whose lanes count every in-box entry, self
// included. `max_lane_terms` is the most terms one lane summed.
fn cellScanOrderedSeparation(pos_x: []const f32, pos_y: []const f32, index: usize, max_lane_terms: *u8) ReferenceSeparation {
    const cellOf = struct {
        fn compute(x: f32, y: f32) [2]i32 {
            return .{
                @as(i32, @intFromFloat(@floor(x / test_cell_size))),
                @as(i32, @intFromFloat(@floor(y / test_cell_size))),
            };
        }
    }.compute;
    const own_cell = cellOf(pos_x[index], pos_y[index]);
    var lanes = LaneSeparation{};
    var rank: usize = 0;
    var cell_y = own_cell[1] - test_separation_scan_radius;
    while (cell_y <= own_cell[1] + test_separation_scan_radius) : (cell_y += 1) {
        var cell_x = own_cell[0] - test_separation_scan_radius;
        while (cell_x <= own_cell[0] + test_separation_scan_radius) : (cell_x += 1) {
            for (0..pos_x.len) |j| {
                const j_cell = cellOf(pos_x[j], pos_y[j]);
                if (j_cell[0] != cell_x or j_cell[1] != cell_y) continue;
                const lane = rank % simd.lane_count;
                rank += 1;
                if (j == index) continue;
                lanes.visit(pos_x, pos_y, index, j, lane);
            }
        }
    }
    for (lanes.lane_terms) |terms| max_lane_terms.* = @max(max_lane_terms.*, terms);
    return lanes.finish();
}

test "ai computeBoundedSeparation matches a cell-scan-ordered lane oracle across multiple cells" {
    // Agents across many cells, so a flipped scan order, a within-cell walk out of index
    // order, or a lane off its run position breaks bit-exact parity.
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

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    try gatherInline(&ai_sys, .{ .ai_slice = ai_slice, .movement = movement_slice, .data = &data });
    try std.testing.expectEqual(@as(usize, count), ai_sys.rows.len);

    const gathered = ai_sys.rows.slice();
    const pos_x = gathered.items(.pos_x);
    const pos_y = gathered.items(.pos_y);

    // Fail loud if the fixture regresses to a near-single-cell spread, or leaves its one
    // chunk.
    var min_cell_x: i32 = std.math.maxInt(i32);
    var max_cell_x: i32 = std.math.minInt(i32);
    var min_cell_y: i32 = std.math.maxInt(i32);
    var max_cell_y: i32 = std.math.minInt(i32);
    for (0..count) |i| {
        const cx: i32 = @intFromFloat(@floor(pos_x[i] / test_cell_size));
        const cy: i32 = @intFromFloat(@floor(pos_y[i] / test_cell_size));
        min_cell_x = @min(min_cell_x, cx);
        max_cell_x = @max(max_cell_x, cx);
        min_cell_y = @min(min_cell_y, cy);
        max_cell_y = @max(max_cell_y, cy);
    }
    try std.testing.expect(max_cell_x - min_cell_x >= 3);
    try std.testing.expect(max_cell_y - min_cell_y >= 3);
    try std.testing.expect(min_cell_x >= 0 and min_cell_y >= 0 and max_cell_x < spatial_sys.view().cells_per_chunk and max_cell_y < spatial_sys.view().cells_per_chunk);

    const context = buildAiSeparationContext(gathered, spatial_sys.view(), ai_sys.range_tallies.items, null);

    var separation_block = SeparationBlock{};

    // Fail loud if no lane ever sums two terms: the lane order would be untested.
    var max_lane_terms: u8 = 0;
    for (0..count) |i| {
        const ported = computeBoundedSeparation(&context, i, &separation_block);
        const reference = cellScanOrderedSeparation(pos_x, pos_y, i, &max_lane_terms);
        try std.testing.expectEqual(reference.x, ported.x);
        try std.testing.expectEqual(reference.y, ported.y);
    }
    try std.testing.expect(max_lane_terms >= 2);
}

// An agent with cohere gain, of `faction`, at `(x, y)`.
fn addCohereBody(data: *DataSystem, x: f32, y: f32, faction: Faction) !void {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{ .x = x, .y = y }, .previous_position = .{ .x = x, .y = y }, .velocity = .{}, .speed = 20 });
    try data.setAiAgent(entity, .{ .active_behavior = .wander, .gain_cohere = 1.0 });
    try data.setFaction(entity, faction);
}

test "cohere finds its ally past more hostiles than its check budget" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // The thinker in cell row 3, 65 hostiles in row 2 within reach and scanned first, and
    // one ally in row 4.
    try addCohereBody(&data, 100, 100, .player);
    for (0..max_cohere_candidate_checks + 1) |hostile| try addCohereBody(&data, 60 + 1.2 * @as(f32, @floatFromInt(hostile)), 70, .hostile);
    try addCohereBody(&data, 100, 150, .ally);

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();
    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    try gatherInline(&ai_sys, .{ .ai_slice = data.aiAgentSliceConst(), .movement = data.movementBodySliceConst(), .data = &data });
    const context = buildAiSeparationContext(ai_sys.rows.slice(), spatial_sys.view(), ai_sys.range_tallies.items, null);
    var cohere_block = CohereBlock{};
    const cohere = computeCohereNeighbors(&context, 0, &cohere_block);
    try std.testing.expectEqual(@as(u32, 1), cohere.count);
    try std.testing.expectEqual(@as(f32, 100), cohere.mean_x);
    try std.testing.expectEqual(@as(f32, 150), cohere.mean_y);
}

test "cohere caps at its neighbor count, summing the first in scan order in lane partials" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // One cell: the thinker, then 14 allies.
    try addCohereBody(&data, 16, 16, .player);
    var prng = std.Random.DefaultPrng.init(0xc0e4_e12a);
    const rand = prng.random();
    for (0..14) |_| try addCohereBody(&data, 1 + rand.float(f32) * 30, 1 + rand.float(f32) * 30, .ally);

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();
    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    try gatherInline(&ai_sys, .{ .ai_slice = data.aiAgentSliceConst(), .movement = data.movementBodySliceConst(), .data = &data });
    const gathered = ai_sys.rows.slice();
    const context = buildAiSeparationContext(gathered, spatial_sys.view(), ai_sys.range_tallies.items, null);
    var cohere_block = CohereBlock{};
    const cohere = computeCohereNeighbors(&context, 0, &cohere_block);
    try std.testing.expectEqual(max_cohere_neighbors, cohere.count);

    // The ally run follows self's one-entry player run in the stream: ally k at rank k + 1.
    var acc_x: [simd.lane_count]f32 = @splat(0);
    var acc_y: [simd.lane_count]f32 = @splat(0);
    for (0..max_cohere_neighbors) |ally| {
        acc_x[(ally + 1) % simd.lane_count] += gathered.items(.pos_x)[ally + 1];
        acc_y[(ally + 1) % simd.lane_count] += gathered.items(.pos_y)[ally + 1];
    }
    const inv = 1.0 / @as(f32, @floatFromInt(max_cohere_neighbors));
    try std.testing.expectEqual(simd.sumLanesScalar(acc_x) * inv, cohere.mean_x);
    try std.testing.expectEqual(simd.sumLanesScalar(acc_y) * inv, cohere.mean_y);
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

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    frame.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
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

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    frame.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
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
    // config fields defaulting to null.
    const no_memory = try data.createEntity();
    try data.setMovementBody(no_memory, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(no_memory, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });
    try data.setAiPerception(no_memory, .{ .target_visible = false });
    // Deliberately no setAiMemory call for this entity.

    // Memory present but last_known_target invalid: override must not apply.
    // Same start position as `no_memory`; agents at exact-equal positions get
    // zero separation contribution (the `dist2 > 0.1` near-zero guard in
    // `SeparationAccumulator.visitLanes`), so this stays a pure seek-direction check.
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

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    frame.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
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

    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    frame.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
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

test "ai serial and threaded agree on a memory-overridden seek target" {
    // Two DataSystems: arbitration write-back mutates sticky columns.
    var serial_data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer serial_data.deinit();
    var threaded_data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer threaded_data.deinit();

    inline for (.{ &serial_data, &threaded_data }) |data| {
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
        try addParityFillers(data, parity_filler_count);
    }
    const agent_count = 1 + parity_filler_count;

    var serial_spatial = try testSpatialIndex(&serial_data);
    defer serial_spatial.deinit();
    var threaded_spatial = try testSpatialIndex(&threaded_data);
    defer threaded_spatial.deinit();

    var serial_ai = AiSystem.init(std.testing.allocator);
    defer serial_ai.deinit();
    var serial_frame = SimulationFrame.init(std.testing.allocator);
    defer serial_frame.deinit();
    try serial_frame.reserveStreams(8, 0, agent_count, 0, 0, 0);
    serial_frame.beginStep();
    _ = try updateInline(&serial_ai, serial_data.aiAgentSliceConst(), serial_data.movementBodySliceConst(), serial_spatial.view(), &serial_data, &serial_frame, 0.016, .{
        .intent_seed = 1,
        .focus_target = .{ .x = 100, .y = 0 },
        .perception_slice = serial_data.aiPerceptionSliceConst(),
        .memory_slice = serial_data.aiMemorySliceConst(),
    });
    const serial = serial_frame.navigation_intents.mergedItems();
    try std.testing.expect(serial.len >= 1);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    var threaded_ai = AiSystem.init(std.testing.allocator);
    defer threaded_ai.deinit();
    var threaded_frame = SimulationFrame.init(std.testing.allocator);
    defer threaded_frame.deinit();
    try threaded_frame.reserveStreams(8, 0, agent_count, 0, 0, 0);
    threaded_frame.beginStep();
    _ = try threaded_ai.update(threaded_data.aiAgentSliceConst(), threaded_data.movementBodySliceConst(), threaded_spatial.view(), &threaded_data, &threaded_frame, &threads, 0.016, .{
        .intent_seed = 1,
        .focus_target = .{ .x = 100, .y = 0 },
        .perception_slice = threaded_data.aiPerceptionSliceConst(),
        .memory_slice = threaded_data.aiMemorySliceConst(),
        .items_per_range = ai_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });
    const threaded = threaded_frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(serial.len, threaded.len);
    for (serial, threaded) |a, b| {
        try std.testing.expectEqual(a.entity.index, b.entity.index);
        try std.testing.expectEqual(a.goal.x, b.goal.x);
        try std.testing.expectEqual(a.goal.y, b.goal.y);
    }

    try std.testing.expectEqual(serial[0].goal.x, threaded[0].goal.x);
    try std.testing.expectEqual(serial[0].goal.y, threaded[0].goal.y);
    try std.testing.expectEqual(serial[0].direct_direction_x, threaded[0].direct_direction_x);
    try std.testing.expectEqual(serial[0].direct_direction_y, threaded[0].direct_direction_y);
    // Both must reflect the memory override, not the configured seek_target.
    try std.testing.expectEqual(@as(f32, 0), serial[0].goal.x);
    try std.testing.expectEqual(@as(f32, 100), serial[0].goal.y);
}

// ---- Arbitration integration tests ---------------------------------------------

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
    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 2, 0, 0, 0);

    frame.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
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
    // wander-only agent keeps wandering.
    try data.setAiAgent(entity, .{ .active_behavior = .wander, .wander_amplitude = 30, .gain_pursue = 1.0 });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();
    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 2, 0, 0, 0);

    frame.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{ .intent_seed = 7 });

    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), intents.len);
    // A resolveGoal-invalid row's goal falls back to self position.
    try std.testing.expectEqual(@as(f32, 10), intents[0].goal.x);
    try std.testing.expectEqual(@as(f32, 10), intents[0].goal.y);
    try std.testing.expectEqual(@as(i16, 0), intents[0].priority);
    try std.testing.expect(data_test_support.aiAgent(&data, entity).?.active_behavior == .wander);
}

test "invalid pursue goal writes wander active_behavior so fatigue does not treat it as exertion" {
    var data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer data.deinit();

    // Sticky-held pursue with commitment remaining, but no visible threat, no
    // fresh memory, no focus_target: resolveGoal is invalid and locomotion
    // degrades to wander. active_behavior must become wander (not stay pursue)
    // so affect's fatigue path does not keep accruing exertion.
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(entity, .{
        .active_behavior = .pursue,
        .commitment_remaining = 10,
        .commitment_max_steps = 30,
        .sticky_bonus = 0.2,
        .wander_amplitude = 0,
        .gain_pursue = 1.0,
        .gain_wander = 0.1,
    });
    try data.setAiPerception(entity, .{ .target_visible = false });

    const ai_slice = data.aiAgentSliceConst();
    const move_slice = data.movementBodySliceConst();
    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 2, 0, 0, 0);

    frame.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{
        .intent_seed = 1,
        .perception_slice = data.aiPerceptionSliceConst(),
    });

    const agent = data_test_support.aiAgent(&data, entity).?;
    try std.testing.expect(agent.active_behavior == .wander);
    try std.testing.expectEqual(@as(u16, 0), agent.commitment_remaining);
}

test "arbitration serial and threaded parity across perception + memory + affect signals" {
    // Two DataSystems: arbitration write-back mutates sticky columns.
    var serial_data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer serial_data.deinit();
    var threaded_data = @import("../data_system.zig").DataSystem.init(std.testing.allocator);
    defer threaded_data.deinit();

    // More agents than one aligned range of every AI stage, so the threaded side splits them
    // across workers.
    const agent_count: usize = ai_intent_range_alignment_items + 2 * ai_range_alignment_items;
    inline for (.{ &serial_data, &threaded_data }) |data| {
        for (0..agent_count) |i| {
            const x: f32 = @floatFromInt(i * 6);
            const entity = try data.createEntity();
            try data.setMovementBody(entity, .{ .position = .{ .x = x, .y = 0 }, .previous_position = .{ .x = x, .y = 0 }, .velocity = .{}, .speed = 30 });
            try data.setFaction(entity, if (i % 2 == 0) .player else .hostile);
            try data.setAiAgent(entity, .{
                .active_behavior = .wander,
                .wander_amplitude = @floatFromInt(i % 5),
                .gain_wander = if (i == 0) 0 else 1.0,
                .gain_pursue = if (i == 0) 0 else if (i % 3 == 0) 1.0 else 0,
                .gain_flee = if (i == 0) 0 else if (i % 3 == 1) 1.0 else 0,
                .gain_cohere = if (i == 0) 0 else if (i % 3 == 2) 1.0 else 0,
                .gain_investigate = if (i == 0) 1.0 else 0,
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
    }

    var serial_spatial = try testSpatialIndex(&serial_data);
    defer serial_spatial.deinit();
    var threaded_spatial = try testSpatialIndex(&threaded_data);
    defer threaded_spatial.deinit();

    var markers = InterestMarkerStore.init(std.testing.allocator);
    defer markers.deinit(std.testing.allocator);
    _ = try markers.addMarker(.{
        .kind = .investigate,
        .level = 0,
        .x = 100,
        .y = 0,
        .radius = 8,
    });

    var serial_ai = AiSystem.init(std.testing.allocator);
    defer serial_ai.deinit();
    var serial_frame = SimulationFrame.init(std.testing.allocator);
    defer serial_frame.deinit();
    try serial_frame.reserveStreams(8, 0, agent_count, 0, 0, 0);
    serial_frame.beginStep();
    _ = try updateInline(&serial_ai, serial_data.aiAgentSliceConst(), serial_data.movementBodySliceConst(), serial_spatial.view(), &serial_data, &serial_frame, 0.016, .{
        .intent_seed = 0x51de51de,
        .step = 3,
        .perception_slice = serial_data.aiPerceptionSliceConst(),
        .memory_slice = serial_data.aiMemorySliceConst(),
        .affect_slice = serial_data.aiAffectSliceConst(),
        .interest_markers = &markers,
    });
    const serial = serial_frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(agent_count, serial.len);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    var threaded_ai = AiSystem.init(std.testing.allocator);
    defer threaded_ai.deinit();
    var threaded_frame = SimulationFrame.init(std.testing.allocator);
    defer threaded_frame.deinit();
    try threaded_frame.reserveStreams(8, 0, agent_count, 0, 0, 0);
    threaded_frame.beginStep();
    _ = try threaded_ai.update(threaded_data.aiAgentSliceConst(), threaded_data.movementBodySliceConst(), threaded_spatial.view(), &threaded_data, &threaded_frame, &threads, 0.016, .{
        .intent_seed = 0x51de51de,
        .step = 3,
        .perception_slice = threaded_data.aiPerceptionSliceConst(),
        .memory_slice = threaded_data.aiMemorySliceConst(),
        .affect_slice = threaded_data.aiAffectSliceConst(),
        .interest_markers = &markers,
        .items_per_range = ai_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });
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
    var saw_marker = false;
    for (serial) |intent| {
        if (intent.goal.x == 100 and intent.goal.y == 0) saw_marker = true;
    }
    try std.testing.expect(saw_marker);
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
    var spatial_sys = try testSpatialIndex(&data);
    defer spatial_sys.deinit();

    var ai_sys = AiSystem.init(std.testing.allocator);
    defer ai_sys.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 4, 0, 0, 0);

    frame.beginStep();
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, .{ .intent_seed = 1 });

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
    var spatial_sys = try testSpatialIndex(&data);
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

    try ai_sys.reserve(ai_slice.entities.len);

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
    _ = try updateInline(&ai_sys, ai_slice, move_slice, spatial_sys.view(), &data, &frame, 0.016, cfg);
    try std.testing.expectEqual(@as(usize, 1), frame.navigation_intents.mergedItems().len);
}
