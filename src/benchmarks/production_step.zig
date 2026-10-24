// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! `production-step`: the production fixed step (`GameDemoState.update`: the pipeline, then
//! the structural-commit seam) at one population, one axis moved at a time from a base of a
//! spread population on a banded walkable world. Shapes: `spread` (a uniform grid over every
//! level, the population split across levels), `crowd` (a square at a fixed pitch around
//! the observer, on the surface), and `stacked` (the same `crowd` square, archetype for
//! archetype, on every level at the observer's x/y, every row `always_active` so every
//! level is indexed and every AI row thinks every step). The state is built through
//! `initWithWorld` with no demo spawn and the production pathfinding defaults; the population
//! is committed through the production structural applier and grown through the population
//! seam.
//!
//! Item code: `shape * 10^14 + inert per agent * 10^13 + level side * 10^9 + levels * 10^6 +
//! population` (shape 0 `spread`, 1 `crowd`, 2 `stacked`). The base is 4,096 `spread` agents
//! at 1024² x 8 levels; the axes are population 1,024 and 16,384 for `spread` and `crowd`,
//! levels 1 and 32, side 512 and 2048, 1 or 4 inert rows per agent, and `stacked` at 256
//! agents per level on 1, 4, and 8 levels.
//!
//! Each sample binds a fresh runtime perf log and bench-only batch sink: `main` is the step's
//! wall time minus the off-main time of the logged and bench-only batches that ran on
//! workers (an upper bound: batches neither carries count as main), and `untimed` is the wall
//! time no top-level stage timer holds, the log's and the sink's bench-only timers both.
//! `tiers=` splits the rows by scope tier (cognition/locomotion/kinematic/dormant),
//! `thinking=` counts the rows the AI stage ran, `separation_per_thinking=` the AI separation
//! candidate checks and neighbor samples per thinking row, and `top_main=` names the three
//! top-level stages with the most main time. `--details` adds each top-level stage's
//! `wall=`, `off_main=`, and `main=` with each of its batches' `(ran=r/n threaded=k/r)`: the
//! r of n measured steps it ran on, and the k of those every call ran on workers; the nested
//! stage timers; and the census counters as means per step. It also prints, as each case
//! ends, every batch that ran under its stage timer (`calls/step=`, `items/call=` mean and
//! fewest-most, `ns/call=` mean, `ran=`, `threaded=`), and every tuner, by field path, whose
//! probe windows, demotions, restores, or shift skips changed over the measured steps.
//!
//! Every case runs the same pre-measure steps (the warmup plus the adaptive settle limit), so
//! the serial and tuned cases measure the same simulated state. The tuned case then reports
//! whether every `GameDemoState` tuner its measured steps ran had settled when measurement
//! began (`settled=k/n idle=m` and the unsettled paths; a tuner no measured step ran, such as
//! a rebuild tuner only a world create or rebuild selects, is idle) and is not judged when
//! one had not. The `--details` tuner deltas end with each tuner's phase and final shape.
//!
//! Pass shape: step and main time linear in population for `spread` and `crowd`; in level
//! side and in level count at a fixed population, every row advances at its tier and the cost
//! per advancing row stays flat; flat in inert rows; `stacked` separation checks and samples
//! per thinking row flat in levels, since a query reads only its own level. Asserts check
//! the committed population and that every step finishes; on `stacked`, separation checks
//! per thinking row within `check_bound=`, the most rows of one level any query's scan box
//! holds at the measured steps' index input (the pre-measure snapshot, each row widened by
//! the cells it crossed since; `drift=` is the most cells any row crossed per axis), and that
//! bound below the query's check budget, so a query that also reads other levels fails it.
//!
//! Dispatch check, on a case with workers: after the measured steps every `GameDemoState`
//! tuner is pinned to a one-item threaded profile over all workers and one more step runs;
//! every stage it records whose calls cover more ranges than calls must have run every call
//! on workers, or the case fails. `--details` lists the checked stages as `pinned dispatch:`.

const std = @import("std");
const AudioCommandBuffer = @import("../app/audio.zig").AudioCommandBuffer;
const InputState = @import("../app/input.zig").InputState;
const runtime_perf_log = @import("../app/runtime_perf_log.zig");
const StateTransitions = @import("../app/state.zig").StateTransitions;
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const TimeLoop = @import("../app/time_loop.zig").TimeLoop;
const AssetStore = @import("../assets/assets.zig").AssetStore;
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const AudioConfig = @import("../config.zig").AudioConfig;
const math = @import("../core/math.zig");
const AiArchetypeId = @import("../game/ai_archetypes.zig").AiArchetypeId;
const PrimitiveVisual = @import("../game/data_system.zig").PrimitiveVisual;
const StructuralCommand = @import("../game/data_system.zig").StructuralCommand;
const SteeringAgent = @import("../game/data_system.zig").SteeringAgent;
const DigConfig = @import("../game/dig_controller.zig").DigConfig;
const GameDemoState = @import("../game/game_demo_state.zig").GameDemoState;
const placeSpawnedMover = @import("../game/game_demo_state.zig").placeSpawnedMover;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const data_test_support = @import("../game/data_system/test_support.zig");
const forEachTunerIn = @import("../game/simulation_pipeline_test_support.zig").forEachTunerIn;
const pinTunersIn = @import("../game/simulation_pipeline_test_support.zig").pinTunersIn;
const keep_stagger_phase = @import("../game/simulation_scope.zig").keep_stagger_phase;
const max_separation_candidate_checks = @import("../game/systems/ai.zig").max_separation_candidate_checks;
const separation_radius = @import("../game/systems/ai.zig").separation_radius;
const boxAxisCells = @import("../game/systems/spatial_index.zig").boxAxisCells;
const cellScanRadius = @import("../game/systems/spatial_index.zig").cellScanRadius;
const SpatialIndexView = @import("../game/systems/spatial_index.zig").SpatialIndexView;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");
const TunerCounts = suite.TunerCounts;

const BatchStage = runtime_perf_log.BatchStage;
const BenchBatchStage = runtime_perf_log.BenchBatchStage;
const BenchTiming = runtime_perf_log.BenchTiming;
const Metric = runtime_perf_log.Metric;
const Timing = runtime_perf_log.Timing;

pub const group = suite.BenchmarkGroup{
    .name = "production-step",
    .item_label = StepCode.label,
    .describe_item = StepCode.describe,
    .item_counts = &item_counts,
    .runCase = runCase,
    .write_workload = writeStepWorkload,
    // The step runs its own stage tuners; the fixed controls live in the stage groups.
    .cases = &suite.serial_and_tuned_cases,
};

