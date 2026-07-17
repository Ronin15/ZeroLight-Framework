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
const Faction = @import("data_system.zig").Faction;
const PrimitiveVisual = @import("data_system.zig").PrimitiveVisual;
const render_depth = @import("render_depth.zig");

pub const Player = struct {
    entity: EntityId = EntityId.invalid,
    // The Z-level (plane) the player currently stands on. Drives which level the
    // dig acts on and syncs the body's `position_z` for the render slice.
    current_level: u16 = 0,

    const initial_position = math.Vec2{ .x = 400, .y = 225 };
    const size = math.Vec2{ .x = 32, .y = 32 };
    const speed: f32 = 120;
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
        try data.setAssetReference(entity, .{ .sprite = .grim_characters, .atlas_entry_id = 0 });
        try data.setFaction(entity, .player);
        // Pre-attach surface world_level so the first plane-traversal fall cannot
        // OOM on component growth after carveLandingCell has already mutated a tile.
        try data.setWorldLevel(entity, 0);

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

test "player spawn pre-attaches surface world_level" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);
    try std.testing.expectEqual(@as(?u16, 0), data.worldLevelConst(player.entity));
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
    input.setHeld(.move_right, true);
    input.setHeld(.move_up, true);

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
    input.setHeld(.move_up, true);

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
    input.setHeld(.move_right, true);
    input.setHeld(.move_up, true);

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

    player.onPause(&data);

    const paused = data.movementBodyConst(player.entity).?;
    try std.testing.expectEqual(paused.position.x, paused.previous_position.x);
    try std.testing.expectEqual(paused.position.y, paused.previous_position.y);

    body.position_x.* = 48;
    body.position_y.* = 96;
    player.onResume(&data);

    const resumed = data.movementBodyConst(player.entity).?;
    try std.testing.expectEqual(resumed.position.x, resumed.previous_position.x);
    try std.testing.expectEqual(resumed.position.y, resumed.previous_position.y);
}
