// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const math = @import("math.zig");

pub const lane_count: usize = 4;
pub const Float4 = @Vector(lane_count, f32);
pub const Int4 = @Vector(lane_count, i32);
pub const Mask4 = @Vector(lane_count, bool);

pub fn float4(x: f32, y: f32, z: f32, w: f32) Float4 {
    return .{ x, y, z, w };
}

pub fn int4(x: i32, y: i32, z: i32, w: i32) Int4 {
    return .{ x, y, z, w };
}

pub fn splatFloat4(value: f32) Float4 {
    return @splat(value);
}

pub fn splatInt4(value: i32) Int4 {
    return @splat(value);
}

pub fn loadFloat4(values: []const f32) Float4 {
    std.debug.assert(values.len >= lane_count);
    return .{ values[0], values[1], values[2], values[3] };
}

pub fn loadInt4(values: []const i32) Int4 {
    std.debug.assert(values.len >= lane_count);
    return .{ values[0], values[1], values[2], values[3] };
}

pub fn storeFloat4(values: *[lane_count]f32, vector: Float4) void {
    values.* = toFloatArray(vector);
}

pub fn storeFloat4Slice(values: []f32, vector: Float4) void {
    std.debug.assert(values.len >= lane_count);
    const stored = toFloatArray(vector);
    inline for (0..lane_count) |index| {
        values[index] = stored[index];
    }
}

pub fn storeInt4(values: *[lane_count]i32, vector: Int4) void {
    values.* = toIntArray(vector);
}

pub fn toFloatArray(vector: Float4) [lane_count]f32 {
    return .{ vector[0], vector[1], vector[2], vector[3] };
}

pub fn toIntArray(vector: Int4) [lane_count]i32 {
    return .{ vector[0], vector[1], vector[2], vector[3] };
}

pub fn addFloat4(lhs: Float4, rhs: Float4) Float4 {
    return lhs + rhs;
}

pub fn addInt4(lhs: Int4, rhs: Int4) Int4 {
    return lhs + rhs;
}

pub fn subFloat4(lhs: Float4, rhs: Float4) Float4 {
    return lhs - rhs;
}

pub fn subInt4(lhs: Int4, rhs: Int4) Int4 {
    return lhs - rhs;
}

pub fn mulFloat4(lhs: Float4, rhs: Float4) Float4 {
    return lhs * rhs;
}

pub fn mulInt4(lhs: Int4, rhs: Int4) Int4 {
    return lhs * rhs;
}

pub fn divFloat4(lhs: Float4, rhs: Float4) Float4 {
    return lhs / rhs;
}

/// Per-lane linear interpolation between `start` and `end` by `amount`. SIMD
/// counterpart of `math.lerp`.
pub fn lerpFloat4(start: Float4, end: Float4, amount: Float4) Float4 {
    return start + (end - start) * amount;
}

/// Per-lane truncating integer division. Lowered lane-by-lane because Zig's `/`
/// operator rejects signed integer operands (it requires @divTrunc/@divFloor/
/// @divExact), so there is no single signed-vector divide to fold this into.
pub fn divInt4(lhs: Int4, rhs: Int4) Int4 {
    return .{
        @divTrunc(lhs[0], rhs[0]),
        @divTrunc(lhs[1], rhs[1]),
        @divTrunc(lhs[2], rhs[2]),
        @divTrunc(lhs[3], rhs[3]),
    };
}

/// Vectorized counterpart of `math.floorToI32`: floors each lane to `i32`,
/// saturating identically to the scalar form (NaN -> 0; at/below `minInt(i32)`
/// -> `minInt(i32)`; at/above the f32 rounding of `maxInt(i32)` -> `maxInt(i32)`).
/// Lanes needing saturation are replaced with a safe dummy value before the
/// vector cast (Zig requires every lane in range for `@intFromFloat`) and then
/// patched with the exact saturated constant, mirroring the scalar function's
/// early-return branches instead of clamping into a castable subrange — the
/// f32 grid spacing near `maxInt(i32)` (256 apart) makes "clamp to max minus
/// one" silently round back to the unrepresentable boundary.
pub fn floorToI4(values: Float4) Int4 {
    const floored = @floor(values);
    const is_nan = floored != floored;
    const min_f = splatFloat4(@as(f32, @floatFromInt(std.math.minInt(i32))));
    const max_f = splatFloat4(@as(f32, @floatFromInt(std.math.maxInt(i32))));
    const at_or_below_min = floored <= min_f;
    const at_or_above_max = floored >= max_f;
    const needs_override = is_nan | at_or_below_min | at_or_above_max;
    const cast_source = selectFloat4(needs_override, splatFloat4(0), floored);
    const cast: Int4 = @intFromFloat(cast_source);
    const with_max = selectInt4(at_or_above_max, splatInt4(std.math.maxInt(i32)), cast);
    const with_min = selectInt4(at_or_below_min, splatInt4(std.math.minInt(i32)), with_max);
    return selectInt4(is_nan, splatInt4(0), with_min);
}

