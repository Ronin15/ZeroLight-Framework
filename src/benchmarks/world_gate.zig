// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! `world-gate`: one `WorldGateSystem.apply` (the bounds clamp and the solid-tile gate of
//! a settled movement step: one lane pass over the movement rows, then the player row)
//! over bodies on underground levels whose floors alternate walkable and solid tiles, plus
//! the player on the surface. Each body's collision bounds equal its visual size, and it
//! starts and steps inside one tile, a checkerboard of bodies on walkable and on solid
//! tiles whatever the grid pitch, so per-body work is the same at every size. The apply is
//! idempotent, so no reset runs between iterations. `--details` prints `main=`, the time
//! outside a pass that ran on workers, its share and per body, and `threaded=`, the
//! measured applies whose pass ran on workers.
//!
//! Item code: `shape * 10^6 + bodies`. Shapes:
//! - `uniform` (0): every row a gated AI body on level 1.
//! - `interleaved` (1): rows cycle a non-AI mover, a dormant AI body, a gated AI body on
//!   level 1, and one on level 2, so lane batches mix gated and skipped rows and gated
//!   lanes alternate levels: the store order the pass meets when membership and level do
//!   not order the rows.
//! - `scattered` (2): every row a gated AI body on the grid, its level (1 or 2) drawn from
//!   a seeded RNG and the rows stored in a seeded random order, so neighbouring lanes read
//!   terrain bits on other levels and chunks.
//! - `scattered-sorted` (3): the identical row set stored in `(level, chunk)` order.
//! - `wide-scattered` (4) and `wide-scattered-sorted` (5): the same pair on a 4096-tile
//!   side. Each body owns one chunk on level 1 or 2, and that chunk's origin cell is
//!   solid, so every lookup reads a mixed chunk's bit block. The blocks are one per body
//!   (128KB, 512KB, and 2MB at the three body counts).
//!
//! The scattered pair measures what scattered store order costs the per-row terrain
//! lookups against the same rows grouped by level and chunk. The wide pair is that
//! measurement with one bit block per body. Either pass shape (scattered within
//! spread of its sorted twin) is reported, not asserted.
//!
//! Pass shape: time linear in bodies and main per body flat in each shape;
//! `thread-adaptive-tuned-range` is the production tuner and matches or beats the best
//! control within spread. Asserts check the fixture's row count, that the timed applies
//! hold exactly the gated solid-start rows and the dormant rows at their previous position,
//! and that a fixed threaded case ran the pass on workers.

const std = @import("std");
const math = @import("../core/math.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const Player = @import("../game/player.zig").Player;
const ChunkCoord = @import("../game/simulation_scope.zig").ChunkCoord;
const SimulationTier = @import("../game/simulation_scope.zig").SimulationTier;
const WorldGateConfig = @import("../game/systems/world_gate.zig").WorldGateConfig;
const WorldGateSystem = @import("../game/systems/world_gate.zig").WorldGateSystem;
const world_gate_range_alignment_items = @import("../game/systems/world_gate.zig").world_gate_range_alignment_items;
const TileId = @import("../game/world/system.zig").TileId;
const WorldSystem = @import("../game/world/system.zig").WorldSystem;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "world-gate",
    .item_label = GateCode.label,
    .describe_item = GateCode.describe,
    .item_counts = &item_counts,
    .runCase = runCase,
    .write_workload = writeGateWorkload,
};

const GateShape = enum(u8) { uniform, interleaved, scattered, scattered_sorted, wide_scattered, wide_scattered_sorted };
const GateFields = struct { shape: GateShape, bodies: u32 };
const GateCode = suite.ItemCode(GateFields, &.{6});