const StepShape = enum(u8) { spread, crowd, stacked };
const StepFields = struct { shape: StepShape, inert_per_agent: u8, level_side: u16, levels: u16, population: u32 };
const StepCode = suite.ItemCode(StepFields, &.{ 1, 4, 3, 6 });

// The base config every axis moves one field away from.
const base = StepFields{ .shape = .spread, .inert_per_agent = 0, .level_side = 1024, .levels = 8, .population = 4_096 };

fn baseWith(comptime overrides: anytype) usize {
    var fields = base;
    inline for (@typeInfo(@TypeOf(overrides)).@"struct".field_names) |name| @field(fields, name) = @field(overrides, name);
    return StepCode.of(fields);
}

const item_counts = [_]usize{
    baseWith(.{ .population = 1_024 }),
    baseWith(.{}),
    baseWith(.{ .population = 16_384 }),
    baseWith(.{ .shape = .crowd, .population = 1_024 }),
    baseWith(.{ .shape = .crowd }),
    baseWith(.{ .shape = .crowd, .population = 16_384 }),
    baseWith(.{ .levels = 1 }),
    baseWith(.{ .levels = 32 }),
    baseWith(.{ .level_side = 512 }),
    baseWith(.{ .level_side = 2048 }),
    baseWith(.{ .inert_per_agent = 1 }),
    baseWith(.{ .inert_per_agent = 4 }),
    baseWith(.{ .shape = .stacked, .levels = 1, .population = 256 }),
    baseWith(.{ .shape = .stacked, .levels = 4, .population = 1_024 }),
    baseWith(.{ .shape = .stacked, .levels = 8, .population = 2_048 }),
};

// Presentation size of the observer's view; the simulation scope derives from it.
const viewport_width: f32 = 1280;
const viewport_height: f32 = 720;
// Fixture content: body size, crowd pitch, and agent speed.
const body_size: f32 = 20;
const crowd_pitch: f32 = 24;
const agent_speed: f32 = 42;

const archetype_ids = std.meta.tags(AiArchetypeId);

// The stage timers that hold the step's top-level stages; the rest are nested inside one.
fn isTopLevelStage(stage: Timing) bool {
    const name = @tagName(stage);
    return std.mem.startsWith(u8, name, "pipeline_") or std.mem.startsWith(u8, name, "gameplay_");
}

// The batches that run inside one top-level stage timer: the perf log's cost-driver stages
// and the bench-only stages the step hands the census's sink.
const StageBatches = struct {
    logged: []const BatchStage = &.{},
    bench: []const BenchBatchStage = &.{},
};

// Each top-level stage timer's batches, for the per-stage main-thread split.
fn stageBatches(stage: Timing) StageBatches {
    return switch (stage) {
        .pipeline_spatial_index => .{ .logged = &.{.spatial_index_build}, .bench = &.{ .spatial_index_bucket, .spatial_index_link } },
        .pipeline_perception => .{ .bench = &.{ .perception_gather, .perception } },
        .pipeline_ai_memory => .{ .bench = &.{ .ai_memory_gather, .ai_memory_order, .ai_memory_visible, .ai_memory_decay } },
        .pipeline_ai_affect => .{ .bench = &.{.affect} },
        .pipeline_ai => .{ .bench = &.{ .ai_gather, .ai_separation, .ai_intent } },
        .pipeline_path_goals => .{ .bench = &.{ .path_goal_scan, .path_goal_project } },
        .pipeline_steering => .{ .bench = &.{ .steering_agents, .steering_select_resolve, .steering_select_claim, .steering_directions, .steering_grid_bucket, .steering_grid_sort, .steering } },
        .pipeline_pathfinding => .{
            .logged = &.{ .path_intake, .path_registry_flush, .path_resize_copy },
            .bench = &.{ .path_registry_flush_count, .path_registry_rename, .path_group_field_advance, .path_group_field_begin, .path_solve, .path_publish_copy },
        },
        .pipeline_apply_intents => .{ .bench = &.{.apply_intents} },
        .pipeline_movement => .{ .bench = &.{.movement} },
        .pipeline_collision => .{
            .logged = &.{.collision_trigger_refresh},
            .bench = &.{ .collision_fill, .collision_sort, .collision_broadphase, .collision_narrowphase, .collision_static_pairs, .collision_static_rect, .collision_static_place, .collision_static_sort, .collision_trigger_emit_count, .collision_trigger_emit },
        },
        .pipeline_collision_response => .{ .bench = &.{ .collision_response_gather, .collision_response_place, .collision_response_apply } },
        .pipeline_clamp_bounds => .{ .bench = &.{.world_gate} },
        .pipeline_chunk_derive => .{ .bench = &.{.chunk_derive} },
        .gameplay_particles => .{ .bench = &.{.particles} },
        .gameplay_structural => .{
            .logged = &.{ .static_collider_plan, .collision_trigger_rewrite, .nav_remask, .nav_connect, .nav_closure, .nav_evict },
            .bench = &.{ .static_collider_touch, .static_collider_group, .static_collider_apply, .static_collider_rewrite, .static_collider_install, .collision_trigger_query, .collision_trigger_insert_place, .collision_trigger_insert_sort, .collision_trigger_node },
        },
        else => .{},
    };
}

// Each bench-only stage timer's batches; every bench-only timer is a top-level stage.
fn benchStageBatches(stage: BenchTiming) StageBatches {
    return switch (stage) {
        .pipeline_scope_gather => .{ .bench = &.{.scope_ai_gather} },
        .pipeline_cognition_order => .{ .bench = &.{.scope_cognition} },
        .pipeline_collision_scope => .{ .bench = &.{.scope_collision_gather} },
        .pipeline_plane_traversal => .{ .bench = &.{.plane_entry} },
        .pipeline_tier_policy => .{ .bench = &.{.scope_tier_policy} },
        .pipeline_action_react => .{},
    };
}

