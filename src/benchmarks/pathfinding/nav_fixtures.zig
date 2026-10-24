// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Pathfinding bench fixtures and reports shared by two or more of the group files in
//! this folder: cold-step drivers, open and route worlds, the reaction fixture, and the
//! toggle batch. Generic harness pieces stay in `suite.zig` and `../fixtures.zig`.

const std = @import("std");
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const offMainNs = @import("../../app/thread_system.zig").offMainNs;
const math = @import("../../core/math.zig");
const DataSystem = @import("../../game/data_system.zig").DataSystem;
const PathRequest = @import("../../game/simulation.zig").PathRequest;
const RangeOutputStream = @import("../../game/simulation.zig").RangeOutputStream;
const SimulationFrame = @import("../../game/simulation.zig").SimulationFrame;
const SimulationEvent = @import("../../game/simulation.zig").SimulationEvent;
const PathfindingCapacity = @import("../../game/systems/pathfinding.zig").PathfindingCapacity;
const PathfindingStats = @import("../../game/systems/pathfinding.zig").PathfindingStats;
const PathfindingSystem = @import("../../game/systems/pathfinding.zig").PathfindingSystem;
const PathfindingConfig = @import("../../game/systems/pathfinding.zig").PathfindingConfig;
const StaticColliderSystem = @import("../../game/systems/static_colliders.zig").StaticColliderSystem;
const default_max_solves_per_frame = @import("../../game/systems/pathfinding.zig").default_max_solves_per_frame;
const pathfinding_range_alignment_items = @import("../../game/systems/pathfinding.zig").pathfinding_range_alignment_items;
const flush_pair_count = @import("../../game/systems/pathfinding/publish.zig").flush_pair_count;
const NavUpdateStats = @import("../../game/systems/pathfinding/types.zig").NavUpdateStats;
const default_cache_ttl_steps = @import("../../game/systems/pathfinding/types.zig").default_cache_ttl_steps;
const WorldSystem = @import("../../game/world/system.zig").WorldSystem;
const CellCoord = @import("../../game/world/system.zig").CellCoord;
const TileId = @import("../../game/world/system.zig").TileId;
const fixtures = @import("../fixtures.zig");
const nav_size = @import("../nav_size.zig");
const suite = @import("../suite.zig");

// A cold step re-solves up to the per-step ceiling, so the cold groups take fewer warmup and
// measured samples than the suite's defaults; a smaller `--warmup`/`--iterations` still wins.
// The tuned case still settles at the suite's limit (`suite.adaptiveSettleIterationLimit`):
// production's update tuners persist across steps, so a cold step is no fresh one-off.
const cold_warmup_cap: usize = 1;
const cold_iteration_cap: usize = 5;

pub fn coldWarmup(options: suite.Options) usize {
    return @min(options.warmup_iterations, cold_warmup_cap);
}
pub fn coldIterations(options: suite.Options) usize {
    return @min(options.iterations, cold_iteration_cap);
}

/// Every tuner of `system`'s stage set (`fixtures.addNavTuners`): those a pathfinding step,
/// and its nav reaction, select. One no measured step selects stays unused, so a fixture's
/// setup runs only the measured step's shape.
pub fn stepTunerSettle(system: *const PathfindingSystem) suite.TunerSettle {
    return fixtures.navTunerSettle("", &system.tuners);
}

