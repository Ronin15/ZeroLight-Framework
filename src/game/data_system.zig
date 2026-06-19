// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-owned persistent gameplay data.
//! Hot system data is stored as scalar SoA columns so processors can load lanes
//! directly with core/simd.zig and split contiguous ranges through ThreadSystem.

const std = @import("std");
const SpriteAssetId = @import("../assets/manifest.zig").SpriteAssetId;
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
    collision_bounds,
    collision_response,
    ai_agent,
    steering_agent,
};

pub const ComponentMask = u32;

pub const component_masks = struct {
    pub const movement_body = componentMask(.movement_body);
    pub const facing = componentMask(.facing);
    pub const primitive_visual = componentMask(.primitive_visual);
    pub const asset_reference = componentMask(.asset_reference);
    pub const collision_bounds = componentMask(.collision_bounds);
    pub const collision_response = componentMask(.collision_response);
    pub const ai_agent = componentMask(.ai_agent);
    pub const steering_agent = componentMask(.steering_agent);
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
    sprite: SpriteAssetId,
};

pub const ConstAssetReferenceSlice = struct {
    entities: []const EntityId,
    sprite_ids: []const SpriteAssetId,
};

pub const CollisionBounds = struct {
    offset: math.Vec2 = .{},
    size: math.Vec2,
};

pub const CollisionBoundsCommand = struct {
    entity: EntityId,
    bounds: CollisionBounds,
};

pub const ConstCollisionBoundsSlice = struct {
    entities: []const EntityId,
    offset_x: ConstHotF32Slice,
    offset_y: ConstHotF32Slice,
    size_x: ConstHotF32Slice,
    size_y: ConstHotF32Slice,
};

pub const CollisionResponseMode = enum {
    solid,
    bounce,
    trigger,
};

pub const CollisionResponseMobility = enum {
    dynamic,
    static,
};

pub const CollisionResponse = struct {
    mode: CollisionResponseMode = .solid,
    mobility: CollisionResponseMobility = .dynamic,
    restitution: f32 = 0,
};

pub const CollisionResponseCommand = struct {
    entity: EntityId,
    response: CollisionResponse,
};

pub const ConstCollisionResponseSlice = struct {
    entities: []const EntityId,
    modes: []const CollisionResponseMode,
    mobilities: []const CollisionResponseMobility,
    restitution: ConstHotF32Slice,
};

pub const AiBehavior = enum {
    wander,
    seek,
};

pub const AiAgent = struct {
    behavior: AiBehavior = .wander,
    wander_amplitude: f32 = 30.0,
    seek_weight: f32 = 0.0,
};

pub const max_ai_wander_amplitude: f32 = 1000.0;
pub const max_ai_seek_weight: f32 = 16.0;

pub const AiAgentCommand = struct {
    entity: EntityId,
    agent: AiAgent,
};

pub const ConstAiAgentSlice = struct {
    entities: []const EntityId,
    behaviors: []const AiBehavior,
    wander_amplitudes: ConstHotF32Slice,
    seek_weights: ConstHotF32Slice,
};

pub const SteeringAgent = struct {
    agent_radius: f32 = 12.0,
    waypoint_tolerance: f32 = 8.0,
    avoidance_radius: f32 = 48.0,
    avoidance_weight: f32 = 1.0,
    max_neighbor_samples: u16 = 16,
    stuck_step_threshold: u16 = 18,
    replan_cooldown_steps: u16 = 12,
    unavailable_backoff_steps: u16 = 45,
};

pub const max_steering_radius: f32 = 512.0;
pub const max_steering_weight: f32 = 32.0;
pub const max_steering_neighbor_samples: u16 = 256;
pub const max_steering_cooldown_steps: u16 = 4096;

pub const SteeringAgentCommand = struct {
    entity: EntityId,
    agent: SteeringAgent,
};

pub const ConstSteeringAgentSlice = struct {
    entities: []const EntityId,
    agent_radii: ConstHotF32Slice,
    waypoint_tolerances: ConstHotF32Slice,
    avoidance_radii: ConstHotF32Slice,
    avoidance_weights: ConstHotF32Slice,
    max_neighbor_samples: []const u16,
    stuck_step_thresholds: []const u16,
    replan_cooldown_steps: []const u16,
    unavailable_backoff_steps: []const u16,
};

pub const EntityTemplate = struct {
    movement_body: ?MovementBody = null,
    facing: ?FacingData = null,
    primitive_visual: ?PrimitiveVisual = null,
    asset_reference: ?AssetReference = null,
    collision_bounds: ?CollisionBounds = null,
    collision_response: ?CollisionResponse = null,
    ai_agent: ?AiAgent = null,
    steering_agent: ?SteeringAgent = null,
};

pub const MovementBodyCommand = struct {
    entity: EntityId,
    body: MovementBody,
};

pub const FacingCommand = struct {
    entity: EntityId,
    facing: FacingData,
};

pub const PrimitiveVisualCommand = struct {
    entity: EntityId,
    visual: PrimitiveVisual,
};

pub const AssetReferenceCommand = struct {
    entity: EntityId,
    asset_reference: AssetReference,
};

pub const StructuralCommand = union(enum) {
    create_entity: EntityTemplate,
    destroy_entity: EntityId,
    set_movement_body: MovementBodyCommand,
    set_facing: FacingCommand,
    set_primitive_visual: PrimitiveVisualCommand,
    set_asset_reference: AssetReferenceCommand,
    set_collision_bounds: CollisionBoundsCommand,
    set_collision_response: CollisionResponseCommand,
    set_ai_agent: AiAgentCommand,
    set_steering_agent: SteeringAgentCommand,
};

pub const StructuralCommitStats = struct {
    created: usize = 0,
    destroyed: usize = 0,
    components_set: usize = 0,
    stale_skipped: usize = 0,
};

