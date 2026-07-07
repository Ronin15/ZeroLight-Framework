// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-owned fixed-step simulation pipeline.
//! The pipeline owns reusable simulation systems, stage order, scope stats, and
//! processor handoff for one gameplay state instance. It is intentionally not a
//! global scheduler or dynamic system registry.

const std = @import("std");
const builtin = @import("builtin");
const math = @import("../core/math.zig");
const runtime_perf_log = @import("../app/runtime_perf_log.zig");
const c = @import("../platform/sdl.zig").c;
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const DataSystem = @import("data_system.zig").DataSystem;
const EntityId = @import("data_system.zig").EntityId;
const Faction = @import("data_system.zig").Faction;
const MovementBodyPtr = @import("data_system.zig").MovementBodyPtr;
const PrimitiveVisual = @import("data_system.zig").PrimitiveVisual;
const DigConfig = @import("dig_controller.zig").DigConfig;
const DigController = @import("dig_controller.zig").DigController;
const AudioController = @import("audio_controller.zig").AudioController;
const AudioCommandBuffer = @import("../app/audio.zig").AudioCommandBuffer;
const InputState = @import("../app/input.zig").InputState;
const Player = @import("player.zig").Player;
const AiStats = @import("systems/ai.zig").AiStats;
const AiSystem = @import("systems/ai.zig").AiSystem;
const AiMemoryStats = @import("systems/ai_memory.zig").AiMemoryStats;
const AiMemorySystem = @import("systems/ai_memory.zig").AiMemorySystem;
const AffectStats = @import("systems/affect.zig").AffectStats;
const AffectSystem = @import("systems/affect.zig").AffectSystem;
const CollisionStats = @import("systems/collision.zig").CollisionStats;
const CollisionSystem = @import("systems/collision.zig").CollisionSystem;
const CollisionResponseStats = @import("systems/collision_response.zig").CollisionResponseStats;
const CollisionResponseSystem = @import("systems/collision_response.zig").CollisionResponseSystem;
const MovementStats = @import("systems/movement.zig").MovementStats;
const MovementSystem = @import("systems/movement.zig").MovementSystem;
const PathfindingCapacity = @import("systems/pathfinding.zig").PathfindingCapacity;
const PathfindingStats = @import("systems/pathfinding.zig").PathfindingStats;
const PathfindingSystem = @import("systems/pathfinding.zig").PathfindingSystem;
const NavUpdateStats = @import("systems/pathfinding.zig").NavUpdateStats;
const PerceptionStats = @import("systems/perception.zig").PerceptionStats;
const PerceptionSystem = @import("systems/perception.zig").PerceptionSystem;
const PlayerPerceptionCandidate = @import("systems/perception.zig").PlayerPerceptionCandidate;
const SteeringStats = @import("systems/steering.zig").SteeringStats;
const SteeringSystem = @import("systems/steering.zig").SteeringSystem;
const SimulationFrame = @import("simulation.zig").SimulationFrame;
const StructuralCommand = @import("data_system.zig").StructuralCommand;
const SimulationScope = @import("simulation_scope.zig").SimulationScope;
const ActiveRegion = @import("simulation_scope.zig").ActiveRegion;
const cognition_halo_chunks = @import("simulation_scope.zig").cognition_halo_chunks;
const SimulationScopeSystem = @import("systems/simulation_scope.zig").SimulationScopeSystem;
const SpatialIndexStats = @import("systems/spatial_index.zig").SpatialIndexStats;
const SpatialIndexSystem = @import("systems/spatial_index.zig").SpatialIndexSystem;
const CellCoord = @import("world_system.zig").CellCoord;
const WorldSystem = @import("world_system.zig").WorldSystem;

/// Coarse per-step data resources stages read/write, for the stage-ordering
/// contract below. Some tags bundle several SoA columns owned by one system
/// (e.g. `movement_positions` covers the movement body's position/velocity
/// columns together) rather than tracking every field individually.
const PipelineResource = enum {
    world_tiles,
    events,
    ai_scope_indices,
    spatial_index,
    navigation_intents,
    movement_intents,
    path_requests,
    movement_positions,
    movement_scope_indices,
    collision_scope_indices,
    contacts,
    collision_triggers,
    world_level,
    structural_commands,
    perception_sensed,
    ai_memory,
    affect_drives,
};

const ResourceSet = std.EnumSet(PipelineResource);

fn resources(comptime items: []const PipelineResource) ResourceSet {
    return ResourceSet.initMany(items);
}

const StageId = enum {
    dig_world_edit,
    scope_advance_and_ai_gather,
    spatial_index_build,
    perception_update,
    ai_memory_update,
    affect_update,
    ai_decide,
    steering_update,
    pathfinding_update,
    apply_ai_movement_intents,
    movement_scope_gather,
    movement_integrate,
    bounds_and_tile_gate,
    collision_scope_gather,
    collision_detect,
    collision_respond,
    plane_traversal,
    tier_policy,
};

const StageContract = struct { reads: ResourceSet, writes: ResourceSet };

/// Declares each stage's resource reads/writes against `stage_order` below.
/// Checked at comptime: a stage cannot read a resource no earlier stage in
/// `stage_order` writes.
fn stageContract(stage: StageId) StageContract {
    return switch (stage) {
        .dig_world_edit => .{ .reads = .empty, .writes = resources(&.{ .world_tiles, .events }) },
        .scope_advance_and_ai_gather => .{ .reads = .empty, .writes = resources(&.{.ai_scope_indices}) },
        .spatial_index_build => .{ .reads = resources(&.{.ai_scope_indices}), .writes = resources(&.{.spatial_index}) },
        // Queries the spatial index for hostile candidates and writes sensed state; also
        // emits acquisition/loss transition events (Slice 29).
        .perception_update => .{ .reads = resources(&.{ .ai_scope_indices, .spatial_index }), .writes = resources(&.{ .perception_sensed, .events }) },
        // Refreshes from this step's perception transition events (Slice 30); does not
        // read perception_sensed's raw columns directly.
        .ai_memory_update => .{ .reads = resources(&.{ .ai_scope_indices, .events }), .writes = resources(&.{.ai_memory}) },
        // Appraises this step's just-written perception + memory columns into drives
        // (Slice 31); a future arbitration stage (Slice 32) is the first affect_drives reader.
        .affect_update => .{ .reads = resources(&.{ .ai_scope_indices, .perception_sensed, .ai_memory }), .writes = resources(&.{ .affect_drives, .events }) },
        .ai_decide => .{ .reads = resources(&.{ .ai_scope_indices, .spatial_index, .perception_sensed, .ai_memory }), .writes = resources(&.{.navigation_intents}) },
        .steering_update => .{ .reads = resources(&.{.navigation_intents}), .writes = resources(&.{ .movement_intents, .path_requests }) },
        .pathfinding_update => .{ .reads = resources(&.{.path_requests}), .writes = .empty },
        .apply_ai_movement_intents => .{ .reads = resources(&.{.movement_intents}), .writes = resources(&.{.movement_positions}) },
        .movement_scope_gather => .{ .reads = .empty, .writes = resources(&.{.movement_scope_indices}) },
        .movement_integrate => .{ .reads = resources(&.{ .movement_positions, .movement_scope_indices }), .writes = resources(&.{.movement_positions}) },
        .bounds_and_tile_gate => .{ .reads = resources(&.{.movement_positions}), .writes = resources(&.{.movement_positions}) },
        .collision_scope_gather => .{ .reads = .empty, .writes = resources(&.{.collision_scope_indices}) },
        .collision_detect => .{ .reads = resources(&.{ .movement_positions, .collision_scope_indices }), .writes = resources(&.{.contacts}) },
        .collision_respond => .{ .reads = resources(&.{.contacts}), .writes = resources(&.{ .movement_positions, .collision_triggers }) },
        .plane_traversal => .{ .reads = resources(&.{.movement_positions}), .writes = resources(&.{ .world_tiles, .world_level, .events }) },
        .tier_policy => .{ .reads = resources(&.{.movement_positions}), .writes = resources(&.{.structural_commands}) },
    };
}

/// The pipeline's concrete fixed-step stage order. `update()` marks each stage
/// via `stage_trace` at its real call site so the order-trace test below can
/// prove this declared order matches what actually runs.
const stage_order = [_]StageId{
    .dig_world_edit,
    .scope_advance_and_ai_gather,
    .spatial_index_build,
    .perception_update,
    .ai_memory_update,
    .affect_update,
    .ai_decide,
    .steering_update,
    .pathfinding_update,
    .apply_ai_movement_intents,
    .movement_scope_gather,
    .movement_integrate,
    .bounds_and_tile_gate,
    .collision_scope_gather,
    .collision_detect,
    .collision_respond,
    .plane_traversal,
    .tier_policy,
};

comptime {
    var produced: ResourceSet = .empty;
    for (stage_order) |stage| {
        const contract = stageContract(stage);
        const unmet = contract.reads.differenceWith(produced);
        if (unmet.count() != 0) {
            @compileError("SimulationPipeline stage '" ++ @tagName(stage) ++
                "' reads a resource no earlier stage writes — fix stage_order or stageContract()");
        }
        produced.setUnion(contract.writes);
    }
}

