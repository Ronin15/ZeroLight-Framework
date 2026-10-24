// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! The steering avoidance pass: bounded agent and static-obstacle pushes on each selected
//! intent's base direction, written as movement intents and path requests in selected
//! order. Free functions over `*SteeringSystem`; its step calls `writeMovementIntents`.

const std = @import("std");
const PaddedSlot = @import("../../../app/thread_system.zig").PaddedSlot;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const setSlotCount = @import("../../../app/thread_system.zig").setSlotCount;
const runtime_perf_log = @import("../../../app/runtime_perf_log.zig");
const math = @import("../../../core/math.zig");
const simd = @import("../../../core/simd.zig");
const ConstSteeringAgentSlice = @import("../../data_system.zig").ConstSteeringAgentSlice;
const MovementIntent = @import("../../simulation.zig").MovementIntent;
const PathRequest = @import("../../simulation.zig").PathRequest;
const SimulationIntent = @import("../../simulation.zig").SimulationIntent;
const RangeOutputStream = @import("../../simulation.zig").RangeOutputStream;
const SimulationFrame = @import("../../simulation.zig").SimulationFrame;
const ColliderView = @import("../static_colliders.zig").ColliderView;
const BoxHits = @import("../static_colliders.zig").BoxHits;
const steering_range_alignment_items = @import("system.zig").steering_range_alignment_items;
const StageThreads = @import("system.zig").StageThreads;
const SteeringStats = @import("system.zig").SteeringStats;
const SteeringSystem = @import("system.zig").SteeringSystem;
const selectedWorkSlice = @import("system.zig").selectedWorkSlice;
const selectedWorkSliceConst = @import("system.zig").selectedWorkSliceConst;
const SelectedWorkSlice = @import("system.zig").SelectedWorkSlice;
const ConstAgentSnapshotSlice = @import("system.zig").ConstAgentSnapshotSlice;
const SelectedIntent = @import("system.zig").SelectedIntent;
const SelectedWindow = @import("directions.zig").SelectedWindow;
const AgentGridDirectory = @import("agent_grid.zig").AgentGridDirectory;
const SpatialCellEntry = @import("agent_grid.zig").SpatialCellEntry;
const SpatialCellRange = @import("agent_grid.zig").SpatialCellRange;
const findCellRange = @import("agent_grid.zig").findCellRange;
const spatialCell = @import("agent_grid.zig").spatialCell;

pub const max_agent_candidate_checks: u16 = 64;

// Per-agent obstacle query budgets: the query stops after this many static boxes meeting
// the query box (each a push candidate), or after `max_obstacle_work` probes and entry
// reads.
const max_obstacle_hits: u16 = 64;
const max_obstacle_work: u16 = 512;

/// The avoidance pass over the selected intents in selected order: each range writes its
/// movement intents and the path requests its intents flagged, one range of each stream
/// per pass range, sized before dispatch from the directions' request prefixes. Both
/// streams therefore merge in selected order.
pub fn writeMovementIntents(
    self: *SteeringSystem,
    frame: *SimulationFrame,
    threads: StageThreads,
    obstacles: ColliderView,
    steering: ConstSteeringAgentSlice,
    stats: *SteeringStats,
) !void {
    const count = stats.selected_intent_count;
    const movement = threads.stage(&self.adaptive_tuner);
    const selection = movement.select(count, steering_range_alignment_items);
    const range_count = selection.range_count;
    const work = selectedWorkSliceConst(self);
    const intent_base = try frame.intents.appendRangeCounts(range_count);
    const request_base = try frame.path_requests.appendRangeCounts(range_count);
    for (0..range_count) |range_index| {
        const start = range_index * selection.items_per_range;
        const end = @min(start + selection.items_per_range, count);
        frame.intents.addCount(intent_base + range_index, end - start);
        const requests = requestsBefore(self.selected_windows.items, work.request_prefix, count, stats.path_request_count, end) -
            requestsBefore(self.selected_windows.items, work.request_prefix, count, stats.path_request_count, start);
        frame.path_requests.addCount(request_base + range_index, requests);
    }
    try frame.intents.prefixAppendedRanges(intent_base);
    try frame.path_requests.prefixAppendedRanges(request_base);
    setSlotCount(MovementTally, &self.movement_tallies, range_count);

    var context = SteeringJobContext{
        .windows = self.selected_windows.items,
        .selected = self.selected.items,
        .work = selectedWorkSlice(self),
        .agents = self.agentSnapshotSliceConst(),
        .agent_radii = steering.agent_radii,
        .obstacles = obstacles,
        .agent_cell_entries = self.agent_cell_entries.items,
        .agent_cell_ranges = self.agent_cell_ranges.items,
        .agent_grid = &self.agent_grid,
        .spatial_cell_size = self.spatial_cell_size,
        .intents = &frame.intents,
        .requests = &frame.path_requests,
        .intent_range_base = intent_base,
        .request_range_base = request_base,
        .selected_count = count,
        .tallies = self.movement_tallies.items,
        .range_count = range_count,
    };
    const batch = movement.run(selection, count, steering_range_alignment_items, &context, writeSteeringMovementJob);
    if (comptime runtime_perf_log.enabled) stats.perf.batch = batch;
    frame.intents.finishWrite();
    frame.path_requests.finishWrite();

    if (comptime runtime_perf_log.enabled) {
        for (self.movement_tallies.items) |slot| {
            stats.perf.agent_neighbor_samples += slot.value.agent_samples;
            stats.perf.obstacle_samples += slot.value.obstacle_samples;
            stats.perf.agent_candidate_checks += slot.value.agent_checks;
            stats.perf.obstacle_candidate_checks += slot.value.obstacle_checks;
        }
    }
    stats.movement_intent_count = count;
}

