// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Perception throughput: gather, shared index query, FOV filter, bounded LOS raycast, and
//! transition emit over one population per group, with the index and the think set (every
//! agent, in the index's cell-major order) built untimed.
//! - `perception`: observer/hostile pairs at ordinary sparse-tile density. Pass shape: time
//!   linear in observers, the main thread's time (the gather's window merge) flat per agent.
//! - `perception-los-dense`: the same pairs plus `los_dense_extra_sparse_tiles` sparse tiles
//!   no ray crosses, so only an LOS cost growing with tile count moves it. Pass shape: within
//!   spread of `perception`; asserts check its sensed, LOS, and found counts equal
//!   `perception`'s.
//! - `perception-scattered-dense-index`: `perception_dense_index` shuffled, so worker ranges
//!   write interleaved `PerceptionStore` slots. Pass shape: within spread of `perception`.
//! - `perception-cell-ordered`: the pairs created in the think set's order, so every
//!   `PerceptionStore` access ascends with the rows. Pass shape: `perception` within spread
//!   of it; asserts check the store slots ascend.
//! These four assert at most one neighbor-block fill per run of observer rows sharing a cell,
//! level, and faction, plus one per range. They print `sensed=`, `los_checks=`, `los_blocked=`,
//! `found=` (observers with a nearest threat), `events=` (perceived plus lost),
//! `dropped_events=`, and `block_fills=`; `--details` adds `main=` with `main_per_item=` and
//! `gather=` (the gather stage's shape).
//! - `perception-crowd`: separated clusters of one observer and one hostile ahead of it on
//!   its level. Variant `allies` puts the hostile at half the vision range with allies inside
//!   the range; `levels` stacks one hostile per level below at half the range and puts the
//!   same-level hostile past the stack. Pass shape: every observer finds its hostile, nothing
//!   is sensed across levels, and checks per observer stay flat in allies and levels. Asserts
//!   check a threat found per observer, one FOV survivor each, at most
//!   `crowd_max_checks_per_observer` checks, and a fixed threaded case dispatching the gather
//!   and compute to workers. Prints `threat_found=` (found over observers), `sensed=`,
//!   `block_fills=`, and `checks_per_observer=`; `--details` adds `main=` with
//!   `main_per_item=` (per observer) and `gather=`.
//! Stage shapes are over the measured steps (`[threaded/non-empty]`; the compute is the row's
//! batch). The tuned case settles both stage tuners before measuring, and `--details` prints
//! each one's state (`tuners:`).

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const math = @import("../core/math.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const Faction = @import("../game/data_system.zig").Faction;
const AiPerception = @import("../game/data_system.zig").AiPerception;
const SimulationEvents = @import("../game/simulation.zig").SimulationEvents;
const spatial_index_mod = @import("../game/systems/spatial_index.zig");
const IndexGeometry = spatial_index_mod.IndexGeometry;
const SpatialIndexSystem = spatial_index_mod.SpatialIndexSystem;
const SpatialIndexView = spatial_index_mod.SpatialIndexView;
const perception_mod = @import("../game/systems/perception.zig");
const PerceptionStats = perception_mod.PerceptionStats;
const PerceptionSystem = perception_mod.PerceptionSystem;
const perception_range_alignment_items = perception_mod.perception_range_alignment_items;
const WorldSystem = @import("../game/world/system.zig").WorldSystem;
const SimulationScopeSystem = @import("../game/systems/simulation_scope.zig").SimulationScopeSystem;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "perception",
    .item_label = "perception agents",
    .item_counts = &suite.event_scale_counts,
    .runCase = runCase,
    .write_workload = writePerceptionWorkload,
};

pub const los_dense_group = suite.BenchmarkGroup{
    .name = "perception-los-dense",
    .item_label = "perception agents",
    .item_counts = &suite.event_scale_counts,
    .runCase = runLosDenseCase,
    .write_workload = writePerceptionWorkload,
};

pub const scattered_dense_index_group = suite.BenchmarkGroup{
    .name = "perception-scattered-dense-index",
    .item_label = "perception agents",
    .item_counts = &suite.event_scale_counts,
    .runCase = runScatteredDenseIndexCase,
    .write_workload = writePerceptionWorkload,
};

