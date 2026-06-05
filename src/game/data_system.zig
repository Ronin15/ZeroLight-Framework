// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-owned persistent gameplay data.
//! Hot system data is stored as scalar SoA columns so processors can load lanes
//! directly with core/simd.zig and split contiguous ranges through ThreadSystem.

const std = @import("std");
const assets_mod = @import("../assets/assets.zig");
const config = @import("../config.zig");
const math = @import("../core/math.zig");
const simd = @import("../core/simd.zig");

pub const hot_soa_column_alignment: usize = 64;
pub const movement_range_alignment_items: usize = hot_soa_column_alignment / @sizeOf(f32);

pub const HotF32Slice = []align(hot_soa_column_alignment) f32;
pub const ConstHotF32Slice = []align(hot_soa_column_alignment) const f32;

const HotF32List = std.ArrayListAligned(f32, .fromByteUnits(hot_soa_column_alignment));

pub const EntityId = struct {
    index: u32,
    generation: u32,

    pub const invalid = EntityId{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn init(index: u32, generation: u32) !EntityId {
        if (index == std.math.maxInt(u32)) return error.InvalidEntityIndex;
        if (generation == 0) return error.InvalidGeneration;
        return .{ .index = index, .generation = generation };
    }

    pub fn isValid(self: EntityId) bool {
        return self.index != std.math.maxInt(u32) and self.generation != 0;
    }

    pub fn matches(self: EntityId, index: u32, generation: u32) bool {
        return self.isValid() and self.index == index and self.generation == generation;
    }
};

pub const Component = enum(u5) {
    movement_body,
    facing,
    primitive_visual,
    asset_reference,
};

pub const ComponentMask = u32;

pub const component_masks = struct {
    pub const movement_body = componentMask(.movement_body);
    pub const facing = componentMask(.facing);
    pub const primitive_visual = componentMask(.primitive_visual);
    pub const asset_reference = componentMask(.asset_reference);
    pub const render_primitive = movement_body | facing | primitive_visual;
};

pub fn componentMask(component: Component) ComponentMask {
    return @as(ComponentMask, 1) << @intFromEnum(component);
}

pub const Facing = enum {
    up,
    down,
    left,
    right,
};

pub const MovementBody = struct {
    position: math.Vec2 = .{},
    previous_position: math.Vec2 = .{},
    velocity: math.Vec2 = .{},
    speed: f32 = 0,
};

pub const MovementBodyPtr = struct {
    position_x: *f32,
    position_y: *f32,
    previous_x: *f32,
    previous_y: *f32,
    velocity_x: *f32,
    velocity_y: *f32,
    speed: *f32,
};

pub const MovementBodySlice = struct {
    entities: []const EntityId,
    position_x: HotF32Slice,
    position_y: HotF32Slice,
    previous_x: HotF32Slice,
    previous_y: HotF32Slice,
    velocity_x: HotF32Slice,
    velocity_y: HotF32Slice,
    speed: HotF32Slice,
};

pub const ConstMovementBodySlice = struct {
    entities: []const EntityId,
    position_x: ConstHotF32Slice,
    position_y: ConstHotF32Slice,
    previous_x: ConstHotF32Slice,
    previous_y: ConstHotF32Slice,
    velocity_x: ConstHotF32Slice,
    velocity_y: ConstHotF32Slice,
    speed: ConstHotF32Slice,
};

pub const FacingData = struct {
    direction: Facing = .down,
};

pub const FacingSlice = struct {
    entities: []const EntityId,
    directions: []Facing,
};

pub const ConstFacingSlice = struct {
    entities: []const EntityId,
    directions: []const Facing,
};

pub const PrimitiveVisual = struct {
    size: math.Vec2,
    color: config.Color,
    layer: i32 = 0,
    marker_color: config.Color,
    marker_layer: i32 = 1,
    marker_length: f32 = 0,
    marker_depth: f32 = 0,
    marker_margin: f32 = 0,
};

pub const ConstPrimitiveVisualSlice = struct {
    entities: []const EntityId,
    size_x: []const f32,
    size_y: []const f32,
    color_r: []const f32,
    color_g: []const f32,
    color_b: []const f32,
    color_a: []const f32,
    layers: []const i32,
    marker_color_r: []const f32,
    marker_color_g: []const f32,
    marker_color_b: []const f32,
    marker_color_a: []const f32,
    marker_layers: []const i32,
    marker_lengths: []const f32,
    marker_depths: []const f32,
    marker_margins: []const f32,
};

pub const AssetReference = struct {
    relative_path: []const u8,
};

pub const ConstAssetReferenceSlice = struct {
    entities: []const EntityId,
    relative_paths: []const []const u8,
};

pub const DataSystem = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayList(EntitySlot) = .empty,
    first_free_slot: ?u32 = null,
    movement_bodies: MovementBodyStore = .{},
    facings: FacingStore = .{},
    primitive_visuals: PrimitiveVisualStore = .{},
    asset_refs: AssetReferenceStore = .{},

    pub fn init(allocator: std.mem.Allocator) DataSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DataSystem) void {
        self.asset_refs.deinit(self.allocator);
        self.primitive_visuals.deinit(self.allocator);
        self.facings.deinit(self.allocator);
        self.movement_bodies.deinit(self.allocator);
        self.slots.deinit(self.allocator);
        self.* = init(self.allocator);
    }

    pub fn createEntity(self: *DataSystem) !EntityId {
        if (self.first_free_slot) |index| {
            const slot = &self.slots.items[@intCast(index)];
            self.first_free_slot = slot.next_free;
            slot.alive = true;
            slot.next_free = null;
            return EntityId.init(index, slot.generation) catch unreachable;
        }

        if (self.slots.items.len >= std.math.maxInt(u32)) return error.TooManyEntities;
        const index: u32 = @intCast(self.slots.items.len);
        try self.slots.append(self.allocator, .{ .generation = 1, .alive = true });
        return EntityId.init(index, 1) catch unreachable;
    }

    pub fn destroyEntity(self: *DataSystem, id: EntityId) bool {
        const slot = self.resolveSlot(id) orelse return false;
        const index = id.index;

        if (slot.movement_body_index) |dense_index| self.removeMovementBodyAt(@intCast(dense_index));
        if (slot.facing_index) |dense_index| self.removeFacingAt(@intCast(dense_index));
        if (slot.primitive_visual_index) |dense_index| self.removePrimitiveVisualAt(@intCast(dense_index));
        if (slot.asset_ref_index) |dense_index| self.removeAssetReferenceAt(@intCast(dense_index));

        const retired_slot = &self.slots.items[@intCast(index)];
        retired_slot.generation = nextGeneration(retired_slot.generation);
        retired_slot.alive = false;
        retired_slot.next_free = self.first_free_slot;
        retired_slot.component_mask = 0;
        retired_slot.movement_body_index = null;
        retired_slot.facing_index = null;
        retired_slot.primitive_visual_index = null;
        retired_slot.asset_ref_index = null;
        self.first_free_slot = index;
        return true;
    }

    pub fn isAlive(self: *const DataSystem, id: EntityId) bool {
        return self.resolveSlotConst(id) != null;
    }

    pub fn componentMaskFor(self: *const DataSystem, id: EntityId) ComponentMask {
        const slot = self.resolveSlotConst(id) orelse return 0;
        return slot.component_mask;
    }

    pub fn hasComponents(self: *const DataSystem, id: EntityId, mask: ComponentMask) bool {
        const slot = self.resolveSlotConst(id) orelse return false;
        return slot.hasComponents(mask);
    }

    pub fn clearRetainingCapacity(self: *DataSystem) void {
        self.asset_refs.clearRetainingCapacity(self.allocator);
        self.primitive_visuals.clearRetainingCapacity();
        self.facings.clearRetainingCapacity();
        self.movement_bodies.clearRetainingCapacity();

        self.first_free_slot = null;
        for (self.slots.items, 0..) |*slot, index| {
            slot.generation = nextGeneration(slot.generation);
            slot.alive = false;
            slot.next_free = self.first_free_slot;
            slot.component_mask = 0;
            slot.movement_body_index = null;
            slot.facing_index = null;
            slot.primitive_visual_index = null;
            slot.asset_ref_index = null;
            self.first_free_slot = @intCast(index);
        }
    }

    pub fn reset(self: *DataSystem) void {
        self.clearRetainingCapacity();
    }

    pub fn setMovementBody(self: *DataSystem, id: EntityId, body: MovementBody) !void {
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        if (slot.movement_body_index) |index| {
            self.movement_bodies.set(@intCast(index), body);
            return;
        }

        const dense_index = try self.movement_bodies.append(self.allocator, id, body);
        slot.movement_body_index = dense_index;
        slot.addComponent(.movement_body);
    }

    pub fn movementBodyPtr(self: *DataSystem, id: EntityId) ?MovementBodyPtr {
        const slot = self.resolveSlot(id) orelse return null;
        const dense_index = slot.movement_body_index orelse return null;
        return self.movement_bodies.ptrAt(@intCast(dense_index));
    }

    pub fn movementBodyConst(self: *const DataSystem, id: EntityId) ?MovementBody {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.movement_body_index orelse return null;
        return self.movement_bodies.get(@intCast(dense_index));
    }

    pub fn movementBodySlice(self: *DataSystem) MovementBodySlice {
        return self.movement_bodies.slice();
    }

    pub fn movementBodySliceConst(self: *const DataSystem) ConstMovementBodySlice {
        return self.movement_bodies.sliceConst();
    }

    pub fn setFacing(self: *DataSystem, id: EntityId, facing: FacingData) !void {
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        if (slot.facing_index) |index| {
            self.facings.directions.items[@intCast(index)] = facing.direction;
            return;
        }

        const dense_index = try self.facings.append(self.allocator, id, facing);
        slot.facing_index = dense_index;
        slot.addComponent(.facing);
    }

    pub fn facingPtr(self: *DataSystem, id: EntityId) ?*Facing {
        const slot = self.resolveSlot(id) orelse return null;
        const dense_index = slot.facing_index orelse return null;
        return &self.facings.directions.items[@intCast(dense_index)];
    }

    pub fn facingConst(self: *const DataSystem, id: EntityId) ?FacingData {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.facing_index orelse return null;
        return .{ .direction = self.facings.directions.items[@intCast(dense_index)] };
    }

    pub fn facingSlice(self: *DataSystem) FacingSlice {
        return self.facings.slice();
    }

    pub fn facingSliceConst(self: *const DataSystem) ConstFacingSlice {
        return self.facings.sliceConst();
    }

    pub fn setPrimitiveVisual(self: *DataSystem, id: EntityId, visual: PrimitiveVisual) !void {
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        if (slot.primitive_visual_index) |index| {
            self.primitive_visuals.set(@intCast(index), visual);
            return;
        }

        const dense_index = try self.primitive_visuals.append(self.allocator, id, visual);
        slot.primitive_visual_index = dense_index;
        slot.addComponent(.primitive_visual);
    }

    pub fn primitiveVisualConst(self: *const DataSystem, id: EntityId) ?PrimitiveVisual {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.primitive_visual_index orelse return null;
        return self.primitive_visuals.get(@intCast(dense_index));
    }

    pub fn primitiveVisualSliceConst(self: *const DataSystem) ConstPrimitiveVisualSlice {
        return self.primitive_visuals.sliceConst();
    }

    pub fn setAssetReference(self: *DataSystem, id: EntityId, asset_ref: AssetReference) !void {
        try assets_mod.validateRelativePath(asset_ref.relative_path);
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;

        const owned_path = try self.allocator.dupe(u8, asset_ref.relative_path);
        errdefer self.allocator.free(owned_path);

        if (slot.asset_ref_index) |index| {
            const dense_index: usize = @intCast(index);
            self.allocator.free(self.asset_refs.relative_paths.items[dense_index]);
            self.asset_refs.relative_paths.items[dense_index] = owned_path;
            return;
        }

        const dense_index = try self.asset_refs.append(self.allocator, id, owned_path);
        slot.asset_ref_index = dense_index;
        slot.addComponent(.asset_reference);
    }

    pub fn assetReferenceConst(self: *const DataSystem, id: EntityId) ?AssetReference {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.asset_ref_index orelse return null;
        return .{ .relative_path = self.asset_refs.relative_paths.items[@intCast(dense_index)] };
    }

    pub fn assetReferenceSliceConst(self: *const DataSystem) ConstAssetReferenceSlice {
        return self.asset_refs.sliceConst();
    }

    fn resolveSlot(self: *DataSystem, id: EntityId) ?*EntitySlot {
        if (!id.isValid()) return null;
        const index: usize = @intCast(id.index);
        if (index >= self.slots.items.len) return null;

        const slot = &self.slots.items[index];
        if (!slot.alive) return null;
        if (!id.matches(id.index, slot.generation)) return null;
        return slot;
    }

    fn resolveSlotConst(self: *const DataSystem, id: EntityId) ?*const EntitySlot {
        if (!id.isValid()) return null;
        const index: usize = @intCast(id.index);
        if (index >= self.slots.items.len) return null;

        const slot = &self.slots.items[index];
        if (!slot.alive) return null;
        if (!id.matches(id.index, slot.generation)) return null;
        return slot;
    }

    fn removeMovementBodyAt(self: *DataSystem, index: usize) void {
        const moved = self.movement_bodies.removeAt(index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].movement_body_index = @intCast(index);
    }

    fn removeFacingAt(self: *DataSystem, index: usize) void {
        const moved = self.facings.removeAt(index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].facing_index = @intCast(index);
    }

    fn removePrimitiveVisualAt(self: *DataSystem, index: usize) void {
        const moved = self.primitive_visuals.removeAt(index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].primitive_visual_index = @intCast(index);
    }

    fn removeAssetReferenceAt(self: *DataSystem, index: usize) void {
        const moved = self.asset_refs.removeAt(self.allocator, index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].asset_ref_index = @intCast(index);
    }
};

