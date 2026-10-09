// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Sparse-tile render prep against the camera window as the world's sparse tile
//! count grows. A 2048x2048 world of 8 levels holds exactly 256 sparse tiles inside
//! a fixed 1280x720 camera window on the active level, over four depths; every other
//! tile sits outside the window's chunks on all levels. The window's work is the
//! same at every size, so each group is expected flat in the world's sparse count:
//!   - `render-sparse-window-frame`: one frame's window update (unchanged, so
//!     O(1)), depth range walk, and sparse submit into a headless `SpriteBatch`.
//!   - `render-sparse-window-pan`: the window pans one chunk across, a frame, back,
//!     a frame; each pan rebuilds the window's sparse list.
//!   - `render-sparse-window-add`: one sparse tile added outside the window, then a
//!     frame. Tiles are append-only in play, so each iteration's reset (untimed)
//!     drops the added tile.
//! The item count is the world's sparse tile count. Fixtures build once per case
//! outside the timed loop. Sparse prep is main-thread work, so the groups measure
//! the serial case only.

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const WorldDepth = @import("../game/render_depth.zig").WorldDepth;
const WorldSystem = @import("../game/world_system.zig").WorldSystem;
const TileId = @import("../game/world_system.zig").TileId;
const level_z_step = @import("../game/world_system.zig").level_z_step;
const default_chunk_size_tiles = @import("../game/world_system.zig").default_chunk_size_tiles;
const Rect = @import("../render/renderer.zig").Rect;
const TextureId = @import("../render/resources.zig").TextureId;
const SpriteBatch = @import("../render/sprite_batch.zig").SpriteBatch;
const suite = @import("suite.zig");

const world_side: u16 = 2048;
const world_levels: u16 = 8;
const active_level: u16 = 0;
const overscan_chunks: u16 = 1;
const viewport_w: f32 = 1280;
const viewport_h: f32 = 720;
// Camera top-left, in tiles: chunk-aligned and clear of the world edge, so the
// one-chunk pan is never clamped.
const camera_tile_x: u16 = 256;
const camera_tile_y: u16 = 256;

// The window's tiles: a 16x16 block inside the camera's tile bounds, at least one
// chunk from its left and right edges so a one-chunk pan keeps all of them in view.
const window_block_edge: u16 = 16;
const window_tile_count: usize = @as(usize, window_block_edge) * window_block_edge;
const window_block_x: u16 = camera_tile_x + 20;
const window_block_y: u16 = camera_tile_y + 3;
const window_depths = [_]WorldDepth{ .floor, .obstacle, .effect, .marker };

// Tiles outside the window fill rows from here down, far below the window's chunks
// after any pan and overscan.
const outside_first_row: u16 = 512;
const outside_columns: usize = 256;
const outside_column_stride: u16 = world_side / outside_columns;

// The add group's tile: outside the window, on a level inside the render window.
const added_tile_level: u16 = 3;
const added_tile_x: u16 = 1000;
const added_tile_y: u16 = 1500;

const sparse_tile_counts = [_]usize{ 1_000, 16_000, 256_000 };

pub const frame_group = suite.BenchmarkGroup{
    .name = "render-sparse-window-frame",
    .defaultItemCounts = sparseTileCounts,
    .runCase = runFrameCase,
};

pub const pan_group = suite.BenchmarkGroup{
    .name = "render-sparse-window-pan",
    .defaultItemCounts = sparseTileCounts,
    .runCase = runPanCase,
};

pub const add_group = suite.BenchmarkGroup{
    .name = "render-sparse-window-add",
    .defaultItemCounts = sparseTileCounts,
    .runCase = runAddCase,
};

fn sparseTileCounts(_: suite.Profile) []const usize {
    return &sparse_tile_counts;
}

const Workload = enum { frame, pan, add };

fn runFrameCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .frame);
}

fn runPanCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .pan);
}

fn runAddCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .add);
}

const Fixture = struct {
    world: WorldSystem,
    batch: SpriteBatch,
    texture: TextureId,
    window_tile: TileId,
    // Non-blocking, so adding and dropping it leaves the level's blocked bits alone.
    added_tile: TileId,
    sparse_count: usize,

    fn deinit(self: *Fixture) void {
        self.batch.deinit();
        self.world.deinit();
        self.* = undefined;
    }

    fn cameraRect(self: *const Fixture, step_chunks: i32) Rect {
        const tile_size = self.world.tile_size;
        const chunk_px = @as(f32, @floatFromInt(default_chunk_size_tiles)) * tile_size;
        return .{
            .x = @as(f32, @floatFromInt(camera_tile_x)) * tile_size + @as(f32, @floatFromInt(step_chunks)) * chunk_px,
            .y = @as(f32, @floatFromInt(camera_tile_y)) * tile_size,
            .w = viewport_w,
            .h = viewport_h,
        };
    }

    // One frame's sparse prep for the camera `step_chunks` right of its start:
    // window update, depth range walk, and submit. Returns the sprites submitted.
    fn frame(self: *Fixture, step_chunks: i32) !usize {
        const world = &self.world;
        self.batch.beginFrame();
        try world.setVisibleChunksForWorldRect(self.cameraRect(step_chunks), overscan_chunks, active_level);
        if (world.reserveRenderRecords() != window_tile_count) return error.WindowSparseCountMismatch;
        var submitted: usize = 0;
        for (0..world.sparseDepthRangeCount()) |range_index| {
            submitted += try world.submitVisibleSparseSprites(&self.batch, self.texture, range_index);
        }
        if (submitted != window_tile_count) return error.WindowSparseSubmitMismatch;
        return submitted;
    }

    fn addOutsideTile(self: *Fixture) !void {
        // An obstacle event would mean the tile set blocked bits the drop does not clear.
        const event = try self.world.addSparseTile(added_tile_level, added_tile_x, added_tile_y, self.added_tile, 0, .marker);
        if (event != null) return error.AddedTileBlocksMovement;
    }

    // Drops the tile `addOutsideTile` appended, returning the world to `sparse_count`
    // tiles: truncates `sparse_tiles` and the tile's level and chunk index lists. It
    // invalidates nothing, as the add outside the window invalidated nothing.
    fn dropAddedTile(self: *Fixture) !void {
        const world = &self.world;
        if (world.sparseTileCount() != self.sparse_count + 1) return error.AddedTileCountMismatch;
        const added_index: u32 = @intCast(self.sparse_count);
        const chunk = world.chunkCoordForCell(added_tile_x, added_tile_y);
        const chunk_index: usize = @intCast(chunk.y * @as(i32, world.chunksX()) + chunk.x);
        if (world.sparse_level_tiles.items[added_tile_level].pop() != added_index) return error.AddedTileIndexMismatch;
        if (world.sparse_level_chunk_tiles.items[added_tile_level].items[chunk_index].pop() != added_index) return error.AddedTileIndexMismatch;
        world.sparse_tiles.shrinkRetainingCapacity(self.sparse_count);
        if (world.sparse_window.dirty) return error.OutsideAddDirtiedWindow;
    }
};

