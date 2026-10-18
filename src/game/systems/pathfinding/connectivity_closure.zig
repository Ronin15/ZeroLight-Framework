// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Over the connectivity roots (`connectivity.zig`), the per-world one-way closure: a terminal
//! is a root holding an endpoint of a live one-way link, an H-component a weak component of
//! terminals over those links, and each H-component owns its reachability matrix (one row per
//! terminal) in a block of its own, freed with it. A batch touches the H-components its change
//! can reach, re-resolves their links (threaded per link), and recomputes only the rows whose
//! reach can change (mask threaded per row, SCC plan per piece, rows per SCC span in level
//! rounds); the main thread merges terminals and pieces and commits, O(1) per item. Blocks grow
//! by powers of two and narrow when under a quarter full; a relocated or new block is written
//! into the batch's reserved tail and landed (threaded per line) into its own allocation in the
//! same nav reaction. No batch reads or moves an untouched component's block.

const std = @import("std");
const WorldSystem = @import("../../world/system.zig").WorldSystem;
const LevelLink = @import("../../world/system.zig").LevelLink;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const BatchStats = @import("../../../app/thread_system.zig").BatchStats;
const Dispatch = @import("../../../app/thread_system.zig").Dispatch;
const RoundDispatch = @import("../../../app/thread_system.zig").RoundDispatch;
const accumulateBatch = @import("../../../app/thread_system.zig").accumulateBatch;
const runStage = @import("../../../app/thread_system.zig").runStage;
const NavGraph = @import("nav_graph.zig").NavGraph;
const BatchLevels = @import("nav_graph.zig").BatchLevels;
const chunkKey = @import("../chunk_list_map.zig").chunkKey;
const keyLevel = @import("../chunk_list_map.zig").keyLevel;
const keyChunk = @import("../chunk_list_map.zig").keyChunk;
const sortedContains = @import("nav_graph.zig").sortedContains;
const LabelSet = @import("nav_graph.zig").LabelSet;
const CellCoord = @import("../../world/system.zig").CellCoord;
const no_link_endpoint = @import("../../world/terrain.zig").no_link_endpoint;
const ChunkGeometry = @import("../../world/terrain.zig").ChunkGeometry;
const types = @import("types.zig");
const NavUpdateStats = types.NavUpdateStats;
const StageTimer = @import("../../../app/runtime_perf_log.zig").StageTimer;
const listBytesBound = @import("nav_graph.zig").listBytesBound;
const rowsBytesBound = @import("nav_graph.zig").rowsBytesBound;
const simd = @import("../../../core/simd.zig");
const Connectivity = @import("connectivity.zig").Connectivity;
const ElementColumns = @import("connectivity.zig").ElementColumns;
const GroupColumns = @import("connectivity.zig").GroupColumns;
const Neighbour = @import("connectivity.zig").Neighbour;
const StorageShape = @import("connectivity.zig").StorageShape;
const portalNode = @import("connectivity.zig").portalNode;
const forEachEdge = @import("connectivity.zig").forEachEdge;
const findRoot = @import("connectivity.zig").findRoot;
const uniteBySize = @import("connectivity.zig").uniteBySize;
const nodeKeyLevel = @import("connectivity.zig").nodeKeyLevel;
const growPool = @import("connectivity.zig").growPool;
const no_node = @import("connectivity.zig").no_node;
const no_root = @import("connectivity.zig").no_root;
const no_term = @import("connectivity.zig").no_term;
const no_oneway = @import("connectivity.zig").no_oneway;
const no_key = @import("connectivity.zig").no_key;

pub const no_hcomp: u32 = std.math.maxInt(u32);
pub const no_index: u32 = std.math.maxInt(u32);
const no_slot: u32 = std.math.maxInt(u32);
const no_piece: u32 = std.math.maxInt(u32);
const no_scc: u32 = std.math.maxInt(u32);
// A block's index map holds, per handed-out index, its terminal's id, or when the index is
// free the next free index (`no_index` ends the list). An entry is live exactly when the
// terminal it names points back to that index of that block.
// Words of one rows item's span and one landing line: a 64-byte cache line.
const span_words: usize = 16;

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

