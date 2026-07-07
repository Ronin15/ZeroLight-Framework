// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! AffectSystem throughput bench: isolates the per-step cost of appraising
//! every gathered agent's four drives (fear/curiosity/aggression/fatigue).
//! A fixed fraction of the fixture carries `AiPerception`/`AiMemory` too, with
//! a visible-hostile/heard-stimulus/low-familiarity signal already baked into
//! the hot columns at fixture creation time -- unlike ai_memory.zig's bench,
//! affect's inputs are hot component state, not per-step events, so there is
//! no per-iteration injection loop here (and so no risk of the O(n^2)
//! per-event `appendRequired` pitfall that file's bench comment warns about).

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const ConstAiAgentSlice = @import("../game/data_system.zig").ConstAiAgentSlice;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const AffectStats = @import("../game/systems/affect.zig").AffectStats;
const AffectSystem = @import("../game/systems/affect.zig").AffectSystem;
const affect_range_alignment_items = @import("../game/systems/affect.zig").affect_range_alignment_items;
const SimulationEvents = @import("../game/simulation.zig").SimulationEvents;
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "ai-affect",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
};

// Every Nth agent (creation order) also carries AiPerception/AiMemory with a
// visible-hostile/heard-stimulus/low-familiarity signal baked in, so the
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

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return suite.eventScaleCounts(profile);
}

pub fn createFixture(allocator: std.mem.Allocator, count: usize) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    var events = SimulationEvents.init(allocator);
    errdefer events.deinit();

    for (0..count) |i| {
        const entity = try data.createEntity();
        const seek = i % 2 == 0;
        try data.setAiAgent(entity, .{ .behavior = if (seek) .seek else .wander });
        try data.setAiAffect(entity, .{ .decay_rate_fear = 0.1, .decay_rate_curiosity = 0.1, .decay_rate_aggression = 0.1, .decay_rate_fatigue = 0.1 });
        if (i % affect_signal_stride == 0) {
            try data.setAiPerception(entity, .{ .vision_range = 100, .target_visible = true, .nearest_threat_dist = 10, .heard_stimulus = false });
            try data.setAiMemory(entity, .{ .familiarity = 0.1 });
        }
    }

    return .{ .data = data, .events = events };
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try createFixture(allocator, item_count);
    defer fixture.deinit();
    var system = AffectSystem.init(allocator);
    defer system.deinit();
    if (suite.adaptiveTunerForCase(case, affect_range_alignment_items)) |tuner| {
        system.compute_tuner = tuner;
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
        while (!system.compute_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case);
        }
    }
    const settled_before_measurement = if (case.adaptive) system.compute_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = AffectStats{};
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_stats = try runOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.batch);
    }

    var stats = accumulator.finish();
    stats.candidate_pairs = last_stats.processed_count;
    stats.output_count = last_stats.threshold_crossed_count;
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.compute_tuner.report(), settled_before_measurement);
    }
    return stats;
}

fn runOnce(system: *AffectSystem, fixture: *Fixture, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase) !AffectStats {
    fixture.events.clearRetainingCapacity();
    const ai_slice = fixture.data.aiAgentSliceConst();

    if (!case.usesThreadSystem()) {
        return try system.updateSerial(ai_slice, &fixture.data, &fixture.events, .{});
    }

    return try system.update(ai_slice, &fixture.data, &fixture.events, thread_system.?, .{
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

fn benchmarkItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(affect_range_alignment_items) orelse
        suite.alignItemCount(suite.default_items_per_range, affect_range_alignment_items);
}
