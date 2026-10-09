// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Chunk-owned terrain scaling: one fixed-size terrain change per timed iteration
//! on worlds of every level size and depth. The change is the same at every point,
//! so the cost model expects each group flat across both axes:
//!   - `chunk-scale-dig`: 64 single-cell digs and refills, each in its own chunk.
//!   - `chunk-scale-cave-in`: a 32x32 tunnel region on four stacked levels collapses
//!     to solid and is carved back, in one step each.
//!   - `chunk-scale-explosion-fill`: a radius-12 disk is blown open and filled back.
//! Every write goes through the step's reserve seam (`reserveDenseCellWrite`) first.
//! Changes sit on the deepest levels at the level center; each iteration ends at its
//! start state. The item count encodes the case as `level side * 1000 + levels`.
//! Fixtures build once per case outside the timed loop. Terrain edits run on the
//! main thread, so only the serial case is measured.

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const WorldSystem = @import("../game/world_system.zig").WorldSystem;
const TileId = @import("../game/world_system.zig").TileId;
const invalid_tile_id = @import("../game/world_system.zig").invalid_tile_id;
const level_z_step = @import("../game/world_system.zig").level_z_step;
const default_chunk_size_tiles = @import("../game/world_system.zig").default_chunk_size_tiles;
const suite = @import("suite.zig");

const level_sides = [_]u16{ 256, 1024, 2048 };
const level_counts = [_]u16{ 8, 32, 128 };
const case_encoding: usize = 1000;

const scale_item_counts = blk: {
    var counts: [level_sides.len * level_counts.len]usize = undefined;
    for (level_sides, 0..) |side, side_index| {
        for (level_counts, 0..) |levels, level_index| {
            counts[side_index * level_counts.len + level_index] = @as(usize, side) * case_encoding + levels;
        }
    }
    break :blk counts;
};

const dig_cell_count: u16 = 64;
const cave_in_edge: u16 = 32;
const cave_in_levels: u16 = 4;
const explosion_radius: i32 = 12;

pub const dig_group = suite.BenchmarkGroup{
    .name = "chunk-scale-dig",
    .defaultItemCounts = scaleItemCounts,
    .runCase = runDigCase,
};

pub const cave_in_group = suite.BenchmarkGroup{
    .name = "chunk-scale-cave-in",
    .defaultItemCounts = scaleItemCounts,
    .runCase = runCaveInCase,
};

pub const explosion_fill_group = suite.BenchmarkGroup{
    .name = "chunk-scale-explosion-fill",
    .defaultItemCounts = scaleItemCounts,
    .runCase = runExplosionFillCase,
};

fn scaleItemCounts(_: suite.Profile) []const usize {
    return &scale_item_counts;
}

const Workload = enum { dig, cave_in, explosion_fill };

fn runDigCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .dig);
}

fn runCaveInCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .cave_in);
}

fn runExplosionFillCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .explosion_fill);
}

const Fixture = struct {
    world: WorldSystem,
    dirt: TileId,
    tunnel: TileId,
    side: u16,
    levels: u16,

    fn deinit(self: *Fixture) void {
        self.world.deinit();
        self.* = undefined;
    }

    // Floor layer of `level`; level `i` owns layer `i`.
    fn floor(self: *const Fixture, level: u16) usize {
        _ = self;
        return level;
    }
};

// A grass surface over `levels - 1` solid dirt levels, each one uniform dense band.
fn buildFixture(allocator: std.mem.Allocator, io: std.Io, side: u16, levels: u16) !Fixture {
    const asset_store = AssetStore.init(allocator, io, "assets");
    var meta = try world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    var meta_owned = true;
    defer if (meta_owned) meta.deinit();
    var world = WorldSystem{
        .allocator = allocator,
        .width = side,
        .height = side,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = default_chunk_size_tiles,
    };
    errdefer world.deinit();
    try world.buildCatalog(&meta);
    const grass = try world.requireTileByName(&meta, "grass");
    const dirt = try world.requireTileByName(&meta, "dirt");
    const tunnel = try world.requireTileByName(&meta, "cave_0");
    for (0..levels) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        const layer = try world.addDenseLayer(level, 0, .floor, if (level_index == 0) grass else dirt);
        std.debug.assert(layer == level);
    }
    world.adoptTilesetMeta(meta);
    meta_owned = false;
    return .{ .world = world, .dirt = dirt, .tunnel = tunnel, .side = side, .levels = levels };
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, workload: Workload) !suite.RunStats {
    if (case.usesThreadSystem()) return suite.RunStats.skipped("terrain edits run on the main thread");
    const side: u16 = @intCast(item_count / case_encoding);
    const levels: u16 = @intCast(item_count % case_encoding);
    std.debug.assert(levels >= cave_in_levels + 1 and side >= 256);

    var fixture = try buildFixture(allocator, io, side, levels);
    defer fixture.deinit();
    if (workload == .cave_in) _ = try applyCaveInRegion(&fixture, fixture.tunnel);

    for (0..options.warmup_iterations) |_| _ = try runIteration(&fixture, workload);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var cells_changed: usize = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        cells_changed = try runIteration(&fixture, workload);
        accumulator.record(suite.elapsedNs(start_ns, suite.nowNs(io)), suite.serialBatch(cells_changed, 1));
    }
    var stats = accumulator.finish();
    // The item count is a case code, so report throughput over the cells written.
    stats.output_count = cells_changed;
    stats.items_per_second = if (stats.mean_ns == 0) 0 else @intCast(@as(u128, cells_changed) * std.time.ns_per_s / stats.mean_ns);
    return stats;
}

