// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-owned fixed-step simulation pipeline.
//! The pipeline owns reusable simulation systems, stage order, scope stats, and
//! processor handoff for one gameplay state instance. It is intentionally not a
//! global scheduler or dynamic system registry.

const std = @import("std");
const math = @import("../core/math.zig");
const runtime_perf_log = @import("../app/runtime_perf_log.zig");
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const DataSystem = @import("data_system.zig").DataSystem;
const EntityId = @import("data_system.zig").EntityId;
const Faction = @import("data_system.zig").Faction;
const MovementBodyPtr = @import("data_system.zig").MovementBodyPtr;
const MovementBodySlice = @import("data_system.zig").MovementBodySlice;
const ConstScopeColumnsSlice = @import("data_system.zig").ConstScopeColumnsSlice;
const PrimitiveVisual = @import("data_system.zig").PrimitiveVisual;
const DigConfig = @import("dig_controller.zig").DigConfig;
const DigController = @import("dig_controller.zig").DigController;
const facedCellForEntity = @import("dig_controller.zig").facedCellForEntity;
const DestructibleController = @import("destructible_controller.zig").DestructibleController;
const AudioController = @import("audio_controller.zig").AudioController;
const ParticleSystem = @import("systems/particle.zig").ParticleSystem;
const AudioCommandBuffer = @import("../app/audio.zig").AudioCommandBuffer;
const InputState = @import("../app/input.zig").InputState;
const Player = @import("player.zig").Player;
const AiStats = @import("systems/ai.zig").AiStats;
const AiSystem = @import("systems/ai.zig").AiSystem;
const default_goal_requantization_hysteresis_distance = @import("systems/ai.zig").default_goal_requantization_hysteresis_distance;
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
const CollisionContact = @import("simulation.zig").CollisionContact;
const SimulationFrame = @import("simulation.zig").SimulationFrame;
const ActionIntent = @import("simulation.zig").ActionIntent;
const action_intent_live_capacity = @import("simulation.zig").action_intent_live_capacity;
const WorldStimulus = @import("simulation.zig").WorldStimulus;
const defaultStimulusIntensity = @import("simulation.zig").defaultStimulusIntensity;
const stimulus_deferred_capacity = @import("simulation.zig").stimulus_deferred_capacity;
const stimulus_live_capacity = @import("simulation.zig").stimulus_live_capacity;
const stimulus_max_impacts_per_step = @import("simulation.zig").stimulus_max_impacts_per_step;
const stimulus_sticky_capacity = @import("simulation.zig").stimulus_sticky_capacity;
const cognition_stagger_n = @import("simulation_scope.zig").cognition_stagger_n;
const StructuralCommand = @import("data_system.zig").StructuralCommand;
const SimulationScope = @import("simulation_scope.zig").SimulationScope;
const ActiveRegion = @import("simulation_scope.zig").ActiveRegion;
const cognition_halo_chunks = @import("simulation_scope.zig").cognition_halo_chunks;
const SimulationScopeSystem = @import("systems/simulation_scope.zig").SimulationScopeSystem;
const SpatialIndexStats = @import("systems/spatial_index.zig").SpatialIndexStats;
const SpatialIndexSystem = @import("systems/spatial_index.zig").SpatialIndexSystem;
const SpatialIndexDenseWindowGeometry = @import("systems/spatial_index.zig").DenseWindowGeometry;
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
    action_intents,
    movement_intents,
    path_requests,
    movement_positions,
    chunk_columns,
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
    action_intent_capture,
    scope_advance_and_ai_gather,
    spatial_index_build,
    perception_update,
    ai_memory_update,
    affect_update,
    ai_decide,
    steering_update,
    pathfinding_update,
    apply_ai_movement_intents,
    movement_integrate,
    chunk_derive,
    bounds_and_tile_gate,
    collision_scope_gather,
    collision_detect,
    collision_respond,
    plane_traversal,
    action_react,
    tier_policy,
};

const StageContract = struct { reads: ResourceSet, writes: ResourceSet };

/// Declares each stage's resource reads/writes against `stage_order` below.
/// Checked at comptime: a stage cannot read a resource no earlier stage in
/// `stage_order` writes.
fn stageContract(stage: StageId) StageContract {
    return switch (stage) {
        .dig_world_edit => .{ .reads = .empty, .writes = resources(&.{ .world_tiles, .events }) },
        // Contract-only resource handoff — NOT a wall-clock stage body.
        // Wall-clock emit: `main_thread_inputs` → `captureActionIntent` before
        // `update()` (before dig). `stage_order` may list this tag after dig for
        // graph bookkeeping only; do not schedule dig-dependent action logic
        // as if capture runs after dig process.
        .action_intent_capture => .{ .reads = .empty, .writes = resources(&.{.action_intents}) },
        .scope_advance_and_ai_gather => .{ .reads = .empty, .writes = resources(&.{.ai_scope_indices}) },
        .spatial_index_build => .{ .reads = resources(&.{.ai_scope_indices}), .writes = resources(&.{.spatial_index}) },
        // Queries the spatial index for hostile candidates and writes sensed state; also
        // emits acquisition/loss transition events (Slice 29).
        // Reads world_tiles for line-of-sight / occlusion against the dig-authored
        // floor state from dig_world_edit earlier this step.
        .perception_update => .{ .reads = resources(&.{ .ai_scope_indices, .spatial_index, .world_tiles }), .writes = resources(&.{ .perception_sensed, .events }) },
        // Refreshes from this step's perception transition events (Slice 30),
        // reading the acquired target's last-seen position from perception_sensed.
        .ai_memory_update => .{ .reads = resources(&.{ .ai_scope_indices, .events, .perception_sensed }), .writes = resources(&.{.ai_memory}) },
        // Appraises this step's just-written perception + memory columns into drives
        // (Slice 31); arbitration (Slice 32), wired into ai_decide below, is the
        // first affect_drives reader.
        .affect_update => .{ .reads = resources(&.{ .ai_scope_indices, .perception_sensed, .ai_memory }), .writes = resources(&.{ .affect_drives, .events }) },
        .ai_decide => .{ .reads = resources(&.{ .ai_scope_indices, .spatial_index, .perception_sensed, .ai_memory, .affect_drives }), .writes = resources(&.{.navigation_intents}) },
        .steering_update => .{ .reads = resources(&.{.navigation_intents}), .writes = resources(&.{ .movement_intents, .path_requests }) },
        .pathfinding_update => .{ .reads = resources(&.{.path_requests}), .writes = .empty },
        .apply_ai_movement_intents => .{ .reads = resources(&.{.movement_intents}), .writes = resources(&.{.movement_positions}) },
        // Movement integrates the full contiguous range (non-moving rows are
        // zero-velocity no-ops), so there is no movement scope filter to read.
        .movement_integrate => .{ .reads = resources(&.{.movement_positions}), .writes = resources(&.{.movement_positions}) },
        // Recomputes each body's chunk from its final settled position, after every
        // movement_positions writer (integrate, collision respond, bounds/tile gate,
        // plane traversal) has run — ordered late, before tier_policy (LOD banding
        // reads these columns). `action_react` may sit between chunk_derive and
        // tier_policy; it does not rewrite movement_positions or chunk_columns.
        .chunk_derive => .{ .reads = resources(&.{.movement_positions}), .writes = resources(&.{.chunk_columns}) },
        // Reads dig-authored world_tiles (and any plane-traversal carves from a
        // prior step) to stop bodies penetrating solid underground tiles. Runs
        // after collision_respond so a contact push into solid dirt is re-gated
        // before plane_traversal / chunk_derive see the pose.
        .bounds_and_tile_gate => .{ .reads = resources(&.{ .movement_positions, .world_tiles }), .writes = resources(&.{.movement_positions}) },
        .collision_scope_gather => .{ .reads = .empty, .writes = resources(&.{.collision_scope_indices}) },
        .collision_detect => .{ .reads = resources(&.{ .movement_positions, .collision_scope_indices }), .writes = resources(&.{.contacts}) },
        .collision_respond => .{ .reads = resources(&.{.contacts}), .writes = resources(&.{ .movement_positions, .collision_triggers }) },
        // Reads hole/ramp walkability from world_tiles; may carve landing cells
        // (writes world_tiles + events) and snaps body x/y/z on fall
        // (writes movement_positions + world_level).
        .plane_traversal => .{ .reads = resources(&.{ .movement_positions, .world_tiles }), .writes = resources(&.{ .world_tiles, .world_level, .events, .movement_positions }) },
        // DestructibleController consumes merged action intents and queues
        // structural commands + domain events. Target resolve reads settled poses
        // and world_level columns. tier_policy also writes structural_commands
        // afterward via RangeOutputStream multi-producer append.
        .action_react => .{
            .reads = resources(&.{ .action_intents, .movement_positions, .world_level }),
            .writes = resources(&.{ .structural_commands, .events }),
        },
        .tier_policy => .{ .reads = resources(&.{ .movement_positions, .chunk_columns }), .writes = resources(&.{.structural_commands}) },
    };
}

/// A resource a stage computes purely from other same-step resources. Declaring
/// it lets the comptime freshness check below prove the derived value still
/// reflects its inputs when a later stage reads it: no stage between the producer
/// and a consumer may overwrite an input. Reads-before-writes proves a producer
/// EXISTS; this proves the produced value is not stale by the time it is used.
const Derivation = struct { output: PipelineResource, inputs: ResourceSet };

/// Derivations a stage produces (most stages produce none).
fn stageDerivations(stage: StageId) []const Derivation {
    return switch (stage) {
        // chunk_columns is recomputed from movement_positions; every position
        // writer (integrate, collision respond, bounds/tile gate, plane traversal)
        // must run before this so tier_policy reads chunks matching final positions.
        .chunk_derive => &.{.{ .output = .chunk_columns, .inputs = resources(&.{.movement_positions}) }},
        else => &.{},
    };
}

/// The pipeline's concrete fixed-step stage order. Reads-before-writes ordering
/// and derived-resource freshness (see `stageDerivations`) are enforced at
/// comptime below; ordering the contract cannot see (e.g. two stages that share
/// no `PipelineResource`) is proven by causal-effect tests further down in this
/// file, the same technique the other stage-order tests use.
///
/// Tile gate runs AFTER collision response so a contact correction that pushes a
/// body into solid underground dirt is re-gated before plane_traversal and
/// chunk_derive observe the pose. Dig still runs first so this step's carves are
/// walkable for movement + gate. Bounds clamp shares the gate stage.
const stage_order = [_]StageId{
    .dig_world_edit,
    .action_intent_capture,
    .scope_advance_and_ai_gather,
    .spatial_index_build,
    .perception_update,
    .ai_memory_update,
    .affect_update,
    .ai_decide,
    .steering_update,
    .pathfinding_update,
    .apply_ai_movement_intents,
    .movement_integrate,
    .collision_scope_gather,
    .collision_detect,
    .collision_respond,
    .bounds_and_tile_gate,
    .plane_traversal,
    .chunk_derive,
    .action_react,
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

    // Freshness: a derived resource must still reflect its inputs when consumed.
    // For each derivation, no stage between the producing stage and any later
    // consumer of the output may overwrite one of the inputs — otherwise the
    // consumer reads a value computed from superseded inputs.
    for (stage_order, 0..) |producer_stage, producer_i| {
        for (stageDerivations(producer_stage)) |derivation| {
            for (stage_order[producer_i + 1 ..], producer_i + 1..) |consumer_stage, consumer_i| {
                if (!stageContract(consumer_stage).reads.contains(derivation.output)) continue;
                for (stage_order[producer_i + 1 .. consumer_i]) |between_stage| {
                    if (stageContract(between_stage).writes.intersectWith(derivation.inputs).count() != 0) {
                        @compileError("SimulationPipeline: derived resource '" ++ @tagName(derivation.output) ++
                            "' from '" ++ @tagName(producer_stage) ++ "' is stale before consumer '" ++
                            @tagName(consumer_stage) ++ "': stage '" ++ @tagName(between_stage) ++
                            "' overwrites an input in between — move the deriving stage after the last input writer that precedes the consumer");
                    }
                }
            }
        }
    }
}

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
    /// Optional particle system for soft-drop destroy bursts (Slice 45).
    particles: ?*ParticleSystem = null,
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
    chunk_derive: BatchStats = .{},
    collision: CollisionStats = .{},
    collision_response: CollisionResponseStats = .{},
    /// Live-bus stimuli dropped this step (promote and footstep optional
    /// appends when `stimulus_live_capacity` is full). Dig uses required
    /// `appendStimulus`, not soft drop.
    stimuli_live_dropped: usize = 0,
    /// Deferred impact stimuli dropped this step when the pipeline buffer is full.
    stimuli_deferred_dropped: usize = 0,
    /// One-shot sticky captures dropped this step when the sticky buffer is full.
    stimuli_sticky_dropped: usize = 0,
    /// Deferred impacts promoted onto the live bus at the start of this step.
    stimuli_promoted: usize = 0,
    /// Action intents observed by the `action_react` consumer.
    action_intents_consumed: usize = 0,
    /// Optional action-intent appends dropped (full bus / ensure failure).
    action_intents_dropped: usize = 0,
    /// Destructible entities destroyed this step (queued structural destroy).
    destructibles_destroyed: usize = 0,
    /// Destructible entities hit but not destroyed this step.
    destructibles_hit: usize = 0,

    pub fn recordTo(self: SimulationPipelineStats, perf: runtime_perf_log.Context) void {
        const scope_stats = self.scope.stats;
        const spatial_index_stats = self.spatial_index;
        const perception_stats = self.perception;
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

        perf.recordMetric(.perception_observers, metric(perception_stats.observer_count));
        perf.recordMetric(.perception_sensed, metric(perception_stats.sensed_count));
        perf.recordMetric(.perception_los_checks, metric(perception_stats.los_checks));
        perf.recordMetric(.perception_los_blocked, metric(perception_stats.los_blocked));
        perf.recordMetric(.perception_nearest_threat_found, metric(perception_stats.nearest_threat_found_count));
        perf.recordMetric(.perception_candidate_checks, metric(perception_stats.candidate_checks));
        perf.recordBatch(.perception, perception_stats.batch);

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
        perf.recordTiming(.steering_select, steering_stats.select_ns);
        perf.recordTiming(.steering_snapshot, steering_stats.snapshot_ns);
        perf.recordTiming(.steering_directions, steering_stats.directions_ns);

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
        perf.recordMetric(.path_escalated_solves, metric(pathfinding_stats.escalated_solves));
        perf.recordMetric(.path_escalated_deferred, metric(pathfinding_stats.escalated_deferred));
        perf.recordMetric(.path_goal_projected, metric(pathfinding_stats.goal_projected));
        perf.recordMetric(.path_group_fields_built, metric(pathfinding_stats.group_fields_built));
        perf.recordMetric(.path_group_field_reuses, metric(pathfinding_stats.group_field_reuses));
        perf.recordMetric(.path_group_field_rebuild_throttled, metric(pathfinding_stats.group_field_rebuild_throttled));
        perf.recordMetric(.path_group_field_samples, metric(pathfinding_stats.group_field_samples));
        perf.recordMetricMax(.path_max_stitch_segments, metric(pathfinding_stats.max_stitch_segments_observed));
        perf.recordBatch(.path_fallback, pathfinding_stats.fallback_batch);
        perf.recordTiming(.pathfinding_accept, pathfinding_stats.accept_ns);
        perf.recordTiming(.pathfinding_group_service, pathfinding_stats.group_service_ns);
        perf.recordTiming(.pathfinding_solve, pathfinding_stats.solve_ns);
        perf.recordTiming(.pathfinding_publish, pathfinding_stats.publish_ns);

        perf.recordMetric(.movement_bodies, metric(movement_stats.body_count));
        perf.recordBatch(.movement, movement_stats.batch);
        perf.recordBatch(.chunk_derive, self.chunk_derive);

        perf.recordMetric(.collision_bodies, metric(collision_stats.body_count));
        perf.recordMetric(.collision_candidate_pairs, metric(collision_stats.candidate_pair_count));
        perf.recordMetric(.collision_contacts, metric(collision_stats.contact_count));
        perf.recordMetric(.collision_broadphase_simd_groups, metric(collision_stats.broadphase_simd_groups));
        if (collision_stats.used_full_sort) perf.recordMetric(.collision_full_sorts, 1);
        perf.recordBatch(.collision_broadphase, collision_stats.broadphase_batch);
        perf.recordBatch(.collision_narrowphase, collision_stats.narrowphase_batch);
        perf.recordTiming(.collision_gather, collision_stats.gather_ns);
        perf.recordTiming(.collision_sort, collision_stats.sort_ns);

        perf.recordMetric(.collision_response_contacts, metric(collision_response_stats.contact_count));
        perf.recordMetric(.collision_response_intents, metric(collision_response_stats.intent_count));
        perf.recordMetric(.collision_response_triggers, metric(collision_response_stats.trigger_count));

        perf.recordMetric(.stimuli_live_dropped, metric(self.stimuli_live_dropped));
        perf.recordMetric(.stimuli_deferred_dropped, metric(self.stimuli_deferred_dropped));
        perf.recordMetric(.stimuli_sticky_dropped, metric(self.stimuli_sticky_dropped));
        perf.recordMetric(.stimuli_promoted, metric(self.stimuli_promoted));
        perf.recordMetric(.action_intents_consumed, metric(self.action_intents_consumed));
        perf.recordMetric(.action_intents_dropped, metric(self.action_intents_dropped));
        perf.recordMetric(.destructibles_destroyed, metric(self.destructibles_destroyed));
        perf.recordMetric(.destructibles_hit, metric(self.destructibles_hit));
    }
};

