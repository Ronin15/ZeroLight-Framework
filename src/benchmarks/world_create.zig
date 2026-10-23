// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! `world-create`: one world created and destroyed through the production build, timed by
//! phase: `surface` (`initProceduralFromMeta`, the threaded paint), `stack`
//! (`addUndergroundLevelStack`), `nav` (`SimulationPipeline.init` on the world, the static
//! colliders and the nav build), and `destroy` (`pipeline.deinit`, then the world), on the
//! serial and tuned cases. Configs: sides 256, 1024, and 2048 at 8 levels, then 32 and 128
//! levels at side 256 (item code `level side * 1000 + levels`). One untimed pass per config
//! on a zero-worker thread system counts live bytes after each create phase and after
//! destroy. Prints each phase's mean time, `live_kb` after `surface`, `stack`, and `nav`
//! (the counted pass), and `after_destroy_bytes=`. Pass shape: each phase's time and bytes
//! at most linear in level area times levels, memory following what exists, and zero bytes
//! after destroy. Asserts check the zero after destroy and, once per case at the smallest
//! config, that the phases build the world `initProcedural` builds.
//!
//! `world-create-statics`: a world's pipeline created over its statics and its first commit
//! seam, through the production entries (`SimulationPipeline.init` with nav over the world on
//! the case's threads, `SimulationPipeline.reserveFrame`, then `commitStructuralAndReact`
//! with no commands), on a fixed one-level 256² walkable world. Item count: statics, two per
//! pitch cell of a square on the world's corner (a solid and a trigger half a tile past it,
//! one stored trigger pair per cell). Timed: `init` and `first_seam`; the world and data
//! build untimed. Today the stored-trigger store first builds in the first seam's trigger
//! sync (a rebuild over every row, which also grows the stored trigger contact bound).
//! Cases: serial, tuned, and `thread-fixed-auto`, which pins the first seam's trigger rebuild
//! stages (the rebuild query and the store's four) to the case's fixed range on every worker
//! between `init` and the seam, and fails when one of them ran inline over more than one
//! range. The init's collider rebuild and nav build run on fresh tuners no control reaches.
//! `main=` is the create's time less the off-main time of the collider rebuild and the
//! trigger rebuild stages; the nav build's worker time is not split out yet, so it counts
//! as main. A measuring landing: pass shape, for the fix that builds the store at create, is
//! create plus first seam linear in statics with main per static flat, the first seam's
//! trigger sync O(1) (no rebuild), and the first collision step after it emitting every
//! stored pair with no pair-bound overflow. Asserts check fixture invariants only: the
//! collider rows, and one stored pair per cell after the first seam. Prints `statics=`,
//! `stored_pairs=`, `init=`, `first_seam=`, `per_static=`, and `main=` with
//! `main_per_item=`; `--details` adds the first seam's `trigger_sync=` time and its rebuild query's shape
//! (`trigger_rebuild_query=` workers/ranges, the last measured create's).

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const WorldTilesetMeta = @import("../assets/world_tileset_meta.zig").WorldTilesetMeta;
const manifest = @import("../assets/manifest.zig");
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const math = @import("../core/math.zig");
const static_colliders_test_support = @import("../game/systems/static_colliders_test_support.zig");
const pinThreadedProfile = @import("../game/simulation_pipeline_test_support.zig").pinThreadedProfile;
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const AdaptiveWorkProfile = @import("../app/thread_system.zig").AdaptiveWorkProfile;
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const SimulationPipeline = @import("../game/simulation_pipeline.zig").SimulationPipeline;
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
    // The paint and the nav build thread; every other control has no path of its own.
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
        .nav_build_thread_system = threads,
    });
    const nav = markPhase(io, counter);

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
    for (0..options.iterations) |_| {
        const times = try createAndDestroy(allocator, io, &meta, config, &threads, null, &uncounted);
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
    }
    stats.items_per_second = suite.itemsPerSecond(@as(usize, fields.level_side) * fields.level_side * fields.levels, stats.mean_ns);
    stats.batch_carried = false;
    stats.world_create = summary;
    return stats;
}

fn writeCreateWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    const summary = stats.world_create orelse return;
    try writer.print("surface={f} stack={f} nav={f} destroy={f} live_kb surface={} stack={} nav={} after_destroy_bytes={}", .{
        suite.formatDuration(summary.surface_ns),
        suite.formatDuration(summary.stack_ns),
        suite.formatDuration(summary.nav_ns),
        suite.formatDuration(summary.destroy_ns),
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
    // The init's stages run their own fresh tuners; the fixed case pins the first seam's
    // trigger rebuild.
    .cases = &statics_cases,
};

const statics_cases = suite.casesNamed(&.{ "serial-direct", "thread-fixed-auto", "thread-adaptive-tuned-range" });
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
    return .{ .data = data, .world = world, .cells = cells };
}

const StaticsSample = struct {
    init_ns: u64,
    seam_ns: u64,
    trigger_sync_ns: u64,
    // The collider rebuild's and the trigger rebuild stages' worker dispatch time.
    off_main_ns: u64,
    // The first seam's trigger rebuild query.
    query_batch: BatchStats,
};

// The first seam's trigger rebuild stages: the rebuild query, then the store's.
const trigger_rebuild_stage_count = 5;