const item_counts = [_]usize{
    GateCode.of(.{ .shape = .uniform, .bodies = 4_096 }),
    GateCode.of(.{ .shape = .uniform, .bodies = 16_384 }),
    GateCode.of(.{ .shape = .uniform, .bodies = 65_536 }),
    GateCode.of(.{ .shape = .interleaved, .bodies = 4_096 }),
    GateCode.of(.{ .shape = .interleaved, .bodies = 16_384 }),
    GateCode.of(.{ .shape = .interleaved, .bodies = 65_536 }),
    GateCode.of(.{ .shape = .scattered, .bodies = 4_096 }),
    GateCode.of(.{ .shape = .scattered, .bodies = 16_384 }),
    GateCode.of(.{ .shape = .scattered, .bodies = 65_536 }),
    GateCode.of(.{ .shape = .scattered_sorted, .bodies = 4_096 }),
    GateCode.of(.{ .shape = .scattered_sorted, .bodies = 16_384 }),
    GateCode.of(.{ .shape = .scattered_sorted, .bodies = 65_536 }),
    GateCode.of(.{ .shape = .wide_scattered, .bodies = 4_096 }),
    GateCode.of(.{ .shape = .wide_scattered, .bodies = 16_384 }),
    GateCode.of(.{ .shape = .wide_scattered, .bodies = 65_536 }),
    GateCode.of(.{ .shape = .wide_scattered_sorted, .bodies = 4_096 }),
    GateCode.of(.{ .shape = .wide_scattered_sorted, .bodies = 16_384 }),
    GateCode.of(.{ .shape = .wide_scattered_sorted, .bodies = 65_536 }),
};

// The fixed world: a surface and the gated levels, each of this side in tiles.
const gate_level_side: u16 = 256;
// Wide shapes: 256 chunks on a side, so 65,536 bodies still get one chunk each.
const wide_level_side: u16 = 4096;
const gate_levels = [_]u16{ 1, 2 };
const body_size: f32 = 20;
// The player's box, the size the demo gives it.
const player_size: f32 = 32;
// Each body's settled step from its previous position, so both gate axes test a move.
const step_offset = math.Vec2{ .x = 3, .y = 2 };
// Seeds the scattered shapes' levels and store order; mixed with the body count so each
// size has its own deterministic layout, the same in both scattered shapes.
const scatter_seed: u64 = 0x5ca7_7e2d_0b0d_1e5;

// What one body row is: whether the pass gates it, and on which level.
const RowKind = enum { non_ai, dormant, gated };

const BodyRow = struct { kind: RowKind, level: u16 };

// The scattered shapes draw each row's level in `placeBodies`.
fn bodyRow(shape: GateShape, index: usize) BodyRow {
    return switch (shape) {
        .uniform, .scattered, .scattered_sorted, .wide_scattered, .wide_scattered_sorted => .{ .kind = .gated, .level = gate_levels[0] },
        .interleaved => switch (index % 4) {
            0 => .{ .kind = .non_ai, .level = gate_levels[0] },
            1 => .{ .kind = .dormant, .level = gate_levels[0] },
            2 => .{ .kind = .gated, .level = gate_levels[0] },
            else => .{ .kind = .gated, .level = gate_levels[1] },
        },
    };
}

fn levelCount(shape: GateShape) u16 {
    return switch (shape) {
        .uniform => gate_levels[0] + 1,
        .interleaved, .scattered, .scattered_sorted, .wide_scattered, .wide_scattered_sorted => gate_levels[1] + 1,
    };
}

const Fixture = struct {
    world: WorldSystem,
    data: DataSystem,
    player: Player,
    // Rows the pass gates, and rows the timed applies leave at their previous position:
    // the gated solid starts and the dormant rows.
    gated_rows: usize,
    held_rows: usize,

    fn deinit(self: *Fixture) void {
        self.data.deinit();
        self.world.deinit();
        self.* = undefined;
    }
};

// Every gated level's floor alternates walkable and solid tiles in a checkerboard.
// Wide shapes leave the floors walkable and paint one solid cell per body chunk later.
const BuiltWorld = struct {
    world: WorldSystem,
    solid: TileId,
};

fn wideShape(shape: GateShape) bool {
    return shape == .wide_scattered or shape == .wide_scattered_sorted;
}

