// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Deferred structural-command pipeline: capacity preflight, then command-order
//! commit through DataSystem's accessor methods. Preflight reads the free-list
//! prefix this batch pops; the only slot write is that unlink on the
//! OutOfMemory return, before commit.

const std = @import("std");
const math = @import("../../core/math.zig");
const types = @import("types.zig");
const EntityId = types.EntityId;
const retiredSlotGeneration = types.retiredSlotGeneration;
const Component = types.Component;
const ComponentMask = types.ComponentMask;
const componentMask = types.componentMask;
const EntityTemplate = types.EntityTemplate;
const StructuralCommand = types.StructuralCommand;
const StructuralCommitStats = types.StructuralCommitStats;
const StructuralChange = types.StructuralChange;
const DataSystem = @import("system.zig").DataSystem;
const validateMovementBody = @import("movement.zig").validateMovementBody;
const validatePrimitiveVisual = @import("visual.zig").validatePrimitiveVisual;
const validateCollisionBounds = @import("collision.zig").validateCollisionBounds;
const validateCollisionResponse = @import("collision.zig").validateCollisionResponse;
const validateAiAgent = @import("agents.zig").validateAiAgent;
const validateSteeringAgent = @import("agents.zig").validateSteeringAgent;
const validateAiPerception = @import("perception.zig").validateAiPerception;
const validateAiMemory = @import("memory.zig").validateAiMemory;
const validateAiAffect = @import("affect.zig").validateAiAffect;
// Destructible payloads are scalar bools + u8 — no fallible validation beyond
// StructuralCommand payload shape.

pub const NullStructuralChangeSink = struct {
    fn record(_: *NullStructuralChangeSink, _: StructuralChange) void {}
};

pub const NullStructuralCommitPreparer = struct {
    fn prepare(_: *NullStructuralCommitPreparer, _: usize) !void {}
};

pub const StructuralCapacityNeeds = struct {
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
    world_levels: usize,
    factions: usize,
    ai_perceptions: usize,
    ai_memories: usize,
    ai_affects: usize,
    destructibles: usize,

    fn init(data: *const DataSystem) StructuralCapacityNeeds {
        return .{
            .slots = data.slots.items.len,
            .movement_bodies = data.movement_bodies.len(),
            .facings = data.facings.len(),
            .primitive_visuals = data.primitive_visuals.len(),
            .asset_refs = data.asset_refs.len(),
            .collision_bounds = data.collision_bounds.len(),
            .collision_responses = data.collision_responses.len(),
            .ai_agents = data.ai_agents.len(),
            .steering_agents = data.steering_agents.len(),
            .world_levels = data.world_levels.len(),
            .factions = data.factions.len(),
            .ai_perceptions = data.ai_perceptions.len(),
            .ai_memories = data.ai_memories.len(),
            .ai_affects = data.ai_affects.len(),
            .destructibles = data.destructibles.len(),
        };
    }

    // `u32` row indices: a projection past one fails at the growth seam as `OutOfMemory`,
    // before any write.
    fn validateLimits(self: StructuralCapacityNeeds) error{OutOfMemory}!void {
        inline for (@typeInfo(StructuralCapacityNeeds).@"struct".field_names) |name| {
            if (@field(self, name) > std.math.maxInt(u32)) return error.OutOfMemory;
        }
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
        if (template.world_level != null) try self.addComponent(.world_level);
        if (template.faction != null) try self.addComponent(.faction);
        if (template.ai_perception != null) try self.addComponent(.ai_perception);
        if (template.ai_memory != null) try self.addComponent(.ai_memory);
        if (template.ai_affect != null) try self.addComponent(.ai_affect);
        if (template.destructible != null) try self.addComponent(.destructible);
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
            .world_level => &self.current.world_levels,
            .faction => &self.current.factions,
            .ai_perception => &self.current.ai_perceptions,
            .ai_memory => &self.current.ai_memories,
            .ai_affect => &self.current.ai_affects,
            .destructible => &self.current.destructibles,
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
            .world_level => &self.required.world_levels,
            .faction => &self.required.factions,
            .ai_perception => &self.required.ai_perceptions,
            .ai_memory => &self.required.ai_memories,
            .ai_affect => &self.required.ai_affects,
            .destructible => &self.required.destructibles,
        };
    }
};

fn addCapacity(value: usize, amount: usize) !usize {
    return std.math.add(usize, value, amount);
}

pub const StructuralCommitPlan = struct {
    // `structural_event_count` lets callers reserve their change sink before
    // mutation so event publishing cannot fail halfway through commit.
    command_count: usize,
    capacity_needs: StructuralCapacityNeeds,
    structural_event_count: usize,
};

/// One budgeted commit's applied prefix. `deferred_applied` is the head of the
/// deferred slice; `fresh_applied` is the head of the fresh slice. The tail of
/// either slice is not part of this commit.
pub const StructuralPrefix = struct {
    plan: StructuralCommitPlan,
    deferred_applied: usize = 0,
    fresh_applied: usize = 0,
    stagger_arrivals: usize = 0,
};

