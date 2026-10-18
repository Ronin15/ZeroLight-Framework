// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Pathfinding cache bench groups: scoped eviction and elastic capacity ramp and shrink.
//! A config whose nav storage exceeds the bench's nav-size limit fails with its
//! figure (`nav_size.checkNavSize`), and every config checks each part of the nav's
//! bytes against its charge (`nav_size.checkNavBytes`).

const std = @import("std");
const runtime_perf_log = @import("../../app/runtime_perf_log.zig");
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const offMainNs = @import("../../app/thread_system.zig").offMainNs;
const DataSystem = @import("../../game/data_system.zig").DataSystem;
const EntityId = @import("../../game/data_system.zig").EntityId;
const PathRequest = @import("../../game/simulation.zig").PathRequest;
const RangeOutputStream = @import("../../game/simulation.zig").RangeOutputStream;
const PathfindingCapacity = @import("../../game/systems/pathfinding.zig").PathfindingCapacity;
const PathfindingStats = @import("../../game/systems/pathfinding.zig").PathfindingStats;
const PathfindingSystem = @import("../../game/systems/pathfinding.zig").PathfindingSystem;
const default_max_solves_per_frame = @import("../../game/systems/pathfinding.zig").default_max_solves_per_frame;
const PathQueryKey = @import("../../game/systems/pathfinding/types.zig").PathQueryKey;
const cached_results_per_agent = @import("../../game/systems/pathfinding/types.zig").cached_results_per_agent;
const min_capacity_floor = @import("../../game/systems/pathfinding/types.zig").min_capacity_floor;
const NavUpdateStats = @import("../../game/systems/pathfinding/types.zig").NavUpdateStats;
const CellCoord = @import("../../game/world/system.zig").CellCoord;
const default_chunk_size_tiles = @import("../../game/world/system.zig").default_chunk_size_tiles;
const fixtures = @import("../fixtures.zig");
const pathfinding_test_support = @import("../../game/systems/pathfinding/test_support.zig");
const nav_size = @import("../nav_size.zig");
const suite = @import("../suite.zig");
const coldWarmup = @import("nav_fixtures.zig").coldWarmup;
const coldIterations = @import("nav_fixtures.zig").coldIterations;
const runColdOnce = @import("nav_fixtures.zig").runColdOnce;
const setPathStageTuners = @import("nav_fixtures.zig").setPathStageTuners;
const StageReport = @import("nav_fixtures.zig").StageReport;
const OpenWorld = @import("nav_fixtures.zig").OpenWorld;
const buildOpenWorld = @import("nav_fixtures.zig").buildOpenWorld;
const toggle_batch = @import("nav_fixtures.zig").toggle_batch;
const ReactFixture = @import("nav_fixtures.zig").ReactFixture;
const EvictReport = @import("nav_fixtures.zig").EvictReport;
const assembleReactFixture = @import("nav_fixtures.zig").assembleReactFixture;
const ChunkCoord = @import("nav_fixtures.zig").ChunkCoord;
const chunkCells = @import("nav_fixtures.zig").chunkCells;

// One timed dig on a 256² walkable level holding 1,000, 10,000, or 50,000 cached results
// of short paths (`EvictCode`): the cell turns blocking and the nav reaction runs, eviction
// included. The dig crosses the same few paths at every count, so it passes when flat in
// cached results. `outputs` is the results evicted. An untimed reset reopens the cell and
// re-solves the evicted results. The region configs (4, 16, or 64 chunks at 10,000 results)
// instead fill a chunk-aligned square of that many chunks in one step, crossing the routes of
// its rows: the dense-change reaction, which passes when linear in the region's chunks and
// the registrations its eviction visits. The churned config (64 chunks at 10,000 results)
// times the same region fill over a registry rebuilt through publish/evict churn before
// every timed reaction (untimed: rounds of seeded random digs inside the region's route
// rows, each reacted to, reopened, and re-solved); it passes when its eviction stages are
// within spread of the fresh registry's at the same config. Items/s is the path-registry
// entries the eviction visited per second. `--details` prints the eviction stages' shapes,
// the reaction's main-thread time, and the entries visited.
pub const evict_group = suite.BenchmarkGroup{
    .name = "pathfinding-evict",
    .item_label = EvictCode.label,
    .item_counts = &evict_item_counts,
    .runCase = runEvictCase,
    .write_workload = writeEvictWorkload,
};

