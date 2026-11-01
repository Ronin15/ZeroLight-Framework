// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Movement-body component storage: dense SoA rows for position/velocity plus
//! the in-lockstep simulation-scope columns (tier/chunk/stagger/level), and the
//! movement-body payload validator. Mirrors pathfinding's per-domain package
//! modules.

const std = @import("std");
const types = @import("types.zig");
const EntityId = types.EntityId;
const Facing = types.Facing;
const MovementBody = types.MovementBody;
const MovementBodyPtr = types.MovementBodyPtr;
const CollisionBounds = types.CollisionBounds;
const SpriteAssetId = @import("../../assets/manifest.zig").SpriteAssetId;
const MovementBodySlice = types.MovementBodySlice;
const ConstMovementBodySlice = types.ConstMovementBodySlice;
const ScopeColumnsSlice = types.ScopeColumnsSlice;
const ConstScopeColumnsSlice = types.ConstScopeColumnsSlice;
const hotStoreCapacity = types.hotStoreCapacity;
const no_component_row = types.no_component_row;
const EntitySimulationMetadata = @import("../simulation_scope.zig").EntitySimulationMetadata;
const SimulationTier = @import("../simulation_scope.zig").SimulationTier;
const cognition_stagger_n = @import("../simulation_scope.zig").cognition_stagger_n;
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");

pub fn validateMovementBody(body: MovementBody) !void {
    if (!std.math.isFinite(body.position.x) or !std.math.isFinite(body.position.y)) return error.InvalidMovementBody;
    if (!std.math.isFinite(body.previous_position.x) or !std.math.isFinite(body.previous_position.y)) return error.InvalidMovementBody;
    if (!std.math.isFinite(body.velocity.x) or !std.math.isFinite(body.velocity.y)) return error.InvalidMovementBody;
    if (!std.math.isFinite(body.speed) or body.speed < 0) return error.InvalidMovementBody;
}

const ArrivalCount = struct {
    next: u32,
    live: u32,
};

const ArrivalHold = struct {
    world: u32 = 0,
    key: u128 = 0,
    held: bool = false,
};

const OtherStaggerWorld = struct {
    cell_size: f32 = 0,
    cells_x: u32 = 0,
    cells_y: u32 = 0,
    arrivals: std.AutoHashMapUnmanaged(u128, ArrivalCount) = .empty,
    level_origins: std.AutoHashMapUnmanaged(u16, u32) = .empty,
};

const MovementBodyRow = struct {
    entity: EntityId,
    position_x: f32,
    position_y: f32,
    position_z: i32,
    previous_x: f32,
    previous_y: f32,
    velocity_x: f32,
    velocity_y: f32,
    speed: f32,
    has_primitive_visual: bool = false,
    // Mirror of the entity's `CollisionBounds` (zero without one) and its AI membership,
    // written only by `DataSystem` at the commit seam.
    bounds_offset_x: f32 = 0,
    bounds_offset_y: f32 = 0,
    bounds_size_x: f32 = 0,
    bounds_size_y: f32 = 0,
    has_collision_bounds: bool = false,
    has_ai_agent: bool = false,
    tier: SimulationTier,
    chunk_x: i32,
    chunk_y: i32,
    level: u16,
    stagger_phase: u8,
    // Set once `commitStagger` or a named phase write lands. Unset rows still hold the
    // append placeholder `dense_index % cognition_stagger_n`.
    stagger_settled: bool = false,
    always_active: bool,
    // Linked component rows. `no_component_row` when that component is absent.
    ai_row: u32 = no_component_row,
    bounds_row: u32 = no_component_row,
    // Index of this row's drawable run, and its slot in that run. `no_drawable` is none.
    drawable_run: u32 = no_drawable,
    drawable_slot: u32 = no_drawable,
};

const no_drawable: u32 = std.math.maxInt(u32);

const DrawableRow = struct {
    entity: EntityId,
    movement_index: u32,
    previous_x: f32,
    position_x: f32,
    previous_y: f32,
    position_y: f32,
    position_z: i32,
    size_x: f32 = 0,
    size_y: f32 = 0,
    color_r: f32 = 0,
    color_g: f32 = 0,
    color_b: f32 = 0,
    color_a: f32 = 0,
    depth_value: i32 = 0,
    has_asset: bool = false,
    // Unread when `has_asset` is false.
    sprite: SpriteAssetId = @as(SpriteAssetId, @fromBackingInt(0)),
    atlas_entry_id: u16 = 0,
    has_facing: bool = false,
    // Unread when `has_facing` is false.
    direction: Facing = .down,
    marker_color_r: f32 = 0,
    marker_color_g: f32 = 0,
    marker_color_b: f32 = 0,
    marker_color_a: f32 = 0,
    marker_depth_value: i32 = 0,
    marker_length: f32 = 0,
    marker_depth: f32 = 0,
    marker_margin: f32 = 0,
};

/// Appearance columns of one drawable row, by value.
const DrawableAppearance = struct {
    size_x: f32,
    size_y: f32,
    color_r: f32,
    color_g: f32,
    color_b: f32,
    color_a: f32,
    depth_value: i32,
    has_asset: bool,
    sprite: SpriteAssetId,
    atlas_entry_id: u16,
    has_facing: bool,
    direction: Facing,
    marker_color_r: f32,
    marker_color_g: f32,
    marker_color_b: f32,
    marker_color_a: f32,
    marker_depth_value: i32,
    marker_length: f32,
    marker_depth: f32,
    marker_margin: f32,
};

/// Every column collect reads from one drawable run.
pub const DrawableRunColumns = struct {
    entity: []EntityId,
    movement_index: []u32,
    previous_x: []f32,
    position_x: []f32,
    previous_y: []f32,
    position_y: []f32,
    position_z: []i32,
    size_x: []f32,
    size_y: []f32,
    color_r: []f32,
    color_g: []f32,
    color_b: []f32,
    color_a: []f32,
    depth_value: []i32,
    has_asset: []bool,
    sprite: []SpriteAssetId,
    atlas_entry_id: []u16,
    has_facing: []bool,
    direction: []Facing,
    marker_color_r: []f32,
    marker_color_g: []f32,
    marker_color_b: []f32,
    marker_color_a: []f32,
    marker_depth_value: []i32,
    marker_length: []f32,
    marker_depth: []f32,
    marker_margin: []f32,
};

const DrawableRun = struct {
    rows: std.MultiArrayList(DrawableRow) = .empty,
    refreshed_epoch: u32 = 0,
    key: u128 = 0,
    live: bool = false,
    // Slots reserved past `rows.len` and not yet linked. Zero outside a reserve/link.
    reserved_extra: u32 = 0,
};

