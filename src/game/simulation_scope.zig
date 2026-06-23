// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-owned simulation tier and active-scope contracts.
//! Slice 22 keeps runtime behavior full-active while landing the metadata and
//! stats shape that later chunk/visibility policy can consume.

const std = @import("std");

/// Persistent capability tier for an entity. Slice 22 stores this metadata and
/// reports stats only; later scoped runtime slices decide how tiers gate stages.
pub const SimulationTier = enum(u2) {
    dormant,
    kinematic,
    locomotion,
    cognition,

    pub fn allowsMovement(self: SimulationTier) bool {
        return switch (self) {
            .dormant => false,
            .kinematic, .locomotion, .cognition => true,
        };
    }

    pub fn allowsCollision(self: SimulationTier) bool {
        return switch (self) {
            .dormant, .kinematic => false,
            .locomotion, .cognition => true,
        };
    }

    pub fn allowsCognition(self: SimulationTier) bool {
        return self == .cognition;
    }
};

pub const ChunkCoord = struct {
    x: i32 = 0,
    y: i32 = 0,
};

/// Half-open chunk rectangle for a future fixed-step active scope.
/// The current slice validates and stores the shape without enabling filtering.
pub const ActiveRegion = struct {
    min: ChunkCoord,
    max_exclusive: ChunkCoord,

    pub fn init(min: ChunkCoord, max_exclusive: ChunkCoord) !ActiveRegion {
        const region = ActiveRegion{ .min = min, .max_exclusive = max_exclusive };
        try region.validate();
        return region;
    }

    pub fn validate(self: ActiveRegion) !void {
        if (self.max_exclusive.x <= self.min.x) return error.InvalidActiveRegion;
        if (self.max_exclusive.y <= self.min.y) return error.InvalidActiveRegion;
    }

    pub fn containsChunk(self: ActiveRegion, chunk: ChunkCoord) bool {
        return chunk.x >= self.min.x and chunk.x < self.max_exclusive.x and
            chunk.y >= self.min.y and chunk.y < self.max_exclusive.y;
    }
};

/// Cold per-entity metadata used by future scope construction.
/// It belongs on entity slots rather than hot SoA processor columns.
pub const EntitySimulationMetadata = struct {
    tier: SimulationTier = .cognition,
    chunk: ChunkCoord = .{},

    pub fn validate(self: EntitySimulationMetadata) !void {
        _ = self;
    }
};

/// Per-step scope counters. Slice 22 reports full-active counts so later scoped
/// behavior can prove what changed without adding runtime timers.
pub const SimulationScopeStats = struct {
    total_entities: usize = 0,
    dormant_entities: usize = 0,
    kinematic_entities: usize = 0,
    locomotion_entities: usize = 0,
    cognition_entities: usize = 0,
    movement_stage_entities: usize = 0,
    collision_stage_entities: usize = 0,
    collision_response_stage_entities: usize = 0,
    ai_stage_entities: usize = 0,
    steering_stage_entities: usize = 0,

    pub fn recordEntity(self: *SimulationScopeStats, metadata: EntitySimulationMetadata) void {
        self.total_entities += 1;
        switch (metadata.tier) {
            .dormant => self.dormant_entities += 1,
            .kinematic => self.kinematic_entities += 1,
            .locomotion => self.locomotion_entities += 1,
            .cognition => self.cognition_entities += 1,
        }
    }
};

/// Transient fixed-step scope. Today it represents the full active set; future
/// chunk/visibility policy can add concrete active regions and filtered lists.
pub const SimulationScope = struct {
    active_region: ?ActiveRegion = null,
    stats: SimulationScopeStats = .{},

    pub fn fullActive(stats: SimulationScopeStats) SimulationScope {
        return .{ .stats = stats };
    }
};

test "simulation tier capabilities are monotonic" {
    try std.testing.expect(!SimulationTier.dormant.allowsMovement());
    try std.testing.expect(SimulationTier.kinematic.allowsMovement());
    try std.testing.expect(!SimulationTier.kinematic.allowsCollision());
    try std.testing.expect(SimulationTier.locomotion.allowsCollision());
    try std.testing.expect(!SimulationTier.locomotion.allowsCognition());
    try std.testing.expect(SimulationTier.cognition.allowsCognition());
}

test "active region validates and contains half-open chunks" {
    try std.testing.expectError(
        error.InvalidActiveRegion,
        ActiveRegion.init(.{ .x = 2, .y = 0 }, .{ .x = 2, .y = 1 }),
    );

    const region = try ActiveRegion.init(.{ .x = -1, .y = 2 }, .{ .x = 3, .y = 5 });
    try std.testing.expect(region.containsChunk(.{ .x = -1, .y = 2 }));
    try std.testing.expect(region.containsChunk(.{ .x = 2, .y = 4 }));
    try std.testing.expect(!region.containsChunk(.{ .x = 3, .y = 4 }));
    try std.testing.expect(!region.containsChunk(.{ .x = 0, .y = 5 }));
}

test "full active scope preserves supplied stats" {
    var stats = SimulationScopeStats{};
    stats.recordEntity(.{});
    stats.recordEntity(.{ .tier = .locomotion });
    stats.movement_stage_entities = 2;
    stats.collision_stage_entities = 1;

    const scope = SimulationScope.fullActive(stats);
    try std.testing.expect(scope.active_region == null);
    try std.testing.expectEqual(@as(usize, 2), scope.stats.total_entities);
    try std.testing.expectEqual(@as(usize, 1), scope.stats.cognition_entities);
    try std.testing.expectEqual(@as(usize, 1), scope.stats.locomotion_entities);
    try std.testing.expectEqual(@as(usize, 2), scope.stats.movement_stage_entities);
    try std.testing.expectEqual(@as(usize, 1), scope.stats.collision_stage_entities);
}
