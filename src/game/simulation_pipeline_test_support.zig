// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared private fixtures: tuner pins for the pipeline's tests and the benches' dispatch
//! checks, the named tuner walk the benches' census reads, the steering-after-commit scene
//! the pipeline's seam tests and the demo's nav-OOM test drive, and the one-agent pipeline
//! fixture both files' seam and event-budget tests build. Test-only: no production path
//! imports it.

const std = @import("std");
const math = @import("../core/math.zig");
const AdaptiveWorkProfile = @import("../app/thread_system.zig").AdaptiveWorkProfile;
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const DataSystem = @import("data_system.zig").DataSystem;
const EntityId = @import("data_system.zig").EntityId;
const StructuralCommand = @import("data_system.zig").StructuralCommand;
const SimulationFrame = @import("simulation.zig").SimulationFrame;
const SimulationPipeline = @import("simulation_pipeline.zig").SimulationPipeline;
const WorldSystem = @import("world/system.zig").WorldSystem;
const updateSteeringInline = @import("systems/steering/test_support.zig").updateSteeringInline;

/// Pins every pipeline batch tuner to one settled threaded `profile` that never
/// nudges, demotes, or resets on item-count drift, so the multi-worker path runs a
/// deterministic multi-range partition. The tuners would otherwise pick the shape from
/// timing (inline below `threaded_batch_ns`). The tuners are found by walking the
/// pipeline's fields at comptime, so a tuner a system adds is pinned with it.
pub fn pinPipelineThreadedProfiles(pipeline: *SimulationPipeline, profile: AdaptiveWorkProfile) void {
    pinTunersIn(SimulationPipeline, pipeline, profile);
}

/// Pins every `AdaptiveWorkTuner` `value` holds by value: itself, or in a struct field, an
/// array element, or a set optional, at any depth. A single pointer is not owned, so it is
/// not walked.
pub fn pinTunersIn(comptime T: type, value: *T, profile: AdaptiveWorkProfile) void {
    var pin = PinVisitor{ .profile = profile };
    forEachTunerIn(T, value, "", &pin);
}

const PinVisitor = struct {
    profile: AdaptiveWorkProfile,

    pub fn visit(self: *PinVisitor, comptime _: []const u8, tuner: *AdaptiveWorkTuner) void {
        pinThreadedProfile(tuner, self.profile);
    }
};

/// Calls `visitor.visit(comptime path, tuner)` on every `AdaptiveWorkTuner` `value` holds by
/// value, in field order, as `pinTunersIn` pins them. `path` is `root_path` plus each field
/// name (`.name`) and array element (`[i]`) to the tuner, so it names one tuner.
pub fn forEachTunerIn(comptime T: type, value: *T, comptime root_path: []const u8, visitor: anytype) void {
    if (T == AdaptiveWorkTuner) return visitor.visit(root_path, value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| {
            if (comptime holdsTuner(Field)) forEachTunerIn(Field, &@field(value, name), root_path ++ "." ++ name, visitor);
        },
        .array => |info| inline for (0..info.len) |index| {
            forEachTunerIn(info.child, &value[index], root_path ++ std.fmt.comptimePrint("[{d}]", .{index}), visitor);
        },
        .optional => |info| if (value.*) |*payload| forEachTunerIn(info.child, payload, root_path, visitor),
        else => {},
    }
}

