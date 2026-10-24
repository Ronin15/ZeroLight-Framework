// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! `nav-update-scattered`: incremental nav update over a 3-level 256² world. Each timed
//! sample toggles `item_count` digs on level 1 open, then blocked, each half one buffered nav
//! update (its terrain record untimed), so only the touched chunks and their neighbours patch.
//! The mean is the two halves' average. Digs go one per chunk over the world's 256 chunks,
//! several per chunk past that. Passes when linear in digs up to 256 and in dirty cells past it.
//! Each update's remask batch covers exactly its dirty chunks, and an untimed update with no
//! marks after the measured toggles remasks nothing.
//!
//! The static-obstacle groups time one static collision body moved one step on a 256² world
//! through the production commit seam (`SimulationPipeline.commitStructuralAndReact`, the
//! pipeline built over the bodies and the world): its `set_movement_body` command, the
//! budgeted commit, the population seam, the collider sync and its nav record, the trigger
//! sync, and the nav and steering reactions.
//! The move is the same in every case, so each passes when flat in its item count:
//!   - `nav-update-entity-obstacles`: 10, 1,000, or 10,000 other static bodies in chunks away
//!     from the moved body's 3x3 chunk block.
//!   - `nav-update-static-population`: 1,000, 10,000, or 50,000 dynamic bodies and no other
//!     static body.
//! Each case builds its world, bodies, and nav untimed; the moved body alternates between two
//! cells of one chunk. `outputs` is the chunks patched and `candidates` the bodies present.
//!
//! `nav-update-static-dense`: 64, 1,024, or 16,384 statics changed in one commit through the
//! same seam, half moved one chunk over and half destroyed and recreated there at reused
//! entity indices, among 64 statics per chunk. Passes when linear in the change count, with
//! the chunk rewrite threaded. `nav-update-static-dense-tail`: every insert lands past
//! its run's tail (32 statics per chunk, created after the 64 residents, moved one chunk over
//! and back each step in (chunk, slot) order). Passes when linear in the change count.
//!
//! Every group runs serial and threaded; `--details` prints the main thread's share (the
//! time outside the seam's or update's stages on workers) and the reaction's stage shapes over
//! the measured steps (`[threaded/non-empty]`): `nav-update-scattered` the opening updates' and,
//! under the row, the re-blocking ones' (`block_update:`); the seam groups the seam's collider
//! sync and trigger patch stages too (`seam:`). The static-dense groups' headline batch and
//! tuner are the sync's chunk rewrite. Every measured update runs each nav stage of more than
//! one range on workers in a fixed threaded case (`suite.checkNavReactionDispatched`), as does
//! every collider sync stage of the static-dense groups. The tuned case settles every tuner
//! the measured step runs (`step_tuners:`): both toggle halves' nav stage sets, or every seam
//! stage set (`fixtures.addSeamTuners`).

const std = @import("std");
const math = @import("../core/math.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const EntityTemplate = @import("../game/data_system.zig").EntityTemplate;
const StructuralCommand = @import("../game/data_system.zig").StructuralCommand;
const CollisionResponseMobility = @import("../game/data_system.zig").CollisionResponseMobility;
const WorldSystem = @import("../game/world/system.zig").WorldSystem;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const SimulationEvent = @import("../game/simulation.zig").SimulationEvent;
const TileEdit = @import("../game/systems/pathfinding/test_support.zig").TileEdit;
const PathfindingSystem = @import("../game/systems/pathfinding.zig").PathfindingSystem;
const NavUpdateStats = @import("../game/systems/pathfinding.zig").NavUpdateStats;
const structuralEventHeadroom = @import("../game/simulation.zig").structuralEventHeadroom;
const StaticColliderSystem = @import("../game/systems/static_colliders.zig").StaticColliderSystem;
const SyncStage = @import("../game/systems/static_colliders.zig").SyncStage;
const splice_range_alignment_items = @import("../game/systems/chunk_list_map.zig").splice_range_alignment_items;
const TileId = @import("../game/world/system.zig").TileId;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

// World side length in nav cells/tiles: holds the largest footprint at the world midpoint
// with a few chunks of margin.
const world_tiles: u16 = 256;
const tile_size: f32 = 32.0;

// Abstract chunk side in tiles. Nav takes the world's chunk, and the world builds at the
// default, so the scattered footprint stays one dirty cell per distinct chunk (its item_count
// equals the dirty-chunk count) even if the default changes.
const nav_chunk_tiles: u16 = @import("../game/world/system.zig").default_chunk_size_tiles;
const static_colliders_test_support = @import("../game/systems/static_colliders_test_support.zig");
const chunks_per_side: usize = @as(usize, world_tiles) / nav_chunk_tiles;
const total_chunks: usize = chunks_per_side * chunks_per_side;

// Scattered dig counts over the world's 256 chunks: one dig per distinct chunk up to 256,
// then several per chunk (up to `max_digs_per_chunk`).
const scattered_counts = [_]usize{ 16, 32, 64, 128, 256, 1000 };
const max_digs_per_chunk: usize = 16;

pub const group = suite.BenchmarkGroup{
    .name = "nav-update-scattered",
    .item_label = "digs in one step",
    .item_counts = &scattered_counts,
    .runCase = runCase,
    .write_workload = writeNavStagesWorkload,
};

// A dig footprint's main-thread share (per edited cell) and nav stages, under `--details`.
fn writeNavStagesWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    if (view == .summary) return;
    try suite.writeNavStages(writer, stats);
    try suite.writeMainShare(writer, stats, stats.item_count);
}