comptime {
    // Every batch stage the step records sits in exactly one stage timer.
    @setEvalBranchQuota(20_000);
    for (std.meta.tags(BatchStage)) |batch| {
        var owners: usize = 0;
        for (std.meta.tags(Timing)) |stage| {
            for (stageBatches(stage).logged) |owned| {
                if (owned == batch) owners += 1;
            }
        }
        for (std.meta.tags(BenchTiming)) |stage| {
            for (benchStageBatches(stage).logged) |owned| {
                if (owned == batch) owners += 1;
            }
        }
        if (owners != 1) @compileError("batch stage " ++ @tagName(batch) ++ " needs exactly one stage timer");
    }
    for (std.meta.tags(BenchBatchStage)) |batch| {
        var owners: usize = 0;
        for (std.meta.tags(Timing)) |stage| {
            for (stageBatches(stage).bench) |owned| {
                if (owned == batch) owners += 1;
            }
        }
        for (std.meta.tags(BenchTiming)) |stage| {
            for (benchStageBatches(stage).bench) |owned| {
                if (owned == batch) owners += 1;
            }
        }
        if (owners != 1) @compileError("bench batch stage " ++ @tagName(batch) ++ " needs exactly one stage timer");
    }
}

// The counters the census prints, as means per step.
const census_metrics = [_]Metric{
    .scope_total_entities,
    .scope_movement_stage_entities,
    .scope_cognition_entities,
    .scope_locomotion_entities,
    .scope_kinematic_entities,
    .scope_dormant_entities,
    .scope_ai_stage_entities,
    .scope_stagger_skips,
    .ai_entities,
    .ai_separation_candidate_checks,
    .ai_separation_neighbor_samples,
    .perception_observers,
    .perception_candidate_checks,
    .perception_sensed,
    .perception_nearest_threat_found,
    .steering_agent_candidate_checks,
    .steering_path_requests,
    .collision_bodies,
    .collision_candidate_pairs,
    .collision_contacts,
    .structural_created,
    .structural_destroyed,
    .structural_components_set,
    .simulation_events_dropped,
    .population_capacity_grows,
};

// A body's spawn placement: its level and position.
const Placement = struct {
    level: u16,
    position: math.Vec2,
};

// Row `slot` of `slots_per_level` on a uniform grid over a `level_px` square level.
fn spreadPosition(slot: usize, slots_per_level: usize, level_px: f32) math.Vec2 {
    const side = suite.ceilSqrt(slots_per_level);
    const pitch = level_px / @as(f32, @floatFromInt(side));
    return .{
        .x = (@as(f32, @floatFromInt(slot % side)) + 0.5) * pitch,
        .y = (@as(f32, @floatFromInt(slot / side)) + 0.5) * pitch,
    };
}

// Placement of agent `agent` (`inert == null`) or its `inert`-th inert row. Spread: agents
// round-robin over levels, each level a uniform grid holding its agents and their inert
// rows interleaved. Crowd: a square at `crowd_pitch` centred on the level, all on level 0.
// Stacked: agents fill level 0, then level 1, and on, each level the same centred square.
fn placement(fields: StepFields, level_px: f32, agent: usize, inert: ?usize) Placement {
    const rows_per_agent = @as(usize, fields.inert_per_agent) + 1;
    const slot_in_agent: usize = if (inert) |index| index + 1 else 0;
    switch (fields.shape) {
        .spread => {
            const agents_per_level = (@as(usize, fields.population) + fields.levels - 1) / fields.levels;
            const slot = (agent / fields.levels) * rows_per_agent + slot_in_agent;
            return .{
                .level = @intCast(agent % fields.levels),
                .position = spreadPosition(slot, agents_per_level * rows_per_agent, level_px),
            };
        },
        .crowd => return .{
            .level = 0,
            .position = crowdPosition(agent * rows_per_agent + slot_in_agent, @as(usize, fields.population) * rows_per_agent, level_px),
        },
        .stacked => {
            const agents_per_level = stackedAgentsPerLevel(fields);
            return .{
                .level = @intCast(agent / agents_per_level),
                .position = crowdPosition((agent % agents_per_level) * rows_per_agent + slot_in_agent, agents_per_level * rows_per_agent, level_px),
            };
        },
    }
}

// The index that picks agent `agent`'s archetype: its slot on its level for `stacked`, so
// every level holds the same archetype at the same position; else the agent itself.
fn archetypeSlot(fields: StepFields, agent: usize) usize {
    return if (fields.shape == .stacked) agent % stackedAgentsPerLevel(fields) else agent;
}

fn stackedAgentsPerLevel(fields: StepFields) usize {
    return (@as(usize, fields.population) + fields.levels - 1) / fields.levels;
}

// Row `slot` of `slots` in a square at `crowd_pitch` centred on a `level_px` square level.
fn crowdPosition(slot: usize, slots: usize, level_px: f32) math.Vec2 {
    const side = suite.ceilSqrt(slots);
    const origin = level_px * 0.5 - @as(f32, @floatFromInt(side)) * crowd_pitch * 0.5;
    return .{
        .x = origin + @as(f32, @floatFromInt(slot % side)) * crowd_pitch,
        .y = origin + @as(f32, @floatFromInt(slot / side)) * crowd_pitch,
    };
}

// Commits the population as one batch through the production applier, then places each new
// row on its level through the demo spawn's `placeSpawnedMover`, and grows the pipeline at
// the population seam.
fn spawnPopulation(allocator: std.mem.Allocator, state: *GameDemoState, fields: StepFields) !void {
    const level_px = state.world.worldWidthPixels();
    const rows_per_agent = @as(usize, fields.inert_per_agent) + 1;
    const row_count = @as(usize, fields.population) * rows_per_agent;
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(allocator);
    try commands.ensureTotalCapacity(allocator, row_count);
    for (0..fields.population) |agent| {
        const bundle = state.archetype_catalog.bundleForId(archetype_ids[archetypeSlot(fields, agent) % archetype_ids.len]);
        const agent_place = placement(fields, level_px, agent, null);
        commands.appendAssumeCapacity(.{ .create_entity = .{
            .movement_body = .{ .position = agent_place.position, .previous_position = agent_place.position, .speed = agent_speed },
            .primitive_visual = bodyVisual(),
            .asset_reference = .{ .sprite = .grim_characters },
            .collision_bounds = .{ .size = .{ .x = body_size, .y = body_size } },
            .collision_response = .{ .mode = .bounce, .mobility = .dynamic, .restitution = 1 },
            .world_level = agent_place.level,
            .faction = bundle.faction,
            .ai_agent = bundle.behavior,
            .ai_perception = bundle.perception,
            .ai_memory = bundle.memory,
            .ai_affect = bundle.affect,
            .steering_agent = if (bundle.behavior != null) SteeringAgent{} else null,
        } });
        for (0..fields.inert_per_agent) |inert| {
            const inert_place = placement(fields, level_px, agent, inert);
            commands.appendAssumeCapacity(.{ .create_entity = .{
                .movement_body = .{ .position = inert_place.position, .previous_position = inert_place.position },
                .primitive_visual = bodyVisual(),
                .asset_reference = .{ .sprite = .grim_characters },
                .collision_bounds = .{ .size = .{ .x = body_size, .y = body_size } },
                .world_level = inert_place.level,
                .faction = .neutral,
            } });
        }
    }

    const rows_before = state.data.movementBodySliceConst().entities.len;
    _ = try state.data.applyStructuralCommands(commands.items);
    const movement = state.data.movementBodySliceConst();
    std.debug.assert(movement.entities.len == rows_before + row_count);
    // `stacked` rows are then marked `always_active` (each row's placement and stagger phase
    // kept), so every level's crowd is indexed and its AI rows think.
    for (movement.entities[rows_before..]) |entity| {
        try placeSpawnedMover(&state.data, &state.world, entity);
        if (fields.shape != .stacked) continue;
        var metadata = data_test_support.simulationMetadata(&state.data, entity).?;
        metadata.always_active = true;
        metadata.stagger_phase = keep_stagger_phase;
        try state.data.setSimulationMetadata(entity, metadata);
    }

    // The observer stands at the footprint's centre.
    const player = state.data.movementBodyPtr(state.player.entity).?;
    player.position_x.* = level_px * 0.5;
    player.position_y.* = level_px * 0.5;
    player.previous_x.* = level_px * 0.5;
    player.previous_y.* = level_px * 0.5;

    _ = try state.pipeline.syncPopulationCapacity(&state.simulation_frame, &state.data);
}

