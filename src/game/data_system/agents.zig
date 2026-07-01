// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! AI and steering agent component storage: wander/seek behavior tuning and
//! local-avoidance steering tuning, plus their payload validators (both
//! validate against the shared max_* bounds in types.zig).

const std = @import("std");
const types = @import("types.zig");
const EntityId = types.EntityId;
const AiBehavior = types.AiBehavior;
const AiAgent = types.AiAgent;
const max_ai_wander_amplitude = types.max_ai_wander_amplitude;
const max_ai_seek_weight = types.max_ai_seek_weight;
const ConstAiAgentSlice = types.ConstAiAgentSlice;
const SteeringAgent = types.SteeringAgent;
const max_steering_radius = types.max_steering_radius;
const max_steering_weight = types.max_steering_weight;
const max_steering_neighbor_samples = types.max_steering_neighbor_samples;
const max_steering_cooldown_steps = types.max_steering_cooldown_steps;
const ConstSteeringAgentSlice = types.ConstSteeringAgentSlice;
const hotStoreCapacity = types.hotStoreCapacity;

pub fn validateAiAgent(agent: AiAgent) !void {
    if (!std.math.isFinite(agent.wander_amplitude) or !std.math.isFinite(agent.seek_weight)) return error.InvalidAiAgent;
    if (agent.wander_amplitude < 0 or agent.seek_weight < 0) return error.InvalidAiAgent;
    if (agent.wander_amplitude > max_ai_wander_amplitude or agent.seek_weight > max_ai_seek_weight) return error.InvalidAiAgent;
}

pub fn validateSteeringAgent(agent: SteeringAgent) !void {
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

const AiAgentRow = struct {
    entity: EntityId,
    behavior: AiBehavior,
    wander_amplitude: f32,
    seek_weight: f32,
};

const SteeringAgentRow = struct {
    entity: EntityId,
    agent_radius: f32,
    waypoint_tolerance: f32,
    avoidance_radius: f32,
    avoidance_weight: f32,
    max_neighbor_samples: u16,
    stuck_step_threshold: u16,
    replan_cooldown_steps: u16,
    unavailable_backoff_steps: u16,
};

pub const AiAgentStore = struct {
    rows: std.MultiArrayList(AiAgentRow) = .{},

    pub fn len(self: *const AiAgentStore) usize {
        return self.rows.len;
    }

    pub fn append(self: *AiAgentStore, allocator: std.mem.Allocator, entity: EntityId, agent: AiAgent) !u32 {
        if (self.rows.len >= std.math.maxInt(u32)) return error.TooManyAiAgentRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.rows.len);
        self.rows.appendAssumeCapacity(.{
            .entity = entity,
            .behavior = agent.behavior,
            .wander_amplitude = agent.wander_amplitude,
            .seek_weight = agent.seek_weight,
        });
        return index;
    }

    pub fn set(self: *AiAgentStore, index: usize, agent: AiAgent) void {
        const s = self.rows.slice();
        s.items(.behavior)[index] = agent.behavior;
        s.items(.wander_amplitude)[index] = agent.wander_amplitude;
        s.items(.seek_weight)[index] = agent.seek_weight;
    }

    pub fn get(self: *const AiAgentStore, index: usize) AiAgent {
        const s = self.rows.slice();
        return .{
            .behavior = s.items(.behavior)[index],
            .wander_amplitude = s.items(.wander_amplitude)[index],
            .seek_weight = s.items(.seek_weight)[index],
        };
    }

    pub fn removeAt(self: *AiAgentStore, index: usize) ?EntityId {
        const s = self.rows.slice();
        const last = self.rows.len - 1;
        const moved_entity = if (index != last) s.items(.entity)[last] else null;
        self.rows.swapRemove(index);
        return moved_entity;
    }

    pub fn sliceConst(self: *const AiAgentStore) ConstAiAgentSlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .behaviors = s.items(.behavior),
            .wander_amplitudes = s.items(.wander_amplitude),
            .seek_weights = s.items(.seek_weight),
        };
    }

    pub fn clearRetainingCapacity(self: *AiAgentStore) void {
        self.rows.clearRetainingCapacity();
    }

    pub fn deinit(self: *AiAgentStore, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *AiAgentStore, allocator: std.mem.Allocator) !void {
        try self.ensureCapacity(allocator, self.rows.len + 1);
    }

    pub fn ensureCapacity(self: *AiAgentStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.rows.ensureTotalCapacity(allocator, hotStoreCapacity(capacity));
    }
};

