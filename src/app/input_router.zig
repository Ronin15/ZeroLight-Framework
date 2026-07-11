// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Allocation-free input routing for gameplay, UI, app command, and debug contexts.

const std = @import("std");
const inputFile = @import("input.zig");
const Action = @import("input.zig").Action;
const FrameCommands = @import("input.zig").FrameCommands;
const InputState = @import("input.zig").InputState;
const c = @import("../platform/sdl.zig").c;

pub const InputContext = enum(usize) {
    gameplay,
    ui,
    app,
    debug,
};

const context_count = @typeInfo(InputContext).@"enum".fields.len;

pub const InputRoutingPolicy = struct {
    contexts: ContextFlags = ContextFlags.defaultGameplay(),

    pub fn gameplay() InputRoutingPolicy {
        return .{ .contexts = ContextFlags.defaultGameplay() };
    }

    pub fn modalUi() InputRoutingPolicy {
        var contexts = ContextFlags{};
        contexts.set(.ui, true);
        contexts.set(.app, true);
        contexts.set(.debug, true);
        return .{ .contexts = contexts };
    }

    pub fn passThroughOverlay() InputRoutingPolicy {
        var contexts = ContextFlags.defaultGameplay();
        contexts.set(.ui, true);
        return .{ .contexts = contexts };
    }

    pub fn opaqueScreen() InputRoutingPolicy {
        return modalUi();
    }

    pub fn withContext(self: InputRoutingPolicy, context: InputContext, enabled: bool) InputRoutingPolicy {
        var next = self;
        next.contexts.set(context, enabled);
        return next;
    }

    pub fn allowsContext(self: InputRoutingPolicy, context: InputContext) bool {
        return self.contexts.get(context);
    }

    pub fn allowsAction(self: InputRoutingPolicy, action: Action) bool {
        return self.allowsContext(contextForAction(action));
    }
};

pub fn routeEvent(policy: InputRoutingPolicy, event: *const c.SDL_Event, input: *InputState, commands: *FrameCommands) void {
    switch (event.type) {
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
            const action = inputFile.actionForKey(event.key.key) orelse return;
            routeAction(policy, action, event.type == c.SDL_EVENT_KEY_DOWN, event.key.repeat, input, commands);
        },
        c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_EVENT_GAMEPAD_BUTTON_UP => {
            const action = inputFile.actionForGamepadButton(@intCast(event.gbutton.button)) orelse return;
            // Gamepad buttons never repeat: SDL does not synthesize repeat
            // events for held gamepad buttons the way it does for keys.
            routeAction(policy, action, event.type == c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, false, input, commands);
        },
        c.SDL_EVENT_GAMEPAD_AXIS_MOTION => {
            if (!policy.allowsContext(.gameplay)) return;
            const axis: c.SDL_GamepadAxis = @intCast(event.gaxis.axis);
            switch (axis) {
                c.SDL_GAMEPAD_AXIS_LEFTX => input.handleGamepadAxis(event.gaxis.value, null),
                c.SDL_GAMEPAD_AXIS_LEFTY => input.handleGamepadAxis(null, event.gaxis.value),
                else => {},
            }
        },
        else => {},
    }
}

/// Gates `action` through `policy`, then routes it to held gameplay input
/// (`InputState`) or a one-frame command (`FrameCommands`) on a fresh
/// down-press. Shared by keyboard and gamepad button events so both device
/// kinds go through identical policy and latch semantics.
fn routeAction(policy: InputRoutingPolicy, action: Action, is_down: bool, is_repeat: bool, input: *InputState, commands: *FrameCommands) void {
    if (!policy.allowsAction(action)) return;
    if (isGameplayAction(action)) {
        input.setHeld(action, is_down);
    } else if (is_down and !is_repeat) {
        commands.press(action);
    }
}

pub fn contextForAction(action: Action) InputContext {
    return switch (action) {
        .move_left, .move_right, .move_up, .move_down, .dig_hole, .dig_ramp, .dig_down => .gameplay,
        .pause, .resume_game, .quit => .app,
        .toggle_debug_overlay => .debug,
        .menu_up, .menu_down, .menu_left, .menu_right => .ui,
    };
}

pub const ContextFlags = struct {
    values: [context_count]bool = [_]bool{false} ** context_count,

    pub fn defaultGameplay() ContextFlags {
        var flags = ContextFlags{};
        flags.set(.gameplay, true);
        flags.set(.app, true);
        flags.set(.debug, true);
        return flags;
    }

    pub fn get(self: *const ContextFlags, context: InputContext) bool {
        return self.values[@intFromEnum(context)];
    }

    pub fn set(self: *ContextFlags, context: InputContext, value: bool) void {
        self.values[@intFromEnum(context)] = value;
    }
};

