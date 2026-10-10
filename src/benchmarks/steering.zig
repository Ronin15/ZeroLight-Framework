// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! `steering` times one steering step over its agent count. `steering-static-change` times
//! one static collision body moved and committed, the steering post-commit reaction, and one
//! steering step for a fixed agent population, with the static count as its item count; the
//! cost model expects it flat in the static count.

const std = @import("std");
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const math = @import("../core/math.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const NavigationIntent = @import("../game/simulation.zig").NavigationIntent;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const PathfindingSystem = @import("../game/systems/pathfinding.zig").PathfindingSystem;
const SteeringStats = @import("../game/systems/steering.zig").SteeringStats;
const SteeringSystem = @import("../game/systems/steering.zig").SteeringSystem;
const steering_range_alignment_items = @import("../game/systems/steering.zig").steering_range_alignment_items;
const default_chunk_size_tiles = @import("../game/world_system.zig").default_chunk_size_tiles;
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "steering",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
};

pub const static_change_group = suite.BenchmarkGroup{
    .name = "steering-static-change",
    .defaultItemCounts = staticChangeItemCounts,
    .runCase = runStaticChangeCase,
};

const quick_counts = [_]usize{ 128, 512, 1024 };
const standard_counts = [_]usize{ 512, 1024, 4096 };
const stress_counts = [_]usize{ 4096, 10000 };

const Fixture = struct {
    data: DataSystem,
    frame: SimulationFrame,
    pathfinding: PathfindingSystem,
    agents: std.ArrayList(EntityId) = .empty,
    obstacle_count: usize = 0,

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.agents.deinit(allocator);
        self.pathfinding.deinit();
        self.frame.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &quick_counts,
        .standard => &standard_counts,
        .stress => &stress_counts,
    };
}

pub fn createFixture(allocator: std.mem.Allocator, count: usize) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    var frame = SimulationFrame.init(allocator);
    errdefer frame.deinit();
    try frame.reserveStreams(suite.rangeCount(count, steering_range_alignment_items), 0, count, 0, 0, 0);
    try frame.reservePathRequests(suite.rangeCount(count, steering_range_alignment_items), count);
    var pathfinding = PathfindingSystem.init(allocator);
    errdefer pathfinding.deinit();
    try pathfinding.reserve(.{
        .max_frame_requests = count,
        .max_pending_requests = count,
        .max_cached_results = count * 2,
        .max_group_fields = 4,
        .worker_participant_count = 1,
        .max_solved_requests_per_step = count,
    });
    var agents = std.ArrayList(EntityId).empty;
    errdefer agents.deinit(allocator);
    try agents.ensureTotalCapacity(allocator, count);

    const side = gridSide(count);
    for (0..count) |index| {
        agents.appendAssumeCapacity(try addAgent(&data, index, side));
    }

    var obstacle_count: usize = 0;
    for (0..@min(@as(usize, 16), side)) |index| {
        _ = try addStatic(&data, nearStaticPosition(index));
        obstacle_count += 1;
    }

    const world_extent = @as(f32, @floatFromInt(side + 4)) * 32.0;
    try pathfinding.rebuildStaticNavGrid(&data, world_extent, world_extent, 32.0);

    return .{ .data = data, .frame = frame, .pathfinding = pathfinding, .agents = agents, .obstacle_count = obstacle_count };
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try createFixture(allocator, item_count);
    defer fixture.deinit(allocator);
    const measured = try measureCase(allocator, io, options, case, item_count, &fixture, &fixture, runOnce);
    var stats = measured.stats;
    stats.candidate_pairs = measured.last.agent_candidate_checks + measured.last.obstacle_candidate_checks;
    stats.sample_count = measured.last.agent_neighbor_samples + measured.last.obstacle_samples;
    return stats;
}

const MeasuredCase = struct {
    stats: suite.RunStats,
    last: SteeringStats,
};