pub const DataSystem = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayList(EntitySlot) = .empty,
    first_free_slot: ?u32 = null,
    movement_bodies: MovementBodyStore = .{},
    facings: FacingStore = .{},
    primitive_visuals: PrimitiveVisualStore = .{},
    asset_refs: AssetReferenceStore = .{},
    collision_bounds: CollisionBoundsStore = .{},
    collision_responses: CollisionResponseStore = .{},
    ai_agents: AiAgentStore = .{},
    steering_agents: SteeringAgentStore = .{},

    pub fn init(allocator: std.mem.Allocator) DataSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DataSystem) void {
        self.steering_agents.deinit(self.allocator);
        self.ai_agents.deinit(self.allocator);
        self.collision_responses.deinit(self.allocator);
        self.collision_bounds.deinit(self.allocator);
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
        if (slot.collision_bounds_index) |dense_index| self.removeCollisionBoundsAt(@intCast(dense_index));
        if (slot.collision_response_index) |dense_index| self.removeCollisionResponseAt(@intCast(dense_index));
        if (slot.ai_agent_index) |dense_index| self.removeAiAgentAt(@intCast(dense_index));
        if (slot.steering_agent_index) |dense_index| self.removeSteeringAgentAt(@intCast(dense_index));

        const retired_slot = &self.slots.items[@intCast(index)];
        retired_slot.generation = nextGeneration(retired_slot.generation);
        retired_slot.alive = false;
        retired_slot.next_free = self.first_free_slot;
        retired_slot.component_mask = 0;
        retired_slot.movement_body_index = null;
        retired_slot.facing_index = null;
        retired_slot.primitive_visual_index = null;
        retired_slot.asset_ref_index = null;
        retired_slot.collision_bounds_index = null;
        retired_slot.collision_response_index = null;
        retired_slot.ai_agent_index = null;
        retired_slot.steering_agent_index = null;
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
        self.steering_agents.clearRetainingCapacity();
        self.ai_agents.clearRetainingCapacity();
        self.asset_refs.clearRetainingCapacity(self.allocator);
        self.collision_bounds.clearRetainingCapacity();
        self.collision_responses.clearRetainingCapacity();
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
            slot.collision_bounds_index = null;
            slot.collision_response_index = null;
            slot.ai_agent_index = null;
            slot.steering_agent_index = null;
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

    pub fn movementBodyDenseIndex(self: *const DataSystem, id: EntityId) ?usize {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.movement_body_index orelse return null;
        return @intCast(dense_index);
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
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;

        if (slot.asset_ref_index) |index| {
            self.asset_refs.sprite_ids.items[@intCast(index)] = asset_ref.sprite;
            return;
        }

        const dense_index = try self.asset_refs.append(self.allocator, id, asset_ref.sprite);
        slot.asset_ref_index = dense_index;
        slot.addComponent(.asset_reference);
    }

    pub fn assetReferenceConst(self: *const DataSystem, id: EntityId) ?AssetReference {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.asset_ref_index orelse return null;
        return .{ .sprite = self.asset_refs.sprite_ids.items[@intCast(dense_index)] };
    }

    pub fn assetReferenceSliceConst(self: *const DataSystem) ConstAssetReferenceSlice {
        return self.asset_refs.sliceConst();
    }

    pub fn setCollisionBounds(self: *DataSystem, id: EntityId, bounds: CollisionBounds) !void {
        try validateCollisionBounds(bounds);
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        if (slot.collision_bounds_index) |index| {
            self.collision_bounds.set(@intCast(index), bounds);
            return;
        }

        const dense_index = try self.collision_bounds.append(self.allocator, id, bounds);
        slot.collision_bounds_index = dense_index;
        slot.addComponent(.collision_bounds);
    }

    pub fn collisionBoundsConst(self: *const DataSystem, id: EntityId) ?CollisionBounds {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.collision_bounds_index orelse return null;
        return self.collision_bounds.get(@intCast(dense_index));
    }

    pub fn collisionBoundsDenseIndex(self: *const DataSystem, id: EntityId) ?usize {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.collision_bounds_index orelse return null;
        return @intCast(dense_index);
    }

    pub fn collisionBoundsSliceConst(self: *const DataSystem) ConstCollisionBoundsSlice {
        return self.collision_bounds.sliceConst();
    }

    pub fn setCollisionResponse(self: *DataSystem, id: EntityId, response: CollisionResponse) !void {
        try validateCollisionResponse(response);
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        if (slot.collision_response_index) |index| {
            self.collision_responses.set(@intCast(index), response);
            return;
        }

        const dense_index = try self.collision_responses.append(self.allocator, id, response);
        slot.collision_response_index = dense_index;
        slot.addComponent(.collision_response);
    }

    pub fn collisionResponseConst(self: *const DataSystem, id: EntityId) ?CollisionResponse {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.collision_response_index orelse return null;
        return self.collision_responses.get(@intCast(dense_index));
    }

    pub fn collisionResponseDenseIndex(self: *const DataSystem, id: EntityId) ?usize {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.collision_response_index orelse return null;
        return @intCast(dense_index);
    }

    pub fn collisionResponseSliceConst(self: *const DataSystem) ConstCollisionResponseSlice {
        return self.collision_responses.sliceConst();
    }

    pub fn setAiAgent(self: *DataSystem, id: EntityId, agent: AiAgent) !void {
        try validateAiAgent(agent);
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        if (slot.ai_agent_index) |index| {
            self.ai_agents.set(@intCast(index), agent);
            return;
        }

        const dense_index = try self.ai_agents.append(self.allocator, id, agent);
        slot.ai_agent_index = dense_index;
        slot.addComponent(.ai_agent);
    }

    pub fn aiAgentConst(self: *const DataSystem, id: EntityId) ?AiAgent {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.ai_agent_index orelse return null;
        return self.ai_agents.get(@intCast(dense_index));
    }

    pub fn aiAgentSliceConst(self: *const DataSystem) ConstAiAgentSlice {
        return self.ai_agents.sliceConst();
    }

    pub fn setSteeringAgent(self: *DataSystem, id: EntityId, agent: SteeringAgent) !void {
        try validateSteeringAgent(agent);
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        if (slot.steering_agent_index) |index| {
            self.steering_agents.set(@intCast(index), agent);
            return;
        }

        const dense_index = try self.steering_agents.append(self.allocator, id, agent);
        slot.steering_agent_index = dense_index;
        slot.addComponent(.steering_agent);
    }

    pub fn steeringAgentConst(self: *const DataSystem, id: EntityId) ?SteeringAgent {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.steering_agent_index orelse return null;
        return self.steering_agents.get(@intCast(dense_index));
    }

    pub fn steeringAgentDenseIndex(self: *const DataSystem, id: EntityId) ?usize {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.steering_agent_index orelse return null;
        return @intCast(dense_index);
    }

    pub fn steeringAgentSliceConst(self: *const DataSystem) ConstSteeringAgentSlice {
        return self.steering_agents.sliceConst();
    }

    pub fn applyStructuralCommands(self: *DataSystem, commands: []const StructuralCommand) !StructuralCommitStats {
        try validateStructuralCommands(commands);
        var stats = StructuralCommitStats{};
        for (commands) |command| {
            switch (command) {
                .create_entity => |template| {
                    const entity = try self.createEntity();
                    errdefer _ = self.destroyEntity(entity);
                    stats.created += 1;
                    stats.components_set += try self.applyTemplateComponents(entity, template);
                },
                .destroy_entity => |entity| {
                    if (self.destroyEntity(entity)) {
                        stats.destroyed += 1;
                    } else {
                        stats.stale_skipped += 1;
                    }
                },
                .set_movement_body => |set| {
                    if (!self.isAlive(set.entity)) {
                        stats.stale_skipped += 1;
                        continue;
                    }
                    try self.setMovementBody(set.entity, set.body);
                    stats.components_set += 1;
                },
                .set_facing => |set| {
                    if (!self.isAlive(set.entity)) {
                        stats.stale_skipped += 1;
                        continue;
                    }
                    try self.setFacing(set.entity, set.facing);
                    stats.components_set += 1;
                },
                .set_primitive_visual => |set| {
                    if (!self.isAlive(set.entity)) {
                        stats.stale_skipped += 1;
                        continue;
                    }
                    try self.setPrimitiveVisual(set.entity, set.visual);
                    stats.components_set += 1;
                },
                .set_asset_reference => |set| {
                    if (!self.isAlive(set.entity)) {
                        stats.stale_skipped += 1;
                        continue;
                    }
                    try self.setAssetReference(set.entity, set.asset_reference);
                    stats.components_set += 1;
                },
                .set_collision_bounds => |set| {
                    if (!self.isAlive(set.entity)) {
                        stats.stale_skipped += 1;
                        continue;
                    }
                    try self.setCollisionBounds(set.entity, set.bounds);
                    stats.components_set += 1;
                },
                .set_collision_response => |set| {
                    if (!self.isAlive(set.entity)) {
                        stats.stale_skipped += 1;
                        continue;
                    }
                    try self.setCollisionResponse(set.entity, set.response);
                    stats.components_set += 1;
                },
                .set_ai_agent => |set| {
                    if (!self.isAlive(set.entity)) {
                        stats.stale_skipped += 1;
                        continue;
                    }
                    try self.setAiAgent(set.entity, set.agent);
                    stats.components_set += 1;
                },
                .set_steering_agent => |set| {
                    if (!self.isAlive(set.entity)) {
                        stats.stale_skipped += 1;
                        continue;
                    }
                    try self.setSteeringAgent(set.entity, set.agent);
                    stats.components_set += 1;
                },
            }
        }
        return stats;
    }

    fn validateStructuralCommands(commands: []const StructuralCommand) !void {
        for (commands) |command| {
            switch (command) {
                .create_entity => |template| {
                    if (template.collision_bounds) |bounds| {
                        try validateCollisionBounds(bounds);
                    }
                    if (template.collision_response) |response| {
                        try validateCollisionResponse(response);
                    }
                    if (template.ai_agent) |agent| {
                        try validateAiAgent(agent);
                    }
                    if (template.steering_agent) |agent| {
                        try validateSteeringAgent(agent);
                    }
                },
                .set_collision_bounds => |set| try validateCollisionBounds(set.bounds),
                .set_collision_response => |set| try validateCollisionResponse(set.response),
                .set_ai_agent => |set| try validateAiAgent(set.agent),
                .set_steering_agent => |set| try validateSteeringAgent(set.agent),
                else => {},
            }
        }
    }

    fn applyTemplateComponents(self: *DataSystem, entity: EntityId, template: EntityTemplate) !usize {
        var components_set: usize = 0;
        if (template.movement_body) |body| {
            try self.setMovementBody(entity, body);
            components_set += 1;
        }
        if (template.facing) |facing| {
            try self.setFacing(entity, facing);
            components_set += 1;
        }
        if (template.primitive_visual) |visual| {
            try self.setPrimitiveVisual(entity, visual);
            components_set += 1;
        }
        if (template.asset_reference) |asset_ref| {
            try self.setAssetReference(entity, asset_ref);
            components_set += 1;
        }
        if (template.collision_bounds) |bounds| {
            try self.setCollisionBounds(entity, bounds);
            components_set += 1;
        }
        if (template.collision_response) |response| {
            try self.setCollisionResponse(entity, response);
            components_set += 1;
        }
        if (template.ai_agent) |agent| {
            try self.setAiAgent(entity, agent);
            components_set += 1;
        }
        if (template.steering_agent) |agent| {
            try self.setSteeringAgent(entity, agent);
            components_set += 1;
        }
        return components_set;
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

    fn removeCollisionBoundsAt(self: *DataSystem, index: usize) void {
        const moved = self.collision_bounds.removeAt(index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].collision_bounds_index = @intCast(index);
    }

    fn removeCollisionResponseAt(self: *DataSystem, index: usize) void {
        const moved = self.collision_responses.removeAt(index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].collision_response_index = @intCast(index);
    }

    fn removeAiAgentAt(self: *DataSystem, index: usize) void {
        const moved = self.ai_agents.removeAt(index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].ai_agent_index = @intCast(index);
    }

    fn removeSteeringAgentAt(self: *DataSystem, index: usize) void {
        const moved = self.steering_agents.removeAt(index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].steering_agent_index = @intCast(index);
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
    collision_bounds_index: ?u32 = null,
    collision_response_index: ?u32 = null,
    ai_agent_index: ?u32 = null,
    steering_agent_index: ?u32 = null,

    fn addComponent(self: *EntitySlot, component: Component) void {
        self.component_mask |= componentMask(component);
    }

    fn hasComponents(self: EntitySlot, mask: ComponentMask) bool {
        return (self.component_mask & mask) == mask;
    }
};

fn validateCollisionBounds(bounds: CollisionBounds) !void {
    if (!std.math.isFinite(bounds.offset.x) or !std.math.isFinite(bounds.offset.y)) return error.InvalidCollisionBounds;
    if (!std.math.isFinite(bounds.size.x) or !std.math.isFinite(bounds.size.y)) return error.InvalidCollisionBounds;
    if (bounds.size.x <= 0 or bounds.size.y <= 0) return error.InvalidCollisionBounds;
}

fn validateCollisionResponse(response: CollisionResponse) !void {
    if (!std.math.isFinite(response.restitution)) return error.InvalidCollisionResponse;
    if (response.restitution < 0) return error.InvalidCollisionResponse;
}

fn validateAiAgent(agent: AiAgent) !void {
    if (!std.math.isFinite(agent.wander_amplitude) or !std.math.isFinite(agent.seek_weight)) return error.InvalidAiAgent;
    if (agent.wander_amplitude < 0 or agent.seek_weight < 0) return error.InvalidAiAgent;
    if (agent.wander_amplitude > max_ai_wander_amplitude or agent.seek_weight > max_ai_seek_weight) return error.InvalidAiAgent;
}

fn validateSteeringAgent(agent: SteeringAgent) !void {
    if (!std.math.isFinite(agent.agent_radius) or
        !std.math.isFinite(agent.waypoint_tolerance) or
        !std.math.isFinite(agent.avoidance_radius) or
        !std.math.isFinite(agent.avoidance_weight))
    {
        return error.InvalidSteeringAgent;
    }
    if (agent.agent_radius <= 0 or
        agent.waypoint_tolerance < 0 or
        agent.avoidance_radius < 0 or
        agent.avoidance_weight < 0)
    {
        return error.InvalidSteeringAgent;
    }
    if (agent.agent_radius > max_steering_radius or
        agent.waypoint_tolerance > max_steering_radius or
        agent.avoidance_radius > max_steering_radius or
        agent.avoidance_weight > max_steering_weight or
        agent.max_neighbor_samples > max_steering_neighbor_samples or
        agent.replan_cooldown_steps > max_steering_cooldown_steps or
        agent.unavailable_backoff_steps > max_steering_cooldown_steps)
    {
        return error.InvalidSteeringAgent;
    }
}

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
    sprite_ids: std.ArrayList(SpriteAssetId) = .empty,

    fn append(self: *AssetReferenceStore, allocator: std.mem.Allocator, entity: EntityId, sprite: SpriteAssetId) !u32 {
        if (self.entities.items.len >= std.math.maxInt(u32)) return error.TooManyAssetReferenceRows;
        const capacity = self.entities.items.len + 1;
        try self.entities.ensureTotalCapacity(allocator, capacity);
        try self.sprite_ids.ensureTotalCapacity(allocator, capacity);
        const index: u32 = @intCast(self.entities.items.len);
        self.entities.appendAssumeCapacity(entity);
        self.sprite_ids.appendAssumeCapacity(sprite);
        return index;
    }

    fn removeAt(self: *AssetReferenceStore, allocator: std.mem.Allocator, index: usize) ?EntityId {
        _ = allocator;
        const last = self.entities.items.len - 1;
        const moved_entity = if (index != last) self.entities.items[last] else null;
        self.entities.items[index] = self.entities.items[last];
        self.sprite_ids.items[index] = self.sprite_ids.items[last];
        _ = self.entities.pop();
        _ = self.sprite_ids.pop();
        return moved_entity;
    }

    fn sliceConst(self: *const AssetReferenceStore) ConstAssetReferenceSlice {
        return .{ .entities = self.entities.items, .sprite_ids = self.sprite_ids.items };
    }

    fn clearRetainingCapacity(self: *AssetReferenceStore, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.entities.clearRetainingCapacity();
        self.sprite_ids.clearRetainingCapacity();
    }

    fn deinit(self: *AssetReferenceStore, allocator: std.mem.Allocator) void {
        self.entities.deinit(allocator);
        self.sprite_ids.deinit(allocator);
        self.* = .{};
    }
};

const CollisionBoundsStore = struct {
    entities: std.ArrayList(EntityId) = .empty,
    offset_x: HotF32List = .empty,
    offset_y: HotF32List = .empty,
    size_x: HotF32List = .empty,
    size_y: HotF32List = .empty,

    fn append(self: *CollisionBoundsStore, allocator: std.mem.Allocator, entity: EntityId, bounds: CollisionBounds) !u32 {
        if (self.entities.items.len >= std.math.maxInt(u32)) return error.TooManyCollisionBoundsRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.entities.items.len);
        self.entities.appendAssumeCapacity(entity);
        self.offset_x.appendAssumeCapacity(bounds.offset.x);
        self.offset_y.appendAssumeCapacity(bounds.offset.y);
        self.size_x.appendAssumeCapacity(bounds.size.x);
        self.size_y.appendAssumeCapacity(bounds.size.y);
        return index;
    }

    fn set(self: *CollisionBoundsStore, index: usize, bounds: CollisionBounds) void {
        self.offset_x.items[index] = bounds.offset.x;
        self.offset_y.items[index] = bounds.offset.y;
        self.size_x.items[index] = bounds.size.x;
        self.size_y.items[index] = bounds.size.y;
    }

    fn get(self: *const CollisionBoundsStore, index: usize) CollisionBounds {
        return .{
            .offset = .{ .x = self.offset_x.items[index], .y = self.offset_y.items[index] },
            .size = .{ .x = self.size_x.items[index], .y = self.size_y.items[index] },
        };
    }

    fn removeAt(self: *CollisionBoundsStore, index: usize) ?EntityId {
        const last = self.entities.items.len - 1;
        const moved_entity = if (index != last) self.entities.items[last] else null;
        self.entities.items[index] = self.entities.items[last];
        self.offset_x.items[index] = self.offset_x.items[last];
        self.offset_y.items[index] = self.offset_y.items[last];
        self.size_x.items[index] = self.size_x.items[last];
        self.size_y.items[index] = self.size_y.items[last];
        _ = self.entities.pop();
        _ = self.offset_x.pop();
        _ = self.offset_y.pop();
        _ = self.size_x.pop();
        _ = self.size_y.pop();
        return moved_entity;
    }

    fn sliceConst(self: *const CollisionBoundsStore) ConstCollisionBoundsSlice {
        return .{
            .entities = self.entities.items,
            .offset_x = self.offset_x.items,
            .offset_y = self.offset_y.items,
            .size_x = self.size_x.items,
            .size_y = self.size_y.items,
        };
    }

    fn clearRetainingCapacity(self: *CollisionBoundsStore) void {
        self.entities.clearRetainingCapacity();
        self.offset_x.clearRetainingCapacity();
        self.offset_y.clearRetainingCapacity();
        self.size_x.clearRetainingCapacity();
        self.size_y.clearRetainingCapacity();
    }

    fn deinit(self: *CollisionBoundsStore, allocator: std.mem.Allocator) void {
        self.entities.deinit(allocator);
        self.offset_x.deinit(allocator);
        self.offset_y.deinit(allocator);
        self.size_x.deinit(allocator);
        self.size_y.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *CollisionBoundsStore, allocator: std.mem.Allocator) !void {
        const capacity = self.entities.items.len + 1;
        try self.entities.ensureTotalCapacity(allocator, capacity);
        try self.offset_x.ensureTotalCapacity(allocator, capacity);
        try self.offset_y.ensureTotalCapacity(allocator, capacity);
        try self.size_x.ensureTotalCapacity(allocator, capacity);
        try self.size_y.ensureTotalCapacity(allocator, capacity);
    }
};

