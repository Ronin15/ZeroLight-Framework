// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Startup runtime asset catalog.
//! The engine preloads this catalog once and game/render/audio hot paths use
//! stable asset IDs instead of path strings.

const std = @import("std");
const AssetCache = @import("cache.zig").AssetCache;
const AssetStore = @import("assets.zig").AssetStore;
const AudioAssetId = manifest.AudioAssetId;
const AudioService = @import("../app/audio.zig").AudioService;
const Rect = @import("../render/renderer.zig").Rect;
const Renderer = @import("../render/renderer.zig").Renderer;
const SpriteAssetId = manifest.SpriteAssetId;
const TextureId = @import("../render/resources.zig").TextureId;
const TextureLease = @import("cache.zig").TextureLease;
const log = @import("../core/logging.zig").assets;
const manifest = @import("manifest.zig");

pub const AssetStatus = enum {
    not_loaded,
    available,
    unavailable,
};

pub const PreparedSprite = struct {
    texture: TextureId,
    source_rect: ?Rect = null,
};

pub const RuntimeAssets = struct {
    sprite_slots: [manifest.sprite_asset_count]SpriteSlot = initSpriteSlots(),
    audio_status: [manifest.audio_asset_count]AssetStatus = initAudioStatus(),

    pub fn init() RuntimeAssets {
        return .{};
    }

    pub fn preload(
        self: *RuntimeAssets,
        asset_store: AssetStore,
        cache: *AssetCache,
        renderer: *Renderer,
        audio: *AudioService,
    ) !void {
        for (manifest.sprite_assets) |spec| {
            try self.preloadSprite(asset_store, cache, renderer, spec);
        }
        for (manifest.audio_assets) |spec| {
            const available = try audio.preloadAudio(spec.id, spec.path, spec.kind, spec.predecode);
            self.audio_status[manifest.audioIndex(spec.id)] = if (available) .available else .unavailable;
        }
    }

    pub fn deinit(self: *RuntimeAssets, cache: *AssetCache, renderer: *Renderer) void {
        for (&self.sprite_slots) |*slot| {
            cache.releaseTexture(renderer, &slot.lease);
            slot.* = .{};
        }
        self.audio_status = initAudioStatus();
    }

    pub fn sprite(self: *const RuntimeAssets, id: SpriteAssetId) ?PreparedSprite {
        const slot = self.sprite_slots[manifest.spriteIndex(id)];
        if (slot.status != .available or !slot.lease.id.isValid()) return null;
        return .{
            .texture = slot.lease.id,
            .source_rect = slot.source_rect,
        };
    }

    pub fn spriteStatus(self: *const RuntimeAssets, id: SpriteAssetId) AssetStatus {
        return self.sprite_slots[manifest.spriteIndex(id)].status;
    }

    pub fn audioStatus(self: *const RuntimeAssets, id: AudioAssetId) AssetStatus {
        return self.audio_status[manifest.audioIndex(id)];
    }

    fn preloadSprite(
        self: *RuntimeAssets,
        asset_store: AssetStore,
        cache: *AssetCache,
        renderer: *Renderer,
        spec: manifest.SpriteAssetSpec,
    ) !void {
        try @import("assets.zig").validateRelativePath(spec.path);
        if (asset_store.resolveReadablePath(spec.path)) |path| {
            asset_store.allocator.free(path);
        } else |err| switch (err) {
            error.FileNotFound => {
                log.warn("startup sprite asset unavailable \"{s}\": {}", .{ spec.path, err });
                self.sprite_slots[manifest.spriteIndex(spec.id)].status = .unavailable;
                return;
            },
            else => return err,
        }

        const lease = try cache.acquireTexture(renderer, spec.path);
        self.sprite_slots[manifest.spriteIndex(spec.id)] = .{
            .status = .available,
            .lease = lease,
            .source_rect = sourceRect(spec.source_rect),
        };
    }
};

const SpriteSlot = struct {
    status: AssetStatus = .not_loaded,
    lease: TextureLease = .{},
    source_rect: ?Rect = null,
};

fn initSpriteSlots() [manifest.sprite_asset_count]SpriteSlot {
    return [_]SpriteSlot{.{}} ** manifest.sprite_asset_count;
}

fn initAudioStatus() [manifest.audio_asset_count]AssetStatus {
    return [_]AssetStatus{.not_loaded} ** manifest.audio_asset_count;
}

fn sourceRect(value: ?manifest.SourceRect) ?Rect {
    const rect = value orelse return null;
    return .{
        .x = rect.x,
        .y = rect.y,
        .w = rect.w,
        .h = rect.h,
    };
}

test "runtime asset catalog starts with unloaded status" {
    const runtime_assets = RuntimeAssets.init();

    try std.testing.expectEqual(AssetStatus.not_loaded, runtime_assets.spriteStatus(.demo_tile));
    try std.testing.expectEqual(AssetStatus.not_loaded, runtime_assets.audioStatus(.demo_music));
}

test "missing startup sprite marks id unavailable without requiring renderer access" {
    var runtime_assets = RuntimeAssets.init();
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var cache: AssetCache = undefined;
    var renderer: Renderer = undefined;

    try runtime_assets.preloadSprite(asset_store, &cache, &renderer, .{
        .id = .demo_tile,
        .path = "missing/nope.png",
    });

    try std.testing.expectEqual(AssetStatus.unavailable, runtime_assets.spriteStatus(.demo_tile));
    try std.testing.expect(runtime_assets.sprite(.demo_tile) == null);
}
