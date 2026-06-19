// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");

pub const SpriteAssetId = enum(u16) {
    demo_tile,
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

pub const SpriteAssetSpec = struct {
    id: SpriteAssetId,
    path: []const u8,
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
};

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
