// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! - `ai`: the per-step AI decision (gather, separation, cohere, arbitration, intents) over
//!   a fixed-density grid, with the shared index and the think set (every agent, in the
//!   index's cell-major order, as production orders it) built untimed. Pass shape: time
//!   linear in agents; separation checks per agent at most `max_separation_candidate_checks`;
//!   neighbor-block fills at most the rows' cell runs plus the ranges, per query kind; the
//!   tuned case within spread of the best control; the main thread's time (the gather's
//!   window merge) flat per agent. Asserts check the check and fill bounds.
//! - `ai-cell-ordered`: the same agents created in the think set's order, so every per-row
//!   store read and write (`ai_agent_hot` by AI index) ascends. Pass shape: `ai` within
//!   spread of it, the scattered-write control; asserts check the think set ascends.
//! Both print `separation_checks=`, `intents=`, `separation_fills=`, and `cohere_fills=`
//! (neighbor-block fills per query kind); the summary adds the behavior histogram, and
//! `--details` adds `main=` with `main_per_item=` (per intent), `gather=` and `intent=` (stage
//! shapes; the separation stage is the row's batch), and `tuned=` when the intent stage ran
//! inline.

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const maxRangeCount = @import("../app/thread_system.zig").maxRangeCount;
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const math = @import("../core/math.zig");
const AiBehavior = @import("../game/data_system.zig").AiBehavior;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const AiStats = @import("../game/systems/ai.zig").AiStats;
const AiSystem = @import("../game/systems/ai.zig").AiSystem;
const ai_range_alignment_items = @import("../game/systems/ai.zig").ai_range_alignment_items;
const max_separation_candidate_checks = @import("../game/systems/ai.zig").max_separation_candidate_checks;
const IndexGeometry = @import("../game/systems/spatial_index.zig").IndexGeometry;
const SpatialIndexSystem = @import("../game/systems/spatial_index.zig").SpatialIndexSystem;
const SpatialIndexView = @import("../game/systems/spatial_index.zig").SpatialIndexView;
const SimulationScopeSystem = @import("../game/systems/simulation_scope.zig").SimulationScopeSystem;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const InterestMarkerStore = @import("../game/world/interest.zig").InterestMarkerStore;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

const delta_seconds: f32 = 1.0 / 60.0;
const intent_seed: u64 = 0x0a17_b0a7;

// One archetype per `AiBehavior`, so every selection bucket runs; perception columns are set
// directly, so the bench times decision and intents, not the upstream cognition stages.
const behavior_archetype_cycle_len: usize = 5;

// The fixture's body grid: columns per row and the world-unit pitch.
const grid_columns: usize = 128;
const grid_pitch_x: f32 = 11.0;
const grid_pitch_y: f32 = 9.0;

pub const group = suite.BenchmarkGroup{
    .name = "ai",
    .item_label = "AI agents",
    .item_counts = &suite.event_scale_counts,
    .runCase = runCase,
    .write_workload = writeAiWorkload,
};

pub const cell_ordered_group = suite.BenchmarkGroup{
    .name = "ai-cell-ordered",
    .item_label = "AI agents",
    .item_counts = &suite.event_scale_counts,
    .runCase = runCellOrderedCase,
    .write_workload = writeAiWorkload,
};

