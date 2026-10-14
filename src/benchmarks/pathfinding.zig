// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const ParallelRange = @import("../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../app/thread_system.zig").WorkerId;
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const inlineBatch = @import("../app/thread_system.zig").inlineBatch;
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const math = @import("../core/math.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const PathRequest = @import("../game/simulation.zig").PathRequest;
const RangeOutputStream = @import("../game/simulation.zig").RangeOutputStream;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const SimulationEvent = @import("../game/simulation.zig").SimulationEvent;
const PathfindingCapacity = @import("../game/systems/pathfinding.zig").PathfindingCapacity;
const PathfindingStats = @import("../game/systems/pathfinding.zig").PathfindingStats;
const PathfindingSystem = @import("../game/systems/pathfinding.zig").PathfindingSystem;
const NavGraph = @import("../game/systems/pathfinding/nav_graph.zig").NavGraph;
const StaticColliderSystem = @import("../game/systems/static_colliders.zig").StaticColliderSystem;
const default_max_solves_per_frame = @import("../game/systems/pathfinding.zig").default_max_solves_per_frame;
const pathfinding_range_alignment_items = @import("../game/systems/pathfinding.zig").pathfinding_range_alignment_items;
const PathQueryKey = @import("../game/systems/pathfinding/types.zig").PathQueryKey;
const default_tier1_abstract_node_cap = @import("../game/systems/pathfinding/types.zig").default_tier1_abstract_node_cap;
const refLevel = @import("../game/systems/pathfinding/types.zig").refLevel;
const refLocal = @import("../game/systems/pathfinding/types.zig").refLocal;
const cached_results_per_agent = @import("../game/systems/pathfinding/types.zig").cached_results_per_agent;
const min_capacity_floor = @import("../game/systems/pathfinding/types.zig").min_capacity_floor;
const intake_range_alignment_items = @import("../game/systems/pathfinding/types.zig").intake_range_alignment_items;
const NavUpdateStats = @import("../game/systems/pathfinding/types.zig").NavUpdateStats;
const GoalResolveStats = @import("../game/systems/pathfinding/types.zig").GoalResolveStats;
const goal_scan_range_alignment_items = @import("../game/systems/pathfinding/goal_table.zig").scan_range_alignment_items;
const goal_project_range_alignment_items = @import("../game/systems/pathfinding/goal_table.zig").project_range_alignment_items;
const AiDir = @import("../game/systems/ai.zig").AiDir;
const computeRequantizedGoal = @import("../game/systems/ai.zig").computeRequantizedGoal;
const default_goal_requantization_hysteresis_distance = @import("../game/systems/ai.zig").default_goal_requantization_hysteresis_distance;
const WorldSystem = @import("../game/world_system.zig").WorldSystem;
const CellCoord = @import("../game/world_system.zig").CellCoord;
const TileId = @import("../game/world_system.zig").TileId;
const default_chunk_size_tiles = @import("../game/world_system.zig").default_chunk_size_tiles;
const default_group_field_build_budget = @import("../game/systems/pathfinding/types.zig").default_group_field_build_budget;
const isGoalPortal = @import("../game/systems/pathfinding/solve.zig").isGoalPortal;
const connectivity = @import("../game/systems/pathfinding/connectivity.zig");
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

// The request-load groups (`pathfinding` through `pathfinding-query`) run world-backed nav on
// one walkable level of a fixed side per layout, so the item count varies the load and never
// the world; every request's route is the same at every count. Each times `update` steps;
// `--details` prints each update stage's busiest shape and the main-thread time per phase.
//   - Open routes (`pathfinding`, `-drain`, `-cache-open`, `-query`): request `i`'s goal on a
//     grid of `request_columns` columns from cell (8, 8) of a `request_side`² level, its start
//     (`request_route_dx`, `request_route_dy`) cells further on, a route across several chunks.
//   - `-shared-goal`: the open routes' starts, every request to one far goal.
//   - `-cache-detour`: a full-height wall down the level's middle, open at row
//     `detour_gap_y`; starts in `detour_lanes` lanes left of it, goals mirrored right.
//   - `-hard-fallback*`: a `hard_fallback_side`² level with one blocking cell on every third
//     row's center; each request crosses its row past that cell.

// Cold solve curve: one cold step of distinct-goal requests (runtime state cleared before
// it, untimed), solving min(count, the per-step solve ceiling) and deferring the rest.
// Items/s is solves serviced. Passes when the time grows linearly to the ceiling and is flat
// past it.
pub const group = suite.BenchmarkGroup{
    .name = "pathfinding",
    .item_label = "path requests",
    .defaultItemCounts = coldSolveItemCounts,
    .runCase = runCase,
    .write_workload = writeSolveWorkload,
};

// One cold step of requests sharing one goal: one solve, every other request folded into
// its pending entry; the group-field threshold sits above the count, so no field begins.
// Items/s is requests answered. Passes when linear in requests with one solve per step.
pub const dedup_group = suite.BenchmarkGroup{
    .name = "pathfinding-shared-goal",
    .item_label = "path requests to one goal",
    .defaultItemCounts = sharedGoalItemCounts,
    .runCase = runDedupCase,
    .write_workload = writeDedupWorkload,
};

// A drain step: the item count's distinct requests accepted once (untimed), then each timed
// step solves the per-step ceiling of the carried queue over an empty stream. Passes when
// flat in queue depth.
pub const drain_group = suite.BenchmarkGroup{
    .name = "pathfinding-drain",
    .item_label = "queued path requests",
    .defaultItemCounts = drainItemCounts,
    .runCase = runDrainCase,
    .write_workload = writeSolveWorkload,
};

// One step of open-route requests every one of which the warm cache serves. Passes when
// linear in requests.
pub const fallback_group = suite.BenchmarkGroup{
    .name = "pathfinding-cache-open",
    .item_label = "cached path requests",
    .defaultItemCounts = fallbackDefaultItemCounts,
    .runCase = runFallbackCase,
    .write_workload = writeCacheWorkload,
};

// `pathfinding-cache-open` over the detour routes. Passes when linear in requests.
pub const fallback_detour_group = suite.BenchmarkGroup{
    .name = "pathfinding-cache-detour",
    .item_label = "cached detour path requests",
    .defaultItemCounts = fallbackDefaultItemCounts,
    .runCase = runFallbackDetourCase,
    .write_workload = writeCacheWorkload,
};

// One cold step of the hard-fallback routes at the full solve budget. Passes when linear in
// requests to the per-step ceiling and flat past it.
pub const hard_fallback_group = suite.BenchmarkGroup{
    .name = "pathfinding-hard-fallback",
    .item_label = "hard fallback path requests",
    .defaultItemCounts = fallbackDefaultItemCounts,
    .runCase = runHardFallbackCase,
    .write_workload = writeFallbackWorkload,
};

// `pathfinding-hard-fallback` with solve admissions capped at `hard_fallback_admissions` per
// step (`--fallback-budget` overrides it); the rest defer. Passes when linear in requests to
// the cap and flat past it.
pub const hard_fallback_budget_group = suite.BenchmarkGroup{
    .name = "pathfinding-hard-fallback-budget",
    .item_label = "hard fallback path requests",
    .defaultItemCounts = fallbackDefaultItemCounts,
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
    .defaultItemCounts = escalatedDetourItemCounts,
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
    .defaultItemCounts = groupFieldDetourItemCounts,
    .runCase = runGroupFieldDetourCase,
    .write_workload = writeFieldSampleWorkload,
};

// `pathfinding-group-field-detour` with the shared goal moving one new nav cell every
// `group_field_detour_rekey_period_steps` steps; times every step of the measured cycles.
// Passes when the field serves part of every run, escalated solves stay at most one per
// rekey, and the per-step time is linear in pack size.
pub const group_field_detour_moving_group = suite.BenchmarkGroup{
    .name = "pathfinding-group-field-detour-moving",
    .item_label = "pack agents",
    .defaultItemCounts = groupFieldDetourItemCounts,
    .runCase = runGroupFieldDetourMovingCase,
    .write_workload = writeFieldMovingWorkload,
};

// The moving goal advancing every step at the chase speed, its request goal re-keyed only past
// `default_goal_requantization_hysteresis_distance` (`computeRequantizedGoal`). Passes when
// rewrites stay below the measured steps, escalated solves at most one per rewrite, and the
// per-step time is linear in pack size.
pub const group_field_detour_moving_hysteresis_group = suite.BenchmarkGroup{
    .name = "pathfinding-group-field-detour-moving-hysteresis",
    .item_label = "pack agents",
    .defaultItemCounts = groupFieldDetourItemCounts,
    .runCase = runGroupFieldDetourMovingHysteresisCase,
    .write_workload = writeFieldMovingWorkload,
};

// Packs (the item count) of `group_field_pack_agents` agents on an open
// `group_field_detour_side`² level, each with its own goal marching one nav cell per rekey
// cycle, so every pack's field builds at once (one `group_field_expand` item each). Times every
// step of the measured cycles. Passes when linear in packs. `--details` prints per-field
// coverage, blocks, resident bytes, and pool growths.
pub const group_field_packs_group = suite.BenchmarkGroup{
    .name = "pathfinding-group-field-packs",
    .item_label = "packs",
    .defaultItemCounts = groupFieldPacksItemCounts,
    .runCase = runGroupFieldPacksCase,
    .write_workload = writePacksWorkload,
};

// Sparse-coverage fields: four crowds on a 1024² level whose only walkable cells are a
// lattice of 1-wide corridors every nav chunk, each flooding a field capped at the item
// count's cells. One sample rebuilds the four fields from scratch until all are ready.
// Passes when linear in the cell cap, every field covering its cap.
pub const group_field_tunnel_group = suite.BenchmarkGroup{
    .name = "pathfinding-group-field-tunnel",
    .item_label = "field cell cap",
    .defaultItemCounts = groupFieldTunnelItemCounts,
    .runCase = runGroupFieldTunnelCase,
    .write_workload = writeTunnelWorkload,
};

// Per-agent `statusForWorld` against a warm cache, each agent at its own cached path's
// midpoint, so the waypoint scan finds a deep match: the cache probe and waypoint derivation.
// The queries are read-only and fan across workers. Passes when linear in agents.
pub const query_group = suite.BenchmarkGroup{
    .name = "pathfinding-query",
    .item_label = "querying agents",
    .defaultItemCounts = queryDefaultItemCounts,
    .runCase = runQueryCase,
    .write_workload = writeQueryWorkload,
};

// Nav scaling groups over a world-backed nav. A listed config whose nav storage exceeds the
// bench's nav-size limit fails with its figure (`suite.checkNavSize`), and every config checks
// each part of the nav's bytes against its charge (`suite.checkNavBytes`). The route groups
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
//     and passes when flat in side. Layout 2 runs 16, 64, or 256 teleports at 256² and 8
//     levels and passes when every route solves at 16 and 64; the 256 point is reported, not
//     judged.
//   - `pathfinding-cross-level-shaft`: a 256² world of 8, 32, or 128 walkable levels; a ramp
//     shaft beside the starts joins levels 1 to the deepest, and level 0, which no ramp
//     reaches, holds a one-way teleport from the shaft's planar cell to beside the goals.
//     Requests go from level 1 to level 5, 48 cells east, so the routes are the same at
//     every depth and the teleport is never usable. Passes when flat in depth.
pub const level_size_group = suite.BenchmarkGroup{
    .name = "pathfinding-level-size",
    .item_label = LevelCode.label,
    .defaultItemCounts = levelSizeItemCounts,
    .runCase = runLevelSizeCase,
    .write_workload = writeRouteWorkload,
};

pub const cross_level_depth_group = suite.BenchmarkGroup{
    .name = "pathfinding-cross-level-depth",
    .item_label = CrossLevelCode.label,
    .defaultItemCounts = crossLevelItemCounts,
    .runCase = runCrossLevelDepthCase,
    .write_workload = writeRouteWorkload,
};

pub const cross_level_teleport_group = suite.BenchmarkGroup{
    .name = "pathfinding-cross-level-teleport",
    .item_label = CrossLevelCode.label,
    .defaultItemCounts = teleportItemCounts,
    .runCase = runCrossLevelTeleportCase,
    .write_workload = writeRouteWorkload,
};

pub const cross_level_shaft_group = suite.BenchmarkGroup{
    .name = "pathfinding-cross-level-shaft",
    .item_label = LevelCode.label,
    .defaultItemCounts = crossLevelItemCounts,
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
// A caps, probe, or crowd sample is one request cycle from empty runtime state: the first
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
    .defaultItemCounts = longPathItemCounts,
    .runCase = runLongPathCase,
    .write_workload = writeLongPathWorkload,
};

// A 512² world of 8 walkable levels holding random pads: bidirectional teleports from level 0
// to the deepest level placed as the teleport group's layout 2 (`LinkFoldCode`). One timed
// sample runs the post-commit nav reaction that applies a batch of 64 more pads, added to the
// world untimed. Links are append-only, so every sample (warmup included) leaves its batch in
// the world.
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
// touched chunk at a fixed background. `--details` prints the reaction's plan, patch, and
// connectivity gather shapes, the per-pad and per-pad `commit` cost, the mean endpoints per
// touched chunk, the mean pads held over the timed samples, the main-thread share, and its
// split by section.
pub const link_fold_group = suite.BenchmarkGroup{
    .name = "pathfinding-link-fold",
    .item_label = LinkFoldCode.label,
    .defaultItemCounts = linkFoldItemCounts,
    .runCase = runLinkFoldCase,
    .write_workload = writeLinkFoldWorkload,
};

// One timed dig on a 256² walkable level holding 1,000, 10,000, or 50,000 cached results
// of short paths (`EvictCode`): the cell turns blocking and the nav reaction runs, eviction
// included. The dig crosses the same few paths at every count, so it passes when flat in
// cached results. `outputs` is the results evicted. An untimed reset reopens the cell and
// re-solves the evicted results. The region configs (4, 16, or 64 chunks at 10,000 results)
// instead fill a chunk-aligned square of that many chunks in one step, crossing the routes of
// its rows: the dense-change reaction, which passes when linear in the region's chunks and
// the registrations its eviction visits. Items/s is the path-registry
// entries the eviction visited per second. `--details` prints the eviction stages' shapes,
// the reaction's main-thread time, and the entries visited.
pub const evict_group = suite.BenchmarkGroup{
    .name = "pathfinding-evict",
    .item_label = EvictCode.label,
    .defaultItemCounts = evictItemCounts,
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
    .defaultItemCounts = elasticRampItemCounts,
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
    .defaultItemCounts = elasticRampItemCounts,
    .runCase = runElasticShrinkCase,
    .write_workload = writeElasticShrinkWorkload,
};

// One step of the item count's requests from outside a sealed 80² pocket at the origin of a
// walkable 256² level, each to its own pocket goal: intake answers every request unavailable
// from reach, with no solve and nothing cached. The per-step load of unreachable requests.
// `outputs` is the requests answered unavailable. Passes when linear in requests.
pub const negative_steady_group = suite.BenchmarkGroup{
    .name = "pathfinding-negative-steady",
    .item_label = "unreachable path requests per step",
    .defaultItemCounts = negativeSteadyItemCounts,
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
    .defaultItemCounts = negativeDigItemCounts,
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
    .defaultItemCounts = negativeBurstItemCounts,
    .runCase = runNegativeBurstCase,
    .write_workload = writeBurstWorkload,
};

// One walkable level (`SplitCode`) holding, at its origin corner, solid chunks around one
// walkable gap chunk. Variant 0: a room of edge² chunks walled off by a one-chunk band whose
// one open chunk is the gap; blocking the gap seals the room. Variant 1: a one-chunk ring
// corridor around a solid block of edge² chunks, walled off from the rest of the level, with
// the gap one chunk of the ring; blocking it cuts the ring without splitting it. Variant 2: a
// one-chunk tunnel of edge chunks along the level's north border, walled below, whose east
// mouth chunk is the gap; blocking it seals the tunnel off the open level. One timed sample
// blocks the gap chunk and runs the nav reaction, then reopens it and runs the reaction again;
// the tile writes are untimed. `outputs` is the cells each change flips and `candidates` the
// room, ring, or tunnel chunks. Passes when no config grows faster than its room, ring, or
// tunnel chunks and every config is flat in side. `--details` prints the block and reopen
// reactions and the block reaction's plan, remask, patch, and connectivity shapes (the flood's
// rounds, searches per round, and its tuner's policy) with the reactions' main-thread split.
pub const connectivity_split_group = suite.BenchmarkGroup{
    .name = "pathfinding-connectivity-split",
    .item_label = SplitCode.label,
    .defaultItemCounts = connectivitySplitItemCounts,
    .runCase = runConnectivitySplitCase,
    .write_workload = writeSplitWorkload,
};

// A 256² world of 2 levels (`OnewayCode`), each a lattice of one-cell walled rooms, holding
// `systems` chains of `terminals` rooms, each room joined to the next room of its chain by a
// one-way teleport. Variants 0 and 1 toggle the first chain's last room (its last link's
// target), variant 2 its first room (its first link's source), and variant 3 a far room no
// chain uses. Variant 4 closes the chain's first `terminals - 64` rooms once, untimed (its
// block narrows), then toggles its last room. Variant 5 is a fan: every room joined by a
// one-way teleport to a hub room, the hub to the last room, which toggles, so one round
// recomputes every source's row (rows narrower than a cache line below 512 terminals).
// Variants 1 to 5 hold one chain or fan. Variant 6 (dense) holds `systems` chains of
// `oneway_dense_terminals` rooms whose heads sit side by side on level 0's last room row,
// joined into one system through the open wall cells between them; the timed block reaction
// fills every such wall cell (the system splits into `systems`) and the reopen opens them (one
// dense opening merges them), its blocks resizing. Variant 7 adds to variant 0's chains a
// ballast chain on level 1 whose block holds over twice the chains' live words; before every
// sample, untimed and with the nav tuners restored after, the ballast reopens (its one block
// lands in that reaction) and then every ballast room closes (its block is freed in that
// reaction), and the nav's bytes are checked. Its timed block and reopen reactions must land,
// allocate, and free no block and leave the batch tail's capacity as it was. The toggled end's
// 8 rooms sit in one fixed chunk whose orthogonal neighbours hold no other chain room, so every
// config's toggle patches the same chunks. One timed sample blocks the cell and runs the nav
// reaction, then reopens it and runs the reaction again; the tile writes are untimed.
// `outputs` is the one-way links and `candidates` the rooms. Passes when variants 0, 3, and 4
// are flat (4 in its peak terminals), variant 2 grows at most linearly in terminals, variants 1
// and 5 at most as terminals² / 32, and variant 6 at most as its merged system's rows,
// (systems x terminals)² / 32; its block resizes and reserve ratio are reported, not checked,
// since its fill and reopen resize blocks by design. Variant 7 passes when its timed block reaction, that reaction's reserve section,
// and its closure stages are flat in systems; the ballast's own landing and free follow its
// block alone. `--details` as for `pathfinding-connectivity-split`, plus variant 7's ballast
// retire (the reopen's landing and tail use, the close's free) and the split of its timed
// block reaction (reserve, closure stages, landing, rest).
pub const connectivity_oneway_group = suite.BenchmarkGroup{
    .name = "pathfinding-connectivity-oneway",
    .item_label = OnewayCode.label,
    .defaultItemCounts = connectivityOnewayItemCounts,
    .runCase = runConnectivityOnewayCase,
    .write_workload = writeOnewayWorkload,
};

// Cold solve counts: three below the per-step solve ceiling, the ceiling, and three past it,
// so both regimes show their shape.
const cold_solve_quick_counts = [_]usize{ 128, 256, 384, 512, 1024, 2048, 4096 };
const cold_solve_standard_counts = [_]usize{ 128, 256, 384, 512, 1024, 4096, 8192 };
const cold_solve_stress_counts = [_]usize{ 128, 256, 384, 512, 2048, 4096, 8192 };
const shared_goal_quick_counts = [_]usize{ 128, 512, 2048 };
const shared_goal_standard_counts = [_]usize{ 512, 2048, 8192 };
const shared_goal_stress_counts = [_]usize{ 2048, 8192, 32768 };
// Queue depths past the ceiling, so every drain step solves a full ceiling.
const drain_quick_counts = [_]usize{ 1024, 2048, 4096 };
const drain_standard_counts = [_]usize{ 1024, 4096, 16384 };
const drain_stress_counts = [_]usize{ 2048, 8192, 16384 };
const fallback_quick_counts = [_]usize{ 16, 64, 128 };
const fallback_standard_counts = [_]usize{ 64, 128, 256, 1024 };
const fallback_stress_counts = [_]usize{ 256, 512, 1024 };
const query_quick_counts = [_]usize{ 256, 1024, 4096 };
const query_standard_counts = [_]usize{ 1024, 4096, 16384 };
const query_stress_counts = [_]usize{ 2048, 8192, 16384 };
// Level sides, in whole chunks, up to the largest whose detour the fixed tier-1 budget solves.
const escalated_detour_quick_counts = [_]usize{ 64, 128, 256 };
const escalated_detour_standard_counts = [_]usize{ 128, 256, 512 };
const escalated_detour_stress_counts = [_]usize{ 128, 256, 512 };
// Pack sizes.
const group_field_detour_quick_counts = [_]usize{ 16, 64, 256 };
const group_field_detour_standard_counts = [_]usize{ 16, 64, 256 };
const group_field_detour_stress_counts = [_]usize{ 64, 256, 1024 };
const group_field_packs_item_counts = [_]usize{ 1, 4, 16 };
const group_field_tunnel_item_counts = [_]usize{ 2048, 16384, 65536 };

// A cold step re-solves up to the per-step ceiling, so the cold groups take fewer samples
// than the suite's defaults; a smaller `--warmup`/`--iterations` still wins.
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

fn coldSolveItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &cold_solve_quick_counts,
        .standard => &cold_solve_standard_counts,
        .stress => &cold_solve_stress_counts,
    };
}

