// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Allocation-free input routing contracts for future gameplay, UI, and debug contexts.
//! This is not wired into Engine yet; keep it small enough for per-event or per-frame use.

const std = @import("std");
const Action = @import("input.zig").Action;

pub const InputContext = enum(usize) {
    gameplay,
    ui,
    debug,
};

const context_count = @typeInfo(InputContext).@"enum".fields.len;

pub const InputRoutingPolicy = struct {
    contexts: ContextFlags = ContextFlags.defaultGameplay(),

    pub fn gameplayOnly() InputRoutingPolicy {
        return .{ .contexts = ContextFlags.defaultGameplay() };
    }

    pub fn uiModal() InputRoutingPolicy {
        var contexts = ContextFlags{};
        contexts.set(.ui, true);
        contexts.set(.debug, true);
        return .{ .contexts = contexts };
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

pub fn contextForAction(action: Action) InputContext {
    return switch (action) {
        .moveLeft, .moveRight, .moveUp, .moveDown => .gameplay,
        .pause, .resumeGame, .quit => .ui,
        .toggleDebugOverlay => .debug,
    };
}

pub const ContextFlags = struct {
    values: [context_count]bool = [_]bool{false} ** context_count,

    pub fn defaultGameplay() ContextFlags {
        var flags = ContextFlags{};
        flags.set(.gameplay, true);
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

test "default input routing allows gameplay and debug actions" {
    const policy = InputRoutingPolicy.gameplayOnly();

    try std.testing.expect(policy.allowsAction(.moveLeft));
    try std.testing.expect(policy.allowsAction(.toggleDebugOverlay));
    try std.testing.expect(!policy.allowsAction(.pause));
}

test "ui modal routing blocks gameplay while keeping UI and debug commands" {
    const policy = InputRoutingPolicy.uiModal();

    try std.testing.expect(!policy.allowsAction(.moveRight));
    try std.testing.expect(policy.allowsAction(.pause));
    try std.testing.expect(policy.allowsAction(.quit));
    try std.testing.expect(policy.allowsAction(.toggleDebugOverlay));
}

test "input routing contexts can be toggled without allocation" {
    const policy = InputRoutingPolicy.gameplayOnly()
        .withContext(.gameplay, false)
        .withContext(.ui, true);

    try std.testing.expect(!policy.allowsContext(.gameplay));
    try std.testing.expect(policy.allowsContext(.ui));
    try std.testing.expect(policy.allowsContext(.debug));
}