pub const cell_ordered_group = suite.BenchmarkGroup{
    .name = "perception-cell-ordered",
    .item_label = "perception agents",
    .item_counts = &suite.event_scale_counts,
    .runCase = runCellOrderedCase,
    .write_workload = writePerceptionWorkload,
};

pub const crowd_group = suite.BenchmarkGroup{
    .name = "perception-crowd",
    .item_label = CrowdCode.label,
    .describe_item = CrowdCode.describe,
    .item_counts = &crowd_item_counts,
    .runCase = runCrowdCase,
    .write_workload = writeCrowdWorkload,
};

const CrowdVariant = enum(u8) { allies, levels };
// `axis` is the allies per observer (`allies`) or the level count (`levels`).
const CrowdCode = suite.ItemCode(struct { variant: CrowdVariant, axis: u32 }, &.{6});

const crowd_item_counts = [_]usize{
    CrowdCode.of(.{ .variant = .allies, .axis = 16 }),
    CrowdCode.of(.{ .variant = .allies, .axis = 64 }),
    CrowdCode.of(.{ .variant = .allies, .axis = 256 }),
    CrowdCode.of(.{ .variant = .levels, .axis = 2 }),
    CrowdCode.of(.{ .variant = .levels, .axis = 8 }),
    CrowdCode.of(.{ .variant = .levels, .axis = 32 }),
};

// Observers on a square grid of clusters. The pitch keeps every other cluster's members
// past the observer's vision range.
const crowd_grid_side: usize = 32;
const crowd_observers: usize = crowd_grid_side * crowd_grid_side;
const crowd_cluster_pitch: f32 = 384;
// Allies fill a square of this half-extent around their observer, inside its range.
const crowd_ally_half_extent: f32 = 84;
const crowd_observer_velocity_x: f32 = 10;
// Per-observer check bound, flat in allies and levels; the box meets only adjacent clusters
// (asserted in `createCrowdFixture`).
const crowd_max_checks_per_observer: usize = 9;
// The `levels` variant's same-level hostile, as a fraction of the vision range ahead.
const crowd_same_level_hostile_fraction: f32 = 0.75;

// Pairs are one tile apart, so a pair's blocking tile blocks no other pair's candidate.
const pair_grid_columns: usize = 128;
// Pairs sit on their row's center line, off the horizontal grid lines, so each
// pair's LOS stays the single same-cell check (a ray along a grid line also
// tests the row across it).
const pair_row_center: f32 = 0.5;
// The observer sits this fraction of a tile ahead of its candidate, in the candidate's tile,
// facing it.
const observer_offset_tile_fraction: f32 = 0.3;
const observer_facing_velocity_x: f32 = -10.0;

// Two tiles: short enough that the candidate cap never fills before an observer's own row
// is scanned, so `los_blocked` counts real occlusion.
const observer_vision_range: f32 = 64.0;

// Every 4th pair's candidate sits on a blocking tile.
const blocked_pair_period: usize = 4;

// Sparse tiles far outside the populated grid, only to inflate the world's tile count.
const los_dense_extra_sparse_tiles: usize = 20_000;
// Rows clear of the largest populated grid, so the extra tiles meet no agent's tile.
const los_dense_region_row_start: u16 = 210;
const los_dense_region_width: u16 = 200;
const world_tiles_side: u16 = 340;

const Fixture = struct {
    data: DataSystem,
    world: WorldSystem,

    fn deinit(self: *Fixture) void {
        self.world.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

fn addAgent(data: *DataSystem, pos_x: f32, pos_y: f32, velocity_x: f32, velocity_y: f32, faction: Faction) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{
        .position = .{ .x = pos_x, .y = pos_y },
        .previous_position = .{ .x = pos_x, .y = pos_y },
        .velocity = .{ .x = velocity_x, .y = velocity_y },
        .speed = 40,
    });
    try data.setAiAgent(entity, .{ .active_behavior = .wander });
    try data.setFaction(entity, faction);
    return entity;
}

fn addObserver(data: *DataSystem, pos_x: f32, pos_y: f32, velocity_x: f32, velocity_y: f32) !EntityId {
    const entity = try addAgent(data, pos_x, pos_y, velocity_x, velocity_y, .player);
    try data.setAiPerception(entity, .{ .vision_range = observer_vision_range });
    return entity;
}

