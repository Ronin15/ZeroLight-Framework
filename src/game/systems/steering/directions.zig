// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Steering `directions`: path status, progress, and the smoothed base direction of each
//! steering row's selected intent. Free functions over `*SteeringSystem`; its step calls
//! `prepareDirections`.

const std = @import("std");
const PaddedSlot = @import("../../../app/thread_system.zig").PaddedSlot;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const inlineBatch = @import("../../../app/thread_system.zig").inlineBatch;
const setRowCount = @import("../../../app/thread_system.zig").setRowCount;
const setSlotCount = @import("../../../app/thread_system.zig").setSlotCount;
const thread_shared_record_alignment = @import("../../../app/thread_system.zig").thread_shared_record_alignment;
const math = @import("../../../core/math.zig");
const simd = @import("../../../core/simd.zig");
const ConstScopeColumnsSlice = @import("../../data_system.zig").ConstScopeColumnsSlice;
const ConstSteeringAgentSlice = @import("../../data_system.zig").ConstSteeringAgentSlice;
const DataSystem = @import("../../data_system.zig").DataSystem;
const NavigationIntent = @import("../../simulation.zig").NavigationIntent;
const PathfindingSystem = @import("../pathfinding.zig").PathfindingSystem;
const steering_range_alignment_items = @import("system.zig").steering_range_alignment_items;
const movementScopeLevel = @import("system.zig").movementScopeLevel;
const StageThreads = @import("system.zig").StageThreads;
const SteeringStats = @import("system.zig").SteeringStats;
const SteeringSystem = @import("system.zig").SteeringSystem;
const selectedWorkSlice = @import("system.zig").selectedWorkSlice;
const SelectedWorkRow = @import("system.zig").SelectedWorkRow;
const RuntimeRow = @import("system.zig").RuntimeRow;
const SelectedWorkSlice = @import("system.zig").SelectedWorkSlice;
const SelectedIntent = @import("system.zig").SelectedIntent;
const no_row = @import("selection.zig").no_row;

pub const direction_epsilon: f32 = 0.0001;

/// Fraction of the way from the previous emitted direction toward the new
/// target direction each fixed step. `base_dir` can flip discretely — the
/// path/direct-fallback selection toggles while a goal-cell requantization is
/// in flight, a fresh corridor solve replaces a stale waypoint, or a wander
/// epoch changes — and without smoothing each flip snaps the heading in one
/// step, which reads as a wiggle while chasing a moving goal. Blending softens
/// any such flip into a turn over several steps (~10 steps to mostly converge
/// at 60Hz) instead of an instant snap, while staying responsive enough not to
/// lag behind a genuinely moving goal.
const steering_turn_smoothing: f32 = 0.15;

/// `directions` over the intents: each intent that is its steering row's first this step
/// emits the row's best intent into its range's window, then the main thread lays the
/// windows out in range order.
pub fn prepareDirections(
    self: *SteeringSystem,
    data: *const DataSystem,
    steering: ConstSteeringAgentSlice,
    intents: []const NavigationIntent,
    pathfinding: *const PathfindingSystem,
    threads: ?StageThreads,
    stats: *SteeringStats,
) void {
    const intent_count = intents.len;
    std.debug.assert(self.selected.capacity >= intent_count);
    self.selected.items.len = intent_count;
    setRowCount(SelectedWorkRow, &self.selected_work_rows, intent_count);
    const movement = data.movementBodySliceConst();
    const intent_rows = self.intent_rows.slice();
    const claims = self.claims.slice();
    var job = DirectionsJob{
        .pathfinding = pathfinding,
        .intents = intents,
        .intent_steering = intent_rows.items(.steering),
        .intent_movement = intent_rows.items(.movement),
        .claim_stamps = claims.items(.stamp),
        .claim_first = claims.items(.first),
        .claim_best = claims.items(.best),
        .stamp = self.claim_stamp,
        .steering = steering,
        .previous_x = movement.previous_x,
        .previous_y = movement.previous_y,
        .scope = data.scopeColumnsSliceConst(),
        .runtime = self.runtime_rows.slice(),
        .selected = self.selected.items,
        .work = selectedWorkSlice(self),
        .items_per_range = intent_count,
        .tallies = &.{},
    };
    var range_count: usize = 1;
    if (threads) |stage| {
        const directions = stage.stage(&self.directions_tuner);
        const selection = directions.select(intent_count, steering_range_alignment_items);
        setSlotCount(DirectionsTally, &self.directions_tallies, selection.range_count);
        job.items_per_range = selection.items_per_range;
        job.tallies = self.directions_tallies.items;
        stats.directions_batch = directions.run(selection, intent_count, steering_range_alignment_items, &job, directionsJob);
        range_count = selection.range_count;
    } else {
        setSlotCount(DirectionsTally, &self.directions_tallies, 1);
        job.tallies = self.directions_tallies.items;
        directionsJob(&job, .{ .index = 0, .start = 0, .end = intent_count }, WorkerId.main);
        stats.directions_batch = inlineBatch(intent_count, steering_range_alignment_items);
    }

    self.selected_windows.clearRetainingCapacity();
    std.debug.assert(self.selected_windows.capacity >= range_count);
    var selected_count: usize = 0;
    var request_count: usize = 0;
    for (self.directions_tallies.items[0..range_count], 0..) |slot, range_index| {
        const tally = slot.value;
        self.selected_windows.appendAssumeCapacity(.{
            .start = range_index * job.items_per_range,
            .count = tally.count,
            .logical_base = selected_count,
            .request_base = request_count,
        });
        selected_count += tally.count;
        request_count += tally.requests;
        stats.path_available_count += tally.available;
        stats.path_partial_count += tally.partial;
        stats.path_pending_count += tally.pending;
        stats.path_unavailable_count += tally.unavailable;
        stats.replan_cooldown_count += tally.cooldowns;
        stats.unavailable_backoff_count += tally.backoffs;
        stats.stuck_replan_count += tally.stuck_replans;
    }
    stats.selected_intent_count = selected_count;
    stats.path_request_count = request_count;
}

