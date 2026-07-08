// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const ParallelRange = @import("../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../app/thread_system.zig").WorkerId;
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const math = @import("../core/math.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const PathRequest = @import("../game/simulation.zig").PathRequest;
const RangeOutputStream = @import("../game/simulation.zig").RangeOutputStream;
const PathfindingCapacity = @import("../game/systems/pathfinding.zig").PathfindingCapacity;
const PathfindingStats = @import("../game/systems/pathfinding.zig").PathfindingStats;
const PathfindingSystem = @import("../game/systems/pathfinding.zig").PathfindingSystem;
const default_max_fallback_requests_per_step = @import("../game/systems/pathfinding.zig").default_max_fallback_requests_per_step;
const default_max_solves_per_frame = @import("../game/systems/pathfinding.zig").default_max_solves_per_frame;
const pathfinding_range_alignment_items = @import("../game/systems/pathfinding.zig").pathfinding_range_alignment_items;
const AiDir = @import("../game/systems/ai.zig").AiDir;
const computeRequantizedGoal = @import("../game/systems/ai.zig").computeRequantizedGoal;
const default_goal_requantization_hysteresis_distance = @import("../game/systems/ai.zig").default_goal_requantization_hysteresis_distance;
const suite = @import("suite.zig");

// Headline solve curve: cold, DISTINCT-goal individual A* across the 512/frame ceiling.
// Each measured frame performs min(512, count) real solves and defers the rest, so this is
// a true cold solver-throughput curve (no goal-keyed dedup), not a single shared-goal solve.
pub const group = suite.BenchmarkGroup{
    .name = "pathfinding",
    .defaultItemCounts = coldSolveItemCounts,
    .runCase = runCase,
};

// Shared-goal dedup path (kept distinct from the headline solve curve): every agent shares
// one goal, so all but the first resolve via dedup/group-field off a single cold A* solve.
pub const dedup_group = suite.BenchmarkGroup{
    .name = "pathfinding-shared-goal",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runDedupCase,
};

// Multi-frame amortized drain: submit N >> 512 distinct goals once, then step successive
// frames WITHOUT clearing so `pending` carries the remainder and drains at the per-frame
// ceiling. Validates the cross-frame carry-over the 512 cap exists for.
pub const drain_group = suite.BenchmarkGroup{
    .name = "pathfinding-drain",
    .defaultItemCounts = drainItemCounts,
    .runCase = runDrainCase,
};

pub const fallback_group = suite.BenchmarkGroup{
    .name = "pathfinding-cache-open",
    .defaultItemCounts = fallbackDefaultItemCounts,
    .runCase = runFallbackCase,
};

pub const fallback_detour_group = suite.BenchmarkGroup{
    .name = "pathfinding-cache-detour",
    .defaultItemCounts = fallbackDefaultItemCounts,
    .runCase = runFallbackDetourCase,
};

pub const fallback_unreachable_group = suite.BenchmarkGroup{
    .name = "pathfinding-cache-unreachable",
    .defaultItemCounts = unreachableDefaultItemCounts,
    .runCase = runFallbackUnreachableCase,
};

pub const hard_fallback_group = suite.BenchmarkGroup{
    .name = "pathfinding-hard-fallback",
    .defaultItemCounts = fallbackDefaultItemCounts,
    .runCase = runHardFallbackCase,
};

pub const hard_fallback_budget_group = suite.BenchmarkGroup{
    .name = "pathfinding-hard-fallback-budget",
    .defaultItemCounts = fallbackDefaultItemCounts,
    .runCase = runHardFallbackBudgetCase,
};

// Escalated (tier-1) detour guard: a full-height wall with a single gap far from the
// start/goal line forces the longest possible corridor detour — the shape of the
// game-breaking FPS-drop bug (agents pathfinding around a large obstacle, e.g. a lake)
// the two-tier retry ladder (PendingRequest.tier) fixed. Both tiers use FIXED budgets
// (default_max_abstract_nodes for tier 0, default_tier1_abstract_node_cap for tier 1 —
// never derived from or scaled to world/graph size, see types.zig), so per-query cost
// stays bounded independent of grid size; item_count here is the grid SIDE in cells (not
// an agent count), chosen to stay well under the fixed tier-1 budget regardless of
// profile. The scenario that mattered was ONE agent's ONE worst-case long-range solve (a
// simultaneous crowd of them is bounded separately by max_escalated_solves_per_step, not
// this case). tier0_abstract_node_cap is forced deliberately tiny so the FIRST attempt
// exhausts regardless of grid size — exercising the real promote-to-tier-1 path against
// the fixed tier-1 budget. Measures the COLD escalated (tier-1) solve only, so a
// regression that reintroduces the unbounded retry storm, or a detour this grid size that
// no longer fits the fixed tier-1 budget, shows up here as a wall-clock regression or a
// failed debug-assert.
pub const escalated_detour_group = suite.BenchmarkGroup{
    .name = "pathfinding-escalated-detour",
    .defaultItemCounts = escalatedDetourItemCounts,
    .runCase = runEscalatedDetourCase,
};

// Shared-goal flow field around a large obstacle at PRODUCTION nav-grid scale
// (256x256, matching game_demo_state's procedural world) with a demo-scale pursuit
// pack (~24 agents) declaring `.group`. This is the water-adjacent FPS-drop shape:
// a chasing pack whose shared goal re-keys often, near a large blocked region (the
// same wall/gap shape as escalated_detour_group). With min_group_field_agents
// pinned to a fixed 8 (matching game_demo_state.proceduralPathfindingCapacity), the
// pack crosses the threshold and the managed flow field (serviceGroupFields /
// ensureGroupField) engages, so once built every re-key is answered by a field
// sample instead of a per-agent tier-0/tier-1 A* re-solve. Measures the STEADY-STATE
// ready-field sampling cost (build happens during untimed setup) — a regression
// that stops the field from engaging at this population/grid combination shows up
// here as group_fields_built no longer 0 during measurement, or group_field_samples
// dropping below item_count.
pub const group_field_detour_group = suite.BenchmarkGroup{
    .name = "pathfinding-group-field-detour",
    .defaultItemCounts = groupFieldDetourItemCounts,
    .runCase = runGroupFieldDetourCase,
};

// Same production shape as group_field_detour_group, but the shared goal MOVES (re-keys) at
// the real chase cadence instead of staying static for the whole run, exercising
// ensureGroupField's rebuild throttle against a moving goal instead of only steady-state
// sampling of an already-ready field. See runGroupFieldDetourMovingCase.
pub const group_field_detour_moving_group = suite.BenchmarkGroup{
    .name = "pathfinding-group-field-detour-moving",
    .defaultItemCounts = groupFieldDetourItemCounts,
    .runCase = runGroupFieldDetourMovingCase,
};

// Same production shape and per-step chase cadence as group_field_detour_moving_group, but
// the live goal advances CONTINUOUSLY at the real per-step player speed instead of jumping a
// whole nav cell at once, and the request goal only re-keys once that live position has
// moved past `src/game/systems/ai.zig`'s `default_goal_requantization_hysteresis_distance`
// from the last reported goal — calls the same `computeRequantizedGoal` pure function
// `AiSystem.requantizeGoal` wraps (AiConfig.goal_requantization_hysteresis_distance).
// This is the actual fix under test: proves fewer distinct-goal re-keys (and therefore
// fewer escalated tier-0/tier-1 solves) over the identical sustained chase that
// group_field_detour_moving_group measures with hysteresis disabled.
pub const group_field_detour_moving_hysteresis_group = suite.BenchmarkGroup{
    .name = "pathfinding-group-field-detour-moving-hysteresis",
    .defaultItemCounts = groupFieldDetourItemCounts,
    .runCase = runGroupFieldDetourMovingHysteresisCase,
};

// Query tier: per-agent statusForWorld against a WARM cache, distinct from the solve
// groups (which measure update) and from steering/ai (which measure avoidance). Each
// agent reads its own cached path mid-route, so this isolates the cache probe and the
// per-step waypoint derivation — the crowd-scale path-following lookup. The queries are
// read-only and independent, so they fan across workers (each agent owns its hint slot).
pub const query_group = suite.BenchmarkGroup{
    .name = "pathfinding-query",
    .defaultItemCounts = queryDefaultItemCounts,
    .runCase = runQueryCase,
};

const quick_counts = [_]usize{ 128, 512, 1024 };
const standard_counts = [_]usize{ 512, 1024, 4096 };
const stress_counts = [_]usize{ 4096, 10000 };
// Cold-solve curve sits at and well above the 512 ceiling so the deferral ratio is traced
// (e.g. 4096 -> 512 solved, 3584 deferred). Every count >= the ceiling. Counts are kept lean
// and capped below the 256x256-grid tier (10000): each cold row re-runs the full per-frame
// solve ceiling on a count-sized grid, so an extra big count costs seconds per profile.
const cold_solve_quick_counts = [_]usize{512};
const cold_solve_standard_counts = [_]usize{ 512, 1024, 2048 };
const cold_solve_stress_counts = [_]usize{ 2048, 4096 };
// Drain counts are deep queues (N >> 512); each cycle spans ceil(N/512) drain frames, so one
// count per profile (above the ceiling) already exercises the cross-frame carry-over.
const drain_quick_counts = [_]usize{1024};
const drain_standard_counts = [_]usize{2048};
const drain_stress_counts = [_]usize{4096};
const fallback_quick_counts = [_]usize{ 16, 64, 128 };
const fallback_standard_counts = [_]usize{ 64, 128, 256, 1024 };
const fallback_stress_counts = [_]usize{ 256, 512, 1024 };
const unreachable_quick_counts = [_]usize{ 8, 16, 32 };
const unreachable_standard_counts = [_]usize{ 16, 32, 64, 1024 };
const unreachable_stress_counts = [_]usize{ 64, 128, 1024 };
// Lean (two counts per profile): the query loop is cheap, and a crowd at and well above
// the per-frame solve ceiling is enough to show the cache-probe and waypoint-scan cost.
const query_quick_counts = [_]usize{ 256, 1024 };
const query_standard_counts = [_]usize{ 1024, 4096 };
const query_stress_counts = [_]usize{4096};
// Grid SIDE (cells), not agent count — see escalated_detour_group's doc comment. Kept
// well below the calibration repro's 256x256 production map so this stays CI-fast; the
// fixed tier-1 budget does not depend on grid size, so a smaller grid still exercises
// the real promote-to-tier-1 path once tier0 is forced to exhaust.
const escalated_detour_quick_counts = [_]usize{64};
const escalated_detour_standard_counts = [_]usize{96};
const escalated_detour_stress_counts = [_]usize{128};
// Item counts here are the shared-goal PACK size (agents), not the grid side — the
// grid is pinned at production scale (group_field_detour_grid_side) for every count
// and every profile, mirroring the demo's fixed ~24-mover pursuit pack.
const group_field_detour_quick_counts = [_]usize{24};
const group_field_detour_standard_counts = [_]usize{24};
const group_field_detour_stress_counts = [_]usize{ 24, 48 };
// Production nav-grid scale (matches game_demo_state's procedural world side).
const group_field_detour_grid_side: usize = 256;
// Untimed setup: fixed loop-safety bound on steps spent waiting for the field to
// finish building (default_group_field_build_budget cells/step), plus slack — never
// derived from grid size, just a guard against a stalled setup hanging the bench.
const group_field_detour_setup_guard: usize = 64;

// A cold pathfinding frame runs up to the per-frame solve ceiling of A* on a count-sized grid
// — orders of magnitude heavier than the vectorized subsystem benches the suite measurement
// defaults (warmup 5 / iterations 30 / adaptive settle up to 48) were sized for. A cold mean is
// stable in far fewer samples, so the COLD runners use this tighter budget to keep each profile
// well under a minute; the hot cache/query groups keep the full suite budget. User-supplied
// --warmup/--iterations smaller than these caps still win (min), so explicit overrides are honored.
const cold_warmup_cap: usize = 1;
const cold_iteration_cap: usize = 5;
const cold_settle_cap: usize = 4;

fn coldWarmup(options: suite.Options) usize {
    return @min(options.warmup_iterations, cold_warmup_cap);
}
fn coldIterations(options: suite.Options) usize {
    return @min(options.iterations, cold_iteration_cap);
}
fn coldSettleLimit(options: suite.Options) usize {
    return @min(suite.adaptiveSettleIterationLimit(options), cold_settle_cap);
}

const Workload = enum {
    common_goal,
    unique_open,
    blocked_detour,
    blocked_unreachable,
    hard_fallback,
};

const MeasurementMode = enum {
    // Warm cache: measures the cache-hit probe (no solve runs).
    hot_cache,
    // Cold per-cell A* fallback (heavy-obstacle field); serviced = fallback_requests.
    cold_fallback,
    // Cold mixed solve (abstract + fallback) on a representative map; serviced = solves.
    cold_solve,

    fn isCold(self: MeasurementMode) bool {
        return self != .hot_cache;
    }
};

const Fixture = struct {
    data: DataSystem,
    requests: RangeOutputStream(PathRequest),

    fn deinit(self: *Fixture) void {
        self.requests.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &quick_counts,
        .standard => &standard_counts,
        .stress => &stress_counts,
    };
}

pub fn coldSolveItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &cold_solve_quick_counts,
        .standard => &cold_solve_standard_counts,
        .stress => &cold_solve_stress_counts,
    };
}

