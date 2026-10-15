// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared contact predicates for sensory stimuli and collision audio.
//! Pure leaf: no controller state, no SDL.

const std = @import("std");
const math = @import("../core/math.zig");
const DataSystem = @import("data_system.zig").DataSystem;
const EntityId = @import("data_system.zig").EntityId;
const CollisionContact = @import("simulation.zig").CollisionContact;

pub fn involvesEntity(contact: CollisionContact, entity: EntityId) bool {
    return contact.a.eql(entity) or contact.b.eql(entity);
}

/// Midpoint of the two bodies. Null when either body is missing.
pub fn midpoint(data: *const DataSystem, contact: CollisionContact) ?math.Vec2 {
    const a = data.movementBodyConst(contact.a) orelse return null;
    const b = data.movementBodyConst(contact.b) orelse return null;
    return .{
        .x = (a.position.x + b.position.x) * 0.5,
        .y = (a.position.y + b.position.y) * 0.5,
    };
}

/// Loudness scale shared by impact stimuli and collision SFX gain.
/// `clamp(penetration / 18, 0.25, 1)`.
pub fn penetrationScale(penetration: f32) f32 {
    return std.math.clamp(penetration / 18.0, 0.25, 1.0);
}

test "penetrationScale matches the shared impact curve" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), penetrationScale(0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), penetrationScale(4.5), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), penetrationScale(9), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), penetrationScale(18), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), penetrationScale(40), 0.0001);
}
