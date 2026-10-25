// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Pathfinding route bench groups: level size, cross-level depth, teleport and shaft
//! routes, long paths, and link folding.

const std = @import("std");
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const inlineBatch = @import("../../app/thread_system.zig").inlineBatch;
const DataSystem = @import("../../game/data_system.zig").DataSystem;
const PathRequest = @import("../../game/simulation.zig").PathRequest;
const RangeOutputStream = @import("../../game/simulation.zig").RangeOutputStream;
const PathfindingCapacity = @import("../../game/systems/pathfinding.zig").PathfindingCapacity;
const PathfindingStats = @import("../../game/systems/pathfinding.zig").PathfindingStats;
const PathfindingConfig = @import("../../game/systems/pathfinding.zig").PathfindingConfig;
const PathfindingSystem = @import("../../game/systems/pathfinding.zig").PathfindingSystem;
const pathfinding_test_support = @import("../../game/systems/pathfinding/test_support.zig");
const pathfinding_range_alignment_items = @import("../../game/systems/pathfinding.zig").pathfinding_range_alignment_items;
const default_tier1_abstract_node_cap = @import("../../game/systems/pathfinding/types.zig").default_tier1_abstract_node_cap;
const refLevel = @import("../../game/systems/pathfinding/types.zig").refLevel;
const refLocal = @import("../../game/systems/pathfinding/types.zig").refLocal;
const WorldSystem = @import("../../game/world/system.zig").WorldSystem;
const CellCoord = @import("../../game/world/system.zig").CellCoord;
const default_chunk_size_tiles = @import("../../game/world/system.zig").default_chunk_size_tiles;
const isGoalPortal = @import("../../game/systems/pathfinding/solve.zig").isGoalPortal;
const fixtures = @import("../fixtures.zig");
const nav_size = @import("../nav_size.zig");
const suite = @import("../suite.zig");
const coldWarmup = @import("nav_fixtures.zig").coldWarmup;
const coldIterations = @import("nav_fixtures.zig").coldIterations;
const runColdOnce = @import("nav_fixtures.zig").runColdOnce;
const coldStepConfig = @import("nav_fixtures.zig").coldStepConfig;
const expireCachedResults = @import("nav_fixtures.zig").expireCachedResults;
const drainPending = @import("nav_fixtures.zig").drainPending;
const StageReport = @import("nav_fixtures.zig").StageReport;
const stepTunerSettle = @import("nav_fixtures.zig").stepTunerSettle;
const OpenWorld = @import("nav_fixtures.zig").OpenWorld;
const buildOpenWorld = @import("nav_fixtures.zig").buildOpenWorld;
const writeLevelZeroCells = @import("nav_fixtures.zig").writeLevelZeroCells;
const RouteFixture = @import("nav_fixtures.zig").RouteFixture;
const initRouteFixture = @import("nav_fixtures.zig").initRouteFixture;
const PlanarRoute = @import("nav_fixtures.zig").PlanarRoute;
const ReactFixture = @import("nav_fixtures.zig").ReactFixture;
const Reaction = @import("nav_fixtures.zig").Reaction;
const ReactionStages = @import("nav_fixtures.zig").ReactionStages;
const assembleReactFixture = @import("nav_fixtures.zig").assembleReactFixture;
const toggleSizeConfig = @import("nav_fixtures.zig").toggleSizeConfig;
const toggle_batch_keys = @import("nav_fixtures.zig").toggle_batch_keys;

// Nav scaling groups over a world-backed nav. A listed config whose nav storage exceeds the
// bench's nav-size limit fails with its figure (`nav_size.checkNavSize`), and every config checks
// each part of the nav's bytes against its charge (`nav_size.checkNavBytes`). The route groups
// time one cold step of 64 distinct-goal requests; `candidates` is the abstract nodes the last
// solve used and `outputs` the routes that solved. The level-size and depth groups fail
// unless every route solves that step; the teleport and shaft groups count a route whose
// search exhausted its budget as unsolved (`routes solved= unsolved=` under `--details`).
// Every group passes only when all routes solve within the step at every config.
//   - `pathfinding-level-size`: one walkable level of side 256, 1024, or 2048 with a
//     full-height wall and a two-cell central gap; every request crosses the gap, so
//     the routes are the same at every size. Passes when flat in side.
//   - `pathfinding-cross-level-depth`: a 256² world of 8, 32, or 128 walkable levels,
//     consecutive levels joined by one ramp; requests go from level 0 to level 4, so
//     the routes are the same at every depth. Passes when flat in depth.
//   - `pathfinding-cross-level-teleport`: the depth fixture plus one bidirectional
//     teleport between opposite corners of level 0 and the deepest level, far from the
//     routes, whose span far exceeds its traversal cost. Passes when flat in depth. A
//     teleport-count config instead adds that many such teleports from level 0 to the deepest
//     level in one layout. Layout 0 spreads them evenly over level-0 cells within 16 of the
//     border, each to its point mirror. Layout 1 spreads them evenly over level-0 rows
//     [center - 112, center - 97) across the side, each to its point mirror. Layout 2 places
//     random pads on a fixed seed: level-0 cells at least 24 cells from the routes' starts
//     and goals, each to an independent random cell at least 64 cells away. Layout 0 runs
//     64, 256, or 1,024 teleports at 256² and 8 levels and passes when flat in teleport count.
//     Layout 1 runs one teleport per 16 strip cells on sides 256, 1024, and 2048 at 8 levels
//     and passes when flat in side. Layout 2 runs 16 teleports at 256² and 8 levels and
//     passes when every route solves.
//   - `pathfinding-cross-level-shaft`: a 256² world of 8, 32, or 128 walkable levels; a ramp
//     shaft beside the starts joins levels 1 to the deepest, and level 0, which no ramp
//     reaches, holds a one-way teleport from the shaft's planar cell to beside the goals.
//     Requests go from level 1 to level 5, 48 cells east, so the routes are the same at
//     every depth and the teleport is never usable. Passes when flat in depth.
pub const level_size_group = suite.BenchmarkGroup{
    .name = "pathfinding-level-size",
    .item_label = LevelCode.label,
    .describe_item = LevelCode.describe,
    .item_counts = &level_size_item_counts,
    .runCase = runLevelSizeCase,
    .write_workload = writeRouteWorkload,
};

pub const cross_level_depth_group = suite.BenchmarkGroup{
    .name = "pathfinding-cross-level-depth",
    .item_label = CrossLevelCode.label,
    .describe_item = CrossLevelCode.describe,
    .item_counts = &cross_level_item_counts,
    .runCase = runCrossLevelDepthCase,
    .write_workload = writeRouteWorkload,
};

pub const cross_level_teleport_group = suite.BenchmarkGroup{
    .name = "pathfinding-cross-level-teleport",
    .item_label = CrossLevelCode.label,
    .describe_item = CrossLevelCode.describe,
    .item_counts = &teleport_item_counts,
    .runCase = runCrossLevelTeleportCase,
    .write_workload = writeRouteWorkload,
};

pub const cross_level_shaft_group = suite.BenchmarkGroup{
    .name = "pathfinding-cross-level-shaft",
    .item_label = LevelCode.label,
    .describe_item = LevelCode.describe,
    .item_counts = &cross_level_item_counts,
    .runCase = runCrossLevelShaftCase,
    .write_workload = writeRouteWorkload,
};

// One far goal per route length D on the flat chunk-portal search (`LongPathCode`). Layouts:
//   - 0, serpentine: a 2048² level with a wall every 128 rows, each open by an 8-cell gap at
//     alternating ends; start and goal sit on the center column, the parameter walls apart.
//   - 1, open diagonal: an open 2048² level; start (8, 8), goal the parameter cells further
//     along the diagonal.
//   - 2, descent: 128 levels of 256² joined by one ramp per pair at alternating corners; the
//     goal is the parameter levels below the start, so the route crosses every level it
//     passes corner to corner.
//   - 3, depth: layout 2's 4-level descent on stacks of the parameter's levels.
//   - 4, wide descent: layout 2's ramps on 3 levels of the parameter's side; the goal is 2
//     levels below the start.
//   - 5, cave: layout 1's route through seeded blob caves (blocking disks of radius 3 to 24
//     over about 40% of the level, from one fixed seed), its ends moved to the nearest cells
//     of the main cave.
//   - 6, deep wide descent: layout 2's ramps on the parameter's levels of 1024²; the goal is
//     on the deepest level, so the route crosses every level corner to corner.
// Variant 0 runs the library caps. Variant 1 raises only the escalated attempt's abstract node
// cap past every node a layout holds, so that search runs to its goal and its claims show the
// uncapped order; a probe search that still saturates fails the case. Variant 2 checks the
// fold of 32 requests for one goal (the first from the layout's start, the rest scattered)
// into one pending entry and one solve per attempt; intake keeps the first start, so it
// measures no sharing cost. Variant 3 walks one agent from the serpentine's, the open
// diagonal's, or the cave's start toward its goal through partial hops, a sample being the
// whole walk: each step reads its status, requests on `.missing` or a partial's refresh,
// advances up to `walk_cells_per_step` waypoints (holding when pending or at a partial's end),
// then runs one timed step; the sample's time is the steps' total. A walk holding
// `walk_stall_steps` steps in a row, or past 4 x the route's cells + 64 steps, fails the case.
// Variant 4 chains hops for the cross-level layouts, which a walk cannot cross: a sample
// requests from the start, runs the first attempt's step and the escalated one's when it
// promoted, restarts at a partial's end on its level, and repeats until a hop arrives; the
// sample's time is the steps' total, and a hop that drops or a chain past the route's cells +
// 64 hops fails the case.
// A caps, probe, or crowd sample is one request cycle with nothing pending and every cached
// result expired (untimed, through the production steps and the result TTL): the first
// attempt's step, the escalated attempt's step when the first exhausted, then every agent's
// status. Claims must repeat exactly across samples. Serial only: each step solves one
// request. Each variant runs 3 route lengths per layout.
// Passes when: caps and crowd attempts are flat in route length once the route passes the
// escalated attempt's caps (each attempt's work is bounded by them), the crowd within spread
// of caps at the same route; probe claims grow at most linearly in the nodes the layout's
// route needs; walks and hop chains grow at most linearly in route length (each hop bounded).
// `--details` prints, per attempt, the abstract nodes claimed, the chosen corridor's nodes,
// the stitched cells and segment searches when the stitch ran, the crossing boxes the
// heuristic settled and whether its budget froze, the outcome, and the step time, then the
// blocked cells on level 0 and the agents' statuses. `candidates` is the last attempt's claims
// and `outputs` the agents a path serves. A walk prints its steps, held steps, solves (its
// requests), partial and full results, escalations, abstract claims over every solve, and total
// solve time; its `candidates` are its solves and `outputs` its published results. A hop chain
// prints its last hop's start, its hops (published ones toward a least-estimate node as
// `least_hops`), solves, escalations, claims, and total solve time; its `candidates` are its
// solves and `outputs` its hops. An attempt's `abstract_partial` outcome is a saturated tier-1
// search published toward its least-estimate node.
pub const long_path_group = suite.BenchmarkGroup{
    .name = "pathfinding-long-path",
    .item_label = LongPathCode.label,
    .describe_item = LongPathCode.describe,
    .item_counts = &long_path_item_counts,
    .runCase = runLongPathCase,
    .write_workload = writeLongPathWorkload,
    .cases = &suite.serial_cases,
};