/// Test-only record of the stage order `update()` actually ran, so a test can
/// assert it matches `stage_order`. Zero-cost outside tests.
const StageTrace = if (builtin.is_test) struct {
    order: [stage_order.len]StageId = undefined,
    count: usize = 0,

    fn mark(self: *StageTrace, stage: StageId) void {
        self.order[self.count] = stage;
        self.count += 1;
    }

    fn slice(self: *const StageTrace) []const StageId {
        return self.order[0..self.count];
    }
} else struct {
    fn mark(_: *StageTrace, _: StageId) void {}
    fn slice(_: *const StageTrace) []const StageId {
        return &.{};
    }
};

/// Construction policy for the state-owned simulation pipeline.
/// Capacities are reserved up front so the fixed-step hot path can stay warm.
pub const SimulationPipelineConfig = struct {
    steering_agent_capacity: usize = 0,
    static_obstacle_capacity: usize = 0,
    contact_capacity: usize = 0,
    /// Movement-body count the scope system pre-sizes its gather/tier scratch to,
    /// so the per-step scope passes are allocation-free after init.
    movement_body_capacity: usize = 0,
    pathfinding: PathfindingCapacity = .{},
    nav_cell_size: f32 = 32.0,
    navigation_world: ?*const WorldSystem = null,
    /// When set, the one-time static nav build fans mask/abstract work across levels.
    nav_build_thread_system: ?*ThreadSystem = null,
    dig: DigConfig = .{},
    /// This state's reserved share of `frame.events`'s `capacity_limit` (see
    /// `SimulationFrame.reserveStreams`), passed through as
    /// `PerceptionConfig.max_events_per_step`. Sized by the caller against its
    /// own event-capacity budget, same as `contact_capacity`/
    /// `static_obstacle_capacity`; defaults to 0.
    perception_max_events_per_step: usize = 0,
    /// This state's reserved share of `frame.events`'s `capacity_limit`,
    /// passed through as `AffectConfig.max_events_per_step`. Sized by the
    /// caller against its own event-capacity budget, same as
    /// `perception_max_events_per_step`; defaults to 0.
    affect_max_events_per_step: usize = 0,
};

/// Borrowed per-step inputs for pipeline update.
/// The pipeline owns systems and stage order, but not persistent game data,
/// frame storage, app services, or state transitions.
pub const SimulationPipelineUpdateContext = struct {
    data: *DataSystem,
    frame: *SimulationFrame,
    /// Mutable world for the dig controller's world-tile authoring. Borrowed for
    /// the step only; persistent tile facts stay owned by the gameplay state.
    world: *WorldSystem,
    player: *Player,
    thread_system: *ThreadSystem,
    delta_seconds: f32,
    bounds_width: f32,
    bounds_height: f32,
    /// Borrowed runtime perf sink. Stage timers are zero-cost when perf
    /// logging is disabled at comptime, so the hot path stays clean.
    perf: runtime_perf_log.Context = .{},
};

/// Aggregated outputs from one pipeline step. Runtime perf and tests consume
/// these counters without adding a separate timing path to gameplay code.
pub const SimulationPipelineStats = struct {
    scope: SimulationScope = .{},
    spatial_index: SpatialIndexStats = .{},
    perception: PerceptionStats = .{},
    ai_memory: AiMemoryStats = .{},
    affect: AffectStats = .{},
    ai: AiStats = .{},
    steering: SteeringStats = .{},
    pathfinding: PathfindingStats = .{},
    movement: MovementStats = .{},
    collision: CollisionStats = .{},
    collision_response: CollisionResponseStats = .{},

    pub fn recordTo(self: SimulationPipelineStats, perf: runtime_perf_log.Context) void {
        const scope_stats = self.scope.stats;
        const spatial_index_stats = self.spatial_index;
        const ai_stats = self.ai;
        const steering_stats = self.steering;
        const pathfinding_stats = self.pathfinding;
        const movement_stats = self.movement;
        const collision_stats = self.collision;
        const collision_response_stats = self.collision_response;

        perf.recordMetric(.scope_total_entities, metric(scope_stats.total_entities));
        perf.recordMetric(.scope_dormant_entities, metric(scope_stats.dormant_entities));
        perf.recordMetric(.scope_kinematic_entities, metric(scope_stats.kinematic_entities));
        perf.recordMetric(.scope_locomotion_entities, metric(scope_stats.locomotion_entities));
        perf.recordMetric(.scope_cognition_entities, metric(scope_stats.cognition_entities));
        perf.recordMetric(.scope_movement_stage_entities, metric(scope_stats.movement_stage_entities));
        perf.recordMetric(.scope_collision_stage_entities, metric(scope_stats.collision_stage_entities));
        perf.recordMetric(.scope_collision_response_stage_entities, metric(scope_stats.collision_response_stage_entities));
        perf.recordMetric(.scope_ai_stage_entities, metric(scope_stats.ai_stage_entities));
        perf.recordMetric(.scope_steering_stage_entities, metric(scope_stats.steering_stage_entities));
        perf.recordMetric(.scope_stagger_skips, metric(scope_stats.stagger_skips));
        perf.recordMetric(.scope_chunk_filtered_entities, metric(scope_stats.chunk_filtered_entities));

        perf.recordBatch(.spatial_index_build, spatial_index_stats.batch);

        perf.recordMetric(.ai_entities, metric(ai_stats.entity_count));
        perf.recordMetric(.ai_intents, metric(ai_stats.intent_count));
        perf.recordMetric(.ai_navigation_intents, metric(ai_stats.navigation_intent_count));
        perf.recordMetric(.ai_separation_candidate_checks, metric(ai_stats.separation_candidate_checks));
        perf.recordMetric(.ai_separation_neighbor_samples, metric(ai_stats.separation_neighbor_samples));
        perf.recordBatch(.ai_separation, ai_stats.separation_batch);
        perf.recordBatch(.ai_intent, ai_stats.intent_batch);

        perf.recordMetric(.steering_navigation_intents, metric(steering_stats.navigation_intent_count));
        perf.recordMetric(.steering_selected_intents, metric(steering_stats.selected_intent_count));
        perf.recordMetric(.steering_movement_intents, metric(steering_stats.movement_intent_count));
        perf.recordMetric(.steering_path_requests, metric(steering_stats.path_request_count));
        perf.recordMetric(.steering_paths_available, metric(steering_stats.path_available_count));
        perf.recordMetric(.steering_paths_pending, metric(steering_stats.path_pending_count));
        perf.recordMetric(.steering_paths_unavailable, metric(steering_stats.path_unavailable_count));
        perf.recordMetric(.steering_replan_cooldowns, metric(steering_stats.replan_cooldown_count));
        perf.recordMetric(.steering_unavailable_backoffs, metric(steering_stats.unavailable_backoff_count));
        perf.recordMetric(.steering_stuck_replans, metric(steering_stats.stuck_replan_count));
        perf.recordMetric(.steering_agent_neighbor_samples, metric(steering_stats.agent_neighbor_samples));
        perf.recordMetric(.steering_obstacle_samples, metric(steering_stats.obstacle_samples));
        perf.recordMetric(.steering_agent_candidate_checks, metric(steering_stats.agent_candidate_checks));
        perf.recordMetric(.steering_obstacle_candidate_checks, metric(steering_stats.obstacle_candidate_checks));
        perf.recordBatch(.steering, steering_stats.batch);

        perf.recordMetric(.path_accepted_requests, metric(pathfinding_stats.accepted_requests));
        perf.recordMetric(.path_duplicate_requests, metric(pathfinding_stats.duplicate_requests));
        perf.recordMetric(.path_pending_requests, metric(pathfinding_stats.pending_requests));
        perf.recordMetric(.path_solved_requests, metric(pathfinding_stats.solved_requests));
        perf.recordMetric(.path_fallback_requests, metric(pathfinding_stats.fallback_requests));
        perf.recordMetric(.path_available_results, metric(pathfinding_stats.available_results));
        perf.recordMetric(.path_unavailable_results, metric(pathfinding_stats.unavailable_results));
        perf.recordMetric(.path_dropped_requests, metric(pathfinding_stats.dropped_requests));
        perf.recordMetric(.path_deferred_requests, metric(pathfinding_stats.deferred_requests));
        perf.recordMetric(.path_fallback_deferred_requests, metric(pathfinding_stats.fallback_deferred_requests));
        perf.recordMetric(.path_cache_hits, metric(pathfinding_stats.cache_hits));
        perf.recordMetric(.path_cache_evictions, metric(pathfinding_stats.cache_evictions));
        perf.recordMetric(.path_budget_exhausted, metric(pathfinding_stats.budget_exhausted));
        perf.recordMetric(.path_goal_projected, metric(pathfinding_stats.goal_projected));
        perf.recordMetric(.path_group_fields_built, metric(pathfinding_stats.group_fields_built));
        perf.recordMetric(.path_group_field_reuses, metric(pathfinding_stats.group_field_reuses));
        perf.recordMetric(.path_group_field_rebuild_throttled, metric(pathfinding_stats.group_field_rebuild_throttled));
        perf.recordMetric(.path_group_field_samples, metric(pathfinding_stats.group_field_samples));
        perf.recordBatch(.path_fallback, pathfinding_stats.fallback_batch);
        perf.recordTiming(.pathfinding_accept, pathfinding_stats.accept_ns);
        perf.recordTiming(.pathfinding_group_service, pathfinding_stats.group_service_ns);
        perf.recordTiming(.pathfinding_solve, pathfinding_stats.solve_ns);
        perf.recordTiming(.pathfinding_publish, pathfinding_stats.publish_ns);

        perf.recordMetric(.movement_bodies, metric(movement_stats.body_count));
        perf.recordBatch(.movement, movement_stats.batch);

        perf.recordMetric(.collision_bodies, metric(collision_stats.body_count));
        perf.recordMetric(.collision_candidate_pairs, metric(collision_stats.candidate_pair_count));
        perf.recordMetric(.collision_contacts, metric(collision_stats.contact_count));
        perf.recordMetric(.collision_broadphase_simd_groups, metric(collision_stats.broadphase_simd_groups));
        if (collision_stats.used_full_sort) perf.recordMetric(.collision_full_sorts, 1);
        perf.recordBatch(.collision_broadphase, collision_stats.broadphase_batch);
        perf.recordBatch(.collision_narrowphase, collision_stats.narrowphase_batch);

        perf.recordMetric(.collision_response_contacts, metric(collision_response_stats.contact_count));
        perf.recordMetric(.collision_response_intents, metric(collision_response_stats.intent_count));
        perf.recordMetric(.collision_response_triggers, metric(collision_response_stats.trigger_count));
    }
};