// One timed change and its reversal; returns the cells written.
fn runIteration(fixture: *Fixture, workload: Workload) !usize {
    return switch (workload) {
        .dig => digAndRefill(fixture),
        .cave_in => blk: {
            const collapsed = try applyCaveInRegion(fixture, fixture.dirt);
            break :blk collapsed + try applyCaveInRegion(fixture, fixture.tunnel);
        },
        .explosion_fill => blk: {
            const opened = try applyExplosionDisk(fixture, invalid_tile_id);
            break :blk opened + try applyExplosionDisk(fixture, fixture.dirt);
        },
    };
}

fn digAndRefill(fixture: *Fixture) !usize {
    const world = &fixture.world;
    const level = fixture.levels - 1;
    const layer = fixture.floor(level);
    const chunk = default_chunk_size_tiles;
    const origin = fixture.side / 2 - 4 * chunk;
    var cell_index: u16 = 0;
    while (cell_index < dig_cell_count) : (cell_index += 1) {
        const x = origin + (cell_index % 8) * chunk + 5;
        const y = origin + (cell_index / 8) * chunk + 7;
        world.beginDenseCellWriteReserve();
        try world.reserveDenseCellWrite(layer, x, y, fixture.tunnel);
        _ = try world.setDenseTile(layer, x, y, fixture.tunnel);
        world.beginDenseCellWriteReserve();
        try world.reserveDenseCellWrite(layer, x, y, fixture.dirt);
        _ = try world.setDenseTile(layer, x, y, fixture.dirt);
    }
    return @as(usize, dig_cell_count) * 2;
}

// Writes `tile` over the cave-in region on the four deepest levels in one step.
fn applyCaveInRegion(fixture: *Fixture, tile: TileId) !usize {
    const world = &fixture.world;
    const origin = fixture.side / 2 - cave_in_edge / 2 + 3;
    world.beginDenseCellWriteReserve();
    for (0..cave_in_levels) |depth| {
        const layer = fixture.floor(fixture.levels - 1 - @as(u16, @intCast(depth)));
        for (0..cave_in_edge) |dy| for (0..cave_in_edge) |dx| {
            try world.reserveDenseCellWrite(layer, origin + @as(u16, @intCast(dx)), origin + @as(u16, @intCast(dy)), tile);
        };
    }
    for (0..cave_in_levels) |depth| {
        const layer = fixture.floor(fixture.levels - 1 - @as(u16, @intCast(depth)));
        for (0..cave_in_edge) |dy| for (0..cave_in_edge) |dx| {
            _ = try world.setDenseTile(layer, origin + @as(u16, @intCast(dx)), origin + @as(u16, @intCast(dy)), tile);
        };
    }
    return @as(usize, cave_in_levels) * cave_in_edge * cave_in_edge;
}

// Writes `tile` (an empty hole or the refill) over the disk on the deepest level in one step.
fn applyExplosionDisk(fixture: *Fixture, tile: TileId) !usize {
    const world = &fixture.world;
    const layer = fixture.floor(fixture.levels - 1);
    const center: i32 = fixture.side / 2 + 5;
    var written: usize = 0;
    world.beginDenseCellWriteReserve();
    for (0..2) |pass| {
        var dy: i32 = -explosion_radius;
        while (dy <= explosion_radius) : (dy += 1) {
            var dx: i32 = -explosion_radius;
            while (dx <= explosion_radius) : (dx += 1) {
                if (dx * dx + dy * dy > explosion_radius * explosion_radius) continue;
                const x: u16 = @intCast(center + dx);
                const y: u16 = @intCast(center + dy);
                if (pass == 0) {
                    try world.reserveDenseCellWrite(layer, x, y, tile);
                } else {
                    if (tile == invalid_tile_id) {
                        _ = try world.clearDenseTile(layer, x, y);
                    } else {
                        _ = try world.setDenseTile(layer, x, y, tile);
                    }
                    written += 1;
                }
            }
        }
    }
    return written;
}
