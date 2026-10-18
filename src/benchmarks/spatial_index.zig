// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared spatial index groups, each timing the index alone (its consumers' groups build it
//! untimed).
//! - `spatial_index`: the build over shuffled slots, so keys reach the sort in store order.
//!   Pass shape: H log(H/B) in H indexed entities over B key bands, the sort off main on the
//!   tuned case. Asserts check the sort ran on workers at the largest size.
//! - `spatial_index-shape`: the build in a `shape_world_chunks`² world with every body in one
//!   chunk (`dense_chunk`), one per chunk (`sparse_chunks`), or `shape_deep_bodies` over its
//!   levels (`deep_levels`). Pass shape: linear in H with the sort off main on the tuned case
//!   at the largest H; `deep_levels` flat in levels, its storage linear in levels. Asserts
//!   check every body indexed, the sort on workers, and the directories' bytes whole against
//!   `chunk_slot_bytes` x chunks x levels.
//!   Both build groups print `entities=`, `--details` adding `main=` and the `sort=` and
//!   `link=` stage shapes; `spatial_index-shape` also prints `directory_bytes=`, the level
//!   directories' bytes.
//! - `spatial_index-query`: one query per body from its own position, in the index's
//!   cell-major order, through one neighbor block. `field` is a uniform four-faction field at
//!   the `ai` density, radius a quarter, one, or four chunks, over `full`, `friendly`, or
//!   `hostile` factions: one block fill per key, each walking the box's pieces once, and
//!   per-query time linear in its checks, hostile <= friendly <= full. `dense_cell` puts N
//!   neutral bodies in one cell with a one-cell radius: one fill for the run, per-query time
//!   flat in N, judged from timing. Asserts check each query's checks equal its budget or its
//!   box's entries of its factions but itself, every visit of the query's factions and never
//!   self, one fill per key, each field radius's chunk count, and every `dense_cell` body in
//!   one cell.

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const math = @import("../core/math.zig");
const simd = @import("../core/simd.zig");
const required_tile_size = @import("../assets/world_tileset_meta.zig").required_tile_size;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const FactionSet = @import("../game/faction.zig").FactionSet;
const default_chunk_size_tiles = @import("../game/world/system.zig").default_chunk_size_tiles;
const IndexGeometry = @import("../game/systems/spatial_index.zig").IndexGeometry;
const IndexPopulation = @import("../game/systems/spatial_index.zig").IndexPopulation;
const chunk_slot_bytes = @import("../game/systems/spatial_index.zig").chunk_slot_bytes;
const spatial_index_test_support = @import("../game/systems/spatial_index_test_support.zig");
const NeighborQuery = @import("../game/systems/spatial_index.zig").NeighborQuery;
const NeighborLanes = @import("../game/systems/spatial_index.zig").NeighborLanes;
const NeighborBlock = @import("../game/systems/spatial_index.zig").NeighborBlock;
const LaneStop = @import("../game/systems/spatial_index.zig").LaneStop;
const SpatialIndexConfig = @import("../game/systems/spatial_index.zig").SpatialIndexConfig;
const SpatialIndexStats = @import("../game/systems/spatial_index.zig").SpatialIndexStats;
const SpatialIndexSystem = @import("../game/systems/spatial_index.zig").SpatialIndexSystem;
const SpatialIndexView = @import("../game/systems/spatial_index.zig").SpatialIndexView;
const spatial_index_range_alignment_items = @import("../game/systems/spatial_index.zig").spatial_index_range_alignment_items;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "spatial_index",
    .item_label = "indexed entities",
    .item_counts = &suite.event_scale_counts,
    .runCase = runCase,
    .write_workload = writeIndexWorkload,
};

pub const shape_group = suite.BenchmarkGroup{
    .name = "spatial_index-shape",
    .item_label = ShapeCode.label,
    .item_counts = &shape_item_counts,
    .runCase = runShapeCase,
    .write_workload = writeShapeWorkload,
    .cases = &suite.serial_and_tuned_cases,
};

pub const query_group = suite.BenchmarkGroup{
    .name = "spatial_index-query",
    .item_label = QueryCode.label,
    .item_counts = &query_item_counts,
    .runCase = runQueryCase,
    .write_workload = writeQueryWorkload,
    .cases = &suite.serial_cases,
};

