// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Pipeline-owned domain controller for player digging on a multi-Z-level world.
//! Consumes the per-step `dig_intent` captured in the input phase, resolves the
//! cell the player faces on their current plane, and authors a world-tile edit:
//!   - dig hole on the surface (level 0): punches a see-through hole
//!     (`clearDenseTile`) to fall to the plane below.
//!   - dig hole underground (level >= 1): carves a walkable tunnel floor through
//!     the solid dirt of the current plane so the player can mine forward.
//!   - dig down: punches a see-through hole in the faced cell on any plane to drop
//!     to the level below (no-op on the bottom plane).
//!   - dig ramp: carves a walkable ramp tile plus a bidirectional `LevelLink` to
//!     climb between planes.
//! Emits the resulting `world_tile_changed` event for the post-commit nav re-mask.

const std = @import("std");
const math = @import("../core/math.zig");
const InputState = @import("../app/input.zig").InputState;
const DataSystem = @import("data_system.zig").DataSystem;
const EntityId = @import("data_system.zig").EntityId;
const Facing = @import("data_system.zig").Facing;
const Player = @import("player.zig").Player;
const WorldSystem = @import("world_system.zig").WorldSystem;
const TileId = @import("world_system.zig").TileId;
const invalid_tile_id = @import("world_system.zig").invalid_tile_id;
const CellCoord = @import("world_system.zig").CellCoord;
const SimulationFrame = @import("simulation.zig").SimulationFrame;
const WorldTileChangedEvent = @import("simulation.zig").WorldTileChangedEvent;
const StimulusKind = @import("simulation.zig").StimulusKind;
const defaultStimulusIntensity = @import("simulation.zig").defaultStimulusIntensity;
const DigIntent = @import("simulation.zig").DigIntent;
const WorldTilesetMeta = @import("../assets/world_tileset_meta.zig").WorldTilesetMeta;
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;

/// Walkable tiles the dig carves, resolved by the gameplay state from the tileset
/// meta and passed in at pipeline init, so the controller stays free of asset
/// loading. `ramp_tile` climbs between planes; `tunnel_tile` is the walkable floor
/// left when mining forward through solid underground dirt.
pub const DigConfig = struct {
    // Default to the invalid sentinel, not tile 0: TileId 0 is a real,
    // movement-blocking tile, so a 0 default would silently carve it. Leaving
    // these unresolved trips the carve-path guard in `DigController.process`
    // rather than digging a wrong tile. `fromMeta`/`fromRuntimeAssets` resolve
    // them to valid ids.
    ramp_tile: TileId = invalid_tile_id,
    tunnel_tile: TileId = invalid_tile_id,

    /// Resolves the dig tiles by name from the world tileset metadata. `ramp_tile`
    /// climbs between planes; `tunnel_tile` is the walkable floor mined through
    /// solid underground dirt (also the tile a fall carves into its landing cell).
    pub fn fromMeta(meta: *const WorldTilesetMeta) !DigConfig {
        return .{
            .ramp_tile = (meta.tileByName("cobblestone") orelse return error.WorldTilesetMissingDigTile).id,
            .tunnel_tile = (meta.tileByName("cave_0") orelse return error.WorldTilesetMissingDigTile).id,
        };
    }

    pub fn fromRuntimeAssets(runtime_assets: *const RuntimeAssets) !DigConfig {
        const meta = runtime_assets.worldTilesetMeta() orelse return error.WorldTilesetMetadataUnavailable;
        return fromMeta(meta);
    }
};

