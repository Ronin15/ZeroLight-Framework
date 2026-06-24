// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub fn clamp(value: f32, min: f32, max: f32) f32 {
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

/// Floors `value` to an `i32`, saturating non-finite and out-of-range inputs.
/// Guards `@intFromFloat`, which is illegal behavior on NaN/inf/out-of-range
/// floats — grid-cell helpers feed it integrated positions that can diverge.
pub fn floorToI32(value: f32) i32 {
    if (std.math.isNan(value)) return 0;
    const floored = @floor(value);
    if (floored <= @as(f32, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    if (floored >= @as(f32, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    return @intFromFloat(floored);
}

pub fn lerpVec2(start: Vec2, end: Vec2, amount: f32) Vec2 {
    return .{
        .x = start.x + (end.x - start.x) * amount,
        .y = start.y + (end.y - start.y) * amount,
    };
}

test "clamp keeps values inside bounds" {
    try std.testing.expectEqual(@as(f32, 0), clamp(-4, 0, 10));
    try std.testing.expectEqual(@as(f32, 5), clamp(5, 0, 10));
    try std.testing.expectEqual(@as(f32, 10), clamp(20, 0, 10));
}

test "floorToI32 floors finite values and saturates non-finite ones" {
    try std.testing.expectEqual(@as(i32, 3), floorToI32(3.7));
    try std.testing.expectEqual(@as(i32, -4), floorToI32(-3.2));
    try std.testing.expectEqual(@as(i32, 0), floorToI32(std.math.nan(f32)));
    try std.testing.expectEqual(std.math.maxInt(i32), floorToI32(std.math.inf(f32)));
    try std.testing.expectEqual(std.math.minInt(i32), floorToI32(-std.math.inf(f32)));
    try std.testing.expectEqual(std.math.maxInt(i32), floorToI32(1.0e30));
}

test "lerpVec2 interpolates between points" {
    const result = lerpVec2(.{ .x = 2, .y = 4 }, .{ .x = 10, .y = 20 }, 0.25);

    try std.testing.expectApproxEqAbs(@as(f32, 4), result.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 8), result.y, 0.001);
}