const Fixture = struct {
    data: DataSystem,

    fn deinit(self: *Fixture) void {
        self.data.deinit();
    }
};

// One world chunk's side in world units, from the world defaults.
const chunk_world: f32 = required_tile_size * @as(f32, @floatFromInt(default_chunk_size_tiles));

// Grid point `grid[slot]` for each slot: a fixed-seed shuffle of `0..count`, so keys reach
// the sort in store order, not key order. The caller frees it.
fn shuffledPoints(allocator: std.mem.Allocator, count: usize, seed: u64) ![]usize {
    const grid = try allocator.alloc(usize, count);
    for (grid, 0..) |*point, index| point.* = index;
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().shuffle(usize, grid);
    return grid;
}

fn addIndexedBody(data: *DataSystem, position: math.Vec2, index: usize) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{
        .position = position,
        .previous_position = position,
        .velocity = .{},
        .speed = 35.0 + @as(f32, @floatFromInt(index % 17)),
    });
    try data.setAiAgent(entity, .{
        .active_behavior = if (index % 3 == 0) .wander else .pursue,
        .wander_amplitude = 6.0 + @as(f32, @floatFromInt(index % 29)),
        .gain_pursue = if (index % 3 == 0) 0.0 else 0.4 + @as(f32, @floatFromInt(index % 7)) * 0.1,
    });
    return entity;
}

pub fn createFixture(allocator: std.mem.Allocator, count: usize) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const grid = try shuffledPoints(allocator, count, 0x5107_0dde);
    defer allocator.free(grid);
    for (0..count) |index| {
        _ = try addIndexedBody(&data, .{
            .x = @as(f32, @floatFromInt(grid[index] % 128)) * 11.0,
            .y = @as(f32, @floatFromInt(grid[index] / 128)) * 9.0,
        }, index);
    }
    return .{ .data = data };
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var fixture = try createFixture(allocator, item_count);
    defer fixture.deinit();
    const counts = &suite.event_scale_counts;
    const expect_off_main = item_count == counts[counts.len - 1];
    const rows = (item_count + 127) / 128;
    const geometry = fixtures.indexGeometryCovering(128 * 11.0, @as(f32, @floatFromInt(rows)) * 9.0, 1);
    const timed = try timeBuilds(allocator, io, options, case, &fixture.data, geometry, item_count, if (expect_off_main) .sort else .none);
    return timed.stats;
}

// Whether a tuned case asserts the sort, the build's cost driver, ran on workers; bucket and
// link run inline where their tuners keep them below the gate.
const OffMain = enum { none, sort };

const TimedBuilds = struct {
    stats: suite.RunStats,
    directory_bytes: usize,
};

