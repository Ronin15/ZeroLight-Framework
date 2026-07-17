// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! AI short-term memory component storage: last-known target position with a
//! staleness timer, a fixed-capacity recent-contact ring, and a spatial
//! familiarity scalar, plus the memory payload validator. Mirrors
//! perception.zig's PerceptionStore shape; unlike perception, every column is
//! hot per-step state, so set() is a full overwrite with no cold/hot split.

const std = @import("std");
const types = @import("types.zig");
const EntityId = types.EntityId;
const AiMemory = types.AiMemory;
const AiMemoryContact = types.AiMemoryContact;
const ai_memory_ring_capacity = types.ai_memory_ring_capacity;
const max_ai_memory_staleness = types.max_ai_memory_staleness;
const max_ai_memory_familiarity = types.max_ai_memory_familiarity;
const ConstAiMemorySlice = types.ConstAiMemorySlice;
const AiMemorySlice = types.AiMemorySlice;
const hotStoreCapacity = types.hotStoreCapacity;

pub fn validateAiMemory(memory: AiMemory) !void {
    if (!std.math.isFinite(memory.staleness) or memory.staleness < 0 or memory.staleness > max_ai_memory_staleness) return error.InvalidAiMemory;
    if (!std.math.isFinite(memory.familiarity) or memory.familiarity < 0 or memory.familiarity > max_ai_memory_familiarity) return error.InvalidAiMemory;
    if (memory.ring_next_slot >= ai_memory_ring_capacity) return error.InvalidAiMemory;
    for (memory.ring) |contact| {
        if (!std.math.isFinite(contact.x) or !std.math.isFinite(contact.y) or !std.math.isFinite(contact.age)) return error.InvalidAiMemory;
        if (contact.age < 0 or contact.age > max_ai_memory_staleness) return error.InvalidAiMemory;
    }
}

const RingColumns = struct {
    entity: [ai_memory_ring_capacity]EntityId,
    x: [ai_memory_ring_capacity]f32,
    y: [ai_memory_ring_capacity]f32,
    age: [ai_memory_ring_capacity]f32,
};

fn splitRing(ring: [ai_memory_ring_capacity]AiMemoryContact) RingColumns {
    var columns: RingColumns = undefined;
    for (ring, 0..) |contact, i| {
        columns.entity[i] = contact.entity;
        columns.x[i] = contact.x;
        columns.y[i] = contact.y;
        columns.age[i] = contact.age;
    }
    return columns;
}

fn joinRing(
    entity: [ai_memory_ring_capacity]EntityId,
    x: [ai_memory_ring_capacity]f32,
    y: [ai_memory_ring_capacity]f32,
    age: [ai_memory_ring_capacity]f32,
) [ai_memory_ring_capacity]AiMemoryContact {
    var ring: [ai_memory_ring_capacity]AiMemoryContact = undefined;
    for (0..ai_memory_ring_capacity) |i| {
        ring[i] = .{ .entity = entity[i], .x = x[i], .y = y[i], .age = age[i] };
    }
    return ring;
}

const AiMemoryRow = struct {
    entity: EntityId,
    last_known_target: EntityId,
    last_known_x: f32,
    last_known_y: f32,
    staleness: f32,
    familiarity: f32,
    ring_entity: [ai_memory_ring_capacity]EntityId,
    ring_x: [ai_memory_ring_capacity]f32,
    ring_y: [ai_memory_ring_capacity]f32,
    ring_age: [ai_memory_ring_capacity]f32,
    ring_next_slot: u8,
};

