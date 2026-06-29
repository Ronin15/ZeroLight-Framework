// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-owned simulation tier and active-scope contracts.
//! Slice 24 wires the tier/chunk scaffolding into real scoped behavior:
//! cognition-stage gating by camera halo, stagger cadence, and tier commands.

const std = @import("std");

/// Steps between cognition-stage runs for a single entity. AI and steering run
/// once every cognition_stagger_n fixed steps per entity, rotating by stagger_phase.
pub const cognition_stagger_n: u8 = 4;

/// Simulation LOD bands as chunk distance from the camera-visible border. An
/// entity's tier is the band its chunk falls into: within cognition_halo it
/// thinks; out to locomotion_halo it moves+collides; out to kinematic_halo it
/// moves only; beyond that it is dormant (fully asleep). The bands must be
/// monotonically increasing.
///
/// Sized in chunks (1 chunk = chunk_size_tiles × tile_size px; e.g. 8×32 = 256 px).
/// These are radii BEYOND the visible region, so cognition must clear a full screen
/// of margin or entities pop-think as they scroll in: a 4K width (3840 px) is ~15
/// chunks, so cognition ≥ 16 keeps a screen-wide thinking halo. Defaults give
/// roughly one screen of cognition margin, then a screen each of locomotion and
/// kinematic before dormant. Tune to your world/camera scale and perf budget.
pub const cognition_halo_chunks: u16 = 16;
pub const locomotion_halo_chunks: u16 = 32;
pub const kinematic_halo_chunks: u16 = 48;

/// Chunk-distance weight of one depth/level step in the cube LOD ball over
/// (chunk_x, chunk_y, level); applied via `lodDistance`. At the default 16
/// (= cognition_halo_chunks) one level off the camera lands on the cognition edge,
/// so an on-screen entity one level away still thinks; two levels off (32) drops to
/// locomotion, three (48) to kinematic, four+ to dormant. Lower it to keep more
/// depth layers in cognition (a px depth ÷ px-per-chunk in spirit, like the halos
/// above). Tunable to the world's level spacing and per-level perf budget.
pub const level_distance_chunks: u16 = 16;

comptime {
    std.debug.assert(cognition_halo_chunks <= locomotion_halo_chunks);
    std.debug.assert(locomotion_halo_chunks <= kinematic_halo_chunks);
}

/// Persistent capability tier for an entity.
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

/// Maps a chunk's distance from the visible region to its LOD tier. This is the
/// simulation-LOD ladder the halo policy applies every step: near entities think,
/// far entities sleep. `distance` is the chebyshev chunk distance (0 inside the
/// visible region); see `ActiveRegion.chunkDistance`.
pub fn tierForChunkDistance(distance: i32) SimulationTier {
    if (distance <= cognition_halo_chunks) return .cognition;
    if (distance <= locomotion_halo_chunks) return .locomotion;
    if (distance <= kinematic_halo_chunks) return .kinematic;
    return .dormant;
}

pub const ChunkCoord = struct {
    x: i32 = 0,
    y: i32 = 0,
};

/// Half-open chunk rectangle for a future fixed-step active scope.
/// The current slice validates and stores the shape without enabling filtering.
pub const ActiveRegion = struct {
    min: ChunkCoord,
    max_exclusive: ChunkCoord,
    /// Camera depth/level this region is anchored at. The cube LOD distance adds a
    /// per-level penalty against this; defaults 0 (the surface). Set by the pipeline
    /// from the camera/player level before the tier policy reads it.
    level: u16 = 0,

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

    /// Chebyshev (chunk-grid) distance from `chunk` to this half-open region:
    /// 0 when inside, otherwise the number of chunks to the nearest edge. Drives
    /// the simulation-LOD bands in `tierForChunkDistance`.
    pub fn chunkDistance(self: ActiveRegion, chunk: ChunkCoord) i32 {
        const dx = @max(@max(self.min.x - chunk.x, chunk.x - (self.max_exclusive.x - 1)), 0);
        const dy = @max(@max(self.min.y - chunk.y, chunk.y - (self.max_exclusive.y - 1)), 0);
        return @max(dx, dy);
    }

    /// Cube (L∞ ball) distance over (chunk_x, chunk_y, level): the chebyshev chunk
    /// distance, but never less than the per-level penalty for being off the region's
    /// level. So an entity on a far level reads as far regardless of its x/y, and an
    /// on-level entity reduces to the plain `chunkDistance`. Drives the LOD bands in
    /// `tierForChunkDistance` once the tier policy weighs depth.
    pub fn lodDistance(self: ActiveRegion, chunk: ChunkCoord, level: u16) i32 {
        const level_delta: i32 = @intCast(@abs(@as(i32, level) - @as(i32, self.level)));
        return @max(self.chunkDistance(chunk), level_delta * @as(i32, level_distance_chunks));
    }
};