const EntitySlot = struct {
    generation: u32 = 1,
    alive: bool = false,
    next_free: ?u32 = null,
    component_mask: ComponentMask = 0,
    movement_body_index: ?u32 = null,
    facing_index: ?u32 = null,
    primitive_visual_index: ?u32 = null,
    asset_ref_index: ?u32 = null,

    fn addComponent(self: *EntitySlot, component: Component) void {
        self.component_mask |= componentMask(component);
    }

    fn hasComponents(self: EntitySlot, mask: ComponentMask) bool {
        return (self.component_mask & mask) == mask;
    }
};

const MovementBodyStore = struct {
    entities: std.ArrayList(EntityId) = .empty,
    position_x: HotF32List = .empty,
    position_y: HotF32List = .empty,
    previous_x: HotF32List = .empty,
    previous_y: HotF32List = .empty,
    velocity_x: HotF32List = .empty,
    velocity_y: HotF32List = .empty,
    speed: HotF32List = .empty,

    fn append(self: *MovementBodyStore, allocator: std.mem.Allocator, entity: EntityId, body: MovementBody) !u32 {
        if (self.entities.items.len >= std.math.maxInt(u32)) return error.TooManyMovementBodyRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.entities.items.len);
        self.entities.appendAssumeCapacity(entity);
        self.position_x.appendAssumeCapacity(body.position.x);
        self.position_y.appendAssumeCapacity(body.position.y);
        self.previous_x.appendAssumeCapacity(body.previous_position.x);
        self.previous_y.appendAssumeCapacity(body.previous_position.y);
        self.velocity_x.appendAssumeCapacity(body.velocity.x);
        self.velocity_y.appendAssumeCapacity(body.velocity.y);
        self.speed.appendAssumeCapacity(body.speed);
        return index;
    }

    fn set(self: *MovementBodyStore, index: usize, body: MovementBody) void {
        self.position_x.items[index] = body.position.x;
        self.position_y.items[index] = body.position.y;
        self.previous_x.items[index] = body.previous_position.x;
        self.previous_y.items[index] = body.previous_position.y;
        self.velocity_x.items[index] = body.velocity.x;
        self.velocity_y.items[index] = body.velocity.y;
        self.speed.items[index] = body.speed;
    }

    fn get(self: *const MovementBodyStore, index: usize) MovementBody {
        return .{
            .position = .{ .x = self.position_x.items[index], .y = self.position_y.items[index] },
            .previous_position = .{ .x = self.previous_x.items[index], .y = self.previous_y.items[index] },
            .velocity = .{ .x = self.velocity_x.items[index], .y = self.velocity_y.items[index] },
            .speed = self.speed.items[index],
        };
    }

    fn ptrAt(self: *MovementBodyStore, index: usize) MovementBodyPtr {
        return .{
            .position_x = &self.position_x.items[index],
            .position_y = &self.position_y.items[index],
            .previous_x = &self.previous_x.items[index],
            .previous_y = &self.previous_y.items[index],
            .velocity_x = &self.velocity_x.items[index],
            .velocity_y = &self.velocity_y.items[index],
            .speed = &self.speed.items[index],
        };
    }

    fn removeAt(self: *MovementBodyStore, index: usize) ?EntityId {
        const last = self.entities.items.len - 1;
        const moved_entity = if (index != last) self.entities.items[last] else null;
        self.entities.items[index] = self.entities.items[last];
        self.position_x.items[index] = self.position_x.items[last];
        self.position_y.items[index] = self.position_y.items[last];
        self.previous_x.items[index] = self.previous_x.items[last];
        self.previous_y.items[index] = self.previous_y.items[last];
        self.velocity_x.items[index] = self.velocity_x.items[last];
        self.velocity_y.items[index] = self.velocity_y.items[last];
        self.speed.items[index] = self.speed.items[last];
        _ = self.entities.pop();
        _ = self.position_x.pop();
        _ = self.position_y.pop();
        _ = self.previous_x.pop();
        _ = self.previous_y.pop();
        _ = self.velocity_x.pop();
        _ = self.velocity_y.pop();
        _ = self.speed.pop();
        return moved_entity;
    }

    fn slice(self: *MovementBodyStore) MovementBodySlice {
        return .{
            .entities = self.entities.items,
            .position_x = self.position_x.items,
            .position_y = self.position_y.items,
            .previous_x = self.previous_x.items,
            .previous_y = self.previous_y.items,
            .velocity_x = self.velocity_x.items,
            .velocity_y = self.velocity_y.items,
            .speed = self.speed.items,
        };
    }

    fn sliceConst(self: *const MovementBodyStore) ConstMovementBodySlice {
        return .{
            .entities = self.entities.items,
            .position_x = self.position_x.items,
            .position_y = self.position_y.items,
            .previous_x = self.previous_x.items,
            .previous_y = self.previous_y.items,
            .velocity_x = self.velocity_x.items,
            .velocity_y = self.velocity_y.items,
            .speed = self.speed.items,
        };
    }

    fn clearRetainingCapacity(self: *MovementBodyStore) void {
        self.entities.clearRetainingCapacity();
        self.position_x.clearRetainingCapacity();
        self.position_y.clearRetainingCapacity();
        self.previous_x.clearRetainingCapacity();
        self.previous_y.clearRetainingCapacity();
        self.velocity_x.clearRetainingCapacity();
        self.velocity_y.clearRetainingCapacity();
        self.speed.clearRetainingCapacity();
    }

    fn deinit(self: *MovementBodyStore, allocator: std.mem.Allocator) void {
        self.entities.deinit(allocator);
        self.position_x.deinit(allocator);
        self.position_y.deinit(allocator);
        self.previous_x.deinit(allocator);
        self.previous_y.deinit(allocator);
        self.velocity_x.deinit(allocator);
        self.velocity_y.deinit(allocator);
        self.speed.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *MovementBodyStore, allocator: std.mem.Allocator) !void {
        const capacity = self.entities.items.len + 1;
        try self.entities.ensureTotalCapacity(allocator, capacity);
        try self.position_x.ensureTotalCapacity(allocator, capacity);
        try self.position_y.ensureTotalCapacity(allocator, capacity);
        try self.previous_x.ensureTotalCapacity(allocator, capacity);
        try self.previous_y.ensureTotalCapacity(allocator, capacity);
        try self.velocity_x.ensureTotalCapacity(allocator, capacity);
        try self.velocity_y.ensureTotalCapacity(allocator, capacity);
        try self.speed.ensureTotalCapacity(allocator, capacity);
    }
};

