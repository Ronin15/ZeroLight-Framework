// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Per-request solvers: the budget-bounded local A*, the abstract chunk-portal/link
//! corridor search, the corridor stitcher, and the worker job entry point. These
//! free functions borrow *PathfindingSystem plus per-worker scratch and reach into
//! the NavGraph internals directly; they stay free functions to keep that wiring flat.

const std = @import("std");
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const PathfindingSystem = @import("system.zig").PathfindingSystem;
const NavGrid = @import("nav_grid.zig").NavGrid;
const NavGraph = @import("nav_graph.zig").NavGraph;
const AbstractScratch = @import("scratch.zig").AbstractScratch;
const SearchScratch = @import("scratch.zig").SearchScratch;
const types = @import("types.zig");
const PathSolveResult = types.PathSolveResult;
const PendingRequest = types.PendingRequest;
const StitchedCell = types.StitchedCell;
const OpenNode = types.OpenNode;
const no_parent = types.no_parent;
const no_cell = types.no_cell;
const no_ref = types.no_ref;
const no_component = types.no_component;
const diagonal_cost = types.diagonal_cost;
const cardinal_cost = types.cardinal_cost;
const packRef = types.packRef;
const refLevel = types.refLevel;
const refLocal = types.refLocal;
const octileCells = types.octileCells;
const octileXY = types.octileXY;
const siftUp = types.siftUp;
const popHeap = types.popHeap;
const neighbor_dirs = types.neighbor_dirs;

pub const SolveJobContext = struct {
    system: *PathfindingSystem,
};

// Fallback workers share the system for read-only graph/pending access but use
// worker-indexed scratch and a worker-disjoint path stripe to stay private.
pub fn solveFallbackJob(context: *anyopaque, range: ParallelRange, worker_id: WorkerId) void {
    const job: *SolveJobContext = @ptrCast(@alignCast(context));
    const system = job.system;
    const scratch = &system.scratch_slots.items[worker_id.index];
    for (range.start..range.end) |fallback_index| {
        const pending_index = system.fallback_indices.items[fallback_index];
        // The dense fallback index is this request's disjoint path stripe; two
        // requests never share a stripe even when one worker solves several.
        system.solve_results.items[pending_index] = solveOne(system, pending_index, scratch, fallback_index);
    }
}

// Outcome of a budget-bounded local A* over one level's grid.
pub const LocalSolve = enum { found, budget_exhausted, none };

// Solves one request. Short same-component hops use the budget-bounded local A*
// directly and store a plain path (no stitched corridor). Long-range or cross-level
// queries route through the abstract chunk-portal/link graph to pick a corridor, then
// stitch the full obstacle-aware (level,cell) path from per-segment local A* runs;
// the query walks it per-agent on its current level. Per-solve work is bounded by the
// abstract node budget plus the per-segment local budget, independent of total cells.
pub fn solveOne(system: *PathfindingSystem, pending_index: usize, scratch: *SearchScratch, path_slot: usize) PathSolveResult {
    const graph = &system.graph;
    const request = system.pending.items[pending_index];
    if (!graph.valid()) return .{ .unavailable = request.key };

    const start_grid = graph.grid(request.start_level) orelse return .{ .unavailable = request.key };
    const goal_grid = graph.grid(request.key.goal_level) orelse return .{ .unavailable = request.key };
    const start_index = start_grid.indexForCell(request.start) orelse return .{ .unavailable = request.key };
    if (start_grid.isBlockedIndex(start_index)) return .{ .unavailable = request.key };

    // Projection (including failure) was resolved at acceptance against the goal
    // level. no_parent means no open cell near the goal: a definitive negative.
    if (request.goal_index == no_parent) return .{ .unavailable = request.key };
    const goal_index = request.goal_index;

    const same_level = request.start_level == request.key.goal_level;
    if (same_level) {
        if (start_index == goal_index) {
            recordPath(system, pending_index, path_slot, &.{@intCast(goal_index)}, request.start_level);
            return .{ .available = request.key };
        }
        // Same component: a short hop the local A* can usually finish.
        if (start_grid.connected(start_index, goal_index)) {
            switch (localAStar(start_grid, scratch, start_index, goal_index)) {
                .found => {
                    recordPath(system, pending_index, path_slot, scratch.path_scratch.items, request.start_level);
                    return .{ .available = request.key };
                },
                // Budget spill on a short same-component hop is a transient: keep
                // it pending so a later frame retries rather than mislabeling it.
                .budget_exhausted => return .{ .budget_exhausted = request.key },
                .none => return .{ .unavailable = request.key },
            }
        }
        // Same level but different component: only a link corridor (e.g. a
        // teleport back onto this level) could connect them. Fall to abstract.
    }

    return solveAbstract(system, pending_index, scratch, path_slot, request, start_grid, goal_grid, start_index, goal_index);
}

