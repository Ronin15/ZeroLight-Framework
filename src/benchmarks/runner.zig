// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const logging = @import("../core/logging.zig");
const ai = @import("ai.zig");
const collision = @import("collision.zig");
const collision_response = @import("collision_response.zig");
const movement = @import("movement.zig");
const particles = @import("particles.zig");
const pathfinding = @import("pathfinding.zig");
const steering = @import("steering.zig");
const suite = @import("suite.zig");

pub const std_options = logging.std_options;

const benchmark_groups = [_]suite.BenchmarkGroup{
    movement.group,
    particles.group,
    ai.group,
    collision.group,
    collision.sparse_group,
    collision_response.solid_group,
    collision_response.bounce_group,
    collision_response.trigger_group,
    collision_response.mixed_group,
    pathfinding.group,
    pathfinding.fallback_group,
    pathfinding.fallback_detour_group,
    pathfinding.fallback_unreachable_group,
    pathfinding.hard_fallback_group,
    steering.group,
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();

    var parsed_args = std.ArrayList([]const u8).empty;
    defer parsed_args.deinit(init.gpa);
    while (args.next()) |arg| {
        try parsed_args.append(init.gpa, arg);
    }

    const options = suite.parseOptions(parsed_args.items) catch |err| switch (err) {
        error.HelpRequested => {
            suite.printUsage();
            return;
        },
        else => {
            suite.printUsage();
            return err;
        },
    };

    try suite.runAll(init.gpa, init.io, &benchmark_groups, options);
}
