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
const AiAgent = @import("data_system.zig").AiAgent;
const AiAffect = @import("data_system.zig").AiAffect;
const AiMemory = @import("data_system.zig").AiMemory;
const AiPerception = @import("data_system.zig").AiPerception;
const AssetReference = @import("data_system.zig").AssetReference;
const component_masks = @import("data_system.zig").component_masks;
const CollisionResponseMobility = @import("data_system.zig").CollisionResponseMobility;
const CollisionResponseMode = @import("data_system.zig").CollisionResponseMode;
const DataSystem = @import("data_system.zig").DataSystem;
const DigConfig = @import("dig_controller.zig").DigConfig;
const EntityId = @import("data_system.zig").EntityId;
const Faction = @import("data_system.zig").Faction;
const movement_range_alignment_items = @import("data_system.zig").movement_range_alignment_items;
const StructuralCommitStats = @import("data_system.zig").StructuralCommitStats;
const StructuralCommand = @import("data_system.zig").StructuralCommand;
const SteeringAgent = @import("data_system.zig").SteeringAgent;
const simulation_scope = @import("simulation_scope.zig");
const InputState = @import("../app/input.zig").InputState;
const Player = @import("player.zig").Player;
const ParticleSystem = @import("systems/particle.zig").ParticleSystem;
const NavUpdateStats = @import("systems/pathfinding.zig").NavUpdateStats;
const PathfindingCapacity = @import("systems/pathfinding.zig").PathfindingCapacity;
const autoSizedMaxNavMemoryBytes = @import("systems/pathfinding.zig").autoSizedMaxNavMemoryBytes;
const DigIntent = @import("simulation.zig").DigIntent;
const NavInvalidationReason = @import("simulation.zig").NavInvalidationReason;
const SimulationFrame = @import("simulation.zig").SimulationFrame;
const SimulationPhase = @import("simulation.zig").SimulationPhase;
const SimulationPipeline = @import("simulation_pipeline.zig").SimulationPipeline;
const CollisionSystem = @import("systems/collision.zig").CollisionSystem;
const estimateTriggerCapacity = @import("systems/collision_response.zig").estimateTriggerCapacity;
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

/// Smallest demo patch that still covers dig/nav tests (cells through 7x7).
const demo_test_viewport_width: f32 = 256;
const demo_test_viewport_height: f32 = 256;
// Default mover count for every path EXCEPT the real battle-scale procedural entry
// (initProceduralWithRuntimeAssets) — this is what initDemoForTest and every other test
// in this file spawn through, so it stays small on purpose (see coding-standards.md /
// CLAUDE.md's "keep test fixtures at the smallest size that still exercises the
// behavior under test"). A prior pass bumped this GLOBALLY to battle-scale to exercise
// the pathfinding group-field threshold live — that made every test in this file spawn
// 2048 movers too, taking `zig build test` from ~6s to ~43s. Population is now a
// runtime parameter (see DemoPopulationCapacity/deriveDemoPopulationCapacity) so the
// battle-scale exercise and fast tests don't have to share one global constant.
const default_demo_mover_count: usize = 32;
// Only initProceduralWithRuntimeAssets (the real game, not tests) passes this.
const battle_scale_demo_mover_count: usize = 2048;
const obstacle_count = 4;

/// Every mover-count-dependent capacity this demo needs, derived from a single runtime
/// population — mirrors pathfinding's own `deriveCapacity(base, agent_count)` pattern
/// (one source value, everything else computed from it) rather than a scattered set of
/// independent constants that can drift out of sync with each other or with whichever
/// mover count a given init path actually uses.
const DemoPopulationCapacity = struct {
    mover_count: usize,
    surface_movers: usize,
    underground_movers: usize,
    contact_capacity: usize,
    intent_capacity: usize,
    collision_trigger_capacity: usize,
    structural_reserve: usize,
    event_reserve: usize,
    perception_event_reserve: usize,
    affect_event_reserve: usize,
};

/// `demoArchetypeForIndex`'s fixed 8-slot cycle carries exactly 3 "full
/// cognition" archetypes (timid/aggressive/curious -- the only ones that
/// attach `AiPerception` + `AiAffect`; cohere reads the shared spatial index
/// directly and needs neither). Rounds `mover_count` up to a whole cycle so
/// this stays a safe upper bound for any population, not an exact count tied
/// to one remainder.
fn demoCognitionAgentCount(mover_count: usize) usize {
    const whole_cycles = (mover_count + demo_archetype_cycle_len - 1) / demo_archetype_cycle_len;
    return whole_cycles * demo_cognition_archetypes_per_cycle;
}

fn deriveDemoPopulationCapacity(mover_count: usize) DemoPopulationCapacity {
    // Matches the historical 24/32 == 0.75 surface/total split.
    const surface_movers = mover_count * 3 / 4;
    const underground_movers = mover_count - surface_movers;
    // Owned by CollisionSystem (this demo has no independent opinion on worst-case
    // simultaneous contacts for N bodies — that's collision's own domain knowledge, not
    // a ratio to guess here). A contact-stream overflow is a graceful, counted drop
    // (RangeOutputStream.stats.dropped), not a crash, so an approximation is fine.
    const contact_capacity = CollisionSystem.estimateContactCapacity(mover_count + obstacle_count + 1);
    // Every steering agent emits one navigation intent per step unconditionally (unlike
    // path REQUESTS, which are sparse/event-driven) — this must cover the full
    // population, not an independent guess.
    const intent_capacity = mover_count + obstacle_count + 1;
    // Owned by collision_response (a trigger event requires an underlying contact, so
    // trigger count is bounded by contact count — collision_response's own domain
    // knowledge, not a second independent ratio for this demo to guess).
    const collision_trigger_capacity = estimateTriggerCapacity(contact_capacity);
    const structural_reserve = mover_count + 16;
    // Per-step `frame.events` capacity_limit. Every plane-traversal fall/mining event and
    // every structural-commit event shares this one budget for the step (cleared only at
    // `beginStep`), so it must cover the worst case of all of them landing in the same
    // step, not just the largest single source: `applyNpcPlaneTraversal` walks every AI
    // agent and can emit up to `mover_count` fall events, plus the player's own
    // plane-traversal fall (1) and dig-mining event (1), plus up to `structural_reserve`
    // structural-commit events (tier changes / create / destroy), plus the post-commit
    // nav-invalidation headroom (1) already tracked separately by
    // `applyStructuralCommandsAndPostCommitEvents`. Plus perception's
    // `entity_perceived`/`entity_lost` pair (at most 2 per cognition agent per step: an
    // identity swap emits both) and affect's `affect_threshold_crossed` (at most 1 per
    // drive per step, 4 drives, per cognition agent) for the `demoArchetypeForIndex`
    // subset that now carries `AiPerception`/`AiAffect` — see
    // `demoCognitionAgentCount`/`perception_max_events_per_step`/
    // `affect_max_events_per_step` below.
    const cognition_agents = demoCognitionAgentCount(mover_count);
    const perception_event_reserve = cognition_agents * 2;
    const affect_event_reserve = cognition_agents * 4;
    const event_reserve = mover_count + 1 + 1 + structural_reserve + 1 + perception_event_reserve + affect_event_reserve;
    return .{
        .mover_count = mover_count,
        .surface_movers = surface_movers,
        .underground_movers = underground_movers,
        .contact_capacity = contact_capacity,
        .intent_capacity = intent_capacity,
        .collision_trigger_capacity = collision_trigger_capacity,
        .structural_reserve = structural_reserve,
        .event_reserve = event_reserve,
        .perception_event_reserve = perception_event_reserve,
        .affect_event_reserve = affect_event_reserve,
    };
}

