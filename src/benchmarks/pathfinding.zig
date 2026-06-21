// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const math = @import("../core/math.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const PathRequest = @import("../game/simulation.zig").PathRequest;
const RangeOutputStream = @import("../game/simulation.zig").RangeOutputStream;
const PathfindingCapacity = @import("../game/systems/pathfinding.zig").PathfindingCapacity;
const PathfindingStats = @import("../game/systems/pathfinding.zig").PathfindingStats;
const PathfindingSystem = @import("../game/systems/pathfinding.zig").PathfindingSystem;
const default_max_fallback_requests_per_step = @import("../game/systems/pathfinding.zig").default_max_fallback_requests_per_step;
const pathfinding_range_alignment_items = @import("../game/systems/pathfinding.zig").pathfinding_range_alignment_items;
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "pathfinding",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
};

pub const fallback_group = suite.BenchmarkGroup{
    .name = "pathfinding-cache-open",
    .defaultItemCounts = fallbackDefaultItemCounts,
    .runCase = runFallbackCase,
};

pub const fallback_detour_group = suite.BenchmarkGroup{
    .name = "pathfinding-cache-detour",
    .defaultItemCounts = fallbackDefaultItemCounts,
    .runCase = runFallbackDetourCase,
};

pub const fallback_unreachable_group = suite.BenchmarkGroup{
    .name = "pathfinding-cache-unreachable",
    .defaultItemCounts = unreachableDefaultItemCounts,
    .runCase = runFallbackUnreachableCase,
};

pub const hard_fallback_group = suite.BenchmarkGroup{
    .name = "pathfinding-hard-fallback",
    .defaultItemCounts = fallbackDefaultItemCounts,
    .runCase = runHardFallbackCase,
};

pub const hard_fallback_budget_group = suite.BenchmarkGroup{
    .name = "pathfinding-hard-fallback-budget",
    .defaultItemCounts = fallbackDefaultItemCounts,
    .runCase = runHardFallbackBudgetCase,
};

const quick_counts = [_]usize{ 128, 512, 1024 };
const standard_counts = [_]usize{ 512, 1024, 4096 };
const stress_counts = [_]usize{ 4096, 10000 };
const fallback_quick_counts = [_]usize{ 16, 64, 128 };
const fallback_standard_counts = [_]usize{ 64, 128, 256, 1024 };
const fallback_stress_counts = [_]usize{ 256, 512, 1024 };
const unreachable_quick_counts = [_]usize{ 8, 16, 32 };
const unreachable_standard_counts = [_]usize{ 16, 32, 64, 1024 };
const unreachable_stress_counts = [_]usize{ 64, 128, 1024 };

const Workload = enum {
    common_goal,
    unique_open,
    blocked_detour,
    blocked_unreachable,
    hard_fallback,
};

const MeasurementMode = enum {
    hot_cache,
    cold_hard_fallback,
};

const Fixture = struct {
    data: DataSystem,
    requests: RangeOutputStream(PathRequest),

    fn deinit(self: *Fixture) void {
        self.requests.deinit();
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

pub fn fallbackDefaultItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &fallback_quick_counts,
        .standard => &fallback_standard_counts,
        .stress => &fallback_stress_counts,
    };
}

pub fn unreachableDefaultItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &unreachable_quick_counts,
        .standard => &unreachable_standard_counts,
        .stress => &unreachable_stress_counts,
    };
}

