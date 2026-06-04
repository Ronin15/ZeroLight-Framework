// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const log = @import("../core/logging.zig").platform;

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
});

pub const SdlContext = struct {
    pub fn init(flags: c.SDL_InitFlags) !SdlContext {
        if (!c.SDL_Init(flags)) {
            return sdlError("SDL_Init");
        }
        var flag_names_buffer: [160]u8 = undefined;
        const flag_names = initFlagNames(&flag_names_buffer, flags);
        log.debug("SDL initialized with subsystems={s}", .{flag_names});
        return .{};
    }

    pub fn deinit(self: *SdlContext) void {
        _ = self;
        c.SDL_Quit();
    }
};

pub const Window = struct {
    handle: *c.SDL_Window,

    pub fn create(title: [:0]const u8, width: u32, height: u32, flags: c.SDL_WindowFlags) !Window {
        const handle = c.SDL_CreateWindow(title.ptr, @intCast(width), @intCast(height), flags) orelse {
            return sdlError("SDL_CreateWindow");
        };
        var flag_names_buffer: [256]u8 = undefined;
        const flag_names = windowFlagNames(&flag_names_buffer, flags);
        log.debug("SDL window created: title=\"{s}\" size={}x{} flags={s}", .{ title, width, height, flag_names });
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Window) void {
        c.SDL_DestroyWindow(self.handle);
    }
};

pub fn sdlError(comptime operation: []const u8) error{SdlError} {
    log.err("{s} failed: {s}", .{ operation, c.SDL_GetError() });
    return error.SdlError;
}

const InitFlagName = struct {
    flag: c.SDL_InitFlags,
    name: []const u8,
};

const init_flag_names = [_]InitFlagName{
    .{ .flag = c.SDL_INIT_AUDIO, .name = "audio" },
    .{ .flag = c.SDL_INIT_VIDEO, .name = "video" },
    .{ .flag = c.SDL_INIT_JOYSTICK, .name = "joystick" },
    .{ .flag = c.SDL_INIT_HAPTIC, .name = "haptic" },
    .{ .flag = c.SDL_INIT_GAMEPAD, .name = "gamepad" },
    .{ .flag = c.SDL_INIT_EVENTS, .name = "events" },
    .{ .flag = c.SDL_INIT_SENSOR, .name = "sensor" },
    .{ .flag = c.SDL_INIT_CAMERA, .name = "camera" },
};

fn initFlagNames(buffer: []u8, flags: c.SDL_InitFlags) []const u8 {
    if (flags == 0) {
        return "none";
    }

    var remaining = flags;
    var used: usize = 0;
    for (init_flag_names) |entry| {
        if ((flags & entry.flag) != 0) {
            appendFlagName(buffer, &used, entry.name);
            remaining &= ~entry.flag;
        }
    }

    if (remaining != 0) {
        appendFlagName(buffer, &used, "unknown");
    }

    return buffer[0..used];
}

const WindowFlagName = struct {
    flag: c.SDL_WindowFlags,
    name: []const u8,
};

const window_flag_names = [_]WindowFlagName{
    .{ .flag = c.SDL_WINDOW_FULLSCREEN, .name = "fullscreen" },
    .{ .flag = c.SDL_WINDOW_OPENGL, .name = "opengl" },
    .{ .flag = c.SDL_WINDOW_OCCLUDED, .name = "occluded" },
    .{ .flag = c.SDL_WINDOW_HIDDEN, .name = "hidden" },
    .{ .flag = c.SDL_WINDOW_BORDERLESS, .name = "borderless" },
    .{ .flag = c.SDL_WINDOW_RESIZABLE, .name = "resizable" },
    .{ .flag = c.SDL_WINDOW_MINIMIZED, .name = "minimized" },
    .{ .flag = c.SDL_WINDOW_MAXIMIZED, .name = "maximized" },
    .{ .flag = c.SDL_WINDOW_MOUSE_GRABBED, .name = "mouse-grabbed" },
    .{ .flag = c.SDL_WINDOW_INPUT_FOCUS, .name = "input-focus" },
    .{ .flag = c.SDL_WINDOW_MOUSE_FOCUS, .name = "mouse-focus" },
    .{ .flag = c.SDL_WINDOW_EXTERNAL, .name = "external" },
    .{ .flag = c.SDL_WINDOW_MODAL, .name = "modal" },
    .{ .flag = c.SDL_WINDOW_HIGH_PIXEL_DENSITY, .name = "high-pixel-density" },
    .{ .flag = c.SDL_WINDOW_MOUSE_CAPTURE, .name = "mouse-capture" },
    .{ .flag = c.SDL_WINDOW_MOUSE_RELATIVE_MODE, .name = "mouse-relative-mode" },
    .{ .flag = c.SDL_WINDOW_ALWAYS_ON_TOP, .name = "always-on-top" },
    .{ .flag = c.SDL_WINDOW_UTILITY, .name = "utility" },
    .{ .flag = c.SDL_WINDOW_TOOLTIP, .name = "tooltip" },
    .{ .flag = c.SDL_WINDOW_POPUP_MENU, .name = "popup-menu" },
    .{ .flag = c.SDL_WINDOW_KEYBOARD_GRABBED, .name = "keyboard-grabbed" },
    .{ .flag = c.SDL_WINDOW_VULKAN, .name = "vulkan" },
    .{ .flag = c.SDL_WINDOW_METAL, .name = "metal" },
    .{ .flag = c.SDL_WINDOW_TRANSPARENT, .name = "transparent" },
    .{ .flag = c.SDL_WINDOW_NOT_FOCUSABLE, .name = "not-focusable" },
};

fn windowFlagNames(buffer: []u8, flags: c.SDL_WindowFlags) []const u8 {
    if (flags == 0) {
        return "none";
    }

    var remaining = flags;
    var used: usize = 0;
    for (window_flag_names) |entry| {
        if ((flags & entry.flag) != 0) {
            appendFlagName(buffer, &used, entry.name);
            remaining &= ~entry.flag;
        }
    }

    if (remaining != 0) {
        appendFlagName(buffer, &used, "unknown");
    }

    return buffer[0..used];
}

fn appendFlagName(buffer: []u8, used: *usize, name: []const u8) void {
    if (used.* != 0) {
        appendBytes(buffer, used, ", ");
    }
    appendBytes(buffer, used, name);
}

fn appendBytes(buffer: []u8, used: *usize, bytes: []const u8) void {
    const available = buffer.len - used.*;
    const copied = @min(available, bytes.len);
    @memcpy(buffer[used.*..][0..copied], bytes[0..copied]);
    used.* += copied;
}

test "SDL init flags format as subsystem names" {
    var buffer: [160]u8 = undefined;

    try std.testing.expectEqualStrings("video", initFlagNames(&buffer, c.SDL_INIT_VIDEO));
    try std.testing.expectEqualStrings(
        "audio, video, events",
        initFlagNames(&buffer, c.SDL_INIT_AUDIO | c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS),
    );
    try std.testing.expectEqualStrings("none", initFlagNames(&buffer, 0));
}

test "SDL window flags format as names" {
    var buffer: [256]u8 = undefined;

    try std.testing.expectEqualStrings("none", windowFlagNames(&buffer, 0));
    try std.testing.expectEqualStrings("resizable", windowFlagNames(&buffer, c.SDL_WINDOW_RESIZABLE));
    try std.testing.expectEqualStrings(
        "hidden, resizable, high-pixel-density",
        windowFlagNames(
            &buffer,
            c.SDL_WINDOW_HIDDEN | c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
        ),
    );
}