fn metric(value: usize) u64 {
    return @intCast(value);
}

/// Fixed-step simulation owner for one gameplay state instance.
/// This owns reusable systems and concrete stage order; it is not a global
/// scheduler, registry, or callback-driven dependency graph.
pub const SimulationPipeline = struct {
    movement: MovementSystem,
    collision: CollisionSystem,
    collision_response: CollisionResponseSystem,
    ai: AiSystem,
    steering: SteeringSystem,
    pathfinding: PathfindingSystem,
    /// Backbone scope system: recomputes chunks, gates AI/movement/collision by
    /// tier + camera cognition halo + stagger, and drives auto tier wake/sleep.
    scope: SimulationScopeSystem,
    /// Shared per-step spatial index (Slice 28), built once from the same
    /// cognition-scoped population the scope system selects for AI. AI
    /// separation queries it read-only; future perception stages reuse it too.
    spatial_index: SpatialIndexSystem,
    /// AI perception substrate (Slice 29): queries the shared spatial index for
    /// hostile candidates within vision/FOV/line-of-sight and writes sensed
    /// state to `PerceptionStore` for the cognition-scoped `AiPerception` subset.
    perception: PerceptionSystem,
    /// AI short-term memory: decays staleness/familiarity/ring contacts for the
    /// cognition-scoped `AiPerception` + `AiMemory` subset and refreshes from
    /// this step's perception acquisition events, feeding `AiSystem`'s
    /// memory-aware cold-seek retarget.
    ai_memory: AiMemorySystem,
    /// Emotion-drive appraisal (fear/curiosity/aggression/fatigue): appraises
    /// this step's just-refreshed `AiPerception`/`AiMemory` state (both
    /// optional per row) plus each agent's own `AiAgent.behavior` into the
    /// cognition-scoped `AiAffect` subset. A future arbitration slice reads
    /// the resulting drives; this stage only appraises and decays them.
    affect: AffectSystem,
    dig: DigController,
    audio_controller: AudioController,
    nav_cell_size: f32,
    stage_trace: StageTrace = .{},
    /// See `SimulationPipelineConfig.perception_max_events_per_step`.
    perception_max_events_per_step: usize,
    /// See `SimulationPipelineConfig.affect_max_events_per_step`.
    affect_max_events_per_step: usize,

    /// Initializes owned systems, reserves their cold capacities, and builds
    /// the current static navigation grid from the state-owned `DataSystem`.
    pub fn init(
        allocator: std.mem.Allocator,
        data: *const DataSystem,
        bounds_width: f32,
        bounds_height: f32,
        config: SimulationPipelineConfig,
    ) !SimulationPipeline {
        var ai = AiSystem.init(allocator);
        errdefer ai.deinit();
        var steering = SteeringSystem.init(allocator);
        errdefer steering.deinit();
        try steering.reserveForCapacity(config.steering_agent_capacity, config.static_obstacle_capacity);
        var pathfinding = PathfindingSystem.init(allocator);
        errdefer pathfinding.deinit();
        try pathfinding.reserve(config.pathfinding);
        try pathfinding.rebuildStaticNavGridWithWorld(data, config.navigation_world, bounds_width, bounds_height, config.nav_cell_size, config.nav_build_thread_system);
        var collision = CollisionSystem.init(allocator);
        errdefer collision.deinit();
        var collision_response = CollisionResponseSystem.init(allocator);
        errdefer collision_response.deinit();
        try collision_response.reserveForContacts(config.contact_capacity);
        var scope = SimulationScopeSystem.init(allocator);
        errdefer scope.deinit();
        try scope.reserve(config.movement_body_capacity);
        var spatial_index = SpatialIndexSystem.init(allocator);
        errdefer spatial_index.deinit();
        try spatial_index.reserve(config.movement_body_capacity);
        // No reserve method: PerceptionSystem lazily ensureTotalCapacity's its
        // gather buffers on first use, same as AiSystem.
        var perception = PerceptionSystem.init(allocator);
        errdefer perception.deinit();
        // No reserve method: AiMemorySystem lazily ensureTotalCapacity's its
        // gather buffer on first use, same as PerceptionSystem/AiSystem.
        var ai_memory = AiMemorySystem.init(allocator);
        errdefer ai_memory.deinit();
        // No reserve method: AffectSystem lazily ensureTotalCapacity's its
        // gather buffer on first use, same as AiMemorySystem/PerceptionSystem.
        var affect = AffectSystem.init(allocator);
        errdefer affect.deinit();

        return .{
            .movement = MovementSystem.init(),
            .collision = collision,
            .collision_response = collision_response,
            .ai = ai,
            .steering = steering,
            .pathfinding = pathfinding,
            .scope = scope,
            .spatial_index = spatial_index,
            .perception = perception,
            .ai_memory = ai_memory,
            .affect = affect,
            .dig = DigController.init(config.dig),
            .audio_controller = AudioController.init(),
            .nav_cell_size = config.nav_cell_size,
            .perception_max_events_per_step = config.perception_max_events_per_step,
            .affect_max_events_per_step = config.affect_max_events_per_step,
        };
    }

    /// Releases owned processor/controller state. Borrowed gameplay data and
    /// frame storage stay owned by the gameplay state.
    pub fn deinit(self: *SimulationPipeline) void {
        self.affect.deinit();
        self.ai_memory.deinit();
        self.perception.deinit();
        self.spatial_index.deinit();
        self.scope.deinit();
        self.pathfinding.deinit();
        self.steering.deinit();
        self.ai.deinit();
        self.collision_response.deinit();
        self.collision.deinit();
        self.* = undefined;
    }

    /// Rebuilds the state-local static navigation grid after committed domain
    /// changes invalidate obstacle occupancy.
    pub fn rebuildStaticNavigation(
        self: *SimulationPipeline,
        data: *const DataSystem,
        bounds_width: f32,
        bounds_height: f32,
    ) !void {
        try self.pathfinding.rebuildStaticNavGrid(data, bounds_width, bounds_height, self.nav_cell_size);
    }

    pub fn rebuildStaticNavigationWithWorld(
        self: *SimulationPipeline,
        data: *const DataSystem,
        world: *const WorldSystem,
        bounds_width: f32,
        bounds_height: f32,
    ) !void {
        try self.pathfinding.rebuildStaticNavGridWithWorld(data, world, bounds_width, bounds_height, self.nav_cell_size, null);
    }

    /// Clears the pathfinding system's dirty nav-cell buffer. Call once before a step's
    /// marking pass so a skipped apply never leaks stale edits into the next step.
    pub fn clearNavDirty(self: *SimulationPipeline) void {
        self.pathfinding.clearNavDirty();
    }

    /// Records one changed nav cell (from a structural event) for the next incremental
    /// update. The system-owned buffer grows rather than drops, so any number of edits in
    /// one step reach the nav graph.
    pub fn markNavDirty(self: *SimulationPipeline, level: u16, x: u16, y: u16) !void {
        try self.pathfinding.markNavDirty(level, x, y);
    }

    /// Marks a whole level for re-derivation next update, for changes that cannot be reduced to
    /// specific cells (e.g. a destroyed static obstacle whose nav cell is no longer resolvable).
    pub fn markNavLevelDirty(self: *SimulationPipeline, level: u16) !void {
        try self.pathfinding.markNavLevelDirty(level);
    }

    /// Whether any dirty nav cell or whole-level request is buffered for this step.
    pub fn hasPendingNavUpdates(self: *const SimulationPipeline) bool {
        return self.pathfinding.hasPendingNavUpdates();
    }

    /// Folds the buffered static-obstacle edits into the existing nav graph incrementally
    /// (affected levels only, single `nav_version` bump) rather than rebuilding the whole
    /// world, then clears the buffer. The whole-world build path stays init-only.
    pub fn applyNavUpdates(
        self: *SimulationPipeline,
        data: *const DataSystem,
        world: *const WorldSystem,
        thread_system: ?*ThreadSystem,
    ) !NavUpdateStats {
        return self.pathfinding.applyBufferedNavUpdates(data, world, thread_system);
    }

    /// Orchestrates the post-commit nav reaction by delegating to the nav-owning
    /// `PathfindingSystem`, which interprets nav-invalidating events into dirty
    /// cells, applies the incremental update, and emits the invalidation event.
    pub fn reactToPostCommitNavEvents(
        self: *SimulationPipeline,
        frame: *SimulationFrame,
        data: *const DataSystem,
        world: *const WorldSystem,
        thread_system: ?*ThreadSystem,
    ) !NavUpdateStats {
        return self.pathfinding.reactToPostCommitNavEvents(frame, data, world, thread_system);
    }

    /// Orchestrates the post-commit perception-cache reaction by delegating to
    /// the cache-owning `PerceptionSystem`, which records localized dirty
    /// rects for its LOS-blocked bitmap cache from the same committed events
    /// `reactToPostCommitNavEvents` reacts to — a fully independent side
    /// effect on disjoint state, so call order between the two does not
    /// matter.
    pub fn reactToPostCommitPerceptionEvents(
        self: *SimulationPipeline,
        frame: *SimulationFrame,
        world: *const WorldSystem,
    ) !void {
        return self.perception.reactToPostCommitPerceptionEvents(frame, world);
    }

    /// Whether any pending structural command may invalidate navigation once
    /// applied. Delegates to `PathfindingSystem`; used for the pre-commit event
    /// capacity preflight.
    pub fn structuralCommandsMayInvalidateNavigation(data: *const DataSystem, frame: *const SimulationFrame) bool {
        return PathfindingSystem.structuralCommandsMayInvalidateNavigation(data, frame);
    }

    /// Whether any queued structural-commit event will drive a nav invalidation.
    pub fn pendingEventsMayInvalidateNavigation(frame: *const SimulationFrame) bool {
        return PathfindingSystem.pendingEventsMayInvalidateNavigation(frame);
    }

    /// Queues ambient audio (music + movement-gated jet loop) through the owned
    /// audio controller. Buffer/input/data are borrowed; the controller owns the
    /// audio-policy runtime state.
    pub fn queueAmbientAudio(self: *SimulationPipeline, audio: *AudioCommandBuffer, input: *const InputState, data: *const DataSystem, player: Player) void {
        self.audio_controller.queueAmbient(audio, input, data, player);
    }

    /// Queues collision SFX for this step's contacts through the owned audio controller.
    pub fn queueCollisionAudio(self: *SimulationPipeline, audio: *AudioCommandBuffer, frame: *const SimulationFrame, data: *const DataSystem, delta_seconds: f32) void {
        self.audio_controller.queueCollision(audio, frame, data, delta_seconds);
    }

    /// Flags the active jet loop to stop on resume (no command buffer at pause time).
    pub fn pauseAudio(self: *SimulationPipeline) void {
        self.audio_controller.onPause();
    }

    /// Captures this step's dig intent from held input through the owned dig
    /// controller. Called in the main-thread input phase, before `update`.
    pub fn captureDigIntent(self: *SimulationPipeline, input: *const InputState, frame: *SimulationFrame) void {
        self.dig.captureIntent(input, frame);
    }

    /// Synchronizes interpolation history for pipeline-owned movement state.
    /// State-owned visual effects still synchronize at their own owner.
    pub fn syncPreviousPositions(self: *SimulationPipeline, data: *DataSystem) void {
        var movement_slice = data.movementBodySlice();
        self.movement.syncPreviousPositions(&movement_slice);
    }

    /// Test-only: the stage order `update()` actually ran this step, for
    /// asserting it matches the declared `stage_order` contract.
    fn debugStageOrder(self: *const SimulationPipeline) []const StageId {
        return self.stage_trace.slice();
    }

    /// Runs the current full-active fixed-step stage order and returns stage
    /// stats. Real scoped filtering is intentionally deferred until world/chunk
    /// visibility data exists.
    pub fn update(self: *SimulationPipeline, context: SimulationPipelineUpdateContext) !SimulationPipelineStats {
        const data = context.data;
        const frame = context.frame;

        self.stage_trace = .{};
        frame.phase = .processors;
        // Player-authored world edit. Runs first; its world_tile_changed event is
        // deferred and re-masks navigation in merge_outputs regardless of order.
        self.stage_trace.mark(.dig_world_edit);
        try self.dig.process(context.world, data, context.player.*, frame);

        // Backbone scope pass. Advance the stagger clock, derive the camera
        // cognition halo, and select the cognition (AI/steering) subset for this
        // step. Chunk maintenance is folded into movement (below), which derives
        // each integrated body's chunk in-pass — exact every step at any speed, no
        // separate recompute. The AI gather reads the chunk movement wrote last
        // step (the body's current pre-move cell). Movement/collision gate on tier
        // only (no chunk filter), so they keep running off-screen; cognition gates
        // on the halo + stagger.
        self.stage_trace.mark(.scope_advance_and_ai_gather);
        self.scope.advanceStep();
        const cognition_region: ?ActiveRegion = context.world.cognitionActiveRegion(cognition_halo_chunks);
        const stagger_step = self.scope.staggerStep();
        const ai_indices = (try self.scope.gatherAiAgentIndices(data, cognition_region, stagger_step, context.thread_system, .{})).indices;

        const ai_slice = data.aiAgentSliceConst();
        const move_slice = data.movementBodySliceConst();

        // Shared spatial index (Slice 28): built once from the same cognition-scoped
        // population, from the same prior positions AI's own gather reads, so index
        // row `i` and AiSystem row `i` refer to the same agent (see spatial_index.zig
        // and ai.zig's cross-file population-domain contract). AI separation queries
        // it read-only below; future perception stages will reuse it too.
        self.stage_trace.mark(.spatial_index_build);
        var spatial_index_timer = StageTimer.start();
        const spatial_index_stats = try self.spatial_index.build(ai_slice, move_slice, data, context.thread_system, .{ .scope_dense_indices = ai_indices });
        spatial_index_timer.stop(context.perf, .pipeline_spatial_index);

        // Perception substrate (Slice 29): queries the just-built spatial index
        // for hostile candidates within vision/FOV/line-of-sight, over the same
        // cognition-scoped `ai_indices` population, writing sensed state to
        // `PerceptionStore` before AI reads it. The player is folded in as an
        // extra hostile candidate alongside spatial-index neighbors.
        const perception_player_candidate: ?PlayerPerceptionCandidate = if (data.movementBodyConst(context.player.entity)) |pbody|
            .{
                .entity = context.player.entity,
                .pos_x = pbody.previous_position.x,
                .pos_y = pbody.previous_position.y,
                .faction = data.factionConst(context.player.entity) orelse .neutral,
                .level = context.player.current_level,
            }
        else
            null;

        self.stage_trace.mark(.perception_update);
        var perception_timer = StageTimer.start();
        const perception_stats = try self.perception.update(ai_slice, move_slice, self.spatial_index.view(), context.world, data, &frame.events, context.thread_system, .{
            .scope_dense_indices = ai_indices,
            .player_candidate = perception_player_candidate,
            .stimuli = frame.stimuli.mergedItems(),
            .max_events_per_step = self.perception_max_events_per_step,
        });
        perception_timer.stop(context.perf, .pipeline_perception);

        // Decays staleness/familiarity/ring contacts and refreshes from this
        // step's perception acquisition events, over the same cognition-scoped
        // `ai_indices` population, before AI reads it for the cold-seek
        // retarget below.
        self.stage_trace.mark(.ai_memory_update);
        var ai_memory_timer = StageTimer.start();
        const ai_memory_stats = try self.ai_memory.update(ai_slice, data, frame, context.thread_system, .{
            .scope_dense_indices = ai_indices,
        });
        ai_memory_timer.stop(context.perf, .pipeline_ai_memory);

        // Appraises this step's just-written perception + memory state into
        // fear/curiosity/aggression/fatigue, over the same cognition-scoped
        // `ai_indices` population. Must run after both perception and
        // ai_memory (it reads their this-step hot columns) and before
        // AI/arbitration would read the resulting drives -- arbitration does
        // not exist yet, this is a forward seam only, not implemented here.
        self.stage_trace.mark(.affect_update);
        var affect_timer = StageTimer.start();
        const affect_stats = try self.affect.update(ai_slice, data, &frame.events, context.thread_system, .{
            .scope_dense_indices = ai_indices,
            .max_events_per_step = self.affect_max_events_per_step,
        });
        affect_timer.stop(context.perf, .pipeline_ai_affect);

        // The player's plane is deliberately NOT propagated into the AI goal level:
        // NPCs stay on the surface (goal_level 0) until autonomous descent lands.
        // Seeding the player's underground plane here would make them request
        // cross-level paths they cannot walk (start_level is pinned to 0), piling
        // them at the ramp mouth. They simply seek the (x,y) above the player.
        const player_target = if (data.movementBodyConst(context.player.entity)) |pbody|
            pbody.previous_position
        else
            math.Vec2{ .x = 400, .y = 225 };

        self.stage_trace.mark(.ai_decide);
        var ai_timer = StageTimer.start();
        const ai_stats = try self.ai.update(ai_slice, move_slice, self.spatial_index.view(), data, frame, context.thread_system, context.delta_seconds, .{
            .intent_seed = 0xfeedf00d,
            .step = self.scope.currentStep(),
            .seek_target = player_target,
            // Every demo agent seeks the moving player: the canonical shared goal.
            // Declaring group mode routes them through one managed flow field
            // toward the player's nav cell instead of N individual A* solves.
            .nav_request_kind = .group,
            .navigation_intents = &frame.navigation_intents,
            // Cognition halo + stagger selection. Steering inherits this scope
            // transitively: it only acts on the navigation intents AI emits here.
            .scope_dense_indices = ai_indices,
            // Cold-perception agents with fresh memory retarget seek toward
            // their last-known position instead of losing the goal.
            .perception_slice = data.aiPerceptionSliceConst(),
            .memory_slice = data.aiMemorySliceConst(),
        });
        ai_timer.stop(context.perf, .pipeline_ai);

        self.stage_trace.mark(.steering_update);
        var steering_timer = StageTimer.start();
        const steering_stats = try self.steering.update(data, frame, context.thread_system, &self.pathfinding, .{});
        steering_timer.stop(context.perf, .pipeline_steering);

        self.stage_trace.mark(.pathfinding_update);
        var pathfinding_timer = StageTimer.start();
        // Drive elastic pathfinding capacity off the live steering-agent crowd (the
        // entities that consume paths), so pools grow for battles and shrink after.
        const path_agent_count = data.steeringAgentSliceConst().entities.len;
        const pathfinding_stats = try self.pathfinding.update(&frame.path_requests, path_agent_count, context.thread_system, .{});
        pathfinding_timer.stop(context.perf, .pipeline_pathfinding);

        self.stage_trace.mark(.apply_ai_movement_intents);
        var apply_intents_timer = StageTimer.start();
        applyAiMovementIntents(data, frame);
        apply_intents_timer.stop(context.perf, .pipeline_apply_intents);

        // Movement gates on tier only (no chunk filter): every non-dormant entity
        // integrates, on- or off-screen. Null = full-active warm SIMD range. Movement
        // also derives each integrated body's chunk in-pass via chunk_grid, so chunk
        // stays exact every step with no separate recompute.
        self.stage_trace.mark(.movement_scope_gather);
        const movement_scope_indices = (try self.scope.gatherMovementBodyIndices(data, context.thread_system, .{})).indices;
        const scope_columns = data.scopeColumnsSlice();
        var movement_slice = data.movementBodySlice();
        self.stage_trace.mark(.movement_integrate);
        var movement_timer = StageTimer.start();
        const movement_stats = self.movement.update(&movement_slice, context.thread_system, context.delta_seconds, .{
            .scope_dense_indices = movement_scope_indices,
            .chunk_grid = .{
                .chunk_x = scope_columns.chunk_x,
                .chunk_y = scope_columns.chunk_y,
                .tile_size = context.world.tile_size,
                .chunk_size_tiles = context.world.chunk_size_tiles,
                .width = context.world.width,
                .height = context.world.height,
            },
        });
        movement_timer.stop(context.perf, .pipeline_movement);

        self.stage_trace.mark(.bounds_and_tile_gate);
        var clamp_timer = StageTimer.start();
        clampAiEntitiesToBounds(data, context.bounds_width, context.bounds_height);
        try context.player.clampToBounds(data, context.bounds_width, context.bounds_height);
        // Gate the player against solid world tiles on their current plane (mining:
        // underground dirt is solid until dug). Runs after the bounds clamp and
        // before entity collision so downstream stages see the gated position. NPCs
        // are gated the same way right below, skipping only dormant-tier NPCs
        // (they don't move this step, so gating them would be dead work).
        gatePlayerToWalkableTiles(context.world, data, context.player.*);
        gateNpcEntitiesToWalkableTiles(context.world, data);
        clamp_timer.stop(context.perf, .pipeline_clamp_bounds);

        // Collision also gates on tier only (no chunk filter): off-screen entities
        // keep colliding with geometry. Null = full-active.
        self.stage_trace.mark(.collision_scope_gather);
        const collision_scope_indices = (try self.scope.gatherCollisionBoundsIndices(data, context.thread_system, .{})).indices;
        self.stage_trace.mark(.collision_detect);
        var collision_timer = StageTimer.start();
        const collision_stats = try self.collision.update(data, &frame.contacts, context.thread_system, .{
            .scope_dense_indices = collision_scope_indices,
        });
        collision_timer.stop(context.perf, .pipeline_collision);

        self.stage_trace.mark(.collision_respond);
        var collision_response_timer = StageTimer.start();
        const collision_response_stats = try self.collision_response.update(data, frame);
        collision_response_timer.stop(context.perf, .pipeline_collision_response);

        // After movement/collision settle positions, update planes: follow a ramp
        // on cell entry, fall one level per step when standing over a hole. Both
        // the player and NPCs route through `DigController.applyEntityPlaneTraversal`
        // so falls carve their landing cell identically; a fall's tile change
        // re-masks navigation post-commit.
        self.stage_trace.mark(.plane_traversal);
        try self.dig.applyPlaneTraversal(context.world, data, context.player, frame);
        try applyNpcPlaneTraversal(&self.dig, context.world, data, frame);

        // Simulation-LOD tier policy: each entity is assigned cognition/locomotion/
        // kinematic/dormant by its cube distance from the visible region, applied
        // via deferred structural commands on the frame stream for the commit seam.
        // Uses the raw visible region (not the cognition halo) so all four bands
        // are measured from the same origin, anchored at the camera/player level so
        // off-level entities demote. Queues nothing when no tier changed.
        self.stage_trace.mark(.tier_policy);
        var visible_region = context.world.visibleChunkRegion();
        if (visible_region) |*region| region.level = context.player.current_level;
        _ = try self.scope.queueTierChanges(data, visible_region, &frame.structural_commands, context.thread_system, .{});

        const scope = self.buildScopeStats(
            data,
            cognition_region,
            ai_indices,
            movement_scope_indices,
            collision_scope_indices,
            steering_stats,
        );

        return .{
            .scope = scope,
            .spatial_index = spatial_index_stats,
            .perception = perception_stats,
            .ai_memory = ai_memory_stats,
            .affect = affect_stats,
            .ai = ai_stats,
            .steering = steering_stats,
            .pathfinding = pathfinding_stats,
            .movement = movement_stats,
            .collision = collision_stats,
            .collision_response = collision_response_stats,
        };
    }

    /// Builds the per-step scope stats: tier histograms and full-active baselines
    /// from `DataSystem`, with stage entity counts overridden to the actually-scoped
    /// participation and the stagger/chunk-filter counters from this step.
    fn buildScopeStats(
        self: *const SimulationPipeline,
        data: *const DataSystem,
        cognition_region: ?ActiveRegion,
        ai_indices: []const u32,
        movement_scope_indices: ?[]const u32,
        collision_scope_indices: ?[]const u32,
        steering_stats: SteeringStats,
    ) SimulationScope {
        var stats = data.simulationScopeStatsFullActive();
        stats.ai_stage_entities = ai_indices.len;
        // Steering is transitively scoped via AI's intents; its real participation
        // is the count of movement intents it actually emitted this step.
        stats.steering_stage_entities = steering_stats.movement_intent_count;
        if (movement_scope_indices) |idx| stats.movement_stage_entities = idx.len;
        if (collision_scope_indices) |idx| stats.collision_stage_entities = idx.len;
        stats.stagger_skips = self.scope.stagger_skips;
        stats.chunk_filtered_entities = self.scope.chunk_filtered_entities;
        return .{ .active_region = cognition_region, .stats = stats };
    }
};

