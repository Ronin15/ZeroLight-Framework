// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared private test fixtures for the steering files. Test-only: no production path
//! imports it. Single-file helpers stay in their file.

const std = @import("std");
const math = @import("../../../core/math.zig");
const DataSystem = @import("../../data_system.zig").DataSystem;
const EntityId = @import("../../data_system.zig").EntityId;
const NavigationIntent = @import("../../simulation.zig").NavigationIntent;
const SimulationFrame = @import("../../simulation.zig").SimulationFrame;
const PathfindingSystem = @import("../pathfinding.zig").PathfindingSystem;
const StaticColliderSystem = @import("../static_colliders.zig").StaticColliderSystem;
const BoxHits = @import("../static_colliders.zig").BoxHits;
const StructuralCommand = @import("../../data_system.zig").StructuralCommand;
const SteeringStats = @import("system.zig").SteeringStats;
const SteeringSystem = @import("system.zig").SteeringSystem;
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;

/// `SteeringSystem.update` inline as one range: a thread system with no workers.
pub fn updateSteeringInline(steering: *SteeringSystem, data: *const DataSystem, frame: *SimulationFrame, pathfinding: *const PathfindingSystem, colliders: *const StaticColliderSystem) !SteeringStats {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    return steering.update(data, frame, &threads, pathfinding, colliders, .{});
}

pub fn expectEveryStageThreaded(stats: SteeringStats) !void {
    try std.testing.expect(!stats.batch.ran_inline);
    try std.testing.expect(stats.batch.active_worker_threads > 0);
}

// An intent for `agent` (the `agent_index`th) whose direct direction is unique to the
// agent and `variant`.
pub fn selectionIntent(agent: EntityId, agent_index: usize, variant: usize, priority: i16) NavigationIntent {
    const angle = @as(f32, @floatFromInt(agent_index)) * 0.13 + @as(f32, @floatFromInt(variant)) * 1.7;
    return .{ .entity = agent, .goal = .{ .x = 999, .y = 999 }, .direct_direction_x = @cos(angle), .direct_direction_y = @sin(angle), .priority = priority };
}

pub fn addSteeredEntity(data: *DataSystem, position: math.Vec2) !EntityId {
    const entity = try data.createEntity();
    errdefer _ = data.destroyEntity(entity);
    try data.setMovementBody(entity, .{
        .position = position,
        .previous_position = position,
        .velocity = .{},
        .speed = 32,
    });
    try data.setSteeringAgent(entity, .{
        .agent_radius = 8,
        .waypoint_tolerance = 4,
        .avoidance_radius = 48,
        .avoidance_weight = 1.5,
        .max_neighbor_samples = 8,
        .stuck_step_threshold = 3,
        .replan_cooldown_steps = 4,
        .unavailable_backoff_steps = 12,
    });
    return entity;
}

pub fn addStaticObstacle(data: *DataSystem, position: math.Vec2, size: math.Vec2) !EntityId {
    const entity = try data.createEntity();
    errdefer _ = data.destroyEntity(entity);
    try data.setMovementBody(entity, .{
        .position = position,
        .previous_position = position,
        .velocity = .{},
        .speed = 0,
    });
    try data.setCollisionBounds(entity, .{ .size = size });
    try data.setCollisionResponse(entity, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    return entity;
}

pub fn appendNavigationIntent(frame: *SimulationFrame, intent: NavigationIntent) !void {
    try appendNavigationIntents(frame, &.{intent});
}

pub fn appendNavigationIntents(frame: *SimulationFrame, intents: []const NavigationIntent) !void {
    try frame.navigation_intents.prepareRangeCounts(1);
    frame.navigation_intents.addCount(0, intents.len);
    try frame.navigation_intents.prefix();
    var writer = frame.navigation_intents.rangeWriter(0);
    for (intents) |intent| writer.write(intent);
    writer.finish();
    frame.navigation_intents.finishWrite();
}

// Static colliders of `data`'s statics on the cell grid of `pathfinding`'s world-less build
// over `width` x `height`.
pub fn testColliders(pathfinding: *const PathfindingSystem, data: *const DataSystem, width: f32, height: f32, cell_size: f32) !StaticColliderSystem {
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    errdefer colliders.deinit();
    try colliders.rebuild(data, try pathfinding.boundsNavExtent(width, height, cell_size).colliderGeometry());
    return colliders;
}

// The commit seam for statics in this step: the collider reserve, the commit of
// `commands`, the capture, and the sync.
pub fn commitStaticsForTest(frame: *SimulationFrame, data: *DataSystem, colliders: *StaticColliderSystem, commands: []const StructuralCommand) !void {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    try colliders.reserveForCommit(data, commands.len);
    try frame.structural_commands.prepareRangeCounts(1);
    frame.structural_commands.addCount(0, commands.len);
    try frame.structural_commands.prefix();
    var writer = frame.structural_commands.rangeWriter(0);
    for (commands) |command| writer.write(command);
    writer.finish();
    frame.structural_commands.finishWrite();
    _ = try frame.applyStructuralCommands(data);
    colliders.capture(frame);
    try colliders.sync(data, &serial_threads);
}

// Parity statics on a 512-unit level of 16-unit cells (2 x 2 chunks): boxes of size
// classes 0 through the top, one across the chunk border at x = 256, near the parity
// agents' 224 x 112 grid.
pub const parity_statics = [_][2]math.Vec2{
    .{ .{ .x = 72, .y = 32 }, .{ .x = 36, .y = 96 } },
    .{ .{ .x = 96, .y = 20 }, .{ .x = 48, .y = 60 } },
    .{ .{ .x = 30, .y = 70 }, .{ .x = 8, .y = 8 } },
    .{ .{ .x = 140, .y = 40 }, .{ .x = 20, .y = 20 } },
    .{ .{ .x = 200, .y = 60 }, .{ .x = 70, .y = 12 } },
    .{ .{ .x = 180, .y = 90 }, .{ .x = 300, .y = 30 } },
};

/// Fails unless some steering agent's obstacle query box (its avoidance plus agent radius
/// about its position, on its level) meets a static: the fixture invariant that a steering
/// step covers obstacle pushes.
pub fn expectStaticNearASteeredAgent(colliders: *const StaticColliderSystem, data: *const DataSystem) !void {
    const view = colliders.view();
    const agents = data.steeringAgentSliceConst();
    var min_x: [1]f32 = undefined;
    var min_y: [1]f32 = undefined;
    var max_x: [1]f32 = undefined;
    var max_y: [1]f32 = undefined;
    const hits = BoxHits{ .min_x = &min_x, .min_y = &min_y, .max_x = &max_x, .max_y = &max_y };
    for (agents.entities, 0..) |agent, row| {
        const position = (data.movementBodyConst(agent) orelse continue).position;
        const radius = agents.avoidance_radii[row] + agents.agent_radii[row];
        const box = math.Aabb{ .min_x = position.x - radius, .min_y = position.y - radius, .max_x = position.x + radius, .max_y = position.y + radius };
        if (view.queryBox(data.worldLevelConst(agent) orelse 0, box, .{ .max_hits = 1, .max_work = std.math.maxInt(u16) }, hits).hits > 0) return;
    }
    return error.NoStaticNearASteeredAgent;
}

// The parity statics span at least two query classes and two chunks.
pub fn expectParityStaticsSpread(colliders: *const StaticColliderSystem) !void {
    try std.testing.expect(colliders.query_class_mask.count() >= 2);
    const view = colliders.view();
    try std.testing.expect(view.chunkHasRows(0, 0) and view.chunkHasRows(0, 1));
}
