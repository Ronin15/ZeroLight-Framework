// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! The collision system's stored static-trigger pairs: one paged order tree per level, all in
//! one `TriggerStore` per world. A level's pairs, in contact-key order (the level is the key's
//! top 16 bits), are split into sorted pages of up to `page_capacity` pairs held in pooled
//! `PayloadSlabs` slots with SoA columns. Pages are the leaves of the level's B+-tree; each
//! page's header masks its valid and allowed slots, and each inner node holds its children's
//! first keys and a prefix of their counts of every `PairCount`. The level table is indexed by
//! level id; `LevelRank`, a Fenwick tree over the levels' counts, folds the levels into one
//! global order per count, so `cursorAt(ordinal)` and `emittedCursorAt(count, ordinal)` are a
//! Fenwick find plus one tree descent.
//!
//! A patch takes its edits as data: inserts located to their page, and drop pieces naming the
//! slots of one page. Main buckets them by level, page and node; a banded sort orders the
//! inserts; main plans every tree height of every touched level from counts alone; one leaf
//! dispatch writes the fresh pages; main writes the nodes and installs. Every allocation
//! happens before the first stored mutation. A rebuild runs the same plan from empty trees.

const std = @import("std");
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const Dispatch = @import("../../app/thread_system.zig").Dispatch;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const SlotList = @import("../../app/thread_system.zig").SlotList;
const StageControls = @import("../../app/thread_system.zig").StageControls;
const StageThreads = @import("../../app/thread_system.zig").StageThreads;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;
const changedCapacities = @import("../../app/thread_system.zig").changedCapacities;
const rebuild_tuner_config = @import("../../app/thread_system.zig").rebuild_tuner_config;
const runShaped = @import("../../app/thread_system.zig").runShaped;
const StageShape = @import("../../app/thread_system.zig").StageShape;
const runtime_perf_log = @import("../../app/runtime_perf_log.zig");
const StageTimer = runtime_perf_log.StageTimer;
const logging = @import("../../core/logging.zig");
const pdqSort = @import("../../core/sort.zig").pdq;
const simd = @import("../../core/simd.zig");
const CollisionContact = @import("../simulation.zig").CollisionContact;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const banded_sort = @import("banded_sort.zig");
const BandOffsets = banded_sort.BandOffsets;
const PayloadSlabs = @import("chunk_list_map.zig").PayloadSlabs;
const no_entry = @import("chunk_list_map.zig").no_entry;
const payload_slot_alignment = @import("chunk_list_map.zig").payload_slot_alignment;

/// Pairs per page (P). A page's drop set is one u64, and every column holds whole 64 B lines.
pub const page_capacity: u32 = 64;
/// Entries per inner node (F): the largest fanout whose node fits the 3072 B slot class and
/// whose touched-children set is one u64.
const node_capacity: u32 = 62;
// The B+-tree fill bounds of a non-root page and node.
const page_min: u32 = page_capacity / 2;
const node_min: u32 = node_capacity / 2;
// Inner nodes on a page's path: with u32 pair counts and the fill bounds, a level tree is at
// most 6 high, so this is a format width, not a cap.
const max_tree_height = 7;
// A stored row whose entity has no movement body.
const no_row: u32 = std.math.maxInt(u32);
// `emit` bit 0: both rows resolve. Bit 1: both tiers allow collision.
const emit_valid: u8 = 1;
const emit_allowed: u8 = 2;

/// The emit bits of a stored pair whose rows both resolve, from each side's tier allowing
/// collision.
pub fn emitBits(a_allows: bool, b_allows: bool) u8 {
    return emit_valid | if (a_allows and b_allows) emit_allowed else 0;
}

/// What a count or an ordinal over the stored pairs counts: every pair, the pairs whose rows
/// resolve, or those whose tiers also both allow collision.
pub const PairCount = enum {
    pairs,
    valid,
    allowed,

    /// The pairs a step emits as contacts: the allowed ones with `exclude`, else the valid.
    pub fn emitted(exclude: bool) PairCount {
        return if (exclude) .allowed else .valid;
    }
};

const Counts = std.EnumArray(PairCount, u32);

// True when a stored pair with emit bits `emit` counts as `kind`.
fn countsAs(emit: u8, kind: PairCount) bool {
    return switch (kind) {
        .pairs => true,
        .valid => emit & emit_valid != 0,
        .allowed => emit == emit_valid | emit_allowed,
    };
}

// Insert place and sort ranges start on cache-line boundaries of the staging and destination
// windows and span at least one line, as the static pair sort's ranges do.
const insert_range_alignment_items: usize = 16;
// A refresh range owns the pages that start in it and writes each one's counts or prefix into
// its parent's entry: a cache line of u32 entries is 16 pages, 16 full pages' pairs.
const refresh_range_alignment_items: usize = page_capacity * (thread_shared_record_alignment / @sizeOf(u32));
// Leaf items are whole output pages, each at least a 2.5 KB slot, and each also writes its
// `LevelOutput` record, under a cache line: two items make a range span a line of those
// records.
const rewrite_range_alignment_items: usize = 2;

// ---- Page and node layouts -----------------------------------------------------------

const header_bytes: usize = 64;

const PageHeader = struct {
    len: u32,
    // The slots whose rows resolve, and those whose tiers also both allow collision.
    valid_mask: u64,
    allowed_mask: u64,

    // The slots that count as `kind`.
    fn slots(self: PageHeader, kind: PairCount) u64 {
        return switch (kind) {
            .pairs => lowSlots(self.len),
            .valid => self.valid_mask,
            .allowed => self.allowed_mask,
        };
    }

    fn counts(self: PageHeader) Counts {
        return .init(.{ .pairs = self.len, .valid = @popCount(self.valid_mask), .allowed = @popCount(self.allowed_mask) });
    }
};

const NodeHeader = struct {
    count: u32,
    /// The subtree's pairs of each count.
    totals: Counts,
};

// Page columns in hot-loop read order, at comptime offsets past the header.
const page_columns = .{
    .{ "keys", u256 },
    .{ "a", EntityId },
    .{ "b", EntityId },
    .{ "a_row", u32 },
    .{ "b_row", u32 },
    .{ "normal_x", f32 },
    .{ "normal_y", f32 },
    .{ "penetration", f32 },
    .{ "max_speed_sq", f32 },
    .{ "rel_speed_sq", f32 },
    .{ "emit", u8 },
};

fn columnOffset(comptime columns: anytype, comptime name: []const u8, comptime capacity: usize) usize {
    comptime var offset = header_bytes;
    inline for (columns) |column| {
        if (comptime std.mem.eql(u8, column[0], name)) return offset;
        offset += capacity * @sizeOf(column[1]);
    }
    @compileError("no column " ++ name);
}

fn layoutBytes(comptime columns: anytype, comptime capacity: usize) usize {
    comptime var offset = header_bytes;
    inline for (columns) |column| offset += capacity * @sizeOf(column[1]);
    return offset;
}

// `start`, `valid_start` and `allowed_start`: the node's pairs of each count before the entry.
const node_columns = .{
    .{ "first_key", u256 },
    .{ "child", u32 },
    .{ "start", u32 },
    .{ "valid_start", u32 },
    .{ "allowed_start", u32 },
};

const page_bytes = layoutBytes(page_columns, page_capacity);
const node_bytes = layoutBytes(node_columns, node_capacity);
const leaf_class: u8 = PayloadSlabs.classFor(page_bytes) catch @compileError("page past the last slot class");
const node_class: u8 = PayloadSlabs.classFor(node_bytes) catch @compileError("node past the last slot class");

comptime {
    std.debug.assert(page_bytes == 4992 and node_bytes == 3040);
    std.debug.assert(@sizeOf(PageHeader) <= header_bytes and @sizeOf(NodeHeader) <= header_bytes);
    std.debug.assert(@sizeOf(EntityId) == 8 and @alignOf(u256) <= payload_slot_alignment);
    std.debug.assert(header_bytes % @alignOf(u256) == 0);
    std.debug.assert(page_capacity <= @bitSizeOf(u64) and node_capacity <= @bitSizeOf(u64));
    std.debug.assert(insert_range_alignment_items * @sizeOf(InsertEdit) % thread_shared_record_alignment == 0);
}

fn columnPtr(comptime T: type, bytes: []align(payload_slot_alignment) u8, comptime offset: usize, comptime capacity: usize) *[capacity]T {
    return @ptrCast(@alignCast(bytes[offset..][0 .. capacity * @sizeOf(T)]));
}

/// One stored page's header and columns, viewed in place in its pool slot.
pub const Page = struct {
    header: *PageHeader,
    keys: *[page_capacity]u256,
    a: *[page_capacity]EntityId,
    b: *[page_capacity]EntityId,
    a_row: *[page_capacity]u32,
    b_row: *[page_capacity]u32,
    normal_x: *[page_capacity]f32,
    normal_y: *[page_capacity]f32,
    penetration: *[page_capacity]f32,
    max_speed_sq: *[page_capacity]f32,
    rel_speed_sq: *[page_capacity]f32,
    emit: *[page_capacity]u8,

    fn of(bytes: []align(payload_slot_alignment) u8) Page {
        var view: Page = undefined;
        view.header = @ptrCast(@alignCast(bytes[0..@sizeOf(PageHeader)]));
        inline for (page_columns) |column| {
            @field(view, column[0]) = columnPtr(column[1], bytes, columnOffset(page_columns, column[0], page_capacity), page_capacity);
        }
        return view;
    }

    /// Slot `slot`'s pair as a contact, its stored rows widened (`writeInsert`'s inverse).
    pub fn contactAt(self: Page, slot: usize) CollisionContact {
        return .{
            .a = self.a[slot],
            .b = self.b[slot],
            .a_movement_index = self.a_row[slot],
            .b_movement_index = self.b_row[slot],
            .normal_x = self.normal_x[slot],
            .normal_y = self.normal_y[slot],
            .penetration = self.penetration[slot],
            .pre_response_max_speed_sq = self.max_speed_sq[slot],
            .pre_response_relative_speed_sq = self.rel_speed_sq[slot],
        };
    }
};

const Node = struct {
    header: *NodeHeader,
    first_key: *[node_capacity]u256,
    child: *[node_capacity]u32,
    start: *[node_capacity]u32,
    valid_start: *[node_capacity]u32,
    allowed_start: *[node_capacity]u32,

    fn of(bytes: []align(payload_slot_alignment) u8) Node {
        var view: Node = undefined;
        view.header = @ptrCast(@alignCast(bytes[0..@sizeOf(NodeHeader)]));
        inline for (node_columns) |column| {
            @field(view, column[0]) = columnPtr(column[1], bytes, columnOffset(node_columns, column[0], node_capacity), node_capacity);
        }
        return view;
    }

    // The prefix column of `kind`'s counts.
    fn starts(self: Node, kind: PairCount) *[node_capacity]u32 {
        return switch (kind) {
            .pairs => self.start,
            .valid => self.valid_start,
            .allowed => self.allowed_start,
        };
    }

    // The prefix columns in `Counts.values` order.
    fn prefixColumns(self: Node) [Counts.len]*[node_capacity]u32 {
        var columns: [Counts.len]*[node_capacity]u32 = undefined;
        for (std.enums.values(PairCount)) |kind| columns[Counts.Indexer.indexOf(kind)] = self.starts(kind);
        return columns;
    }

    // The pairs of `kind` under entry `entry`. Reads `kind`'s column and total alone: refresh
    // ranges write the valid and allowed columns of nodes other ranges' cursors read pairs
    // from.
    fn entryCount(self: Node, entry: usize, kind: PairCount) u32 {
        const column = self.starts(kind);
        const end = if (entry + 1 < self.header.count) column[entry + 1] else self.header.totals.getPtrConst(kind).*;
        return end - column[entry];
    }

    // The first entry holding a pair of `kind`; the node holds one.
    fn firstCounted(self: Node, kind: PairCount) u32 {
        var entry: u32 = 0;
        while (self.entryCount(entry, kind) == 0) entry += 1;
        return entry;
    }
};

// Copies `count` pairs, every column, from `source` at `from` to `dest` at `at`.
fn copyPairs(dest: Page, at: usize, source: Page, from: usize, count: usize) void {
    inline for (page_columns) |column| {
        @memcpy(@field(dest, column[0])[at..][0..count], @field(source, column[0])[from..][0..count]);
    }
}

// ---- Keys and edit records -------------------------------------------------------------

/// The bit a contact key's level starts at: the level is the key's top 16 bits.
pub const key_level_shift = 240;

/// The level of contact key `key`.
pub fn keyLevel(key: u256) u16 {
    return @truncate(key >> key_level_shift);
}

// The lowest key of `level`.
fn levelFirstKey(level: u16) u256 {
    return @as(u256, level) << key_level_shift;
}

/// One stored pair to insert, with its rows and emit bits current at the patch.
pub const InsertEdit = struct {
    key: u256,
    contact: CollisionContact,
    emit: u8,
};

// A page's place in its level tree: `nodes[h]` is its ancestor at height h + 1 and
// `entries[h]` the entry taken there; `nodes[height - 1]` is the level's root. `leaf` is
// `no_entry` on an empty level.
const TreePath = struct {
    level: u16 = 0,
    leaf: u32 = no_entry,
    nodes: [max_tree_height]u32 = @splat(no_entry),
    entries: [max_tree_height]u8 = @splat(0),
};

/// A page's place in its level: its tree path and the pairs of its level before it (0 on an
/// empty level).
pub const PageLocation = struct {
    path: TreePath,
    leaf_start: u32,
};

/// Stored slots `[lo, hi)` of the page at `page` to drop.
pub const DropPiece = struct {
    page: PageLocation,
    lo: u8,
    hi: u8,
};

/// One query range's edits, in range order. A patch's `insert_pages[i]` is the page
/// `inserts[i]`'s key falls in; a rebuild locates nothing and leaves it empty.
pub const EditSource = struct {
    inserts: []const InsertEdit = &.{},
    insert_pages: []const PageLocation = &.{},
    drops: []const DropPiece = &.{},
};

// Where a key falls: its page (the last whose first key is at or below it, else the
// level's first) and the page's length.
const Locate = struct {
    page: PageLocation,
    page_len: u32,
};

// One level's tree: its root (a page at height 0), its height, and its pairs of each count.
// An empty level has root `no_entry`.
const LevelTree = struct {
    root: u32 = no_entry,
    counts: Counts = .initFill(0),
    height: u8 = 0,
};

// A Fenwick tree over the levels' counts, one node per level id holding every count:
// `prefix(kind, level)` is the global ordinal of the level's first pair of `kind`.
// Hand-rolled: std has no Fenwick or order-statistics structure.
const LevelRank = struct {
    // Node i (1-based) at `sums[i - 1]` holds the counts of levels `[i - lowbit(i), i)`.
    sums: std.ArrayList(Counts) = .empty,

    fn lowbit(index: usize) usize {
        return index & (~index +% 1);
    }

    fn deinit(self: *LevelRank, allocator: std.mem.Allocator) void {
        self.sums.deinit(allocator);
    }

    // Adds `deltas` to `level`'s counts. O(log L).
    fn add(self: *LevelRank, level: usize, deltas: std.EnumArray(PairCount, i64)) void {
        var index = level + 1;
        while (index <= self.sums.items.len) : (index += lowbit(index)) {
            const sum = &self.sums.items[index - 1];
            for (std.enums.values(PairCount)) |kind| sum.set(kind, @intCast(@as(i64, sum.get(kind)) + deltas.get(kind)));
        }
    }

    // The pairs of `kind` on levels below `level`. O(log L).
    fn prefix(self: *const LevelRank, kind: PairCount, level: usize) u32 {
        std.debug.assert(level <= self.sums.items.len);
        var total: u32 = 0;
        var index = level;
        while (index > 0) : (index -= lowbit(index)) total += self.sums.items[index - 1].get(kind);
        return total;
    }

    const Found = struct { level: u16, local: u32 };

    // The level holding global ordinal `ordinal` of `kind` (below its total) and its ordinal
    // among the level's pairs of `kind`, by binary lifting: levels holding none are passed
    // over. O(log L).
    fn find(self: *const LevelRank, kind: PairCount, ordinal: u32) Found {
        const count = self.sums.items.len;
        std.debug.assert(count != 0);
        var position: usize = 0;
        var remaining = ordinal;
        var step = std.math.floorPowerOfTwo(usize, count);
        while (step != 0) : (step >>= 1) {
            const next = position + step;
            if (next <= count and self.sums.items[next - 1].get(kind) <= remaining) {
                position = next;
                remaining -= self.sums.items[next - 1].get(kind);
            }
        }
        std.debug.assert(position < count);
        return .{ .level = @intCast(position), .local = remaining };
    }

    // Appends an empty level within reserved capacity. O(log L).
    fn appendAssumeCapacity(self: *LevelRank) void {
        const index = self.sums.items.len + 1;
        var sum: Counts = undefined;
        for (std.enums.values(PairCount)) |kind| sum.set(kind, self.prefix(kind, index - 1) - self.prefix(kind, index - lowbit(index)));
        self.sums.appendAssumeCapacity(sum);
    }

    // Rebuilds the tree over `levels`' counts within reserved capacity. O(L).
    fn build(self: *LevelRank, levels: []const LevelTree) void {
        std.debug.assert(self.sums.capacity >= levels.len);
        self.sums.items.len = levels.len;
        for (self.sums.items, levels) |*sum, tree| sum.* = tree.counts;
        for (1..levels.len + 1) |index| {
            const parent = index + lowbit(index);
            if (parent > levels.len) continue;
            const into = &self.sums.items[parent - 1];
            for (std.enums.values(PairCount)) |kind| into.set(kind, into.get(kind) + self.sums.items[index - 1].get(kind));
        }
    }
};

// ---- Stages ---------------------------------------------------------------------------