const FacingStore = struct {
    entities: std.ArrayList(EntityId) = .empty,
    directions: std.ArrayList(Facing) = .empty,

    fn append(self: *FacingStore, allocator: std.mem.Allocator, entity: EntityId, facing: FacingData) !u32 {
        if (self.entities.items.len >= std.math.maxInt(u32)) return error.TooManyFacingRows;
        const capacity = self.entities.items.len + 1;
        try self.entities.ensureTotalCapacity(allocator, capacity);
        try self.directions.ensureTotalCapacity(allocator, capacity);
        const index: u32 = @intCast(self.entities.items.len);
        self.entities.appendAssumeCapacity(entity);
        self.directions.appendAssumeCapacity(facing.direction);
        return index;
    }

    fn removeAt(self: *FacingStore, index: usize) ?EntityId {
        const last = self.entities.items.len - 1;
        const moved_entity = if (index != last) self.entities.items[last] else null;
        self.entities.items[index] = self.entities.items[last];
        self.directions.items[index] = self.directions.items[last];
        _ = self.entities.pop();
        _ = self.directions.pop();
        return moved_entity;
    }

    fn slice(self: *FacingStore) FacingSlice {
        return .{ .entities = self.entities.items, .directions = self.directions.items };
    }

    fn sliceConst(self: *const FacingStore) ConstFacingSlice {
        return .{ .entities = self.entities.items, .directions = self.directions.items };
    }

    fn clearRetainingCapacity(self: *FacingStore) void {
        self.entities.clearRetainingCapacity();
        self.directions.clearRetainingCapacity();
    }

    fn deinit(self: *FacingStore, allocator: std.mem.Allocator) void {
        self.entities.deinit(allocator);
        self.directions.deinit(allocator);
        self.* = .{};
    }
};