pub fn drainItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &drain_quick_counts,
        .standard => &drain_standard_counts,
        .stress => &drain_stress_counts,
    };
}

pub fn fallbackDefaultItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &fallback_quick_counts,
        .standard => &fallback_standard_counts,
        .stress => &fallback_stress_counts,
    };
}

pub fn unreachableDefaultItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &unreachable_quick_counts,
        .standard => &unreachable_standard_counts,
        .stress => &unreachable_stress_counts,
    };
}

pub fn queryDefaultItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &query_quick_counts,
        .standard => &query_standard_counts,
        .stress => &query_stress_counts,
    };
}

pub fn escalatedDetourItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &escalated_detour_quick_counts,
        .standard => &escalated_detour_standard_counts,
        .stress => &escalated_detour_stress_counts,
    };
}

pub fn groupFieldDetourItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &group_field_detour_quick_counts,
        .standard => &group_field_detour_standard_counts,
        .stress => &group_field_detour_stress_counts,
    };
}

pub fn createFixture(allocator: std.mem.Allocator, count: usize, workload: Workload) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    var requests = RangeOutputStream(PathRequest).init(allocator);
    errdefer requests.deinit();
    try requests.reserve(suite.rangeCount(count, suite.default_items_per_range), count);

    const side = fixtureGridSide(count, workload);
    try addObstacleField(&data, side, workload);
    for (0..count) |index| {
        const start_cell = requestStartCell(index, side, workload);
        const goal_cell = requestGoalCell(index, side, workload);
        const entity = try addEntity(&data, .{
            .x = @as(f32, @floatFromInt(start_cell.x)) * 32.0,
            .y = @as(f32, @floatFromInt(start_cell.y)) * 32.0,
        }, false);
        try appendRequest(&requests, .{
            .entity = entity,
            .start = .{
                .x = @as(f32, @floatFromInt(start_cell.x)) * 32.0 + 8.0,
                .y = @as(f32, @floatFromInt(start_cell.y)) * 32.0 + 8.0,
            },
            .goal = .{
                .x = @as(f32, @floatFromInt(goal_cell.x)) * 32.0 + 8.0,
                .y = @as(f32, @floatFromInt(goal_cell.y)) * 32.0 + 8.0,
            },
        });
    }

    return .{ .data = data, .requests = requests };
}