// A patch or step stage of the store, each under its own tuner.
const TriggerStage = enum { insert_place, insert_sort, leaf, refresh };
// A rebuild's stages, each under its own rebuild tuner.
const TriggerRebuildStage = enum { insert_place, insert_sort, leaf };
/// The thread system and range controls the store's stages dispatch on.
pub const StoreThreads = StageThreads(StageControls);

const InsertSort = banded_sort.BandedSort(InsertEdit, insertKeyOf);

fn insertKeyOf(edit: InsertEdit) u256 {
    return edit.key;
}

// ---- Patch plan records ----------------------------------------------------------------

// A level a patch touches: its pre-patch tree, its edit counts, and its planned root.
const TouchedLevel = struct {
    level: u16,
    old: LevelTree,
    // The record of the unit under the virtual root (the old root, or an empty level's
    // virtual page), and of the virtual root itself.
    root_record: u32 = no_entry,
    virtual_root: u32,
    inserts: u32 = 0,
    dropped: u32 = 0,
    // Null: the level empties.
    new_root: ?Entry = null,
    new_height: u8 = 0,
    // The planned root's counts, read at install.
    new_counts: Counts = .initFill(0),
};

// A touched page or node, an empty level's virtual page (id `no_entry`, height 0), or a
// level's virtual root (id `no_entry`, one entry: the root). Sizes are pre-patch.
const Touched = struct {
    id: u32,
    level_record: u32,
    parent: u32 = no_entry,
    // Pairs of its level before it, and under it.
    start: u32,
    pairs: u32,
    // Its pairs (page) or entries (node).
    size: u32,
    // Page: dropped slots. Node: touched entries.
    mask: u64 = 0,
    inserts: u32 = 0,
    // Items the lower runs starting under it output (height ≥ 1).
    child_outputs: u32 = 0,
    run: u32 = no_entry,
    entry: u8 = 0,
    height: u8,
};

// A maximal sequence of adjacent touched units at one height, merged and re-split into `m`
// fresh units. A run with `units_lo == units_hi` is a growth run above a level's old root.
const Run = struct {
    level_record: u32,
    units_lo: u32,
    units_hi: u32,
    // Merged items: pairs (height 0) or entries.
    n: u32 = 0,
    m: u32 = 0,
    out_base: u32 = 0,
    seg_lo: u32 = 0,
    seg_hi: u32 = 0,
    // Height 0: its slice of the sorted inserts and its kept old pairs.
    ins_lo: u32 = 0,
    ins_count: u32 = 0,
    kept: u32 = 0,
    // A run of one entry above height 0 claims no node: it passes `through` up.
    through: ?Entry = null,
};

// A tree entry a plan names before its claims are reserved: an old page or node, or an
// output of a height.
// `value` is the old id or the output index; `height` is the entry's own height.
const Entry = struct {
    kind: enum { old, output },
    height: u8,
    value: u32,
};

const SegmentKind = enum(u8) { page, entries, outputs };

// A run's input in merged order. `page`: old page `id`'s slots `[0, hi)` less `mask`, kept
// pairs from position `pos`. `entries`: old node `id`'s entries `[lo, hi)`. `outputs`: the
// lower height's outputs `[lo, hi)`.
const Segment = struct {
    kind: SegmentKind,
    id: u32 = no_entry,
    lo: u32 = 0,
    hi: u32 = 0,
    pos: u32,
    mask: u64 = 0,

    fn items(self: Segment) u32 {
        return switch (self.kind) {
            .page => self.hi - @popCount(self.mask),
            .entries, .outputs => self.hi - self.lo,
        };
    }
};

const HeightPlan = struct {
    runs_lo: u32 = 0,
    runs_hi: u32 = 0,
    outputs: u32 = 0,
    // The node-class claim ordinal of its first output (height ≥ 1).
    claim_base: u32 = 0,
};

// A growth run owed at the next height: `run` output more than one unit at a level's top.
const Growth = struct {
    level_record: u32,
    run: u32,
};

// One output page or node as its parent's entry and the install read it: a page's written by
// its own leaf item, a node's by the merge on main.
const LevelOutput = struct {
    first_key: u256,
    id: u32,
    counts: Counts,
};

/// The node merge of a patch or rebuild, on main after the leaf join: the nodes it wrote and
/// its time.
pub const NodeMerge = struct {
    outputs: usize = 0,
    ns: u64 = 0,
};

/// A refresh's fold on main after its join: the range edges, split-node and higher-node
/// entries, and levels it visited, and its time.
pub const RefreshFold = struct {
    entries: usize = 0,
    ns: u64 = 0,
};

