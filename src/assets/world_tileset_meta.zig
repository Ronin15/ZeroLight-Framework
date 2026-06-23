// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! World tileset metadata loaded once at setup. World construction resolves
//! authoring names to stable tile IDs; `WorldSystem` keeps source rectangles in
//! SoA catalog columns instead of storing names or renderer handles.

const std = @import("std");
const atlas_meta_common = @import("atlas_meta_common.zig");
const manifest = @import("manifest.zig");

pub const required_tile_size: f32 = 32;
pub const TileAnimation = atlas_meta_common.TileAnimation;

pub const TileProperties = struct {
    layer: []const u8,
    terrain: []const u8,
    walkable: bool,
    blocks_movement: bool,
    blocks_vision: bool,
};

pub const TileEntry = struct {
    id: u16,
    name: []const u8,
    category: []const u8,
    column: u32,
    row: u32,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    properties: TileProperties,
};

pub const AtlasInfo = struct {
    path: []const u8,
    sprite_asset_id: []const u8,
    width: u32,
    height: u32,
};

const JsonTileProperties = struct {
    layer: []const u8,
    terrain: []const u8,
    walkable: bool,
    blocks_movement: bool,
    blocks_vision: bool,
};

const JsonTileEntry = struct {
    id: u16,
    name: []const u8,
    category: []const u8,
    column: u32,
    row: u32,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    properties: JsonTileProperties,
};

const JsonAtlasInfo = struct {
    path: []const u8,
    sprite_asset_id: []const u8,
    width: u32,
    height: u32,
};

const JsonRoot = struct {
    version: u32,
    name: []const u8,
    theme: []const u8,
    atlas: JsonAtlasInfo,
    tile_size: u32,
    columns: u32,
    rows: u32,
    tile_count: u32,
    animations: ?std.json.Value = null,
    tiles: []JsonTileEntry,
};

pub const WorldTilesetMeta = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    parsed: std.json.Parsed(JsonRoot),
    name_to_id: std.StringHashMap(u16),
    id_to_index: std.AutoHashMap(u16, usize),
    animations: std.StringHashMap(TileAnimation),

    pub fn deinit(self: *WorldTilesetMeta) void {
        atlas_meta_common.deinitAnimationTable(&self.animations, self.allocator);
        self.id_to_index.deinit();
        self.name_to_id.deinit();
        atlas_meta_common.deinitJsonAsset(self.allocator, self.bytes, &self.parsed);
        self.* = undefined;
    }

    pub fn version(self: WorldTilesetMeta) u32 {
        return self.parsed.value.version;
    }

    pub fn name(self: WorldTilesetMeta) []const u8 {
        return self.parsed.value.name;
    }

    pub fn theme(self: WorldTilesetMeta) []const u8 {
        return self.parsed.value.theme;
    }

    pub fn atlas(self: WorldTilesetMeta) AtlasInfo {
        const json_atlas = self.parsed.value.atlas;
        return .{
            .path = json_atlas.path,
            .sprite_asset_id = json_atlas.sprite_asset_id,
            .width = json_atlas.width,
            .height = json_atlas.height,
        };
    }

    pub fn tileSize(self: WorldTilesetMeta) f32 {
        return @floatFromInt(self.parsed.value.tile_size);
    }

    pub fn columns(self: WorldTilesetMeta) u32 {
        return self.parsed.value.columns;
    }

    pub fn rows(self: WorldTilesetMeta) u32 {
        return self.parsed.value.rows;
    }

    pub fn tileCount(self: WorldTilesetMeta) u32 {
        return self.parsed.value.tile_count;
    }

    pub fn tileAtIndex(self: WorldTilesetMeta, index: usize) ?TileEntry {
        if (index >= self.parsed.value.tiles.len) return null;
        return jsonTileToEntry(self.parsed.value.tiles[index]);
    }

    pub fn sourceRectByName(self: WorldTilesetMeta, tile_name: []const u8) ?manifest.SourceRect {
        const id = self.name_to_id.get(tile_name) orelse return null;
        return self.sourceRectForId(id);
    }

    pub fn sourceRectForId(self: WorldTilesetMeta, id: u16) ?manifest.SourceRect {
        const index = self.id_to_index.get(id) orelse return null;
        return sourceRectFromTile(self.parsed.value.tiles[index]);
    }

    pub fn tileByName(self: WorldTilesetMeta, tile_name: []const u8) ?TileEntry {
        const id = self.name_to_id.get(tile_name) orelse return null;
        const index = self.id_to_index.get(id) orelse return null;
        return jsonTileToEntry(self.parsed.value.tiles[index]);
    }

    /// Returned animation slices are valid until this meta object is deinitialized.
    pub fn animationByName(self: WorldTilesetMeta, animation_name: []const u8) ?TileAnimation {
        return self.animations.get(animation_name);
    }
};

