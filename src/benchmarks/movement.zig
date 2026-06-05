// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const thread_mod = @import("../app/thread_system.zig");
const ThreadSystem = thread_mod.ThreadSystem;
const AdaptiveGrainTuner = thread_mod.AdaptiveGrainTuner;
const data_mod = @import("../game/data_system.zig");
const DataSystem = data_mod.DataSystem;
const MovementSystem = @import("../game/systems/movement.zig");
const suite = @import("suite.zig");

const delta_seconds: f32 = 1.0 / 60.0;
const benchmark_tuner_settle_warmup_cap: usize = 64;

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
            .grain_size = suite.default_grain_size,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();

    var grain_tuner: ?AdaptiveGrainTuner = if (case.tuned_grain)
        AdaptiveGrainTuner.init(benchmarkTunerConfig(data_mod.movement_range_alignment_items))
    else
        null;

    for (0..options.warmup_iterations) |_| {
        _ = runOnce(&data, if (threads) |*thread_system| thread_system else null, case, if (grain_tuner) |*tuner| tuner else null);
    }
    var settled_before_measurement = false;
    if (grain_tuner) |*tuner| {
        var extra_warmup: usize = 0;
        while (!tuner.isSettled() and extra_warmup < benchmark_tuner_settle_warmup_cap) : (extra_warmup += 1) {
            _ = runOnce(&data, if (threads) |*thread_system| thread_system else null, case, tuner);
        }
        settled_before_measurement = tuner.isSettled();
    }

    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const batch = runOnce(&data, if (threads) |*thread_system| thread_system else null, case, if (grain_tuner) |*tuner| tuner else null);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), batch);
    }

    var stats = accumulator.finish();
    if (grain_tuner) |*tuner| {
        var summary = suite.grainTuningSummary(tuner.report());
        summary.settled_before_measurement = settled_before_measurement;
        stats.grain_tuning = summary;
    }
    return stats;
}

fn runOnce(data: *DataSystem, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase, grain_tuner: ?*AdaptiveGrainTuner) thread_mod.BatchStats {
    if (!case.usesThreadSystem()) {
        MovementSystem.updateSerial(data, delta_seconds);
        return suite.serialBatch(data.movementBodySliceConst().entities.len, data_mod.movement_range_alignment_items);
    }

    const stats = MovementSystem.update(data, thread_system.?, delta_seconds, .{
        .min_parallel_items = 1,
        .grain_size = case.grainSize(data_mod.movement_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
        .grain_tuner = grain_tuner,
    });
    return stats.batch;
}

fn benchmarkTunerConfig(range_alignment_items: usize) thread_mod.AdaptiveGrainTunerConfig {
    return .{
        .initial_grain_size = suite.default_grain_size,
        .min_grain_size = range_alignment_items,
        .max_grain_size = suite.default_grain_size * 64,
        .sample_window = 2,
        .improvement_threshold_percent = 5,
        .settle_after_failed_probes = 2,
        .retune_after_settled_windows = 10_000,
    };
}

test "movement benchmark fixture creates requested movement bodies" {
    var data = try createFixture(std.testing.allocator, 32);
    defer data.deinit();

    try std.testing.expectEqual(@as(usize, 32), data.movementBodySliceConst().entities.len);
}

test "movement benchmark tiny inline case runs without display" {
    var options = suite.Options{
        .warmup_iterations = 1,
        .iterations = 1,
    };
    options.profile = .quick;
    const stats = try runCase(std.testing.allocator, std.testing.io, options, suite.default_cases[1], 1_024);
    try std.testing.expectEqual(suite.RunStatus.measured, stats.status);
    try std.testing.expect(stats.batch.ran_inline);
}

test "movement benchmark profiles sweep multiple entity counts" {
    try std.testing.expectEqual(@as(usize, 4), defaultItemCounts(.quick).len);
    try std.testing.expectEqual(@as(usize, 1_024), defaultItemCounts(.quick)[0]);
    try std.testing.expectEqual(@as(usize, 65_536), defaultItemCounts(.quick)[3]);
}
