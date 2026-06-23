// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");

pub const WorldDepth = enum(i32) {
    floor = -2,
    obstacle = -1,
    actor = 0,
    effect = 1,
    marker = 2,
};

pub fn worldZ(depth: WorldDepth) i32 {
    return @intFromEnum(depth);
}

pub fn worldZWithOffset(base_z: i32, depth: WorldDepth) i32 {
    const value = @as(i64, base_z) + @as(i64, worldZ(depth));
    return @intCast(std.math.clamp(
        value,
        @as(i64, std.math.minInt(i32)),
        @as(i64, std.math.maxInt(i32)),
    ));
}

test "world depth bands are ordered from lower world to overlays" {
    try std.testing.expect(worldZ(.floor) < worldZ(.obstacle));
    try std.testing.expect(worldZ(.obstacle) < worldZ(.actor));
    try std.testing.expect(worldZ(.actor) <= worldZ(.effect));
    try std.testing.expect(worldZ(.effect) < worldZ(.marker));
}

test "world z offset saturates at i32 bounds" {
    try std.testing.expectEqual(std.math.maxInt(i32), worldZWithOffset(std.math.maxInt(i32), .marker));
    try std.testing.expectEqual(std.math.minInt(i32), worldZWithOffset(std.math.minInt(i32), .floor));
}
