// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const config = @import("../config.zig");
const math = @import("../core/math.zig");
const builtin = @import("builtin");
const std = @import("std");
const AudioCommandBuffer = @import("../app/audio.zig").AudioCommandBuffer;
const LoopingSfxId = @import("../app/audio.zig").LoopingSfxId;
const AudioAssetId = @import("../assets/manifest.zig").AudioAssetId;
const SpriteAssetId = @import("../assets/manifest.zig").SpriteAssetId;
const component_masks = @import("data_system.zig").component_masks;
const CollisionResponseMobility = @import("data_system.zig").CollisionResponseMobility;
const CollisionResponseMode = @import("data_system.zig").CollisionResponseMode;
const DataSystem = @import("data_system.zig").DataSystem;
const EntityId = @import("data_system.zig").EntityId;
const movement_range_alignment_items = @import("data_system.zig").movement_range_alignment_items;
const StructuralCommand = @import("data_system.zig").StructuralCommand;
const InputState = @import("../app/input.zig").InputState;
const Player = @import("player.zig").Player;
const CollisionSystem = @import("systems/collision.zig").CollisionSystem;
const CollisionResponseSystem = @import("systems/collision_response.zig").CollisionResponseSystem;
const MovementSystem = @import("systems/movement.zig").MovementSystem;
const ParticleSystem = @import("systems/particle.zig").ParticleSystem;
const AiSystem = @import("systems/ai.zig").AiSystem;
const default_max_fallback_requests_per_step = @import("systems/pathfinding.zig").default_max_fallback_requests_per_step;
const PathfindingCapacity = @import("systems/pathfinding.zig").PathfindingCapacity;
const PathfindingSystem = @import("systems/pathfinding.zig").PathfindingSystem;
const SteeringSystem = @import("systems/steering.zig").SteeringSystem;
const CollisionContact = @import("simulation.zig").CollisionContact;
const SimulationFrame = @import("simulation.zig").SimulationFrame;
const SimulationPhase = @import("simulation.zig").SimulationPhase;
const RenderContext = @import("../app/state.zig").RenderContext;
const StateTransitions = @import("../app/state.zig").StateTransitions;
const UpdateContext = @import("../app/state.zig").UpdateContext;
const RenderOrder = @import("../render/renderer.zig").RenderOrder;
const RenderQueue = @import("../render/render_queue.zig").RenderQueue;
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const render_prep = @import("render_prep.zig");
const render_depth = @import("render_depth.zig");
const WorldDepth = render_depth.WorldDepth;
const c = @import("../platform/sdl.zig").c;

const test_square_count = 8;
const obstacle_count = 2;
const collision_sfx_cooldown_capacity = 32;
const collision_sfx_cooldown_seconds: f32 = 0.14;
const demo_contact_capacity = 64;
const demo_music = AudioAssetId.demo_music;
const collision_sfx = AudioAssetId.collision_sfx;
const jet_sfx = AudioAssetId.player_jet_sfx;
const player_jet_loop_id = LoopingSfxId{ .value = 1 };

