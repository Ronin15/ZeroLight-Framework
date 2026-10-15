// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Per-request solvers: the budget-bounded local A*, the abstract chunk-record
//! corridor search, the corridor stitcher, and the worker job entry point. These
//! free functions borrow *PathfindingSystem plus per-worker scratch and read the
//! NavGraph's grids and chunk records; they stay free functions to keep that wiring flat.

const std = @import("std");
const simd = @import("../../../core/simd.zig");
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const PathfindingSystem = @import("system.zig").PathfindingSystem;
const NavGrid = @import("nav_grid.zig").NavGrid;
const allowed_moves = @import("nav_grid.zig").allowed_moves;
const NavGraph = @import("nav_graph.zig").NavGraph;
const NavPortal = @import("nav_graph.zig").NavPortal;
const ChunkGeometry = @import("../../world_terrain.zig").ChunkGeometry;
const LinkBounds = @import("nav_graph.zig").LinkBounds;
const LinkPairs = @import("nav_graph.zig").LinkPairs;
const PairChains = @import("nav_graph.zig").PairChains;
const LinkBox = @import("nav_graph.zig").LinkBox;
const LevelCrossings = @import("nav_graph.zig").LevelCrossings;
const CrossingScratch = @import("scratch.zig").CrossingScratch;
const crossingBoxRef = @import("scratch.zig").crossingBoxRef;
const crossingBoxBudget = @import("types.zig").crossingBoxBudget;
const CrossingRates = @import("nav_graph.zig").CrossingRates;
const max_link_box_coord = @import("nav_graph.zig").max_link_box_coord;
const AbstractScratch = @import("scratch.zig").AbstractScratch;
const AbstractSlot = @import("scratch.zig").AbstractSlot;
const CorridorScratch = @import("scratch.zig").CorridorScratch;
const SearchScratch = @import("scratch.zig").SearchScratch;
const chunk_list_map = @import("../chunk_list_map.zig");
const chunkKey = @import("../chunk_list_map.zig").chunkKey;
const types = @import("types.zig");
const GridCell = @import("types.zig").GridCell;
const PathSolveResult = @import("types.zig").PathSolveResult;
const CellCursor = @import("types.zig").CellCursor;
const registry_shard_count = @import("types.zig").registry_shard_count;
const registryShard = @import("types.zig").registryShard;
const PendingRequest = @import("types.zig").PendingRequest;
const PathQueryKey = @import("types.zig").PathQueryKey;
const StitchedCell = @import("types.zig").StitchedCell;
const OpenNode = @import("types.zig").OpenNode;
const no_parent = @import("types.zig").no_parent;
const no_slot = @import("types.zig").no_slot;
const unreachable_cost = @import("types.zig").unreachable_cost;
const long_link_pairs = @import("types.zig").long_link_pairs;
const long_lane_cap = @import("types.zig").long_lane_cap;
const diagonal_cost = @import("types.zig").diagonal_cost;
const cardinal_cost = @import("types.zig").cardinal_cost;
const packRef = @import("types.zig").packRef;
const refLevel = @import("types.zig").refLevel;
const refLocal = @import("types.zig").refLocal;
const octileXY = @import("types.zig").octileXY;
const octileU32 = @import("types.zig").octileU32;
const siftUp = @import("types.zig").siftUp;
const popHeap = @import("types.zig").popHeap;
const neighbor_dirs = @import("types.zig").neighbor_dirs;

pub const SolveJobContext = struct {
    system: *PathfindingSystem,
    /// Dispatched range count from the pre-select that sized this batch; dual-asserted
    /// against `range.index` at job entry (mirror affect.zig / collision.zig).
    range_count: usize,
};

// Fallback workers share the system for read-only graph/pending access but use
// worker-indexed scratch. Every output (result, solved path, path stripe) sits at the
// request's solve ordinal, so a range writes only its own `[start, end)` window; a
// tier-1 solve also writes the tier-1 pool entry of its escalated admission index, which
// no other ordinal of the step holds.
pub fn solveJob(context: *anyopaque, range: ParallelRange, worker_id: WorkerId) void {
    const job: *SolveJobContext = @ptrCast(@alignCast(context));
    const system = job.system;
    // Dual worker asserts: range.index vs dispatched range count AND range.end vs
    // the fallback-index buffer this job walks and the ordinal windows it writes.
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= system.solve_indices.items.len);
    std.debug.assert(range.end <= system.solve_results.items.len);
    std.debug.assert(range.end <= system.solved_paths.items.len);
    std.debug.assert(range.end <= system.solve_tier1_slot.items.len);
    // scratch_slots is never resized during the parallel region (only in applyDerivedCapacity,
    // which runs in beginUpdate before parallelForWithOptions), so this pointer stays valid.
    // Guards the reserve-before-dispatch invariant: applyDerivedCapacity sized scratch_slots to
    // the participant count the caller asserted against before dispatching this batch.
    std.debug.assert(worker_id.index < system.scratch_slots.items.len);
    const scratch = &system.scratch_slots.items[worker_id.index];
    for (range.start..range.end) |ordinal| {
        const pending_index = system.solve_indices.items[ordinal];
        system.solve_results.items[ordinal] = solveOne(system, pending_index, scratch, ordinal);
    }
}

// Outcome of a budget-bounded local A* over one level's grid.
const LocalSolve = enum { found, budget_exhausted, none };

// Outcome of a corridor stitch. `capped`: the stitched-cell or segment-count cap stopped it,
// and the cells appended are the first cells of the stitch an uncapped run returns (segments
// run in corridor order and an append never changes earlier cells). `spilled`: a segment's
// local search spent its node budget, or the cap was zero; a re-solve from the stitched end
// would pick the same next portal and spill again, so no prefix is kept.
const StitchOutcome = enum { found, capped, spilled, none };

// Solves one request. Short same-component hops use the budget-bounded local A*
// directly and store a plain path (no stitched corridor). Long-range or cross-level
// queries route through the abstract chunk-portal/link graph to pick a corridor, then
// stitch the full obstacle-aware (level,cell) path from per-segment local A* runs;
// the query walks it per-agent on its current level. Per-solve work is bounded by the
// abstract node budget, plus at most max_stitch_segments per-segment local searches
// (see default_max_stitch_segments) — not just one, since a corridor can cross many
// portals — each capped at the per-segment local budget, independent of total cells.
/// Solves logical pending entry `pending_index`, writing its solved path at `ordinal`
/// (its solve ordinal: result slot, solved-path slot, and path stripe). The live goal and
/// reach come before any search: a goal no open start reaches is `.unavailable` with no
/// search, and once reach holds no search ends without a path.
pub fn solveOne(system: *PathfindingSystem, pending_index: usize, scratch: *SearchScratch, ordinal: usize) PathSolveResult {
    const graph = &system.graph;
    const request = system.pending.at(pending_index);
    if (!graph.valid()) return .{ .unavailable = request.key };
    // Every local search of this solve clamps to the committed node budget, as the
    // abstract and stitched searches clamp theirs: a plain path then fits its stripe, and
    // every participant spills at the same count even when a failed re-reserve left
    // scratch tables at different limits.
    scratch.explored_budget = @min(system.capacity.max_explored_nodes, scratch.explored_limit);

    // Start-side failures are start_invalid, a property of the representative agent (e.g.
    // one momentarily overlapping a body), never of the goal.
    const start_grid = graph.grid(request.start_level) orelse return .{ .start_invalid = request.key };
    const goal_grid = graph.grid(request.key.goal_level) orelse return .{ .unavailable = request.key };
    const start_index = start_grid.indexForCell(request.start) orelse return .{ .start_invalid = request.key };

    // The goal against the grid now (a nav change since acceptance may have moved it), and
    // reach from this start: an accepted request whose goal became unreachable answers
    // without a search. A blocked start is start_invalid whatever the goal.
    const goal_index = system.liveGoal(request.key, goal_grid).cell orelse
        return if (start_grid.isBlockedIndex(start_index)) .{ .start_invalid = request.key } else .{ .unavailable = request.key };
    switch (system.reaches(request.key.agent_class, request.start_level, start_index, request.key.goal_level, goal_index)) {
        .start_blocked => return .{ .start_invalid = request.key },
        .unreachable_goal => return .{ .unavailable = request.key },
        .reaches => {},
    }

    const same_level = request.start_level == request.key.goal_level;
    if (same_level) {
        if (start_index == goal_index) {
            recordPath(system, ordinal, &.{@intCast(goal_index)}, request.start_level, @intCast(goal_index));
            return .{ .available = request.key };
        }
        // Same component: a short hop the local A* can usually finish.
        if (start_grid.connected(start_index, goal_index)) {
            switch (localAStar(start_grid, scratch, start_index, goal_index)) {
                .found => {
                    recordPath(system, ordinal, scratch.path_scratch.items, request.start_level, @intCast(goal_index));
                    return .{ .available = request.key };
                },
                // Budget spill on a short same-component hop is a transient: keep
                // it pending so a later frame retries rather than mislabeling it.
                .budget_exhausted => return .{ .budget_exhausted = request.key },
                .none => return reachContractBreak(request.key),
            }
        }
        // Same level but different component: NavGrid components are CHUNK-LOCAL (a flood
        // never crosses a chunk border), so this is the COMMON case of a start/goal in
        // different chunks, not just the rare same-level teleport link — either way, only
        // the abstract chunk-portal/link graph can connect them. Fall to abstract.
    }

    // Two-tier attempt caps: tier 0 (the common case) runs in the participant's corridor
    // scratch at the cheap tier-0 caps; tier 1 (already promoted by a prior
    // budget_exhausted) runs in the tier-1 pool entry of its escalated admission index at
    // the fixed tier-1 caps — never derived from or scaled to world/graph size. See
    // PendingRequest.tier and compactPendingAfterSolve's budget_exhausted handling. The
    // tier-0 caps are independently settable, so they clamp to the tier-1 ceiling: tier 0
    // is the cheaper attempt. Each search further clamps its cap to the reserved logical
    // limits of the scratch it runs in.
    const corridor = if (request.tier == 0) &scratch.corridor else tier1Corridor(system, ordinal);
    const abstract_node_cap = if (request.tier == 0) @min(system.capacity.tier0_abstract_node_cap, system.capacity.max_abstract_nodes) else system.capacity.max_abstract_nodes;
    const stitched_cell_cap = if (request.tier == 0) @min(system.capacity.tier0_stitched_cell_cap, system.capacity.max_stitched_path_cells) else system.capacity.max_stitched_path_cells;
    return solveAbstract(system, scratch, corridor, ordinal, request, start_grid, goal_grid, start_index, goal_index, abstract_node_cap, stitched_cell_cap, system.capacity.max_stitch_segments);
}

// A search that ended without a path after reach held: reach and the searches disagree.
// Panics under runtime safety; a release build drops the request as start_invalid.
fn reachContractBreak(key: PathQueryKey) PathSolveResult {
    if (std.debug.runtime_safety) @panic("pathfinding: a search after reach found no path");
    return .{ .start_invalid = key };
}

// The tier-1 pool entry `prepareSolvePhase` assigned to the escalated solve at `ordinal`.
fn tier1Corridor(system: *PathfindingSystem, ordinal: usize) *CorridorScratch {
    const tier1_slot = system.solve_tier1_slot.items[ordinal];
    std.debug.assert(tier1_slot < system.tier1_scratch.items.len);
    return &system.tier1_scratch.items[tier1_slot].corridor;
}

// Abstract A* over portal nodes + link edges to choose a corridor across
// chunks/levels, then stitches the FULL obstacle-aware path: per-segment local A*
// between consecutive corridor portals (and start->first portal, last portal->goal)
// concatenated into one grid-adjacent (level,cell) path, with a discrete jump only
// across an inter-level link. The query walks that path per-agent on its current
// level, so every heading is to a traversable neighbor. Saturating the abstract
// scratch or a segment's node budget spills to a later frame (budget_exhausted); reach
// held before the search, so no search ends without a path. A tier-1 stitch stopped by
// its cell or segment cap publishes its prefix as `.partial` when the prefix leaves its start
// cell, so each hop advances along the path even where it folds back near its start; a prefix
// that never leaves the start, and a tier-0 cap, promote as a spill does. A saturated tier-1
// search publishes `.partial` toward its least-estimate expanded node (`LeastExpanded`), cut
// to end on the last stitched cell whose estimate lies below the start's; with no expanded
// node or stitched cell below the start's estimate it drops as a spill does.
fn solveAbstract(
    system: *PathfindingSystem,
    scratch: *SearchScratch,
    corridor_scratch: *CorridorScratch,
    ordinal: usize,
    request: PendingRequest,
    start_grid: *const NavGrid,
    goal_grid: *const NavGrid,
    start_index: usize,
    goal_index: usize,
    abstract_node_cap: usize,
    stitched_cell_cap: usize,
    segment_cap: usize,
) PathSolveResult {
    const graph = &system.graph;
    const abstract = &corridor_scratch.abstract;
    // The search's estimate, written by the search and read again to cut a stitch toward its
    // least node. Only a tier-1 search tracks that node; tier 0 promotes on saturation.
    var heuristic: CrossLevelHeuristic = undefined;
    var least_expanded: LeastExpanded = undefined;
    const least: ?*LeastExpanded = if (request.tier == 0) null else &least_expanded;
    const searched = abstractCorridor(graph, abstract, start_grid, goal_grid, request.start_level, request.key.goal_level, start_index, goal_index, abstract_node_cap, &heuristic, least);
    scratch.crossing_boxes_settled += abstract.crossing.settles;
    scratch.crossing_budget_frozen += @intFromBool(abstract.crossing.frozen);
    const to_goal = searched == .found;
    const corridor = switch (searched) {
        .found, .toward => |c| c,
        // Abstract scratch saturated: a reachable goal past the attempt's cap, retried on
        // the two-tier ladder.
        .saturated => return .{ .budget_exhausted = request.key },
        .none => return reachContractBreak(request.key),
        // Start-side seeding failure: dropped, never cached.
        .unseedable => return .{ .start_invalid = request.key },
    };

    // Stitch the full obstacle-aware path across every corridor segment. A node-budget
    // spill is a transient: retry next frame. A cap at tier 0 promotes; at tier 1 its prefix
    // is the partial result. Consecutive corridor nodes connect, so a stitch ending without a
    // path breaks reach.
    const capped = switch (stitchCorridor(system, scratch, corridor_scratch, request, goal_grid, start_index, goal_index, stitched_cell_cap, segment_cap, to_goal)) {
        .found => false,
        .capped => true,
        .spilled => return .{ .budget_exhausted = request.key },
        .none => return reachContractBreak(request.key),
    };

    const stitched_list = &corridor_scratch.stitched;
    if (stitched_list.items.len == 0) return reachContractBreak(request.key);
    if (!to_goal) {
        // Ends the stitch on its last cell below the start's estimate: the least node itself
        // when uncapped; when capped, a prefix cell, and none past the start drops.
        if (!cutBelowStart(stitched_list, &heuristic, least_expanded.start_h, graph.geometry.width)) return .{ .budget_exhausted = request.key };
    } else if (capped) {
        // A prefix ending on its start would answer its own next request unchanged.
        const end = stitched_list.items[stitched_list.items.len - 1];
        if (request.tier == 0 or (end.level == request.start_level and end.cell == start_index)) return .{ .budget_exhausted = request.key };
    }
    const partial = capped or !to_goal;
    const stitched = stitched_list.items;
    recordStitched(system, ordinal, stitched, request.start_level, @intCast(goal_index));
    const solved = &system.solved_paths.items[ordinal];
    solved.via_abstract = true;
    solved.cross_level = corridor.crosses_level;
    return if (partial) .{ .partial = request.key } else .{ .available = request.key };
}

// Stitches the chosen abstract corridor (corridor_scratch.abstract.corridor, ordered portal
// (level, cell) refs root->goal) into corridor_scratch.stitched as one (level,cell) path;
// local A* segments run in the participant's `scratch`.
// A NON-link transition (corridor_link[i] == false) is walked with local A* between
// consecutive portal cells; a LINK transition (corridor_link[i] == true) is a single
// discrete jump (no intermediate cells), whether it crosses Z or is a same-level
// teleport. The final span (last portal -> goal) is a same-level local A*. Returns
// `capped` on a stitched-buffer overflow or a segment-count spill (segment_cap, see
// default_max_stitch_segments — bounds total local-search work independent of how many
// portals the chosen corridor crosses), with the cells stitched so far kept, and `spilled`
// on a segment node-budget spill. `to_goal` false (a corridor toward a closed node short of
// the goal) ends the stitch on the corridor's last node, with no final span.
// SIMD verdict: scalar. Segments run in corridor order, each a local A* from the previous
// segment's end.
fn stitchCorridor(
    system: *PathfindingSystem,
    scratch: *SearchScratch,
    corridor_scratch: *CorridorScratch,
    request: PendingRequest,
    goal_grid: *const NavGrid,
    start_index: usize,
    goal_index: usize,
    cap_requested: usize,
    segment_cap: usize,
    to_goal: bool,
) StitchOutcome {
    const graph = &system.graph;
    const stitched = &corridor_scratch.stitched;
    const abstract = &corridor_scratch.abstract;
    stitched.clearRetainingCapacity();
    const cap = @min(cap_requested, corridor_scratch.stitched_limit);
    if (cap == 0) return .spilled;
    // Seed the path with the start cell on the start level.
    stitched.appendAssumeCapacity(.{ .level = request.start_level, .cell = @intCast(start_index) });

    var prev_level = request.start_level;
    var prev_cell: usize = start_index;
    var segments_used: usize = 0;
    for (abstract.corridor.items, 0..) |ref, i| {
        const portal = StitchedCell{ .level = refLevel(ref), .cell = refLocal(ref) };
        // The first corridor portal (i == 0) is on the start level and reached from
        // the start cell by a walkable span; later portals follow corridor_link.
        const is_link = i != 0 and abstract.corridor_link.items[i];
        if (is_link) {
            // Discrete link jump: append the far endpoint cell with no intermediate
            // cells (the agent crosses the link rather than walking).
            if (stitched.items.len >= cap) return .capped;
            stitched.appendAssumeCapacity(.{ .level = portal.level, .cell = portal.cell });
        } else {
            // The corridor names only built levels; a miss breaks the reach contract (the
            // caller's reachContractBreak).
            const grid = graph.grid(prev_level) orelse return .none;
            // appendSegment no-ops (no localAStar call) when prev_cell already equals the
            // portal cell, so only a genuine local search counts against segment_cap.
            if (prev_cell != portal.cell and !countSegment(scratch, &segments_used, segment_cap)) return .capped;
            switch (appendSegment(scratch, stitched, grid, prev_level, prev_cell, portal.cell, cap)) {
                .found => {},
                else => |r| return r,
            }
        }
        prev_level = portal.level;
        prev_cell = portal.cell;
    }
    if (!to_goal) return .found;
    // Final span: last corridor cell -> goal cell, a walkable same-level segment. A found
    // corridor ends at a goal-level portal (abstractCorridor's goal test).
    std.debug.assert(prev_level == request.key.goal_level);
    if (prev_cell != goal_index and !countSegment(scratch, &segments_used, segment_cap)) return .capped;
    switch (appendSegment(scratch, stitched, goal_grid, prev_level, prev_cell, @intCast(goal_index), cap)) {
        .found => {},
        else => |r| return r,
    }
    return .found;
}

// Counts one segment search against `segment_cap`, recording the participant's per-step
// high-water; false when the cap is spent.
fn countSegment(scratch: *SearchScratch, segments_used: *usize, segment_cap: usize) bool {
    if (segments_used.* >= segment_cap) return false;
    segments_used.* += 1;
    scratch.max_stitch_segments_used = @max(scratch.max_stitch_segments_used, segments_used.*);
    return true;
}

// Runs local A* from `from` to `to` on `grid` and appends the resulting cells
// (skipping the first, already present as the previous segment's tail) to the
// stitched buffer, tagged with `level`. Returns `spilled` on a local node-budget spill,
// `capped` when appending would overflow the stitched cap (the cells that fit kept).
fn appendSegment(scratch: *SearchScratch, stitched: *std.ArrayList(StitchedCell), grid: *const NavGrid, level: u16, from: usize, to: usize, cap: usize) StitchOutcome {
    if (from == to) return .found;
    switch (localAStar(grid, scratch, from, to)) {
        .found => {},
        .budget_exhausted => return .spilled,
        .none => return .none,
    }
    // path_scratch is start->goal for this segment; its first cell equals `from`,
    // already the tail of the stitched buffer, so skip it.
    const seg = scratch.path_scratch.items;
    if (seg.len <= 1) return .found;
    for (seg[1..]) |cell| {
        if (stitched.items.len >= cap) return .capped;
        stitched.appendAssumeCapacity(.{ .level = level, .cell = cell });
    }
    return .found;
}

/// Whether an abstract node ends a search toward its goal: a portal on the goal level, in the
/// goal cell's chunk, sharing that cell's chunk-local component label. A goal labeled 0
/// (blocked) has no goal portal.
pub fn isGoalPortal(level: u16, chunk: usize, label: u8, goal_level: u16, goal_chunk: usize, goal_label: u8) bool {
    return level == goal_level and goal_label != 0 and chunk == goal_chunk and label == goal_label;
}

const AbstractCorridor = struct {
    // Whether the chosen corridor crosses at least one inter-level link.
    crosses_level: bool,
};

const AbstractResult = union(enum) {
    found: AbstractCorridor,
    // Saturated with a least-estimate fallback whose node lies below the start's estimate:
    // the corridor ends on that node, short of the goal.
    toward: AbstractCorridor,
    // The bounded abstract scratch saturated (open/slot table full); the corridor
    // may exist but could not be searched this frame.
    saturated,
    // No corridor reaches the goal level/cell from the start.
    none,
    // The representative start carries no component label (a blocked/degenerate
    // cell): a start-side condition, not an unreachable goal.
    unseedable,
};

