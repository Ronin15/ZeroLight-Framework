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
const render_depth = @import("render_depth.zig");
const ChunkCoord = @import("simulation_scope.zig").ChunkCoord;
const EntitySimulationMetadata = @import("simulation_scope.zig").EntitySimulationMetadata;
const SimulationScopeStats = @import("simulation_scope.zig").SimulationScopeStats;
const SimulationTier = @import("simulation_scope.zig").SimulationTier;
const cognition_stagger_n = @import("simulation_scope.zig").cognition_stagger_n;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const simd = @import("../core/simd.zig");
const WorldDepth = render_depth.WorldDepth;

pub const hot_soa_column_alignment: usize = 64;
pub const movement_range_alignment_items: usize = hot_soa_column_alignment / @sizeOf(f32);

pub const HotF32Slice = []align(hot_soa_column_alignment) f32;
pub const ConstHotF32Slice = []align(hot_soa_column_alignment) const f32;
pub const HotI32Slice = []align(hot_soa_column_alignment) i32;
pub const ConstHotI32Slice = []align(hot_soa_column_alignment) const i32;

const HotF32List = std.ArrayListAligned(f32, .fromByteUnits(hot_soa_column_alignment));
const HotI32List = std.ArrayListAligned(i32, .fromByteUnits(hot_soa_column_alignment));

/// Stable entity handle. The index points at an entity slot and the generation
/// changes whenever that slot is retired, so stale IDs cannot resolve after
/// free-list reuse.
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
    position_z: i32 = 0,
    previous_z: i32 = 0,
    velocity: math.Vec2 = .{},
    speed: f32 = 0,
};

pub const MovementBodyPtr = struct {
    position_x: *f32,
    position_y: *f32,
    position_z: *i32,
    previous_x: *f32,
    previous_y: *f32,
    previous_z: *i32,
    velocity_x: *f32,
    velocity_y: *f32,
    speed: *f32,
};

/// Mutable dense movement columns. Entity order matches every movement column
/// so processors can use one row index for positions, velocities, and identity.
pub const MovementBodySlice = struct {
    entities: []const EntityId,
    position_x: HotF32Slice,
    position_y: HotF32Slice,
    position_z: HotI32Slice,
    previous_x: HotF32Slice,
    previous_y: HotF32Slice,
    previous_z: HotI32Slice,
    velocity_x: HotF32Slice,
    velocity_y: HotF32Slice,
    speed: HotF32Slice,
};

pub const ConstMovementBodySlice = struct {
    entities: []const EntityId,
    position_x: ConstHotF32Slice,
    position_y: ConstHotF32Slice,
    position_z: ConstHotI32Slice,
    previous_x: ConstHotF32Slice,
    previous_y: ConstHotF32Slice,
    previous_z: ConstHotI32Slice,
    velocity_x: ConstHotF32Slice,
    velocity_y: ConstHotF32Slice,
    speed: ConstHotF32Slice,
};

/// Dense simulation-scope columns in lockstep with the movement store rows
/// (index here == movement dense index). The scope system writes chunk_x/y here
/// during its recompute and reads the columns for the movement gather and tier
/// policy as aligned SoA. Mutable view exposes only chunk_x/y as writable — the
/// per-step recompute writes those. tier/stagger_phase/always_active are const
/// here; they change only through setSimulationTier/setSimulationMetadata, which
/// keep tier_counts in sync, so a stray write through this view can't desync them.
pub const ScopeColumnsSlice = struct {
    entities: []const EntityId,
    tier: []const SimulationTier,
    chunk_x: HotI32Slice,
    chunk_y: HotI32Slice,
    /// Entity depth/level for the cube LOD distance. Const in the mutable view: set
    /// via setSimulationMetadata, never by the per-step chunk recompute.
    level: []const u16,
    stagger_phase: []const u8,
    always_active: []const bool,
};

pub const ConstScopeColumnsSlice = struct {
    entities: []const EntityId,
    tier: []const SimulationTier,
    chunk_x: ConstHotI32Slice,
    chunk_y: ConstHotI32Slice,
    level: []const u16,
    stagger_phase: []const u8,
    always_active: []const bool,
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

/// Data-only primitive visual component. Render order and colors live here, but
/// prepared draw records and renderer handles stay outside DataSystem.
pub const PrimitiveVisual = struct {
    size: math.Vec2,
    color: config.Color,
    depth: WorldDepth = .actor,
    marker_color: config.Color,
    marker_depth_band: WorldDepth = .marker,
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
    depth_values: []const i32,
    marker_color_r: []const f32,
    marker_color_g: []const f32,
    marker_color_b: []const f32,
    marker_color_a: []const f32,
    marker_depth_values: []const i32,
    marker_lengths: []const f32,
    marker_depths: []const f32,
    marker_margins: []const f32,
};

pub const AssetReference = struct {
    pub const no_atlas_entry: u16 = std.math.maxInt(u16);

    sprite: SpriteAssetId,
    atlas_entry_id: u16 = no_atlas_entry,

    pub fn hasAtlasEntry(self: AssetReference) bool {
        return self.atlas_entry_id != no_atlas_entry;
    }
};

pub const ConstAssetReferenceSlice = struct {
    entities: []const EntityId,
    sprite_ids: []const SpriteAssetId,
    atlas_entry_ids: []const u16,
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

/// Component bundle consumed by create_entity during structural commits. Each
/// optional payload still goes through normal validation and change reporting.
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

pub const SimulationTierCommand = struct {
    entity: EntityId,
    tier: SimulationTier,
};

/// Deferred structural work committed after processors finish. Commands carry
/// stable entity IDs and component values only, never borrowed slices or service
/// references from the frame that produced them.
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
    set_simulation_tier: SimulationTierCommand,
};

pub const StructuralCommitStats = struct {
    created: usize = 0,
    destroyed: usize = 0,
    components_set: usize = 0,
    stale_skipped: usize = 0,
};

pub const StructuralEntityDestroyedChange = struct {
    entity: EntityId,
    component_mask: ComponentMask,
    was_static_navigation_obstacle: bool,
};

pub const StructuralComponentChangedChange = struct {
    entity: EntityId,
    component: Component,
    was_static_navigation_obstacle: bool,
    is_static_navigation_obstacle: bool,
};

pub const StructuralChange = union(enum) {
    entity_created: EntityId,
    entity_destroyed: StructuralEntityDestroyedChange,
    component_changed: StructuralComponentChangedChange,
};

const NullStructuralChangeSink = struct {
    fn record(_: *NullStructuralChangeSink, _: StructuralChange) void {}
};

const NullStructuralCommitPreparer = struct {
    fn prepare(_: *NullStructuralCommitPreparer, _: usize) !void {}
};

const StructuralCapacityNeeds = struct {
    // Preflight reserves every storage target before the commit loop. That
    // keeps structural commits all-or-fail before DataSystem mutates.
    slots: usize,
    movement_bodies: usize,
    facings: usize,
    primitive_visuals: usize,
    asset_refs: usize,
    collision_bounds: usize,
    collision_responses: usize,
    ai_agents: usize,
    steering_agents: usize,

    fn init(data: *const DataSystem) StructuralCapacityNeeds {
        return .{
            .slots = data.slots.items.len,
            .movement_bodies = data.movement_bodies.entities.items.len,
            .facings = data.facings.entities.items.len,
            .primitive_visuals = data.primitive_visuals.entities.items.len,
            .asset_refs = data.asset_refs.entities.items.len,
            .collision_bounds = data.collision_bounds.entities.items.len,
            .collision_responses = data.collision_responses.entities.items.len,
            .ai_agents = data.ai_agents.entities.items.len,
            .steering_agents = data.steering_agents.entities.items.len,
        };
    }

    fn validateLimits(self: StructuralCapacityNeeds) !void {
        if (self.slots > std.math.maxInt(u32)) return error.TooManyEntities;
        if (self.movement_bodies > std.math.maxInt(u32)) return error.TooManyMovementBodyRows;
        if (self.facings > std.math.maxInt(u32)) return error.TooManyFacingRows;
        if (self.primitive_visuals > std.math.maxInt(u32)) return error.TooManyPrimitiveVisualRows;
        if (self.asset_refs > std.math.maxInt(u32)) return error.TooManyAssetReferenceRows;
        if (self.collision_bounds > std.math.maxInt(u32)) return error.TooManyCollisionBoundsRows;
        if (self.collision_responses > std.math.maxInt(u32)) return error.TooManyCollisionResponseRows;
        if (self.ai_agents > std.math.maxInt(u32)) return error.TooManyAiAgentRows;
        if (self.steering_agents > std.math.maxInt(u32)) return error.TooManySteeringAgentRows;
    }
};

const StructuralCapacityProjection = struct {
    // Projection follows command-order creates, destroys, and first-time
    // component additions without touching real slots or dense component stores.
    current: StructuralCapacityNeeds,
    required: StructuralCapacityNeeds,
    free_slots: usize,

    fn init(data: *const DataSystem) StructuralCapacityProjection {
        const current = StructuralCapacityNeeds.init(data);
        return .{
            .current = current,
            .required = current,
            .free_slots = data.free_slot_count,
        };
    }

    fn createSlot(self: *StructuralCapacityProjection) !void {
        if (self.free_slots > 0) {
            self.free_slots -= 1;
            return;
        }
        self.current.slots = try addCapacity(self.current.slots, 1);
        self.required.slots = @max(self.required.slots, self.current.slots);
    }

    fn destroySlot(self: *StructuralCapacityProjection) !void {
        self.free_slots = try addCapacity(self.free_slots, 1);
    }

    fn addTemplate(self: *StructuralCapacityProjection, template: EntityTemplate) !void {
        if (template.movement_body != null) try self.addComponent(.movement_body);
        if (template.facing != null) try self.addComponent(.facing);
        if (template.primitive_visual != null) try self.addComponent(.primitive_visual);
        if (template.asset_reference != null) try self.addComponent(.asset_reference);
        if (template.collision_bounds != null) try self.addComponent(.collision_bounds);
        if (template.collision_response != null) try self.addComponent(.collision_response);
        if (template.ai_agent != null) try self.addComponent(.ai_agent);
        if (template.steering_agent != null) try self.addComponent(.steering_agent);
    }

    fn addComponent(self: *StructuralCapacityProjection, component: Component) !void {
        const current = self.currentField(component);
        const required = self.requiredField(component);
        current.* = try addCapacity(current.*, 1);
        required.* = @max(required.*, current.*);
    }

    fn removeComponent(self: *StructuralCapacityProjection, component: Component) void {
        const current = self.currentField(component);
        std.debug.assert(current.* > 0);
        current.* -= 1;
    }

    fn currentField(self: *StructuralCapacityProjection, component: Component) *usize {
        return switch (component) {
            .movement_body => &self.current.movement_bodies,
            .facing => &self.current.facings,
            .primitive_visual => &self.current.primitive_visuals,
            .asset_reference => &self.current.asset_refs,
            .collision_bounds => &self.current.collision_bounds,
            .collision_response => &self.current.collision_responses,
            .ai_agent => &self.current.ai_agents,
            .steering_agent => &self.current.steering_agents,
        };
    }

    fn requiredField(self: *StructuralCapacityProjection, component: Component) *usize {
        return switch (component) {
            .movement_body => &self.required.movement_bodies,
            .facing => &self.required.facings,
            .primitive_visual => &self.required.primitive_visuals,
            .asset_reference => &self.required.asset_refs,
            .collision_bounds => &self.required.collision_bounds,
            .collision_response => &self.required.collision_responses,
            .ai_agent => &self.required.ai_agents,
            .steering_agent => &self.required.steering_agents,
        };
    }
};

fn addCapacity(value: usize, amount: usize) !usize {
    return std.math.add(usize, value, amount);
}

const StructuralCommitPlan = struct {
    // `structural_event_count` lets callers reserve their change sink before
    // mutation so event publishing cannot fail halfway through commit.
    command_count: usize,
    capacity_needs: StructuralCapacityNeeds,
    structural_event_count: usize,
};

const ProjectedEntityState = struct {
    // Scratch copy of just the liveness and component membership needed for
    // preflight. Dense row indices are irrelevant until the real commit pass.
    alive: bool,
    component_mask: ComponentMask,

    fn init(data: *const DataSystem, entity: EntityId) ProjectedEntityState {
        const slot = data.resolveSlotConst(entity) orelse return .{
            .alive = false,
            .component_mask = 0,
        };
        return .{
            .alive = true,
            .component_mask = slot.component_mask,
        };
    }

    fn hasComponent(self: ProjectedEntityState, component: Component) bool {
        return (self.component_mask & componentMask(component)) != 0;
    }

    fn addComponent(self: *ProjectedEntityState, component: Component) void {
        self.component_mask |= componentMask(component);
    }

    fn destroy(self: *ProjectedEntityState) void {
        self.alive = false;
        self.component_mask = 0;
    }
};

/// Reusable scratch for prepared structural commits. Simulation pipelines keep
/// this around to avoid per-step hash-map allocation churn.
pub const StructuralPlanScratch = struct {
    allocator: std.mem.Allocator,
    projected_entities: std.AutoHashMapUnmanaged(u64, ProjectedEntityState) = .{},

    pub fn init(allocator: std.mem.Allocator) StructuralPlanScratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StructuralPlanScratch) void {
        self.projected_entities.deinit(self.allocator);
        self.projected_entities = .{};
    }

    pub fn clearRetainingCapacity(self: *StructuralPlanScratch) void {
        self.projected_entities.clearRetainingCapacity();
    }

    fn projectedState(
        self: *StructuralPlanScratch,
        data: *const DataSystem,
        entity: EntityId,
    ) !*ProjectedEntityState {
        const result = try self.projected_entities.getOrPut(self.allocator, structuralEntityKey(entity));
        if (!result.found_existing) {
            result.value_ptr.* = ProjectedEntityState.init(data, entity);
        }
        return result.value_ptr;
    }
};

