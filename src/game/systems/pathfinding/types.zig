// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Foundation types, sentinels, capacity/config/stats records, and pure helpers
//! shared across the pathfinding package: packed-ref helpers, the goal-keyed query
//! key, the octile cost helpers, the binary-heap primitives, and the small array
//! resize utilities. Leaf module within the pathfinding package (no other package
//! module imports it back) — depends on core/app primitives plus a few lightweight
//! game-module TYPE imports (EntityId, PathAgentClass, PathRequestKind) that
//! PendingRequest/PathQueryKey reference, never on game module behavior.

const std = @import("std");
const math = @import("../../../core/math.zig");
const simd = @import("../../../core/simd.zig");
const runtime_perf_log = @import("../../../app/runtime_perf_log.zig");
const BatchStats = @import("../../../app/thread_system.zig").BatchStats;
const AdaptiveWorkTuner = @import("../../../app/thread_system.zig").AdaptiveWorkTuner;
const EntityId = @import("../../data_system.zig").EntityId;
const PathAgentClass = @import("../../simulation.zig").PathAgentClass;
const PathRequestKind = @import("../../simulation.zig").PathRequestKind;

pub const pathfinding_range_alignment_items: usize = simd.lane_count;

pub const default_cell_size: f32 = 32.0;
pub const default_max_frame_requests: usize = 1024;
pub const default_max_pending_requests: usize = 1024;
pub const default_max_cached_results: usize = 1024;
// Threaded participant slots (workers + main thread). A FIXED property of the
// configured thread system, not a per-frame discovery: exactly this many per-cell A*
// scratch slots get O(cells) arrays, sized once during the nav build. Default 1 is
// the serial path (slot 0 only); the pipeline plumbs the real participant count.
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
// Cap on the stored path length per cached individual result. Longer paths are
// downsampled by stride so a moving agent can still derive a forward waypoint.
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
// Group-field threshold: a flow-field build is O(cells), so the shared field earns
// its build only at grid-scale crowds, not a population fraction. Threshold =
// clamp(cellCount / cells_per_group_agent, floor, budget); auto-scales with world
// size. The divisor and floor are tuning knobs (256 lands the 512x512 demo on ~1024),
// not measured constants. A non-zero min_group_field_agents pins it instead (tests); 0 derives.
pub const default_min_group_field_agents: usize = 0;
pub const default_cells_per_group_agent: usize = 256;
pub const group_field_threshold_floor: usize = 64;
// Hard ceiling on the elastically-derived per-step/memory capacity. The only fixed
// capacity number; requests beyond it follow the existing dropped_requests path.
// Caps worst-case resident memory so a safe-point resize can never OOM.
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
// Generous default nav-memory ceiling. The build-time gate fails loud well before
// real allocation pressure; tests use a tiny ceiling to exercise the gate.
pub const default_max_nav_memory_bytes: usize = 512 * 1024 * 1024;
// Bounded outward radius (in cells) for projecting a blocked goal to the nearest
// open cell on its level.
pub const default_goal_projection_radius: i32 = 16;
// Side length (in nav cells) of one abstract chunk. The chunk-portal graph is the
// structure that bounds per-query work independent of total cell count.
pub const default_nav_chunk_tiles: u16 = 16;
// Slack multiplier applied to a chunk's measured init edge count to size its fixed edge
// window, so an in-place dig that adds a few edges stays within the window instead of
// triggering the loud full-rebuild fallback.
pub const default_edge_slack: u32 = 2;
// Smallest per-chunk edge window, so a chunk that builds with zero edges at init still has
// headroom for a dig that opens a little connectivity before any fallback.
pub const chunk_edge_floor: u32 = 32;
// When an incremental nav update touches more than this many distinct levels, the
// per-affected-level relabel degenerates into a full relabel of every level. It
// increments a loud `nav_full_relabel` counter so a runaway batch is visible. The
// demo's worlds have very few levels, so a real edit stays well under this.
pub const default_nav_full_relabel_level_threshold: usize = 8;
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
// `.missing` (retryable later, NOT a false negative) rather than growing the budget.
pub const default_tier1_abstract_node_cap: usize = default_max_abstract_nodes * 4;
pub const default_tier1_stitched_cell_cap: usize = default_max_stitched_path_cells * 4;
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
// Sentinel for "no parent ref" in the abstract search's packed-ref parent column.
pub const no_ref: usize = std.math.maxInt(usize);