pub const DigController = struct {
    ramp_tile: TileId,
    tunnel_tile: TileId,
    // Rising-edge latches so one held dig key digs one cell per press, not per frame.
    hole_held_last: bool = false,
    down_held_last: bool = false,
    ramp_held_last: bool = false,
    // Last grid cell the player occupied, so plane traversal (fall/ramp) fires only
    // on cell entry — anti-oscillation and the one-level-per-fall guard.
    player_last_cell: ?CellCoord = null,

    pub fn init(config: DigConfig) DigController {
        return .{ .ramp_tile = config.ramp_tile, .tunnel_tile = config.tunnel_tile };
    }

    /// Translates the held dig actions into this step's `dig_intent` on the rising
    /// edge so one press digs one cell. When several fire the same frame, hole
    /// (forward) wins, then down, then ramp. `process` consumes the intent.
    pub fn captureIntent(self: *DigController, input: *const InputState, frame: *SimulationFrame) void {
        const hole_held = input.isHeld(.dig_hole);
        const down_held = input.isHeld(.dig_down);
        const ramp_held = input.isHeld(.dig_ramp);
        if (hole_held and !self.hole_held_last) {
            frame.dig_intent = .hole;
        } else if (down_held and !self.down_held_last) {
            frame.dig_intent = .down;
        } else if (ramp_held and !self.ramp_held_last) {
            frame.dig_intent = .ramp;
        }
        self.hole_held_last = hole_held;
        self.down_held_last = down_held;
        self.ramp_held_last = ramp_held;
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

        // Fail loudly on an unresolved config rather than silently carving the
        // invalid sentinel into the world: reaching the carve path means the
        // controller's dig tiles must have been resolved to valid ids (via
        // `DigConfig.fromMeta`/`fromRuntimeAssets`). The sentinel defaults exist so
        // a controller that is never asked to dig need not resolve them.
        std.debug.assert(self.ramp_tile != invalid_tile_id);
        std.debug.assert(self.tunnel_tile != invalid_tile_id);

        const body = data.movementBodyConst(player.entity) orelse return;
        const facing = data.facingConst(player.entity) orelse return;
        const visual = data.primitiveVisualConst(player.entity) orelse return;

        const offset = facingOffset(facing.direction);
        const faced_x = body.position.x + visual.size.x * 0.5 + offset.x * world.tile_size;
        const faced_y = body.position.y + visual.size.y * 0.5 + offset.y * world.tile_size;
        const target = world.cellContaining(faced_x, faced_y) orelse return;
        const cell = CellCoord{ .x = target.x, .y = target.y };

        const floor_layer = world.denseFloorLayerForLevel(player.current_level) orelse return;
        // Intentional no-ops that never mutate return before the event preflight
        // so a full event budget cannot fail a dig that would have done nothing.
        if (intent == .down and @as(usize, player.current_level) + 1 >= world.levelCount()) return;
        if (intent == .ramp and (player.current_level == 0 or world.rampLinkOtherLevel(player.current_level, cell) != null)) return;

        // Reserve event + stimulus slots before any world mutate so a capacity miss
        // cannot leave the tile changed without matching outputs. digRamp also
        // preflights level_links capacity before its tile write.
        try frame.events.ensureEventAppendCapacity(1);
        try frame.ensureStimulusAppendCapacity(1);
        const changed = switch (intent) {
            // Surface: punch a see-through hole to fall through. Underground: mine a
            // walkable tunnel floor through the solid dirt of this plane.
            .hole => if (player.current_level == 0)
                try world.clearDenseTile(floor_layer, cell.x, cell.y)
            else
                try world.setDenseTile(floor_layer, cell.x, cell.y, self.tunnel_tile),
            // Dig down: punch a see-through hole in the faced cell on any plane to
            // drop to the level below. Bottom-plane no-op is handled above.
            .down => try world.clearDenseTile(floor_layer, cell.x, cell.y),
            .ramp => try self.digRamp(world, player.current_level, floor_layer, cell),
            .none => unreachable,
        } orelse return;

        try frame.events.appendRequired(.{
            .stage = .structural_commit,
            .payload = .{ .world_tile_changed = changed },
        });
        try frame.appendStimulus(.{
            .position = cellCenterWorldPos(world, cell),
            .intensity = defaultStimulusIntensity(.dig),
            .kind = .dig,
            .level = player.current_level,
        });
    }

    /// Carves a walkable ramp tile and adds a bidirectional ramp `LevelLink` to the
    /// plane above (ramps ascend — they exist to climb out of a pit). Caller has
    /// already filtered surface / existing-link no-ops; event + stimulus capacity is
    /// preflighted in `process` before this runs. Level-link capacity is reserved
    /// here before the tile write so an OOM cannot leave an orphan ramp tile.
    fn digRamp(self: *const DigController, world: *WorldSystem, level: u16, floor_layer: usize, cell: CellCoord) !?WorldTileChangedEvent {
        const above = level - 1;
        try world.ensureLevelLinkCapacity(1);
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

    /// Result of one entity's cell-entry plane traversal. `tile_change` is set when
    /// a fall carved its landing cell; callers batch these into one event range.
    pub const PlaneTraversalResult = struct {
        new_level: ?u16 = null,
        tile_change: ?WorldTileChangedEvent = null,
    };

    /// Updates the player's plane after movement. On entering a new cell: follow a
    /// ramp link to its other plane, else fall one level if standing over a hole
    /// with a level below (see `applyEntityPlaneTraversal`). The cell-entry guard
    /// (`player_last_cell`) advances only after a successful or intentional no-op
    /// traversal so a mid-transition error leaves the latch unchanged and the next
    /// step retries. Returns any landing-cell tile change for the caller's batch
    /// publish. NPCs share the same underlying traversal via
    /// `applyEntityPlaneTraversal`, called by `simulation_pipeline` with their own
    /// per-entity cell-entry guard (previous/current body centers).
    pub fn applyPlaneTraversal(self: *DigController, world: *WorldSystem, data: *DataSystem, player: *Player) !?WorldTileChangedEvent {
        const body = data.movementBodyConst(player.entity) orelse return null;
        const visual = data.primitiveVisualConst(player.entity) orelse return null;
        const center_x = body.position.x + visual.size.x * 0.5;
        const center_y = body.position.y + visual.size.y * 0.5;
        const target = world.cellContaining(center_x, center_y) orelse return null;
        const cell = CellCoord{ .x = target.x, .y = target.y };

        if (self.player_last_cell) |last| {
            if (last.x == cell.x and last.y == cell.y) return null;
        }

        const result = try self.applyEntityPlaneTraversal(world, data, player.entity, player.current_level, cell);
        if (result.new_level) |new_level| {
            player.current_level = new_level;
        }
        // Advance only after successful / intentional no-op traversal (no error).
        self.player_last_cell = cell;
        return result.tile_change;
    }

    /// Read-only: whether entering `cell` on `level` would fall and carve a landing
    /// cell that is not already the tunnel tile. Used to preflight event capacity
    /// before any world mutate in the plane-traversal stage.
    pub fn wouldCarveLandingCell(self: *const DigController, world: *const WorldSystem, level: u16, cell: CellCoord) bool {
        if (world.rampLinkOtherLevel(level, cell) != null) return false;
        const below: usize = @as(usize, level) + 1;
        if (below >= world.levelCount() or !world.denseFloorIsEmpty(level, cell.x, cell.y)) return false;
        const floor_layer = world.denseFloorLayerForLevel(@intCast(below)) orelse return false;
        return world.denseTile(floor_layer, cell.x, cell.y) != self.tunnel_tile;
    }

    /// Entity-generic plane traversal for one cell-entry event: follows a ramp
    /// link to its other plane, else falls one level if `cell` is a hole with a
    /// level below. Falling carves the landing cell walkable first — underground
    /// planes default to solid dirt, and landing embedded in it would have the
    /// tile gate shove the entity straight back out, a permanent soft-lock.
    /// Does not publish events: the caller batches `tile_change` values. Shared by
    /// the player (`applyPlaneTraversal`) and NPCs (`simulation_pipeline`).
    ///
    /// Attaches `world_level` (at the current plane) before any tile mutate so
    /// `setEntityLevel` cannot OOM after `carveLandingCell` has already written.
    /// Player.spawn pre-attaches level 0; NPCs should carry the component before
    /// the plane stage. Missing-component attach is the safety net.
    pub fn applyEntityPlaneTraversal(
        self: *const DigController,
        world: *WorldSystem,
        data: *DataSystem,
        entity: EntityId,
        level: u16,
        cell: CellCoord,
    ) !PlaneTraversalResult {
        // Allocation-free for entities that already have world_level; otherwise
        // attach at the current plane before any tile write.
        if (data.worldLevelConst(entity) == null) {
            try data.setWorldLevel(entity, level);
        }

        if (world.rampLinkOtherLevel(level, cell)) |other| {
            try setEntityLevel(world, data, entity, other, cell);
            return .{ .new_level = other };
        }
        const below: usize = @as(usize, level) + 1;
        if (below < world.levelCount() and world.denseFloorIsEmpty(level, cell.x, cell.y)) {
            const below_level: u16 = @intCast(below);
            // The plane below is solid dirt; carve the landing cell walkable so the
            // entity never lands embedded in rock (else the tile gate would shove
            // it straight back out). Carve only after world_level is known present
            // so setEntityLevel cannot fail from store growth mid-transition.
            const tile_change = try self.carveLandingCell(world, below_level, cell);
            try setEntityLevel(world, data, entity, below_level, cell);
            return .{ .new_level = below_level, .tile_change = tile_change };
        }
        return .{};
    }

    /// Carves a fall's landing cell to the walkable tunnel tile. Returns the tile
    /// change for the caller's batched event publish, or null when the level has
    /// no floor layer or the cell was already the tunnel tile. Does not emit a
    /// stimulus: this runs after this step's hearing read, so it would be cleared
    /// before ever seen. Caller must preflight event capacity before mutate.
    fn carveLandingCell(self: *const DigController, world: *WorldSystem, level: u16, cell: CellCoord) !?WorldTileChangedEvent {
        const floor_layer = world.denseFloorLayerForLevel(level) orelse return null;
        return try world.setDenseTile(floor_layer, cell.x, cell.y, self.tunnel_tile);
    }
};

fn cellCenterWorldPos(world: *const WorldSystem, cell: CellCoord) math.Vec2 {
    return .{
        .x = (@as(f32, @floatFromInt(cell.x)) + 0.5) * world.tile_size,
        .y = (@as(f32, @floatFromInt(cell.y)) + 0.5) * world.tile_size,
    };
}

/// Moves an entity onto a plane: tracks the level and snaps the body's render z
/// (and its previous, since z is not interpolated) to that plane's base. When
/// descending into a solid lower plane, also snaps x/y flush onto `cell` so the
/// one-tile-sized body sits inside the carved pocket rather than straddling the
/// solid neighbors the tile gate would otherwise shove it out of. Level 0 is fully
/// open, so no x/y snap there.
fn setEntityLevel(world: *const WorldSystem, data: *DataSystem, entity: EntityId, level: u16, cell: CellCoord) !void {
    try data.setWorldLevel(entity, level);
    const body = data.movementBodyPtr(entity) orelse return;
    body.snapZ(world.levelBaseZ(level));
    if (level == 0) return;
    const snap_x = @as(f32, @floatFromInt(cell.x)) * world.tile_size;
    const snap_y = @as(f32, @floatFromInt(cell.y)) * world.tile_size;
    body.position_x.* = snap_x;
    body.position_y.* = snap_y;
    body.previous_x.* = snap_x;
    body.previous_y.* = snap_y;
}

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
        .ramp_tile = (meta.tileByName("cobblestone") orelse return error.TestUnexpectedResult).id,
        .tunnel_tile = (meta.tileByName("cave_0") orelse return error.TestUnexpectedResult).id,
    });
}

