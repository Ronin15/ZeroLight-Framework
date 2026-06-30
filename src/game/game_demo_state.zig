// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const config = @import("../config.zig");
const math = @import("../core/math.zig");
const builtin = @import("builtin");
const std = @import("std");
const AudioCommandBuffer = @import("../app/audio.zig").AudioCommandBuffer;
const runtime_perf_log = @import("../app/runtime_perf_log.zig");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const sprite_atlas_meta = @import("../assets/sprite_atlas_meta.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const manifest = @import("../assets/manifest.zig");
const SpriteAssetId = @import("../assets/manifest.zig").SpriteAssetId;
const AssetReference = @import("data_system.zig").AssetReference;
const component_masks = @import("data_system.zig").component_masks;
const CollisionResponseMobility = @import("data_system.zig").CollisionResponseMobility;
const CollisionResponseMode = @import("data_system.zig").CollisionResponseMode;
const DataSystem = @import("data_system.zig").DataSystem;
const DigConfig = @import("dig_controller.zig").DigConfig;
const EntityId = @import("data_system.zig").EntityId;
const MovementBody = @import("data_system.zig").MovementBody;
const PrimitiveVisual = @import("data_system.zig").PrimitiveVisual;
const EntityTemplate = @import("data_system.zig").EntityTemplate;
const movement_range_alignment_items = @import("data_system.zig").movement_range_alignment_items;
const StructuralCommitStats = @import("data_system.zig").StructuralCommitStats;
const StructuralCommand = @import("data_system.zig").StructuralCommand;
const SteeringAgent = @import("data_system.zig").SteeringAgent;
const simulation_scope = @import("simulation_scope.zig");
const InputState = @import("../app/input.zig").InputState;
const Player = @import("player.zig").Player;
const ParticleUpdateStats = @import("systems/particle.zig").ParticleUpdateStats;
const ParticleSystem = @import("systems/particle.zig").ParticleSystem;
const NavUpdateStats = @import("systems/pathfinding.zig").NavUpdateStats;
const DigIntent = @import("simulation.zig").DigIntent;
const NavInvalidationReason = @import("simulation.zig").NavInvalidationReason;
const SimulationEventStats = @import("simulation.zig").SimulationEventStats;
const SimulationFrame = @import("simulation.zig").SimulationFrame;
const SimulationPhase = @import("simulation.zig").SimulationPhase;
const SimulationPipeline = @import("simulation_pipeline.zig").SimulationPipeline;
const SimulationPipelineStats = @import("simulation_pipeline.zig").SimulationPipelineStats;
const RenderContext = @import("../app/state.zig").RenderContext;
const StateTransitions = @import("../app/state.zig").StateTransitions;
const UpdateContext = @import("../app/state.zig").UpdateContext;
const RenderOrder = @import("../render/renderer.zig").RenderOrder;
const Rect = @import("../render/renderer.zig").Rect;
const Camera2D = @import("../render/camera.zig").Camera2D;
const TextureId = @import("../render/resources.zig").TextureId;
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const render_prep = @import("render_prep.zig");
const render_depth = @import("render_depth.zig");
const WorldDepth = render_depth.WorldDepth;
const world_system = @import("world_system.zig");
const WorldSystem = world_system.WorldSystem;
const c = @import("../platform/sdl.zig").c;

const test_square_count = 8;
const obstacle_count = 2;
const demo_contact_capacity = 64;
const procedural_world_config = world_system.WorldBuildConfig{
    .width_tiles = 512,
    .height_tiles = 512,
    .chunk_size_tiles = 16,
};
const world_render_overscan_chunks: u16 = 0;

/// Comptime-gated wall-clock timer for one gameplay-tick stage. Zero-cost no-op
/// when perf logging is disabled; samples the SDL nanosecond clock otherwise.
const StageTimer = if (runtime_perf_log.enabled) struct {
    start_ns: u64,

    fn start() StageTimer {
        return .{ .start_ns = c.SDL_GetTicksNS() };
    }

    fn stop(self: StageTimer, perf: runtime_perf_log.Context, timing: runtime_perf_log.Timing) void {
        const end_ns = c.SDL_GetTicksNS();
        perf.recordTiming(timing, if (end_ns > self.start_ns) end_ns - self.start_ns else 0);
    }
} else struct {
    fn start() StageTimer {
        return .{};
    }

    fn stop(_: StageTimer, _: runtime_perf_log.Context, _: runtime_perf_log.Timing) void {}
};

pub const GameDemoState = struct {
    data: DataSystem,
    simulation_frame: SimulationFrame,
    pipeline: SimulationPipeline,
    world: WorldSystem,
    player: Player,
    particles: ParticleSystem,
    scene_prep: render_prep.DynamicScenePrep,
    test_squares: [test_square_count]EntityId,
    obstacles: [obstacle_count]EntityId,
    // Last incremental nav-update batch diagnostics, recorded into perf metrics.
    last_nav_update_stats: NavUpdateStats = .{},
    camera_previous: Camera2D = .{},
    camera_current: Camera2D = .{},
    viewport_width: f32 = 800,
    viewport_height: f32 = 450,
    bounds_width: f32 = 800,
    bounds_height: f32 = 450,

    pub fn init(
        allocator: std.mem.Allocator,
        runtime_assets: *const RuntimeAssets,
        bounds_width: f32,
        bounds_height: f32,
    ) !GameDemoState {
        return try initWithRuntimeAssets(allocator, runtime_assets, bounds_width, bounds_height);
    }

    pub fn initWithRuntimeAssets(
        allocator: std.mem.Allocator,
        runtime_assets: *const RuntimeAssets,
        bounds_width: f32,
        bounds_height: f32,
    ) !GameDemoState {
        var state = try initWithWorld(
            allocator,
            bounds_width,
            bounds_height,
            bounds_width,
            bounds_height,
            try WorldSystem.initDemo(
                allocator,
                runtime_assets,
                bounds_width,
                bounds_height,
            ),
            try DigConfig.fromRuntimeAssets(runtime_assets),
            // No thread system on this path (tests): serial, slot 0 only.
            1,
        );
        errdefer state.deinit();
        try state.validateAtlasReferences(runtime_assets);
        return state;
    }

    pub fn initProceduralWithRuntimeAssets(
        allocator: std.mem.Allocator,
        runtime_assets: *const RuntimeAssets,
        thread_system: *ThreadSystem,
        viewport_width: f32,
        viewport_height: f32,
    ) !GameDemoState {
        const world = try WorldSystem.initProcedural(
            allocator,
            runtime_assets,
            procedural_world_config,
            thread_system,
        );
        var state = try initWithWorld(
            allocator,
            viewport_width,
            viewport_height,
            world.worldWidthPixels(),
            world.worldHeightPixels(),
            world,
            try DigConfig.fromRuntimeAssets(runtime_assets),
            // The configured threaded participant count is fixed at this point; the
            // pathfinding A* scratch is sized for it during the nav build.
            thread_system.participantSlotCount(),
        );
        errdefer state.deinit();
        try state.validateAtlasReferences(runtime_assets);
        return state;
    }

    /// Resolves the dig controller's tile config (the walkable ramp and tunnel
    /// tiles) from the runtime tileset metadata.
    fn initWithWorld(
        allocator: std.mem.Allocator,
        viewport_width: f32,
        viewport_height: f32,
        simulation_bounds_width: f32,
        simulation_bounds_height: f32,
        world_value: WorldSystem,
        dig_config: DigConfig,
        worker_participant_count: usize,
    ) !GameDemoState {
        var world = world_value;
        errdefer world.deinit();
        var data = DataSystem.init(allocator);
        errdefer data.deinit();
        const player = try Player.spawn(&data);
        try data.setCollisionBounds(player.entity, .{ .size = .{ .x = 32, .y = 32 } });
        try data.setCollisionResponse(player.entity, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
        // Player starts on the surface plane (level 0); sync render z to that plane.
        const player_body = data.movementBodyPtr(player.entity).?;
        player_body.position_z.* = world.levelBaseZ(0);
        player_body.previous_z.* = world.levelBaseZ(0);
        const world_width = simulation_bounds_width;
        const world_height = simulation_bounds_height;
        const test_squares = try spawnTestSquares(&data);
        const obstacles = try spawnObstacles(&data);
        var particles = try ParticleSystem.init(allocator, .{ .capacity = 512 });
        errdefer particles.deinit();
        var scene_prep = render_prep.DynamicScenePrep.init(allocator);
        errdefer scene_prep.deinit();
        world.setVisibleChunksForWorldRect(.{
            .x = 0,
            .y = 0,
            .w = viewport_width,
            .h = viewport_height,
        }, world_render_overscan_chunks);
        var simulation_frame = SimulationFrame.init(allocator);
        errdefer simulation_frame.deinit();
        // Last arg sizes the structural-command stream: the per-step LOD tier policy
        // can emit up to one set_simulation_tier per movement body when many cross a
        // band at once, plus headroom for dig/create bursts — keeps the commit seam
        // allocation-free on churn frames.
        try simulation_frame.reserveStreams(8, 16, 16, demo_contact_capacity, 16, test_square_count + 8);
        try simulation_frame.reservePathRequests(8, test_square_count);
        var pipeline = try SimulationPipeline.init(allocator, &data, world_width, world_height, .{
            .steering_agent_capacity = test_square_count,
            .static_obstacle_capacity = obstacle_count,
            .contact_capacity = demo_contact_capacity,
            .movement_body_capacity = test_square_count + obstacle_count + 1,
            // 512x512 tiles at a 32px nav cell = one nav cell per tile, full
            // resolution.
            .nav_cell_size = 32,
            // Elastic pathfinding capacity tracks the live steering-agent crowd:
            // the per-step request/cache caps and the group-field threshold derive
            // from the agent count automatically. Only the hard ceiling is fixed, so
            // a battle grows and quiets shrinks without bumping knobs. At this demo's
            // small scale capacity settles low and the group path stays dormant.
            .pathfinding = .{
                .max_group_fields = 4,
                .max_agent_budget = 4096,
                // Configured threaded participant count; A* scratch is sized for it in
                // the nav build so the first threaded solve does no lazy allocation.
                .worker_participant_count = worker_participant_count,
            },
            .navigation_world = &world,
            .dig = dig_config,
        });
        errdefer pipeline.deinit();

        var state = GameDemoState{
            .data = data,
            .simulation_frame = simulation_frame,
            .pipeline = pipeline,
            .world = world,
            .player = player,
            .particles = particles,
            .scene_prep = scene_prep,
            .test_squares = test_squares,
            .obstacles = obstacles,
            .viewport_width = viewport_width,
            .viewport_height = viewport_height,
            .bounds_width = world_width,
            .bounds_height = world_height,
        };
        state.syncCameraToPlayer();
        try render_prep.ensureScenePrepCapacity(&state.scene_prep, state.gameplayScene());
        return state;
    }

    pub fn deinit(self: *GameDemoState) void {
        self.scene_prep.deinit();
        self.particles.deinit();
        self.world.deinit();
        self.pipeline.deinit();
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
        var input_timer = StageTimer.start();
        try self.player.applyInput(&self.data, context.input);
        self.pipeline.captureDigIntent(context.input, &self.simulation_frame);
        input_timer.stop(context.perf, .gameplay_input);

        var ambient_audio_timer = StageTimer.start();
        self.pipeline.queueAmbientAudio(context.audio, context.input, &self.data, self.player);
        ambient_audio_timer.stop(context.perf, .gameplay_audio);

        const pipeline_stats = try self.pipeline.update(.{
            .data = &self.data,
            .frame = &self.simulation_frame,
            .world = &self.world,
            .player = &self.player,
            .thread_system = context.thread_system,
            .delta_seconds = context.delta_seconds,
            .bounds_width = self.bounds_width,
            .bounds_height = self.bounds_height,
            .perf = context.perf,
        });

        var collision_audio_timer = StageTimer.start();
        self.pipeline.queueCollisionAudio(context.audio, &self.simulation_frame, &self.data, context.delta_seconds);
        collision_audio_timer.stop(context.perf, .gameplay_audio);

        var particle_timer = StageTimer.start();
        const particle_stats = self.particles.update(context.thread_system, context.delta_seconds, .{});
        particle_timer.stop(context.perf, .gameplay_particles);

        var camera_timer = StageTimer.start();
        self.updateCamera();
        camera_timer.stop(context.perf, .gameplay_camera);

        self.simulation_frame.phase = .merge_outputs;
        var structural_timer = StageTimer.start();
        const structural_stats = try self.applyStructuralCommandsAndPostCommitEvents(context.thread_system);
        structural_timer.stop(context.perf, .gameplay_structural);
        self.simulation_frame.phase = .finished;

        if (comptime runtime_perf_log.enabled) {
            recordRuntimePerfStats(
                context.perf,
                pipeline_stats,
                particle_stats,
                structural_stats,
                self.simulation_frame.events.stats,
                self.last_nav_update_stats,
            );
        }
    }

    pub fn render(self: *GameDemoState, context: RenderContext) !void {
        const camera = self.interpolatedCamera(context.interpolation_alpha);
        context.renderer.setCamera(camera);
        const camera_rect = Rect{
            .x = camera.position.x,
            .y = camera.position.y,
            .w = self.viewport_width / camera.zoom,
            .h = self.viewport_height / camera.zoom,
        };
        self.world.setVisibleChunksForWorldRect(camera_rect, world_render_overscan_chunks);
        const scene = self.gameplayScene();
        try context.renderer.reserveSpriteCommands(render_prep.spriteCommandCapacity(scene));
        try render_prep.submitGameplayFrame(
            &self.scene_prep,
            scene,
            context.renderer,
            context.runtime_assets,
            context.interpolation_alpha,
            camera_rect,
        );
    }

    fn gameplayScene(self: *GameDemoState) render_prep.GameplayScene {
        return .{
            .data = &self.data,
            .world = &self.world,
            .player_entity = self.player.entity,
            .player_level = self.player.current_level,
            .particles = &self.particles,
            .overscan_chunks = world_render_overscan_chunks,
        };
    }

    fn recordRuntimePerfStats(
        perf: runtime_perf_log.Context,
        pipeline_stats: SimulationPipelineStats,
        particle_stats: ParticleUpdateStats,
        structural_stats: StructuralCommitStats,
        event_stats: SimulationEventStats,
        nav_update_stats: NavUpdateStats,
    ) void {
        const scope_stats = pipeline_stats.scope.stats;
        const ai_stats = pipeline_stats.ai;
        const steering_stats = pipeline_stats.steering;
        const pathfinding_stats = pipeline_stats.pathfinding;
        const movement_stats = pipeline_stats.movement;
        const collision_stats = pipeline_stats.collision;
        const collision_response_stats = pipeline_stats.collision_response;

        perf.recordMetric(.scope_total_entities, metric(scope_stats.total_entities));
        perf.recordMetric(.scope_dormant_entities, metric(scope_stats.dormant_entities));
        perf.recordMetric(.scope_kinematic_entities, metric(scope_stats.kinematic_entities));
        perf.recordMetric(.scope_locomotion_entities, metric(scope_stats.locomotion_entities));
        perf.recordMetric(.scope_cognition_entities, metric(scope_stats.cognition_entities));
        perf.recordMetric(.scope_movement_stage_entities, metric(scope_stats.movement_stage_entities));
        perf.recordMetric(.scope_collision_stage_entities, metric(scope_stats.collision_stage_entities));
        perf.recordMetric(.scope_collision_response_stage_entities, metric(scope_stats.collision_response_stage_entities));
        perf.recordMetric(.scope_ai_stage_entities, metric(scope_stats.ai_stage_entities));
        perf.recordMetric(.scope_steering_stage_entities, metric(scope_stats.steering_stage_entities));
        perf.recordMetric(.scope_stagger_skips, metric(scope_stats.stagger_skips));
        perf.recordMetric(.scope_chunk_filtered_entities, metric(scope_stats.chunk_filtered_entities));

        perf.recordMetric(.ai_entities, metric(ai_stats.entity_count));
        perf.recordMetric(.ai_intents, metric(ai_stats.intent_count));
        perf.recordMetric(.ai_navigation_intents, metric(ai_stats.navigation_intent_count));
        perf.recordMetric(.ai_separation_candidate_checks, metric(ai_stats.separation_candidate_checks));
        perf.recordMetric(.ai_separation_neighbor_samples, metric(ai_stats.separation_neighbor_samples));
        perf.recordBatch(.ai_separation, ai_stats.separation_batch);
        perf.recordBatch(.ai_intent, ai_stats.intent_batch);

        perf.recordMetric(.steering_navigation_intents, metric(steering_stats.navigation_intent_count));
        perf.recordMetric(.steering_selected_intents, metric(steering_stats.selected_intent_count));
        perf.recordMetric(.steering_movement_intents, metric(steering_stats.movement_intent_count));
        perf.recordMetric(.steering_path_requests, metric(steering_stats.path_request_count));
        perf.recordMetric(.steering_paths_available, metric(steering_stats.path_available_count));
        perf.recordMetric(.steering_paths_pending, metric(steering_stats.path_pending_count));
        perf.recordMetric(.steering_paths_unavailable, metric(steering_stats.path_unavailable_count));
        perf.recordMetric(.steering_replan_cooldowns, metric(steering_stats.replan_cooldown_count));
        perf.recordMetric(.steering_unavailable_backoffs, metric(steering_stats.unavailable_backoff_count));
        perf.recordMetric(.steering_stuck_replans, metric(steering_stats.stuck_replan_count));
        perf.recordMetric(.steering_agent_neighbor_samples, metric(steering_stats.agent_neighbor_samples));
        perf.recordMetric(.steering_obstacle_samples, metric(steering_stats.obstacle_samples));
        perf.recordMetric(.steering_agent_candidate_checks, metric(steering_stats.agent_candidate_checks));
        perf.recordMetric(.steering_obstacle_candidate_checks, metric(steering_stats.obstacle_candidate_checks));
        perf.recordBatch(.steering, steering_stats.batch);

        perf.recordMetric(.path_accepted_requests, metric(pathfinding_stats.accepted_requests));
        perf.recordMetric(.path_duplicate_requests, metric(pathfinding_stats.duplicate_requests));
        perf.recordMetric(.path_pending_requests, metric(pathfinding_stats.pending_requests));
        perf.recordMetric(.path_solved_requests, metric(pathfinding_stats.solved_requests));
        perf.recordMetric(.path_fallback_requests, metric(pathfinding_stats.fallback_requests));
        perf.recordMetric(.path_available_results, metric(pathfinding_stats.available_results));
        perf.recordMetric(.path_unavailable_results, metric(pathfinding_stats.unavailable_results));
        perf.recordMetric(.path_dropped_requests, metric(pathfinding_stats.dropped_requests));
        perf.recordMetric(.path_deferred_requests, metric(pathfinding_stats.deferred_requests));
        perf.recordMetric(.path_fallback_deferred_requests, metric(pathfinding_stats.fallback_deferred_requests));
        perf.recordMetric(.path_cache_hits, metric(pathfinding_stats.cache_hits));
        perf.recordMetric(.path_cache_evictions, metric(pathfinding_stats.cache_evictions));
        perf.recordMetric(.path_budget_exhausted, metric(pathfinding_stats.budget_exhausted));
        perf.recordMetric(.path_goal_projected, metric(pathfinding_stats.goal_projected));
        perf.recordMetric(.path_group_fields_built, metric(pathfinding_stats.group_fields_built));
        perf.recordMetric(.path_group_field_reuses, metric(pathfinding_stats.group_field_reuses));
        perf.recordMetric(.path_group_field_rebuild_throttled, metric(pathfinding_stats.group_field_rebuild_throttled));
        perf.recordMetric(.path_group_field_samples, metric(pathfinding_stats.group_field_samples));
        perf.recordBatch(.path_fallback, pathfinding_stats.fallback_batch);
        perf.recordTiming(.pathfinding_accept, pathfinding_stats.accept_ns);
        perf.recordTiming(.pathfinding_group_service, pathfinding_stats.group_service_ns);
        perf.recordTiming(.pathfinding_solve, pathfinding_stats.solve_ns);
        perf.recordTiming(.pathfinding_publish, pathfinding_stats.publish_ns);

        perf.recordMetric(.movement_bodies, metric(movement_stats.body_count));
        perf.recordBatch(.movement, movement_stats.batch);

        perf.recordMetric(.collision_bodies, metric(collision_stats.body_count));
        perf.recordMetric(.collision_candidate_pairs, metric(collision_stats.candidate_pair_count));
        perf.recordMetric(.collision_contacts, metric(collision_stats.contact_count));
        perf.recordMetric(.collision_broadphase_simd_groups, metric(collision_stats.broadphase_simd_groups));
        if (collision_stats.used_full_sort) perf.recordMetric(.collision_full_sorts, 1);
        perf.recordBatch(.collision_broadphase, collision_stats.broadphase_batch);
        perf.recordBatch(.collision_narrowphase, collision_stats.narrowphase_batch);

        perf.recordMetric(.collision_response_contacts, metric(collision_response_stats.contact_count));
        perf.recordMetric(.collision_response_intents, metric(collision_response_stats.intent_count));
        perf.recordMetric(.collision_response_triggers, metric(collision_response_stats.trigger_count));

        perf.recordMetric(.particle_active_before, metric(particle_stats.active_before));
        perf.recordMetric(.particle_active_after, metric(particle_stats.active_after));
        perf.recordMetric(.particle_removed, metric(particle_stats.removed_count));
        perf.recordBatch(.particles, particle_stats.batch);

        perf.recordMetric(.structural_created, metric(structural_stats.created));
        perf.recordMetric(.structural_destroyed, metric(structural_stats.destroyed));
        perf.recordMetric(.structural_components_set, metric(structural_stats.components_set));
        perf.recordMetric(.structural_stale_skipped, metric(structural_stats.stale_skipped));

        perf.recordMetric(.simulation_events_total, metric(event_stats.total));
        perf.recordMetric(.simulation_events_dropped, metric(event_stats.dropped));
        perf.recordMetric(.simulation_events_entity_created, metric(event_stats.entity_created));
        perf.recordMetric(.simulation_events_entity_destroyed, metric(event_stats.entity_destroyed));
        perf.recordMetric(.simulation_events_component_changed, metric(event_stats.component_changed));
        perf.recordMetric(.simulation_events_world_tile_changed, metric(event_stats.world_tile_changed));
        perf.recordMetric(.simulation_events_world_obstacle_changed, metric(event_stats.world_obstacle_changed));
        perf.recordMetric(.simulation_events_nav_region_invalidated, metric(event_stats.nav_region_invalidated));
        perf.recordMetric(.simulation_events_structural_commit_stage, metric(event_stats.structural_commit_stage));
        perf.recordMetric(.simulation_events_domain_reaction_stage, metric(event_stats.domain_reaction_stage));

        perf.recordMetric(.nav_dirty_chunks, metric(nav_update_stats.dirty_chunks));
        perf.recordMetric(.nav_incremental_rebuilds, metric(nav_update_stats.incremental_rebuilds));
        perf.recordMetric(.nav_full_relabel, metric(nav_update_stats.full_relabel));
        perf.recordMetric(.nav_version_bumps, metric(nav_update_stats.version_bumps));
        perf.recordMetric(.nav_chunks_patched, metric(nav_update_stats.chunks_patched));
        perf.recordMetric(.nav_edge_cap_fallback, metric(nav_update_stats.edge_cap_fallback));
    }

    fn metric(value: usize) u64 {
        return @intCast(value);
    }

    pub fn onPause(self: *GameDemoState) void {
        self.pipeline.pauseAudio();
        self.syncInterpolatedState();
    }

    pub fn onResume(self: *GameDemoState) void {
        self.syncInterpolatedState();
    }

    fn syncInterpolatedState(self: *GameDemoState) void {
        self.pipeline.syncPreviousPositions(&self.data);
        self.particles.syncPreviousPositions();
        self.syncCameraToPlayer();
    }

    fn syncCameraToPlayer(self: *GameDemoState) void {
        const camera = self.cameraForPlayer();
        self.camera_previous = camera;
        self.camera_current = camera;
    }

    fn updateCamera(self: *GameDemoState) void {
        self.camera_previous = self.camera_current;
        self.camera_current = self.cameraForPlayer();
    }

    fn interpolatedCamera(self: *const GameDemoState, interpolation_alpha: f32) Camera2D {
        return .{
            .position = math.lerpVec2(self.camera_previous.position, self.camera_current.position, interpolation_alpha),
            .zoom = self.camera_current.zoom,
        };
    }

    fn cameraForPlayer(self: *const GameDemoState) Camera2D {
        const body = self.data.movementBodyConst(self.player.entity) orelse return self.camera_current;
        const visual = self.data.primitiveVisualConst(self.player.entity) orelse return self.camera_current;
        const target_x = body.position.x + visual.size.x * 0.5 - self.viewport_width * 0.5;
        const target_y = body.position.y + visual.size.y * 0.5 - self.viewport_height * 0.5;
        return .{
            .position = .{
                .x = math.clamp(target_x, 0, @max(self.bounds_width - self.viewport_width, 0)),
                .y = math.clamp(target_y, 0, @max(self.bounds_height - self.viewport_height, 0)),
            },
            .zoom = 1.0,
        };
    }

    fn applyStructuralCommandsAndPostCommitEvents(self: *GameDemoState, thread_system: ?*ThreadSystem) !StructuralCommitStats {
        // The post-commit nav reaction appends at most one nav_region_invalidated
        // event, driven by EITHER structural commands applied this frame OR
        // invalidating world events already queued in the stream (e.g. a dig's
        // world_tile_changed that did not originate from a structural command).
        // Reserve the slot for both sources so the append never trips a tight
        // capacity_limit.
        const may_invalidate_navigation = SimulationPipeline.structuralCommandsMayInvalidateNavigation(&self.data, &self.simulation_frame) or
            SimulationPipeline.pendingEventsMayInvalidateNavigation(&self.simulation_frame);
        const extra_event_count: usize = if (may_invalidate_navigation) 1 else 0;
        const stats = try self.simulation_frame.applyStructuralCommandsWithExtraEvents(&self.data, extra_event_count);
        self.last_nav_update_stats = try self.pipeline.reactToPostCommitNavEvents(&self.simulation_frame, &self.data, &self.world, thread_system);
        try render_prep.ensureScenePrepCapacity(&self.scene_prep, self.gameplayScene());
        return stats;
    }

    fn validateAtlasReferences(self: *const GameDemoState, runtime_assets: *const RuntimeAssets) !void {
        try validateAtlasReferencesInData(&self.data, runtime_assets);
    }
};

fn validateAtlasReferencesInData(data: *const DataSystem, runtime_assets: *const RuntimeAssets) !void {
    const asset_refs = data.assetReferenceSliceConst();
    for (asset_refs.sprite_ids, asset_refs.atlas_entry_ids) |sprite_id, atlas_entry_id| {
        try validateAtlasReference(.{ .sprite = sprite_id, .atlas_entry_id = atlas_entry_id }, runtime_assets);
    }
}

fn validateAtlasReference(asset_ref: AssetReference, runtime_assets: *const RuntimeAssets) !void {
    if (!asset_ref.hasAtlasEntry()) return;
    const meta = runtime_assets.spriteAtlasMeta(asset_ref.sprite) orelse return error.SpriteAtlasMetadataUnavailable;
    if (meta.sourceRectForId(asset_ref.atlas_entry_id) == null) return error.InvalidSpriteAtlasEntry;
}

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
                    .asset_reference = demoCharacterAssetReference(index),
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
            try data.setAssetReference(e, demoCharacterAssetReference(index));
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

fn demoSteeringAgent(size: math.Vec2) SteeringAgent {
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

fn demoCharacterAssetReference(index: usize) AssetReference {
    const character_ids = [_]u16{ 8, 9, 10, 11, 12, 13, 14, 15 };
    return .{ .sprite = .grim_characters, .atlas_entry_id = character_ids[index % character_ids.len] };
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

fn runtimeAssetsWithWorldTexture() !RuntimeAssets {
    var runtime_assets = RuntimeAssets.init();
    setSpriteAvailableForTest(&runtime_assets, .world_tileset, try TextureId.init(1, 1));
    return runtime_assets;
}

fn runtimeAssetsWithWorldMetadataForTest() !RuntimeAssets {
    var runtime_assets = try runtimeAssetsWithWorldTexture();
    runtime_assets.allocator = std.testing.allocator;
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    runtime_assets.atlas_meta[manifest.spriteIndex(.world_tileset)] = .{
        .world_tileset = try world_tileset_meta.load(
            std.testing.allocator,
            asset_store,
            manifest.spriteSpec(.world_tileset).metadata_path.?,
        ),
    };
    return runtime_assets;
}

fn runtimeAssetsWithDemoMetadataForTest() !RuntimeAssets {
    var runtime_assets = try runtimeAssetsWithWorldMetadataForTest();
    errdefer deinitRuntimeAssetMetadataForTest(&runtime_assets);
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    runtime_assets.atlas_meta[manifest.spriteIndex(.grim_characters)] = .{
        .sprite_atlas = try sprite_atlas_meta.load(
            std.testing.allocator,
            asset_store,
            .grim_characters,
            manifest.spriteSpec(.grim_characters).metadata_path.?,
        ),
    };
    return runtime_assets;
}

fn deinitRuntimeAssetMetadataForTest(runtime_assets: *RuntimeAssets) void {
    for (&runtime_assets.atlas_meta) |*slot| {
        if (slot.*) |*meta| {
            switch (meta.*) {
                .world_tileset => |*world_meta| world_meta.deinit(),
                .sprite_atlas => |*atlas_meta| atlas_meta.deinit(),
            }
        }
        slot.* = null;
    }
}

fn setSpriteAvailableForTest(runtime_assets: *RuntimeAssets, id: SpriteAssetId, texture: TextureId) void {
    runtime_assets.sprite_slots[manifest.spriteIndex(id)] = .{
        .status = .available,
        .lease = .{ .id = texture },
    };
}

fn initDemoForTest(allocator: std.mem.Allocator, bounds_width: f32, bounds_height: f32) !GameDemoState {
    const asset_store = AssetStore.init(allocator, std.testing.io, "assets");
    const meta = try world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    var world = try WorldSystem.initDemoFromMetaWithUnderground(allocator, &meta, bounds_width, bounds_height);
    world.adoptTilesetMeta(meta);
    const dig_config = try DigConfig.fromMeta(world.tileset_meta.?);
    return try GameDemoState.initWithWorld(allocator, bounds_width, bounds_height, bounds_width, bounds_height, world, dig_config, 1);
}

fn digFacedForTest(demo: *GameDemoState, intent: DigIntent) !void {
    demo.simulation_frame.beginStep();
    demo.simulation_frame.dig_intent = intent;
    try demo.pipeline.dig.process(&demo.world, &demo.data, demo.player, &demo.simulation_frame);
}

fn placePlayerInCell(demo: *GameDemoState, cx: u16, cy: u16) void {
    const body = demo.data.movementBodyPtr(demo.player.entity).?;
    const visual = demo.data.primitiveVisualConst(demo.player.entity).?;
    body.position_x.* = @as(f32, @floatFromInt(cx)) * 32 + 16 - visual.size.x * 0.5;
    body.position_y.* = @as(f32, @floatFromInt(cy)) * 32 + 16 - visual.size.y * 0.5;
}

test "demo spawns atlas-backed moving actors" {
    var demo = try initDemoForTest(std.testing.allocator, 800, 450);
    defer demo.deinit();

    try std.testing.expectEqual(@as(usize, test_square_count + obstacle_count + 1), demo.data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, test_square_count + obstacle_count + 1), demo.data.collisionBoundsSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, test_square_count + obstacle_count + 1), demo.data.collisionResponseSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, test_square_count + obstacle_count + 1), demo.data.assetReferenceSliceConst().entities.len);
    const player_asset = demo.data.assetReferenceConst(demo.player.entity).?;
    try std.testing.expectEqual(SpriteAssetId.grim_characters, player_asset.sprite);
    try std.testing.expect(player_asset.hasAtlasEntry());
    try std.testing.expectEqual(@as(usize, 0), demo.particles.activeCount());
    for (demo.test_squares) |entity| {
        try std.testing.expect(demo.data.hasComponents(entity, component_masks.movement_body | component_masks.primitive_visual | component_masks.asset_reference | component_masks.collision_bounds | component_masks.collision_response));
        const asset_ref = demo.data.assetReferenceConst(entity).?;
        try std.testing.expectEqual(SpriteAssetId.grim_characters, asset_ref.sprite);
        try std.testing.expect(asset_ref.hasAtlasEntry());
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

test "demo actor atlas entries resolve in installed character metadata" {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try sprite_atlas_meta.load(
        std.testing.allocator,
        asset_store,
        .grim_characters,
        manifest.spriteSpec(.grim_characters).metadata_path.?,
    );
    defer meta.deinit();

    const player_asset = AssetReference{ .sprite = .grim_characters, .atlas_entry_id = 0 };
    try std.testing.expect(meta.sourceRectForId(player_asset.atlas_entry_id) != null);
    for (0..test_square_count) |index| {
        const asset_ref = demoCharacterAssetReference(index);
        try std.testing.expectEqual(SpriteAssetId.grim_characters, asset_ref.sprite);
        try std.testing.expect(meta.sourceRectForId(asset_ref.atlas_entry_id) != null);
    }
}

test "demo init validates atlas-backed references at loading boundary" {
    var runtime_assets = try runtimeAssetsWithDemoMetadataForTest();
    defer deinitRuntimeAssetMetadataForTest(&runtime_assets);

    var demo = try GameDemoState.initWithRuntimeAssets(std.testing.allocator, &runtime_assets, 800, 450);
    defer demo.deinit();

    try std.testing.expectEqual(@as(usize, test_square_count + obstacle_count + 1), demo.data.assetReferenceSliceConst().entities.len);
}

test "procedural demo uses large world bounds and interpolated follow camera" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var runtime_assets = try runtimeAssetsWithDemoMetadataForTest();
    defer deinitRuntimeAssetMetadataForTest(&runtime_assets);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();

    var demo = try GameDemoState.initProceduralWithRuntimeAssets(std.testing.allocator, &runtime_assets, &threads, 800, 450);
    defer demo.deinit();

    try std.testing.expectEqual(@as(f32, 800), demo.viewport_width);
    try std.testing.expectEqual(@as(f32, 450), demo.viewport_height);
    try std.testing.expect(demo.bounds_width > demo.viewport_width);
    try std.testing.expect(demo.bounds_height > demo.viewport_height);

    const body = demo.data.movementBodyPtr(demo.player.entity).?;
    body.position_x.* = 4096.5;
    body.position_y.* = 2048.25;
    body.previous_x.* = 4090.5;
    body.previous_y.* = 2040.25;
    demo.updateCamera();

    const camera = demo.interpolatedCamera(0.5);
    try std.testing.expect(camera.position.x > 0);
    try std.testing.expect(camera.position.y > 0);
    try std.testing.expect(camera.position.x != @floor(camera.position.x));
}

test "demo init rejects missing character atlas metadata" {
    var runtime_assets = try runtimeAssetsWithWorldMetadataForTest();
    defer deinitRuntimeAssetMetadataForTest(&runtime_assets);

    try std.testing.expectError(
        error.SpriteAtlasMetadataUnavailable,
        GameDemoState.initWithRuntimeAssets(std.testing.allocator, &runtime_assets, 800, 450),
    );
}

test "demo atlas validation rejects invalid character entry ids" {
    var runtime_assets = try runtimeAssetsWithDemoMetadataForTest();
    defer deinitRuntimeAssetMetadataForTest(&runtime_assets);
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const entity = try data.createEntity();
    try data.setAssetReference(entity, .{ .sprite = .grim_characters, .atlas_entry_id = 4096 });

    try std.testing.expectError(
        error.InvalidSpriteAtlasEntry,
        validateAtlasReferencesInData(&data, &runtime_assets),
    );
}

test "demo world tile event invalidates navigation after commit reaction" {
    var demo = try initDemoForTest(std.testing.allocator, 800, 450);
    defer demo.deinit();

    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    const water = (meta.tileByName("water_1") orelse return error.TestExpectedEqual).id;
    const changed = (try demo.world.setDenseTile(0, 1, 1, water)) orelse return error.TestExpectedEqual;
    try demo.simulation_frame.events.appendRequired(.{
        .stage = .structural_commit,
        .payload = .{ .world_tile_changed = changed },
    });

    demo.last_nav_update_stats = try demo.pipeline.reactToPostCommitNavEvents(&demo.simulation_frame, &demo.data, &demo.world, null);

    var nav_invalidated = false;
    for (demo.simulation_frame.events.mergedItems()) |event| {
        switch (event.payload) {
            .nav_region_invalidated => nav_invalidated = true,
            else => {},
        }
    }
    try std.testing.expect(nav_invalidated);
}

test "demo dig hole drops the player one plane and a ramp climbs back" {
    var demo = try initDemoForTest(std.testing.allocator, 800, 450);
    defer demo.deinit();

    demo.data.facingPtr(demo.player.entity).?.* = .right;
    placePlayerInCell(&demo, 3, 3); // stands on (3,3), faces (4,3)
    try demo.pipeline.dig.applyPlaneTraversal(&demo.world, &demo.data, &demo.player, &demo.simulation_frame); // seed player_last_cell = (3,3)
    try std.testing.expectEqual(@as(u16, 0), demo.player.current_level);

    // Dig a hole in the faced cell on the surface plane.
    try digFacedForTest(&demo, .hole);
    const floor0 = demo.world.denseFloorLayerForLevel(0).?;
    try std.testing.expectEqual(world_system.invalid_tile_id, demo.world.denseTile(floor0, 4, 3));

    // Walk into the hole -> fall exactly one level onto the dirt plane.
    placePlayerInCell(&demo, 4, 3);
    try demo.pipeline.dig.applyPlaneTraversal(&demo.world, &demo.data, &demo.player, &demo.simulation_frame);
    try std.testing.expectEqual(@as(u16, 1), demo.player.current_level);
    try std.testing.expectEqual(demo.world.levelBaseZ(1), demo.data.movementBodyConst(demo.player.entity).?.position_z);

    // The solid-dirt landing cell is carved walkable so the fall does not bury
    // the player in rock.
    const floor1 = demo.world.denseFloorLayerForLevel(1).?;
    try std.testing.expect(!demo.world.denseTileBlocksMovement(floor1, 4, 3));

    // Standing put: no second fall.
    try demo.pipeline.dig.applyPlaneTraversal(&demo.world, &demo.data, &demo.player, &demo.simulation_frame);
    try std.testing.expectEqual(@as(u16, 1), demo.player.current_level);

    // On the dirt plane, dig a ramp in the faced cell (5,3), then walk onto it.
    try digFacedForTest(&demo, .ramp);
    try std.testing.expectEqual(@as(u16, 1), demo.world.levelLinks().len);
    placePlayerInCell(&demo, 5, 3);
    try demo.pipeline.dig.applyPlaneTraversal(&demo.world, &demo.data, &demo.player, &demo.simulation_frame);
    try std.testing.expectEqual(@as(u16, 0), demo.player.current_level);
    try std.testing.expectEqual(demo.world.levelBaseZ(0), demo.data.movementBodyConst(demo.player.entity).?.position_z);
}

test "demo ramp dig drives the real post-commit nav re-mask without panicking on an interior cell" {
    // Regression: digRamp adds a LevelLink at runtime (dig_controller.zig). The dug cell's
    // chunk is re-masked at the structural-commit gate via processPostCommitEvents ->
    // applyNavUpdates. A faced interior cell whose endpoint has no init-built slot must be
    // DEFERRED by tryLinkPortal, not resolved against an absent run (linkTailIndex unreachable).
    var demo = try initDemoForTest(std.testing.allocator, 800, 450);
    defer demo.deinit();

    demo.data.facingPtr(demo.player.entity).?.* = .right;
    placePlayerInCell(&demo, 3, 3);
    try demo.pipeline.dig.applyPlaneTraversal(&demo.world, &demo.data, &demo.player, &demo.simulation_frame);

    // Fall to the dirt plane, then dig a ramp at the faced interior cell (5,3).
    try digFacedForTest(&demo, .hole);
    placePlayerInCell(&demo, 4, 3);
    try demo.pipeline.dig.applyPlaneTraversal(&demo.world, &demo.data, &demo.player, &demo.simulation_frame);
    try std.testing.expectEqual(@as(u16, 1), demo.player.current_level);

    try digFacedForTest(&demo, .ramp);
    try std.testing.expectEqual(@as(usize, 1), demo.world.levelLinks().len);
    // The real per-step nav re-mask the live game runs each frame. Must not panic.
    demo.last_nav_update_stats = try demo.pipeline.reactToPostCommitNavEvents(&demo.simulation_frame, &demo.data, &demo.world, null);

    // The link still climbs planes via the world tier (independent of the abstract graph).
    placePlayerInCell(&demo, 5, 3);
    try demo.pipeline.dig.applyPlaneTraversal(&demo.world, &demo.data, &demo.player, &demo.simulation_frame);
    try std.testing.expectEqual(@as(u16, 0), demo.player.current_level);
}

test "demo dig down drops the player through the dirt plane to the void plane" {
    var demo = try initDemoForTest(std.testing.allocator, 800, 450);
    defer demo.deinit();

    demo.data.facingPtr(demo.player.entity).?.* = .right;
    placePlayerInCell(&demo, 3, 3); // stands on (3,3), faces (4,3)
    try demo.pipeline.dig.applyPlaneTraversal(&demo.world, &demo.data, &demo.player, &demo.simulation_frame); // seed player_last_cell = (3,3)

    // Surface hole + fall onto the dirt plane (level 1), landing carved at (4,3).
    try digFacedForTest(&demo, .hole);
    placePlayerInCell(&demo, 4, 3);
    try demo.pipeline.dig.applyPlaneTraversal(&demo.world, &demo.data, &demo.player, &demo.simulation_frame);
    try std.testing.expectEqual(@as(u16, 1), demo.player.current_level);

    // Dig DOWN through the faced cell (5,3): a see-through hole, not a tunnel carve.
    try digFacedForTest(&demo, .down);
    const floor1 = demo.world.denseFloorLayerForLevel(1).?;
    try std.testing.expectEqual(world_system.invalid_tile_id, demo.world.denseTile(floor1, 5, 3));

    // Walk into it -> fall one more level onto the void plane (level 2).
    placePlayerInCell(&demo, 5, 3);
    try demo.pipeline.dig.applyPlaneTraversal(&demo.world, &demo.data, &demo.player, &demo.simulation_frame);
    try std.testing.expectEqual(@as(u16, 2), demo.player.current_level);
    try std.testing.expectEqual(demo.world.levelBaseZ(2), demo.data.movementBodyConst(demo.player.entity).?.position_z);

    // The void-plane landing cell is carved walkable so the player is not buried.
    const floor2 = demo.world.denseFloorLayerForLevel(2).?;
    try std.testing.expect(!demo.world.denseTileBlocksMovement(floor2, 5, 3));
}

test "demo multi-cell obstacle rect event blocks every covered nav cell in one batch" {
    var demo = try initDemoForTest(std.testing.allocator, 800, 450);
    defer demo.deinit();

    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    const grass = (meta.tileByName("grass") orelse return error.TestExpectedEqual).id;
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;

    // A multi-cell obstacle rect: the post-commit reaction expands it to cells, forwards them
    // to the pathfinding system's dirty buffer, and applyNavUpdates blocks every covered cell.
    // This is the play-state reaction check (world stays consistent); the engine's no-drop and
    // whole-chunk remask behavior is covered by the pathfinding system tests.
    const obstacle_layer = try demo.world.addDenseLayer(0, 0, .obstacle, grass);
    const min_x: u16 = 2;
    const min_y: u16 = 2;
    const max_x_exclusive: u16 = 7;
    const max_y_exclusive: u16 = 7;
    var yy: u16 = min_y;
    while (yy < max_y_exclusive) : (yy += 1) {
        var xx: u16 = min_x;
        while (xx < max_x_exclusive) : (xx += 1) {
            _ = try demo.world.setDenseTile(obstacle_layer, xx, yy, tree);
        }
    }
    try demo.simulation_frame.events.appendRequired(.{
        .stage = .structural_commit,
        .payload = .{ .world_obstacle_changed = .{
            .level = 0,
            .min_x = min_x,
            .min_y = min_y,
            .max_x_exclusive = max_x_exclusive,
            .max_y_exclusive = max_y_exclusive,
        } },
    });

    demo.last_nav_update_stats = try demo.pipeline.reactToPostCommitNavEvents(&demo.simulation_frame, &demo.data, &demo.world, null);

    // The incremental update ran; a pure incremental dig keeps nav_version stable
    // (caches are scope-evicted, not version-invalidated), so no version bump.
    try std.testing.expectEqual(@as(usize, 1), demo.last_nav_update_stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), demo.last_nav_update_stats.version_bumps);

    // Every covered cell is blocked even though the rect overflowed the dirty scratch.
    yy = min_y;
    while (yy < max_y_exclusive) : (yy += 1) {
        var xx: u16 = min_x;
        while (xx < max_x_exclusive) : (xx += 1) {
            try std.testing.expect(demo.world.levelBlocksMovement(0, xx, yy));
        }
    }

    var nav_invalidated = false;
    for (demo.simulation_frame.events.mergedItems()) |event| {
        switch (event.payload) {
            .nav_region_invalidated => nav_invalidated = true,
            else => {},
        }
    }
    try std.testing.expect(nav_invalidated);
}

test "demo owns and completes a simulation frame during update" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var demo = try initDemoForTest(std.testing.allocator, 800, 450);
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
    var runtime_assets = RuntimeAssets.init();
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
        .runtime_assets = &runtime_assets,
        .delta_seconds = 0.016,
        .transitions = &transitions,
        .thread_system = &threads,
    });

    try std.testing.expectEqual(SimulationPhase.finished, demo.simulation_frame.phase);
    try std.testing.expectEqual(@as(usize, 0), demo.simulation_frame.structural_commands.mergedItems().len);
    const player_after = demo.data.movementBodyConst(demo.player.entity).?;
    try std.testing.expect(player_after.position.x > player_before.position.x);
    // moveRight (direction.x = 1) * Player.speed (120) = 120.
    try std.testing.expectEqual(@as(f32, 120), player_after.velocity.x);
    var any_square_moved = false;
    for (demo.test_squares, 0..) |entity, index| {
        const body = demo.data.movementBodyConst(entity).?;
        if (body.position.x != square_before[index].x or body.position.y != square_before[index].y) {
            any_square_moved = true;
        }
    }
    try std.testing.expect(any_square_moved);
    try std.testing.expect(demo.pipeline.audio_controller.music_started);
    try std.testing.expect(audio.len() >= 2);
}