// The world, nav, and footprint one dig case toggles, built per case.
const Fixture = struct {
    allocator: std.mem.Allocator,
    data: DataSystem,
    world: WorldSystem,
    // No statics: the digs' remask composes world bits only.
    colliders: StaticColliderSystem,
    system: PathfindingSystem,
    obstacle_layer: usize,
    grass: TileId,
    tree: TileId,
    // Tiles toggled each timed iteration: the count's footprint on level 1, and the tile
    // writes' events the terrain record takes, as a writer's.
    edits: std.ArrayList(TileEdit) = .empty,
    events: std.ArrayList(SimulationEvent) = .empty,
    // Chunks each update must remask.
    expected_dirty_chunks: usize = 0,
    // The stats of the most recent timed update, and of the most recent opening and
    // re-blocking halves.
    last_stats: NavUpdateStats = .{},
    open_stats: NavUpdateStats = .{},
    block_stats: NavUpdateStats = .{},
    // The re-blocking half's stage tuners (`fixtures.NavTuners`), set with the opening set.
    revert_tuners: fixtures.NavTuners = .{},

    fn deinit(self: *Fixture) void {
        self.events.deinit(self.allocator);
        self.edits.deinit(self.allocator);
        self.system.deinit();
        self.colliders.deinit();
        self.world.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

// Builds the world and nav (all cells open), sized for `participant_count`.
fn buildFixture(allocator: std.mem.Allocator, io: std.Io, participant_count: usize) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    // Three walkable levels; the dig happens on level 1's obstacle band.
    var tileset = try fixtures.loadTilesetMeta(allocator, io);
    defer tileset.deinit();
    var world = try fixtures.buildBandedWorld(allocator, &tileset, world_tiles, 3, "grass", "grass");
    errdefer world.deinit();
    const grass = try world.requireTileByName(&tileset, "grass");
    const tree = try world.requireTileByName(&tileset, "tree_0");
    const obstacle_layer = try world.addDenseLayer(1, 0, .obstacle, grass);

    var colliders = StaticColliderSystem.init(allocator);
    errdefer colliders.deinit();
    const extent = PathfindingSystem.worldNavExtent(&world);
    try colliders.rebuild(&data, try extent.colliderGeometry(), null);
    var system = PathfindingSystem.init(allocator);
    errdefer system.deinit();
    try system.reserve(.{ .worker_participant_count = participant_count });
    try system.rebuildNavFromColliders(&colliders, extent, null);

    return .{
        .allocator = allocator,
        .data = data,
        .world = world,
        .colliders = colliders,
        .system = system,
        .obstacle_layer = obstacle_layer,
        .grass = grass,
        .tree = tree,
    };
}

// The count's digs on level 1, over distinct chunks, row-major: the k-th round of 256 digs
// places one more dig in every chunk (chunk centers first, then cells stepping (3, 5) from
// them), so up to 256 digs dirty that many chunks and more digs dirty all 256, several per
// chunk. Capped at `max_digs_per_chunk` per chunk. Cost is per chunk (the remask is
// whole-chunk). The world is not written here: the toggle sets the open and blocked state.
fn setFootprint(fixture: *Fixture, allocator: std.mem.Allocator, cells: usize) !void {
    fixture.edits.clearRetainingCapacity();
    const n = @min(cells, total_chunks * max_digs_per_chunk);
    fixture.expected_dirty_chunks = @min(n, total_chunks);
    var placed = try std.DynamicBitSetUnmanaged.initEmpty(allocator, @as(usize, world_tiles) * world_tiles);
    defer placed.deinit(allocator);
    for (0..n) |dig| {
        const chunk = dig % total_chunks;
        const round = dig / total_chunks;
        const cx = chunk % chunks_per_side;
        const cy = chunk / chunks_per_side;
        // 3 and 5 are odd, so rounds below the chunk edge hit distinct cells.
        const local_x = (nav_chunk_tiles / 2 + 3 * round) % nav_chunk_tiles;
        const local_y = (nav_chunk_tiles / 2 + 5 * round) % nav_chunk_tiles;
        // In range: inside the `world_tiles`² level.
        const x: u16 = @intCast(cx * nav_chunk_tiles + local_x);
        const y: u16 = @intCast(cy * nav_chunk_tiles + local_y);
        // Every dig is a distinct cell, so the step makes `n` real changes.
        const cell = @as(usize, y) * world_tiles + x;
        if (placed.isSet(cell)) return error.ScatteredCellRepeated;
        placed.set(cell);
        try fixture.edits.append(allocator, .{ .level = 1, .x = x, .y = y });
    }
}

// One open-then-blocked toggle of the footprint: the first half opens it (grass), the second
// re-blocks it (tree) on the revert stage tuners (swapped untimed), each one nav update; only
// the updates are timed. Returns both halves' sum.
fn runToggle(fixture: *Fixture, io: std.Io, thread_system: *ThreadSystem) !u64 {
    var elapsed: u64 = 0;
    try writeFootprint(fixture, fixture.grass);
    elapsed += try timeNavUpdate(fixture, io, thread_system);
    fixture.open_stats = fixture.last_stats;
    fixtures.swapNavTuners(&fixture.system, &fixture.revert_tuners);
    defer fixtures.swapNavTuners(&fixture.system, &fixture.revert_tuners);
    try writeFootprint(fixture, fixture.tree);
    elapsed += try timeNavUpdate(fixture, io, thread_system);
    fixture.block_stats = fixture.last_stats;
    return elapsed;
}

// Writes `tile` over the footprint, keeping each write's event for the terrain record.
fn writeFootprint(fixture: *Fixture, tile: TileId) !void {
    fixture.events.clearRetainingCapacity();
    try fixture.events.ensureTotalCapacity(fixture.allocator, fixture.edits.items.len);
    for (fixture.edits.items) |edit| {
        const changed = try fixture.world.setDenseTile(fixture.obstacle_layer, edit.x, edit.y, tile) orelse continue;
        fixture.events.appendAssumeCapacity(.{ .stage = .structural_commit, .payload = .{ .world_tile_changed = changed } });
    }
}

// Times one incremental nav update over the fixture's footprint. The terrain record of the
// footprint's writes (serial, so it trains no tuner) is untimed setup, as production records
// edits before the patch. Fails unless the update applied and remasked the footprint's chunks,
// its remask batch over exactly those chunks.
fn timeNavUpdate(fixture: *Fixture, io: std.Io, thread_system: *ThreadSystem) !u64 {
    try fixture.system.reserveTerrainNavRecord(fixture.events.items.len);
    fixture.system.recordTerrainNavEvents(fixture.events.items, &fixture.world, null);
    const t0 = suite.nowNs(io);
    const stats = try fixture.system.applyBufferedNavUpdates(&fixture.colliders, &fixture.world, thread_system);
    const elapsed = suite.elapsedNs(t0, suite.nowNs(io));
    if (stats.incremental_rebuilds != 1) return error.NavUpdateNotApplied;
    if (stats.dirty_chunks != fixture.expected_dirty_chunks) return error.NavUpdateNotApplied;
    if (stats.perf.remask_batch.item_count != stats.dirty_chunks) return error.NavUpdateRemaskMissedChunks;
    fixture.last_stats = stats;
    return elapsed;
}

// Both toggle halves' stage tuner sets, every tuner of each.
fn toggleTunerSettle(fixture: *const Fixture) suite.TunerSettle {
    var census = fixtures.navTunerSettle("", &fixture.system.tuners);
    fixtures.addNavTuners(&census, "revert.", &fixture.revert_tuners);
    return census;
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;

    var fixture = try buildFixture(allocator, io, fixtures.participantCount(thread_ptr));
    defer fixture.deinit();
    try setFootprint(&fixture, allocator, item_count);
    // Untimed: block the whole footprint, so every toggle half writes a real flip per cell
    // (a write that changes nothing emits no event and no mark).
    try writeFootprint(&fixture, fixture.tree);
    try fixture.system.reserveTerrainNavRecord(fixture.events.items.len);
    fixture.system.recordTerrainNavEvents(fixture.events.items, &fixture.world, null);
    _ = try fixture.system.applyBufferedNavUpdates(&fixture.colliders, &fixture.world, thread_ptr);
    fixtures.setNavTuners(&fixture.system, case);
    fixture.revert_tuners = fixture.system.tuners;

    // Warm so the abstract buffers are at high-water capacity (the steady path is
    // allocation-free) and the tuners have trained an inline baseline before timing.
    var warm = suite.Warmup.init(options, case, 1);
    while (warm.nextSettled(toggleTunerSettle(&fixture))) _ = try runToggle(&fixture, io, thread_ptr);
    const settle = toggleTunerSettle(&fixture);
    const remask_tuner_start = suite.TunerStart.of(fixture.system.tuners.nav.getPtrConst(.remask), case);
    const patch_tuner_start = suite.TunerStart.of(fixture.system.tuners.nav.getPtrConst(.patch), case);

    // Throughput is over the cells edited: the footprint is capped, so a count above the cap
    // edits fewer cells.
    const edited_cells = fixture.edits.items.len;
    var accumulator = suite.StatsAccumulator.init(edited_cells);
    var open_reactions = suite.NavReactionShapes{};
    var block_reactions = suite.NavReactionShapes{};
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        const elapsed = try runToggle(&fixture, io, thread_ptr);
        // The opening update's remask: the reported tuners' set (the revert half runs on
        // the revert set).
        accumulator.record(elapsed / 2, fixture.open_stats.perf.remask_batch);
        try suite.checkNavReactionDispatched(case, thread_ptr, .{}, fixture.open_stats);
        try suite.checkNavReactionDispatched(case, thread_ptr, .{}, fixture.block_stats);
        // Main is the halves' time outside their stages on workers, per half as the mean is.
        main_total += (elapsed -| (fixture.open_stats.perf.off_main_stage_ns + fixture.block_stats.perf.off_main_stage_ns)) / 2;
        open_reactions.add(.{}, fixture.open_stats);
        block_reactions.add(.{}, fixture.block_stats);
    }
    // Untimed: an update with no marks applies and remasks nothing, so it reports no stale
    // remask from the toggles.
    const idle = try fixture.system.applyBufferedNavUpdates(&fixture.colliders, &fixture.world, thread_ptr);
    if (idle.incremental_rebuilds != 0 or idle.perf.remask_batch.item_count != 0) return error.NavIdleUpdateRemasked;
    var stats = accumulator.finish();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    // The opening updates' stages (the reported tuners' set) in the workload column; the
    // re-blocking updates' under the row.
    open_reactions.summarize(&stats, fixtures.floodTunerWorkers(&fixture.system, case));
    block_reactions.print(&stats.details, "block_update");
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        stats.work_tuning = suite.workTuningSummary(fixture.system.tuners.nav.getPtrConst(.remask), remask_tuner_start);
        stats.secondary_work_tuning = suite.workTuningSummary(fixture.system.tuners.nav.getPtrConst(.patch), patch_tuner_start);
    }
    return stats;
}