// An H-component: its block (`k_cap` rows of `rowWords(k_cap)` words, then `k_cap` index
// words: `blockWords(k_cap)`), its own allocation or, between a relocating commit and its
// landing, a slice of the batch tail; the indices handed out (`k_high`) and live, the head of
// its free index list, its one-way link list, and its batch slot and stamp. A free id has
// `k_cap == 0` and an empty block.
const HCompRow = struct {
    block: []align(64) u32,
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
    block: [][]align(64) u32 = &.{},
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

/// Words of one row of a block of `k_cap` indices.
pub fn rowWords(k_cap: u32) u32 {
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
    return std.math.ceilPowerOfTwoAssert(u32, terms + @divCeil(terms, 2));
}

/// Words of a block of `k_cap` indices: its rows and index map, padded to whole lines so every
/// block starts on a line.
pub fn blockWords(k_cap: u32) usize {
    const raw = @as(usize, k_cap) * (@as(usize, rowWords(k_cap)) + 1);
    return std.mem.alignForward(usize, raw, span_words);
}

/// The index map of H-component `id`'s block: `k_cap` words after its rows.
pub fn indexMap(hcomp: HCompColumns, id: u32) []u32 {
    const k_cap = hcomp.k_cap[id];
    return hcomp.block[id][@as(usize, k_cap) * rowWords(k_cap) ..][0..k_cap];
}

// Whether map entry `entry` at `index` of H-component `id` names a live terminal: one that
// points back to that index there. A free entry holds a local index or `no_index`, which no
// terminal of `id` at `index` can hold while the terminal columns invert the map.
fn liveEntry(term: TermColumns, id: u32, entry: u32, index: usize) bool {
    return entry < term.hcomp.len and term.hcomp[entry] == id and term.index[entry] == index;
}

/// One registered one-way endpoint a gather item saw: the registry row and both ends' node
/// keys after the patch (`no_key` for an end closed or on an unbuilt level), each with its row
/// before the merge (a hint for an end outside the batch's keys).
pub const OneWayEntry = struct {
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
// indices handed out and its free list (popped in the batch), whether it takes a new block
// and whether it narrows there (every terminal renumbered and recomputed), its terminal
// count, its A list window and SCCs, its link list, and a tally used while picking heirs.
const PieceRow = struct {
    inherit: u32,
    hcomp: u32,
    block: []align(64) u32,
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

// One kept terminal's old row (`words` words in its block) and the S window it is tested
// against.
const MaskItem = struct {
    slot: u32,
    row: [*]const u32,
    touch: u32,
    words: u32,
};

// One round-0 span of a block: its words `dst`, the first `src_len` copied from `src`, the
// rest zeroed (a zeroed span has `src_len == 0`).
const CopyItem = struct {
    dst: []u32,
    src: [*]const u32,
    src_len: u32,
};

// One rows item: an SCC (its A position) of a piece, and the 16-word span of its row.
const RowsItem = struct {
    piece: u32,
    scc: u32,
    span: u32,
};

// A block committed into the batch tail, waiting for its landing: its H-component, its tail
// word offset, and its own allocation (empty until the landing allocates it).
const LandBlock = struct {
    hcomp: u32,
    src: usize,
    dst: []align(64) u32,
};

// What one batch's closure stages may touch, bounded in prepare from counts: its candidate
// H-components (their count, terminals, links, capacities, row words, and block words), the
// dead links its keys take loose, the terminals it can pop (gross) and add net, whether a
// merge of components is possible, every terminal and piece it can number, the widest block
// a piece can take, and the reserves derived from them.
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
    copy_items: usize = 0,
    round_items: usize = 0,
    tail_words: usize = 0,
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

// The batch bound's sums over its groups: tail words, rows items, copy items, and the
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

/// The power-of-two block cap a block built or regrown for `terms` indices takes; at most
/// 2^31, so local indices stay below `no_index`.
pub fn boundCap(terms: usize) error{OutOfMemory}!u32 {
    // Passing 2^31 needs over 2^30 live terminals in one block, so it fails as the allocator
    // does.
    const cap = std.math.ceilPowerOfTwo(usize, terms) catch return error.OutOfMemory;
    if (cap > 1 << 31) return error.OutOfMemory;
    return @intCast(cap);
}

/// Counters of one batch's closure stages.
pub const ClosureCounters = struct {
    touched: usize = 0,
    links: usize = 0,
    terms_new: usize = 0,
    terms_left: usize = 0,
    a_rows: usize = 0,
    rounds: usize = 0,
    words_written: usize = 0,
    shrinks: usize = 0,
    // Tail words the relocated pieces' blocks took.
    tail_words: usize = 0,
    // Blocks allocated (a world build's exact blocks) and freed (retired or relocated).
    block_allocs: usize = 0,
    block_frees: usize = 0,
};

/// The per-world one-way closure: the registry of world links, the terminals (roots holding
/// an endpoint of a live one-way link), the H-components (weak components of terminals over
/// live links), each component's reachability matrix in its own block, and the batch staging
/// its stages share.
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
    // Words of every live block.
    live_words: usize = 0,
    // A batch's relocated and new blocks, written by its commit and landed into their own
    // allocations (`landResidents`) in order; `residents` names them. Empty after every nav
    // update, failed ones included, unless its landing failed too (`NavGraph.landClosure`).
    // `tail_limit` is the words a batch may place, assigned after the tail's reserve succeeds.
    tail: std.array_list.Aligned(u32, .@"64") = .empty,
    tail_limit: usize = 0,
    residents: std.ArrayList(LandBlock) = .empty,
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
    // Usize: a batch's round items sum spans over every SCC and may pass u32.
    round_starts: std.ArrayList(usize) = .empty,
    // Stage shapes of the most recent batch (stats and benches).
    last_resolve_batch: BatchStats = .{},
    last_mask_batch: BatchStats = .{},
    last_plan_batch: BatchStats = .{},
    last_rows_batch: BatchStats = .{},

    pub fn deinit(self: *Closure, allocator: std.mem.Allocator) void {
        // A resident's block lies in the tail; every other live block is its own allocation.
        const blocks = self.hcomps.items(.block);
        for (self.residents.items) |resident| blocks[resident.hcomp] = &.{};
        for (blocks) |block| {
            if (block.len != 0) allocator.free(block);
        }
        self.residents.deinit(allocator);
        self.tail.deinit(allocator);
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
        const word = self.hcomp.block[hcomp][@as(usize, self.term.index[from]) * rowWords(k_cap) + to_index / 32];
        return (word >> @intCast(to_index % 32)) & 1 != 0;
    }

    /// Re-takes the terminal and H-component column views after a pool grows.
    pub fn refreshColumns(self: *Closure) void {
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
    // pops never allocate. Pool growth is geometric and counted; ids stay below their
    // sentinels.
    fn ensureFreeIds(self: *Closure, allocator: std.mem.Allocator, terms: usize, hcomps: usize, pool_grows: *u64) !void {
        // The pools may move before a later step fails: the views follow them either way.
        defer self.refreshColumns();
        // Exhausting either pool needs 2^32 - 1 live rows of it (`growPool`: OutOfMemory).
        try growPool(TermRow, allocator, &self.terms, &self.term_free, terms, .{ .root = no_root, .hcomp = no_hcomp, .index = no_index, .slot = no_slot }, no_term, pool_grows);
        try growPool(HCompRow, allocator, &self.hcomps, &self.hcomp_free, hcomps, emptyHComp(), no_hcomp, pool_grows);
    }

    /// Bytes of the registry, the terminal and H-component pools, and the live blocks.
    pub fn bytes(self: *const Closure) usize {
        return self.oneway.capacity * @sizeOf(OneWayRow) +
            self.oneway_of_link.capacity * @sizeOf(u32) +
            self.terms.capacity * @sizeOf(TermRow) +
            self.term_free.capacity * @sizeOf(u32) +
            self.hcomps.capacity * @sizeOf(HCompRow) +
            self.hcomp_free.capacity * @sizeOf(u32) +
            self.live_words * @sizeOf(u32);
    }

    /// Bytes of the batch staging and the tail.
    pub fn stagingBytes(self: *const Closure) usize {
        return (self.cand_starts.capacity + self.ow_starts.capacity + self.round_starts.capacity) * @sizeOf(usize) +
            self.cand_tallies.capacity * @sizeOf(CandTally) +
            (self.cand_counts.capacity + self.cand_hcomps.capacity + self.ow_counts.capacity +
                self.freed_terms.capacity + self.s_words.capacity + self.s_list.capacity + self.loose.capacity +
                self.resolve_items.capacity + self.targets.capacity + self.leaving.capacity + self.plan_items.capacity) * @sizeOf(u32) +
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
            self.tail.capacity * @sizeOf(u32) +
            self.residents.capacity * @sizeOf(LandBlock);
    }
};

fn emptyHComp() HCompRow {
    return .{ .block = &.{}, .k_cap = 0, .k_high = 0, .k_live = 0, .index_free = no_index, .link_head = no_oneway, .link_tail = no_oneway, .link_count = 0, .slot = no_slot, .stamp = 0 };
}

/// One-way links among `links`.
pub fn countOneWay(links: []const LevelLink) usize {
    var count: usize = 0;
    for (links) |link| count += @intFromBool(!link.bidirectional);
    return count;
}

/// The closure's share of `storageBytesBound`: its one-way rows, terminal and H-component pools,
/// blocks and tail, and a batch's staging over `keys` keys holding at most `key_nodes` nodes. A batch holds at most every terminal as an old or popped
/// one, every one-way link live or loose, and blocks whose caps sum to twice the terminals.
pub fn closureBytesBound(shape: StorageShape, keys: usize, key_nodes: usize) usize {
    if (shape.oneway_links == 0) return 0;
    const terminals = 2 *| shape.oneway_links;
    const system = @max(1, @min(shape.system_terminals, terminals));
    // A block's cap is a power of two below twice its component's terminals.
    const cap_max = std.math.ceilPowerOfTwo(usize, 2 *| system) catch std.math.maxInt(usize);
    const row_words = @max(1, cap_max / 32);
    const spans = @divCeil(row_words, span_words);
    const live_words = 2 *| terminals *| (row_words +| 2) +| span_words *| terminals;
    const blocks = (3 *| live_words +| span_words *| terminals) *| @sizeOf(u32);
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
        listBytesBound(usize, 2 *| terminals +| 2) +| listBytesBound(LandBlock, terminals);
    return registry +| pools +| blocks +| staging;
}

// ----------------------------------------------------------------------------------------
// One-way closure: registry
// ----------------------------------------------------------------------------------------

/// Reserves the registry rows of `new_links`, the world links past the registry's cursor
/// that the next commit registers: a link-map entry each and a row per one-way link.
/// Growth is geometric and counted in `pool_grows`. O(1) per link; registers nothing.
pub fn reserveRegistry(self: *Connectivity, allocator: std.mem.Allocator, new_links: []const LevelLink, pool_grows: *u64) error{OutOfMemory}!void {
    const closure = &self.closure;
    const oneway_total = closure.oneway.len + countOneWay(new_links);
    const link_total = closure.oneway_cursor + new_links.len;
    // One row per world link at most, and `WorldSystem.reserveLevelLink` fails as
    // OutOfMemory at `no_link_endpoint / 2` (2^31 - 1) links (two u32 endpoint entries
    // each), so rows stay below `no_oneway` (2^32 - 1).
    std.debug.assert(oneway_total <= link_total and link_total <= no_link_endpoint / 2);
    try types.growList(&closure.oneway_of_link, allocator, link_total, pool_grows);
    try types.growList(&closure.oneway, allocator, oneway_total, pool_grows);
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
/// one-way ones on the built levels, and builds every H-component's matrix in a block of
/// its own, allocated exactly; its staging, sized to every link, is freed with the world
/// build's. Allocates; on error the caller discards the graph. Resolution
/// O(links) threaded, one allocation per component, Tarjan O(terminals + links) per
/// component, rows O((terminals + links) * row words) threaded.
pub fn buildClosure(self: *Connectivity, allocator: std.mem.Allocator, levels: BatchLevels, world: ?*const WorldSystem, threads: ClosureThreads, pool_grows: *u64, stats: *NavUpdateStats) error{OutOfMemory}!ClosureCounters {
    const world_system = world orelse return .{};
    const new_links = world_system.levelLinks()[self.closure.oneway_cursor..];
    try reserveRegistry(self, allocator, new_links, pool_grows);
    appendRegistry(self, new_links);
    const links = self.closure.oneway.len;
    if (links == 0) return .{};
    advanceStamp(self);
    // Every terminal is new, at most two per link, and every link is loose.
    var bounds = ClosureBounds{ .e_t = links, .loose = links, .n_gross = 2 * links, .n_net = 2 * links, .merge = true };
    try boundBatch(&bounds, &.{}, self.closure.hcomp);
    try reserveClosure(self, allocator, bounds, pool_grows);
    const closure = &self.closure;
    std.debug.assert(closure.residents.items.len == 0 and closure.tail.items.len == 0);
    closure.active = true;
    defer closure.active = false;
    closure.freed_terms.clearRetainingCapacity();
    closure.touched.len = 0;
    closure.resolve_items.clearRetainingCapacity();
    for (0..links) |row| closure.resolve_items.appendAssumeCapacity(@intCast(row));
    var counters = ClosureCounters{};
    resolveLinks(self, levels, world, threads.resolve, stats);
    const merge_timer = StageTimer.begin();
    mergeResolved(self, &counters);
    stats.main.closure_ns += merge_timer.lap();
    // Every piece is new and takes its exact block, at the build seam.
    const pieces = closure.pieces.slice();
    const blocks = pieces.items(.block);
    var allocated: usize = 0;
    errdefer for (blocks[0..allocated]) |block| allocator.free(block);
    for (pieces.items(.k_cap), blocks) |k_cap, *block| {
        block.* = try allocator.alignedAlloc(u32, .@"64", blockWords(k_cap));
        allocated += 1;
    }
    counters.block_allocs += allocated;
    finishClosure(self, allocator, threads, true, &counters, stats);
    return counters;
}

// ----------------------------------------------------------------------------------------
// One-way closure: prepare
// ----------------------------------------------------------------------------------------

fn advanceStamp(self: *Connectivity) void {
    const closure = &self.closure;
    if (closure.stamp >= std.math.maxInt(u32) - 3) {
        @memset(closure.hcomp.stamp, 0);
        @memset(closure.oneway.items(.stamp), 0);
        closure.stamp = 0;
    }
    closure.stamp += 2;
}

/// The closure's prepare over a batch's `keys`, before any record changes: per key its
/// gather one-way window (its link endpoints) and, when the registry holds a link, the
/// candidate scan (`conn_candidates`): the H-components of the old nodes' terminals when
/// `old_nodes`, of the registered one-way endpoints' links, and of every endpoint
/// partner's terminal, read through `levels` before the change, and the key's tallies.
/// `changed` flags a marks batch's remasked keys; null is a level build, whose every key
/// changed. Then on the main thread the candidates deduped by stamp in key order and
/// compacted, the tallies and the seed edges whose kept far end's root holds a terminal
/// summed, the batch bound, and its reserves, the batch tail among them. Any blocks a
/// failed landing left in the tail land first. O(1) per key, candidate entry, seed edge,
/// and distinct candidate on the main thread.
pub fn prepareClosure(
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
    // An earlier build's or a deferred landing's blocks leave the tail before the batch
    // touches any block.
    try landResidents(self, allocator, threads.land, stats);
    var section = StageTimer.begin();
    defer stats.main.reserve_ns += section.lap();
    const closure = &self.closure;
    advanceStamp(self);
    const scan = closure.oneway.len != 0;
    const window = &self.staging_window;
    window.note(.patch_keys, keys.len + 1);
    try types.resizeStaging(&closure.ow_starts, allocator, keys.len + 1, pool_grows);
    try types.resizeStaging(&closure.ow_counts, allocator, keys.len, pool_grows);
    if (scan) {
        try types.resizeStaging(&closure.cand_starts, allocator, keys.len + 1, pool_grows);
        try types.resizeStaging(&closure.cand_counts, allocator, keys.len, pool_grows);
        try types.resizeStaging(&closure.cand_tallies, allocator, keys.len, pool_grows);
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
    window.note(.ow_entries, ow_total);
    try types.resizeStaging(&closure.ow_entries, allocator, ow_total, pool_grows);

    // Every new link is loose, and each end of a new one-way link may pop a terminal.
    var bounds = ClosureBounds{ .loose = new_oneway };
    var revived_gross: usize = 0;
    var revived_net: usize = 0;
    var shared: usize = 2 * new_oneway;
    var opened = false;
    var distinct: usize = 0;
    if (scan) {
        closure.cand_starts.items[keys.len] = cand_total;
        window.note(.cand_entries, cand_total);
        try types.resizeStaging(&closure.cand_hcomps, allocator, cand_total, pool_grows);
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
        const batch = runStage(threads.candidates, keys.len, 1, &job, &job.range_count, candidateJob);
        section = StageTimer.begin();
        accumulateBatch(&stats.conn_closure_candidates_batch, batch);
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
    try reserveClosure(self, allocator, bounds, pool_grows);
    // The tail every relocated piece of the batch takes, on main before any closure
    // dispatch: a batch that can number no terminal places nothing.
    closure.tail_limit = 0;
    if (bounds.k_b != 0) {
        window.note(.tail, bounds.tail_words);
        try types.growList(&closure.tail, allocator, bounds.tail_words, pool_grows);
        closure.tail_limit = bounds.tail_words;
        std.debug.assert(closure.tail.capacity >= closure.tail_limit and closure.tail.items.len == 0);
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
    bounds.tail_words = sums.tail + 2 * bounds.n_net * (row_max + 1) + span_words * bounds.pieces;
    bounds.round_items = sums.rounds + bounds.n_gross * w_max;
    bounds.copy_items = sums.copies + 2 * bounds.n_net * spanCount(q_max) + bounds.pieces;
}

// Reserves every staging list the closure stages use for `bounds`, noting their needs in
// the release window, and the free terminal and H-component ids the merge pops. The S
// bitmap stays zero over its length.
fn reserveClosure(self: *Connectivity, allocator: std.mem.Allocator, bounds: ClosureBounds, pool_grows: *u64) !void {
    const closure = &self.closure;
    const window = &self.staging_window;
    try closure.ensureFreeIds(allocator, @min(bounds.n_gross, 2 * bounds.e_t), bounds.pieces, pool_grows);
    window.note(.closure_terms, bounds.k_c);
    try types.growList(&closure.freed_terms, allocator, bounds.k_c, pool_grows);
    try types.growList(&closure.leaving, allocator, bounds.k_c, pool_grows);
    try types.growList(&closure.freed_indices, allocator, bounds.k_c, pool_grows);
    window.note(.candidates, bounds.candidates);
    try types.growList(&closure.touched, allocator, bounds.candidates, pool_grows);
    // A growth zeroes its new words.
    window.note(.s_words, bounds.s_words);
    const s_before = closure.s_words.items.len;
    if (bounds.s_words > s_before) {
        try types.growList(&closure.s_words, allocator, bounds.s_words, pool_grows);
        closure.s_words.items.len = bounds.s_words;
        @memset(closure.s_words.items[s_before..], 0);
    }
    window.note(.k_cap_sum, bounds.k_cap_sum);
    try types.resizeStaging(&closure.s_list, allocator, bounds.k_cap_sum, pool_grows);
    window.note(.loose, bounds.loose);
    try types.growList(&closure.loose, allocator, bounds.loose, pool_grows);
    window.note(.links, bounds.e_t);
    inline for (.{ &closure.resolve_items, &closure.resolve_out, &closure.targets }) |list| {
        try types.growList(list, allocator, bounds.e_t, pool_grows);
    }
    window.note(.slots, bounds.k_b + 2);
    try types.growList(&closure.slots, allocator, bounds.k_b, pool_grows);
    try types.growList(&closure.apos, allocator, bounds.k_b, pool_grows);
    try types.growList(&closure.round_starts, allocator, bounds.k_b + 2, pool_grows);
    window.note(.pieces, bounds.pieces);
    try types.growList(&closure.pieces, allocator, bounds.pieces, pool_grows);
    try types.growList(&closure.plan_items, allocator, bounds.pieces, pool_grows);
    try types.growList(&closure.residents, allocator, bounds.pieces, pool_grows);
    const masks = @min(bounds.k_b, bounds.k_c);
    window.note(.masks, masks);
    try types.growList(&closure.mask_items, allocator, masks, pool_grows);
    window.note(.copy_items, bounds.copy_items);
    try types.growList(&closure.copy_items, allocator, bounds.copy_items, pool_grows);
    window.note(.round_items, bounds.round_items);
    try types.growList(&closure.round_items, allocator, bounds.round_items, pool_grows);
    // Assigned only after every reserve succeeded.
    closure.limits = bounds;
    closure.freed_terms.clearRetainingCapacity();
    std.debug.assert(closure.slots.capacity >= bounds.k_b and closure.pieces.capacity >= bounds.pieces and closure.resolve_items.capacity >= bounds.e_t);
    std.debug.assert(closure.residents.capacity >= bounds.pieces);
}

/// Lands the blocks the last relocating commit wrote into the batch tail, each into its
/// own exact allocation: every allocation first, so on `OutOfMemory` nothing changes and
/// the blocks stay valid in the tail; then one copy of the tail's lines
/// (`conn_closure_land`, a line per item); then each H-component's block switch, and the
/// tail empties. No-op with nothing in the tail. Main work O(1) per block.
pub fn landResidents(self: *Connectivity, allocator: std.mem.Allocator, threads: ?Dispatch, stats: *NavUpdateStats) error{OutOfMemory}!void {
    const closure = &self.closure;
    const residents = closure.residents.items;
    if (residents.len == 0) return;
    var section = StageTimer.begin();
    defer stats.main.reserve_ns += section.lap();
    const blocks = closure.hcomp.block;
    var allocated: usize = 0;
    errdefer for (residents[0..allocated]) |*resident| {
        allocator.free(resident.dst);
        resident.dst = &.{};
    };
    for (residents) |*resident| {
        resident.dst = try allocator.alignedAlloc(u32, .@"64", blocks[resident.hcomp].len);
        allocated += 1;
    }
    const lines = closure.tail.items.len / span_words;
    std.debug.assert(closure.tail.items.len % span_words == 0 and residents[0].src == 0);
    var job = LandJob{ .blocks = residents, .src = closure.tail.items };
    stats.main.reserve_ns += section.lap();
    const batch = runStage(threads, lines, 1, &job, &job.range_count, landJob);
    section = StageTimer.begin();
    accumulateBatch(&stats.conn_closure_land_batch, batch);
    stats.addStageTime(batch);
    for (residents) |*resident| {
        blocks[resident.hcomp] = resident.dst;
        resident.dst = &.{};
    }
    stats.closure_block_allocs += residents.len;
    stats.closure_landed_words += closure.tail.items.len;
    closure.residents.clearRetainingCapacity();
    closure.tail.items.len = 0;
}

// ----------------------------------------------------------------------------------------
// One-way closure: commit
// ----------------------------------------------------------------------------------------

/// Brings the closure up to date after `finish`: touches the H-components the batch can
/// change and collects their links and the dead links its keys hold, resolves them, merges
/// terminals and pieces, then recomputes the affected rows. Allocation-free after the
/// batch's closure reserve; frees the blocks it retires or relocates.
pub fn updateClosure(self: *Connectivity, allocator: std.mem.Allocator, levels: BatchLevels, world: ?*const WorldSystem, key_count: usize, threads: ClosureThreads, stats: *NavUpdateStats) ClosureCounters {
    // The prepare landed every earlier block: each block the commit frees is its own
    // allocation.
    std.debug.assert(self.closure.residents.items.len == 0 and self.closure.tail.items.len == 0);
    var counters = ClosureCounters{};
    const touch_timer = StageTimer.begin();
    touchClosure(self, levels, key_count);
    stats.main.closure_ns += touch_timer.lap();
    if (self.closure.resolve_items.items.len == 0) {
        self.closure.last_resolve_batch = .{};
        self.closure.last_mask_batch = .{};
        self.closure.last_plan_batch = .{};
        self.closure.last_rows_batch = .{};
        return counters;
    }
    resolveLinks(self, levels, world, threads.resolve, stats);
    const merge_timer = StageTimer.begin();
    mergeResolved(self, &counters);
    stats.main.closure_ns += merge_timer.lap();
    finishClosure(self, allocator, threads, false, &counters, stats);
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
    for (closure.freed_terms.items) |term| touchHComp(self, closure.term.hcomp[term], &s_cursor, &list_cursor);
    const groups = GroupColumns.of(self.groups.slice());
    for (0..self.groups.len) |group| {
        if (groups.set_count[group] == 0 and groups.root_count[group] < 2) continue;
        for (self.group_roots.items[groups.root_start[group]..][0..groups.root_count[group]]) |root| {
            const term = self.root_term[root];
            if (term != no_term) touchHComp(self, closure.term.hcomp[term], &s_cursor, &list_cursor);
        }
    }
    const oneway = OneWayColumns.of(closure.oneway.slice());
    const elements = ElementColumns.of(self.elements.slice());
    for (0..key_count) |item| {
        for (closure.ow_entries.items[closure.ow_starts.items[item]..][0..closure.ow_counts.items[item]]) |entry| {
            const hcomp = oneway.hcomp[entry.oneway];
            if (hcomp != no_hcomp) {
                touchHComp(self, hcomp, &s_cursor, &list_cursor);
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
                if (term != no_term) touchHComp(self, closure.term.hcomp[term], &s_cursor, &list_cursor);
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
fn resolveLinks(self: *Connectivity, levels: BatchLevels, world: ?*const WorldSystem, threads: ?Dispatch, stats: *NavUpdateStats) void {
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
    closure.last_resolve_batch = runStage(threads, count, 1, &job, &job.range_count, resolveJob);
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
fn adoptTerm(self: *Connectivity, root: u32, term: u32) void {
    const closure = &self.closure;
    std.debug.assert(term != no_term);
    if (self.root_term[root] != no_term or closure.term.root[term] != no_root) return;
    self.root_term[root] = term;
    closure.term.root[term] = root;
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
    indexMap(closure.hcomp, id)[index] = pieces.free_head[piece];
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
// SIMD verdict: scalar. Union-find, first-sight numbering, and free-list pops per link and
// slot on the main thread (data-dependent), O(1)/O(α) each.
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
        adoptTerm(self, out.src_root, oneway.src_term[link]);
        adoptTerm(self, out.dst_root, oneway.dst_term[link]);
    }
    for (items, outs) |link, out| {
        const old_live = oneway.hcomp[link] != no_hcomp;
        var src_term = no_term;
        var dst_term = no_term;
        if (out.live) {
            src_term = termOfRoot(self, out.src_root, counters);
            dst_term = termOfRoot(self, out.dst_root, counters);
            const src_slot = slotOf(self, slots, src_term, &slot_count);
            const dst_slot = slotOf(self, slots, dst_term, &slot_count);
            _ = uniteBySize(slots.parent, slots.size, src_slot, dst_slot);
            if (src_term != dst_term) {
                slots.out_count[src_slot] += 1;
                live_edges += 1;
            }
        }
        const changed = old_live != out.live or (out.live and (oneway.src_term[link] != src_term or oneway.dst_term[link] != dst_term));
        if (changed) {
            if (old_live) addS(self, touched, oneway.src_term[link]);
            if (out.live) addS(self, touched, src_term);
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
            pieces.block[piece] = &.{};
            pieces.k_cap[piece] = 0;
            pieces.k_high[piece] = 0;
            pieces.free_head[piece] = no_index;
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
    // of its terminals (ties to the lower piece). The walk precedes every index freed in
    // the batch, so the committed terminal columns still invert each map.
    const hcomp = closure.hcomp;
    closure.leaving.clearRetainingCapacity();
    for (0..closure.touched.len) |touch| {
        const id = touched.hcomp[touch];
        const map = indexMap(hcomp, id)[0..hcomp.k_high[id]];
        var heir: u32 = no_piece;
        var heir_count: u32 = 0;
        for (map, 0..) |entry, index| {
            if (!liveEntry(closure.term, id, entry, index)) continue;
            const slot = closure.term.slot[entry];
            if (slot == no_slot) {
                std.debug.assert(closure.leaving.items.len < closure.leaving.capacity);
                closure.leaving.appendAssumeCapacity(entry);
                addS(self, touched, entry);
                continue;
            }
            const piece = slots.piece[slot];
            pieces.tally[piece] += 1;
            if (pieces.tally[piece] > heir_count or (pieces.tally[piece] == heir_count and piece < heir)) {
                heir = piece;
                heir_count = pieces.tally[piece];
            }
        }
        for (map, 0..) |entry, index| {
            if (!liveEntry(closure.term, id, entry, index)) continue;
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
            pieces.free_head[piece] = no_index;
        }
    }
    // Every index the batch frees in an inherited block, before any is handed out: the
    // leaving terminals', then the moved-out ones' in slot order. Each goes onto its
    // heir's free list through the old index map (round 0 zeroes its row) and may be
    // taken in this batch: its old row is in S, so every kept row reaching it is in A.
    closure.freed_indices.clearRetainingCapacity();
    for (closure.leaving.items) |term| freeIndex(self, touched, pieces, hcomp.slot[closure.term.hcomp[term]], closure.term.index[term]);
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
        addS(self, touched, term);
        freeIndex(self, touched, pieces, hcomp.slot[old], closure.term.index[term]);
    }

    // Indices in slot order: each recomputed terminal takes a free index of its piece's
    // block, or the next one.
    for (0..slot_count) |slot| {
        if (slots.kept[slot]) continue;
        const piece = slots.piece[slot];
        const inherit = pieces.inherit[piece];
        if (pieces.free_head[piece] != no_index) {
            const index = pieces.free_head[piece];
            pieces.free_head[piece] = indexMap(hcomp, touched.hcomp[inherit])[index];
            slots.index[slot] = index;
        } else {
            slots.index[slot] = pieces.k_high[piece];
            pieces.k_high[piece] += 1;
        }
    }
    // A piece outgrowing its block, new, or narrowing takes a new block. Every freed index
    // was offered first, so it holds no hole.
    for (0..piece_count) |piece| {
        if (pieces.inherit[piece] != no_slot and pieces.k_high[piece] <= pieces.k_cap[piece] and !pieces.compact[piece]) continue;
        std.debug.assert(pieces.k_high[piece] == pieces.terms[piece]);
        pieces.relocated[piece] = true;
        if (pieces.compact[piece]) {
            pieces.k_cap[piece] = compactCap(pieces.k_high[piece]);
            counters.shrinks += 1;
        } else {
            // At most 2^31: the prepare bounded the largest block (`boundCap`).
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
        const row = hcomp.block[id][@as(usize, slots.index[slot]) * words ..][0..words];
        closure.mask_items.appendAssumeCapacity(.{ .slot = @intCast(slot), .row = row.ptr, .touch = @intCast(touch), .words = words });
    }
}

// The mask (`conn_closure_mask`), each piece's A list, the plan
// (`conn_closure_plan`: CSR walk, Tarjan, SCC levels), block assignment and round lists,
// the rows (`conn_closure_rows`, rounds under one profile), and the commit. With `preset`
// every relocated piece already holds its own block (a world build); else each takes the
// tail.
fn finishClosure(self: *Connectivity, allocator: std.mem.Allocator, threads: ClosureThreads, preset: bool, counters: *ClosureCounters, stats: *NavUpdateStats) void {
    const closure = &self.closure;
    const slots = SlotColumns.of(closure.slots.slice());
    const pieces = PieceColumns.of(closure.pieces.slice());
    const touched = TouchColumns.of(closure.touched.slice());
    const slot_count = closure.slots.len;
    const piece_count = closure.pieces.len;

    // Mask.
    var mask = MaskJob{
        .items = closure.mask_items.items,
        .s_words = closure.s_words.items,
        .s_list = closure.s_list.items,
        .s_start = touched.s_start,
        .s_list_start = touched.s_list_start,
        .s_count = touched.s_count,
        .a_flag = slots.a_flag,
    };
    closure.last_mask_batch = runStage(threads.mask, closure.mask_items.items.len, 1, &mask, &mask.range_count, maskJob);
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
    var plan = SccPlanJob{
        .items = closure.plan_items.items,
        .pieces = pieces,
        .slots = slots,
        .targets = closure.targets.items,
        .apos = apos,
    };
    stats.main.closure_ns += section.lap();
    closure.last_plan_batch = runStage(threads.plan, closure.plan_items.items.len, 1, &plan, &plan.range_count, sccPlanJob);
    stats.addStageTime(closure.last_plan_batch);
    section = StageTimer.begin();

    // Blocks, then the round-0 copy and zero spans, then the round lists.
    assignBlocks(self, slots, pieces, touched, preset, counters);
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
        commitClosure(self, allocator, slots, pieces, touched, preset, counters);
        stats.main.closure_ns += section.lap();
        return;
    }
    stats.main.closure_ns += section.lap();
    var dispatch = RoundDispatch.begin(threads.rows, closure.copy_items.items.len + round_total);
    if (closure.copy_items.items.len != 0) {
        var copy = CopyJob{ .items = closure.copy_items.items };
        dispatch.run(closure.copy_items.items.len, &copy, &copy.range_count, copyJob);
    }
    for (0..rounds) |level| {
        const round_slice = closure.round_items.items[closure.round_starts.items[level]..closure.round_starts.items[level + 1]];
        if (round_slice.len == 0) continue;
        var rows = RowsJob{
            .items = round_slice,
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
    for (closure.copy_items.items) |item| counters.words_written += item.dst.len;
    for (closure.plan_items.items) |piece| counters.words_written += @as(usize, pieces.a_count[piece]) * rowWords(pieces.k_cap[piece]);

    commitClosure(self, allocator, slots, pieces, touched, preset, counters);
    stats.main.closure_ns += section.lap();
}

// Block assignment and round-0 spans, in piece order: a relocated piece takes its preset
// block or the next tail block (its old block, if any, leaves the live words) and gets
// copies of its kept rows outside A (widened, zero tail) and zeroed rows for every other
// index outside A; a piece in place gets its freed indices' rows zeroed. O(1) per piece
// and span.
fn assignBlocks(self: *Connectivity, slots: SlotColumns, pieces: PieceColumns, touched: TouchColumns, preset: bool, counters: *ClosureCounters) void {
    const closure = &self.closure;
    const hcomp = closure.hcomp;
    closure.copy_items.clearRetainingCapacity();
    for (0..closure.pieces.len) |piece| {
        if (!pieces.relocated[piece]) continue;
        const words = blockWords(pieces.k_cap[piece]);
        if (preset) {
            std.debug.assert(pieces.block[piece].len == words);
        } else {
            const offset = closure.tail.items.len;
            std.debug.assert(offset % span_words == 0 and offset + words <= closure.tail_limit);
            closure.tail.items.len = offset + words;
            // Blocks span whole 16-word lines, so each starts 64-byte aligned in the tail.
            pieces.block[piece] = @alignCast(closure.tail.items[offset..][0..words]);
            counters.tail_words += words;
        }
        closure.live_words += words;
        const block = pieces.block[piece];
        const row_words = rowWords(pieces.k_cap[piece]);
        // Unused indices past those handed out: one zeroed range.
        zeroWords(self, block, @as(usize, pieces.k_high[piece]) * row_words, @as(usize, pieces.k_cap[piece] - pieces.k_high[piece]) * row_words);
        const inherit = pieces.inherit[piece];
        if (inherit == no_slot) continue;
        const id = touched.hcomp[inherit];
        closure.live_words -= blockWords(hcomp.k_cap[id]);
        // The inherited block's free indices nobody took.
        const old_map = indexMap(hcomp, id);
        var free = pieces.free_head[piece];
        while (free != no_index) : (free = old_map[free]) {
            zeroWords(self, block, @as(usize, free) * row_words, row_words);
        }
    }
    for (closure.freed_indices.items) |freed| {
        const piece = touched.kept_by[freed.touch];
        const row_words = rowWords(pieces.k_cap[piece]);
        zeroWords(self, pieces.block[piece], @as(usize, freed.index) * row_words, row_words);
    }
    for (0..closure.slots.len) |slot| {
        const piece = slots.piece[slot];
        if (!pieces.relocated[piece] or !slots.kept[slot] or slots.a_flag[slot]) continue;
        const id = touched.hcomp[pieces.inherit[piece]];
        const old_words = rowWords(hcomp.k_cap[id]);
        const new_words = rowWords(pieces.k_cap[piece]);
        const src = hcomp.block[id][@as(usize, slots.index[slot]) * old_words ..][0..old_words];
        const dst = pieces.block[piece][@as(usize, slots.index[slot]) * new_words ..][0..new_words];
        var start: usize = 0;
        while (start < new_words) : (start += span_words) {
            const len = @min(span_words, new_words - start);
            const src_len = if (start >= old_words) 0 else @min(len, old_words - start);
            appendCopy(self, .{ .dst = dst[start..][0..len], .src = if (src_len == 0) dst[start..].ptr else src[start..].ptr, .src_len = @intCast(src_len) });
        }
    }
}

// Zeroes `len` words of `block` from `start` in round 0, one span per item.
fn zeroWords(self: *Connectivity, block: []u32, start: usize, len: usize) void {
    const words = block[start..][0..len];
    var offset: usize = 0;
    while (offset < len) : (offset += span_words) {
        const span = words[offset..][0..@min(span_words, len - offset)];
        appendCopy(self, .{ .dst = span, .src = span.ptr, .src_len = 0 });
    }
}

fn appendCopy(self: *Connectivity, item: CopyItem) void {
    const closure = &self.closure;
    std.debug.assert(closure.copy_items.items.len < closure.limits.copy_items);
    closure.copy_items.appendAssumeCapacity(item);
}

// The commit, in order: each piece's H-component id (inherited, or popped), the links
// relinked per piece (dead ones off every list), dead components and their blocks freed,
// each piece's row, index map (a relocated one's copied first, its old block then freed),
// free list, and, for a tail block, its landing entry; every slot's terminal, every leaving
// terminal freed, and the S windows cleared. O(1) per terminal, link, and piece, plus one
// free per freed block; the blocks it frees are their own allocations (`allocator`'s).
fn commitClosure(self: *Connectivity, allocator: std.mem.Allocator, slots: SlotColumns, pieces: PieceColumns, touched: TouchColumns, preset: bool, counters: *ClosureCounters) void {
    const closure = &self.closure;
    const hcomp = closure.hcomp;
    const term = closure.term;
    const oneway = OneWayColumns.of(closure.oneway.slice());
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
        closure.live_words -= blockWords(hcomp.k_cap[id]);
        allocator.free(hcomp.block[id]);
        counters.block_frees += 1;
        const stamp = hcomp.stamp[id];
        closure.hcomps.set(id, emptyHComp());
        hcomp.stamp[id] = stamp;
        std.debug.assert(closure.hcomp_free.items.len < closure.hcomp_free.capacity);
        closure.hcomp_free.appendAssumeCapacity(id);
    }
    // Tail blocks follow piece order from the tail's start.
    var tail_offset: usize = 0;
    for (0..closure.pieces.len) |piece| {
        const id = pieces.hcomp[piece];
        const inherit = pieces.inherit[piece];
        const map_start = @as(usize, pieces.k_cap[piece]) * rowWords(pieces.k_cap[piece]);
        if (pieces.relocated[piece] and inherit != no_slot) {
            if (!pieces.compact[piece]) {
                const k_high = hcomp.k_high[id];
                @memcpy(pieces.block[piece][map_start..][0..k_high], indexMap(hcomp, id)[0..k_high]);
            }
            allocator.free(hcomp.block[id]);
            counters.block_frees += 1;
        }
        if (pieces.relocated[piece] and !preset) {
            std.debug.assert(pieces.block[piece].ptr == closure.tail.items[tail_offset..].ptr);
            std.debug.assert(closure.residents.items.len < closure.limits.pieces);
            closure.residents.appendAssumeCapacity(.{ .hcomp = id, .src = tail_offset, .dst = &.{} });
            tail_offset += pieces.block[piece].len;
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
    std.debug.assert(tail_offset == closure.tail.items.len);
    for (0..closure.slots.len) |slot| {
        const id = slots.term[slot];
        const piece = slots.piece[slot];
        term.hcomp[id] = pieces.hcomp[piece];
        term.index[id] = slots.index[slot];
        term.slot[id] = no_slot;
        indexMap(hcomp, pieces.hcomp[piece])[slots.index[slot]] = id;
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

// ----------------------------------------------------------------------------------------
// One-way closure stages
// ----------------------------------------------------------------------------------------

/// Threading for the closure stages, each with its own tuner; a null stage runs inline.
pub const ClosureThreads = struct {
    candidates: ?Dispatch = null,
    resolve: ?Dispatch = null,
    mask: ?Dispatch = null,
    plan: ?Dispatch = null,
    rows: ?Dispatch = null,
    land: ?Dispatch = null,
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
    block: [][]align(64) u32,
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
    return @divCeil(rowWords(k_cap), @as(u32, span_words));
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
// its link: one terminal per such cell however many endpoints it holds (a cell is one node),
// plus one per link whose partner end was open (net: when the partner's root held no
// terminal). The key's split counts the distinct endpoint cells open before and after
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
        return sortedContains(self.keys, key);
    }
};

// Labels of one key's qualifying endpoint cells that hold an old edge.
const SplitEdges = struct {
    labels: *const LabelSet,
    edged: LabelSet = .empty,

    /// `forEachEdge`'s visitor: notes the edge's label when it is a qualifying one.
    pub fn visit(self: *SplitEdges, label: u8, _: Neighbour) void {
        if (self.labels.isSet(label)) self.edged.set(label);
    }
};

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
            // The world's tiling: `level` may be the one being built, absent from `levels`.
            const geometry = ChunkGeometry.init(world.width, world.height, world.chunk_size_tiles);
            // The distinct qualifying endpoint cells (chunk-local) and their old labels, and the
            // distinct newly opened endpoint cells.
            var cells: LabelSet = .empty;
            var labels: LabelSet = .empty;
            var opened_cells: LabelSet = .empty;
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
                        const partner_chunk = geometry.chunkOf(endpoint.other_cell.x, endpoint.other_cell.y);
                        const own_order = cellOrder(world, level, endpoint.cell);
                        const partner_order = cellOrder(world, endpoint.other_level, endpoint.other_cell);
                        if (!job.isKey(chunkKey(endpoint.other_level, partner_chunk)) or own_order <= partner_order) tally.loose += 1;
                    }
                    if (changed and !world.levelBlocksMovement(level, endpoint.cell.x, endpoint.cell.y)) {
                        if (portalNode(job.levels, level, endpoint.cell.x, endpoint.cell.y)) |own| {
                            const own_row = job.levels.graph(level).nodeOf(own.chunk, own.label);
                            if (own_row != no_node and job.nodeTerm(level, own_row) != no_term) {
                                const local = geometry.localOf(endpoint.cell.x, endpoint.cell.y);
                                if (!cells.isSet(local)) {
                                    cells.set(local);
                                    cell_count += 1;
                                    labels.set(own.label);
                                }
                            }
                        } else if (dead) {
                            const partner_bare = partner != null and (partner_row == no_node or job.nodeTerm(partner.?.level, partner_row) == no_term);
                            // A cell lies in one chunk, so in one key: the set dedupes it fully.
                            const local = geometry.localOf(endpoint.cell.x, endpoint.cell.y);
                            const own: u32 = @intFromBool(!opened_cells.isSet(local));
                            opened_cells.set(local);
                            tally.new_gross += own + @as(u32, @intFromBool(partner != null));
                            tally.new_net += own + @as(u32, @intFromBool(partner_bare));
                        }
                    }
                }
                if (partner_row == no_node) continue;
                const hcomp = job.nodeHComp(partner.?.level, partner_row) orelse continue;
                window[written] = hcomp;
                written += 1;
            }
            // At most 128 labels and 256 cells a chunk.
            const label_count: u32 = @intCast(labels.count());
            if (label_count != 0) {
                var edges = SplitEdges{ .labels = &labels };
                forEachEdge(job.levels, job.world, level, chunk, null, .mirrors_and_links, &edges);
                const edged: u32 = @intCast(edges.edged.count());
                tally.split = cell_count - label_count + edged;
            }
        }
        std.debug.assert(written <= window.len);
        job.counts[item] = @intCast(written);
        job.tallies[item] = tally;
    }
}

// A cell's order for picking one end of a link: its level, then its row-major index.
fn cellOrder(world: *const WorldSystem, level: u16, cell: CellCoord) u64 {
    return (@as(u64, level) << 32) | (@as(u64, cell.y) * world.width + cell.x);
}

// The landing: copies the tail's blocks into their own allocations, one 16-word line per
// item; a line finds its block by binary search over the blocks' tail offsets. Each item
// writes only its line of one destination.
const LandJob = struct {
    blocks: []const LandBlock,
    src: []const u32,
    range_count: usize = 0,
};

// SIMD verdict: `@memcpy` per line.
fn landJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *LandJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end * span_words <= job.src.len);
    // The first block starts at the tail's start, so every line has a block at or before it.
    std.debug.assert(range.start == range.end or job.blocks[0].src == 0);
    for (range.start..range.end) |line| {
        const block = job.blocks[std.sort.upperBound(LandBlock, job.blocks, line, orderLineSrc) - 1];
        const offset = line * span_words - block.src;
        std.debug.assert(offset + span_words <= block.dst.len);
        @memcpy(block.dst[offset..][0..span_words], job.src[line * span_words ..][0..span_words]);
    }
}

fn orderLineSrc(line: usize, block: LandBlock) std.math.Order {
    return std.math.order(line, block.src / span_words);
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

    fn rootAt(self: *const ResolveJob, level: u16, cell: CellCoord) ?u32 {
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
        std.debug.assert(item.slot < job.a_flag.len);
        const row = item.row[0..item.words];
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
const SccPlanJob = struct {
    items: []const u32,
    pieces: PieceColumns,
    slots: SlotColumns,
    targets: []const u32,
    apos: APosColumns,
    range_count: usize = 0,
};

// SIMD verdict: scalar. An irreducible depth-first search.
fn sccPlanJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *SccPlanJob = @ptrCast(@alignCast(context));
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

// The rows' round 0: copies and zeroes spans of the batch's blocks. Each item writes only its
// span.
const CopyJob = struct {
    items: []const CopyItem,
    range_count: usize = 0,
};

// SIMD verdict: `@memcpy`/`@memset` per span.
fn copyJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *CopyJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.items.len);
    for (job.items[range.start..range.end]) |item| {
        // Each item writes only its span, sliced from its block on main.
        std.debug.assert(item.src_len <= item.dst.len and item.dst.len <= span_words);
        @memcpy(item.dst[0..item.src_len], item.src[0..item.src_len]);
        @memset(item.dst[item.src_len..], 0);
    }
}

// The rows' later rounds: per (SCC, span), the span of the SCC's row (its members' bits ORed with
// the rows of every terminal its members reach in one link outside the SCC: earlier rounds'
// rows or kept rows), written into each member's row. Each item writes only its members'
// spans; it reads rows no item of its round writes.
const RowsJob = struct {
    items: []const RowsItem,
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
        const block = job.pieces.block[item.piece];
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
                const row = @as(usize, slots.index[target]) * row_words + word_start;
                std.debug.assert(row + len <= block.len);
                orInto(acc[0..len], block[row..][0..len]);
            }
        }
        for (members) |member| {
            const row = @as(usize, slots.index[member]) * row_words + word_start;
            @memcpy(block[row..][0..len], acc[0..len]);
        }
    }
}

// ----------------------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------------------

const test_support = @import("test_support.zig");
const PathfindingSystem = @import("system.zig").PathfindingSystem;
const TileId = @import("../../world/system.zig").TileId;
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const SimulationFrame = @import("../../simulation.zig").SimulationFrame;
const runtime_perf_log = @import("../../../app/runtime_perf_log.zig");
const no_colliders = &test_support.no_colliders;
const reach = @import("connectivity.zig").reach;
const StagingSizes = @import("connectivity.zig").StagingSizes;
const storageBytesBound = @import("connectivity.zig").storageBytesBound;
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

// Asserts the closure staging of `conn` is held for one batch's per-key windows over `keep`'s
// patch keys, and every other closure list for nothing.
fn expectClosureStagingWithin(conn: *const Connectivity, keep: StagingSizes) !void {
    const t = std.testing;
    const closure = &conn.closure;
    inline for (.{ &closure.cand_starts, &closure.ow_starts, &closure.cand_counts, &closure.cand_tallies, &closure.ow_counts }) |list| {
        try t.expect(types.stagingHeld(list, keep.patch_keys + 1));
    }
    inline for (.{
        &closure.cand_hcomps, &closure.ow_entries,    &closure.freed_terms, &closure.touched,
        &closure.s_words,     &closure.s_list,        &closure.loose,       &closure.resolve_items,
        &closure.resolve_out, &closure.slots,         &closure.targets,     &closure.pieces,
        &closure.leaving,     &closure.freed_indices, &closure.mask_items,  &closure.plan_items,
        &closure.apos,        &closure.copy_items,    &closure.round_items, &closure.round_starts,
        &closure.tail,        &closure.residents,
    }) |list| try t.expect(types.stagingHeld(list, 0));
}

// Runs `steps` steps with no nav change.
fn quietSteps(fixture: *TestWorld, system: *PathfindingSystem, steps: usize) !void {
    for (0..steps) |_| {
        const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        try std.testing.expectEqual(@as(usize, 0), stats.incremental_rebuilds);
    }
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

test "a world build with one-way links frees its closure staging when it ends" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, 0, 32);
    const window: u32 = 4;
    var system = try fixture.build(windowCapacity(window));
    defer system.deinit();
    const conn = &system.graph.connectivity;
    try std.testing.expectEqual(@as(usize, 32), test_support.closureTermCount(conn.closure));
    const keep = conn.oneChunkStaging(system.graph.levelGraph(0).?.border_stride);
    try expectStagingWithin(conn, keep);
    try expectClosureStagingWithin(conn, keep);
    try expectGraphStagingWithin(&system.graph);
    try fixture.expectMatchesRebuild(&system);
}

test "a one-way world's single dig stays allocation-free after its closure staging is released" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, 0, 16);
    const window: u32 = 4;
    var system = try fixture.build(windowCapacity(window));
    defer system.deinit();
    const conn = &system.graph.connectivity;
    // The dig and its refill, each one chunk, set the closure floor.
    try setRoom(&fixture, &system, chunks, 0, 5, fixture.tree);
    const dug = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expect(dug.closure_links != 0);
    try setRoom(&fixture, &system, chunks, 0, 5, fixture.grass);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    // A dense change through the chain grows the closure staging; two quiet windows free it.
    for (0..8) |index| try setRoom(&fixture, &system, chunks, 0, index, fixture.tree);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    for (0..8) |index| try setRoom(&fixture, &system, chunks, 0, index, fixture.grass);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    const dense_staging = conn.stagingBytes();
    try quietSteps(&fixture, &system, 2 * window);
    try std.testing.expect(conn.stagingBytes() < dense_staging);
    // The same dig again: its prepare neither shrinks nor grows anything.
    try setRoom(&fixture, &system, chunks, 0, 5, fixture.tree);
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
// resolve and loose lists, copy and rows items, the relocated blocks' caps, and the tail words
// they took; and every block landed. An update that also built levels checks only its tail
// words.
fn expectWithinBounds(closure: *const Closure, stats: NavUpdateStats) !void {
    const t = std.testing;
    try t.expect(stats.closure_tail_used <= stats.closure_tail_bound);
    try t.expectEqual(@as(usize, 0), closure.residents.items.len);
    try t.expectEqual(@as(usize, 0), closure.tail.items.len);
    if (stats.closure_links == 0 or stats.levels_built != 0) return;
    const limits = closure.limits;
    try t.expect(stats.closure_terms_new <= limits.n_gross);
    try t.expect(closure.slots.len <= limits.k_c + limits.n_net);
    try t.expect(closure.slots.len <= limits.k_b and closure.pieces.len <= limits.pieces);
    try t.expect(closure.resolve_items.items.len <= limits.e_t and closure.loose.items.len <= limits.loose);
    try t.expect(closure.copy_items.items.len <= limits.copy_items and closure.round_items.items.len <= limits.round_items);
    try t.expect(stats.closure_tail_used <= limits.tail_words);
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
    try std.testing.expectEqual(@as(usize, 2), test_support.closureHcompCount(system.graph.connectivity.closure));
    // A link within one component, then one joining two.
    try addOneWay(&fixture, 0, latticeRoom(chunks, 3), 0, latticeRoom(chunks, 1));
    _ = try applyWithinBounds(&fixture, &system);
    try fixture.expectMatchesRebuild(&system);
    try addOneWay(&fixture, 0, latticeRoom(chunks, 3), 1, latticeRoom(chunks, 40));
    try addOneWay(&fixture, 1, latticeRoom(chunks, 40), 0, latticeRoom(chunks, 10));
    _ = try applyWithinBounds(&fixture, &system);
    try fixture.expectMatchesRebuild(&system);
    try std.testing.expectEqual(@as(usize, 1), test_support.closureHcompCount(system.graph.connectivity.closure));
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
    const terms = test_support.closureTermCount(system.graph.connectivity.closure);
    _ = try fixture.world.addDenseLayer(1, 0, .obstacle, fixture.tree);
    const replaced = try applyWithinBounds(&fixture, &system);
    try std.testing.expectEqual(@as(usize, 1), replaced.levels_built);
    try std.testing.expect(test_support.closureTermCount(system.graph.connectivity.closure) < terms);
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
    try std.testing.expect(test_support.closureTermCount(system.graph.connectivity.closure) > 8);
}

// The row words of `term` in its component's block.
fn termRow(closure: *const Closure, term: u32) []const u32 {
    const hcomp = closure.term.hcomp[term];
    const words = rowWords(closure.hcomp.k_cap[hcomp]);
    return closure.hcomp.block[hcomp][@as(usize, closure.term.index[term]) * words ..][0..words];
}

// The terminal of lattice room `index` on `level`.
fn roomTerm(system: *const PathfindingSystem, fixture: *const TestWorld, chunks: u16, level: u16, index: usize) u32 {
    const room = latticeRoom(chunks, index);
    const cell = fixture.cell(room[0], room[1]);
    const graph = &system.graph;
    const grid = graph.grid(level).?;
    const row = graph.levelGraph(level).?.nodeOf(grid.geometry.chunkOfCell(cell), grid.labelAt(cell));
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

test "a batch where one terminal leaves and another joins a full block reuses the freed index: the block keeps its capacity, words, and allocation" {
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
    const block = closure.hcomp.block[id].ptr;
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
    try std.testing.expectEqual(block, closure.hcomp.block[id].ptr);
    try std.testing.expectEqual(@as(usize, 0), stats.closure_block_allocs + stats.closure_block_frees);
    try fixture.expectMatchesRebuild(&system);
}

test "a dig touching no one-way system runs no closure item and writes no block word; a world without one-way links skips the candidate scan" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, 0, 6);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    const id = roomHComp(&system, &fixture, chunks, 0);
    const block = closure.hcomp.block[id].ptr;
    const words = try std.testing.allocator.dupe(u32, closure.hcomp.block[id]);
    defer std.testing.allocator.free(words);
    // Two rooms with no endpoint joined, far from the chain's row.
    const wall = latticeWall(chunks, 60);
    try fixture.setCell(&system, 0, wall[0], wall[1], fixture.grass);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expect(stats.conn_closure_candidates_batch.item_count != 0);
    try std.testing.expectEqual(@as(usize, 0), stats.conn_closure_resolve_batch.item_count);
    try std.testing.expectEqual(@as(usize, 0), stats.conn_closure_mask_batch.item_count);
    try std.testing.expectEqual(@as(usize, 0), stats.conn_closure_plan_batch.item_count);
    try std.testing.expectEqual(@as(usize, 0), stats.conn_closure_rows_batch.item_count);
    try std.testing.expectEqual(@as(usize, 0), stats.closure_words_written);
    try std.testing.expectEqual(@as(usize, 0), stats.conn_closure_land_batch.item_count);
    try std.testing.expectEqual(block, closure.hcomp.block[id].ptr);
    try std.testing.expectEqualSlices(u32, words, closure.hcomp.block[id]);
    try fixture.expectMatchesRebuild(&system);

    var plain = try latticeWorld(chunks, 1);
    defer plain.deinit();
    var plain_system = try plain.build(test_support.abstractCapacity());
    defer plain_system.deinit();
    try plain.setCell(&plain_system, 0, wall[0], wall[1], plain.grass);
    const plain_stats = try plain_system.applyBufferedNavUpdates(no_colliders, &plain.world, null);
    try std.testing.expectEqual(@as(usize, 0), plain_stats.conn_closure_candidates_batch.item_count);
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
    land: bool = false,

    fn add(self: *ClosureStagesOnWorkers, stats: NavUpdateStats) void {
        self.candidates = self.candidates or onWorkers(stats.conn_closure_candidates_batch);
        self.resolve = self.resolve or onWorkers(stats.conn_closure_resolve_batch);
        self.mask = self.mask or onWorkers(stats.conn_closure_mask_batch);
        self.plan = self.plan or onWorkers(stats.conn_closure_plan_batch);
        self.rows = self.rows or onWorkers(stats.conn_closure_rows_batch);
        self.land = self.land or onWorkers(stats.conn_closure_land_batch);
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
            threaded.nav_controls = .{ .adaptive = false, .items_per_range = items_per_range };
            // The world build's closure runs threaded.
            try threaded.rebuildStaticNavGridWithWorld(&fixture.data, &fixture.world, &threads);
            try expectSameColumns(&inline_system.graph, &threaded.graph);
            const systems = [_]*PathfindingSystem{ &inline_system, &threaded };
            var on_workers = ClosureStagesOnWorkers{};
            var landed: usize = 0;
            // Every tail closed, then reopened; chain A wholly closed (its block dies); B's
            // tail closed; B's tail reopened while D loses all but 24 rooms (its block narrows
            // and lands).
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
                landed += stats.closure_landed_words;
                try std.testing.expectEqual(serial.closure_shrinks, stats.closure_shrinks);
                try std.testing.expectEqual(serial.closure_landed_words, stats.closure_landed_words);
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
            try std.testing.expect(landed != 0);
            if (workers == 4 and items_per_range == 1) {
                try std.testing.expect(on_workers.candidates and on_workers.resolve and on_workers.mask);
                try std.testing.expect(on_workers.plan and on_workers.rows and on_workers.land);
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
    // Fails every allocation; the frees of retired or relocated blocks reach the real one.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const original = system.graph.allocator;
    system.graph.allocator = failing.allocator();
    const batch = system.graph.commitMarks(prepared, no_colliders.view(), nav_threads, &stats);
    system.graph.allocator = original;
    try std.testing.expect(!failing.has_induced_failure);
    system.graph.landClosure(nav_threads, &stats);
    system.nav_marks.clearRetainingCapacity();
    try std.testing.expect(batch.changed);
    try std.testing.expect(stats.closure_terms_new != 0 and stats.closure_a_rows != 0);
    try std.testing.expect(!stats.conn_closure_resolve_batch.ran_inline and !stats.conn_closure_mask_batch.ran_inline);
    try expectWithinBounds(&system.graph.connectivity.closure, stats);
    try fixture.expectMatchesRebuild(&system);
}

test "repeated one-way toggles and terminal splits and merges return terminals, components, words, and links to their counts, and every reaction ends with its blocks landed" {
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
            return .{ .terms = test_support.closureTermCount(c), .hcomps = test_support.closureHcompCount(c), .live_words = c.live_words, .term_pool = c.terms.len, .links = links };
        }
    }.of;
    var start: ?Counts = null;
    const wall = latticeWall(chunks, 3);
    for (0..6) |_| {
        // The tail toggled, then the wall between rooms 3 and 4 opened and closed.
        for ([_]TileId{ fixture.tree, fixture.grass }) |tile| {
            try setRoom(&fixture, &system, chunks, 0, 7, tile);
            _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
            try std.testing.expect(closure.tail.items.len == 0 and closure.residents.items.len == 0);
        }
        for ([_]TileId{ fixture.grass, fixture.tree }) |tile| {
            try fixture.setCell(&system, 0, wall[0], wall[1], tile);
            _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
            try std.testing.expect(closure.tail.items.len == 0 and closure.residents.items.len == 0);
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

test "a one-way system that loses most of its terminals narrows its block and frees the old one in the same batch; a far dig allocates and frees no block" {
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
    try std.testing.expectEqual(@as(usize, 1), cut.closure_block_frees);
    try std.testing.expectEqual(@as(usize, 1), cut.closure_block_allocs);
    try std.testing.expectEqual(blockWords(64), cut.closure_landed_words);
    const id = roomHComp(&system, &fixture, chunks, narrow_tail);
    try std.testing.expectEqual(@as(u32, 64), closure.hcomp.k_cap[id]);
    try std.testing.expectEqual(@as(u32, 28), closure.hcomp.k_high[id]);
    try std.testing.expectEqual(@as(u32, 28), closure.hcomp.k_live[id]);
    try std.testing.expectEqual(blockWords(64), closure.live_words);
    try fixture.expectMatchesRebuild(&system);
    // A dig far from every endpoint touches no component and no block.
    const block = closure.hcomp.block[id].ptr;
    const wall = latticeWall(chunks, 40);
    try fixture.setCell(&system, 0, wall[0], wall[1], fixture.grass);
    const far = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 0), far.closure_links);
    try std.testing.expectEqual(@as(usize, 0), far.closure_block_allocs + far.closure_block_frees + far.closure_landed_words);
    try std.testing.expectEqual(block, closure.hcomp.block[id].ptr);
    try std.testing.expectEqual(blockWords(64), closure.live_words);
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
    // The toggles keep the block in place.
    const block = closure.hcomp.block[id].ptr;
    for (0..8) |toggle| {
        try setRoom(&fixture, &system, chunks, 0, narrow_tail, if (toggle % 2 == 0) fixture.tree else fixture.grass);
        const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        try std.testing.expectEqual(@as(usize, 0), stats.closure_shrinks);
        try std.testing.expectEqual(@as(usize, 0), stats.closure_block_allocs + stats.closure_block_frees);
        try std.testing.expectEqual(narrowed[0], closure.hcomp.k_cap[id]);
        try std.testing.expectEqual(block, closure.hcomp.block[id].ptr);
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
    try std.testing.expectEqual(@as(usize, 1), test_support.closureHcompCount(closure));
    try std.testing.expectEqual(narrowed[2] - blockWords(4), closure.live_words);
    // The narrowing freed the regrown block and the closed system's in its own batch.
    try std.testing.expectEqual(@as(usize, 2), again.closure_block_frees);
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
    try std.testing.expectEqual(@as(usize, 5), test_support.closureHcompCount(closure));
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
    // Fails every allocation; the old block's free reaches the real one.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const original = system.graph.allocator;
    system.graph.allocator = failing.allocator();
    _ = system.graph.commitMarks(prepared, no_colliders.view(), nav_threads, &stats);
    system.graph.allocator = original;
    system.nav_marks.clearRetainingCapacity();
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), stats.closure_shrinks);
    try std.testing.expectEqual(@as(usize, 1), stats.closure_block_frees);
    try std.testing.expect(!stats.conn_closure_rows_batch.ran_inline);
    // The narrowed block waits in the tail, readable, until the reaction's landing.
    const closure = &system.graph.connectivity.closure;
    try std.testing.expectEqual(@as(usize, 1), closure.residents.items.len);
    try fixture.expectMatchesRebuild(&system);
    system.graph.landClosure(nav_threads, &stats);
    try std.testing.expectEqual(@as(usize, 0), closure.residents.items.len);
    try std.testing.expectEqual(blockWords(64), stats.closure_landed_words);
    try expectWithinBounds(closure, stats);
    try fixture.expectMatchesRebuild(&system);
}

// One H-component's block as a batch elsewhere must leave it: its id, address, rows, and
// handed-out map entries.
const BlockSnapshot = struct {
    id: u32,
    ptr: [*]align(64) u32,
    words: []u32,

    fn take(system: *const PathfindingSystem, fixture: *const TestWorld, chunks: u16, room: usize) !BlockSnapshot {
        const closure = &system.graph.connectivity.closure;
        const id = roomHComp(system, fixture, chunks, room);
        const k_cap = closure.hcomp.k_cap[id];
        const k_high = closure.hcomp.k_high[id];
        const rows = @as(usize, k_cap) * rowWords(k_cap);
        const words = try std.testing.allocator.alloc(u32, rows + k_high);
        @memcpy(words[0..rows], closure.hcomp.block[id][0..rows]);
        @memcpy(words[rows..], indexMap(closure.hcomp, id)[0..k_high]);
        return .{ .id = id, .ptr = closure.hcomp.block[id].ptr, .words = words };
    }

    fn deinit(self: *BlockSnapshot) void {
        std.testing.allocator.free(self.words);
    }

    fn expectUnchanged(self: *const BlockSnapshot, system: *const PathfindingSystem, fixture: *const TestWorld, chunks: u16, room: usize) !void {
        var now = try take(system, fixture, chunks, room);
        defer now.deinit();
        try std.testing.expectEqual(self.id, now.id);
        try std.testing.expectEqual(self.ptr, now.ptr);
        try std.testing.expectEqualSlices(u32, self.words, now.words);
    }
};

test "changes in one one-way system never move or write another system's block" {
    const chunks: u16 = 8;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    // Systems over rooms 0..7, 16..47, and 48..63 (rows 0 to 3), whose chunks no change to the
    // narrow chain (rows 8 to 15) patches.
    const others = [_]usize{ 0, 16, 48 };
    try addChain(&fixture, chunks, 0, 0, 8);
    try addChain(&fixture, chunks, 0, 16, 32);
    try addChain(&fixture, chunks, 0, 48, 16);
    try addChain(&fixture, chunks, 0, narrow_first, 128);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    var snapshots: [others.len]?BlockSnapshot = @splat(null);
    defer for (&snapshots) |*snapshot| {
        if (snapshot.*) |*taken| taken.deinit();
    };
    for (others, &snapshots) |room, *snapshot| snapshot.* = try BlockSnapshot.take(&system, &fixture, chunks, room);
    // Tail toggles in place, a narrowing and its regrowth (two relocations), a retirement, and
    // a new system in its place.
    for (0..7) |step| {
        switch (step) {
            0...3 => try setRoom(&fixture, &system, chunks, 0, narrow_tail, if (step % 2 == 0) fixture.tree else fixture.grass),
            4 => for (narrow_first..narrow_first + 100) |room| try setRoom(&fixture, &system, chunks, 0, room, fixture.tree),
            5 => for (narrow_first..narrow_first + 128) |room| try setRoom(&fixture, &system, chunks, 0, room, fixture.tree),
            else => for (narrow_first..narrow_first + 128) |room| try setRoom(&fixture, &system, chunks, 0, room, fixture.grass),
        }
        const stats = try applyWithinBounds(&fixture, &system);
        try std.testing.expect(stats.closure_links != 0);
        for (others, &snapshots) |room, *snapshot| try snapshot.*.?.expectUnchanged(&system, &fixture, chunks, room);
    }
    try fixture.expectMatchesRebuild(&system);
}

test "retiring or narrowing a system frees its old block in the same batch; live words and bytes follow" {
    const chunks: u16 = 8;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, 0, 4);
    try addChain(&fixture, chunks, 0, narrow_first, 128);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    // A narrowing and its regrowth first, so the measured batches grow no pool or table.
    _ = try narrowChain(&fixture, &system, fixture.tree);
    _ = try narrowChain(&fixture, &system, fixture.grass);
    try std.testing.expectEqual(@as(u32, 128), closure.hcomp.k_cap[roomHComp(&system, &fixture, chunks, narrow_tail)]);
    var live_words = closure.live_words;
    var bytes = closure.bytes();
    const cut = try narrowChain(&fixture, &system, fixture.tree);
    try std.testing.expectEqual(@as(usize, 1), cut.closure_shrinks);
    try std.testing.expectEqual(@as(usize, 1), cut.closure_block_frees);
    try std.testing.expectEqual(@as(usize, 1), cut.closure_block_allocs);
    const narrowed = blockWords(128) - blockWords(64);
    try std.testing.expectEqual(live_words - narrowed, closure.live_words);
    try std.testing.expectEqual(bytes - narrowed * @sizeOf(u32), closure.bytes());
    // The small system retired: its block goes in that batch, and nothing lands.
    const small = roomHComp(&system, &fixture, chunks, 0);
    live_words = closure.live_words;
    bytes = closure.bytes();
    for (0..4) |room| try setRoom(&fixture, &system, chunks, 0, room, fixture.tree);
    const retired = try applyWithinBounds(&fixture, &system);
    try std.testing.expectEqual(@as(usize, 1), retired.closure_block_frees);
    try std.testing.expectEqual(@as(usize, 0), retired.closure_block_allocs + retired.closure_landed_words);
    try std.testing.expectEqual(@as(u32, 0), closure.hcomp.k_cap[small]);
    try std.testing.expectEqual(@as(usize, 0), closure.hcomp.block[small].len);
    try std.testing.expectEqual(live_words - blockWords(4), closure.live_words);
    try std.testing.expectEqual(bytes - blockWords(4) * @sizeOf(u32), closure.bytes());
    try fixture.expectMatchesRebuild(&system);
}

test "a relocating batch lands its pieces in the same nav reaction on workers: the tail and residents are empty after it, and the land stage ran on workers" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const chunks: u16 = 16;
    const rooms: usize = 256;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    // A chain over rows 0 to 7, every room closed: its links are dead until the reopen.
    try addChain(&fixture, chunks, 0, 0, rooms);
    for (0..rooms) |room| try setRoom(&fixture, null, chunks, 0, room, fixture.tree);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 4, .items_per_range = 1 });
    defer threads.deinit();
    var capacity = test_support.abstractCapacity();
    capacity.worker_participant_count = threads.participantSlotCount();
    var system = try fixture.build(capacity);
    defer system.deinit();
    system.nav_controls = .{ .adaptive = false, .items_per_range = 1 };
    const closure = &system.graph.connectivity.closure;
    try std.testing.expectEqual(@as(usize, 0), test_support.closureTermCount(closure));
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    for (0..rooms) |room| try setRoom(&fixture, &system, chunks, 0, room, fixture.grass);
    frame.beginStep();
    const stats = try system.reactToPostCommitNavEvents(&frame, no_colliders, &fixture.world, &threads);
    // One new system of 256: its block, 144 lines, lands on workers in this reaction.
    try std.testing.expectEqual(@as(usize, 1), test_support.closureHcompCount(closure));
    try std.testing.expectEqual(@as(u32, rooms), closure.hcomp.k_cap[roomHComp(&system, &fixture, chunks, 0)]);
    const land = stats.conn_closure_land_batch;
    try std.testing.expectEqual(blockWords(rooms) / span_words, land.item_count);
    try std.testing.expect(!land.ran_inline and land.worker_thread_ranges != 0);
    try std.testing.expectEqual(blockWords(rooms), stats.closure_landed_words);
    try std.testing.expectEqual(@as(usize, 1), stats.closure_block_allocs);
    try expectWithinBounds(closure, stats);
    try fixture.expectMatchesRebuild(&system);
}

