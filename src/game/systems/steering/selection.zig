// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Steering intent selection, `select_resolve` and `select_claim`: one intent per steering
//! row, its first in source order and its best by priority. Free functions over
//! `*SteeringSystem`; its step calls `selectIntents`.

const std = @import("std");
const runtime_perf_log = @import("../../../app/runtime_perf_log.zig");
const BandPartition = @import("../../../app/thread_system.zig").BandPartition;
const PaddedSlot = @import("../../../app/thread_system.zig").PaddedSlot;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const setRowCount = @import("../../../app/thread_system.zig").setRowCount;
const setSlotCount = @import("../../../app/thread_system.zig").setSlotCount;
const DataSystem = @import("../../data_system.zig").DataSystem;
const NavigationIntent = @import("../../simulation.zig").NavigationIntent;
const OwnedBands = @import("../banded_sort.zig").OwnedBands;
const steering_range_alignment_items = @import("system.zig").steering_range_alignment_items;
const max_bands = @import("system.zig").max_bands;
const StageThreads = @import("system.zig").StageThreads;
const SteeringStats = @import("system.zig").SteeringStats;
const SteeringSystem = @import("system.zig").SteeringSystem;
const BandRow = @import("system.zig").BandRow;

// `OwnedBands` indexes `starts` at `band_count`, so the widths match.
comptime {
    std.debug.assert(max_bands == @import("../banded_sort.zig").band_count);
}

// An intent with no steering row, or a claim field not yet written this step.
pub const no_row: u32 = std.math.maxInt(u32);

// Steering rows per claim block; a band owns whole blocks.
const band_block_rows: usize = steering_range_alignment_items;

/// `select_resolve`, then `select_claim`. Each stage runs inline or on workers as its tuner
/// selects, including when no worker is available: ranges resolve their intents and place
/// them by steering band in their window; a claim range is a span of the placed intents and
/// owns every nonempty band whose start lies in the span, claiming that band's steering rows
/// from every resolve range's segment in range order. A band is never split. The bands follow
/// the steering rows only, never the resolve partition. Each steering row gets its first
/// intent in source order and its best by priority, ties to the earlier.
pub fn selectIntents(
    self: *SteeringSystem,
    data: *const DataSystem,
    agent_count: usize,
    intents: []const NavigationIntent,
    threads: StageThreads,
    stats: *SteeringStats,
) void {
    const intent_count = intents.len;
    setRowCount(IntentRow, &self.intent_rows, intent_count);
    const intent_rows = self.intent_rows.slice();
    const claims = claimColumns(self.claims.slice());
    const resolve_stage = threads.stage(&self.select_resolve_tuner);
    const selection = resolve_stage.select(intent_count, steering_range_alignment_items);
    const bands = AgentBands.init(agent_count);
    setSlotCount(BandRow, &self.band_rows, selection.range_count);
    std.debug.assert(self.intent_buckets.capacity >= intent_count);
    self.intent_buckets.items.len = intent_count;
    var resolve = ResolveJob{
        .data = data,
        .intents = intents,
        .intent_steering = intent_rows.items(.steering),
        .intent_movement = intent_rows.items(.movement),
        .buckets = self.intent_buckets.items,
        .bands = bands,
        .items_per_range = selection.items_per_range,
        .band_rows = self.band_rows.items,
    };
    const resolve_batch = resolve_stage.run(selection, intent_count, steering_range_alignment_items, &resolve, resolveJob);
    if (comptime runtime_perf_log.enabled) stats.perf.select_resolve_batch = resolve_batch;

    const starts = placedBandStarts(self.band_rows.items, bands.band_count);
    // Placed intents are a u32 count, at most the intent count.
    const placed: usize = @intCast(starts[max_bands]);
    const claim_stage = threads.stage(&self.select_claim_tuner);
    const claim_selection = claim_stage.select(placed, steering_range_alignment_items);
    var claim = ClaimJob{
        .intents = intents,
        .intent_steering = intent_rows.items(.steering),
        .buckets = self.intent_buckets.items,
        .band_rows = self.band_rows.items,
        .resolve_items_per_range = selection.items_per_range,
        .bands = bands,
        .starts = starts,
        .claims = claims,
        .stamp = self.claim_stamp,
        .range_count = claim_selection.range_count,
    };
    const claim_batch = claim_stage.run(claim_selection, placed, steering_range_alignment_items, &claim, claimJob);
    if (comptime runtime_perf_log.enabled) stats.perf.select_claim_batch = claim_batch;
}