fn buildWorld(allocator: std.mem.Allocator, io: std.Io, shape: GateShape) !BuiltWorld {
    var tileset = try fixtures.loadTilesetMeta(allocator, io);
    defer tileset.deinit();
    const meta = &tileset;
    const levels = levelCount(shape);
    const side = if (wideShape(shape)) wide_level_side else gate_level_side;
    var world = try fixtures.buildBandedWorld(allocator, meta, side, levels, "grass", "grass");
    errdefer world.deinit();
    const solid = try world.requireTileByName(meta, "dirt");
    // A wide chunk becomes mixed when its origin cell is painted, one per body.
    if (wideShape(shape)) return .{ .world = world, .solid = solid };
    const walkable = try world.requireTileByName(meta, "grass");
    for (1..levels) |level| {
        const floor = world.denseFloorLayerForLevel(@intCast(level)) orelse return error.InvalidWorldLevel;
        for (0..side) |y| {
            for (0..side) |x| {
                _ = try world.setDenseTile(floor, @intCast(x), @intCast(y), if ((x + y) % 2 == 0) walkable else solid);
            }
        }
    }
    return .{ .world = world, .solid = solid };
}

// One body row in store order: its previous position, the chunk it steps into, whether
// its start tile is solid, and what the row is. `grid_index` is its place on the grid.
const Placement = struct {
    previous: math.Vec2,
    chunk: ChunkCoord,
    solid: bool,
    body: BodyRow,
    grid_index: usize,

    // `(level, chunk row, chunk column)`, then the grid order inside a chunk.
    fn levelChunkLessThan(_: void, a: Placement, b: Placement) bool {
        if (a.body.level != b.body.level) return a.body.level < b.body.level;
        if (a.chunk.y != b.chunk.y) return a.chunk.y < b.chunk.y;
        if (a.chunk.x != b.chunk.x) return a.chunk.x < b.chunk.x;
        return a.grid_index < b.grid_index;
    }
};

// The bodies on a grid over the level, in the shape's store order. Caller owns the slice.
fn placeBodies(allocator: std.mem.Allocator, world: *const WorldSystem, shape: GateShape, bodies: usize) ![]Placement {
    const grid_side = suite.ceilSqrt(bodies);
    if (grid_side > gate_level_side) return error.WorldGateGridPastLevel;
    const pitch_tiles = gate_level_side / grid_side;
    const tile = world.tile_size;
    var prng = std.Random.DefaultPrng.init(scatter_seed ^ bodies);
    const random = prng.random();
    const placements = try allocator.alloc(Placement, bodies);
    errdefer allocator.free(placements);
    for (placements, 0..) |*placement, index| {
        const column = index % grid_side;
        const row = index / grid_side;
        // Checkerboard of bodies: odd ones start on a solid tile, even ones on a walkable one.
        const solid = (column + row) % 2 == 1;
        var tile_x = column * pitch_tiles;
        const tile_y = row * pitch_tiles;
        // The floor is walkable where the tile parity is even; a body whose pitch tile has the
        // other parity shifts one tile along x, back from the level's last column.
        if (((tile_x + tile_y) % 2 == 1) != solid) tile_x = if (tile_x + 1 < gate_level_side) tile_x + 1 else tile_x - 1;
        var body = bodyRow(shape, index);
        if (shape == .scattered or shape == .scattered_sorted) body.level = gate_levels[random.uintLessThan(usize, gate_levels.len)];
        const previous = math.Vec2{
            .x = @as(f32, @floatFromInt(tile_x)) * tile,
            .y = @as(f32, @floatFromInt(tile_y)) * tile,
        };
        placement.* = .{
            .previous = previous,
            .chunk = world.chunkCoordForWorldPos(previous.x + step_offset.x, previous.y + step_offset.y),
            .solid = solid,
            .body = body,
            .grid_index = index,
        };
    }
    switch (shape) {
        .uniform, .interleaved => {},
        .scattered => random.shuffle(Placement, placements),
        .scattered_sorted => std.mem.sort(Placement, placements, {}, Placement.levelChunkLessThan),
        .wide_scattered, .wide_scattered_sorted => unreachable,
    }
    return placements;
}

