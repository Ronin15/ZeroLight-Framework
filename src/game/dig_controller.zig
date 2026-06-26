// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Pipeline-owned domain controller for player digging on a multi-Z-level world.
//! Consumes the per-step `dig_intent` captured in the input phase, resolves the
//! cell the player faces on their current plane, and either punches a see-through
//! hole (`clearDenseTile`) to fall through, or carves a walkable ramp tile plus a
//! `LevelLink` to climb between planes. Emits the resulting `world_tile_changed`
//! event for the post-commit nav re-mask.

const std = @import("std");
const math = @import("../core/math.zig");
const DataSystem = @import("data_system.zig").DataSystem;
const Facing = @import("data_system.zig").Facing;
const Player = @import("player.zig").Player;
const WorldSystem = @import("world_system.zig").WorldSystem;
const TileId = @import("world_system.zig").TileId;
const CellCoord = @import("world_system.zig").CellCoord;
const SimulationFrame = @import("simulation.zig").SimulationFrame;
const WorldTileChangedEvent = @import("simulation.zig").WorldTileChangedEvent;

/// The walkable ramp tile the dig carves, resolved by the gameplay state from the
/// tileset meta and passed in at pipeline init, so the controller stays free of
/// asset loading.
pub const DigConfig = struct {
    ramp_tile: TileId = 0,
};

pub const DigController = struct {
    ramp_tile: TileId,

    pub fn init(config: DigConfig) DigController {
        return .{ .ramp_tile = config.ramp_tile };
    }

    /// Applies this step's dig intent to the cell the player faces on their current
    /// plane. No-op when there is no intent, the player lacks a body/facing, the
    /// plane has no floor layer, or the faced cell is off-world. Emits one
    /// `world_tile_changed` event on an actual change.
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
        const target = world.cellContaining(faced_x, faced_y) orelse return;
        const cell = CellCoord{ .x = target.x, .y = target.y };

        const floor_layer = world.denseFloorLayerForLevel(player.current_level) orelse return;
        const changed = switch (intent) {
            .hole => try world.clearDenseTile(floor_layer, cell.x, cell.y),
            .ramp => try self.digRamp(world, player.current_level, floor_layer, cell),
            .none => unreachable,
        } orelse return;

        try frame.events.appendRequired(.{
            .stage = .structural_commit,
            .payload = .{ .world_tile_changed = changed },
        });
    }

    /// Carves a walkable ramp tile and adds a bidirectional ramp `LevelLink` to the
    /// plane above (ramps ascend — they exist to climb out of a pit). No-op on the
    /// surface (nothing above) or when a ramp link already covers the cell.
    fn digRamp(self: *const DigController, world: *WorldSystem, level: u16, floor_layer: usize, cell: CellCoord) !?WorldTileChangedEvent {
        if (level == 0) return null;
        if (world.rampLinkOtherLevel(level, cell) != null) return null;
        const above = level - 1;
        const changed = try world.setDenseTile(floor_layer, cell.x, cell.y, self.ramp_tile);
        try world.addLevelLink(.{
            .kind = .ramp,
            .level_a = level,
            .cell_a = cell,
            .level_b = above,
            .cell_b = cell,
            .traversal_cost = 1,
            .bidirectional = true,
        });
        return changed;
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
const invalid_tile_id = @import("world_system.zig").invalid_tile_id;

fn testDigController(meta: anytype) !DigController {
    return DigController.init(.{
        .ramp_tile = (meta.tileByName("cobblestone") orelse return error.TestUnexpectedResult).id,
    });
}

const TestWorld = struct {
    meta: world_tileset_meta.WorldTilesetMeta,
    world: WorldSystem,
    data: DataSystem,
    player: Player,

    fn init(facing: Facing, level: u16) !TestWorld {
        const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
        var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
        errdefer meta.deinit();
        var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 320, 320);
        errdefer world.deinit();
        try world.addUndergroundLevels(&meta);
        var data = DataSystem.init(std.testing.allocator);
        errdefer data.deinit();
        var player = try Player.spawn(&data);
        player.current_level = level;
        // Cell (3,3) top-left, facing right -> faced cell (4,3).
        const body = data.movementBodyPtr(player.entity).?;
        body.position_x.* = 96;
        body.position_y.* = 96;
        data.facingPtr(player.entity).?.* = facing;
        return .{ .meta = meta, .world = world, .data = data, .player = player };
    }

    fn deinit(self: *TestWorld) void {
        self.data.deinit();
        self.world.deinit();
        self.meta.deinit();
    }
};

