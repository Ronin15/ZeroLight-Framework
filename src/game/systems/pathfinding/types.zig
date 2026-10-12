// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Foundation types, sentinels, capacity/config/stats records, and pure helpers
//! shared across the pathfinding package: packed-ref helpers, the goal-keyed query
//! key, the octile cost helpers, the binary-heap primitives, and the small array
//! resize utilities. Leaf module within the pathfinding package (no other package
//! module imports it back) — depends on core/app primitives plus a few lightweight
//! game-module TYPE imports (EntityId, PathAgentClass) that
//! PendingRequest/PathQueryKey reference, never on game module behavior.

const std = @import("std");
const math = @import("../../../core/math.zig");
const simd = @import("../../../core/simd.zig");
const runtime_perf_log = @import("../../../app/runtime_perf_log.zig");
const BatchStats = @import("../../../app/thread_system.zig").BatchStats;
const AdaptiveWorkTuner = @import("../../../app/thread_system.zig").AdaptiveWorkTuner;
const EntityId = @import("../../data_system.zig").EntityId;
const PathAgentClass = @import("../../simulation.zig").PathAgentClass;

pub const pathfinding_range_alignment_items: usize = simd.lane_count;
/// Cache-line size records written by concurrent ranges are padded or aligned to.
pub const thread_shared_record_alignment: usize = 64;

pub const default_cell_size: f32 = 32.0;
pub const default_max_frame_requests: usize = 1024;
pub const default_max_pending_requests: usize = 1024;
pub const default_max_cached_results: usize = 1024;
// Threaded participant slots (workers + main thread). A FIXED property of the
// configured thread system, not a per-frame discovery: exactly this many search scratch
// slots, each sized by the node budgets at the capacity seam. Default 1 is the serial
// path (slot 0 only); the pipeline plumbs the real participant count.
pub const default_worker_participant_count: usize = 1;
pub const default_max_solved_requests_per_step: usize = 128;
pub const default_max_fallback_requests_per_step: usize = 128;
// Budget-bounded A* scratch is sized to this many explored nodes rather than the
// whole grid. Hitting the budget spills the request to a later frame.
pub const default_max_explored_nodes: usize = 4096;
// Open-heap headroom over the distinct-cell node budget. The budget-bounded A* pushes a
// fresh heap entry on every g-improvement without removing the superseded one, so the live
// heap can briefly hold several stale entries per open cell. Sizing the heap above the
// distinct-cell budget (paired with lazy pop-skip of superseded entries) keeps a search
// that is still under the distinct-cell budget from false-spilling on a full heap.
pub const open_heap_headroom_factor: usize = 4;

/// Logical open-heap limit for a search whose distinct-node budget is `node_budget`:
/// `open_heap_headroom_factor` entries per budgeted node (lazy-deletion duplicates),
/// floored at 16. Search gates compare the heap length against this, never the list's
/// physical capacity, so the spill point matches on every participant slot regardless
/// of reserve history.
pub fn openHeapLimit(node_budget: usize) usize {
    return @max(@as(usize, 16), node_budget *| open_heap_headroom_factor);
}
// Words of the inline path stripe each cached result owns: a plain path of up to this
// many cells, or a stitched path of half as many, is stored inline; a longer result is
// stored whole in a long block (`resultBlockWords`).
pub const default_max_stored_path_cells: usize = 512;
// Demand-driven managed shared-goal flow fields.
pub const default_max_group_fields: usize = 4;
// Must stay below however long a build takes to reach `.ready` at
// default_group_field_build_budget, or a completed build is always ready for an
// already-superseded goal and never gets sampled with the CURRENT key — see
// pathfinding-group-field-detour-moving's samples_total>0 regression guard, which
// validates this exact pairing. This is an internal relationship between two
// pathfinding-owned constants, not a caller/world-scale judgment call (unlike
// min_group_field_agents), so it stays a fixed default here rather than something
// every caller must independently re-derive and keep in sync by hand.
pub const default_group_field_rebuild_min_steps: u32 = 8;
// PER-STEP cap: the actual lever that bounds a single frame's worst-case group-field
// cost (unlike group_field_max_cells, which only bounds how many steps a build can take
// in total — a single expand() call can still spend this many cells' worth of work in
// one step regardless of the total cap). NOT free to lower in isolation: a shared field
// must finish flooding a full-size world well within one rekey cadence or it can never
// catch a moving goal (the field completes, but always for an already-superseded goal
// cell, so it never matches the CURRENT request key and is never sampled — see
// pathfinding-group-field-detour-moving's samples_total>0 regression guard, calibrated
// to a 120px/s pursuit goal on a 256x256/32px grid needing ~8 steps to fully flood at
// this budget against a 16-step rekey cadence). Real per-frame cost is bounded instead
// by min_group_field_agents gating the feature to battle-scale crowds (see
// game_demo_state.proceduralPathfindingCapacity) and group_field_max_cells preventing a
// pathological total build size, not by starving the per-step relax rate itself.
pub const default_group_field_build_budget: usize = 8192;
// Fixed cap on total distinct cells one flow-field build may cover, independent of world
// size — without this, a build floods the WHOLE reachable component from the goal (the
// entire grid in open terrain), so cost scales with world size, violating this module's
// "per-query work is a fixed constant" rule (see max_abstract_nodes' doc comment for the
// same principle applied to abstract search). Deliberately generous (well above any
// current world's cell count, e.g. the 256x256/32px demo world's 65536 cells) rather than
// tight against the per-step budget: a build's REQUIRED coverage is set by the distance
// from the goal to the farthest sharer, not by this constant, and a cap too close to a
// real world's cell count silently truncates the field before it ever reaches agents on
// the far side of a detour (starving them into permanent individual-solve fallback,
// exactly the failure pathfinding-group-field-detour-moving's samples_total>0 regression
// guard exists to catch). This bounds a FUTURE much larger world's worst case while
// staying a no-op ceiling for any world built today; group_field_build_budget (the
// PER-STEP cap) is the lever that actually bounds per-frame cost, since a single step can
// still process up to that many cells regardless of this total.
pub const default_group_field_max_cells: usize = 131072;
// Group-field threshold: same-goal sharers required in one step before a shared flow field
// builds. The gated cost: a shared field floods up to group_field_max_cells cells at
// group_field_build_budget cells per step, so it earns that cost only for a large same-goal
// crowd. A FIXED per-query policy constant: never derived from world size, cell count, or
// population (PathfindingSystem.groupFieldThreshold only clamps it to
// [1, max(min_capacity_floor, max_agent_budget)], with the ceiling frozen at reserve, so it
// never demands more sharers than the configured ceiling admits).
pub const default_min_group_field_agents: usize = 1024;
// Library default initial elastic agent ceiling for bare callers (benches, tests). The demo
// derives its own from content. The population seam raises it (raiseAgentBudget) whenever
// the steering population outgrows it; the raise is never refused.
pub const default_max_agent_budget: usize = 4096;
// Smallest agent count the per-step caps are derived for. The derived capacity
// tracks the live crowd down to this floor (so a tiny demo settles tiny), but never
// below it, so an empty/near-empty step keeps a usable minimum and avoids thrash.
pub const min_capacity_floor: usize = 8;
// Sustained-low-load window (in steps, ~2s at 60Hz) the agent count must stay below
// half of the live capacity before pools shrink. Grow-fast / shrink-slow hysteresis
// keeps an oscillating battle from reallocating every frame.
pub const default_capacity_shrink_window: u32 = 120;
// Per-step / per-memory caps are derived from agent_count via these ratios so a
// crowd of n drives n in-flight requests and a 4n result cache.
pub const cached_results_per_agent: usize = 4;
// Per-frame A* solve/fallback amortization ceiling, independent of the agent
// population: population scales the queue and cache (all agents can be queued, all
// paths cached), NOT the per-tick A* work, so a diverse-goal burst from a big group
// spreads across frames (the defer queue carries the remainder) instead of spiking a
// single frame. The shared-goal common case is absorbed by the group flow field, so
// this ceiling only backstops the pathological all-different-goals burst. The adaptive
// fallback tuner threads the work under it; 512 reflects the threaded per-frame budget
// (raised from the single-thread-era 256). Clamped down to the population so a tiny
// demo (8 agents) still caps at 8.
pub const default_max_solves_per_frame: usize = 512;
// Bounded outward radius (in cells) for projecting a blocked goal to the nearest
// open cell on its level.
pub const default_goal_projection_radius: i32 = 16;
// Side length (in nav cells) of one abstract chunk for a world-less nav build; with a
// world, nav chunks are the world's chunks. The chunk-portal graph is the structure that
// bounds per-query work independent of total cell count.
pub const default_nav_chunk_tiles: u16 = 16;
// Fixed abstract-cost penalty added when an abstract A* edge crosses a LevelLink.
// Kept above any single octile step so the search prefers staying on one level.
pub const inter_level_penalty: u32 = cardinal_cost * 4;
// Bounded node budget for the abstract A* over portal/link nodes. The abstract
// graph is small (portals scale with chunk borders, not cells), so this caps the
// per-query abstract work; refinement of each segment uses the local budget.
// This is the TIER-0 (first, cheap attempt) default — see PendingRequest.tier.
// A FIXED constant, deliberately never derived from world/graph size: per-query
// work must stay bounded independent of world size (see the existing
// "regardless of world size" test on the abstract solve, and the constant-set
// invariant nav_graph.zig's incremental-dig tests pin), so a request that does
// not fit is a bounded, honest "try the bigger fixed tier-1 budget next", never
// a bigger number picked because THIS map happened to need it.
pub const default_max_abstract_nodes: usize = 4096;
// Cap on the stored stitched-path cells per cached cross-chunk/cross-level result.
// An abstract corridor is refined into a single grid-adjacent (level,cell) path by
// stitching local A* segments; this bounds that path. A stitched path that exceeds
// the cap spills to a later frame (budget_exhausted) and is retried from the agent's
// advanced position, so the cap is never a silent truncation. Tier-0 default; see
// default_max_abstract_nodes's doc comment for why this stays fixed.
pub const default_max_stitched_path_cells: usize = 512;
// Tier-0 (first-attempt) abstract-search attempt caps, independently settable from
// max_abstract_nodes/max_stitched_path_cells (the tier-1 ceiling below) so a
// caller/test can force a deterministic tier-0 saturation without disturbing tier 1.
// Default equals the historical fixed defaults, so the common case's solve cost is
// unchanged by the tier split.
pub const default_tier0_abstract_node_attempt_cap: usize = default_max_abstract_nodes;
pub const default_tier0_stitched_attempt_cap: usize = default_max_stitched_path_cells;
// Tier-1 (second, escalated attempt) caps: FIXED constants, a flat multiple of the
// tier-0 defaults, exactly like every other budget in this module — NOT derived from
// or scaled to the built graph's portal count, level size, or any other measured
// world state (a prior version of this fix did that and was rejected: worlds vary in
// size, so a budget must stay bounded independent of it, matching this file's other
// "independent of total cell count" / "independent of world size" invariants). A
// request that still exhausts the tier-1 budget is genuinely hard for THIS fixed
// budget, not "this particular map is big" — see PendingRequest.tier and
// compactPendingAfterSolve's budget_exhausted handling, which drops such a request to
// `.missing` (retryable later, never `.unavailable`) rather than growing the budget.
pub const default_tier1_abstract_node_cap: usize = default_max_abstract_nodes * 4;
pub const default_tier1_stitched_cell_cap: usize = default_max_stitched_path_cells * 4;
/// Link pairs (entrance box, exit box, least cost) in a nav graph's long-link summary: a
/// precision width, never a capacity, since past it pairs merge and no link is dropped. The
/// abstract heuristic scans the entrance boxes on a push whose short-link estimate exceeds the
/// pair floor, so the scan stays a few vector steps beside the heap sift that push already
/// pays, and the pair chain closure stays a fixed cold 16^3.
pub const long_link_pairs: usize = 16;
/// Largest per-level crossing rate the heuristic charges: keeps a box term (planar octile below
/// 2^20 plus a level gap below 2^16 times this rate) inside an i32 lane.
pub const crossing_rate_cap: u32 = 1 << 14;
/// Clamp on every long-term lane value (box term, pair cost, chain bound, pair floor), so the
/// sum of two clamped lanes stays inside an i32. Clamping only lowers a lower bound.
pub const long_lane_cap: i32 = (1 << 30) - 1;

