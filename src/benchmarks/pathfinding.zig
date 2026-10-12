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
const StaticColliderSystem = @import("../game/systems/static_colliders.zig").StaticColliderSystem;
const NavCellEdit = @import("../game/systems/pathfinding.zig").NavCellEdit;
const default_max_fallback_requests_per_step = @import("../game/systems/pathfinding.zig").default_max_fallback_requests_per_step;
const default_max_solves_per_frame = @import("../game/systems/pathfinding.zig").default_max_solves_per_frame;
const pathfinding_range_alignment_items = @import("../game/systems/pathfinding.zig").pathfinding_range_alignment_items;
const PathQueryKey = @import("../game/systems/pathfinding/types.zig").PathQueryKey;
const cached_results_per_agent = @import("../game/systems/pathfinding/types.zig").cached_results_per_agent;
const min_capacity_floor = @import("../game/systems/pathfinding/types.zig").min_capacity_floor;
const intake_range_alignment_items = @import("../game/systems/pathfinding/types.zig").intake_range_alignment_items;
const evict_range_alignment_items = @import("../game/systems/pathfinding/types.zig").evict_range_alignment_items;
const NavUpdateStats = @import("../game/systems/pathfinding/types.zig").NavUpdateStats;
const AiDir = @import("../game/systems/ai.zig").AiDir;
const computeRequantizedGoal = @import("../game/systems/ai.zig").computeRequantizedGoal;
const default_goal_requantization_hysteresis_distance = @import("../game/systems/ai.zig").default_goal_requantization_hysteresis_distance;
const AssetStore = @import("../assets/assets.zig").AssetStore;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const WorldSystem = @import("../game/world_system.zig").WorldSystem;
const CellCoord = @import("../game/world_system.zig").CellCoord;
const TileId = @import("../game/world_system.zig").TileId;
const level_z_step = @import("../game/world_system.zig").level_z_step;
const default_chunk_size_tiles = @import("../game/world_system.zig").default_chunk_size_tiles;
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
// pinned to a fixed 8 (this bench's own standalone override — the demo no longer
// pins this low: a live capture measured the field building constantly but never
// once being sampled at demo scale, since pending-dedup and the result cache
// already serve a goal-change burst off one solve for free, so the demo now pins
// this far above any population it has), the pack crosses the threshold and the
// managed flow field (serviceGroupFields / ensureGroupField) engages, so once
// built every re-key is answered by a field sample instead of a per-agent
// tier-0/tier-1 A* re-solve. Measures the STEADY-STATE ready-field sampling cost
// (build happens during untimed setup) — a regression that stops the field from
// engaging at this population/grid combination shows up here as
// group_fields_built no longer 0 during measurement, or group_field_samples
// dropping below item_count. This exercises the MECHANISM (a warm, actually-used
// field is cheap) in isolation; whether real gameplay ever reaches this population
// pattern is a separate, demo-level question — see proceduralPathfindingCapacity's
// doc comment.
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

// Nav scaling groups over a world-backed nav (item counts in the size groups encode
// `level side * 1000 + levels`). A config whose nav storage exceeds the bench's
// nav-size limit is skipped, its figure printed (`navSizeSkip`). The route groups time
// one cold step of 64 distinct-goal requests; `candidates` is the abstract nodes the last
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
//     teleport-count config (item count teleports * 10^7 + side * 1000 + levels) instead
//     spreads that many such teleports over level-0 cells within 16 of the border, each to
//     its point mirror on the deepest level; it passes when flat in teleport count, at every
//     side.
//   - `pathfinding-cross-level-shaft`: a 256² world of 8, 32, or 128 walkable levels; a ramp
//     shaft beside the starts joins levels 1 to the deepest, and level 0, which no ramp
//     reaches, holds a one-way teleport from the shaft's planar cell to beside the goals.
//     Requests go from level 1 to level 5, 48 cells east, so the routes are the same at
//     every depth and the teleport is never usable. Passes when flat in depth.
pub const level_size_group = suite.BenchmarkGroup{
    .name = "pathfinding-level-size",
    .defaultItemCounts = levelSizeItemCounts,
    .runCase = runLevelSizeCase,
};

pub const cross_level_depth_group = suite.BenchmarkGroup{
    .name = "pathfinding-cross-level-depth",
    .defaultItemCounts = crossLevelItemCounts,
    .runCase = runCrossLevelDepthCase,
};

pub const cross_level_teleport_group = suite.BenchmarkGroup{
    .name = "pathfinding-cross-level-teleport",
    .defaultItemCounts = crossLevelItemCounts,
    .runCase = runCrossLevelTeleportCase,
};

pub const cross_level_shaft_group = suite.BenchmarkGroup{
    .name = "pathfinding-cross-level-shaft",
    .defaultItemCounts = crossLevelItemCounts,
    .runCase = runCrossLevelShaftCase,
};

// One timed dig on a 256² walkable level holding 1,000, 10,000, or 50,000 cached results
// (the item count) of short paths: the cell turns blocking and the nav reaction runs,
// eviction included. The dig crosses the same few paths at every count, so it passes
// when flat in cached results. `outputs` is the results evicted. An untimed reset
// reopens the cell and re-solves the evicted results. A region config (item count
// region chunks * 10^7 + cached results) instead fills a chunk-aligned square of that
// many chunks in one step, crossing the routes of its rows: the dense-change reaction.
// Items/s is the path-registry entries the eviction visited per second. `--details` prints
// the eviction stages' shapes, the reaction's main-thread time, and the entries visited.
pub const evict_group = suite.BenchmarkGroup{
    .name = "pathfinding-evict",
    .defaultItemCounts = evictItemCounts,
    .runCase = runEvictCase,
};

// Item counts up to `group_field_tunnel_min_cells`: moving packs of 24 agents (the item
// count is the pack count) on an open 256² nav grid, each with its own goal marching one
// nav cell per rekey cycle. Fields per pack and a threshold of 8 make the packs' fields
// build at the same time, one `group_field_expand` item per building field. Times every
// step of the measured cycles; `outputs` is the fields built and `candidates` the field
// samples.
// Larger item counts: sparse-coverage fields. Four crowds on a 1024² level whose only
// walkable cells are a lattice of 1-wide corridors every nav chunk (31 cells per
// 256-cell chunk) each flood a field capped at the item count's cells. One iteration
// rebuilds the four fields from scratch until all are ready; the time is that build and
// `outputs` the cells covered.
// `--details` prints per-field coverage, blocks, resident bytes, and pool growths.
pub const group_field_packs_group = suite.BenchmarkGroup{
    .name = "pathfinding-group-field-packs",
    .defaultItemCounts = groupFieldPacksItemCounts,
    .runCase = runGroupFieldPacksCase,
};

// The agent count ramps linearly to 1,000, 4,000, or 16,000 (the item count) over 64
// steps, then holds until every agent's path is cached; each step every live agent
// requests its own distinct goal. Times the pathfinding updates of the whole ramp;
// `outputs` is the solves it took and `candidates` the solves past one per agent (cached
// results lost to eviction or a resize, then solved again).
pub const elastic_ramp_group = suite.BenchmarkGroup{
    .name = "pathfinding-elastic-ramp",
    .defaultItemCounts = elasticRampItemCounts,
    .runCase = runElasticRampCase,
};

// The `pathfinding-elastic-ramp` ramp to 1,000, 4,000, or 16,000 agents (the item count),
// untimed, then a drop to the last-added eighth, whose results are the youngest and stay
// cached, held until the shrink window elapses. Times the step whose update shrinks the
// capacity, result cache included; that step and the hold step before it serve only cache
// hits. `outputs` is the cached results kept, `candidates` those moved to a lower owner id,
// `evictions` those evicted. `--details` adds the hold step's time and the difference, the
// resize, split into its worker-side copy and the rest on the main thread, with the cache
// and agent capacities before and after.
pub const elastic_shrink_group = suite.BenchmarkGroup{
    .name = "pathfinding-elastic-shrink",
    .defaultItemCounts = elasticRampItemCounts,
    .runCase = runElasticShrinkCase,
};

// The `pathfinding-cache-unreachable` layout (starts and goals on opposite sides of a wall
// with no gap), but every timed step requests goals the previous step did not, on result
// state cleared before it (untimed): nothing is answered from the cache, so the step runs
// every admitted failing solve and publishes its negative. `outputs` is the negatives
// published, `deferred` the requests past the per-step solve ceiling.
pub const cold_unreachable_group = suite.BenchmarkGroup{
    .name = "pathfinding-cold-unreachable",
    .defaultItemCounts = coldSolveItemCounts,
    .runCase = runColdUnreachableCase,
};

// Fresh unreachable goals on a full negative cache. Goals lie in a sealed 80² pocket at the
// origin of a walkable 256² level and are requested from outside it, so every search ends
// without a path and the goal flood proves the pocket. Untimed, four steps of the item
// count's requests fill the negative cache to its cap (four per agent); each timed step
// then requests the item count of goals that no step of the last 16 asked for, and every
// published negative evicts a round-robin victim. `outputs` is the step's negatives answered
// and `evictions` (`victims=`) the victims the full cache evicted.
pub const negative_steady_group = suite.BenchmarkGroup{
    .name = "pathfinding-negative-steady",
    .defaultItemCounts = negativeSteadyItemCounts,
    .runCase = runNegativeSteadyCase,
};

// The item count's requests (item code level side * 1000 + requests) from outside a
// sealed 80² pocket at the origin of a walkable level, each to its own goal inside it.
// An untimed first update publishes every goal's negative: side 256's searches end without
// a path under the tier-0 cap, and the goal flood proves the pocket within their claims;
// sides 1024 and 2048 exhaust the tier-0 budget, and the flood proves it within that cap.
// Each timed step toggles one far cell's blocking, runs the nav reaction, and updates the
// same requests: the far change evicts no negative, so on the pinned sides every request is
// a hit. Other sides check only that each request is answered unavailable, exhausted, or
// still pending. `outputs` is the step's solves, `candidates` its cache hits, `samples` its
// exhausted attempts, and `deferred` the requests still pending after it. `--details`
// prints the update's stages, the reaction's remask and eviction stages with its
// main-thread share, and the reaction/update split with the negatives it evicted.
pub const negative_dig_group = suite.BenchmarkGroup{
    .name = "pathfinding-negative-dig",
    .defaultItemCounts = negativeDigItemCounts,
    .runCase = runNegativeDigCase,
};

// The item count's unreachable requests in one burst. Four sealed 56² pockets line the top
// edge of a walkable 256² level; requesters start outside them from row 72, and request `i`
// goes to its own cell of pocket `i mod 4`. One timed sample, on result state cleared before
// it (untimed), submits every request on one step and then steps an empty stream until
// nothing is pending; an untimed status query of every request follows each step. `outputs`
// is the requests answered unavailable and `candidates` the searches the burst ran; the
// workload column adds the burst's steps, the step after which every status read
// unavailable, and the mean longest step. Passes when linear in requests. `--details` prints
// the update stages over the timed steps.
pub const negative_burst_group = suite.BenchmarkGroup{
    .name = "pathfinding-negative-burst",
    .defaultItemCounts = negativeBurstItemCounts,
    .runCase = runNegativeBurstCase,
};

// One walkable level (item code variant * 10^10 + edge chunks * 10^7 + side * 1000 + 1)
// holding, at its origin corner, solid chunks around one walkable gap chunk. Variant 0: a
// room of edge² chunks walled off by a one-chunk band whose one open chunk is the gap;
// blocking the gap seals the room. Variant 1: a one-chunk ring corridor around a solid block
// of edge² chunks, walled off from the rest of the level, with the gap one chunk of the ring;
// blocking it cuts the ring without splitting it. Variant 2: a one-chunk tunnel of edge
// chunks along the level's north border, walled below, whose east mouth chunk is the gap;
// blocking it seals the tunnel off the open level. One timed sample blocks the gap chunk and
// runs the nav reaction, then reopens it and runs the reaction again; the tile writes are
// untimed. `outputs` is the cells each change flips and `candidates` the room, ring, or tunnel
// chunks. Passes when no config grows faster than its room, ring, or tunnel chunks and every
// config is flat in side. `--details` prints the block and reopen reactions, the block
// reaction's plan, remask, patch, and connectivity shapes (the flood's rounds, searches per
// round, and its tuner's policy), and the reactions' main-thread share.
pub const connectivity_split_group = suite.BenchmarkGroup{
    .name = "pathfinding-connectivity-split",
    .defaultItemCounts = connectivitySplitItemCounts,
    .runCase = runConnectivitySplitCase,
};

// A 256² world of 2 levels (item code variant * 10^10 + terminals * 10^5 + systems), each a
// lattice of one-cell walled rooms, holding `systems` chains of `terminals` rooms, each room
// joined to the next room of its chain by a one-way teleport. Variants 0 and 1 toggle the
// first chain's last room (its last link's target), variant 2 its first room (its first
// link's source), and variant 3 a far room no chain uses. Variant 4 closes the chain's first
// `terminals - 64` rooms once, untimed (its block narrows), then toggles its last room.
// Variant 5 is a fan: every room joined by a one-way teleport to a hub room, the hub to the
// last room, which toggles, so one round recomputes every source's row (rows narrower than a
// cache line below 512 terminals). Variants 1 to 5 hold one chain or fan. The toggled end's 8 rooms sit in one
// fixed chunk whose orthogonal neighbours hold no other chain room, so every config's toggle
// patches the same chunks. One timed sample blocks the cell and runs the nav reaction, then
// reopens it and runs the reaction again; the tile writes are untimed. `outputs` is the
// one-way links and `candidates` the rooms. Passes when variants 0, 3, and 4 are flat (4 in
// its peak terminals), variant 2 grows at most linearly in terminals, and variants 1 and 5 at
// most as terminals² / 32. `--details` as for `pathfinding-connectivity-split`.
pub const connectivity_oneway_group = suite.BenchmarkGroup{
    .name = "pathfinding-connectivity-oneway",
    .defaultItemCounts = connectivityOnewayItemCounts,
    .runCase = runConnectivityOnewayCase,
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
    return runWorkloadCase(allocator, io, options, case, group.name, item_count, .unique_open, .cold_solve, item_count, item_count);
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
    setPathStageTuners(&system, case);

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
    return runWorkloadCase(allocator, io, options, case, fallback_group.name, item_count, .unique_open, .hot_cache, item_count, item_count);
}