/// Per-step audio bound for demo tests: movers can emit collision SFX alongside
/// ambient music, listener, and the player jet loop. Not scaled 1:1 with mover count —
/// concurrent AUDIBLE sounds have a natural ceiling far below the mover count, so this
/// stays a fixed, generous-but-bounded budget.
const demo_test_audio_capacity = 256;
const procedural_world_width_tiles: u16 = 256;
const procedural_world_height_tiles: u16 = 256;
/// Surface + underground dense floors for the procedural 32-level mine (runtime load).
/// Unit tests use `initDemoForTest` / `initDemoFromMetaWithUnderground` (3 levels), not this config.
const procedural_underground_count: u16 = 31; //31
const procedural_dense_layer_count: usize = 1 + procedural_underground_count;
/// Procedural worlds author one `.floor` dense band per level (no obstacle stack per plane).
const procedural_max_dense_bands_per_level: u8 = 1;
/// Dense floors below `active_level` kept in the render window. Draw/fragment
/// cost is proportional to actual interleave points this frame (normally 1),
/// not window depth, so the full authored underground stack fits:
/// `1 + procedural_render_window_levels_below == procedural_dense_layer_count`,
/// exactly filling `k_max_dense_submit_stack_cap`.
const procedural_render_window_levels_below: u16 = procedural_underground_count;
comptime {
    std.debug.assert(procedural_dense_layer_count <= world_system.k_max_dense_submit_stack_cap);
    const submit_layers = @as(usize, 1 + procedural_render_window_levels_below) * procedural_max_dense_bands_per_level;
    std.debug.assert(submit_layers <= world_system.k_max_dense_submit_stack_cap);
}
/// `estimateDenseTileGpuBytes` ceiling: dense_layer_count * width * height * @sizeOf(u32).
const procedural_max_dense_tile_gpu_bytes: usize =
    procedural_dense_layer_count *
    @as(usize, procedural_world_width_tiles) *
    @as(usize, procedural_world_height_tiles) *
    @sizeOf(u32);
pub const default_world_build_config = world_system.WorldBuildConfig{
    .width_tiles = procedural_world_width_tiles,
    .height_tiles = procedural_world_height_tiles,
    .chunk_size_tiles = 16,
    .underground_level_count = procedural_underground_count,
    .max_dense_bands_per_level = procedural_max_dense_bands_per_level,
    .max_dense_tile_gpu_bytes = procedural_max_dense_tile_gpu_bytes,
    .render_window = .{ .levels_below = procedural_render_window_levels_below },
};

fn proceduralPathfindingCapacity(worker_participant_count: usize, level_link_count: usize) PathfindingCapacity {
    var cap: PathfindingCapacity = .{
        .max_group_fields = 4,
        .max_agent_budget = 4096,
        .worker_participant_count = worker_participant_count,
        // MEASURED, not assumed (a live perf capture on this exact demo, after the
        // portal-consolidation and group-field hardening fixes below were both already
        // in place, over one 60-SECOND window): at population/threshold=8, the shared
        // flow-field built ~115 times across those 60 seconds (group_fields_built ==
        // accepted_requests, roughly one new build every 0.5s) but was NEVER actually
        // sampled even once (group_field_samples == 0 across every single one of those
        // builds) — 100% build cost, 0% payoff, for the whole window. Why: this demo's
        // AI issues path requests only when an agent's CURRENT path is missing/invalid
        // (event-driven, not a continuous per-step re-request), targeting one
        // hysteresis-throttled shared broadcast goal. When that goal changes (roughly
        // every 0.5s here), the resulting burst of requests is served by ONE real solve
        // — every other requester in the burst dedups against that single IN-FLIGHT
        // request (PathfindingSystem's pending_keys set) or, failing that, the
        // goal-keyed result cache (default_cache_ttl_steps, far longer than this goal's
        // own ~0.5s rekey cadence) — for FREE, before the shared field ever finishes
        // building. This holds regardless of population size: pending-dedup absorbs the
        // whole burst off one solve no matter how many agents share it, so a bigger
        // crowd doesn't change the math. A shared flood only earns its cost when
        // SIMULTANEOUS demand within one burst exceeds what a single dedup'd solve can
        // serve — i.e. genuine mass-combat scale. 2000 sits comfortably above any
        // population this demo produces while staying a real, considered ceiling (not
        // "disabled") for when a battle-scale crowd feature exists; revisit with a fresh
        // measurement, not a guess, once that feature is built.
        .min_group_field_agents = 2000,
        // group_field_rebuild_min_steps is intentionally left at its default: the safe
        // value is an internal relationship between group_field_build_budget and this
        // throttle (both pathfinding-owned), not a demo-specific judgment call — see
        // default_group_field_rebuild_min_steps' doc comment.
    };
    cap.max_nav_memory_bytes = autoSizedMaxNavMemoryBytes(cap, procedural_dense_layer_count, procedural_world_width_tiles, procedural_world_height_tiles, level_link_count);
    return cap;
}
/// Chunk + pixel AABB margin for dynamic collect and sparse visibility (Slice 24B).
const world_render_overscan_chunks: u16 = 1;

const StageTimer = runtime_perf_log.StageTimer;