test "demo queues jet loop audio only on movement edges" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var demo = try initDemoForTest(std.testing.allocator, 800, 450);
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
    var runtime_assets = RuntimeAssets.init();
    var input = InputState{};
    input.setHeld(.moveRight, true);

    try demo.update(.{
        .input = &input,
        .audio = &audio,
        .runtime_assets = &runtime_assets,
        .delta_seconds = 0.016,
        .transitions = &transitions,
        .thread_system = &threads,
    });
    try std.testing.expect(demo.pipeline.audio_controller.jet_loop_active);
    try std.testing.expect(audio.len() >= 3);

    audio.beginStep();
    try demo.update(.{
        .input = &input,
        .audio = &audio,
        .runtime_assets = &runtime_assets,
        .delta_seconds = 0.016,
        .transitions = &transitions,
        .thread_system = &threads,
    });
    try std.testing.expect(demo.pipeline.audio_controller.jet_loop_active);
    try std.testing.expectEqual(@as(usize, 1), audio.len());

    input.setHeld(.moveRight, false);
    audio.beginStep();
    try demo.update(.{
        .input = &input,
        .audio = &audio,
        .runtime_assets = &runtime_assets,
        .delta_seconds = 0.016,
        .transitions = &transitions,
        .thread_system = &threads,
    });
    try std.testing.expect(!demo.pipeline.audio_controller.jet_loop_active);
    try std.testing.expectEqual(@as(usize, 2), audio.len());
}