pub const GameDemoState = struct {
    data: DataSystem,
    simulation_frame: SimulationFrame,
    player: Player,
    movement: MovementSystem,
    collision: CollisionSystem,
    collision_response: CollisionResponseSystem,
    particles: ParticleSystem,
    render_queue: RenderQueue,
    ai: AiSystem,
    steering: SteeringSystem,
    pathfinding: PathfindingSystem,
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
        var render_queue = RenderQueue.init(allocator);
        errdefer render_queue.deinit();
        try render_queue.ensureTotalCapacity(1 + obstacle_count + test_square_count + 2 + particles.capacity);
        var ai = AiSystem.init(allocator);
        errdefer ai.deinit();
        var steering = SteeringSystem.init(allocator);
        errdefer steering.deinit();
        try steering.reserveForCapacity(test_square_count, obstacle_count);
        var pathfinding = PathfindingSystem.init(allocator);
        errdefer pathfinding.deinit();
        var simulation_frame = SimulationFrame.init(allocator);
        errdefer simulation_frame.deinit();
        try simulation_frame.reserveStreams(8, 16, 16, demo_contact_capacity, 16, 8);
        try simulation_frame.reservePathRequests(8, test_square_count);
        try pathfinding.reserve(PathfindingCapacity{
            .max_frame_requests = test_square_count,
            .max_pending_requests = test_square_count,
            .max_cached_results = test_square_count * 4,
            .max_goal_fields = 4,
            .max_worker_scratch_slots = 64,
            .max_solved_requests_per_step = test_square_count,
            .max_fallback_requests_per_step = default_max_fallback_requests_per_step,
        });
        try pathfinding.rebuildStaticNavGrid(&data, bounds_width, bounds_height, 32.0);
        var collision_response = CollisionResponseSystem.init(allocator);
        errdefer collision_response.deinit();
        try collision_response.reserveForContacts(demo_contact_capacity);

        return .{
            .data = data,
            .simulation_frame = simulation_frame,
            .player = player,
            .movement = MovementSystem.init(),
            .collision = CollisionSystem.init(allocator),
            .collision_response = collision_response,
            .particles = particles,
            .render_queue = render_queue,
            .ai = ai,
            .steering = steering,
            .pathfinding = pathfinding,
            .test_squares = test_squares,
            .obstacles = obstacles,
            .bounds_width = bounds_width,
            .bounds_height = bounds_height,
        };
    }

    pub fn deinit(self: *GameDemoState) void {
        self.pathfinding.deinit();
        self.steering.deinit();
        self.ai.deinit();
        self.render_queue.deinit();
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
        // AI emits high-level navigation intents. Steering consumes those intents,
        // path status, and dense steering data before it writes final NPC MovementIntents.
        const ai_slice = self.data.aiAgentSliceConst();
        const move_slice = self.data.movementBodySliceConst();

        // Provide the player's position so "seek" behaviors head toward the player
        // (instead of the global center-of-mass of all bodies, which caused seekers
        // to clump on each other and spam collisions/bounce audio).
        const player_target = if (self.data.movementBodyConst(self.player.entity)) |pbody|
            pbody.previous_position
        else
            math.Vec2{ .x = 400, .y = 225 };

        _ = try self.ai.update(ai_slice, move_slice, &self.data, &self.simulation_frame, context.thread_system, context.delta_seconds, .{
            .intent_seed = 0xfeedf00d,
            .seek_target = player_target,
            .navigation_intents = &self.simulation_frame.navigation_intents,
        });

        _ = try self.steering.update(&self.data, &self.simulation_frame, context.thread_system, &self.pathfinding, .{});
        _ = try self.pathfinding.update(&self.simulation_frame.path_requests, context.thread_system, .{});

        // Intent application step (main thread): consume merged MovementIntents from AI (and future), write velocities
        // for ai_agent entities only via direct MovementBodyPtr (hot column mutation). Stale IDs rejected. Player
        // remains 100% special-cased (applyInput + no ai_agent component). Collision/response/particle paths unchanged.
        for (self.simulation_frame.intents.mergedItems()) |item| {
            if (item != .movement) continue;
            const mi = item.movement;
            if (!self.data.isAlive(mi.entity)) continue;
            if (self.data.aiAgentConst(mi.entity) == null) continue;
            if (self.data.movementBodyPtr(mi.entity)) |body| {
                const spd = if (body.speed.* > 0) body.speed.* else 40.0;
                body.velocity_x.* = mi.direction_x * spd;
                body.velocity_y.* = mi.direction_y * spd;
            }
        }

        var movement_slice = self.data.movementBodySlice();
        _ = self.movement.update(&movement_slice, context.thread_system, context.delta_seconds, .{});

        self.clampAiSquaresToBounds(self.bounds_width, self.bounds_height);
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
        self.render_queue.clearRetainingCapacity();
        try self.render_queue.addRect(.{
            .x = 0,
            .y = self.bounds_height - 4,
            .w = self.bounds_width,
            .h = 4,
        }, config.Color{ .r = 0.16, .g = 0.24, .b = 0.29, .a = 1.0 }, RenderOrder.world(render_depth.worldZ(.floor)), .world);
        for (self.obstacles) |entity| {
            try render_prep.enqueueEntity(&self.render_queue, &self.data, entity, context.runtime_assets, context.interpolation_alpha);
        }
        for (self.test_squares) |entity| {
            try render_prep.enqueueEntity(&self.render_queue, &self.data, entity, context.runtime_assets, context.interpolation_alpha);
        }
        try self.player.enqueueRender(&self.data, context.runtime_assets, &self.render_queue, context.interpolation_alpha);
        try self.particles.enqueueRender(&self.render_queue, context.interpolation_alpha);
        try self.render_queue.submit(context.renderer);
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

    fn clampAiSquaresToBounds(self: *GameDemoState, bounds_width: f32, bounds_height: f32) void {
        const ai_slice = self.data.aiAgentSliceConst();
        for (ai_slice.entities) |entity| {
            const body = self.data.movementBodyPtr(entity) orelse continue;
            const visual = self.data.primitiveVisualConst(entity) orelse continue;

            // Use math.clamp (same as Player.clampToBounds) for positions. Zero velocity on
            // clamp for AI (main-thread only) so infrequent decisions do not cause wall-push
            // until next ai update; player does not zero because input re-applies each step.
            // Preserves prior AI demo behavior and collision response expectations.
            const max_x = bounds_width - visual.size.x;
            const new_x = math.clamp(body.position_x.*, 0, max_x);
            if (new_x != body.position_x.*) body.velocity_x.* = 0;
            body.position_x.* = new_x;

            const max_y = bounds_height - visual.size.y;
            const new_y = math.clamp(body.position_y.*, 0, max_y);
            if (new_y != body.position_y.*) body.velocity_y.* = 0;
            body.position_y.* = new_y;
        }
    }

    fn emitPlayerTrail(self: *GameDemoState) void {
        const body = self.data.movementBodyConst(self.player.entity) orelse return;
        const position = body.position;
        _ = self.particles.emitBurst(.{
            .count = 2,
            .position = .{ .x = position.x + 16, .y = position.y + 16 },
            .base_z = body.position_z,
            .base_velocity = .{ .x = -24, .y = -36 },
            .velocity_step = .{ .x = 48, .y = -4 },
            .acceleration = .{ .x = 0, .y = 80 },
            .lifetime = 0.55,
            .lifetime_step = 0.04,
            .start_size = 7,
            .end_size = 1,
            .start_color = .{ .r = 1.0, .g = 0.78, .b = 0.28, .a = 0.85 },
            .end_color = .{ .r = 0.95, .g = 0.24, .b = 0.18, .a = 0.0 },
            .depth = .effect,
        });
    }

    fn queueAmbientAudio(self: *GameDemoState, audio: *AudioCommandBuffer, input: *const InputState) void {
        if (!self.music_started) {
            audio.playMusic(.{
                .asset = demo_music,
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
                    .asset = jet_sfx,
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
                .asset = collision_sfx,
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

    fn contactAudioPosition(self: *const GameDemoState, contact: CollisionContact) ?math.Vec2 {
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

        // Full: evict the slot with the least remaining time (gives newest collision
        // the longest protection). Linear scan is acceptable (N<=32, cold path).
        var min_idx: usize = 0;
        var min_rem = self.collision_sfx_cooldowns[0].remaining_seconds;
        for (1..self.collision_sfx_cooldown_count) |i| {
            if (self.collision_sfx_cooldowns[i].remaining_seconds < min_rem) {
                min_rem = self.collision_sfx_cooldowns[i].remaining_seconds;
                min_idx = i;
            }
        }
        self.collision_sfx_cooldowns[min_idx] = .{
            .key = key,
            .remaining_seconds = collision_sfx_cooldown_seconds,
        };
    }

    fn collisionSfxFrequencyRatio(contact: CollisionContact) f32 {
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
        .{ .position = .{ .x = 80, .y = 80 }, .velocity = .{ .x = 20, .y = 5 }, .size = .{ .x = 22, .y = 22 }, .color = .{ .r = 0.34, .g = 0.69, .b = 1.0, .a = 1.0 }, .depth = .actor },
        .{ .position = .{ .x = 180, .y = 140 }, .velocity = .{ .x = 5, .y = 18 }, .size = .{ .x = 26, .y = 26 }, .color = .{ .r = 0.46, .g = 0.86, .b = 0.38, .a = 1.0 }, .depth = .actor },
        .{ .position = .{ .x = 280, .y = 260 }, .velocity = .{ .x = -14, .y = 9 }, .size = .{ .x = 18, .y = 18 }, .color = .{ .r = 0.95, .g = 0.42, .b = 0.59, .a = 1.0 }, .depth = .actor },
        .{ .position = .{ .x = 420, .y = 90 }, .velocity = .{ .x = 11, .y = -10 }, .size = .{ .x = 24, .y = 24 }, .color = .{ .r = 0.7, .g = 0.54, .b = 1.0, .a = 1.0 }, .depth = .actor },
        .{ .position = .{ .x = 120, .y = 320 }, .velocity = .{ .x = 8, .y = -16 }, .size = .{ .x = 20, .y = 20 }, .color = .{ .r = 0.95, .g = 0.65, .b = 0.25, .a = 1.0 }, .depth = .actor },
        .{ .position = .{ .x = 550, .y = 200 }, .velocity = .{ .x = -9, .y = 12 }, .size = .{ .x = 30, .y = 18 }, .color = .{ .r = 0.55, .g = 0.82, .b = 0.92, .a = 1.0 }, .depth = .actor },
        .{ .position = .{ .x = 650, .y = 340 }, .velocity = .{ .x = 15, .y = -7 }, .size = .{ .x = 19, .y = 19 }, .color = .{ .r = 0.85, .g = 0.45, .b = 0.78, .a = 1.0 }, .depth = .actor },
        .{ .position = .{ .x = 300, .y = 70 }, .velocity = .{ .x = -6, .y = 22 }, .size = .{ .x = 25, .y = 25 }, .color = .{ .r = 0.4, .g = 0.95, .b = 0.75, .a = 1.0 }, .depth = .actor },
    };
    var entities: [test_square_count]EntityId = undefined;
    for (specs, 0..) |spec, index| {
        const entity = if (index == 3 or index == 7) blk: {
            // Use EntityTemplate (via create_entity structural command) for a couple of ai-driven spawns
            // to exercise the Slice 14 structural path.
            _ = try data.applyStructuralCommands(&[_]StructuralCommand{.{
                .create_entity = .{
                    .movement_body = .{
                        .position = spec.position,
                        .previous_position = spec.position,
                        .velocity = spec.velocity,
                        .speed = if (index == 3) 48 else 55,
                    },
                    .primitive_visual = .{
                        .size = spec.size,
                        .color = spec.color,
                        .depth = spec.depth,
                        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                        .marker_depth_band = .marker,
                        .marker_length = 0,
                        .marker_depth = 0,
                        .marker_margin = 0,
                    },
                    .asset_reference = .{ .sprite = .demo_tile },
                    .collision_bounds = .{ .size = spec.size },
                    .collision_response = .{ .mode = .bounce, .mobility = .dynamic, .restitution = 1 },
                    .ai_agent = if (index == 3)
                        .{ .behavior = .seek, .wander_amplitude = 6, .seek_weight = 1.35 }
                    else
                        .{ .behavior = .seek, .wander_amplitude = 4, .seek_weight = 1.6 },
                    .steering_agent = demoSteeringAgent(spec.size),
                },
            }});
            const post = data.movementBodySliceConst();
            break :blk post.entities[post.entities.len - 1];
        } else blk: {
            const e = try data.createEntity();
            errdefer _ = data.destroyEntity(e);
            try data.setMovementBody(e, .{
                .position = spec.position,
                .previous_position = spec.position,
                .velocity = spec.velocity,
                .speed = if (index == 0 or index == 4) 0 else 42,
            });
            try data.setPrimitiveVisual(e, .{
                .size = spec.size,
                .color = spec.color,
                .depth = spec.depth,
                .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .marker_depth_band = .marker,
                .marker_length = 0,
                .marker_depth = 0,
                .marker_margin = 0,
            });
            try data.setAssetReference(e, .{ .sprite = .demo_tile });
            try data.setCollisionBounds(e, .{ .size = spec.size });
            try data.setCollisionResponse(e, .{ .mode = .bounce, .mobility = .dynamic, .restitution = 1 });
            break :blk e;
        };

        // Pronounced behaviors for the new larger set of squares.
        // Seekers have high seek_weight so the COM pull is obvious.
        // Wanderers have high amplitude so their motion is chaotic and visible.
        // A couple use EntityTemplate above; the rest use direct sets.
        if (index == 0 or index == 4) {
            // Strong pure wanderers
            try data.setAiAgent(entity, .{ .behavior = .wander, .wander_amplitude = 58, .seek_weight = 0 });
            try data.setSteeringAgent(entity, demoSteeringAgent(spec.size));
        } else if (index == 1 or index == 5) {
            // Strong seekers (COM pull dominates, light wander)
            try data.setAiAgent(entity, .{ .behavior = .seek, .wander_amplitude = 7, .seek_weight = 1.55 });
            try data.setSteeringAgent(entity, demoSteeringAgent(spec.size));
        } else if (index == 2 or index == 6) {
            // No ai_agent — these keep classic spawn velocity and bounce normally
        } else if (index == 3 or index == 7) {
            // Already set via the template above (strong seek variants)
        }
        entities[index] = entity;
    }
    return entities;
}

fn demoSteeringAgent(size: math.Vec2) @import("data_system.zig").SteeringAgent {
    return .{
        .agent_radius = @max(size.x, size.y) * 0.5,
        .waypoint_tolerance = 10,
        .avoidance_radius = 54,
        .avoidance_weight = 1.15,
        .max_neighbor_samples = 8,
        .stuck_step_threshold = 24,
        .replan_cooldown_steps = 10,
        .unavailable_backoff_steps = 45,
    };
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
            .depth = .obstacle,
            .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .marker_depth_band = .obstacle,
            .marker_length = 0,
            .marker_depth = 0,
            .marker_margin = 0,
        });
        try data.setAssetReference(entity, .{ .sprite = .demo_tile });
        try data.setCollisionBounds(entity, .{ .size = spec.size });
        try data.setCollisionResponse(entity, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
        entities[index] = entity;
    }
    return entities;
}

const TestSquareSpec = struct {
    position: math.Vec2,
    velocity: math.Vec2,
    size: math.Vec2,
    color: config.Color,
    depth: WorldDepth,
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
    try std.testing.expectEqual(@as(usize, test_square_count + obstacle_count + 1), demo.data.assetReferenceSliceConst().entities.len);
    try std.testing.expectEqual(SpriteAssetId.demo_tile, demo.data.assetReferenceConst(demo.player.entity).?.sprite);
    try std.testing.expectEqual(@as(usize, 0), demo.particles.activeCount());
    for (demo.test_squares) |entity| {
        try std.testing.expect(demo.data.hasComponents(entity, component_masks.movement_body | component_masks.primitive_visual | component_masks.asset_reference | component_masks.collision_bounds | component_masks.collision_response));
        try std.testing.expectEqual(SpriteAssetId.demo_tile, demo.data.assetReferenceConst(entity).?.sprite);
        const body = demo.data.movementBodyConst(entity).?;
        const has_ai = demo.data.hasComponents(entity, component_masks.ai_agent);
        try std.testing.expect(has_ai or body.velocity.x != 0 or body.velocity.y != 0);
        if (has_ai) {
            try std.testing.expect(demo.data.aiAgentConst(entity) != null);
        }
        const visual = demo.data.primitiveVisualConst(entity).?;
        try std.testing.expect(visual.color.a > 0);
        try std.testing.expectEqual(CollisionResponseMode.bounce, demo.data.collisionResponseConst(entity).?.mode);
    }
    for (demo.obstacles) |entity| {
        try std.testing.expect(demo.data.hasComponents(entity, component_masks.movement_body | component_masks.primitive_visual | component_masks.asset_reference | component_masks.collision_bounds | component_masks.collision_response));
        try std.testing.expectEqual(SpriteAssetId.demo_tile, demo.data.assetReferenceConst(entity).?.sprite);
        const body = demo.data.movementBodyConst(entity).?;
        try std.testing.expectEqual(@as(f32, 0), body.velocity.x);
        try std.testing.expectEqual(@as(f32, 0), body.velocity.y);
        try std.testing.expectEqual(CollisionResponseMobility.static, demo.data.collisionResponseConst(entity).?.mobility);
    }
}

test "demo render queue orders mixed world z records after grouped emission" {
    var demo = try GameDemoState.init(std.testing.allocator, 800, 450);
    defer demo.deinit();
    var runtime_assets = RuntimeAssets.init();

    demo.render_queue.clearRetainingCapacity();
    const high_obstacle = demo.data.movementBodyPtr(demo.obstacles[0]).?;
    high_obstacle.position_z.* = 20;
    high_obstacle.previous_z.* = 20;
    const low_actor = demo.data.movementBodyPtr(demo.test_squares[0]).?;
    low_actor.position_z.* = -20;
    low_actor.previous_z.* = -20;

    try render_prep.enqueueEntity(&demo.render_queue, &demo.data, demo.obstacles[0], &runtime_assets, 1.0);
    try render_prep.enqueueEntity(&demo.render_queue, &demo.data, demo.test_squares[0], &runtime_assets, 1.0);
    demo.render_queue.sortForSubmit();

    try std.testing.expectEqual(@as(usize, 2), demo.render_queue.recordCount());
    try std.testing.expect(demo.render_queue.recordOrder(0).lessOrEqual(demo.render_queue.recordOrder(1)));
    try std.testing.expect(demo.render_queue.recordOrder(0).depth < demo.render_queue.recordOrder(1).depth);
}

test "demo owns and completes a simulation frame during update" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var demo = try GameDemoState.init(std.testing.allocator, 800, 450);
    defer demo.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 0,
        .items_per_range = movement_range_alignment_items,
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

    try std.testing.expectEqual(SimulationPhase.finished, demo.simulation_frame.phase);
    try std.testing.expectEqual(@as(usize, 0), demo.simulation_frame.structural_commands.mergedItems().len);
    const player_after = demo.data.movementBodyConst(demo.player.entity).?;
    try std.testing.expect(player_after.position.x > player_before.position.x);
    try std.testing.expectEqual(@as(f32, 240), player_after.velocity.x);
    var any_square_moved = false;
    for (demo.test_squares, 0..) |entity, index| {
        const body = demo.data.movementBodyConst(entity).?;
        if (body.position.x != square_before[index].x or body.position.y != square_before[index].y) {
            any_square_moved = true;
        }
    }
    // At least some square activity (non-ai squares move from spawn vel; ai-driven ones via intent+consumption covered by dedicated "demo ai processor drives..." test).
    try std.testing.expect(any_square_moved);
    try std.testing.expect(demo.particles.activeCount() > 0);
    try std.testing.expect(demo.music_started);
    try std.testing.expect(audio.len() >= 2);
}

test "demo collision response blocks player against obstacles" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var demo = try GameDemoState.init(std.testing.allocator, 800, 450);
    defer demo.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 0,
        .items_per_range = movement_range_alignment_items,
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

test "demo ai processor drives non-player squares via intents (seek_target deterministic, 0-worker serial path)" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var demo = try GameDemoState.init(std.testing.allocator, 800, 450);
    defer demo.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 0,
        .items_per_range = movement_range_alignment_items,
    });
    defer threads.deinit();
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var audio = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer audio.deinit();

    // Record pre positions for sample ai squares (ai on 0=wander/1=seek/3=template-seek per 8-square spawn mix with pronounced behaviors; ai on 4/5/7 also).
    const ai0 = demo.test_squares[0];
    const ai1 = demo.test_squares[1];
    const ai3 = demo.test_squares[3];
    const pre0 = demo.data.movementBodyConst(ai0).?.position;
    const pre1 = demo.data.movementBodyConst(ai1).?.position;
    const pre3 = demo.data.movementBodyConst(ai3).?.position;

    try demo.update(.{
        .input = &InputState{},
        .audio = &audio,
        .delta_seconds = 0.016,
        .transitions = &transitions,
        .thread_system = &threads,
    });

    try std.testing.expectEqual(SimulationPhase.finished, demo.simulation_frame.phase);
    const post_intents = demo.simulation_frame.intents.mergedItems();
    try std.testing.expect(post_intents.len >= 3); // steering emitted final movement intents for ai-controlled squares

    const post0 = demo.data.movementBodyConst(ai0).?.position;
    const post1 = demo.data.movementBodyConst(ai1).?.position;
    const post3 = demo.data.movementBodyConst(ai3).?.position;
    // Driven by ai navigation + steering movement intents before movement integration.
    try std.testing.expect(post0.x != pre0.x or post0.y != pre0.y);
    try std.testing.expect(post1.x != pre1.x or post1.y != pre1.y);
    try std.testing.expect(post3.x != pre3.x or post3.y != pre3.y);

    // ai_agent present and player still special (no ai mask)
    try std.testing.expect(demo.data.hasComponents(ai0, component_masks.ai_agent));
    try std.testing.expect(!demo.data.hasComponents(demo.player.entity, component_masks.ai_agent));
}