const Fixture = struct {
    data: DataSystem,
    frame: SimulationFrame,
    // Backs `AiConfig.focus_entity` -- `resolveGoal`'s pursue fallback checks
    // the *entity*, not just the position (`Signals.focus_target`), so a
    // config with only `.focus_target` set and no `.focus_entity` never
    // resolves the fallback tier at all.
    focus_entity: EntityId,
    markers: InterestMarkerStore,

    fn deinit(self: *Fixture) void {
        self.markers.deinit(self.frame.allocator);
        self.frame.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

pub fn createFixture(allocator: std.mem.Allocator, count: usize) !Fixture {
    return createFixtureInOrder(allocator, count, null);
}

// The fixture's agents created in `order` (agent `order[k]` k-th), or in index order.
fn createFixtureInOrder(allocator: std.mem.Allocator, count: usize, order: ?[]const u32) !Fixture {
    std.debug.assert(order == null or order.?.len == count);
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    var frame = SimulationFrame.init(allocator);
    errdefer frame.deinit();
    try frame.reserveStreams(maxRangeCount(count, ai_range_alignment_items), 0, count, 0, 0, 0);

    // Marker entities for flee's `nearest_threat` id and pursue's opt-in
    // `focus_target` fallback id: only their validity matters here (no
    // movement/AI components of their own), never queried by the spatial
    // index.
    const threat_marker = try data.createEntity();
    const focus_entity = try data.createEntity();

    for (0..count) |step| {
        const index: usize = if (order) |agents| agents[step] else step;
        const entity = try data.createEntity();
        const position = math.Vec2{
            .x = @as(f32, @floatFromInt(index % grid_columns)) * grid_pitch_x,
            .y = @as(f32, @floatFromInt(index / grid_columns)) * grid_pitch_y,
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
        try data.setAiMemory(entity, .{ .staleness = @floatFromInt(index % 5), .familiarity = 0.25 });
        try data.setAiAffect(entity, .{ .fear = 0.2, .curiosity = 0.15, .aggression = 0.1 });
    }

    var markers = InterestMarkerStore.init(allocator);
    errdefer markers.deinit(allocator);
    _ = try markers.addMarker(.{ .kind = .investigate, .level = 0, .x = 64, .y = 64, .radius = 16 });
    _ = try markers.addMarker(.{ .kind = .investigate, .level = 0, .x = 400, .y = 200, .radius = 16 });

    return .{ .data = data, .frame = frame, .focus_entity = focus_entity, .markers = markers };
}

// The grid covering the fixture's `count` bodies, laid out `grid_columns` per row.
fn fixtureIndexGeometry(count: usize) IndexGeometry {
    const rows = (count + grid_columns - 1) / grid_columns;
    return fixtures.indexGeometryCovering(@as(f32, @floatFromInt(grid_columns)) * grid_pitch_x, @as(f32, @floatFromInt(rows)) * grid_pitch_y, 1);
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
    return runFixture(allocator, io, options, case, item_count, &fixture, false);
}

pub fn runCellOrderedCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    // The default fixture's think set is the creation order, built inline.
    var setup_threads = try ThreadSystem.init(allocator, io, .{ .max_worker_threads = 0 });
    defer setup_threads.deinit();
    const order = blk: {
        var plain = try createFixture(allocator, item_count);
        defer plain.deinit();
        var index = SpatialIndexSystem.init(allocator);
        defer index.deinit();
        _ = try index.build(&plain.data, .{ .entities = plain.data.aiAgentSliceConst().entities }, fixtureIndexGeometry(item_count), &setup_threads, .{});
        const view = index.view();
        var scope = SimulationScopeSystem.init(allocator);
        defer scope.deinit();
        break :blk try allocator.dupe(u32, (try scope.compactCognition(&view, 0, false, &setup_threads, .{})).cognition);
    };
    defer allocator.free(order);
    var fixture = try createFixtureInOrder(allocator, item_count, order);
    defer fixture.deinit();
    return runFixture(allocator, io, options, case, item_count, &fixture, true);
}

// `think_ascends`: the fixture was created in its think set's order.
fn runFixture(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, fixture: *Fixture, think_ascends: bool) !suite.RunStats {
    var system = AiSystem.init(allocator);
    defer system.deinit();
    if (suite.adaptiveTunerForCase(case, ai_range_alignment_items)) |tuner| {
        system.gather_tuner = tuner;
        system.separation_tuner = suite.adaptiveTunerForCase(case, ai_range_alignment_items).?;
        system.intent_tuner = suite.adaptiveTunerForCase(case, ai_range_alignment_items).?;
    }

    var threads: ?ThreadSystem = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();

    // Positions never change, so the index is built once, untimed (its own group times it).
    var spatial_sys = SpatialIndexSystem.init(allocator);
    defer spatial_sys.deinit();
    _ = try spatial_sys.build(&fixture.data, .{ .entities = fixture.data.aiAgentSliceConst().entities }, fixtureIndexGeometry(item_count), &threads.?, .{ .adaptive = false });
    const spatial_view = spatial_sys.view();
    var scope = SimulationScopeSystem.init(allocator);
    defer scope.deinit();
    const think_set = (try scope.compactCognition(&spatial_view, 0, false, &threads.?, .{ .adaptive = false })).cognition;
    std.debug.assert(think_set.len == item_count);
    if (think_ascends) {
        for (think_set, 0..) |row, rank| std.debug.assert(row == rank);
    }

    var warm = suite.Warmup.init(options, case, 0);
    while (warm.next((system.gather_tuner.phase == .settled) and (system.separation_tuner.phase == .settled) and (system.intent_tuner.phase == .settled))) {
        _ = try runOnce(&system, fixture, spatial_view, think_set, if (threads) |*thread_system| thread_system else null, case);
    }
    const separation_settled_before_measurement = if (case.adaptive) (system.separation_tuner.phase == .settled) else false;
    const intent_settled_before_measurement = if (case.adaptive) (system.intent_tuner.phase == .settled) else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_ai_stats = AiStats{};
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_ai_stats = try runOnce(&system, fixture, spatial_view, think_set, if (threads) |*thread_system| thread_system else null, case);
        const end_ns = suite.nowNs(io);
        const elapsed_ns = suite.elapsedNs(start_ns, end_ns);
        accumulator.record(elapsed_ns, last_ai_stats.separation_batch);
        main_total += elapsed_ns -| (offMainNs(last_ai_stats.gather_batch) + offMainNs(last_ai_stats.separation_batch) + offMainNs(last_ai_stats.intent_batch));
    }

    var stats = accumulator.finish();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    std.debug.assert(last_ai_stats.separation_candidate_checks <= last_ai_stats.entity_count * max_separation_candidate_checks);
    // A fill per key a range's rows change to: at most the rows' cell runs plus the ranges.
    const ranges = last_ai_stats.separation_batch.range_count;
    std.debug.assert(last_ai_stats.separation_block_fills <= cellRuns(fixture, spatial_view, think_set, false) + ranges);
    std.debug.assert(last_ai_stats.cohere_block_fills <= cellRuns(fixture, spatial_view, think_set, true) + ranges);
    stats.candidate_pairs = last_ai_stats.separation_candidate_checks;
    stats.output_count = last_ai_stats.intent_count;
    stats.neighbor_block_fills = last_ai_stats.separation_block_fills;
    stats.secondary_neighbor_block_fills = last_ai_stats.cohere_block_fills;
    stats.secondary_batch = suite.batchSummaryFromBatch(last_ai_stats.intent_batch);
    stats.splice_batch = suite.batchSummaryFromBatch(last_ai_stats.gather_batch);
    stats.ai_behavior_histogram = behaviorHistogram(fixture.data.aiAgentSliceConst().behaviors);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(suite.tunerReport(&system.separation_tuner), separation_settled_before_measurement);
        stats.secondary_work_tuning = suite.workTuningSummary(suite.tunerReport(&system.intent_tuner), intent_settled_before_measurement);
    }
    return stats;
}