fn sharedGoalItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &shared_goal_quick_counts,
        .standard => &shared_goal_standard_counts,
        .stress => &shared_goal_stress_counts,
    };
}

fn drainItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &drain_quick_counts,
        .standard => &drain_standard_counts,
        .stress => &drain_stress_counts,
    };
}

fn fallbackDefaultItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &fallback_quick_counts,
        .standard => &fallback_standard_counts,
        .stress => &fallback_stress_counts,
    };
}

fn queryDefaultItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &query_quick_counts,
        .standard => &query_standard_counts,
        .stress => &query_stress_counts,
    };
}

fn escalatedDetourItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &escalated_detour_quick_counts,
        .standard => &escalated_detour_standard_counts,
        .stress => &escalated_detour_stress_counts,
    };
}

fn groupFieldDetourItemCounts(profile: suite.Profile) []const usize {
    return switch (profile) {
        .quick => &group_field_detour_quick_counts,
        .standard => &group_field_detour_standard_counts,
        .stress => &group_field_detour_stress_counts,
    };
}

fn groupFieldPacksItemCounts(_: suite.Profile) []const usize {
    return &group_field_packs_item_counts;
}

fn groupFieldTunnelItemCounts(_: suite.Profile) []const usize {
    return &group_field_tunnel_item_counts;
}

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

fn writeQueryWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("warm_paths={} queries={}", .{ stats.candidate_pairs, stats.output_count });
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
fn initRequestFixture(allocator: std.mem.Allocator, io: std.Io, workload: Workload, count: usize, capacity: PathfindingCapacity, thread_system: ?*ThreadSystem) !RouteFixture {
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
    return runWorkloadCase(allocator, io, options, case, group.name, item_count, .unique_open, .cold_solve, item_count, item_count);
}

// Every request shares one goal: all but the first fold into its pending entry, so a cold
// step is one solve. Items/s is requests answered, not solves.
fn runDedupCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    // The field threshold above every sharer count (the agent ceiling clamps it), so the
    // timed step is the fold alone, never a group-field begin.
    var capacity = requestCapacity(item_count + 1, fixtures.participantCount(thread_ptr));
    capacity.min_group_field_agents = item_count + 1;
    var fixture = try initRequestFixture(allocator, io, .common_goal, item_count, capacity, thread_ptr);
    defer fixture.deinit();
    const system = &fixture.system;
    setPathStageTuners(system, case);

    for (0..1 + coldWarmup(options)) |_| {
        system.clearRuntimeState();
        _ = try runColdOnce(system, &fixture.requests, thread_ptr, case, item_count, item_count, item_count);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = coldSettleLimit(options);
        while (!system.tuners.solve.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            system.clearRuntimeState();
            _ = try runColdOnce(system, &fixture.requests, thread_ptr, case, item_count, item_count, item_count);
        }
    }
    const settled = if (case.adaptive) system.tuners.solve.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    for (0..coldIterations(options)) |_| {
        system.clearRuntimeState();
        const start_ns = suite.nowNs(io);
        last_stats = try runColdOnce(system, &fixture.requests, thread_ptr, case, item_count, item_count, item_count);
        accumulator.record(suite.elapsedNs(start_ns, suite.nowNs(io)), last_stats.solve_batch);
        if (last_stats.group_field_begin_batch.item_count != 0 or last_stats.group_fields_built != 0) return error.SharedGoalBeganField;
    }
    if (last_stats.solve_admissions != 1) return error.SharedGoalNotOneSolve;
    var stats = accumulator.finish();
    stats.output_count = last_stats.available_results + last_stats.unavailable_results + last_stats.duplicate_requests + last_stats.cache_hits;
    stats.candidate_pairs = last_stats.duplicate_requests + last_stats.cache_hits;
    stats.items_per_second = suite.itemsPerSecond(stats.output_count, stats.mean_ns);
    if (case.adaptive) stats.work_tuning = suite.workTuningSummary(system.tuners.solve.report(), settled);
    return stats;
}

fn runFallbackCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runWorkloadCase(allocator, io, options, case, fallback_group.name, item_count, .unique_open, .hot_cache, item_count, item_count);
}

fn runFallbackDetourCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runWorkloadCase(allocator, io, options, case, fallback_detour_group.name, item_count, .blocked_detour, .hot_cache, item_count, item_count);
}

fn runHardFallbackCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runWorkloadCase(allocator, io, options, case, hard_fallback_group.name, item_count, .hard_fallback, .cold_fallback, item_count, item_count);
}

fn runHardFallbackBudgetCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    const fallback_budget = @min(options.fallback_budget orelse hard_fallback_admissions, item_count);
    return runWorkloadCase(allocator, io, options, case, hard_fallback_budget_group.name, item_count, .hard_fallback, .cold_fallback, item_count, fallback_budget);
}

// Admissions per step of the hard-fallback-budget case: a window narrower than its solve
// window, so the admission limit defers the rest.
const hard_fallback_admissions: usize = 128;

fn runWorkloadCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, group_name: []const u8, item_count: usize, workload: Workload, mode: MeasurementMode, solve_budget: usize, fallback_budget: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    var fixture = try initRequestFixture(allocator, io, workload, item_count, requestCapacity(item_count, fixtures.participantCount(thread_ptr)), thread_ptr);
    defer fixture.deinit();
    const system = &fixture.system;
    setPathStageTuners(system, case);

    system.clearRuntimeState();
    _ = try runColdOnce(system, &fixture.requests, thread_ptr, case, item_count, solve_budget, fallback_budget);
    if (mode == .hot_cache) try warmHotCache(system, &fixture.requests, thread_ptr, options, case, item_count);

    const warmup_count = if (mode.isCold()) coldWarmup(options) else options.warmup_iterations;
    const measure_count = if (mode.isCold()) coldIterations(options) else options.iterations;
    for (0..warmup_count) |_| {
        if (mode.isCold()) system.clearRuntimeState();
        _ = try runColdOnce(system, &fixture.requests, thread_ptr, case, item_count, solve_budget, fallback_budget);
    }
    if (case.adaptive and mode.isCold()) {
        var settle_guard: usize = 0;
        const settle_limit = coldSettleLimit(options);
        while (!system.tuners.solve.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            system.clearRuntimeState();
            _ = try runColdOnce(system, &fixture.requests, thread_ptr, case, item_count, solve_budget, fallback_budget);
        }
    }
    const settled_before_measurement = if (case.adaptive) system.tuners.solve.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    var stage_report = StageReport{};
    for (0..measure_count) |_| {
        if (mode.isCold()) system.clearRuntimeState();
        const start_ns = suite.nowNs(io);
        last_stats = try runColdOnce(system, &fixture.requests, thread_ptr, case, item_count, solve_budget, fallback_budget);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.solve_batch);
        stage_report.add(suite.elapsedNs(start_ns, end_ns), last_stats);
    }
    stage_report.print(options, group_name, item_count, case);
    // Every route exists and starts open.
    if (last_stats.unavailable_results != 0) return error.RouteUnavailable;

    var stats = accumulator.finish();
    stats.output_count = last_stats.available_results;
    stats.deferred_count = last_stats.pending_requests;
    stats.fallback_deferred_count = last_stats.admission_deferred_requests;
    stats.cache_evictions = last_stats.cache_evictions;
    // Throughput counts what the step serviced: cache hits when warm, admissions when cold
    // at the admission window, published results when cold; the per-step ceiling defers the
    // rest.
    const serviced: usize = switch (mode) {
        .hot_cache => last_stats.cache_hits,
        .cold_fallback => last_stats.solve_admissions,
        .cold_solve => last_stats.available_results,
    };
    stats.candidate_pairs = serviced;
    switch (mode) {
        .hot_cache => if (serviced != item_count) return error.HotCacheMissed,
        .cold_fallback => if (serviced != @min(item_count, fallback_budget, default_max_solves_per_frame)) return error.FallbackAdmissionsDrifted,
        // A solve may exhaust its budget and defer, so results are bounded by the ceiling.
        .cold_solve => if (serviced > @min(item_count, solve_budget, default_max_solves_per_frame)) return error.SolvesPastCeiling,
    }
    stats.items_per_second = suite.itemsPerSecond(serviced, stats.mean_ns);
    if (case.adaptive and mode.isCold()) {
        stats.work_tuning = suite.workTuningSummary(system.tuners.solve.report(), settled_before_measurement);
    }
    return stats;
}

// A drain step: the queue accepted untimed (`refillDrainQueue`), each timed step solving the
// carried queue's front at the per-step ceiling over an empty stream.
fn runDrainCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    // The refill step solves one ceiling; a full-ceiling drain step needs another behind it.
    if (item_count < 2 * default_max_solves_per_frame) return error.DrainQueueBelowTwoCeilings;
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    var fixture = try initRequestFixture(allocator, io, .unique_open, item_count, requestCapacity(item_count, fixtures.participantCount(thread_ptr)), thread_ptr);
    defer fixture.deinit();
    const system = &fixture.system;
    setPathStageTuners(system, case);
    var empty = RangeOutputStream(PathRequest).init(allocator);
    defer empty.deinit();

    // A healthy queue empties in ceil(N / ceiling) steps; past that a cycle stops.
    const drain_step_limit = suite.rangeCount(item_count, default_max_solves_per_frame) + 2;
    const drain_samples = coldIterations(options);
    for (0..@max(@as(usize, 1), coldWarmup(options))) |_| {
        try refillDrainQueue(system, &fixture.requests, thread_ptr, case, item_count);
        var guard: usize = drain_step_limit;
        while (system.pending.len > 0 and guard > 0) : (guard -= 1) {
            const before = system.pending.len;
            _ = try runColdOnce(system, &empty, thread_ptr, case, item_count, item_count, item_count);
            if (system.pending.len >= before) return error.DrainStalled;
        }
    }

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
            accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.solve_batch);
            stage_report.add(suite.elapsedNs(start_ns, end_ns), last_stats);
            if (system.pending.len >= before) return error.DrainStalled;
        }
    }
    stage_report.print(options, drain_group.name, item_count, case);

    var stats = accumulator.finish();
    stats.output_count = last_stats.available_results + last_stats.unavailable_results;
    stats.candidate_pairs = last_stats.solved_requests;
    stats.deferred_count = last_stats.pending_requests;
    stats.items_per_second = suite.itemsPerSecond(last_stats.solved_requests, stats.mean_ns);
    if (case.adaptive) stats.work_tuning = suite.workTuningSummary(system.tuners.solve.report(), false);
    return stats;
}

// Clears the runtime state and accepts every distinct goal in one step, which also solves
// the first ceiling; the queue carries the rest.
fn refillDrainQueue(system: *PathfindingSystem, requests: *RangeOutputStream(PathRequest), thread_system: ?*ThreadSystem, case: suite.BenchmarkCase, agent_count: usize) !void {
    system.clearRuntimeState();
    _ = try runColdOnce(system, requests, thread_system, case, agent_count, agent_count, agent_count);
}

