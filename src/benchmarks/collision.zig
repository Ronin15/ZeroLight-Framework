// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const math = @import("../core/math.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const CollisionStats = @import("../game/systems/collision.zig").CollisionStats;
const CollisionSystem = @import("../game/systems/collision.zig").CollisionSystem;
const collision_range_alignment_items = @import("../game/systems/collision.zig").collision_range_alignment_items;
const simulation = @import("../game/simulation.zig");
const CollisionContact = @import("../game/simulation.zig").CollisionContact;
const RangeOutputStream = @import("../game/simulation.zig").RangeOutputStream;
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "collision",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
};

pub const sparse_group = suite.BenchmarkGroup{
    .name = "collision-sparse",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runSparseCase,
};

const FixtureMode = enum {
    dense,
    sparse,
};

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return suite.eventScaleCounts(profile);
}

pub fn createFixture(allocator: std.mem.Allocator, count: usize) !DataSystem {
    return createFixtureWithMode(allocator, count, .dense);
}

pub fn createSparseFixture(allocator: std.mem.Allocator, count: usize) !DataSystem {
    return createFixtureWithMode(allocator, count, .sparse);
}

fn createFixtureWithMode(allocator: std.mem.Allocator, count: usize, mode: FixtureMode) !DataSystem {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    const columns: usize = 512;
    for (0..count) |index| {
        const entity = try data.createEntity();
        const position = benchmarkPosition(index, columns, mode);
        try data.setMovementBody(entity, .{
            .position = position,
            .previous_position = position,
            .velocity = .{},
            .speed = 0,
        });
        try data.setCollisionBounds(entity, .{
            .size = .{ .x = 9, .y = 9 },
        });
    }

    return data;
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseWithMode(allocator, io, options, case, item_count, .dense);
}

pub fn runSparseCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseWithMode(allocator, io, options, case, item_count, .sparse);
}

fn runCaseWithMode(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, mode: FixtureMode) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var data = try createFixtureWithMode(allocator, item_count, mode);
    defer data.deinit();
    var system = CollisionSystem.init(allocator);
    defer system.deinit();
    if (suite.adaptiveTunerForCase(case, collision_range_alignment_items)) |tuner| {
        system.broadphase_tuner = tuner;
        system.narrowphase_tuner = suite.adaptiveTunerForCase(case, collision_range_alignment_items).?;
    }
    var contacts = RangeOutputStream(CollisionContact).init(allocator);
    defer contacts.deinit();

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();

    for (0..options.warmup_iterations) |_| {
        _ = try runOnce(&system, &data, &contacts, if (threads) |*thread_system| thread_system else null, case);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while ((!system.broadphase_tuner.isSettled() or !system.narrowphase_tuner.isSettled()) and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runOnce(&system, &data, &contacts, if (threads) |*thread_system| thread_system else null, case);
        }
    }
    const broadphase_settled_before_measurement = if (case.adaptive) system.broadphase_tuner.isSettled() else false;
    const narrowphase_settled_before_measurement = if (case.adaptive) system.narrowphase_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_collision_stats = CollisionStats{};
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_collision_stats = try runOnce(&system, &data, &contacts, if (threads) |*thread_system| thread_system else null, case);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_collision_stats.broadphase_batch);
    }

    var stats = accumulator.finish();
    stats.candidate_pairs = last_collision_stats.candidate_pair_count;
    stats.output_count = last_collision_stats.contact_count;
    stats.secondary_batch = suite.batchSummaryFromBatch(last_collision_stats.narrowphase_batch);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.broadphase_tuner.report(), broadphase_settled_before_measurement);
        stats.secondary_work_tuning = suite.workTuningSummary(system.narrowphase_tuner.report(), narrowphase_settled_before_measurement);
    }
    return stats;
}

fn runOnce(
    system: *CollisionSystem,
    data: *const DataSystem,
    contacts: *RangeOutputStream(CollisionContact),
    thread_system: ?*ThreadSystem,
    case: suite.BenchmarkCase,
) !CollisionStats {
    if (!case.usesThreadSystem()) {
        return try system.updateSerial(data, contacts);
    }

    return try system.update(data, contacts, thread_system.?, .{
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

fn benchmarkItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(collision_range_alignment_items) orelse
        suite.alignItemCount(suite.default_items_per_range, collision_range_alignment_items);
}

fn benchmarkPosition(index: usize, columns: usize, mode: FixtureMode) math.Vec2 {
    return switch (mode) {
        .dense => .{
            .x = @floatFromInt((index % columns) * 7),
            .y = @floatFromInt((index / columns) * 7),
        },
        .sparse => sparseBenchmarkPosition(index, columns),
    };
}

fn sparseBenchmarkPosition(index: usize, columns: usize) math.Vec2 {
    const sparse_group_index = index / 20;
    const slot = index % 20;
    const base_index = sparse_group_index * 20 + if (slot == 1) @as(usize, 0) else slot;
    const offset_x: usize = if (slot == 1) 6 else 0;
    return .{
        .x = @floatFromInt((base_index % columns) * 32 + offset_x),
        .y = @floatFromInt((base_index / columns) * 32),
    };
}

test "collision benchmark fixture creates requested collision bodies" {
    var data = try createFixture(std.testing.allocator, 32);
    defer data.deinit();

    try std.testing.expectEqual(@as(usize, 32), data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 32), data.collisionBoundsSliceConst().entities.len);
}

test "collision sparse fixture has far fewer contacts than dense fixture" {
    var dense_data = try createFixture(std.testing.allocator, 200);
    defer dense_data.deinit();
    var sparse_data = try createSparseFixture(std.testing.allocator, 200);
    defer sparse_data.deinit();
    var dense_system = CollisionSystem.init(std.testing.allocator);
    defer dense_system.deinit();
    var sparse_system = CollisionSystem.init(std.testing.allocator);
    defer sparse_system.deinit();
    var dense_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer dense_contacts.deinit();
    var sparse_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer sparse_contacts.deinit();

    const dense = try dense_system.updateSerial(&dense_data, &dense_contacts);
    const sparse = try sparse_system.updateSerial(&sparse_data, &sparse_contacts);

    try std.testing.expect(dense.contact_count > sparse.contact_count);
    try std.testing.expectEqual(@as(usize, 10), sparse.contact_count);
}

test "collision benchmark tiny serial case runs without display" {
    const options = suite.Options{
        .warmup_iterations = 1,
        .iterations = 1,
    };
    const stats = try runCase(std.testing.allocator, std.testing.io, options, suite.default_cases[0], 10_000);
    try std.testing.expectEqual(suite.RunStatus.measured, stats.status);
    try std.testing.expect(stats.batch.ran_inline);
}

test "collision benchmark profiles cover high-throughput target counts" {
    try std.testing.expectEqualSlices(usize, suite.eventScaleCounts(.quick), defaultItemCounts(.quick));
    try std.testing.expectEqualSlices(usize, suite.eventScaleCounts(.standard), defaultItemCounts(.standard));
    try std.testing.expectEqualSlices(usize, suite.eventScaleCounts(.stress), defaultItemCounts(.stress));
}
