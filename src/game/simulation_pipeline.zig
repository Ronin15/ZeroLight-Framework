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
const SimulationScope = @import("simulation_scope.zig").SimulationScope;
const WorldSystem = @import("world_system.zig").WorldSystem;

/// Construction policy for the state-owned simulation pipeline.
/// Capacities are reserved up front so the fixed-step hot path can stay warm.
pub const SimulationPipelineConfig = struct {
    steering_agent_capacity: usize = 0,
    static_obstacle_capacity: usize = 0,
    contact_capacity: usize = 0,
    pathfinding: PathfindingCapacity = .{},
    nav_cell_size: f32 = 32.0,
    navigation_world: ?*const WorldSystem = null,
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
        try pathfinding.rebuildStaticNavGridWithWorld(data, config.navigation_world, bounds_width, bounds_height, config.nav_cell_size);
        var collision = CollisionSystem.init(allocator);
        errdefer collision.deinit();
        var collision_response = CollisionResponseSystem.init(allocator);
        errdefer collision_response.deinit();
        try collision_response.reserveForContacts(config.contact_capacity);

        return .{
            .movement = MovementSystem.init(),
            .collision = collision,
            .collision_response = collision_response,
            .ai = ai,
            .steering = steering,
            .pathfinding = pathfinding,
            .dig = DigController.init(config.dig),
            .audio_controller = AudioController.init(),
            .nav_cell_size = config.nav_cell_size,
        };
    }

    /// Releases owned processor/controller state. Borrowed gameplay data and
    /// frame storage stay owned by the gameplay state.
    pub fn deinit(self: *SimulationPipeline) void {
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
        try self.pathfinding.rebuildStaticNavGridWithWorld(data, world, bounds_width, bounds_height, self.nav_cell_size);
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
        const scope = SimulationScope.fullActive(data.simulationScopeStatsFullActive());

        frame.phase = .processors;
        // Player-authored world edit. Runs first; its world_tile_changed event is
        // deferred and re-masks navigation in merge_outputs regardless of order.
        try self.dig.process(context.world, data, context.player.*, frame);

        const ai_slice = data.aiAgentSliceConst();
        const move_slice = data.movementBodySliceConst();
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
        const ai_stats = try self.ai.update(ai_slice, move_slice, data, frame, context.thread_system, context.delta_seconds, .{
            .intent_seed = 0xfeedf00d,
            .seek_target = player_target,
            // Every demo agent seeks the moving player: the canonical shared goal.
            // Declaring group mode routes them through one managed flow field
            // toward the player's nav cell instead of N individual A* solves.
            .nav_request_kind = .group,
            .navigation_intents = &frame.navigation_intents,
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

        var movement_slice = data.movementBodySlice();
        var movement_timer = StageTimer.start();
        const movement_stats = self.movement.update(&movement_slice, context.thread_system, context.delta_seconds, .{});
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
        clamp_timer.stop(context.perf, .pipeline_clamp_bounds);

        var collision_timer = StageTimer.start();
        const collision_stats = try self.collision.update(data, &frame.contacts, context.thread_system, .{});
        collision_timer.stop(context.perf, .pipeline_collision);

        var collision_response_timer = StageTimer.start();
        const collision_response_stats = try self.collision_response.update(data, frame);
        collision_response_timer.stop(context.perf, .pipeline_collision_response);

        // After movement/collision settle the player's position, update their plane:
        // fall into a hole or follow a ramp on cell entry. Player-only; mutates the
        // borrowed `Player.current_level` and snaps the body, then the dig reaction's
        // tile change re-masks navigation post-commit.
        try self.dig.applyPlaneTraversal(context.world, data, context.player, frame);

        return .{
            .scope = scope,
            .ai = ai_stats,
            .steering = steering_stats,
            .pathfinding = pathfinding_stats,
            .movement = movement_stats,
            .collision = collision_stats,
            .collision_response = collision_response_stats,
        };
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

/// Stops the player from moving into solid world tiles on their current plane.
/// No-op on level 0 (the surface is fully walkable and pre-existing decos/water are
/// intentionally pass-through there). Resolves X then Y independently against the
/// pre-move position so a diagonal push into a wall slides along it. The body is one
/// tile wide; sampling the four AABB corners (with an epsilon so a flush right/bottom
/// edge stays in the covered cell) is exact for the sub-tile motion this produces.
/// Allocation-free, single entity, scalar.
fn gatePlayerToWalkableTiles(world: *const WorldSystem, data: *DataSystem, player: Player) void {
    if (player.current_level == 0) return;
    const body = data.movementBodyPtr(player.entity) orelse return;
    const visual = data.primitiveVisualConst(player.entity) orelse return;
    const w = visual.size.x;
    const h = visual.size.y;
    const pre_x = body.previous_x.*;
    const pre_y = body.previous_y.*;
    const post_x = body.position_x.*;
    const post_y = body.position_y.*;

    var resolved_x = post_x;
    if (rectOverlapsSolidTile(world, player.current_level, post_x, pre_y, w, h)) resolved_x = pre_x;
    var resolved_y = post_y;
    if (rectOverlapsSolidTile(world, player.current_level, resolved_x, post_y, w, h)) resolved_y = pre_y;

    if (resolved_x != post_x) body.velocity_x.* = 0;
    if (resolved_y != post_y) body.velocity_y.* = 0;
    body.position_x.* = resolved_x;
    body.position_y.* = resolved_y;
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