fn metric(value: usize) u64 {
    return @intCast(value);
}

/// Squared speed threshold for emitting one player footstep per step.
const footstep_velocity_sq_threshold: f32 = 1.0;

/// Minimum penetration before a zero-velocity contact may still enqueue impact
/// (only when relative velocity is also non-trivial).
const impact_min_penetration: f32 = 1.0;

const hearing_stimuli_scratch_capacity: usize = stimulus_live_capacity + stimulus_sticky_capacity;

comptime {
    // sticky_remaining stores the per-entry linger count in a u8.
    std.debug.assert(cognition_stagger_n - 1 <= std.math.maxInt(u8));
}

fn contactInvolvesEntity(contact: CollisionContact, entity: EntityId) bool {
    return contact.a.eql(entity) or contact.b.eql(entity);
}

fn contactStimulusPosition(data: *const DataSystem, contact: CollisionContact) ?math.Vec2 {
    const a = data.movementBodyConst(contact.a) orelse return null;
    const b = data.movementBodyConst(contact.b) orelse return null;
    return .{
        .x = (a.position.x + b.position.x) * 0.5,
        .y = (a.position.y + b.position.y) * 0.5,
    };
}

fn impactStimulusIntensity(contact: CollisionContact) f32 {
    const scale = std.math.clamp(contact.penetration / 18.0, 0.25, 1.0);
    return defaultStimulusIntensity(.impact) * scale;
}

fn contactEligibleForImpactStimulus(contact: CollisionContact) bool {
    // Velocity comes from the contact's pre-response snapshot; reading the live
    // movement columns here would see the approach axis already zeroed by
    // collision response, silencing head-on hits.
    if (contact.pre_response_max_speed_sq >= footstep_velocity_sq_threshold) return true;
    if (contact.penetration < impact_min_penetration) return false;
    return contact.pre_response_relative_speed_sq >= footstep_velocity_sq_threshold;
}

/// Moves pipeline-deferred impacts onto the live per-step bus before perception.
fn promoteDeferredStimuli(
    pipeline: *SimulationPipeline,
    frame: *SimulationFrame,
    live_dropped: *usize,
) usize {
    const pending = pipeline.deferred_stimulus_count;
    var promoted: usize = 0;
    var retained: usize = 0;
    for (pipeline.deferred_stimuli[0..pending]) |stimulus| {
        if (frame.tryAppendStimulus(stimulus, stimulus_live_capacity)) {
            promoted += 1;
        } else {
            pipeline.deferred_stimuli[retained] = stimulus;
            retained += 1;
            live_dropped.* += 1;
        }
    }
    pipeline.deferred_stimulus_count = retained;
    return promoted;
}

fn rebuildHearingStimuliScratch(pipeline: *SimulationPipeline, frame: *const SimulationFrame) []const WorldStimulus {
    const live = frame.stimuli.mergedItems();
    var len: usize = 0;
    for (live) |stimulus| {
        std.debug.assert(len < hearing_stimuli_scratch_capacity);
        pipeline.hearing_stimuli_scratch[len] = stimulus;
        len += 1;
    }
    for (0..pipeline.sticky_count) |i| {
        if (pipeline.sticky_remaining[i] == 0) continue;
        std.debug.assert(len < hearing_stimuli_scratch_capacity);
        pipeline.hearing_stimuli_scratch[len] = pipeline.sticky_stimuli[i];
        len += 1;
    }
    return pipeline.hearing_stimuli_scratch[0..len];
}

/// Ages one-shot sticky stimuli one stagger step, then captures this step's
/// dig/impact stimuli into freed slots. The age-before-capture order is internal
/// so it cannot be reordered by a caller; captures past the fixed sticky
/// capacity are dropped and counted rather than silently discarded.
fn advanceStickyStimuli(pipeline: *SimulationPipeline, frame: *const SimulationFrame, sticky_dropped: *usize) void {
    var write: usize = 0;
    for (0..pipeline.sticky_count) |i| {
        const remaining = pipeline.sticky_remaining[i];
        if (remaining <= 1) continue;
        pipeline.sticky_stimuli[write] = pipeline.sticky_stimuli[i];
        pipeline.sticky_remaining[write] = remaining - 1;
        write += 1;
    }
    pipeline.sticky_count = write;

    const linger = cognition_stagger_n - 1;
    if (linger == 0) return;
    for (frame.stimuli.mergedItems()) |stimulus| {
        switch (stimulus.kind) {
            .dig, .impact => {},
            .footstep => continue,
        }
        if (pipeline.sticky_count >= stimulus_sticky_capacity) {
            sticky_dropped.* += 1;
            continue;
        }
        pipeline.sticky_stimuli[pipeline.sticky_count] = stimulus;
        pipeline.sticky_remaining[pipeline.sticky_count] = linger;
        pipeline.sticky_count += 1;
    }
}

/// At most one footstep when the player's movement body carries non-trivial velocity.
fn tryAppendPlayerFootstepStimulus(
    frame: *SimulationFrame,
    data: *const DataSystem,
    player: Player,
    live_dropped: *usize,
) void {
    const body = data.movementBodyConst(player.entity) orelse return;
    const vel_sq = body.velocity.x * body.velocity.x + body.velocity.y * body.velocity.y;
    if (vel_sq < footstep_velocity_sq_threshold) return;
    const appended = frame.tryAppendStimulus(.{
        .position = body.position,
        .intensity = defaultStimulusIntensity(.footstep),
        .kind = .footstep,
        .level = player.current_level,
    }, stimulus_live_capacity);
    if (!appended) live_dropped.* += 1;
}

