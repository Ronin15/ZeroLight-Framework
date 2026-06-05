// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const ThreadSystemConfig = @import("app/thread_system.zig").ThreadSystemConfig;
const resolution = @import("app/resolution.zig");
const std = @import("std");

pub const PresentMode = enum {
    vsync,
    immediate,
    mailbox,
};

pub const AppConfig = struct {
    app_name: []const u8,
    window_title: []const u8,
    asset_root: []const u8 = "assets",
    resolution_policy: resolution.ResolutionPolicy = .{},
    high_pixel_density: bool = true,
    resizable: bool = true,
    gpu_debug: bool = false,
    frames_in_flight: u32 = 3,
    present_mode: PresentMode = .vsync,
    clear_color: Color = .{ .r = 0.071, .g = 0.125, .b = 0.173, .a = 1.0 },
    threading: ThreadSystemConfig = .{},

    pub fn validate(self: AppConfig) !void {
        try self.resolution_policy.validate();
        if (self.frames_in_flight < 1 or self.frames_in_flight > 3) {
            return error.InvalidConfig;
        }
    }
};

pub const Color = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

test "app config validation accepts defaults" {
    try (AppConfig{
        .app_name = "test",
        .window_title = "test",
    }).validate();
}

test "app config validation rejects invalid logical size" {
    try std.testing.expectError(error.InvalidLogicalSize, (AppConfig{
        .app_name = "test",
        .window_title = "test",
        .resolution_policy = .{
            .logical_size = .{ .width = 0, .height = 720 },
        },
    }).validate());
}

test "app config validation rejects invalid frame latency" {
    try std.testing.expectError(error.InvalidConfig, (AppConfig{
        .app_name = "test",
        .window_title = "test",
        .frames_in_flight = 0,
    }).validate());
    try std.testing.expectError(error.InvalidConfig, (AppConfig{
        .app_name = "test",
        .window_title = "test",
        .frames_in_flight = 4,
    }).validate());
}
