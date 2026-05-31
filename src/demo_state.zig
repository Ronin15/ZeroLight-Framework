// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const config = @import("config.zig");
const InputState = @import("input.zig").InputState;
const math = @import("math.zig");
const Renderer = @import("renderer.zig").Renderer;
const c = @import("sdl.zig").c;

pub const DemoState = struct {
    player: Player = .{},
    bounds_width: f32 = 800,
    bounds_height: f32 = 450,

    pub fn init(bounds_width: f32, bounds_height: f32) DemoState {
        return .{
            .bounds_width = bounds_width,
            .bounds_height = bounds_height,
        };
    }

    pub fn deinit(self: *DemoState) void {
        _ = self;
    }

    pub fn handleEvent(self: *DemoState, event: *const c.SDL_Event) bool {
        _ = self;
        _ = event;
        return false;
    }

    pub fn update(self: *DemoState, input: *const InputState, delta_seconds: f32) void {
        self.player.update(input, delta_seconds, self.bounds_width, self.bounds_height);
    }

    pub fn render(self: *DemoState, renderer: *Renderer, interpolation_alpha: f32) !void {
        try self.player.render(renderer, interpolation_alpha);
        try renderer.drawRect(.{
            .x = 0,
            .y = self.bounds_height - 4,
            .w = self.bounds_width,
            .h = 4,
        }, config.Color{ .r = 0.16, .g = 0.24, .b = 0.29, .a = 1.0 }, -1);
    }

    pub fn onPause(self: *DemoState) void {
        self.player.onPause();
    }
};

const Direction = enum {
    up,
    down,
    left,
    right,
};

const Player = struct {
    position: math.Vec2 = .{ .x = 400, .y = 225 },
    previous_position: math.Vec2 = .{ .x = 400, .y = 225 },
    facing: Direction = .down,

    const size: f32 = 32;
    const speed: f32 = 240;
    const marker_length: f32 = 12;
    const marker_depth: f32 = 6;
    const marker_margin: f32 = 4;
    const color = config.Color{ .r = 1.0, .g = 0.8, .b = 0.36, .a = 1.0 };
    const marker_color = config.Color{ .r = 0.8, .g = 0.56, .b = 0.22, .a = 1.0 };

    fn update(self: *Player, input: *const InputState, delta_seconds: f32, bounds_width: f32, bounds_height: f32) void {
        self.previous_position = self.position;

        const direction = input.movementVector();

        if (direction.x < 0) {
            self.facing = .left;
        } else if (direction.x > 0) {
            self.facing = .right;
        } else if (direction.y < 0) {
            self.facing = .up;
        } else if (direction.y > 0) {
            self.facing = .down;
        }

        self.position.x = math.clamp(
            self.position.x + direction.x * speed * delta_seconds,
            0,
            bounds_width - size,
        );
        self.position.y = math.clamp(
            self.position.y + direction.y * speed * delta_seconds,
            0,
            bounds_height - size,
        );
    }

    fn render(self: *const Player, renderer: *Renderer, interpolation_alpha: f32) !void {
        const render_position = math.lerpVec2(self.previous_position, self.position, interpolation_alpha);
        try renderer.drawRect(.{
            .x = render_position.x,
            .y = render_position.y,
            .w = size,
            .h = size,
        }, color, 0);
        try renderer.drawRect(markerRect(render_position, self.facing), marker_color, 1);
    }

    fn onPause(self: *Player) void {
        self.previous_position = self.position;
    }

    fn markerRect(position: math.Vec2, facing: Direction) @import("renderer.zig").Rect {
        const centered_offset = (size - marker_length) * 0.5;

        return switch (facing) {
            .up => .{
                .x = position.x + centered_offset,
                .y = position.y + marker_margin,
                .w = marker_length,
                .h = marker_depth,
            },
            .down => .{
                .x = position.x + centered_offset,
                .y = position.y + size - marker_margin - marker_depth,
                .w = marker_length,
                .h = marker_depth,
            },
            .left => .{
                .x = position.x + marker_margin,
                .y = position.y + centered_offset,
                .w = marker_depth,
                .h = marker_length,
            },
            .right => .{
                .x = position.x + size - marker_margin - marker_depth,
                .y = position.y + centered_offset,
                .w = marker_depth,
                .h = marker_length,
            },
        };
    }
};

test "player movement clamps to state bounds" {
    const std = @import("std");
    var player = Player{ .position = .{ .x = 790, .y = -4 }, .previous_position = .{ .x = 790, .y = -4 } };
    var input = InputState{};
    input.setHeld(.moveRight, true);
    input.setHeld(.moveUp, true);

    player.update(&input, 1.0, 800, 450);

    try std.testing.expectEqual(@as(f32, 768), player.position.x);
    try std.testing.expectEqual(@as(f32, 0), player.position.y);
}

test "player facing updates from movement and remains while idle" {
    const std = @import("std");
    var player = Player{};

    var input = InputState{};
    input.setHeld(.moveUp, true);

    player.update(&input, 0.0, 800, 450);
    try std.testing.expectEqual(Direction.up, player.facing);

    player.update(&InputState{}, 0.0, 800, 450);
    try std.testing.expectEqual(Direction.up, player.facing);
}

test "player horizontal facing wins for diagonal movement" {
    const std = @import("std");
    var player = Player{};

    var input = InputState{};
    input.setHeld(.moveRight, true);
    input.setHeld(.moveUp, true);

    player.update(&input, 0.0, 800, 450);

    try std.testing.expectEqual(Direction.right, player.facing);
}