fn createFixture(allocator: std.mem.Allocator, io: std.Io, count: usize, extra_sparse_tiles: usize) !Fixture {
    return createFixtureInOrder(allocator, io, count, extra_sparse_tiles, null);
}

// `createFixture`'s pairs created in `order` (pair `order[k]` k-th), or in pair order.
fn createFixtureInOrder(allocator: std.mem.Allocator, io: std.Io, count: usize, extra_sparse_tiles: usize, order: ?[]const u32) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    var tileset = try fixtures.loadTilesetMeta(allocator, io);
    defer tileset.deinit();
    var world = try fixtures.buildBandedWorld(allocator, &tileset, world_tiles_side, 1, "grass", "grass");
    errdefer world.deinit();
    const tile_size = world.tile_size;
    const tree = try world.requireTileByName(&tileset, "tree_0");
    const deco = try world.requireTileByName(&tileset, "deco_0");

    const observer_offset_x = tile_size * observer_offset_tile_fraction;
    const pair_count = count / 2;
    std.debug.assert(order == null or order.?.len == pair_count);
    var step: usize = 0;
    while (step < pair_count) : (step += 1) {
        const pair_index: usize = if (order) |pairs| pairs[step] else step;
        const gx = @as(f32, @floatFromInt(pair_index % pair_grid_columns)) * tile_size;
        const gy = (@as(f32, @floatFromInt(pair_index / pair_grid_columns)) + pair_row_center) * tile_size;
        _ = try addAgent(&data, gx, gy, 0, 0, .hostile);
        _ = try addObserver(&data, gx + observer_offset_x, gy, observer_facing_velocity_x, 0);

        if (pair_index % blocked_pair_period == blocked_pair_period - 1) {
            const cell = world.cellContaining(gx, gy) orelse continue;
            _ = try world.addSparseTile(0, cell.x, cell.y, tree, 0, .obstacle);
        }
    }

    var extra_index: usize = 0;
    while (extra_index < extra_sparse_tiles) : (extra_index += 1) {
        const x: u16 = @intCast(extra_index % los_dense_region_width);
        const y: u16 = los_dense_region_row_start + @as(u16, @intCast(extra_index / los_dense_region_width));
        _ = try world.addSparseTile(0, x, y, deco, 0, .obstacle);
    }

    return .{ .data = data, .world = world };
}

// `createFixture`'s pairs with `setAiPerception` called in a shuffled observer order, so
// `perception_dense_index` is decorrelated from the gather row order.
fn createDecorrelatedFixture(allocator: std.mem.Allocator, io: std.Io, count: usize) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    var tileset = try fixtures.loadTilesetMeta(allocator, io);
    defer tileset.deinit();
    var world = try fixtures.buildBandedWorld(allocator, &tileset, world_tiles_side, 1, "grass", "grass");
    errdefer world.deinit();
    const tile_size = world.tile_size;
    const tree = try world.requireTileByName(&tileset, "tree_0");

    const observer_offset_x = tile_size * observer_offset_tile_fraction;
    const pair_count = count / 2;
    const shuffle_stride = fixtures.coprimeStride(fixtures.shuffle_stride, pair_count);
    std.debug.assert(pair_count == 0 or std.math.gcd(shuffle_stride, pair_count) == 1);

    var observers = std.ArrayList(EntityId).empty;
    defer observers.deinit(allocator);
    try observers.ensureTotalCapacity(allocator, pair_count);

    var pair_index: usize = 0;
    while (pair_index < pair_count) : (pair_index += 1) {
        const gx = @as(f32, @floatFromInt(pair_index % pair_grid_columns)) * tile_size;
        const gy = (@as(f32, @floatFromInt(pair_index / pair_grid_columns)) + pair_row_center) * tile_size;
        _ = try addAgent(&data, gx, gy, 0, 0, .hostile);
        // `setAiPerception` waits for the shuffled pass.
        const observer = try addAgent(&data, gx + observer_offset_x, gy, observer_facing_velocity_x, 0, .player);
        observers.appendAssumeCapacity(observer);

        if (pair_index % blocked_pair_period == blocked_pair_period - 1) {
            const cell = world.cellContaining(gx, gy) orelse continue;
            _ = try world.addSparseTile(0, cell.x, cell.y, tree, 0, .obstacle);
        }
    }

    var step: usize = 0;
    while (step < pair_count) : (step += 1) {
        const source = (step * shuffle_stride) % pair_count;
        try data.setAiPerception(observers.items[source], .{ .vision_range = observer_vision_range });
    }

    return .{ .data = data, .world = world };
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseImpl(allocator, io, options, case, item_count, buildDefaultFixture);
}

