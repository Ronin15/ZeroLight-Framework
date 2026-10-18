// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Pathfinding negative-result bench groups: steady, dig, and burst unreachable load.
//! A config whose nav storage exceeds the bench's nav-size limit fails with its
//! figure (`nav_size.checkNavSize`), and every config checks each part of the nav's
//! bytes against its charge (`nav_size.checkNavBytes`).

const std = @import("std");
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const offMainNs = @import("../../app/thread_system.zig").offMainNs;
const DataSystem = @import("../../game/data_system.zig").DataSystem;
const PathRequest = @import("../../game/simulation.zig").PathRequest;
const PathfindingCapacity = @import("../../game/systems/pathfinding.zig").PathfindingCapacity;
const PathfindingStats = @import("../../game/systems/pathfinding.zig").PathfindingStats;
const PathfindingSystem = @import("../../game/systems/pathfinding.zig").PathfindingSystem;
const GoalResolveStats = @import("../../game/systems/pathfinding/types.zig").GoalResolveStats;
const goal_scan_range_alignment_items = @import("../../game/systems/pathfinding/goal_table.zig").scan_range_alignment_items;
const CellCoord = @import("../../game/world/system.zig").CellCoord;
const fixtures = @import("../fixtures.zig");
const nav_size = @import("../nav_size.zig");
const suite = @import("../suite.zig");
const coldWarmup = @import("nav_fixtures.zig").coldWarmup;
const coldIterations = @import("nav_fixtures.zig").coldIterations;
const coldSettleLimit = @import("nav_fixtures.zig").coldSettleLimit;
const runColdOnce = @import("nav_fixtures.zig").runColdOnce;
const setPathStageTuners = @import("nav_fixtures.zig").setPathStageTuners;
const StageReport = @import("nav_fixtures.zig").StageReport;
const buildOpenWorld = @import("nav_fixtures.zig").buildOpenWorld;
const writeLevelZeroCells = @import("nav_fixtures.zig").writeLevelZeroCells;
const toggle_batch = @import("nav_fixtures.zig").toggle_batch;
const ReactFixture = @import("nav_fixtures.zig").ReactFixture;
const Reaction = @import("nav_fixtures.zig").Reaction;
const EvictReport = @import("nav_fixtures.zig").EvictReport;
const assembleReactFixture = @import("nav_fixtures.zig").assembleReactFixture;
const pocket_dig_inset = @import("nav_fixtures.zig").pocket_dig_inset;
const pocketDigCell = @import("nav_fixtures.zig").pocketDigCell;

// One step of the item count's requests from outside a sealed 80² pocket at the origin of a
// walkable 256² level, each to its own pocket goal: intake answers every request unavailable
// from reach, with no solve and nothing cached. The per-step load of unreachable requests.
// `outputs` is the requests answered unavailable. Passes when linear in requests.
pub const negative_steady_group = suite.BenchmarkGroup{
    .name = "pathfinding-negative-steady",
    .item_label = "unreachable path requests per step",
    .item_counts = &negative_steady_item_counts,
    .runCase = runNegativeSteadyCase,
    .write_workload = writeUnavailableWorkload,
};

// The item count's requests (`NegativeDigCode`) from outside a sealed 80² pocket at the origin
// of a walkable level, each to its own goal inside it. Each timed step toggles one far cell's
// blocking, runs the nav reaction, and updates the same requests; intake answers every request
// unavailable from reach, with no solve. `outputs` is the requests answered unavailable.
// Passes when flat in side and linear in requests. `--details` prints the update's stages, the
// reaction's remask and eviction stages with its main-thread share, and the reaction/update
// split.
pub const negative_dig_group = suite.BenchmarkGroup{
    .name = "pathfinding-negative-dig",
    .item_label = NegativeDigCode.label,
    .item_counts = &negative_dig_item_counts,
    .runCase = runNegativeDigCase,
    .write_workload = writeUnavailableWorkload,
};

