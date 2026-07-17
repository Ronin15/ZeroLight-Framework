// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Deferred structural-command pipeline: capacity preflight (projects the
//! command stream against current liveness/masks without touching real slots
//! or dense stores), then command-order commit through DataSystem's already-
//! pub accessor methods. Mirrors pathfinding/solve.zig's relationship to
//! system.zig: these are free functions that borrow *DataSystem explicitly
//! rather than living as DataSystem methods, keeping the wiring flat.

const std = @import("std");
const math = @import("../../core/math.zig");
const types = @import("types.zig");
const EntityId = types.EntityId;
const Component = types.Component;
const ComponentMask = types.ComponentMask;
const componentMask = types.componentMask;
const EntityTemplate = types.EntityTemplate;
const StructuralCommand = types.StructuralCommand;
const StructuralCommitStats = types.StructuralCommitStats;
const StructuralChange = types.StructuralChange;
const ObstacleWorldRect = types.ObstacleWorldRect;
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
// StructuralCommand payload shape (see validateStructuralCommands else branch).

pub const NullStructuralChangeSink = struct {
    fn record(_: *NullStructuralChangeSink, _: StructuralChange) void {}
};

pub const NullStructuralCommitPreparer = struct {
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
        if (self.world_levels > std.math.maxInt(u32)) return error.TooManyWorldLevelRows;
        if (self.factions > std.math.maxInt(u32)) return error.TooManyFactionRows;
        if (self.ai_perceptions > std.math.maxInt(u32)) return error.TooManyAiPerceptionRows;
        if (self.ai_memories > std.math.maxInt(u32)) return error.TooManyAiMemoryRows;
        if (self.ai_affects > std.math.maxInt(u32)) return error.TooManyAiAffectRows;
        if (self.destructibles > std.math.maxInt(u32)) return error.TooManyDestructibleRows;
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

// Module-pub (not facade-exported): system.zig's preflightStructuralCommands
// wrapper needs to name this return type across the file boundary. Tests
// never spell it directly (they use the inferred `try data.preflightStructuralCommands(...)`).
pub const StructuralCommitPlan = struct {
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
        // resolveSlotConst is private to system.zig; isAlive+componentMaskFor are
        // the equivalent already-pub accessors (same result, one extra lookup,
        // off the movement/collision hot path).
        if (!data.isAlive(entity)) return .{ .alive = false, .component_mask = 0 };
        return .{
            .alive = true,
            .component_mask = data.componentMaskFor(entity),
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
    if (template.world_level != null) count += 1;
    if (template.faction != null) count += 1;
    if (template.ai_perception != null) count += 1;
    if (template.ai_memory != null) count += 1;
    if (template.ai_affect != null) count += 1;
    if (template.destructible != null) count += 1;
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
    // Prepared commits split allocation/preparation from mutation so callers
    // can reuse scratch and reserve their own event buffers ahead of time.
    const plan = try preflightStructuralCommands(self, commands, scratch);
    try preparer.prepare(plan.structural_event_count);
    // No allocations or event-capacity failures should occur after this
    // point; the commit loop can mutate DataSystem in command order.
    return try commitStructuralCommands(self, commands, change_sink);
}

/// File-private: only `applyStructuralCommandsPrepared` (and its unprepared
/// wrappers) may commit. Callers must go through preflight/prepared entry points
/// so capacity is reserved before mutation.
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
                stats.components_set += try applyTemplateComponents(self, entity, template);
                stats.created += 1;
                change_sink.record(.{ .entity_created = entity });
                recordTemplateComponentChanges(self, change_sink, entity, template);
            },
            .destroy_entity => |entity| {
                const component_mask = self.componentMaskFor(entity);
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(entity);
                const obstacle_world_rect = if (was_static_navigation_obstacle) self.staticObstacleWorldRect(entity) else null;
                if (self.destroyEntity(entity)) {
                    stats.destroyed += 1;
                    change_sink.record(.{ .entity_destroyed = .{
                        .entity = entity,
                        .component_mask = component_mask,
                        .was_static_navigation_obstacle = was_static_navigation_obstacle,
                        .obstacle_world_rect = obstacle_world_rect,
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
                const old_rect = if (was_static_navigation_obstacle) self.staticObstacleWorldRect(set.entity) else null;
                try self.setMovementBody(set.entity, set.body);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .movement_body, was_static_navigation_obstacle, old_rect);
            },
            .set_facing => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setFacing(set.entity, set.facing);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .facing, was_static_navigation_obstacle, null);
            },
            .set_primitive_visual => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setPrimitiveVisual(set.entity, set.visual);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .primitive_visual, was_static_navigation_obstacle, null);
            },
            .set_asset_reference => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setAssetReference(set.entity, set.asset_reference);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .asset_reference, was_static_navigation_obstacle, null);
            },
            .set_collision_bounds => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                const old_rect = if (was_static_navigation_obstacle) self.staticObstacleWorldRect(set.entity) else null;
                try self.setCollisionBounds(set.entity, set.bounds);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .collision_bounds, was_static_navigation_obstacle, old_rect);
            },
            .set_collision_response => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                const old_rect = if (was_static_navigation_obstacle) self.staticObstacleWorldRect(set.entity) else null;
                try self.setCollisionResponse(set.entity, set.response);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .collision_response, was_static_navigation_obstacle, old_rect);
            },
            .set_ai_agent => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setAiAgent(set.entity, set.agent);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .ai_agent, was_static_navigation_obstacle, null);
            },
            .set_steering_agent => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setSteeringAgent(set.entity, set.agent);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .steering_agent, was_static_navigation_obstacle, null);
            },
            .set_world_level => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setWorldLevel(set.entity, set.level);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .world_level, was_static_navigation_obstacle, null);
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
                recordComponentChange(self, change_sink, set.entity, .faction, was_static_navigation_obstacle, null);
            },
            .set_ai_perception => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setAiPerception(set.entity, set.perception);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .ai_perception, was_static_navigation_obstacle, null);
            },
            .set_ai_memory => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setAiMemory(set.entity, set.memory);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .ai_memory, was_static_navigation_obstacle, null);
            },
            .set_ai_affect => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setAiAffect(set.entity, set.affect);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .ai_affect, was_static_navigation_obstacle, null);
            },
            .set_destructible => |set| {
                if (!self.isAlive(set.entity)) {
                    stats.stale_skipped += 1;
                    continue;
                }
                const was_static_navigation_obstacle = self.isStaticNavigationObstacle(set.entity);
                try self.setDestructible(set.entity, set.destructible);
                stats.components_set += 1;
                recordComponentChange(self, change_sink, set.entity, .destructible, was_static_navigation_obstacle, null);
            },
        }
    }
    return stats;
}

