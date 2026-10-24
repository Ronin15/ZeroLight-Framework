// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! `world-create`: one world created and destroyed through the production build, timed by
//! phase: `surface` (`initProceduralFromMeta`, the threaded paint), `stack`
//! (`addUndergroundLevelStack`), `nav` (`SimulationPipeline.init` on the world, the static
//! colliders, the nav build, and the stored-trigger build, empty here), and `destroy`
//! (`pipeline.deinit`, then the world), on the serial and tuned cases; every tuner runs fresh
//! (a pipeline per create, and the nav build resets the pathfinding tuners after it), so the
//! tuned case is measured fresh (`settled=fresh`, no headline tuner). Configs: sides 256,
//! 1024, and 2048 at 8 levels, then 32 and 128 levels at side 256 (item code
//! `level side * 1000 + levels`). One untimed pass per config on a zero-worker thread system
//! counts live bytes after each create phase and after destroy. Prints each phase's mean
//! time, `surface_main=` (the `surface` phase less the paint's off-main time), `nav_main=`
//! (the `nav` phase less the off-main time of its collider rebuild, nav build, and trigger
//! build stages), `live_kb` after `surface`, `stack`, and `nav` (the counted pass), and
//! `after_destroy_bytes=`; `--details` adds the paint's shape over the measured creates
//! (`stages: paint=`, with its `[threaded/dispatched]` census). Pass shape: each phase's time and
//! bytes at most linear in level area times levels, `surface_main` and `nav_main` per chunk
//! flat, memory following what exists, and zero bytes after destroy. Asserts check the zero
//! after destroy, once per case at the smallest config that the phases build the world
//! `initProcedural` builds, and in the tuned case with workers that the paint and the nav
//! build's remask (each a fresh full-pool tuner) ran on workers.
//!
//! `world-create-statics`: a world's pipeline created over its statics and its first commit
//! seam, through the production entries (`SimulationPipeline.init` with nav over the world on
//! the case's threads, which builds the static colliders, nav, and the stored trigger pairs;
//! `SimulationPipeline.reserveFrame`, which tops up the stored-trigger contact bound; then
//! `commitStructuralAndReact` with no commands), on a fixed one-level 256² walkable world.
//! Item count: statics, two per pitch cell of a square on the world's corner (a solid and a
//! trigger half a tile past it, one stored trigger pair per cell). Timed: `init` and
//! `first_seam`; the world and data build untimed. Cases: serial and tuned; the init's
//! rebuild stages run on fresh tuners no control reaches, as production's do (a pipeline per
//! create), so the tuned case is measured fresh (`settled=fresh`, its tuning cell the collider
//! rewrite tuner after the last measured init). Per create, untimed checks: init
//! stored every pair at the colliders' revision and the world's strips, and `reserveFrame`
//! declared a trigger contact bound covering them; the collider rebuild selected every slot,
//! planned, touched and grouped every static, filled every span and installed every
//! occupied chunk; the trigger rebuild query covered every static, the insert place and sort
//! every pair, the leaf stage their pages, the node merge on main at least one node, and no
//! patch stage or merge ran; in the tuned case with workers every rebuild stage over more
//! than one aligned range (the collider rebuild's six, the trigger build's four, the nav
//! build's remask) ran on workers; the first
//! seam rebuilt nothing (its trigger rebuild records are init's, its patch query empty, its
//! pair count kept); and a collision step after it at the world's strips emits every stored
//! pair with no pair-bound overflow. `main=` is the create's time less the off-main time of the
//! collider rebuild, the nav build, and the trigger build stages. Pass shape: time per static
//! flat up to the insert sort's log factor; main per static flat (the nav build's fixed-world
//! cost an intercept); the
//! first seam's trigger sync O(1); every multi-range rebuild stage on workers in the tuned
//! case; a first step with no overflow. Prints `statics=`, `stored_pairs=`, `init=`, `first_seam=`,
//! `per_static=`, and `main=` with `main_per_item=`; `--details` adds the init's phases
//! (`collider_rebuild=`, `nav_build=`, and `trigger_build=` each with its main, and `rest=`,
//! the init less the three), `first_seam=` with its trigger sync, the shapes of the trigger
//! build's and the collider rebuild's stages (the busiest over the measured creates), and the
//! trigger build's node merge on main (`node_merge=`, its mean nodes and time per node; pass
//! shape: time per node flat in statics).

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const WorldTilesetMeta = @import("../assets/world_tileset_meta.zig").WorldTilesetMeta;
const manifest = @import("../assets/manifest.zig");
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const math = @import("../core/math.zig");
const static_colliders_test_support = @import("../game/systems/static_colliders_test_support.zig");
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const SimulationPipeline = @import("../game/simulation_pipeline.zig").SimulationPipeline;
const CollisionStrips = @import("../game/systems/collision.zig").CollisionStrips;
const TriggerStore = @import("../game/systems/collision_triggers.zig").TriggerStore;
const trigger_page_capacity = @import("../game/systems/collision_triggers.zig").page_capacity;
const NodeMerge = @import("../game/systems/collision_triggers.zig").NodeMerge;
const RebuildStage = @import("../game/systems/static_colliders.zig").RebuildStage;
const WorldBuildConfig = @import("../game/world/system.zig").WorldBuildConfig;
const WorldSystem = @import("../game/world/system.zig").WorldSystem;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "world-create",
    .item_label = ScaleCode.label,
    .describe_item = ScaleCode.describe,
    .item_counts = &item_counts,
    .runCase = runCase,
    .write_workload = writeCreateWorkload,
    // The paint and the nav build thread on fresh tuners no control reaches.
    .cases = &suite.serial_and_tuned_cases,
};