// A 512² world of 8 walkable levels holding random pads: bidirectional teleports from level 0
// to the deepest level placed as the teleport group's layout 2 (`LinkFoldCode`). One timed
// sample runs the post-commit nav reaction that applies a batch of 64 more pads, added to the
// world untimed. Links are append-only, so every sample (warmup included) leaves its batch in
// the world. A 64-pad placement is a one-off jump amid ordinary nav work, so the case runs the
// spike shape: the nav stage tuners settle on in-band toggles (one cell at level 1's centre,
// which holds no pad, blocked and reacted to, then reopened and reacted to on a revert stage
// tuner set), then at least two warmup batches grow the per-range scratch (a jump's shape,
// held across its count band, is judged by its first two records), and each measured sample runs one
// in-band toggle untimed before the timed fold (headline tuner: the patch). Every case runs
// at least two toggles and then one per batch, so the world is the same in every case.
//   - Axis 0 (uniform): 1,024, 8,192, or 32,768 background pads; every batch is uniform
//     random pads too, so endpoints per touched chunk rise with pads held.
//   - Axis 1 (probe): background pads keep off a probe region of chunk pairs (a level-0 chunk
//     and its point mirror on the deepest level), one set of 8 pairs per sample, each pair
//     joined by `preload` pads first; each batch lands 8 pads in each pair of its own set, so
//     endpoints per touched chunk stay at preload + 8 at any background. Preload 16 over
//     1,024, 8,192, or 32,768 background pads, then preload 4 and 64 over 8,192.
// `outputs` is the pads the world holds after the run and `candidates` the chunks the last
// reaction patched; items/s is pads applied per second. Passes when the reaction's `commit`
// section (the link fold) is flat per pad in pads held on both axes, the whole reaction is flat
// in background pads at a fixed preload, and it grows at most linearly in endpoints per
// touched chunk at a fixed background, and when every timed patch batch of the tuned case is
// a jump that reuses the judgment its count band holds (re-predicts none), with uniform
// batches at varying chunk counts (some off the entry's count). Every batch is 64 pads, so its
// patch count stays inside the entry's band; a count outside it would re-predict and fail
// the run as a fixture that left the band. `--details` prints the reaction's plan, patch, and
// connectivity gather shapes, the per-pad and per-pad `commit` cost, the mean endpoints per
// touched chunk, the mean pads held over the timed samples, the main-thread share, and its
// split by section, and for the tuned case the patch jumps' count range, those at a count
// other than their judgment entry's, and those re-predicted.
pub const link_fold_group = suite.BenchmarkGroup{
    .name = "pathfinding-link-fold",
    .item_label = LinkFoldCode.label,
    .describe_item = LinkFoldCode.describe,
    .item_counts = &link_fold_item_counts,
    .runCase = runLinkFoldCase,
    .write_workload = writeLinkFoldWorkload,
};

const LevelCode = suite.ItemCode(struct { level_side: u16, levels: u16 }, &.{3});
const CrossLevelCode = suite.ItemCode(struct { layout: TeleportLayout, teleports: usize, level_side: u16, levels: u16 }, &.{ 5, 4, 3 });
const LongPathCode = suite.ItemCode(struct { variant: LongPathVariant, layout: LongPathLayout, parameter: u16 }, &.{ 1, 6 });
const LinkFoldCode = suite.ItemCode(struct { axis: LinkFoldAxis, probe_preload: usize, background_pads: usize }, &.{ 3, 6 });

const level_size_item_counts = [_]usize{
    LevelCode.of(.{ .level_side = 256, .levels = 1 }),
    LevelCode.of(.{ .level_side = 1024, .levels = 1 }),
    LevelCode.of(.{ .level_side = 2048, .levels = 1 }),
};
const cross_level_item_counts = [_]usize{
    LevelCode.of(.{ .level_side = 256, .levels = 8 }),
    LevelCode.of(.{ .level_side = 256, .levels = 32 }),
    LevelCode.of(.{ .level_side = 256, .levels = 128 }),
};
fn teleportCode(comptime layout: TeleportLayout, comptime teleports: usize, comptime level_side: u16) usize {
    return CrossLevelCode.of(.{ .layout = layout, .teleports = teleports, .level_side = level_side, .levels = 8 });
}

// The depth configs with the one corner teleport, then each layout's teleport-count axis.
const teleport_item_counts = cross_level_item_counts ++ [_]usize{
    teleportCode(.border_band, 64, 256),
    teleportCode(.border_band, 256, 256),
    teleportCode(.border_band, 1024, 256),
    teleportCode(.strip, teleport_strip_rows * 256 / 16, 256),
    teleportCode(.strip, teleport_strip_rows * 1024 / 16, 1024),
    teleportCode(.strip, teleport_strip_rows * 2048 / 16, 2048),
    teleportCode(.random_pads, 16, 256),
};

// Teleport-count configs place their teleports on level-0 cells this close to the border.
const teleport_border_band: u16 = 16;
// The strip layout's rows: this many, from this far north of the level center.
const teleport_strip_north: u16 = 112;
const teleport_strip_rows: u16 = 15;
// Random pads: the fixed seed, the least distance of an entrance from the routes' block, and
// the least planar span of a pad.
const random_pad_seed: u64 = 0x0064_9ad5;
const random_pad_route_clearance: u32 = 24;
const random_pad_min_span: u32 = 64;
const link_fold_side: u16 = 512;
const link_fold_levels: u16 = 8;
// Pads each timed link-fold reaction applies.
const link_fold_batch: usize = 64;
// Probe chunk pairs each probe-axis batch lands in, an equal share of its pads each.
const link_fold_probe_pairs: usize = 8;
// The uniform axis, then the probe axis in background pads at a fixed preload, then in
// preload at a fixed background.
const link_fold_item_counts = [_]usize{
    LinkFoldCode.of(.{ .axis = .uniform, .probe_preload = 0, .background_pads = 1024 }),
    LinkFoldCode.of(.{ .axis = .uniform, .probe_preload = 0, .background_pads = 8192 }),
    LinkFoldCode.of(.{ .axis = .uniform, .probe_preload = 0, .background_pads = 32768 }),
    LinkFoldCode.of(.{ .axis = .probe, .probe_preload = 16, .background_pads = 1024 }),
    LinkFoldCode.of(.{ .axis = .probe, .probe_preload = 16, .background_pads = 8192 }),
    LinkFoldCode.of(.{ .axis = .probe, .probe_preload = 16, .background_pads = 32768 }),
    LinkFoldCode.of(.{ .axis = .probe, .probe_preload = 4, .background_pads = 8192 }),
    LinkFoldCode.of(.{ .axis = .probe, .probe_preload = 64, .background_pads = 8192 }),
};

fn writeRouteWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("abstract_nodes={} routes_solved={}", .{ stats.candidate_pairs, stats.output_count });
}

fn writeLongPathWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("candidates={} outputs={}", .{ stats.candidate_pairs, stats.output_count });
}

fn writeLinkFoldWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("pads_held={} chunks_patched={}", .{ stats.output_count, stats.candidate_pairs });
    if (view == .details) try suite.writeNavMain(writer, stats.nav_main);
}

// Most abstract nodes any participant's or tier-1 pool entry's last search claimed this step.
fn lastAbstractNodesUsed(system: *const PathfindingSystem) usize {
    var nodes: usize = 0;
    for (system.scratch_slots.items) |*scratch| nodes = @max(nodes, scratch.corridor.abstract.nodes_used);
    for (system.tier1_scratch.items) |*entry| nodes = @max(nodes, entry.corridor.abstract.nodes_used);
    return nodes;
}

const route_request_count: usize = 64;
// Requests run from level 0 to this level in the cross-level groups.
const cross_level_goal_level: u16 = 4;

// The route fixtures never change nav after the build: no marks batch.
fn routeSizeConfig(side: usize, levels: usize, links: usize, participant_count: usize) nav_size.NavSizeConfig {
    return .{
        .side = side,
        .levels = levels,
        .links = links,
        .participant_count = participant_count,
        .agent_budget = route_request_count,
        .group_fields = 1,
        .batch = nav_size.NavBatch.none,
    };
}

fn runLevelSizeCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const code = try LevelCode.decode(item_count);
    const side = code.level_side;
    const levels = code.levels;
    if (levels != 1 or side < 256) return error.LevelSizeBadConfig;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const participant_count = fixtures.participantCount(thread_ptr);
    var size_config = routeSizeConfig(side, levels, 0, participant_count);

    var open = try buildOpenWorld(allocator, io, side, levels);
    var open_owned = true;
    errdefer if (open_owned) open.world.deinit();
    // A full-height blocking wall on the center column, open only at the two center rows.
    const center = side / 2;
    const wall = try allocator.alloc(CellCoord, side - 2);
    defer allocator.free(wall);
    var wall_len: usize = 0;
    for (0..side) |y| {
        if (y == center - 1 or y == center) continue;
        wall[wall_len] = .{ .x = center, .y = @intCast(y) };
        wall_len += 1;
    }
    try writeLevelZeroCells(&open, wall[0..wall_len], open.blocking);
    // The built world's content sizes the nav.
    size_config.content = pathfinding_test_support.navStorageContentOf(&open.world);
    try nav_size.checkNavSize(level_size_group.name, item_count, case, size_config);

    // An 8x8 block of starts left of the wall and their goals mirrored right of it,
    // rows 4 apart around the gap: each route crosses the gap.
    var requests: [route_request_count]PathRequest = undefined;
    for (&requests, 0..) |*request, index| {
        const column: u16 = @intCast(index % 8);
        const row: u16 = @intCast(index / 8);
        const y = center - 16 + row * 4;
        request.* = .{
            .entity = undefined,
            .start = open.cellCenter(.{ .x = center - 6 - column, .y = y }),
            .goal = open.cellCenter(.{ .x = center + 6 + column, .y = y + 1 }),
        };
    }
    open_owned = false;
    var fixture = try initRouteFixture(allocator, open, &requests, nav_size.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit();
    try nav_size.checkNavBytes(level_size_group.name, item_count, size_config, &fixture.system);
    const stats = try runColdRouteSteps(io, options, case, item_count, &fixture, thread_ptr, .fail);
    try nav_size.checkNavBytes(level_size_group.name, item_count, size_config, &fixture.system);
    return stats;
}

fn runCrossLevelDepthCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCrossLevelCase(allocator, io, options, case, item_count, false);
}

fn runCrossLevelTeleportCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCrossLevelCase(allocator, io, options, case, item_count, true);
}

// The ramp between level `upper` and `upper + 1`: alternating sides of the level
// center, so a route to level 4 crosses each level it passes.
fn crossLevelRampCell(center: u16, upper: u16) CellCoord {
    return .{ .x = if (upper % 2 == 0) center + 24 else center - 24, .y = center };
}

// Where a teleport-count config's teleports sit; each joins level 0 to the deepest level.
const TeleportLayout = enum(u8) {
    // Level-0 cells within `teleport_border_band` of the border, each to its point mirror.
    border_band,
    // `teleport_strip_rows` level-0 rows across the side, the first `teleport_strip_north`
    // north of the center, each to its point mirror.
    strip,
    // Random level-0 cells clear of the routes, each to an independent random cell.
    random_pads,
};

// A cross-level item code (`CrossLevelCode`).
const CrossLevelConfig = struct {
    layout: TeleportLayout,
    // 0: the teleport group's one corner-to-corner teleport, or none in the depth group.
    teleports: usize,
    side: u16,
    levels: u16,

    // Teleports in the depth group, a layout other than the border band with none, or a
    // config the fixture cannot build is an error.
    fn decode(item_count: usize, teleport: bool) !CrossLevelConfig {
        const code = try CrossLevelCode.decode(item_count);
        if (!teleport and (code.teleports != 0 or code.layout != .border_band)) return error.CrossLevelDepthHoldsTeleports;
        if (code.layout != .border_band and code.teleports == 0) return error.CrossLevelLayoutNoTeleports;
        if (code.levels <= cross_level_goal_level or code.level_side < 256) return error.CrossLevelWorldTooSmall;
        const layout_cells: usize = switch (code.layout) {
            .border_band => borderBandCells(code.level_side),
            .strip => @as(usize, teleport_strip_rows) * code.level_side,
            .random_pads => std.math.maxInt(usize),
        };
        if (code.teleports > layout_cells) return error.CrossLevelTeleportsExceedLayout;
        return .{ .layout = code.layout, .teleports = code.teleports, .side = code.level_side, .levels = code.levels };
    }
};