test "a relocating batch committed under a failing allocator on a multi-worker ThreadSystem leaves its pieces resident; a failed landing defers with the closure intact; a prepare under failure returns OutOfMemory with state intact; disarmed, it lands and matches the rebuild" {
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
    system.nav_controls = .{ .adaptive = false, .items_per_range = 1 };
    const nav_threads = forcedNavThreads(&system, &threads);
    const closure = &system.graph.connectivity.closure;
    // A narrowing and its regrowth on the same threads warm every list the batches below use.
    for ([_]TileId{ fixture.tree, fixture.grass }) |tile| {
        for (narrow_first..narrow_first + 100) |room| try setRoom(&fixture, &system, chunks, 0, room, tile);
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    }
    // The narrowing prepared with the real allocator, committed under the failing one: its
    // block waits in the tail, readable.
    for (narrow_first..narrow_first + 100) |room| try setRoom(&fixture, &system, chunks, 0, room, fixture.tree);
    var stats = NavUpdateStats{};
    const prepared = (try system.graph.prepareMarks(&fixture.world, no_colliders.view(), system.nav_marks.items, nav_threads, &stats)).?;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const original = system.graph.allocator;
    system.graph.allocator = failing.allocator();
    _ = system.graph.commitMarks(prepared, no_colliders.view(), nav_threads, &stats);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), stats.closure_shrinks);
    try std.testing.expect(!stats.conn_closure_rows_batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 1), closure.residents.items.len);
    try fixture.expectMatchesRebuild(&system);
    // Its landing fails: deferred, counted, and the block stays in the tail.
    system.graph.landClosure(nav_threads, &stats);
    system.graph.allocator = original;
    system.nav_marks.clearRetainingCapacity();
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), stats.closure_land_deferrals);
    try std.testing.expectEqual(@as(usize, 0), stats.closure_landed_words);
    try std.testing.expectEqual(@as(usize, 1), closure.residents.items.len);
    try std.testing.expectEqual(blockWords(64), closure.tail.items.len);
    try fixture.expectMatchesRebuild(&system);
    // The next batch's prepare under failure fails as OutOfMemory before any change, the
    // block still resident and the change pending.
    var before = try fixture.build(test_support.abstractCapacity());
    defer before.deinit();
    try setRoom(&fixture, &system, chunks, 0, narrow_tail, fixture.tree);
    var failing_prepare = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing_prepare.allocator();
    system.graph.allocator = failing_prepare.allocator();
    const result = system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    system.allocator = std.testing.allocator;
    system.graph.allocator = original;
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expect(failing_prepare.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), closure.residents.items.len);
    try test_support.expectConnectivityConsistent(&system.graph);
    try test_support.expectSameConnectivityPartition(&system.graph, &before.graph);
    try test_support.expectSameClosure(&system.graph, &before.graph);
    try std.testing.expect(system.hasPendingNavUpdates(&fixture.world));
    // Disarmed: the prepare lands the block, then the batch runs.
    const retried = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    try std.testing.expectEqual(blockWords(64), retried.closure_landed_words);
    try std.testing.expectEqual(@as(usize, 1), retried.closure_block_allocs);
    try expectWithinBounds(closure, retried);
    try fixture.expectMatchesRebuild(&system);
}

