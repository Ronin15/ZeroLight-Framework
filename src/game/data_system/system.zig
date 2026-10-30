// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Persistent gameplay-data owner and ECS storage foundation: entity slots
//! (stable handles with generation-based reuse safety) plus dense SoA
//! component stores from the sibling data_system/ package modules. Structural
//! (create/destroy/component-set) commands are deferred through structural.zig;
//! movement/collision/agent/visual/faction component storage lives in their
//! own per-domain modules, mirroring pathfinding's system.zig + solve.zig split.

const std = @import("std");
const types = @import("types.zig");
const EntityId = types.EntityId;
const Component = types.Component;
const ComponentMask = types.ComponentMask;
const component_masks = types.component_masks;
const componentMask = types.componentMask;
const Facing = types.Facing;
const MovementBody = types.MovementBody;
const MovementBodyPtr = types.MovementBodyPtr;
const MovementBodySlice = types.MovementBodySlice;
const ConstMovementBodySlice = types.ConstMovementBodySlice;
const ScopeColumnsSlice = types.ScopeColumnsSlice;
const ConstScopeColumnsSlice = types.ConstScopeColumnsSlice;
const FacingData = types.FacingData;
const ConstFacingSlice = types.ConstFacingSlice;
const PrimitiveVisual = types.PrimitiveVisual;
const ConstPrimitiveVisualSlice = types.ConstPrimitiveVisualSlice;
const AssetReference = types.AssetReference;
const ConstAssetReferenceSlice = types.ConstAssetReferenceSlice;
const BodyLevelFaction = types.BodyLevelFaction;
const RenderCollectIndices = types.RenderCollectIndices;
const MovementVisualDenseIndices = types.MovementVisualDenseIndices;
const MovementSteeringDenseIndices = types.MovementSteeringDenseIndices;
const CollisionBounds = types.CollisionBounds;
const ConstCollisionBoundsSlice = types.ConstCollisionBoundsSlice;
const CollisionResponseMode = types.CollisionResponseMode;
const CollisionResponseMobility = types.CollisionResponseMobility;
const CollisionResponse = types.CollisionResponse;
const ConstCollisionResponseSlice = types.ConstCollisionResponseSlice;
const AiBehavior = types.AiBehavior;
const AiAgent = types.AiAgent;
const ConstAiAgentSlice = types.ConstAiAgentSlice;
const AiAgentSlice = types.AiAgentSlice;
const SteeringAgent = types.SteeringAgent;
const ConstSteeringAgentSlice = types.ConstSteeringAgentSlice;
const ConstWorldLevelSlice = types.ConstWorldLevelSlice;
const Faction = types.Faction;
const StructuralCommand = types.StructuralCommand;
const movement_range_alignment_items = types.movement_range_alignment_items;
const hot_soa_column_alignment = types.hot_soa_column_alignment;
const hotStoreCapacity = types.hotStoreCapacity;
const MovementBodyStore = @import("movement.zig").MovementBodyStore;
const validateMovementBody = @import("movement.zig").validateMovementBody;
const FacingStore = @import("visual.zig").FacingStore;
const PrimitiveVisualStore = @import("visual.zig").PrimitiveVisualStore;
const AssetReferenceStore = @import("visual.zig").AssetReferenceStore;
const validatePrimitiveVisual = @import("visual.zig").validatePrimitiveVisual;
const SpriteAssetId = @import("../../assets/manifest.zig").SpriteAssetId;
const collision = @import("collision.zig");
const CollisionBoundsStore = collision.CollisionBoundsStore;
const CollisionResponseStore = collision.CollisionResponseStore;
const validateCollisionBounds = collision.validateCollisionBounds;
const validateCollisionResponse = collision.validateCollisionResponse;
const agents = @import("agents.zig");
const AiAgentStore = agents.AiAgentStore;
const SteeringAgentStore = agents.SteeringAgentStore;
const validateAiAgent = agents.validateAiAgent;
const validateSteeringAgent = agents.validateSteeringAgent;
const max_ai_gain = types.max_ai_gain;
const max_steering_neighbor_samples = types.max_steering_neighbor_samples;
const faction_level = @import("faction_level.zig");
const FactionStore = faction_level.FactionStore;
const WorldLevelStore = faction_level.WorldLevelStore;
const perception = @import("perception.zig");
const PerceptionStore = perception.PerceptionStore;
const validateAiPerception = perception.validateAiPerception;
const AiPerception = types.AiPerception;
const max_ai_perception_vision_range = types.max_ai_perception_vision_range;
const ConstPerceptionSlice = types.ConstPerceptionSlice;
const PerceptionSlice = types.PerceptionSlice;
const memory = @import("memory.zig");
const AiMemoryStore = memory.AiMemoryStore;
const validateAiMemory = memory.validateAiMemory;
const AiMemory = types.AiMemory;
const ConstAiMemorySlice = types.ConstAiMemorySlice;
const AiMemorySlice = types.AiMemorySlice;
const affect = @import("affect.zig");
const AiAffectStore = affect.AiAffectStore;
const validateAiAffect = affect.validateAiAffect;
const AiAffect = types.AiAffect;
const ConstAiAffectSlice = types.ConstAiAffectSlice;
const AiAffectSlice = types.AiAffectSlice;
const DestructibleStore = @import("destructible.zig").DestructibleStore;
const Destructible = types.Destructible;
const ConstDestructibleSlice = types.ConstDestructibleSlice;
const structural = @import("structural.zig");
const StructuralPlanScratch = structural.StructuralPlanScratch;
const NullStructuralChangeSink = structural.NullStructuralChangeSink;
const NullStructuralCommitPreparer = structural.NullStructuralCommitPreparer;
const EntitySimulationMetadata = @import("../simulation_scope.zig").EntitySimulationMetadata;
const cognition_stagger_n = @import("../simulation_scope.zig").cognition_stagger_n;
const keep_stagger_phase = @import("../simulation_scope.zig").keep_stagger_phase;
const SimulationScopeStats = @import("../simulation_scope.zig").SimulationScopeStats;
const SimulationTier = @import("../simulation_scope.zig").SimulationTier;
const simd = @import("../../core/simd.zig");

// `collisionBodyRefs`' result: a collider's movement row and world level.
const CollisionBodyRefs = struct {
    movement_body: u32,
    level: ?u16,
};