fn runCrossLevelCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, teleport: bool) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const config = try CrossLevelConfig.decode(item_count, teleport);
    const side = config.side;
    const levels = config.levels;
    const teleport_count = config.teleports;

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const participant_count = fixtures.participantCount(thread_ptr);
    const link_count: usize = levels - 1 + if (teleport_count != 0) teleport_count else @intFromBool(teleport);
    var size_config = routeSizeConfig(side, levels, link_count, participant_count);
    // Every ramp and teleport here is bidirectional.
    size_config.oneway_links = 0;
    const group_name = if (teleport) cross_level_teleport_group.name else cross_level_depth_group.name;

    var open = try buildOpenWorld(allocator, io, side, levels);
    var open_owned = true;
    errdefer if (open_owned) open.world.deinit();
    const center = side / 2;
    for (0..levels - 1) |upper_index| {
        const upper: u16 = @intCast(upper_index);
        const cell = crossLevelRampCell(center, upper);
        try open.world.addLevelLink(.{
            .kind = .ramp,
            .level_a = upper,
            .cell_a = cell,
            .level_b = upper + 1,
            .cell_b = cell,
            .traversal_cost = 1,
            .bidirectional = true,
        });
    }
    if (teleport_count != 0) {
        const deepest = levels - 1;
        switch (config.layout) {
            .border_band => try addBorderTeleports(&open.world, side, deepest, teleport_count),
            .strip => try addStripTeleports(&open.world, side, deepest, teleport_count),
            .random_pads => {
                var prng = std.Random.DefaultPrng.init(random_pad_seed);
                try addRandomPads(&open.world, prng.random(), side, deepest, teleport_count, 0);
            },
        }
    } else if (teleport) {
        try open.world.addLevelLink(.{
            .kind = .teleport,
            .level_a = 0,
            .cell_a = .{ .x = 8, .y = 8 },
            .level_b = levels - 1,
            .cell_b = .{ .x = side - 9, .y = side - 9 },
            .traversal_cost = 1,
            .bidirectional = true,
        });
    }

    // The built world's content and links size the nav.
    size_config.content = pathfinding_test_support.navStorageContentOf(&open.world);
    try nav_size.checkNavSize(group_name, item_count, case, size_config);

    // Starts in an 8x8 block at the level-0 center, goals in an 8x8 block below it on
    // level 4.
    var requests: [route_request_count]PathRequest = undefined;
    for (&requests, 0..) |*request, index| {
        const column: u16 = @intCast(index % 8);
        const row: u16 = @intCast(index / 8);
        request.* = .{
            .entity = undefined,
            .start_level = 0,
            .goal_level = cross_level_goal_level,
            .start = open.cellCenter(.{ .x = center - 4 + column, .y = center - 4 + row }),
            .goal = open.cellCenter(.{ .x = center - 4 + column, .y = center + 8 + row }),
        };
    }
    open_owned = false;
    var fixture = try initRouteFixture(allocator, open, &requests, nav_size.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit();
    try nav_size.checkNavBytes(group_name, item_count, size_config, &fixture.system);
    const stats = try runColdRouteSteps(io, options, case, item_count, &fixture, thread_ptr, if (teleport) .count else .fail);
    try nav_size.checkNavBytes(group_name, item_count, size_config, &fixture.system);
    return stats;
}

// Shaft group levels: requests start on one and end on the other.
const shaft_start_level: u16 = 1;
const shaft_goal_level: u16 = 5;
// Columns east of the starts' block at which the goals' block begins.
const shaft_goal_offset: u16 = 48;

fn runCrossLevelShaftCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const code = try LevelCode.decode(item_count);
    const side = code.level_side;
    const levels = code.levels;
    if (levels <= shaft_goal_level or side < 256) return error.CrossLevelShaftBadConfig;

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const participant_count = fixtures.participantCount(thread_ptr);
    // Ramps join levels 1..levels-1; one teleport leaves level 0.
    const link_count: usize = levels - 2 + 1;
    var size_config = routeSizeConfig(side, levels, link_count, participant_count);

    var open = try buildOpenWorld(allocator, io, side, levels);
    var open_owned = true;
    errdefer if (open_owned) open.world.deinit();
    const center = side / 2;
    // The shaft sits just west of the starts' 8x8 block.
    const shaft = CellCoord{ .x = center - 8, .y = center };
    for (shaft_start_level..levels - 1) |upper_index| {
        const upper: u16 = @intCast(upper_index);
        try open.world.addLevelLink(.{
            .kind = .ramp,
            .level_a = upper,
            .cell_a = shaft,
            .level_b = upper + 1,
            .cell_b = shaft,
            .traversal_cost = 1,
            .bidirectional = true,
        });
    }
    // Level 0 has no ramp, so this teleport's entrance is unreachable; its exit lands just
    // west of the goals' block on the goal level.
    try open.world.addLevelLink(.{
        .kind = .teleport,
        .level_a = 0,
        .cell_a = shaft,
        .level_b = shaft_goal_level,
        .cell_b = .{ .x = center - 4 + shaft_goal_offset - 2, .y = center },
        .traversal_cost = 1,
        .bidirectional = false,
    });
    // The built world's content and links size the nav.
    size_config.content = pathfinding_test_support.navStorageContentOf(&open.world);
    try nav_size.checkNavSize(cross_level_shaft_group.name, item_count, case, size_config);

    var requests: [route_request_count]PathRequest = undefined;
    for (&requests, 0..) |*request, index| {
        const column: u16 = @intCast(index % 8);
        const row: u16 = @intCast(index / 8);
        request.* = .{
            .entity = undefined,
            .start_level = shaft_start_level,
            .goal_level = shaft_goal_level,
            .start = open.cellCenter(.{ .x = center - 4 + column, .y = center - 4 + row }),
            .goal = open.cellCenter(.{ .x = center - 4 + shaft_goal_offset + column, .y = center - 4 + row }),
        };
    }
    open_owned = false;
    var fixture = try initRouteFixture(allocator, open, &requests, nav_size.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit();
    try nav_size.checkNavBytes(cross_level_shaft_group.name, item_count, size_config, &fixture.system);
    const stats = try runColdRouteSteps(io, options, case, item_count, &fixture, thread_ptr, .count);
    try nav_size.checkNavBytes(cross_level_shaft_group.name, item_count, size_config, &fixture.system);
    return stats;
}

const long_path_side: u16 = 2048;
// Serpentine rows per wall, and the open cells at one end of each wall.
const serpentine_pitch: u16 = 128;
const serpentine_gap: u16 = 8;
const serpentine_walls: u16 = long_path_side / serpentine_pitch - 1;
// The open diagonal's start on both axes.
const open_diagonal_origin: u16 = 8;
const stack_side: u16 = 256;
const descent_levels: u16 = 128;
// Ramps sit this far in from a level's corners on both axes.
const stack_corner_inset: u16 = 8;
const depth_descent: u16 = 4;
const wide_descent_levels: u16 = 3;
const deep_wide_side: u16 = 1024;
const long_path_crowd: usize = 32;
// Cave blobs: the seed, the blob count (expected cover 1 - e^-0.51, about 40%, at the mean
// disk area of radii 3 to 24), and the radius range.
const cave_seed: u64 = 0x0064_ca7e;
const cave_blobs: usize = 3100;
const cave_min_radius: u32 = 3;
const cave_max_radius: u32 = 24;
// Past the abstract nodes every long-path layout holds; a probe search that saturates fails
// the case.
const long_path_probe_nodes: usize = 1 << 18;

const LongPathLayout = enum(u8) {
    serpentine,
    open_diagonal,
    descent,
    depth,
    wide_descent,
    cave,
    deep_wide,
};

const LongPathVariant = enum(u8) {
    caps,
    probe,
    crowd,
    walk,
    hops,
};

const LongPathConfig = struct {
    variant: LongPathVariant,
    layout: LongPathLayout,
    parameter: u16,

    fn code(comptime variant: LongPathVariant, comptime layout: LongPathLayout, comptime parameter: u16) usize {
        return LongPathCode.of(.{ .variant = variant, .layout = layout, .parameter = parameter });
    }

    // A parameter the layout cannot build, a crowd off the serpentine and open diagonal, or a
    // walk off the planar layouts is an error.
    fn decode(item_count: usize) !LongPathConfig {
        const fields = try LongPathCode.decode(item_count);
        const parameter = fields.parameter;
        if (parameter == 0) return error.LongPathBadParameter;
        const config = LongPathConfig{ .variant = fields.variant, .layout = fields.layout, .parameter = parameter };
        const buildable = switch (config.layout) {
            .serpentine => parameter <= serpentine_walls,
            .open_diagonal, .cave => open_diagonal_origin + parameter < long_path_side,
            .descent => parameter < descent_levels,
            .depth => parameter > depth_descent,
            // Whole chunks, with room for both ramp corners.
            .wide_descent => parameter % default_chunk_size_tiles == 0 and parameter > 4 * stack_corner_inset,
            .deep_wide => parameter >= 2,
        };
        if (!buildable) return error.LongPathBadParameter;
        if (config.variant == .crowd and config.layout != .serpentine and config.layout != .open_diagonal) return error.LongPathCrowdLayout;
        if (config.variant == .walk and config.levels() != 1) return error.LongPathWalkLayout;
        return config;
    }

    fn levels(self: LongPathConfig) u16 {
        return switch (self.layout) {
            .serpentine, .open_diagonal, .cave => 1,
            .descent => descent_levels,
            .depth, .deep_wide => self.parameter,
            .wide_descent => wide_descent_levels,
        };
    }

    fn side(self: LongPathConfig) u16 {
        return switch (self.layout) {
            .serpentine, .open_diagonal, .cave => long_path_side,
            .descent, .depth => stack_side,
            .wide_descent => self.parameter,
            .deep_wide => deep_wide_side,
        };
    }

    // Levels the route descends.
    fn descent(self: LongPathConfig) u16 {
        return switch (self.layout) {
            .serpentine, .open_diagonal, .cave => 0,
            .descent => self.parameter,
            .depth => depth_descent,
            .wide_descent => wide_descent_levels - 1,
            .deep_wide => self.parameter - 1,
        };
    }

    fn agents(self: LongPathConfig) usize {
        return if (self.variant == .crowd) long_path_crowd else 1;
    }

    // The route's length in cells, derived from the layout's geometry; the cave's is its
    // diagonal's, a lower bound.
    fn routeCells(self: LongPathConfig) usize {
        const stack_crossing: usize = self.side() - 2 * stack_corner_inset - 1;
        return switch (self.layout) {
            .serpentine => @as(usize, long_path_side - serpentine_gap) * self.parameter,
            .open_diagonal, .cave => self.parameter,
            .descent, .depth, .wide_descent, .deep_wide => stack_crossing * (@as(usize, self.descent()) + 1),
        };
    }
};

// Each variant at 3 route lengths per layout: the caps curves, the probe on the same routes,
// the crowd, the walks, and the hop chains.
const long_path_item_counts = [_]usize{
    LongPathConfig.code(.caps, .serpentine, 1),
    LongPathConfig.code(.caps, .serpentine, 4),
    LongPathConfig.code(.caps, .serpentine, 15),
    LongPathConfig.code(.caps, .open_diagonal, 256),
    LongPathConfig.code(.caps, .open_diagonal, 1024),
    LongPathConfig.code(.caps, .open_diagonal, 2032),
    LongPathConfig.code(.caps, .descent, 4),
    LongPathConfig.code(.caps, .descent, 16),
    LongPathConfig.code(.caps, .descent, 127),
    LongPathConfig.code(.caps, .depth, 8),
    LongPathConfig.code(.caps, .depth, 32),
    LongPathConfig.code(.caps, .depth, 128),
    LongPathConfig.code(.caps, .wide_descent, 256),
    LongPathConfig.code(.caps, .wide_descent, 1024),
    LongPathConfig.code(.caps, .wide_descent, 2048),
    LongPathConfig.code(.caps, .cave, 256),
    LongPathConfig.code(.caps, .cave, 1024),
    LongPathConfig.code(.caps, .cave, 2032),
    LongPathConfig.code(.caps, .deep_wide, 4),
    LongPathConfig.code(.caps, .deep_wide, 8),
    LongPathConfig.code(.caps, .deep_wide, 16),
    LongPathConfig.code(.probe, .serpentine, 1),
    LongPathConfig.code(.probe, .serpentine, 4),
    LongPathConfig.code(.probe, .serpentine, 15),
    LongPathConfig.code(.probe, .open_diagonal, 256),
    LongPathConfig.code(.probe, .open_diagonal, 1024),
    LongPathConfig.code(.probe, .open_diagonal, 2032),
    LongPathConfig.code(.probe, .descent, 4),
    LongPathConfig.code(.probe, .descent, 16),
    LongPathConfig.code(.probe, .descent, 127),
    LongPathConfig.code(.probe, .wide_descent, 256),
    LongPathConfig.code(.probe, .wide_descent, 1024),
    LongPathConfig.code(.probe, .wide_descent, 2048),
    LongPathConfig.code(.probe, .cave, 256),
    LongPathConfig.code(.probe, .cave, 1024),
    LongPathConfig.code(.probe, .cave, 2032),
    LongPathConfig.code(.probe, .deep_wide, 4),
    LongPathConfig.code(.probe, .deep_wide, 8),
    LongPathConfig.code(.probe, .deep_wide, 16),
    LongPathConfig.code(.crowd, .serpentine, 1),
    LongPathConfig.code(.crowd, .serpentine, 4),
    LongPathConfig.code(.crowd, .serpentine, 15),
    LongPathConfig.code(.crowd, .open_diagonal, 256),
    LongPathConfig.code(.crowd, .open_diagonal, 1024),
    LongPathConfig.code(.crowd, .open_diagonal, 2032),
    LongPathConfig.code(.walk, .open_diagonal, 512),
    LongPathConfig.code(.walk, .open_diagonal, 1024),
    LongPathConfig.code(.walk, .open_diagonal, 2032),
    LongPathConfig.code(.walk, .cave, 512),
    LongPathConfig.code(.walk, .cave, 1024),
    LongPathConfig.code(.walk, .cave, 2032),
    // One wall: past the stitched-cell cap, inside the abstract cap. Four and fifteen: past the
    // abstract cap, each hop toward a saturated search's least-estimate node.
    LongPathConfig.code(.walk, .serpentine, 1),
    LongPathConfig.code(.walk, .serpentine, 4),
    LongPathConfig.code(.walk, .serpentine, 15),
    // The cross-level routes past the tier-1 abstract cap, as hop chains (a walk cannot change
    // level).
    LongPathConfig.code(.hops, .descent, 16),
    LongPathConfig.code(.hops, .descent, 64),
    LongPathConfig.code(.hops, .descent, 127),
    LongPathConfig.code(.hops, .wide_descent, 512),
    LongPathConfig.code(.hops, .wide_descent, 1024),
    LongPathConfig.code(.hops, .wide_descent, 2048),
    LongPathConfig.code(.hops, .deep_wide, 4),
    LongPathConfig.code(.hops, .deep_wide, 8),
    LongPathConfig.code(.hops, .deep_wide, 16),
};