// The agent count ramps linearly to 1,000, 4,000, or 16,000 (the item count) over 64
// steps, then holds until every agent's path is cached; each step every live agent
// requests its own distinct goal. Times the pathfinding updates of the whole ramp;
// `outputs` is the solves it took and `candidates` the solves past one per agent (cached
// results lost to eviction or a resize, then solved again). Passes when linear in agents with
// no re-solve.
pub const elastic_ramp_group = suite.BenchmarkGroup{
    .name = "pathfinding-elastic-ramp",
    .item_label = "agents at the ramp's top",
    .item_counts = &elastic_ramp_item_counts,
    .runCase = runElasticRampCase,
    .write_workload = writeElasticRampWorkload,
};

// The `pathfinding-elastic-ramp` ramp to 1,000, 4,000, or 16,000 agents (the item count),
// untimed, then a drop to the last-added eighth, whose results are the youngest and stay
// cached, held until the shrink window elapses. Times the step whose update shrinks the
// capacity, result cache included; that step and the hold step before it serve only cache
// hits. `outputs` is the cached results kept, `candidates` those moved to a lower owner id,
// `evictions` those evicted. Passes when the resize (step minus hold) grows at most linearly
// in the capacity it shrinks from. `--details` adds the hold step's time and the difference,
// the resize, split into its worker-side copy and the rest on the main thread, with the cache
// and agent capacities before and after.
pub const elastic_shrink_group = suite.BenchmarkGroup{
    .name = "pathfinding-elastic-shrink",
    .item_label = "agents before the drop",
    .item_counts = &elastic_ramp_item_counts,
    .runCase = runElasticShrinkCase,
    .write_workload = writeElasticShrinkWorkload,
};

// How the path registry was built before each timed reaction: by the cache fill alone, or
// through publish/evict churn after it.
const EvictRegistry = enum(u8) { fresh, churned };
const EvictCode = suite.ItemCode(struct { registry: EvictRegistry, region_chunks: usize, cached_results: usize }, &.{ 3, 7 });

// The dig at each result count, then the region axis at a fixed result count, then the
// churned registry at the largest region.
const evict_item_counts = [_]usize{
    EvictCode.of(.{ .registry = .fresh, .region_chunks = 0, .cached_results = 1_000 }),
    EvictCode.of(.{ .registry = .fresh, .region_chunks = 0, .cached_results = 10_000 }),
    EvictCode.of(.{ .registry = .fresh, .region_chunks = 0, .cached_results = 50_000 }),
    EvictCode.of(.{ .registry = .fresh, .region_chunks = 4, .cached_results = 10_000 }),
    EvictCode.of(.{ .registry = .fresh, .region_chunks = 16, .cached_results = 10_000 }),
    EvictCode.of(.{ .registry = .fresh, .region_chunks = 64, .cached_results = 10_000 }),
    EvictCode.of(.{ .registry = .churned, .region_chunks = 64, .cached_results = 10_000 }),
};
const elastic_ramp_item_counts = [_]usize{ 1_000, 4_000, 16_000 };

fn writeEvictWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("cached={} evicted={}", .{ stats.candidate_pairs, stats.output_count });
    if (view == .details) {
        try writer.writeByte(' ');
        try suite.writeNavStages(writer, stats);
    }
}

fn writeElasticRampWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("solves={} re_solves={}", .{ stats.output_count, stats.candidate_pairs });
}