pub fn runLosDenseCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    const stats = try runCaseImpl(allocator, io, options, case, item_count, buildLosDenseFixture);
    if (stats.status == .skipped) return stats;
    // The extra tiles change no count.
    const plain = try untimedCounts(allocator, io, item_count);
    std.debug.assert(stats.sample_count == plain.perf.sensed_count and stats.candidate_pairs == plain.perf.los_checks);
    std.debug.assert(stats.deferred_count == plain.perf.los_blocked and stats.output_count == plain.perf.nearest_threat_found_count);
    return stats;
}

// One untimed inline step over the default fixture.
fn untimedCounts(allocator: std.mem.Allocator, io: std.Io, item_count: usize) !PerceptionStats {
    var setup_threads = try ThreadSystem.init(allocator, io, .{ .max_worker_threads = 0 });
    defer setup_threads.deinit();
    var fixture = try buildDefaultFixture(allocator, io, item_count);
    defer fixture.deinit();
    var system = PerceptionSystem.init(allocator);
    defer system.deinit();
    var events = SimulationEvents.init(allocator);
    defer events.deinit();
    var spatial_sys = SpatialIndexSystem.init(allocator);
    defer spatial_sys.deinit();
    _ = try spatial_sys.build(&fixture.data, .{ .entities = fixture.data.aiAgentSliceConst().entities }, IndexGeometry.ofWorld(&fixture.world), &setup_threads, .{});
    const spatial_view = spatial_sys.view();
    var scope = SimulationScopeSystem.init(allocator);
    defer scope.deinit();
    const think_set = (try scope.compactCognition(&spatial_view, 0, false, &setup_threads, .{})).cognition;
    return runOnce(&system, &fixture, spatial_view, think_set, &events, &setup_threads, suite.serial_cases[0]);
}

pub fn runScatteredDenseIndexCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseImpl(allocator, io, options, case, item_count, buildScatteredDenseIndexFixture);
}

pub fn runCellOrderedCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    const stats = try runCaseImpl(allocator, io, options, case, item_count, buildCellOrderedFixture);
    if (stats.status == .skipped) return stats;
    // The same pairs: the same counts as the default order.
    const plain = try untimedCounts(allocator, io, item_count);
    std.debug.assert(stats.sample_count == plain.perf.sensed_count and stats.output_count == plain.perf.nearest_threat_found_count);
    return stats;
}

// The default fixture's pairs in its think set's observer order: an observer's AI row is its
// pair's second (`addAgent` hostile, then observer).
fn buildCellOrderedFixture(allocator: std.mem.Allocator, io: std.Io, item_count: usize) !Fixture {
    var setup_threads = try ThreadSystem.init(allocator, io, .{ .max_worker_threads = 0 });
    defer setup_threads.deinit();
    var plain = try buildDefaultFixture(allocator, io, item_count);
    defer plain.deinit();
    var spatial_sys = SpatialIndexSystem.init(allocator);
    defer spatial_sys.deinit();
    _ = try spatial_sys.build(&plain.data, .{ .entities = plain.data.aiAgentSliceConst().entities }, IndexGeometry.ofWorld(&plain.world), &setup_threads, .{});
    const view = spatial_sys.view();
    var scope = SimulationScopeSystem.init(allocator);
    defer scope.deinit();
    const think_set = (try scope.compactCognition(&view, 0, false, &setup_threads, .{})).cognition;
    const order = try allocator.alloc(u32, item_count / 2);
    defer allocator.free(order);
    var observers: usize = 0;
    for (think_set) |row| {
        if (row % 2 == 0) continue;
        order[observers] = row / 2;
        observers += 1;
    }
    std.debug.assert(observers == order.len);
    var fixture = try createFixtureInOrder(allocator, io, item_count, 0, order);
    errdefer fixture.deinit();
    // The new think set walks the observers, so their store slots, in creation order.
    var ordered_index = SpatialIndexSystem.init(allocator);
    defer ordered_index.deinit();
    _ = try ordered_index.build(&fixture.data, .{ .entities = fixture.data.aiAgentSliceConst().entities }, IndexGeometry.ofWorld(&fixture.world), &setup_threads, .{});
    const ordered_view = ordered_index.view();
    var next_observer: u32 = 1;
    for ((try scope.compactCognition(&ordered_view, 0, false, &setup_threads, .{})).cognition) |row| {
        if (row % 2 == 0) continue;
        std.debug.assert(row == next_observer);
        next_observer += 2;
    }
    return fixture;
}