fn structuralEntityKey(entity: EntityId) u64 {
    return (@as(u64, entity.index) << 32) | @as(u64, entity.generation);
}

fn removeProjectedComponents(component_mask: ComponentMask, projection: *StructuralCapacityProjection) void {
    inline for (std.meta.fields(Component)) |field| {
        const component: Component = @enumFromInt(field.value);
        if ((component_mask & componentMask(component)) != 0) {
            projection.removeComponent(component);
        }
    }
}

fn templateComponentCount(template: EntityTemplate) usize {
    var count: usize = 0;
    if (template.movement_body != null) count += 1;
    if (template.facing != null) count += 1;
    if (template.primitive_visual != null) count += 1;
    if (template.asset_reference != null) count += 1;
    if (template.collision_bounds != null) count += 1;
    if (template.collision_response != null) count += 1;
    if (template.ai_agent != null) count += 1;
    if (template.steering_agent != null) count += 1;
    return count;
}

/// Persistent gameplay data owner and ECS storage foundation. Entity slots are
/// stable handles, while component stores are dense SoA columns referenced from
/// live slots.
pub const DataSystem = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayList(EntitySlot) = .empty,
    first_free_slot: ?u32 = null,
    free_slot_count: usize = 0,
    // Live entity count per simulation tier, maintained incrementally on
    // create/destroy/metadata-change so the per-fixed-step scope stats are O(1)
    // instead of scanning every slot. Indexed by @intFromEnum(SimulationTier).
    tier_counts: [4]usize = .{ 0, 0, 0, 0 },
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
            std.debug.assert(self.free_slot_count > 0);
            self.free_slot_count -= 1;
            slot.alive = true;
            slot.next_free = null;
            // Scope metadata (tier/chunk/stagger) is born with the movement body
            // as a dense column row, not on the slot. tier_counts is maintained at
            // movement-body add/remove.
            // Reused slots keep their incremented generation so stale IDs cannot
            // address the new entity.
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

        // Component stores stay dense. Removing an entity may swap the tail row
        // into this entity's dense index and patch that moved entity's slot.
        if (slot.movement_body_index) |dense_index| self.removeMovementBodyAt(@intCast(dense_index));
        if (slot.facing_index) |dense_index| self.removeFacingAt(@intCast(dense_index));
        if (slot.primitive_visual_index) |dense_index| self.removePrimitiveVisualAt(@intCast(dense_index));
        if (slot.asset_ref_index) |dense_index| self.removeAssetReferenceAt(@intCast(dense_index));
        if (slot.collision_bounds_index) |dense_index| self.removeCollisionBoundsAt(@intCast(dense_index));
        if (slot.collision_response_index) |dense_index| self.removeCollisionResponseAt(@intCast(dense_index));
        if (slot.ai_agent_index) |dense_index| self.removeAiAgentAt(@intCast(dense_index));
        if (slot.steering_agent_index) |dense_index| self.removeSteeringAgentAt(@intCast(dense_index));

        // tier_counts is decremented in removeMovementBodyAt (called above) since
        // the tier now lives on the dense movement-body scope row, not the slot.
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
        self.free_slot_count += 1;
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

    /// Returns simulation-scope metadata for a live entity, read from its dense
    /// movement-body scope row. Entities without a movement body (and stale/dead/
    /// invalid IDs) return null — scope metadata exists only for simulated entities.
    pub fn simulationMetadata(self: *const DataSystem, id: EntityId) ?EntitySimulationMetadata {
        const slot = self.resolveSlotConst(id) orelse return null;
        const di: usize = slot.movement_body_index orelse return null;
        return .{
            .tier = self.movement_bodies.tier.items[di],
            .chunk = .{ .x = self.movement_bodies.chunk_x.items[di], .y = self.movement_bodies.chunk_y.items[di] },
            .level = self.movement_bodies.level.items[di],
            .stagger_phase = self.movement_bodies.stagger_phase.items[di],
            .always_active = self.movement_bodies.always_active.items[di],
        };
    }

    /// Writes the full scope metadata for an entity into its dense scope row.
    /// Requires a movement body; returns error.InvalidEntity otherwise.
    pub fn setSimulationMetadata(self: *DataSystem, id: EntityId, metadata: EntitySimulationMetadata) !void {
        try metadata.validate();
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        const di: usize = slot.movement_body_index orelse return error.InvalidEntity;
        self.tier_counts[@intFromEnum(self.movement_bodies.tier.items[di])] -= 1;
        self.tier_counts[@intFromEnum(metadata.tier)] += 1;
        self.movement_bodies.tier.items[di] = metadata.tier;
        self.movement_bodies.chunk_x.items[di] = metadata.chunk.x;
        self.movement_bodies.chunk_y.items[di] = metadata.chunk.y;
        self.movement_bodies.level.items[di] = metadata.level;
        self.movement_bodies.stagger_phase.items[di] = metadata.stagger_phase;
        self.movement_bodies.always_active.items[di] = metadata.always_active;
        self.snapInterpolationIfStill(di, metadata.tier);
    }

    /// Stores the pre-computed chunk coordinate into the entity's dense scope row.
    /// No-op for entities without a movement body. The scope system normally writes
    /// chunk columns in bulk via scopeColumnsSlice(); this is the per-entity path.
    pub fn setEntityChunk(self: *DataSystem, id: EntityId, chunk: ChunkCoord) void {
        const slot = self.resolveSlot(id) orelse return;
        const di: usize = slot.movement_body_index orelse return;
        self.movement_bodies.chunk_x.items[di] = chunk.x;
        self.movement_bodies.chunk_y.items[di] = chunk.y;
    }

    /// Changes an entity's simulation tier while preserving chunk, stagger_phase,
    /// and always_active. Processors must not call this inside worker ranges; use
    /// a .set_simulation_tier structural command for deferred tier changes.
    pub fn setSimulationTier(self: *DataSystem, id: EntityId, tier: SimulationTier) !void {
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        const di: usize = slot.movement_body_index orelse return error.InvalidEntity;
        self.tier_counts[@intFromEnum(self.movement_bodies.tier.items[di])] -= 1;
        self.tier_counts[@intFromEnum(tier)] += 1;
        self.movement_bodies.tier.items[di] = tier;
        // chunk, stagger_phase, and always_active are intentionally preserved.
        self.snapInterpolationIfStill(di, tier);
    }

    /// When an entity enters a non-moving tier, movement stops updating its
    /// previous position while its position stays frozen — render interpolation
    /// (lerp previous→position) would otherwise oscillate. Snap previous=position
    /// so the row renders static until it moves again.
    fn snapInterpolationIfStill(self: *DataSystem, di: usize, tier: SimulationTier) void {
        if (tier.allowsMovement()) return;
        self.movement_bodies.previous_x.items[di] = self.movement_bodies.position_x.items[di];
        self.movement_bodies.previous_y.items[di] = self.movement_bodies.position_y.items[di];
        self.movement_bodies.previous_z.items[di] = self.movement_bodies.position_z.items[di];
    }

    /// Mutable dense scope columns (chunk_x/y written by the recompute pass).
    pub fn scopeColumnsSlice(self: *DataSystem) ScopeColumnsSlice {
        return self.movement_bodies.scopeSlice();
    }

    /// Const dense scope columns for the movement gather and tier policy scans.
    pub fn scopeColumnsSliceConst(self: *const DataSystem) ConstScopeColumnsSlice {
        return self.movement_bodies.scopeSliceConst();
    }

    /// Live count of entities at a given tier (O(1), incrementally maintained).
    /// The scope system uses this for fast-path gather decisions: when no entity
    /// is below a stage's required tier, the stage runs full-active with no scan.
    pub fn tierCount(self: *const DataSystem, tier: SimulationTier) usize {
        return self.tier_counts[@intFromEnum(tier)];
    }

    /// Current full-active scope counters. Tier histograms come from the
    /// incrementally-maintained `tier_counts` (O(1), no per-step slot scan); stage
    /// counts come free from dense slice lengths. `scanLiveTierCounts` is the
    /// parity baseline the counters must match. `total_entities` is the count of
    /// entities carrying a simulation tier (i.e. those with a movement body), not
    /// the full live-entity set.
    pub fn simulationScopeStatsFullActive(self: *const DataSystem) SimulationScopeStats {
        return .{
            .total_entities = self.tier_counts[0] + self.tier_counts[1] + self.tier_counts[2] + self.tier_counts[3],
            .dormant_entities = self.tier_counts[@intFromEnum(SimulationTier.dormant)],
            .kinematic_entities = self.tier_counts[@intFromEnum(SimulationTier.kinematic)],
            .locomotion_entities = self.tier_counts[@intFromEnum(SimulationTier.locomotion)],
            .cognition_entities = self.tier_counts[@intFromEnum(SimulationTier.cognition)],
            .movement_stage_entities = self.movement_bodies.entities.items.len,
            .collision_stage_entities = self.collision_bounds.entities.items.len,
            .collision_response_stage_entities = self.collision_responses.entities.items.len,
            .ai_stage_entities = self.ai_agents.entities.items.len,
            .steering_stage_entities = self.steering_agents.entities.items.len,
        };
    }

    /// O(rows) scan of the dense scope tier column — the parity baseline for the
    /// incrementally maintained `tier_counts`. Test/debug only; not on the hot path.
    /// Counts entities with a movement body (the entities that carry a tier).
    pub fn scanLiveTierCounts(self: *const DataSystem) [4]usize {
        var counts = [4]usize{ 0, 0, 0, 0 };
        for (self.movement_bodies.tier.items) |tier| {
            counts[@intFromEnum(tier)] += 1;
        }
        return counts;
    }

    pub fn isStaticNavigationObstacle(self: *const DataSystem, id: EntityId) bool {
        const obstacle_mask = component_masks.movement_body | component_masks.collision_bounds | component_masks.collision_response;
        if (!self.hasComponents(id, obstacle_mask)) return false;
        const response = self.collisionResponseConst(id) orelse return false;
        return response.mobility == .static;
    }

    pub fn clearRetainingCapacity(self: *DataSystem) void {
        // Reset invalidates all existing IDs while keeping allocated component
        // columns warm for the next state/session.
        self.steering_agents.clearRetainingCapacity();
        self.ai_agents.clearRetainingCapacity();
        self.asset_refs.clearRetainingCapacity();
        self.collision_bounds.clearRetainingCapacity();
        self.collision_responses.clearRetainingCapacity();
        self.primitive_visuals.clearRetainingCapacity();
        self.facings.clearRetainingCapacity();
        self.movement_bodies.clearRetainingCapacity();

        self.first_free_slot = null;
        self.free_slot_count = self.slots.items.len;
        self.tier_counts = .{ 0, 0, 0, 0 };
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
        try validateMovementBody(body);
        // Public set* calls are upserts: existing component rows are overwritten,
        // while missing rows are appended and registered in the entity slot.
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        if (slot.movement_body_index) |index| {
            self.movement_bodies.set(@intCast(index), body);
            return;
        }

        const dense_index = try self.movement_bodies.append(self.allocator, id, body);
        slot.movement_body_index = dense_index;
        slot.addComponent(.movement_body);
        // The new scope row defaults to .cognition (see MovementBodyStore.append).
        self.tier_counts[@intFromEnum(SimulationTier.cognition)] += 1;
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
        try validatePrimitiveVisual(visual);
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

    pub fn primitiveVisualDenseIndex(self: *const DataSystem, id: EntityId) ?usize {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.primitive_visual_index orelse return null;
        return @intCast(dense_index);
    }

    pub fn setAssetReference(self: *DataSystem, id: EntityId, asset_ref: AssetReference) !void {
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;

        if (slot.asset_ref_index) |index| {
            self.asset_refs.sprite_ids.items[@intCast(index)] = asset_ref.sprite;
            self.asset_refs.atlas_entry_ids.items[@intCast(index)] = asset_ref.atlas_entry_id;
            return;
        }

        const dense_index = try self.asset_refs.append(self.allocator, id, asset_ref);
        slot.asset_ref_index = dense_index;
        slot.addComponent(.asset_reference);
    }

    pub fn assetReferenceConst(self: *const DataSystem, id: EntityId) ?AssetReference {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.asset_ref_index orelse return null;
        const index: usize = @intCast(dense_index);
        return .{
            .sprite = self.asset_refs.sprite_ids.items[index],
            .atlas_entry_id = self.asset_refs.atlas_entry_ids.items[index],
        };
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
        var sink = NullStructuralChangeSink{};
        return try self.applyStructuralCommandsWithChangeSink(commands, &sink);
    }

    pub fn applyStructuralCommandsWithChangeSink(self: *DataSystem, commands: []const StructuralCommand, change_sink: anytype) !StructuralCommitStats {
        var scratch = StructuralPlanScratch.init(self.allocator);
        defer scratch.deinit();
        var preparer = NullStructuralCommitPreparer{};
        return try self.applyStructuralCommandsPrepared(commands, &scratch, &preparer, change_sink);
    }

    pub fn applyStructuralCommandsPrepared(
        self: *DataSystem,
        commands: []const StructuralCommand,
        scratch: *StructuralPlanScratch,
        preparer: anytype,
        change_sink: anytype,
    ) !StructuralCommitStats {
        // Prepared commits split allocation/preparation from mutation so callers
        // can reuse scratch and reserve their own event buffers ahead of time.
        const plan = try self.preflightStructuralCommands(commands, scratch);
        try preparer.prepare(plan.structural_event_count);
        // No allocations or event-capacity failures should occur after this
        // point; the commit loop can mutate DataSystem in command order.
        return try self.commitStructuralCommands(commands, change_sink);
    }

    fn commitStructuralCommands(
        self: *DataSystem,
        commands: []const StructuralCommand,
        change_sink: anytype,
    ) !StructuralCommitStats {
        // Commit preserves command order. Stale entity commands are skipped, but
        // valid commands still produce deterministic component-change events.
        var stats = StructuralCommitStats{};
        for (commands) |command| {
            switch (command) {
                .create_entity => |template| {
                    const entity = try self.createEntity();
                    errdefer _ = self.destroyEntity(entity);
                    stats.components_set += try self.applyTemplateComponents(entity, template);
                    stats.created += 1;
                    change_sink.record(.{ .entity_created = entity });
                    self.recordTemplateComponentChanges(change_sink, entity, template);
                },
                .destroy_entity => |entity| {
                    const component_mask = self.componentMaskFor(entity);
                    const was_static_navigation_obstacle = self.isStaticNavigationObstacle(entity);
                    if (self.destroyEntity(entity)) {
                        stats.destroyed += 1;
                        change_sink.record(.{ .entity_destroyed = .{
                            .entity = entity,
                            .component_mask = component_mask,
                            .was_static_navigation_obstacle = was_static_navigation_obstacle,
                        } });
                    } else {
                        stats.stale_skipped += 1;
                    }
                },
                .set_movement_body => |set| {
                    if (!self.isAlive(set.entity)) {
                        stats.stale_skipped += 1;
                        continue;
                    }
                    const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                    try self.setMovementBody(set.entity, set.body);
                    stats.components_set += 1;
                    self.recordComponentChange(change_sink, set.entity, .movement_body, was_static_navigation_obstacle);
                },
                .set_facing => |set| {
                    if (!self.isAlive(set.entity)) {
                        stats.stale_skipped += 1;
                        continue;
                    }
                    const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                    try self.setFacing(set.entity, set.facing);
                    stats.components_set += 1;
                    self.recordComponentChange(change_sink, set.entity, .facing, was_static_navigation_obstacle);
                },
                .set_primitive_visual => |set| {
                    if (!self.isAlive(set.entity)) {
                        stats.stale_skipped += 1;
                        continue;
                    }
                    const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                    try self.setPrimitiveVisual(set.entity, set.visual);
                    stats.components_set += 1;
                    self.recordComponentChange(change_sink, set.entity, .primitive_visual, was_static_navigation_obstacle);
                },
                .set_asset_reference => |set| {
                    if (!self.isAlive(set.entity)) {
                        stats.stale_skipped += 1;
                        continue;
                    }
                    const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                    try self.setAssetReference(set.entity, set.asset_reference);
                    stats.components_set += 1;
                    self.recordComponentChange(change_sink, set.entity, .asset_reference, was_static_navigation_obstacle);
                },
                .set_collision_bounds => |set| {
                    if (!self.isAlive(set.entity)) {
                        stats.stale_skipped += 1;
                        continue;
                    }
                    const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                    try self.setCollisionBounds(set.entity, set.bounds);
                    stats.components_set += 1;
                    self.recordComponentChange(change_sink, set.entity, .collision_bounds, was_static_navigation_obstacle);
                },
                .set_collision_response => |set| {
                    if (!self.isAlive(set.entity)) {
                        stats.stale_skipped += 1;
                        continue;
                    }
                    const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                    try self.setCollisionResponse(set.entity, set.response);
                    stats.components_set += 1;
                    self.recordComponentChange(change_sink, set.entity, .collision_response, was_static_navigation_obstacle);
                },
                .set_ai_agent => |set| {
                    if (!self.isAlive(set.entity)) {
                        stats.stale_skipped += 1;
                        continue;
                    }
                    const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                    try self.setAiAgent(set.entity, set.agent);
                    stats.components_set += 1;
                    self.recordComponentChange(change_sink, set.entity, .ai_agent, was_static_navigation_obstacle);
                },
                .set_steering_agent => |set| {
                    if (!self.isAlive(set.entity)) {
                        stats.stale_skipped += 1;
                        continue;
                    }
                    const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                    try self.setSteeringAgent(set.entity, set.agent);
                    stats.components_set += 1;
                    self.recordComponentChange(change_sink, set.entity, .steering_agent, was_static_navigation_obstacle);
                },
                .set_simulation_tier => |set| {
                    // Skip stale IDs and live entities without a movement body
                    // (tier exists only on simulated rows) — same upsert tolerance
                    // as the sibling set_* commands, so neither aborts the batch.
                    if (!self.isAlive(set.entity) or self.movementBodyDenseIndex(set.entity) == null) {
                        stats.stale_skipped += 1;
                        continue;
                    }
                    try self.setSimulationTier(set.entity, set.tier);
                    // Tier is cold slot metadata — no component mask change, no structural event.
                },
            }
        }
        return stats;
    }

    fn preflightStructuralCommands(
        self: *DataSystem,
        commands: []const StructuralCommand,
        scratch: *StructuralPlanScratch,
    ) !StructuralCommitPlan {
        try validateStructuralCommands(commands);
        scratch.clearRetainingCapacity();
        if (commands.len == 0) {
            return .{
                .command_count = 0,
                .capacity_needs = StructuralCapacityNeeds.init(self),
                .structural_event_count = 0,
            };
        }
        try scratch.projected_entities.ensureTotalCapacity(scratch.allocator, @intCast(commands.len));

        var projection = StructuralCapacityProjection.init(self);
        var structural_event_count: usize = 0;

        // Preflight simulates the command stream against projected liveness and
        // masks so capacity and event reservations match what commit will do.
        for (commands) |command| {
            switch (command) {
                .create_entity => |template| {
                    try projection.createSlot();
                    try projection.addTemplate(template);
                    structural_event_count = try addCapacity(structural_event_count, 1 + templateComponentCount(template));
                },
                .destroy_entity => |entity| {
                    const state = try scratch.projectedState(self, entity);
                    if (state.alive) {
                        structural_event_count = try addCapacity(structural_event_count, 1);
                        try projection.destroySlot();
                        removeProjectedComponents(state.component_mask, &projection);
                        state.destroy();
                    }
                },
                .set_movement_body => |set| try self.preflightSetComponent(set.entity, .movement_body, scratch, &projection, &structural_event_count),
                .set_facing => |set| try self.preflightSetComponent(set.entity, .facing, scratch, &projection, &structural_event_count),
                .set_primitive_visual => |set| try self.preflightSetComponent(set.entity, .primitive_visual, scratch, &projection, &structural_event_count),
                .set_asset_reference => |set| try self.preflightSetComponent(set.entity, .asset_reference, scratch, &projection, &structural_event_count),
                .set_collision_bounds => |set| try self.preflightSetComponent(set.entity, .collision_bounds, scratch, &projection, &structural_event_count),
                .set_collision_response => |set| try self.preflightSetComponent(set.entity, .collision_response, scratch, &projection, &structural_event_count),
                .set_ai_agent => |set| try self.preflightSetComponent(set.entity, .ai_agent, scratch, &projection, &structural_event_count),
                .set_steering_agent => |set| try self.preflightSetComponent(set.entity, .steering_agent, scratch, &projection, &structural_event_count),
                .set_simulation_tier => {},
            }
        }

        try projection.required.validateLimits();
        const plan = StructuralCommitPlan{
            .command_count = commands.len,
            .capacity_needs = projection.required,
            .structural_event_count = structural_event_count,
        };
        try self.reserveStructuralPlanCapacity(plan);
        return plan;
    }

    fn preflightSetComponent(
        self: *DataSystem,
        entity: EntityId,
        component: Component,
        scratch: *StructuralPlanScratch,
        projection: *StructuralCapacityProjection,
        structural_event_count: *usize,
    ) !void {
        const state = try scratch.projectedState(self, entity);
        if (!state.alive) return;
        structural_event_count.* = try addCapacity(structural_event_count.*, 1);
        if (!state.hasComponent(component)) {
            try projection.addComponent(component);
            state.addComponent(component);
        }
    }

    fn reserveStructuralPlanCapacity(self: *DataSystem, plan: StructuralCommitPlan) !void {
        try self.slots.ensureTotalCapacity(self.allocator, plan.capacity_needs.slots);
        try self.movement_bodies.ensureCapacity(self.allocator, plan.capacity_needs.movement_bodies);
        try self.facings.ensureCapacity(self.allocator, plan.capacity_needs.facings);
        try self.primitive_visuals.ensureCapacity(self.allocator, plan.capacity_needs.primitive_visuals);
        try self.asset_refs.ensureCapacity(self.allocator, plan.capacity_needs.asset_refs);
        try self.collision_bounds.ensureCapacity(self.allocator, plan.capacity_needs.collision_bounds);
        try self.collision_responses.ensureCapacity(self.allocator, plan.capacity_needs.collision_responses);
        try self.ai_agents.ensureCapacity(self.allocator, plan.capacity_needs.ai_agents);
        try self.steering_agents.ensureCapacity(self.allocator, plan.capacity_needs.steering_agents);
    }

    pub fn validateStructuralCommands(commands: []const StructuralCommand) !void {
        // Validate fallible payloads up front so the later command-order commit
        // does not partially mutate before rejecting bad component data.
        for (commands) |command| {
            switch (command) {
                .create_entity => |template| {
                    if (template.movement_body) |body| {
                        try validateMovementBody(body);
                    }
                    if (template.primitive_visual) |visual| {
                        try validatePrimitiveVisual(visual);
                    }
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
                .set_movement_body => |set| try validateMovementBody(set.body),
                .set_primitive_visual => |set| try validatePrimitiveVisual(set.visual),
                .set_collision_bounds => |set| try validateCollisionBounds(set.bounds),
                .set_collision_response => |set| try validateCollisionResponse(set.response),
                .set_ai_agent => |set| try validateAiAgent(set.agent),
                .set_steering_agent => |set| try validateSteeringAgent(set.agent),
                else => {},
            }
        }
    }

    fn recordTemplateComponentChanges(self: *const DataSystem, change_sink: anytype, entity: EntityId, template: EntityTemplate) void {
        // Navigation-obstacle notifications compare before/after state across
        // the component sequence because movement, bounds, and response together
        // define whether pathfinding needs a grid rebuild.
        var was_static_navigation_obstacle = false;
        if (template.movement_body != null) {
            self.recordComponentChange(change_sink, entity, .movement_body, was_static_navigation_obstacle);
            was_static_navigation_obstacle = self.isStaticNavigationObstacle(entity);
        }
        if (template.facing != null) self.recordComponentChange(change_sink, entity, .facing, was_static_navigation_obstacle);
        if (template.primitive_visual != null) self.recordComponentChange(change_sink, entity, .primitive_visual, was_static_navigation_obstacle);
        if (template.asset_reference != null) self.recordComponentChange(change_sink, entity, .asset_reference, was_static_navigation_obstacle);
        if (template.collision_bounds != null) {
            self.recordComponentChange(change_sink, entity, .collision_bounds, was_static_navigation_obstacle);
            was_static_navigation_obstacle = self.isStaticNavigationObstacle(entity);
        }
        if (template.collision_response != null) {
            self.recordComponentChange(change_sink, entity, .collision_response, was_static_navigation_obstacle);
            was_static_navigation_obstacle = self.isStaticNavigationObstacle(entity);
        }
        if (template.ai_agent != null) self.recordComponentChange(change_sink, entity, .ai_agent, was_static_navigation_obstacle);
        if (template.steering_agent != null) self.recordComponentChange(change_sink, entity, .steering_agent, was_static_navigation_obstacle);
    }

    fn recordComponentChange(self: *const DataSystem, change_sink: anytype, entity: EntityId, component: Component, was_static_navigation_obstacle: bool) void {
        change_sink.record(.{ .component_changed = .{
            .entity = entity,
            .component = component,
            .was_static_navigation_obstacle = was_static_navigation_obstacle,
            .is_static_navigation_obstacle = self.isStaticNavigationObstacle(entity),
        } });
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
        // Resolution checks both liveness and generation. Slot index alone is
        // never enough because free-list reuse is intentional.
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
        // The scope tier row leaves with the movement body, so drop its tier count
        // before the swap overwrites it. The moved tail row keeps its own tier.
        self.tier_counts[@intFromEnum(self.movement_bodies.tier.items[index])] -= 1;
        // Store removals swap the tail row into the removed row. If a row moved,
        // the moved entity's slot must be patched immediately.
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
        const moved = self.asset_refs.removeAt(index);
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
    // Per-entity slot metadata stays cold compared with component columns. Hot
    // systems query masks once, then iterate dense component slices directly.
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

fn validateMovementBody(body: MovementBody) !void {
    if (!std.math.isFinite(body.position.x) or !std.math.isFinite(body.position.y)) return error.InvalidMovementBody;
    if (!std.math.isFinite(body.previous_position.x) or !std.math.isFinite(body.previous_position.y)) return error.InvalidMovementBody;
    if (!std.math.isFinite(body.velocity.x) or !std.math.isFinite(body.velocity.y)) return error.InvalidMovementBody;
    if (!std.math.isFinite(body.speed) or body.speed < 0) return error.InvalidMovementBody;
}

fn validatePrimitiveVisual(visual: PrimitiveVisual) !void {
    if (!std.math.isFinite(visual.size.x) or !std.math.isFinite(visual.size.y)) return error.InvalidPrimitiveVisual;
    if (visual.size.x <= 0 or visual.size.y <= 0) return error.InvalidPrimitiveVisual;
    try validatePrimitiveColor(visual.color);
    try validatePrimitiveColor(visual.marker_color);
    if (!std.math.isFinite(visual.marker_length) or visual.marker_length < 0) return error.InvalidPrimitiveVisual;
    if (!std.math.isFinite(visual.marker_depth) or visual.marker_depth < 0) return error.InvalidPrimitiveVisual;
    if (!std.math.isFinite(visual.marker_margin) or visual.marker_margin < 0) return error.InvalidPrimitiveVisual;
}

fn validatePrimitiveColor(color: config.Color) !void {
    if (!std.math.isFinite(color.r) or !std.math.isFinite(color.g) or
        !std.math.isFinite(color.b) or !std.math.isFinite(color.a))
    {
        return error.InvalidPrimitiveVisual;
    }
}

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
    // Movement is the hottest component, so scalar fields are separate aligned
    // columns for SIMD loads and cache-line-aware range splitting.
    entities: std.ArrayList(EntityId) = .empty,
    position_x: HotF32List = .empty,
    position_y: HotF32List = .empty,
    position_z: HotI32List = .empty,
    previous_x: HotF32List = .empty,
    previous_y: HotF32List = .empty,
    previous_z: HotI32List = .empty,
    velocity_x: HotF32List = .empty,
    velocity_y: HotF32List = .empty,
    speed: HotF32List = .empty,
    // Simulation-scope columns ride in dense lockstep with the movement rows so
    // the scope system's O(N) recompute, movement gather, and tier policy iterate
    // aligned SoA instead of scattered cold slots. The movement processor's slice
    // omits these, so movement integration never touches their cache lines. Scope
    // metadata therefore exists exactly for entities with a movement body.
    tier: std.ArrayList(SimulationTier) = .empty,
    chunk_x: HotI32List = .empty,
    chunk_y: HotI32List = .empty,
    level: std.ArrayList(u16) = .empty,
    stagger_phase: std.ArrayList(u8) = .empty,
    always_active: std.ArrayList(bool) = .empty,

    fn append(self: *MovementBodyStore, allocator: std.mem.Allocator, entity: EntityId, body: MovementBody) !u32 {
        if (self.entities.items.len >= std.math.maxInt(u32)) return error.TooManyMovementBodyRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.entities.items.len);
        self.entities.appendAssumeCapacity(entity);
        self.position_x.appendAssumeCapacity(body.position.x);
        self.position_y.appendAssumeCapacity(body.position.y);
        self.position_z.appendAssumeCapacity(body.position_z);
        self.previous_x.appendAssumeCapacity(body.previous_position.x);
        self.previous_y.appendAssumeCapacity(body.previous_position.y);
        self.previous_z.appendAssumeCapacity(body.previous_z);
        self.velocity_x.appendAssumeCapacity(body.velocity.x);
        self.velocity_y.appendAssumeCapacity(body.velocity.y);
        self.speed.appendAssumeCapacity(body.speed);
        // New scope row defaults: full cognition, chunk recomputed next step, and a
        // stagger phase derived from the dense index so phases spread evenly.
        self.tier.appendAssumeCapacity(.cognition);
        self.chunk_x.appendAssumeCapacity(0);
        self.chunk_y.appendAssumeCapacity(0);
        self.level.appendAssumeCapacity(0);
        self.stagger_phase.appendAssumeCapacity(@intCast(index % cognition_stagger_n));
        self.always_active.appendAssumeCapacity(false);
        return index;
    }

    fn set(self: *MovementBodyStore, index: usize, body: MovementBody) void {
        self.position_x.items[index] = body.position.x;
        self.position_y.items[index] = body.position.y;
        self.position_z.items[index] = body.position_z;
        self.previous_x.items[index] = body.previous_position.x;
        self.previous_y.items[index] = body.previous_position.y;
        self.previous_z.items[index] = body.previous_z;
        self.velocity_x.items[index] = body.velocity.x;
        self.velocity_y.items[index] = body.velocity.y;
        self.speed.items[index] = body.speed;
    }

    fn get(self: *const MovementBodyStore, index: usize) MovementBody {
        return .{
            .position = .{ .x = self.position_x.items[index], .y = self.position_y.items[index] },
            .previous_position = .{ .x = self.previous_x.items[index], .y = self.previous_y.items[index] },
            .position_z = self.position_z.items[index],
            .previous_z = self.previous_z.items[index],
            .velocity = .{ .x = self.velocity_x.items[index], .y = self.velocity_y.items[index] },
            .speed = self.speed.items[index],
        };
    }

    fn ptrAt(self: *MovementBodyStore, index: usize) MovementBodyPtr {
        return .{
            .position_x = &self.position_x.items[index],
            .position_y = &self.position_y.items[index],
            .position_z = &self.position_z.items[index],
            .previous_x = &self.previous_x.items[index],
            .previous_y = &self.previous_y.items[index],
            .previous_z = &self.previous_z.items[index],
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
        self.position_z.items[index] = self.position_z.items[last];
        self.previous_x.items[index] = self.previous_x.items[last];
        self.previous_y.items[index] = self.previous_y.items[last];
        self.previous_z.items[index] = self.previous_z.items[last];
        self.velocity_x.items[index] = self.velocity_x.items[last];
        self.velocity_y.items[index] = self.velocity_y.items[last];
        self.speed.items[index] = self.speed.items[last];
        self.tier.items[index] = self.tier.items[last];
        self.chunk_x.items[index] = self.chunk_x.items[last];
        self.chunk_y.items[index] = self.chunk_y.items[last];
        self.level.items[index] = self.level.items[last];
        self.stagger_phase.items[index] = self.stagger_phase.items[last];
        self.always_active.items[index] = self.always_active.items[last];
        _ = self.entities.pop();
        _ = self.position_x.pop();
        _ = self.position_y.pop();
        _ = self.position_z.pop();
        _ = self.previous_x.pop();
        _ = self.previous_y.pop();
        _ = self.previous_z.pop();
        _ = self.velocity_x.pop();
        _ = self.velocity_y.pop();
        _ = self.speed.pop();
        _ = self.tier.pop();
        _ = self.chunk_x.pop();
        _ = self.chunk_y.pop();
        _ = self.level.pop();
        _ = self.stagger_phase.pop();
        _ = self.always_active.pop();
        return moved_entity;
    }

    fn slice(self: *MovementBodyStore) MovementBodySlice {
        return .{
            .entities = self.entities.items,
            .position_x = self.position_x.items,
            .position_y = self.position_y.items,
            .position_z = self.position_z.items,
            .previous_x = self.previous_x.items,
            .previous_y = self.previous_y.items,
            .previous_z = self.previous_z.items,
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
            .position_z = self.position_z.items,
            .previous_x = self.previous_x.items,
            .previous_y = self.previous_y.items,
            .previous_z = self.previous_z.items,
            .velocity_x = self.velocity_x.items,
            .velocity_y = self.velocity_y.items,
            .speed = self.speed.items,
        };
    }

    fn scopeSlice(self: *MovementBodyStore) ScopeColumnsSlice {
        return .{
            .entities = self.entities.items,
            .tier = self.tier.items,
            .chunk_x = self.chunk_x.items,
            .chunk_y = self.chunk_y.items,
            .level = self.level.items,
            .stagger_phase = self.stagger_phase.items,
            .always_active = self.always_active.items,
        };
    }

    fn scopeSliceConst(self: *const MovementBodyStore) ConstScopeColumnsSlice {
        return .{
            .entities = self.entities.items,
            .tier = self.tier.items,
            .chunk_x = self.chunk_x.items,
            .chunk_y = self.chunk_y.items,
            .level = self.level.items,
            .stagger_phase = self.stagger_phase.items,
            .always_active = self.always_active.items,
        };
    }

    fn clearRetainingCapacity(self: *MovementBodyStore) void {
        self.entities.clearRetainingCapacity();
        self.position_x.clearRetainingCapacity();
        self.position_y.clearRetainingCapacity();
        self.position_z.clearRetainingCapacity();
        self.previous_x.clearRetainingCapacity();
        self.previous_y.clearRetainingCapacity();
        self.previous_z.clearRetainingCapacity();
        self.velocity_x.clearRetainingCapacity();
        self.velocity_y.clearRetainingCapacity();
        self.speed.clearRetainingCapacity();
        self.tier.clearRetainingCapacity();
        self.chunk_x.clearRetainingCapacity();
        self.chunk_y.clearRetainingCapacity();
        self.level.clearRetainingCapacity();
        self.stagger_phase.clearRetainingCapacity();
        self.always_active.clearRetainingCapacity();
    }

    fn deinit(self: *MovementBodyStore, allocator: std.mem.Allocator) void {
        self.entities.deinit(allocator);
        self.position_x.deinit(allocator);
        self.position_y.deinit(allocator);
        self.position_z.deinit(allocator);
        self.previous_x.deinit(allocator);
        self.previous_y.deinit(allocator);
        self.previous_z.deinit(allocator);
        self.velocity_x.deinit(allocator);
        self.velocity_y.deinit(allocator);
        self.speed.deinit(allocator);
        self.tier.deinit(allocator);
        self.chunk_x.deinit(allocator);
        self.chunk_y.deinit(allocator);
        self.level.deinit(allocator);
        self.stagger_phase.deinit(allocator);
        self.always_active.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *MovementBodyStore, allocator: std.mem.Allocator) !void {
        try self.ensureCapacity(allocator, self.entities.items.len + 1);
    }

    fn ensureCapacity(self: *MovementBodyStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.entities.ensureTotalCapacity(allocator, capacity);
        try self.position_x.ensureTotalCapacity(allocator, capacity);
        try self.position_y.ensureTotalCapacity(allocator, capacity);
        try self.position_z.ensureTotalCapacity(allocator, capacity);
        try self.previous_x.ensureTotalCapacity(allocator, capacity);
        try self.previous_y.ensureTotalCapacity(allocator, capacity);
        try self.previous_z.ensureTotalCapacity(allocator, capacity);
        try self.velocity_x.ensureTotalCapacity(allocator, capacity);
        try self.velocity_y.ensureTotalCapacity(allocator, capacity);
        try self.speed.ensureTotalCapacity(allocator, capacity);
        try self.tier.ensureTotalCapacity(allocator, capacity);
        try self.chunk_x.ensureTotalCapacity(allocator, capacity);
        try self.chunk_y.ensureTotalCapacity(allocator, capacity);
        try self.level.ensureTotalCapacity(allocator, capacity);
        try self.stagger_phase.ensureTotalCapacity(allocator, capacity);
        try self.always_active.ensureTotalCapacity(allocator, capacity);
    }
};

const FacingStore = struct {
    // Facing is compact and cold enough to keep as enum rows, but it still
    // follows the dense entity-row contract for fast membership scans.
    entities: std.ArrayList(EntityId) = .empty,
    directions: std.ArrayList(Facing) = .empty,

    fn append(self: *FacingStore, allocator: std.mem.Allocator, entity: EntityId, facing: FacingData) !u32 {
        if (self.entities.items.len >= std.math.maxInt(u32)) return error.TooManyFacingRows;
        try self.ensureCapacity(allocator, self.entities.items.len + 1);
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

    fn ensureCapacity(self: *FacingStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.entities.ensureTotalCapacity(allocator, capacity);
        try self.directions.ensureTotalCapacity(allocator, capacity);
    }
};

const PrimitiveVisualStore = struct {
    // Visual columns keep render-prep reads linear and avoid touching gameplay
    // systems that do not care about color, marker, or depth fields.
    entities: std.ArrayList(EntityId) = .empty,
    size_x: std.ArrayList(f32) = .empty,
    size_y: std.ArrayList(f32) = .empty,
    color_r: std.ArrayList(f32) = .empty,
    color_g: std.ArrayList(f32) = .empty,
    color_b: std.ArrayList(f32) = .empty,
    color_a: std.ArrayList(f32) = .empty,
    depth_values: std.ArrayList(i32) = .empty,
    marker_color_r: std.ArrayList(f32) = .empty,
    marker_color_g: std.ArrayList(f32) = .empty,
    marker_color_b: std.ArrayList(f32) = .empty,
    marker_color_a: std.ArrayList(f32) = .empty,
    marker_depth_values: std.ArrayList(i32) = .empty,
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
        self.depth_values.items[index] = render_depth.worldZ(visual.depth);
        self.marker_color_r.items[index] = visual.marker_color.r;
        self.marker_color_g.items[index] = visual.marker_color.g;
        self.marker_color_b.items[index] = visual.marker_color.b;
        self.marker_color_a.items[index] = visual.marker_color.a;
        self.marker_depth_values.items[index] = render_depth.worldZ(visual.marker_depth_band);
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
            .depth = @enumFromInt(self.depth_values.items[index]),
            .marker_color = .{
                .r = self.marker_color_r.items[index],
                .g = self.marker_color_g.items[index],
                .b = self.marker_color_b.items[index],
                .a = self.marker_color_a.items[index],
            },
            .marker_depth_band = @enumFromInt(self.marker_depth_values.items[index]),
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
        self.depth_values.items[index] = self.depth_values.items[last];
        self.marker_color_r.items[index] = self.marker_color_r.items[last];
        self.marker_color_g.items[index] = self.marker_color_g.items[last];
        self.marker_color_b.items[index] = self.marker_color_b.items[last];
        self.marker_color_a.items[index] = self.marker_color_a.items[last];
        self.marker_depth_values.items[index] = self.marker_depth_values.items[last];
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
            .depth_values = self.depth_values.items,
            .marker_color_r = self.marker_color_r.items,
            .marker_color_g = self.marker_color_g.items,
            .marker_color_b = self.marker_color_b.items,
            .marker_color_a = self.marker_color_a.items,
            .marker_depth_values = self.marker_depth_values.items,
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
        self.depth_values.clearRetainingCapacity();
        self.marker_color_r.clearRetainingCapacity();
        self.marker_color_g.clearRetainingCapacity();
        self.marker_color_b.clearRetainingCapacity();
        self.marker_color_a.clearRetainingCapacity();
        self.marker_depth_values.clearRetainingCapacity();
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
        self.depth_values.deinit(allocator);
        self.marker_color_r.deinit(allocator);
        self.marker_color_g.deinit(allocator);
        self.marker_color_b.deinit(allocator);
        self.marker_color_a.deinit(allocator);
        self.marker_depth_values.deinit(allocator);
        self.marker_lengths.deinit(allocator);
        self.marker_depths.deinit(allocator);
        self.marker_margins.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *PrimitiveVisualStore, allocator: std.mem.Allocator) !void {
        try self.ensureCapacity(allocator, self.entities.items.len + 1);
    }

    fn ensureCapacity(self: *PrimitiveVisualStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.entities.ensureTotalCapacity(allocator, capacity);
        try self.size_x.ensureTotalCapacity(allocator, capacity);
        try self.size_y.ensureTotalCapacity(allocator, capacity);
        try self.color_r.ensureTotalCapacity(allocator, capacity);
        try self.color_g.ensureTotalCapacity(allocator, capacity);
        try self.color_b.ensureTotalCapacity(allocator, capacity);
        try self.color_a.ensureTotalCapacity(allocator, capacity);
        try self.depth_values.ensureTotalCapacity(allocator, capacity);
        try self.marker_color_r.ensureTotalCapacity(allocator, capacity);
        try self.marker_color_g.ensureTotalCapacity(allocator, capacity);
        try self.marker_color_b.ensureTotalCapacity(allocator, capacity);
        try self.marker_color_a.ensureTotalCapacity(allocator, capacity);
        try self.marker_depth_values.ensureTotalCapacity(allocator, capacity);
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
        self.depth_values.appendAssumeCapacity(render_depth.worldZ(visual.depth));
        self.marker_color_r.appendAssumeCapacity(visual.marker_color.r);
        self.marker_color_g.appendAssumeCapacity(visual.marker_color.g);
        self.marker_color_b.appendAssumeCapacity(visual.marker_color.b);
        self.marker_color_a.appendAssumeCapacity(visual.marker_color.a);
        self.marker_depth_values.appendAssumeCapacity(render_depth.worldZ(visual.marker_depth_band));
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
        _ = self.depth_values.pop();
        _ = self.marker_color_r.pop();
        _ = self.marker_color_g.pop();
        _ = self.marker_color_b.pop();
        _ = self.marker_color_a.pop();
        _ = self.marker_depth_values.pop();
        _ = self.marker_lengths.pop();
        _ = self.marker_depths.pop();
        _ = self.marker_margins.pop();
    }
};

const AssetReferenceStore = struct {
    // Persistent render identity is a stable asset ID. Loaded textures and
    // prepared sprite records are renderer/cache concerns, not component data.
    entities: std.ArrayList(EntityId) = .empty,
    sprite_ids: std.ArrayList(SpriteAssetId) = .empty,
    atlas_entry_ids: std.ArrayList(u16) = .empty,

    fn append(self: *AssetReferenceStore, allocator: std.mem.Allocator, entity: EntityId, asset_ref: AssetReference) !u32 {
        if (self.entities.items.len >= std.math.maxInt(u32)) return error.TooManyAssetReferenceRows;
        try self.ensureCapacity(allocator, self.entities.items.len + 1);
        const index: u32 = @intCast(self.entities.items.len);
        self.entities.appendAssumeCapacity(entity);
        self.sprite_ids.appendAssumeCapacity(asset_ref.sprite);
        self.atlas_entry_ids.appendAssumeCapacity(asset_ref.atlas_entry_id);
        return index;
    }

    fn removeAt(self: *AssetReferenceStore, index: usize) ?EntityId {
        const last = self.entities.items.len - 1;
        const moved_entity = if (index != last) self.entities.items[last] else null;
        self.entities.items[index] = self.entities.items[last];
        self.sprite_ids.items[index] = self.sprite_ids.items[last];
        self.atlas_entry_ids.items[index] = self.atlas_entry_ids.items[last];
        _ = self.entities.pop();
        _ = self.sprite_ids.pop();
        _ = self.atlas_entry_ids.pop();
        return moved_entity;
    }

    fn sliceConst(self: *const AssetReferenceStore) ConstAssetReferenceSlice {
        return .{
            .entities = self.entities.items,
            .sprite_ids = self.sprite_ids.items,
            .atlas_entry_ids = self.atlas_entry_ids.items,
        };
    }

    fn clearRetainingCapacity(self: *AssetReferenceStore) void {
        self.entities.clearRetainingCapacity();
        self.sprite_ids.clearRetainingCapacity();
        self.atlas_entry_ids.clearRetainingCapacity();
    }

    fn deinit(self: *AssetReferenceStore, allocator: std.mem.Allocator) void {
        self.atlas_entry_ids.deinit(allocator);
        self.entities.deinit(allocator);
        self.sprite_ids.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacity(self: *AssetReferenceStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.entities.ensureTotalCapacity(allocator, capacity);
        try self.sprite_ids.ensureTotalCapacity(allocator, capacity);
        try self.atlas_entry_ids.ensureTotalCapacity(allocator, capacity);
    }
};

const CollisionBoundsStore = struct {
    // Bounds columns are aligned because collision and pathfinding both scan
    // them in tight loops.
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
        try self.ensureCapacity(allocator, self.entities.items.len + 1);
    }

    fn ensureCapacity(self: *CollisionBoundsStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.entities.ensureTotalCapacity(allocator, capacity);
        try self.offset_x.ensureTotalCapacity(allocator, capacity);
        try self.offset_y.ensureTotalCapacity(allocator, capacity);
        try self.size_x.ensureTotalCapacity(allocator, capacity);
        try self.size_y.ensureTotalCapacity(allocator, capacity);
    }
};

const CollisionResponseStore = struct {
    // Response rows describe collision policy and static/dynamic mobility; they
    // intentionally do not point at collision-system runtime state.
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
        try self.ensureCapacity(allocator, self.entities.items.len + 1);
    }

    fn ensureCapacity(self: *CollisionResponseStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.entities.ensureTotalCapacity(allocator, capacity);
        try self.modes.ensureTotalCapacity(allocator, capacity);
        try self.mobilities.ensureTotalCapacity(allocator, capacity);
        try self.restitution.ensureTotalCapacity(allocator, capacity);
    }
};

const AiAgentStore = struct {
    // AI agent data stays small and persistent here. Per-step decisions are
    // emitted through SimulationFrame streams instead of stored on the entity.
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
        try self.ensureCapacity(allocator, self.entities.items.len + 1);
    }

    fn ensureCapacity(self: *AiAgentStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.entities.ensureTotalCapacity(allocator, capacity);
        try self.behaviors.ensureTotalCapacity(allocator, capacity);
        try self.wander_amplitudes.ensureTotalCapacity(allocator, capacity);
        try self.seek_weights.ensureTotalCapacity(allocator, capacity);
    }
};

