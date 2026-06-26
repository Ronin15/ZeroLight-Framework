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

/// Linearly interpolates between `start` and `end` by `amount`. Scalar
/// counterpart of `simd.lerpFloat4`.
pub fn lerp(start: f32, end: f32, amount: f32) f32 {
    return start + (end - start) * amount;
}

pub fn lerpVec2(start: Vec2, end: Vec2, amount: f32) Vec2 {
    return .{
        .x = lerp(start.x, end.x, amount),
        .y = lerp(start.y, end.y, amount),
    };
}

pub fn lengthSquared(v: Vec2) f32 {
    return v.x * v.x + v.y * v.y;
}

pub fn length(v: Vec2) f32 {
    return @sqrt(lengthSquared(v));
}

/// Normalizes `v`, returning a zero vector when its squared length is at or
/// below `epsilon`. Scalar counterpart of `simd.normalizeOrZero2Float4`.
pub fn normalizeOrZero(v: Vec2, epsilon: f32) Vec2 {
    const len2 = lengthSquared(v);
    if (len2 <= epsilon) return .{};
    const inv = 1.0 / @sqrt(len2);
    return .{ .x = v.x * inv, .y = v.y * inv };
}

/// Two-scalar normalize-or-zero with full non-finite guards: returns a zero
/// vector when either input, the squared length, or the result is non-finite,
/// or when the squared length is at or below `epsilon`. Used by gameplay
/// processors whose inputs can overflow to non-finite intermediates.
pub fn normalizeOrZeroFinite(dx: f32, dy: f32, epsilon: f32) Vec2 {
    if (!std.math.isFinite(dx) or !std.math.isFinite(dy)) return .{};
    const len2 = dx * dx + dy * dy;
    if (!std.math.isFinite(len2) or len2 <= epsilon) return .{};
    const inv = 1.0 / @sqrt(len2);
    return .{ .x = dx * inv, .y = dy * inv };
}

/// Like `normalizeOrZeroFinite` but returns `default` on any degenerate or
/// non-finite case, including a post-normalize finite recheck of the result.
pub fn normalizeOrDefaultFinite(dx: f32, dy: f32, epsilon: f32, default: Vec2) Vec2 {
    if (!std.math.isFinite(dx) or !std.math.isFinite(dy)) return default;
    const len2 = dx * dx + dy * dy;
    if (!std.math.isFinite(len2) or len2 <= epsilon) return default;
    const inv = 1.0 / @sqrt(len2);
    const nx = dx * inv;
    const ny = dy * inv;
    if (!std.math.isFinite(nx) or !std.math.isFinite(ny)) return default;
    return .{ .x = nx, .y = ny };
}

/// Clamp using `@min(@max(...))`. Differs from `clamp` only in NaN handling: a
/// NaN `value` yields a bound rather than propagating NaN. Scalar counterpart
/// of `simd.clampFloat4`.
pub fn clampMinMax(value: f32, min: f32, max: f32) f32 {
    return @min(@max(value, min), max);
}

/// Sine/cosine pair for a single angle. Computing both once lets callers rotate
/// many points by the same angle without recomputing trig per point.
pub const SinCos = struct {
    sin: f32,
    cos: f32,
};

/// Evaluates `@sin`/`@cos` of `angle` (radians) together.
pub fn sinCos(angle: f32) SinCos {
    return .{ .sin = @sin(angle), .cos = @cos(angle) };
}

/// Rotates `v` counter-clockwise by a precomputed sin/cos pair:
/// `(x*cos - y*sin, x*sin + y*cos)`.
pub fn rotate2D(v: Vec2, angle: SinCos) Vec2 {
    return .{
        .x = v.x * angle.cos - v.y * angle.sin,
        .y = v.x * angle.sin + v.y * angle.cos,
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

test "lerp matches simd.lerpFloat4 per lane" {
    const simd = @import("simd.zig");
    const start = [_]f32{ 0, -2, 3.5, 100 };
    const end = [_]f32{ 10, 2, -1.5, 0 };
    const amounts = [_]f32{ 0, 0.25, 0.5, 1 };
    for (start, end, amounts) |s, e, a| {
        const vector = simd.lerpFloat4(simd.splatFloat4(s), simd.splatFloat4(e), simd.splatFloat4(a));
        try std.testing.expectApproxEqAbs(lerp(s, e, a), vector[0], 0.0001);
    }
}

test "length helpers measure 3-4-5 vector" {
    const v = Vec2{ .x = 3, .y = 4 };
    try std.testing.expectApproxEqAbs(@as(f32, 25), lengthSquared(v), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), length(v), 0.001);
}

test "normalizeOrZero normalizes and zeroes short vectors" {
    const normalized = normalizeOrZero(.{ .x = 3, .y = 4 }, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), normalized.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), normalized.y, 0.001);

    const zeroed = normalizeOrZero(.{ .x = 0, .y = 0 }, 1.0e-12);
    try std.testing.expectEqual(@as(f32, 0), zeroed.x);
    try std.testing.expectEqual(@as(f32, 0), zeroed.y);
}