fn writeElasticShrinkWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("kept={} moved={} evicted={}", .{ stats.output_count, stats.candidate_pairs, stats.cache_evictions });
}

// Short distinct-goal requests over a walkable 256² level: goal `i` on a 240-wide grid
// from cell (8, 8), its start 4 cells right and one down.
const short_route_side: u16 = 256;
const short_route_columns: usize = 240;
// Registry runs a short route holds: it crosses at most one chunk edge on each axis.
const short_route_runs: usize = 3;

fn shortRouteRequest(open: *const OpenWorld, entity: EntityId, index: usize) PathRequest {
    const goal: CellCoord = .{ .x = @intCast(8 + index % short_route_columns), .y = @intCast(8 + index / short_route_columns) };
    return .{
        .entity = entity,
        .start = open.cellCenter(.{ .x = goal.x + 4, .y = goal.y + 1 }),
        .goal = open.cellCenter(goal),
    };
}

fn buildShortRouteRequests(allocator: std.mem.Allocator, data: *DataSystem, open: *const OpenWorld, count: usize) ![]PathRequest {
    std.debug.assert(8 + count / short_route_columns + 1 < short_route_side);
    const requests = try allocator.alloc(PathRequest, count);
    errdefer allocator.free(requests);
    for (requests, 0..) |*request, index| request.* = shortRouteRequest(open, try data.createEntity(), index);
    return requests;
}

// The result cache holds `cached_results_per_agent` results per agent.
fn evictAgentBudget(result_count: usize) usize {
    return @divCeil(result_count, cached_results_per_agent);
}

// The evict dig: right of every goal column, so it crosses a few paths of the first
// goal rows at every count and is no request's goal.
const evict_dig_cell: CellCoord = .{ .x = 250, .y = 9 };

fn initShortRouteFixture(allocator: std.mem.Allocator, io: std.Io, result_count: usize, capacity: PathfindingCapacity, thread_system: ?*ThreadSystem) !ReactFixture {
    var open = try buildOpenWorld(allocator, io, short_route_side, 1);
    errdefer open.world.deinit();
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const requests = try buildShortRouteRequests(allocator, &data, &open, result_count);
    errdefer allocator.free(requests);
    return assembleReactFixture(allocator, &open, &data, requests, capacity, thread_system);
}

// The region config's square: chunk-aligned from chunk (2, 2), `edge` chunks a side.
fn evictRegionChunks(allocator: std.mem.Allocator, edge: u16) ![]ChunkCoord {
    if (2 + @as(usize, edge) > short_route_side / default_chunk_size_tiles) return error.EvictRegionTooLarge;
    const chunks = try allocator.alloc(ChunkCoord, @as(usize, edge) * edge);
    for (chunks, 0..) |*chunk, index| chunk.* = .{ .x = @intCast(2 + index % edge), .y = @intCast(2 + index / edge) };
    return chunks;
}