const ProjectedEntityState = struct {
    // Liveness, mask, and the drawable cursor. Dense row indices stay off this copy.
    alive: bool,
    component_mask: ComponentMask,
    scope_level: u16,
    chunk_x: i32,
    chunk_y: i32,
    linked: bool,
    // Set when this cursor reserved neighbor slots. An adjacent level sync spends that slot.
    neighbor_reserved: bool = false,
    // Neighbor levels this cursor still holds, at its chunk. A planned sync clears a hold
    // `releaseStaleNeighbors` would drop before a later sync reads it.
    hold_below: ?u16 = null,
    hold_above: ?u16 = null,
    world_level: u16,

    fn init(data: *const DataSystem, entity: EntityId) ProjectedEntityState {
        // resolveSlotConst is private to system.zig; isAlive+componentMaskFor are
        // the equivalent already-pub accessors (same result, one extra lookup,
        // off the movement/collision hot path).
        if (!data.isAlive(entity)) return .{
            .alive = false,
            .component_mask = 0,
            .scope_level = 0,
            .chunk_x = 0,
            .chunk_y = 0,
            .linked = false,
            .world_level = 0,
        };
        const world_level = data.worldLevelConst(entity) orelse 0;
        const movement = data.movementBodyDenseIndex(entity) orelse return .{
            .alive = true,
            .component_mask = data.componentMaskFor(entity),
            .scope_level = 0,
            .chunk_x = 0,
            .chunk_y = 0,
            .linked = false,
            .world_level = world_level,
        };
        const metadata = data.movement_bodies.scopeMetadataAt(movement);
        const level = metadata.level orelse 0;
        const linked = data.movementBodySliceConst().has_primitive_visual[movement];
        const holds = if (linked) projectedNeighborHolds(data, movement, level, metadata.chunk.x, metadata.chunk.y) else ProjectedNeighborHolds{};
        return .{
            .alive = true,
            .component_mask = data.componentMaskFor(entity),
            .scope_level = level,
            .chunk_x = metadata.chunk.x,
            .chunk_y = metadata.chunk.y,
            .linked = linked,
            .hold_below = holds.below,
            .hold_above = holds.above,
            .world_level = world_level,
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

const DrawablePlanKey = struct {
    level: u16,
    chunk_x: i32,
    chunk_y: i32,
};

const DrawablePlanEntry = struct {
    added: u32 = 0,
    // Neighbor slots included in `added`. A link consume does not spend these.
    spare: u32 = 0,
    consumed: u32 = 0,
    applied: bool = false,
    created: bool = false,
};

/// Prepared-commit scratch. Pipelines keep the struct. A non-zero map is
/// released so a later step does not walk retained slots.
pub const StructuralPlanScratch = struct {
    allocator: std.mem.Allocator,
    projected_entities: std.AutoHashMapUnmanaged(u64, ProjectedEntityState) = .{},
    drawable_plan: std.AutoHashMapUnmanaged(DrawablePlanKey, DrawablePlanEntry) = .{},
    reuse_generations: std.ArrayList(u32) = .empty,

    pub fn init(allocator: std.mem.Allocator) StructuralPlanScratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StructuralPlanScratch) void {
        self.projected_entities.deinit(self.allocator);
        self.drawable_plan.deinit(self.allocator);
        self.reuse_generations.deinit(self.allocator);
        self.projected_entities = .{};
        self.drawable_plan = .{};
        self.reuse_generations = .empty;
    }

    /// A zero count does not walk retained slots. A non-zero count releases the map.
    /// The generation stack drops its length and keeps its capacity.
    pub fn clearRetainingCapacity(self: *StructuralPlanScratch) void {
        self.clearProjected();
        self.clearDrawable();
        self.reuse_generations.clearRetainingCapacity();
    }

    fn clearProjected(self: *StructuralPlanScratch) void {
        if (self.projected_entities.count() == 0) return;
        self.projected_entities.deinit(self.allocator);
        self.projected_entities = .{};
    }

    fn clearDrawable(self: *StructuralPlanScratch) void {
        if (self.drawable_plan.count() == 0) return;
        self.drawable_plan.deinit(self.allocator);
        self.drawable_plan = .{};
    }

    fn drawableEntry(self: *StructuralPlanScratch, key: DrawablePlanKey) !*DrawablePlanEntry {
        const result = try self.drawable_plan.getOrPut(self.allocator, key);
        if (!result.found_existing) result.value_ptr.* = .{};
        return result.value_ptr;
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
    inline for (comptime std.meta.tags(Component)) |component| {
        if ((component_mask & componentMask(component)) != 0) {
            projection.removeComponent(component);
        }
    }
}

/// Most `.structural_commit` events one `create_entity` emits: one `entity_created`
/// plus one `component_changed` per template component. Derived from `EntityTemplate`,
/// so a new template component widens it automatically.
pub const max_structural_events_per_create: usize = 1 + @typeInfo(EntityTemplate).@"struct".field_names.len;

comptime {
    // `templateComponentCount` counts every field, so each one must be an optional
    // component slot.
    const info = @typeInfo(EntityTemplate).@"struct";
    for (info.field_names, info.field_types) |name, field_type| {
        if (@typeInfo(field_type) != .optional) @compileError("EntityTemplate." ++ name ++ " must be optional");
    }
}

fn templateComponentCount(template: EntityTemplate) usize {
    var count: usize = 0;
    inline for (comptime @typeInfo(EntityTemplate).@"struct".field_names) |name| {
        if (@field(template, name) != null) count += 1;
    }
    return count;
}

pub fn applyStructuralCommands(self: *DataSystem, commands: []const StructuralCommand) !StructuralCommitStats {
    var sink = NullStructuralChangeSink{};
    return try applyStructuralCommandsWithChangeSink(self, commands, &sink);
}

pub fn applyStructuralCommandsWithChangeSink(self: *DataSystem, commands: []const StructuralCommand, change_sink: anytype) !StructuralCommitStats {
    var scratch = StructuralPlanScratch.init(self.allocator);
    defer scratch.deinit();
    var preparer = NullStructuralCommitPreparer{};
    return try applyStructuralCommandsPrepared(self, commands, &scratch, &preparer, change_sink);
}

pub fn applyStructuralCommandsPrepared(
    self: *DataSystem,
    commands: []const StructuralCommand,
    scratch: *StructuralPlanScratch,
    preparer: anytype,
    change_sink: anytype,
) !StructuralCommitStats {
    // One slice, no share cut, no deferred deque.
    const prefix = try projectStructuralPrefix(self, &.{}, commands, scratch, null);
    return commitStructuralPrefix(self, &.{}, commands[0..prefix.fresh_applied], prefix, scratch, preparer, change_sink);
}

pub fn commitStructuralPrefix(
    self: *DataSystem,
    deferred_applied: []const StructuralCommand,
    fresh_applied: []const StructuralCommand,
    prefix: StructuralPrefix,
    scratch: *StructuralPlanScratch,
    preparer: anytype,
    change_sink: anytype,
) !StructuralCommitStats {
    var open = true;
    errdefer if (open) {
        abortAppliedDrawablePlan(self, scratch);
        scratch.clearRetainingCapacity();
    };
    try finishStructuralPrefix(self, scratch, prefix);
    try preparer.prepare(prefix.plan.structural_event_count);
    open = false;
    // No allocations or event-capacity failures should occur after this
    // point; the commit loop can mutate DataSystem in command order.
    scratch.clearRetainingCapacity();
    var stats = try commitStructuralCommands(self, deferred_applied, change_sink);
    const fresh_stats = try commitStructuralCommands(self, fresh_applied, change_sink);
    stats.created += fresh_stats.created;
    stats.destroyed += fresh_stats.destroyed;
    stats.components_set += fresh_stats.components_set;
    stats.stale_skipped += fresh_stats.stale_skipped;
    return stats;
}

/// File-private: commits one applied slice. Capacity is reserved before this runs.
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
                errdefer self.destroyCreatedEntity(entity);
                stats.components_set += try applyTemplateComponents(self, entity, template);
                stats.created += 1;
                change_sink.record(.{ .entity_created = entity });
                recordTemplateComponentChanges(self, change_sink, entity, template);
            },
            .destroy_entity => |entity| {
                const component_mask = self.componentMaskFor(entity);
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(entity);
                // Capture plane before destroy: world_level row is removed with the entity.
                const level = self.worldLevelConst(entity) orelse 0;
                if (try self.destroyEntity(entity)) {
                    stats.destroyed += 1;
                    change_sink.record(.{ .entity_destroyed = .{
                        .entity = entity,
                        .component_mask = component_mask,
                        .was_static_navigation_obstacle = was_static_navigation_obstacle,
                        .level = level,
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
                const inserting_body = self.movementBodyDenseIndex(set.entity) == null;
                try self.setMovementBodyReserved(set.entity, set.body);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .movement_body, was_static_navigation_obstacle);
                if (inserting_body) try self.commitReservedStaggerPhase(set.entity);
            },
            .set_facing => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setFacing(set.entity, set.facing);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .facing, was_static_navigation_obstacle);
            },
            .set_primitive_visual => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setPrimitiveVisualReserved(set.entity, set.visual);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .primitive_visual, was_static_navigation_obstacle);
            },
            .set_asset_reference => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setAssetReference(set.entity, set.asset_reference);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .asset_reference, was_static_navigation_obstacle);
            },
            .set_collision_bounds => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setCollisionBounds(set.entity, set.bounds);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .collision_bounds, was_static_navigation_obstacle);
            },
            .set_collision_response => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setCollisionResponse(set.entity, set.response);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .collision_response, was_static_navigation_obstacle);
            },
            .set_ai_agent => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                const adding_ai = !self.hasComponents(set.entity, componentMask(.ai_agent));
                try self.setAiAgent(set.entity, set.agent);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .ai_agent, was_static_navigation_obstacle);
                if (adding_ai) try self.commitReservedStaggerPhase(set.entity);
            },
            .set_steering_agent => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setSteeringAgent(set.entity, set.agent);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .steering_agent, was_static_navigation_obstacle);
            },
            .set_world_level => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setWorldLevelReserved(set.entity, set.level);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .world_level, was_static_navigation_obstacle);
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
            .set_faction => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setFaction(set.entity, set.faction);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .faction, was_static_navigation_obstacle);
            },
            .set_ai_perception => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setAiPerception(set.entity, set.perception);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .ai_perception, was_static_navigation_obstacle);
            },
            .set_ai_memory => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setAiMemory(set.entity, set.memory);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .ai_memory, was_static_navigation_obstacle);
            },
            .set_ai_affect => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setAiAffect(set.entity, set.affect);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .ai_affect, was_static_navigation_obstacle);
            },
            .set_destructible => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setDestructible(set.entity, set.destructible);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .destructible, was_static_navigation_obstacle);
            },
        }
    }
    return stats;
}