fn drawableKey(level: u16, chunk_x: i32, chunk_y: i32) u128 {
    const x: u32 = @bitCast(chunk_x);
    const y: u32 = @bitCast(chunk_y);
    return (@as(u128, level) << 64) | (@as(u128, x) << 32) | y;
}

pub const MovementBodyStore = struct {
    rows: std.MultiArrayList(MovementBodyRow) = .{},
    // One run per occupied (level, chunk) of drawable rows. Map values are indices into `runs`.
    runs: std.ArrayList(DrawableRun) = .empty,
    free_runs: std.ArrayList(u32) = .empty,
    run_of: std.AutoHashMapUnmanaged(u128, u32) = .empty,
    pose_epoch: u32 = 0,
    // A key is one cell that still has a live holder. It leaves when `live` hits 0.
    // The level origin stays until that world is released.
    arrivals: std.AutoHashMapUnmanaged(u128, ArrivalCount) = .empty,
    // Next origin for a level's first AI arrival in a cell. Absent means 0.
    level_origins: std.AutoHashMapUnmanaged(u16, u32) = .empty,
    cell_size: f32 = 0,
    cells_x: u32 = 0,
    cells_y: u32 = 0,
    // Cold, one per movement row, swap-removed with it. The fixed step reads `stagger_phase` only.
    arrival_holds: std.ArrayList(ArrivalHold) = .empty,
    // Every world id but 0: its own grid and arrival maps. Id 0 uses the fields above.
    other_worlds: std.AutoHashMapUnmanaged(u32, OtherStaggerWorld) = .empty,

    pub fn len(self: *const MovementBodyStore) usize {
        return self.rows.len;
    }

    pub fn append(self: *MovementBodyStore, allocator: std.mem.Allocator, entity: EntityId, body: MovementBody) !u32 {
        // `u32` row indices: exhausting them fails at this growth seam as `OutOfMemory`.
        if (self.rows.len >= std.math.maxInt(u32)) return error.OutOfMemory;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.rows.len);
        self.rows.appendAssumeCapacity(.{
            .entity = entity,
            .position_x = body.position.x,
            .position_y = body.position.y,
            .position_z = body.position_z,
            .previous_x = body.previous_position.x,
            .previous_y = body.previous_position.y,
            .velocity_x = body.velocity.x,
            .velocity_y = body.velocity.y,
            .speed = body.speed,
            .tier = .cognition,
            .chunk_x = 0,
            .chunk_y = 0,
            .level = 0,
            .stagger_phase = @intCast(index % cognition_stagger_n),
            .stagger_settled = false,
            .always_active = false,
            .ai_row = no_component_row,
            .bounds_row = no_component_row,
        });
        self.arrival_holds.appendAssumeCapacity(.{});
        std.debug.assert(self.arrival_holds.items.len == self.rows.len);
        return index;
    }

    pub fn set(self: *MovementBodyStore, index: usize, body: MovementBody) void {
        const s = self.rows.slice();
        s.items(.position_x)[index] = body.position.x;
        s.items(.position_y)[index] = body.position.y;
        s.items(.position_z)[index] = body.position_z;
        s.items(.previous_x)[index] = body.previous_position.x;
        s.items(.previous_y)[index] = body.previous_position.y;
        s.items(.velocity_x)[index] = body.velocity.x;
        s.items(.velocity_y)[index] = body.velocity.y;
        s.items(.speed)[index] = body.speed;
        self.writeRunPose(index, body);
    }

    pub fn get(self: *const MovementBodyStore, index: usize) MovementBody {
        const s = self.rows.slice();
        return .{
            .position = .{ .x = s.items(.position_x)[index], .y = s.items(.position_y)[index] },
            .previous_position = .{ .x = s.items(.previous_x)[index], .y = s.items(.previous_y)[index] },
            .position_z = s.items(.position_z)[index],
            .velocity = .{ .x = s.items(.velocity_x)[index], .y = s.items(.velocity_y)[index] },
            .speed = s.items(.speed)[index],
        };
    }

    pub fn ptrAt(self: *MovementBodyStore, index: usize) MovementBodyPtr {
        const s = self.rows.slice();
        return .{
            .position_x = &s.items(.position_x)[index],
            .position_y = &s.items(.position_y)[index],
            .position_z = &s.items(.position_z)[index],
            .previous_x = &s.items(.previous_x)[index],
            .previous_y = &s.items(.previous_y)[index],
            .velocity_x = &s.items(.velocity_x)[index],
            .velocity_y = &s.items(.velocity_y)[index],
            .speed = &s.items(.speed)[index],
        };
    }

    pub fn tierAt(self: *const MovementBodyStore, index: usize) SimulationTier {
        return self.rows.slice().items(.tier)[index];
    }

    pub fn setHasPrimitiveVisual(self: *MovementBodyStore, allocator: std.mem.Allocator, index: usize, has_visual: bool) !void {
        const had = self.rows.slice().items(.has_primitive_visual)[index];
        if (had == has_visual) return;
        if (has_visual) {
            // The flag lands after the link, so a failed place leaves the row unlinked and a retry places it.
            try self.placeDrawable(allocator, index);
            self.rows.slice().items(.has_primitive_visual)[index] = true;
        } else {
            self.unlinkDrawable(index);
            self.rows.slice().items(.has_primitive_visual)[index] = false;
        }
    }

    /// Mirrors `bounds` onto row `index` and marks it bounded.
    pub fn setCollisionBounds(self: *MovementBodyStore, index: usize, bounds: CollisionBounds) void {
        const s = self.rows.slice();
        s.items(.bounds_offset_x)[index] = bounds.offset.x;
        s.items(.bounds_offset_y)[index] = bounds.offset.y;
        s.items(.bounds_size_x)[index] = bounds.size.x;
        s.items(.bounds_size_y)[index] = bounds.size.y;
        s.items(.has_collision_bounds)[index] = true;
    }

    pub fn setHasAiAgent(self: *MovementBodyStore, index: usize, has_agent: bool) void {
        self.rows.slice().items(.has_ai_agent)[index] = has_agent;
    }

    pub fn aiRowAt(self: *const MovementBodyStore, index: usize) u32 {
        return self.rows.slice().items(.ai_row)[index];
    }

    pub fn setAiRow(self: *MovementBodyStore, index: usize, ai_row: u32) void {
        self.rows.slice().items(.ai_row)[index] = ai_row;
    }

    pub fn aiRowColumn(self: *MovementBodyStore) []u32 {
        return self.rows.slice().items(.ai_row);
    }

    pub fn boundsRowAt(self: *const MovementBodyStore, index: usize) u32 {
        return self.rows.slice().items(.bounds_row)[index];
    }

    pub fn setBoundsRow(self: *MovementBodyStore, index: usize, bounds_row: u32) void {
        self.rows.slice().items(.bounds_row)[index] = bounds_row;
    }

    pub fn scopeMetadataAt(self: *const MovementBodyStore, index: usize) EntitySimulationMetadata {
        const s = self.rows.slice();
        return .{
            .tier = s.items(.tier)[index],
            .chunk = .{ .x = s.items(.chunk_x)[index], .y = s.items(.chunk_y)[index] },
            .level = s.items(.level)[index],
            .stagger_phase = s.items(.stagger_phase)[index],
            .always_active = s.items(.always_active)[index],
        };
    }

    pub fn setScopeMetadata(self: *MovementBodyStore, index: usize, metadata: EntitySimulationMetadata) void {
        const s = self.rows.slice();
        s.items(.tier)[index] = metadata.tier;
        s.items(.chunk_x)[index] = metadata.chunk.x;
        s.items(.chunk_y)[index] = metadata.chunk.y;
        // Resolved by the caller: a scope row always holds a level.
        s.items(.level)[index] = metadata.level.?;
        s.items(.stagger_phase)[index] = metadata.stagger_phase;
        s.items(.always_active)[index] = metadata.always_active;
    }

    pub fn markStaggerSettled(self: *MovementBodyStore, index: usize) void {
        self.rows.slice().items(.stagger_settled)[index] = true;
    }

    /// Stores the index build's cell grid on world 0. The same scalars are a no-op. Different scalars
    /// with arrivals or level origins already recorded assert: residues were counted on the previous grid.
    pub fn setStaggerCellGrid(self: *MovementBodyStore, cell_size: f32, cells_x: u32, cells_y: u32) void {
        installStaggerScalars(&self.cell_size, &self.cells_x, &self.cells_y, self.arrivals.count(), self.level_origins.count(), cell_size, cells_x, cells_y);
    }

    /// Installs `world_id`'s cell grid. Id 0 is `setStaggerCellGrid` and allocates nothing.
    /// Any other id get-or-puts its own record (the only allocation) and applies the same
    /// scalar rule to that record. A failed put inserts nothing.
    pub fn setStaggerWorldGrid(self: *MovementBodyStore, allocator: std.mem.Allocator, world_id: u32, cell_size: f32, cells_x: u32, cells_y: u32) !void {
        if (world_id == 0) {
            self.setStaggerCellGrid(cell_size, cells_x, cells_y);
            return;
        }
        const gop = try self.other_worlds.getOrPut(allocator, world_id);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const world = gop.value_ptr;
        installStaggerScalars(&world.cell_size, &world.cells_x, &world.cells_y, world.arrivals.count(), world.level_origins.count(), cell_size, cells_x, cells_y);
    }

    /// Reserves one new arrival key and one level origin per structural AI arrival on world 0.
    /// The commit inserts at most that many; cells that already have a residue insert none.
    pub fn ensureStaggerMapCapacity(self: *MovementBodyStore, allocator: std.mem.Allocator, additional: usize) !void {
        try ensureStaggerMaps(allocator, &self.level_origins, &self.arrivals, additional);
    }

    fn ensureStaggerMaps(
        allocator: std.mem.Allocator,
        level_origins: *std.AutoHashMapUnmanaged(u16, u32),
        arrivals: *std.AutoHashMapUnmanaged(u128, ArrivalCount),
        additional: usize,
    ) !void {
        if (additional == 0) return;
        const slots: u32 = @intCast(additional);
        try level_origins.ensureUnusedCapacity(allocator, slots);
        try arrivals.ensureUnusedCapacity(allocator, slots);
    }

    /// True when a commit would read the row: the grid is installed and the phase is not settled.
    pub fn staggerCommitOpen(self: *const MovementBodyStore, index: usize) bool {
        if (self.cells_x == 0 or self.cells_y == 0) return false;
        return !self.rows.slice().items(.stagger_settled)[index];
    }

    /// Settles an AI row `index` on `world_id`'s grid. A missing grid, a settled row, or a row
    /// with no AI does nothing: no AI row keeps its placeholder and takes no residue. The first
    /// AI body in a cell takes the level origin; later bodies take that cell's next residue.
    /// `assume_capacity` puts a new level origin and arrival key into capacity already reserved.
    /// Otherwise those two slots are reserved before either put. A failed reserve inserts neither
    /// key and does not advance the origin. A residue also records the row's hold.
    pub fn commitStagger(self: *MovementBodyStore, allocator: std.mem.Allocator, world_id: u32, index: usize, level: u16, has_ai: bool, assume_capacity: bool) !void {
        const grid = self.staggerWorldMaps(world_id) orelse return;
        if (self.rows.slice().items(.stagger_settled)[index]) return;
        if (!has_ai) return;
        const s = self.rows.slice();
        const cell_x = math.worldPosToCell(s.items(.previous_x)[index], grid.cell_size, grid.cells_x);
        const cell_y = math.worldPosToCell(s.items(.previous_y)[index], grid.cell_size, grid.cells_y);
        const key: u128 = (@as(u128, level) << 64) | (@as(u128, cell_x) << 32) | cell_y;
        const phase = try nextStaggerResidue(allocator, grid.level_origins, grid.arrivals, level, key, assume_capacity);
        const row = self.rows.slice();
        row.items(.stagger_phase)[index] = phase;
        row.items(.stagger_settled)[index] = true;
        self.arrival_holds.items[index] = .{ .world = world_id, .key = key, .held = true };
    }

    fn nextStaggerResidue(
        allocator: std.mem.Allocator,
        level_origins: *std.AutoHashMapUnmanaged(u16, u32),
        arrivals: *std.AutoHashMapUnmanaged(u128, ArrivalCount),
        level: u16,
        key: u128,
        assume_capacity: bool,
    ) !u8 {
        if (arrivals.getPtr(key)) |count| {
            const phase: u8 = @intCast(count.next % cognition_stagger_n);
            count.next += 1;
            count.live += 1;
            return phase;
        }
        if (!assume_capacity) try ensureStaggerMaps(allocator, level_origins, arrivals, 1);
        const level_gop = level_origins.getOrPutAssumeCapacity(level);
        if (!level_gop.found_existing) level_gop.value_ptr.* = 0;
        const origin = level_gop.value_ptr.*;
        const cell_gop = arrivals.getOrPutAssumeCapacity(key);
        std.debug.assert(!cell_gop.found_existing);
        cell_gop.value_ptr.* = .{ .next = origin + 1, .live = 1 };
        level_gop.value_ptr.* = origin + 1;
        return @intCast(origin % cognition_stagger_n);
    }

    pub fn setTier(self: *MovementBodyStore, index: usize, tier: SimulationTier) void {
        self.rows.slice().items(.tier)[index] = tier;
    }

    pub fn snapPreviousToPosition(self: *MovementBodyStore, index: usize) void {
        const s = self.rows.slice();
        s.items(.previous_x)[index] = s.items(.position_x)[index];
        s.items(.previous_y)[index] = s.items(.position_y)[index];
    }

    pub fn zeroVelocity(self: *MovementBodyStore, index: usize) void {
        const s = self.rows.slice();
        s.items(.velocity_x)[index] = 0;
        s.items(.velocity_y)[index] = 0;
    }

    pub fn removeAt(self: *MovementBodyStore, index: usize) ?EntityId {
        std.debug.assert(self.arrival_holds.items.len == self.rows.len);
        const hold = self.arrival_holds.items[index];
        if (hold.held) self.dropArrivalHold(hold);
        _ = self.arrival_holds.swapRemove(index);
        const s = self.rows.slice();
        const last = self.rows.len - 1;
        const moved_entity = if (index != last) s.items(.entity)[last] else null;
        self.rows.swapRemove(index);
        return moved_entity;
    }

    pub fn slice(self: *MovementBodyStore) MovementBodySlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .position_x = s.items(.position_x),
            .position_y = s.items(.position_y),
            .position_z = s.items(.position_z),
            .previous_x = s.items(.previous_x),
            .previous_y = s.items(.previous_y),
            .velocity_x = s.items(.velocity_x),
            .velocity_y = s.items(.velocity_y),
            .speed = s.items(.speed),
            .has_primitive_visual = s.items(.has_primitive_visual),
            .bounds_offset_x = s.items(.bounds_offset_x),
            .bounds_offset_y = s.items(.bounds_offset_y),
            .bounds_size_x = s.items(.bounds_size_x),
            .bounds_size_y = s.items(.bounds_size_y),
            .has_collision_bounds = s.items(.has_collision_bounds),
            .has_ai_agent = s.items(.has_ai_agent),
        };
    }

    pub fn sliceConst(self: *const MovementBodyStore) ConstMovementBodySlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .position_x = s.items(.position_x),
            .position_y = s.items(.position_y),
            .position_z = s.items(.position_z),
            .previous_x = s.items(.previous_x),
            .previous_y = s.items(.previous_y),
            .velocity_x = s.items(.velocity_x),
            .velocity_y = s.items(.velocity_y),
            .speed = s.items(.speed),
            .has_primitive_visual = s.items(.has_primitive_visual),
            .bounds_offset_x = s.items(.bounds_offset_x),
            .bounds_offset_y = s.items(.bounds_offset_y),
            .bounds_size_x = s.items(.bounds_size_x),
            .bounds_size_y = s.items(.bounds_size_y),
            .has_collision_bounds = s.items(.has_collision_bounds),
            .has_ai_agent = s.items(.has_ai_agent),
        };
    }

    pub fn scopeSlice(self: *MovementBodyStore) ScopeColumnsSlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .tier = s.items(.tier),
            .chunk_x = s.items(.chunk_x),
            .chunk_y = s.items(.chunk_y),
            .level = s.items(.level),
            .stagger_phase = s.items(.stagger_phase),
            .always_active = s.items(.always_active),
        };
    }

    pub fn scopeSliceConst(self: *const MovementBodyStore) ConstScopeColumnsSlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .tier = s.items(.tier),
            .chunk_x = s.items(.chunk_x),
            .chunk_y = s.items(.chunk_y),
            .level = s.items(.level),
            .stagger_phase = s.items(.stagger_phase),
            .always_active = s.items(.always_active),
        };
    }

    pub fn clearRetainingCapacity(self: *MovementBodyStore) void {
        self.rows.clearRetainingCapacity();
        self.arrival_holds.clearRetainingCapacity();
        self.arrivals.clearRetainingCapacity();
        self.level_origins.clearRetainingCapacity();
        var worlds = self.other_worlds.iterator();
        while (worlds.next()) |entry| {
            entry.value_ptr.arrivals.clearRetainingCapacity();
            entry.value_ptr.level_origins.clearRetainingCapacity();
        }
        self.run_of.clearRetainingCapacity();
        self.free_runs.clearRetainingCapacity();
        self.pose_epoch = 0;
        for (self.runs.items, 0..) |*run, index| {
            run.rows.clearRetainingCapacity();
            run.live = false;
            run.key = 0;
            run.refreshed_epoch = 0;
            run.reserved_extra = 0;
            self.free_runs.appendAssumeCapacity(@intCast(index));
        }
    }

    pub fn deinit(self: *MovementBodyStore, allocator: std.mem.Allocator) void {
        for (self.runs.items) |*run| run.rows.deinit(allocator);
        self.runs.deinit(allocator);
        self.free_runs.deinit(allocator);
        self.run_of.deinit(allocator);
        self.arrival_holds.deinit(allocator);
        var worlds = self.other_worlds.iterator();
        while (worlds.next()) |entry| {
            entry.value_ptr.arrivals.deinit(allocator);
            entry.value_ptr.level_origins.deinit(allocator);
        }
        self.other_worlds.deinit(allocator);
        self.arrivals.deinit(allocator);
        self.level_origins.deinit(allocator);
        self.rows.deinit(allocator);
        self.* = .{};
    }

    /// Frees `world_id`'s arrival map and level origins. A live hold for that id still owns a
    /// key: the caller destroys those rows first so `removeAt` drops the claims. Id 0's maps
    /// are left empty; any other id's record is removed. Rows that did not hold this id stay.
    pub fn releaseStaggerWorld(self: *MovementBodyStore, allocator: std.mem.Allocator, world_id: u32) void {
        for (self.arrival_holds.items) |hold| {
            std.debug.assert(!(hold.held and hold.world == world_id));
        }
        if (world_id == 0) {
            self.arrivals.deinit(allocator);
            self.level_origins.deinit(allocator);
            self.arrivals = .empty;
            self.level_origins = .empty;
            return;
        }
        if (self.other_worlds.fetchRemove(world_id)) |removed| {
            var world = removed.value;
            world.arrivals.deinit(allocator);
            world.level_origins.deinit(allocator);
        }
    }

    pub fn bumpPoseEpoch(self: *MovementBodyStore) void {
        self.pose_epoch +%= 1;
    }

    pub fn drawableRunIndex(self: *const MovementBodyStore, level: u16, chunk_x: i32, chunk_y: i32) ?u32 {
        return self.run_of.get(drawableKey(level, chunk_x, chunk_y));
    }

    pub fn drawableRunLength(self: *const MovementBodyStore, run_index: u32) usize {
        return self.runs.items[run_index].rows.len;
    }

    /// Copies movement poses into a visible run when `pose_epoch` moved. Off-view runs are not called.
    pub fn refreshRunPose(self: *MovementBodyStore, run_index: u32) void {
        const run = &self.runs.items[run_index];
        if (run.refreshed_epoch == self.pose_epoch) return;
        const drawn = run.rows.slice();
        const movement = self.rows.slice();
        for (drawn.items(.movement_index), 0..) |movement_index, slot| {
            const row = movement_index;
            drawn.items(.previous_x)[slot] = movement.items(.previous_x)[row];
            drawn.items(.position_x)[slot] = movement.items(.position_x)[row];
            drawn.items(.previous_y)[slot] = movement.items(.previous_y)[row];
            drawn.items(.position_y)[slot] = movement.items(.position_y)[row];
            drawn.items(.position_z)[slot] = movement.items(.position_z)[row];
        }
        run.refreshed_epoch = self.pose_epoch;
    }

    /// Copies row `index`'s pose into its slot in `run_index`. Does not walk the run
    /// and does not mark it refreshed, so the other rows stay stale.
    pub fn refreshSlotPose(self: *MovementBodyStore, index: usize, run_index: u32) ?usize {
        const movement = self.rows.slice();
        if (movement.items(.drawable_run)[index] != run_index) return null;
        const slot: usize = movement.items(.drawable_slot)[index];
        const drawn = self.runs.items[run_index].rows.slice();
        drawn.items(.previous_x)[slot] = movement.items(.previous_x)[index];
        drawn.items(.position_x)[slot] = movement.items(.position_x)[index];
        drawn.items(.previous_y)[slot] = movement.items(.previous_y)[index];
        drawn.items(.position_y)[slot] = movement.items(.position_y)[index];
        drawn.items(.position_z)[slot] = movement.items(.position_z)[index];
        return slot;
    }

    pub fn drawableRunSlice(self: *MovementBodyStore, run_index: u32) DrawableRunColumns {
        const drawn = self.runs.items[run_index].rows.slice();
        return .{
            .entity = drawn.items(.entity),
            .movement_index = drawn.items(.movement_index),
            .previous_x = drawn.items(.previous_x),
            .position_x = drawn.items(.position_x),
            .previous_y = drawn.items(.previous_y),
            .position_y = drawn.items(.position_y),
            .position_z = drawn.items(.position_z),
            .size_x = drawn.items(.size_x),
            .size_y = drawn.items(.size_y),
            .color_r = drawn.items(.color_r),
            .color_g = drawn.items(.color_g),
            .color_b = drawn.items(.color_b),
            .color_a = drawn.items(.color_a),
            .depth_value = drawn.items(.depth_value),
            .has_asset = drawn.items(.has_asset),
            .sprite = drawn.items(.sprite),
            .atlas_entry_id = drawn.items(.atlas_entry_id),
            .has_facing = drawn.items(.has_facing),
            .direction = drawn.items(.direction),
            .marker_color_r = drawn.items(.marker_color_r),
            .marker_color_g = drawn.items(.marker_color_g),
            .marker_color_b = drawn.items(.marker_color_b),
            .marker_color_a = drawn.items(.marker_color_a),
            .marker_depth_value = drawn.items(.marker_depth_value),
            .marker_length = drawn.items(.marker_length),
            .marker_depth = drawn.items(.marker_depth),
            .marker_margin = drawn.items(.marker_margin),
        };
    }

    /// The row at `index` moved there from the tail. Its run entry still names the old index.
    pub fn retieDrawableMovementIndex(self: *MovementBodyStore, index: usize) void {
        const movement = self.rows.slice();
        const run_index = movement.items(.drawable_run)[index];
        if (run_index == no_drawable) return;
        const slot = movement.items(.drawable_slot)[index];
        self.runs.items[run_index].rows.slice().items(.movement_index)[slot] = @intCast(index);
    }

    pub fn unlinkDrawable(self: *MovementBodyStore, index: usize) void {
        const movement = self.rows.slice();
        const run_index = movement.items(.drawable_run)[index];
        if (run_index == no_drawable) return;
        const slot: usize = movement.items(.drawable_slot)[index];
        const run = &self.runs.items[run_index];
        const last = run.rows.len - 1;
        if (slot != last) {
            const moved_movement = run.rows.slice().items(.movement_index)[last];
            run.rows.swapRemove(slot);
            self.rows.slice().items(.drawable_slot)[moved_movement] = @intCast(slot);
        } else {
            run.rows.swapRemove(slot);
        }
        const row = self.rows.slice();
        row.items(.drawable_run)[index] = no_drawable;
        row.items(.drawable_slot)[index] = no_drawable;
        // A reservation is a link that has not run yet. Releasing here drops that destination from `run_of`.
        if (run.rows.len == 0 and run.reserved_extra == 0) self.releaseRun(run_index);
    }

    pub fn placeDrawable(self: *MovementBodyStore, allocator: std.mem.Allocator, index: usize) !void {
        const movement = self.rows.slice();
        if (movement.items(.drawable_run)[index] != no_drawable) return;
        const level = movement.items(.level)[index];
        const chunk_x = movement.items(.chunk_x)[index];
        const chunk_y = movement.items(.chunk_y)[index];
        try self.reserveDrawableDestination(allocator, level, chunk_x, chunk_y);
        self.commitDrawableLink(index, level, chunk_x, chunk_y);
        // A level change moves the row into the neighbor level's run. That run is
        // reserved with the visual, so the fall does not allocate.
        if (level > 0) try self.reserveDrawableDestination(allocator, level - 1, chunk_x, chunk_y);
        if (level != std.math.maxInt(u16)) try self.reserveDrawableDestination(allocator, level + 1, chunk_x, chunk_y);
    }

    /// Reserves the runs a level change from this row would move into, so that change allocates nothing.
    pub fn reserveDrawableNeighborLevels(self: *MovementBodyStore, allocator: std.mem.Allocator, index: usize) !void {
        const movement = self.rows.slice();
        if (!movement.items(.has_primitive_visual)[index]) return;
        const level = movement.items(.level)[index];
        const chunk_x = movement.items(.chunk_x)[index];
        const chunk_y = movement.items(.chunk_y)[index];
        if (level > 0) try self.reserveDrawableDestination(allocator, level - 1, chunk_x, chunk_y);
        if (level != std.math.maxInt(u16)) try self.reserveDrawableDestination(allocator, level + 1, chunk_x, chunk_y);
    }

    /// Reserves the run for (`level`, `chunk_x`, `chunk_y`) and one more row slot in it.
    /// Does not link. On error, drops this pass's reservations and any run that is still empty.
    pub fn reserveDrawableDestination(self: *MovementBodyStore, allocator: std.mem.Allocator, level: u16, chunk_x: i32, chunk_y: i32) !void {
        const run_index = self.runForKey(allocator, drawableKey(level, chunk_x, chunk_y)) catch |err| {
            self.abandonDrawableReservations();
            return err;
        };
        const run = &self.runs.items[run_index];
        const slots = run.reserved_extra + 1;
        run.rows.ensureTotalCapacity(allocator, run.rows.len + slots) catch |err| {
            self.abandonDrawableReservations();
            return err;
        };
        run.reserved_extra = slots;
    }

    /// Unlinks `index` and links it into a destination `reserveDrawableDestination` already reserved.
    /// Allocates nothing. Appearance is copied onto the new slot; the same-run return does not.
    pub fn relinkReservedDrawable(self: *MovementBodyStore, index: usize, level: u16, chunk_x: i32, chunk_y: i32) void {
        const key = drawableKey(level, chunk_x, chunk_y);
        const dest = self.run_of.get(key).?;
        const current = self.rows.slice().items(.drawable_run)[index];
        if (current == dest) {
            std.debug.assert(self.runs.items[dest].reserved_extra > 0);
            self.runs.items[dest].reserved_extra -= 1;
            return;
        }
        if (current != no_drawable) {
            const appearance = self.appearanceAt(index);
            self.unlinkDrawable(index);
            self.commitDrawableLink(index, level, chunk_x, chunk_y);
            self.writeDrawableAppearance(index, appearance);
        } else {
            self.unlinkDrawable(index);
            self.commitDrawableLink(index, level, chunk_x, chunk_y);
        }
    }

    /// Links `index` at (`level`, `chunk_x`, `chunk_y`). The destination run and its row slot are
    /// reserved before the unlink, so a failure leaves membership unchanged.
    pub fn retargetDrawable(self: *MovementBodyStore, allocator: std.mem.Allocator, index: usize, level: u16, chunk_x: i32, chunk_y: i32) !void {
        if (!self.rows.slice().items(.has_primitive_visual)[index]) return;
        const key = drawableKey(level, chunk_x, chunk_y);
        if (self.run_of.get(key)) |dest| {
            if (self.runs.items[dest].reserved_extra > 0) {
                self.relinkReservedDrawable(index, level, chunk_x, chunk_y);
                return;
            }
        }
        try self.reserveDrawableDestination(allocator, level, chunk_x, chunk_y);
        self.relinkReservedDrawable(index, level, chunk_x, chunk_y);
    }

    /// Writes `appearance` onto `index`'s drawable row. An unlinked row is unchanged.
    pub fn writeDrawableAppearance(self: *MovementBodyStore, index: usize, appearance: DrawableAppearance) void {
        // One mixed row, so the copy stays scalar.
        const movement = self.rows.slice();
        const run_index = movement.items(.drawable_run)[index];
        if (run_index == no_drawable) return;
        const slot: usize = movement.items(.drawable_slot)[index];
        const drawn = self.runs.items[run_index].rows.slice();
        drawn.items(.size_x)[slot] = appearance.size_x;
        drawn.items(.size_y)[slot] = appearance.size_y;
        drawn.items(.color_r)[slot] = appearance.color_r;
        drawn.items(.color_g)[slot] = appearance.color_g;
        drawn.items(.color_b)[slot] = appearance.color_b;
        drawn.items(.color_a)[slot] = appearance.color_a;
        drawn.items(.depth_value)[slot] = appearance.depth_value;
        drawn.items(.has_asset)[slot] = appearance.has_asset;
        drawn.items(.sprite)[slot] = appearance.sprite;
        drawn.items(.atlas_entry_id)[slot] = appearance.atlas_entry_id;
        drawn.items(.has_facing)[slot] = appearance.has_facing;
        drawn.items(.direction)[slot] = appearance.direction;
        drawn.items(.marker_color_r)[slot] = appearance.marker_color_r;
        drawn.items(.marker_color_g)[slot] = appearance.marker_color_g;
        drawn.items(.marker_color_b)[slot] = appearance.marker_color_b;
        drawn.items(.marker_color_a)[slot] = appearance.marker_color_a;
        drawn.items(.marker_depth_value)[slot] = appearance.marker_depth_value;
        drawn.items(.marker_length)[slot] = appearance.marker_length;
        drawn.items(.marker_depth)[slot] = appearance.marker_depth;
        drawn.items(.marker_margin)[slot] = appearance.marker_margin;
    }

    fn appearanceAt(self: *const MovementBodyStore, index: usize) DrawableAppearance {
        const movement = self.rows.slice();
        const run_index = movement.items(.drawable_run)[index];
        std.debug.assert(run_index != no_drawable);
        const slot: usize = movement.items(.drawable_slot)[index];
        const drawn = self.runs.items[run_index].rows.slice();
        return .{
            .size_x = drawn.items(.size_x)[slot],
            .size_y = drawn.items(.size_y)[slot],
            .color_r = drawn.items(.color_r)[slot],
            .color_g = drawn.items(.color_g)[slot],
            .color_b = drawn.items(.color_b)[slot],
            .color_a = drawn.items(.color_a)[slot],
            .depth_value = drawn.items(.depth_value)[slot],
            .has_asset = drawn.items(.has_asset)[slot],
            .sprite = drawn.items(.sprite)[slot],
            .atlas_entry_id = drawn.items(.atlas_entry_id)[slot],
            .has_facing = drawn.items(.has_facing)[slot],
            .direction = drawn.items(.direction)[slot],
            .marker_color_r = drawn.items(.marker_color_r)[slot],
            .marker_color_g = drawn.items(.marker_color_g)[slot],
            .marker_color_b = drawn.items(.marker_color_b)[slot],
            .marker_color_a = drawn.items(.marker_color_a)[slot],
            .marker_depth_value = drawn.items(.marker_depth_value)[slot],
            .marker_length = drawn.items(.marker_length)[slot],
            .marker_depth = drawn.items(.marker_depth)[slot],
            .marker_margin = drawn.items(.marker_margin)[slot],
        };
    }

    fn writeRunPose(self: *MovementBodyStore, index: usize, body: MovementBody) void {
        const movement = self.rows.slice();
        const run_index = movement.items(.drawable_run)[index];
        if (run_index == no_drawable) return;
        const slot = movement.items(.drawable_slot)[index];
        const drawn = self.runs.items[run_index].rows.slice();
        drawn.items(.previous_x)[slot] = body.previous_position.x;
        drawn.items(.position_x)[slot] = body.position.x;
        drawn.items(.previous_y)[slot] = body.previous_position.y;
        drawn.items(.position_y)[slot] = body.position.y;
        drawn.items(.position_z)[slot] = body.position_z;
    }

    fn runForKey(self: *MovementBodyStore, allocator: std.mem.Allocator, key: u128) !u32 {
        if (self.run_of.get(key)) |index| return index;
        const index = if (self.free_runs.pop()) |freed| freed else blk: {
            try self.runs.ensureTotalCapacity(allocator, self.runs.items.len + 1);
            // One spare so a failed map insert can return the new index to the free list.
            try self.free_runs.ensureTotalCapacity(allocator, self.runs.items.len + 2);
            const created: u32 = @intCast(self.runs.items.len);
            self.runs.appendAssumeCapacity(.{});
            break :blk created;
        };
        errdefer self.free_runs.appendAssumeCapacity(index);
        try self.run_of.ensureUnusedCapacity(allocator, 1);
        self.run_of.putAssumeCapacityNoClobber(key, index);
        const run = &self.runs.items[index];
        run.key = key;
        run.live = true;
        run.refreshed_epoch = self.pose_epoch;
        run.reserved_extra = 0;
        return index;
    }

    fn releaseRun(self: *MovementBodyStore, run_index: u32) void {
        const run = &self.runs.items[run_index];
        _ = self.run_of.remove(run.key);
        run.rows.clearRetainingCapacity();
        run.live = false;
        run.key = 0;
        run.reserved_extra = 0;
        self.free_runs.appendAssumeCapacity(run_index);
    }

    fn commitDrawableLink(self: *MovementBodyStore, index: usize, level: u16, chunk_x: i32, chunk_y: i32) void {
        const key = drawableKey(level, chunk_x, chunk_y);
        const run_index = self.run_of.get(key).?;
        const run = &self.runs.items[run_index];
        std.debug.assert(run.reserved_extra > 0);
        std.debug.assert(run.rows.capacity >= run.rows.len + 1);
        run.reserved_extra -= 1;
        const movement = self.rows.slice();
        const slot: u32 = @intCast(run.rows.len);
        run.rows.appendAssumeCapacity(.{
            .entity = movement.items(.entity)[index],
            .movement_index = @intCast(index),
            .previous_x = movement.items(.previous_x)[index],
            .position_x = movement.items(.position_x)[index],
            .previous_y = movement.items(.previous_y)[index],
            .position_y = movement.items(.position_y)[index],
            .position_z = movement.items(.position_z)[index],
        });
        const row = self.rows.slice();
        row.items(.drawable_run)[index] = run_index;
        row.items(.drawable_slot)[index] = slot;
    }

    fn abandonDrawableReservations(self: *MovementBodyStore) void {
        for (self.runs.items, 0..) |*run, index| {
            const empty = run.live and run.rows.len == 0;
            run.reserved_extra = 0;
            if (empty) self.releaseRun(@intCast(index));
        }
    }

    fn ensureCapacityForOne(self: *MovementBodyStore, allocator: std.mem.Allocator) !void {
        try self.ensureCapacity(allocator, self.rows.len + 1);
    }

    pub fn ensureCapacity(self: *MovementBodyStore, allocator: std.mem.Allocator, capacity: usize) !void {
        const slots = hotStoreCapacity(capacity);
        try self.rows.ensureTotalCapacity(allocator, slots);
        try self.arrival_holds.ensureTotalCapacity(allocator, slots);
    }

    fn staggerWorldMaps(self: *MovementBodyStore, world_id: u32) ?struct {
        cell_size: f32,
        cells_x: u32,
        cells_y: u32,
        arrivals: *std.AutoHashMapUnmanaged(u128, ArrivalCount),
        level_origins: *std.AutoHashMapUnmanaged(u16, u32),
    } {
        if (world_id == 0) {
            if (self.cells_x == 0 or self.cells_y == 0) return null;
            return .{
                .cell_size = self.cell_size,
                .cells_x = self.cells_x,
                .cells_y = self.cells_y,
                .arrivals = &self.arrivals,
                .level_origins = &self.level_origins,
            };
        }
        const world = self.other_worlds.getPtr(world_id) orelse return null;
        if (world.cells_x == 0 or world.cells_y == 0) return null;
        return .{
            .cell_size = world.cell_size,
            .cells_x = world.cells_x,
            .cells_y = world.cells_y,
            .arrivals = &world.arrivals,
            .level_origins = &world.level_origins,
        };
    }

    fn dropArrivalHold(self: *MovementBodyStore, hold: ArrivalHold) void {
        const arrivals = if (hold.world == 0)
            &self.arrivals
        else
            &self.other_worlds.getPtr(hold.world).?.arrivals;
        const count = arrivals.getPtr(hold.key).?;
        std.debug.assert(count.live > 0);
        count.live -= 1;
        if (count.live == 0) std.debug.assert(arrivals.remove(hold.key));
    }
};

