// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared private test fixtures for `WorldSystem` callers across modules. Test-only:
//! no production path imports it. Single-module helpers stay in their module.

const std = @import("std");
const AssetStore = @import("../../assets/assets.zig").AssetStore;
const manifest = @import("../../assets/manifest.zig");
const world_tileset_meta = @import("../../assets/world_tileset_meta.zig");
const WorldTilesetMeta = @import("../../assets/world_tileset_meta.zig").WorldTilesetMeta;
const WorldSystem = @import("system.zig").WorldSystem;
const TileId = @import("system.zig").TileId;
const WorldBuildConfig = @import("system.zig").WorldBuildConfig;
const DenseCellWrite = @import("edit.zig").DenseCellWrite;
const DenseChunkWrites = @import("edit.zig").DenseChunkWrites;
const cellCoordOf = @import("edit.zig").cellCoordOf;
const CellCoord = @import("system.zig").CellCoord;
const WorldTileChangedEvent = @import("../simulation.zig").WorldTileChangedEvent;
const default_chunk_size_tiles = @import("system.zig").default_chunk_size_tiles;
const invalid_tile_id = @import("system.zig").invalid_tile_id;
const max_chunk_size_tiles = @import("system.zig").max_chunk_size_tiles;
const world_render = @import("render.zig");
const world_gpu_tiles = @import("gpu_tiles.zig");
const ChunkGeometry = @import("terrain.zig").ChunkGeometry;
const ChunkWindow = @import("gpu_tiles.zig").ChunkWindow;
const TileStoreSpan = @import("../../render/renderer.zig").TileStoreSpan;
const tile_store_no_link = @import("../../render/renderer.zig").tile_store_no_link;
const tile_store_uniform_bit = @import("../../render/renderer.zig").tile_store_uniform_bit;

/// CPU copy of a GPU tile store: applies upload batches as the frame copy pass does
/// and reads tiles back the way `tilemap.frag.glsl` does, so tests assert what a
/// draw would show rather than the mirror's bookkeeping.
pub const TestGpuStore = struct {
    words: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *TestGpuStore) void {
        self.words.deinit(std.testing.allocator);
    }

    pub fn apply(self: *TestGpuStore, spans: []const TileStoreSpan, values: []const u32) !void {
        var value_index: usize = 0;
        for (spans) |span| {
            const end: usize = @intCast(span.end());
            if (self.words.items.len < end) try self.words.appendNTimes(std.testing.allocator, 0xDEAD_BEEF, end - self.words.items.len);
            @memcpy(self.words.items[span.dst_element..end], values[value_index..][0..span.count]);
            value_index += span.count;
        }
        try std.testing.expectEqual(values.len, value_index);
    }

    /// The tile at cell (x, y) of the layer whose directory starts at `directory`,
    /// or null when the cell's chunk is outside `window` (the shader discards it).
    pub fn tileAt(self: *const TestGpuStore, geom: ChunkGeometry, side: u32, window: ChunkWindow, directory: u32, x: u16, y: u16) ?TileId {
        const chunk_x = @as(u32, x) >> geom.shift;
        const chunk_y = @as(u32, y) >> geom.shift;
        if (!window.contains(chunk_x, chunk_y)) return null;
        const word = self.words.items[directory + (chunk_y & (side - 1)) * side + (chunk_x & (side - 1))];
        if (word & tile_store_uniform_bit != 0) return @truncate(word);
        const local = geom.localOf(x, y);
        const element = self.words.items[word + local / 2];
        return @truncate(element >> @intCast((local & 1) * 16));
    }

    /// The shader's chain walk: the first tile other than `empty` over `count`
    /// layers from `first_directory`, following link words; `empty` when every
    /// layer is empty, null when the chunk is outside `window`.
    pub fn composite(self: *const TestGpuStore, geom: ChunkGeometry, side: u32, window: ChunkWindow, first_directory: u32, count: usize, empty: TileId, x: u16, y: u16) ?TileId {
        var directory = first_directory;
        for (0..count) |index| {
            const found = self.tileAt(geom, side, window, directory, x, y) orelse return null;
            if (found != empty) return found;
            if (index + 1 < count) {
                directory = self.words.items[directory + side * side];
                std.debug.assert(directory != tile_store_no_link);
            }
        }
        return empty;
    }
};