/// One avoidance range's sample and candidate counts, kept only with
/// `runtime_perf_log.enabled` (zero-sized otherwise, so its slots hold no storage).
pub const MovementTally = if (runtime_perf_log.enabled) struct {
    agent_samples: usize = 0,
    obstacle_samples: usize = 0,
    agent_checks: usize = 0,
    obstacle_checks: usize = 0,
} else struct {};

const SteeringJobContext = struct {
    // Worker context is immutable input plus range-indexed output columns and
    // pre-prefixed SimulationFrame streams.
    windows: []const SelectedWindow,
    selected: []const SelectedIntent,
    work: SelectedWorkSlice,
    // By steering row.
    agents: ConstAgentSnapshotSlice,
    agent_radii: []const f32,
    /// The static colliders' synced rows, read-only for the whole dispatch.
    obstacles: ColliderView,
    agent_cell_entries: []const SpatialCellEntry,
    agent_cell_ranges: []const SpatialCellRange,
    agent_grid: *const AgentGridDirectory,
    spatial_cell_size: f32,
    intents: *RangeOutputStream(SimulationIntent),
    requests: *RangeOutputStream(PathRequest),
    intent_range_base: usize,
    request_range_base: usize,
    // Selected intents in selected order; the pass's item count.
    selected_count: usize,
    tallies: []PaddedSlot(MovementTally),
    /// Dispatched range count; dual-asserted against `range.index` at job entry.
    range_count: usize,
};

const AvoidanceResult = struct {
    direction: math.Vec2,
    perf: AvoidancePerf = .{},
};

// One agent's avoidance samples and candidate checks.
const AvoidancePerf = if (runtime_perf_log.enabled) struct {
    agent_samples: u16 = 0,
    obstacle_samples: u16 = 0,
    agent_candidate_checks: u16 = 0,
    obstacle_candidate_checks: u16 = 0,
} else struct {};

// Path requests flagged by the selected intents before selected position `logical`.
pub fn requestsBefore(windows: []const SelectedWindow, request_prefix: []const u32, selected_count: usize, request_count: usize, logical: usize) usize {
    if (logical >= selected_count) return request_count;
    const window = windows[windowContaining(windows, logical)];
    return window.request_base + request_prefix[window.start + logical - window.logical_base];
}

// The window holding selected position `logical` (below the selected count): the last
// window starting at or before it, which is never empty.
fn windowContaining(windows: []const SelectedWindow, logical: usize) usize {
    const after = std.sort.partitionPoint(SelectedWindow, windows, logical, windowStartsAtOrBefore);
    std.debug.assert(after > 0);
    std.debug.assert(logical < windows[after - 1].logical_base + windows[after - 1].count);
    return after - 1;
}

fn windowStartsAtOrBefore(logical: usize, window: SelectedWindow) bool {
    return window.logical_base <= logical;
}

fn writeSteeringMovementJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    // Jobs never append outside their assigned output ranges, which keeps the
    // transient streams deterministic across serial and threaded runs.
    const job: *SteeringJobContext = @ptrCast(@alignCast(context));
    // Dual worker asserts (mirror affect.zig / collision.zig).
    std.debug.assert(range.index < job.range_count and range.index < job.tallies.len);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.selected_count);
    var intents = job.intents.rangeWriter(job.intent_range_base + range.index);
    var requests = job.requests.rangeWriter(job.request_range_base + range.index);
    // One hit scratch per range, reused by every agent of the range.
    var obstacle_hits: ObstacleHitScratch = undefined;
    var tally = MovementTally{};
    if (range.start < range.end) {
        // A cursor from selected order onto the directions windows.
        var window = windowContaining(job.windows, range.start);
        for (range.start..range.end) |logical| {
            while (logical >= job.windows[window].logical_base + job.windows[window].count) window += 1;
            const index = job.windows[window].start + (logical - job.windows[window].logical_base);
            std.debug.assert(index < job.selected.len and index < job.work.len());
            const result = computeAvoidance(job, index, &obstacle_hits);
            job.work.final_dir_x[index] = result.direction.x;
            job.work.final_dir_y[index] = result.direction.y;
            if (comptime runtime_perf_log.enabled) {
                tally.agent_samples += result.perf.agent_samples;
                tally.obstacle_samples += result.perf.obstacle_samples;
                tally.agent_checks += result.perf.agent_candidate_checks;
                tally.obstacle_checks += result.perf.obstacle_candidate_checks;
            }
            const selected = job.selected[index];
            intents.write(.{ .movement = MovementIntent{
                .entity = selected.entity,
                .direction_x = result.direction.x,
                .direction_y = result.direction.y,
            } });
            if (job.work.emit_request[index]) requests.write(PathRequest{
                .entity = selected.entity,
                .agent_class = selected.intent.agent_class,
                .kind = selected.intent.kind,
                .start_level = job.work.selected_world_level[index],
                .goal_level = selected.intent.goal_level,
                .start = .{ .x = job.work.start_x[index], .y = job.work.start_y[index] },
                .goal = selected.intent.goal,
            });
        }
    }
    intents.finish();
    requests.finish();
    job.tallies[range.index].value = tally;
}