// Headline pathfinding solve curve: cold, DISTINCT-goal individual A* at and above the
// 512/frame amortization ceiling. min(512, count) solves run this frame; the remainder
// defers (the drain group measures the carry-over). Distinct goals mean no goal-keyed dedup,
// so this is a true cold solver-throughput curve, not a single shared-goal solve. The solve
// budget is the full count so the per-frame ceiling (not a bench-imposed budget) does the
// capping, and items_per_second reports solves actually serviced, not the requested count.
pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runWorkloadCase(allocator, io, options, case, item_count, .unique_open, .cold_solve, item_count, item_count);
}

// Shared-goal dedup path: every agent requests the SAME goal cell, so all but the first hash
// to one PathQueryKey (start is not part of the key) and resolve via dedup/group-field off a
// single cold A* solve per frame. The transient request state is cleared each iteration so
// every iteration is a fresh cold dedup. Throughput here is agents-resolved-via-dedup per
// second (the dedup IS the workload), NOT solver throughput.
pub fn runDedupCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try createFixture(allocator, item_count, .common_goal);
    defer fixture.deinit();
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    if (suite.adaptiveTunerForCase(case, pathfinding_range_alignment_items)) |tuner| {
        system.fallback_tuner = tuner;
    }

    const grid_side = fixtureGridSide(item_count, .common_goal);
    const world_extent = @as(f32, @floatFromInt(grid_side)) * 32.0;

    // Build the thread system first so the pathfinding system is sized for its real
    // participant count (workers + 1); each participant gets one O(cells) A* slot.
    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;

    try system.reserve(PathfindingCapacity{
        .max_group_fields = 8,
        .worker_participant_count = participant_count,
        // Let elastic capacity grow to the full benchmark item count (some profiles
        // exceed the default ceiling); agent_count drives the per-step caps.
        .max_agent_budget = @max(item_count, 1),
    });
    try system.rebuildStaticNavGrid(&fixture.data, world_extent, world_extent, 32.0);

    system.clearRuntimeState();
    _ = try runColdOnce(&system, &fixture.requests, if (threads) |*thread_system| thread_system else null, case, item_count, item_count, item_count);
    for (0..coldWarmup(options)) |_| {
        system.clearTransientRequestsRetainingFields();
        _ = try runColdOnce(&system, &fixture.requests, if (threads) |*thread_system| thread_system else null, case, item_count, item_count, item_count);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = coldSettleLimit(options);
        while (!system.fallback_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            system.clearTransientRequestsRetainingFields();
            _ = try runColdOnce(&system, &fixture.requests, if (threads) |*thread_system| thread_system else null, case, item_count, item_count, item_count);
        }
    }
    const solve_settled_before_measurement = if (case.adaptive) system.fallback_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    for (0..coldIterations(options)) |_| {
        system.clearTransientRequestsRetainingFields();
        const start_ns = suite.nowNs(io);
        last_stats = try runColdOnce(&system, &fixture.requests, if (threads) |*thread_system| thread_system else null, case, item_count, item_count, item_count);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.solveBatch());
    }

    var stats = accumulator.finish();
    // Goal-keyed dedup resolves a shared goal once; same-goal duplicates and warm cache hits
    // are also resolved agents. Count all so output_count reflects every requesting agent.
    stats.output_count = last_stats.available_results + last_stats.unavailable_results +
        last_stats.duplicate_requests + last_stats.cache_hits;
    stats.candidate_pairs = last_stats.duplicate_requests + last_stats.cache_hits;
    // Honest denominator: agents resolved via dedup this step (every requesting agent),
    // explicitly NOT the single A* solve. Equals item_count when nothing is dropped.
    if (stats.mean_ns != 0) {
        stats.items_per_second = suite.itemsPerSecond(stats.output_count, stats.mean_ns);
    }
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.fallback_tuner.report(), solve_settled_before_measurement);
    }
    return stats;
}

pub fn runFallbackCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runWorkloadCase(allocator, io, options, case, item_count, .unique_open, .hot_cache, item_count, item_count);
}

pub fn runFallbackDetourCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runWorkloadCase(allocator, io, options, case, item_count, .blocked_detour, .hot_cache, item_count, item_count);
}

pub fn runFallbackUnreachableCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runWorkloadCase(allocator, io, options, case, item_count, .blocked_unreachable, .hot_cache, item_count, item_count);
}

pub fn runHardFallbackCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runWorkloadCase(allocator, io, options, case, item_count, .hard_fallback, .cold_fallback, item_count, item_count);
}

pub fn runHardFallbackBudgetCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    const fallback_budget = @min(options.fallback_budget orelse hardFallbackBudget(item_count), item_count);
    return runWorkloadCase(allocator, io, options, case, item_count, .hard_fallback, .cold_fallback, item_count, fallback_budget);
}

fn hardFallbackBudget(item_count: usize) usize {
    return @min(item_count, default_max_fallback_requests_per_step);
}

fn runWorkloadCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, workload: Workload, mode: MeasurementMode, solve_budget: usize, fallback_budget: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try createFixture(allocator, item_count, workload);
    defer fixture.deinit();
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    if (suite.adaptiveTunerForCase(case, pathfinding_range_alignment_items)) |tuner| {
        system.fallback_tuner = tuner;
    }

    const grid_side = fixtureGridSide(item_count, workload);
    const world_extent = @as(f32, @floatFromInt(grid_side)) * 32.0;

    // Build the thread system first so the pathfinding A* scratch is sized for the
    // real participant count (workers + 1) during the nav build, not lazily.
    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;

    try system.reserve(PathfindingCapacity{
        .max_group_fields = 8,
        .worker_participant_count = participant_count,
        // Elastic capacity grows to the benchmark item count; the per-step solve and
        // fallback budgets are still applied via the config each runColdOnce.
        .max_agent_budget = @max(item_count, 1),
    });
    try system.rebuildStaticNavGrid(&fixture.data, world_extent, world_extent, 32.0);

    system.clearRuntimeState();
    _ = try runColdOnce(&system, &fixture.requests, if (threads) |*thread_system| thread_system else null, case, item_count, solve_budget, fallback_budget);

    // Cold modes re-solve the full per-frame ceiling every frame, so they use the tighter cold
    // measurement budget; the hot_cache mode is a cheap probe and keeps the full suite budget.
    const warmup_count = if (mode.isCold()) coldWarmup(options) else options.warmup_iterations;
    const measure_count = if (mode.isCold()) coldIterations(options) else options.iterations;
    for (0..warmup_count) |_| {
        if (mode.isCold()) system.clearRuntimeState();
        _ = try runColdOnce(&system, &fixture.requests, if (threads) |*thread_system| thread_system else null, case, item_count, solve_budget, fallback_budget);
    }
    if (case.adaptive and mode.isCold()) {
        var settle_guard: usize = 0;
        const settle_limit = coldSettleLimit(options);
        while (!system.fallback_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            system.clearRuntimeState();
            _ = try runColdOnce(&system, &fixture.requests, if (threads) |*thread_system| thread_system else null, case, item_count, solve_budget, fallback_budget);
        }
    }
    const settled_before_measurement = if (case.adaptive) system.fallback_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    for (0..measure_count) |_| {
        if (mode.isCold()) system.clearRuntimeState();
        const start_ns = suite.nowNs(io);
        last_stats = try runColdOnce(&system, &fixture.requests, if (threads) |*thread_system| thread_system else null, case, item_count, solve_budget, fallback_budget);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.solveBatch());
    }

    var stats = accumulator.finish();
    stats.output_count = last_stats.available_results + last_stats.unavailable_results;
    stats.deferred_count = last_stats.deferred_requests;
    stats.fallback_deferred_count = last_stats.fallback_deferred_requests;
    stats.cache_evictions = last_stats.cache_evictions;

    // Throughput must reflect items actually serviced this step, not the requested count.
    // Cold solves are capped at the per-frame amortization ceiling, so a 4096-request row
    // only performs min(4096, ceiling) solves and defers the rest to later frames; counting
    // all 4096 would inflate the curve to look like the solver scales past the cap when its
    // real per-step work is flat at the ceiling. The serviced count is mode-specific: cache
    // hits when warm, fallback A* solves when cold-fallback, abstract+fallback solves when
    // cold-solve. All three equal item_count when nothing is deferred, so honest rows match.
    const serviced: usize = switch (mode) {
        .hot_cache => last_stats.cache_hits,
        .cold_fallback => last_stats.fallback_requests,
        .cold_solve => stats.output_count,
    };
    stats.candidate_pairs = serviced;
    // Pin the "no silent cap drift" invariant: per-frame solves never exceed the ceiling.
    // cold-fallback counts fallback ATTEMPTS (slots filled), which is exactly the fallback
    // budget clamped to the ceiling. cold-solve counts SUCCESSES (results published); a long
    // open-grid path may exhaust the node budget and defer to a later frame, so its serviced
    // count is bounded by — not always equal to — the solve budget clamped to the ceiling.
    switch (mode) {
        .hot_cache => {},
        .cold_fallback => std.debug.assert(serviced == @min(item_count, @min(fallback_budget, default_max_solves_per_frame))),
        .cold_solve => std.debug.assert(serviced <= @min(item_count, @min(solve_budget, default_max_solves_per_frame))),
    }
    if (stats.mean_ns != 0) {
        stats.items_per_second = suite.itemsPerSecond(serviced, stats.mean_ns);
    }
    if (case.adaptive and mode.isCold()) {
        stats.work_tuning = suite.workTuningSummary(system.fallback_tuner.report(), settled_before_measurement);
    }
    return stats;
}

