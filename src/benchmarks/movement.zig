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
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const SimulationIntent = @import("../game/simulation.zig").SimulationIntent;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

const delta_seconds: f32 = 1.0 / 60.0;

// `movement`: one `MovementSystem` update over N movement bodies with varied velocities,
// with no reset between iterations. `--details` prints `main=`, the time outside an
// integrate that ran on workers, and `main_per_item=`. Pass shape: time linear in bodies
// and main per body flat; asserts check each step covers every body, and a fixed threaded
// case dispatches the integrate to workers.
pub const group = suite.BenchmarkGroup{
    .name = "movement",
    .item_label = "movement bodies",
    .item_counts = &suite.event_scale_counts,
    .runCase = runCase,
    .write_workload = writeMovementWorkload,
};

fn createFixture(allocator: std.mem.Allocator, count: usize) !DataSystem {
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

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var data = try createFixture(allocator, item_count);
    defer data.deinit();

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();

    var system = MovementSystem.init();

    var warm = suite.Warmup.init(options, case, 0);
    while (warm.next(suite.tunerSettled(&system.adaptive_tuner))) {
        _ = runOnce(&system, &data, &threads, case);
    }
    const adaptive_tuner_start = suite.TunerStart.of(&system.adaptive_tuner, case);

    var accumulator = suite.StatsAccumulator.init(item_count);
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const batch = runOnce(&system, &data, &threads, case);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        std.debug.assert(batch.item_count == item_count);
        try suite.checkStageDispatched(case, &threads, case.stageItemsPerRange(movement_range_alignment_items), batch);
        accumulator.record(elapsed_ns, batch);
        // Main is everything but an integrate that ran on workers.
        main_total += if (batch.ran_inline) elapsed_ns else elapsed_ns -| batch.batch_duration_ns;
    }

    var stats = accumulator.finish();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(&system.adaptive_tuner, adaptive_tuner_start);
    }
    return stats;
}

fn runOnce(
    system: *MovementSystem,
    data: *DataSystem,
    thread_system: *ThreadSystem,
    case: suite.BenchmarkCase,
) BatchStats {
    var slice = data.movementBodySlice();

    const stats = system.update(&slice, thread_system, delta_seconds, .{
        .items_per_range = case.stageItemsPerRange(movement_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
        .batches_per_participant = case.stageBatchesPerParticipant(),
    });
    return stats.perf.batch;
}

fn writeMovementWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    if (view == .summary) return;
    try suite.writeMainShare(writer, stats, stats.item_count);
}

// `movement-apply-intents` and `movement-apply-intents-sorted`: one movement intent per
// moving agent, in movement-row order with `movement_row` set. The sorted group is the
// production shape's control; both fixtures are that order. Timed: one apply of the merged
// intents into velocity; apply is idempotent, so no reset runs between iterations.
// `--details` reports the applied intents, the apply shape, and the main-thread time
// (everything but a dispatched apply), share, and time per intent; a fixed threaded case
// with more than one range of intents dispatches the apply at one range per fixed range.
pub const apply_intents_group = suite.BenchmarkGroup{
    .name = "movement-apply-intents",
    .item_label = "moving agents",
    .item_counts = &apply_intents_item_counts,
    .runCase = runApplyIntentsCase,
    .write_workload = writeApplyWorkload,
};

pub const apply_intents_sorted_group = suite.BenchmarkGroup{
    .name = "movement-apply-intents-sorted",
    .item_label = "moving agents",
    .item_counts = &apply_intents_item_counts,
    .runCase = runApplyIntentsCase,
    .write_workload = writeApplyWorkload,
};

const apply_intents_item_counts = [_]usize{ 1_024, 4_096, 16_384 };
// Every this-many agents has speed 0, so the apply takes its default-speed path.
const zero_speed_every: usize = 5;
// The apply's speed for a row whose speed is not positive.
const default_intent_speed: f32 = 40.0;

