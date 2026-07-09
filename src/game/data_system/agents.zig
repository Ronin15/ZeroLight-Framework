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
const max_ai_gain = types.max_ai_gain;
const ConstAiAgentSlice = types.ConstAiAgentSlice;
const AiAgentSlice = types.AiAgentSlice;
const SteeringAgent = types.SteeringAgent;
const max_steering_radius = types.max_steering_radius;
const max_steering_weight = types.max_steering_weight;
const max_steering_neighbor_samples = types.max_steering_neighbor_samples;
const max_steering_cooldown_steps = types.max_steering_cooldown_steps;
const ConstSteeringAgentSlice = types.ConstSteeringAgentSlice;
const hotStoreCapacity = types.hotStoreCapacity;

pub fn validateAiAgent(agent: AiAgent) !void {
    const gains = [_]f32{ agent.gain_wander, agent.gain_pursue, agent.gain_flee, agent.gain_investigate, agent.gain_cohere };
    for (gains) |gain| {
        if (!std.math.isFinite(gain) or gain < 0 or gain > max_ai_gain) return error.InvalidAiAgent;
    }
    if (!std.math.isFinite(agent.wander_amplitude) or agent.wander_amplitude < 0 or agent.wander_amplitude > max_ai_wander_amplitude) {
        return error.InvalidAiAgent;
    }
    if (!std.math.isFinite(agent.sticky_bonus) or agent.sticky_bonus < 0) return error.InvalidAiAgent;
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
    // Cold
    gain_wander: f32,
    gain_pursue: f32,
    gain_flee: f32,
    gain_investigate: f32,
    gain_cohere: f32,
    wander_amplitude: f32,
    commitment_max_steps: u16,
    sticky_bonus: f32,
    // Hot
    active_behavior: AiBehavior,
    commitment_remaining: u16,
    last_score: f32,
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
            .gain_wander = agent.gain_wander,
            .gain_pursue = agent.gain_pursue,
            .gain_flee = agent.gain_flee,
            .gain_investigate = agent.gain_investigate,
            .gain_cohere = agent.gain_cohere,
            .wander_amplitude = agent.wander_amplitude,
            .commitment_max_steps = agent.commitment_max_steps,
            .sticky_bonus = agent.sticky_bonus,
            .active_behavior = agent.active_behavior,
            .commitment_remaining = agent.commitment_remaining,
            .last_score = agent.last_score,
        });
        return index;
    }

    /// Updates only the cold personality tunables on an existing row. A
    /// retune must not wipe live arbitration state, so the hot columns
    /// (active_behavior, commitment_remaining, last_score) are left
    /// untouched — mirrors `PerceptionStore.set`.
    pub fn set(self: *AiAgentStore, index: usize, agent: AiAgent) void {
        const s = self.rows.slice();
        s.items(.gain_wander)[index] = agent.gain_wander;
        s.items(.gain_pursue)[index] = agent.gain_pursue;
        s.items(.gain_flee)[index] = agent.gain_flee;
        s.items(.gain_investigate)[index] = agent.gain_investigate;
        s.items(.gain_cohere)[index] = agent.gain_cohere;
        s.items(.wander_amplitude)[index] = agent.wander_amplitude;
        s.items(.commitment_max_steps)[index] = agent.commitment_max_steps;
        s.items(.sticky_bonus)[index] = agent.sticky_bonus;
    }

    pub fn get(self: *const AiAgentStore, index: usize) AiAgent {
        const s = self.rows.slice();
        return .{
            .gain_wander = s.items(.gain_wander)[index],
            .gain_pursue = s.items(.gain_pursue)[index],
            .gain_flee = s.items(.gain_flee)[index],
            .gain_investigate = s.items(.gain_investigate)[index],
            .gain_cohere = s.items(.gain_cohere)[index],
            .wander_amplitude = s.items(.wander_amplitude)[index],
            .commitment_max_steps = s.items(.commitment_max_steps)[index],
            .sticky_bonus = s.items(.sticky_bonus)[index],
            .active_behavior = s.items(.active_behavior)[index],
            .commitment_remaining = s.items(.commitment_remaining)[index],
            .last_score = s.items(.last_score)[index],
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
            .behaviors = s.items(.active_behavior),
            .wander_amplitudes = s.items(.wander_amplitude),
            .gain_wanders = s.items(.gain_wander),
            .gain_pursues = s.items(.gain_pursue),
            .gain_flees = s.items(.gain_flee),
            .gain_investigates = s.items(.gain_investigate),
            .gain_coheres = s.items(.gain_cohere),
            .commitment_max_steps = s.items(.commitment_max_steps),
            .sticky_bonus = s.items(.sticky_bonus),
            .commitment_remaining = s.items(.commitment_remaining),
            .last_score = s.items(.last_score),
        };
    }

    /// Mutable view for arbitration's per-step sticky-selection write-back.
    /// Cold personality tunables stay const here — they change only through
    /// `AiAgentStore.set`, mirroring `PerceptionStore.slice`.
    pub fn slice(self: *AiAgentStore) AiAgentSlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .active_behavior = s.items(.active_behavior),
            .commitment_remaining = s.items(.commitment_remaining),
            .last_score = s.items(.last_score),
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

