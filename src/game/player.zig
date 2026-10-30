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
        errdefer data.destroyCreatedEntity(entity);

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
        // Pre-attach surface world_level so the player's first plane traversal needs no
        // world_level growth in the plane stage's reserve.
        try data.setWorldLevel(entity, 0);

        return .{ .entity = entity };
    }

    pub fn applyInput(
        self: Player,
        data: *DataSystem,
        input: *const InputState,
    ) !void {
        const body = data.movementBodyPtr(self.entity) orelse return error.MissingPlayerMovementBody;
        const facing = data.facingConst(self.entity) orelse return error.MissingPlayerFacing;

        const direction = input.movementVector();
        body.velocity_x.* = direction.x * body.speed.*;
        body.velocity_y.* = direction.y * body.speed.*;
        const turned: ?Facing = if (direction.x < 0)
            .left
        else if (direction.x > 0)
            .right
        else if (direction.y < 0)
            .up
        else if (direction.y > 0)
            .down
        else
            null;
        if (turned) |next| {
            if (next != facing.direction) try data.setFacing(self.entity, .{ .direction = next });
        }
    }

    /// Keeps the player's collision box (`position + offset`, `size`) inside
    /// `[0, bounds]` with `math.clampMinMax`, the scalar twin of the world gate's lane
    /// clamp. A player without collision bounds has no box and is left as is.
    pub fn clampToBounds(self: Player, data: *DataSystem, bounds_width: f32, bounds_height: f32) !void {
        const body = data.movementBodyPtr(self.entity) orelse return error.MissingPlayerMovementBody;
        const bounds = data.collisionBoundsConst(self.entity) orelse return;

        body.position_x.* = math.clampMinMax(
            body.position_x.*,
            0 - bounds.offset.x,
            bounds_width - bounds.offset.x - bounds.size.x,
        );
        body.position_y.* = math.clampMinMax(
            body.position_y.*,
            0 - bounds.offset.y,
            bounds_height - bounds.offset.y - bounds.size.y,
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
    try data.setCollisionBounds(player.entity, .{ .size = Player.size });
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
    var threads = try @import("../app/thread_system.zig").ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var movement_system = movement.MovementSystem.init();
    _ = movement_system.update(&movement_slice, &threads, 1.0, .{});
    try player.clampToBounds(&data, 800, 450);

    const body = data.movementBodyConst(player.entity).?;
    try std.testing.expectEqual(@as(f32, 768), body.position.x);
    try std.testing.expectEqual(@as(f32, 0), body.position.y);
}

test "player clamp keeps the collision box in bounds and leaves a box-less player as is" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);
    const body = data.movementBodyPtr(player.entity).?;

    body.position_x.* = 900;
    body.position_y.* = -50;
    try player.clampToBounds(&data, 800, 450);
    try std.testing.expectEqual(@as(f32, 900), body.position_x.*);
    try std.testing.expectEqual(@as(f32, -50), body.position_y.*);

    // The box spans [position + offset, position + offset + size).
    try data.setCollisionBounds(player.entity, .{ .offset = .{ .x = 4, .y = -6 }, .size = .{ .x = 20, .y = 10 } });
    try player.clampToBounds(&data, 800, 450);
    try std.testing.expectEqual(@as(f32, 800 - 4 - 20), body.position_x.*);
    try std.testing.expectEqual(@as(f32, 6), body.position_y.*);
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

test "player facing updates the drawable run direction from held movement" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);

    var input = InputState{};
    input.setHeld(.move_up, true);
    try player.applyInput(&data, &input);

    // Spawn mirrors `.down`. A facing-store write that skips `setFacing` leaves this `.down`.
    const run_index = data.movement_bodies.drawableRunIndex(0, 0, 0).?;
    try std.testing.expectEqual(Facing.up, data.movement_bodies.drawableRunSlice(run_index).direction[0]);

    try player.applyInput(&data, &InputState{});
    try std.testing.expectEqual(Facing.up, data.movement_bodies.drawableRunSlice(run_index).direction[0]);
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