/// One directions range's selected intents: `count` from `start` in `selected`, at selected
/// positions from `logical_base`, after `request_base` earlier path requests.
pub const SelectedWindow = struct {
    start: usize,
    count: usize,
    logical_base: usize,
    request_base: usize,
};

pub const DirectionsTally = struct {
    count: usize = 0,
    requests: usize = 0,
    available: usize = 0,
    partial: usize = 0,
    pending: usize = 0,
    unavailable: usize = 0,
    cooldowns: usize = 0,
    backoffs: usize = 0,
    stuck_replans: usize = 0,
};

comptime {
    std.debug.assert(@sizeOf(PaddedSlot(DirectionsTally)) % thread_shared_record_alignment == 0);
}

const SteeringAgentView = struct {
    agent_radius: f32,
    waypoint_tolerance: f32,
    avoidance_radius: f32,
    avoidance_weight: f32,
    max_neighbor_samples: u16,
    stuck_step_threshold: u16,
    replan_cooldown_steps: u16,
    unavailable_backoff_steps: u16,
};

const PathDirection = struct {
    has_direction: bool = false,
    direction: math.Vec2 = .{},
    status_allows_replan: bool = false,
    // Distance from the agent to the point it is actually steering toward this step
    // (the next path waypoint, or the goal when steering direct). Stuck detection
    // measures progress against this, not the straight-line goal distance, so an
    // agent correctly walking a detour around an obstacle is not flagged stuck.
    progress_distance: f32 = 0,
};

// `directions`: one range of intents.
const DirectionsJob = struct {
    pathfinding: *const PathfindingSystem,
    intents: []const NavigationIntent,
    intent_steering: []const u32,
    intent_movement: []const u32,
    claim_stamps: []const u32,
    claim_first: []const u32,
    claim_best: []const u32,
    stamp: u32,
    steering: ConstSteeringAgentSlice,
    previous_x: []const f32,
    previous_y: []const f32,
    scope: ConstScopeColumnsSlice,
    // Written only at the steering rows of the range's selected intents, each selected once.
    runtime: std.MultiArrayList(RuntimeRow).Slice,
    // Range r's window starts at `r * items_per_range`.
    selected: []SelectedIntent,
    work: SelectedWorkSlice,
    items_per_range: usize,
    tallies: []PaddedSlot(DirectionsTally),
};

// Each intent that is its steering row's first this step emits the row's best intent into
// the next slot of the range's window: path status and progress per intent (scalar: a
// cache probe, a field sample, and a waypoint walk), then the direction tail per block of
// four in lanes.
fn directionsJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *DirectionsJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.tallies.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.intents.len and range.end <= job.intent_steering.len);
    std.debug.assert(range.end <= job.selected.len and range.end <= job.work.len());
    // Runtime rows are written at intents' steering rows, which index the claims.
    std.debug.assert(job.runtime.len == job.steering.entities.len and job.claim_first.len == job.runtime.len);
    var runtime = job.runtime;
    var tally = DirectionsTally{};
    var tail = DirectionTail{};
    const sink = DirectionTailSink{
        .base_x = job.work.base_dir_x,
        .base_y = job.work.base_dir_y,
        .prev_x = runtime.items(.prev_dir_x),
        .prev_y = runtime.items(.prev_dir_y),
        .has_prev = runtime.items(.has_prev_dir),
    };
    for (range.start..range.end) |intent_index| {
        const row = job.intent_steering[intent_index];
        if (row == no_row or job.claim_first[row] != intent_index) continue;
        std.debug.assert(job.claim_stamps[row] == job.stamp);
        const best = job.claim_best[row];
        const intent = job.intents[best];
        const movement_index = job.intent_movement[best];
        const slot = range.start + tally.count;
        const agent = steeringAgentAt(job.steering, row);
        const start = math.Vec2{ .x = job.previous_x[movement_index], .y = job.previous_y[movement_index] };
        const start_level = movementScopeLevel(job.scope, movement_index);

        var state = runtime.get(row);
        var emit_request = false;
        const path_dir = directionFromPathStatus(job.pathfinding, intent, start, start_level, agent, &state, &tally, &emit_request);
        updateProgress(&state, path_dir.progress_distance, agent, path_dir.status_allows_replan, &tally, &emit_request);
        runtime.set(row, state);

        job.selected[slot] = .{ .entity = intent.entity, .intent = intent };
        job.work.start_x[slot] = start.x;
        job.work.start_y[slot] = start.y;
        job.work.final_dir_x[slot] = 0;
        job.work.final_dir_y[slot] = 0;
        job.work.selected_agent_radii[slot] = agent.agent_radius;
        job.work.selected_avoidance_radii[slot] = agent.avoidance_radius;
        job.work.selected_avoidance_weights[slot] = agent.avoidance_weight;
        job.work.selected_max_neighbor_samples[slot] = agent.max_neighbor_samples;
        job.work.selected_world_level[slot] = start_level;
        // At most one request per intent, so the count fits u32 (`max_step_items`).
        job.work.request_prefix[slot] = @intCast(tally.requests);
        job.work.emit_request[slot] = emit_request;
        if (emit_request) tally.requests += 1;
        tally.count += 1;

        tail.push(slot, row, .{
            .has_path = path_dir.has_direction,
            .path_x = path_dir.direction.x,
            .path_y = path_dir.direction.y,
            .direct_x = intent.direct_direction_x,
            .direct_y = intent.direct_direction_y,
            .prev_x = state.prev_dir_x,
            .prev_y = state.prev_dir_y,
            .has_prev = state.has_prev_dir,
        });
        if (tail.count == simd.lane_count) tail.finish(sink);
    }
    tail.finish(sink);
    job.tallies[range.index].value = tally;
}