pub const AiMemoryStore = struct {
    rows: std.MultiArrayList(AiMemoryRow) = .{},

    pub fn len(self: *const AiMemoryStore) usize {
        return self.rows.len;
    }

    pub fn append(self: *AiMemoryStore, allocator: std.mem.Allocator, entity: EntityId, memory: AiMemory) !u32 {
        if (self.rows.len >= std.math.maxInt(u32)) return error.TooManyAiMemoryRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.rows.len);
        const ring = splitRing(memory.ring);
        self.rows.appendAssumeCapacity(.{
            .entity = entity,
            .last_known_target = memory.last_known_target,
            .last_known_x = memory.last_known_x,
            .last_known_y = memory.last_known_y,
            .staleness = memory.staleness,
            .familiarity = memory.familiarity,
            .ring_entity = ring.entity,
            .ring_x = ring.x,
            .ring_y = ring.y,
            .ring_age = ring.age,
            .ring_next_slot = memory.ring_next_slot,
        });
        return index;
    }

    /// Full overwrite: AiMemory carries no cold tunables distinct from its
    /// runtime state, so unlike PerceptionStore.set there is nothing to preserve.
    pub fn set(self: *AiMemoryStore, index: usize, memory: AiMemory) void {
        const s = self.rows.slice();
        const ring = splitRing(memory.ring);
        s.items(.last_known_target)[index] = memory.last_known_target;
        s.items(.last_known_x)[index] = memory.last_known_x;
        s.items(.last_known_y)[index] = memory.last_known_y;
        s.items(.staleness)[index] = memory.staleness;
        s.items(.familiarity)[index] = memory.familiarity;
        s.items(.ring_entity)[index] = ring.entity;
        s.items(.ring_x)[index] = ring.x;
        s.items(.ring_y)[index] = ring.y;
        s.items(.ring_age)[index] = ring.age;
        s.items(.ring_next_slot)[index] = memory.ring_next_slot;
    }

    pub fn get(self: *const AiMemoryStore, index: usize) AiMemory {
        const s = self.rows.slice();
        return .{
            .last_known_target = s.items(.last_known_target)[index],
            .last_known_x = s.items(.last_known_x)[index],
            .last_known_y = s.items(.last_known_y)[index],
            .staleness = s.items(.staleness)[index],
            .familiarity = s.items(.familiarity)[index],
            .ring = joinRing(
                s.items(.ring_entity)[index],
                s.items(.ring_x)[index],
                s.items(.ring_y)[index],
                s.items(.ring_age)[index],
            ),
            .ring_next_slot = s.items(.ring_next_slot)[index],
        };
    }

    pub fn removeAt(self: *AiMemoryStore, index: usize) ?EntityId {
        const s = self.rows.slice();
        const last = self.rows.len - 1;
        const moved_entity = if (index != last) s.items(.entity)[last] else null;
        self.rows.swapRemove(index);
        return moved_entity;
    }

    pub fn sliceConst(self: *const AiMemoryStore) ConstAiMemorySlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .last_known_target = s.items(.last_known_target),
            .last_known_x = s.items(.last_known_x),
            .last_known_y = s.items(.last_known_y),
            .staleness = s.items(.staleness),
            .familiarity = s.items(.familiarity),
            .ring_entity = s.items(.ring_entity),
            .ring_x = s.items(.ring_x),
            .ring_y = s.items(.ring_y),
            .ring_age = s.items(.ring_age),
            .ring_next_slot = s.items(.ring_next_slot),
        };
    }

    /// Mutable view for `AiMemorySystem`'s per-step refresh/decay writes.
    pub fn slice(self: *AiMemoryStore) AiMemorySlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .last_known_target = s.items(.last_known_target),
            .last_known_x = s.items(.last_known_x),
            .last_known_y = s.items(.last_known_y),
            .staleness = s.items(.staleness),
            .familiarity = s.items(.familiarity),
            .ring_entity = s.items(.ring_entity),
            .ring_x = s.items(.ring_x),
            .ring_y = s.items(.ring_y),
            .ring_age = s.items(.ring_age),
            .ring_next_slot = s.items(.ring_next_slot),
        };
    }

    pub fn clearRetainingCapacity(self: *AiMemoryStore) void {
        self.rows.clearRetainingCapacity();
    }

    pub fn deinit(self: *AiMemoryStore, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *AiMemoryStore, allocator: std.mem.Allocator) !void {
        try self.ensureCapacity(allocator, self.rows.len + 1);
    }

    pub fn ensureCapacity(self: *AiMemoryStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.rows.ensureTotalCapacity(allocator, hotStoreCapacity(capacity));
    }
};