fn sourceRectFromTile(tile: JsonTileEntry) manifest.SourceRect {
    return .{
        .x = tile.x,
        .y = tile.y,
        .w = tile.width,
        .h = tile.height,
    };
}

fn jsonTileToEntry(tile: JsonTileEntry) TileEntry {
    return .{
        .id = tile.id,
        .name = tile.name,
        .category = tile.category,
        .column = tile.column,
        .row = tile.row,
        .x = tile.x,
        .y = tile.y,
        .width = tile.width,
        .height = tile.height,
        .properties = .{
            .layer = tile.properties.layer,
            .terrain = tile.properties.terrain,
            .walkable = tile.properties.walkable,
            .blocks_movement = tile.properties.blocks_movement,
            .blocks_vision = tile.properties.blocks_vision,
        },
    };
}

pub fn sourceRectForIndex(index: u16, columns: u32, tile_size: f32) manifest.SourceRect {
    const col = @as(f32, @floatFromInt(index % columns));
    const row = @as(f32, @floatFromInt(index / columns));
    return .{
        .x = col * tile_size,
        .y = row * tile_size,
        .w = tile_size,
        .h = tile_size,
    };
}

pub fn load(
    allocator: std.mem.Allocator,
    asset_store: @import("assets.zig").AssetStore,
    metadata_path: []const u8,
) !WorldTilesetMeta {
    const loaded = try atlas_meta_common.readJsonAsset(allocator, asset_store, metadata_path, 4 * 1024 * 1024, JsonRoot);
    return finishLoad(allocator, loaded.bytes, loaded.parsed, .world_tileset);
}

pub fn parse(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    linked_sprite_id: ?manifest.SpriteAssetId,
) !WorldTilesetMeta {
    const owned = try allocator.dupe(u8, bytes);

    const parsed = std.json.parseFromSlice(JsonRoot, allocator, owned, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        allocator.free(owned);
        return err;
    };

    return finishLoad(allocator, owned, parsed, linked_sprite_id);
}

fn finishLoad(
    allocator: std.mem.Allocator,
    bytes: []u8,
    parsed: std.json.Parsed(JsonRoot),
    linked_sprite_id: ?manifest.SpriteAssetId,
) !WorldTilesetMeta {
    errdefer atlas_meta_common.deinitJsonAsset(allocator, bytes, &parsed);
    try validateRoot(&parsed.value);

    if (linked_sprite_id) |sprite_id| {
        if (sprite_id != .world_tileset) return atlas_meta_common.LayoutMismatch.UnsupportedSpriteAsset;
        try manifest.validateAtlasMetadata(sprite_id, parsed.value.atlas.path, parsed.value.atlas.sprite_asset_id);
    }

    var names = try allocator.alloc([]const u8, parsed.value.tiles.len);
    defer allocator.free(names);
    var ids = try allocator.alloc(u16, parsed.value.tiles.len);
    defer allocator.free(ids);

    for (parsed.value.tiles, 0..) |tile, index| {
        names[index] = tile.name;
        ids[index] = tile.id;
    }

    var indexes = try atlas_meta_common.buildEntryIndexes(allocator, names, ids);
    errdefer {
        indexes.id_to_index.deinit();
        indexes.name_to_id.deinit();
    }

    var animations = try atlas_meta_common.parseAnimationValue(allocator, parsed.value.animations);
    errdefer atlas_meta_common.deinitAnimationTable(&animations, allocator);
    try atlas_meta_common.validateAnimationTileIds(&animations, &indexes.id_to_index);

    return .{
        .allocator = allocator,
        .bytes = bytes,
        .parsed = parsed,
        .name_to_id = indexes.name_to_id,
        .id_to_index = indexes.id_to_index,
        .animations = animations,
    };
}

fn validateRoot(root: *const JsonRoot) !void {
    if (root.tile_size != @as(u32, @intFromFloat(required_tile_size))) {
        return atlas_meta_common.LayoutMismatch.AtlasLayoutMismatch;
    }
    if (root.columns == 0 or root.rows == 0) {
        return atlas_meta_common.LayoutMismatch.AtlasLayoutMismatch;
    }
    if (root.tile_count != root.tiles.len) {
        return atlas_meta_common.LayoutMismatch.AtlasSpriteCountMismatch;
    }
    const cell_count = try atlas_meta_common.checkedGridCellCount(root.columns, root.rows);
    if (@as(u64, root.tile_count) > cell_count) {
        return atlas_meta_common.LayoutMismatch.AtlasLayoutMismatch;
    }
    try atlas_meta_common.validateAtlasDimensions(
        root.atlas.width,
        root.atlas.height,
        root.columns,
        root.rows,
        root.tile_size,
        root.tile_size,
    );
    for (root.tiles) |tile| {
        try atlas_meta_common.validateGridEntry(
            tile.id,
            root.columns,
            root.rows,
            root.tile_size,
            root.tile_size,
            tile.column,
            tile.row,
            tile.x,
            tile.y,
            tile.width,
            tile.height,
        );
    }
}

