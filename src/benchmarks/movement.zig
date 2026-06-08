// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const thread_mod = @import("../app/thread_system.zig");
const ThreadSystem = thread_mod.ThreadSystem;
const data_mod = @import("../game/data_system.zig");
const DataSystem = data_mod.DataSystem;
const movement = @import("../game/systems/movement.zig");
const MovementSystem = movement.MovementSystem;
const suite = @import("suite.zig");

const delta_seconds: f32 = 1.0 / 60.0;

pub const group = suite.BenchmarkGroup{
    .name = "movement",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
};

const quick_counts = [_]usize{ 1_024, 4_096, 16_384, 65_536 };
const standard_counts = [_]usize{ 1_024, 4_096, 16_384, 65_536, 262_144 };
const stress_counts = [_]usize{ 4_096, 16_384, 65_536, 262_144, 1_048_576 };

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &quick_counts,
        .standard => &standard_counts,
        .stress => &stress_counts,
    };
}

pub fn createFixture(allocator: std.mem.Allocator, count: usize) !DataSystem {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    for (0..count) |index| {
        const entity = try data.createEntity();
        const base: f32 = @floatFromInt(index);
        try data.setMovementBody(entity, .{
            .position = .{
                .x = base * 0.25,
                .y = base * -0.125,
            },
            .previous_position = .{
                .x = base * 0.25,
                .y = base * -0.125,
            },
            .velocity = .{
                .x = 20.0 + @as(f32, @floatFromInt(index % 17)),
                .y = -15.0 + @as(f32, @floatFromInt(index % 11)),
            },
            .speed = 1,
        });
    }

    return data;
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var data = try createFixture(allocator, item_count);
    defer data.deinit();

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .min_parallel_items = 1,
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();

    var system = MovementSystem.init();

    for (0..options.warmup_iterations) |_| {
        _ = runOnce(&system, &data, if (threads) |*thread_system| thread_system else null, case);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!system.adaptive_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = runOnce(&system, &data, if (threads) |*thread_system| thread_system else null, case);
        }
    }

    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const batch = runOnce(&system, &data, if (threads) |*thread_system| thread_system else null, case);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), batch);
    }

    var stats = accumulator.finish();
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.adaptive_tuner.report());
    }
    return stats;
}

fn runOnce(
    system: *MovementSystem,
    data: *DataSystem,
    thread_system: ?*ThreadSystem,
    case: suite.BenchmarkCase,
) thread_mod.BatchStats {
    var slice = data.movementBodySlice();
    if (!case.usesThreadSystem()) {
        movement.updateSerial(&slice, delta_seconds);
        return suite.serialBatch(data.movementBodySliceConst().entities.len, data_mod.movement_range_alignment_items);
    }

    const stats = system.update(&slice, thread_system.?, delta_seconds, .{
        .min_parallel_items = 1,
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
    return stats.batch;
}

fn benchmarkItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(data_mod.movement_range_alignment_items) orelse
        suite.alignItemCount(suite.default_items_per_range, data_mod.movement_range_alignment_items);
}

test "movement benchmark fixture creates requested movement bodies" {
    var data = try createFixture(std.testing.allocator, 32);
    defer data.deinit();

    try std.testing.expectEqual(@as(usize, 32), data.movementBodySliceConst().entities.len);
}

test "movement benchmark tiny serial case runs without display" {
    var options = suite.Options{
        .warmup_iterations = 1,
        .iterations = 1,
    };
    options.profile = .quick;
    const stats = try runCase(std.testing.allocator, std.testing.io, options, suite.default_cases[0], 1_024);
    try std.testing.expectEqual(suite.RunStatus.measured, stats.status);
    try std.testing.expect(stats.batch.ran_inline);
}

test "movement benchmark fixed cases use explicit range controls" {
    try std.testing.expectEqual(
        suite.alignItemCount(suite.default_items_per_range, data_mod.movement_range_alignment_items),
        benchmarkItemsPerRange(suite.default_cases[3]).?,
    );
    try std.testing.expectEqual(suite.default_cases[4].itemsPerRange(data_mod.movement_range_alignment_items).?, benchmarkItemsPerRange(suite.default_cases[4]).?);
    try std.testing.expectEqual(suite.default_cases[5].itemsPerRange(data_mod.movement_range_alignment_items).?, benchmarkItemsPerRange(suite.default_cases[5]).?);
    try std.testing.expectEqual(@as(?usize, null), benchmarkItemsPerRange(suite.default_cases[6]));
}

test "movement benchmark profiles sweep multiple entity counts" {
    try std.testing.expectEqual(@as(usize, 4), defaultItemCounts(.quick).len);
    try std.testing.expectEqual(@as(usize, 1_024), defaultItemCounts(.quick)[0]);
    try std.testing.expectEqual(@as(usize, 65_536), defaultItemCounts(.quick)[3]);
}
