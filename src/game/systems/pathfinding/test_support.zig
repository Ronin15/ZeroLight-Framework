// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared private test fixtures for the pathfinding package. These are test-only
//! helpers (no production contract exposes them); each test-bearing module imports
//! what it needs. Single-module helpers are co-located in their module instead.

const std = @import("std");
const math = @import("../../../core/math.zig");
const DataSystem = @import("../../data_system.zig").DataSystem;
const EntityId = @import("../../data_system.zig").EntityId;
const RangeOutputStream = @import("../../simulation.zig").RangeOutputStream;
const PathRequest = @import("../../simulation.zig").PathRequest;
const PathfindingCapacity = @import("types.zig").PathfindingCapacity;
const assets = @import("../../../assets/assets.zig");
const manifest = @import("../../../assets/manifest.zig");
const world_tileset_meta = @import("../../../assets/world_tileset_meta.zig");
const WorldTilesetMeta = world_tileset_meta.WorldTilesetMeta;
const TileId = @import("../../world_system.zig").TileId;

pub fn addNavBody(data: *DataSystem, position: math.Vec2, size: math.Vec2, static: bool) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = position, .previous_position = position });
    try data.setCollisionBounds(entity, .{ .size = size });
    try data.setCollisionResponse(entity, .{ .mobility = if (static) .static else .dynamic });
    return entity;
}

pub fn appendPathRequest(stream: *RangeOutputStream(PathRequest), request: PathRequest) !void {
    const range_base = try stream.appendRangeCounts(1);
    stream.addCount(range_base, 1);
    try stream.prefixAppendedRanges(range_base);
    var writer = stream.rangeWriter(range_base);
    writer.write(request);
    writer.finish();
    stream.finishWrite();
}

pub fn baselineCapacity() PathfindingCapacity {
    // Per-step request/cache caps are derived elastically from the agent count
    // (floored at min_capacity_floor = 8), so only the non-derived knobs are set
    // here. An explicit min_group_field_agents pins the group-field threshold so
    // these tests exercise the field mechanics with a handful of agents, bypassing
    // the grid-derived threshold (which would otherwise require hundreds of sharers).
    return .{
        .max_group_fields = 2,
        .worker_participant_count = 1,
        .min_group_field_agents = 1,
    };
}

// Loads the world tileset metadata used by the demo. Cross-level/abstract tests
// build real `WorldSystem` worlds from it (no test-only production hooks).
pub fn loadTestWorldMeta(allocator: std.mem.Allocator) !WorldTilesetMeta {
    const asset_store = assets.AssetStore.init(allocator, std.testing.io, "assets");
    return world_tileset_meta.load(
        allocator,
        asset_store,
        manifest.spriteSpec(.world_tileset).metadata_path.?,
    );
}

pub fn requireTestTile(meta: *const WorldTilesetMeta, name: []const u8) !TileId {
    return (meta.tileByName(name) orelse return error.UnknownTestTile).id;
}

// Capacity tuned for the abstract tier: small chunks so a modest world spans
// several chunks (real portals), plus headroom for cross-level corridor storage.
pub fn abstractCapacity() PathfindingCapacity {
    return .{
        .max_frame_requests = 8,
        .max_pending_requests = 8,
        .max_cached_results = 16,
        .max_group_fields = 2,
        .worker_participant_count = 1,
        .max_solved_requests_per_step = 8,
        .max_fallback_requests_per_step = 8,
        .nav_chunk_tiles = 4,
        .max_stitched_path_cells = 256,
        .min_group_field_agents = 1,
    };
}
