// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! `far-sim`: the production fixed step (`GameDemoState.update`) with one near body and
//! every other agent on the lowest band. Population axis, world side 256: items `1024`,
//! `4096`, `10000`. Extent axis, population 4096: items `1000064`, `1000256`, `1001024`
//! (layout 1, side 64 / 256 / 1024). Agents sit one per stagger cell on level 4, so each
//! cell's first arrival takes the next level origin.
//!
//! The measured window is one residue cycle of 64 steps after the harness warmup and the
//! adaptive settle limit. Pass shape: think rows follow population / cadence and are flat
//! in extent. Over those 64 steps the think-set length sum equals the lowest-band agent
//! count, the per-step max and min differ by at most 1, index entries equal the AI count,
//! movement items equal `advancing`, and collision items stay 1. The whole step is not
//! that single order.

const std = @import("std");
const AudioCommandBuffer = @import("../app/audio.zig").AudioCommandBuffer;
const InputState = @import("../app/input.zig").InputState;
const runtime_perf_log = @import("../app/runtime_perf_log.zig");
const StateTransitions = @import("../app/state.zig").StateTransitions;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const TimeLoop = @import("../app/time_loop.zig").TimeLoop;
const AssetStore = @import("../assets/assets.zig").AssetStore;
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const AudioConfig = @import("../config.zig").AudioConfig;
const math = @import("../core/math.zig");
const PrimitiveVisual = @import("../game/data_system.zig").PrimitiveVisual;
const StructuralCommand = @import("../game/data_system.zig").StructuralCommand;
const SteeringAgent = @import("../game/data_system.zig").SteeringAgent;
const DigConfig = @import("../game/dig_controller.zig").DigConfig;
const GameDemoState = @import("../game/game_demo_state.zig").GameDemoState;
const placeSpawnedMover = @import("../game/game_demo_state.zig").placeSpawnedMover;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const IndexGeometry = @import("../game/systems/spatial_index.zig").IndexGeometry;
const SpatialIndexConfig = @import("../game/systems/spatial_index.zig").SpatialIndexConfig;
const cellGrid = @import("../game/systems/spatial_index.zig").cellGrid;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

const BenchBatchStage = runtime_perf_log.BenchBatchStage;
const Metric = runtime_perf_log.Metric;

pub const group = suite.BenchmarkGroup{
    .name = "far-sim",
    .item_label = "layout * 10^6 + side, else population",
    .describe_item = describeItem,
    .item_counts = &item_counts,
    .runCase = runCase,
    .write_workload = writeWorkload,
    .cases = &suite.serial_and_tuned_cases,
};

const extent_base: usize = 1_000_000;
const population_side: u16 = 256;
const extent_population: u32 = 4096;
const level_count: u16 = 5;
const agent_level: u16 = 4;
const residue_steps: usize = 64;
const viewport_width: f32 = 1280;
const viewport_height: f32 = 720;
const body_size: f32 = 20;
const agent_speed: f32 = 42;

const item_counts = [_]usize{
    1024,
    4096,
    10000,
    extent_base + 64,
    extent_base + 256,
    extent_base + 1024,
};

const Fields = struct {
    layout: u8,
    side: u16,
    population: u32,
};

fn decodeItem(item: usize) Fields {
    if (item >= extent_base) {
        return .{ .layout = 1, .side = @intCast(item - extent_base), .population = extent_population };
    }
    return .{ .layout = 0, .side = population_side, .population = @intCast(item) };
}

fn describeItem(writer: *std.Io.Writer, item: usize) std.Io.Writer.Error!void {
    const fields = decodeItem(item);
    try writer.print("layout={} side={} population={}", .{ fields.layout, fields.side, fields.population });
}