/// One world's stored trigger pairs. Its lifetime is the collision system's: a rebuild
/// resets it and `deinit` frees it. Not thread-safe: patches, rebuilds and refreshes run on
/// main and dispatch their own stages; readers (`cursorAt`, `emittedCursorAt`, `locateKey`,
/// `storedPiece`, `seek`) may run on workers while no patch, rebuild or refresh runs.
pub const TriggerStore = struct {
    /// Kept only with `runtime_perf_log.enabled`. Growth counts: pool slabs the pages and
    /// nodes grew by, level table growths, and patch plan scratch lists a patch grew (each
    /// list once per patch, on error too). Each patch or step stage's last batch shape
    /// (`last_batches`), the last patch's node merge (`last_node_merge`) and the last
    /// refresh's fold (`last_refresh_fold`), reset by every patch and rebuild, so after a
    /// rebuild the patch and step records hold none; each rebuild
    /// stage's (`last_rebuild_batches`) and the rebuild's node merge
    /// (`last_rebuild_node_merge`), reset by every rebuild.
    pub const Perf = if (runtime_perf_log.enabled) struct {
        page_grows: u64 = 0,
        level_grows: u64 = 0,
        scratch_grows: u64 = 0,
        last_batches: std.EnumArray(TriggerStage, BatchStats) = .initFill(.{}),
        last_node_merge: NodeMerge = .{},
        last_rebuild_batches: std.EnumArray(TriggerRebuildStage, BatchStats) = .initFill(.{}),
        last_rebuild_node_merge: NodeMerge = .{},
        last_refresh_fold: RefreshFold = .{},
    } else struct {};

    allocator: std.mem.Allocator,
    pool: PayloadSlabs = .{},
    /// By level id; length 1 + the highest level that has held pairs since the last rebuild.
    levels: std.ArrayList(LevelTree) = .empty,
    level_rank: LevelRank = .{},
    // Patch scratch kept zero outside a patch: 1 + the touched record of a level, page id or
    // node id. The page and node columns cover their class's `id_limit`.
    level_pending: std.ArrayList(u32) = .empty,
    leaf_pending: std.ArrayList(u32) = .empty,
    node_pending: std.ArrayList(u32) = .empty,
    /// Store-wide sums over every level: pairs, pairs whose rows resolve, and allowed pairs.
    pair_count: u32 = 0,
    valid_count: u32 = 0,
    allowed_count: u32 = 0,
    /// The allow epoch stored rows and emit bits are current at.
    refreshed_epoch: ?u64 = null,
    /// The collider revision the store was last patched or rebuilt to.
    seen_revision: u64 = 0,
    ready: bool = false,
    tuners: std.EnumArray(TriggerStage, AdaptiveWorkTuner) = .initFill(AdaptiveWorkTuner.init(.{})),
    rebuild_tuners: std.EnumArray(TriggerRebuildStage, AdaptiveWorkTuner) = .initFill(AdaptiveWorkTuner.init(rebuild_tuner_config)),
    perf: Perf = .{},
    page_growth_logged: bool = false,
    level_growth_logged: bool = false,
    scratch_growth_logged: bool = false,

    // Patch scratch, grow-only and kept warm.
    touched_levels: std.ArrayList(TouchedLevel) = .empty,
    touched: std.ArrayList(Touched) = .empty,
    level_order: std.ArrayList(u32) = .empty,
    // Touched records by height, in key order: each height's input order, then its runs'
    // units with absorbed neighbours.
    units: std.ArrayList(u32) = .empty,
    runs: std.ArrayList(Run) = .empty,
    segments: std.ArrayList(Segment) = .empty,
    growth: std.ArrayList(Growth) = .empty,
    next_growth: std.ArrayList(Growth) = .empty,
    heights: [max_tree_height + 1]HeightPlan = @splat(.{}),
    height_count: usize = 0,
    // By height, one per output in output order.
    level_outputs: [max_tree_height + 1]std.ArrayList(LevelOutput) = @splat(.empty),
    sorted_inserts: std.ArrayList(InsertEdit) = .empty,
    insert_staging: std.ArrayList(InsertEdit) = .empty,
    insert_segments: std.ArrayList([]const InsertEdit) = .empty,
    insert_segment_starts: std.ArrayList(usize) = .empty,
    band_offsets: SlotList(BandOffsets) = .empty,

    pub fn init(allocator: std.mem.Allocator) TriggerStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TriggerStore) void {
        const allocator = self.allocator;
        self.pool.deinit(allocator);
        self.levels.deinit(allocator);
        self.level_rank.deinit(allocator);
        self.level_pending.deinit(allocator);
        self.leaf_pending.deinit(allocator);
        self.node_pending.deinit(allocator);
        self.touched_levels.deinit(allocator);
        self.touched.deinit(allocator);
        self.level_order.deinit(allocator);
        self.units.deinit(allocator);
        self.runs.deinit(allocator);
        self.segments.deinit(allocator);
        self.growth.deinit(allocator);
        self.next_growth.deinit(allocator);
        for (&self.level_outputs) |*outputs| outputs.deinit(allocator);
        self.sorted_inserts.deinit(allocator);
        self.insert_staging.deinit(allocator);
        self.insert_segments.deinit(allocator);
        self.insert_segment_starts.deinit(allocator);
        self.band_offsets.deinit(allocator);
        self.* = .{ .allocator = allocator };
    }

    /// Page `id`'s view.
    pub fn page(self: *const TriggerStore, id: u32) Page {
        return Page.of(self.pool.bytesOf(.{ .class = leaf_class, .id = id }));
    }

    /// Page `id`'s key column alone, for readers that search keys and touch no other column.
    pub fn pageKeys(self: *const TriggerStore, id: u32) *const [page_capacity]u256 {
        return columnPtr(u256, self.pool.bytesOf(.{ .class = leaf_class, .id = id }), comptime columnOffset(page_columns, "keys", page_capacity), page_capacity);
    }

    fn node(self: *const TriggerStore, id: u32) Node {
        return Node.of(self.pool.bytesOf(.{ .class = node_class, .id = id }));
    }

    fn levelTree(self: *const TriggerStore, level: u16) LevelTree {
        return if (level < self.levels.items.len) self.levels.items[level] else .{};
    }

    /// The stored pairs of `kind`, over every level.
    pub fn countOf(self: *const TriggerStore, kind: PairCount) u32 {
        return switch (kind) {
            .pairs => self.pair_count,
            .valid => self.valid_count,
            .allowed => self.allowed_count,
        };
    }

    // The counts of the tree under `root` at `height`: its page's header, or its node's totals.
    fn subtreeCounts(self: *const TriggerStore, root: u32, height: usize) Counts {
        return if (height == 0) self.page(root).header.counts() else self.node(root).header.totals;
    }

    // ---- Readers (pure; safe on workers while no patch runs) ---------------------------

    /// The page `key` falls in. A level past the table end or empty locates its virtual
    /// page (`leaf = no_entry`, `leaf_start = 0`). O(H log F).
    pub fn locateKey(self: *const TriggerStore, key: u256) Locate {
        const level = keyLevel(key);
        const tree = self.levelTree(level);
        var located = Locate{ .page = .{ .path = .{ .level = level }, .leaf_start = 0 }, .page_len = 0 };
        if (tree.root == no_entry) return located;
        const path = &located.page.path;
        var id = tree.root;
        var height: usize = tree.height;
        located.page_len = tree.counts.get(.pairs);
        while (height > 0) {
            height -= 1;
            const at = self.node(id);
            const count = at.header.count;
            const entry = std.sort.upperBound(u256, at.first_key[0..count], key, orderU256) -| 1;
            path.nodes[height] = id;
            path.entries[height] = @intCast(entry);
            located.page.leaf_start += at.start[entry];
            if (height == 0) located.page_len = at.entryCount(entry, .pairs);
            id = at.child[entry];
        }
        path.leaf = id;
        return located;
    }

    /// The one-slot drop piece of stored key `key`, or null when no stored pair has it.
    /// O(H log F + log P).
    pub fn storedPiece(self: *const TriggerStore, key: u256) ?DropPiece {
        const located = self.locateKey(key);
        if (located.page.path.leaf == no_entry) return null;
        const keys = self.pageKeys(located.page.path.leaf)[0..located.page_len];
        const slot = std.sort.lowerBound(u256, keys, key, orderU256);
        if (slot == keys.len or keys[slot] != key) return null;
        // A page holds at most `page_capacity` pairs.
        return .{ .page = located.page, .lo = @intCast(slot), .hi = @intCast(slot + 1) };
    }

    /// A cursor on the first stored pair at or after `key`, over every level; invalid past
    /// the last pair, where its ordinal (`page_start + offset`) is `pair_count`. One descent
    /// from the key's own path; an empty level, or a key past its level's last pair, adds
    /// `cursorAt`'s Fenwick find and a second descent onto the next level holding pairs.
    /// O(log L + H log F).
    pub fn seek(self: *const TriggerStore, key: u256) Cursor {
        const level = keyLevel(key);
        if (level >= self.levels.items.len) return self.endCursor();
        const level_start = self.level_rank.prefix(.pairs, level);
        const located = self.locateKey(key);
        if (located.page.path.leaf == no_entry) {
            // An empty level: the next level holding pairs starts at this level's ordinal.
            if (level_start < self.pair_count) return self.cursorAt(level_start);
            return self.endCursor();
        }
        const keys = self.pageKeys(located.page.path.leaf)[0..located.page_len];
        var cursor = Cursor{
            .store = self,
            .path = located.page.path,
            .height = self.levels.items[level].height,
            .page_len = located.page_len,
            .leaf_start = located.page.leaf_start,
            .page_start = level_start + located.page.leaf_start,
            // A page holds at most `page_capacity` pairs.
            .offset = @intCast(std.sort.lowerBound(u256, keys, key, orderU256)),
        };
        // Past the page's last key: the next page's first pair, on this level or a later one.
        if (cursor.offset == cursor.page_len) cursor.nextPage();
        return cursor;
    }

    // The invalid cursor past the last stored pair.
    fn endCursor(self: *const TriggerStore) Cursor {
        return .{ .store = self, .path = .{}, .height = 0, .page_len = 0, .leaf_start = 0, .page_start = self.pair_count, .offset = 0 };
    }

    /// A cursor on stored pair `ordinal` (below `pair_count`), over every level in key
    /// order: a Fenwick find, then one descent. O(log L + H log F).
    pub fn cursorAt(self: *const TriggerStore, ordinal: u32) Cursor {
        std.debug.assert(ordinal < self.pair_count);
        const found = self.level_rank.find(.pairs, ordinal);
        const tree = self.levels.items[found.level];
        var cursor = Cursor{
            .store = self,
            .path = .{ .level = found.level },
            .height = tree.height,
            .page_len = tree.counts.get(.pairs),
            .leaf_start = 0,
            .page_start = ordinal - found.local,
            .offset = found.local,
        };
        var id = tree.root;
        var height: usize = tree.height;
        while (height > 0) {
            height -= 1;
            const at = self.node(id);
            const entry = std.sort.upperBound(u32, at.start[0..at.header.count], cursor.offset, orderU32) - 1;
            cursor.path.nodes[height] = id;
            cursor.path.entries[height] = @intCast(entry);
            cursor.offset -= at.start[entry];
            if (height == 0) cursor.page_len = at.entryCount(entry, .pairs);
            id = at.child[entry];
        }
        cursor.path.leaf = id;
        cursor.leaf_start = found.local - cursor.offset;
        cursor.page_start = ordinal - cursor.offset;
        std.debug.assert(cursor.offset < cursor.page_len);
        return cursor;
    }

    /// A cursor on the stored pair of ordinal `ordinal` among the pairs of `kind` (below
    /// `countOf(kind)`), over every level in key order: a Fenwick find on `kind`'s counts, one
    /// descent on `kind`'s prefixes, and one select in the page's mask. O(log L + H log F).
    pub fn emittedCursorAt(self: *const TriggerStore, kind: PairCount, ordinal: u32) EmittedCursor {
        std.debug.assert(ordinal < self.countOf(kind));
        const found = self.level_rank.find(kind, ordinal);
        const tree = self.levels.items[found.level];
        var cursor = EmittedCursor{ .store = self, .kind = kind, .path = .{ .level = found.level }, .height = tree.height, .rest = 0, .slot = 0 };
        var local = found.local;
        var id = tree.root;
        var height: usize = tree.height;
        while (height > 0) {
            height -= 1;
            const at = self.node(id);
            const column = at.starts(kind);
            // The last entry starting at or below `local`: entries holding none of `kind` share
            // their successor's start and are passed over.
            const entry = std.sort.upperBound(u32, column[0..at.header.count], local, orderU32) - 1;
            cursor.path.nodes[height] = id;
            cursor.path.entries[height] = @intCast(entry);
            local -= column[entry];
            id = at.child[entry];
        }
        cursor.path.leaf = id;
        const slots = self.page(id).header.slots(kind);
        cursor.slot = selectBit(slots, local);
        cursor.rest = slots & ~lowSlots(cursor.slot);
        return cursor;
    }

    // ---- Patch ------------------------------------------------------------------------

    /// Applies `edits` (each query range's inserts and drop pieces, in range order) and
    /// records `revision`. The drops are disjoint and name stored pairs; inserts are new
    /// keys located against this store. Allocates only before its first stored mutation:
    /// on error the store is unchanged and `seen_revision` is kept.
    pub fn patch(self: *TriggerStore, threads: StoreThreads, edits: []const EditSource, revision: u64) error{OutOfMemory}!void {
        errdefer self.discardPlan();
        if (comptime runtime_perf_log.enabled) {
            self.perf.last_batches = .initFill(.{});
            self.perf.last_node_merge = .{};
            self.perf.last_refresh_fold = .{};
        }
        const before = self.planScratchCapacities();
        defer self.countScratchGrowth(changedCapacities(&before, &self.planScratchCapacities()));
        try self.bucket(edits);
        try self.collectInsertSegments(edits);
        const sorted = try self.sortInserts(threads.stage(self.tuners.getPtr(.insert_place)), threads.stage(self.tuners.getPtr(.insert_sort)));
        if (comptime runtime_perf_log.enabled) {
            self.perf.last_batches.set(.insert_place, sorted.place);
            self.perf.last_batches.set(.insert_sort, sorted.sort);
        }
        try self.orderLevels();
        try self.orderTouchedPages();
        try self.planHeights();
        try self.reservePlan();
        const written = self.writeOutputs(threads.stage(self.tuners.getPtr(.leaf)));
        if (comptime runtime_perf_log.enabled) {
            self.perf.last_batches.set(.leaf, written.leaf);
            self.perf.last_node_merge = written.node_merge;
        }
        self.install(.patch);
        self.seen_revision = revision;
    }

    /// Replaces every stored pair with `inserts` (each query range's inserts, in range
    /// order; rows and emit bits current at `allow_epoch`) and records `revision`. Each stage
    /// dispatches under its own rebuild tuner and records into `Perf.last_rebuild_batches`,
    /// and the node merge into `Perf.last_rebuild_node_merge`. On error the store is empty
    /// and not ready.
    pub fn rebuild(self: *TriggerStore, threads: StoreThreads, inserts: []const EditSource, revision: u64, allow_epoch: u64) error{OutOfMemory}!void {
        errdefer {
            self.discardPlan();
            self.ready = false;
        }
        self.discardPlan();
        self.ready = false;
        if (comptime runtime_perf_log.enabled) {
            self.perf.last_batches = .initFill(.{});
            self.perf.last_node_merge = .{};
            self.perf.last_refresh_fold = .{};
            self.perf.last_rebuild_batches = .initFill(.{});
            self.perf.last_rebuild_node_merge = .{};
        }
        self.pool.resetClass(leaf_class);
        self.pool.resetClass(node_class);
        self.levels.clearRetainingCapacity();
        self.level_rank.sums.clearRetainingCapacity();
        self.pair_count = 0;
        self.valid_count = 0;
        self.allowed_count = 0;
        try self.collectInsertSegments(inserts);
        const sorted = try self.sortInserts(threads.stage(self.rebuild_tuners.getPtr(.insert_place)), threads.stage(self.rebuild_tuners.getPtr(.insert_sort)));
        if (comptime runtime_perf_log.enabled) {
            self.perf.last_rebuild_batches.set(.insert_place, sorted.place);
            self.perf.last_rebuild_batches.set(.insert_sort, sorted.sort);
        }
        try self.touchRebuildLevels();
        try self.planHeights();
        try self.reservePlan();
        const written = self.writeOutputs(threads.stage(self.rebuild_tuners.getPtr(.leaf)));
        if (comptime runtime_perf_log.enabled) {
            self.perf.last_rebuild_batches.set(.leaf, written.leaf);
            self.perf.last_rebuild_node_merge = written.node_merge;
        }
        self.install(.rebuild);
        self.seen_revision = revision;
        self.refreshed_epoch = allow_epoch;
        self.ready = true;
    }

    // Clears every pending entry and the plan scratch; the stored trees are untouched.
    fn discardPlan(self: *TriggerStore) void {
        for (self.touched.items) |record| {
            if (record.id == no_entry) continue;
            if (record.height == 0) self.leaf_pending.items[record.id] = 0 else self.node_pending.items[record.id] = 0;
        }
        for (self.touched_levels.items) |level| self.level_pending.items[level.level] = 0;
        self.clearScratch();
    }

    fn clearScratch(self: *TriggerStore) void {
        self.touched_levels.clearRetainingCapacity();
        self.touched.clearRetainingCapacity();
        self.level_order.clearRetainingCapacity();
        self.units.clearRetainingCapacity();
        self.runs.clearRetainingCapacity();
        self.segments.clearRetainingCapacity();
        self.growth.clearRetainingCapacity();
        self.next_growth.clearRetainingCapacity();
        self.sorted_inserts.clearRetainingCapacity();
        self.heights = @splat(.{});
        self.height_count = 0;
        for (&self.level_outputs) |*outputs| outputs.clearRetainingCapacity();
    }

    // ---- Bucket (main, O(1) per record) --------------------------------------------------

    fn bucket(self: *TriggerStore, edits: []const EditSource) error{OutOfMemory}!void {
        for (edits) |source| {
            std.debug.assert(source.inserts.len == source.insert_pages.len);
            for (source.drops) |piece| {
                std.debug.assert(piece.lo < piece.hi and piece.hi <= page_capacity);
                const record = try self.touchPage(piece.page);
                const bits = slotMask(piece.lo, piece.hi);
                const touched = &self.touched.items[record];
                std.debug.assert(touched.id != no_entry and piece.hi <= touched.size);
                // The drops of one patch are disjoint.
                std.debug.assert(touched.mask & bits == 0);
                touched.mask |= bits;
                self.touched_levels.items[touched.level_record].dropped += piece.hi - piece.lo;
            }
            for (source.inserts, source.insert_pages) |edit, page_at| {
                std.debug.assert(keyLevel(edit.key) == page_at.path.level);
                const record = try self.touchPage(page_at);
                const touched = &self.touched.items[record];
                touched.inserts += 1;
                self.touched_levels.items[touched.level_record].inserts += 1;
            }
        }
    }

    // The touched level record of `level`, created with its virtual root.
    fn touchLevel(self: *TriggerStore, level: u16) error{OutOfMemory}!u32 {
        if (level < self.level_pending.items.len and self.level_pending.items[level] != 0) return self.level_pending.items[level] - 1;
        if (level >= self.level_pending.items.len) {
            const missing = @as(usize, level) + 1 - self.level_pending.items.len;
            try self.level_pending.appendNTimes(self.allocator, 0, missing);
        }
        try self.touched_levels.ensureUnusedCapacity(self.allocator, 1);
        const level_record: u32 = @intCast(self.touched_levels.items.len);
        const old = self.levelTree(level);
        const virtual_root = try self.addRecord(.{
            .id = no_entry,
            .level_record = level_record,
            .start = 0,
            .pairs = old.counts.get(.pairs),
            .size = 1,
            .height = old.height + 1,
        });
        self.touched_levels.appendAssumeCapacity(.{ .level = level, .old = old, .virtual_root = virtual_root });
        self.level_pending.items[level] = level_record + 1;
        return level_record;
    }

    fn addRecord(self: *TriggerStore, record: Touched) error{OutOfMemory}!u32 {
        const index: u32 = @intCast(self.touched.items.len);
        try self.touched.append(self.allocator, record);
        return index;
    }

    // The touched record of the page at `location`, created with every untouched ancestor.
    fn touchPage(self: *TriggerStore, location: PageLocation) error{OutOfMemory}!u32 {
        const path = location.path;
        const level_record = try self.touchLevel(path.level);
        const level = &self.touched_levels.items[level_record];
        if (path.leaf == no_entry) {
            std.debug.assert(level.old.root == no_entry);
            if (level.root_record != no_entry) return level.root_record;
            const virtual_page = try self.addRecord(.{ .id = no_entry, .level_record = level_record, .start = 0, .pairs = 0, .size = 0, .height = 0 });
            self.linkChild(virtual_page, level.virtual_root, 0);
            self.touched_levels.items[level_record].root_record = virtual_page;
            return virtual_page;
        }
        if (self.leaf_pending.items[path.leaf] != 0) return self.leaf_pending.items[path.leaf] - 1;
        const height = level.old.height;
        const len = if (height == 0) level.old.counts.get(.pairs) else self.node(path.nodes[0]).entryCount(path.entries[0], .pairs);
        const record = try self.addRecord(.{ .id = path.leaf, .level_record = level_record, .start = location.leaf_start, .pairs = len, .size = len, .height = 0 });
        self.leaf_pending.items[path.leaf] = record + 1;
        // Link it and each new ancestor until one already touched.
        var child = record;
        var child_height: usize = 0;
        while (true) {
            if (child_height == height) {
                const virtual_root = self.touched_levels.items[level_record].virtual_root;
                self.linkChild(child, virtual_root, 0);
                self.touched_levels.items[level_record].root_record = child;
                return record;
            }
            const node_id = path.nodes[child_height];
            const entry = path.entries[child_height];
            if (self.node_pending.items[node_id] != 0) {
                self.linkChild(child, self.node_pending.items[node_id] - 1, entry);
                return record;
            }
            const at = self.node(node_id);
            const parent = try self.addRecord(.{
                .id = node_id,
                .level_record = level_record,
                .start = self.touched.items[child].start - at.start[entry],
                .pairs = at.header.totals.get(.pairs),
                .size = at.header.count,
                .height = @intCast(child_height + 1),
            });
            self.node_pending.items[node_id] = parent + 1;
            self.linkChild(child, parent, entry);
            child = parent;
            child_height += 1;
        }
    }

    fn linkChild(self: *TriggerStore, child: u32, parent: u32, entry: usize) void {
        self.touched.items[child].parent = parent;
        self.touched.items[child].entry = @intCast(entry);
        self.touched.items[parent].mask |= @as(u64, 1) << @intCast(entry);
    }

    // ---- Insert sort (workers) -----------------------------------------------------------

    fn collectInsertSegments(self: *TriggerStore, edits: []const EditSource) error{OutOfMemory}!void {
        self.insert_segments.clearRetainingCapacity();
        self.insert_segment_starts.clearRetainingCapacity();
        try self.insert_segments.ensureTotalCapacity(self.allocator, edits.len);
        try self.insert_segment_starts.ensureTotalCapacity(self.allocator, edits.len);
        var total: usize = 0;
        for (edits) |source| {
            self.insert_segments.appendAssumeCapacity(source.inserts);
            self.insert_segment_starts.appendAssumeCapacity(total);
            total += source.inserts.len;
        }
    }

    // The banded sort of every collected insert into `sorted_inserts`.
    fn sortInserts(self: *TriggerStore, place_dispatch: Dispatch, sort_dispatch: Dispatch) error{OutOfMemory}!banded_sort.SortBatches {
        var total: usize = 0;
        for (self.insert_segments.items) |segment| total += segment.len;
        if (total >= no_entry) return error.OutOfMemory;
        try self.sorted_inserts.ensureTotalCapacity(self.allocator, total);
        self.sorted_inserts.items.len = total;
        return InsertSort.sortSegments(
            self.allocator,
            place_dispatch,
            sort_dispatch,
            self.insert_segments.items,
            self.insert_segment_starts.items,
            insert_range_alignment_items,
            &self.insert_staging,
            &self.band_offsets,
            self.sorted_inserts.items,
        );
    }

    // ---- Plan (main; counts only) ----------------------------------------------------------

    // The touched levels in level-id order, so runs and inserts line up in key order.
    fn orderLevels(self: *TriggerStore) error{OutOfMemory}!void {
        const count = self.touched_levels.items.len;
        try self.level_order.ensureTotalCapacity(self.allocator, count);
        self.level_order.clearRetainingCapacity();
        for (0..count) |index| self.level_order.appendAssumeCapacity(@intCast(index));
        pdqSort(u32, self.level_order.items, self.touched_levels.items, levelRecordLess);
    }

    fn levelRecordLess(levels: []const TouchedLevel, lhs: u32, rhs: u32) bool {
        return levels[lhs].level < levels[rhs].level;
    }

    // The touched pages in key order: a walk of each touched level's touched subtree, in
    // entry order. O(touched records).
    fn orderTouchedPages(self: *TriggerStore) error{OutOfMemory}!void {
        const Frame = struct { record: u32, mask: u64 };
        for (self.level_order.items) |level_record| {
            var stack: [max_tree_height + 1]Frame = undefined;
            const virtual_root = self.touched_levels.items[level_record].virtual_root;
            stack[0] = .{ .record = virtual_root, .mask = self.touched.items[virtual_root].mask };
            var depth: usize = 1;
            while (depth > 0) {
                const top = &stack[depth - 1];
                if (top.mask == 0) {
                    depth -= 1;
                    continue;
                }
                const entry = @ctz(top.mask);
                top.mask &= top.mask - 1;
                const child = self.childRecord(top.record, entry);
                const child_record = self.touched.items[child];
                if (child_record.height == 0) {
                    try self.units.append(self.allocator, child);
                } else {
                    stack[depth] = .{ .record = child, .mask = child_record.mask };
                    depth += 1;
                }
            }
        }
    }

    // The touched record of touched node `record`'s entry `entry`.
    fn childRecord(self: *const TriggerStore, record: u32, entry: usize) u32 {
        const parent = self.touched.items[record];
        if (parent.id == no_entry) {
            std.debug.assert(entry == 0);
            return self.touched_levels.items[parent.level_record].root_record;
        }
        const child_id = self.node(parent.id).child[entry];
        const pending = if (parent.height == 1) self.leaf_pending.items[child_id] else self.node_pending.items[child_id];
        std.debug.assert(pending != 0);
        return pending - 1;
    }

    // A rebuild's touched records: per level of the sorted inserts, a virtual root over a
    // virtual page receiving every insert of the level. O(L_p log I).
    fn touchRebuildLevels(self: *TriggerStore) error{OutOfMemory}!void {
        const inserts = self.sorted_inserts.items;
        var at: usize = 0;
        while (at < inserts.len) {
            const level = keyLevel(inserts[at].key);
            const end = if (level == std.math.maxInt(u16)) inserts.len else at + std.sort.lowerBound(InsertEdit, inserts[at..], levelFirstKey(level + 1), orderInsertKey);
            const level_record = try self.touchLevel(level);
            const virtual_page = try self.addRecord(.{
                .id = no_entry,
                .level_record = level_record,
                .start = 0,
                .pairs = 0,
                .size = 0,
                .inserts = @intCast(end - at),
                .height = 0,
            });
            const touched_level = &self.touched_levels.items[level_record];
            touched_level.inserts = @intCast(end - at);
            touched_level.root_record = virtual_page;
            self.linkChild(virtual_page, touched_level.virtual_root, 0);
            try self.units.append(self.allocator, virtual_page);
            try self.level_order.append(self.allocator, level_record);
            at = end;
        }
    }

    // Plans every height bottom-up. `units` starts with the touched pages in key order;
    // each height appends its final unit order, then its parents as the next height's order.
    fn planHeights(self: *TriggerStore) error{OutOfMemory}!void {
        var total: i64 = self.pair_count;
        for (self.touched_levels.items) |level| total += @as(i64, level.inserts) - level.dropped;
        if (total >= no_entry) return error.OutOfMemory;
        var order_lo: usize = 0;
        var order_hi = self.units.items.len;
        var insert_cursor: u32 = 0;
        var height: usize = 0;
        while (order_lo < order_hi or self.growth.items.len != 0) : (height += 1) {
            // A level tree is at most 6 high (u32 pairs), so its virtual root's height fits.
            std.debug.assert(height <= max_tree_height);
            const runs_lo: u32 = @intCast(self.runs.items.len);
            const final_lo = self.units.items.len;
            try self.formRuns(height, order_lo, order_hi);
            for (self.growth.items) |owed| {
                try self.runs.append(self.allocator, .{ .level_record = owed.level_record, .units_lo = 0, .units_hi = 0 });
            }
            const runs_hi: u32 = @intCast(self.runs.items.len);
            const plan = &self.heights[height];
            plan.runs_lo = runs_lo;
            plan.runs_hi = runs_hi;
            if (height == 1) plan.claim_base = 0 else if (height > 1) plan.claim_base = self.heights[height - 1].claim_base + self.heights[height - 1].outputs;
            self.height_count = height + 1;
            self.next_growth.clearRetainingCapacity();
            var growth_index: usize = 0;
            for (runs_lo..runs_hi) |run_index| {
                const run = &self.runs.items[run_index];
                const lower_run: ?u32 = if (run.units_lo == run.units_hi) blk: {
                    defer growth_index += 1;
                    break :blk self.growth.items[growth_index].run;
                } else null;
                try self.planRun(height, @intCast(run_index), lower_run, &insert_cursor);
            }
            std.mem.swap(std.ArrayList(Growth), &self.growth, &self.next_growth);
            // The next height's order: each final unit's parent, once each.
            const next_lo = self.units.items.len;
            const final_hi = next_lo;
            for (final_lo..final_hi) |index| {
                const parent = self.touched.items[self.units.items[index]].parent;
                if (parent == no_entry) continue;
                if (self.units.items.len > next_lo and self.units.items[self.units.items.len - 1] == parent) continue;
                try self.units.append(self.allocator, parent);
            }
            order_lo = next_lo;
            order_hi = self.units.items.len;
        }
        std.debug.assert(insert_cursor == self.sorted_inserts.items.len);
    }

    // Splits `units[order_lo..order_hi]` (height `height`, key order) into maximal adjacent
    // runs. A run of one output under the fill bound absorbs its untouched neighbour in key
    // order (the right one, else the left), which may join it to the next or previous run.
    fn formRuns(self: *TriggerStore, height: usize, order_lo: usize, order_hi: usize) error{OutOfMemory}!void {
        const fill_min = if (height == 0) page_min else node_min;
        const runs_lo = self.runs.items.len;
        var index = order_lo;
        while (index < order_hi) {
            const first = self.units.items[index];
            var run = Run{ .level_record = self.touched.items[first].level_record, .units_lo = @intCast(self.units.items.len), .units_hi = 0 };
            var items: u32 = 0;
            var last = first;
            try self.units.append(self.allocator, first);
            items += self.unitItems(first, height);
            index += 1;
            while (index < order_hi and self.adjacent(last, self.units.items[index])) : (index += 1) {
                last = self.units.items[index];
                try self.units.append(self.allocator, last);
                items += self.unitItems(last, height);
            }
            var merged = false;
            if (items > 0 and items < fill_min) {
                if (try self.touchNeighbour(last, height, .right)) |right| {
                    try self.units.append(self.allocator, right);
                    last = right;
                    while (index < order_hi and self.adjacent(last, self.units.items[index])) : (index += 1) {
                        last = self.units.items[index];
                        try self.units.append(self.allocator, last);
                    }
                } else if (try self.touchNeighbour(first, height, .left)) |left| {
                    try self.units.insert(self.allocator, run.units_lo, left);
                    if (self.runs.items.len > runs_lo) {
                        const previous = &self.runs.items[self.runs.items.len - 1];
                        if (self.adjacent(self.units.items[previous.units_hi - 1], left)) {
                            previous.units_hi = @intCast(self.units.items.len);
                            merged = true;
                        }
                    }
                }
            }
            if (merged) continue;
            run.units_hi = @intCast(self.units.items.len);
            try self.runs.append(self.allocator, run);
        }
    }

    // Unit `record`'s items after the patch: pairs (height 0) or entries.
    fn unitItems(self: *const TriggerStore, record: u32, height: usize) u32 {
        const unit = self.touched.items[record];
        std.debug.assert(unit.height == height);
        const kept = unit.size - @popCount(unit.mask);
        return kept + if (height == 0) unit.inserts else unit.child_outputs;
    }

    // True when `right` directly follows `left` in their level's sequence at their height.
    fn adjacent(self: *const TriggerStore, left: u32, right: u32) bool {
        const lhs = self.touched.items[left];
        const rhs = self.touched.items[right];
        return lhs.level_record == rhs.level_record and lhs.start + lhs.pairs == rhs.start;
    }

    const Side = enum { left, right };

    // The untouched unit at `record`'s height beside it in key order, touched with every
    // untouched ancestor below the nearest common one; null at the level's edge. O(H).
    fn touchNeighbour(self: *TriggerStore, record: u32, height: usize, side: Side) error{OutOfMemory}!?u32 {
        var child = record;
        while (true) {
            const parent = self.touched.items[child].parent;
            if (parent == no_entry or self.touched.items[parent].id == no_entry) return null;
            const entry: usize = self.touched.items[child].entry;
            const size = self.touched.items[parent].size;
            const sibling: ?usize = switch (side) {
                .right => if (entry + 1 < size) entry + 1 else null,
                .left => if (entry > 0) entry - 1 else null,
            };
            if (sibling) |sibling_entry| return try self.touchDescent(parent, sibling_entry, height, side);
            child = parent;
        }
    }

    // Touches `parent`'s entry `entry` and its edge descendants (first on the right side,
    // last on the left) down to `height`; returns the unit at `height`, which was untouched.
    fn touchDescent(self: *TriggerStore, parent_record: u32, parent_entry: usize, height: usize, side: Side) error{OutOfMemory}!u32 {
        var parent = parent_record;
        var entry = parent_entry;
        while (true) {
            const above = self.touched.items[parent];
            const at = self.node(above.id);
            const child_id = at.child[entry];
            const child_height: usize = above.height - 1;
            const start = above.start + at.start[entry];
            const pending = if (child_height == 0) self.leaf_pending.items[child_id] else self.node_pending.items[child_id];
            if (pending != 0) {
                // A touched ancestor of the neighbour: its own parent link is in place.
                std.debug.assert(child_height > height);
                parent = pending - 1;
            } else {
                const pairs = at.entryCount(entry, .pairs);
                const size = if (child_height == 0) pairs else self.node(child_id).header.count;
                const record = try self.addRecord(.{
                    .id = child_id,
                    .level_record = above.level_record,
                    .start = start,
                    .pairs = pairs,
                    .size = size,
                    .height = @intCast(child_height),
                });
                if (child_height == 0) self.leaf_pending.items[child_id] = record + 1 else self.node_pending.items[child_id] = record + 1;
                self.linkChild(record, parent, entry);
                if (child_height == height) return record;
                parent = record;
            }
            const below = self.touched.items[parent];
            entry = switch (side) {
                .right => 0,
                .left => below.size - 1,
            };
        }
    }

    // Plans run `run_index` at `height`: its segments, merged count, outputs and claims. A
    // growth run (no units) re-splits `lower_run`'s outputs.
    fn planRun(self: *TriggerStore, height: usize, run_index: u32, lower_run: ?u32, insert_cursor: *u32) error{OutOfMemory}!void {
        const seg_lo: u32 = @intCast(self.segments.items.len);
        var items: u32 = 0;
        var through: ?Entry = null;
        if (lower_run) |lower| {
            const below = self.runs.items[lower];
            try self.segments.append(self.allocator, .{ .kind = .outputs, .lo = below.out_base, .hi = below.out_base + below.m, .pos = 0 });
            items = below.m;
        } else if (height == 0) {
            const run = self.runs.items[run_index];
            var inserts: u32 = 0;
            for (self.units.items[run.units_lo..run.units_hi]) |record| {
                const unit = self.touched.items[record];
                inserts += unit.inserts;
                if (unit.id == no_entry) continue;
                try self.segments.append(self.allocator, .{ .kind = .page, .id = unit.id, .hi = unit.size, .pos = items, .mask = unit.mask });
                items += unit.size - @popCount(unit.mask);
            }
            const kept = items;
            self.runs.items[run_index].kept = kept;
            self.runs.items[run_index].ins_lo = insert_cursor.*;
            self.runs.items[run_index].ins_count = inserts;
            insert_cursor.* += inserts;
            items += inserts;
        } else {
            const run = self.runs.items[run_index];
            var last_lower: u32 = no_entry;
            var passed_through = false;
            for (self.units.items[run.units_lo..run.units_hi]) |record| {
                const unit = self.touched.items[record];
                var entry: u32 = 0;
                while (entry < unit.size) {
                    const rest = unit.mask >> @intCast(entry);
                    if (rest & 1 != 0) {
                        // A span of touched entries: one lower run, or the tail of one.
                        const span_end = entry + @ctz(~rest);
                        const lower = self.touched.items[self.childRecord(record, entry)].run;
                        // Adjacent touched units are always one run.
                        std.debug.assert(self.touched.items[self.childRecord(record, span_end - 1)].run == lower);
                        if (lower != last_lower) {
                            last_lower = lower;
                            const below = self.runs.items[lower];
                            if (below.through) |passed| {
                                through = passed;
                                passed_through = true;
                                items += 1;
                            } else if (below.m != 0) {
                                through = .{ .kind = .output, .height = @intCast(height - 1), .value = below.out_base };
                                try self.segments.append(self.allocator, .{ .kind = .outputs, .lo = below.out_base, .hi = below.out_base + below.m, .pos = items });
                                items += below.m;
                            }
                        }
                        entry = span_end;
                    } else {
                        const span_end = if (rest == 0) unit.size else @min(unit.size, entry + @ctz(rest));
                        through = .{ .kind = .old, .height = @intCast(height - 1), .value = self.node(unit.id).child[entry] };
                        try self.segments.append(self.allocator, .{ .kind = .entries, .id = unit.id, .lo = entry, .hi = span_end, .pos = items });
                        items += span_end - entry;
                        entry = span_end;
                    }
                }
            }
            // A passed-through lower run covers its whole level, so it is this run's only
            // entry and needs no segment.
            std.debug.assert(!passed_through or items == 1);
        }
        const run = &self.runs.items[run_index];
        run.n = items;
        run.seg_lo = seg_lo;
        run.seg_hi = @intCast(self.segments.items.len);
        const plan = &self.heights[height];
        run.out_base = plan.outputs;
        if (height > 0 and items == 1) {
            // One entry: no node; the entry passes through to the level's top.
            std.debug.assert(through != null);
            run.through = through;
        } else {
            const capacity: u32 = if (height == 0) page_capacity else node_capacity;
            run.m = (items + capacity - 1) / capacity;
            plan.outputs += run.m;
        }
        const out_items: u32 = if (run.through != null) 1 else run.m;
        if (run.units_lo != run.units_hi) {
            for (self.units.items[run.units_lo..run.units_hi]) |record| self.touched.items[record].run = run_index;
            const first_parent = self.touched.items[self.units.items[run.units_lo]].parent;
            if (first_parent != no_entry) self.touched.items[first_parent].child_outputs += out_items;
        }
        // A level's top: its virtual root's run, or a growth run above it.
        const top = run.units_lo == run.units_hi or self.touched.items[self.units.items[run.units_lo]].parent == no_entry;
        if (!top) return;
        const level = &self.touched_levels.items[run.level_record];
        if (items == 0) {
            level.new_root = null;
            level.new_height = 0;
        } else if (run.through) |passed| {
            level.new_root = passed;
            level.new_height = passed.height;
        } else if (run.m == 1) {
            level.new_root = .{ .kind = .output, .height = @intCast(height), .value = run.out_base };
            level.new_height = @intCast(height);
        } else {
            try self.next_growth.append(self.allocator, .{ .level_record = run.level_record, .run = run_index });
        }
    }

    // The id output `output` of `height` claims.
    fn outputId(self: *const TriggerStore, height: usize, output: u32) u32 {
        if (height == 0) return self.pool.claimedId(leaf_class, output);
        return self.pool.claimedId(node_class, self.heights[height].claim_base + output);
    }

    fn entryId(self: *const TriggerStore, entry: Entry) u32 {
        return switch (entry.kind) {
            .old => entry.value,
            .output => self.level_outputs[entry.height].items[entry.value].id,
        };
    }

    fn nodeOutputs(self: *const TriggerStore) u32 {
        if (self.height_count < 2) return 0;
        const top = self.heights[self.height_count - 1];
        return top.claim_base + top.outputs;
    }

    // Every allocation the write and install need: slot claims, pending coverage, the
    // outputs' records, and the level table and rank for levels past its end.
    fn reservePlan(self: *TriggerStore) error{OutOfMemory}!void {
        var slabs_before = self.pool.slab_count;
        try self.pool.reserve(self.allocator, leaf_class, self.heights[0].outputs);
        self.countPageGrowth(self.pool.slab_count - slabs_before);
        slabs_before = self.pool.slab_count;
        try self.pool.reserve(self.allocator, node_class, self.nodeOutputs());
        self.countPageGrowth(self.pool.slab_count - slabs_before);
        try coverPending(self.allocator, &self.leaf_pending, self.pool.classes[leaf_class].claims.id_limit);
        try coverPending(self.allocator, &self.node_pending, self.pool.classes[node_class].claims.id_limit);
        for (self.level_outputs[0..self.height_count], self.heights[0..self.height_count]) |*outputs, plan| {
            try outputs.ensureTotalCapacity(self.allocator, plan.outputs);
            outputs.items.len = plan.outputs;
        }
        var level_end: usize = 0;
        for (self.touched_levels.items) |level| level_end = @max(level_end, @as(usize, level.level) + 1);
        const table_capacity = self.levels.capacity;
        try self.levels.ensureTotalCapacity(self.allocator, level_end);
        try self.level_rank.sums.ensureTotalCapacity(self.allocator, level_end);
        if (self.levels.capacity != table_capacity) self.countLevelGrowth();
    }

    fn coverPending(allocator: std.mem.Allocator, pending: *std.ArrayList(u32), limit: u32) error{OutOfMemory}!void {
        if (pending.items.len >= limit) return;
        try pending.appendNTimes(allocator, 0, limit - pending.items.len);
    }

    fn countPageGrowth(self: *TriggerStore, slabs: usize) void {
        if (slabs == 0) return;
        if (comptime runtime_perf_log.enabled) self.perf.page_grows += slabs;
        if (self.page_growth_logged) return;
        self.page_growth_logged = true;
        if (comptime logging.enabled(.info)) logging.game.info("stored trigger pages grew", .{});
    }

    fn countLevelGrowth(self: *TriggerStore) void {
        if (comptime runtime_perf_log.enabled) self.perf.level_grows += 1;
        if (self.level_growth_logged) return;
        self.level_growth_logged = true;
        if (comptime logging.enabled(.info)) logging.game.info("stored trigger level table grew", .{});
    }

    fn countScratchGrowth(self: *TriggerStore, lists: usize) void {
        if (lists == 0) return;
        if (comptime runtime_perf_log.enabled) self.perf.scratch_grows += lists;
        if (self.scratch_growth_logged) return;
        self.scratch_growth_logged = true;
        if (comptime logging.enabled(.info)) logging.game.info("stored trigger patch scratch grew", .{});
    }

    // The plan scratch lists besides `level_outputs`.
    const plan_scratch_lists = 16;

    // The capacities of every plan scratch list a patch reserves, whose growth counts as
    // scratch growth.
    fn planScratchCapacities(self: *const TriggerStore) [plan_scratch_lists + max_tree_height + 1]usize {
        const lists = [plan_scratch_lists]usize{
            self.level_pending.capacity,  self.leaf_pending.capacity,    self.node_pending.capacity,
            self.touched_levels.capacity, self.touched.capacity,         self.level_order.capacity,
            self.units.capacity,          self.runs.capacity,            self.segments.capacity,
            self.growth.capacity,         self.next_growth.capacity,     self.sorted_inserts.capacity,
            self.insert_staging.capacity, self.insert_segments.capacity, self.insert_segment_starts.capacity,
            self.band_offsets.capacity,
        };
        var outputs: [max_tree_height + 1]usize = undefined;
        for (&outputs, &self.level_outputs) |*capacity, list| capacity.* = list.capacity;
        return lists ++ outputs;
    }

    // ---- Write (workers) and install (main) ----------------------------------------------

    // The leaf stage's batch and the node merge's record, kept only with
    // `runtime_perf_log.enabled`.
    const WriteRecords = if (runtime_perf_log.enabled) struct {
        leaf: BatchStats,
        node_merge: NodeMerge,
    } else struct {};

    // The leaf stage writes the fresh pages, then main merges the nodes.
    fn writeOutputs(self: *TriggerStore, leaf_dispatch: Dispatch) WriteRecords {
        const pages = self.heights[0].outputs;
        const leaf_stage = if (pages == 0) null else leaf_dispatch;
        const leaf_shape = StageShape.select(leaf_stage, pages, rewrite_range_alignment_items);
        var leaf_job = LeafJob{
            .store = self,
            .runs = self.runs.items[self.heights[0].runs_lo..self.heights[0].runs_hi],
            .outputs = self.level_outputs[0].items,
            .range_count = leaf_shape.range_count,
        };
        const leaf_batch = runShaped(leaf_stage, leaf_shape, pages, rewrite_range_alignment_items, &leaf_job, leafJob);
        const timer = StageTimer.begin();
        self.mergeNodes();
        if (comptime !runtime_perf_log.enabled) return .{};
        return .{ .leaf = leaf_batch, .node_merge = .{ .outputs = self.nodeOutputs(), .ns = timer.lap() } };
    }

    // Writes every output node, height by height and each height's runs in output order: an
    // ordered merge on main, O(1) per entry, each lower output or kept old entry becoming one
    // entry of its parent. A run's outputs take its merged entries in order, so one segment
    // cursor advances through the run.
    fn mergeNodes(self: *TriggerStore) void {
        if (self.height_count < 2) return;
        for (1..self.height_count) |height| {
            const plan = self.heights[height];
            const children = self.level_outputs[height - 1].items;
            const outputs = self.level_outputs[height].items;
            for (self.runs.items[plan.runs_lo..plan.runs_hi]) |run| {
                var segments = SegmentCursor{ .segments = self.segments.items[run.seg_lo..run.seg_hi] };
                for (0..run.m) |index| {
                    const begin: u32 = @intCast(@as(u64, index) * run.n / run.m);
                    const end: u32 = @intCast(@as(u64, index + 1) * run.n / run.m);
                    const output = run.out_base + @as(u32, @intCast(index));
                    outputs[output] = writeNode(self, self.outputId(height, output), children, &segments, end - begin);
                }
                std.debug.assert(run.m == 0 or segments.index == segments.segments.len);
            }
        }
    }

    const InstallMode = enum { patch, rebuild };

    // Commits claims and releases, the touched levels' entries, counts and ranks, and the
    // sums. Allocates nothing.
    fn install(self: *TriggerStore, mode: InstallMode) void {
        for (self.touched_levels.items) |*level| {
            const root = level.new_root orelse continue;
            level.new_counts = switch (root.kind) {
                .output => self.level_outputs[root.height].items[root.value].counts,
                .old => self.subtreeCounts(root.value, root.height),
            };
            level.new_root = .{ .kind = .old, .height = root.height, .value = self.entryId(root) };
        }
        self.pool.commitClaims(leaf_class, self.heights[0].outputs);
        self.pool.commitClaims(node_class, self.nodeOutputs());
        var page_releases: usize = 0;
        var node_releases: usize = 0;
        for (self.touched.items) |record| {
            if (record.id == no_entry) continue;
            if (record.height == 0) {
                self.pool.releaseAt(.{ .class = leaf_class, .id = record.id }, page_releases);
                page_releases += 1;
                self.leaf_pending.items[record.id] = 0;
            } else {
                self.pool.releaseAt(.{ .class = node_class, .id = record.id }, node_releases);
                node_releases += 1;
                self.node_pending.items[record.id] = 0;
            }
        }
        self.pool.commitReleases(leaf_class, page_releases);
        self.pool.commitReleases(node_class, node_releases);
        var deltas = std.EnumArray(PairCount, i64).initFill(0);
        for (self.level_order.items) |level_record| {
            const level = self.touched_levels.items[level_record];
            while (self.levels.items.len <= level.level) {
                self.levels.appendAssumeCapacity(.{});
                if (mode == .patch) self.level_rank.appendAssumeCapacity();
            }
            std.debug.assert(level.new_counts.get(.pairs) == @as(i64, level.old.counts.get(.pairs)) + level.inserts - level.dropped);
            var level_deltas: std.EnumArray(PairCount, i64) = undefined;
            for (std.enums.values(PairCount)) |kind| {
                level_deltas.set(kind, @as(i64, level.new_counts.get(kind)) - level.old.counts.get(kind));
                deltas.set(kind, deltas.get(kind) + level_deltas.get(kind));
            }
            self.levels.items[level.level] = .{
                .root = if (level.new_root) |root| root.value else no_entry,
                .height = level.new_height,
                .counts = level.new_counts,
            };
            if (mode == .patch) self.level_rank.add(level.level, level_deltas);
            self.level_pending.items[level.level] = 0;
        }
        if (mode == .rebuild) self.level_rank.build(self.levels.items);
        self.pair_count = @intCast(@as(i64, self.pair_count) + deltas.get(.pairs));
        self.valid_count = @intCast(@as(i64, self.valid_count) + deltas.get(.valid));
        self.allowed_count = @intCast(@as(i64, self.allowed_count) + deltas.get(.allowed));
        self.clearScratch();
    }

    // ---- Refresh (workers) ---------------------------------------------------------------

    /// Re-resolves every stored pair's rows and emit bits when `data`'s allow epoch moved
    /// past `refreshed_epoch`; true when it ran. Ranges own the pages that start in them and
    /// rewrite their masks. A range holding every page of a height-1 node writes its valid and
    /// allowed prefixes and totals; a node split at a range edge gets each page's raw counts,
    /// which main turns into prefixes before folding the nodes above, the level counts and the
    /// rank. Never allocates.
    pub fn refresh(self: *TriggerStore, threads: StoreThreads, data: *const DataSystem) bool {
        const epoch = data.collision_allow_epoch;
        if (self.pair_count == 0 or (self.refreshed_epoch != null and self.refreshed_epoch.? == epoch)) return false;
        const dispatch = threads.stage(self.tuners.getPtr(.refresh));
        const shape = StageShape.select(dispatch, self.pair_count, refresh_range_alignment_items);
        var job = RefreshJob{
            .store = self,
            .data = data,
            .items_per_range = shape.items_per_range,
            .range_count = shape.range_count,
        };
        const batch = runShaped(dispatch, shape, self.pair_count, refresh_range_alignment_items, &job, refreshJob);
        const timer = StageTimer.begin();
        const entries = self.foldRefreshed(shape.items_per_range, shape.range_count);
        if (comptime runtime_perf_log.enabled) {
            self.perf.last_batches.set(.refresh, batch);
            self.perf.last_refresh_fold = .{ .entries = entries, .ns = timer.lap() };
        }
        self.refreshed_epoch = epoch;
        return true;
    }

    // After a refresh's join, on main: each height-1 node split at a range edge turns its
    // pages' raw counts into prefixes and totals, each node above height 1 sums its children's
    // totals, then the level counts, the rank and the store sums follow. O(R (log L + H log F
    // + F) + N1 + L), O(1) per entry. Returns the entries it visited (counted only with
    // `runtime_perf_log.enabled`).
    fn foldRefreshed(self: *TriggerStore, items_per_range: usize, range_count: usize) usize {
        var entries: usize = 0;
        // The nodes split at range edges, in order: a node an edge splits holds the first page
        // starting at or past that edge at an entry past its first.
        var last_split: u32 = no_entry;
        for (1..range_count) |range_index| {
            var cursor = self.cursorAt(@intCast(range_index * items_per_range));
            if (cursor.offset != 0) cursor.nextPage();
            if (!cursor.valid() or cursor.height == 0 or cursor.path.entries[0] == 0) continue;
            const split = cursor.path.nodes[0];
            if (split == last_split) continue;
            last_split = split;
            const at = self.node(split);
            var valid: u32 = 0;
            var allowed: u32 = 0;
            for (at.valid_start[0..at.header.count], at.allowed_start[0..at.header.count]) |*valid_start, *allowed_start| {
                const page_valid = valid_start.*;
                const page_allowed = allowed_start.*;
                valid_start.* = valid;
                allowed_start.* = allowed;
                valid += page_valid;
                allowed += page_allowed;
            }
            at.header.totals.set(.valid, valid);
            at.header.totals.set(.allowed, allowed);
            if (comptime runtime_perf_log.enabled) entries += at.header.count;
        }
        var valid: u32 = 0;
        var allowed: u32 = 0;
        for (self.levels.items) |*tree| {
            if (tree.root == no_entry) continue;
            if (tree.height >= 2) {
                const folded = self.foldNode(tree.root, tree.height);
                if (comptime runtime_perf_log.enabled) entries += folded;
            }
            const counts = self.subtreeCounts(tree.root, tree.height);
            std.debug.assert(counts.get(.pairs) == tree.counts.get(.pairs));
            tree.counts = counts;
            valid += counts.get(.valid);
            allowed += counts.get(.allowed);
        }
        self.level_rank.build(self.levels.items);
        self.valid_count = valid;
        self.allowed_count = allowed;
        if (comptime runtime_perf_log.enabled) entries += range_count + self.levels.items.len;
        return entries;
    }

    // Node `id` at `height` (at least 2) takes its children's valid and allowed totals, each
    // child above height 1 folded first, into its prefixes and totals. Returns the entries it
    // and its folded children hold (counted only with `runtime_perf_log.enabled`).
    fn foldNode(self: *TriggerStore, id: u32, height: usize) usize {
        const at = self.node(id);
        var entries: usize = if (comptime runtime_perf_log.enabled) at.header.count else 0;
        var valid: u32 = 0;
        var allowed: u32 = 0;
        for (at.child[0..at.header.count], at.valid_start[0..at.header.count], at.allowed_start[0..at.header.count]) |child, *valid_start, *allowed_start| {
            if (height > 2) {
                const folded = self.foldNode(child, height - 1);
                if (comptime runtime_perf_log.enabled) entries += folded;
            }
            const totals = self.node(child).header.totals;
            valid_start.* = valid;
            allowed_start.* = allowed;
            valid += totals.get(.valid);
            allowed += totals.get(.allowed);
        }
        at.header.totals.set(.valid, valid);
        at.header.totals.set(.allowed, allowed);
        return entries;
    }
};

