// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const runner = @import("benchmarks/runner.zig");

pub const std_options = runner.std_options;

// Bench pass-shape asserts and main-thread shares read the perf counters.
comptime {
    if (!@import("app/runtime_perf_log.zig").enabled) @compileError("the bench build enables the perf_counters build option");
}

pub fn main(init: std.process.Init) !void {
    try runner.main(init);
}
