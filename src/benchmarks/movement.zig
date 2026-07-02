// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const movement_range_alignment_items = @import("../game/data_system.zig").movement_range_alignment_items;
const movement = @import("../game/systems/movement.zig");
const MovementSystem = @import("../game/systems/movement.zig").MovementSystem;
const suite = @import("suite.zig");

const delta_seconds: f32 = 1.0 / 60.0;

pub const group = suite.BenchmarkGroup{
    .name = "movement",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
};

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return suite.eventScaleCounts(profile);
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
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();

    var system = MovementSystem.init();
    if (suite.adaptiveTunerForCase(case, movement_range_alignment_items)) |tuner| {
        system.adaptive_tuner = tuner;
    }

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
    const settled_before_measurement = if (case.adaptive) system.adaptive_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const batch = runOnce(&system, &data, if (threads) |*thread_system| thread_system else null, case);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), batch);
    }

    var stats = accumulator.finish();
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.adaptive_tuner.report(), settled_before_measurement);
    }
    return stats;
}

fn runOnce(
    system: *MovementSystem,
    data: *DataSystem,
    thread_system: ?*ThreadSystem,
    case: suite.BenchmarkCase,
) BatchStats {
    var slice = data.movementBodySlice();
    if (!case.usesThreadSystem()) {
        movement.updateSerial(&slice, delta_seconds);
        return suite.serialBatch(data.movementBodySliceConst().entities.len, movement_range_alignment_items);
    }

    const stats = system.update(&slice, thread_system.?, delta_seconds, .{
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
    return stats.batch;
}

fn benchmarkItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(movement_range_alignment_items) orelse
        suite.alignItemCount(suite.default_items_per_range, movement_range_alignment_items);
}