/// A position in the stored order, over every level: unit stride within a page, one path
/// step per page, and a `cursorAt` at a level's end. Reads no page header, so a range may
/// stand on a page another range rewrites.
pub const Cursor = struct {
    store: *const TriggerStore,
    path: TreePath,
    height: u8,
    page_len: u32,
    /// The pairs of the cursor's level before its page.
    leaf_start: u32,
    /// The global ordinal of the page's first pair.
    page_start: u32,
    offset: u32,

    /// False past the last stored pair.
    pub fn valid(self: Cursor) bool {
        return self.path.leaf != no_entry;
    }

    pub fn page(self: Cursor) Page {
        return self.store.page(self.path.leaf);
    }

    /// The cursor's page's key column alone.
    pub fn pageKeys(self: Cursor) *const [page_capacity]u256 {
        return self.store.pageKeys(self.path.leaf);
    }

    /// The drop piece of the cursor's page's slots `[lo, hi)`.
    pub fn dropPiece(self: Cursor, lo: u32, hi: u32) DropPiece {
        std.debug.assert(lo < hi and hi <= self.page_len);
        // A page holds at most `page_capacity` pairs.
        return .{ .page = .{ .path = self.path, .leaf_start = self.leaf_start }, .lo = @intCast(lo), .hi = @intCast(hi) };
    }

    /// The next stored pair.
    pub fn next(self: *Cursor) void {
        self.offset += 1;
        if (self.offset == self.page_len) self.nextPage();
    }

    /// The first pair of the next page: the lowest ancestor with a next entry, then down its
    /// first entries; past the level's last page, the next level holding pairs. O(1)
    /// amortized per page.
    pub fn nextPage(self: *Cursor) void {
        const store = self.store;
        const next_start = self.page_start + self.page_len;
        var height: usize = 0;
        while (height < self.height) : (height += 1) {
            const at = store.node(self.path.nodes[height]);
            const entry = self.path.entries[height] + 1;
            if (entry >= at.header.count) continue;
            self.path.entries[height] = @intCast(entry);
            var child = at.child[entry];
            var below = height;
            while (below > 0) {
                below -= 1;
                self.path.nodes[below] = child;
                self.path.entries[below] = 0;
                child = store.node(child).child[0];
            }
            self.path.leaf = child;
            self.leaf_start += self.page_len;
            self.page_start = next_start;
            self.offset = 0;
            self.page_len = store.node(self.path.nodes[0]).entryCount(self.path.entries[0], .pairs);
            return;
        }
        if (next_start < store.pair_count) {
            self.* = store.cursorAt(next_start);
            return;
        }
        self.* = store.endCursor();
    }
};