// One selected intent's inputs to the direction tail: the path direction when the path
// gives one, the intent's raw direct direction, and its runtime row's previous direction.
const DirectionTailInput = struct {
    has_path: bool,
    path_x: f32,
    path_y: f32,
    direct_x: f32,
    direct_y: f32,
    prev_x: f32,
    prev_y: f32,
    has_prev: bool,
};

// Where the tail writes: base directions by selected slot, previous directions by
// steering row.
const DirectionTailSink = struct {
    base_x: []f32,
    base_y: []f32,
    prev_x: []f32,
    prev_y: []f32,
    has_prev: []bool,
};

// Up to one lane block of pending direction tails.
const DirectionTail = struct {
    inputs: [simd.lane_count]DirectionTailInput = undefined,
    slots: [simd.lane_count]usize = undefined,
    rows: [simd.lane_count]usize = undefined,
    count: usize = 0,

    fn push(self: *DirectionTail, slot: usize, row: usize, input: DirectionTailInput) void {
        std.debug.assert(self.count < simd.lane_count);
        self.inputs[self.count] = input;
        self.slots[self.count] = slot;
        self.rows[self.count] = row;
        self.count += 1;
    }

    // Writes each pending base direction to its slot and makes it its row's previous
    // direction: a full block in lanes, a partial block per item.
    fn finish(self: *DirectionTail, sink: DirectionTailSink) void {
        var bases: [simd.lane_count]math.Vec2 = undefined;
        if (self.count == simd.lane_count) {
            bases = smoothDirectionLanes(&self.inputs);
        } else {
            for (self.inputs[0..self.count], bases[0..self.count]) |input, *base| base.* = smoothDirectionScalar(input);
        }
        for (bases[0..self.count], self.slots[0..self.count], self.rows[0..self.count]) |base, slot, row| {
            sink.base_x[slot] = base.x;
            sink.base_y[slot] = base.y;
            sink.prev_x[row] = base.x;
            sink.prev_y[row] = base.y;
            sink.has_prev[row] = true;
        }
        self.count = 0;
    }
};

// The base direction: the path direction, else the normalized direct direction, blended
// from the previous direction by `steering_turn_smoothing` and re-normalized, so a
// discrete flip in the chosen direction (path/direct toggle, waypoint replan, wander epoch
// change) becomes a bounded per-step turn. A row's first direction is used as-is (no
// startup lag). The caller stores the result as the row's previous direction.
fn smoothDirectionScalar(input: DirectionTailInput) math.Vec2 {
    const direct = math.normalizeOrZeroFinite(input.direct_x, input.direct_y, direction_epsilon);
    const target = if (input.has_path) math.Vec2{ .x = input.path_x, .y = input.path_y } else direct;
    if (!input.has_prev) return target;
    const blended = math.lerpVec2(.{ .x = input.prev_x, .y = input.prev_y }, target, steering_turn_smoothing);
    return math.normalizeOrDefaultFinite(blended.x, blended.y, direction_epsilon, target);
}

