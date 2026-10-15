// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const Dispatch = @import("../app/thread_system.zig").Dispatch;
const ParallelRange = @import("../app/thread_system.zig").ParallelRange;
const StageControls = @import("../app/thread_system.zig").StageControls;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../app/thread_system.zig").WorkerId;
const inlineBatch = @import("../app/thread_system.zig").inlineBatch;
const rangeCount = @import("../app/thread_system.zig").rangeCount;
const thread_shared_record_alignment = @import("../app/thread_system.zig").thread_shared_record_alignment;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

// `thread-dispatch`: one stage dispatch, `Dispatch.select` then `Dispatch.run`, over a
// trivial job that increments each item of its own range once, so a sample times what a
// stage pays per call (selection, range claims, worker wake and join, tuner bookkeeping)
// with as little job as possible. Items are one counter each in a line-aligned column;
// ranges align to whole cache lines, so no two ranges share a writable line.
// `serial-direct` runs the job once over every item with no thread system (the job's own
// cost); fixed cases pin range size and worker cap; `thread-adaptive-fixed-range` runs the
// suite's fixed-range tuner and `thread-adaptive-tuned-range` the thread system's shared
// tuner. Ladder: 1, 16, 256, and 4,096 ranges at the default range size. Cost model: a
// threaded batch costs O(ranges) claims plus O(workers) wakes plus the job, independent of
// world size and population. At the top rung the column (1 MiB) spreads across cores'
// caches, so its per-range time includes moving job data between cores; a before/after
// has the same data placement on both sides, so its delta still isolates dispatch.
// Asserts check every threaded batch's shape (range count from its range size, inline
// exactly when no worker is active, active workers at most min(workers, ranges - 1), every
// range claimed once), fixed cases' exact shape, each job's range index against the
// selected range count, and that every item was incremented once per dispatch.
// `--details` prints the shape (`inline` or workers/ranges), the time per item, and the
// time per range.
pub const group = suite.BenchmarkGroup{
    .name = "thread-dispatch",
    .item_label = "items",
    .defaultItemCounts = itemCounts,
    .runCase = runCase,
    .write_workload = writeWorkload,
};

const Item = u32;
const range_alignment_items = thread_shared_record_alignment / @sizeOf(Item);
const item_counts = [_]usize{ 64, 1_024, 16_384, 262_144 };

fn itemCounts(_: suite.Profile) []const usize {
    return &item_counts;
}

const DispatchContext = struct {
    items: []Item,
    // The selected batch's range count; `range.index` stays under it.
    range_count: usize,
};

// Scalar on purpose: the job is the fixture, kept trivial; SIMD would only shrink its term.
fn incrementJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *DispatchContext = @ptrCast(@alignCast(context));
    std.debug.assert(range.start <= range.end and range.end <= job.items.len);
    std.debug.assert(range.index < job.range_count);
    for (job.items[range.start..range.end]) |*item| item.* += 1;
}

