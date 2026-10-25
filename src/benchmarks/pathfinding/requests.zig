// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Pathfinding request-load bench groups: the per-step request path (cache, detour,
//! fallback, drain, shared goals, query) and the group-field service.

const std = @import("std");
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const offMainNs = @import("../../app/thread_system.zig").offMainNs;
const math = @import("../../core/math.zig");
const DataSystem = @import("../../game/data_system.zig").DataSystem;
const EntityId = @import("../../game/data_system.zig").EntityId;
const PathRequest = @import("../../game/simulation.zig").PathRequest;
const RangeOutputStream = @import("../../game/simulation.zig").RangeOutputStream;
const PathfindingCapacity = @import("../../game/systems/pathfinding.zig").PathfindingCapacity;
const PathfindingStats = @import("../../game/systems/pathfinding.zig").PathfindingStats;
const PathfindingSystem = @import("../../game/systems/pathfinding.zig").PathfindingSystem;
const default_max_solves_per_frame = @import("../../game/systems/pathfinding.zig").default_max_solves_per_frame;
const pathfinding_range_alignment_items = @import("../../game/systems/pathfinding.zig").pathfinding_range_alignment_items;
const min_capacity_floor = @import("../../game/systems/pathfinding/types.zig").min_capacity_floor;
const AiDir = @import("../../game/systems/ai.zig").AiDir;
const computeRequantizedGoal = @import("../../game/systems/ai.zig").computeRequantizedGoal;
const default_goal_requantization_hysteresis_distance = @import("../../game/systems/ai.zig").default_goal_requantization_hysteresis_distance;
const CellCoord = @import("../../game/world/system.zig").CellCoord;
const default_chunk_size_tiles = @import("../../game/world/system.zig").default_chunk_size_tiles;
const default_group_field_build_budget = @import("../../game/systems/pathfinding/types.zig").default_group_field_build_budget;
const groupFieldResidentBytes = @import("../../game/systems/pathfinding/test_support.zig").groupFieldResidentBytes;
const fixtures = @import("../fixtures.zig");
const suite = @import("../suite.zig");
const coldWarmup = @import("nav_fixtures.zig").coldWarmup;
const coldIterations = @import("nav_fixtures.zig").coldIterations;
const runColdOnce = @import("nav_fixtures.zig").runColdOnce;
const expireCachedResults = @import("nav_fixtures.zig").expireCachedResults;
const StageReport = @import("nav_fixtures.zig").StageReport;
const stepTunerSettle = @import("nav_fixtures.zig").stepTunerSettle;
const OpenWorld = @import("nav_fixtures.zig").OpenWorld;
const buildOpenWorld = @import("nav_fixtures.zig").buildOpenWorld;
const writeLevelZeroCells = @import("nav_fixtures.zig").writeLevelZeroCells;
const RouteFixture = @import("nav_fixtures.zig").RouteFixture;
const initRouteFixture = @import("nav_fixtures.zig").initRouteFixture;
const PlanarRoute = @import("nav_fixtures.zig").PlanarRoute;

// The request-load groups (`pathfinding` through `pathfinding-query`) run world-backed nav on
// one walkable level of a fixed side per layout, so the item count varies the load and never
// the world; every request's route is the same at every count. Each times `update` steps;
// `--details` prints each update stage's busiest shape and the main-thread time per phase.
// Each group's headline batch and tuner is the stage it is judged on: the solve for a cold
// step, intake for a hit-only or folding step (`-cache-*`, `-shared-goal`,
// `-group-field-detour`), the group-field advance for the moving and pack field groups. The
// tuned case settles every step tuner (`stepTunerSettle`) before measuring, at the suite's
// settle limit; the census judges only the tuners that recorded in the measured steps, so a
// hit-only or ready-field step, which runs intake alone, leaves its setup's tuners idle. The
// moving and pack field groups run fixed goal cycles, so the measured fixture never runs a
// settle loop: their tuned case starts from step tuners settled on an identical twin's cycles
// (the march from cycle 0), and its census judges them when measurement begins.
//   - Open routes (`pathfinding`, `-drain`, `-cache-open`, `-query`): request `i`'s goal on a
//     grid of `request_columns` columns from cell (8, 8) of a `request_side`² level, its start
//     (`request_route_dx`, `request_route_dy`) cells further on, a route across several chunks.
//   - `-shared-goal`: the open routes' starts, every request to one far goal.
//   - `-cache-detour`: a full-height wall down the level's middle, open at row
//     `detour_gap_y`; starts in `detour_lanes` lanes left of it, goals mirrored right.
//   - `-hard-fallback*`: a `hard_fallback_side`² level with one blocking cell on every third
//     row's center; each request crosses its row past that cell.

// Cold solve curve: one cold step of distinct-goal requests (every cached result expired
// before it, untimed; a deferred backlog carries over, as in play), solving min(count, the
// per-step solve ceiling) and deferring the rest.
// Items/s is solves serviced. Passes when the time grows linearly to the ceiling and is flat
// past it.
pub const group = suite.BenchmarkGroup{
    .name = "pathfinding",
    .item_label = "path requests",
    .item_counts = &cold_solve_counts,
    .runCase = runCase,
    .write_workload = writeSolveWorkload,
};

// One cold step of requests sharing one goal: one solve, every other request folded into
// its pending entry; the group-field threshold sits above the count, so no field begins.
// Items/s is requests answered. Passes when linear in requests with one solve per step.
pub const dedup_group = suite.BenchmarkGroup{
    .name = "pathfinding-shared-goal",
    .item_label = "path requests to one goal",
    .item_counts = &shared_goal_counts,
    .runCase = runDedupCase,
    .write_workload = writeDedupWorkload,
};

// A drain step: the item count's distinct requests accepted once (untimed), then each timed
// step solves the per-step ceiling of the carried queue over an empty stream. Passes when
// flat in queue depth.
pub const drain_group = suite.BenchmarkGroup{
    .name = "pathfinding-drain",
    .item_label = "queued path requests",
    .item_counts = &drain_counts,
    .runCase = runDrainCase,
    .write_workload = writeSolveWorkload,
};

// One step of open-route requests every one of which the warm cache serves. Passes when
// linear in requests.
pub const fallback_group = suite.BenchmarkGroup{
    .name = "pathfinding-cache-open",
    .item_label = "cached path requests",
    .item_counts = &fallback_counts,
    .runCase = runFallbackCase,
    .write_workload = writeCacheWorkload,
};

// `pathfinding-cache-open` over the detour routes. Passes when linear in requests.
pub const fallback_detour_group = suite.BenchmarkGroup{
    .name = "pathfinding-cache-detour",
    .item_label = "cached detour path requests",
    .item_counts = &fallback_counts,
    .runCase = runFallbackDetourCase,
    .write_workload = writeCacheWorkload,
};

// One cold step of the hard-fallback routes at the full solve budget. Passes when linear in
// requests to the per-step ceiling and flat past it.
pub const hard_fallback_group = suite.BenchmarkGroup{
    .name = "pathfinding-hard-fallback",
    .item_label = "hard fallback path requests",
    .item_counts = &fallback_counts,
    .runCase = runHardFallbackCase,
    .write_workload = writeFallbackWorkload,
};

// `pathfinding-hard-fallback` with solve admissions capped at `hard_fallback_admissions` per
// step (`--fallback-budget` overrides it); the rest defer. Passes when linear in requests to
// the cap and flat past it.
pub const hard_fallback_budget_group = suite.BenchmarkGroup{
    .name = "pathfinding-hard-fallback-budget",
    .item_label = "hard fallback path requests",
    .item_counts = &fallback_counts,
    .runCase = runHardFallbackBudgetCase,
    .write_workload = writeFallbackWorkload,
};

// One cold escalated (tier-1) solve around a full-height wall open only at row 1, the row
// below the level's top border, from a start beside the wall's foot to a goal mirrored
// across it: the longest detour on the level. An untimed step first exhausts the first attempt at a one-node cap, promoting the
// request. The item count is the level side. Passes when every side's detour solves within
// the fixed tier-1 budget, its time following the abstract nodes the search claims: at most
// the detour region's chunks, quadratic in side, and never past the fixed cap.
pub const escalated_detour_group = suite.BenchmarkGroup{
    .name = "pathfinding-escalated-detour",
    .item_label = "level side (cells)",
    .item_counts = &escalated_detour_counts,
    .runCase = runEscalatedDetourCase,
    .write_workload = writeSolveWorkload,
};

// A pack (the item count) sharing one goal across the escalated detour's wall on a
// `group_field_detour_side`² level, sampling a ready group field each step; the field
// builds untimed. Passes when linear in pack size with no field build or solve in the
// timed steps.
pub const group_field_detour_group = suite.BenchmarkGroup{
    .name = "pathfinding-group-field-detour",
    .item_label = "pack agents",
    .item_counts = &group_field_detour_counts,
    .runCase = runGroupFieldDetourCase,
    .write_workload = writeFieldSampleWorkload,
};

