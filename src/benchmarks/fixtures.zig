// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Fixture builders shared by the bench groups: a case's thread system, bodies, request
//! streams, the world tileset and banded worlds, a 4-connected flood, and the nav reaction's
//! tuner setup.

const std = @import("std");
const math = @import("../core/math.zig");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const ThreadSystemConfig = @import("../app/thread_system.zig").ThreadSystemConfig;
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const AssetStore = @import("../assets/assets.zig").AssetStore;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const CollisionResponseMobility = @import("../game/data_system.zig").CollisionResponseMobility;
const PathRequest = @import("../game/simulation.zig").PathRequest;
const RangeOutputStream = @import("../game/simulation.zig").RangeOutputStream;
const WorldSystem = @import("../game/world/system.zig").WorldSystem;
const level_z_step = @import("../game/world/system.zig").level_z_step;
const default_chunk_size_tiles = @import("../game/world/system.zig").default_chunk_size_tiles;
const PathfindingSystem = @import("../game/systems/pathfinding.zig").PathfindingSystem;
const evict_range_alignment_items = @import("../game/systems/pathfinding/types.zig").evict_range_alignment_items;
const nav_mark_range_alignment_items = @import("../game/systems/pathfinding/nav_reaction.zig").nav_mark_range_alignment_items;
const suite = @import("suite.zig");

/// The case's thread system, or null for the serial case.
pub fn initCaseThreads(allocator: std.mem.Allocator, io: std.Io, case: suite.BenchmarkCase) !?ThreadSystem {
    if (!case.usesThreadSystem()) return null;
    return try initRequiredCaseThreads(allocator, io, case);
}

/// The case's thread system for a stage that requires one: the engine's default config at
/// the case's worker count, with no workers for the serial case.
pub fn initRequiredCaseThreads(allocator: std.mem.Allocator, io: std.Io, case: suite.BenchmarkCase) !ThreadSystem {
    var config = ThreadSystemConfig{};
    config.max_worker_threads = case.maxWorkerThreads();
    return ThreadSystem.init(allocator, io, config);
}

/// Threaded participant slots of `thread_system` (workers + main), or 1 without one.
pub fn participantCount(thread_system: ?*const ThreadSystem) usize {
    const threads = thread_system orelse return 1;
    return threads.participantSlotCount();
}

/// A collision body: movement body at `position`, `size` bounds, and `mobility`.
pub fn addBody(data: *DataSystem, position: math.Vec2, size: math.Vec2, mobility: CollisionResponseMobility) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = position, .previous_position = position });
    try data.setCollisionBounds(entity, .{ .size = size });
    try data.setCollisionResponse(entity, .{ .mobility = mobility });
    return entity;
}

/// Writes `requests` as one range, replacing the stream's contents.
pub fn writeRequests(stream: *RangeOutputStream(PathRequest), requests: []const PathRequest) !void {
    stream.clearRetainingCapacity();
    if (requests.len == 0) return;
    const range_base = try stream.appendRangeCounts(1);
    stream.addCount(range_base, requests.len);
    try stream.prefixAppendedRanges(range_base);
    var writer = stream.rangeWriter(range_base);
    for (requests) |request| writer.write(request);
    writer.finish();
    stream.finishWrite();
}

/// The world tileset's metadata; the caller deinits it.
pub fn loadTilesetMeta(allocator: std.mem.Allocator, io: std.Io) !world_tileset_meta.WorldTilesetMeta {
    const asset_store = AssetStore.init(allocator, io, "assets");
    return world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
}

/// The bench world fixture: `levels` square levels of `side`² tiles in default chunks,
/// each one uniform dense floor band (level `i` owns layer `i`), the tile named `surface`
/// on level 0 and `below` under it. The world owns its tileset metadata
/// (`tilesetMeta()`) for further tile lookups.
pub fn buildBandedWorld(allocator: std.mem.Allocator, io: std.Io, side: u16, levels: u16, surface: []const u8, below: []const u8) !WorldSystem {
    var meta = try loadTilesetMeta(allocator, io);
    var meta_owned = true;
    defer if (meta_owned) meta.deinit();
    var world = WorldSystem{
        .allocator = allocator,
        .width = side,
        .height = side,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = default_chunk_size_tiles,
    };
    errdefer world.deinit();
    try world.buildCatalog(&meta);
    const surface_tile = try world.requireTileByName(&meta, surface);
    const below_tile = try world.requireTileByName(&meta, below);
    for (0..levels) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        const layer = try world.addDenseLayer(level, 0, .floor, if (level_index == 0) surface_tile else below_tile);
        std.debug.assert(layer == level);
    }
    world.adoptTilesetMeta(meta);
    meta_owned = false;
    return world;
}