pub const SteeringAgentStore = struct {
    rows: std.MultiArrayList(SteeringAgentRow) = .{},

    pub fn len(self: *const SteeringAgentStore) usize {
        return self.rows.len;
    }

    pub fn append(self: *SteeringAgentStore, allocator: std.mem.Allocator, entity: EntityId, agent: SteeringAgent) !u32 {
        if (self.rows.len >= std.math.maxInt(u32)) return error.TooManySteeringAgentRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.rows.len);
        self.rows.appendAssumeCapacity(.{
            .entity = entity,
            .agent_radius = agent.agent_radius,
            .waypoint_tolerance = agent.waypoint_tolerance,
            .avoidance_radius = agent.avoidance_radius,
            .avoidance_weight = agent.avoidance_weight,
            .max_neighbor_samples = agent.max_neighbor_samples,
            .stuck_step_threshold = agent.stuck_step_threshold,
            .replan_cooldown_steps = agent.replan_cooldown_steps,
            .unavailable_backoff_steps = agent.unavailable_backoff_steps,
        });
        return index;
    }

    pub fn set(self: *SteeringAgentStore, index: usize, agent: SteeringAgent) void {
        const s = self.rows.slice();
        s.items(.agent_radius)[index] = agent.agent_radius;
        s.items(.waypoint_tolerance)[index] = agent.waypoint_tolerance;
        s.items(.avoidance_radius)[index] = agent.avoidance_radius;
        s.items(.avoidance_weight)[index] = agent.avoidance_weight;
        s.items(.max_neighbor_samples)[index] = agent.max_neighbor_samples;
        s.items(.stuck_step_threshold)[index] = agent.stuck_step_threshold;
        s.items(.replan_cooldown_steps)[index] = agent.replan_cooldown_steps;
        s.items(.unavailable_backoff_steps)[index] = agent.unavailable_backoff_steps;
    }

    pub fn get(self: *const SteeringAgentStore, index: usize) SteeringAgent {
        const s = self.rows.slice();
        return .{
            .agent_radius = s.items(.agent_radius)[index],
            .waypoint_tolerance = s.items(.waypoint_tolerance)[index],
            .avoidance_radius = s.items(.avoidance_radius)[index],
            .avoidance_weight = s.items(.avoidance_weight)[index],
            .max_neighbor_samples = s.items(.max_neighbor_samples)[index],
            .stuck_step_threshold = s.items(.stuck_step_threshold)[index],
            .replan_cooldown_steps = s.items(.replan_cooldown_steps)[index],
            .unavailable_backoff_steps = s.items(.unavailable_backoff_steps)[index],
        };
    }

    pub fn removeAt(self: *SteeringAgentStore, index: usize) ?EntityId {
        const s = self.rows.slice();
        const last = self.rows.len - 1;
        const moved_entity = if (index != last) s.items(.entity)[last] else null;
        self.rows.swapRemove(index);
        return moved_entity;
    }

    pub fn sliceConst(self: *const SteeringAgentStore) ConstSteeringAgentSlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .agent_radii = s.items(.agent_radius),
            .waypoint_tolerances = s.items(.waypoint_tolerance),
            .avoidance_radii = s.items(.avoidance_radius),
            .avoidance_weights = s.items(.avoidance_weight),
            .max_neighbor_samples = s.items(.max_neighbor_samples),
            .stuck_step_thresholds = s.items(.stuck_step_threshold),
            .replan_cooldown_steps = s.items(.replan_cooldown_steps),
            .unavailable_backoff_steps = s.items(.unavailable_backoff_steps),
        };
    }

    pub fn clearRetainingCapacity(self: *SteeringAgentStore) void {
        self.rows.clearRetainingCapacity();
    }

    pub fn deinit(self: *SteeringAgentStore, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *SteeringAgentStore, allocator: std.mem.Allocator) !void {
        try self.ensureCapacity(allocator, self.rows.len + 1);
    }

    pub fn ensureCapacity(self: *SteeringAgentStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.rows.ensureTotalCapacity(allocator, hotStoreCapacity(capacity));
    }
};