// Whether a `T` holds an `AdaptiveWorkTuner` where `forEachTunerIn` walks. A tuner the walk
// cannot reach fails the build: in a union (which variant is live), behind a slice or
// many-item pointer (owned heap rows), or in an error-union payload.
fn holdsTuner(comptime T: type) bool {
    @setEvalBranchQuota(100_000);
    if (T == AdaptiveWorkTuner) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => |info| for (info.field_types) |Field| {
            if (holdsTuner(Field)) break true;
        } else false,
        .array => |info| holdsTuner(info.child),
        .optional => |info| holdsTuner(info.child),
        .@"union" => |info| for (info.field_types) |Field| {
            if (holdsTuner(Field)) @compileError("forEachTunerIn cannot walk a tuner in union " ++ @typeName(T));
        } else false,
        .pointer => |info| switch (info.size) {
            .one => false,
            .slice, .many, .c => if (holdsTuner(info.child)) @compileError("forEachTunerIn cannot walk a tuner behind " ++ @typeName(T)) else false,
        },
        .error_union => |info| if (holdsTuner(info.payload)) @compileError("forEachTunerIn cannot walk a tuner in error union " ++ @typeName(T)) else false,
        else => false,
    };
}

/// Pins one tuner as `pinTunersIn` does.
pub fn pinThreadedProfile(tuner: *AdaptiveWorkTuner, profile: AdaptiveWorkProfile) void {
    tuner.config.threaded_batch_ns = 0;
    tuner.config.item_count_reset_percent = std.math.maxInt(u8);
    tuner.config.nudge_samples = std.math.maxInt(usize);
    tuner.phase = .settled;
    tuner.has_threaded_profile = true;
    tuner.current_profile = profile;
    tuner.candidate_profile = null;
    // A learned count no item count can grow past by the 255% reset band (nor shrink
    // past), so no count shift ever reshapes the pin.
    tuner.learned_item_count = std.math.maxInt(usize) / 256;
}

/// One steering step for `agent` heading +x; returns its lateral (y) direction.
pub fn lateralSteeringOnce(pipeline: *SimulationPipeline, frame: *SimulationFrame, data: *const DataSystem, agent: EntityId, goal: math.Vec2) !f32 {
    frame.beginStep();
    try frame.navigation_intents.prepareRangeCounts(1);
    frame.navigation_intents.addCount(0, 1);
    try frame.navigation_intents.prefix();
    var writer = frame.navigation_intents.rangeWriter(0);
    writer.write(.{ .entity = agent, .goal = goal, .direct_direction_x = 1 });
    writer.finish();
    frame.navigation_intents.finishWrite();
    _ = try updateSteeringInline(&pipeline.steering, data, frame, &pipeline.pathfinding, &pipeline.static_colliders);
    for (frame.intents.mergedItems()) |intent| {
        if (intent.movement.entity.eql(agent)) return intent.movement.direction_y;
    }
    return error.TestExpectedEqual;
}

pub const SteeringBox = struct {
    agent: EntityId,
    box: EntityId,
    goal: math.Vec2,
    // Ahead of and above (-y) the agent: steering pushes it toward +y.
    beside: math.Vec2,
};

