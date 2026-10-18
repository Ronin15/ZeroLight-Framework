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
//!     climb between planes, and clears its exit cell on the plane above walkable.
//! Emits the resulting `world_tile_changed` event (and a ramp exit's
//! `world_obstacle_changed`) for the post-commit nav re-mask.

const std = @import("std");
const builtin = @import("builtin");
const logging = @import("../core/logging.zig");
const math = @import("../core/math.zig");
const InputState = @import("../app/input.zig").InputState;
const DataSystem = @import("data_system.zig").DataSystem;
const EntityId = @import("data_system.zig").EntityId;
const Facing = @import("data_system.zig").Facing;
const Player = @import("player.zig").Player;
const WorldSystem = @import("world/system.zig").WorldSystem;
const TileId = @import("world/system.zig").TileId;
const invalid_tile_id = @import("world/system.zig").invalid_tile_id;
const CellCoord = @import("world/system.zig").CellCoord;
const LevelLink = @import("world/system.zig").LevelLink;
const SimulationFrame = @import("simulation.zig").SimulationFrame;
const SimulationEvent = @import("simulation.zig").SimulationEvent;
const WorldTileChangedEvent = @import("simulation.zig").WorldTileChangedEvent;
const WorldObstacleChangedEvent = @import("simulation.zig").WorldObstacleChangedEvent;
const StimulusKind = @import("simulation.zig").StimulusKind;
const defaultStimulusIntensity = @import("simulation.zig").defaultStimulusIntensity;
const DigIntent = @import("simulation.zig").DigIntent;
const maxEventsPerStep = @import("simulation.zig").maxEventsPerStep;
const stimulus_live_capacity = @import("simulation.zig").stimulus_live_capacity;
const SensoryBus = @import("sensory_bus.zig").SensoryBus;
const WorldTilesetMeta = @import("../assets/world_tileset_meta.zig").WorldTilesetMeta;
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const PlaneEntry = @import("systems/plane_entry.zig").PlaneEntry;
const PlaneTarget = @import("systems/plane_entry.zig").PlaneTarget;
const planeTarget = @import("systems/plane_entry.zig").planeTarget;
const no_landing_layer = @import("systems/plane_entry.zig").no_landing_layer;
const WorldEditError = @import("world/system.zig").WorldEditError;
const DenseCellWrite = @import("world/edit.zig").DenseCellWrite;
const DenseChunkWrites = @import("world/edit.zig").DenseChunkWrites;
const TerrainEditThreads = @import("world/edit.zig").TerrainEditThreads;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const StageControls = @import("../app/thread_system.zig").StageControls;
const StampedTable = @import("stamped_table.zig").StampedTable;