fn consumeFreeGeneration(
    self: *DataSystem,
    scratch: *StructuralPlanScratch,
    cursor: *?u32,
    cursor_previous: *?u32,
) error{OutOfMemory}!void {
    if (scratch.reuse_generations.pop()) |generation| {
        if (generation == std.math.maxInt(u32)) return error.OutOfMemory;
        return;
    }
    const index = cursor.* orelse return;
    const slot = &self.slots.items[@intCast(index)];
    const generation = slot.generation;
    const next = slot.next_free;
    if (generation == std.math.maxInt(u32)) {
        self.unlinkFreeSlot(index, cursor_previous.*);
        return error.OutOfMemory;
    }
    cursor_previous.* = index;
    cursor.* = next;
}

fn projectedAlive(scratch: *const StructuralPlanScratch, data: *const DataSystem, entity: EntityId) bool {
    if (scratch.projected_entities.get(structuralEntityKey(entity))) |state| return state.alive;
    return data.isAlive(entity);
}

fn structuralEventDelta(scratch: *const StructuralPlanScratch, data: *const DataSystem, command: StructuralCommand) usize {
    return switch (command) {
        .create_entity => |template| 1 + templateComponentCount(template),
        .set_simulation_tier => 0,
        .destroy_entity => |entity| if (projectedAlive(scratch, data, entity)) 1 else 0,
        .set_movement_body => |set| if (projectedAlive(scratch, data, set.entity)) 1 else 0,
        .set_facing => |set| if (projectedAlive(scratch, data, set.entity)) 1 else 0,
        .set_primitive_visual => |set| if (projectedAlive(scratch, data, set.entity)) 1 else 0,
        .set_asset_reference => |set| if (projectedAlive(scratch, data, set.entity)) 1 else 0,
        .set_collision_bounds => |set| if (projectedAlive(scratch, data, set.entity)) 1 else 0,
        .set_collision_response => |set| if (projectedAlive(scratch, data, set.entity)) 1 else 0,
        .set_ai_agent => |set| if (projectedAlive(scratch, data, set.entity)) 1 else 0,
        .set_steering_agent => |set| if (projectedAlive(scratch, data, set.entity)) 1 else 0,
        .set_world_level => |set| if (projectedAlive(scratch, data, set.entity)) 1 else 0,
        .set_faction => |set| if (projectedAlive(scratch, data, set.entity)) 1 else 0,
        .set_ai_perception => |set| if (projectedAlive(scratch, data, set.entity)) 1 else 0,
        .set_ai_memory => |set| if (projectedAlive(scratch, data, set.entity)) 1 else 0,
        .set_ai_affect => |set| if (projectedAlive(scratch, data, set.entity)) 1 else 0,
        .set_destructible => |set| if (projectedAlive(scratch, data, set.entity)) 1 else 0,
    };
}

