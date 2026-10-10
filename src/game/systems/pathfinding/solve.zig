// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Per-request solvers: the budget-bounded local A*, the abstract chunk-record
//! corridor search, the corridor stitcher, and the worker job entry point. These
//! free functions borrow *PathfindingSystem plus per-worker scratch and read the
//! NavGraph's grids and chunk records; they stay free functions to keep that wiring flat.

const std = @import("std");
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const PathfindingSystem = @import("system.zig").PathfindingSystem;
const NavGrid = @import("nav_grid.zig").NavGrid;
const allowed_moves = @import("nav_grid.zig").allowed_moves;
const NavGraph = @import("nav_graph.zig").NavGraph;
const NavPortal = @import("nav_graph.zig").NavPortal;
const AbstractScratch = @import("scratch.zig").AbstractScratch;
const AbstractSlot = @import("scratch.zig").AbstractSlot;
const CorridorScratch = @import("scratch.zig").CorridorScratch;
const SearchScratch = @import("scratch.zig").SearchScratch;
const types = @import("types.zig");
const PathSolveResult = types.PathSolveResult;
const PendingRequest = types.PendingRequest;
const PathQueryKey = types.PathQueryKey;
const StitchedCell = types.StitchedCell;
const OpenNode = types.OpenNode;
const no_parent = types.no_parent;
const no_slot = types.no_slot;
const no_component = types.no_component;
const diagonal_cost = types.diagonal_cost;
const cardinal_cost = types.cardinal_cost;
const packRef = types.packRef;
const refLevel = types.refLevel;
const refLocal = types.refLocal;
const octileXY = types.octileXY;
const octileU32 = types.octileU32;
const siftUp = types.siftUp;
const popHeap = types.popHeap;
const neighbor_dirs = types.neighbor_dirs;

pub const SolveJobContext = struct {
    system: *PathfindingSystem,
    /// Dispatched range count from the pre-select that sized this batch; dual-asserted
    /// against `range.index` at job entry (mirror affect.zig / collision.zig).
    range_count: usize,
};

// Fallback workers share the system for read-only graph/pending access but use
// worker-indexed scratch. Every output (result, solved path, path stripe) sits at the
// request's fallback ordinal, so a range writes only its own `[start, end)` window; a
// tier-1 solve also writes the tier-1 pool entry of its escalated admission index, which
// no other ordinal of the step holds.
pub fn solveFallbackJob(context: *anyopaque, range: ParallelRange, worker_id: WorkerId) void {
    const job: *SolveJobContext = @ptrCast(@alignCast(context));
    const system = job.system;
    // Dual worker asserts: range.index vs dispatched range count AND range.end vs
    // the fallback-index buffer this job walks and the ordinal windows it writes.
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= system.fallback_indices.items.len);
    std.debug.assert(range.end <= system.solve_results.items.len);
    std.debug.assert(range.end <= system.solved_paths.items.len);
    std.debug.assert(range.end <= system.fallback_tier1_slot.items.len);
    // scratch_slots is never resized during the parallel region (only in applyDerivedCapacity,
    // which runs in beginUpdate before parallelForWithOptions), so this pointer stays valid.
    // Guards the reserve-before-dispatch invariant: applyDerivedCapacity sized scratch_slots to
    // the participant count the caller asserted against before dispatching this batch.
    std.debug.assert(worker_id.index < system.scratch_slots.items.len);
    const scratch = &system.scratch_slots.items[worker_id.index];
    for (range.start..range.end) |ordinal| {
        const pending_index = system.fallback_indices.items[ordinal];
        system.solve_results.items[ordinal] = solveOne(system, pending_index, scratch, ordinal);
    }
}

// Outcome of a budget-bounded local A* over one level's grid.
const LocalSolve = enum { found, budget_exhausted, none };

