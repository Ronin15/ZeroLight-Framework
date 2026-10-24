// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! `steering` times one steering step over its agent count on a row-major grid;
//! `steering-shuffled`, `steering-corridor`, and `steering-cluster-outlier` time the same step
//! with the agents created in a shuffled order, in one cell-row corridor, and in a cluster
//! with one agent far outside it. The static groups build a `SimulationPipeline` over their
//! agents and statics, nav over a one-level walkable world, and step its steering system on
//! its nav and colliders. `steering-static-change` times one static collision body moved and
//! committed through the production commit seam (`commitStructuralAndReact`: reserves,
//! budgeted commit, capture, population seam, collider and trigger sync, and the nav and
//! steering reactions) and one steering step for a fixed agent population, with the static
//! count as its item count; the cost model expects it flat in the static count. `steering-static-dense` times one steering step for a fixed agent
//! population among chunks holding a count of statics each; its item code names the
//! statics' layout and that count. The `chunk_ordered` layout creates the statics chunk by
//! chunk; `interleaved` creates the same statics in a seeded shuffled order, so consecutive
//! statics land in different chunks; `churned` builds the chunk-ordered statics, then
//! destroys a seeded random half and recreates them at the same places through the
//! production commit seam. Each reports the main thread's share: the iteration minus its
//! off-main stage time (the seam's collider sync and nav reaction stages included).
//!
//! Pass shape: `steering` and the three layout groups linear in agents, the tuned case
//! judged against its controls; `steering-static-change` flat in statics;
//! `steering-static-dense` linear in statics per chunk, and the `interleaved` and `churned`
//! layouts' time per agent within spread of `chunk_ordered` at the same count. Asserts
//! check that every agent writes a movement intent, that the agent groups' avoidance checks
//! stay within each agent's candidate budget, that the static groups sample statics,
//! and that `steering-static-dense` repeats its first step's obstacle visits and samples
//! and, when churned, that every destroy and recreate commits and syncs.
//!
//! The agent groups print `avoidance_checks=`, `samples=`, and `intents=`;
//! `steering-static-change` prints `obstacle_checks=` and `obstacle_samples=`;
//! `steering-static-dense` prints `obstacle_visits=` (with visits per agent),
//! `obstacle_samples=`, and `intents=`. `--details` adds each prepare stage's shape
//! (`agents=`, `resolve=`, `claim=`, `dir=`, `bucket=` the agent grid's bucket pass, `sort=`
//! its sort; `-` for a stage that did not run), `steer=` (the avoidance pass), and `main=`;
//! the agent groups also print `band_max=`, the entries in the agent grid's largest band.