fn dispatchOnce(
    context: *DispatchContext,
    thread_system: ?*ThreadSystem,
    fixed_tuner: *?AdaptiveWorkTuner,
    case: suite.BenchmarkCase,
) BatchStats {
    const item_count = context.items.len;
    const threads = thread_system orelse {
        context.range_count = 1;
        incrementJob(context, .{ .start = 0, .end = item_count }, WorkerId.main);
        return inlineBatch(item_count, range_alignment_items);
    };
    // A fixed case never consults its tuner; adaptive cases without a fixed-range tuner
    // run the thread system's shared one.
    const tuner: *AdaptiveWorkTuner = if (fixed_tuner.*) |*owned| owned else &threads.adaptive_tuner;
    const controls: StageControls = if (case.adaptive) .{} else .{
        .items_per_range = case.fixedItemsPerRange(range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = false,
    };
    const dispatch = Dispatch.init(threads, tuner, controls);
    const selection = dispatch.select(item_count, range_alignment_items);
    context.range_count = selection.range_count;
    return dispatch.run(selection, item_count, range_alignment_items, context, incrementJob);
}

fn tunerSettled(thread_system: *const ThreadSystem, fixed_tuner: *const ?AdaptiveWorkTuner) bool {
    if (fixed_tuner.*) |*tuner| return tuner.isSettled();
    return thread_system.adaptive_tuner.isSettled();
}

// The shape every threaded batch must have, whoever chose it.
fn assertThreadedShape(batch: BatchStats, thread_system: *const ThreadSystem) void {
    std.debug.assert(batch.range_count == rangeCount(batch.item_count, batch.items_per_range));
    std.debug.assert(batch.ran_inline == (batch.active_worker_threads == 0));
    std.debug.assert(batch.active_worker_threads <= @min(thread_system.workerThreadCount(), batch.range_count -| 1));
}

// The shape a fixed case's dispatch must have; checked against every measured batch.
fn assertFixedShape(batch: BatchStats, thread_system: *const ThreadSystem, case: suite.BenchmarkCase) void {
    const items_per_range = case.fixedItemsPerRange(range_alignment_items);
    const ranges = rangeCount(batch.item_count, items_per_range);
    const worker_cap = @min(case.maxWorkerThreads() orelse thread_system.workerThreadCount(), thread_system.workerThreadCount());
    std.debug.assert(batch.items_per_range == items_per_range);
    std.debug.assert(batch.range_count == ranges);
    if (ranges <= 1 or worker_cap == 0) {
        std.debug.assert(batch.ran_inline and batch.active_worker_threads == 0);
    } else {
        std.debug.assert(!batch.ran_inline);
        std.debug.assert(batch.active_worker_threads == @min(worker_cap, ranges - 1));
    }
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;

    const items = try allocator.alignedAlloc(Item, .fromByteUnits(thread_shared_record_alignment), item_count);
    defer allocator.free(items);
    @memset(items, 0);
    var context = DispatchContext{ .items = items, .range_count = 0 };
    var fixed_tuner = suite.adaptiveTunerForCase(case, range_alignment_items);

    var dispatches: usize = 0;
    for (0..options.warmup_iterations) |_| {
        _ = dispatchOnce(&context, thread_ptr, &fixed_tuner, case);
        dispatches += 1;
    }
    if (case.adaptive) {
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        var settle_guard: usize = 0;
        while (!tunerSettled(thread_ptr.?, &fixed_tuner) and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = dispatchOnce(&context, thread_ptr, &fixed_tuner, case);
            dispatches += 1;
        }
    }
    const settled_before_measurement = case.adaptive and tunerSettled(thread_ptr.?, &fixed_tuner);

    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const batch = dispatchOnce(&context, thread_ptr, &fixed_tuner, case);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        dispatches += 1;
        std.debug.assert(batch.item_count == item_count);
        std.debug.assert(batch.main_thread_ranges + batch.worker_thread_ranges == batch.range_count);
        if (thread_ptr) |thread_system| {
            assertThreadedShape(batch, thread_system);
            if (!case.adaptive) assertFixedShape(batch, thread_system, case);
        }
        accumulator.record(elapsed_ns, batch);
    }

    for (items) |item| std.debug.assert(item == dispatches);
    var stats = accumulator.finish();
    stats.output_count = item_count;
    if (case.adaptive) {
        const report = if (fixed_tuner) |*tuner| tuner.report() else thread_ptr.?.adaptive_tuner.report();
        stats.work_tuning = suite.workTuningSummary(report, settled_before_measurement);
    }
    return stats;
}

// `ns` divided by `count`, in ns to two decimals.
fn writeNsPer(writer: *std.Io.Writer, label: []const u8, ns: u64, count: usize) std.Io.Writer.Error!void {
    const hundredths: u64 = if (count == 0) 0 else std.math.lossyCast(u64, @as(u128, ns) * 100 / count);
    try writer.print(" {s}={}.{d:0>2} ns", .{ label, hundredths / 100, hundredths % 100 });
}

fn writeWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    if (view == .details) {
        try writer.writeAll("shape=");
        try suite.writeStageShape(writer, stats.batch);
    } else {
        try writer.print("items={}", .{stats.output_count});
    }
    try writeNsPer(writer, "per_item", stats.mean_ns, stats.item_count);
    try writeNsPer(writer, "per_range", stats.mean_ns, stats.batch.range_count);
}