const ScaleCode = suite.ItemCode(struct { level_side: u16, levels: u16 }, &.{3});

// The scale axes: level side at the shallowest depth, then depth at the smallest side.
const level_sides = [_]u16{ 256, 1024, 2048 };
const level_counts = [_]u16{ 8, 32, 128 };

const item_counts = blk: {
    var counts: [level_sides.len + level_counts.len - 1]usize = undefined;
    for (level_sides, 0..) |side, index| counts[index] = ScaleCode.of(.{ .level_side = side, .levels = level_counts[0] });
    for (level_counts[1..], level_sides.len..) |levels, index| counts[index] = ScaleCode.of(.{ .level_side = level_sides[0], .levels = levels });
    break :blk counts;
};

const PhaseTimes = struct {
    surface_ns: u64 = 0,
    stack_ns: u64 = 0,
    nav_ns: u64 = 0,
    destroy_ns: u64 = 0,
    // The `nav` phase's stage time on workers: its collider rebuild, nav build, and trigger
    // build.
    nav_off_main_ns: u64 = 0,
    // The surface's procedural paint, read before the world is destroyed.
    paint: BatchStats = .{},
    // The nav build's remask over every level.
    nav_remask: BatchStats = .{},
};

// Live bytes of `counter` (allocated minus freed), or zero without one.
fn liveBytes(counter: ?*const std.testing.FailingAllocator) usize {
    const state = counter orelse return 0;
    return state.allocated_bytes - state.freed_bytes;
}

// A phase's end: its timestamp and the counter's live bytes then.
const PhaseMark = struct {
    end_ns: i96 = 0,
    live_bytes: usize = 0,
};

fn markPhase(io: std.Io, counter: ?*const std.testing.FailingAllocator) PhaseMark {
    return .{ .end_ns = suite.nowNs(io), .live_bytes = liveBytes(counter) };
}

// The production world build at its two phases, in `initProcedural`'s order: the surface,
// then the underground stack, marking each phase's end.
fn buildWorldInPhases(
    allocator: std.mem.Allocator,
    io: std.Io,
    meta: *const WorldTilesetMeta,
    config: WorldBuildConfig,
    threads: *ThreadSystem,
    counter: ?*const std.testing.FailingAllocator,
    surface: *PhaseMark,
    stack: *PhaseMark,
) !WorldSystem {
    var world = try WorldSystem.initProceduralFromMeta(allocator, meta, config, threads);
    errdefer world.deinit();
    surface.* = markPhase(io, counter);
    try world.addUndergroundLevelStack(meta, config.underground_level_count);
    stack.* = markPhase(io, counter);
    return world;
}

