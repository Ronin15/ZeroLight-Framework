// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared private test fixtures for the simulation pipeline tests. Test-only: no
//! production path imports it. Fixtures that reach private pipeline declarations stay
//! in `simulation_pipeline.zig`.

const std = @import("std");
const math = @import("../core/math.zig");
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const AdaptiveWorkProfile = @import("../app/thread_system.zig").AdaptiveWorkProfile;
const DataSystem = @import("data_system.zig").DataSystem;
const EntityId = @import("data_system.zig").EntityId;
const CollisionResponseMobility = @import("data_system.zig").CollisionResponseMobility;
const CollisionResponseMode = @import("data_system.zig").CollisionResponseMode;
const Faction = @import("data_system.zig").Faction;
const PrimitiveVisual = @import("data_system.zig").PrimitiveVisual;
const DigConfig = @import("dig_controller.zig").DigConfig;
const DigController = @import("dig_controller.zig").DigController;
const DigIntent = @import("simulation.zig").DigIntent;
const Player = @import("player.zig").Player;
const PathfindingCapacity = @import("systems/pathfinding.zig").PathfindingCapacity;
const PathfindingSystem = @import("systems/pathfinding.zig").PathfindingSystem;
const PlaneEntrySystem = @import("systems/plane_entry.zig").PlaneEntrySystem;
const SimulationFrame = @import("simulation.zig").SimulationFrame;
const SimulationEvent = @import("simulation.zig").SimulationEvent;
const structuralEventHeadroom = @import("simulation.zig").structuralEventHeadroom;
const maxEventsPerStep = @import("simulation.zig").maxEventsPerStep;
const action_intent_live_capacity = @import("simulation.zig").action_intent_live_capacity;
const pipeline_structural_event_share = @import("simulation.zig").pipeline_structural_event_share;
const stimulus_live_capacity = @import("simulation.zig").stimulus_live_capacity;
const StructuralCommand = @import("data_system.zig").StructuralCommand;
const ActiveRegion = @import("simulation_scope.zig").ActiveRegion;
const cognition_halo_chunks = @import("simulation_scope.zig").cognition_halo_chunks;
const WorldSystem = @import("world/system.zig").WorldSystem;
const Rect = @import("../render/renderer.zig").Rect;
const AssetStore = @import("../assets/assets.zig").AssetStore;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const GridCell = @import("systems/pathfinding/types.zig").GridCell;
const ThreadSystemConfig = @import("../app/thread_system.zig").ThreadSystemConfig;
const InterestMarkerId = @import("world/interest.zig").InterestMarkerId;
const nav_test_support = @import("systems/pathfinding/test_support.zig");
const AiAgent = @import("data_system.zig").AiAgent;
const MovementBody = @import("data_system.zig").MovementBody;
const SimulationTier = @import("simulation_scope.zig").SimulationTier;
const SimulationPipelineUpdateContext = @import("simulation_pipeline.zig").SimulationPipelineUpdateContext;
const sim_view_overscan_chunks = @import("simulation_pipeline.zig").sim_view_overscan_chunks;
const PopulationSyncStats = @import("simulation_pipeline.zig").PopulationSyncStats;
const SimulationPipeline = @import("simulation_pipeline.zig").SimulationPipeline;
const data_test_support = @import("data_system/test_support.zig");

/// Minimal multi-level grass/dirt world for dig/plane/gate pipeline tests.
/// 8×8 tiles cover cell fixtures around (3..6, 3) without full 320 demo paint.
pub fn testMinimalMultiLevelWorld(meta: *const world_tileset_meta.WorldTilesetMeta) !WorldSystem {
    const bounds = meta.tileSize() * 8;
    return WorldSystem.initDemoFromMetaWithUnderground(std.testing.allocator, meta, bounds, bounds);
}

/// Builds a 3-level minimal world and carves the given level-1 cells walkable so a
/// player body can sit in one and try to move into solid dirt around it.
pub fn gateTestWorld(meta: *const world_tileset_meta.WorldTilesetMeta, carve: []const [2]u16) !WorldSystem {
    var world = try testMinimalMultiLevelWorld(meta);
    errdefer world.deinit();
    const cave_0 = (meta.tileByName("cave_0") orelse return error.TestUnexpectedResult).id;
    const floor1 = world.denseFloorLayerForLevel(1).?;
    for (carve) |cell| {
        _ = try world.setDenseTile(floor1, cell[0], cell[1], cave_0);
    }
    return world;
}

/// One plane stage's dig half: a serial entry gather, the reserve, then the commit.
pub fn testPlaneTraversalStage(dig: *DigController, world: *WorldSystem, data: *DataSystem, player: *Player, frame: *SimulationFrame) !void {
    var plane_entry = PlaneEntrySystem.init(std.testing.allocator);
    defer plane_entry.deinit();
    const entries = try plane_entry.gather(data, world, player.entity, dig.tunnel_tile, null);
    const reservation = try dig.reservePlaneTraversalStage(world, data, player, frame, entries, null);
    try dig.commitPlaneTraversalStage(world, data, player, frame, reservation, null);
}

pub fn placePlayerFlush(data: *DataSystem, player: Player, cell: [2]u16) void {
    const body = data.movementBodyPtr(player.entity).?;
    const x = @as(f32, @floatFromInt(cell[0])) * 32;
    const y = @as(f32, @floatFromInt(cell[1])) * 32;
    body.previous_x.* = x;
    body.previous_y.* = y;
    body.position_x.* = x;
    body.position_y.* = y;
}

const scope_render_test_agent_count = 4;

const scope_render_test_steps = 4;

const ScopeRenderTraceStep = struct {
    cognition_region: ?ActiveRegion,
    ai_entity_count: usize,
    stagger_skips: usize,
    tier_commands: [scope_render_test_agent_count + 1]?StructuralCommand,
};

const ScopeRenderTrace = struct {
    steps: [scope_render_test_steps]ScopeRenderTraceStep,
    bodies: [scope_render_test_agent_count]MovementBody,
    agents: [scope_render_test_agent_count]AiAgent,
};

