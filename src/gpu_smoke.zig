// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const gpu_smoke = @import("platform/gpu_smoke_impl.zig");

pub fn main(init: std.process.Init) !void {
    try gpu_smoke.main(init);
}
