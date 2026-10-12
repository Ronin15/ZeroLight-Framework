// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Solver scratch: the abstract-tier search table (AbstractScratch), the corridor scratch
//! one abstract solve stitches into (CorridorScratch), and the per-participant local A*
//! search table (SearchScratch). Every table is open-addressed, sized by its node budget
//! (never by level cells), and generation-stamped so a reset is O(1) outside the rare
//! wraparound.

const std = @import("std");
const types = @import("types.zig");
const PortalFlags = @import("nav_graph.zig").PortalFlags;
const thread_shared_record_alignment = @import("../../../app/thread_system.zig").thread_shared_record_alignment;
const OpenNode = types.OpenNode;
const StitchedCell = types.StitchedCell;
const unreachable_cost = types.unreachable_cost;
const no_slot = types.no_slot;
const max_stamp_generation = types.max_stamp_generation;
const openHeapLimit = types.openHeapLimit;
const fibonacciSlot = types.fibonacciSlot;
const hashTableSlots = types.hashTableSlots;
const hashTableShift = types.hashTableShift;

pub const AbstractSlotFlags = packed struct(u8) {
    // The slot's best parent edge is a cross-level or teleport link.
    via_link: bool = false,
    // `portal_label`/`portal_flags` hold the node's chunk portal.
    portal_known: bool = false,
    reserved: u6 = 0,
};

/// One abstract node: its packed `(level << 32) | cell` ref, `generation << 1 | closed`,
/// best cost, parent slot, and cell coordinates, plus its chunk portal when the claiming
/// relax knew it. Coordinates and portal are written once, when the node is claimed.
pub const AbstractSlot = extern struct {
    node: usize,
    stamp: u32,
    g: u32,
    parent: u32,
    x: u32,
    y: u32,
    portal_label: u8,
    portal_flags: PortalFlags,
    flags: AbstractSlotFlags,
    reserved: u8 = 0,

    comptime {
        std.debug.assert(@sizeOf(AbstractSlot) == 32);
    }
};

/// A `slotFor` result: the node's slot and whether this call claimed it.
pub const AbstractClaim = struct {
    slot: u32,
    fresh: bool,
};

