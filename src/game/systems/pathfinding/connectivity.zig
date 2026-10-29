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
//! Every batch also maintains the one-way closure over the roots (`connectivity_closure.zig`).

const std = @import("std");
const connectivity_closure = @import("connectivity_closure.zig");
const Closure = @import("connectivity_closure.zig").Closure;
const ClosureCounters = @import("connectivity_closure.zig").ClosureCounters;
const ClosureThreads = @import("connectivity_closure.zig").ClosureThreads;
const OneWayEntry = @import("connectivity_closure.zig").OneWayEntry;
const WorldSystem = @import("../../world/system.zig").WorldSystem;
const LevelLink = @import("../../world/system.zig").LevelLink;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const BatchStats = @import("../../../app/thread_system.zig").BatchStats;
const Dispatch = @import("../../../app/thread_system.zig").Dispatch;
const RoundDispatch = @import("../../../app/thread_system.zig").RoundDispatch;
const runStage = @import("../../../app/thread_system.zig").runStage;
const thread_shared_record_alignment = @import("../../../app/thread_system.zig").thread_shared_record_alignment;
const NavGrid = @import("nav_grid.zig").NavGrid;
const NavGraph = @import("nav_graph.zig").NavGraph;
const NavLevelGraph = @import("nav_graph.zig").NavLevelGraph;
const BatchLevels = @import("nav_graph.zig").BatchLevels;
const PatchInfo = @import("nav_graph.zig").PatchInfo;
const chunkKey = @import("../chunk_list_map.zig").chunkKey;
const assertFieldsClassified = @import("../chunk_list_map.zig").assertFieldsClassified;
const keyLevel = @import("../chunk_list_map.zig").keyLevel;
const keyChunk = @import("../chunk_list_map.zig").keyChunk;
const LevelRuns = @import("nav_graph.zig").LevelRuns;
const sortedContains = @import("nav_graph.zig").sortedContains;
const LabelSet = @import("nav_graph.zig").LabelSet;
const maxChunkLabels = @import("nav_grid.zig").maxChunkLabels;
const ChunkGeometry = @import("../../world/terrain.zig").ChunkGeometry;
const types = @import("types.zig");
const NavUpdateStats = types.NavUpdateStats;
const runtime_perf_log = @import("../../../app/runtime_perf_log.zig");
const StageTimer = runtime_perf_log.StageTimer;

pub const no_node: u32 = std.math.maxInt(u32);
pub const no_comp: u32 = std.math.maxInt(u32);
pub const no_root: u32 = std.math.maxInt(u32);
const no_set: u32 = std.math.maxInt(u32);
const no_unit: u32 = std.math.maxInt(u32);
const no_group: u32 = std.math.maxInt(u32);
const no_family: u32 = std.math.maxInt(u32);
const no_element: u32 = std.math.maxInt(u32);
const no_round: u32 = std.math.maxInt(u32);
pub const no_key: u64 = std.math.maxInt(u64);
pub const no_term: u32 = std.math.maxInt(u32);
pub const no_oneway: u32 = std.math.maxInt(u32);

comptime {
    // Block and tail offsets and flood table sizes are proven against a 64-bit usize.
    std.debug.assert(@bitSizeOf(usize) == 64);
}

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
    return (chunkKey(level, chunk) << 8) | label;
}

fn oldKey(level: u16, chunk: u32, label: u8) u64 {
    return old_bit | nodeKey(level, chunk, label);
}

/// The level of node key `key`.
pub fn nodeKeyLevel(key: u64) u16 {
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
// whole queue), and (`perf`, only with `runtime_perf_log.enabled`) the nodes it expanded.
const FloodOut = struct {
    written: u32,
    expanded: u32,
    resume_key: u64,
    resume_row: u32,
    perf: Perf,

    const Perf = if (runtime_perf_log.enabled) struct { expansions: u32 } else struct {};
};

// A node a search reached that its set did not hold when the round was built; `foreign` when
// another set held it then, so the search did not expand through it.
const Proposal = struct {
    key: u64,
    row: u32,
    foreign: bool,
};

// One participant's search table: the node keys its current item proposed, open-addressed and
// cleared by a generation bump. Only its own participant writes it. Not a std set: it clears
// once per flood item, where std's clear costs the table's capacity. Not an `ElementMap`: a
// key set probed through slices by the worker's visitor, with no values or logical limit, on
// its own cache line.
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

    // Grows the table to `slots` (a power of two), counting one in `grows`. Never shrinks.
    fn reserve(self: *FloodScratch, allocator: std.mem.Allocator, slots: usize, grows: *u64) !void {
        if (self.keys.len >= slots) return;
        const keys = try allocator.alloc(u64, slots);
        errdefer allocator.free(keys);
        const stamps = try allocator.alloc(u32, slots);
        @memset(stamps, 0);
        self.deinit(allocator);
        self.* = .{ .keys = keys, .stamps = stamps };
        grows.* += 1;
    }
};

// Default proposal slots per flood round (W): rounds pack served sets' windows up to it.
// A round width, not a budget: every round of a batch completes in that batch.
pub const default_flood_window: usize = 16384;

// Default most nodes one flood item proposes (K): a work quantum that bounds each
// participant's search table.
pub const default_flood_budget_cap: u32 = 512;

// A key's first probe slot in a power-of-two table of `mask + 1` slots: a Fibonacci hash's
// high bits.
fn homeSlot(key: u64, mask: usize) usize {
    const hash: usize = @truncate((key *% 0x9E3779B97F4A7C15) >> 32);
    return hash & mask;
}

/// The most keys per slot an `ElementMapAt` table holds.
const SlotLoad = enum { half, three_quarters };

// Not std.HashMapUnmanaged: its clear costs the high-water capacity per batch, where the
// generation bump costs nothing.
/// Open-addressed u64 -> u32 map, cleared by a generation bump. Its slot count is a power of
/// two holding its logical limit at a load of at most `load` (`slotCount`), so linear probes
/// stay short and an insert always finds room. Const lookups are safe on workers while
/// nothing writes. Expected linear probes at full load: 1.5 per hit and 2.5 per miss at
/// `.half`, 2.5 and 8.5 at `.three_quarters`, which holds a third fewer slots on average.
fn ElementMapAt(comptime load: SlotLoad) type {
    return struct {
        keys: std.ArrayList(u64) = .empty,
        values: std.ArrayList(u32) = .empty,
        stamps: std.ArrayList(u32) = .empty,
        generation: u32 = 1,
        limit: usize = 0,
        used: usize = 0,

        const Self = @This();

        comptime {
            assertFieldsClassified(Self, &.{ "keys", "values", "stamps" }, &.{ "generation", "limit", "used" });
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.stamps.deinit(allocator);
            self.values.deinit(allocator);
            self.keys.deinit(allocator);
            self.* = .{};
        }

        /// The slots for `limit` keys: a power of two holding them at `load` or less. Lookups are
        /// exact and nothing iterates the slots, so the count never changes a result.
        pub fn slotCount(limit: usize) error{OutOfMemory}!usize {
            const least = switch (load) {
                .half => 2 *| limit,
                .three_quarters => limit +| limit / 3 +| 1,
            };
            // Overflowing usize needs over 2^62 live keys, so it fails as the allocator does.
            return std.math.ceilPowerOfTwo(usize, @max(least, 16)) catch error.OutOfMemory;
        }

        /// Grows the slots to hold `limit` keys, emptying the map when they grow; never shrinks.
        pub fn reserve(self: *Self, allocator: std.mem.Allocator, limit: usize) !void {
            var grows: u64 = 0;
            try self.reserveSlots(allocator, limit, &grows);
        }

        // Grows the slots to hold `limit` keys as batch staging at a main-thread prepare seam,
        // emptying the map when they grow and counting one in `grows`. A release
        // (`release`) frees them between batches.
        fn reserveStaging(self: *Self, allocator: std.mem.Allocator, limit: usize, grows: *u64) !void {
            try self.reserveSlots(allocator, limit, grows);
        }

        fn reserveSlots(self: *Self, allocator: std.mem.Allocator, limit: usize, grows: *u64) !void {
            const slots = try slotCount(limit);
            if (slots > self.keys.items.len) {
                try self.keys.ensureTotalCapacityPrecise(allocator, slots);
                try self.values.ensureTotalCapacityPrecise(allocator, slots);
                try self.stamps.ensureTotalCapacityPrecise(allocator, slots);
                self.keys.items.len = slots;
                self.values.items.len = slots;
                self.stamps.items.len = slots;
                @memset(self.stamps.items, 0);
                self.generation = 1;
                grows.* += 1;
            }
            // Assigned only after every reserve succeeded.
            self.limit = limit;
            std.debug.assert(self.stamps.items.len >= slots);
        }

        // Frees the slots down to what `keep` keys need when they hold more than twice that,
        // emptying the map. Never fails: a failed shrink keeps the larger buffers.
        fn release(self: *Self, allocator: std.mem.Allocator, keep: usize) void {
            const slots = slotCount(keep) catch return;
            if (!types.shouldShrinkCapacity(self.keys.items.len, slots)) return;
            self.keys.shrinkAndFree(allocator, slots);
            self.values.shrinkAndFree(allocator, slots);
            self.stamps.shrinkAndFree(allocator, slots);
            @memset(self.stamps.items, 0);
            self.generation = 1;
            self.limit = 0;
            self.used = 0;
        }

        pub fn clear(self: *Self) void {
            self.used = 0;
            self.generation +%= 1;
            if (self.generation == 0) {
                @memset(self.stamps.items, 0);
                self.generation = 1;
            }
        }

        fn slotOf(self: *const Self, key: u64) usize {
            const mask = self.keys.items.len - 1;
            var slot = homeSlot(key, mask);
            while (self.stamps.items[slot] == self.generation and self.keys.items[slot] != key) slot = (slot + 1) & mask;
            return slot;
        }

        pub fn get(self: *const Self, key: u64) ?u32 {
            const slot = self.slotOf(key);
            return if (self.stamps.items[slot] == self.generation) self.values.items[slot] else null;
        }

        pub fn put(self: *Self, key: u64, value: u32) void {
            const slot = self.slotOf(key);
            std.debug.assert(self.stamps.items[slot] != self.generation);
            self.claimSlot(slot, key);
            self.values.items[slot] = value;
        }

        /// `key`'s value slot from one probe: `found` when the key was present, else the key is
        /// inserted and the caller writes its value. Within the reserved limit.
        pub fn getOrPut(self: *Self, key: u64) GetOrPut {
            const slot = self.slotOf(key);
            const found = self.stamps.items[slot] == self.generation;
            if (!found) self.claimSlot(slot, key);
            return .{ .value = &self.values.items[slot], .found = found };
        }

        pub const GetOrPut = struct {
            value: *u32,
            found: bool,
        };

        fn claimSlot(self: *Self, slot: usize, key: u64) void {
            std.debug.assert(self.used < self.limit);
            self.used += 1;
            self.stamps.items[slot] = self.generation;
            self.keys.items[slot] = key;
        }
    };
}