/// Walkable tiles the dig carves, resolved by the gameplay state from the tileset
/// meta and passed in at pipeline init, so the controller stays free of asset
/// loading. `ramp_tile` climbs between planes; `tunnel_tile` is the walkable floor
/// left when mining forward through solid underground dirt.
pub const DigConfig = struct {
    // Default to the invalid sentinel, not tile 0: TileId 0 is a real,
    // movement-blocking tile, so a 0 default would silently carve it. Leaving
    // these unresolved returns `error.UnresolvedDigTiles` from `reserveWorldEdit` before
    // any world mutate (ReleaseFast-safe; not a Debug-only assert).
    // `fromMeta`/`fromRuntimeAssets` resolve them to valid ids.
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

/// What a dig's reserve and commit can fail with; each leaves the world unchanged.
pub const DigEditError = WorldEditError || error{
    UnresolvedDigTiles,
    StimulusCapacityExceeded,
    EventCapacityExceeded,
};

/// What the plane stage's reserve and commit can fail with. The reserve fails before any
/// write; the commit's only growth is its carve batch's terrain pools (counted), which
/// fails before any terrain write.
pub const PlaneStageError = WorldEditError || error{
    PlaneScratchUnreserved,
    UnorderedDenseChunkWrites,
    EventCapacityExceeded,
    InvalidEntity,
    TooManyWorldLevelRows,
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
    /// One step's plane-traversal scratch, each list reserved at pipeline init to the
    /// `.plane_traversal` event budget (the player plus every AI row): the traversals
    /// the reserve decides (`plane_moves`), the carves in decision order
    /// (`plane_carves`) and grouped by chunk for the batched write (`plane_carve_next`,
    /// `plane_carve_writes`, `plane_carve_chunks`), and the carves' tile changes
    /// (`plane_tile_changes`). `reservePlaneTraversalStage` grows them before anything is
    /// written when a step's entries exceed the reservation, counting it in
    /// `plane_scratch_grown`; after that the step only appends into reserved capacity.
    plane_moves: std.ArrayList(PlaneMove) = .empty,
    /// The landing cells this step's falls carve, keyed `(level, cell)`. Reserved with
    /// the lists above, so a step allocates nothing; a step clears it in O(1), so its
    /// size costs memory only, never per-step work.
    plane_claims: PlaneClaims = .{},
    /// Range controls of the commit's carve batch, whose stages the world's terrain-edit
    /// tuners drive by default; pinned only for benchmark and test partitions.
    carve_controls: StageControls = .{},
    plane_carves: std.ArrayList(DenseCellWrite) = .empty,
    plane_carve_next: std.ArrayList(u32) = .empty,
    plane_carve_writes: std.ArrayList(DenseCellWrite) = .empty,
    plane_carve_chunks: std.ArrayList(DenseChunkWrites) = .empty,
    plane_tile_changes: std.ArrayList(WorldTileChangedEvent) = .empty,
    /// The declared traversal reservation (`reservePlaneScratch` /
    /// `ensurePlaneScratchReserve`). Drift telemetry compares against this, never a
    /// list's capacity, which `ensureTotalCapacity` rounds past it.
    plane_scratch_reserved: usize = 0,
    scratch_allocator: ?std.mem.Allocator = null,
    /// Telemetry: plane-traversal steps whose possible traversals (the player's cell
    /// entry and the gathered entries) exceeded `plane_scratch_reserved` (perf metric
    /// `dig_plane_scratch_grown`), whether or not the scratch's rounded-up capacity
    /// absorbed it; the stage grows the scratch first when it did not. Nonzero means the
    /// `.plane_traversal` reservation is short of the live population; the first such
    /// step warns once.
    plane_scratch_grown: u64 = 0,

    pub fn init(config: DigConfig) DigController {
        return .{ .ramp_tile = config.ramp_tile, .tunnel_tile = config.tunnel_tile };
    }

    /// Translates the held dig actions into this step's `dig_intent` on the rising
    /// edge so one press digs one cell. When several fire the same frame, hole
    /// (forward) wins, then down, then ramp. `reserveWorldEdit` consumes the intent.
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

    /// Plans this step's dig (the cell the player faces on their current plane) and
    /// reserves its world growth (tile storage, and a ramp's exit and link) once, so
    /// the stage can call it before anything else mutates step state: an OOM here
    /// leaves the world and the step untouched for the retry.
    /// Returns the reserved edit for `commitWorldEdit`, or null when the intent does
    /// nothing: no intent, no body/facing, no floor layer, or an off-world cell.
    pub fn reserveWorldEdit(
        self: *const DigController,
        world: *WorldSystem,
        data: *const DataSystem,
        player: Player,
        intent: DigIntent,
    ) DigEditError!?DigEdit {
        const edit = (try self.planEdit(world, data, player, intent)) orelse return null;
        try reserveEdit(world, edit);
        return edit;
    }

    /// Writes an edit `reserveWorldEdit` reserved, with no world write between them:
    /// allocation-free in the world. Event and stimulus capacity are preflighted
    /// before the write, so a capacity miss leaves the world unchanged. Emits the
    /// cell's `world_tile_changed` event, a ramp exit's `world_obstacle_changed`, and
    /// one dig stimulus when either changed. Every write that landed is published on
    /// every exit, error included.
    pub fn commitWorldEdit(world: *WorldSystem, edit: DigEdit, frame: *SimulationFrame) DigEditError!void {
        if (frame.stimulusLiveCount() >= stimulus_live_capacity) return error.StimulusCapacityExceeded;
        try frame.events.ensureEventAppendCapacity(maxEventsPerStep(.dig_world_edit, .{}));
        try frame.ensureStimulusAppendCapacity(1);
        var applied: AppliedEdit = .{};
        const written = applyEdit(world, edit, &applied);
        publishAppliedEdit(frame, applied);
        try written;
        if (applied.tile == null and applied.exit == null) return;

        var stimulus_dropped: usize = 0;
        _ = try SensoryBus.emit(frame, .{
            .position = cellCenterWorldPos(world, edit.cell),
            .intensity = defaultStimulusIntensity(.dig),
            .kind = .dig,
            .level = edit.level,
        }, true, &stimulus_dropped);
    }

    /// One planned dig: a cell write on `level`'s floor and, for a ramp, its link and
    /// its exit.
    pub const DigEdit = struct {
        level: u16,
        floor_layer: usize,
        cell: CellCoord,
        /// `invalid_tile_id` punches a see-through hole.
        tile: TileId,
        ramp_link: ?LevelLink = null,
        exit: ?RampExit = null,
    };

    /// A ramp's exit: the cell on the plane above, cleared of every blocking band and
    /// sparse tile, its blocking floor becoming `floor_tile`.
    pub const RampExit = struct {
        level: u16,
        cell: CellCoord,
        floor_tile: TileId,
    };

    // Resolves the intent to one cell write, or null for an intentional no-op.
    // Read-only; returns `UnresolvedDigTiles` before any mutate when the dig tiles
    // were never resolved.
    fn planEdit(self: *const DigController, world: *const WorldSystem, data: *const DataSystem, player: Player, intent: DigIntent) !?DigEdit {
        if (intent == .none) return null;
        // Fail loudly on an unresolved config rather than silently carving the
        // invalid sentinel into the world: reaching the carve path means the
        // controller's dig tiles must have been resolved to valid ids (via
        // `DigConfig.fromMeta`/`fromRuntimeAssets`). The sentinel defaults exist so
        // a controller that is never asked to dig need not resolve them.
        // Runtime check (not Debug-only assert): ReleaseFast strips std.debug.assert,
        // so an unresolved controller must return before any world mutate.
        if (self.ramp_tile == invalid_tile_id or self.tunnel_tile == invalid_tile_id) {
            return error.UnresolvedDigTiles;
        }
        const cell = facedCellForEntity(world, data, player.entity) orelse return null;
        const level = player.current_level;
        const floor_layer = world.denseFloorLayerForLevel(level) orelse return null;
        return switch (intent) {
            // Surface: punch a see-through hole to fall through. Underground: mine a
            // walkable tunnel floor through the solid dirt of this plane.
            .hole => .{ .level = level, .floor_layer = floor_layer, .cell = cell, .tile = if (level == 0) invalid_tile_id else self.tunnel_tile },
            // Dig down: punch a see-through hole in the faced cell on any plane to
            // drop to the level below; a no-op on the bottom plane.
            .down => if (@as(usize, level) + 1 >= world.levelCount())
                null
            else
                .{ .level = level, .floor_layer = floor_layer, .cell = cell, .tile = invalid_tile_id },
            // Ramp: a walkable ramp tile plus a bidirectional link to the plane above;
            // a no-op on the surface or where a ramp already links this cell.
            .ramp => if (level == 0 or world.rampLinkOtherLevel(level, cell) != null)
                null
            else
                .{
                    .level = level,
                    .floor_layer = floor_layer,
                    .cell = cell,
                    .tile = self.ramp_tile,
                    .ramp_link = rampLink(level, cell),
                    .exit = .{ .level = level - 1, .cell = cell, .floor_tile = self.tunnel_tile },
                },
            .none => unreachable,
        };
    }

    /// Sizes the plane-traversal scratch for `capacity` traversals a step and records
    /// `allocator` for its later growth.
    pub fn reservePlaneScratch(self: *DigController, allocator: std.mem.Allocator, capacity: usize) error{OutOfMemory}!void {
        self.scratch_allocator = allocator;
        try self.reservePlaneLists(allocator, capacity);
        self.plane_scratch_reserved = capacity;
    }

    /// Grow-only re-reserve from the pipeline's population seam, using the
    /// allocator `reservePlaneScratch` set. Not a shortfall: `plane_scratch_grown` is
    /// not counted.
    pub fn ensurePlaneScratchReserve(self: *DigController, capacity: usize) error{ OutOfMemory, PlaneScratchUnreserved }!void {
        const allocator = self.scratch_allocator orelse return error.PlaneScratchUnreserved;
        try self.reservePlaneLists(allocator, capacity);
        self.plane_scratch_reserved = @max(self.plane_scratch_reserved, capacity);
    }

    // Room for `capacity` traversals, claims, and carves; grow-only.
    fn reservePlaneLists(self: *DigController, allocator: std.mem.Allocator, capacity: usize) error{OutOfMemory}!void {
        try self.plane_moves.ensureTotalCapacity(allocator, capacity);
        try self.plane_carves.ensureTotalCapacity(allocator, capacity);
        try self.plane_carve_next.ensureTotalCapacity(allocator, capacity);
        try self.plane_carve_writes.ensureTotalCapacity(allocator, capacity);
        try self.plane_carve_chunks.ensureTotalCapacity(allocator, capacity);
        try self.plane_tile_changes.ensureTotalCapacity(allocator, capacity);
        if (capacity > self.plane_claims.usable()) try self.plane_claims.reserve(allocator, capacity);
    }

    /// Cold path for a step whose possible traversals `needed` exceed the reservation,
    /// taken on the main thread before any world mutation: grows the scratch if its
    /// physical capacity is short, then counts the drift (only after any growth
    /// succeeded). The first drifting step warns once (release-visible, compiled out of
    /// tests).
    fn growPlaneScratch(self: *DigController, needed: usize) error{ OutOfMemory, PlaneScratchUnreserved }!void {
        @branchHint(.cold);
        const allocator = self.scratch_allocator orelse return error.PlaneScratchUnreserved;
        try self.reservePlaneLists(allocator, needed);
        self.plane_scratch_grown += 1;
        if (comptime logging.enabled(.warn)) {
            if (self.plane_scratch_grown == 1) logging.game.warn(
                "plane traversal: {d} possible traversals exceeded the reserved scratch; grew to {d} (reservation short of the live population)",
                .{ needed, self.plane_moves.capacity },
            );
        }
    }

    pub fn deinit(self: *DigController) void {
        if (self.scratch_allocator) |allocator| {
            self.plane_claims.deinit(allocator);
            self.plane_moves.deinit(allocator);
            self.plane_carves.deinit(allocator);
            self.plane_carve_next.deinit(allocator);
            self.plane_carve_writes.deinit(allocator);
            self.plane_carve_chunks.deinit(allocator);
            self.plane_tile_changes.deinit(allocator);
        }
        self.* = undefined;
    }

    /// One traversal the plane reserve decided: `entity` moves to `level` with its body
    /// on `cell`, after carving `cell` on `carve_layer` (`no_landing_layer`: no carve).
    pub const PlaneMove = struct {
        entity: EntityId,
        cell: CellCoord,
        level: u16,
        carve_layer: u32,
    };

    /// What `reservePlaneTraversalStage` decided and reserved for the commit: the
    /// traversals in commit order (the player's first), the landing carves among them and
    /// those carves grouped by (level, chunk) for one batched write, the missing
    /// `world_level` rows, the gathered NPC entries, and the player's entered cell. Valid
    /// until the commit, with no world, data, or event write in between.
    pub const PlaneTraversalReservation = struct {
        moves: []const PlaneMove,
        carves: usize,
        carve_chunks: []const DenseChunkWrites,
        missing_world_level: usize,
        npc_entries: []const PlaneEntry,
        player_cell: ?CellCoord,
    };

    /// The plane stage's preflight, before any write. Decides every traversal in commit
    /// order (the player, then each gathered NPC entry in AI row order) from the
    /// classification the entry carries, re-judging only an entry whose hole or landing
    /// an earlier traversal this step carves, and groups the landing carves by (level,
    /// chunk) for the commit's batched write (`WorldSystem.groupDenseCellWrites`), each at
    /// O(1) per entry. Then reserves the carves' event capacity and the missing
    /// `world_level` rows; the scratch grows (counted) first when the entries exceed its
    /// reservation.
    /// `npc_entries` is this step's `PlaneEntrySystem.gather` over the same `world`,
    /// `data`, and `player`, valid through the commit. On error nothing is written. The
    /// caller reserves anything else sized from `carves` (the nav record) before
    /// `commitPlaneTraversalStage`.
    pub fn reservePlaneTraversalStage(
        self: *DigController,
        world: *WorldSystem,
        data: *DataSystem,
        player: *const Player,
        frame: *SimulationFrame,
        npc_entries: []const PlaneEntry,
        thread_system: *ThreadSystem,
    ) PlaneStageError!PlaneTraversalReservation {
        self.plane_tile_changes.clearRetainingCapacity();
        self.plane_moves.clearRetainingCapacity();
        const player_entry = playerCellEntry(self, world, data, player.*);
        const possible = npc_entries.len + @intFromBool(player_entry != null);
        if (possible > self.plane_scratch_reserved) try self.growPlaneScratch(possible);
        // O(1): the previous step's claims stop counting.
        self.plane_claims.beginStep();
        std.debug.assert(self.plane_moves.capacity >= possible and self.plane_claims.usable() >= possible);

        // SIMD verdict: scalar. Claim-table probes and record appends per entry.
        var missing_world_level: usize = 0;
        if (player_entry) |entry| {
            self.decideMove(world.width, player.entity, entry.level, entry.cell, planeTarget(world, entry.level, entry.cell, self.tunnel_tile));
            if (data.worldLevelConst(player.entity) == null) missing_world_level += 1;
        }
        for (npc_entries) |entry| {
            std.debug.assert(!entry.entity.eql(player.entity));
            self.decideMove(world.width, entry.entity, entry.level, entry.cell, entry.target);
            missing_world_level += @intFromBool(entry.needs_world_level);
        }

        // SIMD verdict: scalar. A filtered record copy per carving move.
        self.plane_carves.clearRetainingCapacity();
        for (self.plane_moves.items) |move| {
            if (move.carve_layer == no_landing_layer) continue;
            self.plane_carves.appendAssumeCapacity(.{ .layer = move.carve_layer, .x = move.cell.x, .y = move.cell.y, .tile = self.tunnel_tile });
        }
        const carves = self.plane_carves.items.len;
        std.debug.assert(self.plane_carve_next.capacity >= carves and self.plane_carve_writes.capacity >= carves and
            self.plane_carve_chunks.capacity >= carves and self.plane_tile_changes.capacity >= carves);
        const carve_chunks = world.groupDenseCellWrites(
            self.plane_carves.items,
            self.plane_carve_next.allocatedSlice()[0..carves],
            self.plane_carve_writes.allocatedSlice()[0..carves],
            self.plane_carve_chunks.allocatedSlice()[0..carves],
        );
        try world.reserveDenseCellWrites(carve_chunks, self.carveThreads(world, thread_system));
        try frame.events.ensureEventAppendCapacity(carves);
        if (missing_world_level > 0) {
            try data.world_levels.ensureCapacity(data.allocator, data.world_levels.len() + missing_world_level);
        }
        return .{
            .moves = self.plane_moves.items,
            .carves = carves,
            .carve_chunks = carve_chunks,
            .missing_world_level = missing_world_level,
            .npc_entries = npc_entries,
            .player_cell = if (player_entry) |entry| entry.cell else null,
        };
    }

    // Decides one entered cell's traversal against this step's earlier decisions, which
    // carve only landings and add no links: a ramp is unaffected; a fall whose hole an
    // earlier fall carves shut stays (the cell holds a floor by its turn); a landing an
    // earlier fall already carves needs no second carve. O(1): a claim-table probe or
    // insert and a record append, into reserved capacity.
    fn decideMove(self: *DigController, width: u16, entity: EntityId, level: u16, cell: CellCoord, target: PlaneTarget) void {
        switch (target.action) {
            .attach => {},
            .ramp => self.plane_moves.appendAssumeCapacity(.{ .entity = entity, .cell = cell, .level = target.target_level, .carve_layer = no_landing_layer }),
            .fall => {
                if (self.plane_claims.contains(planeCellKey(width, level, cell))) return;
                var carve_layer = no_landing_layer;
                if (target.carve and self.plane_claims.insert(planeCellKey(width, target.target_level, cell))) {
                    carve_layer = target.landing_layer;
                }
                self.plane_moves.appendAssumeCapacity(.{ .entity = entity, .cell = cell, .level = target.target_level, .carve_layer = carve_layer });
            },
        }
    }

    /// Player + NPC plane traversal for one step, after `reservePlaneTraversalStage`
    /// (with the same `thread_system`) and nothing written since. Attaches the missing
    /// `world_level` rows (allocation-free after the reserve, and idempotent on a retry),
    /// then writes every landing carve as one batched dense edit
    /// (`WorldSystem.applyDenseCellWrites`, its chunks on `thread_system`): all
    /// or nothing, and its only growth is the terrain pools' (counted), so an error writes
    /// no terrain. Then publishes the carves as one event range and applies each decided
    /// traversal in order (allocation-free). The player's cell-entry latch
    /// (`player_last_cell`) advances only once the player's own traversal (or its no-op)
    /// applied, so an earlier error leaves it for the next step's retry.
    pub fn commitPlaneTraversalStage(
        self: *DigController,
        world: *WorldSystem,
        data: *DataSystem,
        player: *Player,
        frame: *SimulationFrame,
        reservation: PlaneTraversalReservation,
        thread_system: *ThreadSystem,
    ) PlaneStageError!void {
        const scratch = &self.plane_tile_changes;
        std.debug.assert(scratch.items.len == 0);
        std.debug.assert(scratch.capacity >= reservation.carves);
        try attachMissingWorldLevels(data, player, reservation);
        try world.applyDenseCellWrites(reservation.carve_chunks, self.carveThreads(world, thread_system), scratch);
        std.debug.assert(scratch.items.len <= reservation.carves);
        frame.publishWorldTileChangesAssumeCapacity(scratch.items);
        try self.applyPlaneTraversals(world, data, player, reservation);
    }

    // The carve batch's stage threading: the world's terrain-edit tuners under
    // `carve_controls`, or inline without a thread system.
    fn carveThreads(self: *const DigController, world: *WorldSystem, thread_system: *ThreadSystem) TerrainEditThreads {
        return .{
            .thread_system = thread_system,
            .plan_tuner = &world.terrain_edit_plan_tuner,
            .write_tuner = &world.terrain_edit_write_tuner,
            .controls = self.carve_controls,
        };
    }

    // The commit's decided traversals in order; allocation-free after the reserve.
    // SIMD verdict: scalar. Per-entity store writes through each entity's slot.
    fn applyPlaneTraversals(
        self: *DigController,
        world: *WorldSystem,
        data: *DataSystem,
        player: *Player,
        reservation: PlaneTraversalReservation,
    ) PlaneStageError!void {
        // The player's traversal is the first move when it has one.
        const player_moves = reservation.moves.len > 0 and reservation.moves[0].entity.eql(player.entity);
        if (!player_moves) self.latchPlayerCell(reservation);
        // The landings were carved walkable before any fall: the plane below defaults to
        // solid dirt, where the tile gate would shove the entity straight back out.
        for (reservation.moves) |move| {
            try setEntityLevel(world, data, move.entity, move.level, move.cell);
            if (move.entity.eql(player.entity)) {
                player.current_level = move.level;
                self.latchPlayerCell(reservation);
            }
        }
    }

    // Advances the player's cell-entry latch to the cell its traversal judged.
    fn latchPlayerCell(self: *DigController, reservation: PlaneTraversalReservation) void {
        if (reservation.player_cell) |cell| self.player_last_cell = cell;
    }
};

// One step's claimed (level, cell) keys over the shared stamped table: a new step
// clears in O(1), a probe is O(1) at load at most 1/2.
const PlaneClaims = struct {
    const Slot = struct { key: u64, stamp: u32 };
    const Table = StampedTable(Slot, "key");

    slots: []Slot = &.{},
    shift: u6 = 0,
    generation: u32 = 1,
    used: usize = 0,
    // The most claims a step may hold; the table holds twice as many slots.
    limit: usize = 0,

    fn deinit(self: *PlaneClaims, allocator: std.mem.Allocator) void {
        allocator.free(self.slots);
        self.* = .{};
    }

    fn usable(self: *const PlaneClaims) usize {
        return self.limit;
    }

    // A fresh, empty table for at least `count` claims, grown geometrically; drops the
    // current claims. An error leaves the table as it was.
    fn reserve(self: *PlaneClaims, allocator: std.mem.Allocator, count: usize) error{OutOfMemory}!void {
        const limit = @max(count, 2 * self.limit);
        const table = try Table.alloc(allocator, limit);
        allocator.free(self.slots);
        self.* = .{ .slots = table.slots, .shift = table.shift, .limit = limit };
    }

    // Starts a step with no claims: O(1) outside the stamp wraparound.
    fn beginStep(self: *PlaneClaims) void {
        Table.advance(self.slots, &self.generation);
        self.used = 0;
    }

    fn contains(self: *const PlaneClaims, key: u64) bool {
        return Table.contains(self.slots, self.shift, self.generation, key);
    }

    // Claims `key`; true when it was not yet claimed this step. Requires room
    // (`usable`).
    fn insert(self: *PlaneClaims, key: u64) bool {
        const claimed = Table.claim(self.slots, self.shift, self.generation, &self.used, self.limit, key, freshClaim);
        // The reserve sized the step's claims (asserted), so a claim always resolves.
        return claimed.?.fresh;
    }

    fn freshClaim(key: u64, stamp: u32) Slot {
        return .{ .key = key, .stamp = stamp };
    }
};

// Attaches `world_level` to the player and each gathered entry missing it, into the
// room the plane reserve made.
fn attachMissingWorldLevels(data: *DataSystem, player: *const Player, reservation: DigController.PlaneTraversalReservation) PlaneStageError!void {
    if (reservation.missing_world_level == 0) return;
    if (reservation.player_cell != null and data.worldLevelConst(player.entity) == null) {
        try data.setWorldLevel(player.entity, player.current_level);
    }
    for (reservation.npc_entries) |entry| {
        if (entry.needs_world_level and data.worldLevelConst(entry.entity) == null) {
            try data.setWorldLevel(entry.entity, entry.level);
        }
    }
}

// A plane-traversal claim key: `level` in the high bits over the level-local cell index.
fn planeCellKey(width: u16, level: u16, cell: CellCoord) u64 {
    return (@as(u64, level) << 32) | (@as(u64, cell.y) * width + cell.x);
}

const PlaneCellEntry = struct {
    level: u16,
    cell: CellCoord,
};

fn rampLink(level: u16, cell: CellCoord) LevelLink {
    return .{
        .kind = .ramp,
        .level_a = level,
        .cell_a = cell,
        .level_b = level - 1,
        .cell_b = cell,
        .traversal_cost = 1,
        .bidirectional = true,
    };
}

// Opens a reserve scope and reserves the edit's tile write, ramp exit, and ramp link.
fn reserveEdit(world: *WorldSystem, edit: DigController.DigEdit) !void {
    world.beginDenseCellWriteReserve();
    try world.reserveDenseCellWrite(edit.floor_layer, edit.cell.x, edit.cell.y, edit.tile);
    if (edit.exit) |exit| try world.reserveClearCellBlocking(exit.level, exit.cell.x, exit.cell.y, exit.floor_tile);
    if (edit.ramp_link) |link| try world.reserveLevelLink(link);
}

// What one applied edit changed: the dug cell and a ramp's exit.
const AppliedEdit = struct {
    tile: ?WorldTileChangedEvent = null,
    exit: ?WorldObstacleChangedEvent = null,
};

// Writes the reserved edit; allocation-free after `reserveEdit`. A ramp's exit is
// cleared and its link added even when the cell already held the ramp tile. Each
// change lands in `applied` right after its write, before any later fallible step; a
// link reaches nav through the link-count gap, not an event.
fn applyEdit(world: *WorldSystem, edit: DigController.DigEdit, applied: *AppliedEdit) !void {
    applied.tile = if (edit.tile == invalid_tile_id)
        try world.clearDenseTile(edit.floor_layer, edit.cell.x, edit.cell.y)
    else
        try world.setDenseTile(edit.floor_layer, edit.cell.x, edit.cell.y, edit.tile);
    if (edit.exit) |exit| applied.exit = try world.clearCellBlocking(exit.level, exit.cell.x, exit.cell.y, exit.floor_tile);
    if (edit.ramp_link) |link| try world.addLevelLink(link);
}

// Publishes an applied edit's 0-2 events as one range, into the event capacity
// `commitWorldEdit` preflighted.
fn publishAppliedEdit(frame: *SimulationFrame, applied: AppliedEdit) void {
    const event_count = @as(usize, @intFromBool(applied.tile != null)) + @intFromBool(applied.exit != null);
    if (event_count == 0) return;
    var writer = frame.events.appendReservedRange(event_count);
    if (applied.tile) |changed| writer.write(.{ .stage = .structural_commit, .payload = .{ .world_tile_changed = changed } });
    if (applied.exit) |cleared| writer.write(.{ .stage = .structural_commit, .payload = .{ .world_obstacle_changed = cleared } });
    writer.finish();
    frame.events.finishWrite();
}

fn playerCellEntry(
    dig: *const DigController,
    world: *const WorldSystem,
    data: *const DataSystem,
    player: Player,
) ?PlaneCellEntry {
    const body = data.movementBodyConst(player.entity) orelse return null;
    const visual = data.primitiveVisualConst(player.entity) orelse return null;
    const center_x = body.position.x + visual.size.x * 0.5;
    const center_y = body.position.y + visual.size.y * 0.5;
    const target = world.cellContaining(center_x, center_y) orelse return null;
    const cell = CellCoord{ .x = target.x, .y = target.y };
    if (dig.player_last_cell) |last| {
        if (last.x == cell.x and last.y == cell.y) return null;
    }
    return .{ .level = player.current_level, .cell = cell };
}

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

/// World cell the entity faces from body center + facing × tile size.
/// Null when body/facing/visual is missing or the probe is off-world.
/// Shared by dig planning and action-intent capture so interact/destructible
/// targets stay aligned with dig's faced-cell contract.
pub fn facedCellForEntity(
    world: *const WorldSystem,
    data: *const DataSystem,
    entity: EntityId,
) ?CellCoord {
    const body = data.movementBodyConst(entity) orelse return null;
    const facing = data.facingConst(entity) orelse return null;
    const visual = data.primitiveVisualConst(entity) orelse return null;
    const offset = facingOffset(facing.direction);
    const faced_x = body.position.x + visual.size.x * 0.5 + offset.x * world.tile_size;
    const faced_y = body.position.y + visual.size.y * 0.5 + offset.y * world.tile_size;
    const target = world.cellContaining(faced_x, faced_y) orelse return null;
    return .{ .x = target.x, .y = target.y };
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
const warmLandingTerrain = @import("world/test_support.zig").warmLandingTerrain;
const denseTileBlocksMovement = @import("world/test_support.zig").denseTileBlocksMovement;
const sparseTileCellCoord = @import("world/test_support.zig").sparseTileCellCoord;
const PlaneEntrySystem = @import("systems/plane_entry.zig").PlaneEntrySystem;

// One dig in stage order: reserve, then commit the reserved edit.
fn testDig(dig: *const DigController, world: *WorldSystem, data: *const DataSystem, player: Player, frame: *SimulationFrame) !void {
    const edit = (try dig.reserveWorldEdit(world, data, player, frame.dig_intent)) orelse return;
    try DigController.commitWorldEdit(world, edit, frame);
}

// One plane stage: a serial entry gather, the reserve, then the commit.
fn testPlaneTraversalStage(dig: *DigController, world: *WorldSystem, data: *DataSystem, player: *Player, frame: *SimulationFrame) !void {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var plane_entry = PlaneEntrySystem.init(std.testing.allocator);
    defer plane_entry.deinit();
    const entries = try plane_entry.gather(data, world, player.entity, dig.tunnel_tile, null);
    const reservation = try dig.reservePlaneTraversalStage(world, data, player, frame, entries, &serial_threads);
    try dig.commitPlaneTraversalStage(world, data, player, frame, reservation, &serial_threads);
}

// A frame with room for a small plane stage's events, its step begun.
fn testPlaneFrame() !SimulationFrame {
    var frame = SimulationFrame.init(std.testing.allocator);
    errdefer frame.deinit();
    try frame.reserveStreams(4, 16, 8, 8, 8, 8);
    frame.beginStep();
    return frame;
}

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

    // Built in place: the world borrows `&self.meta`, so the fixture never moves after.
    fn init(self: *TestWorld, facing: Facing, level: u16) !void {
        const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
        self.meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
        errdefer self.meta.deinit();
        self.world = try testMinimalMultiLevelWorld(&self.meta);
        errdefer self.world.deinit();
        self.data = DataSystem.init(std.testing.allocator);
        errdefer self.data.deinit();
        self.player = try Player.spawn(&self.data);
        self.player.current_level = level;
        try self.data.setWorldLevel(self.player.entity, level);
        // Cell (3,3) top-left, facing right -> faced cell (4,3).
        const body = self.data.movementBodyPtr(self.player.entity).?;
        body.position_x.* = 96;
        body.position_y.* = 96;
        self.data.facingPtr(self.player.entity).?.* = facing;
    }

    fn deinit(self: *TestWorld) void {
        self.data.deinit();
        self.world.deinit();
        self.meta.deinit();
    }
};

test "DigController plane scratch reserved-then-push is allocation-free (FailingAllocator)" {
    var dig = DigController.init(.{});
    defer dig.deinit();
    try dig.reservePlaneScratch(std.testing.allocator, 2);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const saved = dig.scratch_allocator.?;
    dig.scratch_allocator = failing.allocator();
    defer dig.scratch_allocator = saved;

    const change = WorldTileChangedEvent{
        .level = 1,
        .x = 2,
        .y = 3,
        .old_tile_id = 1,
        .new_tile_id = 2,
        .old_blocks_movement = true,
        .new_blocks_movement = false,
    };
    dig.plane_tile_changes.appendAssumeCapacity(change);
    dig.plane_tile_changes.appendAssumeCapacity(change);
    try std.testing.expectEqual(@as(usize, 2), dig.plane_tile_changes.items.len);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

/// Adds a locomotion-tier wandering NPC on level 0 whose body enters `to` from `from`
/// this step (previous position on `from`, current on `to`), so plane traversal sees a
/// cell entry. Mirrors the pipeline's plane-traversal NPC fixtures.
fn addCellEntryNpc(data: *DataSystem, from: CellCoord, to: CellCoord) !EntityId {
    return addCellEntryNpcOnLevel(data, from, to, 0);
}

/// `addCellEntryNpc` with `world_level` at `world_level`, or left off when null.
fn addCellEntryNpcOnLevel(data: *DataSystem, from: CellCoord, to: CellCoord, world_level: ?u16) !EntityId {
    const npc = try data.createEntity();
    try data.setMovementBody(npc, .{});
    try data.setPrimitiveVisual(npc, .{
        .size = .{ .x = 32, .y = 32 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    });
    try data.setAiAgent(npc, .{ .active_behavior = .wander, .gain_pursue = 0 });
    if (world_level) |level| try data.setWorldLevel(npc, level);
    try data.setSimulationTier(npc, .locomotion);
    const body = data.movementBodyPtr(npc).?;
    body.previous_x.* = @as(f32, @floatFromInt(from.x)) * 32;
    body.previous_y.* = @as(f32, @floatFromInt(from.y)) * 32;
    body.position_x.* = @as(f32, @floatFromInt(to.x)) * 32;
    body.position_y.* = @as(f32, @floatFromInt(to.y)) * 32;
    return npc;
}

/// Opens surface holes at (4,3) and (6,3) with one NPC entering each this step.
fn setUpTwoFalls(tw: *TestWorld) !void {
    const floor0 = tw.world.denseFloorLayerForLevel(0).?;
    _ = try tw.world.clearDenseTile(floor0, 4, 3);
    _ = try tw.world.clearDenseTile(floor0, 6, 3);
    _ = try addCellEntryNpc(&tw.data, .{ .x = 3, .y = 3 }, .{ .x = 4, .y = 3 });
    _ = try addCellEntryNpc(&tw.data, .{ .x = 5, .y = 3 }, .{ .x = 6, .y = 3 });
}

fn worldTileChangesOf(frame: *const SimulationFrame, out: []WorldTileChangedEvent) ![]WorldTileChangedEvent {
    var count: usize = 0;
    for (frame.events.mergedItems()) |event| switch (event.payload) {
        .world_tile_changed => |change| {
            if (count == out.len) return error.TestUnexpectedResult;
            out[count] = change;
            count += 1;
        },
        else => {},
    };
    return out[0..count];
}

test "plane traversal grows an under-reserved scratch before any carve and matches a reserved run" {
    var tw_short: TestWorld = undefined;
    try tw_short.init(.right, 0);
    defer tw_short.deinit();
    var tw_reserved: TestWorld = undefined;
    try tw_reserved.init(.right, 0);
    defer tw_reserved.deinit();
    try setUpTwoFalls(&tw_short);
    try setUpTwoFalls(&tw_reserved);

    var dig_short = try testDigController(&tw_short.meta);
    defer dig_short.deinit();
    // A zero reserve sets the allocator but leaves capacity 0, so two carves must grow it.
    try dig_short.reservePlaneScratch(std.testing.allocator, 0);
    var dig_reserved = try testDigController(&tw_reserved.meta);
    defer dig_reserved.deinit();
    try dig_reserved.reservePlaneScratch(std.testing.allocator, 4);

    var frame_short = SimulationFrame.init(std.testing.allocator);
    defer frame_short.deinit();
    try frame_short.reserveStreams(4, 16, 8, 8, 8, 8);
    frame_short.beginStep();
    var frame_reserved = SimulationFrame.init(std.testing.allocator);
    defer frame_reserved.deinit();
    try frame_reserved.reserveStreams(4, 16, 8, 8, 8, 8);
    frame_reserved.beginStep();

    try testPlaneTraversalStage(&dig_short, &tw_short.world, &tw_short.data, &tw_short.player, &frame_short);
    try testPlaneTraversalStage(&dig_reserved, &tw_reserved.world, &tw_reserved.data, &tw_reserved.player, &frame_reserved);

    // Capacity changed only the telemetry: both runs carve both landings.
    inline for (.{ &tw_short, &tw_reserved }) |tw| {
        const floor1 = tw.world.denseFloorLayerForLevel(1).?;
        try std.testing.expect(!denseTileBlocksMovement(&tw.world, floor1, 4, 3));
        try std.testing.expect(!denseTileBlocksMovement(&tw.world, floor1, 6, 3));
    }
    try std.testing.expectEqual(@as(u64, 1), dig_short.plane_scratch_grown);
    try std.testing.expect(dig_short.plane_tile_changes.capacity >= 2);
    try std.testing.expectEqual(@as(u64, 0), dig_reserved.plane_scratch_grown);

    // Same published changes, same order ((4,3) then (6,3)).
    var short_buf: [4]WorldTileChangedEvent = undefined;
    var reserved_buf: [4]WorldTileChangedEvent = undefined;
    const short_changes = try worldTileChangesOf(&frame_short, &short_buf);
    const reserved_changes = try worldTileChangesOf(&frame_reserved, &reserved_buf);
    try std.testing.expectEqual(@as(usize, 2), short_changes.len);
    try std.testing.expectEqual(reserved_changes.len, short_changes.len);
    for (short_changes, reserved_changes) |a, b| try std.testing.expectEqual(b, a);
    try std.testing.expectEqual(@as(u16, 4), short_changes[0].x);
    try std.testing.expectEqual(@as(u16, 6), short_changes[1].x);
    try std.testing.expectEqual(@as(usize, 2), frame_short.events.stats.world_tile_changed);
    try std.testing.expectEqual(@as(usize, 2), frame_reserved.events.stats.world_tile_changed);
}

test "plane traversal counts carves past the reservation even inside the scratch's slack" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 0);
    defer tw.deinit();
    try setUpTwoFalls(&tw);

    var dig = try testDigController(&tw.meta);
    defer dig.deinit();
    // Physical slack past the declared reservation of 1 (std rounds a reserve of 1 up to
    // several entries; reserving 8 first makes the slack explicit).
    try dig.reservePlaneScratch(std.testing.allocator, 8);
    try dig.reservePlaneScratch(std.testing.allocator, 1);
    const capacity_before = dig.plane_tile_changes.capacity;
    try std.testing.expect(capacity_before >= 2);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 16, 8, 8, 8, 8);
    frame.beginStep();

    try testPlaneTraversalStage(&dig, &tw.world, &tw.data, &tw.player, &frame);

    // Two carves against a reservation of 1: drift, counted though nothing grew.
    try std.testing.expectEqual(capacity_before, dig.plane_tile_changes.capacity);
    try std.testing.expectEqual(@as(u64, 1), dig.plane_scratch_grown);
    try std.testing.expectEqual(@as(usize, 2), frame.events.stats.world_tile_changed);
}