/// Enqueues player-involving collision contacts as next-step impact stimuli.
fn enqueuePlayerCollisionImpactsToDeferred(
    pipeline: *SimulationPipeline,
    frame: *const SimulationFrame,
    data: *const DataSystem,
    player_entity: EntityId,
    player_level: u16,
    deferred_dropped: *usize,
) void {
    var enqueued: usize = 0;
    for (frame.contacts.mergedItems()) |contact| {
        if (!contactInvolvesEntity(contact, player_entity)) continue;
        if (!contactEligibleForImpactStimulus(contact)) continue;
        if (enqueued >= stimulus_max_impacts_per_step) {
            deferred_dropped.* += 1;
            continue;
        }
        const position = contactStimulusPosition(data, contact) orelse continue;
        if (pipeline.deferred_stimulus_count >= stimulus_deferred_capacity) {
            deferred_dropped.* += 1;
            continue;
        }
        pipeline.deferred_stimuli[pipeline.deferred_stimulus_count] = .{
            .position = position,
            .intensity = impactStimulusIntensity(contact),
            .kind = .impact,
            .level = player_level,
        };
        pipeline.deferred_stimulus_count += 1;
        enqueued += 1;
    }
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
    /// memory-aware cold-pursue retarget.
    ai_memory: AiMemorySystem,
    /// Emotion-drive appraisal (fear/curiosity/aggression/fatigue): appraises
    /// this step's just-refreshed `AiPerception`/`AiMemory` state (both
    /// optional per row) plus each agent's own `AiAgent.active_behavior` into
    /// the cognition-scoped `AiAffect` subset. `AiConfig.affect_slice` threads
    /// the resulting drives into arbitration (Slice 32) one stage later; this
    /// stage only appraises and decays them.
    affect: AffectSystem,
    dig: DigController,
    destructible: DestructibleController,
    audio_controller: AudioController,
    nav_cell_size: f32,
    /// See `SimulationPipelineConfig.perception_max_events_per_step`.
    perception_max_events_per_step: usize,
    /// See `SimulationPipelineConfig.affect_max_events_per_step`.
    affect_max_events_per_step: usize,
    /// Pipeline-owned deferred impact buffer (Slice 39): survives `beginStep`
    /// until promoted before perception on the next `update`.
    deferred_stimuli: [stimulus_deferred_capacity]WorldStimulus = undefined,
    deferred_stimulus_count: usize = 0,
    /// One-shot dig/impact linger for cognition stagger (not cleared on `beginStep`).
    sticky_stimuli: [stimulus_sticky_capacity]WorldStimulus = undefined,
    sticky_remaining: [stimulus_sticky_capacity]u8 = undefined,
    sticky_count: usize = 0,
    hearing_stimuli_scratch: [hearing_stimuli_scratch_capacity]WorldStimulus = undefined,
    /// Rising-edge latch for `Action.interact` (one press per fixed step).
    /// Advanced only after a successful append so a soft-dropped press can retry.
    interact_held_last: bool = false,
    /// Soft-drops from `tryAppendActionIntent` this step (reset each `update`).
    action_intents_dropped_step: usize = 0,

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
        const spatial_geometry: SpatialIndexDenseWindowGeometry = if (config.navigation_world) |world|
            .{ .chunk_size_tiles = world.chunk_size_tiles, .tile_size = world.tile_size }
        else
            .{};
        try spatial_index.reserve(config.movement_body_capacity, spatial_geometry);
        // No reserve method: PerceptionSystem lazily ensureTotalCapacity's its
        // gather buffers on first use, same as AiSystem.
        var perception = PerceptionSystem.init(allocator);
        errdefer perception.deinit();
        // Pays every level's first-ever `level_blocked` cache build once here,
        // alongside pathfinding's own static grid build above, instead of
        // scattered across whichever live steps first put an observer on each
        // level (see `PerceptionSystem.prebuildLevelCaches`'s doc comment).
        if (config.navigation_world) |world| {
            try perception.prebuildLevelCaches(world);
        }
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
            .destructible = DestructibleController.init(),
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

    /// Orchestrates the post-commit static-obstacle spatial invalidation for
    /// steering local avoidance. Same structural_commit event family as nav/
    /// perception; call order among the three post-commit reactions does not
    /// matter (disjoint state).
    pub fn reactToPostCommitSteeringEvents(
        self: *SimulationPipeline,
        frame: *const SimulationFrame,
    ) void {
        self.steering.reactToPostCommitSteeringEvents(frame);
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

    /// Queues collision SFX for this step's contacts through the owned audio
    /// controller. Only contacts involving `player.entity` play a sound.
    pub fn queueCollisionAudio(self: *SimulationPipeline, audio: *AudioCommandBuffer, frame: *const SimulationFrame, data: *const DataSystem, player: Player, delta_seconds: f32) void {
        self.audio_controller.queueCollision(audio, frame, data, player.entity, delta_seconds);
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

    /// Captures non-locomotion action intents on held-input rising edges. Called
    /// in the main-thread input phase alongside `captureDigIntent`. On soft-drop
    /// (full bus), the latch stays open so a later step can retry while held.
    pub fn captureActionIntent(
        self: *SimulationPipeline,
        input: *const InputState,
        frame: *SimulationFrame,
        player: Player,
        data: *const DataSystem,
        world: *const WorldSystem,
    ) void {
        const interact_held = input.isHeld(.interact);
        if (interact_held and !self.interact_held_last) {
            var intent: ActionIntent = .{
                .entity = player.entity,
                .kind = .interact,
            };
            // Same faced-cell probe as dig so Slice 45 consumers match dig targeting.
            if (facedCellForEntity(world, data, player.entity)) |cell| {
                intent.level = player.current_level;
                intent.cell_x = cell.x;
                intent.cell_y = cell.y;
                intent.has_cell = true;
            }
            const appended = frame.tryAppendActionIntent(intent, action_intent_live_capacity);
            if (appended) {
                self.interact_held_last = true;
            } else {
                self.action_intents_dropped_step += 1;
            }
            return;
        }
        if (!interact_held) self.interact_held_last = false;
    }

    /// Synchronizes interpolation history for pipeline-owned movement state.
    /// State-owned visual effects still synchronize at their own owner.
    pub fn syncPreviousPositions(self: *SimulationPipeline, data: *DataSystem) void {
        var movement_slice = data.movementBodySlice();
        self.movement.syncPreviousPositions(&movement_slice);
    }

    /// Runs the current full-active fixed-step stage order and returns stage
    /// stats. Scope selection uses the live camera cognition halo + stagger; chunk
    /// columns are derived in their own late stage after positions settle.
    pub fn update(self: *SimulationPipeline, context: SimulationPipelineUpdateContext) !SimulationPipelineStats {
        const data = context.data;
        const frame = context.frame;

        frame.phase = .processors;
        var stimuli_live_dropped: usize = 0;
        var stimuli_deferred_dropped: usize = 0;
        var stimuli_sticky_dropped: usize = 0;
        // Capture-phase soft-drops accumulate on the pipeline field before update;
        // fold into this step's stats and clear for the next input phase.
        const action_intents_dropped = self.action_intents_dropped_step;
        self.action_intents_dropped_step = 0;
        const stimuli_promoted = promoteDeferredStimuli(self, frame, &stimuli_live_dropped);
        // Player-authored world edit. Runs after deferred promote; its
        // world_tile_changed event is deferred and re-masks navigation in
        // merge_outputs regardless of order.
        try self.dig.process(context.world, data, context.player.*, frame);
        tryAppendPlayerFootstepStimulus(frame, data, context.player.*, &stimuli_live_dropped);
        // `action_intent_capture` is a contract-only stage: intents were already
        // appended in `main_thread_inputs` (before this function).

        // Backbone scope pass. Advance the stagger clock, derive the camera
        // cognition halo, and select the cognition (AI/steering) subset for this
        // step. Chunk columns are derived later in `chunk_derive` from each body's
        // final settled position (after integrate, collision, tile gate, and plane
        // traversal) — not in-pass during movement. The AI gather reads the chunk
        // written last step (the body's current pre-move cell). Movement/collision
        // gate on tier only (no chunk filter), so they keep running off-screen;
        // cognition gates on the halo + stagger.
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

        const hearing_stimuli = rebuildHearingStimuliScratch(self, frame);
        var perception_timer = StageTimer.start();
        const perception_stats = try self.perception.update(ai_slice, move_slice, self.spatial_index.view(), context.world, data, &frame.events, context.thread_system, .{
            .scope_dense_indices = ai_indices,
            .player_candidate = perception_player_candidate,
            .stimuli = hearing_stimuli,
            .max_events_per_step = self.perception_max_events_per_step,
        });
        perception_timer.stop(context.perf, .pipeline_perception);
        advanceStickyStimuli(self, frame, &stimuli_sticky_dropped);

        // Decays staleness/familiarity/ring contacts and refreshes from this
        // step's perception acquisition events, over the same cognition-scoped
        // `ai_indices` population, before AI reads it for the cold-pursue
        // retarget below.
        var ai_memory_timer = StageTimer.start();
        const ai_memory_stats = try self.ai_memory.update(ai_slice, data, frame, context.thread_system, .{
            .scope_dense_indices = ai_indices,
        });
        ai_memory_timer.stop(context.perf, .pipeline_ai_memory);

        // Appraises this step's just-written perception + memory state into
        // fear/curiosity/aggression/fatigue, over the same cognition-scoped
        // `ai_indices` population. Must run after both perception and
        // ai_memory (it reads their this-step hot columns) and before
        // arbitration (Slice 32), wired below via `AiConfig.affect_slice`,
        // reads the resulting drives.
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
        // them at the ramp mouth. `player_target` only ever feeds the opt-in
        // pursue fallback below, never a goal level, so this stays a flat (x,y).
        const player_target = if (data.movementBodyConst(context.player.entity)) |pbody|
            pbody.previous_position
        else
            math.Vec2{ .x = 400, .y = 225 };

        var ai_timer = StageTimer.start();
        const ai_stats = try self.ai.update(ai_slice, move_slice, self.spatial_index.view(), data, frame, context.thread_system, context.delta_seconds, .{
            .intent_seed = 0xfeedf00d,
            .step = self.scope.currentStep(),
            // Last-resort fallback (see AiConfig.focus_target's doc comment):
            // arbitration only reaches for this when a row's own perception/
            // memory produced no goal and its gain_pursue > 0. Most rows
            // resolve their goal from their own sensed/remembered/felt state
            // instead and never touch this pair.
            .focus_target = player_target,
            // Ties the pursue fallback's identity to the actual entity
            // `player_target` represents, so a row falling back to this
            // signal only ever targets this same entity.
            .focus_entity = context.player.entity,
            // Throttles how often the fallback target re-keys as the player
            // moves continuously, since local separation/steering closes the
            // small gap between path updates. Without this, the goal re-keys
            // (and triggers one bounded escalated solve) roughly every nav
            // cell the player crosses.
            .goal_requantization_hysteresis_distance = default_goal_requantization_hysteresis_distance,
            // Ceiling only: arbitration currently resolves every behavior's
            // goal to `.individual` (each row's goal is agent-specific), so
            // this has no observable effect today. `.individual` is still the
            // correct default going forward -- a future group-goal upgrade
            // (e.g. cohere's shared quantized cell) would otherwise silently
            // turn back on the moment it lands.
            .nav_request_kind = .individual,
            .navigation_intents = &frame.navigation_intents,
            // Cognition halo + stagger selection. Steering inherits this scope
            // transitively: it only acts on the navigation intents AI emits here.
            .scope_dense_indices = ai_indices,
            // Cold-perception agents with fresh memory retarget seek toward
            // their last-known position instead of losing the goal.
            .perception_slice = data.aiPerceptionSliceConst(),
            .memory_slice = data.aiMemorySliceConst(),
            // Emotion drives (Slice 31/32): arbitration scores each row's
            // behaviors partly off these, so feelings can change which
            // behavior wins independent of what's perceived/remembered.
            .affect_slice = data.aiAffectSliceConst(),
            .interest_markers = &context.world.interest_markers,
        });
        ai_timer.stop(context.perf, .pipeline_ai);

        var steering_timer = StageTimer.start();
        const steering_stats = try self.steering.update(data, frame, context.thread_system, &self.pathfinding, .{});
        steering_timer.stop(context.perf, .pipeline_steering);

        var pathfinding_timer = StageTimer.start();
        // Drive elastic pathfinding capacity off the live steering-agent crowd (the
        // entities that consume paths), so pools grow for battles and shrink after.
        const path_agent_count = data.steeringAgentSliceConst().entities.len;
        const pathfinding_stats = try self.pathfinding.update(&frame.path_requests, path_agent_count, context.thread_system, .{});
        pathfinding_timer.stop(context.perf, .pipeline_pathfinding);

        var apply_intents_timer = StageTimer.start();
        applyAiMovementIntents(data, frame);
        apply_intents_timer.stop(context.perf, .pipeline_apply_intents);

        // Movement is a pure position integrator over the full contiguous SoA range:
        // non-moving rows carry zero velocity (DataSystem zeros it on entry to a
        // non-moving tier) so they integrate as no-ops — no scattered skip-path.
        // Chunk maintenance is deliberately NOT here: chunk columns are consumed by
        // tier policy (LOD) and render prep, not by movement, and must reflect the
        // final settled position after collision response, bounds/tile gating, and
        // plane traversal — so it runs as its own late pass (action_react may sit
        // between chunk_derive and tier_policy; neither rewrites chunk columns).
        var movement_slice = data.movementBodySlice();
        var movement_timer = StageTimer.start();
        const movement_stats = self.movement.update(&movement_slice, context.thread_system, context.delta_seconds, .{});
        movement_timer.stop(context.perf, .pipeline_movement);

        // Collision also gates on tier only (no chunk filter): off-screen entities
        // keep colliding with geometry. Null = full-active. Runs before the tile
        // gate so a contact push into solid underground dirt is corrected by the
        // gate before plane_traversal / chunk_derive observe the pose.
        const collision_scope_indices = (try self.scope.gatherCollisionBoundsIndices(data, context.thread_system, .{})).indices;
        var collision_timer = StageTimer.start();
        const collision_stats = try self.collision.update(data, &frame.contacts, context.thread_system, .{
            .scope_dense_indices = collision_scope_indices,
        });
        collision_timer.stop(context.perf, .pipeline_collision);

        var collision_response_timer = StageTimer.start();
        const collision_response_stats = try self.collision_response.update(data, frame);
        collision_response_timer.stop(context.perf, .pipeline_collision_response);
        enqueuePlayerCollisionImpactsToDeferred(
            self,
            frame,
            data,
            context.player.entity,
            context.player.current_level,
            &stimuli_deferred_dropped,
        );

        var clamp_timer = StageTimer.start();
        clampAiEntitiesToBounds(data, context.bounds_width, context.bounds_height);
        try context.player.clampToBounds(data, context.bounds_width, context.bounds_height);
        // Gate against solid world tiles on the current plane (mining: underground
        // dirt is solid until dug). After collision response so contact corrections
        // cannot leave a body embedded in solid tiles. NPCs skip dormant-tier
        // (they don't move this step, so gating them would be dead work).
        gatePlayerToWalkableTiles(context.world, data, context.player.*);
        gateNpcEntitiesToWalkableTiles(context.world, data);
        clamp_timer.stop(context.perf, .pipeline_clamp_bounds);

        // After movement/collision/gate settle positions, update planes: follow a
        // ramp on cell entry, fall one level per step when standing over a hole.
        // Player + NPCs route through `DigController.applyEntityPlaneTraversal`;
        // fall landing carves are batched into one event range (single finishWrite).
        try applyPlaneTraversalStage(&self.dig, context.world, data, context.player, frame);

        // Chunk maintenance: recompute each body's (chunk_x, chunk_y) from its now
        // settled position. Positions are final here — all of movement, collision
        // response, bounds/tile gating, and plane traversal have run. Consumers are
        // tier_policy (LOD banding; action_react may run between this pass and it)
        // and render prep; movement never reads it. Own timer keeps this scope
        // work out of the movement stage.
        var chunk_derive_timer = StageTimer.start();
        const chunk_derive_stats = self.scope.deriveChunks(data, context.thread_system, .{
            .tile_size = context.world.tile_size,
            .chunk_size_tiles = context.world.chunk_size_tiles,
            .width = context.world.width,
            .height = context.world.height,
        }, .{});
        chunk_derive_timer.stop(context.perf, .pipeline_chunk_derive);

        // action_react: first domain consumer of merged action intents (destructibles).
        // Queues structural_commands + domain events; tier_policy may append more
        // structural_commands afterward (RangeOutputStream multi-producer).
        const destructible_stats = try self.destructible.process(
            frame,
            data,
            context.world,
            context.particles,
        );

        // Simulation-LOD tier policy: each entity is assigned cognition/locomotion/
        // kinematic/dormant by its cube distance from the visible region, applied
        // via deferred structural commands on the frame stream for the commit seam.
        // Uses the raw visible region (not the cognition halo) so all four bands
        // are measured from the same origin, anchored at the camera/player level so
        // off-level entities demote. Queues nothing when no tier changed.
        var visible_region = context.world.visibleChunkRegion();
        if (visible_region) |*region| region.level = context.player.current_level;
        _ = try self.scope.queueTierChanges(data, visible_region, &frame.structural_commands, context.thread_system, .{});

        const scope = self.buildScopeStats(
            data,
            cognition_region,
            ai_indices,
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
            .chunk_derive = chunk_derive_stats,
            .collision = collision_stats,
            .collision_response = collision_response_stats,
            .stimuli_live_dropped = stimuli_live_dropped,
            .stimuli_deferred_dropped = stimuli_deferred_dropped,
            .stimuli_sticky_dropped = stimuli_sticky_dropped,
            .stimuli_promoted = stimuli_promoted,
            .action_intents_consumed = destructible_stats.intents_consumed,
            .action_intents_dropped = action_intents_dropped,
            .destructibles_destroyed = destructible_stats.destroyed,
            .destructibles_hit = destructible_stats.hits,
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
        collision_scope_indices: ?[]const u32,
        steering_stats: SteeringStats,
    ) SimulationScope {
        var stats = data.simulationScopeStatsFullActive();
        stats.ai_stage_entities = ai_indices.len;
        // Steering is transitively scoped via AI's intents; its real participation
        // is the count of movement intents it actually emitted this step.
        stats.steering_stage_entities = steering_stats.movement_intent_count;
        // Movement integrates the full contiguous range every step (non-moving rows
        // are zero-velocity no-ops), so its stage entity count is the full-active
        // default set above — there is no movement scope filter to narrow it.
        if (collision_scope_indices) |idx| stats.collision_stage_entities = idx.len;
        stats.stagger_skips = self.scope.stagger_skips;
        stats.chunk_filtered_entities = self.scope.chunk_filtered_entities;
        return .{ .active_region = cognition_region, .stats = stats };
    }
};

const StageTimer = runtime_perf_log.StageTimer;

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

/// Stops one dense movement row from moving into solid world tiles on `level`.
/// No-op on level 0 (the surface is fully walkable and pre-existing decos/water
/// are intentionally pass-through there). Resolves X then Y independently against
/// the pre-move position so a diagonal push into a wall slides along it. The body
/// is one tile wide; sampling the four AABB corners (with an epsilon so a flush
/// right/bottom edge stays in the covered cell) is exact for the sub-tile motion
/// this produces. Allocation-free, scalar. Shared by the player and NPC gates.
fn gateBodyColumnsToWalkableTiles(
    world: *const WorldSystem,
    level: u16,
    movement: *MovementBodySlice,
    movement_index: usize,
    size_x: f32,
    size_y: f32,
) void {
    if (level == 0) return;
    const pre_x = movement.previous_x[movement_index];
    const pre_y = movement.previous_y[movement_index];
    const post_x = movement.position_x[movement_index];
    const post_y = movement.position_y[movement_index];

    var resolved_x = post_x;
    if (rectOverlapsSolidTile(world, level, post_x, pre_y, size_x, size_y)) resolved_x = pre_x;
    var resolved_y = post_y;
    if (rectOverlapsSolidTile(world, level, resolved_x, post_y, size_x, size_y)) resolved_y = pre_y;

    if (resolved_x != post_x) movement.velocity_x[movement_index] = 0;
    if (resolved_y != post_y) movement.velocity_y[movement_index] = 0;
    movement.position_x[movement_index] = resolved_x;
    movement.position_y[movement_index] = resolved_y;
}

/// Pointer wrapper for the single-entity player gate (same math as the dense path).
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
    const visuals = data.primitiveVisualSliceConst();
    var movement = data.movementBodySlice();
    // One slot resolve per AI → dense columns. Tier/level come from the movement
    // scope row (kept in sync with world_level), not extra entity lookups.
    for (ai_slice.entities) |entity| {
        const indices = data.movementVisualDenseIndices(entity) orelse continue;
        const mi = indices.movement;
        // Dormant NPCs never move this step (movement itself skips writing their
        // position), so gating them against world tiles is dead work — skip.
        if (!scope_columns.tier[mi].allowsMovement()) continue;
        gateBodyColumnsToWalkableTiles(
            world,
            scope_columns.level[mi],
            &movement,
            mi,
            visuals.size_x[indices.visual],
            visuals.size_y[indices.visual],
        );
    }
}

/// Player + NPC plane traversal for one step. Preflights event capacity, dense
/// GPU edit capacity, and `world_level` attaches for every cell-entry candidate
/// **before** any world mutate, then applies transitions (collecting tile
/// changes) and publishes all carves in a single event range with one
/// finishWrite — O(N) rather than per-fall appendRequired O(N²). Mid-loop
/// attach OOM cannot leave earlier landings carved without events.
fn applyPlaneTraversalStage(
    dig: *DigController,
    world: *WorldSystem,
    data: *DataSystem,
    player: *Player,
    frame: *SimulationFrame,
) !void {
    const scratch = &frame.world_tile_changes_scratch;
    scratch.clearRetainingCapacity();

    const ai_slice = data.aiAgentSliceConst();
    const scope_columns = data.scopeColumnsSliceConst();
    try scratch.ensureTotalCapacity(frame.allocator, 1 + ai_slice.entities.len);

    // Read-only preflight: count landing carves and missing world_level attaches
    // so capacity is reserved before any world mutate.
    var pending_carves: usize = 0;
    var missing_world_level: usize = 0;
    const player_entry = playerCellEntry(dig, world, data, player.*);
    if (player_entry) |entry| {
        if (dig.wouldCarveLandingCell(world, entry.level, entry.cell)) pending_carves += 1;
        if (data.worldLevelConst(player.entity) == null) missing_world_level += 1;
    }
    for (ai_slice.entities) |entity| {
        if (npcCellEntry(world, data, scope_columns, entity)) |entry| {
            if (dig.wouldCarveLandingCell(world, entry.level, entry.cell)) pending_carves += 1;
            if (data.worldLevelConst(entity) == null) missing_world_level += 1;
        }
    }
    // Event capacity + dense GPU edit queue (when live) reserved before any
    // carve so a mid-stage OOM cannot leave earlier falls published to world
    // without world_tile_changed / GPU edits (multi-fall atomicity).
    try frame.events.ensureEventAppendCapacity(pending_carves);
    try world.ensureDenseTileEditCapacity(pending_carves);

    // Attach world_level for every cell-entry candidate that lacks it before the
    // first carve. Capacity for all missing rows is reserved first so a partial
    // attach loop cannot leave some entities leveled and others mid-growth, then
    // carves still safe: applyEntityPlaneTraversal's attach becomes a no-op.
    if (missing_world_level > 0) {
        try data.world_levels.ensureCapacity(data.allocator, data.world_levels.len() + missing_world_level);
        if (player_entry) |entry| {
            if (data.worldLevelConst(player.entity) == null) {
                try data.setWorldLevel(player.entity, entry.level);
            }
        }
        for (ai_slice.entities) |entity| {
            if (npcCellEntry(world, data, scope_columns, entity)) |entry| {
                if (data.worldLevelConst(entity) == null) {
                    try data.setWorldLevel(entity, entry.level);
                }
            }
        }
    }

    if (try dig.applyPlaneTraversal(world, data, player)) |change| {
        scratch.appendAssumeCapacity(change);
    }
    for (ai_slice.entities) |entity| {
        const entry = npcCellEntry(world, data, scope_columns, entity) orelse continue;
        const result = try dig.applyEntityPlaneTraversal(world, data, entity, entry.level, entry.cell);
        if (result.tile_change) |change| {
            scratch.appendAssumeCapacity(change);
        }
    }
    try frame.publishWorldTileChanges(scratch.items);
}

const NpcCellEntry = struct {
    level: u16,
    cell: CellCoord,
};

/// Player cell-entry probe for preflight: new cell this step (vs `player_last_cell`).
fn playerCellEntry(
    dig: *const DigController,
    world: *const WorldSystem,
    data: *const DataSystem,
    player: Player,
) ?NpcCellEntry {
    const body = data.movementBodyConst(player.entity) orelse return null;
    const visual = data.primitiveVisualConst(player.entity) orelse return null;
    const center_x = body.position.x + visual.size.x * 0.5;
    const center_y = body.position.y + visual.size.y * 0.5;
    const target = world.cellContaining(center_x, center_y) orelse return null;
    const cell = CellCoord{ .x = target.x, .y = target.y };
    if (dig.player_last_cell) |last| {
        if (last.x == cell.x and last.y == cell.y) return null;
    }
    return .{ .level = player.current_level, .cell = cell };
}

/// NPC cell-entry probe: previous vs current body centers, skipping dormant tiers.
/// Returns null when the NPC did not enter a new cell this step. Prefers the
/// `world_level` component; falls back to the movement-scope level so a missing
/// component can still be pre-attached before any carve (multi-entity safety).
fn npcCellEntry(
    world: *const WorldSystem,
    data: *const DataSystem,
    scope_columns: ConstScopeColumnsSlice,
    entity: EntityId,
) ?NpcCellEntry {
    const dense_index = data.movementBodyDenseIndex(entity) orelse return null;
    if (!scope_columns.tier[dense_index].allowsMovement()) return null;
    const level = data.worldLevelConst(entity) orelse scope_columns.level[dense_index];
    const body = data.movementBodyConst(entity) orelse return null;
    const visual = data.primitiveVisualConst(entity) orelse return null;
    const prev_center_x = body.previous_position.x + visual.size.x * 0.5;
    const prev_center_y = body.previous_position.y + visual.size.y * 0.5;
    const center_x = body.position.x + visual.size.x * 0.5;
    const center_y = body.position.y + visual.size.y * 0.5;
    const prev_cell = world.cellContaining(prev_center_x, prev_center_y) orelse return null;
    const cell = world.cellContaining(center_x, center_y) orelse return null;
    if (prev_cell.x == cell.x and prev_cell.y == cell.y) return null;
    return .{ .level = level, .cell = CellCoord{ .x = cell.x, .y = cell.y } };
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
    const scope_columns = data.scopeColumnsSliceConst();
    // Size columns only — no PrimitiveVisual struct rebuild per entity.
    const visuals = data.primitiveVisualSliceConst();
    var movement = data.movementBodySlice();
    // One slot resolve per AI → dense movement/visual indices, then pure SoA
    // column writes. Matches the tile-gate path so bounds + gate share the same
    // index resolve shape (not dual movementBodyPtr + visual index lookups).
    for (ai_slice.entities) |entity| {
        const indices = data.movementVisualDenseIndices(entity) orelse continue;
        const mi = indices.movement;
        // Dormant rows did not integrate this step; re-clamping settled poses is
        // dead work (same skip policy as gateNpcEntitiesToWalkableTiles).
        if (!scope_columns.tier[mi].allowsMovement()) continue;

        const max_x = bounds_width - visuals.size_x[indices.visual];
        const new_x = math.clamp(movement.position_x[mi], 0, max_x);
        if (new_x != movement.position_x[mi]) movement.velocity_x[mi] = 0;
        movement.position_x[mi] = new_x;

        const max_y = bounds_height - visuals.size_y[indices.visual];
        const new_y = math.clamp(movement.position_y[mi], 0, max_y);
        if (new_y != movement.position_y[mi]) movement.velocity_y[mi] = 0;
        movement.position_y[mi] = new_y;
    }
}

test "stageContract(.ai_decide) reads affect_drives, written by affect_update one stage earlier" {
    const contract = stageContract(.ai_decide);
    try std.testing.expect(contract.reads.contains(.affect_drives));
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

test "pipeline commits the dig stage's world edit before plane traversal reads it in the same step" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    // Both stages declare `world_tiles` (dig writes, plane_traversal reads), so
    // the comptime reads-before-writes check already requires dig first. This
    // causal test still proves the real call-site order: dig's hole is live for
    // plane_traversal in the same step (misordering leaves the tile solid).
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    var world = try testMinimalMultiLevelWorld(&meta);
    defer world.deinit();

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    player.current_level = 0;
    // Player stands at cell (5,3) facing right, so this step's dig punches a
    // hole at (6,3) -- the same cell an NPC crosses into this step.
    placePlayerFlush(&data, player, .{ 5, 3 });
    data.facingPtr(player.entity).?.* = .right;

    try std.testing.expect(!world.denseFloorIsEmpty(0, 6, 3));

    const npc = try data.createEntity();
    try data.setMovementBody(npc, .{});
    try data.setPrimitiveVisual(npc, .{
        .size = .{ .x = 32, .y = 32 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    });
    try data.setAiAgent(npc, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setWorldLevel(npc, 0);
    try data.setSimulationTier(npc, .locomotion);
    {
        const body = data.movementBodyPtr(npc).?;
        body.previous_x.* = 5 * 32;
        body.previous_y.* = 3 * 32;
        body.position_x.* = 5 * 32;
        body.position_y.* = 3 * 32;
        body.velocity_x.* = 2000;
        body.velocity_y.* = 0;
    }

    const dig_config = try DigConfig.fromMeta(&meta);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    try frame.reservePathRequests(2, 2);
    try frame.reserveWorldTileChangesScratch(4);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
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

    frame.beginStep();
    frame.dig_intent = .hole;
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

    // The NPC crossed from (5,3) into the just-dug hole cell (6,3) and fell to
    // level 1 within this same step. That is only reachable if dig_world_edit's
    // tile change committed to `WorldSystem` before plane_traversal read that
    // cell's floor state this step -- a misordering would leave the tile solid
    // until next step and the NPC would not fall yet.
    try std.testing.expectEqual(@as(?u16, 1), data.worldLevelConst(npc));
    const floor1 = world.denseFloorLayerForLevel(1).?;
    try std.testing.expect(!world.denseTileBlocksMovement(floor1, 6, 3));
}

test "pipeline resamples AI wander direction across fixed steps" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    const wanderer = try data.createEntity();
    try data.setMovementBody(wanderer, .{ .position = .{ .x = 10, .y = 10 }, .previous_position = .{ .x = 10, .y = 10 }, .velocity = .{}, .speed = 20 });
    try data.setAiAgent(wanderer, .{ .active_behavior = .wander, .wander_amplitude = 30, .gain_pursue = 0 });

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

test "pipeline runs ai_memory after perception and before ai, feeding memory into AI's cold-pursue retarget" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data); // Spawns at (400, 225).

    const agent = try data.createEntity();
    // Far outside the default AiPerception vision_range (192) from the
    // player, so the real PerceptionSystem pass this step reports the target
    // not visible regardless of hostility.
    try data.setMovementBody(agent, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(agent, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });
    try data.setAiPerception(agent, .{});
    // Memory of the player -- the same entity the pipeline's focus_entity
    // resolves to below -- so arbitration's memory/focus identity match lets the
    // retarget through and this still proves the ai_memory-before-ai order.
    try data.setAiMemory(agent, .{
        .last_known_target = player.entity,
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
    // player's focus_target fallback (400, 225) — the actual end-to-end proof
    // that a cold-perception agent retargets via memory through the real pipeline.
    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), intents.len);
    try std.testing.expectEqual(@as(f32, 0), intents[0].goal.x);
    try std.testing.expectEqual(@as(f32, 100), intents[0].goal.y);
}

test "pipeline does not retarget a cold agent toward memory of an entity other than the current focus entity" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data); // Spawns at (400, 225); this is the pipeline's focus_entity.

    // A throwaway entity the agent glimpsed earlier, disconnected from the
    // player. Memory of it must not be trusted as a substitute for the live
    // player-seek goal, even though it is fresh and valid.
    const other_target = try data.createEntity();
    const agent = try data.createEntity();
    // Far outside the default AiPerception vision_range (192) from the
    // player, so the real PerceptionSystem pass this step reports the target
    // not visible regardless of hostility.
    try data.setMovementBody(agent, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(agent, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });
    try data.setAiPerception(agent, .{});
    try data.setAiMemory(agent, .{
        .last_known_target = other_target,
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

    // Memory is fresh and valid, but belongs to `other_target`, not the
    // configured `focus_target` fallback entity -- arbitration's identity
    // check must reject it, so the goal falls through to the live player
    // focus_target (400, 225), not snap to (0, 100).
    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), intents.len);
    try std.testing.expectEqual(@as(f32, 400), intents[0].goal.x);
    try std.testing.expectEqual(@as(f32, 225), intents[0].goal.y);
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
    try data.setAiAgent(observer, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setFaction(observer, .player);
    try data.setAiPerception(observer, .{});
    try data.setAiAffect(observer, .{ .decay_rate_fear = 0.5, .decay_rate_aggression = 0.5 });

    const hostile = try data.createEntity();
    try data.setMovementBody(hostile, .{ .position = .{ .x = 10, .y = 0 }, .previous_position = .{ .x = 10, .y = 0 }, .velocity = .{}, .speed = 0 });
    try data.setAiAgent(hostile, .{ .active_behavior = .wander, .gain_pursue = 0 });
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

test "pipeline resolves an aggressive non-player entity's pursue goal to another non-player entity, not the player" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    // Push the player well outside every AiPerception's default vision_range
    // (240) so it never becomes a perceived/fallback candidate this step --
    // isolating the point of this test: the pursuer's goal comes from its own
    // perceived hostile, not the pipeline's focus_target fallback.
    const player_body = data.movementBodyPtr(player.entity).?;
    player_body.position_x.* = 5000;
    player_body.position_y.* = 5000;
    player_body.previous_x.* = 5000;
    player_body.previous_y.* = 5000;

    const pursuer = try data.createEntity();
    try data.setMovementBody(pursuer, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(pursuer, .{ .active_behavior = .wander, .wander_amplitude = 0, .gain_pursue = 1.0 });
    try data.setFaction(pursuer, .player);
    try data.setAiPerception(pursuer, .{});

    // Kept inside the 1x1, 32px-tile world below (see the LOS comment on
    // `world.addLevel`) so the real LOS raycast doesn't fail closed on an
    // out-of-bounds endpoint.
    const target = try data.createEntity();
    try data.setMovementBody(target, .{ .position = .{ .x = 10, .y = 0 }, .previous_position = .{ .x = 10, .y = 0 }, .velocity = .{}, .speed = 0 });
    try data.setAiAgent(target, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setFaction(target, .hostile);

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

    // The pursuer's real perception saw `target` (close, hostile stance) this
    // step, so arbitration resolves its pursue goal to `target`'s position --
    // proving the pipeline no longer forces every agent's goal onto the
    // player, even though the player-broadcast focus_target/focus_entity pair
    // remains wired as the (unused here) opt-in fallback.
    const intents = frame.navigation_intents.mergedItems();
    var found = false;
    for (intents) |intent| {
        if (intent.entity.index != pursuer.index or intent.entity.generation != pursuer.generation) continue;
        found = true;
        try std.testing.expectEqual(@as(f32, 10), intent.goal.x);
        try std.testing.expectEqual(@as(f32, 0), intent.goal.y);
    }
    try std.testing.expect(found);
}

const AssetStore = @import("../assets/assets.zig").AssetStore;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");

/// Minimal multi-level grass/dirt world for dig/plane/gate pipeline tests.
/// 8×8 tiles cover cell fixtures around (3..6, 3) without full 320 demo paint.
fn testMinimalMultiLevelWorld(meta: *const world_tileset_meta.WorldTilesetMeta) !WorldSystem {
    const bounds = meta.tileSize() * 8;
    return WorldSystem.initDemoFromMetaWithUnderground(std.testing.allocator, meta, bounds, bounds);
}

// Builds a 3-level minimal world and carves the given level-1 cells walkable so a
// player body can sit in one and try to move into solid dirt around it.
fn gateTestWorld(meta: *const world_tileset_meta.WorldTilesetMeta, carve: []const [2]u16) !WorldSystem {
    var world = try testMinimalMultiLevelWorld(meta);
    errdefer world.deinit();
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
    var world = try testMinimalMultiLevelWorld(&meta);
    defer world.deinit();

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
    try data.setAiAgent(dormant_npc, .{ .active_behavior = .wander, .gain_pursue = 0 });
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
    try data.setAiAgent(active_npc, .{ .active_behavior = .wander, .gain_pursue = 0 });
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
    try data.setAiAgent(observer, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setAiPerception(observer, .{ .vision_range = 100 });

    // Locomotion-tier: `gatherAiAgentIndices` excludes it (tier.allowsCognition()
    // is false), so it must never enter perception's gather either — proves
    // perception shares AI's exact scoped population rather than its own.
    const out_of_scope = try data.createEntity();
    try data.setMovementBody(out_of_scope, .{ .position = .{ .x = 60, .y = 60 }, .previous_position = .{ .x = 60, .y = 60 }, .velocity = .{}, .speed = 20 });
    try data.setAiAgent(out_of_scope, .{ .active_behavior = .wander, .gain_pursue = 0 });
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
    try data.setAiAgent(observer_a, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setFaction(observer_a, .player);
    try data.setAiPerception(observer_a, .{});
    const hostile_a = try data.createEntity();
    try data.setMovementBody(hostile_a, .{ .position = .{ .x = 10, .y = 0 }, .previous_position = .{ .x = 10, .y = 0 }, .velocity = .{}, .speed = 0 });
    try data.setAiAgent(hostile_a, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setFaction(hostile_a, .hostile);

    const observer_b = try data.createEntity();
    try data.setMovementBody(observer_b, .{ .position = .{ .x = 100, .y = 0 }, .previous_position = .{ .x = 100, .y = 0 }, .velocity = .{ .x = 10, .y = 0 }, .speed = 20 });
    try data.setAiAgent(observer_b, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setFaction(observer_b, .player);
    try data.setAiPerception(observer_b, .{});
    const hostile_b = try data.createEntity();
    try data.setMovementBody(hostile_b, .{ .position = .{ .x = 110, .y = 0 }, .previous_position = .{ .x = 110, .y = 0 }, .velocity = .{}, .speed = 0 });
    try data.setAiAgent(hostile_b, .{ .active_behavior = .wander, .gain_pursue = 0 });
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

test "pipeline commits the dig stage's world edit before the tile gate reads walkability in the same step" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    // Both stages declare `world_tiles` (dig writes, bounds_and_tile_gate reads),
    // so the comptime check requires dig first. This causal test proves the real
    // call-site order: an underground NPC walks into a cell this step's dig mines
    // walkable, and the gate must NOT revert it. Underground (level 1) is required
    // because the gate is a deliberate no-op on the surface.
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    var world = try testMinimalMultiLevelWorld(&meta);
    defer world.deinit();

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    player.current_level = 1;
    // Player stands underground at cell (5,3) facing right, so this step's dig
    // mines a walkable tunnel at (6,3) -- the cell the NPC crosses into.
    placePlayerFlush(&data, player, .{ 5, 3 });
    data.facingPtr(player.entity).?.* = .right;

    // Level 1 is solid dirt: the forward cell blocks movement until dig mines it.
    try std.testing.expect(world.levelBlocksMovement(1, 6, 3));

    const npc = try data.createEntity();
    try data.setMovementBody(npc, .{});
    try data.setPrimitiveVisual(npc, .{
        .size = .{ .x = 32, .y = 32 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    });
    try data.setAiAgent(npc, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setWorldLevel(npc, 1);
    try data.setSimulationTier(npc, .locomotion);
    {
        const body = data.movementBodyPtr(npc).?;
        body.previous_x.* = 5 * 32;
        body.previous_y.* = 3 * 32;
        body.position_x.* = 5 * 32;
        body.position_y.* = 3 * 32;
        // 2000 * 0.016 == one 32px tile: integration lands the body in cell (6,3).
        body.velocity_x.* = 2000;
        body.velocity_y.* = 0;
    }

    const dig_config = try DigConfig.fromMeta(&meta);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    try frame.reservePathRequests(2, 2);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
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

    frame.beginStep();
    frame.dig_intent = .hole;
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

    // The dig mined (6,3) walkable this step, so the gate let the NPC keep its
    // move into that cell. A misordering would leave (6,3) solid when the gate
    // read it and revert the NPC back to cell (5,3).
    try std.testing.expect(!world.levelBlocksMovement(1, 6, 3));
    const npc_body = data.movementBodyPtr(npc).?;
    const npc_cell = world.cellContaining(npc_body.position_x.* + 16, npc_body.position_y.* + 16).?;
    try std.testing.expectEqual(@as(u16, 6), npc_cell.x);
    try std.testing.expectEqual(@as(u16, 3), npc_cell.y);
    // The mined cell is a walkable tunnel (not a hole), so the NPC stays on level 1.
    try std.testing.expectEqual(@as(?u16, 1), data.worldLevelConst(npc));
}

test "stageContract declares world_tiles reads for gate, plane traversal, and perception" {
    try std.testing.expect(stageContract(.bounds_and_tile_gate).reads.contains(.world_tiles));
    try std.testing.expect(stageContract(.plane_traversal).reads.contains(.world_tiles));
    try std.testing.expect(stageContract(.perception_update).reads.contains(.world_tiles));
    try std.testing.expect(stageContract(.dig_world_edit).writes.contains(.world_tiles));
}

test "pipeline tile gate after collision response rejects contact push into solid underground dirt" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    // Causal: collision_respond can push a body into solid underground tiles.
    // bounds_and_tile_gate must run AFTER response so the end-of-step pose is
    // walkable. A pre-collision-only gate would leave the body embedded.
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    // Single walkable pocket at (3,3); neighbors stay solid dirt.
    var world = try gateTestWorld(&meta, &.{.{ 3, 3 }});
    defer world.deinit();

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    player.current_level = 1;
    placePlayerFlush(&data, player, .{ 3, 3 });
    // Player collides so response can shove them into solid (4,3).
    try data.setCollisionBounds(player.entity, .{ .size = .{ .x = 32, .y = 32 } });
    try data.setCollisionResponse(player.entity, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    try data.setWorldLevel(player.entity, 1);

    // Static solid body overlapping the player from the left; response separates
    // the dynamic player along +x into solid dirt at cell (4,3).
    const wall = try data.createEntity();
    try data.setMovementBody(wall, .{
        .position = .{ .x = 3 * 32 - 16, .y = 3 * 32 },
        .previous_position = .{ .x = 3 * 32 - 16, .y = 3 * 32 },
        .velocity = .{},
        .speed = 0,
    });
    try data.setCollisionBounds(wall, .{ .size = .{ .x = 32, .y = 32 } });
    try data.setCollisionResponse(wall, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    try data.setWorldLevel(wall, 1);
    try data.setSimulationTier(wall, .locomotion);

    // Sanity: (4,3) is solid; player starts flush in the carved pocket.
    try std.testing.expect(world.levelBlocksMovement(1, 4, 3));
    try std.testing.expect(!world.levelBlocksMovement(1, 3, 3));

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    try frame.reservePathRequests(2, 2);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 8,
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
    // Keep previous == start so a post-response gate can slide back to the pocket.
    // Zero velocity so movement does not walk out on its own.
    {
        const body = data.movementBodyPtr(player.entity).?;
        body.velocity_x.* = 0;
        body.velocity_y.* = 0;
    }
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

    const body = data.movementBodyConst(player.entity).?;
    // End-of-step pose must not overlap solid tiles on level 1.
    try std.testing.expect(!rectOverlapsSolidTile(&world, 1, body.position.x, body.position.y, 32, 32));
    // And should remain in/near the carved pocket rather than deep in solid dirt.
    const cell = world.cellContaining(body.position.x + 16, body.position.y + 16).?;
    try std.testing.expectEqual(@as(u16, 3), cell.x);
    try std.testing.expectEqual(@as(u16, 3), cell.y);
}

test "pipeline chunk_derive after collision pose settle matches settled world position" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    // Causal: chunk_derive must run AFTER collision_respond (and gate/plane) so
    // scope chunk columns match the settled pose. If derive ran before response,
    // a contact push across a chunk boundary would leave stale chunk_* columns.
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    // 16 tiles wide × default chunk_size 8 → two chunks on X. Surface (level 0)
    // is fully walkable so the tile gate cannot undo the contact push.
    const tile_size = meta.tileSize();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, tile_size * 16, tile_size * 8);
    defer world.deinit();
    try std.testing.expectEqual(@as(u16, 8), world.chunk_size_tiles);

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    player.current_level = 0;
    // Cell 7 is still chunk 0; a deep +x solid push must land at x>=256 (cell 8, chunk 1).
    placePlayerFlush(&data, player, .{ 7, 3 });
    try data.setCollisionBounds(player.entity, .{ .size = .{ .x = 32, .y = 32 } });
    try data.setCollisionResponse(player.entity, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    try data.setWorldLevel(player.entity, 0);
    // Seed stale chunk columns at the pre-response cell (chunk 0).
    {
        const mi = data.movementBodyDenseIndex(player.entity).?;
        const scope = data.scopeColumnsSlice();
        scope.chunk_x[mi] = 0;
        scope.chunk_y[mi] = 0;
    }

    // Static wall overlaps the player with pen_x=32 < pen_y so the contact normal
    // is +x and the full 32px correction lands the body in chunk 1.
    const wall = try data.createEntity();
    try data.setMovementBody(wall, .{
        .position = .{ .x = 6 * 32, .y = 3 * 32 - 6 },
        .previous_position = .{ .x = 6 * 32, .y = 3 * 32 - 6 },
        .velocity = .{},
        .speed = 0,
    });
    try data.setCollisionBounds(wall, .{ .size = .{ .x = 64, .y = 40 } });
    try data.setCollisionResponse(wall, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    try data.setWorldLevel(wall, 0);
    try data.setSimulationTier(wall, .locomotion);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    try frame.reservePathRequests(2, 2);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 8,
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
    {
        const body = data.movementBodyPtr(player.entity).?;
        body.velocity_x.* = 0;
        body.velocity_y.* = 0;
    }
    _ = try pipeline.update(.{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = tile_size * 16,
        .bounds_height = tile_size * 8,
    });

    const body = data.movementBodyConst(player.entity).?;
    const settled = world.chunkCoordForWorldPos(body.position.x, body.position.y);
    const meta_after = data.simulationMetadata(player.entity).?;
    try std.testing.expectEqual(settled.x, meta_after.chunk.x);
    try std.testing.expectEqual(settled.y, meta_after.chunk.y);
    // Contact must have crossed the chunk-0 / chunk-1 boundary (cell 8 = chunk 1).
    try std.testing.expect(settled.x >= 1);
}

test "pipeline plane traversal batches fall landing tile events into one range" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    // Two NPCs fall through surface holes in the same step; both landing carves
    // must publish as world_tile_changed events that share ONE events range
    // (single finishWrite batch, not per-fall appendRequired).
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    var world = try testMinimalMultiLevelWorld(&meta);
    defer world.deinit();

    const floor0 = world.denseFloorLayerForLevel(0).?;
    _ = try world.clearDenseTile(floor0, 4, 3);
    _ = try world.clearDenseTile(floor0, 6, 3);

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    // Park the player away from the holes so only the NPCs fall.
    placePlayerFlush(&data, player, .{ 1, 1 });

    const dig_config = try DigConfig.fromMeta(&meta);
    inline for (.{ [2]u16{ 4, 3 }, [2]u16{ 6, 3 } }) |cell| {
        const npc = try data.createEntity();
        try data.setMovementBody(npc, .{});
        try data.setPrimitiveVisual(npc, .{
            .size = .{ .x = 32, .y = 32 },
            .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
            .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        });
        try data.setAiAgent(npc, .{ .active_behavior = .wander, .gain_pursue = 0 });
        try data.setWorldLevel(npc, 0);
        try data.setSimulationTier(npc, .locomotion);
        const body = data.movementBodyPtr(npc).?;
        // Start on the west neighbor: movement integrates previous→current, so a
        // pre-set "already on the hole" pose collapses to same-cell before plane
        // traversal (velocity 0) and never fires a cell-entry fall. Match the dig
        // causal fixture: 2000 * 0.016 == one 32px tile into the hole this step.
        const start_x = @as(f32, @floatFromInt(cell[0] - 1)) * 32;
        const start_y = @as(f32, @floatFromInt(cell[1])) * 32;
        body.previous_x.* = start_x;
        body.previous_y.* = start_y;
        body.position_x.* = start_x;
        body.position_y.* = start_y;
        body.velocity_x.* = 2000;
        body.velocity_y.* = 0;
    }

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 16, 8, 8, 8, 8);
    try frame.reservePathRequests(2, 2);
    try frame.reserveWorldTileChangesScratch(4);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
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

    var tile_events: usize = 0;
    for (frame.events.mergedItems()) |event| {
        switch (event.payload) {
            .world_tile_changed => tile_events += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), tile_events);
    // Strong M7 contract: both landing carves share one events range (batched
    // publishWorldTileChanges), not two appendRequired ranges of one each.
    var batch_ranges: usize = 0;
    for (frame.events.range_stats.items) |range_stat| {
        if (range_stat.world_tile_changed >= 2) batch_ranges += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), batch_ranges);
    try std.testing.expectEqual(@as(usize, 2), frame.events.stats.world_tile_changed);

    const floor1 = world.denseFloorLayerForLevel(1).?;
    try std.testing.expect(!world.denseTileBlocksMovement(floor1, 4, 3));
    try std.testing.expect(!world.denseTileBlocksMovement(floor1, 6, 3));
}

test "plane traversal event capacity miss leaves landing tiles unchanged" {
    // Mirrors dig process capacity-miss proof: stage preflights events before
    // any carve so a zero budget cannot leave landings walkable without publish.
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    var world = try testMinimalMultiLevelWorld(&meta);
    defer world.deinit();

    const floor0 = world.denseFloorLayerForLevel(0).?;
    _ = try world.clearDenseTile(floor0, 4, 3);
    const floor1 = world.denseFloorLayerForLevel(1).?;
    const landing_before = world.denseTile(floor1, 4, 3);
    try std.testing.expect(world.denseTileBlocksMovement(floor1, 4, 3));

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    placePlayerFlush(&data, player, .{ 1, 1 });

    const dig_config = try DigConfig.fromMeta(&meta);
    const npc = try data.createEntity();
    try data.setMovementBody(npc, .{});
    try data.setPrimitiveVisual(npc, .{
        .size = .{ .x = 32, .y = 32 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    });
    try data.setAiAgent(npc, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setWorldLevel(npc, 0);
    try data.setSimulationTier(npc, .locomotion);
    // Cell entry this step: previous west neighbor, current over the hole.
    const body = data.movementBodyPtr(npc).?;
    body.previous_x.* = 3 * 32;
    body.previous_y.* = 3 * 32;
    body.position_x.* = 4 * 32;
    body.position_y.* = 3 * 32;

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 0, 8, 8, 8, 8);
    try frame.reserveWorldTileChangesScratch(4);
    frame.beginStep();
    frame.events.setCapacityLimit(0);

    var dig = DigController.init(dig_config);
    try std.testing.expectError(
        error.EventCapacityExceeded,
        applyPlaneTraversalStage(&dig, &world, &data, &player, &frame),
    );
    try std.testing.expectEqual(landing_before, world.denseTile(floor1, 4, 3));
    try std.testing.expect(world.denseTileBlocksMovement(floor1, 4, 3));
    try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);
}

test "plane traversal multi-entity world_level attach OOM leaves landings uncarved" {
    // M8: two NPCs missing world_level over holes. Stage reserves attach capacity
    // and attaches both before any carve — so OOM on capacity leaves both landings
    // solid (no mid-loop carve without matching events). Avoid Player.spawn: it
    // pre-grows world_levels and can hide the attach allocation.
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    var world = try testMinimalMultiLevelWorld(&meta);
    defer world.deinit();

    const floor0 = world.denseFloorLayerForLevel(0).?;
    _ = try world.clearDenseTile(floor0, 4, 3);
    _ = try world.clearDenseTile(floor0, 6, 3);
    const floor1 = world.denseFloorLayerForLevel(1).?;
    const landing_a = world.denseTile(floor1, 4, 3);
    const landing_b = world.denseTile(floor1, 6, 3);

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Bare player shell (no world_level) parked off the holes.
    const player_entity = try data.createEntity();
    try data.setMovementBody(player_entity, .{});
    try data.setPrimitiveVisual(player_entity, .{
        .size = .{ .x = 32, .y = 32 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    });
    var player = Player{ .entity = player_entity, .current_level = 0 };
    placePlayerFlush(&data, player, .{ 1, 1 });
    // Seed last_cell so the parked player is not a cell-entry candidate.
    const dig_config = try DigConfig.fromMeta(&meta);
    var dig = DigController.init(dig_config);
    dig.player_last_cell = .{ .x = 1, .y = 1 };

    try std.testing.expectEqual(@as(usize, 0), data.world_levels.len());

    inline for (.{ [2]u16{ 4, 3 }, [2]u16{ 6, 3 } }) |cell| {
        const npc = try data.createEntity();
        try data.setMovementBody(npc, .{});
        try data.setPrimitiveVisual(npc, .{
            .size = .{ .x = 32, .y = 32 },
            .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
            .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        });
        try data.setAiAgent(npc, .{ .active_behavior = .wander, .gain_pursue = 0 });
        try data.setSimulationTier(npc, .locomotion);
        try std.testing.expect(data.worldLevelConst(npc) == null);
        const body = data.movementBodyPtr(npc).?;
        body.previous_x.* = @as(f32, @floatFromInt(cell[0] - 1)) * 32;
        body.previous_y.* = @as(f32, @floatFromInt(cell[1])) * 32;
        body.position_x.* = @as(f32, @floatFromInt(cell[0])) * 32;
        body.position_y.* = @as(f32, @floatFromInt(cell[1])) * 32;
    }

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 16, 8, 8, 8, 8);
    try frame.reserveWorldTileChangesScratch(4);
    frame.beginStep();

    // Fail the first data allocation (world_levels ensureCapacity / attach).
    const original = data.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    data.allocator = failing.allocator();
    defer data.allocator = original;

    try std.testing.expectError(
        error.OutOfMemory,
        applyPlaneTraversalStage(&dig, &world, &data, &player, &frame),
    );
    try std.testing.expectEqual(landing_a, world.denseTile(floor1, 4, 3));
    try std.testing.expectEqual(landing_b, world.denseTile(floor1, 6, 3));
    try std.testing.expectEqual(@as(usize, 0), frame.events.stats.world_tile_changed);
}

test "plane traversal multi-fall after scratch reserve is allocation-free (FailingAllocator)" {
    // M9: warm scratch + event capacity, arm FA at index 0, two falls publish
    // with zero further allocations on the frame / events / data paths used.
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    var world = try testMinimalMultiLevelWorld(&meta);
    defer world.deinit();

    const floor0 = world.denseFloorLayerForLevel(0).?;
    _ = try world.clearDenseTile(floor0, 4, 3);
    _ = try world.clearDenseTile(floor0, 6, 3);

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    placePlayerFlush(&data, player, .{ 1, 1 });

    const dig_config = try DigConfig.fromMeta(&meta);
    inline for (.{ [2]u16{ 4, 3 }, [2]u16{ 6, 3 } }) |cell| {
        const npc = try data.createEntity();
        try data.setMovementBody(npc, .{});
        try data.setPrimitiveVisual(npc, .{
            .size = .{ .x = 32, .y = 32 },
            .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
            .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        });
        try data.setAiAgent(npc, .{ .active_behavior = .wander, .gain_pursue = 0 });
        try data.setWorldLevel(npc, 0);
        try data.setSimulationTier(npc, .locomotion);
        const body = data.movementBodyPtr(npc).?;
        body.previous_x.* = @as(f32, @floatFromInt(cell[0] - 1)) * 32;
        body.previous_y.* = @as(f32, @floatFromInt(cell[1])) * 32;
        body.position_x.* = @as(f32, @floatFromInt(cell[0])) * 32;
        body.position_y.* = @as(f32, @floatFromInt(cell[1])) * 32;
    }

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 16, 8, 8, 8, 8);
    try frame.reserveWorldTileChangesScratch(4);
    // Warm the exact event append path the stage preflights + publishes through.
    try frame.events.ensureEventAppendCapacity(2);
    frame.beginStep();
    // beginStep clears counts but retains capacity — re-warm event value capacity
    // after clear so ensureEventAppendCapacity(2) inside the stage is free.
    try frame.events.ensureEventAppendCapacity(2);

    const original_frame = frame.allocator;
    const original_events = frame.events.stream.allocator;
    const original_data = data.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const fail_alloc = failing.allocator();
    frame.allocator = fail_alloc;
    frame.events.stream.allocator = fail_alloc;
    data.allocator = fail_alloc;
    defer {
        frame.allocator = original_frame;
        frame.events.stream.allocator = original_events;
        data.allocator = original_data;
    }

    var dig = DigController.init(dig_config);
    try applyPlaneTraversalStage(&dig, &world, &data, &player, &frame);

    try std.testing.expectEqual(@as(usize, 2), frame.events.stats.world_tile_changed);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    const floor1 = world.denseFloorLayerForLevel(1).?;
    try std.testing.expect(!world.denseTileBlocksMovement(floor1, 4, 3));
    try std.testing.expect(!world.denseTileBlocksMovement(floor1, 6, 3));
}

test "pipeline commits the dig stage's stimulus before perception reads it in the same step" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    // `dig_world_edit` appends a `.dig` `WorldStimulus` to `frame.stimuli`, which
    // `perception_update` consumes for hearing. The two share no tracked
    // `PipelineResource`, and `frame.stimuli` is cleared each `beginStep`, so a
    // stimulus produced after perception would be silently dropped. Prove the real
    // order runs dig first: an in-earshot AI observer hears this step's dig.
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    var world = try testMinimalMultiLevelWorld(&meta);
    defer world.deinit();

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    player.current_level = 0;
    // Player at cell (5,3) facing right punches a hole at (6,3) on level 0, whose
    // cell-center is the stimulus position.
    placePlayerFlush(&data, player, .{ 5, 3 });
    data.facingPtr(player.entity).?.* = .right;

    // Cognition-tier AiPerception observer at cell (7,3) -- within earshot of the
    // dig cell (6,3), same level, but far enough that it never steps onto the hole.
    // gain_pursue 0 with only neutral factions present means no visible target.
    const observer = try data.createEntity();
    try data.setMovementBody(observer, .{ .position = .{ .x = 7 * 32, .y = 3 * 32 }, .previous_position = .{ .x = 7 * 32, .y = 3 * 32 }, .velocity = .{}, .speed = 0 });
    try data.setAiAgent(observer, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setWorldLevel(observer, 0);
    try data.setAiPerception(observer, .{ .hearing_range = 1000 });

    // Sanity: the observer does not hear anything before the step runs.
    try std.testing.expect(!data.aiPerceptionConst(observer).?.heard_stimulus);

    const dig_config = try DigConfig.fromMeta(&meta);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    try frame.reservePathRequests(2, 2);
    try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 4,
        .dig = dig_config,
        .perception_max_events_per_step = 4,
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
    frame.dig_intent = .hole;
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

    // The observer heard this step's dig, which is only possible if dig produced
    // the stimulus before perception read `frame.stimuli` this step -- perception
    // running first would find the (freshly cleared) stimulus stream empty.
    try std.testing.expect(data.aiPerceptionConst(observer).?.heard_stimulus);
}

test "pipeline promotes deferred impacts before perception on the following step" {
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

    const impact_x: f32 = 200;
    const impact_y: f32 = 220;
    const observer = try data.createEntity();
    try data.setMovementBody(observer, .{
        .position = .{ .x = impact_x + 40, .y = impact_y },
        .previous_position = .{ .x = impact_x + 40, .y = impact_y },
        .velocity = .{},
        .speed = 0,
    });
    try data.setAiAgent(observer, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setWorldLevel(observer, 0);
    try data.setSimulationTier(observer, .cognition);
    try data.setAiPerception(observer, .{ .hearing_range = 500 });

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    try frame.reservePathRequests(2, 2);
    try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 4,
        .movement_body_capacity = 4,
        .perception_max_events_per_step = 4,
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

    // Simulate a collision impact deferred at the end of the prior step.
    pipeline.deferred_stimuli[0] = .{
        .position = .{ .x = impact_x, .y = impact_y },
        .intensity = defaultStimulusIntensity(.impact),
        .kind = .impact,
        .level = 0,
    };
    pipeline.deferred_stimulus_count = 1;

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

    const perception = data.aiPerceptionConst(observer).?;
    try std.testing.expect(perception.heard_stimulus);
    try std.testing.expectApproxEqAbs(impact_x, perception.heard_stimulus_x, 0.01);
    try std.testing.expectApproxEqAbs(impact_y, perception.heard_stimulus_y, 0.01);
    try std.testing.expectEqual(@as(usize, 0), pipeline.deferred_stimulus_count);
}

test "pipeline defers player collision impacts until the next step" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    try data.setCollisionBounds(player.entity, .{ .size = .{ .x = 32, .y = 32 } });
    const body = data.movementBodyPtr(player.entity).?;
    body.position_x.* = 100;
    body.position_y.* = 100;
    body.previous_x.* = 100;
    body.previous_y.* = 100;
    body.velocity_x.* = 0;
    body.velocity_y.* = 0;

    const blocker = try data.createEntity();
    try data.setMovementBody(blocker, .{
        .position = .{ .x = 110, .y = 100 },
        .previous_position = .{ .x = 110, .y = 100 },
        .velocity = .{ .x = -80, .y = 0 },
        .speed = 80,
    });
    try data.setCollisionBounds(blocker, .{ .size = .{ .x = 32, .y = 32 } });
    try data.setSimulationTier(blocker, .locomotion);

    const observer = try data.createEntity();
    try data.setMovementBody(observer, .{
        .position = .{ .x = 130, .y = 100 },
        .previous_position = .{ .x = 130, .y = 100 },
        .velocity = .{},
        .speed = 0,
    });
    try data.setAiAgent(observer, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setWorldLevel(observer, 0);
    try data.setSimulationTier(observer, .cognition);
    try data.setAiPerception(observer, .{ .hearing_range = 500 });

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
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    try frame.reservePathRequests(2, 2);
    try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 8,
        .movement_body_capacity = 8,
        .perception_max_events_per_step = 4,
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
    try std.testing.expect(stats.collision.contact_count > 0);
    try std.testing.expectEqual(@as(usize, 1), pipeline.deferred_stimulus_count);
    try std.testing.expectEqual(@import("simulation.zig").StimulusKind.impact, pipeline.deferred_stimuli[0].kind);
    try std.testing.expect(!data.aiPerceptionConst(observer).?.heard_stimulus);

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
    try std.testing.expect(data.aiPerceptionConst(observer).?.heard_stimulus);
}

test "head-on player impact enqueues even after collision response zeroes approach velocity" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    try data.setCollisionBounds(player.entity, .{ .size = .{ .x = 32, .y = 32 } });
    try data.setCollisionResponse(player.entity, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    const body = data.movementBodyPtr(player.entity).?;
    body.position_x.* = 100;
    body.position_y.* = 100;
    body.previous_x.* = 100;
    body.previous_y.* = 100;
    body.velocity_x.* = 120;
    body.velocity_y.* = 0;

    // Static solid wall directly in the player's path: response zeroes the
    // player's approach velocity this step, so eligibility must rely on the
    // contact's pre-response snapshot rather than the post-response columns.
    const wall = try data.createEntity();
    try data.setMovementBody(wall, .{
        .position = .{ .x = 120, .y = 100 },
        .previous_position = .{ .x = 120, .y = 100 },
        .velocity = .{},
        .speed = 0,
    });
    try data.setCollisionBounds(wall, .{ .size = .{ .x = 32, .y = 32 } });
    try data.setCollisionResponse(wall, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    try data.setWorldLevel(wall, 0);
    try data.setSimulationTier(wall, .locomotion);

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
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    try frame.reservePathRequests(2, 2);
    try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 8,
        .movement_body_capacity = 8,
        .perception_max_events_per_step = 4,
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
    frame.dig_intent = .none;
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

    try std.testing.expect(stats.collision.contact_count > 0);
    // Response ran and zeroed the approach axis; the old post-response read would
    // see this and drop the impact. The snapshot-based gate must not.
    try std.testing.expectEqual(@as(f32, 0), data.movementBodyConst(player.entity).?.velocity.x);
    try std.testing.expectEqual(@as(usize, 1), pipeline.deferred_stimulus_count);
    try std.testing.expectEqual(@import("simulation.zig").StimulusKind.impact, pipeline.deferred_stimuli[0].kind);
}

test "pipeline emits player footstep stimulus before perception in the same step" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    const pbody = data.movementBodyPtr(player.entity).?;
    pbody.position_x.* = 5 * 32;
    pbody.position_y.* = 3 * 32;
    pbody.previous_x.* = 5 * 32;
    pbody.previous_y.* = 3 * 32;
    pbody.velocity_x.* = 120;
    pbody.velocity_y.* = 0;

    const observer = try data.createEntity();
    try data.setMovementBody(observer, .{
        .position = .{ .x = 7 * 32, .y = 3 * 32 },
        .previous_position = .{ .x = 7 * 32, .y = 3 * 32 },
        .velocity = .{},
        .speed = 0,
    });
    try data.setAiAgent(observer, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setWorldLevel(observer, 0);
    try data.setSimulationTier(observer, .cognition);
    try data.setAiPerception(observer, .{ .hearing_range = 1000 });

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
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    try frame.reservePathRequests(2, 2);
    try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 4,
        .movement_body_capacity = 4,
        .perception_max_events_per_step = 4,
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
    frame.dig_intent = .none;
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

    const perception = data.aiPerceptionConst(observer).?;
    try std.testing.expect(perception.heard_stimulus);
    try std.testing.expectApproxEqAbs(@as(f32, 5 * 32), perception.heard_stimulus_x, 0.01);
}

test "deferred impact enqueue drops newest when deferred buffer is full" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);
    try data.setCollisionBounds(player.entity, .{ .size = .{ .x = 32, .y = 32 } });
    const pbody = data.movementBodyPtr(player.entity).?;
    pbody.velocity_x.* = 50;
    pbody.velocity_y.* = 0;
    const other = try data.createEntity();
    try data.setMovementBody(other, .{
        .position = .{ .x = 10, .y = 10 },
        .previous_position = .{ .x = 10, .y = 10 },
        .velocity = .{},
        .speed = 0,
    });
    try data.setCollisionBounds(other, .{ .size = .{ .x = 32, .y = 32 } });

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.contacts.reserve(1, 1);
    const writer = try frame.contacts.appendRangeCounts(1);
    frame.contacts.addCount(writer, 1);
    try frame.contacts.prefixAppendedRanges(writer);
    var contact_writer = frame.contacts.rangeWriter(writer);
    contact_writer.write(.{
        .a = player.entity,
        .b = other,
        .a_movement_index = 0,
        .b_movement_index = 1,
        .normal_x = -1,
        .normal_y = 0,
        .penetration = 4,
        .pre_response_max_speed_sq = 50 * 50,
        .pre_response_relative_speed_sq = 50 * 50,
    });
    contact_writer.finish();
    frame.contacts.finishWrite();

    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 4,
        .pathfinding = .{
            .max_frame_requests = 1,
            .max_pending_requests = 1,
            .max_cached_results = 1,
            .max_group_fields = 1,
            .worker_participant_count = 1,
            .max_solved_requests_per_step = 1,
            .max_fallback_requests_per_step = 1,
        },
    });
    defer pipeline.deinit();
    pipeline.deferred_stimulus_count = stimulus_deferred_capacity;

    var deferred_dropped: usize = 0;
    enqueuePlayerCollisionImpactsToDeferred(
        &pipeline,
        &frame,
        &data,
        player.entity,
        0,
        &deferred_dropped,
    );
    try std.testing.expectEqual(@as(usize, 1), deferred_dropped);
    try std.testing.expectEqual(stimulus_deferred_capacity, pipeline.deferred_stimulus_count);
}

test "promote drops deferred impacts when live bus is already full" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);

    for (0..stimulus_live_capacity) |i| {
        try frame.appendStimulus(.{
            .position = .{ .x = @floatFromInt(i), .y = 0 },
            .intensity = 1,
            .kind = .dig,
            .level = 0,
        });
    }

    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .pathfinding = .{
            .max_frame_requests = 1,
            .max_pending_requests = 1,
            .max_cached_results = 1,
            .max_group_fields = 1,
            .worker_participant_count = 1,
            .max_solved_requests_per_step = 1,
            .max_fallback_requests_per_step = 1,
        },
    });
    defer pipeline.deinit();
    pipeline.deferred_stimuli[0] = .{
        .position = .{ .x = 200, .y = 0 },
        .intensity = defaultStimulusIntensity(.impact),
        .kind = .impact,
        .level = 0,
    };
    pipeline.deferred_stimulus_count = 1;

    var live_dropped: usize = 0;
    const promoted = promoteDeferredStimuli(&pipeline, &frame, &live_dropped);
    try std.testing.expectEqual(@as(usize, 0), promoted);
    try std.testing.expectEqual(@as(usize, 1), live_dropped);
    try std.testing.expectEqual(@as(usize, 1), pipeline.deferred_stimulus_count);
    try std.testing.expectEqual(stimulus_live_capacity, frame.stimuli.mergedItems().len);
}

