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
const logging = @import("../core/logging.zig");
const runtime_perf_log = @import("../app/runtime_perf_log.zig");
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const AdaptiveWorkProfile = @import("../app/thread_system.zig").AdaptiveWorkProfile;
const AdaptiveWorkTunerConfig = @import("../app/thread_system.zig").AdaptiveWorkTunerConfig;
const rangeCount = @import("../app/thread_system.zig").rangeCount;
const maxRangeCount = @import("../app/thread_system.zig").maxRangeCount;
const DataSystem = @import("data_system.zig").DataSystem;
const hotStoreCapacity = @import("data_system.zig").hotStoreCapacity;
const PopulationRowCounts = @import("data_system.zig").PopulationRowCounts;
const movement_range_alignment_items = @import("data_system.zig").movement_range_alignment_items;
const EntityId = @import("data_system.zig").EntityId;
const DigConfig = @import("dig_controller.zig").DigConfig;
const DigController = @import("dig_controller.zig").DigController;
const DigEdit = @import("dig_controller.zig").DigController.DigEdit;
const DigEditError = @import("dig_controller.zig").DigEditError;
const DigIntent = @import("simulation.zig").DigIntent;
const facedCellForEntity = @import("dig_controller.zig").facedCellForEntity;
const DestructibleController = @import("destructible_controller.zig").DestructibleController;
const DestructibleProcessStats = @import("destructible_controller.zig").DestructibleProcessStats;
const AudioController = @import("audio_controller.zig").AudioController;
const SensoryBus = @import("sensory_bus.zig").SensoryBus;
const StimulusConfig = @import("sensory_bus.zig").StimulusConfig;
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
const CollisionStrips = @import("systems/collision.zig").CollisionStrips;
const CollisionSystem = @import("systems/collision.zig").CollisionSystem;
const CollisionResponseStats = @import("systems/collision_response.zig").CollisionResponseStats;
const CollisionResponseSystem = @import("systems/collision_response.zig").CollisionResponseSystem;
const estimateTriggerCapacity = @import("systems/collision_response.zig").estimateTriggerCapacity;
const MovementIntentStats = @import("systems/movement.zig").MovementIntentStats;
const MovementStats = @import("systems/movement.zig").MovementStats;
const MovementSystem = @import("systems/movement.zig").MovementSystem;
const PathfindingCapacity = @import("systems/pathfinding.zig").PathfindingCapacity;
const PathfindingStats = @import("systems/pathfinding.zig").PathfindingStats;
const PathfindingSystem = @import("systems/pathfinding.zig").PathfindingSystem;
const NavUpdateStats = @import("systems/pathfinding.zig").NavUpdateStats;
const GoalResolveStats = @import("systems/pathfinding.zig").GoalResolveStats;
const NavigationIntent = @import("simulation.zig").NavigationIntent;
const PerceptionStats = @import("systems/perception.zig").PerceptionStats;
const PerceptionSystem = @import("systems/perception.zig").PerceptionSystem;
const PlayerPerceptionCandidate = @import("systems/perception.zig").PlayerPerceptionCandidate;
const PlaneEntrySystem = @import("systems/plane_entry.zig").PlaneEntrySystem;
const SteeringStats = @import("systems/steering/system.zig").SteeringStats;
const SteeringSystem = @import("systems/steering/system.zig").SteeringSystem;
const steering_range_alignment_items = @import("systems/steering/system.zig").steering_range_alignment_items;
const ai_range_alignment_items = @import("systems/ai.zig").ai_range_alignment_items;
const scope_range_alignment_items = @import("systems/simulation_scope.zig").scope_range_alignment_items;
const StaticColliderSystem = @import("systems/static_colliders.zig").StaticColliderSystem;
const SimulationFrame = @import("simulation.zig").SimulationFrame;
const EventBudgetInputs = @import("simulation.zig").EventBudgetInputs;
const StructuralCommitBudget = @import("simulation.zig").StructuralCommitBudget;
const structuralEventHeadroom = @import("simulation.zig").structuralEventHeadroom;
const EventProducerId = @import("simulation.zig").EventProducerId;
const maxEventsPerStep = @import("simulation.zig").maxEventsPerStep;
const perception_events_per_observer_max = @import("simulation.zig").perception_events_per_observer_max;
const affect_events_per_row_max = @import("simulation.zig").affect_events_per_row_max;
const ActionIntent = @import("simulation.zig").ActionIntent;
const action_intent_live_capacity = @import("simulation.zig").action_intent_live_capacity;
const pipeline_structural_event_share = @import("simulation.zig").pipeline_structural_event_share;
const defaultStimulusIntensity = @import("simulation.zig").defaultStimulusIntensity;
const stimulus_deferred_capacity = @import("simulation.zig").stimulus_deferred_capacity;
const stimulus_live_capacity = @import("simulation.zig").stimulus_live_capacity;
const stimulus_max_impacts_per_step = @import("simulation.zig").stimulus_max_impacts_per_step;
const StructuralCommand = @import("data_system.zig").StructuralCommand;
const SimulationScope = @import("simulation_scope.zig").SimulationScope;
const ActiveRegion = @import("simulation_scope.zig").ActiveRegion;
const cognition_halo_chunks = @import("simulation_scope.zig").cognition_halo_chunks;
const SimulationScopeSystem = @import("systems/simulation_scope.zig").SimulationScopeSystem;
const IndexGeometry = @import("systems/spatial_index.zig").IndexGeometry;
const SpatialIndexStats = @import("systems/spatial_index.zig").SpatialIndexStats;
const SpatialIndexSystem = @import("systems/spatial_index.zig").SpatialIndexSystem;
const CellCoord = @import("world/system.zig").CellCoord;
const WorldSystem = @import("world/system.zig").WorldSystem;
const Rect = @import("../render/renderer.zig").Rect;
const world_gate = @import("systems/world_gate.zig");