/// Comptime-gated wall-clock timer for one pipeline stage. When perf logging
/// is disabled it is a zero-field, zero-cost no-op; when enabled it samples the
/// SDL nanosecond clock and forwards the duration to the bound perf context.
const StageTimer = if (runtime_perf_log.enabled) struct {
    start_ns: u64,

    fn start() StageTimer {
        return .{ .start_ns = c.SDL_GetTicksNS() };
    }

    fn stop(self: StageTimer, perf: runtime_perf_log.Context, timing: runtime_perf_log.Timing) void {
        const end_ns = c.SDL_GetTicksNS();
        perf.recordTiming(timing, if (end_ns > self.start_ns) end_ns - self.start_ns else 0);
    }
} else struct {
    fn start() StageTimer {
        return .{};
    }

    fn stop(_: StageTimer, _: runtime_perf_log.Context, _: runtime_perf_log.Timing) void {}
};

fn applyAiMovementIntents(data: *DataSystem, frame: *const SimulationFrame) void {
    for (frame.intents.mergedItems()) |item| {
        if (item != .movement) continue;
        const movement_intent = item.movement;
        if (!data.isAlive(movement_intent.entity)) continue;
        if (data.aiAgentConst(movement_intent.entity) == null) continue;
        if (data.movementBodyPtr(movement_intent.entity)) |body| {
            const speed = if (body.speed.* > 0) body.speed.* else 40.0;
            body.velocity_x.* = movement_intent.direction_x * speed;
            body.velocity_y.* = movement_intent.direction_y * speed;
        }
    }
}