test "demo collision response blocks player against obstacles" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var demo = try initDemoForTest(std.testing.allocator, 800, 450);
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
    var runtime_assets = RuntimeAssets.init();

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
        .runtime_assets = &runtime_assets,
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

    var demo = try initDemoForTest(std.testing.allocator, 800, 450);
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
    var runtime_assets = RuntimeAssets.init();

    // Record pre positions for sample ai squares (ai on 0=wander/1=seek/3=template-seek per 8-square spawn mix with pronounced behaviors; ai on 4/5/7 also).
    const ai0 = demo.test_squares[0];
    const ai1 = demo.test_squares[1];
    const ai3 = demo.test_squares[3];
    const pre0 = demo.data.movementBodyConst(ai0).?.position;
    const pre1 = demo.data.movementBodyConst(ai1).?.position;
    const pre3 = demo.data.movementBodyConst(ai3).?.position;

    // Cognition (AI + steering) is staggered: each entity thinks once per
    // cognition_stagger_n steps, so a single step drives only a phase subset.
    // Run a full stagger cycle so every tracked square gets its think step, then
    // assert all of them were driven by intents over the cycle.
    var total_intents: usize = 0;
    for (0..simulation_scope.cognition_stagger_n) |_| {
        try demo.update(.{
            .input = &InputState{},
            .audio = &audio,
            .runtime_assets = &runtime_assets,
            .delta_seconds = 0.016,
            .transitions = &transitions,
            .thread_system = &threads,
        });
        try std.testing.expectEqual(SimulationPhase.finished, demo.simulation_frame.phase);
        total_intents += demo.simulation_frame.intents.mergedItems().len;
    }
    try std.testing.expect(total_intents >= 3); // steering emitted final movement intents across the cycle

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

    var demo = try initDemoForTest(std.testing.allocator, 800, 450);
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
    var runtime_assets = RuntimeAssets.init();

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
        .runtime_assets = &runtime_assets,
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
    var demo = try initDemoForTest(std.testing.allocator, 800, 450);
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
    var runtime_assets = RuntimeAssets.init();

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
        .runtime_assets = &runtime_assets,
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

