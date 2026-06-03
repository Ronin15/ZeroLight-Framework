// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Minimal package root for shared starter helpers and tests.

const math = @import("core/math.zig");

pub const Vec2 = math.Vec2;
pub const clamp = math.clamp;
pub const lerpVec2 = math.lerpVec2;
