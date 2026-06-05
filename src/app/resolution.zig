// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Pure logical-resolution policy for SDL_GPU presentation.
//! SDL_Renderer logical presentation is intentionally not used by this project.

const std = @import("std");

pub const ScaleMode = enum {
    stretch,
    fit,
    integer_fit,
    overscan,
};

pub const LogicalSize = struct {
    width: u32 = 1280,
    height: u32 = 720,

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

pub const DrawableSize = struct {
    width: u32,
    height: u32,

    pub fn validate(self: DrawableSize) !void {
        if (self.width == 0 or self.height == 0) return error.InvalidDrawableSize;
    }
};

pub const ResolutionPolicy = struct {
    logical_size: LogicalSize = .{},
    scale_mode: ScaleMode = .fit,

    pub fn validate(self: ResolutionPolicy) !void {
        try self.logical_size.validate();
    }
};

pub const Viewport = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    scale_x: f32,
    scale_y: f32,
};

pub const Presentation = struct {
    policy: ResolutionPolicy,
    window_size: WindowSize,
    drawable_size: DrawableSize,
    viewport: Viewport,
};

pub const Point = struct {
    x: f32,
    y: f32,
};

pub fn computePresentation(
    policy: ResolutionPolicy,
    window_size: WindowSize,
    drawable_size: DrawableSize,
) !Presentation {
    try window_size.validate();
    return .{
        .policy = policy,
        .window_size = window_size,
        .drawable_size = drawable_size,
        .viewport = try computeViewport(policy, drawable_size),
    };
}

pub fn computeViewport(policy: ResolutionPolicy, drawable_size: DrawableSize) !Viewport {
    try policy.validate();
    try drawable_size.validate();

    return switch (policy.scale_mode) {
        .stretch => stretchViewport(policy.logical_size, drawable_size),
        .fit => scaledViewport(policy.logical_size, drawable_size, fitScale(policy.logical_size, drawable_size), true),
        .integer_fit => scaledViewport(policy.logical_size, drawable_size, integerFitScale(policy.logical_size, drawable_size), false),
        .overscan => scaledViewport(policy.logical_size, drawable_size, overscanScale(policy.logical_size, drawable_size), false),
    };
}

pub fn windowToDrawable(point: Point, window_size: WindowSize, drawable_size: DrawableSize) !Point {
    try window_size.validate();
    try drawable_size.validate();

    return .{
        .x = point.x * (@as(f32, @floatFromInt(drawable_size.width)) / @as(f32, @floatFromInt(window_size.width))),
        .y = point.y * (@as(f32, @floatFromInt(drawable_size.height)) / @as(f32, @floatFromInt(window_size.height))),
    };
}

pub fn drawableToLogical(point: Point, policy: ResolutionPolicy, drawable_size: DrawableSize) !?Point {
    const viewport = try computeViewport(policy, drawable_size);
    if (!pointInViewport(point, viewport)) return null;

    return .{
        .x = (point.x - @as(f32, @floatFromInt(viewport.x))) / viewport.scale_x,
        .y = (point.y - @as(f32, @floatFromInt(viewport.y))) / viewport.scale_y,
    };
}

pub fn windowToLogical(
    point: Point,
    policy: ResolutionPolicy,
    window_size: WindowSize,
    drawable_size: DrawableSize,
) !?Point {
    const drawable_point = try windowToDrawable(point, window_size, drawable_size);
    return try drawableToLogical(drawable_point, policy, drawable_size);
}

fn stretchViewport(logical_size: LogicalSize, drawable_size: DrawableSize) Viewport {
    return .{
        .x = 0,
        .y = 0,
        .width = drawable_size.width,
        .height = drawable_size.height,
        .scale_x = scaleFor(drawable_size.width, logical_size.width),
        .scale_y = scaleFor(drawable_size.height, logical_size.height),
    };
}

fn scaledViewport(
    logical_size: LogicalSize,
    drawable_size: DrawableSize,
    scale: f32,
    clamp_to_drawable: bool,
) Viewport {
    var width = scaledExtent(logical_size.width, scale);
    var height = scaledExtent(logical_size.height, scale);
    if (clamp_to_drawable) {
        width = @min(width, drawable_size.width);
        height = @min(height, drawable_size.height);
    }

    return .{
        .x = centeredOffset(drawable_size.width, width),
        .y = centeredOffset(drawable_size.height, height),
        .width = width,
        .height = height,
        .scale_x = scaleFor(width, logical_size.width),
        .scale_y = scaleFor(height, logical_size.height),
    };
}

fn fitScale(logical_size: LogicalSize, drawable_size: DrawableSize) f32 {
    return @min(
        scaleFor(drawable_size.width, logical_size.width),
        scaleFor(drawable_size.height, logical_size.height),
    );
}

fn overscanScale(logical_size: LogicalSize, drawable_size: DrawableSize) f32 {
    return @max(
        scaleFor(drawable_size.width, logical_size.width),
        scaleFor(drawable_size.height, logical_size.height),
    );
}

fn integerFitScale(logical_size: LogicalSize, drawable_size: DrawableSize) f32 {
    return @max(1.0, @floor(fitScale(logical_size, drawable_size)));
}

fn scaleFor(output_extent: u32, logical_extent: u32) f32 {
    return @as(f32, @floatFromInt(output_extent)) / @as(f32, @floatFromInt(logical_extent));
}

