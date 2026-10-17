// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared private test fixtures for the shared neighbor index's consumers. Test-only: no
//! production path imports it.

const std = @import("std");
const DataSystem = @import("../data_system.zig").DataSystem;
const IndexGeometry = @import("spatial_index.zig").IndexGeometry;
const SpatialIndexSystem = @import("spatial_index.zig").SpatialIndexSystem;
const IndexPopulation = @import("spatial_index.zig").IndexPopulation;
const SpatialIndexConfig = @import("spatial_index.zig").SpatialIndexConfig;
const SpatialIndexStats = @import("spatial_index.zig").SpatialIndexStats;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const default_chunk_size_tiles = @import("../world/system.zig").default_chunk_size_tiles;

/// The consumers' test grid: 64 x 64 default chunks of 32-unit tiles from the origin, one
/// level (the index grows a directory for any level a body is on). Bodies outside it clamp
/// to its edge cells.
pub const test_index_geometry = IndexGeometry{
    .tile_size = 32,
    .chunk_size_tiles = default_chunk_size_tiles,
    .chunks_x = 64,
    .chunks_y = 64,
    .level_count = 1,
};

/// The inline-built index of every AI agent of `data`, on `std.testing.allocator`. The caller
/// owns the returned system and passes its `.view()` to the consumer under test.
pub fn testSpatialIndex(data: *const DataSystem) !SpatialIndexSystem {
    return testHaloIndex(data, null);
}

/// `testSpatialIndex` over the agents at `halo` (dense AI indices) only.
pub fn testHaloIndex(data: *const DataSystem, halo: ?[]const u32) !SpatialIndexSystem {
    var system = SpatialIndexSystem.init(std.testing.allocator);
    errdefer system.deinit();
    _ = try buildInline(&system, data, .{ .entities = data.aiAgentSliceConst().entities, .rows = halo }, test_index_geometry, .{});
    return system;
}

/// `SpatialIndexSystem.build` inline as one range: a thread system with no workers.
pub fn buildInline(system: *SpatialIndexSystem, data: *const DataSystem, population: IndexPopulation, geometry: IndexGeometry, config: SpatialIndexConfig) !SpatialIndexStats {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0, .items_per_range = std.math.maxInt(u32) });
    defer threads.deinit();
    return system.build(data, population, geometry, &threads, config);
}