/// Stops one body from moving into solid world tiles on `level`. No-op on level 0
/// (the surface is fully walkable and pre-existing decos/water are intentionally
/// pass-through there). Resolves X then Y independently against the pre-move
/// position so a diagonal push into a wall slides along it. The body is one tile
/// wide; sampling the four AABB corners (with an epsilon so a flush right/bottom
/// edge stays in the covered cell) is exact for the sub-tile motion this produces.
/// Allocation-free, single entity, scalar. Shared by the player and NPC gates.
fn gateBodyToWalkableTiles(world: *const WorldSystem, level: u16, body: MovementBodyPtr, visual: PrimitiveVisual) void {
    if (level == 0) return;
    const w = visual.size.x;
    const h = visual.size.y;
    const pre_x = body.previous_x.*;
    const pre_y = body.previous_y.*;
    const post_x = body.position_x.*;
    const post_y = body.position_y.*;

    var resolved_x = post_x;
    if (rectOverlapsSolidTile(world, level, post_x, pre_y, w, h)) resolved_x = pre_x;
    var resolved_y = post_y;
    if (rectOverlapsSolidTile(world, level, resolved_x, post_y, w, h)) resolved_y = pre_y;

    if (resolved_x != post_x) body.velocity_x.* = 0;
    if (resolved_y != post_y) body.velocity_y.* = 0;
    body.position_x.* = resolved_x;
    body.position_y.* = resolved_y;
}