// Half-open-rect shrink applied to a max world coordinate before clamping to a cell, so a
// rect whose edge lands exactly on a cell boundary does not spuriously include the next
// cell. Must stay identical at every rect->cell site for remask-vs-rebuild parity.
pub const rect_edge_epsilon: f32 = 0.001;

comptime {
    // The abstract search identifies a node by a packed (level << 32) | local_node ref
    // stored in a usize, so the target must have a 64-bit usize.
    if (@bitSizeOf(usize) < 64) @compileError("pathfinding abstract node refs require a 64-bit usize");
}

// Packs a per-level abstract node identity. local is a node index within the level's
// own NavLevelGraph.portals run, so packing keeps cross-level search keys distinct
// without a global node numbering. A packed ref's top 16 bits are always 0 (level is a
// u16), so no real packed ref can ever equal no_ref/no_parent (maxInt, all 64 bits set) —
// packRef never aliases the sentinel. Sentinel contract is one-directional instead:
// refLevel/refLocal must only decode a real packed ref, never no_ref/no_parent directly,
// since `no_ref >> 32` would panic refLevel's @intCast to u16 (0xFFFFFFFF does not fit).
// Callers guard the sentinel first.
pub fn packRef(level: u16, local: u32) usize {
    return (@as(usize, level) << 32) | local;
}

comptime {
    if (packRef(std.math.maxInt(u16), std.math.maxInt(u32)) == no_ref) {
        @compileError("packRef must never alias the no_ref sentinel");
    }
}

pub fn refLevel(ref: usize) u16 {
    return @intCast(ref >> 32);
}

pub fn refLocal(ref: usize) u32 {
    return @truncate(ref);
}

pub const NavGridError = error{NavWorldTooLarge};

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

// One static-obstacle edit for incremental nav rebuild: a world tile flip on
// `level` at tile `(x, y)`. Carries only compact coordinates (no world handle), so
// the caller maps a single-cell `world_tile_changed` event into this before feeding
// `applyNavUpdates`. Multi-cell `world_obstacle_changed` events map to one
// `ChangedSpan` via `markNavTileRectDirty` instead (not an O(tiles) expand into
// this form). The world reference is passed alongside the edit batch so the
// affected level's blocked mask is re-derived from authoritative state.
pub const NavCellEdit = struct {
    level: u16,
    x: u16,
    y: u16,
};

// Diagnostics for one incremental `applyNavUpdates` batch. Recorded by the caller
// into runtime perf metrics. A batch that finds no real obstacle change does no
// work and leaves every counter zero.
pub const NavUpdateStats = struct {
    // Distinct abstract chunks touched by the dirty cells (membership-counted, not
    // double-counted) across affected levels.
    dirty_chunks: usize = 0,
    // 1 when this batch recomputed affected-level masks/components and the abstract
    // graph (an incremental rebuild that did NOT touch the whole world); else 0.
    incremental_rebuilds: usize = 0,
    // 1 when the affected-level count exceeded the configured full-relabel
    // threshold and every level was relabeled (a loud bounded fallback); else 0.
    full_relabel: usize = 0,
    // 1 when this batch bumped `nav_version` (invalidating goal-keyed caches); else 0.
    version_bumps: usize = 0,
    // Distinct abstract chunks patched this batch (dirty chunks plus their
    // border-adjacent neighbors), summed across affected levels. The dirty-bounded
    // work proxy: independent of total level size.
    chunks_patched: usize = 0,
    // 1 when an affected chunk's transition/intra edges overflowed its fixed
    // per-chunk edge window, forcing a loud full abstract-graph rebuild with more
    // slack (a genuine topology blow-up); else 0.
    edge_cap_fallback: usize = 0,

    pub fn recordTo(self: NavUpdateStats, perf: runtime_perf_log.Context) void {
        perf.recordMetric(.nav_dirty_chunks, metric(self.dirty_chunks));
        perf.recordMetric(.nav_incremental_rebuilds, metric(self.incremental_rebuilds));
        perf.recordMetric(.nav_full_relabel, metric(self.full_relabel));
        perf.recordMetric(.nav_version_bumps, metric(self.version_bumps));
        perf.recordMetric(.nav_chunks_patched, metric(self.chunks_patched));
        perf.recordMetric(.nav_edge_cap_fallback, metric(self.edge_cap_fallback));
    }
};