const std = @import("std");
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const maxRangeCount = @import("../app/thread_system.zig").maxRangeCount;
const math = @import("../core/math.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const StructuralCommand = @import("../game/data_system.zig").StructuralCommand;
const NavigationIntent = @import("../game/simulation.zig").NavigationIntent;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const structuralEventHeadroom = @import("../game/simulation.zig").structuralEventHeadroom;
const PathfindingSystem = @import("../game/systems/pathfinding.zig").PathfindingSystem;
const StaticColliderSystem = @import("../game/systems/static_colliders.zig").StaticColliderSystem;
const SteeringStats = @import("../game/systems/steering/system.zig").SteeringStats;
const SteeringSystem = @import("../game/systems/steering/system.zig").SteeringSystem;
const steering_range_alignment_items = @import("../game/systems/steering/system.zig").steering_range_alignment_items;
const max_agent_candidate_checks = @import("../game/systems/steering/avoidance.zig").max_agent_candidate_checks;
const default_chunk_size_tiles = @import("../game/world/system.zig").default_chunk_size_tiles;
const WorldSystem = @import("../game/world/system.zig").WorldSystem;
const CommitSeamResult = @import("../game/simulation_pipeline.zig").CommitSeamResult;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");
const static_colliders_test_support = @import("../game/systems/static_colliders_test_support.zig");

pub const group = suite.BenchmarkGroup{
    .name = "steering",
    .item_label = "steering agents",
    .item_counts = &agent_counts,
    .runCase = runCase,
    .write_workload = writeSteeringWorkload,
};

pub const shuffled_group = suite.BenchmarkGroup{
    .name = "steering-shuffled",
    .item_label = "steering agents",
    .item_counts = &layout_counts,
    .runCase = runShuffledCase,
    .write_workload = writeSteeringWorkload,
};

pub const corridor_group = suite.BenchmarkGroup{
    .name = "steering-corridor",
    .item_label = "steering agents",
    .item_counts = &layout_counts,
    .runCase = runCorridorCase,
    .write_workload = writeSteeringWorkload,
};

pub const cluster_outlier_group = suite.BenchmarkGroup{
    .name = "steering-cluster-outlier",
    .item_label = "steering agents",
    .item_counts = &layout_counts,
    .runCase = runClusterOutlierCase,
    .write_workload = writeSteeringWorkload,
};

pub const static_change_group = suite.BenchmarkGroup{
    .name = "steering-static-change",
    .item_label = "static bodies",
    .item_counts = &static_change_counts,
    .runCase = runStaticChangeCase,
    .write_workload = writeStaticChangeWorkload,
};

pub const static_dense_group = suite.BenchmarkGroup{
    .name = "steering-static-dense",
    .item_label = StaticDenseCode.label,
    .describe_item = StaticDenseCode.describe,
    .item_counts = &static_dense_counts,
    .runCase = runStaticDenseCase,
    .write_workload = writeStaticDenseWorkload,
};

const agent_counts = [_]usize{ 128, 512, 1024 };
const layout_counts = [_]usize{ 1024, 4096, 16384 };

// Where the steering agent groups place their agents.
const Layout = enum {
    // Row-major on a square grid at the agent pitch, created in row-major order.
    grid,
    // The grid's positions, created in a seeded random order.
    shuffled,
    // Two lanes inside the first spatial cell row, created in a seeded random order.
    corridor,
    // The grid's positions for all but one agent, which sits far outside the grid and the
    // nav extent; created in a seeded random order.
    cluster_outlier,
};

const layout_shuffle_seed: u64 = 0x64_6d_4e_42;
// The corridor's lanes sit at these y offsets, both inside spatial cell row 0.
const corridor_lane_y = [2]f32{ 4.0, 22.0 };
// Nav rows of the corridor's nav extent; they cover the lanes and the near statics.
const corridor_nav_rows: f32 = 8.0;
// The outlier's coordinates, in multiples of the grid's nav extent.
const outlier_extent_multiple: f32 = 64.0;

const Fixture = struct {
    data: DataSystem,
    frame: SimulationFrame,
    pathfinding: PathfindingSystem,
    // Built from the fixture's statics on nav's cell grid; steering reads them.
    colliders: StaticColliderSystem,
    agents: std.ArrayList(EntityId) = .empty,

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.agents.deinit(allocator);
        self.colliders.deinit();
        self.pathfinding.deinit();
        self.frame.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

fn createFixture(allocator: std.mem.Allocator, count: usize, layout: Layout) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    var frame = SimulationFrame.init(allocator);
    errdefer frame.deinit();
    try frame.reserveStreams(maxRangeCount(count, steering_range_alignment_items), 0, count, 0, 0, 0);
    try frame.reservePathRequests(maxRangeCount(count, steering_range_alignment_items), count);
    var pathfinding = PathfindingSystem.init(allocator);
    errdefer pathfinding.deinit();
    try pathfinding.reserve(.{
        .max_group_fields = 4,
        .worker_participant_count = 1,
    });
    var agents = std.ArrayList(EntityId).empty;
    errdefer agents.deinit(allocator);
    try agents.ensureTotalCapacity(allocator, count);

    const side = gridSide(count);
    const grid_extent = @as(f32, @floatFromInt(side + 4)) * nav_cell_size;
    // Agent k takes position slot `creation_order[k]`; the grid layout keeps row-major order.
    const creation_order = try allocator.alloc(usize, count);
    defer allocator.free(creation_order);
    for (creation_order, 0..) |*slot, index| slot.* = index;
    if (layout != .grid) {
        var prng = std.Random.DefaultPrng.init(layout_shuffle_seed);
        prng.random().shuffle(usize, creation_order);
    }
    for (creation_order) |slot| {
        agents.appendAssumeCapacity(try addAgent(&data, layoutPosition(layout, slot, count, side, grid_extent)));
    }

    const near_static_total = @min(@as(usize, 16), side);
    for (0..near_static_total) |index| {
        _ = try addStatic(&data, nearStaticPosition(index));
    }

    var nav_width = grid_extent;
    var nav_height = grid_extent;
    if (layout == .corridor) {
        const corridor_length = @as(f32, @floatFromInt(count / 2 + 4)) * agent_pitch;
        const static_row_end = nearStaticPosition(near_static_total - 1).x + static_size + nav_cell_size;
        nav_width = @max(corridor_length, static_row_end);
        nav_height = corridor_nav_rows * nav_cell_size;
    }
    try pathfinding.rebuildStaticNavGrid(&data, nav_width, nav_height, nav_cell_size);
    var colliders = try buildColliders(allocator, &data, &pathfinding, nav_width, nav_height);
    errdefer colliders.deinit();

    return .{ .data = data, .frame = frame, .pathfinding = pathfinding, .colliders = colliders, .agents = agents };
}

// The static colliders of `data`'s statics on the cell grid of nav's `width` x `height` build.
fn buildColliders(allocator: std.mem.Allocator, data: *const DataSystem, pathfinding: *const PathfindingSystem, width: f32, height: f32) !StaticColliderSystem {
    var colliders = StaticColliderSystem.init(allocator);
    errdefer colliders.deinit();
    try colliders.rebuild(data, try pathfinding.boundsNavExtent(width, height, nav_cell_size).colliderGeometry(), null);
    return colliders;
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return try runLayoutCase(allocator, io, options, case, item_count, .grid);
}

fn runShuffledCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return try runLayoutCase(allocator, io, options, case, item_count, .shuffled);
}