fn installStaggerScalars(
    cell_size: *f32,
    cells_x: *u32,
    cells_y: *u32,
    arrivals_count: u32,
    origins_count: u32,
    new_cell_size: f32,
    new_cells_x: u32,
    new_cells_y: u32,
) void {
    std.debug.assert(std.math.isFinite(new_cell_size) and new_cell_size > 0);
    std.debug.assert(new_cells_x != 0 and new_cells_y != 0);
    if (cell_size.* == new_cell_size and cells_x.* == new_cells_x and cells_y.* == new_cells_y) return;
    std.debug.assert(arrivals_count == 0 and origins_count == 0);
    cell_size.* = new_cell_size;
    cells_x.* = new_cells_x;
    cells_y.* = new_cells_y;
}

test "simd range helpers cover movement body vector and scalar tail counts" {
    try std.testing.expectEqual(@as(usize, 0), simd.vectorizedEnd(@as(usize, 0)));
    try std.testing.expectEqual(@as(usize, 0), simd.vectorizedEnd(simd.lane_count - 1));
    try std.testing.expectEqual(@as(usize, simd.lane_count), simd.vectorizedEnd(simd.lane_count));
    try std.testing.expectEqual(@as(usize, simd.lane_count * 2), simd.vectorizedEnd(simd.lane_count * 2 + 1));
}