/// Minimal multi-level grass/dirt world for dig/plane tests (not full 320 demo).
/// 8×8 tiles cover dig fixtures at cells (3,3)/(4,3) and edge off-world aim.
fn testMinimalMultiLevelWorld(meta: *const world_tileset_meta.WorldTilesetMeta) !WorldSystem {
    const bounds = meta.tileSize() * 8;
    return WorldSystem.initDemoFromMetaWithUnderground(std.testing.allocator, meta, bounds, bounds);
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
        var world = try testMinimalMultiLevelWorld(&meta);
        errdefer world.deinit();
        var data = DataSystem.init(std.testing.allocator);
        errdefer data.deinit();
        var player = try Player.spawn(&data);
        player.current_level = level;
        try data.setWorldLevel(player.entity, level);
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

    const stimuli = frame.stimuli.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), stimuli.len);
    try std.testing.expectEqual(StimulusKind.dig, stimuli[0].kind);
    try std.testing.expectEqual(@as(u16, 0), stimuli[0].level);
    try std.testing.expectEqual(@as(f32, 4.5) * tw.world.tile_size, stimuli[0].position.x);
    try std.testing.expectEqual(@as(f32, 3.5) * tw.world.tile_size, stimuli[0].position.y);
}

test "dig controller mines a walkable tunnel floor underground instead of a hole" {
    var tw = try TestWorld.init(.right, 1);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);

    const floor = tw.world.denseFloorLayerForLevel(1).?;
    // The faced underground cell starts as solid dirt.
    try std.testing.expect(tw.world.denseTileBlocksMovement(floor, 4, 3));

    var frame = try runDig(&tw, dig, .hole);
    defer frame.deinit();

    // Mining carves the walkable tunnel tile (not a see-through hole).
    try std.testing.expectEqual(dig.tunnel_tile, tw.world.denseTile(floor, 4, 3));
    try std.testing.expect(!tw.world.denseTileBlocksMovement(floor, 4, 3));

    const events = frame.events.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), events.len);
    const changed = switch (events[0].payload) {
        .world_tile_changed => |ch| ch,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u16, 1), changed.level);
    try std.testing.expect(changed.old_blocks_movement);
    try std.testing.expect(!changed.new_blocks_movement);

    const stimuli = frame.stimuli.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), stimuli.len);
    try std.testing.expectEqual(@as(u16, 1), stimuli[0].level);
}

