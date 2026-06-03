// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
pub const Vec2 = @import("../core/math.zig").Vec2;

pub const Camera2D = struct {
    position: Vec2 = .{},
    zoom: f32 = 1.0,

    pub fn worldToScreen(self: Camera2D, point: anytype) Vec2 {
        return .{
            .x = (point.x - self.position.x) * self.zoom,
            .y = (point.y - self.position.y) * self.zoom,
        };
    }
};

test "camera transforms world coordinates into screen coordinates" {
    const camera = Camera2D{
        .position = .{ .x = 10, .y = 20 },
        .zoom = 2,
    };
    const result = camera.worldToScreen(.{ .x = 14, .y = 25 });

    try std.testing.expectApproxEqAbs(@as(f32, 8), result.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), result.y, 0.001);
}
