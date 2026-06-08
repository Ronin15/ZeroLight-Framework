// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const config = @import("../config.zig");
const math = @import("../core/math.zig");
const std = @import("std");
const data_mod = @import("data_system.zig");
const DataSystem = data_mod.DataSystem;
const EntityId = data_mod.EntityId;
const audio_mod = @import("../app/audio.zig");
const AudioCommandBuffer = audio_mod.AudioCommandBuffer;
const LoopingSfxId = audio_mod.LoopingSfxId;
const InputState = @import("../app/input.zig").InputState;
const Player = @import("player.zig").Player;
const CollisionSystem = @import("systems/collision.zig").CollisionSystem;
const CollisionResponseSystem = @import("systems/collision_response.zig").CollisionResponseSystem;
const MovementSystem = @import("systems/movement.zig").MovementSystem;
const ParticleSystem = @import("systems/particle.zig").ParticleSystem;
const SimulationFrame = @import("simulation.zig").SimulationFrame;
const state_mod = @import("../app/state.zig");
const RenderContext = state_mod.RenderContext;
const StateTransitions = state_mod.StateTransitions;
const UpdateContext = state_mod.UpdateContext;
const c = @import("../platform/sdl.zig").c;

const test_square_count = 4;
const obstacle_count = 2;
const collision_sfx_cooldown_capacity = 32;
const collision_sfx_cooldown_seconds: f32 = 0.14;
const demo_music_path = "audio/music/demo_loop.wav";
const collision_sfx_path = "audio/sfx/collision.wav";
const jet_sfx_path = "audio/sfx/player_jet.wav";
const player_jet_loop_id = LoopingSfxId{ .value = 1 };