// ----------------------------------------------------------------------------
// Static-obstacle moves: one static body moved, committed, and reacted to.
// ----------------------------------------------------------------------------

const other_static_counts = [_]usize{ 10, 1_000, 10_000 };
const dynamic_body_counts = [_]usize{ 1_000, 10_000, 50_000 };

pub const entity_obstacle_group = suite.BenchmarkGroup{
    .name = "nav-update-entity-obstacles",
    .item_label = "other static bodies",
    .item_counts = &other_static_counts,
    .runCase = runEntityObstacleCase,
    .write_workload = writeStaticMoveWorkload,
};

pub const static_population_group = suite.BenchmarkGroup{
    .name = "nav-update-static-population",
    .item_label = "dynamic bodies",
    .item_counts = &dynamic_body_counts,
    .runCase = runStaticPopulationCase,
    .write_workload = writeStaticMoveWorkload,
};

fn runEntityObstacleCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runStaticMoveCase(allocator, io, options, case, item_count, 0);
}

fn runStaticPopulationCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runStaticMoveCase(allocator, io, options, case, 0, item_count);
}

// Bodies cover one nav cell: a quarter-tile square inset from the cell's top-left corner.
const body_size: f32 = 8.0;
const body_inset: f32 = 4.0;
// The moved body's chunk; no other static body lies in it or its 8 neighbors.
const moved_chunk: usize = 8;
const moved_cell_a: usize = moved_chunk * nav_chunk_tiles + 4;
const moved_cell_b: usize = moved_cell_a + 3;