const SteeringAgentStore = struct {
    // Steering configuration is persistent, while path cooldowns and local
    // avoidance scratch live in SteeringSystem runtime rows.
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
        try self.ensureCapacity(allocator, self.entities.items.len + 1);
    }

    fn ensureCapacity(self: *SteeringAgentStore, allocator: std.mem.Allocator, capacity: usize) !void {
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
    try std.testing.expectEqual(slice.entities.len, slice.position_z.len);
    try std.testing.expectEqual(slice.entities.len, slice.previous_x.len);
    try std.testing.expectEqual(slice.entities.len, slice.previous_y.len);
    try std.testing.expectEqual(slice.entities.len, slice.previous_z.len);
    try std.testing.expectEqual(slice.entities.len, slice.velocity_x.len);
    try std.testing.expectEqual(slice.entities.len, slice.velocity_y.len);
    try std.testing.expectEqual(slice.entities.len, slice.speed.len);
}

fn expectHotColumnPointersAligned(slice: ConstMovementBodySlice) !void {
    try expectPointerAligned(slice.position_x.ptr);
    try expectPointerAligned(slice.position_y.ptr);
    try expectPointerAligned(slice.position_z.ptr);
    try expectPointerAligned(slice.previous_x.ptr);
    try expectPointerAligned(slice.previous_y.ptr);
    try expectPointerAligned(slice.previous_z.ptr);
    try expectPointerAligned(slice.velocity_x.ptr);
    try expectPointerAligned(slice.velocity_y.ptr);
    try expectPointerAligned(slice.speed.ptr);
}