// One body per (level, chunk), striped across the two gated levels. The origin cell is
// painted before the store order changes, so each level's bit-block slots follow chunk
// order and a shuffled store reads them out of order. A walkable body sits on the next
// cell of its chunk. Caller owns the slice.
fn placeWideBodies(allocator: std.mem.Allocator, world: *WorldSystem, solid_tile: TileId, shape: GateShape, bodies: usize) ![]Placement {
    const chunk_tiles: usize = world.chunk_size_tiles;
    const chunks_x = world.width / chunk_tiles;
    const chunk_slots = chunks_x * (world.height / chunk_tiles);
    if (bodies > chunk_slots * gate_levels.len) return error.WorldGateGridPastLevel;
    const tile = world.tile_size;
    const placements = try allocator.alloc(Placement, bodies);
    errdefer allocator.free(placements);
    for (placements, 0..) |*placement, index| {
        const level = gate_levels[index % gate_levels.len];
        const slot = index / gate_levels.len;
        const solid = slot % 2 == 1;
        const cx = slot % chunks_x;
        const cy = slot / chunks_x;
        const local_x: usize = if (solid) 0 else 1;
        const tile_x = cx * chunk_tiles + local_x;
        const tile_y = cy * chunk_tiles;
        const previous = math.Vec2{
            .x = @as(f32, @floatFromInt(tile_x)) * tile,
            .y = @as(f32, @floatFromInt(tile_y)) * tile,
        };
        placement.* = .{
            .previous = previous,
            .chunk = world.chunkCoordForWorldPos(previous.x + step_offset.x, previous.y + step_offset.y),
            .solid = solid,
            .body = .{ .kind = .gated, .level = level },
            .grid_index = index,
        };
        std.debug.assert(placement.chunk.x == @as(i32, @intCast(cx)));
        std.debug.assert(placement.chunk.y == @as(i32, @intCast(cy)));
    }
    // Slot order is this order. Permuting first would make the gate stream the pool.
    try paintWideSolids(world, solid_tile, placements);
    switch (shape) {
        .wide_scattered => {
            var prng = std.Random.DefaultPrng.init(scatter_seed ^ bodies);
            prng.random().shuffle(Placement, placements);
        },
        .wide_scattered_sorted => std.mem.sort(Placement, placements, {}, Placement.levelChunkLessThan),
        .uniform, .interleaved, .scattered, .scattered_sorted => unreachable,
    }
    return placements;
}

// Paints the origin cell of each wide body's chunk solid, so the chunk is mixed and the
// gate's lookup reads its bit block. A repeated chunk paints the same cell again.
fn paintWideSolids(world: *WorldSystem, solid: TileId, placements: []const Placement) !void {
    const chunk_tiles = world.chunk_size_tiles;
    for (placements) |placement| {
        const floor = world.denseFloorLayerForLevel(placement.body.level) orelse return error.InvalidWorldLevel;
        const origin_x: u16 = @intCast(@as(i32, @intCast(chunk_tiles)) * placement.chunk.x);
        const origin_y: u16 = @intCast(@as(i32, @intCast(chunk_tiles)) * placement.chunk.y);
        _ = try world.setDenseTile(floor, origin_x, origin_y, solid);
    }
}

fn buildFixture(allocator: std.mem.Allocator, io: std.Io, shape: GateShape, bodies: usize) !Fixture {
    const built = try buildWorld(allocator, io, shape);
    var world = built.world;
    errdefer world.deinit();
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const player = try Player.spawn(&data);
    try data.setCollisionBounds(player.entity, .{ .size = .{ .x = player_size, .y = player_size } });

    const tile = world.tile_size;
    // A body and its step stay inside its start tile on both axes.
    std.debug.assert(body_size + step_offset.x < tile and body_size + step_offset.y < tile);
    const placements = if (wideShape(shape))
        try placeWideBodies(allocator, &world, built.solid, shape, bodies)
    else
        try placeBodies(allocator, &world, shape, bodies);
    defer allocator.free(placements);
    var gated_rows: usize = 0;
    var held_rows: usize = 0;
    for (placements) |placement| {
        const body = placement.body;
        gated_rows += @intFromBool(body.kind == .gated);
        held_rows += @intFromBool(body.kind == .dormant or (body.kind == .gated and placement.solid));
        const previous = placement.previous;
        const position = math.Vec2{ .x = previous.x + step_offset.x, .y = previous.y + step_offset.y };
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{ .position = position, .previous_position = previous, .velocity = step_offset, .speed = 40 });
        try data.setPrimitiveVisual(entity, .{
            .size = .{ .x = body_size, .y = body_size },
            .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
            .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        });
        try data.setCollisionBounds(entity, .{ .size = .{ .x = body_size, .y = body_size } });
        if (body.kind != .non_ai) try data.setAiAgent(entity, .{ .active_behavior = .wander });
        try data.setWorldLevel(entity, body.level);
        // A dormant row snaps its previous position to its position here.
        const tier: SimulationTier = if (body.kind == .dormant) .dormant else .locomotion;
        try data.setSimulationMetadata(entity, .{
            .tier = tier,
            .chunk = placement.chunk,
            .level = body.level,
        });
    }
    std.debug.assert(data.movementBodySliceConst().entities.len == bodies + 1);
    return .{ .world = world, .data = data, .player = player, .gated_rows = gated_rows, .held_rows = held_rows };
}