// An intent's dense indices; `no_row` when its entity is not a steering agent with a body.
pub const IntentRow = struct {
    steering: u32 = no_row,
    movement: u32 = no_row,
};

/// A steering row's first intent this step (source order) and its best (priority, ties to
/// the earlier), valid while `stamp` equals the system's `claim_stamp`.
pub const Claim = struct {
    stamp: u32 = 0,
    first: u32 = 0,
    best: u32 = 0,
};

const ClaimColumns = struct {
    stamp: []u32,
    first: []u32,
    best: []u32,
};

fn claimColumns(claims: std.MultiArrayList(Claim).Slice) ClaimColumns {
    return .{ .stamp = claims.items(.stamp), .first = claims.items(.first), .best = claims.items(.best) };
}

// The partition of steering rows into bands of whole `band_block_rows` blocks.
pub const AgentBands = BandPartition(band_block_rows, max_bands);

fn resolveIntentRow(data: *const DataSystem, intent: NavigationIntent) IntentRow {
    // One slot resolve for both dense indices (not movement + steering separately).
    const indices = data.movementSteeringDenseIndices(intent.entity) orelse return .{};
    // Dense indices fit u32: steering rows by `max_step_items`, movement rows by their
    // store's u32 row cap.
    return .{ .steering = @intCast(indices.steering), .movement = @intCast(indices.movement) };
}

// Claims steering row `row` for intent `intent_index`: the row's first claim this step takes
// both first and best; a later one replaces best only at a higher priority, so ties keep
// the earlier source order. Claims of one row arrive in source order.
fn claimRow(claims: ClaimColumns, stamp: u32, row: usize, intent_index: u32, intents: []const NavigationIntent) void {
    if (claims.stamp[row] != stamp) {
        claims.stamp[row] = stamp;
        claims.first[row] = intent_index;
        claims.best[row] = intent_index;
        return;
    }
    std.debug.assert(intent_index > claims.best[row]);
    if (intents[intent_index].priority > intents[claims.best[row]].priority) claims.best[row] = intent_index;
}

// `select_resolve`: one range of intents.
const ResolveJob = struct {
    data: *const DataSystem,
    intents: []const NavigationIntent,
    intent_steering: []u32,
    intent_movement: []u32,
    // Range r's window starts at `r * items_per_range`.
    buckets: []u32,
    bands: AgentBands,
    items_per_range: usize,
    band_rows: []PaddedSlot(BandRow),
};

// Resolves the range's intents, then places each resolved intent's index in the range's
// window by steering band, in source order within a band, and records the band offsets.
fn resolveJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *ResolveJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.band_rows.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.intents.len and range.end <= job.buckets.len);
    std.debug.assert(range.end <= job.intent_steering.len and range.end <= job.intent_movement.len);
    const band_count = job.bands.band_count;
    var offsets: [max_bands + 1]u32 = @splat(0);
    for (range.start..range.end) |intent_index| {
        const resolved = resolveIntentRow(job.data, job.intents[intent_index]);
        job.intent_steering[intent_index] = resolved.steering;
        job.intent_movement[intent_index] = resolved.movement;
        if (resolved.steering != no_row) offsets[job.bands.bandOfRow(resolved.steering) + 1] += 1;
    }
    for (1..band_count + 1) |band| offsets[band] += offsets[band - 1];
    job.band_rows[range.index].value.offsets = offsets;
    var cursor = offsets;
    for (range.start..range.end) |intent_index| {
        const row = job.intent_steering[intent_index];
        if (row == no_row) continue;
        const band = job.bands.bandOfRow(row);
        // Intent indices fit u32 (`max_step_items`).
        job.buckets[range.start + cursor[band]] = @intCast(intent_index);
        cursor[band] += 1;
    }
}

// Band b's start among placed intents, over every resolve range. `offsets[b]` counts the
// placed intents of earlier bands, so the sum is that start; entries past `band_count`
// equal the placed total.
fn placedBandStarts(band_rows: []const PaddedSlot(BandRow), band_count: usize) [max_bands + 1]u32 {
    std.debug.assert(band_count <= max_bands);
    var starts: [max_bands + 1]u32 = @splat(0);
    for (band_rows) |slot| {
        for (starts[0 .. band_count + 1], slot.value.offsets[0 .. band_count + 1]) |*start, offset| {
            start.* += offset;
        }
    }
    const placed = starts[band_count];
    for (starts[band_count + 1 ..]) |*tail| tail.* = placed;
    return starts;
}

