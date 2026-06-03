// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");

pub const TimeLoop = struct {
    pub const target_update_hz: u64 = 60;
    pub const fixed_delta_ns: u64 = std.time.ns_per_s / target_update_hz;
    pub const fixed_delta_seconds: f32 = 1.0 / @as(f32, @floatFromInt(target_update_hz));
    pub const max_updates_per_frame: u32 = 5;

    last_time_ns: u64,
    accumulator_ns: u64 = 0,
    updates_this_frame: u32 = 0,
    hit_update_cap: bool = false,

    pub fn init(now_ns: u64) TimeLoop {
        return .{ .last_time_ns = now_ns };
    }

    pub fn beginFrame(self: *TimeLoop, now_ns: u64) void {
        const elapsed_ns = if (now_ns > self.last_time_ns) now_ns - self.last_time_ns else 0;
        const max_elapsed_ns = fixed_delta_ns * max_updates_per_frame;
        self.last_time_ns = now_ns;
        self.updates_this_frame = 0;
        self.hit_update_cap = elapsed_ns > max_elapsed_ns;
        self.accumulator_ns += @min(elapsed_ns, max_elapsed_ns);
    }

    pub fn reset(self: *TimeLoop, now_ns: u64) void {
        self.last_time_ns = now_ns;
        self.accumulator_ns = 0;
        self.updates_this_frame = 0;
        self.hit_update_cap = false;
    }

    pub fn shouldUpdate(self: *const TimeLoop) bool {
        return self.accumulator_ns >= fixed_delta_ns and
            self.updates_this_frame < max_updates_per_frame;
    }

    pub fn finishUpdate(self: *TimeLoop) void {
        std.debug.assert(self.accumulator_ns >= fixed_delta_ns);
        std.debug.assert(self.updates_this_frame < max_updates_per_frame);

        self.accumulator_ns -= fixed_delta_ns;
        self.updates_this_frame += 1;
        if (self.updates_this_frame == max_updates_per_frame and self.accumulator_ns >= fixed_delta_ns) {
            self.accumulator_ns = fixed_delta_ns - 1;
            self.hit_update_cap = true;
        }
    }

    pub fn interpolationAlpha(self: *const TimeLoop) f32 {
        return @as(f32, @floatFromInt(self.accumulator_ns)) /
            @as(f32, @floatFromInt(fixed_delta_ns));
    }
};

test "half frame elapsed produces no updates and half alpha" {
    var loop = TimeLoop.init(0);
    loop.beginFrame(TimeLoop.fixed_delta_ns / 2);

    try std.testing.expect(!loop.shouldUpdate());
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), loop.interpolationAlpha(), 0.001);
}

test "one fixed frame elapsed produces one update and zero alpha" {
    var loop = TimeLoop.init(0);
    loop.beginFrame(TimeLoop.fixed_delta_ns);

    try std.testing.expect(loop.shouldUpdate());
    loop.finishUpdate();

    try std.testing.expect(!loop.shouldUpdate());
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), loop.interpolationAlpha(), 0.001);
}

test "large elapsed frame is clamped" {
    var loop = TimeLoop.init(0);
    loop.beginFrame(TimeLoop.fixed_delta_ns * 100);

    var updates: u32 = 0;
    while (loop.shouldUpdate()) {
        loop.finishUpdate();
        updates += 1;
    }

    try std.testing.expectEqual(TimeLoop.max_updates_per_frame, updates);
    try std.testing.expect(loop.hit_update_cap);
    try std.testing.expect(loop.accumulator_ns < TimeLoop.fixed_delta_ns);
}

test "update cap prevents more than five fixed updates" {
    var loop = TimeLoop.init(0);
    loop.accumulator_ns = TimeLoop.fixed_delta_ns * (TimeLoop.max_updates_per_frame + 3);

    var updates: u32 = 0;
    while (loop.shouldUpdate()) {
        loop.finishUpdate();
        updates += 1;
    }

    try std.testing.expectEqual(TimeLoop.max_updates_per_frame, updates);
    try std.testing.expect(loop.hit_update_cap);
    try std.testing.expect(loop.accumulator_ns < TimeLoop.fixed_delta_ns);
}

test "reset clears accumulated catch-up time" {
    var loop = TimeLoop.init(0);
    loop.beginFrame(TimeLoop.fixed_delta_ns * 3);

    loop.reset(123);

    try std.testing.expectEqual(@as(u64, 123), loop.last_time_ns);
    try std.testing.expectEqual(@as(u64, 0), loop.accumulator_ns);
    try std.testing.expect(!loop.shouldUpdate());
    try std.testing.expect(!loop.hit_update_cap);
}