// Solves one request. Short same-component hops use the budget-bounded local A*
// directly and store a plain path (no stitched corridor). Long-range or cross-level
// queries route through the abstract chunk-portal/link graph to pick a corridor, then
// stitch the full obstacle-aware (level,cell) path from per-segment local A* runs;
// the query walks it per-agent on its current level. Per-solve work is bounded by the
// abstract node budget, plus at most max_stitch_segments per-segment local searches
// (see default_max_stitch_segments) — not just one, since a corridor can cross many
// portals — each capped at the per-segment local budget, independent of total cells.
/// Solves logical pending entry `pending_index`, writing its solved path at `ordinal`
/// (its fallback ordinal: result slot, solved-path slot, and path stripe).
pub fn solveOne(system: *PathfindingSystem, pending_index: usize, scratch: *SearchScratch, ordinal: usize) PathSolveResult {
    const graph = &system.graph;
    const request = system.pending.at(pending_index);
    if (!graph.valid()) return .{ .unavailable = request.key };
    // Every local search of this solve clamps to the committed node budget, as the
    // abstract and stitched searches clamp theirs: a plain path then fits its stripe, and
    // every participant spills at the same count even when a failed re-reserve left
    // scratch tables at different limits.
    scratch.explored_budget = @min(system.capacity.max_explored_nodes, scratch.explored_limit);

    // Start-side failures are start_invalid, never unavailable: the negative cache is
    // goal-keyed and shared, so a blocked/off-grid representative start (e.g. an agent
    // momentarily overlapping a body) must not mark the goal unavailable for everyone.
    const start_grid = graph.grid(request.start_level) orelse return .{ .start_invalid = request.key };
    const goal_grid = graph.grid(request.key.goal_level) orelse return .{ .unavailable = request.key };
    const start_index = start_grid.indexForCell(request.start) orelse return .{ .start_invalid = request.key };
    if (start_grid.isBlockedIndex(start_index)) return .{ .start_invalid = request.key };

    // Projection (including failure) was resolved at acceptance against the goal
    // level. no_parent means no open cell near the goal: a definitive negative.
    if (request.goal_index == no_parent) return .{ .unavailable = request.key };
    const goal_index = request.goal_index;

    const same_level = request.start_level == request.key.goal_level;
    if (same_level) {
        if (start_index == goal_index) {
            recordPath(system, ordinal, request.key, &.{@intCast(goal_index)}, request.start_level);
            return .{ .available = request.key };
        }
        // Same component: a short hop the local A* can usually finish.
        if (start_grid.connected(start_index, goal_index)) {
            switch (localAStar(start_grid, scratch, start_index, goal_index)) {
                .found => {
                    recordPath(system, ordinal, request.key, scratch.path_scratch.items, request.start_level);
                    return .{ .available = request.key };
                },
                // Budget spill on a short same-component hop is a transient: keep
                // it pending so a later frame retries rather than mislabeling it.
                .budget_exhausted => return .{ .budget_exhausted = request.key },
                .none => return .{ .unavailable = request.key },
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

// The tier-1 pool entry `prepareSolvePhase` assigned to the escalated solve at `ordinal`.
fn tier1Corridor(system: *PathfindingSystem, ordinal: usize) *CorridorScratch {
    const tier1_slot = system.fallback_tier1_slot.items[ordinal];
    std.debug.assert(tier1_slot < system.tier1_scratch.items.len);
    return &system.tier1_scratch.items[tier1_slot].corridor;
}

// Abstract A* over portal nodes + link edges to choose a corridor across
// chunks/levels, then stitches the FULL obstacle-aware path: per-segment local A*
// between consecutive corridor portals (and start->first portal, last portal->goal)
// concatenated into one grid-adjacent (level,cell) path, with a discrete jump only
// across an inter-level link. The query walks that path per-agent on its current
// level, so every heading is to a traversable neighbor. Saturating the abstract
// scratch or a segment's node budget spills to a later frame (budget_exhausted)
// rather than mislabeling it; only a genuinely missing corridor is unavailable.
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
    const corridor = switch (abstractCorridor(graph, &corridor_scratch.abstract, start_grid, goal_grid, request.start_level, request.key.goal_level, start_index, goal_index, abstract_node_cap)) {
        .found => |c| c,
        // Abstract scratch saturated: retry next frame instead of a hard negative.
        .saturated => return .{ .budget_exhausted = request.key },
        .none => return .{ .unavailable = request.key },
        // Start-side seeding failure: drop without poisoning the goal-keyed negative cache.
        .unseedable => return .{ .start_invalid = request.key },
    };

    // Stitch the full obstacle-aware path across every corridor segment. A node-budget
    // spill, a stitched-buffer overflow, or a segment-count spill (see
    // default_max_stitch_segments) is a transient: retry next frame.
    switch (stitchCorridor(system, scratch, corridor_scratch, request, goal_grid, start_index, goal_index, stitched_cell_cap, segment_cap)) {
        .found => {},
        .budget_exhausted => return .{ .budget_exhausted = request.key },
        .none => return .{ .unavailable = request.key },
    }

    const stitched = corridor_scratch.stitched.items;
    if (stitched.len == 0) return .{ .unavailable = request.key };
    recordStitched(system, ordinal, request.key, stitched, request.start_level);
    const solved = &system.solved_paths.items[ordinal];
    solved.via_abstract = true;
    solved.cross_level = corridor.crosses_level;
    return .{ .available = request.key };
}

// Stitches the chosen abstract corridor (corridor_scratch.abstract.corridor, ordered portal
// (level, cell) refs root->goal) into corridor_scratch.stitched as one (level,cell) path;
// local A* segments run in the participant's `scratch`.
// A NON-link transition (corridor_link[i] == false) is walked with local A* between
// consecutive portal cells; a LINK transition (corridor_link[i] == true) is a single
// discrete jump (no intermediate cells), whether it crosses Z or is a same-level
// teleport. The final span (last portal -> goal) is a same-level local A*. Returns
// budget_exhausted on any segment node-budget spill, stitched-buffer overflow, or
// segment-count spill (segment_cap, see default_max_stitch_segments — bounds total
// local-search work independent of how many portals the chosen corridor crosses).
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
) LocalSolve {
    const graph = &system.graph;
    const stitched = &corridor_scratch.stitched;
    const abstract = &corridor_scratch.abstract;
    stitched.clearRetainingCapacity();
    const cap = @min(cap_requested, corridor_scratch.stitched_limit);
    if (cap == 0) return .budget_exhausted;
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
            if (stitched.items.len >= cap) return .budget_exhausted;
            stitched.appendAssumeCapacity(.{ .level = portal.level, .cell = portal.cell });
        } else {
            // prev_level indexes a live level by construction (it came from the corridor
            // we just built); spill rather than panic if a malformed graph ever violates that.
            const grid = graph.grid(prev_level) orelse return .none;
            // appendSegment no-ops (no localAStar call) when prev_cell already equals the
            // portal cell, so only a genuine local search counts against segment_cap.
            if (prev_cell != portal.cell) {
                if (segments_used >= segment_cap) return .budget_exhausted;
                segments_used += 1;
                if (segments_used > scratch.max_stitch_segments_used) scratch.max_stitch_segments_used = segments_used;
            }
            switch (appendSegment(scratch, stitched, grid, prev_level, prev_cell, portal.cell, cap)) {
                .found => {},
                else => |r| return r,
            }
        }
        prev_level = portal.level;
        prev_cell = portal.cell;
    }
    // Final span: last corridor cell -> goal cell, a walkable same-level segment.
    // abstractCorridor only returns .found after buildCorridor validates the corridor ends
    // on goal_level, so prev_level == goal_level here. Dead-code defensive guard.
    if (prev_level != request.key.goal_level) return .none;
    if (prev_cell != goal_index) {
        if (segments_used >= segment_cap) return .budget_exhausted;
        segments_used += 1;
        if (segments_used > scratch.max_stitch_segments_used) scratch.max_stitch_segments_used = segments_used;
    }
    switch (appendSegment(scratch, stitched, goal_grid, prev_level, prev_cell, @intCast(goal_index), cap)) {
        .found => {},
        else => |r| return r,
    }
    return .found;
}