// Narrows the narrow chain of an 8-chunk lattice in one batch committed outside a reaction,
// then fails its landing: the narrowed block stays deferred in the tail.
fn deferNarrowingLanding(fixture: *TestWorld, system: *PathfindingSystem) !void {
    for (narrow_first..narrow_first + 100) |room| try setRoom(fixture, system, 8, 0, room, fixture.tree);
    var stats = NavUpdateStats{};
    const prepared = (try system.graph.prepareMarks(&fixture.world, no_colliders.view(), system.nav_marks.items, null, &stats)).?;
    _ = system.graph.commitMarks(prepared, no_colliders.view(), null, &stats);
    system.nav_marks.clearRetainingCapacity();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const original = system.graph.allocator;
    system.graph.allocator = failing.allocator();
    system.graph.landClosure(null, &stats);
    system.graph.allocator = original;
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), stats.closure_land_deferrals);
    try std.testing.expectEqual(@as(usize, 1), system.graph.connectivity.closure.residents.items.len);
}

test "release windows closing while a landing is deferred keep the tail and its blocks; the next batch lands them" {
    const chunks: u16 = 8;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, narrow_first, 128);
    var system = try fixture.build(windowCapacity(1));
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    try deferNarrowingLanding(&fixture, &system);
    const slots_held = closure.slots.capacity;
    // Quiet steps, each closing a window: the later ones keep nothing of the narrowing.
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    for (0..3) |_| {
        frame.beginStep();
        _ = try system.reactToPostCommitNavEvents(&frame, no_colliders, &fixture.world, null);
    }
    // The windows released the batch's other staging, never the tail under the block.
    try std.testing.expect(closure.slots.capacity < slots_held);
    try std.testing.expectEqual(@as(usize, 1), closure.residents.items.len);
    try std.testing.expectEqual(blockWords(64), closure.tail.items.len);
    try fixture.expectMatchesRebuild(&system);
    // Each step closes a window, which resets the batch limits `expectWithinBounds` reads.
    try setRoom(&fixture, &system, chunks, 0, narrow_tail, fixture.tree);
    const landed = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(blockWords(64), landed.closure_landed_words);
    try std.testing.expect(closure.residents.items.len == 0 and closure.tail.items.len == 0);
    try fixture.expectMatchesRebuild(&system);
}