/// Runs `scope_render_test_steps` pipeline steps with one fixed `sim_view` on a
/// 64×16-tile, chunk-16 world (4 chunks) with one AI agent per chunk. When
/// `render_cadence` is set, the render visibility window is rewritten between
/// steps (varying rects, call counts, and a far rect) as interpolated render
/// frames would; otherwise it is never set.
pub fn runScopeRenderWindowScenario(render_cadence: bool) !ScopeRenderTrace {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    player.current_level = 0;

    const chunk_pixels: f32 = 16 * 32;
    var agents: [scope_render_test_agent_count]EntityId = undefined;
    for (&agents, 0..) |*agent, i| {
        const x = @as(f32, @floatFromInt(i)) * chunk_pixels + 100;
        agent.* = try data.createEntity();
        try data.setMovementBody(agent.*, .{
            .position = .{ .x = x, .y = 200 },
            .previous_position = .{ .x = x, .y = 200 },
            .velocity = .{ .x = 10, .y = 0 },
            .speed = 20,
        });
        try data.setAiAgent(agent.*, .{ .active_behavior = .wander, .gain_pursue = 0 });
        try data.setAiPerception(agent.*, .{});
        // Agent 2 starts a band low so the tier policy has a promotion to queue.
        try data.setSimulationMetadata(agent.*, .{
            .tier = if (i == 2) .locomotion else .cognition,
            .chunk = .{ .x = @intCast(i), .y = 0 },
            .stagger_phase = @intCast(i),
        });
    }

    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 64,
        .height = 16,
        .tile_size = 32,
        .chunk_size_tiles = 16,
    };
    defer world.deinit();
    _ = try world.addLevel(0);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, 16, 16, 16, 16, 16);
    try frame.reservePathRequests(4, 4);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 2048, 512, .{
        .contact_capacity = 8,
        .pathfinding = .{
            .max_group_fields = 1,
            .worker_participant_count = 1,
        },
    });
    defer pipeline.deinit();

    // Fixed-step view over chunk 1 → overscan-1 region chunks [0,3).
    const sim_view = Rect{ .x = 600, .y = 0, .w = 400, .h = 256 };
    // Per-step render frames: differing alpha-lerped rects, call counts, and a
    // far rect over chunk 3, including a step with no render at all.
    const render_rects = [scope_render_test_steps][]const Rect{
        &.{ .{ .x = 0, .y = 0, .w = 256, .h = 256 }, .{ .x = 37.5, .y = 0, .w = 256, .h = 256 } },
        &.{.{ .x = 1800, .y = 200, .w = 200, .h = 200 }},
        &.{},
        &.{ .{ .x = 1500, .y = 0, .w = 256, .h = 256 }, .{ .x = 1700, .y = 64, .w = 256, .h = 256 }, .{ .x = 1900, .y = 100, .w = 128, .h = 128 } },
    };

    var trace: ScopeRenderTrace = undefined;
    for (&trace.steps, render_rects) |*out, rects| {
        if (render_cadence) {
            for (rects) |rect| try world.setVisibleChunksForWorldRect(rect, sim_view_overscan_chunks, 0);
        }
        frame.beginStep();
        const stats = try pipeline.update(.{
            .data = &data,
            .frame = &frame,
            .world = &world,
            .player = &player,
            .thread_system = &threads,
            .delta_seconds = 1.0 / 60.0,
            .bounds_width = 2048,
            .bounds_height = 512,
            .sim_view = sim_view,
        });
        out.* = .{
            .cognition_region = stats.scope.active_region,
            .ai_entity_count = stats.ai.entity_count,
            .stagger_skips = stats.scope.stats.stagger_skips,
            .tier_commands = @splat(null),
        };
        const commands = frame.structural_commands.mergedItems();
        try std.testing.expect(commands.len <= out.tier_commands.len);
        for (commands, 0..) |command, i| out.tier_commands[i] = command;
    }
    if (render_cadence) {
        // The render window really did leave the sim view (else the comparison
        // would be vacuous).
        const render_region = world.visibleChunkRegion() orelse return error.TestExpectedRenderWindow;
        try std.testing.expect(!std.meta.eql(render_region, world.chunkRegionForWorldRect(sim_view, sim_view_overscan_chunks).?));
    } else {
        try std.testing.expect(world.visibleChunkRegion() == null);
    }
    for (agents, 0..) |agent, i| {
        trace.bodies[i] = data.movementBodyConst(agent).?;
        trace.agents[i] = data_test_support.aiAgent(&data, agent).?;
    }

    // Scope came from the sim view: halo region, stagger gating, and the
    // queued promotion of the locomotion-seeded agent.
    const expected_cognition = world.cognitionRegionForWorldRect(sim_view, sim_view_overscan_chunks, cognition_halo_chunks).?;
    for (trace.steps) |step| {
        try std.testing.expectEqual(@as(?ActiveRegion, expected_cognition), step.cognition_region);
        try std.testing.expect(step.stagger_skips > 0);
        const promote = (step.tier_commands[0] orelse return error.TestExpectedTierCommand).set_simulation_tier;
        try std.testing.expectEqual(agents[2], promote.entity);
        try std.testing.expectEqual(SimulationTier.cognition, promote.tier);
    }
    return trace;
}

pub const share_test_pathfinding: PathfindingCapacity = .{
    .max_group_fields = 1,
    .worker_participant_count = 1,
};

pub fn addShareTestAgent(data: *DataSystem, x: f32, faction: Faction, observer: bool) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{ .x = x, .y = 0 }, .previous_position = .{ .x = x, .y = 0 }, .velocity = .{}, .speed = 0 });
    try data.setAiAgent(entity, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setFaction(entity, faction);
    if (observer) {
        try data.setAiPerception(entity, .{});
        try data.setAiMemory(entity, .{});
    }
    return entity;
}

pub fn moveShareTestAgent(data: *DataSystem, entity: EntityId, x: f32) void {
    const body = data.movementBodyPtr(entity).?;
    body.previous_x.* = x;
    body.position_x.* = x;
    body.previous_y.* = 0;
    body.position_y.* = 0;
}

pub fn shareTestWorld() !WorldSystem {
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 64,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 16,
    };
    errdefer world.deinit();
    _ = try world.addLevel(0);
    return world;
}

pub fn countPerceptionEvents(frame: *const SimulationFrame) struct { perceived: usize, lost: usize } {
    var perceived: usize = 0;
    var lost: usize = 0;
    for (frame.events.mergedItems()) |event| switch (event.payload) {
        .entity_perceived => perceived += 1,
        .entity_lost => lost += 1,
        else => {},
    };
    return .{ .perceived = perceived, .lost = lost };
}