fn cellCorner(x: usize, y: usize) math.Vec2 {
    return .{
        .x = @as(f32, @floatFromInt(x)) * tile_size + body_inset,
        .y = @as(f32, @floatFromInt(y)) * tile_size + body_inset,
    };
}

fn nearMovedChunk(chunk_x: usize, chunk_y: usize) bool {
    return chunk_x + 1 >= moved_chunk and chunk_x <= moved_chunk + 1 and chunk_y + 1 >= moved_chunk and chunk_y <= moved_chunk + 1;
}

// A collision body over one nav cell.
fn createBody(data: *DataSystem, position: math.Vec2, mobility: CollisionResponseMobility) !EntityId {
    return fixtures.addBody(data, position, .{ .x = body_size, .y = body_size }, mobility);
}

// `count` static bodies, one per cell, filling the chunks outside the moved body's 3x3
// chunk block round-robin, so every such chunk holds about the same number.
fn addOtherStatics(allocator: std.mem.Allocator, data: *DataSystem, count: usize) !void {
    var chunks: std.ArrayList(usize) = .empty;
    defer chunks.deinit(allocator);
    for (0..total_chunks) |chunk| {
        if (!nearMovedChunk(chunk % chunks_per_side, chunk / chunks_per_side)) try chunks.append(allocator, chunk);
    }
    std.debug.assert(count <= chunks.items.len * nav_chunk_tiles * nav_chunk_tiles);
    for (0..count) |index| {
        const chunk = chunks.items[index % chunks.items.len];
        const local = index / chunks.items.len;
        const x = (chunk % chunks_per_side) * nav_chunk_tiles + local % nav_chunk_tiles;
        const y = (chunk / chunks_per_side) * nav_chunk_tiles + local / nav_chunk_tiles;
        _ = try createBody(data, cellCorner(x, y), .static);
    }
}

// `count` dynamic bodies, one per cell in row-major order over the level.
fn addDynamicBodies(data: *DataSystem, count: usize) !void {
    std.debug.assert(count <= @as(usize, world_tiles) * world_tiles);
    for (0..count) |index| {
        _ = try createBody(data, cellCorner(index % world_tiles, index / world_tiles), .dynamic);
    }
}