fn computeAvoidance(job: *const SteeringJobContext, index: usize, obstacle_hits: *ObstacleHitScratch) AvoidanceResult {
    // Start with the path/direct base direction, then add bounded local pushes
    // from nearby agents and static obstacle boxes.
    var ax = job.work.base_dir_x[index];
    var ay = job.work.base_dir_y[index];
    var sample_count: u16 = 0;
    var agent_candidate_count: u16 = 0;
    const max_samples = job.work.selected_max_neighbor_samples[index];
    if (max_samples > 0) {
        accumulateAgentAvoidanceBounded(job, index, &ax, &ay, &sample_count, &agent_candidate_count, max_samples);
    }

    const start_x = job.work.start_x[index];
    const start_y = job.work.start_y[index];
    const radius = job.work.selected_avoidance_radii[index] + job.work.selected_agent_radii[index];
    const weight = job.work.selected_avoidance_weights[index];
    // Statics on the agent's level whose box meets the query box: every static that can
    // push lies within `radius` of the agent, so inside the box.
    const box = math.Aabb{ .min_x = start_x - radius, .min_y = start_y - radius, .max_x = start_x + radius, .max_y = start_y + radius };
    const query = job.obstacles.queryBox(job.work.selected_world_level[index], box, .{
        .max_hits = max_obstacle_hits,
        .max_work = max_obstacle_work,
    }, obstacle_hits.boxHits());
    var push = ObstaclePush{ .ax = ax, .ay = ay };
    pushObstacles(obstacle_hits, query.hits, start_x, start_y, radius, weight, &push);

    return .{
        .direction = math.normalizeOrZeroFinite(push.ax, push.ay, 0.0001),
        .perf = if (comptime runtime_perf_log.enabled) .{
            .agent_samples = sample_count,
            .obstacle_samples = push.perf.samples,
            .agent_candidate_checks = agent_candidate_count,
            .obstacle_candidate_checks = query.entries,
        } else .{},
    };
}

// One agent's obstacle hit boxes, packed by `ColliderView.queryBox` for the SIMD push.
const ObstacleHitScratch = struct {
    min_x: [max_obstacle_hits]f32,
    min_y: [max_obstacle_hits]f32,
    max_x: [max_obstacle_hits]f32,
    max_y: [max_obstacle_hits]f32,

    fn boxHits(self: *ObstacleHitScratch) BoxHits {
        return .{ .min_x = &self.min_x, .min_y = &self.min_y, .max_x = &self.max_x, .max_y = &self.max_y };
    }
};

// The accumulated steering direction, and the obstacle pushes added to it
// (`runtime_perf_log.enabled` only).
const ObstaclePush = struct {
    ax: f32,
    ay: f32,
    perf: PushPerf = .{},
};

const PushPerf = if (runtime_perf_log.enabled) struct { samples: u16 = 0 } else struct {};

// Adds the push of each of the first `count` hit boxes to `push`: four boxes per lane group,
// the last group masked to the boxes left. Lane `i` keeps the partial sum of boxes `i`,
// `i + 4`, ... in hit order, a lane out of range or past `count` adding -0.0 (the additive
// identity, so a -0.0 component stays -0.0); the four partials are reduced once in
// `simd.sumLanesFloat4`'s pinned order and added to `push`. `pushObstaclesScalar` sums in
// that order, bit for bit.
fn pushObstacles(hits: *const ObstacleHitScratch, count: usize, start_x: f32, start_y: f32, radius: f32, weight: f32, push: *ObstaclePush) void {
    std.debug.assert(count <= max_obstacle_hits);
    const agent = ObstacleAgentLanes{
        .start_x = simd.splatFloat4(start_x),
        .start_y = simd.splatFloat4(start_y),
        .radius = simd.splatFloat4(radius),
        .radius2 = simd.splatFloat4(radius * radius),
        .weight = simd.splatFloat4(weight),
    };
    var sums = ObstaclePushLanes{};
    var at: usize = 0;
    const vector_end = simd.vectorizedEnd(count);
    while (at < vector_end) : (at += simd.lane_count) {
        const boxes = ObstacleBoxLanes{
            .min_x = simd.loadFloat4(hits.min_x[at..]),
            .min_y = simd.loadFloat4(hits.min_y[at..]),
            .max_x = simd.loadFloat4(hits.max_x[at..]),
            .max_y = simd.loadFloat4(hits.max_y[at..]),
        };
        pushObstacleLanes(agent, boxes, simd.lanesBelow(simd.lane_count), &sums);
    }
    if (at < count) {
        // The boxes past `count` are unwritten scratch: the prefix loads read only the boxes left.
        const left = count - at;
        const boxes = ObstacleBoxLanes{
            .min_x = simd.loadFloat4Prefix(hits.min_x[at..], left),
            .min_y = simd.loadFloat4Prefix(hits.min_y[at..], left),
            .max_x = simd.loadFloat4Prefix(hits.max_x[at..], left),
            .max_y = simd.loadFloat4Prefix(hits.max_y[at..], left),
        };
        pushObstacleLanes(agent, boxes, simd.lanesBelow(left), &sums);
    }
    push.ax += simd.sumLanesFloat4(sums.ax);
    push.ay += simd.sumLanesFloat4(sums.ay);
    if (comptime runtime_perf_log.enabled) push.perf.samples += sums.perf.samples;
}

// One agent's obstacle push inputs, splat across the lanes.
const ObstacleAgentLanes = struct {
    start_x: simd.Float4,
    start_y: simd.Float4,
    radius: simd.Float4,
    radius2: simd.Float4,
    weight: simd.Float4,
};

// Four hit boxes, one per lane.
const ObstacleBoxLanes = struct {
    min_x: simd.Float4,
    min_y: simd.Float4,
    max_x: simd.Float4,
    max_y: simd.Float4,
};

// Per-lane partial sums of the obstacle pushes, -0.0 before any push, and the pushes added
// (`runtime_perf_log.enabled` only).
const ObstaclePushLanes = struct {
    ax: simd.Float4 = simd.splatFloat4(-0.0),
    ay: simd.Float4 = simd.splatFloat4(-0.0),
    perf: PushPerf = .{},
};

