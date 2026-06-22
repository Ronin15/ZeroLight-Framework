// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const config = @import("../config.zig");
const InputState = @import("../app/input.zig").InputState;
const math = @import("../core/math.zig");
const std = @import("std");
const DataSystem = @import("data_system.zig").DataSystem;
const EntityId = @import("data_system.zig").EntityId;
const Facing = @import("data_system.zig").Facing;
const PrimitiveVisual = @import("data_system.zig").PrimitiveVisual;
const RenderOrder = @import("../render/renderer.zig").RenderOrder;
const Rect = @import("../render/renderer.zig").Rect;
const RenderQueue = @import("../render/render_queue.zig").RenderQueue;
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const render_depth = @import("render_depth.zig");

pub const Player = struct {
    entity: EntityId = EntityId.invalid,

    const initial_position = math.Vec2{ .x = 400, .y = 225 };
    const size = math.Vec2{ .x = 32, .y = 32 };
    const speed: f32 = 240;
    const marker_length: f32 = 12;
    const marker_depth: f32 = 6;
    const marker_margin: f32 = 4;
    const color = config.Color{ .r = 1.0, .g = 0.8, .b = 0.36, .a = 1.0 };
    const marker_color = config.Color{ .r = 0.8, .g = 0.56, .b = 0.22, .a = 1.0 };

    pub fn spawn(data: *DataSystem) !Player {
        const entity = try data.createEntity();
        errdefer _ = data.destroyEntity(entity);

        try data.setMovementBody(entity, .{
            .position = initial_position,
            .previous_position = initial_position,
            .velocity = .{},
            .speed = speed,
        });
        try data.setFacing(entity, .{ .direction = .down });
        try data.setPrimitiveVisual(entity, playerVisual());
        try data.setAssetReference(entity, .{ .sprite = .demo_tile });

        return .{ .entity = entity };
    }

    pub fn applyInput(
        self: Player,
        data: *DataSystem,
        input: *const InputState,
    ) !void {
        const body = data.movementBodyPtr(self.entity) orelse return error.MissingPlayerMovementBody;
        const facing = data.facingPtr(self.entity) orelse return error.MissingPlayerFacing;

        const direction = input.movementVector();
        body.velocity_x.* = direction.x * body.speed.*;
        body.velocity_y.* = direction.y * body.speed.*;
        if (direction.x < 0) {
            facing.* = .left;
        } else if (direction.x > 0) {
            facing.* = .right;
        } else if (direction.y < 0) {
            facing.* = .up;
        } else if (direction.y > 0) {
            facing.* = .down;
        }
    }

    pub fn clampToBounds(self: Player, data: *DataSystem, bounds_width: f32, bounds_height: f32) !void {
        const body = data.movementBodyPtr(self.entity) orelse return error.MissingPlayerMovementBody;
        const visual = data.primitiveVisualConst(self.entity) orelse return error.MissingPlayerVisual;

        body.position_x.* = math.clamp(
            body.position_x.*,
            0,
            bounds_width - visual.size.x,
        );
        body.position_y.* = math.clamp(
            body.position_y.*,
            0,
            bounds_height - visual.size.y,
        );
    }

    pub fn enqueueRender(self: Player, data: *const DataSystem, runtime_assets: *const RuntimeAssets, queue: *RenderQueue, interpolation_alpha: f32) !void {
        const body = data.movementBodyConst(self.entity) orelse return error.MissingPlayerMovementBody;
        const facing = data.facingConst(self.entity) orelse return error.MissingPlayerFacing;
        const visual = data.primitiveVisualConst(self.entity) orelse return error.MissingPlayerVisual;
        const render_position = math.lerpVec2(body.previous_position, body.position, interpolation_alpha);
        const body_order = worldOrder(render_depth.worldZWithOffset(body.position_z, visual.depth));

        const dest = Rect{
            .x = render_position.x,
            .y = render_position.y,
            .w = visual.size.x,
            .h = visual.size.y,
        };
        if (data.assetReferenceConst(self.entity)) |asset_ref| {
            if (runtime_assets.sprite(asset_ref.sprite)) |sprite| {
                try queue.addSprite(.{
                    .texture = sprite.texture,
                    .source = sprite.source_rect,
                    .dest = dest,
                    .tint = visual.color,
                    .order = body_order,
                });
            } else {
                try queue.addRect(dest, visual.color, body_order, .world);
            }
        } else {
            try queue.addRect(dest, visual.color, body_order, .world);
        }
        const marker_order = worldOrder(render_depth.worldZWithOffset(body.position_z, visual.marker_depth_band));
        try queue.addRect(
            markerRect(render_position, facing.direction, visual),
            visual.marker_color,
            marker_order,
            .world,
        );
    }

    pub fn onPause(self: Player, data: *DataSystem) void {
        self.syncPreviousPosition(data);
    }

    pub fn onResume(self: Player, data: *DataSystem) void {
        self.syncPreviousPosition(data);
    }

    pub fn syncPreviousPosition(self: Player, data: *DataSystem) void {
        const body = data.movementBodyPtr(self.entity) orelse return;
        body.previous_x.* = body.position_x.*;
        body.previous_y.* = body.position_y.*;
        body.previous_z.* = body.position_z.*;
    }
};

