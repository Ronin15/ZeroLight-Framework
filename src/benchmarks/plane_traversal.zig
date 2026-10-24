// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Plane traversal's per-agent cost: every AI agent crosses a cell boundary each step on the
//! walkable level 0 of a 2-level world (solid level 1 below). The item count is the AI agent
//! count, except in the banded group.
//!   - `plane-traversal`: no holes or ramps, so nothing traverses: the worst case for the
//!     per-agent cell-entry test.
//!   - `plane-traversal-falls`: the same plus a fixed 64 agents (fewer with fewer agents)
//!     entering their own level-0 hole: 64 falls and landing carves per step.
//!   - `plane-traversal-dense-falls`: an explosion under the crowd: every 4th agent enters its
//!     own hole, so falls and carves scale with the agents.
//!   - `plane-traversal-dense-falls-banded`: the worst-case landing shape. A fixed 4096 agents
//!     (1024 fallers) land on a level holding the item count of dense bands (one floor, the
//!     rest walkable overlays) and as many walkable sparse tiles per chunk; main time per
//!     entry against the band count shows whether a landing costs its level's bands and
//!     sparse tiles.
//! Timed: the production plane stage (`simulation_pipeline.runPlaneTraversal`): the NPC
//! cell-entry gather, the dig reserve and commit over its entries with the carve batch, and
//! the carves' nav record, on the case's threads (none for the serial case). The untimed
//! reset applies the recorded nav marks, puts the fallers back on level 0, refills their
//! landing cells, and begins the next frame step. The carves run on the world's terrain-edit
//! tuners under the case's controls. `--details` reports the headline's shape (the gather;
//! the carve write for the dense-falls groups, which are judged on landings), the stage's
//! main-thread time (all but a dispatched gather, carve, or mark batch), its share, and its
//! time per entry, then every stage's shape over the measured steps (`stages:`) and, for the
//! tuned case, each stage tuner's state (`tuners:`). The tuned case settles the gather, carve,
//! and nav tuners before measuring; a fixed threaded case runs each stage of more than one
//! range on workers.

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const DigConfig = @import("../game/dig_controller.zig").DigConfig;
const DigController = @import("../game/dig_controller.zig").DigController;
const Player = @import("../game/player.zig").Player;
const PlaneEntrySystem = @import("../game/systems/plane_entry.zig").PlaneEntrySystem;
const PathfindingSystem = @import("../game/systems/pathfinding.zig").PathfindingSystem;
const StaticColliderSystem = @import("../game/systems/static_colliders.zig").StaticColliderSystem;
const runPlaneTraversal = @import("../game/simulation_pipeline.zig").runPlaneTraversal;
const plane_entry_range_alignment_items = @import("../game/systems/plane_entry.zig").plane_entry_range_alignment_items;
const WorldSystem = @import("../game/world/system.zig").WorldSystem;
const TileId = @import("../game/world/system.zig").TileId;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const maxEventsPerStep = @import("../game/simulation.zig").maxEventsPerStep;
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const StageControls = @import("../app/thread_system.zig").StageControls;
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

const level_count: u16 = 2;
// Falls per step in the falls group.
const fixed_falls_per_step: usize = 64;
// Agents per faller in the dense-falls group.
const dense_agents_per_faller: usize = 4;

const item_counts = [_]usize{ 1_024, 4_096, 16_384 };
// The banded group's landing-level band counts, and its fixed agent count.
const band_counts = [_]usize{ 4, 32, 256 };
const banded_agent_count: usize = 4_096;

const Workload = enum {
    no_falls,
    fixed_falls,
    dense_falls,
    banded_falls,

    fn fallerCount(self: Workload, agent_count: usize) usize {
        return switch (self) {
            .no_falls => 0,
            .fixed_falls => @min(fixed_falls_per_step, agent_count),
            .dense_falls, .banded_falls => agent_count / dense_agents_per_faller,
        };
    }

    // One world at every default size: the dense group's 4096 fallers take a quarter of
    // a 128-tile level. Doubles only when the fallers would fill over half the level.
    fn worldSide(self: Workload, faller_count: usize) u16 {
        var side: usize = if (self == .dense_falls or self == .banded_falls) 128 else 64;
        while (faller_count > side * side / 2) side *= 2;
        return @intCast(side);
    }
};

