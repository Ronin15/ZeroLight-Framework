// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AssetStore = @import("assets.zig").AssetStore;
const manifest = @import("manifest.zig");

pub const LayoutMismatch = error{
    AtlasLayoutMismatch,
    AtlasSpriteCountMismatch,
    DuplicateEntryName,
    DuplicateEntryId,
    InvalidAnimationEntry,
    MissingMetadataPath,
    UnsupportedSpriteAsset,
};

/// Animation frame lists borrow from the owning tileset meta object; do not use
/// after `WorldTilesetMeta.deinit`.
pub const TileAnimation = struct {
    tile_ids: []const u16,
    frame_duration_ms: u32,
};

/// Convenience lookup for `manifest.spriteSpec(id).metadata_path`.
pub fn metadataPathFor(id: manifest.SpriteAssetId) LayoutMismatch![]const u8 {
    const spec = manifest.spriteSpec(id);
    return spec.metadata_path orelse error.MissingMetadataPath;
}

pub fn readJsonAsset(
    allocator: std.mem.Allocator,
    asset_store: AssetStore,
    metadata_path: []const u8,
    max_bytes: usize,
    comptime T: type,
) !struct { bytes: []u8, parsed: std.json.Parsed(T) } {
    const path = try asset_store.resolveReadablePath(metadata_path);
    defer asset_store.allocator.free(path);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(asset_store.io, path, allocator, .limited(max_bytes));
    errdefer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(T, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });

    return .{ .bytes = bytes, .parsed = parsed };
}

pub fn deinitJsonAsset(
    allocator: std.mem.Allocator,
    bytes: []u8,
    parsed: anytype,
) void {
    parsed.deinit();
    allocator.free(bytes);
}

pub fn buildEntryIndexes(
    allocator: std.mem.Allocator,
    names: []const []const u8,
    ids: []const u16,
) !struct {
    name_to_id: std.StringHashMap(u16),
    id_to_index: std.AutoHashMap(u16, usize),
} {
    if (names.len != ids.len) return error.AtlasSpriteCountMismatch;

    var name_to_id = std.StringHashMap(u16).init(allocator);
    errdefer name_to_id.deinit();

    var id_to_index = std.AutoHashMap(u16, usize).init(allocator);
    errdefer id_to_index.deinit();

    for (names, ids, 0..) |name, id, index| {
        const name_gop = try name_to_id.getOrPut(name);
        if (name_gop.found_existing) return error.DuplicateEntryName;
        name_gop.value_ptr.* = id;

        const id_gop = try id_to_index.getOrPut(id);
        if (id_gop.found_existing) return error.DuplicateEntryId;
        id_gop.value_ptr.* = index;
    }

    return .{ .name_to_id = name_to_id, .id_to_index = id_to_index };
}

pub fn validateGridEntry(
    id: u16,
    columns: u32,
    rows: u32,
    frame_w: u32,
    frame_h: u32,
    column: u32,
    row: u32,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
) LayoutMismatch!void {
    if (id == std.math.maxInt(u16)) return error.AtlasLayoutMismatch;
    if (columns == 0 or rows == 0 or frame_w == 0 or frame_h == 0) {
        return error.AtlasLayoutMismatch;
    }

    const cell_count = @as(u64, columns) * @as(u64, rows);
    const id_index: u64 = id;
    if (id_index >= cell_count) return error.AtlasLayoutMismatch;

    const expected_column = id_index % columns;
    const expected_row = id_index / columns;
    const expected_x = @as(f32, @floatFromInt(expected_column * frame_w));
    const expected_y = @as(f32, @floatFromInt(expected_row * frame_h));

    if (column != expected_column or row != expected_row) {
        return error.AtlasLayoutMismatch;
    }
    if (x != expected_x or y != expected_y) {
        return error.AtlasLayoutMismatch;
    }
    if (width != @as(f32, @floatFromInt(frame_w)) or height != @as(f32, @floatFromInt(frame_h))) {
        return error.AtlasLayoutMismatch;
    }
}

pub fn checkedGridCellCount(columns: u32, rows: u32) LayoutMismatch!u64 {
    return std.math.mul(u64, @as(u64, columns), @as(u64, rows)) catch error.AtlasLayoutMismatch;
}

pub fn validateAtlasDimensions(
    atlas_width: u32,
    atlas_height: u32,
    columns: u32,
    rows: u32,
    frame_width: u32,
    frame_height: u32,
) LayoutMismatch!void {
    const expected_width = std.math.mul(u64, @as(u64, columns), @as(u64, frame_width)) catch return error.AtlasLayoutMismatch;
    const expected_height = std.math.mul(u64, @as(u64, rows), @as(u64, frame_height)) catch return error.AtlasLayoutMismatch;
    if (expected_width > std.math.maxInt(u32) or expected_height > std.math.maxInt(u32)) {
        return error.AtlasLayoutMismatch;
    }
    if (atlas_width != @as(u32, @intCast(expected_width)) or atlas_height != @as(u32, @intCast(expected_height))) {
        return error.AtlasLayoutMismatch;
    }
}