/// The update config of a cold step under `case` with the given solve and admission budgets.
pub fn coldStepConfig(case: suite.BenchmarkCase, solve_budget: usize, fallback_budget: usize) PathfindingConfig {
    return .{
        .items_per_range = case.stageItemsPerRange(pathfinding_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
        .max_solved_requests_per_step = solve_budget,
        .max_solve_admissions_per_step = fallback_budget,
    };
}

/// Moves the step clock past the result TTL, as that many idle steps would: each cached
/// goal's next request finds its result expired, removes it at intake, and solves it cold,
/// while every chunk that still holds a registration keeps its registry block. This is the
/// play shape of a cold request; `clearRuntimeState` is a nav rebuild's reset, which releases
/// every block. Pending work stays, as in play.
pub fn expireCachedResults(system: *PathfindingSystem) void {
    system.step_counter +%= default_cache_ttl_steps;
}

/// Steps `config` over no requests until nothing is pending: play drops pending work only by
/// solving it or by its second exhausted attempt.
pub fn drainPending(system: *PathfindingSystem, thread_system: *ThreadSystem, agent_count: usize, config: PathfindingConfig) !void {
    var empty = RangeOutputStream(PathRequest).init(system.allocator);
    defer empty.deinit();
    // Each entry takes at most two attempts, and a step with work pending admits one or more.
    var steps_left = 2 * system.pending.len + 1;
    while (system.pending.len != 0) : (steps_left -= 1) {
        if (steps_left == 0) return error.PendingDrainStalled;
        _ = try system.update(&empty, agent_count, thread_system, config);
    }
}

/// One pathfinding update under `case`; a fixed threaded case runs every update stage of
/// more than one range on workers. A registry flush that added registrations ran at least
/// one unit per pair and per add, on at most one worker per pair but one, and a fixed
/// threaded case flushes one range per configured range of units.
pub fn runColdOnce(system: *PathfindingSystem, requests: *RangeOutputStream(PathRequest), thread_system: *ThreadSystem, case: suite.BenchmarkCase, agent_count: usize, solve_budget: usize, fallback_budget: usize) !PathfindingStats {
    const config = coldStepConfig(case, solve_budget, fallback_budget);
    const stats = try system.update(requests, agent_count, thread_system, config);
    try suite.checkStagesDispatched(case, thread_system, config.items_per_range, &updateBatches(stats));
    // A shrink's registry rename pass, at its fixed shape, and the flush's bound count.
    try suite.checkStagesDispatched(case, thread_system, config.items_per_range, &.{ stats.perf.registry_rename_batch, stats.perf.registry_flush_count_batch });
    const flush = stats.perf.registry_flush_batch;
    const adds = stats.perf.registrations_added;
    if (adds != 0 and flush.item_count < flush_pair_count + adds) return error.RegistryFlushMissedUnits;
    if (flush.active_worker_threads > flush_pair_count - 1) return error.RegistryFlushPastPairWorkers;
    try suite.checkFixedRangeCount(case, thread_system, config.items_per_range, flush);
    return stats;
}

// An update's stage batches, in `StageReport` order.
fn updateBatches(stats: PathfindingStats) [update_stage_count]BatchStats {
    return .{ stats.perf.intake_batch, stats.perf.group_field_batch, stats.perf.group_field_begin_batch, stats.perf.solve_batch, stats.perf.publish_copy_batch, stats.perf.registry_flush_batch, stats.perf.resize_copy_batch };
}

const update_stage_count = 7;

// Worker-side time of an update's threaded stages; stages that ran inline add nothing.
fn offMainStageNs(stats: PathfindingStats) u64 {
    var total: u64 = 0;
    for (updateBatches(stats)) |batch| total += offMainNs(batch);
    return total;
}

// Stage shapes and the main-thread share of the timed pathfinding updates, printed
// under --details: each stage's shape is its busiest timed batch, and main time is each
// timed span minus its stages' worker-side time.
pub const StageReport = struct {
    main_ns: u128 = 0,
    timed_ns: u128 = 0,
    samples: usize = 0,
    // Main-thread time per update phase: the phase timer minus its stages' worker time.
    accept_main_ns: u128 = 0,
    group_main_ns: u128 = 0,
    solve_main_ns: u128 = 0,
    publish_ns: u128 = 0,
    // Intake, group-field advance, group-field begin, solve, publish copy, registry flush,
    // resize copy. The flush count and a shrink's rename pass are separate: neither is a
    // perf-log key.
    shapes: suite.StageShapes(update_stage_count) = .{},
    count: suite.StageShapes(1) = .{},
    // Route groups that count unsolved routes: the last timed step's outcome.
    routes: ?RouteOutcome = null,
    // Path-registry entries the timed updates added and removed.
    registrations_added: usize = 0,
    registrations_removed: usize = 0,
    // Requests and solves the timed updates answered unavailable from reach, and blocked
    // goals intake projected itself.
    unavailable: usize = 0,
    goal_fallbacks: usize = 0,

    pub fn add(self: *StageReport, elapsed_ns: u64, stats: PathfindingStats) void {
        self.samples += 1;
        self.timed_ns += elapsed_ns;
        self.main_ns += elapsed_ns -| offMainStageNs(stats) -| offMainNs(stats.perf.registry_flush_count_batch) -| offMainNs(stats.perf.registry_rename_batch);
        self.accept_main_ns += stats.accept_ns -| offMainNs(stats.perf.intake_batch);
        self.group_main_ns += stats.group_service_ns -| (offMainNs(stats.perf.group_field_batch) + offMainNs(stats.perf.group_field_begin_batch));
        self.solve_main_ns += stats.solve_ns -| offMainNs(stats.perf.solve_batch);
        self.publish_ns += stats.publish_ns -| offMainNs(stats.perf.publish_copy_batch);
        self.count.add(.{stats.perf.registry_flush_count_batch});
        self.registrations_added += stats.perf.registrations_added;
        self.registrations_removed += stats.perf.registrations_removed;
        self.unavailable += stats.perf.unavailable_results;
        self.goal_fallbacks += stats.perf.goal_fallbacks;
        self.shapes.add(updateBatches(stats));
    }

    pub fn write(self: StageReport, details: *suite.DetailLines) void {
        if (self.timed_ns == 0) return;
        var buffers: [update_stage_count][48]u8 = undefined;
        var labels: [update_stage_count][]const u8 = undefined;
        for (&buffers, &labels, 0..) |*buffer, *label, index| label.* = self.shapes.label(index, buffer);
        const samples: u128 = self.samples * std.time.ns_per_us;
        var count_buffer: [48]u8 = undefined;
        details.print("intake={s} group_field={s}/{s} solve={s} publish_copy={s} registry_flush={s} registry_flush_count={s} resize_copy={s} main={}us ({}%) main_phases accept={}us group={}us solve={}us publish={}us", .{
            labels[0],
            labels[1],
            labels[2],
            labels[3],
            labels[4],
            labels[5],
            self.count.label(0, &count_buffer),
            labels[6],
            @as(u64, @intCast(self.main_ns / self.samples / std.time.ns_per_us)),
            @as(u64, @intCast(self.main_ns * 100 / self.timed_ns)),
            @as(u64, @intCast(self.accept_main_ns / samples)),
            @as(u64, @intCast(self.group_main_ns / samples)),
            @as(u64, @intCast(self.solve_main_ns / samples)),
            @as(u64, @intCast(self.publish_ns / samples)),
        });
        if (self.routes) |routes| details.print(" routes solved={} unsolved={}", .{ routes.solved, routes.unsolved });
        details.print(" registrations +{}/-{} per update", .{ self.registrations_added / self.samples, self.registrations_removed / self.samples });
        if (self.unavailable + self.goal_fallbacks != 0) {
            details.print(" unavailable={} goal_fallbacks={} per update", .{
                self.unavailable / self.samples,
                self.goal_fallbacks / self.samples,
            });
        }
        details.print("\n", .{});
    }
};

// Walkable levels of `side`² tiles in default chunks, one floor band per level (level
// `i` owns layer `i`); `blocking` blocks movement.
pub const OpenWorld = struct {
    world: WorldSystem,
    walkable: TileId,
    blocking: TileId,

    fn floor(level: u16) usize {
        return level;
    }

    pub fn cellCenter(self: *const OpenWorld, cell: CellCoord) math.Vec2 {
        return .{
            .x = (@as(f32, @floatFromInt(cell.x)) + 0.5) * self.world.tile_size,
            .y = (@as(f32, @floatFromInt(cell.y)) + 0.5) * self.world.tile_size,
        };
    }
};

pub fn buildOpenWorld(allocator: std.mem.Allocator, io: std.Io, side: u16, levels: u16) !OpenWorld {
    var tileset = try fixtures.loadTilesetMeta(allocator, io);
    defer tileset.deinit();
    const meta = &tileset;
    var world = try fixtures.buildBandedWorld(allocator, meta, side, levels, "grass", "grass");
    errdefer world.deinit();
    const walkable = try world.requireTileByName(meta, "grass");
    const blocking = try world.requireTileByName(meta, "dirt");
    return .{ .world = world, .walkable = walkable, .blocking = blocking };
}

// Writes `tile` into `cells` on level 0 in one reserve scope.
pub fn writeLevelZeroCells(open: *OpenWorld, cells: []const CellCoord, tile: TileId) !void {
    try writeLevelCells(open, 0, cells, tile);
}

// Writes `tile` into `cells` on `level` in one reserve scope.
pub fn writeLevelCells(open: *OpenWorld, level: u16, cells: []const CellCoord, tile: TileId) !void {
    const layer = OpenWorld.floor(level);
    open.world.beginDenseCellWriteReserve();
    for (cells) |cell| try open.world.reserveDenseCellWrite(layer, cell.x, cell.y, tile);
    for (cells) |cell| _ = try open.world.setDenseTile(layer, cell.x, cell.y, tile);
}

// The chunk keys a marks batch toggling one cell patches: its chunk and four neighbours.
pub const toggle_batch_keys: usize = nav_size.squareBatchKeys(1);
pub const toggle_batch: nav_size.NavBatch = .{ .mark_chunks = 1, .links = 0, .keys = toggle_batch_keys };

// A world-backed nav with a fixed request set, timed one cold step at a time.
pub const RouteFixture = struct {
    open: OpenWorld,
    data: DataSystem,
    requests: RangeOutputStream(PathRequest),
    system: PathfindingSystem,

    pub fn deinit(self: *RouteFixture) void {
        self.system.deinit();
        self.requests.deinit();
        self.data.deinit();
        self.open.world.deinit();
        self.* = undefined;
    }
};

// Takes ownership of `open`; adds one entity per request.
pub fn initRouteFixture(allocator: std.mem.Allocator, open: OpenWorld, requests: []PathRequest, capacity: PathfindingCapacity, thread_system: *ThreadSystem) !RouteFixture {
    var owned_open = open;
    errdefer owned_open.world.deinit();
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    for (requests) |*request| request.entity = try data.createEntity();
    var stream = RangeOutputStream(PathRequest).init(allocator);
    errdefer stream.deinit();
    try fixtures.writeRequests(&stream, requests);
    var system = PathfindingSystem.init(allocator);
    errdefer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &owned_open.world, thread_system);
    return .{ .open = owned_open, .data = data, .requests = stream, .system = system };
}