comptime {
    std.debug.assert(long_link_pairs % simd.lane_count == 0);
    std.debug.assert(2 * @as(i64, long_lane_cap) <= std.math.maxInt(i32));
}
// FIXED cap on the number of per-segment local A* runs one stitchCorridor call may
// attempt (solve.zig). max_abstract_nodes only loosely bounds this (a corridor can be
// at most that many portals long), which is far too loose to bound real per-frame
// cost: each non-link segment can independently spend up to max_explored_nodes doing
// its own local search, so total stitch work is corridor_length * max_explored_nodes,
// NOT the additive "abstract budget plus local budget" a corridor walk might suggest.
// Without this, a long, portal-dense corridor (more likely after digging carves an
// irregular tunnel network with many small chunks/portals) multiplies that per-segment
// cost by however many portals the corridor happens to cross — scaling with graph
// structure, exactly what this module's budgets must never do. A stitch that exceeds
// this is budget_exhausted (retried next frame), matching every other spill path here.
// Sized generously above the "lake detour: reported-bug scale" test's corridor (a
// 256x256/16-tile-chunk full-height-and-back detour around a single-gap wall, the
// worst legitimate corridor this suite exercises), not tuned tight to it — tight
// against one scenario risks silently starving a different, longer legitimate
// corridor exactly like an undersized group_field_max_cells starved far-side group
// members (see that constant's doc comment for the same failure shape).
pub const default_max_stitch_segments: usize = 512;
// Steps after which a cached result is re-solved when next requested, so an agent
// picks up world changes that did not directly cross its path. 0 disables. ~5s at 60Hz.
pub const default_cache_ttl_steps: u32 = 300;

pub const no_parent: usize = std.math.maxInt(usize);
pub const no_cell: u32 = std.math.maxInt(u32);
pub const no_component: u32 = 0;
pub const diagonal_cost: u32 = 14;
pub const cardinal_cost: u32 = 10;
pub const unreachable_cost: u32 = std.math.maxInt(u32);
/// Sentinel slot id of the open-addressed search and field tables: no parent, no bucket
/// link. `hashTableSlots` keeps every real slot id below it.
pub const no_slot: u32 = std.math.maxInt(u32);
/// Largest generation of a table stamp `generation << 1 | flag`; the next one wraps to 1
/// after clearing every stamp.
pub const max_stamp_generation: u32 = std.math.maxInt(u32) >> 1;

// Half-open-rect shrink applied to a max world coordinate before clamping to a cell, so a
// rect whose edge lands exactly on a cell boundary does not spuriously include the next
// cell. Must stay identical at every rect->cell site for remask-vs-rebuild parity.
pub const rect_edge_epsilon: f32 = 0.001;

comptime {
    // The abstract search identifies a node by a packed (level << 32) | cell ref
    // stored in a usize, so the target must have a 64-bit usize.
    if (@bitSizeOf(usize) < 64) @compileError("pathfinding abstract node refs require a 64-bit usize");
}

// Packs an abstract node identity: a portal cell on a level. A packed ref's top 16 bits are
// always 0 (level is a u16), so no real packed ref equals no_parent (maxInt).
pub fn packRef(level: u16, local: u32) usize {
    return (@as(usize, level) << 32) | local;
}

comptime {
    if (packRef(std.math.maxInt(u16), std.math.maxInt(u32)) == no_parent) {
        @compileError("packRef must never alias the no_parent sentinel");
    }
}

pub fn refLevel(ref: usize) u16 {
    return @intCast(ref >> 32);
}

pub fn refLocal(ref: usize) u32 {
    return @truncate(ref);
}

pub const PathStatus = enum {
    missing,
    pending,
    available,
    unavailable,
};

pub const PathView = struct {
    status: PathStatus = .missing,
    next_waypoint: math.Vec2 = .{},
    path_len: usize = 0,
};

// One static-obstacle edit for an incremental nav update: a world tile flip on `level` at
// tile `(x, y)`. Compact coordinates only (no world handle); the world is passed alongside
// the batch so the level's mask is re-derived from authoritative state.
pub const NavCellEdit = struct {
    level: u16,
    x: u16,
    y: u16,
};

/// What one nav mark changed.
pub const NavMarkKind = enum(u8) {
    /// An inclusive world tile box (tile and obstacle events).
    tile_box,
    /// An inclusive nav-cell span a static collider covered or covers.
    static_span,
};

/// One recorded nav change, consumed by the next nav batch. Coordinates are inclusive.
pub const NavMark = struct {
    level: u16,
    kind: NavMarkKind,
    min_x: u32,
    min_y: u32,
    max_x: u32,
    max_y: u32,
};

