// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const math = @import("../core/math.zig");
const c = @import("../platform/sdl.zig").c;

pub const Action = enum(usize) {
    moveLeft,
    moveRight,
    moveUp,
    moveDown,
    pause,
    resumeGame,
    quit,
    toggleDebugOverlay,
};

const action_count = @typeInfo(Action).@"enum".fields.len;

pub const KeyBinding = struct {
    key: c.SDL_Keycode,
    action: Action,
};

pub const default_key_bindings = [_]KeyBinding{
    .{ .key = c.SDLK_A, .action = .moveLeft },
    .{ .key = c.SDLK_D, .action = .moveRight },
    .{ .key = c.SDLK_W, .action = .moveUp },
    .{ .key = c.SDLK_S, .action = .moveDown },
    .{ .key = c.SDLK_P, .action = .pause },
    .{ .key = c.SDLK_RETURN, .action = .resumeGame },
    .{ .key = c.SDLK_SPACE, .action = .resumeGame },
    .{ .key = c.SDLK_ESCAPE, .action = .quit },
    .{ .key = c.SDLK_F2, .action = .toggleDebugOverlay },
};

pub const InputState = struct {
    held_actions: ActionFlags = .{},

    pub fn releaseMovement(self: *InputState) void {
        inline for (movement_actions) |action| {
            self.held_actions.set(action, false);
        }
    }

    pub fn handleEvent(self: *InputState, event: *const c.SDL_Event) void {
        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                const action = actionForKey(event.key.key) orelse return;
                if (!isGameplayAction(action)) return;
                self.held_actions.set(action, event.type == c.SDL_EVENT_KEY_DOWN);
            },
            else => {},
        }
    }

    pub fn isHeld(self: *const InputState, action: Action) bool {
        return self.held_actions.get(action);
    }

    pub fn setHeld(self: *InputState, action: Action, value: bool) void {
        if (!isGameplayAction(action)) return;
        self.held_actions.set(action, value);
    }

    pub fn movementVector(self: *const InputState) math.Vec2 {
        var direction = math.Vec2{};
        if (self.isHeld(.moveLeft)) direction.x -= 1;
        if (self.isHeld(.moveRight)) direction.x += 1;
        if (self.isHeld(.moveUp)) direction.y -= 1;
        if (self.isHeld(.moveDown)) direction.y += 1;
        return direction;
    }
};

pub const FrameCommands = struct {
    pressed_actions: ActionFlags = .{},

    pub fn beginFrame(self: *FrameCommands) void {
        self.pressed_actions.clear();
    }

    pub fn handleEvent(self: *FrameCommands, event: *const c.SDL_Event) void {
        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                if (event.key.repeat) return;
                const action = actionForKey(event.key.key) orelse return;
                if (!isCommandAction(action)) return;
                self.pressed_actions.set(action, true);
            },
            else => {},
        }
    }

    pub fn wasPressed(self: *const FrameCommands, action: Action) bool {
        return self.pressed_actions.get(action);
    }
};

const movement_actions = [_]Action{
    .moveLeft,
    .moveRight,
    .moveUp,
    .moveDown,
};

fn isGameplayAction(action: Action) bool {
    return switch (action) {
        .moveLeft, .moveRight, .moveUp, .moveDown => true,
        else => false,
    };
}

fn isCommandAction(action: Action) bool {
    return switch (action) {
        .pause, .resumeGame, .quit, .toggleDebugOverlay => true,
        else => false,
    };
}

pub fn actionForKey(key: c.SDL_Keycode) ?Action {
    for (default_key_bindings) |binding| {
        if (binding.key == key) return binding.action;
    }
    return null;
}

const ActionFlags = struct {
    values: [action_count]bool = [_]bool{false} ** action_count,

    fn clear(self: *ActionFlags) void {
        self.values = [_]bool{false} ** action_count;
    }

    fn get(self: *const ActionFlags, action: Action) bool {
        return self.values[@intFromEnum(action)];
    }

    fn set(self: *ActionFlags, action: Action, value: bool) void {
        self.values[@intFromEnum(action)] = value;
    }
};

test "default key bindings map keyboard keys to actions" {
    const std = @import("std");

    try std.testing.expectEqual(Action.moveLeft, actionForKey(c.SDLK_A).?);
    try std.testing.expectEqual(Action.moveRight, actionForKey(c.SDLK_D).?);
    try std.testing.expectEqual(Action.moveUp, actionForKey(c.SDLK_W).?);
    try std.testing.expectEqual(Action.moveDown, actionForKey(c.SDLK_S).?);
    try std.testing.expectEqual(Action.pause, actionForKey(c.SDLK_P).?);
    try std.testing.expectEqual(Action.resumeGame, actionForKey(c.SDLK_RETURN).?);
    try std.testing.expectEqual(Action.resumeGame, actionForKey(c.SDLK_SPACE).?);
    try std.testing.expectEqual(Action.quit, actionForKey(c.SDLK_ESCAPE).?);
    try std.testing.expectEqual(Action.toggleDebugOverlay, actionForKey(c.SDLK_F2).?);
}