test "plane traversal within the scratch reserve is allocation-free (FailingAllocator)" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 0);
    defer tw.deinit();
    try setUpTwoFalls(&tw);

    var dig = try testDigController(&tw.meta);
    defer dig.deinit();
    // The player's entry and the two NPC entries.
    try dig.reservePlaneScratch(std.testing.allocator, 3);
    try warmLandingTerrain(&tw.world, dig.tunnel_tile, 1, .{ 4, 3 });

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 16, 8, 8, 8, 8);
    frame.beginStep();
    // Warm the event append path the stage preflights and publishes through.
    try frame.events.ensureEventAppendCapacity(2);

    const original_dig = dig.scratch_allocator.?;
    const original_frame = frame.allocator;
    const original_events = frame.events.stream.allocator;
    const original_data = tw.data.allocator;
    const original_world = tw.world.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const fail_alloc = failing.allocator();
    dig.scratch_allocator = fail_alloc;
    frame.allocator = fail_alloc;
    frame.events.stream.allocator = fail_alloc;
    tw.data.allocator = fail_alloc;
    // World/dense-edit allocations (tile writes, block takes) are caught too.
    tw.world.allocator = fail_alloc;
    // Declared after the deinit defers, so it restores the real allocators first (LIFO).
    defer {
        dig.scratch_allocator = original_dig;
        frame.allocator = original_frame;
        frame.events.stream.allocator = original_events;
        tw.data.allocator = original_data;
        tw.world.allocator = original_world;
    }

    try testPlaneTraversalStage(&dig, &tw.world, &tw.data, &tw.player, &frame);

    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(u64, 0), dig.plane_scratch_grown);
    try std.testing.expectEqual(@as(usize, 2), frame.events.stats.world_tile_changed);
}