/// The allocators of everything a pipeline step can reach: frame streams, data, world,
/// pipeline systems, pathfinding, the static colliders and both their list tiers, dig
/// scratch, and the thread system. `install` swaps
/// them all (to one failing allocator for a zero-allocation proof, or per-owner
/// counters to see which owner allocated) and returns the originals for `restore`.
/// Test-only fixture.
pub const TestAllocatorSwap = struct {
    frame: std.mem.Allocator = undefined,
    events: std.mem.Allocator = undefined,
    navigation_intents: std.mem.Allocator = undefined,
    action_intents: std.mem.Allocator = undefined,
    intents: std.mem.Allocator = undefined,
    path_requests: std.mem.Allocator = undefined,
    contacts: std.mem.Allocator = undefined,
    collision_triggers: std.mem.Allocator = undefined,
    structural_commands: std.mem.Allocator = undefined,
    stimuli: std.mem.Allocator = undefined,
    data: std.mem.Allocator = undefined,
    world: std.mem.Allocator = undefined,
    collision: std.mem.Allocator = undefined,
    collision_response: std.mem.Allocator = undefined,
    ai: std.mem.Allocator = undefined,
    steering: std.mem.Allocator = undefined,
    pathfinding: std.mem.Allocator = undefined,
    graph: std.mem.Allocator = undefined,
    static_colliders: std.mem.Allocator = undefined,
    collider_chunk_lists: std.mem.Allocator = undefined,
    collider_query_lists: std.mem.Allocator = undefined,
    scope: std.mem.Allocator = undefined,
    spatial_index: std.mem.Allocator = undefined,
    perception: std.mem.Allocator = undefined,
    ai_memory: std.mem.Allocator = undefined,
    affect: std.mem.Allocator = undefined,
    dig: ?std.mem.Allocator = null,
    plane_entry: std.mem.Allocator = undefined,
    threads: std.mem.Allocator = undefined,

    pub const Targets = struct {
        pipeline: *SimulationPipeline,
        frame: *SimulationFrame,
        data: *DataSystem,
        world: *WorldSystem,
        threads: *ThreadSystem,
    };

    const owner_names = @typeInfo(TestAllocatorSwap).@"struct".field_names;
    const owner_count = owner_names.len;

    /// Every owner set to `allocator`.
    pub fn uniform(allocator: std.mem.Allocator) TestAllocatorSwap {
        var out: TestAllocatorSwap = .{};
        inline for (owner_names) |name| @field(out, name) = allocator;
        return out;
    }

    pub fn install(self: *TestAllocatorSwap, targets: Targets, to: TestAllocatorSwap) void {
        self.* = get(targets);
        set(targets, to);
    }

    pub fn restore(self: *const TestAllocatorSwap, targets: Targets) void {
        set(targets, self.*);
    }

    fn get(t: Targets) TestAllocatorSwap {
        return .{
            .frame = t.frame.allocator,
            .events = t.frame.events.stream.allocator,
            .navigation_intents = t.frame.navigation_intents.allocator,
            .action_intents = t.frame.action_intents.allocator,
            .intents = t.frame.intents.allocator,
            .path_requests = t.frame.path_requests.allocator,
            .contacts = t.frame.contacts.allocator,
            .collision_triggers = t.frame.collision_triggers.allocator,
            .structural_commands = t.frame.structural_commands.allocator,
            .stimuli = t.frame.stimuli.allocator,
            .data = t.data.allocator,
            .world = t.world.allocator,
            .collision = t.pipeline.collision.allocator,
            .collision_response = t.pipeline.collision_response.allocator,
            .ai = t.pipeline.ai.allocator,
            .steering = t.pipeline.steering.allocator,
            .pathfinding = t.pipeline.pathfinding.allocator,
            .graph = t.pipeline.pathfinding.graph.allocator,
            .static_colliders = t.pipeline.static_colliders.allocator,
            .collider_chunk_lists = t.pipeline.static_colliders.chunk_lists.allocator,
            .collider_query_lists = t.pipeline.static_colliders.query_lists.allocator,
            .scope = t.pipeline.scope.allocator,
            .spatial_index = t.pipeline.spatial_index.allocator,
            .perception = t.pipeline.perception.allocator,
            .ai_memory = t.pipeline.ai_memory.allocator,
            .affect = t.pipeline.affect.allocator,
            .dig = t.pipeline.dig.scratch_allocator,
            .plane_entry = t.pipeline.plane_entry.allocator,
            .threads = t.threads.allocator,
        };
    }

    fn set(t: Targets, to: TestAllocatorSwap) void {
        t.frame.allocator = to.frame;
        t.frame.events.stream.allocator = to.events;
        t.frame.navigation_intents.allocator = to.navigation_intents;
        t.frame.action_intents.allocator = to.action_intents;
        t.frame.intents.allocator = to.intents;
        t.frame.path_requests.allocator = to.path_requests;
        t.frame.contacts.allocator = to.contacts;
        t.frame.collision_triggers.allocator = to.collision_triggers;
        t.frame.structural_commands.allocator = to.structural_commands;
        t.frame.stimuli.allocator = to.stimuli;
        t.data.allocator = to.data;
        t.world.allocator = to.world;
        t.pipeline.collision.allocator = to.collision;
        t.pipeline.collision_response.allocator = to.collision_response;
        t.pipeline.ai.allocator = to.ai;
        t.pipeline.steering.allocator = to.steering;
        t.pipeline.pathfinding.allocator = to.pathfinding;
        t.pipeline.pathfinding.graph.allocator = to.graph;
        t.pipeline.static_colliders.allocator = to.static_colliders;
        t.pipeline.static_colliders.chunk_lists.allocator = to.collider_chunk_lists;
        t.pipeline.static_colliders.query_lists.allocator = to.collider_query_lists;
        t.pipeline.scope.allocator = to.scope;
        t.pipeline.spatial_index.allocator = to.spatial_index;
        t.pipeline.perception.allocator = to.perception;
        t.pipeline.ai_memory.allocator = to.ai_memory;
        t.pipeline.affect.allocator = to.affect;
        // Dig scratch stays unset (null) until the plane scratch is reserved.
        if (t.pipeline.dig.scratch_allocator != null) t.pipeline.dig.scratch_allocator = to.dig;
        t.pipeline.plane_entry.allocator = to.plane_entry;
        t.threads.allocator = to.threads;
    }
};

/// Pins every pipeline batch tuner to one settled threaded `profile` that never
/// re-probes, demotes, or resets on item-count drift, so the multi-worker path runs a
/// deterministic multi-range partition. The tuners would otherwise pick the shape from
/// timing (inline below `threaded_batch_ns`). The tuners are found by walking the
/// pipeline's fields at comptime, so a tuner a system adds is pinned with it.
/// Test-only fixture.
pub fn pinPipelineThreadedProfiles(pipeline: *SimulationPipeline, profile: AdaptiveWorkProfile) void {
    pinTunersIn(SimulationPipeline, pipeline, profile);
}

// Pins every `AdaptiveWorkTuner` `value` holds by value: itself, or in a struct field, an
// array element, or a set optional, at any depth. A single pointer is not owned, so it is
// not walked. Test-only fixture.
fn pinTunersIn(comptime T: type, value: *T, profile: AdaptiveWorkProfile) void {
    if (T == AdaptiveWorkTuner) return pinThreadedProfile(value, profile);
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| {
            if (comptime holdsTuner(Field)) pinTunersIn(Field, &@field(value, name), profile);
        },
        .array => |info| for (value) |*element| pinTunersIn(info.child, element, profile),
        .optional => |info| if (value.*) |*payload| pinTunersIn(info.child, payload, profile),
        else => {},
    }
}

// Whether a `T` holds an `AdaptiveWorkTuner` where `pinTunersIn` walks. A tuner the walk
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
            if (holdsTuner(Field)) @compileError("pinTunersIn cannot walk a tuner in union " ++ @typeName(T));
        } else false,
        .pointer => |info| switch (info.size) {
            .one => false,
            .slice, .many, .c => if (holdsTuner(info.child)) @compileError("pinTunersIn cannot walk a tuner behind " ++ @typeName(T)) else false,
        },
        .error_union => |info| if (holdsTuner(info.payload)) @compileError("pinTunersIn cannot walk a tuner in error union " ++ @typeName(T)) else false,
        else => false,
    };
}

// Pins one tuner as `pinPipelineThreadedProfiles` does. Test-only fixture.
fn pinThreadedProfile(tuner: *AdaptiveWorkTuner, profile: AdaptiveWorkProfile) void {
    tuner.config.threaded_batch_ns = 0;
    tuner.config.retune_after_settled_windows = std.math.maxInt(usize);
    tuner.config.item_count_reset_percent = std.math.maxInt(u8);
    tuner.phase = .settled;
    tuner.has_threaded_profile = true;
    tuner.current_profile = profile;
    tuner.best_profile = profile;
    tuner.candidate_profile = null;
    // Forget the pre-pin item count so the first pinned batch does not reset.
    tuner.learned_item_count = 0;
}

/// One non-failing counting allocator per `TestAllocatorSwap` owner, to see which
/// owners allocate during a step. Counts fresh allocations plus in-place
/// resizes/remaps (a grown list can remap without a fresh allocation). Test-only fixture.
pub const TestAllocatorCounters = struct {
    counters: [TestAllocatorSwap.owner_count]std.testing.FailingAllocator,

    pub fn init() TestAllocatorCounters {
        var self: TestAllocatorCounters = undefined;
        for (&self.counters) |*counter| counter.* = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        return self;
    }

    pub fn allocators(self: *TestAllocatorCounters) TestAllocatorSwap {
        var out: TestAllocatorSwap = .{};
        inline for (TestAllocatorSwap.owner_names, 0..) |name, index| @field(out, name) = self.counters[index].allocator();
        return out;
    }

    fn countAt(self: *const TestAllocatorCounters, index: usize) usize {
        return self.counters[index].allocations + self.counters[index].resize_index;
    }

    /// Fails naming the first owner outside `allowed` that allocated.
    pub fn expectOnlyOwnersAllocated(self: *const TestAllocatorCounters, comptime allowed: []const []const u8) !void {
        inline for (TestAllocatorSwap.owner_names, 0..) |name, index| {
            const is_allowed = comptime blk: {
                for (allowed) |owner| {
                    if (std.mem.eql(u8, owner, name)) break :blk true;
                }
                break :blk false;
            };
            if (!is_allowed and self.countAt(index) != 0) {
                std.debug.print("unexpected allocations on owner '{s}': {d}\n", .{ name, self.countAt(index) });
                return error.TestUnexpectedResult;
            }
        }
    }
};