// Multi-frame amortized drain: submits N >> 512 distinct goals once per cycle, then steps
// successive frames over an EMPTY request stream WITHOUT clearing, so `pending` carries the
// remainder and drains at the per-frame ceiling. Each timed sample is one drain frame, so the
// mean reflects steady carry-over cost (flat ~ceiling solves) rather than the one-time accept.
pub fn runDrainCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    if (item_count <= default_max_solves_per_frame) {
        return suite.RunStats.skipped("count at or below the per-frame ceiling; nothing to drain");
    }

    var fixture = try createFixture(allocator, item_count, .unique_open);
    defer fixture.deinit();
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    if (suite.adaptiveTunerForCase(case, pathfinding_range_alignment_items)) |tuner| {
        system.fallback_tuner = tuner;
    }

    const grid_side = fixtureGridSide(item_count, .unique_open);
    const world_extent = @as(f32, @floatFromInt(grid_side)) * 32.0;

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;

    try system.reserve(PathfindingCapacity{
        .max_group_fields = 8,
        .worker_participant_count = participant_count,
        .max_agent_budget = @max(item_count, 1),
    });
    try system.rebuildStaticNavGrid(&fixture.data, world_extent, world_extent, 32.0);

    // Drain frames step over an empty stream so no new request is accepted; only the carried
    // pending queue is solved, isolating steady drain cost from the one-time accept.
    var empty = RangeOutputStream(PathRequest).init(allocator);
    defer empty.deinit();

    // Bounds one cycle's drain frames so a stalled queue (a request that never resolves)
    // can never hang the loop; ceil(N/ceiling) frames empty a healthy queue, plus slack.
    const drain_frame_budget = suite.rangeCount(item_count, default_max_solves_per_frame) + 2;

    // Drain is cold (each cycle re-solves ceil(N/ceiling) frames), so use the cold budget.
    const drain_samples = coldIterations(options);
    // Warmup: a couple of full drain cycles so pools are at high-water and the tuner trains.
    for (0..@max(@as(usize, 1), coldWarmup(options))) |_| {
        try refillDrainQueue(&system, &fixture.requests, thread_ptr, case, item_count);
        var guard: usize = drain_frame_budget;
        while (system.pending.items.len > 0 and guard > 0) : (guard -= 1) {
            const before = system.pending.items.len;
            _ = try runColdOnce(&system, &empty, thread_ptr, case, item_count, item_count, item_count);
            if (system.pending.items.len >= before) break; // no progress: stop draining this cycle
        }
    }

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    while (accumulator.iterations < drain_samples) {
        // Refill is untimed: clears completed/pending then accepts all N (this frame also
        // solves the first ceiling). The timed samples below are pure drain frames.
        try refillDrainQueue(&system, &fixture.requests, thread_ptr, case, item_count);
        var guard: usize = drain_frame_budget;
        while (system.pending.items.len > 0 and accumulator.iterations < drain_samples and guard > 0) : (guard -= 1) {
            const before = system.pending.items.len;
            const start_ns = suite.nowNs(io);
            last_stats = try runColdOnce(&system, &empty, thread_ptr, case, item_count, item_count, item_count);
            const end_ns = suite.nowNs(io);
            accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.solveBatch());
            if (system.pending.items.len >= before) break; // no progress: refill next cycle
        }
    }

    var stats = accumulator.finish();
    stats.output_count = last_stats.available_results + last_stats.unavailable_results;
    stats.candidate_pairs = last_stats.solved_requests;
    stats.deferred_count = last_stats.deferred_requests;
    // Steady per-frame solver throughput: solves serviced in a drain frame, which stays flat
    // at the ceiling regardless of how deep the carried queue is — that flat per-frame solve
    // count while `pending` drains is the amortization (per-frame wall cost tracks grid size,
    // not queue depth).
    if (stats.mean_ns != 0) {
        stats.items_per_second = suite.itemsPerSecond(last_stats.solved_requests, stats.mean_ns);
    }
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.fallback_tuner.report(), false);
    }
    return stats;
}

// Resets the result/pending state and accepts all N distinct goals in one frame, so the next
// frames drain the carried remainder. The accept frame itself solves the first ceiling.
fn refillDrainQueue(system: *PathfindingSystem, requests: *RangeOutputStream(PathRequest), thread_system: ?*ThreadSystem, case: suite.BenchmarkCase, agent_count: usize) !void {
    system.clearTransientRequestsRetainingFields();
    _ = try runColdOnce(system, requests, thread_system, case, agent_count, agent_count, agent_count);
}

fn runColdOnce(system: *PathfindingSystem, requests: *RangeOutputStream(PathRequest), thread_system: ?*ThreadSystem, case: suite.BenchmarkCase, agent_count: usize, solve_budget: usize, fallback_budget: usize) !PathfindingStats {
    if (!case.usesThreadSystem()) {
        return try system.updateSerial(requests, agent_count, .{
            .max_solved_requests_per_step = solve_budget,
            .max_fallback_requests_per_step = fallback_budget,
        });
    }
    return try system.update(requests, agent_count, thread_system.?, .{
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
        .max_solved_requests_per_step = solve_budget,
        .max_fallback_requests_per_step = fallback_budget,
    });
}

fn benchmarkItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(pathfinding_range_alignment_items) orelse
        suite.alignItemCount(suite.default_items_per_range, pathfinding_range_alignment_items);
}

const QueryContext = struct {
    system: *const PathfindingSystem,
    // Per-agent query inputs, all indexed by agent. starts[i] is the agent's CURRENT cell
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
    for (range.start..range.end) |i| {
        const view = ctx.system.statusForWorld(0, ctx.starts[i], 0, ctx.goals[i], .default, &ctx.hints[i]);
        ctx.sink[i] = @intFromEnum(view.status);
    }
}

fn runQueries(ctx: *QueryContext, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase, item_count: usize) BatchStats {
    if (thread_system) |ts| {
        return ts.parallelForWithOptions(item_count, ctx, queryJob, .{
            .items_per_range = benchmarkItemsPerRange(case),
            .max_worker_threads = case.maxWorkerThreads(),
            .range_alignment_items = pathfinding_range_alignment_items,
            .adaptive = case.adaptive,
        });
    }
    queryJob(@ptrCast(ctx), .{ .start = 0, .end = item_count }, WorkerId.main);
    return suite.serialBatch(item_count, pathfinding_range_alignment_items);
}