// The item count's unreachable requests in one step (`BurstCode`). Four sealed 56² pockets
// line the top edge of a walkable 256² level; requesters start outside them from row 72.
// Variant 0: request `i` goes to its own cell of pocket `i mod 4`. Variant 1 (a blocked
// crowd): each pocket holds a 3x3 blocking block at its center, and request `i` goes to pocket
// `i mod 4`'s block center, a blocked goal whose nearest open cell lies inside the sealed
// pocket. One timed sample, on result state cleared before it (untimed), runs the goal resolve
// over every request and the step that submits them; a status query of every request follows,
// untimed in variant 0 and timed in variant 1. `outputs` is the requests answered unavailable;
// the workload adds the goal projections. Passes when the step answers every request with no
// search and nothing pending, linear in requests, with four projections for the blocked crowd
// at every size. `--details` prints the update stages and the goal resolve's stage shapes.
pub const negative_burst_group = suite.BenchmarkGroup{
    .name = "pathfinding-negative-burst",
    .item_label = BurstCode.label,
    .item_counts = &negative_burst_item_counts,
    .runCase = runNegativeBurstCase,
    .write_workload = writeBurstWorkload,
};

// The case's goal resolve over `intents`, as the pipeline's `path_goal_resolve` stage.
fn runResolveGoals(system: *PathfindingSystem, intents: []const PathRequest, thread_system: *ThreadSystem, case: suite.BenchmarkCase) !GoalResolveStats {
    return system.resolveGoals(PathRequest, intents, thread_system, .{
        .items_per_range = case.stageItemsPerRange(goal_scan_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

const NegativeDigCode = suite.ItemCode(struct { level_side: u16, requests: u16 }, &.{3});
const BurstCode = suite.ItemCode(struct { variant: BurstVariant, requests: usize }, &.{6});

const negative_steady_item_counts = [_]usize{ 256, 1024, 4096 };
const negative_dig_item_counts = [_]usize{
    NegativeDigCode.of(.{ .level_side = 256, .requests = 64 }),
    NegativeDigCode.of(.{ .level_side = 256, .requests = 128 }),
    NegativeDigCode.of(.{ .level_side = 256, .requests = 256 }),
    NegativeDigCode.of(.{ .level_side = 1024, .requests = 64 }),
    NegativeDigCode.of(.{ .level_side = 2048, .requests = 64 }),
};

const negative_burst_item_counts = [_]usize{
    BurstCode.of(.{ .variant = .open_goals, .requests = 1024 }),
    BurstCode.of(.{ .variant = .open_goals, .requests = 4096 }),
    BurstCode.of(.{ .variant = .open_goals, .requests = 12288 }),
    BurstCode.of(.{ .variant = .blocked_crowd, .requests = 1024 }),
    BurstCode.of(.{ .variant = .blocked_crowd, .requests = 4096 }),
    BurstCode.of(.{ .variant = .blocked_crowd, .requests = 12288 }),
};

fn writeUnavailableWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("unavailable={}", .{stats.output_count});
}

fn writeBurstWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("unavailable={} projections={}", .{ stats.output_count, stats.candidate_pairs });
}

// Goal-pocket fixture: a walkable pocket of `pocket_side`² cells at the level origin, closed
// by the level border and a blocking column x = `pocket_side` and row y = `pocket_side`.
// Goals are pocket cells in row-major order; requesters start outside it on rows from
// `pocket_requester_row`, `pocket_requester_margin` cells clear of the level's sides.
const pocket_side: u16 = 80;
const pocket_requester_row: u16 = 96;
const pocket_requester_margin: u16 = 8;

const negative_steady_side: u16 = 256;

fn pocketGoalCell(index: usize) CellCoord {
    std.debug.assert(index < @as(usize, pocket_side) * pocket_side);
    return .{ .x = @intCast(index % pocket_side), .y = @intCast(index / pocket_side) };
}

fn pocketRequesterCell(side: u16, index: usize) CellCoord {
    const columns = side - 2 * pocket_requester_margin;
    // Range checked by `checkPocketLayout`: every requester row lies inside the level.
    return .{ .x = @intCast(pocket_requester_margin + index % columns), .y = @intCast(pocket_requester_row + index / columns) };
}

fn pocketWallCells() [2 * pocket_side + 1]CellCoord {
    var walls: [2 * pocket_side + 1]CellCoord = undefined;
    for (0..pocket_side + 1) |y| walls[y] = .{ .x = pocket_side, .y = @intCast(y) };
    for (0..pocket_side) |x| walls[pocket_side + 1 + x] = .{ .x = @intCast(x), .y = pocket_side };
    return walls;
}

// Fails unless the first `goal_count` goals and `requester_count` starts are distinct cells,
// every goal inside the pocket and every start outside it, none a wall or the far dig cell.
fn checkPocketLayout(allocator: std.mem.Allocator, side: u16, goal_count: usize, requester_count: usize) !void {
    if (goal_count > @as(usize, pocket_side) * pocket_side) return error.PocketGoalCellsTooFew;
    const columns = side -| 2 * pocket_requester_margin;
    if (columns == 0 or pocket_requester_row + @divCeil(requester_count, columns) > side -| pocket_dig_inset) return error.PocketRequesterRowsTooFew;
    var taken = try std.DynamicBitSetUnmanaged.initEmpty(allocator, @as(usize, side) * side);
    defer taken.deinit(allocator);
    const walls = pocketWallCells();
    for (walls) |cell| taken.set(@as(usize, cell.y) * side + cell.x);
    const dig = pocketDigCell(side);
    taken.set(@as(usize, dig.y) * side + dig.x);
    for (0..goal_count) |index| {
        const cell = pocketGoalCell(index);
        const slot = @as(usize, cell.y) * side + cell.x;
        if (taken.isSet(slot)) return error.PocketLayoutOverlap;
        taken.set(slot);
    }
    for (0..requester_count) |index| {
        const cell = pocketRequesterCell(side, index);
        if (cell.x < pocket_side and cell.y < pocket_side) return error.PocketRequesterInside;
        const slot = @as(usize, cell.y) * side + cell.x;
        if (taken.isSet(slot)) return error.PocketLayoutOverlap;
        taken.set(slot);
    }
}

// The pocket on a walkable `side`² level with one requester per request; goals are set per
// step. Nav is world-backed, so the far dig reaches it through `changeAndReact`.
fn initPocketFixture(allocator: std.mem.Allocator, io: std.Io, side: u16, requester_count: usize, capacity: PathfindingCapacity, thread_system: *ThreadSystem) !ReactFixture {
    var open = try buildOpenWorld(allocator, io, side, 1);
    errdefer open.world.deinit();
    const walls = pocketWallCells();
    try writeLevelZeroCells(&open, &walls, open.blocking);
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const requests = try allocator.alloc(PathRequest, requester_count);
    errdefer allocator.free(requests);
    for (requests, 0..) |*request, index| {
        request.* = .{
            .entity = try data.createEntity(),
            .start = open.cellCenter(pocketRequesterCell(side, index)),
            .goal = open.cellCenter(pocketGoalCell(index)),
        };
    }
    return assembleReactFixture(allocator, &open, &data, requests, capacity, thread_system);
}

fn pocketSizeConfig(side: u16, participant_count: usize, requester_count: usize) nav_size.NavSizeConfig {
    return .{
        .side = side,
        .levels = 1,
        .participant_count = participant_count,
        .agent_budget = requester_count,
        .group_fields = 1,
        // No path is published, so no long block or registry run is taken.
        .long_results = 0,
        .runs_per_result = 0,
        // At most one toggled cell per step.
        .batch = toggle_batch,
    };
}

const PocketStep = struct {
    elapsed_ns: u64,
    stats: PathfindingStats,
};

// Times one update of every request; intake must answer every one unavailable from reach,
// with no solve and nothing cached.
fn runPocketUpdate(io: std.Io, case: suite.BenchmarkCase, fixture: *ReactFixture, thread_system: *ThreadSystem) !PocketStep {
    try fixtures.writeRequests(&fixture.stream, fixture.requests);
    const count = fixture.requests.len;
    const start_ns = suite.nowNs(io);
    const stats = try runColdOnce(&fixture.system, &fixture.stream, thread_system, case, count, count, count);
    const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
    if (stats.perf.available_results != 0) return error.PocketGoalReached;
    if (stats.perf.dropped_requests != 0 or stats.perf.start_invalid_dropped != 0) return error.PocketRequestDropped;
    if (stats.perf.solved_requests != 0 or stats.accepted_requests != 0 or stats.perf.cache_hits != 0) return error.PocketSearched;
    if (stats.perf.unavailable_results != count) return error.PocketNotAnsweredAtIntake;
    return .{ .elapsed_ns = elapsed_ns, .stats = stats };
}

fn runNegativeSteadyCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const side = negative_steady_side;
    try checkPocketLayout(allocator, side, item_count, item_count);
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const participant_count = fixtures.participantCount(thread_ptr);
    const size_config = pocketSizeConfig(side, participant_count, item_count);
    try nav_size.checkNavSize(negative_steady_group.name, item_count, case, size_config);

    var fixture = try initPocketFixture(allocator, io, side, item_count, nav_size.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    try nav_size.checkNavBytes(negative_steady_group.name, item_count, size_config, &fixture.system);
    setPathStageTuners(&fixture.system, case);

    var warm = suite.Warmup.custom(case, coldWarmup(options), coldSettleLimit(options));
    while (warm.next(fixture.system.tuners.intake.phase == .settled)) _ = try runPocketUpdate(io, case, &fixture, thread_ptr);
    const settled_before_measurement = if (case.adaptive) (fixture.system.tuners.intake.phase == .settled) else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    var stage_report = StageReport{};
    for (0..coldIterations(options)) |_| {
        const step = try runPocketUpdate(io, case, &fixture, thread_ptr);
        last_stats = step.stats;
        accumulator.record(step.elapsed_ns, last_stats.intake_batch);
        stage_report.add(step.elapsed_ns, last_stats);
    }

    try nav_size.checkNavBytes(negative_steady_group.name, item_count, size_config, &fixture.system);
    var stats = accumulator.finish();
    stage_report.write(&stats.details);
    stats.output_count = last_stats.perf.unavailable_results;
    if (case.adaptive) stats.work_tuning = suite.workTuningSummary(suite.tunerReport(&fixture.system.tuners.intake), settled_before_measurement);
    return stats;
}

// The timed negative-dig steps' reaction/update split and the reaction's remask shape,
// printed under --details. The reaction's eviction stages and main-thread share print through
// `EvictReport`.
const NegativeDigReport = struct {
    samples: usize = 0,
    react_ns: u128 = 0,
    update_ns: u128 = 0,
    remask: suite.StageShapes(1) = .{},

    fn add(self: *NegativeDigReport, reaction: Reaction, step: PocketStep) void {
        self.samples += 1;
        self.react_ns += reaction.elapsed_ns;
        self.update_ns += step.elapsed_ns;
        self.remask.add(.{reaction.stats.remask_batch});
    }

    fn write(self: NegativeDigReport, details: *suite.DetailLines) void {
        if (self.samples == 0) return;
        const samples: u128 = self.samples * std.time.ns_per_us;
        var remask_buffer: [48]u8 = undefined;
        details.print("react={}us update={}us remask={s}\n", .{
            @as(u64, @intCast(self.react_ns / samples)),
            @as(u64, @intCast(self.update_ns / samples)),
            self.remask.label(0, &remask_buffer),
        });
    }
};

// The negative-dig step: toggles the far cell's blocking and runs the nav reaction (its
// time measured inside `changeAndReact`), then updates the same requests, every one
// answered at intake.
const NegativeDig = struct {
    cell: CellCoord,
    blocked: bool = false,

    fn step(self: *NegativeDig, io: std.Io, case: suite.BenchmarkCase, fixture: *ReactFixture, thread_system: *ThreadSystem) !struct { reaction: Reaction, update: PocketStep } {
        self.blocked = !self.blocked;
        const tile = if (self.blocked) fixture.open.blocking else fixture.open.walkable;
        const reaction = try fixture.changeAndReact(io, &.{self.cell}, tile, thread_system);
        const update = try runPocketUpdate(io, case, fixture, thread_system);
        return .{ .reaction = reaction, .update = update };
    }
};

fn runNegativeDigCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const code = try NegativeDigCode.decode(item_count);
    const side = code.level_side;
    const requester_count: usize = code.requests;
    if (requester_count == 0) return error.NegativeDigNoRequests;
    try checkPocketLayout(allocator, side, requester_count, requester_count);
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const participant_count = fixtures.participantCount(thread_ptr);
    const size_config = pocketSizeConfig(side, participant_count, requester_count);
    try nav_size.checkNavSize(negative_dig_group.name, item_count, case, size_config);

    var fixture = try initPocketFixture(allocator, io, side, requester_count, nav_size.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    try nav_size.checkNavBytes(negative_dig_group.name, item_count, size_config, &fixture.system);
    try fixture.changed.ensureTotalCapacity(allocator, 1);
    setPathStageTuners(&fixture.system, case);
    fixtures.setNavTuners(&fixture.system, case);

    // Untimed first update: every request answered at intake, as every later one.
    var report = NegativeDigReport{};
    _ = try runPocketUpdate(io, case, &fixture, thread_ptr);

    var dig = NegativeDig{ .cell = pocketDigCell(side) };
    var warm = suite.Warmup.custom(case, coldWarmup(options), coldSettleLimit(options));
    while (warm.next(fixture.system.tuners.intake.phase == .settled)) _ = try dig.step(io, case, &fixture, thread_ptr);
    const settled_before_measurement = if (case.adaptive) (fixture.system.tuners.intake.phase == .settled) else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    // The update's stages and the reaction's eviction stages, each over its own span.
    var stage_report = StageReport{};
    var reaction_report = EvictReport{};
    for (0..coldIterations(options)) |_| {
        const timed = try dig.step(io, case, &fixture, thread_ptr);
        accumulator.record(timed.reaction.elapsed_ns + timed.update.elapsed_ns, timed.update.stats.intake_batch);
        stage_report.add(timed.update.elapsed_ns, timed.update.stats);
        reaction_report.add(timed.reaction);
        report.add(timed.reaction, timed.update);
    }

    try nav_size.checkNavBytes(negative_dig_group.name, item_count, size_config, &fixture.system);
    var stats = accumulator.finish();
    stage_report.write(&stats.details);
    reaction_report.write(&stats.details);
    report.write(&stats.details);
    stats.output_count = requester_count;
    if (stats.mean_ns != 0) stats.items_per_second = suite.itemsPerSecond(requester_count, stats.mean_ns);
    if (case.adaptive) stats.work_tuning = suite.workTuningSummary(suite.tunerReport(&fixture.system.tuners.intake), settled_before_measurement);
    return stats;
}

// Burst fixture: `burst_pockets` sealed `burst_pocket_side`² pockets along the top edge of a
// walkable `burst_side`² level, pocket `k` from column `k * burst_pocket_pitch + 1`, each
// closed by the level border, a blocking column on either side, and a blocking row below
// it. Requesters start outside on rows from `burst_requester_row`, `pocket_requester_margin`
// cells clear of the level's sides. The blocked-crowd variant adds a `burst_block_side`²
// blocking block at each pocket's center.
const burst_side: u16 = 256;
const burst_pockets: u16 = 4;
const burst_pocket_side: u16 = 56;
const burst_pocket_pitch: u16 = 64;
const burst_requester_row: u16 = 72;
const burst_requester_columns: usize = burst_side - 2 * pocket_requester_margin;
// Per pocket: two side columns of `burst_pocket_side + 1` cells and the row between them.
const burst_wall_cells_per_pocket: usize = 3 * burst_pocket_side + 2;
const burst_block_side: u16 = 3;

comptime {
    // Requesters start below every pocket's bottom wall, and the last pocket's right wall
    // lies inside the level.
    std.debug.assert(burst_requester_row > burst_pocket_side);
    std.debug.assert((burst_pockets - 1) * burst_pocket_pitch + burst_pocket_side + 1 < burst_side);
    // A blocked center's block leaves open pocket cells next to it.
    std.debug.assert(burst_block_side < burst_pocket_side);
}

const BurstVariant = enum(u8) {
    // Each request's own open goal cell.
    open_goals,
    // Every request of a pocket at its blocked center.
    blocked_crowd,
};

const BurstConfig = struct {
    variant: BurstVariant,
    requests: usize,

    fn decode(item_count: usize) !BurstConfig {
        const code = try BurstCode.decode(item_count);
        return .{ .variant = code.variant, .requests = code.requests };
    }
};

fn burstGoalCell(variant: BurstVariant, index: usize) CellCoord {
    const pocket: u16 = @intCast(index % burst_pockets);
    if (variant == .blocked_crowd) return burstPocketCenter(pocket);
    const cell = index / burst_pockets;
    // In range: the cell lies inside its pocket.
    std.debug.assert(cell < @as(usize, burst_pocket_side) * burst_pocket_side);
    return .{
        .x = pocket * burst_pocket_pitch + 1 + @as(u16, @intCast(cell % burst_pocket_side)),
        .y = @intCast(cell / burst_pocket_side),
    };
}

fn burstPocketCenter(pocket: u16) CellCoord {
    return .{ .x = pocket * burst_pocket_pitch + 1 + burst_pocket_side / 2, .y = burst_pocket_side / 2 };
}

fn burstRequesterCell(index: usize) CellCoord {
    // Range checked by `checkBurstLayout`: every requester row lies inside the level.
    return .{ .x = @intCast(pocket_requester_margin + index % burst_requester_columns), .y = @intCast(burst_requester_row + index / burst_requester_columns) };
}

fn burstWallCells() [burst_pockets * burst_wall_cells_per_pocket]CellCoord {
    var walls: [burst_pockets * burst_wall_cells_per_pocket]CellCoord = undefined;
    var len: usize = 0;
    for (0..burst_pockets) |pocket_index| {
        const left: u16 = @as(u16, @intCast(pocket_index)) * burst_pocket_pitch;
        const right = left + burst_pocket_side + 1;
        for (0..burst_pocket_side + 1) |y| {
            walls[len] = .{ .x = left, .y = @intCast(y) };
            walls[len + 1] = .{ .x = right, .y = @intCast(y) };
            len += 2;
        }
        for (0..burst_pocket_side) |x| {
            walls[len] = .{ .x = left + 1 + @as(u16, @intCast(x)), .y = burst_pocket_side };
            len += 1;
        }
    }
    std.debug.assert(len == walls.len);
    return walls;
}

// The blocked-crowd variant's center blocks, one per pocket.
fn burstBlockCells() [burst_pockets * burst_block_side * burst_block_side]CellCoord {
    var cells: [burst_pockets * burst_block_side * burst_block_side]CellCoord = undefined;
    var len: usize = 0;
    for (0..burst_pockets) |pocket_index| {
        const center = burstPocketCenter(@intCast(pocket_index));
        for (0..burst_block_side) |dy| {
            for (0..burst_block_side) |dx| {
                cells[len] = .{ .x = center.x - burst_block_side / 2 + @as(u16, @intCast(dx)), .y = center.y - burst_block_side / 2 + @as(u16, @intCast(dy)) };
                len += 1;
            }
        }
    }
    std.debug.assert(len == cells.len);
    return cells;
}

// Fails unless every open-goal request has its own pocket cell and every requester row lies
// inside the level.
fn checkBurstLayout(config: BurstConfig) !void {
    if (config.requests == 0) return error.NegativeBurstNoRequests;
    if (config.variant == .open_goals and @divCeil(config.requests, burst_pockets) > @as(usize, burst_pocket_side) * burst_pocket_side) return error.NegativeBurstGoalCellsTooFew;
    const rows = @divCeil(config.requests, burst_requester_columns);
    if (burst_requester_row + rows > burst_side) return error.NegativeBurstRequesterRowsTooFew;
}

fn initBurstFixture(allocator: std.mem.Allocator, io: std.Io, config: BurstConfig, capacity: PathfindingCapacity, thread_system: *ThreadSystem) !ReactFixture {
    var open = try buildOpenWorld(allocator, io, burst_side, 1);
    errdefer open.world.deinit();
    const walls = burstWallCells();
    try writeLevelZeroCells(&open, &walls, open.blocking);
    if (config.variant == .blocked_crowd) {
        const blocks = burstBlockCells();
        try writeLevelZeroCells(&open, &blocks, open.blocking);
    }
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const requests = try allocator.alloc(PathRequest, config.requests);
    errdefer allocator.free(requests);
    for (requests, 0..) |*request, index| {
        request.* = .{
            .entity = try data.createEntity(),
            .start = open.cellCenter(burstRequesterCell(index)),
            .goal = open.cellCenter(burstGoalCell(config.variant, index)),
        };
    }
    return assembleReactFixture(allocator, &open, &data, requests, capacity, thread_system);
}

fn burstSizeConfig(participant_count: usize, requester_count: usize) nav_size.NavSizeConfig {
    return .{
        .side = burst_side,
        .levels = 1,
        .participant_count = participant_count,
        .agent_budget = requester_count,
        .group_fields = 1,
        // No path is published, so no long block or registry run is taken.
        .long_results = 0,
        .runs_per_result = 0,
        // Requests only: no marks batch.
        .batch = nav_size.NavBatch.none,
    };
}

// Requests whose status reads unavailable: one status query per request.
fn unavailableCount(fixture: *const ReactFixture) usize {
    var unavailable: usize = 0;
    for (fixture.requests) |request| {
        const view = fixture.system.statusForWorld(request.start_level, request.start, request.goal_level, request.goal, request.agent_class, null);
        if (view.status == .unavailable) unavailable += 1;
    }
    return unavailable;
}

// The burst's goal resolves under --details: the scan and project stage shapes and their
// worker-side time per burst.
const ResolveReport = struct {
    samples: usize = 0,
    shapes: suite.StageShapes(2) = .{},
    off_main_ns: u128 = 0,

    fn add(self: *ResolveReport, resolve: GoalResolveStats) void {
        self.samples += 1;
        const scan = resolve.perf.scan_batch;
        const project = resolve.perf.project_batch;
        self.shapes.add(.{ scan, project });
        self.off_main_ns += offMainNs(scan) + offMainNs(project);
    }

    fn write(self: ResolveReport, details: *suite.DetailLines) void {
        if (self.samples == 0) return;
        var scan_buffer: [48]u8 = undefined;
        var project_buffer: [48]u8 = undefined;
        details.print("goal_scan={s} goal_project={s} goal_off_main={}us\n", .{
            self.shapes.label(0, &scan_buffer),
            self.shapes.label(1, &project_buffer),
            @as(u64, @intCast(self.off_main_ns / self.samples / std.time.ns_per_us)),
        });
    }
};

const BurstOutcome = struct {
    // The goal resolve and the step, plus the status sweep in the blocked-crowd variant.
    elapsed_ns: u64,
    unavailable: usize,
    // Projections the goal resolve computed.
    projections: usize,
    stats: PathfindingStats,
    resolve: GoalResolveStats,
};

// One burst on cleared result state: the goal resolve over every request (the pipeline
// resolves every intent each step) and the step that submits them. Intake answers every
// request unavailable from reach on that step, with no search and nothing pending, and every
// status reads unavailable after it.
fn runBurst(io: std.Io, case: suite.BenchmarkCase, variant: BurstVariant, fixture: *ReactFixture, thread_system: *ThreadSystem) !BurstOutcome {
    const count = fixture.requests.len;
    fixture.system.clearRuntimeState();
    try fixtures.writeRequests(&fixture.stream, fixture.requests);
    const start_ns = suite.nowNs(io);
    const resolve = try runResolveGoals(&fixture.system, fixture.requests, thread_system, case);
    const stats = try runColdOnce(&fixture.system, &fixture.stream, thread_system, case, count, count, count);
    var elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
    if (stats.perf.available_results != 0) return error.NegativeBurstGoalReached;
    if (stats.perf.dropped_requests != 0 or stats.perf.start_invalid_dropped != 0) return error.NegativeBurstRequestDropped;
    if (stats.perf.unavailable_results != count or stats.pending_requests != 0) return error.NegativeBurstUnanswered;
    if (stats.perf.solved_requests != 0) return error.NegativeBurstSearched;
    const status_start_ns = suite.nowNs(io);
    const all_unavailable = unavailableCount(fixture) == count;
    if (variant == .blocked_crowd) elapsed_ns += suite.elapsedNs(status_start_ns, suite.nowNs(io));
    if (!all_unavailable) return error.NegativeBurstStatusNotUnavailable;
    // One projection per distinct blocked goal, shared: four for the blocked crowd.
    const expected_projections: usize = if (variant == .blocked_crowd) burst_pockets else 0;
    if (resolve.distinct != expected_projections or stats.perf.goal_fallbacks != 0) return error.NegativeBurstProjectionsNotShared;
    return .{ .elapsed_ns = elapsed_ns, .unavailable = stats.perf.unavailable_results, .projections = resolve.distinct, .stats = stats, .resolve = resolve };
}

fn runNegativeBurstCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const config = try BurstConfig.decode(item_count);
    try checkBurstLayout(config);
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const participant_count = fixtures.participantCount(thread_ptr);
    const size_config = burstSizeConfig(participant_count, config.requests);
    try nav_size.checkNavSize(negative_burst_group.name, item_count, case, size_config);

    var fixture = try initBurstFixture(allocator, io, config, nav_size.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    try nav_size.checkNavBytes(negative_burst_group.name, item_count, size_config, &fixture.system);
    setPathStageTuners(&fixture.system, case);

    // At least one untimed burst: the first grows the capacity from the reserve floor.
    var warm = suite.Warmup.custom(case, @max(1, coldWarmup(options)), coldSettleLimit(options));
    while (warm.next(fixture.system.tuners.intake.phase == .settled)) _ = try runBurst(io, case, config.variant, &fixture, thread_ptr);
    const settled_before_measurement = if (case.adaptive) (fixture.system.tuners.intake.phase == .settled) else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var stage_report = StageReport{};
    var resolve_report = ResolveReport{};
    var last: ?BurstOutcome = null;
    for (0..coldIterations(options)) |_| {
        const burst = try runBurst(io, case, config.variant, &fixture, thread_ptr);
        resolve_report.add(burst.resolve);
        // The update's stages and main share; the resolve's worker time prints on its own.
        stage_report.add(burst.elapsed_ns -| (offMainNs(burst.resolve.perf.scan_batch) + offMainNs(burst.resolve.perf.project_batch)), burst.stats);
        accumulator.record(burst.elapsed_ns, burst.stats.intake_batch);
        last = burst;
    }

    try nav_size.checkNavBytes(negative_burst_group.name, item_count, size_config, &fixture.system);
    var stats = accumulator.finish();
    stage_report.write(&stats.details);
    resolve_report.write(&stats.details);
    if (last) |burst| {
        stats.output_count = burst.unavailable;
        stats.candidate_pairs = burst.projections;
    }
    stats.items_per_second = suite.itemsPerSecond(config.requests, stats.mean_ns);
    if (case.adaptive) stats.work_tuning = suite.workTuningSummary(suite.tunerReport(&fixture.system.tuners.intake), settled_before_measurement);
    return stats;
}
