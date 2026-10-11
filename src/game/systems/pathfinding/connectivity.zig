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
const offMainNs = @import("nav_graph.zig").offMainNs;
const chunkKey = @import("nav_graph.zig").chunkKey;
const keyLevel = @import("nav_graph.zig").keyLevel;
const keyChunk = @import("nav_graph.zig").keyChunk;
const types = @import("types.zig");
const NavUpdateStats = types.NavUpdateStats;
const setLen = types.setLen;

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

// A root: the head of its member comps and their count. A freed root links the next freed
// root of its group through `head` until the commit.
const RootRow = struct {
    head: u32,
    members: u32,
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

/// Whether `goal_cell` on `goal_level` is reachable from `start_cell` on `start_level` over
/// the graph's border mirrors and two-way links: the same chunk label, or two nodes under one
/// root. A blocked cell reaches nothing; a label holding no portal, or a chunk holding no
/// record, reaches only its own chunk label. Undirected only: one-way links join no root, and
/// with no closure over them maintained a goal reached only across a one-way link reads false.
/// O(1): two label reads, two record node walks (at most the portal-bearing labels of one
/// chunk each), two root reads.
pub fn reach(graph: *const NavGraph, start_level: u16, start_cell: usize, goal_level: u16, goal_cell: usize) bool {
    const start_grid = graph.grid(start_level) orelse return false;
    const goal_grid = graph.grid(goal_level) orelse return false;
    const start_label = start_grid.labelAt(start_cell);
    const goal_label = goal_grid.labelAt(goal_cell);
    if (start_label == 0 or goal_label == 0) return false;
    const start_chunk = start_grid.chunkOfCell(start_cell);
    const goal_chunk = goal_grid.chunkOfCell(goal_cell);
    if (start_level == goal_level and start_chunk == goal_chunk and start_label == goal_label) return true;
    const start_graph = graph.levelGraph(start_level).?;
    const goal_graph = graph.levelGraph(goal_level).?;
    const start_row = start_graph.nodeOf(start_chunk, start_label);
    const goal_row = goal_graph.nodeOf(goal_chunk, goal_label);
    if (start_row == no_node or goal_row == no_node) return false;
    const conn = &graph.connectivity;
    return conn.comp_root[start_graph.node_comp[start_row]] == conn.comp_root[goal_graph.node_comp[goal_row]];
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

// Open-addressed u64 -> u32 map, cleared by a generation bump. Its slot count is a power of
// two at least twice its logical limit, so probes stay short and an insert always finds room.
const ElementMap = struct {
    keys: std.ArrayList(u64) = .empty,
    values: std.ArrayList(u32) = .empty,
    stamps: std.ArrayList(u32) = .empty,
    generation: u32 = 1,
    limit: usize = 0,
    used: usize = 0,

    fn deinit(self: *ElementMap, allocator: std.mem.Allocator) void {
        self.stamps.deinit(allocator);
        self.values.deinit(allocator);
        self.keys.deinit(allocator);
        self.* = .{};
    }

    fn reserve(self: *ElementMap, allocator: std.mem.Allocator, limit: usize) !void {
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
    fn shrink(self: *ElementMap, allocator: std.mem.Allocator, limit: usize) void {
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

    fn clear(self: *ElementMap) void {
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

    fn get(self: *const ElementMap, key: u64) ?u32 {
        const slot = self.slotOf(key);
        return if (self.stamps.items[slot] == self.generation) self.values.items[slot] else null;
    }

    fn put(self: *ElementMap, key: u64, value: u32) void {
        const slot = self.slotOf(key);
        std.debug.assert(self.stamps.items[slot] != self.generation);
        std.debug.assert(self.used < self.limit);
        self.used += 1;
        self.stamps.items[slot] = self.generation;
        self.keys.items[slot] = key;
        self.values.items[slot] = value;
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
            self.root_free.capacity * @sizeOf(u32);
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
                self.root_first.capacity + self.round_sets.capacity) * @sizeOf(u32);
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
            for (0..added) |_| self.roots.appendAssumeCapacity(.{ .head = no_comp, .members = 0 });
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
    // O(1) per link. Links are append-only; a world that dropped links keeps the larger max.
    fn noteLinks(self: *Connectivity, world: ?*const WorldSystem) void {
        const world_system = world orelse return;
        const links = world_system.levelLinks();
        if (self.endpoint_links_seen > links.len) self.endpoint_links_seen = links.len;
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
        new_link_count: usize,
        threads: ?NavStageThreads,
        pool_grows: *u64,
        stats: *NavUpdateStats,
    ) !void {
        std.debug.assert(patch_info.len == patch_keys.len);
        // Flags and seed windows: changed keys are a sorted subset of the sorted patch keys.
        try setLen(&self.patch_changed, allocator, patch_keys.len);
        try setLen(&self.seed_starts, allocator, changed_keys.len + 1);
        try setLen(&self.seed_counts, allocator, changed_keys.len);
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
        try setLen(&self.seed_edges, allocator, seed_total);

        // Gather windows: per patch key its old nodes and new labels as rows and one edge per
        // border flag and link endpoint; per new link one edge.
        const item_count = patch_keys.len + new_link_count;
        try setLen(&self.row_starts, allocator, item_count + 1);
        try setLen(&self.edge_starts, allocator, item_count + 1);
        try setLen(&self.row_counts, allocator, item_count);
        try setLen(&self.edge_counts, allocator, item_count);
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
        try setLen(&self.gather_rows, allocator, row_total);
        try setLen(&self.gather_edges, allocator, edge_total);

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
        self.marks_staging_high = self.marks_staging_high.max(.{
            .changed_keys = changed_keys.len,
            .patch_keys = patch_keys.len,
            .items = item_count,
            .seeds = seed_total,
            .rows = row_total,
            .edges = edge_total,
            .elements = limit,
        });

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
        self.last_seed_batch = runStage(threads, changed_keys.len, &job, &job.range_count, seedJob);
        stats.off_main_stage_ns += offMainNs(self.last_seed_batch);
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
        self.last_gather_batch = runStage(gather_threads, patch_keys.len + new_links.len, &gather, &gather.range_count, gatherJob);
        stats.off_main_stage_ns += offMainNs(self.last_gather_batch);
        self.mergeBatch(levels, patch_keys, true, patch_keys.len + new_links.len, null);
        return self.settleAndFlood(levels, world, flood_threads, stats);
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
        pool_grows: *u64,
        stats: *NavUpdateStats,
    ) !ConnectivityCounters {
        const fresh = levels.fresh.?;
        const level_graph = fresh.graph;
        const seeding = replaced != null;
        // The staging shrinks back when the build ends, and on an error too.
        errdefer self.shrinkStaging(allocator, self.marks_staging_high.max(self.oneChunkStaging(level_graph.border_stride)));
        try setLen(&self.row_starts, allocator, keys.len + 1);
        try setLen(&self.edge_starts, allocator, keys.len + 1);
        try setLen(&self.row_counts, allocator, keys.len);
        try setLen(&self.edge_counts, allocator, keys.len);
        try setLen(&self.seed_starts, allocator, if (seeding) keys.len + 1 else 1);
        try setLen(&self.seed_counts, allocator, if (seeding) keys.len else 0);
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
        try setLen(&self.gather_rows, allocator, labels);
        try setLen(&self.gather_edges, allocator, edge_total);
        try setLen(&self.seed_edges, allocator, seed_total);
        // No fresh row is old, so no key reads as remasked.
        try setLen(&self.patch_changed, allocator, keys.len);
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
            stats.off_main_stage_ns += offMainNs(self.last_seed_batch);
        } else {
            self.last_seed_batch = .{};
        }
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
        self.last_gather_batch = runStage(gather_threads, keys.len, &gather, &gather.range_count, gatherJob);
        stats.off_main_stage_ns += offMainNs(self.last_gather_batch);
        self.mergeBatch(levels, keys, false, keys.len, replaced);
        const counters = self.settleAndFlood(levels, world, flood_threads, stats);
        self.shrinkStaging(allocator, self.marks_staging_high.max(self.oneChunkStaging(level_graph.border_stride)));
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
            std.debug.assert(self.root_free.items.len < self.root_free.capacity);
            self.root_free.appendAssumeCapacity(root);
        }
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
        if (counters.families != 0) self.runFlood(views, threads, &counters, stats);
        self.finish(views, &counters);
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
            dispatch.run(item_count, &job, &job.range_count, floodJob);

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
// the edges leaving those new labels. Per new link: its edge, when it is two-way and both of
// its ends are open portals on built levels.
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
    range_count: usize = 0,
};

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

    // Asserts `system`'s connectivity is consistent and partitions as a full rebuild does.
    fn expectMatchesRebuild(self: *TestWorld, system: *const PathfindingSystem) !void {
        var rebuilt = try self.build(test_support.abstractCapacity());
        defer rebuilt.deinit();
        try test_support.expectConnectivityConsistent(&system.graph);
        try test_support.expectConnectivityConsistent(&rebuilt.graph);
        try test_support.expectSameConnectivityPartition(&system.graph, &rebuilt.graph);
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
            try std.testing.expect(reach(&system.graph, 0, inside, 0, outside));
            const roots = system.graph.connectivity.rootCount();

            try fixture.setChunk(&system, 0, edge, edge / 2, fixture.tree);
            const enclosed = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
            // A one-chunk room loses its only portal: no node is left to split off.
            const split: usize = if (edge > 1) 1 else 0;
            try std.testing.expectEqual(split, enclosed.conn_splits);
            try std.testing.expect(!reach(&system.graph, 0, inside, 0, outside));
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
            try std.testing.expect(reach(&system.graph, 0, inside, 0, outside));
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
        try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), 0, fixture.cell(1, @as(usize, span - 1) * test_chunk + 1)));
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
    try std.testing.expect(!reach(&system.graph, 0, fixture.cell(1, 1), 0, fixture.cell(20, 20)));
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
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), 0, fixture.cell(20, 20)));
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