/// Coarse per-step data resources stages read/write, for the stage-ordering
/// contract below. Some tags bundle several SoA columns owned by one system
/// (e.g. `movement_positions` covers the movement body's position/velocity
/// columns together) rather than tracking every field individually.
const PipelineResource = enum {
    world_tiles,
    /// `entity_perceived` / `entity_lost`. A dig write of `world_events` does not satisfy this.
    perception_events,
    /// `affect_threshold_crossed`.
    affect_events,
    /// World-domain payloads: tile/obstacle/nav changes and `destructible_destroyed`.
    world_events,
    /// `entity_created` / `entity_destroyed` / `component_changed`, emitted at structural commit
    /// after `update`. External to the stage graph.
    structural_events,
    /// Live `frame.stimuli` bus (promote, dig, footstep) read by perception the same step.
    stimuli,
    /// `AiAgent.active_behavior`. Written by `ai_decide`; `affect_update` carries the previous step.
    ai_behavior,
    /// `WorldSystem` interest markers. Authored outside the step; `ai_decide` carries them.
    interest_markers,
    ai_halo_indices,
    ai_cognition_indices,
    spatial_index,
    navigation_intents,
    /// `PathfindingSystem.goals`: the step's live projection per distinct blocked goal of
    /// `navigation_intents`, read by steering's status queries and the pathfinding update.
    path_goals,
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
    scope_advance_and_ai_gather,
    spatial_index_build,
    ai_cognition_order,
    perception_update,
    ai_memory_update,
    affect_update,
    ai_decide,
    path_goal_resolve,
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

const StageContract = struct {
    reads: ResourceSet = .empty,
    writes: ResourceSet = .empty,
    /// Consumed this step, but not written by an earlier stage. Either produced
    /// outside `update` (`external_resources`) or written by a later stage for
    /// the next step's reader. Disjoint from `reads` and `writes`.
    carried: ResourceSet = .empty,
};

/// Resources produced outside `stage_order`: input capture, world authoring, or
/// the post-`update` structural commit.
const external_resources = resources(&.{ .action_intents, .interest_markers, .structural_events });

/// Declares each stage's resource reads/writes against `stage_order` below.
/// Checked at comptime: a stage cannot read a resource no earlier stage in
/// `stage_order` writes. `carried` is the exception for values that arrive from
/// outside this step's graph.
fn stageContract(stage: StageId) StageContract {
    return switch (stage) {
        // Stimulus writes (promote, dig append, footstep) run inside this stage,
        // before perception reads the live bus.
        .dig_world_edit => .{ .reads = .empty, .writes = resources(&.{ .world_tiles, .world_events, .stimuli }) },
        .scope_advance_and_ai_gather => .{ .reads = .empty, .writes = resources(&.{.ai_halo_indices}) },
        // Indexes the halo at the previous step's positions and levels, which this
        // step's movement and plane traversal write later.
        .spatial_index_build => .{
            .reads = resources(&.{.ai_halo_indices}),
            .writes = resources(&.{.spatial_index}),
            .carried = resources(&.{ .movement_positions, .world_level }),
        },
        // The think set in the index's cell-major order, so rows sharing a neighborhood
        // are adjacent in every think-set stage.
        .ai_cognition_order => .{ .reads = resources(&.{.spatial_index}), .writes = resources(&.{.ai_cognition_indices}) },
        // Queries the spatial index for hostile candidates and writes sensed
        // state for this step's observers (think set); also emits acquisition/loss
        // transition events. Reads world_tiles for line-of-sight /
        // occlusion against the dig-authored floor state from dig_world_edit.
        // Reads `stimuli` authored at dig_world_edit (live bus + hearing scratch).
        // Carries the previous step's positions and levels the observer rows gather.
        .perception_update => .{
            .reads = resources(&.{ .ai_cognition_indices, .spatial_index, .world_tiles, .stimuli }),
            .writes = resources(&.{ .perception_sensed, .perception_events }),
            .carried = resources(&.{ .movement_positions, .world_level }),
        },
        // Refreshes from this step's perception transition events,
        // reading the acquired target's last-seen position from perception_sensed.
        .ai_memory_update => .{ .reads = resources(&.{ .ai_cognition_indices, .perception_events, .perception_sensed }), .writes = resources(&.{.ai_memory}) },
        // Appraises this step's just-written perception + memory columns into drives
        // Carries `ai_behavior` from the previous step; `ai_decide`
        // writes the new mode later in this step.
        .affect_update => .{
            .reads = resources(&.{ .ai_cognition_indices, .perception_sensed, .ai_memory }),
            .writes = resources(&.{ .affect_drives, .affect_events }),
            .carried = resources(&.{.ai_behavior}),
        },
        .ai_decide => .{
            .reads = resources(&.{ .ai_cognition_indices, .spatial_index, .perception_sensed, .ai_memory, .affect_drives }),
            .writes = resources(&.{ .navigation_intents, .ai_behavior }),
            .carried = resources(&.{ .interest_markers, .movement_positions, .world_level }),
        },
        // One projection per distinct blocked goal of this step's intents, before every
        // reader of a live goal.
        .path_goal_resolve => .{ .reads = resources(&.{.navigation_intents}), .writes = resources(&.{.path_goals}) },
        .steering_update => .{ .reads = resources(&.{ .navigation_intents, .path_goals }), .writes = resources(&.{ .movement_intents, .path_requests }) },
        .pathfinding_update => .{ .reads = resources(&.{ .path_requests, .path_goals }), .writes = .empty },
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
        // Body levels are next-step state: plane_traversal writes them after collision.
        .collision_detect => .{
            .reads = resources(&.{ .movement_positions, .collision_scope_indices }),
            .writes = resources(&.{.contacts}),
            .carried = resources(&.{.world_level}),
        },
        .collision_respond => .{ .reads = resources(&.{.contacts}), .writes = resources(&.{ .movement_positions, .collision_triggers }) },
        // Reads hole/ramp walkability from world_tiles; may carve landing cells
        // (writes world_tiles + world_events) and snaps body x/y/z on fall
        // (writes movement_positions + world_level).
        .plane_traversal => .{ .reads = resources(&.{ .movement_positions, .world_tiles }), .writes = resources(&.{ .world_tiles, .world_level, .world_events, .movement_positions }) },
        // DestructibleController consumes action intents captured before `update`
        // (`carried`, not written by a stage) and queues structural commands plus
        // `destructible_destroyed` world events. Target resolve reads settled poses
        // and world_level columns. tier_policy also writes structural_commands
        // afterward via RangeOutputStream multi-producer append.
        .action_react => .{
            .reads = resources(&.{ .movement_positions, .world_level }),
            .writes = resources(&.{ .structural_commands, .world_events }),
            .carried = resources(&.{.action_intents}),
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

/// The fixed-step stage order, comptime-enforced against the contracts; ordering the
/// contracts cannot see is proven by causal-effect tests. Tile gate runs after collision
/// response, so a pushed body is re-gated.
const stage_order = [_]StageId{
    .dig_world_edit,
    .scope_advance_and_ai_gather,
    .spatial_index_build,
    .ai_cognition_order,
    .perception_update,
    .ai_memory_update,
    .affect_update,
    .ai_decide,
    .path_goal_resolve,
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
    // EnumSet insert/union/intersect each walk the resource bits. One cached
    // contract per stage plus the carried checks exceed the default 1000.
    @setEvalBranchQuota(4000);
    if (stage_order.len != @typeInfo(StageId).@"enum".field_names.len) {
        @compileError("SimulationPipeline stage_order must list every StageId exactly once");
    }
    var seen: [stage_order.len]bool = @splat(false);
    for (stage_order) |stage| {
        const index = @backingInt(stage);
        if (seen[index]) {
            @compileError("SimulationPipeline stage_order lists '" ++ @tagName(stage) ++ "' more than once");
        }
        seen[index] = true;
    }

    // One `stageContract` evaluation per stage. Repeating it inside the
    // freshness walk rebuilds EnumSets and blows the comptime branch quota.
    var contracts: [stage_order.len]StageContract = undefined;
    for (stage_order, 0..) |stage, index| contracts[index] = stageContract(stage);

    // Writes of every stage after index i, so a carried input can be checked
    // against "a later stage writes this" without a resource×stage scan.
    var later_writes: [stage_order.len]ResourceSet = @splat(.empty);
    {
        var later: ResourceSet = .empty;
        var index = stage_order.len;
        while (index > 0) {
            index -= 1;
            later_writes[index] = later;
            later.setUnion(contracts[index].writes);
        }
    }

    var produced: ResourceSet = .empty;
    for (stage_order, 0..) |stage, stage_index| {
        const contract = contracts[stage_index];
        if (contract.carried.intersectWith(contract.reads).count() != 0 or
            contract.carried.intersectWith(contract.writes).count() != 0)
        {
            @compileError("SimulationPipeline stage '" ++ @tagName(stage) ++
                "' carries a resource it also reads or writes — carried is disjoint from both");
        }
        const unmet = contract.reads.differenceWith(produced);
        if (unmet.count() != 0) {
            @compileError("SimulationPipeline stage '" ++ @tagName(stage) ++
                "' reads a resource no earlier stage writes — fix stage_order or stageContract()");
        }
        if (contract.carried.intersectWith(produced).count() != 0) {
            @compileError("SimulationPipeline stage '" ++ @tagName(stage) ++
                "' carries a resource an earlier stage writes — declare it as a read");
        }
        const unjustified = contract.carried.differenceWith(external_resources).differenceWith(later_writes[stage_index]);
        if (unjustified.count() != 0) {
            for (std.meta.tags(PipelineResource)) |resource| {
                if (!unjustified.contains(resource)) continue;
                @compileError("SimulationPipeline stage '" ++ @tagName(stage) ++
                    "' carries '" ++ @tagName(resource) ++
                    "', which is neither external nor written by a later stage");
            }
        }
        produced.setUnion(contract.writes);
    }

    // Freshness: a derived resource must still reflect its inputs when consumed.
    // For each derivation, no stage between the producing stage and any later
    // consumer of the output may overwrite one of the inputs — otherwise the
    // consumer reads a value computed from superseded inputs.
    for (stage_order, 0..) |producer_stage, producer_i| {
        for (stageDerivations(producer_stage)) |derivation| {
            for (producer_i + 1..stage_order.len) |consumer_i| {
                if (!contracts[consumer_i].reads.contains(derivation.output)) continue;
                for (producer_i + 1..consumer_i) |between_i| {
                    if (contracts[between_i].writes.intersectWith(derivation.inputs).count() != 0) {
                        @compileError("SimulationPipeline: derived resource '" ++ @tagName(derivation.output) ++
                            "' from '" ++ @tagName(producer_stage) ++ "' is stale before consumer '" ++
                            @tagName(stage_order[consumer_i]) ++ "': stage '" ++ @tagName(stage_order[between_i]) ++
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
    contact_capacity: usize = 0,
    /// Initial population size for every population-sized capacity (scope, spatial
    /// index, collision, steering, cognition gathers, plane scratch, event shares).
    /// `init` raises it to the committed `DataSystem` rows; afterwards only
    /// `SimulationPipeline.syncPopulationCapacity` grows it.
    movement_body_capacity: usize = 0,
    pathfinding: PathfindingCapacity = .{},
    /// Nav cell size for a world-less nav build. With `navigation_world`, nav cells are
    /// its tiles and nav chunks its chunks.
    nav_cell_size: f32 = 32.0,
    navigation_world: ?*const WorldSystem = null,
    /// When set, the one-time static nav build fans mask/abstract work across levels.
    nav_build_thread_system: ?*ThreadSystem = null,
    dig: DigConfig = .{},
    /// The caller's part of the per-step `.structural_commit` event share, in events, sized
    /// with `structuralEventHeadroom(creates, destroys + component sets)` from the caller's
    /// fixed per-step budgets; the pipeline adds its own share on top. It also sizes the
    /// structural-command stream and its ranges past the pipeline's own.
    structural_headroom: usize = 0,
    stimuli: StimulusConfig = .{},
};

/// Borrowed per-step inputs for pipeline update.
/// The pipeline owns systems and stage order, but not persistent game data,
/// frame storage, app services, or state transitions.
/// The plane-traversal stage: the NPC cell entries gathered on workers first, the dig
/// controller's reserve and commit over only them (and the player's cell entry), and the
/// landing carves, one event range, recorded as nav marks right after the write into room
/// reserved before it. Every write that landed is recorded, error included.
pub fn runPlaneTraversal(
    plane_entry: *PlaneEntrySystem,
    dig: *DigController,
    pathfinding: *PathfindingSystem,
    world: *WorldSystem,
    data: *DataSystem,
    player: *Player,
    frame: *SimulationFrame,
    thread_system: *ThreadSystem,
) !void {
    const entries = try plane_entry.gather(data, world, player.entity, dig.tunnel_tile, thread_system);
    const reservation = try dig.reservePlaneTraversalStage(world, data, player, frame, entries, thread_system);
    // The record room follows the carves the preflight counted, which may exceed the
    // tracked population's budget until a failed population seam succeeds.
    if (reservation.carves != 0) try pathfinding.reserveTerrainNavRecord(reservation.carves);
    const first_event = frame.events.mergedItems().len;
    const traversed = dig.commitPlaneTraversalStage(world, data, player, frame, reservation, thread_system);
    // Earlier events keep their positions, so the tail is the stage's own events.
    pathfinding.recordTerrainNavEvents(frame.events.mergedItems()[first_event..], world, thread_system);
    try traversed;
}

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
    /// Optional particle system for soft-drop destroy bursts.
    particles: ?*ParticleSystem = null,
    /// Fixed-step camera rect the simulation derives scope from (cognition
    /// halo, stagger, tier bands) via `simViewRegion` /
    /// `cognitionRegionForWorldRect`. Never the render visibility window, which
    /// follows the interpolated render camera and so depends on frame pacing.
    /// Required: a missing view would silently disable scope gating and run every
    /// entity at full cost. A world with no chunks yields no region, which keeps
    /// the full-active fallback (no halo, no stagger, no tier demotion).
    sim_view: Rect,
};

/// Chunk overscan applied to `sim_view` for simulation scope. Equals the demo's
/// render overscan (comptime-asserted in `game_demo_state.zig`) so the sim
/// region matches the render window at interpolation alpha 1.
pub const sim_view_overscan_chunks: u16 = 1;

/// The one scope-band source for pipeline stages: the fixed-step `sim_view`
/// chunk region anchored at the player's level. Later scope-band readers must
/// call this rather than reading any world visibility state.
fn simViewRegion(context: SimulationPipelineUpdateContext) ?ActiveRegion {
    var region = context.world.chunkRegionForWorldRect(
        context.sim_view,
        sim_view_overscan_chunks,
    ) orelse return null;
    region.level = context.player.current_level;
    return region;
}

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
    /// The step's goal resolve (`path_goal_resolve`).
    path_goals: GoalResolveStats = .{},
    pathfinding: PathfindingStats = .{},
    apply_intents: MovementIntentStats = .{},
    movement: MovementStats = .{},
    chunk_derive: BatchStats = .{},
    collision: CollisionStats = .{},
    collision_response: CollisionResponseStats = .{},
    /// Live-bus stimuli dropped this step (promote and footstep optional
    /// appends when `stimulus_live_capacity` is full). Dig uses required
    /// `writeLiveStimulus`, not soft drop.
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
    /// Plane-traversal landing-carve scratch growths this step (reservation short of the
    /// live population; zero in steady state).
    dig_plane_scratch_grown: usize = 0,
    /// Plane-entry gather window growths this step (reservation short of the live AI
    /// rows; zero in steady state).
    plane_entry_windows_grown: usize = 0,
    perf: Perf = .{},

    /// Kept only with `runtime_perf_log.enabled`: the think-set compaction
    /// (`ai_cognition_order`) and the plane stage's NPC cell-entry gather.
    pub const Perf = if (runtime_perf_log.enabled) struct {
        cognition: BatchStats = .{},
        plane_entry: BatchStats = .{},
    } else struct {};

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

        // The sort is the build's cost driver; the bucket and link stages stay bench-only.
        perf.recordBatch(.spatial_index_build, spatial_index_stats.sort_batch);

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
        perf.recordTiming(.steering_grid, steering_stats.grid_ns);

        perf.recordMetric(.path_accepted_requests, metric(pathfinding_stats.accepted_requests));
        perf.recordMetric(.path_duplicate_requests, metric(pathfinding_stats.duplicate_requests));
        perf.recordMetric(.path_pending_requests, metric(pathfinding_stats.pending_requests));
        perf.recordMetric(.path_solved_requests, metric(pathfinding_stats.solved_requests));
        perf.recordMetric(.path_solve_admissions, metric(pathfinding_stats.solve_admissions));
        perf.recordMetric(.path_available_results, metric(pathfinding_stats.available_results));
        perf.recordMetric(.path_partial_results, metric(pathfinding_stats.partial_results));
        perf.recordMetric(.path_unavailable_results, metric(pathfinding_stats.unavailable_results));
        perf.recordMetric(.path_dropped_requests, metric(pathfinding_stats.dropped_requests));
        perf.recordMetric(.path_admission_deferred_requests, metric(pathfinding_stats.admission_deferred_requests));
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
        perf.recordMetricMax(.path_max_distinct_group_keys, metric(pathfinding_stats.distinct_group_keys));
        perf.recordMetric(.path_group_field_evictions, metric(pathfinding_stats.group_field_evictions));
        perf.recordBatch(.path_solve, pathfinding_stats.solve_batch);
        perf.recordBatch(.path_intake, pathfinding_stats.intake_batch);
        perf.recordBatch(.path_registry_flush, pathfinding_stats.registry_flush_batch);
        perf.recordTiming(.pathfinding_accept, pathfinding_stats.accept_ns);
        perf.recordTiming(.pathfinding_group_service, pathfinding_stats.group_service_ns);
        perf.recordTiming(.pathfinding_solve, pathfinding_stats.solve_ns);
        perf.recordTiming(.pathfinding_publish, pathfinding_stats.publish_ns);
        // Only a step that resized records its resize, so the timing averages per resize.
        if (pathfinding_stats.resize_ns != 0) {
            perf.recordTiming(.pathfinding_resize, pathfinding_stats.resize_ns);
            perf.recordBatch(.path_resize_copy, pathfinding_stats.resize_copy_batch);
        }

        perf.recordMetric(.movement_bodies, metric(movement_stats.body_count));
        perf.recordBatch(.movement, movement_stats.batch);
        perf.recordBatch(.chunk_derive, self.chunk_derive);

        perf.recordMetric(.collision_bodies, metric(collision_stats.body_count));
        perf.recordMetric(.collision_candidate_pairs, metric(collision_stats.candidate_pair_count));
        perf.recordMetric(.collision_contacts, metric(collision_stats.contact_count));
        perf.recordMetric(.collision_broadphase_simd_groups, metric(collision_stats.broadphase_simd_groups));
        if (collision_stats.pair_bound_exceeded) perf.recordMetric(.collision_pair_bound_exceeded, 1);
        perf.recordBatch(.collision_broadphase, collision_stats.broadphase_batch);
        perf.recordBatch(.collision_narrowphase, collision_stats.narrowphase_batch);

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
        perf.recordMetric(.dig_plane_scratch_grown, metric(self.dig_plane_scratch_grown));
        perf.recordMetric(.plane_entry_windows_grown, metric(self.plane_entry_windows_grown));
    }
};

fn metric(value: usize) u64 {
    return @intCast(value);
}

/// The population seam's geometric growth target: 1.5x plus one 16-row alignment
/// block, hot-store aligned (e.g. 12 -> 48, 37 -> 80, 7 -> 32).
fn grownPopulationCapacity(rows: usize) usize {
    return hotStoreCapacity(rows + rows / 2 + movement_range_alignment_items);
}

/// What one `syncPopulationCapacity` call did. All-false on the O(1) fast path.
pub const PopulationSyncStats = struct {
    /// A tracked population capacity grew this call.
    grew: bool = false,

    pub fn recordTo(self: PopulationSyncStats, perf: runtime_perf_log.Context) void {
        perf.recordMetric(.population_capacity_grows, @intFromBool(self.grew));
    }
};

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
    /// Static navigation obstacles as shared rows on nav's cell grid, changed only at the
    /// commit seam (`reserveStaticColliders`, `captureStaticColliderChanges`,
    /// `syncStaticColliders`); nav and steering read them.
    static_colliders: StaticColliderSystem,
    /// Backbone scope system: recomputes chunks, gathers the unstaggered
    /// cognition halo and the stagger-filtered think set, and drives auto tier
    /// wake/sleep.
    scope: SimulationScopeSystem,
    /// Shared per-step neighbor index, built once on workers from the unstaggered
    /// cognition halo. Perception and AI separation/cohere query it read-only.
    spatial_index: SpatialIndexSystem,
    /// AI perception substrate: queries the shared spatial index for
    /// hostile candidates within vision/FOV/line-of-sight and writes
    /// sensed state to `PerceptionStore` for this step's think-set observers.
    perception: PerceptionSystem,
    /// AI short-term memory: decays staleness/familiarity/ring contacts for the
    /// think-set `AiPerception` + `AiMemory` subset and refreshes from
    /// this step's perception acquisition events, feeding `AiSystem`'s
    /// memory-aware cold-pursue retarget.
    ai_memory: AiMemorySystem,
    /// Emotion-drive appraisal (fear/curiosity/aggression/fatigue): appraises
    /// this step's just-refreshed `AiPerception`/`AiMemory` state (both
    /// optional per row) plus each agent's own `AiAgent.active_behavior` into
    /// the think-set `AiAffect` subset. `AiConfig.affect_slice` threads
    /// the resulting drives into arbitration one stage later; this
    /// stage only appraises and decays them.
    affect: AffectSystem,
    dig: DigController,
    /// The plane stage's NPC cell-entry gather; the dig controller's plane reserve and
    /// commit visit only its entries. Its windows follow the population seam.
    plane_entry: PlaneEntrySystem,
    destructible: DestructibleController,
    audio_controller: AudioController,
    /// Tracked logical population capacity: every population-sized pipeline capacity is
    /// reserved to it. Grown only by `syncPopulationCapacity` at the commit seam.
    movement_body_capacity: usize,
    /// Once-only flag for the first population-seam growth log.
    population_growth_logged: bool = false,
    /// This pipeline's share of `frame.events`' `capacity_limit` for perception,
    /// passed through as `PerceptionConfig.max_events_per_step`. Derived share
    /// (`perception_events_per_observer_max` x tracked `AiPerception` rows), exact at
    /// init and grown only at the population seam, so the merge cap never truncates.
    perception_max_events_per_step: usize,
    /// Affect's derived share (`affect_events_per_row_max` x tracked `AiAffect` rows),
    /// passed through as `AffectConfig.max_events_per_step`; grown only at the seam.
    affect_max_events_per_step: usize,
    /// See `SimulationPipelineConfig.structural_headroom`.
    structural_headroom: usize,
    /// Deferred impacts, sticky linger, and the hearing scratch. Survives `beginStep`.
    sensory: SensoryBus,
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
        // `data` at init is authoritative: the tracked capacities start at least at
        // the committed rows, so `tracked >= rows` holds from construction.
        const rows = data.populationRowCounts();
        const population = @max(config.movement_body_capacity, rows.population());
        var ai = AiSystem.init(allocator);
        errdefer ai.deinit();
        var steering = SteeringSystem.init(allocator);
        errdefer steering.deinit();
        try steering.reserve(population);
        var pathfinding = PathfindingSystem.init(allocator);
        errdefer pathfinding.deinit();
        try pathfinding.reserve(config.pathfinding);
        try pathfinding.reserveGoals(population);
        // The elastic pools cover the committed steering agents now, so the first update has
        // nothing to grow. A failure here or later frees them with the system.
        try growPathfindingForAgents(&pathfinding, rows.steering_agents);
        // With a world, nav covers its levels at its own tile and chunk dimensions; the
        // bounds and `nav_cell_size` shape only a world-less build. The colliders build first,
        // on nav's cell grid, and nav reads them.
        const nav_extent = if (config.navigation_world) |world|
            PathfindingSystem.worldNavExtent(world)
        else
            pathfinding.boundsNavExtent(bounds_width, bounds_height, config.nav_cell_size);
        var static_colliders = StaticColliderSystem.init(allocator);
        errdefer static_colliders.deinit();
        try static_colliders.rebuild(data, try nav_extent.colliderGeometry());
        try pathfinding.rebuildNavFromColliders(&static_colliders, nav_extent, if (config.navigation_world != null) config.nav_build_thread_system else null);
        var collision = CollisionSystem.init(allocator);
        errdefer collision.deinit();
        var collision_response = CollisionResponseSystem.init(allocator);
        errdefer collision_response.deinit();
        // The response reserves follow the collision pair bound over the population, like
        // `collision.reserve`; `reserve` sizes the frame's contact streams to the same bound.
        try collision_response.reserveForContacts(@max(config.contact_capacity, CollisionSystem.estimateContactCapacity(population)));
        try collision.reserve(population);
        var scope = SimulationScopeSystem.init(allocator);
        errdefer scope.deinit();
        try scope.reserve(population);
        var spatial_index = SpatialIndexSystem.init(allocator);
        errdefer spatial_index.deinit();
        try spatial_index.reserve(population);
        // Reserved below to `movement_body_capacity` (`reserve`), alongside `AiSystem`.
        var perception = PerceptionSystem.init(allocator);
        errdefer perception.deinit();
        // Reserved below to `movement_body_capacity` (`reserve`), alongside `AiSystem`.
        var ai_memory = AiMemorySystem.init(allocator);
        errdefer ai_memory.deinit();
        // Reserved below to `movement_body_capacity` (`reserve`), alongside `AiSystem`.
        var affect = AffectSystem.init(allocator);
        errdefer affect.deinit();
        var dig = DigController.init(config.dig);
        errdefer dig.deinit();
        try dig.reservePlaneScratch(allocator, maxEventsPerStep(.plane_traversal, .{ .movement_body_capacity = population }));
        // The plane-traversal stage records its carves into nav; its record room follows the
        // same bound.
        try pathfinding.reserveTerrainNavRecord(maxEventsPerStep(.plane_traversal, .{ .movement_body_capacity = population }));
        var plane_entry = PlaneEntrySystem.init(allocator);
        errdefer plane_entry.deinit();
        try plane_entry.reserve(population);
        try ai.reserve(population);
        try perception.reserve(population);
        try ai_memory.reserve(population);
        try affect.reserve(population);

        return .{
            .movement = MovementSystem.init(),
            .collision = collision,
            .collision_response = collision_response,
            .ai = ai,
            .steering = steering,
            .pathfinding = pathfinding,
            .static_colliders = static_colliders,
            .scope = scope,
            .spatial_index = spatial_index,
            .perception = perception,
            .ai_memory = ai_memory,
            .affect = affect,
            .dig = dig,
            .plane_entry = plane_entry,
            .destructible = DestructibleController.init(),
            .audio_controller = AudioController.init(),
            .movement_body_capacity = population,
            .perception_max_events_per_step = perception_events_per_observer_max * rows.ai_perceptions,
            .affect_max_events_per_step = affect_events_per_row_max * rows.ai_affects,
            .structural_headroom = config.structural_headroom,
            .sensory = SensoryBus.init(config.stimuli),
        };
    }

    /// Tops up frame events to the sum of producer budgets (`eventCapacitySum`),
    /// reserves cognition gather scratch for `pop`, and reserves the contact-dependent
    /// streams to the collision pair bound over the tracked `movement_body_capacity`
    /// (`reserveContactStreams`). Does not lower an existing higher event limit. The
    /// production entry: state init calls it after `reserveStreams`.
    pub fn reserve(self: *SimulationPipeline, frame: *SimulationFrame, pop: usize) !void {
        try self.ai.reserve(pop);
        try self.perception.reserve(pop);
        try self.ai_memory.reserve(pop);
        try self.affect.reserve(pop);
        try self.reserveContactStreams(frame);
        const sum = self.eventCapacitySum();
        try frame.events.reserve(sum, sum);
        if (frame.events.capacity_limit) |limit| {
            if (limit < sum) frame.events.setCapacityLimit(sum);
        } else {
            frame.events.setCapacityLimit(sum);
        }
    }

    /// Reserves `frame.contacts`, `frame.collision_triggers` and the response's intent,
    /// order, trigger, observer, and gather-range staging to `CollisionSystem.estimateContactCapacity(movement_body_capacity)`,
    /// the pair bound `collision.reserve` sizes the collision stores to (contacts are a
    /// subset of candidate pairs, triggers of contacts). Every scene within that bound
    /// runs `collision_detect` and `collision_respond` allocation-free under every
    /// partition; past it the main-thread grow paths run, counted by the collision
    /// system's `pair_bound_overflows`. Grow-only.
    fn reserveContactStreams(self: *SimulationPipeline, frame: *SimulationFrame) !void {
        const contact_capacity = CollisionSystem.estimateContactCapacity(self.movement_body_capacity);
        try CollisionSystem.reserveContactStream(&frame.contacts, self.movement_body_capacity);
        // Response writes the trigger stream as one range.
        try frame.collision_triggers.reserve(1, estimateTriggerCapacity(contact_capacity));
        try self.collision_response.reserveForContacts(contact_capacity);
    }

    /// The most ranges steering's avoidance pass appends to `frame.intents` and to
    /// `frame.path_requests` in one step at the tracked population (one of each per pass
    /// range): the range count to reserve both streams to.
    pub fn steeringStreamRangeCount(self: *const SimulationPipeline) usize {
        return maxRangeCount(self.movement_body_capacity, steering_range_alignment_items);
    }

    // The most ranges `ai_decide` appends to `frame.navigation_intents` in one step at the
    // tracked population.
    fn navigationIntentRangeCount(self: *const SimulationPipeline) usize {
        return maxRangeCount(self.movement_body_capacity, ai_range_alignment_items);
    }

    // The most ranges one step appends to `frame.structural_commands` at the tracked
    // population: the tier policy's ranges, the destructible controller's one, and the
    // caller's queued ranges, at most one per event of its `structural_headroom` (each
    // range holds at least one command).
    fn structuralCommandRangeCount(self: *const SimulationPipeline) usize {
        return maxRangeCount(self.movement_body_capacity, scope_range_alignment_items) + 1 + self.structural_headroom;
    }

    /// The per-step `frame.events` bound: the exhaustive sum of `maxEventsPerStep`
    /// over every `EventProducerId` under this pipeline's budgets.
    pub fn eventCapacitySum(self: *const SimulationPipeline) usize {
        const budgets = self.eventBudgets();
        var sum: usize = 0;
        inline for (comptime std.meta.tags(EventProducerId)) |producer| {
            sum += maxEventsPerStep(producer, budgets);
        }
        return sum;
    }

    /// The budget for this step's structural commit: the whole `.structural_commit`
    /// share (the pipeline's destructible share plus the caller's
    /// `structural_headroom`), plus `extra_required_events` preflighted for after it.
    pub fn structuralCommitBudget(self: *const SimulationPipeline, extra_required_events: usize) StructuralCommitBudget {
        return .{
            .extra_required_events = extra_required_events,
            .structural_event_share = maxEventsPerStep(.structural_commit, self.eventBudgets()),
        };
    }

    /// Structural-command stream room beyond one `set_simulation_tier` per body: the
    /// whole `.structural_commit` event share. Every non-tier command emits at least one
    /// event, so the event share bounds the command count.
    pub fn structuralCommandHeadroom(self: *const SimulationPipeline) usize {
        return maxEventsPerStep(.structural_commit, self.eventBudgets());
    }

    pub fn eventBudgets(self: *const SimulationPipeline) EventBudgetInputs {
        return .{
            .perception_max_events_per_step = self.perception_max_events_per_step,
            .affect_max_events_per_step = self.affect_max_events_per_step,
            .movement_body_capacity = self.movement_body_capacity,
            .structural_headroom = self.structural_headroom,
        };
    }

    /// Population growth seam, on main after the structural commit: O(1) unless the
    /// population grew, then re-reserves every population-sized capacity. The only growth
    /// point; grow-only, sized from committed row counts, so capacity never changes
    /// behavior. After an error the tracked values are restored and the next seam retries.
    pub fn syncPopulationCapacity(
        self: *SimulationPipeline,
        frame: *SimulationFrame,
        data: *const DataSystem,
    ) !PopulationSyncStats {
        const rows = data.populationRowCounts();
        const population = rows.population();
        if (population <= self.movement_body_capacity and
            rows.ai_perceptions * perception_events_per_observer_max <= self.perception_max_events_per_step and
            rows.ai_affects * affect_events_per_row_max <= self.affect_max_events_per_step and
            self.pathfinding.coversAgentCount(rows.steering_agents))
        {
            return .{};
        }
        return self.growPopulationCapacity(frame, rows);
    }

    fn growPopulationCapacity(
        self: *SimulationPipeline,
        frame: *SimulationFrame,
        rows: PopulationRowCounts,
    ) !PopulationSyncStats {
        @branchHint(.cold);
        var stats: PopulationSyncStats = .{};
        const population = rows.population();
        const old_body = self.movement_body_capacity;
        const body = if (population > old_body) grownPopulationCapacity(population) else old_body;
        const old_perception_share = self.perception_max_events_per_step;
        const old_affect_share = self.affect_max_events_per_step;
        const perception_share = if (rows.ai_perceptions * perception_events_per_observer_max > old_perception_share)
            perception_events_per_observer_max * grownPopulationCapacity(rows.ai_perceptions)
        else
            old_perception_share;
        const affect_share = if (rows.ai_affects * affect_events_per_row_max > old_affect_share)
            affect_events_per_row_max * grownPopulationCapacity(rows.ai_affects)
        else
            old_affect_share;
        // `collision.reserve` raises its declared pair bound; a later failure (the contact
        // streams in `reserve`) must not leave it declaring streams that were never sized.
        const old_pair_bound = self.collision.reserved_pair_bound;
        errdefer {
            self.collision.reserved_pair_bound = old_pair_bound;
            self.movement_body_capacity = old_body;
            self.perception_max_events_per_step = old_perception_share;
            self.affect_max_events_per_step = old_affect_share;
        }

        const body_grew = body != old_body;
        if (body_grew) {
            try self.scope.reserve(body);
            try self.plane_entry.reserve(body);
            try self.spatial_index.reserve(body);
            try self.collision.reserve(body);
            try self.dig.ensurePlaneScratchReserve(body + 1);
            try self.pathfinding.reserveTerrainNavRecord(maxEventsPerStep(.plane_traversal, .{ .movement_body_capacity = body }));
            try self.steering.reserve(body);
            try self.pathfinding.reserveGoals(body);
        }

        self.movement_body_capacity = body;
        const shares_grew = perception_share != old_perception_share or affect_share != old_affect_share;
        self.perception_max_events_per_step = perception_share;
        self.affect_max_events_per_step = affect_share;

        if (body_grew or shares_grew) {
            // Each stream's range count is the most ranges its writers dispatch at `body`.
            try frame.navigation_intents.reserve(self.navigationIntentRangeCount(), body);
            try frame.intents.reserve(self.steeringStreamRangeCount(), body);
            try frame.structural_commands.reserve(self.structuralCommandRangeCount(), body + self.structuralCommandHeadroom());
            try frame.reservePathRequests(self.steeringStreamRangeCount(), body);
            // Raises the event limit, re-runs the cognition reserves and the contact
            // streams + response reserves to the grown pair bound (and every other
            // reserve attached to `reserve`).
            try self.reserve(frame, body);
        }

        try growPathfindingForAgents(&self.pathfinding, rows.steering_agents);

        if (body_grew or shares_grew) {
            stats.grew = true;
            if (!self.population_growth_logged) {
                self.population_growth_logged = true;
                if (comptime logging.enabled(.info)) logging.game.info(
                    "population seam grew pipeline capacity to {d} bodies",
                    .{body},
                );
            }
        }
        return stats;
    }

    // Sizes pathfinding's elastic pools for `steering_agents`, raising its agent ceiling
    // geometrically when the crowd passes it; O(1) when they already cover it. Shared by init
    // (the committed rows) and the population seam. An error restores the ceiling, and the
    // pools keep the fallback limits their resize installs.
    fn growPathfindingForAgents(pathfinding: *PathfindingSystem, steering_agents: usize) error{OutOfMemory}!void {
        if (pathfinding.coversAgentCount(steering_agents)) return;
        const old_agent_budget = pathfinding.capacity.max_agent_budget;
        errdefer pathfinding.capacity.max_agent_budget = old_agent_budget;
        if (steering_agents > pathfinding.agentBudget()) {
            pathfinding.raiseAgentBudget(grownPopulationCapacity(steering_agents));
        }
        try pathfinding.growForAgentCount(steering_agents);
    }

    /// Releases owned processor/controller state. Borrowed gameplay data and
    /// frame storage stay owned by the gameplay state.
    pub fn deinit(self: *SimulationPipeline) void {
        self.plane_entry.deinit();
        self.dig.deinit();
        self.affect.deinit();
        self.ai_memory.deinit();
        self.perception.deinit();
        self.spatial_index.deinit();
        self.scope.deinit();
        self.static_colliders.deinit();
        self.pathfinding.deinit();
        self.steering.deinit();
        self.ai.deinit();
        self.collision_response.deinit();
        self.collision.deinit();
        self.* = undefined;
    }

    /// The commit seam's collider reserve, before the structural commit: sizes the static
    /// colliders' dirty list to every entity index this step's commands can produce, so the
    /// capture after the commit allocates nothing, and nav's static marks to every change
    /// the next collider sync can record (the pending changes plus one per command). An
    /// error commits nothing.
    pub fn reserveStaticColliders(self: *SimulationPipeline, frame: *const SimulationFrame, data: *const DataSystem) !void {
        const command_count = frame.structural_commands.mergedItems().len;
        try self.static_colliders.reserveForCommit(data, command_count);
        try self.pathfinding.reserveStaticColliderMarks(self.static_colliders.pendingChangeCount() + command_count);
    }

    /// Right after the structural commit: records the step's static changes into the
    /// colliders' persistent dirty list. Allocation-free; never fails, so a later seam
    /// failure cannot lose them.
    pub fn captureStaticColliderChanges(self: *SimulationPipeline, frame: *const SimulationFrame) void {
        self.static_colliders.capture(frame);
    }

    /// Applies the captured static changes to the collider rows, then records them for nav
    /// into the marks `reserveStaticColliders` reserved, whether or not nav applies this
    /// step. Main work is O(1) per changed static and per footprint chunk entering or
    /// leaving; the per-chunk sorted placement threads under `thread_system`. On error the
    /// rows are unchanged, nothing is recorded, and the changes stay for the next sync.
    pub fn syncStaticColliders(self: *SimulationPipeline, data: *const DataSystem, thread_system: *ThreadSystem) !void {
        try self.static_colliders.sync(data, thread_system);
        self.pathfinding.recordStaticColliderChanges(self.static_colliders.changesThisStep());
    }

    /// Records the last collider sync's chunk-list splice batch. Every sync resets it, so
    /// after the commit seam it is this step's, empty (and not recorded) when no static
    /// changed.
    pub fn recordStaticColliderSyncTo(self: *const SimulationPipeline, perf: runtime_perf_log.Context) void {
        perf.recordBatch(.static_collider_splice, self.static_colliders.last_splice_batch);
    }

    /// Orchestrates the post-commit nav reaction by delegating to the nav-owning
    /// `PathfindingSystem`, which applies every recorded nav change and emits the
    /// invalidation event. Runs after `syncStaticColliders` succeeded this step.
    pub fn reactToPostCommitNavEvents(
        self: *SimulationPipeline,
        frame: *SimulationFrame,
        world: *const WorldSystem,
        thread_system: *ThreadSystem,
    ) !NavUpdateStats {
        return self.pathfinding.reactToPostCommitNavEvents(frame, &self.static_colliders, world, thread_system);
    }

    /// Orchestrates steering's post-commit reaction: its movement-index cache follows the
    /// step's entity changes. Steering reads the synced collider rows directly, so no
    /// static change reaches it here. Disjoint state, so it runs even when the nav
    /// reaction fails.
    pub fn reactToPostCommitSteeringEvents(
        self: *SimulationPipeline,
        frame: *const SimulationFrame,
    ) void {
        self.steering.reactToPostCommitSteeringEvents(frame);
    }

    /// Whether the post-commit nav reaction may emit its event this step: a pending
    /// structural command may change nav, a failed collider sync left static changes for
    /// this step's sync, or nav has recorded marks, levels, links, or a content revision
    /// still to apply. Used for the pre-commit event capacity preflight.
    pub fn navReactionMayEmit(self: *const SimulationPipeline, data: *const DataSystem, frame: *const SimulationFrame, world: *const WorldSystem) bool {
        return self.static_colliders.hasPendingChanges() or self.pathfinding.navReactionMayEmit(data, frame, world);
    }

    /// Queues ambient audio (music + movement-gated jet loop) through the owned
    /// audio controller. Buffer/input/data are borrowed; the controller owns the
    /// audio-policy runtime state.
    pub fn queueAmbientAudio(self: *SimulationPipeline, audio: *AudioCommandBuffer, input: *const InputState, data: *const DataSystem, player: Player) void {
        self.audio_controller.queueAmbient(audio, input, data, player);
    }

    /// Queues collision SFX for this step's contacts through the owned audio
    /// controller. Only contacts involving `player.entity` play a sound; they are the
    /// collision response's observer contacts, so this runs after `update` on the same
    /// frame.
    pub fn queueCollisionAudio(self: *SimulationPipeline, audio: *AudioCommandBuffer, frame: *const SimulationFrame, data: *const DataSystem, player: Player, delta_seconds: f32) void {
        self.audio_controller.queueCollision(audio, frame, data, self.collision_response.observerContacts(frame, player.entity), delta_seconds);
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
            // Same faced-cell probe as dig so action-intent consumers match dig targeting.
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

    /// Per-step values produced by one stage and read by a later stage or by
    /// `finish`. Not persistent. Indices alias scope scratch owned by the pipeline.
    const StepState = struct {
        context: SimulationPipelineUpdateContext,
        stimuli_live_dropped: usize = 0,
        stimuli_deferred_dropped: usize = 0,
        stimuli_sticky_dropped: usize = 0,
        stimuli_promoted: usize = 0,
        action_intents_dropped: usize = 0,
        dig_plane_scratch_grown: usize = 0,
        plane_entry_windows_grown: usize = 0,
        perf: SimulationPipelineStats.Perf = .{},
        cognition_region: ?ActiveRegion = null,
        stagger_step: u8 = 0,
        ai_halo_indices: []const u32 = &[_]u32{},
        ai_cognition_indices: []const u32 = &[_]u32{},
        collision_scope_indices: ?[]const u32 = null,
        spatial_index: SpatialIndexStats = .{},
        perception: PerceptionStats = .{},
        ai_memory: AiMemoryStats = .{},
        affect: AffectStats = .{},
        ai: AiStats = .{},
        steering: SteeringStats = .{},
        path_goals: GoalResolveStats = .{},
        pathfinding: PathfindingStats = .{},
        apply_intents: MovementIntentStats = .{},
        movement: MovementStats = .{},
        chunk_derive: BatchStats = .{},
        collision: CollisionStats = .{},
        collision_response: CollisionResponseStats = .{},
        destructible: DestructibleProcessStats = .{},

        fn init(pipeline: *SimulationPipeline, context: SimulationPipelineUpdateContext) StepState {
            const dropped = pipeline.action_intents_dropped_step;
            pipeline.action_intents_dropped_step = 0;
            var step = StepState{
                .context = context,
                .action_intents_dropped = dropped,
            };
            step.context.frame.phase = .processors;
            return step;
        }

        fn finish(self: StepState, pipeline: *const SimulationPipeline) SimulationPipelineStats {
            const scope = pipeline.buildScopeStats(
                self.context.data,
                self.cognition_region,
                self.ai_cognition_indices,
                self.collision_scope_indices,
                self.steering,
            );
            return .{
                .scope = scope,
                .spatial_index = self.spatial_index,
                .perception = self.perception,
                .ai_memory = self.ai_memory,
                .affect = self.affect,
                .ai = self.ai,
                .steering = self.steering,
                .path_goals = self.path_goals,
                .pathfinding = self.pathfinding,
                .apply_intents = self.apply_intents,
                .movement = self.movement,
                .chunk_derive = self.chunk_derive,
                .collision = self.collision,
                .collision_response = self.collision_response,
                .stimuli_live_dropped = self.stimuli_live_dropped,
                .stimuli_deferred_dropped = self.stimuli_deferred_dropped,
                .stimuli_sticky_dropped = self.stimuli_sticky_dropped,
                .stimuli_promoted = self.stimuli_promoted,
                .action_intents_consumed = self.destructible.intents_consumed,
                .action_intents_dropped = self.action_intents_dropped,
                .destructibles_destroyed = self.destructible.destroyed,
                .destructibles_hit = self.destructible.hits,
                .dig_plane_scratch_grown = self.dig_plane_scratch_grown,
                .plane_entry_windows_grown = self.plane_entry_windows_grown,
                .perf = self.perf,
            };
        }
    };

    /// Runs `stage_order` and returns stage stats. Scope selection uses the
    /// fixed-step `sim_view` cognition halo (index/candidates) plus stagger (think
    /// set); chunk
    /// columns are derived in their own late stage after positions settle.
    /// Action intents are already on the frame from `captureActionIntent`.
    pub fn update(self: *SimulationPipeline, context: SimulationPipelineUpdateContext) !SimulationPipelineStats {
        var step = StepState.init(self, context);
        inline for (stage_order) |id| try self.runStage(id, &step);
        return step.finish(self);
    }

    fn runStage(self: *SimulationPipeline, comptime id: StageId, step: *StepState) !void {
        switch (id) {
            .dig_world_edit => try self.stageDigWorldEdit(step),
            .scope_advance_and_ai_gather => try self.stageScopeAdvanceAndAiGather(step),
            .spatial_index_build => try self.stageSpatialIndexBuild(step),
            .ai_cognition_order => try self.stageAiCognitionOrder(step),
            .perception_update => try self.stagePerceptionUpdate(step),
            .ai_memory_update => try self.stageAiMemoryUpdate(step),
            .affect_update => try self.stageAffectUpdate(step),
            .ai_decide => try self.stageAiDecide(step),
            .path_goal_resolve => try self.stagePathGoalResolve(step),
            .steering_update => try self.stageSteeringUpdate(step),
            .pathfinding_update => try self.stagePathfindingUpdate(step),
            .apply_ai_movement_intents => self.stageApplyAiMovementIntents(step),
            .movement_integrate => self.stageMovementIntegrate(step),
            .collision_scope_gather => try self.stageCollisionScopeGather(step),
            .collision_detect => try self.stageCollisionDetect(step),
            .collision_respond => try self.stageCollisionRespond(step),
            .bounds_and_tile_gate => try self.stageBoundsAndTileGate(step),
            .plane_traversal => try self.stagePlaneTraversal(step),
            .chunk_derive => self.stageChunkDerive(step),
            .action_react => try self.stageActionReact(step),
            .tier_policy => try self.stageTierPolicy(step),
        }
    }

    fn stageDigWorldEdit(self: *SimulationPipeline, step: *StepState) !void {
        const context = step.context;
        // The dig is planned and its world growth (tile storage, a ramp's exit
        // clear and link) reserved once, before the promote, so an OOM fails the
        // stage with the deferred impacts still queued; the promote writes no world
        // state.
        const dig_edit = try self.reserveDigWorldEdit(context.world, context.data, context.player.*, context.frame.dig_intent);
        // Promote, then dig, then at most one footstep, before perception reads stimuli.
        step.stimuli_promoted = try self.sensory.promote(context.frame, &step.stimuli_live_dropped);
        if (dig_edit) |edit| try self.commitDigWorldEdit(context.world, edit, context.frame);
        try self.sensory.appendFootstep(context.frame, context.data, context.player.*, &step.stimuli_live_dropped);
    }

    /// Plans `intent`'s dig and reserves its world growth and its nav record, so an OOM
    /// fails before anything is written. Returns the edit for `commitDigWorldEdit`, with
    /// no world write between them, or null when the intent does nothing.
    pub fn reserveDigWorldEdit(self: *SimulationPipeline, world: *WorldSystem, data: *const DataSystem, player: Player, intent: DigIntent) DigEditError!?DigEdit {
        const edit = (try self.dig.reserveWorldEdit(world, data, player, intent)) orelse return null;
        try self.pathfinding.reserveTerrainNavRecord(maxEventsPerStep(.dig_world_edit, .{}));
        return edit;
    }

    /// Writes a player-authored edit `reserveDigWorldEdit` reserved, plus a ramp's exit
    /// cleared walkable on the level above, and records its `world_tile_changed` event
    /// (and the exit's `world_obstacle_changed`) as nav marks; the commit seam applies
    /// them. Every write that landed is recorded, error included.
    pub fn commitDigWorldEdit(self: *SimulationPipeline, world: *WorldSystem, edit: DigEdit, frame: *SimulationFrame) DigEditError!void {
        const first_event = frame.events.mergedItems().len;
        const written = DigController.commitWorldEdit(world, edit, frame);
        // Earlier events keep their positions, so the tail is the edit's own events.
        self.pathfinding.recordTerrainNavEvents(frame.events.mergedItems()[first_event..], world, null);
        try written;
    }

    /// Advance the stagger clock, derive the cognition halo from the fixed-step
    /// `sim_view` (never the render window), and gather this step's unstaggered halo
    /// (spatial index + perception candidates); `ai_cognition_order` selects the think set
    /// from its index. Chunk columns are derived later in `chunk_derive`. The AI gather
    /// reads the chunk written last step. Movement/collision gate on tier only, so they
    /// keep running off-screen.
    fn stageScopeAdvanceAndAiGather(self: *SimulationPipeline, step: *StepState) !void {
        const context = step.context;
        self.scope.advanceStep();
        step.cognition_region = context.world.cognitionRegionForWorldRect(context.sim_view, sim_view_overscan_chunks, cognition_halo_chunks);
        step.stagger_step = self.scope.staggerStep();
        step.ai_halo_indices = (try self.scope.gatherAiPopulations(context.data, step.cognition_region, context.thread_system, .{})).halo;
    }

    /// Shared neighbor index: built once from the unstaggered halo, at the
    /// previous positions perception and AI read, over the world's chunk grid.
    fn stageSpatialIndexBuild(self: *SimulationPipeline, step: *StepState) !void {
        const context = step.context;
        const data = context.data;
        var spatial_index_timer = StageTimer.start();
        step.spatial_index = try self.spatial_index.build(
            data,
            .{ .entities = data.aiAgentSliceConst().entities, .rows = step.ai_halo_indices },
            IndexGeometry.ofWorld(context.world),
            context.thread_system,
            .{},
        );
        spatial_index_timer.stop(context.perf, .pipeline_spatial_index);
    }

    /// The think set: the indexed halo rows on this step's stagger phase (every row with no
    /// cognition region), in the index's cell-major order.
    fn stageAiCognitionOrder(self: *SimulationPipeline, step: *StepState) !void {
        const context = step.context;
        const index = self.spatial_index.view();
        const result = try self.scope.compactCognition(&index, step.stagger_step, step.cognition_region != null, context.thread_system, .{});
        step.ai_cognition_indices = result.cognition;
        if (comptime runtime_perf_log.enabled) step.perf.cognition = result.batch;
    }

    /// Perception: hostile candidates within vision/FOV/line-of-sight
    /// from the shared index, writing sensed state only for this step's think-set observers.
    /// The player is folded in as an extra hostile candidate. Sticky dig/impact
    /// stimuli advance after this step's hearing read.
    fn stagePerceptionUpdate(self: *SimulationPipeline, step: *StepState) !void {
        const context = step.context;
        const data = context.data;
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

        const hearing_stimuli = self.sensory.hearingSlice(context.frame);
        var perception_timer = StageTimer.start();
        step.perception = try self.perception.update(
            data.aiAgentSliceConst(),
            data.movementBodySliceConst(),
            self.spatial_index.view(),
            context.world,
            data,
            &context.frame.events,
            context.thread_system,
            .{
                .scope_dense_indices = step.ai_cognition_indices,
                .player_candidate = perception_player_candidate,
                .stimuli = hearing_stimuli,
                .max_events_per_step = maxEventsPerStep(.perception_update, self.eventBudgets()),
            },
        );
        perception_timer.stop(context.perf, .pipeline_perception);
        self.sensory.advanceSticky(context.frame, &step.stimuli_sticky_dropped);
    }

    /// Decays staleness/familiarity/ring contacts and refreshes from this step's
    /// perception acquisition events, over the think set, before AI reads memory.
    fn stageAiMemoryUpdate(self: *SimulationPipeline, step: *StepState) !void {
        const context = step.context;
        var ai_memory_timer = StageTimer.start();
        step.ai_memory = try self.ai_memory.update(context.data.aiAgentSliceConst(), context.data, context.frame, context.thread_system, .{
            .scope_dense_indices = step.ai_cognition_indices,
        });
        ai_memory_timer.stop(context.perf, .pipeline_ai_memory);
    }

    /// Appraises this step's perception + memory into drives over the think set.
    /// Must run after both producers and before `ai_decide` reads the drives.
    fn stageAffectUpdate(self: *SimulationPipeline, step: *StepState) !void {
        const context = step.context;
        var affect_timer = StageTimer.start();
        step.affect = try self.affect.update(context.data.aiAgentSliceConst(), context.data, &context.frame.events, context.thread_system, .{
            .scope_dense_indices = step.ai_cognition_indices,
            .max_events_per_step = maxEventsPerStep(.affect_update, self.eventBudgets()),
        });
        affect_timer.stop(context.perf, .pipeline_ai_affect);
    }

    fn stageAiDecide(self: *SimulationPipeline, step: *StepState) !void {
        const context = step.context;
        const data = context.data;
        // The player's plane is deliberately not propagated into the AI goal level:
        // NPCs stay on the surface until autonomous descent lands. Seeding the
        // player's underground plane here would make them request cross-level paths
        // they cannot walk, piling them at the ramp mouth. `player_target` only
        // feeds the opt-in pursue fallback, never a goal level.
        const player_target = if (data.movementBodyConst(context.player.entity)) |pbody|
            pbody.previous_position
        else
            math.Vec2{ .x = 400, .y = 225 };

        var ai_timer = StageTimer.start();
        step.ai = try self.ai.update(
            data.aiAgentSliceConst(),
            data.movementBodySliceConst(),
            self.spatial_index.view(),
            data,
            context.frame,
            context.thread_system,
            context.delta_seconds,
            .{
                .intent_seed = 0xfeedf00d,
                .step = self.scope.currentStep(),
                // Last-resort fallback: arbitration reaches for this only when a
                // row's own perception/memory produced no goal and its gain_pursue > 0.
                .focus_target = player_target,
                .focus_entity = context.player.entity,
                .goal_requantization_hysteresis_distance = default_goal_requantization_hysteresis_distance,
                // Ceiling only: arbitration resolves every behavior's goal to
                // `.individual`, so this has no observable effect today.
                .nav_request_kind = .individual,
                .navigation_intents = &context.frame.navigation_intents,
                .scope_dense_indices = step.ai_cognition_indices,
                .perception_slice = data.aiPerceptionSliceConst(),
                .memory_slice = data.aiMemorySliceConst(),
                .affect_slice = data.aiAffectSliceConst(),
                .interest_markers = &context.world.interest_markers,
            },
        );
        ai_timer.stop(context.perf, .pipeline_ai);
    }

    fn stagePathGoalResolve(self: *SimulationPipeline, step: *StepState) !void {
        const context = step.context;
        var path_goals_timer = StageTimer.start();
        step.path_goals = try self.pathfinding.resolveGoals(NavigationIntent, context.frame.navigation_intents.mergedItems(), context.thread_system, .{});
        path_goals_timer.stop(context.perf, .pipeline_path_goals);
    }

    fn stageSteeringUpdate(self: *SimulationPipeline, step: *StepState) !void {
        const context = step.context;
        var steering_timer = StageTimer.start();
        step.steering = try self.steering.update(context.data, context.frame, context.thread_system, &self.pathfinding, &self.static_colliders, .{});
        steering_timer.stop(context.perf, .pipeline_steering);
    }

    fn stagePathfindingUpdate(self: *SimulationPipeline, step: *StepState) !void {
        const context = step.context;
        var pathfinding_timer = StageTimer.start();
        // Elastic pathfinding capacity tracks the live steering-agent crowd.
        const path_agent_count = context.data.steeringAgentSliceConst().entities.len;
        step.pathfinding = try self.pathfinding.update(&context.frame.path_requests, path_agent_count, context.thread_system, .{});
        pathfinding_timer.stop(context.perf, .pipeline_pathfinding);
    }

    fn stageApplyAiMovementIntents(self: *SimulationPipeline, step: *StepState) void {
        // Steering is the stream's only writer, one intent per steering row; the
        // threaded apply's disjoint row writes rely on it.
        std.debug.assert(step.context.frame.intents.mergedItems().len == step.steering.movement_intent_count);
        var apply_intents_timer = StageTimer.start();
        step.apply_intents = self.movement.applyIntents(step.context.data, step.context.frame, step.context.thread_system, .{});
        apply_intents_timer.stop(step.context.perf, .pipeline_apply_intents);
    }

    /// Movement integrates the full contiguous range. Non-moving rows carry zero
    /// velocity, so they integrate as no-ops. Chunk maintenance is `chunk_derive`,
    /// after collision, the tile gate, and plane traversal have settled positions.
    fn stageMovementIntegrate(self: *SimulationPipeline, step: *StepState) void {
        const context = step.context;
        var movement_slice = context.data.movementBodySlice();
        var movement_timer = StageTimer.start();
        step.movement = self.movement.update(&movement_slice, context.thread_system, context.delta_seconds, .{});
        movement_timer.stop(context.perf, .pipeline_movement);
    }

    /// Collision gates on tier only (no chunk filter): off-screen entities keep
    /// colliding. Null indices mean full-active.
    fn stageCollisionScopeGather(self: *SimulationPipeline, step: *StepState) !void {
        const context = step.context;
        step.collision_scope_indices = (try self.scope.gatherCollisionBoundsIndices(context.data, context.thread_system, .{})).indices;
    }

    fn stageCollisionDetect(self: *SimulationPipeline, step: *StepState) !void {
        const context = step.context;
        var collision_timer = StageTimer.start();
        step.collision = try self.collision.update(context.data, &context.frame.contacts, context.thread_system, .{
            .strips = CollisionStrips.ofWorld(context.world),
            .scope_dense_indices = step.collision_scope_indices,
        });
        collision_timer.stop(context.perf, .pipeline_collision);
    }

    fn stageCollisionRespond(self: *SimulationPipeline, step: *StepState) !void {
        const context = step.context;
        var collision_response_timer = StageTimer.start();
        step.collision_response = try self.collision_response.update(context.data, context.frame, context.player.entity, context.thread_system, .{});
        collision_response_timer.stop(context.perf, .pipeline_collision_response);
        self.sensory.enqueuePlayerImpacts(
            context.frame,
            context.data,
            self.collision_response.observerContacts(context.frame, context.player.entity),
            context.player.current_level,
            &step.stimuli_deferred_dropped,
        );
    }

    fn stageBoundsAndTileGate(_: *SimulationPipeline, step: *StepState) !void {
        const context = step.context;
        var clamp_timer = StageTimer.start();
        try world_gate.apply(context.world, context.data, context.player, context.bounds_width, context.bounds_height);
        clamp_timer.stop(context.perf, .pipeline_clamp_bounds);
    }

    /// After positions settle: follow a ramp on cell entry, or fall one level when
    /// standing over a hole (`runPlaneTraversal`).
    fn stagePlaneTraversal(self: *SimulationPipeline, step: *StepState) !void {
        const context = step.context;
        const grown_before = self.dig.plane_scratch_grown;
        const windows_grown_before = self.plane_entry.windows_grown;
        try runPlaneTraversal(&self.plane_entry, &self.dig, &self.pathfinding, context.world, context.data, context.player, context.frame, context.thread_system);
        if (comptime runtime_perf_log.enabled) step.perf.plane_entry = self.plane_entry.perf.last_batch;
        step.plane_entry_windows_grown = @intCast(self.plane_entry.windows_grown - windows_grown_before);
        step.dig_plane_scratch_grown = @intCast(self.dig.plane_scratch_grown - grown_before);
    }

    /// Recompute each body's chunk from its settled position. Consumers are tier
    /// policy and render prep. `action_react` may sit between this and tier policy;
    /// neither rewrites chunk columns.
    fn stageChunkDerive(self: *SimulationPipeline, step: *StepState) void {
        const context = step.context;
        var chunk_derive_timer = StageTimer.start();
        step.chunk_derive = self.scope.deriveChunks(context.data, context.thread_system, .{
            .tile_size = context.world.tile_size,
            .chunk_size_tiles = context.world.chunk_size_tiles,
            .width = context.world.width,
            .height = context.world.height,
        }, .{});
        chunk_derive_timer.stop(context.perf, .pipeline_chunk_derive);
    }

    /// First domain consumer of action intents carried from input capture.
    fn stageActionReact(self: *SimulationPipeline, step: *StepState) !void {
        const context = step.context;
        step.destructible = try self.destructible.process(
            context.frame,
            context.data,
            context.world,
            context.particles,
        );
    }

    /// Assign cognition/locomotion/kinematic/dormant by cube distance from the
    /// fixed-step sim-view region. Commands are deferred. The anchor level is the
    /// player's, so off-level entities demote. Queues nothing when no tier changed.
    fn stageTierPolicy(self: *SimulationPipeline, step: *StepState) !void {
        const context = step.context;
        _ = try self.scope.queueTierChanges(context.data, simViewRegion(context), &context.frame.structural_commands, context.thread_system, .{});
    }

    fn buildScopeStats(
        self: *const SimulationPipeline,
        data: *const DataSystem,
        cognition_region: ?ActiveRegion,
        ai_cognition_indices: []const u32,
        collision_scope_indices: ?[]const u32,
        steering_stats: SteeringStats,
    ) SimulationScope {
        var stats = data.simulationScopeStatsFullActive();
        stats.ai_stage_entities = ai_cognition_indices.len;
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

const StageTimer = @import("../app/runtime_perf_log.zig").StageTimer;

const data_test_support = @import("data_system/test_support.zig");
const pathfinding_test_support = @import("systems/pathfinding/test_support.zig");

const static_colliders_test_support = @import("systems/static_colliders_test_support.zig");

test "stageContract(.ai_decide) reads affect_drives, written by affect_update one stage earlier" {
    const contract = stageContract(.ai_decide);
    try std.testing.expect(contract.reads.contains(.affect_drives));
}

test "stage contracts split event families and carry out-of-graph inputs" {
    const memory = stageContract(.ai_memory_update);
    try std.testing.expect(memory.reads.contains(.perception_events));
    try std.testing.expect(!memory.reads.contains(.world_events));
    try std.testing.expect(!memory.reads.contains(.affect_events));
    try std.testing.expect(!memory.reads.contains(.structural_events));

    const affect = stageContract(.affect_update);
    try std.testing.expect(affect.writes.contains(.affect_events));
    try std.testing.expect(affect.carried.contains(.ai_behavior));
    try std.testing.expect(!affect.reads.contains(.ai_behavior));

    const decide = stageContract(.ai_decide);
    try std.testing.expect(decide.writes.contains(.ai_behavior));
    try std.testing.expect(decide.writes.contains(.navigation_intents));
    try std.testing.expect(decide.carried.contains(.interest_markers));
    try std.testing.expect(decide.carried.contains(.movement_positions));
    try std.testing.expect(decide.carried.contains(.world_level));
    const perception = stageContract(.perception_update);
    try std.testing.expect(perception.carried.contains(.movement_positions));
    try std.testing.expect(perception.carried.contains(.world_level));

    const react = stageContract(.action_react);
    try std.testing.expect(react.carried.contains(.action_intents));
    try std.testing.expect(!react.reads.contains(.action_intents));
    try std.testing.expect(react.writes.contains(.world_events));

    try std.testing.expect(stageContract(.dig_world_edit).writes.contains(.stimuli));
    try std.testing.expect(stageContract(.perception_update).reads.contains(.stimuli));
    try std.testing.expect(external_resources.contains(.structural_events));
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
        .contact_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
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
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 4,
        .dig = dig_config,
        .movement_body_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
    });

    // The NPC crossed from (5,3) into the just-dug hole cell (6,3) and fell to
    // level 1 within this same step. That is only reachable if dig_world_edit's
    // tile change committed to `WorldSystem` before plane_traversal read that
    // cell's floor state this step -- a misordering would leave the tile solid
    // until next step and the NPC would not fall yet.
    try std.testing.expectEqual(@as(?u16, 1), data.worldLevelConst(npc));
    const floor1 = world.denseFloorLayerForLevel(1).?;
    try std.testing.expect(!denseTileBlocksMovement(&world, floor1, 6, 3));
}

test "pipeline update after reserve allocates nothing on frame streams with dig, fall, and contact" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    // Same dig-then-fall fixture as the causal order test, plus an overlapping
    // pair at the origin so collision writes a contact. The pair sits off the
    // dug cell, so the fall still lands. Frame streams are reserved, then
    // swapped to a failing allocator; world and data allocators stay real
    // because the dig and the landing carve mutate tiles.
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    var world = try testMinimalMultiLevelWorld(&meta);
    defer world.deinit();

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    player.current_level = 0;
    placePlayerFlush(&data, player, .{ 5, 3 });
    data.facingPtr(player.entity).?.* = .right;

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

    const bumper = try data.createEntity();
    try data.setMovementBody(bumper, .{
        .position = .{ .x = 0, .y = 0 },
        .previous_position = .{ .x = 0, .y = 0 },
        .velocity = .{},
        .speed = 0,
    });
    try data.setCollisionBounds(bumper, .{ .size = .{ .x = 32, .y = 32 } });
    try data.setCollisionResponse(bumper, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    try data.setWorldLevel(bumper, 0);
    try data.setSimulationTier(bumper, .locomotion);

    const wall = try data.createEntity();
    try data.setMovementBody(wall, .{
        .position = .{ .x = 16, .y = 0 },
        .previous_position = .{ .x = 16, .y = 0 },
        .velocity = .{},
        .speed = 0,
    });
    try data.setCollisionBounds(wall, .{ .size = .{ .x = 32, .y = 32 } });
    try data.setCollisionResponse(wall, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    try data.setWorldLevel(wall, 0);
    try data.setSimulationTier(wall, .locomotion);

    const dig_config = try DigConfig.fromMeta(&meta);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(16, 128, 32, 32, 16, 16);
    try frame.reservePathRequests(4, 8);
    try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);
    try frame.reserveActionIntents(4, 4);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 8,
        .dig = dig_config,
        .movement_body_capacity = 8,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
        },
    });
    defer pipeline.deinit();
    try pipeline.reserve(&frame, 8);

    frame.beginStep();
    frame.dig_intent = .hole;

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const fail_alloc = failing.allocator();
    const saved_events = frame.events.stream.allocator;
    const saved_stimuli = frame.stimuli.allocator;
    const saved_contacts = frame.contacts.allocator;
    const saved_structural = frame.structural_commands.allocator;
    const saved_intents = frame.intents.allocator;
    const saved_nav = frame.navigation_intents.allocator;
    const saved_paths = frame.path_requests.allocator;
    const saved_triggers = frame.collision_triggers.allocator;
    const saved_actions = frame.action_intents.allocator;
    frame.events.stream.allocator = fail_alloc;
    frame.stimuli.allocator = fail_alloc;
    frame.contacts.allocator = fail_alloc;
    frame.structural_commands.allocator = fail_alloc;
    frame.intents.allocator = fail_alloc;
    frame.navigation_intents.allocator = fail_alloc;
    frame.path_requests.allocator = fail_alloc;
    frame.collision_triggers.allocator = fail_alloc;
    frame.action_intents.allocator = fail_alloc;
    defer {
        frame.events.stream.allocator = saved_events;
        frame.stimuli.allocator = saved_stimuli;
        frame.contacts.allocator = saved_contacts;
        frame.structural_commands.allocator = saved_structural;
        frame.intents.allocator = saved_intents;
        frame.navigation_intents.allocator = saved_nav;
        frame.path_requests.allocator = saved_paths;
        frame.collision_triggers.allocator = saved_triggers;
        frame.action_intents.allocator = saved_actions;
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
        .sim_view = fullWorldSimView(&world),
    });

    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(?u16, 1), data.worldLevelConst(npc));
    try std.testing.expect(frame.contacts.mergedItems().len > 0);
    try std.testing.expect(frame.stimuli.mergedItems().len > 0);
}

test "eventCapacitySum equals capacity_limit after reserve" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 64, 64, .{
        .movement_body_capacity = 8,
        .structural_headroom = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
        },
    });
    defer pipeline.deinit();
    try frame.reserveStreams(4, 0, 4, 4, 4, 4);
    try pipeline.reserve(&frame, 8);

    // dig 2 + perception 0 + affect 0 (no AiPerception/AiAffect rows) + plane (8 + 1) +
    // action_react 64 + structural (pipeline destructible 64 + caller 4) + nav 1.
    try std.testing.expectEqual(@as(usize, 144), pipeline.eventCapacitySum());
    try std.testing.expectEqual(@as(?usize, pipeline.eventCapacitySum()), frame.events.capacity_limit);
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
        .contact_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
        },
    });
    defer pipeline.deinit();

    // The world has no chunks, so the full-world `sim_view` yields no cognition
    // region and the AI gather falls back to full-active with no stagger gating —
    // the wanderer runs every step.
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
        .sim_view = fullWorldSimView(&world),
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
            .sim_view = fullWorldSimView(&world),
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
        .contact_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
    });

    // Both stages ran over the same scoped agent this step (observable stage
    // order: ai_memory processes after perception and before ai reads it).
    try std.testing.expectEqual(@as(usize, 1), pipeline.ai_memory.memory_dense_indices.items.len);
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
        .contact_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
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
    // A level must exist or line of sight fails closed (an invalid level
    // blocks every cell), never reporting a target visible.
    _ = try world.addLevel(0);
    // The level gives the world a chunk, so the full-world `sim_view` applies
    // stagger: keep both agents thinking this step.
    try markAllAlwaysActive(&data);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 4, 4, 4, 4, 4);
    try frame.reservePathRequests(2, 2);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
    });

    // Both perception and affect ran this step over the observer (the only
    // entity carrying AiAffect); both agents (observer + hostile) reach AI.
    try std.testing.expectEqual(@as(usize, 1), stats.perception.observer_count);
    try std.testing.expectEqual(@as(usize, 1), pipeline.affect.rows.len);
    try std.testing.expectEqual(@as(usize, 2), stats.ai.entity_count);

    // Affect observed this step's perception output (hostile visible, close),
    // proving it ran after perception -- a stale/previous-step read would
    // have left fear/aggression at their zero default.
    const affect_after = data_test_support.aiAffect(&data, observer).?;
    try std.testing.expect(affect_after.fear > 0);
    try std.testing.expect(affect_after.aggression > 0);
}

