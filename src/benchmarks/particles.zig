// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const math = @import("../core/math.zig");
const particle_range_alignment_items = @import("../game/systems/particle.zig").particle_range_alignment_items;
const ParticleSystem = @import("../game/systems/particle.zig").ParticleSystem;
const WorldDepth = @import("../game/render_depth.zig").WorldDepth;
const suite = @import("suite.zig");

const delta_seconds: f32 = 1.0 / 60.0;
const benchmark_particle_depths = [_]WorldDepth{ .actor, .effect, .marker };

pub const group = suite.BenchmarkGroup{
    .name = "particles",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
};

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return suite.eventScaleCounts(profile);
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
            .depth = benchmark_particle_depths[index % benchmark_particle_depths.len],
        });
        std.debug.assert(emitted);
    }

    return particles;
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var particles = try createFixture(allocator, item_count);
    defer particles.deinit();
    if (suite.adaptiveTunerForCase(case, particle_range_alignment_items)) |tuner| {
        particles.adaptive_tuner = tuner;
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
        _ = runOnce(&particles, if (threads) |*thread_system| thread_system else null, case);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!particles.adaptive_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = runOnce(&particles, if (threads) |*thread_system| thread_system else null, case);
        }
    }
    const settled_before_measurement = if (case.adaptive) particles.adaptive_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const batch = runOnce(&particles, if (threads) |*thread_system| thread_system else null, case);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), batch);
    }

    var stats = accumulator.finish();
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(particles.adaptive_tuner.report(), settled_before_measurement);
    }
    return stats;
}

fn runOnce(particles: *ParticleSystem, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase) BatchStats {
    if (!case.usesThreadSystem()) {
        return particles.updateSerial(delta_seconds).batch;
    }

    return particles.update(thread_system.?, delta_seconds, .{
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    }).batch;
}

fn benchmarkItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(particle_range_alignment_items) orelse
        suite.alignItemCount(suite.default_items_per_range, particle_range_alignment_items);
}
