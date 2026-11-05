// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-owned simulation tier and active-scope contracts.
//! Bands from the observer's fixed-step view set think cadence and collision fidelity.
//! `dormant` is inert rows only; agents are never assigned it.

const std = @import("std");
const runtime_perf_log = @import("../app/runtime_perf_log.zig");

/// Steps between cognition-stage runs for a single entity. AI and steering run
/// once every cognition_stagger_n fixed steps per entity, rotating by stagger_phase.
pub const cognition_stagger_n: u8 = 4;

/// `EntitySimulationMetadata.stagger_phase` sentinel: a metadata write keeps the row's phase.
pub const keep_stagger_phase: u8 = std.math.maxInt(u8);

comptime {
    std.debug.assert(cognition_stagger_n <= keep_stagger_phase);
}

/// Simulation LOD bands as chunk distance from the observer's fixed-step view.
/// An entity's tier is the band its chunk falls into. The bands must be
/// monotonically increasing. Past the kinematic halo the band is `lowest`.
///
/// Sized in chunks (1 chunk = chunk_size_tiles × tile_size px; e.g. 8×32 = 256 px).
/// These are radii BEYOND the visible region, so cognition must clear a full screen
/// of margin or entities pop-think as they scroll in: a 4K width (3840 px) is ~15
/// chunks, so cognition ≥ 16 keeps a screen-wide thinking halo. Defaults give
/// roughly one screen of cognition margin, then a screen each of locomotion and
/// kinematic before the lowest band. Tune to your world/camera scale and perf budget.
pub const cognition_halo_chunks: u16 = 16;
pub const locomotion_halo_chunks: u16 = 32;
pub const kinematic_halo_chunks: u16 = 48;

/// Chunk-distance weight of one depth/level step in the cube LOD ball over
/// (chunk_x, chunk_y, level); applied via `lodDistance`. At the default 16
/// (= cognition_halo_chunks) one level off the camera lands on the cognition edge,
/// so an on-screen entity one level away still thinks; two levels off (32) drops to
/// locomotion, three (48) to kinematic, four+ to the lowest band. Lower it to keep more
/// depth layers in cognition (a px depth ÷ px-per-chunk in spirit, like the halos
/// above). Tunable to the world's level spacing and per-level perf budget.
pub const level_distance_chunks: u16 = 16;

comptime {
    std.debug.assert(cognition_halo_chunks <= locomotion_halo_chunks);
    std.debug.assert(locomotion_halo_chunks <= kinematic_halo_chunks);
}

/// Residue modulus. Every think cadence divides it.
pub const band_residue_n: u8 = 64;
pub const locomotion_think_cadence: u8 = 16;
pub const kinematic_think_cadence: u8 = 32;
pub const lowest_think_cadence: u8 = 64;

/// Persistent capability tier for an entity. `lowest` is the far band.
/// `dormant` is inert rows only.
pub const SimulationTier = enum(u3) {
    dormant,
    kinematic,
    locomotion,
    cognition,
    lowest = 4,

    pub fn allowsMovement(self: SimulationTier) bool {
        return self != .dormant;
    }

    pub fn allowsCollision(self: SimulationTier) bool {
        return switch (self) {
            .locomotion, .cognition => true,
            .dormant, .kinematic, .lowest => false,
        };
    }

    pub fn allowsCognition(self: SimulationTier) bool {
        return self != .dormant;
    }
};

/// Steps between thinks for `tier`. `dormant` does not think.
pub fn thinkCadence(tier: SimulationTier) u8 {
    return switch (tier) {
        .cognition => cognition_stagger_n,
        .locomotion => locomotion_think_cadence,
        .kinematic => kinematic_think_cadence,
        .lowest => lowest_think_cadence,
        .dormant => 0,
    };
}

/// `always_active` thinks every step. Otherwise `step % cadence == phase % cadence`.
pub fn thinksThisStep(tier: SimulationTier, always_active: bool, phase: u8, step: u32) bool {
    if (always_active) return true;
    const cadence: u32 = thinkCadence(tier);
    if (cadence == 0) return false;
    return step % cadence == @as(u32, phase) % cadence;
}

/// One always-active group, then each tier's residues.
pub const think_group_count: usize = 1 + std.meta.tags(SimulationTier).len * @as(usize, band_residue_n);

comptime {
    std.debug.assert(band_residue_n <= keep_stagger_phase);
    std.debug.assert(band_residue_n % cognition_stagger_n == 0);
    std.debug.assert(band_residue_n % locomotion_think_cadence == 0);
    std.debug.assert(band_residue_n % kinematic_think_cadence == 0);
    std.debug.assert(band_residue_n % lowest_think_cadence == 0);
    std.debug.assert(think_group_count == 321);
}