/// A map for lookups on workers, kept to short probes.
pub const ElementMap = ElementMapAt(.half);
/// Connectivity's merge map: main-thread, one batch long, its limit an over-count of the
/// batch's elements, so it trades probe length for memory.
pub const MergeMap = ElementMapAt(.three_quarters);

/// Union-find over u32 index columns (std has none): find with full path compression.
pub fn findRoot(parents: []u32, index: u32) u32 {
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

/// Unites two classes by size, ties to the lower index; returns the representative.
pub fn uniteBySize(parents: []u32, sizes: []u32, a: u32, b: u32) u32 {
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

/// Grows the free id list `free` of the pool `rows` to at least `needed` ids, new rows set to
/// `empty` and pushed in descending order so pops hand out ascending ids. The pool grows to
/// exactly the larger of its need and twice its capacity (an empty pool to its need), counted
/// once in `pool_grows`; the free list covers the pool exactly, so a release never allocates.
/// Ids stay below `id_end`, the pool's sentinel: a need reaching it fails as `OutOfMemory`, like
/// the allocator. The caller refreshes its column views after the call, success or not (the
/// pool may have moved). On error the pool keeps its rows and ids.
pub fn growPool(
    comptime Row: type,
    allocator: std.mem.Allocator,
    rows: *std.MultiArrayList(Row),
    free: *std.ArrayList(u32),
    needed: usize,
    empty: Row,
    id_end: u32,
    pool_grows: *u64,
) error{OutOfMemory}!void {
    if (free.items.len >= needed) return;
    const added = needed - free.items.len;
    const total = rows.len + added;
    // Exhausting the ids needs `id_end` live rows of the pool, so it fails as the allocator does.
    if (total >= id_end) return error.OutOfMemory;
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

/// Counters of one batch's connectivity stages, for stats and benches. `round_items_min` and
/// `round_items_max` span the flood's rounds (both zero with no round); `step_items` is the
/// active sets the flood sized its rounds from (`RoundDispatch.begin`); `build_visits` counts
/// the active sets the main thread's round builds walked; `flood_off_main_ns` is the rounds'
/// dispatch time on workers. `perf` is kept only with `runtime_perf_log.enabled`.
pub const ConnectivityCounters = struct {
    families: usize = 0,
    closure: ClosureCounters = .{},
    perf: Perf = .{},

    pub const Perf = if (runtime_perf_log.enabled) struct {
        groups: usize = 0,
        rounds: usize = 0,
        build_visits: usize = 0,
        flood_nodes: usize = 0,
        splits: usize = 0,
        merges: usize = 0,
        round_items_min: usize = 0,
        round_items_max: usize = 0,
        step_items: usize = 0,
        flood_off_main_ns: u64 = 0,
    } else struct {};
};

/// The element columns of one merge, taken once with the staging at its limit.
pub const ElementColumns = struct {
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

    pub fn of(slice: std.MultiArrayList(ElementRow).Slice) ElementColumns {
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

/// A merge's root-group columns, taken once with the staging at its limit.
pub const GroupColumns = struct {
    root_start: []u32,
    root_count: []u32,
    set_start: []u32,
    set_count: []u32,

    pub fn of(slice: std.MultiArrayList(GroupRow).Slice) GroupColumns {
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

/// Element counts of the batch staging lists that a marks batch changing one chunk needs:
/// the floor no staging list frees below, so a run of small batches never reallocates. The
/// closure's per-key windows keep `patch_keys`; its other lists keep nothing.
pub const StagingSizes = struct {
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
};

// Need groups of the staging lists for their release window (`types.StagingWindow`): the
// lists of a group are sized from one need.
const StagingGroup = enum {
    changed_keys,
    patch_keys,
    items,
    seeds,
    rows,
    edges,
    elements,
    ow_entries,
    cand_entries,
    closure_terms,
    candidates,
    s_words,
    k_cap_sum,
    loose,
    links,
    slots,
    pieces,
    masks,
    copy_items,
    round_items,
    tail,
};

/// Per-world comps and roots, plus the batch staging the stages share and the flood's round
/// buffers. Comps and roots are pools with free lists whose capacity covers every pooled id,
/// so a release never allocates. Every staging bound is reserved on the main thread before
/// the batch's stages dispatch: a list grows, counted (`types.growList`), to each batch's or
/// build's need, a batch noting it in the release window (`staging_window`); `releaseWindow`,
/// on the window's last step or a level build's step, frees it down to what the window kept,
/// so staging follows recent batches, never its high-water. The round buffers are fixed per world once reserved.
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
    element_map: MergeMap = .{},
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
    /// Proposal slots per flood round (W) beyond one node's slack, read at each flood reserve.
    /// Changes round count, never the partition.
    flood_window: usize = default_flood_window,
    /// The most proposals one flood item writes before it stops expanding (K), read at each
    /// flood reserve. Changes round count, never the partition.
    flood_budget_cap: u32 = default_flood_budget_cap,
    // The most link endpoints any chunk holds, over the first `endpoint_links_seen` links.
    max_chunk_endpoints: usize = 0,
    endpoint_links_seen: usize = 0,
    // The staging's release window over marks batches.
    staging_window: types.StagingWindow(StagingGroup) = .{},
    // The most recent batch's flood (its rounds folded into one), seed, and gather stage
    // shapes, kept only with `runtime_perf_log.enabled`.
    perf: Perf = .{},

    pub const Perf = if (runtime_perf_log.enabled) struct {
        last_flood_batch: BatchStats = .{},
        last_seed_batch: BatchStats = .{},
        last_gather_batch: BatchStats = .{},
    } else struct {};

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

    /// At the end of a step that closes the release window or built a level: frees every
    /// staging list down to what it keeps (`StagingWindow.kept`: the most the window's batches
    /// needed, the most any batch changing at most one chunk needed, and one changed chunk's
    /// static bound) when it holds more (`types.releaseStaging`); a closing window starts the
    /// next. The round buffers stay. Never fails. O(staging lists) plus the bytes it frees.
    pub fn releaseWindow(self: *Connectivity, allocator: std.mem.Allocator, border_stride: usize) void {
        const floor = self.oneChunkStaging(border_stride);
        const window = &self.staging_window;
        // Window highs of the per-key and starts lists count their closing entry.
        const changed_keep = window.kept(.changed_keys, floor.changed_keys + 1);
        types.releaseStaging(&self.seed_starts, allocator, changed_keep);
        types.releaseStaging(&self.seed_counts, allocator, changed_keep);
        types.releaseStaging(&self.seed_edges, allocator, window.kept(.seeds, floor.seeds));
        const key_keep = window.kept(.patch_keys, floor.patch_keys + 1);
        types.releaseStaging(&self.patch_changed, allocator, key_keep);
        const item_keep = window.kept(.items, floor.items + 1);
        inline for (.{ &self.row_starts, &self.edge_starts, &self.row_counts, &self.edge_counts }) |list| {
            types.releaseStaging(list, allocator, item_keep);
        }
        types.releaseStaging(&self.gather_rows, allocator, window.kept(.rows, floor.rows));
        types.releaseStaging(&self.gather_edges, allocator, window.kept(.edges, floor.edges));
        const element_keep = window.kept(.elements, floor.elements);
        types.releaseStaging(&self.elements, allocator, element_keep);
        // Elements plus the roots of kept elements share the map.
        self.element_map.release(allocator, 2 * element_keep);
        types.releaseStaging(&self.units, allocator, element_keep);
        types.releaseStaging(&self.sets, allocator, element_keep);
        types.releaseStaging(&self.families, allocator, element_keep);
        types.releaseStaging(&self.groups, allocator, element_keep);
        inline for (.{ &self.unit_elements, &self.group_roots, &self.group_sets, &self.root_first, &self.round_sets }) |list| {
            types.releaseStaging(list, allocator, element_keep);
        }
        const closure = &self.closure;
        inline for (.{ &closure.cand_starts, &closure.cand_counts, &closure.cand_tallies, &closure.ow_starts, &closure.ow_counts }) |list| {
            types.releaseStaging(list, allocator, key_keep);
        }
        types.releaseStaging(&closure.ow_entries, allocator, window.kept(.ow_entries, 0));
        types.releaseStaging(&closure.cand_hcomps, allocator, window.kept(.cand_entries, 0));
        const terms_keep = window.kept(.closure_terms, 0);
        inline for (.{ &closure.freed_terms, &closure.leaving, &closure.freed_indices }) |list| {
            types.releaseStaging(list, allocator, terms_keep);
        }
        types.releaseStaging(&closure.touched, allocator, window.kept(.candidates, 0));
        // A shrink empties the S bitmap, which stays zero over its length.
        types.releaseStaging(&closure.s_words, allocator, window.kept(.s_words, 0));
        types.releaseStaging(&closure.s_list, allocator, window.kept(.k_cap_sum, 0));
        types.releaseStaging(&closure.loose, allocator, window.kept(.loose, 0));
        const links_keep = window.kept(.links, 0);
        inline for (.{ &closure.resolve_items, &closure.resolve_out, &closure.targets }) |list| {
            types.releaseStaging(list, allocator, links_keep);
        }
        const slots_keep = window.kept(.slots, 0);
        inline for (.{ &closure.slots, &closure.apos, &closure.round_starts }) |list| {
            types.releaseStaging(list, allocator, slots_keep);
        }
        const pieces_keep = window.kept(.pieces, 0);
        types.releaseStaging(&closure.pieces, allocator, pieces_keep);
        types.releaseStaging(&closure.plan_items, allocator, pieces_keep);
        types.releaseStaging(&closure.mask_items, allocator, window.kept(.masks, 0));
        types.releaseStaging(&closure.copy_items, allocator, window.kept(.copy_items, 0));
        types.releaseStaging(&closure.round_items, allocator, window.kept(.round_items, 0));
        // The tail holds a deferred landing's blocks until it lands.
        if (closure.residents.items.len == 0) {
            types.releaseStaging(&closure.tail, allocator, window.kept(.tail, 0));
            types.releaseStaging(&closure.residents, allocator, pieces_keep);
        }
        // The lists may have shrunk below the limits: the next reserve sets them.
        self.element_limit = 0;
        self.element_count = 0;
        self.element_map.limit = 0;
        closure.limits = .{};
        closure.tail_limit = 0;
        window.released();
    }

    /// Bytes of the comp and root pools and their free lists.
    fn poolBytes(self: *const Connectivity) usize {
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
    fn floodBytes(self: *const Connectivity) usize {
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

    /// The staging a marks batch changing one chunk needs: the changed key and its four
    /// neighbours as patch keys plus one new link, each key up to `border_stride` portals and
    /// the largest chunk's endpoints. A level build keeps at least this much, which the next
    /// dig reserves anyway.
    pub fn oneChunkStaging(self: *const Connectivity, border_stride: usize) StagingSizes {
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

    /// Re-takes the comp and root column views after a pool grows.
    pub fn refreshColumns(self: *Connectivity) void {
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
    // below their sentinels. Exhausting either needs 2^32 - 1 live rows of it: OutOfMemory.
    fn ensureFreeIds(self: *Connectivity, allocator: std.mem.Allocator, needed: usize, pool_grows: *u64) !void {
        // The pools may move before a later step fails: the views follow them either way.
        defer self.refreshColumns();
        try growPool(CompRow, allocator, &self.comps, &self.comp_free, needed, .{ .root = no_root, .size = 0, .prev = no_comp, .next = no_comp, .set = no_set }, no_comp, pool_grows);
        try growPool(RootRow, allocator, &self.roots, &self.root_free, needed, .{ .head = no_comp, .members = 0, .term = no_term }, no_root, pool_grows);
    }

    // Reserves the merge staging for `limit` elements (element rows and the map, units,
    // sets, families, groups, and their lists) and `fresh` free comps and roots: fresh ids go
    // one pair per set or rootless unit, at most one per unit.
    fn reserveMerge(self: *Connectivity, allocator: std.mem.Allocator, limit: usize, fresh: usize, pool_grows: *u64) !void {
        // Reaching `no_unit` needs 2^32 - 1 merge elements in one batch, so it fails as the
        // allocator does.
        if (limit >= no_unit) return error.OutOfMemory;
        self.staging_window.note(.elements, limit);
        try types.growList(&self.elements, allocator, limit, pool_grows);
        // Elements plus the roots of kept elements share the map.
        try self.element_map.reserveStaging(allocator, 2 * limit, pool_grows);
        try types.growList(&self.units, allocator, limit, pool_grows);
        try types.growList(&self.sets, allocator, limit, pool_grows);
        try types.growList(&self.families, allocator, limit, pool_grows);
        try types.growList(&self.groups, allocator, limit, pool_grows);
        inline for (.{ &self.unit_elements, &self.group_roots, &self.group_sets, &self.root_first, &self.round_sets }) |list| {
            try types.growList(list, allocator, limit, pool_grows);
        }
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
        const geometry = ChunkGeometry.init(world_system.width, world_system.height, world_system.chunk_size_tiles);
        for (links[self.endpoint_links_seen..]) |link| {
            inline for (.{ .{ link.level_a, link.cell_a }, .{ link.level_b, link.cell_b } }) |end| {
                const chunk = geometry.chunkOf(end[1].x, end[1].y);
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
    // the participant count; each growth counts one in `pool_grows`.
    fn reserveFlood(self: *Connectivity, allocator: std.mem.Allocator, border_stride: usize, participants: usize, pool_grows: *u64) !void {
        const slack = border_stride + self.max_chunk_endpoints;
        const budget: u32 = @intCast(@max(@min(@as(usize, self.flood_budget_cap), self.flood_window), 1));
        const window = @max(self.flood_window, budget) + slack;
        const items = window / (1 + slack);
        // The budget is a u32 and the slack 32 border flags plus a chunk's endpoints (two per
        // world link, below 2^32), so the table is under 2^35 slots: no usize overflow.
        const slots = std.math.ceilPowerOfTwoAssert(usize, 2 * (@as(usize, budget) + slack));
        try types.growList(&self.flood_items, allocator, items, pool_grows);
        try types.growList(&self.flood_outs, allocator, items, pool_grows);
        try types.growList(&self.proposals, allocator, window, pool_grows);
        try types.growList(&self.flood_scratch, allocator, participants, pool_grows);
        while (self.flood_scratch.items.len < participants) self.flood_scratch.appendAssumeCapacity(.{});
        for (self.flood_scratch.items) |*scratch| try scratch.reserve(allocator, slots, pool_grows);
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
        threads: ?Dispatch,
        closure_threads: ClosureThreads,
        pool_grows: *u64,
        stats: *NavUpdateStats,
    ) error{OutOfMemory}!void {
        std.debug.assert(patch_info.len == patch_keys.len and patch_keys.len != 0);
        var section = StageTimer.begin();
        const new_link_count = new_links.len;
        // The batch notes its needs in the release window (`NavGraph.finishStagingStep`).
        const window = &self.staging_window;
        window.beginBatch();
        // Flags and seed windows: changed keys are a sorted subset of the sorted patch keys.
        window.note(.patch_keys, patch_keys.len + 1);
        try types.resizeStaging(&self.patch_changed, allocator, patch_keys.len, pool_grows);
        window.note(.changed_keys, changed_keys.len + 1);
        try types.resizeStaging(&self.seed_starts, allocator, changed_keys.len + 1, pool_grows);
        try types.resizeStaging(&self.seed_counts, allocator, changed_keys.len, pool_grows);
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
        window.note(.seeds, seed_total);
        try types.resizeStaging(&self.seed_edges, allocator, seed_total, pool_grows);

        // Gather windows: per patch key its old nodes and new labels as rows and one edge per
        // border flag and link endpoint; per new link one edge.
        const item_count = patch_keys.len + new_link_count;
        window.note(.items, item_count + 1);
        try types.resizeStaging(&self.row_starts, allocator, item_count + 1, pool_grows);
        try types.resizeStaging(&self.edge_starts, allocator, item_count + 1, pool_grows);
        try types.resizeStaging(&self.row_counts, allocator, item_count, pool_grows);
        try types.resizeStaging(&self.edge_counts, allocator, item_count, pool_grows);
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
        window.note(.rows, row_total);
        try types.resizeStaging(&self.gather_rows, allocator, row_total, pool_grows);
        window.note(.edges, edge_total);
        try types.resizeStaging(&self.gather_edges, allocator, edge_total, pool_grows);

        // Node rows: each patch key gains at most one per portal-bearing label, so at most
        // its node bound and at most its chunk's label bound, per level.
        var runs = LevelRuns{ .keys = patch_keys };
        while (runs.next()) |run| {
            const level_graph = levels.graph(run.level);
            const label_bound = maxChunkLabels(levels.grid(run.level).geometry.chunk_tiles);
            var needed: usize = 0;
            for (patch_info[run.start..run.end]) |info| needed += @min(level_graph.border_stride + info.endpoints, label_bound);
            try level_graph.ensureFreeNodes(allocator, needed, pool_grows);
        }
        // Each row is one element; a gathered edge adds at most its far end (its near end is an
        // added row, a new link's ends are patch keys' rows) and a seed edge at most both.
        const limit = row_total + edge_total + 2 * seed_total;
        try self.reserveMerge(allocator, limit, limit, pool_grows);
        // Only a removal can flood; its sets come from the seeds.
        if (seed_total != 0) {
            self.noteLinks(world);
            try self.reserveFlood(allocator, levels.graph(keyLevel(changed_keys[0])).border_stride, participantCount(threads), pool_grows);
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
        stats.addMain(.reserve_ns, section.lap());
        const seed_batch = runStage(threads, changed_keys.len, 1, &job, &job.range_count, seedJob);
        if (comptime runtime_perf_log.enabled) self.perf.last_seed_batch = seed_batch;
        stats.addStageTime(seed_batch);

        // The closure reads the seed windows' counts and the graph before the change.
        section = StageTimer.begin();
        const new_oneway = connectivity_closure.countOneWay(new_links);
        self.closure.active = self.closure.oneway.len != 0 or new_oneway != 0;
        stats.addMain(.reserve_ns, section.lap());
        if (self.closure.active) _ = try connectivity_closure.prepareClosure(self, allocator, levels, world, patch_keys, true, self.patch_changed.items, new_oneway, new_link_count, closure_threads, pool_grows, stats);
        window.endBatch(changed_keys.len <= 1);
    }

    /// The infallible half, after the patch re-derived every patch key's record: gathers the
    /// patch keys and new links (threaded), merges rows, unions, and groups in key order on
    /// the main thread (O(1) per row, edge, and element; union-find amortized O(α)), settles
    /// every unit no removal can split, floods the rest in rounds (searches threaded, claims
    /// merged on main in item order), and unites each root-group. Allocation-free after
    /// `prepareMarks`; `allocator` (the prepare's) only frees the closure blocks the batch
    /// retires or relocates.
    pub fn commitMarks(
        self: *Connectivity,
        allocator: std.mem.Allocator,
        levels: BatchLevels,
        world: ?*const WorldSystem,
        patch_keys: []const u64,
        new_links: []const LevelLink,
        gather_threads: ?Dispatch,
        flood_threads: ?Dispatch,
        closure_threads: ClosureThreads,
        stats: *NavUpdateStats,
    ) ConnectivityCounters {
        var gather = self.gatherJobFor(levels, world, patch_keys, new_links);
        const gather_batch = runStage(gather_threads, patch_keys.len + new_links.len, 1, &gather, &gather.range_count, gatherJob);
        if (comptime runtime_perf_log.enabled) self.perf.last_gather_batch = gather_batch;
        stats.addStageTime(gather_batch);
        const merge_timer = StageTimer.begin();
        self.mergeBatch(levels, patch_keys, true, patch_keys.len + new_links.len, null);
        stats.addMain(.conn_merge_ns, merge_timer.lap());
        var counters = self.settleAndFlood(levels, world, flood_threads, stats);
        if (self.closure.active) counters.closure = connectivity_closure.updateClosure(self, allocator, levels, world, patch_keys.len, closure_threads, stats);
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
    /// gathers, merges, settles, floods, and unites as a marks batch does. Its staging grows
    /// to the level, so a world build's levels reuse it; its needs stay out of the release
    /// window (the caller's `beginBuild`), and the build's step frees it.
    /// O(level chunks + nodes + edges), the seed, gather, and flood stages threaded.
    pub fn buildLevel(
        self: *Connectivity,
        allocator: std.mem.Allocator,
        levels: BatchLevels,
        old_levels: BatchLevels,
        world: ?*const WorldSystem,
        keys: []const u64,
        replaced: ?*NavLevelGraph,
        seed_threads: ?Dispatch,
        gather_threads: ?Dispatch,
        flood_threads: ?Dispatch,
        closure_threads: ClosureThreads,
        pool_grows: *u64,
        stats: *NavUpdateStats,
    ) error{OutOfMemory}!ConnectivityCounters {
        const fresh = levels.fresh.?;
        const level_graph = fresh.graph;
        const seeding = replaced != null;
        var section = StageTimer.begin();
        // A build's needs stay out of the window (`beginBuild`); its notes are no-ops.
        const window = &self.staging_window;
        window.note(.items, keys.len + 1);
        try types.resizeStaging(&self.row_starts, allocator, keys.len + 1, pool_grows);
        try types.resizeStaging(&self.edge_starts, allocator, keys.len + 1, pool_grows);
        try types.resizeStaging(&self.row_counts, allocator, keys.len, pool_grows);
        try types.resizeStaging(&self.edge_counts, allocator, keys.len, pool_grows);
        const seed_keys: usize = if (seeding) keys.len else 0;
        window.note(.changed_keys, seed_keys + 1);
        try types.resizeStaging(&self.seed_starts, allocator, seed_keys + 1, pool_grows);
        try types.resizeStaging(&self.seed_counts, allocator, seed_keys, pool_grows);
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
        window.note(.rows, labels);
        try types.resizeStaging(&self.gather_rows, allocator, labels, pool_grows);
        window.note(.edges, edge_total);
        try types.resizeStaging(&self.gather_edges, allocator, edge_total, pool_grows);
        window.note(.seeds, seed_total);
        try types.resizeStaging(&self.seed_edges, allocator, seed_total, pool_grows);
        // No fresh row is old, so no key reads as remasked.
        window.note(.patch_keys, keys.len + 1);
        try types.resizeStaging(&self.patch_changed, allocator, keys.len, pool_grows);
        @memset(self.patch_changed.items, false);
        // An empty pool grows to exactly the level's labels.
        try level_graph.ensureFreeNodes(allocator, labels, pool_grows);
        // A mirror's far end is an added row of the level; only a link's far end, a seed's far
        // end, and the one old element standing for a replaced level add elements. Fresh ids go
        // one pair per set or rootless unit: at most the added rows plus the seeds' far ends.
        try self.reserveMerge(allocator, labels + endpoint_total + seed_total + 1, labels + seed_total + 1, pool_grows);
        if (seed_total != 0) {
            self.noteLinks(world);
            try self.reserveFlood(allocator, level_graph.border_stride, participantCount(flood_threads), pool_grows);
        }
        stats.addMain(.reserve_ns, section.lap());

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
            const seed_batch = runStage(seed_threads, keys.len, 1, &seed, &seed.range_count, seedJob);
            if (comptime runtime_perf_log.enabled) self.perf.last_seed_batch = seed_batch;
            stats.addStageTime(seed_batch);
        } else {
            if (comptime runtime_perf_log.enabled) self.perf.last_seed_batch = .{};
        }
        // The closure's reserves, before any connectivity changes: the candidates read the
        // replaced level's old nodes and every key's link partners on the other levels.
        self.closure.active = self.closure.oneway.len != 0;
        if (self.closure.active) _ = try connectivity_closure.prepareClosure(self, allocator, old_levels, world, keys, seeding, null, 0, 0, closure_threads, pool_grows, stats);
        var gather = self.gatherJobFor(levels, world, keys, &.{});
        const gather_batch = runStage(gather_threads, keys.len, 1, &gather, &gather.range_count, gatherJob);
        if (comptime runtime_perf_log.enabled) self.perf.last_gather_batch = gather_batch;
        stats.addStageTime(gather_batch);
        section = StageTimer.begin();
        self.mergeBatch(levels, keys, false, keys.len, replaced);
        stats.addMain(.conn_merge_ns, section.lap());
        var counters = self.settleAndFlood(levels, world, flood_threads, stats);
        if (self.closure.active) counters.closure = connectivity_closure.updateClosure(self, allocator, levels, world, keys.len, closure_threads, stats);
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

    fn settleAndFlood(self: *Connectivity, levels: BatchLevels, world: ?*const WorldSystem, threads: ?Dispatch, stats: *NavUpdateStats) ConnectivityCounters {
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
        if (comptime runtime_perf_log.enabled) self.perf.last_flood_batch = .{};
        stats.addMain(.conn_layout_ns, section.lap());
        if (counters.families != 0) self.runFlood(views, threads, &counters, stats);
        section = StageTimer.begin();
        self.finish(views, &counters);
        stats.addMain(.conn_layout_ns, section.lap());
        return counters;
    }

    // Unites units sharing an old root or a removal cluster into root-groups; a cluster
    // spanning two units marks both as sets and joins their families. Numbers units, groups,
    // sets, and families on first sight in element order, and lays out each unit's elements,
    // each group's old roots and sets, and every set's and rootless unit's fresh comp and root.
    // SIMD verdict: scalar. Union-find finds and first-sight numbering per element on the
    // main thread (data-dependent chains), O(α) each.
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
        if (comptime runtime_perf_log.enabled) counters.perf.groups = group_total;
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
    fn runFlood(self: *Connectivity, views: BatchViews, threads: ?Dispatch, counters: *ConnectivityCounters, stats: *NavUpdateStats) void {
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
                            if (comptime runtime_perf_log.enabled) counters.perf.build_visits += 1;
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
                            if (comptime runtime_perf_log.enabled) counters.perf.build_visits += 1;
                            if (sets.claimed[pending] < target) window_need += @min(target - sets.claimed[pending], budget_limit) + slack;
                            if (window_total + window_need > self.flood_window_limit) break :build;
                        }
                    }
                    families.served[family] = round;
                    const items_before = self.flood_items.items.len;
                    var set = families.pass_next[family];
                    while (set != no_set) : (set = sets.next_active[set]) {
                        if (comptime runtime_perf_log.enabled) counters.perf.build_visits += 1;
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
            stats.addMain(.flood_ns, section.lap());
            dispatch.run(item_count, &job, &job.range_count, floodJob);
            section = StageTimer.begin();

            // Merge, in item order.
            for (self.flood_items.items, self.flood_outs.items) |item, out| {
                if (comptime runtime_perf_log.enabled) counters.perf.flood_nodes += out.perf.expansions;
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
                if (comptime runtime_perf_log.enabled) counters.perf.splits += 1;
            }
        }
        const flood_batch = dispatch.finish(self.sets.len);
        if (comptime runtime_perf_log.enabled) {
            self.perf.last_flood_batch = flood_batch;
            counters.perf.rounds = round;
            counters.perf.round_items_min = dispatch.round_items_min;
            counters.perf.round_items_max = dispatch.round_items_max;
            counters.perf.step_items = self.sets.len;
            counters.perf.flood_off_main_ns = dispatch.off_main_ns;
            stats.perf.off_main_stage_ns += dispatch.off_main_ns;
            stats.perf.inline_stage_ns += dispatch.inline_ns;
        }
        stats.addMain(.flood_ns, section.lap());
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
                    if (comptime runtime_perf_log.enabled) counters.perf.merges += 1;
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
    // One-way closure (`connectivity_closure.zig`)
    // ------------------------------------------------------------------------------------

    pub const reserveRegistry = connectivity_closure.reserveRegistry;
    pub const appendRegistry = connectivity_closure.appendRegistry;
    pub const buildClosure = connectivity_closure.buildClosure;
    pub const landResidents = connectivity_closure.landResidents;

    // The gather stage over `keys` then `links` on the prepared windows, with the registry and
    // the one-way windows when the closure is active.
    fn gatherJobFor(self: *Connectivity, levels: BatchLevels, world: ?*const WorldSystem, keys: []const u64, links: []const LevelLink) GatherJob {
        var job = GatherJob{
            .levels = levels,
            .world = world,
            .keys = keys,
            .changed = self.patch_changed.items,
            .links = links,
            .row_starts = self.row_starts.items,
            .row_counts = self.row_counts.items,
            .rows = self.gather_rows.items,
            .edge_starts = self.edge_starts.items,
            .edge_counts = self.edge_counts.items,
            .edges = self.gather_edges.items,
        };
        const closure = &self.closure;
        if (!closure.active) return job;
        std.debug.assert(closure.ow_counts.items.len == keys.len);
        job.oneway_of_link = closure.oneway_of_link.items;
        job.oneway_cursor = closure.oneway_cursor;
        job.ow_starts = closure.ow_starts.items;
        job.ow_counts = closure.ow_counts.items;
        job.ow_entries = closure.ow_entries.items;
        return job;
    }
};

// ----------------------------------------------------------------------------------------
// Edges
// ----------------------------------------------------------------------------------------

/// A node an edge reaches: its key, and its level, chunk, and label.
pub const Neighbour = struct {
    key: u64,
    level: u16,
    chunk: u32,
    label: u8,
};

// The node of open cell (x, y) of `level`: its chunk and label from shifts.
fn neighbourAt(grid: *const NavGrid, level: u16, x: usize, y: usize) Neighbour {
    const chunk = grid.geometry.chunkOf(x, y);
    const label = grid.labelAtLocal(chunk, grid.geometry.localOf(x, y));
    std.debug.assert(label != 0);
    return .{ .key = nodeKey(level, chunk, label), .level = level, .chunk = chunk, .label = label };
}

/// The node at cell (`x`, `y`) of `level` when the cell is open on a built level and is a
/// portal of its chunk's record, else null.
pub fn portalNode(levels: BatchLevels, level: u16, x: u16, y: u16) ?Neighbour {
    if (!levels.built(level)) return null;
    const grid = levels.grid(level);
    if (grid.isBlockedXY(x, y)) return null;
    const neighbour = neighbourAt(grid, level, x, y);
    if (levels.graph(level).chunkPortals(neighbour.chunk).find(grid.geometry.localOf(x, y)) == null) return null;
    return neighbour;
}

const EdgeKinds = enum { mirrors, mirrors_and_links };

/// Calls `visitor.visit(label, neighbour)` for each edge leaving a node of `chunk`'s record on
/// `level` (only `only_label`'s when set): one per border flag (the mirror cell across that
/// side) in portal order, then, with links, one per two-way link endpoint in the chunk (from
/// the world's endpoint list, both sides of every link) whose two ends are open portals on
/// built levels, in list order. One-way links and a link back to the same node yield none.
/// O(portals of the record + link endpoints in the chunk).
pub fn forEachEdge(levels: BatchLevels, world: ?*const WorldSystem, level: u16, chunk: u32, only_label: ?u8, kinds: EdgeKinds, visitor: anytype) void {
    const grid = levels.grid(level);
    const portals = levels.graph(level).chunkPortals(chunk);
    const bounds = grid.chunkBounds(chunk);
    const mask: usize = grid.geometry.chunk_tiles - 1;
    for (portals.border) |portal| {
        if (only_label) |wanted| {
            if (portal.label != wanted) continue;
        }
        const x = bounds.x0 + (portal.local & mask);
        const y = bounds.y0 + (@as(usize, portal.local) >> grid.geometry.shift);
        // A flag means the mirror cell exists in-grid.
        if (portal.flags.west) visitor.visit(portal.label, neighbourAt(grid, level, x - 1, y));
        if (portal.flags.east) visitor.visit(portal.label, neighbourAt(grid, level, x + 1, y));
        if (portal.flags.north) visitor.visit(portal.label, neighbourAt(grid, level, x, y - 1));
        if (portal.flags.south) visitor.visit(portal.label, neighbourAt(grid, level, x, y + 1));
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
        return sortedContains(self.changed_keys, chunkKey(level, chunk));
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
                if (grid.isBlockedXY(endpoint.cell.x, endpoint.cell.y)) continue;
                const neighbour = portalNode(job.levels, endpoint.other_level, endpoint.other_cell.x, endpoint.other_cell.y) orelse continue;
                const end = job.far(neighbour);
                const near_key = if (job.replaced) oldKey(level, 0, 0) else oldKey(level, chunk, grid.labelAtLocal(chunk, grid.geometry.localOf(endpoint.cell.x, endpoint.cell.y)));
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

const GatherEdges = struct {
    levels: BatchLevels,
    level: u16,
    chunk: u32,
    added: *const LabelSet,
    window: []EdgeEntry,
    written: usize = 0,

    fn visit(self: *GatherEdges, label: u8, neighbour: Neighbour) void {
        if (!self.added.isSet(label)) return;
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
        var labels: LabelSet = .empty;
        const portals = level_graph.chunkPortals(chunk);
        for (portals.border) |portal| labels.set(portal.label);
        for (portals.extra) |portal| labels.set(portal.label);
        var added = labels;
        var row = level_graph.record_node_head[record];
        while (row != no_node) : (row = level_graph.node_sibling[row]) {
            const label = level_graph.node_label[row];
            const keep = !job.changed[item] and labels.isSet(label);
            if (keep) added.unset(label);
            row_window[row_count] = .{ .row = row, .label = label, .kind = if (keep) .kept else .removed };
            row_count += 1;
        }
        var added_labels = added.iterator(.{});
        while (added_labels.next()) |label| {
            row_window[row_count] = .{ .row = no_node, .label = @intCast(label), .kind = .added };
            row_count += 1;
        }
        job.row_counts[item] = @intCast(row_count);
        // A chunk that only lost or kept labels has no new edge: its neighbours' new edges
        // come from their added side.
        if (added.findFirstSet() == null) {
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
fn participantCount(threads: ?Dispatch) usize {
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
        var slot = homeSlot(neighbour.key, mask);
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
            if (comptime runtime_perf_log.enabled) expansions += 1;
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
                if (comptime runtime_perf_log.enabled) expansions += 1;
            }
        }
        out.* = .{
            .written = @intCast(visitor.written),
            .expanded = @intCast(expanded),
            .resume_key = key,
            .resume_row = row,
            .perf = if (comptime runtime_perf_log.enabled) .{ .expansions = expansions } else .{},
        };
    }
}

// ----------------------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------------------

const test_support = @import("test_support.zig");

/// Live roots of a `Connectivity`: one per connected set of nodes.
fn connectivityRootCount(connectivity: anytype) usize {
    return connectivity.roots.len - connectivity.root_free.items.len;
}

/// Live comps of a `Connectivity`.
fn connectivityCompCount(connectivity: anytype) usize {
    return connectivity.comps.len - connectivity.comp_free.items.len;
}
const PathfindingSystem = @import("system.zig").PathfindingSystem;
const TileId = @import("../../world/system.zig").TileId;
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const SimulationFrame = @import("../../simulation.zig").SimulationFrame;
const no_colliders = &test_support.no_colliders;
const boundCap = @import("connectivity_closure.zig").boundCap;
const TestWorld = test_support.TestWorld;
const exhausted_pool_window = test_support.exhausted_pool_window;
const expectExhaustedPoolBatch = test_support.expectExhaustedPoolBatch;
const expectGraphStagingWithin = test_support.expectGraphStagingWithin;
const expectSameColumns = test_support.expectSameColumns;
const expectStagingWithin = test_support.expectStagingWithin;
const forcedNavThreads = test_support.forcedNavThreads;
const hubTunnels = test_support.hubTunnels;
const markAll = test_support.markAll;
const setHubCorridor = test_support.setHubCorridor;
const test_chunk = test_support.test_chunk;
const toggleRooms = test_support.toggleRooms;
const twoRooms = test_support.twoRooms;
const windowCapacity = test_support.windowCapacity;

// A walled room of `edge` x `edge` chunks in the level's corner whose only opening is the gap
// chunk (edge, edge / 2) of its wall band.
fn buildRoom(fixture: *TestWorld, edge: u16) !void {
    for (0..edge + 1) |cy| {
        if (cy == edge / 2) continue;
        try fixture.setChunk(null, 0, edge, @intCast(cy), fixture.tree);
    }
    for (0..edge) |cx| try fixture.setChunk(null, 0, @intCast(cx), edge, fixture.tree);
}

test "enclosing a room splits off exactly the room, and reopening merges it back without a flood" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    for ([_]u16{ 1, 2, 4 }) |edge| {
        for ([_]u16{ 16, 32 }) |side| {
            var fixture = try TestWorld.init(side, 1);
            defer fixture.deinit();
            try buildRoom(&fixture, edge);
            var system = try fixture.build(test_support.abstractCapacity());
            defer system.deinit();
            const inside = fixture.cell(1, 1);
            const outside = fixture.cell(@as(usize, side) * test_chunk - 2, @as(usize, side) * test_chunk - 2);
            try std.testing.expect(reach(&system.graph, 0, inside, 0, outside) == .reaches);
            const roots = connectivityRootCount(&system.graph.connectivity);

            try fixture.setChunk(&system, 0, edge, edge / 2, fixture.tree);
            _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
            // A one-chunk room loses its only portal: no node is left to split off.
            const split: usize = if (edge > 1) 1 else 0;
            try std.testing.expect(reach(&system.graph, 0, inside, 0, outside) != .reaches);
            try std.testing.expectEqual(roots + split, connectivityRootCount(&system.graph.connectivity));
            try fixture.expectMatchesRebuild(&system);

            try fixture.setChunk(&system, 0, edge, edge / 2, fixture.grass);
            _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
            try std.testing.expect(reach(&system.graph, 0, inside, 0, outside) == .reaches);
            try std.testing.expectEqual(roots, connectivityRootCount(&system.graph.connectivity));
            try fixture.expectMatchesRebuild(&system);
        }
    }
}

test "cutting a ring floods and splits nothing" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
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
        const roots = connectivityRootCount(&system.graph.connectivity);
        try fixture.setChunk(&system, 0, 0, span / 2, fixture.tree);
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
        try std.testing.expectEqual(roots, connectivityRootCount(&system.graph.connectivity));
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
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
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
    const roots = connectivityRootCount(&system.graph.connectivity);
    try fixture.setChunk(&system, 0, 2, 3, fixture.grass);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try std.testing.expectEqual(roots - 1, connectivityRootCount(&system.graph.connectivity));
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), 0, fixture.cell(20, 20)) == .reaches);
    try snapshotComps(&system.graph, &.{gap_chunk}, &after);
    try std.testing.expectEqual(before.count(), after.count());
    var entries = before.iterator();
    while (entries.next()) |entry| try std.testing.expectEqual(entry.value_ptr.*, after.get(entry.key_ptr.*).?);
    try fixture.expectMatchesRebuild(&system);
}

test "a dense change across four levels, its reopening, and an explosion opening match a full rebuild" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
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
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
        try fixture.expectMatchesRebuild(&system);
    }
    // An explosion clears the filled region and the wall band in one step.
    for (0..4) |level| {
        for (0..24) |y| for (6..20) |x| try fixture.setCell(&system, @intCast(level), @intCast(x), @intCast(y), fixture.grass);
    }
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try fixture.expectMatchesRebuild(&system);
}

test "a new two-way link joins two components; a one-way link joins none but reaches forward only; blocking and reopening an endpoint splits and rejoins" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var fixture = try TestWorld.init(4, 2);
    defer fixture.deinit();
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const top = fixture.cell(1, 1);
    const bottom = fixture.cell(14, 14);
    try std.testing.expect(reach(&system.graph, 0, top, 1, bottom) != .reaches);
    // One-way: no undirected edge, one directed reach.
    const roots = connectivityRootCount(&system.graph.connectivity);
    try fixture.world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 3, .y = 3 }, .level_b = 1, .cell_b = .{ .x = 9, .y = 9 }, .traversal_cost = 1, .bidirectional = false });
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try std.testing.expectEqual(roots, connectivityRootCount(&system.graph.connectivity));
    try std.testing.expect(reach(&system.graph, 0, top, 1, bottom) == .reaches);
    try std.testing.expect(reach(&system.graph, 1, bottom, 0, top) != .reaches);
    try fixture.expectMatchesRebuild(&system);
    // Two-way: one edge, a root merge.
    try fixture.world.addLevelLink(.{ .kind = .stair, .level_a = 0, .cell_a = .{ .x = 5, .y = 6 }, .level_b = 1, .cell_b = .{ .x = 10, .y = 2 }, .traversal_cost = 1, .bidirectional = true });
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try std.testing.expectEqual(roots - 1, connectivityRootCount(&system.graph.connectivity));
    try std.testing.expect(reach(&system.graph, 0, top, 1, bottom) == .reaches);
    try std.testing.expect(reach(&system.graph, 1, bottom, 0, top) == .reaches);
    try fixture.expectMatchesRebuild(&system);
    // Blocking the level-1 endpoint cuts the only connection.
    try fixture.setCell(&system, 1, 10, 2, fixture.tree);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try std.testing.expectEqual(roots, connectivityRootCount(&system.graph.connectivity));
    // The one-way link still reaches forward; nothing reaches back.
    try std.testing.expect(reach(&system.graph, 0, top, 1, bottom) == .reaches);
    try std.testing.expect(reach(&system.graph, 1, bottom, 0, top) != .reaches);
    try fixture.expectMatchesRebuild(&system);
    try fixture.setCell(&system, 1, 10, 2, fixture.grass);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try std.testing.expect(reach(&system.graph, 0, top, 1, bottom) == .reaches);
    try fixture.expectMatchesRebuild(&system);
}

test "a level added with a link to it while a dig closes the link's old-level end leaves the levels apart" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
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
        const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
        try std.testing.expectEqual(@as(usize, 1), stats.levels_built);
        try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), level, fixture.cell(1, 1)) != .reaches);
        try fixture.expectMatchesRebuild(&system);
        // Reopening the end joins them.
        try fixture.setCell(&system, 0, end[0], end[1], fixture.grass);
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
        try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), level, fixture.cell(1, 1)) == .reaches);
        try fixture.expectMatchesRebuild(&system);
    }
}