pub const GameDemoState = struct {
    data: DataSystem,
    simulation_frame: SimulationFrame,
    player: Player,
    movement: MovementSystem,
    collision: CollisionSystem,
    collision_response: CollisionResponseSystem,
    particles: ParticleSystem,
    test_squares: [test_square_count]EntityId,
    obstacles: [obstacle_count]EntityId,
    collision_sfx_cooldowns: [collision_sfx_cooldown_capacity]CollisionSfxCooldown = undefined,
    collision_sfx_cooldown_count: usize = 0,
    music_started: bool = false,
    bounds_width: f32 = 800,
    bounds_height: f32 = 450,

    pub fn init(allocator: std.mem.Allocator, bounds_width: f32, bounds_height: f32) !GameDemoState {
        var data = DataSystem.init(allocator);
        errdefer data.deinit();
        const player = try Player.spawn(&data);
        try data.setCollisionBounds(player.entity, .{ .size = .{ .x = 32, .y = 32 } });
        try data.setCollisionResponse(player.entity, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
        const test_squares = try spawnTestSquares(&data);
        const obstacles = try spawnObstacles(&data);
        var particles = try ParticleSystem.init(allocator, .{ .capacity = 512 });
        errdefer particles.deinit();
        var simulation_frame = SimulationFrame.init(allocator);
        errdefer simulation_frame.deinit();
        try simulation_frame.reserveStreams(8, 16, 16, 32, 16, 8);

        return .{
            .data = data,
            .simulation_frame = simulation_frame,
            .player = player,
            .movement = MovementSystem.init(),
            .collision = CollisionSystem.init(allocator),
            .collision_response = CollisionResponseSystem.init(allocator),
            .particles = particles,
            .test_squares = test_squares,
            .obstacles = obstacles,
            .bounds_width = bounds_width,
            .bounds_height = bounds_height,
        };
    }

    pub fn deinit(self: *GameDemoState) void {
        self.particles.deinit();
        self.collision_response.deinit();
        self.collision.deinit();
        self.simulation_frame.deinit();
        self.data.deinit();
    }

    pub fn handleEvent(self: *GameDemoState, event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
        _ = self;
        _ = event;
        _ = transitions;
        return false;
    }

    pub fn update(self: *GameDemoState, context: UpdateContext) !void {
        _ = context.transitions;
        self.simulation_frame.beginStep();
        self.simulation_frame.phase = .main_thread_inputs;
        try self.player.applyInput(&self.data, context.input);
        self.queueAmbientAudio(context.audio, context.input);

        self.simulation_frame.phase = .processors;
        var movement_slice = self.data.movementBodySlice();
        _ = self.movement.update(&movement_slice, context.thread_system, context.delta_seconds, .{});

        try self.player.clampToBounds(&self.data, self.bounds_width, self.bounds_height);
        _ = try self.collision.update(&self.data, &self.simulation_frame.contacts, context.thread_system, .{});
        _ = try self.collision_response.update(&self.data, &self.simulation_frame);
        self.queueCollisionAudio(context.audio, context.delta_seconds);
        self.emitPlayerTrail();
        _ = self.particles.update(context.thread_system, context.delta_seconds, .{});

        self.simulation_frame.phase = .merge_outputs;
        _ = try self.simulation_frame.applyStructuralCommands(&self.data);
        self.simulation_frame.phase = .finished;
    }

    pub fn render(self: *GameDemoState, context: RenderContext) !void {
        _ = context.thread_system;
        for (self.obstacles) |entity| {
            try renderPrimitiveEntity(&self.data, entity, context.renderer, context.interpolation_alpha);
        }
        for (self.test_squares) |entity| {
            try renderPrimitiveEntity(&self.data, entity, context.renderer, context.interpolation_alpha);
        }
        try self.particles.render(context.renderer, context.interpolation_alpha);
        try self.player.render(&self.data, context.renderer, context.interpolation_alpha);
        try context.renderer.drawRect(.{
            .x = 0,
            .y = self.bounds_height - 4,
            .w = self.bounds_width,
            .h = 4,
        }, config.Color{ .r = 0.16, .g = 0.24, .b = 0.29, .a = 1.0 }, -1);
    }

    pub fn onPause(self: *GameDemoState) void {
        self.syncInterpolatedState();
    }

    pub fn onResume(self: *GameDemoState) void {
        self.syncInterpolatedState();
    }

    fn syncInterpolatedState(self: *GameDemoState) void {
        var movement_slice = self.data.movementBodySlice();
        self.movement.syncPreviousPositions(&movement_slice);
        self.particles.syncPreviousPositions();
    }

    fn emitPlayerTrail(self: *GameDemoState) void {
        const body = self.data.movementBodyConst(self.player.entity) orelse return;
        const position = body.position;
        _ = self.particles.emitBurst(.{
            .count = 2,
            .position = .{ .x = position.x + 16, .y = position.y + 16 },
            .base_velocity = .{ .x = -24, .y = -36 },
            .velocity_step = .{ .x = 48, .y = -4 },
            .acceleration = .{ .x = 0, .y = 80 },
            .lifetime = 0.55,
            .lifetime_step = 0.04,
            .start_size = 7,
            .end_size = 1,
            .start_color = .{ .r = 1.0, .g = 0.78, .b = 0.28, .a = 0.85 },
            .end_color = .{ .r = 0.95, .g = 0.24, .b = 0.18, .a = 0.0 },
            .layer = 0,
        });
    }

    fn queueAmbientAudio(self: *GameDemoState, audio: *AudioCommandBuffer, input: *const InputState) void {
        if (!self.music_started) {
            audio.playMusic(.{
                .path = demo_music_path,
                .gain = 1.0,
                .loop = true,
                .fade_in_ms = 750,
            }) catch return;
            self.music_started = true;
        }

        if (self.data.movementBodyConst(self.player.entity)) |body| {
            audio.setListener(.{ .x = body.position.x + 16, .y = body.position.y + 16 }) catch {};
            if (input.movementVector().x != 0 or input.movementVector().y != 0) {
                audio.startLoopingSfx(player_jet_loop_id, .{
                    .path = jet_sfx_path,
                    .gain = 0.34,
                    .priority = 220,
                    .frequency_ratio = 1.0,
                    .position = .{ .x = body.position.x + 16, .y = body.position.y + 16 },
                }) catch {};
            } else {
                audio.stopLoopingSfx(player_jet_loop_id) catch {};
            }
        }
    }

    fn queueCollisionAudio(self: *GameDemoState, audio: *AudioCommandBuffer, delta_seconds: f32) void {
        self.tickCollisionSfxCooldowns(delta_seconds);
        for (self.simulation_frame.contacts.mergedItems()) |contact| {
            if (self.collisionPairOnCooldown(contact.a, contact.b)) continue;
            const position = self.contactAudioPosition(contact) orelse continue;
            const gain = std.math.clamp(contact.penetration / 18.0, 0.25, 1.0);
            const frequency_ratio = collisionSfxFrequencyRatio(contact);
            audio.playSfx(.{
                .path = collision_sfx_path,
                .gain = gain,
                .priority = 180,
                .frequency_ratio = frequency_ratio,
                .position = position,
            }) catch |err| switch (err) {
                error.AudioCommandLimitReached => break,
                else => continue,
            };
            self.addCollisionSfxCooldown(contact.a, contact.b);
        }
    }

    fn contactAudioPosition(self: *const GameDemoState, contact: @import("simulation.zig").CollisionContact) ?math.Vec2 {
        const a = self.data.movementBodyConst(contact.a) orelse return null;
        const b = self.data.movementBodyConst(contact.b) orelse return null;
        return .{
            .x = (a.position.x + b.position.x) * 0.5,
            .y = (a.position.y + b.position.y) * 0.5,
        };
    }

    fn tickCollisionSfxCooldowns(self: *GameDemoState, delta_seconds: f32) void {
        var index: usize = 0;
        while (index < self.collision_sfx_cooldown_count) {
            self.collision_sfx_cooldowns[index].remaining_seconds -= delta_seconds;
            if (self.collision_sfx_cooldowns[index].remaining_seconds <= 0) {
                self.collision_sfx_cooldown_count -= 1;
                self.collision_sfx_cooldowns[index] = self.collision_sfx_cooldowns[self.collision_sfx_cooldown_count];
            } else {
                index += 1;
            }
        }
    }

    fn collisionPairOnCooldown(self: *const GameDemoState, a: EntityId, b: EntityId) bool {
        const key = CollisionSfxCooldown.keyFor(a, b);
        for (self.collision_sfx_cooldowns[0..self.collision_sfx_cooldown_count]) |cooldown| {
            if (cooldown.key == key) return true;
        }
        return false;
    }

    fn addCollisionSfxCooldown(self: *GameDemoState, a: EntityId, b: EntityId) void {
        const key = CollisionSfxCooldown.keyFor(a, b);
        if (self.collision_sfx_cooldown_count < self.collision_sfx_cooldowns.len) {
            self.collision_sfx_cooldowns[self.collision_sfx_cooldown_count] = .{
                .key = key,
                .remaining_seconds = collision_sfx_cooldown_seconds,
            };
            self.collision_sfx_cooldown_count += 1;
            return;
        }

        self.collision_sfx_cooldowns[0] = .{
            .key = key,
            .remaining_seconds = collision_sfx_cooldown_seconds,
        };
    }

    fn collisionSfxFrequencyRatio(contact: @import("simulation.zig").CollisionContact) f32 {
        var hash = CollisionSfxCooldown.keyFor(contact.a, contact.b);
        hash ^= @as(u64, @intFromFloat(@abs(contact.normal_x) * 31.0));
        hash ^= @as(u64, @intFromFloat(@abs(contact.normal_y) * 47.0)) << 8;
        hash ^= @as(u64, @intFromFloat(std.math.clamp(contact.penetration, 0, 64) * 16.0)) << 16;
        const bucket: f32 = @floatFromInt(hash % 9);
        return 0.92 + bucket * 0.02;
    }
};

const CollisionSfxCooldown = struct {
    key: u64,
    remaining_seconds: f32,

    fn keyFor(a: EntityId, b: EntityId) u64 {
        const a_id = entityAudioKey(a);
        const b_id = entityAudioKey(b);
        const low = @min(a_id, b_id);
        const high = @max(a_id, b_id);
        return low ^ std.math.rotl(u64, high, 32);
    }

    fn entityAudioKey(entity: EntityId) u64 {
        return (@as(u64, entity.generation) << 32) | entity.index;
    }
};

fn spawnTestSquares(data: *DataSystem) ![test_square_count]EntityId {
    const specs = [_]TestSquareSpec{
        .{
            .position = .{ .x = 120, .y = 120 },
            .velocity = .{ .x = 18, .y = 0 },
            .size = .{ .x = 24, .y = 24 },
            .color = .{ .r = 0.34, .g = 0.69, .b = 1.0, .a = 1.0 },
            .layer = 0,
        },
        .{
            .position = .{ .x = 220, .y = 160 },
            .velocity = .{ .x = 0, .y = 14 },
            .size = .{ .x = 28, .y = 28 },
            .color = .{ .r = 0.46, .g = 0.86, .b = 0.38, .a = 1.0 },
            .layer = 0,
        },
        .{
            .position = .{ .x = 320, .y = 220 },
            .velocity = .{ .x = -16, .y = 10 },
            .size = .{ .x = 20, .y = 20 },
            .color = .{ .r = 0.95, .g = 0.42, .b = 0.59, .a = 1.0 },
            .layer = 0,
        },
        .{
            .position = .{ .x = 470, .y = 130 },
            .velocity = .{ .x = 12, .y = -8 },
            .size = .{ .x = 26, .y = 26 },
            .color = .{ .r = 0.7, .g = 0.54, .b = 1.0, .a = 1.0 },
            .layer = 0,
        },
    };
    var entities: [test_square_count]EntityId = undefined;
    for (specs, 0..) |spec, index| {
        const entity = try data.createEntity();
        errdefer _ = data.destroyEntity(entity);
        try data.setMovementBody(entity, .{
            .position = spec.position,
            .previous_position = spec.position,
            .velocity = spec.velocity,
            .speed = 0,
        });
        try data.setPrimitiveVisual(entity, .{
            .size = spec.size,
            .color = spec.color,
            .layer = spec.layer,
            .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .marker_layer = spec.layer,
            .marker_length = 0,
            .marker_depth = 0,
            .marker_margin = 0,
        });
        try data.setCollisionBounds(entity, .{ .size = spec.size });
        try data.setCollisionResponse(entity, .{ .mode = .bounce, .mobility = .dynamic, .restitution = 1 });
        entities[index] = entity;
    }
    return entities;
}

fn spawnObstacles(data: *DataSystem) ![obstacle_count]EntityId {
    const specs = [_]ObstacleSpec{
        .{
            .position = .{ .x = 462, .y = 215 },
            .size = .{ .x = 72, .y = 48 },
            .color = .{ .r = 0.2, .g = 0.28, .b = 0.34, .a = 1.0 },
        },
        .{
            .position = .{ .x = 245, .y = 285 },
            .size = .{ .x = 96, .y = 28 },
            .color = .{ .r = 0.26, .g = 0.34, .b = 0.36, .a = 1.0 },
        },
    };
    var entities: [obstacle_count]EntityId = undefined;
    for (specs, 0..) |spec, index| {
        const entity = try data.createEntity();
        errdefer _ = data.destroyEntity(entity);
        try data.setMovementBody(entity, .{
            .position = spec.position,
            .previous_position = spec.position,
            .velocity = .{},
            .speed = 0,
        });
        try data.setPrimitiveVisual(entity, .{
            .size = spec.size,
            .color = spec.color,
            .layer = -1,
            .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .marker_layer = -1,
            .marker_length = 0,
            .marker_depth = 0,
            .marker_margin = 0,
        });
        try data.setCollisionBounds(entity, .{ .size = spec.size });
        try data.setCollisionResponse(entity, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
        entities[index] = entity;
    }
    return entities;
}

fn renderPrimitiveEntity(
    data: *const DataSystem,
    entity: EntityId,
    renderer: *@import("../render/renderer.zig").Renderer,
    interpolation_alpha: f32,
) !void {
    const body = data.movementBodyConst(entity) orelse return;
    const visual = data.primitiveVisualConst(entity) orelse return;
    const render_position = math.lerpVec2(body.previous_position, body.position, interpolation_alpha);
    try renderer.drawRect(.{
        .x = render_position.x,
        .y = render_position.y,
        .w = visual.size.x,
        .h = visual.size.y,
    }, visual.color, visual.layer);
}

const TestSquareSpec = struct {
    position: math.Vec2,
    velocity: math.Vec2,
    size: math.Vec2,
    color: config.Color,
    layer: i32,
};

const ObstacleSpec = struct {
    position: math.Vec2,
    size: math.Vec2,
    color: config.Color,
};

test "demo spawns colored moving test squares" {
    var demo = try GameDemoState.init(std.testing.allocator, 800, 450);
    defer demo.deinit();

    try std.testing.expectEqual(@as(usize, test_square_count + obstacle_count + 1), demo.data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, test_square_count + obstacle_count + 1), demo.data.collisionBoundsSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, test_square_count + obstacle_count + 1), demo.data.collisionResponseSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 0), demo.particles.activeCount());
    for (demo.test_squares) |entity| {
        try std.testing.expect(demo.data.hasComponents(entity, data_mod.component_masks.movement_body | data_mod.component_masks.primitive_visual | data_mod.component_masks.collision_bounds | data_mod.component_masks.collision_response));
        const body = demo.data.movementBodyConst(entity).?;
        try std.testing.expect(body.velocity.x != 0 or body.velocity.y != 0);
        const visual = demo.data.primitiveVisualConst(entity).?;
        try std.testing.expect(visual.color.a > 0);
        try std.testing.expectEqual(data_mod.CollisionResponseMode.bounce, demo.data.collisionResponseConst(entity).?.mode);
    }
    for (demo.obstacles) |entity| {
        try std.testing.expect(demo.data.hasComponents(entity, data_mod.component_masks.movement_body | data_mod.component_masks.primitive_visual | data_mod.component_masks.collision_bounds | data_mod.component_masks.collision_response));
        const body = demo.data.movementBodyConst(entity).?;
        try std.testing.expectEqual(@as(f32, 0), body.velocity.x);
        try std.testing.expectEqual(@as(f32, 0), body.velocity.y);
        try std.testing.expectEqual(data_mod.CollisionResponseMobility.static, demo.data.collisionResponseConst(entity).?.mobility);
    }
}