/// Maps a chunk's distance from the visible region to its LOD band.
/// `distance` is the chebyshev chunk distance (0 inside the region). Past the
/// kinematic halo the band is `lowest`.
pub fn tierForChunkDistance(distance: i32) SimulationTier {
    if (distance <= cognition_halo_chunks) return .cognition;
    if (distance <= locomotion_halo_chunks) return .locomotion;
    if (distance <= kinematic_halo_chunks) return .kinematic;
    return .lowest;
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

/// Per-entity simulation metadata value type (`setSimulationMetadata`). The hot storage is
/// dense SoA columns on the movement-body store; the hot path reads them directly via
/// `scopeColumnsSlice`.
pub const EntitySimulationMetadata = struct {
    tier: SimulationTier = .cognition,
    chunk: ChunkCoord = .{},
    /// Depth/level this entity occupies; the tier policy weighs it through the cube LOD
    /// distance so a multi-level world demotes off-level entities correctly. A
    /// setSimulationMetadata write takes it from the entity's `world_level` row when it has
    /// one (a supplied level must match), else keeps the row's level at `null` (the default)
    /// and writes any other value; a read returns the row's level.
    level: ?u16 = null,
    /// Residue within `band_residue_n`. The first AI arrival in a `(level, cell)` takes that
    /// level's next origin and later arrivals take the cell's next residue. The append
    /// stripe `dense_index % cognition_stagger_n` is only the unsettled placeholder.
    /// `keep_stagger_phase` and `setSimulationTier` keep the stored phase; `removeAt`
    /// does not reassign. A setSimulationMetadata write keeps the row's phase at
    /// `keep_stagger_phase` (the default) and writes any other value; a read returns
    /// the row's phase.
    stagger_phase: u8 = keep_stagger_phase,
    /// When true, the cognition-halo tier policy never demotes this entity
    /// regardless of its distance from the camera. Use for bosses, scripted
    /// enemies, and any NPC that must keep thinking even when far off-screen.
    always_active: bool = false,

    pub fn validate(self: EntitySimulationMetadata) error{InvalidStaggerPhase}!void {
        if (self.stagger_phase != keep_stagger_phase and self.stagger_phase >= band_residue_n) return error.InvalidStaggerPhase;
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
    lowest_entities: usize = 0,
    movement_stage_entities: usize = 0,
    collision_stage_entities: usize = 0,
    collision_response_stage_entities: usize = 0,
    ai_stage_entities: usize = 0,
    steering_stage_entities: usize = 0,
    perf: Perf = .{},

    /// Kept only with `runtime_perf_log.enabled`. `stagger_skips` is the not-due
    /// run length this step (a bodiless row counts). `chunk_filtered_entities`
    /// stays 0: the index is the whole AI population.
    pub const Perf = if (runtime_perf_log.enabled) struct {
        stagger_skips: usize = 0,
        chunk_filtered_entities: usize = 0,
    } else struct {};
};

/// Transient fixed-step scope. `active_region` is the fixed-step view's chunk
/// region. Null assigns `lowest`; cadence still applies.
pub const SimulationScope = struct {
    active_region: ?ActiveRegion = null,
    stats: SimulationScopeStats = .{},
};

test "simulation tier capabilities are monotonic" {
    try std.testing.expect(!SimulationTier.dormant.allowsMovement());
    try std.testing.expect(!SimulationTier.dormant.allowsCollision());
    try std.testing.expect(!SimulationTier.dormant.allowsCognition());
    try std.testing.expect(SimulationTier.kinematic.allowsMovement());
    try std.testing.expect(!SimulationTier.kinematic.allowsCollision());
    try std.testing.expect(SimulationTier.kinematic.allowsCognition());
    try std.testing.expect(SimulationTier.locomotion.allowsCollision());
    try std.testing.expect(SimulationTier.locomotion.allowsCognition());
    try std.testing.expect(SimulationTier.cognition.allowsCognition());
    try std.testing.expect(SimulationTier.lowest.allowsMovement());
    try std.testing.expect(!SimulationTier.lowest.allowsCollision());
    try std.testing.expect(SimulationTier.lowest.allowsCognition());
    try std.testing.expect(thinksThisStep(.cognition, false, 4, 0));
    try std.testing.expect(!thinksThisStep(.locomotion, false, 4, 5));
    try std.testing.expect(thinksThisStep(.lowest, true, 3, 1));
    try std.testing.expect(!thinksThisStep(.dormant, false, 0, 0));
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
    try std.testing.expectEqual(SimulationTier.lowest, tierForChunkDistance(kinematic_halo_chunks + 1));
    try std.testing.expectEqual(SimulationTier.lowest, tierForChunkDistance(1000));
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