/// Walks `deferred` then `fresh`. `share` null takes both. A set share stops
/// before the command whose event delta would exceed it; that command and the
/// tail are not validated or projected. Does not reserve stores or apply the
/// drawable plan.
pub fn projectStructuralPrefix(
    self: *DataSystem,
    deferred: []const StructuralCommand,
    fresh: []const StructuralCommand,
    scratch: *StructuralPlanScratch,
    share: ?usize,
) !StructuralPrefix {
    scratch.clearProjected();
    scratch.clearDrawable();
    defer scratch.clearProjected();
    errdefer scratch.clearDrawable();
    if (deferred.len == 0 and fresh.len == 0) {
        return .{
            .plan = .{
                .command_count = 0,
                .capacity_needs = StructuralCapacityNeeds.init(self),
                .structural_event_count = 0,
            },
        };
    }
    scratch.clearRetainingCapacity();

    var projection = StructuralCapacityProjection.init(self);
    var structural_event_count: usize = 0;
    var stagger_arrivals: usize = 0;
    var deferred_applied: usize = 0;
    var fresh_applied: usize = 0;
    var free_cursor: ?u32 = self.first_free_slot;
    var free_previous: ?u32 = null;

    const slices = [2][]const StructuralCommand{ deferred, fresh };
    commands: for (slices, 0..) |slice, slice_index| {
        for (slice, 0..) |command, index| {
            const summed = try addCapacity(structural_event_count, structuralEventDelta(scratch, self, command));
            if (share) |limit| {
                if (summed > limit) break :commands;
            }
            structural_event_count = summed;
            _ = try validateStructuralCommands(&.{command});
            try projectAcceptedCommand(self, scratch, &projection, &free_cursor, &free_previous, &stagger_arrivals, command);
            if (slice_index == 0) {
                deferred_applied = index + 1;
            } else {
                fresh_applied = index + 1;
            }
        }
    }

    return .{
        .plan = .{
            .command_count = deferred_applied + fresh_applied,
            .capacity_needs = projection.required,
            .structural_event_count = structural_event_count,
        },
        .deferred_applied = deferred_applied,
        .fresh_applied = fresh_applied,
        .stagger_arrivals = stagger_arrivals,
    };
}

fn projectAcceptedCommand(
    self: *DataSystem,
    scratch: *StructuralPlanScratch,
    projection: *StructuralCapacityProjection,
    free_cursor: *?u32,
    free_previous: *?u32,
    stagger_arrivals: *usize,
    command: StructuralCommand,
) !void {
    switch (command) {
        .create_entity => |template| {
            try consumeFreeGeneration(self, scratch, free_cursor, free_previous);
            try projection.createSlot();
            try projection.addTemplate(template);
            if (template.movement_body != null and template.ai_agent != null) stagger_arrivals.* += 1;
            try planTemplateDrawable(self, scratch, template);
        },
        .destroy_entity => |entity| {
            const state = try scratch.projectedState(self, entity);
            if (state.alive) {
                if (scratch.reuse_generations.items.len == scratch.reuse_generations.capacity) {
                    try scratch.reuse_generations.ensureTotalCapacity(scratch.allocator, scratch.reuse_generations.items.len + 1);
                }
                scratch.reuse_generations.appendAssumeCapacity(retiredSlotGeneration(self.slots.items[@intCast(entity.index)].generation));
                try projection.destroySlot();
                removeProjectedComponents(state.component_mask, projection);
                state.destroy();
            }
        },
        .set_movement_body => |set| {
            const state = try scratch.projectedState(self, set.entity);
            const inserting = state.alive and !state.hasComponent(.movement_body);
            const inserts_ai_arrival = inserting and state.hasComponent(.ai_agent);
            try preflightSetComponent(self, set.entity, .movement_body, scratch, projection);
            if (inserts_ai_arrival) stagger_arrivals.* += 1;
            try planMovementDrawable(self, scratch, set.entity, inserting);
        },
        .set_facing => |set| try preflightSetComponent(self, set.entity, .facing, scratch, projection),
        .set_primitive_visual => |set| {
            try preflightSetComponent(self, set.entity, .primitive_visual, scratch, projection);
            const state = try scratch.projectedState(self, set.entity);
            if (state.alive and state.hasComponent(.movement_body) and !state.linked) try cursorPlace(self, scratch, state);
        },
        .set_asset_reference => |set| try preflightSetComponent(self, set.entity, .asset_reference, scratch, projection),
        .set_collision_bounds => |set| try preflightSetComponent(self, set.entity, .collision_bounds, scratch, projection),
        .set_collision_response => |set| try preflightSetComponent(self, set.entity, .collision_response, scratch, projection),
        .set_ai_agent => |set| {
            const state = try scratch.projectedState(self, set.entity);
            const adds_ai_arrival = state.alive and state.hasComponent(.movement_body) and !state.hasComponent(.ai_agent);
            try preflightSetComponent(self, set.entity, .ai_agent, scratch, projection);
            if (adds_ai_arrival) stagger_arrivals.* += 1;
        },
        .set_steering_agent => |set| try preflightSetComponent(self, set.entity, .steering_agent, scratch, projection),
        .set_world_level => |set| {
            const state = try scratch.projectedState(self, set.entity);
            if (state.alive) state.world_level = set.level;
            try preflightSetComponent(self, set.entity, .world_level, scratch, projection);
            const live = try scratch.projectedState(self, set.entity);
            if (live.alive and live.hasComponent(.movement_body)) try cursorSync(self, scratch, live, set.level, set.entity);
        },
        .set_faction => |set| try preflightSetComponent(self, set.entity, .faction, scratch, projection),
        .set_ai_perception => |set| try preflightSetComponent(self, set.entity, .ai_perception, scratch, projection),
        .set_ai_memory => |set| try preflightSetComponent(self, set.entity, .ai_memory, scratch, projection),
        .set_ai_affect => |set| try preflightSetComponent(self, set.entity, .ai_affect, scratch, projection),
        .set_destructible => |set| try preflightSetComponent(self, set.entity, .destructible, scratch, projection),
        .set_simulation_tier => {},
    }
}

