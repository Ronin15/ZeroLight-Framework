// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Collision component storage: axis-aligned bounds (offset/size) and the
//! response policy (mode/mobility/restitution), plus their payload validators.

const std = @import("std");
const types = @import("types.zig");
const EntityId = types.EntityId;
const CollisionBounds = types.CollisionBounds;
const ConstCollisionBoundsSlice = types.ConstCollisionBoundsSlice;
const CollisionResponseMode = types.CollisionResponseMode;
const CollisionResponseMobility = types.CollisionResponseMobility;
const CollisionResponse = types.CollisionResponse;
const ConstCollisionResponseSlice = types.ConstCollisionResponseSlice;
const hotStoreCapacity = types.hotStoreCapacity;

pub fn validateCollisionBounds(bounds: CollisionBounds) !void {
    if (!std.math.isFinite(bounds.offset.x) or !std.math.isFinite(bounds.offset.y)) return error.InvalidCollisionBounds;
    if (!std.math.isFinite(bounds.size.x) or !std.math.isFinite(bounds.size.y)) return error.InvalidCollisionBounds;
    if (bounds.size.x <= 0 or bounds.size.y <= 0) return error.InvalidCollisionBounds;
}

pub fn validateCollisionResponse(response: CollisionResponse) !void {
    // Restitution is a coefficient of restitution bounded to [0, 1]; a value > 1
    // injects energy on every bounce and destabilizes the collision solver, so
    // reject it on both ends like the sibling scalar validators.
    if (!std.math.isFinite(response.restitution) or response.restitution < 0 or response.restitution > 1) return error.InvalidCollisionResponse;
}

const CollisionBoundsRow = struct {
    entity: EntityId,
    offset_x: f32,
    offset_y: f32,
    size_x: f32,
    size_y: f32,
};

const CollisionResponseRow = struct {
    entity: EntityId,
    mode: CollisionResponseMode,
    mobility: CollisionResponseMobility,
    restitution: f32,
};

/// `dynamic_pos` slot for a bounds row that is a static navigation obstacle.
pub const no_dynamic: u32 = std.math.maxInt(u32);