test "AiMemoryStore append is allocation-free after ensureCapacity reserves" {
    var store: AiMemoryStore = .{};
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

test "validateAiMemory accepts defaults and rejects out-of-range or non-finite fields" {
    try validateAiMemory(.{});
    try validateAiMemory(.{ .staleness = max_ai_memory_staleness, .familiarity = max_ai_memory_familiarity });

    try std.testing.expectError(error.InvalidAiMemory, validateAiMemory(.{ .staleness = -1 }));
    try std.testing.expectError(error.InvalidAiMemory, validateAiMemory(.{ .staleness = std.math.inf(f32) }));
    try std.testing.expectError(error.InvalidAiMemory, validateAiMemory(.{ .staleness = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidAiMemory, validateAiMemory(.{ .staleness = max_ai_memory_staleness + 1 }));

    try std.testing.expectError(error.InvalidAiMemory, validateAiMemory(.{ .familiarity = -0.1 }));
    try std.testing.expectError(error.InvalidAiMemory, validateAiMemory(.{ .familiarity = std.math.inf(f32) }));
    try std.testing.expectError(error.InvalidAiMemory, validateAiMemory(.{ .familiarity = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidAiMemory, validateAiMemory(.{ .familiarity = max_ai_memory_familiarity + 0.1 }));

    try std.testing.expectError(error.InvalidAiMemory, validateAiMemory(.{ .ring_next_slot = ai_memory_ring_capacity }));

    var bad_age_ring: [ai_memory_ring_capacity]AiMemoryContact = [_]AiMemoryContact{.{}} ** ai_memory_ring_capacity;
    bad_age_ring[0].age = -1;
    try std.testing.expectError(error.InvalidAiMemory, validateAiMemory(.{ .ring = bad_age_ring }));

    var stale_ring: [ai_memory_ring_capacity]AiMemoryContact = [_]AiMemoryContact{.{}} ** ai_memory_ring_capacity;
    stale_ring[1].age = max_ai_memory_staleness + 1;
    try std.testing.expectError(error.InvalidAiMemory, validateAiMemory(.{ .ring = stale_ring }));

    var nan_ring: [ai_memory_ring_capacity]AiMemoryContact = [_]AiMemoryContact{.{}} ** ai_memory_ring_capacity;
    nan_ring[2].x = std.math.nan(f32);
    try std.testing.expectError(error.InvalidAiMemory, validateAiMemory(.{ .ring = nan_ring }));
}

test "AiMemoryStore append/set/get/removeAt round-trip" {
    var store = AiMemoryStore{};
    defer store.deinit(std.testing.allocator);

    const first = try EntityId.init(1, 1);
    const second = try EntityId.init(2, 1);
    const third = try EntityId.init(3, 1);
    const contact_entity = try EntityId.init(9, 1);

    _ = try store.append(std.testing.allocator, first, .{ .staleness = 10, .familiarity = 0.1 });
    _ = try store.append(std.testing.allocator, second, .{ .staleness = 20, .familiarity = 0.2 });
    _ = try store.append(std.testing.allocator, third, .{ .staleness = 30, .familiarity = 0.3 });
    try std.testing.expectEqual(@as(usize, 3), store.len());
    try std.testing.expectEqual(@as(f32, 20), store.get(1).staleness);

    var ring: [ai_memory_ring_capacity]AiMemoryContact = [_]AiMemoryContact{.{}} ** ai_memory_ring_capacity;
    ring[0] = .{ .entity = contact_entity, .x = 5, .y = 6, .age = 1.5 };
    store.set(0, .{
        .last_known_target = contact_entity,
        .last_known_x = 100,
        .last_known_y = 200,
        .staleness = 0,
        .familiarity = 0.9,
        .ring = ring,
        .ring_next_slot = 1,
    });
    const updated = store.get(0);
    try std.testing.expectEqual(contact_entity, updated.last_known_target);
    try std.testing.expectEqual(@as(f32, 100), updated.last_known_x);
    try std.testing.expectEqual(@as(f32, 200), updated.last_known_y);
    try std.testing.expectEqual(@as(f32, 0), updated.staleness);
    try std.testing.expectEqual(@as(f32, 0.9), updated.familiarity);
    try std.testing.expectEqual(@as(u8, 1), updated.ring_next_slot);
    try std.testing.expectEqual(contact_entity, updated.ring[0].entity);
    try std.testing.expectEqual(@as(f32, 5), updated.ring[0].x);
    try std.testing.expectEqual(@as(f32, 6), updated.ring[0].y);
    try std.testing.expectEqual(@as(f32, 1.5), updated.ring[0].age);

    const moved = store.removeAt(1);
    try std.testing.expectEqual(@as(?EntityId, third), moved);
    try std.testing.expectEqual(@as(usize, 2), store.len());
    try std.testing.expectEqual(@as(f32, 30), store.get(1).staleness);
}

test "AiMemoryStore sliceConst and mutable slice expose aligned columns" {
    var store = AiMemoryStore{};
    defer store.deinit(std.testing.allocator);

    const first = try EntityId.init(1, 1);
    const second = try EntityId.init(2, 1);
    _ = try store.append(std.testing.allocator, first, .{});
    _ = try store.append(std.testing.allocator, second, .{});

    const const_slice = store.sliceConst();
    try std.testing.expectEqual(@as(usize, 2), const_slice.entities.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.last_known_x.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.staleness.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.familiarity.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.ring_entity.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.ring_x.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.ring_y.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.ring_age.len);
    try std.testing.expectEqual(const_slice.entities.len, const_slice.ring_next_slot.len);

    const mutable_slice = store.slice();
    mutable_slice.staleness[1] = 42;
    mutable_slice.familiarity[1] = 0.7;
    mutable_slice.ring_next_slot[1] = 2;
    mutable_slice.ring_x[1][0] = 3.5;
    try std.testing.expectEqual(@as(f32, 42), store.get(1).staleness);
    try std.testing.expectEqual(@as(f32, 0.7), store.get(1).familiarity);
    try std.testing.expectEqual(@as(u8, 2), store.get(1).ring_next_slot);
    try std.testing.expectEqual(@as(f32, 3.5), store.get(1).ring[0].x);
}