/// A position among the stored pairs of one `PairCount`, over every level in key order: the
/// next counted slot of a page is one bit step in its mask; past a page's last, the lowest
/// ancestor with a later entry holding one, then down each node's first such entry; past a
/// level's last, an `emittedCursorAt` on the next. O(1) per pair plus O(H F) per page step.
/// Steps only onto a counted pair: callers stop before the last. Reads page masks: valid only
/// while no patch, rebuild or refresh runs.
pub const EmittedCursor = struct {
    store: *const TriggerStore,
    kind: PairCount,
    path: TreePath,
    height: u8,
    // The page's counted slots from `slot` on.
    rest: u64,
    slot: u32,

    pub fn page(self: EmittedCursor) Page {
        return self.store.page(self.path.leaf);
    }

    /// The cursor's pair's key.
    pub fn key(self: EmittedCursor) u256 {
        return self.store.pageKeys(self.path.leaf)[self.slot];
    }

    /// The next counted pair, which exists; true when it is on another page.
    pub fn next(self: *EmittedCursor) bool {
        self.rest &= self.rest - 1;
        if (self.rest != 0) {
            self.slot = @ctz(self.rest);
            return false;
        }
        self.nextPage();
        return true;
    }

    fn nextPage(self: *EmittedCursor) void {
        const store = self.store;
        var height: usize = 0;
        while (height < self.height) : (height += 1) {
            const at = store.node(self.path.nodes[height]);
            var entry: usize = self.path.entries[height] + 1;
            while (entry < at.header.count and at.entryCount(entry, self.kind) == 0) entry += 1;
            if (entry == at.header.count) continue;
            self.path.entries[height] = @intCast(entry);
            var child = at.child[entry];
            var below = height;
            while (below > 0) {
                below -= 1;
                const under = store.node(child);
                const first = under.firstCounted(self.kind);
                self.path.nodes[below] = child;
                self.path.entries[below] = @intCast(first);
                child = under.child[first];
            }
            self.path.leaf = child;
            self.rest = store.page(child).header.slots(self.kind);
            self.slot = @ctz(self.rest);
            return;
        }
        // Past the level's last counted pair: the next level's first, which exists.
        const next_level = @as(usize, self.path.level) + 1;
        std.debug.assert(next_level < store.levels.items.len);
        self.* = store.emittedCursorAt(self.kind, store.level_rank.prefix(self.kind, next_level));
    }
};

fn orderU256(key: u256, item: u256) std.math.Order {
    return std.math.order(key, item);
}

fn orderU32(key: u32, item: u32) std.math.Order {
    return std.math.order(key, item);
}

fn orderInsertKey(key: u256, edit: InsertEdit) std.math.Order {
    return std.math.order(key, edit.key);
}

fn orderSegmentPos(position: u32, segment: Segment) std.math.Order {
    return std.math.order(position, segment.pos);
}

fn orderRunOutput(output: u32, run: Run) std.math.Order {
    return std.math.order(output, run.out_base);
}

// Slots `[lo, hi)` of a page's u64 set.
fn slotMask(lo: u32, hi: u32) u64 {
    return lowSlots(hi) & ~lowSlots(lo);
}

// Slots below `count`.
fn lowSlots(count: u32) u64 {
    std.debug.assert(count <= 64);
    return if (count == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(count)) - 1;
}

// The slot of `word`'s set bit of rank `rank`: a `@popCount` bisection. Hand-rolled: std
// has no select-in-word.
fn selectBit(word: u64, rank: u32) u32 {
    std.debug.assert(rank < @popCount(word));
    var rest = word;
    var remaining = rank;
    var slot: u32 = 0;
    inline for ([_]u6{ 32, 16, 8, 4, 2, 1 }) |half| {
        const low: u32 = @popCount(rest & ((@as(u64, 1) << half) - 1));
        if (remaining >= low) {
            remaining -= low;
            slot += half;
            rest >>= half;
        }
    }
    std.debug.assert(rest & 1 == 1 and remaining == 0);
    return slot;
}

// The first kept slot at or after `slot` of a page segment, or null.
fn keptFrom(segment: Segment, slot: u32) ?u32 {
    if (slot >= segment.hi) return null;
    const kept = (lowSlots(segment.hi) & ~segment.mask) >> @intCast(slot);
    if (kept == 0) return null;
    return slot + @ctz(kept);
}

// ---- Leaf job (one output page per item) --------------------------------------------------

const LeafJob = struct {
    store: *const TriggerStore,
    runs: []const Run,
    outputs: []LevelOutput,
    range_count: usize,
};

// Scalar: a key-compare merge of kept pairs with sorted inserts, the kept spans copied per
// column with `@memcpy`, each insert transposed from its record into the columns. The range
// finds its first output's run once and steps runs in output order.
fn leafJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *LeafJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start < range.end and range.end <= job.outputs.len);
    var run_index = std.sort.upperBound(Run, job.runs, @as(u32, @intCast(range.start)), orderRunOutput) - 1;
    for (range.start..range.end) |output| {
        while (output >= job.runs[run_index].out_base + job.runs[run_index].m) run_index += 1;
        job.outputs[output] = writePage(job.store, job.runs[run_index], @intCast(output));
    }
}

// Writes output page `output` of `run` and returns its record.
fn writePage(store: *const TriggerStore, run: Run, output: u32) LevelOutput {
    std.debug.assert(output >= run.out_base and output < run.out_base + run.m);
    const index = output - run.out_base;
    const begin: u32 = @intCast(@as(u64, index) * run.n / run.m);
    const end: u32 = @intCast(@as(u64, index + 1) * run.n / run.m);
    const segments = store.segments.items[run.seg_lo..run.seg_hi];
    const inserts = store.sorted_inserts.items[run.ins_lo..][0..run.ins_count];
    var kept_taken = mergeSplit(store, segments, run.kept, inserts, begin);
    var inserts_taken = begin - kept_taken;
    const id = store.outputId(0, output);
    const dest = store.page(id);
    // The kept cursor: segment, its page and slot of kept pair `kept_taken`. `source` is
    // set while kept pairs remain.
    var segment_index: usize = 0;
    var source: Page = undefined;
    var slot: u32 = 0;
    if (kept_taken < run.kept) {
        segment_index = std.sort.upperBound(Segment, segments, kept_taken, orderSegmentPos) - 1;
        source = store.page(segments[segment_index].id);
        slot = selectBit(lowSlots(segments[segment_index].hi) & ~segments[segment_index].mask, kept_taken - segments[segment_index].pos);
    }
    const count = end - begin;
    var written: u32 = 0;
    while (written < count) {
        const take_kept = kept_taken < run.kept and (inserts_taken == inserts.len or
            source.keys[slot] < inserts[inserts_taken].key);
        if (!take_kept) {
            writeInsert(dest, written, inserts[inserts_taken]);
            inserts_taken += 1;
            written += 1;
            continue;
        }
        // A span of kept slots: up to the next dropped slot, the page end, the next insert's
        // key, and this page's remaining count.
        const segment = segments[segment_index];
        const dropped_after = segment.mask >> @intCast(slot);
        const undropped = if (dropped_after == 0) segment.hi - slot else @min(segment.hi - slot, @ctz(dropped_after));
        var span = @min(undropped, count - written);
        if (inserts_taken < inserts.len) {
            const bound = inserts[inserts_taken].key;
            var below: u32 = 1;
            while (below < span and source.keys[slot + below] < bound) below += 1;
            span = below;
        }
        copyPairs(dest, written, source, slot, span);
        written += span;
        kept_taken += span;
        if (kept_taken == run.kept) continue;
        if (keptFrom(segment, slot + span)) |next_slot| {
            slot = next_slot;
        } else {
            segment_index += 1;
            while (keptFrom(segments[segment_index], 0) == null) segment_index += 1;
            source = store.page(segments[segment_index].id);
            slot = keptFrom(segments[segment_index], 0).?;
        }
    }
    if (std.debug.runtime_safety) {
        for (dest.keys[1..count], dest.keys[0 .. count - 1]) |key, previous| std.debug.assert(previous < key);
    }
    dest.header.* = .{
        .len = count,
        .valid_mask = simd.bytesMatchingMask(dest.emit[0..count], emit_valid, emit_valid),
        .allowed_mask = simd.bytesMatchingMask(dest.emit[0..count], emit_valid | emit_allowed, emit_valid | emit_allowed),
    };
    return .{ .first_key = dest.keys[0], .id = id, .counts = dest.header.counts() };
}

// The kept pairs among the first `position` merged pairs of a run: a binary search on the
// merge path, comparing kept pair x with insert `position - x - 1`. Keys are distinct.
// Hand-rolled: `std.sort.partitionPoint` needs a slice, and this predicate indexes two
// streams by x.
fn mergeSplit(store: *const TriggerStore, segments: []const Segment, kept: u32, inserts: []const InsertEdit, position: u32) u32 {
    const insert_count: u32 = @intCast(inserts.len);
    var lo = position -| insert_count;
    var hi = @min(position, kept);
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (keptKey(store, segments, mid) < inserts[position - mid - 1].key) lo = mid + 1 else hi = mid;
    }
    return lo;
}

// The key of the run's kept pair `kept_index`.
fn keptKey(store: *const TriggerStore, segments: []const Segment, kept_index: u32) u256 {
    const segment = segments[std.sort.upperBound(Segment, segments, kept_index, orderSegmentPos) - 1];
    const slot = selectBit(lowSlots(segment.hi) & ~segment.mask, kept_index - segment.pos);
    return store.pageKeys(segment.id)[slot];
}