// Times `options.iterations` builds of every AI agent of `data` over `geometry` after warmup
// and, on an adaptive case, tuner settling, asserting `off_main`'s stages ran on workers on
// the tuned case.
fn timeBuilds(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, data: *const DataSystem, geometry: IndexGeometry, item_count: usize, off_main: OffMain) !TimedBuilds {
    var system = SpatialIndexSystem.init(allocator);
    defer system.deinit();
    try system.reserve(data.aiAgentSliceConst().entities.len);
    if (suite.adaptiveTunerForCase(case, spatial_index_range_alignment_items)) |tuner| {
        system.bucket_tuner = tuner;
        system.sort_tuner = suite.adaptiveTunerForCase(case, spatial_index_range_alignment_items).?;
        system.link_tuner = suite.adaptiveTunerForCase(case, spatial_index_range_alignment_items).?;
    }

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;

    var warm = suite.Warmup.init(options, case, 0);
    while (warm.next((system.bucket_tuner.phase == .settled) and (system.sort_tuner.phase == .settled) and (system.link_tuner.phase == .settled))) _ = try runOnce(&system, data, geometry, thread_ptr, case);
    const bucket_settled_before_measurement = if (case.adaptive) (system.bucket_tuner.phase == .settled) else false;
    const sort_settled_before_measurement = if (case.adaptive) (system.sort_tuner.phase == .settled) else false;

    const tuned = case.adaptive and case.adaptive_range_mode == .tuned;
    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = SpatialIndexStats{};
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_stats = try runOnce(&system, data, geometry, thread_ptr, case);
        const end_ns = suite.nowNs(io);
        const elapsed_ns = suite.elapsedNs(start_ns, end_ns);
        if (tuned) switch (off_main) {
            .none => {},
            .sort => if (last_stats.sort_batch.ran_inline) return error.SortRanInline,
        };
        accumulator.record(elapsed_ns, last_stats.perf.bucket_batch);
        try suite.checkStagesDispatched(case, thread_ptr, case.stageItemsPerRange(spatial_index_range_alignment_items), &.{ last_stats.perf.bucket_batch, last_stats.sort_batch, last_stats.perf.link_batch });
        main_total += elapsed_ns -| (offMainNs(last_stats.perf.bucket_batch) + offMainNs(last_stats.sort_batch) + offMainNs(last_stats.perf.link_batch));
    }

    var stats = accumulator.finish();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    stats.output_count = last_stats.entity_count;
    stats.secondary_batch = suite.batchSummaryFromBatch(last_stats.sort_batch);
    stats.splice_batch = suite.batchSummaryFromBatch(last_stats.perf.link_batch);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(suite.tunerReport(&system.bucket_tuner), bucket_settled_before_measurement);
        stats.secondary_work_tuning = suite.workTuningSummary(suite.tunerReport(&system.sort_tuner), sort_settled_before_measurement);
    }
    return .{ .stats = stats, .directory_bytes = spatial_index_test_support.directoryBytes(&system) };
}

