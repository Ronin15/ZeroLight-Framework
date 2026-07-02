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
const c = @import("../platform/sdl.zig").c;
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const DataSystem = @import("data_system.zig").DataSystem;
const EntityId = @import("data_system.zig").EntityId;
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
    ai: AiStats = .{},
    steering: SteeringStats = .{},
    pathfinding: PathfindingStats = .{},
    movement: MovementStats = .{},
    collision: CollisionStats = .{},
    collision_response: CollisionResponseStats = .{},
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
    /// Backbone scope system: recomputes chunks, gates AI/movement/collision by
    /// tier + camera cognition halo + stagger, and drives auto tier wake/sleep.
    scope: SimulationScopeSystem,
    /// Shared per-step spatial index (Slice 28), built once from the same
    /// cognition-scoped population the scope system selects for AI. AI
    /// separation queries it read-only; future perception stages reuse it too.
    spatial_index: SpatialIndexSystem,
    dig: DigController,
    audio_controller: AudioController,
    nav_cell_size: f32,

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

        return .{
            .movement = MovementSystem.init(),
            .collision = collision,
            .collision_response = collision_response,
            .ai = ai,
            .steering = steering,
            .pathfinding = pathfinding,
            .scope = scope,
            .spatial_index = spatial_index,
            .dig = DigController.init(config.dig),
            .audio_controller = AudioController.init(),
            .nav_cell_size = config.nav_cell_size,
        };
    }

    /// Releases owned processor/controller state. Borrowed gameplay data and
    /// frame storage stay owned by the gameplay state.
    pub fn deinit(self: *SimulationPipeline) void {
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

    /// Runs the current full-active fixed-step stage order and returns stage
    /// stats. Real scoped filtering is intentionally deferred until world/chunk
    /// visibility data exists.
    pub fn update(self: *SimulationPipeline, context: SimulationPipelineUpdateContext) !SimulationPipelineStats {
        const data = context.data;
        const frame = context.frame;

        frame.phase = .processors;
        // Player-authored world edit. Runs first; its world_tile_changed event is
        // deferred and re-masks navigation in merge_outputs regardless of order.
        try self.dig.process(context.world, data, context.player.*, frame);

        // Backbone scope pass. Advance the stagger clock, derive the camera
        // cognition halo, and select the cognition (AI/steering) subset for this
        // step. Chunk maintenance is folded into movement (below), which derives
        // each integrated body's chunk in-pass — exact every step at any speed, no
        // separate recompute. The AI gather reads the chunk movement wrote last
        // step (the body's current pre-move cell). Movement/collision gate on tier
        // only (no chunk filter), so they keep running off-screen; cognition gates
        // on the halo + stagger.
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

        // The player's plane is deliberately NOT propagated into the AI goal level:
        // NPCs stay on the surface (goal_level 0) until autonomous descent lands.
        // Seeding the player's underground plane here would make them request
        // cross-level paths they cannot walk (start_level is pinned to 0), piling
        // them at the ramp mouth. They simply seek the (x,y) above the player.
        const player_target = if (data.movementBodyConst(context.player.entity)) |pbody|
            pbody.previous_position
        else
            math.Vec2{ .x = 400, .y = 225 };

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

        // Movement gates on tier only (no chunk filter): every non-dormant entity
        // integrates, on- or off-screen. Null = full-active warm SIMD range. Movement
        // also derives each integrated body's chunk in-pass via chunk_grid, so chunk
        // stays exact every step with no separate recompute.
        const movement_scope_indices = (try self.scope.gatherMovementBodyIndices(data, context.thread_system, .{})).indices;
        const scope_columns = data.scopeColumnsSlice();
        var movement_slice = data.movementBodySlice();
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

        var clamp_timer = StageTimer.start();
        clampAiEntitiesToBounds(data, context.bounds_width, context.bounds_height);
        try context.player.clampToBounds(data, context.bounds_width, context.bounds_height);
        // Gate the player against solid world tiles on their current plane (mining:
        // underground dirt is solid until dug). Runs after the bounds clamp and
        // before entity collision so downstream stages see the gated position. AI
        // entities stay on the surface (level 0, fully walkable) this slice, so the
        // gate is player-only by design — see docs/simulation-tiers-and-pipeline.md.
        gatePlayerToWalkableTiles(context.world, data, context.player.*);
        gateNpcEntitiesToWalkableTiles(context.world, data);
        clamp_timer.stop(context.perf, .pipeline_clamp_bounds);

        // Collision also gates on tier only (no chunk filter): off-screen entities
        // keep colliding with geometry. Null = full-active.
        const collision_scope_indices = (try self.scope.gatherCollisionBoundsIndices(data, context.thread_system, .{})).indices;
        var collision_timer = StageTimer.start();
        const collision_stats = try self.collision.update(data, &frame.contacts, context.thread_system, .{
            .scope_dense_indices = collision_scope_indices,
        });
        collision_timer.stop(context.perf, .pipeline_collision);

        var collision_response_timer = StageTimer.start();
        const collision_response_stats = try self.collision_response.update(data, frame);
        collision_response_timer.stop(context.perf, .pipeline_collision_response);

        // After movement/collision settle positions, update planes: follow a ramp
        // on cell entry, fall one level per step when standing over a hole. Both
        // the player and NPCs route through `DigController.applyEntityPlaneTraversal`
        // so falls carve their landing cell identically; a fall's tile change
        // re-masks navigation post-commit.
        try self.dig.applyPlaneTraversal(context.world, data, context.player, frame);
        try applyNpcPlaneTraversal(&self.dig, context.world, data, frame);

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
            movement_scope_indices,
            collision_scope_indices,
            steering_stats,
        );

        return .{
            .scope = scope,
            .spatial_index = spatial_index_stats,
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
    for (ai_slice.entities) |entity| {
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
/// copy that could (and did) drift out of sync.
fn applyNpcPlaneTraversal(dig: *DigController, world: *WorldSystem, data: *DataSystem, frame: *SimulationFrame) !void {
    const ai_slice = data.aiAgentSliceConst();
    for (ai_slice.entities) |entity| {
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