fn runDig(tw: *TestWorld, dig: DigController, intent: @import("simulation.zig").DigIntent) !SimulationFrame {
    var frame = SimulationFrame.init(std.testing.allocator);
    errdefer frame.deinit();
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    frame.beginStep();
    frame.dig_intent = intent;
    try dig.process(&tw.world, &tw.data, tw.player, &frame);
    return frame;
}

test "dig controller punches a see-through hole in the faced cell" {
    var tw = try TestWorld.init(.right, 0);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);

    var frame = try runDig(&tw, dig, .hole);
    defer frame.deinit();

    const floor = tw.world.denseFloorLayerForLevel(0).?;
    try std.testing.expectEqual(invalid_tile_id, tw.world.denseTile(floor, 4, 3));

    const events = frame.events.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), events.len);
    const changed = switch (events[0].payload) {
        .world_tile_changed => |c| c,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u16, 4), changed.x);
    try std.testing.expectEqual(@as(u16, 3), changed.y);
    try std.testing.expectEqual(invalid_tile_id, changed.new_tile_id);
    try std.testing.expect(!changed.new_blocks_movement);
}

test "dig controller carves a ramp tile and one bidirectional link below the surface" {
    var tw = try TestWorld.init(.right, 1);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);

    var frame = try runDig(&tw, dig, .ramp);
    defer frame.deinit();

    const floor = tw.world.denseFloorLayerForLevel(1).?;
    try std.testing.expectEqual(dig.ramp_tile, tw.world.denseTile(floor, 4, 3));

    const links = tw.world.levelLinks();
    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expectEqual(@import("world_system.zig").LevelLinkKind.ramp, links[0].kind);
    try std.testing.expect(links[0].bidirectional);
    try std.testing.expectEqual(@as(u16, 1), links[0].level_a);
    try std.testing.expectEqual(@as(u16, 0), links[0].level_b);
    try std.testing.expectEqual(@as(u16, 4), links[0].cell_a.x);
    try std.testing.expectEqual(@as(u16, 3), links[0].cell_a.y);

    // Re-digging the same cell does not add a second link.
    var frame2 = try runDig(&tw, dig, .ramp);
    defer frame2.deinit();
    try std.testing.expectEqual(@as(usize, 1), tw.world.levelLinks().len);
}

test "dig controller ramp is a no-op on the surface" {
    var tw = try TestWorld.init(.right, 0);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);

    var frame = try runDig(&tw, dig, .ramp);
    defer frame.deinit();

    try std.testing.expectEqual(@as(usize, 0), tw.world.levelLinks().len);
    try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);
}

test "dig controller is a no-op for none intent or an off-world target" {
    var tw = try TestWorld.init(.left, 0);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);
    // Facing left from the left edge aims off-world.
    const body = tw.data.movementBodyPtr(tw.player.entity).?;
    body.position_x.* = 0;
    body.position_y.* = 96;

    var none_frame = try runDig(&tw, dig, .none);
    defer none_frame.deinit();
    try std.testing.expectEqual(@as(usize, 0), none_frame.events.mergedItems().len);

    var off_frame = try runDig(&tw, dig, .hole);
    defer off_frame.deinit();
    try std.testing.expectEqual(@as(usize, 0), off_frame.events.mergedItems().len);
}