test "demo collision response handles player contacts with moving entities" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var demo = try GameDemoState.init(std.testing.allocator, 800, 450);
    defer demo.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 0,
        .items_per_range = movement_range_alignment_items,
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

test "ai squares use consistent math.clamp and zero velocity on bounds (main thread only)" {
    var demo = try GameDemoState.init(std.testing.allocator, 800, 450);
    defer demo.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 0,
        .items_per_range = movement_range_alignment_items,
    });
    defer threads.deinit();
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var audio = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer audio.deinit();

    // Pick an ai square (index 0 is wander ai), force it out of bounds + outward vel.
    const ai_ent = demo.test_squares[0];
    const body = demo.data.movementBodyPtr(ai_ent).?;
    body.position_x.* = -10;
    body.position_y.* = 460;
    body.previous_x.* = body.position_x.*;
    body.previous_y.* = body.position_y.*;
    body.velocity_x.* = -20;
    body.velocity_y.* = 30;

    try demo.update(.{
        .input = &InputState{},
        .audio = &audio,
        .delta_seconds = 0.016,
        .transitions = &transitions,
        .thread_system = &threads,
    });

    const after = demo.data.movementBodyConst(ai_ent).?;
    // Clamped via math.clamp (pos >=0, <= bound-size), and vels zeroed for the clamped axes (AI policy).
    try std.testing.expect(after.position.x >= 0);
    try std.testing.expect(after.position.y <= 450 - 22); // size of first spec
    // vels zeroed on the violated axes (was pushed out)
    try std.testing.expectEqual(@as(f32, 0), after.velocity.x);
    try std.testing.expectEqual(@as(f32, 0), after.velocity.y);
}

