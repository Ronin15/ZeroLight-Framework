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
//! Timed: the plane stage's NPC cell-entry gather (`PlaneEntrySystem`, serial or threaded),
//! then the dig reserve and commit over its entries, with the carve batch on the same
//! threads. The untimed reset puts the fallers back on level 0, refills their landing cells,
//! and begins the next frame step. `--details` reports the gather's shape and the stage's
//! main-thread time (all but a dispatched gather or carve batch), its share, and its time per
//! entry.

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const DigConfig = @import("../game/dig_controller.zig").DigConfig;
const DigController = @import("../game/dig_controller.zig").DigController;
const Player = @import("../game/player.zig").Player;
const PlaneEntrySystem = @import("../game/systems/plane_entry.zig").PlaneEntrySystem;
const plane_entry_range_alignment_items = @import("../game/systems/plane_entry.zig").plane_entry_range_alignment_items;
const WorldSystem = @import("../game/world/system.zig").WorldSystem;
const TileId = @import("../game/world/system.zig").TileId;
const level_z_step = @import("../game/world/system.zig").level_z_step;
const default_chunk_size_tiles = @import("../game/world/system.zig").default_chunk_size_tiles;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const maxEventsPerStep = @import("../game/simulation.zig").maxEventsPerStep;
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
    .defaultItemCounts = defaultItemCounts,
    .runCase = runNoFallsCase,
    .write_workload = writePlaneAgentsWorkload,
};

pub const falls_group = suite.BenchmarkGroup{
    .name = "plane-traversal-falls",
    .item_label = "AI agents",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runFallsCase,
    .write_workload = writePlaneAgentsWorkload,
};

pub const dense_falls_group = suite.BenchmarkGroup{
    .name = "plane-traversal-dense-falls",
    .item_label = "AI agents",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runDenseFallsCase,
    .write_workload = writePlaneAgentsWorkload,
};

pub const banded_falls_group = suite.BenchmarkGroup{
    .name = "plane-traversal-dense-falls-banded",
    .item_label = std.fmt.comptimePrint("landing-level bands ({} AI agents)", .{banded_agent_count}),
    .defaultItemCounts = defaultBandCounts,
    .runCase = runBandedFallsCase,
    .write_workload = writePlaneBandsWorkload,
};

fn defaultItemCounts(_: suite.Profile) []const usize {
    return &item_counts;
}

fn defaultBandCounts(_: suite.Profile) []const usize {
    return &band_counts;
}

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
    player: Player,
    fallers: std.ArrayList(Faller) = .empty,
    dirt: TileId,

    fn deinit(self: *Fixture) void {
        self.fallers.deinit(self.allocator);
        self.plane_entry.deinit();
        self.dig.deinit();
        self.frame.deinit();
        self.data.deinit();
        self.world.deinit();
        self.* = undefined;
    }

    // Untimed, before each stage: puts every faller back on level 0 entering its hole,
    // refills its landing cell, and begins the frame step.
    fn resetStep(self: *Fixture) !void {
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
};