test "MovementBodyStore append is allocation-free after ensureCapacity reserves" {
    var store: MovementBodyStore = .{};
    defer store.deinit(std.testing.allocator);

    const reserved = 4;
    try store.ensureCapacity(std.testing.allocator, reserved);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const failing_alloc = failing.allocator();

    var i: u32 = 0;
    while (i < reserved) : (i += 1) {
        const entity = try EntityId.init(i, 1);
        _ = try store.append(failing_alloc, entity, .{});
    }
    try std.testing.expectEqual(@as(usize, reserved), store.len());
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

const data_test_support = @import("test_support.zig");

test "MovementBodyStore fails an append past its u32 row cap as OutOfMemory" {
    try data_test_support.expectRowCapOutOfMemory(MovementBodyStore, MovementBody{});
}

test "setHasPrimitiveVisual retries a failed place" {
    var store: MovementBodyStore = .{};
    defer store.deinit(std.testing.allocator);
    const entity = try EntityId.init(0, 1);
    const index: usize = try store.append(std.testing.allocator, entity, .{});

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, store.setHasPrimitiveVisual(failing.allocator(), index, true));
    try std.testing.expect(!store.slice().has_primitive_visual[index]);
    try std.testing.expect(store.drawableRunIndex(0, 0, 0) == null);

    try store.setHasPrimitiveVisual(std.testing.allocator, index, true);
    try std.testing.expect(store.slice().has_primitive_visual[index]);
    const run_index = store.drawableRunIndex(0, 0, 0).?;
    try std.testing.expectEqual(@as(usize, 1), store.drawableRunLength(run_index));
    try std.testing.expect(store.drawableRunSlice(run_index).entity[0].eql(entity));
}