test "dig controller down punches a drop hole through the faced cell underground" {
    var tw = try TestWorld.init(.right, 1);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);

    var frame = try runDig(&tw, dig, .down);
    defer frame.deinit();

    // The faced underground cell becomes a see-through, non-blocking hole to fall
    // through to the plane below (distinct from a walkable tunnel carve).
    const floor = tw.world.denseFloorLayerForLevel(1).?;
    try std.testing.expectEqual(invalid_tile_id, tw.world.denseTile(floor, 4, 3));

    const events = frame.events.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), events.len);
    const changed = switch (events[0].payload) {
        .world_tile_changed => |ch| ch,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(changed.old_blocks_movement);
    try std.testing.expect(!changed.new_blocks_movement);

    const stimuli = frame.stimuli.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), stimuli.len);
    try std.testing.expectEqual(@as(u16, 1), stimuli[0].level);
}

test "dig controller down is a no-op on the bottom plane" {
    var tw = try TestWorld.init(.right, 2);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);

    var frame = try runDig(&tw, dig, .down);
    defer frame.deinit();

    try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 0), frame.stimuli.mergedItems().len);
    // The bottom floor cell stays solid: there is nothing below to fall into.
    const floor = tw.world.denseFloorLayerForLevel(2).?;
    try std.testing.expect(tw.world.denseTileBlocksMovement(floor, 4, 3));
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

    const stimuli = frame.stimuli.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), stimuli.len);
    try std.testing.expectEqual(@as(u16, 1), stimuli[0].level);

    // Re-digging the same cell does not add a second link or a second stimulus.
    var frame2 = try runDig(&tw, dig, .ramp);
    defer frame2.deinit();
    try std.testing.expectEqual(@as(usize, 1), tw.world.levelLinks().len);
    try std.testing.expectEqual(@as(usize, 0), frame2.stimuli.mergedItems().len);
}