/// Main-thread wall time of one nav reaction's ordered sections, in ns, summed over its level
/// builds and marks batch. No section spans a stage job, dispatched or inline, so the reaction's
/// main time minus their sum and its inline stage time is untimed glue. Zero in ReleaseFast and
/// ReleaseSmall (`StageTimer`). Diagnostic only.
pub const NavMainPhases = struct {
    // The terrain records' event check and `nav_mark`'s profile select, tally reset, and
    // window append.
    mark_ns: u64 = 0,
    // The key plan's window sizing, staging reserve, and merge or swap.
    plan_ns: u64 = 0,
    // Patch info, cell blocks, records, the connectivity and closure prepare, the registry,
    // and the eviction sizing.
    reserve_ns: u64 = 0,
    // Link fold, remask claim and release loops, record claims and releases.
    commit_ns: u64 = 0,
    // The connectivity merge of rows, unions, and groups.
    conn_merge_ns: u64 = 0,
    // The connectivity layout, settle, set opening, and finish.
    conn_layout_ns: u64 = 0,
    // The flood rounds' builds, merges, and closes.
    flood_ns: u64 = 0,
    // The closure's touch, terminal merge, A lists, blocks, round lists, and commit.
    closure_ns: u64 = 0,
    // Eviction's hit removal, the registry flush outside its dispatch, and a rebuilt level's
    // cache and request clear.
    evict_ns: u64 = 0,
};

// Diagnostics for one nav update (level builds plus the marks batch). Recorded by the
// caller into runtime perf metrics. A step with nothing to apply leaves every counter zero.
pub const NavUpdateStats = struct {
    // Chunks the marks batch remasked (the changed chunks).
    dirty_chunks: usize = 0,
    // 1 when the marks batch changed the graph; else 0.
    incremental_rebuilds: usize = 0,
    // Chunks whose records the marks batch re-derived: the changed chunks, their orthogonal
    // neighbours, and both endpoint chunks of every newly added link.
    chunks_patched: usize = 0,
    // Levels built from the world this update: added levels and levels whose content
    // changed without per-cell events.
    levels_built: usize = 0,
    // Records the marks batch left holding portals.
    records_patched: usize = 0,
    // Remask, patch, mark, and eviction dispatch time that ran on workers; inline stages
    // add nothing. Diagnostic only.
    off_main_stage_ns: u64 = 0,
    // The same stages' time run inline on the main thread. Diagnostic only.
    inline_stage_ns: u64 = 0,
    // The marks batch's chunk remask; empty when no marks batch changed the graph. Level
    // builds' remasks are not in it.
    remask_batch: BatchStats = .{},
    // Path eviction: the pre-commit bound count over the changed keys, the halo walk over
    // their registrations, and the registry flush of the removals.
    evict_count_batch: BatchStats = .{},
    evict_batch: BatchStats = .{},
    evict_flush_batch: BatchStats = .{},
    // Registry entries the halo walk visited, the cached results it evicted, and the group
    // fields a changed cell next to a costed cell dropped.
    evict_entries_visited: usize = 0,
    evicted_results: usize = 0,
    dropped_fields: usize = 0,
    // The connectivity stages of the level builds and the marks batch, summed: the seed over
    // changed keys, the gather over patch keys and new links, and the flood over its searches
    // (every round folded into one).
    conn_seed_batch: BatchStats = .{},
    conn_gather_batch: BatchStats = .{},
    conn_flood_batch: BatchStats = .{},
    // The fewest and most searches any flood round dispatched (both zero with no round), and
    // the flood rounds' dispatch time on workers. Diagnostic only.
    conn_round_items_min: usize = 0,
    conn_round_items_max: usize = 0,
    conn_flood_off_main_ns: u64 = 0,
    // Active sets the flood rounds' builds walked on the main thread. Diagnostic only.
    conn_build_visits: usize = 0,
    // Across level builds and the marks batch: connectivity root-groups united, flood families
    // and rounds, nodes the floods expanded, components a flood split off, and roots merged
    // into another.
    conn_groups: usize = 0,
    conn_families: usize = 0,
    conn_rounds: usize = 0,
    conn_flood_nodes: usize = 0,
    conn_splits: usize = 0,
    conn_merges: usize = 0,
    // The one-way closure's stages across level builds and the marks batch: the candidate
    // scan and compaction (prepare), and link resolve, row mask, SCC plan, and rows (rounds
    // folded into one).
    conn_candidates_batch: BatchStats = .{},
    conn_closure_compact_batch: BatchStats = .{},
    conn_closure_resolve_batch: BatchStats = .{},
    conn_closure_mask_batch: BatchStats = .{},
    conn_closure_plan_batch: BatchStats = .{},
    conn_closure_rows_batch: BatchStats = .{},
    // The closure's components touched, links resolved, terminals new and left, rows
    // recomputed (|A|), row rounds (round 0 included), arena words written, and blocks
    // narrowed, summed;
    // compactions; and the arena's live and dead words and its allocated words after the
    // last batch.
    closure_touched: usize = 0,
    closure_links: usize = 0,
    closure_terms_new: usize = 0,
    closure_terms_left: usize = 0,
    closure_a_rows: usize = 0,
    closure_rounds: usize = 0,
    closure_words_written: usize = 0,
    closure_shrinks: usize = 0,
    closure_compactions: usize = 0,
    closure_live_words: usize = 0,
    closure_dead_words: usize = 0,
    closure_arena_capacity: usize = 0,
    // Each the most over the update's closure batches: the arena tail words a batch's bound
    // reserved and its relocated blocks took, the arena's word limit after its prepare, its
    // candidate components' block words, the live words at its prepare, and the terminals it
    // could number.
    closure_tail_bound: usize = 0,
    closure_tail_used: usize = 0,
    closure_arena_limit: usize = 0,
    closure_candidate_words: usize = 0,
    closure_live_prepared: usize = 0,
    closure_kb: usize = 0,
    // The reaction's main-thread sections, the terrain records' `nav_mark` folded in.
    main: NavMainPhases = .{},

    /// Adds a stage batch's time: to `inline_stage_ns` when it ran inline, else to
    /// `off_main_stage_ns`.
    pub fn addStageTime(self: *NavUpdateStats, batch: BatchStats) void {
        if (batch.ran_inline) {
            self.inline_stage_ns += batch.batch_duration_ns;
        } else {
            self.off_main_stage_ns += batch.batch_duration_ns;
        }
    }

    pub fn recordTo(self: NavUpdateStats, perf: runtime_perf_log.Context) void {
        perf.recordMetric(.nav_dirty_chunks, metric(self.dirty_chunks));
        perf.recordMetric(.nav_incremental_rebuilds, metric(self.incremental_rebuilds));
        perf.recordMetric(.nav_chunks_patched, metric(self.chunks_patched));
        perf.recordMetric(.nav_levels_built, metric(self.levels_built));
        perf.recordMetric(.nav_records_patched, metric(self.records_patched));
        perf.recordBatch(.nav_remask, self.remask_batch);
        perf.recordBatch(.nav_connect, self.conn_flood_batch);
        perf.recordBatch(.nav_closure, self.conn_closure_rows_batch);
        perf.recordBatch(.nav_evict, self.evict_batch);
    }
};

fn metric(value: usize) u64 {
    return @intCast(value);
}

test "nav update stats record the remask, the connectivity flood, the closure rows, and the eviction halo walk under their own perf stages" {
    if (!runtime_perf_log.enabled) return error.SkipZigTest;
    var perf = runtime_perf_log.RuntimePerfLog.init(0);
    const stats = NavUpdateStats{
        .remask_batch = .{ .item_count = 5 },
        .conn_seed_batch = .{ .item_count = 7 },
        .conn_gather_batch = .{ .item_count = 8 },
        .conn_flood_batch = .{ .item_count = 6 },
        .conn_closure_resolve_batch = .{ .item_count = 10 },
        .conn_closure_rows_batch = .{ .item_count = 9 },
        .evict_count_batch = .{ .item_count = 2 },
        .evict_batch = .{ .item_count = 3 },
        .evict_flush_batch = .{ .item_count = 4 },
    };
    stats.recordTo(runtime_perf_log.Context.bind(&perf));
    const remask = perf.batches[@backingInt(runtime_perf_log.BatchStage.nav_remask)];
    const connect = perf.batches[@backingInt(runtime_perf_log.BatchStage.nav_connect)];
    const evict = perf.batches[@backingInt(runtime_perf_log.BatchStage.nav_evict)];
    try std.testing.expectEqual(@as(u64, 1), remask.calls);
    try std.testing.expectEqual(@as(u64, 5), remask.items);
    try std.testing.expectEqual(@as(u64, 1), connect.calls);
    try std.testing.expectEqual(@as(u64, 6), connect.items);
    const closure = perf.batches[@backingInt(runtime_perf_log.BatchStage.nav_closure)];
    try std.testing.expectEqual(@as(u64, 1), closure.calls);
    try std.testing.expectEqual(@as(u64, 9), closure.items);
    try std.testing.expectEqual(@as(u64, 1), evict.calls);
    try std.testing.expectEqual(@as(u64, 3), evict.items);
}

