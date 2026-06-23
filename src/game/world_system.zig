// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-owned SoA world/tile storage and render preparation.
//! Persistent world data stores stable tile IDs, level/chunk metadata, and
//! atlas-derived source rect columns. Renderer handles stay outside this owner.

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const manifest = @import("../assets/manifest.zig");
const WorldTilesetMeta = @import("../assets/world_tileset_meta.zig").WorldTilesetMeta;
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const Rect = @import("../render/renderer.zig").Rect;
const RenderOrder = @import("../render/renderer.zig").RenderOrder;
const RenderQueue = @import("../render/render_queue.zig").RenderQueue;
const render_depth = @import("render_depth.zig");
const WorldDepth = render_depth.WorldDepth;

pub const TileId = u16;
pub const invalid_tile_id: TileId = std.math.maxInt(TileId);
pub const default_chunk_size_tiles: u16 = 8;

pub const TileFlags = packed struct(u8) {
    walkable: bool = false,
    blocks_movement: bool = false,
    blocks_vision: bool = false,
    reserved: u5 = 0,
};

pub const WorldRenderStats = struct {
    levels: usize = 0,
    chunks: usize = 0,
    visible_chunks: usize = 0,
    total_tiles: usize = 0,
    visible_tiles: usize = 0,
    emitted_sprite_tiles: usize = 0,
    missing_source_rects: usize = 0,
};

const ChunkColumns = struct {
    level_indices: std.ArrayList(u16) = .empty,
    x: std.ArrayList(i32) = .empty,
    y: std.ArrayList(i32) = .empty,
    cell_min_x: std.ArrayList(u16) = .empty,
    cell_min_y: std.ArrayList(u16) = .empty,
    cell_max_x_exclusive: std.ArrayList(u16) = .empty,
    cell_max_y_exclusive: std.ArrayList(u16) = .empty,
    visible: std.ArrayList(bool) = .empty,

    fn deinit(self: *ChunkColumns, allocator: std.mem.Allocator) void {
        self.visible.deinit(allocator);
        self.cell_max_y_exclusive.deinit(allocator);
        self.cell_max_x_exclusive.deinit(allocator);
        self.cell_min_y.deinit(allocator);
        self.cell_min_x.deinit(allocator);
        self.y.deinit(allocator);
        self.x.deinit(allocator);
        self.level_indices.deinit(allocator);
        self.* = .{};
    }

    fn ensureTotalCapacity(self: *ChunkColumns, allocator: std.mem.Allocator, count: usize) !void {
        try self.level_indices.ensureTotalCapacity(allocator, count);
        try self.x.ensureTotalCapacity(allocator, count);
        try self.y.ensureTotalCapacity(allocator, count);
        try self.cell_min_x.ensureTotalCapacity(allocator, count);
        try self.cell_min_y.ensureTotalCapacity(allocator, count);
        try self.cell_max_x_exclusive.ensureTotalCapacity(allocator, count);
        try self.cell_max_y_exclusive.ensureTotalCapacity(allocator, count);
        try self.visible.ensureTotalCapacity(allocator, count);
    }

    fn appendAssumeCapacity(
        self: *ChunkColumns,
        level_index: u16,
        chunk_x: i32,
        chunk_y: i32,
        min_x: u16,
        min_y: u16,
        max_x: u16,
        max_y: u16,
        visible: bool,
    ) void {
        self.level_indices.appendAssumeCapacity(level_index);
        self.x.appendAssumeCapacity(chunk_x);
        self.y.appendAssumeCapacity(chunk_y);
        self.cell_min_x.appendAssumeCapacity(min_x);
        self.cell_min_y.appendAssumeCapacity(min_y);
        self.cell_max_x_exclusive.appendAssumeCapacity(max_x);
        self.cell_max_y_exclusive.appendAssumeCapacity(max_y);
        self.visible.appendAssumeCapacity(visible);
    }
};