const CollisionResponseStore = struct {
    entities: std.ArrayList(EntityId) = .empty,
    modes: std.ArrayList(CollisionResponseMode) = .empty,
    mobilities: std.ArrayList(CollisionResponseMobility) = .empty,
    restitution: HotF32List = .empty,

    fn append(self: *CollisionResponseStore, allocator: std.mem.Allocator, entity: EntityId, response: CollisionResponse) !u32 {
        if (self.entities.items.len >= std.math.maxInt(u32)) return error.TooManyCollisionResponseRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.entities.items.len);
        self.entities.appendAssumeCapacity(entity);
        self.modes.appendAssumeCapacity(response.mode);
        self.mobilities.appendAssumeCapacity(response.mobility);
        self.restitution.appendAssumeCapacity(response.restitution);
        return index;
    }

    fn set(self: *CollisionResponseStore, index: usize, response: CollisionResponse) void {
        self.modes.items[index] = response.mode;
        self.mobilities.items[index] = response.mobility;
        self.restitution.items[index] = response.restitution;
    }

    fn get(self: *const CollisionResponseStore, index: usize) CollisionResponse {
        return .{
            .mode = self.modes.items[index],
            .mobility = self.mobilities.items[index],
            .restitution = self.restitution.items[index],
        };
    }

    fn removeAt(self: *CollisionResponseStore, index: usize) ?EntityId {
        const last = self.entities.items.len - 1;
        const moved_entity = if (index != last) self.entities.items[last] else null;
        self.entities.items[index] = self.entities.items[last];
        self.modes.items[index] = self.modes.items[last];
        self.mobilities.items[index] = self.mobilities.items[last];
        self.restitution.items[index] = self.restitution.items[last];
        _ = self.entities.pop();
        _ = self.modes.pop();
        _ = self.mobilities.pop();
        _ = self.restitution.pop();
        return moved_entity;
    }

    fn sliceConst(self: *const CollisionResponseStore) ConstCollisionResponseSlice {
        return .{
            .entities = self.entities.items,
            .modes = self.modes.items,
            .mobilities = self.mobilities.items,
            .restitution = self.restitution.items,
        };
    }

    fn clearRetainingCapacity(self: *CollisionResponseStore) void {
        self.entities.clearRetainingCapacity();
        self.modes.clearRetainingCapacity();
        self.mobilities.clearRetainingCapacity();
        self.restitution.clearRetainingCapacity();
    }

    fn deinit(self: *CollisionResponseStore, allocator: std.mem.Allocator) void {
        self.entities.deinit(allocator);
        self.modes.deinit(allocator);
        self.mobilities.deinit(allocator);
        self.restitution.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *CollisionResponseStore, allocator: std.mem.Allocator) !void {
        const capacity = self.entities.items.len + 1;
        try self.entities.ensureTotalCapacity(allocator, capacity);
        try self.modes.ensureTotalCapacity(allocator, capacity);
        try self.mobilities.ensureTotalCapacity(allocator, capacity);
        try self.restitution.ensureTotalCapacity(allocator, capacity);
    }
};