test "drawable row append allocates nothing after its run slot is reserved" {
    var store: MovementBodyStore = .{};
    defer store.deinit(std.testing.allocator);
    const first = try EntityId.init(0, 1);
    const second = try EntityId.init(1, 1);
    const first_index: usize = try store.append(std.testing.allocator, first, .{});
    const second_index: usize = try store.append(std.testing.allocator, second, .{});
    try store.setHasPrimitiveVisual(std.testing.allocator, first_index, true);

    const run_index = store.drawableRunIndex(0, 0, 0).?;
    try store.runs.items[run_index].rows.ensureTotalCapacity(std.testing.allocator, store.runs.items[run_index].rows.len + 1);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    try store.setHasPrimitiveVisual(failing.allocator(), second_index, true);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(store.slice().has_primitive_visual[second_index]);
    try std.testing.expectEqual(@as(usize, 2), store.drawableRunLength(run_index));
}

test "new drawable run append allocates nothing after its list reserve" {
    var store: MovementBodyStore = .{};
    defer store.deinit(std.testing.allocator);
    try store.runs.ensureTotalCapacity(std.testing.allocator, 1);
    try store.free_runs.ensureTotalCapacity(std.testing.allocator, store.runs.items.len + 2);
    try store.run_of.ensureUnusedCapacity(std.testing.allocator, 1);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const run_index = try store.runForKey(failing.allocator(), drawableKey(1, 2, 3));
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(store.runs.items[run_index].live);
    try std.testing.expectEqual(drawableKey(1, 2, 3), store.runs.items[run_index].key);
}