// Walls on every `serpentine_pitch`-th row, odd walls open at the east end and even walls at
// the west end; returns the cells blocked.
fn addSerpentineWalls(allocator: std.mem.Allocator, open: *OpenWorld) !usize {
    const wall_cells = long_path_side - serpentine_gap;
    const cells = try allocator.alloc(CellCoord, @as(usize, serpentine_walls) * wall_cells);
    defer allocator.free(cells);
    var len: usize = 0;
    for (1..serpentine_walls + 1) |wall| {
        const first: u16 = if (wall % 2 == 1) 0 else serpentine_gap;
        for (first..first + wall_cells) |x| {
            // In range: x < long_path_side and wall * serpentine_pitch < long_path_side.
            cells[len] = .{ .x = @intCast(x), .y = @intCast(wall * serpentine_pitch) };
            len += 1;
        }
    }
    try writeLevelZeroCells(open, cells[0..len], open.blocking);
    return len;
}

// Sets (`value` true) or clears every cell of `cells` (a `long_path_side`² level, row-major)
// within `radius` of (center_x, center_y).
fn setDisk(cells: *std.DynamicBitSetUnmanaged, center_x: u32, center_y: u32, radius: u32, value: bool) void {
    const side: i64 = long_path_side;
    const reach: i64 = radius;
    const cx: i64 = center_x;
    const cy: i64 = center_y;
    const min_y = @max(0, cy - reach);
    const max_y = @min(side - 1, cy + reach);
    const min_x = @max(0, cx - reach);
    const max_x = @min(side - 1, cx + reach);
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy > reach * reach) continue;
            // In range: 0 <= x, y < side.
            cells.setValue(@intCast(y * side + x), value);
        }
    }
}

// Seeded blob caves over level 0: `cave_blobs` blocking disks at uniform centers and radii.
// The route's ends move to the cells of the main cave (the 4-connected open component of the
// open cell nearest the level center) nearest their targets, so the route exists; returns
// the cells blocked.
fn addCaveBlobs(allocator: std.mem.Allocator, open: *OpenWorld, route: *PlanarRoute) !usize {
    const side: u32 = long_path_side;
    var blocked = try std.DynamicBitSetUnmanaged.initEmpty(allocator, side * side);
    defer blocked.deinit(allocator);
    var prng = std.Random.DefaultPrng.init(cave_seed);
    const random = prng.random();
    for (0..cave_blobs) |_| {
        const center_x = random.uintLessThan(u32, side);
        const center_y = random.uintLessThan(u32, side);
        setDisk(&blocked, center_x, center_y, random.intRangeAtMost(u32, cave_min_radius, cave_max_radius), true);
    }
    const blocked_count = blocked.count();

    // The main cave: a flood from the open cell nearest the center.
    const center = CellCoord{ .x = long_path_side / 2, .y = long_path_side / 2 };
    const seed = nearestCell(&blocked, false, center) orelse return error.LongPathCaveSolid;
    var main_cave = try std.DynamicBitSetUnmanaged.initEmpty(allocator, side * side);
    defer main_cave.deinit(allocator);
    _ = try fixtures.flood4(allocator, side, side, .{ seed.x, seed.y }, CaveCells{ .blocked = &blocked, .side = side }, &main_cave);
    route.start = nearestCell(&main_cave, true, route.start) orelse return error.LongPathCaveSolid;
    route.goal = nearestCell(&main_cave, true, route.goal) orelse return error.LongPathCaveSolid;

    const cells = try allocator.alloc(CellCoord, blocked_count);
    defer allocator.free(cells);
    var iterator = blocked.iterator(.{});
    var len: usize = 0;
    while (iterator.next()) |index| : (len += 1) {
        // In range: index < side * side.
        cells[len] = .{ .x = @intCast(index % side), .y = @intCast(index / side) };
    }
    try writeLevelZeroCells(open, cells, open.blocking);
    return blocked_count;
}

// A cave level's open cells: those `blocked` leaves clear. A flood over them never stops early.
const CaveCells = struct {
    blocked: *const std.DynamicBitSetUnmanaged,
    side: u32,

    pub fn open(self: CaveCells, x: u32, y: u32) bool {
        return !self.blocked.isSet(@as(usize, y) * self.side + x);
    }

    pub fn stop(_: CaveCells, _: u32, _: u32) bool {
        return false;
    }
};

// The cell of a `long_path_side`² level whose bit in `cells` equals `value` nearest `target`
// (Chebyshev, then row-major order); null when none does.
fn nearestCell(cells: *const std.DynamicBitSetUnmanaged, value: bool, target: CellCoord) ?CellCoord {
    var best: ?CellCoord = null;
    var best_distance: u32 = std.math.maxInt(u32);
    for (0..long_path_side) |y| {
        for (0..long_path_side) |x| {
            if (cells.isSet(y * long_path_side + x) != value) continue;
            // In range: x, y < long_path_side.
            const cell = CellCoord{ .x = @intCast(x), .y = @intCast(y) };
            const distance = @max(@max(cell.x, target.x) - @min(cell.x, target.x), @max(cell.y, target.y) - @min(cell.y, target.y));
            if (distance >= best_distance) continue;
            best_distance = distance;
            best = cell;
        }
    }
    return best;
}

// A planar layout's start and goal cells.
fn planarRoute(config: LongPathConfig) PlanarRoute {
    return switch (config.layout) {
        .serpentine => .{
            .start = .{ .x = long_path_side / 2, .y = serpentine_pitch / 2 },
            .goal = .{ .x = long_path_side / 2, .y = config.parameter * serpentine_pitch + serpentine_pitch / 2 },
        },
        .open_diagonal, .descent, .depth, .wide_descent, .cave, .deep_wide => .{
            .start = .{ .x = open_diagonal_origin, .y = open_diagonal_origin },
            .goal = .{ .x = open_diagonal_origin + config.parameter, .y = open_diagonal_origin + config.parameter },
        },
    };
}

// Crowd member `index`'s start: the route's start for the first; the rest spread over the
// serpentine's first band, or an 8 x 4 block of the open diagonal's corner.
fn crowdStart(layout: LongPathLayout, start: CellCoord, index: usize) CellCoord {
    if (index == 0) return start;
    // In range: index < long_path_crowd keeps every coordinate below 2048.
    std.debug.assert(index < long_path_crowd);
    return switch (layout) {
        .serpentine => .{ .x = @intCast(128 + 56 * index), .y = @intCast(16 + 32 * (index % 4)) },
        .open_diagonal, .descent, .depth, .wide_descent, .cave, .deep_wide => .{
            .x = @intCast(open_diagonal_origin + 32 * (index % 8)),
            .y = @intCast(open_diagonal_origin + 32 * (index / 8)),
        },
    };
}

// The ramp from `upper` to the level below on levels of `side`: the far corner under even
// levels, the near one under odd levels.
fn stackRampCell(side: u16, upper: u16) CellCoord {
    const coord: u16 = if (upper % 2 == 0) side - 1 - stack_corner_inset else stack_corner_inset;
    return .{ .x = coord, .y = coord };
}

// A descent's goal: two cells inside the goal level's ramp corner, so the route crosses the
// goal level corner to corner like every level above it.
fn stackGoalCell(side: u16, goal_level: u16) CellCoord {
    const ramp = stackRampCell(side, goal_level);
    const coord: u16 = if (ramp.x == stack_corner_inset) ramp.x + 2 else ramp.x - 2;
    return .{ .x = coord, .y = coord };
}

const LongPathWorld = struct {
    open: OpenWorld,
    // Cells blocked on level 0.
    blocked: usize,
};

// Builds `config`'s world and writes its `config.agents()` requests, the layout's start first.
fn buildLongPathWorld(allocator: std.mem.Allocator, io: std.Io, config: LongPathConfig, requests: *[long_path_crowd]PathRequest) !LongPathWorld {
    const levels = config.levels();
    if (levels == 1) {
        var open = try buildOpenWorld(allocator, io, long_path_side, 1);
        errdefer open.world.deinit();
        var route = planarRoute(config);
        const blocked = switch (config.layout) {
            .serpentine => try addSerpentineWalls(allocator, &open),
            .cave => try addCaveBlobs(allocator, &open, &route),
            .open_diagonal, .descent, .depth, .wide_descent, .deep_wide => 0,
        };
        for (requests[0..config.agents()], 0..) |*request, index| {
            request.* = .{ .entity = undefined, .start = open.cellCenter(crowdStart(config.layout, route.start, index)), .goal = open.cellCenter(route.goal) };
        }
        return .{ .open = open, .blocked = blocked };
    }
    const side = config.side();
    var open = try buildOpenWorld(allocator, io, side, levels);
    errdefer open.world.deinit();
    for (0..levels - 1) |upper_index| {
        // In range: below the u16 level count.
        const upper: u16 = @intCast(upper_index);
        const cell = stackRampCell(side, upper);
        try open.world.addLevelLink(.{
            .kind = .ramp,
            .level_a = upper,
            .cell_a = cell,
            .level_b = upper + 1,
            .cell_b = cell,
            .traversal_cost = 1,
            .bidirectional = true,
        });
    }
    const goal_level = config.descent();
    requests[0] = .{
        .entity = undefined,
        .start_level = 0,
        .goal_level = goal_level,
        .start = open.cellCenter(.{ .x = stack_corner_inset, .y = stack_corner_inset }),
        .goal = open.cellCenter(stackGoalCell(side, goal_level)),
    };
    return .{ .open = open, .blocked = 0 };
}

const LongPathOutcome = enum {
    available,
    // A tier-1 stitch past its cell or segment cap published its prefix.
    partial,
    // A saturated tier-1 search published toward its least-estimate node.
    abstract_partial,
    // The abstract search hit its node cap or open-heap limit.
    abstract_saturated,
    // The stitch hit the attempt's stitched-cell cap.
    stitch_cells,
    // The stitch hit the segment-search cap.
    stitch_segments,
    // One segment's local search hit its node budget.
    stitch_segment_budget,
};

// One solve attempt's search, read from the scratch it ran in, and its step's time.
const LongPathAttempt = struct {
    nodes: usize,
    // The chosen corridor's nodes; zero when the search did not reach the goal.
    corridor: usize,
    // Stitched cells and segment searches; zero when the stitch did not run.
    cells: usize,
    segments: usize,
    // Crossing boxes the heuristic settled, and whether its budget froze the crossing search.
    settles: usize,
    frozen: bool,
    outcome: LongPathOutcome,
    ns: u64,

    fn sameWork(self: LongPathAttempt, other: LongPathAttempt) bool {
        return self.nodes == other.nodes and self.corridor == other.corridor and self.cells == other.cells and
            self.segments == other.segments and self.settles == other.settles and self.frozen == other.frozen and self.outcome == other.outcome;
    }
};

