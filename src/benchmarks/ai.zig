// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const math = @import("../core/math.zig");
const AiBehavior = @import("../game/data_system.zig").AiBehavior;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const AiStats = @import("../game/systems/ai.zig").AiStats;
const AiSystem = @import("../game/systems/ai.zig").AiSystem;
const ai_range_alignment_items = @import("../game/systems/ai.zig").ai_range_alignment_items;
const SpatialIndexSystem = @import("../game/systems/spatial_index.zig").SpatialIndexSystem;
const SpatialIndexView = @import("../game/systems/spatial_index.zig").SpatialIndexView;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const suite = @import("suite.zig");

const delta_seconds: f32 = 1.0 / 60.0;
const intent_seed: u64 = 0x0a17_b0a7;

// Fixed 5-slot archetype cycle (one slot per `AiBehavior`), so the
// arbitration selection histogram exercises every bucket instead of
// collapsing to a wander/pursue split. Mirrors `game_demo_state.zig`'s
// `demoArchetypeForIndex` at bench scale, but sets hot perception columns
// directly (no `PerceptionSystem`/`AffectSystem` run) the same way
// `affect.zig`'s bench sets `AiPerception` hot fields straight into the
// fixture -- this bench isolates arbitration + intent-emission cost, not the
// upstream cognition stages.
const behavior_archetype_cycle_len: usize = 5;

pub const group = suite.BenchmarkGroup{
    .name = "ai",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
};

const Fixture = struct {
    data: DataSystem,
    frame: SimulationFrame,
    // Backs `AiConfig.focus_entity` -- `resolveGoal`'s pursue fallback checks
    // the *entity*, not just the position (`Signals.focus_target`), so a
    // config with only `.focus_target` set and no `.focus_entity` never
    // resolves the fallback tier at all.
    focus_entity: EntityId,

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
    try frame.reserveStreams(suite.rangeCount(count, ai_range_alignment_items), 0, count, 0, 0, 0);

    // Marker entities for flee's `nearest_threat` id and pursue's opt-in
    // `focus_target` fallback id: only their validity matters here (no
    // movement/AI components of their own), never queried by the spatial
    // index.
    const threat_marker = try data.createEntity();
    const focus_entity = try data.createEntity();

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
        // Uniform faction so cohere's friendly-neighbor spatial query always
        // has candidates nearby, regardless of which archetype slot lands
        // next to it in the grid.
        try data.setFaction(entity, .ally);
        const wander_amplitude = 6.0 + @as(f32, @floatFromInt(index % 29));

        switch (index % behavior_archetype_cycle_len) {
            0 => try data.setAiAgent(entity, .{ .active_behavior = .wander, .wander_amplitude = wander_amplitude }),
            1 => try data.setAiAgent(entity, .{
                .active_behavior = .pursue,
                .wander_amplitude = wander_amplitude,
                .gain_pursue = 0.4 + @as(f32, @floatFromInt(index % 7)) * 0.1,
            }),
            2 => {
                try data.setAiAgent(entity, .{ .active_behavior = .wander, .wander_amplitude = wander_amplitude, .gain_flee = 1.5 });
                try data.setAiPerception(entity, .{
                    .target_visible = true,
                    .nearest_threat = threat_marker,
                    .last_seen_x = position.x - 40.0,
                    .last_seen_y = position.y,
                });
            },
            3 => {
                try data.setAiAgent(entity, .{ .active_behavior = .wander, .wander_amplitude = wander_amplitude, .gain_investigate = 1.5 });
                try data.setAiPerception(entity, .{
                    .heard_stimulus = true,
                    .heard_stimulus_x = position.x,
                    .heard_stimulus_y = position.y + 20.0,
                });
            },
            else => try data.setAiAgent(entity, .{ .active_behavior = .wander, .wander_amplitude = wander_amplitude, .gain_cohere = 1.5 }),
        }
    }

    return .{ .data = data, .frame = frame, .focus_entity = focus_entity };
}

fn behaviorHistogram(behaviors: []const AiBehavior) suite.AiBehaviorHistogramSummary {
    var histogram = suite.AiBehaviorHistogramSummary{};
    for (behaviors) |behavior| {
        switch (behavior) {
            .wander => histogram.wander += 1,
            .pursue => histogram.pursue += 1,
            .flee => histogram.flee += 1,
            .investigate => histogram.investigate += 1,
            .cohere => histogram.cohere += 1,
        }
    }
    return histogram;
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

    // This bench never runs movement, so the fixture's positions never change
    // across iterations. Build the shared spatial index once, outside every
    // timed/warmup/settle call, so the group's timed window measures only
    // `system.update`/`updateSerial` (query + intent emission), not the index
    // build — that cost has its own dedicated `spatial_index` bench group.
    var spatial_sys = SpatialIndexSystem.init(allocator);
    defer spatial_sys.deinit();
    const ai_slice = fixture.data.aiAgentSliceConst();
    const movement_slice = fixture.data.movementBodySliceConst();
    try spatial_sys.reserve(ai_slice.entities.len, .{});
    _ = try spatial_sys.buildSerial(ai_slice, movement_slice, &fixture.data, .{});
    const spatial_view = spatial_sys.view();

    for (0..options.warmup_iterations) |_| {
        _ = try runOnce(&system, &fixture, spatial_view, if (threads) |*thread_system| thread_system else null, case);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while ((!system.separation_tuner.isSettled() or !system.intent_tuner.isSettled()) and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runOnce(&system, &fixture, spatial_view, if (threads) |*thread_system| thread_system else null, case);
        }
    }
    const separation_settled_before_measurement = if (case.adaptive) system.separation_tuner.isSettled() else false;
    const intent_settled_before_measurement = if (case.adaptive) system.intent_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_ai_stats = AiStats{};
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_ai_stats = try runOnce(&system, &fixture, spatial_view, if (threads) |*thread_system| thread_system else null, case);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_ai_stats.separation_batch);
    }

    var stats = accumulator.finish();
    stats.candidate_pairs = last_ai_stats.separation_candidate_checks;
    stats.output_count = last_ai_stats.intent_count;
    stats.secondary_batch = suite.batchSummaryFromBatch(last_ai_stats.intent_batch);
    stats.ai_behavior_histogram = behaviorHistogram(fixture.data.aiAgentSliceConst().behaviors);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.separation_tuner.report(), separation_settled_before_measurement);
        stats.secondary_work_tuning = suite.workTuningSummary(system.intent_tuner.report(), intent_settled_before_measurement);
    }
    return stats;
}

fn runOnce(system: *AiSystem, fixture: *Fixture, spatial_view: SpatialIndexView, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase) !AiStats {
    fixture.frame.beginStep();
    const ai_slice = fixture.data.aiAgentSliceConst();
    const movement_slice = fixture.data.movementBodySliceConst();
    if (!case.usesThreadSystem()) {
        return try system.updateSerial(ai_slice, movement_slice, spatial_view, &fixture.data, &fixture.frame, delta_seconds, .{
            .intent_seed = intent_seed,
            .focus_target = benchmarkSeekTarget(),
            .focus_entity = fixture.focus_entity,
            .perception_slice = fixture.data.aiPerceptionSliceConst(),
        });
    }

    return try system.update(ai_slice, movement_slice, spatial_view, &fixture.data, &fixture.frame, thread_system.?, delta_seconds, .{
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
        .intent_seed = intent_seed,
        .focus_target = benchmarkSeekTarget(),
        .focus_entity = fixture.focus_entity,
        .perception_slice = fixture.data.aiPerceptionSliceConst(),
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