test "demo structural static obstacle change emits one navigation invalidation event" {
    var demo = try initDemoForTest(std.testing.allocator, 800, 450);
    defer demo.deinit();

    demo.simulation_frame.beginStep();
    try demo.simulation_frame.structural_commands.prepareRangeCounts(1);
    demo.simulation_frame.structural_commands.addCount(0, 1);
    try demo.simulation_frame.structural_commands.prefix();
    var writer = demo.simulation_frame.structural_commands.rangeWriter(0);
    writer.write(.{ .create_entity = .{
        .movement_body = .{
            .position = .{ .x = 360, .y = 180 },
            .previous_position = .{ .x = 360, .y = 180 },
            .velocity = .{},
            .speed = 0,
        },
        .collision_bounds = .{ .size = .{ .x = 32, .y = 32 } },
        .collision_response = .{ .mode = .solid, .mobility = .static, .restitution = 0 },
    } });
    writer.finish();
    demo.simulation_frame.structural_commands.finishWrite();

    _ = try demo.applyStructuralCommandsAndPostCommitEvents(null);

    var nav_invalidations: usize = 0;
    for (demo.simulation_frame.events.mergedItems()) |event| {
        switch (event.payload) {
            .nav_region_invalidated => |nav| {
                nav_invalidations += 1;
                try std.testing.expectEqual(NavInvalidationReason.static_obstacle_changed, nav.reason);
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), nav_invalidations);
    try std.testing.expectEqual(@as(usize, 1), demo.simulation_frame.events.stats.nav_region_invalidated);
}

test "demo preflights navigation invalidation event before structural mutation" {
    var demo = try initDemoForTest(std.testing.allocator, 800, 450);
    defer demo.deinit();

    const entity_count_before = demo.data.movementBodySliceConst().entities.len;

    demo.simulation_frame.beginStep();
    demo.simulation_frame.events.setCapacityLimit(4);
    try demo.simulation_frame.structural_commands.prepareRangeCounts(1);
    demo.simulation_frame.structural_commands.addCount(0, 1);
    try demo.simulation_frame.structural_commands.prefix();
    var writer = demo.simulation_frame.structural_commands.rangeWriter(0);
    writer.write(.{ .create_entity = .{
        .movement_body = .{
            .position = .{ .x = 360, .y = 180 },
            .previous_position = .{ .x = 360, .y = 180 },
            .velocity = .{},
            .speed = 0,
        },
        .collision_bounds = .{ .size = .{ .x = 32, .y = 32 } },
        .collision_response = .{ .mode = .solid, .mobility = .static, .restitution = 0 },
    } });
    writer.finish();
    demo.simulation_frame.structural_commands.finishWrite();

    try std.testing.expectError(error.EventCapacityExceeded, demo.applyStructuralCommandsAndPostCommitEvents(null));
    try std.testing.expectEqual(entity_count_before, demo.data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 0), demo.simulation_frame.events.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 0), demo.simulation_frame.events.stats.total);
}