// Budget-bounded A* over abstract portal nodes keyed by a packed (level << 32) | cell ref,
// in an open-addressed table of `hashTableSlots(node_limit)` rows, so memory follows the
// node budget, never the portal count. `corridor` holds the ordered refs of the chosen
// route (root start-level portal -> goal portal); `corridor_link[i]` marks whether
// corridor[i] was reached from corridor[i-1] over a link edge (a discrete jump) rather
// than an intra-level edge (walkable by local A*).
pub const AbstractScratch = struct {
    generation: u32 = 1,
    // Per-query budget on new nodes, at most `node_limit`; set by each search.
    node_budget: usize = 0,
    // Distinct nodes claimed this generation.
    nodes_used: usize = 0,
    /// Logical node cap set by `reserve`; a query budget never exceeds it, which keeps the
    /// table at load <= 1/2.
    node_limit: usize = 0,
    open: std.ArrayList(OpenNode) = .empty,
    slots: []AbstractSlot = &.{},
    slot_shift: u6 = 0,
    corridor: std.ArrayList(usize) = .empty,
    corridor_link: std.ArrayList(bool) = .empty,
    /// Logical open-heap cap set by `reserve` (`openHeapLimit(max_abstract_nodes)`); the
    /// search gates compare against this, never `open.capacity`.
    open_limit: usize = 0,
    /// Logical corridor cap set by `reserve` (`max_abstract_nodes`); the search gates
    /// compare against this, never `corridor.capacity`.
    corridor_limit: usize = 0,

    pub fn deinit(self: *AbstractScratch, allocator: std.mem.Allocator) void {
        self.corridor_link.deinit(allocator);
        self.corridor.deinit(allocator);
        allocator.free(self.slots);
        self.open.deinit(allocator);
        self.* = undefined;
    }

    /// Sizes the table and lists for `max_abstract_nodes`. A no-op at the reserved size;
    /// otherwise the new table is allocated before anything changes, so an out-of-memory
    /// leaves the scratch as it was.
    pub fn reserve(self: *AbstractScratch, allocator: std.mem.Allocator, max_abstract_nodes: usize) !void {
        const slot_count = try hashTableSlots(max_abstract_nodes);
        if (self.slots.len == slot_count and self.node_limit == max_abstract_nodes) return;
        // Headroom above the distinct-node budget: relaxAbstractNode pushes a fresh entry
        // on every g-improvement, so the live heap holds stale duplicates the slot table
        // does not. Sizing it past the budget keeps a sub-budget search from
        // false-saturating on a full heap.
        const open_limit = openHeapLimit(max_abstract_nodes);
        const slots = try allocator.alloc(AbstractSlot, slot_count);
        errdefer allocator.free(slots);
        try self.open.ensureTotalCapacity(allocator, open_limit);
        try self.corridor.ensureTotalCapacity(allocator, max_abstract_nodes);
        try self.corridor_link.ensureTotalCapacity(allocator, max_abstract_nodes);
        allocator.free(self.slots);
        self.slots = slots;
        @memset(std.mem.sliceAsBytes(self.slots), 0);
        self.slot_shift = hashTableShift(slot_count);
        self.generation = 1;
        self.nodes_used = 0;
        // Physical list capacity is grow-only, so a smaller re-reserve lowers the limits
        // while capacity stays.
        self.node_limit = max_abstract_nodes;
        self.node_budget = max_abstract_nodes;
        self.open_limit = open_limit;
        self.corridor_limit = max_abstract_nodes;
        std.debug.assert(self.node_limit * 2 <= self.slots.len);
        std.debug.assert(self.open.capacity >= self.open_limit and
            self.corridor.capacity >= self.corridor_limit and
            self.corridor_link.capacity >= self.corridor_limit);
        self.open.clearRetainingCapacity();
        self.corridor.clearRetainingCapacity();
        self.corridor_link.clearRetainingCapacity();
    }

    pub fn reset(self: *AbstractScratch) void {
        self.open.clearRetainingCapacity();
        self.corridor.clearRetainingCapacity();
        self.corridor_link.clearRetainingCapacity();
        self.nodes_used = 0;
        if (self.generation == max_stamp_generation) {
            @memset(std.mem.sliceAsBytes(self.slots), 0);
            self.generation = 1;
        } else {
            self.generation += 1;
        }
    }

    /// The slot of `node`, claiming it on first touch this generation (cost unreachable, no
    /// parent, no cached coordinates). Null only when claiming a new node would pass
    /// `node_budget`; a touched node always resolves.
    pub fn slotFor(self: *AbstractScratch, node: usize) ?AbstractClaim {
        std.debug.assert(self.slots.len != 0 and self.node_budget <= self.node_limit);
        const slots = self.slots;
        const slot_mask = slots.len - 1;
        // Scalar probe: about 1.5 slots per hit and 2.5 per miss at load <= 1/2, and
        // `node_budget <= node_limit <= slots.len / 2` leaves a free slot on every chain.
        var index = fibonacciSlot(node, self.slot_shift);
        while (true) : (index = (index + 1) & slot_mask) {
            const slot = &slots[index];
            if (slot.stamp >> 1 == self.generation) {
                if (slot.node == node) return .{ .slot = @intCast(index), .fresh = false };
                continue;
            }
            if (self.nodes_used >= self.node_budget) return null;
            self.nodes_used += 1;
            slot.* = .{
                .node = node,
                .stamp = self.generation << 1,
                .g = unreachable_cost,
                .parent = no_slot,
                .x = 0,
                .y = 0,
                .portal_label = 0,
                .portal_flags = .{},
                .flags = .{},
            };
            return .{ .slot = @intCast(index), .fresh = true };
        }
    }
};

/// The scratch one abstract solve runs in: the abstract search and the stitched path it
/// refines into. A participant owns one at tier-0 caps; each tier-1 pool entry owns one at
/// tier-1 caps.
pub const CorridorScratch = struct {
    abstract: AbstractScratch = .{},
    // Stitched (level,cell) corridor path assembled from per-segment local A* runs before
    // it is copied into the request's path stripe.
    stitched: std.ArrayList(StitchedCell) = .empty,
    /// Logical stitched-path cap set by `reserve`; a query cap never exceeds it.
    stitched_limit: usize = 0,

    pub fn deinit(self: *CorridorScratch, allocator: std.mem.Allocator) void {
        self.stitched.deinit(allocator);
        self.abstract.deinit(allocator);
        self.* = undefined;
    }

    /// Sizes the abstract table for `max_abstract_nodes` and the stitched path for
    /// `max_stitched_path_cells`; no-op and failure-atomic like `AbstractScratch.reserve`.
    pub fn reserve(self: *CorridorScratch, allocator: std.mem.Allocator, max_abstract_nodes: usize, max_stitched_path_cells: usize) !void {
        try self.abstract.reserve(allocator, max_abstract_nodes);
        // One extra slot lets a segment overflow be detected before truncation.
        try self.stitched.ensureTotalCapacity(allocator, max_stitched_path_cells +| 1);
        self.stitched_limit = max_stitched_path_cells;
        std.debug.assert(self.stitched.capacity > self.stitched_limit);
    }
};