fn playerVisual() PrimitiveVisual {
    return .{
        .size = Player.size,
        .color = Player.color,
        .depth = .actor,
        .marker_color = Player.marker_color,
        .marker_depth_band = .actor,
        .marker_length = Player.marker_length,
        .marker_depth = Player.marker_depth,
        .marker_margin = Player.marker_margin,
    };
}

fn worldOrder(depth: i32) RenderOrder {
    return RenderOrder.world(depth);
}

fn markerRect(position: math.Vec2, facing: Facing, visual: PrimitiveVisual) Rect {
    const centered_x = (visual.size.x - visual.marker_length) * 0.5;
    const centered_y = (visual.size.y - visual.marker_length) * 0.5;

    return switch (facing) {
        .up => .{
            .x = position.x + centered_x,
            .y = position.y + visual.marker_margin,
            .w = visual.marker_length,
            .h = visual.marker_depth,
        },
        .down => .{
            .x = position.x + centered_x,
            .y = position.y + visual.size.y - visual.marker_margin - visual.marker_depth,
            .w = visual.marker_length,
            .h = visual.marker_depth,
        },
        .left => .{
            .x = position.x + visual.marker_margin,
            .y = position.y + centered_y,
            .w = visual.marker_depth,
            .h = visual.marker_length,
        },
        .right => .{
            .x = position.x + visual.size.x - visual.marker_margin - visual.marker_depth,
            .y = position.y + centered_y,
            .w = visual.marker_depth,
            .h = visual.marker_length,
        },
    };
}

test "player movement clamps to state bounds" {
    const movement = @import("systems/movement.zig");
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);
    try data.setMovementBody(player.entity, .{
        .position = .{ .x = 790, .y = -4 },
        .previous_position = .{ .x = 790, .y = -4 },
        .velocity = .{},
        .speed = Player.speed,
    });
    var input = InputState{};
    input.setHeld(.moveRight, true);
    input.setHeld(.moveUp, true);

    try player.applyInput(&data, &input);
    var movement_slice = data.movementBodySlice();
    movement.updateSerial(&movement_slice, 1.0);
    try player.clampToBounds(&data, 800, 450);

    const body = data.movementBodyConst(player.entity).?;
    try std.testing.expectEqual(@as(f32, 768), body.position.x);
    try std.testing.expectEqual(@as(f32, 0), body.position.y);
}

test "player facing updates from movement and remains while idle" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);

    var input = InputState{};
    input.setHeld(.moveUp, true);

    try player.applyInput(&data, &input);
    try std.testing.expectEqual(Facing.up, data.facingConst(player.entity).?.direction);

    try player.applyInput(&data, &InputState{});
    try std.testing.expectEqual(Facing.up, data.facingConst(player.entity).?.direction);
}

test "player facing marker remains in actor render depth band" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);

    const visual = data.primitiveVisualConst(player.entity).?;
    try std.testing.expectEqual(render_depth.WorldDepth.actor, visual.depth);
    try std.testing.expectEqual(render_depth.WorldDepth.actor, visual.marker_depth_band);
}

test "player horizontal facing wins for diagonal movement" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);

    var input = InputState{};
    input.setHeld(.moveRight, true);
    input.setHeld(.moveUp, true);

    try player.applyInput(&data, &input);

    try std.testing.expectEqual(Facing.right, data.facingConst(player.entity).?.direction);
}

test "player pause and resume sync previous position to current data position" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);
    const body = data.movementBodyPtr(player.entity).?;
    body.position_x.* = 12;
    body.position_y.* = 24;
    body.previous_x.* = 2;
    body.previous_y.* = 4;
    body.position_z.* = 12;
    body.previous_z.* = 2;

    player.onPause(&data);

    const paused = data.movementBodyConst(player.entity).?;
    try std.testing.expectEqual(paused.position.x, paused.previous_position.x);
    try std.testing.expectEqual(paused.position.y, paused.previous_position.y);
    try std.testing.expectEqual(paused.position_z, paused.previous_z);

    body.position_x.* = 48;
    body.position_y.* = 96;
    body.position_z.* = 24;
    player.onResume(&data);

    const resumed = data.movementBodyConst(player.entity).?;
    try std.testing.expectEqual(resumed.position.x, resumed.previous_position.x);
    try std.testing.expectEqual(resumed.position.y, resumed.previous_position.y);
    try std.testing.expectEqual(resumed.position_z, resumed.previous_z);
}