fn expectPointerAligned(ptr: anytype) !void {
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(ptr) % hot_soa_column_alignment);
}

fn expectPrimitiveVisualColumnsAligned(slice: ConstPrimitiveVisualSlice) !void {
    try std.testing.expectEqual(slice.entities.len, slice.size_x.len);
    try std.testing.expectEqual(slice.entities.len, slice.size_y.len);
    try std.testing.expectEqual(slice.entities.len, slice.color_r.len);
    try std.testing.expectEqual(slice.entities.len, slice.color_g.len);
    try std.testing.expectEqual(slice.entities.len, slice.color_b.len);
    try std.testing.expectEqual(slice.entities.len, slice.color_a.len);
    try std.testing.expectEqual(slice.entities.len, slice.depth_values.len);
    try std.testing.expectEqual(slice.entities.len, slice.marker_color_r.len);
    try std.testing.expectEqual(slice.entities.len, slice.marker_color_g.len);
    try std.testing.expectEqual(slice.entities.len, slice.marker_color_b.len);
    try std.testing.expectEqual(slice.entities.len, slice.marker_color_a.len);
    try std.testing.expectEqual(slice.entities.len, slice.marker_depth_values.len);
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

test "entity simulation metadata defaults and rejects stale ids" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    // Scope metadata lives on the dense movement-body scope row, so an entity
    // must have a movement body to carry it. Bodiless entities report null.
    const entity = try data.createEntity();
    try std.testing.expect(data.simulationMetadata(entity) == null);
    try data.setMovementBody(entity, .{});
    try std.testing.expectEqual(EntitySimulationMetadata{}, data.simulationMetadata(entity).?);
    try data.setSimulationMetadata(entity, .{
        .tier = .locomotion,
        .chunk = .{ .x = 4, .y = -2 },
        .level = 3,
    });
    try std.testing.expectEqual(EntitySimulationMetadata{
        .tier = .locomotion,
        .chunk = .{ .x = 4, .y = -2 },
        .level = 3,
    }, data.simulationMetadata(entity).?);
    // The scope columns view exposes the same level the metadata round-tripped.
    try std.testing.expectEqual(@as(u16, 3), data.scopeColumnsSliceConst().level[0]);

    try std.testing.expect(data.destroyEntity(entity));
    try std.testing.expect(data.simulationMetadata(entity) == null);
    try std.testing.expectError(error.InvalidEntity, data.setSimulationMetadata(entity, .{}));

    const reused = try data.createEntity();
    try std.testing.expectEqual(entity.index, reused.index);
    try data.setMovementBody(reused, .{});
    try std.testing.expectEqual(EntitySimulationMetadata{}, data.simulationMetadata(reused).?);
}