// `pushObstacleScalar` over the boxes in `lanes`, each added to its lane's partial sum.
inline fn pushObstacleLanes(agent: ObstacleAgentLanes, boxes: ObstacleBoxLanes, lanes: simd.MaskBits, sums: *ObstaclePushLanes) void {
    const zero = simd.splatFloat4(0);
    const edge_dx = agent.start_x - simd.clampFloat4(agent.start_x, boxes.min_x, boxes.max_x);
    const edge_dy = agent.start_y - simd.clampFloat4(agent.start_y, boxes.min_y, boxes.max_y);
    // Inside the box: push away from its center.
    const inside = simd.equalFloat4(edge_dx, zero) & simd.equalFloat4(edge_dy, zero);
    const half = simd.splatFloat4(0.5);
    const dx = simd.selectFloat4(inside, agent.start_x - (boxes.min_x + boxes.max_x) * half, edge_dx);
    const dy = simd.selectFloat4(inside, agent.start_y - (boxes.min_y + boxes.max_y) * half, edge_dy);
    const dist2 = simd.lengthSquared2Float4(dx, dy);
    const in_range = simd.greaterThanFloat4(dist2, simd.splatFloat4(obstacle_min_dist2)) & simd.lessThanFloat4(dist2, agent.radius2);
    const length_direction = simd.lengthDirection2Float4(dx, dy, 0);
    const strength = (simd.splatFloat4(1) - length_direction.length / agent.radius) * agent.weight;
    const pushing = simd.maskBits(in_range) & lanes;
    // Lanes that do not push add -0.0, the additive identity.
    const identity = simd.splatFloat4(-0.0);
    sums.ax += simd.selectBitsFloat4(pushing, length_direction.direction.x * strength, identity);
    sums.ay += simd.selectBitsFloat4(pushing, length_direction.direction.y * strength, identity);
    if (comptime runtime_perf_log.enabled) sums.perf.samples += @popCount(pushing);
}

// Squared distances at or below this push nothing (no stable direction).
const obstacle_min_dist2: f32 = 0.0001;

fn accumulateAgentAvoidanceBounded(
    job: *const SteeringJobContext,
    index: usize,
    ax: *f32,
    ay: *f32,
    sample_count: *u16,
    candidate_count: *u16,
    max_samples: u16,
) void {
    // Candidate and sample caps are separate: candidate caps bound dense-cell
    // cost, while sample caps keep behavior stable for configured agents.
    const start_x = job.work.start_x[index];
    const start_y = job.work.start_y[index];
    const avoidance_radius = job.work.selected_avoidance_radii[index];
    const query_radius = avoidance_radius + job.work.selected_agent_radii[index];
    const weight = job.work.selected_avoidance_weights[index];
    const self_entity = job.selected[index].entity;
    const min_cell_x = spatialCell(start_x - query_radius, job.spatial_cell_size);
    const max_cell_x = spatialCell(start_x + query_radius, job.spatial_cell_size);
    const min_cell_y = spatialCell(start_y - query_radius, job.spatial_cell_size);
    const max_cell_y = spatialCell(start_y + query_radius, job.spatial_cell_size);

    // The serial grid is one band: its ranges are resolved once, not per probed cell.
    const one_band: ?[]const SpatialCellRange = if (job.agent_grid.splitter_count == 0)
        job.agent_cell_ranges[job.agent_grid.bands[0].start..][0..job.agent_grid.bands[0].range_count]
    else
        null;
    var cell_y = min_cell_y;
    while (cell_y <= max_cell_y and sample_count.* < max_samples and candidate_count.* < max_agent_candidate_checks) : (cell_y += 1) {
        var cell_x = min_cell_x;
        while (cell_x <= max_cell_x and sample_count.* < max_samples and candidate_count.* < max_agent_candidate_checks) : (cell_x += 1) {
            const band_ranges = one_band orelse job.agent_grid.rangesOfCell(job.agent_cell_ranges, cell_x, cell_y);
            const range = findCellRange(band_ranges, cell_x, cell_y) orelse continue;
            for (job.agent_cell_entries[range.start..range.end]) |entry| {
                if (sample_count.* >= max_samples or candidate_count.* >= max_agent_candidate_checks) break;
                candidate_count.* += 1;
                const other_index = entry.index;
                if (job.agents.entity[other_index].eql(self_entity)) continue;
                // Match collision's sameWorldLevel gate: pure-XY overlap across
                // floors must not produce a lateral push.
                if (job.agents.world_level[other_index] != job.work.selected_world_level[index]) continue;
                const dx = start_x - job.agents.x[other_index];
                const dy = start_y - job.agents.y[other_index];
                const combined_radius = avoidance_radius + job.agent_radii[other_index];
                const dist2 = dx * dx + dy * dy;
                if (dist2 > 0.0001 and dist2 < combined_radius * combined_radius) {
                    accumulateAgentSample(dx, dy, combined_radius, weight, ax, ay, sample_count);
                }
            }
        }
    }
}

fn accumulateAgentSample(
    dx: f32,
    dy: f32,
    combined_radius: f32,
    weight: f32,
    ax: *f32,
    ay: *f32,
    sample_count: *u16,
) void {
    const push = math.lengthDirection(dx, dy, 0);
    const strength = (1.0 - push.length / combined_radius) * weight;
    ax.* += push.direction.x * strength;
    ay.* += push.direction.y * strength;
    sample_count.* += 1;
}

const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const DataSystem = @import("../../data_system.zig").DataSystem;
const EntityId = @import("../../data_system.zig").EntityId;
const max_steering_neighbor_samples = @import("../../data_system.zig").max_steering_neighbor_samples;
const NavigationIntent = @import("../../simulation.zig").NavigationIntent;
const PathfindingSystem = @import("../pathfinding.zig").PathfindingSystem;
const addSteeredEntity = @import("test_support.zig").addSteeredEntity;
const updateSteeringInline = @import("test_support.zig").updateSteeringInline;
const addStaticObstacle = @import("test_support.zig").addStaticObstacle;
const appendNavigationIntent = @import("test_support.zig").appendNavigationIntent;
const appendNavigationIntents = @import("test_support.zig").appendNavigationIntents;
const testColliders = @import("test_support.zig").testColliders;
const commitStaticsForTest = @import("test_support.zig").commitStaticsForTest;
const parity_statics = @import("test_support.zig").parity_statics;
const expectParityStaticsSpread = @import("test_support.zig").expectParityStaticsSpread;
const expectStaticNearASteeredAgent = @import("test_support.zig").expectStaticNearASteeredAgent;