pub fn minFloat4(lhs: Float4, rhs: Float4) Float4 {
    return @min(lhs, rhs);
}

pub fn minInt4(lhs: Int4, rhs: Int4) Int4 {
    return @min(lhs, rhs);
}

pub fn maxFloat4(lhs: Float4, rhs: Float4) Float4 {
    return @max(lhs, rhs);
}

pub fn maxInt4(lhs: Int4, rhs: Int4) Int4 {
    return @max(lhs, rhs);
}

pub fn lessThanFloat4(lhs: Float4, rhs: Float4) Mask4 {
    return lhs < rhs;
}

pub fn lessThanInt4(lhs: Int4, rhs: Int4) Mask4 {
    return lhs < rhs;
}

pub fn greaterThanFloat4(lhs: Float4, rhs: Float4) Mask4 {
    return lhs > rhs;
}

pub fn greaterThanInt4(lhs: Int4, rhs: Int4) Mask4 {
    return lhs > rhs;
}

pub fn equalFloat4(lhs: Float4, rhs: Float4) Mask4 {
    return lhs == rhs;
}

pub fn equalInt4(lhs: Int4, rhs: Int4) Mask4 {
    return lhs == rhs;
}

pub fn selectFloat4(mask: Mask4, true_values: Float4, false_values: Float4) Float4 {
    return @select(f32, mask, true_values, false_values);
}

pub fn selectInt4(mask: Mask4, true_values: Int4, false_values: Int4) Int4 {
    return @select(i32, mask, true_values, false_values);
}

pub fn clampFloat4(values: Float4, minimum: Float4, maximum: Float4) Float4 {
    return minFloat4(maxFloat4(values, minimum), maximum);
}

pub fn clampInt4(values: Int4, minimum: Int4, maximum: Int4) Int4 {
    return minInt4(maxInt4(values, minimum), maximum);
}

// Counts the true lanes in a mask via a single vector reduction.
pub fn countTrue(mask: Mask4) u32 {
    return @reduce(.Add, @as(@Vector(lane_count, u32), @intFromBool(mask)));
}

pub fn vectorCount(item_count: usize) usize {
    return item_count / lane_count;
}

pub fn vectorizedEnd(item_count: usize) usize {
    return vectorCount(item_count) * lane_count;
}

pub fn tailLen(item_count: usize) usize {
    return item_count - vectorizedEnd(item_count);
}

pub fn hasTail(item_count: usize) bool {
    return tailLen(item_count) != 0;
}

/// Per-lane pair of 2D components (one `Float4` per axis).
pub const Vec2x4 = struct {
    x: Float4,
    y: Float4,
};

/// Per-lane sine and cosine results.
pub const SinCos4 = struct {
    sin: Float4,
    cos: Float4,
};

/// Gathers four `f32` values from `values` at the given indices into lane order.
/// Use to pack sparse SoA rows into contiguous lanes before vector math.
pub fn gatherFloat4(values: []const f32, indices: [lane_count]usize) Float4 {
    return .{
        values[indices[0]],
        values[indices[1]],
        values[indices[2]],
        values[indices[3]],
    };
}

/// Gathers four `i32` values from `values` at the given indices into lane order.
pub fn gatherInt4(values: []const i32, indices: [lane_count]usize) Int4 {
    return .{
        values[indices[0]],
        values[indices[1]],
        values[indices[2]],
        values[indices[3]],
    };
}