fn buildDefaultFixture(allocator: std.mem.Allocator, io: std.Io, item_count: usize) !Fixture {
    return createFixture(allocator, io, item_count, 0);
}

fn buildLosDenseFixture(allocator: std.mem.Allocator, io: std.Io, item_count: usize) !Fixture {
    return createFixture(allocator, io, item_count, los_dense_extra_sparse_tiles);
}

fn buildScatteredDenseIndexFixture(allocator: std.mem.Allocator, io: std.Io, item_count: usize) !Fixture {
    return createDecorrelatedFixture(allocator, io, item_count);
}

fn runCaseImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: suite.Options,
    case: suite.BenchmarkCase,
    item_count: usize,
    buildFixture: *const fn (std.mem.Allocator, std.Io, usize) anyerror!Fixture,
) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try buildFixture(allocator, io, item_count);
    defer fixture.deinit();

    var system = PerceptionSystem.init(allocator);
    defer system.deinit();

    var events = SimulationEvents.init(allocator);
    defer events.deinit();

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();

    // Positions never change, so the shared index is built once, untimed.
    var spatial_sys = SpatialIndexSystem.init(allocator);
    defer spatial_sys.deinit();
    _ = try spatial_sys.build(&fixture.data, .{ .entities = fixture.data.aiAgentSliceConst().entities }, IndexGeometry.ofWorld(&fixture.world), &threads, .{ .adaptive = false });
    const spatial_view = spatial_sys.view();
    var scope = SimulationScopeSystem.init(allocator);
    defer scope.deinit();
    const think_set = (try scope.compactCognition(&spatial_view, 0, false, &threads, .{ .adaptive = false })).cognition;

    var warm = suite.Warmup.init(options, case, 0);
    while (warm.nextSettled(stageTunerSettle(&system))) {
        events.clearRetainingCapacity();
        _ = try runOnce(&system, &fixture, spatial_view, think_set, &events, &threads, case);
    }
    const settle = stageTunerSettle(&system);
    const compute_tuner_start = suite.TunerStart.of(&system.compute_tuner, case);
    const tuner_window = suite.TunerWindow(stage_names.len).begin(stageTuners(&system));
    var shapes = suite.StageShapes(stage_names.len){};

    var accumulator = suite.StatsAccumulator.init(item_count);
    // Sensed, LOS, and found counts are the same every step; transitions occur once.
    var last_stats = PerceptionStats{};
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        events.clearRetainingCapacity();
        const start_ns = suite.nowNs(io);
        last_stats = try runOnce(&system, &fixture, spatial_view, think_set, &events, &threads, case);
        const end_ns = suite.nowNs(io);
        const elapsed_ns = suite.elapsedNs(start_ns, end_ns);
        accumulator.record(elapsed_ns, last_stats.perf.batch);
        shapes.add(.{ last_stats.perf.gather_batch, last_stats.perf.batch });
        try suite.checkStagesDispatched(case, &threads, case.stageItemsPerRange(perception_range_alignment_items), &.{ last_stats.perf.gather_batch, last_stats.perf.batch });
        main_total += elapsed_ns -| (offMainNs(last_stats.perf.gather_batch) + offMainNs(last_stats.perf.batch));
    }

    std.debug.assert(last_stats.perf.block_fills <= observerCellRuns(&fixture.data, &system, spatial_view) + last_stats.perf.batch.range_count);
    var stats = accumulator.finish();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    stats.output_count = last_stats.perf.nearest_threat_found_count;
    stats.candidate_pairs = last_stats.perf.los_checks;
    stats.sample_count = last_stats.perf.sensed_count;
    stats.deferred_count = last_stats.perf.los_blocked;
    stats.fallback_deferred_count = events.stats.entity_perceived + events.stats.entity_lost;
    stats.cache_evictions = events.stats.dropped;
    stats.neighbor_block_fills = last_stats.perf.block_fills;
    stats.splice_batch = suite.batchSummaryFromShapes(&shapes, 0);
    reportTuners(&stats, &system, case, settle, tuner_window, compute_tuner_start);
    return stats;
}