test "demo owns and completes a simulation frame during update" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var demo = try GameDemoState.init(std.testing.allocator, 800, 450);
    defer demo.deinit();
    var threads = try @import("../app/thread_system.zig").ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 0,
        .min_parallel_items = 1,
        .items_per_range = data_mod.movement_range_alignment_items,
    });
    defer threads.deinit();
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var audio = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer audio.deinit();
    var input = InputState{};
    input.setHeld(.moveRight, true);
    const player_before = demo.data.movementBodyConst(demo.player.entity).?;
    var square_before: [test_square_count]math.Vec2 = undefined;
    for (demo.test_squares, 0..) |entity, index| {
        square_before[index] = demo.data.movementBodyConst(entity).?.position;
    }

    try demo.update(.{
        .input = &input,
        .audio = &audio,
        .delta_seconds = 0.016,
        .transitions = &transitions,
        .thread_system = &threads,
    });

    try std.testing.expectEqual(@import("simulation.zig").SimulationPhase.finished, demo.simulation_frame.phase);
    try std.testing.expectEqual(@as(usize, 0), demo.simulation_frame.structural_commands.mergedItems().len);
    const player_after = demo.data.movementBodyConst(demo.player.entity).?;
    try std.testing.expect(player_after.position.x > player_before.position.x);
    try std.testing.expectEqual(@as(f32, 240), player_after.velocity.x);
    for (demo.test_squares, 0..) |entity, index| {
        const body = demo.data.movementBodyConst(entity).?;
        try std.testing.expect(body.position.x != square_before[index].x or body.position.y != square_before[index].y);
    }
    try std.testing.expect(demo.particles.activeCount() > 0);
    try std.testing.expect(demo.music_started);
    try std.testing.expect(audio.len() >= 2);
}