fn isGameplayAction(action: Action) bool {
    return switch (action) {
        .move_left, .move_right, .move_up, .move_down, .dig_hole, .dig_ramp, .dig_down => true,
        else => false,
    };
}

fn keyEvent(event_type: u32, key: c.SDL_Keycode, repeat: bool) c.SDL_Event {
    return c.SDL_Event{ .key = .{
        .type = event_type,
        .reserved = 0,
        .timestamp = 0,
        .windowID = 0,
        .which = 0,
        .scancode = 0,
        .key = key,
        .mod = 0,
        .raw = 0,
        .down = event_type == c.SDL_EVENT_KEY_DOWN,
        .repeat = repeat,
    } };
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

fn gamepadAxisEvent(axis: c.SDL_GamepadAxis, value: i16) c.SDL_Event {
    return c.SDL_Event{ .gaxis = .{
        .type = c.SDL_EVENT_GAMEPAD_AXIS_MOTION,
        .reserved = 0,
        .timestamp = 0,
        .which = 0,
        .axis = @intCast(axis),
        .padding1 = 0,
        .padding2 = 0,
        .padding3 = 0,
        .value = value,
        .padding4 = 0,
    } };
}

test "gameplay routing allows gameplay app and debug actions" {
    const policy = InputRoutingPolicy.gameplay();

    try std.testing.expect(policy.allowsAction(.move_left));
    try std.testing.expect(policy.allowsAction(.pause));
    try std.testing.expect(policy.allowsAction(.quit));
    try std.testing.expect(policy.allowsAction(.resume_game));
    try std.testing.expect(policy.allowsAction(.toggle_debug_overlay));
    try std.testing.expect(!policy.allowsAction(.menu_up));
    try std.testing.expect(!policy.allowsAction(.menu_down));
    try std.testing.expect(!policy.allowsContext(.ui));
}

test "ui modal routing blocks gameplay while keeping UI and debug commands" {
    const policy = InputRoutingPolicy.modalUi();

    try std.testing.expect(!policy.allowsAction(.move_right));
    try std.testing.expect(policy.allowsContext(.ui));
    try std.testing.expect(policy.allowsAction(.pause));
    try std.testing.expect(policy.allowsAction(.quit));
    try std.testing.expect(policy.allowsAction(.toggle_debug_overlay));
    try std.testing.expect(policy.allowsAction(.menu_up));
    try std.testing.expect(policy.allowsAction(.menu_down));
    try std.testing.expect(policy.allowsAction(.menu_left));
    try std.testing.expect(policy.allowsAction(.menu_right));
}

test "pass through overlay routing allows gameplay ui app and debug contexts" {
    const policy = InputRoutingPolicy.passThroughOverlay();

    try std.testing.expect(policy.allowsContext(.gameplay));
    try std.testing.expect(policy.allowsContext(.ui));
    try std.testing.expect(policy.allowsContext(.app));
    try std.testing.expect(policy.allowsContext(.debug));
}

test "input routing contexts can be toggled without allocation" {
    const policy = InputRoutingPolicy.gameplay()
        .withContext(.gameplay, false)
        .withContext(.ui, true);

    try std.testing.expect(!policy.allowsContext(.gameplay));
    try std.testing.expect(policy.allowsContext(.ui));
    try std.testing.expect(policy.allowsContext(.debug));
}

test "routed gameplay events mutate held input only when gameplay is allowed" {
    var input = InputState{};
    var commands = FrameCommands{};
    var down_event = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_A, false);
    var up_event = keyEvent(c.SDL_EVENT_KEY_UP, c.SDLK_A, false);

    routeEvent(InputRoutingPolicy.modalUi(), &down_event, &input, &commands);
    try std.testing.expect(!input.isHeld(.move_left));

    routeEvent(InputRoutingPolicy.gameplay(), &down_event, &input, &commands);
    try std.testing.expect(input.isHeld(.move_left));

    routeEvent(InputRoutingPolicy.modalUi(), &up_event, &input, &commands);
    try std.testing.expect(input.isHeld(.move_left));

    routeEvent(InputRoutingPolicy.gameplay(), &up_event, &input, &commands);
    try std.testing.expect(!input.isHeld(.move_left));
}