/// A steering agent heading +x and a static box parked far from it, on `level`. The agent
/// is created last, so it is the last movement row: destroying any earlier movement body
/// swap-removes the agent into that body's row.
pub fn addSteeringAgentAndParkedBox(data: *DataSystem, level: u16) !SteeringBox {
    const parked = math.Vec2{ .x = 96, .y = 960 };
    const box = try data.createEntity();
    try data.setMovementBody(box, .{ .position = parked, .previous_position = parked, .velocity = .{}, .speed = 0 });
    try data.setCollisionBounds(box, .{ .size = .{ .x = 20, .y = 20 } });
    try data.setCollisionResponse(box, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    try data.setWorldLevel(box, level);
    const agent_position = math.Vec2{ .x = 96, .y = 96 };
    const agent = try data.createEntity();
    try data.setMovementBody(agent, .{ .position = agent_position, .previous_position = agent_position, .velocity = .{}, .speed = 32 });
    try data.setSteeringAgent(agent, .{
        .agent_radius = 8,
        .waypoint_tolerance = 4,
        .avoidance_radius = 48,
        .avoidance_weight = 1.5,
        .max_neighbor_samples = 8,
        .stuck_step_threshold = 3,
        .replan_cooldown_steps = 4,
        .unavailable_backoff_steps = 12,
    });
    try data.setWorldLevel(agent, level);
    return .{
        .agent = agent,
        .box = box,
        .goal = .{ .x = 192, .y = 96 },
        .beside = .{ .x = agent_position.x + 8, .y = agent_position.y - 32 },
    };
}

/// Writes this step's structural commands: one `set_movement_body` moving `box` to
/// `position`, then `extra`.
pub fn writeBoxMove(frame: *SimulationFrame, box: EntityId, position: math.Vec2, extra: []const StructuralCommand) !void {
    try frame.structural_commands.prepareRangeCounts(1);
    frame.structural_commands.addCount(0, 1 + extra.len);
    try frame.structural_commands.prefix();
    var writer = frame.structural_commands.rangeWriter(0);
    writer.write(.{ .set_movement_body = .{ .entity = box, .body = .{ .position = position, .previous_position = position, .velocity = .{}, .speed = 0 } } });
    for (extra) |command| writer.write(command);
    writer.finish();
    frame.structural_commands.finishWrite();
}

/// Steering's last agent snapshot (the positions neighbors avoid) holds `agent` at its own
/// previous position.
pub fn expectSteeringSeesOwnPosition(pipeline: *const SimulationPipeline, data: *const DataSystem, agent: EntityId) !void {
    const own = data.movementBodyConst(agent).?.previous_position;
    const agents = pipeline.steering.agentSnapshotSliceConst();
    for (agents.entity, agents.x, agents.y) |entity, x, y| {
        if (!entity.eql(agent)) continue;
        try std.testing.expectEqual(own, math.Vec2{ .x = x, .y = y });
        return;
    }
    return error.TestExpectedEqual;
}

/// A movement body with no steering or collider component, far from the scene on `level`.
pub fn addBystanderBody(data: *DataSystem, level: u16) !EntityId {
    const far = math.Vec2{ .x = 900, .y = 900 };
    const bystander = try data.createEntity();
    try data.setMovementBody(bystander, .{ .position = far, .previous_position = far, .velocity = .{}, .speed = 0 });
    try data.setWorldLevel(bystander, level);
    return bystander;
}

/// A pipeline over a 1x1 one-level world (64x64 bounds, no navigation world) with a
/// 4-body reserve and the caller's `structural_headroom`, its frame reserved through
/// `reserveFrame`, and one cognition agent carrying `AiPerception` + `AiAffect`.
pub const OneAgentPipelineFixture = struct {
    world: WorldSystem,
    data: DataSystem,
    frame: SimulationFrame,
    pipeline: SimulationPipeline,

    pub fn init(self: *OneAgentPipelineFixture, structural_headroom: usize) !void {
        const allocator = std.testing.allocator;
        self.world = .{ .allocator = allocator, .width = 1, .height = 1, .tile_size = 32, .chunk_size_tiles = 1 };
        errdefer self.world.deinit();
        _ = try self.world.addLevel(0);
        self.data = DataSystem.init(allocator);
        errdefer self.data.deinit();
        const agent = try self.data.createEntity();
        try self.data.setMovementBody(agent, .{ .position = .{ .x = 0, .y = 0 } });
        try self.data.setAiPerception(agent, .{});
        try self.data.setAiAffect(agent, .{});
        self.frame = SimulationFrame.init(allocator);
        errdefer self.frame.deinit();
        self.pipeline = try SimulationPipeline.init(allocator, &self.data, 64, 64, .{
            .movement_body_capacity = 4,
            .structural_headroom = structural_headroom,
            .pathfinding = .{ .max_group_fields = 1, .worker_participant_count = 1 },
        });
        errdefer self.pipeline.deinit();
        try self.pipeline.reserveFrame(&self.frame);
    }

    pub fn deinit(self: *OneAgentPipelineFixture) void {
        self.pipeline.deinit();
        self.frame.deinit();
        self.data.deinit();
        self.world.deinit();
    }
};
