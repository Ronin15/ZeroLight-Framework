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
    if (!std.math.isFinite(response.restitution)) return error.InvalidCollisionResponse;
    if (response.restitution < 0) return error.InvalidCollisionResponse;
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

pub const CollisionBoundsStore = struct {
    rows: std.MultiArrayList(CollisionBoundsRow) = .{},

    pub fn len(self: *const CollisionBoundsStore) usize {
        return self.rows.len;
    }

    pub fn append(self: *CollisionBoundsStore, allocator: std.mem.Allocator, entity: EntityId, bounds: CollisionBounds) !u32 {
        if (self.rows.len >= std.math.maxInt(u32)) return error.TooManyCollisionBoundsRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.rows.len);
        self.rows.appendAssumeCapacity(.{
            .entity = entity,
            .offset_x = bounds.offset.x,
            .offset_y = bounds.offset.y,
            .size_x = bounds.size.x,
            .size_y = bounds.size.y,
        });
        return index;
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
        self.rows.swapRemove(index);
        return moved_entity;
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
    }

    pub fn deinit(self: *CollisionBoundsStore, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *CollisionBoundsStore, allocator: std.mem.Allocator) !void {
        try self.ensureCapacity(allocator, self.rows.len + 1);
    }

    pub fn ensureCapacity(self: *CollisionBoundsStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.rows.ensureTotalCapacity(allocator, hotStoreCapacity(capacity));
    }
};

pub const CollisionResponseStore = struct {
    rows: std.MultiArrayList(CollisionResponseRow) = .{},

    pub fn len(self: *const CollisionResponseStore) usize {
        return self.rows.len;
    }

    pub fn append(self: *CollisionResponseStore, allocator: std.mem.Allocator, entity: EntityId, response: CollisionResponse) !u32 {
        if (self.rows.len >= std.math.maxInt(u32)) return error.TooManyCollisionResponseRows;
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