// Warms up, settles the adaptive tuner, and times `step(context)` over `steering`'s agents and
// statics.
fn measureCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: suite.Options,
    case: suite.BenchmarkCase,
    item_count: usize,
    steering: *const Fixture,
    context: anytype,
    comptime step: fn (*SteeringSystem, @TypeOf(context), ?*ThreadSystem, suite.BenchmarkCase) anyerror!SteeringStats,
) !MeasuredCase {
    var system = SteeringSystem.init(allocator);
    defer system.deinit();
    try system.reserveForCapacity(steering.agents.items.len, steering.obstacle_count);
    if (suite.adaptiveTunerForCase(case, steering_range_alignment_items)) |tuner| {
        system.adaptive_tuner = tuner;
    }

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;

    for (0..options.warmup_iterations) |_| {
        _ = try step(&system, context, thread_ptr, case);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!system.adaptive_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try step(&system, context, thread_ptr, case);
        }
    }
    const settled_before_measurement = if (case.adaptive) system.adaptive_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = SteeringStats{};
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_stats = try step(&system, context, thread_ptr, case);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.batch);
    }

    var stats = accumulator.finish();
    stats.output_count = last_stats.movement_intent_count;
    stats.secondary_batch = suite.batchSummaryFromBatch(BatchStats{});
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.adaptive_tuner.report(), settled_before_measurement);
    }
    return .{ .stats = stats, .last = last_stats };
}

fn runOnce(system: *SteeringSystem, fixture: *Fixture, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase) !SteeringStats {
    fixture.frame.beginStep();
    return try steeringStep(system, fixture, thread_system, case);
}

