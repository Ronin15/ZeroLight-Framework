// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! AiMemorySystem throughput bench: isolates the two real per-step costs this
//! system pays -- SIMD gather/scatter decay of every gathered agent's
//! staleness/familiarity/ring columns (`processed_count`), and the
//! event-driven ring refresh pass reacting to this step's `entity_perceived`
//! events (`refreshed_count`). Every `ai_memory_event_stride`th agent gets a
//! synthetic perceived event each iteration, so `refreshed_count` scales with
//! population like `processed_count` does, without event injection itself
//! dominating the measured window.

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const ConstAiAgentSlice = @import("../game/data_system.zig").ConstAiAgentSlice;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const AiMemoryStats = @import("../game/systems/ai_memory.zig").AiMemoryStats;
const AiMemorySystem = @import("../game/systems/ai_memory.zig").AiMemorySystem;
const ai_memory_range_alignment_items = @import("../game/systems/ai_memory.zig").ai_memory_range_alignment_items;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "ai-memory",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
};

// Every Nth agent (creation order) gets a synthetic `entity_perceived` event
// each iteration -- a fixed population fraction rather than a single event,
// so refresh cost stays proportional across this bench's item-count sweep.
const ai_memory_event_stride: usize = 8;

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

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return suite.eventScaleCounts(profile);
}

fn perceivedEventCount(count: usize) usize {
    if (count == 0) return 0;
    return (count + ai_memory_event_stride - 1) / ai_memory_event_stride;
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
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try createFixture(allocator, item_count);
    defer fixture.deinit();
    var system = AiMemorySystem.init(allocator);
    defer system.deinit();
    if (suite.adaptiveTunerForCase(case, ai_memory_range_alignment_items)) |tuner| {
        system.decay_tuner = tuner;
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
        while (!system.decay_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case);
        }
    }
    const settled_before_measurement = if (case.adaptive) system.decay_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = AiMemoryStats{};
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_stats = try runOnce(&system, &fixture, if (threads) |*thread_system| thread_system else null, case);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.batch);
    }

    var stats = accumulator.finish();
    stats.candidate_pairs = last_stats.processed_count;
    stats.output_count = last_stats.refreshed_count;
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.decay_tuner.report(), settled_before_measurement);
    }
    return stats;
}

fn runOnce(system: *AiMemorySystem, fixture: *Fixture, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase) !AiMemoryStats {
    fixture.frame.beginStep();
    const ai_slice = fixture.data.aiAgentSliceConst();
    try injectPerceivedEvents(&fixture.frame, ai_slice, fixture.target);

    if (!case.usesThreadSystem()) {
        return try system.updateSerial(ai_slice, &fixture.data, &fixture.frame, .{});
    }

    return try system.update(ai_slice, &fixture.data, &fixture.frame, thread_system.?, .{
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

// Commits this iteration's synthetic perceived events as one range-writer
// batch (`appendRangeCounts` -> `addCount` -> `prefixAppendedRanges` ->
// `rangeWriter` -> one `finishWrite`), the same shape `perception.zig` itself
// uses to commit a whole step's transitions. Calling `appendRequired` once
// per event instead would recompute pending-count/stat bookkeeping over every
// range appended so far on each call, turning a `count`-sized injection loop
// into `O(count^2)` overhead that would dominate the measured window.
fn injectPerceivedEvents(frame: *SimulationFrame, ai_slice: ConstAiAgentSlice, target: EntityId) !void {
    const event_count = perceivedEventCount(ai_slice.entities.len);
    if (event_count == 0) return;

    const first_range = try frame.events.appendRangeCounts(1);
    frame.events.addCount(first_range, event_count);
    try frame.events.prefixAppendedRanges(first_range);

    var writer = frame.events.rangeWriter(first_range);
    var i: usize = 0;
    while (i < ai_slice.entities.len) : (i += ai_memory_event_stride) {
        writer.write(.{ .stage = .domain_reaction, .payload = .{ .entity_perceived = .{
            .observer = ai_slice.entities[i],
            .target = target,
        } } });
    }
    writer.finish();
    frame.events.finishWrite();
}

fn benchmarkItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(ai_memory_range_alignment_items) orelse
        suite.alignItemCount(suite.default_items_per_range, ai_memory_range_alignment_items);
}