test "pipeline fear selects flee before movement, not only a positive drive" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);

    const observer = try data.createEntity();
    try data.setMovementBody(observer, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 40 });
    try data.setAiAgent(observer, .{
        .active_behavior = .wander,
        .wander_amplitude = 0,
        .gain_flee = 1,
        .gain_pursue = 0,
        .gain_wander = 0,
    });
    try data.setFaction(observer, .player);
    try data.setAiPerception(observer, .{});
    try data.setAiAffect(observer, .{});

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
    _ = try world.addLevel(0);
    // The level gives the world a chunk, so the full-world `sim_view` applies
    // stagger: pin the observer thinking on this single step (not a stagger test).
    try markAllAlwaysActive(&data);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    try frame.reservePathRequests(2, 2);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 4,
        .movement_body_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
        },
    });
    defer pipeline.deinit();
    try pipeline.reserve(&frame, 4);

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
        .sim_view = fullWorldSimView(&world),
    });

    try std.testing.expectEqual(@import("data_system.zig").AiBehavior.flee, data_test_support.aiAgent(&data, observer).?.active_behavior);
}

test "pipeline perception acquire refreshes memory last_known the same step" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);

    const observer = try data.createEntity();
    try data.setMovementBody(observer, .{ .position = .{ .x = 0, .y = 0 }, .previous_position = .{ .x = 0, .y = 0 }, .velocity = .{}, .speed = 0 });
    try data.setAiAgent(observer, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setFaction(observer, .player);
    try data.setAiPerception(observer, .{});
    try data.setAiMemory(observer, .{
        .last_known_target = player.entity,
        .last_known_x = 0,
        .last_known_y = 100,
        .staleness = 10,
    });

    const hostile = try data.createEntity();
    try data.setMovementBody(hostile, .{ .position = .{ .x = 10, .y = 0 }, .previous_position = .{ .x = 10, .y = 0 }, .velocity = .{}, .speed = 0 });
    try data.setAiAgent(hostile, .{ .active_behavior = .wander });
    try data.setFaction(hostile, .hostile);

    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    _ = try world.addLevel(0);
    // The level gives the world a chunk, so the full-world `sim_view` applies
    // stagger: pin the observer thinking on this single step (not a stagger test).
    try markAllAlwaysActive(&data);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    try frame.reservePathRequests(2, 2);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 4,
        .movement_body_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
    });

    const memory = data_test_support.aiMemory(&data, observer).?;
    try std.testing.expect(memory.last_known_target.eql(hostile));
    try std.testing.expectApproxEqAbs(@as(f32, 10), memory.last_known_x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), memory.last_known_y, 0.01);
}