// Creates and destroys one world on `allocator`, timing each phase. With `counter` (the
// state behind `allocator`), records its live bytes after each phase into `bytes`.
fn createAndDestroy(
    allocator: std.mem.Allocator,
    io: std.Io,
    meta: *const WorldTilesetMeta,
    config: WorldBuildConfig,
    threads: *ThreadSystem,
    counter: ?*const std.testing.FailingAllocator,
    bytes: *suite.WorldCreateSummary,
) !PhaseTimes {
    var surface = PhaseMark{};
    var stack = PhaseMark{};
    const start_ns = suite.nowNs(io);
    var world = try buildWorldInPhases(allocator, io, meta, config, threads, counter, &surface, &stack);
    errdefer world.deinit();

    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    var pipeline = try SimulationPipeline.init(allocator, &data, world.worldWidthPixels(), world.worldHeightPixels(), .{
        .navigation_world = &world,
        .build_thread_system = threads,
    });
    const nav = markPhase(io, counter);
    const nav_build = pipeline.pathfinding.perf.last_nav_build;
    const nav_off_main_ns = sumOffMainNs(&colliderRebuildBatches(&pipeline)) + nav_build.perf.off_main_stage_ns + sumOffMainNs(&triggerRebuildBatches(&pipeline));
    const paint = world.perf.last_paint_batch;

    pipeline.deinit();
    data.deinit();
    world.deinit();
    const destroy = markPhase(io, counter);
    bytes.surface_bytes = surface.live_bytes;
    bytes.stack_bytes = stack.live_bytes;
    bytes.nav_bytes = nav.live_bytes;
    bytes.destroyed_bytes = destroy.live_bytes;
    return .{
        .surface_ns = suite.elapsedNs(start_ns, surface.end_ns),
        .stack_ns = suite.elapsedNs(surface.end_ns, stack.end_ns),
        .nav_ns = suite.elapsedNs(stack.end_ns, nav.end_ns),
        .destroy_ns = suite.elapsedNs(nav.end_ns, destroy.end_ns),
        .nav_off_main_ns = nav_off_main_ns,
        .paint = paint,
        .nav_remask = nav_build.perf.remask_batch,
    };
}