// The body rows (not the player's) at their previous position on both axes.
fn heldRows(data: *const DataSystem, player: EntityId) usize {
    const movement = data.movementBodySliceConst();
    var held: usize = 0;
    for (movement.entities, 0..) |entity, row| {
        if (entity.eql(player)) continue;
        held += @intFromBool(movement.position_x[row] == movement.previous_x[row] and movement.position_y[row] == movement.previous_y[row]);
    }
    return held;
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const code = try GateCode.decode(item_count);
    const bodies: usize = code.bodies;
    var fixture = try buildFixture(allocator, io, code.shape, bodies);
    defer fixture.deinit();
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const bounds = fixture.world.worldWidthPixels();

    var gate: WorldGateSystem = .{};
    const items_per_range = case.stageItemsPerRange(world_gate_range_alignment_items);
    const config = WorldGateConfig{
        .items_per_range = items_per_range,
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
        .batches_per_participant = case.stageBatchesPerParticipant(),
    };

    var warm = suite.Warmup.init(options, case, 0);
    while (warm.next(suite.tunerSettled(&gate.tuner))) {
        try gate.apply(&fixture.world, &fixture.data, &fixture.player, bounds, bounds, &threads, config);
    }
    const tuner_start = suite.TunerStart.of(&gate.tuner, case);

    var accumulator = suite.StatsAccumulator.init(item_count);
    var main_total: u128 = 0;
    var threaded_applies: usize = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        try gate.apply(&fixture.world, &fixture.data, &fixture.player, bounds, bounds, &threads, config);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        const batch = gate.perf.last_batch;
        // Every movement row is an item: the bodies and the player.
        std.debug.assert(batch.item_count == bodies + 1);
        try suite.checkStageDispatched(case, &threads, items_per_range, batch);
        accumulator.record(elapsed_ns, batch);
        // Main is everything but a pass that ran on workers.
        main_total += if (batch.ran_inline) elapsed_ns else elapsed_ns -| batch.batch_duration_ns;
        threaded_applies += @intFromBool(!batch.ran_inline);
    }
    if (options.iterations > 0 and heldRows(&fixture.data, fixture.player.entity) != fixture.held_rows) return error.WorldGateWrongHeldRows;
    var stats = accumulator.finish();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    if (case.adaptive) stats.work_tuning = suite.workTuningSummary(&gate.tuner, tuner_start);
    stats.output_count = bodies;
    stats.candidate_pairs = fixture.gated_rows;
    stats.sample_count = fixture.held_rows;
    stats.deferred_count = threaded_applies;
    return stats;
}

// `candidate_pairs` holds the gated rows, `sample_count` the held rows, and
// `deferred_count` the measured applies whose pass ran on workers.
fn writeGateWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("bodies={} gated={} held={}", .{ stats.output_count, stats.candidate_pairs, stats.sample_count });
    if (view == .summary) return;
    try writer.print(" threaded={}/{} ", .{ stats.deferred_count, stats.iterations });
    try suite.writeMainShare(writer, stats, stats.output_count);
}