// `select_claim`: one range of placed intents.
const ClaimJob = struct {
    intents: []const NavigationIntent,
    intent_steering: []const u32,
    buckets: []const u32,
    band_rows: []const PaddedSlot(BandRow),
    resolve_items_per_range: usize,
    bands: AgentBands,
    // Band starts among the placed intents; `starts[max_bands]` is the placed count.
    starts: [max_bands + 1]u32,
    claims: ClaimColumns,
    stamp: u32,
    range_count: usize,
};

// The range owns each nonempty band whose placed start lies in it. That band claims its
// steering rows from every resolve range's band segment in range order, which is source order.
fn claimJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *ClaimJob = @ptrCast(@alignCast(context));
    const placed = job.starts[max_bands];
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= placed);
    const claim_rows = job.claims.stamp.len;
    std.debug.assert(job.claims.first.len == claim_rows and job.claims.best.len == claim_rows);
    var owned = OwnedBands.init(&job.starts, range.start, range.end);
    while (owned.next()) |band| {
        std.debug.assert(band < job.bands.band_count);
        const first_row = job.bands.firstRow(band);
        const end_row = job.bands.firstRow(band + 1);
        std.debug.assert(end_row <= claim_rows);
        for (job.band_rows, 0..) |slot, resolve_range| {
            const window = job.buckets[resolve_range * job.resolve_items_per_range ..];
            for (window[slot.value.offsets[band]..slot.value.offsets[band + 1]]) |intent_index| {
                const row = job.intent_steering[intent_index];
                std.debug.assert(row >= first_row and row < end_row);
                claimRow(job.claims, job.stamp, row, intent_index, job.intents);
            }
        }
    }
}

const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const math = @import("../../../core/math.zig");
const EntityId = @import("../../data_system.zig").EntityId;
const MovementIntent = @import("../../simulation.zig").MovementIntent;
const SimulationFrame = @import("../../simulation.zig").SimulationFrame;
const PathfindingSystem = @import("../pathfinding.zig").PathfindingSystem;
const StaticColliderSystem = @import("../static_colliders.zig").StaticColliderSystem;
const direction_epsilon = @import("directions.zig").direction_epsilon;
const buildSteeredIndex = @import("test_support.zig").buildSteeredIndex;
const updateSteeringInline = @import("test_support.zig").updateSteeringInline;
const selectionIntent = @import("test_support.zig").selectionIntent;
const addSteeredEntity = @import("test_support.zig").addSteeredEntity;
const appendNavigationIntents = @import("test_support.zig").appendNavigationIntents;
const testColliders = @import("test_support.zig").testColliders;

test "steering keeps highest priority navigation intent with stable tie order" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 1, .worker_participant_count = 1 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);
    var colliders = try testColliders(&pathfinding, &data, 160, 160, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntents(&frame, &.{
        .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1, .priority = 0 },
        .{ .entity = agent, .goal = .{ .x = 0, .y = 96 }, .direct_direction_y = 1, .priority = 10 },
        .{ .entity = agent, .goal = .{ .x = 96, .y = 96 }, .direct_direction_x = 1, .direct_direction_y = 1, .priority = 10 },
    });
    const stats = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 3), stats.navigation_intent_count);
    try std.testing.expectEqual(@as(usize, 1), stats.selected_intent_count);
    const intent = frame.intents.mergedItems()[0].movement;
    try std.testing.expect(intent.direction_y > 0.9);
    try std.testing.expect(@abs(intent.direction_x) < 0.01);
}