fn runEvictCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const code = try EvictCode.decode(item_count);
    if (code.registry == .churned and code.region_chunks == 0) return error.EvictChurnNeedsRegion;
    const region_chunks = code.region_chunks;
    const result_count = code.cached_results;
    const region_edge = std.math.cast(u16, std.math.sqrt(region_chunks)) orelse return error.EvictRegionTooLarge;
    if (@as(usize, region_edge) * region_edge != region_chunks) return error.EvictRegionNotSquare;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const participant_count = fixtures.participantCount(thread_ptr);
    const size_config = nav_size.NavSizeConfig{
        .side = short_route_side,
        .levels = 1,
        .participant_count = participant_count,
        .agent_budget = evictAgentBudget(result_count),
        .group_fields = 1,
        .long_results = 0,
        .runs_per_result = short_route_runs,
        // The dig's cell, or every cell of the region square; their chunks with their
        // neighbours.
        .batch = if (region_chunks == 0) toggle_batch else .{
            .mark_chunks = region_chunks * default_chunk_size_tiles * default_chunk_size_tiles,
            .links = 0,
            .keys = nav_size.squareBatchKeys(region_edge),
        },
    };
    try nav_size.checkNavSize(evict_group.name, item_count, case, size_config);

    var fixture = try initShortRouteFixture(allocator, io, result_count, nav_size.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    try nav_size.checkNavBytes(evict_group.name, item_count, size_config, &fixture.system);
    const region_cells: ?[]CellCoord = if (region_chunks == 0) null else region: {
        const chunks = try evictRegionChunks(allocator, region_edge);
        defer allocator.free(chunks);
        break :region try chunkCells(allocator, chunks, fixture.open.world.chunk_size_tiles);
    };
    defer if (region_cells) |cells| allocator.free(cells);
    const cells: []const CellCoord = region_cells orelse &.{evict_dig_cell};
    try fixture.changed.ensureTotalCapacity(allocator, cells.len);
    var churn: ?RegistryChurn = if (code.registry == .churned) try RegistryChurn.init(allocator, cells, result_count) else null;
    defer if (churn) |*registry_churn| registry_churn.deinit(allocator);
    fixtures.setNavTuners(&fixture.system, case);
    try fixture.fillCache(case, thread_ptr);
    if (churn) |*registry_churn| try registry_churn.run(io, &fixture, case, thread_ptr);

    for (0..options.warmup_iterations) |_| {
        _ = try fixture.changeAndReact(io, cells, fixture.open.blocking, thread_ptr);
        _ = try fixture.changeAndReact(io, cells, fixture.open.walkable, thread_ptr);
        try fixture.fillCache(case, thread_ptr);
        if (churn) |*registry_churn| try registry_churn.run(io, &fixture, case, thread_ptr);
    }
    var accumulator = suite.StatsAccumulator.init(item_count);
    var report = EvictReport{};
    var evicted: usize = 0;
    var last_stats: NavUpdateStats = .{};
    for (0..options.iterations) |_| {
        const reaction = try fixture.changeAndReact(io, cells, fixture.open.blocking, thread_ptr);
        evicted = result_count - fixture.cachedCount();
        // The reaction evicted exactly the results the cache lost.
        if (comptime runtime_perf_log.enabled) {
            if (reaction.stats.perf.evicted_results != evicted) return error.EvictCountMismatch;
        }
        last_stats = reaction.stats;
        accumulator.record(reaction.elapsed_ns, reaction.stats.remask_batch);
        report.add(reaction);
        _ = try fixture.changeAndReact(io, cells, fixture.open.walkable, thread_ptr);
        try fixture.fillCache(case, thread_ptr);
        if (churn) |*registry_churn| try registry_churn.run(io, &fixture, case, thread_ptr);
    }
    // The size config charges no long block.
    if (fixture.system.long_block_growth.count != 0) return error.ShortRouteTookLongBlock;
    try nav_size.checkNavBytes(evict_group.name, item_count, size_config, &fixture.system);
    var stats = accumulator.finish();
    report.write(&stats.details);
    stats.output_count = evicted;
    stats.cache_evictions = evicted;
    stats.candidate_pairs = result_count;
    // Registry entries the reaction's eviction visited per second.
    stats.items_per_second = suite.itemsPerSecond(report.visited, stats.mean_ns);
    stats.batch = suite.batchSummaryFromBatch(last_stats.remask_batch);
    stats.secondary_batch = suite.batchSummaryFromBatch(suite.perfBatch(last_stats.perf, "patch_batch"));
    return stats;
}

// Churn rounds before each timed reaction, and the cells each round digs.
const churn_rounds: usize = 4;
const churn_cells_per_round: usize = 256;
const churn_seed: u64 = 0x63_68_75_72;