// A tier-1 search's least-estimate expanded node, ties to the lower ref, so the choice depends
// only on the set of expanded nodes, a pure function of graph, goal, start, and budget; and the
// estimate at the start cell.
const LeastExpanded = struct {
    start_h: u32,
    slot: u32,
    ref: usize,
    h: u32,

    fn begin(self: *LeastExpanded, start_h: u32) void {
        self.start_h = start_h;
        self.slot = no_slot;
        self.ref = 0;
        self.h = unreachable_cost;
    }

    // O(1) per expanded node.
    fn consider(self: *LeastExpanded, slot: u32, ref: usize, h: u32) void {
        if (h > self.h or (h == self.h and self.slot != no_slot and ref >= self.ref)) return;
        self.slot = slot;
        self.ref = ref;
        self.h = h;
    }

    fn belowStart(self: *const LeastExpanded) bool {
        return self.slot != no_slot and self.h < self.start_h;
    }
};

// Cuts a stitch toward a least node back to its last cell whose `heuristic` estimate lies below
// `start_h`; false when no cell past the start does. Uncapped, the last cell is the least node,
// so this costs one estimate; a capped stitch scans back from its end, at most its cells.
// SIMD verdict: scalar. Back-to-front early exit, usually on the first cell.
fn cutBelowStart(stitched: *std.ArrayList(StitchedCell), heuristic: *CrossLevelHeuristic, start_h: u32, width: usize) bool {
    var len = stitched.items.len;
    while (len > 1) : (len -= 1) {
        const cell = stitched.items[len - 1];
        // Sides of a validated level fit u32.
        const x: u32 = @intCast(cell.cell % width);
        const y: u32 = @intCast(cell.cell / width);
        if (heuristic.estimate(heuristic.levelTerms(cell.level), cell.level, x, y) < start_h) {
            stitched.shrinkRetainingCapacity(len);
            return true;
        }
    }
    return false;
}

// A node an abstract expansion relaxes: its packed ref, cell coordinates, and its chunk
// portal when the relaxing expansion holds it (a same-chunk peer, or a seed).
const AbstractNode = struct {
    ref: usize,
    x: u32,
    y: u32,
    portal: ?NavPortal,
};

// Writes a freshly claimed node's coordinates and known portal into its slot, once.
fn cacheAbstractNode(slot: *AbstractSlot, node: AbstractNode) void {
    slot.x = node.x;
    slot.y = node.y;
    const portal = node.portal orelse return;
    slot.portal_label = portal.label;
    slot.portal_flags = portal.flags;
    slot.flags.portal_known = true;
}

// Relaxes one abstract neighbor `node` reached from `parent_slot` at `cost`, recording
// whether the relaxing edge was a cross-level link. The estimate is computed only when the
// relax improves g and pushes, from `terms` (null: from the node's own level). Returns false
// on saturation (the node budget or the open heap is full).
fn relaxAbstractNode(
    abstract: *AbstractScratch,
    parent_slot: u32,
    parent_g: u32,
    node: AbstractNode,
    cost: u32,
    via_link: bool,
    heuristic: *CrossLevelHeuristic,
    terms: ?CrossLevelHeuristic.LevelTerms,
) bool {
    const claim = abstract.slotFor(node.ref) orelse return false;
    const slot = &abstract.slots[claim.slot];
    if (claim.fresh) cacheAbstractNode(slot, node);
    if (slot.stamp & 1 != 0) return true;
    const candidate = parent_g +| cost;
    if (candidate >= slot.g) return true;
    slot.g = candidate;
    slot.parent = parent_slot;
    slot.flags.via_link = via_link;
    if (abstract.open.items.len >= abstract.open_limit) return false;
    const level = refLevel(node.ref);
    const h = heuristic.estimate(terms orelse heuristic.levelTerms(level), level, node.x, node.y);
    abstract.open.appendAssumeCapacity(.{ .index = node.ref, .f = candidate +| h, .h = h });
    siftUp(abstract.open.items, abstract.open.items.len - 1);
    return true;
}

// Consistent lower bound on the abstract cost from a node to the goal, built once per query
// from the graph's link bounds: the least of a short and a long term. With D the planar
// octile to the goal and K the fewest level-crossing short links that close the node's level
// gap, a path using only short links costs at least D + K * short_excess and K * short_cost.
// Off the goal level it also costs at least the node's crossing distance (`CrossingSearch`),
// and the short term is the larger of the two. A path whose first long link lies in pair p
// costs at least the short-link bound from the node to p's entrance box, plus p's cost, plus
// p's chain bound: the least, over pairs r its exit box chains to, of the chain cost plus the
// short-link bound from r's exit box to the goal. Box bounds charge a level gap at per-level
// crossing rates, so an entrance on a far level cuts nothing nearby. The long term is at least
// `long_floor` (the cheapest link plus the nearest exit box's bound) and `pair_floor` (the
// least pair offset), so a push scans entrance boxes only past both; the offsets are built on
// the first push past `long_floor`. On the goal level with no long link the estimate is
// octile. Short terms saturate; long lanes clamp at `long_lane_cap`.
//
// The crossing distance is the exact distance to the goal in a relaxed graph: free octile
// movement within each level, levels joined only through each level's departing crossing
// boxes (`LevelCrossings`) at the box's least cost. It holds a cheaper copy of every short
// edge, so it is a consistent lower bound on every short-only path. A Dijkstra from the goal
// over the boxes computes it lazily: the first estimate on a level settles boxes in distance
// order until that level's distances are final, and gathers its box distances once. Past the
// crossing scratch's budget the search freezes at the distance F of the settle it stopped in:
// an unsettled box then counts F, which adds edges to the relaxed graph, so the bound stays
// consistent and is a pure function of graph, goal, and budget, whatever the evaluation order.
const CrossLevelHeuristic = struct {
    goal_x: u32,
    goal_y: u32,
    goal_level: u16,
    short_span: u32,
    short_cost: u32,
    short_excess: u32,
    rates: CrossingRates,
    pairs: *const LinkPairs,
    chains: *const PairChains,
    // Per pair, the box bound from its exit box to the goal.
    exit_terms: [long_link_pairs]i32,
    long_floor: u32,
    // Per pair, its cost plus its chain bound; valid once `pair_ready`.
    offsets: [long_link_pairs]i32,
    pair_floor: u32,
    pair_ready: bool,
    crossing: CrossingSearch,

    // The level-dependent part of the short term, shared by every node on one level.
    const LevelTerms = struct {
        add: u32,
        floor: u32,
    };

    // One exit-box scan, once per query. `crossing` null (or a graph with no crossings)
    // leaves out the crossing distance; `crossing_budget` caps the boxes its search touches.
    fn init(graph: *const NavGraph, goal_level: u16, goal_x: u32, goal_y: u32, crossing: ?*CrossingScratch, crossing_budget: usize) CrossLevelHeuristic {
        const bounds = &graph.link_bounds;
        // Links exist only on world-backed graphs, whose u16 sides keep box lanes in i32.
        if (bounds.pairs.count != 0 or bounds.short_span != 0) {
            std.debug.assert(graph.world_backed and graph.geometry.width <= max_link_box_coord + 1 and graph.geometry.height <= max_link_box_coord + 1);
        }
        var heuristic = fromBounds(bounds, goal_level, goal_x, goal_y);
        // Every level-crossing short link folds into the crossings, and only those set the span.
        if (bounds.short_span != 0) {
            if (crossing) |scratch| {
                std.debug.assert(graph.level_crossings.items.len == graph.levels.items.len);
                heuristic.crossing = CrossingSearch.init(graph.level_crossings.items, scratch, crossing_budget, goal_level, goal_x, goal_y, graph.geometry);
            }
        }
        return heuristic;
    }

    fn fromBounds(bounds: *const LinkBounds, goal_level: u16, goal_x: u32, goal_y: u32) CrossLevelHeuristic {
        const rates = bounds.crossingRates();
        var heuristic = CrossLevelHeuristic{
            .goal_x = goal_x,
            .goal_y = goal_y,
            .goal_level = goal_level,
            .short_span = bounds.short_span,
            .short_cost = bounds.short_cost,
            .short_excess = bounds.short_excess,
            .rates = rates,
            .pairs = &bounds.pairs,
            .chains = &bounds.chains,
            .exit_terms = @splat(0),
            .long_floor = unreachable_cost,
            .offsets = @splat(0),
            .pair_floor = unreachable_cost,
            .pair_ready = false,
            .crossing = .{},
        };
        // With no long link every short term passes the unreachable floor.
        if (bounds.pairs.count == 0) return heuristic;
        heuristic.exit_terms = bounds.pairs.exits.laneTerms(goal_x, goal_y, goal_level, rates);
        var nearest = heuristic.exit_terms[0];
        for (heuristic.exit_terms[1..]) |term| nearest = @min(nearest, term);
        // At most every pair offset: each pair's cost is at least min(long_cost, cap) and its
        // chain bound at least the nearest exit term.
        heuristic.long_floor = @min(bounds.long_cost +| @as(u32, @intCast(nearest)), @as(u32, long_lane_cap));
        return heuristic;
    }

    // Per pair offset = min(cost + min(chain bound, cap), cap), the chain bound being the least
    // over pairs r of chains.to[r] + exit_terms[r]: one `Int4` step per r and lane group.
    fn preparePairs(self: *CrossLevelHeuristic) void {
        const pairs = self.pairs;
        const lane_groups = long_link_pairs / simd.lane_count;
        var chain_bound: [lane_groups]simd.Int4 = @splat(simd.splatInt4(std.math.maxInt(i32)));
        for (0..pairs.count) |exit_pair| {
            const exit_term = simd.splatInt4(self.exit_terms[exit_pair]);
            for (&chain_bound, 0..) |*bound, group| {
                // At most 2 * long_lane_cap, inside an i32.
                bound.* = simd.minInt4(bound.*, simd.addInt4(simd.loadInt4(self.chains.to[exit_pair][group * simd.lane_count ..]), exit_term));
            }
        }
        const cap = simd.splatInt4(long_lane_cap);
        var least = cap;
        for (chain_bound, 0..) |bound, group| {
            const lanes = group * simd.lane_count;
            const offset = simd.minInt4(simd.addInt4(simd.loadInt4(pairs.cost[lanes..]), simd.minInt4(bound, cap)), cap);
            simd.storeInt4(self.offsets[lanes..][0..simd.lane_count], offset);
            least = simd.minInt4(least, offset);
        }
        var floor = least[0];
        inline for (1..simd.lane_count) |lane| floor = @min(floor, least[lane]);
        // A min of offsets in [0, long_lane_cap].
        self.pair_floor = @intCast(floor);
        self.pair_ready = true;
    }

    fn levelTerms(self: *const CrossLevelHeuristic, level: u16) LevelTerms {
        const gap: u32 = @max(level, self.goal_level) - @min(level, self.goal_level);
        if (gap == 0) return .{ .add = 0, .floor = 0 };
        // No short link crosses levels: only a long link reaches the goal level.
        if (self.short_span == 0) return .{ .add = unreachable_cost, .floor = unreachable_cost };
        const crossings = (gap + self.short_span - 1) / self.short_span;
        return .{ .add = crossings *| self.short_excess, .floor = crossings *| self.short_cost };
    }

    // `terms` are `level`'s. Mutable only to build the pair offsets and run the crossing
    // search on first use, both pure functions of the graph, goal, and budget.
    fn estimate(self: *CrossLevelHeuristic, terms: LevelTerms, level: u16, x: u32, y: u32) u32 {
        const planar = octileU32(x, y, self.goal_x, self.goal_y);
        var short = @max(planar +| terms.add, terms.floor);
        if (level != self.goal_level and self.crossing.enabled()) short = @max(short, self.crossing.bound(level, x, y, self.rates));
        if (short <= self.long_floor) return short;
        if (!self.pair_ready) self.preparePairs();
        if (short <= self.pair_floor) return short;
        return @min(short, self.pairs.entrances.offsetLowerBound(&self.offsets, self.pairs.count, x, y, level, self.rates));
    }
};

// The heuristic's crossing distance (see `CrossLevelHeuristic`): a lazy Dijkstra from the goal
// over the level crossings' boxes, run in a participant's `CrossingScratch`. The goal seeds it
// as a settled point box on the goal level at distance 0. Settling a box on level l relaxes,
// for every source level in l's arrival window, each departing box whose exit range covers l,
// at its cost plus the planar octile from its exit box to the settled box's entrance
// (`LinkBoxes.coveringTerms`, one `Int4` step per four slots). Ties pop by box ref, so the
// settle order is a pure function of the crossings and the goal. Allocation-free.
// SIMD verdict: scalar frontier (each pop relaxes from the distances earlier pops set); the
// covering terms and the per-estimate offset scan are four-lane.
const CrossingSearch = struct {
    crossings: []const LevelCrossings = &.{},
    scratch: ?*CrossingScratch = null,
    budget: usize = 0,
    goal_level: u16 = 0,
    goal_x: u32 = 0,
    goal_y: u32 = 0,
    // The octile across a level: no point of a level is farther from another.
    diameter: u32 = 0,
    seeded: bool = false,
    // Set once the heap drains: every reachable box is settled.
    drained: bool = false,
    // Set when the budget stops the search; unsettled boxes then count `frozen_at`.
    frozen_at: ?u32 = null,
    // Gathered levels' box distances, direct-mapped by level, so a search whose frontier spans
    // up to `gathered_levels` levels gathers each once.
    gathered: [gathered_levels]GatheredLevel = @splat(.{}),

    const gathered_levels: usize = 16;

    // A level's box distances, slots past its departing count copying slot 0; valid once
    // `level` is set, and final for the query (a gathered level is resolved).
    const GatheredLevel = struct {
        level: u32 = std.math.maxInt(u32),
        lanes: [long_link_pairs]i32 = @splat(long_lane_cap),
    };

    fn init(crossings: []const LevelCrossings, scratch: *CrossingScratch, budget: usize, goal_level: u16, goal_x: u32, goal_y: u32, geometry: ChunkGeometry) CrossingSearch {
        // Sides of a world-backed graph fit u16, so the diameter stays below 2^21.
        const width = geometry.width;
        const height = geometry.height;
        return .{
            .crossings = crossings,
            .scratch = scratch,
            .budget = budget,
            .goal_level = goal_level,
            .goal_x = goal_x,
            .goal_y = goal_y,
            .diameter = octileU32(0, 0, width -| 1, height -| 1),
        };
    }

    fn enabled(self: *const CrossingSearch) bool {
        return self.scratch != null;
    }

    // The crossing distance from (x, y) on `level`, not the goal level, clamped to
    // `long_lane_cap`; `long_lane_cap` when the level has no departing box.
    fn bound(self: *CrossingSearch, level: u16, x: u32, y: u32, rates: CrossingRates) u32 {
        std.debug.assert(level < self.crossings.len and level != self.goal_level);
        const departing = &self.crossings[level].departing;
        if (departing.count == 0) return long_lane_cap;
        const gathered = &self.gathered[level % gathered_levels];
        if (gathered.level != level) self.gather(level, gathered);
        // Entrance boxes lie on `level`, so the box term charges no level gap. A lane sum
        // reaches 2 * long_lane_cap; clamping only lowers a lower bound.
        return @min(departing.entrances.offsetLowerBound(&gathered.lanes, departing.count, x, y, level, rates), @as(u32, long_lane_cap));
    }

    // Settles until `level`'s box distances are final, then gathers them into `gathered`.
    fn gather(self: *CrossingSearch, level: u16, gathered: *GatheredLevel) void {
        const scratch = self.scratch.?;
        if (!self.seeded) self.seed(scratch);
        while (!self.resolved(scratch, level)) self.settleNext(scratch);
        const departing = &self.crossings[level].departing;
        // An unsettled box lies past every point's nearest settled one on a resolved level, so
        // it counts the cap, or the frozen distance once the budget stopped the search.
        const unsettled: u32 = self.frozen_at orelse long_lane_cap;
        for (0..departing.count) |slot| {
            const box = scratch.findBox(crossingBoxRef(level, slot));
            const distance = if (box != null and box.?.stamp & 1 != 0) box.?.d else unsettled;
            // In [0, long_lane_cap]: relaxes skip candidates past the cap.
            gathered.lanes[slot] = @intCast(distance);
        }
        for (departing.count..long_link_pairs) |pad| gathered.lanes[pad] = gathered.lanes[0];
        gathered.level = level;
    }

    // Whether no further settle can lower a distance on `level`: the search froze or drained,
    // every box of the level settled, or the least open distance passes the level's least
    // settled distance plus its diameter, so no unsettled box is the nearest to any point.
    fn resolved(self: *const CrossingSearch, scratch: *CrossingScratch, level: u16) bool {
        if (self.frozen_at != null or self.drained) return true;
        const settled = scratch.findLevel(level) orelse return false;
        if (settled.settled == self.crossings[level].departing.count) return true;
        // Never empty here: a drained heap sets `drained`.
        return scratch.open.items[0].f >= settled.d_min +| self.diameter;
    }

    fn seed(self: *CrossingSearch, scratch: *CrossingScratch) void {
        scratch.begin(self.budget);
        self.seeded = true;
        // In range: goal coordinates of a world-backed level fit u16.
        self.relaxFrom(scratch, LinkBox.point(@intCast(self.goal_x), @intCast(self.goal_y), self.goal_level), self.goal_level, 0);
        if (self.frozen_at == null and scratch.open.items.len == 0) self.drained = true;
    }

    // Pops the nearest open box, skipping superseded entries, and settles it.
    fn settleNext(self: *CrossingSearch, scratch: *CrossingScratch) void {
        while (scratch.open.items.len != 0) {
            const next = popHeap(&scratch.open);
            // In range: heap indices are box refs below 2^20.
            const ref: u32 = @intCast(next.index);
            const box = scratch.boxFor(ref).?;
            if (box.stamp & 1 != 0 or next.f > box.d) continue;
            box.stamp |= 1;
            scratch.settles += 1;
            const level: u16 = @intCast(ref >> 4);
            const entry = scratch.levelFor(level);
            entry.settled += 1;
            entry.d_min = @min(entry.d_min, box.d);
            self.relaxFrom(scratch, self.crossings[level].departing.entrances.boxAt(ref & 0xf), level, box.d);
            break;
        }
        if (self.frozen_at == null and scratch.open.items.len == 0) self.drained = true;
    }

    // Relaxes every departing box landing on `level` toward the settled box `entrance` there
    // at `distance`. A claim or push past the budget freezes the search at `distance`: every
    // unsettled box lies at least that far.
    fn relaxFrom(self: *CrossingSearch, scratch: *CrossingScratch, entrance: LinkBox, level: u16, distance: u32) void {
        const arrivals = &self.crossings[level];
        if (arrivals.arrival_lo > arrivals.arrival_hi) return;
        for (arrivals.arrival_lo..@as(usize, arrivals.arrival_hi) + 1) |source_index| {
            // In range: a window spans folded source levels.
            const source: u16 = @intCast(source_index);
            const departing = &self.crossings[source].departing;
            if (departing.count == 0) continue;
            const terms = departing.exits.coveringTerms(entrance, level);
            for (0..departing.count) |slot| {
                if (terms[slot] >= long_lane_cap) continue;
                // Below 2^32: three lanes of at most long_lane_cap.
                const candidate = @as(u64, distance) + @as(u64, @intCast(departing.cost[slot])) + @as(u64, @intCast(terms[slot]));
                if (candidate >= long_lane_cap) continue;
                const box = scratch.boxFor(crossingBoxRef(source, slot)) orelse return self.freeze(scratch, distance);
                if (box.stamp & 1 != 0 or candidate >= box.d) continue;
                if (scratch.open.items.len >= scratch.open_limit) return self.freeze(scratch, distance);
                box.d = @intCast(candidate);
                scratch.open.appendAssumeCapacity(.{ .index = crossingBoxRef(source, slot), .f = box.d, .h = 0 });
                siftUp(scratch.open.items, scratch.open.items.len - 1);
            }
        }
    }

    fn freeze(self: *CrossingSearch, scratch: *CrossingScratch, distance: u32) void {
        self.frozen_at = distance;
        scratch.frozen = true;
    }
};

