// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const inlineBatch = @import("../app/thread_system.zig").inlineBatch;
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
// with no reset between iterations. Prints no workload fields. Pass shape: time linear in
// bodies; asserts check each step covers every body.
pub const group = suite.BenchmarkGroup{
    .name = "movement",
    .item_label = "movement bodies",
    .item_counts = &suite.event_scale_counts,
    .runCase = runCase,
    .write_workload = suite.writeNoWorkload,
};

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

    var threads = try fixtures.initCaseThreads(allocator, io, case);
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
        std.debug.assert(batch.item_count == item_count);
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
        return inlineBatch(data.movementBodySliceConst().entities.len, movement_range_alignment_items);
    }

    const stats = system.update(&slice, thread_system.?, delta_seconds, .{
        .items_per_range = case.stageItemsPerRange(movement_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
    return stats.batch;
}

// `movement-apply-intents`: one AI movement intent per moving agent, written once in a
// scattered row order. Timed: one apply of the merged intents into velocity; apply is
// idempotent, so no reset runs between iterations. `--details` reports the applied
// intents, the apply shape, and the main-thread time (everything but a dispatched
// apply) and share. `movement-apply-intents-sorted` is the same stream in row order, so
// each range writes one contiguous row window: the scattered group's control for worker
// ranges writing rows scattered across the velocity columns.
pub const apply_intents_group = suite.BenchmarkGroup{
    .name = "movement-apply-intents",
    .item_label = "moving agents",
    .item_counts = &apply_intents_item_counts,
    .runCase = runApplyIntentsScatteredCase,
    .write_workload = writeApplyWorkload,
};

pub const apply_intents_sorted_group = suite.BenchmarkGroup{
    .name = "movement-apply-intents-sorted",
    .item_label = "moving agents",
    .item_counts = &apply_intents_item_counts,
    .runCase = runApplyIntentsSortedCase,
    .write_workload = writeApplyWorkload,
};

// The intent stream's row order.
const IntentOrder = enum { scattered, sorted };

const apply_intents_item_counts = [_]usize{ 1_024, 4_096, 16_384 };
// Every this-many agents has speed 0, so the apply takes its default-speed path.
const zero_speed_every: usize = 5;
// First stride tried for the scattered intent order; stepped until coprime with the agent
// count so the order visits every row once.
const scatter_stride_seed: usize = 7_919;
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
// on movement row `index`; one movement intent each, in `index * stride mod count` order
// when scattered, else in row order.
fn buildApplyIntentsFixture(allocator: std.mem.Allocator, count: usize, order_kind: IntentOrder) !ApplyIntentsFixture {
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
    const stride: usize = switch (order_kind) {
        .scattered => fixtures.coprimeStride(scatter_stride_seed, count),
        .sorted => 1,
    };
    for (0..count) |order| {
        const row = order * stride % count;
        const direction = agentDirection(row);
        writer.write(.{ .movement = .{ .entity = entities[row], .direction_x = direction[0], .direction_y = direction[1] } });
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
    thread_system: ?*ThreadSystem,
    case: suite.BenchmarkCase,
) BatchStats {
    if (!case.usesThreadSystem()) {
        movement.applyIntentsSerial(&fixture.data, &fixture.frame);
        return inlineBatch(fixture.frame.intents.mergedItems().len, movement_range_alignment_items);
    }
    const stats = system.applyIntents(&fixture.data, &fixture.frame, thread_system.?, .{
        .items_per_range = case.stageItemsPerRange(movement_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
    return stats.batch;
}

fn runApplyIntentsScatteredCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runApplyIntentsCase(allocator, io, options, case, item_count, .scattered);
}

fn runApplyIntentsSortedCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runApplyIntentsCase(allocator, io, options, case, item_count, .sorted);
}

fn runApplyIntentsCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, order_kind: IntentOrder) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;

    var fixture = try buildApplyIntentsFixture(allocator, item_count, order_kind);
    defer fixture.deinit();
    var system = MovementSystem.init();
    if (suite.adaptiveTunerForCase(case, movement_range_alignment_items)) |tuner| {
        system.apply_intents_tuner = tuner;
    }

    // A fixed threaded case with more than one range of intents dispatches the apply.
    const expect_dispatch = if (thread_ptr) |thread_system|
        !case.adaptive and thread_system.workerThreadCount() > 0 and item_count > case.fixedItemsPerRange(movement_range_alignment_items)
    else
        false;

    for (0..@max(@as(usize, 1), options.warmup_iterations)) |_| {
        _ = applyIntentsOnce(&system, &fixture, thread_ptr, case);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!system.apply_intents_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = applyIntentsOnce(&system, &fixture, thread_ptr, case);
        }
    }
    const settled_before_measurement = if (case.adaptive) system.apply_intents_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const batch = applyIntentsOnce(&system, &fixture, thread_ptr, case);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        std.debug.assert(batch.item_count == item_count);
        std.debug.assert(!expect_dispatch or (batch.range_count > 1 and !batch.ran_inline));
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
        stats.work_tuning = suite.workTuningSummary(system.apply_intents_tuner.report(), settled_before_measurement);
    }
    return stats;
}

fn writeApplyWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("intents={}", .{stats.output_count});
    if (view == .summary) return;
    try writer.writeAll(" apply=");
    try suite.writeStageShape(writer, stats.batch);
    try suite.writeShare(writer, "main", stats.main_ns orelse 0, stats.mean_ns);
}