/// Test-only `sim_view` covering the whole world extent: every chunk of the
/// player's level is in view, so nothing on that level leaves the cognition halo
/// or demotes. A chunkless world yields no region (the full-active fallback).
pub fn fullWorldSimView(world: *const WorldSystem) Rect {
    return .{ .x = 0, .y = 0, .w = world.worldWidthPixels(), .h = world.worldHeightPixels() };
}

/// Test-only: opts every movement body out of cognition stagger. A full-world
/// `sim_view` on a chunked world applies stagger (each agent thinks one step in
/// `cognition_stagger_n`); tests whose subject is the whole population thinking in
/// one step (a worst-case event share, a stage-order read) mark it always-active.
pub fn markAllAlwaysActive(data: *DataSystem) !void {
    for (data.movementBodySliceConst().entities) |entity| {
        var metadata = data_test_support.simulationMetadata(data, entity).?;
        metadata.always_active = true;
        try data.setSimulationMetadata(entity, metadata);
    }
}

/// Mirrors `GameDemoState.applyStructuralCommandsAndPostCommitEvents`: the collider and
/// static mark reserve, the commit with the nav-reaction slot reserved, the collider
/// capture, the population seam, the collider sync and its nav record, then the post-commit
/// reactions (nav apply only after a successful population seam and collider sync; steering
/// always), returning the first error.
pub fn commitAndSyncLikeDemo(pipeline: *SimulationPipeline, frame: *SimulationFrame, data: *DataSystem, world: *const WorldSystem) !PopulationSyncStats {
    const extra_event_count: usize = if (pipeline.navReactionMayEmit(data, frame, world)) maxEventsPerStep(.nav_reaction, .{}) else 0;
    try pipeline.reserveStaticColliders(frame, data);
    _ = try frame.applyStructuralCommandsBudgeted(data, pipeline.structuralCommitBudget(extra_event_count));
    pipeline.captureStaticColliderChanges(frame);
    const sync = pipeline.syncPopulationCapacity(frame, data);
    const colliders = pipeline.syncStaticColliders(data, null);
    const nav_update = if (sync) |_| (if (colliders) |_| pipeline.reactToPostCommitNavEvents(frame, world, null) else |err| err) else |err| err;
    pipeline.reactToPostCommitSteeringEvents(frame);
    const sync_stats = try sync;
    try colliders;
    _ = try nav_update;
    return sync_stats;
}

pub fn writeStructuralCommands(frame: *SimulationFrame, commands: []const StructuralCommand) !void {
    try frame.structural_commands.prepareRangeCounts(1);
    frame.structural_commands.addCount(0, commands.len);
    try frame.structural_commands.prefix();
    var writer = frame.structural_commands.rangeWriter(0);
    for (commands) |command| writer.write(command);
    writer.finish();
    frame.structural_commands.finishWrite();
}

pub fn cellBody(cell: [2]u16) MovementBody {
    const position = math.Vec2{ .x = @as(f32, @floatFromInt(cell[0])) * 32, .y = @as(f32, @floatFromInt(cell[1])) * 32 };
    return .{ .position = position, .previous_position = position, .velocity = .{}, .speed = 0 };
}

pub const growth_npc_visual: PrimitiveVisual = .{
    .size = .{ .x = 32, .y = 32 },
    .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
};

pub fn growthNpcTemplate(cell: [2]u16) StructuralCommand {
    return .{ .create_entity = .{
        .movement_body = cellBody(cell),
        .primitive_visual = growth_npc_visual,
        .collision_bounds = .{ .size = .{ .x = 16, .y = 16 } },
        .collision_response = .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 },
        .ai_agent = .{ .active_behavior = .wander, .gain_pursue = 0 },
        .world_level = 0,
    } };
}

pub fn growthSteeringTemplate(cell: [2]u16) StructuralCommand {
    return .{ .create_entity = .{
        .movement_body = cellBody(cell),
        .steering_agent = .{
            .agent_radius = 8,
            .waypoint_tolerance = 4,
            .avoidance_radius = 48,
            .avoidance_weight = 1.5,
            .max_neighbor_samples = 8,
            .stuck_step_threshold = 3,
            .replan_cooldown_steps = 4,
            .unavailable_backoff_steps = 12,
        },
        .world_level = 0,
    } };
}

// The pathing crowd: more agents than one 16-item range, each investigating its own
// marker on a distinct blocked cell, so the goal scan and projection, path intake, and
// registry flush each span several ranges on a 16-item partition.
const pathing_crowd_count: usize = 22;

// Cells between crowd columns: each agent's nearest marker is its own, before and after
// the markers shift one cell east.
const pathing_crowd_column_cells: u16 = 4;

// The crowd's row; the markers sit on the blocked row 0 above it.
const pathing_crowd_row: u16 = 4;

fn pathingCrowdCellX(column: usize) u16 {
    // The crowd's columns fit a test world's u16 width.
    return @intCast(1 + column * pathing_crowd_column_cells);
}

fn pathingCrowdTemplate(column: usize) StructuralCommand {
    const position = math.Vec2{ .x = @as(f32, @floatFromInt(pathingCrowdCellX(column))) * 32, .y = @as(f32, @floatFromInt(pathing_crowd_row)) * 32 };
    return .{
        .create_entity = .{
            .movement_body = .{ .position = position, .previous_position = position, .velocity = .{}, .speed = 32 },
            .ai_agent = .{ .active_behavior = .investigate, .gain_wander = 0, .gain_investigate = 1, .wander_amplitude = 0 },
            // No replan cooldown: a moved goal is requested the step it moves.
            .steering_agent = .{
                .agent_radius = 8,
                .waypoint_tolerance = 4,
                .avoidance_radius = 48,
                .avoidance_weight = 1.5,
                .max_neighbor_samples = 8,
                .stuck_step_threshold = 3,
                .replan_cooldown_steps = 0,
                .unavailable_backoff_steps = 12,
            },
            .world_level = 0,
        },
    };
}

// Places one investigate marker on row 0 of each crowd column, `shift` cells east.
fn placePathingCrowdMarkers(world: *WorldSystem, ids: []InterestMarkerId, shift: u16) !void {
    for (ids, 0..) |*id, column| {
        id.* = try world.addInterestMarker(.{
            .kind = .investigate,
            .level = 0,
            .x = @as(f32, @floatFromInt(pathingCrowdCellX(column) + shift)) * 32 + 16,
            .y = 16,
            .radius = 16,
        });
    }
}