// Gathers this step's NPC entries serially, then reserves and commits the plane stage
// over them. Returns the reservation's landing carves.
fn runPlaneStageOverEntries(
    dig: *DigController,
    plane_entry: *PlaneEntrySystem,
    tw: *TestWorld,
    frame: *SimulationFrame,
) !usize {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    const entries = try plane_entry.gather(&tw.data, &tw.world, tw.player.entity, dig.tunnel_tile, null);
    const reservation = try dig.reservePlaneTraversalStage(&tw.world, &tw.data, &tw.player, frame, entries, &serial_threads);
    try dig.commitPlaneTraversalStage(&tw.world, &tw.data, &tw.player, frame, reservation, &serial_threads);
    return reservation.carves;
}

test "plane traversal attaches world_level only to cell-entry agents missing it, and skips plain crossings" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 0);
    defer tw.deinit();
    var dig = try testDigController(&tw.meta);
    defer dig.deinit();
    try dig.reservePlaneScratch(std.testing.allocator, 4);

    // Crosses a plain cell with no world_level, its scope on level 1.
    const missing = try addCellEntryNpcOnLevel(&tw.data, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, null);
    try tw.data.setSimulationMetadata(missing, .{ .tier = .locomotion, .level = 1 });
    // Crosses a plain cell with world_level.
    const plain = try addCellEntryNpc(&tw.data, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 });
    // No world_level, and stays in its cell.
    const still = try addCellEntryNpcOnLevel(&tw.data, .{ .x = 5, .y = 5 }, .{ .x = 5, .y = 5 }, null);
    try std.testing.expect(tw.data.worldLevelConst(missing) == null);
    try std.testing.expect(tw.data.worldLevelConst(still) == null);
    const plain_before = tw.data.movementBodyConst(plain).?;

    var plane_entry = PlaneEntrySystem.init(std.testing.allocator);
    defer plane_entry.deinit();
    const entries = try plane_entry.gather(&tw.data, &tw.world, tw.player.entity, dig.tunnel_tile, null);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expect(entries[0].entity.eql(missing));
    try std.testing.expectEqual(@as(u16, 1), entries[0].level);
    try std.testing.expect(entries[0].needs_world_level);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 16, 8, 8, 8, 8);
    frame.beginStep();
    try std.testing.expectEqual(@as(usize, 0), try runPlaneStageOverEntries(&dig, &plane_entry, &tw, &frame));

    try std.testing.expectEqual(@as(?u16, 1), tw.data.worldLevelConst(missing));
    try std.testing.expectEqual(@as(?u16, 0), tw.data.worldLevelConst(plain));
    try std.testing.expect(tw.data.worldLevelConst(still) == null);
    try std.testing.expectEqual(plain_before, tw.data.movementBodyConst(plain).?);
    try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);
}