pub const DataSystem = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayList(EntitySlot) = .empty,
    first_free_slot: ?u32 = null,
    free_slot_count: usize = 0,
    // Live entity count per simulation tier, maintained incrementally on
    // create/destroy/metadata-change so the per-fixed-step scope stats are O(1)
    // instead of scanning every slot. Indexed by @backingInt(SimulationTier).
    tier_counts: [4]usize = .{ 0, 0, 0, 0 },
    /// Stamp of movement-row collision allowance. Zero is a packed epoch, not an
    /// unpacked marker. It moves when a tier crosses `allowsCollision`, and when a
    /// movement row is removed, because `swapRemove` can retarget that index.
    collision_allow_epoch: u64 = 0,
    /// Entities recorded with the epoch bump, generation included. Trigger refresh
    /// drains it. Step scratch: it starts empty and is not saved.
    collision_allow_records: std.ArrayList(EntityId) = .empty,
    movement_bodies: MovementBodyStore = .{},
    facings: FacingStore = .{},
    primitive_visuals: PrimitiveVisualStore = .{},
    asset_refs: AssetReferenceStore = .{},
    collision_bounds: CollisionBoundsStore = .{},
    collision_responses: CollisionResponseStore = .{},
    ai_agents: AiAgentStore = .{},
    steering_agents: SteeringAgentStore = .{},
    world_levels: WorldLevelStore = .{},
    factions: FactionStore = .{},
    ai_perceptions: PerceptionStore = .{},
    ai_memories: AiMemoryStore = .{},
    ai_affects: AiAffectStore = .{},
    destructibles: DestructibleStore = .{},

    pub fn init(allocator: std.mem.Allocator) DataSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DataSystem) void {
        self.destructibles.deinit(self.allocator);
        self.ai_affects.deinit(self.allocator);
        self.ai_memories.deinit(self.allocator);
        self.ai_perceptions.deinit(self.allocator);
        self.factions.deinit(self.allocator);
        self.world_levels.deinit(self.allocator);
        self.steering_agents.deinit(self.allocator);
        self.ai_agents.deinit(self.allocator);
        self.collision_responses.deinit(self.allocator);
        self.collision_bounds.deinit(self.allocator);
        self.asset_refs.deinit(self.allocator);
        self.primitive_visuals.deinit(self.allocator);
        self.facings.deinit(self.allocator);
        self.movement_bodies.deinit(self.allocator);
        self.collision_allow_records.deinit(self.allocator);
        self.slots.deinit(self.allocator);
        self.* = init(self.allocator);
    }

    /// O(1): each population-sized store's committed row count.
    pub fn populationRowCounts(self: *const DataSystem) types.PopulationRowCounts {
        return .{
            .movement_bodies = self.movement_bodies.len(),
            .steering_agents = self.steering_agents.len(),
            .ai_agents = self.ai_agents.len(),
            .collision_bounds = self.collision_bounds.len(),
            .ai_perceptions = self.ai_perceptions.len(),
            .ai_affects = self.ai_affects.len(),
        };
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

        // `u32` slot indices: exhausting them fails at this growth seam as `OutOfMemory`.
        if (self.slots.items.len >= std.math.maxInt(u32)) return error.OutOfMemory;
        const index: u32 = @intCast(self.slots.items.len);
        try self.slots.append(self.allocator, .{ .generation = 1, .alive = true });
        return EntityId.init(index, 1) catch unreachable;
    }

    pub fn destroyEntity(self: *DataSystem, id: EntityId) error{OutOfMemory}!bool {
        const slot = self.resolveSlot(id) orelse return false;
        const index = id.index;

        // Component stores stay dense. Removing an entity may swap the tail row
        // into this entity's dense index and patch that moved entity's slot.
        if (slot.movement_body_index) |dense_index| try self.removeMovementBodyAt(@intCast(dense_index));
        if (slot.facing_index) |dense_index| self.removeFacingAt(@intCast(dense_index));
        if (slot.primitive_visual_index) |dense_index| self.removePrimitiveVisualAt(@intCast(dense_index));
        if (slot.asset_ref_index) |dense_index| self.removeAssetReferenceAt(@intCast(dense_index));
        if (slot.collision_bounds_index) |dense_index| self.removeCollisionBoundsAt(@intCast(dense_index));
        if (slot.collision_response_index) |dense_index| self.removeCollisionResponseAt(@intCast(dense_index));
        if (slot.ai_agent_index) |dense_index| self.removeAiAgentAt(@intCast(dense_index));
        if (slot.steering_agent_index) |dense_index| self.removeSteeringAgentAt(@intCast(dense_index));
        if (slot.world_level_index) |dense_index| self.removeWorldLevelAt(@intCast(dense_index));
        if (slot.faction_index) |dense_index| self.removeFactionAt(@intCast(dense_index));
        if (slot.ai_perception_index) |dense_index| self.removeAiPerceptionAt(@intCast(dense_index));
        if (slot.ai_memory_index) |dense_index| self.removeAiMemoryAt(@intCast(dense_index));
        if (slot.ai_affect_index) |dense_index| self.removeAiAffectAt(@intCast(dense_index));
        if (slot.destructible_index) |dense_index| self.removeDestructibleAt(@intCast(dense_index));

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
        retired_slot.world_level_index = null;
        retired_slot.faction_index = null;
        retired_slot.ai_perception_index = null;
        retired_slot.ai_memory_index = null;
        retired_slot.ai_affect_index = null;
        retired_slot.destructible_index = null;
        self.first_free_slot = index;
        self.free_slot_count += 1;
        return true;
    }

    /// `errdefer` cleanup of an entity this call created. `OutOfMemory` leaves it
    /// alive; the caller's error stands.
    pub fn destroyCreatedEntity(self: *DataSystem, id: EntityId) void {
        const destroyed = self.destroyEntity(id) catch |err| {
            std.debug.assert(err == error.OutOfMemory);
            return;
        };
        _ = destroyed;
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

    /// Writes the full scope metadata for an entity into its dense scope row, keeping the
    /// row's stagger phase when `metadata.stagger_phase` is `keep_stagger_phase`. The level
    /// comes from the entity's `world_level` row when it has one, and a supplied level must
    /// match it; without one, a `null` level keeps the row's.
    /// Requires a movement body; returns error.InvalidEntity otherwise, and
    /// error.InvalidStaggerPhase for any other phase not below `cognition_stagger_n`.
    pub fn setSimulationMetadata(self: *DataSystem, id: EntityId, metadata: EntitySimulationMetadata) !void {
        try metadata.validate();
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        const di: usize = slot.movement_body_index orelse return error.InvalidEntity;
        const stored = self.movement_bodies.scopeMetadataAt(di);
        var resolved = metadata;
        if (resolved.stagger_phase == keep_stagger_phase) resolved.stagger_phase = stored.stagger_phase;
        std.debug.assert(resolved.stagger_phase < cognition_stagger_n);
        if (slot.world_level_index) |world_level_index| {
            const world_level = self.world_levels.get(@intCast(world_level_index));
            if (metadata.level) |level| std.debug.assert(level == world_level);
            resolved.level = world_level;
        } else if (resolved.level == null) resolved.level = stored.level;
        // The record lands before the tier, so a failed append leaves the row.
        try self.noteCollisionAllow(id, stored.tier, metadata.tier);
        self.tier_counts[@backingInt(stored.tier)] -= 1;
        self.tier_counts[@backingInt(metadata.tier)] += 1;
        const old_level = stored.level orelse 0;
        const new_level = resolved.level orelse old_level;
        const key_changed = old_level != new_level or stored.chunk.x != metadata.chunk.x or stored.chunk.y != metadata.chunk.y;
        // Tier lands before the retarget so a retry does not apply it twice. The chunk and level
        // land after the row is linked, so a failed retarget keeps the old key.
        if (key_changed) {
            var staged = resolved;
            staged.chunk = stored.chunk;
            staged.level = stored.level;
            self.movement_bodies.setScopeMetadata(di, staged);
            try self.movement_bodies.retargetDrawable(self.allocator, di, new_level, metadata.chunk.x, metadata.chunk.y);
        }
        self.movement_bodies.setScopeMetadata(di, resolved);
        try self.movement_bodies.reserveDrawableNeighborLevels(self.allocator, di);
        self.snapInterpolationIfStill(di, metadata.tier);
    }

    /// Changes an entity's simulation tier while preserving chunk, stagger_phase,
    /// and always_active. Processors must not call this inside worker ranges; use
    /// a .set_simulation_tier structural command for deferred tier changes.
    pub fn setSimulationTier(self: *DataSystem, id: EntityId, tier: SimulationTier) !void {
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        const di: usize = slot.movement_body_index orelse return error.InvalidEntity;
        const old_tier = self.movement_bodies.tierAt(di);
        // The record lands before the tier, so a failed append leaves the row.
        try self.noteCollisionAllow(id, old_tier, tier);
        self.tier_counts[@backingInt(old_tier)] -= 1;
        self.tier_counts[@backingInt(tier)] += 1;
        self.movement_bodies.setTier(di, tier);
        // chunk, stagger_phase, and always_active are intentionally preserved.
        self.snapInterpolationIfStill(di, tier);
    }

    // Dormant and kinematic are the tiers that do not allow collision. Locomotion
    // and cognition cross neither each other nor this stamp. The entity is recorded
    // before the bump; a failed append leaves the epoch and the tier alone.
    fn noteCollisionAllow(self: *DataSystem, id: EntityId, old_tier: SimulationTier, new_tier: SimulationTier) error{OutOfMemory}!void {
        if (old_tier.allowsCollision() == new_tier.allowsCollision()) return;
        try self.collision_allow_records.append(self.allocator, id);
        self.collision_allow_epoch +%= 1;
    }

    /// When an entity enters a non-moving tier, snap previous=position so render
    /// interpolation (lerp previous→position) does not oscillate, and zero its
    /// velocity. Zeroing is what lets the movement processor integrate the full
    /// contiguous SoA range every step: a non-moving row integrates as a no-op
    /// instead of drifting on a stale velocity, so movement needs no scattered
    /// skip-path. Velocity is re-established by AI intents when the row reactivates.
    fn snapInterpolationIfStill(self: *DataSystem, di: usize, tier: SimulationTier) void {
        if (tier.allowsMovement()) return;
        self.movement_bodies.snapPreviousToPosition(di);
        self.movement_bodies.zeroVelocity(di);
    }

    /// Mutable dense scope columns (chunk_x/y written in-pass by the movement processor).
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
        return self.tier_counts[@backingInt(tier)];
    }

    /// Current full-active scope counters. Tier histograms come from the
    /// incrementally-maintained `tier_counts` (O(1), no per-step slot scan); stage
    /// counts come free from dense slice lengths. The collision stage reads only the
    /// dynamic bounds rows (static obstacles live in the static colliders), the same set
    /// the scoped gather filters. `total_entities` is the count of entities carrying a
    /// simulation tier (i.e. those with a movement body), not the full live-entity set.
    pub fn simulationScopeStatsFullActive(self: *const DataSystem) SimulationScopeStats {
        return .{
            .total_entities = self.tier_counts[0] + self.tier_counts[1] + self.tier_counts[2] + self.tier_counts[3],
            .dormant_entities = self.tier_counts[@backingInt(SimulationTier.dormant)],
            .kinematic_entities = self.tier_counts[@backingInt(SimulationTier.kinematic)],
            .locomotion_entities = self.tier_counts[@backingInt(SimulationTier.locomotion)],
            .cognition_entities = self.tier_counts[@backingInt(SimulationTier.cognition)],
            .movement_stage_entities = self.movement_bodies.len(),
            .collision_stage_entities = self.collision_bounds.dynamic_ids.items.len,
            .collision_response_stage_entities = self.collision_responses.len(),
            .ai_stage_entities = self.ai_agents.len(),
            .steering_stage_entities = self.steering_agents.len(),
        };
    }

    pub fn isStaticNavigationObstacle(self: *const DataSystem, id: EntityId) bool {
        const obstacle_mask = component_masks.movement_body | component_masks.collision_bounds | component_masks.collision_response;
        if (!self.hasComponents(id, obstacle_mask)) return false;
        const response = self.collisionResponseConst(id) orelse return false;
        return response.mobility == .static;
    }

    /// The columns `staticObstacleAt` reads, sliced once. O(1).
    pub fn staticObstacleColumns(self: *const DataSystem) types.StaticObstacleColumns {
        const movement = self.movementBodySliceConst();
        const bounds = self.collisionBoundsSliceConst();
        return .{
            .position_x = movement.position_x,
            .position_y = movement.position_y,
            .offset_x = bounds.offset_x,
            .offset_y = bounds.offset_y,
            .size_x = bounds.size_x,
            .size_y = bounds.size_y,
            .mobilities = self.collisionResponseSliceConst().mobilities,
            .levels = self.worldLevelSliceConst().levels,
        };
    }

    /// The static navigation obstacle at entity slot `index` (below `slots.items.len`), under
    /// the slot's live id:
    /// a live slot with a movement body, collision bounds, and a static collision response,
    /// read through `columns` (`staticObstacleColumns`); null otherwise. Its rect is
    /// `math.aabbFromOffsetSize` of its position, offset and size, and its level
    /// `worldLevelConst`'s or 0. One slot read and one row read per store, no slice built;
    /// safe on workers while the stores are unchanged.
    pub fn staticObstacleAt(self: *const DataSystem, index: usize, columns: types.StaticObstacleColumns) ?types.StaticObstacle {
        const slot = &self.slots.items[index];
        if (!slot.alive) return null;
        const body = slot.movement_body_index orelse return null;
        const bounds = slot.collision_bounds_index orelse return null;
        const response = slot.collision_response_index orelse return null;
        if (columns.mobilities[response] != .static) return null;
        return .{
            // Entity slots stay below maxInt(u32), the invalid index.
            .entity = .{ .index = @intCast(index), .generation = slot.generation },
            .level = if (slot.world_level_index) |level| columns.levels[level] else 0,
            .x = columns.position_x[body],
            .y = columns.position_y[body],
            .offset_x = columns.offset_x[bounds],
            .offset_y = columns.offset_y[bounds],
            .size_x = columns.size_x[bounds],
            .size_y = columns.size_y[bounds],
        };
    }

    /// `staticObstacleAt` of `id`'s slot when `id` is live (its slot's generation); null for
    /// a stale or invalid id. O(1); safe on workers while the stores are unchanged.
    pub fn staticObstacle(self: *const DataSystem, id: EntityId, columns: types.StaticObstacleColumns) ?types.StaticObstacle {
        _ = self.resolveSlotConst(id) orelse return null;
        return self.staticObstacleAt(id.index, columns);
    }

    pub fn clearRetainingCapacity(self: *DataSystem) void {
        // Reset invalidates all existing IDs while keeping allocated component
        // columns warm for the next state/session.
        self.destructibles.clearRetainingCapacity();
        self.ai_affects.clearRetainingCapacity();
        self.ai_memories.clearRetainingCapacity();
        self.ai_perceptions.clearRetainingCapacity();
        self.factions.clearRetainingCapacity();
        self.world_levels.clearRetainingCapacity();
        self.steering_agents.clearRetainingCapacity();
        self.ai_agents.clearRetainingCapacity();
        self.asset_refs.clearRetainingCapacity();
        self.collision_bounds.clearRetainingCapacity();
        self.collision_responses.clearRetainingCapacity();
        self.primitive_visuals.clearRetainingCapacity();
        self.facings.clearRetainingCapacity();
        self.movement_bodies.clearRetainingCapacity();
        self.collision_allow_records.clearRetainingCapacity();

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
            slot.world_level_index = null;
            slot.faction_index = null;
            slot.ai_perception_index = null;
            slot.ai_memory_index = null;
            slot.ai_affect_index = null;
            slot.destructible_index = null;
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

        // Removal records this id and, when the row is not the tail, the id swapRemove
        // moves. Reserved before the append so that cleanup cannot allocate.
        try self.collision_allow_records.ensureTotalCapacity(self.allocator, self.collision_allow_records.items.len + 2);
        const dense_index = try self.movement_bodies.append(self.allocator, id, body);
        slot.movement_body_index = dense_index;
        slot.addComponent(.movement_body);
        // The new scope row defaults to .cognition (see MovementBodyStore.append).
        self.tier_counts[@backingInt(SimulationTier.cognition)] += 1;
        // A primitive-visual row may already exist for this entity (e.g. movement
        // body re-added after being destroyed while the visual persisted) — sync
        // the new row's flag so render collect doesn't skip it.
        if (slot.primitive_visual_index != null) {
            try self.movement_bodies.setHasPrimitiveVisual(self.allocator, @intCast(dense_index), true);
        }
        // Bounds and AI rows may already exist: the new row mirrors them for the world gate.
        if (slot.collision_bounds_index) |bounds_index| {
            self.movement_bodies.setCollisionBounds(dense_index, self.collision_bounds.get(@intCast(bounds_index)));
        }
        if (slot.ai_agent_index != null) self.movement_bodies.setHasAiAgent(dense_index, true);
        // A world-level row may already exist (setWorldLevel called first) —
        // sync it onto the new scope row.
        if (slot.world_level_index) |world_level_index| {
            const level = self.world_levels.get(@intCast(world_level_index));
            try self.syncScopeLevelFromWorldLevel(id, level);
        }
        // An existing body write does not change static membership. A new body can.
        self.syncDynamicBounds(id);
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

    /// `id`'s movement row from a stored `hint`: the hint while `entities[hint]` still names
    /// `id` (index and generation), else one slot resolve; null with no movement body.
    /// `entities` is the movement store's entity column the caller sliced once.
    pub fn movementBodyDenseIndexHinted(self: *const DataSystem, entities: []const EntityId, id: EntityId, hint: usize) ?usize {
        if (hint < entities.len and entities[hint].eql(id)) return hint;
        return self.movementBodyDenseIndex(id);
    }

    pub fn bodyLevelFaction(self: *const DataSystem, id: EntityId) ?BodyLevelFaction {
        const slot = self.resolveSlotConst(id) orelse return null;
        const movement_body = slot.movement_body_index orelse return null;
        return .{
            .movement_body = @intCast(movement_body),
            .level = if (slot.world_level_index) |index| self.world_levels.get(@intCast(index)) else null,
            .faction = if (slot.faction_index) |index| self.factions.factionAt(@intCast(index)) else null,
        };
    }

    /// A collider's movement row and world level (null without the component), read
    /// through the caller's `worldLevelSliceConst().levels`: one slot resolve per call and no
    /// store slice.
    pub fn collisionBodyRefs(self: *const DataSystem, id: EntityId, levels: []const u16) ?CollisionBodyRefs {
        const slot = self.resolveSlotConst(id) orelse return null;
        const movement_body = slot.movement_body_index orelse return null;
        return .{
            .movement_body = movement_body,
            .level = if (slot.world_level_index) |index| levels[index] else null,
        };
    }

    /// Drawable indices for a movement-body dense row. The movement index is the
    /// loop anchor for render collect and matches scope columns (`tier`, `chunk_*`).
    /// The caller passes the movement column slice it is already iterating and the
    /// primitive-visual row count (for the debug bounds assert) so this stays a pure
    /// slot resolve with no per-row MultiArrayList slice rebuild — the 11-column and
    /// 15-column rebuilds this used to do are dead work in the hot render-collect
    /// loop (and the 15-column rebuild only fed a bounds assert ReleaseFast strips).
    /// The caller has already confirmed `movement.has_primitive_visual[movement_index]`.
    pub fn renderCollectIndicesForMovement(
        self: *const DataSystem,
        movement: ConstMovementBodySlice,
        movement_index: usize,
        primitive_visual_count: usize,
    ) ?RenderCollectIndices {
        if (movement_index >= movement.entities.len) return null;
        const slot = self.resolveSlotConst(movement.entities[movement_index]) orelse return null;
        const visual_index = slot.primitive_visual_index orelse return null;
        std.debug.assert(visual_index < primitive_visual_count);
        return .{
            .visual_index = @intCast(visual_index),
            .asset_ref_index = if (slot.asset_ref_index) |index| @intCast(index) else null,
            .facing_index = if (slot.facing_index) |index| @intCast(index) else null,
        };
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
            self.facings.setDirection(@intCast(index), facing.direction);
            return;
        }

        const dense_index = try self.facings.append(self.allocator, id, facing);
        slot.facing_index = dense_index;
        slot.addComponent(.facing);
    }

    pub fn facingPtr(self: *DataSystem, id: EntityId) ?*Facing {
        const slot = self.resolveSlot(id) orelse return null;
        const dense_index = slot.facing_index orelse return null;
        return self.facings.directionPtr(@intCast(dense_index));
    }

    pub fn facingConst(self: *const DataSystem, id: EntityId) ?FacingData {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.facing_index orelse return null;
        return .{ .direction = self.facings.directionAt(@intCast(dense_index)) };
    }

    pub fn facingSliceConst(self: *const DataSystem) ConstFacingSlice {
        return self.facings.sliceConst();
    }

    pub fn setPrimitiveVisual(self: *DataSystem, id: EntityId, visual: PrimitiveVisual) !void {
        try validatePrimitiveVisual(visual);
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        if (slot.primitive_visual_index) |index| {
            self.primitive_visuals.set(@intCast(index), visual);
            if (slot.movement_body_index) |movement_index| {
                try self.movement_bodies.setHasPrimitiveVisual(self.allocator, @intCast(movement_index), true);
            }
            return;
        }

        const dense_index = try self.primitive_visuals.append(self.allocator, id, visual);
        slot.primitive_visual_index = dense_index;
        slot.addComponent(.primitive_visual);
        if (slot.movement_body_index) |movement_index| {
            try self.movement_bodies.setHasPrimitiveVisual(self.allocator, @intCast(movement_index), true);
        }
    }

    pub fn primitiveVisualConst(self: *const DataSystem, id: EntityId) ?PrimitiveVisual {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.primitive_visual_index orelse return null;
        return self.primitive_visuals.get(@intCast(dense_index));
    }

    pub fn primitiveVisualSliceConst(self: *const DataSystem) ConstPrimitiveVisualSlice {
        return self.primitive_visuals.sliceConst();
    }

    /// One slot resolve → dense movement + visual row indices for the plane-entry gather.
    /// Null if the entity is missing either component (or is not alive).
    pub fn movementVisualDenseIndices(self: *const DataSystem, id: EntityId) ?MovementVisualDenseIndices {
        const slot = self.resolveSlotConst(id) orelse return null;
        const movement = slot.movement_body_index orelse return null;
        const visual = slot.primitive_visual_index orelse return null;
        return .{
            .movement = @intCast(movement),
            .visual = @intCast(visual),
        };
    }

    /// One slot resolve → dense movement + steering-agent indices for steering select.
    /// Null if the entity is missing either component (or is not alive).
    pub fn movementSteeringDenseIndices(self: *const DataSystem, id: EntityId) ?MovementSteeringDenseIndices {
        const slot = self.resolveSlotConst(id) orelse return null;
        const movement = slot.movement_body_index orelse return null;
        const steering = slot.steering_agent_index orelse return null;
        return .{
            .movement = @intCast(movement),
            .steering = @intCast(steering),
        };
    }

    pub fn setAssetReference(self: *DataSystem, id: EntityId, asset_ref: AssetReference) !void {
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;

        if (slot.asset_ref_index) |index| {
            self.asset_refs.set(@intCast(index), asset_ref);
            return;
        }

        const dense_index = try self.asset_refs.append(self.allocator, id, asset_ref);
        slot.asset_ref_index = dense_index;
        slot.addComponent(.asset_reference);
    }

    pub fn assetReferenceSliceConst(self: *const DataSystem) ConstAssetReferenceSlice {
        return self.asset_refs.sliceConst();
    }

    pub fn setCollisionBounds(self: *DataSystem, id: EntityId, bounds: CollisionBounds) !void {
        try validateCollisionBounds(bounds);
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        if (slot.collision_bounds_index) |index| {
            self.collision_bounds.set(@intCast(index), bounds);
            if (slot.movement_body_index) |movement_index| self.movement_bodies.setCollisionBounds(movement_index, bounds);
            return;
        }

        const dense_index = try self.collision_bounds.append(self.allocator, id, bounds);
        slot.collision_bounds_index = dense_index;
        slot.addComponent(.collision_bounds);
        if (slot.movement_body_index) |movement_index| self.movement_bodies.setCollisionBounds(movement_index, bounds);
        // In-place size writes do not change membership. Append can complete a static obstacle.
        self.syncDynamicBounds(id);
    }

    pub fn collisionBoundsConst(self: *const DataSystem, id: EntityId) ?CollisionBounds {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.collision_bounds_index orelse return null;
        return self.collision_bounds.get(@intCast(dense_index));
    }

    pub fn collisionBoundsSliceConst(self: *const DataSystem) ConstCollisionBoundsSlice {
        return self.collision_bounds.sliceConst();
    }

    pub fn setCollisionResponse(self: *DataSystem, id: EntityId, response: CollisionResponse) !void {
        try validateCollisionResponse(response);
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        if (slot.collision_response_index) |index| {
            self.collision_responses.set(@intCast(index), response);
            self.syncDynamicBounds(id);
            return;
        }

        const dense_index = try self.collision_responses.append(self.allocator, id, response);
        slot.collision_response_index = dense_index;
        slot.addComponent(.collision_response);
        self.syncDynamicBounds(id);
    }

    pub fn collisionResponseConst(self: *const DataSystem, id: EntityId) ?CollisionResponse {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.collision_response_index orelse return null;
        return self.collision_responses.get(@intCast(dense_index));
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
        if (slot.movement_body_index) |movement_index| self.movement_bodies.setHasAiAgent(movement_index, true);
    }

    pub fn aiAgentSliceConst(self: *const DataSystem) ConstAiAgentSlice {
        return self.ai_agents.sliceConst();
    }

    /// Mutable hot-column view for arbitration's per-step sticky-selection
    /// write-back (active_behavior, commitment_remaining, last_score).
    pub fn aiAgentSlice(self: *DataSystem) AiAgentSlice {
        return self.ai_agents.slice();
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

    pub fn steeringAgentDenseIndex(self: *const DataSystem, id: EntityId) ?usize {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.steering_agent_index orelse return null;
        return @intCast(dense_index);
    }

    pub fn steeringAgentSliceConst(self: *const DataSystem) ConstSteeringAgentSlice {
        return self.steering_agents.sliceConst();
    }

    pub fn setWorldLevel(self: *DataSystem, id: EntityId, level: u16) !void {
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        if (slot.world_level_index) |index| {
            self.world_levels.set(@intCast(index), level);
        } else {
            const dense_index = try self.world_levels.append(self.allocator, id, level);
            slot.world_level_index = dense_index;
            slot.addComponent(.world_level);
        }
        try self.syncScopeLevelFromWorldLevel(id, level);
    }

    pub fn worldLevelConst(self: *const DataSystem, id: EntityId) ?u16 {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.world_level_index orelse return null;
        return self.world_levels.get(@intCast(dense_index));
    }

    pub fn worldLevelSliceConst(self: *const DataSystem) ConstWorldLevelSlice {
        return self.world_levels.sliceConst();
    }

    pub fn setFaction(self: *DataSystem, id: EntityId, entity_faction: Faction) !void {
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        if (slot.faction_index) |index| {
            self.factions.setFaction(@intCast(index), entity_faction);
            return;
        }

        const dense_index = try self.factions.append(self.allocator, id, entity_faction);
        slot.faction_index = dense_index;
        slot.addComponent(.faction);
    }

    pub fn factionConst(self: *const DataSystem, id: EntityId) ?Faction {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.faction_index orelse return null;
        return self.factions.factionAt(@intCast(dense_index));
    }

    pub fn setAiPerception(self: *DataSystem, id: EntityId, perception_value: AiPerception) !void {
        try validateAiPerception(perception_value);
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        if (slot.ai_perception_index) |index| {
            // Upsert on an existing row is a retune: PerceptionStore.set only
            // touches the cold tunables and preserves live hot sensing state.
            self.ai_perceptions.set(@intCast(index), perception_value);
            return;
        }

        const dense_index = try self.ai_perceptions.append(self.allocator, id, perception_value);
        slot.ai_perception_index = dense_index;
        slot.addComponent(.ai_perception);
    }

    pub fn aiPerceptionSliceConst(self: *const DataSystem) ConstPerceptionSlice {
        return self.ai_perceptions.sliceConst();
    }

    /// Dense `PerceptionStore` row index for `id`, or `null` when the entity
    /// carries no `AiPerception` component. Mirrors `movementBodyDenseIndex`;
    /// `PerceptionSystem`'s gather uses this to distinguish scoped AI agents
    /// that sense from those that do not.
    pub fn aiPerceptionDenseIndex(self: *const DataSystem, id: EntityId) ?usize {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.ai_perception_index orelse return null;
        return @intCast(dense_index);
    }

    /// Mutable hot-column view for PerceptionSystem's per-step sensed-state writes.
    pub fn perceptionSlice(self: *DataSystem) PerceptionSlice {
        return self.ai_perceptions.slice();
    }

    pub fn setAiMemory(self: *DataSystem, id: EntityId, memory_value: AiMemory) !void {
        try validateAiMemory(memory_value);
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        if (slot.ai_memory_index) |index| {
            self.ai_memories.set(@intCast(index), memory_value);
            return;
        }

        const dense_index = try self.ai_memories.append(self.allocator, id, memory_value);
        slot.ai_memory_index = dense_index;
        slot.addComponent(.ai_memory);
    }

    pub fn aiMemorySliceConst(self: *const DataSystem) ConstAiMemorySlice {
        return self.ai_memories.sliceConst();
    }

    /// Dense `AiMemoryStore` row index for `id`, or `null` when the entity
    /// carries no `AiMemory` component. Mirrors `aiPerceptionDenseIndex`.
    pub fn aiMemoryDenseIndex(self: *const DataSystem, id: EntityId) ?usize {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.ai_memory_index orelse return null;
        return @intCast(dense_index);
    }

    /// Mutable hot-column view for `AiMemorySystem`'s per-step refresh/decay writes.
    pub fn aiMemorySlice(self: *DataSystem) AiMemorySlice {
        return self.ai_memories.slice();
    }

    pub fn setAiAffect(self: *DataSystem, id: EntityId, affect_value: AiAffect) !void {
        try validateAiAffect(affect_value);
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        if (slot.ai_affect_index) |index| {
            // Upsert on an existing row is a retune: AiAffectStore.set only
            // touches the cold tunables and preserves live hot appraisal state.
            self.ai_affects.set(@intCast(index), affect_value);
            return;
        }

        const dense_index = try self.ai_affects.append(self.allocator, id, affect_value);
        slot.ai_affect_index = dense_index;
        slot.addComponent(.ai_affect);
    }

    pub fn aiAffectSliceConst(self: *const DataSystem) ConstAiAffectSlice {
        return self.ai_affects.sliceConst();
    }

    /// Dense `AiAffectStore` row index for `id`, or `null` when the entity
    /// carries no `AiAffect` component. Mirrors `aiMemoryDenseIndex`.
    pub fn aiAffectDenseIndex(self: *const DataSystem, id: EntityId) ?usize {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.ai_affect_index orelse return null;
        return @intCast(dense_index);
    }

    /// Mutable hot-column view for `AffectSystem`'s per-step appraisal writes.
    pub fn aiAffectSlice(self: *DataSystem) AiAffectSlice {
        return self.ai_affects.slice();
    }

    pub fn setDestructible(self: *DataSystem, id: EntityId, value: Destructible) !void {
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        if (slot.destructible_index) |index| {
            self.destructibles.set(@intCast(index), value);
            return;
        }

        const dense_index = try self.destructibles.append(self.allocator, id, value);
        slot.destructible_index = dense_index;
        slot.addComponent(.destructible);
    }

    pub fn destructibleConst(self: *const DataSystem, id: EntityId) ?Destructible {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.destructible_index orelse return null;
        return self.destructibles.get(@intCast(dense_index));
    }

    pub fn destructibleSliceConst(self: *const DataSystem) ConstDestructibleSlice {
        return self.destructibles.sliceConst();
    }

    // Rewrites only the scope row's level; the rest of the row is as stored.
    fn syncScopeLevelFromWorldLevel(self: *DataSystem, id: EntityId, level: u16) !void {
        const slot = self.resolveSlotConst(id) orelse return;
        const di: usize = slot.movement_body_index orelse return;
        var metadata = self.movement_bodies.scopeMetadataAt(di);
        if (metadata.level == level) return;
        // Level lands after the row is linked, so a failed retarget keeps the old level and a retry moves it.
        try self.movement_bodies.retargetDrawable(self.allocator, di, level, metadata.chunk.x, metadata.chunk.y);
        metadata.level = level;
        self.movement_bodies.setScopeMetadata(di, metadata);
        self.snapInterpolationIfStill(di, metadata.tier);
    }

    pub const applyStructuralCommands = structural.applyStructuralCommands;

    pub const applyStructuralCommandsWithChangeSink = structural.applyStructuralCommandsWithChangeSink;

    pub const applyStructuralCommandsPrepared = structural.applyStructuralCommandsPrepared;

    const preflightStructuralCommands = structural.preflightStructuralCommands;

    pub const validateStructuralCommands = structural.validateStructuralCommands;

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

    pub fn resolveSlotConst(self: *const DataSystem, id: EntityId) ?*const EntitySlot {
        if (!id.isValid()) return null;
        const index: usize = @intCast(id.index);
        if (index >= self.slots.items.len) return null;

        const slot = &self.slots.items[index];
        if (!slot.alive) return null;
        if (!id.matches(id.index, slot.generation)) return null;
        return slot;
    }

    fn removeMovementBodyAt(self: *DataSystem, index: usize) error{OutOfMemory}!void {
        // The scope tier row leaves with the movement body, so drop its tier count
        // before the swap overwrites it. The moved tail row keeps its own tier.
        // A later row may land on this index; stored trigger pairs re-read it.
        // Both ids are recorded before the bump and the removal; a failed reserve
        // leaves the epoch, the list, and the row.
        const entities = self.movement_bodies.sliceConst().entities;
        const removed = entities[index];
        const last = entities.len - 1;
        const tail: ?EntityId = if (index == last) null else entities[last];
        try self.collision_allow_records.ensureTotalCapacity(self.allocator, self.collision_allow_records.items.len + if (tail != null) @as(usize, 2) else 1);
        self.collision_allow_records.appendAssumeCapacity(removed);
        if (tail) |tail_id| self.collision_allow_records.appendAssumeCapacity(tail_id);
        self.collision_allow_epoch +%= 1;
        self.tier_counts[@backingInt(self.movement_bodies.tierAt(index))] -= 1;
        const bounds_index = self.slots.items[@intCast(removed.index)].collision_bounds_index;
        self.movement_bodies.unlinkDrawable(index);
        // Store removals swap the tail row into the removed row. If a row moved,
        // the moved entity's slot must be patched immediately.
        const moved = self.movement_bodies.removeAt(index);
        if (moved) |entity| {
            self.slots.items[@intCast(entity.index)].movement_body_index = @intCast(index);
            self.movement_bodies.retieDrawableMovementIndex(index);
        }
        // Losing the movement body ends a static obstacle. The bounds row stays.
        if (bounds_index) |dense| self.collision_bounds.addDynamic(dense);
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
        const removed = self.collision_responses.sliceConst().entities[index];
        const moved = self.collision_responses.removeAt(index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].collision_response_index = @intCast(index);
        // Bounds may already have been swap-removed (destroy drops bounds first). Only a row
        // that still belongs to this entity becomes dynamic.
        const slot = &self.slots.items[@intCast(removed.index)];
        const bounds_index = slot.collision_bounds_index orelse return;
        if (@as(usize, bounds_index) >= self.collision_bounds.len()) return;
        const bounds_entity = self.collision_bounds.sliceConst().entities[bounds_index];
        if (!bounds_entity.eql(removed)) return;
        self.collision_bounds.addDynamic(bounds_index);
    }

    fn syncDynamicBounds(self: *DataSystem, id: EntityId) void {
        const slot = self.resolveSlot(id) orelse return;
        const bounds_index = slot.collision_bounds_index orelse return;
        if (self.isStaticNavigationObstacle(id)) {
            self.collision_bounds.removeDynamic(bounds_index);
        } else {
            self.collision_bounds.addDynamic(bounds_index);
        }
    }

    fn removeAiAgentAt(self: *DataSystem, index: usize) void {
        const moved = self.ai_agents.removeAt(index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].ai_agent_index = @intCast(index);
    }

    fn removeSteeringAgentAt(self: *DataSystem, index: usize) void {
        const moved = self.steering_agents.removeAt(index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].steering_agent_index = @intCast(index);
    }

    fn removeWorldLevelAt(self: *DataSystem, index: usize) void {
        const moved = self.world_levels.removeAt(index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].world_level_index = @intCast(index);
    }

    fn removeFactionAt(self: *DataSystem, index: usize) void {
        const moved = self.factions.removeAt(index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].faction_index = @intCast(index);
    }

    fn removeAiPerceptionAt(self: *DataSystem, index: usize) void {
        const moved = self.ai_perceptions.removeAt(index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].ai_perception_index = @intCast(index);
    }

    fn removeAiMemoryAt(self: *DataSystem, index: usize) void {
        const moved = self.ai_memories.removeAt(index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].ai_memory_index = @intCast(index);
    }

    fn removeAiAffectAt(self: *DataSystem, index: usize) void {
        const moved = self.ai_affects.removeAt(index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].ai_affect_index = @intCast(index);
    }

    fn removeDestructibleAt(self: *DataSystem, index: usize) void {
        const moved = self.destructibles.removeAt(index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].destructible_index = @intCast(index);
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
    world_level_index: ?u32 = null,
    faction_index: ?u32 = null,
    ai_perception_index: ?u32 = null,
    ai_memory_index: ?u32 = null,
    ai_affect_index: ?u32 = null,
    destructible_index: ?u32 = null,

    fn addComponent(self: *EntitySlot, component: Component) void {
        self.component_mask |= componentMask(component);
    }

    fn hasComponents(self: EntitySlot, mask: ComponentMask) bool {
        return (self.component_mask & mask) == mask;
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
    try std.testing.expectEqual(slice.entities.len, slice.velocity_x.len);
    try std.testing.expectEqual(slice.entities.len, slice.velocity_y.len);
    try std.testing.expectEqual(slice.entities.len, slice.speed.len);
    try std.testing.expectEqual(slice.entities.len, slice.has_primitive_visual.len);
    try std.testing.expectEqual(slice.entities.len, slice.bounds_offset_x.len);
    try std.testing.expectEqual(slice.entities.len, slice.bounds_offset_y.len);
    try std.testing.expectEqual(slice.entities.len, slice.bounds_size_x.len);
    try std.testing.expectEqual(slice.entities.len, slice.bounds_size_y.len);
    try std.testing.expectEqual(slice.entities.len, slice.has_collision_bounds.len);
    try std.testing.expectEqual(slice.entities.len, slice.has_ai_agent.len);
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
}

fn expectCollisionResponseColumnsAligned(slice: ConstCollisionResponseSlice) !void {
    try std.testing.expectEqual(slice.entities.len, slice.modes.len);
    try std.testing.expectEqual(slice.entities.len, slice.mobilities.len);
    try std.testing.expectEqual(slice.entities.len, slice.restitution.len);
}

fn expectAiAgentColumnsAligned(slice: ConstAiAgentSlice) !void {
    try std.testing.expectEqual(slice.entities.len, slice.behaviors.len);
    try std.testing.expectEqual(slice.entities.len, slice.wander_amplitudes.len);
    try std.testing.expectEqual(slice.entities.len, slice.gain_wanders.len);
    try std.testing.expectEqual(slice.entities.len, slice.gain_pursues.len);
    try std.testing.expectEqual(slice.entities.len, slice.gain_flees.len);
    try std.testing.expectEqual(slice.entities.len, slice.gain_investigates.len);
    try std.testing.expectEqual(slice.entities.len, slice.gain_coheres.len);
    try std.testing.expectEqual(slice.entities.len, slice.commitment_max_steps.len);
    try std.testing.expectEqual(slice.entities.len, slice.sticky_bonus.len);
    try std.testing.expectEqual(slice.entities.len, slice.commitment_remaining.len);
    try std.testing.expectEqual(slice.entities.len, slice.last_score.len);
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
}

fn expectWorldLevelColumnsAligned(slice: ConstWorldLevelSlice) !void {
    try std.testing.expectEqual(slice.entities.len, slice.levels.len);
}

const data_test_support = @import("test_support.zig");

fn primitiveVisualDenseIndex(data: *const DataSystem, id: EntityId) ?usize {
    return data_test_support.rowOf(data, id, "primitive_visual_index");
}

fn collisionBoundsDenseIndex(data: *const DataSystem, id: EntityId) ?usize {
    return data_test_support.rowOf(data, id, "collision_bounds_index");
}

fn collisionResponseDenseIndex(data: *const DataSystem, id: EntityId) ?usize {
    return data_test_support.rowOf(data, id, "collision_response_index");
}

fn steeringAgent(data: *const DataSystem, id: EntityId) ?SteeringAgent {
    return data.steering_agents.get(data_test_support.rowOf(data, id, "steering_agent_index") orelse return null);
}

fn destructibleDenseIndex(data: *const DataSystem, id: EntityId) ?usize {
    return data_test_support.rowOf(data, id, "destructible_index");
}

/// Per-tier counts from an O(rows) scan of the dense scope tier column: the parity
/// baseline for the incrementally maintained `DataSystem.tier_counts`.
fn scanLiveTierCounts(data: *const DataSystem) [4]usize {
    var counts = [4]usize{ 0, 0, 0, 0 };
    for (data.movement_bodies.scopeSliceConst().tier) |tier| {
        counts[@backingInt(tier)] += 1;
    }
    return counts;
}

test "world level round-trips through set get ptr and dense slice" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    const second = try data.createEntity();
    const third = try data.createEntity();

    try data.setWorldLevel(first, 0);
    try data.setWorldLevel(second, 7);
    try data.setWorldLevel(third, 42);
    try data.setWorldLevel(first, 3);

    try std.testing.expectEqual(@as(?u16, 3), data.worldLevelConst(first));
    try std.testing.expectEqual(@as(?u16, 7), data.worldLevelConst(second));
    try std.testing.expectEqual(@as(?u16, 42), data.worldLevelConst(third));
    try std.testing.expect(data.hasComponents(first, component_masks.world_level));
    try std.testing.expect(data.hasComponents(second, component_masks.world_level));
    try std.testing.expect(!data.hasComponents(third, component_masks.movement_body));

    try data.setWorldLevel(second, 11);
    try std.testing.expectEqual(@as(?u16, 11), data.worldLevelConst(second));

    const slice = data.worldLevelSliceConst();
    try expectWorldLevelColumnsAligned(slice);
    try std.testing.expectEqual(@as(usize, 3), slice.entities.len);
    try std.testing.expectEqual(@as(u16, 3), slice.levels[0]);
    try std.testing.expectEqual(@as(u16, 11), slice.levels[1]);
    try std.testing.expectEqual(@as(u16, 42), slice.levels[2]);
}

test "world level via EntityTemplate defaults surface level and mask queries" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const commands = [_]StructuralCommand{
        .{ .create_entity = .{
            .movement_body = testBody(1),
            .world_level = 0,
        } },
        .{ .create_entity = .{
            .movement_body = testBody(2),
            .world_level = 9,
        } },
        .{ .set_world_level = .{ .entity = .invalid, .level = 1 } },
    };
    const stats = try data.applyStructuralCommands(commands[0..2]);
    try std.testing.expectEqual(@as(usize, 2), stats.created);
    try std.testing.expectEqual(@as(usize, 4), stats.components_set);

    const surface = data.movementBodySliceConst().entities[0];
    const deep = data.movementBodySliceConst().entities[1];
    try std.testing.expect(data.hasComponents(surface, component_masks.world_level | component_masks.movement_body));
    try std.testing.expectEqual(@as(u16, 0), data.worldLevelConst(surface).?);
    try std.testing.expectEqual(@as(u16, 9), data.worldLevelConst(deep).?);
}