pub const PlanarRoute = struct {
    start: CellCoord,
    goal: CellCoord,
};

const RouteOutcome = struct {
    solved: usize,
    unsolved: usize,
};

// A world-backed nav with its static colliders and requests, its terrain changed as a
// writer changes it and the post-commit nav reaction run on it.
pub const ReactFixture = struct {
    open: OpenWorld,
    data: DataSystem,
    colliders: StaticColliderSystem,
    requests: []PathRequest,
    stream: RangeOutputStream(PathRequest),
    empty: RangeOutputStream(PathRequest),
    system: PathfindingSystem,
    agent_count: usize,
    // The step the nav reaction runs in.
    frame: SimulationFrame,
    // The last change's tile events, each a cell whose blocking flipped.
    changed: std.ArrayList(SimulationEvent) = .empty,

    pub fn deinit(self: *ReactFixture, allocator: std.mem.Allocator) void {
        self.changed.deinit(allocator);
        self.frame.deinit();
        self.system.deinit();
        self.empty.deinit();
        self.stream.deinit();
        allocator.free(self.requests);
        self.colliders.deinit();
        self.data.deinit();
        self.open.world.deinit();
        self.* = undefined;
    }

    // Requests every result in batches the intake admits and drains each batch, until
    // every result reads available. A cache hit keeps its solve step, so a pass's own
    // steps can age a result past the TTL after that pass already served it; the next
    // pass re-solves those. Passes stop at one per solve step of a full generation,
    // plus one wave. Untimed.
    pub fn fillCache(self: *ReactFixture, case: suite.BenchmarkCase, thread_system: *ThreadSystem) !void {
        const pass_limit = @divCeil(self.requests.len, default_max_solves_per_frame) + 2;
        for (0..pass_limit) |_| {
            var start: usize = 0;
            while (start < self.requests.len) : (start += self.agent_count) {
                const end = @min(start + self.agent_count, self.requests.len);
                try fixtures.writeRequests(&self.stream, self.requests[start..end]);
                var step_stats = try runColdOnce(&self.system, &self.stream, thread_system, case, self.agent_count, self.agent_count, self.agent_count);
                var guard = @divCeil(self.agent_count, default_max_solves_per_frame) + 2;
                while (step_stats.perf.pending_requests != 0) : (guard -= 1) {
                    if (guard == 0) return error.EvictFillStalled;
                    step_stats = try runColdOnce(&self.system, &self.empty, thread_system, case, self.agent_count, self.agent_count, self.agent_count);
                }
            }
            if (self.cachedCount() == self.requests.len) return;
        }
        return error.EvictFillIncomplete;
    }

    // Requests whose path the cache serves. Untimed: one status query per request.
    pub fn cachedCount(self: *const ReactFixture) usize {
        var cached: usize = 0;
        for (self.requests) |request| {
            const view = self.system.statusForWorld(request.start_level, request.start, request.goal_level, request.goal, request.agent_class, null);
            if (view.status == .available) cached += 1;
        }
        return cached;
    }

    // Sets `cells` on level 0 to `tile` in one step as a terrain writer does (untimed: the
    // record reserve, then the write and its tile events), then times the writer's nav record
    // of the events and the post-commit nav reaction; returns the reaction's time and stats.
    // `changed` holds `cells.len` entries.
    pub fn changeAndReact(self: *ReactFixture, io: std.Io, cells: []const CellCoord, tile: TileId, thread_system: *ThreadSystem) !Reaction {
        return self.changeLevelAndReact(io, 0, cells, tile, thread_system);
    }

    // `changeAndReact` on `level`.
    pub fn changeLevelAndReact(self: *ReactFixture, io: std.Io, level: u16, cells: []const CellCoord, tile: TileId, thread_system: *ThreadSystem) !Reaction {
        const layer = OpenWorld.floor(level);
        self.changed.clearRetainingCapacity();
        try self.system.reserveTerrainNavRecord(cells.len);
        self.open.world.beginDenseCellWriteReserve();
        for (cells) |cell| try self.open.world.reserveDenseCellWrite(layer, cell.x, cell.y, tile);
        for (cells) |cell| {
            const changed = (try self.open.world.setDenseTile(layer, cell.x, cell.y, tile)) orelse return error.EvictDigUnchanged;
            if (changed.old_blocks_movement == changed.new_blocks_movement) return error.EvictDigUnchanged;
            self.changed.appendAssumeCapacity(.{ .stage = .structural_commit, .payload = .{ .world_tile_changed = changed } });
        }
        self.frame.beginStep();
        const version_before = self.system.graph.version;
        const start_ns = suite.nowNs(io);
        self.system.recordTerrainNavEvents(self.changed.items, &self.open.world, thread_system);
        const stats = try self.system.reactToPostCommitNavEvents(&self.frame, &self.colliders, &self.open.world, thread_system);
        const elapsed = suite.elapsedNs(start_ns, suite.nowNs(io));
        if (stats.incremental_rebuilds != 1) return error.EvictReactionUnchanged;
        if (self.system.graph.version != version_before) return error.EvictDigRebuiltNav;
        return .{ .elapsed_ns = elapsed, .stats = stats, .mark = self.system.perf.last_mark_batch };
    }
};