test "replacing a level that held the only link between two halves of another splits them" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
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
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try std.testing.expectEqual(@as(usize, 1), stats.levels_built);
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
    const cells = graph.geometry.width * graph.geometry.height;
    const parents = try std.testing.allocator.alloc(u32, cells * graph.levelCount());
    for (parents, 0..) |*parent, index| parent.* = @intCast(index);
    for (0..graph.levelCount()) |level| {
        const grid = graph.grid(@intCast(level)).?;
        const base = level * cells;
        for (0..graph.geometry.height) |y| for (0..graph.geometry.width) |x| {
            if (grid.isBlockedXY(x, y)) continue;
            const here: u32 = @intCast(base + y * graph.geometry.width + x);
            const east = x + 1 < graph.geometry.width and !grid.isBlockedXY(x + 1, y);
            const south = y + 1 < graph.geometry.height and !grid.isBlockedXY(x, y + 1);
            if (east) cellUnite(parents, here, here + 1);
            if (south) cellUnite(parents, here, @intCast(here + graph.geometry.width));
            if (east and south and !grid.isBlockedXY(x + 1, y + 1)) cellUnite(parents, here, @intCast(here + graph.geometry.width + 1));
            const west = x > 0 and !grid.isBlockedXY(x - 1, y);
            if (west and south and !grid.isBlockedXY(x - 1, y + 1)) cellUnite(parents, here, @intCast(here + graph.geometry.width - 1));
        };
    }
    for (world.levelLinks()) |link| {
        if (!link.bidirectional) continue;
        const a = @as(usize, link.cell_a.y) * graph.geometry.width + link.cell_a.x;
        const b = @as(usize, link.cell_b.y) * graph.geometry.width + link.cell_b.x;
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
    const cells = graph.geometry.width * graph.geometry.height;
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(allocator);
    for (world.levelLinks()) |link| {
        if (link.bidirectional) continue;
        const a = @as(usize, link.cell_a.y) * graph.geometry.width + link.cell_a.x;
        const b = @as(usize, link.cell_b.y) * graph.geometry.width + link.cell_b.x;
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
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
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
            _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
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
    const chunk = system.graph.geometry.chunkOfCell(fixture.cell(5, 5));
    try std.testing.expectEqual(no_node, system.graph.levelGraph(0).?.nodeOf(chunk, system.graph.grid(0).?.labelAt(fixture.cell(5, 5))));
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(5, 5), 0, fixture.cell(6, 6)) == .reaches);
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(5, 5), 0, fixture.cell(1, 1)) != .reaches);
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), 0, fixture.cell(6, 5)) != .reaches);
    // A blocked start decides nothing.
    try std.testing.expectEqual(Reach.start_blocked, reach(&system.graph, 0, fixture.cell(4, 4), 0, fixture.cell(4, 4)));
}