// `pathfinding-group-field-detour` with the shared goal moving one new nav cell every
// `group_field_detour_rekey_period_steps` steps; 2 untimed cycles, then times every step of 6
// measured cycles. The tuned case starts from step tuners carried from an identical twin run
// until they settle. Passes when the field serves part of every run, escalated solves stay at
// most one per rekey, and the per-step time is linear in pack size.
pub const group_field_detour_moving_group = suite.BenchmarkGroup{
    .name = "pathfinding-group-field-detour-moving",
    .item_label = "pack agents",
    .item_counts = &group_field_detour_counts,
    .runCase = runGroupFieldDetourMovingCase,
    .write_workload = writeFieldMovingWorkload,
};

// The moving goal advancing every step at the chase speed, its request goal re-keyed only past
// `default_goal_requantization_hysteresis_distance` (`computeRequantizedGoal`). Cycles and the
// tuned case's twin carry as `-moving`. Passes when rewrites stay below the measured steps,
// escalated solves at most one per rewrite, and the per-step time is linear in pack size.
pub const group_field_detour_moving_hysteresis_group = suite.BenchmarkGroup{
    .name = "pathfinding-group-field-detour-moving-hysteresis",
    .item_label = "pack agents",
    .item_counts = &group_field_detour_counts,
    .runCase = runGroupFieldDetourMovingHysteresisCase,
    .write_workload = writeFieldMovingWorkload,
};

// Packs (the item count) of `group_field_pack_agents` agents on an open
// `group_field_detour_side`² level, each with its own goal marching one nav cell per rekey
// cycle, so every pack's field builds at once (one `group_field_expand` item each). Times every
// step of the measured cycles; cycles and the tuned case's twin carry as `-moving`. Passes
// when linear in packs. `--details` prints per-field coverage, blocks, resident bytes, and
// pool growths.
pub const group_field_packs_group = suite.BenchmarkGroup{
    .name = "pathfinding-group-field-packs",
    .item_label = "packs",
    .item_counts = &group_field_packs_item_counts,
    .runCase = runGroupFieldPacksCase,
    .write_workload = writePacksWorkload,
};

// Sparse-coverage fields: four crowds on a 1024² level whose only walkable cells are a
// lattice of 1-wide corridors every nav chunk, each flooding a field capped at the item
// count's cells. One sample rebuilds the four fields from scratch until all are ready; an
// untimed first build warms the fields' block pools. A cap within the per-step build budget
// (`default_group_field_build_budget`, 8192) builds whole in the begin pass
// (`group_field_begin`); a larger cap builds its first budget there and the rest in the
// advance pass (`group_field`) over later steps. The headline batch is the busiest pass batch
// (field count) of a build's steps, and the tuned row's work tuning is the pass that ran it,
// the other its secondary tuning. Passes when linear in the cell cap, every field covering its
// cap.
pub const group_field_tunnel_group = suite.BenchmarkGroup{
    .name = "pathfinding-group-field-tunnel",
    .item_label = "field cell cap",
    .item_counts = &group_field_tunnel_item_counts,
    .runCase = runGroupFieldTunnelCase,
    .write_workload = writeTunnelWorkload,
};

// Per-agent `statusForWorld` against a warm cache, each agent at its own cached path's
// midpoint, so the waypoint scan finds a deep match: the cache probe and waypoint derivation.
// The queries are read-only and fan across workers. Passes when linear in agents.
pub const query_group = suite.BenchmarkGroup{
    .name = "pathfinding-query",
    .item_label = "querying agents",
    .item_counts = &query_counts,
    .runCase = runQueryCase,
    .write_workload = writeQueryWorkload,
};

// Cold solve counts: three below the per-step solve ceiling, the ceiling, and three past it,
// so both regimes show their shape.
const cold_solve_counts = [_]usize{ 128, 256, 384, 512, 1024, 2048, 4096 };
const shared_goal_counts = [_]usize{ 128, 512, 2048 };
// Queue depths past the ceiling, so every drain step solves a full ceiling.
const drain_counts = [_]usize{ 1024, 2048, 4096 };
const fallback_counts = [_]usize{ 16, 64, 128 };
const query_counts = [_]usize{ 256, 1024, 4096 };
// Level sides, in whole chunks, up to the largest whose detour the fixed tier-1 budget solves.
const escalated_detour_counts = [_]usize{ 64, 128, 256 };
// Pack sizes.
const group_field_detour_counts = [_]usize{ 16, 64, 256 };
const group_field_packs_item_counts = [_]usize{ 1, 4, 16 };
const group_field_tunnel_item_counts = [_]usize{ 2048, 16384, 65536 };

fn writeSolveWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("solves={} results={} deferred={}", .{ stats.candidate_pairs, stats.output_count, stats.deferred_count });
}

fn writeDedupWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("answered={} folded={}", .{ stats.output_count, stats.candidate_pairs });
}

fn writeCacheWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("cache_hits={} results={}", .{ stats.candidate_pairs, stats.output_count });
}

fn writeFallbackWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("solve_admissions={} admission_deferred={} deferred={} results={} evictions={}", .{ stats.candidate_pairs, stats.fallback_deferred_count, stats.deferred_count, stats.output_count, stats.cache_evictions });
}

// Under --details, the main thread's share of the query batch, per query.
fn writeQueryWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("warm_paths={} queries={}", .{ stats.candidate_pairs, stats.output_count });
    if (view == .details) try suite.writeMainShare(writer, stats, stats.output_count);
}

fn writeFieldSampleWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("field_samples={} folded={}", .{ stats.candidate_pairs, stats.output_count });
}

fn writeFieldMovingWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("escalated={} throttled={} fields_built={} field_samples={}", .{ stats.output_count, stats.candidate_pairs, stats.deferred_count, stats.sample_count });
}

fn writePacksWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("fields_built={} field_samples={}", .{ stats.output_count, stats.candidate_pairs });
}

fn writeTunnelWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("cells_covered={}", .{stats.output_count});
}

// Request-load layouts. Open routes: request `i`'s goal on a grid of `request_columns`
// columns from (8, 8), its start (`request_route_dx`, `request_route_dy`) cells on.
const request_side: u16 = 512;
const request_route_dx: u16 = 64;
const request_route_dy: u16 = 32;
const request_columns: usize = request_side - 16 - request_route_dx;
// Detour routes: lanes beside the middle wall, open at this row.
const detour_lanes: usize = 64;
const detour_gap_y: u16 = 64;
// Hard-fallback routes: one row of requests every third row, each blocked by its row's center
// cell.
const hard_fallback_side: u16 = 128;
const hard_fallback_lanes: usize = (hard_fallback_side - 4) / 3;
const hard_fallback_columns: usize = hard_fallback_side / 2 - 1;

const Workload = enum {
    unique_open,
    common_goal,
    blocked_detour,
    hard_fallback,

    fn side(self: Workload) u16 {
        return if (self == .hard_fallback) hard_fallback_side else request_side;
    }

    // The most requests the layout holds, each its own start.
    fn capacity(self: Workload) usize {
        return switch (self) {
            .unique_open, .common_goal => request_columns * (request_side - 16 - request_route_dy - 8),
            .blocked_detour => detour_lanes * ((detour_gap_y - 8) / 2),
            .hard_fallback => hard_fallback_lanes * hard_fallback_columns,
        };
    }

    fn route(self: Workload, index: usize) PlanarRoute {
        return switch (self) {
            .unique_open, .common_goal => blk: {
                const goal = CellCoord{ .x = @intCast(8 + index % request_columns), .y = @intCast(8 + index / request_columns) };
                const start = CellCoord{ .x = goal.x + request_route_dx, .y = goal.y + request_route_dy };
                if (self == .common_goal) break :blk .{ .start = start, .goal = .{ .x = request_side - 8, .y = request_side - 8 } };
                break :blk .{ .start = start, .goal = goal };
            },
            .blocked_detour => blk: {
                const lane: u16 = @intCast(index % detour_lanes);
                const y: u16 = @intCast(8 + 2 * (index / detour_lanes));
                break :blk .{ .start = .{ .x = request_side / 2 - 2 - lane, .y = y }, .goal = .{ .x = request_side / 2 + 2 + lane, .y = y } };
            },
            .hard_fallback => blk: {
                const column: u16 = @intCast(index / hard_fallback_lanes);
                const y: u16 = @intCast(2 + (index % hard_fallback_lanes) * 3);
                break :blk .{ .start = .{ .x = 1 + column, .y = y }, .goal = .{ .x = hard_fallback_side - 2 - column, .y = y } };
            },
        };
    }

    // The layout's blocking cells on level 0.
    fn blockedCells(self: Workload, allocator: std.mem.Allocator) ![]CellCoord {
        var cells: std.ArrayList(CellCoord) = .empty;
        errdefer cells.deinit(allocator);
        switch (self) {
            .unique_open, .common_goal => {},
            .blocked_detour => for (0..request_side) |y| {
                if (y != detour_gap_y) try cells.append(allocator, .{ .x = request_side / 2, .y = @intCast(y) });
            },
            .hard_fallback => for (0..hard_fallback_lanes) |lane| {
                try cells.append(allocator, .{ .x = hard_fallback_side / 2, .y = @intCast(2 + lane * 3) });
            },
        }
        return cells.toOwnedSlice(allocator);
    }
};