/// Scatters lane values back to `values` at the given indices. Indices must be
/// distinct; overlapping targets make the result order-dependent.
pub fn scatterFloat4(values: []f32, indices: [lane_count]usize, vector: Float4) void {
    inline for (0..lane_count) |i| {
        inline for (i + 1..lane_count) |j| {
            std.debug.assert(indices[i] != indices[j]);
        }
    }
    inline for (0..lane_count) |lane| {
        values[indices[lane]] = vector[lane];
    }
}

/// Per-lane reciprocal square root, `1 / sqrt(values)`. Lanes that are zero or
/// negative produce inf/NaN; guard the input when that is possible.
pub fn reciprocalSqrtFloat4(values: Float4) Float4 {
    return splatFloat4(1) / @sqrt(values);
}

/// Per-lane squared length of 2D vectors.
pub fn lengthSquared2Float4(x: Float4, y: Float4) Float4 {
    return x * x + y * y;
}

/// Normalizes per-lane 2D vectors, returning zero for lanes whose squared
/// length is at or below `epsilon`. Matches scalar normalize-or-zero semantics
/// and never produces inf/NaN: the divisor is floored before the reciprocal,
/// and short lanes are masked to zero afterward.
pub fn normalizeOrZero2Float4(x: Float4, y: Float4, epsilon: f32) Vec2x4 {
    const len2 = lengthSquared2Float4(x, y);
    const positive = greaterThanFloat4(len2, splatFloat4(epsilon));
    const safe_len2 = maxFloat4(len2, splatFloat4(std.math.floatMin(f32)));
    const inv_len = reciprocalSqrtFloat4(safe_len2);
    const zero = splatFloat4(0);
    return .{
        .x = selectFloat4(positive, x * inv_len, zero),
        .y = selectFloat4(positive, y * inv_len, zero),
    };
}

/// Per-lane sine. Uses the compiler builtin element-wise over the vector; the
/// single call site lets a vectorized polynomial replace this later without
/// touching callers.
pub fn sinFloat4(values: Float4) Float4 {
    return @sin(values);
}

/// Per-lane cosine. See `sinFloat4` for the implementation note.
pub fn cosFloat4(values: Float4) Float4 {
    return @cos(values);
}

/// Per-lane sine and cosine together, for rotation and field-of-view math.
pub fn sinCosFloat4(values: Float4) SinCos4 {
    return .{ .sin = @sin(values), .cos = @cos(values) };
}

fn expectFloatArrayApprox(actual: [lane_count]f32, expected: [lane_count]f32) !void {
    for (actual, expected) |actual_value, expected_value| {
        try std.testing.expectApproxEqAbs(expected_value, actual_value, 0.001);
    }
}

test "float load store and conversion keep stable lane order" {
    const source = [_]f32{ 1, 2, 3, 4 };
    const vector = loadFloat4(&source);

    try expectFloatArrayApprox(toFloatArray(vector), source);

    var stored: [lane_count]f32 = undefined;
    storeFloat4(&stored, vector);
    try expectFloatArrayApprox(stored, source);

    var stored_slice = [_]f32{ 0, 0, 0, 0, 99 };
    storeFloat4Slice(stored_slice[0..], vector);
    try expectFloatArrayApprox(stored_slice[0..lane_count].*, source);
    try std.testing.expectEqual(@as(f32, 99), stored_slice[lane_count]);
}

test "int load store and conversion keep stable lane order" {
    const source = [_]i32{ 1, -2, 3, -4 };
    const vector = loadInt4(&source);

    try std.testing.expectEqual(source, toIntArray(vector));

    var stored: [lane_count]i32 = undefined;
    storeInt4(&stored, vector);
    try std.testing.expectEqual(source, stored);
}

test "float operations match scalar results" {
    const lhs = float4(8, -6, 4, 9);
    const rhs = float4(2, 3, -2, 4.5);

    try expectFloatArrayApprox(toFloatArray(addFloat4(lhs, rhs)), .{ 10, -3, 2, 13.5 });
    try expectFloatArrayApprox(toFloatArray(subFloat4(lhs, rhs)), .{ 6, -9, 6, 4.5 });
    try expectFloatArrayApprox(toFloatArray(mulFloat4(lhs, rhs)), .{ 16, -18, -8, 40.5 });
    try expectFloatArrayApprox(toFloatArray(divFloat4(lhs, rhs)), .{ 4, -2, -2, 2 });
    try expectFloatArrayApprox(toFloatArray(minFloat4(lhs, rhs)), .{ 2, -6, -2, 4.5 });
    try expectFloatArrayApprox(toFloatArray(maxFloat4(lhs, rhs)), .{ 8, 3, 4, 9 });
}