test "two hundred seeded random steps of digs, fills, and links match a full rebuild after each" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
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
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
        try fixture.expectMatchesRebuild(&system);
    }
}

test "repeatedly enclosing and reopening a room returns nodes, comps, and roots to their counts" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var fixture = try TestWorld.init(8, 1);
    defer fixture.deinit();
    try buildRoom(&fixture, 3);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const nodes = system.graph.levelGraph(0).?.nodeCount();
    var counts: [2]usize = undefined;
    for (0..6) |cycle| {
        try fixture.setChunk(&system, 0, 3, 1, fixture.tree);
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
        try fixture.setChunk(&system, 0, 3, 1, fixture.grass);
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
        try std.testing.expectEqual(nodes, system.graph.levelGraph(0).?.nodeCount());
        try std.testing.expectEqual(@as(usize, 1), connectivityRootCount(&system.graph.connectivity));
        // Live comps from the first cycle on; the pool reaches its high-water by the second.
        const now = [2]usize{ connectivityCompCount(&system.graph.connectivity), system.graph.connectivity.comps.len };
        if (cycle == 0) counts[0] = now[0] else try std.testing.expectEqual(counts[0], now[0]);
        if (cycle == 1) counts[1] = now[1] else if (cycle > 1) try std.testing.expectEqual(counts[1], now[1]);
    }
    try fixture.expectMatchesRebuild(&system);
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

