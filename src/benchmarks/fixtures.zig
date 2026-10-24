// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Fixture builders shared by the bench groups: a case's thread system, bodies, one-range
//! stream writes, the production commit seam on a pipeline and a static moved through it,
//! the world tileset and banded worlds, a 4-connected flood, a coprime-stride shuffle, the nav
//! reaction's and the static colliders' tuner setup, the settle censuses of a nav stage tuner
//! set and of the commit seam with the seam's stage batches and worker time, and the render
//! benches' texture table and phase timers.

const std = @import("std");
const math = @import("../core/math.zig");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const ThreadSystemConfig = @import("../app/thread_system.zig").ThreadSystemConfig;
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const rebuild_tuner_config = @import("../app/thread_system.zig").rebuild_tuner_config;
const AssetStore = @import("../assets/assets.zig").AssetStore;
const Color = @import("../config.zig").Color;
const resources = @import("../render/resources.zig");
const sprite_batch = @import("../render/sprite_batch.zig");
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const IndexGeometry = @import("../game/systems/spatial_index.zig").IndexGeometry;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const CollisionResponseMobility = @import("../game/data_system.zig").CollisionResponseMobility;
const StructuralCommand = @import("../game/data_system.zig").StructuralCommand;
const structuralEventHeadroom = @import("../game/simulation.zig").structuralEventHeadroom;
const PathRequest = @import("../game/simulation.zig").PathRequest;
const RangeOutputStream = @import("../game/simulation.zig").RangeOutputStream;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const StaticColliderSystem = @import("../game/systems/static_colliders.zig").StaticColliderSystem;
const RebuildStage = @import("../game/systems/static_colliders.zig").RebuildStage;
const SyncStage = @import("../game/systems/static_colliders.zig").SyncStage;
const static_colliders_test_support = @import("../game/systems/static_colliders_test_support.zig");
const NavUpdateStats = @import("../game/systems/pathfinding/types.zig").NavUpdateStats;
const splice_range_alignment_items = @import("../game/systems/chunk_list_map.zig").splice_range_alignment_items;
const WorldSystem = @import("../game/world/system.zig").WorldSystem;
const level_z_step = @import("../game/world/system.zig").level_z_step;
const default_chunk_size_tiles = @import("../game/world/system.zig").default_chunk_size_tiles;
const PathfindingSystem = @import("../game/systems/pathfinding.zig").PathfindingSystem;
const PathfindingCapacity = @import("../game/systems/pathfinding.zig").PathfindingCapacity;
const NavStage = @import("../game/systems/pathfinding/nav_graph.zig").NavStage;
const SimulationPipeline = @import("../game/simulation_pipeline.zig").SimulationPipeline;
const CollisionStats = @import("../game/systems/collision.zig").CollisionStats;
const CollisionSystem = @import("../game/systems/collision.zig").CollisionSystem;
const CollisionStrips = @import("../game/systems/collision.zig").CollisionStrips;
const collision_range_alignment_items = @import("../game/systems/collision.zig").collision_range_alignment_items;
const CommitSeamResult = @import("../game/simulation_pipeline.zig").CommitSeamResult;
const suite = @import("suite.zig");

/// The case's thread system, or null for the serial case.
pub fn initCaseThreads(allocator: std.mem.Allocator, io: std.Io, case: suite.BenchmarkCase) !?ThreadSystem {
    if (!case.usesThreadSystem()) return null;
    return try initRequiredCaseThreads(allocator, io, case);
}

/// The case's thread system for a stage that requires one: the engine's default config at
/// the case's worker count. The serial case has no workers, so every stage runs as one
/// inline range, the shape production takes on a machine with no spare core.
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