// Publish/evict churn over the region's route rows: each round digs a seeded random set of
// those cells in one step (evicting the results routed through them), reopens them, and
// re-solves every evicted result, so the registry's runs are rebuilt from released entries.
const RegistryChurn = struct {
    // The region's cells on some result's route, shuffled per round.
    candidates: []CellCoord,
    prng: std.Random.DefaultPrng,

    fn init(allocator: std.mem.Allocator, region_cells: []const CellCoord, result_count: usize) !RegistryChurn {
        // Route rows: goals from row 8, each start one row below its goal.
        const last_route_row = 8 + @divCeil(result_count, short_route_columns);
        var count: usize = 0;
        for (region_cells) |cell| {
            if (cell.y >= 8 and cell.y <= last_route_row) count += 1;
        }
        if (count < churn_cells_per_round) return error.EvictChurnTooFewRouteCells;
        const candidates = try allocator.alloc(CellCoord, count);
        count = 0;
        for (region_cells) |cell| {
            if (cell.y < 8 or cell.y > last_route_row) continue;
            candidates[count] = cell;
            count += 1;
        }
        return .{ .candidates = candidates, .prng = std.Random.DefaultPrng.init(churn_seed) };
    }

    fn deinit(self: *RegistryChurn, allocator: std.mem.Allocator) void {
        allocator.free(self.candidates);
        self.* = undefined;
    }

    // Untimed churn rounds; `fixture.changed` was reserved for the region, which holds every
    // candidate.
    fn run(self: *RegistryChurn, io: std.Io, fixture: *ReactFixture, case: suite.BenchmarkCase, thread_system: *ThreadSystem) !void {
        std.debug.assert(fixture.changed.capacity >= churn_cells_per_round);
        for (0..churn_rounds) |_| {
            self.prng.random().shuffle(CellCoord, self.candidates);
            const cells = self.candidates[0..churn_cells_per_round];
            _ = try fixture.changeAndReact(io, cells, fixture.open.blocking, thread_system);
            _ = try fixture.changeAndReact(io, cells, fixture.open.walkable, thread_system);
            try fixture.fillCache(case, thread_system);
        }
    }
};

const elastic_ramp_steps: usize = 64;

const ElasticRamp = struct {
    elapsed_ns: u64 = 0,
    solves: usize = 0,
    // The solve stage of the step that solved the most.
    busiest_solve_batch: BatchStats = .{},
};

fn runElasticRampCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const participant_count = fixtures.participantCount(thread_ptr);
    const size_config = nav_size.NavSizeConfig{
        .side = short_route_side,
        .levels = 1,
        .participant_count = participant_count,
        .agent_budget = item_count,
        .group_fields = 1,
        .long_results = 0,
        .runs_per_result = short_route_runs,
        // Requests only: no marks batch.
        .batch = nav_size.NavBatch.none,
    };
    try nav_size.checkNavSize(elastic_ramp_group.name, item_count, case, size_config);
    const capacity = nav_size.navSizeCapacity(size_config);

    var open = try buildOpenWorld(allocator, io, short_route_side, 1);
    defer open.world.deinit();
    var data = DataSystem.init(allocator);
    defer data.deinit();
    const requests = try buildShortRouteRequests(allocator, &data, &open, item_count);
    defer allocator.free(requests);
    var stream = RangeOutputStream(PathRequest).init(allocator);
    defer stream.deinit();
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &open.world, thread_ptr);
    try nav_size.checkNavBytes(elastic_ramp_group.name, item_count, size_config, &system);
    setPathStageTuners(&system, case);

    for (0..options.warmup_iterations) |_| _ = try runElasticRamp(io, case, &system, capacity, &stream, requests, thread_ptr);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var last = ElasticRamp{};
    for (0..options.iterations) |_| {
        last = try runElasticRamp(io, case, &system, capacity, &stream, requests, thread_ptr);
        accumulator.record(last.elapsed_ns, last.busiest_solve_batch);
    }
    // The size config charges no long block.
    if (system.long_block_growth.count != 0) return error.ShortRouteTookLongBlock;
    try nav_size.checkNavBytes(elastic_ramp_group.name, item_count, size_config, &system);
    var stats = accumulator.finish();
    stats.output_count = last.solves;
    // A ramp ends with every agent's result cached once, so every solve past one per
    // agent re-solved a lost result.
    stats.candidate_pairs = last.solves - item_count;
    stats.items_per_second = suite.itemsPerSecond(last.solves, stats.mean_ns);
    return stats;
}