const LongPathCycle = struct {
    first: LongPathAttempt,
    escalated: ?LongPathAttempt,
    // Agents whose status is available (a cached path serves them), partial, and missing.
    available: usize,
    partial: usize,
    missing: usize,

    fn ns(self: LongPathCycle) u64 {
        return self.first.ns + if (self.escalated) |escalated| escalated.ns else 0;
    }

    fn sameWork(self: LongPathCycle, other: LongPathCycle) bool {
        if (!self.first.sameWork(other.first) or self.available != other.available or self.partial != other.partial or self.missing != other.missing) return false;
        const escalated = self.escalated orelse return other.escalated == null;
        const other_escalated = other.escalated orelse return false;
        return escalated.sameWork(other_escalated);
    }
};

// Times one inline step that must solve exactly one request, at `tier`, and reads that solve
// from its scratch: the participant's corridor for a first attempt, the first tier-1 pool
// entry (the step's only escalated admission) for an escalated one.
fn runLongPathAttempt(io: std.Io, threads: *ThreadSystem, system: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), request: PathRequest, agent_count: usize, tier: u8) !LongPathAttempt {
    const start_ns = suite.nowNs(io);
    const stats = try system.update(requests, agent_count, threads, longPathAttemptConfig(agent_count));
    const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
    if (stats.perf.unavailable_results != 0) return error.RouteUnavailable;
    if (stats.perf.start_invalid_dropped != 0) return error.RouteStartInvalid;
    if (stats.perf.solve_admissions != 1 or stats.perf.escalated_solves != @intFromBool(tier != 0)) return error.LongPathNotOneSolve;
    const corridor = if (tier == 0) &system.scratch_slots.items[0].corridor else &system.tier1_scratch.items[0].corridor;
    const abstract = &corridor.abstract;
    // A search that reached its goal leaves its corridor; a saturated one leaves it empty, or
    // cut at the corridor limit.
    const found = abstract.corridor.items.len != 0 and abstract.corridor.items.len < abstract.corridor_limit;
    const cells = if (found) corridor.stitched.items.len else 0;
    const segments = stats.perf.max_stitch_segments_observed;
    // The segment cap bounds every stitch's local searches.
    if (segments > system.capacity.max_stitch_segments) return error.StitchSegmentsPastCap;
    const outcome: LongPathOutcome = if (stats.perf.available_results == 1 or stats.perf.partial_results == 1) published: {
        // Every layout's route leaves its start's chunk, so the solve ran the abstract search.
        if (!found or stats.perf.abstract_solves != 1) return error.LongPathSolvedOffCorridor;
        if (stats.perf.partial_results == 0) break :published .available;
        break :published if (corridorEndsAtGoal(system, abstract.corridor.items, request)) .partial else .abstract_partial;
    } else if (stats.perf.budget_exhausted != 1)
        return error.LongPathUnexpectedOutcome
    else if (!found)
        .abstract_saturated
    else if (cells >= corridor.stitched_limit)
        .stitch_cells
    else if (segments >= system.capacity.max_stitch_segments)
        .stitch_segments
    else
        .stitch_segment_budget;
    return .{
        .nodes = abstract.nodes_used,
        .corridor = if (found) abstract.corridor.items.len else 0,
        .cells = cells,
        .segments = segments,
        .settles = abstract.crossing.settles,
        .frozen = abstract.crossing.frozen,
        .outcome = outcome,
        .ns = elapsed_ns,
    };
}

// A long-path attempt's inline step: every agent's request may solve.
fn longPathAttemptConfig(agent_count: usize) PathfindingConfig {
    return .{ .max_solved_requests_per_step = agent_count, .max_solve_admissions_per_step = agent_count };
}

// A walk's or hop chain's inline step: one solve.
const one_solve_config = PathfindingConfig{ .max_solved_requests_per_step = 1, .max_solve_admissions_per_step = 1 };

// Whether a corridor ends on a goal portal of `request` (`isGoalPortal` at its live goal); a
// least-estimate corridor ends short of one.
fn corridorEndsAtGoal(system: *const PathfindingSystem, corridor: []const usize, request: PathRequest) bool {
    const last = corridor[corridor.len - 1];
    const level = refLevel(last);
    const grid = system.graph.grid(level) orelse return false;
    const goal_grid = system.graph.grid(request.goal_level) orelse return false;
    const geometry = system.graph.chunkGeometry();
    const key = system.graph.keyForWorld(request.goal_level, request.goal, request.agent_class) orelse return false;
    const goal_index = system.liveGoal(key, goal_grid).cell orelse return false;
    const cell = refLocal(last);
    return isGoalPortal(level, geometry.chunkOfCell(cell), grid.labelAt(cell), request.goal_level, geometry.chunkOfCell(goal_index), goal_grid.labelAt(goal_index));
}

// One request cycle with nothing pending and every cached result expired (`drainPending`,
// `expireCachedResults`): the first attempt, the escalated attempt when the first exhausted,
// then every agent's status. No request stays pending after the second attempt: it solves or
// drops.
fn runLongPathCycle(io: std.Io, threads: *ThreadSystem, fixture: *RouteFixture, empty: *const RangeOutputStream(PathRequest), requests: []const PathRequest) !LongPathCycle {
    const system = &fixture.system;
    try drainPending(system, threads, requests.len, longPathAttemptConfig(requests.len));
    expireCachedResults(system);
    const first = try runLongPathAttempt(io, threads, system, &fixture.requests, requests[0], requests.len, 0);
    var escalated: ?LongPathAttempt = null;
    if (first.outcome != .available) {
        if (system.pending.len != 1 or system.pending.at(0).tier != 1) return error.LongPathNotEscalated;
        escalated = try runLongPathAttempt(io, threads, system, empty, requests[0], requests.len, 1);
    }
    if (system.pending.len != 0) return error.LongPathStillPending;
    var cycle = LongPathCycle{ .first = first, .escalated = escalated, .available = 0, .partial = 0, .missing = 0 };
    for (requests) |request| {
        switch (system.statusForWorld(request.start_level, request.start, request.goal_level, request.goal, request.agent_class, null).status) {
            .available => cycle.available += 1,
            .partial => cycle.partial += 1,
            .missing => cycle.missing += 1,
            .pending, .unavailable => return error.LongPathUnexpectedStatus,
        }
    }
    return cycle;
}

// Waypoints a walker advances per step: a hop of the tier-1 stitched cap ends well inside
// the result's TTL, so a walk measures refresh hops rather than TTL re-solves.
const walk_cells_per_step: usize = 16;
// Held steps in a row past which a walk fails: well past the two-attempt ladder a hop takes and
// its refresh cooldown.
const walk_stall_steps: usize = 32;

// One walk's counts and its timed steps' total.
const LongPathWalk = struct {
    // Abstract nodes claimed over every solve.
    claims: usize = 0,
    steps: usize = 0,
    // Steps the walker advanced no waypoint.
    held_steps: usize = 0,
    solves: usize = 0,
    partial_results: usize = 0,
    full_results: usize = 0,
    escalations: usize = 0,
    solve_ns: u64 = 0,

    fn sameWork(self: LongPathWalk, other: LongPathWalk) bool {
        return self.claims == other.claims and self.steps == other.steps and self.held_steps == other.held_steps and self.solves == other.solves and
            self.partial_results == other.partial_results and self.full_results == other.full_results and self.escalations == other.escalations;
    }
};

// Walks `request`'s agent to its goal with nothing pending and every cached result expired
// (`drainPending`, `expireCachedResults`; see the group comment).
fn runLongPathWalk(io: std.Io, threads: *ThreadSystem, fixture: *RouteFixture, stream: *RangeOutputStream(PathRequest), request: PathRequest, step_limit: usize) !LongPathWalk {
    const system = &fixture.system;
    try drainPending(system, threads, 1, one_solve_config);
    expireCachedResults(system);
    const grid = system.graph.grid(request.start_level) orelse return error.RouteUnavailable;
    const goal_cell = grid.worldToCellClamped(request.goal);
    var position = request.start;
    var hint: u32 = 0;
    var walk = LongPathWalk{};
    var held_in_row: usize = 0;
    const tier0_abstract = &system.scratch_slots.items[0].corridor.abstract;
    const tier1_abstract = &system.tier1_scratch.items[0].corridor.abstract;
    while (!std.meta.eql(grid.worldToCellClamped(position), goal_cell)) {
        if (walk.steps == step_limit) return error.LongPathWalkStalled;
        if (held_in_row == walk_stall_steps) break;
        walk.steps += 1;
        const view = system.statusForWorld(request.start_level, position, request.goal_level, request.goal, request.agent_class, &hint);
        if (view.status == .unavailable) return error.RouteUnavailable;
        const wants_hop = view.status == .missing or (view.status == .partial and view.refresh);
        var hop = request;
        hop.start = position;
        try fixtures.writeRequests(stream, if (wants_hop) &.{hop} else &.{});
        var moved: usize = 0;
        while (moved < walk_cells_per_step) : (moved += 1) {
            const next = system.statusForWorld(request.start_level, position, request.goal_level, request.goal, request.agent_class, &hint);
            if (next.status != .available and next.status != .partial) break;
            if (std.meta.eql(grid.worldToCellClamped(next.next_waypoint), grid.worldToCellClamped(position))) break;
            position = next.next_waypoint;
        }
        if (moved == 0) walk.held_steps += 1;
        held_in_row = if (moved == 0) held_in_row + 1 else 0;
        // Each step's claims, counted from empty tables.
        tier0_abstract.reset();
        tier1_abstract.reset();
        const start_ns = suite.nowNs(io);
        const stats = try system.update(stream, 1, threads, one_solve_config);
        walk.solve_ns += suite.elapsedNs(start_ns, suite.nowNs(io));
        walk.claims += tier0_abstract.nodes_used + tier1_abstract.nodes_used;
        if (stats.perf.unavailable_results != 0) return error.RouteUnavailable;
        if (stats.perf.start_invalid_dropped != 0) return error.RouteStartInvalid;
        walk.solves += stats.perf.solve_admissions;
        walk.partial_results += stats.perf.partial_results;
        walk.full_results += stats.perf.available_results - stats.perf.cache_hits;
        walk.escalations += stats.perf.escalated_solves;
    }
    if (!std.meta.eql(grid.worldToCellClamped(position), goal_cell)) return error.LongPathWalkStalled;
    return walk;
}

fn runLongPathWalkCase(allocator: std.mem.Allocator, io: std.Io, threads: *ThreadSystem, options: suite.Options, item_count: usize, config: LongPathConfig, fixture: *RouteFixture, request: PathRequest, blocked: usize) !suite.RunStats {
    var stream = RangeOutputStream(PathRequest).init(allocator);
    defer stream.deinit();
    const step_limit = 4 * config.routeCells() + 64;
    for (0..coldWarmup(options)) |_| _ = try runLongPathWalk(io, threads, fixture, &stream, request, step_limit);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var reference: ?LongPathWalk = null;
    for (0..coldIterations(options)) |_| {
        const walk = try runLongPathWalk(io, threads, fixture, &stream, request, step_limit);
        if (reference) |kept| {
            if (!kept.sameWork(walk)) return error.LongPathWorkVaried;
        } else reference = walk;
        accumulator.record(walk.solve_ns, inlineBatch(1, pathfinding_range_alignment_items));
    }
    var stats = accumulator.finish();
    const walk = reference orelse return stats;
    {
        stats.details.print("{s} walk parameter={} route~{} cells | steps={} held={} solves={} partial={} full={} escalations={} claims={} solve={}us | blocked={}\n", .{
            @tagName(config.layout),
            config.parameter,
            config.routeCells(),
            walk.steps,
            walk.held_steps,
            walk.solves,
            walk.partial_results,
            walk.full_results,
            walk.escalations,
            walk.claims,
            stats.mean_ns / std.time.ns_per_us,
            blocked,
        });
    }
    stats.candidate_pairs = walk.solves;
    stats.output_count = walk.partial_results + walk.full_results;
    stats.items_per_second = suite.itemsPerSecond(stats.output_count, stats.mean_ns);
    return stats;
}