test "plane traversal re-evaluates gathered entries against this step's earlier carves" {
    // A on level 0 and B on level 1 both enter (4,3), a hole on both levels. A's fall
    // carves level 1's (4,3), filling B's hole, so B falls only when it commits first.
    inline for (.{ true, false }) |a_first| {
        var tw: TestWorld = undefined;
        try tw.init(.right, 0);
        defer tw.deinit();
        var dig = try testDigController(&tw.meta);
        defer dig.deinit();
        try dig.reservePlaneScratch(std.testing.allocator, 4);
        const floor0 = tw.world.denseFloorLayerForLevel(0).?;
        const floor1 = tw.world.denseFloorLayerForLevel(1).?;
        const floor2 = tw.world.denseFloorLayerForLevel(2).?;
        _ = try tw.world.clearDenseTile(floor0, 4, 3);
        _ = try tw.world.clearDenseTile(floor1, 4, 3);

        var a: EntityId = undefined;
        var b: EntityId = undefined;
        if (a_first) a = try addCellEntryNpc(&tw.data, .{ .x = 3, .y = 3 }, .{ .x = 4, .y = 3 });
        b = try addCellEntryNpcOnLevel(&tw.data, .{ .x = 5, .y = 3 }, .{ .x = 4, .y = 3 }, 1);
        if (!a_first) a = try addCellEntryNpc(&tw.data, .{ .x = 3, .y = 3 }, .{ .x = 4, .y = 3 });

        var plane_entry = PlaneEntrySystem.init(std.testing.allocator);
        defer plane_entry.deinit();
        var frame = SimulationFrame.init(std.testing.allocator);
        defer frame.deinit();
        try frame.reserveStreams(4, 16, 8, 8, 8, 8);
        frame.beginStep();
        // The reserve decides in commit order: A's carve fills B's hole when A goes first.
        try std.testing.expectEqual(@as(usize, if (a_first) 1 else 2), try runPlaneStageOverEntries(&dig, &plane_entry, &tw, &frame));

        try std.testing.expectEqual(@as(?u16, 1), tw.data.worldLevelConst(a));
        try std.testing.expectEqual(dig.tunnel_tile, tw.world.denseTile(floor1, 4, 3));
        if (a_first) {
            try std.testing.expectEqual(@as(?u16, 1), tw.data.worldLevelConst(b));
            try std.testing.expect(denseTileBlocksMovement(&tw.world, floor2, 4, 3));
            try std.testing.expectEqual(@as(usize, 1), frame.events.stats.world_tile_changed);
        } else {
            try std.testing.expectEqual(@as(?u16, 2), tw.data.worldLevelConst(b));
            try std.testing.expectEqual(dig.tunnel_tile, tw.world.denseTile(floor2, 4, 3));
            try std.testing.expectEqual(@as(usize, 2), frame.events.stats.world_tile_changed);
        }
    }
}

// The per-entry traversal the plane stage's decisions reproduce: one entry at a time
// against the world as the earlier entries left it, classifying and carving on the
// spot. The stage's parity reference.
fn referencePlaneTraversal(dig: *const DigController, world: *WorldSystem, data: *DataSystem, entity: EntityId, level: u16, cell: CellCoord, carves: *std.ArrayList(WorldTileChangedEvent)) !void {
    if (world.rampLinkOtherLevel(level, cell)) |other| return setEntityLevel(world, data, entity, other, cell);
    const below = @as(usize, level) + 1;
    if (below >= world.levelCount() or !world.denseFloorIsEmpty(level, cell.x, cell.y)) return;
    const below_level: u16 = @intCast(below);
    if (world.denseFloorLayerForLevel(below_level)) |layer| {
        if (try world.setDenseTile(layer, cell.x, cell.y, dig.tunnel_tile)) |change| try carves.append(std.testing.allocator, change);
    }
    try setEntityLevel(world, data, entity, below_level, cell);
}

// A 4-level world over the dig fixture's 8x8 cells with random holes, pre-carved
// landings, and ramps in its central 4x4 cells, and `npc_count` agents entering random
// central cells on random levels (some missing world_level), many on shared columns.
const ParityWorld = struct {
    world: WorldSystem,
    data: DataSystem,
    player: Player,

    fn init(meta: *const world_tileset_meta.WorldTilesetMeta, seed: u64, npc_count: usize) !ParityWorld {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var world = try testMinimalMultiLevelWorld(meta);
        errdefer world.deinit();
        const dirt = try world.requireTileByName(meta, "dirt");
        const tunnel = (try DigConfig.fromMeta(meta)).tunnel_tile;
        const deepest = try world.addLevel(-3 * @import("world/system.zig").level_z_step);
        _ = try world.addDenseLayer(deepest, 0, .floor, dirt);
        for (0..world.levelCount()) |level_index| {
            const level: u16 = @intCast(level_index);
            const floor = world.denseFloorLayerForLevel(level).?;
            for (2..6) |y| for (2..6) |x| {
                const roll = random.uintLessThan(u8, 20);
                if (roll < 8) {
                    _ = try world.clearDenseTile(floor, @intCast(x), @intCast(y));
                } else if (roll < 11 and level > 0) {
                    _ = try world.setDenseTile(floor, @intCast(x), @intCast(y), tunnel);
                }
            };
        }
        for (0..3) |_| {
            const upper = random.uintLessThan(u16, 3);
            const cell = CellCoord{ .x = 2 + random.uintLessThan(u16, 4), .y = 2 + random.uintLessThan(u16, 4) };
            try world.addLevelLink(.{ .kind = .ramp, .level_a = upper + 1, .cell_a = cell, .level_b = upper, .cell_b = cell, .traversal_cost = 1, .bidirectional = true });
        }
        var data = DataSystem.init(std.testing.allocator);
        errdefer data.deinit();
        const player = try Player.spawn(&data);
        for (0..npc_count) |_| {
            const to = CellCoord{ .x = 2 + random.uintLessThan(u16, 4), .y = 2 + random.uintLessThan(u16, 4) };
            const level = random.uintLessThan(u16, 4);
            const has_level = random.uintLessThan(u8, 5) != 0;
            const npc = try addCellEntryNpcOnLevel(&data, .{ .x = to.x - 1, .y = to.y }, to, if (has_level) level else null);
            if (!has_level) try data.setSimulationMetadata(npc, .{ .tier = .locomotion, .level = level });
        }
        return .{ .world = world, .data = data, .player = player };
    }

    fn deinit(self: *ParityWorld) void {
        self.data.deinit();
        self.world.deinit();
    }
};

fn changeLessThan(_: void, lhs: WorldTileChangedEvent, rhs: WorldTileChangedEvent) bool {
    if (lhs.level != rhs.level) return lhs.level < rhs.level;
    if (lhs.y != rhs.y) return lhs.y < rhs.y;
    return lhs.x < rhs.x;
}

test "plane stage decisions match the per-entry sequential traversal on shared columns, ramps, and pre-carved landings" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    const allocator = std.testing.allocator;
    const asset_store = AssetStore.init(allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    const npc_count: usize = 48;
    var reference_cancels: usize = 0;
    for (0..24) |seed| {
        var staged = try ParityWorld.init(&meta, seed, npc_count);
        defer staged.deinit();
        var reference = try ParityWorld.init(&meta, seed, npc_count);
        defer reference.deinit();
        var dig = try testDigController(&meta);
        defer dig.deinit();
        try dig.reservePlaneScratch(allocator, npc_count + 1);
        // The player stays out of both runs: its cell is already latched.
        if (playerCellEntry(&dig, &staged.world, &staged.data, staged.player)) |entry| dig.player_last_cell = entry.cell;

        var frame = SimulationFrame.init(allocator);
        defer frame.deinit();
        try frame.reserveStreams(4, npc_count + 1, 0, 0, 0, 0);
        frame.beginStep();
        var staged_entry = PlaneEntrySystem.init(allocator);
        defer staged_entry.deinit();
        const staged_entries = try staged_entry.gather(&staged.data, &staged.world, staged.player.entity, dig.tunnel_tile, null);
        const reservation = try dig.reservePlaneTraversalStage(&staged.world, &staged.data, &staged.player, &frame, staged_entries, &serial_threads);
        const staged_carves = reservation.carves;
        try dig.commitPlaneTraversalStage(&staged.world, &staged.data, &staged.player, &frame, reservation, &serial_threads);

        // The reference: the same entries in the same order, attaches first.
        var plane_entry = PlaneEntrySystem.init(allocator);
        defer plane_entry.deinit();
        const entries = try plane_entry.gather(&reference.data, &reference.world, reference.player.entity, dig.tunnel_tile, null);
        for (entries) |entry| {
            if (entry.needs_world_level) try reference.data.setWorldLevel(entry.entity, entry.level);
        }
        var reference_carves: std.ArrayList(WorldTileChangedEvent) = .empty;
        defer reference_carves.deinit(allocator);
        for (entries) |entry| {
            try referencePlaneTraversal(&dig, &reference.world, &reference.data, entry.entity, entry.level, entry.cell, &reference_carves);
            const pre_carved = entry.target.action == .fall and !entry.target.carve;
            reference_cancels += @intFromBool(entry.target.action == .fall and !pre_carved and reference.data.worldLevelConst(entry.entity).? == entry.level);
        }

        for (0..staged.world.dense_layers.len) |layer| {
            for (0..8) |y| for (0..8) |x| {
                try std.testing.expectEqual(reference.world.denseTile(layer, @intCast(x), @intCast(y)), staged.world.denseTile(layer, @intCast(x), @intCast(y)));
            };
        }
        const staged_ai = staged.data.aiAgentSliceConst().entities;
        const reference_ai = reference.data.aiAgentSliceConst().entities;
        for (staged_ai, reference_ai) |staged_npc, reference_npc| {
            try std.testing.expectEqual(reference.data.worldLevelConst(reference_npc), staged.data.worldLevelConst(staged_npc));
            try std.testing.expectEqual(reference.data.movementBodyConst(reference_npc).?.position, staged.data.movementBodyConst(staged_npc).?.position);
        }
        var staged_buffer: [npc_count]WorldTileChangedEvent = undefined;
        const staged_changes = try worldTileChangesOf(&frame, &staged_buffer);
        std.mem.sort(WorldTileChangedEvent, staged_changes, {}, changeLessThan);
        std.mem.sort(WorldTileChangedEvent, reference_carves.items, {}, changeLessThan);
        try std.testing.expectEqualSlices(WorldTileChangedEvent, reference_carves.items, staged_changes);
        // Exact: one carve per landing the reference carved, so no shared landing is
        // written twice or reserved twice in nav.
        try std.testing.expectEqual(reference_carves.items.len, staged_carves);
    }
    // The seeds reach the re-judged case: a fall whose hole an earlier carve shut.
    try std.testing.expect(reference_cancels > 0);
}