pub fn preflightStructuralCommands(
    self: *DataSystem,
    commands: []const StructuralCommand,
    scratch: *StructuralPlanScratch,
) !StructuralCommitPlan {
    const prefix = try projectStructuralPrefix(self, &.{}, commands, scratch, null);
    if (prefix.plan.command_count == 0) return prefix.plan;
    var open = true;
    errdefer if (open) {
        abortAppliedDrawablePlan(self, scratch);
        scratch.clearRetainingCapacity();
    };
    try finishStructuralPrefix(self, scratch, prefix);
    open = false;
    return prefix.plan;
}

fn finishStructuralPrefix(self: *DataSystem, scratch: *StructuralPlanScratch, prefix: StructuralPrefix) !void {
    if (prefix.plan.command_count == 0) return;
    try prefix.plan.capacity_needs.validateLimits();
    // Each applied command records at most two allow ids (a removal and its landed
    // tail, or a create's errdefer removal). Tier changes record one. The tail does not.
    try self.collision_allow_records.ensureTotalCapacity(self.allocator, self.collision_allow_records.items.len + prefix.plan.command_count * 2);
    try reserveStructuralPlanCapacity(self, prefix.plan);
    // Upper bound: one new arrival key and one level origin per AI arrival this commit
    // settles. The commit puts into that capacity. Without a grid the commit does not insert.
    if (prefix.stagger_arrivals != 0 and self.movement_bodies.cells_x != 0 and self.movement_bodies.cells_y != 0) {
        try self.movement_bodies.ensureStaggerMapCapacity(self.allocator, prefix.stagger_arrivals);
    }
    try applyDrawablePlan(self, scratch);
}

fn planTemplateDrawable(self: *DataSystem, scratch: *StructuralPlanScratch, template: EntityTemplate) !void {
    // Movement, then the visual place, then the world-level sync: `applyTemplateComponents` order.
    var cursor = ProjectedEntityState{
        .alive = true,
        .component_mask = 0,
        .scope_level = 0,
        .chunk_x = 0,
        .chunk_y = 0,
        .linked = false,
        .world_level = 0,
    };
    if (template.movement_body != null) {
        cursor.scope_level = 0;
        cursor.chunk_x = 0;
        cursor.chunk_y = 0;
        cursor.linked = false;
        cursor.addComponent(.movement_body);
    }
    if (template.primitive_visual != null and cursor.hasComponent(.movement_body)) try cursorPlace(self, scratch, &cursor);
    if (template.world_level) |level| {
        cursor.world_level = level;
        if (cursor.hasComponent(.movement_body)) try cursorSync(self, scratch, &cursor, level, null);
    }
}

fn planMovementDrawable(self: *DataSystem, scratch: *StructuralPlanScratch, entity: EntityId, inserting: bool) !void {
    const state = try scratch.projectedState(self, entity);
    if (!state.alive) return;
    if (inserting) {
        state.scope_level = 0;
        state.chunk_x = 0;
        state.chunk_y = 0;
        state.linked = false;
        if (state.hasComponent(.primitive_visual)) try cursorPlace(self, scratch, state);
        if (state.hasComponent(.world_level)) try cursorSync(self, scratch, state, state.world_level, entity);
        return;
    }
    if (state.hasComponent(.world_level)) try cursorSync(self, scratch, state, state.world_level, entity);
}