// Steps until every request is a cache hit and, for an adaptive case, the intake tuner has
// settled (bounded), so the timed steps are the hit path only.
fn warmHotCache(system: *PathfindingSystem, requests: *RangeOutputStream(PathRequest), thread_system: ?*ThreadSystem, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !void {
    const fill_limit = suite.rangeCount(item_count, default_max_solves_per_frame) + 2;
    const settle_limit = fill_limit + suite.adaptiveSettleIterationLimit(options);
    var steps: usize = 0;
    while (true) {
        const stats = try runColdOnce(system, requests, thread_system, case, item_count, item_count, item_count);
        steps += 1;
        const all_hits = stats.cache_hits == item_count;
        if (!all_hits and steps > fill_limit) return error.HotCacheNotWarm;
        const tuner_ready = !case.adaptive or system.tuners.intake.isSettled() or steps >= settle_limit;
        if (all_hits and tuner_ready) return;
    }
}

fn runColdOnce(system: *PathfindingSystem, requests: *RangeOutputStream(PathRequest), thread_system: ?*ThreadSystem, case: suite.BenchmarkCase, agent_count: usize, solve_budget: usize, fallback_budget: usize) !PathfindingStats {
    if (!case.usesThreadSystem()) {
        return try system.updateSerial(requests, agent_count, .{
            .max_solved_requests_per_step = solve_budget,
            .max_solve_admissions_per_step = fallback_budget,
        });
    }
    return try system.update(requests, agent_count, thread_system.?, .{
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
        .max_solved_requests_per_step = solve_budget,
        .max_solve_admissions_per_step = fallback_budget,
    });
}

// Gives every pathfinding update stage this case's tuner, as the solve batch gets its own.
fn setPathStageTuners(system: *PathfindingSystem, case: suite.BenchmarkCase) void {
    if (suite.adaptiveTunerForCase(case, pathfinding_range_alignment_items)) |tuner| system.tuners.solve = tuner;
    if (suite.adaptiveTunerForCase(case, intake_range_alignment_items)) |tuner| system.tuners.intake = tuner;
    if (suite.adaptiveTunerForCase(case, 1)) |tuner| system.tuners.group_field = tuner;
    if (suite.adaptiveTunerForCase(case, 1)) |tuner| system.tuners.group_field_begin = tuner;
    if (suite.adaptiveTunerForCase(case, 1)) |tuner| system.tuners.group_field_stall = tuner;
    if (suite.adaptiveTunerForCase(case, 1)) |tuner| system.tuners.publish_copy = tuner;
    if (suite.adaptiveTunerForCase(case, 1)) |tuner| system.tuners.registry_flush = tuner;
    if (suite.adaptiveTunerForCase(case, 1)) |tuner| system.tuners.resize_copy = tuner;
    if (suite.adaptiveTunerForCase(case, goal_scan_range_alignment_items)) |tuner| system.tuners.goal_scan = tuner;
    if (suite.adaptiveTunerForCase(case, goal_project_range_alignment_items)) |tuner| system.tuners.goal_project = tuner;
}

// The case's goal resolve over `intents`, as the pipeline's `path_goal_resolve` stage.
fn runResolveGoals(system: *PathfindingSystem, intents: []const PathRequest, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase) !GoalResolveStats {
    if (!case.usesThreadSystem()) return system.resolveGoals(PathRequest, intents, null, .{});
    return system.resolveGoals(PathRequest, intents, thread_system.?, .{
        .items_per_range = case.itemsPerRange(goal_scan_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

// An update's stage batches, in `StageReport` order.
fn updateBatches(stats: PathfindingStats) [update_stage_count]BatchStats {
    return .{ stats.intake_batch, stats.group_field_batch, stats.group_field_begin_batch, stats.solve_batch, stats.publish_copy_batch, stats.registry_flush_batch, stats.resize_copy_batch };
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
const StageReport = struct {
    main_ns: u128 = 0,
    timed_ns: u128 = 0,
    samples: usize = 0,
    // Main-thread time per update phase: the phase timer minus its stages' worker time.
    accept_main_ns: u128 = 0,
    group_main_ns: u128 = 0,
    solve_main_ns: u128 = 0,
    publish_ns: u128 = 0,
    // Intake, group-field advance, group-field begin, solve, publish copy, registry flush,
    // resize copy.
    shapes: suite.StageShapes(update_stage_count) = .{},
    // Route groups that count unsolved routes: the last timed step's outcome.
    routes: ?RouteOutcome = null,
    // Path-registry entries the timed updates added and removed.
    registrations_added: usize = 0,
    registrations_removed: usize = 0,
    // Requests and solves the timed updates answered unavailable from reach, and blocked
    // goals intake projected itself.
    unavailable: usize = 0,
    goal_fallbacks: usize = 0,

    fn add(self: *StageReport, elapsed_ns: u64, stats: PathfindingStats) void {
        self.samples += 1;
        self.timed_ns += elapsed_ns;
        self.main_ns += elapsed_ns -| offMainStageNs(stats);
        self.accept_main_ns += stats.accept_ns -| offMainNs(stats.intake_batch);
        self.group_main_ns += stats.group_service_ns -| (offMainNs(stats.group_field_batch) + offMainNs(stats.group_field_begin_batch));
        self.solve_main_ns += stats.solve_ns -| offMainNs(stats.solve_batch);
        self.publish_ns += stats.publish_ns -| offMainNs(stats.publish_copy_batch);
        self.registrations_added += stats.registrations_added;
        self.registrations_removed += stats.registrations_removed;
        self.unavailable += stats.unavailable_results;
        self.goal_fallbacks += stats.goal_fallbacks;
        self.shapes.add(updateBatches(stats));
    }

    fn print(self: StageReport, options: suite.Options, group_name: []const u8, item_count: usize, case: suite.BenchmarkCase) void {
        if (!options.details or self.timed_ns == 0) return;
        var buffers: [update_stage_count][48]u8 = undefined;
        var labels: [update_stage_count][]const u8 = undefined;
        for (&buffers, &labels, 0..) |*buffer, *label, index| label.* = self.shapes.label(index, buffer);
        const samples: u128 = self.samples * std.time.ns_per_us;
        std.debug.print("  {s} {} {s}: intake={s} group_field={s}/{s} solve={s} publish_copy={s} registry_flush={s} resize_copy={s} main={}us ({}%) main_phases accept={}us group={}us solve={}us publish={}us", .{
            group_name,
            item_count,
            case.name,
            labels[0],
            labels[1],
            labels[2],
            labels[3],
            labels[4],
            labels[5],
            labels[6],
            @as(u64, @intCast(self.main_ns / self.samples / std.time.ns_per_us)),
            @as(u64, @intCast(self.main_ns * 100 / self.timed_ns)),
            @as(u64, @intCast(self.accept_main_ns / samples)),
            @as(u64, @intCast(self.group_main_ns / samples)),
            @as(u64, @intCast(self.solve_main_ns / samples)),
            @as(u64, @intCast(self.publish_ns / samples)),
        });
        if (self.routes) |routes| std.debug.print(" routes solved={} unsolved={}", .{ routes.solved, routes.unsolved });
        std.debug.print(" registrations +{}/-{} per update", .{ self.registrations_added / self.samples, self.registrations_removed / self.samples });
        if (self.unavailable + self.goal_fallbacks != 0) {
            std.debug.print(" unavailable={} goal_fallbacks={} per update", .{
                self.unavailable / self.samples,
                self.goal_fallbacks / self.samples,
            });
        }
        std.debug.print("\n", .{});
    }
};

fn benchmarkItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(pathfinding_range_alignment_items) orelse
        std.mem.alignForwardAnyAlign(usize, suite.default_items_per_range, pathfinding_range_alignment_items);
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
    return inlineBatch(item_count, pathfinding_range_alignment_items);
}

// Per-agent statusForWorld against a warm cache: each agent queries from the midpoint of
// its own cached path, so the waypoint scan has a deep match to find.
fn runQueryCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    var fixture = try initRequestFixture(allocator, io, .unique_open, item_count, requestCapacity(item_count, fixtures.participantCount(thread_ptr)), thread_ptr);
    defer fixture.deinit();
    const system = &fixture.system;

    // Warm: the per-step solve ceiling caps each step, so enough steps drain the queue.
    const warm_steps = item_count / default_max_solves_per_frame + 4;
    for (0..warm_steps) |_| _ = try system.updateSerial(&fixture.requests, item_count, .{});

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
    // Warmup also settles each agent's hint to its midpoint index.
    for (0..options.warmup_iterations) |_| _ = runQueries(&context, thread_ptr, case, item_count);

    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const batch = runQueries(&context, thread_ptr, case, item_count);
        accumulator.record(suite.elapsedNs(start_ns, suite.nowNs(io)), batch);
    }
    var stats = accumulator.finish();
    stats.output_count = item_count;
    stats.candidate_pairs = warm_paths;
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
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
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

    for (0..coldWarmup(options)) |_| {
        try promoteDetour(system, &fixture.requests, thread_ptr, case);
        _ = try runColdOnce(system, &empty, thread_ptr, case, 1, 1, 1);
    }
    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    for (0..coldIterations(options)) |_| {
        try promoteDetour(system, &fixture.requests, thread_ptr, case);
        const start_ns = suite.nowNs(io);
        last_stats = try runColdOnce(system, &empty, thread_ptr, case, 1, 1, 1);
        accumulator.record(suite.elapsedNs(start_ns, suite.nowNs(io)), last_stats.solve_batch);
    }
    // The fixed tier-1 budget solves the detour; a second exhaustion would drop it.
    if (last_stats.available_results != 1 or last_stats.escalated_solves != 1) return error.EscalatedDetourUnsolved;
    var stats = accumulator.finish();
    stats.output_count = last_stats.available_results;
    stats.candidate_pairs = last_stats.solved_requests;
    stats.items_per_second = suite.itemsPerSecond(stats.output_count, stats.mean_ns);
    return stats;
}

// The untimed setup step: submits the request on cleared state and exhausts its first
// attempt, leaving it pending at tier 1.
fn promoteDetour(system: *PathfindingSystem, requests: *RangeOutputStream(PathRequest), thread_system: ?*ThreadSystem, case: suite.BenchmarkCase) !void {
    system.clearRuntimeState();
    const stats = try runColdOnce(system, requests, thread_system, case, 1, 1, 1);
    if (stats.budget_exhausted != 1 or system.pending.len != 1 or system.pending.at(0).tier != 1) return error.EscalatedDetourNotPromoted;
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

fn initPackFixture(allocator: std.mem.Allocator, io: std.Io, agent_count: usize, capacity: PathfindingCapacity, thread_system: ?*ThreadSystem) !PackFixture {
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
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    var fixture = try initPackFixture(allocator, io, item_count, packCapacity(item_count, fixtures.participantCount(thread_ptr)), thread_ptr);
    defer fixture.deinit(allocator);
    const system = &fixture.system;
    setPathStageTuners(system, case);
    try writePackRequests(allocator, &fixture.stream, &fixture.scratch, &fixture.open, fixture.entities, fixture.open.cellCenter(packGoal(group_field_detour_side, 0)));

    var last_stats = PathfindingStats{};
    var guard: usize = group_field_detour_setup_guard;
    while (guard > 0 and last_stats.group_field_samples < item_count) : (guard -= 1) {
        last_stats = try runColdOnce(system, &fixture.stream, thread_ptr, case, item_count, item_count, item_count);
    }
    if (last_stats.group_field_samples != item_count) return error.GroupFieldNotReady;
    for (0..options.warmup_iterations) |_| _ = try runColdOnce(system, &fixture.stream, thread_ptr, case, item_count, item_count, item_count);

    var accumulator = suite.StatsAccumulator.init(item_count);
    var stage_report = StageReport{};
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_stats = try runColdOnce(system, &fixture.stream, thread_ptr, case, item_count, item_count, item_count);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        accumulator.record(elapsed_ns, last_stats.solve_batch);
        stage_report.add(elapsed_ns, last_stats);
        // A ready field answers every member: no build, no per-agent solve.
        if (last_stats.group_fields_built != 0 or last_stats.group_field_samples != item_count) return error.GroupFieldNotSampled;
    }
    stage_report.print(options, group_field_detour_group.name, item_count, case);

    var stats = accumulator.finish();
    stats.output_count = last_stats.duplicate_requests;
    stats.candidate_pairs = last_stats.group_field_samples;
    stats.items_per_second = suite.itemsPerSecond(item_count, stats.mean_ns);
    return stats;
}

// The moving groups' measured totals.
const MovingTotals = struct {
    escalated: usize = 0,
    throttled: usize = 0,
    built: usize = 0,
    samples: usize = 0,

    fn add(self: *MovingTotals, stats: PathfindingStats) void {
        self.escalated += stats.escalated_solves;
        self.throttled += stats.group_field_rebuild_throttled;
        self.built += stats.group_fields_built;
        self.samples += stats.group_field_samples;
    }

    fn into(self: MovingTotals, stats: *suite.RunStats) void {
        stats.output_count = self.escalated;
        stats.candidate_pairs = self.throttled;
        stats.deferred_count = self.built;
        stats.sample_count = self.samples;
    }
};

// A moving shared goal at the chase cadence: each cycle re-keys the pack's goal to a nav cell
// no earlier cycle targeted (a strict march, so no cycle rides an earlier cached result), then
// steps the rekey period. The first request for a new goal is always one bounded solve (the
// field cannot be ready for it yet); the throttle must let the field serve the rest.
fn runGroupFieldDetourMovingCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    // Fixed cycle counts: --warmup and --iterations do not apply.
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    var fixture = try initPackFixture(allocator, io, item_count, packCapacity(item_count, fixtures.participantCount(thread_ptr)), thread_ptr);
    defer fixture.deinit(allocator);
    const system = &fixture.system;
    setPathStageTuners(system, case);

    var totals = MovingTotals{};
    var accumulator = suite.StatsAccumulator.init(item_count);
    var stage_report = StageReport{};
    for (0..group_field_detour_moving_warmup_cycles + group_field_detour_moving_cycles) |cycle| {
        try writePackRequests(allocator, &fixture.stream, &fixture.scratch, &fixture.open, fixture.entities, fixture.open.cellCenter(packGoal(group_field_detour_side, cycle)));
        const measured = cycle >= group_field_detour_moving_warmup_cycles;
        for (0..group_field_detour_rekey_period_steps) |_| {
            const start_ns = suite.nowNs(io);
            const stats = try runColdOnce(system, &fixture.stream, thread_ptr, case, item_count, item_count, item_count);
            const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
            if (!measured) continue;
            accumulator.record(elapsed_ns, stats.solve_batch);
            stage_report.add(elapsed_ns, stats);
            totals.add(stats);
        }
    }
    stage_report.print(options, group_field_detour_moving_group.name, item_count, case);
    // The throttle lets the field reach ready and serve part of the run; escalated solves stay
    // at one per rekey.
    if (totals.samples == 0) return error.GroupFieldNeverSampled;
    if (totals.escalated > group_field_detour_moving_cycles) return error.GroupFieldEscalationsPastRekeys;
    var stats = accumulator.finish();
    totals.into(&stats);
    return stats;
}

// The live goal advancing every step at the chase speed (one nav cell per rekey period), the
// request goal re-keyed only past the AI's requantization hysteresis
// (`computeRequantizedGoal`, the function `AiSystem.requantizeGoal` wraps).
fn runGroupFieldDetourMovingHysteresisCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    // Fixed cycle counts: --warmup and --iterations do not apply.
    _ = options;
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    var fixture = try initPackFixture(allocator, io, item_count, packCapacity(item_count, fixtures.participantCount(thread_ptr)), thread_ptr);
    defer fixture.deinit(allocator);
    const system = &fixture.system;
    setPathStageTuners(system, case);

    const start_goal = fixture.open.cellCenter(packGoal(group_field_detour_side, 0));
    const px_per_step: f32 = fixture.open.world.tile_size / @as(f32, @floatFromInt(group_field_detour_rekey_period_steps));
    var snapped_goal = start_goal;
    var snapped_initialized = false;
    var last_written_goal: ?math.Vec2 = null;
    // Goal rewrites past the hysteresis over the measured steps.
    var rewrite_count: usize = 0;
    const total_steps = (group_field_detour_moving_warmup_cycles + group_field_detour_moving_cycles) * group_field_detour_rekey_period_steps;
    const warmup_steps = group_field_detour_moving_warmup_cycles * group_field_detour_rekey_period_steps;

    var totals = MovingTotals{};
    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..total_steps) |step_index| {
        const live = math.Vec2{ .x = start_goal.x, .y = start_goal.y - @as(f32, @floatFromInt(step_index)) * px_per_step };
        const requantized = computeRequantizedGoal(
            AiDir{ .x = snapped_goal.x, .y = snapped_goal.y },
            snapped_initialized,
            AiDir{ .x = live.x, .y = live.y },
            default_goal_requantization_hysteresis_distance,
        );
        snapped_goal = .{ .x = requantized.goal.x, .y = requantized.goal.y };
        snapped_initialized = requantized.initialized;
        const measured = step_index >= warmup_steps;
        if (last_written_goal == null or last_written_goal.?.x != snapped_goal.x or last_written_goal.?.y != snapped_goal.y) {
            try writePackRequests(allocator, &fixture.stream, &fixture.scratch, &fixture.open, fixture.entities, snapped_goal);
            last_written_goal = snapped_goal;
            if (measured) rewrite_count += 1;
        }
        const start_ns = suite.nowNs(io);
        const stats = try runColdOnce(system, &fixture.stream, thread_ptr, case, item_count, item_count, item_count);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        if (!measured) continue;
        accumulator.record(elapsed_ns, stats.solve_batch);
        totals.add(stats);
    }
    // The field still serves part of the run; escalated solves follow the hysteresis-reduced
    // rewrites, which stay below the per-step count.
    if (totals.samples == 0) return error.GroupFieldNeverSampled;
    if (rewrite_count >= total_steps - warmup_steps) return error.GroupFieldRewroteEveryStep;
    if (totals.escalated > rewrite_count) return error.GroupFieldEscalationsPastRewrites;
    var stats = accumulator.finish();
    totals.into(&stats);
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

fn runGroupFieldPacksCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const packs = item_count;
    if (packs == 0 or group_field_pack_side / packs < group_field_pack_band_min) return error.GroupFieldPacksTooMany;
    const agent_count = packs * group_field_pack_agents;
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;

    var open = try buildOpenWorld(allocator, io, group_field_pack_side, 1);
    defer open.world.deinit();
    var data = DataSystem.init(allocator);
    defer data.deinit();
    const entities = try allocator.alloc(EntityId, agent_count);
    defer allocator.free(entities);
    for (entities) |*entity| entity.* = try data.createEntity();
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    var capacity = packCapacity(agent_count, fixtures.participantCount(thread_ptr));
    capacity.max_group_fields = packs;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &open.world, thread_ptr);
    setPathStageTuners(&system, case);

    var stream = RangeOutputStream(PathRequest).init(allocator);
    defer stream.deinit();
    var scratch: std.ArrayList(PathRequest) = .empty;
    defer scratch.deinit(allocator);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var stage_report = StageReport{};
    var built_total: usize = 0;
    var samples_total: usize = 0;
    for (0..group_field_detour_moving_warmup_cycles + group_field_detour_moving_cycles) |cycle| {
        try writeGroupFieldPackRequests(allocator, &stream, &scratch, &open, entities, packs, cycle);
        const measured = cycle >= group_field_detour_moving_warmup_cycles;
        for (0..group_field_detour_rekey_period_steps) |_| {
            const start_ns = suite.nowNs(io);
            const stats = try runColdOnce(&system, &stream, thread_ptr, case, agent_count, agent_count, agent_count);
            const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
            if (!measured) continue;
            accumulator.record(elapsed_ns, stats.group_field_batch);
            stage_report.add(elapsed_ns, stats);
            built_total += stats.group_fields_built;
            samples_total += stats.group_field_samples;
        }
    }
    stage_report.print(options, group_field_packs_group.name, item_count, case);
    printFieldMemory(options, group_field_packs_group.name, item_count, case, &system);
    // Every pack's field builds each rekey and is sampled.
    if (built_total < packs * group_field_detour_moving_cycles or samples_total == 0) return error.GroupFieldPacksNotEngaged;

    var stats = accumulator.finish();
    stats.output_count = built_total;
    stats.candidate_pairs = samples_total;
    stats.items_per_second = suite.itemsPerSecond(built_total, stats.mean_ns *| stats.iterations);
    return stats;
}

// Per-field coverage and memory of a system's fields, averaged over the built fields.
fn printFieldMemory(options: suite.Options, group_name: []const u8, item_count: usize, case: suite.BenchmarkCase, system: *const PathfindingSystem) void {
    if (!options.details) return;
    var fields: usize = 0;
    var covered: usize = 0;
    var blocks: usize = 0;
    var resident: usize = 0;
    for (system.group_fields.items) |*field| {
        if (field.state == .empty) continue;
        fields += 1;
        covered += field.pushed_count;
        blocks += field.used_blocks;
        resident += field.residentBytes();
    }
    if (fields == 0) return;
    std.debug.print("  {s} {} {s}: fields={} per_field covered={} blocks={} resident={}B bytes_per_cell={} pool_grows={} pool_failures={}\n", .{
        group_name,
        item_count,
        case.name,
        fields,
        covered / fields,
        blocks / fields,
        resident / fields,
        resident / @max(@as(usize, 1), covered),
        system.group_field_pool_growth.count,
        system.group_field_pool_failure.count,
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

// Rebuilds the four fields from scratch (pools kept) until all are ready; times the steps.
fn buildTunnelFields(io: std.Io, system: *PathfindingSystem, requests: *RangeOutputStream(PathRequest), thread_system: ?*ThreadSystem, case: suite.BenchmarkCase, agent_count: usize) !struct { elapsed_ns: u64, batch: BatchStats } {
    system.clearRuntimeState();
    var elapsed_ns: u64 = 0;
    var batch = BatchStats{};
    for (0..group_field_tunnel_build_guard) |_| {
        const start_ns = suite.nowNs(io);
        const stats = try runColdOnce(system, requests, thread_system, case, agent_count, agent_count, agent_count);
        elapsed_ns += suite.elapsedNs(start_ns, suite.nowNs(io));
        if (stats.group_field_begin_batch.item_count > batch.item_count) batch = stats.group_field_begin_batch;
        if (stats.group_field_batch.item_count > batch.item_count) batch = stats.group_field_batch;
        var ready: usize = 0;
        for (system.group_fields.items) |field| ready += @intFromBool(field.state == .ready);
        if (ready == group_field_tunnel_fields) return .{ .elapsed_ns = elapsed_ns, .batch = batch };
    }
    return error.GroupFieldTunnelBuildStalled;
}

fn runGroupFieldTunnelCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const agent_count = group_field_tunnel_fields * group_field_tunnel_agents;
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;

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
    setPathStageTuners(system, case);

    for (0..coldWarmup(options)) |_| _ = try buildTunnelFields(io, system, &fixture.requests, thread_ptr, case, agent_count);
    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..@max(@as(usize, 1), coldIterations(options))) |_| {
        const built = try buildTunnelFields(io, system, &fixture.requests, thread_ptr, case, agent_count);
        accumulator.record(built.elapsed_ns, built.batch);
    }
    var covered: usize = 0;
    for (system.group_fields.items) |field| covered += field.pushed_count;
    // Every field covers its cap: the lattice's corridor cells reach past the largest cap.
    if (covered != group_field_tunnel_fields * item_count) return error.GroupFieldTunnelShortOfCap;
    printFieldMemory(options, group_field_tunnel_group.name, item_count, case, system);

    var stats = accumulator.finish();
    stats.output_count = covered;
    stats.items_per_second = suite.itemsPerSecond(covered, stats.mean_ns);
    return stats;
}

const LevelCode = suite.ItemCode(struct { level_side: u16, levels: u16 }, &.{3});
const CrossLevelCode = suite.ItemCode(struct { layout: TeleportLayout, teleports: usize, level_side: u16, levels: u16 }, &.{ 5, 4, 3 });
const LongPathCode = suite.ItemCode(struct { variant: LongPathVariant, layout: LongPathLayout, parameter: u16 }, &.{ 1, 6 });
const LinkFoldCode = suite.ItemCode(struct { axis: LinkFoldAxis, probe_preload: usize, background_pads: usize }, &.{ 3, 6 });
const EvictCode = suite.ItemCode(struct { region_chunks: usize, cached_results: usize }, &.{7});
const NegativeDigCode = suite.ItemCode(struct { level_side: u16, requests: u16 }, &.{3});
const BurstCode = suite.ItemCode(struct { variant: BurstVariant, requests: usize }, &.{6});
const SplitCode = suite.ItemCode(struct { variant: SplitVariant, edge_chunks: u16, level_side: u16, levels: u16 }, &.{ 3, 4, 3 });
const OnewayCode = suite.ItemCode(struct { variant: OnewayVariant, terminals_per_system: usize, systems: usize }, &.{ 5, 5 });

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
    teleportCode(.random_pads, 64, 256),
    teleportCode(.random_pads, 256, 256),
};

fn teleportItemCounts(_: suite.Profile) []const usize {
    return &teleport_item_counts;
}

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
// The dig at each result count, then the region axis at a fixed result count.
const evict_item_counts = [_]usize{
    EvictCode.of(.{ .region_chunks = 0, .cached_results = 1_000 }),
    EvictCode.of(.{ .region_chunks = 0, .cached_results = 10_000 }),
    EvictCode.of(.{ .region_chunks = 0, .cached_results = 50_000 }),
    EvictCode.of(.{ .region_chunks = 4, .cached_results = 10_000 }),
    EvictCode.of(.{ .region_chunks = 16, .cached_results = 10_000 }),
    EvictCode.of(.{ .region_chunks = 64, .cached_results = 10_000 }),
};
const elastic_ramp_item_counts = [_]usize{ 1_000, 4_000, 16_000 };

fn levelSizeItemCounts(_: suite.Profile) []const usize {
    return &level_size_item_counts;
}

fn crossLevelItemCounts(_: suite.Profile) []const usize {
    return &cross_level_item_counts;
}

fn linkFoldItemCounts(_: suite.Profile) []const usize {
    return &link_fold_item_counts;
}

fn evictItemCounts(_: suite.Profile) []const usize {
    return &evict_item_counts;
}