fn metric(value: usize) u64 {
    return @intCast(value);
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

// One edit's changed nav-cell rectangle on a level; scopes path-cache eviction to it.
pub const ChangedSpan = struct {
    level: u16,
    span: NavSpan,
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

// Tile index containing a world coordinate, clamped to [0, count-1]. Negatives map
// to 0; the float floor guards against the inf/NaN illegal-behavior trap.
pub fn tileIndexClamped(value: f32, tile_size: f32, count: u16) u16 {
    if (count == 0) return 0; // empty grid: no valid index, and guards clamp(.,0,-1)
    if (!(value > 0)) return 0;
    const idx = math.floorToI32(value / tile_size);
    const max_index: i32 = @as(i32, @intCast(count)) - 1;
    return @intCast(std.math.clamp(idx, 0, max_index));
}

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
    // by the pipeline; each gets an O(cells) A* scratch slot sized during the build.
    // NOT recomputed by deriveCapacity — a genuine caller-supplied value.
    worker_participant_count: usize = default_worker_participant_count,
    // Budget-bounded A* sizing.
    max_explored_nodes: usize = default_max_explored_nodes,
    max_stored_path_cells: usize = default_max_stored_path_cells,
    // Abstract chunk-portal tier sizing. nav_chunk_tiles sets the abstract chunk side
    // length. max_abstract_nodes/max_stitched_path_cells bound the ESCALATED (tier-1)
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
    // Incremental nav update: when an `applyNavUpdates` batch touches more than this
    // many levels, it relabels every level (a loud, counted fallback) rather than
    // only the affected ones.
    nav_full_relabel_level_threshold: usize = default_nav_full_relabel_level_threshold,
    // Build-time nav memory ceiling. Exceeding it fails the rebuild loudly.
    max_nav_memory_bytes: usize = default_max_nav_memory_bytes,
    // Managed shared-goal flow fields.
    max_group_fields: usize = default_max_group_fields,
    group_field_rebuild_min_steps: u32 = default_group_field_rebuild_min_steps,
    group_field_build_budget: usize = default_group_field_build_budget,
    group_field_max_cells: usize = default_group_field_max_cells,
    // Pins the group-field threshold when non-zero; 0 derives it from grid size (see
    // groupFieldThreshold). Production pins this too: a derived threshold scales with
    // grid size and goes dead when the map is large relative to the mover count.
    min_group_field_agents: usize = default_min_group_field_agents,
    // Elastic capacity ceiling (the only fixed capacity number). Live capacity
    // tracks the agent count up to this, then requests follow dropped_requests.
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
// field count) is left untouched. Lives here (not system.zig) because the nav
// memory gate must derive the same ELASTIC CEILING caps the elastic resize can
// later grow to — one derivation, no drift.
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

// The fixed-step pathfinding update's phase timer: the one shared StageTimer
// (see runtime_perf_log.zig), used here via its `begin`/`lap` interface.
pub const PhaseTimer = runtime_perf_log.StageTimer;

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
    // A tier-1 attempt that still exhausted its (fixed) budget: dropped from pending
    // WITHOUT negative-caching, so the next query falls through to `.missing` (retryable
    // later) rather than a false definitive `.unavailable`. See compactPendingAfterSolve.
    escalated_dropped: usize = 0,
    // Start-side solve failures dropped without negative-caching (see
    // PathSolveResult.start_invalid).
    start_invalid_dropped: usize = 0,
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

// A distinct group goal and how many agents declared it this step; the count
// gates flow-field building.
pub const GroupRequestTally = struct {
    key: PathQueryKey,
    count: usize,
};

pub const PreparedRequest = struct {
    entity: EntityId,
    kind: PathRequestKind,
    key: PathQueryKey,
    start_level: u16,
    start: GridCell,
};

pub const PendingRequest = struct {
    entity: EntityId,
    key: PathQueryKey,
    // Level the representative start cell lives on. The goal level is carried by
    // key.goal_level; a differing start/goal level routes cross-level.
    start_level: u16,
    // Representative start cell for the single A* solve run for this goal key.
    start: GridCell,
    // Projected open goal cell index (the original goal may be blocked).
    // `no_parent` means projection found no open cell near the goal: a
    // definitive unavailable.
    goal_index: usize,
    // Two-tier retry ladder: 0 is the first (cheap, fixed-budget) attempt; a
    // budget_exhausted at tier 0 promotes to tier 1 (a larger but still FIXED
    // abstract-node/stitched-cell ceiling — never derived from world/graph size) and
    // rotates to the back of pending once. A budget_exhausted AT tier 1 drops the
    // request WITHOUT negative-caching (not a definitive negative, just "doesn't fit
    // either fixed budget") — worst case exactly two solve attempts per request, never
    // the old unbounded retry storm, and never a false `.unavailable` for a goal that
    // may genuinely be reachable. Reset implicitly: a solved or dropped entry leaves
    // pending entirely.
    tier: u8 = 0,
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

pub const PathResult = struct {
    key: PathQueryKey,
    // Plain-path cells (start-to-goal order) for a same-component local solve,
    // stored in the cache slot's path buffer and indexed on path_level. u32 (not usize):
    // cell counts are bounded by max_stored_path_cells, and this struct is stored in
    // every cache slot (up to max_agent_budget of them), so the narrower field matters.
    path_len: u32,
    // Level the plain path cells index into (equals key.goal_level for a local solve).
    path_level: u16 = 0,
    // Number of stitched (level,cell) cells stored in the slot's stitched buffer.
    // Zero for a plain same-component local solve (path_len cells suffice); set for
    // an abstract chunk/cross-level corridor, whose full obstacle-aware path is
    // stitched from per-segment local A* and walked per-agent on its current level.
    stitched_len: u32 = 0,
};

// Copies a plain (same-component, single-level) path into `dst`, stride-downsampling
// when `src` is longer than `dst` so the stored cells still span start->goal and keep
// forward direction within the budget. Returns the cell count written. Head-truncating
// instead would dead-end the agent at the stride boundary (no successor cell -> stall
// until the cache TTL re-solves); downsampling keeps it progressing across the whole
// span. Downsampled cells are NOT guaranteed grid-adjacent, so this is only valid for
// the plain path the query treats as approximate — the abstract stitched corridor is
// stored whole. Shared by the worker solve buffer (recordPath) and the result cache
// (writePath) so both follow one contract.
pub fn downsamplePathInto(dst: []u32, src: []const u32) usize {
    if (src.len <= dst.len) {
        @memcpy(dst[0..src.len], src);
        return src.len;
    }
    if (dst.len <= 1) {
        // A single-cell (or empty) budget can only keep the start; also guards the
        // dst.len - 1 divisor below.
        if (dst.len == 1) dst[0] = src[0];
        return dst.len;
    }
    for (0..dst.len) |i| {
        const src_index = (i * (src.len - 1)) / (dst.len - 1);
        dst[i] = src[src_index];
    }
    return dst.len;
}

pub const PathSolveResult = union(enum) {
    // Successful solve carries the solved path through pending_index lookup.
    available: PathQueryKey,
    unavailable: PathQueryKey,
    deferred: PathQueryKey,
    // Budget spill: request stays pending; counted as budget-exhausted.
    budget_exhausted: PathQueryKey,
    // Start-side failure (blocked/off-grid representative start, unseedable start
    // component): a property of the representative agent, not of the goal. Dropped
    // from pending WITHOUT negative-caching — the goal-keyed `unavailable` set is
    // shared by every agent, so caching this would poison the goal for all of them.
    // The next status query falls through to `.missing` (retryable).
    start_invalid: PathQueryKey,
};

pub const OpenNode = struct {
    index: usize,
    f: u32,
    h: u32,
};

// An abstract-graph node: a portal cell on a specific level. Portals sit on the
// open border between two adjacent chunks. Abstract A* searches over these nodes
// plus inter-level link edges, never over raw cells.
pub const PortalNode = struct {
    level: u16,
    cell_index: u32,
    // Chunk this portal belongs to (chunk_y * chunks_x + chunk_x within a level).
    chunk: u32,
};

// One directed intra-level abstract edge: `target` is a local node index on the
// same level as the owning node, reached at `cost`. Cross-level transitions live
// in NavGraph.link_edges, not here.
pub const AbstractEdge = struct {
    target: u32,
    cost: u32,
};
// Comparator for binarySearch over a level's sorted compact label keys.
pub fn orderU32(key: u32, item: u32) std.math.Order {
    return std.math.order(key, item);
}
// Octile distance between two cell indices, in the same cardinal/diagonal cost
// units used by the local A*, so abstract and refined costs are comparable.
// Shared octile cost core: diagonal steps plus straight steps, weighted by the step costs.
// u64 so a pathological delta cannot overflow mid-formula; both callers saturate to u32.
fn octileCost(dx: u64, dy: u64) u64 {
    const diagonal = @min(dx, dy);
    const straight = @max(dx, dy) - diagonal;
    return diagonal * diagonal_cost + straight * cardinal_cost;
}

pub fn octileCells(width: usize, a: u32, b: u32) u32 {
    const ax: i64 = @intCast(a % width);
    const ay: i64 = @intCast(a / width);
    const bx: i64 = @intCast(b % width);
    const by: i64 = @intCast(b / width);
    const dx: u64 = @intCast(@abs(bx - ax));
    const dy: u64 = @intCast(@abs(by - ay));
    return @intCast(@min(octileCost(dx, dy), @as(u64, std.math.maxInt(u32))));
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
// already hold so the hot loop avoids re-deriving them via div/mod. Shares octileCost
// with octileCells so both saturate identically instead of one silently wrapping.
pub fn octileXY(from_x: i32, from_y: i32, to_x: i32, to_y: i32) u32 {
    const dx: u64 = @abs(to_x - from_x);
    const dy: u64 = @abs(to_y - from_y);
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

// FNV-1a 64-bit offset basis and prime, shared by both hash functions below so the
// constants are defined once rather than duplicated per function.
const fnv_offset_basis: u64 = 14695981039346656037;
const fnv_prime: u64 = 1099511628211;

pub fn hashPathKey(key: PathQueryKey) usize {
    var h: u64 = fnv_offset_basis;
    inline for (.{ key.nav_version, @intFromEnum(key.agent_class), @as(u32, key.goal_level), @as(u32, @bitCast(key.goal.x)), @as(u32, @bitCast(key.goal.y)) }) |part| {
        h ^= @as(u64, part);
        h *%= fnv_prime;
    }
    return @intCast(h);
}

pub fn hashUsize(value: usize) usize {
    var h: u64 = fnv_offset_basis;
    h ^= @as(u64, @intCast(value));
    h *%= fnv_prime;
    return @intCast(h);
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
pub fn resizeArrayList(comptime T: type, list: *std.ArrayList(T), allocator: std.mem.Allocator, capacity: usize) !void {
    if (shouldShrinkCapacity(list.capacity, capacity)) {
        list.clearRetainingCapacity();
        list.shrinkAndFree(allocator, 0);
    }
    try list.ensureTotalCapacity(allocator, capacity);
    list.clearRetainingCapacity();
}

// Like resizeArrayList but for a pool sized to exactly `capacity` and memset to a
// fill value (the disjoint worker path/stitched stripes). Shrinking frees memory.
pub fn resizeFilledArrayList(comptime T: type, list: *std.ArrayList(T), allocator: std.mem.Allocator, capacity: usize, fill: T) !void {
    if (shouldShrinkCapacity(list.capacity, capacity)) list.shrinkAndFree(allocator, 0);
    try list.ensureTotalCapacity(allocator, capacity);
    list.items.len = capacity;
    @memset(list.items, fill);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "octileCells and octileXY saturate identically instead of one silently wrapping" {
    // Both share octileCost's u64 core and the same maxInt(u32) saturation clamp, so a
    // pathological delta produces the same capped result from either entry point rather
    // than one wrapping to a small value.
    const width: usize = 4;
    const far_a: u32 = 0; // (0, 0)
    const far_b: u32 = 3 + 3 * width; // (3, 3) on a 4-wide grid: a small, exact delta.
    try std.testing.expectEqual(@as(u32, 3 * diagonal_cost), octileCells(width, far_a, far_b));
    try std.testing.expectEqual(@as(u32, 3 * diagonal_cost), octileXY(0, 0, 3, 3));

    // A delta far beyond any real grid saturates to maxInt(u32) rather than wrapping.
    const huge: i32 = std.math.maxInt(i32);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), octileXY(0, 0, huge, huge));
}

test "downsamplePathInto preserves start/goal and handles degenerate dst lengths" {
    // src fits: exact copy, no downsampling.
    var exact: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 3), downsamplePathInto(exact[0..3], &.{ 10, 11, 12 }));
    try std.testing.expectEqualSlices(u32, &.{ 10, 11, 12 }, exact[0..3]);

    // dst.len == 0: guarded before the (dst.len - 1) divisor; returns 0 without touching dst.
    var zero_dst: [0]u32 = .{};
    try std.testing.expectEqual(@as(usize, 0), downsamplePathInto(&zero_dst, &.{ 1, 2, 3 }));

    // dst.len == 1: keeps only the start cell (never the goal), per the single-cell-budget
    // guard, and does not evaluate the (dst.len - 1) divisor.
    var one_dst: [1]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 1), downsamplePathInto(&one_dst, &.{ 7, 8, 9 }));
    try std.testing.expectEqual(@as(u32, 7), one_dst[0]);

    // src longer than dst: downsampled but start and goal are always preserved exactly.
    var short_dst: [3]u32 = undefined;
    const long_src = [_]u32{ 20, 21, 22, 23, 24, 25, 26 };
    try std.testing.expectEqual(@as(usize, 3), downsamplePathInto(&short_dst, &long_src));
    try std.testing.expectEqual(@as(u32, 20), short_dst[0]);
    try std.testing.expectEqual(@as(u32, 26), short_dst[2]);
}

test "tileIndexClamped handles degenerate count, negative, and non-finite input" {
    // Zero-sized grid: no valid index; also guards clamp(., 0, -1) below.
    try std.testing.expectEqual(@as(u16, 0), tileIndexClamped(100, 32, 0));
    // Non-positive value (including a would-be-negative tile) clamps to 0.
    try std.testing.expectEqual(@as(u16, 0), tileIndexClamped(-5, 32, 10));
    try std.testing.expectEqual(@as(u16, 0), tileIndexClamped(0, 32, 10));
    // NaN fails every comparison, including `> 0`, so it also clamps to 0 rather than
    // reaching the illegal-behavior floorToI32(NaN) path.
    try std.testing.expectEqual(@as(u16, 0), tileIndexClamped(std.math.nan(f32), 32, 10));
    // In-range value maps to its tile; a value past the last tile clamps to count-1.
    try std.testing.expectEqual(@as(u16, 3), tileIndexClamped(100, 32, 10));
    try std.testing.expectEqual(@as(u16, 9), tileIndexClamped(1_000_000, 32, 10));
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

    // resizeFilledArrayList additionally sets items.len to capacity and fills it.
    var filled: std.ArrayList(u8) = .empty;
    defer filled.deinit(std.testing.allocator);
    try resizeFilledArrayList(u8, &filled, std.testing.allocator, 4, 0xAB);
    try std.testing.expectEqual(@as(usize, 4), filled.items.len);
    for (filled.items) |byte| try std.testing.expectEqual(@as(u8, 0xAB), byte);
}