pub const WorldSystem = struct {
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    tile_size: f32,
    chunk_size_tiles: u16,

    catalog_valid: std.ArrayList(bool) = .empty,
    catalog_source_x: std.ArrayList(f32) = .empty,
    catalog_source_y: std.ArrayList(f32) = .empty,
    catalog_source_w: std.ArrayList(f32) = .empty,
    catalog_source_h: std.ArrayList(f32) = .empty,
    catalog_flags: std.ArrayList(TileFlags) = .empty,

    level_base_z: std.ArrayList(i32) = .empty,

    dense_level_indices: std.ArrayList(u16) = .empty,
    dense_base_z: std.ArrayList(i32) = .empty,
    dense_depth_bands: std.ArrayList(WorldDepth) = .empty,
    dense_tile_ids: std.ArrayList(TileId) = .empty,

    sparse_level_indices: std.ArrayList(u16) = .empty,
    sparse_chunk_indices: std.ArrayList(u32) = .empty,
    sparse_cell_indices: std.ArrayList(u32) = .empty,
    sparse_tile_ids: std.ArrayList(TileId) = .empty,
    sparse_depth_values: std.ArrayList(i32) = .empty,
    sparse_flags: std.ArrayList(TileFlags) = .empty,

    chunk_level_indices: std.ArrayList(u16) = .empty,
    chunk_x: std.ArrayList(i32) = .empty,
    chunk_y: std.ArrayList(i32) = .empty,
    chunk_cell_min_x: std.ArrayList(u16) = .empty,
    chunk_cell_min_y: std.ArrayList(u16) = .empty,
    chunk_cell_max_x_exclusive: std.ArrayList(u16) = .empty,
    chunk_cell_max_y_exclusive: std.ArrayList(u16) = .empty,
    chunk_visible: std.ArrayList(bool) = .empty,

    pub fn initDemo(
        allocator: std.mem.Allocator,
        runtime_assets: *const RuntimeAssets,
        bounds_width: f32,
        bounds_height: f32,
    ) !WorldSystem {
        const meta = runtime_assets.worldTilesetMeta() orelse return error.WorldTilesetMetadataUnavailable;
        return try initDemoFromMeta(allocator, meta, bounds_width, bounds_height);
    }

    pub fn initDemoFromMeta(
        allocator: std.mem.Allocator,
        meta: *const WorldTilesetMeta,
        bounds_width: f32,
        bounds_height: f32,
    ) !WorldSystem {
        const tile_size = meta.tileSize();
        const width = ceilTiles(bounds_width, tile_size);
        const height = ceilTiles(bounds_height, tile_size);
        var world = WorldSystem{
            .allocator = allocator,
            .width = width,
            .height = height,
            .tile_size = tile_size,
            .chunk_size_tiles = default_chunk_size_tiles,
        };
        errdefer world.deinit();

        try world.buildCatalog(meta);
        const level = try world.addLevel(0);

        const grass = try world.requireTileByName(meta, "grass");
        const dirt = try world.requireTileByName(meta, "dirt");
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
                    dirt
                else if ((x * 3 + y) % 17 == 0)
                    stone
                else
                    grass;
                try world.setDenseTile(ground_layer, @intCast(x), @intCast(y), tile);
            }
        }

        try world.addSparseTile(level, width / 4, height / 3, deco, 0, .obstacle);
        try world.addSparseTile(level, (width * 3) / 4, (height * 2) / 3, deco, 0, .obstacle);

        try world.rebuildChunks();
        return world;
    }

    pub fn initDemoFromAssetStore(
        allocator: std.mem.Allocator,
        asset_store: AssetStore,
        bounds_width: f32,
        bounds_height: f32,
    ) !WorldSystem {
        var meta = try world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
        defer meta.deinit();
        return try initDemoFromMeta(allocator, &meta, bounds_width, bounds_height);
    }

    pub fn deinit(self: *WorldSystem) void {
        self.chunk_visible.deinit(self.allocator);
        self.chunk_cell_max_y_exclusive.deinit(self.allocator);
        self.chunk_cell_max_x_exclusive.deinit(self.allocator);
        self.chunk_cell_min_y.deinit(self.allocator);
        self.chunk_cell_min_x.deinit(self.allocator);
        self.chunk_y.deinit(self.allocator);
        self.chunk_x.deinit(self.allocator);
        self.chunk_level_indices.deinit(self.allocator);

        self.sparse_flags.deinit(self.allocator);
        self.sparse_depth_values.deinit(self.allocator);
        self.sparse_tile_ids.deinit(self.allocator);
        self.sparse_cell_indices.deinit(self.allocator);
        self.sparse_chunk_indices.deinit(self.allocator);
        self.sparse_level_indices.deinit(self.allocator);

        self.dense_tile_ids.deinit(self.allocator);
        self.dense_depth_bands.deinit(self.allocator);
        self.dense_base_z.deinit(self.allocator);
        self.dense_level_indices.deinit(self.allocator);

        self.level_base_z.deinit(self.allocator);

        self.catalog_flags.deinit(self.allocator);
        self.catalog_source_h.deinit(self.allocator);
        self.catalog_source_w.deinit(self.allocator);
        self.catalog_source_y.deinit(self.allocator);
        self.catalog_source_x.deinit(self.allocator);
        self.catalog_valid.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reserveRenderRecords(self: *const WorldSystem) usize {
        return self.visibleTileCount();
    }

    pub fn visibleTileCount(self: *const WorldSystem) usize {
        var visible_dense_cells: usize = 0;
        for (0..self.dense_level_indices.items.len) |layer_index| {
            for (0..self.chunk_visible.items.len) |chunk_index| {
                if (!self.chunk_visible.items[chunk_index] or !self.chunkMatchesLayer(chunk_index, layer_index)) continue;
                visible_dense_cells += self.chunkCellCount(chunk_index);
            }
        }
        var visible_sparse_tiles: usize = 0;
        for (self.sparse_chunk_indices.items) |chunk_index| {
            if (self.isSparseChunkVisible(chunk_index)) {
                visible_sparse_tiles += 1;
            }
        }
        return visible_dense_cells + visible_sparse_tiles;
    }

    pub fn enqueueRender(
        self: *const WorldSystem,
        queue: *RenderQueue,
        runtime_assets: *const RuntimeAssets,
    ) !WorldRenderStats {
        const prepared = runtime_assets.sprite(.world_tileset) orelse return error.WorldTilesetTextureUnavailable;
        var stats = WorldRenderStats{
            .levels = self.level_base_z.items.len,
            .chunks = self.chunk_visible.items.len,
            .total_tiles = self.dense_level_indices.items.len * self.cellCount() + self.sparse_tile_ids.items.len,
        };

        for (0..self.chunk_visible.items.len) |chunk_index| {
            if (self.chunk_visible.items[chunk_index]) stats.visible_chunks += 1;
        }

        for (0..self.dense_level_indices.items.len) |layer_index| {
            const order = RenderOrder.world(self.worldZForLevel(
                self.dense_level_indices.items[layer_index],
                self.dense_base_z.items[layer_index],
                self.dense_depth_bands.items[layer_index],
            ));
            for (0..self.chunk_visible.items.len) |chunk_index| {
                if (!self.chunk_visible.items[chunk_index] or !self.chunkMatchesLayer(chunk_index, layer_index)) continue;
                const min_x = self.chunk_cell_min_x.items[chunk_index];
                const min_y = self.chunk_cell_min_y.items[chunk_index];
                const max_x = self.chunk_cell_max_x_exclusive.items[chunk_index];
                const max_y = self.chunk_cell_max_y_exclusive.items[chunk_index];
                var y = min_y;
                while (y < max_y) : (y += 1) {
                    var x = min_x;
                    while (x < max_x) : (x += 1) {
                        const tile_id = self.denseTile(layer_index, x, y);
                        try self.enqueueTile(queue, prepared, tile_id, x, y, order, &stats);
                    }
                }
            }
        }

        for (self.sparse_tile_ids.items, 0..) |tile_id, index| {
            if (!self.isSparseChunkVisible(self.sparse_chunk_indices.items[index])) continue;
            const cell = self.sparse_cell_indices.items[index];
            const x: u16 = @intCast(cell % self.width);
            const y: u16 = @intCast((cell / self.width) % self.height);
            try self.enqueueTile(
                queue,
                prepared,
                tile_id,
                x,
                y,
                RenderOrder.world(self.sparse_depth_values.items[index]),
                &stats,
            );
        }

        return stats;
    }

    pub fn denseTile(self: *const WorldSystem, layer_index: usize, x: u16, y: u16) TileId {
        return self.dense_tile_ids.items[self.denseLayerOffset(layer_index) + self.cellIndex(x, y)];
    }

    pub fn setDenseTile(self: *WorldSystem, layer_index: usize, x: u16, y: u16, tile_id: TileId) !void {
        if (layer_index >= self.dense_level_indices.items.len) return error.InvalidWorldLayer;
        try self.validateTileId(tile_id);
        if (x >= self.width or y >= self.height) return error.InvalidWorldCell;
        self.dense_tile_ids.items[self.denseLayerOffset(layer_index) + self.cellIndex(x, y)] = tile_id;
    }

    pub fn chunkCoordForCell(self: *const WorldSystem, x: u16, y: u16) struct { x: i32, y: i32 } {
        return .{
            .x = @intCast(x / self.chunk_size_tiles),
            .y = @intCast(y / self.chunk_size_tiles),
        };
    }

    pub fn addLevel(self: *WorldSystem, base_z: i32) !u16 {
        const index = self.level_base_z.items.len;
        if (index > std.math.maxInt(u16)) return error.WorldLevelOverflow;
        try self.level_base_z.ensureUnusedCapacity(self.allocator, 1);
        self.level_base_z.appendAssumeCapacity(base_z);
        errdefer _ = self.level_base_z.pop();
        try self.rebuildChunks();
        return @intCast(index);
    }

    pub fn addDenseLayer(self: *WorldSystem, level_index: u16, base_z: i32, depth: WorldDepth, fill_tile: TileId) !usize {
        try self.validateLevelIndex(level_index);
        try self.validateTileId(fill_tile);
        const layer_index = self.dense_level_indices.items.len;
        try self.dense_level_indices.ensureUnusedCapacity(self.allocator, 1);
        try self.dense_base_z.ensureUnusedCapacity(self.allocator, 1);
        try self.dense_depth_bands.ensureUnusedCapacity(self.allocator, 1);
        try self.dense_tile_ids.ensureUnusedCapacity(self.allocator, self.cellCount());
        self.dense_level_indices.appendAssumeCapacity(level_index);
        self.dense_base_z.appendAssumeCapacity(base_z);
        self.dense_depth_bands.appendAssumeCapacity(depth);
        for (0..self.cellCount()) |_| {
            self.dense_tile_ids.appendAssumeCapacity(fill_tile);
        }
        return layer_index;
    }

    pub fn addSparseTile(
        self: *WorldSystem,
        level_index: u16,
        x: u16,
        y: u16,
        tile_id: TileId,
        base_z: i32,
        depth: WorldDepth,
    ) !void {
        try self.validateLevelIndex(level_index);
        try self.validateTileId(tile_id);
        if (x >= self.width or y >= self.height) return error.InvalidWorldCell;
        const cell = self.cellIndex(x, y);
        const chunk_index = try self.sparseChunkIndexForCell(level_index, x, y);
        const flags = self.flagsFor(tile_id);
        const world_z = self.worldZForLevel(level_index, base_z, depth);
        try self.sparse_level_indices.ensureUnusedCapacity(self.allocator, 1);
        try self.sparse_chunk_indices.ensureUnusedCapacity(self.allocator, 1);
        try self.sparse_cell_indices.ensureUnusedCapacity(self.allocator, 1);
        try self.sparse_tile_ids.ensureUnusedCapacity(self.allocator, 1);
        try self.sparse_depth_values.ensureUnusedCapacity(self.allocator, 1);
        try self.sparse_flags.ensureUnusedCapacity(self.allocator, 1);
        self.sparse_level_indices.appendAssumeCapacity(level_index);
        self.sparse_chunk_indices.appendAssumeCapacity(chunk_index);
        self.sparse_cell_indices.appendAssumeCapacity(cell);
        self.sparse_tile_ids.appendAssumeCapacity(tile_id);
        self.sparse_depth_values.appendAssumeCapacity(world_z);
        self.sparse_flags.appendAssumeCapacity(flags);
    }

    fn enqueueTile(
        self: *const WorldSystem,
        queue: *RenderQueue,
        prepared: @import("../assets/runtime_assets.zig").PreparedSprite,
        tile_id: TileId,
        x: u16,
        y: u16,
        order: RenderOrder,
        stats: *WorldRenderStats,
    ) !void {
        stats.visible_tiles += 1;
        const dest = Rect{
            .x = @as(f32, @floatFromInt(x)) * self.tile_size,
            .y = @as(f32, @floatFromInt(y)) * self.tile_size,
            .w = self.tile_size,
            .h = self.tile_size,
        };
        const source = self.sourceRect(tile_id) orelse {
            stats.missing_source_rects += 1;
            return error.MissingTileSourceRect;
        };
        try queue.addSprite(.{
            .texture = prepared.texture,
            .source = source,
            .dest = dest,
            .order = order,
        });
        stats.emitted_sprite_tiles += 1;
    }

    fn buildCatalog(self: *WorldSystem, meta: *const WorldTilesetMeta) !void {
        const count = catalogCapacity(meta);
        try self.catalog_valid.ensureTotalCapacity(self.allocator, count);
        try self.catalog_source_x.ensureTotalCapacity(self.allocator, count);
        try self.catalog_source_y.ensureTotalCapacity(self.allocator, count);
        try self.catalog_source_w.ensureTotalCapacity(self.allocator, count);
        try self.catalog_source_h.ensureTotalCapacity(self.allocator, count);
        try self.catalog_flags.ensureTotalCapacity(self.allocator, count);
        for (0..count) |_| {
            self.catalog_valid.appendAssumeCapacity(false);
            self.catalog_source_x.appendAssumeCapacity(0);
            self.catalog_source_y.appendAssumeCapacity(0);
            self.catalog_source_w.appendAssumeCapacity(self.tile_size);
            self.catalog_source_h.appendAssumeCapacity(self.tile_size);
            self.catalog_flags.appendAssumeCapacity(.{});
        }

        for (0..meta.tileCount()) |index| {
            const tile = meta.tileAtIndex(index) orelse continue;
            const tile_index: usize = tile.id;
            self.catalog_valid.items[tile_index] = true;
            self.catalog_source_x.items[tile_index] = tile.x;
            self.catalog_source_y.items[tile_index] = tile.y;
            self.catalog_source_w.items[tile_index] = tile.width;
            self.catalog_source_h.items[tile_index] = tile.height;
            self.catalog_flags.items[tile_index] = .{
                .walkable = tile.properties.walkable,
                .blocks_movement = tile.properties.blocks_movement,
                .blocks_vision = tile.properties.blocks_vision,
            };
        }
    }

    fn rebuildChunks(self: *WorldSystem) !void {
        const chunks_x = ceilDiv(self.width, self.chunk_size_tiles);
        const chunks_y = ceilDiv(self.height, self.chunk_size_tiles);
        const chunk_count = @as(usize, chunks_x) * @as(usize, chunks_y) * self.level_base_z.items.len;
        var next = ChunkColumns{};
        errdefer next.deinit(self.allocator);
        try next.ensureTotalCapacity(self.allocator, chunk_count);
        for (0..self.level_base_z.items.len) |level_index| {
            for (0..chunks_y) |cy| {
                for (0..chunks_x) |cx| {
                    const min_x: u16 = @intCast(cx * self.chunk_size_tiles);
                    const min_y: u16 = @intCast(cy * self.chunk_size_tiles);
                    const max_x: u16 = @min(self.width, min_x + self.chunk_size_tiles);
                    const max_y: u16 = @min(self.height, min_y + self.chunk_size_tiles);
                    const chunk_x: i32 = @intCast(cx);
                    const chunk_y: i32 = @intCast(cy);
                    next.appendAssumeCapacity(
                        @intCast(level_index),
                        chunk_x,
                        chunk_y,
                        min_x,
                        min_y,
                        max_x,
                        max_y,
                        self.preservedChunkVisible(@intCast(level_index), chunk_x, chunk_y),
                    );
                }
            }
        }

        var old = ChunkColumns{
            .level_indices = self.chunk_level_indices,
            .x = self.chunk_x,
            .y = self.chunk_y,
            .cell_min_x = self.chunk_cell_min_x,
            .cell_min_y = self.chunk_cell_min_y,
            .cell_max_x_exclusive = self.chunk_cell_max_x_exclusive,
            .cell_max_y_exclusive = self.chunk_cell_max_y_exclusive,
            .visible = self.chunk_visible,
        };
        self.chunk_level_indices = next.level_indices;
        self.chunk_x = next.x;
        self.chunk_y = next.y;
        self.chunk_cell_min_x = next.cell_min_x;
        self.chunk_cell_min_y = next.cell_min_y;
        self.chunk_cell_max_x_exclusive = next.cell_max_x_exclusive;
        self.chunk_cell_max_y_exclusive = next.cell_max_y_exclusive;
        self.chunk_visible = next.visible;
        next = .{};
        old.deinit(self.allocator);
    }

    fn sourceRect(self: *const WorldSystem, tile_id: TileId) ?Rect {
        const index: usize = tile_id;
        if (index >= self.catalog_valid.items.len or !self.catalog_valid.items[index]) return null;
        return .{
            .x = self.catalog_source_x.items[index],
            .y = self.catalog_source_y.items[index],
            .w = self.catalog_source_w.items[index],
            .h = self.catalog_source_h.items[index],
        };
    }

    fn flagsFor(self: *const WorldSystem, tile_id: TileId) TileFlags {
        const index: usize = tile_id;
        if (index >= self.catalog_flags.items.len) return .{};
        return self.catalog_flags.items[index];
    }

    fn requireTileByName(self: *const WorldSystem, meta: *const WorldTilesetMeta, name: []const u8) !TileId {
        _ = self;
        const tile = meta.tileByName(name) orelse return error.RequiredWorldTileMissing;
        return tile.id;
    }

    fn cellCount(self: *const WorldSystem) usize {
        return @as(usize, self.width) * @as(usize, self.height);
    }

    fn cellIndex(self: *const WorldSystem, x: u16, y: u16) u32 {
        std.debug.assert(x < self.width);
        std.debug.assert(y < self.height);
        return @intCast(@as(usize, y) * @as(usize, self.width) + @as(usize, x));
    }

    fn denseLayerOffset(self: *const WorldSystem, layer_index: usize) usize {
        return layer_index * self.cellCount();
    }

    fn chunkCellCount(self: *const WorldSystem, chunk_index: usize) usize {
        const width = self.chunk_cell_max_x_exclusive.items[chunk_index] - self.chunk_cell_min_x.items[chunk_index];
        const height = self.chunk_cell_max_y_exclusive.items[chunk_index] - self.chunk_cell_min_y.items[chunk_index];
        return @as(usize, width) * @as(usize, height);
    }

    fn validateLevelIndex(self: *const WorldSystem, level_index: u16) !void {
        if (@as(usize, level_index) >= self.level_base_z.items.len) return error.InvalidWorldLevel;
    }

    fn validateTileId(self: *const WorldSystem, tile_id: TileId) !void {
        if (!self.isValidTileId(tile_id)) return error.InvalidWorldTile;
    }

    fn isValidTileId(self: *const WorldSystem, tile_id: TileId) bool {
        const index: usize = tile_id;
        return index < self.catalog_valid.items.len and self.catalog_valid.items[index];
    }

    fn worldZForLevel(self: *const WorldSystem, level_index: u16, local_z: i32, depth: WorldDepth) i32 {
        const level_z: i64 = @as(i64, self.level_base_z.items[level_index]);
        const value = level_z + @as(i64, local_z) + @as(i64, render_depth.worldZ(depth));
        const min: i64 = std.math.minInt(i32);
        const max: i64 = std.math.maxInt(i32);
        return @intCast(@max(min, @min(max, value)));
    }

    fn chunkMatchesLayer(self: *const WorldSystem, chunk_index: usize, layer_index: usize) bool {
        return self.chunk_level_indices.items[chunk_index] == self.dense_level_indices.items[layer_index];
    }

    fn preservedChunkVisible(self: *const WorldSystem, level_index: u16, chunk_x: i32, chunk_y: i32) bool {
        for (0..self.chunk_visible.items.len) |index| {
            if (self.chunk_level_indices.items[index] != level_index) continue;
            if (self.chunk_x.items[index] != chunk_x or self.chunk_y.items[index] != chunk_y) continue;
            return self.chunk_visible.items[index];
        }
        return true;
    }

    fn isSparseChunkVisible(self: *const WorldSystem, chunk_index: u32) bool {
        const index: usize = chunk_index;
        return index < self.chunk_visible.items.len and self.chunk_visible.items[index];
    }

    fn sparseChunkIndexForCell(self: *const WorldSystem, level_index: u16, x: u16, y: u16) !u32 {
        const chunks_x = ceilDiv(self.width, self.chunk_size_tiles);
        const chunks_y = ceilDiv(self.height, self.chunk_size_tiles);
        const chunk_x = x / self.chunk_size_tiles;
        const chunk_y = y / self.chunk_size_tiles;
        const level_offset = @as(usize, level_index) * @as(usize, chunks_x) * @as(usize, chunks_y);
        const chunk_offset = @as(usize, chunk_y) * @as(usize, chunks_x) + @as(usize, chunk_x);
        const index = level_offset + chunk_offset;
        if (index > std.math.maxInt(u32)) return error.WorldChunkOverflow;
        return @intCast(index);
    }
};

