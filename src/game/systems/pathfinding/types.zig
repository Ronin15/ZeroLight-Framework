// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Foundation types, sentinels, capacity/config/stats records, and pure helpers
//! shared across the pathfinding package: packed-ref helpers, the goal-keyed query
//! key, the octile cost helpers, the binary-heap primitives, and the small array
//! resize utilities. Leaf module — depends only on core/app primitives.

const std = @import("std");
const math = @import("../../../core/math.zig");
const simd = @import("../../../core/simd.zig");
const runtime_perf_log = @import("../../../app/runtime_perf_log.zig");
const sdl = @import("../../../platform/sdl.zig").c;
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
pub const default_group_field_rebuild_min_steps: u32 = 30;
pub const default_group_field_build_budget: usize = 8192;
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
pub const default_max_abstract_nodes: usize = 4096;
// Cap on the stored stitched-path cells per cached cross-chunk/cross-level result.
// An abstract corridor is refined into a single grid-adjacent (level,cell) path by
// stitching local A* segments; this bounds that path. A stitched path that exceeds
// the cap spills to a later frame (budget_exhausted) and is retried from the agent's
// advanced position, so the cap is never a silent truncation.
pub const default_max_stitched_path_cells: usize = 512;
// Steps after which a cached result is re-solved when next requested, so an agent
// picks up world changes that did not directly cross its path. 0 disables. ~5s at 60Hz.
pub const default_cache_ttl_steps: u32 = 300;
// Queue-fairness thresholds for a pending entry that keeps budget-spilling. After this
// many consecutive budget-exhausted retries it is rotated to the BACK of pending so
// late-queued work behind a chronic spiller still reaches the solver.
pub const budget_exhausted_rotate_after: u32 = 4;
// After this many it is demoted to a hard negative (negative-cached) so a request that
// never fits the per-solve budget stops consuming a solve slot every frame.
pub const budget_exhausted_drop_after: u32 = 32;

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
// without a global node numbering. Sentinel contract: refLevel/refLocal must only decode
// a real packed ref — decoding no_ref/no_parent (maxInt) would panic the refLevel @intCast,
// and packRef(0xFFFF, 0xFFFFFFFF) aliases no_ref exactly. Callers guard the sentinel first.
pub fn packRef(level: u16, local: u32) usize {
    return (@as(usize, level) << 32) | local;
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
    // Level of the grid cell the agent should step toward next. Matches start_level
    // while the path stays on one floor; at a LevelLink crossing (stitched j+1 on a
    // different level) this is the destination floor so movement can commit a transition.
    next_cell_level: u16 = 0,
    path_len: usize = 0,
};

// One static-obstacle edit for incremental nav rebuild: a world tile flip on
// `level` at tile `(x, y)`. Carries only compact coordinates (no world handle), so
// the caller maps a `world_tile_changed`/`world_obstacle_changed` event into this
// before feeding `applyNavUpdates`. The world reference is passed alongside the edit
// batch so the affected level's blocked mask is re-derived from authoritative state.
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
};

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
    max_frame_requests: usize = default_max_frame_requests,
    max_pending_requests: usize = default_max_pending_requests,
    max_cached_results: usize = default_max_cached_results,
    // Threaded participant slots (workers + 1). Set from the configured thread system
    // by the pipeline; each gets an O(cells) A* scratch slot sized during the build.
    worker_participant_count: usize = default_worker_participant_count,
    max_solved_requests_per_step: usize = default_max_solved_requests_per_step,
    max_fallback_requests_per_step: usize = default_max_fallback_requests_per_step,
    // Budget-bounded A* sizing.
    max_explored_nodes: usize = default_max_explored_nodes,
    max_stored_path_cells: usize = default_max_stored_path_cells,
    // Abstract chunk-portal tier sizing. nav_chunk_tiles sets the abstract chunk
    // side length; max_abstract_nodes bounds abstract A* work.
    nav_chunk_tiles: u16 = default_nav_chunk_tiles,
    max_abstract_nodes: usize = default_max_abstract_nodes,
    max_stitched_path_cells: usize = default_max_stitched_path_cells,
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
    // Pins the group-field threshold when non-zero; 0 derives it from grid size (see
    // groupFieldThreshold). Non-zero is for tests exercising field mechanics.
    min_group_field_agents: usize = default_min_group_field_agents,
    // Elastic capacity ceiling (the only fixed capacity number). Live capacity
    // tracks the agent count up to this, then requests follow dropped_requests.
    max_agent_budget: usize = default_max_agent_budget,
    // Steps the agent count must stay below half capacity before pools shrink.
    capacity_shrink_window: u32 = default_capacity_shrink_window,
};