// `smoothDirectionScalar` over four inputs in lanes, equal to it bit for bit.
fn smoothDirectionLanes(inputs: *const [simd.lane_count]DirectionTailInput) [simd.lane_count]math.Vec2 {
    var has_path: [simd.lane_count]bool = undefined;
    var has_prev: [simd.lane_count]bool = undefined;
    var path_x: [simd.lane_count]f32 = undefined;
    var path_y: [simd.lane_count]f32 = undefined;
    var direct_x: [simd.lane_count]f32 = undefined;
    var direct_y: [simd.lane_count]f32 = undefined;
    var prev_x: [simd.lane_count]f32 = undefined;
    var prev_y: [simd.lane_count]f32 = undefined;
    for (inputs, 0..) |input, lane| {
        has_path[lane] = input.has_path;
        has_prev[lane] = input.has_prev;
        path_x[lane] = input.path_x;
        path_y[lane] = input.path_y;
        direct_x[lane] = input.direct_x;
        direct_y[lane] = input.direct_y;
        prev_x[lane] = input.prev_x;
        prev_y[lane] = input.prev_y;
    }
    const path_mask: simd.Mask4 = has_path;
    const prev_mask: simd.Mask4 = has_prev;
    const direct = simd.normalizeOrZeroFinite2Float4(simd.loadFloat4(&direct_x), simd.loadFloat4(&direct_y), direction_epsilon);
    const target = simd.Vec2x4{
        .x = simd.selectFloat4(path_mask, simd.loadFloat4(&path_x), direct.x),
        .y = simd.selectFloat4(path_mask, simd.loadFloat4(&path_y), direct.y),
    };
    const previous = simd.Vec2x4{ .x = simd.loadFloat4(&prev_x), .y = simd.loadFloat4(&prev_y) };
    const blended = simd.lerpVec2Float4(previous, target, simd.splatFloat4(steering_turn_smoothing));
    const smoothed = simd.normalizeOrDefaultFinite2Float4(blended.x, blended.y, direction_epsilon, target);
    const base_x = simd.toFloatArray(simd.selectFloat4(prev_mask, smoothed.x, target.x));
    const base_y = simd.toFloatArray(simd.selectFloat4(prev_mask, smoothed.y, target.y));
    var bases: [simd.lane_count]math.Vec2 = undefined;
    for (&bases, base_x, base_y) |*base, x, y| base.* = .{ .x = x, .y = y };
    return bases;
}

fn directionFromPathStatus(
    pathfinding: *const PathfindingSystem,
    intent: NavigationIntent,
    start: math.Vec2,
    start_level: u16,
    steering_agent: SteeringAgentView,
    runtime: *RuntimeRow,
    tally: *DirectionsTally,
    emit_request: *bool,
) PathDirection {
    // Missing paths request work, pending paths hold direction, unavailable
    // paths enter backoff, and available paths steer toward the next waypoint. Partial paths
    // are followed like available ones; inside the end's refresh window they request the next
    // hop, and at the end they hold as pending paths do.
    const goal_distance = distance(start, intent.goal);
    const view = pathfinding.statusForWorld(start_level, start, intent.goal_level, intent.goal, intent.agent_class, &runtime.waypoint_hint);
    switch (view.status) {
        .available => {
            tally.available += 1;
            return followWaypoint(view.next_waypoint, start, intent.goal, steering_agent.waypoint_tolerance, goal_distance);
        },
        .partial => {
            tally.partial += 1;
            if (view.refresh) {
                if (runtime.replan_cooldown == 0 and runtime.unavailable_backoff == 0) {
                    emit_request.* = true;
                    runtime.replan_cooldown = steering_agent.replan_cooldown_steps;
                } else {
                    tally.cooldowns += 1;
                }
                // At the end: the path goes no further, so wait for the next hop without a
                // stuck replan.
                const to_end = math.Vec2{ .x = view.next_waypoint.x - start.x, .y = view.next_waypoint.y - start.y };
                if (math.lengthSquared(to_end) <= steering_agent.waypoint_tolerance * steering_agent.waypoint_tolerance) return .{ .progress_distance = goal_distance };
            }
            return followWaypoint(view.next_waypoint, start, intent.goal, steering_agent.waypoint_tolerance, goal_distance);
        },
        .missing => {
            if (runtime.replan_cooldown == 0 and runtime.unavailable_backoff == 0) {
                emit_request.* = true;
                runtime.replan_cooldown = steering_agent.replan_cooldown_steps;
            } else {
                tally.cooldowns += 1;
            }
            return .{ .status_allows_replan = true, .progress_distance = goal_distance };
        },
        .pending => {
            tally.pending += 1;
            return .{ .progress_distance = goal_distance };
        },
        .unavailable => {
            tally.unavailable += 1;
            if (runtime.unavailable_backoff == 0) {
                runtime.unavailable_backoff = steering_agent.unavailable_backoff_steps;
            } else {
                tally.backoffs += 1;
            }
            return .{ .progress_distance = goal_distance };
        },
    }
}

// The direction along a path toward `waypoint`, or straight to `goal` once within
// `tolerance` of it.
fn followWaypoint(waypoint: math.Vec2, start: math.Vec2, goal: math.Vec2, tolerance: f32, goal_distance: f32) PathDirection {
    const to_waypoint = math.Vec2{ .x = waypoint.x - start.x, .y = waypoint.y - start.y };
    if (math.lengthSquared(to_waypoint) <= tolerance * tolerance) {
        // At the waypoint: steer straight to the goal, so progress is goal distance.
        return .{ .has_direction = true, .direction = math.normalizeOrZeroFinite(goal.x - start.x, goal.y - start.y, direction_epsilon), .status_allows_replan = true, .progress_distance = goal_distance };
    }
    // Following the path: progress is closing on the next waypoint, which a
    // detour reduces even while straight-line goal distance grows.
    return .{ .has_direction = true, .direction = math.normalizeOrZeroFinite(to_waypoint.x, to_waypoint.y, direction_epsilon), .status_allows_replan = true, .progress_distance = math.length(to_waypoint) };
}

