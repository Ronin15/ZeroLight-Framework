// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const math = @import("../core/math.zig");
const c = @import("../platform/sdl.zig").c;

pub const Action = enum(usize) {
    move_left,
    move_right,
    move_up,
    move_down,
    pause,
    resume_game,
    quit,
    toggle_debug_overlay,
    menu_up,
    menu_down,
    menu_left,
    menu_right,
    dig_hole,
    dig_ramp,
    dig_down,
};

const action_count = @typeInfo(Action).@"enum".fields.len;

pub const KeyBinding = struct {
    key: c.SDL_Keycode,
    action: Action,
};

pub const default_key_bindings = [_]KeyBinding{
    .{ .key = c.SDLK_A, .action = .move_left },
    .{ .key = c.SDLK_D, .action = .move_right },
    .{ .key = c.SDLK_W, .action = .move_up },
    .{ .key = c.SDLK_S, .action = .move_down },
    .{ .key = c.SDLK_P, .action = .pause },
    .{ .key = c.SDLK_RETURN, .action = .resume_game },
    .{ .key = c.SDLK_SPACE, .action = .resume_game },
    .{ .key = c.SDLK_ESCAPE, .action = .quit },
    .{ .key = c.SDLK_F2, .action = .toggle_debug_overlay },
    .{ .key = c.SDLK_UP, .action = .menu_up },
    .{ .key = c.SDLK_DOWN, .action = .menu_down },
    .{ .key = c.SDLK_LEFT, .action = .menu_left },
    .{ .key = c.SDLK_RIGHT, .action = .menu_right },
    .{ .key = c.SDLK_E, .action = .dig_hole },
    .{ .key = c.SDLK_Q, .action = .dig_ramp },
    .{ .key = c.SDLK_F, .action = .dig_down },
};

pub const GamepadButtonBinding = struct {
    button: c.SDL_GamepadButton,
    action: Action,
};

pub const default_gamepad_bindings = [_]GamepadButtonBinding{
    .{ .button = c.SDL_GAMEPAD_BUTTON_DPAD_UP, .action = .menu_up },
    .{ .button = c.SDL_GAMEPAD_BUTTON_DPAD_DOWN, .action = .menu_down },
    .{ .button = c.SDL_GAMEPAD_BUTTON_DPAD_LEFT, .action = .menu_left },
    .{ .button = c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT, .action = .menu_right },
    .{ .button = c.SDL_GAMEPAD_BUTTON_SOUTH, .action = .resume_game },
    .{ .button = c.SDL_GAMEPAD_BUTTON_EAST, .action = .quit },
    .{ .button = c.SDL_GAMEPAD_BUTTON_START, .action = .pause },
    .{ .button = c.SDL_GAMEPAD_BUTTON_WEST, .action = .dig_hole },
    .{ .button = c.SDL_GAMEPAD_BUTTON_NORTH, .action = .dig_ramp },
    .{ .button = c.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER, .action = .dig_down },
    .{ .button = c.SDL_GAMEPAD_BUTTON_BACK, .action = .toggle_debug_overlay },
};

/// Radial deadzone applied to the raw left-stick axes before they contribute
/// to `movementVector`. ~8000/32767, SDL's own documented center noise band.
const gamepad_stick_deadzone: f32 = 0.24;
const gamepad_stick_axis_max: f32 = 32767.0;