// Every movement row's level and the cells the index filed it under per axis, from the
// pre-measure snapshot through the last measured step's build, for the `stacked` separation
// check bound.
const CellSpanRecord = struct {
    const Span = struct { level: u16, min_x: u32, max_x: u32, min_y: u32, max_y: u32 };

    // The movement rows at the snapshot, in row order; no row despawns here.
    entities: []EntityId,
    spans: std.MultiArrayList(Span),
    cell_size: f32,
    cells_x: u32,
    cells_y: u32,

    // Snapshots every row at the positions the next step's index build reads.
    fn init(allocator: std.mem.Allocator, data: *const DataSystem, view: SpatialIndexView) !CellSpanRecord {
        const movement = data.movementBodySliceConst();
        const entities = try allocator.dupe(EntityId, movement.entities);
        errdefer allocator.free(entities);
        var spans: std.MultiArrayList(Span) = .empty;
        errdefer spans.deinit(allocator);
        try spans.resize(allocator, entities.len);
        const columns = spans.slice();
        for (entities, columns.items(.level)) |entity, *level| {
            // The level the index files the row under.
            level.* = (data.bodyLevelFaction(entity) orelse return error.PopulationRowLost).level orelse 0;
        }
        var record = CellSpanRecord{ .entities = entities, .spans = spans, .cell_size = view.cell_size, .cells_x = view.cells_x, .cells_y = view.cells_y };
        @memset(columns.items(.min_x), std.math.maxInt(u32));
        @memset(columns.items(.max_x), 0);
        @memset(columns.items(.min_y), std.math.maxInt(u32));
        @memset(columns.items(.max_y), 0);
        record.widen(data);
        return record;
    }

    fn deinit(self: *CellSpanRecord, allocator: std.mem.Allocator) void {
        self.spans.deinit(allocator);
        allocator.free(self.entities);
        self.* = undefined;
    }

    // Widens each row's spans to the cells the next step's index build files it under, read
    // from the dense previous-position columns (`SpatialIndexSystem`'s fill reads them) in
    // row order.
    fn widen(self: *CellSpanRecord, data: *const DataSystem) void {
        const movement = data.movementBodySliceConst();
        std.debug.assert(movement.entities.len == self.entities.len);
        const columns = self.spans.slice();
        for (movement.previous_x, movement.previous_y, columns.items(.min_x), columns.items(.max_x), columns.items(.min_y), columns.items(.max_y)) |x, y, *min_x, *max_x, *min_y, *max_y| {
            const cell_x = math.worldPosToCell(x, self.cell_size, self.cells_x);
            const cell_y = math.worldPosToCell(y, self.cell_size, self.cells_y);
            min_x.* = @min(min_x.*, cell_x);
            max_x.* = @max(max_x.*, cell_x);
            min_y.* = @min(min_y.*, cell_y);
            max_y.* = @max(max_y.*, cell_y);
        }
    }

    fn expectRowsUnchanged(self: *const CellSpanRecord, data: *const DataSystem) !void {
        const entities = data.movementBodySliceConst().entities;
        if (entities.len != self.entities.len) return error.PopulationRowsChanged;
        for (self.entities, entities) |snapshot, live| if (!snapshot.eql(live)) return error.PopulationRowsChanged;
    }

    // The most cells any row crossed on one axis since the snapshot.
    fn maxDrift(self: *const CellSpanRecord) u32 {
        const columns = self.spans.slice();
        var most: u32 = 0;
        for (columns.items(.min_x), columns.items(.max_x), columns.items(.min_y), columns.items(.max_y)) |min_x, max_x, min_y, max_y| most = @max(most, max_x - min_x, max_y - min_y);
        return most;
    }

    // The most rows of one level whose spans reach one query's scan box of `scan_radius`
    // cells. A row reaches the boxes of the query cells its spans' own boxes cover; per level,
    // each row adds one over that rectangle of a difference table, whose summed-area pass
    // gives every query cell its count.
    fn oneLevelBoxBound(self: *const CellSpanRecord, allocator: std.mem.Allocator, levels: u16, scan_radius: u32) !usize {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const columns = self.spans.slice();
        const row_levels = columns.items(.level);

        // Rows bucketed by level: level l's rows are `by_level[level_starts[l]..level_starts[l + 1]]`.
        const level_starts = try arena.alloc(usize, @as(usize, levels) + 1);
        @memset(level_starts, 0);
        for (row_levels) |level| {
            if (level >= levels) return error.RowLevelPastWorld;
            level_starts[level + 1] += 1;
        }
        for (1..level_starts.len) |level| level_starts[level] += level_starts[level - 1];
        const cursors = try arena.dupe(usize, level_starts[0..levels]);
        const by_level = try arena.alloc(u32, row_levels.len);
        for (row_levels, 0..) |level, row| {
            // Movement rows fit u32, as the index's population rows do.
            by_level[cursors[level]] = @intCast(row);
            cursors[level] += 1;
        }

        var most: usize = 0;
        for (0..levels) |level| {
            const rows = by_level[level_starts[level]..level_starts[level + 1]];
            if (rows.len == 0) continue;
            // The query cells any of the level's rows reaches, so the table covers only them.
            var window = Reach{ .min_x = std.math.maxInt(u32), .max_x = 0, .min_y = std.math.maxInt(u32), .max_y = 0 };
            for (rows) |row| {
                const reach = self.reachOf(columns, row, scan_radius);
                window = .{ .min_x = @min(window.min_x, reach.min_x), .max_x = @max(window.max_x, reach.max_x), .min_y = @min(window.min_y, reach.min_y), .max_y = @max(window.max_y, reach.max_y) };
            }
            const width: usize = window.max_x - window.min_x + 1;
            const height: usize = window.max_y - window.min_y + 1;
            const stride = width + 1;
            const table = try arena.alloc(i32, stride * (height + 1));
            @memset(table, 0);
            for (rows) |row| {
                const reach = self.reachOf(columns, row, scan_radius);
                const x0: usize = reach.min_x - window.min_x;
                const x1: usize = reach.max_x - window.min_x + 1;
                const y0: usize = reach.min_y - window.min_y;
                const y1: usize = reach.max_y - window.min_y + 1;
                table[y0 * stride + x0] += 1;
                table[y0 * stride + x1] -= 1;
                table[y1 * stride + x0] -= 1;
                table[y1 * stride + x1] += 1;
            }
            for (0..height) |y| {
                for (0..width) |x| {
                    var count = table[y * stride + x];
                    if (x > 0) count += table[y * stride + x - 1];
                    if (y > 0) count += table[(y - 1) * stride + x];
                    if (x > 0 and y > 0) count -= table[(y - 1) * stride + x - 1];
                    table[y * stride + x] = count;
                    // A count of rows: non-negative.
                    most = @max(most, @as(usize, @intCast(count)));
                }
            }
        }
        return most;
    }

    // Query cells `[min, max]` per axis whose scan box reaches a row's spans.
    const Reach = struct { min_x: u32, max_x: u32, min_y: u32, max_y: u32 };

    fn reachOf(self: *const CellSpanRecord, columns: std.MultiArrayList(Span).Slice, row: u32, scan_radius: u32) Reach {
        return .{
            .min_x = boxAxisCells(columns.items(.min_x)[row], scan_radius, self.cells_x).min,
            .max_x = boxAxisCells(columns.items(.max_x)[row], scan_radius, self.cells_x).max,
            .min_y = boxAxisCells(columns.items(.min_y)[row], scan_radius, self.cells_y).min,
            .max_y = boxAxisCells(columns.items(.max_y)[row], scan_radius, self.cells_y).max,
        };
    }
};