fn runOnce(system: *SpatialIndexSystem, data: *const DataSystem, geometry: IndexGeometry, thread_system: *ThreadSystem, case: suite.BenchmarkCase) !SpatialIndexStats {
    const population = IndexPopulation{ .entities = data.aiAgentSliceConst().entities };

    return try system.build(data, population, geometry, thread_system, .{
        .items_per_range = case.stageItemsPerRange(spatial_index_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

// The primary batch is the bucket stage, `secondary_batch` the sort, and `splice_batch` the
// link; `main` is the time outside the three stages' worker dispatches.
fn writeIndexWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("entities={}", .{stats.output_count});
    if (view == .summary) return;
    if (stats.main_ns) |main_ns| try suite.writeShare(writer, "main", main_ns, stats.mean_ns);
    const sort = stats.secondary_batch orelse return;
    try writer.writeAll(" sort=");
    try suite.writeStageShape(writer, sort);
    const link = stats.splice_batch orelse return;
    try writer.writeAll(" link=");
    try suite.writeStageShape(writer, link);
}

// ---- spatial_index-shape ------------------------------------------------------

const ShapeVariant = enum(u8) { dense_chunk, sparse_chunks, deep_levels };
// `axis` is the body count (`dense_chunk`, `sparse_chunks`) or the level count
// (`deep_levels`).
const ShapeCode = suite.ItemCode(struct { variant: ShapeVariant, axis: u32 }, &.{6});

const shape_item_counts = [_]usize{
    ShapeCode.of(.{ .variant = .dense_chunk, .axis = 1024 }),
    ShapeCode.of(.{ .variant = .dense_chunk, .axis = 4096 }),
    ShapeCode.of(.{ .variant = .dense_chunk, .axis = 16384 }),
    ShapeCode.of(.{ .variant = .sparse_chunks, .axis = 1024 }),
    ShapeCode.of(.{ .variant = .sparse_chunks, .axis = 4096 }),
    ShapeCode.of(.{ .variant = .sparse_chunks, .axis = 16384 }),
    ShapeCode.of(.{ .variant = .deep_levels, .axis = 2 }),
    ShapeCode.of(.{ .variant = .deep_levels, .axis = 8 }),
    ShapeCode.of(.{ .variant = .deep_levels, .axis = 32 }),
};

// The fixed world: room for one body per chunk at the largest H.
const shape_world_chunks: u32 = 128;
// The chunk every `dense_chunk` body lies in, mid-world.
const shape_dense_chunk: u32 = shape_world_chunks / 2;
const shape_deep_bodies: usize = 4096;
// `deep_levels`' grid columns at the `ai` pitch, mid-world.
const shape_deep_columns: usize = 64;
const shape_largest_bodies: u32 = 16384;

comptime {
    std.debug.assert(shape_largest_bodies <= shape_world_chunks * shape_world_chunks);
}

// The chunk column and row of world position `(x, y)`.
fn chunkOf(x: f32, y: f32) [2]u32 {
    return .{ @intFromFloat(@floor(x / chunk_world)), @intFromFloat(@floor(y / chunk_world)) };
}

fn createShapeFixture(allocator: std.mem.Allocator, variant: ShapeVariant, axis: u32) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const body_count: usize = switch (variant) {
        .dense_chunk, .sparse_chunks => axis,
        .deep_levels => shape_deep_bodies,
    };
    const levels: u32 = if (variant == .deep_levels) axis else 1;
    const grid = try shuffledPoints(allocator, body_count, 0x5a17_ce11);
    defer allocator.free(grid);
    var prng = std.Random.DefaultPrng.init(0x0d15_7a11);
    const random = prng.random();
    const mid_world = @as(f32, @floatFromInt(shape_world_chunks / 2)) * chunk_world;
    for (0..body_count) |slot| {
        const point = grid[slot];
        const position: math.Vec2 = switch (variant) {
            .dense_chunk => .{
                .x = (@as(f32, @floatFromInt(shape_dense_chunk)) + 0.01 + random.float(f32) * 0.98) * chunk_world,
                .y = (@as(f32, @floatFromInt(shape_dense_chunk)) + 0.01 + random.float(f32) * 0.98) * chunk_world,
            },
            .sparse_chunks => .{
                .x = (@as(f32, @floatFromInt(point % shape_world_chunks)) + 0.5) * chunk_world,
                .y = (@as(f32, @floatFromInt(point / shape_world_chunks)) + 0.5) * chunk_world,
            },
            .deep_levels => .{
                .x = mid_world + @as(f32, @floatFromInt(point % shape_deep_columns)) * 11.0,
                .y = mid_world + @as(f32, @floatFromInt(point / shape_deep_columns)) * 9.0,
            },
        };
        const entity = try addIndexedBody(&data, position, slot);
        if (variant == .deep_levels) try data.setWorldLevel(entity, @intCast(point % levels));
        const chunk = chunkOf(position.x, position.y);
        std.debug.assert(chunk[0] < shape_world_chunks and chunk[1] < shape_world_chunks);
        if (variant == .dense_chunk) std.debug.assert(chunk[0] == shape_dense_chunk and chunk[1] == shape_dense_chunk);
    }
    return .{ .data = data };
}

fn runShapeCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const fields = try ShapeCode.decode(item_count);
    var fixture = try createShapeFixture(allocator, fields.variant, fields.axis);
    defer fixture.deinit();
    const body_count = fixture.data.aiAgentSliceConst().entities.len;
    const levels: usize = if (fields.variant == .deep_levels) fields.axis else 1;
    const geometry = IndexGeometry{ .tile_size = required_tile_size, .chunk_size_tiles = default_chunk_size_tiles, .chunks_x = shape_world_chunks, .chunks_y = shape_world_chunks, .level_count = levels };
    const off_main: OffMain = if (fields.variant != .deep_levels and fields.axis == shape_largest_bodies) .sort else .none;
    const timed = try timeBuilds(allocator, io, options, case, &fixture.data, geometry, item_count, off_main);
    var stats = timed.stats;
    std.debug.assert(stats.output_count == body_count);
    // A directory per level of the world's chunks, checked whole against the live bytes.
    std.debug.assert(timed.directory_bytes == chunk_slot_bytes * shape_world_chunks * shape_world_chunks * levels);
    stats.cache_evictions = timed.directory_bytes;
    if (fields.variant == .sparse_chunks) {
        // One body per chunk: as many populated chunks as bodies.
        std.debug.assert(body_count == fields.axis);
    }
    if (fields.variant == .deep_levels) {
        // Every level holds the same share of the bodies.
        std.debug.assert(shape_deep_bodies % fields.axis == 0);
    }
    stats.items_per_second = suite.itemsPerSecond(body_count, stats.mean_ns);
    return stats;
}

// `cache_evictions` holds the level directories' bytes.
fn writeShapeWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writeIndexWorkload(writer, stats, view);
    try writer.print(" directory_bytes={}", .{stats.cache_evictions});
}