test "setWorldLevel syncs simulation scope metadata level when movement body exists" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{});
    try data.setSimulationMetadata(entity, .{
        .tier = .locomotion,
        .chunk = .{ .x = 2, .y = -1 },
        .level = 0,
        .stagger_phase = 2,
    });
    try data.setWorldLevel(entity, 5);

    try std.testing.expectEqual(@as(u16, 5), data.worldLevelConst(entity).?);
    try std.testing.expectEqual(EntitySimulationMetadata{
        .tier = .locomotion,
        .chunk = .{ .x = 2, .y = -1 },
        .level = 5,
        .stagger_phase = 2,
    }, data_test_support.simulationMetadata(&data, entity).?);
    try std.testing.expectEqual(@as(u16, 5), data.scopeColumnsSliceConst().level[0]);

    try data.setWorldLevel(entity, 5);
    try std.testing.expectEqual(EntitySimulationMetadata{
        .tier = .locomotion,
        .chunk = .{ .x = 2, .y = -1 },
        .level = 5,
        .stagger_phase = 2,
    }, data_test_support.simulationMetadata(&data, entity).?);

    try data.setWorldLevel(entity, 8);
    try std.testing.expectEqual(@as(u16, 8), data.scopeColumnsSliceConst().level[0]);
}

test "setMovementBody syncs scope metadata level when world level already exists" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setWorldLevel(entity, 7);
    try std.testing.expectEqual(@as(u16, 7), data.worldLevelConst(entity).?);

    try data.setMovementBody(entity, .{});

    try std.testing.expectEqual(@as(u16, 7), data.worldLevelConst(entity).?);
    try std.testing.expectEqual(@as(u16, 7), data.scopeColumnsSliceConst().level[0]);
}