/// Whether dense `layer`'s tile at (x, y) blocks movement on its own (out-of-range cells
/// and layers block), apart from the level's composed bits.
pub fn denseTileBlocksMovement(world: *const WorldSystem, layer: usize, x: u16, y: u16) bool {
    if (layer >= world.dense_layers.len or x >= world.width or y >= world.height) return true;
    const tile: usize = world.denseTile(layer, x, y);
    const flags = world.catalog_flags.items;
    return tile < flags.len and flags[tile].blocks_movement;
}

/// Runs a landing carve into `cell` on `level` through the batched dense edit and undoes
/// it, so a later carve batch in that chunk reuses the batch scratch, tile block, and
/// composed-bits slot: the terrain is warm, like the frame and data allocators the
/// zero-allocation proofs warm.
pub fn warmLandingTerrain(world: *WorldSystem, tunnel_tile: TileId, level: u16, cell: [2]u16) !void {
    const floor = world.denseFloorLayerForLevel(level).?;
    const original = world.denseTile(floor, cell[0], cell[1]);
    var buffer: [1]WorldTileChangedEvent = undefined;
    var events = std.ArrayList(WorldTileChangedEvent).initBuffer(&buffer);
    for ([_]TileId{ tunnel_tile, original }) |tile| {
        events.clearRetainingCapacity();
        const writes = [_]DenseCellWrite{.{ .layer = @intCast(floor), .x = cell[0], .y = cell[1], .tile = tile }};
        const chunks = [_]DenseChunkWrites{.{
            .level = level,
            .chunk_x = cell[0] / world.chunk_size_tiles,
            .chunk_y = cell[1] / world.chunk_size_tiles,
            .writes = &writes,
        }};
        try world.applyDenseCellWrites(&chunks, null, &events);
    }
}

pub fn testWorldMeta() !WorldTilesetMeta {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    return try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
}

/// Minimal grass-filled surface world (one dense floor layer, one chunk when
/// `max(width,height) <= max_chunk_size_tiles`). Prefer this over `initDemoFromMeta`
/// in unit tests that only need levels/dense layers, not demo terrain paint.
pub fn testMinimalSurfaceWorld(meta: *const WorldTilesetMeta, width: u16, height: u16) !WorldSystem {
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = width,
        .height = height,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = max_chunk_size_tiles,
    };
    errdefer world.deinit();
    try world.buildCatalog(meta);
    const level = try world.addLevel(0);
    const grass = try world.requireTileByName(meta, "grass");
    _ = try world.addDenseLayer(level, 0, .floor, grass);
    return world;
}

/// Runs one GPU tile sync without a renderer; the upload batch stays in
/// `world.gpu_tiles.spans`/`values`. A world with no render window set renders its
/// whole extent.
pub fn testSyncGpuTiles(world: *WorldSystem, active_level: u16) !world_gpu_tiles.SyncPlan {
    if (world.visible == null) try testShowWholeWorld(world, active_level);
    const sync_plan = try world_render.planDenseGpuSync(world, active_level);
    world_render.commitDenseGpuSync(world, &sync_plan, active_level, null, null);
    return sync_plan;
}

pub fn testShowWholeWorld(world: *WorldSystem, active_level: u16) !void {
    try world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = world.worldWidthPixels(), .h = world.worldHeightPixels() }, 0, active_level);
}

/// Applies the last sync's upload batch to `gpu`.
pub fn testApplySync(world: *const WorldSystem, gpu: *TestGpuStore) !void {
    try gpu.apply(world.gpu_tiles.spans.items, world.gpu_tiles.values.items);
}

/// The tile `gpu` shows for resident `layer` at (x, y), or null outside the window.
pub fn testGpuTile(world: *const WorldSystem, gpu: *const TestGpuStore, layer: usize, x: u16, y: u16) ?TileId {
    const mirror = &world.gpu_tiles;
    const slot = world.dense_layers.items(.gpu_slot)[layer];
    std.debug.assert(slot != world_gpu_tiles.no_slot);
    return gpu.tileAt(world.chunkGeometry(), mirror.side, mirror.window, mirror.slotDirectory(slot), x, y);
}

