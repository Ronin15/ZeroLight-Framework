// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

pub const PresentMode = enum {
    vsync,
    immediate,
    mailbox,
};

pub const AppConfig = struct {
    app_name: []const u8,
    window_title: []const u8,
    asset_root: []const u8 = "assets",
    logical_width: u32 = 1280,
    logical_height: u32 = 720,
    resizable: bool = false,
    gpu_debug: bool = false,
    frames_in_flight: u32 = 1,
    present_mode: PresentMode = .vsync,
    clear_color: Color = .{ .r = 0.071, .g = 0.125, .b = 0.173, .a = 1.0 },
};

pub const Color = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};
