// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");

pub const Faction = enum { neutral, player, ally, hostile };

pub const Stance = enum { hostile, neutral, friendly };

const faction_count = @typeInfo(Faction).@"enum".fields.len;

// Indexed [a][b]; kept explicit and symmetric so authoring the relationship is
// a direct table edit rather than a derived/computed rule.
const relationship_matrix: [faction_count][faction_count]Stance = .{
    // neutral
    .{ .neutral, .neutral, .neutral, .neutral },
    // player
    .{ .neutral, .friendly, .friendly, .hostile },
    // ally
    .{ .neutral, .friendly, .friendly, .hostile },
    // hostile
    .{ .neutral, .hostile, .hostile, .friendly },
};

pub fn stance(a: Faction, b: Faction) Stance {
    return relationship_matrix[@intFromEnum(a)][@intFromEnum(b)];
}

test "stance is symmetric for defined faction pairs" {
    try std.testing.expectEqual(Stance.hostile, stance(.player, .hostile));
    try std.testing.expectEqual(Stance.hostile, stance(.hostile, .player));

    try std.testing.expectEqual(Stance.friendly, stance(.player, .ally));
    try std.testing.expectEqual(Stance.friendly, stance(.ally, .player));

    try std.testing.expectEqual(Stance.neutral, stance(.player, .neutral));
    try std.testing.expectEqual(Stance.neutral, stance(.neutral, .player));

    try std.testing.expectEqual(Stance.hostile, stance(.ally, .hostile));
    try std.testing.expectEqual(Stance.hostile, stance(.hostile, .ally));
}

test "stance differs across faction pairs" {
    try std.testing.expectEqual(Stance.neutral, stance(.neutral, .neutral));
    try std.testing.expectEqual(Stance.friendly, stance(.hostile, .hostile));

    try std.testing.expectEqual(Stance.hostile, stance(.player, .hostile));
    try std.testing.expectEqual(Stance.friendly, stance(.player, .ally));
}
