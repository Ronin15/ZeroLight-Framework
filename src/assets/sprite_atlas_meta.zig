// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Sprite atlas metadata loaded once at setup. Construction can resolve authoring
//! names to stable numeric IDs; hot render prep resolves IDs through direct
//! source-rect tables instead of storing names or rects in gameplay state.

const std = @import("std");
const atlas_meta_common = @import("atlas_meta_common.zig");
const manifest = @import("manifest.zig");

pub const SpriteEntry = struct {
    id: u16,
    name: []const u8,
    category: []const u8,
    column: u32,
    row: u32,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const AtlasInfo = struct {
    path: []const u8,
    sprite_asset_id: []const u8,
    width: u32,
    height: u32,
};

const JsonSpriteEntry = struct {
    id: u16,
    name: []const u8,
    category: []const u8,
    column: u32,
    row: u32,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
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
    frame_width: u32,
    frame_height: u32,
    columns: u32,
    rows: u32,
    sprite_count: u32,
    sprites: []JsonSpriteEntry,
};

pub const SpriteAtlasMeta = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    parsed: std.json.Parsed(JsonRoot),
    name_to_id: std.StringHashMap(u16),
    id_to_index: std.AutoHashMap(u16, usize),
    source_rect_valid: []bool,
    source_rects: []manifest.SourceRect,

    pub fn deinit(self: *SpriteAtlasMeta) void {
        self.allocator.free(self.source_rects);
        self.allocator.free(self.source_rect_valid);
        self.id_to_index.deinit();
        self.name_to_id.deinit();
        atlas_meta_common.deinitJsonAsset(self.allocator, self.bytes, &self.parsed);
        self.* = undefined;
    }

    pub fn name(self: SpriteAtlasMeta) []const u8 {
        return self.parsed.value.name;
    }

    /// Returned `AtlasInfo` slices (`path`, `sprite_asset_id`) borrow the parsed
    /// JSON and are valid until this meta object is deinitialized.
    pub fn atlas(self: SpriteAtlasMeta) AtlasInfo {
        const json_atlas = self.parsed.value.atlas;
        return .{
            .path = json_atlas.path,
            .sprite_asset_id = json_atlas.sprite_asset_id,
            .width = json_atlas.width,
            .height = json_atlas.height,
        };
    }

    pub fn frameWidth(self: SpriteAtlasMeta) f32 {
        return @floatFromInt(self.parsed.value.frame_width);
    }

    pub fn frameHeight(self: SpriteAtlasMeta) f32 {
        return @floatFromInt(self.parsed.value.frame_height);
    }

    pub fn columns(self: SpriteAtlasMeta) u32 {
        return self.parsed.value.columns;
    }

    pub fn rows(self: SpriteAtlasMeta) u32 {
        return self.parsed.value.rows;
    }

    pub fn spriteCount(self: SpriteAtlasMeta) u32 {
        return self.parsed.value.sprite_count;
    }

    pub fn sourceRectByName(self: SpriteAtlasMeta, sprite_name: []const u8) ?manifest.SourceRect {
        const id = self.name_to_id.get(sprite_name) orelse return null;
        return self.sourceRectForId(id);
    }

    pub fn sourceRectForId(self: SpriteAtlasMeta, id: u16) ?manifest.SourceRect {
        const index: usize = id;
        if (index >= self.source_rect_valid.len or !self.source_rect_valid[index]) return null;
        return self.source_rects[index];
    }

    /// Returned `SpriteEntry` slices (`name`, `category`) borrow the parsed JSON
    /// and are valid until this meta object is deinitialized.
    pub fn spriteByName(self: SpriteAtlasMeta, sprite_name: []const u8) ?SpriteEntry {
        const id = self.name_to_id.get(sprite_name) orelse return null;
        const index = self.id_to_index.get(id) orelse return null;
        return jsonSpriteToEntry(self.parsed.value.sprites[index]);
    }
};

fn sourceRectFromSprite(sprite: JsonSpriteEntry) manifest.SourceRect {
    return .{
        .x = sprite.x,
        .y = sprite.y,
        .w = sprite.width,
        .h = sprite.height,
    };
}

fn jsonSpriteToEntry(sprite: JsonSpriteEntry) SpriteEntry {
    return .{
        .id = sprite.id,
        .name = sprite.name,
        .category = sprite.category,
        .column = sprite.column,
        .row = sprite.row,
        .x = sprite.x,
        .y = sprite.y,
        .width = sprite.width,
        .height = sprite.height,
    };
}