pub const PathfindingConfig = struct {
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    fallback_adaptive_tuner: ?*AdaptiveWorkTuner = null,
    max_solved_requests_per_step: ?usize = null,
    max_fallback_requests_per_step: ?usize = null,
};

// Comptime-gated monotonic phase timer for the fixed-step pathfinding update.
// Zero-cost no-op when perf logging is disabled; uses the SDL monotonic clock
// (gated, perf-only) like the other fixed-step stage timers.
pub const PhaseTimer = if (runtime_perf_log.enabled) struct {
    start_ns: u64,
    pub fn begin() PhaseTimer {
        return .{ .start_ns = sdl.SDL_GetTicksNS() };
    }
    pub fn lap(self: *PhaseTimer) u64 {
        const now = sdl.SDL_GetTicksNS();
        return if (now > self.start_ns) now - self.start_ns else 0;
    }
} else struct {
    pub fn begin() PhaseTimer {
        return .{};
    }
    pub fn lap(_: *PhaseTimer) u64 {
        return 0;
    }
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
    goal_projected: usize = 0,
    group_fields_built: usize = 0,
    group_field_reuses: usize = 0,
    group_field_rebuild_throttled: usize = 0,
    group_field_samples: usize = 0,
    // Abstract-tier and cross-level routing counters.
    abstract_solves: usize = 0,
    cross_level_solves: usize = 0,
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
    // Consecutive frames this entry has budget-spilled. Drives queue-fairness aging in
    // compactPendingAfterSolve (rotate-to-back, then demote) so a chronic spiller never
    // starves the tail. Reset implicitly: a solved entry leaves pending entirely.
    retries: u32 = 0,
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

pub fn hashPathKey(key: PathQueryKey) usize {
    var h: u64 = 14695981039346656037;
    inline for (.{ key.nav_version, @intFromEnum(key.agent_class), @as(u32, key.goal_level), @as(u32, @bitCast(key.goal.x)), @as(u32, @bitCast(key.goal.y)) }) |part| {
        h ^= @as(u64, part);
        h *%= 1099511628211;
    }
    return @intCast(h);
}

pub fn hashUsize(value: usize) usize {
    var h: u64 = 14695981039346656037;
    h ^= @as(u64, @intCast(value));
    h *%= 1099511628211;
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

// Grows (amortized) or shrinks-and-frees a per-step scratch list's backing capacity
// to `capacity`, leaving it empty. Used for lists the update repopulates each step,
// so no contents need to survive the resize. Shrinking frees memory back.
pub fn resizeArrayList(comptime T: type, list: *std.ArrayList(T), allocator: std.mem.Allocator, capacity: usize) !void {
    if (capacity < list.capacity) {
        list.clearRetainingCapacity();
        list.shrinkAndFree(allocator, 0);
    }
    try list.ensureTotalCapacity(allocator, capacity);
    list.clearRetainingCapacity();
}

// Like resizeArrayList but for a pool sized to exactly `capacity` and memset to a
// fill value (the disjoint worker path/stitched stripes). Shrinking frees memory.
pub fn resizeFilledArrayList(comptime T: type, list: *std.ArrayList(T), allocator: std.mem.Allocator, capacity: usize, fill: T) !void {
    if (capacity < list.capacity) list.shrinkAndFree(allocator, 0);
    try list.ensureTotalCapacity(allocator, capacity);
    list.items.len = capacity;
    @memset(list.items, fill);
}