// Runs abstract A* over chunk records. A node is a portal cell, packed as (level << 32) | cell.
// Expanding a node relaxes the other portals of its chunk with its label (octile cost), the
// mirror cell across each border it sits on (one cardinal step), and every link leaving it
// whose target cell is open. The estimate is `CrossLevelHeuristic`; the search ends at the
// first goal-level portal sharing the goal's chunk-local component whose entry carries its
// full octile to the goal. On success it writes the ordered corridor of refs (root
// start-level portal -> goal-level portal) into abstract.corridor for the stitcher to
// refine, and reports whether the corridor crosses a level. Per-query work is bounded by
// the abstract node budget; seeding scans only the start chunk's record. A node's
// coordinates are cached at claim, and its portal when the claiming expansion held it, so a
// pop derives its chunk by shifts and looks a portal up only for a mirror or link target.
// `heuristic` receives the search's estimate. With `least`, each expanded node is offered to
// it, and a saturated search returns `.toward` with the chain to its least node when that
// node's estimate lies below the start cell's.
// SIMD verdict: scalar frontier (each pop relaxes from the costs earlier pops set, over a
// data-dependent portal list); the long-link heuristic terms are four-lane (`preparePairs`).
fn abstractCorridor(
    graph: *const NavGraph,
    abstract: *AbstractScratch,
    start_grid: *const NavGrid,
    goal_grid: *const NavGrid,
    start_level: u16,
    goal_level: u16,
    start_index: usize,
    goal_index: usize,
    node_cap: usize,
    heuristic: *CrossLevelHeuristic,
    least: ?*LeastExpanded,
) AbstractResult {
    abstract.reset();
    // Per-query attempt-scoped cap (tier-0 stays small; tier-1 uses the fixed ceiling),
    // clamped to the table's reserved limit.
    abstract.node_budget = @min(node_cap, abstract.node_limit);
    const slots = abstract.slots;

    // Chunk geometry once per query: a cell's chunk and chunk-local index are shifts and
    // masks of its coordinates.
    const geometry = graph.chunkGeometry();
    const width = geometry.width;
    const shift: u5 = geometry.shift;
    const mask: u32 = @as(u32, geometry.chunk_tiles) - 1;
    // Coordinates and indices stay unsigned: a validated level's cell index can pass 2^31.
    const goal: u32 = @intCast(goal_index);
    const goal_y = goal / width;
    const goal_x = goal - goal_y * width;
    heuristic.* = CrossLevelHeuristic.init(graph, goal_level, goal_x, goal_y, &abstract.crossing, crossingBoxBudget(abstract.node_budget));

    // Seed the open set with the start chunk's portals sharing the start cell's label,
    // costed by octile distance from the start.
    const start_label = start_grid.labelAt(start_index);
    if (start_label == 0) return .unseedable;
    const start_cell: u32 = @intCast(start_index);
    const start_y = start_cell / width;
    const start_x = start_cell - start_y * width;
    const start_portals = graph.chunkPortals(start_level, geometry.chunkOf(start_x, start_y));
    const start_terms = heuristic.levelTerms(start_level);
    if (least) |tracked| tracked.begin(heuristic.estimate(start_terms, start_level, start_x, start_y));
    var seeded: usize = 0;
    for ([_][]const NavPortal{ start_portals.border, start_portals.extra }) |portals| {
        for (portals) |portal| {
            if (portal.label != start_label) continue;
            const px = (start_x & ~mask) + (portal.local & mask);
            const py = (start_y & ~mask) + (@as(u32, portal.local) >> shift);
            const ref = packRef(start_level, py * width + px);
            const claim = abstract.slotFor(ref) orelse return .saturated;
            const seed = &slots[claim.slot];
            if (claim.fresh) cacheAbstractNode(seed, .{ .ref = ref, .x = px, .y = py, .portal = portal });
            const g = octileU32(start_x, start_y, px, py);
            seed.g = g;
            seed.parent = no_slot;
            seed.flags.via_link = false;
            if (abstract.open.items.len >= abstract.open_limit) return .saturated;
            const h = heuristic.estimate(start_terms, start_level, px, py);
            abstract.open.appendAssumeCapacity(.{ .index = ref, .f = g +| h, .h = h });
            siftUp(abstract.open.items, abstract.open.items.len - 1);
            seeded += 1;
        }
    }
    // A labeled component with zero portals is structurally sealed off from every
    // other chunk, which reach answers before any search.
    if (seeded == 0) return .none;

    const goal_label = goal_grid.labelAt(goal_index);
    const goal_chunk = geometry.chunkOf(goal_x, goal_y);

    while (abstract.open.items.len != 0) {
        const current = popHeap(&abstract.open);
        const current_ref = current.index;
        const current_slot = (abstract.slotFor(current_ref) orelse return saturatedResult(abstract, least, start_level)).slot;
        const current_node = &slots[current_slot];
        if (current_node.stamp & 1 != 0) continue;
        // Lazy deletion: skip a superseded duplicate left in the heap by an earlier
        // g-improvement (f-h recovers its g; strict-greater never drops the best entry).
        if (current.f -% current.h > current_node.g) continue;

        const level = refLevel(current_ref);
        const cell = refLocal(current_ref);
        const x = current_node.x;
        const y = current_node.y;
        const chunk = geometry.chunkOf(x, y);
        const local = geometry.localOf(x, y);
        // The record's slices: the peer scan and the link lookup read them.
        const portals = graph.chunkPortals(level, chunk);
        // Every relaxed node is a portal of its chunk's record (mirror runs are symmetric and
        // an open link endpoint is a portal); a miss is a dead end.
        const portal: NavPortal = if (current_node.flags.portal_known)
            .{ .local = local, .label = current_node.portal_label, .flags = current_node.portal_flags }
        else
            portals.find(local) orelse {
                current_node.stamp |= 1;
                continue;
            };
        // Goal reached: this portal is on the goal level and shares the goal's chunk-local
        // component, so the local refiner can finish from here.
        if (isGoalPortal(level, chunk, portal.label, goal_level, goal_chunk, goal_label)) {
            // The objective at a goal portal is g plus its octile to the goal. An entry whose
            // estimate the long floor cut below that octile goes back at the objective, still
            // open, so the first goal portal to end the search is the cheapest.
            const goal_octile = octileU32(x, y, goal_x, goal_y);
            if (current.h < goal_octile) {
                if (abstract.open.items.len >= abstract.open_limit) return saturatedResult(abstract, least, start_level);
                abstract.open.appendAssumeCapacity(.{ .index = current_ref, .f = current_node.g +| goal_octile, .h = goal_octile });
                siftUp(abstract.open.items, abstract.open.items.len - 1);
                continue;
            }
            switch (buildCorridor(abstract, current_slot, start_level)) {
                .ok => {},
                // Budget-truncated reconstruction: spill+retry, never unavailable.
                .truncated => return saturatedResult(abstract, least, start_level),
                .none => return .none,
            }
            return .{ .found = .{ .crosses_level = start_level != goal_level } };
        }

        current_node.stamp |= 1;
        if (least) |tracked| tracked.consider(current_slot, current_ref, current.h);
        const current_g = current_node.g;
        const terms = heuristic.levelTerms(level);
        const origin_x = x & ~mask;
        const origin_y = y & ~mask;
        const local_mask: u8 = @intCast(mask);
        const local_x: u8 = local & local_mask;
        const local_y: u8 = local >> @intCast(shift);
        // Same-label portals of the chunk.
        for ([_][]const NavPortal{ portals.border, portals.extra }) |peers| {
            for (peers) |peer| {
                if (peer.local == local or peer.label != portal.label) continue;
                const peer_x: u8 = peer.local & local_mask;
                const peer_y: u8 = peer.local >> @intCast(shift);
                const px = origin_x + peer_x;
                const py = origin_y + peer_y;
                // In-grid: below the level's cell count.
                const target = py * width + px;
                const cost = chunk_octile[@max(local_x, peer_x) - @min(local_x, peer_x)][@max(local_y, peer_y) - @min(local_y, peer_y)];
                const node = AbstractNode{ .ref = packRef(level, target), .x = px, .y = py, .portal = peer };
                if (!relaxAbstractNode(abstract, current_slot, current_g, node, cost, false, heuristic, terms)) return saturatedResult(abstract, least, start_level);
            }
        }
        // The mirror cell across each border this portal sits on.
        // A flag means the mirror cell exists in-grid.
        if (portal.flags.west and !relaxMirror(abstract, current_slot, current_g, level, cell - 1, x - 1, y, heuristic, terms)) return saturatedResult(abstract, least, start_level);
        if (portal.flags.east and !relaxMirror(abstract, current_slot, current_g, level, cell + 1, x + 1, y, heuristic, terms)) return saturatedResult(abstract, least, start_level);
        if (portal.flags.north and !relaxMirror(abstract, current_slot, current_g, level, cell - width, x, y - 1, heuristic, terms)) return saturatedResult(abstract, least, start_level);
        if (portal.flags.south and !relaxMirror(abstract, current_slot, current_g, level, cell + width, x, y + 1, heuristic, terms)) return saturatedResult(abstract, least, start_level);
        // Links leaving this cell whose target cell is open on a built level; only a
        // link-flagged portal has any.
        if (!portal.flags.link) continue;
        for (portals.linksAt(local)) |link| {
            const target_grid = graph.grid(link.to_level) orelse continue;
            if (target_grid.isBlockedIndex(link.to_cell)) continue;
            const target_y = link.to_cell / width;
            const target_x = link.to_cell - target_y * width;
            const node = AbstractNode{ .ref = packRef(link.to_level, link.to_cell), .x = target_x, .y = target_y, .portal = null };
            if (!relaxAbstractNode(abstract, current_slot, current_g, node, link.cost, true, heuristic, null)) return saturatedResult(abstract, least, start_level);
        }
    }
    return .none;
}

// A saturated search's result: `.toward` with the chain to `least`'s node when it lies below the
// start's estimate, else `.saturated`. O(chain), once per saturated search.
fn saturatedResult(abstract: *AbstractScratch, least: ?*LeastExpanded, start_level: u16) AbstractResult {
    const tracked = least orelse return .saturated;
    if (!tracked.belowStart()) return .saturated;
    switch (buildCorridor(abstract, tracked.slot, start_level)) {
        .ok => {},
        .truncated, .none => return .saturated,
    }
    // Rooted on the start level, the chain crosses a level when any node leaves it.
    const crosses_level = for (abstract.corridor.items) |ref| {
        if (refLevel(ref) != start_level) break true;
    } else false;
    return .{ .toward = .{ .crosses_level = crosses_level } };
}

// Octile cost of a step of (dx, dy) cells within one chunk, by table.
const chunk_octile: [16][16]u32 = blk: {
    @setEvalBranchQuota(16 * 16 * 16);
    var table: [16][16]u32 = undefined;
    for (0..16) |dx| {
        for (0..16) |dy| table[dx][dy] = octileXY(0, 0, dx, dy);
    }
    break :blk table;
};

comptime {
    // Chunk-local coordinates are below the largest chunk edge.
    std.debug.assert(@import("../../world_system.zig").max_chunk_size_tiles <= chunk_octile.len);
}

// Relaxes the mirror cell `target` at (mx, my) across a border at one cardinal step.
fn relaxMirror(abstract: *AbstractScratch, parent_slot: u32, parent_g: u32, level: u16, target: u32, mx: u32, my: u32, heuristic: *CrossLevelHeuristic, terms: CrossLevelHeuristic.LevelTerms) bool {
    const node = AbstractNode{ .ref = packRef(level, target), .x = mx, .y = my, .portal = null };
    return relaxAbstractNode(abstract, parent_slot, parent_g, node, cardinal_cost, false, heuristic, terms);
}

// Outcome of reconstructing the abstract corridor from the parent chain.
const CorridorBuild = enum {
    // Full chain root->goal rebuilt and rooted on the start level.
    ok,
    // The parent chain filled corridor_limit (max_abstract_nodes) before reaching the
    // seed root: a budget truncation, not an unreachable goal. Spill and retry.
    truncated,
    // Empty, or the chain rooted off the start level: a genuine missing corridor.
    none,
};

// Walks the parent slot chain from the reached goal-level portal's slot back to its seeded
// start-level root, writing the ordered packed-ref sequence (root -> goal portal) into
// abstract.corridor and each step's recorded via_link flag into corridor_link. Returns .ok
// when the corridor's root is a start-level portal.
fn buildCorridor(abstract: *AbstractScratch, goal_slot: u32, start_level: u16) CorridorBuild {
    abstract.corridor.clearRetainingCapacity();
    abstract.corridor_link.clearRetainingCapacity();
    var slot = goal_slot;
    var truncated = false;
    while (true) {
        if (abstract.corridor.items.len >= abstract.corridor_limit) {
            truncated = true;
            break;
        }
        const node = abstract.slots[slot];
        abstract.corridor.appendAssumeCapacity(node.node);
        abstract.corridor_link.appendAssumeCapacity(node.flags.via_link);
        if (node.parent == no_slot) break;
        slot = node.parent;
    }
    std.mem.reverse(usize, abstract.corridor.items);
    std.mem.reverse(bool, abstract.corridor_link.items);
    if (abstract.corridor.items.len == 0) return .none;
    // The corridor limit cut the chain before the root: a budget spill, not an unreachable goal.
    if (truncated) return .truncated;
    // corridor_link[0] is false (no predecessor); corridor_link[i] is whether corridor[i]
    // was reached over a cross-level link.
    abstract.corridor_link.items[0] = false;
    return if (refLevel(abstract.corridor.items[0]) == start_level) .ok else .none;
}

// Budget-bounded heap A* over one level's grid. Fills scratch.path_scratch with
// the reconstructed start-to-goal cells on success. The node budget keeps explored
// count bounded; exhausting it spills the request to a later frame.
// SIMD verdict: scalar. A heap frontier: each pop's neighbours relax from the costs the
// previous pops set, and one table lookup already gives all eight moves.
fn localAStar(grid: *const NavGrid, scratch: *SearchScratch, start_index: usize, goal_index: usize) LocalSolve {
    if (start_index == goal_index) {
        scratch.path_scratch.clearRetainingCapacity();
        scratch.path_scratch.appendAssumeCapacity(@intCast(goal_index));
        return .found;
    }
    scratch.reset();
    const slots = scratch.slots;
    const width: i32 = @intCast(grid.geometry.width);
    const goal_x: i32 = @intCast(goal_index % grid.geometry.width);
    const goal_y: i32 = @intCast(goal_index / grid.geometry.width);
    const start_slot = scratch.slotFor(start_index) orelse return .budget_exhausted;
    // The root keeps parent no_slot.
    slots[start_slot].g = 0;
    const h0 = octileXY(@intCast(start_index % grid.geometry.width), @intCast(start_index / grid.geometry.width), goal_x, goal_y);
    scratch.open.appendAssumeCapacity(.{ .index = start_index, .f = h0, .h = h0 });

    while (scratch.open.items.len != 0) {
        const current = popHeap(&scratch.open);
        const current_slot = scratch.slotFor(current.index) orelse return .budget_exhausted;
        const current_node = &slots[current_slot];
        if (current_node.stamp & 1 != 0) continue;
        // Lazy deletion: a superseded duplicate (a better g was recorded for this cell
        // after this entry was queued) is stale — discard it rather than re-expand. f-h
        // recovers this entry's g; it can only under-estimate under a saturating f, so the
        // strict-greater test never drops the live best entry.
        if (current.f -% current.h > current_node.g) continue;
        current_node.stamp |= 1;
        if (current.index == goal_index) {
            reconstructLocalPath(scratch, current_slot);
            return .found;
        }
        // Derive current (x,y) once and step neighbors by the direction offset; the
        // neighbor coordinates feed the heuristic directly, so the inner loop has no
        // per-neighbor div/mod. One 3x3 neighborhood read and one table lookup give every
        // allowed move, bounds and the corner rule included.
        const current_y_index = current.index / grid.geometry.width;
        const current_x_index = current.index - current_y_index * grid.geometry.width;
        const moves = allowed_moves[grid.neighborhood(current_x_index, current_y_index)];
        const current_x: i32 = @intCast(current_x_index);
        const current_y: i32 = @intCast(current_y_index);
        const current_g = current_node.g;
        for (neighbor_dirs, 0..) |dir, dir_index| {
            if (moves & (@as(u8, 1) << @intCast(dir_index)) == 0) continue;
            const nx = current_x + dir.x;
            const ny = current_y + dir.y;
            const next_index: usize = @intCast(ny * width + nx);
            const next_slot = scratch.slotFor(next_index) orelse return .budget_exhausted;
            const next_node = &slots[next_slot];
            if (next_node.stamp & 1 != 0) continue;
            const step_cost = if (dir.diagonal) diagonal_cost else cardinal_cost;
            const candidate_g = current_g +| step_cost;
            if (candidate_g >= next_node.g) continue;
            next_node.g = candidate_g;
            next_node.parent = current_slot;
            const h = octileXY(nx, ny, goal_x, goal_y);
            if (scratch.open.items.len >= scratch.open_limit) return .budget_exhausted;
            scratch.open.appendAssumeCapacity(.{ .index = next_index, .f = candidate_g +| h, .h = h });
            siftUp(scratch.open.items, scratch.open.items.len - 1);
        }
    }
    return .none;
}

// Walks the parent slot chain from `goal_slot` to the root into path_scratch, start first.
fn reconstructLocalPath(scratch: *SearchScratch, goal_slot: u32) void {
    scratch.path_scratch.clearRetainingCapacity();
    var slot = goal_slot;
    while (true) {
        // path_scratch holds max(1, explored_limit) cells, and the chain holds at most
        // one cell per claimed node, so this buffer cannot fill during reconstruction.
        std.debug.assert(scratch.path_scratch.items.len < scratch.path_scratch.capacity);
        const node = scratch.slots[slot];
        scratch.path_scratch.appendAssumeCapacity(node.cell);
        if (node.parent == no_slot) break;
        slot = node.parent;
    }
    // path_scratch is goal-to-start; reverse into start-to-goal.
    std.mem.reverse(u32, scratch.path_scratch.items);
}

// Writes a plain path whole into this request's output stripe at its solve ordinal,
// with its registry runs. The local solve bounds a path at one cell per explored node,
// which the stripe holds.
fn recordPath(system: *PathfindingSystem, ordinal: usize, path: []const u32, path_level: u16, goal_cell: u32) void {
    const stripe_words = system.stripe_words;
    const offset = ordinal * stripe_words;
    std.debug.assert(path.len <= stripe_words);
    @memcpy(system.worker_path_pool.items[offset .. offset + path.len], path);
    var solved = PathfindingSystem.SolvedPath{
        .offset = offset,
        .len = path.len,
        .path_level = path_level,
        .end = .{ .level = path_level, .cell = path[path.len - 1] },
        .goal_cell = goal_cell,
    };
    const starts = system.worker_run_starts.items[offset..][0..stripe_words];
    solved.run_count = splitRuns(system.graph.chunkGeometry(), path, null, path_level, starts, &solved.shard_counts);
    system.solved_paths.items[ordinal] = solved;
}

// Writes the full stitched (level,cell) corridor path, or a partial's prefix, whole into this
// request's output stripe as its cells, then its levels, with its registry runs; `path_level`
// is the start level and `goal_cell` the live goal it was solved toward. stitchCorridor's cap
// (at most max_stitched_path_cells) bounds it at the stripe, asserted so a drift fails loud
// instead of truncating the corridor.
fn recordStitched(system: *PathfindingSystem, ordinal: usize, stitched: []const StitchedCell, start_level: u16, goal_cell: u32) void {
    const stripe_words = system.stripe_words;
    const offset = ordinal * stripe_words;
    std.debug.assert(types.stitchedWords(stitched.len) <= stripe_words);
    const stripe = system.worker_path_pool.items[offset .. offset + stripe_words];
    types.writeStitched(stripe, stitched);
    const view = types.stitchedView(stripe, stitched.len);
    var solved = PathfindingSystem.SolvedPath{
        .offset = offset,
        .len = 0,
        .stitched_len = stitched.len,
        .path_level = start_level,
        .end = stitched[stitched.len - 1],
        .goal_cell = goal_cell,
    };
    const starts = system.worker_run_starts.items[offset..][0..stripe_words];
    solved.run_count = splitRuns(system.graph.chunkGeometry(), view.cells, view.levels, start_level, starts, &solved.shard_counts);
    system.solved_paths.items[ordinal] = solved;
}

