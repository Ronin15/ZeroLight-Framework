// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const config = @import("../config.zig");
const InputState = @import("../app/input.zig").InputState;
const math = @import("../core/math.zig");
const data_mod = @import("data_system.zig");
const DataSystem = data_mod.DataSystem;
const EntityId = data_mod.EntityId;
const Facing = data_mod.Facing;
const PrimitiveVisual = data_mod.PrimitiveVisual;
const renderer = @import("../render/renderer.zig");
const Renderer = renderer.Renderer;
const Rect = renderer.Rect;

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

    pub fn render(self: Player, data: *const DataSystem, renderer_instance: *Renderer, interpolation_alpha: f32) !void {
        const body = data.movementBodyConst(self.entity) orelse return error.MissingPlayerMovementBody;
        const facing = data.facingConst(self.entity) orelse return error.MissingPlayerFacing;
        const visual = data.primitiveVisualConst(self.entity) orelse return error.MissingPlayerVisual;
        const render_position = math.lerpVec2(body.previous_position, body.position, interpolation_alpha);

        try renderer_instance.drawRect(.{
            .x = render_position.x,
            .y = render_position.y,
            .w = visual.size.x,
            .h = visual.size.y,
        }, visual.color, visual.layer);
        try renderer_instance.drawRect(markerRect(render_position, facing.direction, visual), visual.marker_color, visual.marker_layer);
    }

    pub fn onPause(self: Player, data: *DataSystem) void {
        const body = data.movementBodyPtr(self.entity) orelse return;
        body.previous_x.* = body.position_x.*;
        body.previous_y.* = body.position_y.*;
    }
};

fn playerVisual() PrimitiveVisual {
    return .{
        .size = Player.size,
        .color = Player.color,
        .layer = 0,
        .marker_color = Player.marker_color,
        .marker_layer = 1,
        .marker_length = Player.marker_length,
        .marker_depth = Player.marker_depth,
        .marker_margin = Player.marker_margin,
    };
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
    const std = @import("std");
    const movement_system = @import("systems/movement.zig");
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
    movement_system.updateSerial(&data, 1.0);
    try player.clampToBounds(&data, 800, 450);

    const body = data.movementBodyConst(player.entity).?;
    try std.testing.expectEqual(@as(f32, 768), body.position.x);
    try std.testing.expectEqual(@as(f32, 0), body.position.y);
}

test "player facing updates from movement and remains while idle" {
    const std = @import("std");
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

test "player horizontal facing wins for diagonal movement" {
    const std = @import("std");
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);

    var input = InputState{};
    input.setHeld(.moveRight, true);
    input.setHeld(.moveUp, true);

    try player.applyInput(&data, &input);

    try std.testing.expectEqual(Facing.right, data.facingConst(player.entity).?.direction);
}

test "player pause syncs previous position to current data position" {
    const std = @import("std");
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);
    const body = data.movementBodyPtr(player.entity).?;
    body.position_x.* = 12;
    body.position_y.* = 24;
    body.previous_x.* = 2;
    body.previous_y.* = 4;

    player.onPause(&data);

    const paused = data.movementBodyConst(player.entity).?;
    try std.testing.expectEqual(paused.position.x, paused.previous_position.x);
    try std.testing.expectEqual(paused.position.y, paused.previous_position.y);
}