fn catalogCapacity(meta: *const WorldTilesetMeta) usize {
    var max_id: usize = 0;
    for (0..meta.tileCount()) |index| {
        const tile = meta.tileAtIndex(index) orelse continue;
        max_id = @max(max_id, tile.id);
    }
    return max_id + 1;
}

fn ceilTiles(value: f32, tile_size: f32) u16 {
    const tiles = @ceil(value / tile_size);
    return @intFromFloat(@max(tiles, 1));
}

fn ceilDiv(value: u16, divisor: u16) u16 {
    return (value + divisor - 1) / divisor;
}

fn testWorldMeta() !WorldTilesetMeta {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    return try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
}

fn setSpriteAvailableForTest(runtime_assets: *RuntimeAssets, id: manifest.SpriteAssetId, texture: @import("../render/resources.zig").TextureId) void {
    runtime_assets.sprite_slots[manifest.spriteIndex(id)] = .{
        .status = .available,
        .lease = .{ .id = texture },
    };
}

test "world dense layer uses row-major indexing" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 96, 64);
    defer world.deinit();

    try std.testing.expectEqual(@as(u16, 3), world.width);
    try std.testing.expectEqual(@as(u16, 2), world.height);
    try std.testing.expectEqual(@as(u32, 0), world.cellIndex(0, 0));
    try std.testing.expectEqual(@as(u32, 1), world.cellIndex(1, 0));
    try std.testing.expectEqual(@as(u32, 3), world.cellIndex(0, 1));

    const grass = try world.requireTileByName(&meta, "grass");
    try world.setDenseTile(0, 2, 1, grass);
    try std.testing.expectEqual(grass, world.denseTile(0, 2, 1));
}

