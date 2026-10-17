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

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const WorldTilesetMeta = @import("../assets/world_tileset_meta.zig").WorldTilesetMeta;
const manifest = @import("../assets/manifest.zig");
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const SimulationPipeline = @import("../game/simulation_pipeline.zig").SimulationPipeline;
const WorldBuildConfig = @import("../game/world/system.zig").WorldBuildConfig;
const WorldSystem = @import("../game/world/system.zig").WorldSystem;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "world-create",
    .item_label = ScaleCode.label,
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
        whole.levelCount() == phased.levelCount() and whole.denseLayerCount() == phased.denseLayerCount() and
        whole.sparseTileCount() == phased.sparseTileCount();
    if (!same_shape) return error.WorldCreatePhaseDrift;
    for (0..whole.levelCount()) |level_index| {
        const level: u16 = @intCast(level_index);
        if (whole.levelBaseZ(level) != phased.levelBaseZ(level)) return error.WorldCreatePhaseDrift;
        for (0..whole.height) |y| for (0..whole.width) |x| {
            if (whole.levelBlocksMovement(level, @intCast(x), @intCast(y)) != phased.levelBlocksMovement(level, @intCast(x), @intCast(y))) return error.WorldCreatePhaseDrift;
        };
    }
    for (0..whole.denseLayerCount()) |layer| {
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