pub fn load(
    allocator: std.mem.Allocator,
    asset_store: @import("assets.zig").AssetStore,
    linked_sprite_id: manifest.SpriteAssetId,
    metadata_path: []const u8,
) !SpriteAtlasMeta {
    const loaded = try atlas_meta_common.readJsonAsset(allocator, asset_store, metadata_path, 2 * 1024 * 1024, JsonRoot);
    errdefer atlas_meta_common.deinitJsonAsset(allocator, loaded.bytes, &loaded.parsed);
    try validateRoot(&loaded.parsed.value);
    try manifest.validateAtlasMetadata(
        linked_sprite_id,
        loaded.parsed.value.atlas.path,
        loaded.parsed.value.atlas.sprite_asset_id,
    );

    var names = try allocator.alloc([]const u8, loaded.parsed.value.sprites.len);
    defer allocator.free(names);
    var ids = try allocator.alloc(u16, loaded.parsed.value.sprites.len);
    defer allocator.free(ids);

    for (loaded.parsed.value.sprites, 0..) |sprite, index| {
        names[index] = sprite.name;
        ids[index] = sprite.id;
    }

    var indexes = try atlas_meta_common.buildEntryIndexes(allocator, names, ids);
    errdefer {
        indexes.id_to_index.deinit();
        indexes.name_to_id.deinit();
    }
    const source_rect_table = try buildSourceRectTable(allocator, loaded.parsed.value.sprites);
    errdefer {
        allocator.free(source_rect_table.rects);
        allocator.free(source_rect_table.valid);
    }

    return .{
        .allocator = allocator,
        .bytes = loaded.bytes,
        .parsed = loaded.parsed,
        .name_to_id = indexes.name_to_id,
        .id_to_index = indexes.id_to_index,
        .source_rect_valid = source_rect_table.valid,
        .source_rects = source_rect_table.rects,
    };
}

const SourceRectTable = struct {
    valid: []bool,
    rects: []manifest.SourceRect,
};

// Dense lookup table keyed by sprite id, so its size follows the largest id
// rather than the sprite count. Sprite ids are validated u16s (< grid cell
// count, never maxInt(u16)) before this runs, so the table is already bounded
// to <= max_source_rect_entries; the explicit cap documents that bound and
// guards against a sparse, high-id sidecar forcing a wasteful allocation.
const max_source_rect_entries: usize = std.math.maxInt(u16);

fn buildSourceRectTable(allocator: std.mem.Allocator, sprites: []const JsonSpriteEntry) !SourceRectTable {
    var max_id: usize = 0;
    for (sprites) |sprite| {
        max_id = @max(max_id, sprite.id);
    }
    const count = if (sprites.len == 0) 0 else max_id + 1;
    if (count > max_source_rect_entries) {
        return atlas_meta_common.LayoutMismatch.AtlasLayoutMismatch;
    }
    const valid = try allocator.alloc(bool, count);
    errdefer allocator.free(valid);
    const rects = try allocator.alloc(manifest.SourceRect, count);
    errdefer allocator.free(rects);

    @memset(valid, false);
    @memset(rects, manifest.SourceRect{ .x = 0, .y = 0, .w = 0, .h = 0 });
    for (sprites) |sprite| {
        const index: usize = sprite.id;
        valid[index] = true;
        rects[index] = sourceRectFromSprite(sprite);
    }
    return .{ .valid = valid, .rects = rects };
}

fn validateRoot(root: *const JsonRoot) !void {
    if (root.sprite_count != root.sprites.len) {
        return atlas_meta_common.LayoutMismatch.AtlasSpriteCountMismatch;
    }
    if (root.columns == 0 or root.rows == 0 or root.frame_width == 0 or root.frame_height == 0) {
        return atlas_meta_common.LayoutMismatch.AtlasLayoutMismatch;
    }
    const cell_count = try atlas_meta_common.checkedGridCellCount(root.columns, root.rows);
    if (@as(u64, root.sprite_count) > cell_count) {
        return atlas_meta_common.LayoutMismatch.AtlasLayoutMismatch;
    }
    try atlas_meta_common.validateAtlasDimensions(
        root.atlas.width,
        root.atlas.height,
        root.columns,
        root.rows,
        root.frame_width,
        root.frame_height,
    );
    for (root.sprites) |sprite| {
        try atlas_meta_common.validateGridEntry(
            sprite.id,
            root.columns,
            root.rows,
            root.frame_width,
            root.frame_height,
            sprite.column,
            sprite.row,
            sprite.x,
            sprite.y,
            sprite.width,
            sprite.height,
        );
    }
}