test "a world destroyed while a landing is deferred frees every block once" {
    var fixture = try latticeWorld(8, 1);
    defer fixture.deinit();
    try addChain(&fixture, 8, 0, narrow_first, 128);
    var system = try fixture.build(test_support.abstractCapacity());
    // The resident block lies in the tail: the deinit frees the tail, never the block alone.
    defer system.deinit();
    try deferNarrowingLanding(&fixture, &system);
    try fixture.expectMatchesRebuild(&system);
}

test "a landing failing after its first allocation frees what it allocated, keeps every block in the tail, and lands all on retry" {
    const chunks: u16 = 8;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    // Two chains of 64, each cut to 14 rooms in one batch: two narrowed blocks of 32.
    try addChain(&fixture, chunks, 0, 0, 64);
    try addChain(&fixture, chunks, 0, 64, 64);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    for ([_]usize{ 0, 64 }) |first| {
        for (first..first + 50) |room| try setRoom(&fixture, &system, chunks, 0, room, fixture.tree);
    }
    var stats = NavUpdateStats{};
    const prepared = (try system.graph.prepareMarks(&fixture.world, no_colliders.view(), system.nav_marks.items, null, &stats)).?;
    _ = system.graph.commitMarks(prepared, no_colliders.view(), null, &stats);
    system.nav_marks.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 2), stats.closure_shrinks);
    try std.testing.expectEqual(@as(usize, 2), closure.residents.items.len);
    try std.testing.expectEqual(2 * blockWords(32), closure.tail.items.len);
    // The second destination fails: the first is freed, and both blocks stay in the tail.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    const original = system.graph.allocator;
    system.graph.allocator = failing.allocator();
    system.graph.landClosure(null, &stats);
    system.graph.allocator = original;
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), failing.allocations);
    try std.testing.expectEqual(@as(usize, 1), failing.deallocations);
    try std.testing.expectEqual(@as(usize, 1), stats.closure_land_deferrals);
    try std.testing.expectEqual(@as(usize, 2), closure.residents.items.len);
    const tail_start = @intFromPtr(closure.tail.items.ptr);
    for (closure.residents.items) |resident| {
        try std.testing.expectEqual(@as(usize, 0), resident.dst.len);
        try std.testing.expectEqual(tail_start + resident.src * @sizeOf(u32), @intFromPtr(closure.hcomp.block[resident.hcomp].ptr));
    }
    try fixture.expectMatchesRebuild(&system);
    // The retry lands both.
    stats = .{};
    system.graph.landClosure(null, &stats);
    try std.testing.expectEqual(@as(usize, 0), closure.residents.items.len);
    try std.testing.expectEqual(@as(usize, 2), stats.closure_block_allocs);
    try std.testing.expectEqual(2 * blockWords(32), stats.closure_landed_words);
    try fixture.expectMatchesRebuild(&system);
}