pub fn runFallbackDetourCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runWorkloadCase(allocator, io, options, case, fallback_detour_group.name, item_count, .blocked_detour, .hot_cache, item_count, item_count);
}

pub fn runFallbackUnreachableCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runWorkloadCase(allocator, io, options, case, fallback_unreachable_group.name, item_count, .blocked_unreachable, .hot_cache, item_count, item_count);
}

pub fn runHardFallbackCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runWorkloadCase(allocator, io, options, case, hard_fallback_group.name, item_count, .hard_fallback, .cold_fallback, item_count, item_count);
}

pub fn runHardFallbackBudgetCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    const fallback_budget = @min(options.fallback_budget orelse hardFallbackBudget(item_count), item_count);
    return runWorkloadCase(allocator, io, options, case, hard_fallback_budget_group.name, item_count, .hard_fallback, .cold_fallback, item_count, fallback_budget);
}

fn hardFallbackBudget(item_count: usize) usize {
    return @min(item_count, default_max_fallback_requests_per_step);
}

fn runWorkloadCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, group_name: []const u8, item_count: usize, workload: Workload, mode: MeasurementMode, solve_budget: usize, fallback_budget: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try createFixture(allocator, item_count, workload);
    defer fixture.deinit();
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    setPathStageTuners(&system, case);

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
    if (mode == .hot_cache) try warmHotCache(&system, &fixture.requests, if (threads) |*thread_system| thread_system else null, options, case, item_count);

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
    var stage_report = StageReport{};
    for (0..measure_count) |_| {
        if (mode.isCold()) system.clearRuntimeState();
        const start_ns = suite.nowNs(io);
        last_stats = try runColdOnce(&system, &fixture.requests, if (threads) |*thread_system| thread_system else null, case, item_count, solve_budget, fallback_budget);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.solveBatch());
        stage_report.add(suite.elapsedNs(start_ns, end_ns), last_stats);
    }
    stage_report.print(options, group_name, item_count, case);

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
    setPathStageTuners(&system, case);

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
        while (system.pending.len > 0 and guard > 0) : (guard -= 1) {
            const before = system.pending.len;
            _ = try runColdOnce(&system, &empty, thread_ptr, case, item_count, item_count, item_count);
            if (system.pending.len >= before) break; // no progress: stop draining this cycle
        }
    }

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    var stage_report = StageReport{};
    while (accumulator.iterations < drain_samples) {
        // Refill is untimed: clears completed/pending then accepts all N (this frame also
        // solves the first ceiling). The timed samples below are pure drain frames.
        try refillDrainQueue(&system, &fixture.requests, thread_ptr, case, item_count);
        var guard: usize = drain_frame_budget;
        while (system.pending.len > 0 and accumulator.iterations < drain_samples and guard > 0) : (guard -= 1) {
            const before = system.pending.len;
            const start_ns = suite.nowNs(io);
            last_stats = try runColdOnce(&system, &empty, thread_ptr, case, item_count, item_count, item_count);
            const end_ns = suite.nowNs(io);
            accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.solveBatch());
            stage_report.add(suite.elapsedNs(start_ns, end_ns), last_stats);
            if (system.pending.len >= before) break; // no progress: refill next cycle
        }
    }
    stage_report.print(options, drain_group.name, item_count, case);

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

// Steps until every request is a cache hit and, for an adaptive case, the intake tuner
// has settled (bounded), so the timed steps are the hit path only.
fn warmHotCache(system: *PathfindingSystem, requests: *RangeOutputStream(PathRequest), thread_system: ?*ThreadSystem, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !void {
    const fill_limit = suite.rangeCount(item_count, default_max_solves_per_frame) + 2;
    const settle_limit = fill_limit + suite.adaptiveSettleIterationLimit(options);
    var steps: usize = 0;
    while (true) {
        const stats = try runColdOnce(system, requests, thread_system, case, item_count, item_count, item_count);
        steps += 1;
        const all_hits = stats.cache_hits == item_count;
        if (!all_hits and steps > fill_limit) return error.HotCacheNotWarm;
        const tuner_ready = !case.adaptive or system.intake_tuner.isSettled() or steps >= settle_limit;
        if (all_hits and tuner_ready) return;
    }
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

// Gives every pathfinding update stage this case's tuner, as `fallback_tuner` gets its own.
fn setPathStageTuners(system: *PathfindingSystem, case: suite.BenchmarkCase) void {
    if (suite.adaptiveTunerForCase(case, pathfinding_range_alignment_items)) |tuner| system.fallback_tuner = tuner;
    if (suite.adaptiveTunerForCase(case, intake_range_alignment_items)) |tuner| system.intake_tuner = tuner;
    if (suite.adaptiveTunerForCase(case, 1)) |tuner| system.group_field_tuner = tuner;
    if (suite.adaptiveTunerForCase(case, 1)) |tuner| system.group_field_begin_tuner = tuner;
    if (suite.adaptiveTunerForCase(case, 1)) |tuner| system.group_field_stall_tuner = tuner;
    if (suite.adaptiveTunerForCase(case, 1)) |tuner| system.publish_copy_tuner = tuner;
    if (suite.adaptiveTunerForCase(case, 1)) |tuner| system.registry_flush_tuner = tuner;
    if (suite.adaptiveTunerForCase(case, 1)) |tuner| system.resize_copy_tuner = tuner;
}

// An update's stage batches, in `StageReport` order.
fn updateBatches(stats: PathfindingStats) [update_stage_count]BatchStats {
    return .{ stats.intake_batch, stats.group_field_batch, stats.group_field_begin_batch, stats.fallback_batch, stats.publish_copy_batch, stats.registry_flush_batch, stats.resize_copy_batch };
}

const update_stage_count = 7;

// Worker-side time of an update's threaded stages; stages that ran inline add nothing.
fn offMainStageNs(stats: PathfindingStats) u64 {
    var total: u64 = 0;
    for (updateBatches(stats)) |batch| total += offMainNs(batch);
    return total;
}

fn offMainNs(batch: BatchStats) u64 {
    return if (batch.ran_inline) 0 else batch.batch_duration_ns;
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
    // resize copy: each stage's busiest batch, and how many of its non-empty batches ran on
    // workers.
    busiest: [update_stage_count]BatchStats = @splat(.{}),
    threaded: [update_stage_count]usize = @splat(0),
    dispatched: [update_stage_count]usize = @splat(0),
    // Route groups that count unsolved routes: the last timed step's outcome.
    routes: ?RouteOutcome = null,
    // Path-registry entries the timed updates added and removed.
    registrations_added: usize = 0,
    registrations_removed: usize = 0,
    // Negatives the timed updates published, failed solves answered without one, and the
    // negative-registry entries added and removed.
    negatives_published: usize = 0,
    start_unreachable: usize = 0,
    negative_registrations_added: usize = 0,
    negative_registrations_removed: usize = 0,

    fn add(self: *StageReport, elapsed_ns: u64, stats: PathfindingStats) void {
        self.samples += 1;
        self.timed_ns += elapsed_ns;
        self.main_ns += elapsed_ns -| offMainStageNs(stats);
        self.accept_main_ns += stats.accept_ns -| offMainNs(stats.intake_batch);
        self.group_main_ns += stats.group_service_ns -| (offMainNs(stats.group_field_batch) + offMainNs(stats.group_field_begin_batch));
        self.solve_main_ns += stats.solve_ns -| offMainNs(stats.fallback_batch);
        self.publish_ns += stats.publish_ns -| offMainNs(stats.publish_copy_batch);
        self.registrations_added += stats.registrations_added;
        self.registrations_removed += stats.registrations_removed;
        self.negatives_published += stats.negatives_published;
        self.start_unreachable += stats.start_unreachable;
        self.negative_registrations_added += stats.negative_registrations_added;
        self.negative_registrations_removed += stats.negative_registrations_removed;
        for (updateBatches(stats), &self.busiest, &self.threaded, &self.dispatched) |batch, *busiest, *threaded, *dispatched| {
            if (batch.item_count == 0) continue;
            dispatched.* += 1;
            const on_workers = !batch.ran_inline and batch.active_worker_threads != 0;
            if (on_workers) threaded.* += 1;
            const busier = batch.item_count > busiest.item_count or
                (batch.item_count == busiest.item_count and on_workers and (busiest.ran_inline or busiest.active_worker_threads == 0));
            if (busier) busiest.* = batch;
        }
    }

    fn print(self: StageReport, options: suite.Options, group_name: []const u8, item_count: usize, case: suite.BenchmarkCase) void {
        if (!options.details or self.timed_ns == 0) return;
        var shapes: [update_stage_count][48]u8 = undefined;
        var labels: [update_stage_count][]const u8 = undefined;
        for (self.busiest, self.threaded, self.dispatched, &shapes, &labels) |batch, threaded, dispatched, *buffer, *label| {
            label.* = stageShape(buffer, batch, threaded, dispatched);
        }
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
        if (self.negatives_published + self.start_unreachable + self.negative_registrations_removed != 0) {
            std.debug.print(" negatives_published={} start_unreachable={} negative_registrations +{}/-{} per update", .{
                self.negatives_published / self.samples,
                self.start_unreachable / self.samples,
                self.negative_registrations_added / self.samples,
                self.negative_registrations_removed / self.samples,
            });
        }
        std.debug.print("\n", .{});
    }
};

// A stage's busiest batch as `inline` or workers/ranges, with its item count, then
// threaded/non-empty batch counts.
fn stageShape(buffer: []u8, batch: BatchStats, threaded: usize, dispatched: usize) []const u8 {
    if (batch.ran_inline or batch.active_worker_threads == 0) {
        return std.fmt.bufPrint(buffer, "inline({})[{}/{}]", .{ batch.item_count, threaded, dispatched }) catch "inline";
    }
    return std.fmt.bufPrint(buffer, "{}w/{}r({})[{}/{}]", .{ batch.active_worker_threads, batch.range_count, batch.item_count, threaded, dispatched }) catch "stage";
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
                // A cross-chunk route is cached as its stitched corridor (one level here).
                const result = system.completed.resultAt(slot);
                if (result.stitched_len != 0) {
                    const stitched = system.completed.stitchedSlice(slot, result.stitched_len);
                    starts[i] = grid.cellCenter(stitched.cells[stitched.len() / 2]);
                    warm_paths += 1;
                } else {
                    const path = system.completed.pathSlice(slot, result.path_len);
                    if (path.len > 0) {
                        starts[i] = grid.cellCenter(path[path.len / 2]);
                        warm_paths += 1;
                    }
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
        // hops any such detour could need — the nav records hold one border portal per
        // open boundary run per side, so the graph is far
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
            std.debug.assert(sys.pending.len == 1);
            std.debug.assert(sys.pending.at(0).tier == 1);
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
    setPathStageTuners(&system, case);

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
        // Fixed low so a small item_count still exercises the field mechanism directly —
        // this bench's own standalone override, decoupled from whatever population the
        // demo currently pins (see game_demo_state.proceduralPathfindingCapacity's doc
        // comment: production now reserves the field for battle-scale, not this pack
        // size). --items overrides item_count for a direct at-scale check (verified up
        // to 5000 agents at ~2.76ms mean, comfortably inside a 6ms frame budget).
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
    var stage_report = StageReport{};
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_stats = try runColdOnce(&system, &fixture.requests, thread_ptr, case, item_count, item_count, item_count);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.solveBatch());
        stage_report.add(suite.elapsedNs(start_ns, end_ns), last_stats);
    }
    stage_report.print(options, group_field_detour_group.name, item_count, case);

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
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const side = group_field_detour_grid_side;

    var fixture = try createGroupFieldDetourMovingFixture(allocator, side, item_count);
    defer fixture.deinit(allocator);
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    setPathStageTuners(&system, case);

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
    var stage_report = StageReport{};

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
                stage_report.add(suite.elapsedNs(start_ns, end_ns), stats);
                escalated_total += stats.escalated_solves;
                throttled_total += stats.group_field_rebuild_throttled;
                built_total += stats.group_fields_built;
                samples_total += stats.group_field_samples;
            }
        }
    }
    stage_report.print(options, group_field_detour_moving_group.name, item_count, case);

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
    setPathStageTuners(&system, case);

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

const level_case_encoding: usize = 1000;
const level_size_item_counts = [_]usize{ 256_001, 1_024_001, 2_048_001 };
const cross_level_item_counts = [_]usize{ 256_008, 256_032, 256_128 };
const teleport_count_encoding: usize = 10_000_000;
// Teleport-count configs place their teleports on level-0 cells this close to the border.
const teleport_border_band: u16 = 16;
const evict_region_encoding: usize = 10_000_000;
const evict_item_counts = [_]usize{ 1_000, 10_000, 50_000, 64 * evict_region_encoding + 10_000 };
// Four packs, then three tunnel field caps: sample points on the coverage curve.
const group_field_packs_item_counts = [_]usize{ 4, 2048, 16384, 65536 };
// Item counts from here up are tunnel field caps, not pack counts.
const group_field_tunnel_min_cells: usize = 1024;
const elastic_ramp_item_counts = [_]usize{ 1_000, 4_000, 16_000 };