test "chunk_derive matches the pose after a contact push crosses a chunk boundary" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    const body = data.movementBodyPtr(player.entity).?;
    body.previous_x.* = 20;
    body.previous_y.* = 0;
    body.position_x.* = 20;
    body.position_y.* = 0;
    body.velocity_x.* = 0;
    body.velocity_y.* = 0;
    try data.setCollisionBounds(player.entity, .{ .size = .{ .x = 32, .y = 32 } });
    try data.setCollisionResponse(player.entity, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    try data.setWorldLevel(player.entity, 0);

    const wall = try data.createEntity();
    try data.setMovementBody(wall, .{
        .position = .{ .x = 0, .y = 0 },
        .previous_position = .{ .x = 0, .y = 0 },
        .velocity = .{},
        .speed = 0,
    });
    try data.setCollisionBounds(wall, .{ .size = .{ .x = 32, .y = 32 } });
    try data.setCollisionResponse(wall, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    try data.setWorldLevel(wall, 0);
    try data.setSimulationTier(wall, .locomotion);

    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 128,
        .height = 64,
        .tile_size = 32,
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    _ = try world.addLevel(0);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    try frame.reservePathRequests(2, 2);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 128, 64, .{
        .contact_capacity = 4,
        .movement_body_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .bounds_width = 128,
        .bounds_height = 64,
        .sim_view = fullWorldSimView(&world),
    });

    const settled = data.movementBodyConst(player.entity).?;
    const mi = data.movementBodyDenseIndex(player.entity).?;
    const chunk = data.scopeColumnsSliceConst().chunk_x[mi];
    const expected: i32 = @intFromFloat(@floor(settled.position.x / 32.0));
    try std.testing.expectEqual(expected, chunk);
    try std.testing.expect(settled.position.x >= 32);
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
    // A level must exist or line of sight fails closed (an invalid level
    // blocks every cell), never reporting a target visible.
    _ = try world.addLevel(0);
    // The level gives the world a chunk, so the full-world `sim_view` applies
    // stagger: pin the pursuer thinking on this single step (not a stagger test).
    try markAllAlwaysActive(&data);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 4, 4, 4, 4, 4);
    try frame.reservePathRequests(2, 2);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
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
const lane_count = @import("../core/simd.zig").lane_count;
const plane_entry_range_alignment_items = @import("systems/plane_entry.zig").plane_entry_range_alignment_items;
const warmLandingTerrain = @import("world/test_support.zig").warmLandingTerrain;
const denseTileBlocksMovement = @import("world/test_support.zig").denseTileBlocksMovement;
const PathRequest = @import("simulation.zig").PathRequest;
const RangeOutputStream = @import("simulation.zig").RangeOutputStream;
const contactsNaming = @import("systems/collision_response_test_support.zig").contactsNaming;
const testMinimalMultiLevelWorld = @import("pipeline_test_support.zig").testMinimalMultiLevelWorld;
const gateTestWorld = @import("pipeline_test_support.zig").gateTestWorld;
const testPlaneTraversalStage = @import("pipeline_test_support.zig").testPlaneTraversalStage;
const placePlayerFlush = @import("pipeline_test_support.zig").placePlayerFlush;
const runScopeRenderWindowScenario = @import("pipeline_test_support.zig").runScopeRenderWindowScenario;
const share_test_pathfinding = @import("pipeline_test_support.zig").share_test_pathfinding;
const addShareTestAgent = @import("pipeline_test_support.zig").addShareTestAgent;
const moveShareTestAgent = @import("pipeline_test_support.zig").moveShareTestAgent;
const shareTestWorld = @import("pipeline_test_support.zig").shareTestWorld;
const countPerceptionEvents = @import("pipeline_test_support.zig").countPerceptionEvents;
const TestAllocatorSwap = @import("pipeline_test_support.zig").TestAllocatorSwap;
const pinPipelineThreadedProfiles = @import("pipeline_test_support.zig").pinPipelineThreadedProfiles;
const TestAllocatorCounters = @import("pipeline_test_support.zig").TestAllocatorCounters;
const fullWorldSimView = @import("pipeline_test_support.zig").fullWorldSimView;
const markAllAlwaysActive = @import("pipeline_test_support.zig").markAllAlwaysActive;
const commitAndSyncLikeDemo = @import("pipeline_test_support.zig").commitAndSyncLikeDemo;
const writeStructuralCommands = @import("pipeline_test_support.zig").writeStructuralCommands;
const cellBody = @import("pipeline_test_support.zig").cellBody;
const growth_npc_visual = @import("pipeline_test_support.zig").growth_npc_visual;
const growthNpcTemplate = @import("pipeline_test_support.zig").growthNpcTemplate;
const growthSteeringTemplate = @import("pipeline_test_support.zig").growthSteeringTemplate;
const runPathingCrowdGrowthScenario = @import("pipeline_test_support.zig").runPathingCrowdGrowthScenario;
const sealedPursuerTemplate = @import("pipeline_test_support.zig").sealedPursuerTemplate;
const addSealedGoalBoxes = @import("pipeline_test_support.zig").addSealedGoalBoxes;
const runApplyIntentsScenario = @import("pipeline_test_support.zig").runApplyIntentsScenario;
const runContactBoundScenario = @import("pipeline_test_support.zig").runContactBoundScenario;
const runCollisionRespondScenario = @import("pipeline_test_support.zig").runCollisionRespondScenario;
const minimalSyncWorld = @import("pipeline_test_support.zig").minimalSyncWorld;
const sync_test_pathfinding = @import("pipeline_test_support.zig").sync_test_pathfinding;
const addSteeringAgents = @import("pipeline_test_support.zig").addSteeringAgents;
const responderTemplate = @import("pipeline_test_support.zig").responderTemplate;
const NavSeamFixture = @import("pipeline_test_support.zig").NavSeamFixture;
const commitStructuralBurst = @import("pipeline_test_support.zig").commitStructuralBurst;
const addStaticBox = @import("pipeline_test_support.zig").addStaticBox;

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

    world_gate.gatePlayerToWalkableTiles(&world, &data, player);

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
    world_gate.gatePlayerToWalkableTiles(&world, &data, player);
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
        .movement_body_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
    });

    // Dormant NPC never transitioned: the tier gate skipped it despite straddling
    // the hole cell.
    try std.testing.expectEqual(@as(?u16, 0), data.worldLevelConst(dormant_npc));
    try std.testing.expectEqual(@as(f32, 4 * 32), data.movementBodyConst(dormant_npc).?.position.x);

    // Active-tier NPC still falls exactly as before the fix: it crossed into the
    // hole cell, landed on level 1, and its landing cell was carved walkable.
    try std.testing.expectEqual(@as(?u16, 1), data.worldLevelConst(active_npc));
    const floor1 = world.denseFloorLayerForLevel(1).?;
    try std.testing.expect(!denseTileBlocksMovement(&world, floor1, 6, 3));
}

test "pipeline runs the perception stage scoped to cognition-tier ai agents without perturbing movement/ai" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);

    // Cognition-tier observer (default tier): included in the halo and think
    // lists, so it becomes both an AI gather row and a perception gather row.
    const observer = try data.createEntity();
    try data.setMovementBody(observer, .{ .position = .{ .x = 50, .y = 50 }, .previous_position = .{ .x = 50, .y = 50 }, .velocity = .{}, .speed = 20 });
    try data.setAiAgent(observer, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setAiPerception(observer, .{ .vision_range = 100 });

    // Locomotion-tier: `gatherAiPopulations` excludes it (tier.allowsCognition()
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
        .contact_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
    });

    // Scoping: perception's gather ran only over the cognition-tier ai agent,
    // matching AI's own scoped population (both read the same think list)
    // even though two entities in `DataSystem` carry `AiPerception`. With a
    // struct-literal world (`cognition_region == null`) halo == think.
    try std.testing.expectEqual(@as(usize, 1), stats.ai.entity_count);
    try std.testing.expectEqual(@as(usize, 1), stats.perception.observer_count);
    try std.testing.expectEqual(@as(usize, 1), pipeline.spatial_index.view().entryCount());
    try std.testing.expectEqual(@as(usize, 0), frame.events.stats.entity_perceived);
    try std.testing.expectEqual(@as(usize, 0), frame.events.stats.entity_lost);
    try std.testing.expectEqual(@as(usize, 0), frame.events.stats.dropped);

    // No hostile candidate in range (default/neutral factions never read as
    // hostile toward each other or the player): the in-scope observer's sensed
    // state stays cold.
    const observer_perception = data_test_support.aiPerception(&data, observer).?;
    try std.testing.expect(!observer_perception.target_visible);
    try std.testing.expectEqual(EntityId.invalid, observer_perception.nearest_threat);

    // Regression safety: inserting the perception stage between spatial_index
    // and AI does not perturb the existing movement stage's output — every
    // non-dormant body (player + both NPCs) still integrates.
    try std.testing.expectEqual(@as(usize, 3), stats.movement.body_count);
}

test "simulation scope region ignores the render visibility window" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    // Run A rewrites the render window between steps as varying-alpha render
    // frames would; run B never renders. Cognition region, think set, stagger
    // skips, queued tier commands, and movement/AI columns must be identical.
    const with_render = try runScopeRenderWindowScenario(true);
    const without_render = try runScopeRenderWindowScenario(false);
    try std.testing.expectEqualDeep(without_render, with_render);
}

test "pipeline dual-list perception: think observer acquires off-phase halo hostile" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);

    // First pipeline.update advances step_count to 1 → stagger_step 1. The
    // ally thinks this step; the hostile is halo-only (phase 0).
    const ally = try data.createEntity();
    try data.setMovementBody(ally, .{
        .position = .{ .x = 8, .y = 16 },
        .previous_position = .{ .x = 8, .y = 16 },
        .velocity = .{ .x = 100, .y = 0 },
        .speed = 20,
    });
    try data.setAiAgent(ally, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setFaction(ally, .ally);
    try data.setAiPerception(ally, .{});
    try data.setSimulationMetadata(ally, .{
        .tier = .cognition,
        .chunk = .{ .x = 0, .y = 0 },
        .stagger_phase = 1,
    });

    const hostile = try data.createEntity();
    try data.setMovementBody(hostile, .{
        .position = .{ .x = 24, .y = 16 },
        .previous_position = .{ .x = 24, .y = 16 },
        .velocity = .{ .x = -100, .y = 0 },
        .speed = 20,
    });
    try data.setAiAgent(hostile, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setFaction(hostile, .hostile);
    try data.setAiPerception(hostile, .{});
    try data.setSimulationMetadata(hostile, .{
        .tier = .cognition,
        .chunk = .{ .x = 0, .y = 0 },
        .stagger_phase = 0,
    });

    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    _ = try world.addLevel(0);
    // Migrated from a render window at overscan 0: on this single-chunk world
    // the sim view's overscan-1 region clamps to the same chunk [0,1).
    const sim_view = Rect{ .x = 0, .y = 0, .w = 32, .h = 32 };
    const expected_view = ActiveRegion{ .min = .{ .x = 0, .y = 0 }, .max_exclusive = .{ .x = 1, .y = 1 } };
    try std.testing.expectEqual(expected_view, world.chunkRegionForWorldRect(sim_view, sim_view_overscan_chunks).?);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 4, 4, 4, 4, 4);
    try frame.reservePathRequests(2, 2);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = sim_view,
    });

    const h: i32 = cognition_halo_chunks;
    try std.testing.expectEqual(ActiveRegion{
        .min = .{ .x = -h, .y = -h },
        .max_exclusive = .{ .x = 1 + h, .y = 1 + h },
    }, stats.scope.active_region.?);
    try std.testing.expectEqual(@as(usize, 2), pipeline.spatial_index.view().entryCount());
    try std.testing.expectEqual(@as(usize, 1), stats.perception.observer_count);
    try std.testing.expectEqual(@as(usize, 1), stats.ai.entity_count);

    const ally_perception = data_test_support.aiPerception(&data, ally).?;
    try std.testing.expect(ally_perception.target_visible);
    try std.testing.expectEqual(hostile.index, ally_perception.nearest_threat.index);

    const hostile_perception = data_test_support.aiPerception(&data, hostile).?;
    try std.testing.expect(!hostile_perception.target_visible);
    try std.testing.expectEqual(EntityId.invalid, hostile_perception.nearest_threat);
}