test "demo preflights same-batch static obstacle promotion before mutation" {
    var demo = try initDemoForTest(std.testing.allocator, 800, 450);
    defer demo.deinit();

    const entity = try demo.data.createEntity();
    try demo.data.setMovementBody(entity, .{
        .position = .{ .x = 360, .y = 180 },
        .previous_position = .{ .x = 360, .y = 180 },
        .velocity = .{},
        .speed = 0,
    });

    demo.simulation_frame.beginStep();
    demo.simulation_frame.events.setCapacityLimit(2);
    try demo.simulation_frame.structural_commands.prepareRangeCounts(1);
    demo.simulation_frame.structural_commands.addCount(0, 2);
    try demo.simulation_frame.structural_commands.prefix();
    var writer = demo.simulation_frame.structural_commands.rangeWriter(0);
    writer.write(.{ .set_collision_bounds = .{
        .entity = entity,
        .bounds = .{ .size = .{ .x = 32, .y = 32 } },
    } });
    writer.write(.{ .set_collision_response = .{
        .entity = entity,
        .response = .{ .mode = .solid, .mobility = .static, .restitution = 0 },
    } });
    writer.finish();
    demo.simulation_frame.structural_commands.finishWrite();

    try std.testing.expectError(error.EventCapacityExceeded, demo.applyStructuralCommandsAndPostCommitEvents(null));
    try std.testing.expect(demo.data.collisionBoundsConst(entity) == null);
    try std.testing.expect(demo.data.collisionResponseConst(entity) == null);
    try std.testing.expectEqual(@as(usize, 0), demo.simulation_frame.events.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 0), demo.simulation_frame.events.stats.total);
}