test "set copies the pose into the drawable run and refreshRunPose copies it after bumpPoseEpoch" {
    var store: MovementBodyStore = .{};
    defer store.deinit(std.testing.allocator);
    const entity = try EntityId.init(0, 1);
    const index: usize = try store.append(std.testing.allocator, entity, .{ .position = .{ .x = 1, .y = 2 }, .position_z = 3 });
    try store.setHasPrimitiveVisual(std.testing.allocator, index, true);
    store.set(index, .{
        .position = .{ .x = 4, .y = 5 },
        .previous_position = .{ .x = 6, .y = 7 },
        .position_z = 8,
    });

    const run_index = store.drawableRunIndex(0, 0, 0).?;
    const placed = store.drawableRunSlice(run_index);
    try std.testing.expectEqual(@as(f32, 4), placed.position_x[0]);
    try std.testing.expectEqual(@as(f32, 5), placed.position_y[0]);
    try std.testing.expectEqual(@as(f32, 6), placed.previous_x[0]);
    try std.testing.expectEqual(@as(f32, 7), placed.previous_y[0]);
    try std.testing.expectEqual(@as(i32, 8), placed.position_z[0]);

    store.bumpPoseEpoch();
    const columns = store.rows.slice();
    columns.items(.position_x)[index] = 9;
    columns.items(.position_z)[index] = 10;
    try std.testing.expectEqual(@as(f32, 4), store.drawableRunSlice(run_index).position_x[0]);
    try std.testing.expectEqual(@as(i32, 8), store.drawableRunSlice(run_index).position_z[0]);
    store.refreshRunPose(run_index);
    try std.testing.expectEqual(@as(f32, 9), store.drawableRunSlice(run_index).position_x[0]);
    try std.testing.expectEqual(@as(i32, 10), store.drawableRunSlice(run_index).position_z[0]);
}