const AiAgentStore = struct {
    entities: std.ArrayList(EntityId) = .empty,
    behaviors: std.ArrayList(AiBehavior) = .empty,
    wander_amplitudes: HotF32List = .empty,
    seek_weights: HotF32List = .empty,

    fn append(self: *AiAgentStore, allocator: std.mem.Allocator, entity: EntityId, agent: AiAgent) !u32 {
        if (self.entities.items.len >= std.math.maxInt(u32)) return error.TooManyAiAgentRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.entities.items.len);
        self.entities.appendAssumeCapacity(entity);
        self.behaviors.appendAssumeCapacity(agent.behavior);
        self.wander_amplitudes.appendAssumeCapacity(agent.wander_amplitude);
        self.seek_weights.appendAssumeCapacity(agent.seek_weight);
        return index;
    }

    fn set(self: *AiAgentStore, index: usize, agent: AiAgent) void {
        self.behaviors.items[index] = agent.behavior;
        self.wander_amplitudes.items[index] = agent.wander_amplitude;
        self.seek_weights.items[index] = agent.seek_weight;
    }

    fn get(self: *const AiAgentStore, index: usize) AiAgent {
        return .{
            .behavior = self.behaviors.items[index],
            .wander_amplitude = self.wander_amplitudes.items[index],
            .seek_weight = self.seek_weights.items[index],
        };
    }

    fn removeAt(self: *AiAgentStore, index: usize) ?EntityId {
        const last = self.entities.items.len - 1;
        const moved_entity = if (index != last) self.entities.items[last] else null;
        self.entities.items[index] = self.entities.items[last];
        self.behaviors.items[index] = self.behaviors.items[last];
        self.wander_amplitudes.items[index] = self.wander_amplitudes.items[last];
        self.seek_weights.items[index] = self.seek_weights.items[last];
        _ = self.entities.pop();
        _ = self.behaviors.pop();
        _ = self.wander_amplitudes.pop();
        _ = self.seek_weights.pop();
        return moved_entity;
    }

    fn sliceConst(self: *const AiAgentStore) ConstAiAgentSlice {
        return .{
            .entities = self.entities.items,
            .behaviors = self.behaviors.items,
            .wander_amplitudes = self.wander_amplitudes.items,
            .seek_weights = self.seek_weights.items,
        };
    }

    fn clearRetainingCapacity(self: *AiAgentStore) void {
        self.entities.clearRetainingCapacity();
        self.behaviors.clearRetainingCapacity();
        self.wander_amplitudes.clearRetainingCapacity();
        self.seek_weights.clearRetainingCapacity();
    }

    fn deinit(self: *AiAgentStore, allocator: std.mem.Allocator) void {
        self.entities.deinit(allocator);
        self.behaviors.deinit(allocator);
        self.wander_amplitudes.deinit(allocator);
        self.seek_weights.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *AiAgentStore, allocator: std.mem.Allocator) !void {
        const capacity = self.entities.items.len + 1;
        try self.entities.ensureTotalCapacity(allocator, capacity);
        try self.behaviors.ensureTotalCapacity(allocator, capacity);
        try self.wander_amplitudes.ensureTotalCapacity(allocator, capacity);
        try self.seek_weights.ensureTotalCapacity(allocator, capacity);
    }
};

