// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Single-active-gamepad device lifecycle: first-connected-wins adoption,
//! hot-plug add/remove reaction, and fallback-to-next-device on disconnect.
//! `GamepadManager` owns at most one open `*SDL_Gamepad` handle at a time.

const std = @import("std");
const c = @import("../platform/sdl.zig").c;
const logging = @import("../core/logging.zig");
const log = logging.app;

const ActiveGamepad = struct {
    id: c.SDL_JoystickID,
    handle: *c.SDL_Gamepad,
};

pub const GamepadManager = struct {
    active: ?ActiveGamepad = null,

    pub fn init() GamepadManager {
        return .{};
    }

    pub fn deinit(self: *GamepadManager) void {
        if (self.active) |active| {
            c.SDL_CloseGamepad(active.handle);
            self.active = null;
        }
    }

    pub fn activeId(self: *const GamepadManager) ?c.SDL_JoystickID {
        return if (self.active) |active| active.id else null;
    }

    pub fn activeHandle(self: *const GamepadManager) ?*c.SDL_Gamepad {
        return if (self.active) |active| active.handle else null;
    }

    /// Enumerates already-connected devices at startup and adopts the first one
    /// found, if any. One-time cold-path `SDL_GetGamepads` allocation is fine
    /// here; this is not a hot path.
    pub fn openInitial(self: *GamepadManager) void {
        self.openFirstAvailable();
    }

    pub const DeviceChange = enum { none, connected, disconnected };

    pub fn handleDeviceEvent(self: *GamepadManager, event: *const c.SDL_Event) DeviceChange {
        return switch (event.type) {
            c.SDL_EVENT_GAMEPAD_ADDED => {
                if (!shouldAdopt(self.activeId())) return .none;
                return if (self.openDevice(event.gdevice.which)) .connected else .none;
            },
            c.SDL_EVENT_GAMEPAD_REMOVED => {
                if (!isActiveDevice(self.activeId(), event.gdevice.which)) return .none;
                self.closeActive();
                self.openFirstAvailable();
                return .disconnected;
            },
            else => .none,
        };
    }

    fn openDevice(self: *GamepadManager, id: c.SDL_JoystickID) bool {
        const handle = c.SDL_OpenGamepad(id) orelse return false;
        self.active = .{ .id = id, .handle = handle };
        if (logging.enabled(.debug)) {
            const name: [*:0]const u8 = c.SDL_GetGamepadName(handle) orelse "unknown";
            const type_name: [*:0]const u8 = c.SDL_GetGamepadStringForType(c.SDL_GetGamepadType(handle)) orelse "unknown";
            log.debug("gamepad connected: name=\"{s}\" type={s} id={}", .{ name, type_name, id });
        }
        return true;
    }

    fn closeActive(self: *GamepadManager) void {
        if (self.active) |active| {
            log.debug("gamepad disconnected: id={}", .{active.id});
            c.SDL_CloseGamepad(active.handle);
            self.active = null;
        }
    }

    fn openFirstAvailable(self: *GamepadManager) void {
        var count: c_int = 0;
        const ids = c.SDL_GetGamepads(&count) orelse return;
        defer c.SDL_free(ids);
        if (count <= 0) return;
        const available = ids[0..@intCast(count)];
        if (pickFallback(available)) |id| {
            _ = self.openDevice(id);
        }
    }
};

/// True iff nothing is currently active — first-connected-wins adoption.
fn shouldAdopt(current_id: ?c.SDL_JoystickID) bool {
    return current_id == null;
}

/// True iff `candidate_id` is the currently active device.
fn isActiveDevice(current_id: ?c.SDL_JoystickID, candidate_id: c.SDL_JoystickID) bool {
    return current_id != null and current_id.? == candidate_id;
}

/// First-available-wins fallback pick after a disconnect.
fn pickFallback(available: []const c.SDL_JoystickID) ?c.SDL_JoystickID {
    if (available.len == 0) return null;
    return available[0];
}

// SDL_OpenGamepad/SDL_GetGamepads themselves are not unit-testable: there is
// no real or virtual gamepad device in this environment/CI.

test "shouldAdopt only adopts when nothing is active" {
    try std.testing.expect(shouldAdopt(null));
    try std.testing.expect(!shouldAdopt(@as(c.SDL_JoystickID, 7)));
}

test "isActiveDevice matches only the currently active id" {
    try std.testing.expect(!isActiveDevice(null, 1));
    try std.testing.expect(isActiveDevice(@as(c.SDL_JoystickID, 1), 1));
    try std.testing.expect(!isActiveDevice(@as(c.SDL_JoystickID, 1), 2));
}

test "pickFallback selects the first available device or null" {
    try std.testing.expectEqual(@as(?c.SDL_JoystickID, null), pickFallback(&.{}));
    const single = [_]c.SDL_JoystickID{5};
    try std.testing.expectEqual(@as(?c.SDL_JoystickID, 5), pickFallback(&single));
    const multiple = [_]c.SDL_JoystickID{ 3, 9, 12 };
    try std.testing.expectEqual(@as(?c.SDL_JoystickID, 3), pickFallback(&multiple));
}