test "demo collision response blocks player against obstacles" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var demo = try GameDemoState.init(std.testing.allocator, 800, 450);
    defer demo.deinit();
    var threads = try @import("../app/thread_system.zig").ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 0,
        .min_parallel_items = 1,
        .items_per_range = data_mod.movement_range_alignment_items,
    });
    defer threads.deinit();
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var audio = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer audio.deinit();

    const obstacle = demo.obstacles[0];
    const obstacle_body = demo.data.movementBodyConst(obstacle).?;
    const player_body = demo.data.movementBodyPtr(demo.player.entity).?;
    player_body.position_x.* = obstacle_body.position.x - 30;
    player_body.position_y.* = obstacle_body.position.y + 8;
    player_body.previous_x.* = player_body.position_x.*;
    player_body.previous_y.* = player_body.position_y.*;
    var input = InputState{};
    input.setHeld(.moveRight, true);

    try demo.update(.{
        .input = &input,
        .audio = &audio,
        .delta_seconds = 0.016,
        .transitions = &transitions,
        .thread_system = &threads,
    });

    const player_after = demo.data.movementBodyConst(demo.player.entity).?;
    try std.testing.expect(demo.simulation_frame.contacts.mergedItems().len > 0);
    try std.testing.expect(player_after.position.x <= obstacle_body.position.x - 32);
    try std.testing.expect(audio.len() > 2);
}