// `count` requests of `workload` on its level, world-backed nav built over it.
fn initRequestFixture(allocator: std.mem.Allocator, io: std.Io, workload: Workload, count: usize, capacity: PathfindingCapacity, thread_system: *ThreadSystem) !RouteFixture {
    if (count > workload.capacity()) return error.RequestLayoutTooSmall;
    var open = try buildOpenWorld(allocator, io, workload.side(), 1);
    var open_owned = true;
    errdefer if (open_owned) open.world.deinit();
    const blocked = try workload.blockedCells(allocator);
    defer allocator.free(blocked);
    try writeLevelZeroCells(&open, blocked, open.blocking);
    const requests = try allocator.alloc(PathRequest, count);
    defer allocator.free(requests);
    for (requests, 0..) |*request, index| {
        const route = workload.route(index);
        request.* = .{ .entity = undefined, .start = open.cellCenter(route.start), .goal = open.cellCenter(route.goal) };
    }
    open_owned = false;
    return initRouteFixture(allocator, open, requests, capacity, thread_system);
}

// A request-load group's capacity: the item count's agents.
fn requestCapacity(item_count: usize, participant_count: usize) PathfindingCapacity {
    return .{ .worker_participant_count = participant_count, .max_agent_budget = @max(item_count, 1) };
}

const MeasurementMode = enum {
    // Warm cache: measures the cache-hit probe (no solve runs).
    hot_cache,
    // Cold solve at the admission window; serviced = solve admissions.
    cold_fallback,
    // Cold solve; serviced = results published.
    cold_solve,

    fn isCold(self: MeasurementMode) bool {
        return self != .hot_cache;
    }
};

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runWorkloadCase(allocator, io, options, case, item_count, .unique_open, .cold_solve, item_count, item_count);
}

// Every request shares one goal: all but the first fold into its pending entry, so a cold
// step is one solve. Items/s is requests answered, not solves.
fn runDedupCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    // The field threshold above every sharer count (the agent ceiling clamps it), so the
    // timed step is the fold alone, never a group-field begin.
    var capacity = requestCapacity(item_count + 1, fixtures.participantCount(thread_ptr));
    capacity.min_group_field_agents = item_count + 1;
    var fixture = try initRequestFixture(allocator, io, .common_goal, item_count, capacity, thread_ptr);
    defer fixture.deinit();
    const system = &fixture.system;

    var warm = suite.Warmup.custom(case, 1 + coldWarmup(options), suite.adaptiveSettleIterationLimit(options));
    while (warm.nextSettled(stepTunerSettle(system))) {
        expireCachedResults(system);
        _ = try runColdOnce(system, &fixture.requests, thread_ptr, case, item_count, item_count, item_count);
    }
    const settle = stepTunerSettle(system);
    const intake_start = suite.TunerStart.of(&system.tuners.intake, case);

    // The headline is intake, which folds every request; the step solves one.
    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    var stage_report = StageReport{};
    for (0..coldIterations(options)) |_| {
        expireCachedResults(system);
        const start_ns = suite.nowNs(io);
        last_stats = try runColdOnce(system, &fixture.requests, thread_ptr, case, item_count, item_count, item_count);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        accumulator.record(elapsed_ns, last_stats.perf.intake_batch);
        stage_report.add(elapsed_ns, last_stats);
        if (last_stats.perf.group_field_begin_batch.item_count != 0 or last_stats.perf.group_fields_built != 0) return error.SharedGoalBeganField;
    }
    if (last_stats.perf.solve_admissions != 1) return error.SharedGoalNotOneSolve;
    var stats = accumulator.finish();
    stage_report.write(&stats.details);
    stats.output_count = last_stats.perf.available_results + last_stats.perf.unavailable_results + last_stats.perf.duplicate_requests + last_stats.perf.cache_hits;
    stats.candidate_pairs = last_stats.perf.duplicate_requests + last_stats.perf.cache_hits;
    stats.items_per_second = suite.itemsPerSecond(stats.output_count, stats.mean_ns);
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        stats.work_tuning = suite.workTuningSummary(&system.tuners.intake, intake_start);
    }
    return stats;
}

fn runFallbackCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runWorkloadCase(allocator, io, options, case, item_count, .unique_open, .hot_cache, item_count, item_count);
}

fn runFallbackDetourCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runWorkloadCase(allocator, io, options, case, item_count, .blocked_detour, .hot_cache, item_count, item_count);
}

fn runHardFallbackCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runWorkloadCase(allocator, io, options, case, item_count, .hard_fallback, .cold_fallback, item_count, item_count);
}

fn runHardFallbackBudgetCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    const fallback_budget = @min(options.fallback_budget orelse hard_fallback_admissions, item_count);
    return runWorkloadCase(allocator, io, options, case, item_count, .hard_fallback, .cold_fallback, item_count, fallback_budget);
}

// Admissions per step of the hard-fallback-budget case: a window narrower than its solve
// window, so the admission limit defers the rest.
const hard_fallback_admissions: usize = 128;

fn runWorkloadCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, workload: Workload, mode: MeasurementMode, solve_budget: usize, fallback_budget: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    var fixture = try initRequestFixture(allocator, io, workload, item_count, requestCapacity(item_count, fixtures.participantCount(thread_ptr)), thread_ptr);
    defer fixture.deinit();
    const system = &fixture.system;

    system.clearRuntimeState();
    _ = try runColdOnce(system, &fixture.requests, thread_ptr, case, item_count, solve_budget, fallback_budget);
    if (mode == .hot_cache) try warmHotCache(system, &fixture.requests, thread_ptr, options, case, item_count);

    const warmup_count = if (mode.isCold()) coldWarmup(options) else options.warmup_iterations;
    const measure_count = if (mode.isCold()) coldIterations(options) else options.iterations;
    // A cold step settles every tuner it runs; a hit-only step runs intake alone (the cache
    // fill's solves are setup), which `warmHotCache` settled.
    var warm = suite.Warmup.custom(case, warmup_count, if (mode.isCold()) suite.adaptiveSettleIterationLimit(options) else 0);
    while (warm.nextSettled(stepTunerSettle(system))) {
        if (mode.isCold()) expireCachedResults(system);
        _ = try runColdOnce(system, &fixture.requests, thread_ptr, case, item_count, solve_budget, fallback_budget);
    }
    const settle = stepTunerSettle(system);
    // The headline: the solve when cold, intake when every request hits the cache.
    const headline_tuner = if (mode.isCold()) &system.tuners.solve else &system.tuners.intake;
    const headline_start = suite.TunerStart.of(headline_tuner, case);

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    var stage_report = StageReport{};
    for (0..measure_count) |_| {
        if (mode.isCold()) expireCachedResults(system);
        const start_ns = suite.nowNs(io);
        last_stats = try runColdOnce(system, &fixture.requests, thread_ptr, case, item_count, solve_budget, fallback_budget);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), if (mode.isCold()) last_stats.perf.solve_batch else last_stats.perf.intake_batch);
        stage_report.add(suite.elapsedNs(start_ns, end_ns), last_stats);
    }
    // Every route exists and starts open.
    if (last_stats.perf.unavailable_results != 0) return error.RouteUnavailable;

    var stats = accumulator.finish();
    stage_report.write(&stats.details);
    stats.output_count = last_stats.perf.available_results;
    stats.deferred_count = last_stats.perf.pending_requests;
    stats.fallback_deferred_count = last_stats.perf.admission_deferred_requests;
    stats.cache_evictions = last_stats.perf.cache_evictions;
    // Throughput counts what the step serviced: cache hits when warm, admissions when cold
    // at the admission window, published results when cold; the per-step ceiling defers the
    // rest.
    const serviced: usize = switch (mode) {
        .hot_cache => last_stats.perf.cache_hits,
        .cold_fallback => last_stats.perf.solve_admissions,
        .cold_solve => last_stats.perf.available_results,
    };
    stats.candidate_pairs = serviced;
    switch (mode) {
        .hot_cache => if (serviced != item_count) return error.HotCacheMissed,
        .cold_fallback => if (serviced != @min(item_count, fallback_budget, default_max_solves_per_frame)) return error.FallbackAdmissionsDrifted,
        // A solve may exhaust its budget and defer, so results are bounded by the ceiling.
        .cold_solve => if (serviced > @min(item_count, solve_budget, default_max_solves_per_frame)) return error.SolvesPastCeiling,
    }
    stats.items_per_second = suite.itemsPerSecond(serviced, stats.mean_ns);
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        stats.work_tuning = suite.workTuningSummary(headline_tuner, headline_start);
    }
    return stats;
}