test "steering applies local agent and static obstacle avoidance" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    _ = try addSteeredEntity(&data, .{ .x = 20, .y = 0 });
    _ = try addStaticObstacle(&data, .{ .x = 24, .y = -24 }, .{ .x = 20, .y = 20 });

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
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);
    const movement = frame.intents.mergedItems()[0].movement;
    // Only the box, at negative y, pushes toward +y, and neither push alone outweighs the
    // +x direct direction: together they turn it past -x.
    try std.testing.expect(movement.direction_y > 0);
    try std.testing.expect(movement.direction_x < 0);
}

test "steering agent avoidance stops at the candidate cap among dense co-located neighbors" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // The agent samples up to the store's maximum, past the candidate cap, so only the cap
    // can stop its walk.
    const agent = try addSteeredEntity(&data, .{ .x = 60, .y = 60 });
    try data.setSteeringAgent(agent, .{ .agent_radius = 8, .waypoint_tolerance = 4, .avoidance_radius = 48, .avoidance_weight = 1.5, .max_neighbor_samples = max_steering_neighbor_samples, .stuck_step_threshold = 3, .replan_cooldown_steps = 4, .unavailable_backoff_steps = 12 });
    // Twice the cap of neighbors at one point in the grid cell walked before the agent's
    // own, each in reach.
    const neighbor_count = 2 * max_agent_candidate_checks;
    for (0..neighbor_count) |_| _ = try addSteeredEntity(&data, .{ .x = 50, .y = 52 });

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
    try steering.reserve(neighbor_count + 1);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 150, .y = 60 }, .direct_direction_x = 1 });
    _ = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);

    // The direct direction plus the identical pushes of the first `max_agent_candidate_checks`
    // candidates, all neighbors; the uncapped walk would add every neighbor's.
    var capped_ax: f32 = 1;
    var capped_ay: f32 = 0;
    var capped_samples: u16 = 0;
    for (0..max_agent_candidate_checks) |_| accumulateAgentSample(10, 8, 48 + 8, 1.5, &capped_ax, &capped_ay, &capped_samples);
    var uncapped_ax: f32 = 1;
    var uncapped_ay: f32 = 0;
    var uncapped_samples: u16 = 0;
    for (0..neighbor_count) |_| accumulateAgentSample(10, 8, 48 + 8, 1.5, &uncapped_ax, &uncapped_ay, &uncapped_samples);
    const expected = math.normalizeOrZeroFinite(capped_ax, capped_ay, 0.0001);
    const uncapped = math.normalizeOrZeroFinite(uncapped_ax, uncapped_ay, 0.0001);
    try std.testing.expect(expected.y != uncapped.y);
    const movement = frame.intents.mergedItems()[0].movement;
    try std.testing.expect(movement.entity.eql(agent));
    try std.testing.expectEqual(@as(u32, @bitCast(expected.x)), @as(u32, @bitCast(movement.direction_x)));
    try std.testing.expectEqual(@as(u32, @bitCast(expected.y)), @as(u32, @bitCast(movement.direction_y)));
}

test "steering local agent avoidance ignores XY overlap across different world_levels" {
    // Two agents near in XY but on different floors. Without a same-level gate the
    // neighbor would push the steerer off its +x direction toward -y; with it, the direct
    // direction is unchanged.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    const other = try addSteeredEntity(&data, .{ .x = 0, .y = 20 });
    try data.setWorldLevel(agent, 0);
    try data.setWorldLevel(other, 1);

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
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);
    const movement = frame.intents.mergedItems()[0].movement;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), movement.direction_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), movement.direction_y, 0.001);
}

test "steering static obstacle avoidance ignores XY overlap across different world_levels" {
    // A level-1 agent overlaps a level-0 static box in XY: the box is never read and does
    // not push. Moving the box to level 1 through a committed `.world_level` change and
    // the collider sync makes it push on the next step.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    const obstacle = try addStaticObstacle(&data, .{ .x = 4, .y = -12 }, .{ .x = 20, .y = 20 });
    try data.setWorldLevel(agent, 1);
    try data.setWorldLevel(obstacle, 0);

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 1, .worker_participant_count = 1 });
    try pathfinding.rebuildStaticNavGrid(&data, 160, 160, 32);
    var colliders = try testColliders(&pathfinding, &data, 160, 160, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 4, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);
    const cross = frame.intents.mergedItems()[0].movement;
    // The other level's box does not push.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cross.direction_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cross.direction_y, 0.001);

    frame.beginStep();
    try commitStaticsForTest(&frame, &data, &colliders, &.{.{ .set_world_level = .{ .entity = obstacle, .level = 1 } }});
    steering.reactToPostCommitSteeringEvents(&frame);
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);
    const same = frame.intents.mergedItems()[0].movement;
    try std.testing.expect(same.direction_x < 1);
}