// The `stacked` pass shape per config: separation checks per thinking row within the most
// rows of one level any query's scan box holds, and that bound below the query's check
// budget, so a query that also reads other levels fails it.
fn checkStackedSeparation(allocator: std.mem.Allocator, summary: *suite.ProductionStepSummary, fields: StepFields, record: *const CellSpanRecord) !void {
    const scan_radius: u32 = @intCast(cellScanRadius(separation_radius, record.cell_size));
    const bound = try record.oneLevelBoxBound(allocator, fields.levels, scan_radius);
    summary.separation_check_bound = bound;
    summary.max_cell_drift = record.maxDrift();
    if (bound >= max_separation_candidate_checks) return error.SeparationBoundAtCheckBudget;
    // Census counters are floored per-step means of the same steps: a mean under the bound
    // per thinking row stays under it with one more row.
    const thinking = summary.metrics.get(.scope_ai_stage_entities);
    if (thinking == 0) return error.NoThinkingRows;
    if (summary.metrics.get(.ai_separation_candidate_checks) > (thinking + 1) * bound) return error.SeparationChecksPastOneLevel;
}

fn bodyVisual() PrimitiveVisual {
    return .{
        .size = .{ .x = body_size, .y = body_size },
        .color = .{ .r = 0.5, .g = 0.6, .b = 0.7, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    };
}

// One engine fixed step minus the state-stack dispatch and the audio drain: a fresh perf
// log bound, the audio buffer's step begun, then the state's update.
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

    // The step's wall time.
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

// One batch stage's calls over the measured steps: how many, the items they carried (the
// fewest and most in one call), and their summed duration.
const BatchShape = struct {
    calls: u64 = 0,
    items: u64 = 0,
    min_items: u64 = 0,
    max_items: u64 = 0,
    duration_ns: u128 = 0,

    // `batch`: one step's aggregate of the stage.
    fn add(self: *BatchShape, batch: anytype) void {
        if (batch.calls == 0) return;
        self.min_items = if (self.calls == 0) batch.min_items else @min(self.min_items, batch.min_items);
        self.max_items = @max(self.max_items, batch.max_items);
        self.calls += batch.calls;
        self.items += batch.items;
        self.duration_ns += batch.total_duration_ns;
    }
};

// Sums of the measured steps' perf-log reads.
const Census = struct {
    steps: usize = 0,
    main_ns: u128 = 0,
    untimed_ns: u128 = 0,
    stage_wall_ns: std.enums.EnumArray(Timing, u128) = .initFill(0),
    batch_off_main_ns: std.enums.EnumArray(BatchStage, u128) = .initFill(0),
    batch_threaded_steps: std.enums.EnumArray(BatchStage, usize) = .initFill(0),
    batch_recorded_steps: std.enums.EnumArray(BatchStage, usize) = .initFill(0),
    bench_batch_off_main_ns: std.enums.EnumArray(BenchBatchStage, u128) = .initFill(0),
    bench_batch_threaded_steps: std.enums.EnumArray(BenchBatchStage, usize) = .initFill(0),
    bench_batch_recorded_steps: std.enums.EnumArray(BenchBatchStage, usize) = .initFill(0),
    batch_shapes: std.enums.EnumArray(BatchStage, BatchShape) = .initFill(.{}),
    bench_batch_shapes: std.enums.EnumArray(BenchBatchStage, BatchShape) = .initFill(.{}),
    bench_stage_wall_ns: std.enums.EnumArray(BenchTiming, u128) = .initFill(0),
    metrics: std.enums.EnumArray(Metric, u128) = .initFill(0),

    // One stage's step: whether it ran, and its off-main time when every call ran on workers.
    fn addBatch(calls: u64, threaded_calls: u64, total_duration_ns: u64, recorded: *usize, threaded: *usize, off_main: *u128) u64 {
        if (calls == 0) return 0;
        recorded.* += 1;
        if (threaded_calls != calls) return 0;
        threaded.* += 1;
        off_main.* += total_duration_ns;
        return total_duration_ns;
    }

    fn add(self: *Census, log: *const runtime_perf_log.RuntimePerfLog, step_batches: *const runtime_perf_log.StepBatches, step_ns: u64) void {
        self.steps += 1;
        var timed_ns: u64 = 0;
        for (std.meta.tags(Timing)) |stage| {
            const wall_ns = log.timings[@backingInt(stage)].total_ns;
            self.stage_wall_ns.getPtr(stage).* += wall_ns;
            if (isTopLevelStage(stage)) timed_ns += wall_ns;
        }
        for (std.meta.tags(BenchTiming)) |stage| {
            const wall_ns = step_batches.timings[@backingInt(stage)].total_ns;
            self.bench_stage_wall_ns.getPtr(stage).* += wall_ns;
            timed_ns += wall_ns;
        }
        var off_main_ns: u64 = 0;
        // A step counts off main only when every call of the stage ran on workers.
        for (std.meta.tags(BatchStage)) |stage| {
            const batch = log.batches[@backingInt(stage)];
            off_main_ns += addBatch(batch.calls, batch.threaded_calls, batch.total_duration_ns, self.batch_recorded_steps.getPtr(stage), self.batch_threaded_steps.getPtr(stage), self.batch_off_main_ns.getPtr(stage));
            self.batch_shapes.getPtr(stage).add(batch);
        }
        for (std.meta.tags(BenchBatchStage)) |stage| {
            const batch = step_batches.batches[@backingInt(stage)];
            off_main_ns += addBatch(batch.calls, batch.threaded_calls, batch.total_duration_ns, self.bench_batch_recorded_steps.getPtr(stage), self.bench_batch_threaded_steps.getPtr(stage), self.bench_batch_off_main_ns.getPtr(stage));
            self.bench_batch_shapes.getPtr(stage).add(batch);
        }
        for (std.meta.tags(Metric)) |metric| self.metrics.getPtr(metric).* += log.metrics[@backingInt(metric)];
        self.main_ns += step_ns -| off_main_ns;
        self.untimed_ns += step_ns -| timed_ns;
    }

    fn finish(self: *const Census, population: usize) suite.ProductionStepSummary {
        var summary = suite.ProductionStepSummary{ .population = population, .measured_steps = self.steps };
        if (self.steps == 0) return summary;
        const steps: u128 = self.steps;
        summary.main_ns = @intCast(self.main_ns / steps);
        summary.untimed_ns = @intCast(self.untimed_ns / steps);
        for (std.meta.tags(Timing)) |stage| summary.stage_wall_ns.set(stage, @intCast(self.stage_wall_ns.get(stage) / steps));
        for (std.meta.tags(BenchTiming)) |stage| summary.bench_stage_wall_ns.set(stage, @intCast(self.bench_stage_wall_ns.get(stage) / steps));
        for (std.meta.tags(BatchStage)) |stage| {
            summary.batch_off_main_ns.set(stage, @intCast(self.batch_off_main_ns.get(stage) / steps));
            summary.batch_threaded_steps.set(stage, self.batch_threaded_steps.get(stage));
            summary.batch_recorded_steps.set(stage, self.batch_recorded_steps.get(stage));
        }
        for (std.meta.tags(BenchBatchStage)) |stage| {
            summary.bench_batch_off_main_ns.set(stage, @intCast(self.bench_batch_off_main_ns.get(stage) / steps));
            summary.bench_batch_threaded_steps.set(stage, self.bench_batch_threaded_steps.get(stage));
            summary.bench_batch_recorded_steps.set(stage, self.bench_batch_recorded_steps.get(stage));
        }
        for (std.meta.tags(Metric)) |metric| summary.metrics.set(metric, @intCast(self.metrics.get(metric) / steps));
        return summary;
    }

    // Every batch that ran, under its top-level stage: calls per measured step, items per
    // call (mean, fewest-most), mean duration per call, the measured steps it ran on, and of
    // those the steps every call ran on workers.
    fn printBatchShapes(self: *const Census) void {
        std.debug.print("  batches over {} measured steps:\n", .{self.steps});
        for (std.meta.tags(Timing)) |stage| self.printStageBatchShapes(@tagName(stage), stageBatches(stage));
        for (std.meta.tags(BenchTiming)) |stage| self.printStageBatchShapes(@tagName(stage), benchStageBatches(stage));
    }

    fn printStageBatchShapes(self: *const Census, stage: []const u8, batches: StageBatches) void {
        for (batches.logged) |batch| self.printBatchShape(stage, @tagName(batch), self.batch_shapes.get(batch), self.batch_recorded_steps.get(batch), self.batch_threaded_steps.get(batch));
        for (batches.bench) |batch| self.printBatchShape(stage, @tagName(batch), self.bench_batch_shapes.get(batch), self.bench_batch_recorded_steps.get(batch), self.bench_batch_threaded_steps.get(batch));
    }

    fn printBatchShape(self: *const Census, stage: []const u8, name: []const u8, shape: BatchShape, recorded_steps: usize, threaded_steps: usize) void {
        if (shape.calls == 0) return;
        std.debug.print("    {s} {s} calls/step={d:.2} items/call={} ({}-{}) ns/call={f} ran={}/{} threaded={}/{}\n", .{
            stage,
            name,
            @as(f64, @floatFromInt(shape.calls)) / @as(f64, @floatFromInt(self.steps)),
            shape.items / shape.calls,
            shape.min_items,
            shape.max_items,
            suite.formatDuration(@intCast(shape.duration_ns / shape.calls)),
            recorded_steps,
            self.steps,
            threaded_steps,
            recorded_steps,
        });
    }
};

// Every `GameDemoState` tuner's counts by field path, taken before the measured steps; the
// counts after them print as deltas. The walk after the measured steps must visit the
// snapshot's paths in the same order, or the case fails: a tuner that appeared or went away
// (a set or cleared optional) has no delta.
const TunerCensus = struct {
    const Entry = struct { path: []const u8, counts: TunerCounts };

    entries: std.ArrayList(Entry) = .empty,

    fn init(allocator: std.mem.Allocator, state: *GameDemoState) !TunerCensus {
        var counter = CountVisitor{};
        forEachTunerIn(GameDemoState, state, "state", &counter);
        var census = TunerCensus{};
        try census.entries.ensureTotalCapacity(allocator, counter.count);
        var snapshot = SnapshotVisitor{ .entries = &census.entries };
        forEachTunerIn(GameDemoState, state, "state", &snapshot);
        return census;
    }

    fn deinit(self: *TunerCensus, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    fn printDeltas(self: *const TunerCensus, state: *GameDemoState) !void {
        std.debug.print("  tuners changed over the measured steps (of {}):\n", .{self.entries.items.len});
        var deltas = DeltaVisitor{ .entries = self.entries.items };
        forEachTunerIn(GameDemoState, state, "state", &deltas);
        if (deltas.mismatched or deltas.cursor != self.entries.items.len) {
            std.debug.print("production-step: the tuners after the measured steps are not the snapshot's ({} of {} matched)\n", .{ deltas.cursor, self.entries.items.len });
            return error.TunerSetChanged;
        }
        if (deltas.changed == 0) std.debug.print("    none\n", .{});
    }

    const CountVisitor = struct {
        count: usize = 0,

        pub fn visit(self: *CountVisitor, comptime _: []const u8, _: *AdaptiveWorkTuner) void {
            self.count += 1;
        }
    };

    const SnapshotVisitor = struct {
        entries: *std.ArrayList(Entry),

        pub fn visit(self: *SnapshotVisitor, comptime path: []const u8, tuner: *AdaptiveWorkTuner) void {
            self.entries.appendAssumeCapacity(.{ .path = path, .counts = .of(tuner) });
        }
    };

    // Matches each visited tuner to the snapshot entry at its position; the first mismatch
    // stops the deltas.
    const DeltaVisitor = struct {
        entries: []const Entry,
        cursor: usize = 0,
        changed: usize = 0,
        mismatched: bool = false,

        pub fn visit(self: *DeltaVisitor, comptime path: []const u8, tuner: *AdaptiveWorkTuner) void {
            if (self.mismatched) return;
            if (self.cursor == self.entries.len or !std.mem.eql(u8, self.entries[self.cursor].path, path)) {
                self.mismatched = true;
                return;
            }
            const before = self.entries[self.cursor].counts;
            self.cursor += 1;
            const delta = TunerCounts.of(tuner).since(before);
            if (!delta.any()) return;
            self.changed += 1;
            // Four counts of at most 20 digits and their labels, then the tuner's state.
            var line: [192]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&line);
            delta.write(&writer) catch {};
            writer.writeByte(' ') catch {};
            suite.writeTunerState(&writer, tuner) catch {};
            std.debug.print("    {s} {s}\n", .{ path, writer.buffered() });
        }
    };
};

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const fields = try StepCode.decode(item_count);
    std.debug.assert(fields.levels >= 1 and fields.population >= 1);

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();

    var tileset = try fixtures.loadTilesetMeta(allocator, io);
    defer tileset.deinit();
    const dig_config = try DigConfig.fromMeta(&tileset);
    // The state first: nothing fallible sits between the world build and `initWithWorld`.
    const state = try allocator.create(GameDemoState);
    defer allocator.destroy(state);
    var world = try fixtures.buildBandedWorld(allocator, &tileset, fields.level_side, fields.levels, "grass", "grass");
    const world_px = world.worldWidthPixels();
    // `initWithWorld` owns `world` from here, on failure too.
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
    const rows_before = state.data.movementBodySliceConst().entities.len;
    try spawnPopulation(allocator, state, fields);
    const population = state.data.movementBodySliceConst().entities.len;
    std.debug.assert(population == rows_before + @as(usize, fields.population) * (@as(usize, fields.inert_per_agent) + 1));
    // The step census snapshots every state tuner.
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

    // Every case runs the tuned case's pre-measure steps, so each measures the same simulated
    // state (paths requested and solved, positions); the serial case's stages run inline.
    const settle_steps = suite.adaptiveSettleIterationLimit(options);
    const warmup_steps = options.warmup_iterations + settle_steps;
    for (0..warmup_steps) |_| _ = try step.run();
    // Whether every tuner the measured steps run settled in that fixed count; a tuner they do
    // not run (the rebuild tuners run only at the world's create and a nav or collider
    // rebuild) is idle.
    var settle = suite.TunerSettle{};
    settle.addAll(GameDemoState, state, "state");
    var accumulator = suite.StatsAccumulator.init(item_count);
    var census = Census{};
    var tuner_census: ?TunerCensus = if (options.details) try TunerCensus.init(allocator, state) else null;
    defer if (tuner_census) |*census_of_tuners| census_of_tuners.deinit(allocator);
    // Each measured step's queries read the index its build files from the positions the step
    // before it left.
    var span_record: ?CellSpanRecord = if (fields.shape == .stacked)
        try CellSpanRecord.init(allocator, &state.data, state.pipeline.spatial_index.view())
    else
        null;
    defer if (span_record) |*record| record.deinit(allocator);
    for (0..options.iterations) |iteration| {
        const step_ns = try step.run();
        accumulator.record(step_ns, .{});
        census.add(&step.perf_log, &step.step_batches, step_ns);
        if (span_record) |*record| if (iteration + 1 < options.iterations) record.widen(&state.data);
    }
    if (options.details) {
        std.debug.print("  census production-step {} {s}:\n", .{ item_count, case.name });
        census.printBatchShapes();
        try tuner_census.?.printDeltas(state);
    }
    var stats = accumulator.finish();
    stats.items_per_second = suite.itemsPerSecond(population, stats.mean_ns);
    stats.batch_carried = false;
    stats.output_count = population;
    stats.production_step = census.finish(population);
    if (span_record) |*record| {
        try record.expectRowsUnchanged(&state.data);
        try checkStackedSeparation(allocator, &stats.production_step.?, fields, record);
    }
    if (case.adaptive) stats.tuner_settle = settle.measured();
    if (threads.workerThreadCount() > 0) try checkPinnedDispatch(&step, &stats.details);
    return stats;
}