const StaticMoveFixture = struct {
    data: DataSystem,
    world: WorldSystem,
    // The production commit seam; its pipeline owns the colliders and nav.
    seam: fixtures.PipelineSeam,
    // Between two cells of one chunk.
    moved: fixtures.StaticMove,
    // Collision bodies present, the moved one included.
    body_count: usize,

    fn deinit(self: *StaticMoveFixture) void {
        self.seam.deinit();
        self.world.deinit();
        self.data.deinit();
        self.* = undefined;
    }

    fn nav(self: *StaticMoveFixture) *PathfindingSystem {
        return &self.seam.pipeline.pathfinding;
    }

    // One move to the other cell through the production commit seam
    // (`SimulationPipeline.commitStructuralAndReact`). Returns the time from the command
    // write through the seam.
    fn moveAndReact(self: *StaticMoveFixture, io: std.Io, thread_system: *ThreadSystem) !struct { ns: u64, stats: NavUpdateStats } {
        self.seam.frame.beginStep();
        const start_ns = suite.nowNs(io);
        const stats = (try self.seam.commit(&self.data, &self.world, &.{self.moved.command()}, thread_system)).nav_update;
        const ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        if (stats.incremental_rebuilds != 1) return error.StaticMoveNotApplied;
        self.moved.advance();
        return .{ .ns = ns, .stats = stats };
    }
};

fn initStaticMoveFixture(allocator: std.mem.Allocator, io: std.Io, other_statics: usize, dynamic_bodies: usize, threads: *ThreadSystem) !StaticMoveFixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const moved = fixtures.StaticMove{
        .entity = try createBody(&data, cellCorner(moved_cell_a, moved_cell_a), .static),
        .positions = .{ cellCorner(moved_cell_a, moved_cell_a), cellCorner(moved_cell_b, moved_cell_a) },
    };
    try addOtherStatics(allocator, &data, other_statics);
    try addDynamicBodies(&data, dynamic_bodies);

    var tileset = try fixtures.loadTilesetMeta(allocator, io);
    defer tileset.deinit();
    var world = try fixtures.buildBandedWorld(allocator, &tileset, world_tiles, 1, "grass", "grass");
    errdefer world.deinit();
    const seam = try fixtures.PipelineSeam.init(allocator, &data, &world, .{
        .structural_headroom = fixtures.StaticMove.structural_headroom,
        .pathfinding = .{ .worker_participant_count = threads.participantSlotCount() },
        .build_thread_system = threads,
    });
    return .{
        .data = data,
        .world = world,
        .seam = seam,
        .moved = moved,
        .body_count = 1 + other_statics + dynamic_bodies,
    };
}

fn runStaticMoveCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, other_statics: usize, dynamic_bodies: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;

    var fixture = try initStaticMoveFixture(allocator, io, other_statics, dynamic_bodies, thread_ptr);
    defer fixture.deinit();
    fixture.seam.setCaseTuners(case);
    const nav = fixture.nav();

    var warm = suite.Warmup.init(options, case, 1);
    while (warm.nextSettled(fixtures.seamTunerSettle(&fixture.seam.pipeline))) _ = try fixture.moveAndReact(io, thread_ptr);
    const settle = fixtures.seamTunerSettle(&fixture.seam.pipeline);
    const remask_tuner_start = suite.TunerStart.of(nav.tuners.nav.getPtrConst(.remask), case);
    const patch_tuner_start = suite.TunerStart.of(nav.tuners.nav.getPtrConst(.patch), case);

    var accumulator = suite.StatsAccumulator.init(other_statics + dynamic_bodies);
    var chunks_patched: usize = 0;
    var reactions = suite.NavReactionShapes{};
    var seam_shapes = suite.StageShapes(fixtures.seam_stage_names.len){};
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        const result = try fixture.moveAndReact(io, thread_ptr);
        chunks_patched = result.stats.chunks_patched;
        accumulator.record(result.ns, result.stats.perf.remask_batch);
        try suite.checkNavReactionDispatched(case, thread_ptr, nav.perf.last_mark_batch, result.stats);
        reactions.add(nav.perf.last_mark_batch, result.stats);
        seam_shapes.add(fixtures.seamBatches(&fixture.seam.pipeline));
        main_total += result.ns -| fixtures.seamOffMainNs(&fixture.seam.pipeline, result.stats);
    }
    var stats = accumulator.finish();
    stats.output_count = chunks_patched;
    stats.candidate_pairs = fixture.body_count;
    // One move per iteration.
    stats.items_per_second = suite.itemsPerSecond(1, stats.mean_ns);
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    reactions.summarize(&stats, fixtures.floodTunerWorkers(nav, case));
    seam_shapes.print(&stats.details, "seam", fixtures.seam_stage_names);
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        stats.work_tuning = suite.workTuningSummary(nav.tuners.nav.getPtrConst(.remask), remask_tuner_start);
        stats.secondary_work_tuning = suite.workTuningSummary(nav.tuners.nav.getPtrConst(.patch), patch_tuner_start);
    }
    return stats;
}

// ----------------------------------------------------------------------------
// Dense static changes: many statics changed in one commit, synced and reacted to.
// ----------------------------------------------------------------------------

// Statics changed in one commit. Each case's fixture holds `dense_statics_per_chunk` statics
// in each of items/32 chunks, so every touched list is about that long at every count.
const dense_change_counts = [_]usize{ 64, 1024, 16384 };
const dense_statics_per_chunk: usize = 64;
// Every second static of a chunk changes: half of those move one chunk over, half are
// destroyed and recreated one chunk over (the create reuses a freed entity index).
const dense_changes_per_chunk: usize = dense_statics_per_chunk / 2;

