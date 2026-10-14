// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared private test fixtures for `WorldSystem` callers across modules. Test-only:
//! no production path imports it. Single-module helpers stay in their module.

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const WorldSystem = @import("world_system.zig").WorldSystem;
const TileId = @import("world_system.zig").TileId;
const DenseCellWrite = @import("world_system.zig").DenseCellWrite;
const DenseChunkWrites = @import("world_system.zig").DenseChunkWrites;
const WorldTileChangedEvent = @import("simulation.zig").WorldTileChangedEvent;
const default_chunk_size_tiles = @import("world_system.zig").default_chunk_size_tiles;
const ChunkGeometry = @import("world_terrain.zig").ChunkGeometry;
const ChunkWindow = @import("world_gpu_tiles.zig").ChunkWindow;
const TileStoreSpan = @import("../render/renderer.zig").TileStoreSpan;
const tile_store_no_link = @import("../render/renderer.zig").tile_store_no_link;
const tile_store_uniform_bit = @import("../render/renderer.zig").tile_store_uniform_bit;

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
    if (layer >= world.denseLayerCount() or x >= world.width or y >= world.height) return true;
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