fn updateProgress(
    runtime: *RuntimeRow,
    progress_distance: f32,
    steering_agent: SteeringAgentView,
    status_allows_replan: bool,
    tally: *DirectionsTally,
    emit_request: *bool,
) void {
    // Stuck detection watches distance to the active steering target (next
    // waypoint, or goal when direct), not instantaneous velocity, so local
    // avoidance jitter does not immediately trigger replans and an agent walking
    // a detour around an obstacle is not mistaken for stuck.
    const progress_epsilon: f32 = 0.25;
    if (runtime.has_previous_distance and progress_distance + progress_epsilon >= runtime.previous_progress_distance) {
        if (runtime.stuck_steps < std.math.maxInt(u16)) runtime.stuck_steps += 1;
    } else {
        runtime.stuck_steps = 0;
    }
    runtime.previous_progress_distance = progress_distance;
    runtime.has_previous_distance = true;

    if (status_allows_replan and steering_agent.stuck_step_threshold > 0 and
        runtime.stuck_steps >= steering_agent.stuck_step_threshold and
        runtime.replan_cooldown == 0 and runtime.unavailable_backoff == 0)
    {
        runtime.stuck_steps = 0;
        runtime.replan_cooldown = steering_agent.replan_cooldown_steps;
        if (!emit_request.*) {
            emit_request.* = true;
            tally.stuck_replans += 1;
        }
    }
}

fn steeringAgentAt(slice: ConstSteeringAgentSlice, index: usize) SteeringAgentView {
    return .{
        .agent_radius = slice.agent_radii[index],
        .waypoint_tolerance = slice.waypoint_tolerances[index],
        .avoidance_radius = slice.avoidance_radii[index],
        .avoidance_weight = slice.avoidance_weights[index],
        .max_neighbor_samples = slice.max_neighbor_samples[index],
        .stuck_step_threshold = slice.stuck_step_thresholds[index],
        .replan_cooldown_steps = slice.replan_cooldown_steps[index],
        .unavailable_backoff_steps = slice.unavailable_backoff_steps[index],
    };
}

fn distance(a: math.Vec2, b: math.Vec2) f32 {
    return math.length(.{ .x = a.x - b.x, .y = a.y - b.y });
}

const PathRequest = @import("../../simulation.zig").PathRequest;
const RangeOutputStream = @import("../../simulation.zig").RangeOutputStream;
const SimulationFrame = @import("../../simulation.zig").SimulationFrame;

// Test-only fixtures for multi-level start_level regression (not production API).
const WorldSystem = @import("../../world/system.zig").WorldSystem;
const loadTestWorldMeta = @import("../pathfinding/test_support.zig").loadTestWorldMeta;
const worldColliders = @import("../pathfinding/test_support.zig").worldColliders;
const requireTestTile = @import("../pathfinding/test_support.zig").requireTestTile;
const default_cache_ttl_steps = @import("../pathfinding/types.zig").default_cache_ttl_steps;

const addSteeredEntity = @import("test_support.zig").addSteeredEntity;
const addStaticObstacle = @import("test_support.zig").addStaticObstacle;
const appendNavigationIntent = @import("test_support.zig").appendNavigationIntent;
const appendNavigationIntents = @import("test_support.zig").appendNavigationIntents;
const testColliders = @import("test_support.zig").testColliders;

test "steering requests missing paths then follows available path results" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 2, .worker_participant_count = 1 });
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
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const missing_stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 1), missing_stats.path_request_count);
    try std.testing.expectEqual(@as(usize, 1), frame.path_requests.mergedItems().len);
    try std.testing.expect(frame.intents.mergedItems()[0].movement.direction_x > 0);

    _ = try pathfinding.updateSerial(&frame.path_requests, 1, .{});

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 0, .direct_direction_y = 1 });
    const available_stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 1), available_stats.path_available_count);
    try std.testing.expectEqual(@as(usize, 0), available_stats.path_request_count);
    try std.testing.expect(frame.intents.mergedItems()[0].movement.direction_x > 0);
}