test "validateAiAgent accepts defaults and the max_ai_gain boundary, rejects each gain individually" {
    try validateAiAgent(.{});
    try validateAiAgent(.{
        .gain_wander = max_ai_gain,
        .gain_pursue = max_ai_gain,
        .gain_flee = max_ai_gain,
        .gain_investigate = max_ai_gain,
        .gain_cohere = max_ai_gain,
    });

    try std.testing.expectError(error.InvalidAiAgent, validateAiAgent(.{ .gain_wander = -0.1 }));
    try std.testing.expectError(error.InvalidAiAgent, validateAiAgent(.{ .gain_pursue = max_ai_gain + 1.0 }));
    try std.testing.expectError(error.InvalidAiAgent, validateAiAgent(.{ .gain_flee = std.math.inf(f32) }));
    try std.testing.expectError(error.InvalidAiAgent, validateAiAgent(.{ .gain_investigate = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidAiAgent, validateAiAgent(.{ .gain_cohere = -1.0 }));
}

test "validateAiAgent rejects out-of-range wander_amplitude and sticky_bonus" {
    try std.testing.expectError(error.InvalidAiAgent, validateAiAgent(.{ .wander_amplitude = -1 }));
    try std.testing.expectError(error.InvalidAiAgent, validateAiAgent(.{ .wander_amplitude = max_ai_wander_amplitude + 1 }));
    try std.testing.expectError(error.InvalidAiAgent, validateAiAgent(.{ .wander_amplitude = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidAiAgent, validateAiAgent(.{ .sticky_bonus = -0.01 }));
    try std.testing.expectError(error.InvalidAiAgent, validateAiAgent(.{ .sticky_bonus = std.math.inf(f32) }));
}

test "AiAgentStore.set retunes only cold personality fields, preserving hot arbitration state" {
    var store = AiAgentStore{};
    defer store.deinit(std.testing.allocator);

    const entity = try EntityId.init(1, 1);
    _ = try store.append(std.testing.allocator, entity, .{ .active_behavior = .pursue, .commitment_remaining = 12, .last_score = 0.75 });

    store.set(0, .{ .gain_wander = 0.2, .gain_pursue = 0.8, .wander_amplitude = 15, .commitment_max_steps = 40, .sticky_bonus = 0.05 });

    const after = store.get(0);
    try std.testing.expectEqual(@as(f32, 0.2), after.gain_wander);
    try std.testing.expectEqual(@as(f32, 0.8), after.gain_pursue);
    try std.testing.expectEqual(@as(f32, 15), after.wander_amplitude);
    try std.testing.expectEqual(@as(u16, 40), after.commitment_max_steps);
    try std.testing.expectEqual(@as(f32, 0.05), after.sticky_bonus);
    // Hot fields from the original append are untouched by the retune.
    try std.testing.expectEqual(AiBehavior.pursue, after.active_behavior);
    try std.testing.expectEqual(@as(u16, 12), after.commitment_remaining);
    try std.testing.expectEqual(@as(f32, 0.75), after.last_score);
}

test "AiAgentStore.slice exposes a mutable hot-column view aligned with sliceConst" {
    var store = AiAgentStore{};
    defer store.deinit(std.testing.allocator);

    const first = try EntityId.init(1, 1);
    const second = try EntityId.init(2, 1);
    _ = try store.append(std.testing.allocator, first, .{});
    _ = try store.append(std.testing.allocator, second, .{});

    var hot = store.slice();
    try std.testing.expectEqual(@as(usize, 2), hot.entities.len);
    hot.active_behavior[1] = .flee;
    hot.commitment_remaining[1] = 5;
    hot.last_score[1] = 1.5;

    const updated = store.get(1);
    try std.testing.expectEqual(AiBehavior.flee, updated.active_behavior);
    try std.testing.expectEqual(@as(u16, 5), updated.commitment_remaining);
    try std.testing.expectEqual(@as(f32, 1.5), updated.last_score);

    const const_slice = store.sliceConst();
    try std.testing.expectEqual(AiBehavior.flee, const_slice.behaviors[1]);
}