// A drain step: the queue accepted untimed (`refillDrainQueue`), each timed step solving the
// carried queue's front at the per-step ceiling over an empty stream.
fn runDrainCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    // The refill step solves one ceiling; a full-ceiling drain step needs another behind it.
    if (item_count < 2 * default_max_solves_per_frame) return error.DrainQueueBelowTwoCeilings;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    var fixture = try initRequestFixture(allocator, io, .unique_open, item_count, requestCapacity(item_count, fixtures.participantCount(thread_ptr)), thread_ptr);
    defer fixture.deinit();
    const system = &fixture.system;
    var empty = RangeOutputStream(PathRequest).init(allocator);
    defer empty.deinit();

    // A healthy queue empties in ceil(N / ceiling) steps; past that a cycle stops.
    const drain_step_limit = @divCeil(item_count, default_max_solves_per_frame) + 2;
    const drain_samples = coldIterations(options);
    // Each warm cycle refills the queue and drains it; the tuned case settles every step
    // tuner the refill and drain steps run.
    var warm = suite.Warmup.custom(case, @max(@as(usize, 1), coldWarmup(options)), suite.adaptiveSettleIterationLimit(options));
    while (warm.nextSettled(stepTunerSettle(system))) {
        try refillDrainQueue(system, &fixture.requests, thread_ptr, case, item_count);
        var guard: usize = drain_step_limit;
        while (system.pending.len > 0 and guard > 0) : (guard -= 1) {
            const before = system.pending.len;
            _ = try runColdOnce(system, &empty, thread_ptr, case, item_count, item_count, item_count);
            if (system.pending.len >= before) return error.DrainStalled;
        }
    }

    const settle = stepTunerSettle(system);
    const solve_start = suite.TunerStart.of(&system.tuners.solve, case);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    var stage_report = StageReport{};
    while (accumulator.iterations < drain_samples) {
        try refillDrainQueue(system, &fixture.requests, thread_ptr, case, item_count);
        var guard: usize = drain_step_limit;
        // Only full-ceiling steps are drain samples: the queue's tail step solves fewer.
        while (system.pending.len >= default_max_solves_per_frame and accumulator.iterations < drain_samples and guard > 0) : (guard -= 1) {
            const before = system.pending.len;
            const start_ns = suite.nowNs(io);
            last_stats = try runColdOnce(system, &empty, thread_ptr, case, item_count, item_count, item_count);
            const end_ns = suite.nowNs(io);
            accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.perf.solve_batch);
            stage_report.add(suite.elapsedNs(start_ns, end_ns), last_stats);
            if (system.pending.len >= before) return error.DrainStalled;
        }
    }

    var stats = accumulator.finish();
    stage_report.write(&stats.details);
    stats.output_count = last_stats.perf.available_results + last_stats.perf.unavailable_results;
    stats.candidate_pairs = last_stats.perf.solved_requests;
    stats.deferred_count = last_stats.perf.pending_requests;
    stats.items_per_second = suite.itemsPerSecond(last_stats.perf.solved_requests, stats.mean_ns);
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        stats.work_tuning = suite.workTuningSummary(&system.tuners.solve, solve_start);
    }
    return stats;
}

// Expires every cached result (`expireCachedResults`) and accepts every distinct goal in one
// step, which also solves the first ceiling; the queue carries the rest.
fn refillDrainQueue(system: *PathfindingSystem, requests: *RangeOutputStream(PathRequest), thread_system: *ThreadSystem, case: suite.BenchmarkCase, agent_count: usize) !void {
    expireCachedResults(system);
    _ = try runColdOnce(system, requests, thread_system, case, agent_count, agent_count, agent_count);
}

// Steps until every request is a cache hit and, for an adaptive case, the intake tuner has
// settled (bounded), so the timed steps are the hit path only.
fn warmHotCache(system: *PathfindingSystem, requests: *RangeOutputStream(PathRequest), thread_system: *ThreadSystem, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !void {
    const fill_limit = @divCeil(item_count, default_max_solves_per_frame) + 2;
    const settle_limit = fill_limit + suite.adaptiveSettleIterationLimit(options);
    var steps: usize = 0;
    while (true) {
        const stats = try runColdOnce(system, requests, thread_system, case, item_count, item_count, item_count);
        steps += 1;
        const all_hits = stats.perf.cache_hits == item_count;
        if (!all_hits and steps > fill_limit) return error.HotCacheNotWarm;
        const tuner_ready = !case.adaptive or suite.tunerSettled(&system.tuners.intake) or steps >= settle_limit;
        if (all_hits and tuner_ready) return;
    }
}

const QueryContext = struct {
    system: *const PathfindingSystem,
    // Per-agent query inputs, all indexed by agent. starts[i] is the agent's current cell
    // (mid-route), goals[i] its goal. hints[i] is its private waypoint hint (disjoint write
    // per worker). sink[i] consumes the returned status so the query is not elided.
    starts: []const math.Vec2,
    goals: []const math.Vec2,
    hints: []u32,
    sink: []u8,
};

fn queryJob(context: *anyopaque, range: ParallelRange, worker_id: WorkerId) void {
    _ = worker_id;
    const ctx: *QueryContext = @ptrCast(@alignCast(context));
    std.debug.assert(range.end <= ctx.hints.len and range.end <= ctx.sink.len);
    for (range.start..range.end) |i| {
        const view = ctx.system.statusForWorld(0, ctx.starts[i], 0, ctx.goals[i], .default, &ctx.hints[i]);
        ctx.sink[i] = @backingInt(view.status);
    }
}

fn runQueries(ctx: *QueryContext, thread_system: *ThreadSystem, tuner: *AdaptiveWorkTuner, case: suite.BenchmarkCase, item_count: usize) BatchStats {
    return thread_system.parallelForWithOptions(item_count, ctx, queryJob, .{
        .items_per_range = case.stageItemsPerRange(pathfinding_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .range_alignment_items = pathfinding_range_alignment_items,
        .adaptive = case.adaptive,
        .batches_per_participant = case.stageBatchesPerParticipant(),
        .adaptive_tuner = tuner,
    });
}

// Per-agent statusForWorld against a warm cache: each agent queries from the midpoint of
// its own cached path, so the waypoint scan has a deep match to find.
fn runQueryCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    var fixture = try initRequestFixture(allocator, io, .unique_open, item_count, requestCapacity(item_count, fixtures.participantCount(thread_ptr)), thread_ptr);
    defer fixture.deinit();
    const system = &fixture.system;

    // Warm: the per-step solve ceiling caps each step, so enough steps drain the queue.
    const warm_steps = item_count / default_max_solves_per_frame + 4;
    for (0..warm_steps) |_| _ = try system.update(&fixture.requests, item_count, thread_ptr, .{});

    const starts = try allocator.alloc(math.Vec2, item_count);
    defer allocator.free(starts);
    const goals = try allocator.alloc(math.Vec2, item_count);
    defer allocator.free(goals);
    const hints = try allocator.alloc(u32, item_count);
    defer allocator.free(hints);
    const sink = try allocator.alloc(u8, item_count);
    defer allocator.free(sink);
    @memset(hints, 0);
    @memset(sink, 0);

    const grid = system.graph.grid(0).?;
    var warm_paths: usize = 0;
    for (0..item_count) |i| {
        const route = Workload.unique_open.route(i);
        goals[i] = fixture.open.cellCenter(route.goal);
        starts[i] = fixture.open.cellCenter(route.start);
        const key = system.graph.keyForWorld(0, goals[i], .default) orelse continue;
        const slot = system.completed.slotIndex(key) orelse continue;
        // A cross-chunk route is cached as its stitched corridor (one level here).
        const result = system.completed.resultAt(slot);
        if (result.stitched_len != 0) {
            const stitched = system.completed.stitchedSlice(slot, result.stitched_len);
            starts[i] = grid.cellCenter(stitched.cells[stitched.len() / 2]);
            warm_paths += 1;
        } else {
            const path = system.completed.pathSlice(slot, result.path_len);
            if (path.len == 0) continue;
            starts[i] = grid.cellCenter(path[path.len / 2]);
            warm_paths += 1;
        }
    }
    // Every agent's path must be resident, or this times the miss path.
    if (warm_paths != item_count) return error.QueryCacheNotWarm;

    var context = QueryContext{ .system = system, .starts = starts, .goals = goals, .hints = hints, .sink = sink };
    // The query batch's own stage tuner.
    var tuner = AdaptiveWorkTuner.init(.{});
    // Warmup also settles each agent's hint to its midpoint index.
    var warm = suite.Warmup.init(options, case, 0);
    while (warm.next(suite.tunerSettled(&tuner))) _ = runQueries(&context, thread_ptr, &tuner, case, item_count);
    const tuner_start = suite.TunerStart.of(&tuner, case);

    var accumulator = suite.StatsAccumulator.init(item_count);
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const batch = runQueries(&context, thread_ptr, &tuner, case, item_count);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        accumulator.record(elapsed_ns, batch);
        try suite.checkStageDispatched(case, thread_ptr, case.stageItemsPerRange(pathfinding_range_alignment_items), batch);
        main_total += elapsed_ns -| offMainNs(batch);
    }
    var stats = accumulator.finish();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    stats.output_count = item_count;
    stats.candidate_pairs = warm_paths;
    if (case.adaptive) stats.work_tuning = suite.workTuningSummary(&tuner, tuner_start);
    return stats;
}

