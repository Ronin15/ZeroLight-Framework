// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const math = @import("../core/math.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const NavigationIntent = @import("../game/simulation.zig").NavigationIntent;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const PathfindingSystem = @import("../game/systems/pathfinding.zig").PathfindingSystem;
const SteeringStats = @import("../game/systems/steering.zig").SteeringStats;
const SteeringSystem = @import("../game/systems/steering.zig").SteeringSystem;
const steering_range_alignment_items = @import("../game/systems/steering.zig").steering_range_alignment_items;
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "steering",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
};

const quick_counts = [_]usize{ 128, 512, 1024 };
const standard_counts = [_]usize{ 512, 1024, 4096 };
const stress_counts = [_]usize{ 4096, 10000 };

const Fixture = struct {
    data: DataSystem,
    frame: SimulationFrame,
    pathfinding: PathfindingSystem,
    agents: std.ArrayList(EntityId) = .empty,
    obstacle_count: usize = 0,

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.agents.deinit(allocator);
        self.pathfinding.deinit();
        self.frame.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &quick_counts,
        .standard => &standard_counts,
        .stress => &stress_counts,
    };
}

pub fn createFixture(allocator: std.mem.Allocator, count: usize) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    var frame = SimulationFrame.init(allocator);
    errdefer frame.deinit();
    try frame.reserveStreams(suite.rangeCount(count, steering_range_alignment_items), 0, count, 0, 0, 0);
    try frame.reservePathRequests(suite.rangeCount(count, steering_range_alignment_items), count);
    var pathfinding = PathfindingSystem.init(allocator);
    errdefer pathfinding.deinit();
    try pathfinding.reserve(.{
        .max_frame_requests = count,
        .max_pending_requests = count,
        .max_cached_results = count * 2,
        .max_group_fields = 4,
        .worker_participant_count = 1,
        .max_solved_requests_per_step = count,
    });
    var agents = std.ArrayList(EntityId).empty;
    errdefer agents.deinit(allocator);
    try agents.ensureTotalCapacity(allocator, count);

    const side = gridSide(count);
    for (0..count) |index| {
        const entity = try data.createEntity();
        const x: f32 = @floatFromInt(index % side);
        const y: f32 = @floatFromInt(index / side);
        const position = math.Vec2{ .x = x * 18.0, .y = y * 18.0 };
        try data.setMovementBody(entity, .{
            .position = position,
            .previous_position = position,
            .velocity = .{},
            .speed = 32,
        });
        try data.setSteeringAgent(entity, .{
            .agent_radius = 7,
            .waypoint_tolerance = 5,
            .avoidance_radius = 44,
            .avoidance_weight = 1.25,
            .max_neighbor_samples = 12,
            .stuck_step_threshold = 12,
            .replan_cooldown_steps = 8,
            .unavailable_backoff_steps = 30,
        });
        agents.appendAssumeCapacity(entity);
    }

    var obstacle_count: usize = 0;
    for (0..@min(@as(usize, 16), side)) |index| {
        const obstacle = try data.createEntity();
        const position = math.Vec2{ .x = @as(f32, @floatFromInt(index)) * 72.0 + 36.0, .y = 96.0 };
        try data.setMovementBody(obstacle, .{
            .position = position,
            .previous_position = position,
            .velocity = .{},
            .speed = 0,
        });
        try data.setCollisionBounds(obstacle, .{ .size = .{ .x = 28, .y = 28 } });
        try data.setCollisionResponse(obstacle, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
        obstacle_count += 1;
    }

    const world_extent = @as(f32, @floatFromInt(side + 4)) * 32.0;
    try pathfinding.rebuildStaticNavGrid(&data, world_extent, world_extent, 32.0);

    return .{ .data = data, .frame = frame, .pathfinding = pathfinding, .agents = agents, .obstacle_count = obstacle_count };
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try createFixture(allocator, item_count);
    defer fixture.deinit(allocator);
    var system = SteeringSystem.init(allocator);
    defer system.deinit();
    try system.reserveForCapacity(item_count, fixture.obstacle_count);
    if (suite.adaptiveTunerForCase(case, steering_range_alignment_items)) |tuner| {
        system.adaptive_tuner = tuner;
    }

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();

    for (0..options.warmup_iterations) |_| {
        _ = try runOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!system.adaptive_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case);
        }
    }
    const settled_before_measurement = if (case.adaptive) system.adaptive_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = SteeringStats{};
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_stats = try runOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.batch);
    }

    var stats = accumulator.finish();
    stats.candidate_pairs = last_stats.agent_candidate_checks + last_stats.obstacle_candidate_checks;
    stats.sample_count = last_stats.agent_neighbor_samples + last_stats.obstacle_samples;
    stats.output_count = last_stats.movement_intent_count;
    stats.secondary_batch = suite.batchSummaryFromBatch(BatchStats{});
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.adaptive_tuner.report(), settled_before_measurement);
    }
    return stats;
}

fn runOnce(system: *SteeringSystem, fixture: *Fixture, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase) !SteeringStats {
    fixture.frame.beginStep();
    try appendNavigationIntents(&fixture.frame, fixture.agents.items);
    if (!case.usesThreadSystem()) {
        return try system.updateSerial(&fixture.data, &fixture.frame, &fixture.pathfinding, .{});
    }
    return try system.update(&fixture.data, &fixture.frame, thread_system.?, &fixture.pathfinding, .{
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

fn benchmarkItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(steering_range_alignment_items) orelse
        suite.alignItemCount(suite.default_items_per_range, steering_range_alignment_items);
}

fn appendNavigationIntents(frame: *SimulationFrame, agents: []const EntityId) !void {
    try frame.navigation_intents.prepareRangeCounts(1);
    frame.navigation_intents.addCount(0, agents.len);
    try frame.navigation_intents.prefix();
    var writer = frame.navigation_intents.rangeWriter(0);
    for (agents, 0..) |entity, index| {
        writer.write(NavigationIntent{
            .entity = entity,
            .goal = .{ .x = 640.0, .y = 360.0 },
            .direct_direction_x = if (index % 2 == 0) 1 else -1,
            .direct_direction_y = if (index % 3 == 0) 0.5 else 0,
            .priority = 1,
        });
    }
    writer.finish();
    frame.navigation_intents.finishWrite();
}

fn gridSide(count: usize) usize {
    var side: usize = 1;
    while (side * side < count) : (side += 1) {}
    return side;
}
