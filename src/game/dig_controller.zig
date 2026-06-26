// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Pipeline-owned domain controller for player digging. Consumes the per-step
//! `dig_intent` captured in the input phase, resolves the tile the player faces,
//! applies the depth policy via `WorldSystem.setDenseTile`, and emits the
//! resulting `world_tile_changed` event for the post-commit nav re-mask.

const std = @import("std");
const math = @import("../core/math.zig");
const DataSystem = @import("data_system.zig").DataSystem;
const Facing = @import("data_system.zig").Facing;
const Player = @import("player.zig").Player;
const WorldSystem = @import("world_system.zig").WorldSystem;
const TileId = @import("world_system.zig").TileId;
const SimulationFrame = @import("simulation.zig").SimulationFrame;

/// Tile ids and target layer the dig depth policy operates on. Resolved by the
/// gameplay state from the tileset meta and passed in at pipeline init, so the
/// controller stays free of asset loading.
pub const DigConfig = struct {
    ground_layer: usize = 0,
    surface_id: TileId = 0,
    dirt_id: TileId = 0,
    pit_id: TileId = 0,
};

pub const DigController = struct {
    ground_layer: usize,
    surface_id: TileId,
    dirt_id: TileId,
    pit_id: TileId,

    pub fn init(config: DigConfig) DigController {
        return .{
            .ground_layer = config.ground_layer,
            .surface_id = config.surface_id,
            .dirt_id = config.dirt_id,
            .pit_id = config.pit_id,
        };
    }

    /// Next tile one level deeper: surface -> dirt -> pit -> (null, deepest).
    pub fn digDownTile(self: *const DigController, current: TileId) ?TileId {
        if (current == self.pit_id) return null;
        if (current == self.dirt_id) return self.pit_id;
        return self.dirt_id;
    }

    /// Next tile one level shallower: pit -> dirt -> surface -> (null, surface).
    pub fn digUpTile(self: *const DigController, current: TileId) ?TileId {
        if (current == self.pit_id) return self.dirt_id;
        if (current == self.dirt_id) return self.surface_id;
        return null;
    }

    /// Applies this step's dig intent to the cell the player faces. No-op when
    /// there is no intent, the player lacks a body/facing, or the faced cell is
    /// off-world. Emits one `world_tile_changed` event on an actual change.
    pub fn process(
        self: *const DigController,
        world: *WorldSystem,
        data: *const DataSystem,
        player: Player,
        frame: *SimulationFrame,
    ) !void {
        const intent = frame.dig_intent;
        if (intent == .none) return;

        const body = data.movementBodyConst(player.entity) orelse return;
        const facing = data.facingConst(player.entity) orelse return;
        const visual = data.primitiveVisualConst(player.entity) orelse return;

        const offset = facingOffset(facing.direction);
        const faced_x = body.position.x + visual.size.x * 0.5 + offset.x * world.tile_size;
        const faced_y = body.position.y + visual.size.y * 0.5 + offset.y * world.tile_size;
        const cell = world.cellContaining(faced_x, faced_y) orelse return;

        const current = world.denseTile(self.ground_layer, cell.x, cell.y);
        const next = switch (intent) {
            .down => self.digDownTile(current),
            .up => self.digUpTile(current),
            .none => unreachable,
        } orelse return;

        const changed = (try world.setDenseTile(self.ground_layer, cell.x, cell.y, next)) orelse return;
        try frame.events.appendRequired(.{
            .stage = .structural_commit,
            .payload = .{ .world_tile_changed = changed },
        });
    }
};

fn facingOffset(direction: Facing) math.Vec2 {
    return switch (direction) {
        .up => .{ .x = 0, .y = -1 },
        .down => .{ .x = 0, .y = 1 },
        .left => .{ .x = -1, .y = 0 },
        .right => .{ .x = 1, .y = 0 },
    };
}

const AssetStore = @import("../assets/assets.zig").AssetStore;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");

fn testDigController(meta: anytype) !DigController {
    return DigController.init(.{
        .ground_layer = 0,
        .surface_id = (meta.tileByName("grass") orelse return error.TestUnexpectedResult).id,
        .dirt_id = (meta.tileByName("dirt") orelse return error.TestUnexpectedResult).id,
        .pit_id = (meta.tileByName("void_pit") orelse return error.TestUnexpectedResult).id,
    });
}

test "dig controller depth policy cycles surface dirt and pit" {
    const dig = DigController.init(.{ .ground_layer = 0, .surface_id = 0, .dirt_id = 4, .pit_id = 15 });

    try std.testing.expectEqual(@as(?TileId, 4), dig.digDownTile(0));
    try std.testing.expectEqual(@as(?TileId, 15), dig.digDownTile(4));
    try std.testing.expectEqual(@as(?TileId, null), dig.digDownTile(15));

    try std.testing.expectEqual(@as(?TileId, 4), dig.digUpTile(15));
    try std.testing.expectEqual(@as(?TileId, 0), dig.digUpTile(4));
    try std.testing.expectEqual(@as(?TileId, null), dig.digUpTile(0));
}

test "dig controller digs the faced cell and emits a world tile event" {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 320, 320);
    defer world.deinit();

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);
    // Cell (3,3) top-left, facing right -> faced cell (4,3).
    const body = data.movementBodyPtr(player.entity).?;
    body.position_x.* = 96;
    body.position_y.* = 96;
    data.facingPtr(player.entity).?.* = .right;

    const dig = try testDigController(&meta);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    frame.beginStep();
    frame.dig_intent = .down;

    const before = world.denseTile(0, 4, 3);
    try dig.process(&world, &data, player, &frame);

    const events = frame.events.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), events.len);
    const changed = switch (events[0].payload) {
        .world_tile_changed => |c| c,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u16, 4), changed.x);
    try std.testing.expectEqual(@as(u16, 3), changed.y);
    try std.testing.expectEqual(dig.digDownTile(before).?, world.denseTile(0, 4, 3));
}

test "dig controller is a no-op when facing off-world or intent is none" {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 320, 320);
    defer world.deinit();

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);
    const body = data.movementBodyPtr(player.entity).?;
    body.position_x.* = 0;
    body.position_y.* = 96;
    data.facingPtr(player.entity).?.* = .left; // faced point is negative x -> off-world

    const dig = try testDigController(&meta);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    frame.beginStep();

    // No intent: nothing happens.
    try dig.process(&world, &data, player, &frame);
    try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);

    // Intent but off-world target: still nothing.
    frame.dig_intent = .down;
    try dig.process(&world, &data, player, &frame);
    try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);
}
