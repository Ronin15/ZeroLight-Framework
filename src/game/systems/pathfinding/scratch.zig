// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Per-worker solver scratch: the abstract-tier open-addressed search state
//! (AbstractScratch) and the per-cell local A* search state (SearchScratch),
//! both generation-stamped so a reset is O(1) outside the rare wraparound.

const std = @import("std");
const types = @import("types.zig");
const OpenNode = types.OpenNode;
const StitchedCell = types.StitchedCell;
const unreachable_cost = types.unreachable_cost;
const no_ref = types.no_ref;
const no_cell = types.no_cell;
const open_heap_headroom_factor = types.open_heap_headroom_factor;

pub const AbstractSlotRow = struct {
    node: usize = 0,
    g: u32 = 0,
    parent: usize = 0,
    closed: bool = false,
    stamp: u32 = 0,
    via_link: bool = false,
};

pub const SearchCellRow = struct {
    g: u32 = 0,
    parent: u32 = 0,
    closed: bool = false,
    stamp: u32 = 0,
};

// Budget-bounded A* over abstract portal nodes keyed by a packed (level << 32) | local
// ref. Node g-cost/parent/closed/via_link use a ref->slot open-addressed hash with
// generation stamps, so memory is O(max_abstract_nodes), independent of the portal
// count. `corridor` holds the ordered packed refs of the chosen route (root start-level
// portal -> goal portal); `corridor_link[i]` marks whether corridor[i] was reached from
// corridor[i-1] over a cross-level/teleport LINK edge (a discrete jump) rather than an
// intra-level edge (walkable by local A*). The stitcher refines each non-link span with
// local A* and treats each link span as a single jump.
pub const AbstractScratch = struct {
    generation: u32 = 1,
    slot_capacity: usize = 0,
    // Per-query logical node-attempt budget, distinct from slot_capacity (the PHYSICAL
    // table size, sized once at reserve() to the largest — tier-1/derived — ceiling).
    // A caller (abstractCorridor) sets this before each search so a cheap tier-0 attempt
    // spills at its own small cap even though the table itself is sized much larger.
    // reserve() defaults it to the full physical budget so a direct caller that never
    // sets it explicitly keeps the old unconstrained-up-to-physical-size behavior.
    node_budget: usize = 0,
    // Distinct NEW nodes claimed this generation; reset alongside the generation bump.
    nodes_used: usize = 0,
    open: std.ArrayList(OpenNode) = .empty,
    // Node identity is a packed (level << 32) | local ref (usize); parent holds the
    // parent ref or no_ref. via_link records whether the slot's best parent edge was
    // a cross-level link (so buildCorridor can mark link transitions without a CSR scan).
    slots: std.MultiArrayList(AbstractSlotRow) = .{},
    // Cached slot columns; refreshed on reserve. slotFor runs in tight A* loops.
    slot_stamp: []u32 = &[_]u32{},
    slot_node: []usize = &[_]usize{},
    slot_g: []u32 = &[_]u32{},
    slot_parent: []usize = &[_]usize{},
    slot_closed: []bool = &[_]bool{},
    slot_via_link: []bool = &[_]bool{},
    corridor: std.ArrayList(usize) = .empty,
    corridor_link: std.ArrayList(bool) = .empty,

    pub fn deinit(self: *AbstractScratch, allocator: std.mem.Allocator) void {
        self.corridor_link.deinit(allocator);
        self.corridor.deinit(allocator);
        self.slots.deinit(allocator);
        self.open.deinit(allocator);
        self.* = undefined;
    }

    pub fn reserve(self: *AbstractScratch, allocator: std.mem.Allocator, max_abstract_nodes: usize) !void {
        const slot_capacity = @max(@as(usize, 16), max_abstract_nodes * 2);
        self.slot_capacity = slot_capacity;
        // Default node_budget to the full reserved size; abstractCorridor overrides it
        // per-query with the attempt-scoped tier cap.
        self.node_budget = max_abstract_nodes;
        self.nodes_used = 0;
        // Headroom above the distinct-node budget: relaxAbstractNode pushes a fresh entry
        // on every g-improvement, so the live heap holds stale duplicates the slot table
        // (slotFor) does not. Sizing it past the budget keeps a sub-budget search from
        // false-saturating on a full heap.
        try self.open.ensureTotalCapacity(allocator, @max(@as(usize, 16), max_abstract_nodes * open_heap_headroom_factor));
        try self.slots.resize(allocator, slot_capacity);
        self.refreshSlotColumns();
        try self.corridor.ensureTotalCapacity(allocator, max_abstract_nodes);
        try self.corridor_link.ensureTotalCapacity(allocator, max_abstract_nodes);
        @memset(self.slot_stamp, 0);
        self.generation = 1;
        self.open.clearRetainingCapacity();
    }

    fn refreshSlotColumns(self: *AbstractScratch) void {
        const cols = self.slots.slice();
        self.slot_stamp = cols.items(.stamp);
        self.slot_node = cols.items(.node);
        self.slot_g = cols.items(.g);
        self.slot_parent = cols.items(.parent);
        self.slot_closed = cols.items(.closed);
        self.slot_via_link = cols.items(.via_link);
    }

    pub fn reset(self: *AbstractScratch) void {
        self.open.clearRetainingCapacity();
        self.corridor.clearRetainingCapacity();
        self.corridor_link.clearRetainingCapacity();
        self.nodes_used = 0;
        self.generation +%= 1;
        if (self.generation == 0) {
            @memset(self.slot_stamp, 0);
            self.generation = 1;
        }
    }

    pub fn slotFor(self: *AbstractScratch, node: usize) ?usize {
        const capacity = self.slot_capacity;
        if (capacity == 0) return null;
        const stamp = self.slot_stamp;
        const nodes = self.slot_node;
        const g = self.slot_g;
        const parent = self.slot_parent;
        const closed = self.slot_closed;
        const via_link = self.slot_via_link;
        const start = types.hashUsize(node) % capacity;
        for (0..capacity) |probe| {
            const index = (start + probe) % capacity;
            if (stamp[index] == self.generation) {
                if (nodes[index] == node) return index;
                continue;
            }
            // A NEW node past the per-query attempt budget spills the search (returns
            // null -> saturated) even though the physical table has room; an
            // already-touched node (above) always resolves regardless of the budget.
            if (self.nodes_used >= self.node_budget) return null;
            self.nodes_used += 1;
            stamp[index] = self.generation;
            nodes[index] = node;
            g[index] = unreachable_cost;
            parent[index] = no_ref;
            closed[index] = false;
            via_link[index] = false;
            return index;
        }
        return null;
    }
};