test "steering follows a partial path, requests the next hop inside its end window, and holds at its end without a stuck replan" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Cells (1, 8) and (120, 8) of a 128 x 16-cell open strip in 16-cell chunks.
    const start = math.Vec2{ .x = 48, .y = 272 };
    const goal = math.Vec2{ .x = 3856, .y = 272 };
    const agent = try addSteeredEntity(&data, start);
    const agent_view = SteeringAgentView{ .agent_radius = 8, .waypoint_tolerance = 4, .avoidance_radius = 48, .avoidance_weight = 1.5, .max_neighbor_samples = 8, .stuck_step_threshold = 3, .replan_cooldown_steps = 4, .unavailable_backoff_steps = 12 };

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    // Tier 0 promotes past 16 stitched cells; tier 1 publishes a 32-cell prefix.
    try pathfinding.reserve(.{ .max_group_fields = 2, .worker_participant_count = 1, .tier0_stitched_cell_cap = 16, .max_stitched_path_cells = 32 });
    try pathfinding.rebuildStaticNavGrid(&data, 128 * 32, 16 * 32, 32);
    var colliders = try testColliders(&pathfinding, &data, 128 * 32, 16 * 32, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    const intent = NavigationIntent{ .entity = agent, .goal = goal };

    frame.beginStep();
    try appendNavigationIntent(&frame, intent);
    try std.testing.expectEqual(@as(usize, 1), (try steering.updateSerial(&data, &frame, &pathfinding, &colliders)).path_request_count);
    _ = try pathfinding.updateSerial(&frame.path_requests, 1, .{});
    try std.testing.expectEqual(@as(usize, 1), (try pathfinding.updateSerial(&empty, 1, .{})).partial_results);
    const key = pathfinding.graph.keyForWorld(0, goal, .default).?;
    const slot = pathfinding.completed.freshSlotIndex(key, pathfinding.step_counter, default_cache_ttl_steps).?;
    const result = pathfinding.completed.resultAt(slot);
    const prefix = pathfinding.completed.stitchedSlice(slot, result.stitched_len);
    const grid = pathfinding.graph.grid(0).?;
    const end = grid.cellCenter(result.end.cell);
    const near_end = grid.cellCenter(prefix.cells[prefix.len() - 5]);

    // Outside the end's window: follow the prefix and request nothing, past the cooldown. The
    // agent closes on its waypoint, so no step reads as stuck.
    for (0..agent_view.replan_cooldown_steps + 1) |step| {
        const position = math.Vec2{ .x = start.x + 4 * @as(f32, @floatFromInt(step)), .y = start.y };
        try data.setMovementBody(agent, .{ .position = position, .previous_position = position, .velocity = .{}, .speed = 32 });
        frame.beginStep();
        try appendNavigationIntent(&frame, intent);
        const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
        try std.testing.expectEqual(@as(usize, 1), stats.path_partial_count);
        try std.testing.expectEqual(@as(usize, 0), stats.path_request_count);
        try std.testing.expect(frame.intents.mergedItems()[0].movement.direction_x > 0);
    }

    // Inside it: keep following and request the next hop.
    try data.setMovementBody(agent, .{ .position = near_end, .previous_position = near_end, .velocity = .{}, .speed = 32 });
    frame.beginStep();
    try appendNavigationIntent(&frame, intent);
    const refresh_stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 1), refresh_stats.path_request_count);
    try std.testing.expect(frame.intents.mergedItems()[0].movement.direction_x > 0);

    // At the end with the next hop late: hold, one request per cooldown, no stuck replan.
    try data.setMovementBody(agent, .{ .position = end, .previous_position = end, .velocity = .{}, .speed = 32 });
    var last_request: usize = 0;
    var requests: usize = 0;
    const held_steps: usize = 4 * agent_view.stuck_step_threshold;
    for (1..held_steps + 1) |step| {
        frame.beginStep();
        try appendNavigationIntent(&frame, intent);
        const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
        try std.testing.expectEqual(@as(usize, 1), stats.path_partial_count);
        try std.testing.expectEqual(@as(usize, 0), stats.stuck_replan_count);
        if (stats.path_request_count == 0) continue;
        try std.testing.expectEqual(@as(usize, 1), stats.path_request_count);
        try std.testing.expectEqual(@as(usize, agent_view.replan_cooldown_steps), step - last_request);
        last_request = step;
        requests += 1;
    }
    try std.testing.expectEqual(held_steps / agent_view.replan_cooldown_steps, requests);

    // The direction itself: a held agent has none and allows no replan; one outside the window
    // follows the path and requests nothing.
    var held = RuntimeRow{ .entity = agent };
    var tally = DirectionsTally{};
    var emit = false;
    const at_end = directionFromPathStatus(&pathfinding, intent, end, 0, agent_view, &held, &tally, &emit);
    try std.testing.expect(!at_end.has_direction and !at_end.status_allows_replan and emit);
    var following = RuntimeRow{ .entity = agent };
    emit = false;
    const at_start = directionFromPathStatus(&pathfinding, intent, start, 0, agent_view, &following, &tally, &emit);
    try std.testing.expect(at_start.has_direction and at_start.status_allows_replan and !emit);
    try std.testing.expect(at_start.direction.x > 0);

    // The last held step's request solves: the agent at the old end follows the next hop.
    try std.testing.expectEqual(held_steps, last_request);
    try std.testing.expectEqual(@as(usize, 1), frame.path_requests.mergedItems().len);
    _ = try pathfinding.updateSerial(&frame.path_requests, 1, .{});
    try std.testing.expectEqual(@as(usize, 1), (try pathfinding.updateSerial(&empty, 1, .{})).partial_results);
    frame.beginStep();
    try appendNavigationIntent(&frame, intent);
    const next_hop = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 1), next_hop.path_partial_count);
    try std.testing.expectEqual(@as(usize, 0), next_hop.path_request_count);
    try std.testing.expect(frame.intents.mergedItems()[0].movement.direction_x > 0);
}

