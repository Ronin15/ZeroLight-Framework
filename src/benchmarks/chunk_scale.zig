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
//!   - `chunk-scale-gpu-sync-dig`: the dig workload with a GPU tile sync after the
//!     digs and after the refills (64 blocks taken, then freed). Flat.
//!   - `chunk-scale-gpu-sync-level-enter`: the render window steps one level down
//!     and back, each step one level entering (its directory and 64 mixed blocks)
//!     and one leaving. Linear in chunks per level, flat across depth.
//! Every write goes through the step's reserve seam (`reserveDenseCellWrite`) first.
//! Changes sit on the deepest levels at the level center; each iteration ends at its
//! start state. The item count encodes the case as `level side * 1000 + levels`.
//! Fixtures build once per case outside the timed loop. Terrain edits and GPU
//! syncs run on the main thread, so only the serial case is measured. The GPU
//! sync groups drive `syncDenseTileStore` against a headless renderer whose tile
//! store has no GPU buffer: they time planning, commit, and the queued upload
//! batch, which the bench drops after each sync as a frame copy pass would.

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const WorldSystem = @import("../game/world_system.zig").WorldSystem;
const TileId = @import("../game/world_system.zig").TileId;
const invalid_tile_id = @import("../game/world_system.zig").invalid_tile_id;
const level_z_step = @import("../game/world_system.zig").level_z_step;
const default_chunk_size_tiles = @import("../game/world_system.zig").default_chunk_size_tiles;
const Renderer = @import("../render/renderer.zig").Renderer;
const TilemapParams = @import("../render/renderer.zig").TilemapParams;
const tile_store_max_elements = @import("../render/renderer.zig").tile_store_max_elements;
const SpriteBatch = @import("../render/sprite_batch.zig").SpriteBatch;
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
// The GPU sync groups render a two-level window: `active_level` and the one below.
const gpu_window_levels_below: u16 = 1;

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

pub const gpu_sync_dig_group = suite.BenchmarkGroup{
    .name = "chunk-scale-gpu-sync-dig",
    .defaultItemCounts = scaleItemCounts,
    .runCase = runGpuSyncDigCase,
};

pub const gpu_sync_level_enter_group = suite.BenchmarkGroup{
    .name = "chunk-scale-gpu-sync-level-enter",
    .defaultItemCounts = scaleItemCounts,
    .runCase = runGpuSyncLevelEnterCase,
};

fn scaleItemCounts(_: suite.Profile) []const usize {
    return &scale_item_counts;
}

const Workload = enum { dig, cave_in, explosion_fill, gpu_sync_dig, gpu_sync_level_enter };

fn runDigCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .dig);
}

fn runCaveInCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .cave_in);
}

fn runExplosionFillCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .explosion_fill);
}

fn runGpuSyncDigCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .gpu_sync_dig);
}

fn runGpuSyncLevelEnterCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .gpu_sync_level_enter);
}