// ---- spatial_index-query ------------------------------------------------------

const QueryShape = enum(u8) { field, dense_cell };
const QueryFactions = enum(u8) { full, friendly, hostile };
// `axis` is the radius in quarter chunks (`field`) or the body count (`dense_cell`).
const QueryCode = suite.ItemCode(struct { shape: QueryShape, factions: QueryFactions, axis: u32 }, &.{ 1, 5 });

const query_item_counts = [_]usize{
    QueryCode.of(.{ .shape = .field, .factions = .full, .axis = 1 }),
    QueryCode.of(.{ .shape = .field, .factions = .full, .axis = 4 }),
    QueryCode.of(.{ .shape = .field, .factions = .full, .axis = 16 }),
    QueryCode.of(.{ .shape = .field, .factions = .friendly, .axis = 1 }),
    QueryCode.of(.{ .shape = .field, .factions = .friendly, .axis = 4 }),
    QueryCode.of(.{ .shape = .field, .factions = .friendly, .axis = 16 }),
    QueryCode.of(.{ .shape = .field, .factions = .hostile, .axis = 1 }),
    QueryCode.of(.{ .shape = .field, .factions = .hostile, .axis = 4 }),
    QueryCode.of(.{ .shape = .field, .factions = .hostile, .axis = 16 }),
    QueryCode.of(.{ .shape = .dense_cell, .factions = .full, .axis = 256 }),
    QueryCode.of(.{ .shape = .dense_cell, .factions = .full, .axis = 1024 }),
    QueryCode.of(.{ .shape = .dense_cell, .factions = .full, .axis = 4096 }),
};

// A world past the largest box on every side of the field.
const query_world_chunks: u32 = 16;
const query_field_columns: usize = 64;
const query_field_rows: usize = 64;
const query_field_bodies: usize = query_field_columns * query_field_rows;
// Every eighth column of every eighth row is hostile: one body in 64. The rest are neutral,
// player, and ally by slot.
const query_hostile_stride: usize = 8;
const query_check_budget: u16 = 64;
// The budget's stream and self.
const QueryBlock = NeighborBlock(query_check_budget + 1);

// The chunk columns a box of `radius` spans, from the default index cell: a quarter chunk's
// box fits in one chunk width, one chunk's spans three, four chunks' nine. Null for a radius
// the group does not state.
fn statedBoxChunks(radius_quarter_chunks: u32) ?u32 {
    return switch (radius_quarter_chunks) {
        1 => 1,
        4 => 3,
        16 => 9,
        else => null,
    };
}

fn createQueryFixture(allocator: std.mem.Allocator) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const mid_world = @as(f32, @floatFromInt(query_world_chunks / 2)) * chunk_world;
    const origin_x = mid_world - @as(f32, @floatFromInt(query_field_columns)) * 11.0 / 2;
    const origin_y = mid_world - @as(f32, @floatFromInt(query_field_rows)) * 9.0 / 2;
    for (0..query_field_bodies) |slot| {
        const column = slot % query_field_columns;
        const row = slot / query_field_columns;
        const entity = try addIndexedBody(&data, .{
            .x = origin_x + @as(f32, @floatFromInt(column)) * 11.0,
            .y = origin_y + @as(f32, @floatFromInt(row)) * 9.0,
        }, slot);
        const is_hostile = column % query_hostile_stride == 0 and row % query_hostile_stride == 0;
        try data.setFaction(entity, if (is_hostile) .hostile else @fromBackingInt(@intCast(slot % 3)));
    }
    return .{ .data = data };
}

// `count` neutral bodies at random positions inside one index cell, mid-world.
fn createDenseCellFixture(allocator: std.mem.Allocator, count: usize) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const cell_size = (SpatialIndexConfig{}).cell_size;
    const cell_origin = @as(f32, @floatFromInt(query_world_chunks / 2)) * chunk_world;
    var prng = std.Random.DefaultPrng.init(0xde45_ce11);
    const random = prng.random();
    for (0..count) |slot| {
        _ = try addIndexedBody(&data, .{
            .x = cell_origin + (0.01 + random.float(f32) * 0.98) * cell_size,
            .y = cell_origin + (0.01 + random.float(f32) * 0.98) * cell_size,
        }, slot);
    }
    return .{ .data = data };
}