fn runCorridorCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return try runLayoutCase(allocator, io, options, case, item_count, .corridor);
}

fn runClusterOutlierCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return try runLayoutCase(allocator, io, options, case, item_count, .cluster_outlier);
}

fn runLayoutCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, layout: Layout) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try createFixture(allocator, item_count, layout);
    defer fixture.deinit(allocator);
    var system = SteeringSystem.init(allocator);
    defer system.deinit();
    const measured = try measureCase(allocator, io, options, case, item_count, &system, fixture.agents.items.len, null, &fixture, prepareOnce, runOnce);
    // Each agent's avoidance stops at its candidate budget.
    if (measured.last.perf.agent_candidate_checks > measured.last.selected_intent_count * max_agent_candidate_checks) return error.AgentChecksPastBudget;
    var stats = measured.stats;
    stats.candidate_pairs = measured.last.perf.agent_candidate_checks + measured.last.perf.obstacle_candidate_checks;
    stats.sample_count = measured.last.perf.agent_neighbor_samples + measured.last.perf.obstacle_samples;
    return stats;
}

const MeasuredCase = struct {
    stats: suite.RunStats,
    last: SteeringStats,
};

// Off-main time of one steering step's stages.
fn stagesOffMainNs(stats: SteeringStats) u64 {
    return offMainNs(stats.perf.agents_batch) + offMainNs(stats.perf.select_resolve_batch) + offMainNs(stats.perf.select_claim_batch) + offMainNs(stats.perf.directions_batch) +
        offMainNs(stats.perf.grid_bucket_batch) + offMainNs(stats.perf.grid_sort_batch) + offMainNs(stats.perf.batch);
}

// Every steering stage tuner has settled.
fn stageTunersSettled(system: *const SteeringSystem) bool {
    return suite.tunerSettled(&system.adaptive_tuner) and suite.tunerSettled(&system.agents_tuner) and suite.tunerSettled(&system.select_resolve_tuner) and
        suite.tunerSettled(&system.select_claim_tuner) and suite.tunerSettled(&system.directions_tuner) and suite.tunerSettled(&system.grid_bucket_tuner) and
        suite.tunerSettled(&system.grid_sort_tuner);
}

// Entries in the agent grid's largest band after the last step.
fn largestGridBand(system: *const SteeringSystem) usize {
    const grid = &system.agent_grid;
    const band_count: usize = if (grid.splitter_count == 0) 1 else grid.bands.len;
    var largest: usize = 0;
    for (grid.bands[0..band_count]) |band| {
        var entries: usize = 0;
        for (system.agent_cell_ranges.items[band.start..][0..band.range_count]) |range| entries += range.end - range.start;
        largest = @max(largest, entries);
    }
    return largest;
}

// Warms up, settles the stage tuners, and times `step(context)` of `system` over
// `agent_count` agents, with the main thread's share: each iteration minus the off-main time
// of the steering stages and, when the step runs a commit seam, the seam's
// (`seam_off_main_ns`, read after each step). `prepare(context)` writes the step's inputs
// before each step, outside the timed region.
fn measureCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: suite.Options,
    case: suite.BenchmarkCase,
    item_count: usize,
    system: *SteeringSystem,
    agent_count: usize,
    seam_off_main_ns: ?*const u64,
    context: anytype,
    comptime prepare: fn (@TypeOf(context)) anyerror!void,
    comptime step: fn (*SteeringSystem, @TypeOf(context), *ThreadSystem, suite.BenchmarkCase) anyerror!SteeringStats,
) !MeasuredCase {
    try system.reserve(agent_count);

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;

    var last_stats = SteeringStats{};
    var warm = suite.Warmup.init(options, case, 0);
    while (warm.next(stageTunersSettled(system))) {
        try prepare(context);
        last_stats = try step(system, context, thread_ptr, case);
    }
    const settled_before_measurement = if (case.adaptive) stageTunersSettled(system) else false;
    const adaptive_tuner_start = suite.TunerStart.of(&system.adaptive_tuner, settled_before_measurement);

    var accumulator = suite.StatsAccumulator.init(item_count);
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        try prepare(context);
        const start_ns = suite.nowNs(io);
        last_stats = try step(system, context, thread_ptr, case);
        const end_ns = suite.nowNs(io);
        const elapsed_ns = suite.elapsedNs(start_ns, end_ns);
        const off_main_ns = stagesOffMainNs(last_stats) + (if (seam_off_main_ns) |seam_ns| seam_ns.* else 0);
        main_total += elapsed_ns -| off_main_ns;
        accumulator.record(elapsed_ns, last_stats.perf.batch);
        try suite.checkStagesDispatched(case, thread_ptr, case.stageItemsPerRange(steering_range_alignment_items), &.{
            last_stats.perf.agents_batch,      last_stats.perf.select_resolve_batch, last_stats.perf.select_claim_batch, last_stats.perf.directions_batch,
            last_stats.perf.grid_bucket_batch, last_stats.perf.grid_sort_batch,      last_stats.perf.batch,
        });
    }

    var stats = accumulator.finish();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    stats.output_count = last_stats.movement_intent_count;
    stats.secondary_batch = suite.batchSummaryFromBatch(BatchStats{});
    stats.steering_stages = .{
        .agents = suite.batchSummaryFromBatch(last_stats.perf.agents_batch),
        .select_resolve = suite.batchSummaryFromBatch(last_stats.perf.select_resolve_batch),
        .select_claim = suite.batchSummaryFromBatch(last_stats.perf.select_claim_batch),
        .directions = suite.batchSummaryFromBatch(last_stats.perf.directions_batch),
        .grid_bucket = suite.batchSummaryFromBatch(last_stats.perf.grid_bucket_batch),
        .grid_sort = suite.batchSummaryFromBatch(last_stats.perf.grid_sort_batch),
        .band_max = largestGridBand(system),
    };
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(&system.adaptive_tuner, adaptive_tuner_start);
    }
    return .{ .stats = stats, .last = last_stats };
}