test "a hinted movement row is kept only while its row still names the entity" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const first = try data.createEntity();
    try data.setMovementBody(first, .{});
    const second = try data.createEntity();
    try data.setMovementBody(second, .{});
    const bodiless = try data.createEntity();
    try std.testing.expectEqual(@as(?usize, 1), data.movementBodyDenseIndexHinted(data.movementBodySliceConst().entities, second, 1));
    // A stale hint: the destroy swaps `second` onto row 0, and row 1 is past the column end.
    try std.testing.expect(try data.destroyEntity(first));
    const entities = data.movementBodySliceConst().entities;
    try std.testing.expectEqual(@as(?usize, 0), data.movementBodyDenseIndexHinted(entities, second, 1));
    // A hint naming another entity's row, and a destroyed id on its old row, resolve.
    const third = try data.createEntity();
    try data.setMovementBody(third, .{});
    const grown = data.movementBodySliceConst().entities;
    try std.testing.expectEqual(@as(?usize, 1), data.movementBodyDenseIndexHinted(grown, third, 0));
    try std.testing.expectEqual(@as(?usize, null), data.movementBodyDenseIndexHinted(grown, first, 0));
    try std.testing.expectEqual(@as(?usize, null), data.movementBodyDenseIndexHinted(grown, bodiless, 0));
}

test "entity generations reject stale ids after removal and reuse" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    try std.testing.expect(data.isAlive(first));
    try std.testing.expect(try data.destroyEntity(first));
    try std.testing.expect(!data.isAlive(first));

    const reused = try data.createEntity();
    try std.testing.expectEqual(first.index, reused.index);
    try std.testing.expect(reused.generation != first.generation);
    try std.testing.expect(data.isAlive(reused));
    try std.testing.expect(!(try data.destroyEntity(first)));
}

test "entity simulation metadata defaults and rejects stale ids" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    // Scope metadata lives on the dense movement-body scope row, so an entity
    // must have a movement body to carry it. Bodiless entities report null.
    const entity = try data.createEntity();
    try std.testing.expect(data_test_support.simulationMetadata(&data, entity) == null);
    try data.setMovementBody(entity, .{});
    try std.testing.expectEqual(EntitySimulationMetadata{ .level = 0, .stagger_phase = 0 }, data_test_support.simulationMetadata(&data, entity).?);
    try data.setSimulationMetadata(entity, .{
        .tier = .locomotion,
        .chunk = .{ .x = 4, .y = -2 },
        .level = 3,
    });
    try std.testing.expectEqual(EntitySimulationMetadata{
        .tier = .locomotion,
        .chunk = .{ .x = 4, .y = -2 },
        .level = 3,
        .stagger_phase = 0,
    }, data_test_support.simulationMetadata(&data, entity).?);
    // The scope columns view exposes the same level the metadata round-tripped.
    try std.testing.expectEqual(@as(u16, 3), data.scopeColumnsSliceConst().level[0]);

    try std.testing.expect(try data.destroyEntity(entity));
    try std.testing.expect(data_test_support.simulationMetadata(&data, entity) == null);
    try std.testing.expectError(error.InvalidEntity, data.setSimulationMetadata(entity, .{}));

    const reused = try data.createEntity();
    try std.testing.expectEqual(entity.index, reused.index);
    try data.setMovementBody(reused, .{});
    try std.testing.expectEqual(EntitySimulationMetadata{ .level = 0, .stagger_phase = 0 }, data_test_support.simulationMetadata(&data, reused).?);
}