pub fn createFixture(allocator: std.mem.Allocator, count: usize, workload: Workload) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    var requests = RangeOutputStream(PathRequest).init(allocator);
    errdefer requests.deinit();
    try requests.reserve(rangeCount(count, suite.default_items_per_range), count);

    const side = fixtureGridSide(count, workload);
    try addObstacleField(&data, side, workload);
    for (0..count) |index| {
        const start_cell = requestStartCell(index, side, workload);
        const goal_cell = requestGoalCell(index, side, workload);
        const entity = try addEntity(&data, .{
            .x = @as(f32, @floatFromInt(start_cell.x)) * 32.0,
            .y = @as(f32, @floatFromInt(start_cell.y)) * 32.0,
        }, false);
        try appendRequest(&requests, .{
            .entity = entity,
            .start = .{
                .x = @as(f32, @floatFromInt(start_cell.x)) * 32.0 + 8.0,
                .y = @as(f32, @floatFromInt(start_cell.y)) * 32.0 + 8.0,
            },
            .goal = .{
                .x = @as(f32, @floatFromInt(goal_cell.x)) * 32.0 + 8.0,
                .y = @as(f32, @floatFromInt(goal_cell.y)) * 32.0 + 8.0,
            },
        });
    }

    return .{ .data = data, .requests = requests };
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try createFixture(allocator, item_count, .common_goal);
    defer fixture.deinit();
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    if (suite.adaptiveTunerForCase(case, pathfinding_range_alignment_items)) |tuner| {
        system.field_tuner = tuner;
    }

    const grid_side = fixtureGridSide(item_count, .common_goal);
    const world_extent = @as(f32, @floatFromInt(grid_side)) * 32.0;
    try system.reserve(PathfindingCapacity{
        .max_frame_requests = item_count,
        .max_pending_requests = item_count,
        .max_cached_results = item_count * 2,
        .max_goal_fields = 8,
        .max_worker_scratch_slots = 64,
        .max_solved_requests_per_step = item_count,
        .max_fallback_requests_per_step = item_count,
    });
    try system.rebuildStaticNavGrid(&fixture.data, world_extent, world_extent, 32.0);

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();

    system.clearRuntimeState();
    _ = try runColdOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case, item_count, item_count);
    for (0..options.warmup_iterations) |_| {
        system.clearTransientRequestsRetainingFields();
        _ = try runColdOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case, item_count, item_count);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!system.field_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            system.clearTransientRequestsRetainingFields();
            _ = try runColdOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case, item_count, item_count);
        }
    }
    const solve_settled_before_measurement = if (case.adaptive) system.field_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    for (0..options.iterations) |_| {
        system.clearTransientRequestsRetainingFields();
        const start_ns = suite.nowNs(io);
        last_stats = try runColdOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case, item_count, item_count);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.solveBatch());
    }

    var stats = accumulator.finish();
    stats.output_count = last_stats.available_results + last_stats.unavailable_results;
    stats.candidate_pairs = last_stats.field_requests;
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.field_tuner.report(), solve_settled_before_measurement);
    }
    return stats;
}

pub fn runFallbackCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runFallbackWorkloadCase(allocator, io, options, case, item_count, .unique_open, .hot_cache, item_count, item_count);
}

pub fn runFallbackDetourCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runFallbackWorkloadCase(allocator, io, options, case, item_count, .blocked_detour, .hot_cache, item_count, item_count);
}

pub fn runFallbackUnreachableCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runFallbackWorkloadCase(allocator, io, options, case, item_count, .blocked_unreachable, .hot_cache, item_count, item_count);
}

pub fn runHardFallbackCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runFallbackWorkloadCase(allocator, io, options, case, item_count, .hard_fallback, .cold_hard_fallback, item_count, item_count);
}

pub fn runHardFallbackBudgetCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    const fallback_budget = @min(options.fallback_budget orelse hardFallbackBudget(item_count), item_count);
    return runFallbackWorkloadCase(allocator, io, options, case, item_count, .hard_fallback, .cold_hard_fallback, fallback_budget, fallback_budget);
}

fn hardFallbackBudget(item_count: usize) usize {
    return @min(item_count, default_max_fallback_requests_per_step);
}