// A new step with a navigation intent for every agent.
fn prepareOnce(fixture: *Fixture) !void {
    fixture.frame.beginStep();
    try appendNavigationIntents(&fixture.frame, fixture.agents.items);
}

// One steering step; fails when an agent writes no movement intent.
fn runOnce(system: *SteeringSystem, fixture: *Fixture, thread_system: *ThreadSystem, case: suite.BenchmarkCase) !SteeringStats {
    const stats = try steeringStep(system, fixture, thread_system, case);
    if (stats.movement_intent_count != fixture.agents.items.len) return error.AgentIntentMissing;
    return stats;
}

// The steering update for `case` over the step's navigation intents.
fn steeringStep(system: *SteeringSystem, fixture: *Fixture, thread_system: *ThreadSystem, case: suite.BenchmarkCase) !SteeringStats {
    return try system.update(&fixture.data, &fixture.frame, thread_system, &fixture.pathfinding, &fixture.colliders, .{
        .items_per_range = case.stageItemsPerRange(steering_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

fn appendNavigationIntents(frame: *SimulationFrame, agents: []const EntityId) !void {
    var writer = try fixtures.beginOneRange(NavigationIntent, &frame.navigation_intents, agents.len);
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

// Position slot `slot` of `layout` for `count` agents on a `side`-wide grid whose nav extent
// is `grid_extent`.
fn layoutPosition(layout: Layout, slot: usize, count: usize, side: usize, grid_extent: f32) math.Vec2 {
    return switch (layout) {
        .grid, .shuffled => gridPosition(slot, side),
        .corridor => .{ .x = @as(f32, @floatFromInt(slot / 2)) * agent_pitch, .y = corridor_lane_y[slot % 2] },
        .cluster_outlier => if (slot + 1 == count)
            .{ .x = outlier_extent_multiple * grid_extent, .y = outlier_extent_multiple * grid_extent }
        else
            gridPosition(slot, side),
    };
}

// Slot `index` of a `side`-wide row-major grid at the agent pitch.
fn gridPosition(index: usize, side: usize) math.Vec2 {
    return .{
        .x = @as(f32, @floatFromInt(index % side)) * agent_pitch,
        .y = @as(f32, @floatFromInt(index / side)) * agent_pitch,
    };
}

// A steering agent at `position`.
fn addAgent(data: *DataSystem, position: math.Vec2) !EntityId {
    const entity = try data.createEntity();
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
    return fixtures.addBody(data, position, .{ .x = static_size, .y = static_size }, .static);
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
// Static groups: a `SimulationPipeline` over the agents and statics with nav over a one-level
// walkable world, so statics change through the production commit seam; the steering step is
// the pipeline's, on its nav and colliders.
// ----------------------------------------------------------------------------

const SeamFixture = struct {
    data: DataSystem,
    world: WorldSystem,
    seam: fixtures.PipelineSeam,
    agents: std.ArrayList(EntityId),
    // The last commit seam's collider sync and nav reaction worker time.
    seam_off_main_ns: u64 = 0,

    // The pipeline over `data` with nav over a `width` x `height` world-unit world, on nav's
    // cell size. Owns `data` and `agents` from the call, on failure too.
    fn init(allocator: std.mem.Allocator, io: std.Io, data: DataSystem, agents: std.ArrayList(EntityId), width: f32, height: f32, structural_headroom: usize) !SeamFixture {
        var owned_data = data;
        errdefer owned_data.deinit();
        var owned_agents = agents;
        errdefer owned_agents.deinit(allocator);
        var tileset = try fixtures.loadTilesetMeta(allocator, io);
        defer tileset.deinit();
        // The groups' extents are a few hundred tiles a side.
        const tiles_x: u16 = @intFromFloat(@ceil(width / nav_cell_size));
        const tiles_y: u16 = @intFromFloat(@ceil(height / nav_cell_size));
        var world = try fixtures.buildBandedWorldSized(allocator, &tileset, tiles_x, tiles_y, 1, "grass", "grass");
        errdefer world.deinit();
        if (world.tile_size != nav_cell_size or world.chunk_size_tiles != default_chunk_size_tiles) return error.SeamWorldGridMismatch;
        // One participant, as the pathfinding capacity: the builds run inline.
        var build_threads = try fixtures.initRequiredCaseThreads(allocator, io, suite.serial_cases[0]);
        defer build_threads.deinit();
        const seam = try fixtures.PipelineSeam.init(allocator, &owned_data, &world, .{
            .structural_headroom = structural_headroom,
            .pathfinding = .{ .max_group_fields = 4, .worker_participant_count = 1 },
            .build_thread_system = &build_threads,
        });
        return .{ .data = owned_data, .world = world, .seam = seam, .agents = owned_agents };
    }

    fn deinit(self: *SeamFixture, allocator: std.mem.Allocator) void {
        self.agents.deinit(allocator);
        self.seam.deinit();
        self.world.deinit();
        self.data.deinit();
        self.* = undefined;
    }

    fn colliders(self: *SeamFixture) *StaticColliderSystem {
        return &self.seam.pipeline.static_colliders;
    }

    // `commands` through the production commit seam in the frame's current step.
    fn commit(self: *SeamFixture, commands: []const StructuralCommand, thread_system: *ThreadSystem) !CommitSeamResult {
        const result = try self.seam.commit(&self.data, &self.world, commands, thread_system);
        self.seam_off_main_ns = static_colliders_test_support.lastOffMainNs(self.colliders().*) + result.nav_update.perf.off_main_stage_ns;
        return result;
    }

    // A new step with a navigation intent for every agent.
    fn prepare(self: *SeamFixture) !void {
        self.seam.frame.beginStep();
        try appendNavigationIntents(&self.seam.frame, self.agents.items);
    }

    // The pipeline's steering update for `case` over the step's navigation intents.
    fn step(self: *SeamFixture, thread_system: *ThreadSystem, case: suite.BenchmarkCase) !SteeringStats {
        const pipeline = &self.seam.pipeline;
        return try pipeline.steering.update(&self.data, &self.seam.frame, thread_system, &pipeline.pathfinding, &pipeline.static_colliders, .{
            .items_per_range = case.stageItemsPerRange(steering_range_alignment_items),
            .max_worker_threads = case.maxWorkerThreads(),
            .adaptive = case.adaptive,
        });
    }
};

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
const agent_pitch: f32 = 18.0;
const chunk_px: f32 = @as(f32, @floatFromInt(default_chunk_size_tiles)) * nav_cell_size;
// First chunk column of the filler block; one empty chunk column separates it from the agents.
const filler_origin_chunk_x: usize = 4;

const StaticChangeFixture = struct {
    steering: SeamFixture,
    // The mover alternates between two filler-block chunks.
    mover: fixtures.StaticMove,

    fn deinit(self: *StaticChangeFixture, allocator: std.mem.Allocator) void {
        self.steering.deinit(allocator);
        self.* = undefined;
    }
};

// `static_count` statics: `near_static_count` among the agents, one mover, and the rest as
// filler at `statics_per_filler_chunk` per chunk in a square chunk block right of the agents,
// so the block's side grows with the square root of the static count.
fn createStaticChangeFixture(allocator: std.mem.Allocator, io: std.Io, static_count: usize) !StaticChangeFixture {
    if (static_count < near_static_count + 1) return error.TooFewStatics;
    const agent_count = static_change_agent_count;
    var data = DataSystem.init(allocator);
    // `SeamFixture.init` owns `data` and `agents` from its call, on failure too.
    var handed_over = false;
    errdefer if (!handed_over) data.deinit();
    var agents = std.ArrayList(EntityId).empty;
    errdefer if (!handed_over) agents.deinit(allocator);
    try agents.ensureTotalCapacity(allocator, agent_count);

    const side = gridSide(agent_count);
    for (0..agent_count) |index| {
        agents.appendAssumeCapacity(try addAgent(&data, gridPosition(index, side)));
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
    const filler_chunks = @max(@as(usize, 2), @divCeil(filler_count, statics_per_filler_chunk));
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
    const mover = fixtures.StaticMove{ .entity = try addStatic(&data, mover_positions[0]), .positions = mover_positions };

    // Nav covers the agents and the whole filler block, so no static clamps onto an edge cell.
    const nav_width = @as(f32, @floatFromInt(filler_origin_chunk_x + block_side)) * chunk_px;
    const nav_height = @max(@as(f32, @floatFromInt(block_side)) * chunk_px, @as(f32, @floatFromInt(side + 4)) * nav_cell_size);
    handed_over = true;
    var steering = try SeamFixture.init(allocator, io, data, agents, nav_width, nav_height, fixtures.StaticMove.structural_headroom);
    errdefer steering.deinit(allocator);
    if (static_colliders_test_support.liveRowCount(steering.colliders().*) != static_count) return error.WrongStaticCount;
    return .{ .steering = steering, .mover = mover };
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

    var fixture = try createStaticChangeFixture(allocator, io, item_count);
    defer fixture.deinit(allocator);
    fixture.steering.seam.setCaseTuners(case);
    const measured = try measureCase(allocator, io, options, case, item_count, &fixture.steering.seam.pipeline.steering, fixture.steering.agents.items.len, &fixture.steering.seam_off_main_ns, &fixture, prepareStaticChange, staticChangeOnce);
    var stats = measured.stats;
    stats.candidate_pairs = measured.last.perf.obstacle_candidate_checks;
    stats.sample_count = measured.last.perf.obstacle_samples;
    return stats;
}

fn prepareStaticChange(fixture: *StaticChangeFixture) !void {
    try fixture.steering.prepare();
}

// One step: the mover's set_movement_body through the production commit seam (its stages on
// the case's threads, the steering post-commit reaction included), then the pipeline's
// steering update.
fn staticChangeOnce(system: *SteeringSystem, fixture: *StaticChangeFixture, thread_system: *ThreadSystem, case: suite.BenchmarkCase) !SteeringStats {
    std.debug.assert(system == &fixture.steering.seam.pipeline.steering);
    const commit = try fixture.steering.commit(&.{fixture.mover.command()}, thread_system);
    if (commit.structural.components_set != 1) return error.StaticMoveNotApplied;
    if (fixture.steering.colliders().changesThisStep().len != 1) return error.StaticChangeNotSynced;
    fixture.mover.advance();

    const stats = try fixture.steering.step(thread_system, case);
    if (stats.movement_intent_count != fixture.steering.agents.items.len) return error.AgentIntentMissing;
    if (stats.perf.obstacle_samples == 0) return error.NearStaticsUnsampled;
    return stats;
}

// ----------------------------------------------------------------------------
// Static dense: a fixed agent population among chunks dense with statics.
// ----------------------------------------------------------------------------

const StaticDenseLayout = enum(u8) { chunk_ordered, interleaved, churned };
const StaticDenseCode = suite.ItemCode(struct { layout: StaticDenseLayout, statics_per_chunk: usize }, &.{3});

// The chunk-ordered layout at each count, then the other layouts at the largest.
const static_dense_counts = [_]usize{
    StaticDenseCode.of(.{ .layout = .chunk_ordered, .statics_per_chunk = 4 }),
    StaticDenseCode.of(.{ .layout = .chunk_ordered, .statics_per_chunk = 16 }),
    StaticDenseCode.of(.{ .layout = .chunk_ordered, .statics_per_chunk = 64 }),
    StaticDenseCode.of(.{ .layout = .interleaved, .statics_per_chunk = 64 }),
    StaticDenseCode.of(.{ .layout = .churned, .statics_per_chunk = 64 }),
};
// Fixed agent population; the threaded case dispatches the steering stage to workers at it.
const static_dense_agent_count: usize = 4096;
const static_dense_shuffle_seed: u64 = 0x73_74_61_74;

const StaticDenseFixture = struct {
    steering: SeamFixture,
    // Obstacle visits and samples of the first step; every later step repeats them.
    first_visits: ?usize = null,
    first_samples: usize = 0,

    fn deinit(self: *StaticDenseFixture, allocator: std.mem.Allocator) void {
        self.steering.deinit(allocator);
        self.* = undefined;
    }
};

// `statics_per_chunk` statics in every chunk the agent grid overlaps, each centered in its slot
// of a square slot grid spanning the chunk, so every chunk the agents query holds exactly
// `statics_per_chunk` statics and no static crosses a chunk edge. `layout` sets the order the
// statics are created in and whether half are churned through the commit seam.
fn createStaticDenseFixture(allocator: std.mem.Allocator, io: std.Io, statics_per_chunk: usize, layout: StaticDenseLayout) !StaticDenseFixture {
    if (statics_per_chunk == 0) return error.NoStatics;
    const slot_side = std.math.sqrt(statics_per_chunk - 1) + 1;
    std.debug.assert(slot_side * slot_side >= statics_per_chunk);
    const slot_pitch = chunk_px / @as(f32, @floatFromInt(slot_side));
    if (slot_pitch < static_size) return error.StaticsOverlap;

    const agent_count = static_dense_agent_count;
    var data = DataSystem.init(allocator);
    // `SeamFixture.init` owns `data` and `agents` from its call, on failure too.
    var handed_over = false;
    errdefer if (!handed_over) data.deinit();
    var agents = std.ArrayList(EntityId).empty;
    errdefer if (!handed_over) agents.deinit(allocator);
    try agents.ensureTotalCapacity(allocator, agent_count);

    const side = gridSide(agent_count);
    for (0..agent_count) |index| {
        agents.appendAssumeCapacity(try addAgent(&data, gridPosition(index, side)));
    }

    // Chunks overlapped by the agent grid: columns and rows 0 through the last agent's chunk.
    const last_agent_coord = @as(f32, @floatFromInt(side - 1)) * 18.0;
    const chunks_per_axis: usize = @as(usize, @intFromFloat(@floor(last_agent_coord / chunk_px))) + 1;
    const chunk_count = chunks_per_axis * chunks_per_axis;
    const per_chunk_tally = try allocator.alloc(usize, chunk_count);
    defer allocator.free(per_chunk_tally);
    @memset(per_chunk_tally, 0);

    // Every static's position, chunk by chunk.
    const positions = try allocator.alloc(math.Vec2, chunk_count * statics_per_chunk);
    defer allocator.free(positions);
    const slot_inset = (slot_pitch - static_size) * 0.5;
    for (0..chunk_count) |chunk_index| {
        const chunk_x = @as(f32, @floatFromInt(chunk_index % chunks_per_axis)) * chunk_px;
        const chunk_y = @as(f32, @floatFromInt(chunk_index / chunks_per_axis)) * chunk_px;
        for (0..statics_per_chunk) |slot| {
            const position = math.Vec2{
                .x = chunk_x + @as(f32, @floatFromInt(slot % slot_side)) * slot_pitch + slot_inset,
                .y = chunk_y + @as(f32, @floatFromInt(slot / slot_side)) * slot_pitch + slot_inset,
            };
            // Both corners land in the slot's chunk; coordinates are non-negative by construction.
            const min_chunk_x: usize = @intFromFloat(@floor(position.x / chunk_px));
            const min_chunk_y: usize = @intFromFloat(@floor(position.y / chunk_px));
            const max_chunk_x: usize = @intFromFloat(@floor((position.x + static_size) / chunk_px));
            const max_chunk_y: usize = @intFromFloat(@floor((position.y + static_size) / chunk_px));
            if (min_chunk_x != max_chunk_x or min_chunk_y != max_chunk_y) return error.StaticCrossesChunk;
            if (min_chunk_x >= chunks_per_axis or min_chunk_y >= chunks_per_axis) return error.StaticOutsideAgentChunks;
            per_chunk_tally[min_chunk_y * chunks_per_axis + min_chunk_x] += 1;
            positions[chunk_index * statics_per_chunk + slot] = position;
        }
    }
    for (per_chunk_tally) |tally| {
        if (tally != statics_per_chunk) return error.WrongStaticsPerChunk;
    }
    var prng = std.Random.DefaultPrng.init(static_dense_shuffle_seed);
    if (layout == .interleaved) prng.random().shuffle(math.Vec2, positions);
    const statics = try allocator.alloc(EntityId, positions.len);
    defer allocator.free(statics);
    for (statics, positions) |*entity, position| entity.* = try addStatic(&data, position);

    const nav_extent = @as(f32, @floatFromInt(chunks_per_axis)) * chunk_px;
    // Every layout's seam takes the churn's share: one destroy or create per churned static.
    handed_over = true;
    var steering = try SeamFixture.init(allocator, io, data, agents, nav_extent, nav_extent, structuralEventHeadroom(statics.len / 2, 0));
    errdefer steering.deinit(allocator);
    if (layout == .churned) try churnStatics(allocator, io, &steering, statics, positions, prng.random());
    if (static_colliders_test_support.liveRowCount(steering.colliders().*) != chunk_count * statics_per_chunk) return error.WrongStaticCount;
    return .{ .steering = steering };
}

// Destroys a `random` half of `statics` (at `positions`) in one commit, then recreates them
// at the same places in another, each through the production commit seam, as play does;
// `statics` is left holding the live ids.
fn churnStatics(
    allocator: std.mem.Allocator,
    io: std.Io,
    steering: *SeamFixture,
    statics: []EntityId,
    positions: []const math.Vec2,
    random: std.Random,
) !void {
    const order = try allocator.alloc(usize, statics.len);
    defer allocator.free(order);
    for (order, 0..) |*slot, index| slot.* = index;
    random.shuffle(usize, order);
    const churned = order[0 .. statics.len / 2];
    const commands = try allocator.alloc(StructuralCommand, churned.len);
    defer allocator.free(commands);
    // Untimed: the commits' stages run inline.
    var threads = try ThreadSystem.init(allocator, io, .{ .max_worker_threads = 0 });
    defer threads.deinit();

    for (commands, churned) |*command, index| command.* = .{ .destroy_entity = statics[index] };
    try churnCommit(steering, commands, &threads);
    if (static_colliders_test_support.liveRowCount(steering.colliders().*) != statics.len - churned.len) return error.StaticDestroysMissing;

    for (commands, churned) |*command, index| command.* = .{ .create_entity = .{
        .movement_body = .{ .position = positions[index], .previous_position = positions[index], .velocity = .{}, .speed = 0 },
        .collision_bounds = .{ .size = .{ .x = static_size, .y = static_size } },
        .collision_response = .{ .mode = .solid, .mobility = .static, .restitution = 0 },
    } };
    try churnCommit(steering, commands, &threads);
    var created: usize = 0;
    for (steering.seam.frame.structural_changes_scratch.items) |change| switch (change) {
        .entity_created => |entity| {
            statics[churned[created]] = entity;
            created += 1;
        },
        else => {},
    };
    if (created != churned.len) return error.StaticRecreatesMissing;
}

// `commands` as one step's commit through the production seam; fails unless every command
// changed a static.
fn churnCommit(steering: *SeamFixture, commands: []const StructuralCommand, thread_system: *ThreadSystem) !void {
    steering.seam.frame.beginStep();
    _ = try steering.commit(commands, thread_system);
    if (steering.colliders().changesThisStep().len != commands.len) return error.StaticChurnNotSynced;
}

fn runStaticDenseCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const code = try StaticDenseCode.decode(item_count);

    var fixture = try createStaticDenseFixture(allocator, io, code.statics_per_chunk, code.layout);
    defer fixture.deinit(allocator);
    const measured = try measureCase(allocator, io, options, case, code.statics_per_chunk, &fixture.steering.seam.pipeline.steering, fixture.steering.agents.items.len, null, &fixture, prepareStaticDense, staticDenseOnce);
    var stats = measured.stats;
    stats.candidate_pairs = measured.last.perf.obstacle_candidate_checks;
    stats.sample_count = measured.last.perf.obstacle_samples;
    // The header names the config; throughput stays per static per chunk.
    stats.item_count = item_count;
    return stats;
}

fn prepareStaticDense(fixture: *StaticDenseFixture) !void {
    try fixture.steering.prepare();
}

// One steering step; fails when the obstacle workload is empty or differs from the first step's.
fn staticDenseOnce(system: *SteeringSystem, fixture: *StaticDenseFixture, thread_system: *ThreadSystem, case: suite.BenchmarkCase) !SteeringStats {
    std.debug.assert(system == &fixture.steering.seam.pipeline.steering);
    const stats = try fixture.steering.step(thread_system, case);
    if (stats.movement_intent_count != fixture.steering.agents.items.len) return error.AgentIntentMissing;
    if (stats.perf.obstacle_samples == 0) return error.StaticsUnsampled;
    if (stats.perf.obstacle_samples > stats.perf.obstacle_candidate_checks) return error.SamplesExceedVisits;
    if (fixture.first_visits) |first_visits| {
        if (stats.perf.obstacle_candidate_checks != first_visits or stats.perf.obstacle_samples != fixture.first_samples) {
            return error.ObstacleWorkloadDrifted;
        }
    } else {
        fixture.first_visits = stats.perf.obstacle_candidate_checks;
        fixture.first_samples = stats.perf.obstacle_samples;
    }
    return stats;
}

fn writeSteeringWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("avoidance_checks={} samples={} intents={}", .{ stats.candidate_pairs, stats.sample_count, stats.output_count });
    if (view == .summary) return;
    try writer.writeByte(' ');
    try suite.writeSteeringStages(writer, stats);
    try writer.print(" band_max={}", .{(stats.steering_stages orelse suite.SteeringStageSummary{}).band_max});
    try writeSteerShape(writer, stats);
}

fn writeStaticChangeWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("obstacle_checks={} obstacle_samples={}", .{ stats.candidate_pairs, stats.sample_count });
    if (view == .summary) return;
    try writer.writeByte(' ');
    try suite.writeSteeringStages(writer, stats);
    try writeSteerShape(writer, stats);
}

fn writeStaticDenseWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    const visits_per_agent_tenths = if (stats.output_count == 0) 0 else stats.candidate_pairs * 10 / stats.output_count;
    try writer.print("obstacle_visits={} ({}.{}/agent) obstacle_samples={} intents={}", .{ stats.candidate_pairs, visits_per_agent_tenths / 10, visits_per_agent_tenths % 10, stats.sample_count, stats.output_count });
    if (view == .summary) return;
    try writer.writeByte(' ');
    try suite.writeSteeringStages(writer, stats);
    try writeSteerShape(writer, stats);
}

// The avoidance pass's shape and the main thread's share.
fn writeSteerShape(writer: *std.Io.Writer, stats: suite.RunStats) std.Io.Writer.Error!void {
    try writer.writeAll(" steer=");
    try suite.writeStageShape(writer, stats.batch);
    try suite.writeShare(writer, "main", stats.main_ns orelse 0, stats.mean_ns);
}