// Per-agent statusForWorld against a warm cache: isolates the result-cache probe and the
// per-step waypoint derivation (the crowd path-following lookup). Agents are queried from
// the MIDPOINT of their own cached path so the waypoint scan has a deep match to find —
// exactly the cost the per-agent hint optimizes.
pub fn runQueryCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try createFixture(allocator, item_count, .unique_open);
    defer fixture.deinit();
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();

    const grid_side = fixtureGridSide(item_count, .unique_open);
    const world_extent = @as(f32, @floatFromInt(grid_side)) * 32.0;

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;

    try system.reserve(.{
        .max_group_fields = 8,
        .worker_participant_count = participant_count,
        .max_agent_budget = @max(item_count, 1),
    });
    try system.rebuildStaticNavGrid(&fixture.data, world_extent, world_extent, 32.0);

    // Warm the cache: solve every agent's path. Solves are capped per frame at
    // default_max_solves_per_frame, so run enough frames to drain the queue (re-submitted
    // already-cached requests are cheap no-ops). Derived from the real ceiling (not a
    // hand-picked constant) so a lowered ceiling still warms fully instead of silently
    // leaving this a partial-miss bench mislabeled as warm-cache.
    const warm_frames = item_count / default_max_solves_per_frame + 4;
    for (0..warm_frames) |_| {
        _ = try system.updateSerial(&fixture.requests, item_count, .{});
    }

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
        const goal_cell = requestGoalCell(i, grid_side, .unique_open);
        const goal_world = math.Vec2{ .x = @as(f32, @floatFromInt(goal_cell.x)) * 32.0 + 8.0, .y = @as(f32, @floatFromInt(goal_cell.y)) * 32.0 + 8.0 };
        goals[i] = goal_world;
        // Default query position: the agent's own start cell (front of the path).
        const start_cell = requestStartCell(i, grid_side, .unique_open);
        starts[i] = .{ .x = @as(f32, @floatFromInt(start_cell.x)) * 32.0 + 8.0, .y = @as(f32, @floatFromInt(start_cell.y)) * 32.0 + 8.0 };
        // If the path is cached, move the query position to its midpoint so the waypoint
        // derivation must locate a deep cell (the hint's target case).
        if (system.graph.keyForWorld(0, goal_world, .default)) |key| {
            if (system.completed.slotIndex(key)) |slot| {
                const path = system.completed.pathSlice(slot, system.completed.resultAt(slot).path_len);
                if (path.len > 0) {
                    starts[i] = grid.cellCenter(path[path.len / 2]);
                    warm_paths += 1;
                }
            }
        }
    }

    // Every agent's path must be resident before the timed loop, or this silently measures
    // the cache-miss path while labeled a warm-cache bench (see the group-field cases'
    // analogous group_field_samples assert).
    std.debug.assert(warm_paths == item_count);

    var context = QueryContext{ .system = &system, .starts = starts, .goals = goals, .hints = hints, .sink = sink };

    // Warmup also settles each agent's hint to its midpoint index.
    for (0..options.warmup_iterations) |_| {
        _ = runQueries(&context, if (threads) |*thread_system| thread_system else null, case, item_count);
    }

    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const batch = runQueries(&context, if (threads) |*thread_system| thread_system else null, case, item_count);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), batch);
    }

    var stats = accumulator.finish();
    stats.output_count = item_count;
    stats.candidate_pairs = warm_paths; // agents served from a warm cached path
    return stats;
}

// Builds the single-agent, single-request large-obstacle-detour fixture: a full-height
// wall at the grid's horizontal midline with ONE gap near the TOP edge, and the
// start/goal pair placed near the BOTTOM edge on either side of the wall — the longest
// possible detour on a `side`-cell-square grid (see escalated_detour_group).
fn createEscalatedDetourFixture(allocator: std.mem.Allocator, side: usize) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    var requests = RangeOutputStream(PathRequest).init(allocator);
    errdefer requests.deinit();
    try requests.reserve(1, 1);

    const wall_x = side / 2;
    const gap_y: usize = 1;
    for (0..side) |y| {
        if (y == gap_y) continue;
        _ = try addEntity(&data, .{
            .x = @as(f32, @floatFromInt(wall_x)) * 32.0,
            .y = @as(f32, @floatFromInt(y)) * 32.0,
        }, true);
    }
    const far_y = side - 2;
    const entity = try addEntity(&data, .{
        .x = 2.0 * 32.0,
        .y = @as(f32, @floatFromInt(far_y)) * 32.0,
    }, false);
    try appendRequest(&requests, .{
        .entity = entity,
        .start = .{ .x = 2.0 * 32.0 + 8.0, .y = @as(f32, @floatFromInt(far_y)) * 32.0 + 8.0 },
        .goal = .{ .x = @as(f32, @floatFromInt(side - 2)) * 32.0 + 8.0, .y = @as(f32, @floatFromInt(far_y)) * 32.0 + 8.0 },
    });

    return .{ .data = data, .requests = requests };
}

// Measures the COLD ESCALATED (tier-1) solve only: an unmeasured setup step submits the
// request and lets the forced-tiny tier-0 attempt cap exhaust (promoting the request to
// tier 1, per compactPendingAfterSolve), then the timed step re-solves the SAME
// now-tier-1 request against the fixed tier-1 budget. See escalated_detour_group.
pub fn runEscalatedDetourCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const side = item_count;

    var fixture = try createEscalatedDetourFixture(allocator, side);
    defer fixture.deinit();
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();

    const world_extent = @as(f32, @floatFromInt(side)) * 32.0;
    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;

    try system.reserve(PathfindingCapacity{
        .max_group_fields = 1,
        .worker_participant_count = participant_count,
        .max_agent_budget = 8,
        // Deliberately tiny so the FIRST (tier-0) attempt exhausts regardless of grid
        // size, exercising the real promote-to-tier-1 path against the fixed tier-1
        // budget (see the group doc comment). Must stay below the fewest abstract-graph
        // hops any such detour could need — nav_graph.zig's discoverChunkPortals now
        // consolidates open boundary runs to one portal per side, so the graph is far
        // sparser than a per-cell scheme and a merely-small cap (64) is no longer
        // guaranteed to exhaust; 1 is the true floor, matching the same pattern already
        // used to force guaranteed tier-0 exhaustion in system.zig's own tests.
        .tier0_abstract_node_cap = 1,
    });
    try system.rebuildStaticNavGrid(&fixture.data, world_extent, world_extent, 32.0);

    var empty = RangeOutputStream(PathRequest).init(allocator);
    defer empty.deinit();

    // One tier-0 setup step per sample: submits the request (or re-submits a dedup no-op
    // after the first) and exhausts at the tiny tier-0 cap, promoting to tier 1.
    const promoteToTier1 = struct {
        fn run(sys: *PathfindingSystem, fixture_requests: *RangeOutputStream(PathRequest), threads_ptr: ?*ThreadSystem, bench_case: suite.BenchmarkCase) !void {
            sys.clearRuntimeState();
            const setup_stats = try runColdOnce(sys, fixture_requests, threads_ptr, bench_case, 1, 1, 1);
            std.debug.assert(setup_stats.budget_exhausted == 1);
            std.debug.assert(sys.pending.items.len == 1);
            std.debug.assert(sys.pending.items[0].tier == 1);
        }
    }.run;

    for (0..coldWarmup(options)) |_| {
        try promoteToTier1(&system, &fixture.requests, thread_ptr, case);
        _ = try runColdOnce(&system, &empty, thread_ptr, case, 1, 1, 1);
    }

    var accumulator = suite.StatsAccumulator.init(1);
    var last_stats = PathfindingStats{};
    for (0..coldIterations(options)) |_| {
        try promoteToTier1(&system, &fixture.requests, thread_ptr, case);
        const start_ns = suite.nowNs(io);
        last_stats = try runColdOnce(&system, &empty, thread_ptr, case, 1, 1, 1);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.solveBatch());
    }

    // Regression guard: the fixed tier-1 budget must actually resolve this grid size's
    // detour, not leave it budget_exhausted again (which would drop it to `.missing`
    // instead of solving — still not a false negative, but no longer what this
    // benchmark exists to measure).
    std.debug.assert(last_stats.available_results == 1);

    var stats = accumulator.finish();
    stats.output_count = last_stats.available_results + last_stats.unavailable_results;
    if (stats.mean_ns != 0) stats.items_per_second = suite.itemsPerSecond(stats.output_count, stats.mean_ns);
    return stats;
}

