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
            try queue.addSprite(.{
                .texture = sprite.texture,
                .source = sprite.source_rect,
                .dest = dest,
                .tint = visual.color,
                .order = order,
            });
            return;
        }
    }

    try queue.addRect(dest, visual.color, order, .world);
}

pub fn worldOrder(base_z: i32, depth: WorldDepth) RenderOrder {
    return RenderOrder.world(render_depth.worldZWithOffset(base_z, depth));
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
