// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const TimeLoop = @import("time_loop.zig").TimeLoop;
const c = @import("../platform/sdl.zig").c;

pub const fallback_frame_ns = TimeLoop.fixed_delta_ns;

pub const FramePolicy = struct {
    can_render: bool,
    target_frame_ns: ?u64,
    should_pause_gameplay: bool,
};

pub fn windowFramePolicy(window: *c.SDL_Window) FramePolicy {
    return flagsFramePolicy(c.SDL_GetWindowFlags(window));
}

pub fn flagsCanRender(flags: c.SDL_WindowFlags) bool {
    const blocked_flags = c.SDL_WINDOW_HIDDEN |
        c.SDL_WINDOW_MINIMIZED;
    return (flags & blocked_flags) == 0;
}

pub fn flagsFramePolicy(flags: c.SDL_WindowFlags) FramePolicy {
    const needs_background_cap = !flagsCanRender(flags) or
        (flags & c.SDL_WINDOW_OCCLUDED) != 0 or
        (flags & c.SDL_WINDOW_INPUT_FOCUS) == 0;
    const should_pause_gameplay = !flagsCanRender(flags);

    return .{
        .can_render = flagsCanRender(flags),
        .target_frame_ns = if (needs_background_cap) fallback_frame_ns else null,
        .should_pause_gameplay = should_pause_gameplay,
    };
}

pub fn targetDelayNs(frame_start_ns: u64, now_ns: u64, target_frame_ns: u64) u64 {
    const elapsed_ns = if (now_ns > frame_start_ns) now_ns - frame_start_ns else 0;
    if (elapsed_ns >= target_frame_ns) return 0;
    return target_frame_ns - elapsed_ns;
}

pub fn fallbackDelayNs(frame_start_ns: u64, now_ns: u64) u64 {
    return targetDelayNs(frame_start_ns, now_ns, fallback_frame_ns);
}

pub fn paceTargetFrame(frame_start_ns: u64, target_frame_ns: u64) void {
    const delay_ns = targetDelayNs(frame_start_ns, c.SDL_GetTicksNS(), target_frame_ns);
    if (delay_ns > 0) {
        c.SDL_DelayNS(delay_ns);
    }
}

pub fn paceFallbackFrame(frame_start_ns: u64) void {
    paceTargetFrame(frame_start_ns, fallback_frame_ns);
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

test "window flags classify renderability separately from background throttling" {
    const std = @import("std");

    try std.testing.expect(flagsCanRender(c.SDL_WINDOW_INPUT_FOCUS));
    try std.testing.expect(flagsCanRender(c.SDL_WINDOW_INPUT_FOCUS | c.SDL_WINDOW_OCCLUDED));
    try std.testing.expect(flagsCanRender(0));
    try std.testing.expect(!flagsCanRender(c.SDL_WINDOW_HIDDEN));
    try std.testing.expect(!flagsCanRender(c.SDL_WINDOW_MINIMIZED));
    try std.testing.expect(!flagsCanRender(c.SDL_WINDOW_HIDDEN | c.SDL_WINDOW_INPUT_FOCUS));
}

test "focused visible windows render without a frame cap" {
    const std = @import("std");

    const policy = flagsFramePolicy(c.SDL_WINDOW_INPUT_FOCUS);

    try std.testing.expect(policy.can_render);
    try std.testing.expectEqual(@as(?u64, null), policy.target_frame_ns);
    try std.testing.expect(!policy.should_pause_gameplay);
}

test "occluded windows render with the fallback frame cap" {
    const std = @import("std");

    const policy = flagsFramePolicy(c.SDL_WINDOW_INPUT_FOCUS | c.SDL_WINDOW_OCCLUDED);

    try std.testing.expect(policy.can_render);
    try std.testing.expectEqual(@as(?u64, fallback_frame_ns), policy.target_frame_ns);
    try std.testing.expect(!policy.should_pause_gameplay);
}

test "unfocused windows render with the fallback frame cap without forcing pause" {
    const std = @import("std");

    const policy = flagsFramePolicy(0);

    try std.testing.expect(policy.can_render);
    try std.testing.expectEqual(@as(?u64, fallback_frame_ns), policy.target_frame_ns);
    try std.testing.expect(!policy.should_pause_gameplay);
}

test "hidden and minimized windows skip rendering with the fallback frame cap" {
    const std = @import("std");

    const hidden_policy = flagsFramePolicy(c.SDL_WINDOW_HIDDEN | c.SDL_WINDOW_INPUT_FOCUS);
    const minimized_policy = flagsFramePolicy(c.SDL_WINDOW_MINIMIZED | c.SDL_WINDOW_INPUT_FOCUS);

    try std.testing.expect(!hidden_policy.can_render);
    try std.testing.expectEqual(@as(?u64, fallback_frame_ns), hidden_policy.target_frame_ns);
    try std.testing.expect(hidden_policy.should_pause_gameplay);
    try std.testing.expect(!minimized_policy.can_render);
    try std.testing.expectEqual(@as(?u64, fallback_frame_ns), minimized_policy.target_frame_ns);
    try std.testing.expect(minimized_policy.should_pause_gameplay);
}
