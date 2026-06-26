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
            if (!policy.allowsAction(action)) return;
            if (isGameplayAction(action)) {
                input.handleEvent(event);
            } else if (event.type == c.SDL_EVENT_KEY_DOWN) {
                commands.handleEvent(event);
            }
        },
        else => {},
    }
}

pub fn contextForAction(action: Action) InputContext {
    return switch (action) {
        .moveLeft, .moveRight, .moveUp, .moveDown, .digHole, .digRamp => .gameplay,
        .pause, .resumeGame, .quit => .app,
        .toggleDebugOverlay => .debug,
        .menuUp, .menuDown, .menuLeft, .menuRight => .ui,
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
        .moveLeft, .moveRight, .moveUp, .moveDown, .digHole, .digRamp => true,
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

test "gameplay routing allows gameplay app and debug actions" {
    const policy = InputRoutingPolicy.gameplay();

    try std.testing.expect(policy.allowsAction(.moveLeft));
    try std.testing.expect(policy.allowsAction(.pause));
    try std.testing.expect(policy.allowsAction(.quit));
    try std.testing.expect(policy.allowsAction(.resumeGame));
    try std.testing.expect(policy.allowsAction(.toggleDebugOverlay));
    try std.testing.expect(!policy.allowsAction(.menuUp));
    try std.testing.expect(!policy.allowsAction(.menuDown));
    try std.testing.expect(!policy.allowsContext(.ui));
}

test "ui modal routing blocks gameplay while keeping UI and debug commands" {
    const policy = InputRoutingPolicy.modalUi();

    try std.testing.expect(!policy.allowsAction(.moveRight));
    try std.testing.expect(policy.allowsContext(.ui));
    try std.testing.expect(policy.allowsAction(.pause));
    try std.testing.expect(policy.allowsAction(.quit));
    try std.testing.expect(policy.allowsAction(.toggleDebugOverlay));
    try std.testing.expect(policy.allowsAction(.menuUp));
    try std.testing.expect(policy.allowsAction(.menuDown));
    try std.testing.expect(policy.allowsAction(.menuLeft));
    try std.testing.expect(policy.allowsAction(.menuRight));
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
    try std.testing.expect(!input.isHeld(.moveLeft));

    routeEvent(InputRoutingPolicy.gameplay(), &down_event, &input, &commands);
    try std.testing.expect(input.isHeld(.moveLeft));

    routeEvent(InputRoutingPolicy.modalUi(), &up_event, &input, &commands);
    try std.testing.expect(input.isHeld(.moveLeft));

    routeEvent(InputRoutingPolicy.gameplay(), &up_event, &input, &commands);
    try std.testing.expect(!input.isHeld(.moveLeft));
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
    try std.testing.expect(!commands.wasPressed(.toggleDebugOverlay));

    routeEvent(InputRoutingPolicy.gameplay(), &debug_event, &input, &commands);
    try std.testing.expect(commands.wasPressed(.toggleDebugOverlay));
}