pub const static_dense_group = suite.BenchmarkGroup{
    .name = "nav-update-static-dense",
    .item_label = "statics changed in one commit",
    .item_counts = &dense_change_counts,
    .runCase = runStaticDenseCase,
    .write_workload = writeStaticDenseWorkload,
};

pub const static_dense_tail_group = suite.BenchmarkGroup{
    .name = "nav-update-static-dense-tail",
    .item_label = "statics changed in one commit",
    .item_counts = &dense_change_counts,
    .runCase = runStaticDenseTailCase,
    .write_workload = writeStaticDenseWorkload,
};

const StaticDenseFixture = struct {
    allocator: std.mem.Allocator,
    data: DataSystem,
    world: WorldSystem,
    // The production commit seam; its pipeline owns the colliders and nav.
    seam: fixtures.PipelineSeam,
    commands: std.ArrayList(StructuralCommand) = .empty,
    // Moved statics by (chunk, slot) order, and the current ids of the recreated ones.
    moved: std.ArrayList(EntityId) = .empty,
    recreated: std.ArrayList(EntityId) = .empty,
    layout: DenseLayout,
    // Whether the changed statics are the tail statics: created after every resident, on
    // their own cells, and only moved.
    tail: bool,
    // Whether the changed statics sit one chunk over from their home chunk.
    shifted: bool = false,

    fn deinit(self: *StaticDenseFixture) void {
        self.recreated.deinit(self.allocator);
        self.moved.deinit(self.allocator);
        self.commands.deinit(self.allocator);
        self.seam.deinit();
        self.world.deinit();
        self.data.deinit();
        self.* = undefined;
    }

    // Where changed static (home `chunk`, `slot`) sits after this step's change.
    fn targetCorner(self: *const StaticDenseFixture, chunk: usize, slot: usize) math.Vec2 {
        const target_chunk = if (self.shifted) chunk else (chunk + 1) % self.layout.chunk_count;
        return if (self.tail) self.layout.tailSlotCorner(target_chunk, slot) else self.layout.slotCorner(target_chunk, slot);
    }

    // The tail variant's commands: every tail static moves, in (chunk, slot) order.
    fn appendTailMoves(self: *StaticDenseFixture) !void {
        for (0..self.layout.chunk_count) |chunk| for (0..dense_changes_per_chunk) |slot| {
            const corner = self.targetCorner(chunk, slot);
            try self.commands.append(self.allocator, .{ .set_movement_body = .{
                .entity = self.moved.items[chunk * dense_changes_per_chunk + slot],
                .body = .{ .position = corner, .previous_position = corner },
            } });
        };
    }

    fn nav(self: *StaticDenseFixture) *PathfindingSystem {
        return &self.seam.pipeline.pathfinding;
    }

    fn colliders(self: *StaticDenseFixture) *StaticColliderSystem {
        return &self.seam.pipeline.static_colliders;
    }

    // One dense change through the production commit seam
    // (`SimulationPipeline.commitStructuralAndReact`): every move and every destroy + create
    // as one commit. Returns the time from the command build through the seam, its collider
    // sync and nav reaction phases (`SimulationPipeline.Perf`) and the rest, and the splice and
    // reaction off-main stage time.
    fn changeAndReact(self: *StaticDenseFixture, io: std.Io, thread_system: *ThreadSystem) !DenseChangeTiming {
        self.seam.frame.beginStep();
        const start_ns = suite.nowNs(io);
        self.commands.clearRetainingCapacity();
        // Changed slots: every slot ≡ 0 (mod 4) moves, every slot ≡ 2 (mod 4) is recreated.
        var moved_at: usize = 0;
        var recreated_at: usize = 0;
        if (self.tail) try self.appendTailMoves() else for (0..self.layout.chunk_count) |chunk| {
            var slot: usize = 0;
            while (slot < dense_statics_per_chunk) : (slot += 2) {
                const corner = self.targetCorner(chunk, slot);
                if (slot % 4 == 0) {
                    try self.commands.append(self.allocator, .{ .set_movement_body = .{
                        .entity = self.moved.items[moved_at],
                        .body = .{ .position = corner, .previous_position = corner },
                    } });
                    moved_at += 1;
                } else {
                    try self.commands.append(self.allocator, .{ .destroy_entity = self.recreated.items[recreated_at] });
                    recreated_at += 1;
                }
            }
        }
        if (!self.tail) for (0..self.layout.chunk_count) |chunk| {
            var slot: usize = 2;
            while (slot < dense_statics_per_chunk) : (slot += 4) {
                try self.commands.append(self.allocator, .{ .create_entity = denseStaticTemplate(self.targetCorner(chunk, slot)) });
            }
        };
        const stats = (try self.seam.commit(&self.data, &self.world, self.commands.items, thread_system)).nav_update;
        const end_ns = suite.nowNs(io);
        const perf = self.seam.pipeline.perf;
        if (stats.incremental_rebuilds != 1) return error.StaticChangeNotApplied;
        if (self.colliders().changesThisStep().len != self.layout.chunk_count * dense_changes_per_chunk) return error.StaticChangesMissing;
        // The recreated statics' new ids, in create order.
        recreated_at = 0;
        for (self.seam.frame.structural_changes_scratch.items) |change| switch (change) {
            .entity_created => |entity| {
                self.recreated.items[recreated_at] = entity;
                recreated_at += 1;
            },
            else => {},
        };
        if (recreated_at != self.recreated.items.len) return error.StaticRecreatesMissing;
        self.shifted = !self.shifted;
        const ns = suite.elapsedNs(start_ns, end_ns);
        return .{
            .ns = ns,
            .commit_ns = ns -| (perf.seam_collider_sync_ns + perf.seam_nav_reaction_ns),
            .sync_ns = perf.seam_collider_sync_ns,
            .nav_ns = perf.seam_nav_reaction_ns,
            .off_main_ns = fixtures.seamOffMainNs(&self.seam.pipeline, stats),
            .stats = stats,
        };
    }
};