test "collision sfx cooldowns harden: cap<=32, full evicts min-remaining, tick compacts for re-add, keyFor pair order" {
    var demo: GameDemoState = undefined;
    demo.collision_sfx_cooldown_count = 0;
    const mk = struct {
        fn id(i: u32, g: u32) EntityId {
            return .{ .index = i, .generation = g };
        }
    }.id;
    // keyFor is symmetric for pairs
    try std.testing.expectEqual(CollisionSfxCooldown.keyFor(mk(1, 10), mk(2, 20)), CollisionSfxCooldown.keyFor(mk(2, 20), mk(1, 10)));
    // add, tick, fill to 32
    demo.addCollisionSfxCooldown(mk(1, 1), mk(2, 2));
    demo.tickCollisionSfxCooldowns(0.01);
    var n: u32 = 3;
    while (demo.collision_sfx_cooldown_count < collision_sfx_cooldown_capacity) : (n += 1) {
        demo.addCollisionSfxCooldown(mk(n, 10), mk(n + 1, 10));
    }
    try std.testing.expectEqual(@as(usize, 32), demo.collision_sfx_cooldown_count);
    // force distinct rems so [0] is min; full add must keep count==32 and evict a min-rem
    for (&demo.collision_sfx_cooldowns, 0..) |*slot, j| {
        slot.* = .{ .key = CollisionSfxCooldown.keyFor(mk(@as(u32, @intCast(j)), 99), mk(@as(u32, @intCast(j)) + 100, 99)), .remaining_seconds = 0.01 + @as(f32, @floatFromInt(j)) * 0.001 };
    }
    demo.collision_sfx_cooldown_count = 32;
    const min_key = demo.collision_sfx_cooldowns[0].key;
    const na = mk(200, 7);
    const nb = mk(201, 7);
    demo.addCollisionSfxCooldown(na, nb);
    try std.testing.expectEqual(@as(usize, 32), demo.collision_sfx_cooldown_count);
    const nk = CollisionSfxCooldown.keyFor(na, nb);
    var saw_new = false;
    var saw_min = false;
    for (demo.collision_sfx_cooldowns[0..32]) |cd| {
        if (cd.key == nk) saw_new = true;
        if (cd.key == min_key) saw_min = true;
    }
    try std.testing.expect(saw_new);
    try std.testing.expect(!saw_min);
    // tick compacts (removes expired), allowing the pair to be re-added
    demo.collision_sfx_cooldowns[0].remaining_seconds = 0.001;
    demo.collision_sfx_cooldown_count = 2;
    demo.tickCollisionSfxCooldowns(0.01);
    try std.testing.expectEqual(@as(usize, 1), demo.collision_sfx_cooldown_count);
    demo.addCollisionSfxCooldown(mk(1, 1), mk(2, 2));
    try std.testing.expectEqual(@as(usize, 2), demo.collision_sfx_cooldown_count);
}