test "threaded connectivity stages equal the inline ones column for column across worker counts and range sizes" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
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
            threaded.nav_controls = .{ .adaptive = false, .items_per_range = items_per_range };
            // The world build runs the stages threaded over every chunk of each level.
            try threaded.rebuildStaticNavGridWithWorld(&run.data, &run.world, &threads);
            try expectSameColumns(&inline_system.graph, &threaded.graph);
            for ([_]TileId{ run.tree, run.grass, run.tree }) |tile| {
                try writeParityStep(&run, &.{ &inline_system, &threaded }, tile);
                _ = try inline_system.applyBufferedNavUpdates(no_colliders, &run.world, &serial_threads);
                _ = try threaded.applyBufferedNavUpdates(no_colliders, &run.world, &threads);
                try expectSameColumns(&inline_system.graph, &threaded.graph);
                try run.expectMatchesRebuild(&threaded);
            }
        }
    }
}

test "an enclosing batch reserved with the real allocator commits on a multi-worker ThreadSystem without allocating" {
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
    try fixture.expectMatchesRebuild(&system);
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
// batch, and checks it splits off the enclosed rooms and matches a full rebuild.
fn expectEnclosed(side: u16, case: EncloseCase) !void {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
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
    const roots = connectivityRootCount(&system.graph.connectivity);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try std.testing.expectEqual(roots + @as(usize, if (case == .both) 2 else 1), connectivityRootCount(&system.graph.connectivity));
    try fixture.expectMatchesRebuild(&system);
}

test "removals in one component split off only their own sides: one or two enclosures, a far fill, and a walled neighbour label" {
    for (std.meta.tags(EncloseCase)) |case| try expectEnclosed(16, case);
}

// A ring corridor one chunk wide around an `edge` x `edge` solid block, walled off from the
// rest of a level of `side` chunks, cut on its west and east sides in one batch: the north and
// south arcs part.
fn ringCutTwice(side: u16, edge: u16) !void {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
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
    const roots = connectivityRootCount(&system.graph.connectivity);
    try fixture.setChunk(&system, 0, 0, span / 2, fixture.tree);
    try fixture.setChunk(&system, 0, span - 1, span / 2, fixture.tree);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try std.testing.expectEqual(roots + 1, connectivityRootCount(&system.graph.connectivity));
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), 0, fixture.cell(1, @as(usize, span - 1) * test_chunk + 1)) != .reaches);
    try fixture.expectMatchesRebuild(&system);
}