const PrimitiveVisualStore = struct {
    entities: std.ArrayList(EntityId) = .empty,
    size_x: std.ArrayList(f32) = .empty,
    size_y: std.ArrayList(f32) = .empty,
    color_r: std.ArrayList(f32) = .empty,
    color_g: std.ArrayList(f32) = .empty,
    color_b: std.ArrayList(f32) = .empty,
    color_a: std.ArrayList(f32) = .empty,
    layers: std.ArrayList(i32) = .empty,
    marker_color_r: std.ArrayList(f32) = .empty,
    marker_color_g: std.ArrayList(f32) = .empty,
    marker_color_b: std.ArrayList(f32) = .empty,
    marker_color_a: std.ArrayList(f32) = .empty,
    marker_layers: std.ArrayList(i32) = .empty,
    marker_lengths: std.ArrayList(f32) = .empty,
    marker_depths: std.ArrayList(f32) = .empty,
    marker_margins: std.ArrayList(f32) = .empty,

    fn append(self: *PrimitiveVisualStore, allocator: std.mem.Allocator, entity: EntityId, visual: PrimitiveVisual) !u32 {
        if (self.entities.items.len >= std.math.maxInt(u32)) return error.TooManyPrimitiveVisualRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.entities.items.len);
        self.entities.appendAssumeCapacity(entity);
        self.appendColumnsAssumeCapacity(visual);
        return index;
    }

    fn set(self: *PrimitiveVisualStore, index: usize, visual: PrimitiveVisual) void {
        self.size_x.items[index] = visual.size.x;
        self.size_y.items[index] = visual.size.y;
        self.color_r.items[index] = visual.color.r;
        self.color_g.items[index] = visual.color.g;
        self.color_b.items[index] = visual.color.b;
        self.color_a.items[index] = visual.color.a;
        self.layers.items[index] = visual.layer;
        self.marker_color_r.items[index] = visual.marker_color.r;
        self.marker_color_g.items[index] = visual.marker_color.g;
        self.marker_color_b.items[index] = visual.marker_color.b;
        self.marker_color_a.items[index] = visual.marker_color.a;
        self.marker_layers.items[index] = visual.marker_layer;
        self.marker_lengths.items[index] = visual.marker_length;
        self.marker_depths.items[index] = visual.marker_depth;
        self.marker_margins.items[index] = visual.marker_margin;
    }

    fn get(self: *const PrimitiveVisualStore, index: usize) PrimitiveVisual {
        return .{
            .size = .{ .x = self.size_x.items[index], .y = self.size_y.items[index] },
            .color = .{
                .r = self.color_r.items[index],
                .g = self.color_g.items[index],
                .b = self.color_b.items[index],
                .a = self.color_a.items[index],
            },
            .layer = self.layers.items[index],
            .marker_color = .{
                .r = self.marker_color_r.items[index],
                .g = self.marker_color_g.items[index],
                .b = self.marker_color_b.items[index],
                .a = self.marker_color_a.items[index],
            },
            .marker_layer = self.marker_layers.items[index],
            .marker_length = self.marker_lengths.items[index],
            .marker_depth = self.marker_depths.items[index],
            .marker_margin = self.marker_margins.items[index],
        };
    }

    fn removeAt(self: *PrimitiveVisualStore, index: usize) ?EntityId {
        const last = self.entities.items.len - 1;
        const moved_entity = if (index != last) self.entities.items[last] else null;
        self.entities.items[index] = self.entities.items[last];
        self.size_x.items[index] = self.size_x.items[last];
        self.size_y.items[index] = self.size_y.items[last];
        self.color_r.items[index] = self.color_r.items[last];
        self.color_g.items[index] = self.color_g.items[last];
        self.color_b.items[index] = self.color_b.items[last];
        self.color_a.items[index] = self.color_a.items[last];
        self.layers.items[index] = self.layers.items[last];
        self.marker_color_r.items[index] = self.marker_color_r.items[last];
        self.marker_color_g.items[index] = self.marker_color_g.items[last];
        self.marker_color_b.items[index] = self.marker_color_b.items[last];
        self.marker_color_a.items[index] = self.marker_color_a.items[last];
        self.marker_layers.items[index] = self.marker_layers.items[last];
        self.marker_lengths.items[index] = self.marker_lengths.items[last];
        self.marker_depths.items[index] = self.marker_depths.items[last];
        self.marker_margins.items[index] = self.marker_margins.items[last];
        self.popAll();
        return moved_entity;
    }

    fn sliceConst(self: *const PrimitiveVisualStore) ConstPrimitiveVisualSlice {
        return .{
            .entities = self.entities.items,
            .size_x = self.size_x.items,
            .size_y = self.size_y.items,
            .color_r = self.color_r.items,
            .color_g = self.color_g.items,
            .color_b = self.color_b.items,
            .color_a = self.color_a.items,
            .layers = self.layers.items,
            .marker_color_r = self.marker_color_r.items,
            .marker_color_g = self.marker_color_g.items,
            .marker_color_b = self.marker_color_b.items,
            .marker_color_a = self.marker_color_a.items,
            .marker_layers = self.marker_layers.items,
            .marker_lengths = self.marker_lengths.items,
            .marker_depths = self.marker_depths.items,
            .marker_margins = self.marker_margins.items,
        };
    }

    fn clearRetainingCapacity(self: *PrimitiveVisualStore) void {
        self.entities.clearRetainingCapacity();
        self.size_x.clearRetainingCapacity();
        self.size_y.clearRetainingCapacity();
        self.color_r.clearRetainingCapacity();
        self.color_g.clearRetainingCapacity();
        self.color_b.clearRetainingCapacity();
        self.color_a.clearRetainingCapacity();
        self.layers.clearRetainingCapacity();
        self.marker_color_r.clearRetainingCapacity();
        self.marker_color_g.clearRetainingCapacity();
        self.marker_color_b.clearRetainingCapacity();
        self.marker_color_a.clearRetainingCapacity();
        self.marker_layers.clearRetainingCapacity();
        self.marker_lengths.clearRetainingCapacity();
        self.marker_depths.clearRetainingCapacity();
        self.marker_margins.clearRetainingCapacity();
    }

    fn deinit(self: *PrimitiveVisualStore, allocator: std.mem.Allocator) void {
        self.entities.deinit(allocator);
        self.size_x.deinit(allocator);
        self.size_y.deinit(allocator);
        self.color_r.deinit(allocator);
        self.color_g.deinit(allocator);
        self.color_b.deinit(allocator);
        self.color_a.deinit(allocator);
        self.layers.deinit(allocator);
        self.marker_color_r.deinit(allocator);
        self.marker_color_g.deinit(allocator);
        self.marker_color_b.deinit(allocator);
        self.marker_color_a.deinit(allocator);
        self.marker_layers.deinit(allocator);
        self.marker_lengths.deinit(allocator);
        self.marker_depths.deinit(allocator);
        self.marker_margins.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *PrimitiveVisualStore, allocator: std.mem.Allocator) !void {
        const capacity = self.entities.items.len + 1;
        try self.entities.ensureTotalCapacity(allocator, capacity);
        try self.size_x.ensureTotalCapacity(allocator, capacity);
        try self.size_y.ensureTotalCapacity(allocator, capacity);
        try self.color_r.ensureTotalCapacity(allocator, capacity);
        try self.color_g.ensureTotalCapacity(allocator, capacity);
        try self.color_b.ensureTotalCapacity(allocator, capacity);
        try self.color_a.ensureTotalCapacity(allocator, capacity);
        try self.layers.ensureTotalCapacity(allocator, capacity);
        try self.marker_color_r.ensureTotalCapacity(allocator, capacity);
        try self.marker_color_g.ensureTotalCapacity(allocator, capacity);
        try self.marker_color_b.ensureTotalCapacity(allocator, capacity);
        try self.marker_color_a.ensureTotalCapacity(allocator, capacity);
        try self.marker_layers.ensureTotalCapacity(allocator, capacity);
        try self.marker_lengths.ensureTotalCapacity(allocator, capacity);
        try self.marker_depths.ensureTotalCapacity(allocator, capacity);
        try self.marker_margins.ensureTotalCapacity(allocator, capacity);
    }

    fn appendColumnsAssumeCapacity(self: *PrimitiveVisualStore, visual: PrimitiveVisual) void {
        self.size_x.appendAssumeCapacity(visual.size.x);
        self.size_y.appendAssumeCapacity(visual.size.y);
        self.color_r.appendAssumeCapacity(visual.color.r);
        self.color_g.appendAssumeCapacity(visual.color.g);
        self.color_b.appendAssumeCapacity(visual.color.b);
        self.color_a.appendAssumeCapacity(visual.color.a);
        self.layers.appendAssumeCapacity(visual.layer);
        self.marker_color_r.appendAssumeCapacity(visual.marker_color.r);
        self.marker_color_g.appendAssumeCapacity(visual.marker_color.g);
        self.marker_color_b.appendAssumeCapacity(visual.marker_color.b);
        self.marker_color_a.appendAssumeCapacity(visual.marker_color.a);
        self.marker_layers.appendAssumeCapacity(visual.marker_layer);
        self.marker_lengths.appendAssumeCapacity(visual.marker_length);
        self.marker_depths.appendAssumeCapacity(visual.marker_depth);
        self.marker_margins.appendAssumeCapacity(visual.marker_margin);
    }

    fn popAll(self: *PrimitiveVisualStore) void {
        _ = self.entities.pop();
        _ = self.size_x.pop();
        _ = self.size_y.pop();
        _ = self.color_r.pop();
        _ = self.color_g.pop();
        _ = self.color_b.pop();
        _ = self.color_a.pop();
        _ = self.layers.pop();
        _ = self.marker_color_r.pop();
        _ = self.marker_color_g.pop();
        _ = self.marker_color_b.pop();
        _ = self.marker_color_a.pop();
        _ = self.marker_layers.pop();
        _ = self.marker_lengths.pop();
        _ = self.marker_depths.pop();
        _ = self.marker_margins.pop();
    }
};