const DenseChangeTiming = struct {
    ns: u64,
    // The rest of the seam: command write, reserves, commit, capture, population seam, nav
    // record, trigger sync and bound check, and steering reaction.
    commit_ns: u64,
    // Collider sync (`StaticColliderSystem.sync`, the splice stage included).
    sync_ns: u64,
    // The post-commit nav reaction.
    nav_ns: u64,
    off_main_ns: u64,
    stats: NavUpdateStats,
};

fn denseStaticTemplate(position: math.Vec2) EntityTemplate {
    return .{
        .movement_body = .{ .position = position, .previous_position = position },
        .collision_bounds = .{ .size = .{ .x = body_size, .y = body_size } },
        .collision_response = .{ .mobility = .static },
    };
}

// The dense fixture's chunks: `chunk_count` chunks row-major, `chunks_x` per row.
const DenseLayout = struct {
    chunk_count: usize,
    chunks_x: usize,

    fn init(change_count: usize) DenseLayout {
        const chunk_count = @max(2, change_count / dense_changes_per_chunk);
        var chunks_x: usize = 1;
        while (chunks_x * chunks_x < chunk_count) chunks_x += 1;
        return .{ .chunk_count = chunk_count, .chunks_x = chunks_x };
    }

    // The cell of `slot` in `chunk`: 64 slots on every second cell of the chunk's 16 x 16.
    fn slotCorner(self: DenseLayout, chunk: usize, slot: usize) math.Vec2 {
        const x = (chunk % self.chunks_x) * nav_chunk_tiles + (slot % 8) * 2;
        const y = (chunk / self.chunks_x) * nav_chunk_tiles + (slot / 8) * 2;
        return cellCorner(x, y);
    }

    // The cell of tail `slot` in `chunk`: the cell east of resident `slot`, so no tail static
    // shares a cell with a resident.
    fn tailSlotCorner(self: DenseLayout, chunk: usize, slot: usize) math.Vec2 {
        const x = (chunk % self.chunks_x) * nav_chunk_tiles + (slot % 8) * 2 + 1;
        const y = (chunk / self.chunks_x) * nav_chunk_tiles + (slot / 8) * 2;
        return cellCorner(x, y);
    }
};

fn initStaticDenseFixture(allocator: std.mem.Allocator, io: std.Io, change_count: usize, threads: *ThreadSystem, tail: bool) !StaticDenseFixture {
    const layout = DenseLayout.init(change_count);

    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    // Entity index i sits in chunk i mod C, so every chunk's list interleaves indices from
    // the whole range and each insert lands mid-list.
    const slot_entities = try allocator.alloc(EntityId, layout.chunk_count * dense_statics_per_chunk);
    defer allocator.free(slot_entities);
    for (0..dense_statics_per_chunk) |slot| for (0..layout.chunk_count) |chunk| {
        slot_entities[chunk * dense_statics_per_chunk + slot] = try createBody(&data, layout.slotCorner(chunk, slot), .static);
    };
    var moved: std.ArrayList(EntityId) = .empty;
    errdefer moved.deinit(allocator);
    var recreated: std.ArrayList(EntityId) = .empty;
    errdefer recreated.deinit(allocator);
    if (tail) {
        // Created after every resident, in (chunk, slot) order: each is past every list's tail.
        for (0..layout.chunk_count) |chunk| for (0..dense_changes_per_chunk) |slot| {
            try moved.append(allocator, try createBody(&data, layout.tailSlotCorner(chunk, slot), .static));
        };
    } else for (0..layout.chunk_count) |chunk| {
        var slot: usize = 0;
        while (slot < dense_statics_per_chunk) : (slot += 2) {
            const entity = slot_entities[chunk * dense_statics_per_chunk + slot];
            if (slot % 4 == 0) try moved.append(allocator, entity) else try recreated.append(allocator, entity);
        }
    }

    // Layout widths are a few chunks: within a level side.
    var tileset = try fixtures.loadTilesetMeta(allocator, io);
    defer tileset.deinit();
    var world = try fixtures.buildBandedWorld(allocator, &tileset, @intCast(layout.chunks_x * nav_chunk_tiles), 1, "grass", "grass");
    errdefer world.deinit();
    const seam = try fixtures.PipelineSeam.init(allocator, &data, &world, .{
        // Per chunk: the moves and destroys, and a create per destroy unless the tail only moves.
        .structural_headroom = structuralEventHeadroom(if (tail) 0 else layout.chunk_count * dense_changes_per_chunk / 2, layout.chunk_count * dense_changes_per_chunk),
        .pathfinding = .{ .worker_participant_count = threads.participantSlotCount() },
        .build_thread_system = threads,
    });
    return .{
        .allocator = allocator,
        .data = data,
        .world = world,
        .seam = seam,
        .moved = moved,
        .recreated = recreated,
        .layout = layout,
        .tail = tail,
    };
}