fn gateNpcEntitiesToWalkableTiles(world: *const WorldSystem, data: *DataSystem) void {
    const ai_slice = data.aiAgentSliceConst();
    const scope_columns = data.scopeColumnsSliceConst();
    for (ai_slice.entities) |entity| {
        // Dormant NPCs never move this step (movement itself skips writing their
        // position), so gating them against world tiles is dead work — skip.
        if (data.movementBodyDenseIndex(entity)) |dense_index| {
            if (!scope_columns.tier[dense_index].allowsMovement()) continue;
        }
        const level = data.worldLevelConst(entity) orelse 0;
        const body = data.movementBodyPtr(entity) orelse continue;
        const visual = data.primitiveVisualConst(entity) orelse continue;
        gateBodyToWalkableTiles(world, level, body, visual);
    }
}

/// Updates NPC planes after movement using per-entity cell-entry guards derived
/// from previous vs. current body centers (no stored `last_cell` needed, unlike
/// the player, since the movement body already tracks both positions). Delegates
/// the actual ramp/fall/carve/snap logic to `DigController.applyEntityPlaneTraversal`
/// so NPCs get the same landing-cell carve as the player instead of a hand-rolled
/// copy that could (and did) drift out of sync. Dormant-tier NPCs are skipped:
/// movement never moves them this step, so they can't have entered a new cell.
fn applyNpcPlaneTraversal(dig: *DigController, world: *WorldSystem, data: *DataSystem, frame: *SimulationFrame) !void {
    const ai_slice = data.aiAgentSliceConst();
    const scope_columns = data.scopeColumnsSliceConst();
    for (ai_slice.entities) |entity| {
        if (data.movementBodyDenseIndex(entity)) |dense_index| {
            if (!scope_columns.tier[dense_index].allowsMovement()) continue;
        }
        const level = data.worldLevelConst(entity) orelse continue;
        const body = data.movementBodyPtr(entity) orelse continue;
        const visual = data.primitiveVisualConst(entity) orelse continue;
        const prev_center_x = body.previous_x.* + visual.size.x * 0.5;
        const prev_center_y = body.previous_y.* + visual.size.y * 0.5;
        const center_x = body.position_x.* + visual.size.x * 0.5;
        const center_y = body.position_y.* + visual.size.y * 0.5;
        const prev_cell = world.cellContaining(prev_center_x, prev_center_y) orelse continue;
        const cell = world.cellContaining(center_x, center_y) orelse continue;
        if (prev_cell.x == cell.x and prev_cell.y == cell.y) continue;

        _ = try dig.applyEntityPlaneTraversal(world, data, frame, entity, level, CellCoord{ .x = cell.x, .y = cell.y });
    }
}

fn gatePlayerToWalkableTiles(world: *const WorldSystem, data: *DataSystem, player: Player) void {
    const body = data.movementBodyPtr(player.entity) orelse return;
    const visual = data.primitiveVisualConst(player.entity) orelse return;
    gateBodyToWalkableTiles(world, player.current_level, body, visual);
}

/// Whether an axis-aligned body rect overlaps any movement-blocking tile on `level`.
/// Off-world corners read as blocked (fail-closed), matching `levelBlocksMovement`.
fn rectOverlapsSolidTile(world: *const WorldSystem, level: u16, x: f32, y: f32, w: f32, h: f32) bool {
    const edge_epsilon: f32 = 0.5;
    const sample_xs = [_]f32{ x, x + w - edge_epsilon };
    const sample_ys = [_]f32{ y, y + h - edge_epsilon };
    for (sample_ys) |sy| {
        for (sample_xs) |sx| {
            const cell = world.cellContaining(sx, sy) orelse return true;
            if (world.levelBlocksMovement(level, cell.x, cell.y)) return true;
        }
    }
    return false;
}

fn clampAiEntitiesToBounds(data: *DataSystem, bounds_width: f32, bounds_height: f32) void {
    const ai_slice = data.aiAgentSliceConst();
    // Read only the size columns from the dense visual store rather than
    // rebuilding the whole PrimitiveVisual struct per AI entity each step.
    const visuals = data.primitiveVisualSliceConst();
    for (ai_slice.entities) |entity| {
        const body = data.movementBodyPtr(entity) orelse continue;
        const visual_index = data.primitiveVisualDenseIndex(entity) orelse continue;

        const max_x = bounds_width - visuals.size_x[visual_index];
        const new_x = math.clamp(body.position_x.*, 0, max_x);
        if (new_x != body.position_x.*) body.velocity_x.* = 0;
        body.position_x.* = new_x;

        const max_y = bounds_height - visuals.size_y[visual_index];
        const new_y = math.clamp(body.position_y.*, 0, max_y);
        if (new_y != body.position_y.*) body.velocity_y.* = 0;
        body.position_y.* = new_y;
    }
}

test "pipeline updates full active player-only state through serial path" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 2, 2, 4, 2, 2);
    try frame.reservePathRequests(2, 2);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .steering_agent_capacity = 0,
        .static_obstacle_capacity = 0,
        .contact_capacity = 4,
        .pathfinding = .{
            .max_frame_requests = 2,
            .max_pending_requests = 2,
            .max_cached_results = 4,
            .max_group_fields = 1,
            .worker_participant_count = 1,
            .max_solved_requests_per_step = 2,
            .max_fallback_requests_per_step = 2,
        },
    });
    defer pipeline.deinit();

    frame.beginStep();
    const stats = try pipeline.update(.{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 800,
        .bounds_height = 450,
    });

    try std.testing.expectEqual(@as(usize, 1), stats.scope.stats.total_entities);
    try std.testing.expectEqual(@as(usize, 1), stats.scope.stats.movement_stage_entities);
    try std.testing.expectEqual(@as(usize, 0), stats.ai.entity_count);
    try std.testing.expectEqual(@as(usize, 1), stats.movement.body_count);
    try std.testing.expectEqual(@as(usize, 0), frame.contacts.mergedItems().len);
}

test "pipeline stage order matches its declared ordering contract" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 2, 2, 4, 2, 2);
    try frame.reservePathRequests(2, 2);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .steering_agent_capacity = 0,
        .static_obstacle_capacity = 0,
        .contact_capacity = 4,
        .pathfinding = .{
            .max_frame_requests = 2,
            .max_pending_requests = 2,
            .max_cached_results = 4,
            .max_group_fields = 1,
            .worker_participant_count = 1,
            .max_solved_requests_per_step = 2,
            .max_fallback_requests_per_step = 2,
        },
    });
    defer pipeline.deinit();

    frame.beginStep();
    _ = try pipeline.update(.{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 800,
        .bounds_height = 450,
    });

    try std.testing.expectEqualSlices(StageId, &stage_order, pipeline.debugStageOrder());
}

test "pipeline resamples AI wander direction across fixed steps" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    const wanderer = try data.createEntity();
    try data.setMovementBody(wanderer, .{ .position = .{ .x = 10, .y = 10 }, .previous_position = .{ .x = 10, .y = 10 }, .velocity = .{}, .speed = 20 });
    try data.setAiAgent(wanderer, .{ .behavior = .wander, .wander_amplitude = 30, .seek_weight = 0 });

    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 2, 2, 4, 2, 2);
    try frame.reservePathRequests(2, 2);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .steering_agent_capacity = 0,
        .static_obstacle_capacity = 0,
        .contact_capacity = 4,
        .pathfinding = .{
            .max_frame_requests = 2,
            .max_pending_requests = 2,
            .max_cached_results = 4,
            .max_group_fields = 1,
            .worker_participant_count = 1,
            .max_solved_requests_per_step = 2,
            .max_fallback_requests_per_step = 2,
        },
    });
    defer pipeline.deinit();

    // A bare WorldSystem never gets a visibility window set, so
    // `cognitionActiveRegion()` returns null and the AI gather falls back to
    // full-active with no stagger gating — the wanderer runs every step.
    frame.beginStep();
    const stats1 = try pipeline.update(.{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 800,
        .bounds_height = 450,
    });
    try std.testing.expectEqual(@as(usize, 1), stats1.ai.entity_count);
    const step1 = frame.navigation_intents.mergedItems()[0];

    // Wander direction holds steady for `wander_resample_period_steps` (300
    // steps / 5s at 60Hz by default) before resampling, so cross a full
    // epoch boundary here rather than checking single-step deltas.
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        frame.beginStep();
        _ = try pipeline.update(.{
            .data = &data,
            .frame = &frame,
            .world = &world,
            .player = &player,
            .thread_system = &threads,
            .delta_seconds = 0.016,
            .bounds_width = 800,
            .bounds_height = 450,
        });
    }
    const step_after_epoch = frame.navigation_intents.mergedItems()[0];

    try std.testing.expect(step1.direct_direction_x != step_after_epoch.direct_direction_x or
        step1.direct_direction_y != step_after_epoch.direct_direction_y);
}

