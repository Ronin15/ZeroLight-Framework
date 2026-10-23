// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! `world-gate`: one `world_gate.apply` (the bounds clamp and the solid-tile gate of a
//! settled movement step) over AI bodies on an underground level whose floor alternates
//! walkable and solid tiles, plus the player on the surface. Each body starts and steps
//! inside one tile, a checkerboard of bodies on walkable and on solid tiles whatever the grid
//! pitch, so every size gates the same half and per-body work is the same at every size. Pass
//! shape: linear in bodies. The gate is scalar and serial on the main thread today, so
//! `serial-direct` is its one case. Asserts check the fixture's body count and that the
//! timed applies gate exactly the solid-start half (each held at its previous position).

const std = @import("std");
const math = @import("../core/math.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const Player = @import("../game/player.zig").Player;
const world_gate = @import("../game/systems/world_gate.zig");
const WorldSystem = @import("../game/world/system.zig").WorldSystem;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "world-gate",
    .item_label = "gated bodies",
    .item_counts = &item_counts,
    .runCase = runCase,
    .write_workload = writeGateWorkload,
    .cases = &suite.serial_cases,
};

const item_counts = [_]usize{ 4_096, 16_384, 65_536 };

// The fixed world: a surface and one gated level of this side in tiles.
const gate_level_side: u16 = 256;
const gate_level: u16 = 1;
const body_size: f32 = 20;
// Each body's settled step from its previous position, so both gate axes test a move.
const step_offset = math.Vec2{ .x = 3, .y = 2 };

const Fixture = struct {
    world: WorldSystem,
    data: DataSystem,
    player: Player,
    // Bodies whose start tile is solid: the gate holds exactly these.
    solid_starts: usize,

    fn deinit(self: *Fixture) void {
        self.data.deinit();
        self.world.deinit();
        self.* = undefined;
    }
};

// The gated level's floor alternates walkable and solid tiles in a checkerboard.
fn buildWorld(allocator: std.mem.Allocator, io: std.Io) !WorldSystem {
    var tileset = try fixtures.loadTilesetMeta(allocator, io);
    defer tileset.deinit();
    const meta = &tileset;
    var world = try fixtures.buildBandedWorld(allocator, meta, gate_level_side, gate_level + 1, "grass", "grass");
    errdefer world.deinit();
    const solid = try world.requireTileByName(meta, "dirt");
    const walkable = try world.requireTileByName(meta, "grass");
    const floor = world.denseFloorLayerForLevel(gate_level) orelse return error.InvalidWorldLevel;
    for (0..gate_level_side) |y| {
        for (0..gate_level_side) |x| {
            _ = try world.setDenseTile(floor, @intCast(x), @intCast(y), if ((x + y) % 2 == 0) walkable else solid);
        }
    }
    return world;
}

fn buildFixture(allocator: std.mem.Allocator, io: std.Io, bodies: usize) !Fixture {
    var world = try buildWorld(allocator, io);
    errdefer world.deinit();
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const player = try Player.spawn(&data);

    const tile = world.tile_size;
    // A body and its step stay inside its start tile on both axes.
    std.debug.assert(body_size + step_offset.x < tile and body_size + step_offset.y < tile);
    const grid_side = suite.ceilSqrt(bodies);
    if (grid_side > gate_level_side) return error.WorldGateGridPastLevel;
    const pitch_tiles = gate_level_side / grid_side;
    var solid_starts: usize = 0;
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
        solid_starts += @intFromBool(solid);
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
        try data.setAiAgent(entity, .{ .active_behavior = .wander });
        try data.setWorldLevel(entity, gate_level);
        try data.setSimulationMetadata(entity, .{
            .tier = .locomotion,
            .chunk = world.chunkCoordForWorldPos(position.x, position.y),
            .level = gate_level,
        });
    }
    std.debug.assert(data.aiAgentSliceConst().entities.len == bodies);
    return .{ .world = world, .data = data, .player = player, .solid_starts = solid_starts };
}

// The AI bodies the gate holds at their previous position on both axes.
fn heldBodies(data: *const DataSystem) usize {
    const movement = data.movementBodySliceConst();
    var held: usize = 0;
    for (data.aiAgentSliceConst().entities) |entity| {
        const row = data.movementBodyDenseIndex(entity).?;
        held += @intFromBool(movement.position_x[row] == movement.previous_x[row] and movement.position_y[row] == movement.previous_y[row]);
    }
    return held;
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    std.debug.assert(!case.usesThreadSystem());
    var fixture = try buildFixture(allocator, io, item_count);
    defer fixture.deinit();
    const bounds = fixture.world.worldWidthPixels();

    for (0..options.warmup_iterations) |_| {
        try world_gate.apply(&fixture.world, &fixture.data, &fixture.player, bounds, bounds);
    }
    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        try world_gate.apply(&fixture.world, &fixture.data, &fixture.player, bounds, bounds);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), .{});
    }
    if (options.iterations > 0 and heldBodies(&fixture.data) != fixture.solid_starts) return error.WorldGateWrongGatedBodies;
    var stats = accumulator.finish();
    stats.output_count = fixture.data.aiAgentSliceConst().entities.len;
    stats.sample_count = fixture.solid_starts;
    return stats;
}

fn writeGateWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("bodies={} gated={} level={}", .{ stats.output_count, stats.sample_count, gate_level });
}