// The items per range every tuner is pinned to: one item, so every stage whose items span
// more than one aligned range has a multi-range partition to dispatch.
const pinned_items_per_range: usize = 1;

// The step's dispatch check: with every `GameDemoState` tuner pinned to a threaded profile
// of all workers, one more step runs, and every stage it records whose calls cover more
// ranges than calls ran every call on workers. Each checked stage is listed in `details`.
fn checkPinnedDispatch(step: *StepRunner, details: *suite.DetailLines) !void {
    pinTunersIn(GameDemoState, step.state, .{ .worker_threads = step.threads.workerThreadCount(), .items_per_range = pinned_items_per_range });
    _ = try step.run();
    details.print("pinned dispatch:", .{});
    for (std.meta.tags(BatchStage)) |stage| try checkPinnedStage(details, @tagName(stage), step.perf_log.batches[@backingInt(stage)]);
    for (std.meta.tags(BenchBatchStage)) |stage| try checkPinnedStage(details, @tagName(stage), step.step_batches.batches[@backingInt(stage)]);
    details.print("\n", .{});
}

fn checkPinnedStage(details: *suite.DetailLines, name: []const u8, batch: anytype) !void {
    if (batch.ranges <= batch.calls) return;
    details.print(" {s}:threaded={}/{}", .{ name, batch.threaded_calls, batch.calls });
    if (batch.threaded_calls == batch.calls) return;
    std.debug.print("production-step: stage {s} ran {} of {} calls over {} ranges inline under a threaded pin\n", .{ name, batch.calls - batch.threaded_calls, batch.calls, batch.ranges });
    return error.PinnedStageRanInline;
}