// Counts a query's visits and sums their distances, so no visit is elided.
const QueryVisitor = struct {
    visits: usize = 0,
    dist2_sum: f32 = 0,

    pub fn visitLanes(self: *QueryVisitor, lanes: *const NeighborLanes) LaneStop {
        self.visits += @popCount(lanes.inside);
        self.dist2_sum += simd.sumLanesFloat4(simd.selectOrZeroFloat4(lanes.inside, lanes.dist2));
        return null;
    }
};

// Asserts every visit is of a faction in `factions` and never of `self`; untimed.
const CheckingVisitor = struct {
    data: *const DataSystem,
    index: SpatialIndexView,
    factions: FactionSet,
    self: EntityId,

    pub fn visitLanes(self: *CheckingVisitor, lanes: *const NeighborLanes) LaneStop {
        const inside: std.bit_set.Integer(simd.lane_count) = .{ .mask = lanes.inside };
        var bits = inside.iterator(.{});
        while (bits.next()) |bit| {
            // A set bit's index is below lane_count.
            const lane: simd.LaneIndex = @intCast(bit);
            const entries: [simd.lane_count]u32 = lanes.entry;
            const entity = self.index.entityAt(entries[lane]);
            std.debug.assert(self.factions.contains(self.data.factionConst(entity) orelse .neutral));
            std.debug.assert(!entity.eql(self.self));
        }
        return null;
    }
};

const QueryTotals = struct {
    checks: usize = 0,
    visits: usize = 0,
    dist2_sum: f32 = 0,
    block_fills: usize = 0,
};

fn runQueryCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    std.debug.assert(!case.usesThreadSystem());
    const fields = try QueryCode.decode(item_count);
    var fixture = switch (fields.shape) {
        .field => try createQueryFixture(allocator),
        .dense_cell => try createDenseCellFixture(allocator, fields.axis),
    };
    defer fixture.deinit();
    const query_count = fixture.data.aiAgentSliceConst().entities.len;
    const geometry = IndexGeometry{ .tile_size = required_tile_size, .chunk_size_tiles = default_chunk_size_tiles, .chunks_x = query_world_chunks, .chunks_y = query_world_chunks, .level_count = 1 };
    const cell_size = (SpatialIndexConfig{}).cell_size;
    const cells_per_chunk: u32 = @intFromFloat(chunk_world / cell_size);
    const radius = switch (fields.shape) {
        .field => @as(f32, @floatFromInt(fields.axis)) * chunk_world / 4,
        .dense_cell => cell_size,
    };
    const box_cells: u32 = 2 * @as(u32, @intFromFloat(@ceil(radius / cell_size))) + 1;
    switch (fields.shape) {
        .field => {
            const stated_chunks = statedBoxChunks(fields.axis) orelse return error.UnstatedQueryRadius;
            std.debug.assert((box_cells + cells_per_chunk - 1) / cells_per_chunk == stated_chunks);
        },
        .dense_cell => std.debug.assert(box_cells == 3),
    }
    const factions: FactionSet = switch (fields.factions) {
        .full => .full,
        .friendly => .initMany(&.{ .player, .ally }),
        .hostile => .initOne(.hostile),
    };

    // Positions never change, so the index is built once, untimed and inline.
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    var system = SpatialIndexSystem.init(allocator);
    defer system.deinit();
    _ = try system.build(&fixture.data, .{ .entities = fixture.data.aiAgentSliceConst().entities }, geometry, &threads, .{});
    // The bench's cells are the index's.
    std.debug.assert(system.view().cells_per_chunk == cells_per_chunk and system.view().cell_size == cell_size);

    var counts = try FactionCellCounts.init(allocator, &fixture.data, system.view(), factions);
    defer counts.deinit(allocator);
    if (fields.shape == .dense_cell) {
        // Every body in one cell.
        const index = system.view();
        const cell_x = math.worldPosToCell(index.x[0], index.cell_size, index.cells_x);
        const cell_y = math.worldPosToCell(index.y[0], index.cell_size, index.cells_y);
        std.debug.assert(counts.inBox(cell_x, cell_y, 0) == query_count);
    }
    const order = try queryOrder(allocator, system.view());
    defer allocator.free(order);
    std.debug.assert(order.len == query_count);
    checkQueries(&system, &fixture, order, radius, factions, &counts);
    for (0..options.warmup_iterations) |_| _ = runQueries(&system, &fixture, order, radius, factions);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var totals = QueryTotals{};
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        totals = runQueries(&system, &fixture, order, radius, factions);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), .{});
    }
    std.debug.assert(std.math.isFinite(totals.dist2_sum));

    // One fill per key, as the untimed check counted (fills count only with the perf log).
    std.debug.assert(totals.block_fills == ownCellRuns(&system, &fixture, order));
    if (fields.shape == .dense_cell) std.debug.assert(totals.block_fills == 1);

    var stats = accumulator.finish();
    stats.items_per_second = suite.itemsPerSecond(query_count, stats.mean_ns);
    stats.batch_carried = false;
    stats.deferred_count = query_count;
    stats.candidate_pairs = totals.checks;
    stats.output_count = totals.visits;
    stats.sample_count = box_cells;
    stats.neighbor_block_fills = totals.block_fills;
    return stats;
}