fn elasticRampItemCounts(_: suite.Profile) []const usize {
    return &elastic_ramp_item_counts;
}

const negative_steady_item_counts = [_]usize{ 256, 1024, 4096 };
const negative_dig_item_counts = [_]usize{
    NegativeDigCode.of(.{ .level_side = 256, .requests = 64 }),
    NegativeDigCode.of(.{ .level_side = 256, .requests = 128 }),
    NegativeDigCode.of(.{ .level_side = 256, .requests = 256 }),
    NegativeDigCode.of(.{ .level_side = 1024, .requests = 64 }),
    NegativeDigCode.of(.{ .level_side = 2048, .requests = 64 }),
};

fn negativeSteadyItemCounts(_: suite.Profile) []const usize {
    return &negative_steady_item_counts;
}

fn negativeDigItemCounts(_: suite.Profile) []const usize {
    return &negative_dig_item_counts;
}

const negative_burst_item_counts = [_]usize{
    BurstCode.of(.{ .variant = .open_goals, .requests = 1024 }),
    BurstCode.of(.{ .variant = .open_goals, .requests = 4096 }),
    BurstCode.of(.{ .variant = .open_goals, .requests = 12288 }),
    BurstCode.of(.{ .variant = .blocked_crowd, .requests = 1024 }),
    BurstCode.of(.{ .variant = .blocked_crowd, .requests = 4096 }),
    BurstCode.of(.{ .variant = .blocked_crowd, .requests = 12288 }),
};

fn negativeBurstItemCounts(_: suite.Profile) []const usize {
    return &negative_burst_item_counts;
}

fn splitItemCode(comptime variant: SplitVariant, comptime edge_chunks: u16, comptime level_side: u16) usize {
    return SplitCode.of(.{ .variant = variant, .edge_chunks = edge_chunks, .level_side = level_side, .levels = 1 });
}

// Room edges at one side, then the middle edge at two more sides, then ring edges, then
// tunnel lengths at one side and the shortest at two more.
const connectivity_split_item_counts = [_]usize{
    splitItemCode(.room, 2, 1024),
    splitItemCode(.room, 8, 1024),
    splitItemCode(.room, 32, 1024),
    splitItemCode(.room, 8, 256),
    splitItemCode(.room, 8, 2048),
    splitItemCode(.ring, 2, 1024),
    splitItemCode(.ring, 8, 1024),
    splitItemCode(.ring, 32, 1024),
    splitItemCode(.tunnel, 8, 1024),
    splitItemCode(.tunnel, 32, 1024),
    splitItemCode(.tunnel, 62, 1024),
    splitItemCode(.tunnel, 8, 256),
    splitItemCode(.tunnel, 8, 2048),
};

fn connectivitySplitItemCounts(_: suite.Profile) []const usize {
    return &connectivity_split_item_counts;
}

fn onewayItemCode(comptime variant: OnewayVariant, comptime terminals: usize, comptime systems: usize) usize {
    return OnewayCode.of(.{ .variant = variant, .terminals_per_system = terminals, .systems = systems });
}

const connectivity_oneway_item_counts = [_]usize{
    onewayItemCode(.locality, 8, 16),
    onewayItemCode(.locality, 8, 256),
    onewayItemCode(.locality, 8, 2048),
    onewayItemCode(.tail, 64, 1),
    onewayItemCode(.tail, 512, 1),
    onewayItemCode(.tail, 4096, 1),
    onewayItemCode(.head, 64, 1),
    onewayItemCode(.head, 512, 1),
    onewayItemCode(.head, 4096, 1),
    onewayItemCode(.far_dig, 64, 1),
    onewayItemCode(.far_dig, 512, 1),
    onewayItemCode(.far_dig, 4096, 1),
    onewayItemCode(.shrunk, 512, 1),
    onewayItemCode(.shrunk, 2048, 1),
    onewayItemCode(.shrunk, 4096, 1),
    onewayItemCode(.fan, 64, 1),
    onewayItemCode(.fan, 128, 1),
    onewayItemCode(.fan, 256, 1),
    onewayItemCode(.dense, oneway_dense_terminals, 2),
    onewayItemCode(.dense, oneway_dense_terminals, 8),
    onewayItemCode(.dense, oneway_dense_terminals, 32),
    onewayItemCode(.ballast, 8, 64),
    onewayItemCode(.ballast, 8, 512),
    onewayItemCode(.ballast, 8, 2048),
};

fn connectivityOnewayItemCounts(_: suite.Profile) []const usize {
    return &connectivity_oneway_item_counts;
}

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

fn writeUnavailableWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("unavailable={}", .{stats.output_count});
}

fn writeBurstWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("unavailable={} projections={}", .{ stats.output_count, stats.candidate_pairs });
}

fn writeSplitWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("cells={} structure_chunks={}", .{ stats.output_count, stats.candidate_pairs });
    if (view == .details) {
        try writer.writeByte(' ');
        try suite.writeNavStages(writer, stats);
    }
}

fn writeOnewayWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("rooms={} oneway_links={}", .{ stats.candidate_pairs, stats.output_count });
    if (view == .details) {
        try writer.writeByte(' ');
        try suite.writeNavStages(writer, stats);
    }
}

// Walkable levels of `side`² tiles in default chunks, one floor band per level (level
// `i` owns layer `i`); `blocking` blocks movement.
const OpenWorld = struct {
    world: WorldSystem,
    walkable: TileId,
    blocking: TileId,

    fn floor(level: u16) usize {
        return level;
    }

    fn cellCenter(self: *const OpenWorld, cell: CellCoord) math.Vec2 {
        return .{
            .x = (@as(f32, @floatFromInt(cell.x)) + 0.5) * self.world.tile_size,
            .y = (@as(f32, @floatFromInt(cell.y)) + 0.5) * self.world.tile_size,
        };
    }
};

fn buildOpenWorld(allocator: std.mem.Allocator, io: std.Io, side: u16, levels: u16) !OpenWorld {
    var world = try fixtures.buildBandedWorld(allocator, io, side, levels, "grass", "grass");
    errdefer world.deinit();
    const meta = world.tilesetMeta().?;
    const walkable = try world.requireTileByName(meta, "grass");
    const blocking = try world.requireTileByName(meta, "dirt");
    return .{ .world = world, .walkable = walkable, .blocking = blocking };
}

// Writes `tile` into `cells` on level 0 in one reserve scope.
fn writeLevelZeroCells(open: *OpenWorld, cells: []const CellCoord, tile: TileId) !void {
    try writeLevelCells(open, 0, cells, tile);
}