const AssetReferenceStore = struct {
    entities: std.ArrayList(EntityId) = .empty,
    relative_paths: std.ArrayList([]const u8) = .empty,

    fn append(self: *AssetReferenceStore, allocator: std.mem.Allocator, entity: EntityId, owned_path: []const u8) !u32 {
        if (self.entities.items.len >= std.math.maxInt(u32)) return error.TooManyAssetReferenceRows;
        const capacity = self.entities.items.len + 1;
        try self.entities.ensureTotalCapacity(allocator, capacity);
        try self.relative_paths.ensureTotalCapacity(allocator, capacity);
        const index: u32 = @intCast(self.entities.items.len);
        self.entities.appendAssumeCapacity(entity);
        self.relative_paths.appendAssumeCapacity(owned_path);
        return index;
    }

    fn removeAt(self: *AssetReferenceStore, allocator: std.mem.Allocator, index: usize) ?EntityId {
        allocator.free(self.relative_paths.items[index]);
        const last = self.entities.items.len - 1;
        const moved_entity = if (index != last) self.entities.items[last] else null;
        self.entities.items[index] = self.entities.items[last];
        self.relative_paths.items[index] = self.relative_paths.items[last];
        _ = self.entities.pop();
        _ = self.relative_paths.pop();
        return moved_entity;
    }

    fn sliceConst(self: *const AssetReferenceStore) ConstAssetReferenceSlice {
        return .{ .entities = self.entities.items, .relative_paths = self.relative_paths.items };
    }

    fn clearRetainingCapacity(self: *AssetReferenceStore, allocator: std.mem.Allocator) void {
        for (self.relative_paths.items) |path| allocator.free(path);
        self.entities.clearRetainingCapacity();
        self.relative_paths.clearRetainingCapacity();
    }

    fn deinit(self: *AssetReferenceStore, allocator: std.mem.Allocator) void {
        for (self.relative_paths.items) |path| allocator.free(path);
        self.entities.deinit(allocator);
        self.relative_paths.deinit(allocator);
        self.* = .{};
    }
};