// Runs local A* from `from` to `to` on `grid` and appends the resulting cells
// (skipping the first, already present as the previous segment's tail) to the
// stitched buffer, tagged with `level`. Returns the local A* outcome, or
// budget_exhausted if appending would overflow the stitched cap.
fn appendSegment(scratch: *SearchScratch, stitched: *std.ArrayList(StitchedCell), grid: *const NavGrid, level: u16, from: usize, to: usize, cap: usize) LocalSolve {
    if (from == to) return .found;
    switch (localAStar(grid, scratch, from, to)) {
        .found => {},
        .budget_exhausted => return .budget_exhausted,
        .none => return .none,
    }
    // path_scratch is start->goal for this segment; its first cell equals `from`,
    // already the tail of the stitched buffer, so skip it.
    const seg = scratch.path_scratch.items;
    if (seg.len <= 1) return .found;
    for (seg[1..]) |cell| {
        if (stitched.items.len >= cap) return .budget_exhausted;
        stitched.appendAssumeCapacity(.{ .level = level, .cell = cell });
    }
    return .found;
}

const AbstractCorridor = struct {
    // Whether the chosen corridor crosses at least one inter-level link.
    crosses_level: bool,
};

const AbstractResult = union(enum) {
    found: AbstractCorridor,
    // The bounded abstract scratch saturated (open/slot table full); the corridor
    // may exist but could not be searched this frame.
    saturated,
    // No corridor reaches the goal level/cell from the start.
    none,
    // The representative start carries no component label (a blocked/degenerate
    // cell): a start-side condition, not a goal negative.
    unseedable,
};

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
// whether the relaxing edge was a cross-level link. Returns false on saturation (the node
// budget or the open heap is full).
fn relaxAbstractNode(
    abstract: *AbstractScratch,
    parent_slot: u32,
    parent_g: u32,
    node: AbstractNode,
    cost: u32,
    via_link: bool,
    h: u32,
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
    abstract.open.appendAssumeCapacity(.{ .index = node.ref, .f = candidate +| h, .h = h });
    siftUp(abstract.open.items, abstract.open.items.len - 1);
    return true;
}