pub const GridCell = struct {
    x: i32,
    y: i32,
};

// Inclusive nav-cell rectangle (grid coordinates) recomputed by the incremental
// nav remask for one dirty tile edit.
pub const NavSpan = struct {
    min_x: usize,
    min_y: usize,
    max_x: usize,
    max_y: usize,
};

// Single source of the chunk-tiling geometry shared by NavGrid and NavGraph: the chunk_id
// <-> cell mapping and the chunk-local label encoding. NavGrid encodes labels as
// chunk_id * labelStride() + local; NavGraph decodes the owning chunk back via integer
// division. Both delegate here so the encode/decode and chunk bounds cannot drift apart.
pub const ChunkGeometry = struct {
    width: usize,
    height: usize,
    chunk_tiles: usize,

    pub const Bounds = struct { x0: usize, y0: usize, x1: usize, y1: usize };

    pub fn chunksX(self: ChunkGeometry) usize {
        return (self.width + self.chunk_tiles - 1) / self.chunk_tiles;
    }

    pub fn chunksY(self: ChunkGeometry) usize {
        return (self.height + self.chunk_tiles - 1) / self.chunk_tiles;
    }

    pub fn chunkCount(self: ChunkGeometry) usize {
        return self.chunksX() * self.chunksY();
    }

    pub fn chunkOf(self: ChunkGeometry, cell_index: usize) u32 {
        const cx = (cell_index % self.width) / self.chunk_tiles;
        const cy = (cell_index / self.width) / self.chunk_tiles;
        return @intCast(cy * self.chunksX() + cx);
    }

    // Cell rect [x0,x1) x [y0,y1) of one chunk, clamped to the grid.
    pub fn chunkBounds(self: ChunkGeometry, chunk_id: u32) Bounds {
        const cx_count = self.chunksX();
        const cx = chunk_id % cx_count;
        const cy = chunk_id / cx_count;
        const x0 = cx * self.chunk_tiles;
        const y0 = cy * self.chunk_tiles;
        return .{
            .x0 = x0,
            .y0 = y0,
            .x1 = @min(x0 + self.chunk_tiles, self.width),
            .y1 = @min(y0 + self.chunk_tiles, self.height),
        };
    }

    // Per-chunk label stride: chunk_tiles^2 + 1 (max local labels per chunk plus the
    // reserved 0). Computed in u64 for headroom on the encode multiply; encoded labels
    // are asserted to fit u32 at the encode site.
    pub fn labelStride(self: ChunkGeometry) u64 {
        const ct: u64 = self.chunk_tiles;
        return ct * ct + 1;
    }
};

/// Goal-keyed query identity. nav_version invalidates old work on rebuild without
/// pointer comparisons. The start cell is intentionally absent so a moving agent
/// reuses one shared in-flight/cached result per goal. The goal level is part of
/// the key so cross-level goals to the same cell on different floors are distinct
/// cache/pending/group entries.
pub const PathQueryKey = struct {
    nav_version: u32,
    agent_class: PathAgentClass,
    goal_level: u16 = 0,
    goal: GridCell,
};

/// How an agent class moves over nav. Each traversal owns one nav graph (grid plus
/// connectivity); classes that move alike share it.
pub const TraversalClass = enum(u8) {
    walk,
};

/// The traversal of `class`. Exhaustive, so a new class does not compile until it is mapped.
pub fn traversalOf(class: PathAgentClass) TraversalClass {
    return switch (class) {
        .default => .walk,
    };
}

pub const PathfindingCapacity = struct {
    // NOTE: this type doubles as both the caller-supplied base config (passed to
    // reserve()/applyDerivedCapacity) AND the internal derived-capacity storage
    // (self.capacity). The five fields below are the DERIVED side only: deriveCapacity
    // unconditionally recomputes and overwrites them from agent_count/max_agent_budget
    // every time capacity is applied, so a value set here on a caller-constructed
    // PathfindingCapacity has NO effect — it is silently discarded before first use.
    // Configure population/throughput scaling via max_agent_budget instead; these fields
    // exist on this type only because deriveCapacity's output is stored back into it.
    max_frame_requests: usize = default_max_frame_requests,
    max_pending_requests: usize = default_max_pending_requests,
    max_cached_results: usize = default_max_cached_results,
    max_solved_requests_per_step: usize = default_max_solved_requests_per_step,
    max_fallback_requests_per_step: usize = default_max_fallback_requests_per_step,
    // Threaded participant slots (workers + 1). Set from the configured thread system
    // by the pipeline; each gets a search scratch slot sized by the node budgets at the
    // capacity seam. NOT recomputed by deriveCapacity — a genuine caller-supplied value.
    worker_participant_count: usize = default_worker_participant_count,
    // Budget-bounded A* sizing.
    max_explored_nodes: usize = default_max_explored_nodes,
    max_stored_path_cells: usize = default_max_stored_path_cells,
    // Abstract chunk-portal tier sizing. nav_chunk_tiles sets the abstract chunk side
    // length of a world-less build (a world supplies its own). max_abstract_nodes/max_stitched_path_cells bound the ESCALATED (tier-1)
    // abstract A*/stitched-corridor work — FIXED constants (default_tier1_*), never
    // derived from or scaled to world/graph size (see those constants' doc comments).
    nav_chunk_tiles: u16 = default_nav_chunk_tiles,
    max_abstract_nodes: usize = default_tier1_abstract_node_cap,
    max_stitched_path_cells: usize = default_tier1_stitched_cell_cap,
    // Tier-0 (first-attempt) abstract-search caps: independent of max_abstract_nodes/
    // max_stitched_path_cells above, so a caller/test can force a deterministic tier-0
    // saturation without disturbing the tier-1 ceiling.
    tier0_abstract_node_cap: usize = default_tier0_abstract_node_attempt_cap,
    tier0_stitched_cell_cap: usize = default_tier0_stitched_attempt_cap,
    // Caps per-segment local A* attempts within one stitchCorridor call, independent of
    // corridor/portal count. See default_max_stitch_segments' doc comment.
    max_stitch_segments: usize = default_max_stitch_segments,
    // Per-step cap on ESCALATED (tier-1) solve attempts admitted into the fallback
    // batch. Tier-1 attempts are the expensive ones (the derived, larger ceiling), so
    // bounding how many run in one step bounds worst-case per-step solver cost even
    // when several agents are simultaneously stuck. Tier-0 attempts are unaffected and
    // keep filling remaining slots up to max_fallback_requests_per_step as before.
    max_escalated_solves_per_step: usize = 1,
    // Managed shared-goal flow fields.
    max_group_fields: usize = default_max_group_fields,
    group_field_rebuild_min_steps: u32 = default_group_field_rebuild_min_steps,
    group_field_build_budget: usize = default_group_field_build_budget,
    group_field_max_cells: usize = default_group_field_max_cells,
    // Fixed per-query group-field threshold (same-goal sharers per step before a shared field
    // builds); never derived from world size. groupFieldThreshold clamps it to
    // [1, max(min_capacity_floor, max_agent_budget)], using the ceiling frozen at reserve.
    min_group_field_agents: usize = default_min_group_field_agents,
    // Initial elastic agent ceiling. Live capacity tracks the agent count up to it; the
    // population seam raises it (raiseAgentBudget) whenever the steering population
    // outgrows it. Library default for bare callers (benches, tests); the demo derives its
    // own from content.
    max_agent_budget: usize = default_max_agent_budget,
    // Steps the agent count must stay below half capacity before pools shrink.
    capacity_shrink_window: u32 = default_capacity_shrink_window,
};