test "demo collision response handles player contacts with moving entities" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var demo = try GameDemoState.init(std.testing.allocator, 800, 450);
    defer demo.deinit();
    var threads = try @import("../app/thread_system.zig").ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 0,
        .min_parallel_items = 1,
        .items_per_range = data_mod.movement_range_alignment_items,
    });
    defer threads.deinit();
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var audio = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer audio.deinit();

    const square = demo.test_squares[0];
    for (demo.test_squares[1..], 0..) |other, index| {
        const body = demo.data.movementBodyPtr(other).?;
        body.position_x.* = 620 + @as(f32, @floatFromInt(index)) * 40;
        body.position_y.* = 40;
        body.previous_x.* = body.position_x.*;
        body.previous_y.* = body.position_y.*;
    }
    for (demo.obstacles, 0..) |obstacle, index| {
        const body = demo.data.movementBodyPtr(obstacle).?;
        body.position_x.* = 620 + @as(f32, @floatFromInt(index)) * 80;
        body.position_y.* = 330;
        body.previous_x.* = body.position_x.*;
        body.previous_y.* = body.position_y.*;
    }
    const player_body = demo.data.movementBodyPtr(demo.player.entity).?;
    const square_body = demo.data.movementBodyPtr(square).?;
    player_body.position_x.* = 200;
    player_body.position_y.* = 160;
    player_body.previous_x.* = player_body.position_x.*;
    player_body.previous_y.* = player_body.position_y.*;
    player_body.velocity_x.* = 0;
    player_body.velocity_y.* = 0;
    square_body.position_x.* = player_body.position_x.* + 30;
    square_body.position_y.* = player_body.position_y.*;
    square_body.previous_x.* = square_body.position_x.*;
    square_body.previous_y.* = square_body.position_y.*;
    square_body.velocity_x.* = -40;
    square_body.velocity_y.* = 0;

    try demo.update(.{
        .input = &InputState{},
        .audio = &audio,
        .delta_seconds = 0.016,
        .transitions = &transitions,
        .thread_system = &threads,
    });

    const square_after = demo.data.movementBodyConst(square).?;
    try std.testing.expect(demo.simulation_frame.contacts.mergedItems().len > 0);
    try std.testing.expect(square_after.position.x > player_body.position_x.* + 30);
    try std.testing.expect(square_after.velocity.x > 0);
}