test "two cuts of one ring in one batch part its arcs" {
    try ringCutTwice(16, 4);
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

test "enclosing eight pockets of one component in one batch splits them on a multi-worker ThreadSystem as the inline run does" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
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
        threaded.nav_controls = .{ .adaptive = false, .items_per_range = 1 };
        const roots = connectivityRootCount(&threaded.graph.connectivity);
        try enclosePockets(&fixture, &.{ &inline_system, &threaded }, gaps[0..count]);
        _ = try inline_system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
        _ = try threaded.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
        try std.testing.expectEqual(roots + count, connectivityRootCount(&threaded.graph.connectivity));
        try expectSameColumns(&inline_system.graph, &threaded.graph);
        try fixture.expectMatchesRebuild(&threaded);
    }
}

test "threaded floods equal inline ones column for column when families meet and rounds are narrow" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
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
                threaded.nav_controls = .{ .adaptive = false, .items_per_range = items_per_range };
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
                    _ = try inline_system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
                    _ = try threaded.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
                    try expectSameColumns(&inline_system.graph, &threaded.graph);
                    try fixture.expectMatchesRebuild(&threaded);
                }
            }
        }
    }
}

// Writes `tile` over the `edge` x `edge` chunks from chunk (`first`, `first`) of level 0.
fn setChunkBlock(fixture: *TestWorld, system: *PathfindingSystem, first: u16, edge: u16, tile: TileId) !void {
    for (first..first + edge) |cy| for (first..first + edge) |cx| {
        try fixture.setChunk(system, 0, @intCast(cx), @intCast(cy), tile);
    };
}

test "a dense batch's staging frees down within two release windows of one-chunk batches, which then prepare without allocating" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var fixture = try TestWorld.init(16, 1);
    defer fixture.deinit();
    const window: u32 = 6;
    var system = try fixture.build(windowCapacity(window));
    defer system.deinit();
    const conn = &system.graph.connectivity;
    // A cave-in shape: 64 chunks blocked in one batch.
    try setChunkBlock(&fixture, &system, 2, 8, fixture.tree);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    const dense_staging = conn.stagingBytes();
    const dense_resident = system.graph.residentBytes();
    // One-chunk digs and fills over two release windows.
    for (0..2 * window - 1) |batch| {
        try fixture.setChunk(&system, 0, 13, 13, if (batch % 2 == 0) fixture.tree else fixture.grass);
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    }
    try std.testing.expect(2 * conn.stagingBytes() < dense_staging);
    try std.testing.expect(system.graph.residentBytes() < dense_resident);
    try expectStagingWithin(conn, conn.oneChunkStaging(system.graph.levelGraph(0).?.border_stride));
    try expectGraphStagingWithin(&system.graph);
    // The next one-chunk batch neither shrinks nor grows anything.
    try fixture.setChunk(&system, 0, 13, 13, fixture.grass);
    var stats = NavUpdateStats{};
    const original = system.graph.allocator;
    system.graph.allocator = std.testing.failing_allocator;
    const prepared = system.graph.prepareMarks(&fixture.world, no_colliders.view(), system.nav_marks.items, null, &stats);
    system.graph.allocator = original;
    const batch = system.graph.commitMarks((try prepared).?, no_colliders.view(), null, &stats);
    system.nav_marks.clearRetainingCapacity();
    try std.testing.expect(batch.changed);
    try fixture.expectMatchesRebuild(&system);
}