pub const CollisionBoundsStore = struct {
    rows: std.MultiArrayList(CollisionBoundsRow) = .{},
    /// Bounds dense indexes that are not static navigation obstacles.
    dynamic_ids: std.ArrayList(u32) = .empty,
    /// Parallel to `rows`. Slot in `dynamic_ids`, or `no_dynamic`.
    dynamic_pos: std.ArrayList(u32) = .empty,

    pub fn len(self: *const CollisionBoundsStore) usize {
        return self.rows.len;
    }

    pub fn append(self: *CollisionBoundsStore, allocator: std.mem.Allocator, entity: EntityId, bounds: CollisionBounds) !u32 {
        // `u32` row indices: exhausting them fails at this growth seam as `OutOfMemory`.
        if (self.rows.len >= std.math.maxInt(u32)) return error.OutOfMemory;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.rows.len);
        self.rows.appendAssumeCapacity(.{
            .entity = entity,
            .offset_x = bounds.offset.x,
            .offset_y = bounds.offset.y,
            .size_x = bounds.size.x,
            .size_y = bounds.size.y,
        });
        // A new bounds row is dynamic until the caller drops it for a static obstacle.
        const slot: u32 = @intCast(self.dynamic_ids.items.len);
        self.dynamic_pos.appendAssumeCapacity(slot);
        self.dynamic_ids.appendAssumeCapacity(index);
        return index;
    }

    /// O(1). No-op when the row is already dynamic. Capacity comes from `ensureCapacity`.
    pub fn addDynamic(self: *CollisionBoundsStore, bounds_index: u32) void {
        if (self.dynamic_pos.items[bounds_index] != no_dynamic) return;
        std.debug.assert(self.dynamic_ids.capacity >= self.rows.len);
        std.debug.assert(self.dynamic_ids.items.len < self.dynamic_ids.capacity);
        const slot: u32 = @intCast(self.dynamic_ids.items.len);
        self.dynamic_ids.appendAssumeCapacity(bounds_index);
        self.dynamic_pos.items[bounds_index] = slot;
    }

    /// O(1). No-op when the row is already a static obstacle.
    pub fn removeDynamic(self: *CollisionBoundsStore, bounds_index: u32) void {
        const slot = self.dynamic_pos.items[bounds_index];
        if (slot == no_dynamic) return;
        const dyn_last = self.dynamic_ids.items.len - 1;
        const swapped_bounds = self.dynamic_ids.items[dyn_last];
        _ = self.dynamic_ids.swapRemove(slot);
        self.dynamic_pos.items[bounds_index] = no_dynamic;
        if (slot != dyn_last) self.dynamic_pos.items[swapped_bounds] = slot;
    }

    pub fn set(self: *CollisionBoundsStore, index: usize, bounds: CollisionBounds) void {
        const s = self.rows.slice();
        s.items(.offset_x)[index] = bounds.offset.x;
        s.items(.offset_y)[index] = bounds.offset.y;
        s.items(.size_x)[index] = bounds.size.x;
        s.items(.size_y)[index] = bounds.size.y;
    }

    pub fn get(self: *const CollisionBoundsStore, index: usize) CollisionBounds {
        const s = self.rows.slice();
        return .{
            .offset = .{ .x = s.items(.offset_x)[index], .y = s.items(.offset_y)[index] },
            .size = .{ .x = s.items(.size_x)[index], .y = s.items(.size_y)[index] },
        };
    }

    pub fn removeAt(self: *CollisionBoundsStore, index: usize) ?EntityId {
        const s = self.rows.slice();
        const last = self.rows.len - 1;
        const moved_entity = if (index != last) s.items(.entity)[last] else null;
        const removed_dyn = self.dynamic_pos.items[index];
        const tail_dyn = if (index != last) self.dynamic_pos.items[last] else no_dynamic;
        self.rows.swapRemove(index);
        self.swapRemoveDynamic(index, last, removed_dyn, tail_dyn);
        return moved_entity;
    }

    // Follows the bounds swapRemove. Rewrites the moved tail's stored bounds index.
    fn swapRemoveDynamic(self: *CollisionBoundsStore, index: usize, last: usize, removed_dyn: u32, tail_dyn: u32) void {
        _ = self.dynamic_pos.swapRemove(index);
        var relocated_tail = false;
        if (removed_dyn != no_dynamic) {
            const dyn_last = self.dynamic_ids.items.len - 1;
            const swapped_bounds = self.dynamic_ids.items[dyn_last];
            _ = self.dynamic_ids.swapRemove(removed_dyn);
            if (removed_dyn != dyn_last) {
                const pos_at: usize = if (swapped_bounds == last) index else swapped_bounds;
                self.dynamic_pos.items[pos_at] = removed_dyn;
            }
            relocated_tail = swapped_bounds == last;
        }
        if (index != last and tail_dyn != no_dynamic) {
            const slot: usize = if (relocated_tail) removed_dyn else tail_dyn;
            self.dynamic_ids.items[slot] = @intCast(index);
        }
    }

    pub fn sliceConst(self: *const CollisionBoundsStore) ConstCollisionBoundsSlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .offset_x = s.items(.offset_x),
            .offset_y = s.items(.offset_y),
            .size_x = s.items(.size_x),
            .size_y = s.items(.size_y),
        };
    }

    pub fn clearRetainingCapacity(self: *CollisionBoundsStore) void {
        self.rows.clearRetainingCapacity();
        self.dynamic_ids.clearRetainingCapacity();
        self.dynamic_pos.clearRetainingCapacity();
    }

    pub fn deinit(self: *CollisionBoundsStore, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.dynamic_ids.deinit(allocator);
        self.dynamic_pos.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *CollisionBoundsStore, allocator: std.mem.Allocator) !void {
        try self.ensureCapacity(allocator, self.rows.len + 1);
    }

    pub fn ensureCapacity(self: *CollisionBoundsStore, allocator: std.mem.Allocator, capacity: usize) !void {
        const rows_capacity = hotStoreCapacity(capacity);
        try self.rows.ensureTotalCapacity(allocator, rows_capacity);
        try self.dynamic_ids.ensureTotalCapacity(allocator, rows_capacity);
        try self.dynamic_pos.ensureTotalCapacity(allocator, rows_capacity);
    }
};