fn nextGeneration(generation: u32) u32 {
    const next = generation +% 1;
    return if (next == 0) 1 else next;
}

fn expectMovementBodyColumnsAligned(slice: ConstMovementBodySlice) !void {
    try std.testing.expectEqual(slice.entities.len, slice.position_x.len);
    try std.testing.expectEqual(slice.entities.len, slice.position_y.len);
    try std.testing.expectEqual(slice.entities.len, slice.previous_x.len);
    try std.testing.expectEqual(slice.entities.len, slice.previous_y.len);
    try std.testing.expectEqual(slice.entities.len, slice.velocity_x.len);
    try std.testing.expectEqual(slice.entities.len, slice.velocity_y.len);
    try std.testing.expectEqual(slice.entities.len, slice.speed.len);
}

fn expectHotColumnPointersAligned(slice: ConstMovementBodySlice) !void {
    try expectPointerAligned(slice.position_x.ptr);
    try expectPointerAligned(slice.position_y.ptr);
    try expectPointerAligned(slice.previous_x.ptr);
    try expectPointerAligned(slice.previous_y.ptr);
    try expectPointerAligned(slice.velocity_x.ptr);
    try expectPointerAligned(slice.velocity_y.ptr);
    try expectPointerAligned(slice.speed.ptr);
}