test "dig controller ramp is a no-op on the surface" {
    var tw = try TestWorld.init(.right, 0);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);

    var frame = try runDig(&tw, dig, .ramp);
    defer frame.deinit();

    try std.testing.expectEqual(@as(usize, 0), tw.world.levelLinks().len);
    try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 0), frame.stimuli.mergedItems().len);
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
    try std.testing.expectEqual(@as(usize, 0), none_frame.stimuli.mergedItems().len);

    var off_frame = try runDig(&tw, dig, .hole);
    defer off_frame.deinit();
    try std.testing.expectEqual(@as(usize, 0), off_frame.events.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 0), off_frame.stimuli.mergedItems().len);
}

test "dig controller applyEntityPlaneTraversal carves an NPC's landing cell before it falls" {
    var tw = try TestWorld.init(.right, 0);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);

    // Punch a fall-through hole in the surface floor, mirroring what a player's
    // `.down` dig produces, without carving level 1's landing cell — it stays
    // solid dirt by default, same as the underground-mining test above.
    const floor0 = tw.world.denseFloorLayerForLevel(0).?;
    _ = try tw.world.clearDenseTile(floor0, 4, 3);
    const floor1 = tw.world.denseFloorLayerForLevel(1).?;
    try std.testing.expect(tw.world.denseTileBlocksMovement(floor1, 4, 3));

    const npc = try tw.data.createEntity();
    try tw.data.setMovementBody(npc, .{});
    try tw.data.setPrimitiveVisual(npc, .{
        .size = .{ .x = 32, .y = 32 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    });

    const result = try dig.applyEntityPlaneTraversal(&tw.world, &tw.data, npc, 0, .{ .x = 4, .y = 3 });

    try std.testing.expectEqual(@as(?u16, 1), result.new_level);
    try std.testing.expectEqual(@as(?u16, 1), tw.data.worldLevelConst(npc));
    // The landing cell was carved walkable instead of leaving the NPC embedded in
    // solid dirt, which would have soft-locked it against the tile gate.
    try std.testing.expectEqual(dig.tunnel_tile, tw.world.denseTile(floor1, 4, 3));
    try std.testing.expect(!tw.world.denseTileBlocksMovement(floor1, 4, 3));
    try std.testing.expect(result.tile_change != null);
    try std.testing.expectEqual(dig.tunnel_tile, result.tile_change.?.new_tile_id);

    const body = tw.data.movementBodyConst(npc).?;
    try std.testing.expectEqual(@as(f32, 4 * 32), body.position.x);
    try std.testing.expectEqual(@as(f32, 3 * 32), body.position.y);
}

