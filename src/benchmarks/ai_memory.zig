// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! AiMemorySystem throughput: one memory step per iteration, its four threaded stages
//! (translate think rows to memory rows, order the member rows ascending, decay, visibility)
//! plus the main thread's mark, compact, unmark, and event refresh. Every
//! `ai_memory_event_stride`th AI row (the think rows in `ai-memory-sparse`) gets a synthetic
//! perceived event each iteration, so the refreshes scale with the think set without the
//! injection dominating the window.
//! - `ai-memory`: every agent's memory, the think set in store order. Pass shape: time linear
//!   in agents; the tuned case within spread of the best control; main's time per processed
//!   row flat across sizes.
//! - `ai-memory-shuffled`: the same step over a stride shuffle of every agent, as a
//!   cell-major think set arrives. Pass shape: within spread of `ai-memory` at the same size,
//!   and threaded like it.
//! - `ai-memory-sparse`: a fixed think set of 256 rows, 4 in each of 64 row words spread
//!   evenly over a growing memory store, stride-shuffled, so every stage's items stay fixed.
//!   Pass shape: per-step time flat in memory rows.
//! Asserts check every think row carries memory, the translate, decay, and visibility stages
//! each run over the think set, and the order stage over its touched words.
//! Each prints `processed=` (memory rows stepped), `refreshed=`, and `main=` with
//! `main_per_item=` (per processed row); `--details` adds the `translate=`, `order=`, and
//! `visible=` stage shapes (the decay stage is the row's batch).

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const ConstAiAgentSlice = @import("../game/data_system.zig").ConstAiAgentSlice;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const AiMemoryStats = @import("../game/systems/ai_memory.zig").AiMemoryStats;
const AiMemorySystem = @import("../game/systems/ai_memory.zig").AiMemorySystem;
const ai_memory_order_range_alignment_items = @import("../game/systems/ai_memory.zig").ai_memory_order_range_alignment_items;
const ai_memory_range_alignment_items = @import("../game/systems/ai_memory.zig").ai_memory_range_alignment_items;
const word_bits = @import("../game/systems/ai_memory.zig").word_bits;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "ai-memory",
    .item_label = "AI agents",
    .item_counts = &suite.event_scale_counts,
    .runCase = runCase,
    .write_workload = writeMemoryWorkload,
};

pub const shuffled_group = suite.BenchmarkGroup{
    .name = "ai-memory-shuffled",
    .item_label = "AI agents",
    .item_counts = &suite.event_scale_counts,
    .runCase = runShuffledCase,
    .write_workload = writeMemoryWorkload,
};

pub const sparse_group = suite.BenchmarkGroup{
    .name = "ai-memory-sparse",
    .item_label = "memory rows",
    .item_counts = &sparse_item_counts,
    .runCase = runSparseCase,
    .write_workload = writeMemoryWorkload,
};

// Every Nth event row gets a synthetic `entity_perceived` event each iteration -- a fixed
// fraction rather than a single event, so refresh cost stays proportional across this
// bench's item-count sweep.
const ai_memory_event_stride: usize = 8;

// `ai-memory-sparse`: the think rows, `sparse_rows_per_word` in each of `sparse_touched_words`
// row words, fixed while the memory store grows.
const sparse_touched_words: usize = 64;
const sparse_rows_per_word: usize = 4;
const sparse_think_rows: usize = sparse_touched_words * sparse_rows_per_word;
const sparse_item_counts = [_]usize{ 4_096, 16_384, 65_536 };