fn levelSizeItemCounts(_: suite.Profile) []const usize {
    return &level_size_item_counts;
}

fn crossLevelItemCounts(_: suite.Profile) []const usize {
    return &cross_level_item_counts;
}

fn evictItemCounts(_: suite.Profile) []const usize {
    return &evict_item_counts;
}

fn groupFieldPacksItemCounts(_: suite.Profile) []const usize {
    return &group_field_packs_item_counts;
}

fn elasticRampItemCounts(_: suite.Profile) []const usize {
    return &elastic_ramp_item_counts;
}

const negative_steady_item_counts = [_]usize{ 64, 128, 256 };
const negative_dig_item_counts = [_]usize{ 256_064, 256_128, 256_256, 1_024_064, 2_048_064 };

fn negativeSteadyItemCounts(_: suite.Profile) []const usize {
    return &negative_steady_item_counts;
}

fn negativeDigItemCounts(_: suite.Profile) []const usize {
    return &negative_dig_item_counts;
}

const negative_burst_item_counts = [_]usize{ 1024, 4096, 12288 };

fn negativeBurstItemCounts(_: suite.Profile) []const usize {
    return &negative_burst_item_counts;
}

// The connectivity groups' variant digit sits above every other field of their item codes.
const connectivity_variant_encoding: usize = 10_000_000_000;
const split_edge_encoding: usize = 10_000_000;
const oneway_terminals_encoding: usize = 100_000;

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
    onewayItemCode(.shrunk, 8192, 1),
    onewayItemCode(.fan, 64, 1),
    onewayItemCode(.fan, 128, 1),
    onewayItemCode(.fan, 256, 1),
    onewayItemCode(.dense, oneway_dense_terminals, 2),
    onewayItemCode(.dense, oneway_dense_terminals, 8),
    onewayItemCode(.dense, oneway_dense_terminals, 32),
};

fn connectivityOnewayItemCounts(_: suite.Profile) []const usize {
    return &connectivity_oneway_item_counts;
}

/// The capacity a nav scaling config's nav reserves; library defaults elsewhere.
/// `suite.navStorageBytes` charges exactly these three fields.
pub fn navSizeCapacity(config: suite.NavSizeConfig) PathfindingCapacity {
    return .{
        .worker_participant_count = config.participant_count,
        .max_agent_budget = config.agent_budget,
        .max_group_fields = config.group_fields,
    };
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
    const asset_store = AssetStore.init(allocator, io, "assets");
    var meta = try world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    var meta_owned = true;
    defer if (meta_owned) meta.deinit();
    var world = WorldSystem{
        .allocator = allocator,
        .width = side,
        .height = side,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = default_chunk_size_tiles,
    };
    errdefer world.deinit();
    try world.buildCatalog(&meta);
    const walkable = try world.requireTileByName(&meta, "grass");
    const blocking = try world.requireTileByName(&meta, "dirt");
    for (0..levels) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        const layer = try world.addDenseLayer(level, 0, .floor, walkable);
        std.debug.assert(layer == OpenWorld.floor(level));
    }
    world.adoptTilesetMeta(meta);
    meta_owned = false;
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

// Writes `requests` as one range, replacing the stream's contents.
fn writeRequests(stream: *RangeOutputStream(PathRequest), requests: []const PathRequest) !void {
    stream.clearRetainingCapacity();
    if (requests.len == 0) return;
    const range_base = try stream.appendRangeCounts(1);
    stream.addCount(range_base, requests.len);
    try stream.prefixAppendedRanges(range_base);
    var writer = stream.rangeWriter(range_base);
    for (requests) |request| writer.write(request);
    writer.finish();
    stream.finishWrite();
}

fn initCaseThreads(allocator: std.mem.Allocator, io: std.Io, case: suite.BenchmarkCase) !?ThreadSystem {
    if (!case.usesThreadSystem()) return null;
    return try ThreadSystem.init(allocator, io, .{
        .max_worker_threads = case.maxWorkerThreads(),
        .items_per_range = suite.default_items_per_range,
    });
}

// Nav update stages are independent chunks: one chunk per range is the fixed controls'
// partition.
fn navUpdateItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(1) orelse suite.default_items_per_range;
}