test "dig process reserves event capacity before world mutate (capacity miss leaves tile unchanged)" {
    var tw = try TestWorld.init(.right, 0);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    // Warm the streams then pin the event budget at zero so dig cannot append.
    try frame.reserveStreams(4, 0, 8, 8, 8, 8);
    frame.beginStep();
    frame.dig_intent = .hole;

    const floor = tw.world.denseFloorLayerForLevel(0).?;
    const before = tw.world.denseTile(floor, 4, 3);
    try std.testing.expect(before != invalid_tile_id);

    try std.testing.expectError(error.EventCapacityExceeded, dig.process(&tw.world, &tw.data, tw.player, &frame));
    try std.testing.expectEqual(before, tw.world.denseTile(floor, 4, 3));
    try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);
}

test "player_last_cell advances only after successful or intentional no-op traversal" {
    var tw = try TestWorld.init(.right, 0);
    defer tw.deinit();
    var dig = try testDigController(&tw.meta);

    // Hole under the player so the first cell-entry falls and carves.
    const floor0 = tw.world.denseFloorLayerForLevel(0).?;
    _ = try tw.world.clearDenseTile(floor0, 3, 3);
    // Seed last_cell elsewhere so (3,3) counts as a new entry.
    dig.player_last_cell = .{ .x = 0, .y = 0 };

    const change = try dig.applyPlaneTraversal(&tw.world, &tw.data, &tw.player);
    try std.testing.expect(change != null);
    try std.testing.expectEqual(@as(u16, 1), tw.player.current_level);
    try std.testing.expectEqual(@as(u16, 3), dig.player_last_cell.?.x);
    try std.testing.expectEqual(@as(u16, 3), dig.player_last_cell.?.y);

    // Same cell again: intentional no-op early return, latch unchanged.
    const no_change = try dig.applyPlaneTraversal(&tw.world, &tw.data, &tw.player);
    try std.testing.expect(no_change == null);
    try std.testing.expectEqual(@as(u16, 3), dig.player_last_cell.?.x);
}