test "a simulation metadata write keeps the row's stagger phase and level unless it names them" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    // Movement row 1's append-assigned phase is 1 % cognition_stagger_n.
    try data.setMovementBody(try data.createEntity(), .{});
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{});
    const appended_phase = data_test_support.simulationMetadata(&data, entity).?.stagger_phase;
    try std.testing.expectEqual(@as(u8, 1 % cognition_stagger_n), appended_phase);

    try data.setSimulationMetadata(entity, .{ .tier = .locomotion, .chunk = .{ .x = 3, .y = 1 }, .level = 2 });
    const kept = data_test_support.simulationMetadata(&data, entity).?;
    try std.testing.expectEqual(appended_phase, kept.stagger_phase);
    try std.testing.expectEqual(SimulationTier.locomotion, kept.tier);
    try std.testing.expectEqual(@as(u16, 2), kept.level);

    try data.setSimulationMetadata(entity, .{ .tier = .cognition, .stagger_phase = 3 });
    try std.testing.expectEqual(@as(u8, 3), data_test_support.simulationMetadata(&data, entity).?.stagger_phase);
    try std.testing.expectEqual(@as(?u16, 2), data_test_support.simulationMetadata(&data, entity).?.level);
    try data.setSimulationMetadata(entity, .{ .tier = .cognition });
    try std.testing.expectEqual(@as(u8, 3), data_test_support.simulationMetadata(&data, entity).?.stagger_phase);
    try std.testing.expectEqual(@as(?u16, 2), data_test_support.simulationMetadata(&data, entity).?.level);

    try std.testing.expectError(error.InvalidStaggerPhase, data.setSimulationMetadata(entity, .{ .stagger_phase = cognition_stagger_n }));
    try std.testing.expectEqual(@as(u8, 3), data_test_support.simulationMetadata(&data, entity).?.stagger_phase);
}

test "a simulation metadata write takes the level from the entity's world level row" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{});
    try data.setWorldLevel(entity, 5);
    try std.testing.expectEqual(@as(?u16, 5), data_test_support.simulationMetadata(&data, entity).?.level);

    // An omitted level reads the world-level row, never the field default.
    try data.setSimulationMetadata(entity, .{ .tier = .locomotion, .chunk = .{ .x = 2, .y = 7 } });
    try std.testing.expectEqual(@as(?u16, 5), data_test_support.simulationMetadata(&data, entity).?.level);
    try std.testing.expectEqual(@as(u16, 5), data.scopeColumnsSliceConst().level[0]);
    try data.setSimulationMetadata(entity, .{ .tier = .cognition, .level = 5 });
    try std.testing.expectEqual(@as(?u16, 5), data_test_support.simulationMetadata(&data, entity).?.level);

    // A later world-level move carries onto the row, and the next write keeps it.
    try data.setWorldLevel(entity, 0);
    try data.setSimulationMetadata(entity, .{ .tier = .kinematic });
    try std.testing.expectEqual(@as(?u16, 0), data_test_support.simulationMetadata(&data, entity).?.level);
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
    try std.testing.expectEqual(EntitySimulationMetadata{ .level = 0, .stagger_phase = 0 }, data_test_support.simulationMetadata(&data, reused).?);
}

test "createEntity fails past its u32 slot cap as OutOfMemory" {
    // Every request fails but none may reach the allocator: the cap check, not a failed
    // grow, must return the error.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    var data = DataSystem.init(failing.allocator());
    defer data.deinit();
    // The slot count set to the cap over no storage, then restored, so the check runs
    // without 2^32 real slots.
    data.slots.items.len = std.math.maxInt(u32);
    defer data.slots.items.len = 0;
    try std.testing.expectError(error.OutOfMemory, data.createEntity());
    try std.testing.expect(!failing.has_induced_failure);
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
    // A static obstacle: its bounds row is not in the collision stage's dynamic set.
    const wall = try data.createEntity();
    try data.setMovementBody(wall, .{});
    try data.setCollisionBounds(wall, .{ .size = .{ .x = 8, .y = 8 } });
    try data.setCollisionResponse(wall, .{ .mobility = .static });
    try data.setSimulationMetadata(wall, .{ .tier = .dormant });

    const stats = data.simulationScopeStatsFullActive();
    try std.testing.expectEqual(@as(usize, 4), stats.total_entities);
    try std.testing.expectEqual(@as(usize, 2), stats.dormant_entities);
    try std.testing.expectEqual(@as(usize, 1), stats.locomotion_entities);
    try std.testing.expectEqual(@as(usize, 1), stats.cognition_entities);
    try std.testing.expectEqual(data.movementBodySliceConst().entities.len, stats.movement_stage_entities);
    try std.testing.expectEqual(@as(usize, 2), data.collisionBoundsSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 1), stats.collision_stage_entities);
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

    try std.testing.expect(try data.destroyEntity(first));
    try std.testing.expect(try data.destroyEntity(second));
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

    try std.testing.expect(try data.destroyEntity(second));

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
        try std.testing.expectEqual(expected + 40, slice.velocity_x[index]);
        try std.testing.expectEqual(expected + 50, slice.velocity_y[index]);
        try std.testing.expectEqual(expected + 60, slice.speed[index]);
    }
}

test "removeMovementBodyAt reties a non-tail row that shares the drawable run" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const visual: PrimitiveVisual = .{
        .size = .{ .x = 1, .y = 1 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    };
    const first = try data.createEntity();
    const second = try data.createEntity();
    const third = try data.createEntity();
    try data.setMovementBody(first, .{});
    try data.setMovementBody(second, .{});
    try data.setMovementBody(third, .{});
    try data.setPrimitiveVisual(first, visual);
    try data.setPrimitiveVisual(second, visual);
    try data.setPrimitiveVisual(third, visual);

    // `second` is not the tail. The tail `third` shares its drawable run, so removal
    // swap-removes that tail into `second`'s row and must retie the run entry.
    try std.testing.expect(try data.destroyEntity(second));

    const run_index = data.movement_bodies.drawableRunIndex(0, 0, 0).?;
    const run = data.movement_bodies.drawableRunSlice(run_index);
    try std.testing.expectEqual(@as(usize, 2), run.entity.len);
    const movement = data.movementBodySliceConst();
    for (run.entity, run.movement_index) |entity, movement_index| {
        try std.testing.expect(movement_index < movement.entities.len);
        try std.testing.expect(movement.entities[movement_index].eql(entity));
    }
    try std.testing.expect(data.movementBodyConst(first) != null);
    try std.testing.expect(data.movementBodyConst(third) != null);
    try std.testing.expect(data.movementBodyConst(second) == null);
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
    try std.testing.expect(!data.hasComponents(entity, component_masks.movement_body | component_masks.facing | component_masks.primitive_visual));
    try std.testing.expect(!data.hasComponents(entity, component_masks.collision_bounds));
    try std.testing.expect(!data.hasComponents(entity, component_masks.collision_response));

    try data.setPrimitiveVisual(entity, testVisual());
    try data.setCollisionBounds(entity, testBounds(2));
    try data.setCollisionResponse(entity, testResponse(.solid, .dynamic, 0));
    try data.setAiAgent(entity, .{ .active_behavior = .wander });
    try data.setSteeringAgent(entity, testSteeringAgent(1));
    try std.testing.expect(data.hasComponents(entity, component_masks.movement_body | component_masks.facing | component_masks.primitive_visual));
    try std.testing.expect(data.hasComponents(entity, component_masks.collision_bounds));
    try std.testing.expect(data.hasComponents(entity, component_masks.collision_response));
    try std.testing.expect(data.hasComponents(entity, component_masks.ai_agent));
    try std.testing.expect(data.hasComponents(entity, component_masks.steering_agent));
    try std.testing.expectEqual(
        component_masks.movement_body | component_masks.facing | component_masks.primitive_visual | component_masks.collision_bounds | component_masks.collision_response | component_masks.ai_agent | component_masks.steering_agent,
        data.componentMaskFor(entity),
    );

    try std.testing.expect(try data.destroyEntity(entity));
    try std.testing.expectEqual(@as(ComponentMask, 0), data.componentMaskFor(entity));
    try std.testing.expect(!data.hasComponents(entity, component_masks.movement_body));
}

test "bodyLevelFaction matches movementBodyDenseIndex, worldLevelConst, and factionConst" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const bare = try data.createEntity();
    try data.setMovementBody(bare, testBody(1));
    const tagged = try data.createEntity();
    try data.setMovementBody(tagged, testBody(2));
    try data.setWorldLevel(tagged, 3);
    try data.setFaction(tagged, .hostile);
    const bodiless = try data.createEntity();
    try data.setWorldLevel(bodiless, 1);
    try data.setFaction(bodiless, .ally);
    const stale = try data.createEntity();
    try data.setMovementBody(stale, testBody(3));
    try std.testing.expect(try data.destroyEntity(stale));

    for ([_]EntityId{ bare, tagged }) |entity| {
        const found = data.bodyLevelFaction(entity).?;
        try std.testing.expectEqual(data.movementBodyDenseIndex(entity).?, found.movement_body);
        try std.testing.expectEqual(data.worldLevelConst(entity), found.level);
        try std.testing.expectEqual(data.factionConst(entity), found.faction);
    }
    try std.testing.expect(data.bodyLevelFaction(bare).?.level == null);
    try std.testing.expect(data.bodyLevelFaction(bare).?.faction == null);
    try std.testing.expectEqual(@as(?u16, 3), data.bodyLevelFaction(tagged).?.level);
    try std.testing.expect(data.bodyLevelFaction(bodiless) == null);
    try std.testing.expect(data.bodyLevelFaction(stale) == null);
    try std.testing.expect(data.bodyLevelFaction(EntityId.invalid) == null);
}

test "a static obstacle resolves only for a live slot with body, bounds, and a static response, by index and by id" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const bounds = CollisionBounds{ .offset = .{ .x = -2, .y = 3 }, .size = .{ .x = 5, .y = 7 } };
    const static_response = CollisionResponse{ .mobility = .static };

    const surface = try data.createEntity();
    try data.setMovementBody(surface, testBody(1));
    try data.setCollisionBounds(surface, bounds);
    try data.setCollisionResponse(surface, static_response);
    const leveled = try data.createEntity();
    try data.setWorldLevel(leveled, 4);
    try data.setMovementBody(leveled, testBody(2));
    try data.setCollisionBounds(leveled, bounds);
    try data.setCollisionResponse(leveled, static_response);
    const dynamic = try data.createEntity();
    try data.setMovementBody(dynamic, testBody(3));
    try data.setCollisionBounds(dynamic, bounds);
    try data.setCollisionResponse(dynamic, .{});
    const boundless = try data.createEntity();
    try data.setMovementBody(boundless, testBody(4));
    try data.setCollisionResponse(boundless, static_response);
    const bodiless = try data.createEntity();
    try data.setCollisionBounds(bodiless, bounds);
    try data.setCollisionResponse(bodiless, static_response);
    const responseless = try data.createEntity();
    try data.setMovementBody(responseless, testBody(5));
    try data.setCollisionBounds(responseless, bounds);
    const destroyed = try data.createEntity();
    try data.setMovementBody(destroyed, testBody(6));
    try data.setCollisionBounds(destroyed, bounds);
    try data.setCollisionResponse(destroyed, static_response);
    try std.testing.expect(try data.destroyEntity(destroyed));

    const columns = data.staticObstacleColumns();
    for ([_]EntityId{ surface, leveled }) |entity| {
        const found = data.staticObstacleAt(entity.index, columns).?;
        try std.testing.expect(found.entity.eql(entity));
        try std.testing.expectEqual(data.worldLevelConst(entity) orelse 0, found.level);
        try std.testing.expect(data.isStaticNavigationObstacle(entity));
        try std.testing.expectEqual(found, data.staticObstacle(entity, columns).?);
    }
    try std.testing.expectEqual(@as(u16, 0), data.staticObstacleAt(surface.index, columns).?.level);
    try std.testing.expectEqual(@as(u16, 4), data.staticObstacleAt(leveled.index, columns).?.level);
    for ([_]EntityId{ dynamic, boundless, bodiless, responseless, destroyed }) |entity| {
        try std.testing.expect(!data.isStaticNavigationObstacle(entity));
        try std.testing.expect(data.staticObstacleAt(entity.index, columns) == null);
        try std.testing.expect(data.staticObstacle(entity, columns) == null);
    }
    try std.testing.expect(data.staticObstacle(EntityId.invalid, columns) == null);
    // A reused slot resolves under its new id.
    const reused = try data.createEntity();
    try std.testing.expectEqual(destroyed.index, reused.index);
    try data.setMovementBody(reused, testBody(7));
    try data.setCollisionBounds(reused, bounds);
    try data.setCollisionResponse(reused, static_response);
    const refreshed = data.staticObstacleColumns();
    try std.testing.expect(data.staticObstacleAt(destroyed.index, refreshed).?.entity.eql(reused));
    // The destroyed id stays stale on the reused slot.
    try std.testing.expect(data.staticObstacle(destroyed, refreshed) == null);
    try std.testing.expect(data.staticObstacle(reused, refreshed).?.entity.eql(reused));
}