test "normalizeOrZeroFinite matches SIMD normalize lane-for-lane on finite vectors" {
    const simd = @import("simd.zig");
    const epsilon: f32 = 1.0e-3;
    const cases = [_][2]f32{ .{ 3, 4 }, .{ -5, 12 }, .{ 0.001, 0 }, .{ 0, 0 } };
    for (cases) |case| {
        const scalar = normalizeOrZeroFinite(case[0], case[1], epsilon);
        const vector = simd.normalizeOrZero2Float4(simd.splatFloat4(case[0]), simd.splatFloat4(case[1]), epsilon);
        try std.testing.expectApproxEqAbs(scalar.x, vector.x[0], 1.0e-6);
        try std.testing.expectApproxEqAbs(scalar.y, vector.y[0], 1.0e-6);
    }
}

test "normalizeOrZeroFinite zeroes non-finite inputs" {
    const overflow = normalizeOrZeroFinite(std.math.floatMax(f32), std.math.floatMax(f32), 1.0e-4);
    try std.testing.expectEqual(@as(f32, 0), overflow.x);
    try std.testing.expectEqual(@as(f32, 0), overflow.y);

    const infinite = normalizeOrZeroFinite(std.math.inf(f32), 1, 1.0e-4);
    try std.testing.expectEqual(@as(f32, 0), infinite.x);
    try std.testing.expectEqual(@as(f32, 0), infinite.y);
}

test "normalizeOrDefaultFinite falls back on degenerate inputs" {
    const default = Vec2{ .x = 1, .y = 0 };
    const normalized = normalizeOrDefaultFinite(3, 4, 1.0e-4, default);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), normalized.x, 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), normalized.y, 1.0e-4);

    try std.testing.expectEqual(default, normalizeOrDefaultFinite(0, 0, 1.0e-4, default));
    try std.testing.expectEqual(default, normalizeOrDefaultFinite(std.math.inf(f32), 0, 1.0e-4, default));
    try std.testing.expectEqual(default, normalizeOrDefaultFinite(std.math.floatMax(f32), std.math.floatMax(f32), 1.0e-4, default));
}

test "rotate2D rotates points by a precomputed sin/cos pair" {
    const quarter = sinCos(std.math.pi / 2.0);
    const rotated = rotate2D(.{ .x = 1, .y = 0 }, quarter);
    try std.testing.expectApproxEqAbs(@as(f32, 0), rotated.x, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), rotated.y, 1.0e-6);

    const identity = sinCos(0);
    const unchanged = rotate2D(.{ .x = 3, .y = -4 }, identity);
    try std.testing.expectApproxEqAbs(@as(f32, 3), unchanged.x, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -4), unchanged.y, 1.0e-6);

    // Matches the inline formula the sprite quad emitter previously hand-rolled.
    const angle = sinCos(0.7);
    const point = Vec2{ .x = 2, .y = 5 };
    try std.testing.expectApproxEqAbs(
        point.x * angle.cos - point.y * angle.sin,
        rotate2D(point, angle).x,
        1.0e-6,
    );
    try std.testing.expectApproxEqAbs(
        point.x * angle.sin + point.y * angle.cos,
        rotate2D(point, angle).y,
        1.0e-6,
    );
}

test "clampMinMax matches SIMD clamp and tolerates NaN" {
    const simd = @import("simd.zig");
    try std.testing.expectEqual(@as(f32, 0), clampMinMax(-4, 0, 10));
    try std.testing.expectEqual(@as(f32, 10), clampMinMax(20, 0, 10));

    const scalar = clampMinMax(7, 0, 10);
    const vector = simd.clampFloat4(simd.splatFloat4(7), simd.splatFloat4(0), simd.splatFloat4(10));
    try std.testing.expectEqual(scalar, vector[0]);

    try std.testing.expect(!std.math.isNan(clampMinMax(std.math.nan(f32), 0, 10)));
}