// The escalated detour level: a full-height wall down the middle open only at row 1, one
// request from beside the wall's foot to its mirror across it.
fn detourWallCells(allocator: std.mem.Allocator, side: u16) ![]CellCoord {
    const cells = try allocator.alloc(CellCoord, side - 1);
    var len: usize = 0;
    for (0..side) |y| {
        if (y == 1) continue;
        cells[len] = .{ .x = side / 2, .y = @intCast(y) };
        len += 1;
    }
    return cells;
}

// A world-backed level of `side` cells holding the detour wall.
fn buildDetourWorld(allocator: std.mem.Allocator, io: std.Io, side: u16) !OpenWorld {
    var open = try buildOpenWorld(allocator, io, side, 1);
    errdefer open.world.deinit();
    const wall = try detourWallCells(allocator, side);
    defer allocator.free(wall);
    try writeLevelZeroCells(&open, wall, open.blocking);
    return open;
}

// Times the cold escalated solve only: an untimed step submits the request and exhausts the
// one-node first attempt, promoting it; the timed step solves it at the tier-1 budget.
fn runEscalatedDetourCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const side = std.math.cast(u16, item_count) orelse return error.EscalatedDetourSideTooWide;
    if (side % default_chunk_size_tiles != 0 or side < 4 * default_chunk_size_tiles) return error.EscalatedDetourSideNotChunked;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const open = try buildDetourWorld(allocator, io, side);
    var request = [_]PathRequest{.{
        .entity = undefined,
        .start = open.cellCenter(.{ .x = 2, .y = side - 2 }),
        .goal = open.cellCenter(.{ .x = side - 2, .y = side - 2 }),
    }};
    var fixture = try initRouteFixture(allocator, open, &request, .{
        .worker_participant_count = fixtures.participantCount(thread_ptr),
        .max_agent_budget = min_capacity_floor,
        .max_group_fields = 1,
        // One node: the first attempt exhausts at every side, so the request promotes.
        .tier0_abstract_node_cap = 1,
    }, thread_ptr);
    defer fixture.deinit();
    const system = &fixture.system;
    var empty = RangeOutputStream(PathRequest).init(allocator);
    defer empty.deinit();

    // A sample is the untimed promote and the timed solve, both every step tuner's.
    var warm = suite.Warmup.custom(case, coldWarmup(options), suite.adaptiveSettleIterationLimit(options));
    while (warm.nextSettled(stepTunerSettle(system))) {
        try promoteDetour(system, &fixture.requests, thread_ptr, case);
        _ = try runColdOnce(system, &empty, thread_ptr, case, 1, 1, 1);
    }
    const settle = stepTunerSettle(system);
    const solve_start = suite.TunerStart.of(&system.tuners.solve, case);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    for (0..coldIterations(options)) |_| {
        try promoteDetour(system, &fixture.requests, thread_ptr, case);
        const start_ns = suite.nowNs(io);
        last_stats = try runColdOnce(system, &empty, thread_ptr, case, 1, 1, 1);
        accumulator.record(suite.elapsedNs(start_ns, suite.nowNs(io)), last_stats.perf.solve_batch);
    }
    // The fixed tier-1 budget solves the detour; a second exhaustion would drop it.
    if (last_stats.perf.available_results != 1 or last_stats.perf.escalated_solves != 1) return error.EscalatedDetourUnsolved;
    var stats = accumulator.finish();
    stats.output_count = last_stats.perf.available_results;
    stats.candidate_pairs = last_stats.perf.solved_requests;
    stats.items_per_second = suite.itemsPerSecond(stats.output_count, stats.mean_ns);
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        stats.work_tuning = suite.workTuningSummary(&system.tuners.solve, solve_start);
    }
    return stats;
}

// The untimed setup step: submits the request with its cached result expired
// (`expireCachedResults`) and exhausts its first attempt, leaving it pending at tier 1.
fn promoteDetour(system: *PathfindingSystem, requests: *RangeOutputStream(PathRequest), thread_system: *ThreadSystem, case: suite.BenchmarkCase) !void {
    expireCachedResults(system);
    const stats = try runColdOnce(system, requests, thread_system, case, 1, 1, 1);
    if (stats.perf.budget_exhausted != 1 or system.pending.len != 1 or system.pending.at(0).tier != 1) return error.EscalatedDetourNotPromoted;
}

// The group-field detour level side: a whole-level field builds within the rebuild throttle
// at the default build budget, so a re-keyed field is ready before the next rekey.
const group_field_detour_side: u16 = std.math.sqrt(default_group_field_build_budget * group_field_detour_rebuild_min_steps);
// Untimed setup: steps spent waiting for the field to build, a guard against a stalled build.
const group_field_detour_setup_guard: usize = 64;
// Agents a group field engages for: a fixed threshold below every pack size.
const group_field_detour_threshold: usize = 8;
// Fastest re-key cadence: a goal moving at 120 px/s crosses a 32 px nav cell every 16 steps
// at 60 Hz.
const group_field_detour_rekey_period_steps: usize = 16;
// The rebuild throttle, below the rekey cadence, so a field rebuilt for a new goal is
// sampled before the goal moves again.
const group_field_detour_rebuild_min_steps: u32 = 8;
// Rekey cycles run untimed before measuring, and measured.
const group_field_detour_moving_warmup_cycles: usize = 2;
const group_field_detour_moving_cycles: usize = 6;

comptime {
    std.debug.assert(group_field_detour_rebuild_min_steps < group_field_detour_rekey_period_steps);
    std.debug.assert(group_field_detour_side % default_chunk_size_tiles == 0);
}

// Pack member `index`'s start: lanes left of the detour wall from the level's bottom rows.
fn packStart(side: u16, index: usize) CellCoord {
    const lane_width: usize = side / 2 - 2;
    return .{ .x = @intCast(2 + index % lane_width), .y = @intCast(side - 2 - (index / lane_width) * 3) };
}

// The pack's goal for rekey cycle `cycle`: across the wall, marching up one cell a cycle.
fn packGoal(side: u16, cycle: usize) CellCoord {
    return .{ .x = side - 2, .y = @intCast(side - 2 - cycle) };
}

// Rewrites `requests` with every pack member's `.group` request toward `goal`.
fn writePackRequests(allocator: std.mem.Allocator, stream: *RangeOutputStream(PathRequest), scratch: *std.ArrayList(PathRequest), open: *const OpenWorld, entities: []const EntityId, goal: math.Vec2) !void {
    scratch.clearRetainingCapacity();
    try scratch.ensureTotalCapacity(allocator, entities.len);
    for (entities, 0..) |entity, index| {
        scratch.appendAssumeCapacity(.{ .entity = entity, .kind = .group, .start = open.cellCenter(packStart(group_field_detour_side, index)), .goal = goal });
    }
    try fixtures.writeRequests(stream, scratch.items);
}

// The pack on the detour level: its entities, request stream, and world-backed nav.
const PackFixture = struct {
    open: OpenWorld,
    data: DataSystem,
    entities: []EntityId,
    scratch: std.ArrayList(PathRequest) = .empty,
    stream: RangeOutputStream(PathRequest),
    system: PathfindingSystem,

    fn deinit(self: *PackFixture, allocator: std.mem.Allocator) void {
        self.system.deinit();
        self.stream.deinit();
        self.scratch.deinit(allocator);
        allocator.free(self.entities);
        self.data.deinit();
        self.open.world.deinit();
        self.* = undefined;
    }
};

fn initPackFixture(allocator: std.mem.Allocator, io: std.Io, agent_count: usize, capacity: PathfindingCapacity, thread_system: *ThreadSystem) !PackFixture {
    const side = group_field_detour_side;
    if (agent_count > (side / 2 - 2) * ((side - 8) / 3)) return error.PackLayoutTooSmall;
    var open = try buildDetourWorld(allocator, io, side);
    errdefer open.world.deinit();
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const entities = try allocator.alloc(EntityId, agent_count);
    errdefer allocator.free(entities);
    for (entities) |*entity| entity.* = try data.createEntity();
    var system = PathfindingSystem.init(allocator);
    errdefer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &open.world, thread_system);
    return .{ .open = open, .data = data, .entities = entities, .stream = RangeOutputStream(PathRequest).init(allocator), .system = system };
}

fn packCapacity(agent_count: usize, participant_count: usize) PathfindingCapacity {
    return .{
        .max_group_fields = 4,
        .worker_participant_count = participant_count,
        .max_agent_budget = @max(agent_count, 1),
        .min_group_field_agents = group_field_detour_threshold,
        .group_field_rebuild_min_steps = group_field_detour_rebuild_min_steps,
    };
}