fn writeInsert(dest: Page, at: u32, edit: InsertEdit) void {
    const contact = edit.contact;
    dest.keys[at] = edit.key;
    dest.a[at] = contact.a;
    dest.b[at] = contact.b;
    dest.a_row[at] = storedRow(contact.a_movement_index);
    dest.b_row[at] = storedRow(contact.b_movement_index);
    dest.normal_x[at] = contact.normal_x;
    dest.normal_y[at] = contact.normal_y;
    dest.penetration[at] = contact.penetration;
    dest.max_speed_sq[at] = contact.pre_response_max_speed_sq;
    dest.rel_speed_sq[at] = contact.pre_response_relative_speed_sq;
    dest.emit[at] = edit.emit;
}

// A contact's movement row as stored: movement rows are u32 throughout collision.
fn storedRow(row: usize) u32 {
    return std.math.cast(u32, row) orelse no_row;
}

// ---- Node merge (main) ------------------------------------------------------------------

// A run's merged entries consumed in order: segment `index`, `offset` items into it.
const SegmentCursor = struct {
    segments: []const Segment,
    index: usize = 0,
    offset: u32 = 0,
};

// Writes node `id` from the next `count` merged entries at `segments` (`children` the height
// below's outputs) and returns its record. Scalar: an old node's span is one offset add over
// at most F entries per prefix column, a tiny fixed batch; the outputs' prefixes are a running
// sum over their records.
fn writeNode(store: *const TriggerStore, id: u32, children: []const LevelOutput, segments: *SegmentCursor, count: u32) LevelOutput {
    const dest = store.node(id);
    const columns = dest.prefixColumns();
    var totals: [Counts.len]u32 = @splat(0);
    var written: u32 = 0;
    while (written < count) {
        const segment = segments.segments[segments.index];
        const take = @min(segment.items() - segments.offset, count - written);
        switch (segment.kind) {
            // A span of an old node's entries: its prefixes rebased onto this node's.
            .entries => {
                const source = store.node(segment.id);
                const from = segment.lo + segments.offset;
                @memcpy(dest.first_key[written..][0..take], source.first_key[from..][0..take]);
                @memcpy(dest.child[written..][0..take], source.child[from..][0..take]);
                const source_end = from + take == source.header.count;
                for (columns, source.prefixColumns(), &totals, source.header.totals.values) |column, source_column, *total, source_total| {
                    const base = source_column[from];
                    for (column[written..][0..take], source_column[from..][0..take]) |*start, source_start| start.* = total.* + (source_start - base);
                    total.* += (if (source_end) source_total else source_column[from + take]) - base;
                }
            },
            .outputs => for (children[segment.lo + segments.offset ..][0..take], written..) |child, entry| {
                dest.first_key[entry] = child.first_key;
                dest.child[entry] = child.id;
                for (columns, &totals, child.counts.values) |column, *total, child_count| {
                    column[entry] = total.*;
                    total.* += child_count;
                }
            },
            .page => unreachable,
        }
        written += take;
        segments.offset += take;
        if (segments.offset == segment.items()) {
            segments.index += 1;
            segments.offset = 0;
        }
    }
    dest.header.* = .{ .count = count, .totals = .{ .values = totals } };
    return .{ .first_key = dest.first_key[0], .id = id, .counts = .{ .values = totals } };
}

// ---- Refresh job (stored pairs; ranges own the pages starting in them) ---------------------

const RefreshJob = struct {
    store: *const TriggerStore,
    data: *const DataSystem,
    items_per_range: usize,
    range_count: usize,
};

// Scalar: per pair two hinted row resolves into another store and two u8 tier loads; the
// movement columns are not in pair order, and `simd.zig` has no u8 gather. A height-1 node
// whose pages all start in the range gets its prefixes as a running sum over them; a node
// split at a range edge gets each page's counts, which `foldRefreshed` prefixes.
fn refreshJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *RefreshJob = @ptrCast(@alignCast(context));
    const store = job.store;
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start == range.index * job.items_per_range and range.end <= store.pair_count);
    const entities = job.data.movement_bodies.sliceConst().entities;
    const tier = job.data.scopeColumnsSliceConst().tier;
    std.debug.assert(entities.len == tier.len);
    var cursor = store.cursorAt(@intCast(range.start));
    if (cursor.offset != 0) cursor.nextPage();
    // Whether the range holds every page of the cursor's height-1 node: false for a node it
    // starts inside.
    var whole = false;
    var valid: u32 = 0;
    var allowed: u32 = 0;
    while (cursor.valid() and cursor.page_start < range.end) : (cursor.nextPage()) {
        const at = cursor.page();
        var valid_mask: u64 = 0;
        var allowed_mask: u64 = 0;
        for (0..cursor.page_len) |slot| {
            const a_row = job.data.movementBodyDenseIndexHinted(entities, at.a[slot], at.a_row[slot]);
            const b_row = job.data.movementBodyDenseIndexHinted(entities, at.b[slot], at.b_row[slot]);
            if (a_row == null or b_row == null) {
                at.a_row[slot] = if (a_row) |row| storedRow(row) else no_row;
                at.b_row[slot] = if (b_row) |row| storedRow(row) else no_row;
                at.emit[slot] = 0;
                continue;
            }
            at.a_row[slot] = storedRow(a_row.?);
            at.b_row[slot] = storedRow(b_row.?);
            at.emit[slot] = emitBits(tier[a_row.?].allowsCollision(), tier[b_row.?].allowsCollision());
            const bit = @as(u64, 1) << @intCast(slot);
            valid_mask |= bit;
            if (countsAs(at.emit[slot], .allowed)) allowed_mask |= bit;
        }
        at.header.valid_mask = valid_mask;
        at.header.allowed_mask = allowed_mask;
        if (cursor.height == 0) continue;
        // Reads only the parent's pairs prefixes and count, which no range writes.
        const parent = store.node(cursor.path.nodes[0]);
        const entry = cursor.path.entries[0];
        const last_entry = parent.header.count - 1;
        if (entry == 0) {
            whole = cursor.page_start + parent.start[last_entry] < range.end;
            valid = 0;
            allowed = 0;
        }
        if (!whole) {
            parent.valid_start[entry] = @popCount(valid_mask);
            parent.allowed_start[entry] = @popCount(allowed_mask);
            continue;
        }
        parent.valid_start[entry] = valid;
        parent.allowed_start[entry] = allowed;
        valid += @popCount(valid_mask);
        allowed += @popCount(allowed_mask);
        if (entry < last_entry) continue;
        parent.header.totals.set(.valid, valid);
        parent.header.totals.set(.allowed, allowed);
    }
}

// ---- Tests --------------------------------------------------------------------------------

const testing = std.testing;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;

// The tests' own key layout under the level bits, which are all the store reads: a 16-bit
// group just below the level, then a and b ordinals in the low 64 bits.
const test_group_shift = key_level_shift - 16;

fn testKey(level: u16, group: u16, a: u32, b: u32) u256 {
    return levelFirstKey(level) | (@as(u256, group) << test_group_shift) | (@as(u256, a) << 32) | b;
}

fn testIndexA(key: u256) u32 {
    return @truncate(key >> 32);
}

fn testIndexB(key: u256) u32 {
    return @truncate(key);
}

// The emit bits a test pair derives from its key: 0, valid, or valid and allowed.
fn testEmit(key: u256) u8 {
    return switch ((testIndexA(key) + testIndexB(key)) % 3) {
        0 => 0,
        1 => emit_valid,
        else => emit_valid | emit_allowed,
    };
}

fn testContact(key: u256) CollisionContact {
    const a = testIndexA(key);
    const b = testIndexB(key);
    return .{
        .a = .{ .index = a, .generation = 1 },
        .b = .{ .index = b, .generation = 1 },
        .a_movement_index = a,
        .b_movement_index = b,
        .normal_x = @floatFromInt(a),
        .normal_y = @floatFromInt(b),
        .penetration = @floatFromInt(keyLevel(key)),
        .pre_response_max_speed_sq = 1,
        .pre_response_relative_speed_sq = 2,
    };
}

// Fixed smallest ranges on `thread_system`: a 0-worker system runs every stage inline.
fn testThreads(thread_system: *ThreadSystem) StoreThreads {
    return .{ .thread_system = thread_system, .config = .{ .items_per_range = 1, .max_worker_threads = thread_system.workerThreadCount(), .adaptive = false } };
}

// One patch's edits built against `store` through its production readers: inserts located
// by `locateKey`, single drops by `storedPiece`, and each range `[lo, hi]` walked from
// `seek(lo)`, one cursor piece per page. Records are dealt across
// `source_count` sources in turn.
const TestEdits = struct {
    sources: []EditSource,

    fn build(arena: std.mem.Allocator, store: *const TriggerStore, insert_keys: []const u256, drop_keys: []const u256, drop_ranges: []const [2]u256, source_count: usize) !TestEdits {
        const inserts = try arena.alloc(std.ArrayList(InsertEdit), source_count);
        const pages = try arena.alloc(std.ArrayList(PageLocation), source_count);
        const drops = try arena.alloc(std.ArrayList(DropPiece), source_count);
        for (inserts, pages, drops) |*a, *b, *c| {
            a.* = .empty;
            b.* = .empty;
            c.* = .empty;
        }
        for (insert_keys, 0..) |key, index| {
            const located = store.locateKey(key);
            const source = index % source_count;
            try inserts[source].append(arena, .{ .key = key, .contact = testContact(key), .emit = testEmit(key) });
            try pages[source].append(arena, located.page);
        }
        var turn: usize = 0;
        for (drop_keys) |key| {
            const piece = store.storedPiece(key) orelse return error.TestDropNotStored;
            try drops[turn % source_count].append(arena, piece);
            turn += 1;
        }
        for (drop_ranges) |bounds| {
            var cursor = store.seek(bounds[0]);
            while (cursor.valid() and cursor.page().keys[cursor.offset] <= bounds[1]) {
                const lo = cursor.offset;
                var hi = lo;
                const keys = cursor.page().keys;
                while (hi < cursor.page_len and keys[hi] <= bounds[1]) hi += 1;
                try drops[turn % source_count].append(arena, cursor.dropPiece(lo, hi));
                turn += 1;
                if (hi < cursor.page_len) break;
                cursor.nextPage();
            }
        }
        const sources = try arena.alloc(EditSource, source_count);
        for (sources, inserts, pages, drops) |*source, source_inserts, source_pages, source_drops| {
            source.* = .{ .inserts = source_inserts.items, .insert_pages = source_pages.items, .drops = source_drops.items };
        }
        return .{ .sources = sources };
    }
};

fn patchKeys(store: *TriggerStore, threads: StoreThreads, insert_keys: []const u256, drop_keys: []const u256, drop_ranges: []const [2]u256, source_count: usize, revision: u64) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const edits = try TestEdits.build(arena_state.allocator(), store, insert_keys, drop_keys, drop_ranges, source_count);
    try store.patch(threads, edits.sources, revision);
}

fn rebuildKeys(store: *TriggerStore, threads: StoreThreads, keys: []const u256, source_count: usize) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sources = try arena.alloc(EditSource, source_count);
    for (sources, 0..) |*source, index| {
        const lo = keys.len * index / source_count;
        const hi = keys.len * (index + 1) / source_count;
        const inserts = try arena.alloc(InsertEdit, hi - lo);
        for (inserts, keys[lo..hi]) |*edit, key| edit.* = .{ .key = key, .contact = testContact(key), .emit = testEmit(key) };
        source.* = .{ .inserts = inserts };
    }
    try store.rebuild(threads, sources, 1, 0);
}

const SubtreeSummary = struct { first_key: u256, counts: Counts };

// The tree under one node or page: keys stay on `level` and strictly increase past
// `previous`, non-root pages and nodes hold at least half, a root node holds at least two
// entries, each entry's first key and prefixes of every count match its child, totals match
// the subtree's counts, and page masks mark the emit bytes.
fn expectSubtreeValid(store: *const TriggerStore, level: u16, id: u32, height: u8, is_root: bool, previous: *?u256) !SubtreeSummary {
    if (height == 0) {
        const at = store.page(id);
        const len = at.header.len;
        try testing.expect(len >= 1 and len <= page_capacity);
        if (!is_root) try testing.expect(len >= page_min);
        var valid_mask: u64 = 0;
        var allowed_mask: u64 = 0;
        for (at.keys[0..len], at.emit[0..len], 0..) |key, emit, slot| {
            try testing.expectEqual(level, keyLevel(key));
            if (previous.*) |before| try testing.expect(before < key);
            previous.* = key;
            const bit = @as(u64, 1) << @intCast(slot);
            if (emit & emit_valid != 0) valid_mask |= bit;
            if (emit == emit_valid | emit_allowed) allowed_mask |= bit;
        }
        try testing.expectEqual(valid_mask, at.header.valid_mask);
        try testing.expectEqual(allowed_mask, at.header.allowed_mask);
        return .{ .first_key = at.keys[0], .counts = at.header.counts() };
    }
    const at = store.node(id);
    const count = at.header.count;
    try testing.expect(count <= node_capacity);
    try testing.expect(if (is_root) count >= 2 else count >= node_min);
    var summary = SubtreeSummary{ .first_key = at.first_key[0], .counts = .initFill(0) };
    for (0..count) |entry| {
        for (std.enums.values(PairCount)) |kind| try testing.expectEqual(summary.counts.get(kind), at.starts(kind)[entry]);
        const child = try expectSubtreeValid(store, level, at.child[entry], height - 1, false, previous);
        try testing.expectEqual(child.first_key, at.first_key[entry]);
        for (std.enums.values(PairCount)) |kind| summary.counts.set(kind, summary.counts.get(kind) + child.counts.get(kind));
    }
    for (std.enums.values(PairCount)) |kind| try testing.expectEqual(summary.counts.get(kind), at.header.totals.get(kind));
    return summary;
}

// Every level's tree, each level's counts and rank prefixes of every count, the store sums,
// and empty pending scratch.
fn expectTreeValid(store: *const TriggerStore) !void {
    try testing.expectEqual(store.levels.items.len, store.level_rank.sums.items.len);
    var totals = Counts.initFill(0);
    for (store.levels.items, 0..) |tree, level| {
        for (std.enums.values(PairCount)) |kind| try testing.expectEqual(totals.get(kind), store.level_rank.prefix(kind, level));
        if (tree.root == no_entry) {
            try testing.expectEqual(Counts.initFill(0), tree.counts);
            try testing.expectEqual(@as(u8, 0), tree.height);
            continue;
        }
        var previous: ?u256 = null;
        const summary = try expectSubtreeValid(store, @intCast(level), tree.root, tree.height, true, &previous);
        try testing.expectEqual(summary.counts, tree.counts);
        for (std.enums.values(PairCount)) |kind| totals.set(kind, totals.get(kind) + summary.counts.get(kind));
    }
    for (std.enums.values(PairCount)) |kind| {
        try testing.expectEqual(totals.get(kind), store.level_rank.prefix(kind, store.levels.items.len));
        try testing.expectEqual(totals.get(kind), store.countOf(kind));
    }
    for (store.leaf_pending.items) |pending| try testing.expectEqual(@as(u32, 0), pending);
    for (store.node_pending.items) |pending| try testing.expectEqual(@as(u32, 0), pending);
    for (store.level_pending.items) |pending| try testing.expectEqual(@as(u32, 0), pending);
}

// The store's walk from ordinal 0 holds exactly `reference`, with each pair's columns.
fn expectStoredKeys(store: *const TriggerStore, reference: []const u256) !void {
    try testing.expectEqual(reference.len, store.pair_count);
    if (reference.len == 0) return;
    var cursor = store.cursorAt(0);
    for (reference, 0..) |key, ordinal| {
        try testing.expect(cursor.valid());
        try testing.expectEqual(@as(u32, @intCast(ordinal)), cursor.page_start + cursor.offset);
        const at = cursor.page();
        const slot = cursor.offset;
        try testing.expectEqual(key, at.keys[slot]);
        try testing.expectEqual(testContact(key), at.contactAt(slot));
        try testing.expectEqual(testEmit(key), at.emit[slot]);
        cursor.next();
    }
    try testing.expect(!cursor.valid());
}

// `cursorAt`, `seek` and `locateKey` against the sorted reference, at every stored key, at
// keys between and around them, and at every level's first key (empty levels and past the
// table end included).
fn expectReadersMatch(store: *const TriggerStore, reference: []const u256) !void {
    for (reference, 0..) |key, ordinal| {
        const cursor = store.cursorAt(@intCast(ordinal));
        try testing.expectEqual(key, cursor.page().keys[cursor.offset]);
        try expectSeekAt(store, key, cursor);
        if (ordinal + 1 < reference.len) {
            try expectSeekAt(store, key + 1, store.cursorAt(@intCast(ordinal + 1)));
        } else {
            try expectSeekPastEnd(store, key + 1);
        }
        const located = store.locateKey(key);
        try testing.expectEqual(cursor.path.leaf, located.page.path.leaf);
        try testing.expectEqual(cursor.page_start - store.level_rank.prefix(.pairs, keyLevel(key)), located.page.leaf_start);
        try testing.expectEqual(located.page.leaf_start, cursor.leaf_start);
        const piece = store.storedPiece(key).?;
        try testing.expectEqual(located.page.leaf_start, piece.page.leaf_start);
        try testing.expectEqual(cursor.offset, piece.lo);
        try testing.expectEqual(sortedContains(reference, key + 1), store.storedPiece(key + 1) != null);
    }
    for (0..store.levels.items.len + 2) |level| {
        const first = levelFirstKey(@intCast(level));
        const ordinal = std.sort.lowerBound(u256, reference, first, orderU256);
        if (ordinal < reference.len) {
            try expectSeekAt(store, first, store.cursorAt(@intCast(ordinal)));
        } else {
            try expectSeekPastEnd(store, first);
        }
    }
    try expectSeekPastEnd(store, std.math.maxInt(u256));
}