fn runFallbackWorkloadCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, workload: Workload, mode: MeasurementMode, solve_budget: usize, fallback_budget: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try createFixture(allocator, item_count, workload);
    defer fixture.deinit();
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    if (suite.adaptiveTunerForCase(case, pathfinding_range_alignment_items)) |tuner| {
        system.fallback_tuner = tuner;
    }

    const grid_side = fixtureGridSide(item_count, workload);
    const world_extent = @as(f32, @floatFromInt(grid_side)) * 32.0;
    try system.reserve(PathfindingCapacity{
        .max_frame_requests = item_count,
        .max_pending_requests = item_count,
        .max_cached_results = item_count * 2,
        .max_goal_fields = 8,
        .max_worker_scratch_slots = 64,
        .max_solved_requests_per_step = solve_budget,
        .max_fallback_requests_per_step = fallback_budget,
    });
    try system.rebuildStaticNavGrid(&fixture.data, world_extent, world_extent, 32.0);

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();

    system.clearRuntimeState();
    _ = try runColdOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case, solve_budget, fallback_budget);

    for (0..options.warmup_iterations) |_| {
        if (mode == .cold_hard_fallback) system.clearRuntimeState();
        _ = try runColdOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case, solve_budget, fallback_budget);
    }
    if (case.adaptive and mode == .cold_hard_fallback) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!system.fallback_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            system.clearRuntimeState();
            _ = try runColdOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case, solve_budget, fallback_budget);
        }
    }
    const fallback_settled_before_measurement = if (case.adaptive) system.fallback_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    for (0..options.iterations) |_| {
        if (mode == .cold_hard_fallback) system.clearRuntimeState();
        const start_ns = suite.nowNs(io);
        last_stats = try runColdOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case, solve_budget, fallback_budget);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.solveBatch());
    }

    var stats = accumulator.finish();
    stats.output_count = last_stats.available_results + last_stats.unavailable_results;
    stats.candidate_pairs = if (mode == .hot_cache) last_stats.cache_hits else last_stats.fallback_requests;
    stats.deferred_count = last_stats.deferred_requests;
    stats.fallback_deferred_count = last_stats.fallback_deferred_requests;
    stats.cache_evictions = last_stats.cache_evictions;
    if (case.adaptive and mode == .cold_hard_fallback) {
        stats.work_tuning = suite.workTuningSummary(system.fallback_tuner.report(), fallback_settled_before_measurement);
    }
    return stats;
}

fn runColdOnce(system: *PathfindingSystem, fixture: *Fixture, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase, solve_budget: usize, fallback_budget: usize) !PathfindingStats {
    if (!case.usesThreadSystem()) {
        return try system.updateSerial(&fixture.requests, .{
            .max_solved_requests_per_step = solve_budget,
            .max_fallback_requests_per_step = fallback_budget,
        });
    }
    return try system.update(&fixture.requests, thread_system.?, .{
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
        .max_solved_requests_per_step = solve_budget,
        .max_fallback_requests_per_step = fallback_budget,
    });
}

fn benchmarkItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(pathfinding_range_alignment_items) orelse
        suite.alignItemCount(suite.default_items_per_range, pathfinding_range_alignment_items);
}

fn appendRequest(stream: *RangeOutputStream(PathRequest), request: PathRequest) !void {
    const range_base = try stream.appendRangeCounts(1);
    stream.addCount(range_base, 1);
    try stream.prefixAppendedRanges(range_base);
    var writer = stream.rangeWriter(range_base);
    writer.write(request);
    writer.finish();
    stream.finishWrite();
}

fn addEntity(data: *DataSystem, position: math.Vec2, static: bool) !@import("../game/data_system.zig").EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = position, .previous_position = position });
    try data.setCollisionBounds(entity, .{ .size = .{ .x = 8, .y = 8 } });
    try data.setCollisionResponse(entity, .{ .mobility = if (static) .static else .dynamic });
    return entity;
}

const FixtureCell = struct {
    x: usize,
    y: usize,
};