fn scaledExtent(logical_extent: u32, scale: f32) u32 {
    return @max(1, @as(u32, @intFromFloat(@floor(@as(f32, @floatFromInt(logical_extent)) * scale))));
}

fn centeredOffset(outer: u32, inner: u32) i32 {
    const difference = @as(i64, @intCast(outer)) - @as(i64, @intCast(inner));
    return @intCast(@divFloor(difference, 2));
}

fn pointInViewport(point: Point, viewport: Viewport) bool {
    const x = @as(f32, @floatFromInt(viewport.x));
    const y = @as(f32, @floatFromInt(viewport.y));
    return point.x >= x and point.y >= y and
        point.x < x + @as(f32, @floatFromInt(viewport.width)) and
        point.y < y + @as(f32, @floatFromInt(viewport.height));
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
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), viewport.scale_y, 0.001);
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
    try std.testing.expectEqual(@as(f32, 3), viewport.scale_y);
}

test "stretch resolution policy fills the drawable" {
    const viewport = try computeViewport(.{
        .logical_size = .{ .width = 1280, .height = 720 },
        .scale_mode = .stretch,
    }, .{ .width = 800, .height = 800 });

    try std.testing.expectEqual(@as(i32, 0), viewport.x);
    try std.testing.expectEqual(@as(i32, 0), viewport.y);
    try std.testing.expectEqual(@as(u32, 800), viewport.width);
    try std.testing.expectEqual(@as(u32, 800), viewport.height);
    try std.testing.expectApproxEqAbs(@as(f32, 0.625), viewport.scale_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.111), viewport.scale_y, 0.001);
}

test "overscan resolution policy crops with negative centered offsets" {
    const viewport = try computeViewport(.{
        .logical_size = .{ .width = 1280, .height = 720 },
        .scale_mode = .overscan,
    }, .{ .width = 1024, .height = 768 });

    try std.testing.expectEqual(@as(i32, -171), viewport.x);
    try std.testing.expectEqual(@as(i32, 0), viewport.y);
    try std.testing.expectEqual(@as(u32, 1365), viewport.width);
    try std.testing.expectEqual(@as(u32, 768), viewport.height);
    try std.testing.expectApproxEqAbs(viewport.scale_x, viewport.scale_y, 0.001);
}

test "tiny drawable sizes still produce a nonzero viewport" {
    const viewport = try computeViewport(.{
        .logical_size = .{ .width = 1280, .height = 720 },
        .scale_mode = .fit,
    }, .{ .width = 1, .height = 1 });

    try std.testing.expectEqual(@as(i32, 0), viewport.x);
    try std.testing.expectEqual(@as(i32, 0), viewport.y);
    try std.testing.expectEqual(@as(u32, 1), viewport.width);
    try std.testing.expectEqual(@as(u32, 1), viewport.height);
    try std.testing.expect(viewport.scale_x > 0);
    try std.testing.expect(viewport.scale_y > 0);
}

test "invalid logical window and drawable sizes are rejected" {
    try std.testing.expectError(error.InvalidLogicalSize, computeViewport(.{
        .logical_size = .{ .width = 0, .height = 720 },
    }, .{ .width = 1280, .height = 720 }));
    try std.testing.expectError(error.InvalidDrawableSize, computeViewport(.{}, .{ .width = 0, .height = 720 }));
    try std.testing.expectError(error.InvalidWindowSize, computePresentation(.{}, .{ .width = 0, .height = 720 }, .{ .width = 1, .height = 1 }));
}

test "retina style window maps through drawable pixels into logical coordinates" {
    const policy = ResolutionPolicy{
        .logical_size = .{ .width = 1280, .height = 720 },
        .scale_mode = .fit,
    };
    const window_size = WindowSize{ .width = 1280, .height = 720 };
    const drawable_size = DrawableSize{ .width = 2560, .height = 1440 };

    const viewport = try computeViewport(policy, drawable_size);
    try std.testing.expectEqual(@as(i32, 0), viewport.x);
    try std.testing.expectEqual(@as(i32, 0), viewport.y);
    try std.testing.expectEqual(@as(u32, 2560), viewport.width);
    try std.testing.expectEqual(@as(u32, 1440), viewport.height);
    try std.testing.expectEqual(@as(f32, 2), viewport.scale_x);

    const drawable_point = try windowToDrawable(.{ .x = 640, .y = 360 }, window_size, drawable_size);
    try std.testing.expectEqual(@as(f32, 1280), drawable_point.x);
    try std.testing.expectEqual(@as(f32, 720), drawable_point.y);

    const logical_point = (try windowToLogical(.{ .x = 640, .y = 360 }, policy, window_size, drawable_size)).?;
    try std.testing.expectApproxEqAbs(@as(f32, 640), logical_point.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 360), logical_point.y, 0.001);
}

test "letterbox hits outside the logical viewport are rejected" {
    const policy = ResolutionPolicy{
        .logical_size = .{ .width = 1280, .height = 720 },
        .scale_mode = .fit,
    };
    const size = DrawableSize{ .width = 1024, .height = 768 };

    try std.testing.expectEqual(@as(?Point, null), try drawableToLogical(.{ .x = 512, .y = 50 }, policy, size));

    const logical_point = (try drawableToLogical(.{ .x = 512, .y = 384 }, policy, size)).?;
    try std.testing.expectApproxEqAbs(@as(f32, 640), logical_point.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 360), logical_point.y, 0.001);
}