// `seek(key)` stands where `expected` (a `cursorAt` cursor) does: same ordinal, page and path.
fn expectSeekAt(store: *const TriggerStore, key: u256, expected: Cursor) !void {
    const cursor = store.seek(key);
    try testing.expect(cursor.valid());
    try testing.expectEqual(expected.page_start + expected.offset, cursor.page_start + cursor.offset);
    try testing.expectEqual(expected.offset, cursor.offset);
    try testing.expectEqual(expected.page_len, cursor.page_len);
    try testing.expectEqual(expected.height, cursor.height);
    try testing.expectEqual(expected.leaf_start, cursor.leaf_start);
    try testing.expectEqual(expected.path.level, cursor.path.level);
    try testing.expectEqual(expected.path.leaf, cursor.path.leaf);
    try testing.expectEqualSlices(u32, expected.path.nodes[0..expected.height], cursor.path.nodes[0..cursor.height]);
    try testing.expectEqualSlices(u8, expected.path.entries[0..expected.height], cursor.path.entries[0..cursor.height]);
}

// `seek(key)` past the last stored pair: invalid, at ordinal `pair_count`.
fn expectSeekPastEnd(store: *const TriggerStore, key: u256) !void {
    const cursor = store.seek(key);
    try testing.expect(!cursor.valid());
    try testing.expectEqual(store.pair_count, cursor.page_start + cursor.offset);
}

fn sortedInsert(list: *std.ArrayList(u256), key: u256) !void {
    const at = std.sort.lowerBound(u256, list.items, key, orderU256);
    try list.insert(testing.allocator, at, key);
}

fn sortedContains(list: []const u256, key: u256) bool {
    const at = std.sort.lowerBound(u256, list, key, orderU256);
    return at < list.len and list[at] == key;
}

fn sortedRemove(list: *std.ArrayList(u256), key: u256) void {
    const at = std.sort.lowerBound(u256, list.items, key, orderU256);
    std.debug.assert(list.items[at] == key);
    _ = list.orderedRemove(at);
}

test "collision trigger store level rank matches a naive prefix of every count through add, append, find and build" {
    var rank: LevelRank = .{};
    defer rank.deinit(testing.allocator);
    var counts: std.ArrayList(LevelTree) = .empty;
    defer counts.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(0x72_61_6e_6b);
    const random = prng.random();
    // Sizes cross powers of two as levels are appended one at a time.
    for (0..70) |_| {
        try rank.sums.ensureUnusedCapacity(testing.allocator, 1);
        rank.appendAssumeCapacity();
        try counts.append(testing.allocator, .{});
        for (0..3) |_| {
            const level = random.uintLessThan(usize, counts.items.len);
            // Each count moves on its own, so the columns' empty levels differ.
            var deltas: std.EnumArray(PairCount, i64) = undefined;
            for (std.enums.values(PairCount)) |kind| {
                const held = counts.items[level].counts.get(kind);
                const delta: i64 = if (random.boolean() or held == 0) random.uintAtMost(u32, 9) else -@as(i64, random.uintAtMost(u32, held));
                counts.items[level].counts.set(kind, @intCast(@as(i64, held) + delta));
                deltas.set(kind, delta);
            }
            rank.add(level, deltas);
        }
        for (std.enums.values(PairCount)) |kind| {
            var total: u32 = 0;
            for (counts.items, 0..) |tree, level| {
                try testing.expectEqual(total, rank.prefix(kind, level));
                // Every ordinal of the level finds it; levels holding none are never found.
                for (0..tree.counts.get(kind)) |local| {
                    const found = rank.find(kind, total + @as(u32, @intCast(local)));
                    try testing.expectEqual(@as(u16, @intCast(level)), found.level);
                    try testing.expectEqual(@as(u32, @intCast(local)), found.local);
                }
                total += tree.counts.get(kind);
            }
            try testing.expectEqual(total, rank.prefix(kind, counts.items.len));
        }
        var built: LevelRank = .{};
        defer built.deinit(testing.allocator);
        try built.sums.ensureTotalCapacity(testing.allocator, counts.items.len);
        built.build(counts.items);
        try testing.expectEqualSlices(Counts, rank.sums.items, built.sums.items);
    }
}

// Random patches over levels 0, 3 and 9 with empty levels between: single and range drops
// and inserts dealt across several sources. A serial store and a 2-worker store match the
// reference and each other after every patch.
test "collision trigger store random patches across levels match a sorted reference, serial and 2 workers" {
    var serial_system = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 0 });
    defer serial_system.deinit();
    var thread_system = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2 });
    defer thread_system.deinit();
    var serial = TriggerStore.init(testing.allocator);
    defer serial.deinit();
    var threaded = TriggerStore.init(testing.allocator);
    defer threaded.deinit();
    var reference: std.ArrayList(u256) = .empty;
    defer reference.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(0x74_72_69_67);
    const random = prng.random();
    const levels = [_]u16{ 0, 3, 9 };
    var inserts: std.ArrayList(u256) = .empty;
    defer inserts.deinit(testing.allocator);
    var drops: std.ArrayList(u256) = .empty;
    defer drops.deinit(testing.allocator);
    for (0..40) |round| {
        inserts.clearRetainingCapacity();
        drops.clearRetainingCapacity();
        var ranges: [2][2]u256 = undefined;
        var range_count: usize = 0;
        // Growth rounds, then churn, then a level emptied, then regrowth.
        const insert_count: usize = if (round < 8) 400 else if (round < 30) random.uintLessThan(usize, 120) else 30;
        const drop_count: usize = if (round < 8) 20 else random.uintLessThan(usize, 150);
        for (0..insert_count) |_| {
            const key = testKey(levels[random.uintLessThan(usize, levels.len)], random.uintLessThan(u16, 4), random.uintLessThan(u32, 2000), random.uintLessThan(u32, 50));
            if (sortedContains(reference.items, key) or std.mem.indexOfScalar(u256, inserts.items, key) != null) continue;
            if (round == 20 and keyLevel(key) == 3) continue;
            try inserts.append(testing.allocator, key);
        }
        if (round == 20) {
            // Level 3 emptied while the others keep pairs.
            ranges[0] = .{ levelFirstKey(3), levelFirstKey(4) - 1 };
            range_count = 1;
        } else if (round % 5 == 4 and reference.items.len > 0) {
            // Multi-page range drops: every pair of one a-run span on a level.
            const pivot = reference.items[random.uintLessThan(usize, reference.items.len)];
            const level = keyLevel(pivot);
            const lo_a = testIndexA(pivot);
            ranges[0] = .{ testKey(level, 0, lo_a, 0), testKey(level, 0, lo_a + 300, 0) };
            ranges[1] = .{ testKey(level, 2, lo_a, 0), testKey(level, 3, lo_a + 50, 0) };
            range_count = 2;
        }
        for (0..drop_count) |_| {
            if (reference.items.len == 0) break;
            const key = reference.items[random.uintLessThan(usize, reference.items.len)];
            if (std.mem.indexOfScalar(u256, drops.items, key) != null) continue;
            var in_range = false;
            for (ranges[0..range_count]) |bounds| in_range = in_range or (key >= bounds[0] and key <= bounds[1]);
            if (!in_range) try drops.append(testing.allocator, key);
        }
        const sources = 1 + round % 4;
        try patchKeys(&serial, testThreads(&serial_system), inserts.items, drops.items, ranges[0..range_count], sources, round + 1);
        try patchKeys(&threaded, testThreads(&thread_system), inserts.items, drops.items, ranges[0..range_count], sources, round + 1);
        for (drops.items) |key| sortedRemove(&reference, key);
        for (ranges[0..range_count]) |bounds| {
            const lo = std.sort.lowerBound(u256, reference.items, bounds[0], orderU256);
            const hi = std.sort.upperBound(u256, reference.items, bounds[1], orderU256);
            try reference.replaceRange(testing.allocator, lo, hi - lo, &.{});
        }
        for (inserts.items) |key| try sortedInsert(&reference, key);
        try expectTreeValid(&serial);
        try expectTreeValid(&threaded);
        try expectStoredKeys(&serial, reference.items);
        try expectStoredKeys(&threaded, reference.items);
        try testing.expectEqual(round + 1, serial.seen_revision);
        if (round == 20) try testing.expectEqual(@as(u32, 0), serial.levels.items[3].counts.get(.pairs));
    }
    try expectReadersMatch(&serial, reference.items);
    try testing.expectEqual(@as(usize, 10), serial.levels.items.len);
}

// A 0-worker thread system for serial stores and a 2-worker one for threaded stores.
// Initialized in place: a thread system stays where it started.
const TestSystems = struct {
    serial: ThreadSystem,
    threaded: ThreadSystem,

    fn init(self: *TestSystems) !void {
        self.serial = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 0 });
        errdefer self.serial.deinit();
        self.threaded = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2 });
    }

    fn deinit(self: *TestSystems) void {
        self.threaded.deinit();
        self.serial.deinit();
    }
};

// A reference and two stores (serial on a 0-worker system, threaded on a 2-worker one)
// patched in step, checked after each patch.
const TestPair = struct {
    serial: TriggerStore,
    threaded: TriggerStore,
    reference: std.ArrayList(u256) = .empty,
    systems: *TestSystems,
    revision: u64 = 0,

    fn init(systems: *TestSystems) TestPair {
        return .{ .serial = .init(testing.allocator), .threaded = .init(testing.allocator), .systems = systems };
    }

    fn deinit(self: *TestPair) void {
        self.serial.deinit();
        self.threaded.deinit();
        self.reference.deinit(testing.allocator);
    }

    fn rebuild(self: *TestPair, keys: []const u256) !void {
        try rebuildKeys(&self.serial, testThreads(&self.systems.serial), keys, 3);
        try rebuildKeys(&self.threaded, testThreads(&self.systems.threaded), keys, 3);
        self.reference.clearRetainingCapacity();
        try self.reference.appendSlice(testing.allocator, keys);
        std.sort.pdq(u256, self.reference.items, {}, std.sort.asc(u256));
        try self.check();
    }

    fn patch(self: *TestPair, inserts: []const u256, drops: []const u256, ranges: []const [2]u256) !void {
        self.revision += 1;
        try patchKeys(&self.serial, testThreads(&self.systems.serial), inserts, drops, ranges, 2, self.revision);
        try patchKeys(&self.threaded, testThreads(&self.systems.threaded), inserts, drops, ranges, 2, self.revision);
        for (drops) |key| sortedRemove(&self.reference, key);
        for (ranges) |bounds| {
            const lo = std.sort.lowerBound(u256, self.reference.items, bounds[0], orderU256);
            const hi = std.sort.upperBound(u256, self.reference.items, bounds[1], orderU256);
            try self.reference.replaceRange(testing.allocator, lo, hi - lo, &.{});
        }
        for (inserts) |key| try sortedInsert(&self.reference, key);
        try self.check();
    }

    fn check(self: *TestPair) !void {
        try expectTreeValid(&self.serial);
        try expectTreeValid(&self.threaded);
        try expectStoredKeys(&self.serial, self.reference.items);
        try expectStoredKeys(&self.threaded, self.reference.items);
        for (self.serial.levels.items, self.threaded.levels.items) |serial_tree, threaded_tree| {
            try testing.expectEqual(serial_tree.height, threaded_tree.height);
        }
    }

    fn height(self: *const TestPair, level: u16) u8 {
        return self.serial.levels.items[level].height;
    }
};

// Keys `[first, first + count)` of a ordinals on `level`, group 0, b 0.
fn testRunKeys(buffer: []u256, level: u16, first: u32) []u256 {
    for (buffer, 0..) |*key, index| key.* = testKey(level, 0, first + @as(u32, @intCast(index)), 0);
    return buffer;
}

test "collision trigger store page runs split, extend right and left, and merge runs" {
    var systems: TestSystems = undefined;
    try systems.init();
    defer systems.deinit();
    var pair = TestPair.init(&systems);
    defer pair.deinit();
    // Ten full pages under one root node: page p holds a-runs [64p, 64p + 64).
    var keys: [640]u256 = undefined;
    try pair.rebuild(testRunKeys(&keys, 0, 0));
    try testing.expectEqual(@as(u8, 1), pair.height(0));
    try testing.expectEqual(@as(u32, 10), pair.serial.node(pair.serial.levels.items[0].root).header.count);
    var drops: [64]u256 = undefined;
    // A middle page left at 24 absorbs its right sibling.
    try pair.patch(&.{}, testRunKeys(drops[0..40], 0, 3 * 64), &.{});
    // The last page left at 24 absorbs its left sibling.
    try pair.patch(&.{}, testRunKeys(drops[0..40], 0, 9 * 64 + 24), &.{});
    // A page split: 70 inserts between two stored a-runs of the first page.
    var inserts: [70]u256 = undefined;
    for (&inserts, 0..) |*key, index| key.* = testKey(0, 0, 5, @intCast(index + 1));
    try pair.patch(&inserts, &.{}, &.{});
    // Two runs, the later one at the level's end underflowing: its left neighbour joins it
    // to the earlier run.
    const page_count = pair.serial.node(pair.serial.levels.items[0].root).header.count;
    const last_start = pair.serial.node(pair.serial.levels.items[0].root).start[page_count - 1];
    const third_last = pair.serial.node(pair.serial.levels.items[0].root).start[page_count - 3];
    var spread: [3]u256 = undefined;
    spread[0] = pair.reference.items[third_last];
    spread[1] = pair.reference.items[last_start];
    spread[2] = pair.reference.items[last_start + 1];
    try pair.patch(&.{}, &spread, &.{.{ pair.reference.items[last_start + 2], pair.reference.items[last_start + 30] }});
    // Every page dropped but a few pairs: the root collapses to one page, then empties.
    try pair.patch(&.{}, &.{}, &.{.{ pair.reference.items[5], pair.reference.items[pair.reference.items.len - 1] }});
    try testing.expectEqual(@as(u8, 0), pair.height(0));
    try testing.expectEqual(@as(u32, 5), pair.serial.levels.items[0].counts.get(.pairs));
    try pair.patch(&.{}, &.{}, &.{.{ 0, levelFirstKey(1) - 1 }});
    try testing.expectEqual(no_entry, pair.serial.levels.items[0].root);
    try testing.expectEqual(@as(u32, 0), pair.serial.pair_count);
}

test "collision trigger store a right absorption swallows the run it reaches" {
    var systems: TestSystems = undefined;
    try systems.init();
    defer systems.deinit();
    var pair = TestPair.init(&systems);
    defer pair.deinit();
    // Ten full pages under one root node: page p holds a-runs [64p, 64p + 64).
    var keys: [640]u256 = undefined;
    try pair.rebuild(testRunKeys(&keys, 0, 0));
    // Page 3 left at 24 and page 5 at 63: page 3 absorbs page 4, which reaches page 5's run.
    var drops: [41]u256 = undefined;
    _ = testRunKeys(drops[0..40], 0, 3 * 64);
    drops[40] = testKey(0, 0, 5 * 64, 0);
    try pair.patch(&.{}, &drops, &.{});
    try testing.expectEqual(@as(u32, 10), pair.serial.node(pair.serial.levels.items[0].root).header.count);
}

test "collision trigger store roots grow through three heights and collapse to a page and to empty" {
    var systems: TestSystems = undefined;
    try systems.init();
    defer systems.deinit();
    var pair = TestPair.init(&systems);
    defer pair.deinit();
    var keys: [1200]u256 = undefined;
    var seen: [3]bool = @splat(false);
    // Interleaved inserts into an empty level: each patch splits pages throughout the tree.
    for (0..4) |round| {
        for (&keys, 0..) |*key, index| key.* = testKey(2, 0, @intCast(index * 4 + round), 0);
        try pair.patch(&keys, &.{}, &.{});
        seen[pair.height(2)] = true;
    }
    try testing.expectEqual(@as(u8, 2), pair.height(2));
    try testing.expect(seen[1] and seen[2]);
    // Every node under the root but the first emptied but for one pair: their pages merge
    // across node boundaries and the tree shrinks.
    const root = pair.serial.node(pair.serial.levels.items[2].root);
    const keep_from = root.start[1];
    try pair.patch(&.{}, &.{}, &.{.{ pair.reference.items[keep_from + 1], pair.reference.items[pair.reference.items.len - 1] }});
    try testing.expect(pair.height(2) <= 1);
    // One page left, then none.
    try pair.patch(&.{}, &.{}, &.{.{ pair.reference.items[20], pair.reference.items[pair.reference.items.len - 1] }});
    try testing.expectEqual(@as(u8, 0), pair.height(2));
    try pair.patch(&.{}, &.{}, &.{.{ levelFirstKey(2), levelFirstKey(3) - 1 }});
    try testing.expectEqual(@as(u32, 0), pair.serial.pair_count);
}

test "collision trigger store drops spanning one node's pages merge with a cousin across parents" {
    var systems: TestSystems = undefined;
    try systems.init();
    defer systems.deinit();
    var pair = TestPair.init(&systems);
    defer pair.deinit();
    // 80 full pages: a height-2 tree whose height-1 nodes hold 40 pages each.
    var keys: [80 * 64]u256 = undefined;
    try pair.rebuild(testRunKeys(&keys, 1, 0));
    try testing.expectEqual(@as(u8, 2), pair.height(1));
    // Every pair of the first height-1 node but ten: its last pages touch, the lone 10-pair
    // page absorbs the next node's first page.
    const root = pair.serial.node(pair.serial.levels.items[1].root);
    const second_node = root.start[1];
    try pair.patch(&.{}, &.{}, &.{.{ pair.reference.items[10], pair.reference.items[second_node - 1] }});
    try testing.expectEqual(@as(u8, 1), pair.height(1));
    // The same at the level's right edge: the lone page absorbs its left cousin.
    try pair.rebuild(testRunKeys(&keys, 1, 0));
    const last_node = pair.serial.node(pair.serial.levels.items[1].root).start[1];
    try pair.patch(&.{}, &.{}, &.{.{ pair.reference.items[last_node], pair.reference.items[pair.reference.items.len - 11] }});
}