pub const Reaction = struct {
    elapsed_ns: u64,
    stats: NavUpdateStats,
    // The timed terrain record's `nav_mark` dispatch; empty for a reaction that timed no mark.
    mark: BatchStats = .{},
};

// Three stages' shapes in the timed nav reactions and the reactions' main-thread share and
// split: each reaction minus its worker-side stage time.
pub const ReactionStages = struct {
    samples: usize = 0,
    timed_ns: u128 = 0,
    main_ns: u128 = 0,
    shapes: suite.StageShapes(3) = .{},
    nav_main: suite.NavMainSummary = .{},

    pub fn add(self: *ReactionStages, reaction: Reaction, batches: [3]BatchStats) void {
        self.samples += 1;
        self.timed_ns += reaction.elapsed_ns;
        const main_ns = reaction.elapsed_ns -| reaction.stats.perf.off_main_stage_ns;
        self.main_ns += main_ns;
        self.nav_main.add(main_ns, reaction.stats);
        self.nav_main.endSample();
        self.shapes.add(batches);
    }

    // The stages' shapes, written into `buffers`.
    pub fn labels(self: *const ReactionStages, buffers: *[3][48]u8) [3][]const u8 {
        var stage_labels: [3][]const u8 = undefined;
        for (buffers, &stage_labels, 0..) |*buffer, *label, index| label.* = self.shapes.label(index, buffer);
        return stage_labels;
    }

    pub fn mainUsPerSample(self: ReactionStages) u64 {
        return @intCast(self.main_ns / self.samples / std.time.ns_per_us);
    }

    pub fn mainPercent(self: ReactionStages) u64 {
        return @intCast(self.main_ns * 100 / self.timed_ns);
    }
};