fn expectPointerAligned(ptr: [*]align(hot_soa_column_alignment) const f32) !void {
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(ptr) % hot_soa_column_alignment);
}

fn expectPrimitiveVisualColumnsAligned(slice: ConstPrimitiveVisualSlice) !void {
    try std.testing.expectEqual(slice.entities.len, slice.size_x.len);
    try std.testing.expectEqual(slice.entities.len, slice.size_y.len);
    try std.testing.expectEqual(slice.entities.len, slice.color_r.len);
    try std.testing.expectEqual(slice.entities.len, slice.color_g.len);
    try std.testing.expectEqual(slice.entities.len, slice.color_b.len);
    try std.testing.expectEqual(slice.entities.len, slice.color_a.len);
    try std.testing.expectEqual(slice.entities.len, slice.layers.len);
    try std.testing.expectEqual(slice.entities.len, slice.marker_color_r.len);
    try std.testing.expectEqual(slice.entities.len, slice.marker_color_g.len);
    try std.testing.expectEqual(slice.entities.len, slice.marker_color_b.len);
    try std.testing.expectEqual(slice.entities.len, slice.marker_color_a.len);
    try std.testing.expectEqual(slice.entities.len, slice.marker_layers.len);
    try std.testing.expectEqual(slice.entities.len, slice.marker_lengths.len);
    try std.testing.expectEqual(slice.entities.len, slice.marker_depths.len);
    try std.testing.expectEqual(slice.entities.len, slice.marker_margins.len);
}

test "entity ids reject invalid values and match slots exactly" {
    try std.testing.expectError(error.InvalidEntityIndex, EntityId.init(std.math.maxInt(u32), 1));
    try std.testing.expectError(error.InvalidGeneration, EntityId.init(0, 0));

    const id = try EntityId.init(3, 7);
    try std.testing.expect(id.isValid());
    try std.testing.expect(id.matches(3, 7));
    try std.testing.expect(!id.matches(3, 8));
    try std.testing.expect(!EntityId.invalid.isValid());
}

test "entity generations reject stale ids after removal and reuse" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    try std.testing.expect(data.isAlive(first));
    try std.testing.expect(data.destroyEntity(first));
    try std.testing.expect(!data.isAlive(first));

    const reused = try data.createEntity();
    try std.testing.expectEqual(first.index, reused.index);
    try std.testing.expect(reused.generation != first.generation);
    try std.testing.expect(data.isAlive(reused));
    try std.testing.expect(!data.destroyEntity(first));
}

test "movement body store is row aligned and compact after removal" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    const second = try data.createEntity();
    const third = try data.createEntity();
    try data.setMovementBody(first, testBody(1));
    try data.setMovementBody(second, testBody(2));
    try data.setMovementBody(third, testBody(3));

    try std.testing.expect(data.destroyEntity(second));

    const slice = data.movementBodySliceConst();
    try expectMovementBodyColumnsAligned(slice);
    try std.testing.expectEqual(@as(usize, 2), slice.entities.len);
    try std.testing.expect(data.movementBodyConst(first) != null);
    try std.testing.expect(data.movementBodyConst(third) != null);
    try std.testing.expect(data.movementBodyConst(second) == null);

    for (slice.entities, 0..) |entity, index| {
        const expected = if (entity.matches(first.index, first.generation)) @as(f32, 1) else @as(f32, 3);
        try std.testing.expectEqual(expected, slice.position_x[index]);
        try std.testing.expectEqual(expected + 10, slice.position_y[index]);
        try std.testing.expectEqual(expected + 20, slice.previous_x[index]);
        try std.testing.expectEqual(expected + 30, slice.previous_y[index]);
        try std.testing.expectEqual(expected + 40, slice.velocity_x[index]);
        try std.testing.expectEqual(expected + 50, slice.velocity_y[index]);
        try std.testing.expectEqual(expected + 60, slice.speed[index]);
    }
}

test "component masks track entity membership for system queries" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try std.testing.expectEqual(@as(ComponentMask, 0), data.componentMaskFor(entity));
    try std.testing.expect(!data.hasComponents(entity, component_masks.movement_body));

    try data.setMovementBody(entity, testBody(1));
    try data.setFacing(entity, .{ .direction = .right });
    try std.testing.expect(data.hasComponents(entity, component_masks.movement_body | component_masks.facing));
    try std.testing.expect(!data.hasComponents(entity, component_masks.render_primitive));

    try data.setPrimitiveVisual(entity, testVisual());
    try std.testing.expect(data.hasComponents(entity, component_masks.render_primitive));
    try std.testing.expectEqual(
        component_masks.movement_body | component_masks.facing | component_masks.primitive_visual,
        data.componentMaskFor(entity),
    );

    try std.testing.expect(data.destroyEntity(entity));
    try std.testing.expectEqual(@as(ComponentMask, 0), data.componentMaskFor(entity));
    try std.testing.expect(!data.hasComponents(entity, component_masks.movement_body));
}