// Derives the per-step/memory caps from an agent count, clamped to [floor,
// max_agent_budget ceiling]. Population scales the QUEUE and CACHE (frame/pending
// requests, 4n cached results) so every agent can be queued and every path
// cached. Per-frame A* SOLVE work does NOT scale with population: the solve and
// fallback budgets are pinned to a fixed amortization ceiling (clamped down to
// the population so a tiny crowd caps low), so frame time stays bounded as the
// army grows. Algorithm/memory sizing (scratch, path strides, chunk size, group
// field count) is left untouched.
pub fn deriveCapacity(base: PathfindingCapacity, agent_count: usize) PathfindingCapacity {
    var cap = base;
    const clamped = std.math.clamp(agent_count, min_capacity_floor, @max(min_capacity_floor, base.max_agent_budget));
    cap.max_frame_requests = clamped;
    cap.max_pending_requests = clamped;
    cap.max_cached_results = clamped *| cached_results_per_agent;
    // Per-frame solve/fallback amortization ceiling, clamped down to the population
    // (fallback <= solves). Independent of crowd size so a diverse-goal burst spreads
    // across frames; the adaptive tuner threads the work under it.
    const solve_ceiling = @min(default_max_solves_per_frame, clamped);
    cap.max_solved_requests_per_step = solve_ceiling;
    cap.max_fallback_requests_per_step = solve_ceiling;
    return cap;
}

pub const PathfindingConfig = struct {
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    fallback_adaptive_tuner: ?*AdaptiveWorkTuner = null,
    max_solved_requests_per_step: ?usize = null,
    max_fallback_requests_per_step: ?usize = null,
};

pub const PathfindingStats = struct {
    accepted_requests: usize = 0,
    duplicate_requests: usize = 0,
    pending_requests: usize = 0,
    solved_requests: usize = 0,
    fallback_requests: usize = 0,
    available_results: usize = 0,
    unavailable_results: usize = 0,
    dropped_requests: usize = 0,
    deferred_requests: usize = 0,
    fallback_deferred_requests: usize = 0,
    cache_hits: usize = 0,
    cache_evictions: usize = 0,
    // Solver and flow-field counters.
    budget_exhausted: usize = 0,
    // Tier-1 (escalated) solve attempts admitted into this step's fallback batch, and
    // tier-1-ready requests that were NOT admitted because max_escalated_solves_per_step
    // was already reached this step (they simply wait for a later step).
    escalated_solves: usize = 0,
    escalated_deferred: usize = 0,
    // A tier-1 attempt that still exhausted its (fixed) budget: dropped from pending, so
    // the next query falls through to `.missing` (retryable later) rather than a false
    // `.unavailable`. See compactPendingAfterSolve.
    escalated_dropped: usize = 0,
    // Start-side solve failures dropped from pending (see PathSolveResult.start_invalid).
    start_invalid_dropped: usize = 0,
    // Requests and solves answered unavailable because the start cannot reach the goal, or
    // no open goal cell lies within the projection radius; never cached, never searched.
    // Counted in `unavailable_results` too.
    reach_unavailable: usize = 0,
    // Intake requests whose blocked goal the step's goal table did not hold, so intake
    // projected it itself.
    goal_fallbacks: usize = 0,
    // Accepted requests whose goal cell was blocked (their live goal is its projection).
    goal_projected: usize = 0,
    group_fields_built: usize = 0,
    group_field_reuses: usize = 0,
    group_field_rebuild_throttled: usize = 0,
    group_field_samples: usize = 0,
    // Abstract-tier and cross-level routing counters.
    abstract_solves: usize = 0,
    cross_level_solves: usize = 0,
    // Diagnostic only: the most per-segment local A* searches any single stitchCorridor
    // call needed this step, aggregated across workers in finishUpdate (see
    // SearchScratch.max_stitch_segments_used). Lets a live perf capture distinguish "the
    // fixed max_stitch_segments cap is what's bounding solve cost" (this stays pinned at
    // or near the cap every spike) from "some other cost dominates" (this stays low).
    max_stitch_segments_observed: usize = 0,
    // Diagnostic only: distinct group keys tallied this step, after decay/compaction —
    // see beginSolve's doc comment for why this distinguishes the two group-cost failure
    // shapes a live perf capture can't otherwise tell apart.
    distinct_group_keys: usize = 0,
    fallback_batch: BatchStats = .{},
    // Request classification (`path_intake`) and the group-field advance and begin
    // passes (`group_field_expand`); inline stages report `ran_inline`.
    intake_batch: BatchStats = .{},
    group_field_batch: BatchStats = .{},
    group_field_begin_batch: BatchStats = .{},
    // The publish byte copy and registration bucketing (`publish_copy`), the path
    // registry's owner ops and adds (`registry_flush`), and a shrink's byte moves
    // (`resize_copy`).
    publish_copy_batch: BatchStats = .{},
    registry_flush_batch: BatchStats = .{},
    resize_copy_batch: BatchStats = .{},
    // Path registry entries added and removed by this update's flush, and the registry's
    // shard storage growths.
    registrations_added: usize = 0,
    registrations_removed: usize = 0,
    registry_grows: usize = 0,
    // Per-phase update timings (ns); zero when perf logging is disabled. Recorded
    // as pathfinding_* sub-stage timers that break down pipeline_pathfinding.
    accept_ns: u64 = 0,
    group_service_ns: u64 = 0,
    solve_ns: u64 = 0,
    publish_ns: u64 = 0,

    pub fn solveBatch(self: PathfindingStats) BatchStats {
        return self.fallback_batch;
    }
};

/// One step's goal resolve (`PathfindingSystem.resolveGoals`): the intents scanned, those
/// whose goal cell was blocked, the distinct blocked goals the table holds, the projections
/// computed (one per distinct goal), and the scan and project stage batches.
pub const GoalResolveStats = struct {
    intents: usize = 0,
    blocked: usize = 0,
    distinct: usize = 0,
    projections: usize = 0,
    scan_batch: BatchStats = .{},
    project_batch: BatchStats = .{},
};

// A distinct group goal and how many agents declared it this step; the count
// gates flow-field building.
pub const GroupRequestTally = struct {
    key: PathQueryKey,
    count: usize,
};

/// One classified request of the `path_intake` stage, written into its range's window
/// of the item-capacity record buffer: a candidate (its range's repeats folded in), or an
/// expired result to remove. Classified against step-start state only; the main-thread
/// merge resolves expiry, in-step duplicates, and the pending cap in request order.
pub const IntakeRecord = struct {
    entity: EntityId,
    key: PathQueryKey,
    start_level: u16,
    start: GridCell,
    // The key's cached result was expired at step start: the merge removes it.
    expired: bool,
    // Not served by a group field, a cache, or a reach answer, and not pending at step
    // start.
    candidate: bool,
    // The goal cell was blocked: its live goal is its projection.
    projected: bool,
    // Later candidate requests for the same key in this range, folded into this record.
    repeats: usize,
};

/// A group goal key and its request count within one intake range, in the range's
/// first-occurrence order. A key may repeat later in the same window (the job's recent
/// table is fixed-size); the merge sums repeats, so counts stay exact.
pub const GroupKeyCount = struct {
    key: PathQueryKey,
    count: usize,
};

/// One intake range's counts, written once by its job; on its own cache lines.
pub const IntakeTally = struct {
    record_count: usize align(thread_shared_record_alignment) = 0,
    group_key_count: usize = 0,
    dropped_requests: usize = 0,
    duplicate_requests: usize = 0,
    cache_hits: usize = 0,
    available_results: usize = 0,
    unavailable_results: usize = 0,
    group_field_samples: usize = 0,
    reach_unavailable: usize = 0,
    goal_fallbacks: usize = 0,
};

/// Intake range alignment: a multiple of the SIMD lane count at which every range's
/// record and group-key windows start on a cache line.
pub const intake_range_alignment_items: usize = 2 * simd.lane_count;

comptime {
    std.debug.assert(intake_range_alignment_items % simd.lane_count == 0);
    std.debug.assert((@sizeOf(IntakeRecord) * intake_range_alignment_items) % thread_shared_record_alignment == 0);
    std.debug.assert((@sizeOf(GroupKeyCount) * intake_range_alignment_items) % thread_shared_record_alignment == 0);
    std.debug.assert(@sizeOf(IntakeTally) % thread_shared_record_alignment == 0);
}

pub const PendingRequest = struct {
    entity: EntityId,
    key: PathQueryKey,
    // Level the representative start cell lives on. The goal level is carried by
    // key.goal_level; a differing start/goal level routes cross-level.
    start_level: u16,
    // Representative start cell for the single A* solve run for this goal key.
    start: GridCell,
    // Two-tier retry ladder: 0 is the first (cheap, fixed-budget) attempt; a
    // budget_exhausted at tier 0 promotes to tier 1 (a larger but still FIXED
    // abstract-node/stitched-cell ceiling — never derived from world/graph size) and
    // rotates to the back of pending once. A budget_exhausted AT tier 1 drops the
    // request (not `.unavailable`: the goal is reachable, it just did not fit either fixed
    // budget) — worst case exactly two solve attempts per request. Reset implicitly: a
    // solved or dropped entry leaves pending entirely.
    tier: u8 = 0,
};