pub fn parseAnimationValue(
    allocator: std.mem.Allocator,
    animations_value: ?std.json.Value,
) !std.StringHashMap(TileAnimation) {
    var animations = std.StringHashMap(TileAnimation).init(allocator);
    errdefer deinitAnimationTable(&animations, allocator);

    const root = animations_value orelse return animations;
    if (root != .object) return animations;

    var it = root.object.iterator();
    while (it.next()) |entry| {
        const animation_value = entry.value_ptr.*;
        if (animation_value != .object) return error.InvalidAnimationEntry;

        const tile_ids_value = animation_value.object.get("tile_ids") orelse return error.InvalidAnimationEntry;
        const frame_duration_value = animation_value.object.get("frame_duration_ms") orelse return error.InvalidAnimationEntry;
        if (tile_ids_value != .array or frame_duration_value != .integer) return error.InvalidAnimationEntry;
        if (frame_duration_value.integer < 0 or frame_duration_value.integer > std.math.maxInt(u32)) {
            return error.InvalidAnimationEntry;
        }

        const owned_ids = try allocator.alloc(u16, tile_ids_value.array.items.len);
        errdefer allocator.free(owned_ids);

        for (tile_ids_value.array.items, owned_ids) |item, *out| {
            if (item != .integer) return error.InvalidAnimationEntry;
            if (item.integer < 0 or item.integer > std.math.maxInt(u16)) return error.InvalidAnimationEntry;
            out.* = @intCast(item.integer);
        }

        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);

        const gop = try animations.getOrPut(key);
        if (gop.found_existing) {
            return error.DuplicateEntryName;
        }

        gop.value_ptr.* = .{
            .tile_ids = owned_ids,
            .frame_duration_ms = @intCast(frame_duration_value.integer),
        };
    }

    return animations;
}

pub fn validateAnimationTileIds(
    animations: *const std.StringHashMap(TileAnimation),
    id_to_index: *const std.AutoHashMap(u16, usize),
) LayoutMismatch!void {
    var it = animations.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.tile_ids) |tile_id| {
            if (!id_to_index.contains(tile_id)) return error.InvalidAnimationEntry;
        }
    }
}

pub fn deinitAnimationTable(table: *std.StringHashMap(TileAnimation), allocator: std.mem.Allocator) void {
    var it = table.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.tile_ids);
    }
    table.deinit();
}

test "readJsonAsset copies into caller allocator" {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    const JsonRoot = struct {
        version: u32,
    };

    const loaded = try readJsonAsset(
        std.testing.allocator,
        asset_store,
        "sprites/world_tileset.json",
        1024 * 1024,
        JsonRoot,
    );

    defer deinitJsonAsset(std.testing.allocator, loaded.bytes, &loaded.parsed);
    try std.testing.expectEqual(@as(u32, 1), loaded.parsed.value.version);
}

test "readJsonAsset frees the duped bytes exactly once when parse fails" {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    const Mismatch = struct {
        // A required field the sidecar does not contain forces parseFromSlice to
        // fail after the bytes are duped; the errdefer must free them exactly
        // once (a double free here would trip the testing allocator).
        field_absent_from_file: u32,
    };

    try std.testing.expectError(
        error.MissingField,
        readJsonAsset(
            std.testing.allocator,
            asset_store,
            "sprites/world_tileset.json",
            1024 * 1024,
            Mismatch,
        ),
    );
}

test "buildEntryIndexes rejects duplicate ids and names" {
    const names = [_][]const u8{ "grass", "dirt" };
    const ids = [_]u16{ 0, 0 };
    try std.testing.expectError(
        error.DuplicateEntryId,
        buildEntryIndexes(std.testing.allocator, &names, &ids),
    );
}

test "validateGridEntry rejects sentinel ids" {
    try std.testing.expectError(
        error.AtlasLayoutMismatch,
        validateGridEntry(
            std.math.maxInt(u16),
            256,
            256,
            32,
            32,
            255,
            255,
            8160,
            8160,
            32,
            32,
        ),
    );
}

test "parseAnimationValue rejects invalid animation entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"water":{"frame_duration_ms":120}}
    ,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectError(
        error.InvalidAnimationEntry,
        parseAnimationValue(allocator, parsed.value),
    );
}

test "parseAnimationValue rejects out-of-range integer fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"bad":{"tile_ids":[-1],"frame_duration_ms":120}}
    ,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectError(
        error.InvalidAnimationEntry,
        parseAnimationValue(allocator, parsed.value),
    );

    const parsed_duration = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"bad":{"tile_ids":[0],"frame_duration_ms":4294967296}}
    ,
        .{},
    );
    defer parsed_duration.deinit();

    try std.testing.expectError(
        error.InvalidAnimationEntry,
        parseAnimationValue(allocator, parsed_duration.value),
    );
}

test "validateAnimationTileIds rejects unknown tile ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var animations = std.StringHashMap(TileAnimation).init(allocator);
    defer deinitAnimationTable(&animations, allocator);

    const tile_ids = try allocator.alloc(u16, 1);
    tile_ids[0] = 99;
    try animations.put(try allocator.dupe(u8, "water"), .{
        .tile_ids = tile_ids,
        .frame_duration_ms = 120,
    });

    var id_to_index = std.AutoHashMap(u16, usize).init(allocator);
    defer id_to_index.deinit();
    try id_to_index.put(0, 0);

    try std.testing.expectError(
        error.InvalidAnimationEntry,
        validateAnimationTileIds(&animations, &id_to_index),
    );
}

test "metadataPathFor resolves manifest metadata paths" {
    try std.testing.expectEqualStrings(
        "sprites/world_tileset.json",
        try metadataPathFor(.world_tileset),
    );
    try std.testing.expectError(error.MissingMetadataPath, metadataPathFor(.demo_tile));
}

test "validateGridEntry rejects rects that do not match id grid position" {
    try validateGridEntry(5, 4, 2, 16, 24, 1, 1, 16, 24, 16, 24);
    try std.testing.expectError(
        error.AtlasLayoutMismatch,
        validateGridEntry(5, 4, 2, 16, 24, 0, 1, 0, 24, 16, 24),
    );
    try std.testing.expectError(
        error.AtlasLayoutMismatch,
        validateGridEntry(8, 4, 2, 16, 24, 0, 2, 0, 48, 16, 24),
    );
}