// The world adopts the tileset metadata, so its lookups read the owned copy and
// never the local `buildCatalog` borrowed.
fn initFixture(fixture: *Fixture, allocator: std.mem.Allocator, io: std.Io, sparse_count: usize) !void {
    std.debug.assert(sparse_count >= window_tile_count);
    const asset_store = AssetStore.init(allocator, io, "assets");
    var meta = try world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    var meta_owned = true;
    defer if (meta_owned) meta.deinit();
    fixture.* = .{
        .world = .{
            .allocator = allocator,
            .width = world_side,
            .height = world_side,
            .tile_size = meta.tileSize(),
            .chunk_size_tiles = default_chunk_size_tiles,
        },
        .batch = SpriteBatch.init(allocator),
        .texture = TextureId.init(1, 1) catch unreachable,
        .window_tile = undefined,
        .added_tile = undefined,
        .sparse_count = sparse_count,
    };
    errdefer fixture.batch.deinit();
    errdefer fixture.world.deinit();
    const world = &fixture.world;
    try world.buildCatalog(&meta);
    fixture.window_tile = try world.requireTileByName(&meta, "deco_0");
    fixture.added_tile = try world.requireTileByName(&meta, "grass_patchy");
    for (0..world_levels) |level_index| {
        _ = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
    }
    world.adoptTilesetMeta(meta);
    meta_owned = false;

    for (0..window_tile_count) |index| {
        const x = window_block_x + @as(u16, @intCast(index % window_block_edge));
        const y = window_block_y + @as(u16, @intCast(index / window_block_edge));
        _ = try world.addSparseTile(active_level, x, y, fixture.window_tile, 0, window_depths[index % window_depths.len]);
    }

    // The rest spread over every level's outside rows, row-major on a fixed column
    // stride, with the row stride spreading each level's share over the rows.
    const outside_count = sparse_count - window_tile_count;
    const per_level = (outside_count + world_levels - 1) / world_levels;
    const outside_rows = @max(1, (per_level + outside_columns - 1) / outside_columns);
    const row_stride: usize = (world_side - outside_first_row) / outside_rows;
    std.debug.assert(row_stride >= 1);
    for (0..outside_count) |index| {
        const level: u16 = @intCast(index % world_levels);
        const slot = index / world_levels;
        const x: u16 = @intCast((slot % outside_columns) * outside_column_stride + level);
        const y: u16 = @intCast(outside_first_row + (slot / outside_columns) * row_stride);
        std.debug.assert(y < world_side);
        _ = try world.addSparseTile(level, x, y, fixture.window_tile, 0, window_depths[index % window_depths.len]);
    }
    std.debug.assert(world.sparseTileCount() == sparse_count);

    try fixture.batch.reserveStorage(window_tile_count, window_tile_count * 6, window_tile_count);
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, workload: Workload) !suite.RunStats {
    if (case.usesThreadSystem()) return suite.RunStats.skipped("sparse window prep runs on the main thread");
    var fixture: Fixture = undefined;
    try initFixture(&fixture, allocator, io, item_count);
    defer fixture.deinit();
    // The first frame builds the window's sparse list.
    _ = try fixture.frame(0);

    for (0..options.warmup_iterations) |_| {
        _ = try runIteration(&fixture, workload);
        if (workload == .add) try fixture.dropAddedTile();
    }
    var accumulator = suite.StatsAccumulator.init(item_count);
    var submitted: usize = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        submitted = try runIteration(&fixture, workload);
        accumulator.record(suite.elapsedNs(start_ns, suite.nowNs(io)), suite.serialBatch(submitted, 1));
        if (workload == .add) try fixture.dropAddedTile();
    }
    var stats = accumulator.finish();
    // The item count is the world's sparse tile count, so report throughput over the
    // sprites submitted.
    stats.output_count = submitted;
    stats.items_per_second = if (stats.mean_ns == 0) 0 else @intCast(@as(u128, submitted) * std.time.ns_per_s / stats.mean_ns);
    return stats;
}

// One timed workload; returns the sprites submitted.
fn runIteration(fixture: *Fixture, workload: Workload) !usize {
    return switch (workload) {
        .frame => fixture.frame(0),
        .pan => (try fixture.frame(1)) + try fixture.frame(0),
        .add => blk: {
            try fixture.addOutsideTile();
            break :blk fixture.frame(0);
        },
    };
}
