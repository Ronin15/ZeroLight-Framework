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
const SimulationTier = @import("../game/simulation_scope.zig").SimulationTier;
const WorldGateConfig = @import("../game/systems/world_gate.zig").WorldGateConfig;
const WorldGateSystem = @import("../game/systems/world_gate.zig").WorldGateSystem;
const world_gate_range_alignment_items = @import("../game/systems/world_gate.zig").world_gate_range_alignment_items;
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

const GateShape = enum(u8) { uniform, interleaved };
const GateFields = struct { shape: GateShape, bodies: u32 };
const GateCode = suite.ItemCode(GateFields, &.{6});

const item_counts = [_]usize{
    GateCode.of(.{ .shape = .uniform, .bodies = 4_096 }),
    GateCode.of(.{ .shape = .uniform, .bodies = 16_384 }),
    GateCode.of(.{ .shape = .uniform, .bodies = 65_536 }),
    GateCode.of(.{ .shape = .interleaved, .bodies = 4_096 }),
    GateCode.of(.{ .shape = .interleaved, .bodies = 16_384 }),
    GateCode.of(.{ .shape = .interleaved, .bodies = 65_536 }),
};

// The fixed world: a surface and the gated levels, each of this side in tiles.
const gate_level_side: u16 = 256;
const gate_levels = [_]u16{ 1, 2 };
const body_size: f32 = 20;
// The player's box, the size the demo gives it.
const player_size: f32 = 32;
// Each body's settled step from its previous position, so both gate axes test a move.
const step_offset = math.Vec2{ .x = 3, .y = 2 };

// What one body row is: whether the pass gates it, and on which level.
const RowKind = enum { non_ai, dormant, gated };

const BodyRow = struct { kind: RowKind, level: u16 };

fn bodyRow(shape: GateShape, index: usize) BodyRow {
    return switch (shape) {
        .uniform => .{ .kind = .gated, .level = gate_levels[0] },
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
        .interleaved => gate_levels[1] + 1,
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
fn buildWorld(allocator: std.mem.Allocator, io: std.Io, shape: GateShape) !WorldSystem {
    var tileset = try fixtures.loadTilesetMeta(allocator, io);
    defer tileset.deinit();
    const meta = &tileset;
    const levels = levelCount(shape);
    var world = try fixtures.buildBandedWorld(allocator, meta, gate_level_side, levels, "grass", "grass");
    errdefer world.deinit();
    const solid = try world.requireTileByName(meta, "dirt");
    const walkable = try world.requireTileByName(meta, "grass");
    for (1..levels) |level| {
        const floor = world.denseFloorLayerForLevel(@intCast(level)) orelse return error.InvalidWorldLevel;
        for (0..gate_level_side) |y| {
            for (0..gate_level_side) |x| {
                _ = try world.setDenseTile(floor, @intCast(x), @intCast(y), if ((x + y) % 2 == 0) walkable else solid);
            }
        }
    }
    return world;
}

fn buildFixture(allocator: std.mem.Allocator, io: std.Io, shape: GateShape, bodies: usize) !Fixture {
    var world = try buildWorld(allocator, io, shape);
    errdefer world.deinit();
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const player = try Player.spawn(&data);
    try data.setCollisionBounds(player.entity, .{ .size = .{ .x = player_size, .y = player_size } });

    const tile = world.tile_size;
    // A body and its step stay inside its start tile on both axes.
    std.debug.assert(body_size + step_offset.x < tile and body_size + step_offset.y < tile);
    const grid_side = suite.ceilSqrt(bodies);
    if (grid_side > gate_level_side) return error.WorldGateGridPastLevel;
    const pitch_tiles = gate_level_side / grid_side;
    var gated_rows: usize = 0;
    var held_rows: usize = 0;
    for (0..bodies) |index| {
        const column = index % grid_side;
        const row = index / grid_side;
        // Checkerboard of bodies: odd ones start on a solid tile, even ones on a walkable one.
        const solid = (column + row) % 2 == 1;
        var tile_x = column * pitch_tiles;
        const tile_y = row * pitch_tiles;
        // The floor is walkable where the tile parity is even; a body whose pitch tile has the
        // other parity shifts one tile along x, back from the level's last column.
        if (((tile_x + tile_y) % 2 == 1) != solid) tile_x = if (tile_x + 1 < gate_level_side) tile_x + 1 else tile_x - 1;
        const body = bodyRow(shape, index);
        gated_rows += @intFromBool(body.kind == .gated);
        held_rows += @intFromBool(body.kind == .dormant or (body.kind == .gated and solid));
        const previous = math.Vec2{
            .x = @as(f32, @floatFromInt(tile_x)) * tile,
            .y = @as(f32, @floatFromInt(tile_y)) * tile,
        };
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
            .chunk = world.chunkCoordForWorldPos(position.x, position.y),
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