test "default-config pipeline publishes every perception acquisition and refreshes memory" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    // Two observer/hostile pairs, each observer nearest its own hostile.
    const observer_a = try addShareTestAgent(&data, 0, .player, true);
    const hostile_a = try addShareTestAgent(&data, 10, .hostile, false);
    const observer_b = try addShareTestAgent(&data, 300, .player, true);
    const hostile_b = try addShareTestAgent(&data, 310, .hostile, false);

    var world = try shareTestWorld();
    defer world.deinit();
    // Every observer acquires in one step (the share's worst case), so opt out of
    // the full-world `sim_view`'s stagger.
    try markAllAlwaysActive(&data);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    // Production order: init derives the shares, then the frame takes the bound.
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 2048, 450, .{ .pathfinding = share_test_pathfinding });
    defer pipeline.deinit();
    try std.testing.expectEqual(@as(usize, 4), pipeline.perception_max_events_per_step);
    try frame.reserveStreams(4, 0, 4, 4, 4, 4);
    try frame.reservePathRequests(2, 2);
    try pipeline.reserve(&frame, 5);

    frame.beginStep();
    _ = try pipeline.update(.{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 2048,
        .bounds_height = 450,
        .sim_view = fullWorldSimView(&world),
    });

    try std.testing.expectEqual(@as(usize, 2), countPerceptionEvents(&frame).perceived);
    try std.testing.expectEqual(@as(usize, 0), frame.events.stats.dropped);
    try std.testing.expect(data_test_support.aiMemory(&data, observer_a).?.last_known_target.eql(hostile_a));
    try std.testing.expect(data_test_support.aiMemory(&data, observer_b).?.last_known_target.eql(hostile_b));
}

test "derived perception share covers an identity swap for every observer" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    var near: [3]EntityId = undefined;
    var far: [3]EntityId = undefined;
    for (0..3) |index| {
        const base: f32 = @floatFromInt(index * 300);
        _ = try addShareTestAgent(&data, base, .player, true);
        near[index] = try addShareTestAgent(&data, base + 20, .hostile, false);
        far[index] = try addShareTestAgent(&data, base + 60, .hostile, false);
    }

    var world = try shareTestWorld();
    defer world.deinit();
    // Every observer swaps in one step (the share's worst case), so opt out of the
    // full-world `sim_view`'s stagger.
    try markAllAlwaysActive(&data);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 2048, 450, .{ .pathfinding = share_test_pathfinding });
    defer pipeline.deinit();
    try std.testing.expectEqual(@as(usize, 6), pipeline.perception_max_events_per_step);
    try frame.reserveStreams(4, 0, 10, 10, 10, 10);
    try frame.reservePathRequests(2, 2);
    try pipeline.reserve(&frame, 10);

    const context: SimulationPipelineUpdateContext = .{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 2048,
        .bounds_height = 450,
        .sim_view = fullWorldSimView(&world),
    };
    frame.beginStep();
    _ = try pipeline.update(context);
    try std.testing.expectEqual(@as(usize, 3), countPerceptionEvents(&frame).perceived);

    // The far hostile steps in front of the near one: every observer swaps identity
    // (lost + perceived) in one step.
    for (0..3) |index| {
        const base: f32 = @floatFromInt(index * 300);
        moveShareTestAgent(&data, far[index], base + 8);
    }
    frame.beginStep();
    _ = try pipeline.update(context);
    const counts = countPerceptionEvents(&frame);
    try std.testing.expectEqual(@as(usize, 3), counts.perceived);
    try std.testing.expectEqual(@as(usize, 3), counts.lost);
    try std.testing.expectEqual(@as(usize, 0), frame.events.stats.dropped);
}

test "derived affect share is the drive count times AiAffect rows" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..2) |index| {
        const entity = try addShareTestAgent(&data, @floatFromInt(index * 300), .player, false);
        try data.setAiAffect(entity, .{});
    }
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 2048, 450, .{ .pathfinding = share_test_pathfinding });
    defer pipeline.deinit();
    try std.testing.expectEqual(@as(usize, 2 * affect_events_per_row_max), pipeline.affect_max_events_per_step);
    try std.testing.expectEqual(@as(usize, 0), pipeline.perception_max_events_per_step);
}

test "perception share grows at the seam so newly created observers never truncate" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    var observers: [7]EntityId = undefined;
    for (0..3) |index| {
        const base: f32 = @floatFromInt(index * 300);
        observers[index] = try addShareTestAgent(&data, base, .player, true);
        _ = try addShareTestAgent(&data, base + 10, .hostile, false);
    }

    var world = try shareTestWorld();
    defer world.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 2048, 450, .{
        .pathfinding = share_test_pathfinding,
        .structural_headroom = 64,
    });
    defer pipeline.deinit();
    try std.testing.expectEqual(@as(usize, 6), pipeline.perception_max_events_per_step);
    try frame.reserveStreams(pipeline.eventCapacitySum(), 0, 7, 7, 7, 7 + 64);
    try frame.reservePathRequests(2, 2);
    try pipeline.reserve(&frame, 7);

    // Four observer + hostile pairs created through structural commands.
    var commands: [8]StructuralCommand = undefined;
    for (0..4) |index| {
        const base: f32 = @floatFromInt((index + 3) * 300);
        commands[index * 2] = .{ .create_entity = .{
            .movement_body = .{ .position = .{ .x = base, .y = 0 }, .previous_position = .{ .x = base, .y = 0 }, .velocity = .{}, .speed = 0 },
            .ai_agent = .{ .active_behavior = .wander, .gain_pursue = 0 },
            .faction = .player,
            .ai_perception = .{},
            .ai_memory = .{},
        } };
        commands[index * 2 + 1] = .{ .create_entity = .{
            .movement_body = .{ .position = .{ .x = base + 10, .y = 0 }, .previous_position = .{ .x = base + 10, .y = 0 }, .velocity = .{}, .speed = 0 },
            .ai_agent = .{ .active_behavior = .wander, .gain_pursue = 0 },
            .faction = .hostile,
        } };
    }
    frame.beginStep();
    try writeStructuralCommands(&frame, &commands);
    const sync = try commitAndSyncLikeDemo(&pipeline, &frame, &data, &world);
    try std.testing.expect(sync.grew);
    try std.testing.expectEqual(@as(usize, 7), data.populationRowCounts().ai_perceptions);
    try std.testing.expectEqual(perception_events_per_observer_max * grownPopulationCapacity(7), pipeline.perception_max_events_per_step);
    try std.testing.expectEqual(@as(usize, 64), pipeline.perception_max_events_per_step);
    try std.testing.expectEqual(@as(?usize, pipeline.eventCapacitySum()), frame.events.capacity_limit);

    // Every observer acquires in the same step: 7 events, none truncated. Opt the
    // whole committed population out of the full-world `sim_view`'s stagger so the
    // share's worst case is what runs.
    try markAllAlwaysActive(&data);
    frame.beginStep();
    _ = try pipeline.update(.{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 2048,
        .bounds_height = 450,
        .sim_view = fullWorldSimView(&world),
    });
    try std.testing.expectEqual(@as(usize, 7), countPerceptionEvents(&frame).perceived);
    try std.testing.expectEqual(@as(usize, 0), frame.events.stats.dropped);
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
        .movement_body_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
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
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
    });

    const body = data.movementBodyConst(player.entity).?;
    // End-of-step pose must not overlap solid tiles on level 1.
    try std.testing.expect(!world_gate.rectOverlapsSolidTile(&world, 1, body.position.x, body.position.y, 32, 32));
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
    // 16 tiles wide × chunk_size 8 → two chunks on X. Surface (level 0)
    // is fully walkable so the tile gate cannot undo the contact push.
    const tile_size = meta.tileSize();
    var world = try WorldSystem.initDemoFromMetaWithChunkSize(std.testing.allocator, &meta, tile_size * 16, tile_size * 8, 8);
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
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
    });

    const body = data.movementBodyConst(player.entity).?;
    const settled = world.chunkCoordForWorldPos(body.position.x, body.position.y);
    const meta_after = data_test_support.simulationMetadata(&data, player.entity).?;
    try std.testing.expectEqual(settled.x, meta_after.chunk.x);
    try std.testing.expectEqual(settled.y, meta_after.chunk.y);
    // Contact must have crossed the chunk-0 / chunk-1 boundary (cell 8 = chunk 1).
    try std.testing.expect(settled.x >= 1);
}

test "pipeline scope chunks and nav chunks are the world's chunks" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    // 16 x 8 tiles in 4-tile chunks: a 4 x 2 chunk grid.
    const tile_size = meta.tileSize();
    var world = try WorldSystem.initDemoFromMetaWithChunkSize(std.testing.allocator, &meta, tile_size * 16, tile_size * 8, 4);
    defer world.deinit();

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    player.current_level = 0;
    try data.setWorldLevel(player.entity, 0);
    placePlayerFlush(&data, player, .{ 9, 5 });

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    try frame.reservePathRequests(2, 2);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    // The world-less nav knobs and bounds differ from the world on purpose; the world wins.
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, tile_size * 25, tile_size * 3, .{
        .contact_capacity = 8,
        .nav_cell_size = tile_size / 4,
        .navigation_world = &world,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
            .nav_chunk_tiles = 16,
        },
    });
    defer pipeline.deinit();
    try std.testing.expectEqual(world.chunk_size_tiles, pipeline.pathfinding.graph.geometry.chunk_tiles);
    try std.testing.expectEqual(world.tile_size, pipeline.pathfinding.graph.cell_size);
    try std.testing.expectEqual(@as(usize, world.width), pipeline.pathfinding.graph.geometry.width);
    try std.testing.expectEqual(@as(usize, world.height), pipeline.pathfinding.graph.geometry.height);

    frame.beginStep();
    _ = try pipeline.update(.{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = tile_size * 16,
        .bounds_height = tile_size * 8,
        .sim_view = fullWorldSimView(&world),
    });

    const body = data.movementBodyConst(player.entity).?;
    const world_chunk = world.chunkCoordForWorldPos(body.position.x, body.position.y);
    try std.testing.expectEqual(@as(i32, 2), world_chunk.x);
    try std.testing.expectEqual(@as(i32, 1), world_chunk.y);
    const scope_chunk = data_test_support.simulationMetadata(&data, player.entity).?.chunk;
    try std.testing.expectEqual(world_chunk.x, scope_chunk.x);
    try std.testing.expectEqual(world_chunk.y, scope_chunk.y);
    const nav_grid = pipeline.pathfinding.graph.grid(0).?;
    const nav_cell = nav_grid.indexForCell(nav_grid.worldToCellClamped(body.position)).?;
    const world_chunk_index: u32 = @intCast(world_chunk.y * @as(i32, @intCast(world.chunkGeometry().chunks_x)) + world_chunk.x);
    try std.testing.expectEqual(world_chunk_index, nav_grid.geometry.chunkOfCell(nav_cell));
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
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 4,
        .dig = dig_config,
        .movement_body_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
    });

    var tile_events: usize = 0;
    for (frame.events.mergedItems()) |event| {
        switch (event.payload) {
            .world_tile_changed => tile_events += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), tile_events);
    // Both landing carves share one events range (batched
    // publishWorldTileChangesAssumeCapacity), not two appendRequired ranges of one each.
    var batch_ranges: usize = 0;
    for (frame.events.range_stats.items) |range_stat| {
        if (range_stat.world_tile_changed >= 2) batch_ranges += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), batch_ranges);
    try std.testing.expectEqual(@as(usize, 2), frame.events.stats.world_tile_changed);

    const floor1 = world.denseFloorLayerForLevel(1).?;
    try std.testing.expect(!denseTileBlocksMovement(&world, floor1, 4, 3));
    try std.testing.expect(!denseTileBlocksMovement(&world, floor1, 6, 3));
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
    try std.testing.expect(denseTileBlocksMovement(&world, floor1, 4, 3));

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
    frame.beginStep();
    frame.events.setCapacityLimit(0);

    var dig = DigController.init(dig_config);
    try dig.reservePlaneScratch(std.testing.allocator, 4);
    defer dig.deinit();
    try std.testing.expectError(
        error.EventCapacityExceeded,
        testPlaneTraversalStage(&dig, &world, &data, &player, &frame),
    );
    try std.testing.expectEqual(landing_before, world.denseTile(floor1, 4, 3));
    try std.testing.expect(denseTileBlocksMovement(&world, floor1, 4, 3));
    try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);
}

test "plane traversal multi-entity world_level attach OOM leaves landings uncarved" {
    // Two NPCs missing world_level over holes. Stage reserves attach capacity
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
    try dig.reservePlaneScratch(std.testing.allocator, 4);
    defer dig.deinit();
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
    frame.beginStep();

    // Fail the first data allocation (world_levels ensureCapacity / attach).
    const original = data.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    data.allocator = failing.allocator();
    defer data.allocator = original;

    try std.testing.expectError(
        error.OutOfMemory,
        testPlaneTraversalStage(&dig, &world, &data, &player, &frame),
    );
    try std.testing.expectEqual(landing_a, world.denseTile(floor1, 4, 3));
    try std.testing.expectEqual(landing_b, world.denseTile(floor1, 6, 3));
    try std.testing.expectEqual(@as(usize, 0), frame.events.stats.world_tile_changed);
}

test "plane traversal multi-fall after its reserve commits and publishes allocation-free (FailingAllocator)" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
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
    frame.beginStep();

    var dig = DigController.init(dig_config);
    try dig.reservePlaneScratch(std.testing.allocator, 4);
    defer dig.deinit();
    // The reserve covers the scratch, the events, and the world_level rows; with the
    // landing chunk's batch scratch and pools warm, the commit allocates from none of them.
    try warmLandingTerrain(&world, dig.tunnel_tile, 1, .{ 4, 3 });
    var plane_entry = PlaneEntrySystem.init(std.testing.allocator);
    defer plane_entry.deinit();
    const entries = try plane_entry.gather(&data, &world, player.entity, dig.tunnel_tile, null);
    const reservation = try dig.reservePlaneTraversalStage(&world, &data, &player, &frame, entries, &serial_threads);
    try std.testing.expectEqual(@as(usize, 2), reservation.carves);

    const original_frame = frame.allocator;
    const original_events = frame.events.stream.allocator;
    const original_data = data.allocator;
    const original_world = world.allocator;
    const original_dig = dig.scratch_allocator.?;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const fail_alloc = failing.allocator();
    frame.allocator = fail_alloc;
    frame.events.stream.allocator = fail_alloc;
    data.allocator = fail_alloc;
    world.allocator = fail_alloc;
    dig.scratch_allocator = fail_alloc;
    defer {
        frame.allocator = original_frame;
        frame.events.stream.allocator = original_events;
        data.allocator = original_data;
        world.allocator = original_world;
        dig.scratch_allocator = original_dig;
    }

    try dig.commitPlaneTraversalStage(&world, &data, &player, &frame, reservation, &serial_threads);

    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
    // Each landing carve is published once, in one range.
    try std.testing.expectEqual(@as(usize, 2), frame.events.stats.world_tile_changed);
    try std.testing.expectEqual(@as(usize, 2), frame.events.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 1), frame.events.rangeCount());
    const floor1 = world.denseFloorLayerForLevel(1).?;
    try std.testing.expect(!denseTileBlocksMovement(&world, floor1, 4, 3));
    try std.testing.expect(!denseTileBlocksMovement(&world, floor1, 6, 3));
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
    // The chunked world's full-world `sim_view` applies stagger: pin the observer
    // thinking on this single step (dig-before-perception order, not stagger).
    try markAllAlwaysActive(&data);

    // Sanity: the observer does not hear anything before the step runs.
    try std.testing.expect(!data_test_support.aiPerception(&data, observer).?.heard_stimulus);

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
        .movement_body_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
    });

    // The observer heard this step's dig, which is only possible if dig produced
    // the stimulus before perception read `frame.stimuli` this step -- perception
    // running first would find the (freshly cleared) stimulus stream empty.
    try std.testing.expect(data_test_support.aiPerception(&data, observer).?.heard_stimulus);
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
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
        },
    });
    defer pipeline.deinit();

    // Simulate a collision impact deferred at the end of the prior step.
    pipeline.sensory.deferred_stimuli[0] = .{
        .position = .{ .x = impact_x, .y = impact_y },
        .intensity = defaultStimulusIntensity(.impact),
        .kind = .impact,
        .level = 0,
    };
    pipeline.sensory.deferred_stimulus_count = 1;

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
        .sim_view = fullWorldSimView(&world),
    });

    const perception = data_test_support.aiPerception(&data, observer).?;
    try std.testing.expect(perception.heard_stimulus);
    try std.testing.expectApproxEqAbs(impact_x, perception.heard_stimulus_x, 0.01);
    try std.testing.expectApproxEqAbs(impact_y, perception.heard_stimulus_y, 0.01);
    try std.testing.expectEqual(@as(usize, 0), pipeline.sensory.deferred_stimulus_count);
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
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
    });
    try std.testing.expect(stats.collision.contact_count > 0);
    try std.testing.expectEqual(@as(usize, 1), pipeline.sensory.deferred_stimulus_count);
    try std.testing.expectEqual(@import("simulation.zig").StimulusKind.impact, pipeline.sensory.deferred_stimuli[0].kind);
    try std.testing.expect(!data_test_support.aiPerception(&data, observer).?.heard_stimulus);

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
        .sim_view = fullWorldSimView(&world),
    });
    try std.testing.expect(data_test_support.aiPerception(&data, observer).?.heard_stimulus);
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
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
    });

    try std.testing.expect(stats.collision.contact_count > 0);
    // Response ran and zeroed the approach axis; the old post-response read would
    // see this and drop the impact. The snapshot-based gate must not.
    try std.testing.expectEqual(@as(f32, 0), data.movementBodyConst(player.entity).?.velocity.x);
    try std.testing.expectEqual(@as(usize, 1), pipeline.sensory.deferred_stimulus_count);
    try std.testing.expectEqual(@import("simulation.zig").StimulusKind.impact, pipeline.sensory.deferred_stimuli[0].kind);
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
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
    });

    const perception = data_test_support.aiPerception(&data, observer).?;
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
            .max_group_fields = 1,
            .worker_participant_count = 1,
        },
    });
    defer pipeline.deinit();
    pipeline.sensory.deferred_stimulus_count = stimulus_deferred_capacity;

    var deferred_dropped: usize = 0;
    var player_contacts: [16]u32 = undefined;
    pipeline.sensory.enqueuePlayerImpacts(
        &frame,
        &data,
        contactsNaming(&frame, player.entity, &player_contacts),
        0,
        &deferred_dropped,
    );
    try std.testing.expectEqual(@as(usize, 1), deferred_dropped);
    try std.testing.expectEqual(stimulus_deferred_capacity, pipeline.sensory.deferred_stimulus_count);
}

test "dig stage reserves its world edit before promoting, so a failed reserve keeps the deferred impacts" {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    var world = try testMinimalMultiLevelWorld(&meta);
    defer world.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    player.current_level = 1;
    try data.setWorldLevel(player.entity, 1);
    // Cell (3,3), facing right: the ramp goes into level 1's solid cell (4,3).
    placePlayerFlush(&data, player, .{ 3, 3 });
    data.facingPtr(player.entity).?.* = .right;

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 256, 256, .{
        .dig = try DigConfig.fromMeta(&meta),
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
        },
    });
    defer pipeline.deinit();
    pipeline.sensory.deferred_stimuli[0] = .{
        .position = .{ .x = 40, .y = 40 },
        .intensity = defaultStimulusIntensity(.impact),
        .kind = .impact,
        .level = 1,
    };
    pipeline.sensory.deferred_stimulus_count = 1;
    const context: SimulationPipelineUpdateContext = .{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 256,
        .bounds_height = 256,
        .sim_view = fullWorldSimView(&world),
    };
    const floor1 = world.denseFloorLayerForLevel(1).?;
    const before = world.denseTile(floor1, 4, 3);

    frame.beginStep();
    frame.dig_intent = .ramp;
    {
        // The ramp needs a tile block, a bits slot, and link storage: the first fails.
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        world.allocator = failing.allocator();
        defer world.allocator = std.testing.allocator;
        var step = SimulationPipeline.StepState.init(&pipeline, context);
        try std.testing.expectError(error.OutOfMemory, pipeline.stageDigWorldEdit(&step));
    }
    // Nothing moved: the impact is still deferred, the bus and world untouched.
    try std.testing.expectEqual(@as(usize, 1), pipeline.sensory.deferred_stimulus_count);
    try std.testing.expectEqual(@as(usize, 0), frame.stimuli.mergedItems().len);
    try std.testing.expectEqual(before, world.denseTile(floor1, 4, 3));
    try std.testing.expectEqual(@as(usize, 0), world.levelLinks().len);
    try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);

    // The retry promotes the impact and digs the ramp.
    frame.beginStep();
    frame.dig_intent = .ramp;
    var step = SimulationPipeline.StepState.init(&pipeline, context);
    try pipeline.stageDigWorldEdit(&step);
    try std.testing.expectEqual(@as(usize, 1), step.stimuli_promoted);
    try std.testing.expectEqual(@as(usize, 0), pipeline.sensory.deferred_stimulus_count);
    try std.testing.expectEqual(pipeline.dig.ramp_tile, world.denseTile(floor1, 4, 3));
    try std.testing.expectEqual(@as(?u16, 0), world.rampLinkOtherLevel(1, .{ .x = 4, .y = 3 }));
    try std.testing.expectEqual(@as(usize, 2), frame.stimuli.mergedItems().len);
}