// Runs abstract A* over chunk records. A node is a portal cell, packed as (level << 32) | cell.
// Expanding a node relaxes the other portals of its chunk with its label (octile cost), the
// mirror cell across each border it sits on (one cardinal step), and every link leaving it
// whose target cell is open. On success it writes the ordered corridor of refs (root
// start-level portal -> goal-level portal) into abstract.corridor for the stitcher to
// refine, and reports whether the corridor crosses a level. Per-query work is bounded by
// the abstract node budget; seeding scans only the start chunk's record. A node's
// coordinates are cached at claim, and its portal when the claiming expansion held it, so a
// pop derives its chunk by shifts and looks a portal up only for a mirror or link target.
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
) AbstractResult {
    abstract.reset();
    // Per-query attempt-scoped cap (tier-0 stays small; tier-1 uses the fixed ceiling),
    // clamped to the table's reserved limit.
    abstract.node_budget = @min(node_cap, abstract.node_limit);
    const slots = abstract.slots;

    // Chunk geometry once per query: `validateChunkGrid` keeps the chunk edge a power of
    // two, so a cell's chunk and chunk-local index are shifts and masks of its coordinates.
    const width: u32 = @intCast(graph.width);
    const shift: u5 = @intCast(@ctz(graph.chunk_tiles));
    const mask: u32 = @as(u32, graph.chunk_tiles) - 1;
    std.debug.assert(std.math.isPowerOfTwo(graph.chunk_tiles));
    const chunks_x: u32 = (width + mask) >> shift;
    // Coordinates and indices stay unsigned: a validated level's cell index can pass 2^31.
    const goal: u32 = @intCast(goal_index);
    const goal_y = goal / width;
    const goal_x = goal - goal_y * width;

    // Seed the open set with the start chunk's portals sharing the start cell's label,
    // costed by octile distance from the start.
    const start_label = start_grid.labelAt(start_index);
    if (start_label == 0) return .unseedable;
    const start_cell: u32 = @intCast(start_index);
    const start_y = start_cell / width;
    const start_x = start_cell - start_y * width;
    const start_portals = graph.chunkPortals(start_level, (start_y >> shift) * chunks_x + (start_x >> shift));
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
            // Only the goal level has a cell coordinate comparable to the goal; off-level seed
            // portals use h=0 to keep the heuristic admissible (matches the relax paths below).
            const h = if (start_level == goal_level) octileU32(px, py, goal_x, goal_y) else 0;
            abstract.open.appendAssumeCapacity(.{ .index = ref, .f = g +| h, .h = h });
            siftUp(abstract.open.items, abstract.open.items.len - 1);
            seeded += 1;
        }
    }
    // A labeled component with zero portals is structurally sealed off from every
    // other chunk: a definitive negative (the disconnected-goal contract), not a
    // transient start condition.
    if (seeded == 0) return .none;

    const goal_label = goal_grid.labelAt(goal_index);
    const goal_chunk = (goal_y >> shift) * chunks_x + (goal_x >> shift);

    while (abstract.open.items.len != 0) {
        const current = popHeap(&abstract.open);
        const current_ref = current.index;
        const current_slot = (abstract.slotFor(current_ref) orelse return .saturated).slot;
        const current_node = &slots[current_slot];
        if (current_node.stamp & 1 != 0) continue;
        // Lazy deletion: skip a superseded duplicate left in the heap by an earlier
        // g-improvement (f-h recovers its g; strict-greater never drops the best entry).
        if (current.f -% current.h > current_node.g) continue;
        current_node.stamp |= 1;

        const level = refLevel(current_ref);
        const cell = refLocal(current_ref);
        const x = current_node.x;
        const y = current_node.y;
        const chunk = (y >> shift) * chunks_x + (x >> shift);
        const local: u8 = @intCast(((y & mask) << shift) | (x & mask));
        // The record's slices: the peer scan and the link lookup read them.
        const portals = graph.chunkPortals(level, chunk);
        // Every relaxed node is a portal of its chunk's record (mirror runs are symmetric and
        // an open link endpoint is a portal); a miss is a dead end.
        const portal: NavPortal = if (current_node.flags.portal_known)
            .{ .local = local, .label = current_node.portal_label, .flags = current_node.portal_flags }
        else
            portals.find(local) orelse continue;
        // Goal reached: this portal is on the goal level and shares the goal's chunk-local
        // component, so the local refiner can finish from here.
        if (level == goal_level and goal_label != 0 and chunk == goal_chunk and portal.label == goal_label) {
            switch (buildCorridor(abstract, current_slot, start_level)) {
                .ok => {},
                // Budget-truncated reconstruction: spill+retry, never a hard negative.
                .truncated => return .saturated,
                .none => return .none,
            }
            return .{ .found = .{ .crosses_level = start_level != goal_level } };
        }

        const current_g = current_node.g;
        const on_goal_level = level == goal_level;
        const origin_x = x & ~mask;
        const origin_y = y & ~mask;
        const local_mask: u8 = @intCast(mask);
        const local_x: u8 = local & local_mask;
        const local_y: u8 = local >> @intCast(shift);
        // Same-label portals of the chunk. Off the goal level h=0 keeps the estimate admissible.
        for ([_][]const NavPortal{ portals.border, portals.extra }) |peers| {
            for (peers) |peer| {
                if (peer.local == local or peer.label != portal.label) continue;
                const peer_x: u8 = peer.local & local_mask;
                const peer_y: u8 = peer.local >> @intCast(shift);
                const px = origin_x + peer_x;
                const py = origin_y + peer_y;
                const h = if (on_goal_level) octileU32(px, py, goal_x, goal_y) else 0;
                // In-grid: below the level's cell count.
                const target = py * width + px;
                const cost = chunk_octile[@max(local_x, peer_x) - @min(local_x, peer_x)][@max(local_y, peer_y) - @min(local_y, peer_y)];
                const node = AbstractNode{ .ref = packRef(level, target), .x = px, .y = py, .portal = peer };
                if (!relaxAbstractNode(abstract, current_slot, current_g, node, cost, false, h)) return .saturated;
            }
        }
        // The mirror cell across each border this portal sits on.
        // A flag means the mirror cell exists in-grid.
        if (portal.flags.west and !relaxMirror(abstract, current_slot, current_g, level, cell - 1, x - 1, y, on_goal_level, goal_x, goal_y)) return .saturated;
        if (portal.flags.east and !relaxMirror(abstract, current_slot, current_g, level, cell + 1, x + 1, y, on_goal_level, goal_x, goal_y)) return .saturated;
        if (portal.flags.north and !relaxMirror(abstract, current_slot, current_g, level, cell - width, x, y - 1, on_goal_level, goal_x, goal_y)) return .saturated;
        if (portal.flags.south and !relaxMirror(abstract, current_slot, current_g, level, cell + width, x, y + 1, on_goal_level, goal_x, goal_y)) return .saturated;
        // Links leaving this cell whose target cell is open on a built level; only a
        // link-flagged portal has any.
        if (!portal.flags.link) continue;
        for (portals.linksAt(local)) |link| {
            const target_grid = graph.grid(link.to_level) orelse continue;
            if (target_grid.isBlockedIndex(link.to_cell)) continue;
            const target_y = link.to_cell / width;
            const target_x = link.to_cell - target_y * width;
            const h = if (link.to_level == goal_level) octileU32(target_x, target_y, goal_x, goal_y) else 0;
            const node = AbstractNode{ .ref = packRef(link.to_level, link.to_cell), .x = target_x, .y = target_y, .portal = null };
            if (!relaxAbstractNode(abstract, current_slot, current_g, node, link.cost, true, h)) return .saturated;
        }
    }
    return .none;
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
fn relaxMirror(abstract: *AbstractScratch, parent_slot: u32, parent_g: u32, level: u16, target: u32, mx: u32, my: u32, on_goal_level: bool, goal_x: u32, goal_y: u32) bool {
    const h = if (on_goal_level) octileU32(mx, my, goal_x, goal_y) else 0;
    const node = AbstractNode{ .ref = packRef(level, target), .x = mx, .y = my, .portal = null };
    return relaxAbstractNode(abstract, parent_slot, parent_g, node, cardinal_cost, false, h);
}