test "world rejects invalid tile ids before render" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 64, 64);
    defer world.deinit();

    const invalid = invalid_tile_id;
    try std.testing.expectError(error.InvalidWorldTile, world.addDenseLayer(0, 0, .floor, invalid));
    try std.testing.expectError(error.InvalidWorldTile, world.setDenseTile(0, 0, 0, invalid));
    try std.testing.expectError(error.InvalidWorldTile, world.addSparseTile(0, 0, 0, invalid, 0, .obstacle));
}

test "world chunks map cells by chunk size" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 320, 320);
    defer world.deinit();

    const first = world.chunkCoordForCell(0, 0);
    try std.testing.expectEqual(@as(i32, 0), first.x);
    try std.testing.expectEqual(@as(i32, 0), first.y);
    const next = world.chunkCoordForCell(default_chunk_size_tiles, default_chunk_size_tiles);
    try std.testing.expectEqual(@as(i32, 1), next.x);
    try std.testing.expectEqual(@as(i32, 1), next.y);
}

test "world add level keeps chunks renderable without manual rebuild" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);

    const level0 = try world.addLevel(0);
    const level1 = try world.addLevel(10);
    const grass = try world.requireTileByName(&meta, "grass");
    _ = try world.addDenseLayer(level0, 0, .floor, grass);
    _ = try world.addDenseLayer(level1, 0, .floor, grass);

    try std.testing.expectEqual(@as(usize, 2), world.chunk_visible.items.len);
    try std.testing.expectEqual(@as(usize, 2), world.visibleTileCount());
}