const SteeringAgentStore = struct {
    entities: std.ArrayList(EntityId) = .empty,
    agent_radii: HotF32List = .empty,
    waypoint_tolerances: HotF32List = .empty,
    avoidance_radii: HotF32List = .empty,
    avoidance_weights: HotF32List = .empty,
    max_neighbor_samples: std.ArrayList(u16) = .empty,
    stuck_step_thresholds: std.ArrayList(u16) = .empty,
    replan_cooldown_steps: std.ArrayList(u16) = .empty,
    unavailable_backoff_steps: std.ArrayList(u16) = .empty,

    fn append(self: *SteeringAgentStore, allocator: std.mem.Allocator, entity: EntityId, agent: SteeringAgent) !u32 {
        if (self.entities.items.len >= std.math.maxInt(u32)) return error.TooManySteeringAgentRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.entities.items.len);
        self.entities.appendAssumeCapacity(entity);
        self.appendColumnsAssumeCapacity(agent);
        return index;
    }

    fn set(self: *SteeringAgentStore, index: usize, agent: SteeringAgent) void {
        self.agent_radii.items[index] = agent.agent_radius;
        self.waypoint_tolerances.items[index] = agent.waypoint_tolerance;
        self.avoidance_radii.items[index] = agent.avoidance_radius;
        self.avoidance_weights.items[index] = agent.avoidance_weight;
        self.max_neighbor_samples.items[index] = agent.max_neighbor_samples;
        self.stuck_step_thresholds.items[index] = agent.stuck_step_threshold;
        self.replan_cooldown_steps.items[index] = agent.replan_cooldown_steps;
        self.unavailable_backoff_steps.items[index] = agent.unavailable_backoff_steps;
    }

    fn get(self: *const SteeringAgentStore, index: usize) SteeringAgent {
        return .{
            .agent_radius = self.agent_radii.items[index],
            .waypoint_tolerance = self.waypoint_tolerances.items[index],
            .avoidance_radius = self.avoidance_radii.items[index],
            .avoidance_weight = self.avoidance_weights.items[index],
            .max_neighbor_samples = self.max_neighbor_samples.items[index],
            .stuck_step_threshold = self.stuck_step_thresholds.items[index],
            .replan_cooldown_steps = self.replan_cooldown_steps.items[index],
            .unavailable_backoff_steps = self.unavailable_backoff_steps.items[index],
        };
    }

    fn removeAt(self: *SteeringAgentStore, index: usize) ?EntityId {
        const last = self.entities.items.len - 1;
        const moved_entity = if (index != last) self.entities.items[last] else null;
        self.entities.items[index] = self.entities.items[last];
        self.agent_radii.items[index] = self.agent_radii.items[last];
        self.waypoint_tolerances.items[index] = self.waypoint_tolerances.items[last];
        self.avoidance_radii.items[index] = self.avoidance_radii.items[last];
        self.avoidance_weights.items[index] = self.avoidance_weights.items[last];
        self.max_neighbor_samples.items[index] = self.max_neighbor_samples.items[last];
        self.stuck_step_thresholds.items[index] = self.stuck_step_thresholds.items[last];
        self.replan_cooldown_steps.items[index] = self.replan_cooldown_steps.items[last];
        self.unavailable_backoff_steps.items[index] = self.unavailable_backoff_steps.items[last];
        _ = self.entities.pop();
        _ = self.agent_radii.pop();
        _ = self.waypoint_tolerances.pop();
        _ = self.avoidance_radii.pop();
        _ = self.avoidance_weights.pop();
        _ = self.max_neighbor_samples.pop();
        _ = self.stuck_step_thresholds.pop();
        _ = self.replan_cooldown_steps.pop();
        _ = self.unavailable_backoff_steps.pop();
        return moved_entity;
    }

    fn sliceConst(self: *const SteeringAgentStore) ConstSteeringAgentSlice {
        return .{
            .entities = self.entities.items,
            .agent_radii = self.agent_radii.items,
            .waypoint_tolerances = self.waypoint_tolerances.items,
            .avoidance_radii = self.avoidance_radii.items,
            .avoidance_weights = self.avoidance_weights.items,
            .max_neighbor_samples = self.max_neighbor_samples.items,
            .stuck_step_thresholds = self.stuck_step_thresholds.items,
            .replan_cooldown_steps = self.replan_cooldown_steps.items,
            .unavailable_backoff_steps = self.unavailable_backoff_steps.items,
        };
    }

    fn clearRetainingCapacity(self: *SteeringAgentStore) void {
        self.entities.clearRetainingCapacity();
        self.agent_radii.clearRetainingCapacity();
        self.waypoint_tolerances.clearRetainingCapacity();
        self.avoidance_radii.clearRetainingCapacity();
        self.avoidance_weights.clearRetainingCapacity();
        self.max_neighbor_samples.clearRetainingCapacity();
        self.stuck_step_thresholds.clearRetainingCapacity();
        self.replan_cooldown_steps.clearRetainingCapacity();
        self.unavailable_backoff_steps.clearRetainingCapacity();
    }

    fn deinit(self: *SteeringAgentStore, allocator: std.mem.Allocator) void {
        self.entities.deinit(allocator);
        self.agent_radii.deinit(allocator);
        self.waypoint_tolerances.deinit(allocator);
        self.avoidance_radii.deinit(allocator);
        self.avoidance_weights.deinit(allocator);
        self.max_neighbor_samples.deinit(allocator);
        self.stuck_step_thresholds.deinit(allocator);
        self.replan_cooldown_steps.deinit(allocator);
        self.unavailable_backoff_steps.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *SteeringAgentStore, allocator: std.mem.Allocator) !void {
        const capacity = self.entities.items.len + 1;
        try self.entities.ensureTotalCapacity(allocator, capacity);
        try self.agent_radii.ensureTotalCapacity(allocator, capacity);
        try self.waypoint_tolerances.ensureTotalCapacity(allocator, capacity);
        try self.avoidance_radii.ensureTotalCapacity(allocator, capacity);
        try self.avoidance_weights.ensureTotalCapacity(allocator, capacity);
        try self.max_neighbor_samples.ensureTotalCapacity(allocator, capacity);
        try self.stuck_step_thresholds.ensureTotalCapacity(allocator, capacity);
        try self.replan_cooldown_steps.ensureTotalCapacity(allocator, capacity);
        try self.unavailable_backoff_steps.ensureTotalCapacity(allocator, capacity);
    }

    fn appendColumnsAssumeCapacity(self: *SteeringAgentStore, agent: SteeringAgent) void {
        self.agent_radii.appendAssumeCapacity(agent.agent_radius);
        self.waypoint_tolerances.appendAssumeCapacity(agent.waypoint_tolerance);
        self.avoidance_radii.appendAssumeCapacity(agent.avoidance_radius);
        self.avoidance_weights.appendAssumeCapacity(agent.avoidance_weight);
        self.max_neighbor_samples.appendAssumeCapacity(agent.max_neighbor_samples);
        self.stuck_step_thresholds.appendAssumeCapacity(agent.stuck_step_threshold);
        self.replan_cooldown_steps.appendAssumeCapacity(agent.replan_cooldown_steps);
        self.unavailable_backoff_steps.appendAssumeCapacity(agent.unavailable_backoff_steps);
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

fn expectCollisionBoundsColumnsAligned(slice: ConstCollisionBoundsSlice) !void {
    try std.testing.expectEqual(slice.entities.len, slice.offset_x.len);
    try std.testing.expectEqual(slice.entities.len, slice.offset_y.len);
    try std.testing.expectEqual(slice.entities.len, slice.size_x.len);
    try std.testing.expectEqual(slice.entities.len, slice.size_y.len);
    try expectPointerAligned(slice.offset_x.ptr);
    try expectPointerAligned(slice.offset_y.ptr);
    try expectPointerAligned(slice.size_x.ptr);
    try expectPointerAligned(slice.size_y.ptr);
}

fn expectCollisionResponseColumnsAligned(slice: ConstCollisionResponseSlice) !void {
    try std.testing.expectEqual(slice.entities.len, slice.modes.len);
    try std.testing.expectEqual(slice.entities.len, slice.mobilities.len);
    try std.testing.expectEqual(slice.entities.len, slice.restitution.len);
    try expectPointerAligned(slice.restitution.ptr);
}

fn expectAiAgentColumnsAligned(slice: ConstAiAgentSlice) !void {
    try std.testing.expectEqual(slice.entities.len, slice.behaviors.len);
    try std.testing.expectEqual(slice.entities.len, slice.wander_amplitudes.len);
    try std.testing.expectEqual(slice.entities.len, slice.seek_weights.len);
    try expectPointerAligned(slice.wander_amplitudes.ptr);
    try expectPointerAligned(slice.seek_weights.ptr);
}

fn expectSteeringAgentColumnsAligned(slice: ConstSteeringAgentSlice) !void {
    try std.testing.expectEqual(slice.entities.len, slice.agent_radii.len);
    try std.testing.expectEqual(slice.entities.len, slice.waypoint_tolerances.len);
    try std.testing.expectEqual(slice.entities.len, slice.avoidance_radii.len);
    try std.testing.expectEqual(slice.entities.len, slice.avoidance_weights.len);
    try std.testing.expectEqual(slice.entities.len, slice.max_neighbor_samples.len);
    try std.testing.expectEqual(slice.entities.len, slice.stuck_step_thresholds.len);
    try std.testing.expectEqual(slice.entities.len, slice.replan_cooldown_steps.len);
    try std.testing.expectEqual(slice.entities.len, slice.unavailable_backoff_steps.len);
    try expectPointerAligned(slice.agent_radii.ptr);
    try expectPointerAligned(slice.waypoint_tolerances.ptr);
    try expectPointerAligned(slice.avoidance_radii.ptr);
    try expectPointerAligned(slice.avoidance_weights.ptr);
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
    try std.testing.expect(!data.hasComponents(entity, component_masks.collision_bounds));
    try std.testing.expect(!data.hasComponents(entity, component_masks.collision_response));

    try data.setPrimitiveVisual(entity, testVisual());
    try data.setCollisionBounds(entity, testBounds(2));
    try data.setCollisionResponse(entity, testResponse(.solid, .dynamic, 0));
    try data.setAiAgent(entity, .{ .behavior = .wander });
    try data.setSteeringAgent(entity, testSteeringAgent(1));
    try std.testing.expect(data.hasComponents(entity, component_masks.render_primitive));
    try std.testing.expect(data.hasComponents(entity, component_masks.collision_bounds));
    try std.testing.expect(data.hasComponents(entity, component_masks.collision_response));
    try std.testing.expect(data.hasComponents(entity, component_masks.ai_agent));
    try std.testing.expect(data.hasComponents(entity, component_masks.steering_agent));
    try std.testing.expectEqual(
        component_masks.movement_body | component_masks.facing | component_masks.primitive_visual | component_masks.collision_bounds | component_masks.collision_response | component_masks.ai_agent | component_masks.steering_agent,
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
    try data.setAssetReference(entity, .{ .sprite = .demo_tile });
    try data.setCollisionBounds(entity, testBounds(1));
    try data.setCollisionResponse(entity, testResponse(.bounce, .dynamic, 0.75));
    try data.setSteeringAgent(entity, testSteeringAgent(1));

    try std.testing.expect(data.destroyEntity(entity));
    try std.testing.expectEqual(@as(usize, 0), data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 0), data.facingSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 0), data.primitiveVisualSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 0), data.assetReferenceSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 0), data.collisionBoundsSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 0), data.collisionResponseSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 0), data.steeringAgentSliceConst().entities.len);
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
    try data.setAssetReference(entity, .{ .sprite = .demo_tile });

    data.reset();
    try std.testing.expect(!data.isAlive(entity));
    try std.testing.expectEqual(@as(usize, 0), data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 0), data.assetReferenceSliceConst().entities.len);

    const reused = try data.createEntity();
    try std.testing.expect(data.isAlive(reused));
    try std.testing.expect(reused.generation != entity.generation);
}