// Writes `tile` into `cells` on `level` in one reserve scope.
fn writeLevelCells(open: *OpenWorld, level: u16, cells: []const CellCoord, tile: TileId) !void {
    const layer = OpenWorld.floor(level);
    open.world.beginDenseCellWriteReserve();
    for (cells) |cell| try open.world.reserveDenseCellWrite(layer, cell.x, cell.y, tile);
    for (cells) |cell| _ = try open.world.setDenseTile(layer, cell.x, cell.y, tile);
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

// The chunk keys a marks batch toggling one cell patches: its chunk and four neighbours.
const toggle_batch_keys: usize = suite.squareBatchKeys(1);
const toggle_batch: suite.NavBatch = .{ .mark_chunks = 1, .links = 0, .keys = toggle_batch_keys };

// The route fixtures never change nav after the build: no marks batch.
fn routeSizeConfig(side: usize, levels: usize, links: usize, participant_count: usize) suite.NavSizeConfig {
    return .{
        .side = side,
        .levels = levels,
        .links = links,
        .participant_count = participant_count,
        .agent_budget = route_request_count,
        .group_fields = 1,
        .batch = suite.NavBatch.none,
    };
}

// A world-backed nav with a fixed request set, timed one cold step at a time.
const RouteFixture = struct {
    open: OpenWorld,
    data: DataSystem,
    requests: RangeOutputStream(PathRequest),
    system: PathfindingSystem,

    fn deinit(self: *RouteFixture) void {
        self.system.deinit();
        self.requests.deinit();
        self.data.deinit();
        self.open.world.deinit();
        self.* = undefined;
    }
};

// Takes ownership of `open`; adds one entity per request.
fn initRouteFixture(allocator: std.mem.Allocator, open: OpenWorld, requests: []PathRequest, capacity: PathfindingCapacity, thread_system: ?*ThreadSystem) !RouteFixture {
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

fn runLevelSizeCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const code = try LevelCode.decode(item_count);
    const side = code.level_side;
    const levels = code.levels;
    if (levels != 1 or side < 256) return error.LevelSizeBadConfig;
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
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
    size_config.content = NavGraph.storageContentOf(&open.world);
    try suite.checkNavSize(level_size_group.name, item_count, case, size_config);

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
    var fixture = try initRouteFixture(allocator, open, &requests, suite.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit();
    try suite.checkNavBytes(level_size_group.name, item_count, size_config, &fixture.system);
    const stats = try runColdRouteSteps(io, options, case, level_size_group.name, item_count, &fixture, thread_ptr, .fail);
    try suite.checkNavBytes(level_size_group.name, item_count, size_config, &fixture.system);
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

    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
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
    size_config.content = NavGraph.storageContentOf(&open.world);
    try suite.checkNavSize(group_name, item_count, case, size_config);

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
    var fixture = try initRouteFixture(allocator, open, &requests, suite.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit();
    try suite.checkNavBytes(group_name, item_count, size_config, &fixture.system);
    const stats = try runColdRouteSteps(io, options, case, group_name, item_count, &fixture, thread_ptr, if (teleport) .count else .fail);
    try suite.checkNavBytes(group_name, item_count, size_config, &fixture.system);
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

    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
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
    size_config.content = NavGraph.storageContentOf(&open.world);
    try suite.checkNavSize(cross_level_shaft_group.name, item_count, case, size_config);

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
    var fixture = try initRouteFixture(allocator, open, &requests, suite.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit();
    try suite.checkNavBytes(cross_level_shaft_group.name, item_count, size_config, &fixture.system);
    const stats = try runColdRouteSteps(io, options, case, cross_level_shaft_group.name, item_count, &fixture, thread_ptr, .count);
    try suite.checkNavBytes(cross_level_shaft_group.name, item_count, size_config, &fixture.system);
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

fn longPathItemCounts(_: suite.Profile) []const usize {
    return &long_path_item_counts;
}

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

const PlanarRoute = struct {
    start: CellCoord,
    goal: CellCoord,
};

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

// Times one serial step that must solve exactly one request, at `tier`, and reads that solve
// from its scratch: the participant's corridor for a first attempt, the first tier-1 pool
// entry (the step's only escalated admission) for an escalated one.
fn runLongPathAttempt(io: std.Io, system: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), request: PathRequest, agent_count: usize, tier: u8) !LongPathAttempt {
    const start_ns = suite.nowNs(io);
    const stats = try system.updateSerial(requests, agent_count, .{
        .max_solved_requests_per_step = agent_count,
        .max_solve_admissions_per_step = agent_count,
    });
    const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
    if (stats.unavailable_results != 0) return error.RouteUnavailable;
    if (stats.start_invalid_dropped != 0) return error.RouteStartInvalid;
    if (stats.solve_admissions != 1 or stats.escalated_solves != @intFromBool(tier != 0)) return error.LongPathNotOneSolve;
    const corridor = if (tier == 0) &system.scratch_slots.items[0].corridor else &system.tier1_scratch.items[0].corridor;
    const abstract = &corridor.abstract;
    // A search that reached its goal leaves its corridor; a saturated one leaves it empty, or
    // cut at the corridor limit.
    const found = abstract.corridor.items.len != 0 and abstract.corridor.items.len < abstract.corridor_limit;
    const cells = if (found) corridor.stitched.items.len else 0;
    const segments = stats.max_stitch_segments_observed;
    const outcome: LongPathOutcome = if (stats.available_results == 1 or stats.partial_results == 1) published: {
        // Every layout's route leaves its start's chunk, so the solve ran the abstract search.
        if (stats.abstract_solves != 1 or !found) return error.LongPathSolvedOffCorridor;
        if (stats.partial_results == 0) break :published .available;
        break :published if (corridorEndsAtGoal(system, abstract.corridor.items, request)) .partial else .abstract_partial;
    } else if (stats.budget_exhausted != 1)
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

// One request cycle from empty runtime state: the first attempt, the escalated attempt when
// the first exhausted, then every agent's status. No request stays pending after the second
// attempt: it solves or drops.
fn runLongPathCycle(io: std.Io, fixture: *RouteFixture, empty: *const RangeOutputStream(PathRequest), requests: []const PathRequest) !LongPathCycle {
    const system = &fixture.system;
    system.clearRuntimeState();
    const first = try runLongPathAttempt(io, system, &fixture.requests, requests[0], requests.len, 0);
    var escalated: ?LongPathAttempt = null;
    if (first.outcome != .available) {
        if (system.pending.len != 1 or system.pending.at(0).tier != 1) return error.LongPathNotEscalated;
        escalated = try runLongPathAttempt(io, system, empty, requests[0], requests.len, 1);
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

// Walks `request`'s agent from empty runtime state to its goal (see the group comment).
fn runLongPathWalk(io: std.Io, fixture: *RouteFixture, stream: *RangeOutputStream(PathRequest), request: PathRequest, step_limit: usize) !LongPathWalk {
    const system = &fixture.system;
    system.clearRuntimeState();
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
        const stats = try system.updateSerial(stream, 1, .{ .max_solved_requests_per_step = 1, .max_solve_admissions_per_step = 1 });
        walk.solve_ns += suite.elapsedNs(start_ns, suite.nowNs(io));
        walk.claims += tier0_abstract.nodes_used + tier1_abstract.nodes_used;
        if (stats.unavailable_results != 0) return error.RouteUnavailable;
        if (stats.start_invalid_dropped != 0) return error.RouteStartInvalid;
        walk.solves += stats.solve_admissions;
        walk.partial_results += stats.partial_results;
        walk.full_results += stats.available_results - stats.cache_hits;
        walk.escalations += stats.escalated_solves;
    }
    if (!std.meta.eql(grid.worldToCellClamped(position), goal_cell)) return error.LongPathWalkStalled;
    return walk;
}

fn runLongPathWalkCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, config: LongPathConfig, fixture: *RouteFixture, request: PathRequest, blocked: usize) !suite.RunStats {
    var stream = RangeOutputStream(PathRequest).init(allocator);
    defer stream.deinit();
    const step_limit = 4 * config.routeCells() + 64;
    for (0..coldWarmup(options)) |_| _ = try runLongPathWalk(io, fixture, &stream, request, step_limit);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var reference: ?LongPathWalk = null;
    for (0..coldIterations(options)) |_| {
        const walk = try runLongPathWalk(io, fixture, &stream, request, step_limit);
        if (reference) |kept| {
            if (!kept.sameWork(walk)) return error.LongPathWorkVaried;
        } else reference = walk;
        accumulator.record(walk.solve_ns, inlineBatch(1, pathfinding_range_alignment_items));
    }
    var stats = accumulator.finish();
    const walk = reference orelse return stats;
    if (options.details) {
        std.debug.print("  {s} {} {s}: {s} walk parameter={} route~{} cells | steps={} held={} solves={} partial={} full={} escalations={} claims={} solve={}us | blocked={}\n", .{
            long_path_group.name,
            item_count,
            case.name,
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

// Chains `request`'s hops from empty runtime state: each hop's request runs its first attempt
// and, when that promoted, its escalated attempt; a partial restarts the chain at its end, on
// its level, until a hop arrives (`.available`) or drops (`.missing`).
fn runLongPathHops(io: std.Io, fixture: *RouteFixture, stream: *RangeOutputStream(PathRequest), request: PathRequest, hop_limit: usize) !LongPathHops {
    const system = &fixture.system;
    system.clearRuntimeState();
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
            const stats = try system.updateSerial(stream, 1, .{ .max_solved_requests_per_step = 1, .max_solve_admissions_per_step = 1 });
            chain.solve_ns += suite.elapsedNs(start_ns, suite.nowNs(io));
            try fixtures.writeRequests(stream, &.{});
            chain.claims += tier0_abstract.nodes_used + tier1_abstract.nodes_used;
            if (stats.unavailable_results != 0) return error.RouteUnavailable;
            if (stats.start_invalid_dropped != 0) return error.RouteStartInvalid;
            if (stats.solve_admissions != 1 or stats.cache_hits != 0) return error.LongPathNotOneSolve;
            chain.solves += 1;
            chain.escalations += stats.escalated_solves;
            if (stats.available_results == 1) break .arrived;
            if (stats.partial_results == 1) {
                if (attempt == 1 and !corridorEndsAtGoal(system, tier1_abstract.corridor.items, hop)) chain.least_hops += 1;
                break .partial;
            }
            if (stats.escalated_dropped == 1) break .dropped;
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

fn runLongPathHopsCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, config: LongPathConfig, fixture: *RouteFixture, request: PathRequest) !suite.RunStats {
    var stream = RangeOutputStream(PathRequest).init(allocator);
    defer stream.deinit();
    // Every published hop advances at least one cell.
    const hop_limit = config.routeCells() + 64;
    for (0..coldWarmup(options)) |_| _ = try runLongPathHops(io, fixture, &stream, request, hop_limit);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var reference: ?LongPathHops = null;
    for (0..coldIterations(options)) |_| {
        const chain = try runLongPathHops(io, fixture, &stream, request, hop_limit);
        if (reference) |kept| {
            if (!kept.sameWork(chain)) return error.LongPathWorkVaried;
        } else reference = chain;
        accumulator.record(chain.solve_ns, inlineBatch(1, pathfinding_range_alignment_items));
    }
    var stats = accumulator.finish();
    const chain = reference orelse return stats;
    if (options.details) {
        std.debug.print("  {s} {} {s}: {s} hops parameter={} route~{} cells | stop=L{}:{} hops={} least_hops={} solves={} escalations={} claims={} solve={}us\n", .{
            long_path_group.name,
            item_count,
            case.name,
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

fn printLongPathAttempt(label: []const u8, attempt: LongPathAttempt, mean_ns: u64) void {
    std.debug.print(" | {s}: nodes={} corridor={} cells={} segments={} settles={} frozen={} outcome={s} {}us", .{
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
    if (case.usesThreadSystem()) return suite.RunStats.skipped("each step solves one request: a one-item solve batch");
    const config = try LongPathConfig.decode(item_count);
    const levels = config.levels();
    const agent_count = config.agents();
    var requests: [long_path_crowd]PathRequest = undefined;
    // The world first: its content sizes the nav.
    const built = try buildLongPathWorld(allocator, io, config, &requests);
    var open = built.open;
    var open_owned = true;
    defer if (open_owned) open.world.deinit();
    const size_config = suite.NavSizeConfig{
        .side = config.side(),
        .levels = levels,
        .links = levels - 1,
        // Every ramp is bidirectional.
        .oneway_links = 0,
        .participant_count = 1,
        .agent_budget = agent_count,
        .group_fields = 1,
        .batch = suite.NavBatch.none,
        .content = NavGraph.storageContentOf(&open.world),
        .tier1_abstract_nodes = if (config.variant == .probe) long_path_probe_nodes else default_tier1_abstract_node_cap,
    };
    try suite.checkNavSize(long_path_group.name, item_count, case, size_config);

    const capacity = suite.navSizeCapacity(size_config);
    open_owned = false;
    var fixture = try initRouteFixture(allocator, open, requests[0..agent_count], capacity, null);
    defer fixture.deinit();
    try suite.checkNavBytes(long_path_group.name, item_count, size_config, &fixture.system);
    var empty = RangeOutputStream(PathRequest).init(allocator);
    defer empty.deinit();
    const agents = requests[0..agent_count];
    // Every variant checks the nav's bytes again once its paths are cached and registered.
    if (config.variant == .walk or config.variant == .hops) {
        const stats = if (config.variant == .walk)
            try runLongPathWalkCase(allocator, io, options, case, item_count, config, &fixture, agents[0], built.blocked)
        else
            try runLongPathHopsCase(allocator, io, options, case, item_count, config, &fixture, agents[0]);
        try suite.checkNavBytes(long_path_group.name, item_count, size_config, &fixture.system);
        return stats;
    }

    for (0..coldWarmup(options)) |_| _ = try runLongPathCycle(io, &fixture, &empty, agents);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var reference: ?LongPathCycle = null;
    var first_ns: u64 = 0;
    var escalated_ns: u64 = 0;
    for (0..coldIterations(options)) |_| {
        const cycle = try runLongPathCycle(io, &fixture, &empty, agents);
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
    try suite.checkNavBytes(long_path_group.name, item_count, size_config, &fixture.system);
    var stats = accumulator.finish();
    const cycle = reference orelse return stats;
    if (options.details) {
        const samples: u64 = stats.iterations;
        std.debug.print("  {s} {} {s}: {s} {s} parameter={} route~{} cells agents={}", .{
            long_path_group.name,
            item_count,
            case.name,
            @tagName(config.layout),
            @tagName(config.variant),
            config.parameter,
            config.routeCells(),
            agent_count,
        });
        printLongPathAttempt("first", cycle.first, first_ns / samples);
        if (cycle.escalated) |escalated| printLongPathAttempt("escalated", escalated, escalated_ns / samples);
        std.debug.print(" | blocked={} status available={} partial={} missing={}\n", .{ built.blocked, cycle.available, cycle.partial, cycle.missing });
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
    return @as(usize, @intCast(chunk.y)) * world.chunksX() + @as(usize, @intCast(chunk.x));
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

const RouteOutcome = struct {
    solved: usize,
    unsolved: usize,
};

// One cold pathfinding step of the fixture's requests. Every fixture route exists and
// starts on an open cell, so an unavailable answer or an invalid start is a fixture fault.
fn runRouteStep(system: *PathfindingSystem, fixture: *RouteFixture, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase, unsolved_routes: UnsolvedRoutes) !PathfindingStats {
    const count = route_request_count;
    const stats = try runColdOnce(system, &fixture.requests, thread_system, case, count, count, count);
    if (stats.unavailable_results != 0) return error.RouteUnavailable;
    if (stats.start_invalid_dropped != 0) return error.RouteStartInvalid;
    std.debug.assert(stats.available_results <= count);
    if (unsolved_routes == .fail and (stats.available_results != count or stats.pending_requests != 0)) return error.RouteUnsolved;
    return stats;
}

// Times one cold pathfinding step of the fixture's requests per iteration (runtime
// state cleared, untimed, before each).
fn runColdRouteSteps(io: std.Io, options: suite.Options, case: suite.BenchmarkCase, group_name: []const u8, item_count: usize, fixture: *RouteFixture, thread_system: ?*ThreadSystem, unsolved_routes: UnsolvedRoutes) !suite.RunStats {
    const system = &fixture.system;
    setPathStageTuners(system, case);
    for (0..options.warmup_iterations) |_| {
        system.clearRuntimeState();
        _ = try runRouteStep(system, fixture, thread_system, case, unsolved_routes);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = coldSettleLimit(options);
        while (!system.tuners.solve.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            system.clearRuntimeState();
            _ = try runRouteStep(system, fixture, thread_system, case, unsolved_routes);
        }
    }
    const settled = if (case.adaptive) system.tuners.solve.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    var abstract_nodes: usize = 0;
    var stage_report = StageReport{};
    for (0..options.iterations) |_| {
        system.clearRuntimeState();
        const start_ns = suite.nowNs(io);
        last_stats = try runRouteStep(system, fixture, thread_system, case, unsolved_routes);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        accumulator.record(elapsed_ns, last_stats.solve_batch);
        stage_report.add(elapsed_ns, last_stats);
        abstract_nodes = lastAbstractNodesUsed(system);
    }
    if (unsolved_routes == .count) stage_report.routes = .{ .solved = last_stats.available_results, .unsolved = route_request_count - last_stats.available_results };
    stage_report.print(options, group_name, item_count, case);
    var stats = accumulator.finish();
    stats.output_count = last_stats.available_results;
    stats.candidate_pairs = abstract_nodes;
    stats.items_per_second = suite.itemsPerSecond(stats.output_count, stats.mean_ns);
    if (case.adaptive) stats.work_tuning = suite.workTuningSummary(system.tuners.solve.report(), settled);
    return stats;
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
    return (result_count + cached_results_per_agent - 1) / cached_results_per_agent;
}

// The evict dig: right of every goal column, so it crosses a few paths of the first
// goal rows at every count and is no request's goal.
const evict_dig_cell: CellCoord = .{ .x = 250, .y = 9 };

// A world-backed nav with its static colliders and requests, its terrain changed as a
// writer changes it and the post-commit nav reaction run on it.
const ReactFixture = struct {
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

    fn deinit(self: *ReactFixture, allocator: std.mem.Allocator) void {
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
    // every result is cached. Untimed.
    fn fillCache(self: *ReactFixture, case: suite.BenchmarkCase, thread_system: ?*ThreadSystem) !void {
        var start: usize = 0;
        while (start < self.requests.len) : (start += self.agent_count) {
            const end = @min(start + self.agent_count, self.requests.len);
            try fixtures.writeRequests(&self.stream, self.requests[start..end]);
            var step_stats = try runColdOnce(&self.system, &self.stream, thread_system, case, self.agent_count, self.agent_count, self.agent_count);
            var guard = suite.rangeCount(self.agent_count, default_max_solves_per_frame) + 2;
            while (step_stats.pending_requests != 0) : (guard -= 1) {
                if (guard == 0) return error.EvictFillStalled;
                step_stats = try runColdOnce(&self.system, &self.empty, thread_system, case, self.agent_count, self.agent_count, self.agent_count);
            }
        }
        if (self.cachedCount() != self.requests.len) return error.EvictFillIncomplete;
    }

    // Requests whose path the cache serves. Untimed: one status query per request.
    fn cachedCount(self: *const ReactFixture) usize {
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
    fn changeAndReact(self: *ReactFixture, io: std.Io, cells: []const CellCoord, tile: TileId, thread_system: ?*ThreadSystem) !Reaction {
        return self.changeLevelAndReact(io, 0, cells, tile, thread_system);
    }

    // `changeAndReact` on `level`.
    fn changeLevelAndReact(self: *ReactFixture, io: std.Io, level: u16, cells: []const CellCoord, tile: TileId, thread_system: ?*ThreadSystem) !Reaction {
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
        return .{ .elapsed_ns = elapsed, .stats = stats };
    }
};

const Reaction = struct {
    elapsed_ns: u64,
    stats: NavUpdateStats,
};

// Three stages' shapes in the timed nav reactions and the reactions' main-thread share and
// split: each reaction minus its worker-side stage time.
const ReactionStages = struct {
    samples: usize = 0,
    timed_ns: u128 = 0,
    main_ns: u128 = 0,
    shapes: suite.StageShapes(3) = .{},
    nav_main: suite.NavMainSummary = .{},

    fn add(self: *ReactionStages, reaction: Reaction, batches: [3]BatchStats) void {
        self.samples += 1;
        self.timed_ns += reaction.elapsed_ns;
        const main_ns = reaction.elapsed_ns -| reaction.stats.off_main_stage_ns;
        self.main_ns += main_ns;
        self.nav_main.add(main_ns, reaction.stats);
        self.nav_main.endSample();
        self.shapes.add(batches);
    }

    // The stages' shapes, written into `buffers`.
    fn labels(self: *const ReactionStages, buffers: *[3][48]u8) [3][]const u8 {
        var stage_labels: [3][]const u8 = undefined;
        for (buffers, &stage_labels, 0..) |*buffer, *label, index| label.* = self.shapes.label(index, buffer);
        return stage_labels;
    }

    fn mainUsPerSample(self: ReactionStages) u64 {
        return @intCast(self.main_ns / self.samples / std.time.ns_per_us);
    }

    fn mainPercent(self: ReactionStages) u64 {
        return @intCast(self.main_ns * 100 / self.timed_ns);
    }
};

// The timed reactions' eviction stage shapes and main-thread share, printed under
// --details.
const EvictReport = struct {
    stages: ReactionStages = .{},
    visited: usize = 0,
    evicted: usize = 0,

    fn add(self: *EvictReport, reaction: Reaction) void {
        self.stages.add(reaction, .{ reaction.stats.evict_count_batch, reaction.stats.evict_batch, reaction.stats.evict_flush_batch });
        self.visited = reaction.stats.evict_entries_visited;
        self.evicted = reaction.stats.evicted_results;
    }

    fn print(self: EvictReport, options: suite.Options, group_name: []const u8, item_count: usize, case: suite.BenchmarkCase) void {
        if (!options.details or self.stages.timed_ns == 0) return;
        var shapes: [3][48]u8 = undefined;
        const labels = self.stages.labels(&shapes);
        var main_buffer: [320]u8 = undefined;
        std.debug.print("  {s} {} {s}: evict_count={s} evict={s} evict_flush={s} main={}us ({}%) visited={} evicted={}{s}\n", .{
            group_name,
            item_count,
            case.name,
            labels[0],
            labels[1],
            labels[2],
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
fn assembleReactFixture(allocator: std.mem.Allocator, open: *OpenWorld, data: *DataSystem, requests: []PathRequest, capacity: PathfindingCapacity, thread_system: ?*ThreadSystem) !ReactFixture {
    var colliders = StaticColliderSystem.init(allocator);
    errdefer colliders.deinit();
    const extent = PathfindingSystem.worldNavExtent(&open.world);
    try colliders.rebuild(data, try extent.colliderGeometry());
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
    const region_chunks = code.region_chunks;
    const result_count = code.cached_results;
    const region_edge = std.math.cast(u16, std.math.sqrt(region_chunks)) orelse return error.EvictRegionTooLarge;
    if (@as(usize, region_edge) * region_edge != region_chunks) return error.EvictRegionNotSquare;
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count = fixtures.participantCount(thread_ptr);
    const size_config = suite.NavSizeConfig{
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
            .keys = suite.squareBatchKeys(region_edge),
        },
    };
    try suite.checkNavSize(evict_group.name, item_count, case, size_config);

    var fixture = try initShortRouteFixture(allocator, io, result_count, suite.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    try suite.checkNavBytes(evict_group.name, item_count, size_config, &fixture.system);
    const region_cells: ?[]CellCoord = if (region_chunks == 0) null else region: {
        const chunks = try evictRegionChunks(allocator, region_edge);
        defer allocator.free(chunks);
        break :region try chunkCells(allocator, chunks, fixture.open.world.chunk_size_tiles);
    };
    defer if (region_cells) |cells| allocator.free(cells);
    const cells: []const CellCoord = region_cells orelse &.{evict_dig_cell};
    try fixture.changed.ensureTotalCapacity(allocator, cells.len);
    fixtures.setNavTuners(&fixture.system, case);
    try fixture.fillCache(case, thread_ptr);

    for (0..options.warmup_iterations) |_| {
        _ = try fixture.changeAndReact(io, cells, fixture.open.blocking, thread_ptr);
        _ = try fixture.changeAndReact(io, cells, fixture.open.walkable, thread_ptr);
        try fixture.fillCache(case, thread_ptr);
    }
    var accumulator = suite.StatsAccumulator.init(item_count);
    var report = EvictReport{};
    var evicted: usize = 0;
    var last_stats: NavUpdateStats = .{};
    for (0..options.iterations) |_| {
        const reaction = try fixture.changeAndReact(io, cells, fixture.open.blocking, thread_ptr);
        evicted = result_count - fixture.cachedCount();
        // The reaction evicted exactly the results the cache lost.
        if (reaction.stats.evicted_results != evicted) return error.EvictCountMismatch;
        last_stats = reaction.stats;
        accumulator.record(reaction.elapsed_ns, reaction.stats.remask_batch);
        report.add(reaction);
        _ = try fixture.changeAndReact(io, cells, fixture.open.walkable, thread_ptr);
        try fixture.fillCache(case, thread_ptr);
    }
    report.print(options, evict_group.name, item_count, case);
    // The size config charges no long block.
    if (fixture.system.long_block_growth.count != 0) return error.ShortRouteTookLongBlock;
    try suite.checkNavBytes(evict_group.name, item_count, size_config, &fixture.system);
    var stats = accumulator.finish();
    stats.output_count = evicted;
    stats.cache_evictions = evicted;
    stats.candidate_pairs = result_count;
    // Registry entries the reaction's eviction visited per second.
    stats.items_per_second = suite.itemsPerSecond(report.visited, stats.mean_ns);
    stats.batch = suite.batchSummaryFromBatch(last_stats.remask_batch);
    stats.secondary_batch = suite.batchSummaryFromBatch(last_stats.patch_batch);
    return stats;
}

const elastic_ramp_steps: usize = 64;

const ElasticRamp = struct {
    elapsed_ns: u64 = 0,
    solves: usize = 0,
    // The solve stage of the step that solved the most.
    busiest_solve_batch: BatchStats = .{},
};

fn runElasticRampCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count = fixtures.participantCount(thread_ptr);
    const size_config = suite.NavSizeConfig{
        .side = short_route_side,
        .levels = 1,
        .participant_count = participant_count,
        .agent_budget = item_count,
        .group_fields = 1,
        .long_results = 0,
        .runs_per_result = short_route_runs,
        // Requests only: no marks batch.
        .batch = suite.NavBatch.none,
    };
    try suite.checkNavSize(elastic_ramp_group.name, item_count, case, size_config);
    const capacity = suite.navSizeCapacity(size_config);

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
    try suite.checkNavBytes(elastic_ramp_group.name, item_count, size_config, &system);
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
    try suite.checkNavBytes(elastic_ramp_group.name, item_count, size_config, &system);
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
fn runElasticRamp(io: std.Io, case: suite.BenchmarkCase, system: *PathfindingSystem, capacity: PathfindingCapacity, stream: *RangeOutputStream(PathRequest), requests: []const PathRequest, thread_system: ?*ThreadSystem) !ElasticRamp {
    try system.reserve(capacity);
    system.clearRuntimeState();
    const agent_total = requests.len;
    const step_limit = elastic_ramp_steps + 4 * suite.rangeCount(agent_total, default_max_solves_per_frame) + elastic_ramp_steps;
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

    fn print(self: ShrinkReport, options: suite.Options, group_name: []const u8, item_count: usize, case: suite.BenchmarkCase) void {
        if (!options.details or self.samples == 0 or self.step_ns == 0) return;
        const resize_ns = self.step_ns -| self.hold_ns;
        const resize_main_ns = resize_ns -| self.copy_ns;
        const samples: u128 = self.samples * std.time.ns_per_us;
        std.debug.print("  {s} {} {s}: agents {}->{} cache {}->{} kept={} evicted={} moved={} step={}us hold={}us resize={}us ({}% of step) copy={}us resize_main={}us\n", .{
            group_name,
            item_count,
            case.name,
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
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count = fixtures.participantCount(thread_ptr);
    const size_config = suite.NavSizeConfig{
        .side = short_route_side,
        .levels = 1,
        .participant_count = participant_count,
        .agent_budget = item_count,
        .group_fields = 1,
        .long_results = 0,
        .runs_per_result = short_route_runs,
        // Requests only: no marks batch.
        .batch = suite.NavBatch.none,
    };
    try suite.checkNavSize(elastic_shrink_group.name, item_count, case, size_config);
    const capacity = suite.navSizeCapacity(size_config);

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
    try suite.checkNavBytes(elastic_shrink_group.name, item_count, size_config, &system);
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
    stage_report.print(options, elastic_shrink_group.name, item_count, case);
    shrink_report.print(options, elastic_shrink_group.name, item_count, case);
    // The size config charges no long block.
    if (system.long_block_growth.count != 0) return error.ShortRouteTookLongBlock;

    try suite.checkNavBytes(elastic_shrink_group.name, item_count, size_config, &system);
    var stats = accumulator.finish();
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
    thread_system: ?*ThreadSystem,
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
        const owner = system.completed.core.ownerOf(entry.key) orelse continue;
        if (owner != entry.owner) shrink.moved += 1;
    }
    return shrink;
}

// One step of the held agents, which must be served by cache hits alone.
fn runHeldStep(system: *PathfindingSystem, stream: *RangeOutputStream(PathRequest), thread_system: ?*ThreadSystem, case: suite.BenchmarkCase, agent_count: usize) !PathfindingStats {
    const stats = try runColdOnce(system, stream, thread_system, case, agent_count, agent_count, agent_count);
    if (stats.cache_hits != agent_count or stats.solved_requests != 0) return error.ElasticShrinkHeldResultLost;
    return stats;
}

// Goal-pocket fixture: a walkable pocket of `pocket_side`² cells at the level origin, closed
// by the level border and a blocking column x = `pocket_side` and row y = `pocket_side`.
// Goals are pocket cells in row-major order; requesters start outside it on rows from
// `pocket_requester_row`, `pocket_requester_margin` cells clear of the level's sides.
const pocket_side: u16 = 80;
const pocket_requester_row: u16 = 96;
const pocket_requester_margin: u16 = 8;
// The far dig sits this many cells in from the level's far corner.
const pocket_dig_inset: u16 = 6;
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

fn pocketDigCell(side: u16) CellCoord {
    return .{ .x = side - pocket_dig_inset, .y = side - pocket_dig_inset };
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
    if (columns == 0 or pocket_requester_row + (requester_count + columns - 1) / columns > side -| pocket_dig_inset) return error.PocketRequesterRowsTooFew;
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
fn initPocketFixture(allocator: std.mem.Allocator, io: std.Io, side: u16, requester_count: usize, capacity: PathfindingCapacity, thread_system: ?*ThreadSystem) !ReactFixture {
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

fn pocketSizeConfig(side: u16, participant_count: usize, requester_count: usize) suite.NavSizeConfig {
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
fn runPocketUpdate(io: std.Io, case: suite.BenchmarkCase, fixture: *ReactFixture, thread_system: ?*ThreadSystem) !PocketStep {
    try fixtures.writeRequests(&fixture.stream, fixture.requests);
    const count = fixture.requests.len;
    const start_ns = suite.nowNs(io);
    const stats = try runColdOnce(&fixture.system, &fixture.stream, thread_system, case, count, count, count);
    const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
    if (stats.available_results != 0) return error.PocketGoalReached;
    if (stats.start_invalid_dropped != 0 or stats.dropped_requests != 0) return error.PocketRequestDropped;
    if (stats.solved_requests != 0 or stats.accepted_requests != 0 or stats.cache_hits != 0) return error.PocketSearched;
    if (stats.unavailable_results != count) return error.PocketNotAnsweredAtIntake;
    return .{ .elapsed_ns = elapsed_ns, .stats = stats };
}

fn runNegativeSteadyCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const side = negative_steady_side;
    try checkPocketLayout(allocator, side, item_count, item_count);
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count = fixtures.participantCount(thread_ptr);
    const size_config = pocketSizeConfig(side, participant_count, item_count);
    try suite.checkNavSize(negative_steady_group.name, item_count, case, size_config);

    var fixture = try initPocketFixture(allocator, io, side, item_count, suite.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    try suite.checkNavBytes(negative_steady_group.name, item_count, size_config, &fixture.system);
    setPathStageTuners(&fixture.system, case);

    for (0..coldWarmup(options)) |_| _ = try runPocketUpdate(io, case, &fixture, thread_ptr);
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = coldSettleLimit(options);
        while (!fixture.system.tuners.intake.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runPocketUpdate(io, case, &fixture, thread_ptr);
        }
    }
    const settled_before_measurement = if (case.adaptive) fixture.system.tuners.intake.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    var stage_report = StageReport{};
    for (0..coldIterations(options)) |_| {
        const step = try runPocketUpdate(io, case, &fixture, thread_ptr);
        last_stats = step.stats;
        accumulator.record(step.elapsed_ns, last_stats.intake_batch);
        stage_report.add(step.elapsed_ns, last_stats);
    }
    stage_report.print(options, negative_steady_group.name, item_count, case);

    try suite.checkNavBytes(negative_steady_group.name, item_count, size_config, &fixture.system);
    var stats = accumulator.finish();
    stats.output_count = last_stats.unavailable_results;
    if (case.adaptive) stats.work_tuning = suite.workTuningSummary(fixture.system.tuners.intake.report(), settled_before_measurement);
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

    fn print(self: NegativeDigReport, options: suite.Options, item_count: usize, case: suite.BenchmarkCase) void {
        if (!options.details or self.samples == 0) return;
        const samples: u128 = self.samples * std.time.ns_per_us;
        var remask_buffer: [48]u8 = undefined;
        std.debug.print("  {s} {} {s}: react={}us update={}us remask={s}\n", .{
            negative_dig_group.name,
            item_count,
            case.name,
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

    fn step(self: *NegativeDig, io: std.Io, case: suite.BenchmarkCase, fixture: *ReactFixture, thread_system: ?*ThreadSystem) !struct { reaction: Reaction, update: PocketStep } {
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
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count = fixtures.participantCount(thread_ptr);
    const size_config = pocketSizeConfig(side, participant_count, requester_count);
    try suite.checkNavSize(negative_dig_group.name, item_count, case, size_config);

    var fixture = try initPocketFixture(allocator, io, side, requester_count, suite.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    try suite.checkNavBytes(negative_dig_group.name, item_count, size_config, &fixture.system);
    try fixture.changed.ensureTotalCapacity(allocator, 1);
    setPathStageTuners(&fixture.system, case);
    fixtures.setNavTuners(&fixture.system, case);

    // Untimed first update: every request answered at intake, as every later one.
    var report = NegativeDigReport{};
    _ = try runPocketUpdate(io, case, &fixture, thread_ptr);

    var dig = NegativeDig{ .cell = pocketDigCell(side) };
    for (0..coldWarmup(options)) |_| _ = try dig.step(io, case, &fixture, thread_ptr);
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = coldSettleLimit(options);
        while (!fixture.system.tuners.intake.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try dig.step(io, case, &fixture, thread_ptr);
        }
    }
    const settled_before_measurement = if (case.adaptive) fixture.system.tuners.intake.isSettled() else false;

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
    stage_report.print(options, negative_dig_group.name, item_count, case);
    reaction_report.print(options, negative_dig_group.name, item_count, case);
    report.print(options, item_count, case);

    try suite.checkNavBytes(negative_dig_group.name, item_count, size_config, &fixture.system);
    var stats = accumulator.finish();
    stats.output_count = requester_count;
    if (stats.mean_ns != 0) stats.items_per_second = suite.itemsPerSecond(requester_count, stats.mean_ns);
    if (case.adaptive) stats.work_tuning = suite.workTuningSummary(fixture.system.tuners.intake.report(), settled_before_measurement);
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
    if (config.variant == .open_goals and (config.requests + burst_pockets - 1) / burst_pockets > @as(usize, burst_pocket_side) * burst_pocket_side) return error.NegativeBurstGoalCellsTooFew;
    const rows = (config.requests + burst_requester_columns - 1) / burst_requester_columns;
    if (burst_requester_row + rows > burst_side) return error.NegativeBurstRequesterRowsTooFew;
}

fn initBurstFixture(allocator: std.mem.Allocator, io: std.Io, config: BurstConfig, capacity: PathfindingCapacity, thread_system: ?*ThreadSystem) !ReactFixture {
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

fn burstSizeConfig(participant_count: usize, requester_count: usize) suite.NavSizeConfig {
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
        .batch = suite.NavBatch.none,
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
        self.shapes.add(.{ resolve.scan_batch, resolve.project_batch });
        self.off_main_ns += offMainNs(resolve.scan_batch) + offMainNs(resolve.project_batch);
    }

    fn print(self: ResolveReport, options: suite.Options, item_count: usize, case: suite.BenchmarkCase) void {
        if (!options.details or self.samples == 0) return;
        var scan_buffer: [48]u8 = undefined;
        var project_buffer: [48]u8 = undefined;
        std.debug.print("  {s} {} {s}: goal_scan={s} goal_project={s} goal_off_main={}us\n", .{
            negative_burst_group.name,
            item_count,
            case.name,
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
fn runBurst(io: std.Io, case: suite.BenchmarkCase, variant: BurstVariant, fixture: *ReactFixture, thread_system: ?*ThreadSystem) !BurstOutcome {
    const count = fixture.requests.len;
    fixture.system.clearRuntimeState();
    try fixtures.writeRequests(&fixture.stream, fixture.requests);
    const start_ns = suite.nowNs(io);
    const resolve = try runResolveGoals(&fixture.system, fixture.requests, thread_system, case);
    const stats = try runColdOnce(&fixture.system, &fixture.stream, thread_system, case, count, count, count);
    var elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
    if (stats.available_results != 0) return error.NegativeBurstGoalReached;
    if (stats.start_invalid_dropped != 0 or stats.dropped_requests != 0) return error.NegativeBurstRequestDropped;
    if (stats.unavailable_results != count or stats.pending_requests != 0) return error.NegativeBurstUnanswered;
    if (stats.solved_requests != 0) return error.NegativeBurstSearched;
    const status_start_ns = suite.nowNs(io);
    const all_unavailable = unavailableCount(fixture) == count;
    if (variant == .blocked_crowd) elapsed_ns += suite.elapsedNs(status_start_ns, suite.nowNs(io));
    if (!all_unavailable) return error.NegativeBurstStatusNotUnavailable;
    // One projection per distinct blocked goal, shared: four for the blocked crowd.
    const expected_projections: usize = if (variant == .blocked_crowd) burst_pockets else 0;
    if (resolve.distinct != expected_projections or stats.goal_fallbacks != 0) return error.NegativeBurstProjectionsNotShared;
    return .{ .elapsed_ns = elapsed_ns, .unavailable = stats.unavailable_results, .projections = resolve.distinct, .stats = stats, .resolve = resolve };
}

fn runNegativeBurstCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const config = try BurstConfig.decode(item_count);
    try checkBurstLayout(config);
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count = fixtures.participantCount(thread_ptr);
    const size_config = burstSizeConfig(participant_count, config.requests);
    try suite.checkNavSize(negative_burst_group.name, item_count, case, size_config);

    var fixture = try initBurstFixture(allocator, io, config, suite.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    try suite.checkNavBytes(negative_burst_group.name, item_count, size_config, &fixture.system);
    setPathStageTuners(&fixture.system, case);

    // At least one untimed burst: the first grows the capacity from the reserve floor.
    for (0..@max(1, coldWarmup(options))) |_| _ = try runBurst(io, case, config.variant, &fixture, thread_ptr);
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = coldSettleLimit(options);
        while (!fixture.system.tuners.intake.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runBurst(io, case, config.variant, &fixture, thread_ptr);
        }
    }
    const settled_before_measurement = if (case.adaptive) fixture.system.tuners.intake.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var stage_report = StageReport{};
    var resolve_report = ResolveReport{};
    var last: ?BurstOutcome = null;
    for (0..coldIterations(options)) |_| {
        const burst = try runBurst(io, case, config.variant, &fixture, thread_ptr);
        resolve_report.add(burst.resolve);
        // The update's stages and main share; the resolve's worker time prints on its own.
        stage_report.add(burst.elapsed_ns -| (offMainNs(burst.resolve.scan_batch) + offMainNs(burst.resolve.project_batch)), burst.stats);
        accumulator.record(burst.elapsed_ns, burst.stats.intake_batch);
        last = burst;
    }
    stage_report.print(options, negative_burst_group.name, item_count, case);
    resolve_report.print(options, item_count, case);

    try suite.checkNavBytes(negative_burst_group.name, item_count, size_config, &fixture.system);
    var stats = accumulator.finish();
    if (last) |burst| {
        stats.output_count = burst.unavailable;
        stats.candidate_pairs = burst.projections;
    }
    stats.items_per_second = suite.itemsPerSecond(config.requests, stats.mean_ns);
    if (case.adaptive) stats.work_tuning = suite.workTuningSummary(fixture.system.tuners.intake.report(), settled_before_measurement);
    return stats;
}

// The agent budget of the toggle groups' fixtures, which request no paths.
const toggle_agent_budget: usize = 8;

// One timed toggle: a change of `cells` and its nav reaction, then the revert and its
// reaction, with the change reaction's plan, remask, and patch batches.
const ToggleSample = struct {
    change: Reaction,
    // The change reaction's plan, remask, patch, connectivity seed, gather, and flood, and
    // closure candidates, resolve, mask, plan, rows, and landing.
    change_stages: [toggle_stage_count]BatchStats,
    revert: Reaction,

    fn elapsedNs(self: ToggleSample) u64 {
        return self.change.elapsed_ns + self.revert.elapsed_ns;
    }
};

// What a toggle's reactions must keep: every one-way block at its size, each closure reserve
// within its fixed ratio of the words the reaction touches (`checkOnewayReserve`), and, when
// `isolated`, no block of any other system (`checkOnewayIsolated`).
const ToggleChecks = struct {
    fixed_blocks: bool = true,
    reserve_ratio: bool = true,
    isolated: bool = false,
};

// Fails when a reaction's closure reserved past its fixed ratio: a tail over twice its
// candidates' block words plus 32 words per terminal it could number (a small piece's
// 16-word block).
fn checkOnewayReserve(stats: NavUpdateStats) !void {
    const slack = 32 * stats.closure_kb;
    if (stats.closure_tail_bound > 2 * stats.closure_candidate_words + slack) return error.ConnectivityOnewayReserveRatio;
}

// Fails when a toggle reaction relocated, landed, allocated, or freed a block, or grew or
// released the batch tail (its capacity left `tail_capacity`): a toggle in place touches only
// its own system's rows.
fn checkOnewayIsolated(fixture: *const ReactFixture, stats: NavUpdateStats, tail_capacity: usize) !void {
    if (stats.closure_landed_words != 0 or stats.closure_tail_used != 0) return error.ConnectivityOnewayBallastLanded;
    if (stats.closure_block_allocs != 0 or stats.closure_block_frees != 0) return error.ConnectivityOnewayBallastBlocks;
    if (fixture.system.graph.connectivity.closure.tail.capacity != tail_capacity) return error.ConnectivityOnewayBallastTail;
}

// Blocks `cells` (open before) and runs the nav reaction, then reopens them and runs it again.
fn runToggle(io: std.Io, fixture: *ReactFixture, cells: []const CellCoord, thread_system: ?*ThreadSystem, checks: ToggleChecks) !ToggleSample {
    const tail_capacity = fixture.system.graph.connectivity.closure.tail.capacity;
    const change = try fixture.changeAndReact(io, cells, fixture.open.blocking, thread_system);
    if (checks.isolated) try checkOnewayIsolated(fixture, change.stats, tail_capacity);
    const stats = change.stats;
    const change_stages = [toggle_stage_count]BatchStats{
        stats.plan_batch,                    stats.remask_batch,               stats.patch_batch,
        stats.conn_seed_batch,               stats.conn_gather_batch,          stats.conn_flood_batch,
        stats.conn_closure_candidates_batch, stats.conn_closure_resolve_batch, stats.conn_closure_mask_batch,
        stats.conn_closure_plan_batch,       stats.conn_closure_rows_batch,    stats.conn_closure_land_batch,
    };
    const revert = try fixture.changeAndReact(io, cells, fixture.open.walkable, thread_system);
    if (checks.isolated) try checkOnewayIsolated(fixture, revert.stats, tail_capacity);
    // A toggle and its revert never resize a one-way block.
    if (checks.fixed_blocks and (change.stats.closure_shrinks != 0 or revert.stats.closure_shrinks != 0)) return error.ConnectivityOnewayShrinkFlip;
    if (checks.reserve_ratio) {
        try checkOnewayReserve(change.stats);
        try checkOnewayReserve(revert.stats);
    }
    return .{ .change = change, .change_stages = change_stages, .revert = revert };
}

const toggle_stage_count = 12;

// The timed toggles' change and revert reactions: their times and main-thread share, printed
// under --details; and, for the workload column, the change reaction's stage shapes (each
// stage's busiest batch), its connectivity and closure summary beside the revert's flood
// nodes, and both reactions' main-thread split.
const ToggleReport = struct {
    samples: usize = 0,
    change_ns: u128 = 0,
    revert_ns: u128 = 0,
    main_ns: u128 = 0,
    // Plan, remask, patch, connectivity seed, gather, and flood, and closure candidates,
    // resolve, mask, plan, rows, and landing.
    shapes: suite.StageShapes(toggle_stage_count) = .{},
    last_change: NavUpdateStats = .{},
    revert_flood_nodes: usize = 0,
    // Summed over both reactions of every sample.
    closure_shrinks: usize = 0,
    closure_block_allocs: usize = 0,
    closure_block_frees: usize = 0,
    closure_landed_words: usize = 0,
    // The change reactions' closure rows on workers, summed.
    closure_rows_off_main_ns: u64 = 0,
    // The sample reaction with the larger closure tail bound.
    reserve: NavUpdateStats = .{},
    nav_main: suite.NavMainSummary = .{},

    fn add(self: *ToggleReport, sample: ToggleSample) void {
        const change = sample.change.stats;
        const revert = sample.revert.stats;
        self.samples += 1;
        self.change_ns += sample.change.elapsed_ns;
        self.revert_ns += sample.revert.elapsed_ns;
        self.main_ns += (sample.change.elapsed_ns -| change.off_main_stage_ns) + (sample.revert.elapsed_ns -| revert.off_main_stage_ns);
        self.nav_main.add(sample.change.elapsed_ns -| change.off_main_stage_ns, change);
        self.nav_main.add(sample.revert.elapsed_ns -| revert.off_main_stage_ns, revert);
        self.nav_main.endSample();
        self.shapes.add(sample.change_stages);
        self.last_change = change;
        self.revert_flood_nodes = revert.conn_flood_nodes;
        self.closure_shrinks += change.closure_shrinks + revert.closure_shrinks;
        self.closure_block_allocs += change.closure_block_allocs + revert.closure_block_allocs;
        self.closure_block_frees += change.closure_block_frees + revert.closure_block_frees;
        self.closure_landed_words += change.closure_landed_words + revert.closure_landed_words;
        self.closure_rows_off_main_ns += offMainNs(change.conn_closure_rows_batch);
        if (self.samples == 1 or @max(change.closure_tail_bound, revert.closure_tail_bound) > self.reserve.closure_tail_bound) {
            self.reserve = if (revert.closure_tail_bound > change.closure_tail_bound) revert else change;
        }
    }

    // The busiest plan, remask, and patch batches, the connectivity summary, and the
    // main-thread split into `stats`.
    fn summarize(self: ToggleReport, stats: *suite.RunStats, flood_tuner_workers: ?usize) void {
        const busiest = self.shapes.busiest;
        stats.nav_main = self.nav_main;
        stats.nav_plan_batch = suite.batchSummaryFromBatch(busiest[0]);
        stats.batch = suite.batchSummaryFromBatch(busiest[1]);
        stats.secondary_batch = suite.batchSummaryFromBatch(busiest[2]);
        var conn = suite.navConnSummary(self.last_change, flood_tuner_workers);
        const stage_summaries = [_]*suite.BatchSummary{ &conn.seed, &conn.gather, &conn.flood, &conn.candidates, &conn.closure_resolve, &conn.closure_mask, &conn.closure_plan, &conn.closure_rows, &conn.closure_land };
        for (stage_summaries, busiest[3..]) |summary, batch| summary.* = suite.batchSummaryFromBatch(batch);
        conn.reopen_flood_nodes = self.revert_flood_nodes;
        conn.closure_shrinks = self.closure_shrinks;
        conn.closure_block_allocs = self.closure_block_allocs;
        conn.closure_block_frees = self.closure_block_frees;
        conn.closure_landed_words = self.closure_landed_words;
        conn.closure_rows_off_main_ns = if (self.samples == 0) 0 else self.closure_rows_off_main_ns / self.samples;
        conn.closure_tail_bound = self.reserve.closure_tail_bound;
        conn.closure_tail_used = self.reserve.closure_tail_used;
        conn.closure_candidate_words = self.reserve.closure_candidate_words;
        conn.closure_kb = self.reserve.closure_kb;
        stats.nav_conn = conn;
    }

    fn print(self: ToggleReport, options: suite.Options, group_name: []const u8, item_count: usize, case: suite.BenchmarkCase) void {
        if (!options.details or self.samples == 0) return;
        const samples: u128 = self.samples * std.time.ns_per_us;
        const timed_ns = self.change_ns + self.revert_ns;
        std.debug.print("  {s} {} {s}: block={}us reopen={}us main={}us ({}%)\n", .{
            group_name,
            item_count,
            case.name,
            @as(u64, @intCast(self.change_ns / samples)),
            @as(u64, @intCast(self.revert_ns / samples)),
            @as(u64, @intCast(self.main_ns / samples)),
            @as(u64, @intCast(if (timed_ns == 0) 0 else self.main_ns * 100 / timed_ns)),
        });
    }
};

// Times `options.iterations` toggles of `cells` after `options.warmup_iterations` untimed
// ones, each toggle after an untimed retire of `ballast` when there is one. Items/s is the
// cells flipped per second.
fn runToggleSamples(io: std.Io, options: suite.Options, case: suite.BenchmarkCase, group_name: []const u8, item_count: usize, fixture: *ReactFixture, cells: []const CellCoord, thread_system: ?*ThreadSystem, checks: ToggleChecks, ballast: ?*OnewayBallast) !suite.RunStats {
    for (0..options.warmup_iterations) |_| {
        if (ballast) |chain| try chain.retire(io, fixture, thread_system);
        _ = try runToggle(io, fixture, cells, thread_system, checks);
    }
    var accumulator = suite.StatsAccumulator.init(item_count);
    var report = ToggleReport{};
    for (0..options.iterations) |_| {
        if (ballast) |chain| try chain.retire(io, fixture, thread_system);
        const sample = try runToggle(io, fixture, cells, thread_system, checks);
        accumulator.record(sample.elapsedNs(), sample.change.stats.remask_batch);
        report.add(sample);
        if (ballast) |chain| chain.addSample(sample);
    }
    report.print(options, group_name, item_count, case);
    var stats = accumulator.finish();
    report.summarize(&stats, fixtures.floodTunerWorkers(&fixture.system, case));
    stats.items_per_second = suite.itemsPerSecond(2 * cells.len, stats.mean_ns);
    return stats;
}

const SplitVariant = enum(u8) {
    // A room sealed by blocking the gap chunk of its wall.
    room,
    // A ring corridor cut, not split, by blocking one of its chunks.
    ring,
    // A one-chunk tunnel sealed by blocking its mouth chunk.
    tunnel,
};

// A chunk of a toggle fixture, in chunk coordinates.
const ChunkCoord = struct {
    x: u16,
    y: u16,
};

const SplitConfig = struct {
    variant: SplitVariant,
    edge_chunks: u16,
    side: u16,

    fn decode(item_count: usize) !SplitConfig {
        const code = try SplitCode.decode(item_count);
        if (code.levels != 1) return error.ConnectivitySplitNotOneLevel;
        if (code.edge_chunks == 0) return error.ConnectivitySplitNoEdge;
        return .{ .variant = code.variant, .edge_chunks = code.edge_chunks, .side = code.level_side };
    }

    // Chunks a side of the structure's square, its outer wall band (or the tunnel's mouth
    // and the open chunk past it) included.
    fn spanChunks(self: SplitConfig) usize {
        return switch (self.variant) {
            .room => @as(usize, self.edge_chunks) + 1,
            .ring => @as(usize, self.edge_chunks) + 3,
            .tunnel => @as(usize, self.edge_chunks) + 2,
        };
    }

    // The room's chunks, the ring's, or the tunnel's.
    fn structureChunks(self: SplitConfig) usize {
        const edge: usize = self.edge_chunks;
        return switch (self.variant) {
            .room => edge * edge,
            .ring => 4 * edge + 4,
            .tunnel => edge,
        };
    }

    // Whether `cell` lies in the room, in the ring (its gap chunk included), or in the tunnel
    // (its mouth excluded).
    fn inStructure(self: SplitConfig, cell: CellCoord, chunk_tiles: usize) bool {
        const chunk_x = cell.x / chunk_tiles;
        const chunk_y = cell.y / chunk_tiles;
        const edge: usize = self.edge_chunks;
        return switch (self.variant) {
            .room => chunk_x < edge and chunk_y < edge,
            .ring => chunk_x < edge + 2 and chunk_y < edge + 2 and
                (chunk_x == 0 or chunk_y == 0 or chunk_x == edge + 1 or chunk_y == edge + 1),
            .tunnel => chunk_x < edge and chunk_y == 0,
        };
    }

    fn inGapChunk(self: SplitConfig, cell: CellCoord, chunk_tiles: usize) bool {
        const gap = self.gapChunk();
        return cell.x / chunk_tiles == gap.x and cell.y / chunk_tiles == gap.y;
    }

    fn gapChunk(self: SplitConfig) ChunkCoord {
        return switch (self.variant) {
            // Mid-height in the room's wall column.
            .room => .{ .x = self.edge_chunks, .y = self.edge_chunks / 2 },
            // Mid-height in the ring's west side.
            .ring => .{ .x = 0, .y = (self.edge_chunks + 2) / 2 },
            // The tunnel's east mouth.
            .tunnel => .{ .x = self.edge_chunks, .y = 0 },
        };
    }

    // The solid chunks: the room's wall band but its gap, the ring's inner block and its
    // outer wall band, or the row below the tunnel and its mouth. The level border closes the
    // structure's west and north.
    fn solidChunks(self: SplitConfig, allocator: std.mem.Allocator) ![]ChunkCoord {
        var chunks: std.ArrayList(ChunkCoord) = .empty;
        errdefer chunks.deinit(allocator);
        if (self.variant == .tunnel) {
            for (0..self.edge_chunks + 1) |x| try chunks.append(allocator, .{ .x = @intCast(x), .y = 1 });
            return chunks.toOwnedSlice(allocator);
        }
        // The outer band: the column and the row just past the room or the ring.
        const band: u16 = switch (self.variant) {
            .room => self.edge_chunks,
            .ring => self.edge_chunks + 2,
            .tunnel => unreachable,
        };
        const gap = self.gapChunk();
        for (0..band + 1) |y| {
            const chunk = ChunkCoord{ .x = band, .y = @intCast(y) };
            if (self.variant == .room and chunk.x == gap.x and chunk.y == gap.y) continue;
            try chunks.append(allocator, chunk);
        }
        for (0..band) |x| try chunks.append(allocator, .{ .x = @intCast(x), .y = band });
        if (self.variant == .ring) {
            for (1..band - 1) |y| {
                for (1..band - 1) |x| try chunks.append(allocator, .{ .x = @intCast(x), .y = @intCast(y) });
            }
        }
        return chunks.toOwnedSlice(allocator);
    }
};

// Every cell of `chunks`, chunk by chunk in row-major order.
// The chunks lie inside the level, so their cells fit `u16`.
fn chunkCells(allocator: std.mem.Allocator, chunks: []const ChunkCoord, chunk_tiles: u16) ![]CellCoord {
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
fn toggleSizeConfig(side: usize, levels: usize, links: usize, participant_count: usize, batch: suite.NavBatch) suite.NavSizeConfig {
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

// The split fixture on a walkable level: the structure's solid chunks written, no requests.
fn initSplitFixture(allocator: std.mem.Allocator, io: std.Io, config: SplitConfig, capacity: PathfindingCapacity, thread_system: ?*ThreadSystem) !ReactFixture {
    var open = try buildOpenWorld(allocator, io, config.side, 1);
    errdefer open.world.deinit();
    if (config.spanChunks() * open.world.chunk_size_tiles > config.side) return error.ConnectivitySplitStructureTooLarge;
    const solid_chunks = try config.solidChunks(allocator);
    defer allocator.free(solid_chunks);
    const solid = try chunkCells(allocator, solid_chunks, open.world.chunk_size_tiles);
    defer allocator.free(solid);
    try writeLevelZeroCells(&open, solid, open.blocking);
    try checkSplitTopology(allocator, &open.world, config);
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const requests = try allocator.alloc(PathRequest, 0);
    errdefer allocator.free(requests);
    return assembleReactFixture(allocator, &open, &data, requests, capacity, thread_system);
}

// The split structure's open cells: level 0's walkable cells, the gap chunk blocked when
// `gap_blocked`; a flood stops at the first open cell outside the structure.
const SplitFloodCells = struct {
    world: *const WorldSystem,
    config: SplitConfig,
    gap_blocked: bool,

    pub fn open(self: SplitFloodCells, x: u32, y: u32) bool {
        const cell = CellCoord{ .x = @intCast(x), .y = @intCast(y) };
        if (self.world.levelBlocksMovement(0, cell.x, cell.y)) return false;
        return !(self.gap_blocked and self.config.inGapChunk(cell, self.world.chunk_size_tiles));
    }

    pub fn stop(self: SplitFloodCells, x: u32, y: u32) bool {
        return !self.config.inStructure(.{ .x = @intCast(x), .y = @intCast(y) }, self.world.chunk_size_tiles);
    }
};

// Untimed: a 4-connected flood over level 0's open cells from the level origin, which lies in
// the room or the ring. The corner rule lets a diagonal step only through two open orthogonal
// cells, so 4-connected components equal the nav's.
fn floodSplitStructure(allocator: std.mem.Allocator, world: *const WorldSystem, config: SplitConfig, gap_blocked: bool) !fixtures.Flood {
    if (world.levelBlocksMovement(0, 0, 0)) return error.ConnectivitySplitSeedBlocked;
    var reached = try std.DynamicBitSetUnmanaged.initEmpty(allocator, @as(usize, world.width) * world.height);
    defer reached.deinit(allocator);
    return fixtures.flood4(allocator, world.width, world.height, .{ 0, 0 }, SplitFloodCells{ .world = world, .config = config, .gap_blocked = gap_blocked }, &reached);
}

// Fails unless the layout has the shape its variant claims. Room: with the gap blocked the
// room's cells reach one another and nothing outside; with it open they reach outside. Ring:
// with the gap blocked every other ring cell reaches every other and nothing outside.
fn checkSplitTopology(allocator: std.mem.Allocator, world: *const WorldSystem, config: SplitConfig) !void {
    const chunk_cells = @as(usize, world.chunk_size_tiles) * world.chunk_size_tiles;
    const sealed = try floodSplitStructure(allocator, world, config, true);
    switch (config.variant) {
        .room, .tunnel => {
            if (sealed.stopped) return error.ConnectivitySplitRoomNotSealed;
            if (sealed.reached != config.structureChunks() * chunk_cells) return error.ConnectivitySplitRoomNotOneArea;
            const opened = try floodSplitStructure(allocator, world, config, false);
            if (!opened.stopped) return error.ConnectivitySplitRoomGapClosed;
        },
        .ring => {
            if (sealed.stopped) return error.ConnectivitySplitRingNotEnclosed;
            if (sealed.reached != (config.structureChunks() - 1) * chunk_cells) return error.ConnectivitySplitRingSplit;
        },
    }
}

fn runConnectivitySplitCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const config = try SplitConfig.decode(item_count);
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count = fixtures.participantCount(thread_ptr);
    // The gap chunk's cells.
    const size_config = toggleSizeConfig(config.side, 1, 0, participant_count, .{ .mark_chunks = default_chunk_size_tiles * default_chunk_size_tiles, .links = 0, .keys = toggle_batch_keys });
    try suite.checkNavSize(connectivity_split_group.name, item_count, case, size_config);

    var fixture = try initSplitFixture(allocator, io, config, suite.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    try suite.checkNavBytes(connectivity_split_group.name, item_count, size_config, &fixture.system);
    const gap = try chunkCells(allocator, &.{config.gapChunk()}, fixture.open.world.chunk_size_tiles);
    defer allocator.free(gap);
    try fixture.changed.ensureTotalCapacity(allocator, gap.len);
    fixtures.setNavTuners(&fixture.system, case);

    var stats = try runToggleSamples(io, options, case, connectivity_split_group.name, item_count, &fixture, gap, thread_ptr, .{}, null);
    try suite.checkNavBytes(connectivity_split_group.name, item_count, size_config, &fixture.system);
    stats.output_count = gap.len;
    stats.candidate_pairs = config.structureChunks();
    return stats;
}

const OnewayVariant = enum(u8) {
    // Many chains; the first chain's last room toggles.
    locality,
    // One chain; its last room toggles.
    tail,
    // One chain; its first room toggles.
    head,
    // One chain; a far level-0 cell outside every room toggles.
    far_dig,
    // One chain cut once to its last `oneway_shrunk_live` rooms; its last room toggles.
    shrunk,
    // Every room links to a hub that links to the last room, which toggles.
    fan,
    // Many chains whose heads share one root through the open wall cells between them; the
    // toggle fills every such cell in one reaction (the systems part) and reopens them in
    // the next (one dense opening merges them).
    dense,
    // The locality chains plus a ballast chain on level 1, retired before every sample.
    ballast,
};

// One-way fixture: a `oneway_side`² world of `oneway_levels` levels, each level a 2-cell
// lattice of blocking cells around one-cell rooms (its even cells). The toggled chain's end
// group, its `oneway_site_rooms` rooms at the toggled end, takes the first room row of
// level 0's chunk `oneway_site_chunk`; no other room of that chunk or its orthogonal
// neighbours holds a link endpoint, so every config's toggle patches the same content. Every
// other chain room takes the next free room level by level in snaking rows, so consecutive
// rooms mostly lie 2 cells apart.
const oneway_side: u16 = 256;
const oneway_levels: u16 = 2;
const oneway_rooms_per_row: usize = oneway_side / 2;
const oneway_site_rooms: usize = 8;
const oneway_site_chunk: ChunkCoord = .{ .x = 1, .y = 1 };
// Rooms the shrunk variant's cut leaves on its chain.
const oneway_shrunk_live: usize = 64;
// Rooms per chain of the dense variant: its systems' merged terminals stay off a power of
// two, so the merged block keeps slack for the pieces a fill splits off.
const oneway_dense_terminals: usize = 96;
// The dense variant's heads: level-0 rooms side by side on the last room row.
const oneway_dense_row: u16 = oneway_side - 2;

comptime {
    // The end group fits the first room row of one chunk.
    std.debug.assert(2 * oneway_site_rooms <= default_chunk_size_tiles);
}

const OnewayRoom = struct {
    level: u16,
    cell: CellCoord,
};

// The chunk keys a marks batch changing `rooms` patches at most: each distinct chunk they
// sit in with its four neighbours.
fn roomBatchKeys(allocator: std.mem.Allocator, rooms: []const OnewayRoom) !usize {
    const chunks = try allocator.alloc(u64, rooms.len);
    defer allocator.free(chunks);
    const chunk_edge = default_chunk_size_tiles;
    for (rooms, chunks) |room, *chunk| {
        chunk.* = (@as(u64, room.level) << 32) | (@as(u64, room.cell.y / chunk_edge) << 16) | (room.cell.x / chunk_edge);
    }
    std.mem.sort(u64, chunks, {}, std.sort.asc(u64));
    var distinct: usize = 0;
    for (chunks, 0..) |chunk, index| {
        if (index == 0 or chunk != chunks[index - 1]) distinct += 1;
    }
    return distinct * toggle_batch_keys;
}

// Whether a level-0 chunk is the site chunk or one of its orthogonal neighbours.
fn inOnewaySite(level: u16, cell: CellCoord) bool {
    if (level != 0) return false;
    const chunk_x = cell.x / default_chunk_size_tiles;
    const chunk_y = cell.y / default_chunk_size_tiles;
    const dx = @abs(@as(i32, chunk_x) - oneway_site_chunk.x);
    const dy = @abs(@as(i32, chunk_y) - oneway_site_chunk.y);
    return dx + dy <= 1;
}

// Chain `index`'s head in the dense variant.
fn denseHead(index: usize) OnewayRoom {
    std.debug.assert(index < oneway_rooms_per_row);
    // In range: one room row of level 0.
    return .{ .level = 0, .cell = .{ .x = @intCast(2 * index), .y = oneway_dense_row } };
}

// The wall cells joining the dense variant's `systems` heads: between each head and the next.
fn denseWalls(allocator: std.mem.Allocator, systems: usize) ![]CellCoord {
    const walls = try allocator.alloc(CellCoord, systems - 1);
    for (walls, 0..) |*wall, index| wall.* = .{ .x = denseHead(index).cell.x + 1, .y = oneway_dense_row };
    return walls;
}

fn isDenseHead(room: OnewayRoom, systems: usize) bool {
    return room.level == 0 and room.cell.y == oneway_dense_row and room.cell.x < 2 * systems;
}

fn onewaySiteRoom(index: usize) OnewayRoom {
    std.debug.assert(index < oneway_site_rooms);
    // In range: the site chunk's first room row lies inside level 0.
    return .{ .level = 0, .cell = .{
        .x = @intCast(@as(usize, oneway_site_chunk.x) * default_chunk_size_tiles + 2 * index),
        .y = oneway_site_chunk.y * default_chunk_size_tiles,
    } };
}

// The rooms outside the site in fill order: level by level, snaking rows.
fn onewayFreeRooms(allocator: std.mem.Allocator) ![]OnewayRoom {
    var rooms: std.ArrayList(OnewayRoom) = .empty;
    errdefer rooms.deinit(allocator);
    for (0..oneway_levels) |level_index| {
        for (0..oneway_rooms_per_row) |row| {
            for (0..oneway_rooms_per_row) |step| {
                const column = if (row % 2 == 0) step else oneway_rooms_per_row - 1 - step;
                // In range: rows and columns of rooms inside the `oneway_side`² levels.
                const room = OnewayRoom{ .level = @intCast(level_index), .cell = .{ .x = @intCast(2 * column), .y = @intCast(2 * row) } };
                if (inOnewaySite(room.level, room.cell)) continue;
                try rooms.append(allocator, room);
            }
        }
    }
    return rooms.toOwnedSlice(allocator);
}

const OnewayConfig = struct {
    variant: OnewayVariant,
    terminals: usize,
    systems: usize,

    fn decode(item_count: usize) !OnewayConfig {
        const code = try OnewayCode.decode(item_count);
        const variant = code.variant;
        const terminals = code.terminals_per_system;
        const systems = code.systems;
        if (terminals < oneway_site_rooms or systems == 0) return error.ConnectivityOnewayChainTooShort;
        if (variant != .locality and variant != .dense and variant != .ballast and systems != 1) return error.ConnectivityOnewayOneChainOnly;
        if (variant == .dense and (systems < 2 or systems > oneway_rooms_per_row)) return error.ConnectivityOnewayDenseSystems;
        // The cut must leave a block at most a quarter full.
        if (variant == .shrunk and terminals <= 4 * oneway_shrunk_live) return error.ConnectivityOnewayShrunkTooSmall;
        return .{ .variant = variant, .terminals = terminals, .systems = systems };
    }

    fn rooms(self: OnewayConfig) usize {
        return self.terminals * self.systems;
    }

    fn links(self: OnewayConfig) usize {
        return (self.terminals - 1) * self.systems;
    }

    // The ballast chain's rooms (none outside the ballast variant): the smallest power of two
    // whose block holds over twice the chains' words, so its block alone outweighs every live
    // one and any cost it moved into the timed toggle would show.
    fn ballastRooms(self: OnewayConfig) !usize {
        if (self.variant != .ballast) return 0;
        const chain_words = self.systems * try onewayBlockWords(self.terminals);
        var ballast: usize = oneway_site_rooms;
        while (try onewayBlockWords(ballast) <= 2 * chain_words) ballast *= 2;
        return ballast;
    }

    // The one-way links of every chain and the ballast.
    fn allLinks(self: OnewayConfig) !usize {
        const ballast = try self.ballastRooms();
        return self.links() + if (ballast == 0) 0 else ballast - 1;
    }

    // Chain 0's room `index`: its end group in the site (the first rooms for the head
    // variant, else the last), its other rooms the next free rooms.
    fn firstChainSiteIndex(self: OnewayConfig, index: usize) ?usize {
        const site_start = if (self.variant == .head) 0 else self.terminals - oneway_site_rooms;
        if (index < site_start or index >= site_start + oneway_site_rooms) return null;
        return index - site_start;
    }

    // The toggled level-0 cell: chain 0's first room (head), its last room (locality,
    // tail), a far room in a corner chunk no chain room reaches (far dig), or the dense
    // variant's first wall (it toggles every wall).
    fn toggleCell(self: OnewayConfig) CellCoord {
        return switch (self.variant) {
            .locality, .tail, .shrunk, .fan, .ballast => onewaySiteRoom(oneway_site_rooms - 1).cell,
            .head => onewaySiteRoom(0).cell,
            .far_dig => pocketDigCell(oneway_side),
            .dense => .{ .x = denseHead(0).cell.x + 1, .y = oneway_dense_row },
        };
    }
};

// The words of the one-way block a system of `terminals` terminals holds once built or
// regrown.
fn onewayBlockWords(terminals: usize) !usize {
    return connectivity.blockWords(try connectivity.boundCap(terminals));
}

// The ballast variant's chain: `config.ballastRooms()` rooms on level 1 after every chain
// room, in fill order.
fn onewayBallastRooms(allocator: std.mem.Allocator, config: OnewayConfig) ![]OnewayRoom {
    const free_rooms = try onewayFreeRooms(allocator);
    defer allocator.free(free_rooms);
    // The chains took the free rooms before `start`; chain 0's end group sits in the site.
    var start = config.rooms() - oneway_site_rooms;
    while (start < free_rooms.len and free_rooms[start].level == 0) start += 1;
    const count = try config.ballastRooms();
    if (start + count > free_rooms.len) return error.ConnectivityOnewayRoomsTooFew;
    return allocator.dupe(OnewayRoom, free_rooms[start..][0..count]);
}

// The ballast chain on `ballast_level`, retired (every room closed) before each timed toggle:
// its reopen builds and lands its block, its close frees it, so the timed toggle runs right
// after a block that outweighs every live one came and went.
const OnewayBallast = struct {
    const ballast_level: u16 = 1;

    cells: []const CellCoord,
    // What `checkNavBytes` charges the nav, checked after every retire.
    size_config: suite.NavSizeConfig,
    item_count: usize,
    // The ballast's block words, which its reopen lands and its close frees.
    block_words: usize,
    // The last retire's reopen and close reactions.
    reopen: Reaction = .{ .elapsed_ns = 0, .stats = .{} },
    close: Reaction = .{ .elapsed_ns = 0, .stats = .{} },
    retires: usize = 0,
    // The timed block reactions' split, summed over `samples`: the reaction, its main-thread
    // reserve section, its closure stages (candidates, resolve, mask, plan, rows), and its
    // landing stage.
    samples: usize = 0,
    close_ns: u128 = 0,
    reserve_ns: u128 = 0,
    closure_stages_ns: u128 = 0,
    land_ns: u128 = 0,

    // Reopens the ballast's rooms and closes them, one untimed reaction each. Fails when the
    // reopen does not land exactly the ballast's one block or the close does not free exactly
    // it, when the block holds no more than twice the live words it left, or when the nav
    // holds more bytes than charged.
    fn retire(self: *OnewayBallast, io: std.Io, fixture: *ReactFixture, thread_system: ?*ThreadSystem) !void {
        self.reopen = try untimedReaction(io, fixture, self.cells, fixture.open.walkable, thread_system);
        const reopen = self.reopen.stats;
        if (reopen.closure_tail_used != self.block_words or reopen.closure_landed_words != self.block_words or reopen.closure_block_allocs != 1) return error.ConnectivityOnewayBallastLanding;
        try self.closeAll(io, fixture, thread_system);
        self.retires += 1;
        const retired_words = reopen.closure_live_words -| self.close.stats.closure_live_words;
        if (self.close.stats.closure_block_frees != 1 or retired_words != self.block_words) return error.ConnectivityOnewayBallastFree;
        if (retired_words <= 2 * self.close.stats.closure_live_words) return error.ConnectivityOnewayBallastTooSmall;
        try suite.checkNavBytes(connectivity_oneway_group.name, self.item_count, self.size_config, &fixture.system);
    }

    // Closes every ballast room in one untimed reaction.
    fn closeAll(self: *OnewayBallast, io: std.Io, fixture: *ReactFixture, thread_system: ?*ThreadSystem) !void {
        self.close = try untimedReaction(io, fixture, self.cells, fixture.open.blocking, thread_system);
    }

    // Sets the ballast's rooms to `tile` in one reaction, leaving every tuner as it was, so
    // it never trains the timed reactions' stages.
    fn untimedReaction(io: std.Io, fixture: *ReactFixture, cells: []const CellCoord, tile: TileId, thread_system: ?*ThreadSystem) !Reaction {
        const tuners = fixture.system.tuners;
        defer fixture.system.tuners = tuners;
        return fixture.changeLevelAndReact(io, ballast_level, cells, tile, thread_system);
    }

    // Adds a timed sample's block reaction, which ran right after the last retire.
    fn addSample(self: *OnewayBallast, sample: ToggleSample) void {
        const change = sample.change.stats;
        self.samples += 1;
        self.close_ns += sample.change.elapsed_ns;
        self.reserve_ns += change.main.reserve_ns;
        inline for (.{ change.conn_closure_candidates_batch, change.conn_closure_resolve_batch, change.conn_closure_mask_batch, change.conn_closure_plan_batch, change.conn_closure_rows_batch }) |batch| {
            self.closure_stages_ns += batch.batch_duration_ns;
        }
        self.land_ns += change.conn_closure_land_batch.batch_duration_ns;
    }

    // The last retire: the reopen's landing (its shape, time, and words) and its tail bound
    // and use, and the close's main-thread closure time (it holds the free) and the words it
    // freed; then the timed block reactions' split (the rest is everything outside the
    // reserve, closure, and landing). Printed under --details.
    fn print(self: OnewayBallast, options: suite.Options, case: suite.BenchmarkCase) void {
        if (!options.details or self.retires == 0) return;
        const reopen = self.reopen.stats;
        const close = self.close.stats;
        var land_shape = suite.StageShapes(1){};
        land_shape.add(.{reopen.conn_closure_land_batch});
        var land_buffer: [48]u8 = undefined;
        const land = reopen.conn_closure_land_batch;
        std.debug.print("  {s} {} {s}: ballast rooms={} block_words={} retires={} reopen={}us reopen_land={s} reopen_land_ns={} landed_words={} tail_bound={} tail_used={} tail_ratio={d:.2} close={}us close_closure_main={}ns freed_words={} left_live_words={}\n", .{
            connectivity_oneway_group.name,
            self.item_count,
            case.name,
            self.cells.len,
            self.block_words,
            self.retires,
            self.reopen.elapsed_ns / std.time.ns_per_us,
            land_shape.label(0, &land_buffer),
            land.batch_duration_ns,
            reopen.closure_landed_words,
            reopen.closure_tail_bound,
            reopen.closure_tail_used,
            if (reopen.closure_tail_used == 0) 0.0 else @as(f64, @floatFromInt(reopen.closure_tail_bound)) / @as(f64, @floatFromInt(reopen.closure_tail_used)),
            self.close.elapsed_ns / std.time.ns_per_us,
            close.main.closure_ns,
            reopen.closure_live_words -| close.closure_live_words,
            close.closure_live_words,
        });
        if (self.samples == 0) return;
        const samples: u128 = self.samples;
        const parts = self.reserve_ns + self.closure_stages_ns + self.land_ns;
        std.debug.print("  {s} {} {s}: timed block split total={}ns reserve={}ns closure_stages={}ns land={}ns rest={}ns\n", .{
            connectivity_oneway_group.name,
            self.item_count,
            case.name,
            @as(u64, @intCast(self.close_ns / samples)),
            @as(u64, @intCast(self.reserve_ns / samples)),
            @as(u64, @intCast(self.closure_stages_ns / samples)),
            @as(u64, @intCast(self.land_ns / samples)),
            @as(u64, @intCast((self.close_ns -| parts) / samples)),
        });
    }
};

// Every cell of one level with an odd coordinate: the lattice walls.
fn onewayWallCells(allocator: std.mem.Allocator) ![]CellCoord {
    var walls: std.ArrayList(CellCoord) = .empty;
    errdefer walls.deinit(allocator);
    for (0..oneway_side) |y| {
        for (0..oneway_side) |x| {
            if (x % 2 == 0 and y % 2 == 0) continue;
            // Inside the `oneway_side`² level.
            try walls.append(allocator, .{ .x = @intCast(x), .y = @intCast(y) });
        }
    }
    return walls.toOwnedSlice(allocator);
}

// Fails when `room` lies in the far toggle's chunk or an orthogonal neighbour of it.
fn checkOnewayFarRoom(room: OnewayRoom) !void {
    if (room.level != 0) return;
    const far = pocketDigCell(oneway_side);
    const dx = @abs(@as(i32, room.cell.x / default_chunk_size_tiles) - far.x / default_chunk_size_tiles);
    const dy = @abs(@as(i32, room.cell.y / default_chunk_size_tiles) - far.y / default_chunk_size_tiles);
    if (dx + dy <= 1) return error.ConnectivityOnewayChainReachesFarRoom;
}

// Every system's rooms in order, `config.terminals` each: chain 0's end group in the site,
// every other room the next free room.
fn onewayRooms(allocator: std.mem.Allocator, config: OnewayConfig) ![]OnewayRoom {
    const free_rooms = try onewayFreeRooms(allocator);
    defer allocator.free(free_rooms);
    if (config.rooms() - oneway_site_rooms > free_rooms.len) return error.ConnectivityOnewayRoomsTooFew;
    const rooms = try allocator.alloc(OnewayRoom, config.rooms());
    errdefer allocator.free(rooms);
    var next_free: usize = 0;
    for (0..config.systems) |system_index| {
        // Chain 0's index at the toggled end: its first link's source for head, else its
        // last link's target.
        const toggle_index = if (config.variant == .head) 0 else config.terminals - 1;
        for (0..config.terminals) |index| {
            const site_index = if (system_index == 0 and config.variant != .dense) config.firstChainSiteIndex(index) else null;
            const room = if (config.variant == .dense and index == 0) denseHead(system_index) else if (site_index) |site| onewaySiteRoom(site) else free: {
                while (config.variant == .dense and isDenseHead(free_rooms[next_free], config.systems)) next_free += 1;
                defer next_free += 1;
                break :free free_rooms[next_free];
            };
            if (config.variant == .far_dig) try checkOnewayFarRoom(room);
            if (system_index == 0 and index == toggle_index and config.variant != .far_dig and config.variant != .dense) {
                const toggle_cell = config.toggleCell();
                if (room.level != 0 or room.cell.x != toggle_cell.x or room.cell.y != toggle_cell.y) return error.ConnectivityOnewayToggleNotChainEnd;
            }
            rooms[system_index * config.terminals + index] = room;
        }
    }
    return rooms;
}

// One one-way teleport from room `from` to room `to`.
fn addOnewayLink(world: *WorldSystem, from: OnewayRoom, to: OnewayRoom) !void {
    try world.addLevelLink(.{
        .kind = .teleport,
        .level_a = from.level,
        .cell_a = from.cell,
        .level_b = to.level,
        .cell_b = to.cell,
        .traversal_cost = 1,
        .bidirectional = false,
    });
}

fn initOnewayFixture(allocator: std.mem.Allocator, io: std.Io, config: OnewayConfig, rooms: []const OnewayRoom, ballast: []const OnewayRoom, capacity: PathfindingCapacity, thread_system: ?*ThreadSystem) !ReactFixture {
    var open = try buildOpenWorld(allocator, io, oneway_side, oneway_levels);
    errdefer open.world.deinit();
    std.debug.assert(open.world.chunk_size_tiles == default_chunk_size_tiles);
    {
        const walls = try onewayWallCells(allocator);
        defer allocator.free(walls);
        for (0..oneway_levels) |level_index| try writeLevelCells(&open, @intCast(level_index), walls, open.blocking);
    }
    if (config.variant == .dense) {
        // The heads' joining walls start open: one root, one system.
        const walls = try denseWalls(allocator, config.systems);
        defer allocator.free(walls);
        try writeLevelCells(&open, 0, walls, open.walkable);
    }
    std.debug.assert(rooms.len == config.rooms());
    for (0..config.systems) |system_index| {
        const system_rooms = rooms[system_index * config.terminals ..][0..config.terminals];
        // A chain joins each room to the next; a fan joins each room to its hub, the next to
        // last room, and the hub to the last room.
        const hub = config.terminals - 2;
        for (system_rooms[1..], 0..) |room, previous| {
            const from = system_rooms[previous];
            const to = if (config.variant == .fan and previous < hub) system_rooms[hub] else room;
            try addOnewayLink(&open.world, from, to);
        }
    }
    std.debug.assert(ballast.len == try config.ballastRooms());
    if (ballast.len != 0) {
        for (ballast[1..], 0..) |room, previous| try addOnewayLink(&open.world, ballast[previous], room);
    }
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const requests = try allocator.alloc(PathRequest, 0);
    errdefer allocator.free(requests);
    return assembleReactFixture(allocator, &open, &data, requests, capacity, thread_system);
}

// Closes `rooms` (level-0 rooms of one chain) in one untimed nav reaction.
fn cutOnewayChain(allocator: std.mem.Allocator, io: std.Io, fixture: *ReactFixture, rooms: []const OnewayRoom, thread_system: ?*ThreadSystem) !void {
    const cells = try allocator.alloc(CellCoord, rooms.len);
    defer allocator.free(cells);
    for (rooms, cells) |room, *cell| {
        if (room.level != 0) return error.ConnectivityOnewayCutOffFloor;
        cell.* = room.cell;
    }
    try fixture.changed.ensureTotalCapacity(allocator, cells.len);
    const cut = try fixture.changeAndReact(io, cells, fixture.open.blocking, thread_system);
    if (cut.stats.closure_shrinks != 1) return error.ConnectivityOnewayCutNoShrink;
    try checkOnewayReserve(cut.stats);
}

fn runConnectivityOnewayCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const config = try OnewayConfig.decode(item_count);
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count = fixtures.participantCount(thread_ptr);
    const rooms = try onewayRooms(allocator, config);
    defer allocator.free(rooms);
    const ballast_rooms = if (config.variant == .ballast) try onewayBallastRooms(allocator, config) else try allocator.alloc(OnewayRoom, 0);
    defer allocator.free(ballast_rooms);
    // The toggle, the dense variant's walls, the shrunk variant's cut, or the ballast's retire,
    // whichever writes the most cells and patches the most chunks.
    const cut_rooms = if (config.variant == .shrunk) config.terminals - oneway_shrunk_live else 0;
    const batch = suite.NavBatch{
        .mark_chunks = @max(1, @max(config.systems, cut_rooms, ballast_rooms.len)),
        .links = 0,
        .keys = @max(toggle_batch_keys, if (config.variant == .dense)
            config.systems * toggle_batch_keys
        else if (config.variant == .shrunk)
            try roomBatchKeys(allocator, rooms[0..cut_rooms])
        else if (config.variant == .ballast)
            try roomBatchKeys(allocator, ballast_rooms)
        else
            toggle_batch_keys),
    };
    var size_config = toggleSizeConfig(oneway_side, oneway_levels, try config.allLinks(), participant_count, batch);
    // A system is one chain or fan of rooms; the dense variant's opening merges every one.
    size_config.oneway_system_terminals = if (config.variant == .dense) config.rooms() else @max(config.terminals, ballast_rooms.len);
    try suite.checkNavSize(connectivity_oneway_group.name, item_count, case, size_config);

    var fixture = try initOnewayFixture(allocator, io, config, rooms, ballast_rooms, suite.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    try suite.checkNavBytes(connectivity_oneway_group.name, item_count, size_config, &fixture.system);
    // One toggled cell, or the dense variant's walls.
    const dense_walls: []CellCoord = if (config.variant == .dense) try denseWalls(allocator, config.systems) else &.{};
    defer allocator.free(dense_walls);
    const toggle_cell = config.toggleCell();
    const cells = if (config.variant == .dense) dense_walls else &[_]CellCoord{toggle_cell};
    const ballast_cells = try allocator.alloc(CellCoord, ballast_rooms.len);
    defer allocator.free(ballast_cells);
    for (ballast_rooms, ballast_cells) |room, *cell| {
        std.debug.assert(room.level == OnewayBallast.ballast_level);
        cell.* = room.cell;
    }
    try fixture.changed.ensureTotalCapacity(allocator, @max(cells.len, ballast_cells.len));
    fixtures.setNavTuners(&fixture.system, case);
    if (config.variant == .shrunk) try cutOnewayChain(allocator, io, &fixture, rooms[0 .. config.terminals - oneway_shrunk_live], thread_ptr);
    // The ballast starts retired: every sample reopens it first.
    var ballast = OnewayBallast{ .cells = ballast_cells, .size_config = size_config, .item_count = item_count, .block_words = if (ballast_cells.len == 0) 0 else try onewayBlockWords(ballast_cells.len) };
    if (config.variant == .ballast) try ballast.closeAll(io, &fixture, thread_ptr);

    // The dense variant's fill and reopen resize blocks and reserve the merged block the
    // opening can create: its ratio is what the variant measures.
    const checks: ToggleChecks = switch (config.variant) {
        .dense => .{ .fixed_blocks = false, .reserve_ratio = false },
        .ballast => .{ .isolated = true },
        else => .{},
    };
    var stats = try runToggleSamples(io, options, case, connectivity_oneway_group.name, item_count, &fixture, cells, thread_ptr, checks, if (config.variant == .ballast) &ballast else null);
    ballast.print(options, case);
    try suite.checkNavBytes(connectivity_oneway_group.name, item_count, size_config, &fixture.system);
    stats.output_count = config.links();
    stats.candidate_pairs = config.rooms();
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
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count = fixtures.participantCount(thread_ptr);
    // Every sample adds a batch, so the size check holds at the most pads the run holds.
    const samples = options.warmup_iterations + options.iterations;
    const peak_pads = config.padsAfter(samples);
    // A timed batch's pads and their endpoint chunks; the probe preload is in the build.
    var size_config = toggleSizeConfig(link_fold_side, link_fold_levels, peak_pads, participant_count, .{ .mark_chunks = 0, .links = link_fold_batch, .keys = 2 * link_fold_batch });
    // Every pad is bidirectional.
    size_config.oneway_links = 0;
    try suite.checkNavSize(link_fold_group.name, item_count, case, size_config);

    var prng = std.Random.DefaultPrng.init(random_pad_seed);
    const random = prng.random();
    const probe_pairs = config.probePairs(samples);
    var fixture = try initLinkFoldFixture(allocator, io, random, config, probe_pairs, suite.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    try suite.checkNavBytes(link_fold_group.name, item_count, size_config, &fixture.system);
    fixtures.setNavTuners(&fixture.system, case);
    var batch: usize = 0;
    for (0..options.warmup_iterations) |_| {
        _ = try foldPadBatch(io, &fixture, random, config, probe_pairs, batch, thread_ptr);
        batch += 1;
    }
    var accumulator = suite.StatsAccumulator.init(item_count);
    var report = LinkFoldReport{};
    for (0..options.iterations) |_| {
        const sample = try foldPadBatch(io, &fixture, random, config, probe_pairs, batch, thread_ptr);
        batch += 1;
        accumulator.record(sample.reaction.elapsed_ns, sample.reaction.stats.patch_batch);
        report.add(sample, sample.reaction.stats.plan_batch, sample.reaction.stats.patch_batch, fixture.open.world.levelLinks().len);
    }
    const pads_held = fixture.open.world.levelLinks().len;
    if (pads_held != peak_pads) return error.LinkFoldDrift;
    report.print(options, link_fold_group.name, item_count, case);
    try suite.checkNavBytes(link_fold_group.name, item_count, size_config, &fixture.system);
    var stats = accumulator.finish();
    stats.output_count = pads_held;
    stats.candidate_pairs = report.chunks_patched;
    stats.nav_main = report.stages.nav_main;
    stats.items_per_second = suite.itemsPerSecond(link_fold_batch, stats.mean_ns);
    return stats;
}

// The link-fold world, with no requests: `config.pads` random pads off the first
// `probe_pairs` probe chunk pairs, and `config.preload` pads joining each pair.
fn initLinkFoldFixture(allocator: std.mem.Allocator, io: std.Io, random: std.Random, config: LinkFoldConfig, probe_pairs: usize, capacity: PathfindingCapacity, thread_system: ?*ThreadSystem) !ReactFixture {
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
    const chunks_x: usize = world.chunksX();
    const chunks_y: usize = world.chunksY();
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
fn foldPadBatch(io: std.Io, fixture: *ReactFixture, random: std.Random, config: LinkFoldConfig, probe_pairs: usize, batch: usize, thread_system: ?*ThreadSystem) !LinkFoldSample {
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

// The timed link-fold reactions' plan, patch, and connectivity gather shapes and main-thread
// share and split, the chunks the last reaction patched, the endpoints of the chunks the
// reactions touched summed with those chunks, and the pads held after each reaction, summed.
const LinkFoldReport = struct {
    stages: ReactionStages = .{},
    chunks_patched: usize = 0,
    touched_chunks: usize = 0,
    touched_endpoints: usize = 0,
    pads_held: usize = 0,

    fn add(self: *LinkFoldReport, sample: LinkFoldSample, plan: BatchStats, patch: BatchStats, pads_held: usize) void {
        self.stages.add(sample.reaction, .{ plan, patch, sample.reaction.stats.conn_gather_batch });
        self.chunks_patched = sample.reaction.stats.chunks_patched;
        self.touched_chunks += sample.touched_chunks;
        self.touched_endpoints += sample.touched_endpoints;
        self.pads_held += pads_held;
    }

    fn print(self: LinkFoldReport, options: suite.Options, group_name: []const u8, item_count: usize, case: suite.BenchmarkCase) void {
        const stages = self.stages;
        if (!options.details or stages.timed_ns == 0) return;
        var shapes: [3][48]u8 = undefined;
        const labels = stages.labels(&shapes);
        var main_buffer: [320]u8 = undefined;
        const endpoints_x10 = self.touched_endpoints * 10 / self.touched_chunks;
        const pad_samples = stages.samples * link_fold_batch;
        std.debug.print("  {s} {} {s}: plan={s} patch={s} conn_gather={s} per_pad={}ns commit_per_pad={}ns endpoints_per_touched_chunk={}.{} pads_held_mean={} main={}us ({}%) patched={}{s}\n", .{
            group_name,
            item_count,
            case.name,
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
    }
};
