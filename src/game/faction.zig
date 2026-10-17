// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");

pub const Faction = enum { neutral, player, ally, hostile };

pub const Stance = enum { hostile, neutral, friendly };

const faction_count = @typeInfo(Faction).@"enum".field_names.len;

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
    return relationship_matrix[@backingInt(a)][@backingInt(b)];
}

pub const FactionSet = std.EnumSet(Faction);

const stance_count = @typeInfo(Stance).@"enum".field_names.len;

// [wanted][self]: the factions `self` holds at stance `wanted`, from `relationship_matrix`.
const stance_sets: [stance_count][faction_count]FactionSet = blk: {
    var sets: [stance_count][faction_count]FactionSet = @splat(@splat(.empty));
    for (std.meta.tags(Faction)) |self_faction| {
        for (std.meta.tags(Faction)) |other| sets[@backingInt(stance(self_faction, other))][@backingInt(self_faction)].insert(other);
    }
    break :blk sets;
};

/// The factions `self` holds at stance `wanted`: a neighbor query's faction mask.
pub fn factionsWithStance(self: Faction, wanted: Stance) FactionSet {
    return stance_sets[@backingInt(wanted)][@backingInt(self)];
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

test "factionsWithStance holds exactly the factions at that stance, for every pair" {
    for (std.meta.tags(Faction)) |self_faction| {
        var union_of_stances = FactionSet.empty;
        for (std.meta.tags(Stance)) |wanted| {
            const set = factionsWithStance(self_faction, wanted);
            for (std.meta.tags(Faction)) |other| {
                try std.testing.expectEqual(stance(self_faction, other) == wanted, set.contains(other));
            }
            union_of_stances.setUnion(set);
        }
        try std.testing.expect(union_of_stances.eql(.full));
    }
    try std.testing.expect(factionsWithStance(.player, .hostile).eql(.initOne(.hostile)));
    try std.testing.expect(factionsWithStance(.hostile, .hostile).eql(.initMany(&.{ .player, .ally })));
    try std.testing.expect(factionsWithStance(.neutral, .friendly).eql(.empty));
}