test "asset references store stable sprite ids" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setAssetReference(entity, .{ .sprite = .demo_tile });
    try std.testing.expectEqual(SpriteAssetId.demo_tile, data.assetReferenceConst(entity).?.sprite);

    const slice = data.assetReferenceSliceConst();
    try std.testing.expectEqual(@as(usize, 1), slice.entities.len);
    try std.testing.expectEqual(SpriteAssetId.demo_tile, slice.sprite_ids[0]);
}

test "collision bounds store is columnar compact and rejects invalid bounds" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    const second = try data.createEntity();
    const third = try data.createEntity();
    try data.setCollisionBounds(first, testBounds(1));
    try data.setCollisionBounds(second, testBounds(2));
    try data.setCollisionBounds(third, testBounds(3));
    try data.setCollisionBounds(first, .{ .offset = .{ .x = 4, .y = 5 }, .size = .{ .x = 6, .y = 7 } });

    try std.testing.expectEqual(@as(f32, 4), data.collisionBoundsConst(first).?.offset.x);
    try std.testing.expectEqual(@as(f32, 6), data.collisionBoundsConst(first).?.size.x);
    try std.testing.expectError(error.InvalidCollisionBounds, data.setCollisionBounds(first, .{ .size = .{ .x = 0, .y = 1 } }));
    try std.testing.expectError(error.InvalidCollisionBounds, data.setCollisionBounds(first, .{ .size = .{ .x = -1, .y = 1 } }));
    try std.testing.expectError(error.InvalidCollisionBounds, data.setCollisionBounds(first, .{ .offset = .{ .x = std.math.inf(f32), .y = 0 }, .size = .{ .x = 1, .y = 1 } }));
    try std.testing.expectError(error.InvalidCollisionBounds, data.setCollisionBounds(first, .{ .offset = .{ .x = -std.math.inf(f32), .y = 0 }, .size = .{ .x = 1, .y = 1 } }));
    try std.testing.expectError(error.InvalidCollisionBounds, data.setCollisionBounds(first, .{ .offset = .{ .x = std.math.nan(f32), .y = 0 }, .size = .{ .x = 1, .y = 1 } }));
    try std.testing.expectError(error.InvalidCollisionBounds, data.setCollisionBounds(first, .{ .size = .{ .x = std.math.inf(f32), .y = 1 } }));
    try std.testing.expectError(error.InvalidCollisionBounds, data.setCollisionBounds(first, .{ .size = .{ .x = std.math.nan(f32), .y = 1 } }));

    try std.testing.expect(data.destroyEntity(second));
    const slice = data.collisionBoundsSliceConst();
    try expectCollisionBoundsColumnsAligned(slice);
    try std.testing.expectEqual(@as(usize, 2), slice.entities.len);
    try std.testing.expect(data.collisionBoundsConst(first) != null);
    try std.testing.expect(data.collisionBoundsConst(third) != null);
    try std.testing.expect(data.collisionBoundsConst(second) == null);
    try std.testing.expect(data.collisionBoundsDenseIndex(first) != null);
    try std.testing.expect(data.collisionBoundsDenseIndex(third) != null);
    try std.testing.expectEqual(@as(?usize, null), data.collisionBoundsDenseIndex(second));
    try std.testing.expectEqual(first.index, slice.entities[data.collisionBoundsDenseIndex(first).?].index);
    try std.testing.expectEqual(third.index, slice.entities[data.collisionBoundsDenseIndex(third).?].index);
}