/// Every resident layer reads back its CPU tiles over the window and nothing
/// outside it, and the chain from the topmost resident layer composites them in
/// depth order.
pub fn expectGpuStoreMatches(world: *const WorldSystem, gpu: *const TestGpuStore) !void {
    const mirror = &world.gpu_tiles;
    const layers = world.dense_render.layers.items;
    try std.testing.expectEqual(mirror.residentLayerCount(), layers.len);
    for (world.dense_layers.items(.gpu_slot), 0..) |slot, layer| {
        if (slot == world_gpu_tiles.no_slot) continue;
        for (0..world.height) |y| for (0..world.width) |x| {
            const gpu_tile = testGpuTile(world, gpu, layer, @intCast(x), @intCast(y));
            const chunk_x = @as(u32, @intCast(x)) >> world.chunkGeometry().shift;
            const chunk_y = @as(u32, @intCast(y)) >> world.chunkGeometry().shift;
            if (mirror.window.contains(chunk_x, chunk_y)) {
                try std.testing.expectEqual(@as(?TileId, world.denseTile(layer, @intCast(x), @intCast(y))), gpu_tile);
            } else {
                try std.testing.expectEqual(@as(?TileId, null), gpu_tile);
            }
        };
    }
    if (layers.len == 0) return;
    const top_slot = world.dense_layers.items(.gpu_slot)[layers[layers.len - 1]];
    for (0..world.height) |y| for (0..world.width) |x| {
        const shown = gpu.composite(world.chunkGeometry(), mirror.side, mirror.window, mirror.slotDirectory(top_slot), layers.len, invalid_tile_id, @intCast(x), @intCast(y)) orelse continue;
        var expected: TileId = invalid_tile_id;
        var index = layers.len;
        while (index > 0) {
            index -= 1;
            expected = world.denseTile(layers[index], @intCast(x), @intCast(y));
            if (expected != invalid_tile_id) break;
        }
        try std.testing.expectEqual(expected, shown);
    };
}

/// Tile-cell coordinate of the sparse row at (`level`, `chunk`, `offset`).
/// Valid until that row is removed.
pub fn sparseTileCellCoord(world: *const WorldSystem, level: u16, chunk: u32, offset: usize) CellCoord {
    const cell = world.level_terrain.items[level].sparse_runs[chunk].rows.items(.cell_index)[offset];
    return cellCoordOf(world, cell);
}

/// Blocks holding cells in a `DenseLayerStore` (or a pointer to one): its pool less
/// released blocks.
pub fn liveBlockCount(store: anytype) usize {
    return store.fills.items.len - store.free.items.len;
}

/// Slots holding bits in a `ChunkBitsStore` (or a pointer to one).
pub fn liveSlotCount(bits: anytype) usize {
    return bits.bits.items.len - bits.free.items.len;
}

/// Blocked cells of `chunk` in a `ChunkBitsStore` (or a pointer to one): 0 open, every
/// cell blocked, else its block's count.
pub fn chunkBlockedCount(bits: anytype, geom: ChunkGeometry, chunk: u32) u32 {
    return switch (bits.form(chunk)) {
        .open => 0,
        .blocked => geom.extent(chunk).cellCount(),
        .mixed => bits.counts.items[bits.dir[chunk]],
    };
}

/// The sum of the runs' lengths is `sparse_live`, a run holds bytes exactly when
/// it has a live row, and each live row's level and chunk are the run's.
pub fn expectSparseIndexConsistent(world: *const WorldSystem) !void {
    const geom = world.chunkGeometry();
    var live: u32 = 0;
    for (world.level_terrain.items, 0..) |terrain, level| {
        const level_index: u16 = @intCast(level);
        for (terrain.sparse_runs, 0..) |run, chunk| {
            if (run.rows.len == 0) {
                try std.testing.expectEqual(@as(usize, 0), run.rows.capacity);
                continue;
            }
            const rows = run.rows.slice();
            const levels = rows.items(.level_index);
            const chunk_index: u32 = @intCast(chunk);
            for (levels, 0..) |row_level, offset| {
                try std.testing.expectEqual(level_index, row_level);
                const coord = sparseTileCellCoord(world, level_index, chunk_index, offset);
                try std.testing.expectEqual(chunk_index, geom.chunkOf(coord.x, coord.y));
                live += 1;
            }
        }
    }
    try std.testing.expectEqual(live, world.sparse_live);
}