test "world add level preserves existing chunk visibility" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 2,
        .height = 1,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);

    const level0 = try world.addLevel(0);
    world.chunk_visible.items[0] = false;
    const level1 = try world.addLevel(10);
    const grass = try world.requireTileByName(&meta, "grass");
    _ = try world.addDenseLayer(level0, 0, .floor, grass);
    _ = try world.addDenseLayer(level1, 0, .floor, grass);

    try std.testing.expectEqual(@as(usize, 4), world.chunk_visible.items.len);
    try std.testing.expect(!world.chunk_visible.items[0]);
    try std.testing.expect(world.chunk_visible.items[1]);
    try std.testing.expect(world.chunk_visible.items[2]);
    try std.testing.expect(world.chunk_visible.items[3]);
    try std.testing.expectEqual(@as(usize, 3), world.visibleTileCount());
}

test "world render requires atlas texture" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 64, 64);
    defer world.deinit();
    var queue = RenderQueue.init(std.testing.allocator);
    defer queue.deinit();
    var runtime_assets = RuntimeAssets.init();

    try std.testing.expectError(error.WorldTilesetTextureUnavailable, world.enqueueRender(&queue, &runtime_assets));
}

test "world enqueue render emits atlas sprites in stable order" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 64, 64);
    defer world.deinit();
    var queue = RenderQueue.init(std.testing.allocator);
    defer queue.deinit();
    var runtime_assets = RuntimeAssets.init();
    setSpriteAvailableForTest(&runtime_assets, .world_tileset, try @import("../render/resources.zig").TextureId.init(1, 1));

    const stats = try world.enqueueRender(&queue, &runtime_assets);
    queue.sortForSubmit();

    try std.testing.expect(stats.emitted_sprite_tiles > 0);
    try std.testing.expectEqual(stats.emitted_sprite_tiles, queue.recordCount());
    try std.testing.expect(queue.sortedSprite(0) != null);
    try std.testing.expect(queue.sortedSprite(0).?.source != null);
    for (1..queue.recordCount()) |index| {
        try std.testing.expect(queue.recordOrder(index - 1).lessOrEqual(queue.recordOrder(index)));
    }
}

