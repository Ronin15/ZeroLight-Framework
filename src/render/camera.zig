// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

pub const Vec2 = @import("../core/math.zig").Vec2;

// World→screen is baked into the GPU vertex uniform (see Renderer's presentation
// path); there is no CPU camera transform. If screen→world is ever needed (e.g.
// for picking), add an explicit screenToWorld rather than reviving the inverse.
pub const Camera2D = struct {
    position: Vec2 = .{},
    zoom: f32 = 1.0,
};