fn cursorPlace(self: *DataSystem, scratch: *StructuralPlanScratch, cursor: *ProjectedEntityState) !void {
    // Reserve the link slot, then spend it, so a standing spare on this key remains.
    const key: DrawablePlanKey = .{
        .level = cursor.scope_level,
        .chunk_x = cursor.chunk_x,
        .chunk_y = cursor.chunk_y,
    };
    try planEnsure(self, scratch, key);
    try planConsume(self, scratch, key);
    if (cursor.scope_level > 0) {
        try planEnsureNeighbor(self, scratch, .{
            .level = cursor.scope_level - 1,
            .chunk_x = cursor.chunk_x,
            .chunk_y = cursor.chunk_y,
        });
    }
    if (cursor.scope_level != std.math.maxInt(u16)) {
        try planEnsureNeighbor(self, scratch, .{
            .level = cursor.scope_level + 1,
            .chunk_x = cursor.chunk_x,
            .chunk_y = cursor.chunk_y,
        });
    }
    cursor.linked = true;
    cursor.neighbor_reserved = true;
}

fn cursorSync(self: *DataSystem, scratch: *StructuralPlanScratch, cursor: *ProjectedEntityState, level: u16, owner: ?EntityId) !void {
    if (!cursor.hasComponent(.movement_body) or cursor.scope_level == level) return;
    if (cursor.linked) {
        const key: DrawablePlanKey = .{
            .level = level,
            .chunk_x = cursor.chunk_x,
            .chunk_y = cursor.chunk_y,
        };
        // Owns only while this cursor still holds the destination. The drop clears holds
        // `releaseStaleNeighbors` would drop. An adjacent place spends its own spare.
        const owns = owner != null and projectedHold(cursor, level);
        const spent_spare = !owns and cursor.neighbor_reserved and levelsAdjacent(cursor.scope_level, level) and takePlanSpare(scratch, key);
        if (!owns and !spent_spare) try planConsume(self, scratch, key);
        dropStaleProjectedHolds(cursor, level);
    }
    cursor.neighbor_reserved = false;
    cursor.scope_level = level;
}

const ProjectedNeighborHolds = struct {
    below: ?u16 = null,
    above: ?u16 = null,
};

fn projectedNeighborHolds(data: *const DataSystem, row: usize, level: u16, chunk_x: i32, chunk_y: i32) ProjectedNeighborHolds {
    return .{
        .below = if (level > 0 and data.movement_bodies.holdsNeighborReserve(row, level - 1, chunk_x, chunk_y)) level - 1 else null,
        .above = if (level != std.math.maxInt(u16) and data.movement_bodies.holdsNeighborReserve(row, level + 1, chunk_x, chunk_y)) level + 1 else null,
    };
}

fn projectedHold(cursor: *const ProjectedEntityState, level: u16) bool {
    return cursor.hold_below == level or cursor.hold_above == level;
}

fn dropStaleProjectedHolds(cursor: *ProjectedEntityState, level: u16) void {
    if (cursor.hold_below) |held| {
        if (!projectedNeighborKept(level, held)) cursor.hold_below = null;
    }
    if (cursor.hold_above) |held| {
        if (!projectedNeighborKept(level, held)) cursor.hold_above = null;
    }
}

fn projectedNeighborKept(level: u16, held: u16) bool {
    if (level > 0 and held == level - 1) return true;
    if (level != std.math.maxInt(u16) and held == level + 1) return true;
    return false;
}

fn levelsAdjacent(from_level: u16, to_level: u16) bool {
    const wide_from: u32 = from_level;
    const wide_to: u32 = to_level;
    const delta = if (wide_from > wide_to) wide_from - wide_to else wide_to - wide_from;
    return delta == 1;
}

fn planEnsure(self: *DataSystem, scratch: *StructuralPlanScratch, key: DrawablePlanKey) !void {
    const entry = try scratch.drawableEntry(key);
    const base = self.movement_bodies.drawableReservedExtra(key.level, key.chunk_x, key.chunk_y);
    const summed = std.math.add(u32, base, entry.added) catch return error.OutOfMemory;
    if (summed == std.math.maxInt(u32)) return error.OutOfMemory;
    entry.added += 1;
}

fn planEnsureNeighbor(self: *DataSystem, scratch: *StructuralPlanScratch, key: DrawablePlanKey) !void {
    try planEnsure(self, scratch, key);
    scratch.drawable_plan.getPtr(key).?.spare += 1;
}

fn takePlanSpare(scratch: *StructuralPlanScratch, key: DrawablePlanKey) bool {
    const entry = scratch.drawable_plan.getPtr(key) orelse return false;
    if (entry.spare == 0) return false;
    entry.spare -= 1;
    entry.consumed += 1;
    return true;
}

fn planConsume(self: *DataSystem, scratch: *StructuralPlanScratch, key: DrawablePlanKey) !void {
    const pending_empty = blk: {
        const entry = try scratch.drawableEntry(key);
        // Owned neighbor slots are not link slots. Spares reserved in this plan are not either.
        const pending = self.movement_bodies.drawablePendingExtra(key.level, key.chunk_x, key.chunk_y);
        const link_added = entry.added - entry.spare;
        const summed = std.math.add(u32, pending, link_added) catch return error.OutOfMemory;
        std.debug.assert(summed >= entry.consumed);
        break :blk summed == entry.consumed;
    };
    if (pending_empty) try planEnsure(self, scratch, key);
    scratch.drawable_plan.getPtr(key).?.consumed += 1;
}

fn applyDrawablePlan(self: *DataSystem, scratch: *StructuralPlanScratch) !void {
    var it = scratch.drawable_plan.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.added == 0) continue;
        const created = self.movement_bodies.reserveDrawableSlots(
            self.allocator,
            entry.key_ptr.level,
            entry.key_ptr.chunk_x,
            entry.key_ptr.chunk_y,
            entry.value_ptr.added,
        ) catch |err| {
            abortAppliedDrawablePlan(self, scratch);
            return err;
        };
        entry.value_ptr.applied = true;
        entry.value_ptr.created = created;
    }
}