test "world dense and sparse rendering respects z levels and chunk level filtering" {
    var meta = try testWorldMeta();
    defer meta.deinit();
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);

    const level0 = try world.addLevel(0);
    const level1 = try world.addLevel(10);
    const grass = try world.requireTileByName(&meta, "grass");
    const deco = try world.requireTileByName(&meta, "deco_0");
    _ = try world.addDenseLayer(level0, 0, .floor, grass);
    _ = try world.addDenseLayer(level1, 0, .floor, grass);
    try world.addSparseTile(level1, 0, 0, deco, 0, .obstacle);
    try world.rebuildChunks();

    try std.testing.expectEqual(@as(usize, 2), world.chunk_visible.items.len);
    try std.testing.expectEqual(@as(usize, 3), world.visibleTileCount());

    var queue = RenderQueue.init(std.testing.allocator);
    defer queue.deinit();
    var runtime_assets = RuntimeAssets.init();
    setSpriteAvailableForTest(&runtime_assets, .world_tileset, try @import("../render/resources.zig").TextureId.init(1, 1));
    const stats = try world.enqueueRender(&queue, &runtime_assets);
    queue.sortForSubmit();

    try std.testing.expectEqual(@as(usize, 3), stats.emitted_sprite_tiles);
    try std.testing.expectEqual(render_depth.worldZ(.floor), queue.recordOrder(0).depth);
    try std.testing.expectEqual(@as(i32, 8), queue.recordOrder(1).depth);
    try std.testing.expectEqual(@as(i32, 9), queue.recordOrder(2).depth);
}