// One ramp from the reserved floor: resets the system to its reserve (untimed), then
// steps until every agent's result is cached. Times the pathfinding updates only.
fn runElasticRamp(io: std.Io, case: suite.BenchmarkCase, system: *PathfindingSystem, capacity: PathfindingCapacity, stream: *RangeOutputStream(PathRequest), requests: []const PathRequest, thread_system: *ThreadSystem) !ElasticRamp {
    try system.reserve(capacity);
    system.clearRuntimeState();
    const agent_total = requests.len;
    const step_limit = elastic_ramp_steps + 4 * @divCeil(agent_total, default_max_solves_per_frame) + elastic_ramp_steps;
    var ramp = ElasticRamp{};
    for (0..step_limit) |step| {
        const live = if (step < elastic_ramp_steps) agent_total * (step + 1) / elastic_ramp_steps else agent_total;
        try fixtures.writeRequests(stream, requests[0..live]);
        const start_ns = suite.nowNs(io);
        const step_stats = try runColdOnce(system, stream, thread_system, case, live, live, live);
        ramp.elapsed_ns += suite.elapsedNs(start_ns, suite.nowNs(io));
        // Every goal is reachable, so each solve caches one result.
        if (step_stats.unavailable_results != 0) return error.ElasticRampUnreachableGoal;
        ramp.solves += step_stats.solved_requests;
        if (step_stats.solve_batch.item_count > ramp.busiest_solve_batch.item_count) ramp.busiest_solve_batch = step_stats.solve_batch;
        if (live == agent_total and step_stats.cache_hits == agent_total) return ramp;
    }
    return error.ElasticRampStalled;
}

// The elastic-shrink drop keeps this fraction of the ramped agents.
const elastic_shrink_divisor: usize = 8;

// A cached result's key and owner id, read before the shrink step to count the results it
// moved.
const CachedPayload = struct {
    key: PathQueryKey,
    owner: u32,
};

const ElasticShrink = struct {
    // The shrink step and the hold step before it.
    step_ns: u64 = 0,
    hold_ns: u64 = 0,
    // The shrink step's resize copy on workers; zero when it ran inline.
    copy_ns: u64 = 0,
    step_stats: PathfindingStats = .{},
    agent_capacity_before: usize = 0,
    agent_capacity_after: usize = 0,
    cache_capacity_before: usize = 0,
    cache_capacity_after: usize = 0,
    kept: usize = 0,
    evicted: usize = 0,
    moved: usize = 0,
};

// Sums of the timed shrink steps' figures, printed under --details as means.
const ShrinkReport = struct {
    samples: usize = 0,
    step_ns: u128 = 0,
    hold_ns: u128 = 0,
    copy_ns: u128 = 0,
    last: ElasticShrink = .{},

    fn add(self: *ShrinkReport, shrink: ElasticShrink) void {
        self.samples += 1;
        self.step_ns += shrink.step_ns;
        self.hold_ns += shrink.hold_ns;
        self.copy_ns += shrink.copy_ns;
        self.last = shrink;
    }

    fn write(self: ShrinkReport, details: *suite.DetailLines) void {
        if (self.samples == 0 or self.step_ns == 0) return;
        const resize_ns = self.step_ns -| self.hold_ns;
        const resize_main_ns = resize_ns -| self.copy_ns;
        const samples: u128 = self.samples * std.time.ns_per_us;
        details.print("agents {}->{} cache {}->{} kept={} evicted={} moved={} step={}us hold={}us resize={}us ({}% of step) copy={}us resize_main={}us\n", .{
            self.last.agent_capacity_before,
            self.last.agent_capacity_after,
            self.last.cache_capacity_before,
            self.last.cache_capacity_after,
            self.last.kept,
            self.last.evicted,
            self.last.moved,
            @as(u64, @intCast(self.step_ns / samples)),
            @as(u64, @intCast(self.hold_ns / samples)),
            @as(u64, @intCast(resize_ns / samples)),
            @as(u64, @intCast(resize_ns * 100 / self.step_ns)),
            @as(u64, @intCast(self.copy_ns / samples)),
            @as(u64, @intCast(resize_main_ns / samples)),
        });
    }
};

