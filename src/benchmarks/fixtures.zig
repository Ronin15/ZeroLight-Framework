// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Fixture builders shared by the bench groups: a case's thread system, bodies, one-range
//! stream writes, the structural-commit seam and a static moved through it, the world
//! tileset and banded worlds, a 4-connected flood, a coprime-stride shuffle, the nav
//! reaction's and the static colliders' tuner setup, and the render benches' texture table
//! and phase timers.

const std = @import("std");
const math = @import("../core/math.zig");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const ThreadSystemConfig = @import("../app/thread_system.zig").ThreadSystemConfig;
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
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
const StructuralCommitStats = @import("../game/data_system.zig").StructuralCommitStats;
const maxEventsPerStep = @import("../game/simulation.zig").maxEventsPerStep;
const structuralEventHeadroom = @import("../game/simulation.zig").structuralEventHeadroom;
const PathRequest = @import("../game/simulation.zig").PathRequest;
const RangeOutputStream = @import("../game/simulation.zig").RangeOutputStream;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const StaticColliderSystem = @import("../game/systems/static_colliders.zig").StaticColliderSystem;
const splice_range_alignment_items = @import("../game/systems/chunk_list_map.zig").splice_range_alignment_items;
const WorldSystem = @import("../game/world/system.zig").WorldSystem;
const level_z_step = @import("../game/world/system.zig").level_z_step;
const default_chunk_size_tiles = @import("../game/world/system.zig").default_chunk_size_tiles;
const PathfindingSystem = @import("../game/systems/pathfinding.zig").PathfindingSystem;
const NavUpdateStats = @import("../game/systems/pathfinding.zig").NavUpdateStats;
const SteeringSystem = @import("../game/systems/steering/system.zig").SteeringSystem;
const evict_range_alignment_items = @import("../game/systems/pathfinding/types.zig").evict_range_alignment_items;
const nav_mark_range_alignment_items = @import("../game/systems/pathfinding/nav_reaction.zig").nav_mark_range_alignment_items;
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

/// The systems a bench's structural-commit seam runs with: a bench holds no
/// `SimulationPipeline`, so `commit` calls the seam's systems in the demo seam's order. `nav`
/// and `steering` are null when the bench builds none.
pub const CommitSeam = struct {
    colliders: *StaticColliderSystem,
    nav: ?Nav = null,
    steering: ?*SteeringSystem = null,
    /// The caller's part of the commit's `.structural_commit` event share, as a pipeline's
    /// `structural_headroom` (`structuralEventHeadroom` of the commands it queues a step).
    structural_headroom: usize,
    clock: ?*PhaseClock = null,

    pub const Nav = struct {
        system: *PathfindingSystem,
        world: *const WorldSystem,
    };

    pub const Result = struct {
        structural: StructuralCommitStats,
        nav: NavUpdateStats = .{},
    };

    /// Phase marks of one commit: after the collider capture, and after the collider sync
    /// and its nav record.
    pub const PhaseClock = struct {
        io: std.Io,
        captured_ns: i96 = 0,
        synced_ns: i96 = 0,
    };

    /// One structural commit in the demo seam's order (`commitStructuralAndReact`):
    /// `commands` written as one range of `frame`'s structural commands, the collider and
    /// static nav-mark reserve, the budgeted commit, the collider capture, the collider sync
    /// and its nav record, then the nav and steering post-commit reactions (splice and nav
    /// stages on `thread_system` when set). The population seam does not run: a bench grows
    /// no pipeline capacity. Runs in `frame`'s current step, whose structural commands are
    /// empty; the step's changes stay in the frame for the caller.
    pub fn commit(self: CommitSeam, frame: *SimulationFrame, data: *DataSystem, commands: []const StructuralCommand, thread_system: *ThreadSystem) !Result {
        try writeOneRange(StructuralCommand, &frame.structural_commands, commands);
        const nav_may_emit = if (self.nav) |nav| self.colliders.hasPendingChanges() or nav.system.navReactionMayEmit(data, frame, nav.world) else false;
        try self.colliders.reserveForCommit(data, commands.len);
        if (self.nav) |nav| try nav.system.reserveStaticColliderMarks(self.colliders.pendingChangeCount() + commands.len);
        const structural = try frame.applyStructuralCommandsBudgeted(data, .{
            .extra_required_events = if (nav_may_emit) maxEventsPerStep(.nav_reaction, .{}) else 0,
            .structural_event_share = maxEventsPerStep(.structural_commit, .{ .structural_headroom = self.structural_headroom }),
        });
        self.colliders.capture(frame);
        if (self.clock) |clock| clock.captured_ns = suite.nowNs(clock.io);
        try self.colliders.sync(data, thread_system);
        if (self.nav) |nav| nav.system.recordStaticColliderChanges(self.colliders.changesThisStep());
        if (self.clock) |clock| clock.synced_ns = suite.nowNs(clock.io);
        var result = Result{ .structural = structural };
        if (self.nav) |nav| result.nav = try nav.system.reactToPostCommitNavEvents(frame, self.colliders, nav.world, thread_system);
        if (self.steering) |steering| steering.reactToPostCommitSteeringEvents(frame);
        return result;
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

/// Gives the static colliders' chunk-rewrite stage a fresh tuner and the range controls
/// for `case`.
pub fn setSpliceTuners(colliders: *StaticColliderSystem, case: suite.BenchmarkCase) void {
    colliders.chunk_rewrite = suite.adaptiveTunerForCase(case, splice_range_alignment_items) orelse AdaptiveWorkTuner.init(.{});
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
    var world = WorldSystem{
        .allocator = allocator,
        .width = side,
        .height = side,
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
