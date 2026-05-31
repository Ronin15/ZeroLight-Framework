// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const c = @import("sdl.zig").c;

pub const InputState = struct {
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,

    pub fn handleEvent(self: *InputState, event: *const c.SDL_Event) void {
        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                self.handleKey(event.key.key, event.type == c.SDL_EVENT_KEY_DOWN);
            },
            else => {},
        }
    }

    fn handleKey(self: *InputState, key: c.SDL_Keycode, pressed: bool) void {
        switch (key) {
            c.SDLK_A => self.left = pressed,
            c.SDLK_D => self.right = pressed,
            c.SDLK_W => self.up = pressed,
            c.SDLK_S => self.down = pressed,
            else => {},
        }
    }
};

test "input key mapping tracks key down and key up" {
    const std = @import("std");
    var input = InputState{};

    input.handleKey(c.SDLK_A, true);
    input.handleKey(c.SDLK_W, true);
    try std.testing.expect(input.left);
    try std.testing.expect(input.up);
    try std.testing.expect(!input.right);
    try std.testing.expect(!input.down);

    input.handleKey(c.SDLK_A, false);
    try std.testing.expect(!input.left);
    try std.testing.expect(input.up);
}

test "input ignores unmapped keys" {
    const std = @import("std");
    var input = InputState{ .right = true };

    input.handleKey(c.SDLK_SPACE, true);
    try std.testing.expect(input.right);
    try std.testing.expect(!input.left);
}