// The step's stages, each under its own tuner: the observer gather, then the compute.
const stage_names = [_][]const u8{ "gather", "compute" };

fn stageTuners(system: *const PerceptionSystem) [stage_names.len]*const AdaptiveWorkTuner {
    return .{ &system.gather_tuner, &system.compute_tuner };
}

fn stageTunerSettle(system: *const PerceptionSystem) suite.TunerSettle {
    return suite.TunerSettle.of(PerceptionSystem, system);
}

// The tuned case's census, its compute tuner (the row's), and both stage tuners' states.
fn reportTuners(stats: *suite.RunStats, system: *const PerceptionSystem, case: suite.BenchmarkCase, settle: suite.TunerSettle, window: suite.TunerWindow(stage_names.len), compute_start: suite.TunerStart) void {
    if (!case.adaptive) return;
    stats.tuner_settle = settle.measured();
    stats.work_tuning = suite.workTuningSummary(&system.compute_tuner, compute_start);
    window.printTuning(&stats.details, stage_names, stageTuners(system));
}

// The runs of consecutive observer rows sharing a level, index cell, and faction: the
// fixture's keys, with one vision range.
fn observerCellRuns(data: *const DataSystem, system: *const PerceptionSystem, view: SpatialIndexView) usize {
    const rows = system.rows.slice();
    var runs: usize = 0;
    var previous: ?[4]u32 = null;
    for (rows.items(.entity), rows.items(.pos_x), rows.items(.pos_y)) |entity, x, y| {
        const key = [4]u32{ data.worldLevelConst(entity) orelse 0, math.worldPosToCell(x, view.cell_size, view.cells_x), math.worldPosToCell(y, view.cell_size, view.cells_y), @backingInt(data.factionConst(entity) orelse .neutral) };
        if (previous == null or !std.mem.eql(u32, &previous.?, &key)) runs += 1;
        previous = key;
    }
    return runs;
}

fn runOnce(
    system: *PerceptionSystem,
    fixture: *Fixture,
    spatial_view: SpatialIndexView,
    think_set: []const u32,
    events: *SimulationEvents,
    thread_system: *ThreadSystem,
    case: suite.BenchmarkCase,
) !PerceptionStats {
    const ai_slice = fixture.data.aiAgentSliceConst();
    const movement_slice = fixture.data.movementBodySliceConst();

    return try system.update(ai_slice, movement_slice, spatial_view, &fixture.world, &fixture.data, events, thread_system, .{
        .items_per_range = case.stageItemsPerRange(perception_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
        .scope_dense_indices = think_set,
    });
}

// `neighbor_block_fills` holds the block fills, `splice_batch` the gather, and `main` the
// time outside the gather's and compute's worker dispatches, also per agent.
fn writePerceptionWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("sensed={} los_checks={} los_blocked={} found={} events={} dropped_events={} block_fills={}", .{ stats.sample_count, stats.candidate_pairs, stats.deferred_count, stats.output_count, stats.fallback_deferred_count, stats.cache_evictions, stats.neighbor_block_fills });
    if (view == .summary) return;
    try suite.writeMainShare(writer, stats, stats.item_count);
    if (stats.splice_batch) |gather| {
        try writer.writeAll(" gather=");
        try suite.writeStageShape(writer, gather);
    }
}