// The runs of consecutive queries in `order` sharing an own cell: the field's keys, since its
// box and factions are fixed.
fn ownCellRuns(system: *const SpatialIndexSystem, fixture: *const Fixture, order: []const u32) usize {
    const index = system.view();
    var runs: usize = 0;
    var previous: ?[2]u32 = null;
    for (order) |slot| {
        const query = slotQuery(fixture, slot, 0, .full);
        const cell = [2]u32{ math.worldPosToCell(query.x, index.cell_size, index.cells_x), math.worldPosToCell(query.y, index.cell_size, index.cells_y) };
        if (previous == null or !std.mem.eql(u32, &previous.?, &cell)) runs += 1;
        previous = cell;
    }
    return runs;
}

// The query from slot `slot`'s own position with its entity as `self`, under the fixture's
// budget.
fn slotQuery(fixture: *const Fixture, slot: usize, radius: f32, factions: FactionSet) NeighborQuery {
    const entity = fixture.data.aiAgentSliceConst().entities[slot];
    const body = fixture.data.movementBodyDenseIndex(entity).?;
    const movement = fixture.data.movementBodySliceConst();
    return .{
        .x = movement.previous_x[body],
        .y = movement.previous_y[body],
        .level = 0,
        .radius = radius,
        .max_candidate_checks = query_check_budget,
        .factions = factions,
        .self = entity,
    };
}

// Per-cell counts of the bodies of one faction set over the index's cells, as an inclusive
// prefix table: `prefix[(y + 1) * (cells_x + 1) + x + 1]` counts the set's bodies in cells
// `[0, x] x [0, y]`.
const FactionCellCounts = struct {
    prefix: []u32,
    cells_x: u32,
    cells_y: u32,

    fn init(allocator: std.mem.Allocator, data: *const DataSystem, index: SpatialIndexView, factions: FactionSet) !FactionCellCounts {
        const stride = @as(usize, index.cells_x) + 1;
        const prefix = try allocator.alloc(u32, stride * (@as(usize, index.cells_y) + 1));
        @memset(prefix, 0);
        for (index.x, index.y, 0..) |x, y, entry| {
            if (!factions.contains(data.factionConst(index.entityAt(@intCast(entry))) orelse .neutral)) continue;
            const cell_x = math.worldPosToCell(x, index.cell_size, index.cells_x);
            const cell_y = math.worldPosToCell(y, index.cell_size, index.cells_y);
            prefix[(@as(usize, cell_y) + 1) * stride + cell_x + 1] += 1;
        }
        for (1..index.cells_y + 1) |row| {
            for (1..stride) |column| {
                prefix[row * stride + column] += prefix[(row - 1) * stride + column] + prefix[row * stride + column - 1] - prefix[(row - 1) * stride + column - 1];
            }
        }
        return .{ .prefix = prefix, .cells_x = index.cells_x, .cells_y = index.cells_y };
    }

    fn deinit(self: *FactionCellCounts, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
    }

    // The set's bodies in the cells within `scan_radius` of `(own_x, own_y)`, clamped to the
    // grid.
    fn inBox(self: *const FactionCellCounts, own_x: u32, own_y: u32, scan_radius: u32) u32 {
        const stride = @as(usize, self.cells_x) + 1;
        const min_x: usize = own_x -| scan_radius;
        const min_y: usize = own_y -| scan_radius;
        const end_x: usize = @min(@as(usize, own_x) + scan_radius + 1, self.cells_x);
        const end_y: usize = @min(@as(usize, own_y) + scan_radius + 1, self.cells_y);
        return self.prefix[end_y * stride + end_x] + self.prefix[min_y * stride + min_x] - self.prefix[min_y * stride + end_x] - self.prefix[end_y * stride + min_x];
    }
};