test "entity simulation metadata resets with retained capacity" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{});
    try data.setSimulationMetadata(entity, .{
        .tier = .dormant,
        .chunk = .{ .x = 9, .y = 3 },
    });
    data.clearRetainingCapacity();

    const reused = try data.createEntity();
    try std.testing.expectEqual(entity.index, reused.index);
    try data.setMovementBody(reused, .{});
    try std.testing.expectEqual(EntitySimulationMetadata{}, data.simulationMetadata(reused).?);
}

test "full active scope stats count tiers and current stage slices" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const mover = try data.createEntity();
    const thinker = try data.createEntity();
    const dormant = try data.createEntity();
    try data.setMovementBody(mover, .{});
    try data.setCollisionBounds(mover, .{ .size = .{ .x = 8, .y = 8 } });
    try data.setCollisionResponse(mover, .{});
    try data.setMovementBody(thinker, .{});
    try data.setAiAgent(thinker, .{});
    try data.setSteeringAgent(thinker, .{});
    try data.setMovementBody(dormant, .{});
    try data.setSimulationMetadata(mover, .{ .tier = .locomotion });
    try data.setSimulationMetadata(dormant, .{ .tier = .dormant });

    const stats = data.simulationScopeStatsFullActive();
    try std.testing.expectEqual(@as(usize, 3), stats.total_entities);
    try std.testing.expectEqual(@as(usize, 1), stats.dormant_entities);
    try std.testing.expectEqual(@as(usize, 1), stats.locomotion_entities);
    try std.testing.expectEqual(@as(usize, 1), stats.cognition_entities);
    try std.testing.expectEqual(data.movementBodySliceConst().entities.len, stats.movement_stage_entities);
    try std.testing.expectEqual(data.collisionBoundsSliceConst().entities.len, stats.collision_stage_entities);
    try std.testing.expectEqual(data.collisionResponseSliceConst().entities.len, stats.collision_response_stage_entities);
    try std.testing.expectEqual(data.aiAgentSliceConst().entities.len, stats.ai_stage_entities);
    try std.testing.expectEqual(data.steeringAgentSliceConst().entities.len, stats.steering_stage_entities);
}

