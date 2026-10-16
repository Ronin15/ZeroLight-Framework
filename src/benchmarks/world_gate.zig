// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! `world-gate`: one `world_gate.apply` (the bounds clamp and the solid-tile gate of a
//! settled movement step) over AI bodies on an underground level whose floor alternates
//! walkable and solid tiles, plus the player on the surface. Pass shape: linear in bodies,
//! dispatched across workers with a SIMD tile test; the gate has a serial main-thread path
//! only, so `serial-direct` is its one case. Asserts check only the fixture's body count.

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
    .defaultItemCounts = defaultItemCounts,
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

fn defaultItemCounts(_: suite.Profile) []const usize {
    return &item_counts;
}

const Fixture = struct {
    world: WorldSystem,
    data: DataSystem,
    player: Player,

    fn deinit(self: *Fixture) void {
        self.data.deinit();
        self.world.deinit();
        self.* = undefined;
    }
};

// The gated level's floor alternates walkable and solid tiles in a checkerboard.
fn buildWorld(allocator: std.mem.Allocator, io: std.Io) !WorldSystem {
    var world = try fixtures.buildBandedWorld(allocator, io, gate_level_side, gate_level + 1, "grass", "grass");
    errdefer world.deinit();
    const meta = world.tilesetMeta().?;
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

    const level_px = world.worldWidthPixels();
    const grid_side = suite.ceilSqrt(bodies);
    const pitch = level_px / @as(f32, @floatFromInt(grid_side));
    for (0..bodies) |index| {
        const previous = math.Vec2{
            .x = @as(f32, @floatFromInt(index % grid_side)) * pitch,
            .y = @as(f32, @floatFromInt(index / grid_side)) * pitch,
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
    return .{ .world = world, .data = data, .player = player };
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
    var stats = accumulator.finish();
    stats.output_count = fixture.data.aiAgentSliceConst().entities.len;
    return stats;
}

fn writeGateWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("bodies={} level={}", .{ stats.output_count, gate_level });
}
