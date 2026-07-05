// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Leaf public types for the DataSystem package: entity handles, component
//! payload structs, dense-slice views, and structural-command payloads. No
//! dependency on the DataSystem type itself, mirroring pathfinding's types.zig.

const std = @import("std");
const SpriteAssetId = @import("../../assets/manifest.zig").SpriteAssetId;
const config = @import("../../config.zig");
const math = @import("../../core/math.zig");
const faction = @import("../faction.zig");
const render_depth = @import("../render_depth.zig");
const runtime_perf_log = @import("../../app/runtime_perf_log.zig");
const SimulationTier = @import("../simulation_scope.zig").SimulationTier;
const alignItemCount = @import("../../app/thread_system.zig").alignItemCount;
const WorldDepth = render_depth.WorldDepth;
pub const Faction = faction.Faction;

pub const hot_soa_column_alignment: usize = 64;
pub const movement_range_alignment_items: usize = hot_soa_column_alignment / @sizeOf(f32);

pub const HotF32Slice = []f32;
pub const ConstHotF32Slice = []const f32;
pub const HotI32Slice = []i32;
pub const ConstHotI32Slice = []const i32;

pub fn hotStoreCapacity(min_len: usize) usize {
    return alignItemCount(min_len, movement_range_alignment_items);
}

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
    world_level,
    faction,
    ai_perception,
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
    pub const world_level = componentMask(.world_level);
    pub const faction = componentMask(.faction);
    pub const ai_perception = componentMask(.ai_perception);
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

    // z is not interpolated: previous_z must always equal position_z when
    // snapping a body onto a plane (level-change, spawn, fall, ramp).
    pub fn snapZ(self: MovementBodyPtr, z: i32) void {
        self.position_z.* = z;
        self.previous_z.* = z;
    }
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
    /// Dense drawable flag for render collect; movement-only rows stay false.
    has_primitive_visual: []bool,
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
    /// Dense drawable flag for render collect; movement-only rows stay false.
    has_primitive_visual: []const bool,
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

pub const ConstFactionSlice = struct {
    entities: []const EntityId,
    factions: []const Faction,
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

/// Dense component indices resolved in one entity-slot lookup for render-hot paths.
pub const RenderEntityComponentIndices = struct {
    movement_body: usize,
    asset_ref: ?usize = null,
    facing: ?usize = null,
};

/// Primitive-visual and optional facing/asset indices for one movement-body row.
/// Returned only when the entity carries a drawable primitive visual.
pub const RenderCollectIndices = struct {
    visual_index: usize,
    asset_ref_index: ?usize = null,
    facing_index: ?usize = null,
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

// Default half-angle is 60 degrees (120 degree full cone). Capped in
// validateAiPerception at pi/2 (90 degrees) so cos_half_fov never goes
// negative — the FOV test in PerceptionSystem relies on cos_half_fov >= 0.
// Widening past 90 degrees is deferred to a future slice if a wider cone is
// ever needed.
const default_ai_perception_fov_half_angle_radians: f32 = std.math.pi / 3.0;
// cos(pi/3) == 0.5 exactly; kept as a literal comptime constant (not a
// math.sinCos call) so the struct-field default stays trivially comptime-known.
// The store always recomputes cos_half_fov from fov_half_angle_radians on
// append/set, so this default value is never load-bearing.
const default_ai_perception_cos_half_fov: f32 = 0.5;

/// Cold tunables (vision_range, fov_half_angle_radians) are author-set.
/// cos_half_fov is derived once from fov_half_angle_radians at set()/append()
/// time by PerceptionStore — never recomputed per-frame — so FOV checks in
/// the (future) PerceptionSystem need only a dot-product compare, no vector
/// sin/cos polynomial. Hot fields are written every step by PerceptionSystem
/// and held across steps otherwise.
pub const AiPerception = struct {
    vision_range: f32 = 240.0,
    fov_half_angle_radians: f32 = default_ai_perception_fov_half_angle_radians,
    cos_half_fov: f32 = default_ai_perception_cos_half_fov,
    target_visible: bool = false,
    last_seen_x: f32 = 0,
    last_seen_y: f32 = 0,
    nearest_threat: EntityId = EntityId.invalid,
    nearest_threat_dist: f32 = std.math.inf(f32),
    facing_x: f32 = 1.0,
    facing_y: f32 = 0.0,
};

// Keeps LOS raycast step counts small by construction.
pub const max_ai_perception_vision_range: f32 = 512.0;

pub const AiPerceptionCommand = struct {
    entity: EntityId,
    perception: AiPerception,
};

pub const ConstPerceptionSlice = struct {
    entities: []const EntityId,
    vision_range: ConstHotF32Slice,
    fov_half_angle_radians: ConstHotF32Slice,
    cos_half_fov: ConstHotF32Slice,
    target_visible: []const bool,
    last_seen_x: ConstHotF32Slice,
    last_seen_y: ConstHotF32Slice,
    nearest_threat: []const EntityId,
    nearest_threat_dist: ConstHotF32Slice,
    facing_x: ConstHotF32Slice,
    facing_y: ConstHotF32Slice,
};

/// Mutable view exposes only the hot output columns PerceptionSystem writes
/// every step (target_visible, last_seen_x/y, nearest_threat,
/// nearest_threat_dist, facing_x/y). Cold tunables stay const here — they
/// change only through DataSystem.setAiPerception, mirroring ScopeColumnsSlice.
pub const PerceptionSlice = struct {
    entities: []const EntityId,
    vision_range: ConstHotF32Slice,
    fov_half_angle_radians: ConstHotF32Slice,
    cos_half_fov: ConstHotF32Slice,
    target_visible: []bool,
    last_seen_x: HotF32Slice,
    last_seen_y: HotF32Slice,
    nearest_threat: []EntityId,
    nearest_threat_dist: HotF32Slice,
    facing_x: HotF32Slice,
    facing_y: HotF32Slice,
};

pub const WorldLevelCommand = struct {
    entity: EntityId,
    level: u16,
};

pub const ConstWorldLevelSlice = struct {
    entities: []const EntityId,
    levels: []const u16,
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
    world_level: ?u16 = null,
    faction: ?Faction = null,
    ai_perception: ?AiPerception = null,
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

pub const FactionCommand = struct {
    entity: EntityId,
    faction: Faction,
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
    set_world_level: WorldLevelCommand,
    set_simulation_tier: SimulationTierCommand,
    set_faction: FactionCommand,
    set_ai_perception: AiPerceptionCommand,
};

pub const StructuralCommitStats = struct {
    created: usize = 0,
    destroyed: usize = 0,
    components_set: usize = 0,
    stale_skipped: usize = 0,

    pub fn recordTo(self: StructuralCommitStats, perf: runtime_perf_log.Context) void {
        perf.recordMetric(.structural_created, metric(self.created));
        perf.recordMetric(.structural_destroyed, metric(self.destroyed));
        perf.recordMetric(.structural_components_set, metric(self.components_set));
        perf.recordMetric(.structural_stale_skipped, metric(self.stale_skipped));
    }
};

fn metric(value: usize) u64 {
    return @intCast(value);
}

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

test "entity ids reject invalid values and match slots exactly" {
    try std.testing.expectError(error.InvalidEntityIndex, EntityId.init(std.math.maxInt(u32), 1));
    try std.testing.expectError(error.InvalidGeneration, EntityId.init(0, 0));

    const id = try EntityId.init(3, 7);
    try std.testing.expect(id.isValid());
    try std.testing.expect(id.matches(3, 7));
    try std.testing.expect(!id.matches(3, 8));
    try std.testing.expect(!EntityId.invalid.isValid());
}