test "demo unrelated structural component change does not invalidate navigation" {
    var demo = try initDemoForTest(std.testing.allocator, 800, 450);
    defer demo.deinit();

    demo.simulation_frame.beginStep();
    try demo.simulation_frame.structural_commands.prepareRangeCounts(1);
    demo.simulation_frame.structural_commands.addCount(0, 1);
    try demo.simulation_frame.structural_commands.prefix();
    var writer = demo.simulation_frame.structural_commands.rangeWriter(0);
    writer.write(.{ .set_asset_reference = .{
        .entity = demo.player.entity,
        .asset_reference = .{ .sprite = .demo_tile },
    } });
    writer.finish();
    demo.simulation_frame.structural_commands.finishWrite();

    _ = try demo.applyStructuralCommandsAndPostCommitEvents(null);

    for (demo.simulation_frame.events.mergedItems()) |event| {
        switch (event.payload) {
            .nav_region_invalidated => return error.UnexpectedNavInvalidation,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 0), demo.simulation_frame.events.stats.nav_region_invalidated);
}

test "demo dynamic entity structural destruction does not invalidate navigation" {
    var demo = try initDemoForTest(std.testing.allocator, 800, 450);
    defer demo.deinit();

    const dynamic = try demo.data.createEntity();
    try demo.data.setMovementBody(dynamic, .{
        .position = .{ .x = 360, .y = 180 },
        .previous_position = .{ .x = 360, .y = 180 },
        .velocity = .{},
        .speed = 0,
    });
    try demo.data.setCollisionBounds(dynamic, .{ .size = .{ .x = 32, .y = 32 } });
    try demo.data.setCollisionResponse(dynamic, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });

    demo.simulation_frame.beginStep();
    try demo.simulation_frame.structural_commands.prepareRangeCounts(1);
    demo.simulation_frame.structural_commands.addCount(0, 1);
    try demo.simulation_frame.structural_commands.prefix();
    var writer = demo.simulation_frame.structural_commands.rangeWriter(0);
    writer.write(.{ .destroy_entity = dynamic });
    writer.finish();
    demo.simulation_frame.structural_commands.finishWrite();

    _ = try demo.applyStructuralCommandsAndPostCommitEvents(null);

    for (demo.simulation_frame.events.mergedItems()) |event| {
        switch (event.payload) {
            .nav_region_invalidated => return error.UnexpectedNavInvalidation,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 0), demo.simulation_frame.events.stats.nav_region_invalidated);
}