test "movementVisualDenseIndices resolves both rows from one slot lookup" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, testBody(1));
    try std.testing.expect(data.movementVisualDenseIndices(entity) == null);

    try data.setPrimitiveVisual(entity, .{
        .size = .{ .x = 16, .y = 16 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    });
    const indices = data.movementVisualDenseIndices(entity).?;
    try std.testing.expectEqual(@as(usize, 0), indices.movement);
    try std.testing.expectEqual(@as(usize, 0), indices.visual);
    try std.testing.expectEqual(data.movementBodyDenseIndex(entity).?, indices.movement);
    try std.testing.expectEqual(primitiveVisualDenseIndex(&data, entity).?, indices.visual);
    try std.testing.expect(data.movementVisualDenseIndices(EntityId.invalid) == null);
}

test "movementSteeringDenseIndices resolves both rows from one slot lookup" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, testBody(1));
    try std.testing.expect(data.movementSteeringDenseIndices(entity) == null);

    try data.setSteeringAgent(entity, .{});
    const indices = data.movementSteeringDenseIndices(entity).?;
    try std.testing.expectEqual(@as(usize, 0), indices.movement);
    try std.testing.expectEqual(@as(usize, 0), indices.steering);
    try std.testing.expectEqual(data.movementBodyDenseIndex(entity).?, indices.movement);
    try std.testing.expectEqual(data.steeringAgentDenseIndex(entity).?, indices.steering);
    try std.testing.expect(data.movementSteeringDenseIndices(EntityId.invalid) == null);
}

test "render collect indices resolve drawable rows from movement dense index" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, testBody(1));
    try data.setFacing(entity, .{ .direction = .left });
    try data.setPrimitiveVisual(entity, .{
        .size = .{ .x = 16, .y = 16 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    });
    try data.setAssetReference(entity, .{ .sprite = .demo_tile });

    const indices = data.renderCollectIndicesForMovement(
        data.movementBodySliceConst(),
        0,
        data.primitiveVisualSliceConst().entities.len,
    ).?;
    try std.testing.expectEqual(@as(usize, 0), indices.visual_index);
    try std.testing.expect(indices.asset_ref_index != null);
    try std.testing.expect(indices.facing_index != null);

    const movement_only = try data.createEntity();
    try data.setMovementBody(movement_only, testBody(2));
    try std.testing.expect(!data.movementBodySliceConst().has_primitive_visual[1]);
    try std.testing.expect(data.renderCollectIndicesForMovement(
        data.movementBodySliceConst(),
        1,
        data.primitiveVisualSliceConst().entities.len,
    ) == null);
    try std.testing.expect(data.renderCollectIndicesForMovement(
        data.movementBodySliceConst(),
        99,
        data.primitiveVisualSliceConst().entities.len,
    ) == null);

    _ = try data.destroyEntity(entity);
    try std.testing.expect(data.renderCollectIndicesForMovement(
        data.movementBodySliceConst(),
        0,
        data.primitiveVisualSliceConst().entities.len,
    ) == null);
    try std.testing.expect(data.movementBodySliceConst().entities.len == 1);
}

// Expects `id`'s movement row to mirror its collision bounds (zero without) and AI membership.
fn expectBoundsAndAiMirrored(data: *const DataSystem, id: EntityId) !void {
    const row = data.movementBodyDenseIndex(id).?;
    const movement = data.movementBodySliceConst();
    const bounds = data.collisionBoundsConst(id) orelse CollisionBounds{ .size = .{} };
    try std.testing.expectEqual(data.collisionBoundsConst(id) != null, movement.has_collision_bounds[row]);
    try std.testing.expectEqual(bounds.offset.x, movement.bounds_offset_x[row]);
    try std.testing.expectEqual(bounds.offset.y, movement.bounds_offset_y[row]);
    try std.testing.expectEqual(bounds.size.x, movement.bounds_size_x[row]);
    try std.testing.expectEqual(bounds.size.y, movement.bounds_size_y[row]);
    try std.testing.expectEqual(data.hasComponents(id, component_masks.ai_agent), movement.has_ai_agent[row]);
}

test "movement rows mirror collision bounds and AI membership through bounds set, movement append, AI append, and destroy" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    // Bounds and AI before the body: the movement append syncs both.
    const early = try data.createEntity();
    try data.setCollisionBounds(early, .{ .offset = .{ .x = 2, .y = 3 }, .size = .{ .x = 10, .y = 12 } });
    try data.setAiAgent(early, .{});
    try data.setMovementBody(early, testBody(1));
    try expectBoundsAndAiMirrored(&data, early);

    // Body first: the bounds append, the bounds rewrite, and the AI append each write the row.
    const late = try data.createEntity();
    try data.setMovementBody(late, testBody(2));
    try expectBoundsAndAiMirrored(&data, late);
    try data.setCollisionBounds(late, .{ .size = .{ .x = 4, .y = 5 } });
    try expectBoundsAndAiMirrored(&data, late);
    try data.setCollisionBounds(late, .{ .offset = .{ .x = -1, .y = 1 }, .size = .{ .x = 6, .y = 7 } });
    try expectBoundsAndAiMirrored(&data, late);
    try data.setAiAgent(late, .{});
    try expectBoundsAndAiMirrored(&data, late);

    // A plain body stays unbounded and non-AI.
    const plain = try data.createEntity();
    try data.setMovementBody(plain, testBody(3));
    try expectBoundsAndAiMirrored(&data, plain);

    // Destroying the first row swaps the tail row in with its mirrored columns.
    try std.testing.expect(try data.destroyEntity(early));
    try expectBoundsAndAiMirrored(&data, late);
    try expectBoundsAndAiMirrored(&data, plain);
    try std.testing.expect(try data.destroyEntity(late));
    try expectBoundsAndAiMirrored(&data, plain);
    try expectMovementBodyColumnsAligned(data.movementBodySliceConst());
}

test "setMovementBody syncs has_primitive_visual when the visual row already exists" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    // Primitive visual set before movement body — the reverse of the usual
    // template order. setMovementBody must still pick up the existing visual
    // row rather than leaving the new movement row's has_primitive_visual false.
    const entity = try data.createEntity();
    try data.setPrimitiveVisual(entity, .{
        .size = .{ .x = 16, .y = 16 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    });
    try data.setMovementBody(entity, testBody(1));

    try std.testing.expect(data.movementBodySliceConst().has_primitive_visual[0]);
    try std.testing.expect(data.renderCollectIndicesForMovement(
        data.movementBodySliceConst(),
        0,
        data.primitiveVisualSliceConst().entities.len,
    ) != null);
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

    try std.testing.expectEqual([_]f32{ 1, 2, 3, 4 }, simd.toFloatArray(simd.loadFloat4(slice.position_x[0..])));
    try std.testing.expectEqual([_]f32{ 11, 12, 13, 14 }, simd.toFloatArray(simd.loadFloat4(slice.position_y[0..])));
    try std.testing.expectEqual([_]f32{ 41, 42, 43, 44 }, simd.toFloatArray(simd.loadFloat4(slice.velocity_x[0..])));
    try std.testing.expectEqual([_]f32{ 61, 62, 63, 64 }, simd.toFloatArray(simd.loadFloat4(slice.speed[0..])));
}

test "movement hot store rounds capacity for cache-line range splitting" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    for (0..movement_range_alignment_items * 3 + 1) |index| {
        const entity = try data.createEntity();
        try data.setMovementBody(entity, testBody(@floatFromInt(index + 1)));
    }

    const slice = data.movementBodySliceConst();
    try expectMovementBodyColumnsAligned(slice);
    try std.testing.expectEqual(@as(usize, 16), movement_range_alignment_items);
    try std.testing.expectEqual(@as(usize, 0), (movement_range_alignment_items * @sizeOf(f32)) % hot_soa_column_alignment);
    try std.testing.expectEqual(@as(usize, movement_range_alignment_items * 3 + 1), slice.entities.len);
    try std.testing.expectEqual(@as(usize, movement_range_alignment_items * 4), hotStoreCapacity(slice.entities.len));
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

    try std.testing.expect(try data.destroyEntity(entity));
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

    try std.testing.expect(try data.destroyEntity(second));

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
    const asset_ref = data_test_support.assetReference(&data, entity).?;
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

    try std.testing.expect(try data.destroyEntity(second));
    const slice = data.collisionBoundsSliceConst();
    try expectCollisionBoundsColumnsAligned(slice);
    try std.testing.expectEqual(@as(usize, 2), slice.entities.len);
    try std.testing.expect(data.collisionBoundsConst(first) != null);
    try std.testing.expect(data.collisionBoundsConst(third) != null);
    try std.testing.expect(data.collisionBoundsConst(second) == null);
    try std.testing.expect(collisionBoundsDenseIndex(&data, first) != null);
    try std.testing.expect(collisionBoundsDenseIndex(&data, third) != null);
    try std.testing.expectEqual(@as(?usize, null), collisionBoundsDenseIndex(&data, second));
    try std.testing.expectEqual(first.index, slice.entities[collisionBoundsDenseIndex(&data, first).?].index);
    try std.testing.expectEqual(third.index, slice.entities[collisionBoundsDenseIndex(&data, third).?].index);
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

    try std.testing.expect(try data.destroyEntity(second));
    const slice = data.collisionResponseSliceConst();
    try expectCollisionResponseColumnsAligned(slice);
    try std.testing.expectEqual(@as(usize, 2), slice.entities.len);
    try std.testing.expect(data.collisionResponseConst(first) != null);
    try std.testing.expect(data.collisionResponseConst(third) != null);
    try std.testing.expect(data.collisionResponseConst(second) == null);
    try std.testing.expect(collisionResponseDenseIndex(&data, first) != null);
    try std.testing.expect(collisionResponseDenseIndex(&data, third) != null);
    try std.testing.expectEqual(@as(?usize, null), collisionResponseDenseIndex(&data, second));
    try std.testing.expectEqual(first.index, slice.entities[collisionResponseDenseIndex(&data, first).?].index);
    try std.testing.expectEqual(third.index, slice.entities[collisionResponseDenseIndex(&data, third).?].index);
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
            .ai_agent = .{ .active_behavior = .wander, .wander_amplitude = 42.0, .gain_pursue = 0.1 },
            .steering_agent = testSteeringAgent(1),
        } },
        .{ .set_movement_body = .{ .entity = existing, .body = testBody(3) } },
        .{ .set_facing = .{ .entity = existing, .facing = .{ .direction = .right } } },
        .{ .set_collision_bounds = .{ .entity = existing, .bounds = testBounds(8) } },
        .{ .set_collision_response = .{ .entity = existing, .response = testResponse(.bounce, .dynamic, 0.8) } },
        // First component-set for `existing`, so this is an append (not a retune):
        // the given active_behavior takes effect immediately.
        .{ .set_ai_agent = .{ .entity = existing, .agent = .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 0.75 } } },
        .{ .set_steering_agent = .{ .entity = existing, .agent = testSteeringAgent(2) } },
        .{ .set_faction = .{ .entity = existing, .faction = .hostile } },
    };

    const stats = try data.applyStructuralCommands(&commands);

    try std.testing.expectEqual(@as(usize, 1), stats.created);
    try std.testing.expectEqual(@as(usize, 0), stats.destroyed);
    try std.testing.expectEqual(@as(usize, 14), stats.components_set);
    try std.testing.expectEqual(@as(usize, 0), stats.stale_skipped);
    try std.testing.expectEqual(@as(usize, 2), data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(@as(f32, 3), data.movementBodyConst(existing).?.position.x);
    try std.testing.expectEqual(Facing.right, data.facingConst(existing).?.direction);
    try std.testing.expectEqual(@as(?Faction, .hostile), data.factionConst(existing));
    try std.testing.expectEqual(@as(f32, 8), data.collisionBoundsConst(existing).?.size.x);
    try std.testing.expectEqual(CollisionResponseMode.bounce, data.collisionResponseConst(existing).?.mode);
    const ai_slice = data.aiAgentSliceConst();
    try expectAiAgentColumnsAligned(ai_slice);
    try std.testing.expectEqual(@as(usize, 2), ai_slice.entities.len);
    const existing_ai = data_test_support.aiAgent(&data, existing).?;
    try std.testing.expectEqual(AiBehavior.pursue, existing_ai.active_behavior);
    try std.testing.expectEqual(@as(f32, 0.75), existing_ai.gain_pursue);
    try std.testing.expectEqual(@as(f32, 14), steeringAgent(&data, existing).?.agent_radius);
    // created one also has ai from template
    try std.testing.expect(data_test_support.aiAgent(&data, data.movementBodySliceConst().entities[0]) != null or data_test_support.aiAgent(&data, data.movementBodySliceConst().entities[1]) != null);
}

test "structural commands skip stale entities and preserve deterministic command order" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, testBody(1));
    const stale = entity;
    try std.testing.expect(try data.destroyEntity(entity));
    const replacement = try data.createEntity();

    const commands = [_]StructuralCommand{
        .{ .set_movement_body = .{ .entity = stale, .body = testBody(99) } },
        .{ .set_faction = .{ .entity = stale, .faction = .hostile } },
        .{ .set_movement_body = .{ .entity = replacement, .body = testBody(4) } },
        .{ .set_movement_body = .{ .entity = replacement, .body = testBody(5) } },
        .{ .destroy_entity = stale },
    };

    const stats = try data.applyStructuralCommands(&commands);

    try std.testing.expectEqual(@as(usize, 0), stats.created);
    try std.testing.expectEqual(@as(usize, 0), stats.destroyed);
    try std.testing.expectEqual(@as(usize, 2), stats.components_set);
    try std.testing.expectEqual(@as(usize, 3), stats.stale_skipped);
    try std.testing.expectEqual(@as(f32, 5), data.movementBodyConst(replacement).?.position.x);
    try std.testing.expectEqual(@as(?Faction, null), data.factionConst(stale));
}

