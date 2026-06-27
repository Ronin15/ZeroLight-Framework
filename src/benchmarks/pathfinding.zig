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
const default_max_solves_per_frame = @import("../game/systems/pathfinding.zig").default_max_solves_per_frame;
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
    try requests.reserve(suite.rangeCount(count, suite.default_items_per_range), count);

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
        system.fallback_tuner = tuner;
    }

    const grid_side = fixtureGridSide(item_count, .common_goal);
    const world_extent = @as(f32, @floatFromInt(grid_side)) * 32.0;

    // Build the thread system first so the pathfinding system is sized for its real
    // participant count (workers + 1); each participant gets one O(cells) A* slot.
    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;

    try system.reserve(PathfindingCapacity{
        .max_group_fields = 8,
        .worker_participant_count = participant_count,
        // Let elastic capacity grow to the full benchmark item count (some profiles
        // exceed the default ceiling); agent_count drives the per-step caps.
        .max_agent_budget = @max(item_count, 1),
    });
    try system.rebuildStaticNavGrid(&fixture.data, world_extent, world_extent, 32.0);

    system.clearRuntimeState();
    _ = try runColdOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case, item_count, item_count, item_count);
    for (0..options.warmup_iterations) |_| {
        system.clearTransientRequestsRetainingFields();
        _ = try runColdOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case, item_count, item_count, item_count);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!system.fallback_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            system.clearTransientRequestsRetainingFields();
            _ = try runColdOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case, item_count, item_count, item_count);
        }
    }
    const solve_settled_before_measurement = if (case.adaptive) system.fallback_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    for (0..options.iterations) |_| {
        system.clearTransientRequestsRetainingFields();
        const start_ns = suite.nowNs(io);
        last_stats = try runColdOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case, item_count, item_count, item_count);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.solveBatch());
    }

    var stats = accumulator.finish();
    // Goal-keyed dedup resolves a shared goal once; same-goal duplicates and
    // warm cache hits are also resolved agents. Count all so output_count still
    // reflects every requesting agent.
    stats.output_count = last_stats.available_results + last_stats.unavailable_results +
        last_stats.duplicate_requests + last_stats.cache_hits;
    stats.candidate_pairs = last_stats.duplicate_requests + last_stats.cache_hits;
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.fallback_tuner.report(), solve_settled_before_measurement);
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
    return runFallbackWorkloadCase(allocator, io, options, case, item_count, .hard_fallback, .cold_hard_fallback, item_count, fallback_budget);
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

    // Build the thread system first so the pathfinding A* scratch is sized for the
    // real participant count (workers + 1) during the nav build, not lazily.
    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;

    try system.reserve(PathfindingCapacity{
        .max_group_fields = 8,
        .worker_participant_count = participant_count,
        // Elastic capacity grows to the benchmark item count; the per-step solve and
        // fallback budgets are still applied via the config each runColdOnce.
        .max_agent_budget = @max(item_count, 1),
    });
    try system.rebuildStaticNavGrid(&fixture.data, world_extent, world_extent, 32.0);

    system.clearRuntimeState();
    _ = try runColdOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case, item_count, solve_budget, fallback_budget);

    for (0..options.warmup_iterations) |_| {
        if (mode == .cold_hard_fallback) system.clearRuntimeState();
        _ = try runColdOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case, item_count, solve_budget, fallback_budget);
    }
    if (case.adaptive and mode == .cold_hard_fallback) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!system.fallback_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            system.clearRuntimeState();
            _ = try runColdOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case, item_count, solve_budget, fallback_budget);
        }
    }
    const fallback_settled_before_measurement = if (case.adaptive) system.fallback_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    for (0..options.iterations) |_| {
        if (mode == .cold_hard_fallback) system.clearRuntimeState();
        const start_ns = suite.nowNs(io);
        last_stats = try runColdOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case, item_count, solve_budget, fallback_budget);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.solveBatch());
    }

    var stats = accumulator.finish();
    stats.output_count = last_stats.available_results + last_stats.unavailable_results;
    stats.candidate_pairs = if (mode == .hot_cache) last_stats.cache_hits else last_stats.fallback_requests;
    stats.deferred_count = last_stats.deferred_requests;
    stats.fallback_deferred_count = last_stats.fallback_deferred_requests;
    stats.cache_evictions = last_stats.cache_evictions;

    // Throughput must reflect items actually serviced this step, not the requested
    // count. Cold solves are capped at the per-frame amortization ceiling, so a
    // 1024-request row only performs min(1024, ceiling) solves and defers the rest to
    // later frames; counting all 1024 would inflate the curve to look like the solver
    // scales past the cap when its real per-step work is flat at the ceiling. Report
    // serviced/sec (solves when cold, cache hits when hot); both equal item_count when
    // nothing is deferred, so honest rows are unchanged.
    const serviced = stats.candidate_pairs;
    if (mode == .cold_hard_fallback) {
        // Cold fallbacks are bounded by the effective fallback limit, which is the
        // configured fallback budget clamped to the per-frame ceiling; anything beyond
        // that defers. This pins the "no silent cap drift" invariant.
        std.debug.assert(serviced == @min(item_count, @min(fallback_budget, default_max_solves_per_frame)));
    }
    if (stats.mean_ns != 0) {
        stats.items_per_second = suite.itemsPerSecond(serviced, stats.mean_ns);
    }
    if (case.adaptive and mode == .cold_hard_fallback) {
        stats.work_tuning = suite.workTuningSummary(system.fallback_tuner.report(), fallback_settled_before_measurement);
    }
    return stats;
}

fn runColdOnce(system: *PathfindingSystem, fixture: *Fixture, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase, agent_count: usize, solve_budget: usize, fallback_budget: usize) !PathfindingStats {
    if (!case.usesThreadSystem()) {
        return try system.updateSerial(&fixture.requests, agent_count, .{
            .max_solved_requests_per_step = solve_budget,
            .max_fallback_requests_per_step = fallback_budget,
        });
    }
    return try system.update(&fixture.requests, agent_count, thread_system.?, .{
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

test "pathfinding hard fallback budget preserves request denominator" {
    const options = suite.Options{
        .warmup_iterations = 0,
        .iterations = 1,
        .fallback_budget = 8,
    };
    const stats = try runHardFallbackBudgetCase(std.testing.allocator, std.testing.io, options, suite.default_cases[0], 16);

    try std.testing.expectEqual(suite.RunStatus.measured, stats.status);
    try std.testing.expectEqual(@as(usize, 16), stats.item_count);
    try std.testing.expectEqual(@as(usize, 8), stats.output_count);
    try std.testing.expectEqual(@as(usize, 8), stats.fallback_deferred_count);
    try std.testing.expectEqual(@as(usize, 8), stats.deferred_count);
}