const Fixture = struct {
    data: DataSystem,
    frame: SimulationFrame,
    // Shared perceived-target id for every injected event; only its value
    // (not its own components) matters to `AiMemorySystem`'s refresh pass.
    target: EntityId,

    fn deinit(self: *Fixture) void {
        self.frame.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

fn perceivedEventCount(count: usize) usize {
    if (count == 0) return 0;
    return @divCeil(count, ai_memory_event_stride);
}

pub fn createFixture(allocator: std.mem.Allocator, count: usize) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    var frame = SimulationFrame.init(allocator);
    errdefer frame.deinit();
    // One range holds every injected event for the step (mirrors how
    // `perception.zig` commits a whole step's transitions as one
    // `appendRangeCounts`/`rangeWriter` batch, not one `appendRequired` call
    // per event -- the latter recomputes O(ranges-so-far) bookkeeping on
    // every call, which would make injection cost dominate this bench).
    try frame.reserveStreams(1, perceivedEventCount(count), 0, 0, 0, 0);

    const target = try data.createEntity();
    for (0..count) |_| {
        const entity = try data.createEntity();
        try data.setAiAgent(entity, .{});
        try data.setAiPerception(entity, .{});
        try data.setAiMemory(entity, .{});
    }

    return .{ .data = data, .frame = frame, .target = target };
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseImpl(allocator, io, options, case, item_count, .{ .think_set = null, .event_rows = null, .touched_words = @divCeil(item_count, word_bits) });
}

pub fn runShuffledCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    const think_set = try fixtures.strideShuffledRows(allocator, item_count);
    defer allocator.free(think_set);
    return runCaseImpl(allocator, io, options, case, item_count, .{ .think_set = think_set, .event_rows = null, .touched_words = @divCeil(item_count, word_bits) });
}

pub fn runSparseCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    const word_count = item_count / word_bits;
    if (word_count < sparse_touched_words) return error.SparseThinkSetExceedsMemoryRows;
    // Think rows are memory rows: the fixture adds every store's row in one order.
    var ascending: [sparse_think_rows]u32 = undefined;
    for (0..sparse_touched_words) |touched| {
        const word = touched * (word_count / sparse_touched_words);
        for (0..sparse_rows_per_word) |slot| {
            // Below `item_count`, a population size.
            ascending[touched * sparse_rows_per_word + slot] = @intCast(word * word_bits + slot * (word_bits / sparse_rows_per_word));
        }
    }
    const order = try fixtures.strideShuffledRows(allocator, sparse_think_rows);
    defer allocator.free(order);
    var think_set: [sparse_think_rows]u32 = undefined;
    for (&think_set, order) |*row, rank| row.* = ascending[rank];
    return runCaseImpl(allocator, io, options, case, item_count, .{ .think_set = &think_set, .event_rows = &think_set, .touched_words = sparse_touched_words });
}

// `run.think_set` null: every agent in store order. `run.event_rows` null: events stride over
// every AI row; else over these rows.
fn runCaseImpl(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, run: Run) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const think_set = run.think_set;

    var fixture = try createFixture(allocator, item_count);
    defer fixture.deinit();
    var system = AiMemorySystem.init(allocator);
    defer system.deinit();
    if (suite.adaptiveTunerForCase(case, ai_memory_range_alignment_items)) |tuner| {
        system.gather_tuner = tuner;
        system.order_tuner = suite.adaptiveTunerForCase(case, ai_memory_order_range_alignment_items).?;
        system.decay_tuner = suite.adaptiveTunerForCase(case, 1).?;
        system.visible_tuner = suite.adaptiveTunerForCase(case, 1).?;
    }

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();

    var warm = suite.Warmup.init(options, case, 0);
    while (warm.next(tunersSettled(&system))) {
        _ = try runOnce(&system, &fixture, run, &threads, case);
    }
    const settled_before_measurement = if (case.adaptive) tunersSettled(&system) else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = AiMemoryStats{};
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_stats = try runOnce(&system, &fixture, run, &threads, case);
        const end_ns = suite.nowNs(io);
        const elapsed_ns = suite.elapsedNs(start_ns, end_ns);
        accumulator.record(elapsed_ns, last_stats.batch);
        main_total += elapsed_ns -| (offMainNs(last_stats.gather_batch) + offMainNs(last_stats.order_batch) + offMainNs(last_stats.batch) + offMainNs(last_stats.visible_batch));
    }

    var stats = accumulator.finish();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    const think_count = if (think_set) |rows| rows.len else item_count;
    std.debug.assert(system.memory_dense_indices.items.len == think_count);
    std.debug.assert(last_stats.gather_batch.item_count == think_count);
    std.debug.assert(last_stats.batch.item_count == think_count);
    std.debug.assert(last_stats.visible_batch.item_count == think_count);
    std.debug.assert(last_stats.order_batch.item_count == run.touched_words);
    stats.candidate_pairs = system.memory_dense_indices.items.len;
    stats.output_count = fixture.frame.events.stats.entity_perceived;
    stats.splice_batch = suite.batchSummaryFromBatch(last_stats.gather_batch);
    stats.query_splice_batch = suite.batchSummaryFromBatch(last_stats.order_batch);
    stats.secondary_batch = suite.batchSummaryFromBatch(last_stats.visible_batch);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(suite.tunerReport(&system.decay_tuner), settled_before_measurement);
    }
    return stats;
}