test "ai agent component stores dense columns, supports template create and set/get, rejects invalid, compacts on destroy" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    const second = try data.createEntity();
    const third = try data.createEntity();
    try data.setAiAgent(first, .{ .active_behavior = .wander, .wander_amplitude = 12.5, .gain_pursue = 0 });
    try data.setAiAgent(second, .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 0.9 });
    try data.setAiAgent(third, .{ .active_behavior = .wander, .wander_amplitude = 99, .gain_pursue = 0.1 });
    // Retune of an existing row: only cold fields (wander_amplitude, gains)
    // change. active_behavior is hot and stays whatever the first append set.
    try data.setAiAgent(first, .{ .active_behavior = .pursue, .wander_amplitude = 7, .gain_pursue = 0.3 });

    const first_agent = data_test_support.aiAgent(&data, first).?;
    try std.testing.expectEqual(AiBehavior.wander, first_agent.active_behavior);
    try std.testing.expectEqual(@as(f32, 7), first_agent.wander_amplitude);
    try std.testing.expectEqual(@as(f32, 0.3), first_agent.gain_pursue);
    try std.testing.expectError(error.InvalidAiAgent, data.setAiAgent(first, .{ .wander_amplitude = -0.1 }));
    try std.testing.expectError(error.InvalidAiAgent, data.setAiAgent(first, .{ .gain_pursue = std.math.inf(f32) }));
    try std.testing.expectError(error.InvalidAiAgent, data.setAiAgent(first, .{ .wander_amplitude = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidAiAgent, data.setAiAgent(first, .{ .wander_amplitude = std.math.floatMax(f32) }));
    try std.testing.expectError(error.InvalidAiAgent, data.setAiAgent(first, .{ .gain_pursue = max_ai_gain + 1.0 }));
    try std.testing.expectError(error.InvalidAiAgent, data.setAiAgent(first, .{ .sticky_bonus = -0.1 }));
    try std.testing.expectError(error.InvalidAiAgent, data.setAiAgent(first, .{ .sticky_bonus = std.math.nan(f32) }));

    try std.testing.expect(try data.destroyEntity(second));
    const slice = data.aiAgentSliceConst();
    try expectAiAgentColumnsAligned(slice);
    try std.testing.expectEqual(@as(usize, 2), slice.entities.len);
    try std.testing.expect(data_test_support.aiAgent(&data, first) != null);
    try std.testing.expect(data_test_support.aiAgent(&data, third) != null);
    try std.testing.expect(data_test_support.aiAgent(&data, second) == null);
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

    const first_agent = steeringAgent(&data, first).?;
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
    try std.testing.expectError(error.InvalidSteeringAgent, data.setSteeringAgent(first, .{ .stuck_step_threshold = types.max_steering_cooldown_steps + 1 }));

    try std.testing.expect(try data.destroyEntity(second));
    const slice = data.steeringAgentSliceConst();
    try expectSteeringAgentColumnsAligned(slice);
    try std.testing.expectEqual(@as(usize, 2), slice.entities.len);
    try std.testing.expect(steeringAgent(&data, first) != null);
    try std.testing.expect(steeringAgent(&data, third) != null);
    try std.testing.expect(steeringAgent(&data, second) == null);
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
            .ai_agent = .{ .active_behavior = .wander, .wander_amplitude = 55, .gain_pursue = 0 },
            .steering_agent = testSteeringAgent(1),
        } },
    };
    _ = try data.applyStructuralCommands(&commands);

    const entity = data.movementBodySliceConst().entities[0];
    try std.testing.expect(data.hasComponents(entity, component_masks.ai_agent | component_masks.steering_agent | component_masks.movement_body));
    try std.testing.expect(!data.hasComponents(entity, component_masks.collision_response));
    const agent = data_test_support.aiAgent(&data, entity).?;
    try std.testing.expectEqual(AiBehavior.wander, agent.active_behavior);
    try std.testing.expectEqual(@as(f32, 55), agent.wander_amplitude);
    try std.testing.expectEqual(@as(f32, 13), steeringAgent(&data, entity).?.agent_radius);
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
    const asset_ref = data_test_support.assetReference(&data, entity).?;
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
            .ai_agent = .{ .active_behavior = .wander, .wander_amplitude = std.math.floatMax(f32), .gain_pursue = 0 },
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
    var preparer = NullStructuralCommitPreparer{};
    const stats = try data.applyStructuralCommandsPrepared(&commands, &scratch, &preparer, &sink);
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
    try std.testing.expect(try data.destroyEntity(seed));

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
    var preparer = NullStructuralCommitPreparer{};
    const stats = try data.applyStructuralCommandsPrepared(&commands, &scratch, &preparer, &sink);
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
        try std.testing.expect(try data.destroyEntity(entity));
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
    _ = try data.destroyEntity(e0); // was cognition (default)
    const e3 = try data.createEntity(); // reuses e0's slot at cognition
    try data.setMovementBody(e3, .{});
    try data.setSimulationMetadata(e3, .{ .tier = .locomotion });

    // The incrementally-maintained counters must equal a fresh live scan, and the
    // public scope stats must agree cell-for-cell.
    try std.testing.expectEqual(scanLiveTierCounts(&data), data.tier_counts);
    const stats = data.simulationScopeStatsFullActive();
    const scan = scanLiveTierCounts(&data);
    try std.testing.expectEqual(scan[@backingInt(SimulationTier.dormant)], stats.dormant_entities);
    try std.testing.expectEqual(scan[@backingInt(SimulationTier.kinematic)], stats.kinematic_entities);
    try std.testing.expectEqual(scan[@backingInt(SimulationTier.locomotion)], stats.locomotion_entities);
    try std.testing.expectEqual(scan[@backingInt(SimulationTier.cognition)], stats.cognition_entities);
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
    const orig = data_test_support.simulationMetadata(&data, entity).?;
    const orig_chunk = orig.chunk;
    const orig_phase = orig.stagger_phase;

    try data.setSimulationTier(entity, .locomotion);
    const updated = data_test_support.simulationMetadata(&data, entity).?;

    try std.testing.expectEqual(SimulationTier.locomotion, updated.tier);
    try std.testing.expectEqual(orig_chunk, updated.chunk);
    try std.testing.expectEqual(orig_phase, updated.stagger_phase);
    try std.testing.expectEqual(scanLiveTierCounts(&data), data.tier_counts);
}

test "structural command set_simulation_tier commits and skips stale entities" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const alive = try data.createEntity();
    try data.setMovementBody(alive, .{});
    const dead = try data.createEntity();
    _ = try data.destroyEntity(dead);
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
    try std.testing.expectEqual(SimulationTier.dormant, data_test_support.simulationMetadata(&data, alive).?.tier);
    try std.testing.expectEqual(@as(?EntitySimulationMetadata, null), data_test_support.simulationMetadata(&data, bodiless));
    try std.testing.expectEqual(scanLiveTierCounts(&data), data.tier_counts);
}

test "entering a non-moving tier snaps interpolation history to position" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{ .x = 100, .y = 200 } });
    const di = data.movementBodyDenseIndex(entity).?;
    // Diverge previous from position, as a mid-flight integration would leave it.
    var slice = data.movementBodySlice();
    slice.previous_x[di] = 10;
    slice.previous_y[di] = 20;

    // Non-moving tier snaps previous = position so render interpolation is static.
    try data.setSimulationTier(entity, .dormant);
    const after_dormant = data.movementBodySliceConst();
    try std.testing.expectEqual(@as(f32, 100), after_dormant.previous_x[di]);
    try std.testing.expectEqual(@as(f32, 200), after_dormant.previous_y[di]);

    // A moving tier leaves the history untouched (movement will resync it).
    slice = data.movementBodySlice();
    slice.previous_x[di] = 10;
    try data.setSimulationTier(entity, .cognition);
    try std.testing.expectEqual(@as(f32, 10), data.movementBodySliceConst().previous_x[di]);
}

test "a movement body append then a failed set leaves the entity not alive" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{ .x = 1, .y = 1 } });
    try std.testing.expect(data.isAlive(entity));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    data.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, data.setWorldLevel(entity, 3));
    data.destroyCreatedEntity(entity);
    try std.testing.expect(!data.isAlive(entity));
    try std.testing.expectEqual(@as(?usize, null), data.movementBodyDenseIndex(entity));
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "destroying a non-tail movement row allocates nothing once two allow records are reserved" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const first = try data.createEntity();
    const second = try data.createEntity();
    try data.setMovementBody(first, .{ .position = .{ .x = 1, .y = 0 } });
    try data.setMovementBody(second, .{ .position = .{ .x = 2, .y = 0 } });
    try std.testing.expectEqual(@as(usize, 0), data.movementBodyDenseIndex(first).?);
    try std.testing.expectEqual(@as(usize, 1), data.movementBodyDenseIndex(second).?);
    try data.collision_allow_records.ensureTotalCapacity(std.testing.allocator, data.collision_allow_records.items.len + 2);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    data.allocator = failing.allocator();
    try std.testing.expect(try data.destroyEntity(first));
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!data.isAlive(first));
    try std.testing.expect(data.isAlive(second));
    try std.testing.expectEqual(@as(usize, 0), data.movementBodyDenseIndex(second).?);
    try std.testing.expectEqual(@as(usize, 2), data.collision_allow_records.items.len);
}

test "faction round-trips through set get ptr and dense slice" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    const second = try data.createEntity();
    const third = try data.createEntity();

    try data.setFaction(first, .neutral);
    try data.setFaction(second, .ally);
    try data.setFaction(third, .hostile);
    try data.setFaction(first, .player);

    try std.testing.expectEqual(@as(?Faction, .player), data.factionConst(first));
    try std.testing.expectEqual(@as(?Faction, .ally), data.factionConst(second));
    try std.testing.expectEqual(@as(?Faction, .hostile), data.factionConst(third));
    try std.testing.expect(data.hasComponents(first, component_masks.faction));
    try std.testing.expect(data.hasComponents(second, component_masks.faction));
    try std.testing.expect(!data.hasComponents(third, component_masks.movement_body));

    try data.setFaction(second, .hostile);
    try std.testing.expectEqual(@as(?Faction, .hostile), data.factionConst(second));

    const rows = data.factions.rows.slice();
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(Faction.player, rows.items(.faction)[0]);
    try std.testing.expectEqual(Faction.hostile, rows.items(.faction)[1]);
    try std.testing.expectEqual(Faction.hostile, rows.items(.faction)[2]);
}

test "faction via EntityTemplate in structural create and mask queries" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const commands = [_]StructuralCommand{
        .{ .create_entity = .{
            .movement_body = testBody(1),
            .faction = .hostile,
        } },
    };
    _ = try data.applyStructuralCommands(&commands);

    const entity = data.movementBodySliceConst().entities[0];
    try std.testing.expect(data.hasComponents(entity, component_masks.faction | component_masks.movement_body));
    try std.testing.expectEqual(@as(?Faction, .hostile), data.factionConst(entity));
}

test "faction store is columnar and compact after removal" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    const second = try data.createEntity();
    const third = try data.createEntity();
    try data.setFaction(first, .player);
    try data.setFaction(second, .ally);
    try data.setFaction(third, .hostile);

    try std.testing.expect(try data.destroyEntity(second));

    const rows = data.factions.rows.slice();
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    for (rows.items(.entity), rows.items(.faction)) |entity, faction| {
        const expected: Faction = if (entity.matches(first.index, first.generation)) .player else .hostile;
        try std.testing.expectEqual(expected, faction);
    }

    // The swap-remove moved `third` into `second`'s old dense slot; resolving
    // it back through its EntitySlot proves removeFactionAt fixed up the
    // slot's faction_index rather than just leaving the dense columns paired.
    try std.testing.expectEqual(@as(?Faction, .hostile), data.factionConst(third));
}

test "faction survives entity destruction and reuse with generational correctness" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const original = try data.createEntity();
    try data.setFaction(original, .hostile);
    try std.testing.expect(try data.destroyEntity(original));

    // Stale ID no longer resolves once the slot's generation advances.
    try std.testing.expectEqual(@as(?Faction, null), data.factionConst(original));

    const reused = try data.createEntity();
    try std.testing.expectEqual(original.index, reused.index);
    try std.testing.expect(reused.generation != original.generation);
    try std.testing.expectEqual(@as(?Faction, null), data.factionConst(reused));

    try data.setFaction(reused, .ally);
    try std.testing.expectEqual(@as(?Faction, .ally), data.factionConst(reused));
    try std.testing.expectEqual(@as(?Faction, null), data.factionConst(original));
}