// Where the fallers' holes are: the `hole_columns` east columns of level 0, filled
// column-major. Each faller enters its hole from the cell to its west; every other
// agent crosses between columns `0..walker_columns`, never reaching a faller's cell.
const Layout = struct {
    side: u16,
    first_hole_x: u16,
    walker_columns: u16,

    fn of(side: u16, faller_count: usize) Layout {
        // At least one, so walkers keep the same columns with no fallers as with few.
        const hole_columns: u16 = @intCast(@max(1, @divCeil(faller_count, side)));
        const first_hole_x = side - hole_columns;
        // Fallers fill at most half the level, so walkers keep at least half its columns.
        std.debug.assert(first_hole_x >= side / 2);
        return .{ .side = side, .first_hole_x = first_hole_x, .walker_columns = first_hole_x - 2 };
    }

    // Both coordinates are below `side`, a `u16`.
    fn hole(self: Layout, faller_index: usize) [2]u16 {
        return .{ self.first_hole_x + @as(u16, @intCast(faller_index / self.side)), @intCast(faller_index % self.side) };
    }
};

pub const group = suite.BenchmarkGroup{
    .name = "plane-traversal",
    .item_label = "AI agents",
    .item_counts = &item_counts,
    .runCase = runNoFallsCase,
    .write_workload = writePlaneAgentsWorkload,
};

pub const falls_group = suite.BenchmarkGroup{
    .name = "plane-traversal-falls",
    .item_label = "AI agents",
    .item_counts = &item_counts,
    .runCase = runFallsCase,
    .write_workload = writePlaneAgentsWorkload,
};

pub const dense_falls_group = suite.BenchmarkGroup{
    .name = "plane-traversal-dense-falls",
    .item_label = "AI agents",
    .item_counts = &item_counts,
    .runCase = runDenseFallsCase,
    .write_workload = writePlaneAgentsWorkload,
};

pub const banded_falls_group = suite.BenchmarkGroup{
    .name = "plane-traversal-dense-falls-banded",
    .item_label = std.fmt.comptimePrint("landing-level bands ({} AI agents)", .{banded_agent_count}),
    .item_counts = &band_counts,
    .runCase = runBandedFallsCase,
    .write_workload = writePlaneBandsWorkload,
};

const Faller = struct {
    entity: EntityId,
    hole: [2]u16,
};