// Fails its first allocation, then forwards every request to the testing allocator.
const FailOnceAllocator = struct {
    failed: bool = false,

    fn allocator(self: *FailOnceAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        // The context is this allocator (`allocator`).
        const self: *FailOnceAllocator = @ptrCast(@alignCast(context));
        if (!self.failed) {
            self.failed = true;
            return null;
        }
        return std.testing.allocator.rawAlloc(len, alignment, return_address);
    }

    fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        return std.testing.allocator.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        return std.testing.allocator.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        std.testing.allocator.rawFree(memory, alignment, return_address);
    }
};

test "a nav update failing after a level build left blocks in the tail lands them on its error path, or counts the deferral when that landing fails too" {
    for ([_]bool{ false, true }) |landing_fails| {
        var fixture = try TestWorld.init(6, 1);
        defer fixture.deinit();
        var system = try fixture.build(test_support.abstractCapacity());
        defer system.deinit();
        for (1..3) |level| {
            _ = try fixture.world.addLevel(-16 * @as(i32, @intCast(level)));
            _ = try fixture.world.addDenseLayer(@intCast(level), 0, .floor, fixture.grass);
        }
        try addOneWay(&fixture, 1, .{ 2, 2 }, 2, .{ 9, 9 });
        // The link registered with neither level built, then both built outside a reaction: it
        // goes live with the second, whose new block waits in the tail.
        var stats = NavUpdateStats{};
        const prepared = (try system.graph.prepareMarks(&fixture.world, no_colliders.view(), &.{}, null, &stats)).?;
        _ = system.graph.commitMarks(prepared, no_colliders.view(), null, &stats);
        try system.graph.buildLevel(no_colliders.view(), &fixture.world, 1, null, &stats);
        try system.graph.buildLevel(no_colliders.view(), &fixture.world, 2, null, &stats);
        const closure = &system.graph.connectivity.closure;
        try std.testing.expectEqual(@as(usize, 1), closure.residents.items.len);
        // The next update's level build fails at its first allocation.
        _ = try fixture.world.addLevel(-48);
        _ = try fixture.world.addDenseLayer(3, 0, .floor, fixture.grass);
        var once = FailOnceAllocator{};
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        const broken = if (landing_fails) failing.allocator() else once.allocator();
        system.allocator = broken;
        system.graph.allocator = broken;
        const result = system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        system.allocator = std.testing.allocator;
        system.graph.allocator = std.testing.allocator;
        try std.testing.expectError(error.OutOfMemory, result);
        try std.testing.expectEqual(@as(usize, 3), system.graph.levelCount());
        try std.testing.expectEqual(@as(usize, @intFromBool(landing_fails)), closure.residents.items.len);
        try std.testing.expectEqual(@as(u64, @intFromBool(landing_fails)), system.graph.land_deferrals);
        try std.testing.expect(reach(&system.graph, 1, fixture.cell(2, 2), 2, fixture.cell(9, 9)) == .reaches);
        // The retry builds the level, landing any block first.
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        try std.testing.expectEqual(@as(usize, 4), system.graph.levelCount());
        try std.testing.expectEqual(@as(usize, 0), closure.residents.items.len);
        try std.testing.expectEqual(@as(usize, 0), closure.tail.items.len);
        try fixture.expectMatchesRebuild(&system);
    }
}