pub fn preflightStructuralCommands(
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
            .set_movement_body => |set| try preflightSetComponent(self, set.entity, .movement_body, scratch, &projection, &structural_event_count),
            .set_facing => |set| try preflightSetComponent(self, set.entity, .facing, scratch, &projection, &structural_event_count),
            .set_primitive_visual => |set| try preflightSetComponent(self, set.entity, .primitive_visual, scratch, &projection, &structural_event_count),
            .set_asset_reference => |set| try preflightSetComponent(self, set.entity, .asset_reference, scratch, &projection, &structural_event_count),
            .set_collision_bounds => |set| try preflightSetComponent(self, set.entity, .collision_bounds, scratch, &projection, &structural_event_count),
            .set_collision_response => |set| try preflightSetComponent(self, set.entity, .collision_response, scratch, &projection, &structural_event_count),
            .set_ai_agent => |set| try preflightSetComponent(self, set.entity, .ai_agent, scratch, &projection, &structural_event_count),
            .set_steering_agent => |set| try preflightSetComponent(self, set.entity, .steering_agent, scratch, &projection, &structural_event_count),
            .set_world_level => |set| try preflightSetComponent(self, set.entity, .world_level, scratch, &projection, &structural_event_count),
            .set_faction => |set| try preflightSetComponent(self, set.entity, .faction, scratch, &projection, &structural_event_count),
            .set_ai_perception => |set| try preflightSetComponent(self, set.entity, .ai_perception, scratch, &projection, &structural_event_count),
            .set_ai_memory => |set| try preflightSetComponent(self, set.entity, .ai_memory, scratch, &projection, &structural_event_count),
            .set_ai_affect => |set| try preflightSetComponent(self, set.entity, .ai_affect, scratch, &projection, &structural_event_count),
            .set_destructible => |set| try preflightSetComponent(self, set.entity, .destructible, scratch, &projection, &structural_event_count),
            .set_simulation_tier => {},
        }
    }

    try projection.required.validateLimits();
    const plan = StructuralCommitPlan{
        .command_count = commands.len,
        .capacity_needs = projection.required,
        .structural_event_count = structural_event_count,
    };
    try reserveStructuralPlanCapacity(self, plan);
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
    try self.world_levels.ensureCapacity(self.allocator, plan.capacity_needs.world_levels);
    try self.factions.ensureCapacity(self.allocator, plan.capacity_needs.factions);
    try self.ai_perceptions.ensureCapacity(self.allocator, plan.capacity_needs.ai_perceptions);
    try self.ai_memories.ensureCapacity(self.allocator, plan.capacity_needs.ai_memories);
    try self.ai_affects.ensureCapacity(self.allocator, plan.capacity_needs.ai_affects);
    try self.destructibles.ensureCapacity(self.allocator, plan.capacity_needs.destructibles);
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
            .set_movement_body => |set| try validateMovementBody(set.body),
            .set_primitive_visual => |set| try validatePrimitiveVisual(set.visual),
            .set_collision_bounds => |set| try validateCollisionBounds(set.bounds),
            .set_collision_response => |set| try validateCollisionResponse(set.response),
            .set_ai_agent => |set| try validateAiAgent(set.agent),
            .set_steering_agent => |set| try validateSteeringAgent(set.agent),
            .set_ai_perception => |set| try validateAiPerception(set.perception),
            .set_ai_memory => |set| try validateAiMemory(set.memory),
            .set_ai_affect => |set| try validateAiAffect(set.affect),
            else => {},
        }
    }
}