const Fixture = struct {
    allocator: std.mem.Allocator,
    world: WorldSystem,
    data: DataSystem,
    frame: SimulationFrame,
    dig: DigController,
    plane_entry: PlaneEntrySystem,
    // Nav over the world, with no statics: the stage records its carves into it.
    colliders: StaticColliderSystem,
    nav: PathfindingSystem,
    player: Player,
    fallers: std.ArrayList(Faller) = .empty,
    dirt: TileId,

    fn deinit(self: *Fixture) void {
        self.fallers.deinit(self.allocator);
        self.nav.deinit();
        self.colliders.deinit();
        self.plane_entry.deinit();
        self.dig.deinit();
        self.frame.deinit();
        self.data.deinit();
        self.world.deinit();
        self.* = undefined;
    }

    // Untimed, before each stage: applies the last stage's nav marks, puts every faller back
    // on level 0 entering its hole, refills its landing cell, and begins the frame step.
    fn resetStep(self: *Fixture, thread_system: *ThreadSystem) !void {
        _ = try self.nav.applyBufferedNavUpdates(&self.colliders, &self.world, thread_system);
        const tile_size = self.world.tile_size;
        const floor1 = self.world.denseFloorLayerForLevel(1).?;
        for (self.fallers.items) |faller| {
            const x, const y = faller.hole;
            try self.data.setWorldLevel(faller.entity, 0);
            const body = self.data.movementBodyPtr(faller.entity).?;
            body.previous_x.* = @as(f32, @floatFromInt(x - 1)) * tile_size;
            body.previous_y.* = @as(f32, @floatFromInt(y)) * tile_size;
            body.position_x.* = @as(f32, @floatFromInt(x)) * tile_size;
            body.position_y.* = @as(f32, @floatFromInt(y)) * tile_size;
            body.position_z.* = self.world.levelBaseZ(0);
            _ = try self.world.setDenseTile(floor1, x, y, self.dirt);
        }
        self.frame.beginStep();
    }

    // The stage's tuners in `stage_names` order.
    fn stageTuners(self: *const Fixture) [stage_names.len]*const AdaptiveWorkTuner {
        return .{ &self.plane_entry.tuner, &self.world.terrain_edit_plan_tuner, &self.world.terrain_edit_write_tuner, &self.nav.tuners.nav_mark };
    }

    // The last stage's batches in `stage_names` order.
    fn stageBatches(self: *const Fixture) [stage_names.len]BatchStats {
        return .{ self.plane_entry.perf.last_batch, self.world.perf.last_terrain_edit_plan_batch, self.world.perf.last_terrain_edit_write_batch, self.nav.perf.last_mark_batch };
    }

    // Every tuner a stage and its untimed reset run: the stage's, and the nav set the
    // reset's update applies the marks on (`fixtures.addNavTuners`).
    fn tunerSettle(self: *const Fixture) suite.TunerSettle {
        var census = suite.TunerSettle{};
        census.addNamed(stage_names[0..mark_stage], self.stageTuners()[0..mark_stage]);
        fixtures.addNavTuners(&census, "nav.", &self.nav.tuners);
        return census;
    }
};

