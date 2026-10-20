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
//! Each sample binds a fresh runtime perf log: `main` is the step's wall time minus the
//! off-main time of the logged batches that ran on workers (an upper bound: unlogged batches
//! count as main), and `untimed` is the wall time no top-level stage timer holds. `tiers=`
//! splits the rows by scope tier (cognition/locomotion/kinematic/dormant), `thinking=` counts
//! the rows the AI stage ran, `separation_per_thinking=` the AI separation candidate checks
//! and neighbor samples per thinking row, and `top_main=` names the three top-level stages
//! with the most main time. `--details` adds `shared_tuner=` (the thread system's shared
//! tuner after the run: phase, samples, settled windows), each top-level stage's `wall=`,
//! `off_main=`, and `main=` with its batches' `threaded=` steps over the measured steps, the
//! nested stage timers, and the census counters as means per step. ReleaseFast compiles the
//! log out, so only the step total prints there.
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

const std = @import("std");
const AudioCommandBuffer = @import("../app/audio.zig").AudioCommandBuffer;
const InputState = @import("../app/input.zig").InputState;
const runtime_perf_log = @import("../app/runtime_perf_log.zig");
const StateTransitions = @import("../app/state.zig").StateTransitions;
const AdaptiveWorkReport = suite.AdaptiveWorkReport;
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
const max_separation_candidate_checks = @import("../game/systems/ai.zig").max_separation_candidate_checks;
const separation_radius = @import("../game/systems/ai.zig").separation_radius;
const boxAxisCells = @import("../game/systems/spatial_index.zig").boxAxisCells;
const cellScanRadius = @import("../game/systems/spatial_index.zig").cellScanRadius;
const SpatialIndexView = @import("../game/systems/spatial_index.zig").SpatialIndexView;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

const BatchStage = runtime_perf_log.BatchStage;
const Metric = runtime_perf_log.Metric;
const Timing = runtime_perf_log.Timing;

pub const group = suite.BenchmarkGroup{
    .name = "production-step",
    .item_label = StepCode.label,
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

// The logged batch stages that run inside each top-level stage timer, for the per-stage
// main-thread split.
fn stageBatches(stage: Timing) []const BatchStage {
    return switch (stage) {
        .pipeline_spatial_index => &.{.spatial_index_build},
        .pipeline_perception => &.{.perception},
        .pipeline_ai => &.{ .ai_separation, .ai_intent },
        .pipeline_steering => &.{.steering},
        .pipeline_pathfinding => &.{ .path_solve, .path_intake, .path_registry_flush, .path_resize_copy },
        .pipeline_movement => &.{.movement},
        .pipeline_collision => &.{ .collision_fill, .collision_sort, .collision_broadphase, .collision_narrowphase, .collision_static_pairs },
        .pipeline_chunk_derive => &.{.chunk_derive},
        .gameplay_particles => &.{.particles},
        .gameplay_structural => &.{ .static_collider_splice, .nav_remask, .nav_connect, .nav_closure, .nav_evict },
        else => &.{},
    };
}

comptime {
    // Every batch stage the step logs sits in exactly one stage timer; sprite prep runs in
    // render, outside the step.
    @setEvalBranchQuota(20_000);
    for (std.meta.tags(BatchStage)) |batch| {
        var owners: usize = 0;
        for (std.meta.tags(Timing)) |stage| {
            for (stageBatches(stage)) |owned| {
                if (owned == batch) owners += 1;
            }
        }
        const expected: usize = if (batch == .sprite_prep) 0 else 1;
        if (owners != expected) @compileError("batch stage " ++ @tagName(batch) ++ " needs exactly one stage timer");
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
    // `stacked` rows are `always_active`, so every level's crowd is indexed and its AI rows
    // think.
    for (movement.entities[rows_before..]) |entity| try placeSpawnedMover(&state.data, &state.world, entity, fields.shape == .stacked);

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

    // The step's wall time.
    fn run(self: *StepRunner) !u64 {
        self.perf_log = runtime_perf_log.RuntimePerfLog.init(0);
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
            .perf = runtime_perf_log.Context.bind(&self.perf_log),
        });
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(self.io));
        std.debug.assert(self.state.simulation_frame.phase == .finished);
        return elapsed_ns;
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
    metrics: std.enums.EnumArray(Metric, u128) = .initFill(0),

    fn add(self: *Census, log: *const runtime_perf_log.RuntimePerfLog, step_ns: u64) void {
        self.steps += 1;
        var timed_ns: u64 = 0;
        for (std.meta.tags(Timing)) |stage| {
            const wall_ns = log.timings[@backingInt(stage)].total_ns;
            self.stage_wall_ns.getPtr(stage).* += wall_ns;
            if (isTopLevelStage(stage)) timed_ns += wall_ns;
        }
        var off_main_ns: u64 = 0;
        for (std.meta.tags(BatchStage)) |stage| {
            const batch = log.batches[@backingInt(stage)];
            if (batch.calls == 0) continue;
            self.batch_recorded_steps.getPtr(stage).* += 1;
            // A step counts off main only when every call of the stage ran on workers.
            if (batch.threaded_calls != batch.calls) continue;
            self.batch_threaded_steps.getPtr(stage).* += 1;
            self.batch_off_main_ns.getPtr(stage).* += batch.total_duration_ns;
            off_main_ns += batch.total_duration_ns;
        }
        for (std.meta.tags(Metric)) |metric| self.metrics.getPtr(metric).* += log.metrics[@backingInt(metric)];
        self.main_ns += step_ns -| off_main_ns;
        self.untimed_ns += step_ns -| timed_ns;
    }

    fn finish(self: *const Census, population: usize, shared_tuner: AdaptiveWorkReport) suite.ProductionStepSummary {
        var summary = suite.ProductionStepSummary{ .population = population, .measured_steps = self.steps, .shared_tuner = shared_tuner };
        if (self.steps == 0) return summary;
        const steps: u128 = self.steps;
        summary.main_ns = @intCast(self.main_ns / steps);
        summary.untimed_ns = @intCast(self.untimed_ns / steps);
        for (std.meta.tags(Timing)) |stage| summary.stage_wall_ns.set(stage, @intCast(self.stage_wall_ns.get(stage) / steps));
        for (std.meta.tags(BatchStage)) |stage| {
            summary.batch_off_main_ns.set(stage, @intCast(self.batch_off_main_ns.get(stage) / steps));
            summary.batch_threaded_steps.set(stage, self.batch_threaded_steps.get(stage));
            summary.batch_recorded_steps.set(stage, self.batch_recorded_steps.get(stage));
        }
        for (std.meta.tags(Metric)) |metric| summary.metrics.set(metric, @intCast(self.metrics.get(metric) / steps));
        return summary;
    }
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
    var world = try fixtures.buildBandedWorld(allocator, &tileset, fields.level_side, fields.levels, "grass", "grass");
    const world_px = world.worldWidthPixels();
    const state = try allocator.create(GameDemoState);
    defer allocator.destroy(state);
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

    // The tuned case settles its stage tuners first; the serial case's stages run inline.
    const settle_steps = if (case.adaptive) suite.adaptiveSettleIterationLimit(options) else 0;
    const warmup_steps = options.warmup_iterations + settle_steps;
    for (0..warmup_steps) |_| _ = try step.run();
    var accumulator = suite.StatsAccumulator.init(item_count);
    var census = Census{};
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
        census.add(&step.perf_log, step_ns);
        if (span_record) |*record| if (iteration + 1 < options.iterations) record.widen(&state.data);
    }
    var stats = accumulator.finish();
    stats.items_per_second = suite.itemsPerSecond(population, stats.mean_ns);
    stats.batch_carried = false;
    stats.output_count = population;
    stats.production_step = census.finish(population, suite.tunerReport(&threads.adaptive_tuner));
    if (span_record) |*record| {
        try record.expectRowsUnchanged(&state.data);
        try checkStackedSeparation(allocator, &stats.production_step.?, fields, record);
    }
    return stats;
}