test "world tileset metadata resolves source rects by filename" {
    const asset_store = @import("assets.zig").AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    const metadata_path = manifest.spriteSpec(.world_tileset).metadata_path.?;
    var meta = try load(std.testing.allocator, asset_store, metadata_path);
    defer meta.deinit();

    try std.testing.expectEqual(required_tile_size, meta.tileSize());
    try std.testing.expect(meta.columns() > 0);
    try std.testing.expect(meta.rows() > 0);
    try std.testing.expectEqual(meta.tileCount(), meta.parsed.value.tiles.len);

    const grass = meta.sourceRectByName("grass") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 0), grass.x);
    try std.testing.expectEqual(@as(f32, 0), grass.y);
    try std.testing.expectEqual(required_tile_size, grass.w);

    const water = meta.sourceRectByName("water_1") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(required_tile_size, water.w);
    try std.testing.expect(meta.sourceRectForId(9999) == null);
}

test "world tileset metadata parses installed json" {
    const asset_store = @import("assets.zig").AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    const metadata_path = manifest.spriteSpec(.world_tileset).metadata_path.?;
    var meta = try load(std.testing.allocator, asset_store, metadata_path);
    defer meta.deinit();

    try std.testing.expectEqual(@as(u32, 1), meta.version());
    try std.testing.expectEqualStrings("grim_dark_world_tileset", meta.name());
    try std.testing.expectEqualStrings("sprites/world_tileset.png", meta.atlas().path);
    try std.testing.expectEqualStrings("world_tileset", meta.atlas().sprite_asset_id);

    const grass = meta.tileByName("grass") orelse return error.TestExpectedEqual;
    try std.testing.expect(grass.properties.walkable);
    try std.testing.expectEqualStrings("grass", grass.properties.terrain);

    const void_tile = meta.tileByName("void_pit") orelse return error.TestExpectedEqual;
    try std.testing.expect(!void_tile.properties.walkable);
    try std.testing.expect(void_tile.properties.blocks_movement);
}

test "world tileset water animation resolves by name" {
    const asset_store = @import("assets.zig").AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    const metadata_path = manifest.spriteSpec(.world_tileset).metadata_path.?;
    var meta = try load(std.testing.allocator, asset_store, metadata_path);
    defer meta.deinit();

    const water = meta.animationByName("water") orelse return error.TestExpectedEqual;

    try std.testing.expect(water.tile_ids.len > 0);
    try std.testing.expect(water.frame_duration_ms > 0);

    for (water.tile_ids) |tile_id| {
        try std.testing.expect(meta.sourceRectForId(tile_id) != null);
    }
}

test "world tileset parse rejects invalid layout without leaking" {
    const json =
        \\{"version":1,"name":"x","theme":"x","atlas":{"path":"sprites/world_tileset.png","sprite_asset_id":"world_tileset","width":32,"height":32},"tile_size":16,"columns":1,"rows":1,"tile_count":0,"tiles":[]}
    ;
    try std.testing.expectError(
        atlas_meta_common.LayoutMismatch.AtlasLayoutMismatch,
        parse(std.testing.allocator, json, .world_tileset),
    );
}

test "world tileset parse rejects source rects that do not match grid position" {
    const json =
        \\{"version":1,"name":"x","theme":"x","atlas":{"path":"sprites/world_tileset.png","sprite_asset_id":"world_tileset","width":32,"height":32},"tile_size":32,"columns":1,"rows":1,"tile_count":1,"tiles":[{"id":0,"name":"x","category":"x","column":0,"row":0,"x":16,"y":0,"width":32,"height":32,"properties":{"layer":"ground","terrain":"x","walkable":true,"blocks_movement":false,"blocks_vision":false}}]}
    ;
    try std.testing.expectError(
        atlas_meta_common.LayoutMismatch.AtlasLayoutMismatch,
        parse(std.testing.allocator, json, .world_tileset),
    );
}

test "world tileset parse rejects oversized grid products without overflow" {
    const json =
        \\{"version":1,"name":"x","theme":"x","atlas":{"path":"sprites/world_tileset.png","sprite_asset_id":"world_tileset","width":1,"height":1},"tile_size":32,"columns":4294967295,"rows":4294967295,"tile_count":0,"tiles":[]}
    ;
    try std.testing.expectError(
        atlas_meta_common.LayoutMismatch.AtlasLayoutMismatch,
        parse(std.testing.allocator, json, .world_tileset),
    );
}

test "world tileset load uses manifest metadata path" {
    const asset_store = @import("assets.zig").AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    const metadata_path = manifest.spriteSpec(.world_tileset).metadata_path.?;
    var meta = try load(std.testing.allocator, asset_store, metadata_path);
    defer meta.deinit();

    try std.testing.expectEqualStrings(metadata_path, manifest.spriteSpec(.world_tileset).metadata_path.?);
}