const CrowdFixture = struct {
    data: DataSystem,
    world: WorldSystem,

    fn deinit(self: *CrowdFixture) void {
        self.world.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

fn createCrowdFixture(allocator: std.mem.Allocator, io: std.Io, variant: CrowdVariant, axis: u32) !CrowdFixture {
    const vision_range = (AiPerception{}).vision_range;
    const side_px = @as(f32, @floatFromInt(crowd_grid_side)) * crowd_cluster_pitch;
    // Every member sits inside its observer's range. Another cluster's allies sit past it;
    // its hostiles sit ahead of their own observer, so one in range lies behind this one,
    // outside its cone.
    const hostile_reach = vision_range * crowd_same_level_hostile_fraction;
    std.debug.assert(@max(crowd_ally_half_extent * std.math.sqrt2, hostile_reach) < vision_range);
    std.debug.assert(crowd_cluster_pitch - crowd_ally_half_extent > vision_range and hostile_reach < crowd_cluster_pitch);
    // The query box, the vision range rounded up to whole cells plus the observer's own
    // cell on each axis, misses every cluster past the adjacent ones.
    const cell_size = (spatial_index_mod.SpatialIndexConfig{}).cell_size;
    const box_reach = (@ceil(vision_range / cell_size) + 1) * cell_size;
    std.debug.assert(2 * crowd_cluster_pitch - hostile_reach > box_reach);
    const levels: u16 = switch (variant) {
        .allies => 1,
        .levels => @intCast(axis),
    };
    var tileset = try fixtures.loadTilesetMeta(allocator, io);
    defer tileset.deinit();
    const side_tiles: u16 = @intFromFloat(@ceil(side_px / tileset.tileSize()));
    var world = try fixtures.buildBandedWorld(allocator, &tileset, side_tiles, levels, "grass", "grass");
    errdefer world.deinit();
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    const ally_side = suite.ceilSqrt(axis);
    const ally_pitch = 2 * crowd_ally_half_extent / @as(f32, @floatFromInt(ally_side));
    for (0..crowd_observers) |cluster| {
        const center_x = (@as(f32, @floatFromInt(cluster % crowd_grid_side)) + 0.5) * crowd_cluster_pitch;
        const center_y = (@as(f32, @floatFromInt(cluster / crowd_grid_side)) + 0.5) * crowd_cluster_pitch;
        const observer = try addAgent(&data, center_x, center_y, crowd_observer_velocity_x, 0, .player);
        try data.setAiPerception(observer, .{});
        const hostile_x = center_x + vision_range * 0.5;
        // Past the stacked hostiles, still inside the range.
        const same_level_hostile_x = center_x + vision_range * crowd_same_level_hostile_fraction;
        switch (variant) {
            .allies => {
                _ = try addAgent(&data, hostile_x, center_y, 0, 0, .hostile);
                for (0..axis) |ally| {
                    _ = try addAgent(
                        &data,
                        center_x - crowd_ally_half_extent + (@as(f32, @floatFromInt(ally % ally_side)) + 0.5) * ally_pitch,
                        center_y - crowd_ally_half_extent + (@as(f32, @floatFromInt(ally / ally_side)) + 0.5) * ally_pitch,
                        0,
                        0,
                        .player,
                    );
                }
            },
            .levels => {
                for (1..levels) |level| {
                    const hostile = try addAgent(&data, hostile_x, center_y, 0, 0, .hostile);
                    try data.setWorldLevel(hostile, @intCast(level));
                }
                _ = try addAgent(&data, same_level_hostile_x, center_y, 0, 0, .hostile);
            },
        }
    }
    std.debug.assert(data.perceptionSlice().entities.len == crowd_observers);
    return .{ .data = data, .world = world };
}

fn runCrowdCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const fields = try CrowdCode.decode(item_count);
    var fixture = try createCrowdFixture(allocator, io, fields.variant, fields.axis);
    defer fixture.deinit();

    var system = PerceptionSystem.init(allocator);
    defer system.deinit();
    var events = SimulationEvents.init(allocator);
    defer events.deinit();
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();

    // Positions never change, so the shared index is built once, untimed.
    var spatial_sys = SpatialIndexSystem.init(allocator);
    defer spatial_sys.deinit();
    _ = try spatial_sys.build(&fixture.data, .{ .entities = fixture.data.aiAgentSliceConst().entities }, IndexGeometry.ofWorld(&fixture.world), &threads, .{ .adaptive = false });
    const spatial_view = spatial_sys.view();
    const thread_ptr = &threads;
    var scope = SimulationScopeSystem.init(allocator);
    defer scope.deinit();
    const think_set = (try scope.compactCognition(&spatial_view, 0, false, &threads, .{ .adaptive = false })).cognition;

    var warm = suite.Warmup.init(options, case, 0);
    while (warm.nextSettled(stageTunerSettle(&system))) {
        events.clearRetainingCapacity();
        _ = try runCrowdOnce(&system, &fixture, spatial_view, think_set, &events, thread_ptr, case);
    }
    const settle = stageTunerSettle(&system);
    const compute_tuner_start = suite.TunerStart.of(&system.compute_tuner, case);
    const tuner_window = suite.TunerWindow(stage_names.len).begin(stageTuners(&system));
    var shapes = suite.StageShapes(stage_names.len){};

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PerceptionStats{};
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        events.clearRetainingCapacity();
        const start_ns = suite.nowNs(io);
        last_stats = try runCrowdOnce(&system, &fixture, spatial_view, think_set, &events, thread_ptr, case);
        const end_ns = suite.nowNs(io);
        const elapsed_ns = suite.elapsedNs(start_ns, end_ns);
        accumulator.record(elapsed_ns, last_stats.perf.batch);
        shapes.add(.{ last_stats.perf.gather_batch, last_stats.perf.batch });
        try suite.checkStagesDispatched(case, thread_ptr, case.stageItemsPerRange(perception_range_alignment_items), &.{ last_stats.perf.gather_batch, last_stats.perf.batch });
        main_total += elapsed_ns -| (offMainNs(last_stats.perf.gather_batch) + offMainNs(last_stats.perf.batch));
    }
    std.debug.assert(last_stats.perf.observer_count == crowd_observers);
    std.debug.assert(last_stats.perf.nearest_threat_found_count == crowd_observers);
    std.debug.assert(last_stats.perf.sensed_count == crowd_observers);
    std.debug.assert(last_stats.perf.candidate_checks <= crowd_observers * crowd_max_checks_per_observer);

    var stats = accumulator.finish();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    stats.items_per_second = suite.itemsPerSecond(last_stats.perf.observer_count, stats.mean_ns);
    stats.deferred_count = last_stats.perf.observer_count;
    stats.output_count = last_stats.perf.nearest_threat_found_count;
    stats.sample_count = last_stats.perf.sensed_count;
    stats.candidate_pairs = last_stats.perf.candidate_checks;
    stats.neighbor_block_fills = last_stats.perf.block_fills;
    stats.splice_batch = suite.batchSummaryFromShapes(&shapes, 0);
    reportTuners(&stats, &system, case, settle, tuner_window, compute_tuner_start);
    return stats;
}