// Builds `config` through `buildWorldInPhases` and through `initProcedural`, untimed, and
// fails on any difference in size, levels, tiles, or blocked cells.
fn checkPhasesMatchInitProcedural(allocator: std.mem.Allocator, io: std.Io, meta: *const WorldTilesetMeta, config: WorldBuildConfig, threads: *ThreadSystem) !void {
    // `initProcedural` reads the tileset from runtime assets; the slot shares `meta`.
    var runtime_assets = RuntimeAssets.init(allocator);
    const slot = &runtime_assets.atlas_meta[manifest.spriteIndex(.world_tileset)];
    slot.* = .{ .world_tileset = meta.* };
    defer slot.* = null;

    var surface = PhaseMark{};
    var stack = PhaseMark{};
    var phased = try buildWorldInPhases(allocator, io, meta, config, threads, null, &surface, &stack);
    defer phased.deinit();
    var whole = try WorldSystem.initProcedural(allocator, &runtime_assets, config, threads);
    defer whole.deinit();

    const same_shape = whole.width == phased.width and whole.height == phased.height and
        whole.tile_size == phased.tile_size and whole.chunk_size_tiles == phased.chunk_size_tiles and
        whole.levelCount() == phased.levelCount() and whole.dense_layers.len == phased.dense_layers.len and
        whole.sparse_tiles.len == phased.sparse_tiles.len;
    if (!same_shape) return error.WorldCreatePhaseDrift;
    for (0..whole.levelCount()) |level_index| {
        const level: u16 = @intCast(level_index);
        if (whole.levelBaseZ(level) != phased.levelBaseZ(level)) return error.WorldCreatePhaseDrift;
        for (0..whole.height) |y| for (0..whole.width) |x| {
            if (whole.levelBlocksMovement(level, @intCast(x), @intCast(y)) != phased.levelBlocksMovement(level, @intCast(x), @intCast(y))) return error.WorldCreatePhaseDrift;
        };
    }
    for (0..whole.dense_layers.len) |layer| {
        for (0..whole.height) |y| for (0..whole.width) |x| {
            if (whole.denseTile(layer, @intCast(x), @intCast(y)) != phased.denseTile(layer, @intCast(x), @intCast(y))) return error.WorldCreatePhaseDrift;
        };
    }
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const fields = try ScaleCode.decode(item_count);
    std.debug.assert(fields.levels >= 1);
    var meta = try fixtures.loadTilesetMeta(allocator, io);
    defer meta.deinit();
    const config = WorldBuildConfig{
        .width_tiles = fields.level_side,
        .height_tiles = fields.level_side,
        .underground_level_count = fields.levels - 1,
    };

    // The counted pass runs on the main thread alone: the counter is not thread-safe.
    var summary = suite.WorldCreateSummary{};
    {
        var serial_threads = try fixtures.initRequiredCaseThreads(allocator, io, suite.serial_cases[0]);
        defer serial_threads.deinit();
        var counter = std.testing.FailingAllocator.init(allocator, .{});
        _ = try createAndDestroy(counter.allocator(), io, &meta, config, &serial_threads, &counter, &summary);
        std.debug.assert(summary.destroyed_bytes == 0);
    }

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    // Once per case, at the smallest config: the bench's phases still build what
    // `initProcedural` builds.
    if (item_count == item_counts[0]) try checkPhasesMatchInitProcedural(allocator, io, &meta, config, &threads);
    var uncounted = suite.WorldCreateSummary{};
    for (0..options.warmup_iterations) |_| {
        _ = try createAndDestroy(allocator, io, &meta, config, &threads, null, &uncounted);
    }
    var accumulator = suite.StatsAccumulator.init(item_count);
    var totals: [4]u128 = @splat(0);
    var nav_main_total: u128 = 0;
    var surface_main_total: u128 = 0;
    var paint_shapes = suite.StageShapes(1){};
    for (0..options.iterations) |_| {
        const times = try createAndDestroy(allocator, io, &meta, config, &threads, null, &uncounted);
        try suite.checkRebuildOnWorkers(case, &threads, times.paint);
        try suite.checkRebuildOnWorkers(case, &threads, times.nav_remask);
        paint_shapes.add(.{times.paint});
        surface_main_total += times.surface_ns -| offMainNs(times.paint);
        nav_main_total += times.nav_ns -| times.nav_off_main_ns;
        const phases = [_]u64{ times.surface_ns, times.stack_ns, times.nav_ns, times.destroy_ns };
        var sample_ns: u64 = 0;
        for (phases, &totals) |phase_ns, *total| {
            total.* += phase_ns;
            sample_ns += phase_ns;
        }
        accumulator.record(sample_ns, .{});
    }
    var stats = accumulator.finish();
    if (stats.iterations > 0) {
        summary.surface_ns = @intCast(totals[0] / stats.iterations);
        summary.stack_ns = @intCast(totals[1] / stats.iterations);
        summary.nav_ns = @intCast(totals[2] / stats.iterations);
        summary.destroy_ns = @intCast(totals[3] / stats.iterations);
        summary.nav_main_ns = @intCast(nav_main_total / stats.iterations);
        summary.surface_main_ns = @intCast(surface_main_total / stats.iterations);
        paint_shapes.print(&stats.details, "stages", .{"paint"});
    }
    stats.items_per_second = suite.itemsPerSecond(@as(usize, fields.level_side) * fields.level_side * fields.levels, stats.mean_ns);
    stats.batch_carried = false;
    // A summary of any tuner after the create would report a reset tuner, not the build's.
    stats.tuners_fresh = case.adaptive;
    stats.world_create = summary;
    return stats;
}

fn writeCreateWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    const summary = stats.world_create orelse return;
    try writer.print("surface={f} stack={f} nav={f} destroy={f} surface_main={f} nav_main={f} live_kb surface={} stack={} nav={} after_destroy_bytes={}", .{
        suite.formatDuration(summary.surface_ns),
        suite.formatDuration(summary.stack_ns),
        suite.formatDuration(summary.nav_ns),
        suite.formatDuration(summary.destroy_ns),
        suite.formatDuration(summary.surface_main_ns),
        suite.formatDuration(summary.nav_main_ns),
        summary.surface_bytes / 1024,
        summary.stack_bytes / 1024,
        summary.nav_bytes / 1024,
        summary.destroyed_bytes,
    });
}