pub const SearchScratch = struct {
    // One scratch slot per ThreadSystem participant. The local A* node state
    // (g-cost/parent/closed) lives in GENERATION-STAMPED DIRECT per-cell arrays
    // indexed by cell_index: O(1) access with zero hash collisions/probes and good
    // cache locality, in exchange for per-worker storage that is O(cells) (the
    // intended speed-for-bounded-memory trade — the grid is world-bounded). A
    // "reset" bumps the generation rather than clearing the arrays, only @memset-ing
    // the stamps on the rare generation wraparound. `max_explored_nodes` remains the
    // node BUDGET: an explicit expansion counter caps how many distinct cells one
    // solve may stamp, spilling the request to a later frame when exceeded (storage
    // is per-cell but the budget is unchanged).
    generation: u32 = 1,
    cell_count: usize = 0,
    // Per-solve count of distinct cells stamped this generation, bounded by the
    // node budget so a long-range solve spills instead of fully exploring the grid.
    explored: usize = 0,
    explored_budget: usize = 0,
    open: std.ArrayList(OpenNode) = .empty,
    // Direct per-cell rows, indexed by cell_index (NOT a hash slot). g/parent/closed
    // carry the A* state; stamp marks which generation last touched the cell so stale
    // values from a prior solve read as "untouched".
    cells: std.MultiArrayList(SearchCellRow) = .{},
    // Cached cell columns; refreshed on reserve. slotFor runs in tight A* loops.
    cell_stamp: []u32 = &[_]u32{},
    cell_g: []u32 = &[_]u32{},
    cell_parent: []u32 = &[_]u32{},
    cell_closed: []bool = &[_]bool{},
    // Path reconstruction scratch (cell indices, goal-to-start then reversed).
    path_scratch: std.ArrayList(u32) = .empty,
    // Stitched (level,cell) corridor path assembled from per-segment local A* runs
    // before it is copied into the worker corridor stripe.
    stitched_scratch: std.ArrayList(StitchedCell) = .empty,
    // Worker-private abstract-tier scratch so long-range/cross-level routing stays
    // disjoint per worker, matching the local A* scratch ownership.
    abstract: AbstractScratch = .{},

    pub fn deinit(self: *SearchScratch, allocator: std.mem.Allocator) void {
        self.abstract.deinit(allocator);
        self.stitched_scratch.deinit(allocator);
        self.path_scratch.deinit(allocator);
        self.cells.deinit(allocator);
        self.open.deinit(allocator);
        self.* = undefined;
    }

    pub fn reserve(self: *SearchScratch, allocator: std.mem.Allocator, max_explored_nodes: usize, max_stored_path_cells: usize, max_abstract_nodes: usize, max_stitched_path_cells: usize, cell_count: usize) !void {
        try self.abstract.reserve(allocator, max_abstract_nodes);
        // Direct per-cell arrays sized to the grid cell count; cell_index is the
        // array index, so there is no probe and no collision. The node budget stays
        // independent of this storage and is enforced by the expansion counter.
        self.cell_count = cell_count;
        self.explored_budget = max_explored_nodes;
        // Open-heap headroom over the distinct-cell budget (see open_heap_headroom_factor):
        // localAStar pushes a fresh entry per g-improvement and removes the superseded one
        // only lazily on pop, so the heap must hold more than the distinct-cell count or a
        // sub-budget search false-spills on a full heap. explored_budget stays the cap.
        try self.open.ensureTotalCapacity(allocator, @max(@as(usize, 16), max_explored_nodes * open_heap_headroom_factor));
        try self.cells.resize(allocator, cell_count);
        self.refreshCellColumns();
        try self.path_scratch.ensureTotalCapacity(allocator, @max(max_explored_nodes, max_stored_path_cells));
        // One extra slot lets a segment overflow be detected before truncation.
        try self.stitched_scratch.ensureTotalCapacity(allocator, max_stitched_path_cells + 1);
        @memset(self.cell_stamp, 0);
        self.generation = 1;
        self.open.clearRetainingCapacity();
    }

    fn refreshCellColumns(self: *SearchScratch) void {
        const cols = self.cells.slice();
        self.cell_stamp = cols.items(.stamp);
        self.cell_g = cols.items(.g);
        self.cell_parent = cols.items(.parent);
        self.cell_closed = cols.items(.closed);
    }

    pub fn reset(self: *SearchScratch) void {
        self.open.clearRetainingCapacity();
        self.explored = 0;
        self.generation +%= 1;
        if (self.generation == 0) {
            @memset(self.cell_stamp, 0);
            self.generation = 1;
        }
    }

    // Returns the direct cell slot, freshening it on first touch this generation.
    // Returns null only when freshening a NEW cell would exceed the node budget
    // (the spill cap) — already-touched cells always resolve, so reopening a cell
    // never spills. cell_index must be < cell_count (a valid grid cell).
    pub fn slotFor(self: *SearchScratch, cell: usize) ?usize {
        if (cell >= self.cell_count) return null;
        const stamp = self.cell_stamp;
        const g = self.cell_g;
        const parent = self.cell_parent;
        const closed = self.cell_closed;
        if (stamp[cell] == self.generation) return cell;
        if (self.explored >= self.explored_budget) return null;
        self.explored += 1;
        stamp[cell] = self.generation;
        g[cell] = unreachable_cost;
        parent[cell] = no_cell;
        closed[cell] = false;
        return cell;
    }
};
