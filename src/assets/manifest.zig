// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");

pub const SpriteAssetId = enum(u16) {
    demo_tile,
    world_tileset,
    grim_characters,
    grim_items,
};

pub const AudioAssetId = enum(u16) {
    demo_music,
    collision_sfx,
    player_jet_sfx,
};

pub const AudioAssetKind = enum {
    sfx,
    music,
};

pub const SourceRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const AtlasMetaKind = enum {
    world_tileset,
    sprite_atlas,
};

pub const SpriteAssetSpec = struct {
    id: SpriteAssetId,
    path: []const u8,
    metadata_path: ?[]const u8 = null,
    metadata_kind: ?AtlasMetaKind = null,
    source_rect: ?SourceRect = null,
};

pub const AudioAssetSpec = struct {
    id: AudioAssetId,
    path: []const u8,
    kind: AudioAssetKind,
    predecode: bool,
};

pub const sprite_assets = [_]SpriteAssetSpec{
    .{
        .id = .demo_tile,
        .path = "sprites/demo_tile.png",
    },
    .{
        .id = .world_tileset,
        .path = "sprites/world_tileset.png",
        .metadata_path = "sprites/world_tileset.json",
        .metadata_kind = .world_tileset,
    },
    .{
        .id = .grim_characters,
        .path = "sprites/grim_characters.png",
        .metadata_path = "sprites/grim_characters.json",
        .metadata_kind = .sprite_atlas,
    },
    .{
        .id = .grim_items,
        .path = "sprites/grim_items.png",
        .metadata_path = "sprites/grim_items.json",
        .metadata_kind = .sprite_atlas,
    },
};

pub const AtlasManifestMismatch = error{
    AtlasManifestMismatch,
    MissingMetadataPath,
};

pub fn spriteSpec(id: SpriteAssetId) SpriteAssetSpec {
    return sprite_assets[spriteIndex(id)];
}

pub fn expectedMetadataKind(id: SpriteAssetId) ?AtlasMetaKind {
    return switch (id) {
        .demo_tile => null,
        .world_tileset => .world_tileset,
        .grim_characters, .grim_items => .sprite_atlas,
    };
}

pub fn validateAtlasMetadata(
    id: SpriteAssetId,
    atlas_path: []const u8,
    sprite_asset_id: []const u8,
) AtlasManifestMismatch!void {
    const spec = spriteSpec(id);
    const expected_id = @tagName(id);
    if (!std.mem.eql(u8, spec.path, atlas_path) or !std.mem.eql(u8, expected_id, sprite_asset_id)) {
        return error.AtlasManifestMismatch;
    }
}

pub const audio_assets = [_]AudioAssetSpec{
    .{
        .id = .demo_music,
        .path = "audio/music/demo_loop.wav",
        .kind = .music,
        .predecode = false,
    },
    .{
        .id = .collision_sfx,
        .path = "audio/sfx/collision.wav",
        .kind = .sfx,
        .predecode = true,
    },
    .{
        .id = .player_jet_sfx,
        .path = "audio/sfx/player_jet.wav",
        .kind = .sfx,
        .predecode = true,
    },
};

pub const sprite_asset_count = std.meta.fields(SpriteAssetId).len;
pub const audio_asset_count = std.meta.fields(AudioAssetId).len;

pub fn spriteIndex(id: SpriteAssetId) usize {
    return @intFromEnum(id);
}

pub fn audioIndex(id: AudioAssetId) usize {
    return @intFromEnum(id);
}

test "metadata manifest entries declare loader kind and sidecar together" {
    inline for (sprite_assets) |spec| {
        if (spec.metadata_path == null) {
            try std.testing.expect(spec.metadata_kind == null);
            continue;
        }
        try std.testing.expect(spec.metadata_kind != null);
    }
}

test "metadata manifest entries use the loader kind for each sprite id" {
    inline for (sprite_assets) |spec| {
        try std.testing.expectEqual(expectedMetadataKind(spec.id), spec.metadata_kind);
    }
}

test "validateAtlasMetadata rejects manifest mismatches" {
    try validateAtlasMetadata(.world_tileset, "sprites/world_tileset.png", "world_tileset");
    try validateAtlasMetadata(.grim_characters, "sprites/grim_characters.png", "grim_characters");
    try validateAtlasMetadata(.grim_items, "sprites/grim_items.png", "grim_items");
    try std.testing.expectError(
        error.AtlasManifestMismatch,
        validateAtlasMetadata(.world_tileset, "sprites/wrong.png", "world_tileset"),
    );
    try std.testing.expectError(
        error.AtlasManifestMismatch,
        validateAtlasMetadata(.world_tileset, "sprites/world_tileset.png", "grim_items"),
    );
    try std.testing.expectError(
        error.AtlasManifestMismatch,
        validateAtlasMetadata(.grim_characters, "sprites/grim_items.png", "grim_characters"),
    );
}

test "atlas metadata paths link to registered sprite assets" {
    try std.testing.expectEqualStrings("sprites/world_tileset.png", spriteSpec(.world_tileset).path);
    try std.testing.expectEqualStrings("sprites/world_tileset.json", spriteSpec(.world_tileset).metadata_path.?);
    try std.testing.expectEqualStrings("sprites/grim_characters.png", spriteSpec(.grim_characters).path);
    try std.testing.expectEqualStrings("sprites/grim_characters.json", spriteSpec(.grim_characters).metadata_path.?);
    try std.testing.expectEqualStrings("sprites/grim_items.png", spriteSpec(.grim_items).path);
    try std.testing.expectEqualStrings("sprites/grim_items.json", spriteSpec(.grim_items).metadata_path.?);
}

test "startup asset manifest covers every stable id once" {
    var sprite_seen = [_]bool{false} ** sprite_asset_count;
    for (sprite_assets) |spec| {
        const index = spriteIndex(spec.id);
        try std.testing.expect(!sprite_seen[index]);
        sprite_seen[index] = true;
    }
    for (sprite_seen) |seen| try std.testing.expect(seen);

    var audio_seen = [_]bool{false} ** audio_asset_count;
    for (audio_assets) |spec| {
        const index = audioIndex(spec.id);
        try std.testing.expect(!audio_seen[index]);
        audio_seen[index] = true;
    }
    for (audio_seen) |seen| try std.testing.expect(seen);
}