fn runElasticShrinkCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    if (item_count / elastic_shrink_divisor < min_capacity_floor) return error.ElasticShrinkBelowCapacityFloor;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const participant_count = fixtures.participantCount(thread_ptr);
    const size_config = nav_size.NavSizeConfig{
        .side = short_route_side,
        .levels = 1,
        .participant_count = participant_count,
        .agent_budget = item_count,
        .group_fields = 1,
        .long_results = 0,
        .runs_per_result = short_route_runs,
        // Requests only: no marks batch.
        .batch = nav_size.NavBatch.none,
    };
    try nav_size.checkNavSize(elastic_shrink_group.name, item_count, case, size_config);
    const capacity = nav_size.navSizeCapacity(size_config);

    var open = try buildOpenWorld(allocator, io, short_route_side, 1);
    defer open.world.deinit();
    var data = DataSystem.init(allocator);
    defer data.deinit();
    const requests = try buildShortRouteRequests(allocator, &data, &open, item_count);
    defer allocator.free(requests);
    var stream = RangeOutputStream(PathRequest).init(allocator);
    defer stream.deinit();
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &open.world, thread_ptr);
    try nav_size.checkNavBytes(elastic_shrink_group.name, item_count, size_config, &system);
    setPathStageTuners(&system, case);
    var cached: std.ArrayList(CachedPayload) = .empty;
    defer cached.deinit(allocator);

    // Each iteration re-runs the whole ramp untimed, so the cold measurement budget applies.
    for (0..coldWarmup(options)) |_| _ = try runElasticShrink(allocator, io, case, &system, capacity, &stream, requests, &cached, thread_ptr);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var stage_report = StageReport{};
    var shrink_report = ShrinkReport{};
    for (0..coldIterations(options)) |_| {
        const shrink = try runElasticShrink(allocator, io, case, &system, capacity, &stream, requests, &cached, thread_ptr);
        accumulator.record(shrink.step_ns, shrink.step_stats.intake_batch);
        stage_report.add(shrink.step_ns, shrink.step_stats);
        shrink_report.add(shrink);
    }
    // The size config charges no long block.
    if (system.long_block_growth.count != 0) return error.ShortRouteTookLongBlock;

    try nav_size.checkNavBytes(elastic_shrink_group.name, item_count, size_config, &system);
    var stats = accumulator.finish();
    stage_report.write(&stats.details);
    shrink_report.write(&stats.details);
    stats.output_count = shrink_report.last.kept;
    stats.candidate_pairs = shrink_report.last.moved;
    stats.cache_evictions = shrink_report.last.evicted;
    return stats;
}