// Pursuit-pack shared-goal fixture: the same full-height-wall-with-one-gap shape as
// createEscalatedDetourFixture (the longest detour on a `side`-cell-square grid), but
// with `agent_count` agents spread along the near-side bottom rows, all declaring
// `.group` for the SAME goal cell across the gap — the water-adjacent chase-pack
// shape from the FPS-drop bug, shaped so the shared-goal flow field can engage.
fn createGroupFieldDetourFixture(allocator: std.mem.Allocator, side: usize, agent_count: usize) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    var requests = RangeOutputStream(PathRequest).init(allocator);
    errdefer requests.deinit();
    try requests.reserve(suite.rangeCount(agent_count, suite.default_items_per_range), agent_count);

    const wall_x = side / 2;
    const gap_y: usize = 1;
    for (0..side) |y| {
        if (y == gap_y) continue;
        _ = try addEntity(&data, .{
            .x = @as(f32, @floatFromInt(wall_x)) * 32.0,
            .y = @as(f32, @floatFromInt(y)) * 32.0,
        }, true);
    }

    const far_y = side - 2;
    const goal = math.Vec2{
        .x = @as(f32, @floatFromInt(side - 2)) * 32.0 + 8.0,
        .y = @as(f32, @floatFromInt(far_y)) * 32.0 + 8.0,
    };
    const lane_width = @max(@as(usize, 1), wall_x - 2);
    for (0..agent_count) |index| {
        const start_x = 2 + index % lane_width;
        const start_y = far_y -| (index / lane_width) * 3;
        const entity = try addEntity(&data, .{
            .x = @as(f32, @floatFromInt(start_x)) * 32.0,
            .y = @as(f32, @floatFromInt(start_y)) * 32.0,
        }, false);
        try appendRequest(&requests, .{
            .entity = entity,
            .kind = .group,
            .start = .{
                .x = @as(f32, @floatFromInt(start_x)) * 32.0 + 8.0,
                .y = @as(f32, @floatFromInt(start_y)) * 32.0 + 8.0,
            },
            .goal = goal,
        });
    }

    return .{ .data = data, .requests = requests };
}

// Measures the STEADY-STATE cost of a demo-scale pursuit pack (all sharing one goal
// across a large obstacle) once the managed flow field is ready: an untimed setup
// phase resubmits the same pack every step (mirroring AI movers re-requesting every
// tick) until every agent is answered via a field sample, then the timed phase keeps
// resubmitting the SAME pack. See group_field_detour_group's doc comment.
pub fn runGroupFieldDetourCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const side = group_field_detour_grid_side;

    var fixture = try createGroupFieldDetourFixture(allocator, side, item_count);
    defer fixture.deinit();
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    if (suite.adaptiveTunerForCase(case, pathfinding_range_alignment_items)) |tuner| {
        system.fallback_tuner = tuner;
    }

    const world_extent = @as(f32, @floatFromInt(side)) * 32.0;
    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;

    try system.reserve(PathfindingCapacity{
        .max_group_fields = 4,
        .worker_participant_count = participant_count,
        .max_agent_budget = @max(item_count, 1),
        // Fixed: mirrors the production pin in game_demo_state.proceduralPathfindingCapacity
        // that makes this the common case for the demo's pursuit pack (see the fix this
        // benchmark guards).
        .min_group_field_agents = 8,
    });
    try system.rebuildStaticNavGrid(&fixture.data, world_extent, world_extent, 32.0);

    // Untimed setup: keep resubmitting the shared-goal pack until the field is ready
    // and answering every agent by sampling, bounded by a fixed loop-safety guard.
    var last_stats = PathfindingStats{};
    var guard: usize = group_field_detour_setup_guard;
    while (guard > 0 and last_stats.group_field_samples < item_count) : (guard -= 1) {
        last_stats = try runColdOnce(&system, &fixture.requests, thread_ptr, case, item_count, item_count, item_count);
    }
    std.debug.assert(last_stats.group_field_samples == item_count);

    for (0..options.warmup_iterations) |_| {
        _ = try runColdOnce(&system, &fixture.requests, thread_ptr, case, item_count, item_count, item_count);
    }

    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_stats = try runColdOnce(&system, &fixture.requests, thread_ptr, case, item_count, item_count, item_count);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.solveBatch());
    }

    // Regression guard: once ready, the pinned threshold keeps the field engaged —
    // every step samples it, none fall back to a per-agent A* re-solve.
    std.debug.assert(last_stats.group_fields_built == 0);
    std.debug.assert(last_stats.group_field_samples == item_count);

    var stats = accumulator.finish();
    stats.output_count = last_stats.duplicate_requests;
    stats.candidate_pairs = last_stats.group_field_samples;
    if (stats.mean_ns != 0) stats.items_per_second = suite.itemsPerSecond(stats.output_count, stats.mean_ns);
    return stats;
}

// Same wall/gap detour and agent lane layout as createGroupFieldDetourFixture, but keeps
// the raw entities/starts (instead of a pre-baked static-goal request stream) so the case
// runner can rewrite the shared goal into a NEW nav cell periodically, reproducing the
// player re-keying the pack's shared goal as it crosses nav cells.
const MovingFixture = struct {
    data: DataSystem,
    entities: []EntityId,
    starts: []FixtureCell,

    fn deinit(self: *MovingFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.starts);
        allocator.free(self.entities);
        self.data.deinit();
        self.* = undefined;
    }
};

fn createGroupFieldDetourMovingFixture(allocator: std.mem.Allocator, side: usize, agent_count: usize) !MovingFixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    const wall_x = side / 2;
    const gap_y: usize = 1;
    for (0..side) |y| {
        if (y == gap_y) continue;
        _ = try addEntity(&data, .{
            .x = @as(f32, @floatFromInt(wall_x)) * 32.0,
            .y = @as(f32, @floatFromInt(y)) * 32.0,
        }, true);
    }

    const far_y = side - 2;
    const lane_width = @max(@as(usize, 1), wall_x - 2);
    const entities = try allocator.alloc(EntityId, agent_count);
    errdefer allocator.free(entities);
    const starts = try allocator.alloc(FixtureCell, agent_count);
    errdefer allocator.free(starts);
    for (0..agent_count) |index| {
        const start_x = 2 + index % lane_width;
        const start_y = far_y -| (index / lane_width) * 3;
        entities[index] = try addEntity(&data, .{
            .x = @as(f32, @floatFromInt(start_x)) * 32.0,
            .y = @as(f32, @floatFromInt(start_y)) * 32.0,
        }, false);
        starts[index] = .{ .x = start_x, .y = start_y };
    }

    return .{ .data = data, .entities = entities, .starts = starts };
}

// Rewrites `requests` with a fresh `.group` request per agent targeting `goal` — what every
// AI mover actually issues each fixed tick (see src/game/systems/ai.zig). A new goal cell
// here reproduces one player-crosses-a-nav-cell rekey.
fn writeGroupFieldDetourRequests(requests: *RangeOutputStream(PathRequest), entities: []const EntityId, starts: []const FixtureCell, goal: math.Vec2) !void {
    requests.clearRetainingCapacity();
    try requests.reserve(suite.rangeCount(entities.len, suite.default_items_per_range), entities.len);
    for (entities, starts) |entity, start| {
        try appendRequest(requests, .{
            .entity = entity,
            .kind = .group,
            .start = .{
                .x = @as(f32, @floatFromInt(start.x)) * 32.0 + 8.0,
                .y = @as(f32, @floatFromInt(start.y)) * 32.0 + 8.0,
            },
            .goal = goal,
        });
    }
}