// Abstract A* over portal nodes + link edges to choose a corridor across
// chunks/levels, then stitches the FULL obstacle-aware path: per-segment local A*
// between consecutive corridor portals (and start->first portal, last portal->goal)
// concatenated into one grid-adjacent (level,cell) path, with a discrete jump only
// across an inter-level link. The query walks that path per-agent on its current
// level, so every heading is to a traversable neighbor. Saturating the abstract
// scratch or a segment's node budget spills to a later frame (budget_exhausted)
// rather than mislabeling it; only a genuinely missing corridor is unavailable.
pub fn solveAbstract(
    system: *PathfindingSystem,
    pending_index: usize,
    scratch: *SearchScratch,
    path_slot: usize,
    request: PendingRequest,
    start_grid: *const NavGrid,
    goal_grid: *const NavGrid,
    start_index: usize,
    goal_index: usize,
) PathSolveResult {
    const graph = &system.graph;
    const corridor = switch (abstractCorridor(graph, scratch, start_grid, goal_grid, request.start_level, request.key.goal_level, start_index, goal_index)) {
        .found => |c| c,
        // Abstract scratch saturated: retry next frame instead of a hard negative.
        .saturated => return .{ .budget_exhausted = request.key },
        .none => return .{ .unavailable = request.key },
    };

    // Stitch the full obstacle-aware path across every corridor segment. A node-budget
    // spill or an overflow of the stitched buffer is a transient: retry next frame.
    switch (stitchCorridor(system, scratch, request, goal_grid, start_index, goal_index)) {
        .found => {},
        .budget_exhausted => return .{ .budget_exhausted = request.key },
        .none => return .{ .unavailable = request.key },
    }

    const stitched = scratch.stitched_scratch.items;
    if (stitched.len == 0) return .{ .unavailable = request.key };
    // Record the start-level prefix as the plain path (a first-cell fallback) and the
    // full stitched path the query walks.
    recordStartLevelPrefix(system, pending_index, path_slot, stitched, request.start_level);
    recordStitched(system, pending_index, path_slot, stitched);
    var solved = &system.solved_paths.items[pending_index];
    solved.via_abstract = true;
    solved.cross_level = corridor.crosses_level;
    return .{ .available = request.key };
}

// Stitches the chosen abstract corridor (scratch.abstract.corridor, ordered portal
// node indices root->goal) into scratch.stitched_scratch as one (level,cell) path.
// A NON-link transition (corridor_link[i] == false) is walked with local A* between
// consecutive portal cells; a LINK transition (corridor_link[i] == true) is a single
// discrete jump (no intermediate cells), whether it crosses Z or is a same-level
// teleport. The final span (last portal -> goal) is a same-level local A*. Returns
// budget_exhausted on any segment node-budget spill or stitched-buffer overflow.
pub fn stitchCorridor(
    system: *PathfindingSystem,
    scratch: *SearchScratch,
    request: PendingRequest,
    goal_grid: *const NavGrid,
    start_index: usize,
    goal_index: usize,
) LocalSolve {
    const graph = &system.graph;
    const cap = system.capacity.max_stitched_path_cells;
    scratch.stitched_scratch.clearRetainingCapacity();
    if (cap == 0) return .budget_exhausted;
    // Seed the path with the start cell on the start level.
    scratch.stitched_scratch.appendAssumeCapacity(.{ .level = request.start_level, .cell = @intCast(start_index) });

    var prev_level = request.start_level;
    var prev_cell: usize = start_index;
    for (scratch.abstract.corridor.items, 0..) |ref, i| {
        const portal = graph.level_graphs.items[refLevel(ref)].portals.items[refLocal(ref)];
        // The first corridor portal (i == 0) is on the start level and reached from
        // the start cell by a walkable span; later portals follow corridor_link.
        const is_link = i != 0 and scratch.abstract.corridor_link.items[i];
        if (is_link) {
            // Discrete link jump: append the far endpoint cell with no intermediate
            // cells (the agent crosses the link rather than walking).
            if (scratch.stitched_scratch.items.len >= cap) return .budget_exhausted;
            scratch.stitched_scratch.appendAssumeCapacity(.{ .level = portal.level, .cell = portal.cell_index });
        } else {
            // prev_level indexes a live level by construction (it came from the corridor
            // we just built); spill rather than panic if a malformed graph ever violates that.
            const grid = graph.grid(prev_level) orelse return .none;
            switch (appendSegment(scratch, grid, prev_level, prev_cell, portal.cell_index, cap)) {
                .found => {},
                else => |r| return r,
            }
        }
        prev_level = portal.level;
        prev_cell = portal.cell_index;
    }
    // Final span: last corridor cell -> goal cell, a walkable same-level segment.
    if (prev_level != request.key.goal_level) return .budget_exhausted;
    switch (appendSegment(scratch, goal_grid, prev_level, prev_cell, @intCast(goal_index), cap)) {
        .found => {},
        else => |r| return r,
    }
    return .found;
}