// Steady sampling of a ready field: untimed steps build it, then the timed steps resubmit
// the same pack and every member samples the field.
fn runGroupFieldDetourCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    var fixture = try initPackFixture(allocator, io, item_count, packCapacity(item_count, fixtures.participantCount(thread_ptr)), thread_ptr);
    defer fixture.deinit(allocator);
    const system = &fixture.system;
    try writePackRequests(allocator, &fixture.stream, &fixture.scratch, &fixture.open, fixture.entities, fixture.open.cellCenter(packGoal(group_field_detour_side, 0)));

    var last_stats = PathfindingStats{};
    var guard: usize = group_field_detour_setup_guard;
    while (guard > 0 and last_stats.perf.group_field_samples < item_count) : (guard -= 1) {
        last_stats = try runColdOnce(system, &fixture.stream, thread_ptr, case, item_count, item_count, item_count);
    }
    if (last_stats.perf.group_field_samples != item_count) return error.GroupFieldNotReady;
    // A ready field's step runs intake alone, which samples the field for every member; the
    // field build's stages ran only in setup, so the step census leaves them idle.
    var warm = suite.Warmup.init(options, case, 0);
    while (warm.nextSettled(stepTunerSettle(system))) _ = try runColdOnce(system, &fixture.stream, thread_ptr, case, item_count, item_count, item_count);
    const settle = stepTunerSettle(system);
    const intake_start = suite.TunerStart.of(&system.tuners.intake, case);

    var accumulator = suite.StatsAccumulator.init(item_count);
    var stage_report = StageReport{};
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_stats = try runColdOnce(system, &fixture.stream, thread_ptr, case, item_count, item_count, item_count);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        accumulator.record(elapsed_ns, last_stats.perf.intake_batch);
        stage_report.add(elapsed_ns, last_stats);
        // A ready field answers every member: no build, no per-agent solve.
        if (last_stats.perf.group_fields_built != 0 or last_stats.perf.group_field_samples != item_count) return error.GroupFieldNotSampled;
    }

    var stats = accumulator.finish();
    stage_report.write(&stats.details);
    stats.output_count = last_stats.perf.duplicate_requests;
    stats.candidate_pairs = last_stats.perf.group_field_samples;
    stats.items_per_second = suite.itemsPerSecond(item_count, stats.mean_ns);
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        stats.work_tuning = suite.workTuningSummary(&system.tuners.intake, intake_start);
    }
    return stats;
}

// The moving groups' measured totals.
const MovingTotals = struct {
    escalated: usize = 0,
    throttled: usize = 0,
    built: usize = 0,
    samples: usize = 0,

    fn add(self: *MovingTotals, stats: PathfindingStats) void {
        self.escalated += stats.perf.escalated_solves;
        self.throttled += stats.perf.group_field_rebuild_throttled;
        self.built += stats.perf.group_fields_built;
        self.samples += stats.perf.group_field_samples;
    }

    fn into(self: MovingTotals, stats: *suite.RunStats) void {
        stats.output_count = self.escalated;
        stats.candidate_pairs = self.throttled;
        stats.deferred_count = self.built;
        stats.sample_count = self.samples;
    }
};

// The goal cycles a moving or pack field group runs: the march `writeGroupFieldPackRequests`
// bounds, so no cycle's goal leaves the level or revisits an earlier one.
const group_field_march_cycles: usize = group_field_detour_side / 2;

// The measured steps of a moving or pack field group: their times and headline batch (the
// group-field advance), stage shapes, and totals.
const CycleSink = struct {
    accumulator: suite.StatsAccumulator,
    stage_report: StageReport = .{},
    totals: MovingTotals = .{},

    fn add(self: *CycleSink, elapsed_ns: u64, stats: PathfindingStats) void {
        self.accumulator.record(elapsed_ns, stats.perf.group_field_batch);
        self.stage_report.add(elapsed_ns, stats);
        self.totals.add(stats);
    }
};

// The pathfinding step a moving or pack field group's cycles run, with `agent_count` agents
// under `case`.
const CycleStepper = struct {
    io: std.Io,
    threads: *ThreadSystem,
    case: suite.BenchmarkCase,
    agent_count: usize,

    // One step of `system` over `stream`, timed into `sink` when measured.
    fn step(self: CycleStepper, system: *PathfindingSystem, stream: *RangeOutputStream(PathRequest), sink: ?*CycleSink) !void {
        const start_ns = suite.nowNs(self.io);
        const stats = try runColdOnce(system, stream, self.threads, self.case, self.agent_count, self.agent_count, self.agent_count);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(self.io));
        if (sink) |measured| measured.add(elapsed_ns, stats);
    }
};

// The tuned case's start: step tuners settled on an identical twin's cycles, which run from
// cycle 0 until every tuner that recorded since the twin's warmup cycles is settled, within the
// march. The measured fixture then runs its own fixed cycles from these tuners, so its goals
// and steps are the same in every case and run.
fn twinWarmup(case: suite.BenchmarkCase) suite.Warmup {
    return suite.Warmup.custom(case, group_field_detour_moving_warmup_cycles, group_field_march_cycles - group_field_detour_moving_warmup_cycles);
}

// The measured fixture's cycle at which measurement begins: its census snapshot and the
// headline group-field advance tuner's start.
const CycleWindow = struct {
    settle: suite.TunerSettle,
    start: suite.TunerStart,

    fn begin(system: *const PathfindingSystem, case: suite.BenchmarkCase) CycleWindow {
        return .{ .settle = stepTunerSettle(system), .start = .of(&system.tuners.group_field, case) };
    }

    fn report(self: *const CycleWindow, stats: *suite.RunStats, system: *const PathfindingSystem, case: suite.BenchmarkCase) void {
        if (!case.adaptive) return;
        stats.tuner_settle = self.settle.measured();
        stats.work_tuning = suite.workTuningSummary(&system.tuners.group_field, self.start);
    }
};

// Cycle `cycle` of the moving group: the pack re-keyed to the march's goal for `cycle`, then
// the rekey period's steps.
fn movingCycle(allocator: std.mem.Allocator, stepper: CycleStepper, fixture: *PackFixture, cycle: usize, sink: ?*CycleSink) !void {
    try writePackRequests(allocator, &fixture.stream, &fixture.scratch, &fixture.open, fixture.entities, fixture.open.cellCenter(packGoal(group_field_detour_side, cycle)));
    for (0..group_field_detour_rekey_period_steps) |_| try stepper.step(&fixture.system, &fixture.stream, sink);
}

// A moving shared goal at the chase cadence: each cycle re-keys the pack's goal to a nav cell
// no earlier cycle targeted (a strict march, so no cycle rides an earlier cached result), then
// steps the rekey period. The first request for a new goal is always one bounded solve (the
// field cannot be ready for it yet); the throttle must let the field serve the rest.
fn runGroupFieldDetourMovingCase(allocator: std.mem.Allocator, io: std.Io, _: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    // Fixed cycle counts: --warmup and --iterations do not apply.
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const capacity = packCapacity(item_count, fixtures.participantCount(thread_ptr));
    const stepper = CycleStepper{ .io = io, .threads = thread_ptr, .case = case, .agent_count = item_count };

    var carried: ?fixtures.NavTuners = null;
    if (case.adaptive) {
        var twin = try initPackFixture(allocator, io, item_count, capacity, thread_ptr);
        defer twin.deinit(allocator);
        var warm = twinWarmup(case);
        var cycle: usize = 0;
        while (warm.nextSettled(stepTunerSettle(&twin.system))) : (cycle += 1) try movingCycle(allocator, stepper, &twin, cycle, null);
        std.debug.assert(cycle <= group_field_march_cycles);
        carried = twin.system.tuners;
    }
    var fixture = try initPackFixture(allocator, io, item_count, capacity, thread_ptr);
    defer fixture.deinit(allocator);
    const system = &fixture.system;
    if (carried) |tuners| system.tuners = tuners;

    var sink = CycleSink{ .accumulator = .init(item_count) };
    for (0..group_field_detour_moving_warmup_cycles) |cycle| try movingCycle(allocator, stepper, &fixture, cycle, null);
    const window = CycleWindow.begin(system, case);
    for (group_field_detour_moving_warmup_cycles..group_field_detour_moving_warmup_cycles + group_field_detour_moving_cycles) |cycle| {
        try movingCycle(allocator, stepper, &fixture, cycle, &sink);
    }
    // The throttle lets the field reach ready and serve part of the run; escalated solves stay
    // at one per rekey.
    if (sink.totals.samples == 0) return error.GroupFieldNeverSampled;
    if (sink.totals.escalated > group_field_detour_moving_cycles) return error.GroupFieldEscalationsPastRekeys;
    var stats = sink.accumulator.finish();
    sink.stage_report.write(&stats.details);
    sink.totals.into(&stats);
    window.report(&stats, system, case);
    return stats;
}

// The hysteresis group's goal: the live goal advancing every step at the chase speed (one nav
// cell per rekey period), and the request goal re-keyed only past the AI's requantization
// hysteresis (`computeRequantizedGoal`, the function `AiSystem.requantizeGoal` wraps).
const HysteresisGoal = struct {
    start_goal: math.Vec2,
    px_per_step: f32,
    snapped_goal: math.Vec2,
    snapped_initialized: bool = false,
    last_written_goal: ?math.Vec2 = null,

    fn init(fixture: *const PackFixture) HysteresisGoal {
        const start_goal = fixture.open.cellCenter(packGoal(group_field_detour_side, 0));
        return .{
            .start_goal = start_goal,
            .px_per_step = fixture.open.world.tile_size / @as(f32, @floatFromInt(group_field_detour_rekey_period_steps)),
            .snapped_goal = start_goal,
        };
    }
};