pub const InputState = struct {
    held_actions: ActionFlags = .{},
    gamepad_stick_x_raw: i16 = 0,
    gamepad_stick_y_raw: i16 = 0,

    pub fn releaseMovement(self: *InputState) void {
        inline for (movement_actions) |action| {
            self.held_actions.set(action, false);
        }
        self.gamepad_stick_x_raw = 0;
        self.gamepad_stick_y_raw = 0;
    }

    /// Clears every held gameplay action (movement + dig) and stick deflection.
    /// Used when gameplay context is lost (pause enter/exit, modal stack
    /// transitions) so dig cannot stick across a blocked update interval.
    pub fn releaseHeldGameplay(self: *InputState) void {
        self.releaseMovement();
        self.held_actions.set(.dig_hole, false);
        self.held_actions.set(.dig_ramp, false);
        self.held_actions.set(.dig_down, false);
    }

    /// Gamepad-disconnect path: same clear as `releaseHeldGameplay`. A dig
    /// button held at unplug would otherwise never see a button-up event.
    pub fn releaseGamepadInput(self: *InputState) void {
        self.releaseHeldGameplay();
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

    /// Sets whichever of the raw left-stick axes is non-null. The router calls
    /// this once per axis-motion event since SDL delivers X/Y separately.
    pub fn handleGamepadAxis(self: *InputState, raw_x: ?i16, raw_y: ?i16) void {
        if (raw_x) |x| self.gamepad_stick_x_raw = x;
        if (raw_y) |y| self.gamepad_stick_y_raw = y;
    }

    pub fn movementVector(self: *const InputState) math.Vec2 {
        var direction = math.Vec2{};
        if (self.isHeld(.move_left)) direction.x -= 1;
        if (self.isHeld(.move_right)) direction.x += 1;
        if (self.isHeld(.move_up)) direction.y -= 1;
        if (self.isHeld(.move_down)) direction.y += 1;
        const stick = deadzonedStick(self.gamepad_stick_x_raw, self.gamepad_stick_y_raw);
        return .{
            .x = math.clamp(direction.x + stick.x, -1, 1),
            .y = math.clamp(direction.y + stick.y, -1, 1),
        };
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

    /// Latches a one-frame command action, mirroring `InputState.setHeld`.
    pub fn press(self: *FrameCommands, action: Action) void {
        if (!isCommandAction(action)) return;
        self.pressed_actions.set(action, true);
    }
};

const movement_actions = [_]Action{
    .move_left,
    .move_right,
    .move_up,
    .move_down,
};

fn isGameplayAction(action: Action) bool {
    return switch (action) {
        .move_left, .move_right, .move_up, .move_down, .dig_hole, .dig_ramp, .dig_down => true,
        else => false,
    };
}

fn isCommandAction(action: Action) bool {
    return switch (action) {
        .pause, .resume_game, .quit, .toggle_debug_overlay, .menu_up, .menu_down, .menu_left, .menu_right => true,
        else => false,
    };
}

pub fn actionForKey(key: c.SDL_Keycode) ?Action {
    for (default_key_bindings) |binding| {
        if (binding.key == key) return binding.action;
    }
    return null;
}

pub fn actionForGamepadButton(button: c.SDL_GamepadButton) ?Action {
    for (default_gamepad_bindings) |binding| {
        if (binding.button == button) return binding.action;
    }
    return null;
}

/// Resolves the `Action` a fresh (non-repeat) key-down or gamepad button-down
/// event maps to, if any. Shared by menu states so they consume keyboard and
/// gamepad presses through one code path.
pub fn actionForPressEvent(event: *const c.SDL_Event) ?Action {
    return switch (event.type) {
        c.SDL_EVENT_KEY_DOWN => if (event.key.repeat) null else actionForKey(event.key.key),
        c.SDL_EVENT_GAMEPAD_BUTTON_DOWN => actionForGamepadButton(@intCast(event.gbutton.button)),
        else => null,
    };
}

fn axisToUnit(raw: i16) f32 {
    return @as(f32, @floatFromInt(raw)) / gamepad_stick_axis_max;
}

/// Converts raw left-stick axes to a normalized `Vec2` using a scaled radial
/// deadzone: magnitude within `gamepad_stick_deadzone` reports zero, and the
/// remaining `[deadzone, 1]` range is rescaled to `[0, 1]` so a corner-pushed
/// stick reports magnitude ~=1, not the raw unscaled diagonal value.
fn deadzonedStick(raw_x: i16, raw_y: i16) math.Vec2 {
    const unit = math.Vec2{ .x = axisToUnit(raw_x), .y = axisToUnit(raw_y) };
    const magnitude = math.length(unit);
    if (magnitude <= gamepad_stick_deadzone) return .{};
    const scaled = @min((magnitude - gamepad_stick_deadzone) / (1.0 - gamepad_stick_deadzone), 1.0);
    const ratio = scaled / magnitude;
    return .{ .x = unit.x * ratio, .y = unit.y * ratio };
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
    try std.testing.expectEqual(Action.move_left, actionForKey(c.SDLK_A).?);
    try std.testing.expectEqual(Action.move_right, actionForKey(c.SDLK_D).?);
    try std.testing.expectEqual(Action.move_up, actionForKey(c.SDLK_W).?);
    try std.testing.expectEqual(Action.move_down, actionForKey(c.SDLK_S).?);
    try std.testing.expectEqual(Action.pause, actionForKey(c.SDLK_P).?);
    try std.testing.expectEqual(Action.resume_game, actionForKey(c.SDLK_RETURN).?);
    try std.testing.expectEqual(Action.resume_game, actionForKey(c.SDLK_SPACE).?);
    try std.testing.expectEqual(Action.quit, actionForKey(c.SDLK_ESCAPE).?);
    try std.testing.expectEqual(Action.toggle_debug_overlay, actionForKey(c.SDLK_F2).?);
    try std.testing.expectEqual(Action.menu_up, actionForKey(c.SDLK_UP).?);
    try std.testing.expectEqual(Action.menu_down, actionForKey(c.SDLK_DOWN).?);
    try std.testing.expectEqual(Action.menu_left, actionForKey(c.SDLK_LEFT).?);
    try std.testing.expectEqual(Action.menu_right, actionForKey(c.SDLK_RIGHT).?);
}

test "input key mapping tracks held gameplay actions" {
    var input = InputState{};

    input.setHeld(.move_left, true);
    input.setHeld(.move_up, true);
    try std.testing.expect(input.isHeld(.move_left));
    try std.testing.expect(input.isHeld(.move_up));
    try std.testing.expect(!input.isHeld(.move_right));
    try std.testing.expect(!input.isHeld(.move_down));

    input.setHeld(.move_left, false);
    try std.testing.expect(!input.isHeld(.move_left));
    try std.testing.expect(input.isHeld(.move_up));
}

test "input ignores command actions for held gameplay state" {
    var input = InputState{};

    input.setHeld(.pause, true);
    try std.testing.expectEqual(@as(f32, 0), input.movementVector().x);
    input.releaseMovement();
    try std.testing.expect(!input.isHeld(.pause));
}

test "movement vector resolves held movement actions" {
    var input = InputState{};

    input.setHeld(.move_right, true);
    input.setHeld(.move_up, true);
    const movement = input.movementVector();

    try std.testing.expectEqual(@as(f32, 1), movement.x);
    try std.testing.expectEqual(@as(f32, -1), movement.y);
}

test "frame commands latch non-repeated key down events" {
    var commands = FrameCommands{};

    commands.pressed_actions.set(.toggle_debug_overlay, true);
    commands.pressed_actions.set(.pause, true);
    commands.pressed_actions.set(.quit, true);
    commands.pressed_actions.set(.resume_game, true);
    try std.testing.expect(commands.wasPressed(.toggle_debug_overlay));
    try std.testing.expect(commands.wasPressed(.pause));
    try std.testing.expect(commands.wasPressed(.quit));
    try std.testing.expect(commands.wasPressed(.resume_game));

    commands.beginFrame();
    try std.testing.expect(!commands.wasPressed(.toggle_debug_overlay));
    try std.testing.expect(!commands.wasPressed(.pause));
    try std.testing.expect(!commands.wasPressed(.quit));
    try std.testing.expect(!commands.wasPressed(.resume_game));
}

test "frame commands survive key up in the same frame" {
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

    try std.testing.expect(commands.wasPressed(.toggle_debug_overlay));
}

test "frame commands ignore repeated command keys" {
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

    try std.testing.expect(!commands.wasPressed(.toggle_debug_overlay));
}

test "input can release held movement when gameplay is paused" {
    var input = InputState{};
    input.setHeld(.move_left, true);
    input.setHeld(.move_right, true);
    input.setHeld(.move_up, true);
    input.setHeld(.move_down, true);
    input.handleGamepadAxis(12000, -8000);

    input.releaseMovement();

    try std.testing.expect(!input.isHeld(.move_left));
    try std.testing.expect(!input.isHeld(.move_right));
    try std.testing.expect(!input.isHeld(.move_up));
    try std.testing.expect(!input.isHeld(.move_down));
    try std.testing.expectEqual(@as(i16, 0), input.gamepad_stick_x_raw);
    try std.testing.expectEqual(@as(i16, 0), input.gamepad_stick_y_raw);
}

test "releaseHeldGameplay clears movement, dig, and stick state together" {
    var input = InputState{};
    input.setHeld(.move_right, true);
    input.setHeld(.dig_hole, true);
    input.setHeld(.dig_ramp, true);
    input.setHeld(.dig_down, true);
    input.handleGamepadAxis(20000, 20000);

    input.releaseHeldGameplay();

    try std.testing.expect(!input.isHeld(.move_right));
    try std.testing.expect(!input.isHeld(.dig_hole));
    try std.testing.expect(!input.isHeld(.dig_ramp));
    try std.testing.expect(!input.isHeld(.dig_down));
    try std.testing.expectEqual(@as(i16, 0), input.gamepad_stick_x_raw);
    try std.testing.expectEqual(@as(i16, 0), input.gamepad_stick_y_raw);
}

test "releaseGamepadInput is the disconnect alias of releaseHeldGameplay" {
    var input = InputState{};
    input.setHeld(.dig_hole, true);
    input.handleGamepadAxis(10000, -10000);

    input.releaseGamepadInput();

    try std.testing.expect(!input.isHeld(.dig_hole));
    try std.testing.expectEqual(@as(i16, 0), input.gamepad_stick_x_raw);
    try std.testing.expectEqual(@as(i16, 0), input.gamepad_stick_y_raw);
}

test "releaseMovement leaves dig held so releaseHeldGameplay is required for dig clear" {
    var input = InputState{};
    input.setHeld(.move_left, true);
    input.setHeld(.dig_hole, true);
    input.setHeld(.dig_ramp, true);
    input.setHeld(.dig_down, true);

    input.releaseMovement();

    try std.testing.expect(!input.isHeld(.move_left));
    try std.testing.expect(input.isHeld(.dig_hole));
    try std.testing.expect(input.isHeld(.dig_ramp));
    try std.testing.expect(input.isHeld(.dig_down));

    input.releaseHeldGameplay();
    try std.testing.expect(!input.isHeld(.dig_hole));
    try std.testing.expect(!input.isHeld(.dig_ramp));
    try std.testing.expect(!input.isHeld(.dig_down));
}

test "actionForGamepadButton resolves every default binding and rejects unmapped buttons" {
    try std.testing.expectEqual(Action.menu_up, actionForGamepadButton(c.SDL_GAMEPAD_BUTTON_DPAD_UP).?);
    try std.testing.expectEqual(Action.menu_down, actionForGamepadButton(c.SDL_GAMEPAD_BUTTON_DPAD_DOWN).?);
    try std.testing.expectEqual(Action.menu_left, actionForGamepadButton(c.SDL_GAMEPAD_BUTTON_DPAD_LEFT).?);
    try std.testing.expectEqual(Action.menu_right, actionForGamepadButton(c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT).?);
    try std.testing.expectEqual(Action.resume_game, actionForGamepadButton(c.SDL_GAMEPAD_BUTTON_SOUTH).?);
    try std.testing.expectEqual(Action.quit, actionForGamepadButton(c.SDL_GAMEPAD_BUTTON_EAST).?);
    try std.testing.expectEqual(Action.pause, actionForGamepadButton(c.SDL_GAMEPAD_BUTTON_START).?);
    try std.testing.expectEqual(Action.dig_hole, actionForGamepadButton(c.SDL_GAMEPAD_BUTTON_WEST).?);
    try std.testing.expectEqual(Action.dig_ramp, actionForGamepadButton(c.SDL_GAMEPAD_BUTTON_NORTH).?);
    try std.testing.expectEqual(Action.dig_down, actionForGamepadButton(c.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER).?);
    try std.testing.expectEqual(Action.toggle_debug_overlay, actionForGamepadButton(c.SDL_GAMEPAD_BUTTON_BACK).?);
    try std.testing.expectEqual(@as(?Action, null), actionForGamepadButton(c.SDL_GAMEPAD_BUTTON_GUIDE));
}

fn gamepadButtonEvent(event_type: u32, button: c.SDL_GamepadButton, down: bool) c.SDL_Event {
    return c.SDL_Event{ .gbutton = .{
        .type = event_type,
        .reserved = 0,
        .timestamp = 0,
        .which = 0,
        .button = @intCast(button),
        .down = down,
        .padding1 = 0,
        .padding2 = 0,
    } };
}

test "actionForPressEvent resolves keyboard and gamepad press shapes" {
    var key_down = c.SDL_Event{ .key = .{
        .type = c.SDL_EVENT_KEY_DOWN,
        .reserved = 0,
        .timestamp = 0,
        .windowID = 0,
        .which = 0,
        .scancode = 0,
        .key = c.SDLK_A,
        .mod = 0,
        .raw = 0,
        .down = true,
        .repeat = false,
    } };
    try std.testing.expectEqual(Action.move_left, actionForPressEvent(&key_down).?);

    var key_repeat = key_down;
    key_repeat.key.repeat = true;
    try std.testing.expectEqual(@as(?Action, null), actionForPressEvent(&key_repeat));

    var key_up = key_down;
    key_up.type = c.SDL_EVENT_KEY_UP;
    try std.testing.expectEqual(@as(?Action, null), actionForPressEvent(&key_up));

    var gamepad_down = gamepadButtonEvent(c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_GAMEPAD_BUTTON_SOUTH, true);
    try std.testing.expectEqual(Action.resume_game, actionForPressEvent(&gamepad_down).?);

    var gamepad_unmapped = gamepadButtonEvent(c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_GAMEPAD_BUTTON_GUIDE, true);
    try std.testing.expectEqual(@as(?Action, null), actionForPressEvent(&gamepad_unmapped));
}

test "deadzonedStick zeroes small deflection and normalizes full deflection" {
    const inside_deadzone = deadzonedStick(4000, -3000);
    try std.testing.expectEqual(@as(f32, 0), inside_deadzone.x);
    try std.testing.expectEqual(@as(f32, 0), inside_deadzone.y);

    const single_axis_max = deadzonedStick(32767, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), math.length(single_axis_max), 0.01);
    try std.testing.expect(single_axis_max.x > 0.99);
    try std.testing.expectEqual(@as(f32, 0), single_axis_max.y);

    // Both axes pushed to the corner: scaled radial deadzone reports
    // magnitude ~=1, NOT the raw sqrt(2) diagonal magnitude.
    const corner: i16 = 23170; // 32767 / sqrt(2)
    const diagonal_max = deadzonedStick(corner, corner);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), math.length(diagonal_max), 0.02);
}

test "movementVector combines keyboard and gamepad stick input" {
    var keyboard_only = InputState{};
    keyboard_only.setHeld(.move_right, true);
    keyboard_only.setHeld(.move_up, true);
    const keyboard_movement = keyboard_only.movementVector();
    try std.testing.expectEqual(@as(f32, 1), keyboard_movement.x);
    try std.testing.expectEqual(@as(f32, -1), keyboard_movement.y);

    var same_axis = InputState{};
    same_axis.setHeld(.move_right, true);
    same_axis.handleGamepadAxis(32767, null);
    const same_axis_movement = same_axis.movementVector();
    try std.testing.expectEqual(@as(f32, 1), same_axis_movement.x);

    var independent_axes = InputState{};
    independent_axes.setHeld(.move_right, true);
    independent_axes.handleGamepadAxis(null, 32767);
    const independent_movement = independent_axes.movementVector();
    try std.testing.expectEqual(@as(f32, 1), independent_movement.x);
    try std.testing.expect(independent_movement.y > 0.99);
}
