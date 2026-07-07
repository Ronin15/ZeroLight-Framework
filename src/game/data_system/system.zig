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
const FacingSlice = types.FacingSlice;
const ConstFacingSlice = types.ConstFacingSlice;
const ConstFactionSlice = types.ConstFactionSlice;
const PrimitiveVisual = types.PrimitiveVisual;
const ConstPrimitiveVisualSlice = types.ConstPrimitiveVisualSlice;
const AssetReference = types.AssetReference;
const ConstAssetReferenceSlice = types.ConstAssetReferenceSlice;
const RenderEntityComponentIndices = types.RenderEntityComponentIndices;
const RenderCollectIndices = types.RenderCollectIndices;
const CollisionBounds = types.CollisionBounds;
const ConstCollisionBoundsSlice = types.ConstCollisionBoundsSlice;
const CollisionResponseMode = types.CollisionResponseMode;
const CollisionResponseMobility = types.CollisionResponseMobility;
const CollisionResponse = types.CollisionResponse;
const ConstCollisionResponseSlice = types.ConstCollisionResponseSlice;
const AiBehavior = types.AiBehavior;
const AiAgent = types.AiAgent;
const ConstAiAgentSlice = types.ConstAiAgentSlice;
const SteeringAgent = types.SteeringAgent;
const ConstSteeringAgentSlice = types.ConstSteeringAgentSlice;
const ConstWorldLevelSlice = types.ConstWorldLevelSlice;
const Faction = types.Faction;
const StructuralCommand = types.StructuralCommand;
const StructuralCommitStats = types.StructuralCommitStats;
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
const max_ai_seek_weight = types.max_ai_seek_weight;
const max_steering_neighbor_samples = types.max_steering_neighbor_samples;
const faction_level = @import("faction_level.zig");
const FactionStore = faction_level.FactionStore;
const WorldLevelStore = faction_level.WorldLevelStore;
const structural = @import("structural.zig");
const StructuralPlanScratch = structural.StructuralPlanScratch;
const NullStructuralChangeSink = structural.NullStructuralChangeSink;
const EntitySimulationMetadata = @import("../simulation_scope.zig").EntitySimulationMetadata;
const SimulationScopeStats = @import("../simulation_scope.zig").SimulationScopeStats;
const SimulationTier = @import("../simulation_scope.zig").SimulationTier;
const simd = @import("../../core/simd.zig");

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
    world_levels: WorldLevelStore = .{},
    factions: FactionStore = .{},

    pub fn init(allocator: std.mem.Allocator) DataSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DataSystem) void {
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
        if (slot.world_level_index) |dense_index| self.removeWorldLevelAt(@intCast(dense_index));
        if (slot.faction_index) |dense_index| self.removeFactionAt(@intCast(dense_index));

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
        return self.movement_bodies.scopeMetadataAt(di);
    }

    /// Writes the full scope metadata for an entity into its dense scope row.
    /// Requires a movement body; returns error.InvalidEntity otherwise.
    pub fn setSimulationMetadata(self: *DataSystem, id: EntityId, metadata: EntitySimulationMetadata) !void {
        try metadata.validate();
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        const di: usize = slot.movement_body_index orelse return error.InvalidEntity;
        self.tier_counts[@intFromEnum(self.movement_bodies.tierAt(di))] -= 1;
        self.tier_counts[@intFromEnum(metadata.tier)] += 1;
        self.movement_bodies.setScopeMetadata(di, metadata);
        self.snapInterpolationIfStill(di, metadata.tier);
    }

    /// Changes an entity's simulation tier while preserving chunk, stagger_phase,
    /// and always_active. Processors must not call this inside worker ranges; use
    /// a .set_simulation_tier structural command for deferred tier changes.
    pub fn setSimulationTier(self: *DataSystem, id: EntityId, tier: SimulationTier) !void {
        const slot = self.resolveSlot(id) orelse return error.InvalidEntity;
        const di: usize = slot.movement_body_index orelse return error.InvalidEntity;
        self.tier_counts[@intFromEnum(self.movement_bodies.tierAt(di))] -= 1;
        self.tier_counts[@intFromEnum(tier)] += 1;
        self.movement_bodies.setTier(di, tier);
        // chunk, stagger_phase, and always_active are intentionally preserved.
        self.snapInterpolationIfStill(di, tier);
    }

    /// When an entity enters a non-moving tier, movement stops updating its
    /// previous position while its position stays frozen — render interpolation
    /// (lerp previous→position) would otherwise oscillate. Snap previous=position
    /// so the row renders static until it moves again.
    fn snapInterpolationIfStill(self: *DataSystem, di: usize, tier: SimulationTier) void {
        if (tier.allowsMovement()) return;
        self.movement_bodies.snapPreviousToPosition(di);
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
            .movement_stage_entities = self.movement_bodies.len(),
            .collision_stage_entities = self.collision_bounds.len(),
            .collision_response_stage_entities = self.collision_responses.len(),
            .ai_stage_entities = self.ai_agents.len(),
            .steering_stage_entities = self.steering_agents.len(),
        };
    }

    /// O(rows) scan of the dense scope tier column — the parity baseline for the
    /// incrementally maintained `tier_counts`. Test/debug only; not on the hot path.
    /// Counts entities with a movement body (the entities that carry a tier).
    pub fn scanLiveTierCounts(self: *const DataSystem) [4]usize {
        var counts = [4]usize{ 0, 0, 0, 0 };
        for (self.movement_bodies.scopeSliceConst().tier) |tier| {
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

    /// World-space AABB of `id`'s collision body (movement body position plus collision
    /// bounds offset/size), or null when either component is absent. Matches the rect math
    /// pathfinding's nav_grid.zig derives from the same columns, so a caller can localize
    /// nav invalidation to the covered cells without re-deriving the whole level.
    pub fn staticObstacleWorldRect(self: *const DataSystem, id: EntityId) ?types.ObstacleWorldRect {
        const body = self.movementBodyConst(id) orelse return null;
        const bounds = self.collisionBoundsConst(id) orelse return null;
        const min_x = body.position.x + bounds.offset.x;
        const min_y = body.position.y + bounds.offset.y;
        return .{
            .min_x = min_x,
            .min_y = min_y,
            .max_x = min_x + bounds.size.x,
            .max_y = min_y + bounds.size.y,
        };
    }

    pub fn clearRetainingCapacity(self: *DataSystem) void {
        // Reset invalidates all existing IDs while keeping allocated component
        // columns warm for the next state/session.
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
        // A primitive-visual row may already exist for this entity (e.g. movement
        // body re-added after being destroyed while the visual persisted) — sync
        // the new row's flag so render collect doesn't skip it.
        if (slot.primitive_visual_index != null) {
            self.movement_bodies.setHasPrimitiveVisual(@intCast(dense_index), true);
        }
        // A world-level row may already exist (setWorldLevel called first) —
        // sync it onto the new scope row.
        if (slot.world_level_index) |world_level_index| {
            const level = self.world_levels.get(@intCast(world_level_index));
            try self.syncScopeLevelFromWorldLevel(id, level);
        }
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

    pub fn renderEntityComponentIndices(self: *const DataSystem, id: EntityId) ?RenderEntityComponentIndices {
        const slot = self.resolveSlotConst(id) orelse return null;
        const movement_body = slot.movement_body_index orelse return null;
        return .{
            .movement_body = @intCast(movement_body),
            .asset_ref = if (slot.asset_ref_index) |index| @intCast(index) else null,
            .facing = if (slot.facing_index) |index| @intCast(index) else null,
        };
    }

    /// Drawable indices for a movement-body dense row. The movement index is the
    /// loop anchor for render collect and matches scope columns (`tier`, `chunk_*`).
    pub fn renderCollectIndicesForMovement(self: *const DataSystem, movement_index: usize) ?RenderCollectIndices {
        const movement = self.movement_bodies.sliceConst();
        if (movement_index >= movement.entities.len) return null;
        if (!movement.has_primitive_visual[movement_index]) return null;
        const slot = self.resolveSlotConst(movement.entities[movement_index]) orelse return null;
        const visual_index = slot.primitive_visual_index orelse return null;
        const visuals = self.primitive_visuals.sliceConst();
        std.debug.assert(visual_index < visuals.entities.len);
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
            if (slot.movement_body_index) |movement_index| {
                self.movement_bodies.setHasPrimitiveVisual(@intCast(movement_index), true);
            }
            return;
        }

        const dense_index = try self.primitive_visuals.append(self.allocator, id, visual);
        slot.primitive_visual_index = dense_index;
        slot.addComponent(.primitive_visual);
        if (slot.movement_body_index) |movement_index| {
            self.movement_bodies.setHasPrimitiveVisual(@intCast(movement_index), true);
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

    pub fn primitiveVisualDenseIndex(self: *const DataSystem, id: EntityId) ?usize {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.primitive_visual_index orelse return null;
        return @intCast(dense_index);
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

    pub fn assetReferenceConst(self: *const DataSystem, id: EntityId) ?AssetReference {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.asset_ref_index orelse return null;
        return self.asset_refs.get(@intCast(dense_index));
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

    pub fn worldLevelPtr(self: *DataSystem, id: EntityId) ?*u16 {
        const slot = self.resolveSlot(id) orelse return null;
        const dense_index = slot.world_level_index orelse return null;
        return self.world_levels.levelPtr(@intCast(dense_index));
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

    pub fn factionPtr(self: *DataSystem, id: EntityId) ?*Faction {
        const slot = self.resolveSlot(id) orelse return null;
        const dense_index = slot.faction_index orelse return null;
        return self.factions.factionPtr(@intCast(dense_index));
    }

    pub fn factionConst(self: *const DataSystem, id: EntityId) ?Faction {
        const slot = self.resolveSlotConst(id) orelse return null;
        const dense_index = slot.faction_index orelse return null;
        return self.factions.factionAt(@intCast(dense_index));
    }

    pub fn factionSliceConst(self: *const DataSystem) ConstFactionSlice {
        return self.factions.sliceConst();
    }

    fn syncScopeLevelFromWorldLevel(self: *DataSystem, id: EntityId, level: u16) !void {
        const metadata = self.simulationMetadata(id) orelse return;
        if (metadata.level == level) return;
        var updated = metadata;
        updated.level = level;
        try self.setSimulationMetadata(id, updated);
    }

    pub fn applyStructuralCommands(self: *DataSystem, commands: []const StructuralCommand) !StructuralCommitStats {
        return structural.applyStructuralCommands(self, commands);
    }

    pub fn applyStructuralCommandsWithChangeSink(self: *DataSystem, commands: []const StructuralCommand, change_sink: anytype) !StructuralCommitStats {
        return structural.applyStructuralCommandsWithChangeSink(self, commands, change_sink);
    }

    pub fn applyStructuralCommandsPrepared(
        self: *DataSystem,
        commands: []const StructuralCommand,
        scratch: *StructuralPlanScratch,
        preparer: anytype,
        change_sink: anytype,
    ) !StructuralCommitStats {
        return structural.applyStructuralCommandsPrepared(self, commands, scratch, preparer, change_sink);
    }

    // Private, like the original: exercised directly by same-file (test)
    // callers, not part of the public API surface.
    fn commitStructuralCommands(
        self: *DataSystem,
        commands: []const StructuralCommand,
        change_sink: anytype,
    ) !StructuralCommitStats {
        return structural.commitStructuralCommands(self, commands, change_sink);
    }

    fn preflightStructuralCommands(
        self: *DataSystem,
        commands: []const StructuralCommand,
        scratch: *StructuralPlanScratch,
    ) !structural.StructuralCommitPlan {
        return structural.preflightStructuralCommands(self, commands, scratch);
    }

    pub fn validateStructuralCommands(commands: []const StructuralCommand) !void {
        return structural.validateStructuralCommands(commands);
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
        self.tier_counts[@intFromEnum(self.movement_bodies.tierAt(index))] -= 1;
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

    fn removeWorldLevelAt(self: *DataSystem, index: usize) void {
        const moved = self.world_levels.removeAt(index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].world_level_index = @intCast(index);
    }

    fn removeFactionAt(self: *DataSystem, index: usize) void {
        const moved = self.factions.removeAt(index);
        if (moved) |entity| self.slots.items[@intCast(entity.index)].faction_index = @intCast(index);
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
    try std.testing.expectEqual(slice.entities.len, slice.previous_z.len);
    try std.testing.expectEqual(slice.entities.len, slice.velocity_x.len);
    try std.testing.expectEqual(slice.entities.len, slice.velocity_y.len);
    try std.testing.expectEqual(slice.entities.len, slice.speed.len);
    try std.testing.expectEqual(slice.entities.len, slice.has_primitive_visual.len);
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
    try std.testing.expectEqual(slice.entities.len, slice.seek_weights.len);
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

    const level_ptr = data.worldLevelPtr(second).?;
    try std.testing.expectEqual(@as(u16, 7), level_ptr.*);
    level_ptr.* = 11;
    try std.testing.expectEqual(@as(u16, 11), data.worldLevelConst(second));

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
    }, data.simulationMetadata(entity).?);
    try std.testing.expectEqual(@as(u16, 5), data.scopeColumnsSliceConst().level[0]);

    try data.setWorldLevel(entity, 5);
    try std.testing.expectEqual(EntitySimulationMetadata{
        .tier = .locomotion,
        .chunk = .{ .x = 2, .y = -1 },
        .level = 5,
        .stagger_phase = 2,
    }, data.simulationMetadata(entity).?);

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

test "render entity component indices resolve movement asset and facing slots" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, testBody(1));

    const movement_only = data.renderEntityComponentIndices(entity).?;
    try std.testing.expectEqual(@as(usize, 0), movement_only.movement_body);
    try std.testing.expect(movement_only.asset_ref == null);
    try std.testing.expect(movement_only.facing == null);

    try data.setFacing(entity, .{ .direction = .down });
    const with_facing = data.renderEntityComponentIndices(entity).?;
    try std.testing.expect(with_facing.facing != null);
    try std.testing.expect(with_facing.asset_ref == null);

    try data.setAssetReference(entity, .{ .sprite = .demo_tile });
    const full = data.renderEntityComponentIndices(entity).?;
    try std.testing.expect(full.asset_ref != null);
    try std.testing.expect(full.facing != null);
    try std.testing.expectEqual(with_facing.movement_body, full.movement_body);

    try std.testing.expect(data.renderEntityComponentIndices(EntityId.invalid) == null);
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

    const indices = data.renderCollectIndicesForMovement(0).?;
    try std.testing.expectEqual(@as(usize, 0), indices.visual_index);
    try std.testing.expect(indices.asset_ref_index != null);
    try std.testing.expect(indices.facing_index != null);

    const movement_only = try data.createEntity();
    try data.setMovementBody(movement_only, testBody(2));
    try std.testing.expect(!data.movementBodySliceConst().has_primitive_visual[1]);
    try std.testing.expect(data.renderCollectIndicesForMovement(1) == null);
    try std.testing.expect(data.renderCollectIndicesForMovement(99) == null);

    _ = data.destroyEntity(entity);
    try std.testing.expect(data.renderCollectIndicesForMovement(0) == null);
    try std.testing.expect(data.movementBodySliceConst().entities.len == 1);
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
    try std.testing.expect(data.renderCollectIndicesForMovement(0) != null);
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

    const faction_ptr = data.factionPtr(second).?;
    try std.testing.expectEqual(Faction.ally, faction_ptr.*);
    faction_ptr.* = .hostile;
    try std.testing.expectEqual(@as(?Faction, .hostile), data.factionConst(second));

    const slice = data.factionSliceConst();
    try std.testing.expectEqual(slice.entities.len, slice.factions.len);
    try std.testing.expectEqual(@as(usize, 3), slice.entities.len);
    try std.testing.expectEqual(Faction.player, slice.factions[0]);
    try std.testing.expectEqual(Faction.hostile, slice.factions[1]);
    try std.testing.expectEqual(Faction.hostile, slice.factions[2]);
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

    try std.testing.expect(data.destroyEntity(second));

    const slice = data.factionSliceConst();
    try std.testing.expectEqual(slice.entities.len, slice.factions.len);
    try std.testing.expectEqual(@as(usize, 2), slice.entities.len);
    for (slice.entities, 0..) |entity, index| {
        const expected: Faction = if (entity.matches(first.index, first.generation)) .player else .hostile;
        try std.testing.expectEqual(expected, slice.factions[index]);
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
    try std.testing.expect(data.destroyEntity(original));

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