// Fastest realistic re-key cadence: a moving `.group` goal quantizes to a new nav cell
// every ceil(cell_size / player_speed) fixed steps in the worst case (straight-line
// crossing). Player speed 120px/s (src/game/player.zig) over a 32px nav cell (types.zig
// default_cell_size) at 60Hz is 32/120*60 = 16 steps; kept as a literal (not imported —
// `Player.speed` is a private struct constant) so this bench states its own assumption
// explicitly. A tuned throttle must rebuild well within this window to matter.
const group_field_detour_rekey_period_steps: usize = 16;
// A worst-case full-grid detour (group_field_detour_grid_side^2 cells, per this bench's
// setup) needs cells/default_group_field_build_budget steps to reach `.ready` — well
// under the rekey cadence above, so a build reliably finishes and gets resampled before
// the next rekey supersedes it. This must stay BELOW group_field_detour_rekey_period_steps:
// a field that finishes only AFTER the goal has already moved again is always ready for an
// already-stale key, so it can never exact-match the current request and is never sampled
// (see types.zig's group_field_build_budget doc comment for the budget/throttle pairing
// this validates). The demo no longer pins its own override at this population (see
// game_demo_state.proceduralPathfindingCapacity) — this is purely this bench's own
// standalone exercise of the rebuild-under-motion mechanism.
const group_field_detour_rebuild_min_steps: u32 = 8;
// Rekey cycles run untimed before measuring, so the field has engaged past its first
// (always-immediate, empty-slot) build and any transient has settled.
const group_field_detour_moving_warmup_cycles: usize = 2;
// Rekey cycles measured.
const group_field_detour_moving_cycles: usize = 6;

// Measures a MOVING shared goal at the real chase cadence (group_field_detour_group's static
// case only proves steady-state sampling once ready; this proves the rebuild throttle
// actually lets the field catch up to a re-keying goal instead of staying permanently stale).
// Each cycle rewrites the pack's shared goal to a NEW nav cell it has never targeted before
// (a strict march, not an oscillation — revisiting an old goal would get served for free by
// the individual result cache and silently hide a dead field), then steps
// group_field_detour_rekey_period_steps frames.
//
// IMPORTANT: this does NOT prove escalated (tier-1) solves go to zero, and no assertion here
// claims that. The very FIRST request for a brand-new goal cell can never be answered by the
// field (acceptRequests and serviceGroupFields run in the same step the goal changes, so the
// field cannot already be `.ready` for a goal it has not started building), and PathQueryKey
// dedup already collapses that one solve to a single attempt regardless of the field — so one
// bounded solve per rekey is an expected, irreducible cost of a moving shared goal, not a
// regression. What a broken throttle actually breaks is everything AFTER that first solve: with
// the throttle at or above the real cadence (this bench's tuned group_field_detour_rebuild_min_steps
// matches types.zig's default_group_field_rebuild_min_steps precisely to stay below it),
// `ensureGroupField` finds the previous goal's field "stale" every single step but never
// re-clears the throttle wait, so the field never reaches `.ready` again and group_field_samples
// stays 0 for the rest of the run (proven by group_field_detour_group's static case going stale
// forever). A tuned throttle instead lets the field reach `.ready` partway through each cycle
// and serve the remainder cheaply.
pub fn runGroupFieldDetourMovingCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    // Cycle counts are fixed (like group_field_detour_setup_guard's loop-safety bound):
    // this case simulates a fixed number of real re-key cycles rather than repeating one
    // op, so --warmup/--iterations do not apply the way they do to the cold single-solve
    // cases.
    _ = options;
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const side = group_field_detour_grid_side;

    var fixture = try createGroupFieldDetourMovingFixture(allocator, side, item_count);
    defer fixture.deinit(allocator);
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    if (suite.adaptiveTunerForCase(case, pathfinding_range_alignment_items)) |tuner| {
        system.fallback_tuner = tuner;
    }

    const world_extent = @as(f32, @floatFromInt(side)) * 32.0;
    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;

    try system.reserve(PathfindingCapacity{
        .max_group_fields = 4,
        .worker_participant_count = participant_count,
        .max_agent_budget = @max(item_count, 1),
        // Mirrors game_demo_state.proceduralPathfindingCapacity's production pins.
        .min_group_field_agents = 8,
        .group_field_rebuild_min_steps = group_field_detour_rebuild_min_steps,
    });
    try system.rebuildStaticNavGrid(&fixture.data, world_extent, world_extent, 32.0);

    const far_y = side - 2;
    var requests = RangeOutputStream(PathRequest).init(allocator);
    defer requests.deinit();

    var escalated_total: usize = 0;
    var throttled_total: usize = 0;
    var built_total: usize = 0;
    var samples_total: usize = 0;
    var accumulator = suite.StatsAccumulator.init(item_count);

    const total_cycles = group_field_detour_moving_warmup_cycles + group_field_detour_moving_cycles;
    for (0..total_cycles) |cycle_index| {
        // Strictly monotonic march along the open (non-wall) column: every cell stays
        // reachable, and no cycle ever revisits an earlier cycle's exact goal cell, so a
        // later cycle cannot get a free ride off an already-cached individual result —
        // every cycle is a genuinely new rekey, like a player walking in one direction.
        const goal_y = far_y - cycle_index;
        const goal = math.Vec2{
            .x = @as(f32, @floatFromInt(side - 2)) * 32.0 + 8.0,
            .y = @as(f32, @floatFromInt(goal_y)) * 32.0 + 8.0,
        };
        try writeGroupFieldDetourRequests(&requests, fixture.entities, fixture.starts, goal);
        const measured = cycle_index >= group_field_detour_moving_warmup_cycles;
        for (0..group_field_detour_rekey_period_steps) |_| {
            const start_ns = suite.nowNs(io);
            const stats = try runColdOnce(&system, &requests, thread_ptr, case, item_count, item_count, item_count);
            const end_ns = suite.nowNs(io);
            if (measured) {
                accumulator.record(suite.elapsedNs(start_ns, end_ns), stats.solveBatch());
                escalated_total += stats.escalated_solves;
                throttled_total += stats.group_field_rebuild_throttled;
                built_total += stats.group_fields_built;
                samples_total += stats.group_field_samples;
            }
        }
    }

    // Regression guard: the tuned throttle must let the field actually reach `.ready` and
    // serve part of the run. A regression that leaves the throttle at/above the real cadence
    // (an earlier default_group_field_rebuild_min_steps of 30 vs this bench's 16-step cadence
    // is exactly how this was originally found) makes the field permanently stale — this
    // assert fires with samples_total == 0 in that case.
    std.debug.assert(samples_total > 0);
    // Escalated solves are expected (one bounded, dedup'd solve per genuinely new rekey — see
    // the doc comment above), but must stay bounded at one per cycle, not run away.
    std.debug.assert(escalated_total <= group_field_detour_moving_cycles);

    var stats = accumulator.finish();
    stats.output_count = escalated_total;
    stats.candidate_pairs = throttled_total;
    stats.deferred_count = built_total;
    stats.sample_count = samples_total;
    return stats;
}