test "steering threaded arbitration keeps the first appearance and the best intent across ranges" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Far enough apart that no agent pushes another.
    var agents: [40]EntityId = undefined;
    for (&agents, 0..) |*agent, index| {
        agent.* = try addSteeredEntity(&data, .{ .x = @floatFromInt(index % 8 * 200), .y = @floatFromInt(index / 8 * 200) });
    }
    // No nav grid: every path is unavailable, so each agent steers along its intent's
    // direct direction.
    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 1, .worker_participant_count = 1 });
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();

    // Six 16-intent ranges. Every agent's first intent comes in agent order; a second
    // intent per agent a range or more later beats it (priority 2), ties it (1, the first
    // keeps), or loses (0); a third for the first 16 agents ties a priority-2 second or
    // beats the rest.
    var intents: [96]NavigationIntent = undefined;
    for (0..40) |index| intents[index] = selectionIntent(agents[index], index, 0, 1);
    for (0..40) |index| {
        const agent = index * 7 % 40;
        intents[40 + index] = selectionIntent(agents[agent], agent, 1, @as(i16, 2) - @as(i16, @intCast(index % 3)));
    }
    for (0..16) |index| intents[80 + index] = selectionIntent(agents[index], index, 2, 2);
    // The reference: per agent the highest priority, ties to the earliest.
    var best: [40]usize = undefined;
    for (&best, 0..) |*slot, index| slot.* = index;
    for (intents[40..], 40..) |intent, source_order| {
        const agent = for (agents, 0..) |candidate, index| {
            if (candidate.eql(intent.entity)) break index;
        } else unreachable;
        if (intent.priority > intents[best[agent]].priority) best[agent] = source_order;
    }

    var outputs: [2][40]MovementIntent = undefined;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = steering_range_alignment_items });
    defer threads.deinit();
    var index = try buildSteeredIndex(&data);
    defer index.deinit();
    for (&outputs, 0..) |*output, run| {
        var frame = SimulationFrame.init(std.testing.allocator);
        defer frame.deinit();
        try frame.reserveStreams(8, 0, intents.len, 0, 0, 0);
        try frame.reservePathRequests(8, intents.len);
        var steering = SteeringSystem.init(std.testing.allocator);
        defer steering.deinit();
        try steering.reserve(intents.len);
        frame.beginStep();
        try appendNavigationIntents(&frame, &intents);
        const stats = if (run == 0)
            try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders)
        else
            try steering.update(&data, &frame, &threads, &pathfinding, &colliders, index.view(), .{ .items_per_range = steering_range_alignment_items, .max_worker_threads = 2, .adaptive = false });
        try std.testing.expectEqual(@as(usize, 40), stats.selected_intent_count);
        // First appearance order, each agent steering along its best intent.
        for (output, frame.intents.mergedItems(), agents, best) |*slot, merged, agent, best_index| {
            slot.* = merged.movement;
            try std.testing.expect(slot.entity.eql(agent));
            const expected = math.normalizeOrZeroFinite(intents[best_index].direct_direction_x, intents[best_index].direct_direction_y, direction_epsilon);
            try std.testing.expectApproxEqAbs(expected.x, slot.direction_x, 0.00001);
            try std.testing.expectApproxEqAbs(expected.y, slot.direction_y, 0.00001);
        }
    }
    for (outputs[0], outputs[1]) |serial, threaded| {
        try std.testing.expectEqual(@as(u32, @bitCast(serial.direction_x)), @as(u32, @bitCast(threaded.direction_x)));
        try std.testing.expectEqual(@as(u32, @bitCast(serial.direction_y)), @as(u32, @bitCast(threaded.direction_y)));
    }
}