// Cycle `cycle` of the hysteresis group: the rekey period's steps, each advancing the live
// goal and rewriting the pack's requests when the requantized goal moved. Returns the
// rewrites.
fn hysteresisCycle(allocator: std.mem.Allocator, stepper: CycleStepper, fixture: *PackFixture, goal: *HysteresisGoal, cycle: usize, sink: ?*CycleSink) !usize {
    var rewrites: usize = 0;
    for (cycle * group_field_detour_rekey_period_steps..(cycle + 1) * group_field_detour_rekey_period_steps) |step_index| {
        const live = math.Vec2{ .x = goal.start_goal.x, .y = goal.start_goal.y - @as(f32, @floatFromInt(step_index)) * goal.px_per_step };
        const requantized = computeRequantizedGoal(
            AiDir{ .x = goal.snapped_goal.x, .y = goal.snapped_goal.y },
            goal.snapped_initialized,
            AiDir{ .x = live.x, .y = live.y },
            default_goal_requantization_hysteresis_distance,
        );
        goal.snapped_goal = .{ .x = requantized.goal.x, .y = requantized.goal.y };
        goal.snapped_initialized = requantized.initialized;
        const snapped = goal.snapped_goal;
        if (goal.last_written_goal == null or goal.last_written_goal.?.x != snapped.x or goal.last_written_goal.?.y != snapped.y) {
            try writePackRequests(allocator, &fixture.stream, &fixture.scratch, &fixture.open, fixture.entities, snapped);
            goal.last_written_goal = snapped;
            rewrites += 1;
        }
        try stepper.step(&fixture.system, &fixture.stream, sink);
    }
    return rewrites;
}

fn runGroupFieldDetourMovingHysteresisCase(allocator: std.mem.Allocator, io: std.Io, _: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    // Fixed cycle counts: --warmup and --iterations do not apply.
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const capacity = packCapacity(item_count, fixtures.participantCount(thread_ptr));
    const stepper = CycleStepper{ .io = io, .threads = thread_ptr, .case = case, .agent_count = item_count };

    var carried: ?fixtures.NavTuners = null;
    if (case.adaptive) {
        var twin = try initPackFixture(allocator, io, item_count, capacity, thread_ptr);
        defer twin.deinit(allocator);
        var twin_goal = HysteresisGoal.init(&twin);
        var warm = twinWarmup(case);
        var cycle: usize = 0;
        while (warm.nextSettled(stepTunerSettle(&twin.system))) : (cycle += 1) _ = try hysteresisCycle(allocator, stepper, &twin, &twin_goal, cycle, null);
        std.debug.assert(cycle <= group_field_march_cycles);
        carried = twin.system.tuners;
    }
    var fixture = try initPackFixture(allocator, io, item_count, capacity, thread_ptr);
    defer fixture.deinit(allocator);
    const system = &fixture.system;
    if (carried) |tuners| system.tuners = tuners;

    var goal = HysteresisGoal.init(&fixture);
    var sink = CycleSink{ .accumulator = .init(item_count) };
    for (0..group_field_detour_moving_warmup_cycles) |cycle| _ = try hysteresisCycle(allocator, stepper, &fixture, &goal, cycle, null);
    const window = CycleWindow.begin(system, case);
    // Goal rewrites past the hysteresis over the measured steps.
    var rewrite_count: usize = 0;
    for (group_field_detour_moving_warmup_cycles..group_field_detour_moving_warmup_cycles + group_field_detour_moving_cycles) |cycle| {
        rewrite_count += try hysteresisCycle(allocator, stepper, &fixture, &goal, cycle, &sink);
    }
    // The field still serves part of the run; escalated solves follow the hysteresis-reduced
    // rewrites, which stay below the per-step count.
    if (sink.totals.samples == 0) return error.GroupFieldNeverSampled;
    if (rewrite_count >= group_field_detour_moving_cycles * group_field_detour_rekey_period_steps) return error.GroupFieldRewroteEveryStep;
    if (sink.totals.escalated > rewrite_count) return error.GroupFieldEscalationsPastRewrites;
    var stats = sink.accumulator.finish();
    sink.stage_report.write(&stats.details);
    sink.totals.into(&stats);
    window.report(&stats, system, case);
    return stats;
}

const group_field_pack_agents: usize = 2 * group_field_detour_threshold;
const group_field_pack_side: u16 = group_field_detour_side;
// Columns one pack's band holds: its start block and its goal.
const group_field_pack_band_min: usize = 16;

// Every pack's members requesting their pack's goal for `cycle`: pack `p` owns a column band
// of the level, starts in a block at its top, and its goal marches up from the bottom one nav
// cell per cycle (never revisited).
fn writeGroupFieldPackRequests(allocator: std.mem.Allocator, stream: *RangeOutputStream(PathRequest), scratch: *std.ArrayList(PathRequest), open: *const OpenWorld, entities: []const EntityId, packs: usize, cycle: usize) !void {
    const side: usize = group_field_pack_side;
    const band = side / packs;
    std.debug.assert(band >= group_field_pack_band_min and cycle < side / 2);
    scratch.clearRetainingCapacity();
    try scratch.ensureTotalCapacity(allocator, entities.len);
    for (entities, 0..) |entity, index| {
        const pack = index / group_field_pack_agents;
        const member = index % group_field_pack_agents;
        // In range: every band lies inside the level.
        const start = CellCoord{ .x = @intCast(pack * band + 2 + member % 8), .y = @intCast(4 + (member / 8) * 2) };
        const goal = CellCoord{ .x = @intCast(pack * band + band / 2), .y = @intCast(side - 4 - cycle) };
        scratch.appendAssumeCapacity(.{ .entity = entity, .kind = .group, .start = open.cellCenter(start), .goal = open.cellCenter(goal) });
    }
    try fixtures.writeRequests(stream, scratch.items);
}

// `packs` packs on an open `group_field_pack_side`² level: their entities, request stream,
// and world-backed nav with a field slot per pack.
const PacksFixture = struct {
    packs: usize,
    open: OpenWorld,
    data: DataSystem,
    entities: []EntityId,
    scratch: std.ArrayList(PathRequest) = .empty,
    stream: RangeOutputStream(PathRequest),
    system: PathfindingSystem,

    fn init(allocator: std.mem.Allocator, io: std.Io, packs: usize, thread_system: *ThreadSystem) !PacksFixture {
        var open = try buildOpenWorld(allocator, io, group_field_pack_side, 1);
        errdefer open.world.deinit();
        var data = DataSystem.init(allocator);
        errdefer data.deinit();
        const entities = try allocator.alloc(EntityId, packs * group_field_pack_agents);
        errdefer allocator.free(entities);
        for (entities) |*entity| entity.* = try data.createEntity();
        var system = PathfindingSystem.init(allocator);
        errdefer system.deinit();
        var capacity = packCapacity(entities.len, fixtures.participantCount(thread_system));
        capacity.max_group_fields = packs;
        try system.reserve(capacity);
        try system.rebuildStaticNavGridWithWorld(&data, &open.world, thread_system);
        return .{ .packs = packs, .open = open, .data = data, .entities = entities, .stream = RangeOutputStream(PathRequest).init(allocator), .system = system };
    }

    fn deinit(self: *PacksFixture, allocator: std.mem.Allocator) void {
        self.system.deinit();
        self.stream.deinit();
        self.scratch.deinit(allocator);
        allocator.free(self.entities);
        self.data.deinit();
        self.open.world.deinit();
        self.* = undefined;
    }
};

// Cycle `cycle` of the packs group: every pack re-keyed to its march goal for `cycle`, then
// the rekey period's steps.
fn packsCycle(allocator: std.mem.Allocator, stepper: CycleStepper, fixture: *PacksFixture, cycle: usize, sink: ?*CycleSink) !void {
    try writeGroupFieldPackRequests(allocator, &fixture.stream, &fixture.scratch, &fixture.open, fixture.entities, fixture.packs, cycle);
    for (0..group_field_detour_rekey_period_steps) |_| try stepper.step(&fixture.system, &fixture.stream, sink);
}