fn abortAppliedDrawablePlan(self: *DataSystem, scratch: *StructuralPlanScratch) void {
    var it = scratch.drawable_plan.iterator();
    while (it.next()) |entry| {
        if (!entry.value_ptr.applied) continue;
        self.movement_bodies.unreserveDrawableSlots(
            entry.key_ptr.level,
            entry.key_ptr.chunk_x,
            entry.key_ptr.chunk_y,
            entry.value_ptr.added,
            entry.value_ptr.created,
        );
        entry.value_ptr.applied = false;
    }
}

fn preflightSetComponent(
    self: *DataSystem,
    entity: EntityId,
    component: Component,
    scratch: *StructuralPlanScratch,
    projection: *StructuralCapacityProjection,
) !void {
    const state = try scratch.projectedState(self, entity);
    if (!state.alive) return;
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
    try self.world_levels.ensureCapacity(self.allocator, plan.capacity_needs.world_levels);
    try self.factions.ensureCapacity(self.allocator, plan.capacity_needs.factions);
    try self.ai_perceptions.ensureCapacity(self.allocator, plan.capacity_needs.ai_perceptions);
    try self.ai_memories.ensureCapacity(self.allocator, plan.capacity_needs.ai_memories);
    try self.ai_affects.ensureCapacity(self.allocator, plan.capacity_needs.ai_affects);
    try self.destructibles.ensureCapacity(self.allocator, plan.capacity_needs.destructibles);
}

pub fn validateStructuralCommands(commands: []const StructuralCommand) !usize {
    // Validate fallible payloads up front so the later command-order commit
    // does not partially mutate before rejecting bad component data.
    // The count is commands that call projectedState.
    var projecting: usize = 0;
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
                if (template.ai_perception) |perception| {
                    try validateAiPerception(perception);
                }
                if (template.ai_memory) |ai_memory| {
                    try validateAiMemory(ai_memory);
                }
                if (template.ai_affect) |ai_affect| {
                    try validateAiAffect(ai_affect);
                }
            },
            .destroy_entity => projecting += 1,
            .set_movement_body => |set| {
                try validateMovementBody(set.body);
                projecting += 1;
            },
            .set_facing => projecting += 1,
            .set_primitive_visual => |set| {
                try validatePrimitiveVisual(set.visual);
                projecting += 1;
            },
            .set_asset_reference => projecting += 1,
            .set_collision_bounds => |set| {
                try validateCollisionBounds(set.bounds);
                projecting += 1;
            },
            .set_collision_response => |set| {
                try validateCollisionResponse(set.response);
                projecting += 1;
            },
            .set_ai_agent => |set| {
                try validateAiAgent(set.agent);
                projecting += 1;
            },
            .set_steering_agent => |set| {
                try validateSteeringAgent(set.agent);
                projecting += 1;
            },
            .set_world_level => projecting += 1,
            .set_simulation_tier => {},
            .set_faction => projecting += 1,
            .set_ai_perception => |set| {
                try validateAiPerception(set.perception);
                projecting += 1;
            },
            .set_ai_memory => |set| {
                try validateAiMemory(set.memory);
                projecting += 1;
            },
            .set_ai_affect => |set| {
                try validateAiAffect(set.affect);
                projecting += 1;
            },
            .set_destructible => projecting += 1,
        }
    }
    return projecting;
}

fn recordTemplateComponentChanges(self: *const DataSystem, change_sink: anytype, entity: EntityId, template: EntityTemplate) void {
    // applyTemplateComponents (called before this) already applied every template
    // component, so a fresh entity never has a real "before this component" obstacle
    // state to report: every event here passes was_static_navigation_obstacle = false.
    // recordComponentChange computes the live is-side from the fully applied entity.
    if (template.movement_body != null) recordComponentChange(self, change_sink, entity, .movement_body, false);
    if (template.facing != null) recordComponentChange(self, change_sink, entity, .facing, false);
    if (template.primitive_visual != null) recordComponentChange(self, change_sink, entity, .primitive_visual, false);
    if (template.asset_reference != null) recordComponentChange(self, change_sink, entity, .asset_reference, false);
    if (template.collision_bounds != null) recordComponentChange(self, change_sink, entity, .collision_bounds, false);
    if (template.collision_response != null) recordComponentChange(self, change_sink, entity, .collision_response, false);
    if (template.ai_agent != null) recordComponentChange(self, change_sink, entity, .ai_agent, false);
    if (template.steering_agent != null) recordComponentChange(self, change_sink, entity, .steering_agent, false);
    if (template.world_level != null) recordComponentChange(self, change_sink, entity, .world_level, false);
    if (template.faction != null) recordComponentChange(self, change_sink, entity, .faction, false);
    if (template.ai_perception != null) recordComponentChange(self, change_sink, entity, .ai_perception, false);
    if (template.ai_memory != null) recordComponentChange(self, change_sink, entity, .ai_memory, false);
    if (template.ai_affect != null) recordComponentChange(self, change_sink, entity, .ai_affect, false);
    if (template.destructible != null) recordComponentChange(self, change_sink, entity, .destructible, false);
}

fn recordComponentChange(self: *const DataSystem, change_sink: anytype, entity: EntityId, component: Component, was_static_navigation_obstacle: bool) void {
    const is_static_navigation_obstacle = self.isStaticNavigationObstacle(entity);
    change_sink.record(.{
        .component_changed = .{
            .entity = entity,
            .component = component,
            .was_static_navigation_obstacle = was_static_navigation_obstacle,
            .is_static_navigation_obstacle = is_static_navigation_obstacle,
            // Post-set plane (world_level after this command when that component changed).
            .level = self.worldLevelConst(entity) orelse 0,
        },
    });
}