test "entity free slot count tracks destroy reuse and reset" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    const second = try data.createEntity();
    try std.testing.expectEqual(@as(usize, 0), data.free_slot_count);

    try std.testing.expect(data.destroyEntity(first));
    try std.testing.expect(data.destroyEntity(second));
    try std.testing.expectEqual(@as(usize, 2), data.free_slot_count);

    _ = try data.createEntity();
    try std.testing.expectEqual(@as(usize, 1), data.free_slot_count);

    data.clearRetainingCapacity();
    try std.testing.expectEqual(data.slots.items.len, data.free_slot_count);
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
        try std.testing.expectEqual(@as(i32, @intFromFloat(expected)) - 2, slice.position_z[index]);
        try std.testing.expectEqual(expected + 20, slice.previous_x[index]);
        try std.testing.expectEqual(expected + 30, slice.previous_y[index]);
        try std.testing.expectEqual(@as(i32, @intFromFloat(expected)) - 1, slice.previous_z[index]);
        try std.testing.expectEqual(expected + 40, slice.velocity_x[index]);
        try std.testing.expectEqual(expected + 50, slice.velocity_y[index]);
        try std.testing.expectEqual(expected + 60, slice.speed[index]);
    }
}

test "movement body ingress rejects invalid payloads without mutating existing rows" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, testBody(1));

    var bad = testBody(99);
    bad.position.x = std.math.nan(f32);
    try std.testing.expectError(error.InvalidMovementBody, data.setMovementBody(entity, bad));
    try std.testing.expectEqual(@as(f32, 1), data.movementBodyConst(entity).?.position.x);

    bad = testBody(99);
    bad.previous_position.y = std.math.inf(f32);
    try std.testing.expectError(error.InvalidMovementBody, data.setMovementBody(entity, bad));
    try std.testing.expectEqual(@as(f32, 1), data.movementBodyConst(entity).?.position.x);

    bad = testBody(99);
    bad.velocity.x = -std.math.inf(f32);
    try std.testing.expectError(error.InvalidMovementBody, data.setMovementBody(entity, bad));
    try std.testing.expectEqual(@as(f32, 1), data.movementBodyConst(entity).?.position.x);

    bad = testBody(99);
    bad.speed = -0.1;
    try std.testing.expectError(error.InvalidMovementBody, data.setMovementBody(entity, bad));
    try std.testing.expectEqual(@as(f32, 1), data.movementBodyConst(entity).?.position.x);
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