// The population slots in the index's cell-major order: records in key order, each record's
// (cell, faction) runs. The caller frees it.
fn queryOrder(allocator: std.mem.Allocator, index: SpatialIndexView) ![]u32 {
    const order = try allocator.alloc(u32, index.entryCount());
    var count: usize = 0;
    var span = index.cellMajorSpan(0, index.entryCount());
    while (span.next(&index)) |run| {
        @memcpy(order[count..][0 .. run.end - run.start], index.population_row[run.start..run.end]);
        count += run.end - run.start;
    }
    std.debug.assert(count == order.len);
    return order;
}

// Every query once, untimed: its checks the budget or its box's bodies of its factions but
// itself, and its visits of its factions.
fn checkQueries(system: *const SpatialIndexSystem, fixture: *const Fixture, order: []const u32, radius: f32, factions: FactionSet, counts: *const FactionCellCounts) void {
    const index = system.view();
    const scan_radius: u32 = @intFromFloat(@ceil(radius / index.cell_size));
    var block = QueryBlock{};
    for (order) |slot| {
        const query = slotQuery(fixture, slot, radius, factions);
        var visitor = CheckingVisitor{ .data = &fixture.data, .index = index, .factions = factions, .self = query.self };
        const query_stats = index.queryNeighbors(&block, query, &visitor);
        const own_x = math.worldPosToCell(query.x, index.cell_size, index.cells_x);
        const own_y = math.worldPosToCell(query.y, index.cell_size, index.cells_y);
        const self_counted: u32 = @intFromBool(factions.contains(fixture.data.factionConst(query.self) orelse .neutral));
        const wanted = counts.inBox(own_x, own_y, scan_radius) - self_counted;
        std.debug.assert(query_stats.candidate_checks == @min(wanted, query_check_budget));
    }
    std.debug.assert(block.perf.fills == ownCellRuns(system, fixture, order));
}

fn runQueries(system: *const SpatialIndexSystem, fixture: *const Fixture, order: []const u32, radius: f32, factions: FactionSet) QueryTotals {
    const index = system.view();
    var totals = QueryTotals{};
    var block = QueryBlock{};
    for (order) |slot| {
        var visitor = QueryVisitor{};
        const query_stats = index.queryNeighbors(&block, slotQuery(fixture, slot, radius, factions), &visitor);
        totals.checks += query_stats.candidate_checks;
        totals.visits += visitor.visits;
        totals.dist2_sum += visitor.dist2_sum;
    }
    totals.block_fills = block.perf.fills;
    return totals;
}

// `deferred_count` holds the queries, `candidate_pairs` their checks, `output_count` their
// visits, `sample_count` the box side in cells, and `neighbor_block_fills` the block fills.
fn writeQueryWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    const queries = @max(stats.deferred_count, 1);
    try writer.print("queries={} box_cells={} block_fills={} checks_per_query={d:.2} visits_per_query={d:.2}", .{
        stats.deferred_count,
        stats.sample_count,
        stats.neighbor_block_fills,
        @as(f64, @floatFromInt(stats.candidate_pairs)) / @as(f64, @floatFromInt(queries)),
        @as(f64, @floatFromInt(stats.output_count)) / @as(f64, @floatFromInt(queries)),
    });
}