// Falls whose landings lie on two levels and four chunks, entered in AI row order that is
// not (level, chunk) order: the stage's one carve batch, serial or on `threads`, carves
// every landing and publishes the carves in (level, chunk, cell) order.
fn runCrossChunkFalls(meta: *const world_tileset_meta.WorldTilesetMeta, threads: *ThreadSystem, out: *[8]WorldTileChangedEvent) ![]WorldTileChangedEvent {
    const allocator = std.testing.allocator;
    // 8x8 cells in 4-cell chunks: four chunks per level.
    var world = try WorldSystem.initDemoFromMetaWithChunkSize(allocator, meta, meta.tileSize() * 8, meta.tileSize() * 8, 4);
    defer world.deinit();
    try world.addUndergroundLevels(meta);
    const holes = [_]struct { level: u16, cell: CellCoord }{
        .{ .level = 1, .cell = .{ .x = 2, .y = 6 } },
        .{ .level = 0, .cell = .{ .x = 6, .y = 6 } },
        .{ .level = 1, .cell = .{ .x = 5, .y = 1 } },
        .{ .level = 0, .cell = .{ .x = 1, .y = 1 } },
    };
    var data = DataSystem.init(allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    var npcs: [holes.len]EntityId = undefined;
    for (holes, &npcs) |hole, *npc| {
        _ = try world.clearDenseTile(world.denseFloorLayerForLevel(hole.level).?, hole.cell.x, hole.cell.y);
        npc.* = try addCellEntryNpcOnLevel(&data, .{ .x = hole.cell.x - 1, .y = hole.cell.y }, hole.cell, hole.level);
    }
    var dig = try testDigController(meta);
    defer dig.deinit();
    try dig.reservePlaneScratch(allocator, holes.len + 1);
    // One chunk per range, so a threaded run dispatches both batch stages to workers.
    dig.carve_controls = .{ .adaptive = false, .items_per_range = 1 };
    if (playerCellEntry(&dig, &world, &data, player)) |entry| dig.player_last_cell = entry.cell;
    var frame = try testPlaneFrame();
    defer frame.deinit();
    var plane_entry = PlaneEntrySystem.init(allocator);
    defer plane_entry.deinit();
    const entries = try plane_entry.gather(&data, &world, player.entity, dig.tunnel_tile, threads);
    const reservation = try dig.reservePlaneTraversalStage(&world, &data, &player, &frame, entries, threads);
    try std.testing.expectEqual(holes.len, reservation.carves);
    try std.testing.expectEqual(holes.len, reservation.carve_chunks.len);
    try dig.commitPlaneTraversalStage(&world, &data, &player, &frame, reservation, threads);
    for (holes, npcs) |hole, npc| {
        try std.testing.expectEqual(@as(?u16, hole.level + 1), data.worldLevelConst(npc));
        try std.testing.expectEqual(dig.tunnel_tile, world.denseTile(world.denseFloorLayerForLevel(hole.level + 1).?, hole.cell.x, hole.cell.y));
    }
    return worldTileChangesOf(&frame, out);
}

test "plane stage carves landings entered out of chunk order across levels in one ordered batch, serial and threaded alike" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    var serial_buffer: [8]WorldTileChangedEvent = undefined;
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    const serial = try runCrossChunkFalls(&meta, &serial_threads, &serial_buffer);
    // Landings on level 1 (chunks 0, 3), then level 2 (chunks 1, 2).
    const want = [_][3]u16{ .{ 1, 1, 1 }, .{ 1, 6, 6 }, .{ 2, 5, 1 }, .{ 2, 2, 6 } };
    try std.testing.expectEqual(want.len, serial.len);
    for (want, serial) |cell, change| try std.testing.expectEqual(cell, [3]u16{ change.level, change.x, change.y });

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var threaded_buffer: [8]WorldTileChangedEvent = undefined;
    const threaded = try runCrossChunkFalls(&meta, &threads, &threaded_buffer);
    try std.testing.expectEqualSlices(WorldTileChangedEvent, serial, threaded);
}

test "plane claims dedupe within a step and start each step empty without touching a slot" {
    var claims: PlaneClaims = .{};
    defer claims.deinit(std.testing.allocator);
    try claims.reserve(std.testing.allocator, 40);
    try std.testing.expect(claims.usable() >= 40);
    for (0..2) |_| {
        claims.beginStep();
        for (0..40) |index| try std.testing.expect(claims.insert(@as(u64, index % 3) << 32 | index * 977));
        for (0..40) |index| {
            const key = @as(u64, index % 3) << 32 | index * 977;
            try std.testing.expect(claims.contains(key));
            try std.testing.expect(!claims.insert(key));
        }
        try std.testing.expect(!claims.contains(1 << 40));
    }
    const slots_before = try std.testing.allocator.dupe(PlaneClaims.Slot, claims.slots);
    defer std.testing.allocator.free(slots_before);
    claims.beginStep();
    try std.testing.expectEqualSlices(PlaneClaims.Slot, slots_before, claims.slots);
    try std.testing.expect(!claims.contains(977));
}

fn runDig(tw: *TestWorld, dig: DigController, intent: @import("simulation.zig").DigIntent) !SimulationFrame {
    var frame = SimulationFrame.init(std.testing.allocator);
    errdefer frame.deinit();
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    frame.beginStep();
    frame.dig_intent = intent;
    try testDig(&dig, &tw.world, &tw.data, tw.player, &frame);
    return frame;
}

test "a dig returns UnresolvedDigTiles without mutating world" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 0);
    defer tw.deinit();
    // Default DigConfig leaves ramp/tunnel as invalid_tile_id — must fail before carve.
    const dig = DigController.init(.{});
    const floor = tw.world.denseFloorLayerForLevel(0).?;
    const before = tw.world.denseTile(floor, 4, 3);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 8, 8, 8, 8, 8);
    frame.beginStep();
    frame.dig_intent = .hole;
    try std.testing.expectError(error.UnresolvedDigTiles, testDig(&dig, &tw.world, &tw.data, tw.player, &frame));
    try std.testing.expectEqual(before, tw.world.denseTile(floor, 4, 3));
    try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);
}

test "dig controller punches a see-through hole in the faced cell" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 0);
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
    var tw: TestWorld = undefined;
    try tw.init(.right, 1);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);

    const floor = tw.world.denseFloorLayerForLevel(1).?;
    // The faced underground cell starts as solid dirt.
    try std.testing.expect(denseTileBlocksMovement(&tw.world, floor, 4, 3));

    var frame = try runDig(&tw, dig, .hole);
    defer frame.deinit();

    // Mining carves the walkable tunnel tile (not a see-through hole).
    try std.testing.expectEqual(dig.tunnel_tile, tw.world.denseTile(floor, 4, 3));
    try std.testing.expect(!denseTileBlocksMovement(&tw.world, floor, 4, 3));

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
    var tw: TestWorld = undefined;
    try tw.init(.right, 1);
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
    var tw: TestWorld = undefined;
    try tw.init(.right, 2);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);

    var frame = try runDig(&tw, dig, .down);
    defer frame.deinit();

    try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 0), frame.stimuli.mergedItems().len);
    // The bottom floor cell stays solid: there is nothing below to fall into.
    const floor = tw.world.denseFloorLayerForLevel(2).?;
    try std.testing.expect(denseTileBlocksMovement(&tw.world, floor, 4, 3));
}

test "dig controller carves a ramp tile and one bidirectional link below the surface" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 1);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);

    var frame = try runDig(&tw, dig, .ramp);
    defer frame.deinit();

    const floor = tw.world.denseFloorLayerForLevel(1).?;
    try std.testing.expectEqual(dig.ramp_tile, tw.world.denseTile(floor, 4, 3));

    const links = tw.world.levelLinks();
    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expectEqual(@import("world/system.zig").LevelLinkKind.ramp, links[0].kind);
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
    var tw: TestWorld = undefined;
    try tw.init(.right, 0);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);

    var frame = try runDig(&tw, dig, .ramp);
    defer frame.deinit();

    try std.testing.expectEqual(@as(usize, 0), tw.world.levelLinks().len);
    try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 0), frame.stimuli.mergedItems().len);
}

test "dig controller is a no-op for none intent or an off-world target" {
    var tw: TestWorld = undefined;
    try tw.init(.left, 0);
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

test "the plane stage carves an NPC's landing cell before it falls and snaps it into the pocket" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 0);
    defer tw.deinit();
    var dig = try testDigController(&tw.meta);
    defer dig.deinit();
    try dig.reservePlaneScratch(std.testing.allocator, 4);

    // A surface hole over level 1's solid dirt, as a `.down` dig leaves it.
    const floor0 = tw.world.denseFloorLayerForLevel(0).?;
    _ = try tw.world.clearDenseTile(floor0, 4, 3);
    const floor1 = tw.world.denseFloorLayerForLevel(1).?;
    try std.testing.expect(denseTileBlocksMovement(&tw.world, floor1, 4, 3));
    const npc = try addCellEntryNpc(&tw.data, .{ .x = 3, .y = 3 }, .{ .x = 4, .y = 3 });

    var frame = try testPlaneFrame();
    defer frame.deinit();
    try testPlaneTraversalStage(&dig, &tw.world, &tw.data, &tw.player, &frame);

    try std.testing.expectEqual(@as(?u16, 1), tw.data.worldLevelConst(npc));
    // Carved walkable rather than leaving the NPC embedded in solid dirt, which would
    // soft-lock it against the tile gate.
    try std.testing.expectEqual(dig.tunnel_tile, tw.world.denseTile(floor1, 4, 3));
    var changes_buffer: [2]WorldTileChangedEvent = undefined;
    const changes = try worldTileChangesOf(&frame, &changes_buffer);
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqual(dig.tunnel_tile, changes[0].new_tile_id);
    const body = tw.data.movementBodyConst(npc).?;
    try std.testing.expectEqual(@as(f32, 4 * 32), body.position.x);
    try std.testing.expectEqual(@as(f32, 3 * 32), body.position.y);
}

test "a dig commit reserves event capacity before world mutate (capacity miss leaves tile unchanged)" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 0);
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

    try std.testing.expectError(error.EventCapacityExceeded, testDig(&dig, &tw.world, &tw.data, tw.player, &frame));
    try std.testing.expectEqual(before, tw.world.denseTile(floor, 4, 3));
    try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);

    // A ramp under rock needs two events; a budget of one leaves both cells and the
    // links as they were.
    var ramp_tw: TestWorld = undefined;
    try ramp_tw.init(.right, 2);
    defer ramp_tw.deinit();
    var ramp_frame = SimulationFrame.init(std.testing.allocator);
    defer ramp_frame.deinit();
    try ramp_frame.reserveStreams(4, 1, 8, 8, 8, 8);
    ramp_frame.beginStep();
    ramp_frame.dig_intent = .ramp;
    const ramp_floor = ramp_tw.world.denseFloorLayerForLevel(2).?;
    const exit_floor = ramp_tw.world.denseFloorLayerForLevel(1).?;
    const ramp_before = ramp_tw.world.denseTile(ramp_floor, 4, 3);
    const exit_before = ramp_tw.world.denseTile(exit_floor, 4, 3);
    try std.testing.expectError(error.EventCapacityExceeded, testDig(&dig, &ramp_tw.world, &ramp_tw.data, ramp_tw.player, &ramp_frame));
    try std.testing.expectEqual(ramp_before, ramp_tw.world.denseTile(ramp_floor, 4, 3));
    try std.testing.expectEqual(exit_before, ramp_tw.world.denseTile(exit_floor, 4, 3));
    try std.testing.expect(ramp_tw.world.levelBlocksMovement(1, 4, 3));
    try std.testing.expectEqual(@as(usize, 0), ramp_tw.world.levelLinks().len);
    try std.testing.expectEqual(@as(usize, 0), ramp_frame.events.mergedItems().len);
}

test "player_last_cell advances only after successful or intentional no-op traversal" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 0);
    defer tw.deinit();
    var dig = try testDigController(&tw.meta);
    defer dig.deinit();
    try dig.reservePlaneScratch(std.testing.allocator, 4);

    // Hole under the player so the first cell entry falls and carves.
    const floor0 = tw.world.denseFloorLayerForLevel(0).?;
    _ = try tw.world.clearDenseTile(floor0, 3, 3);
    // Seed last_cell elsewhere so (3,3) counts as a new entry.
    dig.player_last_cell = .{ .x = 0, .y = 0 };

    var frame = try testPlaneFrame();
    defer frame.deinit();
    try testPlaneTraversalStage(&dig, &tw.world, &tw.data, &tw.player, &frame);
    try std.testing.expectEqual(@as(usize, 1), frame.events.stats.world_tile_changed);
    try std.testing.expectEqual(@as(u16, 1), tw.player.current_level);
    try std.testing.expectEqual(CellCoord{ .x = 3, .y = 3 }, dig.player_last_cell.?);

    // Same cell again: an intentional no-op, latch unchanged and nothing carved.
    try testPlaneTraversalStage(&dig, &tw.world, &tw.data, &tw.player, &frame);
    try std.testing.expectEqual(@as(usize, 1), frame.events.stats.world_tile_changed);
    try std.testing.expectEqual(CellCoord{ .x = 3, .y = 3 }, dig.player_last_cell.?);
}