test "player footstep drops when live bus is full" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);
    const body = data.movementBodyPtr(player.entity).?;
    body.velocity_x.* = 120;
    body.velocity_y.* = 0;

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);
    for (0..stimulus_live_capacity) |i| {
        try frame.appendStimulus(.{
            .position = .{ .x = @floatFromInt(i), .y = 0 },
            .intensity = 1,
            .kind = .dig,
            .level = 0,
        });
    }

    var live_dropped: usize = 0;
    tryAppendPlayerFootstepStimulus(&frame, &data, player, &live_dropped);
    try std.testing.expectEqual(@as(usize, 1), live_dropped);
    try std.testing.expectEqual(stimulus_live_capacity, frame.stimuli.mergedItems().len);
}

test "player collision impacts enqueue at most stimulus_max_impacts_per_step per step" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);
    try data.setCollisionBounds(player.entity, .{ .size = .{ .x = 32, .y = 32 } });
    const pbody = data.movementBodyPtr(player.entity).?;
    pbody.position_x.* = 0;
    pbody.position_y.* = 0;
    pbody.velocity_x.* = 50;
    pbody.velocity_y.* = 0;

    const contact_count = stimulus_max_impacts_per_step + 4;
    var others: [contact_count]EntityId = undefined;
    for (&others, 0..) |*entity, i| {
        entity.* = try data.createEntity();
        try data.setMovementBody(entity.*, .{
            .position = .{ .x = @floatFromInt(20 + i), .y = 0 },
            .previous_position = .{ .x = @floatFromInt(20 + i), .y = 0 },
            .velocity = .{},
            .speed = 0,
        });
        try data.setCollisionBounds(entity.*, .{ .size = .{ .x = 32, .y = 32 } });
    }

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.contacts.reserve(1, contact_count);
    const writer = try frame.contacts.appendRangeCounts(1);
    frame.contacts.addCount(writer, contact_count);
    try frame.contacts.prefixAppendedRanges(writer);
    var contact_writer = frame.contacts.rangeWriter(writer);
    for (others, 0..) |other, i| {
        contact_writer.write(.{
            .a = player.entity,
            .b = other,
            .a_movement_index = 0,
            .b_movement_index = @intCast(i + 1),
            .normal_x = -1,
            .normal_y = 0,
            .penetration = @floatFromInt(4 + i),
            .pre_response_max_speed_sq = 50 * 50,
            .pre_response_relative_speed_sq = 50 * 50,
        });
    }
    contact_writer.finish();
    frame.contacts.finishWrite();

    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .pathfinding = .{
            .max_frame_requests = 1,
            .max_pending_requests = 1,
            .max_cached_results = 1,
            .max_group_fields = 1,
            .worker_participant_count = 1,
            .max_solved_requests_per_step = 1,
            .max_fallback_requests_per_step = 1,
        },
    });
    defer pipeline.deinit();

    var deferred_dropped: usize = 0;
    enqueuePlayerCollisionImpactsToDeferred(
        &pipeline,
        &frame,
        &data,
        player.entity,
        0,
        &deferred_dropped,
    );
    try std.testing.expectEqual(stimulus_max_impacts_per_step, pipeline.deferred_stimulus_count);
    try std.testing.expectEqual(@as(usize, 4), deferred_dropped);
    try std.testing.expectEqual(@import("simulation.zig").StimulusKind.impact, pipeline.deferred_stimuli[0].kind);
    // First contact in merged order wins the first deferred slot (midpoint x = 10).
    try std.testing.expectApproxEqAbs(@as(f32, 10), pipeline.deferred_stimuli[0].position.x, 0.01);
}