test "input key mapping tracks held gameplay actions" {
    const std = @import("std");
    var input = InputState{};

    input.setHeld(.moveLeft, true);
    input.setHeld(.moveUp, true);
    try std.testing.expect(input.isHeld(.moveLeft));
    try std.testing.expect(input.isHeld(.moveUp));
    try std.testing.expect(!input.isHeld(.moveRight));
    try std.testing.expect(!input.isHeld(.moveDown));

    input.setHeld(.moveLeft, false);
    try std.testing.expect(!input.isHeld(.moveLeft));
    try std.testing.expect(input.isHeld(.moveUp));
}

test "input ignores command actions for held gameplay state" {
    const std = @import("std");
    var input = InputState{};

    input.setHeld(.pause, true);
    try std.testing.expectEqual(@as(f32, 0), input.movementVector().x);
    input.releaseMovement();
    try std.testing.expect(!input.isHeld(.pause));
}

test "movement vector resolves held movement actions" {
    const std = @import("std");
    var input = InputState{};

    input.setHeld(.moveRight, true);
    input.setHeld(.moveUp, true);
    const movement = input.movementVector();

    try std.testing.expectEqual(@as(f32, 1), movement.x);
    try std.testing.expectEqual(@as(f32, -1), movement.y);
}

test "frame commands latch non-repeated key down events" {
    const std = @import("std");
    var commands = FrameCommands{};

    commands.pressed_actions.set(.toggleDebugOverlay, true);
    commands.pressed_actions.set(.pause, true);
    commands.pressed_actions.set(.quit, true);
    commands.pressed_actions.set(.resumeGame, true);
    try std.testing.expect(commands.wasPressed(.toggleDebugOverlay));
    try std.testing.expect(commands.wasPressed(.pause));
    try std.testing.expect(commands.wasPressed(.quit));
    try std.testing.expect(commands.wasPressed(.resumeGame));

    commands.beginFrame();
    try std.testing.expect(!commands.wasPressed(.toggleDebugOverlay));
    try std.testing.expect(!commands.wasPressed(.pause));
    try std.testing.expect(!commands.wasPressed(.quit));
    try std.testing.expect(!commands.wasPressed(.resumeGame));
}

test "frame commands survive key up in the same frame" {
    const std = @import("std");
    var commands = FrameCommands{};
    var input = InputState{};
    var down_event = c.SDL_Event{ .key = .{
        .type = c.SDL_EVENT_KEY_DOWN,
        .reserved = 0,
        .timestamp = 0,
        .windowID = 0,
        .which = 0,
        .scancode = 0,
        .key = c.SDLK_F2,
        .mod = 0,
        .raw = 0,
        .down = true,
        .repeat = false,
    } };
    var up_event = c.SDL_Event{ .key = .{
        .type = c.SDL_EVENT_KEY_UP,
        .reserved = 0,
        .timestamp = 0,
        .windowID = 0,
        .which = 0,
        .scancode = 0,
        .key = c.SDLK_F2,
        .mod = 0,
        .raw = 0,
        .down = false,
        .repeat = false,
    } };

    commands.handleEvent(&down_event);
    input.handleEvent(&down_event);
    commands.handleEvent(&up_event);
    input.handleEvent(&up_event);

    try std.testing.expect(commands.wasPressed(.toggleDebugOverlay));
}

test "frame commands ignore repeated command keys" {
    const std = @import("std");
    var commands = FrameCommands{};
    var event = c.SDL_Event{ .key = .{
        .type = c.SDL_EVENT_KEY_DOWN,
        .reserved = 0,
        .timestamp = 0,
        .windowID = 0,
        .which = 0,
        .scancode = 0,
        .key = c.SDLK_F2,
        .mod = 0,
        .raw = 0,
        .down = true,
        .repeat = true,
    } };

    commands.handleEvent(&event);

    try std.testing.expect(!commands.wasPressed(.toggleDebugOverlay));
}

test "input can release held movement when gameplay is paused" {
    const std = @import("std");
    var input = InputState{};
    input.setHeld(.moveLeft, true);
    input.setHeld(.moveRight, true);
    input.setHeld(.moveUp, true);
    input.setHeld(.moveDown, true);

    input.releaseMovement();

    try std.testing.expect(!input.isHeld(.moveLeft));
    try std.testing.expect(!input.isHeld(.moveRight));
    try std.testing.expect(!input.isHeld(.moveUp));
    try std.testing.expect(!input.isHeld(.moveDown));
}