pub const CollisionResponseStore = struct {
    rows: std.MultiArrayList(CollisionResponseRow) = .{},

    pub fn len(self: *const CollisionResponseStore) usize {
        return self.rows.len;
    }

    pub fn append(self: *CollisionResponseStore, allocator: std.mem.Allocator, entity: EntityId, response: CollisionResponse) !u32 {
        // `u32` row indices: exhausting them fails at this growth seam as `OutOfMemory`.
        if (self.rows.len >= std.math.maxInt(u32)) return error.OutOfMemory;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.rows.len);
        self.rows.appendAssumeCapacity(.{
            .entity = entity,
            .mode = response.mode,
            .mobility = response.mobility,
            .restitution = response.restitution,
        });
        return index;
    }

    pub fn set(self: *CollisionResponseStore, index: usize, response: CollisionResponse) void {
        const s = self.rows.slice();
        s.items(.mode)[index] = response.mode;
        s.items(.mobility)[index] = response.mobility;
        s.items(.restitution)[index] = response.restitution;
    }

    pub fn get(self: *const CollisionResponseStore, index: usize) CollisionResponse {
        const s = self.rows.slice();
        return .{
            .mode = s.items(.mode)[index],
            .mobility = s.items(.mobility)[index],
            .restitution = s.items(.restitution)[index],
        };
    }

    pub fn removeAt(self: *CollisionResponseStore, index: usize) ?EntityId {
        const s = self.rows.slice();
        const last = self.rows.len - 1;
        const moved_entity = if (index != last) s.items(.entity)[last] else null;
        self.rows.swapRemove(index);
        return moved_entity;
    }

    pub fn sliceConst(self: *const CollisionResponseStore) ConstCollisionResponseSlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .modes = s.items(.mode),
            .mobilities = s.items(.mobility),
            .restitution = s.items(.restitution),
        };
    }

    pub fn clearRetainingCapacity(self: *CollisionResponseStore) void {
        self.rows.clearRetainingCapacity();
    }

    pub fn deinit(self: *CollisionResponseStore, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *CollisionResponseStore, allocator: std.mem.Allocator) !void {
        try self.ensureCapacity(allocator, self.rows.len + 1);
    }

    pub fn ensureCapacity(self: *CollisionResponseStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.rows.ensureTotalCapacity(allocator, hotStoreCapacity(capacity));
    }
};

test "CollisionBoundsStore append is allocation-free after ensureCapacity reserves" {
    var store: CollisionBoundsStore = .{};
    defer store.deinit(std.testing.allocator);

    const reserved = 4;
    try store.ensureCapacity(std.testing.allocator, reserved);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const failing_alloc = failing.allocator();

    var i: u32 = 0;
    while (i < reserved) : (i += 1) {
        const entity = try EntityId.init(i, 1);
        _ = try store.append(failing_alloc, entity, .{ .size = .{ .x = 8, .y = 8 } });
    }
    try std.testing.expectEqual(@as(usize, reserved), store.len());
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "dynamic index follows bounds swapRemove" {
    var store: CollisionBoundsStore = .{};
    defer store.deinit(std.testing.allocator);
    const bounds: CollisionBounds = .{ .size = .{ .x = 8, .y = 8 } };
    _ = try store.append(std.testing.allocator, try EntityId.init(1, 1), bounds);
    const second = try store.append(std.testing.allocator, try EntityId.init(2, 1), bounds);
    _ = try store.append(std.testing.allocator, try EntityId.init(3, 1), bounds);
    store.removeDynamic(second);
    _ = store.removeAt(0);
    try std.testing.expectEqual(@as(usize, 2), store.len());
    try std.testing.expectEqual(@as(usize, 1), store.dynamic_ids.items.len);
    try std.testing.expectEqual(@as(u32, 0), store.dynamic_ids.items[0]);
    try std.testing.expectEqual(@as(u32, 0), store.dynamic_pos.items[0]);
    try std.testing.expectEqual(no_dynamic, store.dynamic_pos.items[1]);
    try std.testing.expectEqual(@as(u32, 3), store.sliceConst().entities[0].index);
}

test "CollisionResponseStore append is allocation-free after ensureCapacity reserves" {
    var store: CollisionResponseStore = .{};
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

test "CollisionBoundsStore fails an append past its u32 row cap as OutOfMemory" {
    try data_test_support.expectRowCapOutOfMemory(CollisionBoundsStore, CollisionBounds{ .size = .{ .x = 1, .y = 1 } });
}

test "CollisionResponseStore fails an append past its u32 row cap as OutOfMemory" {
    try data_test_support.expectRowCapOutOfMemory(CollisionResponseStore, CollisionResponse{});
}