// A top-level stage timer: one the perf log records, or a bench-only one the census's sink
// receives.
const Stage = union(enum) {
    logged: Timing,
    bench: BenchTiming,

    fn name(self: Stage) []const u8 {
        return switch (self) {
            inline else => |stage| @tagName(stage),
        };
    }

    fn batches(self: Stage) StageBatches {
        return switch (self) {
            .logged => |stage| stageBatches(stage),
            .bench => |stage| benchStageBatches(stage),
        };
    }

    fn wallNs(self: Stage, summary: *const suite.ProductionStepSummary) u64 {
        return switch (self) {
            .logged => |stage| summary.stage_wall_ns.get(stage),
            .bench => |stage| summary.bench_stage_wall_ns.get(stage),
        };
    }
};

const stage_count = std.meta.tags(Timing).len + std.meta.tags(BenchTiming).len;

// The top-level stages that ran, both channels, most main-thread time first.
fn stagesByMain(summary: *const suite.ProductionStepSummary, out: *[stage_count]Stage) []Stage {
    var count: usize = 0;
    for (std.meta.tags(Timing)) |stage| {
        if (!isTopLevelStage(stage) or summary.stage_wall_ns.get(stage) == 0) continue;
        out[count] = .{ .logged = stage };
        count += 1;
    }
    for (std.meta.tags(BenchTiming)) |stage| {
        if (summary.bench_stage_wall_ns.get(stage) == 0) continue;
        out[count] = .{ .bench = stage };
        count += 1;
    }
    std.mem.sort(Stage, out[0..count], summary, moreMainFirst);
    return out[0..count];
}