fn runStaticDenseCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runDenseCase(allocator, io, options, case, item_count, false);
}

fn runStaticDenseTailCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runDenseCase(allocator, io, options, case, item_count, true);
}

fn runDenseCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, tail: bool) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;

    var fixture = try initStaticDenseFixture(allocator, io, item_count, thread_ptr, tail);
    defer fixture.deinit();
    fixture.seam.setCaseTuners(case);
    const nav = fixture.nav();

    var warm = suite.Warmup.init(options, case, 1);
    while (warm.nextSettled(fixtures.seamTunerSettle(&fixture.seam.pipeline))) _ = try fixture.changeAndReact(io, thread_ptr);
    const settle = fixtures.seamTunerSettle(&fixture.seam.pipeline);
    const rewrite_tuner = fixture.colliders().tuners.getPtrConst(.rewrite);
    const rewrite_tuner_start = suite.TunerStart.of(rewrite_tuner, case);
    const remask_tuner_start = suite.TunerStart.of(nav.tuners.nav.getPtrConst(.remask), case);

    const change_count = fixture.layout.chunk_count * dense_changes_per_chunk;
    var accumulator = suite.StatsAccumulator.init(change_count);
    var commit_total: u128 = 0;
    var sync_total: u128 = 0;
    var nav_total: u128 = 0;
    var main_total: u128 = 0;
    var chunks_patched: usize = 0;
    var reactions = suite.NavReactionShapes{};
    var seam_shapes = suite.StageShapes(fixtures.seam_stage_names.len){};
    for (0..options.iterations) |_| {
        const result = try fixture.changeAndReact(io, thread_ptr);
        chunks_patched = result.stats.chunks_patched;
        commit_total += result.commit_ns;
        sync_total += result.sync_ns;
        nav_total += result.nav_ns;
        main_total += result.ns -| result.off_main_ns;
        const seam_batches = fixtures.seamBatches(&fixture.seam.pipeline);
        // The headline is the collider sync's chunk rewrite, the stage the pass shape names.
        accumulator.record(result.ns, seam_batches[@backingInt(SyncStage.rewrite)]);
        try suite.checkNavReactionDispatched(case, thread_ptr, nav.perf.last_mark_batch, result.stats);
        try suite.checkStagesDispatched(case, thread_ptr, case.stageItemsPerRange(splice_range_alignment_items), seam_batches[0..fixtures.seam_sync_stage_count]);
        reactions.add(nav.perf.last_mark_batch, result.stats);
        seam_shapes.add(seam_batches);
    }
    var stats = accumulator.finish();
    stats.output_count = chunks_patched;
    stats.candidate_pairs = static_colliders_test_support.liveRowCount(fixture.colliders().*);
    stats.items_per_second = suite.itemsPerSecond(change_count, stats.mean_ns);
    reactions.summarize(&stats, fixtures.floodTunerWorkers(nav, case));
    seam_shapes.print(&stats.details, "seam", fixtures.seam_stage_names);
    if (stats.iterations > 0) {
        const iterations: u128 = stats.iterations;
        // Plan: the commit; write: the collider sync and record; nav: the reaction.
        stats.terrain_edit_phases = .{
            .plan_ns = @intCast(commit_total / iterations),
            .write_ns = @intCast(sync_total / iterations),
            .nav_ns = @intCast(nav_total / iterations),
            .main_ns = @intCast(main_total / iterations),
        };
    }
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        stats.work_tuning = suite.workTuningSummary(rewrite_tuner, rewrite_tuner_start);
        stats.secondary_work_tuning = suite.workTuningSummary(nav.tuners.nav.getPtrConst(.remask), remask_tuner_start);
    }
    return stats;
}

// The bodies and chunks patched; under --details the seam's main-thread share (per move) and
// the reaction's stages.
fn writeStaticMoveWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("bodies={} chunks_patched={}", .{ stats.candidate_pairs, stats.output_count });
    if (view == .summary) return;
    try suite.writeMainShare(writer, stats, 1);
    try writer.writeByte(' ');
    try suite.writeNavStages(writer, stats);
}

fn writeStaticDenseWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("statics={} units={} patched={}", .{ stats.candidate_pairs, stats.batch.item_count, stats.output_count });
    if (view == .summary) return;
    try writer.writeAll(" rewrite=");
    try suite.writeStageShape(writer, stats.batch);
    try writer.writeByte(' ');
    try suite.writeNavStages(writer, stats);
    const phases = stats.terrain_edit_phases orelse suite.TerrainEditPhaseSummary{};
    try writer.print(" commit_t={f} sync_t={f} nav_t={f}", .{ suite.formatDuration(phases.plan_ns), suite.formatDuration(phases.write_ns), suite.formatDuration(phases.nav_ns) });
    try suite.writeShare(writer, "main", phases.main_ns, stats.mean_ns);
}