// Runs local A* from `from` to `to` on `grid` and appends the resulting cells
// (skipping the first, already present as the previous segment's tail) to the
// stitched buffer, tagged with `level`. Returns the local A* outcome, or
// budget_exhausted if appending would overflow the stitched cap.
pub fn appendSegment(scratch: *SearchScratch, grid: *const NavGrid, level: u16, from: usize, to: usize, cap: usize) LocalSolve {
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
        if (scratch.stitched_scratch.items.len >= cap) return .budget_exhausted;
        scratch.stitched_scratch.appendAssumeCapacity(.{ .level = level, .cell = cell });
    }
    return .found;
}

pub const AbstractCorridor = struct {
    // Whether the chosen corridor crosses at least one inter-level link.
    crosses_level: bool,
};

pub const AbstractResult = union(enum) {
    found: AbstractCorridor,
    // The bounded abstract scratch saturated (open/slot table full); the corridor
    // may exist but could not be searched this frame.
    saturated,
    // No corridor reaches the goal level/cell from the start.
    none,
};

// Relaxes one abstract neighbor `neighbor_ref` reached from `parent_ref` at `cost`,
// recording whether the relaxing edge was a cross-level link. Returns false on
// saturation (the bounded slot table or open heap is full).
pub fn relaxAbstractNode(
    abstract: *AbstractScratch,
    parent_ref: usize,
    parent_g: u32,
    neighbor_ref: usize,
    cost: u32,
    via_link: bool,
    h: u32,
) bool {
    const slot = abstract.slotFor(neighbor_ref) orelse return false;
    if (abstract.slot_closed.items[slot]) return true;
    const candidate = parent_g +| cost;
    if (candidate >= abstract.slot_g.items[slot]) return true;
    abstract.slot_g.items[slot] = candidate;
    abstract.slot_parent.items[slot] = parent_ref;
    abstract.slot_via_link.items[slot] = via_link;
    if (abstract.open.items.len >= abstract.open.capacity) return false;
    abstract.open.appendAssumeCapacity(.{ .index = neighbor_ref, .f = candidate +| h, .h = h });
    siftUp(abstract.open.items, abstract.open.items.len - 1);
    return true;
}