const ApplyIntentsFixture = struct {
    data: DataSystem,
    frame: SimulationFrame,

    fn deinit(self: *ApplyIntentsFixture) void {
        self.frame.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

fn agentSpeed(index: usize) f32 {
    return if (index % zero_speed_every == 0) 0 else 10.0 + @as(f32, @floatFromInt(index % 13));
}

fn agentDirection(index: usize) [2]f32 {
    return .{
        (@as(f32, @floatFromInt(index % 7)) - 3.0) / 3.0,
        (@as(f32, @floatFromInt(index % 5)) - 2.0) / 2.0,
    };
}

// `count` agents with a movement body (zero velocity) and an AI agent, entity `index`
// on movement row `index`; one movement intent each, in row order, `movement_row` set.
fn buildApplyIntentsFixture(allocator: std.mem.Allocator, count: usize) !ApplyIntentsFixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    for (0..count) |index| {
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{ .speed = agentSpeed(index) });
        try data.setAiAgent(entity, .{});
    }
    const entities = data.movementBodySliceConst().entities;
    std.debug.assert(entities.len == count);

    var frame = SimulationFrame.init(allocator);
    errdefer frame.deinit();
    var writer = try fixtures.beginOneRange(SimulationIntent, &frame.intents, count);
    for (0..count) |row| {
        const direction = agentDirection(row);
        writer.write(.{ .movement = .{
            .entity = entities[row],
            .direction_x = direction[0],
            .direction_y = direction[1],
            .movement_row = @intCast(row),
        } });
    }
    writer.finish();
    frame.intents.finishWrite();
    std.debug.assert(frame.intents.mergedItems().len == count);

    return .{ .data = data, .frame = frame };
}

// Rows whose velocity is exactly their intent's direction times their effective speed.
fn countAppliedRows(data: *const DataSystem) usize {
    const slice = data.movementBodySliceConst();
    var applied: usize = 0;
    for (0..slice.entities.len) |row| {
        const direction = agentDirection(row);
        const speed = if (slice.speed[row] > 0) slice.speed[row] else default_intent_speed;
        if (slice.velocity_x[row] == direction[0] * speed and slice.velocity_y[row] == direction[1] * speed) applied += 1;
    }
    return applied;
}

fn applyIntentsOnce(
    system: *MovementSystem,
    fixture: *ApplyIntentsFixture,
    thread_system: *ThreadSystem,
    case: suite.BenchmarkCase,
) BatchStats {
    const stats = system.applyIntents(&fixture.data, &fixture.frame, thread_system, .{
        .items_per_range = case.stageItemsPerRange(movement_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
        .batches_per_participant = case.stageBatchesPerParticipant(),
    });
    return stats.perf.batch;
}

fn runApplyIntentsCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;

    var fixture = try buildApplyIntentsFixture(allocator, item_count);
    defer fixture.deinit();
    var system = MovementSystem.init();

    var warm = suite.Warmup.init(options, case, 1);
    while (warm.next(suite.tunerSettled(&system.apply_intents_tuner))) {
        _ = applyIntentsOnce(&system, &fixture, thread_ptr, case);
    }
    const apply_intents_tuner_start = suite.TunerStart.of(&system.apply_intents_tuner, case);

    var accumulator = suite.StatsAccumulator.init(item_count);
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const batch = applyIntentsOnce(&system, &fixture, thread_ptr, case);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        std.debug.assert(batch.item_count == item_count);
        // A fixed threaded case with more than one range of intents dispatches the apply, one
        // range per fixed range of intents.
        try suite.checkStageDispatched(case, thread_ptr, case.stageItemsPerRange(movement_range_alignment_items), batch);
        try suite.checkFixedRangeCount(case, thread_ptr, case.stageItemsPerRange(movement_range_alignment_items), batch);
        accumulator.record(elapsed_ns, batch);
        // Main is everything but an apply that ran on workers.
        main_total += if (batch.ran_inline) elapsed_ns else elapsed_ns -| batch.batch_duration_ns;
    }
    const applied = countAppliedRows(&fixture.data);
    std.debug.assert(applied == item_count);
    var stats = accumulator.finish();
    stats.output_count = applied;
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(&system.apply_intents_tuner, apply_intents_tuner_start);
    }
    return stats;
}

fn writeApplyWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("intents={}", .{stats.output_count});
    if (view == .summary) return;
    try writer.writeAll(" apply=");
    try suite.writeStageShape(writer, stats.batch);
    try suite.writeMainShare(writer, stats, stats.output_count);
}