// One hop chain's counts and its steps' total.
const LongPathHops = struct {
    // Requests the chain made: one per published hop, plus the last, which arrives or drops.
    hops: usize = 0,
    // Published hops toward a saturated search's least-estimate node.
    least_hops: usize = 0,
    // Abstract nodes claimed over every solve.
    claims: usize = 0,
    solves: usize = 0,
    escalations: usize = 0,
    // The last hop's start.
    stop_level: u16 = 0,
    stop_cell: u32 = 0,
    solve_ns: u64 = 0,

    fn sameWork(self: LongPathHops, other: LongPathHops) bool {
        return self.hops == other.hops and self.least_hops == other.least_hops and
            self.claims == other.claims and self.solves == other.solves and self.escalations == other.escalations and
            self.stop_level == other.stop_level and self.stop_cell == other.stop_cell;
    }
};

// Chains `request`'s hops with nothing pending and every cached result expired
// (`drainPending`, `expireCachedResults`): each hop's request runs its first attempt
// and, when that promoted, its escalated attempt; a partial restarts the chain at its end, on
// its level, until a hop arrives (`.available`) or drops (`.missing`).
fn runLongPathHops(io: std.Io, threads: *ThreadSystem, fixture: *RouteFixture, stream: *RangeOutputStream(PathRequest), request: PathRequest, hop_limit: usize) !LongPathHops {
    const system = &fixture.system;
    try drainPending(system, threads, 1, one_solve_config);
    expireCachedResults(system);
    const tier0_abstract = &system.scratch_slots.items[0].corridor.abstract;
    const tier1_abstract = &system.tier1_scratch.items[0].corridor.abstract;
    var chain = LongPathHops{};
    var hop = request;
    while (true) {
        if (chain.hops == hop_limit) return error.LongPathHopsUnbounded;
        chain.hops += 1;
        const grid = system.graph.grid(hop.start_level) orelse return error.RouteUnavailable;
        // In range: a cell index of a u16-sided level.
        chain.stop_cell = @intCast(grid.indexForCell(grid.worldToCellClamped(hop.start)) orelse return error.RouteStartInvalid);
        chain.stop_level = hop.start_level;
        try fixtures.writeRequests(stream, &.{hop});
        const ended: enum { arrived, partial, dropped } = for (0..2) |attempt| {
            // Each attempt's claims, counted from empty tables.
            tier0_abstract.reset();
            tier1_abstract.reset();
            const start_ns = suite.nowNs(io);
            const stats = try system.update(stream, 1, threads, one_solve_config);
            chain.solve_ns += suite.elapsedNs(start_ns, suite.nowNs(io));
            try fixtures.writeRequests(stream, &.{});
            chain.claims += tier0_abstract.nodes_used + tier1_abstract.nodes_used;
            if (stats.perf.unavailable_results != 0) return error.RouteUnavailable;
            if (stats.perf.start_invalid_dropped != 0) return error.RouteStartInvalid;
            if (stats.perf.solve_admissions != 1 or stats.perf.cache_hits != 0) return error.LongPathNotOneSolve;
            chain.solves += 1;
            chain.escalations += stats.perf.escalated_solves;
            if (stats.perf.available_results == 1) break .arrived;
            if (stats.perf.partial_results == 1) {
                if (attempt == 1 and !corridorEndsAtGoal(system, tier1_abstract.corridor.items, hop)) chain.least_hops += 1;
                break .partial;
            }
            // Neither arrived nor partial, and no longer pending: the tier-1 attempt dropped it.
            if (attempt == 1 and system.pending.len == 0) break .dropped;
            if (attempt == 1 or system.pending.len != 1 or system.pending.at(0).tier != 1) return error.LongPathNotEscalated;
        } else return error.LongPathStillPending;
        switch (ended) {
            .arrived => return chain,
            .dropped => return error.LongPathHopsDropped,
            .partial => {
                const end = system.solved_paths.items[0].end;
                const end_grid = system.graph.grid(end.level) orelse return error.RouteUnavailable;
                hop.start_level = end.level;
                hop.start = end_grid.cellCenter(end.cell);
            },
        }
    }
}

fn runLongPathHopsCase(allocator: std.mem.Allocator, io: std.Io, threads: *ThreadSystem, options: suite.Options, item_count: usize, config: LongPathConfig, fixture: *RouteFixture, request: PathRequest) !suite.RunStats {
    var stream = RangeOutputStream(PathRequest).init(allocator);
    defer stream.deinit();
    // Every published hop advances at least one cell.
    const hop_limit = config.routeCells() + 64;
    for (0..coldWarmup(options)) |_| _ = try runLongPathHops(io, threads, fixture, &stream, request, hop_limit);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var reference: ?LongPathHops = null;
    for (0..coldIterations(options)) |_| {
        const chain = try runLongPathHops(io, threads, fixture, &stream, request, hop_limit);
        if (reference) |kept| {
            if (!kept.sameWork(chain)) return error.LongPathWorkVaried;
        } else reference = chain;
        accumulator.record(chain.solve_ns, inlineBatch(1, pathfinding_range_alignment_items));
    }
    var stats = accumulator.finish();
    const chain = reference orelse return stats;
    {
        stats.details.print("{s} hops parameter={} route~{} cells | stop=L{}:{} hops={} least_hops={} solves={} escalations={} claims={} solve={}us\n", .{
            @tagName(config.layout),
            config.parameter,
            config.routeCells(),
            chain.stop_level,
            chain.stop_cell,
            chain.hops,
            chain.least_hops,
            chain.solves,
            chain.escalations,
            chain.claims,
            stats.mean_ns / std.time.ns_per_us,
        });
    }
    stats.candidate_pairs = chain.solves;
    stats.output_count = chain.hops;
    stats.items_per_second = suite.itemsPerSecond(stats.output_count, stats.mean_ns);
    return stats;
}

fn writeLongPathAttempt(details: *suite.DetailLines, label: []const u8, attempt: LongPathAttempt, mean_ns: u64) void {
    details.print(" | {s}: nodes={} corridor={} cells={} segments={} settles={} frozen={} outcome={s} {}us", .{
        label,
        attempt.nodes,
        attempt.corridor,
        attempt.cells,
        attempt.segments,
        attempt.settles,
        attempt.frozen,
        @tagName(attempt.outcome),
        mean_ns / std.time.ns_per_us,
    });
}

fn runLongPathCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    std.debug.assert(!case.usesThreadSystem());
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const config = try LongPathConfig.decode(item_count);
    const levels = config.levels();
    const agent_count = config.agents();
    var requests: [long_path_crowd]PathRequest = undefined;
    // The world first: its content sizes the nav.
    const built = try buildLongPathWorld(allocator, io, config, &requests);
    var open = built.open;
    var open_owned = true;
    defer if (open_owned) open.world.deinit();
    const size_config = nav_size.NavSizeConfig{
        .side = config.side(),
        .levels = levels,
        .links = levels - 1,
        // Every ramp is bidirectional.
        .oneway_links = 0,
        .participant_count = 1,
        .agent_budget = agent_count,
        .group_fields = 1,
        .batch = nav_size.NavBatch.none,
        .content = pathfinding_test_support.navStorageContentOf(&open.world),
        .tier1_abstract_nodes = if (config.variant == .probe) long_path_probe_nodes else default_tier1_abstract_node_cap,
    };
    try nav_size.checkNavSize(long_path_group.name, item_count, case, size_config);

    const capacity = nav_size.navSizeCapacity(size_config);
    open_owned = false;
    var fixture = try initRouteFixture(allocator, open, requests[0..agent_count], capacity, &threads);
    defer fixture.deinit();
    try nav_size.checkNavBytes(long_path_group.name, item_count, size_config, &fixture.system);
    var empty = RangeOutputStream(PathRequest).init(allocator);
    defer empty.deinit();
    const agents = requests[0..agent_count];
    // Every variant checks the nav's bytes again once its paths are cached and registered.
    if (config.variant == .walk or config.variant == .hops) {
        const stats = if (config.variant == .walk)
            try runLongPathWalkCase(allocator, io, &threads, options, item_count, config, &fixture, agents[0], built.blocked)
        else
            try runLongPathHopsCase(allocator, io, &threads, options, item_count, config, &fixture, agents[0]);
        try nav_size.checkNavBytes(long_path_group.name, item_count, size_config, &fixture.system);
        return stats;
    }

    for (0..coldWarmup(options)) |_| _ = try runLongPathCycle(io, &threads, &fixture, &empty, agents);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var reference: ?LongPathCycle = null;
    var first_ns: u64 = 0;
    var escalated_ns: u64 = 0;
    for (0..coldIterations(options)) |_| {
        const cycle = try runLongPathCycle(io, &threads, &fixture, &empty, agents);
        if (reference) |kept| {
            if (!kept.sameWork(cycle)) return error.LongPathWorkVaried;
        } else reference = cycle;
        if (config.variant == .probe) {
            if (cycle.escalated) |escalated| switch (escalated.outcome) {
                .abstract_saturated, .abstract_partial => return error.LongPathProbeSaturated,
                else => {},
            };
        }
        first_ns += cycle.first.ns;
        if (cycle.escalated) |escalated| escalated_ns += escalated.ns;
        accumulator.record(cycle.ns(), inlineBatch(1, pathfinding_range_alignment_items));
    }
    try nav_size.checkNavBytes(long_path_group.name, item_count, size_config, &fixture.system);
    var stats = accumulator.finish();
    const cycle = reference orelse return stats;
    {
        const samples: u64 = stats.iterations;
        stats.details.print("{s} {s} parameter={} route~{} cells agents={}", .{
            @tagName(config.layout),
            @tagName(config.variant),
            config.parameter,
            config.routeCells(),
            agent_count,
        });
        writeLongPathAttempt(&stats.details, "first", cycle.first, first_ns / samples);
        if (cycle.escalated) |escalated| writeLongPathAttempt(&stats.details, "escalated", escalated, escalated_ns / samples);
        stats.details.print(" | blocked={} status available={} partial={} missing={}\n", .{ built.blocked, cycle.available, cycle.partial, cycle.missing });
    }
    stats.candidate_pairs = (cycle.escalated orelse cycle.first).nodes;
    stats.output_count = cycle.available;
    stats.items_per_second = suite.itemsPerSecond(stats.output_count, stats.mean_ns);
    return stats;
}

// Adds `count` bidirectional teleports from level-0 cells within `teleport_border_band` of
// the border, spread evenly in row-major order, each to its point mirror on `deepest`. Each
// span far exceeds its cost, and every endpoint is at least 64 cells from the cross-level
// routes' starts and goals around the level center.
fn addBorderTeleports(world: *WorldSystem, side: u16, deepest: u16, count: usize) !void {
    const band_cells = borderBandCells(side);
    std.debug.assert(count <= band_cells);
    const center = side / 2;
    var band_index: usize = 0;
    var added: usize = 0;
    for (0..side) |y| {
        for (0..side) |x| {
            const in_band = x < teleport_border_band or y < teleport_border_band or
                x >= side - teleport_border_band or y >= side - teleport_border_band;
            if (!in_band) continue;
            defer band_index += 1;
            if (added == count or band_index != added * band_cells / count) continue;
            const cell = CellCoord{ .x = @intCast(x), .y = @intCast(y) };
            const mirror = CellCoord{ .x = side - 1 - cell.x, .y = side - 1 - cell.y };
            std.debug.assert(@max(@abs(@as(i32, cell.x) - center), @abs(@as(i32, cell.y) - center)) >= 64 + 16);
            std.debug.assert(@max(@abs(@as(i32, cell.x) - mirror.x), @abs(@as(i32, cell.y) - mirror.y)) > 64);
            try world.addLevelLink(.{
                .kind = .teleport,
                .level_a = 0,
                .cell_a = cell,
                .level_b = deepest,
                .cell_b = mirror,
                .traversal_cost = 1,
                .bidirectional = true,
            });
            added += 1;
        }
    }
    std.debug.assert(added == count);
}

// The level-local chunk index (row-major) of `cell`.
fn levelChunkIndex(world: *const WorldSystem, cell: CellCoord) usize {
    const chunk = world.chunkCoordForCell(cell.x, cell.y);
    // In range: chunk coordinates of an in-world cell are non-negative.
    return @as(usize, @intCast(chunk.y)) * world.chunkGeometry().chunks_x + @as(usize, @intCast(chunk.x));
}