test "collision response store is columnar compact and rejects invalid response data" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    const second = try data.createEntity();
    const third = try data.createEntity();
    try data.setCollisionResponse(first, testResponse(.solid, .dynamic, 0));
    try data.setCollisionResponse(second, testResponse(.bounce, .dynamic, 0.5));
    try data.setCollisionResponse(third, testResponse(.trigger, .static, 1));
    try data.setCollisionResponse(first, testResponse(.bounce, .dynamic, 0.75));

    const first_response = data.collisionResponseConst(first).?;
    try std.testing.expectEqual(CollisionResponseMode.bounce, first_response.mode);
    try std.testing.expectEqual(CollisionResponseMobility.dynamic, first_response.mobility);
    try std.testing.expectEqual(@as(f32, 0.75), first_response.restitution);
    try std.testing.expectError(error.InvalidCollisionResponse, data.setCollisionResponse(first, testResponse(.bounce, .dynamic, -0.01)));
    try std.testing.expectError(error.InvalidCollisionResponse, data.setCollisionResponse(first, testResponse(.bounce, .dynamic, std.math.inf(f32))));
    try std.testing.expectError(error.InvalidCollisionResponse, data.setCollisionResponse(first, testResponse(.bounce, .dynamic, std.math.nan(f32))));

    try std.testing.expect(data.destroyEntity(second));
    const slice = data.collisionResponseSliceConst();
    try expectCollisionResponseColumnsAligned(slice);
    try std.testing.expectEqual(@as(usize, 2), slice.entities.len);
    try std.testing.expect(data.collisionResponseConst(first) != null);
    try std.testing.expect(data.collisionResponseConst(third) != null);
    try std.testing.expect(data.collisionResponseConst(second) == null);
    try std.testing.expect(data.collisionResponseDenseIndex(first) != null);
    try std.testing.expect(data.collisionResponseDenseIndex(third) != null);
    try std.testing.expectEqual(@as(?usize, null), data.collisionResponseDenseIndex(second));
    try std.testing.expectEqual(first.index, slice.entities[data.collisionResponseDenseIndex(first).?].index);
    try std.testing.expectEqual(third.index, slice.entities[data.collisionResponseDenseIndex(third).?].index);
}

test "structural commands apply entity creation and component changes in order" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const existing = try data.createEntity();
    const commands = [_]StructuralCommand{
        .{ .create_entity = .{
            .movement_body = testBody(10),
            .facing = .{ .direction = .left },
            .primitive_visual = testVisualWithSize(20),
            .collision_bounds = testBounds(6),
            .collision_response = testResponse(.solid, .dynamic, 0),
            .ai_agent = .{ .behavior = .wander, .wander_amplitude = 42.0, .seek_weight = 0.1 },
            .steering_agent = testSteeringAgent(1),
        } },
        .{ .set_movement_body = .{ .entity = existing, .body = testBody(3) } },
        .{ .set_facing = .{ .entity = existing, .facing = .{ .direction = .right } } },
        .{ .set_collision_bounds = .{ .entity = existing, .bounds = testBounds(8) } },
        .{ .set_collision_response = .{ .entity = existing, .response = testResponse(.bounce, .dynamic, 0.8) } },
        .{ .set_ai_agent = .{ .entity = existing, .agent = .{ .behavior = .seek, .wander_amplitude = 0, .seek_weight = 0.75 } } },
        .{ .set_steering_agent = .{ .entity = existing, .agent = testSteeringAgent(2) } },
    };

    const stats = try data.applyStructuralCommands(&commands);

    try std.testing.expectEqual(@as(usize, 1), stats.created);
    try std.testing.expectEqual(@as(usize, 0), stats.destroyed);
    try std.testing.expectEqual(@as(usize, 13), stats.components_set);
    try std.testing.expectEqual(@as(usize, 0), stats.stale_skipped);
    try std.testing.expectEqual(@as(usize, 2), data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(@as(f32, 3), data.movementBodyConst(existing).?.position.x);
    try std.testing.expectEqual(Facing.right, data.facingConst(existing).?.direction);
    try std.testing.expectEqual(@as(f32, 8), data.collisionBoundsConst(existing).?.size.x);
    try std.testing.expectEqual(CollisionResponseMode.bounce, data.collisionResponseConst(existing).?.mode);
    const ai_slice = data.aiAgentSliceConst();
    try expectAiAgentColumnsAligned(ai_slice);
    try std.testing.expectEqual(@as(usize, 2), ai_slice.entities.len);
    const existing_ai = data.aiAgentConst(existing).?;
    try std.testing.expectEqual(AiBehavior.seek, existing_ai.behavior);
    try std.testing.expectEqual(@as(f32, 0.75), existing_ai.seek_weight);
    try std.testing.expectEqual(@as(f32, 14), data.steeringAgentConst(existing).?.agent_radius);
    // created one also has ai from template
    try std.testing.expect(data.aiAgentConst(data.movementBodySliceConst().entities[0]) != null or data.aiAgentConst(data.movementBodySliceConst().entities[1]) != null);
}

test "structural commands skip stale entities and preserve deterministic command order" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, testBody(1));
    const stale = entity;
    try std.testing.expect(data.destroyEntity(entity));
    const replacement = try data.createEntity();

    const commands = [_]StructuralCommand{
        .{ .set_movement_body = .{ .entity = stale, .body = testBody(99) } },
        .{ .set_movement_body = .{ .entity = replacement, .body = testBody(4) } },
        .{ .set_movement_body = .{ .entity = replacement, .body = testBody(5) } },
        .{ .destroy_entity = stale },
    };

    const stats = try data.applyStructuralCommands(&commands);

    try std.testing.expectEqual(@as(usize, 0), stats.created);
    try std.testing.expectEqual(@as(usize, 0), stats.destroyed);
    try std.testing.expectEqual(@as(usize, 2), stats.components_set);
    try std.testing.expectEqual(@as(usize, 2), stats.stale_skipped);
    try std.testing.expectEqual(@as(f32, 5), data.movementBodyConst(replacement).?.position.x);
}