// Runs abstract A* over per-level portal CSRs plus the global link_edges. Node identity
// is a packed (level << 32) | local ref. On success it writes the ordered corridor of
// refs (root start-level portal -> goal-level portal) into scratch.abstract.corridor for
// the stitcher to refine, and reports whether the corridor crosses a level. Per-query
// work is bounded by the abstract node budget; seeding scans only the start chunk's
// local-component portals, so it stays bounded independent of total cell count.
pub fn abstractCorridor(
    graph: *const NavGraph,
    scratch: *SearchScratch,
    start_grid: *const NavGrid,
    goal_grid: *const NavGrid,
    start_level: u16,
    goal_level: u16,
    start_index: usize,
    goal_index: usize,
) AbstractResult {
    const abstract = &scratch.abstract;
    abstract.reset();

    // Seed the open set with the start cell's chunk-local-component portals on the start
    // level, costed by octile distance from the start.
    const start_component = start_grid.components.items[start_index];
    if (start_component == no_component) return .none;
    var seeded: usize = 0;
    for (graph.levelComponentPortals(start_level, start_component)) |local_node| {
        const portal = graph.level_graphs.items[start_level].portals.items[local_node];
        const ref = packRef(start_level, local_node);
        const slot = abstract.slotFor(ref) orelse return .saturated;
        const g = octileCells(graph.width, @intCast(start_index), portal.cell_index);
        abstract.slot_g.items[slot] = g;
        abstract.slot_parent.items[slot] = no_ref;
        abstract.slot_via_link.items[slot] = false;
        if (abstract.open.items.len >= abstract.open.capacity) return .saturated;
        // Only the goal level has a cell coordinate comparable to the goal; off-level seed
        // portals use h=0 to keep the heuristic admissible (matches the relax paths below).
        const h = if (start_level == goal_level)
            octileCells(graph.width, portal.cell_index, @intCast(goal_index))
        else
            0;
        abstract.open.appendAssumeCapacity(.{ .index = ref, .f = g +| h, .h = h });
        siftUp(abstract.open.items, abstract.open.items.len - 1);
        seeded += 1;
    }
    if (seeded == 0) return .none;

    const goal_component = goal_grid.components.items[goal_index];

    while (abstract.open.items.len != 0) {
        const current = popHeap(&abstract.open);
        const current_ref = current.index;
        const current_slot = abstract.slotFor(current_ref) orelse return .saturated;
        if (abstract.slot_closed.items[current_slot]) continue;
        // Lazy deletion: skip a superseded duplicate left in the heap by an earlier
        // g-improvement (f-h recovers its g; strict-greater never drops the best entry).
        if (current.f -% current.h > abstract.slot_g.items[current_slot]) continue;
        abstract.slot_closed.items[current_slot] = true;

        const level = refLevel(current_ref);
        const local = refLocal(current_ref);
        const lg = &graph.level_graphs.items[level];
        const portal = lg.portals.items[local];
        // Goal reached: this portal is on the goal level and shares the goal's chunk-local
        // component, so the local refiner can finish from here.
        if (level == goal_level and goal_component != no_component and
            goal_grid.components.items[portal.cell_index] == goal_component)
        {
            switch (buildCorridor(abstract, current_ref, start_level)) {
                .ok => {},
                // Budget-truncated reconstruction: spill+retry, never a hard negative.
                .truncated => return .saturated,
                .none => return .none,
            }
            return .{ .found = .{ .crosses_level = start_level != goal_level } };
        }

        const current_g = abstract.slot_g.items[current_slot];
        // Intra-level CSR edges (target is a node slot on the same level).
        const begin = lg.portal_edge_start.items[local];
        const end = begin + lg.portal_edge_count.items[local];
        for (lg.portal_edges.items[begin..end]) |edge| {
            const target_portal = lg.portals.items[edge.target];
            // Same-level non-goal hops still have a comparable goal cell when level ==
            // goal_level; otherwise h=0 keeps the estimate admissible.
            const h = if (level == goal_level)
                octileCells(graph.width, target_portal.cell_index, @intCast(goal_index))
            else
                0;
            if (!relaxAbstractNode(abstract, current_ref, current_g, packRef(level, edge.target), edge.cost, false, h)) return .saturated;
        }
        // Cross-level link edges: resolve the partner endpoint cell to its portal node on
        // the partner level through that level's cell_to_portal. h=0 unless the partner is
        // on the goal level (no cell coordinate is comparable to the goal until then).
        for (graph.link_edges.items) |link| {
            if (link.from_level == level and link.from_cell == portal.cell_index) {
                const to_local = graph.level_graphs.items[link.to_level].cell_to_portal.items[link.to_cell];
                if (to_local != no_cell) {
                    const h = if (link.to_level == goal_level) octileCells(graph.width, link.to_cell, @intCast(goal_index)) else 0;
                    if (!relaxAbstractNode(abstract, current_ref, current_g, packRef(link.to_level, to_local), link.cost, true, h)) return .saturated;
                }
            }
            if (link.bidirectional and link.to_level == level and link.to_cell == portal.cell_index) {
                const from_local = graph.level_graphs.items[link.from_level].cell_to_portal.items[link.from_cell];
                if (from_local != no_cell) {
                    const h = if (link.from_level == goal_level) octileCells(graph.width, link.from_cell, @intCast(goal_index)) else 0;
                    if (!relaxAbstractNode(abstract, current_ref, current_g, packRef(link.from_level, from_local), link.cost, true, h)) return .saturated;
                }
            }
        }
    }
    return .none;
}