/// Deferred requests in FIFO order over a fixed slot buffer: logical index 0 is the
/// oldest. Dropping a front window and appending at the tail cost what they touch,
/// never the queue length. Main thread mutates; solve workers only read through `at`.
pub const PendingRing = struct {
    slots: std.ArrayList(PendingRequest) = .empty,
    head: usize = 0,
    len: usize = 0,

    pub fn deinit(self: *PendingRing, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
        self.* = undefined;
    }

    /// Resizes to `slot_count` slots and empties the ring. An OOM leaves the storage
    /// and contents as they were.
    pub fn reserve(self: *PendingRing, allocator: std.mem.Allocator, slot_count: usize) !void {
        try resizeArrayList(PendingRequest, &self.slots, allocator, slot_count);
        self.slots.items.len = slot_count;
        self.clear();
    }

    pub fn slotCount(self: *const PendingRing) usize {
        return self.slots.items.len;
    }

    pub fn clear(self: *PendingRing) void {
        self.head = 0;
        self.len = 0;
    }

    fn physicalIndex(self: *const PendingRing, logical: usize) usize {
        const slot_count = self.slots.items.len;
        std.debug.assert(logical < slot_count);
        const index = self.head + logical;
        return if (index >= slot_count) index - slot_count else index;
    }

    pub fn at(self: *const PendingRing, logical: usize) PendingRequest {
        std.debug.assert(logical < self.len);
        return self.slots.items[self.physicalIndex(logical)];
    }

    pub fn ptr(self: *PendingRing, logical: usize) *PendingRequest {
        std.debug.assert(logical < self.len);
        return &self.slots.items[self.physicalIndex(logical)];
    }

    /// Appends at the tail. The caller gates on its logical pending limit, which every
    /// reserve keeps at or below the slot count.
    pub fn push(self: *PendingRing, request: PendingRequest) void {
        std.debug.assert(self.len < self.slots.items.len);
        self.slots.items[self.physicalIndex(self.len)] = request;
        self.len += 1;
    }

    /// Removes the first `count` entries.
    pub fn dropFront(self: *PendingRing, count: usize) void {
        std.debug.assert(count <= self.len);
        if (count == 0) return;
        const slot_count = self.slots.items.len;
        const index = self.head + count;
        self.head = if (index >= slot_count) index - slot_count else index;
        self.len -= count;
    }
};

// One cell of a stitched obstacle-aware corridor path, tagged with its level. The
// stitched path is grid-adjacent within each level's contiguous run; at an
// inter-level link the level changes between consecutive cells (a discrete jump,
// the only non-adjacent step). The query walks the run matching the agent's current
// level cell by cell, exactly like a single-level individual A* path.
pub const StitchedCell = struct {
    level: u16,
    cell: u32,
};

/// Words a stored stitched path of `len` cells occupies: its cells (one `u32` each), then
/// its levels packed two `u16` to a word.
pub fn stitchedWords(len: usize) usize {
    return len + (len + 1) / 2;
}

/// Words of one solve-output stripe and of one result-cache long block: the longest plain
/// path a local solve can return (one cell per explored node) or the longest stitched path.
pub fn resultBlockWords(max_explored_nodes: usize, max_stitched_path_cells: usize) usize {
    return @max(@as(usize, 1), @max(max_explored_nodes, stitchedWords(max_stitched_path_cells)));
}

/// Largest result block a run start can index: run starts are stored as `u16`.
pub const max_result_block_words: usize = std.math.maxInt(u16);

/// A pathfinding budget whose result block a run start cannot index, or whose field cap
/// a field's links cannot pack.
pub const BudgetError = error{PathfindingBudgetTooWide};

/// Words a stored result occupies: one per plain cell, or `stitchedWords` of its cells.
pub fn storedPathWords(path_len: usize, stitched_len: usize) usize {
    return if (stitched_len != 0) stitchedWords(stitched_len) else path_len;
}

/// A stored stitched path: its cells column, then its levels column.
pub const StitchedView = struct {
    cells: []const u32,
    levels: []const u16,

    pub fn len(self: StitchedView) usize {
        return self.cells.len;
    }

    pub fn at(self: StitchedView, index: usize) StitchedCell {
        return .{ .level = self.levels[index], .cell = self.cells[index] };
    }
};

/// `words` read as a stored stitched path of `len` cells (its first `stitchedWords(len)`).
pub fn stitchedView(words: []const u32, len: usize) StitchedView {
    std.debug.assert(stitchedWords(len) <= words.len);
    // The levels column starts on a u32 word, so it is u16-aligned and holds `len` levels.
    const levels: [*]const u16 = @ptrCast(words[len..].ptr);
    return .{ .cells = words[0..len], .levels = levels[0..len] };
}

/// Stores `cells` into `words` as a stitched path: the cells column, then the levels.
pub fn writeStitched(words: []u32, cells: []const StitchedCell) void {
    const len = cells.len;
    std.debug.assert(stitchedWords(len) <= words.len);
    // As in `stitchedView`: a u16-aligned levels column of `len` entries.
    const levels: [*]u16 = @ptrCast(words[len..].ptr);
    for (cells, words[0..len], levels[0..len]) |stitched, *cell, *level| {
        cell.* = stitched.cell;
        level.* = stitched.level;
    }
    // The half-word past an odd length is zero, so equal paths store equal words.
    if (len % 2 == 1) levels[len] = 0;
}

/// The (x, y) of a walk over a grid's cells: one division to start and after a step that
/// is not to a neighbouring cell, O(1) per neighbouring step.
pub const CellCursor = struct {
    width: usize,
    cell: usize,
    x: usize,
    y: usize,

    pub fn init(width: usize, cell: usize) CellCursor {
        return .{ .width = width, .cell = cell, .x = cell % width, .y = cell / width };
    }

    pub fn moveTo(self: *CellCursor, cell: usize) void {
        // Cell indices and widths are below 2^32.
        const delta: i64 = @as(i64, @intCast(cell)) - @as(i64, @intCast(self.cell));
        const width: i64 = @intCast(self.width);
        inline for (.{ -1, 0, 1 }) |dy| {
            const dx = delta - dy * width;
            const x = @as(i64, @intCast(self.x)) + dx;
            const y = @as(i64, @intCast(self.y)) + dy;
            // Index and coordinates are a bijection, so at most one (dx, dy) lands in range.
            if (dx >= -1 and dx <= 1 and x >= 0 and x < width and y >= 0) {
                self.* = .{ .width = self.width, .cell = cell, .x = @intCast(x), .y = @intCast(y) };
                return;
            }
        }
        self.* = init(self.width, cell);
    }
};

/// Path-registry shards. Each key lives in one shard, so a flush threads over shards.
pub const registry_shard_count: usize = 16;

/// The shard of registry key `key`: the top bits of an integer hash that is independent of
/// the shard tables' Fibonacci homes, so one shard's keys spread over its whole table.
pub fn registryShard(key: u64) usize {
    return @intCast(std.hash.int(key) >> registry_shard_shift);
}

const registry_shard_shift: u6 = @intCast(64 - @as(u32, std.math.log2_int(usize, registry_shard_count)));

comptime {
    std.debug.assert(std.math.isPowerOfTwo(registry_shard_count));
}

/// An owner-log entry: owner `old`'s registrations are removed (`new == no_owner`) or
/// renamed to owner `new`.
pub const OwnerOp = struct {
    old: u32,
    new: u32,
};

/// `OwnerOp.new` of a retire.
pub const no_owner: u32 = std.math.maxInt(u32);

/// One registration of a published path: its run's chunk key, the owning cache payload,
/// and the run's first stored cell (its registry entry's order).
pub const RegRecord = struct {
    key: u64,
    owner: u32,
    order: u32,
};

/// Per changed key of an eviction, at its index in the batch's changed keys. Its hit window
/// at `base` holds its path hits (`bound` at most), then its group-field hits (one slot per
/// field). `visited` counts the path registry entries walked. `owned` holds the registered
/// halo keys it owns (bit `(dy + 1) * 3 + (dx + 1)`).
pub const EvictItem = struct {
    bound: u32 = 0,
    base: u32 = 0,
    hits: u32 = 0,
    visited: u32 = 0,
    field_hits: u32 = 0,
    owned: u16 = 0,
};