// A grass surface over one solid dirt level, with one level-0 hole per faller. Agent
// `index` crosses one cell boundary to the right; the first `faller_count` multiples of
// `agent_count / faller_count` walk into their own hole instead. `landing_bands` is the
// dirt level's band count (its floor first) and its walkable sparse tiles per chunk.
fn buildFixture(allocator: std.mem.Allocator, io: std.Io, agent_count: usize, workload: Workload, landing_bands: usize, participant_count: usize) !Fixture {
    const faller_count = workload.fallerCount(agent_count);
    std.debug.assert(faller_count <= agent_count);
    const layout = Layout.of(workload.worldSide(faller_count), faller_count);
    var tileset = try fixtures.loadTilesetMeta(allocator, io);
    defer tileset.deinit();
    const meta = &tileset;
    var world = try fixtures.buildBandedWorld(allocator, meta, layout.side, level_count, "grass", "dirt");
    errdefer world.deinit();
    const dirt = try world.requireTileByName(meta, "dirt");
    const dig_config = try DigConfig.fromMeta(meta);
    // The landing level's extra walkable bands and sparse tiles, every chunk alike.
    std.debug.assert(landing_bands >= 1);
    const overlay = try world.requireTileByName(meta, "stone_floor");
    for (1..landing_bands) |_| _ = try world.addDenseLayer(1, 0, .obstacle, overlay);
    if (landing_bands > 1) {
        const edge = world.chunk_size_tiles;
        for (0..world.chunkGeometry().chunks_y) |chunk_y| for (0..world.chunkGeometry().chunks_x) |chunk_x| {
            for (0..landing_bands) |tile| {
                const x: u16 = @intCast(chunk_x * edge + tile % edge);
                const y: u16 = @intCast(chunk_y * edge + tile / edge % edge);
                std.debug.assert((try world.addSparseTile(1, x, y, overlay, 0, .floor)) == null);
            }
        };
    }
    for (0..faller_count) |faller_index| {
        const x, const y = layout.hole(faller_index);
        _ = try world.clearDenseTile(0, x, y);
    }

    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const player = try Player.spawn(&data);
    var fallers: std.ArrayList(Faller) = .empty;
    errdefer fallers.deinit(allocator);
    try fallers.ensureTotalCapacity(allocator, faller_count);
    const faller_stride = if (faller_count == 0) 1 else agent_count / faller_count;
    const tile_size = world.tile_size;
    for (0..agent_count) |index| {
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{});
        try data.setPrimitiveVisual(entity, .{
            .size = .{ .x = tile_size, .y = tile_size },
            .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
            .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        });
        try data.setAiAgent(entity, .{ .active_behavior = .wander, .gain_pursue = 0 });
        try data.setWorldLevel(entity, 0);
        try data.setSimulationTier(entity, .locomotion);
        const faller_index = index / faller_stride;
        const is_faller = index % faller_stride == 0 and faller_index < faller_count;
        const to: [2]u16 = if (is_faller)
            layout.hole(faller_index)
        else
            .{ @intCast(index % layout.walker_columns + 1), @intCast(index / layout.walker_columns % layout.side) };
        const body = data.movementBodyPtr(entity).?;
        body.previous_x.* = @as(f32, @floatFromInt(to[0] - 1)) * tile_size;
        body.previous_y.* = @as(f32, @floatFromInt(to[1])) * tile_size;
        body.position_x.* = @as(f32, @floatFromInt(to[0])) * tile_size;
        body.position_y.* = @as(f32, @floatFromInt(to[1])) * tile_size;
        if (is_faller) fallers.appendAssumeCapacity(.{ .entity = entity, .hole = to });
    }
    std.debug.assert(fallers.items.len == faller_count);

    // The pipeline's own reservations for this population.
    const plane_budget = maxEventsPerStep(.plane_traversal, .{ .movement_body_capacity = agent_count + 1 });
    var frame = SimulationFrame.init(allocator);
    errdefer frame.deinit();
    try frame.reserveStreams(4, plane_budget, 0, 0, 0, 0);
    var dig = DigController.init(dig_config);
    errdefer dig.deinit();
    try dig.reservePlaneScratch(allocator, plane_budget);
    var plane_entry = PlaneEntrySystem.init(allocator);
    errdefer plane_entry.deinit();
    try plane_entry.reserve(agent_count);
    var colliders = StaticColliderSystem.init(allocator);
    errdefer colliders.deinit();
    const extent = PathfindingSystem.worldNavExtent(&world);
    try colliders.rebuild(&data, try extent.colliderGeometry(), null);
    var nav = PathfindingSystem.init(allocator);
    errdefer nav.deinit();
    try nav.reserve(.{ .worker_participant_count = participant_count });
    try nav.rebuildNavFromColliders(&colliders, extent, null);

    return .{
        .allocator = allocator,
        .world = world,
        .data = data,
        .frame = frame,
        .dig = dig,
        .plane_entry = plane_entry,
        .colliders = colliders,
        .nav = nav,
        .player = player,
        .fallers = fallers,
        .dirt = dirt,
    };
}

fn runNoFallsCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .no_falls, 1);
}

fn runFallsCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .fixed_falls, 1);
}

fn runDenseFallsCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .dense_falls, 1);
}

fn runBandedFallsCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, banded_agent_count, .banded_falls, item_count);
}