test "routed app and debug commands honor context and key repeat" {
    var input = InputState{};
    var commands = FrameCommands{};
    var pause_event = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_P, false);
    var repeated_pause_event = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_P, true);
    var debug_event = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_F2, false);

    routeEvent(InputRoutingPolicy.gameplay(), &pause_event, &input, &commands);
    try std.testing.expect(commands.wasPressed(.pause));

    commands.beginFrame();
    routeEvent(InputRoutingPolicy.gameplay(), &repeated_pause_event, &input, &commands);
    try std.testing.expect(!commands.wasPressed(.pause));

    routeEvent(InputRoutingPolicy.gameplay().withContext(.debug, false), &debug_event, &input, &commands);
    try std.testing.expect(!commands.wasPressed(.toggle_debug_overlay));

    routeEvent(InputRoutingPolicy.gameplay(), &debug_event, &input, &commands);
    try std.testing.expect(commands.wasPressed(.toggle_debug_overlay));
}

test "routed gamepad button events mutate held input only when gameplay is allowed" {
    var input = InputState{};
    var commands = FrameCommands{};
    var down_event = gamepadButtonEvent(c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_GAMEPAD_BUTTON_WEST, true);
    var up_event = gamepadButtonEvent(c.SDL_EVENT_GAMEPAD_BUTTON_UP, c.SDL_GAMEPAD_BUTTON_WEST, false);

    routeEvent(InputRoutingPolicy.modalUi(), &down_event, &input, &commands);
    try std.testing.expect(!input.isHeld(.dig_hole));

    routeEvent(InputRoutingPolicy.gameplay(), &down_event, &input, &commands);
    try std.testing.expect(input.isHeld(.dig_hole));

    routeEvent(InputRoutingPolicy.modalUi(), &up_event, &input, &commands);
    try std.testing.expect(input.isHeld(.dig_hole));

    routeEvent(InputRoutingPolicy.gameplay(), &up_event, &input, &commands);
    try std.testing.expect(!input.isHeld(.dig_hole));
}

test "routed gamepad app and debug button commands honor context, mirroring keyboard" {
    var input = InputState{};
    var commands = FrameCommands{};
    var pause_event = gamepadButtonEvent(c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_GAMEPAD_BUTTON_START, true);
    var debug_event = gamepadButtonEvent(c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_GAMEPAD_BUTTON_BACK, true);

    routeEvent(InputRoutingPolicy.gameplay(), &pause_event, &input, &commands);
    try std.testing.expect(commands.wasPressed(.pause));

    routeEvent(InputRoutingPolicy.gameplay().withContext(.debug, false), &debug_event, &input, &commands);
    try std.testing.expect(!commands.wasPressed(.toggle_debug_overlay));

    routeEvent(InputRoutingPolicy.gameplay(), &debug_event, &input, &commands);
    try std.testing.expect(commands.wasPressed(.toggle_debug_overlay));
}

test "routed gamepad menu navigation matches every InputRoutingPolicy preset like keyboard" {
    var input = InputState{};
    var commands = FrameCommands{};
    var menu_event = gamepadButtonEvent(c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_GAMEPAD_BUTTON_DPAD_UP, true);

    routeEvent(InputRoutingPolicy.gameplay(), &menu_event, &input, &commands);
    try std.testing.expect(!commands.wasPressed(.menu_up));

    routeEvent(InputRoutingPolicy.modalUi(), &menu_event, &input, &commands);
    try std.testing.expect(commands.wasPressed(.menu_up));

    commands.beginFrame();
    routeEvent(InputRoutingPolicy.opaqueScreen(), &menu_event, &input, &commands);
    try std.testing.expect(commands.wasPressed(.menu_up));

    commands.beginFrame();
    routeEvent(InputRoutingPolicy.passThroughOverlay(), &menu_event, &input, &commands);
    try std.testing.expect(commands.wasPressed(.menu_up));
}

test "gamepad left stick axis motion is gated by gameplay context" {
    var input = InputState{};
    var commands = FrameCommands{};
    var left_x = gamepadAxisEvent(c.SDL_GAMEPAD_AXIS_LEFTX, 32767);

    routeEvent(InputRoutingPolicy.modalUi(), &left_x, &input, &commands);
    try std.testing.expectEqual(@as(i16, 0), input.gamepad_stick_x_raw);

    routeEvent(InputRoutingPolicy.gameplay(), &left_x, &input, &commands);
    try std.testing.expectEqual(@as(i16, 32767), input.gamepad_stick_x_raw);
}

test "non-left-stick gamepad axis motion is a no-op" {
    var input = InputState{};
    var commands = FrameCommands{};
    var right_x = gamepadAxisEvent(c.SDL_GAMEPAD_AXIS_RIGHTX, 32767);

    routeEvent(InputRoutingPolicy.gameplay(), &right_x, &input, &commands);
    try std.testing.expectEqual(@as(i16, 0), input.gamepad_stick_x_raw);
    try std.testing.expectEqual(@as(i16, 0), input.gamepad_stick_y_raw);
}