const timing_count = std.meta.tags(Timing).len;

// The top-level stages that ran, most main-thread time first.
fn stagesByMain(summary: *const suite.ProductionStepSummary, out: *[timing_count]Timing) []Timing {
    var count: usize = 0;
    for (std.meta.tags(Timing)) |stage| {
        if (!isTopLevelStage(stage) or summary.stage_wall_ns.get(stage) == 0) continue;
        out[count] = stage;
        count += 1;
    }
    std.mem.sort(Timing, out[0..count], summary, moreMainFirst);
    return out[0..count];
}

fn moreMainFirst(summary: *const suite.ProductionStepSummary, lhs: Timing, rhs: Timing) bool {
    return stageMainNs(summary, lhs) > stageMainNs(summary, rhs);
}

fn stageOffMainNs(summary: *const suite.ProductionStepSummary, stage: Timing) u64 {
    var off_main_ns: u64 = 0;
    for (stageBatches(stage)) |batch| off_main_ns += summary.batch_off_main_ns.get(batch);
    return off_main_ns;
}

fn stageMainNs(summary: *const suite.ProductionStepSummary, stage: Timing) u64 {
    return summary.stage_wall_ns.get(stage) -| stageOffMainNs(summary, stage);
}

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
    var stage_buffer: [timing_count]Timing = undefined;
    const stages = stagesByMain(summary, &stage_buffer);
    try writer.writeAll(" top_main=");
    for (stages[0..@min(stages.len, 3)], 0..) |stage, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{s}:{f}", .{ @tagName(stage)[std.mem.indexOfScalar(u8, @tagName(stage), '_').? + 1 ..], suite.formatDuration(stageMainNs(summary, stage)) });
    }
    if (view == .summary) return;

    const tuner = summary.shared_tuner;
    try writer.print(" shared_tuner={s}/samples:{}/windows:{}", .{ @tagName(tuner.phase), tuner.sample_count, tuner.settled_window_count });
    for (stages) |stage| {
        try writer.print("\n    stage {s} wall={f} off_main={f} main={f}", .{
            @tagName(stage),
            suite.formatDuration(summary.stage_wall_ns.get(stage)),
            suite.formatDuration(stageOffMainNs(summary, stage)),
            suite.formatDuration(stageMainNs(summary, stage)),
        });
        for (stageBatches(stage)) |batch| {
            if (summary.batch_recorded_steps.get(batch) == 0) continue;
            try writer.print(" {s}:threaded={}/{}", .{ @tagName(batch), summary.batch_threaded_steps.get(batch), summary.measured_steps });
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