test "promote drops deferred impacts when live bus is already full" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);

    for (0..stimulus_live_capacity) |i| {
        try frame.writeLiveStimulus(.{
            .position = .{ .x = @floatFromInt(i), .y = 0 },
            .intensity = 1,
            .kind = .dig,
            .level = 0,
        });
    }

    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
        },
    });
    defer pipeline.deinit();
    pipeline.sensory.deferred_stimuli[0] = .{
        .position = .{ .x = 200, .y = 0 },
        .intensity = defaultStimulusIntensity(.impact),
        .kind = .impact,
        .level = 0,
    };
    pipeline.sensory.deferred_stimulus_count = 1;

    var live_dropped: usize = 0;
    const promoted = try pipeline.sensory.promote(&frame, &live_dropped);
    try std.testing.expectEqual(@as(usize, 0), promoted);
    try std.testing.expectEqual(@as(usize, 1), live_dropped);
    try std.testing.expectEqual(@as(usize, 1), pipeline.sensory.deferred_stimulus_count);
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
        try frame.writeLiveStimulus(.{
            .position = .{ .x = @floatFromInt(i), .y = 0 },
            .intensity = 1,
            .kind = .dig,
            .level = 0,
        });
    }

    var live_dropped: usize = 0;
    const bus = SensoryBus.init(.{});
    try bus.appendFootstep(&frame, &data, player, &live_dropped);
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
            .max_group_fields = 1,
            .worker_participant_count = 1,
        },
    });
    defer pipeline.deinit();

    var deferred_dropped: usize = 0;
    var player_contacts: [16]u32 = undefined;
    pipeline.sensory.enqueuePlayerImpacts(
        &frame,
        &data,
        contactsNaming(&frame, player.entity, &player_contacts),
        0,
        &deferred_dropped,
    );
    try std.testing.expectEqual(stimulus_max_impacts_per_step, pipeline.sensory.deferred_stimulus_count);
    try std.testing.expectEqual(@as(usize, 4), deferred_dropped);
    try std.testing.expectEqual(@import("simulation.zig").StimulusKind.impact, pipeline.sensory.deferred_stimuli[0].kind);
    // First contact in merged order wins the first deferred slot (midpoint x = 10).
    try std.testing.expectApproxEqAbs(@as(f32, 10), pipeline.sensory.deferred_stimuli[0].position.x, 0.01);
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
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .contact_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
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
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .contact_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = fullWorldSimView(&world),
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
            .max_group_fields = 1,
            .worker_participant_count = 1,
        },
    });
    defer pipeline.deinit();

    var deferred_dropped: usize = 0;
    var player_contacts: [16]u32 = undefined;
    pipeline.sensory.enqueuePlayerImpacts(&frame, &data, contactsNaming(&frame, player.entity, &player_contacts), 0, &deferred_dropped);
    try std.testing.expectEqual(@as(usize, 0), pipeline.sensory.deferred_stimulus_count);
}

test "sticky dig linger reaches every stagger phase within the linger window" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    var world = try testMinimalMultiLevelWorld(&meta);
    defer world.deinit();
    // Migrated from a render window at overscan `cognition_halo_chunks`: the
    // 8×8-tile world is one chunk, so the sim view's overscan-1 region clamps
    // to the same chunk [0,1) and the cognition halo is unchanged.
    const sim_view = Rect{ .x = 0, .y = 0, .w = 800, .h = 450 };
    try std.testing.expectEqual(
        ActiveRegion{ .min = .{ .x = 0, .y = 0 }, .max_exclusive = .{ .x = 1, .y = 1 } },
        world.chunkRegionForWorldRect(sim_view, sim_view_overscan_chunks).?,
    );

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
        .movement_body_capacity = 4,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
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
        .sim_view = sim_view,
    };

    // Next advance lands on stagger slot 0 (phase-0 cohort); dig once there.
    pipeline.scope.step_count = 3;
    try data.setAiPerception(observer_phase1, .{ .hearing_range = 1000 });
    frame.beginStep();
    frame.dig_intent = .hole;
    _ = try pipeline.update(ctx);
    try std.testing.expect(data_test_support.aiPerception(&data, observer_phase0).?.heard_stimulus);
    try std.testing.expect(!data_test_support.aiPerception(&data, observer_phase1).?.heard_stimulus);

    // Following step runs stagger slot 1; sticky dig should reach phase-1.
    frame.beginStep();
    frame.dig_intent = .none;
    _ = try pipeline.update(ctx);
    try std.testing.expect(data_test_support.aiPerception(&data, observer_phase1).?.heard_stimulus);
    try std.testing.expectApproxEqAbs(dig_stimulus_x, data_test_support.aiPerception(&data, observer_phase1).?.heard_stimulus_x, 1.0);
    try std.testing.expectApproxEqAbs(dig_stimulus_y, data_test_support.aiPerception(&data, observer_phase1).?.heard_stimulus_y, 1.0);
    try std.testing.expect(!data_test_support.aiPerception(&data, observer_phase3).?.heard_stimulus);

    // Slot 2 then slot 3: the linger window (cognition_stagger_n - 1 = 3 steps)
    // must still carry the dig to the furthest cohort before it expires.
    frame.beginStep();
    frame.dig_intent = .none;
    _ = try pipeline.update(ctx);

    frame.beginStep();
    frame.dig_intent = .none;
    _ = try pipeline.update(ctx);
    try std.testing.expect(data_test_support.aiPerception(&data, observer_phase3).?.heard_stimulus);
    try std.testing.expectApproxEqAbs(dig_stimulus_x, data_test_support.aiPerception(&data, observer_phase3).?.heard_stimulus_x, 1.0);
    try std.testing.expectApproxEqAbs(dig_stimulus_y, data_test_support.aiPerception(&data, observer_phase3).?.heard_stimulus_y, 1.0);
}

const GrowthScenarioResult = struct {
    positions: [24][2]f32 = undefined,
    world_tile_changed: usize = 0,
};

/// A 3-level world grown from 4 to 37 rows through the population seam, one stationary
/// step, then one where 24 NPCs fall through dug holes; perception and affect run every
/// step. `max_worker_threads > 0` pins a multi-range partition; `prove_zero_alloc` runs the
/// steps with failing allocators; a non-null `retune` re-pins the partition mid-run.
fn runPopulationGrowthScenario(max_worker_threads: usize, prove_zero_alloc: bool, retune: ?AdaptiveWorkProfile) !GrowthScenarioResult {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    var world = try testMinimalMultiLevelWorld(&meta);
    defer world.deinit();
    // 24 holes on the surface: rows 0..5 at x in {1, 3, 5, 7}. Each NPC starts on the
    // hole's west neighbor (x in {0, 2, 4, 6}).
    const floor0 = world.denseFloorLayerForLevel(0).?;
    var start_cells: [24][2]u16 = undefined;
    for (0..6) |row| {
        for (0..4) |column| {
            const hole_x: u16 = @intCast(column * 2 + 1);
            _ = try world.clearDenseTile(floor0, hole_x, @intCast(row));
            start_cells[row * 4 + column] = .{ hole_x - 1, @intCast(row) };
        }
    }

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    player.current_level = 0;
    placePlayerFlush(&data, player, .{ 1, 7 });
    for (start_cells[0..3]) |cell| {
        const npc = try data.createEntity();
        try data.setMovementBody(npc, cellBody(cell));
        try data.setPrimitiveVisual(npc, growth_npc_visual);
        try data.setCollisionBounds(npc, .{ .size = .{ .x = 16, .y = 16 } });
        try data.setCollisionResponse(npc, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
        try data.setAiAgent(npc, .{ .active_behavior = .wander, .gain_pursue = 0 });
        try data.setAiPerception(npc, .{});
        try data.setAiAffect(npc, .{});
        try data.setWorldLevel(npc, 0);
    }

    const dig_config = try DigConfig.fromMeta(&meta);
    try warmLandingTerrain(&world, dig_config.tunnel_tile, 1, start_cells[0]);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = max_worker_threads });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 256, 256, .{
        .contact_capacity = 4,
        .dig = dig_config,
        .movement_body_capacity = 4,
        .structural_headroom = 200,
        .navigation_world = &world,
        .pathfinding = .{ .max_group_fields = 1, .worker_participant_count = 1 },
    });
    defer pipeline.deinit();
    try frame.reserveStreams(pipeline.eventCapacitySum(), 0, 4, 4, 4, 4 + 200);
    try frame.reservePathRequests(1, 4);
    try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try pipeline.reserve(&frame, 4);
    try std.testing.expectEqual(@as(usize, 4), pipeline.movement_body_capacity);

    const context: SimulationPipelineUpdateContext = .{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 256,
        .bounds_height = 256,
        .sim_view = fullWorldSimView(&world),
    };
    // Warm step at the initial population.
    frame.beginStep();
    _ = try pipeline.update(context);
    _ = try commitAndSyncLikeDemo(&pipeline, &frame, &data, &world);

    // Growth: 19 NPCs (7 commit events each) + 2 NPCs that also carry AiPerception and
    // AiAffect (9 each) + 12 steering-only agents parked on rows 6-7 (4 events each) =
    // 133 + 18 + 48 = 199 events within the caller's 200-event `structural_headroom`
    // (the pipeline's own action-react share sits on top of it).
    var commands: [33]StructuralCommand = undefined;
    for (start_cells[3..], 0..) |cell, index| commands[index] = growthNpcTemplate(cell);
    for (commands[0..2]) |*command| {
        command.create_entity.ai_perception = .{};
        command.create_entity.ai_affect = .{};
    }
    for (0..12) |index| {
        const cell = [2]u16{ @intCast(index % 8), @intCast(6 + index / 8) };
        commands[21 + index] = growthSteeringTemplate(cell);
    }
    const init_perception_share = pipeline.perception_max_events_per_step;
    const init_affect_share = pipeline.affect_max_events_per_step;
    frame.beginStep();
    try writeStructuralCommands(&frame, &commands);
    const sync = try commitAndSyncLikeDemo(&pipeline, &frame, &data, &world);
    try std.testing.expect(sync.grew);
    // 3 -> 5 perception/affect rows: the seam's share-growth arm ran too.
    try std.testing.expectEqual(@as(usize, 5), data.ai_perceptions.len());
    try std.testing.expectEqual(@as(usize, 5), data.ai_affects.len());
    try std.testing.expect(pipeline.perception_max_events_per_step > init_perception_share);
    try std.testing.expect(pipeline.affect_max_events_per_step > init_affect_share);

    // Every tracked capacity followed the committed rows.
    try std.testing.expectEqual(@as(usize, 37), data.populationRowCounts().population());
    try std.testing.expectEqual(grownPopulationCapacity(37), pipeline.movement_body_capacity);
    try std.testing.expectEqual(@as(usize, 80), pipeline.movement_body_capacity);
    try std.testing.expectEqual(@as(?usize, pipeline.eventCapacitySum()), frame.events.capacity_limit);
    try std.testing.expect(maxEventsPerStep(.plane_traversal, pipeline.eventBudgets()) >= 25);
    try std.testing.expect(pipeline.pathfinding.effective_agent_capacity >= 12);
    try std.testing.expect(pipeline.population_growth_logged);

    const targets: TestAllocatorSwap.Targets = .{ .pipeline = &pipeline, .frame = &frame, .data = &data, .world = &world, .threads = &threads };
    // Multi-worker runs pin a 2-worker, 16-item partition (3 movement ranges at 37
    // bodies), or 32-item (2 ranges) ahead of a retune; the tuners would keep this
    // small workload inline. (A 64-item range is inline at 37 bodies, so the retune
    // that adds ranges is 32 -> 16.)
    const first_items_per_range: usize = if (retune != null) 32 else 16;
    if (max_worker_threads > 0) pinPipelineThreadedProfiles(&pipeline, .{ .worker_threads = 2, .items_per_range = first_items_per_range });

    // First post-growth step, stationary. Every run takes it, so serial and
    // multi-worker runs stay step-for-step identical.
    frame.beginStep();
    var counters = TestAllocatorCounters.init();
    var counting_swap: TestAllocatorSwap = .{};
    if (prove_zero_alloc) counting_swap.install(targets, counters.allocators());
    const first_result = pipeline.update(context);
    if (prove_zero_alloc) counting_swap.restore(targets);
    const first_stats = try first_result;
    // The zero-allocation proof covers perception and affect only if they ran: the
    // 5 observers' stagger phases cover all four, so every step thinks at least one.
    try std.testing.expect(first_stats.perception.observer_count >= 1);
    try std.testing.expect(pipeline.affect.rows.len >= 1);
    if (max_worker_threads > 0) {
        try std.testing.expect(!first_stats.movement.batch.ran_inline);
        try std.testing.expectEqual(rangeCount(37, first_items_per_range), first_stats.movement.batch.range_count);
    }
    // The seam reserved every capacity for every partition (per-range
    // outputs are item-count windows, tallies and broadphase slots are reserved to
    // `maxRangeCount`), so the first post-growth step allocates nothing on any owner.
    if (prove_zero_alloc) try counters.expectOnlyOwnersAllocated(&.{});

    if (retune) |profile| {
        // A partition retune to more ranges, with every allocator failing.
        pinPipelineThreadedProfiles(&pipeline, profile);
        frame.beginStep();
        var retune_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        var retune_swap: TestAllocatorSwap = .{};
        if (prove_zero_alloc) retune_swap.install(targets, .uniform(retune_failing.allocator()));
        const retune_result = pipeline.update(context);
        if (prove_zero_alloc) retune_swap.restore(targets);
        const retune_stats = try retune_result;
        try std.testing.expectEqual(rangeCount(37, profile.items_per_range), retune_stats.movement.batch.range_count);
        try std.testing.expect(retune_stats.perception.observer_count >= 1);
        try std.testing.expect(pipeline.affect.rows.len >= 1);
        try std.testing.expectEqual(@as(usize, 0), retune_failing.allocations);
    }

    // All 24 NPCs step east into their hole this step.
    const ai_entities = data.aiAgentSliceConst().entities;
    try std.testing.expectEqual(@as(usize, 24), ai_entities.len);
    for (ai_entities) |npc| {
        try data.setSimulationTier(npc, .locomotion);
        const body = data.movementBodyPtr(npc).?;
        body.velocity_x.* = 2000;
        body.velocity_y.* = 0;
    }

    frame.beginStep();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    var swap: TestAllocatorSwap = .{};
    if (prove_zero_alloc) swap.install(targets, .uniform(failing.allocator()));
    const result = pipeline.update(context);
    if (prove_zero_alloc) swap.restore(targets);
    const fall_stats = try result;
    try std.testing.expectEqual(@as(usize, 0), fall_stats.plane_entry_windows_grown);

    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 0), frame.events.stats.dropped);
    try std.testing.expectEqual(@as(usize, 24), frame.events.stats.world_tile_changed);
    const floor1 = world.denseFloorLayerForLevel(1).?;
    var out: GrowthScenarioResult = .{ .world_tile_changed = frame.events.stats.world_tile_changed };
    for (ai_entities, 0..) |npc, index| {
        try std.testing.expectEqual(@as(?u16, 1), data.worldLevelConst(npc));
        const position = data.movementBodyConst(npc).?.position;
        const cell = world.cellContaining(position.x + 16, position.y + 16).?;
        try std.testing.expect(!denseTileBlocksMovement(&world, floor1, cell.x, cell.y));
        out.positions[index] = .{ position.x, position.y };
    }
    try std.testing.expectEqual(@as(u64, 0), pipeline.dig.plane_scratch_grown);
    try std.testing.expectEqual(@as(u64, 0), pipeline.plane_entry.windows_grown);
    return out;
}

test "population seam grows every pipeline capacity so the next step allocates nothing" {
    _ = try runPopulationGrowthScenario(0, true, null);
}

test "population growth on the multi-worker path allocates nothing on the first step after growth" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    _ = try runPopulationGrowthScenario(2, true, null);
}

test "a partition retune after population growth allocates nothing" {
    // 2 workers at 32-item ranges, then re-pinned to 16-item ranges (2 -> 3 ranges at
    // 37 bodies): no per-range output warms in-stage on the new partition.
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    _ = try runPopulationGrowthScenario(2, true, .{ .worker_threads = 2, .items_per_range = 16 });
}

test "population growth scenario is identical on the serial and multi-worker paths" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const serial = try runPopulationGrowthScenario(0, false, null);
    const threaded = try runPopulationGrowthScenario(2, false, null);
    try std.testing.expectEqual(serial.world_tile_changed, threaded.world_tile_changed);
    for (serial.positions, threaded.positions) |a, b| {
        try std.testing.expectEqual(a[0], b[0]);
        try std.testing.expectEqual(a[1], b[1]);
    }
}

test "a pathing crowd grown at the population seam keeps its first step's growth to the counted path registry, then runs goal resolve, path intake and registry flush threaded allocating nothing" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    try runPathingCrowdGrowthScenario(16, .{ .worker_threads = 2, .items_per_range = 16 });
}

test "a partition retune after a pathing crowd grows runs goal resolve, path intake and registry flush threaded allocating nothing" {
    // 22 items: one 32-item range, then two 16-item ranges.
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    try runPathingCrowdGrowthScenario(32, .{ .worker_threads = 2, .items_per_range = 16 });
}

test "after population growth the seam's stream range counts are the binding reserve and every producer fills them without allocating" {
    // The frame reserves one range per stream at init, so only the population seam sizes
    // the ranges. Seven bodies (player, five walls, a crate) grow by 25 pursuers to 32
    // rows (capacity 64), then 32 more fill the capacity without another growth, so on a
    // 16-item partition every producer appends its bound's ranges.
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 25,
        .height = 15,
        .tile_size = 32,
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    _ = try world.addLevel(0);
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    placePlayerFlush(&data, player, .{ 12, 7 });
    try addSealedGoalBoxes(&data);
    const crate = try data.createEntity();
    try data.setMovementBody(crate, .{ .position = .{ .x = 0, .y = 0 } });
    try data.setDestructible(crate, .{ .hit_points = 1 });

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    const headroom: usize = 256;
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .movement_body_capacity = 8,
        .structural_headroom = headroom,
        .pathfinding = .{ .max_group_fields = 1, .worker_participant_count = threads.participantSlotCount() },
    });
    defer pipeline.deinit();
    try frame.reserveStreams(1, 0, 8, 8, 8, 8 + pipeline.structuralCommandHeadroom());
    try frame.reservePathRequests(1, 8);
    try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try pipeline.reserve(&frame, 8);
    const context: SimulationPipelineUpdateContext = .{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 800,
        .bounds_height = 450,
        .sim_view = fullWorldSimView(&world),
    };
    frame.beginStep();
    _ = try pipeline.update(context);
    _ = try commitAndSyncLikeDemo(&pipeline, &frame, &data, &world);

    var commands: [32]StructuralCommand = undefined;
    for (commands[0..25], 0..) |*command, index| command.* = sealedPursuerTemplate(index);
    frame.beginStep();
    try writeStructuralCommands(&frame, commands[0..25]);
    try std.testing.expect((try commitAndSyncLikeDemo(&pipeline, &frame, &data, &world)).grew);
    try std.testing.expectEqual(@as(usize, 64), pipeline.movement_body_capacity);
    for (&commands, 25..) |*command, index| command.* = sealedPursuerTemplate(index);
    frame.beginStep();
    try writeStructuralCommands(&frame, &commands);
    try std.testing.expect(!(try commitAndSyncLikeDemo(&pipeline, &frame, &data, &world)).grew);
    try std.testing.expectEqual(@as(usize, 64), data.movementBodySliceConst().entities.len);
    try markAllAlwaysActive(&data);
    // The crate alone is tier-policed, and its tier is wrong: the policy changes it, so
    // the tier stage appends every range.
    var crate_metadata = data_test_support.simulationMetadata(&data, crate).?;
    crate_metadata.always_active = false;
    crate_metadata.tier = .dormant;
    try data.setSimulationMetadata(crate, crate_metadata);
    pinPipelineThreadedProfiles(&pipeline, .{ .worker_threads = 2, .items_per_range = 16 });

    const targets: TestAllocatorSwap.Targets = .{ .pipeline = &pipeline, .frame = &frame, .data = &data, .world = &world, .threads = &threads };
    frame.beginStep();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    var swap: TestAllocatorSwap = .{};
    swap.install(targets, .uniform(failing.allocator()));
    // The caller queues its whole headroom as single-command ranges, and the player hits
    // the crate.
    const caller_result = blk: {
        for (0..headroom) |_| {
            const range = frame.structural_commands.appendRangeCounts(1) catch |err| break :blk err;
            frame.structural_commands.addCount(range, 1);
            frame.structural_commands.prefixAppendedRanges(range) catch |err| break :blk err;
            var writer = frame.structural_commands.rangeWriter(range);
            writer.write(.{ .set_simulation_tier = .{ .entity = player.entity, .tier = .cognition } });
            writer.finish();
            frame.structural_commands.finishWrite();
        }
        frame.appendActionIntent(.{ .entity = player.entity, .kind = .interact, .target = crate }) catch |err| break :blk err;
        break :blk {};
    };
    const result = if (caller_result) |_| pipeline.update(context) else |err| err;
    swap.restore(targets);
    const stats = try result;
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 1), stats.destructibles_destroyed);
    // Each stream's writers appended exactly its seam bound.
    try std.testing.expectEqual(pipeline.navigationIntentRangeCount(), frame.navigation_intents.counts.items.len);
    try std.testing.expectEqual(pipeline.steeringStreamRangeCount(), frame.intents.counts.items.len);
    try std.testing.expectEqual(pipeline.steeringStreamRangeCount(), frame.path_requests.counts.items.len);
    try std.testing.expectEqual(pipeline.structuralCommandRangeCount(), frame.structural_commands.counts.items.len);
    try std.testing.expectEqual(@as(usize, 0), stats.steering.path_request_count);
}

test "the AI movement intent apply runs on workers in the pipeline, allocation-free and matching the serial step" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const serial = try runApplyIntentsScenario(0);
    const threaded = try runApplyIntentsScenario(2);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&serial.velocity_x), std.mem.sliceAsBytes(&threaded.velocity_x));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&serial.velocity_y), std.mem.sliceAsBytes(&threaded.velocity_y));
}