test "steering smooths a discrete target-direction flip over several steps instead of snapping" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 2, .worker_participant_count = 1 });
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

    // Never resolving path requests keeps status `.missing` for every step, so
    // `direct_dir` (the raw target direction below) is what smoothing acts on.

    // First observation for this runtime row is used as-is: no startup lag.
    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 999, .y = 999 }, .direct_direction_x = 1, .direct_direction_y = 0 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    const first = frame.intents.mergedItems()[0].movement;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), first.direction_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), first.direction_y, 0.001);

    // Target direction flips a full 90 degrees to (0, 1). A hard snap would
    // jump straight to direction_y == 1; smoothing should only partially turn.
    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 999, .y = 999 }, .direct_direction_x = 0, .direct_direction_y = 1 });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    const second = frame.intents.mergedItems()[0].movement;
    try std.testing.expect(second.direction_y > 0.0);
    try std.testing.expect(second.direction_y < 0.9);
    try std.testing.expect(second.direction_x > 0.0);

    // Repeated steps toward the same (0, 1) target converge close to it.
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        frame.beginStep();
        try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 999, .y = 999 }, .direct_direction_x = 0, .direct_direction_y = 1 });
        _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    }
    const converged = frame.intents.mergedItems()[0].movement;
    try std.testing.expect(converged.direction_y > 0.95);
}

test "steering sources path request start level from movement scope level" {
    // The avoidance pass's path request takes its start level from the selected intent's
    // movementScopeLevel, which `directions` records (scope.level, kept in sync with
    // world_level via setWorldLevel). Exercised through a full updateSerial so a
    // future edit cannot quietly hardcode start_level back to 0. Multi-level nav
    // is required: statusForWorld treats an out-of-range start level as
    // unavailable and never emits a request (not missing).
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const surface = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    const underground = try addSteeredEntity(&data, .{ .x = 0, .y = 32 });
    try data.setWorldLevel(underground, 2);

    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 160, 160);
    defer world.deinit();
    // initDemoFromMeta owns level 0; add two more so start_level 2 has a grid.
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(2, 0, .floor, grass);

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 2, .worker_participant_count = 1 });
    try pathfinding.rebuildStaticNavGridWithWorld(&data, &world, null);
    var colliders = try worldColliders(&data, &world);
    defer colliders.deinit();
    try std.testing.expect(pathfinding.graph.levelCount() >= 3);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    // Fresh entities (no replan cooldown): both missing-path agents emit in one step.
    frame.beginStep();
    try appendNavigationIntents(&frame, &.{
        .{ .entity = surface, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 },
        .{ .entity = underground, .goal_level = 2, .goal = .{ .x = 96, .y = 32 }, .direct_direction_x = 1 },
    });
    _ = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);

    const requests = frame.path_requests.mergedItems();
    try std.testing.expectEqual(@as(usize, 2), requests.len);

    var saw_surface = false;
    var saw_underground = false;
    for (requests) |request| {
        if (request.entity.eql(surface)) {
            try std.testing.expectEqual(@as(u16, 0), request.start_level);
            saw_surface = true;
        } else if (request.entity.eql(underground)) {
            try std.testing.expectEqual(@as(u16, 2), request.start_level);
            try std.testing.expectEqual(@as(u16, 2), request.goal_level);
            saw_underground = true;
        }
    }
    try std.testing.expect(saw_surface);
    try std.testing.expect(saw_underground);
    try std.testing.expectEqual(
        @as(u16, 2),
        data.scopeColumnsSliceConst().level[data.movementBodyDenseIndex(underground).?],
    );
}

test "steering missing path requests respect replan cooldown" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 2, .worker_participant_count = 1 });
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
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const first = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 1), first.path_request_count);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const second = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 0), second.path_request_count);
    try std.testing.expectEqual(@as(usize, 1), second.replan_cooldown_count);
    try std.testing.expectEqual(@as(usize, 0), frame.path_requests.mergedItems().len);
}

test "steering reads an unreachable goal unavailable from status on the first step and backs off on the next, never requesting" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    // A wall on cell column 3, the last column of the first 4-cell chunk, seals the goal's
    // side off the agent's.
    _ = try addStaticObstacle(&data, .{ .x = 96, .y = 0 }, .{ .x = 32, .y = 160 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 1, .worker_participant_count = 1, .nav_chunk_tiles = 4 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);
    const grid = pathfinding.graph.grid(0).?;
    try std.testing.expect(grid.isBlockedCell(.{ .x = 3, .y = 0 }) and !grid.isBlockedCell(.{ .x = 2, .y = 0 }) and !grid.isBlockedCell(.{ .x = 4, .y = 0 }));
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
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 144, .y = 0 }, .direct_direction_x = 1 });
    const first = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 1), first.path_unavailable_count);
    try std.testing.expectEqual(@as(usize, 0), first.path_request_count);
    try std.testing.expectEqual(@as(usize, 0), first.unavailable_backoff_count);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 144, .y = 0 }, .direct_direction_x = 1 });
    const second = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 1), second.path_unavailable_count);
    try std.testing.expectEqual(@as(usize, 1), second.unavailable_backoff_count);
    try std.testing.expectEqual(@as(usize, 0), second.path_request_count);
}

