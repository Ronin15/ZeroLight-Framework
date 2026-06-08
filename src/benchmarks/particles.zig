// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const thread_mod = @import("../app/thread_system.zig");
const ThreadSystem = thread_mod.ThreadSystem;
const math = @import("../core/math.zig");
const particle_mod = @import("../game/systems/particle.zig");
const ParticleSystem = particle_mod.ParticleSystem;
const suite = @import("suite.zig");

const delta_seconds: f32 = 1.0 / 60.0;

pub const group = suite.BenchmarkGroup{
    .name = "particles",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
};

const quick_counts = [_]usize{16_384};
const standard_counts = [_]usize{65_536};
const stress_counts = [_]usize{262_144};

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &quick_counts,
        .standard => &standard_counts,
        .stress => &stress_counts,
    };
}

pub fn createFixture(allocator: std.mem.Allocator, count: usize) !ParticleSystem {
    var particles = try ParticleSystem.init(allocator, .{ .capacity = count });
    errdefer particles.deinit();

    for (0..count) |index| {
        const base: f32 = @floatFromInt(index);
        const emitted = particles.emit(.{
            .position = .{
                .x = base * 0.1,
                .y = base * -0.075,
            },
            .velocity = .{
                .x = 6.0 + @as(f32, @floatFromInt(index % 23)),
                .y = -4.0 + @as(f32, @floatFromInt(index % 19)),
            },
            .acceleration = .{
                .x = 0.15,
                .y = -0.35,
            },
            .lifetime = 1_000_000,
            .start_size = 5,
            .end_size = 1,
            .start_color = .{ .r = 0.9, .g = 0.7, .b = 0.2, .a = 1 },
            .end_color = .{ .r = 0.3, .g = 0.5, .b = 1, .a = 0 },
            .layer = @intCast(index % 4),
        });
        std.debug.assert(emitted);
    }

    return particles;
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var particles = try createFixture(allocator, item_count);
    defer particles.deinit();

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .min_parallel_items = 1,
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();

    for (0..options.warmup_iterations) |_| {
        _ = runOnce(&particles, if (threads) |*thread_system| thread_system else null, case);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!particles.adaptive_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = runOnce(&particles, if (threads) |*thread_system| thread_system else null, case);
        }
    }

    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const batch = runOnce(&particles, if (threads) |*thread_system| thread_system else null, case);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), batch);
    }

    var stats = accumulator.finish();
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(particles.adaptive_tuner.report());
    }
    return stats;
}

fn runOnce(particles: *ParticleSystem, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase) thread_mod.BatchStats {
    if (!case.usesThreadSystem()) {
        return particles.updateSerial(delta_seconds).batch;
    }

    return particles.update(thread_system.?, delta_seconds, .{
        .min_parallel_items = 1,
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    }).batch;
}

fn benchmarkItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(particle_mod.particle_range_alignment_items) orelse
        suite.alignItemCount(suite.default_items_per_range, particle_mod.particle_range_alignment_items);
}

test "particle benchmark fixture creates requested active particles" {
    var particles = try createFixture(std.testing.allocator, 32);
    defer particles.deinit();

    try std.testing.expectEqual(@as(usize, 32), particles.activeCount());
}

test "particle benchmark tiny serial case runs without display" {
    const options = suite.Options{
        .warmup_iterations = 1,
        .iterations = 1,
    };
    const stats = try runCase(std.testing.allocator, std.testing.io, options, suite.default_cases[0], 16_384);
    try std.testing.expectEqual(suite.RunStatus.measured, stats.status);
    try std.testing.expect(stats.batch.ran_inline);
}

test "particle benchmark fixed cases use explicit range controls" {
    try std.testing.expectEqual(
        suite.alignItemCount(suite.default_items_per_range, particle_mod.particle_range_alignment_items),
        benchmarkItemsPerRange(suite.default_cases[3]).?,
    );
    try std.testing.expectEqual(suite.default_cases[4].itemsPerRange(particle_mod.particle_range_alignment_items).?, benchmarkItemsPerRange(suite.default_cases[4]).?);
    try std.testing.expectEqual(suite.default_cases[5].itemsPerRange(particle_mod.particle_range_alignment_items).?, benchmarkItemsPerRange(suite.default_cases[5]).?);
    try std.testing.expectEqual(@as(?usize, null), benchmarkItemsPerRange(suite.default_cases[6]));
}

test "particle benchmark fixture keeps long-lived particles active after update" {
    var particles = try createFixture(std.testing.allocator, 8);
    defer particles.deinit();

    _ = particles.updateSerial(10);
    try std.testing.expectEqual(@as(usize, 8), particles.activeCount());
    const slice = particles.sliceConst();
    try std.testing.expect(math.clamp(slice.color_a[0], 0, 1) > 0.99);
}
