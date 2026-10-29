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
const MovementBody = types.MovementBody;
const MovementBodyPtr = types.MovementBodyPtr;
const CollisionBounds = types.CollisionBounds;
const MovementBodySlice = types.MovementBodySlice;
const ConstMovementBodySlice = types.ConstMovementBodySlice;
const ScopeColumnsSlice = types.ScopeColumnsSlice;
const ConstScopeColumnsSlice = types.ConstScopeColumnsSlice;
const hotStoreCapacity = types.hotStoreCapacity;
const EntitySimulationMetadata = @import("../simulation_scope.zig").EntitySimulationMetadata;
const SimulationTier = @import("../simulation_scope.zig").SimulationTier;
const cognition_stagger_n = @import("../simulation_scope.zig").cognition_stagger_n;
const simd = @import("../../core/simd.zig");

pub fn validateMovementBody(body: MovementBody) !void {
    if (!std.math.isFinite(body.position.x) or !std.math.isFinite(body.position.y)) return error.InvalidMovementBody;
    if (!std.math.isFinite(body.previous_position.x) or !std.math.isFinite(body.previous_position.y)) return error.InvalidMovementBody;
    if (!std.math.isFinite(body.velocity.x) or !std.math.isFinite(body.velocity.y)) return error.InvalidMovementBody;
    if (!std.math.isFinite(body.speed) or body.speed < 0) return error.InvalidMovementBody;
}

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
    always_active: bool,
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
            .always_active = false,
        });
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
        self.rows.deinit(allocator);
        self.* = .{};
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

    pub fn drawableRunSlice(self: *MovementBodyStore, run_index: u32) struct {
        entity: []EntityId,
        movement_index: []u32,
        previous_x: []f32,
        position_x: []f32,
        previous_y: []f32,
        position_y: []f32,
        position_z: []i32,
    } {
        const drawn = self.runs.items[run_index].rows.slice();
        return .{
            .entity = drawn.items(.entity),
            .movement_index = drawn.items(.movement_index),
            .previous_x = drawn.items(.previous_x),
            .position_x = drawn.items(.position_x),
            .previous_y = drawn.items(.previous_y),
            .position_y = drawn.items(.position_y),
            .position_z = drawn.items(.position_z),
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
        if (run.rows.len == 0) self.releaseRun(run_index);
    }

    pub fn placeDrawable(self: *MovementBodyStore, allocator: std.mem.Allocator, index: usize) !void {
        const movement = self.rows.slice();
        if (movement.items(.drawable_run)[index] != no_drawable) return;
        const level = movement.items(.level)[index];
        const chunk_x = movement.items(.chunk_x)[index];
        const chunk_y = movement.items(.chunk_y)[index];
        try self.reserveDrawableDestination(allocator, level, chunk_x, chunk_y);
        self.commitDrawableLink(index, level, chunk_x, chunk_y);
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
    /// Allocates nothing.
    pub fn relinkReservedDrawable(self: *MovementBodyStore, index: usize, level: u16, chunk_x: i32, chunk_y: i32) void {
        const key = drawableKey(level, chunk_x, chunk_y);
        const dest = self.run_of.get(key).?;
        const current = self.rows.slice().items(.drawable_run)[index];
        if (current == dest) {
            std.debug.assert(self.runs.items[dest].reserved_extra > 0);
            self.runs.items[dest].reserved_extra -= 1;
            return;
        }
        self.unlinkDrawable(index);
        self.commitDrawableLink(index, level, chunk_x, chunk_y);
    }

    /// Links `index` at (`level`, `chunk_x`, `chunk_y`). The destination run and its row slot are
    /// reserved before the unlink, so a failure leaves membership unchanged.
    pub fn retargetDrawable(self: *MovementBodyStore, allocator: std.mem.Allocator, index: usize, level: u16, chunk_x: i32, chunk_y: i32) !void {
        if (!self.rows.slice().items(.has_primitive_visual)[index]) return;
        try self.reserveDrawableDestination(allocator, level, chunk_x, chunk_y);
        self.relinkReservedDrawable(index, level, chunk_x, chunk_y);
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
        try self.rows.ensureTotalCapacity(allocator, hotStoreCapacity(capacity));
    }
};

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