test "player_last_cell stays put when the player's traversal fails or has no body, and the retry falls" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 0);
    defer tw.deinit();
    var dig = try testDigController(&tw.meta);
    defer dig.deinit();
    try dig.reservePlaneScratch(std.testing.allocator, 4);

    const floor0 = tw.world.denseFloorLayerForLevel(0).?;
    _ = try tw.world.clearDenseTile(floor0, 3, 3);
    dig.player_last_cell = .{ .x = 0, .y = 0 };
    const floor1 = tw.world.denseFloorLayerForLevel(1).?;
    const landing_before = tw.world.denseTile(floor1, 3, 3);

    // Missing body: no cell entry this step, so the latch waits for a body.
    var ghost = tw.player;
    ghost.entity = .{ .index = 9999, .generation = 1 };
    var frame = try testPlaneFrame();
    defer frame.deinit();
    try testPlaneTraversalStage(&dig, &tw.world, &tw.data, &ghost, &frame);
    try std.testing.expectEqual(CellCoord{ .x = 0, .y = 0 }, dig.player_last_cell.?);

    // A player missing `world_level` whose attach cannot grow fails in the reserve,
    // before any write: no carve, no fall, latch unchanged.
    var fresh_data = DataSystem.init(std.testing.allocator);
    defer fresh_data.deinit();
    const fresh = try fresh_data.createEntity();
    try fresh_data.setMovementBody(fresh, .{});
    try fresh_data.setPrimitiveVisual(fresh, .{
        .size = .{ .x = 32, .y = 32 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    });
    fresh_data.movementBodyPtr(fresh).?.position_x.* = 96;
    fresh_data.movementBodyPtr(fresh).?.position_y.* = 96;
    var fresh_player = tw.player;
    fresh_player.entity = fresh;
    {
        const original = fresh_data.allocator;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        fresh_data.allocator = failing.allocator();
        defer fresh_data.allocator = original;
        try std.testing.expectError(error.OutOfMemory, testPlaneTraversalStage(&dig, &tw.world, &fresh_data, &fresh_player, &frame));
    }
    try std.testing.expectEqual(CellCoord{ .x = 0, .y = 0 }, dig.player_last_cell.?);
    try std.testing.expectEqual(landing_before, tw.world.denseTile(floor1, 3, 3));
    try std.testing.expect(fresh_data.worldLevelConst(fresh) == null);

    // The retry attaches, falls, carves, and latches.
    try testPlaneTraversalStage(&dig, &tw.world, &fresh_data, &fresh_player, &frame);
    try std.testing.expectEqual(@as(u16, 1), fresh_player.current_level);
    try std.testing.expectEqual(@as(?u16, 1), fresh_data.worldLevelConst(fresh));
    try std.testing.expectEqual(dig.tunnel_tile, tw.world.denseTile(floor1, 3, 3));
    try std.testing.expectEqual(CellCoord{ .x = 3, .y = 3 }, dig.player_last_cell.?);
}

test "plane traversal OOM on an NPC's world_level attach leaves the landing tile unchanged" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 0);
    defer tw.deinit();
    var dig = try testDigController(&tw.meta);
    defer dig.deinit();
    try dig.reservePlaneScratch(std.testing.allocator, 4);

    const floor0 = tw.world.denseFloorLayerForLevel(0).?;
    _ = try tw.world.clearDenseTile(floor0, 4, 3);
    const floor1 = tw.world.denseFloorLayerForLevel(1).?;
    const landing_before = tw.world.denseTile(floor1, 4, 3);
    // A fresh data system holding only the NPC, so its world_level store has no
    // capacity and the attach must grow it; the player is a bodiless stand-in.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const npc = try addCellEntryNpcOnLevel(&data, .{ .x = 3, .y = 3 }, .{ .x = 4, .y = 3 }, null);
    var ghost = tw.player;
    ghost.entity = .{ .index = 9999, .generation = 1 };

    var frame = try testPlaneFrame();
    defer frame.deinit();
    const original = data.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    data.allocator = failing.allocator();
    defer data.allocator = original;
    try std.testing.expectError(error.OutOfMemory, testPlaneTraversalStage(&dig, &tw.world, &data, &ghost, &frame));
    try std.testing.expectEqual(landing_before, tw.world.denseTile(floor1, 4, 3));
    try std.testing.expect(data.worldLevelConst(npc) == null);
    try std.testing.expectEqual(@as(usize, 0), frame.events.stats.world_tile_changed);
}

test "player spawn pre-attaches world_level so the first fall allocates nothing in the data stores" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 0);
    defer tw.deinit();
    var dig = try testDigController(&tw.meta);
    defer dig.deinit();
    try dig.reservePlaneScratch(std.testing.allocator, 4);
    try std.testing.expectEqual(@as(?u16, 0), tw.data.worldLevelConst(tw.player.entity));

    const floor0 = tw.world.denseFloorLayerForLevel(0).?;
    _ = try tw.world.clearDenseTile(floor0, 3, 3);

    // The fall only updates the existing world_level row and scope metadata.
    var frame = try testPlaneFrame();
    defer frame.deinit();
    const original = tw.data.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    tw.data.allocator = failing.allocator();
    defer tw.data.allocator = original;
    try testPlaneTraversalStage(&dig, &tw.world, &tw.data, &tw.player, &frame);
    try std.testing.expectEqual(@as(u16, 1), tw.player.current_level);
    try std.testing.expectEqual(@as(?u16, 1), tw.data.worldLevelConst(tw.player.entity));
    try std.testing.expectEqual(@as(usize, 1), frame.events.stats.world_tile_changed);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "a ramp dig whose link reserve fails leaves the ramp tile unchanged" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 1);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);

    const floor = tw.world.denseFloorLayerForLevel(1).?;
    const before = tw.world.denseTile(floor, 4, 3);
    try std.testing.expect(before != dig.ramp_tile);
    // Warm terrain pools leave the empty link rows as the reserve's first allocation.
    try warmLandingTerrain(&tw.world, dig.ramp_tile, 1, .{ 4, 3 });
    try std.testing.expectEqual(@as(usize, 0), tw.world.level_links.capacity);

    const original = tw.world.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    tw.world.allocator = failing.allocator();
    defer tw.world.allocator = original;
    try std.testing.expectError(error.OutOfMemory, dig.reserveWorldEdit(&tw.world, &tw.data, tw.player, .ramp));
    try std.testing.expectEqual(before, tw.world.denseTile(floor, 4, 3));
    try std.testing.expectEqual(@as(usize, 0), tw.world.levelLinks().len);
}

test "a dig committed after its one reserve allocates nothing in the world (FailingAllocator)" {
    inline for (.{ DigIntent.hole, DigIntent.ramp }) |intent| {
        var tw: TestWorld = undefined;
        try tw.init(.right, 1);
        defer tw.deinit();
        const dig = try testDigController(&tw.meta);
        // The faced level-1 cell sits in a uniform, fully blocked chunk, so the carve
        // takes a fresh tile block and composed-bits slot (and a ramp its link row).
        const floor = tw.world.denseFloorLayerForLevel(1).?;
        try std.testing.expect(denseTileBlocksMovement(&tw.world, floor, 4, 3));

        const edit = (try dig.reserveWorldEdit(&tw.world, &tw.data, tw.player, intent)).?;
        try std.testing.expectEqual(@as(u16, 1), edit.level);
        var frame = SimulationFrame.init(std.testing.allocator);
        defer frame.deinit();
        try frame.reserveStreams(4, 8, 8, 8, 8, 8);
        frame.beginStep();

        // The frame's streams are warm, so the event preflight and the publish allocate
        // nothing either.
        const original_events = frame.events.stream.allocator;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        tw.world.allocator = failing.allocator();
        frame.events.stream.allocator = failing.allocator();
        defer {
            tw.world.allocator = std.testing.allocator;
            frame.events.stream.allocator = original_events;
        }
        try DigController.commitWorldEdit(&tw.world, edit, &frame);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
        try std.testing.expect(!tw.world.levelBlocksMovement(1, 4, 3));
        try std.testing.expectEqual(@as(usize, 1), frame.events.mergedItems().len);
        try std.testing.expectEqual(@as(usize, 1), frame.events.rangeCount());
        if (intent == .ramp) {
            try std.testing.expectEqual(@as(?u16, 0), tw.world.rampLinkOtherLevel(1, .{ .x = 4, .y = 3 }));
        }
    }

    // A ramp whose exit holds a solid floor, a blocking overlay, and blocking sparse
    // tiles: the exit's blocks, bits slot, and both events fit the one reserve and
    // the preflight, with room for exactly one more event range.
    var tw: TestWorld = undefined;
    try tw.init(.right, 2);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);
    try addBlockingExitContent(&tw.world, &tw.meta);
    const edit = (try dig.reserveWorldEdit(&tw.world, &tw.data, tw.player, .ramp)).?;
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 64, 8, 8, 8, 8);
    frame.beginStep();
    const filler = SimulationEvent{
        .stage = .domain_reaction,
        .payload = .{ .world_tile_changed = .{ .level = 0, .x = 0, .y = 0, .old_tile_id = 0, .new_tile_id = 1 } },
    };
    while (spareEventRanges(&frame) > 1) try frame.events.appendRequired(filler);
    try std.testing.expectEqual(@as(usize, 1), spareEventRanges(&frame));
    const events_before = frame.events.mergedItems().len;
    const ranges_before = frame.events.rangeCount();

    const original_events = frame.events.stream.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    tw.world.allocator = failing.allocator();
    frame.events.stream.allocator = failing.allocator();
    defer {
        tw.world.allocator = std.testing.allocator;
        frame.events.stream.allocator = original_events;
    }
    try DigController.commitWorldEdit(&tw.world, edit, &frame);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!tw.world.levelBlocksMovement(1, 4, 3));
    try std.testing.expect(!tw.world.levelBlocksMovement(2, 4, 3));
    try std.testing.expectEqual(events_before + 2, frame.events.mergedItems().len);
    try std.testing.expectEqual(ranges_before + 1, frame.events.rangeCount());
    const published = frame.events.mergedItems()[events_before..];
    try std.testing.expect(published[0].payload == .world_tile_changed);
    try std.testing.expect(published[1].payload == .world_obstacle_changed);
    try std.testing.expectEqual(@as(?u16, 1), tw.world.rampLinkOtherLevel(2, .{ .x = 4, .y = 3 }));
}

// Event ranges the frame can still append without growing any per-range list.
fn spareEventRanges(frame: *const SimulationFrame) usize {
    const stream = &frame.events.stream;
    return @min(
        @min(stream.counts.capacity - stream.counts.items.len, frame.events.range_stats.capacity - frame.events.range_stats.items.len),
        @min(stream.offsets.capacity - stream.offsets.items.len, stream.write_offsets.capacity - stream.write_offsets.items.len),
    );
}