/// The cells a `flood4` reached, and whether it stopped at a cell its context stops on.
pub const Flood = struct {
    reached: usize,
    stopped: bool,
};

/// Breadth-first 4-connected flood over a `width` x `height` grid from the open cell `seed`,
/// through cells `context.open(x, y)` admits, marking each in `reached` (row-major, sized to
/// the grid). Stops at the first reached cell `context.stop(x, y)` holds for. O(cells reached).
pub fn flood4(allocator: std.mem.Allocator, width: u32, height: u32, seed: [2]u32, context: anytype, reached: *std.DynamicBitSetUnmanaged) !Flood {
    std.debug.assert(reached.bit_length == @as(usize, width) * height);
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(allocator);
    reached.set(@as(usize, seed[1]) * width + seed[0]);
    try queue.append(allocator, seed[1] * width + seed[0]);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cell = queue.items[head];
        const x = cell % width;
        const y = cell / width;
        const neighbours = [_]?[2]u32{
            if (x > 0) .{ x - 1, y } else null,
            if (x + 1 < width) .{ x + 1, y } else null,
            if (y > 0) .{ x, y - 1 } else null,
            if (y + 1 < height) .{ x, y + 1 } else null,
        };
        for (neighbours) |maybe_neighbour| {
            const next = maybe_neighbour orelse continue;
            const index = next[1] * width + next[0];
            if (reached.isSet(index) or !context.open(next[0], next[1])) continue;
            if (context.stop(next[0], next[1])) return .{ .reached = queue.items.len, .stopped = true };
            reached.set(index);
            try queue.append(allocator, index);
        }
    }
    return .{ .reached = queue.items.len, .stopped = false };
}

/// Gives every nav reaction stage (the batch stages, connectivity and closure included, the
/// mark stage, and the eviction stages) a fresh tuner for `case` and its control config. The
/// stages share one control, so every stage's fixed range modes and fixed-adaptive range
/// scale from one item per range, aligned per stage: a chunk for the chunk stages, an event
/// for the mark stage, a registry entry or pair for the eviction stages. Call after the nav
/// build, which resets tuners.
pub fn setNavTuners(system: *PathfindingSystem, case: suite.BenchmarkCase) void {
    const partition_items = suite.chunk_partition_items;
    const fresh = AdaptiveWorkTuner.init(.{});
    system.tuners.nav = .initFill(suite.adaptiveTunerForPartition(case, partition_items, 1) orelse fresh);
    system.tuners.nav_mark = suite.adaptiveTunerForPartition(case, partition_items, nav_mark_range_alignment_items) orelse fresh;
    system.tuners.nav_evict_count = suite.adaptiveTunerForPartition(case, partition_items, evict_range_alignment_items) orelse fresh;
    system.tuners.nav_evict = suite.adaptiveTunerForPartition(case, partition_items, evict_range_alignment_items) orelse fresh;
    system.tuners.evict_flush = suite.adaptiveTunerForPartition(case, partition_items, 1) orelse fresh;
    system.nav_controls = .{
        .adaptive = case.adaptive,
        .max_worker_threads = case.maxWorkerThreads(),
        .items_per_range = case.stageItemsPerRangeForPartition(partition_items, 1),
    };
}

/// A pathfinding system's stage tuners. A sample that runs a change and then its revert
/// runs the revert on its own set (`swapNavTuners` around it, untimed), so each set learns
/// one workload with one sample per step, as production's one reaction per step does.
pub const NavTuners = @FieldType(PathfindingSystem, "tuners");

/// Swaps `system`'s stage tuners with `other`.
pub fn swapNavTuners(system: *PathfindingSystem, other: *NavTuners) void {
    std.mem.swap(NavTuners, &system.tuners, other);
}

/// The connectivity flood tuner's workers after a case that runs it adaptive on workers
/// (zero: it chose inline); null for any other case.
pub fn floodTunerWorkers(system: *const PathfindingSystem, case: suite.BenchmarkCase) ?usize {
    return floodTunerWorkersOf(&system.tuners, case);
}

/// `floodTunerWorkers` for the flood tuner of the stage tuner set `tuners`.
pub fn floodTunerWorkersOf(tuners: *const NavTuners, case: suite.BenchmarkCase) ?usize {
    if (!case.adaptive or !case.usesThreadSystem()) return null;
    const tuner = tuners.nav.getPtrConst(.conn_flood).report();
    return if (tuner.has_threaded_profile) tuner.current_profile.worker_threads else 0;
}