// One ramp to every agent (untimed), then the drop: hold steps until the shrink window has
// one step left, the last hold step timed as the control, then the timed shrink step. The
// held agents' results are cached throughout, so every held step serves hits only.
fn runElasticShrink(
    allocator: std.mem.Allocator,
    io: std.Io,
    case: suite.BenchmarkCase,
    system: *PathfindingSystem,
    capacity: PathfindingCapacity,
    stream: *RangeOutputStream(PathRequest),
    requests: []const PathRequest,
    cached: *std.ArrayList(CachedPayload),
    thread_system: *ThreadSystem,
) !ElasticShrink {
    _ = try runElasticRamp(io, case, system, capacity, stream, requests, thread_system);
    if (system.low_load_steps != 0) return error.ElasticShrinkRampLeftLowLoad;
    const held = requests[requests.len - requests.len / elastic_shrink_divisor ..];
    try fixtures.writeRequests(stream, held);
    const window = system.capacity.capacity_shrink_window;
    if (window < 2) return error.ElasticShrinkWindowTooShort;
    for (0..window - 2) |_| _ = try runHeldStep(system, stream, thread_system, case, held.len);

    var shrink = ElasticShrink{
        .agent_capacity_before = system.effective_agent_capacity,
        .cache_capacity_before = system.completed.logicalCapacity(),
    };
    const hold_start_ns = suite.nowNs(io);
    _ = try runHeldStep(system, stream, thread_system, case, held.len);
    shrink.hold_ns = suite.elapsedNs(hold_start_ns, suite.nowNs(io));
    if (system.effective_agent_capacity != shrink.agent_capacity_before) return error.ElasticShrinkEarly;

    cached.clearRetainingCapacity();
    try cached.ensureTotalCapacity(allocator, system.completed.count());
    for (system.completed.core.records.items, 0..) |record, owner| {
        if (record.live) cached.appendAssumeCapacity(.{ .key = system.completed.core.keyOf(@intCast(owner)), .owner = @intCast(owner) });
    }
    const step_start_ns = suite.nowNs(io);
    shrink.step_stats = try runHeldStep(system, stream, thread_system, case, held.len);
    shrink.step_ns = suite.elapsedNs(step_start_ns, suite.nowNs(io));
    shrink.copy_ns = offMainNs(shrink.step_stats.resize_copy_batch);
    shrink.agent_capacity_after = system.effective_agent_capacity;
    shrink.cache_capacity_after = system.completed.logicalCapacity();
    if (shrink.agent_capacity_after >= shrink.agent_capacity_before) return error.ElasticShrinkDidNotShrink;
    if (shrink.cache_capacity_after >= shrink.cache_capacity_before) return error.ElasticShrinkCacheDidNotShrink;
    // The step finished the whole shrink: copies done and pages freed, owner ops flushed,
    // and registry owner heads cut to the new capacity.
    if (system.completed.pendingMoves().len != 0 or system.completed.inline_pages.items.len != system.completed.inline_page_count) return error.ElasticShrinkPagesPending;
    if (system.completed.core.ownerLog().len != 0) return error.ElasticShrinkOpsPending;
    for (&system.path_index) |*shard| {
        if (shard.owner_heads.items.len > shrink.cache_capacity_after) return error.ElasticShrinkOwnerHeadsPending;
    }

    // A shrink keeps an entry's key and moves it only to another owner id.
    shrink.kept = system.completed.count();
    // The shrink evicts only what no longer fits.
    if (shrink.kept != @min(cached.items.len, shrink.cache_capacity_after)) return error.ElasticShrinkEvictedWrongCount;
    shrink.evicted = cached.items.len - shrink.kept;
    for (cached.items) |entry| {
        const owner = pathfinding_test_support.cacheOwnerOf(system.completed.core, entry.key) orelse continue;
        if (owner != entry.owner) shrink.moved += 1;
    }
    return shrink;
}

// One step of the held agents, which must be served by cache hits alone.
fn runHeldStep(system: *PathfindingSystem, stream: *RangeOutputStream(PathRequest), thread_system: *ThreadSystem, case: suite.BenchmarkCase, agent_count: usize) !PathfindingStats {
    const stats = try runColdOnce(system, stream, thread_system, case, agent_count, agent_count, agent_count);
    if (stats.cache_hits != agent_count or stats.solved_requests != 0) return error.ElasticShrinkHeldResultLost;
    return stats;
}