/// A bench's production commit seam: a `SimulationPipeline` over a bench's data with nav over
/// its world, built on the build threads as a gameplay state builds it (so its stored trigger
/// pairs build at init), and the frame its steps run in, reserved as a gameplay state
/// reserves it (`SimulationPipeline.reserveFrame`). Data and world stay the caller's; pass
/// the same ones to every call.
pub const PipelineSeam = struct {
    pipeline: SimulationPipeline,
    frame: SimulationFrame,

    pub const Config = struct {
        /// The caller's part of a commit's `.structural_commit` event share
        /// (`structuralEventHeadroom` of the commands it queues a step).
        structural_headroom: usize,
        pathfinding: PathfindingCapacity = .{},
        /// The world-create builds' threads (`SimulationPipelineConfig.build_thread_system`).
        build_thread_system: *ThreadSystem,
    };

    pub fn init(allocator: std.mem.Allocator, data: *const DataSystem, world: *const WorldSystem, config: Config) !PipelineSeam {
        var pipeline = try SimulationPipeline.init(allocator, data, world.worldWidthPixels(), world.worldHeightPixels(), .{
            .navigation_world = world,
            .build_thread_system = config.build_thread_system,
            .structural_headroom = config.structural_headroom,
            .pathfinding = config.pathfinding,
        });
        errdefer pipeline.deinit();
        var frame = SimulationFrame.init(allocator);
        errdefer frame.deinit();
        try pipeline.reserveFrame(&frame);
        return .{ .pipeline = pipeline, .frame = frame };
    }

    pub fn deinit(self: *PipelineSeam) void {
        self.frame.deinit();
        self.pipeline.deinit();
        self.* = undefined;
    }

    /// Gives the colliders' sync and rebuild stages and every nav reaction stage fresh tuners
    /// and controls for `case` (`setSpliceTuners`, `setNavTuners`).
    pub fn setCaseTuners(self: *PipelineSeam, case: suite.BenchmarkCase) void {
        setSpliceTuners(&self.pipeline.static_colliders, case);
        setNavTuners(&self.pipeline.pathfinding, case);
    }

    /// One structural commit in the frame's current step: `commands` written as one range of
    /// its structural commands, then `SimulationPipeline.commitStructuralAndReact` on
    /// `thread_system`. The step's changes stay in the frame for the caller.
    pub fn commit(self: *PipelineSeam, data: *DataSystem, world: *const WorldSystem, commands: []const StructuralCommand, thread_system: *ThreadSystem) !CommitSeamResult {
        try writeOneRange(StructuralCommand, &self.frame.structural_commands, commands);
        return self.pipeline.commitStructuralAndReact(&self.frame, data, world, thread_system);
    }

    /// One collision step on the pipeline at production's inputs (`world`'s strips, the
    /// colliders' view) and `case`'s controls, emitting into the frame's contacts.
    pub fn collisionStep(self: *PipelineSeam, data: *const DataSystem, world: *const WorldSystem, thread_system: *ThreadSystem, case: suite.BenchmarkCase) !CollisionStats {
        return self.pipeline.collision.update(data, &self.frame.contacts, thread_system, .{
            .items_per_range = case.stageItemsPerRange(collision_range_alignment_items),
            .max_worker_threads = case.maxWorkerThreads(),
            .adaptive = case.adaptive,
            .strips = CollisionStrips.ofWorld(world),
            .static_colliders = self.pipeline.static_colliders.view(),
        });
    }
};

/// Replaces `stream`'s contents with one range of `count` items and returns its writer; the
/// caller writes exactly `count` items, then calls the writer's `finish` and the stream's
/// `finishWrite`.
pub fn beginOneRange(comptime T: type, stream: *RangeOutputStream(T), count: usize) !RangeOutputStream(T).RangeWriter {
    try stream.prepareRangeCounts(1);
    stream.addCount(0, count);
    try stream.prefix();
    return stream.rangeWriter(0);
}

/// Replaces `stream`'s contents with `items` as one range.
pub fn writeOneRange(comptime T: type, stream: *RangeOutputStream(T), items: []const T) !void {
    var writer = try beginOneRange(T, stream, items.len);
    for (items) |item| writer.write(item);
    writer.finish();
    stream.finishWrite();
}

/// Writes `requests` as one range, replacing the stream's contents; no range when empty.
pub fn writeRequests(stream: *RangeOutputStream(PathRequest), requests: []const PathRequest) !void {
    if (requests.len == 0) return stream.clearRetainingCapacity();
    try writeOneRange(PathRequest, stream, requests);
}

/// One static body moved back and forth between two positions, one structural command per
/// step: the next move's `set_movement_body`, then `advance` once it committed.
pub const StaticMove = struct {
    /// The commit seam's share for the move's one command a step.
    pub const structural_headroom = structuralEventHeadroom(0, 1);

    entity: EntityId,
    // The body starts at the first.
    positions: [2]math.Vec2,
    at_second: bool = false,

    pub fn command(self: *const StaticMove) StructuralCommand {
        const target = if (self.at_second) self.positions[0] else self.positions[1];
        return .{ .set_movement_body = .{ .entity = self.entity, .body = .{ .position = target, .previous_position = target } } };
    }

    pub fn advance(self: *StaticMove) void {
        self.at_second = !self.at_second;
    }
};