test "steering claims stay correct across the claim stamp wrap" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var agents: [6]EntityId = undefined;
    for (&agents, 0..) |*agent, index| agent.* = try addSteeredEntity(&data, .{ .x = @floatFromInt(index * 200), .y = 0 });
    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 1, .worker_participant_count = 1 });
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();

    // Steps 1 and 3 claim the same rows with different intents, around a wrap.
    const steps = [_][]const NavigationIntent{
        &.{ selectionIntent(agents[0], 0, 0, 1), selectionIntent(agents[1], 1, 0, 1), selectionIntent(agents[2], 2, 0, 1), selectionIntent(agents[0], 0, 1, 3) },
        &.{ selectionIntent(agents[3], 3, 0, 1), selectionIntent(agents[4], 4, 0, 1) },
        &.{ selectionIntent(agents[5], 5, 2, 0), selectionIntent(agents[2], 2, 2, 1), selectionIntent(agents[1], 1, 2, 0), selectionIntent(agents[0], 0, 2, 1), selectionIntent(agents[1], 1, 3, 2) },
    };
    var outputs: [2][steps.len][5]MovementIntent = undefined;
    var counts: [2][steps.len]usize = undefined;
    for (0..2) |run| {
        var frame = SimulationFrame.init(std.testing.allocator);
        defer frame.deinit();
        try frame.reserveStreams(2, 0, 8, 0, 0, 0);
        try frame.reservePathRequests(2, 8);
        var steering = SteeringSystem.init(std.testing.allocator);
        defer steering.deinit();
        try steering.reserve(8);
        for (steps, 0..) |step_intents, step_index| {
            // The second run's middle step takes the last stamp, so its third step wraps.
            if (run == 1 and step_index == 1) steering.claim_stamp = std.math.maxInt(u32) - 1;
            frame.beginStep();
            try appendNavigationIntents(&frame, step_intents);
            const stats = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);
            counts[run][step_index] = stats.selected_intent_count;
            for (frame.intents.mergedItems(), 0..) |merged, index| outputs[run][step_index][index] = merged.movement;
        }
        if (run == 1) try std.testing.expectEqual(@as(u32, 1), steering.claim_stamp);
    }
    try std.testing.expectEqual(counts[0], counts[1]);
    try std.testing.expectEqual(@as(usize, 4), counts[1][2]);
    for (counts[0], outputs[0], outputs[1]) |count, control, wrapped| {
        for (control[0..count], wrapped[0..count]) |expected, actual| {
            try std.testing.expect(expected.entity.eql(actual.entity));
            try std.testing.expectEqual(@as(u32, @bitCast(expected.direction_x)), @as(u32, @bitCast(actual.direction_x)));
            try std.testing.expectEqual(@as(u32, @bitCast(expected.direction_y)), @as(u32, @bitCast(actual.direction_y)));
        }
    }
}

test "steering claims and intents match serial across resolve partitions" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Far enough apart that no agent pushes another.
    var agents: [40]EntityId = undefined;
    for (&agents, 0..) |*agent, index| {
        agent.* = try addSteeredEntity(&data, .{ .x = @floatFromInt(index % 8 * 200), .y = @floatFromInt(index / 8 * 200) });
    }
    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 1, .worker_participant_count = 1 });
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();

    // Each agent's first intent, then a second that beats, ties, or loses to it.
    var intents: [80]NavigationIntent = undefined;
    for (0..40) |index| intents[index] = selectionIntent(agents[index], index, 0, 1);
    for (0..40) |index| {
        const agent = index * 7 % 40;
        intents[40 + index] = selectionIntent(agents[agent], agent, 1, @as(i16, 2) - @as(i16, @intCast(index % 3)));
    }

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = steering_range_alignment_items });
    defer threads.deinit();
    var index = try buildSteeredIndex(&data);
    defer index.deinit();
    // Serial, then five and two resolve ranges.
    const resolve_ranges = [_]?usize{ null, 16, 48 };
    var outputs: [resolve_ranges.len][40]MovementIntent = undefined;
    var claims: [resolve_ranges.len][40]Claim = undefined;
    for (resolve_ranges, &outputs, &claims) |items_per_range, *output, *claim| {
        var frame = SimulationFrame.init(std.testing.allocator);
        defer frame.deinit();
        try frame.reserveStreams(8, 0, intents.len, 0, 0, 0);
        try frame.reservePathRequests(8, intents.len);
        var steering = SteeringSystem.init(std.testing.allocator);
        defer steering.deinit();
        try steering.reserve(intents.len);
        frame.beginStep();
        try appendNavigationIntents(&frame, &intents);
        const stats = if (items_per_range) |range_items|
            try steering.update(&data, &frame, &threads, &pathfinding, &colliders, index.view(), .{ .items_per_range = range_items, .max_worker_threads = 2, .adaptive = false })
        else
            try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);
        try std.testing.expectEqual(@as(usize, 40), stats.selected_intent_count);
        for (output, frame.intents.mergedItems()) |*slot, merged| slot.* = merged.movement;
        for (claim, 0..) |*slot, row| slot.* = steering.claims.get(row);
    }
    for (outputs[1..], claims[1..]) |threaded_output, threaded_claims| {
        for (outputs[0], threaded_output) |want, got| {
            try std.testing.expect(want.entity.eql(got.entity));
            try std.testing.expectEqual(@as(u32, @bitCast(want.direction_x)), @as(u32, @bitCast(got.direction_x)));
            try std.testing.expectEqual(@as(u32, @bitCast(want.direction_y)), @as(u32, @bitCast(got.direction_y)));
        }
        for (claims[0], threaded_claims) |want, got| {
            try std.testing.expectEqual(want.first, got.first);
            try std.testing.expectEqual(want.best, got.best);
        }
    }
}