// Navigation intents for every agent, then the steering update for `case`.
fn steeringStep(system: *SteeringSystem, fixture: *Fixture, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase) !SteeringStats {
    try appendNavigationIntents(&fixture.frame, fixture.agents.items);
    if (!case.usesThreadSystem()) {
        return try system.updateSerial(&fixture.data, &fixture.frame, &fixture.pathfinding, .{});
    }
    return try system.update(&fixture.data, &fixture.frame, thread_system.?, &fixture.pathfinding, .{
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

fn benchmarkItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(steering_range_alignment_items) orelse
        suite.alignItemCount(suite.default_items_per_range, steering_range_alignment_items);
}

fn appendNavigationIntents(frame: *SimulationFrame, agents: []const EntityId) !void {
    try frame.navigation_intents.prepareRangeCounts(1);
    frame.navigation_intents.addCount(0, agents.len);
    try frame.navigation_intents.prefix();
    var writer = frame.navigation_intents.rangeWriter(0);
    for (agents, 0..) |entity, index| {
        writer.write(NavigationIntent{
            .entity = entity,
            .goal = .{ .x = 640.0, .y = 360.0 },
            .direct_direction_x = if (index % 2 == 0) 1 else -1,
            .direct_direction_y = if (index % 3 == 0) 0.5 else 0,
            .priority = 1,
        });
    }
    writer.finish();
    frame.navigation_intents.finishWrite();
}

// Agent `index` of a `side`-wide grid at the 18-px agent pitch.
fn addAgent(data: *DataSystem, index: usize, side: usize) !EntityId {
    const entity = try data.createEntity();
    const x: f32 = @floatFromInt(index % side);
    const y: f32 = @floatFromInt(index / side);
    const position = math.Vec2{ .x = x * 18.0, .y = y * 18.0 };
    try data.setMovementBody(entity, .{
        .position = position,
        .previous_position = position,
        .velocity = .{},
        .speed = 32,
    });
    try data.setSteeringAgent(entity, .{
        .agent_radius = 7,
        .waypoint_tolerance = 5,
        .avoidance_radius = 44,
        .avoidance_weight = 1.25,
        .max_neighbor_samples = 12,
        .stuck_step_threshold = 12,
        .replan_cooldown_steps = 8,
        .unavailable_backoff_steps = 30,
    });
    return entity;
}

// A solid static collision body with its minimum corner at `position`.
fn addStatic(data: *DataSystem, position: math.Vec2) !EntityId {
    const obstacle = try data.createEntity();
    try data.setMovementBody(obstacle, .{
        .position = position,
        .previous_position = position,
        .velocity = .{},
        .speed = 0,
    });
    try data.setCollisionBounds(obstacle, .{ .size = .{ .x = static_size, .y = static_size } });
    try data.setCollisionResponse(obstacle, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    return obstacle;
}

// Static `index` of the row placed among the agents.
fn nearStaticPosition(index: usize) math.Vec2 {
    return .{ .x = @as(f32, @floatFromInt(index)) * 72.0 + 36.0, .y = 96.0 };
}

fn gridSide(count: usize) usize {
    var side: usize = 1;
    while (side * side < count) : (side += 1) {}
    return side;
}

// ----------------------------------------------------------------------------
// Static change: one static moved and committed, then one steering step.
// ----------------------------------------------------------------------------

const static_change_counts = [_]usize{ 10, 1_000, 10_000 };
// Fixed agent population; the threaded case dispatches the steering stage to workers at it.
const static_change_agent_count: usize = 4096;
// Statics among the agents, the same at every static count.
const near_static_count: usize = 8;
const static_size: f32 = 28;
const statics_per_filler_chunk: usize = 16;
// Filler statics sit on a 4x4 grid in their chunk.
const filler_grid_side: usize = 4;
const nav_cell_size: f32 = 32.0;
const chunk_px: f32 = @as(f32, @floatFromInt(default_chunk_size_tiles)) * nav_cell_size;
// First chunk column of the filler block; one empty chunk column separates it from the agents.
const filler_origin_chunk_x: usize = 4;
// The mover's set_movement_body emits one structural event.
const static_move_event_count: usize = 1;

const StaticChangeFixture = struct {
    steering: Fixture,
    mover: EntityId,
    // The mover alternates between these two filler-block chunks.
    mover_positions: [2]math.Vec2,
    at_second: bool = false,

    fn deinit(self: *StaticChangeFixture, allocator: std.mem.Allocator) void {
        self.steering.deinit(allocator);
        self.* = undefined;
    }
};

fn staticChangeItemCounts(_: suite.Profile) []const usize {
    return &static_change_counts;
}

// `static_count` statics: `near_static_count` among the agents, one mover, and the rest as
// filler at `statics_per_filler_chunk` per chunk in a square chunk block right of the agents,
// so the block's side grows with the square root of the static count.
fn createStaticChangeFixture(allocator: std.mem.Allocator, static_count: usize) !StaticChangeFixture {
    if (static_count < near_static_count + 1) return error.TooFewStatics;
    const agent_count = static_change_agent_count;
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    var frame = SimulationFrame.init(allocator);
    errdefer frame.deinit();
    const range_count = suite.rangeCount(agent_count, steering_range_alignment_items);
    try frame.reserveStreams(range_count, static_move_event_count, agent_count, 0, 0, 1);
    try frame.reservePathRequests(range_count, agent_count);
    var pathfinding = PathfindingSystem.init(allocator);
    errdefer pathfinding.deinit();
    try pathfinding.reserve(.{
        .max_frame_requests = agent_count,
        .max_pending_requests = agent_count,
        .max_cached_results = agent_count * 2,
        .max_group_fields = 4,
        .worker_participant_count = 1,
        .max_solved_requests_per_step = agent_count,
    });
    var agents = std.ArrayList(EntityId).empty;
    errdefer agents.deinit(allocator);
    try agents.ensureTotalCapacity(allocator, agent_count);

    const side = gridSide(agent_count);
    for (0..agent_count) |index| {
        agents.appendAssumeCapacity(try addAgent(&data, index, side));
    }
    // Every agent's obstacle query (avoidance plus agent radius, padded by the static
    // half-size) ends left of the empty chunk column before the filler block.
    const agent_extent = @as(f32, @floatFromInt(side - 1)) * 18.0 + 44.0 + 7.0 + static_size * 0.5;
    std.debug.assert(agent_extent < @as(f32, @floatFromInt(filler_origin_chunk_x - 1)) * chunk_px);
    for (0..near_static_count) |index| {
        _ = try addStatic(&data, nearStaticPosition(index));
    }

    const filler_count = static_count - near_static_count - 1;
    // At least two chunks so the mover always has two to alternate between.
    const filler_chunks = @max(@as(usize, 2), (filler_count + statics_per_filler_chunk - 1) / statics_per_filler_chunk);
    const block_side = std.math.sqrt(filler_chunks - 1) + 1;
    std.debug.assert(block_side * block_side >= filler_chunks);
    for (0..filler_count) |index| {
        const chunk = fillerChunkOrigin(index / statics_per_filler_chunk, block_side);
        const slot = index % statics_per_filler_chunk;
        const slot_pitch = chunk_px / @as(f32, @floatFromInt(filler_grid_side));
        _ = try addStatic(&data, .{
            .x = chunk.x + @as(f32, @floatFromInt(slot % filler_grid_side)) * slot_pitch + 32.0,
            .y = chunk.y + @as(f32, @floatFromInt(slot / filler_grid_side)) * slot_pitch + 32.0,
        });
    }
    // Between filler slots, so the mover overlaps no other static.
    const mover_offset = math.Vec2{ .x = 96.0, .y = 96.0 };
    const first_chunk = fillerChunkOrigin(0, block_side);
    const second_chunk = fillerChunkOrigin(1, block_side);
    const mover_positions = [2]math.Vec2{
        .{ .x = first_chunk.x + mover_offset.x, .y = first_chunk.y + mover_offset.y },
        .{ .x = second_chunk.x + mover_offset.x, .y = second_chunk.y + mover_offset.y },
    };
    const mover = try addStatic(&data, mover_positions[0]);

    // Nav covers the agents and the whole filler block, so no static clamps onto an edge cell.
    const nav_width = @as(f32, @floatFromInt(filler_origin_chunk_x + block_side)) * chunk_px;
    const nav_height = @max(@as(f32, @floatFromInt(block_side)) * chunk_px, @as(f32, @floatFromInt(side + 4)) * nav_cell_size);
    try pathfinding.rebuildStaticNavGrid(&data, nav_width, nav_height, nav_cell_size);

    return .{
        .steering = .{ .data = data, .frame = frame, .pathfinding = pathfinding, .agents = agents, .obstacle_count = static_count },
        .mover = mover,
        .mover_positions = mover_positions,
    };
}

// World-space minimum corner of filler chunk `chunk_index` in a `block_side`-wide block.
fn fillerChunkOrigin(chunk_index: usize, block_side: usize) math.Vec2 {
    return .{
        .x = @as(f32, @floatFromInt(filler_origin_chunk_x + chunk_index % block_side)) * chunk_px,
        .y = @as(f32, @floatFromInt(chunk_index / block_side)) * chunk_px,
    };
}

fn runStaticChangeCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try createStaticChangeFixture(allocator, item_count);
    defer fixture.deinit(allocator);
    const measured = try measureCase(allocator, io, options, case, item_count, &fixture.steering, &fixture, staticChangeOnce);
    var stats = measured.stats;
    stats.candidate_pairs = measured.last.obstacle_candidate_checks;
    stats.sample_count = measured.last.obstacle_samples;
    return stats;
}

// One step: the mover's set_movement_body committed, the steering post-commit reaction, then
// navigation intents and the steering update.
fn staticChangeOnce(system: *SteeringSystem, fixture: *StaticChangeFixture, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase) !SteeringStats {
    const frame = &fixture.steering.frame;
    frame.beginStep();
    const target = if (fixture.at_second) fixture.mover_positions[0] else fixture.mover_positions[1];
    try frame.structural_commands.prepareRangeCounts(1);
    frame.structural_commands.addCount(0, 1);
    try frame.structural_commands.prefix();
    var writer = frame.structural_commands.rangeWriter(0);
    writer.write(.{ .set_movement_body = .{
        .entity = fixture.mover,
        .body = .{ .position = target, .previous_position = target, .velocity = .{}, .speed = 0 },
    } });
    writer.finish();
    frame.structural_commands.finishWrite();
    const commit = try frame.applyStructuralCommandsBudgeted(&fixture.steering.data, .{});
    if (commit.components_set != 1) return error.StaticMoveNotApplied;
    fixture.at_second = !fixture.at_second;
    system.reactToPostCommitSteeringEvents(frame);

    const stats = try steeringStep(system, &fixture.steering, thread_system, case);
    if (stats.movement_intent_count != fixture.steering.agents.items.len) return error.AgentIntentMissing;
    if (stats.obstacle_samples == 0) return error.NearStaticsUnsampled;
    return stats;
}
