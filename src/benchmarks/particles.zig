// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const particle_range_alignment_items = @import("../game/systems/particle.zig").particle_range_alignment_items;
const ParticleSystem = @import("../game/systems/particle.zig").ParticleSystem;
const WorldDepth = @import("../game/render_depth.zig").WorldDepth;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

const delta_seconds: f32 = 1.0 / 60.0;
const benchmark_particle_depths = [_]WorldDepth{ .actor, .effect, .marker };

// `particles`: one `ParticleSystem` update over N particles across three render depths,
// each living past the run so every row stays live. `--details` prints `main=`, the time
// outside an update batch that ran on workers, and `main_per_item=`. Pass shape: time
// linear in rows and main per row flat; asserts check every row stays live and each step
// covers them all, and a fixed threaded case dispatches the update to workers.
pub const group = suite.BenchmarkGroup{
    .name = "particles",
    .item_label = "particle rows",
    .item_counts = &suite.event_scale_counts,
    .runCase = runCase,
    .write_workload = writeParticleWorkload,
};

fn createFixture(allocator: std.mem.Allocator, count: usize) !ParticleSystem {
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

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var particles = try createFixture(allocator, item_count);
    defer particles.deinit();
    if (suite.adaptiveTunerForCase(case, particle_range_alignment_items)) |tuner| {
        particles.adaptive_tuner = tuner;
    }

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();

    var warm = suite.Warmup.init(options, case, 0);
    while (warm.next(particles.adaptive_tuner.phase == .settled)) {
        _ = runOnce(&particles, &threads, case);
    }
    const settled_before_measurement = if (case.adaptive) (particles.adaptive_tuner.phase == .settled) else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const batch = runOnce(&particles, &threads, case);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        std.debug.assert(batch.item_count == item_count);
        try suite.checkStageDispatched(case, &threads, case.stageItemsPerRange(particle_range_alignment_items), batch);
        accumulator.record(elapsed_ns, batch);
        // Main is everything but an update batch that ran on workers.
        main_total += if (batch.ran_inline) elapsed_ns else elapsed_ns -| batch.batch_duration_ns;
    }
    std.debug.assert(particles.activeCount() == item_count);

    var stats = accumulator.finish();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(suite.tunerReport(&particles.adaptive_tuner), settled_before_measurement);
    }
    return stats;
}

fn runOnce(particles: *ParticleSystem, thread_system: *ThreadSystem, case: suite.BenchmarkCase) BatchStats {
    return particles.update(thread_system, delta_seconds, .{
        .items_per_range = case.stageItemsPerRange(particle_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    }).perf.batch;
}

fn writeParticleWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    if (view == .summary) return;
    try suite.writeMainShare(writer, stats, stats.item_count);
}
