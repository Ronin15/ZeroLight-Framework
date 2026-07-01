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
const PathRequest = @import("../game/simulation.zig").PathRequest;
const RangeOutputStream = @import("../game/simulation.zig").RangeOutputStream;
const PathfindingCapacity = @import("../game/systems/pathfinding.zig").PathfindingCapacity;
const PathfindingStats = @import("../game/systems/pathfinding.zig").PathfindingStats;
const PathfindingSystem = @import("../game/systems/pathfinding.zig").PathfindingSystem;
const default_max_fallback_requests_per_step = @import("../game/systems/pathfinding.zig").default_max_fallback_requests_per_step;
const default_max_solves_per_frame = @import("../game/systems/pathfinding.zig").default_max_solves_per_frame;
const pathfinding_range_alignment_items = @import("../game/systems/pathfinding.zig").pathfinding_range_alignment_items;
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

    // Warm the cache: solve every agent's path. Solves are capped per frame, so run enough
    // frames to drain the queue (re-submitted already-cached requests are cheap no-ops).
    const warm_frames = item_count / 256 + 4;
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

test "pathfinding hard fallback services the full ceiling across counts" {
    // Pins the unbudgeted hard-fallback invariant the runWorkloadCase cold_fallback assert
    // relies on: the single-cell-per-lane obstacle field forces 100% fallback at every count,
    // including the larger stress geometries (256/512/1024) where an abstract detour around the
    // blocking cell would otherwise be possible. Serviced is capped only by the per-frame solve
    // ceiling, so it equals min(count, ceiling). If a future fixture change let an agent route
    // abstractly, this fails loudly in Debug rather than only when a benchmark happens to run.
    const options = suite.Options{ .warmup_iterations = 0, .iterations = 1 };
    for ([_]usize{ 16, 64, 128, 256, 512, 1024 }) |count| {
        const expected = @min(count, default_max_solves_per_frame);
        const stats = try runHardFallbackCase(std.testing.allocator, std.testing.io, options, suite.default_cases[0], count);
        try std.testing.expectEqual(suite.RunStatus.measured, stats.status);
        try std.testing.expectEqual(count, stats.item_count);
        try std.testing.expectEqual(expected, stats.candidate_pairs);
        try std.testing.expectEqual(expected, stats.output_count);
    }
}