// Same rekey cadence and cycle counts as the zero-hysteresis moving case, but the live
// goal position advances every SINGLE fixed step (2px/step == 120px/s at 60Hz, the same
// player speed the moving case's per-cycle jump is derived from) instead of jumping a
// whole nav cell at the top of each cycle — the granularity a real per-step goal
// requantization actually sees.
pub fn runGroupFieldDetourMovingHysteresisCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    _ = options;
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const side = group_field_detour_grid_side;

    var fixture = try createGroupFieldDetourMovingFixture(allocator, side, item_count);
    defer fixture.deinit(allocator);
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    if (suite.adaptiveTunerForCase(case, pathfinding_range_alignment_items)) |tuner| {
        system.fallback_tuner = tuner;
    }

    const world_extent = @as(f32, @floatFromInt(side)) * 32.0;
    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;

    try system.reserve(PathfindingCapacity{
        .max_group_fields = 4,
        .worker_participant_count = participant_count,
        .max_agent_budget = @max(item_count, 1),
        .min_group_field_agents = 8,
        .group_field_rebuild_min_steps = group_field_detour_rebuild_min_steps,
    });
    try system.rebuildStaticNavGrid(&fixture.data, world_extent, world_extent, 32.0);

    const far_y = side - 2;
    var requests = RangeOutputStream(PathRequest).init(allocator);
    defer requests.deinit();

    var escalated_total: usize = 0;
    var throttled_total: usize = 0;
    var built_total: usize = 0;
    var samples_total: usize = 0;
    var accumulator = suite.StatsAccumulator.init(item_count);

    const world_x = @as(f32, @floatFromInt(side - 2)) * 32.0 + 8.0;
    const start_world_y = @as(f32, @floatFromInt(far_y)) * 32.0 + 8.0;
    const px_per_step: f32 = 32.0 / @as(f32, @floatFromInt(group_field_detour_rekey_period_steps));

    var snapped_goal = math.Vec2{ .x = world_x, .y = start_world_y };
    var snapped_initialized = false;
    var last_written_goal: ?math.Vec2 = null;
    // Counts actual goal rewrites (post-hysteresis), not raw steps, so the escalation bound
    // below proves hysteresis is doing its job: without it, a per-step-advancing goal would
    // rewrite (and escalate) every single step instead of only every real re-key.
    var rewrite_count: usize = 0;

    const total_cycles = group_field_detour_moving_warmup_cycles + group_field_detour_moving_cycles;
    const total_steps = total_cycles * group_field_detour_rekey_period_steps;
    const warmup_steps = group_field_detour_moving_warmup_cycles * group_field_detour_rekey_period_steps;
    const measured_steps = total_steps - warmup_steps;

    for (0..total_steps) |step_index| {
        const live = math.Vec2{
            .x = world_x,
            .y = start_world_y - @as(f32, @floatFromInt(step_index)) * px_per_step,
        };
        // Calls the same pure comparison AiSystem.requantizeGoal wraps, so this bench
        // can't drift from the real hysteresis algorithm.
        const requantized = computeRequantizedGoal(
            AiDir{ .x = snapped_goal.x, .y = snapped_goal.y },
            snapped_initialized,
            AiDir{ .x = live.x, .y = live.y },
            default_goal_requantization_hysteresis_distance,
        );
        snapped_goal = .{ .x = requantized.goal.x, .y = requantized.goal.y };
        snapped_initialized = requantized.initialized;

        if (last_written_goal == null or last_written_goal.?.x != snapped_goal.x or last_written_goal.?.y != snapped_goal.y) {
            try writeGroupFieldDetourRequests(&requests, fixture.entities, fixture.starts, snapped_goal);
            last_written_goal = snapped_goal;
            if (step_index >= warmup_steps) rewrite_count += 1;
        }

        const measured = step_index >= warmup_steps;
        const start_ns = suite.nowNs(io);
        const stats = try runColdOnce(&system, &requests, thread_ptr, case, item_count, item_count, item_count);
        const end_ns = suite.nowNs(io);
        if (measured) {
            accumulator.record(suite.elapsedNs(start_ns, end_ns), stats.solveBatch());
            escalated_total += stats.escalated_solves;
            throttled_total += stats.group_field_rebuild_throttled;
            built_total += stats.group_fields_built;
            samples_total += stats.group_field_samples;
        }
    }

    // Regression guard: the throttle must still let the field reach `.ready` and serve
    // part of the run under hysteresis-throttled re-keys, same as the zero-hysteresis case.
    std.debug.assert(samples_total > 0);
    // The actual proof this case exists for: escalated solves are bounded by the
    // HYSTERESIS-REDUCED rewrite count, not the raw per-step count — a regression that
    // reintroduces a per-step re-key storm shows up here as escalated_total exceeding a
    // rewrite count that itself stayed small.
    std.debug.assert(rewrite_count < measured_steps);
    std.debug.assert(escalated_total <= rewrite_count);

    var stats = accumulator.finish();
    stats.output_count = escalated_total;
    stats.candidate_pairs = throttled_total;
    stats.deferred_count = built_total;
    stats.sample_count = samples_total;
    return stats;
}

fn appendRequest(stream: *RangeOutputStream(PathRequest), request: PathRequest) !void {
    const range_base = try stream.appendRangeCounts(1);
    stream.addCount(range_base, 1);
    try stream.prefixAppendedRanges(range_base);
    var writer = stream.rangeWriter(range_base);
    writer.write(request);
    writer.finish();
    stream.finishWrite();
}

fn addEntity(data: *DataSystem, position: math.Vec2, static: bool) !@import("../game/data_system.zig").EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = position, .previous_position = position });
    try data.setCollisionBounds(entity, .{ .size = .{ .x = 8, .y = 8 } });
    try data.setCollisionResponse(entity, .{ .mobility = if (static) .static else .dynamic });
    return entity;
}

const FixtureCell = struct {
    x: usize,
    y: usize,
};

fn requestStartCell(index: usize, side: usize, workload: Workload) FixtureCell {
    return switch (workload) {
        .common_goal, .unique_open => .{
            .x = index % side,
            .y = index / side,
        },
        .blocked_detour, .blocked_unreachable => .{
            .x = 1 + index % blockedLaneCount(side),
            .y = 1 + (index / blockedLaneCount(side)) % @max(@as(usize, 1), side - 2),
        },
        .hard_fallback => .{
            .x = 1 + (index / hardLaneCount(side)) % hardColumnCount(side),
            .y = 2 + (index % hardLaneCount(side)) * 3,
        },
    };
}

fn requestGoalCell(index: usize, side: usize, workload: Workload) FixtureCell {
    return switch (workload) {
        .common_goal => .{ .x = side - 2, .y = side - 2 },
        .unique_open => .{
            .x = side - 1 - index % side,
            .y = side - 1 - index / side,
        },
        .blocked_detour, .blocked_unreachable => .{
            .x = side - 2 - index % blockedLaneCount(side),
            .y = 1 + (index / blockedLaneCount(side)) % @max(@as(usize, 1), side - 2),
        },
        .hard_fallback => .{
            .x = side - 2 - (index / hardLaneCount(side)) % hardColumnCount(side),
            .y = 2 + (index % hardLaneCount(side)) * 3,
        },
    };
}

fn addObstacleField(data: *DataSystem, side: usize, workload: Workload) !void {
    switch (workload) {
        .common_goal, .unique_open => {},
        .blocked_detour => try addVerticalWall(data, side, true),
        .blocked_unreachable => try addVerticalWall(data, side, false),
        .hard_fallback => try addHardFallbackObstacles(data, side),
    }
}

fn addVerticalWall(data: *DataSystem, side: usize, with_gap: bool) !void {
    const wall_x = side / 2;
    const gap_y = side / 2;
    for (0..side) |y| {
        if (with_gap and y == gap_y) continue;
        _ = try addEntity(data, .{
            .x = @as(f32, @floatFromInt(wall_x)) * 32.0,
            .y = @as(f32, @floatFromInt(y)) * 32.0,
        }, true);
    }
}

fn blockedLaneCount(side: usize) usize {
    return @max(@as(usize, 1), side / 2 -| 2);
}

fn addHardFallbackObstacles(data: *DataSystem, side: usize) !void {
    const obstacle_x = side / 2;
    for (0..hardLaneCount(side)) |lane| {
        _ = try addEntity(data, .{
            .x = @as(f32, @floatFromInt(obstacle_x)) * 32.0,
            .y = @as(f32, @floatFromInt(2 + lane * 3)) * 32.0,
        }, true);
    }
}

fn hardLaneCount(side: usize) usize {
    return @max(@as(usize, 1), (side - 4) / 3);
}

fn hardColumnCount(side: usize) usize {
    return @max(@as(usize, 1), side / 2 - 1);
}

fn fixtureGridSide(item_count: usize, workload: Workload) usize {
    var side: usize = 16;
    while (side * side < item_count) side *= 2;
    if (workload == .hard_fallback) {
        while (hardLaneCount(side) * hardColumnCount(side) < item_count) side *= 2;
        return @max(side, @as(usize, 64));
    }
    return @max(side * 2, @as(usize, 64));
}