/// Per-entity simulation metadata value type for get/set (`simulationMetadata`/
/// `setSimulationMetadata`). The hot storage is dense SoA columns on the
/// movement-body store; the hot path reads them directly via `scopeColumnsSlice`.
pub const EntitySimulationMetadata = struct {
    tier: SimulationTier = .cognition,
    chunk: ChunkCoord = .{},
    /// Depth/level this entity occupies. NPCs are all level 0 today, so this
    /// defaults to the surface; the tier policy weighs it through the cube LOD
    /// distance so a multi-level world demotes off-level entities correctly.
    level: u16 = 0,
    /// Which step within the stagger cycle this entity runs cognition. Assigned at
    /// movement-body append as dense_index % cognition_stagger_n: stable per entity,
    /// preserved by setSimulationTier, but not index-correlated after swap-remove
    /// churn. A full setSimulationMetadata write replaces it with the supplied value.
    stagger_phase: u8 = 0,
    /// When true, the cognition-halo tier policy never demotes this entity
    /// regardless of its distance from the camera. Use for bosses, scripted
    /// enemies, and any NPC that must keep thinking even when far off-screen.
    always_active: bool = false,

    pub fn validate(self: EntitySimulationMetadata) !void {
        _ = self;
    }
};

/// Per-step scope counters. Stage entity counts reflect scoped participation,
/// not the full live-entity set, so regressions in tier/stagger gating are visible.
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
    /// Cognition entities inside the halo that were skipped by stagger this step.
    stagger_skips: usize = 0,
    /// Entities excluded from cognition because their chunk is outside the halo.
    chunk_filtered_entities: usize = 0,

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

/// Transient fixed-step scope. active_region is the cognition halo (camera visible
/// chunks expanded by cognition_halo_chunks); null means no visibility data yet.
pub const SimulationScope = struct {
    active_region: ?ActiveRegion = null,
    stats: SimulationScopeStats = .{},
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

test "chunkDistance is chebyshev distance to the half-open region" {
    // Visible region covers chunks x:[0,4), y:[0,4) (max_exclusive 4 → last cell 3).
    const region = try ActiveRegion.init(.{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 });
    try std.testing.expectEqual(@as(i32, 0), region.chunkDistance(.{ .x = 2, .y = 2 })); // inside
    try std.testing.expectEqual(@as(i32, 0), region.chunkDistance(.{ .x = 3, .y = 3 })); // edge cell
    try std.testing.expectEqual(@as(i32, 1), region.chunkDistance(.{ .x = 4, .y = 3 })); // one past +x
    try std.testing.expectEqual(@as(i32, 2), region.chunkDistance(.{ .x = -2, .y = 1 })); // two before -x
    try std.testing.expectEqual(@as(i32, 6), region.chunkDistance(.{ .x = 9, .y = 2 })); // 9 - 3 = 6
    try std.testing.expectEqual(@as(i32, 5), region.chunkDistance(.{ .x = 8, .y = 7 })); // max(5,4)
}

test "lodDistance is a cube over chunk xy and level" {
    // Region covers chunks x:[0,4), y:[0,4) anchored at level 2.
    const region = ActiveRegion{ .min = .{ .x = 0, .y = 0 }, .max_exclusive = .{ .x = 4, .y = 4 }, .level = 2 };

    // Same level: reduces to plain chunkDistance.
    try std.testing.expectEqual(@as(i32, 0), region.lodDistance(.{ .x = 2, .y = 2 }, 2));
    try std.testing.expectEqual(@as(i32, 6), region.lodDistance(.{ .x = 9, .y = 2 }, 2));

    // One level away (either direction): at least one band, even when xy is inside.
    try std.testing.expectEqual(@as(i32, level_distance_chunks), region.lodDistance(.{ .x = 2, .y = 2 }, 1));
    try std.testing.expectEqual(@as(i32, level_distance_chunks), region.lodDistance(.{ .x = 2, .y = 2 }, 3));

    // Two levels away dominates a small xy distance; xy dominates when it is larger.
    try std.testing.expectEqual(@as(i32, 2 * level_distance_chunks), region.lodDistance(.{ .x = 5, .y = 2 }, 4));
    try std.testing.expectEqual(@as(i32, 100), region.lodDistance(.{ .x = 103, .y = 2 }, 3)); // xy 100 > one band 16
}

test "tierForChunkDistance walks the LOD ladder by band" {
    try std.testing.expectEqual(SimulationTier.cognition, tierForChunkDistance(0));
    try std.testing.expectEqual(SimulationTier.cognition, tierForChunkDistance(cognition_halo_chunks));
    try std.testing.expectEqual(SimulationTier.locomotion, tierForChunkDistance(cognition_halo_chunks + 1));
    try std.testing.expectEqual(SimulationTier.locomotion, tierForChunkDistance(locomotion_halo_chunks));
    try std.testing.expectEqual(SimulationTier.kinematic, tierForChunkDistance(locomotion_halo_chunks + 1));
    try std.testing.expectEqual(SimulationTier.kinematic, tierForChunkDistance(kinematic_halo_chunks));
    try std.testing.expectEqual(SimulationTier.dormant, tierForChunkDistance(kinematic_halo_chunks + 1));
    try std.testing.expectEqual(SimulationTier.dormant, tierForChunkDistance(1000));
}

test "stagger phase rotates across all entities over cognition_stagger_n steps" {
    // Simulate 4 entities with stagger_phase 0–3 across 4 steps.
    // Each step should include exactly 1 entity; all 4 are covered across the cycle.
    const phases = [cognition_stagger_n]u8{ 0, 1, 2, 3 };
    var covered = [cognition_stagger_n]bool{ false, false, false, false };

    for (0..cognition_stagger_n) |step| {
        const stagger_step: u8 = @intCast(step % cognition_stagger_n);
        var included: usize = 0;
        for (phases) |phase| {
            if (phase == stagger_step) {
                included += 1;
                covered[phase] = true;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), included);
    }

    for (covered) |c| try std.testing.expect(c);
}