pub const statics_group = suite.BenchmarkGroup{
    .name = "world-create-statics",
    .item_label = "statics (a solid and a trigger per cell)",
    .item_counts = &statics_counts,
    .runCase = runStaticsCase,
    .write_workload = writeStaticsWorkload,
    // The init's rebuild stages run on fresh tuners no control reaches.
    .cases = &suite.serial_and_tuned_cases,
};

const statics_counts = [_]usize{ 2_048, 8_192, 32_768 };
// The fixed world: one level, the largest count's pitch grid a side.
const statics_world_tiles: u16 = 256;
// A cell's two statics sit on a two-tile pitch: the solid at the cell origin, the trigger half
// a tile down and right, overlapping only its own cell's solid.
const statics_pitch_tiles: usize = 2;

const StaticsFixture = struct {
    data: DataSystem,
    world: WorldSystem,
    cells: usize,
    // The chunks the statics occupy: the square's side in chunks, squared.
    chunks: usize,

    fn deinit(self: *StaticsFixture) void {
        self.world.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

fn addStatic(data: *DataSystem, position: math.Vec2, size: f32, trigger: bool) !EntityId {
    const entity = try fixtures.addBody(data, position, .{ .x = size, .y = size }, .static);
    if (trigger) try data.setCollisionResponse(entity, .{ .mobility = .static, .mode = .trigger });
    return entity;
}

fn createStaticsFixture(allocator: std.mem.Allocator, io: std.Io, statics: usize) !StaticsFixture {
    const cells = statics / 2;
    const side = std.math.sqrt(cells);
    if (side * side * 2 != statics) return error.WorldCreateStaticsNotSquare;
    if (side * statics_pitch_tiles > statics_world_tiles) return error.WorldCreateStaticsPastWorld;
    var meta = try fixtures.loadTilesetMeta(allocator, io);
    defer meta.deinit();
    var world = try fixtures.buildBandedWorld(allocator, &meta, statics_world_tiles, 1, "grass", "grass");
    errdefer world.deinit();
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const tile = world.tile_size;
    const pitch = tile * @as(f32, @floatFromInt(statics_pitch_tiles));
    for (0..side) |cell_y| for (0..side) |cell_x| {
        const origin = math.Vec2{ .x = @as(f32, @floatFromInt(cell_x)) * pitch, .y = @as(f32, @floatFromInt(cell_y)) * pitch };
        _ = try addStatic(&data, origin, tile, false);
        _ = try addStatic(&data, .{ .x = origin.x + tile / 2, .y = origin.y + tile / 2 }, tile, true);
    };
    const chunk_tiles: usize = world.chunk_size_tiles;
    const chunks_side = (side * statics_pitch_tiles + chunk_tiles - 1) / chunk_tiles;
    return .{ .data = data, .world = world, .cells = cells, .chunks = chunks_side * chunks_side };
}

const collider_rebuild_stages = std.enums.values(RebuildStage);
const TriggerRebuildStage = @FieldType(TriggerStore.Perf, "last_rebuild_batches").Key;
const trigger_rebuild_stages = std.enums.values(TriggerRebuildStage);
// The trigger build's stages: the rebuild query, then the store's.
const trigger_stage_count = 1 + trigger_rebuild_stages.len;

const StaticsSample = struct {
    init_ns: u64,
    seam_ns: u64,
    // The first seam's `SimulationPipeline.Perf.seam_trigger_sync_ns`.
    trigger_sync_ns: u64,
    // The init's phases (`SimulationPipeline.Perf`'s `create_*`).
    collider_rebuild_ns: u64,
    nav_build_ns: u64,
    trigger_build_ns: u64,
    // Each phase's stages' worker dispatch time.
    collider_off_main_ns: u64,
    nav_off_main_ns: u64,
    trigger_off_main_ns: u64,
    collider_batches: [collider_rebuild_stages.len]BatchStats,
    trigger_batches: [trigger_stage_count]BatchStats,
    // The trigger build's node merge on main.
    node_merge: NodeMerge,
    // The init's collider rewrite tuner, fresh with the pipeline as in production.
    rewrite_tuning: suite.WorkTuningSummary,
};

fn triggerRebuildBatches(pipeline: *const SimulationPipeline) [trigger_stage_count]BatchStats {
    const store_batches = pipeline.collision.trigger_store.perf.last_rebuild_batches.values;
    return [1]BatchStats{pipeline.collision.perf.trigger_rebuild_query_batch} ++ store_batches;
}

fn colliderRebuildBatches(pipeline: *const SimulationPipeline) [collider_rebuild_stages.len]BatchStats {
    var batches: [collider_rebuild_stages.len]BatchStats = undefined;
    for (&batches, collider_rebuild_stages) |*batch, stage| batch.* = pipeline.static_colliders.perf.last_batches.get(static_colliders_test_support.colliderStage(stage));
    return batches;
}

fn sumOffMainNs(batches: []const BatchStats) u64 {
    var total: u64 = 0;
    for (batches) |batch| total += offMainNs(batch);
    return total;
}

// The init's trigger build: every pair stored at the colliders' revision and the world's
// strips, the contact bound `reserveFrame` declared covering them, the rebuild query over
// every static, the insert place and sort over every pair, the leaf stage over their pages,
// the node merge over at least one node, and no patch stage or merge.
fn checkInitTriggerBuild(pipeline: *const SimulationPipeline, world: *const WorldSystem, statics: usize, cells: usize, batches: [trigger_stage_count]BatchStats) !void {
    const collision = &pipeline.collision;
    const store = &collision.trigger_store;
    if (!store.ready or store.seen_revision != pipeline.static_colliders.view().revision) return error.InitTriggerStoreNotBuilt;
    if (collision.trigger_strips.height != CollisionStrips.ofWorld(world).height) return error.InitTriggerStripsNotWorlds;
    if (store.pair_count != cells) return error.TriggerPairCountMismatch;
    if (collision.reserved_trigger_bound < store.pair_count) return error.InitTriggerBoundNotToppedUp;
    if (batches[0].item_count != statics) return error.TriggerRebuildQueryMissedStatics;
    const store_batches = &store.perf.last_rebuild_batches;
    if (store_batches.get(.insert_place).item_count != cells) return error.TriggerRebuildPlaceMissedPairs;
    if (store_batches.get(.insert_sort).item_count != cells) return error.TriggerRebuildSortMissedPairs;
    const pages = std.math.divCeil(usize, cells, trigger_page_capacity) catch unreachable; // lint:allow catch-unreachable: the page capacity is a nonzero constant
    if (store_batches.get(.leaf).item_count != pages) return error.TriggerRebuildLeafMissedPages;
    if (store.perf.last_rebuild_node_merge.outputs < 1) return error.TriggerRebuildNodeMergeSkipped;
    if (collision.perf.trigger_query_batch.item_count != 0) return error.InitTriggerBuildPatched;
    for (store.perf.last_batches.values) |batch| if (batch.item_count != 0) return error.InitTriggerBuildPatched;
    if (store.perf.last_node_merge.outputs != 0) return error.InitTriggerBuildPatched;
}

// One create and first seam on `threads`, timed, then a collision step and the teardown,
// untimed, with the group's checks.
fn createWithStatics(allocator: std.mem.Allocator, io: std.Io, fixture: *StaticsFixture, statics: usize, case: suite.BenchmarkCase, threads: *ThreadSystem) !StaticsSample {
    const start_ns = suite.nowNs(io);
    var seam = try fixtures.PipelineSeam.init(allocator, &fixture.data, &fixture.world, .{
        .structural_headroom = 0,
        .pathfinding = .{ .worker_participant_count = threads.participantSlotCount() },
        .build_thread_system = threads,
    });
    defer seam.deinit();
    const init_end_ns = suite.nowNs(io);
    const pipeline = &seam.pipeline;
    // Read before the seam, which clears `perf` and replaces the collider records.
    const perf = pipeline.perf;
    const nav_build = pipeline.pathfinding.perf.last_nav_build;
    const collider_batches = colliderRebuildBatches(pipeline);
    const trigger_batches = triggerRebuildBatches(pipeline);
    const node_merge = pipeline.collision.trigger_store.perf.last_rebuild_node_merge;
    const rewrite_tuning = suite.workTuningSummary(pipeline.static_colliders.rebuild_tuners.getPtrConst(.rewrite), .fresh);
    if (static_colliders_test_support.liveRowCount(pipeline.static_colliders) != statics) return error.WrongStaticCount;
    try suite.checkRebuildWork(collider_batches, fixture.data.slots.items.len, statics, fixture.chunks);
    try checkInitTriggerBuild(pipeline, &fixture.world, statics, fixture.cells, trigger_batches);
    for (collider_batches ++ trigger_batches ++ [1]BatchStats{nav_build.perf.remask_batch}) |batch| try suite.checkRebuildOnWorkers(case, threads, batch);

    const seam_start_ns = suite.nowNs(io);
    seam.frame.beginStep();
    _ = try seam.commit(&fixture.data, &fixture.world, &.{}, threads);
    const seam_end_ns = suite.nowNs(io);
    // The first seam rebuilt nothing: init's records stand, and it patched nothing.
    if (!std.meta.eql(triggerRebuildBatches(pipeline), trigger_batches)) return error.FirstSeamRebuiltTriggers;
    if (pipeline.collision.perf.trigger_query_batch.item_count != 0) return error.FirstSeamPatchedTriggers;
    if (pipeline.collision.trigger_store.pair_count != fixture.cells) return error.TriggerPairCountMismatch;

    // The first collision step emits every stored pair inside the declared bound.
    const step = try seam.collisionStep(&fixture.data, &fixture.world, threads, case);
    if (pipeline.collision.perf.pair_bound_overflows != 0) return error.FirstStepPairBoundOverflowed;
    if (step.contact_count != fixture.cells) return error.FirstStepMissedStoredPairs;
    return .{
        .init_ns = suite.elapsedNs(start_ns, init_end_ns),
        .seam_ns = suite.elapsedNs(seam_start_ns, seam_end_ns),
        .trigger_sync_ns = pipeline.perf.seam_trigger_sync_ns,
        .collider_rebuild_ns = perf.create_collider_rebuild_ns,
        .nav_build_ns = perf.create_nav_build_ns,
        .trigger_build_ns = perf.create_trigger_build_ns,
        .collider_off_main_ns = sumOffMainNs(&collider_batches),
        .nav_off_main_ns = nav_build.perf.off_main_stage_ns,
        .trigger_off_main_ns = sumOffMainNs(&trigger_batches),
        .collider_batches = collider_batches,
        .trigger_batches = trigger_batches,
        .node_merge = node_merge,
        .rewrite_tuning = rewrite_tuning,
    };
}

// Mean nanoseconds of the statics group's totals.
const StaticsTotals = struct {
    init: u128 = 0,
    seam: u128 = 0,
    trigger_sync: u128 = 0,
    main: u128 = 0,
    collider_rebuild: u128 = 0,
    collider_main: u128 = 0,
    nav_build: u128 = 0,
    nav_main: u128 = 0,
    trigger_build: u128 = 0,
    trigger_main: u128 = 0,
    node_merge_outputs: u128 = 0,
    node_merge_ns: u128 = 0,
    rest: u128 = 0,

    fn add(self: *StaticsTotals, sample: StaticsSample) void {
        const ns = sample.init_ns + sample.seam_ns;
        self.init += sample.init_ns;
        self.seam += sample.seam_ns;
        self.trigger_sync += sample.trigger_sync_ns;
        self.main += ns -| (sample.collider_off_main_ns + sample.nav_off_main_ns + sample.trigger_off_main_ns);
        self.collider_rebuild += sample.collider_rebuild_ns;
        self.collider_main += sample.collider_rebuild_ns -| sample.collider_off_main_ns;
        self.nav_build += sample.nav_build_ns;
        self.nav_main += sample.nav_build_ns -| sample.nav_off_main_ns;
        self.trigger_build += sample.trigger_build_ns;
        self.trigger_main += sample.trigger_build_ns -| sample.trigger_off_main_ns;
        self.node_merge_outputs += sample.node_merge.outputs;
        self.node_merge_ns += sample.node_merge.ns;
        self.rest += sample.init_ns -| (sample.collider_rebuild_ns + sample.nav_build_ns + sample.trigger_build_ns);
    }

    fn mean(total: u128, iterations: usize) u64 {
        return @intCast(total / iterations);
    }
};

fn runStaticsCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, statics: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var fixture = try createStaticsFixture(allocator, io, statics);
    defer fixture.deinit();
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    for (0..options.warmup_iterations) |_| _ = try createWithStatics(allocator, io, &fixture, statics, case, &threads);
    var accumulator = suite.StatsAccumulator.init(statics);
    var totals = StaticsTotals{};
    var collider_shapes = suite.StageShapes(collider_rebuild_stages.len){};
    var trigger_shapes = suite.StageShapes(trigger_stage_count){};
    var rewrite_tuning: ?suite.WorkTuningSummary = null;
    for (0..options.iterations) |_| {
        const sample = try createWithStatics(allocator, io, &fixture, statics, case, &threads);
        rewrite_tuning = sample.rewrite_tuning;
        totals.add(sample);
        collider_shapes.add(sample.collider_batches);
        trigger_shapes.add(sample.trigger_batches);
        accumulator.record(sample.init_ns + sample.seam_ns, .{});
    }
    var stats = accumulator.finish();
    stats.batch_carried = false;
    stats.sample_count = statics;
    stats.output_count = fixture.cells;
    if (case.adaptive) stats.work_tuning = rewrite_tuning;
    if (stats.iterations > 0) {
        const n = stats.iterations;
        stats.deferred_count = StaticsTotals.mean(totals.init, n);
        stats.fallback_deferred_count = StaticsTotals.mean(totals.seam, n);
        stats.main_ns = StaticsTotals.mean(totals.main, n);
        stats.details.print("collider_rebuild={f} (main {f}) nav_build={f} (main {f}) trigger_build={f} (main {f}) rest={f} first_seam={f} (trigger_sync {f})\n", .{
            suite.formatDuration(StaticsTotals.mean(totals.collider_rebuild, n)),
            suite.formatDuration(StaticsTotals.mean(totals.collider_main, n)),
            suite.formatDuration(StaticsTotals.mean(totals.nav_build, n)),
            suite.formatDuration(StaticsTotals.mean(totals.nav_main, n)),
            suite.formatDuration(StaticsTotals.mean(totals.trigger_build, n)),
            suite.formatDuration(StaticsTotals.mean(totals.trigger_main, n)),
            suite.formatDuration(StaticsTotals.mean(totals.rest, n)),
            suite.formatDuration(StaticsTotals.mean(totals.seam, n)),
            suite.formatDuration(StaticsTotals.mean(totals.trigger_sync, n)),
        });
        var label_buffer: [48]u8 = undefined;
        stats.details.print("trigger_build: query={s}", .{trigger_shapes.label(0, &label_buffer)});
        for (trigger_rebuild_stages, 1..) |stage, index| stats.details.print(" {s}={s}", .{ @tagName(stage), trigger_shapes.label(index, &label_buffer) });
        const per_node_ns: u64 = if (totals.node_merge_outputs > 0) @intCast(totals.node_merge_ns / totals.node_merge_outputs) else 0;
        stats.details.print(" node_merge={}x({f})", .{ StaticsTotals.mean(totals.node_merge_outputs, n), suite.formatDuration(per_node_ns) });
        stats.details.print("\ncollider_rebuild:", .{});
        for (collider_rebuild_stages, 0..) |stage, index| stats.details.print(" {s}={s}", .{ @tagName(stage), collider_shapes.label(index, &label_buffer) });
        stats.details.print("\n", .{});
    }
    return stats;
}

// `sample_count` holds the statics, `output_count` the stored pairs, `deferred_count` the
// mean `init` time and `fallback_deferred_count` the mean first seam time.
fn writeStaticsWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("statics={} stored_pairs={} init={f} first_seam={f} per_static={f}", .{
        stats.sample_count,
        stats.output_count,
        suite.formatDuration(stats.deferred_count),
        suite.formatDuration(stats.fallback_deferred_count),
        suite.formatDuration(stats.mean_ns / @max(stats.sample_count, 1)),
    });
    try suite.writeMainShare(writer, stats, stats.sample_count);
}