test "ai perception round-trips through set/get and rejects invalid tunables" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    const second = try data.createEntity();
    try data.setAiPerception(first, .{ .vision_range = 150, .fov_half_angle_radians = 0.4 });
    try data.setAiPerception(second, .{ .vision_range = 300, .fov_half_angle_radians = 0.9 });

    const first_perception = data_test_support.aiPerception(&data, first).?;
    try std.testing.expectEqual(@as(f32, 150), first_perception.vision_range);
    try std.testing.expectEqual(@as(f32, 0.4), first_perception.fov_half_angle_radians);
    try std.testing.expect(!first_perception.target_visible);
    try std.testing.expectEqual(EntityId.invalid, first_perception.nearest_threat);
    try std.testing.expectEqual(std.math.inf(f32), first_perception.nearest_threat_dist);
    try std.testing.expect(data.hasComponents(first, component_masks.ai_perception));

    try std.testing.expectError(error.InvalidAiPerception, data.setAiPerception(first, .{ .vision_range = 0 }));
    try std.testing.expectError(error.InvalidAiPerception, data.setAiPerception(first, .{ .vision_range = max_ai_perception_vision_range + 1 }));
    try std.testing.expectError(error.InvalidAiPerception, data.setAiPerception(first, .{ .fov_half_angle_radians = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidAiPerception, data.setAiPerception(first, .{ .fov_half_angle_radians = (std.math.pi / 2.0) + 0.1 }));
}

test "ai perception retune through setAiPerception preserves hot sensing state" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    const threat = try data.createEntity();
    try data.setAiPerception(entity, .{ .vision_range = 200, .fov_half_angle_radians = 0.5 });

    // PerceptionSystem-style write of live hot sensing state through the
    // mutable slice, ahead of a later stat retune.
    const live = data.perceptionSlice();
    const dense_index = live.entities.len - 1;
    live.target_visible[dense_index] = true;
    live.last_seen_x[dense_index] = 10;
    live.last_seen_y[dense_index] = 20;
    live.nearest_threat[dense_index] = threat;
    live.nearest_threat_dist[dense_index] = 33.0;
    live.facing_x[dense_index] = 0;
    live.facing_y[dense_index] = 1;

    // A retune (same entity, new cold tunables) must not wipe the hot state above.
    try data.setAiPerception(entity, .{ .vision_range = 400, .fov_half_angle_radians = 1.0 });

    const after = data_test_support.aiPerception(&data, entity).?;
    try std.testing.expectEqual(@as(f32, 400), after.vision_range);
    try std.testing.expectEqual(@as(f32, 1.0), after.fov_half_angle_radians);
    try std.testing.expectApproxEqAbs(@cos(@as(f32, 1.0)), after.cos_half_fov, 1e-6);
    try std.testing.expect(after.target_visible);
    try std.testing.expectEqual(@as(f32, 10), after.last_seen_x);
    try std.testing.expectEqual(@as(f32, 20), after.last_seen_y);
    try std.testing.expectEqual(threat, after.nearest_threat);
    try std.testing.expectEqual(@as(f32, 33.0), after.nearest_threat_dist);
    try std.testing.expectEqual(@as(f32, 0), after.facing_x);
    try std.testing.expectEqual(@as(f32, 1), after.facing_y);
}

test "ai perception via EntityTemplate in structural create and mask queries" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const commands = [_]StructuralCommand{
        .{ .create_entity = .{
            .movement_body = testBody(1),
            .ai_perception = .{ .vision_range = 320, .fov_half_angle_radians = 0.6 },
        } },
    };
    _ = try data.applyStructuralCommands(&commands);

    const entity = data.movementBodySliceConst().entities[0];
    try std.testing.expect(data.hasComponents(entity, component_masks.ai_perception | component_masks.movement_body));
    try std.testing.expectEqual(@as(f32, 320), data_test_support.aiPerception(&data, entity).?.vision_range);
}

test "structural command commit sets ai_perception without allocating after preflight reserves capacity" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const commands = [_]StructuralCommand{
        .{ .create_entity = .{
            .movement_body = testBody(1),
            .ai_perception = .{ .vision_range = 128, .fov_half_angle_radians = 0.3 },
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
    var preparer = NullStructuralCommitPreparer{};
    const stats = try data.applyStructuralCommandsPrepared(&commands, &scratch, &preparer, &sink);
    try std.testing.expectEqual(@as(usize, 1), stats.created);
    try std.testing.expectEqual(@as(usize, 2), stats.components_set);
    const entity = data.movementBodySliceConst().entities[0];
    try std.testing.expectEqual(@as(f32, 128), data_test_support.aiPerception(&data, entity).?.vision_range);
}

test "ai perception store is columnar and compact after removal" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    const second = try data.createEntity();
    const third = try data.createEntity();
    try data.setAiPerception(first, .{ .vision_range = 100 });
    try data.setAiPerception(second, .{ .vision_range = 200 });
    try data.setAiPerception(third, .{ .vision_range = 300 });

    try std.testing.expect(try data.destroyEntity(second));

    const slice = data.aiPerceptionSliceConst();
    try std.testing.expectEqual(slice.entities.len, slice.vision_range.len);
    try std.testing.expectEqual(@as(usize, 2), slice.entities.len);

    // The swap-remove moved `third` into `second`'s old dense slot; resolving
    // it back through its EntitySlot proves removeAiPerceptionAt fixed up the
    // slot's ai_perception_index rather than just leaving the dense columns paired.
    try std.testing.expectEqual(@as(f32, 300), data_test_support.aiPerception(&data, third).?.vision_range);
}

test "ai perception survives entity destruction and reuse with generational correctness" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const original = try data.createEntity();
    try data.setAiPerception(original, .{ .vision_range = 111 });
    try std.testing.expect(try data.destroyEntity(original));

    try std.testing.expectEqual(@as(?AiPerception, null), data_test_support.aiPerception(&data, original));

    const reused = try data.createEntity();
    try std.testing.expectEqual(original.index, reused.index);
    try std.testing.expect(reused.generation != original.generation);
    try std.testing.expectEqual(@as(?AiPerception, null), data_test_support.aiPerception(&data, reused));

    try data.setAiPerception(reused, .{ .vision_range = 222 });
    try std.testing.expectEqual(@as(f32, 222), data_test_support.aiPerception(&data, reused).?.vision_range);
    try std.testing.expectEqual(@as(?AiPerception, null), data_test_support.aiPerception(&data, original));
}

test "ai memory round-trips through set/get and rejects invalid fields" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    const target = try data.createEntity();
    try data.setAiMemory(first, .{ .last_known_target = target, .last_known_x = 5, .last_known_y = 9, .staleness = 12, .familiarity = 0.4 });

    const stored = data_test_support.aiMemory(&data, first).?;
    try std.testing.expectEqual(target, stored.last_known_target);
    try std.testing.expectEqual(@as(f32, 5), stored.last_known_x);
    try std.testing.expectEqual(@as(f32, 9), stored.last_known_y);
    try std.testing.expectEqual(@as(f32, 12), stored.staleness);
    try std.testing.expectEqual(@as(f32, 0.4), stored.familiarity);
    try std.testing.expect(data.hasComponents(first, component_masks.ai_memory));

    try std.testing.expectError(error.InvalidAiMemory, data.setAiMemory(first, .{ .staleness = -1 }));
    try std.testing.expectError(error.InvalidAiMemory, data.setAiMemory(first, .{ .familiarity = 2 }));
    try std.testing.expectError(error.InvalidAiMemory, data.setAiMemory(first, .{ .ring_next_slot = 4 }));
}

test "ai memory store is columnar and compact after removal" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    const second = try data.createEntity();
    const third = try data.createEntity();
    try data.setAiMemory(first, .{ .staleness = 100 });
    try data.setAiMemory(second, .{ .staleness = 200 });
    try data.setAiMemory(third, .{ .staleness = 300 });

    try std.testing.expect(try data.destroyEntity(second));

    const slice = data.aiMemorySliceConst();
    try std.testing.expectEqual(slice.entities.len, slice.staleness.len);
    try std.testing.expectEqual(@as(usize, 2), slice.entities.len);

    // The swap-remove moved `third` into `second`'s old dense slot; resolving
    // it back through its EntitySlot proves removeAiMemoryAt fixed up the
    // slot's ai_memory_index rather than just leaving the dense columns paired.
    try std.testing.expectEqual(@as(f32, 300), data_test_support.aiMemory(&data, third).?.staleness);
}

test "ai memory survives entity destruction and reuse with generational correctness" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const original = try data.createEntity();
    try data.setAiMemory(original, .{ .staleness = 111 });
    try std.testing.expect(try data.destroyEntity(original));

    try std.testing.expectEqual(@as(?AiMemory, null), data_test_support.aiMemory(&data, original));

    const reused = try data.createEntity();
    try std.testing.expectEqual(original.index, reused.index);
    try std.testing.expect(reused.generation != original.generation);
    try std.testing.expectEqual(@as(?AiMemory, null), data_test_support.aiMemory(&data, reused));

    try data.setAiMemory(reused, .{ .staleness = 222 });
    try std.testing.expectEqual(@as(f32, 222), data_test_support.aiMemory(&data, reused).?.staleness);
    try std.testing.expectEqual(@as(?AiMemory, null), data_test_support.aiMemory(&data, original));
}

test "destructible round-trips through set/get and clears on destroy" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    try data.setDestructible(first, .{ .hit_points = 3, .destroy_on_interact = false });
    try std.testing.expect(data.hasComponents(first, component_masks.destructible));
    try std.testing.expectEqual(@as(u8, 3), data.destructibleConst(first).?.hit_points);
    try std.testing.expect(!data.destructibleConst(first).?.destroy_on_interact);

    try data.setDestructible(first, .{ .hit_points = 1 });
    try std.testing.expectEqual(@as(u8, 1), data.destructibleConst(first).?.hit_points);
    try std.testing.expect(data.destructibleConst(first).?.destroy_on_interact);

    try std.testing.expect(try data.destroyEntity(first));
    try std.testing.expectEqual(@as(?Destructible, null), data.destructibleConst(first));
}

test "destructible store is columnar and compact after removal" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    const second = try data.createEntity();
    const third = try data.createEntity();
    try data.setDestructible(first, .{ .hit_points = 1 });
    try data.setDestructible(second, .{ .hit_points = 2 });
    try data.setDestructible(third, .{ .hit_points = 3 });

    try std.testing.expect(try data.destroyEntity(second));

    const slice = data.destructibleSliceConst();
    try std.testing.expectEqual(slice.entities.len, slice.hit_points.len);
    try std.testing.expectEqual(@as(usize, 2), slice.entities.len);

    // The swap-remove moved `third` into `second`'s old dense slot; resolving
    // it back through its EntitySlot proves removeDestructibleAt fixed up the
    // slot's destructible_index rather than just leaving the dense columns paired.
    try std.testing.expectEqual(@as(u8, 3), data.destructibleConst(third).?.hit_points);
    try std.testing.expectEqual(@as(?usize, null), destructibleDenseIndex(&data, second));
    try std.testing.expect(destructibleDenseIndex(&data, third) != null);
}

test "ai affect round-trips through set/get, retunes cold-only, and rejects invalid fields" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    try data.setAiAffect(first, .{ .baseline_fear = 0.2, .decay_rate_fear = 0.1, .threshold_fear = 0.5 });

    const stored = data_test_support.aiAffect(&data, first).?;
    try std.testing.expectEqual(@as(f32, 0.2), stored.baseline_fear);
    try std.testing.expectEqual(@as(f32, 0.1), stored.decay_rate_fear);
    try std.testing.expectEqual(@as(f32, 0.5), stored.threshold_fear);
    try std.testing.expect(data.hasComponents(first, component_masks.ai_affect));

    // A retune upsert only overwrites cold tunables, mirroring aiPerception's set().
    var live = data.aiAffectSlice();
    const dense = data.aiAffectDenseIndex(first).?;
    live.fear[dense] = 0.9;
    try data.setAiAffect(first, .{ .baseline_fear = 0.7 });
    try std.testing.expectEqual(@as(f32, 0.7), data_test_support.aiAffect(&data, first).?.baseline_fear);
    try std.testing.expectEqual(@as(f32, 0.9), data_test_support.aiAffect(&data, first).?.fear);

    try std.testing.expectError(error.InvalidAiAffect, data.setAiAffect(first, .{ .baseline_fear = -1 }));
    try std.testing.expectError(error.InvalidAiAffect, data.setAiAffect(first, .{ .decay_rate_fear = 0 }));
    try std.testing.expectError(error.InvalidAiAffect, data.setAiAffect(first, .{ .threshold_fear = 2 }));
}

test "ai affect store is columnar and compact after removal" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const first = try data.createEntity();
    const second = try data.createEntity();
    const third = try data.createEntity();
    try data.setAiAffect(first, .{ .baseline_fear = 0.1 });
    try data.setAiAffect(second, .{ .baseline_fear = 0.2 });
    try data.setAiAffect(third, .{ .baseline_fear = 0.3 });

    try std.testing.expect(try data.destroyEntity(second));

    const slice = data.aiAffectSliceConst();
    try std.testing.expectEqual(slice.entities.len, slice.baseline_fear.len);
    try std.testing.expectEqual(@as(usize, 2), slice.entities.len);

    // The swap-remove moved `third` into `second`'s old dense slot; resolving
    // it back through its EntitySlot proves removeAiAffectAt fixed up the
    // slot's ai_affect_index rather than just leaving the dense columns paired.
    try std.testing.expectEqual(@as(f32, 0.3), data_test_support.aiAffect(&data, third).?.baseline_fear);
}

test "ai affect survives entity destruction and reuse with generational correctness" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const original = try data.createEntity();
    try data.setAiAffect(original, .{ .baseline_fear = 0.4 });
    try std.testing.expect(try data.destroyEntity(original));

    try std.testing.expectEqual(@as(?AiAffect, null), data_test_support.aiAffect(&data, original));

    const reused = try data.createEntity();
    try std.testing.expectEqual(original.index, reused.index);
    try std.testing.expect(reused.generation != original.generation);
    try std.testing.expectEqual(@as(?AiAffect, null), data_test_support.aiAffect(&data, reused));

    try data.setAiAffect(reused, .{ .baseline_fear = 0.6 });
    try std.testing.expectEqual(@as(f32, 0.6), data_test_support.aiAffect(&data, reused).?.baseline_fear);
    try std.testing.expectEqual(@as(?AiAffect, null), data_test_support.aiAffect(&data, original));
}

fn testBody(base: f32) MovementBody {
    return .{
        .position = .{ .x = base, .y = base + 10 },
        .previous_position = .{ .x = base + 20, .y = base + 30 },
        .position_z = @as(i32, @intFromFloat(base)) - 2,
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