test "an index-map entry is live only at its own index: a free link naming a live terminal of the same component at another index reads as free" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    // System B (rooms 32..39) registers first and takes terminal ids 0..7, so system A's
    // (rooms 0..15) ids run 8 ahead of its indices.
    try addChain(&fixture, chunks, 0, 32, 8);
    try addChain(&fixture, chunks, 0, 0, 16);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    const a = roomHComp(&system, &fixture, chunks, 0);
    const room6 = roomTerm(&system, &fixture, chunks, 0, 6);
    try std.testing.expectEqual(@as(u32, 14), room6);
    try std.testing.expectEqual(@as(u32, 6), closure.term.index[room6]);
    // A's last two rooms (indices 14 and 15) closed in one batch: index 15's free link names
    // 14, the id of A's live room 6 at index 6.
    for (14..16) |room| try setRoom(&fixture, &system, chunks, 0, room, fixture.tree);
    _ = try applyWithinBounds(&fixture, &system);
    try std.testing.expectEqual(@as(u32, 15), closure.hcomp.index_free[a]);
    try std.testing.expectEqual(room6, indexMap(closure.hcomp, a)[15]);
    try std.testing.expectEqual(a, closure.term.hcomp[room6]);
    try std.testing.expect(!liveEntry(closure.term, a, room6, 15));
    try std.testing.expect(liveEntry(closure.term, a, room6, 6));
    try fixture.expectMatchesRebuild(&system);
    // Batches walking A's map: its head leaves, then both rooms return through the free list.
    try setRoom(&fixture, &system, chunks, 0, 0, fixture.tree);
    _ = try applyWithinBounds(&fixture, &system);
    try fixture.expectMatchesRebuild(&system);
    for (14..16) |room| try setRoom(&fixture, &system, chunks, 0, room, fixture.grass);
    _ = try applyWithinBounds(&fixture, &system);
    try fixture.expectMatchesRebuild(&system);
}

