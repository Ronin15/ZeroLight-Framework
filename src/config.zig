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
    audio: AudioConfig = .{},

    pub fn validate(self: AppConfig) !void {
        try validateAssetRoot(self.asset_root);
        try self.resolution_policy.validate();
        try self.audio.validate();
        if (self.frames_in_flight < 1 or self.frames_in_flight > 3) {
            return error.InvalidConfig;
        }
    }
};

pub const AudioConfig = struct {
    enabled: bool = true,
    max_sfx_tracks: u32 = 16,
    max_commands_per_step: u32 = 32,
    master_gain: f32 = 1.0,
    sfx_gain: f32 = 0.85,
    music_gain: f32 = 0.55,
    paused_music_gain: f32 = 0.22,
    spatial_units_per_meter: f32 = 96.0,

    pub fn validate(self: AudioConfig) !void {
        if (self.max_sfx_tracks == 0 or self.max_commands_per_step == 0) {
            return error.InvalidAudioConfig;
        }
        if (!gainIsValid(self.master_gain) or
            !gainIsValid(self.sfx_gain) or
            !gainIsValid(self.music_gain) or
            !gainIsValid(self.paused_music_gain))
        {
            return error.InvalidAudioConfig;
        }
        if (!std.math.isFinite(self.spatial_units_per_meter) or self.spatial_units_per_meter <= 0) {
            return error.InvalidAudioConfig;
        }
    }

    fn gainIsValid(value: f32) bool {
        return std.math.isFinite(value) and value >= 0 and value <= 1;
    }
};

pub const Color = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

fn validateAssetRoot(asset_root: []const u8) !void {
    if (asset_root.len == 0 or std.fs.path.isAbsolute(asset_root)) {
        return error.InvalidConfig;
    }

    var components = std.fs.path.componentIterator(asset_root);
    while (components.next()) |component| {
        if (std.mem.eql(u8, component.name, ".") or std.mem.eql(u8, component.name, "..")) {
            return error.InvalidConfig;
        }
    }
}

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

test "app config validation keeps asset roots relative and traversal-safe" {
    try (AppConfig{ .app_name = "test", .window_title = "test", .asset_root = "content" }).validate();
    try (AppConfig{ .app_name = "test", .window_title = "test", .asset_root = "content/runtime" }).validate();
    try std.testing.expectError(error.InvalidConfig, (AppConfig{ .app_name = "test", .window_title = "test", .asset_root = "" }).validate());
    try std.testing.expectError(error.InvalidConfig, (AppConfig{ .app_name = "test", .window_title = "test", .asset_root = "/tmp/assets" }).validate());
    try std.testing.expectError(error.InvalidConfig, (AppConfig{ .app_name = "test", .window_title = "test", .asset_root = "../content" }).validate());
    try std.testing.expectError(error.InvalidConfig, (AppConfig{ .app_name = "test", .window_title = "test", .asset_root = "./assets" }).validate());
}

test "audio config validation rejects invalid values" {
    try std.testing.expectError(error.InvalidAudioConfig, (AudioConfig{ .max_sfx_tracks = 0 }).validate());
    try std.testing.expectError(error.InvalidAudioConfig, (AudioConfig{ .max_commands_per_step = 0 }).validate());
    try std.testing.expectError(error.InvalidAudioConfig, (AudioConfig{ .master_gain = -0.1 }).validate());
    try std.testing.expectError(error.InvalidAudioConfig, (AudioConfig{ .sfx_gain = 1.1 }).validate());
    try std.testing.expectError(error.InvalidAudioConfig, (AudioConfig{ .spatial_units_per_meter = 0 }).validate());
}