/// Grows a 2-body population (the player and a static wall over row 0) by the pathing
/// crowd through structural creates and the population seam, pins every pipeline tuner to
/// a 2-worker partition of `first_items_per_range` items, and runs the first post-growth
/// step under per-owner counting allocators: only pathfinding allocates, its path registry
/// growing at its counted publish seam for the step's new path content, while its agent
/// capacity and its goal-table, nav-mark, eviction and group-field pool growth counts
/// hold. Then it shifts every marker, so each agent
/// asks for a new goal, re-pins the tuners to `second`, and runs one more step with every
/// allocator failing: nothing allocates, and the goal scan and projection, path intake,
/// and registry flush run threaded.
pub fn runPathingCrowdGrowthScenario(first_items_per_range: usize, second: AdaptiveWorkProfile) !void {
    const width_cells = pathingCrowdCellX(pathing_crowd_count);
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = width_cells,
        .height = pathing_crowd_row + 2,
        .tile_size = 32,
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    _ = try world.addLevel(0);
    var markers: [pathing_crowd_count]InterestMarkerId = undefined;
    try placePathingCrowdMarkers(&world, &markers, 0);
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    placePlayerFlush(&data, player, .{ 0, pathing_crowd_row + 1 });
    try addStaticBox(&data, .{ .x = 0, .y = 0 }, .{ .x = @as(f32, @floatFromInt(width_cells)) * 32, .y = 32 });

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    const headroom: usize = 16 * pathing_crowd_count;
    const bounds_width = world.worldWidthPixels();
    const bounds_height = world.worldHeightPixels();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, bounds_width, bounds_height, .{
        .movement_body_capacity = 4,
        .structural_headroom = headroom,
        .navigation_world = &world,
        .pathfinding = .{ .max_group_fields = 1, .worker_participant_count = threads.participantSlotCount() },
    });
    defer pipeline.deinit();
    try frame.reserveStreams(pipeline.eventCapacitySum(), 0, 4, 4, 4, 4 + headroom);
    try frame.reservePathRequests(pipeline.steeringStreamRangeCount(), 4);
    try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try pipeline.reserve(&frame, 4);

    const context: SimulationPipelineUpdateContext = .{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = bounds_width,
        .bounds_height = bounds_height,
        .sim_view = fullWorldSimView(&world),
    };
    frame.beginStep();
    _ = try pipeline.update(context);
    _ = try commitAndSyncLikeDemo(&pipeline, &frame, &data, &world);

    var commands: [pathing_crowd_count]StructuralCommand = undefined;
    for (&commands, 0..) |*command, column| command.* = pathingCrowdTemplate(column);
    frame.beginStep();
    try writeStructuralCommands(&frame, &commands);
    const sync = try commitAndSyncLikeDemo(&pipeline, &frame, &data, &world);
    try std.testing.expect(sync.grew);
    try markAllAlwaysActive(&data);

    const targets: TestAllocatorSwap.Targets = .{ .pipeline = &pipeline, .frame = &frame, .data = &data, .world = &world, .threads = &threads };
    pinPipelineThreadedProfiles(&pipeline, .{ .worker_threads = 2, .items_per_range = first_items_per_range });
    // Population-sized pathfinding storage the seam grew: the agent capacity and every
    // counted growth but the registry's path content.
    const PathfindingSeamState = struct { agent_capacity: usize, goal_table: u64, nav_mark: u64, evict: u64, group_field_pool: u64 };
    const seam_state = struct {
        fn of(pathfinding: *const PathfindingSystem) PathfindingSeamState {
            return .{
                .agent_capacity = pathfinding.effective_agent_capacity,
                .goal_table = pathfinding.goal_table_growth.count,
                .nav_mark = pathfinding.nav_mark_growth.count,
                .evict = pathfinding.evict_growth.count,
                .group_field_pool = pathfinding.group_field_pool_growth.count,
            };
        }
    }.of;
    const seam_before = seam_state(&pipeline.pathfinding);
    const registry_growths = pipeline.pathfinding.registry_growth.count;
    frame.beginStep();
    var counters = TestAllocatorCounters.init();
    var counting_swap: TestAllocatorSwap = .{};
    counting_swap.install(targets, counters.allocators());
    const first_result = pipeline.update(context);
    counting_swap.restore(targets);
    const first_stats = try first_result;
    try std.testing.expectEqual(pathing_crowd_count, first_stats.steering.path_request_count);
    try counters.expectOnlyOwnersAllocated(&.{"pathfinding"});
    try std.testing.expectEqual(seam_before, seam_state(&pipeline.pathfinding));
    try std.testing.expect(pipeline.pathfinding.registry_growth.count > registry_growths);
    _ = try commitAndSyncLikeDemo(&pipeline, &frame, &data, &world);

    // The crowd's markers are the world's only markers.
    try std.testing.expectEqual(@as(usize, markers.len), world.interest_markers.count());
    world.interest_markers.clear();
    try placePathingCrowdMarkers(&world, &markers, 1);
    pinPipelineThreadedProfiles(&pipeline, second);
    frame.beginStep();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    var failing_swap: TestAllocatorSwap = .{};
    failing_swap.install(targets, .uniform(failing.allocator()));
    const second_result = pipeline.update(context);
    failing_swap.restore(targets);
    const second_stats = try second_result;
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(pathing_crowd_count, second_stats.path_goals.distinct);
    try std.testing.expectEqual(pathing_crowd_count, second_stats.steering.path_request_count);
    for ([_]BatchStats{ second_stats.pathfinding.intake_batch, second_stats.pathfinding.registry_flush_batch }) |batch| {
        try std.testing.expect(!batch.ran_inline);
        try std.testing.expect(batch.range_count > 1);
    }
}

/// A pursuer of the sealed player (`addSealedGoalBoxes`) for the range-binding scenario:
/// AI and steering run every step, and the goal stays unavailable, so no path is solved.
pub fn sealedPursuerTemplate(index: usize) StructuralCommand {
    // Rows 12-14 of a 25-cell-wide world, outside the sealing ring.
    const position = math.Vec2{ .x = @floatFromInt(32 * (index % 25)), .y = @floatFromInt(32 * (12 + index / 25)) };
    return .{ .create_entity = .{
        .movement_body = .{ .position = position, .previous_position = position, .velocity = .{}, .speed = 32 },
        .ai_agent = .{ .active_behavior = .pursue, .wander_amplitude = 0, .gain_pursue = 1.0 },
        .steering_agent = .{
            .agent_radius = 8,
            .waypoint_tolerance = 4,
            .avoidance_radius = 48,
            .avoidance_weight = 1.5,
            .max_neighbor_samples = 8,
            .stuck_step_threshold = 3,
            .replan_cooldown_steps = 4,
            .unavailable_backoff_steps = 12,
        },
        .world_level = 0,
    } };
}

/// The player's goal cell (12, 7) under a 3x3 block, inside a wall ring at cells x 9..15,
/// y 4..10 that seals the open cells holding its projection.
pub fn addSealedGoalBoxes(data: *DataSystem) !void {
    try addStaticBox(data, .{ .x = 352, .y = 192 }, .{ .x = 96, .y = 96 });
    try addStaticBox(data, .{ .x = 288, .y = 128 }, .{ .x = 224, .y = 32 });
    try addStaticBox(data, .{ .x = 288, .y = 320 }, .{ .x = 224, .y = 32 });
    try addStaticBox(data, .{ .x = 288, .y = 160 }, .{ .x = 32, .y = 160 });
    try addStaticBox(data, .{ .x = 480, .y = 160 }, .{ .x = 32, .y = 160 });
}

const apply_intents_agent_count: usize = 20;

const ApplyIntentsScenarioResult = struct {
    // The player's row plus one per agent.
    velocity_x: [apply_intents_agent_count + 1]f32 = undefined,
    velocity_y: [apply_intents_agent_count + 1]f32 = undefined,
};

