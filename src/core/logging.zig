// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const build_options = @import("build_options");

pub const std_options = std.Options{
    .log_level = @enumFromInt(build_options.log_level),
};

pub fn enabled(comptime level: std.log.Level) bool {
    return @intFromEnum(level) <= build_options.log_level;
}

pub const app = std.log.scoped(.app);
pub const assets = std.log.scoped(.assets);
pub const audio = std.log.scoped(.audio);
pub const core = std.log.scoped(.core);
pub const game = std.log.scoped(.game);
pub const render = std.log.scoped(.render);
pub const platform = std.log.scoped(.platform);
pub const debug_overlay = std.log.scoped(.debug_overlay);
pub const perf = std.log.scoped(.perf);