// Gives the nav update stages this case's control config.
fn configureNavUpdateThreads(system: *PathfindingSystem, case: suite.BenchmarkCase) void {
    system.nav_thread_adaptive = case.adaptive;
    system.nav_thread_items_per_range = navUpdateItemsPerRange(case);
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

fn routeSizeConfig(side: usize, levels: usize, links: usize, participant_count: usize) suite.NavSizeConfig {
    return .{
        .side = side,
        .levels = levels,
        .links = links,
        .participant_count = participant_count,
        .agent_budget = route_request_count,
        .group_fields = 1,
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
    try writeRequests(&stream, requests);
    var system = PathfindingSystem.init(allocator);
    errdefer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &owned_open.world, thread_system);
    return .{ .open = owned_open, .data = data, .requests = stream, .system = system };
}

fn runLevelSizeCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const side: u16 = @intCast(item_count / level_case_encoding);
    const levels: u16 = @intCast(item_count % level_case_encoding);
    std.debug.assert(levels == 1 and side >= 256);
    var threads = try initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    const size_config = routeSizeConfig(side, levels, 0, participant_count);
    if (suite.navSizeSkip(level_size_group.name, item_count, case, size_config)) |skip| return skip;

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
    var fixture = try initRouteFixture(allocator, open, &requests, navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit();
    return runColdRouteSteps(io, options, case, level_size_group.name, item_count, &fixture, thread_ptr, .fail);
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

fn runCrossLevelCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, teleport: bool) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const world_config = item_count % teleport_count_encoding;
    const side: u16 = @intCast(world_config / level_case_encoding);
    const levels: u16 = @intCast(world_config % level_case_encoding);
    // 0: the one corner-to-corner teleport.
    const teleport_count = item_count / teleport_count_encoding;
    std.debug.assert(levels > cross_level_goal_level and side >= 256);
    std.debug.assert(teleport or teleport_count == 0);

    var threads = try initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    const link_count: usize = levels - 1 + if (teleport_count != 0) teleport_count else @intFromBool(teleport);
    const size_config = routeSizeConfig(side, levels, link_count, participant_count);
    const group_name = if (teleport) cross_level_teleport_group.name else cross_level_depth_group.name;
    if (suite.navSizeSkip(group_name, item_count, case, size_config)) |skip| return skip;

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
        try addBorderTeleports(&open.world, side, levels - 1, teleport_count);
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
    var fixture = try initRouteFixture(allocator, open, &requests, navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit();
    return runColdRouteSteps(io, options, case, group_name, item_count, &fixture, thread_ptr, if (teleport) .count else .fail);
}

// Shaft group levels: requests start on one and end on the other.
const shaft_start_level: u16 = 1;
const shaft_goal_level: u16 = 5;
// Columns east of the starts' block at which the goals' block begins.
const shaft_goal_offset: u16 = 48;

fn runCrossLevelShaftCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const side: u16 = @intCast(item_count / level_case_encoding);
    const levels: u16 = @intCast(item_count % level_case_encoding);
    std.debug.assert(levels > shaft_goal_level and side >= 256);

    var threads = try initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    // Ramps join levels 1..levels-1; one teleport leaves level 0.
    const link_count: usize = levels - 2 + 1;
    const size_config = routeSizeConfig(side, levels, link_count, participant_count);
    if (suite.navSizeSkip(cross_level_shaft_group.name, item_count, case, size_config)) |skip| return skip;

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
    var fixture = try initRouteFixture(allocator, open, &requests, navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit();
    return runColdRouteSteps(io, options, case, cross_level_shaft_group.name, item_count, &fixture, thread_ptr, .count);
}

// Adds `count` bidirectional teleports from level-0 cells within `teleport_border_band` of
// the border, spread evenly in row-major order, each to its point mirror on `deepest`. Each
// span far exceeds its cost, and every endpoint is at least 64 cells from the cross-level
// routes' starts and goals around the level center.
fn addBorderTeleports(world: *WorldSystem, side: u16, deepest: u16, count: usize) !void {
    const inner = side - 2 * teleport_border_band;
    const band_cells = @as(usize, side) * side - @as(usize, inner) * inner;
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
// starts on an open cell, so a definitive negative or an invalid start is a fixture fault.
fn runRouteStep(system: *PathfindingSystem, fixture: *RouteFixture, thread_system: ?*ThreadSystem, case: suite.BenchmarkCase, unsolved_routes: UnsolvedRoutes) !PathfindingStats {
    const count = route_request_count;
    const stats = try runColdOnce(system, &fixture.requests, thread_system, case, count, count, count);
    if (stats.unavailable_results != 0) return error.RouteUnavailable;
    if (stats.start_invalid_dropped != 0) return error.RouteStartInvalid;
    std.debug.assert(stats.available_results <= count);
    if (unsolved_routes == .fail and (stats.available_results != count or stats.deferred_requests != 0)) return error.RouteUnsolved;
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
        while (!system.fallback_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            system.clearRuntimeState();
            _ = try runRouteStep(system, fixture, thread_system, case, unsolved_routes);
        }
    }
    const settled = if (case.adaptive) system.fallback_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    var abstract_nodes: usize = 0;
    var stage_report = StageReport{};
    for (0..options.iterations) |_| {
        system.clearRuntimeState();
        const start_ns = suite.nowNs(io);
        last_stats = try runRouteStep(system, fixture, thread_system, case, unsolved_routes);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        accumulator.record(elapsed_ns, last_stats.solveBatch());
        stage_report.add(elapsed_ns, last_stats);
        abstract_nodes = lastAbstractNodesUsed(system);
    }
    if (unsolved_routes == .count) stage_report.routes = .{ .solved = last_stats.available_results, .unsolved = route_request_count - last_stats.available_results };
    stage_report.print(options, group_name, item_count, case);
    var stats = accumulator.finish();
    stats.output_count = last_stats.available_results;
    stats.candidate_pairs = abstract_nodes;
    stats.items_per_second = suite.itemsPerSecond(stats.output_count, stats.mean_ns);
    if (case.adaptive) stats.work_tuning = suite.workTuningSummary(system.fallback_tuner.report(), settled);
    return stats;
}

// Short distinct-goal requests over a walkable 256² level: goal `i` on a 240-wide grid
// from cell (8, 8), its start 4 cells right and one down.
const short_route_side: u16 = 256;
const short_route_columns: usize = 240;

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

const EvictFixture = struct {
    open: OpenWorld,
    data: DataSystem,
    colliders: StaticColliderSystem,
    requests: []PathRequest,
    stream: RangeOutputStream(PathRequest),
    empty: RangeOutputStream(PathRequest),
    system: PathfindingSystem,
    agent_count: usize,
    // Cells whose blocking the last change flipped.
    changed: std.ArrayList(NavCellEdit) = .empty,

    fn deinit(self: *EvictFixture, allocator: std.mem.Allocator) void {
        self.changed.deinit(allocator);
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
    fn fillCache(self: *EvictFixture, case: suite.BenchmarkCase, thread_system: ?*ThreadSystem) !void {
        var start: usize = 0;
        while (start < self.requests.len) : (start += self.agent_count) {
            const end = @min(start + self.agent_count, self.requests.len);
            try writeRequests(&self.stream, self.requests[start..end]);
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
    fn cachedCount(self: *const EvictFixture) usize {
        var cached: usize = 0;
        for (self.requests) |request| {
            const view = self.system.statusForWorld(request.start_level, request.start, request.goal_level, request.goal, request.agent_class, null);
            if (view.status == .available) cached += 1;
        }
        return cached;
    }

    // Sets `cells` on level 0 to `tile` in one step (untimed) and runs the nav reaction
    // over them, marking included; returns the reaction's time and stats. `changed` holds
    // `cells.len` entries.
    fn changeAndReact(self: *EvictFixture, io: std.Io, cells: []const CellCoord, tile: TileId, thread_system: ?*ThreadSystem) !EvictReaction {
        const layer = OpenWorld.floor(0);
        self.changed.clearRetainingCapacity();
        self.open.world.beginDenseCellWriteReserve();
        for (cells) |cell| try self.open.world.reserveDenseCellWrite(layer, cell.x, cell.y, tile);
        for (cells) |cell| {
            const changed = (try self.open.world.setDenseTile(layer, cell.x, cell.y, tile)) orelse return error.EvictDigUnchanged;
            if (changed.old_blocks_movement == changed.new_blocks_movement) return error.EvictDigUnchanged;
            self.changed.appendAssumeCapacity(.{ .level = changed.level, .x = changed.x, .y = changed.y });
        }
        const version_before = self.system.graph.version;
        const start_ns = suite.nowNs(io);
        for (self.changed.items) |edit| try self.system.markNavDirty(edit.level, edit.x, edit.y);
        const stats = try self.system.applyBufferedNavUpdates(&self.colliders, &self.open.world, thread_system);
        const elapsed = suite.elapsedNs(start_ns, suite.nowNs(io));
        if (self.system.graph.version != version_before) return error.EvictDigRebuiltNav;
        return .{ .elapsed_ns = elapsed, .stats = stats };
    }
};

const EvictReaction = struct {
    elapsed_ns: u64,
    stats: NavUpdateStats,
};

// The timed reactions' eviction stage shapes and main-thread share, printed under
// --details: each stage's busiest batch, and the reaction minus its worker-side time.
const EvictReport = struct {
    samples: usize = 0,
    timed_ns: u128 = 0,
    main_ns: u128 = 0,
    busiest: [3]BatchStats = @splat(.{}),
    threaded: [3]usize = @splat(0),
    dispatched: [3]usize = @splat(0),
    visited: usize = 0,
    evicted: usize = 0,

    fn add(self: *EvictReport, reaction: EvictReaction) void {
        self.samples += 1;
        self.timed_ns += reaction.elapsed_ns;
        self.main_ns += reaction.elapsed_ns -| reaction.stats.off_main_stage_ns;
        self.visited = reaction.stats.evict_entries_visited;
        self.evicted = reaction.stats.evicted_results;
        const batches = [_]BatchStats{ reaction.stats.evict_count_batch, reaction.stats.evict_batch, reaction.stats.evict_flush_batch };
        for (batches, &self.busiest, &self.threaded, &self.dispatched) |batch, *busiest, *threaded, *dispatched| {
            if (batch.item_count == 0) continue;
            dispatched.* += 1;
            const on_workers = !batch.ran_inline and batch.active_worker_threads != 0;
            if (on_workers) threaded.* += 1;
            if (batch.item_count >= busiest.item_count) busiest.* = batch;
        }
    }

    fn print(self: EvictReport, options: suite.Options, group_name: []const u8, item_count: usize, case: suite.BenchmarkCase) void {
        if (!options.details or self.timed_ns == 0) return;
        var shapes: [3][48]u8 = undefined;
        var labels: [3][]const u8 = undefined;
        for (self.busiest, self.threaded, self.dispatched, &shapes, &labels) |batch, threaded, dispatched, *buffer, *label| {
            label.* = stageShape(buffer, batch, threaded, dispatched);
        }
        std.debug.print("  {s} {} {s}: evict_count={s} evict={s} evict_flush={s} main={}us ({}%) visited={} evicted={}\n", .{
            group_name,
            item_count,
            case.name,
            labels[0],
            labels[1],
            labels[2],
            @as(u64, @intCast(self.main_ns / self.samples / std.time.ns_per_us)),
            @as(u64, @intCast(self.main_ns * 100 / self.timed_ns)),
            self.visited,
            self.evicted,
        });
    }
};

// Builds the colliders and the world-backed nav over `open` and `data`, then moves them
// and `requests` into the fixture. On error they stay with the caller.
fn assembleEvictFixture(allocator: std.mem.Allocator, open: *OpenWorld, data: *DataSystem, requests: []PathRequest, capacity: PathfindingCapacity, thread_system: ?*ThreadSystem) !EvictFixture {
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
    };
}

fn initEvictFixture(allocator: std.mem.Allocator, io: std.Io, result_count: usize, capacity: PathfindingCapacity, thread_system: ?*ThreadSystem) !EvictFixture {
    var open = try buildOpenWorld(allocator, io, short_route_side, 1);
    errdefer open.world.deinit();
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const requests = try buildShortRouteRequests(allocator, &data, &open, result_count);
    errdefer allocator.free(requests);
    return assembleEvictFixture(allocator, &open, &data, requests, capacity, thread_system);
}

// The region config's square: chunk-aligned from chunk (2, 2), `side` chunks a side.
fn evictRegionCells(allocator: std.mem.Allocator, region_chunks: usize, chunk_tiles: usize) ![]CellCoord {
    const side = std.math.sqrt(region_chunks);
    std.debug.assert(side * side == region_chunks);
    const origin = 2 * chunk_tiles;
    const extent = side * chunk_tiles;
    std.debug.assert(origin + extent <= short_route_side);
    const cells = try allocator.alloc(CellCoord, extent * extent);
    for (cells, 0..) |*cell, index| {
        cell.* = .{ .x = @intCast(origin + index % extent), .y = @intCast(origin + index / extent) };
    }
    return cells;
}

fn runEvictCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const region_chunks = item_count / evict_region_encoding;
    const result_count = item_count % evict_region_encoding;
    var threads = try initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    const size_config = suite.NavSizeConfig{
        .side = short_route_side,
        .levels = 1,
        .participant_count = participant_count,
        .agent_budget = evictAgentBudget(result_count),
        .group_fields = 1,
        .long_results = 0,
    };
    if (suite.navSizeSkip(evict_group.name, item_count, case, size_config)) |skip| return skip;

    var fixture = try initEvictFixture(allocator, io, result_count, navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    const region_cells: ?[]CellCoord = if (region_chunks == 0) null else try evictRegionCells(allocator, region_chunks, fixture.open.world.chunk_size_tiles);
    defer if (region_cells) |cells| allocator.free(cells);
    const cells: []const CellCoord = region_cells orelse &.{evict_dig_cell};
    try fixture.changed.ensureTotalCapacity(allocator, cells.len);
    setNavReactionTuners(&fixture.system, case);
    configureNavUpdateThreads(&fixture.system, case);
    try fixture.fillCache(case, thread_ptr);

    for (0..options.warmup_iterations) |_| {
        _ = try fixture.changeAndReact(io, cells, fixture.open.blocking, thread_ptr);
        _ = try fixture.changeAndReact(io, cells, fixture.open.walkable, thread_ptr);
        try fixture.fillCache(case, thread_ptr);
    }
    var accumulator = suite.StatsAccumulator.init(item_count);
    var report = EvictReport{};
    var evicted: usize = 0;
    for (0..options.iterations) |_| {
        const reaction = try fixture.changeAndReact(io, cells, fixture.open.blocking, thread_ptr);
        evicted = result_count - fixture.cachedCount();
        // The reaction evicted exactly the results the cache lost.
        if (reaction.stats.evicted_results != evicted) return error.EvictCountMismatch;
        accumulator.record(reaction.elapsed_ns, fixture.system.graph.last_remask_batch);
        report.add(reaction);
        _ = try fixture.changeAndReact(io, cells, fixture.open.walkable, thread_ptr);
        try fixture.fillCache(case, thread_ptr);
    }
    report.print(options, evict_group.name, item_count, case);
    // The size config charges no long block.
    if (fixture.system.long_block_grows != 0) return error.ShortRouteTookLongBlock;
    var stats = accumulator.finish();
    stats.output_count = evicted;
    stats.cache_evictions = evicted;
    stats.candidate_pairs = result_count;
    // Registry entries the reaction's eviction visited per second.
    stats.items_per_second = suite.itemsPerSecond(report.visited, stats.mean_ns);
    stats.batch = suite.batchSummaryFromBatch(fixture.system.graph.last_remask_batch);
    stats.secondary_batch = suite.batchSummaryFromBatch(fixture.system.graph.last_patch_batch);
    return stats;
}

// Gives the nav reaction's stages this case's tuners.
fn setNavReactionTuners(system: *PathfindingSystem, case: suite.BenchmarkCase) void {
    if (suite.adaptiveTunerForCase(case, 1)) |tuner| {
        system.nav_remask_tuner = tuner;
        system.nav_patch_tuner = suite.adaptiveTunerForCase(case, 1).?;
        system.nav_plan_tuner = suite.adaptiveTunerForCase(case, 1).?;
        system.nav_evict_count_tuner = suite.adaptiveTunerForCase(case, evict_range_alignment_items).?;
        system.nav_evict_tuner = suite.adaptiveTunerForCase(case, evict_range_alignment_items).?;
        system.evict_flush_tuner = suite.adaptiveTunerForCase(case, 1).?;
    }
}

const group_field_pack_agents: usize = 24;

// Rewrites `requests` with every pack's members requesting their pack's goal for `cycle`:
// pack `p` owns a column band of the grid, starts in a block at its top, and its goal
// marches up from the bottom one nav cell per cycle (never revisited).
fn writeGroupFieldPackRequests(requests: *RangeOutputStream(PathRequest), entities: []const EntityId, packs: usize, cycle: usize) !void {
    const side = group_field_detour_grid_side;
    const band = side / packs;
    std.debug.assert(band >= 16 and cycle < side / 2);
    requests.clearRetainingCapacity();
    try requests.reserve(1, entities.len);
    const range_base = try requests.appendRangeCounts(1);
    requests.addCount(range_base, entities.len);
    try requests.prefixAppendedRanges(range_base);
    var writer = requests.rangeWriter(range_base);
    for (entities, 0..) |entity, index| {
        const pack = index / group_field_pack_agents;
        const member = index % group_field_pack_agents;
        const start: FixtureCell = .{ .x = pack * band + 2 + member % 8, .y = 4 + (member / 8) * 2 };
        const goal: FixtureCell = .{ .x = pack * band + band / 2, .y = side - 4 - cycle };
        writer.write(.{
            .entity = entity,
            .kind = .group,
            .start = .{ .x = @as(f32, @floatFromInt(start.x)) * 32.0 + 8.0, .y = @as(f32, @floatFromInt(start.y)) * 32.0 + 8.0 },
            .goal = .{ .x = @as(f32, @floatFromInt(goal.x)) * 32.0 + 8.0, .y = @as(f32, @floatFromInt(goal.y)) * 32.0 + 8.0 },
        });
    }
    writer.finish();
    requests.finishWrite();
}

fn runGroupFieldPacksCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (item_count >= group_field_tunnel_min_cells) return runGroupFieldTunnelCase(allocator, io, options, case, item_count);
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const side = group_field_detour_grid_side;
    const packs = item_count;
    const agent_count = packs * group_field_pack_agents;

    var data = DataSystem.init(allocator);
    defer data.deinit();
    const entities = try allocator.alloc(EntityId, agent_count);
    defer allocator.free(entities);
    for (entities) |*entity| entity.* = try data.createEntity();

    var threads = try initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;

    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    setPathStageTuners(&system, case);
    try system.reserve(PathfindingCapacity{
        .max_group_fields = packs,
        .worker_participant_count = participant_count,
        .max_agent_budget = agent_count,
        .min_group_field_agents = 8,
        .group_field_rebuild_min_steps = group_field_detour_rebuild_min_steps,
    });
    const world_extent = @as(f32, @floatFromInt(side)) * 32.0;
    try system.rebuildStaticNavGrid(&data, world_extent, world_extent, 32.0);

    var requests = RangeOutputStream(PathRequest).init(allocator);
    defer requests.deinit();
    var accumulator = suite.StatsAccumulator.init(item_count);
    var stage_report = StageReport{};
    var built_total: usize = 0;
    var samples_total: usize = 0;
    const total_cycles = group_field_detour_moving_warmup_cycles + group_field_detour_moving_cycles;
    for (0..total_cycles) |cycle| {
        try writeGroupFieldPackRequests(&requests, entities, packs, cycle);
        const measured = cycle >= group_field_detour_moving_warmup_cycles;
        for (0..group_field_detour_rekey_period_steps) |_| {
            const start_ns = suite.nowNs(io);
            const stats = try runColdOnce(&system, &requests, thread_ptr, case, agent_count, agent_count, agent_count);
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
    // Every pack's field engages and is sampled.
    std.debug.assert(built_total >= packs * group_field_detour_moving_cycles);
    std.debug.assert(samples_total > 0);

    var stats = accumulator.finish();
    stats.output_count = built_total;
    stats.candidate_pairs = samples_total;
    if (stats.mean_ns != 0) stats.items_per_second = suite.itemsPerSecond(built_total, stats.mean_ns * stats.iterations);
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
        system.group_field_pool_grows,
        system.group_field_pool_failures,
    });
}

const group_field_tunnel_side: usize = 1024;
// Corridor pitch: one corridor row and column per default nav chunk.
const group_field_tunnel_pitch: usize = 16;
const group_field_tunnel_fields: usize = 4;
const group_field_tunnel_agents: usize = 8;
const group_field_tunnel_build_guard: usize = 256;

// The lattice: a static body over each pitch-1 square between corridors.
fn addTunnelLattice(data: *DataSystem) !void {
    const pitch = group_field_tunnel_pitch;
    const squares = group_field_tunnel_side / pitch;
    const extent = @as(f32, @floatFromInt(pitch - 1)) * 32.0;
    for (0..squares) |square_y| {
        for (0..squares) |square_x| {
            const entity = try data.createEntity();
            const position = math.Vec2{ .x = @as(f32, @floatFromInt(square_x * pitch + 1)) * 32.0, .y = @as(f32, @floatFromInt(square_y * pitch + 1)) * 32.0 };
            try data.setMovementBody(entity, .{ .position = position, .previous_position = position });
            try data.setCollisionBounds(entity, .{ .size = .{ .x = extent, .y = extent } });
            try data.setCollisionResponse(entity, .{ .mobility = .static });
        }
    }
}

// Each field's crowd stands on the corridor row through its goal, the goal at a corridor
// crossing in its own quadrant.
fn writeTunnelRequests(requests: *RangeOutputStream(PathRequest), entities: []const EntityId) !void {
    const side = group_field_tunnel_side;
    const goals = [group_field_tunnel_fields]FixtureCell{ .{ .x = side / 4, .y = side / 4 }, .{ .x = 3 * side / 4, .y = side / 4 }, .{ .x = side / 4, .y = 3 * side / 4 }, .{ .x = 3 * side / 4, .y = 3 * side / 4 } };
    requests.clearRetainingCapacity();
    try requests.reserve(1, entities.len);
    const range_base = try requests.appendRangeCounts(1);
    requests.addCount(range_base, entities.len);
    try requests.prefixAppendedRanges(range_base);
    var writer = requests.rangeWriter(range_base);
    for (entities, 0..) |entity, index| {
        const goal = goals[index / group_field_tunnel_agents];
        const start: FixtureCell = .{ .x = goal.x + 2 + index % group_field_tunnel_agents, .y = goal.y };
        writer.write(.{
            .entity = entity,
            .kind = .group,
            .start = .{ .x = @as(f32, @floatFromInt(start.x)) * 32.0 + 8.0, .y = @as(f32, @floatFromInt(start.y)) * 32.0 + 8.0 },
            .goal = .{ .x = @as(f32, @floatFromInt(goal.x)) * 32.0 + 8.0, .y = @as(f32, @floatFromInt(goal.y)) * 32.0 + 8.0 },
        });
    }
    writer.finish();
    requests.finishWrite();
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
    const side = group_field_tunnel_side;
    const agent_count = group_field_tunnel_fields * group_field_tunnel_agents;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    try addTunnelLattice(&data);
    const entities = try allocator.alloc(EntityId, agent_count);
    defer allocator.free(entities);
    for (entities) |*entity| entity.* = try data.createEntity();

    var threads = try initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;

    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    setPathStageTuners(&system, case);
    try system.reserve(PathfindingCapacity{
        .max_group_fields = group_field_tunnel_fields,
        .worker_participant_count = participant_count,
        .max_agent_budget = agent_count,
        .min_group_field_agents = group_field_tunnel_agents,
        .group_field_max_cells = item_count,
    });
    const world_extent = @as(f32, @floatFromInt(side)) * 32.0;
    try system.rebuildStaticNavGrid(&data, world_extent, world_extent, 32.0);
    var requests = RangeOutputStream(PathRequest).init(allocator);
    defer requests.deinit();
    try writeTunnelRequests(&requests, entities);

    const warmup = @min(options.warmup_iterations, cold_warmup_cap);
    const iterations = @max(@as(usize, 1), @min(options.iterations, cold_iteration_cap));
    for (0..warmup) |_| _ = try buildTunnelFields(io, &system, &requests, thread_ptr, case, agent_count);
    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..iterations) |_| {
        const built = try buildTunnelFields(io, &system, &requests, thread_ptr, case, agent_count);
        accumulator.record(built.elapsed_ns, built.batch);
    }
    var covered: usize = 0;
    for (system.group_fields.items) |field| covered += field.pushed_count;
    // Every field covers its cap: the lattice's 126,976 cells reach past the largest cap.
    std.debug.assert(covered == group_field_tunnel_fields * item_count);
    printFieldMemory(options, group_field_packs_group.name, item_count, case, &system);

    var stats = accumulator.finish();
    stats.output_count = covered;
    if (stats.mean_ns != 0) stats.items_per_second = suite.itemsPerSecond(covered, stats.mean_ns);
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
    var threads = try initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    const size_config = suite.NavSizeConfig{
        .side = short_route_side,
        .levels = 1,
        .participant_count = participant_count,
        .agent_budget = item_count,
        .group_fields = 1,
        .long_results = 0,
    };
    if (suite.navSizeSkip(elastic_ramp_group.name, item_count, case, size_config)) |skip| return skip;
    const capacity = navSizeCapacity(size_config);

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
    setPathStageTuners(&system, case);

    for (0..options.warmup_iterations) |_| _ = try runElasticRamp(io, case, &system, capacity, &stream, requests, thread_ptr);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var last = ElasticRamp{};
    for (0..options.iterations) |_| {
        last = try runElasticRamp(io, case, &system, capacity, &stream, requests, thread_ptr);
        accumulator.record(last.elapsed_ns, last.busiest_solve_batch);
    }
    // The size config charges no long block.
    if (system.long_block_grows != 0) return error.ShortRouteTookLongBlock;
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
        try writeRequests(stream, requests[0..live]);
        const start_ns = suite.nowNs(io);
        const step_stats = try runColdOnce(system, stream, thread_system, case, live, live, live);
        ramp.elapsed_ns += suite.elapsedNs(start_ns, suite.nowNs(io));
        // Every goal is reachable, so each solve caches one result.
        if (step_stats.unavailable_results != 0) return error.ElasticRampUnreachableGoal;
        ramp.solves += step_stats.solved_requests;
        if (step_stats.fallback_batch.item_count > ramp.busiest_solve_batch.item_count) ramp.busiest_solve_batch = step_stats.fallback_batch;
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
    if (item_count / elastic_shrink_divisor < min_capacity_floor) return suite.RunStats.skipped("an eighth of the agents is below the capacity floor; nothing shrinks");
    var threads = try initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    const size_config = suite.NavSizeConfig{
        .side = short_route_side,
        .levels = 1,
        .participant_count = participant_count,
        .agent_budget = item_count,
        .group_fields = 1,
        .long_results = 0,
    };
    if (suite.navSizeSkip(elastic_shrink_group.name, item_count, case, size_config)) |skip| return skip;
    const capacity = navSizeCapacity(size_config);

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
    if (system.long_block_grows != 0) return error.ShortRouteTookLongBlock;

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
    try writeRequests(stream, held);
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
    if (system.completed.core.ownerLog().len != 0 or system.negatives.core.ownerLog().len != 0) return error.ElasticShrinkOpsPending;
    if (system.negatives.logicalCapacity() != shrink.cache_capacity_after) return error.ElasticShrinkNegativeCapacityApart;
    for (&system.path_index, &system.negative_index) |*shard, *negative_shard| {
        if (shard.owner_heads.items.len > shrink.cache_capacity_after) return error.ElasticShrinkOwnerHeadsPending;
        if (negative_shard.owner_heads.items.len > shrink.cache_capacity_after) return error.ElasticShrinkNegativeOwnerHeadsPending;
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

fn runColdUnreachableCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var fixture = try createFixture(allocator, item_count, .blocked_unreachable);
    defer fixture.deinit();
    const side = fixtureGridSide(item_count, .blocked_unreachable);
    // Distinct goal cells right of the wall: one step's requests take distinct keys, and the
    // rotation moves the next step on to other cells where the wall side has room. The
    // per-step clear keeps any repeated key uncached.
    const goal_cells = blockedLaneCount(side) * (side - 2);
    if (goal_cells < item_count) return error.ColdUnreachableGoalCellsTooFew;
    const requests = try allocator.dupe(PathRequest, fixture.requests.mergedItems());
    defer allocator.free(requests);
    var stream = RangeOutputStream(PathRequest).init(allocator);
    defer stream.deinit();
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    setPathStageTuners(&system, case);

    var threads = try initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    try system.reserve(PathfindingCapacity{
        .max_group_fields = 8,
        .worker_participant_count = participant_count,
        .max_agent_budget = @max(item_count, 1),
    });
    const world_extent = @as(f32, @floatFromInt(side)) * 32.0;
    try system.rebuildStaticNavGrid(&fixture.data, world_extent, world_extent, 32.0);

    var next_goal: usize = 0;
    // Untimed priming step: the first step grows the capacity from the reserve floor.
    _ = try runColdUnreachableStep(io, case, &system, &stream, requests, side, goal_cells, &next_goal, thread_ptr);
    for (0..coldWarmup(options)) |_| {
        _ = try runColdUnreachableStep(io, case, &system, &stream, requests, side, goal_cells, &next_goal, thread_ptr);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = coldSettleLimit(options);
        while (!system.fallback_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runColdUnreachableStep(io, case, &system, &stream, requests, side, goal_cells, &next_goal, thread_ptr);
        }
    }
    const settled_before_measurement = if (case.adaptive) system.fallback_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    var stage_report = StageReport{};
    for (0..coldIterations(options)) |_| {
        const step = try runColdUnreachableStep(io, case, &system, &stream, requests, side, goal_cells, &next_goal, thread_ptr);
        last_stats = step.stats;
        accumulator.record(step.elapsed_ns, last_stats.solveBatch());
        stage_report.add(step.elapsed_ns, last_stats);
    }
    stage_report.print(options, cold_unreachable_group.name, item_count, case);

    var stats = accumulator.finish();
    stats.output_count = last_stats.unavailable_results;
    stats.candidate_pairs = last_stats.solved_requests;
    stats.deferred_count = last_stats.deferred_requests;
    stats.cache_evictions = last_stats.cache_evictions;
    if (stats.mean_ns != 0) stats.items_per_second = suite.itemsPerSecond(last_stats.solved_requests, stats.mean_ns);
    if (case.adaptive) stats.work_tuning = suite.workTuningSummary(system.fallback_tuner.report(), settled_before_measurement);
    return stats;
}

// Points every request at the next goal cells (untimed), clears the result state, and
// times one step; every admitted request must fail and publish its negative.
fn runColdUnreachableStep(
    io: std.Io,
    case: suite.BenchmarkCase,
    system: *PathfindingSystem,
    stream: *RangeOutputStream(PathRequest),
    requests: []PathRequest,
    side: usize,
    goal_cells: usize,
    next_goal: *usize,
    thread_system: ?*ThreadSystem,
) !struct { elapsed_ns: u64, stats: PathfindingStats } {
    for (requests, 0..) |*request, index| {
        const goal = requestGoalCell((next_goal.* + index) % goal_cells, side, .blocked_unreachable);
        request.goal = .{
            .x = @as(f32, @floatFromInt(goal.x)) * 32.0 + 8.0,
            .y = @as(f32, @floatFromInt(goal.y)) * 32.0 + 8.0,
        };
    }
    next_goal.* = (next_goal.* + requests.len) % goal_cells;
    try writeRequests(stream, requests);
    // A full negative set drops inserts, so each step starts from an empty one.
    system.clearRuntimeState();
    const start_ns = suite.nowNs(io);
    const stats = try runColdOnce(system, stream, thread_system, case, requests.len, requests.len, requests.len);
    const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
    const admitted = @min(requests.len, default_max_solves_per_frame);
    if (stats.cache_hits != 0) return error.ColdUnreachableCacheHit;
    if (stats.solved_requests != admitted or stats.unavailable_results != admitted) return error.ColdUnreachableSolveNotNegative;
    if (stats.cache_evictions != 0) return error.ColdUnreachableNegativeDropped;
    return .{ .elapsed_ns = elapsed_ns, .stats = stats };
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
// Timed negative-steady steps draw their goals from this many steps' worth, in rotation.
const negative_steady_pool_steps: usize = 16;

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
fn initPocketFixture(allocator: std.mem.Allocator, io: std.Io, side: u16, requester_count: usize, capacity: PathfindingCapacity, thread_system: ?*ThreadSystem) !EvictFixture {
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
    return assembleEvictFixture(allocator, &open, &data, requests, capacity, thread_system);
}

fn pocketSizeConfig(side: u16, participant_count: usize, requester_count: usize) suite.NavSizeConfig {
    return .{
        .side = side,
        .levels = 1,
        .participant_count = participant_count,
        .agent_budget = requester_count,
        .group_fields = 1,
        // No path is published, so no long block is taken.
        .long_results = 0,
        .negatives = requester_count * cached_results_per_agent,
    };
}

const PocketStep = struct {
    elapsed_ns: u64,
    stats: PathfindingStats,
};

// Points request `i` at goal `first_goal + i` when `first_goal` is given, then times one
// update of every request. No requester reaches a goal, and each request is answered
// unavailable, exhausts its attempt, or still waits.
fn runPocketUpdate(io: std.Io, case: suite.BenchmarkCase, fixture: *EvictFixture, thread_system: ?*ThreadSystem, first_goal: ?usize) !PocketStep {
    if (first_goal) |first| {
        for (fixture.requests, 0..) |*request, index| request.goal = fixture.open.cellCenter(pocketGoalCell(first + index));
    }
    try writeRequests(&fixture.stream, fixture.requests);
    const count = fixture.requests.len;
    const start_ns = suite.nowNs(io);
    const stats = try runColdOnce(&fixture.system, &fixture.stream, thread_system, case, count, count, count);
    const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
    if (stats.available_results != 0) return error.PocketGoalReached;
    if (stats.start_invalid_dropped != 0 or stats.dropped_requests != 0) return error.PocketRequestDropped;
    if (stats.unavailable_results + stats.budget_exhausted + stats.escalated_deferred + stats.fallback_deferred_requests != count) return error.PocketRequestUnaccounted;
    return .{ .elapsed_ns = elapsed_ns, .stats = stats };
}

// One negative-steady step on goals from `first_goal`: every request is a fresh failing
// solve that publishes its proven negative, evicting `victims` from the full cache.
fn runNegativeSteadyStep(io: std.Io, case: suite.BenchmarkCase, fixture: *EvictFixture, thread_system: ?*ThreadSystem, first_goal: usize, victims: usize) !PocketStep {
    const step = try runPocketUpdate(io, case, fixture, thread_system, first_goal);
    const count = fixture.requests.len;
    if (step.stats.cache_hits != 0) return error.NegativeSteadyCacheHit;
    if (step.stats.solved_requests != count or step.stats.unavailable_results != count) return error.NegativeSteadySolveNotNegative;
    if (step.stats.negatives_published != count) return error.NegativeSteadyNegativeUnproven;
    if (step.stats.cache_evictions != victims) return error.NegativeSteadyVictimCount;
    return step;
}

fn runNegativeSteadyCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const side = negative_steady_side;
    // Every request must fit one step's solve window for the step's accounting.
    if (item_count > default_max_solves_per_frame) return error.PocketRequestsPastSolveCeiling;
    // The prime pool fills the negative set exactly: its cap is this many per agent.
    const prime_goals = cached_results_per_agent * item_count;
    try checkPocketLayout(allocator, side, prime_goals + negative_steady_pool_steps * item_count, item_count);
    var threads = try initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    const size_config = pocketSizeConfig(side, participant_count, item_count);
    if (suite.navSizeSkip(negative_steady_group.name, item_count, case, size_config)) |skip| return skip;

    var fixture = try initPocketFixture(allocator, io, side, item_count, navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    setPathStageTuners(&fixture.system, case);

    // Untimed prime: the cache takes every prime goal's negative and evicts none.
    for (0..cached_results_per_agent) |prime_step| {
        _ = try runNegativeSteadyStep(io, case, &fixture, thread_ptr, prime_step * item_count, 0);
    }
    var pool_step: usize = 0;
    for (0..coldWarmup(options)) |_| {
        _ = try runNegativeSteadyStep(io, case, &fixture, thread_ptr, prime_goals + pool_step * item_count, item_count);
        pool_step = (pool_step + 1) % negative_steady_pool_steps;
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = coldSettleLimit(options);
        while (!fixture.system.fallback_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runNegativeSteadyStep(io, case, &fixture, thread_ptr, prime_goals + pool_step * item_count, item_count);
            pool_step = (pool_step + 1) % negative_steady_pool_steps;
        }
    }
    const settled_before_measurement = if (case.adaptive) fixture.system.fallback_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PathfindingStats{};
    var stage_report = StageReport{};
    for (0..coldIterations(options)) |_| {
        const step = try runNegativeSteadyStep(io, case, &fixture, thread_ptr, prime_goals + pool_step * item_count, item_count);
        pool_step = (pool_step + 1) % negative_steady_pool_steps;
        last_stats = step.stats;
        accumulator.record(step.elapsed_ns, last_stats.solveBatch());
        stage_report.add(step.elapsed_ns, last_stats);
    }
    stage_report.print(options, negative_steady_group.name, item_count, case);

    var stats = accumulator.finish();
    stats.output_count = last_stats.unavailable_results;
    stats.cache_evictions = last_stats.cache_evictions;
    stats.candidate_pairs = last_stats.cache_hits;
    if (stats.mean_ns != 0) stats.items_per_second = suite.itemsPerSecond(last_stats.solved_requests, stats.mean_ns);
    if (case.adaptive) stats.work_tuning = suite.workTuningSummary(fixture.system.fallback_tuner.report(), settled_before_measurement);
    return stats;
}

// How a negative-dig side's first outside searches end, each then proven by the goal flood;
// sides other than 256, 1024, and 2048 are unpinned.
const PocketSearchEnd = enum {
    // Without a path, under the tier-0 cap.
    none,
    // Exhausting the tier-0 budget.
    exhausted,
    // Unpinned: only the step's accounting is checked.
    any,

    fn forSide(side: u16) PocketSearchEnd {
        return switch (side) {
            256 => .none,
            1024, 2048 => .exhausted,
            else => .any,
        };
    }
};

// The timed negative-dig steps' reaction/update split, the reaction's remask shape, the
// negatives the reactions evicted, the last step's outcome, and the untimed first update's
// abstract nodes, printed under --details. The reaction's eviction stages and main-thread
// share print through `EvictReport`.
const NegativeDigReport = struct {
    samples: usize = 0,
    react_ns: u128 = 0,
    update_ns: u128 = 0,
    remask_busiest: BatchStats = .{},
    remask_threaded: usize = 0,
    remask_dispatched: usize = 0,
    evicted_negatives: usize = 0,
    last: PathfindingStats = .{},
    // Abstract nodes the untimed first update's last search and goal flood claimed.
    tier0_nodes: usize = 0,

    fn add(self: *NegativeDigReport, reaction: EvictReaction, step: PocketStep) void {
        self.samples += 1;
        self.react_ns += reaction.elapsed_ns;
        self.update_ns += step.elapsed_ns;
        self.evicted_negatives += reaction.stats.evicted_negatives;
        self.last = step.stats;
        const remask = reaction.stats.remask_batch;
        if (remask.item_count == 0) return;
        self.remask_dispatched += 1;
        if (!remask.ran_inline and remask.active_worker_threads != 0) self.remask_threaded += 1;
        if (remask.item_count >= self.remask_busiest.item_count) self.remask_busiest = remask;
    }

    fn print(self: NegativeDigReport, options: suite.Options, item_count: usize, case: suite.BenchmarkCase) void {
        if (!options.details or self.samples == 0) return;
        const samples: u128 = self.samples * std.time.ns_per_us;
        var remask_buffer: [48]u8 = undefined;
        std.debug.print("  {s} {} {s}: react={}us update={}us remask={s} evicted_negatives={} hits={} solves={} exhausted={} escalated={} dropped={} pending={} tier0_nodes={}\n", .{
            negative_dig_group.name,
            item_count,
            case.name,
            @as(u64, @intCast(self.react_ns / samples)),
            @as(u64, @intCast(self.update_ns / samples)),
            stageShape(&remask_buffer, self.remask_busiest, self.remask_threaded, self.remask_dispatched),
            self.evicted_negatives,
            self.last.cache_hits,
            self.last.solved_requests,
            self.last.budget_exhausted,
            self.last.escalated_solves,
            self.last.escalated_dropped,
            self.last.deferred_requests,
            self.tier0_nodes,
        });
    }
};

// The negative-dig step: toggles the far cell's blocking and runs the nav reaction (its
// time measured inside `changeAndReact`), then updates the same requests. On the pinned
// sides the far change evicts no negative and every request is a hit.
const NegativeDig = struct {
    cell: CellCoord,
    search_end: PocketSearchEnd,
    blocked: bool = false,

    fn step(self: *NegativeDig, io: std.Io, case: suite.BenchmarkCase, fixture: *EvictFixture, thread_system: ?*ThreadSystem) !struct { reaction: EvictReaction, update: PocketStep } {
        self.blocked = !self.blocked;
        const tile = if (self.blocked) fixture.open.blocking else fixture.open.walkable;
        const reaction = try fixture.changeAndReact(io, &.{self.cell}, tile, thread_system);
        const update = try runPocketUpdate(io, case, fixture, thread_system, null);
        const count = fixture.requests.len;
        switch (self.search_end) {
            .none, .exhausted => {
                if (reaction.stats.evicted_negatives != 0) return error.NegativeDigFarChangeEvicted;
                if (update.stats.cache_hits != count or update.stats.unavailable_results != count or update.stats.solved_requests != 0) return error.NegativeDigNotHit;
            },
            .any => {},
        }
        return .{ .reaction = reaction, .update = update };
    }
};

fn runNegativeDigCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const side: u16 = @intCast(item_count / level_case_encoding);
    const requester_count = item_count % level_case_encoding;
    if (requester_count == 0) return error.NegativeDigNoRequests;
    // Every request must fit one step's solve window for the step's accounting.
    if (requester_count > default_max_solves_per_frame) return error.PocketRequestsPastSolveCeiling;
    try checkPocketLayout(allocator, side, requester_count, requester_count);
    const search_end = PocketSearchEnd.forSide(side);
    var threads = try initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    const size_config = pocketSizeConfig(side, participant_count, requester_count);
    if (suite.navSizeSkip(negative_dig_group.name, item_count, case, size_config)) |skip| return skip;

    var fixture = try initPocketFixture(allocator, io, side, requester_count, navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    try fixture.changed.ensureTotalCapacity(allocator, 1);
    setPathStageTuners(&fixture.system, case);
    setNavReactionTuners(&fixture.system, case);
    configureNavUpdateThreads(&fixture.system, case);

    // Untimed first update: every request is a fresh tier-0 attempt whose goal flood proves
    // the pocket, after a search without a path (256) or one that exhausted its budget.
    var report = NegativeDigReport{};
    const first = try runPocketUpdate(io, case, &fixture, thread_ptr, null);
    report.tier0_nodes = lastAbstractNodesUsed(&fixture.system);
    const proven_after_exhaustion: usize = switch (search_end) {
        .none => 0,
        .exhausted => requester_count,
        .any => first.stats.negatives_proven_after_exhaustion,
    };
    if (search_end != .any) {
        if (first.stats.solved_requests != requester_count or first.stats.negatives_published != requester_count) return error.NegativeDigNotProven;
        if (first.stats.negatives_proven_after_exhaustion != proven_after_exhaustion) return error.NegativeDigSearchEnd;
        if (first.stats.budget_exhausted != 0 or first.stats.escalated_solves != 0) return error.NegativeDigExhausted;
    }

    var dig = NegativeDig{ .cell = pocketDigCell(side), .search_end = search_end };
    for (0..coldWarmup(options)) |_| _ = try dig.step(io, case, &fixture, thread_ptr);
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = coldSettleLimit(options);
        while (!fixture.system.fallback_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try dig.step(io, case, &fixture, thread_ptr);
        }
    }
    const settled_before_measurement = if (case.adaptive) fixture.system.fallback_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    // The update's stages and the reaction's eviction stages, each over its own span.
    var stage_report = StageReport{};
    var reaction_report = EvictReport{};
    for (0..coldIterations(options)) |_| {
        const timed = try dig.step(io, case, &fixture, thread_ptr);
        accumulator.record(timed.reaction.elapsed_ns + timed.update.elapsed_ns, timed.update.stats.solveBatch());
        stage_report.add(timed.update.elapsed_ns, timed.update.stats);
        reaction_report.add(timed.reaction);
        report.add(timed.reaction, timed.update);
    }
    stage_report.print(options, negative_dig_group.name, item_count, case);
    reaction_report.print(options, negative_dig_group.name, item_count, case);
    report.print(options, item_count, case);

    var stats = accumulator.finish();
    stats.output_count = report.last.solved_requests;
    stats.candidate_pairs = report.last.cache_hits;
    stats.sample_count = report.last.budget_exhausted;
    stats.deferred_count = report.last.deferred_requests;
    if (stats.mean_ns != 0) stats.items_per_second = suite.itemsPerSecond(requester_count, stats.mean_ns);
    if (case.adaptive) stats.work_tuning = suite.workTuningSummary(fixture.system.fallback_tuner.report(), settled_before_measurement);
    return stats;
}

// Burst fixture: `burst_pockets` sealed `burst_pocket_side`² pockets along the top edge of a
// walkable `burst_side`² level, pocket `k` from column `k * burst_pocket_pitch + 1`, each
// closed by the level border, a blocking column on either side, and a blocking row below
// it. Requesters start outside on rows from `burst_requester_row`, `pocket_requester_margin`
// cells clear of the level's sides.
const burst_side: u16 = 256;
const burst_pockets: u16 = 4;
const burst_pocket_side: u16 = 56;
const burst_pocket_pitch: u16 = 64;
const burst_requester_row: u16 = 72;
const burst_requester_columns: usize = burst_side - 2 * pocket_requester_margin;
// Per pocket: two side columns of `burst_pocket_side + 1` cells and the row between them.
const burst_wall_cells_per_pocket: usize = 3 * burst_pocket_side + 2;

comptime {
    // Requesters start below every pocket's bottom wall, and the last pocket's right wall
    // lies inside the level.
    std.debug.assert(burst_requester_row > burst_pocket_side);
    std.debug.assert((burst_pockets - 1) * burst_pocket_pitch + burst_pocket_side + 1 < burst_side);
}

fn burstGoalCell(index: usize) CellCoord {
    const pocket: u16 = @intCast(index % burst_pockets);
    const cell = index / burst_pockets;
    // In range: the cell lies inside its pocket.
    std.debug.assert(cell < @as(usize, burst_pocket_side) * burst_pocket_side);
    return .{
        .x = pocket * burst_pocket_pitch + 1 + @as(u16, @intCast(cell % burst_pocket_side)),
        .y = @intCast(cell / burst_pocket_side),
    };
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

// Fails unless every request has its own pocket cell and every requester row lies inside
// the level.
fn checkBurstLayout(requester_count: usize) !void {
    if (requester_count == 0) return error.NegativeBurstNoRequests;
    if ((requester_count + burst_pockets - 1) / burst_pockets > @as(usize, burst_pocket_side) * burst_pocket_side) return error.NegativeBurstGoalCellsTooFew;
    const rows = (requester_count + burst_requester_columns - 1) / burst_requester_columns;
    if (burst_requester_row + rows > burst_side) return error.NegativeBurstRequesterRowsTooFew;
}

fn initBurstFixture(allocator: std.mem.Allocator, io: std.Io, requester_count: usize, capacity: PathfindingCapacity, thread_system: ?*ThreadSystem) !EvictFixture {
    var open = try buildOpenWorld(allocator, io, burst_side, 1);
    errdefer open.world.deinit();
    const walls = burstWallCells();
    try writeLevelZeroCells(&open, &walls, open.blocking);
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const requests = try allocator.alloc(PathRequest, requester_count);
    errdefer allocator.free(requests);
    for (requests, 0..) |*request, index| {
        request.* = .{
            .entity = try data.createEntity(),
            .start = open.cellCenter(burstRequesterCell(index)),
            .goal = open.cellCenter(burstGoalCell(index)),
        };
    }
    return assembleEvictFixture(allocator, &open, &data, requests, capacity, thread_system);
}

fn burstSizeConfig(participant_count: usize, requester_count: usize) suite.NavSizeConfig {
    return .{
        .side = burst_side,
        .levels = 1,
        .participant_count = participant_count,
        .agent_budget = requester_count,
        .group_fields = 1,
        // No path is published, so no long block is taken.
        .long_results = 0,
        // One negative per request.
        .negatives = requester_count,
    };
}

// Requests whose status reads unavailable. Untimed: one status query per request.
fn unavailableCount(fixture: *const EvictFixture) usize {
    var unavailable: usize = 0;
    for (fixture.requests) |request| {
        const view = fixture.system.statusForWorld(request.start_level, request.start, request.goal_level, request.goal, request.agent_class, null);
        if (view.status == .unavailable) unavailable += 1;
    }
    return unavailable;
}

const BurstOutcome = struct {
    // Sum of the burst's step times; status queries excluded.
    elapsed_ns: u64 = 0,
    steps: usize = 0,
    // The step after which every request's status read unavailable.
    status_steps: usize = 0,
    max_step_ns: u64 = 0,
    searches: usize = 0,
    unavailable: usize = 0,
    // The submitting step's stats.
    first: PathfindingStats = .{},
};

// One burst on cleared result state: every request on the first step, then empty steps
// until nothing is pending, within the steps the per-step solve ceiling needs plus one.
// No request reaches its goal, and each is answered unavailable.
fn runBurst(io: std.Io, case: suite.BenchmarkCase, fixture: *EvictFixture, thread_system: ?*ThreadSystem, stage_report: ?*StageReport) !BurstOutcome {
    const count = fixture.requests.len;
    fixture.system.clearRuntimeState();
    try writeRequests(&fixture.stream, fixture.requests);
    const step_limit = suite.rangeCount(count, default_max_solves_per_frame) + 1;
    var outcome = BurstOutcome{};
    var stream = &fixture.stream;
    while (true) {
        if (outcome.steps == step_limit) return error.NegativeBurstNotDrained;
        const start_ns = suite.nowNs(io);
        const stats = try runColdOnce(&fixture.system, stream, thread_system, case, count, count, count);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        if (stats.available_results != 0) return error.NegativeBurstGoalReached;
        if (stats.start_invalid_dropped != 0 or stats.dropped_requests != 0) return error.NegativeBurstRequestDropped;
        if (outcome.steps == 0) outcome.first = stats;
        outcome.steps += 1;
        outcome.elapsed_ns += elapsed_ns;
        outcome.max_step_ns = @max(outcome.max_step_ns, elapsed_ns);
        outcome.searches += stats.solved_requests;
        outcome.unavailable += stats.unavailable_results;
        if (stage_report) |report| report.add(elapsed_ns, stats);
        stream = &fixture.empty;
        if (outcome.status_steps == 0 and unavailableCount(fixture) == count) outcome.status_steps = outcome.steps;
        if (stats.pending_requests == 0) break;
    }
    if (outcome.unavailable != count) return error.NegativeBurstUnanswered;
    if (outcome.status_steps == 0) return error.NegativeBurstStatusNotUnavailable;
    return outcome;
}

fn runNegativeBurstCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    try checkBurstLayout(item_count);
    var threads = try initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    const size_config = burstSizeConfig(participant_count, item_count);
    if (suite.navSizeSkip(negative_burst_group.name, item_count, case, size_config)) |skip| return skip;

    var fixture = try initBurstFixture(allocator, io, item_count, navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    setPathStageTuners(&fixture.system, case);

    // At least one untimed burst: the first grows the capacity from the reserve floor.
    for (0..@max(1, coldWarmup(options))) |_| _ = try runBurst(io, case, &fixture, thread_ptr, null);
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = coldSettleLimit(options);
        while (!fixture.system.fallback_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runBurst(io, case, &fixture, thread_ptr, null);
        }
    }
    const settled_before_measurement = if (case.adaptive) fixture.system.fallback_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var stage_report = StageReport{};
    var last = BurstOutcome{};
    var max_step_total: u128 = 0;
    for (0..coldIterations(options)) |_| {
        last = try runBurst(io, case, &fixture, thread_ptr, &stage_report);
        accumulator.record(last.elapsed_ns, last.first.solveBatch());
        max_step_total += last.max_step_ns;
    }
    stage_report.print(options, negative_burst_group.name, item_count, case);

    var stats = accumulator.finish();
    stats.output_count = last.unavailable;
    stats.candidate_pairs = last.searches;
    stats.sample_count = last.steps;
    stats.deferred_count = last.status_steps;
    if (accumulator.iterations != 0) stats.max_step_ns = @intCast(max_step_total / accumulator.iterations);
    if (stats.mean_ns != 0) stats.items_per_second = suite.itemsPerSecond(item_count, stats.mean_ns);
    if (case.adaptive) stats.work_tuning = suite.workTuningSummary(fixture.system.fallback_tuner.report(), settled_before_measurement);
    return stats;
}

// The agent budget of the toggle groups' fixtures, which request no paths.
const toggle_agent_budget: usize = 8;

// One timed toggle: a change of `cells` and its nav reaction, then the revert and its
// reaction, with the change reaction's plan, remask, and patch batches.
const ToggleSample = struct {
    change: EvictReaction,
    // The change reaction's plan, remask, patch, connectivity seed, gather, and flood, and
    // closure candidates, resolve, mask, plan, rows, and compaction.
    change_stages: [toggle_stage_count]BatchStats,
    revert: EvictReaction,

    fn elapsedNs(self: ToggleSample) u64 {
        return self.change.elapsed_ns + self.revert.elapsed_ns;
    }
};

// What a toggle's reactions must keep: every one-way block at its size, and each closure
// reserve within its fixed ratio of the words the reaction touches (`checkOnewayReserve`).
const ToggleChecks = struct {
    fixed_blocks: bool = true,
    reserve_ratio: bool = true,
};

// Fails when a reaction's closure reserved past its fixed ratio: an arena tail over twice its
// candidates' block words, or an arena limit over three times the live words at its prepare,
// each plus 32 words per terminal it could number (a small piece's 16-word block).
fn checkOnewayReserve(stats: NavUpdateStats) !void {
    const slack = 32 * stats.closure_kb;
    if (stats.closure_tail_bound > 2 * stats.closure_candidate_words + slack) return error.ConnectivityOnewayReserveRatio;
    if (stats.closure_arena_limit > 3 * stats.closure_live_prepared + slack) return error.ConnectivityOnewayReserveRatio;
}

// Blocks `cells` (open before) and runs the nav reaction, then reopens them and runs it again.
fn runToggle(io: std.Io, fixture: *EvictFixture, cells: []const CellCoord, thread_system: ?*ThreadSystem, checks: ToggleChecks) !ToggleSample {
    const change = try fixture.changeAndReact(io, cells, fixture.open.blocking, thread_system);
    const graph = &fixture.system.graph;
    const stats = change.stats;
    const change_stages = [toggle_stage_count]BatchStats{
        graph.last_plan_batch,         stats.remask_batch,               graph.last_patch_batch,
        stats.conn_seed_batch,         stats.conn_gather_batch,          stats.conn_flood_batch,
        stats.conn_candidates_batch,   stats.conn_closure_resolve_batch, stats.conn_closure_mask_batch,
        stats.conn_closure_plan_batch, stats.conn_closure_rows_batch,    stats.conn_closure_compact_batch,
    };
    const revert = try fixture.changeAndReact(io, cells, fixture.open.walkable, thread_system);
    // A toggle and its revert never resize a one-way block.
    if (checks.fixed_blocks and (change.stats.closure_shrinks != 0 or revert.stats.closure_shrinks != 0)) return error.ConnectivityOnewayShrinkFlip;
    if (checks.reserve_ratio) {
        try checkOnewayReserve(change.stats);
        try checkOnewayReserve(revert.stats);
    }
    return .{ .change = change, .change_stages = change_stages, .revert = revert };
}

const toggle_stage_count = 12;

// The timed toggles' change and revert reactions, the change reaction's plan, remask, patch,
// connectivity seed, gather, and flood, and closure candidates, resolve, mask, plan, rows,
// and compaction shapes (each stage's busiest batch), its closure counters and closure rows'
// dispatch time on workers, its connectivity flood (nodes expanded, root-groups, families,
// rounds, the fewest and most searches a round dispatched, components split off, dispatch
// time on workers) beside the revert's flood nodes, the flood tuner's policy after the
// samples, and the reactions' main-thread share: each reaction minus its worker-side stage
// time. Printed under --details.
const ToggleReport = struct {
    samples: usize = 0,
    change_ns: u128 = 0,
    revert_ns: u128 = 0,
    main_ns: u128 = 0,
    busiest: [toggle_stage_count]BatchStats = @splat(.{}),
    threaded: [toggle_stage_count]usize = @splat(0),
    dispatched: [toggle_stage_count]usize = @splat(0),
    closure_touched: usize = 0,
    closure_links: usize = 0,
    closure_terms_new: usize = 0,
    closure_terms_left: usize = 0,
    closure_a_rows: usize = 0,
    closure_rounds: usize = 0,
    closure_words_written: usize = 0,
    closure_shrinks: usize = 0,
    closure_live_words: usize = 0,
    closure_dead_words: usize = 0,
    closure_arena_capacity: usize = 0,
    closure_compactions: usize = 0,
    closure_rows_off_main_ns: u128 = 0,
    // The closure reserve of the sample's reaction with the larger arena tail bound.
    closure_tail_bound: usize = 0,
    closure_tail_used: usize = 0,
    closure_arena_limit: usize = 0,
    closure_candidate_words: usize = 0,
    closure_live_prepared: usize = 0,
    closure_kb: usize = 0,
    chunks_patched: usize = 0,
    records_patched: usize = 0,
    flood_nodes: usize = 0,
    groups: usize = 0,
    families: usize = 0,
    rounds: usize = 0,
    round_items_min: usize = 0,
    round_items_max: usize = 0,
    splits: usize = 0,
    flood_off_main_ns: u64 = 0,
    revert_flood_nodes: usize = 0,
    // The flood tuner's workers when the case runs it adaptive (zero: inline).
    flood_tuner_workers: ?usize = null,

    fn add(self: *ToggleReport, sample: ToggleSample) void {
        self.samples += 1;
        self.change_ns += sample.change.elapsed_ns;
        self.revert_ns += sample.revert.elapsed_ns;
        self.main_ns += (sample.change.elapsed_ns -| sample.change.stats.off_main_stage_ns) + (sample.revert.elapsed_ns -| sample.revert.stats.off_main_stage_ns);
        self.chunks_patched = sample.change.stats.chunks_patched;
        self.records_patched = sample.change.stats.records_patched;
        self.flood_nodes = sample.change.stats.conn_flood_nodes;
        self.groups = sample.change.stats.conn_groups;
        self.families = sample.change.stats.conn_families;
        self.rounds = sample.change.stats.conn_rounds;
        self.round_items_min = sample.change.stats.conn_round_items_min;
        self.round_items_max = sample.change.stats.conn_round_items_max;
        self.flood_off_main_ns = sample.change.stats.conn_flood_off_main_ns;
        self.splits = sample.change.stats.conn_splits;
        self.revert_flood_nodes = sample.revert.stats.conn_flood_nodes;
        const closure = sample.change.stats;
        self.closure_touched = closure.closure_touched;
        self.closure_links = closure.closure_links;
        self.closure_terms_new = closure.closure_terms_new;
        self.closure_terms_left = closure.closure_terms_left;
        self.closure_a_rows = closure.closure_a_rows;
        self.closure_rounds = closure.closure_rounds;
        self.closure_words_written = closure.closure_words_written;
        self.closure_shrinks += closure.closure_shrinks + sample.revert.stats.closure_shrinks;
        self.closure_live_words = closure.closure_live_words;
        self.closure_dead_words = closure.closure_dead_words;
        self.closure_arena_capacity = closure.closure_arena_capacity;
        self.closure_compactions += closure.closure_compactions + sample.revert.stats.closure_compactions;
        self.closure_rows_off_main_ns += offMainNs(closure.conn_closure_rows_batch);
        const reserve = if (sample.revert.stats.closure_tail_bound > closure.closure_tail_bound) sample.revert.stats else closure;
        self.closure_tail_bound = reserve.closure_tail_bound;
        self.closure_tail_used = reserve.closure_tail_used;
        self.closure_arena_limit = reserve.closure_arena_limit;
        self.closure_candidate_words = reserve.closure_candidate_words;
        self.closure_live_prepared = reserve.closure_live_prepared;
        self.closure_kb = reserve.closure_kb;
        for (sample.change_stages, &self.busiest, &self.threaded, &self.dispatched) |batch, *busiest, *threaded, *dispatched| {
            if (batch.item_count == 0) continue;
            dispatched.* += 1;
            const on_workers = !batch.ran_inline and batch.active_worker_threads != 0;
            if (on_workers) threaded.* += 1;
            if (batch.item_count >= busiest.item_count) busiest.* = batch;
        }
    }

    // The busiest plan, remask, and patch batches into `stats`' nav stage summaries.
    fn summarize(self: ToggleReport, stats: *suite.RunStats) void {
        stats.nav_plan_batch = suite.batchSummaryFromBatch(self.busiest[0]);
        stats.batch = suite.batchSummaryFromBatch(self.busiest[1]);
        stats.secondary_batch = suite.batchSummaryFromBatch(self.busiest[2]);
    }

    fn print(self: ToggleReport, options: suite.Options, group_name: []const u8, item_count: usize, case: suite.BenchmarkCase) void {
        if (!options.details or self.samples == 0) return;
        var shapes: [toggle_stage_count][48]u8 = undefined;
        var labels: [toggle_stage_count][]const u8 = undefined;
        for (self.busiest, self.threaded, self.dispatched, &shapes, &labels) |batch, threaded, dispatched, *buffer, *label| {
            label.* = stageShape(buffer, batch, threaded, dispatched);
        }
        const samples: u128 = self.samples * std.time.ns_per_us;
        const timed_ns = self.change_ns + self.revert_ns;
        var tuner_buffer: [24]u8 = undefined;
        const tuner: []const u8 = if (self.flood_tuner_workers) |workers|
            (if (workers == 0) "inline" else std.fmt.bufPrint(&tuner_buffer, "{}w", .{workers}) catch "tuner")
        else
            "-";
        std.debug.print("  {s} {} {s}: block={}us reopen={}us main={}us ({}%) plan={s} remask={s} patch={s} conn_seed={s} conn_gather={s} conn_flood={s} flood_nodes={} groups={} families={} rounds={} round_items={}-{} splits={} flood_off_main={}us flood_tuner={s} reopen_flood_nodes={} chunks_patched={} records_patched={}", .{
            group_name,
            item_count,
            case.name,
            @as(u64, @intCast(self.change_ns / samples)),
            @as(u64, @intCast(self.revert_ns / samples)),
            @as(u64, @intCast(self.main_ns / samples)),
            @as(u64, @intCast(if (timed_ns == 0) 0 else self.main_ns * 100 / timed_ns)),
            labels[0],
            labels[1],
            labels[2],
            labels[3],
            labels[4],
            labels[5],
            self.flood_nodes,
            self.groups,
            self.families,
            self.rounds,
            self.round_items_min,
            self.round_items_max,
            self.splits,
            self.flood_off_main_ns / std.time.ns_per_us,
            tuner,
            self.revert_flood_nodes,
            self.chunks_patched,
            self.records_patched,
        });
        std.debug.print(" conn_candidates={s} closure_resolve={s} closure_mask={s} closure_plan={s} closure_rows={s} closure_compact={s} touched={} links={} terms_new={} terms_left={} a_rows={} closure_rounds={} words_written={} shrinks={} live_words={} dead_words={} arena_capacity={} compactions={} closure_rows_off_main={}us tail_bound={} tail_used={} arena_limit={} cand_words={} live_prepared={} kb={} reserve_ratio={d:.2}\n", .{
            labels[6],
            labels[7],
            labels[8],
            labels[9],
            labels[10],
            labels[11],
            self.closure_touched,
            self.closure_links,
            self.closure_terms_new,
            self.closure_terms_left,
            self.closure_a_rows,
            self.closure_rounds,
            self.closure_words_written,
            self.closure_shrinks,
            self.closure_live_words,
            self.closure_dead_words,
            self.closure_arena_capacity,
            self.closure_compactions,
            @as(u64, @intCast(self.closure_rows_off_main_ns / samples)),
            self.closure_tail_bound,
            self.closure_tail_used,
            self.closure_arena_limit,
            self.closure_candidate_words,
            self.closure_live_prepared,
            self.closure_kb,
            // The arena limit over the live words at prepare.
            if (self.closure_live_prepared == 0) 0.0 else @as(f64, @floatFromInt(self.closure_arena_limit)) / @as(f64, @floatFromInt(self.closure_live_prepared)),
        });
    }
};

// Times `options.iterations` toggles of `cells` after `options.warmup_iterations` untimed
// ones. Items/s is the cells flipped per second.
fn runToggleSamples(io: std.Io, options: suite.Options, case: suite.BenchmarkCase, group_name: []const u8, item_count: usize, fixture: *EvictFixture, cells: []const CellCoord, thread_system: ?*ThreadSystem, checks: ToggleChecks) !suite.RunStats {
    for (0..options.warmup_iterations) |_| _ = try runToggle(io, fixture, cells, thread_system, checks);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var report = ToggleReport{};
    for (0..options.iterations) |_| {
        const sample = try runToggle(io, fixture, cells, thread_system, checks);
        accumulator.record(sample.elapsedNs(), sample.change.stats.remask_batch);
        report.add(sample);
    }
    if (case.adaptive and thread_system != null) {
        const tuner = fixture.system.nav_conn_flood_tuner.report();
        report.flood_tuner_workers = if (tuner.has_threaded_profile) tuner.current_profile.worker_threads else 0;
    }
    report.print(options, group_name, item_count, case);
    var stats = accumulator.finish();
    report.summarize(&stats);
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

fn splitItemCode(variant: SplitVariant, edge_chunks: usize, side: usize) usize {
    return @as(usize, @backingInt(variant)) * connectivity_variant_encoding + edge_chunks * split_edge_encoding + side * level_case_encoding + 1;
}

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
        const variant_index = item_count / connectivity_variant_encoding;
        const edge_chunks = item_count % connectivity_variant_encoding / split_edge_encoding;
        const world_config = item_count % split_edge_encoding;
        if (variant_index > @backingInt(SplitVariant.tunnel)) return error.ConnectivitySplitUnknownVariant;
        if (world_config % level_case_encoding != 1) return error.ConnectivitySplitNotOneLevel;
        if (edge_chunks == 0) return error.ConnectivitySplitNoEdge;
        const side = world_config / level_case_encoding;
        if (side > std.math.maxInt(u16) or edge_chunks > std.math.maxInt(u16)) return error.ConnectivitySplitTooLarge;
        return .{ .variant = @fromBackingInt(@as(u8, @intCast(variant_index))), .edge_chunks = @intCast(edge_chunks), .side = @intCast(side) };
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

fn toggleSizeConfig(side: usize, levels: usize, links: usize, participant_count: usize) suite.NavSizeConfig {
    return .{
        .side = side,
        .levels = levels,
        .links = links,
        .participant_count = participant_count,
        .agent_budget = toggle_agent_budget,
        .group_fields = 1,
        .long_results = 0,
    };
}

// The split fixture on a walkable level: the structure's solid chunks written, no requests.
fn initSplitFixture(allocator: std.mem.Allocator, io: std.Io, config: SplitConfig, capacity: PathfindingCapacity, thread_system: ?*ThreadSystem) !EvictFixture {
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
    return assembleEvictFixture(allocator, &open, &data, requests, capacity, thread_system);
}

const SplitFlood = struct {
    // Open cells of the structure the flood reached.
    visited: usize,
    // Whether it reached an open cell outside the structure (and stopped there).
    escaped: bool,
};

// Untimed: a 4-connected flood over level 0's open cells from the level origin, which lies
// in the room or the ring, treating the gap chunk as blocking when `gap_blocked`. Stops at
// the first open cell outside the structure. The corner rule lets a diagonal step only
// through two open orthogonal cells, so 4-connected components equal the nav's.
fn floodSplitStructure(allocator: std.mem.Allocator, world: *const WorldSystem, config: SplitConfig, gap_blocked: bool) !SplitFlood {
    const chunk_tiles: usize = world.chunk_size_tiles;
    const region = config.spanChunks() * chunk_tiles;
    var visited = try std.DynamicBitSetUnmanaged.initEmpty(allocator, region * region);
    defer visited.deinit(allocator);
    var queue: std.ArrayList(CellCoord) = .empty;
    defer queue.deinit(allocator);
    const seed = CellCoord{ .x = 0, .y = 0 };
    if (world.levelBlocksMovement(0, seed.x, seed.y)) return error.ConnectivitySplitSeedBlocked;
    visited.set(0);
    try queue.append(allocator, seed);
    var read: usize = 0;
    while (read < queue.items.len) : (read += 1) {
        const cell = queue.items[read];
        const x: i32 = cell.x;
        const y: i32 = cell.y;
        const steps = [4][2]i32{ .{ x + 1, y }, .{ x - 1, y }, .{ x, y + 1 }, .{ x, y - 1 } };
        for (steps) |step| {
            if (step[0] < 0 or step[1] < 0 or step[0] >= world.width or step[1] >= world.height) continue;
            // In range: inside the level, whose sides fit `u16`.
            const next = CellCoord{ .x = @intCast(step[0]), .y = @intCast(step[1]) };
            if (world.levelBlocksMovement(0, next.x, next.y)) continue;
            if (gap_blocked and config.inGapChunk(next, chunk_tiles)) continue;
            if (next.x >= region or next.y >= region or !config.inStructure(next, chunk_tiles)) {
                return .{ .visited = queue.items.len, .escaped = true };
            }
            const slot = @as(usize, next.y) * region + next.x;
            if (visited.isSet(slot)) continue;
            visited.set(slot);
            try queue.append(allocator, next);
        }
    }
    return .{ .visited = queue.items.len, .escaped = false };
}

// Fails unless the layout has the shape its variant claims. Room: with the gap blocked the
// room's cells reach one another and nothing outside; with it open they reach outside. Ring:
// with the gap blocked every other ring cell reaches every other and nothing outside.
fn checkSplitTopology(allocator: std.mem.Allocator, world: *const WorldSystem, config: SplitConfig) !void {
    const chunk_cells = @as(usize, world.chunk_size_tiles) * world.chunk_size_tiles;
    const sealed = try floodSplitStructure(allocator, world, config, true);
    switch (config.variant) {
        .room, .tunnel => {
            if (sealed.escaped) return error.ConnectivitySplitRoomNotSealed;
            if (sealed.visited != config.structureChunks() * chunk_cells) return error.ConnectivitySplitRoomNotOneArea;
            const opened = try floodSplitStructure(allocator, world, config, false);
            if (!opened.escaped) return error.ConnectivitySplitRoomGapClosed;
        },
        .ring => {
            if (sealed.escaped) return error.ConnectivitySplitRingNotEnclosed;
            if (sealed.visited != (config.structureChunks() - 1) * chunk_cells) return error.ConnectivitySplitRingSplit;
        },
    }
}

fn runConnectivitySplitCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const config = try SplitConfig.decode(item_count);
    var threads = try initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    const size_config = toggleSizeConfig(config.side, 1, 0, participant_count);
    if (suite.navSizeSkip(connectivity_split_group.name, item_count, case, size_config)) |skip| return skip;

    var fixture = try initSplitFixture(allocator, io, config, navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    const gap = try chunkCells(allocator, &.{config.gapChunk()}, fixture.open.world.chunk_size_tiles);
    defer allocator.free(gap);
    try fixture.changed.ensureTotalCapacity(allocator, gap.len);
    setNavReactionTuners(&fixture.system, case);
    configureNavUpdateThreads(&fixture.system, case);

    var stats = try runToggleSamples(io, options, case, connectivity_split_group.name, item_count, &fixture, gap, thread_ptr, .{});
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
};

fn onewayItemCode(variant: OnewayVariant, terminals: usize, systems: usize) usize {
    return @as(usize, @backingInt(variant)) * connectivity_variant_encoding + terminals * oneway_terminals_encoding + systems;
}

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
        const variant_index = item_count / connectivity_variant_encoding;
        const terminals = item_count % connectivity_variant_encoding / oneway_terminals_encoding;
        const systems = item_count % oneway_terminals_encoding;
        if (variant_index > @backingInt(OnewayVariant.dense)) return error.ConnectivityOnewayUnknownVariant;
        const variant: OnewayVariant = @fromBackingInt(@as(u8, @intCast(variant_index)));
        if (terminals < oneway_site_rooms or systems == 0) return error.ConnectivityOnewayChainTooShort;
        if (variant != .locality and variant != .dense and systems != 1) return error.ConnectivityOnewayOneChainOnly;
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
            .locality, .tail, .shrunk, .fan => onewaySiteRoom(oneway_site_rooms - 1).cell,
            .head => onewaySiteRoom(0).cell,
            .far_dig => pocketDigCell(oneway_side),
            .dense => .{ .x = denseHead(0).cell.x + 1, .y = oneway_dense_row },
        };
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

fn initOnewayFixture(allocator: std.mem.Allocator, io: std.Io, config: OnewayConfig, rooms: []const OnewayRoom, capacity: PathfindingCapacity, thread_system: ?*ThreadSystem) !EvictFixture {
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
            try open.world.addLevelLink(.{
                .kind = .teleport,
                .level_a = from.level,
                .cell_a = from.cell,
                .level_b = to.level,
                .cell_b = to.cell,
                .traversal_cost = 1,
                .bidirectional = false,
            });
        }
    }
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const requests = try allocator.alloc(PathRequest, 0);
    errdefer allocator.free(requests);
    return assembleEvictFixture(allocator, &open, &data, requests, capacity, thread_system);
}

