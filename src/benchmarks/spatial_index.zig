// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared spatial index (Slice 28) build throughput: times only
//! `SpatialIndexSystem.build`/`buildSerial` in isolation, answering "index
//! build allocation-free, no regression" separately from the `ai` group (which
//! now excludes the build from its own timed window — see
//! `src/benchmarks/ai.zig`).

const std = @import("std");
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const math = @import("../core/math.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const SpatialIndexStats = @import("../game/systems/spatial_index.zig").SpatialIndexStats;
const SpatialIndexSystem = @import("../game/systems/spatial_index.zig").SpatialIndexSystem;
const spatial_index_range_alignment_items = @import("../game/systems/spatial_index.zig").spatial_index_range_alignment_items;
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "spatial_index",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
};

const Fixture = struct {
    data: DataSystem,

    fn deinit(self: *Fixture) void {
        self.data.deinit();
    }
};

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return suite.eventScaleCounts(profile);
}

pub fn createFixture(allocator: std.mem.Allocator, count: usize) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    for (0..count) |index| {
        const entity = try data.createEntity();
        const position = math.Vec2{
            .x = @as(f32, @floatFromInt(index % 128)) * 11.0,
            .y = @as(f32, @floatFromInt(index / 128)) * 9.0,
        };
        try data.setMovementBody(entity, .{
            .position = position,
            .previous_position = position,
            .velocity = .{},
            .speed = 35.0 + @as(f32, @floatFromInt(index % 17)),
        });
        try data.setAiAgent(entity, .{
            .active_behavior = if (index % 3 == 0) .wander else .pursue,
            .wander_amplitude = 6.0 + @as(f32, @floatFromInt(index % 29)),
            .gain_pursue = if (index % 3 == 0) 0.0 else 0.4 + @as(f32, @floatFromInt(index % 7)) * 0.1,
        });
    }

    return .{ .data = data };
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try createFixture(allocator, item_count);
    defer fixture.deinit();
    var system = SpatialIndexSystem.init(allocator);
    defer system.deinit();
    try system.reserve(item_count);
    if (suite.adaptiveTunerForCase(case, spatial_index_range_alignment_items)) |tuner| {
        system.build_tuner = tuner;
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
        while (!system.build_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case);
        }
    }
    const settled_before_measurement = if (case.adaptive) system.build_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = SpatialIndexStats{};
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_stats = try runOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.batch);
    }

    var stats = accumulator.finish();
    stats.output_count = last_stats.entity_count;
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.build_tuner.report(), settled_before_measurement);
    }
    return stats;
}

fn runOnce(system: *SpatialIndexSystem, fixture: *Fixture, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase) !SpatialIndexStats {
    const ai_slice = fixture.data.aiAgentSliceConst();
    const movement_slice = fixture.data.movementBodySliceConst();
    if (!case.usesThreadSystem()) {
        return try system.buildSerial(ai_slice, movement_slice, &fixture.data, .{});
    }

    return try system.build(ai_slice, movement_slice, &fixture.data, thread_system.?, .{
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

fn benchmarkItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(spatial_index_range_alignment_items) orelse
        suite.alignItemCount(suite.default_items_per_range, spatial_index_range_alignment_items);
}