test "production steps on workers record nothing into the thread system's shared tuner" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    // Alternating factions so observers sense hostiles; 4 px apart under 16 px bounds, so
    // every body overlaps its nearest neighbours and the narrowphase spans several ranges.
    const agent_count: usize = 64;
    for (0..agent_count) |index| {
        const agent = try addShareTestAgent(&data, 40 + @as(f32, @floatFromInt(index)) * 4, if (index % 2 == 0) .player else .hostile, true);
        try data.setAiAffect(agent, .{});
        try data.setSteeringAgent(agent, growthSteeringTemplate(.{ 0, 0 }).create_entity.steering_agent.?);
        const npc = growthNpcTemplate(.{ 0, 0 }).create_entity;
        try data.setCollisionBounds(agent, npc.collision_bounds.?);
        try data.setCollisionResponse(agent, npc.collision_response.?);
    }
    // One agent per index cell past the crowd, so the index's link stage spans ranges too.
    const spread_count: usize = 32;
    for (0..spread_count) |index| _ = try addShareTestAgent(&data, 400 + @as(f32, @floatFromInt(index)) * 40, .player, false);
    const body_count = agent_count + spread_count;
    try markAllAlwaysActive(&data);

    var world = try shareTestWorld();
    defer world.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 2048, 450, .{
        .contact_capacity = body_count * 8,
        .pathfinding = .{ .max_group_fields = 1, .worker_participant_count = threads.participantSlotCount() },
    });
    defer pipeline.deinit();
    try frame.reserveStreams(pipeline.eventCapacitySum(), 0, body_count, body_count * 8, 4, 4);
    try frame.reservePathRequests(1, body_count);
    try pipeline.reserve(&frame, body_count);

    const context: SimulationPipelineUpdateContext = .{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 2048,
        .bounds_height = 450,
        .sim_view = fullWorldSimView(&world),
    };
    // One sample window under the default stage tuners, then a step pinned onto workers.
    for (0..(AdaptiveWorkTunerConfig{}).sample_window) |_| {
        frame.beginStep();
        _ = try pipeline.update(context);
    }
    pinPipelineThreadedProfiles(&pipeline, .{ .worker_threads = 2, .items_per_range = 16 });
    frame.beginStep();
    const stats = try pipeline.update(context);
    const stage_batches = [_]BatchStats{
        stats.spatial_index.sort_batch,
        stats.perception.batch,
        stats.ai.separation_batch,
        stats.ai.intent_batch,
        stats.movement.batch,
        stats.chunk_derive,
        stats.collision.broadphase_batch,
        stats.collision.narrowphase_batch,
    };
    for (stage_batches) |batch| try std.testing.expect(!batch.ran_inline);
    try std.testing.expect(threads.adaptive_tuner.last_request == null);
}

test "after population growth, ~2 solid contacts per body on the multi-worker path allocate nothing" {
    if (builtin.single_threaded) return error.SkipZigTest;
    try runContactBoundScenario(.solid);
}

test "after population growth, ~2 trigger contacts per body on the multi-worker path allocate nothing" {
    if (builtin.single_threaded) return error.SkipZigTest;
    try runContactBoundScenario(.trigger);
}

test "collision response runs on workers in the pipeline, allocation-free and matching the serial step" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const serial = try runCollisionRespondScenario(0);
    const threaded = try runCollisionRespondScenario(2);
    try std.testing.expectEqual(serial.intent_count, threaded.intent_count);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&serial.position_x), std.mem.sliceAsBytes(&threaded.position_x));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&serial.position_y), std.mem.sliceAsBytes(&threaded.position_y));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&serial.velocity_x), std.mem.sliceAsBytes(&threaded.velocity_x));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&serial.velocity_y), std.mem.sliceAsBytes(&threaded.velocity_y));
    try std.testing.expectEqual(serial.trigger_count, threaded.trigger_count);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(serial.triggers[0..serial.trigger_count]), std.mem.sliceAsBytes(threaded.triggers[0..threaded.trigger_count]));
}

test "population sync at an unchanged population allocates nothing" {
    var world = try minimalSyncWorld();
    defer world.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 64, 64, .{
        .movement_body_capacity = 4,
        .pathfinding = sync_test_pathfinding,
    });
    defer pipeline.deinit();
    try frame.reserveStreams(pipeline.eventCapacitySum(), 0, 4, 4, 4, 4);
    try pipeline.reserve(&frame, 4);

    // Rows added directly (test-only path), past the initial reserve.
    for (0..30) |index| {
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{ .position = .{ .x = @floatFromInt(index), .y = 0 } });
        try data.setAiAgent(entity, .{ .active_behavior = .wander });
    }

    const grown = try pipeline.syncPopulationCapacity(&frame, &data);
    try std.testing.expect(grown.grew);
    try std.testing.expectEqual(grownPopulationCapacity(30), pipeline.movement_body_capacity);
    try std.testing.expect(pipeline.spatial_index.keys.capacity >= pipeline.movement_body_capacity);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    var swap: TestAllocatorSwap = .{};
    swap.install(.{ .pipeline = &pipeline, .frame = &frame, .data = &data, .world = &world, .threads = &threads }, .uniform(failing.allocator()));
    const unchanged = pipeline.syncPopulationCapacity(&frame, &data);
    swap.restore(.{ .pipeline = &pipeline, .frame = &frame, .data = &data, .world = &world, .threads = &threads });
    try std.testing.expect(!(try unchanged).grew);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "a population growth that fails after the collision reserve restores the declared pair bound" {
    // The response allocator fails, so growth errors in `reserveContactStreams`, after
    // `collision.reserve(body)` succeeded. The tracked capacity and the collision's
    // declared pair bound both roll back to the old capacity's, so overflow telemetry
    // keeps matching the streams actually reserved; the retry then raises both.
    var world = try minimalSyncWorld();
    defer world.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 64, 64, .{
        .movement_body_capacity = 4,
        .pathfinding = sync_test_pathfinding,
    });
    defer pipeline.deinit();
    try frame.reserveStreams(pipeline.eventCapacitySum(), 0, 4, 4, 4, 4);
    try pipeline.reserve(&frame, 4);
    const old_pair_bound = pipeline.collision.reserved_pair_bound;
    try std.testing.expectEqual(CollisionSystem.estimateContactCapacity(4), old_pair_bound);

    for (0..30) |index| {
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{ .position = .{ .x = @floatFromInt(index), .y = 0 } });
        try data.setAiAgent(entity, .{ .active_behavior = .wander });
    }

    const response_allocator = pipeline.collision_response.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    pipeline.collision_response.allocator = failing.allocator();
    const failed = pipeline.syncPopulationCapacity(&frame, &data);
    pipeline.collision_response.allocator = response_allocator;
    try std.testing.expectError(error.OutOfMemory, failed);
    try std.testing.expectEqual(@as(usize, 4), pipeline.movement_body_capacity);
    try std.testing.expectEqual(old_pair_bound, pipeline.collision.reserved_pair_bound);

    const grown = try pipeline.syncPopulationCapacity(&frame, &data);
    try std.testing.expect(grown.grew);
    try std.testing.expectEqual(grownPopulationCapacity(30), pipeline.movement_body_capacity);
    try std.testing.expectEqual(CollisionSystem.estimateContactCapacity(pipeline.movement_body_capacity), pipeline.collision.reserved_pair_bound);
}

test "population sync that runs out of memory growing pathfinding keeps the old agent ceiling and the retry grows it" {
    var world = try minimalSyncWorld();
    defer world.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var pathfinding = sync_test_pathfinding;
    pathfinding.max_agent_budget = 8;
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 64, 64, .{ .pathfinding = pathfinding });
    defer pipeline.deinit();
    try frame.reserveStreams(pipeline.eventCapacitySum(), 0, 0, 0, 0, 0);
    try pipeline.reserve(&frame, 0);

    for (0..12) |index| {
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{ .position = .{ .x = @floatFromInt(index), .y = 0 } });
        try data.setSteeringAgent(entity, .{ .agent_radius = 4 });
    }

    // An OOM during the pathfinding grow keeps the old ceiling and pools; the retry lands.
    const real_allocator = pipeline.pathfinding.allocator;
    var failing = std.testing.FailingAllocator.init(real_allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    pipeline.pathfinding.allocator = failing.allocator();
    const failed = pipeline.syncPopulationCapacity(&frame, &data);
    pipeline.pathfinding.allocator = real_allocator;
    try std.testing.expectError(error.OutOfMemory, failed);
    try std.testing.expectEqual(@as(usize, 8), pipeline.pathfinding.agentBudget());
    try std.testing.expectEqual(@as(usize, 8), pipeline.pathfinding.effective_agent_capacity);
    try std.testing.expect(!pipeline.pathfinding.coversAgentCount(12));

    _ = try pipeline.syncPopulationCapacity(&frame, &data);
    try std.testing.expectEqual(grownPopulationCapacity(12), pipeline.pathfinding.agentBudget());
    try std.testing.expectEqual(@as(usize, 48), pipeline.pathfinding.agentBudget());
    // max(12, 2 x the floor 8).
    try std.testing.expectEqual(@as(usize, 16), pipeline.pathfinding.effective_agent_capacity);
    try std.testing.expect(pipeline.pathfinding.coversAgentCount(12));
}

test "a pipeline built over steering agents sizes pathfinding for them, so its first update allocates nothing on a multi-worker ThreadSystem (FailingAllocator)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 8 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    const agent_count = 40;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try addSteeringAgents(&data, agent_count);
    var pathfinding = sync_test_pathfinding;
    pathfinding.worker_participant_count = threads.participantSlotCount();
    // World-less nav over 16x16 open cells.
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 512, 512, .{ .pathfinding = pathfinding });
    defer pipeline.deinit();
    const system = &pipeline.pathfinding;
    try std.testing.expect(system.coversAgentCount(agent_count));
    try std.testing.expect(system.effective_agent_capacity >= agent_count);
    const capacity_at_init = system.effective_agent_capacity;
    const bytes_at_init = pathfinding_test_support.requestResidentBytes(system);

    // One distinct goal per agent, so intake keeps every request.
    var requests: [agent_count]PathRequest = undefined;
    for (&requests, data.steeringAgentSliceConst().entities, 0..) |*request, entity, index| {
        const goal_x: f32 = @floatFromInt(8 + index % 8);
        const goal_y: f32 = @floatFromInt(index / 8);
        request.* = .{ .entity = entity, .start = .{ .x = 48, .y = 48 }, .goal = .{ .x = goal_x * 32 + 16, .y = goal_y * 32 + 16 } };
    }
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    const range_base = try stream.appendRangeCounts(1);
    stream.addCount(range_base, requests.len);
    try stream.prefixAppendedRanges(range_base);
    var writer = stream.rangeWriter(range_base);
    for (requests) |request| writer.write(request);
    writer.finish();
    stream.finishWrite();

    // The first update, with no admission, so the step has no path content to publish: every
    // allocation fails (the system, its graph, its registry shards with their owner heads,
    // and the thread system), and the whole crowd's intake lands in the pools init sized.
    // Driven on the system rather than the pipeline's step, whose path requests come only
    // from AI navigation intents through steering; the whole first step after a seam growth
    // has its own every-owner proof.
    const real_allocator = system.allocator;
    const threads_allocator = threads.allocator;
    const failing = std.testing.failing_allocator;
    system.allocator = failing;
    system.graph.allocator = failing;
    for (&system.path_index) |*shard| shard.allocator = failing;
    threads.allocator = failing;
    const first = system.update(&stream, agent_count, &threads, .{ .adaptive = false, .items_per_range = 8, .max_solve_admissions_per_step = 0 });
    system.allocator = real_allocator;
    system.graph.allocator = real_allocator;
    for (&system.path_index) |*shard| shard.allocator = real_allocator;
    threads.allocator = threads_allocator;
    const intake_stats = try first;
    try std.testing.expect(!intake_stats.intake_batch.ran_inline);
    try std.testing.expect(intake_stats.intake_batch.range_count > 1);
    try std.testing.expectEqual(@as(usize, agent_count), intake_stats.accepted_requests);
    try std.testing.expectEqual(@as(usize, agent_count), intake_stats.pending_requests);
    try std.testing.expectEqual(@as(usize, 0), intake_stats.dropped_requests);
    try std.testing.expectEqual(@as(u64, 0), intake_stats.resize_ns);
    try std.testing.expectEqual(capacity_at_init, system.effective_agent_capacity);

    // The first solving update: only path content grows (registry runs and long blocks);
    // every elastic pool keeps its init size.
    stream.clearRetainingCapacity();
    const solve_stats = try system.update(&stream, agent_count, &threads, .{ .adaptive = false, .items_per_range = 8 });
    try std.testing.expectEqual(@as(usize, agent_count), solve_stats.available_results);
    try std.testing.expectEqual(capacity_at_init, system.effective_agent_capacity);
    const bytes_after = pathfinding_test_support.requestResidentBytes(system);
    try std.testing.expectEqual(bytes_at_init.queues, bytes_after.queues);
    try std.testing.expectEqual(bytes_at_init.search, bytes_after.search);
    try std.testing.expectEqual(bytes_at_init.tier1, bytes_after.tier1);
    try std.testing.expectEqual(bytes_at_init.change_scratch, bytes_after.change_scratch);
}

test "a pipeline init that runs out of memory at any allocation frees everything; one that completes covers its steering agents" {
    const agent_count = 12;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try addSteeringAgents(&data, agent_count);
    // Below the crowd, so init raises the ceiling as well as growing the pools.
    var pathfinding = sync_test_pathfinding;
    pathfinding.max_agent_budget = 8;
    const config: SimulationPipelineConfig = .{ .pathfinding = pathfinding };
    // Hand-rolled: `std.testing.checkAllAllocationFailures` never fails a resize; this sweep does.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = fail_index });
        if (SimulationPipeline.init(failing.allocator(), &data, 256, 256, config)) |built| {
            var pipeline = built;
            defer pipeline.deinit();
            try std.testing.expect(pipeline.pathfinding.coversAgentCount(agent_count));
            try std.testing.expectEqual(grownPopulationCapacity(agent_count), pipeline.pathfinding.agentBudget());
            if (!failing.has_induced_failure) break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}

test "a collider sync that runs out of memory keeps its change and the next step's seam reserves the nav event for it" {
    var world = try minimalSyncWorld();
    defer world.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 64, 64, .{
        .movement_body_capacity = 4,
        .structural_headroom = 128,
        .pathfinding = sync_test_pathfinding,
        .navigation_world = &world,
    });
    defer pipeline.deinit();
    try frame.reserveStreams(pipeline.eventCapacitySum(), 0, 4, 4, 4, 4 + 128);
    try pipeline.reserve(&frame, 4);

    // A static created over the one cell; its collider sync runs out of memory.
    frame.beginStep();
    try writeStructuralCommands(&frame, &.{responderTemplate(0, .static)});
    try pipeline.reserveStaticColliders(&frame, &data);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    pipeline.static_colliders.allocator = failing.allocator();
    pipeline.static_colliders.chunk_lists.allocator = failing.allocator();
    pipeline.static_colliders.query_lists.allocator = failing.allocator();
    const failed = commitAndSyncLikeDemo(&pipeline, &frame, &data, &world);
    pipeline.static_colliders.allocator = std.testing.allocator;
    pipeline.static_colliders.chunk_lists.allocator = std.testing.allocator;
    pipeline.static_colliders.query_lists.allocator = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, failed);
    try std.testing.expect(!pipeline.pathfinding.graph.grid(0).?.isBlockedCell(.{ .x = 0, .y = 0 }));

    // A step with no command: the kept change still makes the nav reaction emit, so the
    // seam reserves its event, and the retried sync blocks the cell.
    frame.beginStep();
    try std.testing.expect(pipeline.navReactionMayEmit(&data, &frame, &world));
    _ = try commitAndSyncLikeDemo(&pipeline, &frame, &data, &world);
    try std.testing.expectEqual(@as(usize, 1), frame.events.stats.nav_region_invalidated);
    try std.testing.expect(pipeline.pathfinding.graph.grid(0).?.isBlockedCell(.{ .x = 0, .y = 0 }));
    try std.testing.expect(!pipeline.navReactionMayEmit(&data, &frame, &world));
}

test "a nav-mark reserve OOM before a dig leaves world and nav intact and the retry applies it" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var fixture: NavSeamFixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    fixture.underground();
    const floor1 = fixture.world.denseFloorLayerForLevel(1).?;
    const tile_before = fixture.world.denseTile(floor1, 6, 3);
    try std.testing.expect(fixture.navBlocked(1, 6, 3));

    fixture.fillNavMarks();
    const nav_allocator = fixture.pipeline.pathfinding.allocator;
    var failing = std.testing.FailingAllocator.init(nav_allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    fixture.pipeline.pathfinding.allocator = failing.allocator();
    const failed = fixture.update(.hole);
    fixture.pipeline.pathfinding.allocator = nav_allocator;
    try std.testing.expectError(error.OutOfMemory, failed);
    // Nothing was written or promoted, and nav is as it was.
    try std.testing.expectEqual(tile_before, fixture.world.denseTile(floor1, 6, 3));
    try std.testing.expectEqual(@as(usize, 0), fixture.frame.events.mergedItems().len);
    try std.testing.expect(fixture.navBlocked(1, 6, 3));

    // The re-issued dig writes, records, and the seam applies it.
    try fixture.update(.hole);
    try std.testing.expect(fixture.world.denseTile(floor1, 6, 3) != tile_before);
    try fixture.seam();
    try std.testing.expect(!fixture.navBlocked(1, 6, 3));
    try fixture.expectNavMatchesRebuild();
}

test "a nav-mark reserve OOM before plane traversal leaves world and nav intact and the retry applies it" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var fixture: NavSeamFixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    // A hole at (6,3); the player then stands over it.
    try fixture.update(.hole);
    try fixture.seam();
    const floor1 = fixture.world.denseFloorLayerForLevel(1).?;
    try std.testing.expect(denseTileBlocksMovement(&fixture.world, floor1, 6, 3));
    try std.testing.expect(fixture.navBlocked(1, 6, 3));

    // Control: a quiet step allocates nothing from nav, so the next failure is the
    // traversal's record reserve.
    const nav_allocator = fixture.pipeline.pathfinding.allocator;
    var quiet = std.testing.FailingAllocator.init(nav_allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    fixture.pipeline.pathfinding.allocator = quiet.allocator();
    try fixture.update(.none);
    fixture.pipeline.pathfinding.allocator = nav_allocator;
    try fixture.seam();

    placePlayerFlush(&fixture.data, fixture.player, .{ 6, 3 });
    fixture.fillNavMarks();
    var failing = std.testing.FailingAllocator.init(nav_allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    fixture.pipeline.pathfinding.allocator = failing.allocator();
    const failed = fixture.update(.none);
    fixture.pipeline.pathfinding.allocator = nav_allocator;
    try std.testing.expectError(error.OutOfMemory, failed);
    // No fall and no landing carve, and nav is as it was.
    try std.testing.expectEqual(@as(u16, 0), fixture.player.current_level);
    try std.testing.expect(denseTileBlocksMovement(&fixture.world, floor1, 6, 3));
    try std.testing.expect(fixture.navBlocked(1, 6, 3));

    // The retried step falls and carves the landing; the seam applies it.
    try fixture.update(.none);
    try std.testing.expectEqual(@as(u16, 1), fixture.player.current_level);
    try std.testing.expect(!denseTileBlocksMovement(&fixture.world, floor1, 6, 3));
    try fixture.seam();
    try std.testing.expect(!fixture.navBlocked(1, 6, 3));
    try fixture.expectNavMatchesRebuild();
}

test "a plane traversal past a failed population seam reserves its nav record from its carves and the seam then matches a rebuild" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var fixture: NavSeamFixture = undefined;
    try fixture.init(.{
        .tiles_per_side = 16,
        .worker_threads = 2,
        .structural_headroom = 128,
        .pathfinding = .{ .max_group_fields = 1, .worker_participant_count = 1 },
    });
    defer fixture.deinit();
    const pathfinding = &fixture.pipeline.pathfinding;
    pathfinding.nav_controls = .{ .adaptive = false, .items_per_range = 1 };
    fixture.pipeline.plane_entry.config = .{ .items_per_range = plane_entry_range_alignment_items, .adaptive = false };
    const spare_marks = pathfinding.nav_marks.capacity - pathfinding.nav_marks.items.len;
    // Past the spare marks and staging, and across at least two `nav_mark` ranges.
    const npc_count = @max(8 * lane_count, spare_marks, pathfinding.nav_mark_staging.capacity) + 1;

    // Each NPC enters its own surface hole from the west this step; level 1 below is solid.
    const floor0 = fixture.world.denseFloorLayerForLevel(0).?;
    const floor1 = fixture.world.denseFloorLayerForLevel(1).?;
    var landings: std.ArrayList(CellCoord) = .empty;
    defer landings.deinit(std.testing.allocator);
    var y: u16 = 0;
    fill: while (y < 16) : (y += 1) {
        var x: u16 = 1;
        while (x < 16) : (x += 1) {
            if (landings.items.len == npc_count) break :fill;
            if (x == 5 and y == 3) continue; // the player's cell
            try std.testing.expect(denseTileBlocksMovement(&fixture.world, floor1, x, y));
            _ = try fixture.world.clearDenseTile(floor0, x, y);
            try landings.append(std.testing.allocator, .{ .x = x, .y = y });
            const npc = try fixture.data.createEntity();
            try fixture.data.setMovementBody(npc, .{});
            try fixture.data.setPrimitiveVisual(npc, growth_npc_visual);
            try fixture.data.setAiAgent(npc, .{ .active_behavior = .wander, .gain_pursue = 0 });
            try fixture.data.setWorldLevel(npc, 0);
            try fixture.data.setSimulationTier(npc, .locomotion);
            const body = fixture.data.movementBodyPtr(npc).?;
            body.previous_x.* = @as(f32, @floatFromInt(x - 1)) * 32;
            body.previous_y.* = @as(f32, @floatFromInt(y)) * 32;
            body.position_x.* = @as(f32, @floatFromInt(x)) * 32;
            body.position_y.* = @as(f32, @floatFromInt(y)) * 32;
        }
    }
    try std.testing.expectEqual(npc_count, landings.items.len);
    fixture.pipeline.dig.player_last_cell = .{ .x = 5, .y = 3 };

    // The population seam runs out of memory at its first reserve, so every population-sized
    // reserve, the nav record's included, stays at the old capacity.
    const old_capacity = fixture.pipeline.movement_body_capacity;
    const scope_allocator = fixture.pipeline.scope.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    fixture.pipeline.scope.allocator = failing.allocator();
    const failed = fixture.pipeline.syncPopulationCapacity(&fixture.frame, &fixture.data);
    fixture.pipeline.scope.allocator = scope_allocator;
    try std.testing.expectError(error.OutOfMemory, failed);
    try std.testing.expectEqual(old_capacity, fixture.pipeline.movement_body_capacity);
    try std.testing.expect(npc_count > maxEventsPerStep(.plane_traversal, fixture.pipeline.eventBudgets()));
    try std.testing.expect(npc_count > pathfinding.nav_marks.capacity - pathfinding.nav_marks.items.len);
    try std.testing.expect(npc_count > pathfinding.nav_mark_staging.capacity);

    fixture.frame.beginStep();
    var step = SimulationPipeline.StepState.init(&fixture.pipeline, .{
        .data = &fixture.data,
        .frame = &fixture.frame,
        .world = &fixture.world,
        .player = &fixture.player,
        .thread_system = &fixture.threads,
        .delta_seconds = 0.016,
        .bounds_width = 256,
        .bounds_height = 256,
        .sim_view = fullWorldSimView(&fixture.world),
    });
    try fixture.pipeline.stagePlaneTraversal(&step);
    // The gather's windows were short of the AI rows too: grown once on main, then dispatched.
    try std.testing.expectEqual(@as(u64, 1), fixture.pipeline.plane_entry.windows_grown);
    try std.testing.expectEqual(@as(usize, 1), step.plane_entry_windows_grown);
    try std.testing.expectEqual(npc_count, fixture.frame.events.stats.world_tile_changed);
    try std.testing.expectEqual(@as(usize, 1), fixture.frame.events.range_stats.items.len);
    for (landings.items) |cell| try std.testing.expect(!denseTileBlocksMovement(&fixture.world, floor1, cell.x, cell.y));

    // The retried seam grows, and nav applies every recorded carve.
    try fixture.seam();
    try std.testing.expect(fixture.pipeline.movement_body_capacity > old_capacity);
    for (landings.items) |cell| try std.testing.expect(!fixture.navBlocked(1, cell.x, cell.y));
    try fixture.expectNavMatchesRebuild();
}