// Puts blocking content in the ramp exit cell (4, 3) on level 1 besides its solid
// floor: a blocking overlay band (filled solid, so the clear takes a block), two
// blocking sparse tiles and one walkable decal there, and one blocking sparse tile
// next door at (5, 3).
fn addBlockingExitContent(world: *WorldSystem, meta: *const world_tileset_meta.WorldTilesetMeta) !void {
    const tree = try world.requireTileByName(meta, "tree_0");
    const deco = try world.requireTileByName(meta, "deco_0");
    const stone = try world.requireTileByName(meta, "stone_floor");
    _ = try world.addDenseLayer(1, 0, .obstacle, tree);
    _ = try world.addSparseTile(1, 4, 3, deco, 0, .obstacle);
    _ = try world.addSparseTile(1, 4, 3, stone, 0, .floor);
    _ = try world.addSparseTile(1, 5, 3, deco, 0, .obstacle);
    _ = try world.addSparseTile(1, 4, 3, tree, 0, .obstacle);
}

// The level's overlay band: the last dense layer, added by `addBlockingExitContent`.
fn exitOverlayLayer(world: *const WorldSystem) usize {
    return world.dense_layers.len - 1;
}

// Level `level`'s sparse tiles as (cell, tile) pairs in row order, into `out`.
fn sparseRowsOf(world: *const WorldSystem, level: u16, out: []CellTile) []CellTile {
    var count: usize = 0;
    for (world.sparse_tiles.items(.level_index), 0..) |row_level, index| {
        if (row_level != level) continue;
        out[count] = .{ .cell = sparseTileCellCoord(world, index), .tile = world.sparse_tiles.items(.tile_id)[index] };
        count += 1;
    }
    return out[0..count];
}

const CellTile = struct { cell: CellCoord, tile: TileId };

fn eventsOf(frame: *const SimulationFrame) []const SimulationEvent {
    return frame.events.mergedItems();
}

test "a ramp dug under solid rock opens its exit cell on the level above in the same dig and emits both events" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 2);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);
    const ramp_floor = tw.world.denseFloorLayerForLevel(2).?;
    const exit_floor = tw.world.denseFloorLayerForLevel(1).?;
    try std.testing.expect(tw.world.levelBlocksMovement(1, 4, 3));

    var frame = try runDig(&tw, dig, .ramp);
    defer frame.deinit();

    try std.testing.expectEqual(dig.ramp_tile, tw.world.denseTile(ramp_floor, 4, 3));
    try std.testing.expectEqual(dig.tunnel_tile, tw.world.denseTile(exit_floor, 4, 3));
    try std.testing.expect(!tw.world.levelBlocksMovement(2, 4, 3));
    try std.testing.expect(!tw.world.levelBlocksMovement(1, 4, 3));
    // Only the exit cell opens on the level above.
    try std.testing.expect(tw.world.levelBlocksMovement(1, 5, 3));
    try std.testing.expectEqual(@as(?u16, 1), tw.world.rampLinkOtherLevel(2, .{ .x = 4, .y = 3 }));
    try std.testing.expectEqual(@as(?u16, 2), tw.world.rampLinkOtherLevel(1, .{ .x = 4, .y = 3 }));

    const events = eventsOf(&frame);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    const ramp_change = switch (events[0].payload) {
        .world_tile_changed => |change| change,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u16, 2), ramp_change.level);
    try std.testing.expectEqual(@as(u16, 4), ramp_change.x);
    try std.testing.expectEqual(@as(u16, 3), ramp_change.y);
    try std.testing.expectEqual(dig.ramp_tile, ramp_change.new_tile_id);
    const exit_change = switch (events[1].payload) {
        .world_obstacle_changed => |change| change,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(WorldObstacleChangedEvent{ .level = 1, .min_x = 4, .min_y = 3, .max_x_exclusive = 5, .max_y_exclusive = 4 }, exit_change);
    try std.testing.expectEqual(@as(usize, 1), frame.stimuli.mergedItems().len);
}

test "a ramp exit clears a blocking obstacle band and blocking sparse tiles with the floor" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 2);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);
    try addBlockingExitContent(&tw.world, &tw.meta);
    const overlay = exitOverlayLayer(&tw.world);
    const tree = try tw.world.requireTileByName(&tw.meta, "tree_0");
    const deco = try tw.world.requireTileByName(&tw.meta, "deco_0");
    const stone = try tw.world.requireTileByName(&tw.meta, "stone_floor");

    var frame = try runDig(&tw, dig, .ramp);
    defer frame.deinit();

    const exit_floor = tw.world.denseFloorLayerForLevel(1).?;
    try std.testing.expectEqual(dig.tunnel_tile, tw.world.denseTile(exit_floor, 4, 3));
    try std.testing.expectEqual(invalid_tile_id, tw.world.denseTile(overlay, 4, 3));
    try std.testing.expectEqual(tree, tw.world.denseTile(overlay, 5, 3));
    try std.testing.expect(!tw.world.levelBlocksMovement(1, 4, 3));
    try std.testing.expect(tw.world.levelBlocksMovement(1, 5, 3));
    // The walkable decal and the neighbour's blocking tile remain.
    var rows_buf: [4]CellTile = undefined;
    const rows = sparseRowsOf(&tw.world, 1, &rows_buf);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    for (rows) |row| {
        const expected: CellTile = if (row.cell.x == 4) .{ .cell = .{ .x = 4, .y = 3 }, .tile = stone } else .{ .cell = .{ .x = 5, .y = 3 }, .tile = deco };
        try std.testing.expectEqual(expected, row);
    }
    try std.testing.expectEqual(@as(usize, 2), eventsOf(&frame).len);
    try std.testing.expectEqual(@as(?u16, 1), tw.world.rampLinkOtherLevel(2, .{ .x = 4, .y = 3 }));
}

test "a ramp whose exit is a hole writes nothing at the exit and still links" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 2);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);
    const exit_floor = tw.world.denseFloorLayerForLevel(1).?;
    _ = try tw.world.clearDenseTile(exit_floor, 4, 3);

    var frame = try runDig(&tw, dig, .ramp);
    defer frame.deinit();

    try std.testing.expectEqual(invalid_tile_id, tw.world.denseTile(exit_floor, 4, 3));
    try std.testing.expectEqual(@as(?u16, 1), tw.world.rampLinkOtherLevel(2, .{ .x = 4, .y = 3 }));
    const events = eventsOf(&frame);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expect(events[0].payload == .world_tile_changed);
}

test "a ramp exit on walkable floor emits only the ramp event" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 2);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);
    const exit_floor = tw.world.denseFloorLayerForLevel(1).?;
    _ = try tw.world.setDenseTile(exit_floor, 4, 3, dig.tunnel_tile);
    const stone = try tw.world.requireTileByName(&tw.meta, "stone_floor");
    _ = try tw.world.addSparseTile(1, 4, 3, stone, 0, .floor);

    var frame = try runDig(&tw, dig, .ramp);
    defer frame.deinit();

    try std.testing.expectEqual(dig.tunnel_tile, tw.world.denseTile(exit_floor, 4, 3));
    var rows_buffer: [4]CellTile = undefined;
    try std.testing.expectEqual(@as(usize, 1), sparseRowsOf(&tw.world, 1, &rows_buffer).len);
    try std.testing.expectEqual(@as(?u16, 1), tw.world.rampLinkOtherLevel(2, .{ .x = 4, .y = 3 }));
    const events = eventsOf(&frame);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expect(events[0].payload == .world_tile_changed);
}

test "a ramp dig that runs out of memory at every allocation leaves both cells, the sparse tiles, and the links unchanged" {
    var fail_index: usize = 0;
    var failures: usize = 0;
    while (true) : (fail_index += 1) {
        var tw: TestWorld = undefined;
        try tw.init(.right, 2);
        defer tw.deinit();
        const dig = try testDigController(&tw.meta);
        try addBlockingExitContent(&tw.world, &tw.meta);
        const overlay = exitOverlayLayer(&tw.world);
        const ramp_floor = tw.world.denseFloorLayerForLevel(2).?;
        const exit_floor = tw.world.denseFloorLayerForLevel(1).?;
        var frame = SimulationFrame.init(std.testing.allocator);
        defer frame.deinit();
        try frame.reserveStreams(4, 8, 8, 8, 8, 8);
        frame.beginStep();
        frame.dig_intent = .ramp;
        const ramp_before = tw.world.denseTile(ramp_floor, 4, 3);
        const exit_before = tw.world.denseTile(exit_floor, 4, 3);
        const overlay_before = tw.world.denseTile(overlay, 4, 3);
        var rows_before_buf: [4]CellTile = undefined;
        const rows_before = sparseRowsOf(&tw.world, 1, &rows_before_buf);

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = 0 });
        tw.world.allocator = failing.allocator();
        const result = testDig(&dig, &tw.world, &tw.data, tw.player, &frame);
        tw.world.allocator = std.testing.allocator;
        if (result) |_| {
            // Every allocation index up to the dig's last failed once before this run.
            try std.testing.expect(failures > 0);
            try std.testing.expect(!tw.world.levelBlocksMovement(1, 4, 3));
            try std.testing.expectEqual(@as(usize, 2), frame.events.mergedItems().len);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            try std.testing.expectEqual(ramp_before, tw.world.denseTile(ramp_floor, 4, 3));
            try std.testing.expectEqual(exit_before, tw.world.denseTile(exit_floor, 4, 3));
            try std.testing.expectEqual(overlay_before, tw.world.denseTile(overlay, 4, 3));
            try std.testing.expect(tw.world.levelBlocksMovement(2, 4, 3));
            try std.testing.expect(tw.world.levelBlocksMovement(1, 4, 3));
            var rows_after_buf: [4]CellTile = undefined;
            try std.testing.expectEqualSlices(CellTile, rows_before, sparseRowsOf(&tw.world, 1, &rows_after_buf));
            try std.testing.expectEqual(@as(usize, 0), tw.world.levelLinks().len);
            try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);
            try std.testing.expectEqual(@as(usize, 0), frame.stimuli.mergedItems().len);
        }
    }
}

test "dig reserveWorldEdit OOM leaves the world unchanged" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 1);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);
    const floor = tw.world.denseFloorLayerForLevel(1).?;
    const before = tw.world.denseTile(floor, 4, 3);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    tw.world.allocator = failing.allocator();
    defer tw.world.allocator = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, dig.reserveWorldEdit(&tw.world, &tw.data, tw.player, .ramp));
    try std.testing.expectEqual(before, tw.world.denseTile(floor, 4, 3));
    try std.testing.expect(tw.world.levelBlocksMovement(1, 4, 3));
    try std.testing.expectEqual(@as(usize, 0), tw.world.levelLinks().len);
}

test "a dig commit on a full live bus leaves the tile unchanged" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 0);
    defer tw.deinit();
    const dig = try testDigController(&tw.meta);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.events.reserve(4, 8);
    frame.events.setCapacityLimit(8);
    try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);
    frame.beginStep();
    for (0..stimulus_live_capacity) |i| {
        try frame.writeLiveStimulus(.{
            .position = .{ .x = @floatFromInt(i), .y = 0 },
            .intensity = 1,
            .kind = .footstep,
            .level = 0,
        });
    }
    frame.dig_intent = .hole;

    const floor = tw.world.denseFloorLayerForLevel(0).?;
    const before = tw.world.denseTile(floor, 4, 3);

    try std.testing.expectError(error.StimulusCapacityExceeded, testDig(&dig, &tw.world, &tw.data, tw.player, &frame));
    try std.testing.expectEqual(before, tw.world.denseTile(floor, 4, 3));
    try std.testing.expectEqual(@as(usize, 0), frame.events.mergedItems().len);
    try std.testing.expectEqual(stimulus_live_capacity, frame.stimuli.mergedItems().len);
}

test "a dig commit stimulus capacity miss leaves tile unchanged" {
    var tw: TestWorld = undefined;
    try tw.init(.right, 0);
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

    try std.testing.expectError(error.OutOfMemory, testDig(&dig, &tw.world, &tw.data, tw.player, &frame));
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
