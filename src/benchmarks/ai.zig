// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const math = @import("../core/math.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const AiStats = @import("../game/systems/ai.zig").AiStats;
const AiSystem = @import("../game/systems/ai.zig").AiSystem;
const ai_range_alignment_items = @import("../game/systems/ai.zig").ai_range_alignment_items;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const suite = @import("suite.zig");

const delta_seconds: f32 = 1.0 / 60.0;
const intent_seed: u64 = 0x0a17_b0a7;

pub const group = suite.BenchmarkGroup{
    .name = "ai",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
};

const Fixture = struct {
    data: DataSystem,
    frame: SimulationFrame,

    fn deinit(self: *Fixture) void {
        self.frame.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return suite.eventScaleCounts(profile);
}

pub fn createFixture(allocator: std.mem.Allocator, count: usize) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    var frame = SimulationFrame.init(allocator);
    errdefer frame.deinit();
    try frame.reserveStreams(rangeCount(count, ai_range_alignment_items), 0, count, 0, 0, 0);

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
            .behavior = if (index % 3 == 0) .wander else .seek,
            .wander_amplitude = 6.0 + @as(f32, @floatFromInt(index % 29)),
            .seek_weight = if (index % 3 == 0) 0.0 else 0.4 + @as(f32, @floatFromInt(index % 7)) * 0.1,
        });
    }

    return .{ .data = data, .frame = frame };
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try createFixture(allocator, item_count);
    defer fixture.deinit();
    var system = AiSystem.init(allocator);
    defer system.deinit();
    if (suite.adaptiveTunerForCase(case, ai_range_alignment_items)) |tuner| {
        system.separation_tuner = tuner;
        system.intent_tuner = suite.adaptiveTunerForCase(case, ai_range_alignment_items).?;
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
        while ((!system.separation_tuner.isSettled() or !system.intent_tuner.isSettled()) and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case);
        }
    }
    const separation_settled_before_measurement = if (case.adaptive) system.separation_tuner.isSettled() else false;
    const intent_settled_before_measurement = if (case.adaptive) system.intent_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_ai_stats = AiStats{};
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_ai_stats = try runOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_ai_stats.separation_batch);
    }

    var stats = accumulator.finish();
    stats.candidate_pairs = last_ai_stats.separation_candidate_checks;
    stats.output_count = last_ai_stats.intent_count;
    stats.secondary_batch = suite.batchSummaryFromBatch(last_ai_stats.intent_batch);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.separation_tuner.report(), separation_settled_before_measurement);
        stats.secondary_work_tuning = suite.workTuningSummary(system.intent_tuner.report(), intent_settled_before_measurement);
    }
    return stats;
}

fn runOnce(system: *AiSystem, fixture: *Fixture, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase) !AiStats {
    fixture.frame.beginStep();
    const ai_slice = fixture.data.aiAgentSliceConst();
    const movement_slice = fixture.data.movementBodySliceConst();
    if (!case.usesThreadSystem()) {
        return try system.updateSerial(ai_slice, movement_slice, &fixture.data, &fixture.frame, delta_seconds, .{
            .intent_seed = intent_seed,
            .seek_target = benchmarkSeekTarget(),
        });
    }

    return try system.update(ai_slice, movement_slice, &fixture.data, &fixture.frame, thread_system.?, delta_seconds, .{
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
        .intent_seed = intent_seed,
        .seek_target = benchmarkSeekTarget(),
    });
}

fn benchmarkItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(ai_range_alignment_items) orelse
        suite.alignItemCount(suite.default_items_per_range, ai_range_alignment_items);
}

fn benchmarkSeekTarget() math.Vec2 {
    return .{ .x = 480, .y = 270 };
}

fn rangeCount(item_count: usize, items_per_range: usize) usize {
    return (item_count + items_per_range - 1) / items_per_range;
}

test "ai benchmark fixture creates requested agents and movement bodies" {
    var fixture = try createFixture(std.testing.allocator, 32);
    defer fixture.deinit();

    try std.testing.expectEqual(@as(usize, 32), fixture.data.aiAgentSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 32), fixture.data.movementBodySliceConst().entities.len);
}

test "ai benchmark tiny serial case runs without display" {
    const options = suite.Options{
        .warmup_iterations = 1,
        .iterations = 1,
    };
    const stats = try runCase(std.testing.allocator, std.testing.io, options, suite.default_cases[0], 256);
    try std.testing.expectEqual(suite.RunStatus.measured, stats.status);
    try std.testing.expect(stats.batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 256), stats.output_count);
}

test "ai benchmark fixed cases use explicit range controls" {
    try std.testing.expectEqual(
        suite.alignItemCount(suite.default_items_per_range, ai_range_alignment_items),
        benchmarkItemsPerRange(suite.default_cases[3]).?,
    );
    try std.testing.expectEqual(suite.default_cases[4].itemsPerRange(ai_range_alignment_items).?, benchmarkItemsPerRange(suite.default_cases[4]).?);
    try std.testing.expectEqual(suite.default_cases[5].itemsPerRange(ai_range_alignment_items).?, benchmarkItemsPerRange(suite.default_cases[5]).?);
    try std.testing.expectEqual(@as(?usize, null), benchmarkItemsPerRange(suite.default_cases[6]));
    try std.testing.expectEqual(@as(?usize, null), benchmarkItemsPerRange(suite.default_cases[7]));
}

test "ai benchmark profiles keep bounded separation workload cases" {
    try std.testing.expectEqualSlices(usize, suite.eventScaleCounts(.quick), defaultItemCounts(.quick));
    try std.testing.expectEqualSlices(usize, suite.eventScaleCounts(.standard), defaultItemCounts(.standard));
    try std.testing.expectEqualSlices(usize, suite.eventScaleCounts(.stress), defaultItemCounts(.stress));
}