/// `apply_intents_agent_count` wandering agents, each with a movement body, an AI agent,
/// and a steering agent, so steering emits one movement intent each step. A chunkless
/// world keeps every agent thinking every step. `max_worker_threads > 0` pins a
/// 2-worker, 16-item partition (2 apply ranges). A warm step, then a step with every
/// allocator failing; returns that step's velocities.
pub fn runApplyIntentsScenario(max_worker_threads: usize) !ApplyIntentsScenarioResult {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    for (0..apply_intents_agent_count) |index| {
        const position = math.Vec2{
            .x = 40 + @as(f32, @floatFromInt(index % 5)) * 140,
            .y = 40 + @as(f32, @floatFromInt(index / 5)) * 90,
        };
        const agent = try data.createEntity();
        // Every 4th agent has no speed, so the apply's default speed runs too.
        const speed: f32 = if (index % 4 == 0) 0 else 10 + @as(f32, @floatFromInt(index));
        try data.setMovementBody(agent, .{ .position = position, .previous_position = position, .velocity = .{}, .speed = speed });
        try data.setAiAgent(agent, .{ .active_behavior = .wander, .wander_amplitude = 30, .gain_pursue = 0 });
        try data.setSteeringAgent(agent, growthSteeringTemplate(.{ 0, 0 }).create_entity.steering_agent.?);
    }

    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 1,
    };
    defer world.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = max_worker_threads });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 4,
        .movement_body_capacity = apply_intents_agent_count + 1,
        .pathfinding = .{ .max_group_fields = 1, .worker_participant_count = threads.participantSlotCount() },
    });
    defer pipeline.deinit();
    try frame.reserveStreams(pipeline.eventCapacitySum(), 0, apply_intents_agent_count, 4, 4, 4);
    try frame.reservePathRequests(1, apply_intents_agent_count);
    try pipeline.reserve(&frame, 4);
    if (max_worker_threads > 0) pinPipelineThreadedProfiles(&pipeline, .{ .worker_threads = 2, .items_per_range = 16 });

    const context: SimulationPipelineUpdateContext = .{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 800,
        .bounds_height = 450,
        .sim_view = fullWorldSimView(&world),
    };
    frame.beginStep();
    _ = try pipeline.update(context);

    const targets: TestAllocatorSwap.Targets = .{ .pipeline = &pipeline, .frame = &frame, .data = &data, .world = &world, .threads = &threads };
    frame.beginStep();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    var swap: TestAllocatorSwap = .{};
    swap.install(targets, .uniform(failing.allocator()));
    const result = pipeline.update(context);
    swap.restore(targets);
    const stats = try result;
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);

    try std.testing.expectEqual(apply_intents_agent_count, stats.steering.movement_intent_count);
    try std.testing.expectEqual(stats.steering.movement_intent_count, stats.apply_intents.intent_count);

    const slice = data.movementBodySliceConst();
    try std.testing.expectEqual(apply_intents_agent_count + 1, slice.entities.len);
    var out: ApplyIntentsScenarioResult = .{};
    @memcpy(&out.velocity_x, slice.velocity_x);
    @memcpy(&out.velocity_y, slice.velocity_y);
    return out;
}

// Adds dynamic collision bodies `first..end` of a row-major chain: 21 per row, 10 px
// apart, 22 px square, rows 40 px apart. Each body overlaps its next two neighbours in
// the row, so a full row of 21 yields 2 * 21 - 3 = 39 contacts.
fn addContactChainBodies(data: *DataSystem, first: usize, end: usize, mode: CollisionResponseMode) !void {
    for (first..end) |index| {
        const column: f32 = @floatFromInt(index % 21);
        const row: f32 = @floatFromInt(index / 21);
        const position = math.Vec2{ .x = 20 + column * 10, .y = 20 + row * 40 };
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{ .position = position, .previous_position = position, .velocity = .{}, .speed = 0 });
        try data.setCollisionBounds(entity, .{ .size = .{ .x = 22, .y = 22 } });
        try data.setCollisionResponse(entity, .{ .mode = mode, .mobility = .dynamic, .restitution = 0 });
    }
}

/// The contact stream, the trigger stream and the response reserves follow
/// the collision pair bound (4 per body of capacity) through `reserve` and the seam, so a
/// population that fills its grown capacity at ~2 contacts per body runs
/// `collision_detect` and `collision_respond` on a real 2-worker partition with every
/// allocator failing. `mode` picks the response path: `.solid` emits two intents per
/// contact, `.trigger` one trigger event per contact.
pub fn runContactBoundScenario(mode: CollisionResponseMode) !void {
    var world = try minimalSyncWorld();
    defer world.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const player = try Player.spawn(&data);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 4,
        .movement_body_capacity = 4,
        .pathfinding = sync_test_pathfinding,
    });
    defer pipeline.deinit();
    try frame.reserveStreams(pipeline.eventCapacitySum(), 0, 4, 4, 4, 4);
    try frame.reservePathRequests(1, 4);
    try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try pipeline.reserve(&frame, 4);
    var player_state = player;
    const context: SimulationPipelineUpdateContext = .{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player_state,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 800,
        .bounds_height = 450,
        .sim_view = fullWorldSimView(&world),
    };
    // Warm step at the initial population.
    frame.beginStep();
    _ = try pipeline.update(context);

    // 31 bodies + the player grow the tracked capacity to 64; 32 more fill it without
    // another growth. 3 full rows: 117 contacts over 64 bodies.
    try addContactChainBodies(&data, 0, 31, mode);
    try std.testing.expect((try pipeline.syncPopulationCapacity(&frame, &data)).grew);
    try std.testing.expectEqual(@as(usize, 64), pipeline.movement_body_capacity);
    try addContactChainBodies(&data, 31, 63, mode);
    try std.testing.expect(!(try pipeline.syncPopulationCapacity(&frame, &data)).grew);
    const population = data.populationRowCounts().population();
    try std.testing.expectEqual(@as(usize, 64), population);

    pinPipelineThreadedProfiles(&pipeline, .{ .worker_threads = 2, .items_per_range = 16 });
    const targets: TestAllocatorSwap.Targets = .{ .pipeline = &pipeline, .frame = &frame, .data = &data, .world = &world, .threads = &threads };
    frame.beginStep();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    var swap: TestAllocatorSwap = .{};
    swap.install(targets, .uniform(failing.allocator()));
    const result = pipeline.update(context);
    swap.restore(targets);
    const stats = try result;

    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!stats.collision.broadphase_batch.ran_inline);
    try std.testing.expect(!stats.collision.narrowphase_batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 3 * (2 * 21 - 3)), stats.collision.contact_count);
    try std.testing.expect(stats.collision.contact_count > population);
    try std.testing.expectEqual(stats.collision.contact_count, stats.collision_response.contact_count);
    switch (mode) {
        .solid, .bounce => try std.testing.expectEqual(2 * stats.collision.contact_count, stats.collision_response.intent_count),
        .trigger => {
            try std.testing.expectEqual(stats.collision.contact_count, stats.collision_response.trigger_count);
            try std.testing.expectEqual(stats.collision.contact_count, frame.collision_triggers.mergedItems().len);
        },
    }
    try std.testing.expect(!stats.collision.pair_bound_exceeded);
}

const respond_scenario_bodies: usize = 63;

// The bodies plus the player.
const respond_scenario_rows: usize = respond_scenario_bodies + 1;

// 3 full chain rows of 21 before any correction.
const respond_scenario_contacts: usize = 3 * (2 * 21 - 3);