/// Gives each of the static colliders' sync and rebuild stages a fresh tuner (a tuned case's
/// rebuild tuners in production's rebuild config), and every stage the range controls for
/// `case`.
pub fn setSpliceTuners(colliders: *StaticColliderSystem, case: suite.BenchmarkCase) void {
    for (std.enums.values(SyncStage)) |stage| {
        colliders.tuners.set(stage, AdaptiveWorkTuner.init(.{}));
    }
    for (std.enums.values(RebuildStage)) |stage| {
        colliders.rebuild_tuners.set(stage, AdaptiveWorkTuner.init(rebuild_tuner_config));
    }
    colliders.splice_controls = .{ .adaptive = case.adaptive, .max_worker_threads = case.maxWorkerThreads(), .items_per_range = case.stageItemsPerRange(splice_range_alignment_items) };
}

/// The world tileset's metadata; the caller deinits it.
pub fn loadTilesetMeta(allocator: std.mem.Allocator, io: std.Io) !world_tileset_meta.WorldTilesetMeta {
    const asset_store = AssetStore.init(allocator, io, "assets");
    return world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
}

/// The bench world fixture: `levels` square levels of `side`² tiles in default chunks,
/// each one uniform dense floor band (level `i` owns layer `i`), the tile named `surface`
/// on level 0 and `below` under it. Reads `meta` only while it builds.
pub fn buildBandedWorld(allocator: std.mem.Allocator, meta: *const world_tileset_meta.WorldTilesetMeta, side: u16, levels: u16, surface: []const u8, below: []const u8) !WorldSystem {
    return buildBandedWorldSized(allocator, meta, side, side, levels, surface, below);
}

/// `buildBandedWorld` with levels of `width` x `height` tiles.
pub fn buildBandedWorldSized(allocator: std.mem.Allocator, meta: *const world_tileset_meta.WorldTilesetMeta, width: u16, height: u16, levels: u16, surface: []const u8, below: []const u8) !WorldSystem {
    var world = WorldSystem{
        .allocator = allocator,
        .width = width,
        .height = height,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = default_chunk_size_tiles,
    };
    errdefer world.deinit();
    try world.buildCatalog(meta);
    const surface_tile = try world.requireTileByName(meta, surface);
    const below_tile = try world.requireTileByName(meta, below);
    for (0..levels) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        const layer = try world.addDenseLayer(level, 0, .floor, if (level_index == 0) surface_tile else below_tile);
        std.debug.assert(layer == level);
    }
    return world;
}

