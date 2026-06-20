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
const sprite_atlas_meta = @import("sprite_atlas_meta.zig");
const SpriteAtlasMeta = sprite_atlas_meta.SpriteAtlasMeta;
const TextureId = @import("../render/resources.zig").TextureId;
const TextureLease = @import("cache.zig").TextureLease;
const world_tileset_meta = @import("world_tileset_meta.zig");
const WorldTilesetMeta = world_tileset_meta.WorldTilesetMeta;
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

const AtlasMetaSlot = union(enum) {
    world_tileset: WorldTilesetMeta,
    sprite_atlas: SpriteAtlasMeta,

    fn deinit(self: *AtlasMetaSlot) void {
        switch (self.*) {
            .world_tileset => |*meta| meta.deinit(),
            .sprite_atlas => |*meta| meta.deinit(),
        }
    }
};

pub const RuntimeAssets = struct {
    allocator: std.mem.Allocator = undefined,
    sprite_slots: [manifest.sprite_asset_count]SpriteSlot = initSpriteSlots(),
    audio_status: [manifest.audio_asset_count]AssetStatus = initAudioStatus(),
    atlas_meta: [manifest.sprite_asset_count]?AtlasMetaSlot = initAtlasMetaSlots(),

    pub fn init() RuntimeAssets {
        return .{};
    }

    pub fn preload(
        self: *RuntimeAssets,
        allocator: std.mem.Allocator,
        asset_store: AssetStore,
        cache: *AssetCache,
        renderer: *Renderer,
        audio: *AudioService,
    ) !void {
        self.allocator = allocator;
        errdefer self.deinit(cache, renderer);

        for (manifest.sprite_assets) |spec| {
            try self.preloadSprite(asset_store, cache, renderer, spec);
        }
        try self.loadAtlasMetadata(asset_store, .{});
        for (manifest.audio_assets) |spec| {
            const available = try audio.preloadAudio(spec.id, spec.path, spec.kind, spec.predecode);
            self.audio_status[manifest.audioIndex(spec.id)] = if (available) .available else .unavailable;
        }
    }

    pub fn deinit(self: *RuntimeAssets, cache: *AssetCache, renderer: *Renderer) void {
        deinitAtlasMetaSlots(&self.atlas_meta);

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

    pub fn atlasMetaLoaded(self: *const RuntimeAssets, id: SpriteAssetId) bool {
        return self.atlas_meta[manifest.spriteIndex(id)] != null;
    }

    /// World tileset metadata lives in a separate loader type from character/item atlases.
    pub fn worldTilesetMeta(self: *const RuntimeAssets) ?*const WorldTilesetMeta {
        if (self.atlas_meta[manifest.spriteIndex(.world_tileset)]) |*slot| {
            return switch (slot.*) {
                .world_tileset => |*meta| meta,
                .sprite_atlas => null,
            };
        }
        return null;
    }

    /// Character and item atlases only. Use `worldTilesetMeta()` for `.world_tileset`.
    pub fn spriteAtlasMeta(self: *const RuntimeAssets, id: SpriteAssetId) ?*const SpriteAtlasMeta {
        if (self.atlas_meta[manifest.spriteIndex(id)]) |*slot| {
            return switch (slot.*) {
                .sprite_atlas => |*meta| meta,
                .world_tileset => null,
            };
        }
        return null;
    }

    pub fn audioStatus(self: *const RuntimeAssets, id: AudioAssetId) AssetStatus {
        return self.audio_status[manifest.audioIndex(id)];
    }

    /// Skips metadata when the atlas texture is unavailable. Requires metadata
    /// when the texture loaded successfully.
    fn loadAtlasMetadata(self: *RuntimeAssets, asset_store: AssetStore, options: LoadAtlasMetadataOptions) !void {
        for (manifest.sprite_assets) |spec| {
            if (spec.metadata_kind == null) continue;
            if (self.spriteStatus(spec.id) != .available) {
                if (options.log_unavailable) {
                    log.warn(
                        "skipping atlas metadata for {s}: sprite texture unavailable",
                        .{@tagName(spec.id)},
                    );
                }
                continue;
            }
            try self.loadMetadataFor(asset_store, spec);
        }
    }

    fn loadMetadataFor(self: *RuntimeAssets, asset_store: AssetStore, spec: manifest.SpriteAssetSpec) !void {
        const expected_kind = manifest.expectedMetadataKind(spec.id);
        const kind = spec.metadata_kind orelse return;
        const metadata_path = spec.metadata_path orelse return error.MissingMetadataPath;
        if (expected_kind != kind) return error.AtlasManifestMismatch;
        const index = manifest.spriteIndex(spec.id);
        errdefer self.atlas_meta[index] = null;
        switch (kind) {
            .world_tileset => self.atlas_meta[index] = .{
                .world_tileset = try world_tileset_meta.load(self.allocator, asset_store, metadata_path),
            },
            .sprite_atlas => self.atlas_meta[index] = .{
                .sprite_atlas = try sprite_atlas_meta.load(self.allocator, asset_store, spec.id, metadata_path),
            },
        }
    }

    fn preloadSprite(
        self: *RuntimeAssets,
        asset_store: AssetStore,
        cache: *AssetCache,
        renderer: *Renderer,
        spec: manifest.SpriteAssetSpec,
    ) !void {
        const index = manifest.spriteIndex(spec.id);

        try @import("assets.zig").validateRelativePath(spec.path);
        if (asset_store.resolveReadablePath(spec.path)) |path| {
            asset_store.allocator.free(path);
        } else |err| switch (err) {
            error.FileNotFound => {
                log.warn("startup sprite asset unavailable \"{s}\": {}", .{ spec.path, err });
                self.releaseSpriteSlot(cache, renderer, index);
                self.sprite_slots[index].status = .unavailable;
                return;
            },
            else => return err,
        }

        const lease = try cache.acquireTexture(renderer, spec.path);
        self.releaseSpriteSlot(cache, renderer, index);
        self.sprite_slots[index] = .{
            .status = .available,
            .lease = lease,
            .source_rect = sourceRect(spec.source_rect),
        };
    }

    fn releaseSpriteSlot(self: *RuntimeAssets, cache: *AssetCache, renderer: *Renderer, index: usize) void {
        cache.releaseTexture(renderer, &self.sprite_slots[index].lease);
        self.sprite_slots[index] = .{};
    }
};

const SpriteSlot = struct {
    status: AssetStatus = .not_loaded,
    lease: TextureLease = .{},
    source_rect: ?Rect = null,
};

const LoadAtlasMetadataOptions = struct {
    log_unavailable: bool = true,
};

fn initSpriteSlots() [manifest.sprite_asset_count]SpriteSlot {
    return [_]SpriteSlot{.{}} ** manifest.sprite_asset_count;
}

fn initAudioStatus() [manifest.audio_asset_count]AssetStatus {
    return [_]AssetStatus{.not_loaded} ** manifest.audio_asset_count;
}

fn initAtlasMetaSlots() [manifest.sprite_asset_count]?AtlasMetaSlot {
    return .{null} ** manifest.sprite_asset_count;
}

fn deinitAtlasMetaSlots(slots: *[manifest.sprite_asset_count]?AtlasMetaSlot) void {
    for (slots) |*slot| {
        if (slot.*) |*meta| {
            meta.deinit();
            slot.* = null;
        }
    }
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
    const cache_testing = @import("cache.zig").testing;
    var runtime_assets = RuntimeAssets.init();
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var fake = cache_testing.Backend{};
    var cache = cache_testing.initCache(std.testing.allocator, asset_store);
    defer cache_testing.deinitCache(&cache, &fake);

    try preloadSpriteWithTestBackend(&runtime_assets, asset_store, &cache, &fake, .{
        .id = .demo_tile,
        .path = "missing/nope.png",
    });

    try std.testing.expectEqual(AssetStatus.unavailable, runtime_assets.spriteStatus(.demo_tile));
    try std.testing.expect(runtime_assets.sprite(.demo_tile) == null);
}

test "runtime assets deinit releases preloaded sprites exactly once" {
    const cache_testing = @import("cache.zig").testing;
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var fake = cache_testing.Backend{};
    var cache = cache_testing.initCache(std.testing.allocator, asset_store);
    defer cache_testing.deinitCache(&cache, &fake);
    var audio = try AudioService.init(std.testing.allocator, asset_store, .{ .enabled = false });
    defer audio.deinit();

    var runtime_assets = RuntimeAssets.init();
    defer deinitWithTestBackend(&runtime_assets, &cache, &fake);
    try preloadWithTestBackend(&runtime_assets, asset_store, &cache, &fake, &audio);

    var available_sprite_count: u32 = 0;
    for (manifest.sprite_assets) |spec| {
        if (runtime_assets.spriteStatus(spec.id) == .available) available_sprite_count += 1;
    }

    try std.testing.expect(available_sprite_count > 0);
    try std.testing.expectEqual(AssetStatus.available, runtime_assets.spriteStatus(.demo_tile));
    try std.testing.expect(runtime_assets.sprite(.demo_tile) != null);
    try std.testing.expectEqual(available_sprite_count, cache_testing.uploadCount(&fake));
    try std.testing.expectEqual(@as(u32, 0), cache_testing.destroyCount(&fake));
    try std.testing.expectEqual(@as(usize, available_sprite_count), cache_testing.entryCount(&cache));

    const uploads_before_deinit = cache_testing.uploadCount(&fake);
    deinitWithTestBackend(&runtime_assets, &cache, &fake);

    try std.testing.expectEqual(AssetStatus.not_loaded, runtime_assets.spriteStatus(.demo_tile));
    try std.testing.expect(runtime_assets.sprite(.demo_tile) == null);
    try std.testing.expectEqual(uploads_before_deinit, cache_testing.destroyCount(&fake));
    try std.testing.expectEqual(@as(usize, 0), cache_testing.entryCount(&cache));
}

test "startup preload attempts every registered sprite id" {
    const cache_testing = @import("cache.zig").testing;
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var fake = cache_testing.Backend{};
    var cache = cache_testing.initCache(std.testing.allocator, asset_store);
    defer cache_testing.deinitCache(&cache, &fake);
    var audio = try AudioService.init(std.testing.allocator, asset_store, .{ .enabled = false });
    defer audio.deinit();

    var runtime_assets = RuntimeAssets.init();
    defer deinitWithTestBackend(&runtime_assets, &cache, &fake);

    try preloadWithTestBackend(&runtime_assets, asset_store, &cache, &fake, &audio);

    for (manifest.sprite_assets) |spec| {
        const status = runtime_assets.spriteStatus(spec.id);
        try std.testing.expect(status != .not_loaded);
    }
}

test "runtime asset sprite replacement keeps one live cache retain" {
    const cache_testing = @import("cache.zig").testing;
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var fake = cache_testing.Backend{};
    var cache = cache_testing.initCache(std.testing.allocator, asset_store);
    defer cache_testing.deinitCache(&cache, &fake);

    var runtime_assets = RuntimeAssets.init();
    defer deinitWithTestBackend(&runtime_assets, &cache, &fake);

    const spec = manifest.SpriteAssetSpec{
        .id = .demo_tile,
        .path = "sprites/demo_tile.png",
    };
    try preloadSpriteWithTestBackend(&runtime_assets, asset_store, &cache, &fake, spec);
    try preloadSpriteWithTestBackend(&runtime_assets, asset_store, &cache, &fake, spec);

    try std.testing.expectEqual(AssetStatus.available, runtime_assets.spriteStatus(.demo_tile));
    try std.testing.expectEqual(@as(u32, 1), cache_testing.uploadCount(&fake));
    try std.testing.expectEqual(@as(u32, 0), cache_testing.destroyCount(&fake));
    try std.testing.expectEqual(@as(usize, 1), cache_testing.entryCount(&cache));
}

test "runtime asset missing sprite replacement releases the previous lease" {
    const cache_testing = @import("cache.zig").testing;
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var fake = cache_testing.Backend{};
    var cache = cache_testing.initCache(std.testing.allocator, asset_store);
    defer cache_testing.deinitCache(&cache, &fake);

    var runtime_assets = RuntimeAssets.init();
    defer deinitWithTestBackend(&runtime_assets, &cache, &fake);

    try preloadSpriteWithTestBackend(&runtime_assets, asset_store, &cache, &fake, .{
        .id = .demo_tile,
        .path = "sprites/demo_tile.png",
    });
    try preloadSpriteWithTestBackend(&runtime_assets, asset_store, &cache, &fake, .{
        .id = .demo_tile,
        .path = "missing/nope.png",
    });

    try std.testing.expectEqual(AssetStatus.unavailable, runtime_assets.spriteStatus(.demo_tile));
    try std.testing.expect(runtime_assets.sprite(.demo_tile) == null);
    try std.testing.expectEqual(@as(u32, 1), cache_testing.uploadCount(&fake));
    try std.testing.expectEqual(@as(u32, 1), cache_testing.destroyCount(&fake));
    try std.testing.expectEqual(@as(usize, 0), cache_testing.entryCount(&cache));
}

test "sprite catalog rollback releases leases acquired before a later error" {
    const cache_testing = @import("cache.zig").testing;
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var fake = cache_testing.Backend{};
    var cache = cache_testing.initCache(std.testing.allocator, asset_store);
    defer cache_testing.deinitCache(&cache, &fake);

    var runtime_assets = RuntimeAssets.init();

    const specs = [_]manifest.SpriteAssetSpec{
        .{
            .id = .demo_tile,
            .path = "sprites/demo_tile.png",
        },
        .{
            .id = .demo_tile,
            .path = "../bad.png",
        },
    };

    try std.testing.expectError(
        error.InvalidAssetPath,
        preloadSpriteSpecsForTest(&runtime_assets, asset_store, &cache, &fake, &specs),
    );

    try std.testing.expectEqual(AssetStatus.not_loaded, runtime_assets.spriteStatus(.demo_tile));
    try std.testing.expect(runtime_assets.sprite(.demo_tile) == null);
    try std.testing.expectEqual(@as(u32, 1), cache_testing.uploadCount(&fake));
    try std.testing.expectEqual(@as(u32, 1), cache_testing.destroyCount(&fake));
    try std.testing.expectEqual(@as(usize, 0), cache_testing.entryCount(&cache));
}

test "startup metadata load skips atlases with unavailable textures" {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var runtime_assets = RuntimeAssets.init();
    runtime_assets.allocator = std.testing.allocator;
    const atlas_sprite_ids = [_]SpriteAssetId{ .world_tileset, .grim_characters, .grim_items };
    for (atlas_sprite_ids) |id| {
        runtime_assets.sprite_slots[manifest.spriteIndex(id)] = .{ .status = .unavailable };
    }

    try runtime_assets.loadAtlasMetadata(asset_store, .{ .log_unavailable = false });

    try std.testing.expect(runtime_assets.worldTilesetMeta() == null);
    try std.testing.expect(runtime_assets.spriteAtlasMeta(.grim_characters) == null);
    try std.testing.expect(runtime_assets.spriteAtlasMeta(.grim_items) == null);
}

test "metadata load fails when texture is available but sidecar is missing" {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var runtime_assets = RuntimeAssets.init();
    runtime_assets.allocator = std.testing.allocator;

    runtime_assets.sprite_slots[manifest.spriteIndex(.world_tileset)] = .{ .status = .available };

    var spec = manifest.spriteSpec(.world_tileset);
    spec.metadata_path = "sprites/missing_world_tileset.json";

    try std.testing.expectError(error.FileNotFound, runtime_assets.loadMetadataFor(asset_store, spec));
    try std.testing.expect(!runtime_assets.atlasMetaLoaded(.world_tileset));
}

test "metadata load fails when kind is declared without a sidecar path" {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var runtime_assets = RuntimeAssets.init();
    runtime_assets.allocator = std.testing.allocator;

    runtime_assets.sprite_slots[manifest.spriteIndex(.world_tileset)] = .{ .status = .available };

    var spec = manifest.spriteSpec(.world_tileset);
    spec.metadata_path = null;

    try std.testing.expectError(error.MissingMetadataPath, runtime_assets.loadMetadataFor(asset_store, spec));
    try std.testing.expect(!runtime_assets.atlasMetaLoaded(.world_tileset));
}

test "metadata load rejects manifest kind mismatches at runtime" {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var runtime_assets = RuntimeAssets.init();
    runtime_assets.allocator = std.testing.allocator;

    runtime_assets.sprite_slots[manifest.spriteIndex(.world_tileset)] = .{ .status = .available };

    var spec = manifest.spriteSpec(.world_tileset);
    spec.metadata_kind = .sprite_atlas;

    try std.testing.expectError(error.AtlasManifestMismatch, runtime_assets.loadMetadataFor(asset_store, spec));
    try std.testing.expect(!runtime_assets.atlasMetaLoaded(.world_tileset));
}

test "startup metadata load parses installed atlases when present" {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var runtime_assets = RuntimeAssets.init();
    runtime_assets.allocator = std.testing.allocator;
    defer deinitAtlasMetaSlots(&runtime_assets.atlas_meta);

    const atlas_sprite_ids = [_]SpriteAssetId{ .world_tileset, .grim_characters, .grim_items };
    for (atlas_sprite_ids) |id| {
        runtime_assets.sprite_slots[manifest.spriteIndex(id)] = .{ .status = .available };
    }

    try runtime_assets.loadAtlasMetadata(asset_store, .{});

    const world_meta = runtime_assets.worldTilesetMeta() orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("grim_dark_world_tileset", world_meta.name());
    try std.testing.expect(world_meta.sourceRectByName("grass") != null);

    const characters_meta = runtime_assets.spriteAtlasMeta(.grim_characters) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("grim_dark_characters", characters_meta.name());
    try std.testing.expect(characters_meta.sourceRectByName("adventurer") != null);

    const items_meta = runtime_assets.spriteAtlasMeta(.grim_items) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("grim_dark_items", items_meta.name());
    try std.testing.expect(items_meta.sourceRectByName("sword") != null);
}

test "startup preload loads atlas metadata when installed atlases are available" {
    const cache_testing = @import("cache.zig").testing;
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var fake = cache_testing.Backend{};
    var cache = cache_testing.initCache(std.testing.allocator, asset_store);
    defer cache_testing.deinitCache(&cache, &fake);
    var audio = try AudioService.init(std.testing.allocator, asset_store, .{ .enabled = false });
    defer audio.deinit();

    var runtime_assets = RuntimeAssets.init();
    defer deinitWithTestBackend(&runtime_assets, &cache, &fake);

    try preloadWithTestBackend(&runtime_assets, asset_store, &cache, &fake, &audio);

    for (manifest.sprite_assets) |spec| {
        if (spec.metadata_path == null) continue;
        if (runtime_assets.spriteStatus(spec.id) != .available) continue;
        try std.testing.expect(runtime_assets.atlasMetaLoaded(spec.id));
    }
}

fn preloadSpriteSpecsForTest(
    runtime_assets: *RuntimeAssets,
    asset_store: AssetStore,
    cache: *AssetCache,
    fake: anytype,
    specs: []const manifest.SpriteAssetSpec,
) !void {
    errdefer deinitWithTestBackend(runtime_assets, cache, fake);

    for (specs) |spec| {
        try preloadSpriteWithTestBackend(runtime_assets, asset_store, cache, fake, spec);
    }
}

fn preloadWithTestBackend(
    runtime_assets: *RuntimeAssets,
    asset_store: AssetStore,
    cache: *AssetCache,
    fake: anytype,
    audio: *AudioService,
) !void {
    errdefer deinitWithTestBackend(runtime_assets, cache, fake);
    runtime_assets.allocator = std.testing.allocator;

    for (manifest.sprite_assets) |spec| {
        try preloadSpriteWithTestBackend(runtime_assets, asset_store, cache, fake, spec);
    }
    try runtime_assets.loadAtlasMetadata(asset_store, .{});
    for (manifest.audio_assets) |spec| {
        const available = try audio.preloadAudio(spec.id, spec.path, spec.kind, spec.predecode);
        runtime_assets.audio_status[manifest.audioIndex(spec.id)] = if (available) .available else .unavailable;
    }
}

fn deinitWithTestBackend(runtime_assets: *RuntimeAssets, cache: *AssetCache, fake: anytype) void {
    const cache_testing = @import("cache.zig").testing;
    deinitAtlasMetaSlots(&runtime_assets.atlas_meta);

    for (&runtime_assets.sprite_slots) |*slot| {
        cache_testing.releaseTexture(cache, fake, &slot.lease);
        slot.* = .{};
    }
    runtime_assets.audio_status = initAudioStatus();
}

fn preloadSpriteWithTestBackend(
    runtime_assets: *RuntimeAssets,
    asset_store: AssetStore,
    cache: *AssetCache,
    fake: anytype,
    spec: manifest.SpriteAssetSpec,
) !void {
    const cache_testing = @import("cache.zig").testing;
    const index = manifest.spriteIndex(spec.id);

    try @import("assets.zig").validateRelativePath(spec.path);
    if (asset_store.resolveReadablePath(spec.path)) |path| {
        asset_store.allocator.free(path);
    } else |err| switch (err) {
        error.FileNotFound => {
            releaseSpriteSlotWithTestBackend(runtime_assets, cache, fake, index);
            runtime_assets.sprite_slots[index].status = .unavailable;
            return;
        },
        else => return err,
    }

    const lease = try cache_testing.acquireTexture(cache, fake, spec.path);
    releaseSpriteSlotWithTestBackend(runtime_assets, cache, fake, index);
    runtime_assets.sprite_slots[index] = .{
        .status = .available,
        .lease = lease,
        .source_rect = sourceRect(spec.source_rect),
    };
}

fn releaseSpriteSlotWithTestBackend(runtime_assets: *RuntimeAssets, cache: *AssetCache, fake: anytype, index: usize) void {
    const cache_testing = @import("cache.zig").testing;
    cache_testing.releaseTexture(cache, fake, &runtime_assets.sprite_slots[index].lease);
    runtime_assets.sprite_slots[index] = .{};
}