// `addContactChainBodies` with the response by index (solid or bounce dynamic, a dynamic
// trigger, a static solid) and nonzero velocities of mixed sign on the dynamic bodies,
// small enough that the chain overlaps hold after one movement step.
fn addMixedContactChainBodies(data: *DataSystem, first: usize, end: usize) !void {
    for (first..end) |index| {
        const column: f32 = @floatFromInt(index % 21);
        const row: f32 = @floatFromInt(index / 21);
        const position = math.Vec2{ .x = 20 + column * 10, .y = 20 + row * 40 };
        const response: @import("data_system.zig").CollisionResponse = switch (index % 8) {
            3 => .{ .mode = .trigger, .mobility = .dynamic, .restitution = 0 },
            5 => .{ .mode = .solid, .mobility = .static, .restitution = 0 },
            1, 6 => .{ .mode = .bounce, .mobility = .dynamic, .restitution = 0.5 },
            else => .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 },
        };
        const speed_x: f32 = 4 + @as(f32, @floatFromInt(index % 5));
        const speed_y: f32 = 3 + @as(f32, @floatFromInt(index % 3));
        const velocity: math.Vec2 = if (response.mobility == .static) .{} else .{
            .x = if (index % 2 == 0) speed_x else -speed_x,
            .y = if (index % 3 == 0) -speed_y else speed_y,
        };
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{ .position = position, .previous_position = position, .velocity = velocity, .speed = 0 });
        try data.setCollisionBounds(entity, .{ .size = .{ .x = 22, .y = 22 } });
        try data.setCollisionResponse(entity, response);
    }
}

const CollisionRespondScenarioResult = struct {
    position_x: [respond_scenario_rows]f32 = undefined,
    position_y: [respond_scenario_rows]f32 = undefined,
    velocity_x: [respond_scenario_rows]f32 = undefined,
    velocity_y: [respond_scenario_rows]f32 = undefined,
    triggers: [respond_scenario_contacts]@import("simulation.zig").CollisionTriggerEvent = undefined,
    trigger_count: usize = 0,
    intent_count: usize = 0,
};

/// The mixed chain over 63 bodies plus the player, with the pipeline reserved for its 64
/// rows. `max_worker_threads > 0` pins a 2-worker, 16-contact gather (8 ranges) and a
/// one-band-per-range apply (4 bands). A warm step, then a step with every allocator
/// failing; returns that step's movement columns and triggers.
pub fn runCollisionRespondScenario(max_worker_threads: usize) !CollisionRespondScenarioResult {
    var world = try minimalSyncWorld();
    defer world.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    try addMixedContactChainBodies(&data, 0, respond_scenario_bodies);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = max_worker_threads });
    defer threads.deinit();
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 800, 450, .{
        .contact_capacity = 4,
        .movement_body_capacity = respond_scenario_rows,
        .pathfinding = sync_test_pathfinding,
    });
    defer pipeline.deinit();
    try frame.reserveStreams(pipeline.eventCapacitySum(), 0, 4, 4, 4, 4);
    try frame.reservePathRequests(1, 4);
    try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try pipeline.reserve(&frame, 4);
    if (max_worker_threads > 0) {
        pinPipelineThreadedProfiles(&pipeline, .{ .worker_threads = 2, .items_per_range = 16 });
        pinThreadedProfile(&pipeline.collision_response.apply_tuner, .{ .worker_threads = 2, .items_per_range = 1 });
    }

    const context: SimulationPipelineUpdateContext = .{
        .data = &data,
        .frame = &frame,
        .world = &world,
        .player = &player,
        .thread_system = &threads,
        .delta_seconds = 0.016,
        .bounds_width = 800,
        .bounds_height = 450,
        .sim_view = fullWorldSimView(&world),
    };
    frame.beginStep();
    _ = try pipeline.update(context);

    const targets: TestAllocatorSwap.Targets = .{ .pipeline = &pipeline, .frame = &frame, .data = &data, .world = &world, .threads = &threads };
    frame.beginStep();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    var swap: TestAllocatorSwap = .{};
    swap.install(targets, .uniform(failing.allocator()));
    const result = pipeline.update(context);
    swap.restore(targets);
    const stats = try result;
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);

    const response = stats.collision_response;
    // The warm step's corrections separate some pairs; several gather ranges remain.
    try std.testing.expect(response.contact_count <= respond_scenario_contacts);
    try std.testing.expect(response.contact_count > 4 * 16);
    try std.testing.expect(response.intent_count > 0);
    try std.testing.expect(response.trigger_count > 0);

    const slice = data.movementBodySliceConst();
    try std.testing.expectEqual(respond_scenario_rows, slice.entities.len);
    var out: CollisionRespondScenarioResult = .{ .trigger_count = response.trigger_count, .intent_count = response.intent_count };
    @memcpy(&out.position_x, slice.position_x);
    @memcpy(&out.position_y, slice.position_y);
    @memcpy(&out.velocity_x, slice.velocity_x);
    @memcpy(&out.velocity_y, slice.velocity_y);
    @memcpy(out.triggers[0..response.trigger_count], frame.collision_triggers.mergedItems());
    return out;
}

pub fn minimalSyncWorld() !WorldSystem {
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 1,
    };
    errdefer world.deinit();
    _ = try world.addLevel(0);
    return world;
}

pub const sync_test_pathfinding: PathfindingCapacity = .{ .max_group_fields = 1, .worker_participant_count = 1 };

/// `count` steering agents with movement bodies, committed before a pipeline is built.
pub fn addSteeringAgents(data: *DataSystem, count: usize) !void {
    for (0..count) |index| {
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{ .position = .{ .x = @floatFromInt(index), .y = 0 } });
        try data.setSteeringAgent(entity, .{ .agent_radius = 4 });
    }
}

pub fn responderTemplate(index: usize, mobility: CollisionResponseMobility) StructuralCommand {
    // 64 px apart on one row, so no two responders overlap (no contacts).
    const position = math.Vec2{ .x = @as(f32, @floatFromInt(index)) * 64, .y = 0 };
    return .{ .create_entity = .{
        .movement_body = .{ .position = position, .previous_position = position, .velocity = .{}, .speed = 0 },
        .collision_bounds = .{ .size = .{ .x = 16, .y = 16 } },
        .collision_response = .{ .mode = .solid, .mobility = mobility, .restitution = 0 },
    } };
}