fn applyTemplateComponents(self: *DataSystem, entity: EntityId, template: EntityTemplate) !usize {
    var components_set: usize = 0;
    if (template.movement_body) |body| {
        try self.setMovementBodyReserved(entity, body);
        components_set += 1;
    }
    if (template.facing) |facing| {
        try self.setFacing(entity, facing);
        components_set += 1;
    }
    if (template.primitive_visual) |visual| {
        try self.setPrimitiveVisualReserved(entity, visual);
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
    if (template.world_level) |level| {
        try self.setWorldLevelReserved(entity, level);
        components_set += 1;
    }
    if (template.faction) |entity_faction| {
        try self.setFaction(entity, entity_faction);
        components_set += 1;
    }
    if (template.ai_perception) |perception| {
        try self.setAiPerception(entity, perception);
        components_set += 1;
    }
    if (template.ai_memory) |ai_memory| {
        try self.setAiMemory(entity, ai_memory);
        components_set += 1;
    }
    if (template.ai_affect) |ai_affect| {
        try self.setAiAffect(entity, ai_affect);
        components_set += 1;
    }
    if (template.destructible) |destructible| {
        try self.setDestructible(entity, destructible);
        components_set += 1;
    }
    if (template.movement_body != null and template.ai_agent != null) {
        try self.commitReservedStaggerPhase(entity);
    }
    return components_set;
}

test "StructuralCapacityNeeds.validateLimits fails every store's count beyond u32 as OutOfMemory" {
    // Growing a store to u32-max rows is impractical to exercise for real, so this proves
    // the guard directly against the private capacity struct, one count at a time.
    var needs = std.mem.zeroes(StructuralCapacityNeeds);
    try needs.validateLimits();
    inline for (@typeInfo(StructuralCapacityNeeds).@"struct".field_names) |name| {
        var over = needs;
        @field(over, name) = std.math.maxInt(u32);
        try over.validateLimits();
        @field(over, name) = @as(usize, std.math.maxInt(u32)) + 1;
        try std.testing.expectError(error.OutOfMemory, over.validateLimits());
    }
}

test "structural command preflight projection does not walk retained capacity" {
    const SimulationTier = @import("../simulation_scope.zig").SimulationTier;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const first = try data.createEntity();
    const second = try data.createEntity();

    var scratch = StructuralPlanScratch.init(std.testing.allocator);
    defer scratch.deinit();

    // Slots a retained 2-entry map keeps. room + 1 does not fit in that map.
    var retained = std.AutoHashMapUnmanaged(u64, u8){};
    defer retained.deinit(std.testing.allocator);
    try retained.ensureTotalCapacity(std.testing.allocator, 2);
    const old_capacity = retained.capacity();
    const room = retained.available;
    try std.testing.expect(old_capacity > 0);
    try std.testing.expect(room > 0);

    const destroys = [_]StructuralCommand{
        .{ .destroy_entity = first },
        .{ .destroy_entity = second },
    };
    const projected = try preflightStructuralCommands(&data, &destroys, &scratch);
    try std.testing.expectEqual(@as(usize, 2), projected.command_count);
    try std.testing.expectEqual(@as(usize, 2), projected.structural_event_count);
    try std.testing.expectEqual(@as(u32, 0), scratch.projected_entities.count());
    try std.testing.expectEqual(@as(u32, 0), scratch.projected_entities.capacity());

    const later = [_]StructuralCommand{
        .{ .destroy_entity = first },
    };
    const again = try preflightStructuralCommands(&data, &later, &scratch);
    try std.testing.expectEqual(@as(usize, 1), again.command_count);
    try std.testing.expectEqual(@as(usize, 1), again.structural_event_count);
    try std.testing.expectEqual(@as(u32, 0), scratch.projected_entities.count());
    try std.testing.expectEqual(@as(u32, 0), scratch.projected_entities.capacity());
    try std.testing.expect(scratch.projected_entities.capacity() != old_capacity);

    const tier_count: usize = @as(usize, room) + 1;
    var tier_commands: std.ArrayList(StructuralCommand) = .empty;
    defer tier_commands.deinit(std.testing.allocator);
    try tier_commands.ensureTotalCapacity(std.testing.allocator, tier_count);
    for (0..tier_count) |_| {
        tier_commands.appendAssumeCapacity(.{
            .set_simulation_tier = .{ .entity = first, .tier = SimulationTier.dormant },
        });
    }
    try data.collision_allow_records.ensureTotalCapacity(
        std.testing.allocator,
        data.collision_allow_records.items.len + tier_commands.items.len * 2,
    );

    scratch.projected_entities.available = 0;
    const data_allocator = data.allocator;
    const scratch_allocator = scratch.allocator;
    scratch.reuse_generations.deinit(std.testing.allocator);
    scratch.reuse_generations = .empty;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    data.allocator = failing.allocator();
    scratch.allocator = failing.allocator();
    defer data.allocator = data_allocator;
    defer scratch.allocator = scratch_allocator;

    const empty = try preflightStructuralCommands(&data, &.{}, &scratch);
    try std.testing.expectEqual(@as(usize, 0), empty.command_count);
    try std.testing.expectEqual(@as(usize, 0), empty.structural_event_count);
    try std.testing.expectEqual(@as(u32, 0), scratch.projected_entities.count());
    try std.testing.expectEqual(@as(u32, 0), scratch.projected_entities.capacity());
    try std.testing.expectEqual(@as(u32, 0), scratch.projected_entities.available);

    const tier_only = try preflightStructuralCommands(&data, tier_commands.items, &scratch);
    try std.testing.expectEqual(tier_count, tier_only.command_count);
    try std.testing.expectEqual(@as(usize, 0), tier_only.structural_event_count);
    try std.testing.expectEqual(@as(u32, 0), scratch.projected_entities.count());
    try std.testing.expectEqual(@as(u32, 0), scratch.projected_entities.capacity());
    try std.testing.expectEqual(@as(u32, 0), scratch.projected_entities.available);
}