/// Splits a stored path into registry runs, maximal stretches of consecutive cells on one
/// level in one chunk (a path re-entering a chunk starts a new run each time): writes each
/// run's first cell index into `starts`, adds each run key's shard to `shard_counts`, and
/// returns the run count. `levels` is the stitched levels column, or null for a plain path
/// on `path_level`. O(cells): coordinates follow each step, with a division only to start,
/// at a level change, or after a step to a cell that is not a neighbour.
// SIMD verdict: scalar. Run boundaries are data-dependent and each step updates the
// coordinates of the previous one.
pub fn splitRuns(geometry: ChunkGeometry, cells: []const u32, levels: ?[]const u16, path_level: u16, starts: []u16, shard_counts: *[registry_shard_count]u32) u32 {
    std.debug.assert(cells.len <= starts.len);
    var run_count: u32 = 0;
    var cursor: CellCursor = undefined;
    var run_level: u16 = 0;
    var run_chunk_x: usize = 0;
    var run_chunk_y: usize = 0;
    for (cells, 0..) |cell, index| {
        const level = if (levels) |column| column[index] else path_level;
        const level_changed = index == 0 or level != run_level;
        if (level_changed) cursor = .init(geometry.width, cell) else cursor.moveTo(cell);
        const chunk_x = cursor.x >> geometry.shift;
        const chunk_y = cursor.y >> geometry.shift;
        if (!level_changed and chunk_x == run_chunk_x and chunk_y == run_chunk_y) continue;
        // A run start indexes the stripe, whose width the reserve keeps within u16.
        starts[run_count] = @intCast(index);
        run_count += 1;
        shard_counts[registryShard(chunkKey(level, geometry.chunkOf(cursor.x, cursor.y)))] += 1;
        run_level = level;
        run_chunk_x = chunk_x;
        run_chunk_y = chunk_y;
    }
    return run_count;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const test_support = @import("test_support.zig");

test "reconstructLocalPath walks the parent slot chain into start-to-goal order" {
    var scratch = SearchScratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reserve(std.testing.allocator, 64, 16, 16);
    scratch.reset();

    // Cells far from their slot ids, chained 100 <- 200 <- 300 <- 400 by parent slot: a walk
    // that read the parent as a cell would leave the chain.
    const cells = [_]usize{ 100, 200, 300, 400 };
    var slots: [cells.len]u32 = undefined;
    for (cells, &slots) |cell, *slot| slot.* = scratch.slotFor(cell).?;
    for (1..slots.len) |index| scratch.slots[slots[index]].parent = slots[index - 1];

    reconstructLocalPath(&scratch, slots[3]);
    try std.testing.expectEqualSlices(u32, &.{ 100, 200, 300, 400 }, scratch.path_scratch.items);

    // The root alone yields the single start cell.
    reconstructLocalPath(&scratch, slots[0]);
    try std.testing.expectEqualSlices(u32, &.{100}, scratch.path_scratch.items);
}

// A direct per-cell A* with the production heap order, move table, and budget semantics.
const ReferenceLocalSearch = struct {
    result: LocalSolve,
    explored: usize,
};

fn referenceLocalAStar(allocator: std.mem.Allocator, grid: *const NavGrid, budget: usize, open_limit: usize, start_index: usize, goal_index: usize, path: *std.ArrayList(u32)) !ReferenceLocalSearch {
    const cell_count = grid.cellCount();
    const g = try allocator.alloc(u32, cell_count);
    defer allocator.free(g);
    const parent = try allocator.alloc(usize, cell_count);
    defer allocator.free(parent);
    const touched = try allocator.alloc(bool, cell_count);
    defer allocator.free(touched);
    const closed = try allocator.alloc(bool, cell_count);
    defer allocator.free(closed);
    @memset(touched, false);
    var open: std.ArrayList(OpenNode) = .empty;
    defer open.deinit(allocator);
    var explored: usize = 0;

    const Touch = struct {
        fn cell(index: usize, touched_cells: []bool, g_cells: []u32, parent_cells: []usize, closed_cells: []bool, explored_count: *usize, node_budget: usize) bool {
            if (touched_cells[index]) return true;
            if (explored_count.* >= node_budget) return false;
            explored_count.* += 1;
            touched_cells[index] = true;
            g_cells[index] = types.unreachable_cost;
            parent_cells[index] = no_parent;
            closed_cells[index] = false;
            return true;
        }
    };

    path.clearRetainingCapacity();
    const width: i32 = @intCast(grid.geometry.width);
    const goal_x: i32 = @intCast(goal_index % grid.geometry.width);
    const goal_y: i32 = @intCast(goal_index / grid.geometry.width);
    if (!Touch.cell(start_index, touched, g, parent, closed, &explored, budget)) return .{ .result = .budget_exhausted, .explored = explored };
    g[start_index] = 0;
    const h0 = octileXY(@intCast(start_index % grid.geometry.width), @intCast(start_index / grid.geometry.width), goal_x, goal_y);
    try open.append(allocator, .{ .index = start_index, .f = h0, .h = h0 });
    while (open.items.len != 0) {
        const current = popHeap(&open);
        if (closed[current.index]) continue;
        if (current.f -% current.h > g[current.index]) continue;
        closed[current.index] = true;
        if (current.index == goal_index) {
            var cell = goal_index;
            while (true) {
                try path.append(allocator, @intCast(cell));
                if (parent[cell] == no_parent) break;
                cell = parent[cell];
            }
            std.mem.reverse(u32, path.items);
            return .{ .result = .found, .explored = explored };
        }
        const cy = current.index / grid.geometry.width;
        const cx = current.index - cy * grid.geometry.width;
        const moves = allowed_moves[grid.neighborhood(cx, cy)];
        for (neighbor_dirs, 0..) |dir, dir_index| {
            if (moves & (@as(u8, 1) << @intCast(dir_index)) == 0) continue;
            const nx = @as(i32, @intCast(cx)) + dir.x;
            const ny = @as(i32, @intCast(cy)) + dir.y;
            const next: usize = @intCast(ny * width + nx);
            if (!Touch.cell(next, touched, g, parent, closed, &explored, budget)) return .{ .result = .budget_exhausted, .explored = explored };
            if (closed[next]) continue;
            const candidate = g[current.index] +| (if (dir.diagonal) diagonal_cost else cardinal_cost);
            if (candidate >= g[next]) continue;
            g[next] = candidate;
            parent[next] = current.index;
            const h = octileXY(nx, ny, goal_x, goal_y);
            if (open.items.len >= open_limit) return .{ .result = .budget_exhausted, .explored = explored };
            try open.append(allocator, .{ .index = next, .f = candidate +| h, .h = h });
            siftUp(open.items, open.items.len - 1);
        }
    }
    return .{ .result = .none, .explored = explored };
}

test "local A* paths equal a direct-array reference search" {
    const allocator = std.testing.allocator;
    var expected_path: std.ArrayList(u32) = .empty;
    defer expected_path.deinit(allocator);
    var found: usize = 0;
    var spilled: usize = 0;
    for (0..12) |seed| {
        var prng = std.Random.DefaultPrng.init(0x5eed_0000 + seed);
        const random = prng.random();
        var grid = NavGrid{};
        defer grid.deinit(allocator);
        try grid.prepare(allocator, 0, 24, 24, 32, 8);
        var blocked: std.ArrayList([2]usize) = .empty;
        defer blocked.deinit(allocator);
        for (0..24) |y| {
            for (0..24) |x| {
                if (random.uintLessThan(u32, 100) < 28) try blocked.append(allocator, .{ x, y });
            }
        }
        try test_support.setBlockedCells(allocator, &grid, blocked.items);

        for ([_]usize{ 4096, 40 }) |budget| {
            var scratch = SearchScratch{};
            defer scratch.deinit(allocator);
            try scratch.reserve(allocator, budget, 16, 16);
            for (0..6) |_| {
                const start = random.uintLessThan(usize, grid.cellCount());
                const goal = random.uintLessThan(usize, grid.cellCount());
                if (grid.isBlockedIndex(start) or grid.isBlockedIndex(goal) or start == goal) continue;
                const expected = try referenceLocalAStar(allocator, &grid, budget, scratch.open_limit, start, goal, &expected_path);
                const result = localAStar(&grid, &scratch, start, goal);
                try std.testing.expectEqual(expected.result, result);
                try std.testing.expectEqual(expected.explored, scratch.explored);
                if (result == .found) {
                    try std.testing.expectEqualSlices(u32, expected_path.items, scratch.path_scratch.items);
                    found += 1;
                }
                spilled += @intFromBool(result == .budget_exhausted);
            }
        }
    }
    try std.testing.expect(found > 10);
    try std.testing.expect(spilled > 0);
}

test "local A* spills at open_limit regardless of the heap's physical capacity" {
    const allocator = std.testing.allocator;
    var grid = NavGrid{};
    defer grid.deinit(allocator);
    try grid.prepare(allocator, 0, 8, 8, 32, 16);

    var a = SearchScratch{};
    defer a.deinit(allocator);
    var b = SearchScratch{};
    defer b.deinit(allocator);
    var c = SearchScratch{};
    defer c.deinit(allocator);
    inline for (.{ &a, &b, &c }) |scratch| try scratch.reserve(allocator, 64, 16, 16);
    // Local fixture: a tiny logical heap limit on A and B; B also gets far more physical
    // capacity than any limit, which must not move its spill point.
    a.open_limit = 3;
    b.open_limit = 3;
    try b.open.ensureTotalCapacity(allocator, 4 * types.openHeapLimit(64));

    try std.testing.expectEqual(LocalSolve.budget_exhausted, localAStar(&grid, &a, 0, 63));
    try std.testing.expectEqual(LocalSolve.budget_exhausted, localAStar(&grid, &b, 0, 63));
    try std.testing.expectEqual(a.explored, b.explored);
    try std.testing.expectEqual(@as(usize, 3), a.open.items.len);
    try std.testing.expectEqual(@as(usize, 3), b.open.items.len);
    // The reserved limit (openHeapLimit(64) = 256) completes the same search.
    try std.testing.expectEqual(LocalSolve.found, localAStar(&grid, &c, 0, 63));
}

fn testAbstractNode(ref: usize) AbstractNode {
    return .{ .ref = ref, .x = 0, .y = 0, .portal = null };
}

test "abstract relax saturates at open_limit regardless of physical capacity" {
    const allocator = std.testing.allocator;
    var a = AbstractScratch{};
    defer a.deinit(allocator);
    var b = AbstractScratch{};
    defer b.deinit(allocator);
    inline for (.{ &a, &b }) |abstract| {
        try abstract.reserve(allocator, 16);
        abstract.reset();
        abstract.open_limit = 2;
    }
    try b.open.ensureTotalCapacity(allocator, 256);

    var no_links = CrossLevelHeuristic.fromBounds(&LinkBounds{}, 0, 0, 0);
    inline for (.{ &a, &b }) |abstract| {
        try std.testing.expect(relaxAbstractNode(abstract, no_slot, 0, testAbstractNode(1), 10, false, &no_links, null));
        try std.testing.expect(relaxAbstractNode(abstract, no_slot, 0, testAbstractNode(2), 10, false, &no_links, null));
        try std.testing.expect(!relaxAbstractNode(abstract, no_slot, 0, testAbstractNode(3), 10, false, &no_links, null));
        try std.testing.expectEqual(@as(usize, 2), abstract.open.items.len);
    }
}

/// Claims `first..first+len` in `abstract` and chains each ref's parent slot to the
/// previous one's (the first is the root).
fn claimAbstractChain(abstract: *AbstractScratch, first: usize, len: usize) !void {
    var parent: u32 = no_slot;
    for (first..first + len) |ref| {
        const claim = abstract.slotFor(ref) orelse return error.TestUnexpectedResult;
        abstract.slots[claim.slot].parent = parent;
        parent = claim.slot;
    }
}

fn abstractSlotOf(abstract: *AbstractScratch, ref: usize) u32 {
    return abstract.slotFor(ref).?.slot;
}

test "buildCorridor truncates at corridor_limit regardless of physical capacity" {
    const allocator = std.testing.allocator;
    var a = AbstractScratch{};
    defer a.deinit(allocator);
    var b = AbstractScratch{};
    defer b.deinit(allocator);
    inline for (.{ &a, &b }) |abstract| {
        try abstract.reserve(allocator, 8);
        // Local fixture: a 4-entry corridor limit under room to claim a 6-node chain.
        abstract.corridor_limit = 4;
        abstract.reset();
        try claimAbstractChain(abstract, 10, 6);
    }
    try b.corridor.ensureTotalCapacity(allocator, 64);
    try b.corridor_link.ensureTotalCapacity(allocator, 64);

    inline for (.{ &a, &b }) |abstract| {
        try std.testing.expectEqual(CorridorBuild.truncated, buildCorridor(abstract, abstractSlotOf(abstract, 15), 0));
        try std.testing.expectEqual(@as(usize, 4), abstract.corridor.items.len);
    }

    // Control: a chain within the limit rebuilds in full, its links read from the slots.
    a.reset();
    try claimAbstractChain(&a, 20, 3);
    a.slots[abstractSlotOf(&a, 22)].flags.via_link = true;
    try std.testing.expectEqual(CorridorBuild.ok, buildCorridor(&a, abstractSlotOf(&a, 22), 0));
    try std.testing.expectEqualSlices(usize, &.{ 20, 21, 22 }, a.corridor.items);
    try std.testing.expectEqualSlices(bool, &.{ false, false, true }, a.corridor_link.items);
}

// An abstract search with its own estimate and no least-node tracking.
fn searchAbstract(graph: *const NavGraph, abstract: *AbstractScratch, start_grid: *const NavGrid, goal_grid: *const NavGrid, start_level: u16, goal_level: u16, start_index: usize, goal_index: usize, node_cap: usize) AbstractResult {
    var heuristic: CrossLevelHeuristic = undefined;
    return abstractCorridor(graph, abstract, start_grid, goal_grid, start_level, goal_level, start_index, goal_index, node_cap, &heuristic, null);
}

test "the abstract node budget clamps to the table's reserved limit" {
    const allocator = std.testing.allocator;
    var data = @import("../../data_system.zig").DataSystem.init(allocator);
    defer data.deinit();
    var meta = try test_support.loadTestWorldMeta(allocator);
    defer meta.deinit();
    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    var capacity = test_support.abstractCapacity();
    capacity.group_field_max_cells = 16;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const grid = system.graph.grid(0).?;
    const start = grid.indexForCell(.{ .x = 0, .y = 0 }).?;
    const goal = grid.indexForCell(.{ .x = 11, .y = 11 }).?;

    // Reserved for 3 nodes (a 16-row table); the query asks for far more.
    var abstract = AbstractScratch{};
    defer abstract.deinit(allocator);
    try abstract.reserve(allocator, 3);
    try std.testing.expectEqual(AbstractResult.saturated, searchAbstract(&system.graph, &abstract, grid, grid, 0, 0, start, goal, 1_000_000));
    try std.testing.expectEqual(@as(usize, 3), abstract.node_budget);
    try std.testing.expectEqual(@as(usize, 3), abstract.nodes_used);
    // Reserved for the full search, the same query finds its corridor.
    try abstract.reserve(allocator, 4096);
    try std.testing.expect(searchAbstract(&system.graph, &abstract, grid, grid, 0, 0, start, goal, 1_000_000) == .found);
}

test "the least-estimate fallback keeps the lowest estimate, ties to the lower ref, and is below the start only strictly" {
    var least: LeastExpanded = undefined;
    least.begin(50);
    try std.testing.expect(!least.belowStart());
    least.consider(4, 900, 60);
    try std.testing.expectEqual(@as(u32, 4), least.slot);
    try std.testing.expect(!least.belowStart());
    // A tie goes to the lower ref, whatever the order offered.
    least.consider(5, 700, 60);
    least.consider(6, 800, 60);
    try std.testing.expectEqual(@as(usize, 700), least.ref);
    try std.testing.expectEqual(@as(u32, 5), least.slot);
    // Equal to the start's estimate is not below it.
    least.consider(7, 990, 50);
    try std.testing.expect(!least.belowStart());
    least.consider(8, 999, 49);
    least.consider(9, 1, 70);
    try std.testing.expectEqual(@as(u32, 8), least.slot);
    try std.testing.expectEqual(@as(u32, 49), least.h);
    try std.testing.expect(least.belowStart());
}

test "a saturated search with a fallback returns the chain to its least-estimate expanded node, ties to the lower ref, and expands the same nodes as one without" {
    const allocator = std.testing.allocator;
    var data = @import("../../data_system.zig").DataSystem.init(allocator);
    defer data.deinit();
    var meta = try test_support.loadTestWorldMeta(allocator);
    defer meta.deinit();
    // 32x32 open cells in 4-cell chunks, no links: the estimate is the octile to the goal.
    var world = try test_support.abstractTestWorld(&meta, 1024, 1024);
    defer world.deinit();
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    var capacity = test_support.abstractCapacity();
    capacity.group_field_max_cells = 16;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const graph = &system.graph;
    const grid = graph.grid(0).?;
    const width = graph.geometry.width;
    var abstract = AbstractScratch{};
    defer abstract.deinit(allocator);
    try abstract.reserve(allocator, 4096);

    var toward: usize = 0;
    var ties: usize = 0;
    for ([_][4]u16{ .{ 1, 1, 30, 30 }, .{ 2, 17, 29, 14 }, .{ 30, 2, 1, 29 } }) |route| {
        const start = grid.indexForCell(.{ .x = route[0], .y = route[1] }).?;
        const goal = grid.indexForCell(.{ .x = route[2], .y = route[3] }).?;
        var octile = CrossLevelHeuristic.init(graph, 0, route[2], route[3], null, 0);
        const start_h = octile.estimate(octile.levelTerms(0), 0, route[0], route[1]);
        for (2..40) |budget| {
            const plain = searchAbstract(graph, &abstract, grid, grid, 0, 0, start, goal, budget);
            const plain_nodes = abstract.nodes_used;
            var least: LeastExpanded = undefined;
            var heuristic: CrossLevelHeuristic = undefined;
            const result = abstractCorridor(graph, &abstract, grid, grid, 0, 0, start, goal, budget, &heuristic, &least);
            try std.testing.expectEqual(plain_nodes, abstract.nodes_used);
            if (plain == .found) {
                try std.testing.expect(result == .found);
                continue;
            }
            try std.testing.expect(plain == .saturated);
            try std.testing.expectEqual(start_h, least.start_h);
            // Reference: the least (estimate, ref) over every closed slot of this search.
            var best_h: u32 = unreachable_cost;
            var best_ref: usize = 0;
            var at_best: usize = 0;
            for (abstract.slots) |slot| {
                if (slot.stamp >> 1 != abstract.generation or slot.stamp & 1 == 0) continue;
                const h = octile.estimate(octile.levelTerms(0), 0, slot.x, slot.y);
                if (h < best_h or (h == best_h and slot.node < best_ref)) {
                    if (h < best_h) at_best = 0;
                    best_h = h;
                    best_ref = slot.node;
                }
                if (h == best_h) at_best += 1;
            }
            ties += @intFromBool(at_best > 1);
            if (best_h >= start_h) {
                try std.testing.expect(result == .saturated);
                continue;
            }
            try std.testing.expect(result == .toward);
            toward += 1;
            const corridor = abstract.corridor.items;
            try std.testing.expectEqual(best_ref, corridor[corridor.len - 1]);
            try std.testing.expectEqual(best_h, least.h);
            // Rooted at a start-chunk seed, each step a chunk peer or a border mirror.
            const geometry = graph.chunkGeometry();
            try std.testing.expectEqual(geometry.chunkOf(route[0], route[1]), geometry.chunkOfCell(refLocal(corridor[0])));
            for (corridor[0 .. corridor.len - 1], corridor[1..]) |from, to| {
                const from_cell = refLocal(from);
                const to_cell = refLocal(to);
                if (geometry.chunkOfCell(from_cell) == geometry.chunkOfCell(to_cell)) continue;
                // In range: a 32-cell side.
                const side = width;
                try std.testing.expectEqual(cardinal_cost, octileU32(from_cell % side, from_cell / side, to_cell % side, to_cell / side));
            }
        }
    }
    try std.testing.expect(toward > 10);
    try std.testing.expect(ties > 0);
}

// An uncached abstract A* with the production expansion order and estimate: a hash map of
// nodes keyed by ref, coordinates divided out of the cell and the portal found on every pop.
const ReferenceAbstract = struct {
    const Node = struct {
        g: u32 = types.unreachable_cost,
        parent: usize = no_parent,
        closed: bool = false,
        via_link: bool = false,
    };

    nodes: std.AutoHashMap(usize, Node),
    open: std.ArrayList(OpenNode) = .empty,
    corridor: std.ArrayList(usize) = .empty,
    corridor_link: std.ArrayList(bool) = .empty,
    budget: usize,
    open_limit: usize,
    corridor_limit: usize,
    // `goal_level_octile` is octile on the goal level and 0 off it.
    estimate: enum { cross_level, goal_level_octile } = .cross_level,
    // The cross-level estimate's crossing scratch, at `crossingBoxBudget(budget)`; null leaves
    // the crossing distance out.
    crossing: ?*CrossingScratch = null,

    fn deinit(self: *ReferenceAbstract) void {
        const allocator = self.nodes.allocator;
        self.corridor_link.deinit(allocator);
        self.corridor.deinit(allocator);
        self.open.deinit(allocator);
        self.nodes.deinit();
    }

    fn claim(self: *ReferenceAbstract, ref: usize) !?*Node {
        if (self.nodes.getPtr(ref)) |node| return node;
        if (self.nodes.count() >= self.budget) return null;
        try self.nodes.put(ref, .{});
        return self.nodes.getPtr(ref).?;
    }

    // False on saturation.
    fn relax(self: *ReferenceAbstract, parent: usize, parent_g: u32, ref: usize, cost: u32, via_link: bool, h: u32) !bool {
        const node = (try self.claim(ref)) orelse return false;
        if (node.closed) return true;
        const candidate = parent_g +| cost;
        if (candidate >= node.g) return true;
        node.* = .{ .g = candidate, .parent = parent, .via_link = via_link };
        if (self.open.items.len >= self.open_limit) return false;
        try self.open.append(self.nodes.allocator, .{ .index = ref, .f = candidate +| h, .h = h });
        siftUp(self.open.items, self.open.items.len - 1);
        return true;
    }

    fn estimateAt(self: *const ReferenceAbstract, heuristic: *CrossLevelHeuristic, level: u16, x: u32, y: u32) u32 {
        return switch (self.estimate) {
            .cross_level => heuristic.estimate(heuristic.levelTerms(level), level, x, y),
            .goal_level_octile => if (level == heuristic.goal_level) octileU32(x, y, heuristic.goal_x, heuristic.goal_y) else 0,
        };
    }

    fn search(self: *ReferenceAbstract, graph: *const NavGraph, start_grid: *const NavGrid, goal_grid: *const NavGrid, start_level: u16, goal_level: u16, start_index: usize, goal_index: usize) !AbstractResult {
        const allocator = self.nodes.allocator;
        const width = graph.geometry.width;
        const tiles: u32 = graph.geometry.chunk_tiles;
        const chunks_x = (width + tiles - 1) / tiles;
        const goal: u32 = @intCast(goal_index);
        const goal_x = goal % width;
        const goal_y = goal / width;
        var heuristic = CrossLevelHeuristic.init(graph, goal_level, goal_x, goal_y, self.crossing, crossingBoxBudget(self.budget));
        const start_label = start_grid.labelAt(start_index);
        if (start_label == 0) return .unseedable;
        const start: u32 = @intCast(start_index);
        const start_x = start % width;
        const start_y = start / width;
        const start_portals = graph.chunkPortals(start_level, (start_y / tiles) * chunks_x + start_x / tiles);
        var seeded: usize = 0;
        for ([_][]const NavPortal{ start_portals.border, start_portals.extra }) |portals| {
            for (portals) |portal| {
                if (portal.label != start_label) continue;
                const px = (start_x / tiles) * tiles + portal.local % tiles;
                const py = (start_y / tiles) * tiles + portal.local / tiles;
                const ref = packRef(start_level, py * width + px);
                const node = (try self.claim(ref)) orelse return .saturated;
                node.* = .{ .g = octileU32(start_x, start_y, px, py) };
                if (self.open.items.len >= self.open_limit) return .saturated;
                const h = self.estimateAt(&heuristic, start_level, px, py);
                try self.open.append(allocator, .{ .index = ref, .f = node.g +| h, .h = h });
                siftUp(self.open.items, self.open.items.len - 1);
                seeded += 1;
            }
        }
        if (seeded == 0) return .none;
        const goal_label = goal_grid.labelAt(goal_index);
        const goal_chunk = (goal_y / tiles) * chunks_x + goal_x / tiles;
        while (self.open.items.len != 0) {
            const current = popHeap(&self.open);
            const node = self.nodes.getPtr(current.index).?;
            if (node.closed) continue;
            if (current.f -% current.h > node.g) continue;
            const current_g = node.g;
            const level = refLevel(current.index);
            const cell = refLocal(current.index);
            const x = cell % width;
            const y = cell / width;
            const chunk = (y / tiles) * chunks_x + x / tiles;
            const local: u8 = @intCast((y % tiles) * tiles + x % tiles);
            const portals = graph.chunkPortals(level, chunk);
            const portal = portals.find(local) orelse {
                node.closed = true;
                continue;
            };
            if (isGoalPortal(level, chunk, portal.label, goal_level, goal_chunk, goal_label)) {
                const goal_octile = octileU32(x, y, goal_x, goal_y);
                if (current.h < goal_octile) {
                    if (self.open.items.len >= self.open_limit) return .saturated;
                    try self.open.append(allocator, .{ .index = current.index, .f = current_g +| goal_octile, .h = goal_octile });
                    siftUp(self.open.items, self.open.items.len - 1);
                    continue;
                }
                var ref = current.index;
                var truncated = false;
                while (true) {
                    if (self.corridor.items.len >= self.corridor_limit) {
                        truncated = true;
                        break;
                    }
                    const step = self.nodes.get(ref).?;
                    try self.corridor.append(allocator, ref);
                    try self.corridor_link.append(allocator, step.via_link);
                    if (step.parent == no_parent) break;
                    ref = step.parent;
                }
                std.mem.reverse(usize, self.corridor.items);
                std.mem.reverse(bool, self.corridor_link.items);
                if (self.corridor.items.len == 0) return .none;
                if (truncated) return .saturated;
                self.corridor_link.items[0] = false;
                if (refLevel(self.corridor.items[0]) != start_level) return .none;
                return .{ .found = .{ .crosses_level = start_level != goal_level } };
            }
            node.closed = true;
            for ([_][]const NavPortal{ portals.border, portals.extra }) |peers| {
                for (peers) |peer| {
                    if (peer.local == local or peer.label != portal.label) continue;
                    const px = (x / tiles) * tiles + peer.local % tiles;
                    const py = (y / tiles) * tiles + peer.local / tiles;
                    const h = self.estimateAt(&heuristic, level, px, py);
                    const cost = octileU32(x, y, px, py);
                    if (!try self.relax(current.index, current_g, packRef(level, py * width + px), cost, false, h)) return .saturated;
                }
            }
            const mirrors = [_]struct { present: bool, x: u32, y: u32 }{
                .{ .present = portal.flags.west, .x = x -% 1, .y = y },
                .{ .present = portal.flags.east, .x = x + 1, .y = y },
                .{ .present = portal.flags.north, .x = x, .y = y -% 1 },
                .{ .present = portal.flags.south, .x = x, .y = y + 1 },
            };
            for (mirrors) |mirror| {
                if (!mirror.present) continue;
                const h = self.estimateAt(&heuristic, level, mirror.x, mirror.y);
                if (!try self.relax(current.index, current_g, packRef(level, mirror.y * width + mirror.x), cardinal_cost, false, h)) return .saturated;
            }
            if (!portal.flags.link) continue;
            for (portals.linksAt(local)) |link| {
                const target_grid = graph.grid(link.to_level) orelse continue;
                if (target_grid.isBlockedIndex(link.to_cell)) continue;
                const h = self.estimateAt(&heuristic, link.to_level, link.to_cell % width, link.to_cell / width);
                if (!try self.relax(current.index, current_g, packRef(link.to_level, link.to_cell), link.cost, true, h)) return .saturated;
            }
        }
        return .none;
    }
};

test "abstract corridors with cached slot coordinates equal an uncached reference" {
    const allocator = std.testing.allocator;
    const DataSystem = @import("../../data_system.zig").DataSystem;
    var meta = try test_support.loadTestWorldMeta(allocator);
    defer meta.deinit();
    const grass = try test_support.requireTestTile(&meta, "grass");
    const tree = try test_support.requireTestTile(&meta, "tree_0");
    var found: usize = 0;
    var found_cross_level: usize = 0;
    var found_via_link: usize = 0;
    var saturated: usize = 0;
    for (0..6) |seed| {
        var prng = std.Random.DefaultPrng.init(0xab57_0000 + seed);
        const random = prng.random();
        var data = DataSystem.init(allocator);
        defer data.deinit();
        // 16x16 cells in 4-tile chunks over two levels, random walls, random links.
        var world = try test_support.abstractTestWorld(&meta, 512, 512);
        defer world.deinit();
        _ = try world.addLevel(0);
        _ = try world.addDenseLayer(1, 0, .floor, grass);
        for ([_]u16{ 0, 1 }) |level| {
            const walls = try world.addDenseLayer(level, 0, .obstacle, grass);
            for (0..16) |y| {
                for (0..16) |x| {
                    if (random.uintLessThan(u32, 100) < 22) _ = try world.setDenseTile(walls, @intCast(x), @intCast(y), tree);
                }
            }
        }
        for (0..4) |link_index| {
            const same_level = link_index == 3;
            try world.addLevelLink(.{
                .kind = if (same_level) .teleport else .stair,
                .level_a = 0,
                .cell_a = .{ .x = random.uintLessThan(u16, 16), .y = random.uintLessThan(u16, 16) },
                .level_b = if (same_level) 0 else 1,
                .cell_b = .{ .x = random.uintLessThan(u16, 16), .y = random.uintLessThan(u16, 16) },
                .traversal_cost = 5,
                .bidirectional = random.boolean(),
            });
        }
        var system = PathfindingSystem.init(allocator);
        defer system.deinit();
        var capacity = test_support.abstractCapacity();
        capacity.group_field_max_cells = 16;
        try system.reserve(capacity);
        try system.rebuildStaticNavGridWithWorld(&data, &world, null);
        const graph = &system.graph;

        var abstract = AbstractScratch{};
        defer abstract.deinit(allocator);
        try abstract.reserve(allocator, 4096);
        var reference_crossing = CrossingScratch{};
        defer reference_crossing.deinit(allocator);
        try reference_crossing.reserve(allocator, crossingBoxBudget(4096));
        for (0..24) |query| {
            const start_level: u16 = random.uintLessThan(u16, 2);
            const goal_level: u16 = random.uintLessThan(u16, 2);
            const start_grid = graph.grid(start_level).?;
            const goal_grid = graph.grid(goal_level).?;
            const start = random.uintLessThan(usize, start_grid.cellCount());
            const goal = random.uintLessThan(usize, goal_grid.cellCount());
            if (start_grid.isBlockedIndex(start) or goal_grid.isBlockedIndex(goal)) continue;
            // Every fourth query runs on a budget small enough to saturate.
            const budget: usize = if (query % 4 == 3) 6 else 4096;
            var reference = ReferenceAbstract{
                .nodes = std.AutoHashMap(usize, ReferenceAbstract.Node).init(allocator),
                .budget = budget,
                .open_limit = abstract.open_limit,
                .corridor_limit = abstract.corridor_limit,
                .crossing = &reference_crossing,
            };
            defer reference.deinit();
            const expected = try reference.search(graph, start_grid, goal_grid, start_level, goal_level, start, goal);
            const result = searchAbstract(graph, &abstract, start_grid, goal_grid, start_level, goal_level, start, goal, budget);
            try std.testing.expectEqualDeep(expected, result);
            try std.testing.expectEqual(reference.nodes.count(), abstract.nodes_used);
            saturated += @intFromBool(result == .saturated);
            if (result != .found) continue;
            try std.testing.expectEqualSlices(usize, reference.corridor.items, abstract.corridor.items);
            try std.testing.expectEqualSlices(bool, reference.corridor_link.items, abstract.corridor_link.items);
            found += 1;
            found_cross_level += @intFromBool(start_level != goal_level);
            found_via_link += @intFromBool(std.mem.indexOfScalar(bool, abstract.corridor_link.items, true) != null);
        }
    }
    try std.testing.expect(found > 10);
    try std.testing.expect(found_cross_level > 0);
    try std.testing.expect(found_via_link > 0);
    try std.testing.expect(saturated > 0);
}

test "abstract expansion visits only same-label peers, border mirrors, and live links" {
    const DataSystem = @import("../../data_system.zig").DataSystem;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try test_support.loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try test_support.requireTestTile(&meta, "grass");
    const tree = try test_support.requireTestTile(&meta, "tree_0");
    // 12x12 cells in 4-tile chunks. A full-height wall at x=5 splits chunk column 1 into
    // two labels, and a one-way teleport from (9,9) lands on the blocked cell (2,2).
    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);
    for (0..12) |y| _ = try world.setDenseTile(obstacle, 5, @intCast(y), tree);
    _ = try world.setDenseTile(obstacle, 2, 2, tree);
    try world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 9, .y = 9 }, .level_b = 0, .cell_b = .{ .x = 2, .y = 2 }, .traversal_cost = 1, .bidirectional = false });
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = test_support.abstractCapacity();
    capacity.group_field_max_cells = 16;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const graph = &system.graph;
    const grid = graph.grid(0).?;
    const start = grid.indexForCell(.{ .x = 6, .y = 5 }).?;
    const goal = grid.indexForCell(.{ .x = 2, .y = 5 }).?;

    const abstract = &system.scratch_slots.items[0].corridor.abstract;
    try std.testing.expectEqual(AbstractResult.none, searchAbstract(graph, abstract, grid, grid, 0, 0, start, goal, 4096));
    // Every node the search touched is a portal of its chunk's record east of the wall:
    // no other-label peer in the start chunk, and never the dead link's blocked target.
    var touched: usize = 0;
    var reached_link_source = false;
    for (abstract.slots) |slot| {
        if (slot.stamp >> 1 != abstract.generation) continue;
        touched += 1;
        try std.testing.expectEqual(@as(u16, 0), refLevel(slot.node));
        const cell = refLocal(slot.node);
        try std.testing.expect(cell % grid.geometry.width > 5);
        // Cached coordinates are the node's own.
        try std.testing.expectEqual(cell % grid.geometry.width, slot.x);
        try std.testing.expectEqual(cell / grid.geometry.width, slot.y);
        try std.testing.expect(graph.chunkPortals(0, graph.geometry.chunkOfCell(cell)).find(test_support.localOfCell(graph.geometry, cell)) != null);
        if (cell == grid.indexForCell(.{ .x = 9, .y = 9 }).?) reached_link_source = true;
    }
    try std.testing.expect(touched > 1);
    try std.testing.expect(reached_link_source);
}