/// World-backed nav over the minimal three-level world: a player at (5,3) facing right, so a
/// dig hits (6,3), stepped through `update` and the demo seam. On level 0 a dig is a hole
/// (walkable either way); `underground` puts the player on level 1's solid dirt, where a dig
/// mines a walkable tunnel and so changes nav.
pub const NavSeamFixture = struct {
    meta: world_tileset_meta.WorldTilesetMeta,
    world: WorldSystem,
    data: DataSystem,
    frame: SimulationFrame,
    threads: ThreadSystem,
    player: Player,
    pipeline: SimulationPipeline,

    const Options = struct {
        tiles_per_side: u32 = 8,
        worker_threads: usize = 0,
        structural_headroom: usize = 16,
        pathfinding: PathfindingCapacity = sync_test_pathfinding,
    };

    pub fn init(self: *NavSeamFixture, options: Options) !void {
        const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
        self.meta = try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
        errdefer self.meta.deinit();
        const bounds = self.meta.tileSize() * @as(f32, @floatFromInt(options.tiles_per_side));
        self.world = try WorldSystem.initDemoFromMetaWithUnderground(std.testing.allocator, &self.meta, bounds, bounds);
        errdefer self.world.deinit();
        self.data = DataSystem.init(std.testing.allocator);
        errdefer self.data.deinit();
        self.player = try Player.spawn(&self.data);
        self.player.current_level = 0;
        placePlayerFlush(&self.data, self.player, .{ 5, 3 });
        self.data.facingPtr(self.player.entity).?.* = .right;
        self.frame = SimulationFrame.init(std.testing.allocator);
        errdefer self.frame.deinit();
        try self.frame.reserveStreams(4, 8, 8, 8, 8, 8);
        try self.frame.reservePathRequests(2, 2);
        self.threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
            .max_worker_threads = options.worker_threads,
            .items_per_range = if (options.worker_threads == 0) (ThreadSystemConfig{}).items_per_range else 1,
        });
        errdefer self.threads.deinit();
        self.pipeline = try SimulationPipeline.init(std.testing.allocator, &self.data, 256, 256, .{
            .dig = try DigConfig.fromMeta(&self.meta),
            .movement_body_capacity = 4,
            .structural_headroom = options.structural_headroom,
            .pathfinding = options.pathfinding,
            .navigation_world = &self.world,
        });
        errdefer self.pipeline.deinit();
        try self.frame.reserveStreams(self.pipeline.eventCapacitySum(), 8, 8, 8, 8, 8 + options.structural_headroom);
        try self.pipeline.reserve(&self.frame, 4);
    }

    pub fn underground(self: *NavSeamFixture) void {
        self.player.current_level = 1;
    }

    pub fn deinit(self: *NavSeamFixture) void {
        self.pipeline.deinit();
        self.threads.deinit();
        self.frame.deinit();
        self.data.deinit();
        self.world.deinit();
        self.meta.deinit();
    }

    /// One step's stages with `intent`, without the commit seam.
    pub fn update(self: *NavSeamFixture, intent: DigIntent) !void {
        self.frame.beginStep();
        self.frame.dig_intent = intent;
        _ = try self.pipeline.update(.{
            .data = &self.data,
            .frame = &self.frame,
            .world = &self.world,
            .player = &self.player,
            .thread_system = &self.threads,
            .delta_seconds = 0.016,
            .bounds_width = 256,
            .bounds_height = 256,
            .sim_view = fullWorldSimView(&self.world),
        });
    }

    pub fn seam(self: *NavSeamFixture) !void {
        _ = try commitAndSyncLikeDemo(&self.pipeline, &self.frame, &self.data, &self.world);
    }

    pub fn navBlocked(self: *const NavSeamFixture, level: u16, x: i32, y: i32) bool {
        return self.pipeline.pathfinding.graph.grid(level).?.isBlockedCell(.{ .x = x, .y = y });
    }

    /// Fills the recorded marks to their capacity, so the next mark reserve must grow.
    pub fn fillNavMarks(self: *NavSeamFixture) void {
        const marks = &self.pipeline.pathfinding.nav_marks;
        while (marks.items.len < marks.capacity) marks.appendAssumeCapacity(.{ .level = 0, .kind = .tile_box, .min_x = 0, .min_y = 0, .max_x = 0, .max_y = 0 });
    }

    /// Nav holds no pending change and equals a fresh build of the world and statics.
    pub fn expectNavMatchesRebuild(self: *const NavSeamFixture) !void {
        const live = &self.pipeline.pathfinding.graph;
        try std.testing.expect(!self.pipeline.pathfinding.hasPendingNavUpdates(&self.world));
        var rebuilt = PathfindingSystem.init(std.testing.allocator);
        defer rebuilt.deinit();
        try rebuilt.reserve(sync_test_pathfinding);
        try rebuilt.rebuildStaticNavGridWithWorld(&self.data, &self.world, null);
        try std.testing.expectEqual(rebuilt.graph.levelCount(), live.levelCount());
        for (0..live.levelCount()) |level_index| {
            const level: u16 = @intCast(level_index);
            for (0..self.world.height) |y| for (0..self.world.width) |x| {
                const cell = GridCell{ .x = @intCast(x), .y = @intCast(y) };
                try std.testing.expectEqual(rebuilt.graph.grid(level).?.isBlockedCell(cell), live.grid(level).?.isBlockedCell(cell));
            };
            try std.testing.expectEqual(rebuilt.graph.levelGraph(level).?.recordCount(), live.levelGraph(level).?.recordCount());
        }
        try std.testing.expectEqual(nav_test_support.totalPortals(&rebuilt.graph), nav_test_support.totalPortals(live));
    }
};

const StructuralBurstOutcome = struct {
    failed: bool,
    bodies: usize,
};

const structural_burst_max_creates: usize = 20;

/// Commits `create_count` 4-event creates against the structural share of a
/// `structuralEventHeadroom(1, 0)` caller headroom (15) plus the pipeline's own
/// `pipeline_structural_event_share` (64) = 79 events, on a minimal pipeline with 2
/// perception/affect observers. With `saturate_other_producers`, every other producer's share is filled
/// first, so only the structural share is left in the shared bound.
pub fn commitStructuralBurst(create_count: usize, saturate_other_producers: bool) !StructuralBurstOutcome {
    var world = try minimalSyncWorld();
    defer world.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var observers: [2]EntityId = undefined;
    for (&observers, 0..) |*observer, index| {
        observer.* = try data.createEntity();
        try data.setMovementBody(observer.*, .{ .position = .{ .x = @floatFromInt(index * 64), .y = 64 } });
        try data.setAiPerception(observer.*, .{});
        try data.setAiAffect(observer.*, .{});
    }
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const headroom = structuralEventHeadroom(1, 0);
    var pipeline = try SimulationPipeline.init(std.testing.allocator, &data, 4096, 128, .{
        .movement_body_capacity = 4,
        .structural_headroom = headroom,
        .pathfinding = sync_test_pathfinding,
    });
    defer pipeline.deinit();
    try frame.reserveStreams(pipeline.eventCapacitySum(), 0, 4, 4, 4, 4 + pipeline.structuralCommandHeadroom());
    try pipeline.reserve(&frame, 4);
    const structural_share = maxEventsPerStep(.structural_commit, pipeline.eventBudgets());
    try std.testing.expectEqual(pipeline_structural_event_share + headroom, structural_share);
    try std.testing.expectEqual(@as(usize, 79), structural_share);
    try std.testing.expect(pipeline.perception_max_events_per_step > 0 and pipeline.affect_max_events_per_step > 0);

    frame.beginStep();
    if (saturate_other_producers) {
        const filler: SimulationEvent = .{
            .stage = .domain_reaction,
            .payload = .{ .affect_threshold_crossed = .{ .entity = observers[0], .drive = .fear, .rising = true } },
        };
        for (0..pipeline.eventCapacitySum() - structural_share) |_| try frame.events.appendRequired(filler);
    }
    var commands: [structural_burst_max_creates]StructuralCommand = undefined;
    std.debug.assert(create_count <= commands.len);
    for (commands[0..create_count], 0..) |*command, index| command.* = responderTemplate(index, .dynamic);
    try writeStructuralCommands(&frame, commands[0..create_count]);
    const events_before = frame.events.mergedItems().len;
    const bodies_before = data.movementBodySliceConst().entities.len;

    _ = commitAndSyncLikeDemo(&pipeline, &frame, &data, &world) catch |err| {
        try std.testing.expectEqual(error.EventCapacityExceeded, err);
        // Rejected before mutation: no rows, no events.
        try std.testing.expectEqual(bodies_before, data.movementBodySliceConst().entities.len);
        try std.testing.expectEqual(events_before, frame.events.mergedItems().len);
        return .{ .failed = true, .bodies = data.movementBodySliceConst().entities.len };
    };
    return .{ .failed = false, .bodies = data.movementBodySliceConst().entities.len };
}

/// A static solid box of `size` from its min corner `position`.
pub fn addStaticBox(data: *DataSystem, position: math.Vec2, size: math.Vec2) !void {
    const box = try data.createEntity();
    try data.setMovementBody(box, .{ .position = position, .previous_position = position, .velocity = .{}, .speed = 0 });
    try data.setCollisionBounds(box, .{ .size = size });
    try data.setCollisionResponse(box, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
}