// One production plane stage, after `resetStep`. Returns the carves it wrote.
fn runStage(fixture: *Fixture, thread_system: *ThreadSystem) !usize {
    try runPlaneTraversal(&fixture.plane_entry, &fixture.dig, &fixture.nav, &fixture.world, &fixture.data, &fixture.player, &fixture.frame, thread_system);
    return fixture.frame.events.stats.world_tile_changed;
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, workload: Workload, landing_bands: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;

    var fixture = try buildFixture(allocator, io, item_count, workload, landing_bands, threads.participantSlotCount());
    defer fixture.deinit();
    fixtures.setNavTuners(&fixture.nav, case);
    const plane_entry = &fixture.plane_entry;
    plane_entry.tuner = AdaptiveWorkTuner.init(.{});
    plane_entry.config = .{
        .items_per_range = case.stageItemsPerRange(plane_entry_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    };

    // The landing carves run on the world's terrain-edit tuners under the case's controls,
    // fresh after the fixture's build, as the nav stages are.
    const carve_controls: StageControls = .{
        .adaptive = case.adaptive,
        .max_worker_threads = case.maxWorkerThreads(),
        .items_per_range = case.stageItemsPerRangeForPartition(suite.chunk_partition_items, 1),
    };
    fixture.dig.carve_controls = carve_controls;
    fixture.world.terrain_edit_plan_tuner = AdaptiveWorkTuner.init(.{});
    fixture.world.terrain_edit_write_tuner = AdaptiveWorkTuner.init(.{});
    const nav_range = case.stageItemsPerRangeForPartition(suite.chunk_partition_items, 1);
    // The falls workloads are judged on their landings: the carve write is their headline.
    const headline_stage: usize = if (workload == .dense_falls or workload == .banded_falls) carve_write_stage else gather_stage;

    try fixture.resetStep(thread_ptr);
    var warm = suite.Warmup.init(options, case, 1);
    while (warm.next(fixture.tunerSettle().all())) {
        _ = try runStage(&fixture, thread_ptr);
        try fixture.resetStep(thread_ptr);
    }
    const settle = fixture.tunerSettle();
    const headline_tuner = fixture.stageTuners()[headline_stage];
    const tuner_start = suite.TunerStart.of(headline_tuner, case.adaptive and settle.all());
    const tuner_window = suite.TunerWindow(stage_names.len).begin(fixture.stageTuners());

    // The banded group's size axis is its landing band count.
    var accumulator = suite.StatsAccumulator.init(if (workload == .banded_falls) landing_bands else item_count);
    var shapes = suite.StageShapes(stage_names.len){};
    var main_total: u128 = 0;
    var entries: usize = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        entries = try runStage(&fixture, thread_ptr);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        const batches = fixture.stageBatches();
        accumulator.record(elapsed_ns, batches[headline_stage]);
        shapes.add(batches);
        // A fixed threaded case runs each stage of more than one range on workers.
        try suite.checkStageDispatched(case, thread_ptr, plane_entry.config.items_per_range, batches[gather_stage]);
        try suite.checkStagesDispatched(case, thread_ptr, carve_controls.items_per_range, batches[carve_plan_stage .. carve_write_stage + 1]);
        try suite.checkStageDispatched(case, thread_ptr, nav_range, batches[mark_stage]);
        // Main is everything but the stages that ran on workers: the gather, the carve
        // batch's plan and write stages, and the nav mark stage.
        var off_main: u64 = 0;
        for (batches) |batch| off_main += offMainNs(batch);
        main_total += elapsed_ns -| off_main;
        try fixture.resetStep(thread_ptr);
    }
    std.debug.assert(entries == fixture.fallers.items.len);
    var stats = accumulator.finish();
    stats.output_count = entries;
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    shapes.print(&stats.details, "stages", stage_names);
    if (case.adaptive) {
        stats.tuner_settle = settle;
        stats.work_tuning = suite.workTuningSummary(headline_tuner, tuner_start);
        tuner_window.printTuning(&stats.details, stage_names, fixture.stageTuners());
    }
    return stats;
}

// The plane stage's threaded stages, in run order: the cell-entry gather, the landing carve
// batch's plan and write, and the carves' nav mark.
const stage_names = [_][]const u8{ "gather", "carve_plan", "carve_write", "nav_mark" };
const gather_stage = 0;
const carve_plan_stage = 1;
const carve_write_stage = 2;
const mark_stage = 3;

fn writePlaneAgentsWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writePlaneWorkload(writer, stats, view, "agents");
}

fn writePlaneBandsWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writePlaneWorkload(writer, stats, view, "bands");
}

fn writePlaneWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView, unit: []const u8) std.Io.Writer.Error!void {
    try writer.print("{s}={} entries={}", .{ unit, stats.item_count, stats.output_count });
    if (view == .summary) return;
    const main_ns = stats.main_ns orelse 0;
    try writer.writeAll(" headline=");
    try suite.writeStageShape(writer, stats.batch);
    try suite.writeShare(writer, "main", main_ns, stats.mean_ns);
    try writer.print(" main_per_entry={f}", .{suite.formatDuration(if (stats.output_count == 0) 0 else main_ns / stats.output_count)});
}