// The timed reactions' eviction stage shapes and main-thread share, printed under
// --details.
pub const EvictReport = struct {
    stages: ReactionStages = .{},
    count: suite.StageShapes(1) = .{},
    visited: usize = 0,
    evicted: usize = 0,

    pub fn add(self: *EvictReport, reaction: Reaction) void {
        self.stages.add(reaction, .{ reaction.stats.perf.evict_count_batch, reaction.stats.perf.evict_batch, reaction.stats.perf.evict_flush_batch });
        self.count.add(.{reaction.stats.perf.registry_flush_count_batch});
        self.visited = reaction.stats.perf.evict_entries_visited;
        self.evicted = reaction.stats.perf.evicted_results;
    }

    pub fn write(self: EvictReport, details: *suite.DetailLines) void {
        if (self.stages.timed_ns == 0) return;
        var shapes: [3][48]u8 = undefined;
        const labels = self.stages.labels(&shapes);
        var count_buffer: [48]u8 = undefined;
        var main_buffer: [320]u8 = undefined;
        details.print("evict_count={s} evict={s} evict_flush={s} registry_flush_count={s} main={}us ({}%) visited={} evicted={}{s}\n", .{
            labels[0],
            labels[1],
            labels[2],
            self.count.label(0, &count_buffer),
            self.stages.mainUsPerSample(),
            self.stages.mainPercent(),
            self.visited,
            self.evicted,
            suite.formatNavMainInto(&main_buffer, self.stages.nav_main),
        });
    }
};