test "action_react consumer reports zero intents when no action producers ran" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
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
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try frame.reserveStreams(2, 2, 0, 0, 0, 2);
    frame.beginStep();
    const stats = try DestructibleController.init().process(&frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 0), stats.intents_consumed);
}

test "action_react consumer counts merged action intents" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
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
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try frame.reserveStreams(2, 2, 0, 0, 0, 2);
    try frame.appendActionIntent(.{ .entity = EntityId.invalid, .kind = .interact });
    const stats = try DestructibleController.init().process(&frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.intents_consumed);
}

test "captureActionIntent appends interact on rising edge only and does not dual-write intents" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = 32,
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try frame.reserveStreams(1, 0, 4, 0, 0, 0);

    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 64, 64, .{
        .pathfinding = .{
            .max_frame_requests = 1,
            .max_pending_requests = 1,
            .max_cached_results = 1,
            .max_group_fields = 1,
            .worker_participant_count = 1,
            .max_solved_requests_per_step = 1,
            .max_fallback_requests_per_step = 1,
        },
    });
    defer pipeline.deinit();

    var input = InputState{};
    input.setHeld(.interact, true);
    pipeline.captureActionIntent(&input, &frame, player, &data, &world);
    try std.testing.expectEqual(@as(usize, 1), frame.actionIntentLiveCount());
    try std.testing.expectEqual(@import("simulation.zig").ActionKind.interact, frame.action_intents.mergedItems()[0].kind);
    try std.testing.expectEqual(@as(usize, 0), frame.intents.mergedItems().len);

    pipeline.captureActionIntent(&input, &frame, player, &data, &world);
    try std.testing.expectEqual(@as(usize, 1), frame.actionIntentLiveCount());

    input.setHeld(.interact, false);
    pipeline.captureActionIntent(&input, &frame, player, &data, &world);
    input.setHeld(.interact, true);
    pipeline.captureActionIntent(&input, &frame, player, &data, &world);
    try std.testing.expectEqual(@as(usize, 2), frame.actionIntentLiveCount());
    try std.testing.expectEqual(@as(usize, 0), frame.intents.mergedItems().len);
}

