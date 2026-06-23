// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const math = @import("../core/math.zig");
const DataSystem = @import("data_system.zig").DataSystem;
const EntityId = @import("data_system.zig").EntityId;
const Rect = @import("../render/renderer.zig").Rect;
const RenderOrder = @import("../render/renderer.zig").RenderOrder;
const RenderQueue = @import("../render/render_queue.zig").RenderQueue;
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const AssetStore = @import("../assets/assets.zig").AssetStore;
const sprite_atlas_meta = @import("../assets/sprite_atlas_meta.zig");
const manifest = @import("../assets/manifest.zig");
const WorldDepth = @import("render_depth.zig").WorldDepth;
const render_depth = @import("render_depth.zig");

pub fn enqueueEntity(
    queue: *RenderQueue,
    data: *const DataSystem,
    entity: EntityId,
    runtime_assets: *const RuntimeAssets,
    interpolation_alpha: f32,
) !void {
    const body = data.movementBodyConst(entity) orelse return;
    const visual = data.primitiveVisualConst(entity) orelse return;
    const render_position = math.lerpVec2(body.previous_position, body.position, interpolation_alpha);
    const dest = Rect{
        .x = render_position.x,
        .y = render_position.y,
        .w = visual.size.x,
        .h = visual.size.y,
    };
    const order = worldOrder(body.position_z, visual.depth);

    if (data.assetReferenceConst(entity)) |asset_ref| {
        if (runtime_assets.sprite(asset_ref.sprite)) |sprite| {
            const source = sourceRectForAsset(runtime_assets, asset_ref, sprite.source_rect) orelse if (asset_ref.hasAtlasEntry())
                null
            else
                sprite.source_rect;
            if (!asset_ref.hasAtlasEntry() or source != null) {
                try queue.addSprite(.{
                    .texture = sprite.texture,
                    .source = source,
                    .dest = dest,
                    .tint = visual.color,
                    .order = order,
                });
                return;
            }
        }
    }

    try queue.addRect(dest, visual.color, order, .world);
}

pub fn sourceRectForAsset(
    runtime_assets: *const RuntimeAssets,
    asset_ref: @import("data_system.zig").AssetReference,
    sprite_source: ?Rect,
) ?Rect {
    if (!asset_ref.hasAtlasEntry()) return sprite_source;
    const meta = runtime_assets.spriteAtlasMeta(asset_ref.sprite) orelse return null;
    const source = meta.sourceRectForId(asset_ref.atlas_entry_id) orelse return null;
    return rectFromManifest(source);
}

fn rectFromManifest(source: manifest.SourceRect) Rect {
    return .{
        .x = source.x,
        .y = source.y,
        .w = source.w,
        .h = source.h,
    };
}

pub fn worldOrder(base_z: i32, depth: WorldDepth) RenderOrder {
    return RenderOrder.world(render_depth.worldZWithOffset(base_z, depth));
}

test "atlas-backed entity falls back to primitive rect without metadata" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{}, .previous_position = .{} });
    try data.setPrimitiveVisual(entity, .{
        .size = .{ .x = 32, .y = 48 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    });
    try data.setAssetReference(entity, .{ .sprite = .grim_characters, .atlas_entry_id = 0 });
    var runtime_assets = RuntimeAssets.init();
    setSpriteAvailableForTest(&runtime_assets, .grim_characters, try @import("../render/resources.zig").TextureId.init(1, 1));
    var queue = RenderQueue.init(std.testing.allocator);
    defer queue.deinit();

    try enqueueEntity(&queue, &data, entity, &runtime_assets, 1.0);
    queue.sortForSubmit();

    try std.testing.expectEqual(@as(usize, 1), queue.recordCount());
    try std.testing.expect(queue.sortedSprite(0) == null);
}

test "atlas-backed entity uses metadata source rect when available" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{}, .previous_position = .{} });
    try data.setPrimitiveVisual(entity, .{
        .size = .{ .x = 32, .y = 48 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    });
    try data.setAssetReference(entity, .{ .sprite = .grim_characters, .atlas_entry_id = 0 });
    var runtime_assets = RuntimeAssets.init();
    runtime_assets.allocator = std.testing.allocator;
    setSpriteAvailableForTest(&runtime_assets, .grim_characters, try @import("../render/resources.zig").TextureId.init(1, 1));
    try setSpriteAtlasMetadataForTest(&runtime_assets, .grim_characters);
    defer deinitAtlasMetadataForTest(&runtime_assets, .grim_characters);
    var queue = RenderQueue.init(std.testing.allocator);
    defer queue.deinit();

    try enqueueEntity(&queue, &data, entity, &runtime_assets, 1.0);
    queue.sortForSubmit();

    const sprite = queue.sortedSprite(0) orelse return error.TestExpectedEqual;
    const source = sprite.source orelse return error.TestExpectedEqual;
    const expected = runtime_assets.spriteAtlasMeta(.grim_characters).?.sourceRectForId(0) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(expected.x, source.x);
    try std.testing.expectEqual(expected.y, source.y);
    try std.testing.expectEqual(expected.w, source.w);
    try std.testing.expectEqual(expected.h, source.h);
}

fn setSpriteAvailableForTest(runtime_assets: *RuntimeAssets, id: manifest.SpriteAssetId, texture: @import("../render/resources.zig").TextureId) void {
    runtime_assets.sprite_slots[manifest.spriteIndex(id)] = .{
        .status = .available,
        .lease = .{ .id = texture },
    };
}

fn setSpriteAtlasMetadataForTest(runtime_assets: *RuntimeAssets, id: manifest.SpriteAssetId) !void {
    const spec = manifest.spriteSpec(id);
    const metadata_path = spec.metadata_path orelse return error.MissingMetadataPath;
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    runtime_assets.atlas_meta[manifest.spriteIndex(id)] = .{
        .sprite_atlas = try sprite_atlas_meta.load(std.testing.allocator, asset_store, id, metadata_path),
    };
}

fn deinitAtlasMetadataForTest(runtime_assets: *RuntimeAssets, id: manifest.SpriteAssetId) void {
    const index = manifest.spriteIndex(id);
    if (runtime_assets.atlas_meta[index]) |*slot| {
        switch (slot.*) {
            .sprite_atlas => |*meta| meta.deinit(),
            .world_tileset => |*meta| meta.deinit(),
        }
    }
    runtime_assets.atlas_meta[index] = null;
}

test "world render order combines entity z with depth band" {
    const below_actor = worldOrder(-2, .actor);
    const obstacle = worldOrder(0, .obstacle);
    const actor = worldOrder(0, .actor);

    try std.testing.expect(below_actor.lessOrEqual(obstacle));
    try std.testing.expect(obstacle.lessOrEqual(actor));
}

test "world render order saturates extreme entity z" {
    try std.testing.expectEqual(std.math.maxInt(i32), worldOrder(std.math.maxInt(i32), .marker).depth);
    try std.testing.expectEqual(std.math.minInt(i32), worldOrder(std.math.minInt(i32), .floor).depth);
}