test "steering multi-level obstacle gate matches between serial and real threaded workers" {

    // Alternating agent levels over one static box per level at overlapping XY:
    // each agent may only react to its own floor's box, identically under every
    // worker split.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var intents = std.ArrayList(NavigationIntent).empty;
    defer intents.deinit(std.testing.allocator);
    try intents.ensureTotalCapacity(std.testing.allocator, 128);

    for (0..128) |index| {
        const x: f32 = @floatFromInt(index % 16);
        const y: f32 = @floatFromInt(index / 16);
        const entity = try addSteeredEntity(&data, .{ .x = x * 14.0, .y = y * 14.0 });
        try data.setWorldLevel(entity, @intCast(index % 2));
        intents.appendAssumeCapacity(.{
            .entity = entity,
            .goal = .{ .x = 420, .y = 220 },
            .direct_direction_x = if (index % 2 == 0) 1 else -1,
            .direct_direction_y = if (index % 3 == 0) 0.25 else -0.15,
            .priority = 1,
        });
    }
    // Statics of several size classes over both chunk columns, alternating levels.
    for (parity_statics, 0..) |placement, index| {
        const entity = try addStaticObstacle(&data, placement[0], placement[1]);
        try data.setWorldLevel(entity, @intCast(index % 2));
    }

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 4, .worker_participant_count = 1 });
    try pathfinding.rebuildStaticNavGrid(&data, 512, 512, 16);
    var colliders = try testColliders(&pathfinding, &data, 512, 512, 16);
    defer colliders.deinit();
    try expectParityStaticsSpread(&colliders);
    try expectStaticNearASteeredAgent(&colliders, &data);

    var serial_frame = SimulationFrame.init(std.testing.allocator);
    defer serial_frame.deinit();
    try serial_frame.reserveStreams(16, 0, 128, 0, 0, 0);
    try serial_frame.reservePathRequests(16, 128);
    serial_frame.beginStep();
    try appendNavigationIntents(&serial_frame, intents.items);
    var serial_system = SteeringSystem.init(std.testing.allocator);
    defer serial_system.deinit();
    try serial_system.reserve(128);
    _ = try updateSteeringInline(&serial_system, &data, &serial_frame, &pathfinding, &colliders);
    const serial = serial_frame.intents.mergedItems();
    try std.testing.expect(serial.len > 0);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 4,
        .items_per_range = steering_range_alignment_items,
    });
    defer threads.deinit();

    const splits = [_]struct { items_per_range: usize, workers: usize }{
        .{ .items_per_range = steering_range_alignment_items, .workers = 2 },
        .{ .items_per_range = steering_range_alignment_items * 3, .workers = 4 },
    };
    for (splits) |split| {
        var threaded_frame = SimulationFrame.init(std.testing.allocator);
        defer threaded_frame.deinit();
        try threaded_frame.reserveStreams(16, 0, 128, 0, 0, 0);
        try threaded_frame.reservePathRequests(16, 128);
        threaded_frame.beginStep();
        try appendNavigationIntents(&threaded_frame, intents.items);
        var threaded_system = SteeringSystem.init(std.testing.allocator);
        defer threaded_system.deinit();
        try threaded_system.reserve(128);
        _ = try threaded_system.update(&data, &threaded_frame, &threads, &pathfinding, &colliders, .{
            .items_per_range = split.items_per_range,
            .max_worker_threads = split.workers,
            .adaptive = false,
        });
        const threaded = threaded_frame.intents.mergedItems();
        try std.testing.expectEqual(serial.len, threaded.len);
        for (serial, threaded) |a, b| {
            try std.testing.expectEqual(a.movement.entity.index, b.movement.entity.index);
            try std.testing.expectEqual(a.movement.entity.generation, b.movement.entity.generation);
            try std.testing.expectEqual(a.movement.direction_x, b.movement.direction_x);
            try std.testing.expectEqual(a.movement.direction_y, b.movement.direction_y);
        }
    }
}

test "steering pushes from a static's committed position the step after its move commits" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    const parked = math.Vec2{ .x = 0, .y = 400 };
    const box = try addStaticObstacle(&data, parked, .{ .x = 20, .y = 20 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 1, .worker_participant_count = 1 });
    try pathfinding.rebuildStaticNavGrid(&data, 640, 640, 32);
    var colliders = try testColliders(&pathfinding, &data, 640, 640, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 4, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);
    try std.testing.expectApproxEqAbs(@as(f32, 0), frame.intents.mergedItems()[0].movement.direction_y, 0.001);

    // The commit moves the box above the agent; its previous position stays parked, so
    // only the committed position can push.
    frame.beginStep();
    try commitStaticsForTest(&frame, &data, &colliders, &.{.{ .set_movement_body = .{
        .entity = box,
        .body = .{ .position = .{ .x = 8, .y = -32 }, .previous_position = parked, .velocity = .{}, .speed = 0 },
    } }});
    steering.reactToPostCommitSteeringEvents(&frame);
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    _ = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);
    // Pushed away from the box, toward +y.
    try std.testing.expect(frame.intents.mergedItems()[0].movement.direction_y > 0.05);
}