test "captureActionIntent stamps faced cell matching dig targeting" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    // Large enough that body at (96,96) facing right probes cell (4,3) in-bounds
    // (same fixture geometry as dig_controller faced-cell tests).
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = 32,
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    placePlayerFlush(&data, player, .{ 3, 3 });
    data.facingPtr(player.entity).?.* = .right;
    player.current_level = 2;

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);

    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 256, 256, .{
        .pathfinding = .{
            .max_frame_requests = 1,
            .max_pending_requests = 1,
            .max_cached_results = 1,
            .max_group_fields = 1,
            .worker_participant_count = 1,
            .max_solved_requests_per_step = 1,
            .max_fallback_requests_per_step = 1,
        },
    });
    defer pipeline.deinit();

    var input = InputState{};
    input.setHeld(.interact, true);
    pipeline.captureActionIntent(&input, &frame, player, &data, &world);

    const intent = frame.action_intents.mergedItems()[0];
    try std.testing.expect(intent.has_cell);
    try std.testing.expectEqual(@as(u16, 4), intent.cell_x);
    try std.testing.expectEqual(@as(u16, 3), intent.cell_y);
    try std.testing.expectEqual(@as(u16, 2), intent.level);

    // Facing change must move the stamp (shared dig helper).
    frame.beginStep();
    pipeline.interact_held_last = false;
    data.facingPtr(player.entity).?.* = .down;
    input.setHeld(.interact, true);
    pipeline.captureActionIntent(&input, &frame, player, &data, &world);
    const down_intent = frame.action_intents.mergedItems()[0];
    try std.testing.expect(down_intent.has_cell);
    try std.testing.expectEqual(@as(u16, 3), down_intent.cell_x);
    try std.testing.expectEqual(@as(u16, 4), down_intent.cell_y);
}