test "a new two-way link joins two components; a one-way link joins none; blocking and reopening an endpoint splits and rejoins" {
    var fixture = try TestWorld.init(4, 2);
    defer fixture.deinit();
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const top = fixture.cell(1, 1);
    const bottom = fixture.cell(14, 14);
    try std.testing.expect(!reach(&system.graph, 0, top, 1, bottom));
    // One-way: no undirected edge.
    try fixture.world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 3, .y = 3 }, .level_b = 1, .cell_b = .{ .x = 9, .y = 9 }, .traversal_cost = 1, .bidirectional = false });
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expect(!reach(&system.graph, 0, top, 1, bottom));
    try fixture.expectMatchesRebuild(&system);
    // Two-way: one edge, a root merge.
    try fixture.world.addLevelLink(.{ .kind = .stair, .level_a = 0, .cell_a = .{ .x = 5, .y = 6 }, .level_b = 1, .cell_b = .{ .x = 10, .y = 2 }, .traversal_cost = 1, .bidirectional = true });
    const linked = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), linked.conn_merges);
    try std.testing.expect(reach(&system.graph, 0, top, 1, bottom));
    try fixture.expectMatchesRebuild(&system);
    // Blocking the level-1 endpoint cuts the only connection.
    try fixture.setCell(&system, 1, 10, 2, fixture.tree);
    const blocked = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), blocked.conn_splits);
    try std.testing.expect(!reach(&system.graph, 0, top, 1, bottom));
    try fixture.expectMatchesRebuild(&system);
    try fixture.setCell(&system, 1, 10, 2, fixture.grass);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expect(reach(&system.graph, 0, top, 1, bottom));
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
        try std.testing.expect(!reach(&system.graph, 0, fixture.cell(1, 1), level, fixture.cell(1, 1)));
        try fixture.expectMatchesRebuild(&system);
        // Reopening the end joins them.
        try fixture.setCell(&system, 0, end[0], end[1], fixture.grass);
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), level, fixture.cell(1, 1)));
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
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), 0, fixture.cell(20, 21)));
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
    try std.testing.expect(!reach(&system.graph, 0, fixture.cell(1, 1), 0, fixture.cell(20, 21)));
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