const LevelLink = @import("../../world_system.zig").LevelLink;
const WorldSystem = @import("../../world_system.zig").WorldSystem;
const WorldTilesetMeta = @import("../../../assets/world_tileset_meta.zig").WorldTilesetMeta;

// 16x16 cells in 4-tile chunks over `levels` levels, each with random walls.
fn heuristicTestWorld(meta: *const WorldTilesetMeta, random: std.Random, levels: u16) !WorldSystem {
    const grass = try test_support.requireTestTile(meta, "grass");
    const tree = try test_support.requireTestTile(meta, "tree_0");
    var world = try test_support.abstractTestWorld(meta, 512, 512);
    errdefer world.deinit();
    for (1..levels) |level| {
        _ = try world.addLevel(-16 * @as(i32, @intCast(level)));
        _ = try world.addDenseLayer(@intCast(level), 0, .floor, grass);
    }
    for (0..levels) |level| {
        const walls = try world.addDenseLayer(@intCast(level), 0, .obstacle, grass);
        for (0..16) |y| {
            for (0..16) |x| {
                if (random.uintLessThan(u32, 100) < 20) _ = try world.setDenseTile(walls, @intCast(x), @intCast(y), tree);
            }
        }
    }
    return world;
}

fn randomCell(random: std.Random, x_min: u16, x_end: u16) @import("../../world_system.zig").CellCoord {
    return .{ .x = x_min + random.uintLessThan(u16, x_end - x_min), .y = random.uintLessThan(u16, 16) };
}

// Links of every bound class over `levels` (>= 3) levels: ramps (planar span 0), a two-level
// stair, a cross-level short teleport whose span far exceeds the cheapest short link's cost,
// and long same-level and cross-level teleports.
fn heuristicTestLinks(random: std.Random, levels: u16) [9]LevelLink {
    var links: [9]LevelLink = undefined;
    for (links[0..3]) |*link| {
        const upper = random.uintLessThan(u16, levels - 1);
        const cell = randomCell(random, 0, 16);
        link.* = .{ .kind = .ramp, .level_a = upper, .cell_a = cell, .level_b = upper + 1, .cell_b = cell, .traversal_cost = 1, .bidirectional = true };
    }
    const stair_upper = random.uintLessThan(u16, levels - 2);
    const stair_cell = randomCell(random, 0, 15);
    links[3] = .{ .kind = .stair, .level_a = stair_upper, .cell_a = stair_cell, .level_b = stair_upper + 2, .cell_b = .{ .x = stair_cell.x + 1, .y = stair_cell.y }, .traversal_cost = 5, .bidirectional = random.boolean() };
    // Planar span 100 under cost 140: short.
    const wide_cell = randomCell(random, 0, 6);
    links[4] = .{ .kind = .teleport, .level_a = 0, .cell_a = wide_cell, .level_b = levels - 1, .cell_b = .{ .x = wide_cell.x + 10, .y = wide_cell.y }, .traversal_cost = 100, .bidirectional = random.boolean() };
    // Planar span at least 80 over cost at most 43: long.
    for (links[5..9], 0..) |*link, index| {
        const level_a = random.uintLessThan(u16, levels);
        const level_b = if (index < 2) level_a else (level_a + 1 + random.uintLessThan(u16, levels - 1)) % levels;
        link.* = .{ .kind = .teleport, .level_a = level_a, .cell_a = randomCell(random, 0, 4), .level_b = level_b, .cell_b = randomCell(random, 12, 16), .traversal_cost = random.uintLessThan(u32, 4), .bidirectional = random.boolean() };
    }
    return links;
}

// `heuristicTestLinks`, plus with `merged` 24 random long teleports from the west columns to the
// east ones, so the long links outnumber the pair summary's width.
fn heuristicTestLinkSet(random: std.Random, levels: u16, merged: bool, buffer: *[9 + 24]LevelLink) []LevelLink {
    buffer[0..9].* = heuristicTestLinks(random, levels);
    if (!merged) return buffer[0..9];
    for (buffer[9..]) |*link| {
        link.* = .{ .kind = .teleport, .level_a = random.uintLessThan(u16, levels), .cell_a = randomCell(random, 0, 4), .level_b = random.uintLessThan(u16, levels), .cell_b = randomCell(random, 12, 16), .traversal_cost = random.uintLessThan(u32, 4), .bidirectional = random.boolean() };
    }
    return buffer;
}

fn heuristicAt(heuristic: *CrossLevelHeuristic, level: u16, x: u32, y: u32) u32 {
    return heuristic.estimate(heuristic.levelTerms(level), level, x, y);
}

// Whether a pair holds a long link: its source in the entrance box and its target in the exit
// box (box terms 0), at a cost no more than the link's.
fn pairHoldsLink(pairs: *const LinkPairs, rates: CrossingRates, from: [3]u32, to: [3]u32, cost: u32) bool {
    const entrance_terms = pairs.entrances.laneTerms(from[1], from[2], @intCast(from[0]), rates);
    const exit_terms = pairs.exits.laneTerms(to[1], to[2], @intCast(to[0]), rates);
    for (0..pairs.count) |pair| {
        if (entrance_terms[pair] == 0 and exit_terms[pair] == 0 and pairs.cost[pair] <= cost) return true;
    }
    return false;
}

fn pushDistance(allocator: std.mem.Allocator, distances: *std.AutoHashMap(usize, u32), open: *std.ArrayList(OpenNode), ref: usize, candidate: u32) !void {
    if (candidate >= (distances.get(ref) orelse unreachable_cost)) return;
    try distances.put(ref, candidate);
    try open.append(allocator, .{ .index = ref, .f = candidate, .h = 0 });
    siftUp(open.items, open.items.len - 1);
}

// The least abstract objective (g at a goal portal plus its octile to the goal) over every
// path `abstractCorridor` may take: an exhaustive Dijkstra over the same nodes and edges with
// goal portals terminal. Null when no goal portal is reachable.
fn exhaustiveAbstractObjective(allocator: std.mem.Allocator, graph: *const NavGraph, start_grid: *const NavGrid, goal_grid: *const NavGrid, start_level: u16, goal_level: u16, start_index: usize, goal_index: usize) !?u32 {
    const width = graph.geometry.width;
    const tiles: u32 = graph.geometry.chunk_tiles;
    const chunks_x = (width + tiles - 1) / tiles;
    const goal: u32 = @intCast(goal_index);
    const goal_x = goal % width;
    const goal_y = goal / width;
    const goal_label = goal_grid.labelAt(goal_index);
    const goal_chunk = (goal_y / tiles) * chunks_x + goal_x / tiles;
    var distances = std.AutoHashMap(usize, u32).init(allocator);
    defer distances.deinit();
    var closed = std.AutoHashMap(usize, void).init(allocator);
    defer closed.deinit();
    var open: std.ArrayList(OpenNode) = .empty;
    defer open.deinit(allocator);

    const start_label = start_grid.labelAt(start_index);
    const start: u32 = @intCast(start_index);
    const start_x = start % width;
    const start_y = start / width;
    const start_portals = graph.chunkPortals(start_level, (start_y / tiles) * chunks_x + start_x / tiles);
    for ([_][]const NavPortal{ start_portals.border, start_portals.extra }) |portals| {
        for (portals) |portal| {
            if (portal.label != start_label) continue;
            const px = (start_x / tiles) * tiles + portal.local % tiles;
            const py = (start_y / tiles) * tiles + portal.local / tiles;
            try pushDistance(allocator, &distances, &open, packRef(start_level, py * width + px), octileU32(start_x, start_y, px, py));
        }
    }
    var best: u32 = unreachable_cost;
    while (open.items.len != 0) {
        const current = popHeap(&open);
        if (closed.contains(current.index)) continue;
        const g = distances.get(current.index).?;
        if (current.f > g) continue;
        try closed.put(current.index, {});
        const level = refLevel(current.index);
        const cell = refLocal(current.index);
        const x = cell % width;
        const y = cell / width;
        const chunk = (y / tiles) * chunks_x + x / tiles;
        const local: u8 = @intCast((y % tiles) * tiles + x % tiles);
        const portals = graph.chunkPortals(level, chunk);
        const portal = portals.find(local) orelse continue;
        if (isGoalPortal(level, chunk, portal.label, goal_level, goal_chunk, goal_label)) {
            best = @min(best, g +| octileU32(x, y, goal_x, goal_y));
            continue;
        }
        for ([_][]const NavPortal{ portals.border, portals.extra }) |peers| {
            for (peers) |peer| {
                if (peer.local == local or peer.label != portal.label) continue;
                const px = (x / tiles) * tiles + peer.local % tiles;
                const py = (y / tiles) * tiles + peer.local / tiles;
                try pushDistance(allocator, &distances, &open, packRef(level, py * width + px), g +| octileU32(x, y, px, py));
            }
        }
        const mirrors = [_]struct { present: bool, cell: u32 }{
            .{ .present = portal.flags.west, .cell = cell -% 1 },
            .{ .present = portal.flags.east, .cell = cell + 1 },
            .{ .present = portal.flags.north, .cell = cell -% width },
            .{ .present = portal.flags.south, .cell = cell + width },
        };
        for (mirrors) |mirror| {
            if (mirror.present) try pushDistance(allocator, &distances, &open, packRef(level, mirror.cell), g +| cardinal_cost);
        }
        for (portals.linksAt(local)) |link| {
            const target_grid = graph.grid(link.to_level) orelse continue;
            if (target_grid.isBlockedIndex(link.to_cell)) continue;
            try pushDistance(allocator, &distances, &open, packRef(link.to_level, link.to_cell), g +| link.cost);
        }
    }
    return if (best == unreachable_cost) null else best;
}

// The objective of the corridor `abstractCorridor` just found: its goal portal's g plus that
// portal's octile to the goal.
fn foundObjective(abstract: *AbstractScratch, width: usize, goal_index: usize) u32 {
    const last = abstract.corridor.items[abstract.corridor.items.len - 1];
    const cell = refLocal(last);
    const g = abstract.slots[abstractSlotOf(abstract, last)].g;
    return g +| octileU32(@intCast(cell % width), @intCast(cell / width), @intCast(goal_index % width), @intCast(goal_index / width));
}