test "int operations match scalar results" {
    const lhs = int4(8, -7, 4, -9);
    const rhs = int4(2, 3, -2, 4);

    try std.testing.expectEqual([_]i32{ 10, -4, 2, -5 }, toIntArray(addInt4(lhs, rhs)));
    try std.testing.expectEqual([_]i32{ 6, -10, 6, -13 }, toIntArray(subInt4(lhs, rhs)));
    try std.testing.expectEqual([_]i32{ 16, -21, -8, -36 }, toIntArray(mulInt4(lhs, rhs)));
    try std.testing.expectEqual([_]i32{ 4, -2, -2, -2 }, toIntArray(divInt4(lhs, rhs)));
    try std.testing.expectEqual([_]i32{ 2, -7, -2, -9 }, toIntArray(minInt4(lhs, rhs)));
    try std.testing.expectEqual([_]i32{ 8, 3, 4, 4 }, toIntArray(maxInt4(lhs, rhs)));
}

test "compare select and clamp helpers match scalar behavior" {
    const values = float4(-4, 2, 6, 12);
    const minimum = splatFloat4(0);
    const maximum = splatFloat4(10);
    const mask = lessThanFloat4(values, maximum);

    try std.testing.expectEqual(Mask4{ true, true, true, false }, mask);
    try expectFloatArrayApprox(
        toFloatArray(selectFloat4(mask, values, maximum)),
        .{ -4, 2, 6, 10 },
    );
    try expectFloatArrayApprox(
        toFloatArray(clampFloat4(values, minimum, maximum)),
        .{ 0, 2, 6, 10 },
    );

    const ints = int4(-4, 2, 6, 12);
    try std.testing.expectEqual(Mask4{ false, true, true, true }, greaterThanInt4(ints, splatInt4(0)));
    try std.testing.expectEqual(
        [_]i32{ 0, 2, 6, 10 },
        toIntArray(clampInt4(ints, splatInt4(0), splatInt4(10))),
    );
}

test "countTrue matches a scalar lane sum" {
    try std.testing.expectEqual(@as(u32, 0), countTrue(Mask4{ false, false, false, false }));
    try std.testing.expectEqual(@as(u32, lane_count), countTrue(@splat(true)));
    try std.testing.expectEqual(@as(u32, 2), countTrue(Mask4{ true, false, true, false }));
    const mask = Mask4{ true, true, false, true };
    var scalar: u32 = 0;
    inline for (0..lane_count) |i| scalar += @intFromBool(mask[i]);
    try std.testing.expectEqual(scalar, countTrue(mask));
}

test "tail helpers cover empty partial exact and multi lane counts" {
    try std.testing.expectEqual(@as(usize, 0), vectorCount(0));
    try std.testing.expectEqual(@as(usize, 0), vectorizedEnd(0));
    try std.testing.expectEqual(@as(usize, 0), tailLen(0));
    try std.testing.expect(!hasTail(0));

    try std.testing.expectEqual(@as(usize, 0), vectorCount(3));
    try std.testing.expectEqual(@as(usize, 0), vectorizedEnd(3));
    try std.testing.expectEqual(@as(usize, 3), tailLen(3));
    try std.testing.expect(hasTail(3));

    try std.testing.expectEqual(@as(usize, 1), vectorCount(4));
    try std.testing.expectEqual(@as(usize, 4), vectorizedEnd(4));
    try std.testing.expectEqual(@as(usize, 0), tailLen(4));
    try std.testing.expect(!hasTail(4));

    try std.testing.expectEqual(@as(usize, 2), vectorCount(11));
    try std.testing.expectEqual(@as(usize, 8), vectorizedEnd(11));
    try std.testing.expectEqual(@as(usize, 3), tailLen(11));
    try std.testing.expect(hasTail(11));
}