pub const GameDemoState = struct {
    // Owns test_squares; freed via this field in deinit (not data.allocator, a
    // substructure's allocator that need not match).
    allocator: std.mem.Allocator,
    data: DataSystem,
    simulation_frame: SimulationFrame,
    pipeline: SimulationPipeline,
    world: WorldSystem,
    player: Player,
    particles: ParticleSystem,
    scene_prep: render_prep.DynamicScenePrep,
    // Owned, allocator-backed: mover count is a runtime parameter (see
    // DemoPopulationCapacity), not a comptime constant, so this can't be a fixed array.
    test_squares: []EntityId,
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
            null,
            null,
            default_demo_mover_count,
        );
        errdefer state.deinit();
        try state.validateAtlasReferences(runtime_assets);
        return state;
    }

    pub fn initProceduralWithRuntimeAssets(
        allocator: std.mem.Allocator,
        runtime_assets: *const RuntimeAssets,
        world_build_config: world_system.WorldBuildConfig,
        thread_system: *ThreadSystem,
        viewport_width: f32,
        viewport_height: f32,
    ) !GameDemoState {
        const world = try WorldSystem.initProcedural(
            allocator,
            runtime_assets,
            world_build_config,
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
            proceduralPathfindingCapacity(thread_system.participantSlotCount(), world.levelLinks().len),
            thread_system,
            battle_scale_demo_mover_count,
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
        pathfinding_override: ?PathfindingCapacity,
        nav_build_thread_system: ?*ThreadSystem,
        mover_count: usize,
    ) !GameDemoState {
        const pop_cap = deriveDemoPopulationCapacity(mover_count);
        var world = world_value;
        errdefer world.deinit();
        var data = DataSystem.init(allocator);
        errdefer data.deinit();
        const player = try Player.spawn(&data);
        try data.setCollisionBounds(player.entity, .{ .size = .{ .x = 32, .y = 32 } });
        try data.setCollisionResponse(player.entity, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
        // Player starts on the surface plane (level 0); sync render z to that plane.
        const player_body = data.movementBodyPtr(player.entity).?;
        player_body.snapZ(world.levelBaseZ(0));
        if (worldUsesCompactDemoSpawn(&world)) {
            const start_x: f32 = 40;
            const start_y: f32 = world.worldHeightPixels() * 0.5 - 16;
            player_body.position_x.* = start_x;
            player_body.position_y.* = start_y;
            player_body.previous_x.* = start_x;
            player_body.previous_y.* = start_y;
        }
        const world_width = simulation_bounds_width;
        const world_height = simulation_bounds_height;
        const test_squares = try spawnTestSquares(allocator, &data, &world, dig_config.tunnel_tile, pop_cap);
        errdefer allocator.free(test_squares);
        const obstacles = try spawnObstacles(&data, &world);
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
        // allocation-free on churn frames. The event-capacity arg (`pop_cap.event_reserve`)
        // covers every source that shares that one per-step budget; see
        // DemoPopulationCapacity's doc comment. The range_count arg (first) is shared
        // across every one of these streams and each `appendRequired`-style call
        // consumes one range, so it must cover the largest per-step range consumer —
        // events (`pop_cap.event_reserve`), not a flat constant unrelated to that budget.
        try simulation_frame.reserveStreams(pop_cap.event_reserve, pop_cap.event_reserve, pop_cap.intent_capacity, pop_cap.contact_capacity, pop_cap.collision_trigger_capacity, pop_cap.structural_reserve);
        try simulation_frame.reservePathRequests(16, pop_cap.mover_count);
        var pipeline = try SimulationPipeline.init(allocator, &data, world_width, world_height, .{
            .steering_agent_capacity = pop_cap.mover_count,
            .static_obstacle_capacity = obstacle_count,
            .contact_capacity = pop_cap.contact_capacity,
            .movement_body_capacity = pop_cap.mover_count + obstacle_count + 1,
            // 512x512 tiles at a 32px nav cell = one nav cell per tile, full
            // resolution.
            .nav_cell_size = 32,
            // Elastic pathfinding capacity tracks the live steering-agent crowd:
            // the per-step request/cache caps and the group-field threshold derive
            // from the agent count automatically. Only the hard ceiling is fixed, so
            // a battle grows and quiets shrinks without bumping knobs. At this demo's
            // small scale capacity settles low and the group path stays dormant.
            .pathfinding = pathfinding_override orelse .{
                .max_group_fields = 4,
                .max_agent_budget = 4096,
                // Configured threaded participant count; A* scratch is sized for it in
                // the nav build so the first threaded solve does no lazy allocation.
                .worker_participant_count = worker_participant_count,
            },
            .navigation_world = &world,
            .nav_build_thread_system = nav_build_thread_system,
            .dig = dig_config,
            // The `demoArchetypeForIndex` cognition subset (timid/aggressive/curious)
            // carries `AiPerception`; sized against `pop_cap.event_reserve`'s own
            // `perception_event_reserve` term (see `demoCognitionAgentCount`).
            .perception_max_events_per_step = pop_cap.perception_event_reserve,
            // Same cognition subset also carries `AiAffect`; sized against
            // `pop_cap.event_reserve`'s `affect_event_reserve` term.
            .affect_max_events_per_step = pop_cap.affect_event_reserve,
        });
        errdefer pipeline.deinit();

        var state = GameDemoState{
            .allocator = allocator,
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
        self.allocator.free(self.test_squares);
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
            pipeline_stats.recordTo(context.perf);
            particle_stats.recordTo(context.perf);
            structural_stats.recordTo(context.perf);
            self.simulation_frame.events.stats.recordTo(context.perf);
            self.last_nav_update_stats.recordTo(context.perf);
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
        try self.pipeline.reactToPostCommitPerceptionEvents(&self.simulation_frame, &self.world);
        try render_prep.ensureScenePrepCapacity(&self.scene_prep, self.gameplayScene());
        return stats;
    }

    fn validateAtlasReferences(self: *const GameDemoState, runtime_assets: *const RuntimeAssets) !void {
        try render_prep.validateAtlasReferences(&self.data, runtime_assets);
    }
};

const SpawnCellCoord = struct { x: u16, y: u16 };

const DemoSpawnSpec = struct {
    position: math.Vec2,
    velocity: math.Vec2,
    size: math.Vec2,
    color: config.Color,
    depth: WorldDepth,
    world_level: u16 = 0,
    use_template: bool = false,
    speed: f32 = 42,
    behavior: ?AiAgent = null,
    perception: ?AiPerception = null,
    memory: ?AiMemory = null,
    affect: ?AiAffect = null,
    faction: Faction = .hostile,
};

fn worldUsesCompactDemoSpawn(world: *const WorldSystem) bool {
    return world.width <= 16 and world.height <= 16;
}

fn spawnTestSquares(allocator: std.mem.Allocator, data: *DataSystem, world: *WorldSystem, tunnel_tile: world_system.TileId, pop_cap: DemoPopulationCapacity) ![]EntityId {
    if (worldUsesCompactDemoSpawn(world)) return spawnTestSquaresCompact(allocator, data, world, pop_cap);
    const entities = try allocator.alloc(EntityId, pop_cap.mover_count);
    errdefer allocator.free(entities);
    // Wraps naturally (col = index % cols, row = index / cols) rather than requiring an
    // exact cols*rows == surface_movers factorization, so this works for any runtime
    // population instead of only counts with a clean integer factorization.
    const cols: usize = 48;

    var index: usize = 0;
    while (index < pop_cap.surface_movers) : (index += 1) {
        const col = index % cols;
        const row = index / cols;
        const size: math.Vec2 = .{ .x = 20 + @as(f32, @floatFromInt(index % 3)) * 2, .y = 20 + @as(f32, @floatFromInt((index + 1) % 3)) * 2 };
        const archetype = demoArchetypeForIndex(index);
        const spec = DemoSpawnSpec{
            .position = .{
                .x = 96 + @as(f32, @floatFromInt(col)) * 96,
                .y = 96 + @as(f32, @floatFromInt(row)) * 88,
            },
            .velocity = demoVelocityForIndex(index),
            .size = size,
            .color = demoColorForIndex(index),
            .depth = .actor,
            .use_template = index == 3 or index == 7,
            .speed = if (index % 5 == 0) 0 else 42,
            .behavior = archetype.behavior,
            .perception = archetype.perception,
            .memory = archetype.memory,
            .affect = archetype.affect,
            .faction = archetype.faction,
        };
        entities[index] = try spawnDemoMover(data, world, spec, index);
    }

    const underground_enabled = world.width >= 128 and world.height >= 128;

    while (index < pop_cap.mover_count) : (index += 1) {
        const underground_index = index - pop_cap.surface_movers;
        const tile = world.tile_size;
        const size: math.Vec2 = .{ .x = 22, .y = 22 };
        const archetype = demoArchetypeForIndex(index);
        const spec = if (underground_enabled) blk: {
            const level = undergroundSpawnLevelForIndex(world, underground_index, pop_cap.underground_movers);
            const cell = undergroundSpawnCellForIndex(underground_index);
            try carveUndergroundSpawnPocket(world, tunnel_tile, level, cell);
            break :blk DemoSpawnSpec{
                .position = .{
                    .x = @as(f32, @floatFromInt(cell.x)) * tile,
                    .y = @as(f32, @floatFromInt(cell.y)) * tile,
                },
                .velocity = .{ .x = 0, .y = 0 },
                .size = size,
                .color = demoColorForIndex(index),
                .depth = .actor,
                .world_level = level,
                .speed = 48,
                .behavior = archetype.behavior,
                .perception = archetype.perception,
                .memory = archetype.memory,
                .affect = archetype.affect,
                .faction = archetype.faction,
            };
        } else blk: {
            const extra_col = underground_index % 4;
            const extra_row = underground_index / 4;
            break :blk DemoSpawnSpec{
                .position = .{
                    .x = 520 + @as(f32, @floatFromInt(extra_col)) * 72,
                    .y = 120 + @as(f32, @floatFromInt(extra_row)) * 72,
                },
                .velocity = demoVelocityForIndex(index),
                .size = size,
                .color = demoColorForIndex(index),
                .depth = .actor,
                .speed = 44,
                .behavior = archetype.behavior,
                .perception = archetype.perception,
                .memory = archetype.memory,
                .affect = archetype.affect,
                .faction = archetype.faction,
            };
        };
        entities[index] = try spawnDemoMover(data, world, spec, index);
    }
    return entities;
}

fn spawnTestSquaresCompact(allocator: std.mem.Allocator, data: *DataSystem, world: *WorldSystem, pop_cap: DemoPopulationCapacity) ![]EntityId {
    const entities = try allocator.alloc(EntityId, pop_cap.mover_count);
    errdefer allocator.free(entities);
    const cols: usize = 6;
    const surface_rows: usize = 4;
    const margin: f32 = 12;
    const entity_extent: f32 = 22;
    const world_w = world.worldWidthPixels();
    const world_h = world.worldHeightPixels();
    const span_x = @max(world_w - 2 * margin - entity_extent, 0);
    const span_y = @max(world_h * 0.45 - margin - entity_extent, 0);
    const step_x = if (cols > 1) span_x / @as(f32, @floatFromInt(cols - 1)) else 0;
    const step_y = if (surface_rows > 1) span_y / @as(f32, @floatFromInt(surface_rows - 1)) else 0;

    for (0..pop_cap.surface_movers) |index| {
        const col = index % cols;
        const row = index / cols;
        const size: math.Vec2 = .{ .x = 20 + @as(f32, @floatFromInt(index % 3)) * 2, .y = 20 + @as(f32, @floatFromInt((index + 1) % 3)) * 2 };
        const archetype = demoArchetypeForIndex(index);
        const spec = DemoSpawnSpec{
            .position = .{
                .x = margin + @as(f32, @floatFromInt(col)) * step_x,
                .y = margin + @as(f32, @floatFromInt(row)) * step_y,
            },
            .velocity = demoVelocityForIndex(index),
            .size = size,
            .color = demoColorForIndex(index),
            .depth = .actor,
            .use_template = index == 3 or index == 7,
            .speed = if (index % 5 == 0) 0 else 42,
            .behavior = archetype.behavior,
            .perception = archetype.perception,
            .memory = archetype.memory,
            .affect = archetype.affect,
            .faction = archetype.faction,
        };
        entities[index] = try spawnDemoMover(data, world, spec, index);
    }

    const underground_cols: usize = 4;
    const underground_rows: usize = 2;
    const underground_origin_y = world_h * 0.55;
    const underground_span_x = @max(world_w - 2 * margin - entity_extent, 0);
    const underground_span_y = @max(world_h - underground_origin_y - margin - entity_extent, 0);
    const underground_step_x = if (underground_cols > 1) underground_span_x / @as(f32, @floatFromInt(underground_cols - 1)) else 0;
    const underground_step_y = if (underground_rows > 1) underground_span_y / @as(f32, @floatFromInt(underground_rows - 1)) else 0;

    for (0..pop_cap.underground_movers) |underground_index| {
        const index = pop_cap.surface_movers + underground_index;
        const col = underground_index % underground_cols;
        const row = underground_index / underground_cols;
        const archetype = demoArchetypeForIndex(index);
        const spec = DemoSpawnSpec{
            .position = .{
                .x = margin + @as(f32, @floatFromInt(col)) * underground_step_x,
                .y = underground_origin_y + @as(f32, @floatFromInt(row)) * underground_step_y,
            },
            .velocity = demoVelocityForIndex(index),
            .size = .{ .x = 22, .y = 22 },
            .color = demoColorForIndex(index),
            .depth = .actor,
            .speed = 44,
            .behavior = archetype.behavior,
            .perception = archetype.perception,
            .memory = archetype.memory,
            .affect = archetype.affect,
            .faction = archetype.faction,
        };
        entities[index] = try spawnDemoMover(data, world, spec, index);
    }
    return entities;
}

/// Spreads demo underground movers across planes `1..max_underground`, not the legacy 1–3 stack.
fn undergroundSpawnLevelForIndex(world: *const WorldSystem, underground_index: usize, underground_movers: usize) u16 {
    const max_underground: usize = if (world.levelCount() > 1) world.levelCount() - 1 else 0;
    if (max_underground == 0) return 0;
    const slot = (underground_index * max_underground + (underground_movers - 1)) / underground_movers;
    return @intCast(1 + @min(slot, max_underground - 1));
}

const underground_spawn_cols: usize = 32;

/// Procedural replacement for a hand-picked coordinate list (infeasible past a handful of
/// movers): a simple grid starting at (40,40), stepping 4 tiles per column/row, comfortably
/// inside any world this demo builds (procedural_world_width/height_tiles == 256). `row =
/// underground_index / underground_spawn_cols` is unbounded (grows with index), so every
/// index gets a distinct cell regardless of total population — no exact cols*rows
/// factorization required.
fn undergroundSpawnCellForIndex(underground_index: usize) SpawnCellCoord {
    const col = underground_index % underground_spawn_cols;
    const row = underground_index / underground_spawn_cols;
    return .{ .x = @intCast(40 + col * 4), .y = @intCast(40 + row * 4) };
}

fn carveUndergroundSpawnPocket(world: *WorldSystem, tunnel_tile: world_system.TileId, level: u16, cell: SpawnCellCoord) !void {
    const floor_layer = world.denseFloorLayerForLevel(level) orelse return error.InvalidWorldLevel;
    _ = try world.setDenseTile(floor_layer, cell.x, cell.y, tunnel_tile);
}

fn spawnDemoMover(data: *DataSystem, world: *WorldSystem, spec: DemoSpawnSpec, index: usize) !EntityId {
    const entity = if (spec.use_template) blk: {
        _ = try data.applyStructuralCommands(&[_]StructuralCommand{.{
            .create_entity = .{
                .movement_body = .{
                    .position = spec.position,
                    .previous_position = spec.position,
                    .velocity = spec.velocity,
                    .speed = spec.speed,
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
                .world_level = spec.world_level,
                .ai_agent = spec.behavior orelse .{ .active_behavior = .pursue, .wander_amplitude = 6, .gain_pursue = 1.35 },
                .ai_perception = spec.perception,
                .ai_memory = spec.memory,
                .ai_affect = spec.affect,
                .steering_agent = demoSteeringAgent(spec.size),
                .faction = spec.faction,
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
            .speed = spec.speed,
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
        try data.setWorldLevel(e, spec.world_level);
        try data.setFaction(e, spec.faction);
        if (spec.behavior) |behavior| {
            try data.setAiAgent(e, behavior);
            try data.setSteeringAgent(e, demoSteeringAgent(spec.size));
        }
        if (spec.perception) |perception| try data.setAiPerception(e, perception);
        if (spec.memory) |memory| try data.setAiMemory(e, memory);
        if (spec.affect) |affect| try data.setAiAffect(e, affect);
        break :blk e;
    };

    const z = world.levelBaseZ(spec.world_level);
    const body = data.movementBodyPtr(entity).?;
    body.position_z.* = z;
    body.previous_z.* = z;
    try data.setSimulationMetadata(entity, .{
        .tier = .cognition,
        .chunk = world.chunkCoordForWorldPos(spec.position.x, spec.position.y),
        .level = spec.world_level,
    });
    return entity;
}

fn demoVelocityForIndex(index: usize) math.Vec2 {
    const table = [_]math.Vec2{
        .{ .x = 20, .y = 5 },  .{ .x = 5, .y = 18 },  .{ .x = -14, .y = 9 }, .{ .x = 11, .y = -10 },
        .{ .x = 8, .y = -16 }, .{ .x = -9, .y = 12 }, .{ .x = 15, .y = -7 }, .{ .x = -6, .y = 22 },
    };
    return table[index % table.len];
}

fn demoColorForIndex(index: usize) config.Color {
    const hue = @as(f32, @floatFromInt(index % 8)) / 8.0;
    return .{ .r = 0.35 + hue * 0.5, .g = 0.45 + (1 - hue) * 0.4, .b = 0.55 + hue * 0.35, .a = 1.0 };
}

/// Full component bundle for one demo mover's personality. `behavior == null`
/// means no `AiAgent` at all (a pure physics/collision body); `perception`/
/// `memory`/`affect` are independently optional so an entity can carry
/// `AiAgent` without full cognition (arbitration treats an absent component
/// as zero signal, per `arbitration.zig`).
const DemoArchetype = struct {
    behavior: ?AiAgent,
    perception: ?AiPerception = null,
    memory: ?AiMemory = null,
    affect: ?AiAffect = null,
    faction: Faction = .hostile,
};

/// Length of `demoArchetypeForIndex`'s fixed personality cycle.
const demo_archetype_cycle_len: usize = 8;
/// Count of cycle slots that attach `AiPerception` + `AiAffect` (timid,
/// aggressive, curious) — kept in sync with the switch below by
/// `demoCognitionAgentCount`'s doc comment; update both together.
const demo_cognition_archetypes_per_cycle: usize = 3;

/// Hardcoded personality archetypes for the demo (full data-driven archetype
/// JSON is Slice 33). A subset of demo movers gets full cognition
/// (`AiPerception` + `AiMemory` + `AiAffect`) with a distinct emotion
/// baseline and gain profile each:
///
/// - `timid` (index 3, `.ally` faction): high `baseline_fear` / `gain_flee`.
///   `.ally` faction makes the `.hostile`-faction majority (including
///   `aggressive`) a genuine perceived threat, so fear/flee has a real
///   non-player source, not just the demo `focus_target` fallback.
/// - `aggressive` (index 4): high `baseline_aggression` / `gain_pursue`.
///   Perceives `timid`'s `.ally` faction as hostile, so it can chase a
///   non-player target purely from perception.
/// - `curious` (index 5): high `baseline_curiosity` / `gain_investigate`,
///   reacts to heard dig stimuli.
/// - `cohesive` (index 6): high `gain_cohere` only -- cohere's goal comes
///   from the shared spatial index (`ai.zig`'s neighbor-mean gather), not
///   perception/memory/affect, so no cognition components are needed.
///
/// The remaining slots keep pre-arbitration-style contrast groups: a
/// wander-only `AiAgent` with zero pursue gain (index 0), two
/// `focus_target`-fallback pursuers with no cognition components (indices 1
/// and 7) that only ever reach the player through arbitration's documented
/// last-resort fallback, and a pure wanderer with no `AiAgent` at all (index
/// 2). Indices 0/1 intentionally keep a real `AiAgent` (never `null`): a
/// handful of tests pin `test_squares[0]`/`[1]`/`[3]` as "the AI squares".
fn demoArchetypeForIndex(index: usize) DemoArchetype {
    return switch (index % demo_archetype_cycle_len) {
        0 => .{ .behavior = .{ .active_behavior = .wander, .wander_amplitude = 58, .gain_pursue = 0 } },
        1 => .{ .behavior = .{ .active_behavior = .pursue, .wander_amplitude = 4, .gain_pursue = 1.2 } },
        2 => .{ .behavior = null },
        3 => .{
            .behavior = .{ .active_behavior = .wander, .wander_amplitude = 20, .gain_flee = 2.0, .gain_pursue = 0 },
            .perception = .{},
            .memory = .{},
            .affect = .{ .baseline_fear = 0.65 },
            .faction = .ally,
        },
        4 => .{
            .behavior = .{ .active_behavior = .pursue, .wander_amplitude = 6, .gain_pursue = 2.0 },
            .perception = .{},
            .memory = .{},
            .affect = .{ .baseline_aggression = 0.65 },
        },
        5 => .{
            .behavior = .{ .active_behavior = .wander, .wander_amplitude = 15, .gain_investigate = 2.0 },
            .perception = .{},
            .memory = .{},
            .affect = .{ .baseline_curiosity = 0.65 },
        },
        6 => .{ .behavior = .{ .active_behavior = .wander, .wander_amplitude = 10, .gain_cohere = 2.0 } },
        else => .{ .behavior = .{ .active_behavior = .pursue, .wander_amplitude = 7, .gain_pursue = 1.55 } },
    };
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

fn spawnObstacles(data: *DataSystem, world: *const WorldSystem) ![obstacle_count]EntityId {
    if (worldUsesCompactDemoSpawn(world)) return spawnObstaclesCompact(data);
    const specs = [_]ObstacleSpec{
        .{ .position = .{ .x = 462, .y = 215 }, .size = .{ .x = 72, .y = 48 }, .color = .{ .r = 0.2, .g = 0.28, .b = 0.34, .a = 1.0 } },
        .{ .position = .{ .x = 245, .y = 285 }, .size = .{ .x = 96, .y = 28 }, .color = .{ .r = 0.26, .g = 0.34, .b = 0.36, .a = 1.0 } },
        .{ .position = .{ .x = 720, .y = 360 }, .size = .{ .x = 64, .y = 40 }, .color = .{ .r = 0.22, .g = 0.3, .b = 0.32, .a = 1.0 } },
        .{ .position = .{ .x = 380, .y = 480 }, .size = .{ .x = 80, .y = 32 }, .color = .{ .r = 0.24, .g = 0.32, .b = 0.35, .a = 1.0 } },
    };
    comptime std.debug.assert(specs.len == obstacle_count);
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

fn spawnObstaclesCompact(data: *DataSystem) ![obstacle_count]EntityId {
    const specs = [_]ObstacleSpec{
        .{ .position = .{ .x = 160, .y = 100 }, .size = .{ .x = 48, .y = 32 }, .color = .{ .r = 0.2, .g = 0.28, .b = 0.34, .a = 1.0 } },
        .{ .position = .{ .x = 40, .y = 168 }, .size = .{ .x = 56, .y = 24 }, .color = .{ .r = 0.26, .g = 0.34, .b = 0.36, .a = 1.0 } },
        .{ .position = .{ .x = 108, .y = 196 }, .size = .{ .x = 40, .y = 28 }, .color = .{ .r = 0.22, .g = 0.3, .b = 0.32, .a = 1.0 } },
        .{ .position = .{ .x = 188, .y = 36 }, .size = .{ .x = 44, .y = 24 }, .color = .{ .r = 0.24, .g = 0.32, .b = 0.35, .a = 1.0 } },
    };
    comptime std.debug.assert(specs.len == obstacle_count);
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

const ObstacleSpec = struct {
    position: math.Vec2,
    size: math.Vec2,
    color: config.Color,
};

fn runtimeAssetsWithWorldTexture() !RuntimeAssets {
    var runtime_assets = RuntimeAssets.init(std.testing.allocator);
    setSpriteAvailableForTest(&runtime_assets, .world_tileset, try TextureId.init(1, 1));
    return runtime_assets;
}

fn runtimeAssetsWithWorldMetadataForTest() !RuntimeAssets {
    var runtime_assets = try runtimeAssetsWithWorldTexture();
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

fn initDemoForTest(allocator: std.mem.Allocator) !GameDemoState {
    const asset_store = AssetStore.init(allocator, std.testing.io, "assets");
    const meta = try world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    var world = try WorldSystem.initDemoFromMetaWithUnderground(allocator, &meta, demo_test_viewport_width, demo_test_viewport_height);
    world.adoptTilesetMeta(meta);
    const dig_config = try DigConfig.fromMeta(world.tilesetMeta().?);
    return try GameDemoState.initWithWorld(
        allocator,
        demo_test_viewport_width,
        demo_test_viewport_height,
        demo_test_viewport_width,
        demo_test_viewport_height,
        world,
        dig_config,
        1,
        null,
        null,
        default_demo_mover_count,
    );
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

fn ambientAudioCommandCount(audio: *const AudioCommandBuffer) usize {
    var count: usize = 0;
    for (audio.items()) |command| {
        switch (command) {
            .play_sfx => {},
            else => count += 1,
        }
    }
    return count;
}

fn isolateDemoBodiesAwayFrom(demo: *GameDemoState, subject: EntityId) void {
    const isolate_x: f32 = demo.bounds_width + 64;
    const isolate_y: f32 = demo.bounds_height + 64;
    for (demo.test_squares) |entity| {
        if (entity.index == subject.index and entity.generation == subject.generation) continue;
        const body = demo.data.movementBodyPtr(entity).?;
        body.position_x.* = isolate_x;
        body.position_y.* = isolate_y;
        body.previous_x.* = isolate_x;
        body.previous_y.* = isolate_y;
        body.velocity_x.* = 0;
        body.velocity_y.* = 0;
    }
    for (demo.obstacles) |entity| {
        const body = demo.data.movementBodyPtr(entity).?;
        body.position_x.* = isolate_x;
        body.position_y.* = isolate_y;
        body.previous_x.* = isolate_x;
        body.previous_y.* = isolate_y;
        body.velocity_x.* = 0;
        body.velocity_y.* = 0;
    }
    const player_body = demo.data.movementBodyPtr(demo.player.entity).?;
    player_body.position_x.* = isolate_x;
    player_body.position_y.* = isolate_y;
    player_body.previous_x.* = isolate_x;
    player_body.previous_y.* = isolate_y;
    player_body.velocity_x.* = 0;
    player_body.velocity_y.* = 0;
}

test "GameDemoState owns test_squares via its own allocator field, not DataSystem's" {
    var demo = try initDemoForTest(std.testing.allocator);
    defer demo.deinit();

    // deinit frees test_squares via self.allocator, set at init from the same
    // parameter spawnTestSquares used -- not inherited from data.allocator, a
    // substructure field that could diverge from it.
    try std.testing.expectEqual(std.testing.allocator.ptr, demo.allocator.ptr);
    try std.testing.expectEqual(std.testing.allocator.vtable, demo.allocator.vtable);
}

test "proceduralPathfindingCapacity reserves the shared flow-field for a future battle-scale crowd" {
    const capacity = proceduralPathfindingCapacity(1, 0);
    // Pinned so high the demo's pursuit pack can never cross it: a live capture measured
    // the shared flood building constantly but never once being sampled at this demo's
    // scale — pending-request dedup and the goal-keyed result cache already serve every
    // requester in a goal-change burst off one solve, for free, regardless of population
    // — see the field's doc comment for the measured evidence.
    try std.testing.expectEqual(@as(usize, 2000), capacity.min_group_field_agents);
}

test "demo spawns atlas-backed moving actors" {
    var demo = try initDemoForTest(std.testing.allocator);
    defer demo.deinit();

    try std.testing.expectEqual(@as(usize, default_demo_mover_count + obstacle_count + 1), demo.data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, default_demo_mover_count + obstacle_count + 1), demo.data.collisionBoundsSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, default_demo_mover_count + obstacle_count + 1), demo.data.collisionResponseSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, default_demo_mover_count + obstacle_count + 1), demo.data.assetReferenceSliceConst().entities.len);
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

test "demo spawns atlas-backed moving actors (non-compact world)" {
    // 17x17 tiles at 32px tile size crosses `worldUsesCompactDemoSpawn`'s
    // <=16 threshold, exercising the non-compact spawn branch.
    const world_dimension_px: f32 = 544;
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    const meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    var world = try WorldSystem.initDemoFromMetaWithUnderground(std.testing.allocator, &meta, world_dimension_px, world_dimension_px);
    world.adoptTilesetMeta(meta);
    const dig_config = try DigConfig.fromMeta(world.tilesetMeta().?);
    var demo = try GameDemoState.initWithWorld(
        std.testing.allocator,
        world_dimension_px,
        world_dimension_px,
        world_dimension_px,
        world_dimension_px,
        world,
        dig_config,
        1,
        null,
        null,
        default_demo_mover_count,
    );
    defer demo.deinit();

    try std.testing.expect(!worldUsesCompactDemoSpawn(&demo.world));

    // Sanity check that the non-compact (hard-coded absolute pixel) spawn
    // layout actually ran, not the compact branch's proportional layout.
    const first_obstacle_body = demo.data.movementBodyConst(demo.obstacles[0]).?;
    try std.testing.expectEqual(@as(f32, 462), first_obstacle_body.position.x);
    try std.testing.expectEqual(@as(f32, 215), first_obstacle_body.position.y);

    try std.testing.expectEqual(@as(usize, default_demo_mover_count + obstacle_count + 1), demo.data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, default_demo_mover_count + obstacle_count + 1), demo.data.collisionBoundsSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, default_demo_mover_count + obstacle_count + 1), demo.data.collisionResponseSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, default_demo_mover_count + obstacle_count + 1), demo.data.assetReferenceSliceConst().entities.len);
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
    for (0..default_demo_mover_count) |index| {
        const asset_ref = demoCharacterAssetReference(index);
        try std.testing.expectEqual(SpriteAssetId.grim_characters, asset_ref.sprite);
        try std.testing.expect(meta.sourceRectForId(asset_ref.atlas_entry_id) != null);
    }
}

test "demo init validates atlas-backed references at loading boundary" {
    var runtime_assets = try runtimeAssetsWithDemoMetadataForTest();
    defer deinitRuntimeAssetMetadataForTest(&runtime_assets);

    var demo = try GameDemoState.initWithRuntimeAssets(std.testing.allocator, &runtime_assets, demo_test_viewport_width, demo_test_viewport_height);
    defer demo.deinit();

    try std.testing.expectEqual(@as(usize, default_demo_mover_count + obstacle_count + 1), demo.data.assetReferenceSliceConst().entities.len);
}

test "procedural demo uses large world bounds and interpolated follow camera" {
    // Simulation bounds decoupled from the (small) hand-built world's own
    // tile-grid bounds; distinctly larger than both the viewport and the
    // player positions set below, so the camera clamp never saturates.
    const large_bounds_width: f32 = 8192;
    const large_bounds_height: f32 = 4096;

    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    const meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    var world = try WorldSystem.initDemoFromMetaWithUnderground(std.testing.allocator, &meta, demo_test_viewport_width, demo_test_viewport_height);
    world.adoptTilesetMeta(meta);
    const dig_config = try DigConfig.fromMeta(world.tilesetMeta().?);
    var demo = try GameDemoState.initWithWorld(
        std.testing.allocator,
        demo_test_viewport_width,
        demo_test_viewport_height,
        large_bounds_width,
        large_bounds_height,
        world,
        dig_config,
        1,
        null,
        null,
        default_demo_mover_count,
    );
    defer demo.deinit();

    try std.testing.expectEqual(demo_test_viewport_width, demo.viewport_width);
    try std.testing.expectEqual(demo_test_viewport_height, demo.viewport_height);
    try std.testing.expect(demo.bounds_width > demo.viewport_width);
    try std.testing.expect(demo.bounds_height > demo.viewport_height);

    const body = demo.data.movementBodyPtr(demo.player.entity).?;
    body.position_x.* = 4096.5;
    body.position_y.* = 2048.25;
    body.previous_x.* = 4090.5;
    body.previous_y.* = 2040.25;
    demo.updateCamera();

    // Player off-center of a large world so the camera clamp doesn't saturate at 0
    // and the sub-pixel lerp between previous/current camera positions is visible.
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
        GameDemoState.initWithRuntimeAssets(std.testing.allocator, &runtime_assets, demo_test_viewport_width, demo_test_viewport_height),
    );
}

test "demo world tile event invalidates navigation after commit reaction" {
    var demo = try initDemoForTest(std.testing.allocator);
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
    try demo.pipeline.reactToPostCommitPerceptionEvents(&demo.simulation_frame, &demo.world);

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
    var demo = try initDemoForTest(std.testing.allocator);
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
    var demo = try initDemoForTest(std.testing.allocator);
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
    try demo.pipeline.reactToPostCommitPerceptionEvents(&demo.simulation_frame, &demo.world);

    // The link still climbs planes via the world tier (independent of the abstract graph).
    placePlayerInCell(&demo, 5, 3);
    try demo.pipeline.dig.applyPlaneTraversal(&demo.world, &demo.data, &demo.player, &demo.simulation_frame);
    try std.testing.expectEqual(@as(u16, 0), demo.player.current_level);
}

test "demo dig down drops the player through the dirt plane to the void plane" {
    var demo = try initDemoForTest(std.testing.allocator);
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

    // Regression: the player's scope metadata level (read by the LOD tier demotion
    // in queueTierChanges) must track current_level, or descending far enough
    // stages the player out of the movement tier via a phantom level_delta.
    try std.testing.expectEqual(@as(u16, 2), demo.data.simulationMetadata(demo.player.entity).?.level);

    // The void-plane landing cell is carved walkable so the player is not buried.
    const floor2 = demo.world.denseFloorLayerForLevel(2).?;
    try std.testing.expect(!demo.world.denseTileBlocksMovement(floor2, 5, 3));
}

test "demo multi-cell obstacle rect event blocks every covered nav cell in one batch" {
    var demo = try initDemoForTest(std.testing.allocator);
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
    try demo.pipeline.reactToPostCommitPerceptionEvents(&demo.simulation_frame, &demo.world);

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

    var demo = try initDemoForTest(std.testing.allocator);
    defer demo.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 0,
        .items_per_range = movement_range_alignment_items,
    });
    defer threads.deinit();
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var audio = AudioCommandBuffer.init(std.testing.allocator, demo_test_audio_capacity);
    defer audio.deinit();
    var runtime_assets = RuntimeAssets.init(std.testing.allocator);
    placePlayerInCell(&demo, 3, 3);
    demo.player.syncPreviousPosition(&demo.data);
    var input = InputState{};
    input.setHeld(.moveRight, true);
    const player_before = demo.data.movementBodyConst(demo.player.entity).?;
    var square_before: [default_demo_mover_count]math.Vec2 = undefined;
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

    var demo = try initDemoForTest(std.testing.allocator);
    defer demo.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 0,
        .items_per_range = movement_range_alignment_items,
    });
    defer threads.deinit();
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var audio = AudioCommandBuffer.init(std.testing.allocator, demo_test_audio_capacity);
    defer audio.deinit();
    var runtime_assets = RuntimeAssets.init(std.testing.allocator);
    placePlayerInCell(&demo, 3, 3);
    demo.player.syncPreviousPosition(&demo.data);
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
    try std.testing.expect(ambientAudioCommandCount(&audio) >= 3);

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
    try std.testing.expectEqual(@as(usize, 1), ambientAudioCommandCount(&audio));

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
    try std.testing.expectEqual(@as(usize, 2), ambientAudioCommandCount(&audio));
}

test "demo collision response blocks player against obstacles" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var demo = try initDemoForTest(std.testing.allocator);
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
    var runtime_assets = RuntimeAssets.init(std.testing.allocator);

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

    var demo = try initDemoForTest(std.testing.allocator);
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
    var runtime_assets = RuntimeAssets.init(std.testing.allocator);

    // Record pre positions for sample ai squares (see demoArchetypeForIndex's 8-slot
    // cycle: 0=wander agent, 1=pursue agent, 3=timid via the template spawn path).
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

    var demo = try initDemoForTest(std.testing.allocator);
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
    var runtime_assets = RuntimeAssets.init(std.testing.allocator);

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
    var demo = try initDemoForTest(std.testing.allocator);
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
    var runtime_assets = RuntimeAssets.init(std.testing.allocator);

    // Pick an ai square (index 0 is wander ai), park in the top-left corner, then
    // push out of bounds so clamp runs without post-clamp collision shoving it back out.
    const ai_ent = demo.test_squares[0];
    isolateDemoBodiesAwayFrom(&demo, ai_ent);
    const visual = demo.data.primitiveVisualConst(ai_ent).?;
    const body = demo.data.movementBodyPtr(ai_ent).?;
    body.position_x.* = -10;
    body.position_y.* = -10;
    body.previous_x.* = body.position_x.*;
    body.previous_y.* = body.position_y.*;
    body.velocity_x.* = -20;
    body.velocity_y.* = -20;

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
    try std.testing.expect(after.position.y >= 0);
    try std.testing.expect(after.position.x <= demo.bounds_width - visual.size.x);
    try std.testing.expect(after.position.y <= demo.bounds_height - visual.size.y);
    // vels zeroed on the violated axes (was pushed out)
    try std.testing.expectEqual(@as(f32, 0), after.velocity.x);
    try std.testing.expectEqual(@as(f32, 0), after.velocity.y);
}

test "demo structural static obstacle change emits one navigation invalidation event" {
    var demo = try initDemoForTest(std.testing.allocator);
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

test "demo event capacity covers every NPC falling plus player fall, mining, structural, and nav events in one step" {
    var demo = try initDemoForTest(std.testing.allocator);
    defer demo.deinit();

    demo.simulation_frame.beginStep();
    // Shares one `frame.events` capacity_limit across every source that can land in
    // the same step: `applyNpcPlaneTraversal` walks every AI agent and can emit up
    // to `default_demo_mover_count` fall events, plus the player's own plane-traversal
    // fall (1) and dig-mining event (1), plus up to the derived structural reserve
    // structural-commit events, plus the post-commit nav-invalidation headroom (1),
    // plus the `demoArchetypeForIndex` cognition subset's worst-case perception
    // (2/agent) and affect (4/agent) events.
    //
    // The 155 below is a hard-coded expectation, not re-derived from
    // deriveDemoPopulationCapacity: re-deriving it here would make this assertion pass
    // trivially even if that formula drifted, since both sides would drift together.
    // A literal catches that.
    const worst_case_event_count: usize = 155;
    try std.testing.expectEqual(worst_case_event_count, deriveDemoPopulationCapacity(default_demo_mover_count).event_reserve);

    const original_events_allocator = demo.simulation_frame.events.stream.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    demo.simulation_frame.events.stream.allocator = failing_allocator.allocator();
    defer demo.simulation_frame.events.stream.allocator = original_events_allocator;

    var appended: usize = 0;
    while (appended < worst_case_event_count) : (appended += 1) {
        try demo.simulation_frame.events.appendRequired(.{
            .stage = .structural_commit,
            .payload = .{ .world_tile_changed = .{
                .level = 0,
                .x = 0,
                .y = 0,
                .old_tile_id = 0,
                .new_tile_id = 1,
            } },
        });
    }
    try std.testing.expectEqual(worst_case_event_count, demo.simulation_frame.events.mergedItems().len);

    try std.testing.expectError(error.EventCapacityExceeded, demo.simulation_frame.events.appendRequired(.{
        .stage = .structural_commit,
        .payload = .{ .world_tile_changed = .{
            .level = 0,
            .x = 0,
            .y = 0,
            .old_tile_id = 0,
            .new_tile_id = 1,
        } },
    }));
}

test "demo preflights navigation invalidation event before structural mutation" {
    var demo = try initDemoForTest(std.testing.allocator);
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
    var demo = try initDemoForTest(std.testing.allocator);
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
    var demo = try initDemoForTest(std.testing.allocator);
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
    var demo = try initDemoForTest(std.testing.allocator);
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
