// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Pure logical-resolution contracts for future resize, high-DPI, and letterbox policy.
//! Current rendering still uses the swapchain size directly.

const std = @import("std");

pub const ScaleMode = enum {
    stretch,
    fit,
    integer_fit,
};

pub const LogicalSize = struct {
    width: u32,
    height: u32,

    pub fn validate(self: LogicalSize) !void {
        if (self.width == 0 or self.height == 0) return error.InvalidLogicalSize;
    }
};

pub const WindowSize = struct {
    width: u32,
    height: u32,

    pub fn validate(self: WindowSize) !void {
        if (self.width == 0 or self.height == 0) return error.InvalidWindowSize;
    }
};

pub const ResolutionPolicy = struct {
    logical_size: LogicalSize,
    scale_mode: ScaleMode = .fit,
};

pub const Viewport = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    scale_x: f32,
    scale_y: f32,
};

pub fn computeViewport(policy: ResolutionPolicy, window: WindowSize) !Viewport {
    try policy.logical_size.validate();
    try window.validate();

    return switch (policy.scale_mode) {
        .stretch => .{
            .x = 0,
            .y = 0,
            .width = window.width,
            .height = window.height,
            .scale_x = @as(f32, @floatFromInt(window.width)) / @as(f32, @floatFromInt(policy.logical_size.width)),
            .scale_y = @as(f32, @floatFromInt(window.height)) / @as(f32, @floatFromInt(policy.logical_size.height)),
        },
        .fit, .integer_fit => centeredViewport(policy, window),
    };
}

fn centeredViewport(policy: ResolutionPolicy, window: WindowSize) Viewport {
    const width_scale = @as(f32, @floatFromInt(window.width)) / @as(f32, @floatFromInt(policy.logical_size.width));
    const height_scale = @as(f32, @floatFromInt(window.height)) / @as(f32, @floatFromInt(policy.logical_size.height));
    var scale = @min(width_scale, height_scale);
    if (policy.scale_mode == .integer_fit) {
        scale = @max(1.0, @floor(scale));
    }

    const viewport_width: u32 = @intFromFloat(@floor(@as(f32, @floatFromInt(policy.logical_size.width)) * scale));
    const viewport_height: u32 = @intFromFloat(@floor(@as(f32, @floatFromInt(policy.logical_size.height)) * scale));

    return .{
        .x = centeredOffset(window.width, viewport_width),
        .y = centeredOffset(window.height, viewport_height),
        .width = viewport_width,
        .height = viewport_height,
        .scale_x = scale,
        .scale_y = scale,
    };
}

fn centeredOffset(outer: u32, inner: u32) i32 {
    return @intCast((outer - inner) / 2);
}

test "fit resolution policy computes centered letterbox viewport" {
    const viewport = try computeViewport(.{
        .logical_size = .{ .width = 1280, .height = 720 },
        .scale_mode = .fit,
    }, .{ .width = 1024, .height = 768 });

    try std.testing.expectEqual(@as(i32, 0), viewport.x);
    try std.testing.expectEqual(@as(i32, 96), viewport.y);
    try std.testing.expectEqual(@as(u32, 1024), viewport.width);
    try std.testing.expectEqual(@as(u32, 576), viewport.height);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), viewport.scale_x, 0.001);
}

test "integer fit resolution policy keeps whole-number scale" {
    const viewport = try computeViewport(.{
        .logical_size = .{ .width = 320, .height = 180 },
        .scale_mode = .integer_fit,
    }, .{ .width = 1000, .height = 700 });

    try std.testing.expectEqual(@as(u32, 960), viewport.width);
    try std.testing.expectEqual(@as(u32, 540), viewport.height);
    try std.testing.expectEqual(@as(i32, 20), viewport.x);
    try std.testing.expectEqual(@as(i32, 80), viewport.y);
    try std.testing.expectEqual(@as(f32, 3), viewport.scale_x);
}

test "stretch resolution policy fills the window" {
    const viewport = try computeViewport(.{
        .logical_size = .{ .width = 1280, .height = 720 },
        .scale_mode = .stretch,
    }, .{ .width = 800, .height = 800 });

    try std.testing.expectEqual(@as(u32, 800), viewport.width);
    try std.testing.expectEqual(@as(u32, 800), viewport.height);
    try std.testing.expectApproxEqAbs(@as(f32, 0.625), viewport.scale_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.111), viewport.scale_y, 0.001);
}