test "the cross-level heuristic is consistent along every abstract edge and at most a goal portal's octile, with its crossing search exact or frozen" {
    const allocator = std.testing.allocator;
    const DataSystem = @import("../../data_system.zig").DataSystem;
    var meta = try test_support.loadTestWorldMeta(allocator);
    defer meta.deinit();
    var crossing = CrossingScratch{};
    defer crossing.deinit(allocator);
    try crossing.reserve(allocator, crossingBoxBudget(4096));
    var frozen: usize = 0;
    var raised: usize = 0;
    var edges: usize = 0;
    var goal_portals: usize = 0;
    var long_sources: usize = 0;
    var collinear_goals: usize = 0;
    // Seeds 6 and 7 hold more long links than the pair summary's width.
    for (0..8) |seed| {
        var prng = std.Random.DefaultPrng.init(0x6e61_0000 + seed);
        const random = prng.random();
        const levels: u16 = 3 + @as(u16, @intCast(seed % 2));
        var data = DataSystem.init(allocator);
        defer data.deinit();
        var world = try heuristicTestWorld(&meta, random, levels);
        defer world.deinit();
        var link_buffer: [9 + 24 + 48]LevelLink = undefined;
        const set = heuristicTestLinkSet(random, levels, seed >= 6, link_buffer[0 .. 9 + 24]);
        // Seeds 6 and 7 also hold more level-crossing short links per level than a level's
        // crossings width, so their boxes merge.
        const ramps: usize = if (seed >= 6) 48 else 0;
        for (link_buffer[set.len..][0..ramps]) |*ramp| {
            const upper = random.uintLessThan(u16, levels - 1);
            const cell = randomCell(random, 0, 16);
            ramp.* = .{ .kind = .ramp, .level_a = upper, .cell_a = cell, .level_b = upper + 1, .cell_b = cell, .traversal_cost = random.uintLessThan(u32, 6), .bidirectional = random.boolean() };
        }
        const links = link_buffer[0 .. set.len + ramps];
        for (links) |link| try world.addLevelLink(link);
        var system = PathfindingSystem.init(allocator);
        defer system.deinit();
        var capacity = test_support.abstractCapacity();
        capacity.group_field_max_cells = 16;
        try system.reserve(capacity);
        try system.rebuildStaticNavGridWithWorld(&data, &world, null);
        const graph = &system.graph;
        const bounds = &graph.link_bounds;
        // Every bound is live, the wide short teleport spans every level, and the cheapest
        // short link costs less than that teleport's planar span.
        try std.testing.expectEqual(levels - 1, bounds.short_span);
        try std.testing.expect(bounds.short_cost < 100 and bounds.long_cost <= 43 and bounds.pairs.count > 0);
        if (seed >= 6) try std.testing.expectEqual(@as(u32, long_link_pairs), bounds.pairs.count);
        if (seed >= 6) {
            var full_levels: usize = 0;
            for (graph.level_crossings.items) |crossings| full_levels += @intFromBool(crossings.departing.count == long_link_pairs);
            try std.testing.expect(full_levels > 0);
        }
        const width = graph.geometry.width;
        // Random goals, then the first open cell on the wide teleport's exit row beyond its
        // exit: there a path through the teleport saves exactly its planar span.
        const wide = links[4];
        const exit_grid = graph.grid(wide.level_b).?;
        var collinear_goal: ?u32 = null;
        for (wide.cell_b.x + 1..16) |x| {
            const cell: u32 = @intCast(@as(usize, wide.cell_b.y) * width + x);
            if (exit_grid.isBlockedIndex(cell)) continue;
            collinear_goal = cell;
            break;
        }
        for (0..9) |goal_index| {
            const fixed = goal_index == 8;
            if (fixed and collinear_goal == null) continue;
            const goal_level = if (fixed) wide.level_b else random.uintLessThan(u16, levels);
            const goal_grid = graph.grid(goal_level).?;
            const goal = if (fixed) collinear_goal.? else random.uintLessThan(u32, @intCast(goal_grid.cellCount()));
            collinear_goals += @intFromBool(fixed);
            const goal_x = goal % width;
            const goal_y = goal / width;
            const goal_label = goal_grid.labelAt(goal);
            const goal_chunk = graph.geometry.chunkOfCell(goal);
            // The full budget, and budgets the crossing search outgrows.
            for ([_]usize{ crossingBoxBudget(4096), 1, 3 }) |crossing_budget| {
                var heuristic = CrossLevelHeuristic.init(graph, goal_level, goal_x, goal_y, &crossing, crossing_budget);
                var plain = CrossLevelHeuristic.init(graph, goal_level, goal_x, goal_y, null, 0);
                for (0..levels) |level_index| {
                    const level: u16 = @intCast(level_index);
                    for (0..graph.chunkCount()) |chunk_index| {
                        const chunk: u32 = @intCast(chunk_index);
                        const portals = graph.chunkPortals(level, chunk);
                        for ([_][]const NavPortal{ portals.border, portals.extra }) |list| {
                            for (list) |portal| {
                                const cell = test_support.cellOfLocal(graph.geometry, chunk, portal.local);
                                const x = cell % width;
                                const y = cell / width;
                                const h = heuristicAt(&heuristic, level, x, y);
                                const plain_h = heuristicAt(&plain, level, x, y);
                                // The crossing distance only raises the estimate, and never on the goal level.
                                try std.testing.expect(h >= plain_h);
                                if (level == goal_level) try std.testing.expectEqual(plain_h, h);
                                raised += @intFromBool(h > plain_h);
                                if (isGoalPortal(level, chunk, portal.label, goal_level, goal_chunk, goal_label)) {
                                    try std.testing.expect(h <= octileU32(x, y, goal_x, goal_y));
                                    goal_portals += 1;
                                }
                                for ([_][]const NavPortal{ portals.border, portals.extra }) |peers| {
                                    for (peers) |peer| {
                                        if (peer.local == portal.local or peer.label != portal.label) continue;
                                        const peer_cell = test_support.cellOfLocal(graph.geometry, chunk, peer.local);
                                        const px = peer_cell % width;
                                        const py = peer_cell / width;
                                        try std.testing.expect(h <= octileU32(x, y, px, py) +| heuristicAt(&heuristic, level, px, py));
                                        edges += 1;
                                    }
                                }
                                const mirrors = [_]struct { present: bool, x: u32, y: u32 }{
                                    .{ .present = portal.flags.west, .x = x -% 1, .y = y },
                                    .{ .present = portal.flags.east, .x = x + 1, .y = y },
                                    .{ .present = portal.flags.north, .x = x, .y = y -% 1 },
                                    .{ .present = portal.flags.south, .x = x, .y = y + 1 },
                                };
                                for (mirrors) |mirror| {
                                    if (!mirror.present) continue;
                                    try std.testing.expect(h <= cardinal_cost +| heuristicAt(&heuristic, level, mirror.x, mirror.y));
                                    edges += 1;
                                }
                                for (portals.linksAt(portal.local)) |link| {
                                    const target_grid = graph.grid(link.to_level) orelse continue;
                                    if (target_grid.isBlockedIndex(link.to_cell)) continue;
                                    const to_x = link.to_cell % width;
                                    const to_y = link.to_cell / width;
                                    try std.testing.expect(h <= link.cost +| heuristicAt(&heuristic, link.to_level, to_x, to_y));
                                    edges += 1;
                                    // A long link lies in a pair: its source in the entrance box, its
                                    // target in the exit box, at no less than the pair's cost.
                                    if (octileU32(x, y, to_x, to_y) > link.cost) {
                                        try std.testing.expect(pairHoldsLink(&bounds.pairs, bounds.crossingRates(), .{ level, x, y }, .{ link.to_level, to_x, to_y }, link.cost));
                                        long_sources += 1;
                                    }
                                }
                            }
                        }
                    }
                }
                frozen += @intFromBool(crossing.frozen);
            }
        }
    }
    try std.testing.expect(frozen > 0);
    try std.testing.expect(raised > 0);
    try std.testing.expect(edges > 1000);
    try std.testing.expect(goal_portals > 0);
    try std.testing.expect(long_sources > 0);
    try std.testing.expect(collinear_goals > 0);
}

test "abstract A* reaches the cost of an exhaustive Dijkstra over the abstract graph, links built whole or through marks" {
    const allocator = std.testing.allocator;
    const DataSystem = @import("../../data_system.zig").DataSystem;
    var meta = try test_support.loadTestWorldMeta(allocator);
    defer meta.deinit();
    var found: usize = 0;
    var found_cross_level: usize = 0;
    var found_via_long: usize = 0;
    var none: usize = 0;
    // Seeds 8 and 9 hold more long links than the pair summary's width, authored long links
    // first, so the second nav apply changes only the crossing rates the pair chains use.
    for (0..10) |seed| {
        const levels: u16 = 3 + @as(u16, @intCast(seed % 2));
        var link_prng = std.Random.DefaultPrng.init(0x6e62_0000 + seed);
        var link_buffer: [9 + 24]LevelLink = undefined;
        const merged = seed >= 8;
        const links = heuristicTestLinkSet(link_prng.random(), levels, merged, &link_buffer);
        if (merged) std.mem.rotate(LevelLink, link_buffer[0..links.len], 5);
        const first_apply = if (merged) links.len - 5 else 4;
        var data = DataSystem.init(allocator);
        defer data.deinit();
        var capacity = test_support.abstractCapacity();
        capacity.group_field_max_cells = 16;

        // The links authored before the world build.
        var whole_prng = std.Random.DefaultPrng.init(0x6e63_0000 + seed);
        var whole_world = try heuristicTestWorld(&meta, whole_prng.random(), levels);
        defer whole_world.deinit();
        for (links) |link| try whole_world.addLevelLink(link);
        var whole = PathfindingSystem.init(allocator);
        defer whole.deinit();
        try whole.reserve(capacity);
        try whole.rebuildStaticNavGridWithWorld(&data, &whole_world, null);

        // The same links added in play, over two nav applies.
        var marked_prng = std.Random.DefaultPrng.init(0x6e63_0000 + seed);
        var marked_world = try heuristicTestWorld(&meta, marked_prng.random(), levels);
        defer marked_world.deinit();
        var marked = PathfindingSystem.init(allocator);
        defer marked.deinit();
        try marked.reserve(capacity);
        try marked.rebuildStaticNavGridWithWorld(&data, &marked_world, null);
        for (links[0..first_apply]) |link| try marked_world.addLevelLink(link);
        _ = try marked.applyBufferedNavUpdates(&test_support.no_colliders, &marked_world, null);
        for (links[first_apply..]) |link| try marked_world.addLevelLink(link);
        _ = try marked.applyBufferedNavUpdates(&test_support.no_colliders, &marked_world, null);
        try std.testing.expect(std.meta.eql(whole.graph.link_bounds, marked.graph.link_bounds));
        for (whole.graph.level_crossings.items, marked.graph.level_crossings.items) |a, b| try std.testing.expect(std.meta.eql(a, b));

        var abstract = AbstractScratch{};
        defer abstract.deinit(allocator);
        try abstract.reserve(allocator, 4096);
        var query_prng = std.Random.DefaultPrng.init(0x6e64_0000 + seed);
        const random = query_prng.random();
        for (0..40) |_| {
            const start_level = random.uintLessThan(u16, levels);
            const goal_level = random.uintLessThan(u16, levels);
            const start = random.uintLessThan(usize, 256);
            const goal = random.uintLessThan(usize, 256);
            for ([_]*const NavGraph{ &whole.graph, &marked.graph }) |graph| {
                const start_grid = graph.grid(start_level).?;
                const goal_grid = graph.grid(goal_level).?;
                if (start_grid.isBlockedIndex(start) or goal_grid.isBlockedIndex(goal)) continue;
                const expected = try exhaustiveAbstractObjective(allocator, graph, start_grid, goal_grid, start_level, goal_level, start, goal);
                switch (searchAbstract(graph, &abstract, start_grid, goal_grid, start_level, goal_level, start, goal, 4096)) {
                    .found => {
                        try std.testing.expectEqual(expected, foundObjective(&abstract, graph.geometry.width, goal));
                        found += 1;
                        found_cross_level += @intFromBool(start_level != goal_level);
                        for (abstract.corridor.items[1..], abstract.corridor.items[0 .. abstract.corridor.items.len - 1], abstract.corridor_link.items[1..]) |to, from, via_link| {
                            if (!via_link) continue;
                            const planar = octileU32(@intCast(refLocal(from) % graph.geometry.width), @intCast(refLocal(from) / graph.geometry.width), @intCast(refLocal(to) % graph.geometry.width), @intCast(refLocal(to) / graph.geometry.width));
                            if (planar > 43) found_via_long += 1;
                        }
                    },
                    .none => {
                        try std.testing.expectEqual(@as(?u32, null), expected);
                        none += 1;
                    },
                    .toward, .saturated, .unseedable => return error.TestUnexpectedResult,
                }
            }
        }
    }
    try std.testing.expect(found > 100);
    try std.testing.expect(found_cross_level > 20);
    try std.testing.expect(found_via_long > 0);
    try std.testing.expect(none > 0);

    // The pocket world, whose first goal-portal pop is not the cheapest, built whole and with
    // its teleport added in play.
    var data = DataSystem.init(allocator);
    defer data.deinit();
    var capacity = test_support.abstractCapacity();
    capacity.group_field_max_cells = 16;
    var whole_world = try pocketRequeueWorld(&meta);
    defer whole_world.deinit();
    try whole_world.addLevelLink(pocket_teleport);
    var whole = PathfindingSystem.init(allocator);
    defer whole.deinit();
    try whole.reserve(capacity);
    try whole.rebuildStaticNavGridWithWorld(&data, &whole_world, null);
    var marked_world = try pocketRequeueWorld(&meta);
    defer marked_world.deinit();
    var marked = PathfindingSystem.init(allocator);
    defer marked.deinit();
    try marked.reserve(capacity);
    try marked.rebuildStaticNavGridWithWorld(&data, &marked_world, null);
    try marked_world.addLevelLink(pocket_teleport);
    _ = try marked.applyBufferedNavUpdates(&test_support.no_colliders, &marked_world, null);
    var abstract = AbstractScratch{};
    defer abstract.deinit(allocator);
    try abstract.reserve(allocator, 4096);
    for ([_]*const NavGraph{ &whole.graph, &marked.graph }) |graph| {
        const grid = graph.grid(0).?;
        const start = grid.indexForCell(pocket_start).?;
        const goal = grid.indexForCell(pocket_goal).?;
        try std.testing.expect(searchAbstract(graph, &abstract, grid, grid, 0, 0, start, goal, 4096) == .found);
        try std.testing.expectEqual(try exhaustiveAbstractObjective(allocator, graph, grid, grid, 0, 0, start, goal), foundObjective(&abstract, graph.geometry.width, goal));
    }
}

test "a cross-level solve claims the same abstract nodes at 6, 18, and 40 levels, and settles the same crossing boxes once the stack passes the route's reach" {
    const allocator = std.testing.allocator;
    const DataSystem = @import("../../data_system.zig").DataSystem;
    var meta = try test_support.loadTestWorldMeta(allocator);
    defer meta.deinit();
    const grass = try test_support.requireTestTile(&meta, "grass");
    var nodes: [3]usize = undefined;
    var corridor_len: [3]usize = undefined;
    var settles: [3]usize = undefined;
    for ([_]u16{ 6, 18, 40 }, &nodes, &corridor_len, &settles) |levels, *level_nodes, *level_corridor_len, *level_settles| {
        var data = DataSystem.init(allocator);
        defer data.deinit();
        // Open 16x16 levels; a ramp shaft at (1, 1) joins every consecutive pair.
        var world = try test_support.abstractTestWorld(&meta, 512, 512);
        defer world.deinit();
        for (1..levels) |level| {
            _ = try world.addLevel(-16 * @as(i32, @intCast(level)));
            _ = try world.addDenseLayer(@intCast(level), 0, .floor, grass);
            try world.addLevelLink(.{ .kind = .ramp, .level_a = @intCast(level - 1), .cell_a = .{ .x = 1, .y = 1 }, .level_b = @intCast(level), .cell_b = .{ .x = 1, .y = 1 }, .traversal_cost = 1, .bidirectional = true });
        }
        var system = PathfindingSystem.init(allocator);
        defer system.deinit();
        var capacity = test_support.abstractCapacity();
        capacity.group_field_max_cells = 16;
        try system.reserve(capacity);
        try system.rebuildStaticNavGridWithWorld(&data, &world, null);
        const graph = &system.graph;
        var abstract = AbstractScratch{};
        defer abstract.deinit(allocator);
        try abstract.reserve(allocator, 4096);
        const start_grid = graph.grid(0).?;
        const goal_grid = graph.grid(4).?;
        const start = start_grid.indexForCell(.{ .x = 0, .y = 0 }).?;
        const goal = goal_grid.indexForCell(.{ .x = 14, .y = 14 }).?;
        try std.testing.expect(searchAbstract(graph, &abstract, start_grid, goal_grid, 0, 4, start, goal, 4096) == .found);
        level_nodes.* = abstract.nodes_used;
        level_corridor_len.* = abstract.corridor.items.len;
        level_settles.* = abstract.crossing.settles;
    }
    try std.testing.expectEqual(nodes[0], nodes[1]);
    try std.testing.expectEqual(nodes[0], nodes[2]);
    try std.testing.expectEqual(corridor_len[0], corridor_len[1]);
    try std.testing.expectEqual(corridor_len[0], corridor_len[2]);
    // The crossing search settles boxes below the goal only within the route's own reach.
    try std.testing.expectEqual(settles[1], settles[2]);
}

test "a long teleport far from the goal leaves same-level abstract nodes and corridor equal to a world without it" {
    const allocator = std.testing.allocator;
    const DataSystem = @import("../../data_system.zig").DataSystem;
    var meta = try test_support.loadTestWorldMeta(allocator);
    defer meta.deinit();
    var nodes: [2]usize = undefined;
    var corridors: [2][]usize = undefined;
    defer for (corridors) |corridor| allocator.free(corridor);
    for ([_]bool{ false, true }, &nodes, &corridors) |teleport, *world_nodes, *world_corridor| {
        var data = DataSystem.init(allocator);
        defer data.deinit();
        // An open 32x32 level in 4-tile chunks.
        var world = try test_support.abstractTestWorld(&meta, 1024, 1024);
        defer world.deinit();
        // A one-way teleport between two border portals: its exit (3, 18) sits beside the
        // start, far from the goal.
        if (teleport) try world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 28, .y = 30 }, .level_b = 0, .cell_b = .{ .x = 3, .y = 18 }, .traversal_cost = 1, .bidirectional = false });
        var system = PathfindingSystem.init(allocator);
        defer system.deinit();
        var capacity = test_support.abstractCapacity();
        capacity.group_field_max_cells = 16;
        try system.reserve(capacity);
        try system.rebuildStaticNavGridWithWorld(&data, &world, null);
        const graph = &system.graph;
        try std.testing.expectEqual(@as(u32, @intFromBool(teleport)), graph.link_bounds.pairs.count);
        var abstract = AbstractScratch{};
        defer abstract.deinit(allocator);
        try abstract.reserve(allocator, 4096);
        const grid = graph.grid(0).?;
        const start = grid.indexForCell(.{ .x = 2, .y = 16 }).?;
        const goal = grid.indexForCell(.{ .x = 12, .y = 16 }).?;
        try std.testing.expect(searchAbstract(graph, &abstract, grid, grid, 0, 0, start, goal, 4096) == .found);
        world_nodes.* = abstract.nodes_used;
        world_corridor.* = try allocator.dupe(usize, abstract.corridor.items);
    }
    try std.testing.expectEqual(nodes[0], nodes[1]);
    try std.testing.expectEqualSlices(usize, corridors[0], corridors[1]);
}

// `levels` open 32x32 levels in 4-tile chunks.
fn openStackWorld(meta: *const WorldTilesetMeta, levels: u16) !WorldSystem {
    const grass = try test_support.requireTestTile(meta, "grass");
    var world = try test_support.abstractTestWorld(meta, 1024, 1024);
    errdefer world.deinit();
    for (1..levels) |level| {
        _ = try world.addLevel(-16 * @as(i32, @intCast(level)));
        _ = try world.addDenseLayer(@intCast(level), 0, .floor, grass);
    }
    return world;
}

// Random level-crossing short links on a 32x32 stack: ramps between adjacent levels, stairs
// two levels apart, and short teleports across the whole stack.
fn randomShortCrossings(random: std.Random, levels: u16, links: []LevelLink) void {
    for (links) |*link| {
        const cell = @import("../../world_system.zig").CellCoord{ .x = random.uintLessThan(u16, 32), .y = random.uintLessThan(u16, 32) };
        const upper = random.uintLessThan(u16, levels - 1);
        link.* = switch (random.uintLessThan(u32, 4)) {
            0, 1 => .{ .kind = .ramp, .level_a = upper, .cell_a = cell, .level_b = upper + 1, .cell_b = cell, .traversal_cost = random.uintLessThan(u32, 8), .bidirectional = random.boolean() },
            2 => .{ .kind = .stair, .level_a = upper, .cell_a = cell, .level_b = @min(levels - 1, upper + 2), .cell_b = .{ .x = cell.x ^ 1, .y = cell.y }, .traversal_cost = 3, .bidirectional = random.boolean() },
            // Planar span at most 14 * 31, under its cost: short.
            else => .{ .kind = .teleport, .level_a = 0, .cell_a = cell, .level_b = levels - 1, .cell_b = .{ .x = random.uintLessThan(u16, 32), .y = random.uintLessThan(u16, 32) }, .traversal_cost = 14 * 31, .bidirectional = random.boolean() },
        };
    }
}

// The relaxed graph's distance from (x, y) on `level` to the goal over unclustered links: free
// octile movement within a level, each directed link's source to its target at its edge cost.
// By Bellman-Ford over the directed links, clamped to `long_lane_cap`.
fn referenceCrossingDistance(allocator: std.mem.Allocator, links: []const LevelLink, goal_level: u16, goal_x: u32, goal_y: u32, level: u16, x: u32, y: u32) !u32 {
    const Directed = struct { from_level: u16, fx: u32, fy: u32, to_level: u16, tx: u32, ty: u32, cost: u64 };
    var directed: std.ArrayList(Directed) = .empty;
    defer directed.deinit(allocator);
    for (links) |link| {
        const cost: u64 = link.traversal_cost +| types.inter_level_penalty;
        try directed.append(allocator, .{ .from_level = link.level_a, .fx = link.cell_a.x, .fy = link.cell_a.y, .to_level = link.level_b, .tx = link.cell_b.x, .ty = link.cell_b.y, .cost = cost });
        if (link.bidirectional) try directed.append(allocator, .{ .from_level = link.level_b, .fx = link.cell_b.x, .fy = link.cell_b.y, .to_level = link.level_a, .tx = link.cell_a.x, .ty = link.cell_a.y, .cost = cost });
    }
    const unreachable_distance = std.math.maxInt(u64);
    // Per directed link, the least cost from its source to the goal through it.
    const through = try allocator.alloc(u64, directed.items.len);
    defer allocator.free(through);
    @memset(through, unreachable_distance);
    var changed = true;
    while (changed) {
        changed = false;
        for (directed.items, through) |link, *best| {
            var landing: u64 = if (link.to_level == goal_level) octileU32(link.tx, link.ty, goal_x, goal_y) else unreachable_distance;
            for (directed.items, through) |next, next_best| {
                if (next.from_level != link.to_level or next_best == unreachable_distance) continue;
                landing = @min(landing, octileU32(link.tx, link.ty, next.fx, next.fy) + next_best);
            }
            if (landing == unreachable_distance or link.cost + landing >= best.*) continue;
            best.* = link.cost + landing;
            changed = true;
        }
    }
    var distance: u64 = unreachable_distance;
    for (directed.items, through) |link, best| {
        if (link.from_level != level or best == unreachable_distance) continue;
        distance = @min(distance, octileU32(x, y, link.fx, link.fy) + best);
    }
    return @intCast(@min(distance, @as(u64, long_lane_cap)));
}

// Directed level-crossing short links leaving `level`.
fn departingLinks(links: []const LevelLink, level: u16) usize {
    var count: usize = 0;
    for (links) |link| count += @as(usize, @intFromBool(link.level_a == level)) + @intFromBool(link.bidirectional and link.level_b == level);
    return count;
}

