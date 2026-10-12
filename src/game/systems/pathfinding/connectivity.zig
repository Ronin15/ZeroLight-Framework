// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Connectivity ids over a nav graph. A node is a portal-bearing (level, chunk, label); its
//! row on its level holds a comp, and every comp hangs off one root, so two nodes connect
//! over border mirrors and two-way links exactly when their comps share a root. Every nav
//! batch maintains them: a seed stage reads the pre-change adjacency of the changed chunks,
//! a gather stage reads the re-derived records, and the main thread merges both in key order
//! (node rows, unions, fresh ids). Units no removal can split settle at once; the rest flood
//! in rounds until every removal's family has one open side: per round each lagging set of a
//! family runs one read-only search of up to its budget on a worker (budgets equalize the
//! family's claimed counts), and the main thread merges the discoveries in item order. Each
//! root-group then unites on the main thread.
//!
//! Over the roots, the per-world one-way closure: a terminal is a root holding an endpoint of
//! a live one-way link, an H-component a weak component of terminals over those links, and
//! each H-component keeps a reachability matrix (one row per terminal) in one arena block.
//! A batch touches the H-components its change can reach, re-resolves their links (threaded
//! per link), and recomputes only the rows whose reach can change (mask threaded per row, SCC
//! plan per piece, rows per SCC span in level rounds); the main thread merges terminals and
//! pieces and commits, O(1) per item. Blocks grow by powers of two, narrow when under a
//! quarter full, and dead blocks compact at the next batch's prepare.

const std = @import("std");
const WorldSystem = @import("../../world_system.zig").WorldSystem;
const LevelLink = @import("../../world_system.zig").LevelLink;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const BatchStats = @import("../../../app/thread_system.zig").BatchStats;
const NavGrid = @import("nav_grid.zig").NavGrid;
const NavGraph = @import("nav_graph.zig").NavGraph;
const NavLevelGraph = @import("nav_graph.zig").NavLevelGraph;
const ChunkPortals = @import("nav_graph.zig").ChunkPortals;
const BatchLevels = @import("nav_graph.zig").BatchLevels;
const NavStageThreads = @import("nav_graph.zig").NavStageThreads;
const PatchInfo = @import("nav_graph.zig").PatchInfo;
const RoundDispatch = @import("nav_graph.zig").RoundDispatch;
const runStage = @import("nav_graph.zig").runStage;
const chunkKey = @import("nav_graph.zig").chunkKey;
const keyLevel = @import("nav_graph.zig").keyLevel;
const keyChunk = @import("nav_graph.zig").keyChunk;
const types = @import("types.zig");
const NavUpdateStats = types.NavUpdateStats;
const StageTimer = @import("../../../app/runtime_perf_log.zig").StageTimer;
const accumulateBatch = @import("nav_graph.zig").accumulateBatch;
const listBytesBound = @import("nav_graph.zig").listBytesBound;
const rowsBytesBound = @import("nav_graph.zig").rowsBytesBound;
const simd = @import("../../../core/simd.zig");

pub const no_node: u32 = std.math.maxInt(u32);
pub const no_comp: u32 = std.math.maxInt(u32);
pub const no_root: u32 = std.math.maxInt(u32);
const no_set: u32 = std.math.maxInt(u32);
const no_unit: u32 = std.math.maxInt(u32);
const no_group: u32 = std.math.maxInt(u32);
const no_family: u32 = std.math.maxInt(u32);
const no_element: u32 = std.math.maxInt(u32);
const no_round: u32 = std.math.maxInt(u32);
const no_key: u64 = std.math.maxInt(u64);
pub const no_term: u32 = std.math.maxInt(u32);
pub const no_hcomp: u32 = std.math.maxInt(u32);
pub const no_oneway: u32 = std.math.maxInt(u32);
const no_index: u32 = std.math.maxInt(u32);
const no_slot: u32 = std.math.maxInt(u32);
const no_piece: u32 = std.math.maxInt(u32);
const no_scc: u32 = std.math.maxInt(u32);
// A block's index map holds a terminal id, or a free index tagged with `free_bit` whose low
// bits link the next free index (`free_end` ends the list). Terminal ids and local indices
// stay below `free_end`.
const free_bit: u32 = 1 << 31;
const free_end: u32 = free_bit - 1;
// Words of one rows item's span and one compaction line: a 64-byte cache line.
const span_words: usize = 16;

/// One node of a level: its chunk-local label, its comp, the next node of its record, and the
/// key and row of the next node in a flood queue (scratch, valid only inside a flood).
pub const NodeRow = struct {
    label: u8,
    comp: u32,
    sibling: u32,
    queue: u64,
    queue_row: u32,
};

// A comp: its root, its node count, its neighbours on the root's member list, and the flood
// set it was handed out to (`no_set` outside a flood).
const CompRow = struct {
    root: u32,
    size: u32,
    prev: u32,
    next: u32,
    set: u32,
};

// A root: the head of its member comps and their count, and its one-way terminal
// (`no_term` unless it holds an endpoint of a live one-way link). A freed root links the next
// freed root of its group through `head` until the commit; a free root has no terminal.
const RootRow = struct {
    head: u32,
    members: u32,
    term: u32,
};

// Node keys: (level, chunk, label) in bits 40..55, 8..39, and 0..7. `old_bit` names a node of
// the graph before the batch, its label read from the old cells; `root_bit` names a root in
// the element map. Chunks of a validated grid stay below 2^31.
const old_bit: u64 = 1 << 63;
const root_bit: u64 = 1 << 62;

fn nodeKey(level: u16, chunk: u32, label: u8) u64 {
    return (@as(u64, level) << 40) | (@as(u64, chunk) << 8) | label;
}

fn oldKey(level: u16, chunk: u32, label: u8) u64 {
    return old_bit | nodeKey(level, chunk, label);
}

fn nodeKeyLevel(key: u64) u16 {
    return @truncate(key >> 40);
}

fn nodeKeyChunk(key: u64) u32 {
    return @truncate(key >> 8);
}

fn nodeKeyLabel(key: u64) u8 {
    return @truncate(key);
}

/// Reach from a start cell to a goal cell (`reach`).
pub const Reach = enum {
    // The start cell is blocked: nothing is decided about the goal.
    start_blocked,
    reaches,
    unreachable_goal,
};

/// Whether `goal_cell` on `goal_level` is reachable from `start_cell` on `start_level` over
/// the graph's border mirrors, two-way links, and live one-way links in their direction: the
/// same chunk label, two nodes under one root, or the start root's terminal reaching the goal
/// root's terminal in their H-component's closure. A blocked start is `start_blocked`; an
/// open start reaches no blocked goal; a label holding no portal, or a chunk holding no
/// record, reaches only its own chunk label. Exact after every nav batch. O(1): one division
/// and label read per cell, two record node walks (at most the portal-bearing labels of one
/// chunk each), two root and two terminal reads, one bit.
pub fn reach(graph: *const NavGraph, start_level: u16, start_cell: usize, goal_level: u16, goal_cell: usize) Reach {
    const start_grid = graph.grid(start_level) orelse return .unreachable_goal;
    const goal_grid = graph.grid(goal_level) orelse return .unreachable_goal;
    const start = start_grid.chunkLabelAt(start_cell);
    if (start.label == 0) return .start_blocked;
    const goal = goal_grid.chunkLabelAt(goal_cell);
    if (goal.label == 0) return .unreachable_goal;
    if (start_level == goal_level and start.chunk == goal.chunk and start.label == goal.label) return .reaches;
    const start_graph = graph.levelGraph(start_level).?;
    const goal_graph = graph.levelGraph(goal_level).?;
    const start_row = start_graph.nodeOf(start.chunk, start.label);
    const goal_row = goal_graph.nodeOf(goal.chunk, goal.label);
    if (start_row == no_node or goal_row == no_node) return .unreachable_goal;
    const conn = &graph.connectivity;
    const start_root = conn.comp_root[start_graph.node_comp[start_row]];
    const goal_root = conn.comp_root[goal_graph.node_comp[goal_row]];
    if (start_root == goal_root) return .reaches;
    return if (conn.closure.termReaches(conn.root_term[start_root], conn.root_term[goal_root])) .reaches else .unreachable_goal;
}

// One edge a seed or gather item found: its two node keys and, per end, the end's row when
// it is a node already on its record (a hint for ends outside the batch's keys).
const EdgeEntry = struct {
    a: u64,
    b: u64,
    a_row: u32,
    b_row: u32,
};

const ElementKind = enum(u8) { removed, kept, added };

// One node of a patch key as the gather saw it: a row it lost, a row it kept, or a label it
// gained (no row yet).
const RowEntry = struct {
    row: u32,
    label: u8,
    kind: ElementKind,
};

// A node the batch touches: removed (gone after it), kept (a row before and after it), or
// added. Parents and sizes are union-find columns over element indices: units over the
// gathered edges, removal clusters over the seed edges, root-groups over shared old roots and
// clusters, families over the clusters that span two units.
const ElementRow = struct {
    key: u64,
    row: u32,
    level: u16,
    kind: ElementKind,
    unit_parent: u32,
    unit_size: u32,
    cluster_parent: u32,
    cluster_size: u32,
    group_parent: u32,
    group_size: u32,
    family_parent: u32,
    family_size: u32,
    // At a cluster's representative: the unit of its first kept element.
    cluster_unit: u32,
    // The element's unit number; at a group or family representative, its number.
    unit: u32,
    group: u32,
    family: u32,
    // At a unit representative: a removal cluster spans it and another unit.
    split: bool,
};

const UnitRow = struct {
    element_start: u32,
    element_count: u32,
    group: u32,
    // Its set number, or `no_set` when no cluster spans it with another unit.
    set: u32,
    // Its first kept element, or `no_element` when the unit is a piece new to the graph.
    first_kept: u32,
    // A rootless unit's fresh comp and root.
    fresh_comp: u32,
    fresh_root: u32,
};

// A flood set, indexed by set number: a unit a removal cluster spans together with another.
// Only a representative (`parent` == itself) holds live queue, comp-chain, count, and list
// fields.
const SetRow = struct {
    parent: u32,
    size: u32,
    // Nodes claimed into the set, its joined sets' included.
    claimed: u32,
    // The family it was created in; resolve through the family union-find.
    family: u32,
    unit: u32,
    group: u32,
    active: bool,
    own_comp: u32,
    fresh_root: u32,
    head_key: u64,
    head_row: u32,
    tail_key: u64,
    tail_row: u32,
    comp_head: u32,
    comp_tail: u32,
    comp_count: u32,
    // Neighbours on its family's list of active sets.
    prev_active: u32,
    next_active: u32,
};

// A family: the sets its removal clusters span, merged with another family when their sets
// meet. At a representative: its active sets (a list) and their count, the claimed count
// every active set is searched up to, the last round that served it, and its pass cursor:
// the next active set the current pass over the list visits (`no_set` once the pass ended).
// Every family sits once on a circular list in family order; a merged-away or finished
// family's entry leaves the list when a round reaches it.
const FamilyRow = struct {
    parent: u32,
    size: u32,
    active: u32,
    target: u32,
    served: u32,
    set_head: u32,
    set_tail: u32,
    pass_next: u32,
    list_prev: u32,
    list_next: u32,
};

const GroupRow = struct {
    root_start: u32,
    root_count: u32,
    set_start: u32,
    set_count: u32,
};

// One served set's search in a round: its set (the representative when the round was built),
// its detached queue from head to tail, the most proposals it writes before it stops
// expanding, and its proposal window (the budget plus one node's slack).
const FloodItem = struct {
    set: u32,
    budget: u32,
    head_key: u64,
    head_row: u32,
    tail_key: u64,
    tail_row: u32,
    window_start: u32,
    window_len: u32,
};

// What a search wrote: its proposal count, the prefix of proposals it expanded itself (or
// passed over as foreign), the first queue node it did not expand (`no_key` when it took the
// whole queue), and the nodes it expanded.
const FloodOut = struct {
    written: u32,
    expanded: u32,
    resume_key: u64,
    resume_row: u32,
    expansions: u32,
};

// A node a search reached that its set did not hold when the round was built; `foreign` when
// another set held it then, so the search did not expand through it.
const Proposal = struct {
    key: u64,
    row: u32,
    foreign: bool,
};

// One participant's search table: the node keys its current item proposed, open-addressed and
// cleared by a generation bump. Only its own participant writes it.
const FloodScratch = struct {
    generation: u32 align(thread_shared_record_alignment) = 0,
    keys: []u64 = &.{},
    stamps: []u32 = &.{},

    comptime {
        std.debug.assert(@sizeOf(FloodScratch) % thread_shared_record_alignment == 0);
    }

    fn deinit(self: *FloodScratch, allocator: std.mem.Allocator) void {
        allocator.free(self.stamps);
        allocator.free(self.keys);
        self.* = .{};
    }

    // Grows the table to `slots` (a power of two). Never shrinks.
    fn reserve(self: *FloodScratch, allocator: std.mem.Allocator, slots: usize) !void {
        if (self.keys.len >= slots) return;
        const keys = try allocator.alloc(u64, slots);
        errdefer allocator.free(keys);
        const stamps = try allocator.alloc(u32, slots);
        @memset(stamps, 0);
        self.deinit(allocator);
        self.* = .{ .keys = keys, .stamps = stamps };
    }
};

// Per-participant scratch sits on whole cache lines: each worker bumps its own generation.
const thread_shared_record_alignment: usize = 64;

/// Default proposal slots per flood round (W): rounds pack served sets' windows up to it.
/// A round width, not a budget: every round of a batch completes in that batch.
pub const default_flood_window: usize = 16384;

/// Default most nodes one flood item proposes (K): a work quantum that bounds each
/// participant's search table.
pub const default_flood_budget_cap: u32 = 512;

// Not std.HashMapUnmanaged: its clear costs the high-water capacity per batch, where the
// generation bump costs nothing.
/// Open-addressed u64 -> u32 map, cleared by a generation bump. Its slot count is a power of
/// two at least twice its logical limit, so probes stay short and an insert always finds
/// room. Const lookups are safe on workers while nothing writes.
pub const ElementMap = struct {
    keys: std.ArrayList(u64) = .empty,
    values: std.ArrayList(u32) = .empty,
    stamps: std.ArrayList(u32) = .empty,
    generation: u32 = 1,
    limit: usize = 0,
    used: usize = 0,

    pub fn deinit(self: *ElementMap, allocator: std.mem.Allocator) void {
        self.stamps.deinit(allocator);
        self.values.deinit(allocator);
        self.keys.deinit(allocator);
        self.* = .{};
    }

    pub fn reserve(self: *ElementMap, allocator: std.mem.Allocator, limit: usize) !void {
        const slots = try std.math.ceilPowerOfTwo(usize, @max(2 * limit, 16));
        if (slots > self.keys.items.len) {
            try self.keys.ensureTotalCapacityPrecise(allocator, slots);
            try self.values.ensureTotalCapacityPrecise(allocator, slots);
            try self.stamps.ensureTotalCapacityPrecise(allocator, slots);
            self.keys.items.len = slots;
            self.values.items.len = slots;
            self.stamps.items.len = slots;
            @memset(self.stamps.items, 0);
            self.generation = 1;
        }
        // Assigned only after every reserve succeeded.
        self.limit = limit;
        std.debug.assert(self.stamps.items.len >= 2 * limit);
    }

    // Shrinks the slots to what `limit` needs when it holds more, emptying the map. Never
    // fails: a failed shrink keeps the larger buffers.
    pub fn shrink(self: *ElementMap, allocator: std.mem.Allocator, limit: usize) void {
        const slots = std.math.ceilPowerOfTwo(usize, @max(2 * limit, 16)) catch return;
        if (self.keys.items.len <= slots) return;
        self.keys.shrinkAndFree(allocator, slots);
        self.values.shrinkAndFree(allocator, slots);
        self.stamps.shrinkAndFree(allocator, slots);
        @memset(self.stamps.items, 0);
        self.generation = 1;
        self.limit = 0;
        self.used = 0;
    }

    pub fn clear(self: *ElementMap) void {
        self.used = 0;
        self.generation +%= 1;
        if (self.generation == 0) {
            @memset(self.stamps.items, 0);
            self.generation = 1;
        }
    }

    fn slotOf(self: *const ElementMap, key: u64) usize {
        const mask = self.keys.items.len - 1;
        var slot: usize = @truncate((key *% 0x9E3779B97F4A7C15) >> 32);
        slot &= mask;
        while (self.stamps.items[slot] == self.generation and self.keys.items[slot] != key) slot = (slot + 1) & mask;
        return slot;
    }

    pub fn get(self: *const ElementMap, key: u64) ?u32 {
        const slot = self.slotOf(key);
        return if (self.stamps.items[slot] == self.generation) self.values.items[slot] else null;
    }

    pub fn put(self: *ElementMap, key: u64, value: u32) void {
        const slot = self.slotOf(key);
        std.debug.assert(self.stamps.items[slot] != self.generation);
        self.claimSlot(slot, key);
        self.values.items[slot] = value;
    }

    /// `key`'s value slot from one probe: `found` when the key was present, else the key is
    /// inserted and the caller writes its value. Within the reserved limit.
    pub fn getOrPut(self: *ElementMap, key: u64) GetOrPut {
        const slot = self.slotOf(key);
        const found = self.stamps.items[slot] == self.generation;
        if (!found) self.claimSlot(slot, key);
        return .{ .value = &self.values.items[slot], .found = found };
    }

    pub const GetOrPut = struct {
        value: *u32,
        found: bool,
    };

    fn claimSlot(self: *ElementMap, slot: usize, key: u64) void {
        std.debug.assert(self.used < self.limit);
        self.used += 1;
        self.stamps.items[slot] = self.generation;
        self.keys.items[slot] = key;
    }
};

// Union-find find with full path compression.
fn findRoot(parents: []u32, index: u32) u32 {
    var root = index;
    while (parents[root] != root) root = parents[root];
    var current = index;
    while (parents[current] != root) {
        const next = parents[current];
        parents[current] = root;
        current = next;
    }
    return root;
}

// Read-only find, for workers while the main thread holds the column still.
fn findRootConst(parents: []const u32, index: u32) u32 {
    var root = index;
    while (parents[root] != root) root = parents[root];
    return root;
}

// Unites two classes by size, ties to the lower index; returns the representative.
fn uniteBySize(parents: []u32, sizes: []u32, a: u32, b: u32) u32 {
    const root_a = findRoot(parents, a);
    const root_b = findRoot(parents, b);
    if (root_a == root_b) return root_a;
    const a_wins = sizes[root_a] > sizes[root_b] or (sizes[root_a] == sizes[root_b] and root_a < root_b);
    const keep = if (a_wins) root_a else root_b;
    const fold = if (a_wins) root_b else root_a;
    parents[fold] = keep;
    sizes[keep] += sizes[fold];
    return keep;
}

// ----------------------------------------------------------------------------------------
// One-way closure storage
// ----------------------------------------------------------------------------------------

// A registered one-way link: its world link, its H-component (`no_hcomp` while dead), the
// next link on that component's list, its resolved source and target terminals, and a batch
// stamp.
const OneWayRow = struct {
    link: u32,
    hcomp: u32,
    next: u32,
    src_term: u32,
    dst_term: u32,
    stamp: u32,
};

// A terminal: its root (`no_root` once its root was freed in the batch), its H-component and
// index there, and its batch slot (`no_slot` outside a batch's merge).
const TermRow = struct {
    root: u32,
    hcomp: u32,
    index: u32,
    slot: u32,
};

// An H-component: its arena block (`k_cap` rows of `rowWords(k_cap)` words, then `k_cap`
// index words), the indices handed out (`k_high`) and live, the head of its free index list,
// its one-way link list, and its batch slot and stamp. A free id has `k_cap == 0`.
const HCompRow = struct {
    block: u32,
    k_cap: u32,
    k_high: u32,
    k_live: u32,
    index_free: u32,
    link_head: u32,
    link_tail: u32,
    link_count: u32,
    slot: u32,
    stamp: u32,
};

const TermColumns = struct {
    root: []u32 = &.{},
    hcomp: []u32 = &.{},
    index: []u32 = &.{},
    slot: []u32 = &.{},
};

const HCompColumns = struct {
    block: []u32 = &.{},
    k_cap: []u32 = &.{},
    k_high: []u32 = &.{},
    k_live: []u32 = &.{},
    index_free: []u32 = &.{},
    link_head: []u32 = &.{},
    link_tail: []u32 = &.{},
    link_count: []u32 = &.{},
    slot: []u32 = &.{},
    stamp: []u32 = &.{},
};

const OneWayColumns = struct {
    link: []u32,
    hcomp: []u32,
    next: []u32,
    src_term: []u32,
    dst_term: []u32,
    stamp: []u32,

    fn of(slice: std.MultiArrayList(OneWayRow).Slice) OneWayColumns {
        return .{
            .link = slice.items(.link),
            .hcomp = slice.items(.hcomp),
            .next = slice.items(.next),
            .src_term = slice.items(.src_term),
            .dst_term = slice.items(.dst_term),
            .stamp = slice.items(.stamp),
        };
    }
};

// Words of one row of a block of `k_cap` indices.
fn rowWords(k_cap: u32) u32 {
    return @max(1, k_cap / 32);
}

// A block narrows when its component holds under a quarter of its indices, from 64 indices
// up (the smallest cap with rows wider than one word), to `compactCap` of its terminals: a
// third to two thirds full, so a third more terminals regrow it and a twelfth fewer narrow
// it again.
const shrink_min_cap: u32 = 64;

fn shrinkDue(terms: u32, k_cap: u32) bool {
    return k_cap >= shrink_min_cap and 4 * terms < k_cap;
}

fn compactCap(terms: u32) u32 {
    return std.math.ceilPowerOfTwoAssert(u32, terms + (terms + 1) / 2);
}

// Words of a block of `k_cap` indices: its rows and index map, padded to whole lines so every
// block starts on a line.
fn blockWords(k_cap: u32) usize {
    const raw = @as(usize, k_cap) * (@as(usize, rowWords(k_cap)) + 1);
    return std.mem.alignForward(usize, raw, span_words);
}

// One registered one-way endpoint a gather item saw: the registry row and both ends' node
// keys after the patch (`no_key` for an end closed or on an unbuilt level), each with its row
// before the merge (a hint for an end outside the batch's keys).
const OneWayEntry = struct {
    oneway: u32,
    a_key: u64,
    a_hint: u32,
    b_key: u64,
    b_hint: u32,
};

// A resolved link: live when both ends are open portals on built levels, then its ends' roots.
const ResolveOut = struct {
    live: bool,
    src_root: u32,
    dst_root: u32,
};

// A touched H-component: its id; its S bitmap and list windows (the old indices whose
// out-edges changed, that left, or that moved out); the piece holding most of its kept
// terminals and how many; and the piece that inherits its block (`no_piece` when none does).
const TouchRow = struct {
    hcomp: u32,
    s_start: u32,
    s_list_start: u32,
    s_count: u32,
    heir: u32,
    heir_count: u32,
    kept_by: u32,
};

// A terminal of the batch's merge, numbered on first sight in link order: its union-find
// columns over live links, its piece, its index in the piece's block, its out-edges' window in
// the batch CSR, its position in its piece's A list (`no_index` outside A) and its SCC, and
// whether it keeps its old index (`kept`) and must be recomputed (`a_flag`).
const SlotRow = struct {
    term: u32,
    parent: u32,
    size: u32,
    piece: u32,
    index: u32,
    out_start: u32,
    out_count: u32,
    a_pos: u32,
    scc: u32,
    kept: bool,
    a_flag: bool,
};

// A weak component of the batch's terminals over live links: the touched H-component whose
// block it inherits (`no_slot` for a new one), its H-component id, block, index capacity, the
// indices handed out and its free list (popped in the batch), whether its block moved to the
// arena tail and whether it narrows there (every terminal renumbered and recomputed), its
// terminal count, its A list window and SCCs, its link list, and a tally used while picking
// heirs.
const PieceRow = struct {
    inherit: u32,
    hcomp: u32,
    block: u32,
    k_cap: u32,
    k_high: u32,
    free_head: u32,
    relocated: bool,
    compact: bool,
    terms: u32,
    a_start: u32,
    a_count: u32,
    scc_count: u32,
    max_level: u32,
    link_head: u32,
    link_tail: u32,
    link_count: u32,
    tally: u32,
};

// One position of the pieces' A lists: its slot, then the per-piece Tarjan scratch (DFS
// index, low link, stack membership, stack and call frames, SCC completion order and its
// tables), then the SCC tables in level order: the members, and per SCC its first member,
// size, and level.
const APosRow = struct {
    slot: u32,
    dfs_index: u32,
    low: u32,
    on_stack: bool,
    stack: u32,
    call: u32,
    edge: u32,
    order: u32,
    tmp_start: u32,
    tmp_size: u32,
    tmp_level: u32,
    member: u32,
    first: u32,
    size: u32,
    level: u32,
};

// A freed index of a block a piece inherits: the touched H-component's slot and the index.
const FreedIndex = struct {
    touch: u32,
    index: u32,
};

// One kept terminal's old row and the S window it is tested against.
const MaskItem = struct {
    slot: u32,
    row: u32,
    touch: u32,
    words: u32,
};

// One round-0 span: `src_len` words copied from `src`, the rest of `len` words zeroed.
const CopyItem = struct {
    dst: u32,
    src: u32,
    len: u32,
    src_len: u32,
};

// One rows item: an SCC (its A position) of a piece, and the 16-word span of its row.
const RowsItem = struct {
    piece: u32,
    scc: u32,
    span: u32,
};

// A live block moving in a compaction: its H-component, old and new offsets, and its first
// line in the copy's line numbering.
const CompactBlock = struct {
    hcomp: u32,
    src: u32,
    dst: u32,
    line_start: u32,
};

// What one batch's closure stages may touch, bounded in prepare from counts: its candidate
// H-components (their count, terminals, links, capacities, row words, and block words), the
// dead links its keys take loose, the terminals it can pop (gross) and add net, whether a
// merge of components is possible, every terminal and piece it can number, the widest block
// a piece can take, the live words at prepare, and the reserves derived from them.
const ClosureBounds = struct {
    candidates: usize = 0,
    k_c: usize = 0,
    e_c: usize = 0,
    loose: usize = 0,
    e_t: usize = 0,
    n_gross: usize = 0,
    n_net: usize = 0,
    merge: bool = false,
    k_b: usize = 0,
    pieces: usize = 0,
    q_max: usize = 0,
    k_cap_sum: usize = 0,
    s_words: usize = 0,
    candidate_words: usize = 0,
    live_prepared: usize = 0,
    copy_items: usize = 0,
    round_items: usize = 0,
    arena_tail: usize = 0,
};

// One key's candidate tallies for the batch bound: the dead one-way links it takes loose
// (each at one canonical end), the terminals its revived links can pop (gross) and add net
// (a partner root already holding one adds none), the pieces terminal roots can split into
// at its cells, and whether it opens a cell the old grid blocks.
const CandTally = struct {
    loose: u32 = 0,
    new_gross: u32 = 0,
    new_net: u32 = 0,
    split: u32 = 0,
    opened: bool = false,
};

// One group of the batch bound: its old terminals, the smallest block its growth test
// compares against, the widest block an in-place piece keeps, and what narrowing adds: the
// most a narrowing heir takes (half its block) and a quarter of each narrowable block.
const BoundGroup = struct {
    k: usize = 0,
    k_cap: u32 = 0,
    width_cap: u32 = 0,
    half: u32 = 0,
    quarter: usize = 0,

    fn of(hcomp: HCompColumns, id: u32) BoundGroup {
        const k_cap = hcomp.k_cap[id];
        const narrows = k_cap >= shrink_min_cap;
        return .{ .k = hcomp.k_live[id], .k_cap = k_cap, .width_cap = k_cap, .half = if (narrows) k_cap / 2 else 0, .quarter = if (narrows) k_cap / 4 else 0 };
    }

    fn join(self: *BoundGroup, other: BoundGroup) void {
        self.k += other.k;
        self.k_cap = @min(self.k_cap, other.k_cap);
        self.width_cap = @max(self.width_cap, other.width_cap);
        self.half = @max(self.half, other.half);
        self.quarter += other.quarter;
    }
};

// The batch bound's sums over its groups: arena tail words, rows items, copy items, and the
// widest block and span count.
const BoundSums = struct {
    tail: usize = 0,
    rounds: usize = 0,
    copies: usize = 0,
    q_max: u32 = 0,
    w_max: u32 = 0,

    // A group's relocated pieces: an heir outgrowing the group's smallest block takes at most
    // `ceilPow2(k + n_net)` indices; otherwise a non-heir piece holds at most half of each
    // block's terminals plus the new ones, and a narrowing heir at most half its block. Their
    // caps sum to at most the group's mass. Each old terminal's row, and the row it frees, is
    // at most the wider of its block and that cap.
    fn add(self: *BoundSums, group: BoundGroup, n_net: usize) !void {
        const q = if (group.k + n_net > group.k_cap)
            try boundCap(group.k + n_net)
        else
            @max(try boundCap(@max(1, group.k / 2 + n_net)), group.half);
        const mass = 2 * group.k + group.quarter;
        const width = @max(spanCount(group.width_cap), spanCount(q));
        self.tail += mass * (@as(usize, rowWords(q)) + 1);
        self.rounds += group.k * width;
        self.copies += mass * spanCount(q) + group.k * width;
        self.q_max = @max(self.q_max, q);
        self.w_max = @max(self.w_max, width);
    }
};

// The power-of-two block cap holding `terms` indices; it stays below `free_end`.
fn boundCap(terms: usize) !u32 {
    const cap = std.math.ceilPowerOfTwo(usize, terms) catch return error.NavConnectivityOverflow;
    if (cap >= free_end) return error.NavConnectivityOverflow;
    return @intCast(cap);
}

/// Counters of one batch's closure stages.
pub const ClosureCounters = struct {
    touched: usize = 0,
    links: usize = 0,
    terms_new: usize = 0,
    terms_left: usize = 0,
    // Freed terminals a root at a link end took back instead of popping a new one.
    adopted: usize = 0,
    a_rows: usize = 0,
    rounds: usize = 0,
    words_written: usize = 0,
    shrinks: usize = 0,
    // Arena words the relocated pieces' blocks took past the live blocks.
    tail_words: usize = 0,
};

/// The per-world one-way closure: the registry of world links, the terminals (roots holding
/// an endpoint of a live one-way link), the H-components (weak components of terminals over
/// live links), each component's reachability matrix in one arena, and the batch staging its
/// stages share.
pub const Closure = struct {
    // Registry: per world link below the cursor its one-way row (`no_oneway` for two-way).
    oneway: std.MultiArrayList(OneWayRow) = .{},
    oneway_of_link: std.ArrayList(u32) = .empty,
    oneway_cursor: usize = 0,
    terms: std.MultiArrayList(TermRow) = .{},
    term_free: std.ArrayList(u32) = .empty,
    hcomps: std.MultiArrayList(HCompRow) = .{},
    hcomp_free: std.ArrayList(u32) = .empty,
    // Column views refreshed whenever a pool grows.
    term: TermColumns = .{},
    hcomp: HCompColumns = .{},
    // The matrices: live blocks, dead blocks waiting for a compaction, and padding-free
    // counts of each.
    words: std.ArrayList(u32) = .empty,
    // The words the arena holds without growing, assigned after its reserve succeeds.
    arena_limit: usize = 0,
    live_words: usize = 0,
    dead_words: usize = 0,
    compactions: u64 = 0,
    // Batch stamps: a prepare stamps candidates with `stamp`, the touch stamps with `stamp + 1`.
    stamp: u32 = 0,
    // Whether the current batch maintains the closure: the registry or the batch's new links
    // hold a one-way link.
    active: bool = false,
    limits: ClosureBounds = .{},
    // Candidate stage windows per key: hcomp ids (the distinct ones compacted to the front
    // after the stage) and the key's tallies.
    cand_starts: std.ArrayList(usize) = .empty,
    cand_counts: std.ArrayList(u32) = .empty,
    cand_hcomps: std.ArrayList(u32) = .empty,
    cand_tallies: std.ArrayList(CandTally) = .empty,
    // Gather one-way windows per key.
    ow_starts: std.ArrayList(usize) = .empty,
    ow_counts: std.ArrayList(u32) = .empty,
    ow_entries: std.ArrayList(OneWayEntry) = .empty,
    // Merge staging.
    freed_terms: std.ArrayList(u32) = .empty,
    touched: std.MultiArrayList(TouchRow) = .{},
    s_words: std.ArrayList(u32) = .empty,
    s_list: std.ArrayList(u32) = .empty,
    loose: std.ArrayList(u32) = .empty,
    resolve_items: std.ArrayList(u32) = .empty,
    resolve_out: std.ArrayList(ResolveOut) = .empty,
    slots: std.MultiArrayList(SlotRow) = .{},
    targets: std.ArrayList(u32) = .empty,
    pieces: std.MultiArrayList(PieceRow) = .{},
    leaving: std.ArrayList(u32) = .empty,
    freed_indices: std.ArrayList(FreedIndex) = .empty,
    mask_items: std.ArrayList(MaskItem) = .empty,
    plan_items: std.ArrayList(u32) = .empty,
    apos: std.MultiArrayList(APosRow) = .{},
    copy_items: std.ArrayList(CopyItem) = .empty,
    round_items: std.ArrayList(RowsItem) = .empty,
    round_starts: std.ArrayList(u32) = .empty,
    compact_blocks: std.ArrayList(CompactBlock) = .empty,
    // Stage shapes of the most recent batch (stats and benches).
    last_resolve_batch: BatchStats = .{},
    last_mask_batch: BatchStats = .{},
    last_plan_batch: BatchStats = .{},
    last_rows_batch: BatchStats = .{},

    fn deinit(self: *Closure, allocator: std.mem.Allocator) void {
        self.compact_blocks.deinit(allocator);
        self.round_starts.deinit(allocator);
        self.round_items.deinit(allocator);
        self.copy_items.deinit(allocator);
        self.apos.deinit(allocator);
        self.plan_items.deinit(allocator);
        self.mask_items.deinit(allocator);
        self.freed_indices.deinit(allocator);
        self.leaving.deinit(allocator);
        self.pieces.deinit(allocator);
        self.targets.deinit(allocator);
        self.slots.deinit(allocator);
        self.resolve_out.deinit(allocator);
        self.resolve_items.deinit(allocator);
        self.loose.deinit(allocator);
        self.s_list.deinit(allocator);
        self.s_words.deinit(allocator);
        self.touched.deinit(allocator);
        self.freed_terms.deinit(allocator);
        self.ow_entries.deinit(allocator);
        self.ow_counts.deinit(allocator);
        self.ow_starts.deinit(allocator);
        self.cand_tallies.deinit(allocator);
        self.cand_hcomps.deinit(allocator);
        self.cand_counts.deinit(allocator);
        self.cand_starts.deinit(allocator);
        self.words.deinit(allocator);
        self.hcomp_free.deinit(allocator);
        self.hcomps.deinit(allocator);
        self.term_free.deinit(allocator);
        self.terms.deinit(allocator);
        self.oneway_of_link.deinit(allocator);
        self.oneway.deinit(allocator);
        self.* = undefined;
    }

    /// Whether terminal `from` reaches terminal `to` over live one-way links: both terminals,
    /// one H-component, and `to`'s bit in `from`'s row. O(1).
    pub fn termReaches(self: *const Closure, from: u32, to: u32) bool {
        if (from == no_term or to == no_term) return false;
        const hcomp = self.term.hcomp[from];
        if (hcomp != self.term.hcomp[to]) return false;
        const k_cap = self.hcomp.k_cap[hcomp];
        const to_index = self.term.index[to];
        const word = self.words.items[self.hcomp.block[hcomp] + @as(usize, self.term.index[from]) * rowWords(k_cap) + to_index / 32];
        return (word >> @intCast(to_index % 32)) & 1 != 0;
    }

    /// Live H-components.
    pub fn hcompCount(self: *const Closure) usize {
        return self.hcomps.len - self.hcomp_free.items.len;
    }

    /// Live terminals.
    pub fn termCount(self: *const Closure) usize {
        return self.terms.len - self.term_free.items.len;
    }

    fn refreshColumns(self: *Closure) void {
        const terms = self.terms.slice();
        self.term = .{ .root = terms.items(.root), .hcomp = terms.items(.hcomp), .index = terms.items(.index), .slot = terms.items(.slot) };
        const hcomps = self.hcomps.slice();
        self.hcomp = .{
            .block = hcomps.items(.block),
            .k_cap = hcomps.items(.k_cap),
            .k_high = hcomps.items(.k_high),
            .k_live = hcomps.items(.k_live),
            .index_free = hcomps.items(.index_free),
            .link_head = hcomps.items(.link_head),
            .link_tail = hcomps.items(.link_tail),
            .link_count = hcomps.items(.link_count),
            .slot = hcomps.items(.slot),
            .stamp = hcomps.items(.stamp),
        };
    }

    // Grows the free terminal and H-component lists to `terms` and `hcomps` ids, so that many
    // pops never allocate. Pool growth is geometric and counted; ids stay below `free_end`.
    fn ensureFreeIds(self: *Closure, allocator: std.mem.Allocator, terms: usize, hcomps: usize, pool_grows: *u64) !void {
        // The pools may move before a later step fails: the views follow them either way.
        defer self.refreshColumns();
        try growPool(TermRow, allocator, &self.terms, &self.term_free, terms, .{ .root = no_root, .hcomp = no_hcomp, .index = no_index, .slot = no_slot }, pool_grows);
        try growPool(HCompRow, allocator, &self.hcomps, &self.hcomp_free, hcomps, emptyHComp(), pool_grows);
    }

    fn bytes(self: *const Closure) usize {
        return self.oneway.capacity * @sizeOf(OneWayRow) +
            self.oneway_of_link.capacity * @sizeOf(u32) +
            self.terms.capacity * @sizeOf(TermRow) +
            self.term_free.capacity * @sizeOf(u32) +
            self.hcomps.capacity * @sizeOf(HCompRow) +
            self.hcomp_free.capacity * @sizeOf(u32) +
            self.words.capacity * @sizeOf(u32);
    }

    fn stagingBytes(self: *const Closure) usize {
        return (self.cand_starts.capacity + self.ow_starts.capacity) * @sizeOf(usize) +
            self.cand_tallies.capacity * @sizeOf(CandTally) +
            (self.cand_counts.capacity + self.cand_hcomps.capacity + self.ow_counts.capacity +
                self.freed_terms.capacity + self.s_words.capacity + self.s_list.capacity + self.loose.capacity +
                self.resolve_items.capacity + self.targets.capacity + self.leaving.capacity + self.plan_items.capacity +
                self.round_starts.capacity) * @sizeOf(u32) +
            self.ow_entries.capacity * @sizeOf(OneWayEntry) +
            self.touched.capacity * @sizeOf(TouchRow) +
            self.resolve_out.capacity * @sizeOf(ResolveOut) +
            self.slots.capacity * @sizeOf(SlotRow) +
            self.pieces.capacity * @sizeOf(PieceRow) +
            self.freed_indices.capacity * @sizeOf(FreedIndex) +
            self.mask_items.capacity * @sizeOf(MaskItem) +
            self.apos.capacity * @sizeOf(APosRow) +
            self.copy_items.capacity * @sizeOf(CopyItem) +
            self.round_items.capacity * @sizeOf(RowsItem) +
            self.compact_blocks.capacity * @sizeOf(CompactBlock);
    }
};

fn emptyHComp() HCompRow {
    return .{ .block = 0, .k_cap = 0, .k_high = 0, .k_live = 0, .index_free = free_end, .link_head = no_oneway, .link_tail = no_oneway, .link_count = 0, .slot = no_slot, .stamp = 0 };
}

// Grows `free` to at least `needed` ids of `rows`, new rows set to `empty`. Pool growth is
// geometric and counted in `pool_grows`; ids stay below `free_end`, so a terminal id never
// reads as a free index-map entry.
fn growPool(comptime Row: type, allocator: std.mem.Allocator, rows: *std.MultiArrayList(Row), free: *std.ArrayList(u32), needed: usize, empty: Row, pool_grows: *u64) !void {
    if (free.items.len >= needed) return;
    const added = needed - free.items.len;
    const total = rows.len + added;
    if (total >= free_end) return error.NavConnectivityOverflow;
    if (total > rows.capacity) {
        try rows.setCapacity(allocator, @max(total, rows.capacity *| 2));
        pool_grows.* += 1;
    }
    try free.ensureTotalCapacityPrecise(allocator, rows.capacity);
    // Pushed in descending id order so pops hand out ascending ids.
    const first: u32 = @intCast(rows.len);
    for (0..added) |_| rows.appendAssumeCapacity(empty);
    var id: u32 = @intCast(rows.len);
    while (id > first) {
        id -= 1;
        free.appendAssumeCapacity(id);
    }
}

fn countOneWay(links: []const LevelLink) usize {
    var count: usize = 0;
    for (links) |link| count += @intFromBool(!link.bidirectional);
    return count;
}

/// Counters of one batch's connectivity stages, for stats and benches. `round_items_min` and
/// `round_items_max` span the flood's rounds (both zero with no round); `build_visits` counts
/// the active sets the main thread's round builds walked; `flood_off_main_ns` is the rounds'
/// dispatch time on workers.
pub const ConnectivityCounters = struct {
    groups: usize = 0,
    families: usize = 0,
    rounds: usize = 0,
    build_visits: usize = 0,
    flood_nodes: usize = 0,
    splits: usize = 0,
    merges: usize = 0,
    round_items_min: usize = 0,
    round_items_max: usize = 0,
    flood_off_main_ns: u64 = 0,
    closure: ClosureCounters = .{},
};

// The element columns of one merge, taken once with the staging at its limit.
const ElementColumns = struct {
    key: []u64,
    row: []u32,
    level: []u16,
    kind: []ElementKind,
    unit_parent: []u32,
    unit_size: []u32,
    cluster_parent: []u32,
    cluster_size: []u32,
    group_parent: []u32,
    group_size: []u32,
    family_parent: []u32,
    family_size: []u32,
    cluster_unit: []u32,
    unit: []u32,
    group: []u32,
    family: []u32,
    split: []bool,

    fn of(slice: std.MultiArrayList(ElementRow).Slice) ElementColumns {
        return .{
            .key = slice.items(.key),
            .row = slice.items(.row),
            .level = slice.items(.level),
            .kind = slice.items(.kind),
            .unit_parent = slice.items(.unit_parent),
            .unit_size = slice.items(.unit_size),
            .cluster_parent = slice.items(.cluster_parent),
            .cluster_size = slice.items(.cluster_size),
            .group_parent = slice.items(.group_parent),
            .group_size = slice.items(.group_size),
            .family_parent = slice.items(.family_parent),
            .family_size = slice.items(.family_size),
            .cluster_unit = slice.items(.cluster_unit),
            .unit = slice.items(.unit),
            .group = slice.items(.group),
            .family = slice.items(.family),
            .split = slice.items(.split),
        };
    }
};

const UnitColumns = struct {
    element_start: []u32,
    element_count: []u32,
    group: []u32,
    set: []u32,
    first_kept: []u32,
    fresh_comp: []u32,
    fresh_root: []u32,

    fn of(slice: std.MultiArrayList(UnitRow).Slice) UnitColumns {
        return .{
            .element_start = slice.items(.element_start),
            .element_count = slice.items(.element_count),
            .group = slice.items(.group),
            .set = slice.items(.set),
            .first_kept = slice.items(.first_kept),
            .fresh_comp = slice.items(.fresh_comp),
            .fresh_root = slice.items(.fresh_root),
        };
    }
};

const SetColumns = struct {
    parent: []u32,
    size: []u32,
    claimed: []u32,
    family: []u32,
    unit: []u32,
    group: []u32,
    active: []bool,
    own_comp: []u32,
    fresh_root: []u32,
    head_key: []u64,
    head_row: []u32,
    tail_key: []u64,
    tail_row: []u32,
    comp_head: []u32,
    comp_tail: []u32,
    comp_count: []u32,
    prev_active: []u32,
    next_active: []u32,

    fn of(slice: std.MultiArrayList(SetRow).Slice) SetColumns {
        return .{
            .parent = slice.items(.parent),
            .size = slice.items(.size),
            .claimed = slice.items(.claimed),
            .family = slice.items(.family),
            .unit = slice.items(.unit),
            .group = slice.items(.group),
            .active = slice.items(.active),
            .own_comp = slice.items(.own_comp),
            .fresh_root = slice.items(.fresh_root),
            .head_key = slice.items(.head_key),
            .head_row = slice.items(.head_row),
            .tail_key = slice.items(.tail_key),
            .tail_row = slice.items(.tail_row),
            .comp_head = slice.items(.comp_head),
            .comp_tail = slice.items(.comp_tail),
            .comp_count = slice.items(.comp_count),
            .prev_active = slice.items(.prev_active),
            .next_active = slice.items(.next_active),
        };
    }
};

const FamilyColumns = struct {
    parent: []u32,
    size: []u32,
    active: []u32,
    target: []u32,
    served: []u32,
    set_head: []u32,
    set_tail: []u32,
    pass_next: []u32,
    list_prev: []u32,
    list_next: []u32,

    fn of(slice: std.MultiArrayList(FamilyRow).Slice) FamilyColumns {
        return .{
            .parent = slice.items(.parent),
            .size = slice.items(.size),
            .active = slice.items(.active),
            .target = slice.items(.target),
            .served = slice.items(.served),
            .set_head = slice.items(.set_head),
            .set_tail = slice.items(.set_tail),
            .pass_next = slice.items(.pass_next),
            .list_prev = slice.items(.list_prev),
            .list_next = slice.items(.list_next),
        };
    }
};

const GroupColumns = struct {
    root_start: []u32,
    root_count: []u32,
    set_start: []u32,
    set_count: []u32,

    fn of(slice: std.MultiArrayList(GroupRow).Slice) GroupColumns {
        return .{
            .root_start = slice.items(.root_start),
            .root_count = slice.items(.root_count),
            .set_start = slice.items(.set_start),
            .set_count = slice.items(.set_count),
        };
    }
};

// The per-batch views the layout, settle, rounds, and finish share: every column taken once.
const BatchViews = struct {
    levels: BatchLevels,
    world: ?*const WorldSystem,
    elements: ElementColumns,
    units: UnitColumns,
    sets: SetColumns,
    families: FamilyColumns,
    groups: GroupColumns,
};

// Element counts of the batch staging lists: what a marks batch prepared, or what a level
// build keeps.
const StagingSizes = struct {
    // Seed windows.
    changed_keys: usize = 0,
    patch_keys: usize = 0,
    // Gather items: patch keys, then new links.
    items: usize = 0,
    seeds: usize = 0,
    rows: usize = 0,
    edges: usize = 0,
    // Merge staging: elements, units, sets, families, groups, and their lists.
    elements: usize = 0,
    // Closure staging: candidate and gather one-way entries, candidate H-components, the
    // terminals and links a batch can number, S windows, and round items.
    cand_entries: usize = 0,
    ow_entries: usize = 0,
    closure_touched: usize = 0,
    closure_terms: usize = 0,
    closure_links: usize = 0,
    closure_k_cap: usize = 0,
    closure_s_words: usize = 0,
    closure_copy_items: usize = 0,
    closure_round_items: usize = 0,

    fn max(a: StagingSizes, b: StagingSizes) StagingSizes {
        var result: StagingSizes = undefined;
        inline for (@typeInfo(StagingSizes).@"struct".field_names) |name| @field(result, name) = @max(@field(a, name), @field(b, name));
        return result;
    }
};

// Shrinks `list` to `keep` slots when it holds more; contents are scratch. A failed shrink
// keeps the larger buffer, so this never fails.
fn shrinkList(comptime T: type, list: *std.ArrayList(T), allocator: std.mem.Allocator, keep: usize) void {
    if (list.capacity <= keep) return;
    list.items.len = keep;
    list.shrinkAndFree(allocator, keep);
    list.clearRetainingCapacity();
}

fn shrinkRows(comptime Row: type, rows: *std.MultiArrayList(Row), allocator: std.mem.Allocator, keep: usize) void {
    if (rows.capacity <= keep) return;
    rows.len = rows.capacity;
    rows.shrinkAndFree(allocator, keep);
    rows.len = 0;
}

/// What sizes a world's reachability for `storageBytesBound`.
pub const StorageShape = struct {
    /// The most live node rows over every level.
    nodes: usize,
    /// The chunks one level build patches and the most nodes it gathers.
    level_chunks: usize,
    level_nodes: usize,
    /// The patch keys and new links of the largest marks batch.
    batch_keys: usize,
    batch_links: usize,
    border_stride: usize,
    /// The most link endpoints one chunk holds.
    chunk_endpoints: usize,
    links: usize,
    oneway_links: usize,
    /// The most terminals one H-component holds, clamped to every terminal.
    system_terminals: usize = std.math.maxInt(usize),
    participants: usize,
};

/// An over-estimate of `Connectivity.residentBytes` for `shape`, for storage size limits.
/// Every list is charged at std's growth past the most it is reserved for, every pool at its
/// doubling past its need. Staging is the larger of one level build and the largest marks
/// batch, per list: a key holds at most `border_stride + chunk_endpoints` nodes. Comps and
/// roots cover the live nodes plus a batch's fresh ids; the closure covers two terminals per
/// one-way link, H-components of at most `system_terminals` each, its arena at three times
/// its live blocks plus a span per piece, and a batch's closure staging at its worst.
pub fn storageBytesBound(shape: StorageShape) usize {
    const node_bound = shape.border_stride + shape.chunk_endpoints;
    const marks_keys = shape.batch_keys;
    const build_keys = shape.level_chunks;
    const keys = @max(marks_keys, build_keys);
    const items = @max(marks_keys +| shape.batch_links, build_keys);
    // Every key's border window, and the link endpoints its chunks hold: at most
    // `chunk_endpoints` each and every endpoint of the world in all.
    const endpoints = 2 *| shape.links;
    const marks_nodes = marks_keys *| shape.border_stride +| @min(marks_keys *| shape.chunk_endpoints, endpoints);
    const build_endpoints = @min(build_keys *| shape.chunk_endpoints, endpoints);
    // A build gathers a row per label (at most its nodes) and an edge per border run and
    // endpoint of every chunk.
    const build_labels = @min(shape.level_nodes, build_keys *| shape.border_stride +| build_endpoints);
    const build_edges = build_keys *| shape.border_stride +| build_endpoints;
    // A marks key gathers its old labels and new nodes as rows, an edge per node, and seeds
    // each node.
    const seeds = @max(marks_nodes, build_endpoints);
    const rows = @max(2 *| marks_nodes, build_labels);
    const edges = @max(marks_nodes +| shape.batch_links, build_edges);
    const marks_elements = 5 *| marks_nodes +| shape.batch_links;
    const build_elements = build_labels +| 2 *| build_endpoints +| 1;
    const elements = @max(marks_elements, build_elements);
    const map_slots = std.math.ceilPowerOfTwo(usize, @max(4 *| elements, 16)) catch std.math.maxInt(usize);
    const staging = listBytesBound(usize, keys +| 1) +| listBytesBound(u32, keys) +| listBytesBound(EdgeEntry, seeds) +|
        listBytesBound(bool, keys) +|
        2 *| (listBytesBound(usize, items +| 1) +| listBytesBound(u32, items)) +|
        listBytesBound(RowEntry, rows) +| listBytesBound(EdgeEntry, edges) +|
        rowsBytesBound(ElementRow, elements) +| rowsBytesBound(UnitRow, elements) +| rowsBytesBound(SetRow, elements) +|
        rowsBytesBound(FamilyRow, elements) +| rowsBytesBound(GroupRow, elements) +|
        5 *| listBytesBound(u32, elements) +|
        map_slots *| (@sizeOf(u64) + 2 * @sizeOf(u32));
    // A pool doubles past its need and its free list covers it exactly.
    const ids = 2 *| (shape.nodes +| elements);
    const pools = ids *| (@sizeOf(CompRow) + @sizeOf(u32) + @sizeOf(RootRow) + @sizeOf(u32));
    const flood_window = @max(default_flood_window, default_flood_budget_cap) + node_bound;
    // A round's items shrink as a node's slack grows: charged at the least slack.
    const flood_items = flood_window / (1 + shape.border_stride);
    const table_slots = std.math.ceilPowerOfTwo(usize, 2 * (default_flood_budget_cap + node_bound)) catch std.math.maxInt(usize);
    const flood = listBytesBound(FloodItem, flood_items) +| listBytesBound(FloodOut, flood_items) +|
        listBytesBound(Proposal, flood_window) +| listBytesBound(FloodScratch, shape.participants) +|
        shape.participants *| table_slots *| (@sizeOf(u64) + @sizeOf(u32));
    // Every world link holds a registry entry, one-way or not.
    const registry = listBytesBound(u32, shape.links);
    const key_nodes = keys *| shape.border_stride +| @min(keys *| shape.chunk_endpoints, endpoints);
    return staging +| pools +| flood +| registry +| closureBytesBound(shape, keys, key_nodes);
}

// The closure's share of `storageBytesBound`: its one-way rows, terminal and H-component pools,
// arena, and a batch's staging over `keys` keys holding at most `key_nodes` nodes. A batch holds at most every terminal as an old or popped
// one, every one-way link live or loose, and blocks whose caps sum to twice the terminals.
fn closureBytesBound(shape: StorageShape, keys: usize, key_nodes: usize) usize {
    if (shape.oneway_links == 0) return 0;
    const terminals = 2 *| shape.oneway_links;
    const system = @max(1, @min(shape.system_terminals, terminals));
    // A block's cap is a power of two below twice its component's terminals.
    const cap_max = std.math.ceilPowerOfTwo(usize, 2 *| system) catch std.math.maxInt(usize);
    const row_words = @max(1, cap_max / 32);
    const spans = (row_words + span_words - 1) / span_words;
    const live_words = 2 *| terminals *| (row_words +| 2) +| span_words *| terminals;
    const arena = (3 *| live_words +| span_words *| terminals) *| @sizeOf(u32);
    const registry = rowsBytesBound(OneWayRow, shape.oneway_links);
    // Terminals pop up to twice the live ones; H-components split into a piece per link.
    const pools = 2 *| 3 *| terminals *| (@sizeOf(TermRow) + @sizeOf(u32)) +| 2 *| 2 *| terminals *| (@sizeOf(HCompRow) + @sizeOf(u32));
    const staging = 2 *| listBytesBound(usize, keys +| 1) +| 2 *| listBytesBound(u32, keys) +| listBytesBound(CandTally, keys) +|
        listBytesBound(u32, 3 *| key_nodes) +|
        listBytesBound(OneWayEntry, @min(keys *| shape.chunk_endpoints, 2 *| shape.links)) +|
        listBytesBound(u32, terminals) +| rowsBytesBound(TouchRow, terminals) +|
        listBytesBound(u32, terminals / 16 +| terminals) +| listBytesBound(u32, 2 *| terminals) +|
        3 *| listBytesBound(u32, terminals) +| listBytesBound(ResolveOut, terminals) +|
        rowsBytesBound(SlotRow, 2 *| terminals) +| rowsBytesBound(PieceRow, terminals) +|
        2 *| listBytesBound(u32, terminals) +| listBytesBound(FreedIndex, terminals) +| listBytesBound(MaskItem, terminals) +|
        rowsBytesBound(APosRow, 2 *| terminals) +|
        listBytesBound(CopyItem, 6 *| terminals *| spans) +| listBytesBound(RowsItem, 3 *| terminals *| spans) +|
        listBytesBound(u32, 2 *| terminals +| 2) +| listBytesBound(CompactBlock, terminals);
    return registry +| pools +| arena +| staging;
}

/// Per-world comps and roots, plus the batch staging the stages share and the flood's round
/// buffers. Comps and roots are pools with free lists whose capacity covers every pooled id,
/// so a release never allocates; every staging bound is reserved before the batch's commit
/// starts, and a level build shrinks its staging back to what a marks batch needs when it
/// ends. The round buffers are fixed per world once reserved.
pub const Connectivity = struct {
    comps: std.MultiArrayList(CompRow) = .{},
    comp_free: std.ArrayList(u32) = .empty,
    roots: std.MultiArrayList(RootRow) = .{},
    root_free: std.ArrayList(u32) = .empty,
    // Column views refreshed whenever a pool grows.
    comp_root: []u32 = &.{},
    comp_size: []u32 = &.{},
    comp_prev: []u32 = &.{},
    comp_next: []u32 = &.{},
    comp_set: []u32 = &.{},
    root_head: []u32 = &.{},
    root_members: []u32 = &.{},
    root_term: []u32 = &.{},
    /// The one-way closure over the roots, maintained by every batch.
    closure: Closure = .{},

    // Seed stage: per item its window start (a prefix of bounds) and written count.
    seed_starts: std.ArrayList(usize) = .empty,
    seed_counts: std.ArrayList(u32) = .empty,
    seed_edges: std.ArrayList(EdgeEntry) = .empty,
    // Gather stage: per patch key whether the batch remasked it; per item (patch keys, then
    // new links) its row and edge windows and written counts.
    patch_changed: std.ArrayList(bool) = .empty,
    row_starts: std.ArrayList(usize) = .empty,
    row_counts: std.ArrayList(u32) = .empty,
    gather_rows: std.ArrayList(RowEntry) = .empty,
    edge_starts: std.ArrayList(usize) = .empty,
    edge_counts: std.ArrayList(u32) = .empty,
    gather_edges: std.ArrayList(EdgeEntry) = .empty,
    // Merge staging, each bounded by `element_limit`.
    element_limit: usize = 0,
    element_count: usize = 0,
    elements: std.MultiArrayList(ElementRow) = .{},
    element_map: ElementMap = .{},
    units: std.MultiArrayList(UnitRow) = .{},
    sets: std.MultiArrayList(SetRow) = .{},
    families: std.MultiArrayList(FamilyRow) = .{},
    groups: std.MultiArrayList(GroupRow) = .{},
    unit_elements: std.ArrayList(u32) = .empty,
    group_roots: std.ArrayList(u32) = .empty,
    group_sets: std.ArrayList(u32) = .empty,
    root_first: std.ArrayList(u32) = .empty,
    round_sets: std.ArrayList(u32) = .empty,
    // Flood rounds, reserved by the first batch that can flood: per round at most
    // `flood_item_limit` items and `flood_window_limit` proposal slots, an item's output
    // slot, and one search table per thread participant.
    flood_items: std.ArrayList(FloodItem) = .empty,
    flood_outs: std.ArrayList(FloodOut) = .empty,
    proposals: std.ArrayList(Proposal) = .empty,
    flood_scratch: std.ArrayList(FloodScratch) = .empty,
    flood_item_limit: usize = 0,
    flood_window_limit: usize = 0,
    // The most proposals one node's expansion writes: `border_stride` flags plus the most
    // endpoints a chunk holds.
    flood_slack: usize = 0,
    // The most proposals an item writes before it stops expanding: K, at most W.
    flood_budget_limit: u32 = 0,
    /// Proposal slots per flood round (W) beyond one node's slack; a bench or test may
    /// narrow it. Changes round count, never the partition.
    flood_window: usize = default_flood_window,
    /// The most proposals one flood item writes before it stops expanding (K); a bench or
    /// test may change it. Changes round count, never the partition.
    flood_budget_cap: u32 = default_flood_budget_cap,
    // The most link endpoints any chunk holds, over the first `endpoint_links_seen` links.
    max_chunk_endpoints: usize = 0,
    endpoint_links_seen: usize = 0,
    // The largest staging any marks batch prepared, per list: a level build keeps that much,
    // or what one changed chunk needs, and frees the rest.
    marks_staging_high: StagingSizes = .{},
    // Batch shapes of the most recent batch's seed and gather stages and its flood's rounds
    // folded into one (stats and benches).
    last_seed_batch: BatchStats = .{},
    last_gather_batch: BatchStats = .{},
    last_flood_batch: BatchStats = .{},

    pub fn deinit(self: *Connectivity, allocator: std.mem.Allocator) void {
        self.closure.deinit(allocator);
        for (self.flood_scratch.items) |*scratch| scratch.deinit(allocator);
        self.flood_scratch.deinit(allocator);
        self.proposals.deinit(allocator);
        self.flood_outs.deinit(allocator);
        self.flood_items.deinit(allocator);
        self.round_sets.deinit(allocator);
        self.root_first.deinit(allocator);
        self.group_sets.deinit(allocator);
        self.group_roots.deinit(allocator);
        self.unit_elements.deinit(allocator);
        self.groups.deinit(allocator);
        self.families.deinit(allocator);
        self.sets.deinit(allocator);
        self.units.deinit(allocator);
        self.element_map.deinit(allocator);
        self.elements.deinit(allocator);
        self.gather_edges.deinit(allocator);
        self.edge_counts.deinit(allocator);
        self.edge_starts.deinit(allocator);
        self.gather_rows.deinit(allocator);
        self.row_counts.deinit(allocator);
        self.row_starts.deinit(allocator);
        self.patch_changed.deinit(allocator);
        self.seed_edges.deinit(allocator);
        self.seed_counts.deinit(allocator);
        self.seed_starts.deinit(allocator);
        self.root_free.deinit(allocator);
        self.roots.deinit(allocator);
        self.comp_free.deinit(allocator);
        self.comps.deinit(allocator);
        self.* = undefined;
    }

    // Shrinks each staging list to its size in `keep` where it holds more; the round buffers
    // stay. Never fails.
    fn shrinkStaging(self: *Connectivity, allocator: std.mem.Allocator, keep: StagingSizes) void {
        shrinkList(usize, &self.seed_starts, allocator, keep.changed_keys + 1);
        shrinkList(u32, &self.seed_counts, allocator, keep.changed_keys);
        shrinkList(EdgeEntry, &self.seed_edges, allocator, keep.seeds);
        shrinkList(bool, &self.patch_changed, allocator, keep.patch_keys);
        shrinkList(usize, &self.row_starts, allocator, keep.items + 1);
        shrinkList(usize, &self.edge_starts, allocator, keep.items + 1);
        shrinkList(u32, &self.row_counts, allocator, keep.items);
        shrinkList(u32, &self.edge_counts, allocator, keep.items);
        shrinkList(RowEntry, &self.gather_rows, allocator, keep.rows);
        shrinkList(EdgeEntry, &self.gather_edges, allocator, keep.edges);
        shrinkRows(ElementRow, &self.elements, allocator, keep.elements);
        self.element_map.shrink(allocator, 2 * keep.elements);
        shrinkRows(UnitRow, &self.units, allocator, keep.elements);
        shrinkRows(SetRow, &self.sets, allocator, keep.elements);
        shrinkRows(FamilyRow, &self.families, allocator, keep.elements);
        shrinkRows(GroupRow, &self.groups, allocator, keep.elements);
        shrinkList(u32, &self.unit_elements, allocator, keep.elements);
        shrinkList(u32, &self.group_roots, allocator, keep.elements);
        shrinkList(u32, &self.group_sets, allocator, keep.elements);
        shrinkList(u32, &self.root_first, allocator, keep.elements);
        shrinkList(u32, &self.round_sets, allocator, keep.elements);
        const closure = &self.closure;
        shrinkList(usize, &closure.cand_starts, allocator, keep.patch_keys + 1);
        shrinkList(u32, &closure.cand_counts, allocator, keep.patch_keys);
        shrinkList(CandTally, &closure.cand_tallies, allocator, keep.patch_keys);
        shrinkList(u32, &closure.cand_hcomps, allocator, keep.cand_entries);
        shrinkList(usize, &closure.ow_starts, allocator, keep.patch_keys + 1);
        shrinkList(u32, &closure.ow_counts, allocator, keep.patch_keys);
        shrinkList(OneWayEntry, &closure.ow_entries, allocator, keep.ow_entries);
        shrinkList(u32, &closure.freed_terms, allocator, keep.closure_terms);
        shrinkRows(TouchRow, &closure.touched, allocator, keep.closure_touched);
        // The S bitmap stays zero over its length: shrink it as a whole.
        if (closure.s_words.capacity > keep.closure_s_words) {
            closure.s_words.items.len = @min(closure.s_words.items.len, keep.closure_s_words);
            closure.s_words.shrinkAndFree(allocator, keep.closure_s_words);
        }
        shrinkList(u32, &closure.s_list, allocator, keep.closure_k_cap);
        shrinkList(u32, &closure.loose, allocator, keep.closure_links);
        shrinkList(u32, &closure.resolve_items, allocator, keep.closure_links);
        shrinkList(ResolveOut, &closure.resolve_out, allocator, keep.closure_links);
        shrinkRows(SlotRow, &closure.slots, allocator, keep.closure_terms);
        shrinkList(u32, &closure.targets, allocator, keep.closure_links);
        shrinkRows(PieceRow, &closure.pieces, allocator, keep.closure_terms);
        shrinkList(u32, &closure.leaving, allocator, keep.closure_terms);
        shrinkList(FreedIndex, &closure.freed_indices, allocator, keep.closure_terms);
        shrinkList(MaskItem, &closure.mask_items, allocator, keep.closure_terms);
        shrinkList(u32, &closure.plan_items, allocator, keep.closure_terms);
        shrinkRows(APosRow, &closure.apos, allocator, keep.closure_terms);
        shrinkList(CopyItem, &closure.copy_items, allocator, keep.closure_copy_items);
        shrinkList(RowsItem, &closure.round_items, allocator, keep.closure_round_items);
        shrinkList(u32, &closure.round_starts, allocator, keep.closure_terms + 2);
        shrinkList(CompactBlock, &closure.compact_blocks, allocator, 0);
        self.element_limit = 0;
        self.element_count = 0;
    }

    /// Live comps.
    pub fn compCount(self: *const Connectivity) usize {
        return self.comps.len - self.comp_free.items.len;
    }

    /// Live roots: one per connected set of nodes.
    pub fn rootCount(self: *const Connectivity) usize {
        return self.roots.len - self.root_free.items.len;
    }

    /// Bytes of the comp and root pools and their free lists.
    pub fn poolBytes(self: *const Connectivity) usize {
        return self.comps.capacity * @sizeOf(CompRow) +
            self.comp_free.capacity * @sizeOf(u32) +
            self.roots.capacity * @sizeOf(RootRow) +
            self.root_free.capacity * @sizeOf(u32) +
            self.closure.bytes();
    }

    /// Bytes of the batch staging.
    pub fn stagingBytes(self: *const Connectivity) usize {
        return (self.seed_starts.capacity + self.row_starts.capacity + self.edge_starts.capacity) * @sizeOf(usize) +
            (self.seed_counts.capacity + self.row_counts.capacity + self.edge_counts.capacity) * @sizeOf(u32) +
            (self.seed_edges.capacity + self.gather_edges.capacity) * @sizeOf(EdgeEntry) +
            self.gather_rows.capacity * @sizeOf(RowEntry) +
            self.patch_changed.capacity +
            self.elements.capacity * @sizeOf(ElementRow) +
            self.element_map.keys.capacity * @sizeOf(u64) +
            (self.element_map.values.capacity + self.element_map.stamps.capacity) * @sizeOf(u32) +
            self.units.capacity * @sizeOf(UnitRow) +
            self.sets.capacity * @sizeOf(SetRow) +
            self.families.capacity * @sizeOf(FamilyRow) +
            self.groups.capacity * @sizeOf(GroupRow) +
            (self.unit_elements.capacity + self.group_roots.capacity + self.group_sets.capacity +
                self.root_first.capacity + self.round_sets.capacity) * @sizeOf(u32) +
            self.closure.stagingBytes();
    }

    /// Bytes of the flood's round buffers and search tables.
    pub fn floodBytes(self: *const Connectivity) usize {
        var bytes = self.flood_items.capacity * @sizeOf(FloodItem) +
            self.flood_outs.capacity * @sizeOf(FloodOut) +
            self.proposals.capacity * @sizeOf(Proposal) +
            self.flood_scratch.capacity * @sizeOf(FloodScratch);
        for (self.flood_scratch.items) |scratch| bytes += scratch.keys.len * @sizeOf(u64) + scratch.stamps.len * @sizeOf(u32);
        return bytes;
    }

    pub fn residentBytes(self: *const Connectivity) usize {
        return self.poolBytes() + self.stagingBytes() + self.floodBytes();
    }

    // The staging a marks batch changing one chunk needs: the changed key and its four
    // neighbours as patch keys plus one new link, each key up to `border_stride` portals and
    // the largest chunk's endpoints. A level build keeps at least this much, which the next
    // dig reserves anyway.
    fn oneChunkStaging(self: *const Connectivity, border_stride: usize) StagingSizes {
        const keys: usize = 5;
        const node_bound = border_stride + self.max_chunk_endpoints;
        const rows = keys * 2 * node_bound;
        const edges = keys * node_bound + 1;
        const seeds = node_bound;
        return .{
            .changed_keys = 1,
            .patch_keys = keys,
            .items = keys + 1,
            .seeds = seeds,
            .rows = rows,
            .edges = edges,
            .elements = rows + edges + 2 * seeds,
        };
    }

    fn refreshColumns(self: *Connectivity) void {
        const comps = self.comps.slice();
        self.comp_root = comps.items(.root);
        self.comp_size = comps.items(.size);
        self.comp_prev = comps.items(.prev);
        self.comp_next = comps.items(.next);
        self.comp_set = comps.items(.set);
        const roots = self.roots.slice();
        self.root_head = roots.items(.head);
        self.root_members = roots.items(.members);
        self.root_term = roots.items(.term);
    }

    // Grows the free comp and root lists to at least `needed` ids each, so that many claims
    // pop without allocating. Pool growth is geometric and counted in `pool_grows`; ids stay
    // below their sentinels.
    fn ensureFreeIds(self: *Connectivity, allocator: std.mem.Allocator, needed: usize, pool_grows: *u64) !void {
        if (self.comp_free.items.len < needed) {
            const added = needed - self.comp_free.items.len;
            const total = self.comps.len + added;
            if (total >= no_comp) return error.NavConnectivityOverflow;
            if (total > self.comps.capacity) {
                try self.comps.setCapacity(allocator, @max(total, self.comps.capacity *| 2));
                // The pool moved: the column views follow it before anything else can fail.
                self.refreshColumns();
                pool_grows.* += 1;
            }
            try self.comp_free.ensureTotalCapacityPrecise(allocator, self.comps.capacity);
            // Pushed in descending id order so claims hand out ascending ids.
            const first: u32 = @intCast(self.comps.len);
            for (0..added) |_| self.comps.appendAssumeCapacity(.{ .root = no_root, .size = 0, .prev = no_comp, .next = no_comp, .set = no_set });
            var id: u32 = @intCast(self.comps.len);
            while (id > first) {
                id -= 1;
                self.comp_free.appendAssumeCapacity(id);
            }
            self.refreshColumns();
        }
        if (self.root_free.items.len < needed) {
            const added = needed - self.root_free.items.len;
            const total = self.roots.len + added;
            if (total >= no_root) return error.NavConnectivityOverflow;
            if (total > self.roots.capacity) {
                try self.roots.setCapacity(allocator, @max(total, self.roots.capacity *| 2));
                self.refreshColumns();
                pool_grows.* += 1;
            }
            try self.root_free.ensureTotalCapacityPrecise(allocator, self.roots.capacity);
            const first: u32 = @intCast(self.roots.len);
            for (0..added) |_| self.roots.appendAssumeCapacity(.{ .head = no_comp, .members = 0, .term = no_term });
            var id: u32 = @intCast(self.roots.len);
            while (id > first) {
                id -= 1;
                self.root_free.appendAssumeCapacity(id);
            }
            self.refreshColumns();
        }
    }

    // Reserves the merge staging for `limit` elements (element rows and the map, units,
    // sets, families, groups, and their lists) and `fresh` free comps and roots: fresh ids go
    // one pair per set or rootless unit, at most one per unit.
    fn reserveMerge(self: *Connectivity, allocator: std.mem.Allocator, limit: usize, fresh: usize, pool_grows: *u64) !void {
        if (limit >= no_unit) return error.NavConnectivityOverflow;
        try self.elements.ensureTotalCapacity(allocator, limit);
        // Elements plus the roots of kept elements share the map.
        try self.element_map.reserve(allocator, 2 * limit);
        try self.units.ensureTotalCapacity(allocator, limit);
        try self.sets.ensureTotalCapacity(allocator, limit);
        try self.families.ensureTotalCapacity(allocator, limit);
        try self.groups.ensureTotalCapacity(allocator, limit);
        try self.unit_elements.ensureTotalCapacity(allocator, limit);
        try self.group_roots.ensureTotalCapacity(allocator, limit);
        try self.group_sets.ensureTotalCapacity(allocator, limit);
        try self.root_first.ensureTotalCapacity(allocator, limit);
        try self.round_sets.ensureTotalCapacity(allocator, limit);
        try self.ensureFreeIds(allocator, fresh, pool_grows);
        // Assigned only after every reserve succeeded.
        self.element_limit = limit;
        std.debug.assert(self.elements.capacity >= limit and self.units.capacity >= limit and self.round_sets.capacity >= limit);
    }

    // Folds the endpoint counts of the world's links not yet seen into `max_chunk_endpoints`:
    // O(1) per link. Links are append-only.
    fn noteLinks(self: *Connectivity, world: ?*const WorldSystem) void {
        const world_system = world orelse return;
        const links = world_system.levelLinks();
        std.debug.assert(self.endpoint_links_seen <= links.len);
        const ct: usize = world_system.chunk_size_tiles;
        const chunks_x = (@as(usize, world_system.width) + ct - 1) / ct;
        for (links[self.endpoint_links_seen..]) |link| {
            inline for (.{ .{ link.level_a, link.cell_a }, .{ link.level_b, link.cell_b } }) |end| {
                const chunk: u32 = @intCast((end[1].y / ct) * chunks_x + end[1].x / ct);
                self.max_chunk_endpoints = @max(self.max_chunk_endpoints, world_system.levelChunkLinkEndpointCount(end[0], chunk));
            }
        }
        self.endpoint_links_seen = links.len;
    }

    // Reserves the flood's round buffers and a search table per thread participant, sized from
    // one node's slack (`border_stride` flags plus the most endpoints a chunk holds), W, and K:
    // fixed per world, never sized from its extent. Every item's window holds its budget plus
    // the slack, so a round holds at most `flood_window_limit / (1 + slack)` items, and a
    // table of twice an item's window keeps probes short. Grows only with the slack, W, K, or
    // the participant count.
    fn reserveFlood(self: *Connectivity, allocator: std.mem.Allocator, border_stride: usize, participants: usize) !void {
        const slack = border_stride + self.max_chunk_endpoints;
        const budget: u32 = @intCast(@max(@min(@as(usize, self.flood_budget_cap), self.flood_window), 1));
        const window = @max(self.flood_window, budget) + slack;
        const items = window / (1 + slack);
        const slots = try std.math.ceilPowerOfTwo(usize, 2 * (@as(usize, budget) + slack));
        try self.flood_items.ensureTotalCapacity(allocator, items);
        try self.flood_outs.ensureTotalCapacity(allocator, items);
        try self.proposals.ensureTotalCapacity(allocator, window);
        try self.flood_scratch.ensureTotalCapacity(allocator, participants);
        while (self.flood_scratch.items.len < participants) self.flood_scratch.appendAssumeCapacity(.{});
        for (self.flood_scratch.items) |*scratch| try scratch.reserve(allocator, slots);
        // Assigned only after every reserve succeeded.
        self.flood_slack = slack;
        self.flood_budget_limit = budget;
        self.flood_window_limit = window;
        self.flood_item_limit = items;
        std.debug.assert(self.flood_items.capacity >= items and self.flood_outs.capacity >= items and self.proposals.capacity >= window);
    }

    // ------------------------------------------------------------------------------------
    // Marks batch
    // ------------------------------------------------------------------------------------

    /// The fallible half of a marks batch, before any cell or record changes: flags the
    /// remasked patch keys, reserves every bound the commit uses (gather windows, node rows
    /// per level, merge staging, free comp and root ids, and, when the batch has seeds, the
    /// flood's round buffers and a search table per participant of `threads`' thread system,
    /// which the commit must share), and runs the seed stage over the changed keys (their
    /// pre-change mirrors and two-way link partners). Main work is O(1) per key and link; the
    /// seed stage threads over changed keys.
    pub fn prepareMarks(
        self: *Connectivity,
        allocator: std.mem.Allocator,
        levels: BatchLevels,
        world: ?*const WorldSystem,
        changed_keys: []const u64,
        patch_keys: []const u64,
        patch_info: []const PatchInfo,
        new_links: []const LevelLink,
        threads: ?NavStageThreads,
        closure_threads: ClosureThreads,
        pool_grows: *u64,
        stats: *NavUpdateStats,
    ) !void {
        std.debug.assert(patch_info.len == patch_keys.len);
        var section = StageTimer.begin();
        const new_link_count = new_links.len;
        // Flags and seed windows: changed keys are a sorted subset of the sorted patch keys.
        try self.patch_changed.resize(allocator, patch_keys.len);
        try self.seed_starts.resize(allocator, changed_keys.len + 1);
        try self.seed_counts.resize(allocator, changed_keys.len);
        var changed_index: usize = 0;
        var seed_total: usize = 0;
        for (patch_keys, patch_info, self.patch_changed.items) |key, info, *changed| {
            changed.* = changed_index < changed_keys.len and changed_keys[changed_index] == key;
            if (!changed.*) continue;
            self.seed_starts.items[changed_index] = seed_total;
            seed_total += levels.graph(keyLevel(key)).border_stride + info.endpoints;
            changed_index += 1;
        }
        std.debug.assert(changed_index == changed_keys.len);
        self.seed_starts.items[changed_keys.len] = seed_total;
        try self.seed_edges.resize(allocator, seed_total);

        // Gather windows: per patch key its old nodes and new labels as rows and one edge per
        // border flag and link endpoint; per new link one edge.
        const item_count = patch_keys.len + new_link_count;
        try self.row_starts.resize(allocator, item_count + 1);
        try self.edge_starts.resize(allocator, item_count + 1);
        try self.row_counts.resize(allocator, item_count);
        try self.edge_counts.resize(allocator, item_count);
        var row_total: usize = 0;
        var edge_total: usize = 0;
        for (0..item_count) |item| {
            self.row_starts.items[item] = row_total;
            self.edge_starts.items[item] = edge_total;
            if (item < patch_keys.len) {
                const level_graph = levels.graph(keyLevel(patch_keys[item]));
                const node_bound = level_graph.border_stride + patch_info[item].endpoints;
                row_total += level_graph.labelCount(keyChunk(patch_keys[item])) + node_bound;
                edge_total += node_bound;
            } else {
                edge_total += 1;
            }
        }
        self.row_starts.items[item_count] = row_total;
        self.edge_starts.items[item_count] = edge_total;
        try self.gather_rows.resize(allocator, row_total);
        try self.gather_edges.resize(allocator, edge_total);

        // Node rows: each patch key may gain up to its node bound, per level.
        var start: usize = 0;
        while (start < patch_keys.len) {
            const level = keyLevel(patch_keys[start]);
            var end = start + 1;
            while (end < patch_keys.len and keyLevel(patch_keys[end]) == level) end += 1;
            var needed: usize = 0;
            for (patch_info[start..end]) |info| needed += levels.graph(level).border_stride + info.endpoints;
            try levels.graph(level).ensureFreeNodes(allocator, needed, pool_grows);
            start = end;
        }
        // Each row is one element; a gathered edge adds at most its far end (its near end is an
        // added row, a new link's ends are patch keys' rows) and a seed edge at most both.
        const limit = row_total + edge_total + 2 * seed_total;
        try self.reserveMerge(allocator, limit, limit, pool_grows);
        // Only a removal can flood; its sets come from the seeds.
        if (seed_total != 0) {
            self.noteLinks(world);
            try self.reserveFlood(allocator, levels.graph(keyLevel(changed_keys[0])).border_stride, participantCount(threads));
        }
        var job = SeedJob{
            .levels = levels,
            .world = world,
            .keys = changed_keys,
            .changed_keys = changed_keys,
            .replaced = false,
            .starts = self.seed_starts.items,
            .counts = self.seed_counts.items,
            .edges = self.seed_edges.items,
        };
        stats.main.reserve_ns += section.lap();
        self.last_seed_batch = runStage(threads, changed_keys.len, &job, &job.range_count, seedJob);
        stats.addStageTime(self.last_seed_batch);

        // The closure reads the seed windows' counts and the graph before the change.
        section = StageTimer.begin();
        const new_oneway = countOneWay(new_links);
        self.closure.active = self.closure.oneway.len != 0 or new_oneway != 0;
        stats.main.reserve_ns += section.lap();
        const bounds: ClosureBounds = if (self.closure.active)
            try self.prepareClosure(allocator, levels, world, patch_keys, true, self.patch_changed.items, new_oneway, new_link_count, closure_threads, pool_grows, stats)
        else
            .{};
        section = StageTimer.begin();
        defer stats.main.reserve_ns += section.lap();
        self.marks_staging_high = self.marks_staging_high.max(.{
            .changed_keys = changed_keys.len,
            .patch_keys = patch_keys.len,
            .items = item_count,
            .seeds = seed_total,
            .rows = row_total,
            .edges = edge_total,
            .elements = limit,
            .cand_entries = self.closure.cand_hcomps.items.len,
            .ow_entries = self.closure.ow_entries.items.len,
            .closure_touched = bounds.candidates,
            .closure_terms = bounds.k_b,
            .closure_links = bounds.e_t,
            .closure_k_cap = bounds.k_cap_sum,
            .closure_s_words = bounds.s_words,
            .closure_copy_items = bounds.copy_items,
            .closure_round_items = bounds.round_items,
        });
    }

    /// The infallible half, after the patch re-derived every patch key's record: gathers the
    /// patch keys and new links (threaded), merges rows, unions, and groups in key order on
    /// the main thread (O(1) per row, edge, and element; union-find amortized O(α)), settles
    /// every unit no removal can split, floods the rest in rounds (searches threaded, claims
    /// merged on main in item order), and unites each root-group. Allocation-free after
    /// `prepareMarks`.
    pub fn commitMarks(
        self: *Connectivity,
        levels: BatchLevels,
        world: ?*const WorldSystem,
        patch_keys: []const u64,
        new_links: []const LevelLink,
        gather_threads: ?NavStageThreads,
        flood_threads: ?NavStageThreads,
        closure_threads: ClosureThreads,
        stats: *NavUpdateStats,
    ) ConnectivityCounters {
        var gather = GatherJob{
            .levels = levels,
            .world = world,
            .keys = patch_keys,
            .changed = self.patch_changed.items,
            .links = new_links,
            .row_starts = self.row_starts.items,
            .row_counts = self.row_counts.items,
            .rows = self.gather_rows.items,
            .edge_starts = self.edge_starts.items,
            .edge_counts = self.edge_counts.items,
            .edges = self.gather_edges.items,
        };
        self.bindOneWayWindows(&gather);
        self.last_gather_batch = runStage(gather_threads, patch_keys.len + new_links.len, &gather, &gather.range_count, gatherJob);
        stats.addStageTime(self.last_gather_batch);
        const merge_timer = StageTimer.begin();
        self.mergeBatch(levels, patch_keys, true, patch_keys.len + new_links.len, null);
        stats.main.conn_merge_ns += merge_timer.lap();
        var counters = self.settleAndFlood(levels, world, flood_threads, stats);
        if (self.closure.active) counters.closure = self.updateClosure(levels, world, patch_keys.len, closure_threads, stats);
        return counters;
    }

    // ------------------------------------------------------------------------------------
    // Level build
    // ------------------------------------------------------------------------------------

    /// Builds the connectivity of the level freshly patched into `levels.fresh`, every chunk
    /// of which is in `keys`. `replaced` holds the old records when it replaces a level: their
    /// rows leave their comps, and their two-way link partners on other levels seed the
    /// removal (read through `old_levels`). Reserves first (node rows exactly, from each
    /// record's label count; fresh ids geometrically), so an error changes nothing; then
    /// gathers, merges, settles, floods, and unites as a marks batch does. It then shrinks
    /// each staging list to the most any marks batch prepared, or one changed chunk's bound if
    /// larger; the flood's round buffers stay. O(level chunks + nodes + edges), the seed,
    /// gather, and flood stages threaded.
    pub fn buildLevel(
        self: *Connectivity,
        allocator: std.mem.Allocator,
        levels: BatchLevels,
        old_levels: BatchLevels,
        world: ?*const WorldSystem,
        keys: []const u64,
        replaced: ?*NavLevelGraph,
        seed_threads: ?NavStageThreads,
        gather_threads: ?NavStageThreads,
        flood_threads: ?NavStageThreads,
        closure_threads: ClosureThreads,
        pool_grows: *u64,
        stats: *NavUpdateStats,
    ) !ConnectivityCounters {
        const fresh = levels.fresh.?;
        const level_graph = fresh.graph;
        const seeding = replaced != null;
        var section = StageTimer.begin();
        // The staging shrinks back when the build ends, and on an error too.
        errdefer self.shrinkStaging(allocator, self.marks_staging_high.max(self.oneChunkStaging(level_graph.border_stride)));
        try self.row_starts.resize(allocator, keys.len + 1);
        try self.edge_starts.resize(allocator, keys.len + 1);
        try self.row_counts.resize(allocator, keys.len);
        try self.edge_counts.resize(allocator, keys.len);
        try self.seed_starts.resize(allocator, if (seeding) keys.len + 1 else 1);
        try self.seed_counts.resize(allocator, if (seeding) keys.len else 0);
        var labels: usize = 0;
        var edge_total: usize = 0;
        var endpoint_total: usize = 0;
        var seed_total: usize = 0;
        for (keys, 0..) |key, item| {
            const chunk = keyChunk(key);
            self.row_starts.items[item] = labels;
            self.edge_starts.items[item] = edge_total;
            if (seeding) self.seed_starts.items[item] = seed_total;
            const has_record = level_graph.recordOf(chunk) != null;
            if (!has_record and !seeding) continue;
            const endpoints: usize = if (world) |world_system| world_system.levelChunkLinkEndpointCount(fresh.index, chunk) else 0;
            if (seeding) seed_total += endpoints;
            if (!has_record) continue;
            labels += level_graph.labelCount(chunk);
            // One edge per border flag: at most one per border run (the stride), and at most
            // four per portal.
            edge_total += @min(level_graph.border_stride, 4 * level_graph.chunkPortals(chunk).border.len) + endpoints;
            endpoint_total += endpoints;
        }
        self.row_starts.items[keys.len] = labels;
        self.edge_starts.items[keys.len] = edge_total;
        self.seed_starts.items[self.seed_starts.items.len - 1] = seed_total;
        try self.gather_rows.resize(allocator, labels);
        try self.gather_edges.resize(allocator, edge_total);
        try self.seed_edges.resize(allocator, seed_total);
        // No fresh row is old, so no key reads as remasked.
        try self.patch_changed.resize(allocator, keys.len);
        @memset(self.patch_changed.items, false);
        try level_graph.ensureNodesExact(allocator, labels);
        // A mirror's far end is an added row of the level; only a link's far end, a seed's far
        // end, and the one old element standing for a replaced level add elements. Fresh ids go
        // one pair per set or rootless unit: at most the added rows plus the seeds' far ends.
        try self.reserveMerge(allocator, labels + endpoint_total + seed_total + 1, labels + seed_total + 1, pool_grows);
        if (seed_total != 0) {
            self.noteLinks(world);
            try self.reserveFlood(allocator, level_graph.border_stride, participantCount(flood_threads));
        }
        stats.main.reserve_ns += section.lap();

        if (seeding) {
            var seed = SeedJob{
                .levels = old_levels,
                .world = world,
                .keys = keys,
                .changed_keys = &.{},
                .replaced = true,
                .starts = self.seed_starts.items,
                .counts = self.seed_counts.items,
                .edges = self.seed_edges.items,
            };
            self.last_seed_batch = runStage(seed_threads, keys.len, &seed, &seed.range_count, seedJob);
            stats.addStageTime(self.last_seed_batch);
        } else {
            self.last_seed_batch = .{};
        }
        // The closure's reserves, before any connectivity changes: the candidates read the
        // replaced level's old nodes and every key's link partners on the other levels.
        self.closure.active = self.closure.oneway.len != 0;
        if (self.closure.active) _ = try self.prepareClosure(allocator, old_levels, world, keys, seeding, null, 0, 0, closure_threads, pool_grows, stats);
        var gather = GatherJob{
            .levels = levels,
            .world = world,
            .keys = keys,
            .changed = self.patch_changed.items,
            .links = &.{},
            .row_starts = self.row_starts.items,
            .row_counts = self.row_counts.items,
            .rows = self.gather_rows.items,
            .edge_starts = self.edge_starts.items,
            .edge_counts = self.edge_counts.items,
            .edges = self.gather_edges.items,
        };
        self.bindOneWayWindows(&gather);
        self.last_gather_batch = runStage(gather_threads, keys.len, &gather, &gather.range_count, gatherJob);
        stats.addStageTime(self.last_gather_batch);
        section = StageTimer.begin();
        self.mergeBatch(levels, keys, false, keys.len, replaced);
        stats.main.conn_merge_ns += section.lap();
        var counters = self.settleAndFlood(levels, world, flood_threads, stats);
        if (self.closure.active) counters.closure = self.updateClosure(levels, world, keys.len, closure_threads, stats);
        section = StageTimer.begin();
        self.shrinkStaging(allocator, self.marks_staging_high.max(self.oneChunkStaging(level_graph.border_stride)));
        stats.main.commit_ns += section.lap();
        return counters;
    }

    // ------------------------------------------------------------------------------------
    // Merge (main thread, O(1) per row, edge, and element)
    // ------------------------------------------------------------------------------------

    // The element for `key`, inserted on first sight: an old key is a removed node; any other
    // key not yet seen is a node outside the batch's keys, kept at its hinted row.
    fn elementFor(self: *Connectivity, columns: ElementColumns, key: u64, row_hint: u32) u32 {
        if (self.element_map.get(key)) |index| return index;
        if (key & old_bit != 0) return self.insertElement(columns, key, no_node, .removed);
        std.debug.assert(row_hint != no_node);
        return self.insertElement(columns, key, row_hint, .kept);
    }

    fn insertElement(self: *Connectivity, columns: ElementColumns, key: u64, row: u32, kind: ElementKind) u32 {
        std.debug.assert(self.element_count < self.element_limit);
        const index: u32 = @intCast(self.element_count);
        self.element_count += 1;
        columns.key[index] = key;
        columns.row[index] = row;
        columns.level[index] = nodeKeyLevel(key);
        columns.kind[index] = kind;
        columns.unit_parent[index] = index;
        columns.unit_size[index] = 1;
        columns.cluster_parent[index] = index;
        columns.cluster_size[index] = 1;
        columns.group_parent[index] = index;
        columns.group_size[index] = 1;
        columns.family_parent[index] = index;
        columns.family_size[index] = 1;
        columns.cluster_unit[index] = no_unit;
        columns.unit[index] = no_unit;
        columns.group[index] = no_group;
        columns.family[index] = no_family;
        columns.split[index] = false;
        self.element_map.put(key, index);
        return index;
    }

    // Takes one node off its comp on the main thread; a comp left empty leaves its root and is
    // freed, and so is a root left without comps.
    fn releaseComp(self: *Connectivity, comp: u32) void {
        std.debug.assert(self.comp_size[comp] > 0);
        self.comp_size[comp] -= 1;
        if (self.comp_size[comp] != 0) return;
        const root = self.unlinkComp(comp);
        std.debug.assert(self.comp_free.items.len < self.comp_free.capacity);
        self.comp_free.appendAssumeCapacity(comp);
        if (self.root_members[root] == 0) {
            self.releaseRootTerm(root);
            std.debug.assert(self.root_free.items.len < self.root_free.capacity);
            self.root_free.appendAssumeCapacity(root);
        }
    }

    // Detaches a freed root's terminal: the terminal keeps its H-component and index until the
    // batch's closure commit frees it, and goes on the freed list that touches its component.
    // O(1).
    fn releaseRootTerm(self: *Connectivity, root: u32) void {
        const term = self.root_term[root];
        if (term == no_term) return;
        self.root_term[root] = no_term;
        self.closure.term.root[term] = no_root;
        std.debug.assert(self.closure.freed_terms.items.len < self.closure.freed_terms.capacity);
        self.closure.freed_terms.appendAssumeCapacity(term);
    }

    // Unlinks `comp` from its root's member list; returns the root.
    fn unlinkComp(self: *Connectivity, comp: u32) u32 {
        const root = self.comp_root[comp];
        const prev = self.comp_prev[comp];
        const next = self.comp_next[comp];
        if (prev != no_comp) self.comp_next[prev] = next else self.root_head[root] = next;
        if (next != no_comp) self.comp_prev[next] = prev;
        self.root_members[root] -= 1;
        self.comp_root[comp] = no_root;
        self.comp_prev[comp] = no_comp;
        self.comp_next[comp] = no_comp;
        return root;
    }

    // Splices the comp chain from `head` to `tail` (`count` comps) into `root`'s member list,
    // clearing each comp's set. O(comps in the chain).
    fn attach(self: *Connectivity, root: u32, head: u32, tail: u32, count: u32) void {
        var comp = head;
        while (true) : (comp = self.comp_next[comp]) {
            self.comp_root[comp] = root;
            self.comp_set[comp] = no_set;
            if (comp == tail) break;
        }
        const old_head = self.root_head[root];
        self.comp_next[tail] = old_head;
        if (old_head != no_comp) self.comp_prev[old_head] = tail;
        self.comp_prev[head] = no_comp;
        self.root_head[root] = head;
        self.root_members[root] += count;
    }

    // Moves every comp of `from` under `to` and frees `from`. O(comps of `from`).
    fn moveRoot(self: *Connectivity, from: u32, to: u32) void {
        const head = self.root_head[from];
        const count = self.root_members[from];
        std.debug.assert(head != no_comp and count != 0);
        var tail = head;
        while (self.comp_next[tail] != no_comp) tail = self.comp_next[tail];
        self.root_head[from] = no_comp;
        self.root_members[from] = 0;
        self.attach(to, head, tail, count);
        self.releaseRootTerm(from);
        std.debug.assert(self.root_free.items.len < self.root_free.capacity);
        self.root_free.appendAssumeCapacity(from);
    }

    // Applies the windows in item order: frees lost rows (a replaced level's first), claims
    // added rows, and relinks each patch key's node list; unites removal clusters over the seed
    // edges and units over the gathered edges (which join nodes of the graph after the batch).
    // `marks` names a marks batch, whose remasked keys' lost rows carry old keys.
    fn mergeBatch(self: *Connectivity, levels: BatchLevels, keys: []const u64, marks: bool, gather_items: usize, replaced: ?*NavLevelGraph) void {
        self.element_map.clear();
        self.element_count = 0;
        self.elements.len = self.element_limit;
        const columns = ElementColumns.of(self.elements.slice());
        const row_starts = self.row_starts.items;
        const row_counts = self.row_counts.items;
        const gather_rows = self.gather_rows.items;
        const patch_changed = self.patch_changed.items;

        if (replaced) |old| {
            for (old.node_comp) |*comp| {
                if (comp.* == no_comp) continue;
                self.releaseComp(comp.*);
                comp.* = no_comp;
            }
        }

        for (keys, 0..) |key, item| {
            const level = keyLevel(key);
            const chunk = keyChunk(key);
            const level_graph = levels.graph(level);
            const window = gather_rows[row_starts[item]..][0..row_counts[item]];
            const record = level_graph.recordOf(chunk) orelse {
                std.debug.assert(window.len == 0);
                continue;
            };
            const remasked = marks and patch_changed[item];
            var head: u32 = no_node;
            var tail: u32 = no_node;
            for (window) |entry| {
                const row = switch (entry.kind) {
                    .removed => {
                        const element_key = if (remasked) oldKey(level, chunk, entry.label) else nodeKey(level, chunk, entry.label);
                        _ = self.insertElement(columns, element_key, entry.row, .removed);
                        self.releaseComp(level_graph.node_comp[entry.row]);
                        level_graph.releaseNode(entry.row);
                        continue;
                    },
                    .kept => entry.row,
                    .added => level_graph.claimNode(entry.label),
                };
                _ = self.insertElement(columns, nodeKey(level, chunk, entry.label), row, entry.kind);
                if (tail == no_node) head = row else level_graph.node_sibling[tail] = row;
                tail = row;
            }
            if (tail != no_node) level_graph.node_sibling[tail] = no_node;
            level_graph.record_node_head[record] = head;
        }

        const seed_starts = self.seed_starts.items;
        const seed_counts = self.seed_counts.items;
        for (seed_counts, 0..) |count, item| {
            for (self.seed_edges.items[seed_starts[item]..][0..count]) |edge| {
                const a = self.elementFor(columns, edge.a, edge.a_row);
                const b = self.elementFor(columns, edge.b, edge.b_row);
                _ = uniteBySize(columns.cluster_parent, columns.cluster_size, a, b);
            }
        }
        const edge_starts = self.edge_starts.items;
        const edge_counts = self.edge_counts.items;
        for (0..gather_items) |item| {
            for (self.gather_edges.items[edge_starts[item]..][0..edge_counts[item]]) |edge| {
                const a = self.elementFor(columns, edge.a, edge.a_row);
                const b = self.elementFor(columns, edge.b, edge.b_row);
                std.debug.assert(columns.kind[a] != .removed and columns.kind[b] != .removed);
                _ = uniteBySize(columns.unit_parent, columns.unit_size, a, b);
            }
        }
        self.elements.len = self.element_count;
    }

    // ------------------------------------------------------------------------------------
    // Layout, settle, flood, and finish (main thread, O(1) per item; the flood's searches
    // threaded)
    // ------------------------------------------------------------------------------------

    fn settleAndFlood(self: *Connectivity, levels: BatchLevels, world: ?*const WorldSystem, threads: ?NavStageThreads, stats: *NavUpdateStats) ConnectivityCounters {
        var section = StageTimer.begin();
        self.units.len = self.element_limit;
        self.sets.len = self.element_limit;
        self.families.len = self.element_limit;
        self.groups.len = self.element_limit;
        const views = BatchViews{
            .levels = levels,
            .world = world,
            .elements = ElementColumns.of(self.elements.slice()),
            .units = UnitColumns.of(self.units.slice()),
            .sets = SetColumns.of(self.sets.slice()),
            .families = FamilyColumns.of(self.families.slice()),
            .groups = GroupColumns.of(self.groups.slice()),
        };
        var counters = ConnectivityCounters{};
        self.layout(views, &counters);
        self.settle(views);
        self.openSets(views);
        self.last_flood_batch = .{};
        stats.main.conn_layout_ns += section.lap();
        if (counters.families != 0) self.runFlood(views, threads, &counters, stats);
        section = StageTimer.begin();
        self.finish(views, &counters);
        stats.main.conn_layout_ns += section.lap();
        return counters;
    }

    // Unites units sharing an old root or a removal cluster into root-groups; a cluster
    // spanning two units marks both as sets and joins their families. Numbers units, groups,
    // sets, and families on first sight in element order, and lays out each unit's elements,
    // each group's old roots and sets, and every set's and rootless unit's fresh comp and root.
    fn layout(self: *Connectivity, views: BatchViews, counters: *ConnectivityCounters) void {
        const elements = views.elements;
        const count = self.element_count;
        self.root_first.clearRetainingCapacity();
        for (0..count) |index_usize| {
            const index: u32 = @intCast(index_usize);
            if (elements.kind[index] != .kept) continue;
            const unit = findRoot(elements.unit_parent, index);
            const comp = views.levels.graph(elements.level[index]).node_comp[elements.row[index]];
            const root_key = root_bit | self.comp_root[comp];
            if (self.element_map.get(root_key)) |first_unit| {
                _ = uniteBySize(elements.group_parent, elements.group_size, unit, first_unit);
            } else {
                self.element_map.put(root_key, unit);
                self.root_first.appendAssumeCapacity(index);
            }
            const cluster = findRoot(elements.cluster_parent, index);
            const cluster_unit = elements.cluster_unit[cluster];
            if (cluster_unit == no_unit) {
                elements.cluster_unit[cluster] = unit;
            } else if (cluster_unit != unit) {
                _ = uniteBySize(elements.group_parent, elements.group_size, unit, cluster_unit);
                _ = uniteBySize(elements.family_parent, elements.family_size, unit, cluster_unit);
                elements.split[unit] = true;
                elements.split[cluster_unit] = true;
            }
        }

        const units = views.units;
        const sets = views.sets;
        const families = views.families;
        const groups = views.groups;
        var unit_total: u32 = 0;
        var group_total: u32 = 0;
        var set_total: u32 = 0;
        var family_total: u32 = 0;
        for (0..count) |index_usize| {
            const index: u32 = @intCast(index_usize);
            if (elements.kind[index] == .removed) continue;
            const unit_rep = findRoot(elements.unit_parent, index);
            if (elements.unit[unit_rep] == no_unit) {
                const group_rep = findRoot(elements.group_parent, unit_rep);
                if (elements.group[group_rep] == no_group) {
                    elements.group[group_rep] = group_total;
                    groups.root_count[group_total] = 0;
                    groups.set_count[group_total] = 0;
                    group_total += 1;
                }
                const group = elements.group[group_rep];
                const unit = unit_total;
                unit_total += 1;
                elements.unit[unit_rep] = unit;
                units.element_count[unit] = 0;
                units.group[unit] = group;
                units.set[unit] = no_set;
                units.first_kept[unit] = no_element;
                units.fresh_comp[unit] = no_comp;
                units.fresh_root[unit] = no_root;
                if (elements.split[unit_rep]) {
                    const family_rep = findRoot(elements.family_parent, unit_rep);
                    if (elements.family[family_rep] == no_family) {
                        const family = family_total;
                        family_total += 1;
                        elements.family[family_rep] = family;
                        families.parent[family] = family;
                        families.size[family] = 1;
                        families.active[family] = 0;
                        families.target[family] = 0;
                        families.served[family] = no_round;
                        families.set_head[family] = no_set;
                        families.set_tail[family] = no_set;
                        families.pass_next[family] = no_set;
                    }
                    const family = elements.family[family_rep];
                    const set = set_total;
                    set_total += 1;
                    units.set[unit] = set;
                    sets.parent[set] = set;
                    sets.size[set] = 1;
                    sets.claimed[set] = 0;
                    sets.family[set] = family;
                    sets.unit[set] = unit;
                    sets.group[set] = group;
                    sets.active[set] = true;
                    // Appended to the family's active list, in set order.
                    sets.prev_active[set] = families.set_tail[family];
                    sets.next_active[set] = no_set;
                    if (families.set_tail[family] == no_set) families.set_head[family] = set else sets.next_active[families.set_tail[family]] = set;
                    families.set_tail[family] = set;
                    families.active[family] += 1;
                    groups.set_count[group] += 1;
                }
            }
            const unit = elements.unit[unit_rep];
            elements.unit[index] = unit;
            units.element_count[unit] += 1;
            if (elements.kind[index] == .kept and units.first_kept[unit] == no_element) units.first_kept[unit] = index;
        }
        self.units.len = unit_total;
        self.sets.len = set_total;
        self.families.len = family_total;
        self.groups.len = group_total;
        counters.groups = group_total;
        counters.families = family_total;

        // Each unit's elements, in element order.
        var offset: u32 = 0;
        for (units.element_start[0..unit_total], units.element_count[0..unit_total]) |*start, *element_count| {
            start.* = offset;
            offset += element_count.*;
            element_count.* = 0;
        }
        self.unit_elements.items.len = offset;
        for (0..count) |index| {
            if (elements.kind[index] == .removed) continue;
            const unit = elements.unit[index];
            self.unit_elements.items[units.element_start[unit] + units.element_count[unit]] = @intCast(index);
            units.element_count[unit] += 1;
        }
        // Each group's old roots, in first-seen order.
        for (self.root_first.items) |index| groups.root_count[units.group[elements.unit[index]]] += 1;
        offset = 0;
        for (groups.root_start[0..group_total], groups.root_count[0..group_total]) |*start, *root_count| {
            start.* = offset;
            offset += root_count.*;
            root_count.* = 0;
        }
        self.group_roots.items.len = offset;
        for (self.root_first.items) |index| {
            const group = units.group[elements.unit[index]];
            const comp = views.levels.graph(elements.level[index]).node_comp[elements.row[index]];
            self.group_roots.items[groups.root_start[group] + groups.root_count[group]] = self.comp_root[comp];
            groups.root_count[group] += 1;
        }
        // Each group's sets, in set order.
        offset = 0;
        for (groups.set_start[0..group_total], groups.set_count[0..group_total]) |*start, *set_count| {
            start.* = offset;
            offset += set_count.*;
            set_count.* = 0;
        }
        self.group_sets.items.len = offset;
        for (sets.group[0..set_total], 0..) |group, set| {
            self.group_sets.items[groups.set_start[group] + groups.set_count[group]] = @intCast(set);
            groups.set_count[group] += 1;
        }
        // Fresh ids in unit order: a comp and a root per set and per rootless unit.
        for (0..unit_total) |unit| {
            const set = units.set[unit];
            if (set == no_set and units.first_kept[unit] != no_element) continue;
            // The batch reserve covered every fresh id.
            const comp = self.comp_free.pop().?;
            const root = self.root_free.pop().?;
            self.comp_root[comp] = no_root;
            self.comp_size[comp] = 0;
            self.comp_prev[comp] = no_comp;
            self.comp_next[comp] = no_comp;
            self.comp_set[comp] = no_set;
            self.root_head[root] = no_comp;
            self.root_members[root] = 0;
            self.root_term[root] = no_term;
            if (set == no_set) {
                units.fresh_comp[unit] = comp;
                units.fresh_root[unit] = root;
            } else {
                sets.own_comp[set] = comp;
                sets.fresh_root[set] = root;
            }
        }
    }

    // Every unit no cluster spans with another settles here: its added nodes join the comp of
    // its first kept node, or one fresh comp under one fresh root when it has none (a piece new
    // to the graph, alone in its root-group). O(1) per element.
    fn settle(self: *Connectivity, views: BatchViews) void {
        const units = views.units;
        const elements = views.elements;
        for (0..self.units.len) |unit| {
            if (units.set[unit] != no_set) continue;
            const first_kept = units.first_kept[unit];
            const comp = if (first_kept != no_element)
                views.levels.graph(elements.level[first_kept]).node_comp[elements.row[first_kept]]
            else blk: {
                const fresh = units.fresh_comp[unit];
                self.attach(units.fresh_root[unit], fresh, fresh, 1);
                break :blk fresh;
            };
            for (self.unit_elements.items[units.element_start[unit]..][0..units.element_count[unit]]) |element| {
                if (elements.kind[element] != .added) continue;
                views.levels.graph(elements.level[element]).node_comp[elements.row[element]] = comp;
                self.comp_size[comp] += 1;
            }
        }
    }

    // Every set claims its unit's nodes into its own fresh comp and queues them.
    fn openSets(self: *Connectivity, views: BatchViews) void {
        const sets = views.sets;
        const units = views.units;
        const elements = views.elements;
        for (0..self.sets.len) |set_usize| {
            const set: u32 = @intCast(set_usize);
            const own = sets.own_comp[set];
            self.comp_set[own] = set;
            sets.head_key[set] = no_key;
            sets.head_row[set] = no_node;
            sets.tail_key[set] = no_key;
            sets.tail_row[set] = no_node;
            sets.comp_head[set] = own;
            sets.comp_tail[set] = own;
            sets.comp_count[set] = 1;
            const unit = sets.unit[set];
            for (self.unit_elements.items[units.element_start[unit]..][0..units.element_count[unit]]) |element| {
                std.debug.assert(elements.kind[element] != .removed);
                self.claim(views, set, elements.key[element], elements.level[element], elements.row[element], true);
            }
        }
    }

    // Moves the node at (`level`, `row`), key `key`, into representative `set`'s own comp, and
    // onto its queue when `enqueue` (a node a search already expanded is not). O(1).
    fn claim(self: *Connectivity, views: BatchViews, set: u32, key: u64, level: u16, row: u32, enqueue: bool) void {
        const sets = views.sets;
        const level_graph = views.levels.graph(level);
        const comp = &level_graph.node_comp[row];
        if (comp.* != no_comp) self.releaseComp(comp.*);
        const own = sets.own_comp[set];
        comp.* = own;
        self.comp_size[own] += 1;
        sets.claimed[set] += 1;
        level_graph.node_queue[row] = no_key;
        level_graph.node_queue_row[row] = no_node;
        if (!enqueue) return;
        if (sets.tail_key[set] == no_key) {
            sets.head_key[set] = key;
            sets.head_row[set] = row;
        } else {
            const tail_graph = views.levels.graph(nodeKeyLevel(sets.tail_key[set]));
            tail_graph.node_queue[sets.tail_row[set]] = key;
            tail_graph.node_queue_row[sets.tail_row[set]] = row;
        }
        sets.tail_key[set] = key;
        sets.tail_row[set] = row;
    }

    // Removes active set `set` from its family's list; a pass cursor on it moves to the next.
    fn unlinkActive(views: BatchViews, family: u32, set: u32) void {
        const sets = views.sets;
        const families = views.families;
        const prev = sets.prev_active[set];
        const next = sets.next_active[set];
        if (families.pass_next[family] == set) families.pass_next[family] = next;
        if (prev != no_set) sets.next_active[prev] = next else families.set_head[family] = next;
        if (next != no_set) sets.prev_active[next] = prev else families.set_tail[family] = prev;
        sets.prev_active[set] = no_set;
        sets.next_active[set] = no_set;
    }

    // Joins active sets `a` and `b` (representatives) by size: queues and comp chains
    // concatenate and claimed counts add; their families unite by size, keeping the larger
    // target and the kept family's pass (the other's when the kept one's ended; a pass walks
    // the appended sets, and a set it passed is checked when the pass ends), and the family
    // loses one active set.
    // Returns how the count of families with two or more active sets changed. O(1)/O(α).
    fn joinSets(views: BatchViews, a: u32, b: u32) i32 {
        const sets = views.sets;
        const families = views.families;
        std.debug.assert(sets.active[a] and sets.active[b]);
        const family_a = findRoot(families.parent, sets.family[a]);
        const family_b = findRoot(families.parent, sets.family[b]);
        var live_before: i32 = @intFromBool(families.active[family_a] >= 2);
        if (family_b != family_a) live_before += @intFromBool(families.active[family_b] >= 2);
        const keep = uniteBySize(sets.parent, sets.size, a, b);
        const fold = if (keep == a) b else a;
        sets.active[fold] = false;
        sets.claimed[keep] += sets.claimed[fold];
        if (sets.head_key[fold] != no_key) {
            if (sets.tail_key[keep] == no_key) {
                sets.head_key[keep] = sets.head_key[fold];
                sets.head_row[keep] = sets.head_row[fold];
            } else {
                const tail_graph = views.levels.graph(nodeKeyLevel(sets.tail_key[keep]));
                tail_graph.node_queue[sets.tail_row[keep]] = sets.head_key[fold];
                tail_graph.node_queue_row[sets.tail_row[keep]] = sets.head_row[fold];
            }
            sets.tail_key[keep] = sets.tail_key[fold];
            sets.tail_row[keep] = sets.tail_row[fold];
        }
        const fold_family = findRoot(families.parent, sets.family[fold]);
        unlinkActive(views, fold_family, fold);
        var family = family_a;
        if (family_b != family_a) {
            family = uniteBySize(families.parent, families.size, family_a, family_b);
            const other = if (family == family_a) family_b else family_a;
            families.active[family] += families.active[other];
            families.target[family] = @max(families.target[family], families.target[other]);
            // The other family's active sets follow this one's.
            if (families.set_head[other] != no_set) {
                if (families.set_tail[family] == no_set) {
                    families.set_head[family] = families.set_head[other];
                } else {
                    sets.next_active[families.set_tail[family]] = families.set_head[other];
                    sets.prev_active[families.set_head[other]] = families.set_tail[family];
                }
                families.set_tail[family] = families.set_tail[other];
            }
            if (families.pass_next[family] == no_set) families.pass_next[family] = families.pass_next[other];
            families.set_head[other] = no_set;
            families.set_tail[other] = no_set;
            families.pass_next[other] = no_set;
            families.active[other] = 0;
        }
        families.active[family] -= 1;
        return @as(i32, @intFromBool(families.active[family] >= 2)) - live_before;
    }

    // Floods the sets in rounds while a family holds two or more active sets. Each round
    // serves families from the cursor in family order. A family serves in passes over its
    // active sets: a pass starts once the last one ended, with one scan that advances the
    // target to the smallest claimed count plus half that (at least 1, at most
    // `flood_budget_limit`) when every active set reached it; each set the pass walks below the
    // target detaches its queue into one item whose budget is the gap, within
    // `flood_window_limit` proposal slots per round (the rest of a pass that does not fit waits
    // and is served first next round; a pass wider than a round resumes at its cursor), so
    // the main thread walks each active set O(1) times per pass. Workers search
    // the items (`conn_flood`, read-only); the main thread merges them in item order (each
    // unexpanded queue spliced back, then claims and joins) and closes every served set left
    // with an empty queue (a whole component) while its family keeps another active set. One
    // thread profile serves every round of the batch, recorded once.
    fn runFlood(self: *Connectivity, views: BatchViews, threads: ?NavStageThreads, counters: *ConnectivityCounters, stats: *NavUpdateStats) void {
        // Builds, merges, and closes: every span between the rounds' searches.
        var section = StageTimer.begin();
        const families = views.families;
        const sets = views.sets;
        const family_count: u32 = @intCast(self.families.len);
        const slack = self.flood_slack;
        const budget_limit = self.flood_budget_limit;
        std.debug.assert(budget_limit != 0 and self.flood_window_limit >= budget_limit + slack);
        // The prepare reserved a search table per participant of the same thread system.
        std.debug.assert(participantCount(threads) <= self.flood_scratch.items.len);
        // Every family starts on the circular list with two or more active sets.
        var live: i32 = 0;
        for (0..family_count) |family_usize| {
            const family: u32 = @intCast(family_usize);
            std.debug.assert(families.active[family] >= 2);
            families.list_next[family] = if (family + 1 == family_count) 0 else family + 1;
            families.list_prev[family] = if (family == 0) family_count - 1 else family - 1;
            live += 1;
        }
        var list_len: u32 = family_count;
        var cursor: u32 = 0;
        var round: u32 = 0;
        var dispatch = RoundDispatch.begin(threads, self.sets.len);
        while (live > 0) : (round += 1) {
            // Build.
            self.flood_items.clearRetainingCapacity();
            self.round_sets.clearRetainingCapacity();
            var window_total: usize = 0;
            var entry = cursor;
            var visited: u32 = 0;
            build: while (visited < list_len) {
                const next = families.list_next[entry];
                const family = findRoot(families.parent, entry);
                if (families.active[family] < 2 or families.served[family] == round) {
                    // Finished, or merged into a family this round already served: every
                    // family still flooding keeps another entry.
                    const prev = families.list_prev[entry];
                    families.list_next[prev] = next;
                    families.list_prev[next] = prev;
                    list_len -= 1;
                    entry = next;
                    continue;
                }
                // At most two walks: a resumed pass that serves nothing ends, and the scan that
                // starts the next pass leaves a set below the target.
                var scanned = false;
                while (true) {
                    if (families.pass_next[family] == no_set) {
                        std.debug.assert(!scanned);
                        scanned = true;
                        var smallest: u32 = std.math.maxInt(u32);
                        var reached = true;
                        var scan = families.set_head[family];
                        while (scan != no_set) : (scan = sets.next_active[scan]) {
                            counters.build_visits += 1;
                            smallest = @min(smallest, sets.claimed[scan]);
                            reached = reached and sets.claimed[scan] >= families.target[family];
                        }
                        if (reached) families.target[family] = smallest + std.math.clamp(smallest / 2, 1, budget_limit);
                        families.pass_next[family] = families.set_head[family];
                    }
                    const target = families.target[family];
                    if (self.flood_items.items.len != 0) {
                        // The rest of the pass waits for a round of its own unless it fits.
                        var window_need: usize = 0;
                        var pending = families.pass_next[family];
                        while (pending != no_set) : (pending = sets.next_active[pending]) {
                            counters.build_visits += 1;
                            if (sets.claimed[pending] < target) window_need += @min(target - sets.claimed[pending], budget_limit) + slack;
                            if (window_total + window_need > self.flood_window_limit) break :build;
                        }
                    }
                    families.served[family] = round;
                    const items_before = self.flood_items.items.len;
                    var set = families.pass_next[family];
                    while (set != no_set) : (set = sets.next_active[set]) {
                        counters.build_visits += 1;
                        std.debug.assert(sets.active[set]);
                        const claimed = sets.claimed[set];
                        if (claimed >= target) continue;
                        const budget = @min(target - claimed, budget_limit);
                        // Only a family wider than a whole round stops here; its pass resumes
                        // at this set next round.
                        if (window_total + budget + slack > self.flood_window_limit) {
                            families.pass_next[family] = set;
                            break :build;
                        }
                        // An active set of a flooding family holds an unexpanded node.
                        std.debug.assert(sets.head_key[set] != no_key);
                        std.debug.assert(self.flood_items.items.len < self.flood_item_limit);
                        self.round_sets.appendAssumeCapacity(set);
                        self.flood_items.appendAssumeCapacity(.{
                            .set = set,
                            .budget = budget,
                            .head_key = sets.head_key[set],
                            .head_row = sets.head_row[set],
                            .tail_key = sets.tail_key[set],
                            .tail_row = sets.tail_row[set],
                            .window_start = @intCast(window_total),
                            .window_len = @intCast(budget + slack),
                        });
                        sets.head_key[set] = no_key;
                        sets.head_row[set] = no_node;
                        sets.tail_key[set] = no_key;
                        sets.tail_row[set] = no_node;
                        window_total += budget + slack;
                    }
                    families.pass_next[family] = no_set;
                    if (self.flood_items.items.len != items_before) break;
                }
                visited += 1;
                entry = next;
            }
            cursor = entry;
            std.debug.assert(list_len != 0);

            // Search.
            const item_count = self.flood_items.items.len;
            std.debug.assert(item_count != 0);
            self.flood_outs.items.len = item_count;
            self.proposals.items.len = window_total;
            var job = FloodJob{
                .levels = views.levels,
                .world = views.world,
                .items = self.flood_items.items,
                .outs = self.flood_outs.items,
                .proposals = self.proposals.items,
                .scratch = self.flood_scratch.items,
                .comp_set = self.comp_set,
                .set_parent = sets.parent,
            };
            stats.main.flood_ns += section.lap();
            dispatch.run(item_count, &job, &job.range_count, floodJob);
            section = StageTimer.begin();

            // Merge, in item order.
            for (self.flood_items.items, self.flood_outs.items) |item, out| {
                counters.flood_nodes += out.expansions;
                var mine = findRoot(sets.parent, item.set);
                if (out.resume_key != no_key) spliceQueue(views, mine, out.resume_key, out.resume_row, item.tail_key, item.tail_row);
                for (self.proposals.items[item.window_start..][0..out.written], 0..) |proposal, index| {
                    const level = nodeKeyLevel(proposal.key);
                    const owner = self.comp_set[views.levels.graph(level).node_comp[proposal.row]];
                    if (owner == no_set) {
                        // A proposal the search expanded itself is claimed but not queued.
                        self.claim(views, mine, proposal.key, level, proposal.row, index >= out.expanded);
                        continue;
                    }
                    const theirs = findRoot(sets.parent, owner);
                    if (theirs == mine) continue;
                    live += self.joinSetsWithChains(views, mine, theirs);
                    mine = findRoot(sets.parent, mine);
                }
            }

            // Close.
            for (self.round_sets.items) |set| {
                if (!sets.active[set] or sets.head_key[set] != no_key) continue;
                const family = findRoot(families.parent, sets.family[set]);
                if (families.active[family] < 2) continue;
                unlinkActive(views, family, set);
                sets.active[set] = false;
                families.active[family] -= 1;
                if (families.active[family] == 1) live -= 1;
                self.attach(sets.fresh_root[set], sets.comp_head[set], sets.comp_tail[set], sets.comp_count[set]);
                counters.splits += 1;
            }
        }
        counters.rounds = round;
        counters.round_items_min = dispatch.round_items_min;
        counters.round_items_max = dispatch.round_items_max;
        counters.flood_off_main_ns = dispatch.off_main_ns;
        self.last_flood_batch = dispatch.finish(self.sets.len);
        stats.off_main_stage_ns += dispatch.off_main_ns;
        stats.inline_stage_ns += dispatch.inline_ns;
        stats.main.flood_ns += section.lap();
    }

    // Appends the linked queue segment from (`head_key`, `head_row`) to (`tail_key`,
    // `tail_row`) to representative `set`'s queue. O(1).
    fn spliceQueue(views: BatchViews, set: u32, head_key: u64, head_row: u32, tail_key: u64, tail_row: u32) void {
        const sets = views.sets;
        if (sets.tail_key[set] == no_key) {
            sets.head_key[set] = head_key;
            sets.head_row[set] = head_row;
        } else {
            const tail_graph = views.levels.graph(nodeKeyLevel(sets.tail_key[set]));
            tail_graph.node_queue[sets.tail_row[set]] = head_key;
            tail_graph.node_queue_row[sets.tail_row[set]] = head_row;
        }
        sets.tail_key[set] = tail_key;
        sets.tail_row[set] = tail_row;
        const end_graph = views.levels.graph(nodeKeyLevel(tail_key));
        end_graph.node_queue[tail_row] = no_key;
        end_graph.node_queue_row[tail_row] = no_node;
    }

    // `joinSets` plus the comp-chain splice, which needs the comp columns.
    fn joinSetsWithChains(self: *Connectivity, views: BatchViews, a: u32, b: u32) i32 {
        const sets = views.sets;
        const chain = [2]struct { head: u32, tail: u32, count: u32 }{
            .{ .head = sets.comp_head[a], .tail = sets.comp_tail[a], .count = sets.comp_count[a] },
            .{ .head = sets.comp_head[b], .tail = sets.comp_tail[b], .count = sets.comp_count[b] },
        };
        const live_change = joinSets(views, a, b);
        const keep = findRoot(sets.parent, a);
        const first = if (keep == a) chain[0] else chain[1];
        const second = if (keep == a) chain[1] else chain[0];
        self.comp_next[first.tail] = second.head;
        self.comp_prev[second.head] = first.tail;
        sets.comp_head[keep] = first.head;
        sets.comp_tail[keep] = second.tail;
        sets.comp_count[keep] = first.count + second.count;
        return live_change;
    }

    // Per root-group in group order: every old root still holding comps unites into the one
    // with the most (the first on ties), one O(1) move per comp; every open set attaches to the
    // result, or to the first open set's fresh root when no old root is left; fresh roots no
    // set took are freed.
    fn finish(self: *Connectivity, views: BatchViews, counters: *ConnectivityCounters) void {
        const groups = views.groups;
        const sets = views.sets;
        for (0..self.groups.len) |group| {
            const roots = self.group_roots.items[groups.root_start[group]..][0..groups.root_count[group]];
            var target: ?u32 = null;
            for (roots) |root| {
                if (self.root_members[root] == 0) continue;
                if (target == null or self.root_members[root] > self.root_members[target.?]) target = root;
            }
            if (target) |largest| {
                for (roots) |root| {
                    if (root == largest or self.root_members[root] == 0) continue;
                    self.moveRoot(root, largest);
                    counters.merges += 1;
                }
            }
            for (self.group_sets.items[groups.set_start[group]..][0..groups.set_count[group]]) |set| {
                if (sets.active[set]) {
                    const root = target orelse sets.fresh_root[set];
                    target = root;
                    self.attach(root, sets.comp_head[set], sets.comp_tail[set], sets.comp_count[set]);
                }
            }
            for (self.group_sets.items[groups.set_start[group]..][0..groups.set_count[group]]) |set| {
                const fresh_root = sets.fresh_root[set];
                if (self.root_members[fresh_root] != 0) continue;
                std.debug.assert(self.root_free.items.len < self.root_free.capacity);
                self.root_free.appendAssumeCapacity(fresh_root);
            }
        }
    }

    // ------------------------------------------------------------------------------------
    // One-way closure: registry
    // ------------------------------------------------------------------------------------

    /// Reserves the registry rows of `new_links`, the world links past the registry's cursor
    /// that the next commit registers: a link-map entry each and a row per one-way link.
    /// Growth is geometric and counted in `pool_grows`. O(1) per link; registers nothing.
    pub fn reserveRegistry(self: *Connectivity, allocator: std.mem.Allocator, new_links: []const LevelLink, pool_grows: *u64) !void {
        const closure = &self.closure;
        const oneway_total = closure.oneway.len + countOneWay(new_links);
        if (oneway_total >= no_oneway) return error.NavConnectivityOverflow;
        const link_total = closure.oneway_cursor + new_links.len;
        if (link_total > closure.oneway_of_link.capacity) {
            try closure.oneway_of_link.ensureTotalCapacity(allocator, link_total);
            pool_grows.* += 1;
        }
        if (oneway_total > closure.oneway.capacity) {
            try closure.oneway.ensureTotalCapacity(allocator, oneway_total);
            pool_grows.* += 1;
        }
    }

    /// Registers `new_links`, the world links from the registry's cursor on; each one-way link
    /// stays dead until a batch resolves it. Allocation-free after `reserveRegistry`. O(1) per
    /// link.
    pub fn appendRegistry(self: *Connectivity, new_links: []const LevelLink) void {
        const closure = &self.closure;
        for (new_links, closure.oneway_cursor..) |link, link_index| {
            if (link.bidirectional) {
                closure.oneway_of_link.appendAssumeCapacity(no_oneway);
                continue;
            }
            // Below `no_oneway`: the reserve checked the row count.
            closure.oneway_of_link.appendAssumeCapacity(@intCast(closure.oneway.len));
            // World links stay below 2^31 (two endpoint entries each in a u32 list).
            closure.oneway.appendAssumeCapacity(.{ .link = @intCast(link_index), .hcomp = no_hcomp, .next = no_oneway, .src_term = no_term, .dst_term = no_term, .stamp = 0 });
        }
        closure.oneway_cursor += new_links.len;
    }

    /// Builds the closure of a freshly built world: registers every world link, resolves the
    /// one-way ones on the built levels, and builds every H-component's matrix in an arena
    /// reserved exactly, then shrinks the staging as a level build does. Allocates; on error
    /// the caller discards the graph. Resolution
    /// O(links) threaded, Tarjan O(terminals + links) per component, rows
    /// O((terminals + links) * row words) threaded.
    pub fn buildClosure(self: *Connectivity, allocator: std.mem.Allocator, levels: BatchLevels, world: ?*const WorldSystem, threads: ClosureThreads, pool_grows: *u64, stats: *NavUpdateStats) !ClosureCounters {
        const world_system = world orelse return .{};
        const new_links = world_system.levelLinks()[self.closure.oneway_cursor..];
        try self.reserveRegistry(allocator, new_links, pool_grows);
        self.appendRegistry(new_links);
        const links = self.closure.oneway.len;
        if (links == 0) return .{};
        self.advanceStamp();
        // Every terminal is new, at most two per link, and every link is loose.
        var bounds = ClosureBounds{ .e_t = links, .loose = links, .n_gross = 2 * links, .n_net = 2 * links, .merge = true };
        try boundBatch(&bounds, &.{}, self.closure.hcomp);
        try self.reserveClosure(allocator, bounds, pool_grows);
        const closure = &self.closure;
        closure.active = true;
        defer closure.active = false;
        closure.freed_terms.clearRetainingCapacity();
        closure.touched.len = 0;
        closure.resolve_items.clearRetainingCapacity();
        for (0..links) |row| closure.resolve_items.appendAssumeCapacity(@intCast(row));
        var counters = ClosureCounters{};
        self.resolveLinks(levels, world, threads.resolve, stats);
        const merge_timer = StageTimer.begin();
        self.mergeResolved(&counters);
        stats.main.closure_ns += merge_timer.lap();
        // The arena, exactly: every piece takes a new block.
        var words: usize = closure.words.items.len;
        const pieces = closure.pieces.slice();
        for (pieces.items(.k_cap)) |k_cap| words += blockWords(k_cap);
        if (words >= std.math.maxInt(u32)) return error.NavConnectivityOverflow;
        try closure.words.ensureTotalCapacityPrecise(allocator, words);
        closure.arena_limit = words;
        std.debug.assert(closure.words.capacity >= closure.arena_limit);
        self.finishClosure(threads, &counters, stats);
        // The staging sized to every link goes back to what a marks batch needs, as after a
        // level build.
        self.shrinkStaging(allocator, self.marks_staging_high.max(self.oneChunkStaging(levels.graph(0).border_stride)));
        return counters;
    }

    // ------------------------------------------------------------------------------------
    // One-way closure: prepare
    // ------------------------------------------------------------------------------------

    fn advanceStamp(self: *Connectivity) void {
        const closure = &self.closure;
        if (closure.stamp >= std.math.maxInt(u32) - 3) {
            @memset(closure.hcomp.stamp, 0);
            @memset(closure.oneway.items(.stamp), 0);
            closure.stamp = 0;
        }
        closure.stamp += 2;
    }

    // The closure's prepare over a batch's `keys`, before any record changes: per key its
    // gather one-way window (its link endpoints) and, when the registry holds a link, the
    // candidate scan (`conn_candidates`): the H-components of the old nodes' terminals when
    // `old_nodes`, of the registered one-way endpoints' links, and of every endpoint
    // partner's terminal, read through `levels` before the change, and the key's tallies.
    // `changed` flags a marks batch's remasked keys; null is a level build, whose every key
    // changed. Then on the main thread the candidates deduped by stamp in key order and
    // compacted, the tallies and the seed edges whose kept far end's root holds a terminal
    // summed, the batch bound, and its reserves, the arena compacted first when needed. O(1)
    // per key, candidate entry, seed edge, and distinct candidate on the main thread.
    fn prepareClosure(
        self: *Connectivity,
        allocator: std.mem.Allocator,
        levels: BatchLevels,
        world: ?*const WorldSystem,
        keys: []const u64,
        old_nodes: bool,
        changed: ?[]const bool,
        new_oneway: usize,
        new_link_count: usize,
        threads: ClosureThreads,
        pool_grows: *u64,
        stats: *NavUpdateStats,
    ) !ClosureBounds {
        var section = StageTimer.begin();
        defer stats.main.reserve_ns += section.lap();
        const closure = &self.closure;
        self.advanceStamp();
        const scan = closure.oneway.len != 0;
        try closure.ow_starts.resize(allocator, keys.len + 1);
        try closure.ow_counts.resize(allocator, keys.len);
        if (scan) {
            try closure.cand_starts.resize(allocator, keys.len + 1);
            try closure.cand_counts.resize(allocator, keys.len);
            try closure.cand_tallies.resize(allocator, keys.len);
        }
        var ow_total: usize = 0;
        var cand_total: usize = 0;
        for (keys, 0..) |key, item| {
            const endpoints: usize = if (world) |world_system| world_system.levelChunkLinkEndpointCount(keyLevel(key), keyChunk(key)) else 0;
            closure.ow_starts.items[item] = ow_total;
            ow_total += endpoints;
            if (!scan) continue;
            closure.cand_starts.items[item] = cand_total;
            const old_labels: usize = if (old_nodes and levels.built(keyLevel(key))) levels.graph(keyLevel(key)).labelCount(keyChunk(key)) else 0;
            // An old node names at most one component, an endpoint its link's and its partner's.
            cand_total += old_labels + 2 * endpoints;
        }
        closure.ow_starts.items[keys.len] = ow_total;
        try closure.ow_entries.resize(allocator, ow_total);

        // Every new link is loose, and each end of a new one-way link may pop a terminal.
        var bounds = ClosureBounds{ .loose = new_oneway, .live_prepared = closure.live_words };
        var revived_gross: usize = 0;
        var revived_net: usize = 0;
        var shared: usize = 2 * new_oneway;
        var opened = false;
        var distinct: usize = 0;
        if (scan) {
            closure.cand_starts.items[keys.len] = cand_total;
            try closure.cand_hcomps.resize(allocator, cand_total);
            var job = CandidateJob{
                .levels = levels,
                .world = world,
                .keys = keys,
                .old_nodes = old_nodes,
                .changed = changed orelse &.{},
                .all_changed = changed == null,
                .oneway_of_link = closure.oneway_of_link.items,
                .oneway_hcomp = closure.oneway.items(.hcomp),
                .oneway_cursor = closure.oneway_cursor,
                .comp_root = self.comp_root,
                .root_term = self.root_term,
                .term_hcomp = closure.term.hcomp,
                .starts = closure.cand_starts.items,
                .counts = closure.cand_counts.items,
                .hcomps = closure.cand_hcomps.items,
                .tallies = closure.cand_tallies.items,
            };
            stats.main.reserve_ns += section.lap();
            const batch = runStage(threads.candidates, keys.len, &job, &job.range_count, candidateJob);
            section = StageTimer.begin();
            accumulateBatch(&stats.conn_candidates_batch, batch);
            stats.addStageTime(batch);
            // Distinct candidates move to the front in first-sight order; a write never
            // passes the entry being read.
            const hcomp = closure.hcomp;
            const cand_stamp = closure.stamp;
            for (closure.cand_counts.items, closure.cand_tallies.items, 0..) |count, tally, item| {
                bounds.loose += tally.loose;
                revived_gross += tally.new_gross;
                revived_net += tally.new_net;
                shared += tally.split;
                opened = opened or tally.opened;
                for (closure.cand_hcomps.items[closure.cand_starts.items[item]..][0..count]) |id| {
                    if (hcomp.stamp[id] == cand_stamp) continue;
                    hcomp.stamp[id] = cand_stamp;
                    closure.cand_hcomps.items[distinct] = id;
                    distinct += 1;
                    bounds.candidates += 1;
                    bounds.k_c += hcomp.k_live[id];
                    bounds.e_c += hcomp.link_count[id];
                    bounds.k_cap_sum += hcomp.k_cap[id];
                    bounds.s_words += rowWords(hcomp.k_cap[id]);
                    bounds.candidate_words += blockWords(hcomp.k_cap[id]);
                }
            }
            // A kept element joins a removal cluster only as a seed's far end, so each split-off
            // part of a terminal root holding kept nodes takes one such seed edge.
            for (self.seed_counts.items, self.seed_starts.items[0..self.seed_counts.items.len]) |count, start| {
                for (self.seed_edges.items[start..][0..count]) |edge| {
                    if (edge.b_row == no_node) continue;
                    const comp = levels.graph(nodeKeyLevel(edge.b)).node_comp[edge.b_row];
                    shared += @intFromBool(self.root_term[self.comp_root[comp]] != no_term);
                }
            }
        } else {
            closure.cand_hcomps.clearRetainingCapacity();
        }
        bounds.e_t = bounds.e_c + bounds.loose;
        bounds.n_gross = revived_gross + shared;
        bounds.n_net = revived_net + shared;
        // Components merge only through a nav opening, a new link, or a level build.
        bounds.merge = opened or new_link_count != 0 or changed == null;
        try boundBatch(&bounds, closure.cand_hcomps.items[0..distinct], closure.hcomp);
        try self.reserveClosure(allocator, bounds, pool_grows);
        // A batch that can touch no component still reclaims dead blocks.
        if (bounds.k_b != 0 or closure.dead_words > closure.live_words) {
            // The arena reserve times its own sections.
            stats.main.reserve_ns += section.lap();
            try self.reserveArena(allocator, if (bounds.k_b == 0) 0 else bounds.arena_tail, threads.compact, pool_grows, stats);
            section = StageTimer.begin();
        }
        return bounds;
    }

    // The batch bound from `bounds`' counts, O(1) per distinct candidate in `ids`. Slots are
    // old terminals plus pops, each an end of a resolved live link; a piece holds a live link.
    // Pieces span candidates only when a merge is possible: then every candidate joins one
    // group, else each is its own. A group's relocated pieces take blocks of at most `Q`
    // indices whose caps sum to at most its mass, and the net new terminals add two indices
    // each at the widest `Q`.
    fn boundBatch(bounds: *ClosureBounds, ids: []const u32, hcomp: HCompColumns) !void {
        bounds.k_b = @min(bounds.k_c + bounds.n_gross, 2 * bounds.e_t);
        bounds.pieces = @min(bounds.k_b, bounds.e_t);
        var sums = BoundSums{};
        if (ids.len >= 2 and bounds.merge) {
            var group = BoundGroup{ .k_cap = std.math.maxInt(u32) };
            for (ids) |id| group.join(BoundGroup.of(hcomp, id));
            try sums.add(group, bounds.n_net);
        } else {
            for (ids) |id| try sums.add(BoundGroup.of(hcomp, id), bounds.n_net);
        }
        const q_max = if (ids.len == 0) try boundCap(@max(1, bounds.n_net)) else sums.q_max;
        const w_max = @max(sums.w_max, spanCount(q_max));
        const row_max: usize = rowWords(q_max);
        bounds.q_max = q_max;
        bounds.arena_tail = sums.tail + 2 * bounds.n_net * (row_max + 1) + span_words * bounds.pieces;
        bounds.round_items = sums.rounds + bounds.n_gross * w_max;
        bounds.copy_items = sums.copies + 2 * bounds.n_net * spanCount(q_max) + bounds.pieces;
    }

    // Reserves every staging list the closure stages use for `bounds`, and the free terminal
    // and H-component ids the merge pops. The S bitmap stays zero over its length.
    fn reserveClosure(self: *Connectivity, allocator: std.mem.Allocator, bounds: ClosureBounds, pool_grows: *u64) !void {
        const closure = &self.closure;
        try closure.ensureFreeIds(allocator, @min(bounds.n_gross, 2 * bounds.e_t), bounds.pieces, pool_grows);
        try closure.freed_terms.ensureTotalCapacity(allocator, bounds.k_c);
        try closure.touched.ensureTotalCapacity(allocator, bounds.candidates);
        const s_before = closure.s_words.items.len;
        if (bounds.s_words > s_before) {
            try closure.s_words.ensureTotalCapacity(allocator, bounds.s_words);
            closure.s_words.items.len = bounds.s_words;
            @memset(closure.s_words.items[s_before..], 0);
        }
        try closure.s_list.resize(allocator, bounds.k_cap_sum);
        try closure.loose.ensureTotalCapacity(allocator, bounds.loose);
        try closure.resolve_items.ensureTotalCapacity(allocator, bounds.e_t);
        try closure.resolve_out.ensureTotalCapacity(allocator, bounds.e_t);
        try closure.targets.ensureTotalCapacity(allocator, bounds.e_t);
        try closure.slots.ensureTotalCapacity(allocator, bounds.k_b);
        try closure.pieces.ensureTotalCapacity(allocator, bounds.pieces);
        try closure.leaving.ensureTotalCapacity(allocator, bounds.k_c);
        try closure.freed_indices.ensureTotalCapacity(allocator, bounds.k_c);
        try closure.mask_items.ensureTotalCapacity(allocator, @min(bounds.k_b, bounds.k_c));
        try closure.plan_items.ensureTotalCapacity(allocator, bounds.pieces);
        try closure.apos.ensureTotalCapacity(allocator, bounds.k_b);
        try closure.copy_items.ensureTotalCapacity(allocator, bounds.copy_items);
        try closure.round_items.ensureTotalCapacity(allocator, bounds.round_items);
        try closure.round_starts.ensureTotalCapacity(allocator, bounds.k_b + 2);
        // Assigned only after every reserve succeeded.
        closure.limits = bounds;
        closure.freed_terms.clearRetainingCapacity();
        std.debug.assert(closure.slots.capacity >= bounds.k_b and closure.pieces.capacity >= bounds.pieces and closure.resolve_items.capacity >= bounds.e_t);
    }

    // Makes room for `tail` arena words past the live blocks. When dead words outweigh live
    // ones or the tail is short, the live blocks move into a fresh arena of half again the live
    // words plus the tail (`conn_closure_compact`: a threaded copy per line, the main thread
    // O(1) per H-component), and the old arena is freed; a larger arena counts as a pool
    // growth.
    fn reserveArena(self: *Connectivity, allocator: std.mem.Allocator, tail: usize, threads: ?NavStageThreads, pool_grows: *u64, stats: *NavUpdateStats) !void {
        var section = StageTimer.begin();
        defer stats.main.reserve_ns += section.lap();
        const closure = &self.closure;
        const needed = closure.live_words + tail;
        if (needed >= std.math.maxInt(u32)) return error.NavConnectivityOverflow;
        if (closure.dead_words <= closure.live_words and closure.arena_limit - closure.words.items.len >= tail) return;
        // Headroom on the live words only: the tail is the batch's worst case.
        const limit = @min(needed + closure.live_words / 2, std.math.maxInt(u32) - 1);
        var fresh: std.ArrayList(u32) = .empty;
        errdefer fresh.deinit(allocator);
        try fresh.ensureTotalCapacityPrecise(allocator, limit);
        try closure.compact_blocks.ensureTotalCapacity(allocator, closure.hcompCount());
        closure.compact_blocks.clearRetainingCapacity();
        const hcomp = closure.hcomp;
        var offset: usize = 0;
        for (hcomp.k_cap, 0..) |k_cap, id| {
            if (k_cap == 0) continue;
            closure.compact_blocks.appendAssumeCapacity(.{
                .hcomp = @intCast(id),
                .src = hcomp.block[id],
                .dst = @intCast(offset),
                .line_start = @intCast(offset / span_words),
            });
            offset += blockWords(k_cap);
        }
        std.debug.assert(offset == closure.live_words);
        fresh.items.len = offset;
        var job = CompactJob{ .blocks = closure.compact_blocks.items, .src = closure.words.items, .dst = fresh.items };
        stats.main.reserve_ns += section.lap();
        const batch = runStage(threads, offset / span_words, &job, &job.range_count, compactJob);
        section = StageTimer.begin();
        accumulateBatch(&stats.conn_closure_compact_batch, batch);
        stats.addStageTime(batch);
        for (closure.compact_blocks.items) |moved| hcomp.block[moved.hcomp] = moved.dst;
        if (limit > closure.arena_limit) pool_grows.* += 1;
        closure.words.deinit(allocator);
        closure.words = fresh;
        closure.arena_limit = limit;
        std.debug.assert(closure.words.capacity >= closure.arena_limit);
        closure.dead_words = 0;
        closure.compactions += 1;
        stats.closure_compactions += 1;
    }

    // ------------------------------------------------------------------------------------
    // One-way closure: commit
    // ------------------------------------------------------------------------------------

    // Points `job` at the registry and the prepared one-way windows when the closure is active.
    fn bindOneWayWindows(self: *Connectivity, job: *GatherJob) void {
        const closure = &self.closure;
        if (!closure.active) return;
        std.debug.assert(closure.ow_counts.items.len == job.keys.len);
        job.oneway_of_link = closure.oneway_of_link.items;
        job.oneway_cursor = closure.oneway_cursor;
        job.ow_starts = closure.ow_starts.items;
        job.ow_counts = closure.ow_counts.items;
        job.ow_entries = closure.ow_entries.items;
    }

    // Brings the closure up to date after `finish`: touches the H-components the batch can
    // change and collects their links and the dead links its keys hold, resolves them, merges
    // terminals and pieces, then recomputes the affected rows.
    // Allocation-free after the batch's closure reserve.
    fn updateClosure(self: *Connectivity, levels: BatchLevels, world: ?*const WorldSystem, key_count: usize, threads: ClosureThreads, stats: *NavUpdateStats) ClosureCounters {
        var counters = ClosureCounters{};
        const touch_timer = StageTimer.begin();
        self.touchClosure(levels, key_count);
        stats.main.closure_ns += touch_timer.lap();
        if (self.closure.resolve_items.items.len == 0) {
            self.closure.last_resolve_batch = .{};
            self.closure.last_mask_batch = .{};
            self.closure.last_plan_batch = .{};
            self.closure.last_rows_batch = .{};
            return counters;
        }
        self.resolveLinks(levels, world, threads.resolve, stats);
        const merge_timer = StageTimer.begin();
        self.mergeResolved(&counters);
        stats.main.closure_ns += merge_timer.lap();
        self.finishClosure(threads, &counters, stats);
        return counters;
    }

    // The touch: per freed terminal, per root of a changed root-group (one that split or united
    // roots), and per one-way entry's ends and link, the H-component is touched once, in that
    // order; a dead link of an entry is taken once as loose. The resolve list is the touched
    // components' links in order, then the loose links. O(1) per freed terminal, group root,
    // entry, and link.
    fn touchClosure(self: *Connectivity, levels: BatchLevels, key_count: usize) void {
        const closure = &self.closure;
        const touch_stamp = closure.stamp + 1;
        closure.touched.len = 0;
        closure.loose.clearRetainingCapacity();
        closure.resolve_items.clearRetainingCapacity();
        var s_cursor: u32 = 0;
        var list_cursor: u32 = 0;
        for (closure.freed_terms.items) |term| self.touchHComp(closure.term.hcomp[term], &s_cursor, &list_cursor);
        const groups = GroupColumns.of(self.groups.slice());
        for (0..self.groups.len) |group| {
            if (groups.set_count[group] == 0 and groups.root_count[group] < 2) continue;
            for (self.group_roots.items[groups.root_start[group]..][0..groups.root_count[group]]) |root| {
                const term = self.root_term[root];
                if (term != no_term) self.touchHComp(closure.term.hcomp[term], &s_cursor, &list_cursor);
            }
        }
        const oneway = OneWayColumns.of(closure.oneway.slice());
        const elements = ElementColumns.of(self.elements.slice());
        for (0..key_count) |item| {
            for (closure.ow_entries.items[closure.ow_starts.items[item]..][0..closure.ow_counts.items[item]]) |entry| {
                const hcomp = oneway.hcomp[entry.oneway];
                if (hcomp != no_hcomp) {
                    self.touchHComp(hcomp, &s_cursor, &list_cursor);
                } else if (oneway.stamp[entry.oneway] != touch_stamp) {
                    oneway.stamp[entry.oneway] = touch_stamp;
                    std.debug.assert(closure.loose.items.len < closure.limits.loose);
                    closure.loose.appendAssumeCapacity(entry.oneway);
                }
                for ([2]u64{ entry.a_key, entry.b_key }, [2]u32{ entry.a_hint, entry.b_hint }) |key, hint| {
                    if (key == no_key) continue;
                    const row = if (self.element_map.get(key)) |element| elements.row[element] else hint;
                    std.debug.assert(row != no_node);
                    const root = self.comp_root[levels.graph(nodeKeyLevel(key)).node_comp[row]];
                    const term = self.root_term[root];
                    if (term != no_term) self.touchHComp(closure.term.hcomp[term], &s_cursor, &list_cursor);
                }
            }
        }
        const touched = closure.touched.slice();
        for (touched.items(.hcomp)) |hcomp| {
            var link = closure.hcomp.link_head[hcomp];
            while (link != no_oneway) : (link = oneway.next[link]) {
                std.debug.assert(closure.resolve_items.items.len < closure.limits.e_t);
                closure.resolve_items.appendAssumeCapacity(link);
            }
        }
        for (closure.loose.items) |link| {
            std.debug.assert(closure.resolve_items.items.len < closure.limits.e_t);
            closure.resolve_items.appendAssumeCapacity(link);
        }
        closure.freed_terms.clearRetainingCapacity();
    }

    // Touches H-component `hcomp` once per batch, giving it S windows; the prepare found it.
    fn touchHComp(self: *Connectivity, hcomp: u32, s_cursor: *u32, list_cursor: *u32) void {
        const closure = &self.closure;
        const columns = closure.hcomp;
        const touch_stamp = closure.stamp + 1;
        if (columns.stamp[hcomp] == touch_stamp) return;
        // The prepare's candidate scan found every component the batch can touch.
        std.debug.assert(columns.stamp[hcomp] == closure.stamp);
        columns.stamp[hcomp] = touch_stamp;
        columns.slot[hcomp] = @intCast(closure.touched.len);
        std.debug.assert(closure.touched.len < closure.limits.candidates);
        closure.touched.appendAssumeCapacity(.{
            .hcomp = hcomp,
            .s_start = s_cursor.*,
            .s_list_start = list_cursor.*,
            .s_count = 0,
            .heir = no_piece,
            .heir_count = 0,
            .kept_by = no_piece,
        });
        s_cursor.* += rowWords(columns.k_cap[hcomp]);
        list_cursor.* += columns.k_high[hcomp];
        std.debug.assert(s_cursor.* <= closure.limits.s_words and list_cursor.* <= closure.limits.k_cap_sum);
    }

    // Each link's ends on the final graph (`conn_closure_resolve`, item = link).
    fn resolveLinks(self: *Connectivity, levels: BatchLevels, world: ?*const WorldSystem, threads: ?NavStageThreads, stats: *NavUpdateStats) void {
        const closure = &self.closure;
        const count = closure.resolve_items.items.len;
        closure.resolve_out.items.len = count;
        var job = ResolveJob{
            .levels = levels,
            .links = if (world) |world_system| world_system.levelLinks() else &.{},
            .oneway_link = closure.oneway.items(.link),
            .items = closure.resolve_items.items,
            .outs = closure.resolve_out.items,
            .comp_root = self.comp_root,
        };
        closure.last_resolve_batch = runStage(threads, count, &job, &job.range_count, resolveJob);
        stats.addStageTime(closure.last_resolve_batch);
    }

    // The terminal of live root `root`, a new one popped when it holds none.
    fn termOfRoot(self: *Connectivity, root: u32, counters: *ClosureCounters) u32 {
        const closure = &self.closure;
        const existing = self.root_term[root];
        if (existing != no_term) {
            // A terminal the batch reaches is new in it or lies in a touched component.
            const hcomp = closure.term.hcomp[existing];
            std.debug.assert(hcomp == no_hcomp or closure.hcomp.stamp[hcomp] == closure.stamp + 1);
            return existing;
        }
        // The batch reserve covered every new terminal.
        std.debug.assert(closure.term_free.items.len != 0);
        const term = closure.term_free.pop().?;
        closure.term.root[term] = root;
        closure.term.hcomp[term] = no_hcomp;
        closure.term.index[term] = no_index;
        closure.term.slot[term] = no_slot;
        self.root_term[root] = term;
        counters.terms_new += 1;
        return term;
    }

    // Gives live root `root` the stored terminal `term` of a link end when the batch freed
    // `term` (its root was released) and `root` holds none. A stored terminal of a link live
    // before was live at the last commit, so a released root marks it freed; once taken, it
    // is not freed any more.
    fn adoptTerm(self: *Connectivity, root: u32, term: u32, counters: *ClosureCounters) void {
        const closure = &self.closure;
        std.debug.assert(term != no_term);
        if (self.root_term[root] != no_term or closure.term.root[term] != no_root) return;
        self.root_term[root] = term;
        closure.term.root[term] = root;
        counters.adopted += 1;
    }

    // The batch slot of terminal `term`, numbered on first sight.
    fn slotOf(self: *Connectivity, slots: SlotColumns, term: u32, slot_count: *u32) u32 {
        const closure = &self.closure;
        const existing = closure.term.slot[term];
        if (existing != no_slot) return existing;
        const slot = slot_count.*;
        std.debug.assert(slot < closure.limits.k_b);
        slot_count.* += 1;
        closure.term.slot[term] = slot;
        slots.term[slot] = term;
        slots.parent[slot] = slot;
        slots.size[slot] = 1;
        slots.piece[slot] = no_piece;
        slots.index[slot] = no_index;
        slots.out_start[slot] = 0;
        slots.out_count[slot] = 0;
        slots.a_pos[slot] = no_index;
        slots.scc[slot] = no_scc;
        slots.kept[slot] = false;
        slots.a_flag[slot] = false;
        return slot;
    }

    // Marks terminal `term`'s old index in its old component's S, once.
    fn addS(self: *Connectivity, touched: TouchColumns, term: u32) void {
        const closure = &self.closure;
        const hcomp = closure.term.hcomp[term];
        if (hcomp == no_hcomp) return;
        const touch = closure.hcomp.slot[hcomp];
        std.debug.assert(closure.hcomp.stamp[hcomp] == closure.stamp + 1);
        const index = closure.term.index[term];
        const word = &closure.s_words.items[touched.s_start[touch] + index / 32];
        const bit = @as(u32, 1) << @intCast(index % 32);
        if (word.* & bit != 0) return;
        word.* |= bit;
        closure.s_list.items[touched.s_list_start[touch] + touched.s_count[touch]] = index;
        touched.s_count[touch] += 1;
    }

    // Frees `index` of touched component `touch`'s block onto its heir piece's free list (in
    // the old index map), when a piece inherits the block; recorded for round 0's zeroing.
    fn freeIndex(self: *Connectivity, touched: TouchColumns, pieces: PieceColumns, touch: u32, index: u32) void {
        const closure = &self.closure;
        const piece = touched.kept_by[touch];
        if (piece == no_piece or pieces.compact[piece]) return;
        const id = touched.hcomp[touch];
        const map_start = closure.hcomp.block[id] + @as(usize, closure.hcomp.k_cap[id]) * rowWords(closure.hcomp.k_cap[id]);
        closure.words.items[map_start + index] = free_bit | pieces.free_head[piece];
        pieces.free_head[piece] = index;
        std.debug.assert(closure.freed_indices.items.len < closure.freed_indices.capacity);
        closure.freed_indices.appendAssumeCapacity(.{ .touch = touch, .index = index });
    }

    // The resolve merge, on the main thread in link order: terminals (new ones popped) and their slots,
    // unions over live links, S for every changed link's old and new source, the CSR of live
    // out-edges; then per touched component its leaving terminals (in S) and its heir piece,
    // each piece's inherited block (or its narrowing), the batch's freed indices onto their
    // heirs' free lists, every terminal's index (kept, or popped from its piece's free list, or
    // past its handed-out indices), moved-out terminals in their old S, and the mask items.
    // O(1)/O(α) per link and terminal slot.
    fn mergeResolved(self: *Connectivity, counters: *ClosureCounters) void {
        const closure = &self.closure;
        const items = closure.resolve_items.items;
        const outs = closure.resolve_out.items;
        const oneway = OneWayColumns.of(closure.oneway.slice());
        const touched = TouchColumns.of(closure.touched.slice());
        closure.slots.len = closure.limits.k_b;
        const slots = SlotColumns.of(closure.slots.slice());
        var slot_count: u32 = 0;
        var live_edges: usize = 0;
        counters.touched = closure.touched.len;
        counters.links = items.len;

        // Adoption, in link order: a root holding no terminal at an end of a link live before
        // takes the link's stored terminal there when the batch freed it and no root took it
        // yet. Merged and re-created roots keep their terminal, so only new ones pop.
        for (items, outs) |link, out| {
            if (!out.live or oneway.hcomp[link] == no_hcomp) continue;
            self.adoptTerm(out.src_root, oneway.src_term[link], counters);
            self.adoptTerm(out.dst_root, oneway.dst_term[link], counters);
        }
        for (items, outs) |link, out| {
            const old_live = oneway.hcomp[link] != no_hcomp;
            var src_term = no_term;
            var dst_term = no_term;
            if (out.live) {
                src_term = self.termOfRoot(out.src_root, counters);
                dst_term = self.termOfRoot(out.dst_root, counters);
                const src_slot = self.slotOf(slots, src_term, &slot_count);
                const dst_slot = self.slotOf(slots, dst_term, &slot_count);
                _ = uniteBySize(slots.parent, slots.size, src_slot, dst_slot);
                if (src_term != dst_term) {
                    slots.out_count[src_slot] += 1;
                    live_edges += 1;
                }
            }
            const changed = old_live != out.live or (out.live and (oneway.src_term[link] != src_term or oneway.dst_term[link] != dst_term));
            if (changed) {
                if (old_live) self.addS(touched, oneway.src_term[link]);
                if (out.live) self.addS(touched, src_term);
            }
        }
        closure.slots.len = slot_count;

        // The CSR of live out-edges over slots.
        var offset: u32 = 0;
        for (slots.out_start[0..slot_count], slots.out_count[0..slot_count]) |*start, *count| {
            start.* = offset;
            offset += count.*;
            count.* = 0;
        }
        std.debug.assert(live_edges <= closure.limits.e_t);
        closure.targets.items.len = live_edges;
        for (items, outs) |_, out| {
            if (!out.live) continue;
            const src_term = self.root_term[out.src_root];
            const dst_term = self.root_term[out.dst_root];
            if (src_term == dst_term) continue;
            const src_slot = closure.term.slot[src_term];
            closure.targets.items[slots.out_start[src_slot] + slots.out_count[src_slot]] = closure.term.slot[dst_term];
            slots.out_count[src_slot] += 1;
        }

        // Pieces, numbered on first sight in slot order.
        closure.pieces.len = closure.limits.pieces;
        const pieces = PieceColumns.of(closure.pieces.slice());
        var piece_count: u32 = 0;
        for (0..slot_count) |slot| {
            const rep = findRoot(slots.parent, @intCast(slot));
            if (slots.piece[rep] == no_piece) {
                const piece = piece_count;
                std.debug.assert(piece < closure.limits.pieces);
                piece_count += 1;
                slots.piece[rep] = piece;
                pieces.inherit[piece] = no_slot;
                pieces.hcomp[piece] = no_hcomp;
                pieces.block[piece] = 0;
                pieces.k_cap[piece] = 0;
                pieces.k_high[piece] = 0;
                pieces.free_head[piece] = free_end;
                pieces.relocated[piece] = false;
                pieces.compact[piece] = false;
                pieces.terms[piece] = 0;
                pieces.a_start[piece] = 0;
                pieces.a_count[piece] = 0;
                pieces.scc_count[piece] = 0;
                pieces.max_level[piece] = 0;
                pieces.link_head[piece] = no_oneway;
                pieces.link_tail[piece] = no_oneway;
                pieces.link_count[piece] = 0;
                pieces.tally[piece] = 0;
            }
            slots.piece[slot] = slots.piece[rep];
            pieces.terms[slots.piece[slot]] += 1;
        }
        closure.pieces.len = piece_count;

        // Per touched component in touch order: leaving terminals, and the piece holding most
        // of its terminals (ties to the lower piece).
        const hcomp = closure.hcomp;
        closure.leaving.clearRetainingCapacity();
        for (0..closure.touched.len) |touch| {
            const id = touched.hcomp[touch];
            const map = closure.words.items[hcomp.block[id] + @as(usize, hcomp.k_cap[id]) * rowWords(hcomp.k_cap[id]) ..][0..hcomp.k_high[id]];
            var heir: u32 = no_piece;
            var heir_count: u32 = 0;
            for (map) |entry| {
                if (entry & free_bit != 0) continue;
                const slot = closure.term.slot[entry];
                if (slot == no_slot) {
                    std.debug.assert(closure.leaving.items.len < closure.leaving.capacity);
                    closure.leaving.appendAssumeCapacity(entry);
                    self.addS(touched, entry);
                    continue;
                }
                const piece = slots.piece[slot];
                pieces.tally[piece] += 1;
                if (pieces.tally[piece] > heir_count or (pieces.tally[piece] == heir_count and piece < heir)) {
                    heir = piece;
                    heir_count = pieces.tally[piece];
                }
            }
            for (map) |entry| {
                if (entry & free_bit != 0) continue;
                const slot = closure.term.slot[entry];
                if (slot != no_slot) pieces.tally[slots.piece[slot]] = 0;
            }
            touched.heir[touch] = heir;
            touched.heir_count[touch] = heir_count;
            if (heir == no_piece) continue;
            const holder = pieces.inherit[heir];
            if (holder == no_slot or heir_count > touched.heir_count[holder]) pieces.inherit[heir] = @intCast(touch);
        }
        counters.terms_left = closure.leaving.items.len;
        for (0..piece_count) |piece| {
            const touch = pieces.inherit[piece];
            if (touch == no_slot) continue;
            touched.kept_by[touch] = @intCast(piece);
            const id = touched.hcomp[touch];
            pieces.block[piece] = hcomp.block[id];
            pieces.k_cap[piece] = hcomp.k_cap[id];
            pieces.k_high[piece] = hcomp.k_high[id];
            pieces.free_head[piece] = hcomp.index_free[id];
            // An heir holding under a quarter of its block narrows: its terminals renumber
            // from 0 and are all recomputed, so its old map yields nothing.
            if (shrinkDue(pieces.terms[piece], hcomp.k_cap[id])) {
                pieces.compact[piece] = true;
                pieces.k_high[piece] = 0;
                pieces.free_head[piece] = free_end;
            }
        }
        // Every index the batch frees in an inherited block, before any is handed out: the
        // leaving terminals', then the moved-out ones' in slot order. Each goes onto its
        // heir's free list through the old index map (round 0 zeroes its row) and may be
        // taken in this batch: its old row is in S, so every kept row reaching it is in A.
        closure.freed_indices.clearRetainingCapacity();
        for (closure.leaving.items) |term| self.freeIndex(touched, pieces, hcomp.slot[closure.term.hcomp[term]], closure.term.index[term]);
        // Kept terminals keep their index; the rest are recomputed (A), moved-out ones in
        // their old S.
        for (0..slot_count) |slot| {
            const term = slots.term[slot];
            const piece = slots.piece[slot];
            const inherit = pieces.inherit[piece];
            const old = closure.term.hcomp[term];
            if (inherit != no_slot and old == touched.hcomp[inherit] and !pieces.compact[piece]) {
                slots.kept[slot] = true;
                slots.index[slot] = closure.term.index[term];
                continue;
            }
            slots.a_flag[slot] = true;
            if (old == no_hcomp) continue;
            self.addS(touched, term);
            self.freeIndex(touched, pieces, hcomp.slot[old], closure.term.index[term]);
        }

        // Indices in slot order: each recomputed terminal takes a free index of its piece's
        // block, or the next one.
        for (0..slot_count) |slot| {
            if (slots.kept[slot]) continue;
            const piece = slots.piece[slot];
            const inherit = pieces.inherit[piece];
            if (pieces.free_head[piece] != free_end) {
                const index = pieces.free_head[piece];
                const id = touched.hcomp[inherit];
                const map_start = hcomp.block[id] + @as(usize, hcomp.k_cap[id]) * rowWords(hcomp.k_cap[id]);
                pieces.free_head[piece] = closure.words.items[map_start + index] & ~free_bit;
                slots.index[slot] = index;
            } else {
                slots.index[slot] = pieces.k_high[piece];
                pieces.k_high[piece] += 1;
            }
        }
        // A piece outgrowing its block, new, or narrowing moves to the arena tail. Every freed
        // index was offered first, so it holds no hole.
        for (0..piece_count) |piece| {
            if (pieces.inherit[piece] != no_slot and pieces.k_high[piece] <= pieces.k_cap[piece] and !pieces.compact[piece]) continue;
            std.debug.assert(pieces.k_high[piece] == pieces.terms[piece]);
            pieces.relocated[piece] = true;
            if (pieces.compact[piece]) {
                pieces.k_cap[piece] = compactCap(pieces.k_high[piece]);
                counters.shrinks += 1;
            } else {
                // Below `free_end`: the prepare bounded the largest block.
                pieces.k_cap[piece] = @intCast(std.math.ceilPowerOfTwoAssert(usize, @max(1, pieces.k_high[piece])));
            }
            std.debug.assert(pieces.k_cap[piece] <= closure.limits.q_max);
        }
        // Kept terminals tested against their component's S.
        closure.mask_items.clearRetainingCapacity();
        for (0..slot_count) |slot| {
            if (!slots.kept[slot]) continue;
            const touch = pieces.inherit[slots.piece[slot]];
            if (touched.s_count[touch] == 0) continue;
            const id = touched.hcomp[touch];
            const words = rowWords(hcomp.k_cap[id]);
            closure.mask_items.appendAssumeCapacity(.{ .slot = @intCast(slot), .row = @intCast(hcomp.block[id] + @as(usize, slots.index[slot]) * words), .touch = @intCast(touch), .words = words });
        }
    }

    // The mask (`conn_closure_mask`), each piece's A list, the plan
    // (`conn_closure_plan`: CSR walk, Tarjan, SCC levels), block assignment and round lists,
    // the rows (`conn_closure_rows`, rounds under one profile), and the commit.
    fn finishClosure(self: *Connectivity, threads: ClosureThreads, counters: *ClosureCounters, stats: *NavUpdateStats) void {
        const closure = &self.closure;
        const slots = SlotColumns.of(closure.slots.slice());
        const pieces = PieceColumns.of(closure.pieces.slice());
        const touched = TouchColumns.of(closure.touched.slice());
        const slot_count = closure.slots.len;
        const piece_count = closure.pieces.len;

        // Mask.
        var mask = MaskJob{
            .items = closure.mask_items.items,
            .words = closure.words.items,
            .s_words = closure.s_words.items,
            .s_list = closure.s_list.items,
            .s_start = touched.s_start,
            .s_list_start = touched.s_list_start,
            .s_count = touched.s_count,
            .a_flag = slots.a_flag,
        };
        closure.last_mask_batch = runStage(threads.mask, closure.mask_items.items.len, &mask, &mask.range_count, maskJob);
        stats.addStageTime(closure.last_mask_batch);
        var section = StageTimer.begin();

        // A lists per piece, in slot order.
        for (slots.a_flag[0..slot_count], slots.piece[0..slot_count]) |flag, piece| {
            if (flag) pieces.a_count[piece] += 1;
        }
        var a_total: u32 = 0;
        closure.plan_items.clearRetainingCapacity();
        for (pieces.a_start[0..piece_count], pieces.a_count[0..piece_count], 0..) |*start, *count, piece| {
            start.* = a_total;
            a_total += count.*;
            if (count.* != 0) closure.plan_items.appendAssumeCapacity(@intCast(piece));
            count.* = 0;
        }
        closure.apos.len = a_total;
        const apos = APosColumns.of(closure.apos.slice());
        for (0..slot_count) |slot| {
            if (!slots.a_flag[slot]) continue;
            const piece = slots.piece[slot];
            const position = pieces.a_start[piece] + pieces.a_count[piece];
            pieces.a_count[piece] += 1;
            apos.slot[position] = @intCast(slot);
            slots.a_pos[slot] = position;
        }
        counters.a_rows = a_total;

        // Plan.
        var plan = PlanJob{
            .items = closure.plan_items.items,
            .pieces = pieces,
            .slots = slots,
            .targets = closure.targets.items,
            .apos = apos,
        };
        stats.main.closure_ns += section.lap();
        closure.last_plan_batch = runStage(threads.plan, closure.plan_items.items.len, &plan, &plan.range_count, planJob);
        stats.addStageTime(closure.last_plan_batch);
        section = StageTimer.begin();

        // Blocks, then the round-0 copy and zero spans, then the round lists.
        self.assignBlocks(slots, pieces, touched, counters);
        var max_level: u32 = 0;
        for (closure.plan_items.items) |piece| max_level = @max(max_level, pieces.max_level[piece]);
        const rounds: usize = if (closure.plan_items.items.len == 0) 0 else max_level + 1;
        closure.round_starts.items.len = rounds + 1;
        @memset(closure.round_starts.items, 0);
        for (closure.plan_items.items) |piece| {
            const spans = spanCount(pieces.k_cap[piece]);
            const start = pieces.a_start[piece];
            for (apos.level[start..][0..pieces.scc_count[piece]]) |level| closure.round_starts.items[level + 1] += spans;
        }
        for (1..rounds + 1) |round| closure.round_starts.items[round] += closure.round_starts.items[round - 1];
        const round_total = if (rounds == 0) 0 else closure.round_starts.items[rounds];
        std.debug.assert(round_total <= closure.limits.round_items);
        closure.round_items.items.len = round_total;
        for (closure.plan_items.items) |piece| {
            const spans = spanCount(pieces.k_cap[piece]);
            const start = pieces.a_start[piece];
            for (0..pieces.scc_count[piece]) |scc| {
                const level = apos.level[start + scc];
                for (0..spans) |span| {
                    closure.round_items.items[closure.round_starts.items[level]] = .{ .piece = @intCast(piece), .scc = @intCast(start + scc), .span = @intCast(span) };
                    closure.round_starts.items[level] += 1;
                }
            }
        }
        // The fill advanced each round's start to its end: shift back.
        var round = rounds;
        while (round > 0) : (round -= 1) closure.round_starts.items[round] = closure.round_starts.items[round - 1];
        if (rounds != 0) closure.round_starts.items[0] = 0;

        // Rows: one sample for the step's copy spans and rounds; none when nothing moved.
        if (closure.copy_items.items.len + round_total == 0) {
            closure.last_rows_batch = .{};
            self.commitClosure(slots, pieces, touched);
            stats.main.closure_ns += section.lap();
            return;
        }
        stats.main.closure_ns += section.lap();
        var dispatch = RoundDispatch.begin(threads.rows, closure.copy_items.items.len + round_total);
        if (closure.copy_items.items.len != 0) {
            var copy = CopyJob{ .items = closure.copy_items.items, .words = closure.words.items };
            dispatch.run(closure.copy_items.items.len, &copy, &copy.range_count, copyJob);
        }
        for (0..rounds) |level| {
            const round_slice = closure.round_items.items[closure.round_starts.items[level]..closure.round_starts.items[level + 1]];
            if (round_slice.len == 0) continue;
            var rows = RowsJob{
                .items = round_slice,
                .words = closure.words.items,
                .pieces = pieces,
                .slots = slots,
                .targets = closure.targets.items,
                .apos = apos,
            };
            dispatch.run(round_slice.len, &rows, &rows.range_count, rowsJob);
        }
        closure.last_rows_batch = dispatch.finish(closure.copy_items.items.len + round_total);
        stats.off_main_stage_ns += dispatch.off_main_ns;
        stats.inline_stage_ns += dispatch.inline_ns;
        section = StageTimer.begin();
        counters.rounds = rounds + @intFromBool(closure.copy_items.items.len != 0);
        for (closure.copy_items.items) |item| counters.words_written += item.len;
        for (closure.plan_items.items) |piece| counters.words_written += @as(usize, pieces.a_count[piece]) * rowWords(pieces.k_cap[piece]);

        self.commitClosure(slots, pieces, touched);
        stats.main.closure_ns += section.lap();
    }

    // Block assignment and round-0 spans, in piece order: a relocated piece takes a tail block
    // (its old block, if any, goes dead) and gets copies of its kept rows outside A (widened,
    // zero tail) and zeroed rows for every other index outside A; a piece in place gets its
    // freed indices' rows zeroed. O(1) per piece and span.
    fn assignBlocks(self: *Connectivity, slots: SlotColumns, pieces: PieceColumns, touched: TouchColumns, counters: *ClosureCounters) void {
        const closure = &self.closure;
        const hcomp = closure.hcomp;
        closure.copy_items.clearRetainingCapacity();
        for (0..closure.pieces.len) |piece| {
            if (!pieces.relocated[piece]) continue;
            const offset = closure.words.items.len;
            const words = blockWords(pieces.k_cap[piece]);
            std.debug.assert(offset % span_words == 0 and offset + words <= closure.arena_limit);
            closure.words.items.len = offset + words;
            closure.live_words += words;
            counters.tail_words += words;
            pieces.block[piece] = @intCast(offset);
            const row_words = rowWords(pieces.k_cap[piece]);
            // Unused indices past those handed out: one zeroed range.
            self.zeroWords(offset + @as(usize, pieces.k_high[piece]) * row_words, @as(usize, pieces.k_cap[piece] - pieces.k_high[piece]) * row_words);
            const inherit = pieces.inherit[piece];
            if (inherit == no_slot) continue;
            const id = touched.hcomp[inherit];
            closure.dead_words += blockWords(hcomp.k_cap[id]);
            closure.live_words -= blockWords(hcomp.k_cap[id]);
            // The inherited block's free indices nobody took.
            const old_map = hcomp.block[id] + @as(usize, hcomp.k_cap[id]) * rowWords(hcomp.k_cap[id]);
            var free = pieces.free_head[piece];
            while (free != free_end) : (free = closure.words.items[old_map + free] & ~free_bit) {
                self.zeroWords(offset + @as(usize, free) * row_words, row_words);
            }
        }
        for (closure.freed_indices.items) |freed| {
            const piece = touched.kept_by[freed.touch];
            const row_words = rowWords(pieces.k_cap[piece]);
            self.zeroWords(pieces.block[piece] + @as(usize, freed.index) * row_words, row_words);
        }
        for (0..closure.slots.len) |slot| {
            const piece = slots.piece[slot];
            if (!pieces.relocated[piece] or !slots.kept[slot] or slots.a_flag[slot]) continue;
            const id = touched.hcomp[pieces.inherit[piece]];
            const old_words = rowWords(hcomp.k_cap[id]);
            const new_words = rowWords(pieces.k_cap[piece]);
            const src = hcomp.block[id] + @as(usize, slots.index[slot]) * old_words;
            const dst = pieces.block[piece] + @as(usize, slots.index[slot]) * new_words;
            var start: usize = 0;
            while (start < new_words) : (start += span_words) {
                const len = @min(span_words, new_words - start);
                const src_len = if (start >= old_words) 0 else @min(len, old_words - start);
                self.appendCopy(.{ .dst = @intCast(dst + start), .src = @intCast(src + start), .len = @intCast(len), .src_len = @intCast(src_len) });
            }
        }
    }

    // Zeroes `len` arena words from `start` in round 0, one span per item.
    fn zeroWords(self: *Connectivity, start: usize, len: usize) void {
        var offset: usize = 0;
        while (offset < len) : (offset += span_words) {
            self.appendCopy(.{ .dst = @intCast(start + offset), .src = 0, .len = @intCast(@min(span_words, len - offset)), .src_len = 0 });
        }
    }

    fn appendCopy(self: *Connectivity, item: CopyItem) void {
        const closure = &self.closure;
        std.debug.assert(closure.copy_items.items.len < closure.limits.copy_items);
        closure.copy_items.appendAssumeCapacity(item);
    }

    // The commit, in order: each piece's H-component id (inherited, or popped), the links
    // relinked per piece (dead ones off every list), dead components freed, each piece's row,
    // index map (a relocated one's copied first), and free list, every slot's terminal, every
    // leaving terminal freed, and the S windows cleared. O(1) per terminal, link, and piece.
    fn commitClosure(self: *Connectivity, slots: SlotColumns, pieces: PieceColumns, touched: TouchColumns) void {
        const closure = &self.closure;
        const hcomp = closure.hcomp;
        const term = closure.term;
        const oneway = OneWayColumns.of(closure.oneway.slice());
        const words = closure.words.items;
        for (0..closure.pieces.len) |piece| {
            const inherit = pieces.inherit[piece];
            // The batch reserve covered a new id per piece.
            pieces.hcomp[piece] = if (inherit != no_slot) touched.hcomp[inherit] else closure.hcomp_free.pop().?;
        }
        for (closure.resolve_items.items, closure.resolve_out.items) |link, out| {
            if (!out.live) {
                oneway.hcomp[link] = no_hcomp;
                oneway.next[link] = no_oneway;
                oneway.src_term[link] = no_term;
                oneway.dst_term[link] = no_term;
                continue;
            }
            const src_term = self.root_term[out.src_root];
            const piece = slots.piece[term.slot[src_term]];
            oneway.hcomp[link] = pieces.hcomp[piece];
            oneway.src_term[link] = src_term;
            oneway.dst_term[link] = self.root_term[out.dst_root];
            oneway.next[link] = no_oneway;
            if (pieces.link_tail[piece] == no_oneway) pieces.link_head[piece] = link else oneway.next[pieces.link_tail[piece]] = link;
            pieces.link_tail[piece] = link;
            pieces.link_count[piece] += 1;
        }
        for (touched.hcomp[0..closure.touched.len], touched.kept_by[0..closure.touched.len]) |id, kept_by| {
            if (kept_by != no_piece) continue;
            closure.dead_words += blockWords(hcomp.k_cap[id]);
            closure.live_words -= blockWords(hcomp.k_cap[id]);
            const stamp = hcomp.stamp[id];
            closure.hcomps.set(id, emptyHComp());
            hcomp.stamp[id] = stamp;
            std.debug.assert(closure.hcomp_free.items.len < closure.hcomp_free.capacity);
            closure.hcomp_free.appendAssumeCapacity(id);
        }
        for (0..closure.pieces.len) |piece| {
            const id = pieces.hcomp[piece];
            const inherit = pieces.inherit[piece];
            const map = pieces.block[piece] + @as(usize, pieces.k_cap[piece]) * rowWords(pieces.k_cap[piece]);
            if (pieces.relocated[piece] and inherit != no_slot and !pieces.compact[piece]) {
                const old_map = hcomp.block[id] + @as(usize, hcomp.k_cap[id]) * rowWords(hcomp.k_cap[id]);
                @memcpy(words[map..][0..hcomp.k_high[id]], words[old_map..][0..hcomp.k_high[id]]);
            }
            hcomp.block[id] = pieces.block[piece];
            hcomp.k_cap[id] = pieces.k_cap[piece];
            hcomp.k_high[id] = pieces.k_high[piece];
            hcomp.k_live[id] = pieces.terms[piece];
            hcomp.index_free[id] = pieces.free_head[piece];
            hcomp.link_head[id] = pieces.link_head[piece];
            hcomp.link_tail[id] = pieces.link_tail[piece];
            hcomp.link_count[id] = pieces.link_count[piece];
            hcomp.slot[id] = no_slot;
        }
        for (0..closure.slots.len) |slot| {
            const id = slots.term[slot];
            const piece = slots.piece[slot];
            const map = pieces.block[piece] + @as(usize, pieces.k_cap[piece]) * rowWords(pieces.k_cap[piece]);
            term.hcomp[id] = pieces.hcomp[piece];
            term.index[id] = slots.index[slot];
            term.slot[id] = no_slot;
            words[map + slots.index[slot]] = id;
        }
        for (closure.leaving.items) |id| {
            const root = term.root[id];
            if (root != no_root and self.root_term[root] == id) self.root_term[root] = no_term;
            term.root[id] = no_root;
            term.hcomp[id] = no_hcomp;
            term.index[id] = no_index;
            term.slot[id] = no_slot;
            std.debug.assert(closure.term_free.items.len < closure.term_free.capacity);
            closure.term_free.appendAssumeCapacity(id);
        }
        for (touched.s_start[0..closure.touched.len], touched.s_list_start[0..closure.touched.len], touched.s_count[0..closure.touched.len]) |s_start, list_start, count| {
            for (closure.s_list.items[list_start..][0..count]) |index| closure.s_words.items[s_start + index / 32] = 0;
        }
    }
};

// ----------------------------------------------------------------------------------------
// Edges
// ----------------------------------------------------------------------------------------

const Neighbour = struct {
    key: u64,
    level: u16,
    chunk: u32,
    label: u8,
};

fn cellLocal(grid: *const NavGrid, cell: usize) u8 {
    const mask: usize = grid.chunk_tiles - 1;
    const x = cell % grid.width;
    const y = cell / grid.width;
    // A chunk holds at most 256 cells.
    return @intCast(((y & mask) << grid.chunk_shift) | (x & mask));
}

fn neighbourAt(grid: *const NavGrid, level: u16, cell: usize) Neighbour {
    const label = grid.labelAt(cell);
    std.debug.assert(label != 0);
    const chunk = grid.chunkOfCell(cell);
    return .{ .key = nodeKey(level, chunk, label), .level = level, .chunk = chunk, .label = label };
}

// The node at cell (`x`, `y`) of `level` when the cell is open on a built level and is a
// portal of its chunk's record, else null.
fn portalNode(levels: BatchLevels, level: u16, x: u16, y: u16) ?Neighbour {
    if (!levels.built(level)) return null;
    const grid = levels.grid(level);
    const cell = @as(usize, y) * grid.width + x;
    if (grid.isBlockedIndex(cell)) return null;
    const neighbour = neighbourAt(grid, level, cell);
    if (levels.graph(level).chunkPortals(neighbour.chunk).find(cellLocal(grid, cell)) == null) return null;
    return neighbour;
}

const EdgeKinds = enum { mirrors, mirrors_and_links };

// Calls `visitor.visit(label, neighbour)` for each edge leaving a node of `chunk`'s record on
// `level` (only `only_label`'s when set): one per border flag (the mirror cell across that
// side) in portal order, then, with links, one per two-way link endpoint in the chunk (from
// the world's endpoint list, both sides of every link) whose two ends are open portals on
// built levels, in list order. One-way links and a link back to the same node yield none.
// O(portals of the record + link endpoints in the chunk).
fn forEachEdge(levels: BatchLevels, world: ?*const WorldSystem, level: u16, chunk: u32, only_label: ?u8, kinds: EdgeKinds, visitor: anytype) void {
    const grid = levels.grid(level);
    const portals = levels.graph(level).chunkPortals(chunk);
    const bounds = grid.chunkBounds(chunk);
    const mask: usize = grid.chunk_tiles - 1;
    const width = grid.width;
    for (portals.border) |portal| {
        if (only_label) |wanted| {
            if (portal.label != wanted) continue;
        }
        const x = bounds.x0 + (portal.local & mask);
        const y = bounds.y0 + (@as(usize, portal.local) >> grid.chunk_shift);
        // A flag means the mirror cell exists in-grid.
        if (portal.flags.west) visitor.visit(portal.label, neighbourAt(grid, level, y * width + x - 1));
        if (portal.flags.east) visitor.visit(portal.label, neighbourAt(grid, level, y * width + x + 1));
        if (portal.flags.north) visitor.visit(portal.label, neighbourAt(grid, level, (y - 1) * width + x));
        if (portal.flags.south) visitor.visit(portal.label, neighbourAt(grid, level, (y + 1) * width + x));
    }
    if (kinds == .mirrors) return;
    const world_system = world orelse return;
    var endpoints = world_system.levelChunkLinkEndpoints(level, chunk);
    while (endpoints.next()) |endpoint| {
        if (!endpoint.bidirectional) continue;
        const near = portalNode(levels, level, endpoint.cell.x, endpoint.cell.y) orelse continue;
        if (only_label) |wanted| {
            if (near.label != wanted) continue;
        }
        const far = portalNode(levels, endpoint.other_level, endpoint.other_cell.x, endpoint.other_cell.y) orelse continue;
        if (far.key == near.key) continue;
        visitor.visit(near.label, far);
    }
}

// ----------------------------------------------------------------------------------------
// Seed stage
// ----------------------------------------------------------------------------------------

// One range of the seed stage, reading the graph before the batch. Per changed key: an edge
// from its old node to the node across each border flag, then one to the far end of every
// two-way link endpoint in it (from the world's endpoint list, both sides of every link)
// whose cell is open, whose far cell is open on a built level, and whose far end holds a
// portal, applied or not: a level built in the same reaction lists a link its other end
// applies only in this batch. Ends in changed chunks carry old keys. For a replaced level
// every key's link ends on other levels join one old element, the whole old level being one
// removal cluster.
const SeedJob = struct {
    levels: BatchLevels,
    world: ?*const WorldSystem,
    keys: []const u64,
    changed_keys: []const u64,
    replaced: bool,
    starts: []const usize,
    counts: []u32,
    edges: []EdgeEntry,
    range_count: usize = 0,

    fn changed(self: *const SeedJob, level: u16, chunk: u32) bool {
        return std.sort.binarySearch(u64, self.changed_keys, chunkKey(level, chunk), struct {
            fn order(key: u64, item: u64) std.math.Order {
                return std.math.order(key, item);
            }
        }.order) != null;
    }

    // The far end of a seed edge: an old key in a changed chunk, else the node's key and row.
    fn far(self: *const SeedJob, neighbour: Neighbour) struct { key: u64, row: u32 } {
        if (self.changed(neighbour.level, neighbour.chunk)) return .{ .key = old_bit | neighbour.key, .row = no_node };
        const row = self.levels.graph(neighbour.level).nodeOf(neighbour.chunk, neighbour.label);
        std.debug.assert(row != no_node);
        return .{ .key = neighbour.key, .row = row };
    }
};

const SeedMirrors = struct {
    job: *const SeedJob,
    level: u16,
    chunk: u32,
    window: []EdgeEntry,
    written: usize = 0,

    fn visit(self: *SeedMirrors, label: u8, neighbour: Neighbour) void {
        const end = self.job.far(neighbour);
        self.window[self.written] = .{ .a = oldKey(self.level, self.chunk, label), .b = end.key, .a_row = no_node, .b_row = end.row };
        self.written += 1;
    }
};

// SIMD verdict: scalar. Record portal scans and endpoint list walks.
fn seedJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *SeedJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.keys.len and range.end <= job.counts.len);
    std.debug.assert(job.starts.len == job.keys.len + 1 and job.starts[job.keys.len] <= job.edges.len);
    for (range.start..range.end) |item| {
        const key = job.keys[item];
        const level = keyLevel(key);
        const chunk = keyChunk(key);
        var mirrors = SeedMirrors{ .job = job, .level = level, .chunk = chunk, .window = job.edges[job.starts[item]..job.starts[item + 1]] };
        if (!job.replaced) forEachEdge(job.levels, job.world, level, chunk, null, .mirrors, &mirrors);
        if (job.world) |world| {
            const grid = job.levels.grid(level);
            var endpoints = world.levelChunkLinkEndpoints(level, chunk);
            while (endpoints.next()) |endpoint| {
                if (!endpoint.bidirectional) continue;
                if (job.replaced and endpoint.other_level == level) continue;
                const cell = @as(usize, endpoint.cell.y) * grid.width + endpoint.cell.x;
                if (grid.isBlockedIndex(cell)) continue;
                if (!job.levels.built(endpoint.other_level)) continue;
                const far_grid = job.levels.grid(endpoint.other_level);
                const far_cell = @as(usize, endpoint.other_cell.y) * far_grid.width + endpoint.other_cell.x;
                if (far_grid.isBlockedIndex(far_cell)) continue;
                const neighbour = neighbourAt(far_grid, endpoint.other_level, far_cell);
                if (job.levels.graph(endpoint.other_level).chunkPortals(neighbour.chunk).find(cellLocal(far_grid, far_cell)) == null) continue;
                const end = job.far(neighbour);
                const near_key = if (job.replaced) oldKey(level, 0, 0) else oldKey(level, chunk, grid.labelAt(cell));
                mirrors.window[mirrors.written] = .{ .a = near_key, .b = end.key, .a_row = no_node, .b_row = end.row };
                mirrors.written += 1;
            }
        }
        job.counts[item] = @intCast(mirrors.written);
    }
}

// ----------------------------------------------------------------------------------------
// Gather stage
// ----------------------------------------------------------------------------------------

// One range of the gather stage, reading the re-derived records and the node lists before
// the merge. Per patch key: its old rows (all lost when the batch remasked the key, else kept
// while their label still holds a portal), its new portal-bearing labels with no row, then
// the edges leaving those new labels; with the closure active, first one entry per registered
// one-way endpoint in the chunk, record or not. Per new link: its edge, when it is two-way and
// both of its ends are open portals on built levels.
const GatherJob = struct {
    levels: BatchLevels,
    world: ?*const WorldSystem,
    keys: []const u64,
    changed: []const bool,
    links: []const LevelLink,
    row_starts: []const usize,
    row_counts: []u32,
    rows: []RowEntry,
    edge_starts: []const usize,
    edge_counts: []u32,
    edges: []EdgeEntry,
    // With the closure active: the registry and each key's one-way entry window.
    oneway_of_link: []const u32 = &.{},
    oneway_cursor: usize = 0,
    ow_starts: []const usize = &.{},
    ow_counts: []u32 = &.{},
    ow_entries: []OneWayEntry = &.{},
    range_count: usize = 0,
};

// One key's registered one-way endpoints as entries: the link's registry row and its two ends
// as portals of the patched graph, with their rows before the merge. O(endpoints in the chunk).
fn gatherOneWay(job: *const GatherJob, level: u16, chunk: u32, window: []OneWayEntry) u32 {
    const world = job.world orelse return 0;
    var written: usize = 0;
    var endpoints = world.levelChunkLinkEndpoints(level, chunk);
    while (endpoints.next()) |endpoint| {
        if (endpoint.link >= job.oneway_cursor) continue;
        const oneway = job.oneway_of_link[endpoint.link];
        if (oneway == no_oneway) continue;
        const near = portalNode(job.levels, level, endpoint.cell.x, endpoint.cell.y);
        const far = portalNode(job.levels, endpoint.other_level, endpoint.other_cell.x, endpoint.other_cell.y);
        std.debug.assert(written < window.len);
        window[written] = .{
            .oneway = oneway,
            .a_key = if (near) |node| node.key else no_key,
            .a_hint = if (near) |node| job.levels.graph(node.level).nodeOf(node.chunk, node.label) else no_node,
            .b_key = if (far) |node| node.key else no_key,
            .b_hint = if (far) |node| job.levels.graph(node.level).nodeOf(node.chunk, node.label) else no_node,
        };
        written += 1;
    }
    return @intCast(written);
}

const LabelSet = [4]u64;

fn labelSetHas(set: *const LabelSet, label: u8) bool {
    return (set[label >> 6] >> @intCast(label & 63)) & 1 != 0;
}

fn labelSetAdd(set: *LabelSet, label: u8) void {
    set[label >> 6] |= @as(u64, 1) << @intCast(label & 63);
}

fn labelSetRemove(set: *LabelSet, label: u8) void {
    set[label >> 6] &= ~(@as(u64, 1) << @intCast(label & 63));
}

const GatherEdges = struct {
    levels: BatchLevels,
    level: u16,
    chunk: u32,
    added: *const LabelSet,
    window: []EdgeEntry,
    written: usize = 0,

    fn visit(self: *GatherEdges, label: u8, neighbour: Neighbour) void {
        if (!labelSetHas(self.added, label)) return;
        self.window[self.written] = .{
            .a = nodeKey(self.level, self.chunk, label),
            .b = neighbour.key,
            .a_row = no_node,
            .b_row = self.levels.graph(neighbour.level).nodeOf(neighbour.chunk, neighbour.label),
        };
        self.written += 1;
    }
};

// SIMD verdict: scalar. Record portal scans, node list walks, and link lookups.
fn gatherJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *GatherJob = @ptrCast(@alignCast(context));
    const item_count = job.keys.len + job.links.len;
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= item_count);
    std.debug.assert(job.row_counts.len == item_count and job.edge_counts.len == item_count and job.changed.len == job.keys.len);
    std.debug.assert(job.row_starts[item_count] <= job.rows.len and job.edge_starts[item_count] <= job.edges.len);
    std.debug.assert(job.ow_counts.len == 0 or (job.ow_counts.len == job.keys.len and job.ow_starts[job.keys.len] <= job.ow_entries.len));
    for (range.start..range.end) |item| {
        const edge_window = job.edges[job.edge_starts[item]..job.edge_starts[item + 1]];
        if (item >= job.keys.len) {
            const link_index = item - job.keys.len;
            job.row_counts[item] = 0;
            job.edge_counts[item] = gatherLink(job.levels, job.links[link_index], edge_window);
            continue;
        }
        const key = job.keys[item];
        const level = keyLevel(key);
        const chunk = keyChunk(key);
        const level_graph = job.levels.graph(level);
        if (job.ow_counts.len != 0) job.ow_counts[item] = gatherOneWay(job, level, chunk, job.ow_entries[job.ow_starts[item]..job.ow_starts[item + 1]]);
        // A chunk with no record holds no node before or after the batch.
        const record = level_graph.recordOf(chunk) orelse {
            job.row_counts[item] = 0;
            job.edge_counts[item] = 0;
            continue;
        };
        const row_window = job.rows[job.row_starts[item]..job.row_starts[item + 1]];
        var row_count: usize = 0;
        var labels: LabelSet = @splat(0);
        const portals = level_graph.chunkPortals(chunk);
        for (portals.border) |portal| labelSetAdd(&labels, portal.label);
        for (portals.extra) |portal| labelSetAdd(&labels, portal.label);
        var added = labels;
        var row = level_graph.record_node_head[record];
        while (row != no_node) : (row = level_graph.node_sibling[row]) {
            const label = level_graph.node_label[row];
            const keep = !job.changed[item] and labelSetHas(&labels, label);
            if (keep) labelSetRemove(&added, label);
            row_window[row_count] = .{ .row = row, .label = label, .kind = if (keep) .kept else .removed };
            row_count += 1;
        }
        for (added, 0..) |word, word_index| {
            var bits = word;
            while (bits != 0) : (bits &= bits - 1) {
                const label: u8 = @intCast(word_index * 64 + @ctz(bits));
                row_window[row_count] = .{ .row = no_node, .label = label, .kind = .added };
                row_count += 1;
            }
        }
        job.row_counts[item] = @intCast(row_count);
        // A chunk that only lost or kept labels has no new edge: its neighbours' new edges
        // come from their added side.
        if (std.mem.allEqual(u64, &added, 0)) {
            job.edge_counts[item] = 0;
            continue;
        }
        var edges = GatherEdges{ .levels = job.levels, .level = level, .chunk = chunk, .added = &added, .window = edge_window };
        forEachEdge(job.levels, job.world, level, chunk, null, .mirrors_and_links, &edges);
        job.edge_counts[item] = @intCast(edges.written);
    }
}

// A new link's edge, when it is two-way and both of its ends are open portals on built levels.
fn gatherLink(levels: BatchLevels, link: LevelLink, window: []EdgeEntry) u32 {
    if (!link.bidirectional) return 0;
    const a = portalNode(levels, link.level_a, link.cell_a.x, link.cell_a.y) orelse return 0;
    const b = portalNode(levels, link.level_b, link.cell_b.x, link.cell_b.y) orelse return 0;
    if (a.key == b.key) return 0;
    std.debug.assert(window.len >= 1);
    window[0] = .{
        .a = a.key,
        .b = b.key,
        .a_row = levels.graph(a.level).nodeOf(a.chunk, a.label),
        .b_row = levels.graph(b.level).nodeOf(b.chunk, b.label),
    };
    return 1;
}

// ----------------------------------------------------------------------------------------
// Flood search
// ----------------------------------------------------------------------------------------

// The thread system's participants (workers plus the main thread), or the main thread alone.
fn participantCount(threads: ?NavStageThreads) usize {
    return if (threads) |stage| stage.thread_system.participantSlotCount() else 1;
}

// One round of the flood stage: per item, a breadth-first search from its set's detached
// queue, then from its own discoveries in discovery order, while it has written fewer
// proposals than its budget. Each edge to a node its set did not hold when the round was
// built, and that the search has not proposed yet, becomes a proposal; one another set held
// is foreign and never searched through. Reads only the graph and the node, comp, and set
// columns (the main thread holds them still); writes its items' windows and output slots and
// its participant's table.
const FloodJob = struct {
    levels: BatchLevels,
    world: ?*const WorldSystem,
    items: []const FloodItem,
    outs: []FloodOut,
    proposals: []Proposal,
    scratch: []FloodScratch,
    comp_set: []const u32,
    set_parent: []const u32,
    range_count: usize = 0,
};

const FloodVisitor = struct {
    levels: BatchLevels,
    comp_set: []const u32,
    set_parent: []const u32,
    set: u32,
    window: []Proposal,
    keys: []u64,
    stamps: []u32,
    generation: u32,
    written: usize = 0,

    fn visit(self: *FloodVisitor, _: u8, neighbour: Neighbour) void {
        const level_graph = self.levels.graph(neighbour.level);
        const row = level_graph.nodeOf(neighbour.chunk, neighbour.label);
        std.debug.assert(row != no_node);
        const owner = self.comp_set[level_graph.node_comp[row]];
        const foreign = owner != no_set and findRootConst(self.set_parent, owner) != self.set;
        if (owner != no_set and !foreign) return;
        // The table holds at most a window of keys in twice as many slots.
        const mask = self.keys.len - 1;
        var slot: usize = @truncate((neighbour.key *% 0x9E3779B97F4A7C15) >> 32);
        slot &= mask;
        while (self.stamps[slot] == self.generation) : (slot = (slot + 1) & mask) {
            if (self.keys[slot] == neighbour.key) return;
        }
        self.stamps[slot] = self.generation;
        self.keys[slot] = neighbour.key;
        std.debug.assert(self.written < self.window.len);
        self.window[self.written] = .{ .key = neighbour.key, .row = row, .foreign = foreign };
        self.written += 1;
    }
};

// SIMD verdict: scalar. A breadth-first frontier with a hash probe per edge (irreducible
// branching per portal and per probe).
fn floodJob(context: *anyopaque, range: ParallelRange, worker: WorkerId) void {
    const job: *FloodJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.items.len and range.end <= job.outs.len);
    std.debug.assert(worker.index < job.scratch.len);
    const scratch = &job.scratch[worker.index];
    for (job.items[range.start..range.end], job.outs[range.start..range.end]) |item, *out| {
        std.debug.assert(item.window_start + item.window_len <= job.proposals.len);
        std.debug.assert(item.budget != 0 and item.budget < item.window_len and 2 * item.window_len <= scratch.keys.len);
        scratch.generation +%= 1;
        if (scratch.generation == 0) {
            @memset(scratch.stamps, 0);
            scratch.generation = 1;
        }
        var visitor = FloodVisitor{
            .levels = job.levels,
            .comp_set = job.comp_set,
            .set_parent = job.set_parent,
            .set = item.set,
            .window = job.proposals[item.window_start..][0..item.window_len],
            .keys = scratch.keys,
            .stamps = scratch.stamps,
            .generation = scratch.generation,
        };
        // The detached queue, in order; one node's edges fit the window's slack.
        var key = item.head_key;
        var row = item.head_row;
        var expansions: u32 = 0;
        while (key != no_key and visitor.written < item.budget) {
            forEachEdge(job.levels, job.world, nodeKeyLevel(key), nodeKeyChunk(key), nodeKeyLabel(key), .mirrors_and_links, &visitor);
            expansions += 1;
            if (key == item.tail_key and row == item.tail_row) {
                key = no_key;
                break;
            }
            const level_graph = job.levels.graph(nodeKeyLevel(key));
            const next = level_graph.node_queue[row];
            row = level_graph.node_queue_row[row];
            key = next;
        }
        // Then its own discoveries, never through a foreign one.
        var expanded: usize = 0;
        if (key == no_key) {
            while (expanded < visitor.written and visitor.written < item.budget) : (expanded += 1) {
                const proposal = visitor.window[expanded];
                if (proposal.foreign) continue;
                forEachEdge(job.levels, job.world, nodeKeyLevel(proposal.key), nodeKeyChunk(proposal.key), nodeKeyLabel(proposal.key), .mirrors_and_links, &visitor);
                expansions += 1;
            }
        }
        out.* = .{
            .written = @intCast(visitor.written),
            .expanded = @intCast(expanded),
            .resume_key = key,
            .resume_row = row,
            .expansions = expansions,
        };
    }
}

// ----------------------------------------------------------------------------------------
// One-way closure stages
// ----------------------------------------------------------------------------------------

/// Threading for the closure stages, each with its own tuner; a null stage runs inline.
pub const ClosureThreads = struct {
    candidates: ?NavStageThreads = null,
    resolve: ?NavStageThreads = null,
    mask: ?NavStageThreads = null,
    plan: ?NavStageThreads = null,
    rows: ?NavStageThreads = null,
    compact: ?NavStageThreads = null,
};

const TouchColumns = struct {
    hcomp: []u32,
    s_start: []u32,
    s_list_start: []u32,
    s_count: []u32,
    heir: []u32,
    heir_count: []u32,
    kept_by: []u32,

    fn of(slice: std.MultiArrayList(TouchRow).Slice) TouchColumns {
        return .{
            .hcomp = slice.items(.hcomp),
            .s_start = slice.items(.s_start),
            .s_list_start = slice.items(.s_list_start),
            .s_count = slice.items(.s_count),
            .heir = slice.items(.heir),
            .heir_count = slice.items(.heir_count),
            .kept_by = slice.items(.kept_by),
        };
    }
};

const SlotColumns = struct {
    term: []u32,
    parent: []u32,
    size: []u32,
    piece: []u32,
    index: []u32,
    out_start: []u32,
    out_count: []u32,
    a_pos: []u32,
    scc: []u32,
    kept: []bool,
    a_flag: []bool,

    fn of(slice: std.MultiArrayList(SlotRow).Slice) SlotColumns {
        return .{
            .term = slice.items(.term),
            .parent = slice.items(.parent),
            .size = slice.items(.size),
            .piece = slice.items(.piece),
            .index = slice.items(.index),
            .out_start = slice.items(.out_start),
            .out_count = slice.items(.out_count),
            .a_pos = slice.items(.a_pos),
            .scc = slice.items(.scc),
            .kept = slice.items(.kept),
            .a_flag = slice.items(.a_flag),
        };
    }
};

const PieceColumns = struct {
    inherit: []u32,
    hcomp: []u32,
    block: []u32,
    k_cap: []u32,
    k_high: []u32,
    free_head: []u32,
    relocated: []bool,
    compact: []bool,
    terms: []u32,
    a_start: []u32,
    a_count: []u32,
    scc_count: []u32,
    max_level: []u32,
    link_head: []u32,
    link_tail: []u32,
    link_count: []u32,
    tally: []u32,

    fn of(slice: std.MultiArrayList(PieceRow).Slice) PieceColumns {
        return .{
            .inherit = slice.items(.inherit),
            .hcomp = slice.items(.hcomp),
            .block = slice.items(.block),
            .k_cap = slice.items(.k_cap),
            .k_high = slice.items(.k_high),
            .free_head = slice.items(.free_head),
            .relocated = slice.items(.relocated),
            .compact = slice.items(.compact),
            .terms = slice.items(.terms),
            .a_start = slice.items(.a_start),
            .a_count = slice.items(.a_count),
            .scc_count = slice.items(.scc_count),
            .max_level = slice.items(.max_level),
            .link_head = slice.items(.link_head),
            .link_tail = slice.items(.link_tail),
            .link_count = slice.items(.link_count),
            .tally = slice.items(.tally),
        };
    }
};

const APosColumns = struct {
    slot: []u32,
    dfs_index: []u32,
    low: []u32,
    on_stack: []bool,
    stack: []u32,
    call: []u32,
    edge: []u32,
    order: []u32,
    tmp_start: []u32,
    tmp_size: []u32,
    tmp_level: []u32,
    member: []u32,
    first: []u32,
    size: []u32,
    level: []u32,

    fn of(slice: std.MultiArrayList(APosRow).Slice) APosColumns {
        return .{
            .slot = slice.items(.slot),
            .dfs_index = slice.items(.dfs_index),
            .low = slice.items(.low),
            .on_stack = slice.items(.on_stack),
            .stack = slice.items(.stack),
            .call = slice.items(.call),
            .edge = slice.items(.edge),
            .order = slice.items(.order),
            .tmp_start = slice.items(.tmp_start),
            .tmp_size = slice.items(.tmp_size),
            .tmp_level = slice.items(.tmp_level),
            .member = slice.items(.member),
            .first = slice.items(.first),
            .size = slice.items(.size),
            .level = slice.items(.level),
        };
    }
};

// Rows items per SCC of a block of `k_cap` indices: one per 16-word span of a row.
fn spanCount(k_cap: u32) u32 {
    return (rowWords(k_cap) + @as(u32, span_words) - 1) / @as(u32, span_words);
}

// ORs `row` into `acc` word for word: four lanes at a time through `simd`, a scalar tail.
fn orInto(acc: []u32, row: []const u32) void {
    std.debug.assert(acc.len == row.len);
    const end = simd.vectorizedEnd(acc.len);
    var index: usize = 0;
    while (index < end) : (index += simd.lane_count) {
        simd.storeUint4Slice(acc[index..], simd.loadUint4(acc[index..]) | simd.loadUint4(row[index..]));
    }
    while (index < acc.len) : (index += 1) acc[index] |= row[index];
}

// Whether `row` and `mask` share a set bit: four lanes at a time through `simd`, a scalar tail.
fn sharesBit(row: []const u32, mask: []const u32) bool {
    std.debug.assert(row.len == mask.len);
    const end = simd.vectorizedEnd(row.len);
    const zero = simd.splatUint4(0);
    var index: usize = 0;
    while (index < end) : (index += simd.lane_count) {
        const both = simd.loadUint4(row[index..]) & simd.loadUint4(mask[index..]);
        if (simd.countTrue(simd.equalUint4(both, zero)) != simd.lane_count) return true;
    }
    while (index < row.len) : (index += 1) {
        if (row[index] & mask[index] != 0) return true;
    }
    return false;
}

// The candidate scan: per key, the H-components of its old nodes' terminals (when
// `old_nodes`), of its registered one-way endpoints' links, and of every endpoint partner's
// terminal, read through the graph before the change; and its tallies. A registered dead
// endpoint counts loose when its partner's chunk is no key or its end sorts first. In a
// changed key, a dead endpoint whose cell was closed and is open in the world now may revive
// its link: one terminal, two when its partner end was open (net: when the partner's root
// held no terminal). The key's split counts the distinct endpoint cells open before and after
// whose old root holds a terminal, less their distinct labels, plus those labels with an old
// edge; and it opens when a cell the old grid blocks is open in the world. Reads only; writes
// its keys' windows and tallies. `keys` are sorted.
const CandidateJob = struct {
    levels: BatchLevels,
    world: ?*const WorldSystem,
    keys: []const u64,
    old_nodes: bool,
    // A marks batch's remasked flags per key; a level build changes every key.
    changed: []const bool,
    all_changed: bool,
    oneway_of_link: []const u32,
    oneway_hcomp: []const u32,
    oneway_cursor: usize,
    comp_root: []const u32,
    root_term: []const u32,
    term_hcomp: []const u32,
    starts: []const usize,
    counts: []u32,
    hcomps: []u32,
    tallies: []CandTally,
    range_count: usize = 0,

    // The H-component of the terminal of the node at `row` of `level`, if any.
    fn nodeHComp(self: *const CandidateJob, level: u16, row: u32) ?u32 {
        const term = self.nodeTerm(level, row);
        return if (term == no_term) null else self.term_hcomp[term];
    }

    // The terminal of the root of the node at `row` of `level` before the change.
    fn nodeTerm(self: *const CandidateJob, level: u16, row: u32) u32 {
        return self.root_term[self.comp_root[self.levels.graph(level).node_comp[row]]];
    }

    fn isKey(self: *const CandidateJob, key: u64) bool {
        return std.sort.binarySearch(u64, self.keys, key, struct {
            fn order(wanted: u64, item: u64) std.math.Order {
                return std.math.order(wanted, item);
            }
        }.order) != null;
    }
};

// Labels of one key's qualifying endpoint cells that hold an old edge.
const SplitEdges = struct {
    labels: *const LabelSet,
    edged: LabelSet = @splat(0),

    fn visit(self: *SplitEdges, label: u8, _: Neighbour) void {
        if (labelSetHas(self.labels, label)) labelSetAdd(&self.edged, label);
    }
};

fn labelSetCount(set: *const LabelSet) u32 {
    var count: u32 = 0;
    for (set) |word| count += @popCount(word);
    return count;
}

// SIMD verdict: scalar. Record node walks and endpoint list walks; the opened test is four
// word-parallel ANDs.
fn candidateJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *CandidateJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.keys.len and range.end <= job.counts.len and range.end <= job.tallies.len);
    std.debug.assert(job.starts.len == job.keys.len + 1 and job.starts[job.keys.len] <= job.hcomps.len);
    std.debug.assert(job.all_changed or job.changed.len == job.keys.len);
    for (range.start..range.end) |item| {
        const key = job.keys[item];
        std.debug.assert(item == 0 or job.keys[item - 1] < key);
        const level = keyLevel(key);
        const chunk = keyChunk(key);
        const window = job.hcomps[job.starts[item]..job.starts[item + 1]];
        const changed = job.all_changed or job.changed[item];
        var written: usize = 0;
        var tally = CandTally{};
        if (job.old_nodes and job.levels.built(level)) {
            const level_graph = job.levels.graph(level);
            if (level_graph.recordOf(chunk)) |record| {
                var row = level_graph.record_node_head[record];
                while (row != no_node) : (row = level_graph.node_sibling[row]) {
                    const hcomp = job.nodeHComp(level, row) orelse continue;
                    if (written != 0 and window[written - 1] == hcomp) continue;
                    window[written] = hcomp;
                    written += 1;
                }
            }
        }
        // A remasked key opens when a cell its old grid blocks is open in the world.
        if (!job.all_changed and changed) {
            const grid = job.levels.grid(level);
            const old_bits = grid.chunkBlockedBits(chunk);
            const world_bits = grid.worldChunkBits(chunk, job.world);
            for (old_bits, world_bits) |old_word, world_word| tally.opened = tally.opened or old_word & ~world_word != 0;
        }
        if (job.world) |world| {
            const ct: u32 = world.chunk_size_tiles;
            const chunks_x: u32 = (@as(u32, world.width) + ct - 1) / ct;
            // The distinct qualifying endpoint cells (chunk-local) and their old labels.
            var cells: LabelSet = @splat(0);
            var labels: LabelSet = @splat(0);
            var cell_count: u32 = 0;
            var endpoints = world.levelChunkLinkEndpoints(level, chunk);
            while (endpoints.next()) |endpoint| {
                if (endpoint.link >= job.oneway_cursor) continue;
                const partner = portalNode(job.levels, endpoint.other_level, endpoint.other_cell.x, endpoint.other_cell.y);
                const partner_row = if (partner) |node| job.levels.graph(node.level).nodeOf(node.chunk, node.label) else no_node;
                const oneway = job.oneway_of_link[endpoint.link];
                if (oneway != no_oneway) {
                    const dead = job.oneway_hcomp[oneway] == no_hcomp;
                    if (!dead) {
                        window[written] = job.oneway_hcomp[oneway];
                        written += 1;
                    } else {
                        const partner_chunk = (endpoint.other_cell.y / ct) * chunks_x + endpoint.other_cell.x / ct;
                        const own_order = cellOrder(world, level, endpoint.cell);
                        const partner_order = cellOrder(world, endpoint.other_level, endpoint.other_cell);
                        if (!job.isKey(chunkKey(endpoint.other_level, partner_chunk)) or own_order <= partner_order) tally.loose += 1;
                    }
                    if (changed and !world.levelBlocksMovement(level, endpoint.cell.x, endpoint.cell.y)) {
                        if (portalNode(job.levels, level, endpoint.cell.x, endpoint.cell.y)) |own| {
                            const own_row = job.levels.graph(level).nodeOf(own.chunk, own.label);
                            if (own_row != no_node and job.nodeTerm(level, own_row) != no_term) {
                                const local = cellLocal(job.levels.grid(level), @as(usize, endpoint.cell.y) * job.levels.grid(level).width + endpoint.cell.x);
                                if (!labelSetHas(&cells, local)) {
                                    labelSetAdd(&cells, local);
                                    cell_count += 1;
                                    labelSetAdd(&labels, own.label);
                                }
                            }
                        } else if (dead) {
                            const partner_bare = partner != null and (partner_row == no_node or job.nodeTerm(partner.?.level, partner_row) == no_term);
                            tally.new_gross += 1 + @as(u32, @intFromBool(partner != null));
                            tally.new_net += 1 + @as(u32, @intFromBool(partner_bare));
                        }
                    }
                }
                if (partner_row == no_node) continue;
                const hcomp = job.nodeHComp(partner.?.level, partner_row) orelse continue;
                window[written] = hcomp;
                written += 1;
            }
            const label_count = labelSetCount(&labels);
            if (label_count != 0) {
                var edges = SplitEdges{ .labels = &labels };
                forEachEdge(job.levels, job.world, level, chunk, null, .mirrors_and_links, &edges);
                tally.split = cell_count - label_count + labelSetCount(&edges.edged);
            }
        }
        std.debug.assert(written <= window.len);
        job.counts[item] = @intCast(written);
        job.tallies[item] = tally;
    }
}

// A cell's order for picking one end of a link: its level, then its row-major index.
fn cellOrder(world: *const WorldSystem, level: u16, cell: @import("../../world_system.zig").CellCoord) u64 {
    return (@as(u64, level) << 32) | (@as(u64, cell.y) * world.width + cell.x);
}

// The compaction: copies live blocks into the fresh arena, one 16-word line per item; a line finds its
// block by binary search over the blocks' first lines.
const CompactJob = struct {
    blocks: []const CompactBlock,
    src: []const u32,
    dst: []u32,
    range_count: usize = 0,
};

// SIMD verdict: `@memcpy` per line.
fn compactJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *CompactJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end * span_words <= job.dst.len);
    // The first block starts at line 0, so every line has a block at or before it.
    std.debug.assert(range.start == range.end or job.blocks[0].line_start == 0);
    for (range.start..range.end) |line| {
        const block = job.blocks[std.sort.upperBound(CompactBlock, job.blocks, line, orderLineStart) - 1];
        const offset = (line - block.line_start) * span_words;
        @memcpy(job.dst[block.dst + offset ..][0..span_words], job.src[block.src + offset ..][0..span_words]);
    }
}

fn orderLineStart(line: usize, block: CompactBlock) std.math.Order {
    return std.math.order(line, block.line_start);
}

// The resolve: each item's link resolved on the final graph. Reads only; writes its outputs.
const ResolveJob = struct {
    levels: BatchLevels,
    links: []const LevelLink,
    oneway_link: []const u32,
    items: []const u32,
    outs: []ResolveOut,
    comp_root: []const u32,
    range_count: usize = 0,

    fn rootAt(self: *const ResolveJob, level: u16, cell: @import("../../world_system.zig").CellCoord) ?u32 {
        const node = portalNode(self.levels, level, cell.x, cell.y) orelse return null;
        const row = self.levels.graph(level).nodeOf(node.chunk, node.label);
        std.debug.assert(row != no_node);
        return self.comp_root[self.levels.graph(level).node_comp[row]];
    }
};

// SIMD verdict: scalar. Two portal lookups and record node walks per link.
fn resolveJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *ResolveJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.items.len and range.end <= job.outs.len);
    for (job.items[range.start..range.end], job.outs[range.start..range.end]) |oneway, *out| {
        const link = job.links[job.oneway_link[oneway]];
        const src = job.rootAt(link.level_a, link.cell_a);
        const dst = job.rootAt(link.level_b, link.cell_b);
        out.* = if (src != null and dst != null)
            .{ .live = true, .src_root = src.?, .dst_root = dst.? }
        else
            .{ .live = false, .src_root = no_root, .dst_root = no_root };
    }
}

// The mask: per kept terminal, whether its old row reaches an S member: bit probes when S is
// shorter than a row, else a word-wise AND. Writes only its items' slots' flags.
const MaskJob = struct {
    items: []const MaskItem,
    words: []const u32,
    s_words: []const u32,
    s_list: []const u32,
    s_start: []const u32,
    s_list_start: []const u32,
    s_count: []const u32,
    a_flag: []bool,
    range_count: usize = 0,
};

// SIMD verdict: `sharesBit` (four-lane AND and zero test) for a full row; scalar bit probes
// when S holds fewer indices than the row has words.
fn maskJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *MaskJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.items.len);
    for (job.items[range.start..range.end]) |item| {
        std.debug.assert(item.slot < job.a_flag.len and item.row + item.words <= job.words.len);
        const row = job.words[item.row..][0..item.words];
        const count = job.s_count[item.touch];
        var hit = false;
        if (count < item.words) {
            for (job.s_list[job.s_list_start[item.touch]..][0..count]) |index| {
                if ((row[index / 32] >> @intCast(index % 32)) & 1 != 0) {
                    hit = true;
                    break;
                }
            }
        } else {
            hit = sharesBit(row, job.s_words[job.s_start[item.touch]..][0..item.words]);
        }
        job.a_flag[item.slot] = hit;
    }
}

// The plan: per piece with an A list, an iterative Tarjan over A in list order (edges to
// terminals outside A are row reads, not graph edges), each SCC's level (1 + the highest
// level of an SCC it reaches in A, 0 if none), and the SCCs counting-sorted by level, stable
// in completion order. Writes only its pieces' A windows, SCC counts and levels, and their
// A slots' SCC ids. O(|A| + edges of A) per piece.
const PlanJob = struct {
    items: []const u32,
    pieces: PieceColumns,
    slots: SlotColumns,
    targets: []const u32,
    apos: APosColumns,
    range_count: usize = 0,
};

// SIMD verdict: scalar. An irreducible depth-first search.
fn planJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *PlanJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.items.len);
    const apos = job.apos;
    const slots = job.slots;
    for (job.items[range.start..range.end]) |piece| {
        const start = job.pieces.a_start[piece];
        const count = job.pieces.a_count[piece];
        std.debug.assert(start + count <= apos.slot.len);
        for (start..start + count) |position| {
            apos.dfs_index[position] = no_index;
            apos.on_stack[position] = false;
        }
        var counter: u32 = 0;
        var stack_len: u32 = 0;
        var scc_count: u32 = 0;
        var order_len: u32 = 0;
        var max_level: u32 = 0;
        for (start..start + count) |root| {
            if (apos.dfs_index[root] != no_index) continue;
            var depth: u32 = 0;
            pushVisit(apos, start, @intCast(root), &counter, &stack_len, &depth);
            while (depth != 0) {
                const frame = start + depth - 1;
                const node = apos.call[frame];
                const slot = apos.slot[node];
                if (apos.edge[frame] < slots.out_count[slot]) {
                    const target = job.targets[slots.out_start[slot] + apos.edge[frame]];
                    apos.edge[frame] += 1;
                    const target_pos = slots.a_pos[target];
                    if (target_pos == no_index) continue;
                    if (apos.dfs_index[target_pos] == no_index) {
                        pushVisit(apos, start, target_pos, &counter, &stack_len, &depth);
                    } else if (apos.on_stack[target_pos]) {
                        apos.low[node] = @min(apos.low[node], apos.dfs_index[target_pos]);
                    }
                    continue;
                }
                depth -= 1;
                if (depth != 0) {
                    const parent = apos.call[start + depth - 1];
                    apos.low[parent] = @min(apos.low[parent], apos.low[node]);
                }
                if (apos.low[node] != apos.dfs_index[node]) continue;
                // `node` roots an SCC: pop it, then its level from the SCCs it reaches.
                const scc = start + scc_count;
                const first = order_len;
                while (true) {
                    stack_len -= 1;
                    const member = apos.stack[start + stack_len];
                    apos.on_stack[member] = false;
                    apos.order[start + order_len] = apos.slot[member];
                    order_len += 1;
                    slots.scc[apos.slot[member]] = scc;
                    if (member == node) break;
                }
                var level: u32 = 0;
                for (apos.order[start + first .. start + order_len]) |member_slot| {
                    for (job.targets[slots.out_start[member_slot]..][0..slots.out_count[member_slot]]) |target| {
                        const target_scc = slots.scc[target];
                        if (slots.a_pos[target] == no_index or target_scc == scc) continue;
                        // Every SCC this one reaches in A completed before it.
                        std.debug.assert(target_scc != no_scc);
                        level = @max(level, apos.tmp_level[target_scc] + 1);
                    }
                }
                apos.tmp_start[scc] = first;
                apos.tmp_size[scc] = order_len - first;
                apos.tmp_level[scc] = level;
                max_level = @max(max_level, level);
                scc_count += 1;
            }
        }
        std.debug.assert(order_len == count);
        // Counting sort by level: counts (in `dfs_index`), then each SCC's final place (in
        // `low`), then the members in final order.
        const counts = apos.dfs_index[start..][0 .. max_level + 1];
        @memset(counts, 0);
        for (apos.tmp_level[start..][0..scc_count]) |level| counts[level] += 1;
        var running: u32 = 0;
        for (counts) |*level_count| {
            const here = level_count.*;
            level_count.* = running;
            running += here;
        }
        for (0..scc_count) |scc| {
            const level = apos.tmp_level[start + scc];
            apos.low[start + scc] = counts[level];
            counts[level] += 1;
        }
        for (0..scc_count) |scc| {
            const place = start + apos.low[start + scc];
            apos.size[place] = apos.tmp_size[start + scc];
            apos.level[place] = apos.tmp_level[start + scc];
        }
        var member_offset: u32 = start;
        for (0..scc_count) |place| {
            apos.first[start + place] = member_offset;
            member_offset += apos.size[start + place];
        }
        for (0..scc_count) |scc| {
            const place = start + apos.low[start + scc];
            const members = apos.order[start + apos.tmp_start[start + scc] ..][0..apos.tmp_size[start + scc]];
            for (members, apos.member[apos.first[place]..][0..members.len]) |member_slot, *member| {
                member.* = member_slot;
                slots.scc[member_slot] = @intCast(place);
            }
        }
        job.pieces.scc_count[piece] = scc_count;
        job.pieces.max_level[piece] = max_level;
    }
}

// Visits A position `position` of the piece starting at `start`: its DFS index and low link,
// onto the SCC stack and the call stack.
fn pushVisit(apos: APosColumns, start: u32, position: u32, counter: *u32, stack_len: *u32, depth: *u32) void {
    apos.dfs_index[position] = counter.*;
    apos.low[position] = counter.*;
    counter.* += 1;
    apos.stack[start + stack_len.*] = position;
    stack_len.* += 1;
    apos.on_stack[position] = true;
    apos.call[start + depth.*] = position;
    apos.edge[start + depth.*] = 0;
    depth.* += 1;
}

// The rows' round 0: copies and zeroes spans of the arena. Each item writes only its span.
const CopyJob = struct {
    items: []const CopyItem,
    words: []u32,
    range_count: usize = 0,
};

// SIMD verdict: `@memcpy`/`@memset` per span.
fn copyJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *CopyJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.items.len);
    for (job.items[range.start..range.end]) |item| {
        std.debug.assert(item.src_len <= item.len and item.dst + item.len <= job.words.len);
        const dst = job.words[item.dst..][0..item.len];
        @memcpy(dst[0..item.src_len], job.words[item.src..][0..item.src_len]);
        @memset(dst[item.src_len..], 0);
    }
}

// The rows' later rounds: per (SCC, span), the span of the SCC's row (its members' bits ORed with
// the rows of every terminal its members reach in one link outside the SCC: earlier rounds'
// rows or kept rows), written into each member's row. Each item writes only its members'
// spans; it reads rows no item of its round writes.
const RowsJob = struct {
    items: []const RowsItem,
    words: []u32,
    pieces: PieceColumns,
    slots: SlotColumns,
    targets: []const u32,
    apos: APosColumns,
    range_count: usize = 0,
};

// SIMD verdict: `orInto` (four-lane u32 OR via `simd`, scalar tail) per successor row span.
fn rowsJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *RowsJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.items.len);
    const slots = job.slots;
    for (job.items[range.start..range.end]) |item| {
        const block: usize = job.pieces.block[item.piece];
        const row_words: usize = rowWords(job.pieces.k_cap[item.piece]);
        const word_start = @as(usize, item.span) * span_words;
        const len = @min(span_words, row_words - word_start);
        var acc: [span_words]u32 = @splat(0);
        const members = job.apos.member[job.apos.first[item.scc]..][0..job.apos.size[item.scc]];
        for (members) |member| {
            const index = slots.index[member];
            const word = index / 32;
            if (word >= word_start and word < word_start + len) acc[word - word_start] |= @as(u32, 1) << @intCast(index % 32);
            for (job.targets[slots.out_start[member]..][0..slots.out_count[member]]) |target| {
                if (slots.scc[target] == item.scc) continue;
                const row = block + @as(usize, slots.index[target]) * row_words + word_start;
                std.debug.assert(row + len <= job.words.len);
                orInto(acc[0..len], job.words[row..][0..len]);
            }
        }
        for (members) |member| {
            const row = block + @as(usize, slots.index[member]) * row_words + word_start;
            @memcpy(job.words[row..][0..len], acc[0..len]);
        }
    }
}

// ----------------------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------------------

const test_support = @import("test_support.zig");
const PathfindingSystem = @import("system.zig").PathfindingSystem;
const DataSystem = @import("../../data_system.zig").DataSystem;
const WorldTilesetMeta = @import("../../../assets/world_tileset_meta.zig").WorldTilesetMeta;
const TileId = @import("../../world_system.zig").TileId;
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const SimulationFrame = @import("../../simulation.zig").SimulationFrame;
const runtime_perf_log = @import("../../../app/runtime_perf_log.zig");
const NavUpdateThreads = @import("nav_graph.zig").NavUpdateThreads;
const no_colliders = &test_support.no_colliders;

// Chunk edge of the test worlds, in cells.
const test_chunk: u16 = 4;

// A world of `chunks` x `chunks` walkable 4-cell chunks on `levels` levels, each level with
// an obstacle layer to draw walls on.
const TestWorld = struct {
    meta: WorldTilesetMeta,
    world: @import("../../world_system.zig").WorldSystem,
    data: DataSystem,
    obstacle: [4]usize = @splat(0),
    grass: TileId,
    tree: TileId,

    fn init(chunks: u16, levels: u16) !TestWorld {
        var meta = try test_support.loadTestWorldMeta(std.testing.allocator);
        errdefer meta.deinit();
        const grass = try test_support.requireTestTile(&meta, "grass");
        const tree = try test_support.requireTestTile(&meta, "tree_0");
        const extent = @as(f32, @floatFromInt(@as(u32, chunks) * test_chunk)) * meta.tileSize();
        var world = try test_support.abstractTestWorld(&meta, extent, extent);
        errdefer world.deinit();
        var fixture = TestWorld{ .meta = meta, .world = world, .data = DataSystem.init(std.testing.allocator), .grass = grass, .tree = tree };
        fixture.obstacle[0] = try fixture.world.addDenseLayer(0, 0, .obstacle, grass);
        for (1..levels) |level| {
            _ = try fixture.world.addLevel(-16 * @as(i32, @intCast(level)));
            _ = try fixture.world.addDenseLayer(@intCast(level), 0, .floor, grass);
            fixture.obstacle[level] = try fixture.world.addDenseLayer(@intCast(level), 0, .obstacle, grass);
        }
        return fixture;
    }

    fn deinit(self: *TestWorld) void {
        self.data.deinit();
        self.world.deinit();
        self.meta.deinit();
    }

    // Writes `tile` over every cell of chunk (cx, cy) on `level`, marking `system` dirty.
    fn setChunk(self: *TestWorld, system: ?*PathfindingSystem, level: u16, cx: u16, cy: u16, tile: TileId) !void {
        for (0..test_chunk) |dy| for (0..test_chunk) |dx| {
            try self.setCell(system, level, @intCast(cx * test_chunk + dx), @intCast(cy * test_chunk + dy), tile);
        };
    }

    fn setCell(self: *TestWorld, system: ?*PathfindingSystem, level: u16, x: u16, y: u16, tile: TileId) !void {
        const changed = (try self.world.setDenseTile(self.obstacle[level], x, y, tile)) orelse return;
        if (system) |nav| try nav.markNavDirty(changed.level, changed.x, changed.y);
    }

    fn build(self: *TestWorld, capacity: types.PathfindingCapacity) !PathfindingSystem {
        var system = PathfindingSystem.init(std.testing.allocator);
        errdefer system.deinit();
        try system.reserve(capacity);
        try system.rebuildStaticNavGridWithWorld(&self.data, &self.world, null);
        return system;
    }

    // Asserts `system`'s connectivity and one-way closure are consistent with the world and
    // partition and reach as a full rebuild's do.
    fn expectMatchesRebuild(self: *TestWorld, system: *const PathfindingSystem) !void {
        var rebuilt = try self.build(test_support.abstractCapacity());
        defer rebuilt.deinit();
        try test_support.expectConnectivityConsistent(&system.graph);
        try test_support.expectConnectivityConsistent(&rebuilt.graph);
        try test_support.expectSameConnectivityPartition(&system.graph, &rebuilt.graph);
        try test_support.expectClosureConsistent(&system.graph, &self.world);
        try test_support.expectClosureConsistent(&rebuilt.graph, &self.world);
        try test_support.expectSameClosure(&system.graph, &rebuilt.graph);
    }

    fn cell(self: *const TestWorld, x: usize, y: usize) usize {
        return y * self.world.width + x;
    }
};

// A walled room of `edge` x `edge` chunks in the level's corner whose only opening is the gap
// chunk (edge, edge / 2) of its wall band.
fn buildRoom(fixture: *TestWorld, edge: u16) !void {
    for (0..edge + 1) |cy| {
        if (cy == edge / 2) continue;
        try fixture.setChunk(null, 0, edge, @intCast(cy), fixture.tree);
    }
    for (0..edge) |cx| try fixture.setChunk(null, 0, @intCast(cx), edge, fixture.tree);
}

test "enclosing a room splits off exactly the room, floods only on its scale, and reopening merges it back" {
    for ([_]u16{ 1, 2, 4 }) |edge| {
        var flood_nodes: [2]usize = undefined;
        for ([_]u16{ 16, 32 }, 0..) |side, run| {
            var fixture = try TestWorld.init(side, 1);
            defer fixture.deinit();
            try buildRoom(&fixture, edge);
            var system = try fixture.build(test_support.abstractCapacity());
            defer system.deinit();
            const inside = fixture.cell(1, 1);
            const outside = fixture.cell(@as(usize, side) * test_chunk - 2, @as(usize, side) * test_chunk - 2);
            try std.testing.expect(reach(&system.graph, 0, inside, 0, outside) == .reaches);
            const roots = system.graph.connectivity.rootCount();

            try fixture.setChunk(&system, 0, edge, edge / 2, fixture.tree);
            const enclosed = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
            // A one-chunk room loses its only portal: no node is left to split off.
            const split: usize = if (edge > 1) 1 else 0;
            try std.testing.expectEqual(split, enclosed.conn_splits);
            try std.testing.expect(reach(&system.graph, 0, inside, 0, outside) != .reaches);
            try std.testing.expectEqual(roots + split, system.graph.connectivity.rootCount());
            // The outside side searches up to the room side's claims plus half again, so the
            // flood stays within a constant of the room.
            const room_nodes = @as(usize, edge) * edge;
            try std.testing.expect(enclosed.conn_flood_nodes <= 3 * room_nodes + 2);
            flood_nodes[run] = enclosed.conn_flood_nodes;
            try fixture.expectMatchesRebuild(&system);

            try fixture.setChunk(&system, 0, edge, edge / 2, fixture.grass);
            const opened = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
            try std.testing.expectEqual(@as(usize, 0), opened.conn_flood_nodes);
            try std.testing.expect(reach(&system.graph, 0, inside, 0, outside) == .reaches);
            try std.testing.expectEqual(roots, system.graph.connectivity.rootCount());
            try fixture.expectMatchesRebuild(&system);
        }
        // The flood follows the room, never the level around it.
        try std.testing.expectEqual(flood_nodes[0], flood_nodes[1]);
    }
}

test "cutting a ring floods around the ring until both sides meet and splits nothing" {
    for ([_]u16{ 1, 2, 4 }) |edge| {
        const span = edge + 2;
        var fixture = try TestWorld.init(span + 3, 1);
        defer fixture.deinit();
        // A solid block ringed by one chunk of corridor, walled off from the rest of the level.
        for (1..span - 1) |cy| for (1..span - 1) |cx| try fixture.setChunk(null, 0, @intCast(cx), @intCast(cy), fixture.tree);
        for (0..span + 1) |i| {
            try fixture.setChunk(null, 0, span, @intCast(i), fixture.tree);
            try fixture.setChunk(null, 0, @intCast(i), span, fixture.tree);
        }
        var system = try fixture.build(test_support.abstractCapacity());
        defer system.deinit();
        const roots = system.graph.connectivity.rootCount();
        try fixture.setChunk(&system, 0, 0, span / 2, fixture.tree);
        const cut = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        try std.testing.expectEqual(@as(usize, 0), cut.conn_splits);
        try std.testing.expect(cut.conn_flood_nodes > 0);
        // Both sides run around the ring until they meet, each at most half again the other's
        // claims, plus one node's slack.
        const ring: usize = 4 * (@as(usize, span) - 1);
        const slack = system.graph.levelGraph(0).?.border_stride;
        try std.testing.expect(cut.conn_flood_nodes <= ring * 3 / 2 + slack);
        try std.testing.expectEqual(roots, system.graph.connectivity.rootCount());
        try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), 0, fixture.cell(1, @as(usize, span - 1) * test_chunk + 1)) == .reaches);
        try fixture.expectMatchesRebuild(&system);
    }
}

// The comp of every node outside `changed` chunks, keyed by (level, chunk, label).
fn snapshotComps(graph: *const NavGraph, changed: []const u32, comps: *std.AutoHashMap(u64, u32)) !void {
    comps.clearRetainingCapacity();
    for (graph.level_graphs.items, 0..) |*level_graph, level| {
        for (0..level_graph.record_dir.items.len) |chunk_usize| {
            const chunk: u32 = @intCast(chunk_usize);
            if (std.mem.indexOfScalar(u32, changed, chunk) != null) continue;
            const record = level_graph.recordOf(chunk) orelse continue;
            var row = level_graph.record_node_head[record];
            while (row != no_node) : (row = level_graph.node_sibling[row]) {
                try comps.put(nodeKey(@intCast(level), chunk, level_graph.node_label[row]), level_graph.node_comp[row]);
            }
        }
    }
}

test "an opening dig floods nothing and moves no node outside its chunk to another comp" {
    var fixture = try TestWorld.init(6, 1);
    defer fixture.deinit();
    // A wall column through chunk column 2, then a dig through its middle chunk joins the
    // two halves.
    for (0..6) |cy| try fixture.setChunk(null, 0, 2, @intCast(cy), fixture.tree);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), 0, fixture.cell(20, 20)) != .reaches);
    var before = std.AutoHashMap(u64, u32).init(std.testing.allocator);
    defer before.deinit();
    var after = std.AutoHashMap(u64, u32).init(std.testing.allocator);
    defer after.deinit();
    const gap_chunk: u32 = 3 * 6 + 2;
    try snapshotComps(&system.graph, &.{gap_chunk}, &before);
    try fixture.setChunk(&system, 0, 2, 3, fixture.grass);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 0), stats.conn_flood_nodes);
    try std.testing.expectEqual(@as(usize, 0), stats.conn_splits);
    try std.testing.expectEqual(@as(usize, 1), stats.conn_merges);
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), 0, fixture.cell(20, 20)) == .reaches);
    try snapshotComps(&system.graph, &.{gap_chunk}, &after);
    try std.testing.expectEqual(before.count(), after.count());
    var entries = before.iterator();
    while (entries.next()) |entry| try std.testing.expectEqual(entry.value_ptr.*, after.get(entry.key_ptr.*).?);
    try fixture.expectMatchesRebuild(&system);
}

test "a dense change across four levels, its reopening, and an explosion opening match a full rebuild" {
    var fixture = try TestWorld.init(6, 4);
    defer fixture.deinit();
    // A wall band on every level, so the region's fill and clear split and merge.
    for (0..4) |level| for (0..6) |cy| try fixture.setChunk(null, @intCast(level), 4, @intCast(cy), fixture.tree);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    for ([_]TileId{ fixture.tree, fixture.grass, fixture.tree }) |tile| {
        for (0..4) |level| {
            for (2..18) |y| for (6..14) |x| try fixture.setCell(&system, @intCast(level), @intCast(x), @intCast(y), tile);
        }
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        try fixture.expectMatchesRebuild(&system);
    }
    // An explosion clears the filled region and the wall band in one step.
    for (0..4) |level| {
        for (0..24) |y| for (6..20) |x| try fixture.setCell(&system, @intCast(level), @intCast(x), @intCast(y), fixture.grass);
    }
    const opened = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 0), opened.conn_flood_nodes);
    try fixture.expectMatchesRebuild(&system);
}

test "a new two-way link joins two components; a one-way link joins none but reaches forward only; blocking and reopening an endpoint splits and rejoins" {
    var fixture = try TestWorld.init(4, 2);
    defer fixture.deinit();
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const top = fixture.cell(1, 1);
    const bottom = fixture.cell(14, 14);
    try std.testing.expect(reach(&system.graph, 0, top, 1, bottom) != .reaches);
    // One-way: no undirected edge, one directed reach.
    const roots = system.graph.connectivity.rootCount();
    try fixture.world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 3, .y = 3 }, .level_b = 1, .cell_b = .{ .x = 9, .y = 9 }, .traversal_cost = 1, .bidirectional = false });
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(roots, system.graph.connectivity.rootCount());
    try std.testing.expect(reach(&system.graph, 0, top, 1, bottom) == .reaches);
    try std.testing.expect(reach(&system.graph, 1, bottom, 0, top) != .reaches);
    try fixture.expectMatchesRebuild(&system);
    // Two-way: one edge, a root merge.
    try fixture.world.addLevelLink(.{ .kind = .stair, .level_a = 0, .cell_a = .{ .x = 5, .y = 6 }, .level_b = 1, .cell_b = .{ .x = 10, .y = 2 }, .traversal_cost = 1, .bidirectional = true });
    const linked = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), linked.conn_merges);
    try std.testing.expect(reach(&system.graph, 0, top, 1, bottom) == .reaches);
    try std.testing.expect(reach(&system.graph, 1, bottom, 0, top) == .reaches);
    try fixture.expectMatchesRebuild(&system);
    // Blocking the level-1 endpoint cuts the only connection.
    try fixture.setCell(&system, 1, 10, 2, fixture.tree);
    const blocked = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), blocked.conn_splits);
    // The one-way link still reaches forward; nothing reaches back.
    try std.testing.expect(reach(&system.graph, 0, top, 1, bottom) == .reaches);
    try std.testing.expect(reach(&system.graph, 1, bottom, 0, top) != .reaches);
    try fixture.expectMatchesRebuild(&system);
    try fixture.setCell(&system, 1, 10, 2, fixture.grass);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expect(reach(&system.graph, 0, top, 1, bottom) == .reaches);
    try fixture.expectMatchesRebuild(&system);
}

test "a level added with a link to it while a dig closes the link's old-level end leaves the levels apart" {
    // The old level's end sits on a border-run midpoint, so it is a node before the batch.
    for ([_][2]u16{ .{ 4, 2 }, .{ 5, 5 } }) |end| {
        var fixture = try TestWorld.init(4, 1);
        defer fixture.deinit();
        var system = try fixture.build(test_support.abstractCapacity());
        defer system.deinit();
        const level = try fixture.world.addLevel(-16);
        _ = try fixture.world.addDenseLayer(level, 0, .floor, fixture.grass);
        fixture.obstacle[level] = try fixture.world.addDenseLayer(level, 0, .obstacle, fixture.grass);
        try fixture.world.addLevelLink(.{ .kind = .stair, .level_a = 0, .cell_a = .{ .x = end[0], .y = end[1] }, .level_b = level, .cell_b = .{ .x = 9, .y = 9 }, .traversal_cost = 1, .bidirectional = true });
        try fixture.setCell(&system, 0, end[0], end[1], fixture.tree);
        const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        try std.testing.expectEqual(@as(usize, 1), stats.levels_built);
        try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), level, fixture.cell(1, 1)) != .reaches);
        try fixture.expectMatchesRebuild(&system);
        // Reopening the end joins them.
        try fixture.setCell(&system, 0, end[0], end[1], fixture.grass);
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), level, fixture.cell(1, 1)) == .reaches);
        try fixture.expectMatchesRebuild(&system);
    }
}

test "replacing a level that held the only link between two halves of another splits them" {
    var fixture = try TestWorld.init(6, 2);
    defer fixture.deinit();
    for (0..6) |cy| try fixture.setChunk(null, 0, 2, @intCast(cy), fixture.tree);
    try fixture.world.addLevelLink(.{ .kind = .stair, .level_a = 0, .cell_a = .{ .x = 2, .y = 2 }, .level_b = 1, .cell_b = .{ .x = 2, .y = 2 }, .traversal_cost = 1, .bidirectional = true });
    try fixture.world.addLevelLink(.{ .kind = .stair, .level_a = 0, .cell_a = .{ .x = 20, .y = 20 }, .level_b = 1, .cell_b = .{ .x = 20, .y = 20 }, .traversal_cost = 1, .bidirectional = true });
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), 0, fixture.cell(20, 21)) == .reaches);
    // A blocking layer over level 1 changes its content without per-cell events: a rebuild.
    _ = try fixture.world.addDenseLayer(1, 0, .obstacle, fixture.tree);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.levels_built);
    try std.testing.expectEqual(@as(usize, 1), stats.conn_splits);
    // The level build's flood reaches the stats and the perf log.
    try std.testing.expect(stats.conn_flood_batch.item_count != 0 and stats.conn_rounds != 0);
    if (runtime_perf_log.enabled) {
        var perf = runtime_perf_log.RuntimePerfLog.init(0);
        stats.recordTo(runtime_perf_log.Context.bind(&perf));
        try std.testing.expectEqual(@as(u64, 1), perf.batches[@backingInt(runtime_perf_log.BatchStage.nav_connect)].calls);
    }
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), 0, fixture.cell(20, 21)) != .reaches);
    try std.testing.expectEqual(@as(usize, 0), system.graph.levelGraph(1).?.nodeCount());
    try fixture.expectMatchesRebuild(&system);
}

fn cellFind(parents: []u32, index: u32) u32 {
    return findRoot(parents, index);
}

fn cellUnite(parents: []u32, a: u32, b: u32) void {
    const root_a = findRoot(parents, a);
    const root_b = findRoot(parents, b);
    if (root_a != root_b) parents[@max(root_a, root_b)] = @min(root_a, root_b);
}

// Cell-level classes: open cells joined by orthogonal moves, diagonal moves through two open
// orthogonal cells, and two-way links with both ends open.
fn referenceCellParents(graph: *const NavGraph, world: *const WorldSystem) ![]u32 {
    const cells = graph.width * graph.height;
    const parents = try std.testing.allocator.alloc(u32, cells * graph.levelCount());
    for (parents, 0..) |*parent, index| parent.* = @intCast(index);
    for (0..graph.levelCount()) |level| {
        const grid = graph.grid(@intCast(level)).?;
        const base = level * cells;
        for (0..graph.height) |y| for (0..graph.width) |x| {
            if (grid.isBlockedXY(x, y)) continue;
            const here: u32 = @intCast(base + y * graph.width + x);
            const east = x + 1 < graph.width and !grid.isBlockedXY(x + 1, y);
            const south = y + 1 < graph.height and !grid.isBlockedXY(x, y + 1);
            if (east) cellUnite(parents, here, here + 1);
            if (south) cellUnite(parents, here, @intCast(here + graph.width));
            if (east and south and !grid.isBlockedXY(x + 1, y + 1)) cellUnite(parents, here, @intCast(here + graph.width + 1));
            const west = x > 0 and !grid.isBlockedXY(x - 1, y);
            if (west and south and !grid.isBlockedXY(x - 1, y + 1)) cellUnite(parents, here, @intCast(here + graph.width - 1));
        };
    }
    for (world.levelLinks()) |link| {
        if (!link.bidirectional) continue;
        const a = @as(usize, link.cell_a.y) * graph.width + link.cell_a.x;
        const b = @as(usize, link.cell_b.y) * graph.width + link.cell_b.x;
        if (graph.grid(link.level_a).?.isBlockedIndex(a) or graph.grid(link.level_b).?.isBlockedIndex(b)) continue;
        cellUnite(parents, @intCast(link.level_a * cells + a), @intCast(link.level_b * cells + b));
    }
    return parents;
}

// Asserts `reach` equals the directed cell-level reference for every pair of open cells: the
// undirected classes, then a search over one-way links (both ends open) between classes.
fn expectReachMatchesCells(graph: *const NavGraph, world: *const WorldSystem) !void {
    const allocator = std.testing.allocator;
    const parents = try referenceCellParents(graph, world);
    defer allocator.free(parents);
    const cells = graph.width * graph.height;
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(allocator);
    for (world.levelLinks()) |link| {
        if (link.bidirectional) continue;
        const a = @as(usize, link.cell_a.y) * graph.width + link.cell_a.x;
        const b = @as(usize, link.cell_b.y) * graph.width + link.cell_b.x;
        if (graph.grid(link.level_a).?.isBlockedIndex(a) or graph.grid(link.level_b).?.isBlockedIndex(b)) continue;
        try edges.append(allocator, .{ cellFind(parents, @intCast(link.level_a * cells + a)), cellFind(parents, @intCast(link.level_b * cells + b)) });
    }
    // Per class: the classes it reaches.
    const reached = try allocator.alloc(bool, parents.len * parents.len);
    defer allocator.free(reached);
    @memset(reached, false);
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(allocator);
    for (0..parents.len) |class| {
        if (cellFind(parents, @intCast(class)) != class) continue;
        const row = reached[class * parents.len ..][0..parents.len];
        queue.clearRetainingCapacity();
        row[class] = true;
        try queue.append(allocator, @intCast(class));
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            for (edges.items) |edge| {
                if (edge[0] != queue.items[head] or row[edge[1]]) continue;
                row[edge[1]] = true;
                try queue.append(allocator, edge[1]);
            }
        }
    }
    for (0..parents.len) |from| {
        const from_level: u16 = @intCast(from / cells);
        if (graph.grid(from_level).?.isBlockedIndex(from % cells)) continue;
        const from_class = cellFind(parents, @intCast(from));
        for (0..parents.len) |to| {
            const to_level: u16 = @intCast(to / cells);
            if (graph.grid(to_level).?.isBlockedIndex(to % cells)) continue;
            const expected = reached[@as(usize, from_class) * parents.len + cellFind(parents, @intCast(to))];
            try std.testing.expectEqual(expected, reach(graph, from_level, from % cells, to_level, to % cells) == .reaches);
        }
    }
}

test "reach equals a directed cell-level search over every pair, built and after random changes, one-way links reaching forward only" {
    var prng = std.Random.DefaultPrng.init(0x7c1);
    const random = prng.random();
    for (0..3) |_| {
        var fixture = try TestWorld.init(3, 2);
        defer fixture.deinit();
        for (0..2) |level| for (0..12) |y| for (0..12) |x| {
            if (random.uintLessThan(u8, 100) < 38) try fixture.setCell(null, @intCast(level), @intCast(x), @intCast(y), fixture.tree);
        };
        for (0..8) |index| {
            try fixture.world.addLevelLink(.{
                .kind = .stair,
                .level_a = @intCast(index % 2),
                .cell_a = .{ .x = random.uintLessThan(u16, 12), .y = random.uintLessThan(u16, 12) },
                .level_b = @intCast((index / 2) % 2),
                .cell_b = .{ .x = random.uintLessThan(u16, 12), .y = random.uintLessThan(u16, 12) },
                .traversal_cost = 1,
                .bidirectional = index % 3 == 0,
            });
        }
        var system = try fixture.build(test_support.abstractCapacity());
        defer system.deinit();
        try expectReachMatchesCells(&system.graph, &fixture.world);
        for (0..6) |_| {
            for (0..5) |_| {
                const tile = if (random.boolean()) fixture.tree else fixture.grass;
                try fixture.setCell(&system, random.uintLessThan(u16, 2), random.uintLessThan(u16, 12), random.uintLessThan(u16, 12), tile);
            }
            _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
            try expectReachMatchesCells(&system.graph, &fixture.world);
            try fixture.expectMatchesRebuild(&system);
        }
    }
}

test "start and goal in one portal-less chunk label reach each other and nothing else" {
    var fixture = try TestWorld.init(3, 1);
    defer fixture.deinit();
    // Chunk (1,1) holds a 2x2 open pocket enclosed by its own blocked ring.
    for (4..8) |y| for (4..8) |x| {
        const pocket = x >= 5 and x <= 6 and y >= 5 and y <= 6;
        try fixture.setCell(null, 0, @intCast(x), @intCast(y), if (pocket) fixture.grass else fixture.tree);
    };
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const chunk = system.graph.chunkOf(fixture.cell(5, 5));
    try std.testing.expectEqual(no_node, system.graph.levelGraph(0).?.nodeOf(chunk, system.graph.grid(0).?.labelAt(fixture.cell(5, 5))));
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(5, 5), 0, fixture.cell(6, 6)) == .reaches);
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(5, 5), 0, fixture.cell(1, 1)) != .reaches);
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), 0, fixture.cell(6, 5)) != .reaches);
    // A blocked start decides nothing.
    try std.testing.expectEqual(Reach.start_blocked, reach(&system.graph, 0, fixture.cell(4, 4), 0, fixture.cell(4, 4)));
}

test "two hundred seeded random steps of digs, fills, and links match a full rebuild after each" {
    var prng = std.Random.DefaultPrng.init(0x64c1);
    const random = prng.random();
    var fixture = try TestWorld.init(4, 2);
    defer fixture.deinit();
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    for (0..200) |step| {
        const writes = 1 + random.uintLessThan(usize, 6);
        for (0..writes) |_| {
            const tile = if (random.uintLessThan(u8, 100) < 55) fixture.tree else fixture.grass;
            try fixture.setCell(&system, random.uintLessThan(u16, 2), random.uintLessThan(u16, 16), random.uintLessThan(u16, 16), tile);
        }
        if (step % 25 == 0) {
            try fixture.world.addLevelLink(.{
                .kind = .ramp,
                .level_a = random.uintLessThan(u16, 2),
                .cell_a = .{ .x = random.uintLessThan(u16, 16), .y = random.uintLessThan(u16, 16) },
                .level_b = random.uintLessThan(u16, 2),
                .cell_b = .{ .x = random.uintLessThan(u16, 16), .y = random.uintLessThan(u16, 16) },
                .traversal_cost = 1,
                .bidirectional = random.uintLessThan(u8, 4) != 0,
            });
        }
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        try fixture.expectMatchesRebuild(&system);
    }
}

test "repeatedly enclosing and reopening a room returns nodes, comps, and roots to their counts" {
    var fixture = try TestWorld.init(8, 1);
    defer fixture.deinit();
    try buildRoom(&fixture, 3);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const nodes = system.graph.levelGraph(0).?.nodeCount();
    var counts: [2]usize = undefined;
    for (0..6) |cycle| {
        try fixture.setChunk(&system, 0, 3, 1, fixture.tree);
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        try fixture.setChunk(&system, 0, 3, 1, fixture.grass);
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        try std.testing.expectEqual(nodes, system.graph.levelGraph(0).?.nodeCount());
        try std.testing.expectEqual(@as(usize, 1), system.graph.connectivity.rootCount());
        // Live comps from the first cycle on; the pool reaches its high-water by the second.
        const now = [2]usize{ system.graph.connectivity.compCount(), system.graph.connectivity.comps.len };
        if (cycle == 0) counts[0] = now[0] else try std.testing.expectEqual(counts[0], now[0]);
        if (cycle == 1) counts[1] = now[1] else if (cycle > 1) try std.testing.expectEqual(counts[1], now[1]);
    }
    try fixture.expectMatchesRebuild(&system);
}

// A 10 x 10 chunk level halved by a solid chunk column, each half holding a walled 2 x 2 chunk
// room opened by one gap chunk ((2, 1) and (7, 1)): enclosing both rooms splits two separate
// components, each flooding as its own family.
fn twoRooms(fixture: *TestWorld) !void {
    for (0..10) |cy| try fixture.setChunk(null, 0, 5, @intCast(cy), fixture.tree);
    for (0..3) |cy| {
        if (cy != 1) try fixture.setChunk(null, 0, 2, @intCast(cy), fixture.tree);
        if (cy != 1) try fixture.setChunk(null, 0, 7, @intCast(cy), fixture.tree);
    }
    for (0..2) |cx| try fixture.setChunk(null, 0, @intCast(cx), 2, fixture.tree);
    for (8..10) |cx| try fixture.setChunk(null, 0, @intCast(cx), 2, fixture.tree);
}

fn toggleRooms(fixture: *TestWorld, system: ?*PathfindingSystem, tile: TileId) !void {
    try fixture.setChunk(system, 0, 2, 1, tile);
    try fixture.setChunk(system, 0, 7, 1, tile);
}

// Asserts `a` and `b` hold bitwise equal connectivity and one-way closure columns.
fn expectSameColumns(a: *const NavGraph, b: *const NavGraph) !void {
    const t = std.testing;
    for (a.level_graphs.items, b.level_graphs.items) |*level_a, *level_b| {
        try t.expectEqualSlices(u8, level_a.node_label, level_b.node_label);
        try t.expectEqualSlices(u32, level_a.node_comp, level_b.node_comp);
        try t.expectEqualSlices(u32, level_a.node_sibling, level_b.node_sibling);
        try t.expectEqualSlices(u32, level_a.node_free.items, level_b.node_free.items);
        try t.expectEqualSlices(u32, level_a.record_node_head, level_b.record_node_head);
        try t.expectEqualSlices(u8, level_a.record_label_count, level_b.record_label_count);
    }
    const conn_a = &a.connectivity;
    const conn_b = &b.connectivity;
    try t.expectEqualSlices(u32, conn_a.comp_root, conn_b.comp_root);
    try t.expectEqualSlices(u32, conn_a.comp_size, conn_b.comp_size);
    try t.expectEqualSlices(u32, conn_a.comp_prev, conn_b.comp_prev);
    try t.expectEqualSlices(u32, conn_a.comp_next, conn_b.comp_next);
    try t.expectEqualSlices(u32, conn_a.comp_set, conn_b.comp_set);
    try t.expectEqualSlices(u32, conn_a.root_head, conn_b.root_head);
    try t.expectEqualSlices(u32, conn_a.root_members, conn_b.root_members);
    try t.expectEqualSlices(u32, conn_a.comp_free.items, conn_b.comp_free.items);
    try t.expectEqualSlices(u32, conn_a.root_free.items, conn_b.root_free.items);
    try t.expectEqualSlices(u32, conn_a.root_term, conn_b.root_term);
    const closure_a = &conn_a.closure;
    const closure_b = &conn_b.closure;
    try t.expectEqualSlices(u32, closure_a.words.items, closure_b.words.items);
    try t.expectEqual(closure_a.live_words, closure_b.live_words);
    try t.expectEqual(closure_a.dead_words, closure_b.dead_words);
    try t.expectEqualSlices(u32, closure_a.oneway_of_link.items, closure_b.oneway_of_link.items);
    inline for (.{ .root, .hcomp, .index, .slot }) |field| try t.expectEqualSlices(u32, @field(closure_a.term, @tagName(field)), @field(closure_b.term, @tagName(field)));
    inline for (.{ .block, .k_cap, .k_high, .k_live, .index_free, .link_head, .link_tail, .link_count }) |field| try t.expectEqualSlices(u32, @field(closure_a.hcomp, @tagName(field)), @field(closure_b.hcomp, @tagName(field)));
    inline for (.{ .link, .hcomp, .next, .src_term, .dst_term }) |field| try t.expectEqualSlices(u32, closure_a.oneway.items(field), closure_b.oneway.items(field));
    try t.expectEqualSlices(u32, closure_a.term_free.items, closure_b.term_free.items);
    try t.expectEqualSlices(u32, closure_a.hcomp_free.items, closure_b.hcomp_free.items);
}

// One parity step on `run`'s world: both rooms' gaps and a scattered pattern on both levels
// take `tile`, each change marked on every system.
fn writeParityStep(run: *TestWorld, systems: []const *PathfindingSystem, tile: TileId) !void {
    for ([_][2]u16{ .{ 2, 1 }, .{ 7, 1 } }) |gap| {
        for (0..test_chunk) |dy| for (0..test_chunk) |dx| {
            try markAll(run, systems, 0, @intCast(gap[0] * test_chunk + dx), @intCast(gap[1] * test_chunk + dy), tile);
        };
    }
    for (0..2) |level| for (12..20) |y| for (12..20) |x| {
        if ((x * 7 + y * 3) % 5 == 0) try markAll(run, systems, @intCast(level), @intCast(x), @intCast(y), tile);
    };
}

fn markAll(run: *TestWorld, systems: []const *PathfindingSystem, level: u16, x: u16, y: u16, tile: TileId) !void {
    const changed = (try run.world.setDenseTile(run.obstacle[level], x, y, tile)) orelse return;
    for (systems) |system| try system.markNavDirty(changed.level, changed.x, changed.y);
}

test "threaded connectivity stages equal the inline ones column for column across worker counts and range sizes" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    for ([_]usize{ 1, 2, 4 }) |workers| {
        var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = workers, .items_per_range = 1 });
        defer threads.deinit();
        for ([_]usize{ 1, 2, 7 }) |items_per_range| {
            var run = try TestWorld.init(10, 2);
            defer run.deinit();
            try twoRooms(&run);
            try run.world.addLevelLink(.{ .kind = .stair, .level_a = 0, .cell_a = .{ .x = 30, .y = 30 }, .level_b = 1, .cell_b = .{ .x = 2, .y = 2 }, .traversal_cost = 1, .bidirectional = true });
            var inline_system = try run.build(test_support.abstractCapacity());
            defer inline_system.deinit();
            var capacity = test_support.abstractCapacity();
            capacity.worker_participant_count = threads.participantSlotCount();
            var threaded = PathfindingSystem.init(std.testing.allocator);
            defer threaded.deinit();
            try threaded.reserve(capacity);
            threaded.nav_thread_adaptive = false;
            threaded.nav_thread_items_per_range = items_per_range;
            // The world build runs the stages threaded over every chunk of each level.
            try threaded.rebuildStaticNavGridWithWorld(&run.data, &run.world, &threads);
            try std.testing.expect(!threaded.graph.connectivity.last_gather_batch.ran_inline);
            try expectSameColumns(&inline_system.graph, &threaded.graph);
            var flooded_on_workers = false;
            for ([_]TileId{ run.tree, run.grass, run.tree }) |tile| {
                try writeParityStep(&run, &.{ &inline_system, &threaded }, tile);
                _ = try inline_system.applyBufferedNavUpdates(no_colliders, &run.world, null);
                const stats = try threaded.applyBufferedNavUpdates(no_colliders, &run.world, &threads);
                try std.testing.expect(!stats.conn_seed_batch.ran_inline and !stats.conn_gather_batch.ran_inline);
                if (stats.conn_splits != 0 and !stats.conn_flood_batch.ran_inline) flooded_on_workers = true;
                try expectSameColumns(&inline_system.graph, &threaded.graph);
                try run.expectMatchesRebuild(&threaded);
            }
            // The two rooms' searches fill two ranges only at one search per range.
            if (items_per_range == 1) try std.testing.expect(flooded_on_workers);
        }
    }
}

test "an enclosing batch reserved with the real allocator commits on a multi-worker ThreadSystem without allocating" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var fixture = try TestWorld.init(10, 1);
    defer fixture.deinit();
    try twoRooms(&fixture);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 4, .items_per_range = 1 });
    defer threads.deinit();
    var capacity = test_support.abstractCapacity();
    capacity.worker_participant_count = threads.participantSlotCount();
    var system = try fixture.build(capacity);
    defer system.deinit();
    const nav_threads = forcedNavThreads(&system, &threads);
    // Reserve with the real allocator, arm the failing one, then commit.
    try toggleRooms(&fixture, &system, fixture.tree);
    var stats = NavUpdateStats{};
    const prepared = (try system.graph.prepareMarks(&fixture.world, no_colliders.view(), system.nav_marks.items, nav_threads, &stats)).?;
    const original = system.graph.allocator;
    system.graph.allocator = std.testing.failing_allocator;
    const batch = system.graph.commitMarks(prepared, no_colliders.view(), nav_threads, &stats);
    system.graph.allocator = original;
    system.nav_marks.clearRetainingCapacity();
    try std.testing.expect(batch.changed);
    try std.testing.expectEqual(@as(usize, 2), stats.conn_splits);
    try std.testing.expect(!stats.conn_seed_batch.ran_inline);
    try std.testing.expect(!stats.conn_gather_batch.ran_inline);
    try std.testing.expect(!stats.conn_flood_batch.ran_inline);
    try fixture.expectMatchesRebuild(&system);
}

test "the post-commit nav reaction runs the connectivity stages on workers and records the flood as nav_connect" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var fixture = try TestWorld.init(10, 1);
    defer fixture.deinit();
    try twoRooms(&fixture);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var capacity = test_support.abstractCapacity();
    capacity.worker_participant_count = threads.participantSlotCount();
    var system = try fixture.build(capacity);
    defer system.deinit();
    system.nav_thread_adaptive = false;
    system.nav_thread_items_per_range = 1;
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try toggleRooms(&fixture, &system, fixture.tree);
    frame.beginStep();
    const stats = try system.reactToPostCommitNavEvents(&frame, no_colliders, &fixture.world, &threads);
    try std.testing.expectEqual(@as(usize, 2), stats.conn_splits);
    // A search expands at least one node.
    try std.testing.expect(stats.conn_flood_batch.item_count != 0 and stats.conn_flood_batch.item_count <= stats.conn_flood_nodes);
    try std.testing.expect(!stats.conn_flood_batch.ran_inline and stats.conn_flood_batch.worker_thread_ranges != 0);
    try std.testing.expect(!stats.conn_seed_batch.ran_inline and !stats.conn_gather_batch.ran_inline);
    if (runtime_perf_log.enabled) {
        var perf = runtime_perf_log.RuntimePerfLog.init(0);
        stats.recordTo(runtime_perf_log.Context.bind(&perf));
        const connect = perf.batches[@backingInt(runtime_perf_log.BatchStage.nav_connect)];
        try std.testing.expectEqual(@as(u64, 1), connect.calls);
        try std.testing.expectEqual(@as(u64, stats.conn_flood_batch.item_count), connect.items);
    }
    try fixture.expectMatchesRebuild(&system);
}

// The system's nav threads pinned to one item per range on `threads`.
fn forcedNavThreads(system: *PathfindingSystem, threads: *ThreadSystem) NavUpdateThreads {
    return .{
        .thread_system = threads,
        .plan_tuner = &system.nav_plan_tuner,
        .remask_tuner = &system.nav_remask_tuner,
        .patch_tuner = &system.nav_patch_tuner,
        .conn_seed_tuner = &system.nav_conn_seed_tuner,
        .conn_gather_tuner = &system.nav_conn_gather_tuner,
        .conn_flood_tuner = &system.nav_conn_flood_tuner,
        .conn_candidates_tuner = &system.nav_conn_candidates_tuner,
        .conn_closure_resolve_tuner = &system.nav_conn_closure_resolve_tuner,
        .conn_closure_mask_tuner = &system.nav_conn_closure_mask_tuner,
        .conn_closure_plan_tuner = &system.nav_conn_closure_plan_tuner,
        .conn_closure_rows_tuner = &system.nav_conn_closure_rows_tuner,
        .conn_closure_compact_tuner = &system.nav_conn_closure_compact_tuner,
        .adaptive = false,
        .items_per_range = 1,
    };
}

// A room of `edge` x `edge` open chunks inside a one-chunk wall ring whose corner is chunk
// (`x`, `y`); the ring's only opening is the gap chunk on its east side. Returns the gap.
fn ringedRoom(fixture: *TestWorld, x: u16, y: u16, edge: u16) ![2]u16 {
    const gap = [2]u16{ x + edge + 1, y + 1 + edge / 2 };
    for (0..edge + 2) |dy| for (0..edge + 2) |dx| {
        const cx: u16 = @intCast(x + dx);
        const cy: u16 = @intCast(y + dy);
        const ring = dx == 0 or dy == 0 or dx == edge + 1 or dy == edge + 1;
        if (!ring or (cx == gap[0] and cy == gap[1])) continue;
        try fixture.setChunk(null, 0, cx, cy, fixture.tree);
    };
    return gap;
}

const EncloseCase = enum { room_a, room_b, both, room_a_and_far_fill, room_a_walled_neighbour };

// Builds a level of `side` chunks with room A (and room B), applies the case's change in one
// batch, checks it against a full rebuild, and returns the flood nodes expanded.
fn encloseFloodNodes(side: u16, case: EncloseCase) !usize {
    var fixture = try TestWorld.init(side, 1);
    defer fixture.deinit();
    const gap_a = try ringedRoom(&fixture, 1, 1, 2);
    const gap_b = try ringedRoom(&fixture, side - 6, side - 6, 2);
    if (case == .room_a_walled_neighbour) {
        // The gap's east neighbour chunk gets a second label south of a long wall, which meets
        // the gap's side of the level only far away.
        const left: u16 = (gap_a[0] + 1) * test_chunk;
        const wall_y: u16 = gap_a[1] * test_chunk + 2;
        for (left + 1..(side - 1) * test_chunk) |cell_x| try fixture.setCell(null, 0, @intCast(cell_x), wall_y, fixture.tree);
        try fixture.setCell(null, 0, left, wall_y + 1, fixture.tree);
        try fixture.setCell(null, 0, left + 1, wall_y + 1, fixture.tree);
    }
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    switch (case) {
        .room_a, .room_a_walled_neighbour => try fixture.setChunk(&system, 0, gap_a[0], gap_a[1], fixture.tree),
        .room_b => try fixture.setChunk(&system, 0, gap_b[0], gap_b[1], fixture.tree),
        .both => {
            try fixture.setChunk(&system, 0, gap_a[0], gap_a[1], fixture.tree);
            try fixture.setChunk(&system, 0, gap_b[0], gap_b[1], fixture.tree);
        },
        .room_a_and_far_fill => {
            try fixture.setChunk(&system, 0, gap_a[0], gap_a[1], fixture.tree);
            try fixture.setCell(&system, 0, (side - 3) * test_chunk + 1, 2, fixture.tree);
        },
    }
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, if (case == .both) 2 else 1), stats.conn_splits);
    try fixture.expectMatchesRebuild(&system);
    return stats.conn_flood_nodes;
}

test "removals in one component flood only their own sides: two enclosures sum, a far fill and a walled neighbour label add nothing, all flat in level side" {
    var alone: ?[2]usize = null;
    for ([_]u16{ 16, 32, 64 }) |side| {
        const room_a = try encloseFloodNodes(side, .room_a);
        const room_b = try encloseFloodNodes(side, .room_b);
        try std.testing.expectEqual(room_a + room_b, try encloseFloodNodes(side, .both));
        try std.testing.expectEqual(room_a, try encloseFloodNodes(side, .room_a_and_far_fill));
        // The wall narrows the outside side's frontier; its search stays on the room's scale.
        const walled = try encloseFloodNodes(side, .room_a_walled_neighbour);
        try std.testing.expect(walled <= 2 * room_a);
        if (alone) |first| {
            try std.testing.expectEqual(first[0], room_a);
            try std.testing.expectEqual(first[1], walled);
        } else alone = .{ room_a, walled };
    }
}

// A ring corridor one chunk wide around an `edge` x `edge` solid block, walled off from the
// rest of a level of `side` chunks, cut on its west and east sides in one batch: the north and
// south arcs part. Returns the flood nodes expanded.
fn ringCutTwice(side: u16, edge: u16) !usize {
    const span = edge + 2;
    var fixture = try TestWorld.init(side, 1);
    defer fixture.deinit();
    for (1..span - 1) |cy| for (1..span - 1) |cx| try fixture.setChunk(null, 0, @intCast(cx), @intCast(cy), fixture.tree);
    for (0..span + 1) |i| {
        try fixture.setChunk(null, 0, span, @intCast(i), fixture.tree);
        try fixture.setChunk(null, 0, @intCast(i), span, fixture.tree);
    }
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const roots = system.graph.connectivity.rootCount();
    try fixture.setChunk(&system, 0, 0, span / 2, fixture.tree);
    try fixture.setChunk(&system, 0, span - 1, span / 2, fixture.tree);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.conn_splits);
    try std.testing.expectEqual(roots + 1, system.graph.connectivity.rootCount());
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), 0, fixture.cell(1, @as(usize, span - 1) * test_chunk + 1)) != .reaches);
    try fixture.expectMatchesRebuild(&system);
    return stats.conn_flood_nodes;
}

test "two cuts of one ring part its arcs, their floods meeting as one family, bounded by the smaller arc and flat in level side" {
    const edge: u16 = 4;
    // Each arc holds the ring's chunks but the two cut ones, halved.
    const arc: usize = (4 * (@as(usize, edge) + 1) - 2) / 2;
    var first: ?usize = null;
    for ([_]u16{ 16, 32, 64 }) |side| {
        const flood = try ringCutTwice(side, edge);
        try std.testing.expect(flood <= 4 * arc + 4);
        if (first) |nodes| try std.testing.expectEqual(nodes, flood) else first = flood;
    }
}

// `pockets` 2 x 2 chunk rooms off one open component of a level of `side` chunks, every gap
// filled in one batch on `system`.
fn enclosePockets(fixture: *TestWorld, systems: []const *PathfindingSystem, gaps: []const [2]u16) !void {
    for (gaps) |gap| {
        for (0..test_chunk) |dy| for (0..test_chunk) |dx| {
            try markAll(fixture, systems, 0, @intCast(gap[0] * test_chunk + dx), @intCast(gap[1] * test_chunk + dy), fixture.tree);
        };
    }
}

test "enclosing eight pockets of one component in one batch floods on workers, several searches per round, and equals the inline run" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 4, .items_per_range = 1 });
    defer threads.deinit();
    for ([_]u16{ 2, 8 }) |edge| {
        var fixture = try TestWorld.init(32, 1);
        defer fixture.deinit();
        var gaps: [8][2]u16 = undefined;
        // Eight small pockets, or one large one.
        const count: usize = if (edge == 2) 8 else 1;
        for (gaps[0..count], 0..) |*gap, index| {
            gap.* = try ringedRoom(&fixture, @intCast(1 + 6 * (index % 4)), @intCast(1 + 6 * (index / 4)), edge);
        }
        var inline_system = try fixture.build(test_support.abstractCapacity());
        defer inline_system.deinit();
        var capacity = test_support.abstractCapacity();
        capacity.worker_participant_count = threads.participantSlotCount();
        var threaded = try fixture.build(capacity);
        defer threaded.deinit();
        threaded.nav_thread_adaptive = false;
        threaded.nav_thread_items_per_range = 1;
        try enclosePockets(&fixture, &.{ &inline_system, &threaded }, gaps[0..count]);
        const serial = try inline_system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        const stats = try threaded.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
        try std.testing.expectEqual(count, stats.conn_splits);
        try std.testing.expectEqual(serial.conn_flood_nodes, stats.conn_flood_nodes);
        try std.testing.expect(!stats.conn_flood_batch.ran_inline);
        try std.testing.expect(stats.conn_flood_batch.item_count > stats.conn_rounds);
        try std.testing.expect(stats.conn_flood_batch.worker_thread_ranges != 0);
        try expectSameColumns(&inline_system.graph, &threaded.graph);
        try fixture.expectMatchesRebuild(&threaded);
    }
}

test "threaded floods equal inline ones column for column when families meet and rounds are narrow" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    for ([_]usize{ 1, 4 }) |workers| {
        var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = workers, .items_per_range = 1 });
        defer threads.deinit();
        for ([_]usize{ 1, 7 }) |items_per_range| {
            for ([_]bool{ true, false }) |narrow| {
                const span: u16 = 6;
                var fixture = try TestWorld.init(16, 1);
                defer fixture.deinit();
                // A ring cut twice (its families meet) and two pockets, enclosed in one batch.
                for (1..span - 1) |cy| for (1..span - 1) |cx| try fixture.setChunk(null, 0, @intCast(cx), @intCast(cy), fixture.tree);
                for (0..span + 1) |i| {
                    try fixture.setChunk(null, 0, span, @intCast(i), fixture.tree);
                    try fixture.setChunk(null, 0, @intCast(i), span, fixture.tree);
                }
                const gaps = [_][2]u16{ try ringedRoom(&fixture, 8, 1, 2), try ringedRoom(&fixture, 8, 8, 2), .{ 0, span / 2 }, .{ span - 1, span / 2 } };
                var inline_system = try fixture.build(test_support.abstractCapacity());
                defer inline_system.deinit();
                var capacity = test_support.abstractCapacity();
                capacity.worker_participant_count = threads.participantSlotCount();
                var threaded = try fixture.build(capacity);
                defer threaded.deinit();
                threaded.nav_thread_adaptive = false;
                threaded.nav_thread_items_per_range = items_per_range;
                if (narrow) {
                    // A window of one node's slack plus four: a few searches per round, so
                    // families wait for the window and resume at the cursor.
                    const slack = threaded.graph.levelGraph(0).?.border_stride + threaded.graph.connectivity.max_chunk_endpoints;
                    inline_system.graph.connectivity.flood_window = slack + 4;
                    threaded.graph.connectivity.flood_window = slack + 4;
                }
                for ([_]TileId{ fixture.tree, fixture.grass, fixture.tree }) |tile| {
                    for (gaps) |gap| {
                        for (0..test_chunk) |dy| for (0..test_chunk) |dx| {
                            try markAll(&fixture, &.{ &inline_system, &threaded }, 0, @intCast(gap[0] * test_chunk + dx), @intCast(gap[1] * test_chunk + dy), tile);
                        };
                    }
                    const serial = try inline_system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
                    const stats = try threaded.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
                    try std.testing.expectEqual(serial.conn_rounds, stats.conn_rounds);
                    try std.testing.expectEqual(serial.conn_flood_nodes, stats.conn_flood_nodes);
                    if (tile == fixture.tree and narrow) try std.testing.expect(stats.conn_rounds > 3);
                    try expectSameColumns(&inline_system.graph, &threaded.graph);
                    try fixture.expectMatchesRebuild(&threaded);
                }
            }
        }
    }
}

// Asserts every staging list of `conn` holds at most its size in `keep`.
fn expectStagingWithin(conn: *const Connectivity, keep: StagingSizes) !void {
    const t = std.testing;
    try t.expect(conn.seed_starts.capacity <= keep.changed_keys + 1 and conn.seed_counts.capacity <= keep.changed_keys);
    try t.expect(conn.seed_edges.capacity <= keep.seeds and conn.patch_changed.capacity <= keep.patch_keys);
    try t.expect(conn.row_starts.capacity <= keep.items + 1 and conn.edge_starts.capacity <= keep.items + 1);
    try t.expect(conn.row_counts.capacity <= keep.items and conn.edge_counts.capacity <= keep.items);
    try t.expect(conn.gather_rows.capacity <= keep.rows and conn.gather_edges.capacity <= keep.edges);
    try t.expect(conn.elements.capacity <= keep.elements and conn.units.capacity <= keep.elements);
    try t.expect(conn.sets.capacity <= keep.elements and conn.families.capacity <= keep.elements and conn.groups.capacity <= keep.elements);
    try t.expect(conn.element_map.keys.capacity <= try std.math.ceilPowerOfTwo(usize, @max(4 * keep.elements, 16)));
    for ([_]usize{ conn.unit_elements.capacity, conn.group_roots.capacity, conn.group_sets.capacity, conn.root_first.capacity, conn.round_sets.capacity }) |capacity| {
        try t.expect(capacity <= keep.elements);
    }
}

// Asserts every closure staging list of `conn` holds at most its size in `keep`.
fn expectClosureStagingWithin(conn: *const Connectivity, keep: StagingSizes) !void {
    const t = std.testing;
    const closure = &conn.closure;
    try t.expect(closure.cand_starts.capacity <= keep.patch_keys + 1 and closure.ow_starts.capacity <= keep.patch_keys + 1);
    try t.expect(closure.cand_counts.capacity <= keep.patch_keys and closure.cand_tallies.capacity <= keep.patch_keys and closure.ow_counts.capacity <= keep.patch_keys);
    try t.expect(closure.cand_hcomps.capacity <= keep.cand_entries and closure.ow_entries.capacity <= keep.ow_entries);
    try t.expect(closure.touched.capacity <= keep.closure_touched and closure.s_words.capacity <= keep.closure_s_words and closure.s_list.capacity <= keep.closure_k_cap);
    for ([_]usize{ closure.loose.capacity, closure.resolve_items.capacity, closure.resolve_out.capacity, closure.targets.capacity }) |capacity| {
        try t.expect(capacity <= keep.closure_links);
    }
    for ([_]usize{ closure.freed_terms.capacity, closure.slots.capacity, closure.pieces.capacity, closure.leaving.capacity, closure.freed_indices.capacity, closure.mask_items.capacity, closure.plan_items.capacity, closure.apos.capacity }) |capacity| {
        try t.expect(capacity <= keep.closure_terms);
    }
    try t.expect(closure.copy_items.capacity <= keep.closure_copy_items and closure.round_items.capacity <= keep.closure_round_items);
    try t.expect(closure.round_starts.capacity <= keep.closure_terms + 2 and closure.compact_blocks.capacity == 0);
}

test "a registry reserve counts each growth of its link map and one-way rows, and a covered reserve none" {
    var fixture = try latticeWorld(4, 1);
    defer fixture.deinit();
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const conn = &system.graph.connectivity;
    const link = LevelLink{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 0, .y = 0 }, .level_b = 0, .cell_b = .{ .x = 2, .y = 0 }, .traversal_cost = 1, .bidirectional = false };
    const links: [40]LevelLink = @splat(link);
    var grows: u64 = 0;
    try conn.reserveRegistry(std.testing.allocator, &links, &grows);
    try std.testing.expectEqual(@as(u64, 2), grows);
    try conn.reserveRegistry(std.testing.allocator, links[0..20], &grows);
    try std.testing.expectEqual(@as(u64, 2), grows);
}

test "a world build with one-way links leaves its closure staging at what a one-chunk batch needs" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, 0, 32);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const conn = &system.graph.connectivity;
    try std.testing.expectEqual(@as(usize, 32), conn.closure.termCount());
    const keep = conn.oneChunkStaging(system.graph.levelGraph(0).?.border_stride);
    try expectStagingWithin(conn, keep);
    try expectClosureStagingWithin(conn, keep);
    try fixture.expectMatchesRebuild(&system);
}

test "a level build shrinks its connectivity staging to what a one-chunk batch needs, and that batch then prepares without allocating" {
    var fixture = try TestWorld.init(16, 2);
    defer fixture.deinit();
    try buildRoom(&fixture, 3);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const conn = &system.graph.connectivity;
    const stride = system.graph.levelGraph(0).?.border_stride;
    // The world build's levels keep no more staging than one changed chunk needs.
    try expectStagingWithin(conn, conn.oneChunkStaging(stride));
    // An enclosure and its reopening warm the node pool, the free ids, and the round buffers.
    try fixture.setChunk(&system, 0, 3, 1, fixture.tree);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try fixture.setChunk(&system, 0, 3, 1, fixture.grass);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    const high = conn.marks_staging_high;
    // A level added in play shrinks back the same way.
    const level = try fixture.world.addLevel(-32);
    _ = try fixture.world.addDenseLayer(level, 0, .floor, fixture.grass);
    const added = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), added.levels_built);
    try expectStagingWithin(conn, high.max(conn.oneChunkStaging(stride)));
    // The same enclosure again: its prepare allocates nothing.
    try fixture.setChunk(&system, 0, 3, 1, fixture.tree);
    var stats = NavUpdateStats{};
    const original = system.graph.allocator;
    system.graph.allocator = std.testing.failing_allocator;
    const prepared = system.graph.prepareMarks(&fixture.world, no_colliders.view(), system.nav_marks.items, null, &stats);
    system.graph.allocator = original;
    const batch = system.graph.commitMarks((try prepared).?, no_colliders.view(), null, &stats);
    system.nav_marks.clearRetainingCapacity();
    try std.testing.expect(batch.changed);
    try std.testing.expectEqual(@as(usize, 1), stats.conn_splits);
    try fixture.expectMatchesRebuild(&system);
}

// A one-chunk tunnel of `length` chunks east from chunk (1, side / 2) of an open level of
// `side` chunks, capped at its far end, its mouth chunk filled in one batch. Checks the
// result against a full rebuild; returns the flood nodes expanded.
fn tunnelFloodNodes(side: u16, length: u16) !usize {
    var fixture = try TestWorld.init(side, 1);
    defer fixture.deinit();
    const row = side / 2;
    for (1..length + 2) |cx| {
        try fixture.setChunk(null, 0, @intCast(cx), row - 1, fixture.tree);
        try fixture.setChunk(null, 0, @intCast(cx), row + 1, fixture.tree);
    }
    try fixture.setChunk(null, 0, length + 1, row, fixture.tree);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    try fixture.setChunk(&system, 0, 1, row, fixture.tree);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.conn_splits);
    try fixture.expectMatchesRebuild(&system);
    return stats.conn_flood_nodes;
}

test "enclosing a thin tunnel off an open level floods on the tunnel's scale, flat in level side" {
    for ([_]u16{ 8, 16, 32 }) |length| {
        const near = try tunnelFloodNodes(length + 8, length);
        const far = try tunnelFloodNodes(2 * length + 16, length);
        // The open side searches at most half again the tunnel's claims per round.
        try std.testing.expect(near <= 3 * @as(usize, length));
        try std.testing.expectEqual(near, far);
    }
}

// `fixture`'s ringed room of `edge` x `edge` chunks at chunk (1, 1), enclosed in one batch on
// a system whose flood items stop at `budget_cap` proposals. Checks the result against a full
// rebuild and returns the system for comparison.
fn encloseRoomSystem(fixture: *TestWorld, edge: u16, budget_cap: u32) !struct { system: PathfindingSystem, stats: NavUpdateStats } {
    var system = try fixture.build(test_support.abstractCapacity());
    errdefer system.deinit();
    system.graph.connectivity.flood_budget_cap = budget_cap;
    try fixture.setChunk(&system, 0, edge + 2, 2 + edge / 2, fixture.tree);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.conn_splits);
    try fixture.expectMatchesRebuild(&system);
    return .{ .system = system, .stats = stats };
}

test "enclosing a room floods within a constant of the room, flat in level side" {
    const edge: u16 = 8;
    var first: ?usize = null;
    for ([_]u16{ 32, 64, 128 }) |side| {
        var fixture = try TestWorld.init(side, 1);
        defer fixture.deinit();
        _ = try ringedRoom(&fixture, 1, 1, edge);
        var enclosed = try encloseRoomSystem(&fixture, edge, default_flood_budget_cap);
        defer enclosed.system.deinit();
        const flood = enclosed.stats.conn_flood_nodes;
        // One node per room chunk.
        try std.testing.expect(2 * flood <= 5 * @as(usize, edge) * edge);
        if (first) |nodes| try std.testing.expectEqual(nodes, flood) else first = flood;
    }
}

test "a flood whose items stop at four proposals takes more rounds and partitions as the default one does" {
    const edge: u16 = 8;
    var fixture = try TestWorld.init(32, 1);
    defer fixture.deinit();
    _ = try ringedRoom(&fixture, 1, 1, edge);
    var wide = try encloseRoomSystem(&fixture, edge, default_flood_budget_cap);
    defer wide.system.deinit();
    try fixture.setChunk(null, 0, edge + 2, 2 + edge / 2, fixture.grass);
    var narrow = try encloseRoomSystem(&fixture, edge, 4);
    defer narrow.system.deinit();
    try std.testing.expect(narrow.stats.conn_rounds > wide.stats.conn_rounds);
    try std.testing.expect(narrow.stats.conn_round_items_max <= 2);
    try test_support.expectSameConnectivityPartition(&narrow.system.graph, &wide.system.graph);
}

// A comb on `fixture`'s level of `2 * tunnels` chunks: an open corridor along chunk row 0 and
// below it `tunnels` one-chunk dead-end tunnels on the even chunk columns, walled apart by the
// odd ones. Filling the corridor in one batch makes every tunnel mouth a set of one family.
// With `joined`, each odd tunnel meets the next at the level's bottom row, so their sets meet
// mid-flood: a set served in a round reaches the one the family's pass resumes at.
fn hubTunnels(fixture: *TestWorld, tunnels: u16, joined: bool) !void {
    const side = 2 * tunnels;
    for (1..side) |cy| {
        var cx: u16 = 1;
        while (cx < side) : (cx += 2) {
            const bottom_link = joined and cy == side - 1 and cx % 4 == 3 and cx + 1 < side - 1;
            if (!bottom_link) try fixture.setChunk(null, 0, cx, @intCast(cy), fixture.tree);
        }
    }
}

// Writes `tile` over the comb's corridor, marking `system` dirty.
fn setHubCorridor(fixture: *TestWorld, system: ?*PathfindingSystem, tunnels: u16, tile: TileId) !void {
    for (0..2 * tunnels) |cx| try fixture.setChunk(system, 0, @intCast(cx), 0, tile);
}

// One node's slack plus four proposal slots: a round holds a few searches.
fn narrowFloodWindow(system: *PathfindingSystem) void {
    const slack = system.graph.levelGraph(0).?.border_stride + system.graph.connectivity.max_chunk_endpoints;
    system.graph.connectivity.flood_window = slack + 4;
}

test "a hub family wider than one round walks each active set once per pass, not once per round" {
    const tunnels: u16 = 16;
    for ([_]bool{ false, true }) |joined| {
        var fixture = try TestWorld.init(2 * tunnels, 1);
        defer fixture.deinit();
        try hubTunnels(&fixture, tunnels, joined);
        const components: usize = if (joined) tunnels - (tunnels - 1) / 2 else tunnels;
        var runs: [2]NavUpdateStats = undefined;
        for ([_]bool{ false, true }, &runs) |narrow, *run| {
            var system = try fixture.build(test_support.abstractCapacity());
            defer system.deinit();
            if (narrow) narrowFloodWindow(&system);
            try setHubCorridor(&fixture, &system, tunnels, fixture.tree);
            run.* = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
            try std.testing.expectEqual(@as(usize, 1), run.conn_families);
            try std.testing.expectEqual(components - 1, run.conn_splits);
            try fixture.expectMatchesRebuild(&system);
            try setHubCorridor(&fixture, null, tunnels, fixture.grass);
        }
        const wide = runs[0];
        const narrow = runs[1];
        // Every wide round serves the whole family at first; a narrow one a few of its sets.
        try std.testing.expectEqual(@as(usize, tunnels), wide.conn_round_items_max);
        try std.testing.expect(4 * narrow.conn_round_items_max <= tunnels);
        try std.testing.expect(narrow.conn_rounds >= 4 * wide.conn_rounds);
        // Spreading a pass over rounds adds about one resumed set per round, never a walk of
        // the family per round.
        try std.testing.expect(narrow.conn_build_visits <= 2 * wide.conn_build_visits);
    }
}

test "a flooding reaction reaches its adaptive tuner as one sample at the batch's set count and selected profile" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 4 });
    defer threads.deinit();
    const tunnels: u16 = 16;
    // A fresh tuner selects inline. A tuner settled on a threaded profile selects ranges wider
    // than any narrow round, so every round runs as one range on the main thread, a shape
    // apart from the selection.
    for ([_]bool{ false, true }) |settled| {
        var fixture = try TestWorld.init(2 * tunnels, 1);
        defer fixture.deinit();
        try hubTunnels(&fixture, tunnels, false);
        var capacity = test_support.abstractCapacity();
        capacity.worker_participant_count = threads.participantSlotCount();
        var system = try fixture.build(capacity);
        defer system.deinit();
        try std.testing.expect(system.nav_thread_adaptive and system.nav_thread_items_per_range == null);
        narrowFloodWindow(&system);
        const tuner = &system.nav_conn_flood_tuner;
        if (settled) {
            tuner.phase = .settled;
            tuner.has_threaded_profile = true;
            tuner.current_profile = .{ .worker_threads = 2, .items_per_range = 4 };
        }
        var before = tuner.*;
        try setHubCorridor(&fixture, &system, tunnels, fixture.tree);
        const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
        try std.testing.expectEqual(@as(usize, tunnels - 1), stats.conn_splits);
        const set_count = system.graph.connectivity.sets.len;
        const selected = threads.selectBatchProfile(&before, .{ .item_count = set_count }).profile;
        try std.testing.expectEqual(settled, selected.worker_threads != 0);
        // Several rounds, one record.
        try std.testing.expect(stats.conn_rounds > 1);
        if (settled) try std.testing.expect(stats.conn_round_items_max <= selected.items_per_range);
        try std.testing.expectEqual(@as(usize, 1), tuner.sample_count);
        try std.testing.expectEqual(set_count, tuner.learned_item_count);
        // The sample carries the selected profile, not the rounds' shape, ...
        const sampled = tuner.sampled_profile.?;
        try std.testing.expectEqual(selected.worker_threads, sampled.worker_threads);
        if (settled) try std.testing.expectEqual(selected.items_per_range, sampled.items_per_range);
        // ... and the set count, not the rounds' summed items: the cost model's first sample
        // is the duration times the participants over the item count.
        const participants: f64 = @floatFromInt(sampled.worker_threads + 1);
        const per_item = @as(f64, @floatFromInt(tuner.sample_durations_ns[0])) * participants / @as(f64, @floatFromInt(set_count));
        try std.testing.expectApproxEqRel(per_item, tuner.model_work_ns_per_item, 1e-9);
        try fixture.expectMatchesRebuild(&system);
    }
}

test "level appends grow the comp and root pools geometrically" {
    var fixture = try TestWorld.init(8, 1);
    defer fixture.deinit();
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const conn = &system.graph.connectivity;
    var comp_grows: usize = 0;
    var root_grows: usize = 0;
    for (0..16) |index| {
        const comp_capacity = conn.comps.capacity;
        const root_capacity = conn.roots.capacity;
        const level = try fixture.world.addLevel(-16 * @as(i32, @intCast(index + 1)));
        _ = try fixture.world.addDenseLayer(level, 0, .floor, fixture.grass);
        const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        try std.testing.expectEqual(@as(usize, 1), stats.levels_built);
        comp_grows += @intFromBool(conn.comps.capacity != comp_capacity);
        root_grows += @intFromBool(conn.roots.capacity != root_capacity);
    }
    // At most a doubling per growth: log2(17) + 2.
    try std.testing.expect(comp_grows <= 7 and root_grows <= 7);
    try fixture.expectMatchesRebuild(&system);
}

test "a batch whose only change is a two-way link between unbuilt levels commits without allocating" {
    var fixture = try TestWorld.init(6, 1);
    defer fixture.deinit();
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    for (1..3) |level| {
        _ = try fixture.world.addLevel(-16 * @as(i32, @intCast(level)));
        _ = try fixture.world.addDenseLayer(@intCast(level), 0, .floor, fixture.grass);
    }
    try fixture.world.addLevelLink(.{ .kind = .stair, .level_a = 1, .cell_a = .{ .x = 2, .y = 2 }, .level_b = 2, .cell_b = .{ .x = 9, .y = 9 }, .traversal_cost = 3, .bidirectional = true });
    var stats = NavUpdateStats{};
    const prepared = (try system.graph.prepareMarks(&fixture.world, no_colliders.view(), &.{}, null, &stats)).?;
    try std.testing.expectEqual(@as(usize, 0), system.graph.patch_keys.items.len);
    const links_before = system.graph.links_applied;
    const original = system.graph.allocator;
    system.graph.allocator = std.testing.failing_allocator;
    const batch = system.graph.commitMarks(prepared, no_colliders.view(), null, &stats);
    system.graph.allocator = original;
    try std.testing.expect(!batch.changed);
    try std.testing.expectEqual(links_before + 1, system.graph.links_applied);
    // Building both levels later joins the link's ends.
    const built = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 2), built.levels_built);
    try std.testing.expect(reach(&system.graph, 1, fixture.cell(2, 2), 2, fixture.cell(9, 9)) == .reaches);
    try fixture.expectMatchesRebuild(&system);
}

// ----------------------------------------------------------------------------------------
// One-way closure tests
// ----------------------------------------------------------------------------------------

// A lattice level set: every cell with an odd coordinate blocked on each level, so every
// even cell is a one-cell room of its own (a root once a link endpoint makes it a portal).
fn latticeWorld(chunks: u16, levels: u16) !TestWorld {
    var fixture = try TestWorld.init(chunks, levels);
    errdefer fixture.deinit();
    const side = @as(usize, chunks) * test_chunk;
    for (0..levels) |level| for (0..side) |y| for (0..side) |x| {
        if (x % 2 == 1 or y % 2 == 1) try fixture.setCell(null, @intCast(level), @intCast(x), @intCast(y), fixture.tree);
    };
    return fixture;
}

// Room `index` of a lattice level `chunks` chunks wide, row-major.
fn latticeRoom(chunks: u16, index: usize) [2]u16 {
    const per_row = @as(usize, chunks) * test_chunk / 2;
    return .{ @intCast(2 * (index % per_row)), @intCast(2 * (index / per_row)) };
}

fn addOneWay(fixture: *TestWorld, from_level: u16, from: [2]u16, to_level: u16, to: [2]u16) !void {
    try fixture.world.addLevelLink(.{ .kind = .teleport, .level_a = from_level, .cell_a = .{ .x = from[0], .y = from[1] }, .level_b = to_level, .cell_b = .{ .x = to[0], .y = to[1] }, .traversal_cost = 1, .bidirectional = false });
}

// A one-way chain over lattice rooms `first`..`first + count` of `level`: room i reaches
// room i + 1.
fn addChain(fixture: *TestWorld, chunks: u16, level: u16, first: usize, count: usize) !void {
    for (first..first + count - 1) |index| try addOneWay(fixture, level, latticeRoom(chunks, index), level, latticeRoom(chunks, index + 1));
}

fn setRoom(fixture: *TestWorld, system: ?*PathfindingSystem, chunks: u16, level: u16, index: usize, tile: TileId) !void {
    const room = latticeRoom(chunks, index);
    try fixture.setCell(system, level, room[0], room[1], tile);
}

// The cell between lattice rooms `index` and `index + 1` of one row.
fn latticeWall(chunks: u16, index: usize) [2]u16 {
    const room = latticeRoom(chunks, index);
    return .{ room[0] + 1, room[1] };
}

// Asserts a nav update's closure stayed within the bound its batch prepared, not merely within
// the reserved capacity: terminals popped and gained over the candidates', slots, pieces,
// resolve and loose lists, copy and rows items, the relocated blocks' caps, and the arena tail
// words they took. An update that also built levels checks only its tail words.
fn expectWithinBounds(closure: *const Closure, stats: NavUpdateStats) !void {
    const t = std.testing;
    try t.expect(stats.closure_tail_used <= stats.closure_tail_bound);
    if (stats.closure_links == 0 or stats.levels_built != 0) return;
    const limits = closure.limits;
    try t.expect(stats.closure_terms_new <= limits.n_gross);
    try t.expect(closure.slots.len <= limits.k_c + limits.n_net);
    try t.expect(closure.slots.len <= limits.k_b and closure.pieces.len <= limits.pieces);
    try t.expect(closure.resolve_items.items.len <= limits.e_t and closure.loose.items.len <= limits.loose);
    try t.expect(closure.copy_items.items.len <= limits.copy_items and closure.round_items.items.len <= limits.round_items);
    try t.expect(stats.closure_tail_used <= limits.arena_tail);
    const pieces = closure.pieces.slice();
    for (pieces.items(.relocated), pieces.items(.k_cap)) |relocated, k_cap| {
        if (relocated) try t.expect(k_cap <= limits.q_max);
    }
}

// Applies `system`'s buffered nav updates and asserts its closure stayed within its bound.
fn applyWithinBounds(fixture: *TestWorld, system: *PathfindingSystem) !NavUpdateStats {
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try expectWithinBounds(&system.graph.connectivity.closure, stats);
    return stats;
}

test "the closure equals a full recompute after one-way adds, endpoint toggles, B-merges and splits, a component falling apart, and level appends and replaces" {
    const chunks: u16 = 6;
    var fixture = try latticeWorld(chunks, 2);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, 0, 4);
    try addChain(&fixture, chunks, 0, 10, 2);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    try fixture.expectMatchesRebuild(&system);
    try std.testing.expectEqual(@as(usize, 2), system.graph.connectivity.closure.hcompCount());
    // A link within one component, then one joining two.
    try addOneWay(&fixture, 0, latticeRoom(chunks, 3), 0, latticeRoom(chunks, 1));
    _ = try applyWithinBounds(&fixture, &system);
    try fixture.expectMatchesRebuild(&system);
    try addOneWay(&fixture, 0, latticeRoom(chunks, 3), 1, latticeRoom(chunks, 40));
    try addOneWay(&fixture, 1, latticeRoom(chunks, 40), 0, latticeRoom(chunks, 10));
    _ = try applyWithinBounds(&fixture, &system);
    try fixture.expectMatchesRebuild(&system);
    try std.testing.expectEqual(@as(usize, 1), system.graph.connectivity.closure.hcompCount());
    // An endpoint closed and reopened: the component falls apart and rejoins.
    for ([_]TileId{ fixture.tree, fixture.grass }) |tile| {
        try setRoom(&fixture, &system, chunks, 1, 40, tile);
        _ = try applyWithinBounds(&fixture, &system);
        try fixture.expectMatchesRebuild(&system);
    }
    // A terminal leaving: the chain head's room closed.
    try setRoom(&fixture, &system, chunks, 0, 0, fixture.tree);
    _ = try applyWithinBounds(&fixture, &system);
    try fixture.expectMatchesRebuild(&system);
    // B-merge of two terminal roots (the wall between rooms 1 and 2 opened), then the split.
    for ([_]TileId{ fixture.grass, fixture.tree }) |tile| {
        const wall = latticeWall(chunks, 1);
        try fixture.setCell(&system, 0, wall[0], wall[1], tile);
        _ = try applyWithinBounds(&fixture, &system);
        try fixture.expectMatchesRebuild(&system);
    }
    // A level appended holding one-way ends, in the same reaction as the links to it.
    const level = try fixture.world.addLevel(-32);
    _ = try fixture.world.addDenseLayer(level, 0, .floor, fixture.grass);
    fixture.obstacle[level] = try fixture.world.addDenseLayer(level, 0, .obstacle, fixture.grass);
    try addOneWay(&fixture, level, .{ 3, 3 }, 0, latticeRoom(chunks, 2));
    try addOneWay(&fixture, 0, latticeRoom(chunks, 11), level, .{ 20, 20 });
    const appended = try applyWithinBounds(&fixture, &system);
    try std.testing.expectEqual(@as(usize, 1), appended.levels_built);
    try fixture.expectMatchesRebuild(&system);
    try std.testing.expect(reach(&system.graph, level, fixture.cell(3, 3), 0, fixture.cell(latticeRoom(chunks, 3)[0], latticeRoom(chunks, 3)[1])) == .reaches);
    // Replacing level 1 with a blocking layer drops its terminals.
    const terms = system.graph.connectivity.closure.termCount();
    _ = try fixture.world.addDenseLayer(1, 0, .obstacle, fixture.tree);
    const replaced = try applyWithinBounds(&fixture, &system);
    try std.testing.expectEqual(@as(usize, 1), replaced.levels_built);
    try std.testing.expect(system.graph.connectivity.closure.termCount() < terms);
    try fixture.expectMatchesRebuild(&system);
}

test "two hundred seeded random steps of one-way links, endpoint toggles, and wall digs and fills match a full recompute after each" {
    var prng = std.Random.DefaultPrng.init(0x1b1b);
    const random = prng.random();
    const chunks: u16 = 4;
    const rooms = @as(usize, chunks) * test_chunk / 2 * (@as(usize, chunks) * test_chunk / 2);
    var fixture = try latticeWorld(chunks, 2);
    defer fixture.deinit();
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    for (0..200) |step| {
        for (0..1 + random.uintLessThan(usize, 3)) |_| {
            const level = random.uintLessThan(u16, 2);
            switch (random.uintLessThan(u8, 3)) {
                // A room closed or opened.
                0 => try setRoom(&fixture, &system, chunks, level, random.uintLessThan(usize, rooms), if (random.boolean()) fixture.tree else fixture.grass),
                // A wall cell dug or filled: rooms merge or split.
                else => {
                    const x = random.uintLessThan(u16, chunks * test_chunk);
                    const y = random.uintLessThan(u16, chunks * test_chunk);
                    if (x % 2 == 1 or y % 2 == 1) try fixture.setCell(&system, level, x, y, if (random.uintLessThan(u8, 3) == 0) fixture.tree else fixture.grass);
                },
            }
        }
        if (step % 4 == 0) {
            try fixture.world.addLevelLink(.{
                .kind = .teleport,
                .level_a = random.uintLessThan(u16, 2),
                .cell_a = blk: {
                    const room = latticeRoom(chunks, random.uintLessThan(usize, rooms));
                    break :blk .{ .x = room[0], .y = room[1] };
                },
                .level_b = random.uintLessThan(u16, 2),
                .cell_b = blk: {
                    const room = latticeRoom(chunks, random.uintLessThan(usize, rooms));
                    break :blk .{ .x = room[0], .y = room[1] };
                },
                .traversal_cost = 1,
                .bidirectional = random.uintLessThan(u8, 5) == 0,
            });
        }
        const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        try expectWithinBounds(&system.graph.connectivity.closure, stats);
        try fixture.expectMatchesRebuild(&system);
    }
    // The run grew real one-way systems.
    try std.testing.expect(system.graph.connectivity.closure.termCount() > 8);
}

// The row words of `term` in its component's block.
fn termRow(closure: *const Closure, term: u32) []const u32 {
    const hcomp = closure.term.hcomp[term];
    const words = rowWords(closure.hcomp.k_cap[hcomp]);
    return closure.words.items[closure.hcomp.block[hcomp] + @as(usize, closure.term.index[term]) * words ..][0..words];
}

// The terminal of lattice room `index` on `level`.
fn roomTerm(system: *const PathfindingSystem, fixture: *const TestWorld, chunks: u16, level: u16, index: usize) u32 {
    const room = latticeRoom(chunks, index);
    const cell = fixture.cell(room[0], room[1]);
    const graph = &system.graph;
    const grid = graph.grid(level).?;
    const row = graph.levelGraph(level).?.nodeOf(grid.chunkOfCell(cell), grid.labelAt(cell));
    std.debug.assert(row != no_node);
    return graph.connectivity.root_term[graph.connectivity.comp_root[graph.levelGraph(level).?.node_comp[row]]];
}

test "reopening a chain's head recomputes only the head's row; every other row stays bitwise" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    // Rooms 1..7 of row 0: the head alone in its chunk among the chain's rooms (a remasked
    // chunk's nodes all take fresh roots).
    try addChain(&fixture, chunks, 0, 1, 7);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    var before: [8][1]u32 = undefined;
    for (2..8) |index| @memcpy(&before[index], termRow(closure, roomTerm(&system, &fixture, chunks, 0, index)));
    try setRoom(&fixture, &system, chunks, 0, 1, fixture.tree);
    const closed = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    // The head left: its only out-edge's source; no other row reaches it.
    try std.testing.expectEqual(@as(usize, 0), closed.closure_a_rows);
    try std.testing.expectEqual(@as(usize, 1), closed.closure_terms_left);
    try setRoom(&fixture, &system, chunks, 0, 1, fixture.grass);
    const opened = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), opened.closure_a_rows);
    for (2..8) |index| try std.testing.expectEqualSlices(u32, &before[index], termRow(closure, roomTerm(&system, &fixture, chunks, 0, index)));
    try fixture.expectMatchesRebuild(&system);
}

test "a batch where one terminal leaves and another joins a full block reuses the freed index: the block keeps its capacity and words" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    // Rooms 0..7 of row 0: eight terminals fill their block.
    try addChain(&fixture, chunks, 0, 0, 8);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    const head = roomTerm(&system, &fixture, chunks, 0, 0);
    const id = closure.term.hcomp[head];
    try std.testing.expectEqual(@as(u32, 8), closure.hcomp.k_cap[id]);
    try std.testing.expectEqual(@as(u32, 8), closure.hcomp.k_high[id]);
    const live_words = closure.live_words;
    // One batch: the tail's room closed, and a new link from the chain to room 20.
    try setRoom(&fixture, &system, chunks, 0, 7, fixture.tree);
    try addOneWay(&fixture, 0, latticeRoom(chunks, 6), 0, latticeRoom(chunks, 20));
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expect(stats.closure_terms_left != 0);
    try std.testing.expectEqual(stats.closure_terms_left, stats.closure_terms_new);
    try std.testing.expectEqual(id, closure.term.hcomp[head]);
    try std.testing.expectEqual(@as(u32, 8), closure.hcomp.k_cap[id]);
    try std.testing.expectEqual(@as(u32, 8), closure.hcomp.k_high[id]);
    try std.testing.expectEqual(live_words, closure.live_words);
    try std.testing.expectEqual(@as(usize, 0), closure.dead_words);
    try fixture.expectMatchesRebuild(&system);
}

test "a dig touching no one-way system runs no closure item and writes no arena word; a world without one-way links skips the candidate scan" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, 0, 6);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const words = try std.testing.allocator.dupe(u32, system.graph.connectivity.closure.words.items);
    defer std.testing.allocator.free(words);
    // Two rooms with no endpoint joined, far from the chain's row.
    const wall = latticeWall(chunks, 60);
    try fixture.setCell(&system, 0, wall[0], wall[1], fixture.grass);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expect(stats.conn_candidates_batch.item_count != 0);
    try std.testing.expectEqual(@as(usize, 0), stats.conn_closure_resolve_batch.item_count);
    try std.testing.expectEqual(@as(usize, 0), stats.conn_closure_mask_batch.item_count);
    try std.testing.expectEqual(@as(usize, 0), stats.conn_closure_plan_batch.item_count);
    try std.testing.expectEqual(@as(usize, 0), stats.conn_closure_rows_batch.item_count);
    try std.testing.expectEqual(@as(usize, 0), stats.closure_words_written);
    try std.testing.expectEqualSlices(u32, words, system.graph.connectivity.closure.words.items);
    try fixture.expectMatchesRebuild(&system);

    var plain = try latticeWorld(chunks, 1);
    defer plain.deinit();
    var plain_system = try plain.build(test_support.abstractCapacity());
    defer plain_system.deinit();
    try plain.setCell(&plain_system, 0, wall[0], wall[1], plain.grass);
    const plain_stats = try plain_system.applyBufferedNavUpdates(no_colliders, &plain.world, null);
    try std.testing.expectEqual(@as(usize, 0), plain_stats.conn_candidates_batch.item_count);
    try std.testing.expect(!plain_system.graph.connectivity.closure.active);
}

test "the closure's row OR and mask kernels equal their scalar forms over row widths of one to nine words" {
    var prng = std.Random.DefaultPrng.init(0x14);
    const random = prng.random();
    for (1..10) |width| {
        for (0..32) |_| {
            var acc: [9]u32 = undefined;
            var row: [9]u32 = undefined;
            var mask: [9]u32 = undefined;
            for (acc[0..width], row[0..width], mask[0..width]) |*a, *r, *m| {
                a.* = random.int(u32);
                r.* = random.int(u32);
                // Sparse masks, so both answers occur.
                m.* = if (random.uintLessThan(u8, 4) == 0) @as(u32, 1) << random.int(u5) else 0;
            }
            var expected: [9]u32 = undefined;
            for (expected[0..width], acc[0..width], row[0..width]) |*e, a, r| e.* = a | r;
            var shares = false;
            for (row[0..width], mask[0..width]) |r, m| shares = shares or r & m != 0;
            orInto(acc[0..width], row[0..width]);
            try std.testing.expectEqualSlices(u32, expected[0..width], acc[0..width]);
            try std.testing.expectEqual(shares, sharesBit(row[0..width], mask[0..width]));
        }
    }
}

// Closes (`tree`) or opens lattice room `index` of level 0 on every system in `systems`.
fn markRoom(fixture: *TestWorld, systems: []const *PathfindingSystem, chunks: u16, index: usize, tile: TileId) !void {
    const room = latticeRoom(chunks, index);
    try markAll(fixture, systems, 0, room[0], room[1], tile);
}

// Which closure stages a batch ran on workers.
const ClosureStagesOnWorkers = struct {
    candidates: bool = false,
    resolve: bool = false,
    mask: bool = false,
    plan: bool = false,
    rows: bool = false,
    compact: bool = false,

    fn add(self: *ClosureStagesOnWorkers, stats: NavUpdateStats) void {
        self.candidates = self.candidates or onWorkers(stats.conn_candidates_batch);
        self.resolve = self.resolve or onWorkers(stats.conn_closure_resolve_batch);
        self.mask = self.mask or onWorkers(stats.conn_closure_mask_batch);
        self.plan = self.plan or onWorkers(stats.conn_closure_plan_batch);
        self.rows = self.rows or onWorkers(stats.conn_closure_rows_batch);
        self.compact = self.compact or onWorkers(stats.conn_closure_compact_batch);
    }

    fn onWorkers(batch: BatchStats) bool {
        return batch.item_count != 0 and !batch.ran_inline and batch.worker_thread_ranges != 0;
    }
};

test "threaded closure stages equal the inline ones word for word across worker counts and range sizes, and each runs on workers" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const chunks: u16 = 8;
    for ([_]usize{ 1, 2, 4 }) |workers| {
        var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = workers, .items_per_range = 1 });
        defer threads.deinit();
        for ([_]usize{ 1, 2, 7 }) |items_per_range| {
            var fixture = try latticeWorld(chunks, 1);
            defer fixture.deinit();
            // Chains A (32 rooms), B (9), C (8), and D (112).
            try addChain(&fixture, chunks, 0, 16, 32);
            try addChain(&fixture, chunks, 0, 64, 9);
            try addChain(&fixture, chunks, 0, 128, 8);
            try addChain(&fixture, chunks, 0, 144, 112);
            var inline_system = try fixture.build(test_support.abstractCapacity());
            defer inline_system.deinit();
            var capacity = test_support.abstractCapacity();
            capacity.worker_participant_count = threads.participantSlotCount();
            var threaded = PathfindingSystem.init(std.testing.allocator);
            defer threaded.deinit();
            try threaded.reserve(capacity);
            threaded.nav_thread_adaptive = false;
            threaded.nav_thread_items_per_range = items_per_range;
            // The world build's closure runs threaded.
            try threaded.rebuildStaticNavGridWithWorld(&fixture.data, &fixture.world, &threads);
            try expectSameColumns(&inline_system.graph, &threaded.graph);
            const systems = [_]*PathfindingSystem{ &inline_system, &threaded };
            var on_workers = ClosureStagesOnWorkers{};
            // Every tail closed, then reopened; chain A wholly closed (its block dies); B's
            // tail closed (the arena compacts first); B's tail reopened while D loses all but
            // 24 rooms (its block narrows).
            for (0..5) |step| {
                switch (step) {
                    0, 1 => for ([_]usize{ 47, 72, 135, 255 }) |tail| try markRoom(&fixture, &systems, chunks, tail, if (step == 0) fixture.tree else fixture.grass),
                    2 => for (16..48) |room| try markRoom(&fixture, &systems, chunks, room, fixture.tree),
                    3 => try markRoom(&fixture, &systems, chunks, 72, fixture.tree),
                    else => {
                        try markRoom(&fixture, &systems, chunks, 72, fixture.grass);
                        for (144..232) |room| try markRoom(&fixture, &systems, chunks, room, fixture.tree);
                    },
                }
                const serial = try inline_system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
                const stats = try threaded.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
                try expectWithinBounds(&inline_system.graph.connectivity.closure, serial);
                try expectWithinBounds(&threaded.graph.connectivity.closure, stats);
                on_workers.add(stats);
                try std.testing.expectEqual(serial.closure_shrinks, stats.closure_shrinks);
                if (step == 4) {
                    try std.testing.expectEqual(@as(usize, 1), stats.closure_shrinks);
                    if (workers == 4 and items_per_range == 1) {
                        try std.testing.expect(ClosureStagesOnWorkers.onWorkers(stats.conn_closure_plan_batch));
                        try std.testing.expect(ClosureStagesOnWorkers.onWorkers(stats.conn_closure_rows_batch));
                    }
                }
                try expectSameColumns(&inline_system.graph, &threaded.graph);
                try fixture.expectMatchesRebuild(&threaded);
            }
            try std.testing.expect(threaded.graph.connectivity.closure.compactions != 0);
            if (workers == 4 and items_per_range == 1) {
                try std.testing.expect(on_workers.candidates and on_workers.resolve and on_workers.mask);
                try std.testing.expect(on_workers.plan and on_workers.rows and on_workers.compact);
            }
        }
    }
}

test "a one-way toggle and a terminal root split prepared with the real allocator commit on a multi-worker ThreadSystem without allocating" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const chunks: u16 = 8;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, 16, 8);
    // Rooms 20 and 21 share one root (and one terminal) through their opened wall.
    const wall = latticeWall(chunks, 20);
    try fixture.setCell(null, 0, wall[0], wall[1], fixture.grass);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 4, .items_per_range = 1 });
    defer threads.deinit();
    var capacity = test_support.abstractCapacity();
    capacity.worker_participant_count = threads.participantSlotCount();
    var system = try fixture.build(capacity);
    defer system.deinit();
    const nav_threads = forcedNavThreads(&system, &threads);
    try fixture.setCell(&system, 0, wall[0], wall[1], fixture.tree);
    try setRoom(&fixture, &system, chunks, 0, 23, fixture.tree);
    var stats = NavUpdateStats{};
    const prepared = (try system.graph.prepareMarks(&fixture.world, no_colliders.view(), system.nav_marks.items, nav_threads, &stats)).?;
    const original = system.graph.allocator;
    system.graph.allocator = std.testing.failing_allocator;
    const batch = system.graph.commitMarks(prepared, no_colliders.view(), nav_threads, &stats);
    system.graph.allocator = original;
    system.nav_marks.clearRetainingCapacity();
    try std.testing.expect(batch.changed);
    try std.testing.expect(stats.closure_terms_new != 0 and stats.closure_a_rows != 0);
    try std.testing.expect(!stats.conn_closure_resolve_batch.ran_inline and !stats.conn_closure_mask_batch.ran_inline);
    try expectWithinBounds(&system.graph.connectivity.closure, stats);
    try fixture.expectMatchesRebuild(&system);
}

test "repeated one-way toggles and terminal splits and merges return terminals, components, words, and links to their counts; the arena stays within twice its live words plus a batch's tail" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, 1, 7);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    const Counts = struct { terms: usize, hcomps: usize, live_words: usize, term_pool: usize, links: usize };
    const counts = struct {
        fn of(c: *const Closure) Counts {
            var links: usize = 0;
            for (c.hcomp.k_cap, c.hcomp.link_count) |k_cap, count| links += if (k_cap != 0) count else 0;
            return .{ .terms = c.termCount(), .hcomps = c.hcompCount(), .live_words = c.live_words, .term_pool = c.terms.len, .links = links };
        }
    }.of;
    var start: ?Counts = null;
    const wall = latticeWall(chunks, 3);
    for (0..6) |_| {
        // The tail toggled, then the wall between rooms 3 and 4 opened and closed.
        for ([_]TileId{ fixture.tree, fixture.grass }) |tile| {
            try setRoom(&fixture, &system, chunks, 0, 7, tile);
            _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
            try std.testing.expect(closure.words.items.len <= 2 * closure.live_words + closure.limits.arena_tail);
        }
        for ([_]TileId{ fixture.grass, fixture.tree }) |tile| {
            try fixture.setCell(&system, 0, wall[0], wall[1], tile);
            _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
            try std.testing.expect(closure.words.items.len <= 2 * closure.live_words + closure.limits.arena_tail);
        }
        if (start) |first| try std.testing.expectEqual(first, counts(closure)) else start = counts(closure);
    }
    try fixture.expectMatchesRebuild(&system);
}

// Rooms 128..255 of an 8-chunk lattice level (its second half, every room open) hold a
// one-way chain: one block of 128.
const narrow_first: usize = 128;
const narrow_tail: usize = 255;

// Sets the narrow chain's first 100 rooms to `tile` in one batch: closed, 28 terminals
// remain. Returns the batch's stats.
fn narrowChain(fixture: *TestWorld, system: *PathfindingSystem, tile: TileId) !NavUpdateStats {
    for (narrow_first..narrow_first + 100) |room| try setRoom(fixture, system, 8, 0, room, tile);
    return system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
}

// The H-component of lattice room `index`'s terminal on level 0.
fn roomHComp(system: *const PathfindingSystem, fixture: *const TestWorld, chunks: u16, index: usize) u32 {
    return system.graph.connectivity.closure.term.hcomp[roomTerm(system, fixture, chunks, 0, index)];
}

test "a one-way system that loses most of its terminals narrows its block, and the next nav batch reclaims the old one" {
    const chunks: u16 = 8;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, narrow_first, 128);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    try std.testing.expectEqual(@as(u32, 128), closure.hcomp.k_cap[roomHComp(&system, &fixture, chunks, narrow_tail)]);
    const cut = try narrowChain(&fixture, &system, fixture.tree);
    try std.testing.expectEqual(@as(usize, 1), cut.closure_shrinks);
    const id = roomHComp(&system, &fixture, chunks, narrow_tail);
    try std.testing.expectEqual(@as(u32, 64), closure.hcomp.k_cap[id]);
    try std.testing.expectEqual(@as(u32, 28), closure.hcomp.k_high[id]);
    try std.testing.expectEqual(@as(u32, 28), closure.hcomp.k_live[id]);
    try std.testing.expectEqual(blockWords(64), closure.live_words);
    try fixture.expectMatchesRebuild(&system);
    // A dig far from every endpoint touches no component, yet reclaims the dead block.
    const compactions = closure.compactions;
    const wall = latticeWall(chunks, 40);
    try fixture.setCell(&system, 0, wall[0], wall[1], fixture.grass);
    const far = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 0), far.closure_links);
    try std.testing.expectEqual(compactions + 1, closure.compactions);
    try std.testing.expectEqual(closure.live_words, closure.words.items.len);
    try std.testing.expectEqual(@as(usize, 0), closure.dead_words);
    try std.testing.expect(closure.arena_limit <= closure.live_words + closure.live_words / 2);
    // A tail toggle writes rows two words wide.
    try setRoom(&fixture, &system, chunks, 0, narrow_tail, fixture.tree);
    const toggle = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expect(toggle.closure_words_written <= (toggle.closure_a_rows + toggle.closure_terms_left + toggle.closure_terms_new) * 2);
    try fixture.expectMatchesRebuild(&system);
}

test "a system at its narrowed size neither narrows nor grows under toggles, and regrowing then narrowing again returns its block and words" {
    const chunks: u16 = 8;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, narrow_first, 128);
    // A second system the cycle kills.
    try addChain(&fixture, chunks, 0, 0, 4);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    _ = try narrowChain(&fixture, &system, fixture.tree);
    const id = roomHComp(&system, &fixture, chunks, narrow_tail);
    const narrowed = .{ closure.hcomp.k_cap[id], closure.hcomp.k_high[id], closure.live_words };
    // The first toggle's prepare compacts the dead block away; the block stays put after.
    var block: ?u32 = null;
    for (0..8) |toggle| {
        try setRoom(&fixture, &system, chunks, 0, narrow_tail, if (toggle % 2 == 0) fixture.tree else fixture.grass);
        const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        try std.testing.expectEqual(@as(usize, 0), stats.closure_shrinks);
        try std.testing.expectEqual(narrowed[0], closure.hcomp.k_cap[id]);
        if (block) |offset| try std.testing.expectEqual(offset, closure.hcomp.block[id]) else block = closure.hcomp.block[id];
    }
    try std.testing.expectEqual(narrowed[2], closure.live_words);
    // Reopened, the system regrows past its narrowed block.
    _ = try narrowChain(&fixture, &system, fixture.grass);
    try std.testing.expectEqual(@as(u32, 128), closure.hcomp.k_cap[roomHComp(&system, &fixture, chunks, narrow_tail)]);
    try fixture.expectMatchesRebuild(&system);
    // Closed again with the second system: one narrowing, the same block size and words.
    for (0..4) |room| try setRoom(&fixture, &system, chunks, 0, room, fixture.tree);
    const again = try narrowChain(&fixture, &system, fixture.tree);
    try std.testing.expectEqual(@as(usize, 1), again.closure_shrinks);
    const regrown = roomHComp(&system, &fixture, chunks, narrow_tail);
    try std.testing.expectEqual(narrowed[0], closure.hcomp.k_cap[regrown]);
    try std.testing.expectEqual(narrowed[1], closure.hcomp.k_high[regrown]);
    try std.testing.expectEqual(@as(usize, 1), closure.hcompCount());
    try std.testing.expectEqual(narrowed[2] - blockWords(4), closure.live_words);
    // The next batch compacts the relocated and dead blocks away: the arena holds exactly
    // the live words.
    try std.testing.expect(closure.dead_words > closure.live_words);
    const wall = latticeWall(chunks, 40);
    try fixture.setCell(&system, 0, wall[0], wall[1], fixture.grass);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(closure.live_words, closure.words.items.len);
    try fixture.expectMatchesRebuild(&system);
}

test "the heir of a component that falls into five pieces narrows; the other pieces take blocks sized to their terminals" {
    const chunks: u16 = 8;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, narrow_first, 128);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    for ([_]usize{ 25, 50, 75, 100 }) |cut| try setRoom(&fixture, &system, chunks, 0, narrow_first + cut, fixture.tree);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.closure_shrinks);
    try std.testing.expectEqual(@as(usize, 5), closure.hcompCount());
    try std.testing.expectEqual(@as(u32, 64), closure.hcomp.k_cap[roomHComp(&system, &fixture, chunks, narrow_tail)]);
    for ([_]usize{ 0, 26, 51, 76 }) |first| try std.testing.expectEqual(@as(u32, 32), closure.hcomp.k_cap[roomHComp(&system, &fixture, chunks, narrow_first + first)]);
    try std.testing.expectEqual(blockWords(64) + 4 * blockWords(32), closure.live_words);
    try fixture.expectMatchesRebuild(&system);
}

test "a block narrowing prepared with the real allocator commits on a multi-worker ThreadSystem without allocating" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const chunks: u16 = 8;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, narrow_first, 128);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 4, .items_per_range = 1 });
    defer threads.deinit();
    var capacity = test_support.abstractCapacity();
    capacity.worker_participant_count = threads.participantSlotCount();
    var system = try fixture.build(capacity);
    defer system.deinit();
    const nav_threads = forcedNavThreads(&system, &threads);
    for (narrow_first..narrow_first + 100) |room| try setRoom(&fixture, &system, chunks, 0, room, fixture.tree);
    var stats = NavUpdateStats{};
    const prepared = (try system.graph.prepareMarks(&fixture.world, no_colliders.view(), system.nav_marks.items, nav_threads, &stats)).?;
    const original = system.graph.allocator;
    system.graph.allocator = std.testing.failing_allocator;
    _ = system.graph.commitMarks(prepared, no_colliders.view(), nav_threads, &stats);
    system.graph.allocator = original;
    system.nav_marks.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 1), stats.closure_shrinks);
    try std.testing.expect(!stats.conn_closure_rows_batch.ran_inline);
    try expectWithinBounds(&system.graph.connectivity.closure, stats);
    try fixture.expectMatchesRebuild(&system);
}

test "a fill splitting one terminal root holding sixteen one-way endpoints in far chunks yields sixteen terminals within the prepared reserve and its bound" {
    const tunnels: u16 = 16;
    var fixture = try TestWorld.init(2 * tunnels, 2);
    defer fixture.deinit();
    try hubTunnels(&fixture, tunnels, false);
    // Each tunnel's far end reaches one open level-1 area.
    var tunnel: u16 = 0;
    while (tunnel < tunnels) : (tunnel += 1) {
        try addOneWay(&fixture, 0, .{ 2 * tunnel * test_chunk + 1, (2 * tunnels - 1) * test_chunk + 1 }, 1, .{ 1, 1 });
    }
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    try std.testing.expectEqual(@as(usize, 2), system.graph.connectivity.closure.termCount());
    try setHubCorridor(&fixture, &system, tunnels, fixture.tree);
    var stats = NavUpdateStats{};
    const prepared = (try system.graph.prepareMarks(&fixture.world, no_colliders.view(), system.nav_marks.items, null, &stats)).?;
    const original = system.graph.allocator;
    system.graph.allocator = std.testing.failing_allocator;
    _ = system.graph.commitMarks(prepared, no_colliders.view(), null, &stats);
    system.graph.allocator = original;
    system.nav_marks.clearRetainingCapacity();
    // Every tunnel takes its own root; the first in link order takes the corridor's terminal
    // back, the rest pop new ones, and none leaves. The tunnels' mouths are the seed edges
    // whose kept far end held the terminal: the bound counts each.
    try std.testing.expectEqual(@as(usize, tunnels + 1), system.graph.connectivity.closure.termCount());
    try std.testing.expectEqual(@as(usize, tunnels - 1), stats.closure_terms_new);
    try std.testing.expectEqual(@as(usize, 0), stats.closure_terms_left);
    try std.testing.expectEqual(@as(usize, tunnels), system.graph.connectivity.closure.limits.n_net);
    try expectWithinBounds(&system.graph.connectivity.closure, stats);
    try fixture.expectMatchesRebuild(&system);
}

test "a world build's closure equals one maintained level by level as levels and their one-way links arrive in play" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, 0, 5);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    for (1..3) |level_usize| {
        const level: u16 = @intCast(level_usize);
        _ = try fixture.world.addLevel(-16 * @as(i32, level));
        _ = try fixture.world.addDenseLayer(level, 0, .floor, fixture.grass);
        fixture.obstacle[level] = try fixture.world.addDenseLayer(level, 0, .obstacle, fixture.grass);
        for (0..test_chunk * chunks) |y| for (0..test_chunk * chunks) |x| {
            if (x % 2 == 1 or y % 2 == 1) try fixture.setCell(null, level, @intCast(x), @intCast(y), fixture.tree);
        };
        try addChain(&fixture, chunks, level, 3, 4);
        try addOneWay(&fixture, level - 1, latticeRoom(chunks, 4), level, latticeRoom(chunks, 3));
        try addOneWay(&fixture, level, latticeRoom(chunks, 6), level - 1, latticeRoom(chunks, 0));
        const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        try std.testing.expectEqual(@as(usize, 1), stats.levels_built);
        // Checks the world build's closure (`buildClosure`) against this one.
        try fixture.expectMatchesRebuild(&system);
    }
    try std.testing.expectEqual(@as(usize, 1), system.graph.connectivity.closure.hcompCount());
}

test "a one-way link between unbuilt levels commits without allocating, stays dead while one end's level is unbuilt, and goes live with the second" {
    var fixture = try TestWorld.init(6, 1);
    defer fixture.deinit();
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    for (1..3) |level| {
        _ = try fixture.world.addLevel(-16 * @as(i32, @intCast(level)));
        _ = try fixture.world.addDenseLayer(@intCast(level), 0, .floor, fixture.grass);
    }
    try addOneWay(&fixture, 1, .{ 2, 2 }, 2, .{ 9, 9 });
    var stats = NavUpdateStats{};
    const prepared = (try system.graph.prepareMarks(&fixture.world, no_colliders.view(), &.{}, null, &stats)).?;
    const original = system.graph.allocator;
    system.graph.allocator = std.testing.failing_allocator;
    const batch = system.graph.commitMarks(prepared, no_colliders.view(), null, &stats);
    system.graph.allocator = original;
    try std.testing.expect(!batch.changed);
    const closure = &system.graph.connectivity.closure;
    try std.testing.expectEqual(@as(usize, 1), closure.oneway.len);
    try std.testing.expectEqual(no_hcomp, closure.oneway.items(.hcomp)[0]);
    try system.graph.buildLevel(no_colliders.view(), &fixture.world, 1, null, &stats);
    try std.testing.expectEqual(no_hcomp, closure.oneway.items(.hcomp)[0]);
    try std.testing.expectEqual(@as(usize, 0), closure.termCount());
    try system.graph.buildLevel(no_colliders.view(), &fixture.world, 2, null, &stats);
    try std.testing.expect(closure.oneway.items(.hcomp)[0] != no_hcomp);
    try std.testing.expect(reach(&system.graph, 1, fixture.cell(2, 2), 2, fixture.cell(9, 9)) == .reaches);
    try std.testing.expect(reach(&system.graph, 2, fixture.cell(9, 9), 1, fixture.cell(2, 2)) != .reaches);
    try fixture.expectMatchesRebuild(&system);
}

test "the post-commit nav reaction runs the closure resolve and rows on workers and records the rows as nav_closure" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const chunks: u16 = 8;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, 16, 16);
    try addChain(&fixture, chunks, 0, 64, 16);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 4, .items_per_range = 1 });
    defer threads.deinit();
    var capacity = test_support.abstractCapacity();
    capacity.worker_participant_count = threads.participantSlotCount();
    var system = try fixture.build(capacity);
    defer system.deinit();
    system.nav_thread_adaptive = false;
    system.nav_thread_items_per_range = 1;
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try setRoom(&fixture, &system, chunks, 0, 31, fixture.tree);
    try setRoom(&fixture, &system, chunks, 0, 79, fixture.tree);
    frame.beginStep();
    const stats = try system.reactToPostCommitNavEvents(&frame, no_colliders, &fixture.world, &threads);
    try std.testing.expect(!stats.conn_closure_resolve_batch.ran_inline and stats.conn_closure_resolve_batch.worker_thread_ranges != 0);
    try std.testing.expect(!stats.conn_closure_rows_batch.ran_inline and stats.conn_closure_rows_batch.worker_thread_ranges != 0);
    if (runtime_perf_log.enabled) {
        var perf = runtime_perf_log.RuntimePerfLog.init(0);
        stats.recordTo(runtime_perf_log.Context.bind(&perf));
        const closure = perf.batches[@backingInt(runtime_perf_log.BatchStage.nav_closure)];
        try std.testing.expectEqual(@as(u64, 1), closure.calls);
        try std.testing.expectEqual(@as(u64, stats.conn_closure_rows_batch.item_count), closure.items);
    }
    try fixture.expectMatchesRebuild(&system);
}

test "a merge and a split of terminal roots far from every endpoint join and part their one-way systems" {
    var fixture = try TestWorld.init(8, 2);
    defer fixture.deinit();
    // Both levels halved by a solid chunk column; each level-0 half reaches the level-1 half
    // below it, so the halves form two one-way systems.
    for (0..2) |level| for (0..8) |cy| try fixture.setChunk(null, @intCast(level), 4, @intCast(cy), fixture.tree);
    try addOneWay(&fixture, 0, .{ 1, 1 }, 1, .{ 2, 2 });
    try addOneWay(&fixture, 0, .{ 30, 30 }, 1, .{ 29, 29 });
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    try std.testing.expectEqual(@as(usize, 2), system.graph.connectivity.closure.hcompCount());
    // A gap in level 0's wall, its patch keys far from every endpoint, merges the halves.
    try fixture.setChunk(&system, 0, 4, 4, fixture.grass);
    const merged = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), merged.conn_merges);
    try std.testing.expectEqual(@as(usize, 1), system.graph.connectivity.closure.hcompCount());
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), 1, fixture.cell(29, 29)) == .reaches);
    try fixture.expectMatchesRebuild(&system);
    // Refilled: the root splits and so does the system.
    try fixture.setChunk(&system, 0, 4, 4, fixture.tree);
    const split = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), split.conn_splits);
    try std.testing.expectEqual(@as(usize, 2), system.graph.connectivity.closure.hcompCount());
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), 1, fixture.cell(29, 29)) != .reaches);
    try fixture.expectMatchesRebuild(&system);
}

// A one-way chain over lattice rooms `rooms` of `level`, in order.
fn addRoomChain(fixture: *TestWorld, chunks: u16, level: u16, rooms: []const usize) !void {
    for (rooms[0 .. rooms.len - 1], rooms[1..]) |from, to| try addOneWay(fixture, level, latticeRoom(chunks, from), level, latticeRoom(chunks, to));
}

// Opens or closes the wall between lattice rooms `index` and `index + 1` of level 0.
fn setWall(fixture: *TestWorld, system: ?*PathfindingSystem, chunks: u16, index: usize, tile: TileId) !void {
    const wall = latticeWall(chunks, index);
    try fixture.setCell(system, 0, wall[0], wall[1], tile);
}

// The block capacity of the H-component of lattice room `index`'s terminal on level 0.
fn roomBlockCap(system: *const PathfindingSystem, fixture: *const TestWorld, chunks: u16, index: usize) u32 {
    const closure = &system.graph.connectivity.closure;
    return closure.hcomp.k_cap[roomHComp(system, fixture, chunks, index)];
}

test "a dig merging a terminal room into a larger terminal-less region keeps its terminal" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    // Rooms 2..7 of row 0 form one open region across chunks holding no endpoint; room 1
    // reaches room 20. Two terminals fill their block, and no free terminal id is left.
    for (2..7) |index| try setWall(&fixture, null, chunks, index, fixture.grass);
    try addOneWay(&fixture, 0, latticeRoom(chunks, 1), 0, latticeRoom(chunks, 20));
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    const term = roomTerm(&system, &fixture, chunks, 0, 1);
    try std.testing.expectEqual(@as(u32, 2), closure.hcomp.k_cap[closure.term.hcomp[term]]);
    try std.testing.expectEqual(@as(usize, 0), closure.term_free.items.len);
    try setWall(&fixture, &system, chunks, 1, fixture.grass);
    const stats = try applyWithinBounds(&fixture, &system);
    try std.testing.expectEqual(@as(usize, 0), stats.closure_terms_new);
    try std.testing.expectEqual(@as(usize, 0), stats.closure_terms_left);
    // Room 1's new node joined the region's root, which took the terminal its old root freed.
    try std.testing.expectEqual(term, roomTerm(&system, &fixture, chunks, 0, 1));
    try std.testing.expectEqual(term, roomTerm(&system, &fixture, chunks, 0, 6));
    try fixture.expectMatchesRebuild(&system);
}

test "a toggle in a chunk of terminal rooms creates and frees only the toggled room's terminal" {
    const chunks: u16 = 8;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    // Rooms 0..63, one full block of 64: the tail, room 63, shares its chunk with chain rooms
    // 46, 47, and 62, which every toggle re-creates.
    try addChain(&fixture, chunks, 0, 0, 64);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    try std.testing.expectEqual(@as(u32, 64), roomBlockCap(&system, &fixture, chunks, 63));
    var neighbours: [3]u32 = undefined;
    for ([_]usize{ 46, 47, 62 }, &neighbours) |room, *term| term.* = roomTerm(&system, &fixture, chunks, 0, room);
    for ([_]TileId{ fixture.tree, fixture.grass }, [_][2]usize{ .{ 0, 1 }, .{ 1, 0 } }) |tile, churn| {
        try setRoom(&fixture, &system, chunks, 0, 63, tile);
        const stats = try applyWithinBounds(&fixture, &system);
        try std.testing.expectEqual(churn[0], stats.closure_terms_new);
        try std.testing.expectEqual(churn[1], stats.closure_terms_left);
        for ([_]usize{ 46, 47, 62 }, neighbours) |room, term| try std.testing.expectEqual(term, roomTerm(&system, &fixture, chunks, 0, room));
        try std.testing.expectEqual(@as(usize, 0), stats.closure_shrinks);
        try fixture.expectMatchesRebuild(&system);
    }
}

test "a tail toggle at a full block bounds its slots by the block and its pops, its links by the chain and its dead link, and its widest block at half" {
    const chunks: u16 = 8;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, 0, 64);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const limits = &system.graph.connectivity.closure.limits;
    // Closed: 64 terminals and 63 links, nothing new.
    try setRoom(&fixture, &system, chunks, 0, 63, fixture.tree);
    _ = try applyWithinBounds(&fixture, &system);
    try std.testing.expectEqual(@as(usize, 64), limits.k_b);
    try std.testing.expectEqual(@as(usize, 63), limits.e_t);
    try std.testing.expectEqual(@as(usize, 0), limits.n_net);
    try std.testing.expectEqual(@as(usize, 32), limits.q_max);
    // Reopened: 63 terminals, 62 live links and the dead one counted once, two pops (the room
    // and its open partner), one net (the partner holds a terminal).
    try setRoom(&fixture, &system, chunks, 0, 63, fixture.grass);
    _ = try applyWithinBounds(&fixture, &system);
    try std.testing.expectEqual(@as(usize, 65), limits.k_b);
    try std.testing.expectEqual(@as(usize, 63), limits.e_t);
    try std.testing.expectEqual(@as(usize, 1), limits.loose);
    try std.testing.expectEqual(@as(usize, 2), limits.n_gross);
    try std.testing.expectEqual(@as(usize, 1), limits.n_net);
    try std.testing.expectEqual(@as(usize, 32), limits.q_max);
    try fixture.expectMatchesRebuild(&system);
}

test "a one-way chain cut to a few rooms, reopened, and toggled stays within the reachability and nav storage bounds" {
    const chunks: u16 = 8;
    const rooms: usize = 64;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, 0, rooms);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const graph = &system.graph;
    const links = rooms - 1;
    const stride = graph.levelGraph(0).?.border_stride;
    const chunk_cells = @as(usize, test_chunk) * test_chunk;
    const chunk_endpoints = @min(2 * links, chunk_cells);
    const shape = StorageShape{
        .nodes = graph.chunkCount() * stride + 2 * links,
        .level_chunks = graph.chunkCount(),
        .level_nodes = graph.chunkCount() * stride + 2 * links,
        .batch_keys = graph.chunkCount(),
        .batch_links = 0,
        .border_stride = stride,
        .chunk_endpoints = chunk_endpoints,
        .links = links,
        .oneway_links = links,
        .system_terminals = rooms,
        .participants = 1,
    };
    const graph_shape = NavGraph.StorageShape{
        .chunks = graph.chunkCount(),
        .levels = 1,
        .chunk_tiles = test_chunk,
        .links = links,
        .oneway_links = links,
        .oneway_system_terminals = rooms,
        .batch_mark_chunks = rooms,
        .batch_links = 0,
        .batch_keys = graph.chunkCount(),
    };
    const cut = rooms - 8;
    for ([_]TileId{ fixture.tree, fixture.grass }) |tile| {
        for (0..cut) |index| try setRoom(&fixture, &system, chunks, 0, index, tile);
        _ = try applyWithinBounds(&fixture, &system);
        try std.testing.expect(graph.connectivity.residentBytes() <= storageBytesBound(shape));
        try std.testing.expect(graph.residentBytes() <= NavGraph.storageBytesBound(graph_shape));
    }
    for (0..4) |_| {
        for ([_]TileId{ fixture.tree, fixture.grass }) |tile| {
            try setRoom(&fixture, &system, chunks, 0, rooms - 1, tile);
            _ = try applyWithinBounds(&fixture, &system);
            try std.testing.expect(graph.connectivity.residentBytes() <= storageBytesBound(shape));
        }
    }
    try fixture.expectMatchesRebuild(&system);
    // The closure is charged only for one-way links.
    var two_way = shape;
    two_way.oneway_links = 0;
    try std.testing.expect(storageBytesBound(two_way) < storageBytesBound(shape));
}

test "a fill splitting a one-chunk room holding two endpoint cells yields two terminals within the bound" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    // Rooms 0 and 1 share chunk 0 and one root through their open wall; it holds the source of
    // the link to the chain 2..8 and the target of the one from its end: 8 terminals, full.
    try setWall(&fixture, null, chunks, 0, fixture.grass);
    try addOneWay(&fixture, 0, latticeRoom(chunks, 0), 0, latticeRoom(chunks, 2));
    try addChain(&fixture, chunks, 0, 2, 7);
    try addOneWay(&fixture, 0, latticeRoom(chunks, 8), 0, latticeRoom(chunks, 1));
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    try std.testing.expectEqual(@as(u32, 8), roomBlockCap(&system, &fixture, chunks, 2));
    try setWall(&fixture, &system, chunks, 0, fixture.tree);
    const stats = try applyWithinBounds(&fixture, &system);
    try std.testing.expectEqual(@as(usize, 9), closure.termCount());
    try std.testing.expectEqual(@as(usize, 1), stats.closure_terms_new);
    try std.testing.expectEqual(@as(usize, 1), closure.limits.n_net);
    try std.testing.expectEqual(@as(u32, 16), roomBlockCap(&system, &fixture, chunks, 2));
    try fixture.expectMatchesRebuild(&system);
}

test "a fill splitting a room across a chunk border, both chunks changed, yields two terminals within the bound" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    // Rooms 1 (chunk 0), 2, and 3 (chunk 1) share one root through their open walls; it holds
    // the source of the link to the chain 4..10 and the target of the one from its end.
    for (1..3) |index| try setWall(&fixture, null, chunks, index, fixture.grass);
    try addOneWay(&fixture, 0, latticeRoom(chunks, 1), 0, latticeRoom(chunks, 4));
    try addChain(&fixture, chunks, 0, 4, 7);
    try addOneWay(&fixture, 0, latticeRoom(chunks, 10), 0, latticeRoom(chunks, 3));
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    try std.testing.expectEqual(@as(u32, 8), roomBlockCap(&system, &fixture, chunks, 4));
    // Both walls filled in one batch: each side's seed edge ends in the other changed chunk.
    for (1..3) |index| try setWall(&fixture, &system, chunks, index, fixture.tree);
    const stats = try applyWithinBounds(&fixture, &system);
    try std.testing.expectEqual(@as(usize, 9), closure.termCount());
    try std.testing.expectEqual(@as(usize, 1), stats.closure_terms_new);
    try std.testing.expectEqual(@as(u32, 16), roomBlockCap(&system, &fixture, chunks, 4));
    try fixture.expectMatchesRebuild(&system);
}

test "opening the closed end of a dead link adds two terminals when its far room holds none and one when it holds a terminal" {
    const chunks: u16 = 4;
    {
        var fixture = try latticeWorld(chunks, 1);
        defer fixture.deinit();
        // A full chain of 8 through chunk 0's rooms 1, 8, and 9; room 0 (closed) reaches room
        // 20, which holds no other endpoint.
        try addRoomChain(&fixture, chunks, 0, &.{ 1, 8, 9, 2, 3, 4, 5, 6 });
        try setRoom(&fixture, null, chunks, 0, 0, fixture.tree);
        try addOneWay(&fixture, 0, latticeRoom(chunks, 0), 0, latticeRoom(chunks, 20));
        var system = try fixture.build(test_support.abstractCapacity());
        defer system.deinit();
        const closure = &system.graph.connectivity.closure;
        try std.testing.expectEqual(@as(u32, 8), roomBlockCap(&system, &fixture, chunks, 1));
        try setRoom(&fixture, &system, chunks, 0, 0, fixture.grass);
        const stats = try applyWithinBounds(&fixture, &system);
        try std.testing.expectEqual(@as(usize, 2), closure.limits.n_net);
        try std.testing.expectEqual(@as(usize, 2), stats.closure_terms_new);
        try std.testing.expectEqual(@as(u32, 2), roomBlockCap(&system, &fixture, chunks, 0));
        try fixture.expectMatchesRebuild(&system);
    }
    {
        var fixture = try latticeWorld(chunks, 1);
        defer fixture.deinit();
        // A chain of 7 in a block of 8; room 16 (closed) reaches its head.
        try addChain(&fixture, chunks, 0, 1, 7);
        try setRoom(&fixture, null, chunks, 0, 16, fixture.tree);
        try addOneWay(&fixture, 0, latticeRoom(chunks, 16), 0, latticeRoom(chunks, 1));
        var system = try fixture.build(test_support.abstractCapacity());
        defer system.deinit();
        const closure = &system.graph.connectivity.closure;
        try std.testing.expectEqual(@as(u32, 8), roomBlockCap(&system, &fixture, chunks, 1));
        try setRoom(&fixture, &system, chunks, 0, 16, fixture.grass);
        const stats = try applyWithinBounds(&fixture, &system);
        try std.testing.expectEqual(@as(usize, 1), closure.limits.n_net);
        try std.testing.expectEqual(@as(usize, 4), closure.limits.q_max);
        try std.testing.expectEqual(@as(usize, 1), stats.closure_terms_new);
        try std.testing.expectEqual(@as(u32, 8), roomBlockCap(&system, &fixture, chunks, 16));
        try fixture.expectMatchesRebuild(&system);
    }
}

test "a dig merging rooms of two full one-way systems grows one block within the bound of their merged group" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    // Chains over rows 0 and 1 (rooms 0..7 and 8..15), each a full block of 8.
    try addChain(&fixture, chunks, 0, 0, 8);
    try addChain(&fixture, chunks, 0, 8, 8);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    try std.testing.expectEqual(@as(usize, 2), closure.hcompCount());
    // The cell between rooms 0 and 8 dug: their roots merge, and so do the systems.
    try fixture.setCell(&system, 0, 0, 1, fixture.grass);
    _ = try applyWithinBounds(&fixture, &system);
    try std.testing.expect(closure.limits.merge);
    try std.testing.expectEqual(@as(usize, 1), closure.hcompCount());
    try std.testing.expectEqual(@as(usize, 15), closure.termCount());
    try std.testing.expectEqual(@as(u32, 16), roomBlockCap(&system, &fixture, chunks, 15));
    try std.testing.expectEqual(@as(usize, 16), closure.limits.q_max);
    try fixture.expectMatchesRebuild(&system);
}

test "a fill in a chunk holding rooms of two one-way systems bounds each system alone" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    // Chains over rooms 1..8 (a full block of 8) and 9..24 (16); chunk 0 holds rooms 1, 8,
    // and 9 of them and room 0 of neither.
    try addChain(&fixture, chunks, 0, 1, 8);
    try addChain(&fixture, chunks, 0, 9, 16);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    try setRoom(&fixture, &system, chunks, 0, 0, fixture.tree);
    _ = try applyWithinBounds(&fixture, &system);
    try std.testing.expectEqual(@as(usize, 2), closure.limits.candidates);
    try std.testing.expect(!closure.limits.merge);
    try std.testing.expectEqual(@as(usize, 8), closure.limits.q_max);
    try fixture.expectMatchesRebuild(&system);
}

test "cutting a full chain of 128 to 28 bounds the batch by its terminals and links alone" {
    const chunks: u16 = 8;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, narrow_first, 128);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const stats = try narrowChain(&fixture, &system, fixture.tree);
    try expectWithinBounds(&system.graph.connectivity.closure, stats);
    const limits = system.graph.connectivity.closure.limits;
    try std.testing.expectEqual(@as(usize, 128), limits.k_b);
    try std.testing.expectEqual(@as(usize, 127), limits.e_t);
    try std.testing.expectEqual(@as(usize, 0), limits.n_gross);
    try std.testing.expectEqual(@as(usize, 64), limits.q_max);
    try fixture.expectMatchesRebuild(&system);
}

test "a dead link with both ends in a batch's keys is taken loose once" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    // Room 0 (closed) reaches room 1: both in chunk 0, the link dead.
    try setRoom(&fixture, null, chunks, 0, 0, fixture.tree);
    try addOneWay(&fixture, 0, latticeRoom(chunks, 0), 0, latticeRoom(chunks, 1));
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    try std.testing.expectEqual(@as(usize, 0), closure.termCount());
    // Room 8 of chunk 0 filled.
    try setRoom(&fixture, &system, chunks, 0, 8, fixture.tree);
    const stats = try applyWithinBounds(&fixture, &system);
    try std.testing.expectEqual(@as(usize, 1), closure.limits.loose);
    try std.testing.expectEqual(@as(usize, 1), closure.limits.e_t);
    try std.testing.expectEqual(@as(usize, 1), stats.closure_links);
    try fixture.expectMatchesRebuild(&system);
}

test "a world build of disjoint one-way links reserves one H-component id per link" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    for (0..5) |link| try addOneWay(&fixture, 0, latticeRoom(chunks, 2 * link), 0, latticeRoom(chunks, 2 * link + 1));
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    try std.testing.expectEqual(@as(usize, 5), closure.hcompCount());
    try std.testing.expectEqual(@as(usize, 5), closure.hcomps.len);
}