test "primitive visual ingress rejects invalid payloads without mutating existing rows" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setPrimitiveVisual(entity, testVisualWithSize(8));

    var bad = testVisualWithSize(99);
    bad.size.x = 0;
    try std.testing.expectError(error.InvalidPrimitiveVisual, data.setPrimitiveVisual(entity, bad));
    try std.testing.expectEqual(@as(f32, 8), data.primitiveVisualConst(entity).?.size.x);

    bad = testVisualWithSize(99);
    bad.size.y = std.math.inf(f32);
    try std.testing.expectError(error.InvalidPrimitiveVisual, data.setPrimitiveVisual(entity, bad));
    try std.testing.expectEqual(@as(f32, 8), data.primitiveVisualConst(entity).?.size.x);

    bad = testVisualWithSize(99);
    bad.color.g = std.math.nan(f32);
    try std.testing.expectError(error.InvalidPrimitiveVisual, data.setPrimitiveVisual(entity, bad));
    try std.testing.expectEqual(@as(f32, 8), data.primitiveVisualConst(entity).?.size.x);

    bad = testVisualWithSize(99);
    bad.marker_length = -0.1;
    try std.testing.expectError(error.InvalidPrimitiveVisual, data.setPrimitiveVisual(entity, bad));
    try std.testing.expectEqual(@as(f32, 8), data.primitiveVisualConst(entity).?.size.x);

    bad = testVisualWithSize(99);
    bad.marker_depth = std.math.inf(f32);
    try std.testing.expectError(error.InvalidPrimitiveVisual, data.setPrimitiveVisual(entity, bad));
    try std.testing.expectEqual(@as(f32, 8), data.primitiveVisualConst(entity).?.size.x);

    bad = testVisualWithSize(99);
    bad.marker_margin = std.math.nan(f32);
    try std.testing.expectError(error.InvalidPrimitiveVisual, data.setPrimitiveVisual(entity, bad));
    try std.testing.expectEqual(@as(f32, 8), data.primitiveVisualConst(entity).?.size.x);
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

test "asset references store stable sprite ids and optional atlas entries" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setAssetReference(entity, .{ .sprite = .grim_characters, .atlas_entry_id = 8 });
    const asset_ref = data.assetReferenceConst(entity).?;
    try std.testing.expectEqual(SpriteAssetId.grim_characters, asset_ref.sprite);
    try std.testing.expectEqual(@as(u16, 8), asset_ref.atlas_entry_id);

    const slice = data.assetReferenceSliceConst();
    try std.testing.expectEqual(@as(usize, 1), slice.entities.len);
    try std.testing.expectEqual(SpriteAssetId.grim_characters, slice.sprite_ids[0]);
    try std.testing.expectEqual(@as(u16, 8), slice.atlas_entry_ids[0]);
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
            .asset_reference = .{ .sprite = .grim_characters, .atlas_entry_id = 9 },
        } },
    };

    _ = try data.applyStructuralCommands(&commands);
    const entity = data.assetReferenceSliceConst().entities[0];
    const asset_ref = data.assetReferenceConst(entity).?;
    try std.testing.expectEqual(SpriteAssetId.grim_characters, asset_ref.sprite);
    try std.testing.expectEqual(@as(u16, 9), asset_ref.atlas_entry_id);
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

test "structural commands prevalidate movement and primitive visuals before mutating" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const existing = try data.createEntity();
    try data.setMovementBody(existing, testBody(1));
    try data.setPrimitiveVisual(existing, testVisualWithSize(8));

    var invalid_body = testBody(2);
    invalid_body.speed = std.math.nan(f32);
    const movement_commands = [_]StructuralCommand{
        .{ .set_movement_body = .{ .entity = existing, .body = testBody(99) } },
        .{ .create_entity = .{ .movement_body = invalid_body } },
    };
    try std.testing.expectError(error.InvalidMovementBody, data.applyStructuralCommands(&movement_commands));
    try std.testing.expectEqual(@as(f32, 1), data.movementBodyConst(existing).?.position.x);
    try std.testing.expectEqual(@as(usize, 1), data.movementBodySliceConst().entities.len);

    var invalid_visual = testVisualWithSize(16);
    invalid_visual.marker_margin = -1;
    const visual_commands = [_]StructuralCommand{
        .{ .set_primitive_visual = .{ .entity = existing, .visual = testVisualWithSize(99) } },
        .{ .create_entity = .{ .primitive_visual = invalid_visual } },
    };
    try std.testing.expectError(error.InvalidPrimitiveVisual, data.applyStructuralCommands(&visual_commands));
    try std.testing.expectEqual(@as(f32, 8), data.primitiveVisualConst(existing).?.size.x);
    try std.testing.expectEqual(@as(usize, 1), data.primitiveVisualSliceConst().entities.len);
}