test "captureActionIntent keeps latch open when tryAppend soft-drops" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);
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
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    // Fill the live bus so the next interact rising edge soft-drops.
    for (0..action_intent_live_capacity) |_| {
        try frame.appendActionIntent(.{ .entity = EntityId.invalid, .kind = .signal });
    }

    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 64, 64, .{
        .pathfinding = .{
            .max_frame_requests = 1,
            .max_pending_requests = 1,
            .max_cached_results = 1,
            .max_group_fields = 1,
            .worker_participant_count = 1,
            .max_solved_requests_per_step = 1,
            .max_fallback_requests_per_step = 1,
        },
    });
    defer pipeline.deinit();

    var input = InputState{};
    input.setHeld(.interact, true);
    pipeline.captureActionIntent(&input, &frame, player, &data, &world);
    try std.testing.expectEqual(@as(usize, action_intent_live_capacity), frame.actionIntentLiveCount());
    try std.testing.expectEqual(@as(usize, 1), pipeline.action_intents_dropped_step);
    try std.testing.expect(!pipeline.interact_held_last);

    // Still held: rising-edge path retries (latch never advanced on soft-drop).
    pipeline.captureActionIntent(&input, &frame, player, &data, &world);
    try std.testing.expectEqual(@as(usize, 2), pipeline.action_intents_dropped_step);
}