test "player_last_cell stays put when plane traversal errors mid-transition" {
    var tw = try TestWorld.init(.right, 0);
    defer tw.deinit();
    var dig = try testDigController(&tw.meta);

    // Hole at (3,3): fall path pre-attaches world_level then carves. An invalid
    // entity fails the attach before any tile mutate — applyPlaneTraversal
    // assigns player_last_cell only after `try applyEntityPlaneTraversal`, so
    // this error must not be treated as a completed cell entry.
    const floor0 = tw.world.denseFloorLayerForLevel(0).?;
    _ = try tw.world.clearDenseTile(floor0, 3, 3);
    dig.player_last_cell = .{ .x = 0, .y = 0 };

    const floor1 = tw.world.denseFloorLayerForLevel(1).?;
    const landing_before = tw.world.denseTile(floor1, 3, 3);

    const dead = EntityId{ .index = 9999, .generation = 1 };
    try std.testing.expectError(
        error.InvalidEntity,
        dig.applyEntityPlaneTraversal(&tw.world, &tw.data, dead, 0, .{ .x = 3, .y = 3 }),
    );
    // Latch was never in applyEntityPlaneTraversal; still at the seeded value.
    try std.testing.expectEqual(@as(u16, 0), dig.player_last_cell.?.x);
    try std.testing.expectEqual(@as(u16, 0), dig.player_last_cell.?.y);
    // Pre-attach failure must not leave a carved landing cell.
    try std.testing.expectEqual(landing_before, tw.world.denseTile(floor1, 3, 3));

    // Missing body: applyPlaneTraversal returns early without advancing the latch
    // (incomplete entry, retry next step once the body is available).
    var ghost = tw.player;
    ghost.entity = dead;
    const no_body = try dig.applyPlaneTraversal(&tw.world, &tw.data, &ghost);
    try std.testing.expect(no_body == null);
    try std.testing.expectEqual(@as(u16, 0), dig.player_last_cell.?.x);
    try std.testing.expectEqual(@as(u16, 0), dig.player_last_cell.?.y);
}

test "plane traversal OOM on world_level attach leaves landing tile unchanged" {
    // Fresh DataSystem so world_levels capacity is zero: first attach must allocate.
    // (TestWorld's player already grew world_levels, which would hide the OOM.)
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    var world = try testMinimalMultiLevelWorld(&meta);
    defer world.deinit();
    const dig = try testDigController(&meta);

    const floor0 = world.denseFloorLayerForLevel(0).?;
    _ = try world.clearDenseTile(floor0, 4, 3);
    const floor1 = world.denseFloorLayerForLevel(1).?;
    const landing_before = world.denseTile(floor1, 4, 3);
    try std.testing.expect(world.denseTileBlocksMovement(floor1, 4, 3));

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const npc = try data.createEntity();
    try data.setMovementBody(npc, .{});
    try data.setPrimitiveVisual(npc, .{
        .size = .{ .x = 32, .y = 32 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    });
    try std.testing.expect(data.worldLevelConst(npc) == null);

    const original = data.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    data.allocator = failing.allocator();
    defer data.allocator = original;

    try std.testing.expectError(
        error.OutOfMemory,
        dig.applyEntityPlaneTraversal(&world, &data, npc, 0, .{ .x = 4, .y = 3 }),
    );
    try std.testing.expectEqual(landing_before, world.denseTile(floor1, 4, 3));
    try std.testing.expect(data.worldLevelConst(npc) == null);
}

test "player spawn pre-attaches world_level so first fall is allocation-free for the store" {
    var tw = try TestWorld.init(.right, 0);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);

    try std.testing.expectEqual(@as(?u16, 0), tw.data.worldLevelConst(tw.player.entity));

    const floor0 = tw.world.denseFloorLayerForLevel(0).?;
    _ = try tw.world.clearDenseTile(floor0, 3, 3);

    // Fail any further data allocations: setEntityLevel must only update the
    // existing world_level row (and scope metadata, which is non-allocating).
    const original = tw.data.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    tw.data.allocator = failing.allocator();
    defer tw.data.allocator = original;

    const result = try dig.applyEntityPlaneTraversal(
        &tw.world,
        &tw.data,
        tw.player.entity,
        0,
        .{ .x = 3, .y = 3 },
    );
    try std.testing.expectEqual(@as(?u16, 1), result.new_level);
    try std.testing.expectEqual(@as(?u16, 1), tw.data.worldLevelConst(tw.player.entity));
    try std.testing.expect(result.tile_change != null);
}