const Fixture = struct {
    world: WorldSystem,
    dirt: TileId,
    tunnel: TileId,
    side: u16,
    levels: u16,
    // GPU sync groups only: a headless renderer holding the world's tile store.
    renderer: ?Renderer = null,

    fn deinit(self: *Fixture) void {
        if (self.renderer) |*renderer| {
            for (renderer.tile_stores.items) |*store| {
                store.pending_spans.deinit(renderer.allocator);
                store.pending_values.deinit(renderer.allocator);
            }
            renderer.tile_stores.deinit(renderer.allocator);
            renderer.tile_merge_spans.deinit(renderer.allocator);
            renderer.tile_merge_values.deinit(renderer.allocator);
            renderer.batch.deinit();
        }
        self.world.deinit();
        self.* = undefined;
    }

    // Gives the world a tile store with no GPU buffer, large enough that no sync
    // grows it (growth would create a GPU buffer).
    fn attachHeadlessTileStore(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.renderer = Renderer{
            .allocator = allocator,
            .device = undefined,
            .window = undefined,
            .pipeline = undefined,
            .tilemap_pipeline = undefined,
            .sampler = undefined,
            .vertex_streams = undefined,
            .batch_capacity_vertices = 0,
            .batch = SpriteBatch.init(allocator),
        };
        const renderer = &self.renderer.?;
        try renderer.tile_stores.append(allocator, .{
            // Never dereferenced: syncs only validate and queue.
            .buffer = @ptrFromInt(0x1000),
            .element_capacity = tile_store_max_elements,
            .directory_elements = 0,
            .block_elements = 1,
            .params = std.mem.zeroes(TilemapParams),
        });
        self.world.gpu_tiles.store = @fromBackingInt(0);
        self.world.render_window = .{ .levels_below = gpu_window_levels_below };
    }

    // One GPU tile sync; returns the elements it uploads and drops the batch.
    fn syncGpuTiles(self: *Fixture, active_level: u16) !usize {
        const renderer = &self.renderer.?;
        try self.world.syncDenseTileStore(renderer, active_level);
        const store = &renderer.tile_stores.items[0];
        const uploaded = store.pending_values.items.len;
        store.pending_spans.clearRetainingCapacity();
        store.pending_values.clearRetainingCapacity();
        return uploaded;
    }

    // The window's top level for the GPU sync groups: the deepest level is resident.
    fn gpuActiveLevel(self: *const Fixture) u16 {
        return self.levels - 1 - gpu_window_levels_below;
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
    switch (workload) {
        .cave_in => _ = try applyCaveInRegion(&fixture, fixture.tunnel),
        .gpu_sync_dig => {
            try fixture.attachHeadlessTileStore(allocator);
            _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel());
        },
        .gpu_sync_level_enter => {
            try fixture.attachHeadlessTileStore(allocator);
            // 64 mixed chunks on each level the window crosses.
            for (fixture.gpuActiveLevel() - 1..fixture.levels) |level| _ = try digCells(&fixture, @intCast(level), fixture.tunnel);
            _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel() - 1);
        },
        .dig, .explosion_fill => {},
    }

    for (0..options.warmup_iterations) |_| _ = try runIteration(&fixture, workload);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var cells_changed: usize = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        cells_changed = try runIteration(&fixture, workload);
        accumulator.record(suite.elapsedNs(start_ns, suite.nowNs(io)), suite.serialBatch(cells_changed, 1));
    }
    var stats = accumulator.finish();
    // The item count is a case code, so report throughput over the cells written
    // (elements uploaded for the GPU sync groups).
    stats.output_count = cells_changed;
    stats.items_per_second = if (stats.mean_ns == 0) 0 else @intCast(@as(u128, cells_changed) * std.time.ns_per_s / stats.mean_ns);
    return stats;
}

// One timed change and its reversal; returns the cells written, or the elements
// uploaded for the GPU sync groups.
fn runIteration(fixture: *Fixture, workload: Workload) !usize {
    return switch (workload) {
        .dig => digAndRefill(fixture),
        .gpu_sync_dig => blk: {
            const level = fixture.levels - 1;
            _ = try digCells(fixture, level, fixture.tunnel);
            const split = try fixture.syncGpuTiles(fixture.gpuActiveLevel());
            _ = try digCells(fixture, level, fixture.dirt);
            break :blk split + try fixture.syncGpuTiles(fixture.gpuActiveLevel());
        },
        .gpu_sync_level_enter => blk: {
            const entered = try fixture.syncGpuTiles(fixture.gpuActiveLevel());
            break :blk entered + try fixture.syncGpuTiles(fixture.gpuActiveLevel() - 1);
        },
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

// Writes `tile` into the dig workload's 64 cells on `level`, one per chunk, in one step.
fn digCells(fixture: *Fixture, level: u16, tile: TileId) !usize {
    const world = &fixture.world;
    const layer = fixture.floor(level);
    const chunk = default_chunk_size_tiles;
    const origin = fixture.side / 2 - 4 * chunk;
    world.beginDenseCellWriteReserve();
    for (0..2) |pass| {
        var cell_index: u16 = 0;
        while (cell_index < dig_cell_count) : (cell_index += 1) {
            const x = origin + (cell_index % 8) * chunk + 5;
            const y = origin + (cell_index / 8) * chunk + 7;
            if (pass == 0) {
                try world.reserveDenseCellWrite(layer, x, y, tile);
            } else {
                _ = try world.setDenseTile(layer, x, y, tile);
            }
        }
    }
    return dig_cell_count;
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