// Outcome of reconstructing the abstract corridor from the parent chain.
pub const CorridorBuild = enum {
    // Full chain root->goal rebuilt and rooted on the start level.
    ok,
    // The parent chain filled corridor.capacity before reaching the seed root: a budget
    // truncation, not an unreachable goal. Spill and retry rather than declare negative.
    truncated,
    // Empty, or the chain rooted off the start level: a genuine missing corridor.
    none,
};

// Walks the abstract parent chain from the reached goal-level portal back to its seeded
// start-level root, writing the ordered packed-ref sequence (root -> goal portal) into
// abstract.corridor and the per-step link flags into corridor_link from the recorded
// slot_via_link. Returns .ok when the corridor's root is a start-level portal.
pub fn buildCorridor(abstract: *AbstractScratch, goal_ref: usize, start_level: u16) CorridorBuild {
    abstract.corridor.clearRetainingCapacity();
    var node = goal_ref;
    var truncated = false;
    while (true) {
        if (abstract.corridor.items.len >= abstract.corridor.capacity) {
            truncated = true;
            break;
        }
        abstract.corridor.appendAssumeCapacity(node);
        const slot = abstract.slotFor(node) orelse break;
        const parent = abstract.slot_parent.items[slot];
        if (parent == no_ref) break;
        node = parent;
    }
    std.mem.reverse(usize, abstract.corridor.items);
    if (abstract.corridor.items.len == 0) return .none;
    // Capacity cut the chain before the root: a budget spill, not an unreachable goal.
    if (truncated) return .truncated;
    // corridor_link[0] is false (no predecessor); corridor_link[i] is whether corridor[i]
    // was reached over a cross-level link, read from the recorded slot flag.
    abstract.corridor_link.clearRetainingCapacity();
    abstract.corridor_link.appendAssumeCapacity(false);
    for (1..abstract.corridor.items.len) |i| {
        const ref = abstract.corridor.items[i];
        const via_link = if (abstract.slotFor(ref)) |slot| abstract.slot_via_link.items[slot] else false;
        abstract.corridor_link.appendAssumeCapacity(via_link);
    }
    return if (refLevel(abstract.corridor.items[0]) == start_level) .ok else .none;
}

// Budget-bounded heap A* over one level's grid. Fills scratch.path_scratch with
// the reconstructed start-to-goal cells on success. The node budget keeps explored
// count bounded; exhausting it spills the request to a later frame.
pub fn localAStar(grid: *const NavGrid, scratch: *SearchScratch, start_index: usize, goal_index: usize) LocalSolve {
    if (start_index == goal_index) {
        scratch.path_scratch.clearRetainingCapacity();
        scratch.path_scratch.appendAssumeCapacity(@intCast(goal_index));
        return .found;
    }
    scratch.reset();
    const width: i32 = @intCast(grid.width);
    const goal_x: i32 = @intCast(goal_index % grid.width);
    const goal_y: i32 = @intCast(goal_index / grid.width);
    const start_slot = scratch.slotFor(start_index) orelse return .budget_exhausted;
    scratch.slot_g.items[start_slot] = 0;
    scratch.slot_parent.items[start_slot] = @intCast(start_index);
    const h0 = octileXY(@intCast(start_index % grid.width), @intCast(start_index / grid.width), goal_x, goal_y);
    scratch.open.appendAssumeCapacity(.{ .index = start_index, .f = h0, .h = h0 });

    while (scratch.open.items.len != 0) {
        const current = popHeap(&scratch.open);
        const current_slot = scratch.slotFor(current.index) orelse return .budget_exhausted;
        if (scratch.slot_closed.items[current_slot]) continue;
        // Lazy deletion: a superseded duplicate (a better g was recorded for this cell
        // after this entry was queued) is stale — discard it rather than re-expand. f-h
        // recovers this entry's g; it can only under-estimate under a saturating f, so the
        // strict-greater test never drops the live best entry.
        if (current.f -% current.h > scratch.slot_g.items[current_slot]) continue;
        scratch.slot_closed.items[current_slot] = true;
        if (current.index == goal_index) {
            reconstructLocalPath(scratch, start_index, goal_index);
            return .found;
        }
        // Derive current (x,y) once and step neighbors by the direction offset; the
        // neighbor coordinates feed the heuristic directly, so the inner loop has no
        // per-neighbor div/mod.
        const current_x: i32 = @intCast(current.index % grid.width);
        const current_y: i32 = @intCast(current.index / grid.width);
        const current_g = scratch.slot_g.items[current_slot];
        for (neighbor_dirs) |dir| {
            const nx = current_x + dir.x;
            const ny = current_y + dir.y;
            if (nx < 0 or ny < 0 or nx >= width or ny >= @as(i32, @intCast(grid.height))) continue;
            const next_index: usize = @intCast(ny * width + nx);
            if (grid.isBlockedIndex(next_index)) continue;
            // nx/ny and current_x/current_y are already in-bounds, so the helper indexes the
            // two orthogonal cells of a diagonal step directly, with no per-neighbor div/bounds.
            if (dir.diagonal and grid.diagonalCornerBlocked(current_x, current_y, nx, ny)) {
                continue;
            }
            const next_slot = scratch.slotFor(next_index) orelse return .budget_exhausted;
            if (scratch.slot_closed.items[next_slot]) continue;
            const step_cost = if (dir.diagonal) diagonal_cost else cardinal_cost;
            const candidate_g = current_g +| step_cost;
            if (candidate_g >= scratch.slot_g.items[next_slot]) continue;
            scratch.slot_g.items[next_slot] = candidate_g;
            scratch.slot_parent.items[next_slot] = @intCast(current.index);
            const h = octileXY(nx, ny, goal_x, goal_y);
            if (scratch.open.items.len >= scratch.open.capacity) return .budget_exhausted;
            scratch.open.appendAssumeCapacity(.{ .index = next_index, .f = candidate_g +| h, .h = h });
            siftUp(scratch.open.items, scratch.open.items.len - 1);
        }
    }
    return .none;
}