test "steering obstacle pushes equal a scalar push over the query's hits" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Agents far enough apart that no agent pushes another.
    const agent_positions = [_]math.Vec2{ .{ .x = 60, .y = 60 }, .{ .x = 260, .y = 60 }, .{ .x = 60, .y = 260 }, .{ .x = 500, .y = 300 } };
    var agents: [agent_positions.len]EntityId = undefined;
    for (&agents, agent_positions) |*agent, position| agent.* = try addSteeredEntity(&data, position);
    // Several size classes; a chunk-border box the second agent stands inside; negative,
    // outside-the-level, larger-than-the-level, and sub-unit boxes; a cluster giving the
    // first agent more hits than one SIMD lane group; and an overlapping box on another
    // level.
    const placements = [_][2]math.Vec2{
        .{ .{ .x = 40, .y = 40 }, .{ .x = 10, .y = 10 } },
        .{ .{ .x = 70, .y = 30 }, .{ .x = 40, .y = 40 } },
        .{ .{ .x = 250, .y = 50 }, .{ .x = 12, .y = 12 } },
        .{ .{ .x = 240, .y = 10 }, .{ .x = 100, .y = 20 } },
        .{ .{ .x = -20, .y = 240 }, .{ .x = 30, .y = 30 } },
        .{ .{ .x = 520, .y = 280 }, .{ .x = 30, .y = 30 } },
        .{ .{ .x = 480, .y = 320 }, .{ .x = 600, .y = 10 } },
        .{ .{ .x = 60, .y = 250 }, .{ .x = 0.5, .y = 0.5 } },
        .{ .{ .x = 20, .y = 75 }, .{ .x = 8, .y = 8 } },
        .{ .{ .x = 32, .y = 75 }, .{ .x = 8, .y = 8 } },
        .{ .{ .x = 44, .y = 75 }, .{ .x = 8, .y = 8 } },
        .{ .{ .x = 56, .y = 75 }, .{ .x = 8, .y = 8 } },
        .{ .{ .x = 68, .y = 75 }, .{ .x = 8, .y = 8 } },
    };
    for (placements) |placement| _ = try addStaticObstacle(&data, placement[0], placement[1]);
    const other_level = try addStaticObstacle(&data, .{ .x = 50, .y = 50 }, .{ .x = 20, .y = 20 });
    try data.setWorldLevel(other_level, 1);

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 1, .worker_participant_count = 1 });
    try pathfinding.rebuildStaticNavGrid(&data, 512, 512, 16);
    var colliders = try testColliders(&pathfinding, &data, 512, 512, 16);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(4);

    var intents: [agents.len]NavigationIntent = undefined;
    for (&intents, agents) |*intent, agent| intent.* = .{ .entity = agent, .goal = .{ .x = 999, .y = 0 }, .direct_direction_x = 1 };
    frame.beginStep();
    try appendNavigationIntents(&frame, &intents);
    _ = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);

    // The reference: the direct direction plus the scalar push of the hits in query order,
    // summed in the lane order.
    const view = colliders.view();
    var hits: ObstacleHitScratch = undefined;
    var pushes: usize = 0;
    var max_hits: u16 = 0;
    for (frame.intents.mergedItems(), agent_positions) |intent, position| {
        const radius: f32 = 48 + 8;
        const box = math.Aabb{ .min_x = position.x - radius, .min_y = position.y - radius, .max_x = position.x + radius, .max_y = position.y + radius };
        const query = view.queryBox(0, box, .{ .max_hits = max_obstacle_hits, .max_work = max_obstacle_work }, hits.boxHits());
        max_hits = @max(max_hits, query.hits);
        for (0..query.hits) |at| {
            var probe = ObstaclePush{ .ax = 0, .ay = 0 };
            pushObstacleScalar(hits.min_x[at], hits.min_y[at], hits.max_x[at], hits.max_y[at], position.x, position.y, radius, 1.5, &probe);
            if (probe.ax != 0 or probe.ay != 0) pushes += 1;
        }
        var push = ObstaclePush{ .ax = 1, .ay = 0 };
        pushObstaclesScalar(&hits, query.hits, position.x, position.y, radius, 1.5, &push);
        const expected = math.normalizeOrZeroFinite(push.ax, push.ay, 0.0001);
        try std.testing.expectEqual(@as(u32, @bitCast(expected.x)), @as(u32, @bitCast(intent.movement.direction_x)));
        try std.testing.expectEqual(@as(u32, @bitCast(expected.y)), @as(u32, @bitCast(intent.movement.direction_y)));
    }
    try std.testing.expect(pushes >= agents.len);
    try std.testing.expect(max_hits > simd.lane_count);
}

test "steering obstacle SIMD push equals the scalar push" {
    var prng = std.Random.DefaultPrng.init(0x0b57);
    const random = prng.random();
    var hits: ObstacleHitScratch = undefined;
    // An agent at the origin with radius 10: boxes holding it (off center and centered),
    // one exactly on the radius, one closer than the push epsilon, then random boxes.
    const crafted = [_][4]f32{
        .{ -1, -1, 3, 3 },
        .{ 10, -2, 12, 2 },
        .{ 0.005, -1, 2, 1 },
        .{ -1, -1, 1, 1 },
        .{ 2, 2, 4, 5 },
    };
    for (0..max_obstacle_hits) |at| {
        const box: [4]f32 = if (at < crafted.len) crafted[at] else blk: {
            const min_x = random.float(f32) * 24 - 12;
            const min_y = random.float(f32) * 24 - 12;
            break :blk .{ min_x, min_y, min_x + random.float(f32) * 6, min_y + random.float(f32) * 6 };
        };
        hits.min_x[at] = box[0];
        hits.min_y[at] = box[1];
        hits.max_x[at] = box[2];
        hits.max_y[at] = box[3];
    }
    for ([_]usize{ 0, 1, 3, 4, 5, 8, 9, 64 }) |count| {
        // -0.0 stays -0.0 unless a push is added.
        var lanes = ObstaclePush{ .ax = 0.25, .ay = -0.0 };
        pushObstacles(&hits, count, 0, 0, 10, 1.5, &lanes);
        var scalar = ObstaclePush{ .ax = 0.25, .ay = -0.0 };
        pushObstaclesScalar(&hits, count, 0, 0, 10, 1.5, &scalar);
        try std.testing.expectEqual(@as(u32, @bitCast(scalar.ax)), @as(u32, @bitCast(lanes.ax)));
        try std.testing.expectEqual(@as(u32, @bitCast(scalar.ay)), @as(u32, @bitCast(lanes.ay)));
    }
    // The crafted on-radius, sub-epsilon, and centered boxes push nothing: the five push
    // what the off-center holding box and the last box push alone. Both share lane 0, and
    // the other lanes hold -0.0, so the lane sum adds them in hit order too.
    var crafted_push = ObstaclePush{ .ax = 0, .ay = 0 };
    pushObstacles(&hits, crafted.len, 0, 0, 10, 1.5, &crafted_push);
    var pushing_only = ObstaclePush{ .ax = 0, .ay = 0 };
    for ([_]usize{ 0, crafted.len - 1 }) |at| pushObstacleScalar(hits.min_x[at], hits.min_y[at], hits.max_x[at], hits.max_y[at], 0, 0, 10, 1.5, &pushing_only);
    try std.testing.expect(pushing_only.ax != 0 and pushing_only.ay != 0);
    try std.testing.expectEqual(@as(u32, @bitCast(pushing_only.ax)), @as(u32, @bitCast(crafted_push.ax)));
    try std.testing.expectEqual(@as(u32, @bitCast(pushing_only.ay)), @as(u32, @bitCast(crafted_push.ay)));
}

