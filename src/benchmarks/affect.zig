// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Affect throughput: one `AffectSystem` step appraising each think row's four drives (fear,
//! curiosity, aggression, fatigue). Every `affect_signal_stride`th agent also carries
//! `AiPerception` and `AiMemory` with a visible hostile and low familiarity in its hot
//! columns, set at fixture creation; nothing is injected per step. Both groups print
//! `processed=` (rows appraised) and `threshold_crossings=`; `--details` adds `main=` with
//! `main_per_item=` (per processed row), flat across sizes. Asserts also check a fixed
//! threaded case dispatches the appraisal to workers.
//! - `ai-affect`: every agent, the think set in store order. Pass shape: time linear in
//!   agents; asserts check every agent is appraised each step.
//! - `ai-affect-shuffled`: the same step over a stride shuffle of every agent as the think
//!   set, so ranges write scattered affect rows, as a cell-major think set does. Pass shape:
//!   within spread of `ai-affect`.

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const AffectStats = @import("../game/systems/affect.zig").AffectStats;
const AffectSystem = @import("../game/systems/affect.zig").AffectSystem;
const affect_range_alignment_items = @import("../game/systems/affect.zig").affect_range_alignment_items;
const SimulationEvents = @import("../game/simulation.zig").SimulationEvents;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "ai-affect",
    .item_label = "AI agents",
    .item_counts = &suite.event_scale_counts,
    .runCase = runCase,
    .write_workload = writeAffectWorkload,
};

pub const shuffled_group = suite.BenchmarkGroup{
    .name = "ai-affect-shuffled",
    .item_label = "AI agents",
    .item_counts = &suite.event_scale_counts,
    .runCase = runShuffledCase,
    .write_workload = writeAffectWorkload,
};

// Every Nth agent (creation order) also carries AiPerception/AiMemory with a
// visible-hostile/low-familiarity signal baked in, so the
// mixed population (some rows with both optional components, most without)
// exercises the common gather path, not just the all-absent one.
const affect_signal_stride: usize = 4;

const Fixture = struct {
    data: DataSystem,
    events: SimulationEvents,

    fn deinit(self: *Fixture) void {
        self.events.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

pub fn createFixture(allocator: std.mem.Allocator, count: usize) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    var events = SimulationEvents.init(allocator);
    errdefer events.deinit();

    for (0..count) |i| {
        const entity = try data.createEntity();
        const seek = i % 2 == 0;
        try data.setAiAgent(entity, .{ .active_behavior = if (seek) .pursue else .wander });
        try data.setAiAffect(entity, .{ .decay_rate_fear = 0.1, .decay_rate_curiosity = 0.1, .decay_rate_aggression = 0.1, .decay_rate_fatigue = 0.1 });
        if (i % affect_signal_stride == 0) {
            try data.setAiPerception(entity, .{ .vision_range = 100, .target_visible = true, .nearest_threat_dist = 10, .heard_stimulus = false });
            try data.setAiMemory(entity, .{ .familiarity = 0.1 });
        }
    }

    return .{ .data = data, .events = events };
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseImpl(allocator, io, options, case, item_count, null);
}

pub fn runShuffledCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    const think_set = try fixtures.strideShuffledRows(allocator, item_count);
    defer allocator.free(think_set);
    return runCaseImpl(allocator, io, options, case, item_count, think_set);
}

// `think_set` null: every agent in store order.
fn runCaseImpl(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, think_set: ?[]const u32) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try createFixture(allocator, item_count);
    defer fixture.deinit();
    var system = AffectSystem.init(allocator);
    defer system.deinit();

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();

    var warm = suite.Warmup.init(options, case, 0);
    while (warm.next(suite.tunerSettled(&system.compute_tuner))) {
        fixture.events.clearRetainingCapacity();
        _ = try runOnce(&system, &fixture, think_set, &threads, case);
    }
    const settled_before_measurement = if (case.adaptive) suite.tunerSettled(&system.compute_tuner) else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = AffectStats{};
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        fixture.events.clearRetainingCapacity();
        const start_ns = suite.nowNs(io);
        last_stats = try runOnce(&system, &fixture, think_set, &threads, case);
        const end_ns = suite.nowNs(io);
        const elapsed_ns = suite.elapsedNs(start_ns, end_ns);
        accumulator.record(elapsed_ns, last_stats.perf.batch);
        try suite.checkStageDispatched(case, &threads, case.stageItemsPerRange(affect_range_alignment_items), last_stats.perf.batch);
        main_total += elapsed_ns -| offMainNs(last_stats.perf.batch);
    }

    std.debug.assert(options.iterations == 0 or system.rows.len == item_count);
    var stats = accumulator.finish();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    stats.candidate_pairs = system.rows.len;
    stats.output_count = fixture.events.stats.affect_threshold_crossed;
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(suite.tunerReport(&system.compute_tuner), settled_before_measurement);
    }
    return stats;
}

// One affect step; the caller clears the events first, outside any timed window.
fn runOnce(system: *AffectSystem, fixture: *Fixture, think_set: ?[]const u32, thread_system: *ThreadSystem, case: suite.BenchmarkCase) !AffectStats {
    const ai_slice = fixture.data.aiAgentSliceConst();

    return try system.update(ai_slice, &fixture.data, &fixture.events, thread_system, .{
        .items_per_range = case.stageItemsPerRange(affect_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
        .scope_dense_indices = think_set,
    });
}

// `main` is the time outside the appraisal's worker dispatch, also per processed row.
fn writeAffectWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("processed={} threshold_crossings={}", .{ stats.candidate_pairs, stats.output_count });
    if (view == .summary) return;
    try suite.writeMainShare(writer, stats, stats.candidate_pairs);
}
