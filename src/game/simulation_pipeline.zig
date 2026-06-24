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
};

/// Borrowed per-step inputs for pipeline update.
/// The pipeline owns systems and stage order, but not persistent game data,
/// frame storage, app services, or state transitions.
pub const SimulationPipelineUpdateContext = struct {
    data: *DataSystem,
    frame: *SimulationFrame,
    player: Player,
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
        const ai_slice = data.aiAgentSliceConst();
        const move_slice = data.movementBodySliceConst();
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
        const pathfinding_stats = try self.pathfinding.update(&frame.path_requests, context.thread_system, .{});
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
        clamp_timer.stop(context.perf, .pipeline_clamp_bounds);

        var collision_timer = StageTimer.start();
        const collision_stats = try self.collision.update(data, &frame.contacts, context.thread_system, .{});
        collision_timer.stop(context.perf, .pipeline_collision);

        var collision_response_timer = StageTimer.start();
        const collision_response_stats = try self.collision_response.update(data, frame);
        collision_response_timer.stop(context.perf, .pipeline_collision_response);

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

fn clampAiEntitiesToBounds(data: *DataSystem, bounds_width: f32, bounds_height: f32) void {
    const ai_slice = data.aiAgentSliceConst();
    for (ai_slice.entities) |entity| {
        const body = data.movementBodyPtr(entity) orelse continue;
        const visual = data.primitiveVisualConst(entity) orelse continue;

        const max_x = bounds_width - visual.size.x;
        const new_x = math.clamp(body.position_x.*, 0, max_x);
        if (new_x != body.position_x.*) body.velocity_x.* = 0;
        body.position_x.* = new_x;

        const max_y = bounds_height - visual.size.y;
        const new_y = math.clamp(body.position_y.*, 0, max_y);
        if (new_y != body.position_y.*) body.velocity_y.* = 0;
        body.position_y.* = new_y;
    }
}

test "pipeline updates full active player-only state through serial path" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);
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
            .max_worker_scratch_slots = 4,
            .max_solved_requests_per_step = 2,
            .max_fallback_requests_per_step = 2,
        },
    });
    defer pipeline.deinit();

    frame.beginStep();
    const stats = try pipeline.update(.{
        .data = &data,
        .frame = &frame,
        .player = player,
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