test "the crossing distance equals a Dijkstra over every link endpoint while each level's links fit its crossings, and stays at most it once boxes merge" {
    const allocator = std.testing.allocator;
    const DataSystem = @import("../../data_system.zig").DataSystem;
    var meta = try test_support.loadTestWorldMeta(allocator);
    defer meta.deinit();
    var scratch = CrossingScratch{};
    defer scratch.deinit(allocator);
    try scratch.reserve(allocator, 1024);
    var exact_checks: usize = 0;
    var merged_checks: usize = 0;
    var below: usize = 0;
    for (0..12) |seed| {
        var prng = std.Random.DefaultPrng.init(0x6e6c_0000 + seed);
        const random = prng.random();
        const levels: u16 = 3 + random.uintLessThan(u16, 4);
        const merged = seed % 3 == 2;
        var link_buffer: [96]LevelLink = undefined;
        const links = link_buffer[0..if (merged) 96 else 2 + random.uintLessThan(usize, 10)];
        randomShortCrossings(random, levels, links);
        var data = DataSystem.init(allocator);
        defer data.deinit();
        var world = try openStackWorld(&meta, levels);
        defer world.deinit();
        for (links) |link| try world.addLevelLink(link);
        var system = PathfindingSystem.init(allocator);
        defer system.deinit();
        try system.reserve(test_support.abstractCapacity());
        try system.rebuildStaticNavGridWithWorld(&data, &world, null);
        const graph = &system.graph;
        var fits = true;
        for (0..levels) |level| fits = fits and departingLinks(links, @intCast(level)) <= long_link_pairs;
        for (0..6) |_| {
            const goal_level = random.uintLessThan(u16, levels);
            const goal_x = random.uintLessThan(u32, 32);
            const goal_y = random.uintLessThan(u32, 32);
            var heuristic = CrossLevelHeuristic.init(graph, goal_level, goal_x, goal_y, &scratch, 1024);
            for (0..24) |_| {
                const level = random.uintLessThan(u16, levels);
                if (level == goal_level) continue;
                const x = random.uintLessThan(u32, 32);
                const y = random.uintLessThan(u32, 32);
                const expected = try referenceCrossingDistance(allocator, links, goal_level, goal_x, goal_y, level, x, y);
                const actual = heuristic.crossing.bound(level, x, y, heuristic.rates);
                if (fits) {
                    try std.testing.expectEqual(expected, actual);
                    exact_checks += 1;
                } else {
                    try std.testing.expect(actual <= expected);
                    below += @intFromBool(actual < expected);
                    merged_checks += 1;
                }
            }
            try std.testing.expect(!scratch.frozen);
        }
    }
    try std.testing.expect(exact_checks > 100);
    try std.testing.expect(merged_checks > 50);
    try std.testing.expect(below > 0);
}

test "a frozen crossing search gives one consistent bound per goal and budget, whatever the evaluation order, at most the unfrozen bound" {
    const allocator = std.testing.allocator;
    const DataSystem = @import("../../data_system.zig").DataSystem;
    var meta = try test_support.loadTestWorldMeta(allocator);
    defer meta.deinit();
    var scratches: [3]CrossingScratch = @splat(.{});
    defer for (&scratches) |*scratch| scratch.deinit(allocator);
    for (&scratches) |*scratch| try scratch.reserve(allocator, 1024);
    var frozen: usize = 0;
    var raised: usize = 0;
    for (0..6) |seed| {
        var prng = std.Random.DefaultPrng.init(0x6e6d_0000 + seed);
        const random = prng.random();
        const levels: u16 = 4 + random.uintLessThan(u16, 3);
        var links: [40]LevelLink = undefined;
        randomShortCrossings(random, levels, &links);
        var data = DataSystem.init(allocator);
        defer data.deinit();
        var world = try openStackWorld(&meta, levels);
        defer world.deinit();
        for (links) |link| try world.addLevelLink(link);
        var system = PathfindingSystem.init(allocator);
        defer system.deinit();
        try system.reserve(test_support.abstractCapacity());
        try system.rebuildStaticNavGridWithWorld(&data, &world, null);
        const graph = &system.graph;
        for (0..4) |_| {
            const goal_level = random.uintLessThan(u16, levels);
            const goal_x = random.uintLessThan(u32, 32);
            const goal_y = random.uintLessThan(u32, 32);
            for ([_]usize{ 0, 1, 2, 4, 8 }) |budget| {
                // Two searches at the budget visiting levels in opposite orders, and one unfrozen.
                var forward = CrossLevelHeuristic.init(graph, goal_level, goal_x, goal_y, &scratches[0], budget);
                var backward = CrossLevelHeuristic.init(graph, goal_level, goal_x, goal_y, &scratches[1], budget);
                var exact = CrossLevelHeuristic.init(graph, goal_level, goal_x, goal_y, &scratches[2], 1024);
                var bounds: [8][32][32]u32 = undefined;
                for (0..levels) |level_index| {
                    const level: u16 = @intCast(level_index);
                    if (level == goal_level) continue;
                    for (0..32) |y| {
                        for (0..32) |x| bounds[level][y][x] = forward.crossing.bound(level, @intCast(x), @intCast(y), forward.rates);
                    }
                }
                var level_index: usize = levels;
                while (level_index > 0) {
                    level_index -= 1;
                    const level: u16 = @intCast(level_index);
                    if (level == goal_level) continue;
                    for (0..32) |y_index| {
                        const y = 31 - y_index;
                        for (0..32) |x| {
                            const bound = backward.crossing.bound(level, @intCast(x), @intCast(y), backward.rates);
                            try std.testing.expectEqual(bounds[level][y][x], bound);
                            const unfrozen = exact.crossing.bound(level, @intCast(x), @intCast(y), exact.rates);
                            try std.testing.expect(bound <= unfrozen);
                            raised += @intFromBool(bound > octileU32(@intCast(x), @intCast(y), goal_x, goal_y));
                        }
                    }
                }
                frozen += @intFromBool(scratches[0].frozen);
                try std.testing.expectEqual(scratches[0].frozen, scratches[1].frozen);
                try std.testing.expect(!scratches[2].frozen);
                // Consistent along every step on a level and every directed link; the goal
                // level counts its octile, which bounds the relaxed distance there.
                const at = struct {
                    fn value(table: *const [8][32][32]u32, goal: [3]u32, level: u16, x: u32, y: u32) u32 {
                        return if (level == goal[0]) octileU32(x, y, goal[1], goal[2]) else table[level][y][x];
                    }
                }.value;
                const goal = [3]u32{ goal_level, goal_x, goal_y };
                for (0..levels) |level_index_2| {
                    const level: u16 = @intCast(level_index_2);
                    if (level == goal_level) continue;
                    for (0..32) |y| {
                        for (0..32) |x| {
                            const here = bounds[level][y][x];
                            if (x + 1 < 32) try std.testing.expect(here <= cardinal_cost + bounds[level][y][x + 1] and bounds[level][y][x + 1] <= cardinal_cost + here);
                            if (y + 1 < 32) try std.testing.expect(here <= cardinal_cost + bounds[level][y + 1][x] and bounds[level][y + 1][x] <= cardinal_cost + here);
                        }
                    }
                }
                for (links) |link| {
                    const cost = link.traversal_cost +| types.inter_level_penalty;
                    if (link.level_a != goal_level) try std.testing.expect(at(&bounds, goal, link.level_a, link.cell_a.x, link.cell_a.y) <= cost + at(&bounds, goal, link.level_b, link.cell_b.x, link.cell_b.y));
                    if (link.bidirectional and link.level_b != goal_level) try std.testing.expect(at(&bounds, goal, link.level_b, link.cell_b.x, link.cell_b.y) <= cost + at(&bounds, goal, link.level_a, link.cell_a.x, link.cell_a.y));
                }
            }
        }
    }
    try std.testing.expect(frozen > 10);
    try std.testing.expect(raised > 1000);
}

// The crossing distance at (x, y) on `level` from a gather made for this call alone, outside
// the gathered-level cache.
fn freshGatherBound(search: *CrossingSearch, level: u16, x: u32, y: u32, rates: CrossingRates) u32 {
    var gathered = CrossingSearch.GatheredLevel{};
    search.gather(level, &gathered);
    const departing = &search.crossings[level].departing;
    return @min(departing.entrances.offsetLowerBound(&gathered.lanes, departing.count, x, y, level, rates), @as(u32, long_lane_cap));
}

// Level `level`'s departing boxes the search has not settled, each checked to count
// `unsettled` in the level's gathered lanes.
fn expectUnsettledLanes(search: *const CrossingSearch, scratch: *CrossingScratch, level: u16, unsettled: i32) !usize {
    const gathered = &search.gathered[level % CrossingSearch.gathered_levels];
    try std.testing.expectEqual(@as(u32, level), gathered.level);
    var count: usize = 0;
    for (0..search.crossings[level].departing.count) |slot| {
        const box = scratch.findBox(crossingBoxRef(level, slot));
        if (box != null and box.?.stamp & 1 != 0) {
            try std.testing.expectEqual(@as(i32, @intCast(box.?.d)), gathered.lanes[slot]);
            continue;
        }
        try std.testing.expectEqual(unsettled, gathered.lanes[slot]);
        count += 1;
    }
    return count;
}

test "a level evicted from the gathered-level cache gathers again to the same bounds, before and after the crossing search freezes, its unsettled boxes counting the cap and then the frozen distance" {
    const allocator = std.testing.allocator;
    const DataSystem = @import("../../data_system.zig").DataSystem;
    var meta = try test_support.loadTestWorldMeta(allocator);
    defer meta.deinit();
    const levels: u16 = 20;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    var world = try openStackWorld(&meta, levels);
    defer world.deinit();
    // One ramp per level pair at alternating corners.
    for (0..levels - 1) |upper_index| {
        const upper: u16 = @intCast(upper_index);
        const coord: u16 = if (upper % 2 == 0) 29 else 2;
        try world.addLevelLink(.{ .kind = .ramp, .level_a = upper, .cell_a = .{ .x = coord, .y = coord }, .level_b = upper + 1, .cell_b = .{ .x = coord, .y = coord }, .traversal_cost = 1, .bidirectional = true });
    }
    // Costly short links from level 1 to the bottom: departing boxes far past level 1's
    // nearest box plus its diameter, so level 1 resolves with them unsettled.
    for ([_]u16{ 8, 16, 24 }) |coord| {
        try world.addLevelLink(.{ .kind = .teleport, .level_a = 1, .cell_a = .{ .x = coord, .y = 31 - coord }, .level_b = levels - 1, .cell_b = .{ .x = coord, .y = 31 - coord }, .traversal_cost = 4000, .bidirectional = false });
    }
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    try system.reserve(test_support.abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    var scratch = CrossingScratch{};
    defer scratch.deinit(allocator);
    try scratch.reserve(allocator, 1024);
    // Level 1 resolves within the budget; level 17, sharing its cache slot, needs more boxes
    // than the budget holds.
    const near: u16 = 1;
    const far: u16 = near + CrossingSearch.gathered_levels;
    var heuristic = CrossLevelHeuristic.init(&system.graph, 0, 4, 4, &scratch, 12);
    const search = &heuristic.crossing;
    try std.testing.expect(system.graph.level_crossings.items[near].departing.count >= 5);
    var first: [32][32]u32 = undefined;
    for (0..32) |y| {
        for (0..32) |x| {
            first[y][x] = search.bound(near, @intCast(x), @intCast(y), heuristic.rates);
            try std.testing.expectEqual(freshGatherBound(search, near, @intCast(x), @intCast(y), heuristic.rates), first[y][x]);
        }
    }
    // Resolved by the diameter rule, not a freeze or a drain: some boxes stay unsettled and
    // count the cap.
    try std.testing.expect(!scratch.frozen and !search.drained);
    try std.testing.expect(try expectUnsettledLanes(search, &scratch, near, long_lane_cap) > 0);
    for (0..32) |y| {
        for (0..32) |x| {
            const bound = search.bound(far, @intCast(x), @intCast(y), heuristic.rates);
            try std.testing.expectEqual(freshGatherBound(search, far, @intCast(x), @intCast(y), heuristic.rates), bound);
        }
    }
    try std.testing.expect(scratch.frozen);
    // Level 17 evicted level 1; its regather after the freeze counts the frozen distance for
    // its unsettled boxes and gives every bound unchanged.
    try std.testing.expectEqual(@as(u32, far), search.gathered[near % CrossingSearch.gathered_levels].level);
    for (0..32) |y| {
        for (0..32) |x| {
            const bound = search.bound(near, @intCast(x), @intCast(y), heuristic.rates);
            try std.testing.expectEqual(first[y][x], bound);
            try std.testing.expectEqual(freshGatherBound(search, near, @intCast(x), @intCast(y), heuristic.rates), bound);
        }
    }
    const frozen_at: i32 = @intCast(search.frozen_at.?);
    try std.testing.expect(frozen_at < long_lane_cap);
    try std.testing.expect(try expectUnsettledLanes(search, &scratch, near, frozen_at) > 0);
}

test "a same-level abstract search settles no crossing box; a corner-to-corner descent settles at most two per level crossed" {
    const allocator = std.testing.allocator;
    const DataSystem = @import("../../data_system.zig").DataSystem;
    var meta = try test_support.loadTestWorldMeta(allocator);
    defer meta.deinit();
    const levels: u16 = 4;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    var world = try openStackWorld(&meta, levels);
    defer world.deinit();
    // One ramp per level pair at alternating corners, inset 2.
    for (0..levels - 1) |upper_index| {
        const upper: u16 = @intCast(upper_index);
        const coord: u16 = if (upper % 2 == 0) 29 else 2;
        try world.addLevelLink(.{ .kind = .ramp, .level_a = upper, .cell_a = .{ .x = coord, .y = coord }, .level_b = upper + 1, .cell_b = .{ .x = coord, .y = coord }, .traversal_cost = 1, .bidirectional = true });
    }
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    try system.reserve(test_support.abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const graph = &system.graph;
    var abstract = AbstractScratch{};
    defer abstract.deinit(allocator);
    try abstract.reserve(allocator, 4096);
    const top = graph.grid(0).?;
    const start = top.indexForCell(.{ .x = 2, .y = 2 }).?;
    // Same level, across the level.
    try std.testing.expect(searchAbstract(graph, &abstract, top, top, 0, 0, start, top.indexForCell(.{ .x = 30, .y = 30 }).?, 4096) == .found);
    try std.testing.expectEqual(@as(usize, 0), abstract.crossing.settles);
    // To the bottom level's far corner: the route crosses every level corner to corner.
    const bottom = graph.grid(levels - 1).?;
    const goal = bottom.indexForCell(.{ .x = 29, .y = 29 }).?;
    try std.testing.expect(searchAbstract(graph, &abstract, top, bottom, 0, levels - 1, start, goal, 4096) == .found);
    try std.testing.expectEqual(try exhaustiveAbstractObjective(allocator, graph, top, bottom, 0, levels - 1, start, goal), foundObjective(&abstract, graph.geometry.width, goal));
    try std.testing.expect(!abstract.crossing.frozen);
    // At least the one box per level crossed the route takes, at most two per level crossed.
    try std.testing.expect(abstract.crossing.settles >= levels - 1 and abstract.crossing.settles <= 2 * (levels - 1));
}

test "with no links the heuristic is octile on the goal level and saturates off it, at any level gap" {
    var none = CrossLevelHeuristic.fromBounds(&LinkBounds{}, 0, 0, 0);
    try std.testing.expectEqual(octileU32(7, 3, 0, 0), heuristicAt(&none, 0, 7, 3));
    try std.testing.expectEqual(unreachable_cost, heuristicAt(&none, 1, 7, 3));
    try std.testing.expectEqual(unreachable_cost, heuristicAt(&none, std.math.maxInt(u16), 7, 3));
    // The largest planar octile, on the goal level and off it.
    const max = std.math.maxInt(u32);
    try std.testing.expectEqual(octileU32(max, max, 0, 0), heuristicAt(&none, 0, max, max));
    try std.testing.expectEqual(unreachable_cost, heuristicAt(&none, 9, max, max));

    // Saturating short and long bounds at the widest gap.
    var widest = LinkBounds{ .short_span = 1, .short_cost = max, .short_excess = max };
    var far = CrossLevelHeuristic.fromBounds(&widest, std.math.maxInt(u16), 0, 0);
    try std.testing.expectEqual(unreachable_cost, heuristicAt(&far, 0, max, max));
    widest.short_span = std.math.maxInt(u16);
    widest.short_cost = 7;
    widest.short_excess = 5;
    var one_crossing = CrossLevelHeuristic.fromBounds(&widest, std.math.maxInt(u16), 0, 0);
    try std.testing.expectEqual(@as(u32, 7), heuristicAt(&one_crossing, 0, 0, 0));
    try std.testing.expectEqual(unreachable_cost, heuristicAt(&one_crossing, 0, max, max));

    // A gap of 3 over two-level links takes two crossings, rounded up.
    var rounded = CrossLevelHeuristic.fromBounds(&LinkBounds{ .short_span = 2, .short_cost = 7, .short_excess = 5 }, 3, 0, 0);
    try std.testing.expectEqual(@as(u32, 14), heuristicAt(&rounded, 0, 0, 0));
    try std.testing.expectEqual(@as(u32, 10 + 10), heuristicAt(&rounded, 0, 1, 0));

    // Box rates: with no crossing short link a level gap costs the cap per level; with
    // two-level links, a level costs at most half a link's cost and excess, rounded down.
    try std.testing.expectEqual(CrossingRates{ .excess = types.crossing_rate_cap, .cost = types.crossing_rate_cap }, (LinkBounds{}).crossingRates());
    try std.testing.expectEqual(CrossingRates{ .excess = 2, .cost = 3 }, (LinkBounds{ .short_span = 2, .short_cost = 7, .short_excess = 5 }).crossingRates());
    try std.testing.expectEqual(CrossingRates{ .excess = types.crossing_rate_cap, .cost = types.crossing_rate_cap }, (LinkBounds{ .short_span = 1, .short_cost = max, .short_excess = max }).crossingRates());

    // Two level-0 pairs toward a goal at (0, 0): pair 0 the cheapest link (10) from (300, 0)
    // to a far exit (100, 0), pair 1 a costly one (200) from (500, 0) to the nearest exit
    // (5, 0). The long floor is 10 + 50; the pair offsets are 10 + 1000 and 200 + 50, since
    // neither chains below its own exit term (4000 + 200 and 2950 + 10).
    const entrance_x = [2]i32{ 300, 500 };
    const exit_x = [2]i32{ 100, 5 };
    const costs = [2]i32{ 10, 200 };
    const chain = [2][2]i32{ .{ 0, 4000 + 200 }, .{ 2950 + 10, 0 } };
    var bounds = LinkBounds{ .long_cost = 10, .pairs = .{ .count = 2 } };
    for (0..long_link_pairs) |slot| {
        // Slots past the count copy pair 0.
        const pair: usize = if (slot == 1) 1 else 0;
        bounds.pairs.entrances.x0[slot] = entrance_x[pair];
        bounds.pairs.entrances.x1[slot] = entrance_x[pair];
        bounds.pairs.exits.x0[slot] = exit_x[pair];
        bounds.pairs.exits.x1[slot] = exit_x[pair];
        bounds.pairs.cost[slot] = costs[pair];
        for (0..long_link_pairs) |to| bounds.chains.to[to][slot] = chain[pair][if (to == 1) 1 else 0];
    }
    var gated = CrossLevelHeuristic.fromBounds(&bounds, 0, 0, 0);
    try std.testing.expectEqual(@as(u32, 60), gated.long_floor);
    // Gate 1: a short term at most the long floor; the offsets stay unbuilt.
    try std.testing.expectEqual(@as(u32, 30), heuristicAt(&gated, 0, 3, 0));
    try std.testing.expect(!gated.pair_ready);
    // Gate 2: past the long floor, at most the pair floor.
    try std.testing.expectEqual(@as(u32, 200), heuristicAt(&gated, 0, 20, 0));
    try std.testing.expect(gated.pair_ready);
    try std.testing.expectEqual(@as(u32, 250), gated.pair_floor);
    // The scan: each pair's offset plus its entrance term, or the short term when less.
    try std.testing.expectEqual(@as(u32, 300), heuristicAt(&gated, 0, 30, 0));
    try std.testing.expectEqual(@as(u32, 1010), heuristicAt(&gated, 0, 300, 0));
    try std.testing.expectEqual(@as(u32, 250 + 100), heuristicAt(&gated, 0, 490, 0));

    // A cheapest link above the lane cap: its pair's cost and offset clamp to the cap, and so
    // does the long floor, so a short term between the cap and the unclamped floor still
    // takes the scan. One pair enters at (300, 0) on level 1 and exits at (5, 0) on level 0;
    // one level-crossing short link costs the cap + 50, so a level-1 node's short term is
    // that.
    var above_cap = LinkBounds{ .short_span = 1, .short_cost = long_lane_cap + 50, .short_excess = 0, .long_cost = long_lane_cap + 100, .pairs = .{ .count = 1 } };
    above_cap.pairs.entrances.x0 = @splat(300);
    above_cap.pairs.entrances.x1 = @splat(300);
    above_cap.pairs.entrances.l0 = @splat(1);
    above_cap.pairs.entrances.l1 = @splat(1);
    above_cap.pairs.exits.x0 = @splat(5);
    above_cap.pairs.exits.x1 = @splat(5);
    above_cap.pairs.cost = @splat(long_lane_cap);
    var clamped = CrossLevelHeuristic.fromBounds(&above_cap, 0, 0, 0);
    try std.testing.expectEqual(@as(u32, long_lane_cap), clamped.long_floor);
    try std.testing.expectEqual(@as(u32, long_lane_cap), heuristicAt(&clamped, 1, 300, 0));
}

// 32x32 cells in 16-tile chunks. Walls close the goal chunk (16..31, 16..31) except two west
// gaps: (16, 17), nearer the start but far from the goal, and (16, 30), near it. A sealed
// one-cell pocket at (13, 17) beside the far gap holds the entrance of `pocket_teleport`, a
// free one-way teleport onto the goal, so the long term cuts estimates near the far gap far
// below their octile to the goal while the teleport itself is never reachable.
fn pocketRequeueWorld(meta: *const WorldTilesetMeta) !WorldSystem {
    const grass = try test_support.requireTestTile(meta, "grass");
    const tree = try test_support.requireTestTile(meta, "tree_0");
    var world = try WorldSystem.initDemoFromMetaWithChunkSize(std.testing.allocator, meta, 1024, 1024, 16);
    errdefer world.deinit();
    const walls = try world.addDenseLayer(0, 0, .obstacle, grass);
    for (16..32) |index| {
        if (index != 17 and index != 30) _ = try world.setDenseTile(walls, 16, @intCast(index), tree);
        _ = try world.setDenseTile(walls, @intCast(index), 16, tree);
    }
    for (12..15) |x| {
        for (16..19) |y| {
            if (x != 13 or y != 17) _ = try world.setDenseTile(walls, @intCast(x), @intCast(y), tree);
        }
    }
    return world;
}

const pocket_teleport = LevelLink{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 13, .y = 17 }, .level_b = 0, .cell_b = .{ .x = 30, .y = 30 }, .traversal_cost = 0, .bidirectional = false };
const pocket_start = types.GridCell{ .x = 14, .y = 23 };
const pocket_goal = types.GridCell{ .x = 30, .y = 30 };

test "a goal portal whose estimate the long floor cut is re-queued before it ends the search" {
    const allocator = std.testing.allocator;
    const DataSystem = @import("../../data_system.zig").DataSystem;
    var meta = try test_support.loadTestWorldMeta(allocator);
    defer meta.deinit();
    var data = DataSystem.init(allocator);
    defer data.deinit();
    var world = try pocketRequeueWorld(&meta);
    defer world.deinit();
    try world.addLevelLink(pocket_teleport);
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    var capacity = test_support.abstractCapacity();
    capacity.group_field_max_cells = 16;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const graph = &system.graph;
    var abstract = AbstractScratch{};
    defer abstract.deinit(allocator);
    try abstract.reserve(allocator, 4096);
    const grid = graph.grid(0).?;
    const start = grid.indexForCell(pocket_start).?;
    const goal = grid.indexForCell(pocket_goal).?;
    // The far gap's estimate is cut to 40 + 30 below its octile 192.
    var heuristic = CrossLevelHeuristic.init(graph, 0, @intCast(pocket_goal.x), @intCast(pocket_goal.y), null, 0);
    try std.testing.expectEqual(@as(u32, 70), heuristicAt(&heuristic, 0, 16, 17));
    try std.testing.expect(searchAbstract(graph, &abstract, grid, grid, 0, 0, start, goal, 4096) == .found);
    // The near gap: g 84 + octile 140, against g 74 + octile 192 through the far one.
    try std.testing.expectEqual(grid.indexForCell(.{ .x = 16, .y = 30 }).?, refLocal(abstract.corridor.items[abstract.corridor.items.len - 1]));
    try std.testing.expectEqual(@as(u32, 224), foundObjective(&abstract, graph.geometry.width, goal));
    try std.testing.expectEqual(@as(?u32, 224), try exhaustiveAbstractObjective(allocator, graph, grid, grid, 0, 0, start, goal));
}

test "a long link landing next to the goal from an unreachable level leaves abstract nodes flat at 6, 18, and 64 levels" {
    const allocator = std.testing.allocator;
    const DataSystem = @import("../../data_system.zig").DataSystem;
    var meta = try test_support.loadTestWorldMeta(allocator);
    defer meta.deinit();
    const grass = try test_support.requireTestTile(&meta, "grass");
    var nodes: [3]usize = undefined;
    var corridors: [3][]usize = undefined;
    var corridor_count: usize = 0;
    defer for (corridors[0..corridor_count]) |corridor| allocator.free(corridor);
    for ([_]u16{ 6, 18, 64 }, &nodes, &corridors) |levels, *level_nodes, *level_corridor| {
        var objectives: [2]u32 = undefined;
        for ([_]bool{ true, false }, &objectives) |teleport, *objective| {
            var data = DataSystem.init(allocator);
            defer data.deinit();
            // Open 16x16 levels in 4-tile chunks. A ramp shaft at (1, 1) joins levels 1 and
            // deeper; level 0, which no ramp reaches, holds a free one-way teleport from the
            // shaft's planar cell to beside the level-4 goal.
            var world = try test_support.abstractTestWorld(&meta, 512, 512);
            defer world.deinit();
            for (1..levels) |level| {
                _ = try world.addLevel(-16 * @as(i32, @intCast(level)));
                _ = try world.addDenseLayer(@intCast(level), 0, .floor, grass);
                if (level >= 2) try world.addLevelLink(.{ .kind = .ramp, .level_a = @intCast(level - 1), .cell_a = .{ .x = 1, .y = 1 }, .level_b = @intCast(level), .cell_b = .{ .x = 1, .y = 1 }, .traversal_cost = 1, .bidirectional = true });
            }
            if (teleport) try world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 1, .y = 1 }, .level_b = 4, .cell_b = .{ .x = 13, .y = 14 }, .traversal_cost = 0, .bidirectional = false });
            var system = PathfindingSystem.init(allocator);
            defer system.deinit();
            var capacity = test_support.abstractCapacity();
            capacity.group_field_max_cells = 16;
            try system.reserve(capacity);
            try system.rebuildStaticNavGridWithWorld(&data, &world, null);
            const graph = &system.graph;
            var abstract = AbstractScratch{};
            defer abstract.deinit(allocator);
            try abstract.reserve(allocator, 4096);
            const start_grid = graph.grid(1).?;
            const goal_grid = graph.grid(4).?;
            const start = start_grid.indexForCell(.{ .x = 0, .y = 0 }).?;
            const goal = goal_grid.indexForCell(.{ .x = 14, .y = 14 }).?;
            try std.testing.expect(searchAbstract(graph, &abstract, start_grid, goal_grid, 1, 4, start, goal, 4096) == .found);
            objective.* = foundObjective(&abstract, graph.geometry.width, goal);
            try std.testing.expectEqual(@as(?u32, objective.*), try exhaustiveAbstractObjective(allocator, graph, start_grid, goal_grid, 1, 4, start, goal));
            if (!teleport) continue;
            level_nodes.* = abstract.nodes_used;
            level_corridor.* = try allocator.dupe(usize, abstract.corridor.items);
            corridor_count += 1;
        }
        try std.testing.expectEqual(objectives[1], objectives[0]);
    }
    try std.testing.expectEqual(nodes[0], nodes[1]);
    try std.testing.expectEqual(nodes[0], nodes[2]);
    try std.testing.expectEqualSlices(usize, corridors[0], corridors[1]);
    try std.testing.expectEqualSlices(usize, corridors[0], corridors[2]);
}