test "a step that frees a dense batch's staging commits its batch on a multi-worker ThreadSystem without allocating, then releases" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var fixture = try TestWorld.init(16, 1);
    defer fixture.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 4, .items_per_range = 1 });
    defer threads.deinit();
    const window: u32 = 6;
    var capacity = windowCapacity(window);
    capacity.worker_participant_count = threads.participantSlotCount();
    var system = try fixture.build(capacity);
    defer system.deinit();
    const conn = &system.graph.connectivity;
    const nav_threads = forcedNavThreads(&system, &threads);
    try setChunkBlock(&fixture, &system, 2, 8, fixture.tree);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    // One-chunk batches up to the last step of the second release window.
    for (0..2 * window - 2) |batch| {
        try fixture.setChunk(&system, 0, 13, 13, if (batch % 2 == 0) fixture.tree else fixture.grass);
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    }
    const held = conn.stagingBytes();
    try fixture.setChunk(&system, 0, 13, 13, fixture.tree);
    var stats = NavUpdateStats{};
    system.graph.tickStagingStep(window);
    try std.testing.expect(conn.staging_window.closing and system.graph.staging_window.closing);
    const prepared = (try system.graph.prepareMarks(&fixture.world, no_colliders.view(), system.nav_marks.items, nav_threads, &stats)).?;
    const original = system.graph.allocator;
    system.graph.allocator = std.testing.failing_allocator;
    const batch = system.graph.commitMarks(prepared, no_colliders.view(), nav_threads, &stats);
    system.graph.allocator = original;
    system.nav_marks.clearRetainingCapacity();
    try std.testing.expect(batch.changed);
    // The release runs at the step's end, after the commit.
    try std.testing.expectEqual(held, conn.stagingBytes());
    system.graph.finishStagingStep();
    try std.testing.expect(2 * conn.stagingBytes() < held);
    try expectGraphStagingWithin(&system.graph);
    try fixture.expectMatchesRebuild(&system);
}

test "quiet steps through the nav reaction keep a dense batch's staging for its window and free it at the next window's end" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var fixture = try TestWorld.init(16, 1);
    defer fixture.deinit();
    const window: u32 = 6;
    var system = try fixture.build(windowCapacity(window));
    defer system.deinit();
    const conn = &system.graph.connectivity;
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const step = struct {
        fn run(world: *TestWorld, nav: *PathfindingSystem, sim: *SimulationFrame, threads: *ThreadSystem) !NavUpdateStats {
            sim.beginStep();
            return nav.reactToPostCommitNavEvents(sim, no_colliders, &world.world, threads);
        }
    }.run;
    const built_staging = conn.stagingBytes();
    try setChunkBlock(&fixture, &system, 2, 8, fixture.tree);
    try std.testing.expectEqual(@as(usize, 1), (try step(&fixture, &system, &frame, &serial_threads)).incremental_rebuilds);
    const dense_staging = conn.stagingBytes();
    const dense_graph = system.graph.residentBytes();
    try std.testing.expect(dense_staging > 2 * built_staging);
    // Quiet steps to the window's next-to-last: one tick each, nothing freed.
    for (0..window - 2) |_| try std.testing.expectEqual(@as(usize, 0), (try step(&fixture, &system, &frame, &serial_threads)).incremental_rebuilds);
    try std.testing.expectEqual(window - 1, system.graph.staging_window.steps);
    try std.testing.expectEqual(window - 1, conn.staging_window.steps);
    try std.testing.expectEqual(dense_staging, conn.stagingBytes());
    // The window's last step releases, keeping its dense batch's high.
    _ = try step(&fixture, &system, &frame, &serial_threads);
    try std.testing.expectEqual(@as(u32, 0), system.graph.staging_window.steps);
    try std.testing.expectEqual(dense_staging, conn.stagingBytes());
    try std.testing.expectEqual(dense_graph, system.graph.residentBytes());
    // A window of quiet steps: its release frees everything down to the floors.
    for (0..window) |_| _ = try step(&fixture, &system, &frame, &serial_threads);
    try std.testing.expect(2 * conn.stagingBytes() < dense_staging);
    try std.testing.expect(system.graph.residentBytes() < dense_graph);
    try expectStagingWithin(conn, conn.oneChunkStaging(system.graph.levelGraph(0).?.border_stride));
    try expectGraphStagingWithin(&system.graph);
    // The freed staging serves the next dig.
    try fixture.setChunk(&system, 0, 2, 2, fixture.grass);
    _ = try step(&fixture, &system, &frame, &serial_threads);
    try fixture.expectMatchesRebuild(&system);
}

test "dense batches in a row keep their staging across release windows, never shrinking it to regrow" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var fixture = try TestWorld.init(16, 1);
    defer fixture.deinit();
    const window: u32 = 8;
    var system = try fixture.build(windowCapacity(window));
    defer system.deinit();
    const conn = &system.graph.connectivity;
    // Dense blocks and reopenings of one region: two of each warm every list and pool. The
    // world build's level-sized lists are noted in the first window and trimmed by the
    // second's release; later releases free nothing, and nothing ever regrows.
    var warm_grows: u64 = 0;
    var released_staging: usize = 0;
    var released_resident: usize = 0;
    for (0..3 * window + 2) |batch| {
        try setChunkBlock(&fixture, &system, 2, 8, if (batch % 2 == 0) fixture.tree else fixture.grass);
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
        if (batch == 3) warm_grows = system.graph.pool_grows;
        if (batch == 2 * window) {
            released_staging = conn.stagingBytes();
            released_resident = system.graph.residentBytes();
        }
    }
    try std.testing.expect(warm_grows > 0);
    try std.testing.expectEqual(warm_grows, system.graph.pool_grows);
    try std.testing.expectEqual(released_staging, conn.stagingBytes());
    try std.testing.expectEqual(released_resident, system.graph.residentBytes());
    try fixture.expectMatchesRebuild(&system);
}

test "element maps hold their limit at their load, find every key, and a merge map's release frees its slots" {
    const allocator = std.testing.allocator;
    var grows: u64 = 0;
    inline for (.{ ElementMap, MergeMap }, .{ 2, 4 }, .{ 1, 3 }) |Map, load_den, load_num| {
        var map: Map = .{};
        defer map.deinit(allocator);
        // 700 separates the loads: 2048 slots at one half, 1024 at three quarters.
        for ([_]usize{ 1, 12, 48, 700, 1000 }) |limit| {
            try map.reserve(allocator, limit);
            const slots = map.keys.items.len;
            try std.testing.expect(std.math.isPowerOfTwo(slots));
            try std.testing.expect(load_den * limit <= load_num * slots or limit == 0);
            if (limit == 700) try std.testing.expectEqual(@as(usize, if (Map == ElementMap) 2048 else 1024), slots);
            map.clear();
            for (0..limit) |index| map.put(@as(u64, index) *% 0x2545F4914F6CDD1D, @intCast(index));
            for (0..limit) |index| try std.testing.expectEqual(@as(?u32, @intCast(index)), map.get(@as(u64, index) *% 0x2545F4914F6CDD1D));
            try std.testing.expectEqual(@as(?u32, null), map.get(0xFFFF_FFFF_FFFF));
        }
    }
    var map: MergeMap = .{};
    defer map.deinit(allocator);
    try map.reserveStaging(allocator, 1000, &grows);
    try std.testing.expectEqual(@as(u64, 1), grows);
    // A release keeping a small batch frees the slots down to it, uncounted.
    map.release(allocator, 10);
    try std.testing.expectEqual(@as(usize, 16), map.keys.items.len);
    try std.testing.expectEqual(@as(u64, 1), grows);
}

test "a level build's staging frees at the end of its step, and a one-chunk batch then prepares without allocating" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var fixture = try TestWorld.init(16, 2);
    defer fixture.deinit();
    try buildRoom(&fixture, 3);
    const window: u32 = 4;
    var system = try fixture.build(windowCapacity(window));
    defer system.deinit();
    const conn = &system.graph.connectivity;
    const stride = system.graph.levelGraph(0).?.border_stride;
    // An enclosure and its reopening warm the node pool, the free ids, and the round buffers,
    // and set the one-chunk floor.
    try fixture.setChunk(&system, 0, 3, 1, fixture.tree);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try fixture.setChunk(&system, 0, 3, 1, fixture.grass);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    // A level added in play grows the staging to a level; its step's end frees it.
    const level = try fixture.world.addLevel(-32);
    _ = try fixture.world.addDenseLayer(level, 0, .floor, fixture.grass);
    const added = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try std.testing.expectEqual(@as(usize, 1), added.levels_built);
    try std.testing.expect(system.graph.staging_window.steps < window);
    try expectStagingWithin(conn, conn.oneChunkStaging(stride));
    try expectGraphStagingWithin(&system.graph);
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
    try fixture.expectMatchesRebuild(&system);
}

test "levels added together in one step build on one shared staging, freed once at the step's end" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var fixture = try TestWorld.init(16, 1);
    defer fixture.deinit();
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const conn = &system.graph.connectivity;
    const stride = system.graph.levelGraph(0).?.border_stride;
    const addLevels = struct {
        fn run(world: *TestWorld, count: usize, first_depth: i32) !void {
            for (0..count) |index| {
                const level = try world.world.addLevel(first_depth - 32 * @as(i32, @intCast(index)));
                _ = try world.world.addDenseLayer(level, 0, .floor, world.grass);
            }
        }
    }.run;
    // One level per step: each step grows the level-sized staging from the floors.
    try addLevels(&fixture, 1, -32);
    const single_before = system.graph.pool_grows;
    try std.testing.expectEqual(@as(usize, 1), (try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads)).levels_built);
    const single_grows = system.graph.pool_grows - single_before;
    try expectStagingWithin(conn, conn.oneChunkStaging(stride));
    // Three in one step: each level's own pools grow from empty, the shared staging once.
    try addLevels(&fixture, 3, -64);
    const step_before = system.graph.pool_grows;
    try std.testing.expectEqual(@as(usize, 3), (try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads)).levels_built);
    try std.testing.expect(system.graph.pool_grows - step_before < 3 * single_grows);
    try expectStagingWithin(conn, conn.oneChunkStaging(stride));
    try expectGraphStagingWithin(&system.graph);
    try fixture.expectMatchesRebuild(&system);
}

// A one-chunk tunnel of `length` chunks east from chunk (1, side / 2) of an open level of
// `side` chunks, capped at its far end, its mouth chunk filled in one batch. Checks it splits
// off the tunnel and matches a full rebuild.
fn expectTunnelEnclosed(side: u16, length: u16) !void {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
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
    const roots = connectivityRootCount(&system.graph.connectivity);
    try fixture.setChunk(&system, 0, 1, row, fixture.tree);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try std.testing.expectEqual(roots + 1, connectivityRootCount(&system.graph.connectivity));
    try fixture.expectMatchesRebuild(&system);
}

test "enclosing a thin tunnel off an open level splits it off" {
    try expectTunnelEnclosed(16, 8);
}

