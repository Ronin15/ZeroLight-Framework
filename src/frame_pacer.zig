// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const TimeLoop = @import("time_loop.zig").TimeLoop;
const c = @import("sdl.zig").c;

pub const fallback_frame_ns = TimeLoop.fixed_delta_ns;

pub fn windowCanRender(window: *c.SDL_Window) bool {
    return flagsCanRender(c.SDL_GetWindowFlags(window));
}

pub fn flagsCanRender(flags: c.SDL_WindowFlags) bool {
    const blocked_flags = c.SDL_WINDOW_HIDDEN |
        c.SDL_WINDOW_MINIMIZED |
        c.SDL_WINDOW_OCCLUDED;
    return (flags & blocked_flags) == 0;
}

pub fn fallbackDelayNs(frame_start_ns: u64, now_ns: u64) u64 {
    const elapsed_ns = if (now_ns > frame_start_ns) now_ns - frame_start_ns else 0;
    if (elapsed_ns >= fallback_frame_ns) return 0;
    return fallback_frame_ns - elapsed_ns;
}

pub fn paceFallbackFrame(frame_start_ns: u64) void {
    const delay_ns = fallbackDelayNs(frame_start_ns, c.SDL_GetTicksNS());
    if (delay_ns > 0) {
        c.SDL_DelayNS(delay_ns);
    }
}

test "fallback delay returns full frame when no time elapsed" {
    const std = @import("std");
    try std.testing.expectEqual(fallback_frame_ns, fallbackDelayNs(100, 100));
}

test "fallback delay returns remaining frame time" {
    const std = @import("std");
    const elapsed_ns = fallback_frame_ns / 4;
    try std.testing.expectEqual(fallback_frame_ns - elapsed_ns, fallbackDelayNs(100, 100 + elapsed_ns));
}

test "fallback delay returns zero when frame is over budget" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u64, 0), fallbackDelayNs(100, 100 + fallback_frame_ns));
    try std.testing.expectEqual(@as(u64, 0), fallbackDelayNs(100, 100 + fallback_frame_ns + 1));
}

test "window flags classify non-renderable window states" {
    const std = @import("std");

    try std.testing.expect(flagsCanRender(0));
    try std.testing.expect(!flagsCanRender(c.SDL_WINDOW_HIDDEN));
    try std.testing.expect(!flagsCanRender(c.SDL_WINDOW_MINIMIZED));
    try std.testing.expect(!flagsCanRender(c.SDL_WINDOW_OCCLUDED));
    try std.testing.expect(!flagsCanRender(c.SDL_WINDOW_HIDDEN | c.SDL_WINDOW_INPUT_FOCUS));
}