/// The index grid of a default-chunk world covering `[0, width) x [0, height)` on `levels`
/// levels, for a bench with no `WorldSystem`.
pub fn indexGeometryCovering(width: f32, height: f32, levels: usize) IndexGeometry {
    const chunk_world = world_tileset_meta.required_tile_size * @as(f32, @floatFromInt(default_chunk_size_tiles));
    return .{
        .tile_size = world_tileset_meta.required_tile_size,
        .chunk_size_tiles = default_chunk_size_tiles,
        .chunks_x = @max(1, @as(u32, @intFromFloat(@ceil(width / chunk_world)))),
        .chunks_y = @max(1, @as(u32, @intFromFloat(@ceil(height / chunk_world)))),
        .level_count = levels,
    };
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
/// stages share one control, so every stage's fixed range modes scale from one item per
/// range, aligned per stage: a chunk for the chunk stages, an event
/// for the mark stage, a registry entry or pair for the eviction stages. Call after the nav
/// build, which resets tuners.
pub fn setNavTuners(system: *PathfindingSystem, case: suite.BenchmarkCase) void {
    const partition_items = suite.chunk_partition_items;
    const fresh = AdaptiveWorkTuner.init(.{});
    system.tuners.nav = .initFill(fresh);
    system.tuners.nav_mark = fresh;
    system.tuners.nav_evict_count = fresh;
    system.tuners.nav_evict = fresh;
    system.tuners.evict_flush = fresh;
    system.tuners.evict_flush_count = fresh;
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

/// Adds every tuner of the stage tuner set `tuners` to `census` under `prefix`, the nav
/// stages by name: each field is a tuner or the nav stage set, so none is missed. A tuner the
/// measured step never selects stays unused (`TunerSettle`), so the caller's setup selects
/// none the step does not run (`setNavTuners` refreshes the reaction's after the build).
pub fn addNavTuners(census: *suite.TunerSettle, comptime prefix: []const u8, tuners: *const NavTuners) void {
    addNavTunersExcept(census, prefix, tuners, &.{});
}

/// `addNavTuners` but the tuner fields named in `skip`: a tuner only a setup step selected,
/// which the caller has shown no measured step ran.
pub fn addNavTunersExcept(census: *suite.TunerSettle, comptime prefix: []const u8, tuners: *const NavTuners, comptime skip: []const []const u8) void {
    inline for (@typeInfo(NavTuners).@"struct".field_names, @typeInfo(NavTuners).@"struct".field_types) |name, Field| {
        const skipped = comptime for (skip) |skip_name| {
            if (std.mem.eql(u8, name, skip_name)) break true;
        } else false;
        if (comptime skipped) {
            // A skipped field is a tuner, never the nav stage set.
            comptime std.debug.assert(Field == AdaptiveWorkTuner);
        } else if (comptime std.mem.eql(u8, name, "nav")) {
            inline for (comptime std.enums.values(NavStage)) |stage| census.add(prefix ++ @tagName(stage), tuners.nav.getPtrConst(stage));
        } else {
            comptime std.debug.assert(Field == AdaptiveWorkTuner);
            census.add(prefix ++ name, &@field(tuners, name));
        }
    }
}

/// `addNavTuners` over a fresh census.
pub fn navTunerSettle(comptime prefix: []const u8, tuners: *const NavTuners) suite.TunerSettle {
    var census = suite.TunerSettle{};
    addNavTuners(&census, prefix, tuners);
    return census;
}

/// Adds every tuner the structural-commit seam runs to `census`: the colliders' sync stages,
/// the trigger patch's query and store stages, and the nav set (`addNavTuners`). The seam's
/// steering reaction and growth sync dispatch nothing; the rebuild tuners run only at a
/// rebuild and the store's refresh only at a collision step, never at the seam, so they are
/// not walked.
pub fn addSeamTuners(census: *suite.TunerSettle, pipeline: *const SimulationPipeline) void {
    census.addNamed(&seam_stage_names[0..sync_stages.len].*, &syncTuners(&pipeline.static_colliders));
    census.add("trigger.query", &pipeline.collision.trigger_query_tuner);
    inline for (trigger_stages) |stage| census.add("trigger." ++ @tagName(stage), pipeline.collision.trigger_store.tuners.getPtrConst(stage));
    addNavTuners(census, "nav.", &pipeline.pathfinding.tuners);
}

const TriggerTuners = @FieldType(@FieldType(CollisionSystem, "trigger_store"), "tuners");
/// The collider sync's stages in `SyncStage` order, their names, and their tuners.
pub const sync_stages = std.enums.values(SyncStage);
pub const sync_stage_names: [sync_stages.len][]const u8 = blk: {
    var names: [sync_stages.len][]const u8 = undefined;
    for (&names, sync_stages) |*name, stage| name.* = @tagName(stage);
    break :blk names;
};

pub fn syncTuners(colliders: *const StaticColliderSystem) [sync_stages.len]*const AdaptiveWorkTuner {
    var tuners: [sync_stages.len]*const AdaptiveWorkTuner = undefined;
    for (&tuners, sync_stages) |*tuner, stage| tuner.* = colliders.tuners.getPtrConst(stage);
    return tuners;
}
// The trigger store's patch stages: every store stage but the collision step's refresh.
const trigger_stages = blk: {
    const all = std.enums.values(TriggerTuners.Key);
    var stages: [all.len - 1]TriggerTuners.Key = undefined;
    var count: usize = 0;
    for (all) |stage| {
        if (std.mem.eql(u8, @tagName(stage), "refresh")) continue;
        stages[count] = stage;
        count += 1;
    }
    std.debug.assert(count == stages.len);
    break :blk stages;
};

/// The structural-commit seam's stages, in `seamBatches` order: the collider sync's, the
/// trigger patch query, and the trigger store's patch stages.
pub const seam_stage_names: [sync_stages.len + 1 + trigger_stages.len][]const u8 = blk: {
    var names: [sync_stages.len + 1 + trigger_stages.len][]const u8 = undefined;
    for (sync_stages, 0..) |stage, index| names[index] = "sync." ++ @tagName(stage);
    names[sync_stages.len] = "trigger.query";
    for (trigger_stages, sync_stages.len + 1..) |stage, index| names[index] = "trigger." ++ @tagName(stage);
    break :blk names;
};

/// The collider sync's stages lead `seam_stage_names`, in `SyncStage` order.
pub const seam_sync_stage_count = sync_stages.len;

/// The seam's stage batches from the last commit (`seam_stage_names` order).
pub fn seamBatches(pipeline: *const SimulationPipeline) [seam_stage_names.len]BatchStats {
    var batches: [seam_stage_names.len]BatchStats = undefined;
    inline for (sync_stages, 0..) |stage, index| batches[index] = pipeline.static_colliders.perf.last_batches.get(static_colliders_test_support.colliderStage(stage));
    batches[sync_stages.len] = pipeline.collision.perf.trigger_query_batch;
    inline for (trigger_stages, sync_stages.len + 1..) |stage, index| batches[index] = pipeline.collision.trigger_store.perf.last_batches.get(stage);
    return batches;
}

/// The last commit seam's stage time on workers: its collider sync, trigger patch, and nav
/// reaction (`nav`, the commit's reaction stats) stages.
pub fn seamOffMainNs(pipeline: *const SimulationPipeline, nav: NavUpdateStats) u64 {
    var total = nav.perf.off_main_stage_ns;
    for (seamBatches(pipeline)) |batch| total += offMainNs(batch);
    return total;
}

/// `addSeamTuners` over a fresh census.
pub fn seamTunerSettle(pipeline: *const SimulationPipeline) suite.TunerSettle {
    var census = suite.TunerSettle{};
    addSeamTuners(&census, pipeline);
    return census;
}

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
    const tuner = tuners.nav.getPtrConst(.conn_flood);
    return if (tuner.has_threaded_profile) tuner.current_profile.worker_threads else 0;
}

/// The stride shuffle's preferred stride.
pub const shuffle_stride: usize = 97;

/// The smallest stride at or past `first` coprime with `count`, so `(step * stride) % count`
/// visits every index of `0..count` once: a fixed scattered order.
pub fn coprimeStride(first: usize, count: usize) usize {
    if (count <= 1) return 1;
    var stride = first;
    while (std.math.gcd(stride, count) != 1) : (stride += 1) {}
    return stride;
}

/// `0..count` in the stride-shuffled order. The caller frees it.
pub fn strideShuffledRows(allocator: std.mem.Allocator, count: usize) ![]u32 {
    const rows = try allocator.alloc(u32, count);
    const stride = coprimeStride(shuffle_stride, count);
    // Below `count`, a population size.
    for (rows, 0..) |*row, step| row.* = @intCast(step * stride % count);
    return rows;
}

/// A sprite texture slot of the render benches' table.
pub const TextureSlot = struct {
    id: sprite_batch.TextureId,
    desc: resources.TextureDesc,
    alive: bool = true,
};

/// The render benches' texture table: four live textures and a dead one (slot 4), which a
/// sprite's texture resolves against.
pub const TextureTable = struct {
    slots: []const TextureSlot,

    pub const bench = TextureTable{ .slots = &.{
        .{ .id = textureId(0, 1), .desc = .{ .width = 64, .height = 64 } },
        .{ .id = textureId(1, 1), .desc = .{ .width = 128, .height = 32 } },
        .{ .id = textureId(2, 1), .desc = .{ .width = 32, .height = 128 } },
        .{ .id = textureId(3, 1), .desc = .{ .width = 16, .height = 16 } },
        .{ .id = textureId(4, 1), .desc = .{ .width = 8, .height = 8 }, .alive = false },
    } };

    pub fn resolver(self: *const TextureTable) sprite_batch.TextureResolver {
        return .{ .context = self, .resolve = resolve };
    }

    fn resolve(context: *const anyopaque, id: sprite_batch.TextureId) ?resources.TextureDesc {
        const self: *const TextureTable = @ptrCast(@alignCast(context));
        if (!id.isValid()) return null;
        for (self.slots) |slot| {
            if (slot.alive and slot.id.matches(id.index, id.generation)) return slot.desc;
        }
        return null;
    }
};

pub fn textureId(index: u32, generation: u32) sprite_batch.TextureId {
    return sprite_batch.TextureId.init(index, generation) catch unreachable;
}

/// A render bench's tint for item `index`.
pub fn tintFor(index: usize) Color {
    return .{
        .r = 0.45 + @as(f32, @floatFromInt(index % 5)) * 0.08,
        .g = 0.55 + @as(f32, @floatFromInt(index % 7)) * 0.05,
        .b = 0.65 + @as(f32, @floatFromInt(index % 3)) * 0.09,
        .a = 1,
    };
}

/// Sums a render bench's per-iteration phase times (`Phases`: every field a `u64` time) and
/// gives their means.
pub fn PhaseAccumulator(comptime Phases: type) type {
    return struct {
        const names = @typeInfo(Phases).@"struct".field_names;
        totals: [names.len]u128 = @splat(0),

        pub fn record(self: *@This(), phases: Phases) void {
            inline for (names, &self.totals) |name, *total| total.* += @field(phases, name);
        }

        pub fn finish(self: @This(), iterations: usize) Phases {
            var means: Phases = .{};
            if (iterations == 0) return means;
            inline for (names, self.totals) |name, total| @field(means, name) = std.math.lossyCast(u64, total / iterations);
            return means;
        }
    };
}