fn runCrowdOnce(
    system: *PerceptionSystem,
    fixture: *CrowdFixture,
    spatial_view: SpatialIndexView,
    think_set: []const u32,
    events: *SimulationEvents,
    thread_system: *ThreadSystem,
    case: suite.BenchmarkCase,
) !PerceptionStats {
    const ai_slice = fixture.data.aiAgentSliceConst();
    const movement_slice = fixture.data.movementBodySliceConst();
    return try system.update(ai_slice, movement_slice, spatial_view, &fixture.world, &fixture.data, events, thread_system, .{
        .items_per_range = case.stageItemsPerRange(perception_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
        .scope_dense_indices = think_set,
    });
}

// `deferred_count` holds the observers, `output_count` those that found a threat,
// `sample_count` the sensed candidates, `candidate_pairs` the index candidate checks, and
// `neighbor_block_fills` the block fills; `main` is the time outside the gather's and
// compute's worker dispatches, also per observer.
fn writeCrowdWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    const observers = @max(stats.deferred_count, 1);
    try writer.print("threat_found={}/{} sensed={} block_fills={} checks_per_observer={d:.2}", .{
        stats.output_count,
        stats.deferred_count,
        stats.sample_count,
        stats.neighbor_block_fills,
        @as(f64, @floatFromInt(stats.candidate_pairs)) / @as(f64, @floatFromInt(observers)),
    });
    if (view == .summary) return;
    try suite.writeMainShare(writer, stats, observers);
    if (stats.splice_batch) |gather| {
        try writer.writeAll(" gather=");
        try suite.writeStageShape(writer, gather);
    }
}