test "captureActionIntent then pipeline.update reports action_intents_consumed" {
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
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
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
    var input = InputState{};
    input.setHeld(.interact, true);
    pipeline.captureActionIntent(&input, &frame, player, &data, &world);
    try std.testing.expectEqual(@as(usize, 1), frame.actionIntentLiveCount());

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
    try std.testing.expectEqual(@as(usize, 1), stats.action_intents_consumed);
    try std.testing.expectEqual(@as(usize, 0), stats.action_intents_dropped);
}

test "captureActionIntent soft-drop recovers after beginStep while held" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);
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
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);

    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 64, 64, .{
        .pathfinding = .{
            .max_frame_requests = 1,
            .max_pending_requests = 1,
            .max_cached_results = 1,
            .max_group_fields = 1,
            .worker_participant_count = 1,
            .max_solved_requests_per_step = 1,
            .max_fallback_requests_per_step = 1,
        },
    });
    defer pipeline.deinit();

    for (0..action_intent_live_capacity) |_| {
        try frame.appendActionIntent(.{ .entity = EntityId.invalid, .kind = .signal });
    }
    var input = InputState{};
    input.setHeld(.interact, true);
    pipeline.captureActionIntent(&input, &frame, player, &data, &world);
    try std.testing.expect(!pipeline.interact_held_last);

    frame.beginStep();
    pipeline.captureActionIntent(&input, &frame, player, &data, &world);
    try std.testing.expect(pipeline.interact_held_last);
    try std.testing.expectEqual(@as(usize, 1), frame.actionIntentLiveCount());
}

test "pipeline.update reports action_intents_dropped after capture soft-drop" {
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
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
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
    for (0..action_intent_live_capacity) |_| {
        try frame.appendActionIntent(.{ .entity = EntityId.invalid, .kind = .signal });
    }
    var input = InputState{};
    input.setHeld(.interact, true);
    pipeline.captureActionIntent(&input, &frame, player, &data, &world);

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
    try std.testing.expectEqual(@as(usize, 1), stats.action_intents_dropped);
}

test "standing player collision does not enqueue deferred impact without motion" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);
    try data.setCollisionBounds(player.entity, .{ .size = .{ .x = 32, .y = 32 } });
    const other = try data.createEntity();
    try data.setMovementBody(other, .{
        .position = .{ .x = 10, .y = 10 },
        .previous_position = .{ .x = 10, .y = 10 },
        .velocity = .{},
        .speed = 0,
    });
    try data.setCollisionBounds(other, .{ .size = .{ .x = 32, .y = 32 } });

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.contacts.reserve(1, 1);
    const writer = try frame.contacts.appendRangeCounts(1);
    frame.contacts.addCount(writer, 1);
    try frame.contacts.prefixAppendedRanges(writer);
    var contact_writer = frame.contacts.rangeWriter(writer);
    contact_writer.write(.{
        .a = player.entity,
        .b = other,
        .a_movement_index = 0,
        .b_movement_index = 1,
        .normal_x = -1,
        .normal_y = 0,
        .penetration = 6,
    });
    contact_writer.finish();
    frame.contacts.finishWrite();

    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .pathfinding = .{
            .max_frame_requests = 1,
            .max_pending_requests = 1,
            .max_cached_results = 1,
            .max_group_fields = 1,
            .worker_participant_count = 1,
            .max_solved_requests_per_step = 1,
            .max_fallback_requests_per_step = 1,
        },
    });
    defer pipeline.deinit();

    var deferred_dropped: usize = 0;
    enqueuePlayerCollisionImpactsToDeferred(&pipeline, &frame, &data, player.entity, 0, &deferred_dropped);
    try std.testing.expectEqual(@as(usize, 0), pipeline.deferred_stimulus_count);
}

test "sticky dig linger reaches every stagger phase within the linger window" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    var world = try testMinimalMultiLevelWorld(&meta);
    defer world.deinit();
    world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 800, .h = 450 }, cognition_halo_chunks);

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    player.current_level = 0;
    placePlayerFlush(&data, player, .{ 5, 3 });
    data.facingPtr(player.entity).?.* = .right;

    const dig_stimulus_x: f32 = 6 * 32 + 16;
    const dig_stimulus_y: f32 = 3 * 32 + 16;

    const observer_phase0 = try data.createEntity();
    try data.setMovementBody(observer_phase0, .{
        .position = .{ .x = 7 * 32, .y = 3 * 32 },
        .previous_position = .{ .x = 7 * 32, .y = 3 * 32 },
        .velocity = .{},
        .speed = 0,
    });
    try data.setAiAgent(observer_phase0, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setWorldLevel(observer_phase0, 0);
    try data.setSimulationTier(observer_phase0, .cognition);
    try data.setAiPerception(observer_phase0, .{ .hearing_range = 1000 });
    try data.setSimulationMetadata(observer_phase0, .{ .tier = .cognition, .chunk = .{ .x = 0, .y = 0 }, .stagger_phase = 0 });

    const observer_phase1 = try data.createEntity();
    try data.setMovementBody(observer_phase1, .{
        .position = .{ .x = 7 * 32, .y = 4 * 32 },
        .previous_position = .{ .x = 7 * 32, .y = 4 * 32 },
        .velocity = .{},
        .speed = 0,
    });
    try data.setAiAgent(observer_phase1, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setWorldLevel(observer_phase1, 0);
    try data.setSimulationTier(observer_phase1, .cognition);
    try data.setAiPerception(observer_phase1, .{ .hearing_range = 1000 });
    try data.setSimulationMetadata(observer_phase1, .{ .tier = .cognition, .chunk = .{ .x = 0, .y = 0 }, .stagger_phase = 1 });

    // Furthest cohort from the dig step: only the full linger window reaches it.
    const observer_phase3 = try data.createEntity();
    try data.setMovementBody(observer_phase3, .{
        .position = .{ .x = 7 * 32, .y = 5 * 32 },
        .previous_position = .{ .x = 7 * 32, .y = 5 * 32 },
        .velocity = .{},
        .speed = 0,
    });
    try data.setAiAgent(observer_phase3, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setWorldLevel(observer_phase3, 0);
    try data.setSimulationTier(observer_phase3, .cognition);
    try data.setAiPerception(observer_phase3, .{ .hearing_range = 1000 });
    try data.setSimulationMetadata(observer_phase3, .{ .tier = .cognition, .chunk = .{ .x = 0, .y = 0 }, .stagger_phase = 3 });

    const dig_config = try DigConfig.fromMeta(&meta);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    try frame.reservePathRequests(2, 2);
    try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 4,
        .dig = dig_config,
        .perception_max_events_per_step = 8,
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

    const ctx = SimulationPipelineUpdateContext{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 800,
        .bounds_height = 450,
    };

    // Next advance lands on stagger slot 0 (phase-0 cohort); dig once there.
    pipeline.scope.step_count = 3;
    try data.setAiPerception(observer_phase1, .{ .hearing_range = 1000 });
    frame.beginStep();
    frame.dig_intent = .hole;
    _ = try pipeline.update(ctx);
    try std.testing.expect(data.aiPerceptionConst(observer_phase0).?.heard_stimulus);
    try std.testing.expect(!data.aiPerceptionConst(observer_phase1).?.heard_stimulus);

    // Following step runs stagger slot 1; sticky dig should reach phase-1.
    frame.beginStep();
    frame.dig_intent = .none;
    _ = try pipeline.update(ctx);
    try std.testing.expect(data.aiPerceptionConst(observer_phase1).?.heard_stimulus);
    try std.testing.expectApproxEqAbs(dig_stimulus_x, data.aiPerceptionConst(observer_phase1).?.heard_stimulus_x, 1.0);
    try std.testing.expectApproxEqAbs(dig_stimulus_y, data.aiPerceptionConst(observer_phase1).?.heard_stimulus_y, 1.0);
    try std.testing.expect(!data.aiPerceptionConst(observer_phase3).?.heard_stimulus);

    // Slot 2 then slot 3: the linger window (cognition_stagger_n - 1 = 3 steps)
    // must still carry the dig to the furthest cohort before it expires.
    frame.beginStep();
    frame.dig_intent = .none;
    _ = try pipeline.update(ctx);

    frame.beginStep();
    frame.dig_intent = .none;
    _ = try pipeline.update(ctx);
    try std.testing.expect(data.aiPerceptionConst(observer_phase3).?.heard_stimulus);
    try std.testing.expectApproxEqAbs(dig_stimulus_x, data.aiPerceptionConst(observer_phase3).?.heard_stimulus_x, 1.0);
    try std.testing.expectApproxEqAbs(dig_stimulus_y, data.aiPerceptionConst(observer_phase3).?.heard_stimulus_y, 1.0);
}
