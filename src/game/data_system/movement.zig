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
    previous_z: i32,
    velocity_x: f32,
    velocity_y: f32,
    speed: f32,
    has_primitive_visual: bool = false,
    tier: SimulationTier,
    chunk_x: i32,
    chunk_y: i32,
    level: u16,
    stagger_phase: u8,
    always_active: bool,
};

pub const MovementBodyStore = struct {
    rows: std.MultiArrayList(MovementBodyRow) = .{},

    pub fn len(self: *const MovementBodyStore) usize {
        return self.rows.len;
    }

    pub fn append(self: *MovementBodyStore, allocator: std.mem.Allocator, entity: EntityId, body: MovementBody) !u32 {
        if (self.rows.len >= std.math.maxInt(u32)) return error.TooManyMovementBodyRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.rows.len);
        self.rows.appendAssumeCapacity(.{
            .entity = entity,
            .position_x = body.position.x,
            .position_y = body.position.y,
            .position_z = body.position_z,
            .previous_x = body.previous_position.x,
            .previous_y = body.previous_position.y,
            .previous_z = body.previous_z,
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
        s.items(.previous_z)[index] = body.previous_z;
        s.items(.velocity_x)[index] = body.velocity.x;
        s.items(.velocity_y)[index] = body.velocity.y;
        s.items(.speed)[index] = body.speed;
    }

    pub fn get(self: *const MovementBodyStore, index: usize) MovementBody {
        const s = self.rows.slice();
        return .{
            .position = .{ .x = s.items(.position_x)[index], .y = s.items(.position_y)[index] },
            .previous_position = .{ .x = s.items(.previous_x)[index], .y = s.items(.previous_y)[index] },
            .position_z = s.items(.position_z)[index],
            .previous_z = s.items(.previous_z)[index],
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
            .previous_z = &s.items(.previous_z)[index],
            .velocity_x = &s.items(.velocity_x)[index],
            .velocity_y = &s.items(.velocity_y)[index],
            .speed = &s.items(.speed)[index],
        };
    }

    pub fn tierAt(self: *const MovementBodyStore, index: usize) SimulationTier {
        return self.rows.slice().items(.tier)[index];
    }

    pub fn setHasPrimitiveVisual(self: *MovementBodyStore, index: usize, has_visual: bool) void {
        self.rows.slice().items(.has_primitive_visual)[index] = has_visual;
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
        s.items(.level)[index] = metadata.level;
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
        s.items(.previous_z)[index] = s.items(.position_z)[index];
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
            .previous_z = s.items(.previous_z),
            .velocity_x = s.items(.velocity_x),
            .velocity_y = s.items(.velocity_y),
            .speed = s.items(.speed),
            .has_primitive_visual = s.items(.has_primitive_visual),
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
            .previous_z = s.items(.previous_z),
            .velocity_x = s.items(.velocity_x),
            .velocity_y = s.items(.velocity_y),
            .speed = s.items(.speed),
            .has_primitive_visual = s.items(.has_primitive_visual),
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
    }

    pub fn deinit(self: *MovementBodyStore, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.* = .{};
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
    try std.testing.expectEqual(@as(usize, 0), simd.tailLen(@as(usize, 0)));
    try std.testing.expectEqual(@as(usize, 0), simd.vectorizedEnd(simd.lane_count - 1));
    try std.testing.expectEqual(@as(usize, simd.lane_count - 1), simd.tailLen(simd.lane_count - 1));
    try std.testing.expectEqual(@as(usize, simd.lane_count), simd.vectorizedEnd(simd.lane_count));
    try std.testing.expectEqual(@as(usize, 0), simd.tailLen(simd.lane_count));
    try std.testing.expectEqual(@as(usize, simd.lane_count * 2), simd.vectorizedEnd(simd.lane_count * 2 + 1));
    try std.testing.expectEqual(@as(usize, 1), simd.tailLen(simd.lane_count * 2 + 1));
}