test "ai agent component stores dense columns, supports template create and set/get, rejects invalid, compacts on destroy" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    const second = try data.createEntity();
    const third = try data.createEntity();
    try data.setAiAgent(first, .{ .behavior = .wander, .wander_amplitude = 12.5, .seek_weight = 0 });
    try data.setAiAgent(second, .{ .behavior = .seek, .wander_amplitude = 0, .seek_weight = 0.9 });
    try data.setAiAgent(third, .{ .behavior = .wander, .wander_amplitude = 99, .seek_weight = 0.1 });
    try data.setAiAgent(first, .{ .behavior = .seek, .wander_amplitude = 7, .seek_weight = 0.3 });

    const first_agent = data.aiAgentConst(first).?;
    try std.testing.expectEqual(AiBehavior.seek, first_agent.behavior);
    try std.testing.expectEqual(@as(f32, 7), first_agent.wander_amplitude);
    try std.testing.expectEqual(@as(f32, 0.3), first_agent.seek_weight);
    try std.testing.expectError(error.InvalidAiAgent, data.setAiAgent(first, .{ .wander_amplitude = -0.1 }));
    try std.testing.expectError(error.InvalidAiAgent, data.setAiAgent(first, .{ .seek_weight = std.math.inf(f32) }));
    try std.testing.expectError(error.InvalidAiAgent, data.setAiAgent(first, .{ .wander_amplitude = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidAiAgent, data.setAiAgent(first, .{ .wander_amplitude = std.math.floatMax(f32) }));
    try std.testing.expectError(error.InvalidAiAgent, data.setAiAgent(first, .{ .seek_weight = max_ai_seek_weight + 1.0 }));

    try std.testing.expect(data.destroyEntity(second));
    const slice = data.aiAgentSliceConst();
    try expectAiAgentColumnsAligned(slice);
    try std.testing.expectEqual(@as(usize, 2), slice.entities.len);
    try std.testing.expect(data.aiAgentConst(first) != null);
    try std.testing.expect(data.aiAgentConst(third) != null);
    try std.testing.expect(data.aiAgentConst(second) == null);
}

test "steering agent component stores dense columns, supports set/get, rejects invalid, compacts on destroy" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    const second = try data.createEntity();
    const third = try data.createEntity();
    try data.setSteeringAgent(first, testSteeringAgent(1));
    try data.setSteeringAgent(second, testSteeringAgent(2));
    try data.setSteeringAgent(third, testSteeringAgent(3));
    try data.setSteeringAgent(first, .{
        .agent_radius = 9,
        .waypoint_tolerance = 3,
        .avoidance_radius = 42,
        .avoidance_weight = 2.5,
        .max_neighbor_samples = 7,
        .stuck_step_threshold = 5,
        .replan_cooldown_steps = 11,
        .unavailable_backoff_steps = 23,
    });

    const first_agent = data.steeringAgentConst(first).?;
    try std.testing.expectEqual(@as(f32, 9), first_agent.agent_radius);
    try std.testing.expectEqual(@as(f32, 3), first_agent.waypoint_tolerance);
    try std.testing.expectEqual(@as(f32, 42), first_agent.avoidance_radius);
    try std.testing.expectEqual(@as(f32, 2.5), first_agent.avoidance_weight);
    try std.testing.expectEqual(@as(u16, 7), first_agent.max_neighbor_samples);
    try std.testing.expectEqual(@as(u16, 5), first_agent.stuck_step_threshold);
    try std.testing.expectEqual(@as(u16, 11), first_agent.replan_cooldown_steps);
    try std.testing.expectEqual(@as(u16, 23), first_agent.unavailable_backoff_steps);
    try std.testing.expectError(error.InvalidSteeringAgent, data.setSteeringAgent(first, .{ .agent_radius = 0 }));
    try std.testing.expectError(error.InvalidSteeringAgent, data.setSteeringAgent(first, .{ .avoidance_weight = -0.1 }));
    try std.testing.expectError(error.InvalidSteeringAgent, data.setSteeringAgent(first, .{ .waypoint_tolerance = std.math.inf(f32) }));
    try std.testing.expectError(error.InvalidSteeringAgent, data.setSteeringAgent(first, .{ .avoidance_radius = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidSteeringAgent, data.setSteeringAgent(first, .{ .max_neighbor_samples = max_steering_neighbor_samples + 1 }));

    try std.testing.expect(data.destroyEntity(second));
    const slice = data.steeringAgentSliceConst();
    try expectSteeringAgentColumnsAligned(slice);
    try std.testing.expectEqual(@as(usize, 2), slice.entities.len);
    try std.testing.expect(data.steeringAgentConst(first) != null);
    try std.testing.expect(data.steeringAgentConst(third) != null);
    try std.testing.expect(data.steeringAgentConst(second) == null);
    try std.testing.expect(data.steeringAgentDenseIndex(first) != null);
    try std.testing.expect(data.steeringAgentDenseIndex(third) != null);
    try std.testing.expectEqual(@as(?usize, null), data.steeringAgentDenseIndex(second));
    try std.testing.expectEqual(first.index, slice.entities[data.steeringAgentDenseIndex(first).?].index);
    try std.testing.expectEqual(third.index, slice.entities[data.steeringAgentDenseIndex(third).?].index);
}

test "ai agent via EntityTemplate in structural create and mask queries" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const commands = [_]StructuralCommand{
        .{ .create_entity = .{
            .movement_body = testBody(1),
            .ai_agent = .{ .behavior = .wander, .wander_amplitude = 55, .seek_weight = 0 },
            .steering_agent = testSteeringAgent(1),
        } },
    };
    _ = try data.applyStructuralCommands(&commands);

    const entity = data.movementBodySliceConst().entities[0];
    try std.testing.expect(data.hasComponents(entity, component_masks.ai_agent | component_masks.steering_agent | component_masks.movement_body));
    try std.testing.expect(!data.hasComponents(entity, component_masks.collision_response));
    const agent = data.aiAgentConst(entity).?;
    try std.testing.expectEqual(AiBehavior.wander, agent.behavior);
    try std.testing.expectEqual(@as(f32, 55), agent.wander_amplitude);
    try std.testing.expectEqual(@as(f32, 13), data.steeringAgentConst(entity).?.agent_radius);
}

test "structural commands set stable asset references" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const commands = [_]StructuralCommand{
        .{ .create_entity = .{
            .movement_body = testBody(1),
            .asset_reference = .{ .sprite = .demo_tile },
        } },
    };

    _ = try data.applyStructuralCommands(&commands);
    const entity = data.assetReferenceSliceConst().entities[0];
    try std.testing.expectEqual(SpriteAssetId.demo_tile, data.assetReferenceConst(entity).?.sprite);
}

test "structural commands prevalidate fallible data before mutating" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const existing = try data.createEntity();
    try data.setMovementBody(existing, testBody(1));

    const commands = [_]StructuralCommand{
        .{ .set_movement_body = .{ .entity = existing, .body = testBody(99) } },
        .{ .create_entity = .{
            .movement_body = testBody(2),
            .collision_bounds = .{ .size = .{ .x = 0, .y = 12 } },
        } },
    };

    try std.testing.expectError(error.InvalidCollisionBounds, data.applyStructuralCommands(&commands));
    try std.testing.expectEqual(@as(f32, 1), data.movementBodyConst(existing).?.position.x);
    try std.testing.expectEqual(@as(usize, 1), data.movementBodySliceConst().entities.len);
}

test "structural commands prevalidate ai agents before mutating" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const existing = try data.createEntity();
    try data.setMovementBody(existing, testBody(1));

    const commands = [_]StructuralCommand{
        .{ .set_movement_body = .{ .entity = existing, .body = testBody(99) } },
        .{ .create_entity = .{
            .movement_body = testBody(2),
            .ai_agent = .{ .behavior = .wander, .wander_amplitude = std.math.floatMax(f32), .seek_weight = 0 },
        } },
    };

    try std.testing.expectError(error.InvalidAiAgent, data.applyStructuralCommands(&commands));
    try std.testing.expectEqual(@as(f32, 1), data.movementBodyConst(existing).?.position.x);
    try std.testing.expectEqual(@as(usize, 1), data.movementBodySliceConst().entities.len);
}

test "structural commands prevalidate steering agents before mutating" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const existing = try data.createEntity();
    try data.setMovementBody(existing, testBody(1));

    const commands = [_]StructuralCommand{
        .{ .set_movement_body = .{ .entity = existing, .body = testBody(99) } },
        .{ .create_entity = .{
            .movement_body = testBody(2),
            .steering_agent = .{ .agent_radius = std.math.inf(f32) },
        } },
    };

    try std.testing.expectError(error.InvalidSteeringAgent, data.applyStructuralCommands(&commands));
    try std.testing.expectEqual(@as(f32, 1), data.movementBodyConst(existing).?.position.x);
    try std.testing.expectEqual(@as(usize, 1), data.movementBodySliceConst().entities.len);
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

fn testSteeringAgent(base: f32) SteeringAgent {
    return .{
        .agent_radius = base + 12,
        .waypoint_tolerance = base + 4,
        .avoidance_radius = base + 48,
        .avoidance_weight = base + 1,
        .max_neighbor_samples = @intFromFloat(base + 8),
        .stuck_step_threshold = @intFromFloat(base + 12),
        .replan_cooldown_steps = @intFromFloat(base + 16),
        .unavailable_backoff_steps = @intFromFloat(base + 32),
    };
}

fn testBounds(base: f32) CollisionBounds {
    return .{
        .offset = .{ .x = base, .y = base + 1 },
        .size = .{ .x = base, .y = base + 2 },
    };
}

fn testResponse(mode: CollisionResponseMode, mobility: CollisionResponseMobility, restitution: f32) CollisionResponse {
    return .{
        .mode = mode,
        .mobility = mobility,
        .restitution = restitution,
    };
}