// `fixture`'s ringed room of `edge` x `edge` chunks at chunk (1, 1), enclosed in one batch on
// a system whose flood items stop at `budget_cap` proposals. Checks the result against a full
// rebuild and returns the system for comparison.
fn encloseRoomSystem(fixture: *TestWorld, edge: u16, budget_cap: u32) !struct { system: PathfindingSystem, stats: NavUpdateStats } {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var system = try fixture.build(test_support.abstractCapacity());
    errdefer system.deinit();
    system.graph.connectivity.flood_budget_cap = budget_cap;
    const roots = connectivityRootCount(&system.graph.connectivity);
    try fixture.setChunk(&system, 0, edge + 2, 2 + edge / 2, fixture.tree);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try std.testing.expectEqual(roots + 1, connectivityRootCount(&system.graph.connectivity));
    try fixture.expectMatchesRebuild(&system);
    return .{ .system = system, .stats = stats };
}

test "a flood whose items stop at four proposals partitions as the default one does" {
    const edge: u16 = 8;
    var fixture = try TestWorld.init(32, 1);
    defer fixture.deinit();
    _ = try ringedRoom(&fixture, 1, 1, edge);
    var wide = try encloseRoomSystem(&fixture, edge, default_flood_budget_cap);
    defer wide.system.deinit();
    try fixture.setChunk(null, 0, edge + 2, 2 + edge / 2, fixture.grass);
    var narrow = try encloseRoomSystem(&fixture, edge, 4);
    defer narrow.system.deinit();
    try test_support.expectSameConnectivityPartition(&narrow.system.graph, &wide.system.graph);
}

// One node's slack plus four proposal slots: a round holds a few searches.
fn narrowFloodWindow(system: *PathfindingSystem) void {
    const slack = system.graph.levelGraph(0).?.border_stride + system.graph.connectivity.max_chunk_endpoints;
    system.graph.connectivity.flood_window = slack + 4;
}

test "a hub family wider than one round splits the same in wide and narrow rounds" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    const tunnels: u16 = 16;
    for ([_]bool{ false, true }) |joined| {
        var fixture = try TestWorld.init(2 * tunnels, 1);
        defer fixture.deinit();
        try hubTunnels(&fixture, tunnels, joined);
        const components: usize = if (joined) tunnels - (tunnels - 1) / 2 else tunnels;
        for ([_]bool{ false, true }) |narrow| {
            var system = try fixture.build(test_support.abstractCapacity());
            defer system.deinit();
            if (narrow) narrowFloodWindow(&system);
            const roots = connectivityRootCount(&system.graph.connectivity);
            try setHubCorridor(&fixture, &system, tunnels, fixture.tree);
            _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
            try std.testing.expectEqual(roots + components - 1, connectivityRootCount(&system.graph.connectivity));
            try fixture.expectMatchesRebuild(&system);
            try setHubCorridor(&fixture, null, tunnels, fixture.grass);
        }
    }
}

test "a flooding reaction reaches its adaptive tuner as one sample at the batch's set count and selected profile" {
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
        try std.testing.expect(system.nav_controls.adaptive and system.nav_controls.items_per_range == null);
        narrowFloodWindow(&system);
        const tuner = system.tuners.nav.getPtr(.conn_flood);
        if (settled) {
            tuner.phase = .settled;
            tuner.has_threaded_profile = true;
            tuner.current_profile = .{ .worker_threads = 2, .items_per_range = 4 };
        }
        var before = tuner.*;
        try setHubCorridor(&fixture, &system, tunnels, fixture.tree);
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
        const set_count = system.graph.connectivity.sets.len;
        const selected = threads.selectBatchProfile(&before, .{ .item_count = set_count }).profile;
        try std.testing.expectEqual(settled, selected.worker_threads != 0);
        // Several rounds, one record.
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
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
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
        const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
        try std.testing.expectEqual(@as(usize, 1), stats.levels_built);
        comp_grows += @intFromBool(conn.comps.capacity != comp_capacity);
        root_grows += @intFromBool(conn.roots.capacity != root_capacity);
    }
    // At most a doubling per growth: log2(17) + 2.
    try std.testing.expect(comp_grows <= 7 and root_grows <= 7);
    try fixture.expectMatchesRebuild(&system);
}

test "a batch whose only change is a two-way link between unbuilt levels commits without allocating" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
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
    const built = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try std.testing.expectEqual(@as(usize, 2), built.levels_built);
    try std.testing.expect(reach(&system.graph, 1, fixture.cell(2, 2), 2, fixture.cell(9, 9)) == .reaches);
    try fixture.expectMatchesRebuild(&system);
}

test "a pool grows to exactly its need from empty, then to twice its capacity, its free list exactly; past its sentinel it fails as OutOfMemory and keeps its ids" {
    const allocator = std.testing.allocator;
    var rows: std.MultiArrayList(CompRow) = .{};
    defer rows.deinit(allocator);
    var free: std.ArrayList(u32) = .empty;
    defer free.deinit(allocator);
    const empty = CompRow{ .root = no_root, .size = 0, .prev = no_comp, .next = no_comp, .set = no_set };
    var grows: u64 = 0;
    try growPool(CompRow, allocator, &rows, &free, 3, empty, no_comp, &grows);
    try std.testing.expectEqual(@as(usize, 3), rows.capacity);
    try std.testing.expectEqual(@as(usize, 3), free.capacity);
    try std.testing.expectEqual(@as(u64, 1), grows);
    // Pops hand out ascending ids.
    try std.testing.expectEqual(@as(?u32, 0), free.pop());
    try std.testing.expectEqual(@as(?u32, 1), free.pop());
    // A need past the capacity by one doubles it; the free list covers the pool exactly.
    try growPool(CompRow, allocator, &rows, &free, 3, empty, no_comp, &grows);
    try std.testing.expectEqual(@as(usize, 6), rows.capacity);
    try std.testing.expectEqual(@as(usize, 6), free.capacity);
    try std.testing.expectEqual(@as(usize, 5), rows.len);
    try std.testing.expectEqual(@as(u64, 2), grows);
    // Already covered: nothing grows.
    try growPool(CompRow, allocator, &rows, &free, 3, empty, no_comp, &grows);
    try std.testing.expectEqual(@as(u64, 2), grows);
    // A need reaching the sentinel fails as the allocator would, before asking it; the pool
    // keeps its rows, ids, and capacity.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, growPool(CompRow, failing.allocator(), &rows, &free, 6, empty, 8, &grows));
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 5), rows.len);
    try std.testing.expectEqual(@as(usize, 6), rows.capacity);
    try std.testing.expectEqual(@as(usize, 3), free.items.len);
    try std.testing.expectEqual(@as(u64, 2), grows);
    // One id short of the sentinel still grows: ids 5 and 6 are below 8.
    try growPool(CompRow, allocator, &rows, &free, 5, empty, 8, &grows);
    try std.testing.expectEqual(@as(usize, 7), rows.len);
    try std.testing.expectEqual(@as(?u32, 5), free.pop());
}

test "a block cap, a map's slot count, and a merge's element limit past their index widths fail as OutOfMemory" {
    try std.testing.expectEqual(@as(u32, 1 << 31), try boundCap(1 << 31));
    try std.testing.expectError(error.OutOfMemory, boundCap((1 << 31) + 1));
    try std.testing.expectError(error.OutOfMemory, boundCap(std.math.maxInt(usize)));
    try std.testing.expectError(error.OutOfMemory, MergeMap.slotCount(std.math.maxInt(usize)));
    // The element limit is checked before any reserve: nothing is asked of the allocator and
    // the stored limit stays.
    var conn = Connectivity{};
    defer conn.deinit(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    var grows: u64 = 0;
    try std.testing.expectError(error.OutOfMemory, conn.reserveMerge(failing.allocator(), no_unit, 0, &grows));
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), conn.element_limit);
    try std.testing.expectEqual(@as(u64, 0), grows);
}

test "a marks batch reaching an exhausted comp id pool fails as OutOfMemory without asking the allocator, keeps the graph and its change pending, and the retry equals a rebuild" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var fixture = try TestWorld.init(4, 1);
    defer fixture.deinit();
    var system = try fixture.build(windowCapacity(exhausted_pool_window));
    defer system.deinit();
    // A wall across the level splits it: the batch needs fresh comps. Placed, removed, and
    // placed again, so the last batch's staging is warm.
    for ([_]TileId{ fixture.tree, fixture.grass }) |tile| {
        for (0..16) |y| try fixture.setCell(&system, 0, 7, @intCast(y), tile);
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    }
    var before = try fixture.build(test_support.abstractCapacity());
    defer before.deinit();
    for (0..16) |y| try fixture.setCell(&system, 0, 7, @intCast(y), fixture.tree);
    try expectExhaustedPoolBatch(&fixture, &system, &before, .comps, true);
}

test "a level build reaching an exhausted comp id pool fails as OutOfMemory, keeps the built levels and the new level pending, and the retry equals a rebuild" {
    var fixture = try TestWorld.init(4, 1);
    defer fixture.deinit();
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    var before = try fixture.build(test_support.abstractCapacity());
    defer before.deinit();
    const level = try fixture.world.addLevel(-16);
    _ = try fixture.world.addDenseLayer(level, 0, .floor, fixture.grass);
    // Unarmed: a level build allocates its fresh storage before its id growth.
    try expectExhaustedPoolBatch(&fixture, &system, &before, .comps, false);
}

test "a marks batch reserves a key's node rows up to its chunk's label bound, however many link endpoints the chunk holds" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var fixture = try TestWorld.init(4, 1);
    defer fixture.deinit();
    // Twelve two-way links from chunk (1, 1) to chunk (3, 3): twelve endpoints in a chunk of
    // at most eight labels.
    for (0..12) |link| {
        const near: u16 = @intCast(4 + link % 4);
        try fixture.world.addLevelLink(.{ .kind = .stair, .level_a = 0, .cell_a = .{ .x = near, .y = @intCast(4 + link / 4) }, .level_b = 0, .cell_b = .{ .x = 13, .y = 13 }, .traversal_cost = 1, .bidirectional = true });
    }
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const level_graph = system.graph.levelGraph(0).?;
    const rows_before = level_graph.nodes.len;
    try std.testing.expectEqual(rows_before, level_graph.nodeCount());
    // A dig inside chunk (1, 1): five patch keys, each reserving at most the label bound.
    try fixture.setCell(&system, 0, 5, 7, fixture.tree);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try std.testing.expectEqual(@as(usize, 5), stats.chunks_patched);
    try std.testing.expect(level_graph.nodes.len <= rows_before + 5 * maxChunkLabels(test_chunk));
    try fixture.expectMatchesRebuild(&system);
}