test "a dig whose step fails before the commit seam reaches nav at the next seam" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var fixture: NavSeamFixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    fixture.underground();
    // The dig's stages run, then the step stops before its seam (a later stage failed).
    try fixture.update(.hole);
    try std.testing.expect(!fixture.world.levelBlocksMovement(1, 6, 3));
    try std.testing.expect(fixture.navBlocked(1, 6, 3));

    // The next step's events no longer hold the dig; its seam still applies it.
    try fixture.update(.none);
    try fixture.seam();
    try std.testing.expect(!fixture.navBlocked(1, 6, 3));
    try fixture.expectNavMatchesRebuild();
}

test "a collider-sync OOM in a dig step still applies the dig the next step" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var fixture: NavSeamFixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    fixture.underground();
    try fixture.update(.hole);
    try writeStructuralCommands(&fixture.frame, &.{responderTemplate(1, .static)});
    // The seam's collider reserve holds; the sync after the commit runs out of memory.
    try fixture.pipeline.reserveStaticColliders(&fixture.frame, &fixture.data);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    fixture.pipeline.static_colliders.allocator = failing.allocator();
    fixture.pipeline.static_colliders.chunk_lists.allocator = failing.allocator();
    fixture.pipeline.static_colliders.query_lists.allocator = failing.allocator();
    const failed = fixture.seam();
    fixture.pipeline.static_colliders.allocator = std.testing.allocator;
    fixture.pipeline.static_colliders.chunk_lists.allocator = std.testing.allocator;
    fixture.pipeline.static_colliders.query_lists.allocator = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, failed);
    try std.testing.expectEqual(@as(usize, 0), static_colliders_test_support.liveRowCount(fixture.pipeline.static_colliders));
    try std.testing.expect(fixture.navBlocked(1, 6, 3));

    // A step with no dig and no command: the retried sync and the kept dig marks apply.
    try fixture.update(.none);
    try fixture.seam();
    try std.testing.expect(fixture.navBlocked(0, 2, 0));
    try std.testing.expect(!fixture.navBlocked(1, 6, 3));
    try fixture.expectNavMatchesRebuild();
}

test "a static nav-mark reserve OOM commits nothing and the retried commit reaches nav" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var fixture: NavSeamFixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    try fixture.update(.none);
    try writeStructuralCommands(&fixture.frame, &.{responderTemplate(1, .static)});
    const entities_before = fixture.data.movementBodySliceConst().entities.len;
    fixture.fillNavMarks();
    const nav_allocator = fixture.pipeline.pathfinding.allocator;
    var failing = std.testing.FailingAllocator.init(nav_allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    fixture.pipeline.pathfinding.allocator = failing.allocator();
    const failed = fixture.pipeline.reserveStaticColliders(&fixture.frame, &fixture.data);
    fixture.pipeline.pathfinding.allocator = nav_allocator;
    try std.testing.expectError(error.OutOfMemory, failed);
    // Nothing committed: no entity, no row, and nav unchanged.
    try std.testing.expectEqual(entities_before, fixture.data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 0), static_colliders_test_support.liveRowCount(fixture.pipeline.static_colliders));
    try std.testing.expect(!fixture.navBlocked(0, 2, 0));

    // The retried seam commits the same commands; nav takes the static.
    try fixture.seam();
    try std.testing.expectEqual(@as(usize, 1), static_colliders_test_support.liveRowCount(fixture.pipeline.static_colliders));
    try std.testing.expect(fixture.navBlocked(0, 2, 0));
    try fixture.expectNavMatchesRebuild();
}

test "a nav apply OOM keeps the step's dig and static marks and the next step applies both" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var fixture: NavSeamFixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    fixture.underground();
    try fixture.update(.hole);
    try writeStructuralCommands(&fixture.frame, &.{responderTemplate(1, .static)});
    const graph_allocator = fixture.pipeline.pathfinding.graph.allocator;
    var failing = std.testing.FailingAllocator.init(graph_allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    fixture.pipeline.pathfinding.graph.allocator = failing.allocator();
    const failed = fixture.seam();
    fixture.pipeline.pathfinding.graph.allocator = graph_allocator;
    try std.testing.expectError(error.OutOfMemory, failed);
    try std.testing.expect(!fixture.navBlocked(0, 2, 0));
    try std.testing.expect(fixture.navBlocked(1, 6, 3));
    try std.testing.expect(fixture.pipeline.pathfinding.hasPendingNavUpdates(&fixture.world));

    try fixture.update(.none);
    try fixture.seam();
    try std.testing.expect(fixture.navBlocked(0, 2, 0));
    try std.testing.expect(!fixture.navBlocked(1, 6, 3));
    try fixture.expectNavMatchesRebuild();
}

test "statics committed at the seam leave the next step allocation-free" {
    var world = try minimalSyncWorld();
    defer world.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 4096, 64, .{
        .movement_body_capacity = 4,
        .structural_headroom = 128,
        .pathfinding = sync_test_pathfinding,
    });
    defer pipeline.deinit();
    try frame.reserveStreams(pipeline.eventCapacitySum(), 0, 4, 4, 4, 4 + 128);
    try frame.reservePathRequests(1, 4);
    try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try pipeline.reserve(&frame, 4);
    const context: SimulationPipelineUpdateContext = .{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 4096,
        .bounds_height = 64,
        .sim_view = fullWorldSimView(&world),
    };

    // First growth: 12 dynamic responders and 1 static.
    var commands: [20]StructuralCommand = undefined;
    for (commands[0..12], 0..) |*command, index| command.* = responderTemplate(index, .dynamic);
    commands[12] = responderTemplate(12, .static);
    frame.beginStep();
    try writeStructuralCommands(&frame, commands[0..13]);
    try std.testing.expect((try commitAndSyncLikeDemo(&pipeline, &frame, &data, &world)).grew);
    frame.beginStep();
    _ = try pipeline.update(context);

    // 20 more statics within the population capacity: the seam syncs them into the rows.
    for (&commands, 0..) |*command, index| command.* = responderTemplate(13 + index, .static);
    frame.beginStep();
    try writeStructuralCommands(&frame, &commands);
    try std.testing.expect(!(try commitAndSyncLikeDemo(&pipeline, &frame, &data, &world)).grew);
    try std.testing.expectEqual(@as(usize, 21), static_colliders_test_support.liveRowCount(pipeline.static_colliders));

    // The next step reads the synced rows and allocates nothing on any owner.
    frame.beginStep();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    var swap: TestAllocatorSwap = .{};
    swap.install(.{ .pipeline = &pipeline, .frame = &frame, .data = &data, .world = &world, .threads = &threads }, .uniform(failing.allocator()));
    const result = pipeline.update(context);
    swap.restore(.{ .pipeline = &pipeline, .frame = &frame, .data = &data, .world = &world, .threads = &threads });
    _ = try result;
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

// Writes one navigation intent for `agent` heading +x, runs the steering stage alone, and
// returns the agent's lateral (y) direction from the stage's last intent for it.
fn steeringStageLateralForTest(pipeline: *SimulationPipeline, context: SimulationPipelineUpdateContext, agent: EntityId) !f32 {
    const frame = context.frame;
    try frame.navigation_intents.prepareRangeCounts(1);
    frame.navigation_intents.addCount(0, 1);
    try frame.navigation_intents.prefix();
    var writer = frame.navigation_intents.rangeWriter(0);
    writer.write(.{ .entity = agent, .goal = .{ .x = 600, .y = 96 }, .direct_direction_x = 1 });
    writer.finish();
    frame.navigation_intents.finishWrite();
    var step = SimulationPipeline.StepState.init(pipeline, context);
    try pipeline.runStage(.steering_update, &step);
    var lateral: ?f32 = null;
    for (frame.intents.mergedItems()) |intent| {
        if (intent.movement.entity.eql(agent)) lateral = intent.movement.direction_y;
    }
    return lateral orelse error.TestExpectedEqual;
}

test "a static committed at the seam pushes steering agents on the next step" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    // The commit seam's collider sync writes the static rows the steering stage reads,
    // outside the stage graph. Steering run between the commit and the sync still sees
    // the box parked; after the sync it pushes away from the box.
    var world = try minimalSyncWorld();
    defer world.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    const agent_position = math.Vec2{ .x = 96, .y = 96 };
    const agent = try data.createEntity();
    try data.setMovementBody(agent, .{ .position = agent_position, .previous_position = agent_position, .velocity = .{}, .speed = 32 });
    try data.setSteeringAgent(agent, .{
        .agent_radius = 8,
        .waypoint_tolerance = 4,
        .avoidance_radius = 48,
        .avoidance_weight = 1.5,
        .max_neighbor_samples = 8,
        .stuck_step_threshold = 3,
        .replan_cooldown_steps = 4,
        .unavailable_backoff_steps = 12,
    });
    const parked = math.Vec2{ .x = 96, .y = 600 };
    const box = try data.createEntity();
    try data.setMovementBody(box, .{ .position = parked, .previous_position = parked, .velocity = .{}, .speed = 0 });
    try data.setCollisionBounds(box, .{ .size = .{ .x = 20, .y = 20 } });
    try data.setCollisionResponse(box, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 640, 640, .{
        .movement_body_capacity = 4,
        .structural_headroom = 16,
        .pathfinding = sync_test_pathfinding,
    });
    defer pipeline.deinit();
    try frame.reserveStreams(pipeline.eventCapacitySum(), 4, 4, 4, 4, 4 + 16);
    try frame.reservePathRequests(1, 4);
    try pipeline.reserve(&frame, 4);
    try std.testing.expectEqual(@as(usize, 1), static_colliders_test_support.liveRowCount(pipeline.static_colliders));
    const context: SimulationPipelineUpdateContext = .{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 640,
        .bounds_height = 640,
        .sim_view = fullWorldSimView(&world),
    };

    // The commit moves the box just above the agent; the sync has not run yet.
    frame.beginStep();
    const beside = math.Vec2{ .x = agent_position.x + 8, .y = agent_position.y - 32 };
    try writeStructuralCommands(&frame, &.{.{ .set_movement_body = .{ .entity = box, .body = .{ .position = beside, .previous_position = beside, .velocity = .{}, .speed = 0 } } }});
    try pipeline.reserveStaticColliders(&frame, &data);
    _ = try frame.applyStructuralCommands(&data);
    pipeline.captureStaticColliderChanges(&frame);
    try std.testing.expectApproxEqAbs(@as(f32, 0), try steeringStageLateralForTest(&pipeline, context, agent), 0.001);

    // After the seam's sync, the stage pushes the agent away from the box (+y).
    try pipeline.syncStaticColliders(&data, &serial_threads);
    pipeline.reactToPostCommitSteeringEvents(&frame);
    try std.testing.expect(try steeringStageLateralForTest(&pipeline, context, agent) > 0.05);
}

test "a static move splices its collider's chunk lists, and a seam with no static change splices none" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var world = try minimalSyncWorld();
    defer world.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const parked = math.Vec2{ .x = 96, .y = 600 };
    const box = try data.createEntity();
    try data.setMovementBody(box, .{ .position = parked, .previous_position = parked, .velocity = .{}, .speed = 0 });
    try data.setCollisionBounds(box, .{ .size = .{ .x = 20, .y = 20 } });
    try data.setCollisionResponse(box, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 640, 640, .{
        .movement_body_capacity = 4,
        .structural_headroom = 16,
        .pathfinding = sync_test_pathfinding,
    });
    defer pipeline.deinit();
    try frame.reserveStreams(pipeline.eventCapacitySum(), 4, 4, 4, 4, 4 + 16);

    // The box moves onto a chunk corner.
    frame.beginStep();
    const moved = math.Vec2{ .x = 500, .y = 500 };
    try writeStructuralCommands(&frame, &.{.{ .set_movement_body = .{ .entity = box, .body = .{ .position = moved, .previous_position = moved, .velocity = .{}, .speed = 0 } } }});
    try pipeline.reserveStaticColliders(&frame, &data);
    _ = try frame.applyStructuralCommands(&data);
    pipeline.captureStaticColliderChanges(&frame);
    try pipeline.syncStaticColliders(&data, &serial_threads);
    try std.testing.expect(pipeline.static_colliders.last_splice_batch.item_count > 0);

    // A seam with no static change resets the batch.
    frame.beginStep();
    try pipeline.reserveStaticColliders(&frame, &data);
    _ = try frame.applyStructuralCommands(&data);
    pipeline.captureStaticColliderChanges(&frame);
    try pipeline.syncStaticColliders(&data, &serial_threads);
    try std.testing.expectEqual(@as(usize, 0), pipeline.static_colliders.last_splice_batch.item_count);
}

test "a structural burst over its own event share fails the same whether other producers are idle or saturated" {
    // 20 creates x 4 events = 80 > 79: rejected at the structural boundary in both cases,
    // never admitted by borrowing idle perception/affect/action shares.
    const over_idle = try commitStructuralBurst(20, false);
    const over_saturated = try commitStructuralBurst(20, true);
    try std.testing.expect(over_idle.failed);
    try std.testing.expectEqual(over_idle, over_saturated);

    // 19 creates x 4 events = 76 <= 79 commits in both cases.
    const within_idle = try commitStructuralBurst(19, false);
    const within_saturated = try commitStructuralBurst(19, true);
    try std.testing.expect(!within_idle.failed);
    try std.testing.expectEqual(@as(usize, 21), within_idle.bodies);
    try std.testing.expectEqual(within_idle, within_saturated);
}

test "a destructible destroy commits through structuralCommitBudget with zero caller structural headroom" {
    var world = try minimalSyncWorld();
    defer world.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const crate = try data.createEntity();
    try data.setMovementBody(crate, .{ .position = .{ .x = 0, .y = 0 } });
    try data.setDestructible(crate, .{ .hit_points = 1 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 64, 64, .{
        .movement_body_capacity = 4,
        .structural_headroom = 0,
        .pathfinding = sync_test_pathfinding,
    });
    defer pipeline.deinit();
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try frame.reserveStreams(pipeline.eventCapacitySum(), 0, 4, 4, 4, 4 + pipeline.structuralCommandHeadroom());
    try pipeline.reserve(&frame, 4);
    // The caller budgets nothing; the share is the pipeline's own destructible part.
    try std.testing.expectEqual(pipeline_structural_event_share, maxEventsPerStep(.structural_commit, pipeline.eventBudgets()));

    frame.beginStep();
    try frame.appendActionIntent(.{ .entity = EntityId.invalid, .kind = .interact, .target = crate });
    // The pipeline's own `action_react` producer (what `stageActionReact` runs).
    const stats = try pipeline.destructible.process(&frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.destroyed);
    try std.testing.expect(data.isAlive(crate));

    _ = try frame.applyStructuralCommandsBudgeted(&data, pipeline.structuralCommitBudget(0));
    try std.testing.expect(!data.isAlive(crate));
}

test "a full-template create costs max_structural_events_per_create events" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const position = math.Vec2{ .x = 0, .y = 0 };
    try writeStructuralCommands(&frame, &.{.{ .create_entity = .{
        .movement_body = .{ .position = position, .previous_position = position, .velocity = .{}, .speed = 0 },
        .facing = .{ .direction = .down },
        .primitive_visual = growth_npc_visual,
        .asset_reference = .{ .sprite = .demo_tile },
        .collision_bounds = .{ .size = .{ .x = 16, .y = 16 } },
        .collision_response = .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 },
        .ai_agent = .{ .active_behavior = .wander },
        .steering_agent = .{ .agent_radius = 4 },
        .world_level = 0,
        .faction = .hostile,
        .ai_perception = .{},
        .ai_memory = .{},
        .ai_affect = .{},
        .destructible = .{},
    } }});
    // Exactly the per-create share: one more event would not fit.
    const share = structuralEventHeadroom(1, 0);
    try std.testing.expectError(error.EventCapacityExceeded, frame.applyStructuralCommandsBudgeted(&data, .{ .structural_event_share = share - 1 }));
    _ = try frame.applyStructuralCommandsBudgeted(&data, .{ .structural_event_share = share });
    try std.testing.expectEqual(share, frame.events.mergedItems().len);
}

test "the think-set stage reads the built index and writes the think set every cognition stage reads" {
    const order = stageContract(.ai_cognition_order);
    try std.testing.expect(order.reads.contains(.spatial_index));
    try std.testing.expect(order.writes.contains(.ai_cognition_indices));
    try std.testing.expect(!stageContract(.scope_advance_and_ai_gather).writes.contains(.ai_cognition_indices));
    const order_at = std.mem.indexOfScalar(StageId, &stage_order, .ai_cognition_order).?;
    try std.testing.expect(std.mem.indexOfScalar(StageId, &stage_order, .spatial_index_build).? < order_at);
    for ([_]StageId{ .perception_update, .ai_memory_update, .affect_update, .ai_decide }) |reader| {
        try std.testing.expect(stageContract(reader).reads.contains(.ai_cognition_indices));
        try std.testing.expect(order_at < std.mem.indexOfScalar(StageId, &stage_order, reader).?);
    }
}

test "the think set reaches AI in the index's cell-major order, not AI index order" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    // AI agent 0 nine cell rows below agents 1 and 2, which share a cell.
    const positions = [_]math.Vec2{ .{ .x = 40, .y = 300 }, .{ .x = 40, .y = 10 }, .{ .x = 45, .y = 12 } };
    var agents: [positions.len]EntityId = undefined;
    for (&agents, positions) |*agent, position| {
        agent.* = try data.createEntity();
        try data.setMovementBody(agent.*, .{ .position = position, .previous_position = position, .velocity = .{}, .speed = 0 });
        try data.setAiAgent(agent.*, .{ .active_behavior = .wander, .gain_pursue = 0 });
    }

    // A struct-literal world: no cognition region, so every agent thinks.
    var world = WorldSystem{ .allocator = std.testing.allocator, .width = 64, .height = 64, .tile_size = 32, .chunk_size_tiles = 16 };
    defer world.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 4, 4, 4, 4, 4);
    try frame.reservePathRequests(4, 4);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 2048, 2048, .{
        .contact_capacity = 4,
        .pathfinding = .{ .max_group_fields = 1, .worker_participant_count = 1 },
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
        .bounds_width = 2048,
        .bounds_height = 2048,
        .sim_view = fullWorldSimView(&world),
    });
    try std.testing.expectEqual(@as(usize, 3), stats.ai.entity_count);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 0 }, pipeline.scope.ai_cognition_indices.items);
    const intents = frame.navigation_intents.mergedItems();
    try std.testing.expectEqual(@as(usize, 3), intents.len);
    for (intents, [_]usize{ 1, 2, 0 }) |intent, agent| try std.testing.expect(intent.entity.eql(agents[agent]));
}

test "the goal resolve stage writes path_goals, read by steering's status queries and the pathfinding update after it" {
    const resolve = stageContract(.path_goal_resolve);
    try std.testing.expect(resolve.reads.contains(.navigation_intents));
    try std.testing.expect(resolve.writes.contains(.path_goals));
    try std.testing.expect(stageContract(.steering_update).reads.contains(.path_goals));
    try std.testing.expect(stageContract(.pathfinding_update).reads.contains(.path_goals));
    const resolve_at = std.mem.indexOfScalar(StageId, &stage_order, .path_goal_resolve).?;
    try std.testing.expect(std.mem.indexOfScalar(StageId, &stage_order, .ai_decide).? < resolve_at);
    try std.testing.expect(resolve_at < std.mem.indexOfScalar(StageId, &stage_order, .steering_update).?);
}

test "a crowd pursuing a blocked goal whose projection is sealed reads it unavailable on the first step, with one shared projection and no request" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // The crowd's goal: the focus target, the player at (400, 225), nav cell (12, 7). A 3x3
    // block covers cells (11..13, 6..8); a wall ring at cells x 9..15, y 4..10 seals the
    // ring of open cells between them, which holds the goal's projection.
    var player = try Player.spawn(&data);
    try addStaticBox(&data, .{ .x = 352, .y = 192 }, .{ .x = 96, .y = 96 });
    try addStaticBox(&data, .{ .x = 288, .y = 128 }, .{ .x = 224, .y = 32 });
    try addStaticBox(&data, .{ .x = 288, .y = 320 }, .{ .x = 224, .y = 32 });
    try addStaticBox(&data, .{ .x = 288, .y = 160 }, .{ .x = 32, .y = 160 });
    try addStaticBox(&data, .{ .x = 480, .y = 160 }, .{ .x = 32, .y = 160 });
    const crowd = 6;
    for (0..crowd) |index| {
        const agent = try data.createEntity();
        const position = math.Vec2{ .x = 48 + 96 * @as(f32, @floatFromInt(index)), .y = 400 };
        try data.setMovementBody(agent, .{ .position = position, .previous_position = position, .velocity = .{}, .speed = 32 });
        try data.setAiAgent(agent, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 });
        try data.setSteeringAgent(agent, .{
            .agent_radius = 8,
            .waypoint_tolerance = 4,
            .avoidance_radius = 48,
            .avoidance_weight = 1.5,
            .max_neighbor_samples = 8,
            .stuck_step_threshold = 3,
            .replan_cooldown_steps = 4,
            .unavailable_backoff_steps = 12,
        });
    }
    try markAllAlwaysActive(&data);
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 25,
        .height = 15,
        .tile_size = 32,
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    _ = try world.addLevel(0);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .movement_body_capacity = 16,
        .structural_headroom = 16,
        .pathfinding = .{ .max_group_fields = 1, .worker_participant_count = threads.participantSlotCount() },
    });
    defer pipeline.deinit();
    try frame.reserveStreams(pipeline.eventCapacitySum(), 16, 16, 16, 16, 16 + 16);
    try frame.reservePathRequests(1, 16);
    try pipeline.reserve(&frame, 16);

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
        .sim_view = fullWorldSimView(&world),
    });
    try std.testing.expectEqual(@as(usize, crowd), frame.navigation_intents.mergedItems().len);
    try std.testing.expectEqual(@as(usize, crowd), stats.path_goals.blocked);
    try std.testing.expectEqual(@as(usize, 1), stats.path_goals.distinct);
    try std.testing.expectEqual(@as(usize, crowd), stats.steering.path_unavailable_count);
    try std.testing.expectEqual(@as(usize, 0), stats.steering.path_request_count);
    try std.testing.expectEqual(@as(usize, 0), stats.pathfinding.goal_fallbacks + stats.pathfinding.accepted_requests);
}