test "pipeline syncs movement previous positions" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{});
    defer pipeline.deinit();

    const body = data.movementBodyPtr(player.entity).?;
    body.position_x.* += 10;
    body.position_y.* += 5;
    pipeline.syncPreviousPositions(&data);

    const synced = data.movementBodyConst(player.entity).?;
    try std.testing.expectEqual(synced.position.x, synced.previous_position.x);
    try std.testing.expectEqual(synced.position.y, synced.previous_position.y);
}

test "pipeline runs ai_memory after perception and before ai, feeding memory into AI's cold-seek retarget" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data); // Spawns at (400, 225).

    const remembered_target = try data.createEntity();
    const agent = try data.createEntity();
    // Far outside the default AiPerception vision_range (240) from the
    // player, so the real PerceptionSystem pass this step reports the target
    // not visible regardless of hostility.
    try data.setMovementBody(agent, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(agent, .{ .behavior = .seek, .wander_amplitude = 0, .seek_weight = 1.0 });
    try data.setAiPerception(agent, .{});
    try data.setAiMemory(agent, .{
        .last_known_target = remembered_target,
        .last_known_x = 0,
        .last_known_y = 100,
        .staleness = 10,
    });

    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 2, 2, 4, 2, 2);
    try frame.reservePathRequests(2, 2);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .steering_agent_capacity = 0,
        .static_obstacle_capacity = 0,
        .contact_capacity = 4,
        .pathfinding = .{
            .max_frame_requests = 2,
            .max_pending_requests = 2,
            .max_cached_results = 4,
            .max_group_fields = 1,
            .worker_participant_count = 1,
            .max_solved_requests_per_step = 2,
            .max_fallback_requests_per_step = 2,
        },
    });
    defer pipeline.deinit();

    frame.beginStep();
    const stats = try pipeline.update(.{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 800,
        .bounds_height = 450,
    });

    // Both stages ran over the same scoped agent this step (observable stage
    // order: ai_memory processes after perception and before ai reads it).
    try std.testing.expectEqual(@as(usize, 1), stats.ai_memory.processed_count);
    try std.testing.expectEqual(@as(usize, 1), stats.ai.entity_count);

    // Perception never saw the player (out of vision range) and AiMemory's
    // fresh last-known position survived AiMemorySystem's decay, so AI's
    // per-row goal reflects the memory retarget (0, 100) rather than the
    // player's seek_target (400, 225) — the actual end-to-end proof that a
    // cold-perception agent retargets via memory through the real pipeline.
    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), intents.len);
    try std.testing.expectEqual(@as(f32, 0), intents[0].goal.x);
    try std.testing.expectEqual(@as(f32, 100), intents[0].goal.y);
}

test "pipeline runs affect after perception and ai_memory, before ai" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);

    // A close hostile puts this step's real PerceptionSystem pass into
    // target_visible=true with a small nearest_threat_dist, so affect's
    // fear/aggression must observe *this step's* freshly written perception
    // state (not a stale previous-step value) to move off baseline.
    const observer = try data.createEntity();
    try data.setMovementBody(observer, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 0 });
    try data.setAiAgent(observer, .{ .behavior = .wander, .seek_weight = 0 });
    try data.setFaction(observer, .player);
    try data.setAiPerception(observer, .{});
    try data.setAiAffect(observer, .{ .decay_rate_fear = 0.5, .decay_rate_aggression = 0.5 });

    const hostile = try data.createEntity();
    try data.setMovementBody(hostile, .{ .position = .{ .x = 10, .y = 0 }, .previous_position = .{ .x = 10, .y = 0 }, .velocity = .{}, .speed = 0 });
    try data.setAiAgent(hostile, .{ .behavior = .wander, .seek_weight = 0 });
    try data.setFaction(hostile, .hostile);

    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    // A level must exist or PerceptionSystem's LOS-blocked cache treats every
    // observer as fail-closed (blocked), never reporting a target visible.
    _ = try world.addLevel(0);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 4, 4, 4, 4, 4);
    try frame.reservePathRequests(2, 2);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .steering_agent_capacity = 0,
        .static_obstacle_capacity = 0,
        .contact_capacity = 4,
        .pathfinding = .{
            .max_frame_requests = 2,
            .max_pending_requests = 2,
            .max_cached_results = 4,
            .max_group_fields = 1,
            .worker_participant_count = 1,
            .max_solved_requests_per_step = 2,
            .max_fallback_requests_per_step = 2,
        },
    });
    defer pipeline.deinit();

    frame.beginStep();
    const stats = try pipeline.update(.{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 800,
        .bounds_height = 450,
    });

    // Both perception and affect ran this step over the observer (the only
    // entity carrying AiAffect); both agents (observer + hostile) reach AI.
    try std.testing.expectEqual(@as(usize, 1), stats.perception.observer_count);
    try std.testing.expectEqual(@as(usize, 1), stats.affect.processed_count);
    try std.testing.expectEqual(@as(usize, 2), stats.ai.entity_count);

    // Affect observed this step's perception output (hostile visible, close),
    // proving it ran after perception -- a stale/previous-step read would
    // have left fear/aggression at their zero default.
    const affect_after = data.aiAffectConst(observer).?;
    try std.testing.expect(affect_after.fear > 0);
    try std.testing.expect(affect_after.aggression > 0);
}

const AssetStore = @import("../assets/assets.zig").AssetStore;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");

// Builds a 3-level demo world and carves the two given level-1 cells walkable so a
// player body can sit in one and try to move into solid dirt around it.
fn gateTestWorld(meta: *const world_tileset_meta.WorldTilesetMeta, carve: []const [2]u16) !WorldSystem {
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, meta, 320, 320);
    errdefer world.deinit();
    try world.addUndergroundLevels(meta);
    const cave_0 = (meta.tileByName("cave_0") orelse return error.TestUnexpectedResult).id;
    const floor1 = world.denseFloorLayerForLevel(1).?;
    for (carve) |cell| {
        _ = try world.setDenseTile(floor1, cell[0], cell[1], cave_0);
    }
    return world;
}

fn placePlayerFlush(data: *DataSystem, player: Player, cell: [2]u16) void {
    const body = data.movementBodyPtr(player.entity).?;
    const x = @as(f32, @floatFromInt(cell[0])) * 32;
    const y = @as(f32, @floatFromInt(cell[1])) * 32;
    body.previous_x.* = x;
    body.previous_y.* = y;
    body.position_x.* = x;
    body.position_y.* = y;
}

test "player tile gate slides along solid dirt and is a no-op on the surface" {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    // Carve a 1x2 vertical pocket at (3,3)-(3,4) on the dirt plane.
    var world = try gateTestWorld(&meta, &.{ .{ 3, 3 }, .{ 3, 4 } });
    defer world.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    player.current_level = 1;
    placePlayerFlush(&data, player, .{ 3, 3 });

    // Move diagonally: +x into solid (cell 4,3), +y into carved (cell 3,4).
    const body = data.movementBodyPtr(player.entity).?;
    body.position_x.* = 3 * 32 + 6;
    body.position_y.* = 3 * 32 + 6;
    body.velocity_x.* = 100;
    body.velocity_y.* = 100;

    gatePlayerToWalkableTiles(&world, &data, player);

    // X reverted (wall), velocity_x zeroed; Y allowed (open pocket), velocity_y kept.
    try std.testing.expectEqual(@as(f32, 3 * 32), body.position_x.*);
    try std.testing.expectEqual(@as(f32, 0), body.velocity_x.*);
    try std.testing.expectEqual(@as(f32, 3 * 32 + 6), body.position_y.*);
    try std.testing.expectEqual(@as(f32, 100), body.velocity_y.*);

    // On the surface the gate never blocks: same push from level 0 is untouched.
    player.current_level = 0;
    placePlayerFlush(&data, player, .{ 3, 3 });
    body.position_x.* = 3 * 32 + 6;
    body.position_y.* = 3 * 32 + 6;
    gatePlayerToWalkableTiles(&world, &data, player);
    try std.testing.expectEqual(@as(f32, 3 * 32 + 6), body.position_x.*);
    try std.testing.expectEqual(@as(f32, 3 * 32 + 6), body.position_y.*);
}

