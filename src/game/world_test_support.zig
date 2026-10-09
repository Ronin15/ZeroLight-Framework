// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared private test fixtures for `WorldSystem` callers across modules. Test-only:
//! no production path imports it. Single-module helpers stay in their module.

const std = @import("std");
const WorldTilesetMeta = @import("../assets/world_tileset_meta.zig").WorldTilesetMeta;
const AssetStore = @import("../assets/assets.zig").AssetStore;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const WorldSystem = @import("world_system.zig").WorldSystem;
const TileId = @import("world_system.zig").TileId;
const default_chunk_size_tiles = @import("world_system.zig").default_chunk_size_tiles;

/// The demo surface `WorldSystem.initDemoFromMeta` paints, cut into
/// `chunk_size_tiles` chunks, so multi-chunk tests shrink the chunk rather than grow
/// the world. Builds no render params; `chunk_size_tiles` must pass
/// `validateChunkGrid`.
pub fn demoWorldWithChunkSize(
    allocator: std.mem.Allocator,
    meta: *const WorldTilesetMeta,
    bounds_width: f32,
    bounds_height: f32,
    chunk_size_tiles: u16,
) !WorldSystem {
    const tile_size = meta.tileSize();
    const width: u16 = @intFromFloat(@max(@ceil(bounds_width / tile_size), 1));
    const height: u16 = @intFromFloat(@max(@ceil(bounds_height / tile_size), 1));
    var world = WorldSystem{
        .allocator = allocator,
        .width = width,
        .height = height,
        .tile_size = tile_size,
        .chunk_size_tiles = chunk_size_tiles,
    };
    errdefer world.deinit();
    try world.buildCatalog(meta);
    const level = try world.addLevel(0);
    const grass = try world.requireTileByName(meta, "grass");
    const grass_patchy = try world.requireTileByName(meta, "grass_patchy");
    const path = try world.requireTileByName(meta, "path_0");
    const stone = try world.requireTileByName(meta, "stone_floor");
    const deco = try world.requireTileByName(meta, "deco_0");

    const ground_layer = try world.addDenseLayer(level, 0, .floor, grass);
    const mid_y = height / 2;
    const mid_x = width / 2;
    for (0..height) |y| {
        for (0..width) |x| {
            const tile: TileId = if (x == mid_x or y == mid_y)
                path
            else if ((x + y) % 11 == 0)
                grass_patchy
            else if ((x * 3 + y) % 17 == 0)
                stone
            else
                grass;
            _ = try world.setDenseTile(ground_layer, @intCast(x), @intCast(y), tile);
        }
    }
    _ = try world.addSparseTile(level, width / 4, height / 3, deco, 0, .obstacle);
    _ = try world.addSparseTile(level, (width * 3) / 4, (height * 2) / 3, deco, 0, .obstacle);
    return world;
}

/// Takes and releases the tile block and composed-bits slot a landing carve into
/// `cell` on `level` needs, so a later carve in that chunk reuses them: the terrain
/// pools are warm, like the frame and data allocators the zero-allocation proofs warm.
pub fn warmLandingTerrain(world: *WorldSystem, tunnel_tile: TileId, level: u16, cell: [2]u16) !void {
    const floor = world.denseFloorLayerForLevel(level).?;
    const original = world.denseTile(floor, cell[0], cell[1]);
    world.beginDenseCellWriteReserve();
    try world.reserveDenseCellWrite(floor, cell[0], cell[1], tunnel_tile);
    _ = try world.setDenseTile(floor, cell[0], cell[1], tunnel_tile);
    _ = try world.setDenseTile(floor, cell[0], cell[1], original);
    world.beginDenseCellWriteReserve();
}

test "the chunk-sized demo world at the default edge matches initDemoFromMeta" {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    const bounds = meta.tileSize() * 24 + 5;
    var fixture = try demoWorldWithChunkSize(std.testing.allocator, &meta, bounds, bounds, default_chunk_size_tiles);
    defer fixture.deinit();
    var demo = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, bounds, bounds);
    defer demo.deinit();

    try std.testing.expectEqual(demo.width, fixture.width);
    try std.testing.expectEqual(demo.height, fixture.height);
    try std.testing.expectEqual(demo.levelCount(), fixture.levelCount());
    try std.testing.expectEqual(demo.denseLayerCount(), fixture.denseLayerCount());
    for (0..demo.denseLayerCount()) |layer| {
        for (0..demo.height) |y| for (0..demo.width) |x| {
            try std.testing.expectEqual(demo.denseTile(layer, @intCast(x), @intCast(y)), fixture.denseTile(layer, @intCast(x), @intCast(y)));
        };
    }
    try std.testing.expectEqual(demo.sparseTileCount(), fixture.sparseTileCount());
    for (0..demo.sparseTileCount()) |index| {
        try std.testing.expectEqual(demo.sparseTileCellCoord(index), fixture.sparseTileCellCoord(index));
        try std.testing.expectEqual(demo.sparseTileBlocksMovement(index), fixture.sparseTileBlocksMovement(index));
    }
}