// Asserts `reach` equals the cell-level reference for every pair of open cells.
fn expectReachMatchesCells(graph: *const NavGraph, world: *const WorldSystem) !void {
    const parents = try referenceCellParents(graph, world);
    defer std.testing.allocator.free(parents);
    const cells = graph.width * graph.height;
    for (0..parents.len) |from| {
        const from_level: u16 = @intCast(from / cells);
        if (graph.grid(from_level).?.isBlockedIndex(from % cells)) continue;
        for (0..parents.len) |to| {
            const to_level: u16 = @intCast(to / cells);
            if (graph.grid(to_level).?.isBlockedIndex(to % cells)) continue;
            const expected = cellFind(parents, @intCast(from)) == cellFind(parents, @intCast(to));
            try std.testing.expectEqual(expected, reach(graph, from_level, from % cells, to_level, to % cells));
        }
    }
}

test "reach equals a cell-level search over every pair, built and after random changes, with one-way links joining nothing" {
    var prng = std.Random.DefaultPrng.init(0x7c1);
    const random = prng.random();
    for (0..3) |_| {
        var fixture = try TestWorld.init(3, 2);
        defer fixture.deinit();
        for (0..2) |level| for (0..12) |y| for (0..12) |x| {
            if (random.uintLessThan(u8, 100) < 38) try fixture.setCell(null, @intCast(level), @intCast(x), @intCast(y), fixture.tree);
        };
        for (0..4) |index| {
            try fixture.world.addLevelLink(.{
                .kind = .stair,
                .level_a = @intCast(index % 2),
                .cell_a = .{ .x = random.uintLessThan(u16, 12), .y = random.uintLessThan(u16, 12) },
                .level_b = @intCast((index / 2) % 2),
                .cell_b = .{ .x = random.uintLessThan(u16, 12), .y = random.uintLessThan(u16, 12) },
                .traversal_cost = 1,
                .bidirectional = index != 3,
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
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(5, 5), 0, fixture.cell(6, 6)));
    try std.testing.expect(!reach(&system.graph, 0, fixture.cell(5, 5), 0, fixture.cell(1, 1)));
    try std.testing.expect(!reach(&system.graph, 0, fixture.cell(1, 1), 0, fixture.cell(6, 5)));
    // A blocked cell reaches nothing.
    try std.testing.expect(!reach(&system.graph, 0, fixture.cell(4, 4), 0, fixture.cell(4, 4)));
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

// Asserts `a` and `b` hold bitwise equal connectivity columns.
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
    try std.testing.expect(!reach(&system.graph, 0, fixture.cell(1, 1), 0, fixture.cell(1, @as(usize, span - 1) * test_chunk + 1)));
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
    try std.testing.expect(reach(&system.graph, 1, fixture.cell(2, 2), 2, fixture.cell(9, 9)));
    try fixture.expectMatchesRebuild(&system);
}