// Closes `rooms` (level-0 rooms of one chain) in one untimed nav reaction.
fn cutOnewayChain(allocator: std.mem.Allocator, io: std.Io, fixture: *EvictFixture, rooms: []const OnewayRoom, thread_system: ?*ThreadSystem) !void {
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
    var threads = try initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;
    const participant_count: usize = if (threads) |*thread_system| thread_system.participantSlotCount() else 1;
    const size_config = toggleSizeConfig(oneway_side, oneway_levels, config.links(), participant_count);
    if (suite.navSizeSkip(connectivity_oneway_group.name, item_count, case, size_config)) |skip| return skip;

    const rooms = try onewayRooms(allocator, config);
    defer allocator.free(rooms);
    var fixture = try initOnewayFixture(allocator, io, config, rooms, navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    // One toggled cell, or the dense variant's walls.
    const dense_walls: []CellCoord = if (config.variant == .dense) try denseWalls(allocator, config.systems) else &.{};
    defer allocator.free(dense_walls);
    const toggle_cell = config.toggleCell();
    const cells = if (config.variant == .dense) dense_walls else &[_]CellCoord{toggle_cell};
    try fixture.changed.ensureTotalCapacity(allocator, cells.len);
    setNavReactionTuners(&fixture.system, case);
    configureNavUpdateThreads(&fixture.system, case);
    if (config.variant == .shrunk) try cutOnewayChain(allocator, io, &fixture, rooms[0 .. config.terminals - oneway_shrunk_live], thread_ptr);

    // The dense variant's fill and reopen resize blocks and reserve the merged block the
    // opening can create: its ratio is what the variant measures.
    const checks: ToggleChecks = if (config.variant == .dense) .{ .fixed_blocks = false, .reserve_ratio = false } else .{};
    var stats = try runToggleSamples(io, options, case, connectivity_oneway_group.name, item_count, &fixture, cells, thread_ptr, checks);
    stats.output_count = config.links();
    stats.candidate_pairs = config.rooms();
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