/// Eviction range alignment: every range's items start on a cache line.
pub const evict_range_alignment_items: usize = 16;
/// Registration and hit windows start on a cache line: records and owner ids per line.
pub const reg_window_alignment_items: usize = thread_shared_record_alignment / @sizeOf(RegRecord);
pub const hit_window_alignment_items: usize = thread_shared_record_alignment / @sizeOf(u32);

comptime {
    std.debug.assert(@sizeOf(RegRecord) == 16);
    std.debug.assert(@sizeOf(EvictItem) == 24);
    std.debug.assert((@sizeOf(EvictItem) * evict_range_alignment_items) % thread_shared_record_alignment == 0);
}

pub const PathResult = struct {
    key: PathQueryKey,
    // Plain-path cells (start-to-goal order) for a same-component local solve, indexed
    // on path_level; zero for a stitched result. u32: a path is bounded by the solve's
    // node budget.
    path_len: u32,
    // Level the plain path cells index into (equals key.goal_level for a local solve).
    path_level: u16 = 0,
    // Number of stitched (level,cell) cells stored in the slot's stitched buffer.
    // Zero for a plain same-component local solve (path_len cells suffice); set for
    // an abstract chunk/cross-level corridor, whose full obstacle-aware path is
    // stitched from per-segment local A* and walked per-agent on its current level.
    stitched_len: u32 = 0,
    // The path's last cell: its stitched path's, or its plain path's on `path_level`.
    end: StitchedCell,
};

pub const PathSolveResult = union(enum) {
    // Successful solve; its solved path sits at the same fallback ordinal.
    available: PathQueryKey,
    // The start cannot reach the goal, or no open goal cell lies within the projection
    // radius: answered for the request, never cached and never searched.
    unavailable: PathQueryKey,
    deferred: PathQueryKey,
    // Budget spill: request stays pending; counted as budget-exhausted.
    budget_exhausted: PathQueryKey,
    // Start-side failure (blocked/off-grid representative start, unseedable start
    // component): a property of the representative agent, not of the goal. Dropped
    // from pending, never cached; the next status query falls through to `.missing`
    // (retryable).
    start_invalid: PathQueryKey,
};

pub const OpenNode = struct {
    index: usize,
    f: u32,
    h: u32,
};

// Comparator for binarySearch over a level's sorted compact label keys.
pub fn orderU32(key: u32, item: u32) std.math.Order {
    return std.math.order(key, item);
}
// Shared octile cost core: diagonal steps plus straight steps, in the local A*'s step
// cost units so abstract and refined costs are comparable. u64 so a pathological delta
// cannot overflow mid-formula; every caller saturates to u32.
fn octileCost(dx: u64, dy: u64) u64 {
    const diagonal = @min(dx, dy);
    const straight = @max(dx, dy) - diagonal;
    return diagonal * diagonal_cost + straight * cardinal_cost;
}

pub fn popHeap(heap: *std.ArrayList(OpenNode)) OpenNode {
    std.debug.assert(heap.items.len != 0); // empty pop would underflow `last` below
    const result = heap.items[0];
    const last = heap.items.len - 1;
    heap.items[0] = heap.items[last];
    heap.items.len = last;
    if (heap.items.len != 0) siftDown(heap.items, 0);
    return result;
}

pub const NeighborDir = struct {
    x: i32,
    y: i32,
    diagonal: bool = false,
};

pub const neighbor_dirs = [_]NeighborDir{
    .{ .x = 1, .y = 0 },
    .{ .x = 0, .y = 1 },
    .{ .x = -1, .y = 0 },
    .{ .x = 0, .y = -1 },
    .{ .x = 1, .y = 1, .diagonal = true },
    .{ .x = -1, .y = 1, .diagonal = true },
    .{ .x = -1, .y = -1, .diagonal = true },
    .{ .x = 1, .y = -1, .diagonal = true },
};

// Index of the neighbor_dirs entry opposite to each direction (negated components).
// Asserted at comptime against neighbor_dirs so the table can't drift from the layout.
pub const opposite_dir = blk: {
    var table: [neighbor_dirs.len]u8 = undefined;
    for (neighbor_dirs, 0..) |dir, i| {
        for (neighbor_dirs, 0..) |candidate, j| {
            if (candidate.x == -dir.x and candidate.y == -dir.y) {
                table[i] = @intCast(j);
                break;
            }
        } else @compileError("neighbor_dirs has no opposite for an entry");
    }
    break :blk table;
};

pub fn oppositeDirIndex(dir_index: usize) u8 {
    return opposite_dir[dir_index];
}

// Octile heuristic over explicit cell coordinates; callers pass coordinates they
// already hold so the hot loop avoids re-deriving them via div/mod. Saturates to
// maxInt(u32) instead of wrapping.
pub fn octileXY(from_x: i32, from_y: i32, to_x: i32, to_y: i32) u32 {
    const dx: u64 = @abs(to_x - from_x);
    const dy: u64 = @abs(to_y - from_y);
    return @intCast(@min(octileCost(dx, dy), @as(u64, std.math.maxInt(u32))));
}

/// Octile cost between two cells given by unsigned coordinates, valid for any level a
/// validated grid allows (coordinates and indices up to 2^32). Saturates like `octileXY`.
pub fn octileU32(ax: u32, ay: u32, bx: u32, by: u32) u32 {
    const dx: u64 = @max(ax, bx) - @min(ax, bx);
    const dy: u64 = @max(ay, by) - @min(ay, by);
    return @intCast(@min(octileCost(dx, dy), @as(u64, std.math.maxInt(u32))));
}

pub fn lessNode(a: OpenNode, b: OpenNode) bool {
    return a.f < b.f or
        (a.f == b.f and a.h < b.h) or
        (a.f == b.f and a.h == b.h and a.index < b.index);
}

pub fn siftUp(heap: []OpenNode, start_index: usize) void {
    var index = start_index;
    while (index != 0) {
        const parent = (index - 1) / 2;
        if (!lessNode(heap[index], heap[parent])) break;
        std.mem.swap(OpenNode, &heap[index], &heap[parent]);
        index = parent;
    }
}

pub fn siftDown(heap: []OpenNode, start_index: usize) void {
    var index = start_index;
    while (true) {
        const left = index * 2 + 1;
        if (left >= heap.len) break;
        const right = left + 1;
        var best = left;
        if (right < heap.len and lessNode(heap[right], heap[left])) best = right;
        if (!lessNode(heap[best], heap[index])) break;
        std.mem.swap(OpenNode, &heap[index], &heap[best]);
        index = best;
    }
}

pub fn keysEqual(a: PathQueryKey, b: PathQueryKey) bool {
    return a.nav_version == b.nav_version and
        a.agent_class == b.agent_class and
        a.goal_level == b.goal_level and
        a.goal.x == b.goal.x and
        a.goal.y == b.goal.y;
}

// FNV-1a 64-bit offset basis and prime of `hashPathKey`.
const fnv_offset_basis: u64 = 14695981039346656037;
const fnv_prime: u64 = 1099511628211;

pub fn hashPathKey(key: PathQueryKey) usize {
    var h: u64 = fnv_offset_basis;
    inline for (.{ key.nav_version, @backingInt(key.agent_class), @as(u32, key.goal_level), @as(u32, @bitCast(key.goal.x)), @as(u32, @bitCast(key.goal.y)) }) |part| {
        h ^= @as(u64, part);
        h *%= fnv_prime;
    }
    return @intCast(h);
}

/// Home slot of `key` in a power-of-two table of `2^(64 - shift)` slots (Fibonacci
/// hashing: the multiply spreads adjacent keys over the table).
pub fn fibonacciSlot(key: u64, shift: u6) usize {
    return @intCast((key *% 0x9E3779B97F4A7C15) >> shift);
}

/// Slot count of an open-addressed table holding at most `max_keys` keys at load <= 1/2:
/// `ceilPow2(max(16, 2 * max_keys))`. Fails as out of memory when the count overflows or
/// a slot id would not fit `u32`.
pub fn hashTableSlots(max_keys: usize) error{OutOfMemory}!usize {
    const slots = std.math.ceilPowerOfTwo(usize, @max(@as(usize, 16), max_keys *| 2)) catch return error.OutOfMemory;
    if (slots > std.math.maxInt(u32)) return error.OutOfMemory;
    return slots;
}