test "steering stops the obstacle walk at the work budget in query order" {
    // Co-located tiny statics in a cell the walk reaches before the one pushing static,
    // none meeting the query box: past the work budget they hide the near static.
    try std.testing.expect(!try pushedBehindFarEntries(600));
    try std.testing.expect(try pushedBehindFarEntries(400));
}

test "steering stops the obstacle walk at the hit cap among dense co-located statics" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 0, .y = 0 });
    for (0..128) |_| {
        _ = try addStaticObstacle(&data, .{ .x = 8, .y = 8 }, .{ .x = 8, .y = 8 });
    }

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 1, .worker_participant_count = 1 });
    try pathfinding.rebuildStaticNavGrid(&data, 256, 256, 32);
    var colliders = try testColliders(&pathfinding, &data, 256, 256, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(1);

    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 96, .y = 0 }, .direct_direction_x = 1 });
    const stats = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);
    try std.testing.expectEqual(@as(usize, 1), stats.movement_intent_count);
    // Every co-located static meets the query box, so each entry read is a hit: the walk
    // stops at the hit cap, and the direction is the direct one plus `max_obstacle_hits`
    // of the 128 identical pushes, summed in the lane order.
    var capped: ObstacleHitScratch = undefined;
    @memset(&capped.min_x, 8);
    @memset(&capped.min_y, 8);
    @memset(&capped.max_x, 16);
    @memset(&capped.max_y, 16);
    var reference = ObstaclePush{ .ax = 1, .ay = 0 };
    pushObstaclesScalar(&capped, max_obstacle_hits, 0, 0, 48 + 8, 1.5, &reference);
    const expected = math.normalizeOrZeroFinite(reference.ax, reference.ay, 0.0001);
    const movement = frame.intents.mergedItems()[0].movement;
    try std.testing.expectEqual(@as(u32, @bitCast(expected.x)), @as(u32, @bitCast(movement.direction_x)));
    try std.testing.expectEqual(@as(u32, @bitCast(expected.y)), @as(u32, @bitCast(movement.direction_y)));
}

// The scalar form of one `pushObstacleLanes` lane: its push toward its closest point's
// opposite side, or from its center when the agent is inside it, falling off linearly to
// zero at `radius`.
fn pushObstacleScalar(min_x: f32, min_y: f32, max_x: f32, max_y: f32, start_x: f32, start_y: f32, radius: f32, weight: f32, push: *ObstaclePush) void {
    var dx = start_x - math.clampMinMax(start_x, min_x, max_x);
    var dy = start_y - math.clampMinMax(start_y, min_y, max_y);
    if (dx == 0 and dy == 0) {
        dx = start_x - (min_x + max_x) * 0.5;
        dy = start_y - (min_y + max_y) * 0.5;
    }
    const dist2 = dx * dx + dy * dy;
    if (dist2 > obstacle_min_dist2 and dist2 < radius * radius) {
        const length_direction = math.lengthDirection(dx, dy, 0);
        const strength = (1.0 - length_direction.length / radius) * weight;
        push.ax += length_direction.direction.x * strength;
        push.ay += length_direction.direction.y * strength;
    }
}

// `pushObstacles` in scalar: box `i` adds `pushObstacleScalar` into partial sum `i % 4`
// (each -0.0 before any push), then the partials are summed in `simd.sumLanesScalar`'s
// order and added to `push`.
fn pushObstaclesScalar(hits: *const ObstacleHitScratch, count: usize, start_x: f32, start_y: f32, radius: f32, weight: f32, push: *ObstaclePush) void {
    var partial_x: [simd.lane_count]f32 = @splat(-0.0);
    var partial_y: [simd.lane_count]f32 = @splat(-0.0);
    for (0..count) |at| {
        const lane = at % simd.lane_count;
        var partial = ObstaclePush{ .ax = partial_x[lane], .ay = partial_y[lane] };
        pushObstacleScalar(hits.min_x[at], hits.min_y[at], hits.max_x[at], hits.max_y[at], start_x, start_y, radius, weight, &partial);
        partial_x[lane] = partial.ax;
        partial_y[lane] = partial.ay;
    }
    push.ax += simd.sumLanesScalar(partial_x);
    push.ay += simd.sumLanesScalar(partial_y);
}

// One agent at (300, 300) with a static to its right and above it, behind `far_count`
// co-located one-unit statics just outside its query box in an earlier walked cell.
// Returns whether the static turned the agent off its +x direct direction.
fn pushedBehindFarEntries(far_count: usize) !bool {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const agent = try addSteeredEntity(&data, .{ .x = 300, .y = 300 });
    for (0..far_count) |_| _ = try addStaticObstacle(&data, .{ .x = 224, .y = 224 }, .{ .x = 1, .y = 1 });
    _ = try addStaticObstacle(&data, .{ .x = 320, .y = 280 }, .{ .x = 10, .y = 10 });

    var pathfinding = PathfindingSystem.init(std.testing.allocator);
    defer pathfinding.deinit();
    try pathfinding.reserve(.{ .max_group_fields = 1, .worker_participant_count = 1 });
    var colliders = try testColliders(&pathfinding, &data, 640, 640, 32);
    defer colliders.deinit();

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(2, 0, 4, 0, 0, 0);
    try frame.reservePathRequests(2, 4);
    var steering = SteeringSystem.init(std.testing.allocator);
    defer steering.deinit();
    try steering.reserve(1);
    frame.beginStep();
    try appendNavigationIntent(&frame, .{ .entity = agent, .goal = .{ .x = 999, .y = 300 }, .direct_direction_x = 1 });
    _ = try updateSteeringInline(&steering, &data, &frame, &pathfinding, &colliders);
    // The static's box [320, 330] x [280, 290] pushes from (320, 290): toward -x and +y.
    return @abs(frame.intents.mergedItems()[0].movement.direction_y) > 0.01;
}