// Outcome of reconstructing the abstract corridor from the parent chain.
const CorridorBuild = enum {
    // Full chain root->goal rebuilt and rooted on the start level.
    ok,
    // The parent chain filled corridor_limit (max_abstract_nodes) before reaching the
    // seed root: a budget truncation, not an unreachable goal. Spill and retry rather
    // than declare negative.
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
fn localAStar(grid: *const NavGrid, scratch: *SearchScratch, start_index: usize, goal_index: usize) LocalSolve {
    if (start_index == goal_index) {
        scratch.path_scratch.clearRetainingCapacity();
        scratch.path_scratch.appendAssumeCapacity(@intCast(goal_index));
        return .found;
    }
    scratch.reset();
    const slots = scratch.slots;
    const width: i32 = @intCast(grid.width);
    const goal_x: i32 = @intCast(goal_index % grid.width);
    const goal_y: i32 = @intCast(goal_index / grid.width);
    const start_slot = scratch.slotFor(start_index) orelse return .budget_exhausted;
    // The root keeps parent no_slot.
    slots[start_slot].g = 0;
    const h0 = octileXY(@intCast(start_index % grid.width), @intCast(start_index / grid.width), goal_x, goal_y);
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
        const current_y_index = current.index / grid.width;
        const current_x_index = current.index - current_y_index * grid.width;
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

// Writes a plain path whole into this request's output stripe at its fallback ordinal.
// The local solve bounds a path at one cell per explored node, which the stripe holds.
fn recordPath(system: *PathfindingSystem, ordinal: usize, key: PathQueryKey, path: []const u32, path_level: u16) void {
    const stripe_words = types.resultBlockWords(system.capacity.max_explored_nodes, system.capacity.max_stitched_path_cells);
    const offset = ordinal * stripe_words;
    std.debug.assert(path.len <= stripe_words);
    @memcpy(system.worker_path_pool.items[offset .. offset + path.len], path);
    system.solved_paths.items[ordinal] = .{
        .key = key,
        .offset = offset,
        .len = path.len,
        .path_level = path_level,
    };
}

// Writes the full stitched (level,cell) corridor path whole into this request's output
// stripe; `path_level` is the start level. stitchCorridor's cap (at most
// max_stitched_path_cells) bounds it at the stripe, asserted so a drift fails loud
// instead of truncating the corridor.
fn recordStitched(system: *PathfindingSystem, ordinal: usize, key: PathQueryKey, stitched: []const StitchedCell, start_level: u16) void {
    const stripe_words = types.resultBlockWords(system.capacity.max_explored_nodes, system.capacity.max_stitched_path_cells);
    const offset = ordinal * stripe_words;
    std.debug.assert(stitched.len * types.stitched_cell_words <= stripe_words);
    const stripe = system.worker_path_pool.items[offset .. offset + stripe_words];
    @memcpy(types.stitchedCells(stripe, stitched.len), stitched);
    system.solved_paths.items[ordinal] = .{
        .key = key,
        .offset = offset,
        .len = 0,
        .stitched_len = stitched.len,
        .path_level = start_level,
    };
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
    const width: i32 = @intCast(grid.width);
    const goal_x: i32 = @intCast(goal_index % grid.width);
    const goal_y: i32 = @intCast(goal_index / grid.width);
    if (!Touch.cell(start_index, touched, g, parent, closed, &explored, budget)) return .{ .result = .budget_exhausted, .explored = explored };
    g[start_index] = 0;
    const h0 = octileXY(@intCast(start_index % grid.width), @intCast(start_index / grid.width), goal_x, goal_y);
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
        const cy = current.index / grid.width;
        const cx = current.index - cy * grid.width;
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

    inline for (.{ &a, &b }) |abstract| {
        try std.testing.expect(relaxAbstractNode(abstract, no_slot, 0, testAbstractNode(1), 10, false, 0));
        try std.testing.expect(relaxAbstractNode(abstract, no_slot, 0, testAbstractNode(2), 10, false, 0));
        try std.testing.expect(!relaxAbstractNode(abstract, no_slot, 0, testAbstractNode(3), 10, false, 0));
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
    try std.testing.expectEqual(AbstractResult.saturated, abstractCorridor(&system.graph, &abstract, grid, grid, 0, 0, start, goal, 1_000_000));
    try std.testing.expectEqual(@as(usize, 3), abstract.node_budget);
    try std.testing.expectEqual(@as(usize, 3), abstract.nodes_used);
    // Reserved for the full search, the same query finds its corridor.
    try abstract.reserve(allocator, 4096);
    try std.testing.expect(abstractCorridor(&system.graph, &abstract, grid, grid, 0, 0, start, goal, 1_000_000) == .found);
}

// An uncached abstract A* with the production expansion order: a hash map of nodes keyed
// by ref, coordinates divided out of the cell and the portal found on every pop.
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

    fn search(self: *ReferenceAbstract, graph: *const NavGraph, start_grid: *const NavGrid, goal_grid: *const NavGrid, start_level: u16, goal_level: u16, start_index: usize, goal_index: usize) !AbstractResult {
        const allocator = self.nodes.allocator;
        const width: u32 = @intCast(graph.width);
        const tiles: u32 = graph.chunk_tiles;
        const chunks_x = (width + tiles - 1) / tiles;
        const goal: u32 = @intCast(goal_index);
        const goal_x = goal % width;
        const goal_y = goal / width;
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
                const h = if (start_level == goal_level) octileU32(px, py, goal_x, goal_y) else 0;
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
            node.closed = true;
            const current_g = node.g;
            const level = refLevel(current.index);
            const cell = refLocal(current.index);
            const x = cell % width;
            const y = cell / width;
            const chunk = (y / tiles) * chunks_x + x / tiles;
            const local: u8 = @intCast((y % tiles) * tiles + x % tiles);
            const portals = graph.chunkPortals(level, chunk);
            const portal = portals.find(local) orelse continue;
            if (level == goal_level and goal_label != 0 and chunk == goal_chunk and portal.label == goal_label) {
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
            const on_goal_level = level == goal_level;
            for ([_][]const NavPortal{ portals.border, portals.extra }) |peers| {
                for (peers) |peer| {
                    if (peer.local == local or peer.label != portal.label) continue;
                    const px = (x / tiles) * tiles + peer.local % tiles;
                    const py = (y / tiles) * tiles + peer.local / tiles;
                    const h = if (on_goal_level) octileU32(px, py, goal_x, goal_y) else 0;
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
                const h = if (on_goal_level) octileU32(mirror.x, mirror.y, goal_x, goal_y) else 0;
                if (!try self.relax(current.index, current_g, packRef(level, mirror.y * width + mirror.x), cardinal_cost, false, h)) return .saturated;
            }
            if (!portal.flags.link) continue;
            for (portals.linksAt(local)) |link| {
                const target_grid = graph.grid(link.to_level) orelse continue;
                if (target_grid.isBlockedIndex(link.to_cell)) continue;
                const h = if (link.to_level == goal_level) octileU32(link.to_cell % width, link.to_cell / width, goal_x, goal_y) else 0;
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
            };
            defer reference.deinit();
            const expected = try reference.search(graph, start_grid, goal_grid, start_level, goal_level, start, goal);
            const result = abstractCorridor(graph, &abstract, start_grid, goal_grid, start_level, goal_level, start, goal, budget);
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
    try std.testing.expectEqual(AbstractResult.none, abstractCorridor(graph, abstract, grid, grid, 0, 0, start, goal, 4096));
    // Every node the search touched is a portal of its chunk's record east of the wall:
    // no other-label peer in the start chunk, and never the dead link's blocked target.
    var touched: usize = 0;
    var reached_link_source = false;
    for (abstract.slots) |slot| {
        if (slot.stamp >> 1 != abstract.generation) continue;
        touched += 1;
        try std.testing.expectEqual(@as(u16, 0), refLevel(slot.node));
        const cell = refLocal(slot.node);
        try std.testing.expect(cell % grid.width > 5);
        // Cached coordinates are the node's own.
        try std.testing.expectEqual(cell % grid.width, slot.x);
        try std.testing.expectEqual(cell / grid.width, slot.y);
        try std.testing.expect(graph.chunkPortals(0, graph.chunkOf(cell)).find(graph.localOf(cell)) != null);
        if (cell == grid.indexForCell(.{ .x = 9, .y = 9 }).?) reached_link_source = true;
    }
    try std.testing.expect(touched > 1);
    try std.testing.expect(reached_link_source);
}