// A grass surface over one solid dirt level, with one level-0 hole per faller. Agent
// `index` crosses one cell boundary to the right; the first `faller_count` multiples of
// `agent_count / faller_count` walk into their own hole instead. `landing_bands` is the
// dirt level's band count (its floor first) and its walkable sparse tiles per chunk.
fn buildFixture(allocator: std.mem.Allocator, io: std.Io, agent_count: usize, workload: Workload, landing_bands: usize) !Fixture {
    const faller_count = workload.fallerCount(agent_count);
    std.debug.assert(faller_count <= agent_count);
    const layout = Layout.of(workload.worldSide(faller_count), faller_count);
    var meta = try fixtures.loadTilesetMeta(allocator, io);
    var meta_owned = true;
    defer if (meta_owned) meta.deinit();
    var world = WorldSystem{
        .allocator = allocator,
        .width = layout.side,
        .height = layout.side,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = default_chunk_size_tiles,
    };
    errdefer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const dirt = try world.requireTileByName(&meta, "dirt");
    const dig_config = try DigConfig.fromMeta(&meta);
    for (0..level_count) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        const layer = try world.addDenseLayer(level, 0, .floor, if (level_index == 0) grass else dirt);
        std.debug.assert(layer == level);
    }
    // The landing level's extra walkable bands and sparse tiles, every chunk alike.
    std.debug.assert(landing_bands >= 1);
    const overlay = try world.requireTileByName(&meta, "stone_floor");
    for (1..landing_bands) |_| _ = try world.addDenseLayer(1, 0, .obstacle, overlay);
    if (landing_bands > 1) {
        const edge = world.chunk_size_tiles;
        for (0..world.chunksY()) |chunk_y| for (0..world.chunksX()) |chunk_x| {
            for (0..landing_bands) |tile| {
                const x: u16 = @intCast(chunk_x * edge + tile % edge);
                const y: u16 = @intCast(chunk_y * edge + tile / edge % edge);
                std.debug.assert((try world.addSparseTile(1, x, y, overlay, 0, .floor)) == null);
            }
        };
    }
    world.adoptTilesetMeta(meta);
    meta_owned = false;
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

    return .{
        .allocator = allocator,
        .world = world,
        .data = data,
        .frame = frame,
        .dig = dig,
        .plane_entry = plane_entry,
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

// One plane stage's gather and dig half, after `resetStep`. Returns the gathered entries.
fn runStage(fixture: *Fixture, thread_system: ?*ThreadSystem) !usize {
    const entries = try fixture.plane_entry.gather(&fixture.data, &fixture.world, fixture.player.entity, fixture.dig.tunnel_tile, thread_system);
    const reservation = try fixture.dig.reservePlaneTraversalStage(&fixture.world, &fixture.data, &fixture.player, &fixture.frame, entries, thread_system);
    try fixture.dig.commitPlaneTraversalStage(&fixture.world, &fixture.data, &fixture.player, &fixture.frame, reservation, thread_system);
    std.debug.assert(reservation.carves == entries.len);
    return entries.len;
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, workload: Workload, landing_bands: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();

    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;

    var fixture = try buildFixture(allocator, io, item_count, workload, landing_bands);
    defer fixture.deinit();
    const plane_entry = &fixture.plane_entry;
    plane_entry.tuner = suite.adaptiveTunerForCase(case, plane_entry_range_alignment_items) orelse AdaptiveWorkTuner.init(.{});
    plane_entry.config = .{
        .items_per_range = case.stageItemsPerRange(plane_entry_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    };

    // A fixed threaded case with more than one range of agents dispatches the gather.
    const expect_dispatch = if (thread_ptr) |thread_system|
        !case.adaptive and thread_system.workerThreadCount() > 0 and item_count > plane_entry.config.items_per_range.?
    else
        false;

    try fixture.resetStep();
    for (0..@max(@as(usize, 1), options.warmup_iterations)) |_| {
        _ = try runStage(&fixture, thread_ptr);
        try fixture.resetStep();
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!plane_entry.tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runStage(&fixture, thread_ptr);
            try fixture.resetStep();
        }
    }
    const settled_before_measurement = if (case.adaptive) plane_entry.tuner.isSettled() else false;

    // The banded group's size axis is its landing band count.
    var accumulator = suite.StatsAccumulator.init(if (workload == .banded_falls) landing_bands else item_count);
    var main_total: u128 = 0;
    var entries: usize = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        entries = try runStage(&fixture, thread_ptr);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        const gather = plane_entry.last_batch;
        std.debug.assert(!expect_dispatch or (gather.range_count > 1 and !gather.ran_inline));
        accumulator.record(elapsed_ns, gather);
        // Main is everything but the stages that ran on workers: the gather and the
        // carve batch's plan and write stages.
        var off_main: u64 = 0;
        for ([_]@TypeOf(gather){ gather, fixture.world.last_terrain_edit_plan_batch, fixture.world.last_terrain_edit_write_batch }) |batch| {
            if (!batch.ran_inline) off_main += batch.batch_duration_ns;
        }
        main_total += elapsed_ns -| off_main;
        try fixture.resetStep();
    }
    std.debug.assert(entries == fixture.fallers.items.len);
    var stats = accumulator.finish();
    stats.output_count = entries;
    if (stats.iterations > 0) {
        stats.terrain_edit_phases = .{ .main_ns = @intCast(main_total / stats.iterations) };
    }
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(plane_entry.tuner.report(), settled_before_measurement);
    }
    return stats;
}

fn writePlaneAgentsWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writePlaneWorkload(writer, stats, view, "agents");
}

fn writePlaneBandsWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writePlaneWorkload(writer, stats, view, "bands");
}

fn writePlaneWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView, unit: []const u8) std.Io.Writer.Error!void {
    try writer.print("{s}={} entries={}", .{ unit, stats.item_count, stats.output_count });
    if (view == .summary) return;
    const main_ns = (stats.terrain_edit_phases orelse suite.TerrainEditPhaseSummary{}).main_ns;
    try writer.writeAll(" gather=");
    try suite.writeStageShape(writer, stats.batch);
    try suite.writeShare(writer, "main", main_ns, stats.mean_ns);
    try writer.print(" main_per_entry={f}", .{suite.formatDuration(if (stats.output_count == 0) 0 else main_ns / stats.output_count)});
}