test "structural commands reserve capacity before mutating" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const existing = try data.createEntity();
    try data.setMovementBody(existing, testBody(1));

    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    try commands.append(std.testing.allocator, .{ .set_movement_body = .{ .entity = existing, .body = testBody(99) } });
    for (0..64) |index| {
        try commands.append(std.testing.allocator, .{ .create_entity = .{
            .movement_body = testBody(@floatFromInt(index + 2)),
            .primitive_visual = testVisual(),
            .collision_bounds = testBounds(1),
        } });
    }

    const original_allocator = data.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    data.allocator = failing_allocator.allocator();
    defer data.allocator = original_allocator;

    var scratch = StructuralPlanScratch.init(std.testing.allocator);
    defer scratch.deinit();
    try std.testing.expectError(error.OutOfMemory, data.preflightStructuralCommands(commands.items, &scratch));
    try std.testing.expectEqual(@as(f32, 1), data.movementBodyConst(existing).?.position.x);
    try std.testing.expectEqual(@as(usize, 1), data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 0), data.primitiveVisualSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 0), data.collisionBoundsSliceConst().entities.len);
}

test "structural command preflight follows destroy then create slot reuse" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, testBody(1));

    const commands = [_]StructuralCommand{
        .{ .destroy_entity = entity },
        .{ .create_entity = .{
            .movement_body = testBody(2),
        } },
    };

    var scratch = StructuralPlanScratch.init(std.testing.allocator);
    defer scratch.deinit();
    _ = try data.preflightStructuralCommands(&commands, &scratch);

    const original_allocator = data.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    data.allocator = failing_allocator.allocator();
    defer data.allocator = original_allocator;

    var sink = NullStructuralChangeSink{};
    const stats = try data.commitStructuralCommands(&commands, &sink);
    try std.testing.expectEqual(@as(usize, 1), stats.destroyed);
    try std.testing.expectEqual(@as(usize, 1), stats.created);
    try std.testing.expectEqual(@as(usize, 1), data.movementBodySliceConst().entities.len);
    try std.testing.expect(data.movementBodyConst(entity) == null);
}

test "structural command preflight counts duplicate component sets once" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const target = try data.createEntity();
    const seed = try data.createEntity();
    try data.setPrimitiveVisual(seed, testVisualWithSize(8));
    try std.testing.expect(data.destroyEntity(seed));

    const commands = [_]StructuralCommand{
        .{ .set_primitive_visual = .{ .entity = target, .visual = testVisualWithSize(16) } },
        .{ .set_primitive_visual = .{ .entity = target, .visual = testVisualWithSize(32) } },
    };

    var scratch = StructuralPlanScratch.init(std.testing.allocator);
    defer scratch.deinit();
    _ = try data.preflightStructuralCommands(&commands, &scratch);

    const original_allocator = data.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    data.allocator = failing_allocator.allocator();
    defer data.allocator = original_allocator;

    var sink = NullStructuralChangeSink{};
    const stats = try data.commitStructuralCommands(&commands, &sink);
    try std.testing.expectEqual(@as(usize, 2), stats.components_set);
    try std.testing.expectEqual(@as(usize, 1), data.primitiveVisualSliceConst().entities.len);
    try std.testing.expectEqual(@as(f32, 32), data.primitiveVisualConst(target).?.size.x);
}

test "structural command plan counts only projected live structural events" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const destroyed = try data.createEntity();
    try data.setMovementBody(destroyed, testBody(1));

    const commands = [_]StructuralCommand{
        .{ .destroy_entity = destroyed },
        .{ .set_movement_body = .{ .entity = destroyed, .body = testBody(2) } },
        .{ .set_facing = .{ .entity = EntityId.invalid, .facing = .{ .direction = .left } } },
        .{ .create_entity = .{
            .movement_body = testBody(3),
            .facing = .{ .direction = .right },
        } },
    };

    var scratch = StructuralPlanScratch.init(std.testing.allocator);
    defer scratch.deinit();
    const plan = try data.preflightStructuralCommands(&commands, &scratch);
    try std.testing.expectEqual(@as(usize, 4), plan.structural_event_count);

    const stats = try data.applyStructuralCommands(&commands);
    try std.testing.expectEqual(@as(usize, 1), stats.destroyed);
    try std.testing.expectEqual(@as(usize, 2), stats.stale_skipped);
    try std.testing.expectEqual(@as(usize, 1), stats.created);
    try std.testing.expectEqual(@as(usize, 2), stats.components_set);
}

test "structural command preflight returns before projection for empty command batches" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    for (0..8) |_| {
        const entity = try data.createEntity();
        try std.testing.expect(data.destroyEntity(entity));
    }

    var scratch = StructuralPlanScratch.init(std.testing.allocator);
    defer scratch.deinit();

    const original_allocator = data.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    data.allocator = failing_allocator.allocator();
    defer data.allocator = original_allocator;

    const plan = try data.preflightStructuralCommands(&.{}, &scratch);
    try std.testing.expectEqual(@as(usize, 0), plan.structural_event_count);
    try std.testing.expectEqual(@as(usize, 0), scratch.projected_entities.count());
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

test "incremental tier counts track create, destroy, metadata change, and reset" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const e0 = try data.createEntity();
    const e1 = try data.createEntity();
    const e2 = try data.createEntity();
    // Tier lives on the dense movement-body scope row, so each tiered entity needs
    // a movement body.
    try data.setMovementBody(e0, .{});
    try data.setMovementBody(e1, .{});
    try data.setMovementBody(e2, .{});
    try data.setSimulationMetadata(e1, .{ .tier = .dormant });
    try data.setSimulationMetadata(e2, .{ .tier = .kinematic });
    _ = data.destroyEntity(e0); // was cognition (default)
    const e3 = try data.createEntity(); // reuses e0's slot at cognition
    try data.setMovementBody(e3, .{});
    try data.setSimulationMetadata(e3, .{ .tier = .locomotion });

    // The incrementally-maintained counters must equal a fresh live scan, and the
    // public scope stats must agree cell-for-cell.
    try std.testing.expectEqual(data.scanLiveTierCounts(), data.tier_counts);
    const stats = data.simulationScopeStatsFullActive();
    const scan = data.scanLiveTierCounts();
    try std.testing.expectEqual(scan[@intFromEnum(SimulationTier.dormant)], stats.dormant_entities);
    try std.testing.expectEqual(scan[@intFromEnum(SimulationTier.kinematic)], stats.kinematic_entities);
    try std.testing.expectEqual(scan[@intFromEnum(SimulationTier.locomotion)], stats.locomotion_entities);
    try std.testing.expectEqual(scan[@intFromEnum(SimulationTier.cognition)], stats.cognition_entities);
    try std.testing.expectEqual(@as(usize, 3), stats.total_entities);

    data.clearRetainingCapacity();
    try std.testing.expectEqual([4]usize{ 0, 0, 0, 0 }, data.tier_counts);
    try std.testing.expectEqual(@as(usize, 0), data.simulationScopeStatsFullActive().total_entities);
}

test "set_simulation_tier preserves chunk and stagger_phase" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{});
    const orig = data.simulationMetadata(entity).?;
    const orig_chunk = orig.chunk;
    const orig_phase = orig.stagger_phase;

    try data.setSimulationTier(entity, .locomotion);
    const updated = data.simulationMetadata(entity).?;

    try std.testing.expectEqual(SimulationTier.locomotion, updated.tier);
    try std.testing.expectEqual(orig_chunk, updated.chunk);
    try std.testing.expectEqual(orig_phase, updated.stagger_phase);
    try std.testing.expectEqual(data.scanLiveTierCounts(), data.tier_counts);
}

test "structural command set_simulation_tier commits and skips stale entities" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const alive = try data.createEntity();
    try data.setMovementBody(alive, .{});
    const dead = try data.createEntity();
    _ = data.destroyEntity(dead);
    // Live entity with no movement body — tier has no row to land on. Must skip
    // like a stale ID, not abort the batch (would drop the trailing command).
    const bodiless = try data.createEntity();

    var commands = [_]StructuralCommand{
        .{ .set_simulation_tier = .{ .entity = dead, .tier = .dormant } },
        .{ .set_simulation_tier = .{ .entity = bodiless, .tier = .dormant } },
        .{ .set_simulation_tier = .{ .entity = alive, .tier = .dormant } },
    };
    var sink = NullStructuralChangeSink{};
    const stats = try data.applyStructuralCommandsWithChangeSink(&commands, &sink);

    try std.testing.expectEqual(@as(usize, 0), stats.created);
    try std.testing.expectEqual(@as(usize, 2), stats.stale_skipped);
    // The command after the skipped ones still applied — no partial commit.
    try std.testing.expectEqual(SimulationTier.dormant, data.simulationMetadata(alive).?.tier);
    try std.testing.expectEqual(@as(?EntitySimulationMetadata, null), data.simulationMetadata(bodiless));
    try std.testing.expectEqual(data.scanLiveTierCounts(), data.tier_counts);
}

test "entering a non-moving tier snaps interpolation history to position" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{ .x = 100, .y = 200 } });
    const di = data.movementBodyDenseIndex(entity).?;
    // Diverge previous from position, as a mid-flight integration would leave it.
    data.movement_bodies.previous_x.items[di] = 10;
    data.movement_bodies.previous_y.items[di] = 20;

    // Non-moving tier snaps previous = position so render interpolation is static.
    try data.setSimulationTier(entity, .dormant);
    try std.testing.expectEqual(@as(f32, 100), data.movement_bodies.previous_x.items[di]);
    try std.testing.expectEqual(@as(f32, 200), data.movement_bodies.previous_y.items[di]);

    // A moving tier leaves the history untouched (movement will resync it).
    data.movement_bodies.previous_x.items[di] = 10;
    try data.setSimulationTier(entity, .cognition);
    try std.testing.expectEqual(@as(f32, 10), data.movement_bodies.previous_x.items[di]);
}

fn testBody(base: f32) MovementBody {
    return .{
        .position = .{ .x = base, .y = base + 10 },
        .previous_position = .{ .x = base + 20, .y = base + 30 },
        .position_z = @as(i32, @intFromFloat(base)) - 2,
        .previous_z = @as(i32, @intFromFloat(base)) - 1,
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
