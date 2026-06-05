// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");

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

/// Integer division uses Zig's trunc-toward-zero semantics.
pub fn divInt4(lhs: Int4, rhs: Int4) Int4 {
    return .{
        @divTrunc(lhs[0], rhs[0]),
        @divTrunc(lhs[1], rhs[1]),
        @divTrunc(lhs[2], rhs[2]),
        @divTrunc(lhs[3], rhs[3]),
    };
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