// Level cells within `teleport_border_band` of the border.
fn borderBandCells(side: u16) usize {
    const inner = side - 2 * teleport_border_band;
    return @as(usize, side) * side - @as(usize, inner) * inner;
}

// Chebyshev distance from `cell` to the cross-level routes' planar block: the starts' 8x8
// block at the level center and the goals' 8x8 block below it.
fn routeBlockDistance(cell: CellCoord, center: u16) u32 {
    return @max(gapOutside(cell.x, center - 4, center + 3), gapOutside(cell.y, center - 4, center + 15));
}

// Distance from `value` to the closed range [low, high]; 0 inside it.
fn gapOutside(value: u16, low: u16, high: u16) u32 {
    if (value < low) return low - value;
    if (value > high) return value - high;
    return 0;
}

// Adds `count` bidirectional teleports from the strip's level-0 cells, spread evenly in
// row-major order, each to its point mirror on `deepest`. Both ends of every teleport lie at
// least 64 cells from the routes' block and its span far exceeds its cost.
fn addStripTeleports(world: *WorldSystem, side: u16, deepest: u16, count: usize) !void {
    const strip_cells = @as(usize, teleport_strip_rows) * side;
    std.debug.assert(count != 0 and count <= strip_cells);
    const center = side / 2;
    const first_row = center - teleport_strip_north;
    const links_before = world.levelLinks().len;
    for (0..count) |added| {
        const strip_index = added * strip_cells / count;
        const cell = CellCoord{ .x = @intCast(strip_index % side), .y = @intCast(first_row + strip_index / side) };
        const mirror = CellCoord{ .x = side - 1 - cell.x, .y = side - 1 - cell.y };
        std.debug.assert(routeBlockDistance(cell, center) >= 64 and routeBlockDistance(mirror, center) >= 64);
        std.debug.assert(@max(@abs(@as(i32, cell.x) - mirror.x), @abs(@as(i32, cell.y) - mirror.y)) > 64);
        try world.addLevelLink(.{
            .kind = .teleport,
            .level_a = 0,
            .cell_a = cell,
            .level_b = deepest,
            .cell_b = mirror,
            .traversal_cost = 1,
            .bidirectional = true,
        });
    }
    std.debug.assert(world.levelLinks().len == links_before + count);
}

// Adds `count` bidirectional random pads drawn from `random`: each from a level-0 cell at
// least `random_pad_route_clearance` from the routes' block to an independent cell on
// `deepest` at least `random_pad_min_span` away, so its span far exceeds its cost. Pads keep
// off the first `avoid_chunks` level-0 chunks in row-major order and their point-mirror chunks
// on `deepest` (the link-fold probe chunks).
fn addRandomPads(world: *WorldSystem, random: std.Random, side: u16, deepest: u16, count: usize, avoid_chunks: usize) !void {
    const center = side / 2;
    const links_before = world.levelLinks().len;
    const chunk_count = world.chunkCountPerLevel();
    std.debug.assert(avoid_chunks <= chunk_count);
    for (0..count) |_| {
        var entrance: CellCoord = undefined;
        while (true) {
            entrance = .{ .x = random.uintLessThan(u16, side), .y = random.uintLessThan(u16, side) };
            if (routeBlockDistance(entrance, center) >= random_pad_route_clearance and levelChunkIndex(world, entrance) >= avoid_chunks) break;
        }
        var exit: CellCoord = undefined;
        while (true) {
            exit = .{ .x = random.uintLessThan(u16, side), .y = random.uintLessThan(u16, side) };
            if (@max(@abs(@as(i32, entrance.x) - exit.x), @abs(@as(i32, entrance.y) - exit.y)) >= random_pad_min_span and
                levelChunkIndex(world, exit) < chunk_count - avoid_chunks) break;
        }
        try world.addLevelLink(.{
            .kind = .teleport,
            .level_a = 0,
            .cell_a = entrance,
            .level_b = deepest,
            .cell_b = exit,
            .traversal_cost = 1,
            .bidirectional = true,
        });
    }
    std.debug.assert(world.levelLinks().len == links_before + count);
}

// How a route group treats a route that did not solve within its cold step (its search
// exhausted the budget, so the request stays pending).
const UnsolvedRoutes = enum {
    // The step fails, so a routing regression can never read as a speedup.
    fail,
    // The step counts it: budget exhaustion is the measured outcome.
    count,
};

// One cold pathfinding step of the fixture's requests. Every fixture route exists and
// starts on an open cell, so an unavailable answer or an invalid start is a fixture fault.
fn runRouteStep(system: *PathfindingSystem, fixture: *RouteFixture, thread_system: *ThreadSystem, case: suite.BenchmarkCase, unsolved_routes: UnsolvedRoutes) !PathfindingStats {
    const count = route_request_count;
    const stats = try runColdOnce(system, &fixture.requests, thread_system, case, count, count, count);
    if (stats.perf.unavailable_results != 0) return error.RouteUnavailable;
    if (stats.perf.start_invalid_dropped != 0) return error.RouteStartInvalid;
    std.debug.assert(stats.perf.available_results <= count);
    if (unsolved_routes == .fail and (stats.perf.available_results != count or stats.perf.pending_requests != 0)) return error.RouteUnsolved;
    return stats;
}

// Times one cold pathfinding step of the fixture's requests per iteration, each with nothing
// pending and every cached result expired, untimed (`drainPending`, `expireCachedResults`).
fn runColdRouteSteps(io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, fixture: *RouteFixture, thread_system: *ThreadSystem, unsolved_routes: UnsolvedRoutes) !suite.RunStats {
    const system = &fixture.system;
    const cold_config = coldStepConfig(case, route_request_count, route_request_count);
    var warm = suite.Warmup.custom(case, options.warmup_iterations, suite.adaptiveSettleIterationLimit(options));
    while (warm.nextSettled(stepTunerSettle(system))) {
        try drainPending(system, thread_system, route_request_count, cold_config);
        expireCachedResults(system);
        _ = try runRouteStep(system, fixture, thread_system, case, unsolved_routes);
    }
    const settle = stepTunerSettle(system);
    const solve_start = suite.TunerStart.of(&system.tuners.solve, case);

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    var abstract_nodes: usize = 0;
    var stage_report = StageReport{};
    for (0..options.iterations) |_| {
        try drainPending(system, thread_system, route_request_count, cold_config);
        expireCachedResults(system);
        const start_ns = suite.nowNs(io);
        last_stats = try runRouteStep(system, fixture, thread_system, case, unsolved_routes);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        accumulator.record(elapsed_ns, last_stats.perf.solve_batch);
        stage_report.add(elapsed_ns, last_stats);
        abstract_nodes = lastAbstractNodesUsed(system);
    }
    if (unsolved_routes == .count) stage_report.routes = .{ .solved = last_stats.perf.available_results, .unsolved = route_request_count - last_stats.perf.available_results };
    var stats = accumulator.finish();
    stage_report.write(&stats.details);
    stats.output_count = last_stats.perf.available_results;
    stats.candidate_pairs = abstract_nodes;
    stats.items_per_second = suite.itemsPerSecond(stats.output_count, stats.mean_ns);
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        stats.work_tuning = suite.workTuningSummary(&system.tuners.solve, solve_start);
    }
    return stats;
}

// Where a link-fold run's timed batches land.
const LinkFoldAxis = enum(u8) {
    // Uniformly over level 0 and the deepest level, as the background pads do.
    uniform,
    // In probe chunks of their own, each preloaded and kept off by the background pads.
    probe,
};

// A link-fold item code (`LinkFoldCode`).
const LinkFoldConfig = struct {
    axis: LinkFoldAxis,
    // Pads ending in each probe chunk before its batch lands.
    preload: usize,
    // Random pads before the run, off the probe chunks.
    pads: usize,

    // A uniform run with a preload, or a uniform run with no pads, is an error.
    fn decode(item_count: usize) !LinkFoldConfig {
        const code = try LinkFoldCode.decode(item_count);
        if (code.axis == .uniform and code.probe_preload != 0) return error.LinkFoldUniformPreload;
        if (code.axis == .uniform and code.background_pads == 0) return error.LinkFoldNoPads;
        return .{ .axis = code.axis, .preload = code.probe_preload, .pads = code.background_pads };
    }

    // Probe chunk pairs a run of `samples` batches takes: one set per batch.
    fn probePairs(self: LinkFoldConfig, samples: usize) usize {
        return if (self.axis == .probe) samples * link_fold_probe_pairs else 0;
    }

    // The pads a run of `samples` batches leaves in the world.
    fn padsAfter(self: LinkFoldConfig, samples: usize) usize {
        return self.pads + self.probePairs(samples) * self.preload + samples * link_fold_batch;
    }
};

fn runLinkFoldCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const config = try LinkFoldConfig.decode(item_count);
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const participant_count = fixtures.participantCount(thread_ptr);
    // A jump's shape, held across its count band, is judged by its first two records, so at
    // least two untimed batches run whatever the warmup count, the same in every case.
    const warmup_batches = @max(options.warmup_iterations, 2);
    // Every sample adds a batch, so the size check holds at the most pads the run holds.
    const samples = warmup_batches + options.iterations;
    const peak_pads = config.padsAfter(samples);
    // A timed batch's pads and their endpoint chunks, or the in-band toggle's one cell; the
    // probe preload is in the build.
    var size_config = toggleSizeConfig(link_fold_side, link_fold_levels, peak_pads, participant_count, .{ .mark_chunks = 1, .links = link_fold_batch, .keys = @max(2 * link_fold_batch, toggle_batch_keys) });
    // Every pad is bidirectional.
    size_config.oneway_links = 0;
    try nav_size.checkNavSize(link_fold_group.name, item_count, case, size_config);

    var prng = std.Random.DefaultPrng.init(random_pad_seed);
    const random = prng.random();
    const probe_pairs = config.probePairs(samples);
    var fixture = try initLinkFoldFixture(allocator, io, random, config, probe_pairs, nav_size.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    try nav_size.checkNavBytes(link_fold_group.name, item_count, size_config, &fixture.system);
    fixtures.setNavTuners(&fixture.system, case);
    // The in-band toggle's reopen reacts on its own stage tuner set.
    var revert_tuners: fixtures.NavTuners = fixture.system.tuners;
    try fixture.changed.ensureTotalCapacity(allocator, 1);
    // The stage tuners train in play on ordinary nav reactions, so the tuned case settles them
    // on in-band toggles; the pads stay fixed meanwhile, so the settle length never changes the
    // measured world. At least two toggles in every case.
    var warm = suite.Warmup.custom(case, 2, suite.adaptiveSettleIterationLimit(options));
    while (warm.nextSettled(linkFoldTunerSettle(&fixture.system, &revert_tuners))) try toggleLinkFoldInBandCell(io, &fixture, &revert_tuners, thread_ptr);
    var batch: usize = 0;
    // Each untimed batch after an in-band toggle grows the per-range scratch to the settled
    // tuners' jump shape and lets the jump's records judge it.
    for (0..warmup_batches) |_| {
        try toggleLinkFoldInBandCell(io, &fixture, &revert_tuners, thread_ptr);
        _ = try foldPadBatch(io, &fixture, random, config, probe_pairs, batch, thread_ptr);
        batch += 1;
    }
    const settle = linkFoldTunerSettle(&fixture.system, &revert_tuners);
    const patch_tuner = fixture.system.tuners.nav.getPtrConst(.patch);
    const patch_start = suite.TunerStart.of(patch_tuner, case);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var report = LinkFoldReport{};
    for (0..options.iterations) |_| {
        try toggleLinkFoldInBandCell(io, &fixture, &revert_tuners, thread_ptr);
        const jump_before = patch_tuner.jump_profile;
        const skips_before = patch_tuner.shift_skip_count;
        const sample = try foldPadBatch(io, &fixture, random, config, probe_pairs, batch, thread_ptr);
        batch += 1;
        const patch = sample.reaction.stats.perf.patch_batch;
        accumulator.record(sample.reaction.elapsed_ns, patch);
        report.add(sample, sample.reaction.stats.perf.plan_batch, patch, fixture.open.world.levelLinks().len);
        // A skipped record on a tuner with no threaded profile and a jump entry took the jump.
        const jumped = patch_tuner.shift_skip_count != skips_before and !patch_tuner.has_threaded_profile;
        if (case.adaptive and jumped) report.addPatchJump(jump_before, patch_tuner.jump_profile, patch.item_count);
    }
    const pads_held = fixture.open.world.levelLinks().len;
    if (pads_held != peak_pads) return error.LinkFoldDrift;
    if (case.adaptive and report.patch_jumps != options.iterations) return error.LinkFoldPatchNotJump;
    if (report.patch_jump_repredicted != 0) return error.LinkFoldJumpRepredicted;
    // Uniform batches touch varying chunk counts, so the band, not a repeated count, is reused.
    if (case.adaptive and config.axis == .uniform and report.patch_jump_off_count == 0) return error.LinkFoldJumpCountFixed;
    try nav_size.checkNavBytes(link_fold_group.name, item_count, size_config, &fixture.system);
    var stats = accumulator.finish();
    report.write(&stats.details);
    stats.output_count = pads_held;
    stats.candidate_pairs = report.chunks_patched;
    stats.nav_main = report.stages.nav_main;
    stats.items_per_second = suite.itemsPerSecond(link_fold_batch, stats.mean_ns);
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        stats.work_tuning = suite.workTuningSummary(patch_tuner, patch_start);
    }
    return stats;
}

