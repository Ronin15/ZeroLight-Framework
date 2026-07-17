// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Destructible component storage: dense per-entity hit-point / affordance
//! rows for action-intent consumers (Slice 45). Mirrors faction_level.zig's
//! simple dense-row shape — no cold/hot split; all fields are author-set
//! facts updated via structural `set_destructible` or destroyed wholesale.

const std = @import("std");
const types = @import("types.zig");
const EntityId = types.EntityId;
const Destructible = types.Destructible;
const ConstDestructibleSlice = types.ConstDestructibleSlice;

const DestructibleRow = struct {
    entity: EntityId,
    hit_points: u8,
    destroy_on_interact: bool,
    destroy_on_attack: bool,
};

pub const DestructibleStore = struct {
    rows: std.MultiArrayList(DestructibleRow) = .{},

    pub fn len(self: *const DestructibleStore) usize {
        return self.rows.len;
    }

    pub fn append(self: *DestructibleStore, allocator: std.mem.Allocator, entity: EntityId, value: Destructible) !u32 {
        if (self.rows.len >= std.math.maxInt(u32)) return error.TooManyDestructibleRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.rows.len);
        self.rows.appendAssumeCapacity(.{
            .entity = entity,
            .hit_points = value.hit_points,
            .destroy_on_interact = value.destroy_on_interact,
            .destroy_on_attack = value.destroy_on_attack,
        });
        return index;
    }

    pub fn set(self: *DestructibleStore, index: usize, value: Destructible) void {
        const s = self.rows.slice();
        s.items(.hit_points)[index] = value.hit_points;
        s.items(.destroy_on_interact)[index] = value.destroy_on_interact;
        s.items(.destroy_on_attack)[index] = value.destroy_on_attack;
    }

    pub fn get(self: *const DestructibleStore, index: usize) Destructible {
        const s = self.rows.slice();
        return .{
            .hit_points = s.items(.hit_points)[index],
            .destroy_on_interact = s.items(.destroy_on_interact)[index],
            .destroy_on_attack = s.items(.destroy_on_attack)[index],
        };
    }

    pub fn removeAt(self: *DestructibleStore, index: usize) ?EntityId {
        const s = self.rows.slice();
        const last = self.rows.len - 1;
        const moved_entity = if (index != last) s.items(.entity)[last] else null;
        self.rows.swapRemove(index);
        return moved_entity;
    }

    pub fn sliceConst(self: *const DestructibleStore) ConstDestructibleSlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .hit_points = s.items(.hit_points),
            .destroy_on_interact = s.items(.destroy_on_interact),
            .destroy_on_attack = s.items(.destroy_on_attack),
        };
    }

    pub fn clearRetainingCapacity(self: *DestructibleStore) void {
        self.rows.clearRetainingCapacity();
    }

    pub fn deinit(self: *DestructibleStore, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *DestructibleStore, allocator: std.mem.Allocator) !void {
        try self.ensureCapacity(allocator, self.rows.len + 1);
    }

    pub fn ensureCapacity(self: *DestructibleStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.rows.ensureTotalCapacity(allocator, capacity);
    }
};

test "DestructibleStore append is allocation-free after ensureCapacity reserves" {
    var store: DestructibleStore = .{};
    defer store.deinit(std.testing.allocator);

    const reserved = 4;
    try store.ensureCapacity(std.testing.allocator, reserved);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const failing_alloc = failing.allocator();

    var i: u32 = 0;
    while (i < reserved) : (i += 1) {
        const entity = try EntityId.init(i, 1);
        _ = try store.append(failing_alloc, entity, .{ .hit_points = 1 });
    }
    try std.testing.expectEqual(@as(usize, reserved), store.len());
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "DestructibleStore append/set/get/removeAt round-trip" {
    var store: DestructibleStore = .{};
    defer store.deinit(std.testing.allocator);

    const first = try EntityId.init(1, 1);
    const second = try EntityId.init(2, 1);
    const third = try EntityId.init(3, 1);

    _ = try store.append(std.testing.allocator, first, .{ .hit_points = 1 });
    _ = try store.append(std.testing.allocator, second, .{ .hit_points = 3, .destroy_on_interact = false });
    _ = try store.append(std.testing.allocator, third, .{ .hit_points = 2, .destroy_on_attack = false });
    try std.testing.expectEqual(@as(usize, 3), store.len());
    try std.testing.expectEqual(@as(u8, 3), store.get(1).hit_points);
    try std.testing.expect(!store.get(1).destroy_on_interact);

    store.set(0, .{ .hit_points = 5, .destroy_on_interact = false, .destroy_on_attack = true });
    const updated = store.get(0);
    try std.testing.expectEqual(@as(u8, 5), updated.hit_points);
    try std.testing.expect(!updated.destroy_on_interact);
    try std.testing.expect(updated.destroy_on_attack);

    const moved = store.removeAt(1);
    try std.testing.expectEqual(@as(?EntityId, third), moved);
    try std.testing.expectEqual(@as(usize, 2), store.len());
    try std.testing.expectEqual(@as(u8, 2), store.get(1).hit_points);
}

test "DestructibleStore sliceConst exposes aligned columns" {
    var store: DestructibleStore = .{};
    defer store.deinit(std.testing.allocator);

    const first = try EntityId.init(1, 1);
    const second = try EntityId.init(2, 1);
    _ = try store.append(std.testing.allocator, first, .{});
    _ = try store.append(std.testing.allocator, second, .{ .hit_points = 4 });

    const const_slice = store.sliceConst();
    try std.testing.expectEqual(@as(usize, 2), const_slice.entities.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.hit_points.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.destroy_on_interact.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.destroy_on_attack.len);
    try std.testing.expectEqual(@as(u8, 4), const_slice.hit_points[1]);
}