fn expectSpriteNameAligned(meta: SpriteAtlasMeta, sprite_name: []const u8) !void {
    const by_name = meta.sourceRectByName(sprite_name) orelse return error.TestExpectedEqual;
    const entry = meta.spriteByName(sprite_name) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(by_name.x, entry.x);
    try std.testing.expectEqual(by_name.y, entry.y);
    try std.testing.expectEqual(by_name.w, entry.width);
    try std.testing.expectEqual(by_name.h, entry.height);
}

test "sprite atlas load rejects linked sprite id mismatches" {
    const asset_store = @import("assets.zig").AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    const metadata_path = manifest.spriteSpec(.grim_characters).metadata_path.?;
    try std.testing.expectError(
        error.AtlasManifestMismatch,
        load(std.testing.allocator, asset_store, .grim_items, metadata_path),
    );
}

test "sprite atlas parse rejects source rects that do not match grid position" {
    const json =
        \\{"version":1,"name":"x","theme":"x","atlas":{"path":"sprites/grim_items.png","sprite_asset_id":"grim_items","width":16,"height":16},"frame_width":16,"frame_height":16,"columns":1,"rows":1,"sprite_count":1,"sprites":[{"id":0,"name":"x","category":"x","column":0,"row":0,"x":8,"y":0,"width":16,"height":16}]}
    ;
    const parsed = try std.json.parseFromSlice(JsonRoot, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectError(
        atlas_meta_common.LayoutMismatch.AtlasLayoutMismatch,
        validateRoot(&parsed.value),
    );
}

test "sprite atlas parse rejects oversized grid products without overflow" {
    const json =
        \\{"version":1,"name":"x","theme":"x","atlas":{"path":"sprites/grim_items.png","sprite_asset_id":"grim_items","width":1,"height":1},"frame_width":65536,"frame_height":65536,"columns":65536,"rows":65536,"sprite_count":0,"sprites":[]}
    ;
    const parsed = try std.json.parseFromSlice(JsonRoot, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectError(
        atlas_meta_common.LayoutMismatch.AtlasLayoutMismatch,
        validateRoot(&parsed.value),
    );
}

test "grim characters metadata parses installed json" {
    const asset_store = @import("assets.zig").AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    const metadata_path = manifest.spriteSpec(.grim_characters).metadata_path.?;
    var meta = try load(std.testing.allocator, asset_store, .grim_characters, metadata_path);
    defer meta.deinit();

    try std.testing.expectEqualStrings("grim_dark_characters", meta.name());
    try std.testing.expect(meta.spriteCount() > 0);
    try std.testing.expectEqual(meta.spriteCount(), meta.parsed.value.sprites.len);
    try std.testing.expect(meta.frameWidth() > 0);
    try std.testing.expect(meta.frameHeight() > 0);

    const adventurer = meta.spriteByName("adventurer") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("hero", adventurer.category);

    const source = meta.sourceRectByName("adventurer") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 0), source.x);
    try std.testing.expectEqual(@as(f32, 0), source.y);
    try std.testing.expect(meta.sourceRectForId(9999) == null);

    const sample_names = [_][]const u8{ "adventurer", "knight", "skeleton", "death_knight" };
    for (sample_names) |sprite_name| {
        try expectSpriteNameAligned(meta, sprite_name);
    }
}

test "grim items metadata parses installed json" {
    const asset_store = @import("assets.zig").AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    const metadata_path = manifest.spriteSpec(.grim_items).metadata_path.?;
    var meta = try load(std.testing.allocator, asset_store, .grim_items, metadata_path);
    defer meta.deinit();

    try std.testing.expectEqualStrings("grim_dark_items", meta.name());
    try std.testing.expect(meta.spriteCount() > 0);
    try std.testing.expectEqual(meta.spriteCount(), meta.parsed.value.sprites.len);
    try std.testing.expect(meta.frameWidth() > 0);

    const sword = meta.spriteByName("sword") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("weapon_melee", sword.category);

    const sample_names = [_][]const u8{ "sword", "health_potion", "iron_key", "torch" };
    for (sample_names) |sprite_name| {
        try expectSpriteNameAligned(meta, sprite_name);
    }
}