test "digRamp OOM on level_links growth leaves ramp tile unchanged" {
    var tw = try TestWorld.init(.right, 1);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);

    const floor = tw.world.denseFloorLayerForLevel(1).?;
    const before = tw.world.denseTile(floor, 4, 3);
    try std.testing.expect(before != dig.ramp_tile);

    // Exact capacity so the next ensureLevelLinkCapacity/append must grow.
    try tw.world.level_links.ensureTotalCapacityPrecise(std.testing.allocator, tw.world.level_links.items.len);
    const original = tw.world.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    tw.world.allocator = failing.allocator();
    defer tw.world.allocator = original;

    try std.testing.expectError(
        error.OutOfMemory,
        dig.digRamp(&tw.world, 1, floor, .{ .x = 4, .y = 3 }),
    );
    try std.testing.expectEqual(before, tw.world.denseTile(floor, 4, 3));
    try std.testing.expectEqual(@as(usize, 0), tw.world.levelLinks().len);
}

test "dig process stimulus capacity miss leaves tile unchanged" {
    var tw = try TestWorld.init(.right, 0);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    // Events get a slot; stimuli stay unreserved so ensureStimulusAppendCapacity fails.
    try frame.events.reserve(4, 8);
    frame.events.setCapacityLimit(8);
    frame.beginStep();
    frame.dig_intent = .hole;

    const floor = tw.world.denseFloorLayerForLevel(0).?;
    const before = tw.world.denseTile(floor, 4, 3);

    const original_stimuli = frame.stimuli.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    frame.stimuli.allocator = failing.allocator();
    defer frame.stimuli.allocator = original_stimuli;

    try std.testing.expectError(error.OutOfMemory, dig.process(&tw.world, &tw.data, tw.player, &frame));
    try std.testing.expectEqual(before, tw.world.denseTile(floor, 4, 3));
    try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 0), frame.stimuli.mergedItems().len);
}

test "dig controller captures intent once on the rising edge of a held key" {
    var dig = DigController.init(.{});
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();

    var input = InputState{};
    input.setHeld(.dig_hole, true);

    frame.beginStep();
    dig.captureIntent(&input, &frame);
    try std.testing.expectEqual(DigIntent.hole, frame.dig_intent);

    // Still held next step: no second dig.
    frame.beginStep();
    dig.captureIntent(&input, &frame);
    try std.testing.expectEqual(DigIntent.none, frame.dig_intent);

    // Release, then press again: the rising edge fires once more.
    input.setHeld(.dig_hole, false);
    frame.beginStep();
    dig.captureIntent(&input, &frame);
    try std.testing.expectEqual(DigIntent.none, frame.dig_intent);

    input.setHeld(.dig_hole, true);
    frame.beginStep();
    dig.captureIntent(&input, &frame);
    try std.testing.expectEqual(DigIntent.hole, frame.dig_intent);
}
