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

/// Keyboard-oriented entry point. Gamepad button/axis events are dropped
/// (no active pad). Prefer `routeEventWithGamepad` from the engine path.
pub fn routeEvent(
    policy: InputRoutingPolicy,
    event: *const c.SDL_Event,
    input: *InputState,
    commands: *FrameCommands,
) void {
    routeEventWithGamepad(policy, event, input, commands, null);
}

/// Routes a raw SDL event through `policy` into held gameplay input or
/// one-frame commands. `active_gamepad_id` filters GAMEPAD_BUTTON_* and
/// GAMEPAD_AXIS_MOTION to the single open pad: when `null`, all pad input is
/// dropped (no active device); when set, only events whose `which` matches
/// are accepted. Keyboard events ignore `active_gamepad_id`.
/// Defense-in-depth: `Engine.handleEvents` already gates via `shouldDeliverEvent`
/// before state `handleEvent` and this router, so menus cannot see non-active pads.
pub fn routeEventWithGamepad(
    policy: InputRoutingPolicy,
    event: *const c.SDL_Event,
    input: *InputState,
    commands: *FrameCommands,
    active_gamepad_id: ?c.SDL_JoystickID,
) void {
    switch (event.type) {
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
            const action = inputFile.actionForKey(event.key.key) orelse return;
            routeAction(policy, action, event.type == c.SDL_EVENT_KEY_DOWN, event.key.repeat, input, commands);
        },
        c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_EVENT_GAMEPAD_BUTTON_UP => {
            if (!isActiveGamepadEvent(active_gamepad_id, event.gbutton.which)) return;
            const action = inputFile.actionForGamepadButton(@intCast(event.gbutton.button)) orelse return;
            // Gamepad buttons never repeat: SDL does not synthesize repeat
            // events for held gamepad buttons the way it does for keys.
            routeAction(policy, action, event.type == c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, false, input, commands);
        },
        c.SDL_EVENT_GAMEPAD_AXIS_MOTION => {
            if (!isActiveGamepadEvent(active_gamepad_id, event.gaxis.which)) return;
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

/// Single-active-gamepad gate used by `Engine.handleEvents` **before** state
/// `handleEvent` and router dispatch. Non pad-input events always pass (including
/// `GAMEPAD_ADDED`/`REMOVED` lifecycle events). `GAMEPAD_BUTTON_*` and
/// `GAMEPAD_AXIS_MOTION` pass only when `active_gamepad_id` is set and equals the
/// event's `which`; when no pad is open (`null`), all pad input is dropped.
///
/// Menus resolve presses via `actionForPressEvent` without a `which` filter, so
/// this early gate is what keeps a second controller from stealing menu control.
/// `routeEventWithGamepad` re-checks the same rule as defense-in-depth.
pub fn shouldDeliverEvent(event: *const c.SDL_Event, active_gamepad_id: ?c.SDL_JoystickID) bool {
    return switch (event.type) {
        c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_EVENT_GAMEPAD_BUTTON_UP => isActiveGamepadEvent(active_gamepad_id, event.gbutton.which),
        c.SDL_EVENT_GAMEPAD_AXIS_MOTION => isActiveGamepadEvent(active_gamepad_id, event.gaxis.which),
        else => true,
    };
}

/// True when `event_which` is the currently active single gamepad. `null`
/// active id means no pad is open — every pad event is rejected.
fn isActiveGamepadEvent(active_gamepad_id: ?c.SDL_JoystickID, event_which: c.SDL_JoystickID) bool {
    const active_id = active_gamepad_id orelse return false;
    return active_id == event_which;
}

/// Gates `action` through `policy`, then routes it to held gameplay input
/// (`InputState`) or a one-frame command (`FrameCommands`) on a fresh
/// down-press. Shared by keyboard and gamepad button events so both device
/// kinds go through identical policy and latch semantics.
///
/// Held-gameplay **UP** is accepted even when the policy blocks the gameplay
/// context, so dig/move cannot trap under a modal that only blocks DOWN.
/// Held-gameplay **DOWN** still requires the policy to allow the action.
fn routeAction(policy: InputRoutingPolicy, action: Action, is_down: bool, is_repeat: bool, input: *InputState, commands: *FrameCommands) void {
    if (isGameplayAction(action)) {
        if (is_down) {
            if (!policy.allowsAction(action)) return;
            input.setHeld(action, true);
        } else {
            // Always clear on UP, even under modalUi / opaqueScreen.
            input.setHeld(action, false);
        }
        return;
    }
    if (!policy.allowsAction(action)) return;
    if (is_down and !is_repeat) {
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

const test_active_gamepad_id: c.SDL_JoystickID = 1;
const test_other_gamepad_id: c.SDL_JoystickID = 2;

fn gamepadButtonEvent(event_type: u32, button: c.SDL_GamepadButton, down: bool) c.SDL_Event {
    return gamepadButtonEventFrom(event_type, button, down, test_active_gamepad_id);
}

fn gamepadButtonEventFrom(event_type: u32, button: c.SDL_GamepadButton, down: bool, which: c.SDL_JoystickID) c.SDL_Event {
    return c.SDL_Event{ .gbutton = .{
        .type = event_type,
        .reserved = 0,
        .timestamp = 0,
        .which = which,
        .button = @intCast(button),
        .down = down,
        .padding1 = 0,
        .padding2 = 0,
    } };
}

fn gamepadAxisEvent(axis: c.SDL_GamepadAxis, value: i16) c.SDL_Event {
    return gamepadAxisEventFrom(axis, value, test_active_gamepad_id);
}

fn gamepadAxisEventFrom(axis: c.SDL_GamepadAxis, value: i16, which: c.SDL_JoystickID) c.SDL_Event {
    return c.SDL_Event{ .gaxis = .{
        .type = c.SDL_EVENT_GAMEPAD_AXIS_MOTION,
        .reserved = 0,
        .timestamp = 0,
        .which = which,
        .axis = @intCast(axis),
        .padding1 = 0,
        .padding2 = 0,
        .padding3 = 0,
        .value = value,
        .padding4 = 0,
    } };
}

fn gamepadDeviceEvent(event_type: u32, which: c.SDL_JoystickID) c.SDL_Event {
    return c.SDL_Event{ .gdevice = .{
        .type = event_type,
        .reserved = 0,
        .timestamp = 0,
        .which = which,
    } };
}

/// Routes with the synthetic active pad id used by gamepad unit fixtures.
fn routeGamepadEvent(policy: InputRoutingPolicy, event: *const c.SDL_Event, input: *InputState, commands: *FrameCommands) void {
    routeEventWithGamepad(policy, event, input, commands, test_active_gamepad_id);
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

    // UP clears held gameplay even under modalUi so dig/move cannot trap.
    routeEvent(InputRoutingPolicy.modalUi(), &up_event, &input, &commands);
    try std.testing.expect(!input.isHeld(.move_left));
}

test "held dig DOWN under modal is ignored; dig UP under modal clears if held" {
    var input = InputState{};
    var commands = FrameCommands{};
    var dig_down = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_E, false);
    var dig_up = keyEvent(c.SDL_EVENT_KEY_UP, c.SDLK_E, false);

    // DOWN under modal must not latch dig.
    routeEvent(InputRoutingPolicy.modalUi(), &dig_down, &input, &commands);
    try std.testing.expect(!input.isHeld(.dig_hole));

    // Latch dig under gameplay, then modal blocks further DOWN.
    routeEvent(InputRoutingPolicy.gameplay(), &dig_down, &input, &commands);
    try std.testing.expect(input.isHeld(.dig_hole));
    routeEvent(InputRoutingPolicy.modalUi(), &dig_down, &input, &commands);
    try std.testing.expect(input.isHeld(.dig_hole));

    // UP under modal clears the prior hold.
    routeEvent(InputRoutingPolicy.modalUi(), &dig_up, &input, &commands);
    try std.testing.expect(!input.isHeld(.dig_hole));
}

test "releaseHeldGameplay after dig hold leaves dig not held under modal" {
    var input = InputState{};
    var commands = FrameCommands{};
    var dig_down = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_E, false);

    routeEvent(InputRoutingPolicy.gameplay(), &dig_down, &input, &commands);
    try std.testing.expect(input.isHeld(.dig_hole));

    // Simulate pause/gameplay-block release path.
    input.releaseHeldGameplay();
    try std.testing.expect(!input.isHeld(.dig_hole));

    // Subsequent DOWN under modal still ignored.
    routeEvent(InputRoutingPolicy.modalUi(), &dig_down, &input, &commands);
    try std.testing.expect(!input.isHeld(.dig_hole));
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

    routeGamepadEvent(InputRoutingPolicy.modalUi(), &down_event, &input, &commands);
    try std.testing.expect(!input.isHeld(.dig_hole));

    routeGamepadEvent(InputRoutingPolicy.gameplay(), &down_event, &input, &commands);
    try std.testing.expect(input.isHeld(.dig_hole));

    // UP clears dig even under modalUi (same as keyboard held-gameplay UP).
    routeGamepadEvent(InputRoutingPolicy.modalUi(), &up_event, &input, &commands);
    try std.testing.expect(!input.isHeld(.dig_hole));
}

test "routed gamepad app and debug button commands honor context, mirroring keyboard" {
    var input = InputState{};
    var commands = FrameCommands{};
    var pause_event = gamepadButtonEvent(c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_GAMEPAD_BUTTON_START, true);
    var debug_event = gamepadButtonEvent(c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_GAMEPAD_BUTTON_BACK, true);

    routeGamepadEvent(InputRoutingPolicy.gameplay(), &pause_event, &input, &commands);
    try std.testing.expect(commands.wasPressed(.pause));

    routeGamepadEvent(InputRoutingPolicy.gameplay().withContext(.debug, false), &debug_event, &input, &commands);
    try std.testing.expect(!commands.wasPressed(.toggle_debug_overlay));

    routeGamepadEvent(InputRoutingPolicy.gameplay(), &debug_event, &input, &commands);
    try std.testing.expect(commands.wasPressed(.toggle_debug_overlay));
}

test "routed gamepad menu navigation matches every InputRoutingPolicy preset like keyboard" {
    var input = InputState{};
    var commands = FrameCommands{};
    var menu_event = gamepadButtonEvent(c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_GAMEPAD_BUTTON_DPAD_UP, true);

    routeGamepadEvent(InputRoutingPolicy.gameplay(), &menu_event, &input, &commands);
    try std.testing.expect(!commands.wasPressed(.menu_up));

    routeGamepadEvent(InputRoutingPolicy.modalUi(), &menu_event, &input, &commands);
    try std.testing.expect(commands.wasPressed(.menu_up));

    commands.beginFrame();
    routeGamepadEvent(InputRoutingPolicy.opaqueScreen(), &menu_event, &input, &commands);
    try std.testing.expect(commands.wasPressed(.menu_up));

    commands.beginFrame();
    routeGamepadEvent(InputRoutingPolicy.passThroughOverlay(), &menu_event, &input, &commands);
    try std.testing.expect(commands.wasPressed(.menu_up));
}

test "gamepad left stick axis motion is gated by gameplay context" {
    var input = InputState{};
    var commands = FrameCommands{};
    var left_x = gamepadAxisEvent(c.SDL_GAMEPAD_AXIS_LEFTX, 32767);

    routeGamepadEvent(InputRoutingPolicy.modalUi(), &left_x, &input, &commands);
    try std.testing.expectEqual(@as(i16, 0), input.gamepad_stick_x_raw);

    routeGamepadEvent(InputRoutingPolicy.gameplay(), &left_x, &input, &commands);
    try std.testing.expectEqual(@as(i16, 32767), input.gamepad_stick_x_raw);
}

test "non-left-stick gamepad axis motion is a no-op" {
    var input = InputState{};
    var commands = FrameCommands{};
    var right_x = gamepadAxisEvent(c.SDL_GAMEPAD_AXIS_RIGHTX, 32767);

    routeGamepadEvent(InputRoutingPolicy.gameplay(), &right_x, &input, &commands);
    try std.testing.expectEqual(@as(i16, 0), input.gamepad_stick_x_raw);
    try std.testing.expectEqual(@as(i16, 0), input.gamepad_stick_y_raw);
}

test "gamepad button and axis events from a non-active device are dropped" {
    var input = InputState{};
    var commands = FrameCommands{};
    var other_button = gamepadButtonEventFrom(
        c.SDL_EVENT_GAMEPAD_BUTTON_DOWN,
        c.SDL_GAMEPAD_BUTTON_WEST,
        true,
        test_other_gamepad_id,
    );
    var other_axis = gamepadAxisEventFrom(c.SDL_GAMEPAD_AXIS_LEFTX, 32767, test_other_gamepad_id);
    var active_button = gamepadButtonEvent(c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_GAMEPAD_BUTTON_WEST, true);
    var active_axis = gamepadAxisEvent(c.SDL_GAMEPAD_AXIS_LEFTX, 16000);

    // Active pad id is test_active_gamepad_id; other device is ignored.
    routeEventWithGamepad(InputRoutingPolicy.gameplay(), &other_button, &input, &commands, test_active_gamepad_id);
    try std.testing.expect(!input.isHeld(.dig_hole));
    routeEventWithGamepad(InputRoutingPolicy.gameplay(), &other_axis, &input, &commands, test_active_gamepad_id);
    try std.testing.expectEqual(@as(i16, 0), input.gamepad_stick_x_raw);

    routeEventWithGamepad(InputRoutingPolicy.gameplay(), &active_button, &input, &commands, test_active_gamepad_id);
    try std.testing.expect(input.isHeld(.dig_hole));
    routeEventWithGamepad(InputRoutingPolicy.gameplay(), &active_axis, &input, &commands, test_active_gamepad_id);
    try std.testing.expectEqual(@as(i16, 16000), input.gamepad_stick_x_raw);
}

test "gamepad button and axis events are dropped when no active pad is open" {
    var input = InputState{};
    var commands = FrameCommands{};
    var button = gamepadButtonEvent(c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_GAMEPAD_BUTTON_WEST, true);
    var axis = gamepadAxisEvent(c.SDL_GAMEPAD_AXIS_LEFTX, 32767);
    var pause = gamepadButtonEvent(c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_GAMEPAD_BUTTON_START, true);

    // null active id = no open pad; all pad input (gameplay + app) is dropped.
    routeEventWithGamepad(InputRoutingPolicy.gameplay(), &button, &input, &commands, null);
    try std.testing.expect(!input.isHeld(.dig_hole));
    routeEventWithGamepad(InputRoutingPolicy.gameplay(), &axis, &input, &commands, null);
    try std.testing.expectEqual(@as(i16, 0), input.gamepad_stick_x_raw);
    routeEventWithGamepad(InputRoutingPolicy.gameplay(), &pause, &input, &commands, null);
    try std.testing.expect(!commands.wasPressed(.pause));

    // Four-arg routeEvent is the no-active-pad convenience path.
    routeEvent(InputRoutingPolicy.gameplay(), &button, &input, &commands);
    try std.testing.expect(!input.isHeld(.dig_hole));
}

test "isActiveGamepadEvent matches only the open device id" {
    try std.testing.expect(!isActiveGamepadEvent(null, test_active_gamepad_id));
    try std.testing.expect(isActiveGamepadEvent(test_active_gamepad_id, test_active_gamepad_id));
    try std.testing.expect(!isActiveGamepadEvent(test_active_gamepad_id, test_other_gamepad_id));
}

test "shouldDeliverEvent admits only the active pad before menu/router path" {
    // Two synthetic which values: only the active device reaches handleEvent/router.
    var active_button = gamepadButtonEvent(c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_GAMEPAD_BUTTON_DPAD_UP, true);
    var other_button = gamepadButtonEventFrom(
        c.SDL_EVENT_GAMEPAD_BUTTON_DOWN,
        c.SDL_GAMEPAD_BUTTON_DPAD_UP,
        true,
        test_other_gamepad_id,
    );
    var active_axis = gamepadAxisEvent(c.SDL_GAMEPAD_AXIS_LEFTX, 16000);
    var other_axis = gamepadAxisEventFrom(c.SDL_GAMEPAD_AXIS_LEFTX, 16000, test_other_gamepad_id);
    var key_down = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_RETURN, false);
    var added = gamepadDeviceEvent(c.SDL_EVENT_GAMEPAD_ADDED, test_other_gamepad_id);

    try std.testing.expect(shouldDeliverEvent(&active_button, test_active_gamepad_id));
    try std.testing.expect(!shouldDeliverEvent(&other_button, test_active_gamepad_id));
    try std.testing.expect(shouldDeliverEvent(&active_axis, test_active_gamepad_id));
    try std.testing.expect(!shouldDeliverEvent(&other_axis, test_active_gamepad_id));

    // No open pad: all pad input dropped; keyboard and lifecycle still pass.
    try std.testing.expect(!shouldDeliverEvent(&active_button, null));
    try std.testing.expect(!shouldDeliverEvent(&active_axis, null));
    try std.testing.expect(shouldDeliverEvent(&key_down, null));
    try std.testing.expect(shouldDeliverEvent(&added, test_active_gamepad_id));
    try std.testing.expect(shouldDeliverEvent(&key_down, test_active_gamepad_id));
}