test "relink keeps a reserved drawable run when its last occupant leaves first" {
    var store: MovementBodyStore = .{};
    defer store.deinit(std.testing.allocator);
    const leaving = try EntityId.init(0, 1);
    const entering = try EntityId.init(1, 1);
    const leaving_index: usize = try store.append(std.testing.allocator, leaving, .{});
    const entering_index: usize = try store.append(std.testing.allocator, entering, .{});
    store.setScopeMetadata(leaving_index, .{ .chunk = .{ .x = 0, .y = 0 }, .level = 0 });
    store.setScopeMetadata(entering_index, .{ .chunk = .{ .x = 1, .y = 0 }, .level = 0 });
    try store.setHasPrimitiveVisual(std.testing.allocator, leaving_index, true);
    try store.setHasPrimitiveVisual(std.testing.allocator, entering_index, true);

    // Same order as deriveChunks: every destination is reserved, then the leaver relinks first.
    try store.reserveDrawableDestination(std.testing.allocator, 0, 1, 0);
    try store.reserveDrawableDestination(std.testing.allocator, 0, 0, 0);
    store.relinkReservedDrawable(leaving_index, 0, 1, 0);
    store.relinkReservedDrawable(entering_index, 0, 0, 0);

    const entered = store.drawableRunIndex(0, 0, 0).?;
    const departed = store.drawableRunIndex(0, 1, 0).?;
    try std.testing.expectEqual(@as(usize, 1), store.drawableRunLength(entered));
    try std.testing.expectEqual(@as(usize, 1), store.drawableRunLength(departed));
    try std.testing.expect(store.drawableRunSlice(entered).entity[0].eql(entering));
    try std.testing.expect(store.drawableRunSlice(departed).entity[0].eql(leaving));
    try std.testing.expectEqual(entered, store.rows.slice().items(.drawable_run)[entering_index]);
    try std.testing.expectEqual(departed, store.rows.slice().items(.drawable_run)[leaving_index]);
    try std.testing.expectEqual(@as(u32, 0), store.runs.items[entered].reserved_extra);
    try std.testing.expectEqual(@as(u32, 0), store.runs.items[departed].reserved_extra);
}