test "movement body columns can be loaded directly through simd helpers" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    for (0..simd.lane_count + 1) |index| {
        const entity = try data.createEntity();
        try data.setMovementBody(entity, testBody(@floatFromInt(index + 1)));
    }

    const slice = data.movementBodySliceConst();
    try expectMovementBodyColumnsAligned(slice);
    try std.testing.expectEqual(@as(usize, simd.lane_count), simd.vectorizedEnd(slice.entities.len));
    try std.testing.expectEqual(@as(usize, 1), simd.tailLen(slice.entities.len));

    try std.testing.expectEqual([_]f32{ 1, 2, 3, 4 }, simd.toFloatArray(simd.loadFloat4(slice.position_x[0..])));
    try std.testing.expectEqual([_]f32{ 11, 12, 13, 14 }, simd.toFloatArray(simd.loadFloat4(slice.position_y[0..])));
    try std.testing.expectEqual([_]f32{ 41, 42, 43, 44 }, simd.toFloatArray(simd.loadFloat4(slice.velocity_x[0..])));
    try std.testing.expectEqual([_]f32{ 61, 62, 63, 64 }, simd.toFloatArray(simd.loadFloat4(slice.speed[0..])));
}

test "movement hot columns keep explicit cache line alignment after growth" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    for (0..movement_range_alignment_items * 3 + 1) |index| {
        const entity = try data.createEntity();
        try data.setMovementBody(entity, testBody(@floatFromInt(index + 1)));
    }

    const slice = data.movementBodySliceConst();
    try expectMovementBodyColumnsAligned(slice);
    try expectHotColumnPointersAligned(slice);
    try std.testing.expectEqual(@as(usize, 16), movement_range_alignment_items);
    try std.testing.expectEqual(@as(usize, 0), (movement_range_alignment_items * @sizeOf(f32)) % hot_soa_column_alignment);
}

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

test "destroying an entity removes every attached data row" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, testBody(1));
    try data.setFacing(entity, .{ .direction = .right });
    try data.setPrimitiveVisual(entity, testVisual());
    try data.setAssetReference(entity, .{ .relative_path = "sprites/player.png" });

    try std.testing.expect(data.destroyEntity(entity));
    try std.testing.expectEqual(@as(usize, 0), data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 0), data.facingSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 0), data.primitiveVisualSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 0), data.assetReferenceSliceConst().entities.len);
}

test "primitive visual store is columnar and compact after removal" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    const second = try data.createEntity();
    const third = try data.createEntity();
    try data.setPrimitiveVisual(first, testVisualWithSize(16));
    try data.setPrimitiveVisual(second, testVisualWithSize(24));
    try data.setPrimitiveVisual(third, testVisualWithSize(32));

    try std.testing.expect(data.destroyEntity(second));

    const slice = data.primitiveVisualSliceConst();
    try expectPrimitiveVisualColumnsAligned(slice);
    try std.testing.expectEqual(@as(usize, 2), slice.entities.len);
    for (slice.entities, 0..) |entity, index| {
        const expected = if (entity.matches(first.index, first.generation)) @as(f32, 16) else @as(f32, 32);
        try std.testing.expectEqual(expected, slice.size_x[index]);
        try std.testing.expectEqual(expected, slice.size_y[index]);
    }
}

test "reset invalidates old ids while keeping system reusable" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, testBody(1));
    try data.setAssetReference(entity, .{ .relative_path = "sprites/player.png" });

    data.reset();
    try std.testing.expect(!data.isAlive(entity));
    try std.testing.expectEqual(@as(usize, 0), data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 0), data.assetReferenceSliceConst().entities.len);

    const reused = try data.createEntity();
    try std.testing.expect(data.isAlive(reused));
    try std.testing.expect(reused.generation != entity.generation);
}

test "asset references validate safe relative paths and own path storage" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setAssetReference(entity, .{ .relative_path = "sprites/player.png" });
    try std.testing.expectEqualStrings("sprites/player.png", data.assetReferenceConst(entity).?.relative_path);

    try data.setAssetReference(entity, .{ .relative_path = "sprites/player-alt.png" });
    try std.testing.expectEqualStrings("sprites/player-alt.png", data.assetReferenceConst(entity).?.relative_path);

    try std.testing.expectError(error.InvalidAssetPath, data.setAssetReference(entity, .{ .relative_path = "../player.png" }));
    try std.testing.expectError(error.InvalidAssetPath, data.setAssetReference(entity, .{ .relative_path = "/tmp/player.png" }));
    try std.testing.expectError(error.InvalidAssetPath, data.setAssetReference(entity, .{ .relative_path = "" }));
}

test "movement body slice access performs no allocations" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const entity = try data.createEntity();
    try data.setMovementBody(entity, testBody(1));

    const original_allocator = data.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    data.allocator = failing_allocator.allocator();
    defer data.allocator = original_allocator;

    const slice = data.movementBodySlice();
    try std.testing.expectEqual(@as(usize, 1), slice.entities.len);
    slice.position_x[0] += 1;
    try std.testing.expectEqual(@as(f32, 2), data.movementBodyConst(entity).?.position.x);
}

test "data system excludes runtime services and transient frame state" {
    try std.testing.expect(!@hasField(DataSystem, "renderer"));
    try std.testing.expect(!@hasField(DataSystem, "texture_id"));
    try std.testing.expect(!@hasField(DataSystem, "texture_lease"));
    try std.testing.expect(!@hasField(DataSystem, "input"));
    try std.testing.expect(!@hasField(DataSystem, "thread_system"));
    try std.testing.expect(!@hasField(DataSystem, "scratch"));
}

fn testBody(base: f32) MovementBody {
    return .{
        .position = .{ .x = base, .y = base + 10 },
        .previous_position = .{ .x = base + 20, .y = base + 30 },
        .velocity = .{ .x = base + 40, .y = base + 50 },
        .speed = base + 60,
    };
}

fn testVisual() PrimitiveVisual {
    return testVisualWithSize(32);
}

fn testVisualWithSize(size: f32) PrimitiveVisual {
    return .{
        .size = .{ .x = size, .y = size },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        .marker_length = 12,
        .marker_depth = 6,
        .marker_margin = 4,
    };
}