fn recordTemplateComponentChanges(self: *const DataSystem, change_sink: anytype, entity: EntityId, template: EntityTemplate) void {
    // applyTemplateComponents (called before this) already applied every template
    // component, so a fresh entity never has a real "before this component" obstacle
    // state to report: every event here passes was_static_navigation_obstacle = false
    // and old_obstacle_world_rect = null (nothing to clear). recordComponentChange still
    // computes the live is/new side from the (already fully applied) entity, so the
    // component whose event completes movement_body + collision_bounds + a static
    // collision_response correctly reports the new obstacle rect.
    if (template.movement_body != null) recordComponentChange(self, change_sink, entity, .movement_body, false, null);
    if (template.facing != null) recordComponentChange(self, change_sink, entity, .facing, false, null);
    if (template.primitive_visual != null) recordComponentChange(self, change_sink, entity, .primitive_visual, false, null);
    if (template.asset_reference != null) recordComponentChange(self, change_sink, entity, .asset_reference, false, null);
    if (template.collision_bounds != null) recordComponentChange(self, change_sink, entity, .collision_bounds, false, null);
    if (template.collision_response != null) recordComponentChange(self, change_sink, entity, .collision_response, false, null);
    if (template.ai_agent != null) recordComponentChange(self, change_sink, entity, .ai_agent, false, null);
    if (template.steering_agent != null) recordComponentChange(self, change_sink, entity, .steering_agent, false, null);
    if (template.world_level != null) recordComponentChange(self, change_sink, entity, .world_level, false, null);
    if (template.faction != null) recordComponentChange(self, change_sink, entity, .faction, false, null);
    if (template.ai_perception != null) recordComponentChange(self, change_sink, entity, .ai_perception, false, null);
    if (template.ai_memory != null) recordComponentChange(self, change_sink, entity, .ai_memory, false, null);
    if (template.ai_affect != null) recordComponentChange(self, change_sink, entity, .ai_affect, false, null);
    if (template.destructible != null) recordComponentChange(self, change_sink, entity, .destructible, false, null);
}