fn requestStartCell(index: usize, side: usize, workload: Workload) FixtureCell {
    return switch (workload) {
        .common_goal, .unique_open => .{
            .x = index % side,
            .y = index / side,
        },
        .blocked_detour, .blocked_unreachable => .{
            .x = 1 + index % blockedLaneCount(side),
            .y = 1 + (index / blockedLaneCount(side)) % @max(@as(usize, 1), side - 2),
        },
        .hard_fallback => .{
            .x = 1 + (index / hardLaneCount(side)) % hardColumnCount(side),
            .y = 2 + (index % hardLaneCount(side)) * 3,
        },
    };
}

fn requestGoalCell(index: usize, side: usize, workload: Workload) FixtureCell {
    return switch (workload) {
        .common_goal => .{ .x = side - 2, .y = side - 2 },
        .unique_open => .{
            .x = side - 1 - index % side,
            .y = side - 1 - index / side,
        },
        .blocked_detour, .blocked_unreachable => .{
            .x = side - 2 - index % blockedLaneCount(side),
            .y = 1 + (index / blockedLaneCount(side)) % @max(@as(usize, 1), side - 2),
        },
        .hard_fallback => .{
            .x = side - 2 - (index / hardLaneCount(side)) % hardColumnCount(side),
            .y = 2 + (index % hardLaneCount(side)) * 3,
        },
    };
}

fn addObstacleField(data: *DataSystem, side: usize, workload: Workload) !void {
    switch (workload) {
        .common_goal, .unique_open => {},
        .blocked_detour => try addVerticalWall(data, side, true),
        .blocked_unreachable => try addVerticalWall(data, side, false),
        .hard_fallback => try addHardFallbackObstacles(data, side),
    }
}

fn addVerticalWall(data: *DataSystem, side: usize, with_gap: bool) !void {
    const wall_x = side / 2;
    const gap_y = side / 2;
    for (0..side) |y| {
        if (with_gap and y == gap_y) continue;
        _ = try addEntity(data, .{
            .x = @as(f32, @floatFromInt(wall_x)) * 32.0,
            .y = @as(f32, @floatFromInt(y)) * 32.0,
        }, true);
    }
}

fn blockedLaneCount(side: usize) usize {
    return @max(@as(usize, 1), side / 2 -| 2);
}

fn addHardFallbackObstacles(data: *DataSystem, side: usize) !void {
    const obstacle_x = side / 2;
    for (0..hardLaneCount(side)) |lane| {
        _ = try addEntity(data, .{
            .x = @as(f32, @floatFromInt(obstacle_x)) * 32.0,
            .y = @as(f32, @floatFromInt(2 + lane * 3)) * 32.0,
        }, true);
    }
}

fn hardLaneCount(side: usize) usize {
    return @max(@as(usize, 1), (side - 4) / 3);
}

fn hardColumnCount(side: usize) usize {
    return @max(@as(usize, 1), side / 2 - 1);
}

fn rangeCount(item_count: usize, items_per_range: usize) usize {
    return (item_count + items_per_range - 1) / items_per_range;
}

fn fixtureGridSide(item_count: usize, workload: Workload) usize {
    var side: usize = 16;
    while (side * side < item_count) side *= 2;
    if (workload == .hard_fallback) {
        while (hardLaneCount(side) * hardColumnCount(side) < item_count) side *= 2;
        return @max(side, @as(usize, 64));
    }
    return @max(side * 2, @as(usize, 64));
}

test "pathfinding benchmark fixture creates requested path requests" {
    var fixture = try createFixture(std.testing.allocator, 32, .common_goal);
    defer fixture.deinit();

    try std.testing.expectEqual(@as(usize, 32), fixture.requests.mergedItems().len);
}

test "pathfinding benchmark tiny serial case runs without display" {
    const options = suite.Options{
        .warmup_iterations = 1,
        .iterations = 1,
    };
    const stats = try runCase(std.testing.allocator, std.testing.io, options, suite.default_cases[0], 32);
    try std.testing.expectEqual(suite.RunStatus.measured, stats.status);
    try std.testing.expect(stats.batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 32), stats.output_count);
}