fn triggerRebuildBatches(pipeline: *const SimulationPipeline) [trigger_rebuild_stage_count]BatchStats {
    const store_batches = pipeline.collision.trigger_store.last_rebuild_batches.values;
    return [1]BatchStats{pipeline.collision.trigger_rebuild_query_batch} ++ store_batches;
}

// The fixed case's control: every trigger rebuild stage tuner replaced by one pinned to the
// case's range on every worker, so the first seam's rebuild dispatches at that shape. The
// replacement has no full-pool first selection, which would override the pin. Other cases
// keep production's fresh rebuild tuners.
fn pinTriggerRebuild(pipeline: *SimulationPipeline, case: suite.BenchmarkCase, threads: *const ThreadSystem) void {
    const items_per_range = case.stageItemsPerRange(1) orelse return;
    if (threads.workerThreadCount() == 0) return;
    const profile: AdaptiveWorkProfile = .{ .worker_threads = threads.workerThreadCount(), .items_per_range = items_per_range };
    pinFixed(&pipeline.collision.trigger_query_rebuild_tuner, profile);
    for (&pipeline.collision.trigger_store.rebuild_tuners.values) |*tuner| pinFixed(tuner, profile);
}

fn pinFixed(tuner: *AdaptiveWorkTuner, profile: AdaptiveWorkProfile) void {
    tuner.* = AdaptiveWorkTuner.init(.{});
    pinThreadedProfile(tuner, profile);
}

// One create and first seam on `threads`, timed, then the teardown, untimed. Checks the
// fixture invariants, and on the fixed case that the trigger rebuild ran on workers.
fn createWithStatics(allocator: std.mem.Allocator, io: std.Io, fixture: *StaticsFixture, statics: usize, case: suite.BenchmarkCase, threads: *ThreadSystem) !StaticsSample {
    const start_ns = suite.nowNs(io);
    var seam = try fixtures.PipelineSeam.init(allocator, &fixture.data, &fixture.world, .{
        .structural_headroom = 0,
        .pathfinding = .{ .worker_participant_count = threads.participantSlotCount() },
        .nav_build_thread_system = threads,
    });
    defer seam.deinit();
    const init_end_ns = suite.nowNs(io);
    const pipeline = &seam.pipeline;
    // The init's collider rebuild; the seam's sync replaces these records.
    const rebuild_off_main_ns = static_colliders_test_support.lastOffMainNs(pipeline.static_colliders);
    pinTriggerRebuild(pipeline, case, threads);
    const seam_start_ns = suite.nowNs(io);
    seam.frame.beginStep();
    _ = try seam.commit(&fixture.data, &fixture.world, &.{}, threads);
    const seam_end_ns = suite.nowNs(io);
    if (static_colliders_test_support.liveRowCount(pipeline.static_colliders) != statics) return error.WrongStaticCount;
    if (pipeline.collision.trigger_store.pair_count != fixture.cells) return error.TriggerPairCountMismatch;
    const trigger_batches = triggerRebuildBatches(pipeline);
    try suite.checkStagesDispatched(case, threads, case.stageItemsPerRange(1), &trigger_batches);
    var off_main_ns = rebuild_off_main_ns;
    for (trigger_batches) |batch| off_main_ns += offMainNs(batch);
    return .{
        .init_ns = suite.elapsedNs(start_ns, init_end_ns),
        .seam_ns = suite.elapsedNs(seam_start_ns, seam_end_ns),
        .trigger_sync_ns = pipeline.perf.seam_trigger_sync_ns,
        .off_main_ns = off_main_ns,
        .query_batch = trigger_batches[0],
    };
}

fn runStaticsCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, statics: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var fixture = try createStaticsFixture(allocator, io, statics);
    defer fixture.deinit();
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    for (0..options.warmup_iterations) |_| _ = try createWithStatics(allocator, io, &fixture, statics, case, &threads);
    var accumulator = suite.StatsAccumulator.init(statics);
    var totals: [4]u128 = @splat(0);
    var query_batch: BatchStats = .{};
    for (0..options.iterations) |_| {
        const sample = try createWithStatics(allocator, io, &fixture, statics, case, &threads);
        query_batch = sample.query_batch;
        const ns = sample.init_ns + sample.seam_ns;
        totals[0] += sample.init_ns;
        totals[1] += sample.seam_ns;
        totals[2] += sample.trigger_sync_ns;
        totals[3] += ns -| sample.off_main_ns;
        accumulator.record(ns, .{});
    }
    var stats = accumulator.finish();
    stats.batch_carried = false;
    stats.sample_count = statics;
    stats.output_count = fixture.cells;
    if (stats.iterations > 0) {
        stats.deferred_count = @intCast(totals[0] / stats.iterations);
        stats.fallback_deferred_count = @intCast(totals[1] / stats.iterations);
        stats.main_ns = @intCast(totals[3] / stats.iterations);
        stats.details.print("trigger_sync={f} trigger_rebuild_query={}w/{}r\n", .{
            suite.formatDuration(@intCast(totals[2] / stats.iterations)),
            if (query_batch.ran_inline) 0 else query_batch.active_worker_threads,
            query_batch.range_count,
        });
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