pub fn reconstructLocalPath(scratch: *SearchScratch, start_index: usize, goal_index: usize) void {
    scratch.path_scratch.clearRetainingCapacity();
    var current = goal_index;
    while (true) {
        scratch.path_scratch.appendAssumeCapacity(@intCast(current));
        if (current == start_index) break;
        const slot = scratch.slotFor(current) orelse break;
        const parent = scratch.slot_parent.items[slot];
        if (parent == no_cell) break;
        current = parent;
        if (scratch.path_scratch.items.len >= scratch.path_scratch.capacity) break;
    }
    // path_scratch is goal-to-start; reverse into start-to-goal.
    std.mem.reverse(u32, scratch.path_scratch.items);
}

pub fn recordPath(system: *PathfindingSystem, pending_index: usize, path_slot: usize, path: []const u32, path_level: u16) void {
    const stride = system.capacity.max_stored_path_cells;
    const offset = path_slot * stride;
    // Downsample (not head-truncate) an over-stride plain path so the agent keeps
    // progressing to the goal instead of stalling at the stride boundary. Shares the
    // result cache's contract via downsamplePathInto.
    const dst = system.worker_path_pool.items[offset .. offset + stride];
    const stored_len = types.downsamplePathInto(dst, path);
    system.solved_paths.items[pending_index] = .{
        .key = system.pending.items[pending_index].key,
        .offset = offset,
        .len = stored_len,
        .path_level = path_level,
    };
}

// Records the leading start-level run of the stitched path as the plain path buffer
// (used only as a first-cell fallback in the query). Writes the rest of the
// SolvedPath entry, mirroring recordPath's contract for a local solve.
pub fn recordStartLevelPrefix(system: *PathfindingSystem, pending_index: usize, path_slot: usize, stitched: []const StitchedCell, start_level: u16) void {
    const stride = system.capacity.max_stored_path_cells;
    const offset = path_slot * stride;
    var count: usize = 0;
    for (stitched) |sc| {
        if (sc.level != start_level) break; // first level change ends the prefix
        if (count >= stride) break;
        system.worker_path_pool.items[offset + count] = sc.cell;
        count += 1;
    }
    system.solved_paths.items[pending_index] = .{
        .key = system.pending.items[pending_index].key,
        .offset = offset,
        .len = count,
        .path_level = start_level,
    };
}

// Copies the full stitched (level,cell) corridor path into this request's disjoint
// stripe. Must run after recordStartLevelPrefix, which writes the rest of the entry.
pub fn recordStitched(system: *PathfindingSystem, pending_index: usize, path_slot: usize, stitched: []const StitchedCell) void {
    const stride = system.capacity.max_stitched_path_cells;
    if (stride == 0) return;
    const offset = path_slot * stride;
    const count = @min(stitched.len, stride);
    @memcpy(system.worker_stitched_pool.items[offset .. offset + count], stitched[0..count]);
    system.solved_paths.items[pending_index].stitched_offset = offset;
    system.solved_paths.items[pending_index].stitched_len = count;
}