test "a long link's estimate pairs its entrance with its own exit and chains through another link only at their real distance" {
    const allocator = std.testing.allocator;
    const DataSystem = @import("../../data_system.zig").DataSystem;
    var meta = try test_support.loadTestWorldMeta(allocator);
    defer meta.deinit();
    const grass = try test_support.requireTestTile(&meta, "grass");
    var data = DataSystem.init(allocator);
    defer data.deinit();
    // Open 64x64 levels 0-2 in 4-tile chunks; ramps (cost 41, one level) at (62, 62) set the
    // crossing rates to 41 per level. One-way teleports of cost 41: A from L0 (2, 32) to
    // L2 (60, 32), B from L2 (60, 2) to L0 (40, 60); the goal is L0 (40, 62).
    var world = try test_support.abstractTestWorld(&meta, 2048, 2048);
    defer world.deinit();
    for (1..3) |level| {
        _ = try world.addLevel(-16 * @as(i32, @intCast(level)));
        _ = try world.addDenseLayer(@intCast(level), 0, .floor, grass);
        try world.addLevelLink(.{ .kind = .ramp, .level_a = @intCast(level - 1), .cell_a = .{ .x = 62, .y = 62 }, .level_b = @intCast(level), .cell_b = .{ .x = 62, .y = 62 }, .traversal_cost = 1, .bidirectional = true });
    }
    try world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 2, .y = 32 }, .level_b = 2, .cell_b = .{ .x = 60, .y = 32 }, .traversal_cost = 1, .bidirectional = false });
    try world.addLevelLink(.{ .kind = .teleport, .level_a = 2, .cell_a = .{ .x = 60, .y = 2 }, .level_b = 0, .cell_b = .{ .x = 40, .y = 60 }, .traversal_cost = 1, .bidirectional = false });
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    var capacity = test_support.abstractCapacity();
    capacity.group_field_max_cells = 16;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const graph = &system.graph;
    // At A's entrance: A (41), L2 (60, 32) -> (60, 2) (300), B (41), L0 (40, 60) -> goal (20).
    // Short-only it is octile 500; A then the short climb from L2 is 41 + 380 + 2 * 41 + 41 =
    // 503 against no chain; independent summaries pair A's entrance with B's exit at 41 + 20.
    var heuristic = CrossLevelHeuristic.init(graph, 0, 40, 62, null, 0);
    try std.testing.expectEqual(@as(u32, 402), heuristicAt(&heuristic, 0, 2, 32));
    const grid = graph.grid(0).?;
    const start = grid.indexForCell(.{ .x = 2, .y = 32 }).?;
    const goal = grid.indexForCell(.{ .x = 40, .y = 62 }).?;
    var abstract = AbstractScratch{};
    defer abstract.deinit(allocator);
    try abstract.reserve(allocator, 4096);
    try std.testing.expect(searchAbstract(graph, &abstract, grid, grid, 0, 0, start, goal, 4096) == .found);
    try std.testing.expectEqual(try exhaustiveAbstractObjective(allocator, graph, grid, grid, 0, 0, start, goal), foundObjective(&abstract, graph.geometry.width, goal));
    try std.testing.expect(std.mem.indexOfScalar(bool, abstract.corridor_link.items, true) != null);
}

// Band geometry for the mirrored-teleport test: 64x64 levels, a 4-cell border band.
const band_side: u16 = 64;
const band_width: u16 = 4;

fn inBand(x: u32, y: u32) bool {
    return x < band_width or y < band_width or x >= band_side - band_width or y >= band_side - band_width;
}

// `count` bidirectional teleports from level-0 band cells, spread evenly in row-major order,
// each to its point mirror on `deepest`.
fn addBandTeleports(world: *WorldSystem, deepest: u16, count: usize) !void {
    const inner = band_side - 2 * band_width;
    const band_cells = @as(usize, band_side) * band_side - @as(usize, inner) * inner;
    var band_index: usize = 0;
    var added: usize = 0;
    for (0..band_side) |y| {
        for (0..band_side) |x| {
            if (!inBand(@intCast(x), @intCast(y))) continue;
            defer band_index += 1;
            if (added == count or band_index != added * band_cells / count) continue;
            try world.addLevelLink(.{
                .kind = .teleport,
                .level_a = 0,
                .cell_a = .{ .x = @intCast(x), .y = @intCast(y) },
                .level_b = deepest,
                .cell_b = .{ .x = @intCast(band_side - 1 - x), .y = @intCast(band_side - 1 - y) },
                .traversal_cost = 1,
                .bidirectional = true,
            });
            added += 1;
        }
    }
    std.debug.assert(added == count);
}

test "mirrored band teleports leave no level-0 band node closed and the objective exact at 1 and band-fill teleports" {
    const allocator = std.testing.allocator;
    const DataSystem = @import("../../data_system.zig").DataSystem;
    var meta = try test_support.loadTestWorldMeta(allocator);
    defer meta.deinit();
    const grass = try test_support.requireTestTile(&meta, "grass");
    const levels: u16 = 8;
    const inner = band_side - 2 * band_width;
    const band_cells = @as(usize, band_side) * band_side - @as(usize, inner) * inner;
    for ([_]usize{ 1, band_cells }) |teleports| {
        var data = DataSystem.init(allocator);
        defer data.deinit();
        // Open levels in 4-tile chunks; ramps alternate 10 cells east and west of the center,
        // so a route from level 0 to level 2 zig-zags between the band's level-0 nodes.
        var world = try test_support.abstractTestWorld(&meta, 2048, 2048);
        defer world.deinit();
        const center = band_side / 2;
        for (1..levels) |level| {
            const upper: u16 = @intCast(level - 1);
            _ = try world.addLevel(-16 * @as(i32, @intCast(level)));
            _ = try world.addDenseLayer(@intCast(level), 0, .floor, grass);
            const cell = @import("../../world_system.zig").CellCoord{ .x = if (upper % 2 == 0) center + 10 else center - 10, .y = center };
            try world.addLevelLink(.{ .kind = .ramp, .level_a = upper, .cell_a = cell, .level_b = upper + 1, .cell_b = cell, .traversal_cost = 1, .bidirectional = true });
        }
        try addBandTeleports(&world, levels - 1, teleports);
        var system = PathfindingSystem.init(allocator);
        defer system.deinit();
        var capacity = test_support.abstractCapacity();
        capacity.group_field_max_cells = 16;
        try system.reserve(capacity);
        try system.rebuildStaticNavGridWithWorld(&data, &world, null);
        const graph = &system.graph;
        var abstract = AbstractScratch{};
        defer abstract.deinit(allocator);
        try abstract.reserve(allocator, 4096);
        const start_grid = graph.grid(0).?;
        const goal_grid = graph.grid(2).?;
        const start = start_grid.indexForCell(.{ .x = center, .y = center - 8 }).?;
        const goal = goal_grid.indexForCell(.{ .x = center, .y = center + 8 }).?;
        try std.testing.expect(searchAbstract(graph, &abstract, start_grid, goal_grid, 0, 2, start, goal, 4096) == .found);
        try std.testing.expectEqual(try exhaustiveAbstractObjective(allocator, graph, start_grid, goal_grid, 0, 2, start, goal), foundObjective(&abstract, graph.geometry.width, goal));
        var band_closed: usize = 0;
        for (abstract.slots) |slot| {
            // This search's claimed nodes carry its generation.
            if (slot.stamp >> 1 != abstract.generation or slot.stamp & 1 == 0 or refLevel(slot.node) != 0) continue;
            band_closed += @intFromBool(inBand(slot.x, slot.y));
        }
        try std.testing.expectEqual(@as(usize, 0), band_closed);
    }
}

test "same-level abstract searches in worlds without long links equal the goal-level octile search" {
    const allocator = std.testing.allocator;
    const DataSystem = @import("../../data_system.zig").DataSystem;
    var meta = try test_support.loadTestWorldMeta(allocator);
    defer meta.deinit();
    var found: usize = 0;
    for (0..6) |seed| {
        var prng = std.Random.DefaultPrng.init(0x6e65_0000 + seed);
        const random = prng.random();
        var data = DataSystem.init(allocator);
        defer data.deinit();
        var world = try heuristicTestWorld(&meta, random, 1);
        defer world.deinit();
        // Same-level short links: each cost covers its planar span.
        for (0..4) |_| {
            const cell = randomCell(random, 0, 14);
            try world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = cell, .level_b = 0, .cell_b = .{ .x = cell.x + 2, .y = cell.y }, .traversal_cost = 0, .bidirectional = random.boolean() });
        }
        var system = PathfindingSystem.init(allocator);
        defer system.deinit();
        var capacity = test_support.abstractCapacity();
        capacity.group_field_max_cells = 16;
        try system.reserve(capacity);
        try system.rebuildStaticNavGridWithWorld(&data, &world, null);
        const graph = &system.graph;
        try std.testing.expect(std.meta.eql(graph.link_bounds, LinkBounds{}));
        var abstract = AbstractScratch{};
        defer abstract.deinit(allocator);
        try abstract.reserve(allocator, 4096);
        const grid = graph.grid(0).?;
        for (0..24) |_| {
            const start = random.uintLessThan(usize, 256);
            const goal = random.uintLessThan(usize, 256);
            if (grid.isBlockedIndex(start) or grid.isBlockedIndex(goal)) continue;
            var reference = ReferenceAbstract{
                .nodes = std.AutoHashMap(usize, ReferenceAbstract.Node).init(allocator),
                .budget = 4096,
                .open_limit = abstract.open_limit,
                .corridor_limit = abstract.corridor_limit,
                .estimate = .goal_level_octile,
            };
            defer reference.deinit();
            const expected = try reference.search(graph, grid, grid, 0, 0, start, goal);
            const result = searchAbstract(graph, &abstract, grid, grid, 0, 0, start, goal, 4096);
            try std.testing.expectEqualDeep(expected, result);
            try std.testing.expectEqual(reference.nodes.count(), abstract.nodes_used);
            if (result != .found) continue;
            try std.testing.expectEqualSlices(usize, reference.corridor.items, abstract.corridor.items);
            try std.testing.expectEqualSlices(bool, reference.corridor_link.items, abstract.corridor_link.items);
            found += 1;
        }
    }
    try std.testing.expect(found > 20);
}

// Run starts and keys by one division per cell: a new run wherever the level or chunk
// differs from the previous cell's.
fn referenceRuns(geometry: ChunkGeometry, cells: []const u32, levels: ?[]const u16, path_level: u16, starts: *std.ArrayList(u16), keys: *std.ArrayList(u64)) !void {
    starts.clearRetainingCapacity();
    keys.clearRetainingCapacity();
    for (cells, 0..) |cell, index| {
        const run_key = chunkKey(if (levels) |column| column[index] else path_level, geometry.chunkOfCell(cell));
        if (index != 0 and keys.items[keys.items.len - 1] == run_key) continue;
        try starts.append(std.testing.allocator, @intCast(index));
        try keys.append(std.testing.allocator, run_key);
    }
}

// Splits `stitched` (or a plain path when every level is `path_level`) and checks the
// starts and shard counts against `referenceRuns`.
fn expectRunsMatchReference(geometry: ChunkGeometry, stitched: []const StitchedCell, plain: bool) !void {
    var words: [64]u32 = undefined;
    var cells: [32]u32 = undefined;
    for (stitched, cells[0..stitched.len]) |cell, *plain_cell| plain_cell.* = cell.cell;
    types.writeStitched(&words, stitched);
    const view = types.stitchedView(&words, stitched.len);
    const levels: ?[]const u16 = if (plain) null else view.levels;
    var starts: [32]u16 = undefined;
    var counts: [registry_shard_count]u32 = @splat(0);
    const run_count = splitRuns(geometry, cells[0..stitched.len], levels, stitched[0].level, &starts, &counts);
    var expected_starts: std.ArrayList(u16) = .empty;
    defer expected_starts.deinit(std.testing.allocator);
    var expected_keys: std.ArrayList(u64) = .empty;
    defer expected_keys.deinit(std.testing.allocator);
    try referenceRuns(geometry, cells[0..stitched.len], levels, stitched[0].level, &expected_starts, &expected_keys);
    try std.testing.expectEqualSlices(u16, expected_starts.items, starts[0..run_count]);
    var expected_counts: [registry_shard_count]u32 = @splat(0);
    for (expected_keys.items) |key| expected_counts[registryShard(key)] += 1;
    try std.testing.expectEqualSlices(u32, &expected_counts, &counts);
}

// 20 x 12 cells in 4-cell chunks: five chunks per row.
const test_run_geometry = ChunkGeometry.init(20, 12, 4);

fn testCell(x: u32, y: u32) u32 {
    return y * 20 + x;
}

test "registrations built on the worker equal a reference run split (plain; stitched across a level change; re-entering a chunk; single cell; non-adjacent step)" {
    var path: [32]StitchedCell = undefined;
    // Plain: a diagonal then a straight line across chunk corners and edges, ending at the
    // grid's right edge (an index step of +1 that must not wrap a row).
    var len: usize = 0;
    for (0..6) |step| {
        path[len] = .{ .level = 2, .cell = testCell(@intCast(1 + step), @intCast(1 + step)) };
        len += 1;
    }
    for (7..20) |x| {
        path[len] = .{ .level = 2, .cell = testCell(@intCast(x), 6) };
        len += 1;
    }
    try expectRunsMatchReference(test_run_geometry, path[0..len], true);
    try expectRunsMatchReference(test_run_geometry, path[0..len], false);
    // Stitched across a level change at the same cell, then back.
    len = 0;
    for ([_][3]u32{ .{ 0, 2, 2 }, .{ 0, 3, 2 }, .{ 0, 4, 2 }, .{ 1, 4, 2 }, .{ 1, 5, 2 }, .{ 0, 5, 2 }, .{ 0, 6, 3 } }) |step| {
        path[len] = .{ .level = @intCast(step[0]), .cell = testCell(step[1], step[2]) };
        len += 1;
    }
    try expectRunsMatchReference(test_run_geometry, path[0..len], false);
    // Leaving chunk (0, 0) and re-entering it: two runs of the same key.
    len = 0;
    for ([_][2]u32{ .{ 2, 1 }, .{ 3, 1 }, .{ 4, 1 }, .{ 4, 2 }, .{ 3, 2 }, .{ 2, 2 } }) |step| {
        path[len] = .{ .level = 0, .cell = testCell(step[0], step[1]) };
        len += 1;
    }
    try expectRunsMatchReference(test_run_geometry, path[0..len], true);
    var starts: [8]u16 = undefined;
    var counts: [registry_shard_count]u32 = @splat(0);
    var cells: [6]u32 = undefined;
    for (path[0..len], &cells) |cell, *plain_cell| plain_cell.* = cell.cell;
    try std.testing.expectEqual(@as(u32, 3), splitRuns(test_run_geometry, &cells, null, 0, &starts, &counts));
    // A single cell.
    try expectRunsMatchReference(test_run_geometry, &.{.{ .level = 1, .cell = testCell(19, 11) }}, false);
    // A same-level teleport: a jump to a far cell, then neighbouring steps from it.
    len = 0;
    for ([_][2]u32{ .{ 1, 1 }, .{ 2, 1 }, .{ 17, 9 }, .{ 18, 10 }, .{ 19, 11 }, .{ 0, 0 }, .{ 1, 0 } }) |step| {
        path[len] = .{ .level = 0, .cell = testCell(step[0], step[1]) };
        len += 1;
    }
    try expectRunsMatchReference(test_run_geometry, path[0..len], true);
}

test "per-ordinal shard counts equal the shard counts of the reference run keys" {
    // Every chunk of a 4-level grid visited in a snake, so runs spread over the shards.
    var prng = std.Random.DefaultPrng.init(0x5a4d);
    const random = prng.random();
    var path: [32]StitchedCell = undefined;
    for (0..20) |_| {
        var x: u32 = random.uintLessThan(u32, 20);
        var y: u32 = random.uintLessThan(u32, 12);
        var level: u16 = random.uintLessThan(u16, 4);
        for (&path) |*cell| {
            cell.* = .{ .level = level, .cell = testCell(x, y) };
            switch (random.uintLessThan(u8, 6)) {
                0 => x = @min(x + 1, 19),
                1 => x -|= 1,
                2 => y = @min(y + 1, 11),
                3 => y -|= 1,
                4 => level = random.uintLessThan(u16, 4),
                else => {
                    x = random.uintLessThan(u32, 20);
                    y = random.uintLessThan(u32, 12);
                },
            }
        }
        try expectRunsMatchReference(test_run_geometry, &path, false);
    }
}