fn bodyVisual() PrimitiveVisual {
    return .{
        .size = .{ .x = body_size, .y = body_size },
        .color = .{ .r = 0.5, .g = 0.6, .b = 0.7, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    };
}

fn lowestAgents(data: *const DataSystem) usize {
    var count: usize = 0;
    for (data.aiAgentSliceConst().tier) |tier| {
        if (tier == .lowest) count += 1;
    }
    return count;
}

const StepRunner = struct {
    state: *GameDemoState,
    io: std.Io,
    input: *const InputState,
    audio: *AudioCommandBuffer,
    runtime_assets: *const RuntimeAssets,
    asset_store: AssetStore,
    transitions: *StateTransitions,
    threads: *ThreadSystem,
    perf_log: runtime_perf_log.RuntimePerfLog = runtime_perf_log.RuntimePerfLog.init(0),
    step_batches: runtime_perf_log.StepBatches = .{},

    fn run(self: *StepRunner) !u64 {
        self.perf_log = runtime_perf_log.RuntimePerfLog.init(0);
        self.step_batches = .{};
        self.audio.beginStep();
        const start_ns = suite.nowNs(self.io);
        try self.state.update(.{
            .input = self.input,
            .audio = self.audio,
            .runtime_assets = self.runtime_assets,
            .asset_store = self.asset_store,
            .delta_seconds = TimeLoop.fixed_delta_seconds,
            .transitions = self.transitions,
            .thread_system = self.threads,
            .perf = .{ .logger = &self.perf_log, .step_batches = &self.step_batches },
        });
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(self.io));
        std.debug.assert(self.state.simulation_frame.phase == .finished);
        return elapsed_ns;
    }
};

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const fields = decodeItem(item_count);
    std.debug.assert(fields.population >= 1);

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();

    var tileset = try fixtures.loadTilesetMeta(allocator, io);
    defer tileset.deinit();
    const dig_config = try DigConfig.fromMeta(&tileset);
    const state = try allocator.create(GameDemoState);
    defer allocator.destroy(state);
    var world = try fixtures.buildBandedWorld(allocator, &tileset, fields.side, level_count, "grass", "grass");
    const world_px = world.worldWidthPixels();
    state.* = try GameDemoState.initWithWorld(
        allocator,
        viewport_width,
        viewport_height,
        world_px,
        world.worldHeightPixels(),
        world,
        dig_config,
        threads.participantSlotCount(),
        null,
        &threads,
        0,
        AssetStore.init(allocator, io, "assets"),
    );
    defer state.deinit();

    const grid = cellGrid(IndexGeometry.ofWorld(&state.world), (SpatialIndexConfig{}).cell_size);
    const cells_x: usize = grid.cells_x;
    const cells_y: usize = grid.cells_y;
    const population: usize = fields.population;
    std.debug.assert(population <= cells_x * cells_y);

    const bundle = state.archetype_catalog.bundleForId(.wanderer);
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(allocator);
    try commands.ensureTotalCapacity(allocator, population);
    for (0..population) |agent| {
        const col = agent % cells_x;
        const row = agent / cells_x;
        const position = math.Vec2{
            .x = (@as(f32, @floatFromInt(col)) + 0.5) * grid.cell_size,
            .y = (@as(f32, @floatFromInt(row)) + 0.5) * grid.cell_size,
        };
        commands.appendAssumeCapacity(.{ .create_entity = .{
            .movement_body = .{ .position = position, .previous_position = position, .speed = agent_speed },
            .primitive_visual = bodyVisual(),
            .asset_reference = .{ .sprite = .grim_characters },
            .collision_bounds = .{ .size = .{ .x = body_size, .y = body_size } },
            .collision_response = .{ .mode = .bounce, .mobility = .dynamic, .restitution = 1 },
            .world_level = agent_level,
            .faction = bundle.faction,
            .ai_agent = bundle.behavior,
            .ai_perception = bundle.perception,
            .ai_memory = bundle.memory,
            .ai_affect = bundle.affect,
            .steering_agent = if (bundle.behavior != null) SteeringAgent{} else null,
        } });
    }
    const rows_before = state.data.movementBodySliceConst().entities.len;
    _ = try state.data.applyStructuralCommands(commands.items);
    const movement = state.data.movementBodySliceConst();
    std.debug.assert(movement.entities.len == rows_before + population);
    for (movement.entities[rows_before..]) |entity| try placeSpawnedMover(&state.data, &state.world, entity);
    std.debug.assert(state.data.ai_agents.len() == population);

    const player = state.data.movementBodyPtr(state.player.entity).?;
    const player_xy = 0.5 * grid.cell_size;
    player.position_x.* = player_xy;
    player.position_y.* = player_xy;
    player.previous_x.* = player_xy;
    player.previous_y.* = player_xy;

    _ = try state.pipeline.syncPopulationCapacity(&state.simulation_frame, &state.data);
    if (suite.tunerCount(GameDemoState, state) > suite.TunerSettle.capacity) return error.TunerCensusCapacity;

    var input = InputState{};
    var audio = AudioCommandBuffer.init(allocator, (AudioConfig{}).max_commands_per_step);
    defer audio.deinit();
    try audio.reserve();
    var transitions = StateTransitions.init(allocator);
    defer transitions.deinit();
    var runtime_assets = RuntimeAssets.init(allocator);
    var step = StepRunner{
        .state = state,
        .io = io,
        .input = &input,
        .audio = &audio,
        .runtime_assets = &runtime_assets,
        .asset_store = AssetStore.init(allocator, io, "assets"),
        .transitions = &transitions,
        .threads = &threads,
    };

    const warmup_steps = options.warmup_iterations + suite.adaptiveSettleIterationLimit(options);
    for (0..warmup_steps) |_| _ = try step.run();
    var settle = suite.TunerSettle{};
    settle.addAll(GameDemoState, state, "state");

    const lowest = lowestAgents(&state.data);
    var think_sum: u64 = 0;
    var think_min: u64 = std.math.maxInt(u64);
    var think_max: u64 = 0;
    var movement_items: u64 = 0;
    var index_entries: usize = 0;
    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..residue_steps) |_| {
        const step_ns = try step.run();
        accumulator.record(step_ns, .{});
        const thinking = step.perf_log.metrics[@backingInt(Metric.scope_ai_stage_entities)];
        think_sum += thinking;
        think_min = @min(think_min, thinking);
        think_max = @max(think_max, thinking);
        const ai_count = state.data.ai_agents.len();
        index_entries = state.pipeline.spatial_index.view().entryCount();
        const movement_batch = step.step_batches.batches[@backingInt(BenchBatchStage.movement)];
        const collision_batch = step.step_batches.batches[@backingInt(BenchBatchStage.collision_fill)];
        movement_items = movement_batch.items;
        const advancing: u64 = @intCast(state.data.movement_bodies.advancing);
        if (index_entries != ai_count or movement_batch.calls != 1 or movement_batch.items != advancing or collision_batch.calls == 0 or collision_batch.min_items != 1 or collision_batch.max_items != 1) {
            std.debug.print(
                "far-sim: step think={} index={} ai={} movement_calls={} movement_items={} advancing={} collision_calls={} collision_min={} collision_max={}\n",
                .{ thinking, index_entries, ai_count, movement_batch.calls, movement_batch.items, advancing, collision_batch.calls, collision_batch.min_items, collision_batch.max_items },
            );
            return error.FarSimShape;
        }
    }
    const lowest_after = lowestAgents(&state.data);
    if (lowest != population or lowest_after != lowest or think_sum != @as(u64, lowest) or think_max - think_min > 1) {
        std.debug.print(
            "far-sim: think_sum={} lowest={}/{} think_step={}-{} index={} population={}\n",
            .{ think_sum, lowest, lowest_after, think_min, think_max, index_entries, population },
        );
        return error.FarSimShape;
    }

    var stats = accumulator.finish();
    stats.sample_count = lowest;
    stats.candidate_pairs = think_sum;
    stats.deferred_count = think_min;
    stats.fallback_deferred_count = think_max;
    stats.output_count = index_entries;
    stats.neighbor_block_fills = movement_items;
    stats.secondary_neighbor_block_fills = 1;
    stats.batch_carried = false;
    stats.items_per_second = suite.itemsPerSecond(population, stats.mean_ns);
    if (case.adaptive) stats.tuner_settle = settle.measured();
    return stats;
}

fn writeWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print(
        "think_sum={} lowest={} think_step={}-{} index={} movement={} collision={}",
        .{
            stats.candidate_pairs,
            stats.sample_count,
            stats.deferred_count,
            stats.fallback_deferred_count,
            stats.output_count,
            stats.neighbor_block_fills,
            stats.secondary_neighbor_block_fills,
        },
    );
}