fn tunersSettled(system: *const AiMemorySystem) bool {
    return (system.gather_tuner.phase == .settled) and (system.order_tuner.phase == .settled) and (system.decay_tuner.phase == .settled) and (system.visible_tuner.phase == .settled);
}

const Run = struct {
    think_set: ?[]const u32,
    event_rows: ?[]const u32,
    // The order stage's items: the think set's nonzero member words.
    touched_words: usize,
};

fn runOnce(system: *AiMemorySystem, fixture: *Fixture, run: Run, thread_system: *ThreadSystem, case: suite.BenchmarkCase) !AiMemoryStats {
    fixture.frame.beginStep();
    const ai_slice = fixture.data.aiAgentSliceConst();
    try injectPerceivedEvents(&fixture.frame, ai_slice, run.event_rows, fixture.target);

    return try system.update(ai_slice, &fixture.data, &fixture.frame, thread_system, .{
        .items_per_range = case.stageItemsPerRange(ai_memory_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
        .scope_dense_indices = run.think_set,
    });
}

// Commits this iteration's synthetic perceived events, one per `ai_memory_event_stride`th
// event row (every AI row when `event_rows` is null), as one range-writer
// batch (`appendRangeCounts` -> `addCount` -> `prefixAppendedRanges` ->
// `rangeWriter` -> one `finishWrite`), the same shape `perception.zig` itself
// uses to commit a whole step's transitions. Calling `appendRequired` once
// per event instead would recompute pending-count/stat bookkeeping over every
// range appended so far on each call, turning a `count`-sized injection loop
// into `O(count^2)` overhead that would dominate the measured window.
fn injectPerceivedEvents(frame: *SimulationFrame, ai_slice: ConstAiAgentSlice, event_rows: ?[]const u32, target: EntityId) !void {
    const row_count = if (event_rows) |rows| rows.len else ai_slice.entities.len;
    const event_count = perceivedEventCount(row_count);
    if (event_count == 0) return;

    const first_range = try frame.events.appendRangeCounts(1);
    frame.events.addCount(first_range, event_count);
    try frame.events.prefixAppendedRanges(first_range);

    var writer = frame.events.rangeWriter(first_range);
    var k: usize = 0;
    while (k < row_count) : (k += ai_memory_event_stride) {
        const row: usize = if (event_rows) |rows| rows[k] else k;
        writer.write(.{ .stage = .domain_reaction, .payload = .{ .entity_perceived = .{
            .observer = ai_slice.entities[row],
            .target = target,
        } } });
    }
    writer.finish();
    frame.events.finishWrite();
}

// `splice_batch` holds the translate stage, `query_splice_batch` the order stage, and
// `secondary_batch` the visibility pass (`batch` is decay); `main` is the time outside the
// four stages' worker dispatches, also per processed row.
fn writeMemoryWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("processed={} refreshed={}", .{ stats.candidate_pairs, stats.output_count });
    try suite.writeMainShare(writer, stats, stats.candidate_pairs);
    if (view == .summary) return;
    try writeStage(writer, " translate=", stats.splice_batch);
    try writeStage(writer, " order=", stats.query_splice_batch);
    try writeStage(writer, " visible=", stats.secondary_batch);
}

fn writeStage(writer: *std.Io.Writer, label: []const u8, batch: ?suite.BatchSummary) std.Io.Writer.Error!void {
    const shape = batch orelse return;
    try writer.writeAll(label);
    try suite.writeStageShape(writer, shape);
}