test "reopening a closed chain in one batch counts each room's cell once: n_net equals its rooms, and the tail stays within the bound" {
    const chunks: u16 = 4;
    const rooms: usize = 8;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    // Every interior room holds two endpoints: one link's target and the next one's source.
    try addChain(&fixture, chunks, 0, 0, rooms);
    for (0..rooms) |room| try setRoom(&fixture, null, chunks, 0, room, fixture.tree);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    try std.testing.expectEqual(@as(usize, 0), test_support.closureTermCount(closure));
    for (0..rooms) |room| try setRoom(&fixture, &system, chunks, 0, room, fixture.grass);
    const stats = try applyWithinBounds(&fixture, &system);
    try std.testing.expectEqual(rooms, closure.limits.n_net);
    try std.testing.expectEqual(rooms, closure.limits.n_gross);
    try std.testing.expectEqual(rooms, stats.closure_terms_new);
    try std.testing.expectEqual(@as(u32, rooms), roomBlockCap(&system, &fixture, chunks, 0));
    try fixture.expectMatchesRebuild(&system);
}

test "an index-map entry is live by back-pointer: a free link equal to a live terminal id of another component reads as free, and term ids are bounded by no_term" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    // System B (rooms 32..39, row 4) registers first, so its terminals take ids 0..7; system A
    // (rooms 0..7, row 0) takes ids 8..15, its rooms at indices 0..7.
    try addChain(&fixture, chunks, 0, 32, 8);
    try addChain(&fixture, chunks, 0, 0, 8);
    var system = try fixture.build(test_support.abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    const a = roomHComp(&system, &fixture, chunks, 0);
    const b = roomHComp(&system, &fixture, chunks, 32);
    // A's rooms 6 and 7 closed in one batch: index 7's free entry links index 6, which is
    // also the id of one of B's live terminals.
    for (6..8) |room| try setRoom(&fixture, &system, chunks, 0, room, fixture.tree);
    _ = try applyWithinBounds(&fixture, &system);
    try std.testing.expectEqual(@as(u32, 7), closure.hcomp.index_free[a]);
    const link = indexMap(closure.hcomp, a)[7];
    try std.testing.expectEqual(@as(u32, 6), link);
    try std.testing.expectEqual(b, closure.term.hcomp[link]);
    try std.testing.expect(!liveEntry(closure.term, a, link, 7));
    try fixture.expectMatchesRebuild(&system);
    // Batches walking A's map read the link as free: room 7 takes index 7 back, then room 5
    // leaves.
    try setRoom(&fixture, &system, chunks, 0, 7, fixture.grass);
    _ = try applyWithinBounds(&fixture, &system);
    try fixture.expectMatchesRebuild(&system);
    try setRoom(&fixture, &system, chunks, 0, 5, fixture.tree);
    _ = try applyWithinBounds(&fixture, &system);
    try fixture.expectMatchesRebuild(&system);
    // Ids reach the full width: a need of 2^31 terminals or H-components passes the id check
    // and asks the allocator; a need reaching the sentinel fails before asking it.
    var grows: u64 = 0;
    inline for (.{ .{ 1 << 31, 0 }, .{ 0, 1 << 31 } }) |need| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        try std.testing.expectError(error.OutOfMemory, closure.ensureFreeIds(failing.allocator(), need[0], need[1], &grows));
        try std.testing.expect(failing.has_induced_failure);
    }
    inline for (.{ .{ no_term, 0 }, .{ 0, no_hcomp } }) |need| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        try std.testing.expectError(error.OutOfMemory, closure.ensureFreeIds(failing.allocator(), need[0], need[1], &grows));
        try std.testing.expect(!failing.has_induced_failure);
    }
    try std.testing.expectEqual(@as(u64, 0), grows);
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
    try std.testing.expectEqual(@as(usize, 2), test_support.closureTermCount(system.graph.connectivity.closure));
    try setHubCorridor(&fixture, &system, tunnels, fixture.tree);
    var stats = NavUpdateStats{};
    const prepared = (try system.graph.prepareMarks(&fixture.world, no_colliders.view(), system.nav_marks.items, null, &stats)).?;
    // Fails every allocation; the old block's free reaches the real one.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const original = system.graph.allocator;
    system.graph.allocator = failing.allocator();
    _ = system.graph.commitMarks(prepared, no_colliders.view(), null, &stats);
    system.graph.allocator = original;
    system.nav_marks.clearRetainingCapacity();
    try std.testing.expect(!failing.has_induced_failure);
    system.graph.landClosure(null, &stats);
    // Every tunnel takes its own root; the first in link order takes the corridor's terminal
    // back, the rest pop new ones, and none leaves. The tunnels' mouths are the seed edges
    // whose kept far end held the terminal: the bound counts each.
    try std.testing.expectEqual(@as(usize, tunnels + 1), test_support.closureTermCount(system.graph.connectivity.closure));
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
    try std.testing.expectEqual(@as(usize, 1), test_support.closureHcompCount(system.graph.connectivity.closure));
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
    try std.testing.expectEqual(@as(usize, 0), test_support.closureTermCount(closure));
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
    system.nav_controls = .{ .adaptive = false, .items_per_range = 1 };
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

// A post-commit nav reaction for the cap test: a lattice with two one-way chains each cut in
// two by a closed room, a new block per chain landing (graph, connectivity, and closure
// stages), or two rooms whose doors close (the flood).
const CappedNavScenario = enum { closure, flood };

const CappedNavRun = struct {
    stats: NavUpdateStats,
    plan_batch: BatchStats,
    patch_batch: BatchStats,
    mark_batch: BatchStats,

    // The run's batch of stage `name`.
    fn batch(self: *const CappedNavRun, comptime name: []const u8) BatchStats {
        if (comptime std.mem.eql(u8, name, "plan")) return self.plan_batch;
        if (comptime std.mem.eql(u8, name, "patch")) return self.patch_batch;
        if (comptime std.mem.eql(u8, name, "mark")) return self.mark_batch;
        return @field(self.stats, name);
    }
};

// The stage names of `CappedNavRun.batch`: every `BatchStats` of `NavUpdateStats`, the key
// plan and record patch, and `nav_mark`.
const capped_nav_stages = blk: {
    var names: []const []const u8 = &.{ "plan", "patch", "mark" };
    for (@typeInfo(NavUpdateStats).@"struct".field_names, @typeInfo(NavUpdateStats).@"struct".field_types) |name, field_type| {
        if (field_type == BatchStats) names = names ++ .{name};
    }
    break :blk names;
};

fn runCappedNavScenario(scenario: CappedNavScenario, threads: *ThreadSystem, cap: ?usize) !CappedNavRun {
    const chunks: u16 = 8;
    var fixture = switch (scenario) {
        .closure => try latticeWorld(chunks, 1),
        .flood => try TestWorld.init(10, 1),
    };
    defer fixture.deinit();
    switch (scenario) {
        .closure => {
            try addChain(&fixture, chunks, 0, 16, 16);
            try addChain(&fixture, chunks, 0, 64, 16);
        },
        .flood => try twoRooms(&fixture),
    }
    var capacity = test_support.abstractCapacity();
    capacity.worker_participant_count = threads.participantSlotCount();
    var system = try fixture.build(capacity);
    defer system.deinit();
    system.nav_controls = .{ .adaptive = false, .items_per_range = 1, .max_worker_threads = cap };
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    switch (scenario) {
        .closure => {
            try setRoom(&fixture, &system, chunks, 0, 24, fixture.tree);
            try setRoom(&fixture, &system, chunks, 0, 72, fixture.tree);
        },
        .flood => try toggleRooms(&fixture, &system, fixture.tree),
    }
    frame.beginStep();
    const stats = try system.reactToPostCommitNavEvents(&frame, no_colliders, &fixture.world, threads);
    try fixture.expectMatchesRebuild(&system);
    return .{
        .stats = stats,
        .plan_batch = stats.plan_batch,
        .patch_batch = stats.patch_batch,
        .mark_batch = system.last_mark_batch,
    };
}

test "a nav worker cap of zero keeps every graph, connectivity, and closure stage inline on a multi-worker ThreadSystem and changes no result" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    for (std.meta.tags(CappedNavScenario)) |scenario| {
        const uncapped = try runCappedNavScenario(scenario, &threads, null);
        const capped = try runCappedNavScenario(scenario, &threads, 0);
        // The fixed partition runs these stages on workers unless the cap holds them inline.
        const on_workers: []const []const u8 = switch (scenario) {
            .closure => &.{ "plan", "patch", "remask_batch", "conn_seed_batch", "conn_gather_batch", "conn_closure_candidates_batch", "conn_closure_land_batch", "conn_closure_resolve_batch", "conn_closure_mask_batch", "conn_closure_plan_batch", "conn_closure_rows_batch" },
            .flood => &.{ "conn_seed_batch", "conn_gather_batch", "conn_flood_batch" },
        };
        var matched: usize = 0;
        inline for (capped_nav_stages) |name| {
            const free = uncapped.batch(name);
            const held = capped.batch(name);
            try std.testing.expectEqual(free.item_count, held.item_count);
            try std.testing.expect(held.ran_inline and held.active_worker_threads == 0);
            for (on_workers) |wanted| {
                if (!std.mem.eql(u8, wanted, name)) continue;
                try std.testing.expect(!free.ran_inline and free.worker_thread_ranges != 0);
                matched += 1;
            }
        }
        try std.testing.expectEqual(on_workers.len, matched);
        inline for (.{ "conn_splits", "conn_merges", "conn_flood_nodes", "closure_links", "closure_a_rows", "records_patched" }) |name| {
            try std.testing.expectEqual(@field(uncapped.stats, name), @field(capped.stats, name));
        }
    }
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
    try std.testing.expectEqual(@as(usize, 2), test_support.closureHcompCount(system.graph.connectivity.closure));
    // A gap in level 0's wall, its patch keys far from every endpoint, merges the halves.
    try fixture.setChunk(&system, 0, 4, 4, fixture.grass);
    const merged = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), merged.conn_merges);
    try std.testing.expectEqual(@as(usize, 1), test_support.closureHcompCount(system.graph.connectivity.closure));
    try std.testing.expect(reach(&system.graph, 0, fixture.cell(1, 1), 1, fixture.cell(29, 29)) == .reaches);
    try fixture.expectMatchesRebuild(&system);
    // Refilled: the root splits and so does the system.
    try fixture.setChunk(&system, 0, 4, 4, fixture.tree);
    const split = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), split.conn_splits);
    try std.testing.expectEqual(@as(usize, 2), test_support.closureHcompCount(system.graph.connectivity.closure));
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
    try std.testing.expectEqual(@as(usize, 9), test_support.closureTermCount(closure));
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
    try std.testing.expectEqual(@as(usize, 9), test_support.closureTermCount(closure));
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
    try std.testing.expectEqual(@as(usize, 2), test_support.closureHcompCount(closure));
    // The cell between rooms 0 and 8 dug: their roots merge, and so do the systems.
    try fixture.setCell(&system, 0, 0, 1, fixture.grass);
    _ = try applyWithinBounds(&fixture, &system);
    try std.testing.expect(closure.limits.merge);
    try std.testing.expectEqual(@as(usize, 1), test_support.closureHcompCount(closure));
    try std.testing.expectEqual(@as(usize, 15), test_support.closureTermCount(closure));
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
    try std.testing.expectEqual(@as(usize, 0), test_support.closureTermCount(closure));
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
    try std.testing.expectEqual(@as(usize, 5), test_support.closureHcompCount(closure));
    try std.testing.expectEqual(@as(usize, 5), closure.hcomps.len);
}

test "a closure batch reaching an exhausted terminal id pool fails as OutOfMemory without asking the allocator, keeps the closure and its change pending, and the retry equals a rebuild" {
    const chunks: u16 = 4;
    var fixture = try latticeWorld(chunks, 1);
    defer fixture.deinit();
    try addChain(&fixture, chunks, 0, 0, 8);
    var system = try fixture.build(windowCapacity(exhausted_pool_window));
    defer system.deinit();
    // Reopening the tail's room creates its terminal. Closed, reopened, and closed again, so
    // the last reopening's staging is warm.
    for ([_]TileId{ fixture.tree, fixture.grass, fixture.tree }) |tile| {
        try setRoom(&fixture, &system, chunks, 0, 7, tile);
        _ = try applyWithinBounds(&fixture, &system);
    }
    var before = try fixture.build(test_support.abstractCapacity());
    defer before.deinit();
    try setRoom(&fixture, &system, chunks, 0, 7, fixture.grass);
    try expectExhaustedPoolBatch(&fixture, &system, &before, .terms, true);
}