/// The `fibonacciSlot` shift of a power-of-two table of `slot_count` slots.
pub fn hashTableShift(slot_count: usize) u6 {
    std.debug.assert(std.math.isPowerOfTwo(slot_count) and slot_count >= 2);
    return @intCast(@as(usize, 64) - std.math.log2_int(usize, slot_count));
}

pub fn emptyKey(nav_version: u32) PathQueryKey {
    return .{
        .nav_version = nav_version,
        .agent_class = .default,
        .goal = .{ .x = 0, .y = 0 },
    };
}

// Grows `list` to hold exactly `len` items (reusing capacity) and sets the active
// length, leaving the new tail uninitialized — callers fill or @memset it. Collapses
// the repeated ensureTotalCapacity + items.len pair.
pub fn setLen(list: anytype, allocator: std.mem.Allocator, len: usize) !void {
    try list.ensureTotalCapacity(allocator, len);
    list.items.len = len;
}

// Whether a list should shrink-and-free before regrowing to `target_capacity`, given its
// current physical `current_capacity`. Hysteresis (only below HALF, not merely below) so
// the allocator's own size-class rounding slack — ensureTotalCapacity commonly hands back
// more than requested — does not perpetually free-then-reallocate the same padded
// capacity on every repeated reserve() call at an unchanged logical target. A genuine
// large downsize still frees memory; only the "target == last target, but < the padded
// physical capacity" false positive is absorbed. Shared by every reserve()-style
// function in this package so the fix lives in one place.
pub fn shouldShrinkCapacity(current_capacity: usize, target_capacity: usize) bool {
    return target_capacity *| 2 < current_capacity;
}

// Grows (amortized) or shrinks-and-frees a per-step scratch list's backing capacity
// to `capacity`, leaving it empty. Used for lists the update repopulates each step,
// so no contents need to survive the resize. Shrinking frees memory back.
//
// Failure-atomic: a shrink allocates the smaller buffer before freeing the old one, so
// an OOM leaves the old (larger) storage in place, never an empty list behind a logical
// limit that still admits writes.
pub fn resizeArrayList(comptime T: type, list: *std.ArrayList(T), allocator: std.mem.Allocator, capacity: usize) !void {
    return resizeList(list, allocator, capacity);
}

/// `resizeArrayList` for any unmanaged list type (cache-line-aligned staging included).
pub fn resizeList(list: anytype, allocator: std.mem.Allocator, capacity: usize) !void {
    if (shouldShrinkCapacity(list.capacity, capacity)) {
        var replacement: @TypeOf(list.*) = .empty;
        try replacement.ensureTotalCapacity(allocator, capacity);
        list.deinit(allocator);
        list.* = replacement;
        return;
    }
    try list.ensureTotalCapacity(allocator, capacity);
    list.clearRetainingCapacity();
}

/// `resizeList` to exactly `len` items, writing none: for a buffer nothing reads past a
/// written length. On error the list keeps its storage and length.
pub fn resizeUnwritten(list: anytype, allocator: std.mem.Allocator, len: usize) !void {
    const old_len = list.items.len;
    // An empty list clears without the debug fill of its old items.
    list.items.len = 0;
    errdefer list.items.len = old_len;
    try resizeList(list, allocator, len);
    list.items.len = len;
}

/// Two-phase resize of one list inside a multi-list failure-atomic reserve.
/// `prepare` makes room for `capacity` without touching the list's contents or freeing
/// its storage: a grow reserves in place (`ensureTotalCapacity` keeps the old buffer on
/// OOM), a shrink allocates the smaller replacement on the side. Once every list of the
/// reserve has prepared, `commit` swaps a pending replacement in (freeing the old buffer)
/// and cannot fail; `abort` (an `errdefer` after `prepare`) frees an uncommitted
/// replacement. So an OOM anywhere leaves every list at its prior storage, never below
/// the logical limit its owner still admits writes against.
pub fn ListResize(comptime T: type) type {
    return struct {
        const Self = @This();
        replacement: ?std.ArrayList(T) = null,

        pub fn prepare(self: *Self, list: *std.ArrayList(T), allocator: std.mem.Allocator, capacity: usize) !void {
            std.debug.assert(self.replacement == null);
            if (shouldShrinkCapacity(list.capacity, capacity)) {
                var replacement: std.ArrayList(T) = .empty;
                try replacement.ensureTotalCapacity(allocator, capacity);
                self.replacement = replacement;
                return;
            }
            try list.ensureTotalCapacity(allocator, capacity);
        }

        pub fn abort(self: *Self, allocator: std.mem.Allocator) void {
            if (self.replacement) |*replacement| replacement.deinit(allocator);
            self.replacement = null;
        }

        /// Infallible: swaps a prepared shrink replacement in (contents are not carried
        /// over; the owner rebuilds the list). A grow was already applied in place.
        pub fn commit(self: *Self, list: *std.ArrayList(T), allocator: std.mem.Allocator) void {
            const replacement = self.replacement orelse return;
            list.deinit(allocator);
            list.* = replacement;
            self.replacement = null;
        }

        /// Infallible: like `commit`, but the list keeps its first `min(len, new_len)`
        /// items (copied into a shrink replacement) and ends at `new_len` items; items
        /// past the old length are undefined. `new_len` is at most the prepared capacity.
        pub fn commitResized(self: *Self, list: *std.ArrayList(T), allocator: std.mem.Allocator, new_len: usize) void {
            if (self.replacement) |*replacement| {
                replacement.appendSliceAssumeCapacity(list.items[0..@min(list.items.len, new_len)]);
            }
            self.commit(list, allocator);
            std.debug.assert(list.capacity >= new_len);
            list.items.len = new_len;
        }
    };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "octileXY is exact on a small delta and saturates instead of wrapping" {
    try std.testing.expectEqual(@as(u32, 3 * diagonal_cost), octileXY(0, 0, 3, 3));

    // A delta far beyond any real grid saturates to maxInt(u32) rather than wrapping.
    const huge: i32 = std.math.maxInt(i32);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), octileXY(0, 0, huge, huge));
}

test "octileU32 equals octileXY on small coordinates and stays exact past the i32 range" {
    for ([_][4]u32{ .{ 0, 0, 3, 3 }, .{ 7, 2, 1, 9 }, .{ 15, 15, 0, 0 }, .{ 5, 5, 5, 5 } }) |c| {
        try std.testing.expectEqual(octileXY(@intCast(c[0]), @intCast(c[1]), @intCast(c[2]), @intCast(c[3])), octileU32(c[0], c[1], c[2], c[3]));
    }
    // Coordinates of cells past 2^31 on a wide validated level: no signed overflow.
    const far: u32 = std.math.maxInt(u32) - 3;
    try std.testing.expectEqual(@as(u32, diagonal_cost + 2 * cardinal_cost), octileU32(far, 1, far + 3, 0));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), octileU32(0, 0, far, far));
}

test "lessNode ties break deterministically on f, then h, then index" {
    // Equal f: lower h wins (closer to the goal by the heuristic).
    try std.testing.expect(lessNode(.{ .index = 5, .f = 10, .h = 2 }, .{ .index = 5, .f = 10, .h = 3 }));
    // Equal f and h: lower index wins, so heap order never depends on insertion order.
    try std.testing.expect(lessNode(.{ .index = 1, .f = 10, .h = 2 }, .{ .index = 2, .f = 10, .h = 2 }));
    try std.testing.expect(!lessNode(.{ .index = 2, .f = 10, .h = 2 }, .{ .index = 1, .f = 10, .h = 2 }));
    // Lower f always wins regardless of h/index.
    try std.testing.expect(lessNode(.{ .index = 9, .f = 5, .h = 100 }, .{ .index = 0, .f = 6, .h = 0 }));
}

test "resize helpers shrink-and-free below capacity and grow-reuse at or above it" {
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(std.testing.allocator);

    try resizeArrayList(u32, &list, std.testing.allocator, 8);
    const grown_capacity = list.capacity;
    try std.testing.expect(grown_capacity >= 8);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);

    // At/above the current capacity: no shrink-and-free, capacity is reused or grown.
    try resizeArrayList(u32, &list, std.testing.allocator, 8);
    try std.testing.expectEqual(grown_capacity, list.capacity);

    // Below the current capacity: shrinks-and-frees rather than just leaving the extra
    // capacity allocated, so an elastic down-resize actually releases memory.
    try resizeArrayList(u32, &list, std.testing.allocator, 2);
    try std.testing.expect(list.capacity < grown_capacity);
    try std.testing.expect(list.capacity >= 2);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}