test "steering reads a goal its start cannot reach unavailable from status every step and never requests it" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    _ = try addStaticObstacle(&data, .{ .x = 32, .y = 0 }, .{ .x = 32, .y = 160 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    // One chunk holds the agent and the goal, on two of its labels.
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

    // Past the agent's replan cooldown and unavailable backoff, so a re-request would show.
    for (0..16) |_| {
        frame.beginStep();
        try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 128, .y = 0 }, .direct_direction_x = 1 });
        const stats = try steering.updateSerial(&data, &frame, &pathfinding, &colliders);
        try std.testing.expectEqual(@as(usize, 1), stats.path_unavailable_count);
        try std.testing.expectEqual(@as(usize, 0), stats.path_request_count);
        const solve = try pathfinding.updateSerial(&frame.path_requests, 1, .{});
        try std.testing.expectEqual(@as(usize, 0), solve.solved_requests + solve.accepted_requests);
    }
}

test "steering direction tail lanes equal the scalar smoothing" {
    var prng = std.Random.DefaultPrng.init(0x0d1e_c7ed);
    const random = prng.random();
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    // Zero, NaN, and inf direct directions; a NaN previous direction; a blend landing at
    // zero length; opposite previous and target.
    const crafted = [_]DirectionTailInput{
        .{ .has_path = false, .path_x = 0, .path_y = 0, .direct_x = 0, .direct_y = 0, .prev_x = 1, .prev_y = 0, .has_prev = true },
        .{ .has_path = false, .path_x = 0, .path_y = 0, .direct_x = nan, .direct_y = 1, .prev_x = 0, .prev_y = 1, .has_prev = true },
        .{ .has_path = false, .path_x = 0, .path_y = 0, .direct_x = inf, .direct_y = 0, .prev_x = 0, .prev_y = 0, .has_prev = false },
        .{ .has_path = true, .path_x = 1, .path_y = 0, .direct_x = 0, .direct_y = 1, .prev_x = nan, .prev_y = 0, .has_prev = true },
        .{ .has_path = true, .path_x = 17, .path_y = 0, .direct_x = 0, .direct_y = 0, .prev_x = -3, .prev_y = 0, .has_prev = true },
        .{ .has_path = true, .path_x = -1, .path_y = 0, .direct_x = 1, .direct_y = 1, .prev_x = 1, .prev_y = 0, .has_prev = true },
        .{ .has_path = false, .path_x = 0, .path_y = 0, .direct_x = -0.00001, .direct_y = 0.00001, .prev_x = 0.6, .prev_y = 0.8, .has_prev = true },
    };
    var inputs: [9]DirectionTailInput = undefined;
    for (0..64) |round| {
        for (&inputs, 0..) |*input, index| {
            const pick = (round * inputs.len + index) % (crafted.len * 3);
            input.* = if (pick < crafted.len) crafted[pick] else .{
                .has_path = random.boolean(),
                .path_x = random.float(f32) * 2 - 1,
                .path_y = random.float(f32) * 2 - 1,
                .direct_x = random.float(f32) * 4 - 2,
                .direct_y = random.float(f32) * 4 - 2,
                .prev_x = random.float(f32) * 2 - 1,
                .prev_y = random.float(f32) * 2 - 1,
                .has_prev = random.boolean(),
            };
        }
        for (1..inputs.len + 1) |count| {
            var base_x: [9]f32 = @splat(0);
            var base_y: [9]f32 = @splat(0);
            var prev_x: [9]f32 = @splat(0);
            var prev_y: [9]f32 = @splat(0);
            var has_prev: [9]bool = @splat(false);
            const sink = DirectionTailSink{ .base_x = &base_x, .base_y = &base_y, .prev_x = &prev_x, .prev_y = &prev_y, .has_prev = &has_prev };
            var tail = DirectionTail{};
            for (inputs[0..count], 0..) |input, index| {
                tail.push(index, index, input);
                if (tail.count == simd.lane_count) tail.finish(sink);
            }
            tail.finish(sink);
            for (inputs[0..count], 0..) |input, index| {
                const expected = smoothDirectionScalar(input);
                try std.testing.expectEqual(@as(u32, @bitCast(expected.x)), @as(u32, @bitCast(base_x[index])));
                try std.testing.expectEqual(@as(u32, @bitCast(expected.y)), @as(u32, @bitCast(base_y[index])));
                try std.testing.expectEqual(@as(u32, @bitCast(expected.x)), @as(u32, @bitCast(prev_x[index])));
                try std.testing.expectEqual(@as(u32, @bitCast(expected.y)), @as(u32, @bitCast(prev_y[index])));
                try std.testing.expect(has_prev[index]);
            }
        }
    }
}