fn moreMainFirst(summary: *const suite.ProductionStepSummary, lhs: Stage, rhs: Stage) bool {
    return stageMainNs(summary, lhs) > stageMainNs(summary, rhs);
}

fn stageOffMainNs(summary: *const suite.ProductionStepSummary, stage: Stage) u64 {
    const batches = stage.batches();
    var off_main_ns: u64 = 0;
    for (batches.logged) |batch| off_main_ns += summary.batch_off_main_ns.get(batch);
    for (batches.bench) |batch| off_main_ns += summary.bench_batch_off_main_ns.get(batch);
    return off_main_ns;
}

fn stageMainNs(summary: *const suite.ProductionStepSummary, stage: Stage) u64 {
    return stage.wallNs(summary) -| stageOffMainNs(summary, stage);
}

// A stage line's batch: the measured steps it ran on, and of those the steps every call ran
// on workers.
const batch_steps_format = " {s}(ran={}/{} threaded={}/{})";

fn writeStepWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("rows={}", .{stats.output_count});
    const summary_value = stats.production_step orelse return;
    const summary = &summary_value;
    try suite.writeShare(writer, "main", summary.main_ns, stats.mean_ns);
    try suite.writeShare(writer, "untimed", summary.untimed_ns, stats.mean_ns);
    try writer.print(" tiers={}/{}/{}/{} thinking={}", .{
        summary.metrics.get(.scope_cognition_entities),
        summary.metrics.get(.scope_locomotion_entities),
        summary.metrics.get(.scope_kinematic_entities),
        summary.metrics.get(.scope_dormant_entities),
        summary.metrics.get(.scope_ai_stage_entities),
    });
    const thinking: f64 = @floatFromInt(@max(summary.metrics.get(.scope_ai_stage_entities), 1));
    try writer.print(" separation_per_thinking={d:.2}/{d:.2}", .{
        @as(f64, @floatFromInt(summary.metrics.get(.ai_separation_candidate_checks))) / thinking,
        @as(f64, @floatFromInt(summary.metrics.get(.ai_separation_neighbor_samples))) / thinking,
    });
    if (summary.separation_check_bound) |bound| try writer.print(" check_bound={} drift={}", .{ bound, summary.max_cell_drift });
    var stage_buffer: [stage_count]Stage = undefined;
    const stages = stagesByMain(summary, &stage_buffer);
    try writer.writeAll(" top_main=");
    for (stages[0..@min(stages.len, 3)], 0..) |stage, index| {
        if (index != 0) try writer.writeByte(',');
        const name = stage.name();
        try writer.print("{s}:{f}", .{ name[std.mem.indexOfScalar(u8, name, '_').? + 1 ..], suite.formatDuration(stageMainNs(summary, stage)) });
    }
    if (view == .summary) return;

    for (stages) |stage| {
        try writer.print("\n    stage {s} wall={f} off_main={f} main={f}", .{
            stage.name(),
            suite.formatDuration(stage.wallNs(summary)),
            suite.formatDuration(stageOffMainNs(summary, stage)),
            suite.formatDuration(stageMainNs(summary, stage)),
        });
        const batches = stage.batches();
        for (batches.logged) |batch| {
            const recorded = summary.batch_recorded_steps.get(batch);
            if (recorded != 0) try writer.print(batch_steps_format, .{ @tagName(batch), recorded, summary.measured_steps, summary.batch_threaded_steps.get(batch), recorded });
        }
        for (batches.bench) |batch| {
            const recorded = summary.bench_batch_recorded_steps.get(batch);
            if (recorded != 0) try writer.print(batch_steps_format, .{ @tagName(batch), recorded, summary.measured_steps, summary.bench_batch_threaded_steps.get(batch), recorded });
        }
    }
    try writer.writeAll("\n    nested");
    for (std.meta.tags(Timing)) |stage| {
        if (isTopLevelStage(stage) or summary.stage_wall_ns.get(stage) == 0) continue;
        try writer.print(" {s}={f}", .{ @tagName(stage), suite.formatDuration(summary.stage_wall_ns.get(stage)) });
    }
    try writer.writeAll("\n    counters");
    for (census_metrics) |metric| try writer.print(" {s}={}", .{ @tagName(metric), summary.metrics.get(metric) });
}