fn runGroupFieldPacksCase(allocator: std.mem.Allocator, io: std.Io, _: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const packs = item_count;
    if (packs == 0 or group_field_pack_side / packs < group_field_pack_band_min) return error.GroupFieldPacksTooMany;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const stepper = CycleStepper{ .io = io, .threads = thread_ptr, .case = case, .agent_count = packs * group_field_pack_agents };

    var carried: ?fixtures.NavTuners = null;
    if (case.adaptive) {
        var twin = try PacksFixture.init(allocator, io, packs, thread_ptr);
        defer twin.deinit(allocator);
        var warm = twinWarmup(case);
        var cycle: usize = 0;
        while (warm.nextSettled(stepTunerSettle(&twin.system))) : (cycle += 1) try packsCycle(allocator, stepper, &twin, cycle, null);
        std.debug.assert(cycle <= group_field_march_cycles);
        carried = twin.system.tuners;
    }
    var fixture = try PacksFixture.init(allocator, io, packs, thread_ptr);
    defer fixture.deinit(allocator);
    const system = &fixture.system;
    if (carried) |tuners| system.tuners = tuners;

    var sink = CycleSink{ .accumulator = .init(item_count) };
    for (0..group_field_detour_moving_warmup_cycles) |cycle| try packsCycle(allocator, stepper, &fixture, cycle, null);
    const window = CycleWindow.begin(system, case);
    for (group_field_detour_moving_warmup_cycles..group_field_detour_moving_warmup_cycles + group_field_detour_moving_cycles) |cycle| {
        try packsCycle(allocator, stepper, &fixture, cycle, &sink);
    }
    // Every pack's field builds each rekey and is sampled.
    const built_total = sink.totals.built;
    if (built_total < packs * group_field_detour_moving_cycles or sink.totals.samples == 0) return error.GroupFieldPacksNotEngaged;

    var stats = sink.accumulator.finish();
    sink.stage_report.write(&stats.details);
    writeFieldMemory(&stats.details, system);
    stats.output_count = built_total;
    stats.candidate_pairs = sink.totals.samples;
    stats.items_per_second = suite.itemsPerSecond(built_total, stats.mean_ns *| stats.iterations);
    window.report(&stats, system, case);
    return stats;
}

// Per-field coverage and memory of a system's fields, averaged over the built fields.
fn writeFieldMemory(details: *suite.DetailLines, system: *const PathfindingSystem) void {
    var fields: usize = 0;
    var covered: usize = 0;
    var blocks: usize = 0;
    var resident: usize = 0;
    for (system.group_fields.items) |*field| {
        if (field.state == .empty) continue;
        fields += 1;
        covered += field.pushed_count;
        blocks += field.used_blocks;
        resident += groupFieldResidentBytes(field);
    }
    if (fields == 0) return;
    details.print("fields={} per_field covered={} blocks={} resident={}B bytes_per_cell={} pool_grows={} pool_failures={}\n", .{
        fields,
        covered / fields,
        blocks / fields,
        resident / fields,
        resident / @max(@as(usize, 1), covered),
        system.group_field_pool_growth.perf.count,
        system.group_field_pool_failure.perf.count,
    });
}

const group_field_tunnel_side: u16 = 1024;
// Corridor pitch: one corridor row and column per default nav chunk.
const group_field_tunnel_pitch: u16 = default_chunk_size_tiles;
const group_field_tunnel_fields: usize = 4;
const group_field_tunnel_agents: usize = 8;
const group_field_tunnel_build_guard: usize = 256;

// The lattice: every cell off the corridor rows and columns blocks.
fn tunnelLatticeCells(allocator: std.mem.Allocator) ![]CellCoord {
    var cells: std.ArrayList(CellCoord) = .empty;
    errdefer cells.deinit(allocator);
    for (0..group_field_tunnel_side) |y| {
        if (y % group_field_tunnel_pitch == 0) continue;
        for (0..group_field_tunnel_side) |x| {
            if (x % group_field_tunnel_pitch == 0) continue;
            try cells.append(allocator, .{ .x = @intCast(x), .y = @intCast(y) });
        }
    }
    return cells.toOwnedSlice(allocator);
}

// Each field's crowd stands on the corridor row through its goal, the goal at a corridor
// crossing in its own quadrant.
fn tunnelRequests(open: *const OpenWorld, requests: []PathRequest) void {
    const side = group_field_tunnel_side;
    const goals = [group_field_tunnel_fields]CellCoord{ .{ .x = side / 4, .y = side / 4 }, .{ .x = 3 * side / 4, .y = side / 4 }, .{ .x = side / 4, .y = 3 * side / 4 }, .{ .x = 3 * side / 4, .y = 3 * side / 4 } };
    for (requests, 0..) |*request, index| {
        const goal = goals[index / group_field_tunnel_agents];
        // In range: a crowd's starts stay on its goal's corridor row.
        const start = CellCoord{ .x = goal.x + 2 + @as(u16, @intCast(index % group_field_tunnel_agents)), .y = goal.y };
        request.* = .{ .entity = undefined, .kind = .group, .start = open.cellCenter(start), .goal = open.cellCenter(goal) };
    }
}

// A group-field pass: the advance or the begin.
const TunnelPass = enum { advance, begin };

// One tunnel field build: its steps' time, and the busiest group-field begin or advance pass
// batch of its steps and which pass ran it.
const TunnelBuild = struct {
    elapsed_ns: u64 = 0,
    batch: BatchStats = .{},
    batch_pass: TunnelPass = .advance,
};

// Rebuilds the four fields from scratch (pools kept) until all are ready; times the steps,
// each added to `report` when given.
fn buildTunnelFields(io: std.Io, system: *PathfindingSystem, requests: *RangeOutputStream(PathRequest), thread_system: *ThreadSystem, case: suite.BenchmarkCase, agent_count: usize, report: ?*StageReport) !TunnelBuild {
    system.clearRuntimeState();
    var build = TunnelBuild{};
    for (0..group_field_tunnel_build_guard) |_| {
        const start_ns = suite.nowNs(io);
        const stats = try runColdOnce(system, requests, thread_system, case, agent_count, agent_count, agent_count);
        const step_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        build.elapsed_ns += step_ns;
        if (report) |stage_report| stage_report.add(step_ns, stats);
        for ([_]BatchStats{ stats.perf.group_field_batch, stats.perf.group_field_begin_batch }, [_]TunnelPass{ .advance, .begin }) |batch, pass| {
            if (batch.item_count > build.batch.item_count) {
                build.batch = batch;
                build.batch_pass = pass;
            }
        }
        var ready: usize = 0;
        for (system.group_fields.items) |field| ready += @intFromBool(field.state == .ready);
        if (ready == group_field_tunnel_fields) return build;
    }
    return error.GroupFieldTunnelBuildStalled;
}

fn runGroupFieldTunnelCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const agent_count = group_field_tunnel_fields * group_field_tunnel_agents;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;

    var open = try buildOpenWorld(allocator, io, group_field_tunnel_side, 1);
    var open_owned = true;
    errdefer if (open_owned) open.world.deinit();
    {
        const lattice = try tunnelLatticeCells(allocator);
        defer allocator.free(lattice);
        try writeLevelZeroCells(&open, lattice, open.blocking);
    }
    var requests: [group_field_tunnel_fields * group_field_tunnel_agents]PathRequest = undefined;
    tunnelRequests(&open, &requests);
    open_owned = false;
    var fixture = try initRouteFixture(allocator, open, &requests, .{
        .max_group_fields = group_field_tunnel_fields,
        .worker_participant_count = fixtures.participantCount(thread_ptr),
        .max_agent_budget = agent_count,
        .min_group_field_agents = group_field_tunnel_agents,
        .group_field_max_cells = item_count,
    }, thread_ptr);
    defer fixture.deinit();
    const system = &fixture.system;

    // Setup: the first build warms the fields' block pools, which persist across builds.
    _ = try buildTunnelFields(io, system, &fixture.requests, thread_ptr, case, agent_count, null);
    // A sample is one whole build; the tuned case settles every step tuner it runs.
    var warm = suite.Warmup.custom(case, coldWarmup(options), suite.adaptiveSettleIterationLimit(options));
    while (warm.nextSettled(stepTunerSettle(system))) _ = try buildTunnelFields(io, system, &fixture.requests, thread_ptr, case, agent_count, null);
    const settle = stepTunerSettle(system);
    const field_start = suite.TunerStart.of(&system.tuners.group_field, case);
    const field_begin_start = suite.TunerStart.of(&system.tuners.group_field_begin, case);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var stage_report = StageReport{};
    // Every build runs the same requests from a cleared state, so one pass supplies every
    // measured build's headline batch.
    var headline_pass: ?TunnelPass = null;
    for (0..@max(@as(usize, 1), coldIterations(options))) |_| {
        const built = try buildTunnelFields(io, system, &fixture.requests, thread_ptr, case, agent_count, &stage_report);
        accumulator.record(built.elapsed_ns, built.batch);
        if (headline_pass) |pass| {
            if (pass != built.batch_pass) return error.GroupFieldTunnelHeadlinePassShift;
        } else headline_pass = built.batch_pass;
    }
    var covered: usize = 0;
    for (system.group_fields.items) |field| covered += field.pushed_count;
    // Every field covers its cap: the lattice's corridor cells reach past the largest cap.
    if (covered != group_field_tunnel_fields * item_count) return error.GroupFieldTunnelShortOfCap;

    var stats = accumulator.finish();
    stage_report.write(&stats.details);
    writeFieldMemory(&stats.details, system);
    stats.output_count = covered;
    stats.items_per_second = suite.itemsPerSecond(covered, stats.mean_ns);
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        // The primary tuning is the pass that supplied the headline batch, so the row's shape
        // and tuning describe one pass; the other is secondary.
        const advance = suite.workTuningSummary(&system.tuners.group_field, field_start);
        const begin = suite.workTuningSummary(&system.tuners.group_field_begin, field_begin_start);
        const advance_leads = headline_pass.? == .advance;
        stats.work_tuning = if (advance_leads) advance else begin;
        stats.secondary_work_tuning = if (advance_leads) begin else advance;
    }
    return stats;
}