/// Brute-force composed blocked bit: OR over every dense layer on the level, then
/// every sparse tile on the level at this cell.
pub fn bruteForceLevelBlocked(world: *const WorldSystem, level: u16, x: u16, y: u16) bool {
    for (0..world.dense_layers.len) |layer| {
        if (world.denseLayerLevel(layer) != level) continue;
        if (world.flagsFor(world.denseTile(layer, x, y)).blocks_movement) return true;
    }
    const target = world.cellIndex(x, y);
    for (world.level_terrain.items[level].sparse_runs) |run| {
        if (run.rows.len == 0) continue;
        const rows = run.rows.slice();
        const sparse_cells = rows.items(.cell_index);
        const sparse_flags = rows.items(.flags);
        for (sparse_cells, sparse_flags) |row_cell, row_flags| {
            if (row_cell == target and row_flags.blocks_movement) return true;
        }
    }
    return false;
}

/// World-tileset tiles the terrain tests write, resolved by name from the catalog.
pub const TerrainTestTiles = struct {
    grass: TileId,
    dirt: TileId,
    water: TileId,
    cave: TileId,
    tree: TileId,
    deco: TileId,

    pub fn resolve(world: *const WorldSystem, meta: *const WorldTilesetMeta) !TerrainTestTiles {
        return .{
            .grass = try world.requireTileByName(meta, "grass"),
            .dirt = try world.requireTileByName(meta, "dirt"),
            .water = try world.requireTileByName(meta, "water_1"),
            .cave = try world.requireTileByName(meta, "cave_0"),
            .tree = try world.requireTileByName(meta, "tree_0"),
            .deco = try world.requireTileByName(meta, "deco_0"),
        };
    }
};

/// A procedural surface within the test size bound: 16x16 tiles in 4x4 chunks, with no
/// underground level.
pub const procedural_test_config = WorldBuildConfig{
    .width_tiles = 16,
    .height_tiles = 16,
    .chunk_size_tiles = 4,
    .underground_level_count = 0,
};

test "the demo world paints the same tiles at every chunk edge" {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    const bounds = meta.tileSize() * 24 + 5;
    var fixture = try WorldSystem.initDemoFromMetaWithChunkSize(std.testing.allocator, &meta, bounds, bounds, 4);
    defer fixture.deinit();
    try std.testing.expect(fixture.chunk_size_tiles != default_chunk_size_tiles);
    var demo = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, bounds, bounds);
    defer demo.deinit();

    try std.testing.expectEqual(demo.width, fixture.width);
    try std.testing.expectEqual(demo.height, fixture.height);
    try std.testing.expectEqual(demo.levelCount(), fixture.levelCount());
    try std.testing.expectEqual(demo.dense_layers.len, fixture.dense_layers.len);
    for (0..demo.dense_layers.len) |layer| {
        for (0..demo.height) |y| for (0..demo.width) |x| {
            try std.testing.expectEqual(demo.denseTile(layer, @intCast(x), @intCast(y)), fixture.denseTile(layer, @intCast(x), @intCast(y)));
        };
    }
    try std.testing.expectEqual(demo.sparse_live, fixture.sparse_live);
    const demo_rows = try std.testing.allocator.alloc(SparseProbe, demo.sparse_live);
    defer std.testing.allocator.free(demo_rows);
    const fixture_rows = try std.testing.allocator.alloc(SparseProbe, fixture.sparse_live);
    defer std.testing.allocator.free(fixture_rows);
    liveSparseProbes(&demo, demo_rows);
    liveSparseProbes(&fixture, fixture_rows);
    for (demo_rows, fixture_rows) |demo_row, fixture_row| {
        try std.testing.expectEqual(demo_row.cell, fixture_row.cell);
        try std.testing.expectEqual(demo_row.blocks, fixture_row.blocks);
    }
}

const SparseProbe = struct { cell: CellCoord, blocks: bool };

fn liveSparseProbes(world: *const WorldSystem, out: []SparseProbe) void {
    var count: usize = 0;
    for (world.level_terrain.items) |terrain| {
        for (terrain.sparse_runs) |run| {
            if (run.rows.len == 0) continue;
            const rows = run.rows.slice();
            const cells = rows.items(.cell_index);
            const flags = rows.items(.flags);
            for (cells, flags) |cell, flag| {
                out[count] = .{ .cell = cellCoordOf(world, cell), .blocks = flag.blocks_movement };
                count += 1;
            }
        }
    }
    std.debug.assert(count == out.len);
}