// Builds the colliders and the world-backed nav over `open` and `data`, then moves them
// and `requests` into the fixture. On error they stay with the caller.
pub fn assembleReactFixture(allocator: std.mem.Allocator, open: *OpenWorld, data: *DataSystem, requests: []PathRequest, capacity: PathfindingCapacity, thread_system: *ThreadSystem) !ReactFixture {
    var colliders = StaticColliderSystem.init(allocator);
    errdefer colliders.deinit();
    const extent = PathfindingSystem.worldNavExtent(&open.world);
    try colliders.rebuild(data, try extent.colliderGeometry(), null);
    var system = PathfindingSystem.init(allocator);
    errdefer system.deinit();
    try system.reserve(capacity);
    try system.rebuildNavFromColliders(&colliders, extent, thread_system);
    return .{
        .open = open.*,
        .data = data.*,
        .colliders = colliders,
        .requests = requests,
        .stream = RangeOutputStream(PathRequest).init(allocator),
        .empty = RangeOutputStream(PathRequest).init(allocator),
        .system = system,
        .agent_count = capacity.max_agent_budget,
        .frame = SimulationFrame.init(allocator),
    };
}

// The far dig sits this many cells in from the level's far corner.
pub const pocket_dig_inset: u16 = 6;

pub fn pocketDigCell(side: u16) CellCoord {
    return .{ .x = side - pocket_dig_inset, .y = side - pocket_dig_inset };
}

// The agent budget of the toggle groups' fixtures, which request no paths.
const toggle_agent_budget: usize = 8;

// A chunk of a toggle fixture, in chunk coordinates.
pub const ChunkCoord = struct {
    x: u16,
    y: u16,
};

// Every cell of `chunks`, chunk by chunk in row-major order.
// The chunks lie inside the level, so their cells fit `u16`.
pub fn chunkCells(allocator: std.mem.Allocator, chunks: []const ChunkCoord, chunk_tiles: u16) ![]CellCoord {
    const per_chunk = @as(usize, chunk_tiles) * chunk_tiles;
    const cells = try allocator.alloc(CellCoord, chunks.len * per_chunk);
    for (chunks, 0..) |chunk, chunk_index| {
        for (0..per_chunk) |local| {
            cells[chunk_index * per_chunk + local] = .{
                .x = @intCast(@as(usize, chunk.x) * chunk_tiles + local % chunk_tiles),
                .y = @intCast(@as(usize, chunk.y) * chunk_tiles + local / chunk_tiles),
            };
        }
    }
    return cells;
}

// `batch`: the workload's largest marks batch.
pub fn toggleSizeConfig(side: usize, levels: usize, links: usize, participant_count: usize, batch: nav_size.NavBatch) nav_size.NavSizeConfig {
    return .{
        .side = side,
        .levels = levels,
        .links = links,
        .participant_count = participant_count,
        .agent_budget = toggle_agent_budget,
        .group_fields = 1,
        .long_results = 0,
        .batch = batch,
    };
}