// The runs of consecutive think rows on one index cell, over the rows with cohere gain when
// `cohere` (one faction, so the cell is the key).
fn cellRuns(fixture: *const Fixture, view: SpatialIndexView, think_set: []const u32, cohere: bool) usize {
    const ai = fixture.data.aiAgentSliceConst();
    const movement = fixture.data.movementBodySliceConst();
    var runs: usize = 0;
    var previous: ?[2]u32 = null;
    for (think_set) |row| {
        if (cohere and ai.gain_coheres[row] <= 0) continue;
        const body = fixture.data.movementBodyDenseIndex(ai.entities[row]).?;
        const cell = [2]u32{ math.worldPosToCell(movement.previous_x[body], view.cell_size, view.cells_x), math.worldPosToCell(movement.previous_y[body], view.cell_size, view.cells_y) };
        if (previous == null or !std.mem.eql(u32, &previous.?, &cell)) runs += 1;
        previous = cell;
    }
    return runs;
}

fn runOnce(system: *AiSystem, fixture: *Fixture, spatial_view: SpatialIndexView, think_set: []const u32, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase) !AiStats {
    fixture.frame.beginStep();
    const ai_slice = fixture.data.aiAgentSliceConst();
    const movement_slice = fixture.data.movementBodySliceConst();

    return try system.update(ai_slice, movement_slice, spatial_view, &fixture.data, &fixture.frame, thread_system.?, delta_seconds, .{
        .items_per_range = case.stageItemsPerRange(ai_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
        .intent_seed = intent_seed,
        .focus_target = benchmarkSeekTarget(),
        .focus_entity = fixture.focus_entity,
        .perception_slice = fixture.data.aiPerceptionSliceConst(),
        .memory_slice = fixture.data.aiMemorySliceConst(),
        .affect_slice = fixture.data.aiAffectSliceConst(),
        .interest_markers = &fixture.markers,
        .scope_dense_indices = think_set,
    });
}

fn benchmarkSeekTarget() math.Vec2 {
    return .{ .x = 480, .y = 270 };
}

// `neighbor_block_fills` holds the separation block fills, `secondary_neighbor_block_fills`
// the cohere ones, `secondary_batch` the intent stage, `splice_batch` the gather, and `main`
// the time outside the three stages' worker dispatches, also per intent.
fn writeAiWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("separation_checks={} intents={} separation_fills={} cohere_fills={}", .{ stats.candidate_pairs, stats.output_count, stats.neighbor_block_fills, stats.secondary_neighbor_block_fills });
    if (view == .summary) {
        if (stats.ai_behavior_histogram) |histogram| {
            try writer.print(" behaviors wander={} pursue={} flee={} investigate={} cohere={}", .{ histogram.wander, histogram.pursue, histogram.flee, histogram.investigate, histogram.cohere });
        }
        return;
    }
    try suite.writeMainShare(writer, stats, stats.output_count);
    if (stats.splice_batch) |gather| {
        try writer.writeAll(" gather=");
        try suite.writeStageShape(writer, gather);
    }
    const intent = stats.secondary_batch orelse return;
    try writer.writeAll(" intent=");
    try suite.writeStageShape(writer, intent);
    if (intent.ran_inline or intent.active_worker_threads == 0) {
        if (stats.secondary_work_tuning) |summary| try writer.print(" tuned={s}", .{if (summary.has_threaded_profile) "threaded" else "none"});
    }
}