test "pipeline skips NPC plane traversal for dormant tier but still falls active-tier NPCs" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 320, 320);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    // Punch two fall-through holes in the surface floor: one under the dormant
    // NPC (should NOT fall — the tier gate must skip it), one under the
    // active-tier NPC (should fall — unchanged pre-fix behavior).
    const floor0 = world.denseFloorLayerForLevel(0).?;
    _ = try world.clearDenseTile(floor0, 4, 3);
    _ = try world.clearDenseTile(floor0, 6, 3);

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);

    const dig_config = try DigConfig.fromMeta(&meta);
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 4,
        .dig = dig_config,
        .pathfinding = .{
            .max_frame_requests = 2,
            .max_pending_requests = 2,
            .max_cached_results = 4,
            .max_group_fields = 1,
            .worker_participant_count = 1,
            .max_solved_requests_per_step = 2,
            .max_fallback_requests_per_step = 2,
        },
    });
    defer pipeline.deinit();

    // Dormant NPC: straddles the hole cell boundary (previous cell (3,3), current
    // cell (4,3)). Movement skips dormant entities entirely, so these manually-set
    // positions survive the step unchanged — if plane traversal ran on it anyway
    // (the bug), it would still detect the crossing and fall.
    const dormant_npc = try data.createEntity();
    try data.setMovementBody(dormant_npc, .{});
    try data.setPrimitiveVisual(dormant_npc, .{
        .size = .{ .x = 32, .y = 32 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    });
    try data.setAiAgent(dormant_npc, .{ .behavior = .wander, .seek_weight = 0 });
    try data.setWorldLevel(dormant_npc, 0);
    // Tier must be set before overwriting position: setSimulationTier snaps
    // previous=position for non-moving tiers, which would erase the crossing
    // this test needs to prove the skip actually does something.
    try data.setSimulationTier(dormant_npc, .dormant);
    {
        const body = data.movementBodyPtr(dormant_npc).?;
        body.previous_x.* = 3 * 32;
        body.previous_y.* = 3 * 32;
        body.position_x.* = 4 * 32;
        body.position_y.* = 3 * 32;
    }

    // Active-tier (locomotion) NPC: velocity carries it from cell (5,3) into the
    // hole cell (6,3) this step. Locomotion allows movement but not cognition, so
    // it moves purely on the manually-set velocity below with no AI override.
    const active_npc = try data.createEntity();
    try data.setMovementBody(active_npc, .{});
    try data.setPrimitiveVisual(active_npc, .{
        .size = .{ .x = 32, .y = 32 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    });
    try data.setAiAgent(active_npc, .{ .behavior = .wander, .seek_weight = 0 });
    try data.setWorldLevel(active_npc, 0);
    try data.setSimulationTier(active_npc, .locomotion);
    {
        const body = data.movementBodyPtr(active_npc).?;
        body.previous_x.* = 5 * 32;
        body.previous_y.* = 3 * 32;
        body.position_x.* = 5 * 32;
        body.position_y.* = 3 * 32;
        body.velocity_x.* = 2000;
        body.velocity_y.* = 0;
    }

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    try frame.reservePathRequests(2, 2);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();

    frame.beginStep();
    _ = try pipeline.update(.{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 800,
        .bounds_height = 450,
    });

    // Dormant NPC never transitioned: the tier gate skipped it despite straddling
    // the hole cell.
    try std.testing.expectEqual(@as(?u16, 0), data.worldLevelConst(dormant_npc));
    try std.testing.expectEqual(@as(f32, 4 * 32), data.movementBodyConst(dormant_npc).?.position.x);

    // Active-tier NPC still falls exactly as before the fix: it crossed into the
    // hole cell, landed on level 1, and its landing cell was carved walkable.
    try std.testing.expectEqual(@as(?u16, 1), data.worldLevelConst(active_npc));
    const floor1 = world.denseFloorLayerForLevel(1).?;
    try std.testing.expect(!world.denseTileBlocksMovement(floor1, 6, 3));
}

test "pipeline runs the perception stage scoped to cognition-tier ai agents without perturbing movement/ai" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);

    // Cognition-tier observer (default tier): included in `ai_indices`, so it
    // becomes both an AI gather row and a perception gather row.
    const observer = try data.createEntity();
    try data.setMovementBody(observer, .{ .position = .{ .x = 50, .y = 50 }, .previous_position = .{ .x = 50, .y = 50 }, .velocity = .{}, .speed = 20 });
    try data.setAiAgent(observer, .{ .behavior = .wander, .seek_weight = 0 });
    try data.setAiPerception(observer, .{ .vision_range = 100 });

    // Locomotion-tier: `gatherAiAgentIndices` excludes it (tier.allowsCognition()
    // is false), so it must never enter perception's gather either — proves
    // perception shares AI's exact scoped population rather than its own.
    const out_of_scope = try data.createEntity();
    try data.setMovementBody(out_of_scope, .{ .position = .{ .x = 60, .y = 60 }, .previous_position = .{ .x = 60, .y = 60 }, .velocity = .{}, .speed = 20 });
    try data.setAiAgent(out_of_scope, .{ .behavior = .wander, .seek_weight = 0 });
    try data.setAiPerception(out_of_scope, .{ .vision_range = 100 });
    try data.setSimulationTier(out_of_scope, .locomotion);

    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 4, 4, 4, 4, 4);
    try frame.reservePathRequests(2, 2);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .steering_agent_capacity = 0,
        .static_obstacle_capacity = 0,
        .contact_capacity = 4,
        .pathfinding = .{
            .max_frame_requests = 2,
            .max_pending_requests = 2,
            .max_cached_results = 4,
            .max_group_fields = 1,
            .worker_participant_count = 1,
            .max_solved_requests_per_step = 2,
            .max_fallback_requests_per_step = 2,
        },
    });
    defer pipeline.deinit();

    frame.beginStep();
    const stats = try pipeline.update(.{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 800,
        .bounds_height = 450,
    });

    // Scoping: perception's gather ran only over the cognition-tier ai agent,
    // matching AI's own scoped population (both read the same `ai_indices`)
    // even though two entities in `DataSystem` carry `AiPerception`.
    try std.testing.expectEqual(@as(usize, 1), stats.ai.entity_count);
    try std.testing.expectEqual(@as(usize, 1), stats.perception.observer_count);
    try std.testing.expectEqual(@as(usize, 1), stats.perception.candidate_population_count);
    try std.testing.expectEqual(@as(usize, 0), stats.perception.perceived_events);
    try std.testing.expectEqual(@as(usize, 0), stats.perception.lost_events);
    try std.testing.expectEqual(@as(usize, 0), stats.perception.dropped_events);

    // No hostile candidate in range (default/neutral factions never read as
    // hostile toward each other or the player): the in-scope observer's sensed
    // state stays cold.
    const observer_perception = data.aiPerceptionConst(observer).?;
    try std.testing.expect(!observer_perception.target_visible);
    try std.testing.expectEqual(EntityId.invalid, observer_perception.nearest_threat);

    // Regression safety: inserting the perception stage between spatial_index
    // and AI does not perturb the existing movement stage's output — every
    // non-dormant body (player + both NPCs) still integrates.
    try std.testing.expectEqual(@as(usize, 3), stats.movement.body_count);
}

test "pipeline perception events truncate instead of throwing when the shared event capacity is tight" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);

    // Two observer/hostile pairs. Each observer is closer to its own hostile
    // than to the other pair's, so nearest-threat selection locks each onto
    // its own target; both newly perceive their hostile this step, so
    // perception emits two events.
    const observer_a = try data.createEntity();
    try data.setMovementBody(observer_a, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{ .x = 10, .y = 0 }, .speed = 20 });
    try data.setAiAgent(observer_a, .{ .behavior = .wander, .seek_weight = 0 });
    try data.setFaction(observer_a, .player);
    try data.setAiPerception(observer_a, .{});
    const hostile_a = try data.createEntity();
    try data.setMovementBody(hostile_a, .{ .position = .{ .x = 10, .y = 0 }, .previous_position = .{ .x = 10, .y = 0 }, .velocity = .{}, .speed = 0 });
    try data.setAiAgent(hostile_a, .{ .behavior = .wander, .seek_weight = 0 });
    try data.setFaction(hostile_a, .hostile);

    const observer_b = try data.createEntity();
    try data.setMovementBody(observer_b, .{ .position = .{ .x = 100, .y = 0 }, .previous_position = .{ .x = 100, .y = 0 }, .velocity = .{ .x = 10, .y = 0 }, .speed = 20 });
    try data.setAiAgent(observer_b, .{ .behavior = .wander, .seek_weight = 0 });
    try data.setFaction(observer_b, .player);
    try data.setAiPerception(observer_b, .{});
    const hostile_b = try data.createEntity();
    try data.setMovementBody(hostile_b, .{ .position = .{ .x = 110, .y = 0 }, .previous_position = .{ .x = 110, .y = 0 }, .velocity = .{}, .speed = 0 });
    try data.setAiAgent(hostile_b, .{ .behavior = .wander, .seek_weight = 0 });
    try data.setFaction(hostile_b, .hostile);

    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 8,
    };
    defer world.deinit();
    _ = try world.addLevel(0);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    // Real per-step event budget of 1 — tighter than the two events this
    // step's perceptions produce.
    try frame.reserveStreams(4, 1, 4, 4, 4, 4);
    try frame.reservePathRequests(2, 2);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .steering_agent_capacity = 0,
        .static_obstacle_capacity = 0,
        .contact_capacity = 4,
        .pathfinding = .{
            .max_frame_requests = 2,
            .max_pending_requests = 2,
            .max_cached_results = 4,
            .max_group_fields = 1,
            .worker_participant_count = 1,
            .max_solved_requests_per_step = 2,
            .max_fallback_requests_per_step = 2,
        },
        .perception_max_events_per_step = 1,
    });
    defer pipeline.deinit();

    frame.beginStep();
    const stats = try pipeline.update(.{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 800,
        .bounds_height = 450,
    });

    try std.testing.expectEqual(@as(usize, 1), stats.perception.perceived_events + stats.perception.lost_events);
    try std.testing.expectEqual(@as(usize, 1), stats.perception.dropped_events);
    try std.testing.expectEqual(@as(usize, 1), frame.events.mergedItems().len);
}