// The link-fold cases' census: the forward stage tuner set (the system's) and the in-band
// toggle's revert set.
fn linkFoldTunerSettle(system: *const PathfindingSystem, revert_tuners: *const fixtures.NavTuners) suite.TunerSettle {
    var census = stepTunerSettle(system);
    fixtures.addNavTuners(&census, "revert.", revert_tuners);
    return census;
}

// The link-fold cases' in-band nav work, untimed: the cell at level 1's centre (no pad joins
// level 1) blocked and reacted to on the forward stage tuners, then reopened and reacted to
// on `revert_tuners` (swapped in and out), which returns terrain and nav to their state before.
fn toggleLinkFoldInBandCell(io: std.Io, fixture: *ReactFixture, revert_tuners: *fixtures.NavTuners, thread_system: *ThreadSystem) !void {
    const cell = [_]CellCoord{.{ .x = link_fold_side / 2, .y = link_fold_side / 2 }};
    _ = try fixture.changeLevelAndReact(io, 1, &cell, fixture.open.blocking, thread_system);
    fixtures.swapNavTuners(&fixture.system, revert_tuners);
    defer fixtures.swapNavTuners(&fixture.system, revert_tuners);
    _ = try fixture.changeLevelAndReact(io, 1, &cell, fixture.open.walkable, thread_system);
}

// The link-fold world, with no requests: `config.pads` random pads off the first
// `probe_pairs` probe chunk pairs, and `config.preload` pads joining each pair.
fn initLinkFoldFixture(allocator: std.mem.Allocator, io: std.Io, random: std.Random, config: LinkFoldConfig, probe_pairs: usize, capacity: PathfindingCapacity, thread_system: *ThreadSystem) !ReactFixture {
    var open = try buildOpenWorld(allocator, io, link_fold_side, link_fold_levels);
    errdefer open.world.deinit();
    const deepest = link_fold_levels - 1;
    try addRandomPads(&open.world, random, link_fold_side, deepest, config.pads, probe_pairs);
    try addProbePads(&open.world, random, deepest, 0, probe_pairs, config.preload);
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const requests = try allocator.alloc(PathRequest, 0);
    errdefer allocator.free(requests);
    return assembleReactFixture(allocator, &open, &data, requests, capacity, thread_system);
}

// Adds `per_pair` bidirectional pads to each probe chunk pair in `[first_pair, first_pair +
// pairs)`: pair `p` joins level-0 chunk `p` (row-major) to its point-mirror chunk on
// `deepest`, each pad between random cells of the two. Fails when a pad's span falls under
// `random_pad_min_span`, so a pad never reads as a short link.
fn addProbePads(world: *WorldSystem, random: std.Random, deepest: u16, first_pair: usize, pairs: usize, per_pair: usize) !void {
    const chunks_x: usize = world.chunkGeometry().chunks_x;
    const chunks_y: usize = world.chunkGeometry().chunks_y;
    const tiles = world.chunk_size_tiles;
    if (first_pair + pairs > chunks_x * chunks_y) return error.LinkFoldProbeTooMany;
    for (first_pair..first_pair + pairs) |pair| {
        const entrance_chunk = CellCoord{ .x = @intCast(pair % chunks_x), .y = @intCast(pair / chunks_x) };
        const exit_chunk = CellCoord{ .x = @intCast(chunks_x - 1 - entrance_chunk.x), .y = @intCast(chunks_y - 1 - entrance_chunk.y) };
        for (0..per_pair) |_| {
            const entrance = CellCoord{ .x = entrance_chunk.x * tiles + random.uintLessThan(u16, tiles), .y = entrance_chunk.y * tiles + random.uintLessThan(u16, tiles) };
            const exit = CellCoord{ .x = exit_chunk.x * tiles + random.uintLessThan(u16, tiles), .y = exit_chunk.y * tiles + random.uintLessThan(u16, tiles) };
            if (@max(@abs(@as(i32, entrance.x) - exit.x), @abs(@as(i32, entrance.y) - exit.y)) < random_pad_min_span) return error.LinkFoldProbeSpan;
            try world.addLevelLink(.{
                .kind = .teleport,
                .level_a = 0,
                .cell_a = entrance,
                .level_b = deepest,
                .cell_b = exit,
                .traversal_cost = 1,
                .bidirectional = true,
            });
        }
    }
}

// One timed link-fold reaction and the chunks it touched: the batch's distinct endpoint
// chunks and the link endpoints they hold after it.
const LinkFoldSample = struct {
    reaction: Reaction,
    touched_chunks: usize,
    touched_endpoints: usize,
};

// Adds batch `batch`'s `link_fold_batch` pads to the world (untimed): uniform random pads, or
// `link_fold_probe_pairs` probe pairs of its own on the probe axis. Then times the post-commit
// nav reaction that applies them and counts the touched chunks' endpoints untimed. Fails
// unless the reaction applied every pad in one marks batch and patched exactly the touched
// chunks.
fn foldPadBatch(io: std.Io, fixture: *ReactFixture, random: std.Random, config: LinkFoldConfig, probe_pairs: usize, batch: usize, thread_system: *ThreadSystem) !LinkFoldSample {
    const world = &fixture.open.world;
    const graph = &fixture.system.graph;
    const applied_before = graph.links_applied;
    std.debug.assert(applied_before == world.levelLinks().len);
    const deepest = link_fold_levels - 1;
    switch (config.axis) {
        .uniform => try addRandomPads(world, random, link_fold_side, deepest, link_fold_batch, 0),
        .probe => {
            const first_pair = batch * link_fold_probe_pairs;
            if (first_pair + link_fold_probe_pairs > probe_pairs) return error.LinkFoldProbeTooFew;
            try addProbePads(world, random, deepest, first_pair, link_fold_probe_pairs, link_fold_batch / link_fold_probe_pairs);
        },
    }
    fixture.frame.beginStep();
    const version_before = graph.version;
    const start_ns = suite.nowNs(io);
    const stats = try fixture.system.reactToPostCommitNavEvents(&fixture.frame, &fixture.colliders, world, thread_system);
    const elapsed = suite.elapsedNs(start_ns, suite.nowNs(io));
    if (stats.incremental_rebuilds != 1) return error.LinkFoldNoBatch;
    if (graph.version != version_before) return error.LinkFoldRebuiltNav;
    if (graph.links_applied != applied_before + link_fold_batch) return error.LinkFoldPadsPending;
    var sample = LinkFoldSample{ .reaction = .{ .elapsed_ns = elapsed, .stats = stats }, .touched_chunks = 0, .touched_endpoints = 0 };
    // Each endpoint's chunk as level << 32 | level-local chunk index, sorted so repeats sit together.
    var keys: [2 * link_fold_batch]u64 = undefined;
    for (world.levelLinks()[applied_before..], 0..) |link, index| {
        keys[2 * index] = @as(u64, link.level_a) << 32 | levelChunkIndex(world, link.cell_a);
        keys[2 * index + 1] = @as(u64, link.level_b) << 32 | levelChunkIndex(world, link.cell_b);
    }
    std.mem.sort(u64, &keys, {}, std.sort.asc(u64));
    for (keys, 0..) |key, index| {
        if (index != 0 and keys[index - 1] == key) continue;
        sample.touched_chunks += 1;
        // In range: the level and the level-local chunk index were packed above.
        sample.touched_endpoints += world.levelChunkLinkEndpointCount(@intCast(key >> 32), @intCast(key & std.math.maxInt(u32)));
    }
    if (stats.chunks_patched != sample.touched_chunks) return error.LinkFoldPatchShape;
    return sample;
}

// A tuner's held jump entry, as the link-fold report reads it.
const PatchJump = @FieldType(AdaptiveWorkTuner, "jump_profile");

// The timed link-fold reactions' plan, patch, and connectivity gather shapes and main-thread
// share and split, the chunks the last reaction patched, the endpoints of the chunks the
// reactions touched summed with those chunks, and the pads held after each reaction, summed.

const LinkFoldReport = struct {
    stages: ReactionStages = .{},
    chunks_patched: usize = 0,
    touched_chunks: usize = 0,
    touched_endpoints: usize = 0,
    pads_held: usize = 0,
    // The tuned case's timed patch jumps: their item count range, those at a count other than
    // their judgment entry's, and those that took a new entry (re-predicted) rather than the
    // judged one their count band covers.
    patch_jumps: usize = 0,
    patch_jump_min_items: usize = std.math.maxInt(usize),
    patch_jump_max_items: usize = 0,
    patch_jump_off_count: usize = 0,
    patch_jump_repredicted: usize = 0,

    // A timed patch batch that took the jump branch, which reads or sets the tuner's jump
    // entry; one without a per-item model holds none.
    fn addPatchJump(self: *LinkFoldReport, before: PatchJump, after: PatchJump, item_count: usize) void {
        const entry = after orelse return;
        self.patch_jumps += 1;
        self.patch_jump_min_items = @min(self.patch_jump_min_items, item_count);
        self.patch_jump_max_items = @max(self.patch_jump_max_items, item_count);
        if (entry.item_count != item_count) self.patch_jump_off_count += 1;
        const reused = if (before) |held| held.learned_item_count == entry.learned_item_count and held.item_count == entry.item_count else false;
        if (!reused) self.patch_jump_repredicted += 1;
    }

    fn add(self: *LinkFoldReport, sample: LinkFoldSample, plan: BatchStats, patch: BatchStats, pads_held: usize) void {
        self.stages.add(sample.reaction, .{ plan, patch, sample.reaction.stats.perf.conn_gather_batch });
        self.chunks_patched = sample.reaction.stats.chunks_patched;
        self.touched_chunks += sample.touched_chunks;
        self.touched_endpoints += sample.touched_endpoints;
        self.pads_held += pads_held;
    }

    fn write(self: LinkFoldReport, details: *suite.DetailLines) void {
        const stages = self.stages;
        if (stages.timed_ns == 0) return;
        var shapes: [3][48]u8 = undefined;
        const labels = stages.labels(&shapes);
        var main_buffer: [320]u8 = undefined;
        const endpoints_x10 = self.touched_endpoints * 10 / self.touched_chunks;
        const pad_samples = stages.samples * link_fold_batch;
        details.print("plan={s} patch={s} conn_gather={s} per_pad={}ns commit_per_pad={}ns endpoints_per_touched_chunk={}.{} pads_held_mean={} main={}us ({}%) patched={}{s}\n", .{
            labels[0],
            labels[1],
            labels[2],
            @as(u64, @intCast(stages.timed_ns / pad_samples)),
            stages.nav_main.sections.commit_ns / pad_samples,
            endpoints_x10 / 10,
            endpoints_x10 % 10,
            self.pads_held / stages.samples,
            stages.mainUsPerSample(),
            stages.mainPercent(),
            self.chunks_patched,
            suite.formatNavMainInto(&main_buffer, stages.nav_main),
        });
        if (self.patch_jumps != 0) details.print("patch_jumps={} patch_jump_items={}-{} patch_jump_off_count={} patch_jump_repredicted={}\n", .{ self.patch_jumps, self.patch_jump_min_items, self.patch_jump_max_items, self.patch_jump_off_count, self.patch_jump_repredicted });
    }
};
