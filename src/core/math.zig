// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub fn clamp(value: f32, min: f32, max: f32) f32 {
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

pub fn lerpVec2(start: Vec2, end: Vec2, amount: f32) Vec2 {
    return .{
        .x = start.x + (end.x - start.x) * amount,
        .y = start.y + (end.y - start.y) * amount,
    };
}

test "clamp keeps values inside bounds" {
    const std = @import("std");
    try std.testing.expectEqual(@as(f32, 0), clamp(-4, 0, 10));
    try std.testing.expectEqual(@as(f32, 5), clamp(5, 0, 10));
    try std.testing.expectEqual(@as(f32, 10), clamp(20, 0, 10));
}

test "lerpVec2 interpolates between points" {
    const std = @import("std");
    const result = lerpVec2(.{ .x = 2, .y = 4 }, .{ .x = 10, .y = 20 }, 0.25);

    try std.testing.expectApproxEqAbs(@as(f32, 4), result.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 8), result.y, 0.001);
}