test "collision trigger store one patch touches three levels at different heights and the cursor crosses empty levels" {
    var systems: TestSystems = undefined;
    try systems.init();
    defer systems.deinit();
    var pair = TestPair.init(&systems);
    defer pair.deinit();
    var keys: [20 + 640 + 72 * 64]u256 = undefined;
    _ = testRunKeys(keys[0..20], 0, 0);
    _ = testRunKeys(keys[20..660], 3, 0);
    _ = testRunKeys(keys[660..], 9, 0);
    try pair.rebuild(&keys);
    try testing.expectEqual(@as(u8, 0), pair.height(0));
    try testing.expectEqual(@as(u8, 1), pair.height(3));
    try testing.expectEqual(@as(u8, 2), pair.height(9));
    try expectReadersMatch(&pair.serial, pair.reference.items);
    var inserts: [3 * 50]u256 = undefined;
    for (0..50) |index| {
        inserts[index] = testKey(0, 1, @intCast(index), 7);
        inserts[50 + index] = testKey(3, 0, @intCast(index * 3), 9);
        inserts[100 + index] = testKey(9, 0, @intCast(index * 70), 9);
    }
    // A new level past the table end joins in the same patch.
    const extra = [_]u256{ testKey(12, 0, 1, 1), testKey(12, 0, 2, 1) };
    try pair.patch(&inserts, &.{ keys[3], keys[30], keys[700] }, &.{.{ keys[100], keys[200] }});
    try pair.patch(&extra, &.{}, &.{});
    try testing.expectEqual(@as(usize, 13), pair.serial.levels.items.len);
    try expectReadersMatch(&pair.serial, pair.reference.items);
    // Level 3 emptied: the cursor steps from level 0 straight to level 9.
    try pair.patch(&.{}, &.{}, &.{.{ levelFirstKey(3), levelFirstKey(4) - 1 }});
    try expectReadersMatch(&pair.serial, pair.reference.items);
    const level0 = pair.serial.levels.items[0].counts.get(.pairs);
    var cursor = pair.serial.cursorAt(level0 - 1);
    cursor.next();
    try testing.expectEqual(@as(u16, 9), cursor.path.level);
    try testing.expectEqual(levelFirstKey(9), cursor.page().keys[cursor.offset]);
}

// The emit bits of `emittedCursorTestKeys`' pair `index` on `level`: level 2 holds pairs
// allowed only near its start, middle and end, and valid on every fifth, so whole height-1
// subtrees count no allowed pair; level 4 holds no valid pair.
fn emittedCursorTestEmit(level: u16, index: usize, level_len: usize) u8 {
    return switch (level) {
        2 => if (index < 10 or (index >= 5000 and index < 5010) or index + 10 >= level_len) emit_valid | emit_allowed else if (index % 5 == 0) emit_valid else 0,
        4 => 0,
        else => if (index % 3 == 0) 0 else if (index % 3 == 1) emit_valid else emit_valid | emit_allowed,
    };
}

test "collision trigger store emitted cursors match each count's reference by ordinal and by step, past pages, subtrees and levels counting none" {
    var serial_system = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 0 });
    defer serial_system.deinit();
    var store = TriggerStore.init(testing.allocator);
    defer store.deinit();
    var inserts: std.ArrayList(InsertEdit) = .empty;
    defer inserts.deinit(testing.allocator);
    // Level 1 is empty and level 4 counts pairs but none valid.
    const levels = [_]struct { level: u16, len: usize }{ .{ .level = 0, .len = 100 }, .{ .level = 2, .len = 3 * 3968 + 500 }, .{ .level = 4, .len = 70 }, .{ .level = 6, .len = 10 } };
    for (levels) |spec| {
        for (0..spec.len) |index| {
            const key = testKey(spec.level, 0, @intCast(index), 0);
            try inserts.append(testing.allocator, .{ .key = key, .contact = testContact(key), .emit = emittedCursorTestEmit(spec.level, index, spec.len) });
        }
    }
    try store.rebuild(testThreads(&serial_system), &.{.{ .inserts = inserts.items }}, 1, 0);
    try expectTreeValid(&store);
    try testing.expectEqual(@as(u8, 2), store.levels.items[2].height);
    var reference: std.ArrayList(u256) = .empty;
    defer reference.deinit(testing.allocator);
    for (std.enums.values(PairCount)) |kind| {
        reference.clearRetainingCapacity();
        for (inserts.items) |edit| if (countsAs(edit.emit, kind)) try reference.append(testing.allocator, edit.key);
        try testing.expectEqual(@as(u32, @intCast(reference.items.len)), store.countOf(kind));
        for (reference.items, 0..) |key, ordinal| {
            const cursor = store.emittedCursorAt(kind, @intCast(ordinal));
            try testing.expectEqual(key, cursor.key());
            try testing.expectEqual(key, cursor.page().keys[cursor.slot]);
        }
        var cursor = store.emittedCursorAt(kind, 0);
        for (reference.items, 1..) |key, taken| {
            try testing.expectEqual(key, cursor.key());
            if (taken < reference.items.len) _ = cursor.next();
        }
    }
}

test "collision trigger store rebuild bulk loads across page, node and node-squared boundaries" {
    var serial_system = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 0 });
    defer serial_system.deinit();
    var store = TriggerStore.init(testing.allocator);
    defer store.deinit();
    const sizes = [_]u32{ 1, 64, 65, 64 * 62, 64 * 62 + 1 };
    const heights = [_]u8{ 0, 0, 1, 1, 2 };
    var keys: std.ArrayList(u256) = .empty;
    defer keys.deinit(testing.allocator);
    for (sizes, 0..) |size, level| {
        for (0..size) |index| try keys.append(testing.allocator, testKey(@intCast(level * 2), 0, @intCast(index), 0));
    }
    try rebuildKeys(&store, testThreads(&serial_system), keys.items, 4);
    try expectTreeValid(&store);
    try expectStoredKeys(&store, keys.items);
    for (heights, 0..) |height, level| try testing.expectEqual(height, store.levels.items[level * 2].height);
    try testing.expect(store.ready);
    // One level past F² full pages grows a third inner height.
    keys.clearRetainingCapacity();
    for (0..64 * 62 * 62 + 1) |index| try keys.append(testing.allocator, testKey(1, 0, @intCast(index), 0));
    try rebuildKeys(&store, testThreads(&serial_system), keys.items, 1);
    try expectTreeValid(&store);
    try testing.expectEqual(@as(u8, 3), store.levels.items[1].height);
    try testing.expectEqual(@as(usize, 2), store.levels.items.len);
    // No pairs: an empty, ready store with no tree height to merge.
    try rebuildKeys(&store, testThreads(&serial_system), &.{}, 1);
    try expectTreeValid(&store);
    try testing.expect(store.ready);
    try testing.expectEqual(@as(usize, 0), store.levels.items.len);
}

test "collision trigger store growing patch under every allocation failure leaves the store unchanged, and the retry matches a rebuild" {
    var thread_system = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2 });
    defer thread_system.deinit();
    var store = TriggerStore.init(testing.allocator);
    defer store.deinit();
    var keys: [700]u256 = undefined;
    _ = testRunKeys(keys[0..400], 0, 0);
    _ = testRunKeys(keys[400..], 4, 0);
    try rebuildKeys(&store, testThreads(&thread_system), &keys, 2);
    // Inserts that split pages and grow the tree, a new level past the table end, and drops.
    var inserts: [300]u256 = undefined;
    for (inserts[0..250], 0..) |*key, index| key.* = testKey(0, 0, @intCast(index), 1);
    for (inserts[250..], 0..) |*key, index| key.* = testKey(40, 1, @intCast(index), 1);
    const drops = [_]u256{ keys[3], keys[401], keys[650] };
    var expected: std.ArrayList(u256) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, &keys);
    for (drops) |key| sortedRemove(&expected, key);
    for (inserts) |key| try sortedInsert(&expected, key);

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        store.allocator = failing.allocator();
        const result = patchKeys(&store, testThreads(&thread_system), &inserts, &drops, &.{}, 3, 7);
        store.allocator = testing.allocator;
        if (result) |_| {
            try testing.expect(!failing.has_induced_failure);
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(failing.has_induced_failure);
            try expectTreeValid(&store);
            try expectStoredKeys(&store, &keys);
            try testing.expectEqual(@as(u64, 1), store.seen_revision);
        }
    }
    try testing.expect(fail_index > 0);
    try expectTreeValid(&store);
    try expectStoredKeys(&store, expected.items);
    try testing.expectEqual(@as(u64, 7), store.seen_revision);
    try testing.expectEqual(@as(usize, 41), store.levels.items.len);
    var rebuilt = TriggerStore.init(testing.allocator);
    defer rebuilt.deinit();
    try rebuildKeys(&rebuilt, testThreads(&thread_system), expected.items, 1);
    try expectStoredKeys(&rebuilt, expected.items);
    try expectReadersMatch(&store, expected.items);
}

test "collision trigger store growing rebuild under every allocation failure leaves the store empty and not ready, and the retry matches" {
    var thread_system = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2 });
    defer thread_system.deinit();
    var store = TriggerStore.init(testing.allocator);
    defer store.deinit();
    var small: [100]u256 = undefined;
    try rebuildKeys(&store, testThreads(&thread_system), testRunKeys(&small, 0, 0), 2);
    // More pages than the first rebuild's slabs, a height-2 tree, and levels past the table end.
    var keys: [64 * 62 + 1 + 300]u256 = undefined;
    _ = testRunKeys(keys[0 .. 64 * 62 + 1], 2, 0);
    _ = testRunKeys(keys[64 * 62 + 1 ..], 30, 0);
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        store.allocator = failing.allocator();
        const result = rebuildKeys(&store, testThreads(&thread_system), &keys, 3);
        store.allocator = testing.allocator;
        if (result) |_| {
            try testing.expect(!failing.has_induced_failure);
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(failing.has_induced_failure);
            try testing.expect(!store.ready);
            try testing.expectEqual(@as(u32, 0), store.pair_count);
            try expectTreeValid(&store);
        }
    }
    try testing.expect(fail_index > 0);
    try testing.expect(store.ready);
    try expectTreeValid(&store);
    try expectStoredKeys(&store, &keys);
    try testing.expectEqual(@as(u8, 2), store.levels.items[2].height);
    try testing.expectEqual(@as(usize, 31), store.levels.items.len);
}

test "collision trigger store warm patches allocate nothing on a 2-worker pool" {
    var thread_system = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2 });
    defer thread_system.deinit();
    var store = TriggerStore.init(testing.allocator);
    defer store.deinit();
    var keys: [1500]u256 = undefined;
    _ = testRunKeys(keys[0..900], 0, 0);
    _ = testRunKeys(keys[900..], 2, 0);
    try rebuildKeys(&store, testThreads(&thread_system), &keys, 2);
    var inserts: [200]u256 = undefined;
    for (&inserts, 0..) |*key, index| key.* = testKey(if (index % 2 == 0) 0 else 2, 0, @intCast(index * 3), 5);
    // Insert then drop the same pairs: after one warm cycle the store's shape and scratch
    // repeat, so the reserves are warm.
    for (0..3) |cycle| {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        if (cycle == 2) store.allocator = failing.allocator();
        defer store.allocator = testing.allocator;
        try patchKeys(&store, testThreads(&thread_system), &inserts, &.{}, &.{}, 3, 2 * cycle + 2);
        try patchKeys(&store, testThreads(&thread_system), &.{}, &inserts, &.{}, 3, 2 * cycle + 3);
        try testing.expect(!failing.has_induced_failure);
        try testing.expectEqual(@as(usize, 0), failing.allocations);
    }
    try expectTreeValid(&store);
    try expectStoredKeys(&store, &keys);
}

// The refresh tests' pair `index`: a one-page level 0, a height-2 level 2 of three height-1
// subtrees, and a one-page level 5.
fn entityPairKey(index: usize) u256 {
    const level: u16 = if (index < 100) 0 else if (index < entity_pairs_level_end) 2 else 5;
    return testKey(level, 0, @intCast(index), 0);
}

const entity_pairs_level_end = 8600;

// Stored pairs naming `entities` in a chain, every row hint stale (row 0).
fn rebuildEntityPairs(store: *TriggerStore, threads: StoreThreads, entities: []const EntityId) !void {
    var inserts: std.ArrayList(InsertEdit) = .empty;
    defer inserts.deinit(testing.allocator);
    for (entities[0 .. entities.len - 1], entities[1..], 0..) |a, b, index| {
        const key = entityPairKey(index);
        var contact = testContact(key);
        contact.a = a;
        contact.b = b;
        contact.a_movement_index = 0;
        contact.b_movement_index = 0;
        try inserts.append(testing.allocator, .{ .key = key, .contact = contact, .emit = emit_valid | emit_allowed });
    }
    std.sort.pdq(InsertEdit, inserts.items, {}, struct {
        fn less(_: void, lhs: InsertEdit, rhs: InsertEdit) bool {
            return lhs.key < rhs.key;
        }
    }.less);
    try store.rebuild(threads, &.{.{ .inserts = inserts.items }}, 1, 0);
}

// Every stored pair's rows are its entities' movement rows (or `no_row`) and its emit bits
// their resolution and tiers; the page masks, node prefixes, level counts, rank and store
// sums count them.
fn expectRefreshed(store: *const TriggerStore, data: *const DataSystem) !void {
    try testing.expectEqual(data.collision_allow_epoch, store.refreshed_epoch.?);
    try expectTreeValid(store);
    const tier = data.scopeColumnsSliceConst().tier;
    var cursor = store.cursorAt(0);
    while (cursor.valid()) : (cursor.next()) {
        const at = cursor.page();
        const slot = cursor.offset;
        const a_row = data.movementBodyDenseIndex(at.a[slot]);
        const b_row = data.movementBodyDenseIndex(at.b[slot]);
        try testing.expectEqual(if (a_row) |row| @as(u32, @intCast(row)) else no_row, at.a_row[slot]);
        try testing.expectEqual(if (b_row) |row| @as(u32, @intCast(row)) else no_row, at.b_row[slot]);
        const emit: u8 = if (a_row == null or b_row == null) 0 else emit_valid | if (tier[a_row.?].allowsCollision() and tier[b_row.?].allowsCollision()) emit_allowed else 0;
        try testing.expectEqual(emit, at.emit[slot]);
    }
}

// Refresh ranges that start inside pages, hold some height-1 nodes whole and split others
// (one across several ranges), over a height-2 level whose nodes fold on main.
test "collision trigger store refresh re-resolves rows, emit bits and every count over several ranges, serial and 2 workers, and allocates nothing warm" {
    var serial_system = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 0 });
    defer serial_system.deinit();
    var thread_system = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2 });
    defer thread_system.deinit();
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    var entities: [entity_pairs_level_end + 400]EntityId = undefined;
    for (&entities, 0..) |*entity, index| {
        entity.* = try data.createEntity();
        const position = @as(f32, @floatFromInt(index));
        try data.setMovementBody(entity.*, .{ .position = .{ .x = position, .y = 0 }, .previous_position = .{ .x = position, .y = 0 } });
        try data.setSimulationTier(entity.*, if (index % 7 == 0) .dormant else .locomotion);
    }
    var serial = TriggerStore.init(testing.allocator);
    defer serial.deinit();
    var threaded = TriggerStore.init(testing.allocator);
    defer threaded.deinit();
    try rebuildEntityPairs(&serial, testThreads(&serial_system), &entities);
    try rebuildEntityPairs(&threaded, testThreads(&thread_system), &entities);
    try testing.expectEqual(@as(u8, 2), serial.levels.items[2].height);
    try testing.expect(serial.pair_count > 2 * refresh_range_alignment_items);
    // Uneven pages, so ranges start inside pages.
    var drops: [40]u256 = undefined;
    for (&drops, 0..) |*key, index| key.* = entityPairKey(index * 200 + 3);
    try patchKeys(&serial, testThreads(&serial_system), &.{}, &drops, &.{}, 1, 2);
    try patchKeys(&threaded, testThreads(&thread_system), &.{}, &drops, &.{}, 1, 2);
    // Destroys swap rows and move the epoch; one entity is left without a movement row.
    try testing.expect(data.destroyEntity(entities[5]));
    try testing.expect(data.destroyEntity(entities[200]));
    try testing.expect(serial.refresh(testThreads(&serial_system), &data));
    // The refresh keeps no range slots: the first one allocates nothing.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    threaded.allocator = failing.allocator();
    const ran = threaded.refresh(testThreads(&thread_system), &data);
    threaded.allocator = testing.allocator;
    try testing.expect(ran);
    try testing.expectEqual(@as(usize, 0), failing.allocations);
    try expectRefreshed(&serial, &data);
    try expectRefreshed(&threaded, &data);
    try testing.expectEqual(serial.valid_count, threaded.valid_count);
    try testing.expectEqual(serial.allowed_count, threaded.allowed_count);
    // A current epoch does not refresh; an allow crossing moves it.
    try testing.expect(!threaded.refresh(testThreads(&thread_system), &data));
    try data.setSimulationTier(entities[11], .dormant);
    try testing.expect(threaded.refresh(testThreads(&thread_system), &data));
    try expectRefreshed(&threaded, &data);
    // Ranges three alignments wide: some height-1 nodes lie whole in one range, whose worker
    // writes their prefixes, and the others split at a range edge, which main prefixes.
    try data.setSimulationTier(entities[12], .dormant);
    const wide: StoreThreads = .{ .thread_system = &thread_system, .config = .{ .items_per_range = 3 * refresh_range_alignment_items, .max_worker_threads = thread_system.workerThreadCount(), .adaptive = false } };
    try testing.expect(threaded.refresh(wide, &data));
    try testing.expect(serial.refresh(testThreads(&serial_system), &data));
    try expectRefreshed(&threaded, &data);
    try expectRefreshed(&serial, &data);
    try testing.expectEqual(serial.allowed_count, threaded.allowed_count);
}