fn recordComponentChange(self: *const DataSystem, change_sink: anytype, entity: EntityId, component: Component, was_static_navigation_obstacle: bool, old_rect: ?ObstacleWorldRect) void {
    const is_static_navigation_obstacle = self.isStaticNavigationObstacle(entity);
    change_sink.record(.{ .component_changed = .{
        .entity = entity,
        .component = component,
        .was_static_navigation_obstacle = was_static_navigation_obstacle,
        .is_static_navigation_obstacle = is_static_navigation_obstacle,
        .old_obstacle_world_rect = old_rect,
        .new_obstacle_world_rect = if (is_static_navigation_obstacle) self.staticObstacleWorldRect(entity) else null,
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
    if (template.world_level) |level| {
        try self.setWorldLevel(entity, level);
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
    return components_set;
}

test "StructuralCapacityNeeds.validateLimits rejects an ai_perceptions count beyond u32" {
    // Growing PerceptionStore to u32-max rows is impractical to exercise for
    // real, so this proves the guard directly against the private capacity
    // struct rather than via an actual oversized store.
    var needs = std.mem.zeroes(StructuralCapacityNeeds);
    try needs.validateLimits();

    needs.ai_perceptions = @as(usize, std.math.maxInt(u32)) + 1;
    try std.testing.expectError(error.TooManyAiPerceptionRows, needs.validateLimits());
}

test "StructuralCapacityNeeds.validateLimits rejects an ai_memories count beyond u32" {
    // Growing AiMemoryStore to u32-max rows is impractical to exercise for
    // real, so this proves the guard directly against the private capacity
    // struct rather than via an actual oversized store.
    var needs = std.mem.zeroes(StructuralCapacityNeeds);
    try needs.validateLimits();

    needs.ai_memories = @as(usize, std.math.maxInt(u32)) + 1;
    try std.testing.expectError(error.TooManyAiMemoryRows, needs.validateLimits());
}

test "StructuralCapacityNeeds.validateLimits rejects an ai_affects count beyond u32" {
    // Growing AiAffectStore to u32-max rows is impractical to exercise for
    // real, so this proves the guard directly against the private capacity
    // struct rather than via an actual oversized store.
    var needs = std.mem.zeroes(StructuralCapacityNeeds);
    try needs.validateLimits();

    needs.ai_affects = @as(usize, std.math.maxInt(u32)) + 1;
    try std.testing.expectError(error.TooManyAiAffectRows, needs.validateLimits());
}

test "StructuralCapacityNeeds.validateLimits rejects a destructibles count beyond u32" {
    var needs = std.mem.zeroes(StructuralCapacityNeeds);
    try needs.validateLimits();

    needs.destructibles = @as(usize, std.math.maxInt(u32)) + 1;
    try std.testing.expectError(error.TooManyDestructibleRows, needs.validateLimits());
}

// Test-local capturing change sink: NullStructuralChangeSink (used by every other test in
// this file) discards the StructuralChange payload entirely, so it cannot exercise the
// obstacle-rect fields below. Grows via the real allocator (test-only; production commits
// always reserve their own sink ahead of mutation, e.g. SimulationFrame's StructuralChangeSink).
const CapturingChangeSink = struct {
    changes: std.ArrayList(StructuralChange) = .empty,

    fn record(self: *CapturingChangeSink, change: StructuralChange) void {
        self.changes.append(std.testing.allocator, change) catch @panic("test allocation failure");
    }

    fn deinit(self: *CapturingChangeSink) void {
        self.changes.deinit(std.testing.allocator);
    }
};

test "commitStructuralCommands emits obstacle world rects across create, move, and destroy of a static nav obstacle" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    var sink = CapturingChangeSink{};
    defer sink.deinit();

    const position = math.Vec2{ .x = 10, .y = 20 };
    const offset = math.Vec2{ .x = 1, .y = 2 };
    const size = math.Vec2{ .x = 8, .y = 4 };
    const template = EntityTemplate{
        .movement_body = .{ .position = position, .previous_position = position },
        .collision_bounds = .{ .offset = offset, .size = size },
        .collision_response = .{ .mobility = .static },
    };

    _ = try applyStructuralCommandsWithChangeSink(&data, &.{.{ .create_entity = template }}, &sink);

    const expected_rect = ObstacleWorldRect{
        .min_x = position.x + offset.x,
        .min_y = position.y + offset.y,
        .max_x = position.x + offset.x + size.x,
        .max_y = position.y + offset.y + size.y,
    };

    var created_entity: ?EntityId = null;
    var create_new_rect: ?ObstacleWorldRect = null;
    for (sink.changes.items) |change| {
        switch (change) {
            .entity_created => |entity| created_entity = entity,
            .component_changed => |changed| {
                if (changed.component == .collision_response) create_new_rect = changed.new_obstacle_world_rect;
            },
            else => {},
        }
    }
    const entity = created_entity orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(expected_rect, create_new_rect orelse return error.TestExpectedEqual);

    sink.changes.clearRetainingCapacity();

    const moved_position = math.Vec2{ .x = 100, .y = 200 };
    _ = try applyStructuralCommandsWithChangeSink(&data, &.{.{ .set_movement_body = .{
        .entity = entity,
        .body = .{ .position = moved_position, .previous_position = moved_position },
    } }}, &sink);

    const expected_new_rect = ObstacleWorldRect{
        .min_x = moved_position.x + offset.x,
        .min_y = moved_position.y + offset.y,
        .max_x = moved_position.x + offset.x + size.x,
        .max_y = moved_position.y + offset.y + size.y,
    };

    try std.testing.expectEqual(@as(usize, 1), sink.changes.items.len);
    const move_change = sink.changes.items[0].component_changed;
    try std.testing.expectEqual(expected_rect, move_change.old_obstacle_world_rect orelse return error.TestExpectedEqual);
    try std.testing.expectEqual(expected_new_rect, move_change.new_obstacle_world_rect orelse return error.TestExpectedEqual);

    sink.changes.clearRetainingCapacity();

    _ = try applyStructuralCommandsWithChangeSink(&data, &.{.{ .destroy_entity = entity }}, &sink);
    try std.testing.expectEqual(@as(usize, 1), sink.changes.items.len);
    const destroy_change = sink.changes.items[0].entity_destroyed;
    try std.testing.expectEqual(expected_new_rect, destroy_change.obstacle_world_rect orelse return error.TestExpectedEqual);
}