/// One tier-1 corridor pool entry. Aligned to `thread_shared_record_alignment` (and so
/// padded to whole lines): entries sit contiguously in `PathfindingSystem.tier1_scratch`
/// and each escalated solve writes its own entry's counters on every node.
pub const Tier1Scratch = struct {
    corridor: CorridorScratch align(thread_shared_record_alignment) = .{},

    comptime {
        std.debug.assert(@alignOf(Tier1Scratch) == thread_shared_record_alignment);
        std.debug.assert(@sizeOf(Tier1Scratch) % thread_shared_record_alignment == 0);
    }

    pub fn deinit(self: *Tier1Scratch, allocator: std.mem.Allocator) void {
        self.corridor.deinit(allocator);
        self.* = undefined;
    }
};

/// One local A* node: its cell, `generation << 1 | closed`, best cost, and parent slot.
pub const SearchSlot = extern struct {
    cell: u32,
    stamp: u32,
    g: u32,
    parent: u32,

    comptime {
        std.debug.assert(@sizeOf(SearchSlot) == 16);
    }
};

pub const SearchScratch = struct {
    // One scratch slot per ThreadSystem participant. The local A* node state lives in an
    // open-addressed table of `hashTableSlots(max_explored_nodes)` rows keyed by cell, so
    // memory follows the node budget, never the level's cell count. A reset bumps the
    // generation, clearing the table only on the rare wraparound. `explored_budget` caps
    // how many distinct cells one solve may claim, spilling the request to a later frame
    // when exceeded; it never passes the reserved `explored_limit`.
    // Aligned to `thread_shared_record_alignment` (and so padded to whole 64 B lines): the
    // per-participant slots sit contiguously in `PathfindingSystem.scratch_slots` and each
    // worker writes its own slot's counters (generation, explored, open/path lengths,
    // abstract counters) on every node. Unaligned, adjacent slots' hot fields share a line
    // and false-share across workers, so threaded solve throughput swung with this struct's
    // size. 64, not `std.atomic.cache_line` (128 on x86_64): the ReleaseFast
    // `pathfinding --items 512` bench measured no gain from 128, matching the engine-wide
    // per-slot rule.
    generation: u32 align(thread_shared_record_alignment) = 1,
    // Per-solve count of distinct cells claimed this generation, bounded by the node
    // budget so a long-range solve spills instead of fully exploring the grid.
    explored: usize = 0,
    // Per-solve distinct-cell budget, at most `explored_limit`; set by each solve.
    explored_budget: usize = 0,
    /// Logical distinct-cell cap set by `reserve`; a solve budget never exceeds it, which
    /// keeps the table at load <= 1/2.
    explored_limit: usize = 0,
    open: std.ArrayList(OpenNode) = .empty,
    /// Logical open-heap cap set by `reserve` (`openHeapLimit(max_explored_nodes)`); the
    /// search gates compare against this, never `open.capacity`.
    open_limit: usize = 0,
    slots: []SearchSlot = &.{},
    slot_shift: u6 = 0,
    // Path reconstruction scratch (cell indices, goal-to-start then reversed).
    path_scratch: std.ArrayList(u32) = .empty,
    // This participant's tier-0 corridor scratch.
    corridor: CorridorScratch = .{},
    // Diagnostic only: highest per-solve stitch segment count (solve.zig's
    // stitchCorridor) this worker has produced since the last aggregation. NOT
    // reset by reset() (that runs per-segment, many times per solve); the owning
    // PathfindingSystem aggregates and clears it once per step in finishUpdate, so
    // it reflects one step's true worst case rather than a single solve's.
    max_stitch_segments_used: usize = 0,

    comptime {
        std.debug.assert(@alignOf(SearchScratch) == thread_shared_record_alignment);
        std.debug.assert(@sizeOf(SearchScratch) % thread_shared_record_alignment == 0);
    }

    pub fn deinit(self: *SearchScratch, allocator: std.mem.Allocator) void {
        self.corridor.deinit(allocator);
        self.path_scratch.deinit(allocator);
        allocator.free(self.slots);
        self.open.deinit(allocator);
        self.* = undefined;
    }

    /// Sizes the search table for `max_explored_nodes` and the corridor scratch for the
    /// abstract and stitched caps. A no-op at the reserved sizes; otherwise each table is
    /// allocated before it replaces the old one, so an out-of-memory leaves every table
    /// consistent with its own logical limits.
    pub fn reserve(self: *SearchScratch, allocator: std.mem.Allocator, max_explored_nodes: usize, max_abstract_nodes: usize, max_stitched_path_cells: usize) !void {
        try self.corridor.reserve(allocator, max_abstract_nodes, max_stitched_path_cells);
        const slot_count = try hashTableSlots(max_explored_nodes);
        if (self.slots.len == slot_count and self.explored_limit == max_explored_nodes) return;
        // Open-heap headroom over the distinct-cell budget (see open_heap_headroom_factor):
        // localAStar pushes a fresh entry per g-improvement and removes the superseded one
        // only lazily on pop, so the heap must hold more than the distinct-cell count or a
        // sub-budget search false-spills on a full heap. explored_limit stays the cap.
        const open_limit = openHeapLimit(max_explored_nodes);
        const slots = try allocator.alloc(SearchSlot, slot_count);
        errdefer allocator.free(slots);
        try self.open.ensureTotalCapacity(allocator, open_limit);
        // A parent chain holds at most one cell per claimed node; a start == goal path one.
        try self.path_scratch.ensureTotalCapacity(allocator, @max(@as(usize, 1), max_explored_nodes));
        allocator.free(self.slots);
        self.slots = slots;
        @memset(std.mem.sliceAsBytes(self.slots), 0);
        self.slot_shift = hashTableShift(slot_count);
        self.generation = 1;
        self.explored = 0;
        self.explored_limit = max_explored_nodes;
        self.explored_budget = max_explored_nodes;
        self.open_limit = open_limit;
        std.debug.assert(self.explored_limit * 2 <= self.slots.len);
        std.debug.assert(self.open.capacity >= self.open_limit);
        self.open.clearRetainingCapacity();
    }

    pub fn reset(self: *SearchScratch) void {
        self.open.clearRetainingCapacity();
        self.explored = 0;
        if (self.generation == max_stamp_generation) {
            @memset(std.mem.sliceAsBytes(self.slots), 0);
            self.generation = 1;
        } else {
            self.generation += 1;
        }
    }

    /// The slot of `cell`, claiming it on first touch this generation (cost unreachable,
    /// open, no parent). Null only when claiming a new cell would pass the node budget (the
    /// spill cap); a touched cell always resolves, so reopening a cell never spills.
    pub fn slotFor(self: *SearchScratch, cell: usize) ?u32 {
        std.debug.assert(self.slots.len != 0);
        // A validated level's cell indices are below maxInt(u32).
        const key: u32 = @intCast(cell);
        const slots = self.slots;
        const slot_mask = slots.len - 1;
        // Scalar probe: about 1.5 slots per hit and 2.5 per miss at load <= 1/2, and
        // `explored_budget <= slots.len / 2` leaves a free slot on every chain.
        var index = fibonacciSlot(key, self.slot_shift);
        while (true) : (index = (index + 1) & slot_mask) {
            const slot = &slots[index];
            if (slot.stamp >> 1 == self.generation) {
                if (slot.cell == key) return @intCast(index);
                continue;
            }
            if (self.explored >= self.explored_budget) return null;
            self.explored += 1;
            slot.* = .{ .cell = key, .stamp = self.generation << 1, .g = unreachable_cost, .parent = no_slot };
            return @intCast(index);
        }
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

fn touchedRows(scratch: *const SearchScratch) usize {
    var rows: usize = 0;
    for (scratch.slots) |slot| rows += @intFromBool(slot.stamp >> 1 == scratch.generation);
    return rows;
}

test "the search table holds ceilPow2(2B) rows whatever the level" {
    const allocator = std.testing.allocator;
    for ([_][2]usize{ .{ 5, 16 }, .{ 64, 128 }, .{ 100, 256 }, .{ 4096, 8192 } }) |case| {
        var scratch = SearchScratch{};
        defer scratch.deinit(allocator);
        try scratch.reserve(allocator, case[0], 16, 16);
        try std.testing.expectEqual(case[1], scratch.slots.len);
        try std.testing.expectEqual(case[0], scratch.explored_limit);
        try std.testing.expectEqual(openHeapLimit(case[0]), scratch.open_limit);
    }
}

test "SearchScratch generation wraparound clears stamps and the closed bit" {
    var scratch = SearchScratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reserve(std.testing.allocator, 16, 16, 16);

    // The last 31-bit generation: its shifted stamp still fits u32.
    scratch.generation = max_stamp_generation;
    const slot = scratch.slotFor(5).?;
    scratch.slots[slot].stamp |= 1;
    try std.testing.expectEqual((max_stamp_generation << 1) | 1, scratch.slots[slot].stamp);

    scratch.reset();
    // Wraps to 1, never to 0 (the cleared stamp) nor to 2^31 (whose shifted stamp aliases 0).
    try std.testing.expectEqual(@as(u32, 1), scratch.generation);
    try std.testing.expectEqual(@as(u32, 0), scratch.slots[slot].stamp);

    // The previously touched cell reads untouched: claiming it spends a fresh budget slot.
    try std.testing.expectEqual(@as(usize, 0), scratch.explored);
    const again = scratch.slotFor(5).?;
    try std.testing.expectEqual(@as(usize, 1), scratch.explored);
    try std.testing.expectEqual(@as(u32, 0), scratch.slots[again].stamp & 1);
}

test "a cell closed in one search reads open in the next" {
    var scratch = SearchScratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reserve(std.testing.allocator, 16, 16, 16);

    const first = scratch.slotFor(9).?;
    scratch.slots[first].stamp |= 1;
    scratch.slots[first].g = 30;
    scratch.reset();
    const second = scratch.slotFor(9).?;
    try std.testing.expectEqual(@as(u32, 0), scratch.slots[second].stamp & 1);
    try std.testing.expectEqual(unreachable_cost, scratch.slots[second].g);
    try std.testing.expectEqual(no_slot, scratch.slots[second].parent);
}

test "a new cell past the explored budget spills, a touched cell resolves" {
    var scratch = SearchScratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reserve(std.testing.allocator, 3, 16, 16);

    const touched = [_]usize{ 7, 70, 700 };
    var touched_slots: [touched.len]u32 = undefined;
    for (touched, &touched_slots) |cell, *slot| slot.* = scratch.slotFor(cell).?;
    try std.testing.expectEqual(@as(usize, 3), scratch.explored);
    try std.testing.expect(scratch.slotFor(7000) == null);
    for (touched, touched_slots) |cell, slot| try std.testing.expectEqual(slot, scratch.slotFor(cell).?);
    try std.testing.expectEqual(@as(usize, 3), scratch.explored);
    try std.testing.expectEqual(@as(usize, 3), touchedRows(&scratch));
}

test "AbstractScratch generation wraparound clears stamps" {
    var scratch = AbstractScratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reserve(std.testing.allocator, 16);

    scratch.generation = max_stamp_generation;
    const claim = scratch.slotFor(42).?;
    try std.testing.expect(claim.fresh);
    scratch.slots[claim.slot].stamp |= 1;

    scratch.reset();
    try std.testing.expectEqual(@as(u32, 1), scratch.generation);
    try std.testing.expectEqual(@as(u32, 0), scratch.slots[claim.slot].stamp);

    // A fresh touch of the same ref after wraparound claims a new node rather than
    // resolving through a stale stamp.
    try std.testing.expectEqual(@as(usize, 0), scratch.nodes_used);
    const again = scratch.slotFor(42).?;
    try std.testing.expect(again.fresh);
    try std.testing.expectEqual(@as(usize, 1), scratch.nodes_used);
    try std.testing.expect(!scratch.slotFor(42).?.fresh);
}

test "cells far above the table size claim distinct slots and probe across the table end" {
    var scratch = SearchScratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reserve(std.testing.allocator, 8, 16, 16);
    try std.testing.expectEqual(@as(usize, 16), scratch.slots.len);

    // Eight cells sharing the last home slot: the chain wraps past the table end.
    var cells: [8]usize = undefined;
    var found: usize = 0;
    var cell: usize = 1 << 20;
    while (found < cells.len) : (cell += 1) {
        if (fibonacciSlot(cell, scratch.slot_shift) == scratch.slots.len - 1) {
            cells[found] = cell;
            found += 1;
        }
    }
    var slots: [8]u32 = undefined;
    for (cells, &slots) |key, *slot| slot.* = scratch.slotFor(key).?;
    for (slots, 0..) |slot, index| {
        // Home 15, then 0, 1, ...: distinct slots in probe order.
        try std.testing.expectEqual(@as(u32, @intCast((15 + index) % 16)), slot);
        try std.testing.expectEqual(@as(u32, @intCast(cells[index])), scratch.slots[slot].cell);
    }
    // Each cell resolves to its own slot, never a chain neighbour with the same stamp.
    for (cells, slots) |key, slot| try std.testing.expectEqual(slot, scratch.slotFor(key).?);
    try std.testing.expectEqual(@as(usize, 8), scratch.explored);
}

test "re-reserving a smaller budget lowers the logical limits while physical capacity stays" {
    const allocator = std.testing.allocator;
    var scratch = SearchScratch{};
    defer scratch.deinit(allocator);
    try scratch.reserve(allocator, 256, 64, 16);
    try scratch.reserve(allocator, 64, 16, 16);

    try std.testing.expectEqual(@as(usize, 256), scratch.open_limit);
    try std.testing.expectEqual(@as(usize, 128), scratch.slots.len);
    try std.testing.expect(scratch.open.capacity >= 1024);
    try std.testing.expectEqual(@as(usize, 16), scratch.corridor.abstract.corridor_limit);
    try std.testing.expectEqual(@as(usize, 16), scratch.corridor.abstract.node_limit);
    try std.testing.expectEqual(@as(usize, 32), scratch.corridor.abstract.slots.len);
    try std.testing.expect(scratch.corridor.abstract.corridor.capacity >= 64);
}

test "a reserve at unchanged budgets allocates nothing and keeps the table (FailingAllocator)" {
    const allocator = std.testing.allocator;
    var scratch = SearchScratch{};
    defer scratch.deinit(allocator);
    try scratch.reserve(allocator, 64, 32, 16);
    var tier1 = Tier1Scratch{};
    defer tier1.deinit(allocator);
    try tier1.corridor.reserve(allocator, 128, 64);

    const search_slots = scratch.slots.ptr;
    const abstract_slots = scratch.corridor.abstract.slots.ptr;
    const tier1_slots = tier1.corridor.abstract.slots.ptr;
    _ = scratch.slotFor(11).?;
    const generation = scratch.generation;

    try scratch.reserve(std.testing.failing_allocator, 64, 32, 16);
    try tier1.corridor.reserve(std.testing.failing_allocator, 128, 64);
    try std.testing.expectEqual(search_slots, scratch.slots.ptr);
    try std.testing.expectEqual(abstract_slots, scratch.corridor.abstract.slots.ptr);
    try std.testing.expectEqual(tier1_slots, tier1.corridor.abstract.slots.ptr);
    try std.testing.expectEqual(generation, scratch.generation);
    try std.testing.expectEqual(@as(usize, 1), touchedRows(&scratch));

    // A changed budget under the failing allocator fails and leaves the old table.
    try std.testing.expectError(error.OutOfMemory, scratch.reserve(std.testing.failing_allocator, 128, 32, 16));
    try std.testing.expectEqual(search_slots, scratch.slots.ptr);
    try std.testing.expectEqual(@as(usize, 64), scratch.explored_limit);
}

test "SearchScratch participant slots never share a cache line" {
    // Contiguous scratch_slots entries are written concurrently by different workers; the
    // layout itself is a comptime assert on the type, this pins the slot stride.
    var slots: [2]SearchScratch = .{ .{}, .{} };
    const stride = @intFromPtr(&slots[1]) - @intFromPtr(&slots[0]);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(&slots[0]) % thread_shared_record_alignment);
    try std.testing.expectEqual(@as(usize, 0), stride % thread_shared_record_alignment);
}

test "tier-1 pool entries never share a cache line" {
    var entries: [2]Tier1Scratch = .{ .{}, .{} };
    const stride = @intFromPtr(&entries[1]) - @intFromPtr(&entries[0]);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(&entries[0]) % thread_shared_record_alignment);
    try std.testing.expectEqual(@as(usize, 0), stride % thread_shared_record_alignment);
    try std.testing.expect(stride >= @sizeOf(CorridorScratch));
}