test "gather and scatter move lanes through sparse indices" {
    const source = [_]f32{ 10, 11, 12, 13, 14, 15 };
    const gathered = gatherFloat4(&source, .{ 5, 0, 3, 1 });
    try expectFloatArrayApprox(toFloatArray(gathered), .{ 15, 10, 13, 11 });

    const int_source = [_]i32{ 0, -1, -2, -3, -4 };
    try std.testing.expectEqual(
        [_]i32{ -4, 0, -2, -1 },
        toIntArray(gatherInt4(&int_source, .{ 4, 0, 2, 1 })),
    );

    var dest = [_]f32{ 0, 0, 0, 0, 0, 0 };
    scatterFloat4(&dest, .{ 5, 0, 3, 1 }, float4(15, 10, 13, 11));
    try std.testing.expectEqual([_]f32{ 10, 11, 0, 13, 0, 15 }, dest);
}

test "reciprocal sqrt matches scalar reference" {
    const values = float4(1, 4, 16, 0.25);
    const result = toFloatArray(reciprocalSqrtFloat4(values));
    try expectFloatArrayApprox(result, .{ 1, 0.5, 0.25, 2 });
}

test "normalize or zero matches scalar and zeroes short lanes" {
    const epsilon: f32 = 1.0e-12;
    const xs = float4(3, 0, -5, 0);
    const ys = float4(4, 0, 0, -2);
    const normalized = normalizeOrZero2Float4(xs, ys, epsilon);

    const x_out = toFloatArray(normalized.x);
    const y_out = toFloatArray(normalized.y);
    inline for (0..lane_count) |lane| {
        const len2 = xs[lane] * xs[lane] + ys[lane] * ys[lane];
        if (len2 <= epsilon) {
            try std.testing.expectEqual(@as(f32, 0), x_out[lane]);
            try std.testing.expectEqual(@as(f32, 0), y_out[lane]);
        } else {
            const inv = 1.0 / @sqrt(len2);
            try std.testing.expectApproxEqAbs(xs[lane] * inv, x_out[lane], 0.001);
            try std.testing.expectApproxEqAbs(ys[lane] * inv, y_out[lane], 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 1), x_out[lane] * x_out[lane] + y_out[lane] * y_out[lane], 0.001);
        }
    }
}

test "floorToI4 matches math.floorToI32 lane-for-lane, including NaN/inf/boundary saturation" {
    const cases = [_]f32{
        0,                                             1.5,
        -1.5,                                          3.7,
        -3.2,                                          std.math.nan(f32),
        std.math.inf(f32),                             -std.math.inf(f32),
        1.0e30,                                        -1.0e30,
        @as(f32, @floatFromInt(std.math.minInt(i32))), @as(f32, @floatFromInt(std.math.maxInt(i32))),
    };
    var i: usize = 0;
    while (i + lane_count <= cases.len) : (i += lane_count) {
        const vector = loadFloat4(cases[i..]);
        const simd_result = toIntArray(floorToI4(vector));
        for (0..lane_count) |lane| {
            try std.testing.expectEqual(math.floorToI32(cases[i + lane]), simd_result[lane]);
        }
    }
    // Cover the tail values individually too (cases.len is not lane-aligned).
    while (i < cases.len) : (i += 1) {
        const vector = splatFloat4(cases[i]);
        const simd_result = toIntArray(floorToI4(vector));
        try std.testing.expectEqual(math.floorToI32(cases[i]), simd_result[0]);
    }
}

test "sin and cos match scalar builtins per lane" {
    const angles = float4(0, std.math.pi / 6.0, std.math.pi / 2.0, std.math.pi);
    const sines = toFloatArray(sinFloat4(angles));
    const cosines = toFloatArray(cosFloat4(angles));
    const both = sinCosFloat4(angles);

    inline for (0..lane_count) |lane| {
        try std.testing.expectApproxEqAbs(@sin(angles[lane]), sines[lane], 0.0001);
        try std.testing.expectApproxEqAbs(@cos(angles[lane]), cosines[lane], 0.0001);
        try std.testing.expectApproxEqAbs(sines[lane], both.sin[lane], 0.0001);
        try std.testing.expectApproxEqAbs(cosines[lane], both.cos[lane], 0.0001);
    }
}
