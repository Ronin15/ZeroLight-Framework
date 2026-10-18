// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Per-level nav cell grids plus per-chunk records: a record holds one chunk's border-run
//! portals, its open link-endpoint portals, and the links leaving them, and a chunk with no
//! portal holds none. One transactional batch (plan, reserve, commit) remasks the changed
//! chunks and re-derives every record whose portals can change; level and world builds are
//! the same batch over fresh storage.

const std = @import("std");
const math = @import("../../../core/math.zig");
const logging = @import("../../../core/logging.zig");
const pdqSort = @import("../../../core/sort.zig").pdq;
const insertionSort = @import("../../../core/sort.zig").insertion;
const WorldSystem = @import("../../world/system.zig").WorldSystem;
const validateChunkGrid = @import("../../world/system.zig").validateChunkGrid;
const ChunkGridError = @import("../../world/system.zig").ChunkGridError;
const chunkKey = @import("../chunk_list_map.zig").chunkKey;
const keyLevel = @import("../chunk_list_map.zig").keyLevel;
const keyChunk = @import("../chunk_list_map.zig").keyChunk;
const max_chunk_size_tiles = @import("../../world/system.zig").max_chunk_size_tiles;
const LevelLink = @import("../../world/system.zig").LevelLink;
const CellCoord = @import("../../world/system.zig").CellCoord;
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const AdaptiveWorkTuner = @import("../../../app/thread_system.zig").AdaptiveWorkTuner;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const Dispatch = @import("../../../app/thread_system.zig").Dispatch;
const StageControls = @import("../../../app/thread_system.zig").StageControls;
const accumulateBatch = @import("../../../app/thread_system.zig").accumulateBatch;
const runShaped = @import("../../../app/thread_system.zig").runShaped;
const stageShape = @import("../../../app/thread_system.zig").stageShape;
const runStage = @import("../../../app/thread_system.zig").runStage;
const thread_shared_record_alignment = @import("../../../app/thread_system.zig").thread_shared_record_alignment;
const PathAgentClass = @import("../../simulation.zig").PathAgentClass;
const NavGrid = @import("nav_grid.zig").NavGrid;
const ChunkBits = @import("../../world/terrain.zig").ChunkBits;
const ChunkGeometry = @import("../../world/terrain.zig").ChunkGeometry;
const no_block = @import("nav_grid.zig").no_block;
const ColliderView = @import("../static_colliders.zig").ColliderView;
const ColliderGeometry = @import("../static_colliders.zig").ColliderGeometry;
const types = @import("types.zig");
const default_cell_size = types.default_cell_size;
const no_cell = types.no_cell;
const inter_level_penalty = types.inter_level_penalty;
const long_link_pairs = types.long_link_pairs;
const PathQueryKey = types.PathQueryKey;
const NavMark = types.NavMark;
const NavSpan = types.NavSpan;
const NavUpdateStats = types.NavUpdateStats;
const runtime_perf_log = @import("../../../app/runtime_perf_log.zig");
const StageTimer = runtime_perf_log.StageTimer;
const connectivity = @import("connectivity.zig");
const Connectivity = @import("connectivity.zig").Connectivity;
const ConnectivityCounters = @import("connectivity.zig").ConnectivityCounters;
const ClosureCounters = @import("connectivity_closure.zig").ClosureCounters;
const ClosureThreads = @import("connectivity_closure.zig").ClosureThreads;
const NodeRow = @import("connectivity.zig").NodeRow;
const no_node = @import("connectivity.zig").no_node;
const no_comp = @import("connectivity.zig").no_comp;
const growPool = @import("connectivity.zig").growPool;
const LinkBounds = @import("link_bounds.zig").LinkBounds;
const LevelCrossings = @import("link_bounds.zig").LevelCrossings;
const foldLevelCrossings = @import("link_bounds.zig").foldLevelCrossings;

// Most border portals a chunk of edge `chunk_tiles` holds: one per open run on each of its
// four sides.
pub fn borderPortalBound(chunk_tiles: u16) usize {
    return 4 * @divCeil(@as(usize, chunk_tiles), 2);
}

// Most border portals any chunk holds.
const max_border_portals: usize = borderPortalBound(max_chunk_size_tiles);

const no_record: u32 = std.math.maxInt(u32);
const no_link_slot: u32 = std.math.maxInt(u32);

comptime {
    // Chunk-local cell indices and component labels are u8.
    std.debug.assert(@as(usize, max_chunk_size_tiles) * max_chunk_size_tiles <= 256);
    // `validateChunkGrid` bounds cell indices below maxInt(u32).
    std.debug.assert(no_cell == std.math.maxInt(u32));
}

/// The sides of a chunk a border portal crosses, plus whether a link endpoint sits on it.
pub const PortalFlags = packed struct(u8) {
    west: bool = false,
    east: bool = false,
    north: bool = false,
    south: bool = false,
    link: bool = false,
    reserved: u3 = 0,
};

/// One portal cell of a chunk: its chunk-local index (`row * chunk_tiles + column`), its
/// chunk-local component label, and its flags.
pub const NavPortal = struct {
    local: u8,
    label: u8,
    flags: PortalFlags,
};

/// One link leaving an open endpoint of a chunk. Side a of a world link always leaves;
/// side b leaves only when the link is bidirectional. The target is live while its cell is
/// open, checked when the link is expanded.
pub const NavLink = struct {
    local: u8,
    to_level: u16,
    to_cell: u32,
    cost: u32,
    // Row in `WorldSystem.levelLinks()`; orders links of one local cell.
    link: u32,
};

/// One chunk's portals and links, valid until the next nav batch. Border portals and extra
/// (non-border link endpoint) portals are each sorted by `local`; links by (`local`, link).
pub const ChunkPortals = struct {
    border: []const NavPortal = &.{},
    extra: []const NavPortal = &.{},
    links: []const NavLink = &.{},

    /// The portal at chunk-local cell `local`, or null. A scan of the border portals (at
    /// most `max_border_portals`), then a binary search of the extra ones.
    pub inline fn find(self: ChunkPortals, local: u8) ?NavPortal {
        if (findLocalLinear(self.border, local)) |index| return self.border[index];
        if (std.sort.binarySearch(NavPortal, self.extra, local, orderPortalLocal)) |index| return self.extra[index];
        return null;
    }

    /// The links leaving chunk-local cell `local`, in link order. O(log links).
    pub fn linksAt(self: ChunkPortals, local: u8) []const NavLink {
        const start, const end = std.sort.equalRange(NavLink, self.links, local, orderLinkLocal);
        return self.links[start..end];
    }

    fn portalCount(self: ChunkPortals) usize {
        return self.border.len + self.extra.len;
    }
};

fn orderPortalLocal(local: u8, portal: NavPortal) std.math.Order {
    return std.math.order(local, portal.local);
}

fn orderLinkLocal(local: u8, link: NavLink) std.math.Order {
    return std.math.order(local, link.local);
}

fn portalLessThan(_: void, a: NavPortal, b: NavPortal) bool {
    return a.local < b.local;
}

fn linkLessThan(_: void, a: NavLink, b: NavLink) bool {
    if (a.local != b.local) return a.local < b.local;
    return a.link < b.link;
}

const RecordRow = struct {
    border_count: u8,
    link_slot: u32,
    // The record's connectivity nodes, linked through `NodeRow.sibling`, and the number of
    // distinct labels its portals hold.
    node_head: u32,
    label_count: u8,
};

// One pooled record's columns.
pub const record_row_bytes = 2 * @sizeOf(u8) + 2 * @sizeOf(u32);

const LinkSlotRow = struct {
    extra: std.ArrayList(NavPortal),
    links: std.ArrayList(NavLink),
};

const empty_portal = NavPortal{ .local = 0, .label = 0, .flags = .{} };
const empty_record = RecordRow{ .border_count = 0, .link_slot = no_link_slot, .node_head = no_node, .label_count = 0 };
const empty_node = NodeRow{ .label = 0, .comp = no_comp, .sibling = no_node, .queue = 0, .queue_row = no_node };

/// One level's records. `record_dir` holds each chunk's record id or none; a record's border
/// portals sit in a fixed `border_stride` window of `border`; a record with link
/// endpoints holds a link slot; a record lists one connectivity node per portal-bearing
/// label. Records, link slots, and nodes are pools with free lists whose capacity covers
/// every pooled id, so a release never allocates.
pub const NavLevelGraph = struct {
    record_dir: std.ArrayList(u32) = .empty,
    records: std.MultiArrayList(RecordRow) = .{},
    border: std.ArrayList(NavPortal) = .empty,
    record_free: std.ArrayList(u32) = .empty,
    link_slots: std.MultiArrayList(LinkSlotRow) = .{},
    link_free: std.ArrayList(u32) = .empty,
    nodes: std.MultiArrayList(NodeRow) = .{},
    node_free: std.ArrayList(u32) = .empty,
    // The world's content revision this level was built from.
    built_revision: u32 = 0,
    // Border portal window per record: `borderPortalBound` of the level's chunk edge.
    border_stride: usize = max_border_portals,
    // Column views refreshed whenever a pool grows; read on the search path.
    border_count: []u8 = &.{},
    record_link_slot: []u32 = &.{},
    slot_extra: []std.ArrayList(NavPortal) = &.{},
    slot_links: []std.ArrayList(NavLink) = &.{},
    record_node_head: []u32 = &.{},
    record_label_count: []u8 = &.{},
    node_label: []u8 = &.{},
    node_comp: []u32 = &.{},
    node_sibling: []u32 = &.{},
    node_queue: []u64 = &.{},
    node_queue_row: []u32 = &.{},
    // This level's plan merge sets, sized to its chunks when it is built.
    plan: LevelPlanSets = .{},

    pub fn deinit(self: *NavLevelGraph, allocator: std.mem.Allocator) void {
        self.plan.deinit(allocator);
        for (self.slot_extra) |*extra| extra.deinit(allocator);
        for (self.slot_links) |*links| links.deinit(allocator);
        self.node_free.deinit(allocator);
        self.nodes.deinit(allocator);
        self.link_free.deinit(allocator);
        self.link_slots.deinit(allocator);
        self.record_free.deinit(allocator);
        self.border.deinit(allocator);
        self.records.deinit(allocator);
        self.record_dir.deinit(allocator);
        self.* = undefined;
    }

    fn refreshColumns(self: *NavLevelGraph) void {
        const records = self.records.slice();
        self.border_count = records.items(.border_count);
        self.record_link_slot = records.items(.link_slot);
        self.record_node_head = records.items(.node_head);
        self.record_label_count = records.items(.label_count);
        const slots = self.link_slots.slice();
        self.slot_extra = slots.items(.extra);
        self.slot_links = slots.items(.links);
        const nodes = self.nodes.slice();
        self.node_label = nodes.items(.label);
        self.node_comp = nodes.items(.comp);
        self.node_sibling = nodes.items(.sibling);
        self.node_queue = nodes.items(.queue);
        self.node_queue_row = nodes.items(.queue_row);
    }

    /// `chunk`'s record id, or null when it holds none.
    pub fn recordOf(self: *const NavLevelGraph, chunk: u32) ?u32 {
        const record = self.record_dir.items[chunk];
        return if (record == no_record) null else record;
    }

    /// Distinct labels among `chunk`'s portals; 0 with no record.
    pub fn labelCount(self: *const NavLevelGraph, chunk: u32) usize {
        const record = self.recordOf(chunk) orelse return 0;
        return self.record_label_count[record];
    }

    /// The node row of `chunk`'s label `label`, or `no_node` when the label holds no portal.
    /// O(portal-bearing labels of the chunk).
    pub fn nodeOf(self: *const NavLevelGraph, chunk: u32, label: u8) u32 {
        const record = self.recordOf(chunk) orelse return no_node;
        var row = self.record_node_head[record];
        while (row != no_node) : (row = self.node_sibling[row]) {
            if (self.node_label[row] == label) return row;
        }
        return no_node;
    }

    /// Live node rows.
    pub fn nodeCount(self: *const NavLevelGraph) usize {
        return self.nodes.len - self.node_free.items.len;
    }

    /// Grows the free node list to at least `needed` rows, so that many claims pop without
    /// allocating (`growPool`; an empty level's pool takes exactly `needed`). `needed` is at
    /// most the level's chunks times `maxChunkLabels` of its edge: the live rows plus a
    /// batch's claims then stay under the label space `validateChunkGrid` keeps below
    /// `no_node`.
    pub fn ensureFreeNodes(self: *NavLevelGraph, allocator: std.mem.Allocator, needed: usize, pool_grows: *u64) !void {
        // The pool may move before a later step fails: the views follow it either way.
        defer self.refreshColumns();
        // Live rows and `needed` are each at most chunks * maxChunkLabels(edge), so their
        // sum is at most chunks * (edge^2 + 1), the label space, below 2^32 - 1.
        std.debug.assert(self.nodeCount() + needed < no_node);
        try growPool(NodeRow, allocator, &self.nodes, &self.node_free, needed, empty_node, no_node, pool_grows);
    }

    /// Takes a free node row for `label`, with no comp yet; the batch reserve covered it.
    pub fn claimNode(self: *NavLevelGraph, label: u8) u32 {
        const row = self.node_free.pop().?;
        self.node_label[row] = label;
        self.node_comp[row] = no_comp;
        self.node_sibling[row] = no_node;
        return row;
    }

    /// Returns `row`, already off its comp and its record's list, to the pool.
    pub fn releaseNode(self: *NavLevelGraph, row: u32) void {
        self.node_comp[row] = no_comp;
        std.debug.assert(self.node_free.items.len < self.node_free.capacity);
        self.node_free.appendAssumeCapacity(row);
    }

    /// `chunk`'s portals and links; empty when the chunk holds no record.
    pub inline fn chunkPortals(self: *const NavLevelGraph, chunk: u32) ChunkPortals {
        const record = self.record_dir.items[chunk];
        if (record == no_record) return .{};
        const base = @as(usize, record) * self.border_stride;
        var portals = ChunkPortals{ .border = self.border.items[base .. base + self.border_count[record]] };
        const slot = self.record_link_slot[record];
        if (slot != no_link_slot) {
            portals.extra = self.slot_extra[slot].items;
            portals.links = self.slot_links[slot].items;
        }
        return portals;
    }

    /// Records holding portals.
    pub fn recordCount(self: *const NavLevelGraph) usize {
        return self.records.len - self.record_free.items.len;
    }

    fn residentBytes(self: *const NavLevelGraph) usize {
        var bytes = self.record_dir.capacity * @sizeOf(u32) +
            self.records.capacity * record_row_bytes +
            self.nodes.capacity * @sizeOf(NodeRow) +
            self.node_free.capacity * @sizeOf(u32) +
            self.border.capacity * @sizeOf(NavPortal) +
            self.record_free.capacity * @sizeOf(u32) +
            self.link_slots.capacity * @sizeOf(LinkSlotRow) +
            self.link_free.capacity * @sizeOf(u32) +
            self.plan.residentBytes();
        for (self.slot_extra) |extra| bytes += extra.capacity * @sizeOf(NavPortal);
        for (self.slot_links) |links| bytes += links.capacity * @sizeOf(NavLink);
        return bytes;
    }

    // Grows the free record list to at least `needed` ids, so the next `needed` claims pop
    // without allocating (`growPool`), each new record with its border window.
    fn ensureFreeRecords(self: *NavLevelGraph, allocator: std.mem.Allocator, needed: usize, pool_grows: *u64) !void {
        defer self.refreshColumns();
        // Live records plus a batch's claims, each for a chunk holding none: at most the
        // chunk count, which `validateChunkGrid` keeps below 2^31 (`no_record`).
        std.debug.assert(self.recordCount() + needed < no_record);
        const added = needed -| self.record_free.items.len;
        // The border windows first: a growth after the pool's could fail with records
        // lacking windows.
        try types.growList(&self.border, allocator, (self.records.len + added) * self.border_stride, pool_grows);
        const before = self.records.len;
        try growPool(RecordRow, allocator, &self.records, &self.record_free, needed, empty_record, no_record, pool_grows);
        std.debug.assert(self.records.len == before + added);
        self.border.appendNTimesAssumeCapacity(empty_portal, added * self.border_stride);
    }

    // Grows the free link-slot list to at least `needed` ids (`growPool`).
    fn ensureFreeLinkSlots(self: *NavLevelGraph, allocator: std.mem.Allocator, needed: usize, pool_grows: *u64) !void {
        defer self.refreshColumns();
        // At most one link slot per record, so under `no_link_slot` as records are.
        std.debug.assert(self.link_slots.len - self.link_free.items.len + needed < no_link_slot);
        try growPool(LinkSlotRow, allocator, &self.link_slots, &self.link_free, needed, .{ .extra = .empty, .links = .empty }, no_link_slot, pool_grows);
    }

    fn claimRecord(self: *NavLevelGraph, chunk: u32) u32 {
        std.debug.assert(self.record_dir.items[chunk] == no_record);
        // The batch reserve grew the free list to cover every claim.
        const record = self.record_free.pop().?;
        self.border_count[record] = 0;
        self.record_link_slot[record] = no_link_slot;
        self.record_node_head[record] = no_node;
        self.record_label_count[record] = 0;
        self.record_dir.items[chunk] = record;
        return record;
    }

    fn claimLinkSlot(self: *NavLevelGraph, record: u32) void {
        std.debug.assert(self.record_link_slot[record] == no_link_slot);
        // The batch reserve grew the free list to cover every claim.
        const slot = self.link_free.pop().?;
        self.slot_extra[slot].clearRetainingCapacity();
        self.slot_links[slot].clearRetainingCapacity();
        self.record_link_slot[record] = slot;
    }

    fn releaseLinkSlot(self: *NavLevelGraph, record: u32) void {
        const slot = self.record_link_slot[record];
        if (slot == no_link_slot) return;
        self.slot_extra[slot].clearRetainingCapacity();
        self.slot_links[slot].clearRetainingCapacity();
        std.debug.assert(self.link_free.items.len < self.link_free.capacity);
        self.link_free.appendAssumeCapacity(slot);
        self.record_link_slot[record] = no_link_slot;
    }

    fn releaseRecord(self: *NavLevelGraph, chunk: u32) void {
        const record = self.record_dir.items[chunk];
        // A record without portals holds no node.
        std.debug.assert(self.record_node_head[record] == no_node);
        self.releaseLinkSlot(record);
        self.border_count[record] = 0;
        std.debug.assert(self.record_free.items.len < self.record_free.capacity);
        self.record_free.appendAssumeCapacity(record);
        self.record_dir.items[chunk] = no_record;
    }
};

// A changed key's remask slot before the commit claims it: the chunk may end mixed and
// holds no cell block yet.
const claim_pending: u32 = no_block - 1;

/// The threaded stages of a nav batch: key plan, remask and component flood, record patch,
/// connectivity seed, gather, and flood, and the one-way closure's candidates, resolve,
/// mask, plan, rows, and landing.
pub const NavStage = enum {
    plan,
    remask,
    patch,
    conn_seed,
    conn_gather,
    conn_flood,
    conn_closure_candidates,
    conn_closure_resolve,
    conn_closure_mask,
    conn_closure_plan,
    conn_closure_rows,
    conn_closure_land,
};

/// One tuner per nav stage, owned by the nav's owner.
pub const NavStageTuners = std.EnumArray(NavStage, AdaptiveWorkTuner);

/// Threading for nav batches: the shared thread system plus each stage's tuner, all under
/// one set of range controls. Absent: every stage runs inline.
pub const NavUpdateThreads = struct {
    thread_system: *ThreadSystem,
    tuners: *NavStageTuners,
    controls: StageControls = .{},
};

// `stage`'s dispatch, or null to run it inline.
fn stageThreads(threads: ?NavUpdateThreads, stage: NavStage) ?Dispatch {
    const t = threads orelse return null;
    return Dispatch.init(t.thread_system, t.tuners.getPtr(stage), t.controls);
}

fn closureThreads(threads: ?NavUpdateThreads) ClosureThreads {
    return .{
        .candidates = stageThreads(threads, .conn_closure_candidates),
        .resolve = stageThreads(threads, .conn_closure_resolve),
        .mask = stageThreads(threads, .conn_closure_mask),
        .plan = stageThreads(threads, .conn_closure_plan),
        .rows = stageThreads(threads, .conn_closure_rows),
        .land = stageThreads(threads, .conn_closure_land),
    };
}

/// Whether ascending batch `keys` hold `key`. O(log keys).
pub fn sortedContains(keys: []const u64, key: u64) bool {
    return std.sort.binarySearch(u64, keys, key, orderKey) != null;
}

fn orderKey(wanted: u64, item: u64) std.math.Order {
    return std.math.order(wanted, item);
}

/// The runs of level-major sorted batch keys sharing a level, in order. O(1) per key.
pub const LevelRuns = struct {
    keys: []const u64,
    start: usize = 0,

    pub const Run = struct { level: u16, start: usize, end: usize };

    pub fn next(self: *LevelRuns) ?Run {
        if (self.start >= self.keys.len) return null;
        const level = keyLevel(self.keys[self.start]);
        var end = self.start + 1;
        while (end < self.keys.len and keyLevel(self.keys[end]) == level) end += 1;
        defer self.start = end;
        return .{ .level = level, .start = self.start, .end = end };
    }
};

// Batch key lists. Plan windows start on cache lines, so the staging lists are aligned.
const OrderedIndexSet = @import("../chunk_list_map.zig").OrderedIndexSet;
const bitSetBytes = @import("../chunk_list_map.zig").bitSetBytes;
const KeyList = std.array_list.Aligned(u64, .fromByteUnits(thread_shared_record_alignment));
const PlanTallyList = std.array_list.Aligned(PlanTally, .fromByteUnits(thread_shared_record_alignment));
pub const key_window_alignment: usize = thread_shared_record_alignment / @sizeOf(u64);

// Sorts `keys` and drops repeats in place; returns the unique count. O(k log k).
fn sortUnique(keys: []u64) usize {
    pdqSort(u64, keys, {}, std.sort.asc(u64));
    var write: usize = 0;
    for (keys) |key| {
        if (write != 0 and keys[write - 1] == key) continue;
        keys[write] = key;
        write += 1;
    }
    return write;
}

// The key lists a batch plans. `changed`: the chunks a mark touches (remasked). `dirty`:
// those plus both endpoint chunks of each new link (the batch result); its stream stages
// only the link keys, and the merge adds the changed keys. `patch`: the dirty keys plus the
// changed keys' orthogonal neighbours (records re-derived); a mark stages the neighbours
// of its span's edge chunks only, the rest lying inside the span.
const PlanStream = enum { changed, dirty, patch };
pub const plan_streams = std.meta.tags(PlanStream).len;

// Need groups of the batch lists for their release window (`types.StagingWindow`): each plan
// stream's staging and key list (they swap buffers), and the plan ranges.
const StagingGroup = enum { changed, dirty, patch, ranges };

fn streamGroup(stream: PlanStream) StagingGroup {
    return switch (stream) {
        .changed => .changed,
        .dirty => .dirty,
        .patch => .patch,
    };
}

// One plan range's key windows in the staging lists.
const PlanWindow = struct {
    start: [plan_streams]usize,
    // Exclusive: the start plus the range's key bounds.
    end: [plan_streams]usize = @splat(0),
};

// One plan range's unique key counts, padded to its own cache line.
const PlanTally = struct {
    counts: [plan_streams]usize align(thread_shared_record_alignment) = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(PlanTally) % thread_shared_record_alignment == 0);
}

// One level's share of the threaded plan merge (`NavGraph.mergePlanWindows`): its patch
// chunks in order and flags for its changed chunks and its new links' endpoint chunks
// (`dirty`), sized to the level's chunks at build and empty between batches. The counts tally
// the flags set in the current merge.
const LevelPlanSets = struct {
    order: OrderedIndexSet = .{},
    changed: std.bit_set.Dynamic = .{},
    dirty: std.bit_set.Dynamic = .{},
    changed_count: usize = 0,
    dirty_count: usize = 0,

    fn init(allocator: std.mem.Allocator, chunk_count: usize) !LevelPlanSets {
        var sets: LevelPlanSets = .{};
        errdefer sets.deinit(allocator);
        _ = try sets.order.reserve(allocator, chunk_count);
        sets.changed = try .initEmpty(allocator, chunk_count);
        sets.dirty = try .initEmpty(allocator, chunk_count);
        return sets;
    }

    fn deinit(self: *LevelPlanSets, allocator: std.mem.Allocator) void {
        self.dirty.deinit(allocator);
        self.changed.deinit(allocator);
        self.order.deinit(allocator);
        self.* = .{};
    }

    // Empty: no patch chunk queued and no flag set since the last merge drained.
    fn isClear(self: *const LevelPlanSets) bool {
        return self.order.isEmpty() and self.changed_count == 0 and self.dirty_count == 0;
    }

    fn residentBytes(self: *const LevelPlanSets) usize {
        return self.order.residentBytes() + bitSetBytes(self.changed) + bitSetBytes(self.dirty);
    }
};

// One range of the plan stage over marks then new links: each item writes its keys into the
// range's window of every stream; the range then sorts and dedupes each window.
const PlanJob = struct {
    graph: *const NavGraph,
    world: *const WorldSystem,
    marks: []const NavMark,
    links: []const LevelLink,
    items_per_range: usize,
    windows: []const PlanWindow,
    staging: [plan_streams][]u64,
    tallies: []PlanTally,
};

// SIMD verdict: scalar. Key writes over a mark's chunk span, then a pdq sort and an in-place
// dedupe of each window (comparison sort and compaction, irreducible).
fn planJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *PlanJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.tallies.len and range.index < job.windows.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.marks.len + job.links.len);
    const window = job.windows[range.index];
    var ends = window.start;
    for (range.start..range.end) |item| job.graph.writeItemKeys(job.world, job.marks, job.links, item, job.staging, &ends);
    // The writes stayed inside this range's own windows.
    for (ends, window.end) |written, bound| std.debug.assert(written <= bound);
    var tally = PlanTally{};
    for (0..plan_streams) |stream| tally.counts[stream] = sortUnique(job.staging[stream][window.start[stream]..ends[stream]]);
    job.tallies[range.index] = tally;
}

/// What a patch key needs from the reserve: its endpoint count on the level and whether it
/// may hold portals after the batch.
pub const PatchInfo = struct {
    endpoints: u32,
    needs_record: bool,
};

/// A level being built into fresh storage: batch stages resolve `index` to it.
pub const LevelTarget = struct {
    index: u16,
    grid: *NavGrid,
    graph: *NavLevelGraph,
};

/// The levels one batch reads and writes; a level being built resolves to its fresh storage.
pub const BatchLevels = struct {
    grids: []NavGrid,
    graphs: []NavLevelGraph,
    fresh: ?LevelTarget = null,

    /// Whether `level` is built (or is the level being built).
    pub fn built(self: BatchLevels, level: u16) bool {
        if (self.fresh) |fresh| {
            if (fresh.index == level) return true;
        }
        return @as(usize, level) < self.grids.len;
    }

    pub fn grid(self: BatchLevels, level: u16) *NavGrid {
        if (self.fresh) |fresh| {
            if (fresh.index == level) return fresh.grid;
        }
        return &self.grids[level];
    }

    pub fn graph(self: BatchLevels, level: u16) *NavLevelGraph {
        if (self.fresh) |fresh| {
            if (fresh.index == level) return fresh.graph;
        }
        return &self.graphs[level];
    }
};

// One range of the remask stage: each key composes its own chunk's cells from the world and
// the colliders listed there, writes them (and its labels) into its own directory entry and
// claimed block, adds its new blocked count to its item's delta, and, for a marks batch,
// writes the cells that changed (old XOR new bits) into its item's mask.
const RemaskJob = struct {
    levels: BatchLevels,
    colliders: ColliderView,
    world: ?*const WorldSystem,
    keys: []const u64,
    slots: []const u32,
    deltas: []i32,
    masks: ?[]ChunkBits,
    range_count: usize = 0,
};

// SIMD verdict: word-parallel scalar. The changed mask is four u64 XORs per chunk.
fn remaskJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *RemaskJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.keys.len and range.end <= job.slots.len and range.end <= job.deltas.len);
    if (job.masks) |masks| std.debug.assert(range.end <= masks.len);
    for (range.start..range.end) |item| {
        const key = job.keys[item];
        const grid = job.levels.grid(keyLevel(key));
        const bits = grid.composeChunk(keyChunk(key), job.world, job.colliders);
        // The old bits are read before the write, which may reuse the chunk's block.
        if (job.masks) |masks| {
            const old = grid.chunkBlockedBits(keyChunk(key));
            for (&masks[item], old, bits) |*changed, before, after| changed.* = before ^ after;
        }
        // A chunk holds at most max_chunk_size_tiles^2 cells.
        job.deltas[item] += @intCast(grid.writeChunk(keyChunk(key), job.slots[item], bits));
    }
}

// One range of the patch stage: each key re-derives its own chunk's record, appending at most
// its planned endpoint count to its link slot.
const PatchJob = struct {
    graph: *const NavGraph,
    levels: BatchLevels,
    world: ?*const WorldSystem,
    keys: []const u64,
    infos: []const PatchInfo,
    range_count: usize = 0,
};

// SIMD verdict: scalar per key (`patchRecord`): side runs are bit scans of at most 16 bits,
// endpoints a list walk with one bit-set dedupe each, sorts of at most a chunk's portals.
fn patchJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *PatchJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.keys.len and job.infos.len == job.keys.len);
    for (job.keys[range.start..range.end], job.infos[range.start..range.end]) |key, info| {
        const level = keyLevel(key);
        job.graph.patchRecord(job.levels.grid(level), job.levels.graph(level), job.world, level, keyChunk(key), info.endpoints);
    }
}

// Folds one batch's connectivity counters and stage shapes into `stats`: level builds and the
// marks batch sum. Only the perf log's flood batch folds without `runtime_perf_log.enabled`.
fn addConnectivityStats(stats: *NavUpdateStats, conn: *const Connectivity, counters: ConnectivityCounters) void {
    accumulateBatch(&stats.conn_flood_batch, conn.last_flood_batch);
    addClosureStats(stats, conn, counters.closure);
    if (comptime !runtime_perf_log.enabled) return;
    stats.perf.conn_groups += counters.perf.groups;
    stats.perf.conn_families += counters.families;
    stats.perf.conn_rounds += counters.perf.rounds;
    stats.perf.conn_build_visits += counters.perf.build_visits;
    stats.perf.conn_flood_nodes += counters.perf.flood_nodes;
    stats.perf.conn_splits += counters.perf.splits;
    stats.perf.conn_merges += counters.perf.merges;
    if (counters.perf.rounds != 0) {
        stats.perf.conn_round_items_min = if (stats.perf.conn_round_items_max == 0) counters.perf.round_items_min else @min(stats.perf.conn_round_items_min, counters.perf.round_items_min);
        stats.perf.conn_round_items_max = @max(stats.perf.conn_round_items_max, counters.perf.round_items_max);
    }
    stats.perf.conn_flood_off_main_ns += counters.perf.flood_off_main_ns;
    accumulateBatch(&stats.perf.conn_seed_batch, conn.perf.last_seed_batch);
    accumulateBatch(&stats.perf.conn_gather_batch, conn.perf.last_gather_batch);
}

// Folds one batch's closure counters and commit-side stage shapes into `stats`; the
// candidates and the landing fold where they run. Only the perf log's rows batch folds
// without `runtime_perf_log.enabled`.
fn addClosureStats(stats: *NavUpdateStats, conn: *const Connectivity, counters: ClosureCounters) void {
    if (counters.links != 0) accumulateBatch(&stats.conn_closure_rows_batch, conn.closure.last_rows_batch);
    if (comptime !runtime_perf_log.enabled) return;
    stats.perf.closure_touched += counters.perf.touched;
    stats.perf.closure_links += counters.links;
    stats.perf.closure_terms_new += counters.perf.terms_new;
    stats.perf.closure_terms_left += counters.perf.terms_left;
    stats.perf.closure_a_rows += counters.perf.a_rows;
    stats.perf.closure_rounds += counters.perf.rounds;
    stats.perf.closure_words_written += counters.perf.words_written;
    stats.perf.closure_shrinks += counters.perf.shrinks;
    stats.perf.closure_block_allocs += counters.perf.block_allocs;
    stats.perf.closure_block_frees += counters.perf.block_frees;
    stats.perf.closure_live_words = conn.closure.live_words;
    stats.perf.closure_tail_capacity = conn.closure.tail.capacity;
    if (conn.closure.active) {
        const limits = conn.closure.limits;
        stats.perf.closure_tail_bound = @max(stats.perf.closure_tail_bound, limits.tail_words);
        stats.perf.closure_tail_used = @max(stats.perf.closure_tail_used, counters.perf.tail_words);
        stats.perf.closure_candidate_words = @max(stats.perf.closure_candidate_words, limits.candidate_words);
        stats.perf.closure_kb = @max(stats.perf.closure_kb, limits.k_b);
    }
    if (counters.links == 0) return;
    accumulateBatch(&stats.perf.conn_closure_resolve_batch, conn.closure.perf.last_resolve_batch);
    accumulateBatch(&stats.perf.conn_closure_mask_batch, conn.closure.perf.last_mask_batch);
    accumulateBatch(&stats.perf.conn_closure_plan_batch, conn.closure.perf.last_plan_batch);
}

/// A marks batch between `NavGraph.prepareMarks` and its commit or abort.
pub const PreparedMarks = struct {
    marks: []const NavMark,
    new_link_count: usize,
    // The world for a world-backed graph; null for bounds.
    world: ?*const WorldSystem,
};

/// What a committed marks batch changed, valid until the next batch.
pub const NavBatchResult = struct {
    changed: bool,
    /// Sorted and deduped: the chunks the marks changed plus both endpoint chunks of each
    /// link the batch applied.
    dirty_keys: []const u64,
    /// Sorted and deduped: the chunks the marks remasked.
    changed_keys: []const u64,
    /// Per changed key, its cells whose blocking the batch flipped (old XOR new bits);
    /// a link changes no cell.
    changed_masks: []const ChunkBits,
};

/// What a nav build covers.
pub const NavExtent = union(enum) {
    /// Every level of a world: nav cells are its tiles and nav chunks its chunks.
    world: *const WorldSystem,
    /// One world-less level over a `width` x `height` rect cut into `cell_size` cells.
    bounds: struct { width: f32, height: f32, cell_size: f32, chunk_tiles: u16 },

    /// The cell grid a build over this extent uses; the static colliders a nav reads must
    /// be placed on it. Fails loudly (`ChunkGridError`) when its index widths do not fit.
    pub fn colliderGeometry(self: NavExtent) ChunkGridError!ColliderGeometry {
        const cells = try self.validatedCellGrid();
        return ColliderGeometry.init(cells.cell_size, cells.width, cells.height, cells.chunk_tiles);
    }

    const CellGrid = struct { cell_size: f32, width: u32, height: u32, chunk_tiles: u16 };

    // This extent's cell grid once `validateChunkGrid` accepts it, before anything is sized
    // from it.
    fn validatedCellGrid(self: NavExtent) ChunkGridError!CellGrid {
        const cell_size: f32, const width: usize, const height: usize, const chunk_tiles: u16 = switch (self) {
            // A nav cell is a tile and a nav chunk the world's chunk.
            .world => |world_system| blk: {
                std.debug.assert(std.math.isFinite(world_system.tile_size) and world_system.tile_size > 0);
                break :blk .{ world_system.tile_size, world_system.width, world_system.height, world_system.chunk_size_tiles };
            },
            // A 0/negative/non-finite cell_size or bound collapses to a 1x1 grid. A side's
            // quotient is clamped while a float (an oversize or subnormal-cell quotient is
            // huge or inf), so the validator, not @intFromFloat, rejects it.
            .bounds => |bounds| blk: {
                const cell_size: f32 = if (std.math.isFinite(bounds.cell_size) and bounds.cell_size > 0) bounds.cell_size else 1.0;
                const safe_w: f32 = if (std.math.isFinite(bounds.width) and bounds.width > 0) bounds.width else 0;
                const safe_h: f32 = if (std.math.isFinite(bounds.height) and bounds.height > 0) bounds.height else 0;
                break :blk .{
                    cell_size,
                    @max(@as(usize, 1), @as(usize, @intFromFloat(@min(@ceil(safe_w / cell_size), side_quotient_clamp)))),
                    @max(@as(usize, 1), @as(usize, @intFromFloat(@min(@ceil(safe_h / cell_size), side_quotient_clamp)))),
                    bounds.chunk_tiles,
                };
            },
        };
        try validateChunkGrid(width, height, chunk_tiles);
        // `validateChunkGrid` keeps each side below 2^32 - 1.
        return .{ .cell_size = cell_size, .width = @intCast(width), .height = @intCast(height), .chunk_tiles = chunk_tiles };
    }
};

// Past every side `validateChunkGrid` accepts, and exact in f32.
const side_quotient_clamp: f32 = 0x1p32;

// Per-level cell grids and chunk records, built from a world (or bounds) and changed only
// through `commitMarks` and `buildLevel` on the main thread; read-only to queries between.
pub const NavGraph = struct {
    allocator: std.mem.Allocator,
    cell_size: f32 = default_cell_size,
    // Every level's sides and chunk tiling (`NavGrid.geometry`).
    geometry: ChunkGeometry = .empty,
    // Bumped only by a world build; part of every query key.
    version: u32 = 1,
    // Built over a world: levels, links, and content revisions follow that world.
    world_backed: bool = false,
    levels: std.ArrayList(NavGrid) = .empty,
    // One record set per level, paired index-for-index with `levels`.
    level_graphs: std.ArrayList(NavLevelGraph) = .empty,
    /// Rows of `levelLinks()` already folded into records and `link_bounds`. Links are
    /// append-only, so a marks batch re-derives both endpoint chunks of `[links_applied, len)`,
    /// folds them into `link_bounds`, and advances it; a level build leaves it alone.
    links_applied: usize = 0,
    /// Bounds over every link folded so far; written only by a world build and a marks commit.
    link_bounds: LinkBounds = .{},
    /// Per level (index-for-index with `levels`), the level-crossing short links leaving it,
    /// folded with `link_bounds`. Grows at a level append; a level replace keeps its entry.
    level_crossings: std.ArrayList(LevelCrossings) = .empty,
    /// Connectivity ids over every level's nodes, maintained by every batch.
    connectivity: Connectivity = .{},
    // The world-wide content revision every level was last checked against.
    built_world_revision: u32 = 0,
    // Batch buffers, reused across batches. `changed_masks` holds, per changed key of the
    // marks batch, the cells it flipped; it and the key lists are valid only within the
    // batch result (`NavBatchResult`), as the step's staging release may free them.
    changed_keys: KeyList = .empty,
    changed_masks: std.ArrayList(ChunkBits) = .empty,
    // Per changed key: the block slot its remask may fill (`no_block` when it can only end
    // uniform) and its blocked-count delta.
    remask_slots: std.ArrayList(u32) = .empty,
    remask_deltas: std.ArrayList(i32) = .empty,
    patch_keys: KeyList = .empty,
    // The batch result's keys: the changed keys plus both endpoint chunks of each new link.
    dirty_keys: KeyList = .empty,
    // Plan stage staging (per-range key windows, one list per stream) and tallies.
    plan_staging: [plan_streams]KeyList = @splat(.empty),
    plan_windows: std.ArrayList(PlanWindow) = .empty,
    plan_tallies: PlanTallyList = .empty,
    // The threaded plan merge's levels holding keys, in order (each level's chunks are in its
    // `LevelPlanSets`). Covers every level, grows at level append, and is empty between
    // batches.
    plan_levels: OrderedIndexSet = .{},
    patch_info: std.ArrayList(PatchInfo) = .empty,
    // The batch lists' release window over marks batches.
    staging_window: types.StagingWindow(StagingGroup) = .{},
    // Set between a prepared marks batch and its commit or abort.
    batch_prepared: bool = false,
    /// Telemetry: growths of the nav pools, level directories, plan sets, and batch staging
    /// (one count per list or pool that grew). The first logs once.
    pool_grows: u64 = 0,
    pool_growth_logged: bool = false,
    /// Telemetry, kept only with `runtime_perf_log.enabled`: closure landings `landClosure`
    /// deferred by `OutOfMemory`, across updates (failed ones too). The first logs once.
    perf: Perf = .{},
    land_deferral_logged: bool = false,

    pub const Perf = if (runtime_perf_log.enabled) struct { land_deferrals: u64 = 0 } else struct {};

    pub fn deinit(self: *NavGraph) void {
        self.connectivity.deinit(self.allocator);
        self.plan_levels.deinit(self.allocator);
        self.plan_tallies.deinit(self.allocator);
        self.plan_windows.deinit(self.allocator);
        for (&self.plan_staging) |*staging| staging.deinit(self.allocator);
        self.dirty_keys.deinit(self.allocator);
        self.patch_info.deinit(self.allocator);
        self.patch_keys.deinit(self.allocator);
        self.remask_deltas.deinit(self.allocator);
        self.remask_slots.deinit(self.allocator);
        self.changed_masks.deinit(self.allocator);
        self.changed_keys.deinit(self.allocator);
        self.level_crossings.deinit(self.allocator);
        for (self.level_graphs.items) |*level_graph| level_graph.deinit(self.allocator);
        self.level_graphs.deinit(self.allocator);
        for (self.levels.items) |*level_grid| level_grid.deinit(self.allocator);
        self.levels.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn levelCount(self: *const NavGraph) usize {
        return self.levels.items.len;
    }

    pub fn levelGraph(self: *const NavGraph, level: u16) ?*const NavLevelGraph {
        if (@as(usize, level) >= self.level_graphs.items.len) return null;
        return &self.level_graphs.items[level];
    }

    pub fn grid(self: *const NavGraph, level: u16) ?*const NavGrid {
        if (@as(usize, level) >= self.levels.items.len) return null;
        return &self.levels.items[level];
    }

    pub fn valid(self: *const NavGraph) bool {
        return self.levels.items.len != 0 and self.levels.items[0].valid();
    }

    pub fn cellCount(self: *const NavGraph) usize {
        return self.geometry.width * self.geometry.height;
    }

    /// The portals and links of `level`'s `chunk`; empty for an unbuilt level or a chunk
    /// with no record.
    pub inline fn chunkPortals(self: *const NavGraph, level: u16, chunk: u32) ChunkPortals {
        if (@as(usize, level) >= self.level_graphs.items.len) return .{};
        return self.level_graphs.items[level].chunkPortals(chunk);
    }

    /// Bytes held by the cell grids, records, and batch buffers (allocated capacity).
    pub fn residentBytes(self: *const NavGraph) usize {
        var bytes = self.changed_keys.capacity * @sizeOf(u64) +
            self.patch_keys.capacity * @sizeOf(u64) +
            self.dirty_keys.capacity * @sizeOf(u64) +
            self.remask_deltas.capacity * @sizeOf(i32) +
            self.remask_slots.capacity * @sizeOf(u32) +
            self.patch_info.capacity * @sizeOf(PatchInfo) +
            self.changed_masks.capacity * @sizeOf(ChunkBits) +
            self.plan_windows.capacity * @sizeOf(PlanWindow) +
            self.plan_tallies.capacity * @sizeOf(PlanTally) +
            self.plan_levels.residentBytes() +
            self.level_crossings.capacity * @sizeOf(LevelCrossings);
        for (self.plan_staging) |staging| bytes += staging.capacity * @sizeOf(u64);
        for (self.levels.items) |*level_grid| bytes += level_grid.residentBytes();
        for (self.level_graphs.items) |*level_graph| bytes += level_graph.residentBytes();
        bytes += self.connectivity.residentBytes();
        return bytes;
    }

    /// Every level's chunk tiling; agrees with each level's `NavGrid.geometry`.
    pub fn chunkGeometry(self: *const NavGraph) ChunkGeometry {
        return self.geometry;
    }

    pub fn chunkCount(self: *const NavGraph) usize {
        return self.geometry.chunkCount();
    }

    // Rebuilds every level into a fresh graph and swaps it in, folding every world link into
    // fresh link bounds. The previous graph stays intact until every level built, so an error
    // leaves it unchanged. Bumps `version`. Returns the build's stage stats.
    // `colliders` must be placed on this extent's cell grid (`NavExtent.colliderGeometry`).
    pub fn rebuild(
        self: *NavGraph,
        colliders: ColliderView,
        extent: NavExtent,
        threads: ?NavUpdateThreads,
    ) !NavUpdateStats {
        const world: ?*const WorldSystem = switch (extent) {
            .world => |world_system| world_system,
            .bounds => null,
        };
        // Cell indices and chunk labels are u32 below `no_cell`; fail loud before any
        // dimension is stored or array sized.
        const cells = try extent.validatedCellGrid();
        const safe_cell_size = cells.cell_size;
        const chunk_tiles = cells.chunk_tiles;
        const width = cells.width;
        const height = cells.height;
        if (colliders.geometry) |geometry| {
            std.debug.assert(geometry.cell_size == safe_cell_size and geometry.grid.width == width and
                geometry.grid.height == height and geometry.grid.chunk_tiles == chunk_tiles);
        }

        var version = self.version +% 1;
        if (version == 0) version = 1;
        var fresh = NavGraph{
            .allocator = self.allocator,
            .cell_size = safe_cell_size,
            .geometry = .init(width, height, chunk_tiles),
            .version = version,
            .world_backed = world != null,
        };
        errdefer fresh.deinit();
        // A world builds exactly its levels; bounds build one.
        const level_count: usize = if (world) |world_system| world_system.levelCount() else 1;
        try types.growList(&fresh.levels, self.allocator, level_count, &fresh.pool_grows);
        try types.growList(&fresh.level_graphs, self.allocator, level_count, &fresh.pool_grows);
        try types.growList(&fresh.level_crossings, self.allocator, level_count, &fresh.pool_grows);
        if (try fresh.plan_levels.reserve(self.allocator, level_count)) fresh.pool_grows += 1;
        var stats = NavUpdateStats{};
        // Every level has the same chunks, so the levels share one level-sized staging, freed
        // once after the closure.
        for (0..level_count) |level| try fresh.buildLevel(colliders, world, @intCast(level), threads, &stats);
        // The one-way closure over every level at once, after the levels and before the swap.
        const fresh_levels = BatchLevels{ .grids = fresh.levels.items, .graphs = fresh.level_graphs.items };
        fresh.beginBuild();
        const closure_counters = try fresh.connectivity.buildClosure(self.allocator, fresh_levels, world, closureThreads(threads), &fresh.pool_grows, &stats);
        fresh.endBuild();
        addClosureStats(&stats, &fresh.connectivity, closure_counters);
        // The world build's staging frees now, down to the floors.
        fresh.finishStagingStep();
        if (world) |world_system| {
            fresh.foldNewLinks(world_system.levelLinks());
            fresh.links_applied = world_system.levelLinks().len;
            fresh.built_world_revision = world_system.contentRevision();
        }
        fresh.pool_grows = self.pool_grows + fresh.pool_grows;
        // The fresh levels' builds already logged their growth; the swap keeps that.
        fresh.pool_growth_logged = self.pool_growth_logged or fresh.pool_growth_logged;
        fresh.perf = self.perf;
        fresh.land_deferral_logged = self.land_deferral_logged;
        self.deinit();
        self.* = fresh;
        if (comptime logging.enabled(.info))
            logging.game.info("nav built: {} levels, {} resident bytes", .{ self.levels.items.len, self.residentBytes() });
        return stats;
    }

    /// Builds level `level_index` from `world` (or bounds when null) into fresh storage and
    /// swaps it in: appended when `level_index == levelCount()`, else replacing that level and
    /// freeing the old one, with its connectivity nodes. An error leaves the graph unchanged.
    /// O(chunks of the level + its nodes and edges); the remask, patch, and connectivity
    /// stages thread over its chunks (the flood over its searches). Never touches
    /// `links_applied`. The batch staging grows to the level, its needs kept out of the release
    /// window; the step's `finishStagingStep` frees it.
    pub fn buildLevel(self: *NavGraph, colliders: ColliderView, world: ?*const WorldSystem, level_index: u16, threads: ?NavUpdateThreads, stats: *NavUpdateStats) error{OutOfMemory}!void {
        self.beginBuild();
        defer self.endBuild();
        std.debug.assert(@as(usize, level_index) <= self.levels.items.len);
        const chunk_count = self.chunkCount();
        var section = StageTimer.begin();
        var fresh_grid = NavGrid{};
        errdefer fresh_grid.deinit(self.allocator);
        try fresh_grid.prepare(self.allocator, level_index, self.geometry.width, self.geometry.height, self.cell_size, self.geometry.chunk_tiles);
        var fresh_graph = NavLevelGraph{ .border_stride = borderPortalBound(self.geometry.chunk_tiles) };
        errdefer fresh_graph.deinit(self.allocator);
        try fresh_graph.record_dir.resize(self.allocator, chunk_count);
        @memset(fresh_graph.record_dir.items, no_record);
        fresh_graph.plan = try .init(self.allocator, chunk_count);
        // The fresh level's directories and plan sets, sized to its chunks: one growth.
        self.pool_grows += 1;
        stats.addMain(.reserve_ns, section.lap());

        // Plan: every chunk of the level, in order. A build has no dirty keys; their list
        // holds one changed chunk's, as every key list does once the build releases them.
        section = StageTimer.begin();
        try types.growList(&self.dirty_keys, self.allocator, one_chunk_keys[@backingInt(PlanStream.dirty)], &self.pool_grows);
        self.staging_window.note(.changed, chunk_count);
        self.staging_window.note(.patch, chunk_count);
        try types.resizeStaging(&self.changed_keys, self.allocator, chunk_count, &self.pool_grows);
        try types.resizeStaging(&self.patch_keys, self.allocator, chunk_count, &self.pool_grows);
        self.dirty_keys.clearRetainingCapacity();
        for (0..chunk_count) |chunk| {
            const key = chunkKey(level_index, @intCast(chunk));
            self.changed_keys.items[chunk] = key;
            self.patch_keys.items[chunk] = key;
        }
        stats.addMain(.plan_ns, section.lap());
        // Reserve.
        section = StageTimer.begin();
        const appending = @as(usize, level_index) == self.levels.items.len;
        if (appending) {
            try types.growList(&self.levels, self.allocator, self.levels.items.len + 1, &self.pool_grows);
            try types.growList(&self.level_graphs, self.allocator, self.level_graphs.items.len + 1, &self.pool_grows);
            try types.growList(&self.level_crossings, self.allocator, self.level_crossings.items.len + 1, &self.pool_grows);
            if (try self.plan_levels.reserve(self.allocator, self.levels.items.len + 1)) self.pool_grows += 1;
        }
        const levels = BatchLevels{
            .grids = self.levels.items,
            .graphs = self.level_graphs.items,
            .fresh = .{ .index = level_index, .grid = &fresh_grid, .graph = &fresh_graph },
        };
        try self.planPatchInfo(world);
        try self.reserveCellBlocks(levels, world, colliders);
        try self.reserveRecords(levels);
        stats.addMain(.reserve_ns, section.lap());

        // Commit into the fresh storage.
        self.remaskKeys(levels, colliders, world, null, stageThreads(threads, .remask), stats);
        section = StageTimer.begin();
        self.claimRecords(levels);
        stats.addMain(.commit_ns, section.lap());
        self.patchKeys(levels, world, stageThreads(threads, .patch), stats);
        // Connectivity: reserves first, so an error leaves every other level as it was.
        const old_levels = BatchLevels{ .grids = self.levels.items, .graphs = self.level_graphs.items };
        const replaced: ?*NavLevelGraph = if (appending) null else &self.level_graphs.items[level_index];
        const counters = try self.connectivity.buildLevel(
            self.allocator,
            levels,
            old_levels,
            world,
            self.changed_keys.items,
            replaced,
            stageThreads(threads, .conn_seed),
            stageThreads(threads, .conn_gather),
            stageThreads(threads, .conn_flood),
            closureThreads(threads),
            &self.pool_grows,
            stats,
        );
        addConnectivityStats(stats, &self.connectivity, counters);
        section = StageTimer.begin();
        _ = self.releaseRecords(levels);
        fresh_graph.built_revision = if (world) |world_system| world_system.levelContentRevision(level_index) else 0;
        if (appending) {
            self.levels.appendAssumeCapacity(fresh_grid);
            self.level_graphs.appendAssumeCapacity(fresh_graph);
            // Empty: links fold only at a world build and a marks commit.
            self.level_crossings.appendAssumeCapacity(.{});
        } else {
            std.debug.assert(self.level_graphs.items[level_index].plan.isClear());
            self.levels.items[level_index].deinit(self.allocator);
            self.level_graphs.items[level_index].deinit(self.allocator);
            self.levels.items[level_index] = fresh_grid;
            self.level_graphs.items[level_index] = fresh_graph;
        }
        stats.addMain(.commit_ns, section.lap());
        stats.levels_built += 1;
        self.logPoolGrowth();
    }

    // What a marks batch changing one chunk keeps in each batch list, per plan stream: the
    // static floor no list frees below.
    const one_chunk_keys: [plan_streams]usize = .{ 1, 1, 5 };

    /// Counts one fixed step of the batch staging's release windows (`length` steps, the
    /// configured `capacity_shrink_window`), on the main thread before the step's nav work.
    /// O(1). Follow with `finishStagingStep` once the step's nav work ends.
    pub fn tickStagingStep(self: *NavGraph, length: u32) void {
        self.staging_window.tick(length);
        self.connectivity.staging_window.tick(length);
    }

    /// Ends a step's nav work, after every batch and level build of the step: on a release
    /// window's last step, or a step that built levels, frees every batch staging list (the
    /// graph's and connectivity's) down to what it keeps (`types.StagingWindow.kept`: the
    /// window's batches and the floors, never a build's level-sized needs) when it holds more;
    /// a closing window starts the next. The only place staging frees, once however many
    /// levels the step built. Never fails, never inside a stage. O(1), or O(lists) plus the
    /// bytes freed once per window or build step.
    pub fn finishStagingStep(self: *NavGraph) void {
        if (self.staging_window.releases()) self.releaseLists();
        if (self.connectivity.staging_window.releases()) self.connectivity.releaseWindow(self.allocator, borderPortalBound(self.geometry.chunk_tiles));
    }

    fn beginBuild(self: *NavGraph) void {
        self.staging_window.beginBuild();
        self.connectivity.staging_window.beginBuild();
    }

    fn endBuild(self: *NavGraph) void {
        self.staging_window.endBuild();
        self.connectivity.staging_window.endBuild();
    }

    fn releaseLists(self: *NavGraph) void {
        const allocator = self.allocator;
        const window = &self.staging_window;
        for (std.meta.tags(PlanStream), one_chunk_keys, &self.plan_staging) |stream, floor, *staging| {
            const keep = window.kept(streamGroup(stream), floor);
            types.releaseStaging(self.keyList(stream), allocator, keep);
            types.releaseStaging(staging, allocator, keep);
        }
        const changed_keep = window.kept(.changed, one_chunk_keys[@backingInt(PlanStream.changed)]);
        types.releaseStaging(&self.changed_masks, allocator, changed_keep);
        types.releaseStaging(&self.remask_slots, allocator, changed_keep);
        types.releaseStaging(&self.remask_deltas, allocator, changed_keep);
        types.releaseStaging(&self.patch_info, allocator, window.kept(.patch, one_chunk_keys[@backingInt(PlanStream.patch)]));
        types.releaseStaging(&self.plan_windows, allocator, window.kept(.ranges, 1));
        types.releaseStaging(&self.plan_tallies, allocator, window.kept(.ranges, 1));
        window.released();
    }

    // Folds `links` into the link bounds and the level crossings; O(1) per link plus a
    // merged pair's exit span, allocation-free (links reference built levels).
    fn foldNewLinks(self: *NavGraph, links: []const LevelLink) void {
        std.debug.assert(self.level_crossings.items.len == self.levels.items.len);
        self.link_bounds.foldLinks(links);
        foldLevelCrossings(self.level_crossings.items, links);
    }

    // The links of `world` not yet folded into records.
    fn newLinks(self: *const NavGraph, world: *const WorldSystem) []const LevelLink {
        if (!self.world_backed) return &.{};
        const links = world.levelLinks();
        // Links are append-only.
        std.debug.assert(links.len >= self.links_applied);
        return links[self.links_applied..];
    }

    /// Prepares `marks` and every link added since the last batch as one transaction, the
    /// fallible half: plan (changed, dirty, and patch keys) and reserve (cell blocks, records,
    /// link slots). No cell, label, or record changes, so a failed or aborted prepare leaves
    /// the graph and `links_applied` as they were; reserved pool entries stay free capacity.
    /// Null when there is nothing to apply. Follow with exactly one `commitMarks` or
    /// `abortMarks`, with the same `colliders`. Each referenced level must be built.
    /// O(marked chunks log + their records + new link endpoints) on the main thread, the key
    /// plan threaded.
    pub fn prepareMarks(
        self: *NavGraph,
        world: *const WorldSystem,
        colliders: ColliderView,
        marks: []const NavMark,
        threads: ?NavUpdateThreads,
        stats: *NavUpdateStats,
    ) error{OutOfMemory}!?PreparedMarks {
        std.debug.assert(!self.batch_prepared);
        if (!self.valid()) return null;
        const new_links = self.newLinks(world);
        if (marks.len == 0 and new_links.len == 0) return null;
        const prepared = PreparedMarks{
            .marks = marks,
            .new_link_count = new_links.len,
            .world = if (self.world_backed) world else null,
        };
        // The batch notes its needs in the release window (`finishStagingStep`).
        self.staging_window.beginBatch();
        try self.planKeys(world, marks, new_links, stageThreads(threads, .plan), stats);
        var section = StageTimer.begin();
        try types.resizeStaging(&self.changed_masks, self.allocator, self.changed_keys.items.len, &self.pool_grows);
        if (self.patch_keys.items.len != 0) {
            const levels = BatchLevels{ .grids = self.levels.items, .graphs = self.level_graphs.items };
            try self.planPatchInfo(prepared.world);
            try self.reserveCellBlocks(levels, prepared.world, colliders);
            try self.reserveRecords(levels);
            stats.addMain(.reserve_ns, section.lap());
            try self.connectivity.prepareMarks(
                self.allocator,
                levels,
                prepared.world,
                self.changed_keys.items,
                self.patch_keys.items,
                self.patch_info.items,
                new_links,
                stageThreads(threads, .conn_seed),
                closureThreads(threads),
                &self.pool_grows,
                stats,
            );
            section = StageTimer.begin();
        }
        // The one-way registry rows the commit appends for the new links.
        try self.connectivity.reserveRegistry(self.allocator, new_links, &self.pool_grows);
        stats.addMain(.reserve_ns, section.lap());
        self.staging_window.endBatch(self.changed_keys.items.len <= 1);
        self.batch_prepared = true;
        return prepared;
    }

    /// Commits a prepared batch, the infallible half: folds the batch's new links into
    /// `link_bounds` and `level_crossings` (O(1) each, a long one a fixed pair insert, a
    /// level-crossing short one a fixed insert into its source level's crossings plus a merged
    /// exit range's windows, then one fixed pair chain closure when the batch changed the
    /// pairs or crossing rates), remasks the changed chunks from
    /// the world and `colliders` (recording each one's flipped cells), re-derives every
    /// patch key's record, updates the connectivity ids, and advances `links_applied`. Remask,
    /// patch, and the connectivity gather thread over keys; the connectivity flood over its
    /// searches.
    pub fn commitMarks(self: *NavGraph, prepared: PreparedMarks, colliders: ColliderView, threads: ?NavUpdateThreads, stats: *NavUpdateStats) NavBatchResult {
        std.debug.assert(self.batch_prepared);
        self.batch_prepared = false;
        // Only a world-backed graph has links to apply.
        std.debug.assert(prepared.new_link_count == 0 or prepared.world != null);
        var section = StageTimer.begin();
        const first_link = self.links_applied;
        const new_links: []const LevelLink = if (prepared.world) |world| world.levelLinks()[first_link..][0..prepared.new_link_count] else &.{};
        self.foldNewLinks(new_links);
        self.links_applied += prepared.new_link_count;
        self.connectivity.appendRegistry(new_links);
        stats.addMain(.commit_ns, section.lap());
        if (self.patch_keys.items.len == 0) return .{ .changed = false, .dirty_keys = &.{}, .changed_keys = &.{}, .changed_masks = &.{} };
        const levels = BatchLevels{ .grids = self.levels.items, .graphs = self.level_graphs.items };
        std.debug.assert(self.changed_masks.items.len == self.changed_keys.items.len);
        self.remaskKeys(levels, colliders, prepared.world, self.changed_masks.items, stageThreads(threads, .remask), stats);
        section = StageTimer.begin();
        self.claimRecords(levels);
        stats.addMain(.commit_ns, section.lap());
        self.patchKeys(levels, prepared.world, stageThreads(threads, .patch), stats);
        const counters = self.connectivity.commitMarks(self.allocator, levels, prepared.world, self.patch_keys.items, new_links, stageThreads(threads, .conn_gather), stageThreads(threads, .conn_flood), closureThreads(threads), stats);
        addConnectivityStats(stats, &self.connectivity, counters);
        section = StageTimer.begin();
        stats.records_patched += self.releaseRecords(levels);
        stats.addMain(.commit_ns, section.lap());
        stats.dirty_chunks += self.changed_keys.items.len;
        stats.chunks_patched += self.patch_keys.items.len;
        stats.incremental_rebuilds = 1;
        self.logPoolGrowth();
        return .{ .changed = true, .dirty_keys = self.dirty_keys.items, .changed_keys = self.changed_keys.items, .changed_masks = self.changed_masks.items };
    }

    /// Drops a prepared batch without changing the graph; its marks and links stay pending.
    pub fn abortMarks(self: *NavGraph, prepared: PreparedMarks) void {
        _ = prepared;
        std.debug.assert(self.batch_prepared);
        self.batch_prepared = false;
        self.changed_keys.clearRetainingCapacity();
        self.dirty_keys.clearRetainingCapacity();
        self.patch_keys.clearRetainingCapacity();
        self.changed_masks.clearRetainingCapacity();
    }

    /// Lands the one-way closure blocks the step's last relocating commit or level build left in
    /// the batch tail (`Connectivity.landResidents`, threaded per line), once at the end of a
    /// nav update, on its error path too, so the tail is empty after every update whose landing
    /// succeeds. Never fails: on `OutOfMemory` the blocks stay valid in the tail,
    /// `closure_land_deferrals` and `perf.land_deferrals` count it (the first logs once), and the
    /// next prepare retries the landing, failing as an ordinary `OutOfMemory` with the graph
    /// intact. Main work O(1) per block.
    pub fn landClosure(self: *NavGraph, threads: ?NavUpdateThreads, stats: *NavUpdateStats) void {
        self.connectivity.landResidents(self.allocator, stageThreads(threads, .conn_closure_land), stats) catch {
            if (comptime runtime_perf_log.enabled) {
                stats.perf.closure_land_deferrals += 1;
                self.perf.land_deferrals += 1;
            }
            if (self.land_deferral_logged) return;
            self.land_deferral_logged = true;
            if (comptime logging.enabled(.warn))
                logging.game.warn("nav closure landing deferred: out of memory; the next nav batch retries it", .{});
        };
    }

    fn logPoolGrowth(self: *NavGraph) void {
        if (self.pool_grows == 0 or self.pool_growth_logged) return;
        self.pool_growth_logged = true;
        if (comptime logging.enabled(.info))
            logging.game.info("nav storage grew ({} growths so far)", .{self.pool_grows});
    }

    // A mark's inclusive nav-cell span, or null when it misses every built level.
    fn markSpan(self: *const NavGraph, world: *const WorldSystem, mark: NavMark) ?NavSpan {
        if (@as(usize, mark.level) >= self.levels.items.len) return null;
        return switch (mark.kind) {
            .tile_box => self.levels.items[mark.level].cellSpanForTileBox(world, mark.min_x, mark.min_y, mark.max_x, mark.max_y),
            .static_span => .{ .min_x = mark.min_x, .min_y = mark.min_y, .max_x = mark.max_x, .max_y = mark.max_y },
        };
    }

    // Upper bounds of the keys item `item` (marks, then new links) writes per stream: a mark
    // its span's chunks as changed and patch keys plus the neighbours along the span's edge;
    // a link its two endpoint chunks as dirty and patch keys. O(1).
    fn itemKeyBounds(self: *const NavGraph, world: *const WorldSystem, marks: []const NavMark, item: usize) [plan_streams]usize {
        if (item < marks.len) {
            const span = self.markSpan(world, marks[item]) orelse return @splat(0);
            const shift = self.geometry.shift;
            const cols = (span.max_x >> shift) - (span.min_x >> shift) + 1;
            const rows = (span.max_y >> shift) - (span.min_y >> shift) + 1;
            return .{ cols * rows, 0, cols * rows + 2 * (cols + rows) };
        }
        return .{ 0, 2, 2 };
    }

    // Writes item `item`'s keys at each stream's cursor. Reads only the graph's geometry and
    // the world, so plan ranges run in parallel.
    fn writeItemKeys(self: *const NavGraph, world: *const WorldSystem, marks: []const NavMark, links: []const LevelLink, item: usize, staging: [plan_streams][]u64, ends: *[plan_streams]usize) void {
        const changed = @backingInt(PlanStream.changed);
        const dirty = @backingInt(PlanStream.dirty);
        const patch = @backingInt(PlanStream.patch);
        const cx_count = self.geometry.chunks_x;
        const cy_count = self.geometry.chunks_y;
        if (item < marks.len) {
            const mark = marks[item];
            const span = self.markSpan(world, mark) orelse return;
            const shift = self.geometry.shift;
            const x0 = span.min_x >> shift;
            const x1 = span.max_x >> shift;
            const y0 = span.min_y >> shift;
            const y1 = span.max_y >> shift;
            for (y0..y1 + 1) |cy| {
                for (x0..x1 + 1) |cx| {
                    const chunk: u32 = @intCast(cy * cx_count + cx);
                    for ([_]usize{ changed, patch }) |stream| {
                        staging[stream][ends[stream]] = chunkKey(mark.level, chunk);
                        ends[stream] += 1;
                    }
                    // A neighbour inside the span is a span chunk already.
                    const neighbours = [_]struct { present: bool, chunk: usize }{
                        .{ .present = cx == x0 and cx > 0, .chunk = chunk -% 1 },
                        .{ .present = cx == x1 and cx + 1 < cx_count, .chunk = chunk +% 1 },
                        .{ .present = cy == y0 and cy > 0, .chunk = chunk -% cx_count },
                        .{ .present = cy == y1 and cy + 1 < cy_count, .chunk = chunk +% cx_count },
                    };
                    for (neighbours) |neighbour| {
                        if (!neighbour.present) continue;
                        staging[patch][ends[patch]] = chunkKey(mark.level, @intCast(neighbour.chunk));
                        ends[patch] += 1;
                    }
                }
            }
            return;
        }
        const link = links[item - marks.len];
        inline for (.{ .{ link.level_a, link.cell_a }, .{ link.level_b, link.cell_b } }) |end| {
            if (@as(usize, end[0]) < self.levels.items.len) {
                const key = chunkKey(end[0], self.geometry.chunkOf(end[1].x, end[1].y));
                for ([_]usize{ dirty, patch }) |stream| {
                    staging[stream][ends[stream]] = key;
                    ends[stream] += 1;
                }
            }
        }
    }

    // Plans a marks batch: the changed, dirty, and patch keys (see `PlanStream`), each sorted
    // and deduped. Threaded over marks and new links: each range writes, sorts, and dedupes
    // its own key windows; the main thread sizes the windows (O(1) per item) and merges them
    // through the plan order set (`mergePlanWindows`). Inline it is one range: one sort and
    // no merge.
    fn planKeys(self: *NavGraph, world: *const WorldSystem, marks: []const NavMark, new_links: []const LevelLink, threads: ?Dispatch, stats: *NavUpdateStats) !void {
        const item_count = marks.len + new_links.len;
        for (std.meta.tags(PlanStream)) |stream| self.keyList(stream).clearRetainingCapacity();
        if (item_count == 0) return;
        var section = StageTimer.begin();
        const selection = stageShape(threads, item_count, 1);

        // Windows: each range's key bounds, starting on a cache line.
        self.staging_window.note(.ranges, selection.range_count);
        try types.resizeStaging(&self.plan_windows, self.allocator, selection.range_count, &self.pool_grows);
        try types.resizeStaging(&self.plan_tallies, self.allocator, selection.range_count, &self.pool_grows);
        var totals: [plan_streams]usize = @splat(0);
        for (self.plan_windows.items, 0..) |*window, range_index| {
            for (&totals) |*total| total.* = std.mem.alignForward(usize, total.*, key_window_alignment);
            window.* = .{ .start = totals };
            const start = range_index * selection.items_per_range;
            for (start..@min(start + selection.items_per_range, item_count)) |item| {
                const bounds = self.itemKeyBounds(world, marks, item);
                for (&totals, bounds) |*total, bound| total.* += bound;
            }
            window.end = totals;
        }
        var staging: [plan_streams][]u64 = undefined;
        for (std.meta.tags(PlanStream), &self.plan_staging, totals, &staging) |stream, *list, total, *slice| {
            self.staging_window.note(streamGroup(stream), total);
            try types.resizeStaging(list, self.allocator, total, &self.pool_grows);
            slice.* = list.items;
        }
        @memset(self.plan_tallies.items, .{});
        var job = PlanJob{
            .graph = self,
            .world = world,
            .marks = marks,
            .links = new_links,
            .items_per_range = selection.items_per_range,
            .windows = self.plan_windows.items,
            .staging = staging,
            .tallies = self.plan_tallies.items,
        };
        stats.addMain(.plan_ns, section.lap());
        const batch = runShaped(threads, selection, item_count, 1, &job, planJob);
        stats.addStageTime(batch);
        if (comptime runtime_perf_log.enabled) accumulateBatch(&stats.perf.plan_batch, batch);

        section = StageTimer.begin();
        defer stats.addMain(.plan_ns, section.lap());
        if (selection.range_count > 1) return self.mergePlanWindows();
        // One range: its windows start at 0 and hold the sorted unique keys.
        const counts = self.plan_tallies.items[0].counts;
        for ([_]PlanStream{ .changed, .patch }) |stream| {
            const out = self.keyList(stream);
            std.mem.swap(KeyList, out, &self.plan_staging[@backingInt(stream)]);
            out.items.len = counts[@backingInt(stream)];
        }
        const dirty = @backingInt(PlanStream.dirty);
        try self.mergeDirtyKeys(self.plan_staging[dirty].items[0..counts[dirty]]);
    }

    // The dirty keys of a one-range plan: the sorted union of the changed keys and the sorted
    // unique link keys. O(changed + link keys).
    // SIMD verdict: scalar. A sorted two-way merge with dedupe (data-dependent, irreducible).
    fn mergeDirtyKeys(self: *NavGraph, link_keys: []const u64) !void {
        const changed = self.changed_keys.items;
        self.staging_window.note(.dirty, changed.len + link_keys.len);
        try types.growList(&self.dirty_keys, self.allocator, changed.len + link_keys.len, &self.pool_grows);
        var changed_index: usize = 0;
        var link_index: usize = 0;
        while (changed_index < changed.len or link_index < link_keys.len) {
            const from_changed = link_index == link_keys.len or (changed_index < changed.len and changed[changed_index] <= link_keys[link_index]);
            const key = if (from_changed) changed[changed_index] else link_keys[link_index];
            if (from_changed) changed_index += 1 else link_index += 1;
            if (link_index < link_keys.len and link_keys[link_index] == key) link_index += 1;
            self.dirty_keys.appendAssumeCapacity(key);
        }
    }

    fn keyList(self: *NavGraph, stream: PlanStream) *KeyList {
        return switch (stream) {
            .changed => &self.changed_keys,
            .dirty => &self.dirty_keys,
            .patch => &self.patch_keys,
        };
    }

    // Merges the plan ranges' sorted unique windows into each stream's sorted unique key list:
    // each patch key queues its chunk in its level's ordered set (and the level in
    // `plan_levels`), each changed and link key flags its chunk; then ascending pops, level by
    // level, emit the patch keys and, by flag, the changed keys and the dirty ones (changed or
    // linked) among them (changed and link keys are patch keys of the same range by
    // construction). O(1) per window key, O(tiers) per unique key and per touched level, for
    // any partition. The output reserve is the last fallible call, so every set is empty
    // again at return.
    // SIMD verdict: scalar. Ordered-set inserts and pops and bit-flag tests per key on the
    // main thread, O(1) each.
    fn mergePlanWindows(self: *NavGraph) !void {
        std.debug.assert(self.plan_levels.isEmpty());
        std.debug.assert(self.level_graphs.items.len <= self.plan_levels.capacity());
        var totals: [plan_streams]usize = @splat(0);
        for (self.plan_tallies.items) |tally| {
            for (&totals, tally.counts) |*total, count| total.* += count;
        }
        // Dirty keys are the changed keys plus the link keys.
        totals[@backingInt(PlanStream.dirty)] += totals[@backingInt(PlanStream.changed)];
        for (std.meta.tags(PlanStream), totals) |stream, total| {
            self.staging_window.note(streamGroup(stream), total);
            try types.growList(self.keyList(stream), self.allocator, total, &self.pool_grows);
        }

        const level_graphs = self.level_graphs.items;
        for (self.plan_windows.items, self.plan_tallies.items) |window, tally| {
            // Patch keys first, so a level's first key this merge finds it clear.
            for (self.planWindowKeys(.patch, window, tally)) |key| {
                const sets = &level_graphs[keyLevel(key)].plan;
                if (sets.order.isEmpty()) {
                    std.debug.assert(sets.isClear());
                    self.plan_levels.insert(keyLevel(key));
                }
                sets.order.insert(keyChunk(key));
            }
            for (self.planWindowKeys(.dirty, window, tally)) |key| {
                const sets = &level_graphs[keyLevel(key)].plan;
                if (sets.dirty.isSet(keyChunk(key))) continue;
                sets.dirty.set(keyChunk(key));
                sets.dirty_count += 1;
            }
            for (self.planWindowKeys(.changed, window, tally)) |key| {
                const sets = &level_graphs[keyLevel(key)].plan;
                if (sets.changed.isSet(keyChunk(key))) continue;
                sets.changed.set(keyChunk(key));
                sets.changed_count += 1;
            }
        }
        while (self.plan_levels.popMin()) |level_index| {
            // Levels are below `levels.len`, so below 2^16 (`chunkKey`).
            const level: u16 = @intCast(level_index);
            const sets = &level_graphs[level_index].plan;
            const changed_start = self.changed_keys.items.len;
            var linked_popped: usize = 0;
            while (sets.order.popMin()) |chunk_index| {
                // Chunks are below the level's chunk count, a u32 (`validateChunkGrid`).
                const chunk: u32 = @intCast(chunk_index);
                const key = chunkKey(level, chunk);
                self.patch_keys.appendAssumeCapacity(key);
                const changed = sets.changed.isSet(chunk);
                const linked = sets.dirty.isSet(chunk);
                if (!changed and !linked) continue;
                self.dirty_keys.appendAssumeCapacity(key);
                if (linked) {
                    sets.dirty.unset(chunk);
                    linked_popped += 1;
                }
                if (!changed) continue;
                sets.changed.unset(chunk);
                self.changed_keys.appendAssumeCapacity(key);
            }
            // Every flag was popped with its patch chunk, so the level's flag sets are empty.
            std.debug.assert(self.changed_keys.items.len - changed_start == sets.changed_count);
            std.debug.assert(linked_popped == sets.dirty_count);
            sets.changed_count = 0;
            sets.dirty_count = 0;
        }
    }

    // One plan range's sorted unique keys of `stream`.
    fn planWindowKeys(self: *const NavGraph, stream: PlanStream, window: PlanWindow, tally: PlanTally) []const u64 {
        const index = @backingInt(stream);
        return self.plan_staging[index].items[window.start[index]..][0..tally.counts[index]];
    }

    // Per patch key: its link endpoints on the level (an O(1) count) and whether it may hold
    // portals. A chunk whose world form is BLOCKED holds none
    // (statics only add blocked cells), and one whose orthogonal neighbours are all BLOCKED
    // has no border run, so it needs a record only for an endpoint. O(keys + endpoints).
    fn planPatchInfo(self: *NavGraph, world: ?*const WorldSystem) !void {
        const patch_count = self.patch_keys.items.len;
        try types.resizeStaging(&self.patch_info, self.allocator, patch_count, &self.pool_grows);
        const cx_count = self.geometry.chunks_x;
        const cy_count = self.geometry.chunks_y;
        for (self.patch_keys.items, self.patch_info.items) |key, *info| {
            const level = keyLevel(key);
            const chunk = keyChunk(key);
            const world_system = world orelse {
                info.* = .{ .endpoints = 0, .needs_record = true };
                continue;
            };
            if (@as(usize, level) >= world_system.levelCount()) {
                info.* = .{ .endpoints = 0, .needs_record = true };
                continue;
            }
            const endpoints = world_system.levelChunkLinkEndpointCount(level, chunk);
            const blocked = struct {
                fn at(ws: *const WorldSystem, lvl: u16, index: usize) bool {
                    return ws.levelChunkBlockedForm(lvl, @intCast(index)) == .blocked;
                }
            }.at;
            var needs = false;
            if (!blocked(world_system, level, chunk)) {
                const cx = chunk % cx_count;
                const cy = chunk / cx_count;
                needs = endpoints != 0 or
                    (cx > 0 and !blocked(world_system, level, chunk - 1)) or
                    (cx + 1 < cx_count and !blocked(world_system, level, chunk + 1)) or
                    (cy > 0 and !blocked(world_system, level, chunk - cx_count)) or
                    (cy + 1 < cy_count and !blocked(world_system, level, chunk + cx_count));
            }
            info.* = .{ .endpoints = endpoints, .needs_record = needs };
        }
    }

    // Grows each level's record and link-slot pools so the claims of `claimRecords` pop
    // without allocating, and sizes every claimed link slot's lists to its key's endpoint
    // count. Claims pop the free lists in key order, so the slot each key will claim is
    // known here. No graph content changes: new pool entries are free. O(keys).
    fn reserveRecords(self: *NavGraph, levels: BatchLevels) !void {
        const keys = self.patch_keys.items;
        var runs = LevelRuns{ .keys = keys };
        while (runs.next()) |run| {
            const start = run.start;
            const end = run.end;
            const level_graph = levels.graph(run.level);
            var new_records: usize = 0;
            var new_slots: usize = 0;
            for (keys[start..end], self.patch_info.items[start..end]) |key, info| {
                const record = level_graph.record_dir.items[keyChunk(key)];
                if (record == no_record and !info.needs_record) continue;
                if (record == no_record) new_records += 1;
                if (info.endpoints != 0 and (record == no_record or level_graph.record_link_slot[record] == no_link_slot)) new_slots += 1;
            }
            try level_graph.ensureFreeRecords(self.allocator, new_records, &self.pool_grows);
            try level_graph.ensureFreeLinkSlots(self.allocator, new_slots, &self.pool_grows);
            var slot_claims: usize = 0;
            for (keys[start..end], self.patch_info.items[start..end]) |key, info| {
                if (info.endpoints == 0) continue;
                const record = level_graph.record_dir.items[keyChunk(key)];
                if (record == no_record and !info.needs_record) continue;
                const slot = if (record != no_record and level_graph.record_link_slot[record] != no_link_slot)
                    level_graph.record_link_slot[record]
                else blk: {
                    slot_claims += 1;
                    break :blk level_graph.link_free.items[level_graph.link_free.items.len - slot_claims];
                };
                // Geometric: a chunk's endpoint count only grows (links are append-only). The
                // patch bounds its appends by the planned count, not the capacity.
                try types.growList(&level_graph.slot_extra[slot], self.allocator, info.endpoints, &self.pool_grows);
                try types.growList(&level_graph.slot_links[slot], self.allocator, info.endpoints, &self.pool_grows);
            }
        }
    }

    // Per changed key, the block slot its remask may fill: the one its chunk holds, a claim
    // when the chunk may end mixed (`chunkMayMix`), or none. Grows each level's block pool
    // to cover the claims (worst case: every such key ends mixed). O(keys).
    fn reserveCellBlocks(self: *NavGraph, levels: BatchLevels, world: ?*const WorldSystem, colliders: ColliderView) !void {
        const keys = self.changed_keys.items;
        try types.resizeStaging(&self.remask_slots, self.allocator, keys.len, &self.pool_grows);
        try types.resizeStaging(&self.remask_deltas, self.allocator, keys.len, &self.pool_grows);
        var runs = LevelRuns{ .keys = keys };
        while (runs.next()) |run| {
            const level_grid = levels.grid(run.level);
            var claims: usize = 0;
            for (keys[run.start..run.end], self.remask_slots.items[run.start..run.end]) |key, *slot| {
                const chunk = keyChunk(key);
                if (level_grid.chunkBlock(chunk)) |held| {
                    slot.* = held;
                } else if (chunkMayMix(level_grid, world, colliders, chunk)) {
                    slot.* = claim_pending;
                    claims += 1;
                } else {
                    slot.* = no_block;
                }
            }
            try level_grid.ensureFreeBlocks(self.allocator, claims, &self.pool_grows);
        }
    }

    // Claims the planned block slots in key order and seeds each key's delta with its
    // chunk's old blocked count; then remasks every changed key (threaded over keys) and,
    // in key order, releases the slots whose chunk ended uniform and applies the deltas.
    fn remaskKeys(self: *NavGraph, levels: BatchLevels, colliders: ColliderView, world: ?*const WorldSystem, masks: ?[]ChunkBits, threads: ?Dispatch, stats: *NavUpdateStats) void {
        const keys = self.changed_keys.items;
        std.debug.assert(self.remask_deltas.items.len == keys.len and self.remask_slots.items.len == keys.len);
        var section = StageTimer.begin();
        for (keys, self.remask_slots.items, self.remask_deltas.items) |key, *slot, *delta| {
            const level_grid = levels.grid(keyLevel(key));
            // A chunk holds at most max_chunk_size_tiles^2 cells.
            delta.* = -@as(i32, @intCast(level_grid.chunkBlockedCount(keyChunk(key))));
            if (slot.* == claim_pending) slot.* = level_grid.claimBlock();
        }
        var job = RemaskJob{
            .levels = levels,
            .colliders = colliders,
            .world = world,
            .keys = keys,
            .slots = self.remask_slots.items,
            .deltas = self.remask_deltas.items,
            .masks = masks,
        };
        stats.addMain(.commit_ns, section.lap());
        const batch = runStage(threads, keys.len, 1, &job, &job.range_count, remaskJob);
        stats.addStageTime(batch);
        accumulateBatch(&stats.remask_batch, batch);
        section = StageTimer.begin();
        for (keys, self.remask_slots.items, self.remask_deltas.items) |key, slot, delta| {
            const level_grid = levels.grid(keyLevel(key));
            if (slot != no_block and level_grid.chunkBlock(keyChunk(key)) != slot) level_grid.releaseBlock(slot);
            const count: isize = @as(isize, @intCast(level_grid.blocked_count)) + delta;
            std.debug.assert(count >= 0);
            level_grid.blocked_count = @intCast(@max(count, 0));
        }
        stats.addMain(.commit_ns, section.lap());
    }

    // Claims a record for every patch key that may hold portals and has none, and a link
    // slot for every record whose key has endpoints, in key order.
    fn claimRecords(self: *NavGraph, levels: BatchLevels) void {
        for (self.patch_keys.items, self.patch_info.items) |key, info| {
            const level_graph = levels.graph(keyLevel(key));
            const chunk = keyChunk(key);
            var record = level_graph.record_dir.items[chunk];
            if (record == no_record) {
                if (!info.needs_record) continue;
                record = level_graph.claimRecord(chunk);
            }
            if (info.endpoints != 0 and level_graph.record_link_slot[record] == no_link_slot) level_graph.claimLinkSlot(record);
        }
    }

    fn patchKeys(self: *NavGraph, levels: BatchLevels, world: ?*const WorldSystem, threads: ?Dispatch, stats: *NavUpdateStats) void {
        var job = PatchJob{ .graph = self, .levels = levels, .world = world, .keys = self.patch_keys.items, .infos = self.patch_info.items };
        const batch = runStage(threads, self.patch_keys.items.len, 1, &job, &job.range_count, patchJob);
        stats.addStageTime(batch);
        if (comptime runtime_perf_log.enabled) accumulateBatch(&stats.perf.patch_batch, batch);
    }

    // Releases the records the patch left without portals and the link slots left empty, in
    // key order; returns the records kept.
    fn releaseRecords(self: *NavGraph, levels: BatchLevels) usize {
        var kept: usize = 0;
        for (self.patch_keys.items) |key| {
            const level_graph = levels.graph(keyLevel(key));
            const chunk = keyChunk(key);
            const record = level_graph.record_dir.items[chunk];
            if (record == no_record) continue;
            const portals = level_graph.chunkPortals(chunk);
            if (portals.portalCount() == 0) {
                level_graph.releaseRecord(chunk);
                continue;
            }
            kept += 1;
            if (portals.extra.len == 0 and portals.links.len == 0) level_graph.releaseLinkSlot(record);
        }
        return kept;
    }

    // Re-derives one chunk's record from its level's cells, its four neighbours' border
    // cells, and the world's endpoint list for (level, chunk). Writes only that record and
    // its link slot, so keys patch in parallel. Border portals follow one rule per side: one
    // portal per maximal run of open cell pairs across the side, at the run's midpoint
    // (floor-biased), so both chunks sharing a side pick the same pair independently.
    fn patchRecord(self: *const NavGraph, level_grid: *const NavGrid, level_graph: *NavLevelGraph, world: ?*const WorldSystem, level: u16, chunk: u32, endpoint_limit: u32) void {
        const record = level_graph.record_dir.items[chunk];
        if (record == no_record) return;
        const bounds = level_grid.chunkBounds(chunk);
        const w = self.geometry.width;
        const cols = bounds.x1 - bounds.x0;
        const rows = bounds.y1 - bounds.y0;
        const shift: u4 = level_grid.geometry.shift;
        const chunks_x = self.geometry.chunks_x;
        var portals: [max_border_portals]NavPortal = undefined;
        var count: usize = 0;
        const Side = NavGrid.ChunkSide;
        const sides = [_]struct { present: bool, side: Side, mirror: Side, neighbour: u32, length: usize, flags: PortalFlags }{
            .{ .present = bounds.x0 > 0, .side = .west, .mirror = .east, .neighbour = chunk -% 1, .length = rows, .flags = .{ .west = true } },
            .{ .present = bounds.x1 < w, .side = .east, .mirror = .west, .neighbour = chunk +% 1, .length = rows, .flags = .{ .east = true } },
            .{ .present = bounds.y0 > 0, .side = .north, .mirror = .south, .neighbour = chunk -% chunks_x, .length = cols, .flags = .{ .north = true } },
            .{ .present = bounds.y1 < self.geometry.height, .side = .south, .mirror = .north, .neighbour = chunk +% chunks_x, .length = cols, .flags = .{ .south = true } },
        };
        for (sides) |side| {
            if (!side.present) continue;
            // A pair is open when this side's cell and its mirror across the border are both
            // open; the neighbour shares this chunk's rows (west/east) or columns.
            const blocked: u32 = level_grid.sideBits(chunk, side.side) | level_grid.sideBits(side.neighbour, side.mirror);
            const open = ~blocked & ((@as(u32, 1) << @intCast(side.length)) - 1);
            var run_start: ?usize = null;
            for (0..side.length + 1) |index| {
                if (index < side.length and (open >> @intCast(index)) & 1 != 0) {
                    if (run_start == null) run_start = index;
                    continue;
                }
                const start = run_start orelse continue;
                run_start = null;
                const mid = start + (index - start) / 2;
                const local: u8 = @intCast(switch (side.side) {
                    .west => mid << shift,
                    .east => (mid << shift) | (cols - 1),
                    .north => mid,
                    .south => ((rows - 1) << shift) | mid,
                });
                if (findLocalLinear(portals[0..count], local)) |existing| {
                    portals[existing].flags = mergeFlags(portals[existing].flags, side.flags);
                } else {
                    std.debug.assert(count < level_graph.border_stride);
                    portals[count] = .{ .local = local, .label = level_grid.labelAtLocal(chunk, local), .flags = side.flags };
                    count += 1;
                }
            }
        }
        insertionSort(NavPortal, portals[0..count], {}, portalLessThan);

        const slot = level_graph.record_link_slot[record];
        if (slot != no_link_slot) {
            const extra = &level_graph.slot_extra[slot];
            const links = &level_graph.slot_links[slot];
            extra.clearRetainingCapacity();
            links.clearRetainingCapacity();
            if (world) |world_system| {
                // Locals already in `extra`: an O(1) dedupe per endpoint, so a chunk holding E
                // endpoints patches in O(E log E) (the sorts below), not O(E²).
                var extra_locals: LabelSet = .empty;
                var endpoints = world_system.levelChunkLinkEndpoints(level, chunk);
                while (endpoints.next()) |endpoint| {
                    if (level_grid.isBlockedXY(endpoint.cell.x, endpoint.cell.y)) continue;
                    const local = self.geometry.localOf(endpoint.cell.x, endpoint.cell.y);
                    if (std.sort.binarySearch(NavPortal, portals[0..count], local, orderPortalLocal)) |existing| {
                        portals[existing].flags.link = true;
                    } else if (!extra_locals.isSet(local)) {
                        extra_locals.set(local);
                        // The reserve sized the slot's lists to the planned endpoint count.
                        std.debug.assert(extra.items.len < endpoint_limit);
                        extra.appendAssumeCapacity(.{ .local = local, .label = level_grid.labelAtLocal(chunk, local), .flags = .{ .link = true } });
                    }
                    if (endpoint.side == .a or endpoint.bidirectional) {
                        std.debug.assert(links.items.len < endpoint_limit);
                        links.appendAssumeCapacity(.{
                            .local = local,
                            .to_level = endpoint.other_level,
                            .to_cell = @intCast(@as(usize, endpoint.other_cell.y) * w + endpoint.other_cell.x),
                            .cost = endpoint.traversal_cost +| inter_level_penalty,
                            .link = endpoint.link,
                        });
                    }
                }
            }
            pdqSort(NavPortal, extra.items, {}, portalLessThan);
            pdqSort(NavLink, links.items, {}, linkLessThan);
        }
        const base = @as(usize, record) * level_graph.border_stride;
        @memcpy(level_graph.border.items[base .. base + count], portals[0..count]);
        // At most max_border_portals (32) border portals.
        level_graph.border_count[record] = @intCast(count);
        var labels: LabelSet = .empty;
        for (portals[0..count]) |portal| labels.set(portal.label);
        if (slot != no_link_slot) {
            for (level_graph.slot_extra[slot].items) |portal| labels.set(portal.label);
        }
        // At most 128 labels fit a chunk.
        level_graph.record_label_count[record] = @intCast(labels.count());
    }

    pub fn keyForWorld(self: *const NavGraph, level: u16, goal: math.Vec2, agent_class: PathAgentClass) ?PathQueryKey {
        const level_grid = self.grid(level) orelse return null;
        if (!level_grid.valid()) return null;
        return .{
            .nav_version = self.version,
            .agent_class = agent_class,
            .goal_level = level,
            .goal = level_grid.worldToCellClamped(goal),
        };
    }
};

/// A set of a chunk's labels or chunk-local cells (both u8).
pub const LabelSet = std.bit_set.Array(u64, 256);

fn findLocalLinear(portals: []const NavPortal, local: u8) ?usize {
    for (portals, 0..) |portal, index| {
        if (portal.local == local) return index;
    }
    return null;
}

fn mergeFlags(a: PortalFlags, b: PortalFlags) PortalFlags {
    return @bitCast(@as(u8, @bitCast(a)) | @as(u8, @bitCast(b)));
}

// Whether `chunk` of `level_grid` may compose mixed: a world-BLOCKED chunk stays BLOCKED
// (colliders only add blocked cells), a world-OPEN one only mixes with a collider listed
// there, and a mixed one may stay mixed. O(1) expected.
fn chunkMayMix(level_grid: *const NavGrid, world: ?*const WorldSystem, colliders: ColliderView, chunk: u32) bool {
    if (world) |world_system| {
        if (@as(usize, level_grid.level) >= world_system.levelCount()) return false;
        switch (world_system.levelChunkBlockedForm(level_grid.level, chunk)) {
            .blocked => return false,
            .mixed => return true,
            .open => {},
        }
    }
    return colliders.chunkHasRows(level_grid.level, chunk);
}
// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const PathfindingSystem = @import("system.zig").PathfindingSystem;
const DataSystem = @import("../../data_system.zig").DataSystem;
const StaticColliderSystem = @import("../static_colliders.zig").StaticColliderSystem;
const no_colliders = &test_support.no_colliders;
const EntityId = @import("../../data_system.zig").EntityId;
const SimulationFrame = @import("../../simulation.zig").SimulationFrame;
const test_support = @import("test_support.zig");
const updatePathfindingInline = @import("test_support.zig").updatePathfindingInline;
const abstractCapacity = test_support.abstractCapacity;
const addNavBody = test_support.addNavBody;
const loadTestWorldMeta = test_support.loadTestWorldMeta;
const requireTestTile = test_support.requireTestTile;
const PathStatus = types.PathStatus;
const appendPathRequest = test_support.appendPathRequest;
const expectLinkPair = test_support.expectLinkPair;
const RangeOutputStream = @import("../../simulation.zig").RangeOutputStream;
const StructuralCommand = @import("../../data_system.zig").StructuralCommand;
const EntityTemplate = @import("../../data_system.zig").EntityTemplate;
const PathRequest = @import("../../simulation.zig").PathRequest;
const TileId = @import("../../world/system.zig").TileId;
const DenseCellWrite = @import("../../world/edit.zig").DenseCellWrite;
const DenseChunkWrites = @import("../../world/edit.zig").DenseChunkWrites;
const WorldTileChangedEvent = @import("../../simulation.zig").WorldTileChangedEvent;
const SimulationEvent = @import("../../simulation.zig").SimulationEvent;

// Asserts graph `a` equals graph `b` level by level: every chunk's form, cell bits, and
// labels, the blocked count, every chunk's record content (border portals, extra portals,
// links), the connectivity partition, each graph's connectivity consistent with its own
// records, and the one-way closure's reach between terminals.
fn expectGraphsEquivalent(a: *const NavGraph, b: *const NavGraph) !void {
    const t = std.testing;
    try t.expectEqual(a.levels.items.len, b.levels.items.len);
    try t.expectEqual(a.cellCount(), b.cellCount());
    for (0..a.levels.items.len) |level| try t.expect(levelsEquivalent(a, b, @intCast(level)));
    try t.expect(std.meta.eql(a.link_bounds, b.link_bounds));
    try t.expectEqual(a.level_crossings.items.len, b.level_crossings.items.len);
    for (a.level_crossings.items, b.level_crossings.items) |crossings_a, crossings_b| try t.expect(std.meta.eql(crossings_a, crossings_b));
    try test_support.expectConnectivityConsistent(a);
    try test_support.expectConnectivityConsistent(b);
    try test_support.expectSameConnectivityPartition(a, b);
    try test_support.expectSameClosure(a, b);
}

// Whether `level` holds the same cells and records in `a` and `b`.
fn levelsEquivalent(a: *const NavGraph, b: *const NavGraph, level: u16) bool {
    const ga = a.grid(level) orelse return b.grid(level) == null;
    const gb = b.grid(level) orelse return false;
    if (ga.blocked_count != gb.blocked_count) return false;
    if (ga.dir.items.len != gb.dir.items.len) return false;
    for (0..ga.dir.items.len) |chunk_index| {
        const chunk: u32 = @intCast(chunk_index);
        if (test_support.navChunkForm(ga, chunk) != test_support.navChunkForm(gb, chunk)) return false;
        const slot_a = ga.chunkBlock(chunk) orelse continue;
        const slot_b = gb.chunkBlock(chunk).?;
        if (!std.mem.eql(u64, &ga.block_bits[slot_a], &gb.block_bits[slot_b])) return false;
        if (!std.mem.eql(u8, &ga.block_labels[slot_a], &gb.block_labels[slot_b])) return false;
        if (ga.block_counts[slot_a] != gb.block_counts[slot_b]) return false;
    }
    for (0..a.chunkCount()) |chunk| {
        const pa = a.chunkPortals(level, @intCast(chunk));
        const pb = b.chunkPortals(level, @intCast(chunk));
        if (!portalsEqual(pa.border, pb.border) or !portalsEqual(pa.extra, pb.extra)) return false;
        if (pa.links.len != pb.links.len) return false;
        for (pa.links, pb.links) |la, lb| {
            if (!std.meta.eql(la, lb)) return false;
        }
    }
    return true;
}

fn portalsEqual(a: []const NavPortal, b: []const NavPortal) bool {
    if (a.len != b.len) return false;
    for (a, b) |pa, pb| {
        if (pa.local != pb.local or pa.label != pb.label or @as(u8, @bitCast(pa.flags)) != @as(u8, @bitCast(pb.flags))) return false;
    }
    return true;
}

// Whether `cell` on `level` is a portal of its chunk's record.
fn isPortal(graph: *const NavGraph, level: u16, cell: usize) bool {
    return graph.chunkPortals(level, graph.geometry.chunkOfCell(cell)).find(test_support.localOfCell(graph.geometry, cell)) != null;
}

// Links leaving a portal whose target cell is open (directed).
fn countLiveLinks(graph: *const NavGraph) usize {
    var count: usize = 0;
    for (0..graph.levelCount()) |level| {
        for (0..graph.chunkCount()) |chunk| {
            for (graph.chunkPortals(@intCast(level), @intCast(chunk)).links) |link| {
                const target = graph.grid(link.to_level) orelse continue;
                if (!target.isBlockedIndex(link.to_cell)) count += 1;
            }
        }
    }
    return count;
}

// A full rebuild of `world` with `capacity`, for equivalence checks.
fn fullRebuild(data: *const DataSystem, world: *const WorldSystem, capacity: types.PathfindingCapacity) !PathfindingSystem {
    var system = PathfindingSystem.init(std.testing.allocator);
    errdefer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(data, world, null);
    return system;
}

const static_colliders_test_support = @import("../static_colliders_test_support.zig");

test "incremental nav update remask matches the composed world mask across levels" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const asset_store = @import("../../../assets/assets.zig").AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try @import("../../../assets/world_tileset_meta.zig").load(
        std.testing.allocator,
        asset_store,
        @import("../../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();

    var world = try test_support.abstractTestWorld(&meta, 256, 256);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    // Small 4-tile chunks (abstractCapacity) so the 8x8 nav grid spans 2x2 chunks per
    // level and the edits straddle chunk boundaries — exercising chunk-local relabel.
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

    // Each edit flips a tile's blocking state: carve an underground tunnel cell,
    // punch an underground drop-hole, and block a surface cell.
    const cave_0 = (meta.tileByName("cave_0") orelse return error.TestExpectedEqual).id;
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;
    const floor1 = world.denseFloorLayerForLevel(1).?;
    _ = try world.setDenseTile(floor1, 3, 3, cave_0); // solid dirt -> walkable tunnel
    _ = try world.clearDenseTile(floor1, 4, 3); // solid dirt -> see-through hole
    const floor0 = world.denseFloorLayerForLevel(0).?;
    _ = try world.setDenseTile(floor0, 2, 2, tree); // surface walkable -> blocked

    const edits = [_]test_support.TileEdit{
        .{ .level = 1, .x = 3, .y = 3 },
        .{ .level = 1, .x = 4, .y = 3 },
        .{ .level = 0, .x = 2, .y = 2 },
    };
    _ = try test_support.applyTileEdits(&system, no_colliders, &world, &edits);

    // The incremental remask must equal the authoritative composed mask on every
    // level and cell, with a consistent blocked_count — i.e. identical to a full
    // recompose, but touching only the dirty footprint.
    for (0..world.levelCount()) |level_usize| {
        const level: u16 = @intCast(level_usize);
        const grid = system.graph.grid(level).?;
        var expected_blocked: usize = 0;
        for (0..world.height) |y_usize| {
            const y: u16 = @intCast(y_usize);
            for (0..world.width) |x_usize| {
                const x: u16 = @intCast(x_usize);
                const expect = world.levelBlocksMovement(level, x, y);
                if (expect) expected_blocked += 1;
                try std.testing.expectEqual(expect, grid.isBlockedCell(.{ .x = @intCast(x), .y = @intCast(y) }));
            }
        }
        try std.testing.expectEqual(expected_blocked, grid.blocked_count);
    }

    // The incremental graph must equal a full rebuild against the same post-edit
    // world/data: same masks, labels, and records.
    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, null);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "threaded initial nav build matches a serial build across levels" {
    // A build given a thread system dispatches its remask and patch stages through it;
    // pinned to a fixed one-chunk partition here so the stages really fan out.
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();

    var world = try test_support.abstractTestWorld(&meta, 256, 256);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);
    try std.testing.expect(world.levelCount() > 1);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();

    var cap = abstractCapacity();
    cap.worker_participant_count = threads.participantSlotCount();

    var threaded = PathfindingSystem.init(std.testing.allocator);
    defer threaded.deinit();
    try threaded.reserve(cap);
    threaded.nav_controls = .{ .adaptive = false, .items_per_range = 1 };
    const build_stats = try threaded.graph.rebuild(no_colliders.view(), .{ .world = &world }, .{ .thread_system = &threads, .tuners = &threaded.tuners.nav, .controls = threaded.nav_controls });
    try std.testing.expect(!build_stats.remask_batch.ran_inline);

    var serial = PathfindingSystem.init(std.testing.allocator);
    defer serial.deinit();
    try serial.reserve(cap);
    try serial.rebuildStaticNavGridWithWorld(&data, &world, null);

    try expectGraphsEquivalent(&threaded.graph, &serial.graph);
}

test "incremental nav update splitting a chunk-local component matches a full rebuild" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    // 12x12 open world, 4-tile chunks. Chunk (1,1) spans cells x4..7, y4..7 and starts
    // as one open local component.
    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

    const grid = system.graph.grid(0).?;
    const left = grid.indexForCell(.{ .x = 4, .y = 5 }).?;
    const right = grid.indexForCell(.{ .x = 6, .y = 5 }).?;
    // Before: both cells share chunk (1,1)'s single open local component.
    try std.testing.expect(grid.connected(left, right));

    // Drop a full-height wall at x=5 inside chunk (1,1), bisecting its open region.
    const wall_layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    var edits = std.ArrayList(test_support.TileEdit).empty;
    defer edits.deinit(std.testing.allocator);
    var wy: u16 = 4;
    while (wy <= 7) : (wy += 1) {
        const changed = (try world.setDenseTile(wall_layer, 5, wy, tree)) orelse return error.TestExpectedEqual;
        try edits.append(std.testing.allocator, .{ .level = changed.level, .x = changed.x, .y = changed.y });
    }
    _ = try test_support.applyTileEdits(&system, no_colliders, &world, edits.items);

    // After: the chunk-local component split into two distinct labels.
    try std.testing.expect(grid.labelAt(left) != 0 and grid.labelAt(right) != 0);
    try std.testing.expect(!grid.connected(left, right));

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, null);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "incremental nav update on a chunk border flips a neighbor chunk's portal" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    // 12x12 world, 4-tile chunks. The vertical border at x=4 spans y=4..7 for chunk row 1;
    // (3,4)/(3,6)/(3,7) start blocked so (3,5)|(4,5) is the border's ONLY open cell pair —
    // an isolated 1-cell run, so it is unambiguously the run's own representative portal
    // under the border-run rule (see NavGraph.patchRecord),
    // rather than depending on which cell a multi-cell run's midpoint happens to land on.
    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    const isolation_layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    for ([_]u16{ 4, 6, 7 }) |wy| {
        _ = try world.setDenseTile(isolation_layer, 3, wy, tree);
    }

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

    const grid = system.graph.grid(0).?;
    const near = grid.indexForCell(.{ .x = 3, .y = 5 }).?; // chunk (0,1), the edited side
    const neighbor = grid.indexForCell(.{ .x = 4, .y = 5 }).?; // chunk (1,1)
    try std.testing.expect(isPortal(&system.graph, 0, near));
    try std.testing.expect(isPortal(&system.graph, 0, neighbor));
    const neighbor_label_before = grid.chunkLabelAt(neighbor);

    // Block (3,5) on the chunk (0,1) side: the (3,5)|(4,5) portal pair disappears, so
    // the NEIGHBOR chunk (1,1)'s portal at (4,5) flips off even though only chunk (0,1)
    // is relabeled.
    const changed = (try world.setDenseTile(isolation_layer, 3, 5, tree)) orelse return error.TestExpectedEqual;
    _ = try test_support.applyTileChange(&system, no_colliders, &world, changed);

    try std.testing.expect(!isPortal(&system.graph, 0, near));
    try std.testing.expect(!isPortal(&system.graph, 0, neighbor));
    // The neighbor chunk's component labels were NOT recomputed: (4,5) keeps its label.
    try std.testing.expectEqual(neighbor_label_before, grid.chunkLabelAt(neighbor));

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, null);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

// The border-run rule: an open chunk border yields one portal per contiguous open run, so a
// fully-interior chunk with all four borders open has at most one portal per side (4), never
// one per open boundary cell (up to chunk_tiles per side).
test "a fully-open interior chunk yields at most one portal per border side, not one per open cell" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    // 12x12 open world, 4-tile chunks: a 3x3 chunk grid whose CENTER chunk (1,1) is the
    // only one with all four sides internal (bordering another chunk on every side).
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGrid(&data, 384, 384, 32);

    const chunk_tiles = system.capacity.nav_chunk_tiles;
    const chunks_per_side = 3;
    const center_chunk: u32 = 1 * chunks_per_side + 1;
    const live_count = system.graph.chunkPortals(0, center_chunk).portalCount();
    // One border portal per side (4), well under one per open boundary cell per side.
    try std.testing.expect(live_count <= 4);
    try std.testing.expect(live_count < @as(usize, chunk_tiles) * 4);
}
test "incremental nav update opening a ramp endpoint makes its two-way link live both ways" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    const level1_obstacle = try world.addDenseLayer(1, 0, .obstacle, grass);
    _ = try world.setDenseTile(level1_obstacle, 2, 2, tree); // ramp endpoint starts blocked
    try world.addLevelLink(.{
        .kind = .stair,
        .level_a = 0,
        .cell_a = .{ .x = 10, .y = 10 },
        .level_b = 1,
        .cell_b = .{ .x = 2, .y = 2 },
        .traversal_cost = 5,
        .bidirectional = true,
    });

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    // Endpoint blocked => no live link either way.
    try std.testing.expectEqual(@as(usize, 0), countLiveLinks(&system.graph));

    // Dig the ramp endpoint open: the endpoint's record gains its links.
    const changed = (try world.setDenseTile(level1_obstacle, 2, 2, grass)) orelse return error.TestExpectedEqual;
    try std.testing.expect(changed.old_blocks_movement and !changed.new_blocks_movement);
    _ = try test_support.applyTileChange(&system, no_colliders, &world, changed);
    // The bidirectional link is live both ways.
    try std.testing.expectEqual(@as(usize, 2), countLiveLinks(&system.graph));

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, null);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "incremental underground dig leaves the surface level's records byte-identical" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    // Open 12x12 surface (level 0) spanning many 4-tile chunks, plus an underground
    // level 1 with a diggable obstacle. An underground dig must do ZERO work on the surface.
    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    const level1_obstacle = try world.addDenseLayer(1, 0, .obstacle, grass);
    _ = try world.setDenseTile(level1_obstacle, 5, 5, tree);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

    // Snapshot level 0's records.
    var surface_before = try fullRebuild(&data, &world, abstractCapacity());
    defer surface_before.deinit();
    try std.testing.expect(test_support.levelLivePortalCount(&system.graph, 0) > 0);
    const record_dir_before = try std.testing.allocator.dupe(u32, system.graph.levelGraph(0).?.record_dir.items);
    defer std.testing.allocator.free(record_dir_before);

    // Dig an UNDERGROUND-only cell open (level 1).
    const changed = (try world.setDenseTile(level1_obstacle, 5, 5, grass)) orelse return error.TestExpectedEqual;
    try std.testing.expect(changed.old_blocks_movement and !changed.new_blocks_movement);
    const stats = try test_support.applyTileChange(&system, no_colliders, &world, changed);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);

    // The surface's cells and records are untouched, record ids included.
    try std.testing.expect(levelsEquivalent(&system.graph, &surface_before.graph, 0));
    try std.testing.expectEqualSlices(u32, record_dir_before, system.graph.levelGraph(0).?.record_dir.items);
    // Sanity: the underground level DID change (not a no-op batch).
    try std.testing.expect(!system.graph.grid(1).?.isBlockedCell(.{ .x = 5, .y = 5 }));

    // And it still matches a full rebuild on every level.
    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, null);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "incremental dig keeps the changed level's records identical to a full rebuild" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    const level1_obstacle = try world.addDenseLayer(1, 0, .obstacle, grass);
    _ = try world.setDenseTile(level1_obstacle, 5, 5, tree);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

    const changed = (try world.setDenseTile(level1_obstacle, 5, 5, grass)) orelse return error.TestExpectedEqual;
    _ = try test_support.applyTileChange(&system, no_colliders, &world, changed);

    var rebuilt = try fullRebuild(&data, &world, abstractCapacity());
    defer rebuilt.deinit();
    try std.testing.expect(levelsEquivalent(&system.graph, &rebuilt.graph, 1));
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}
test "incremental nav update applies the same edit batch deterministically" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

    // Apply a multi-cell straddling edit, snapshot the changed level, then rebuild from the
    // same start state and apply the same batch again: the result must be identical.
    const edits = [_]test_support.TileEdit{ .{ .level = 0, .x = 5, .y = 5 }, .{ .level = 0, .x = 6, .y = 5 }, .{ .level = 0, .x = 5, .y = 6 } };
    _ = (try world.setDenseTile(obstacle, 5, 5, tree)) orelse return error.TestExpectedEqual;
    _ = (try world.setDenseTile(obstacle, 6, 5, tree)) orelse return error.TestExpectedEqual;
    _ = (try world.setDenseTile(obstacle, 5, 6, tree)) orelse return error.TestExpectedEqual;
    _ = try test_support.applyTileEdits(&system, no_colliders, &world, &edits);

    // The same post-edit world built twice and patched once all agree.
    var second = try fullRebuild(&data, &world, abstractCapacity());
    defer second.deinit();
    try expectGraphsEquivalent(&system.graph, &second.graph);
    var third = try fullRebuild(&data, &world, abstractCapacity());
    defer third.deinit();
    try expectGraphsEquivalent(&second.graph, &third.graph);
}
test "incremental single-chunk dig patches a constant chunk set independent of world size" {
    // The dirty-bounded work proxy: a one-cell dig in an interior chunk patches that chunk
    // plus its four orthogonal neighbors (5), regardless of how large the level is. If this
    // ever scaled with world size, dirty-bounding would have silently regressed.
    const extents = [_]f32{ 512, 1024 };
    var patched: [extents.len]usize = undefined;
    for (extents, 0..) |extent, i| {
        var data = DataSystem.init(std.testing.allocator);
        defer data.deinit();
        var meta = try loadTestWorldMeta(std.testing.allocator);
        defer meta.deinit();
        const grass = try requireTestTile(&meta, "grass");
        const tree = try requireTestTile(&meta, "tree_0");

        var world = try test_support.abstractTestWorld(&meta, extent, extent);
        defer world.deinit();
        const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

        var system = PathfindingSystem.init(std.testing.allocator);
        defer system.deinit();
        try system.reserve(abstractCapacity());
        try system.rebuildStaticNavGridWithWorld(&data, &world, null);

        // Cell (5,5) sits in chunk (1,1) (4-tile chunks): interior for both worlds.
        const changed = (try world.setDenseTile(obstacle, 5, 5, tree)) orelse return error.TestExpectedEqual;
        const stats = try test_support.applyTileChange(&system, no_colliders, &world, changed);
        patched[i] = stats.chunks_patched;
    }
    try std.testing.expectEqual(@as(usize, 5), patched[0]);
    try std.testing.expectEqual(patched[0], patched[1]);
}

test "incremental nav update across distant chunks in one batch matches a full rebuild" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    // 512 extent at cell_size 32 is 16 nav cells/side; with 4-tile chunks that is a 4x4 chunk
    // grid, so the two digs below land in opposite-corner chunks with clear space between them.
    const extent: f32 = 512;
    var world = try test_support.abstractTestWorld(&meta, extent, extent);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

    // Two digs in opposite-corner chunks applied as ONE batch. The whole-chunk remask-from-world
    // must reach BOTH distant chunks; a producer that dropped either (or a per-cell remask that
    // missed a coalesced cell) would leave that chunk stale, so the incremental graph must equal
    // a fresh full rebuild against the same world.
    const cells = [_]struct { x: u16, y: u16 }{ .{ .x = 1, .y = 1 }, .{ .x = 13, .y = 13 } };
    var edits: [cells.len]test_support.TileEdit = undefined;
    for (cells, 0..) |cell, i| {
        _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tree)) orelse return error.TestExpectedEqual;
        edits[i] = .{ .level = 0, .x = cell.x, .y = cell.y };
    }
    _ = try test_support.applyTileEdits(&system, no_colliders, &world, &edits);

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, null);

    // Both distant chunks ended blocked in the incremental graph's mask (no dropped cell).
    const nav = system.graph.grid(0).?;
    for (cells) |cell| try std.testing.expect(nav.isBlockedCell(.{ .x = @intCast(cell.x), .y = @intCast(cell.y) }));
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "incremental nav update forced-parallel remask and patch match a serial full rebuild" {
    // The adaptive tuner usually runs a small dig inline, so the threaded remask/patch branches go
    // unexercised. This pins both: forcing adaptive=false with items_per_range=1 over a multi-chunk
    // dig drives the parallel path (asserted via ran_inline == false for BOTH stages), and the
    // disjoint-window result must still be byte-identical to a fresh serial full rebuild.
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    const extent: f32 = 512;
    var world = try test_support.abstractTestWorld(&meta, extent, extent);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var cap = abstractCapacity();
    cap.worker_participant_count = threads.participantSlotCount();
    try system.reserve(cap);
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    // Force the parallel schedule rather than letting the tuner keep the small batch inline.
    system.nav_controls = .{ .adaptive = false, .items_per_range = 1 };

    // Five cells in five distinct nav_chunk_tiles=4 chunks, so both the remask changed-chunk set
    // and the patch dirty set exceed one chunk and actually fan out.
    const cells = [_]struct { x: u16, y: u16 }{
        .{ .x = 1, .y = 1 },  .{ .x = 13, .y = 1 },
        .{ .x = 1, .y = 13 }, .{ .x = 13, .y = 13 },
        .{ .x = 7, .y = 7 },
    };
    for (cells) |cell| {
        _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tree)) orelse return error.TestExpectedEqual;
        try test_support.recordTileEdits(&system, &world, &.{.{ .level = 0, .x = cell.x, .y = cell.y }});
    }
    const stats = try system.applyBufferedNavUpdates(no_colliders, &world, &threads);

    // Both stages must have actually threaded, not fallen back to the inline slot-0 path.
    try std.testing.expect(!stats.remask_batch.ran_inline);

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(cap);
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, null);

    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "incremental nav update threaded chunk patch matches a serial full rebuild" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    const extent: f32 = 512;
    var world = try test_support.abstractTestWorld(&meta, extent, extent);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var cap = abstractCapacity();
    cap.worker_participant_count = threads.participantSlotCount();
    try system.reserve(cap);
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

    // Dig several chunks (each corner plus the center) in one batch, applied through the
    // THREADED buffered path. Each chunk patches only its own record, so the threaded result
    // must equal a fresh serial full rebuild.
    // (The adaptive tuner may run this small batch inline; patchJob runs either way, and
    // parity holds by the disjoint-window design regardless of how it is scheduled.)
    const cells = [_]struct { x: u16, y: u16 }{
        .{ .x = 1, .y = 1 },  .{ .x = 13, .y = 1 },
        .{ .x = 1, .y = 13 }, .{ .x = 13, .y = 13 },
        .{ .x = 7, .y = 7 },
    };
    for (cells) |cell| {
        _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tree)) orelse return error.TestExpectedEqual;
        try test_support.recordTileEdits(&system, &world, &.{.{ .level = 0, .x = cell.x, .y = cell.y }});
    }
    _ = try system.applyBufferedNavUpdates(no_colliders, &world, &threads);

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(cap);
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, null);

    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

// A world-backed nav with colliders built from `data`, seam-driven by `frame`.
const StaticNav = struct {
    data: DataSystem,
    world: WorldSystem,
    colliders: StaticColliderSystem,
    system: PathfindingSystem,
    frame: SimulationFrame,

    fn deinit(self: *StaticNav) void {
        self.frame.deinit();
        self.system.deinit();
        self.colliders.deinit();
        self.world.deinit();
        self.data.deinit();
    }

    // Commits `commands` through the seam and runs the nav reaction.
    fn commitAndReact(self: *StaticNav, commands: []const StructuralCommand, thread_system: *ThreadSystem) !NavUpdateStats {
        try test_support.commitWithColliders(&self.frame, &self.data, &self.colliders, &self.system, commands);
        return self.system.reactToPostCommitNavEvents(&self.frame, &self.colliders, &self.world, thread_system);
    }

    // A fresh full build of the current data and world.
    fn rebuilt(self: *const StaticNav) !PathfindingSystem {
        return fullRebuild(&self.data, &self.world, abstractCapacity());
    }
};

// `world` with `statics` (position, size) added to an empty `DataSystem` before nav builds.
fn staticNav(meta: *const @import("../../../assets/world_tileset_meta.zig").WorldTilesetMeta, extent: f32, statics: []const [2]math.Vec2, capacity: types.PathfindingCapacity) !StaticNav {
    var data = DataSystem.init(std.testing.allocator);
    errdefer data.deinit();
    for (statics) |body| _ = try addNavBody(&data, body[0], body[1], true);
    var world = try test_support.abstractTestWorld(meta, extent, extent);
    errdefer world.deinit();
    var colliders = try test_support.worldColliders(&data, &world);
    errdefer colliders.deinit();
    var system = PathfindingSystem.init(std.testing.allocator);
    errdefer system.deinit();
    try system.reserve(capacity);
    try system.rebuildNavFromColliders(&colliders, PathfindingSystem.worldNavExtent(&world), null);
    return .{ .data = data, .world = world, .colliders = colliders, .system = system, .frame = SimulationFrame.init(std.testing.allocator) };
}

fn staticTemplate(position: math.Vec2, size: math.Vec2) EntityTemplate {
    return .{
        .movement_body = .{ .position = position, .previous_position = position },
        .collision_bounds = .{ .size = size },
        .collision_response = .{ .mobility = .static },
    };
}

fn moveCommand(entity: EntityId, position: math.Vec2) StructuralCommand {
    return .{ .set_movement_body = .{ .entity = entity, .body = .{ .position = position, .previous_position = position } } };
}

test "destroying a static body and reacting leaves its cell open" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var nav = try staticNav(&meta, 256, &.{.{ .{ .x = 100, .y = 100 }, .{ .x = 16, .y = 16 } }}, abstractCapacity());
    defer nav.deinit();
    const entity = nav.data.movementBodySliceConst().entities[0];
    const cell = nav.system.graph.grid(0).?.worldToCellClamped(.{ .x = 100, .y = 100 });
    try std.testing.expect(nav.system.graph.grid(0).?.isBlockedCell(cell));

    _ = try nav.commitAndReact(&.{.{ .destroy_entity = entity }}, &serial_threads);
    try std.testing.expect(!nav.system.graph.grid(0).?.isBlockedCell(cell));
    var rebuilt = try nav.rebuilt();
    defer rebuilt.deinit();
    try expectGraphsEquivalent(&nav.system.graph, &rebuilt.graph);
}

test "entity obstacle create/destroy patches a constant chunk set independent of world size and matches a full rebuild" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    // As "incremental single-chunk dig patches a constant chunk set independent of world
    // size", for a static body created and destroyed through the commit seam.
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const extents = [_]f32{ 512, 1024 };
    var patched: [extents.len]usize = undefined;
    for (extents, 0..) |extent, i| {
        var nav = try staticNav(&meta, extent, &.{}, abstractCapacity());
        defer nav.deinit();
        // Cell (5,5) sits in chunk (1,1) (4-tile chunks): interior for both worlds.
        const create_stats = try nav.commitAndReact(&.{.{ .create_entity = staticTemplate(.{ .x = 160, .y = 160 }, .{ .x = 8, .y = 8 }) }}, &serial_threads);
        patched[i] = create_stats.chunks_patched;
        var rebuilt_created = try nav.rebuilt();
        defer rebuilt_created.deinit();
        try expectGraphsEquivalent(&nav.system.graph, &rebuilt_created.graph);

        const entity = nav.colliders.changesThisStep()[0].entity;
        _ = try nav.commitAndReact(&.{.{ .destroy_entity = entity }}, &serial_threads);
        var rebuilt_destroyed = try nav.rebuilt();
        defer rebuilt_destroyed.deinit();
        try expectGraphsEquivalent(&nav.system.graph, &rebuilt_destroyed.graph);
    }
    try std.testing.expectEqual(@as(usize, 5), patched[0]);
    try std.testing.expectEqual(patched[0], patched[1]);
}

test "entity obstacle move marks both old and new spans dirty at a distance-independent patch cost" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    // Moves a static obstacle corner-to-corner in one commit: its old and new spans each
    // patch a corner chunk and its two orthogonal neighbors, never a box spanning both, so
    // the total (6) does not depend on how far apart the corners are.
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const extents = [_]f32{ 512, 1024 };
    var patched: [extents.len]usize = undefined;
    for (extents, 0..) |extent, i| {
        var nav = try staticNav(&meta, extent, &.{.{ .{ .x = 8, .y = 8 }, .{ .x = 8, .y = 8 } }}, abstractCapacity());
        defer nav.deinit();
        const entity = nav.data.movementBodySliceConst().entities[0];
        const old_cell = nav.system.graph.grid(0).?.worldToCellClamped(.{ .x = 8, .y = 8 });
        try std.testing.expect(nav.system.graph.grid(0).?.isBlockedCell(old_cell));
        const cells_side: u16 = @intFromFloat(extent / 32.0);
        const far_coord: f32 = @as(f32, @floatFromInt(cells_side - 1)) * 32.0 + 8.0;
        const new_cell = nav.system.graph.grid(0).?.worldToCellClamped(.{ .x = far_coord, .y = far_coord });

        const stats = try nav.commitAndReact(&.{moveCommand(entity, .{ .x = far_coord, .y = far_coord })}, &serial_threads);
        patched[i] = stats.chunks_patched;
        try std.testing.expect(!nav.system.graph.grid(0).?.isBlockedCell(old_cell));
        try std.testing.expect(nav.system.graph.grid(0).?.isBlockedCell(new_cell));
        var rebuilt = try nav.rebuilt();
        defer rebuilt.deinit();
        try expectGraphsEquivalent(&nav.system.graph, &rebuilt.graph);
    }
    try std.testing.expectEqual(@as(usize, 6), patched[0]);
    try std.testing.expectEqual(patched[0], patched[1]);
}

test "overlapping static bodies: destroying one leaves the shared cell blocked by the survivor" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    // Two static bodies fully overlapping the same cell.
    var nav = try staticNav(&meta, 512, &.{
        .{ .{ .x = 160, .y = 160 }, .{ .x = 8, .y = 8 } },
        .{ .{ .x = 162, .y = 162 }, .{ .x = 8, .y = 8 } },
    }, abstractCapacity());
    defer nav.deinit();
    const bodies = nav.data.movementBodySliceConst().entities;
    const a = bodies[0];
    const b = bodies[1];
    const cell = nav.system.graph.grid(0).?.worldToCellClamped(.{ .x = 160, .y = 160 });
    try std.testing.expect(nav.system.graph.grid(0).?.isBlockedCell(cell));

    _ = try nav.commitAndReact(&.{.{ .destroy_entity = a }}, &serial_threads);
    try std.testing.expect(nav.system.graph.grid(0).?.isBlockedCell(cell));
    _ = try nav.commitAndReact(&.{.{ .destroy_entity = b }}, &serial_threads);
    try std.testing.expect(!nav.system.graph.grid(0).?.isBlockedCell(cell));
}

test "static-to-dynamic-to-static toggle blocks and unblocks in place without moving" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var nav = try staticNav(&meta, 512, &.{.{ .{ .x = 160, .y = 160 }, .{ .x = 8, .y = 8 } }}, abstractCapacity());
    defer nav.deinit();
    const entity = nav.data.movementBodySliceConst().entities[0];
    const cell = nav.system.graph.grid(0).?.worldToCellClamped(.{ .x = 160, .y = 160 });
    try std.testing.expect(nav.system.graph.grid(0).?.isBlockedCell(cell));

    _ = try nav.commitAndReact(&.{.{ .set_collision_response = .{ .entity = entity, .response = .{ .mobility = .dynamic } } }}, &serial_threads);
    try std.testing.expect(!nav.system.graph.grid(0).?.isBlockedCell(cell));
    _ = try nav.commitAndReact(&.{.{ .set_collision_response = .{ .entity = entity, .response = .{ .mobility = .static } } }}, &serial_threads);
    try std.testing.expect(nav.system.graph.grid(0).?.isBlockedCell(cell));
}

test "a static on level 2 blocks level 2 only" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const fixture = try twoLevelWorld(&meta);
    var nav = StaticNav{
        .data = DataSystem.init(std.testing.allocator),
        .world = fixture.world,
        .colliders = undefined,
        .system = PathfindingSystem.init(std.testing.allocator),
        .frame = SimulationFrame.init(std.testing.allocator),
    };
    nav.colliders = try test_support.worldColliders(&nav.data, &nav.world);
    defer nav.deinit();
    _ = try nav.world.addLevel(-32);
    _ = try nav.world.addDenseLayer(2, 0, .floor, fixture.grass);
    try nav.system.reserve(abstractCapacity());
    try nav.system.rebuildNavFromColliders(&nav.colliders, PathfindingSystem.worldNavExtent(&nav.world), null);

    var template = staticTemplate(.{ .x = 160, .y = 160 }, .{ .x = 8, .y = 8 });
    template.world_level = 2;
    _ = try nav.commitAndReact(&.{.{ .create_entity = template }}, &serial_threads);
    for (0..3) |level| {
        try std.testing.expectEqual(level == 2, nav.system.graph.grid(@intCast(level)).?.isBlockedCell(.{ .x = 5, .y = 5 }));
    }
    var rebuilt = try nav.rebuilt();
    defer rebuilt.deinit();
    try expectGraphsEquivalent(&nav.system.graph, &rebuilt.graph);
}

test "a static obstacle move costs the same at 10 and 10k statics" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    // 128 x 128 cells in 4-tile chunks; the moved body stays in chunk (1,1), and the other
    // statics fill cells outside chunks 0..2 x 0..2 one per cell.
    const other_counts = [_]usize{ 10, 10_000 };
    var patched: [other_counts.len]usize = undefined;
    var remasked: [other_counts.len]usize = undefined;
    var listed: [other_counts.len]usize = undefined;
    for (other_counts, 0..) |other_count, run| {
        var statics: std.ArrayList([2]math.Vec2) = .empty;
        defer statics.deinit(std.testing.allocator);
        try statics.append(std.testing.allocator, .{ .{ .x = 164, .y = 164 }, .{ .x = 8, .y = 8 } });
        var cell: usize = 0;
        while (statics.items.len < other_count + 1) : (cell += 1) {
            const x = cell % 128;
            const y = cell / 128;
            if (x < 12 and y < 12) continue;
            try statics.append(std.testing.allocator, .{ .{ .x = @as(f32, @floatFromInt(x)) * 32 + 4, .y = @as(f32, @floatFromInt(y)) * 32 + 4 }, .{ .x = 8, .y = 8 } });
        }
        var nav = try staticNav(&meta, 4096, statics.items, abstractCapacity());
        defer nav.deinit();
        try std.testing.expectEqual(other_count + 1, static_colliders_test_support.liveRowCount(nav.colliders));
        const moved = nav.data.movementBodySliceConst().entities[0];
        const stats = try nav.commitAndReact(&.{moveCommand(moved, .{ .x = 196, .y = 196 })}, &serial_threads);
        patched[run] = stats.chunks_patched;
        remasked[run] = stats.dirty_chunks;
        // Rows the remask visited: those listed at the remasked chunks.
        var visited: usize = 0;
        for (nav.system.graph.changed_keys.items) |key| {
            var rows = nav.colliders.view().chunkRows(keyLevel(key), keyChunk(key));
            while (rows.next()) |_| visited += 1;
        }
        listed[run] = visited;
    }
    try std.testing.expectEqual(patched[0], patched[1]);
    try std.testing.expectEqual(remasked[0], remasked[1]);
    try std.testing.expectEqual(listed[0], listed[1]);
    try std.testing.expectEqual(@as(usize, 1), listed[0]);
}

test "a ramp whose exit holds a static body routes only after the body moves" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const fixture = try twoLevelWorld(&meta);
    var nav = StaticNav{
        .data = DataSystem.init(std.testing.allocator),
        .world = fixture.world,
        .colliders = undefined,
        .system = PathfindingSystem.init(std.testing.allocator),
        .frame = SimulationFrame.init(std.testing.allocator),
    };
    nav.colliders = try test_support.worldColliders(&nav.data, &nav.world);
    defer nav.deinit();
    try nav.system.reserve(abstractCapacity());
    try nav.system.rebuildNavFromColliders(&nav.colliders, PathfindingSystem.worldNavExtent(&nav.world), null);
    // A static body on the ramp's level-0 exit cell (5,5).
    _ = try nav.commitAndReact(&.{.{ .create_entity = staticTemplate(.{ .x = 164, .y = 164 }, .{ .x = 8, .y = 8 }) }}, &serial_threads);
    const body = nav.colliders.changesThisStep()[0].entity;
    try nav.world.addLevelLink(.{ .kind = .ramp, .level_a = 1, .cell_a = .{ .x = 5, .y = 5 }, .level_b = 0, .cell_b = .{ .x = 5, .y = 5 }, .traversal_cost = 1, .bidirectional = true });
    _ = try nav.system.applyBufferedNavUpdates(&nav.colliders, &nav.world, &serial_threads);
    try std.testing.expect(!try routes(&nav.system, &nav.data, &nav.world, 1, .{ 1, 1 }, 0, .{ 10, 10 }));

    _ = try nav.commitAndReact(&.{moveCommand(body, .{ .x = 292, .y = 36 })}, &serial_threads);
    try std.testing.expect(try routes(&nav.system, &nav.data, &nav.world, 1, .{ 1, 1 }, 0, .{ 10, 10 }));
    var rebuilt = try nav.rebuilt();
    defer rebuilt.deinit();
    try expectGraphsEquivalent(&nav.system.graph, &rebuilt.graph);
}

test "incremental nav update threaded chunk patch matches a serial full rebuild with an entity-obstacle edit" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    // A static body destroyed through the seam, folded into the same threaded batch as four
    // tile digs, must match a serial full rebuild exactly like the tile-only batch does.
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var cap = abstractCapacity();
    cap.worker_participant_count = threads.participantSlotCount();
    var nav = try staticNav(&meta, 512, &.{.{ .{ .x = 224, .y = 224 }, .{ .x = 8, .y = 8 } }}, cap);
    defer nav.deinit();
    const obstacle = try nav.world.addDenseLayer(0, 0, .obstacle, grass);
    // The layer add moved level 0's content revision: settle it before the batch.
    _ = try nav.system.applyBufferedNavUpdates(&nav.colliders, &nav.world, &serial_threads);
    nav.system.nav_controls = .{ .adaptive = false, .items_per_range = 1 };

    const entity = nav.data.movementBodySliceConst().entities[0];
    try test_support.commitWithColliders(&nav.frame, &nav.data, &nav.colliders, &nav.system, &.{.{ .destroy_entity = entity }});
    const cells = [_]struct { x: u16, y: u16 }{
        .{ .x = 1, .y = 1 },  .{ .x = 13, .y = 1 },
        .{ .x = 1, .y = 13 }, .{ .x = 13, .y = 13 },
    };
    for (cells) |cell| {
        _ = (try nav.world.setDenseTile(obstacle, cell.x, cell.y, tree)) orelse return error.TestExpectedEqual;
        try test_support.recordTileEdits(&nav.system, &nav.world, &.{.{ .level = 0, .x = cell.x, .y = cell.y }});
    }
    const stats = try nav.system.applyBufferedNavUpdates(&nav.colliders, &nav.world, &threads);
    try std.testing.expect(!stats.remask_batch.ran_inline);

    var rebuilt = try nav.rebuilt();
    defer rebuilt.deinit();
    try expectGraphsEquivalent(&nav.system.graph, &rebuilt.graph);
}

test "a static obstacle commit and its nav reaction are allocation-free at steady state" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var nav = try staticNav(&meta, 512, &.{.{ .{ .x = 160, .y = 160 }, .{ .x = 8, .y = 8 } }}, abstractCapacity());
    defer nav.deinit();
    const entity = nav.data.movementBodySliceConst().entities[0];
    // Warmup: the body moves out and back through the seam, so the mark buffer, batch keys,
    // cell blocks, records, and the collider lists reach their high-water.
    _ = try nav.commitAndReact(&.{moveCommand(entity, .{ .x = 228, .y = 228 })}, &serial_threads);
    _ = try nav.commitAndReact(&.{moveCommand(entity, .{ .x = 160, .y = 160 })}, &serial_threads);

    const original = nav.system.allocator;
    nav.system.allocator = std.testing.failing_allocator;
    nav.system.graph.allocator = std.testing.failing_allocator;
    defer {
        nav.system.graph.allocator = original;
        nav.system.allocator = original;
    }
    // The same move again: the reaction allocates nothing.
    try test_support.commitWithColliders(&nav.frame, &nav.data, &nav.colliders, &nav.system, &.{moveCommand(entity, .{ .x = 228, .y = 228 })});
    const stats = try nav.system.reactToPostCommitNavEvents(&nav.frame, &nav.colliders, &nav.world, &serial_threads);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
}

test "remask and patch after reserve allocate nothing on a multi-worker ThreadSystem (FailingAllocator)" {
    // The remask's cell blocks and the patch's records and link slots are reserved on the
    // main thread before dispatch; workers only fill what was claimed. This proves it on a
    // real multi-worker ThreadSystem, with a static collider listed in a remasked chunk.
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addNavBody(&data, .{ .x = 164, .y = 164 }, .{ .x = 8, .y = 8 }, true);
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    const extent: f32 = 512;
    var world = try test_support.abstractTestWorld(&meta, extent, extent);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var cap = abstractCapacity();
    cap.worker_participant_count = threads.participantSlotCount();
    try system.reserve(cap);
    var colliders = try test_support.worldColliders(&data, &world);
    defer colliders.deinit();
    try system.rebuildNavFromColliders(&colliders, PathfindingSystem.worldNavExtent(&world), null);
    // Force the parallel schedule rather than letting the tuner keep the small batch inline,
    // so the proof exercises the workers.
    system.nav_controls = .{ .adaptive = false, .items_per_range = 1 };

    // Five cells in five distinct nav_chunk_tiles=4 chunks, so both the remask changed-chunk
    // set and the patch dirty set exceed one chunk and actually fan out to workers.
    const warm_cells = [_]struct { x: u16, y: u16 }{
        .{ .x = 1, .y = 1 },  .{ .x = 13, .y = 1 },
        .{ .x = 1, .y = 13 }, .{ .x = 13, .y = 13 },
        .{ .x = 7, .y = 7 },
    };
    // A distinct cell in each of the SAME five chunks, dug during the failing-allocator proof
    // below. Same per-chunk/per-worker footprint as the warmup, so no buffer grows.
    const proof_cells = [_]struct { x: u16, y: u16 }{
        .{ .x = 2, .y = 2 },  .{ .x = 14, .y = 1 },
        .{ .x = 2, .y = 14 }, .{ .x = 14, .y = 14 },
        .{ .x = 6, .y = 6 },
    };

    // Warmup: toggle the warm cells on then off through the THREADED path, so every buffer the
    // threaded stages touch (batch keys and masks, plan windows, cell blocks, record pools)
    // reaches steady-state capacity before the failing-allocator proof.
    for ([_]@TypeOf(tree){ tree, grass }) |tile| {
        for (warm_cells) |cell| {
            _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tile)) orelse return error.TestExpectedEqual;
            try test_support.recordTileEdits(&system, &world, &.{.{ .level = 0, .x = cell.x, .y = cell.y }});
        }
        const warm_stats = try system.applyBufferedNavUpdates(&colliders, &world, &threads);
        try std.testing.expectEqual(@as(usize, 1), warm_stats.incremental_rebuilds);
        // The warmup itself must have threaded, so the proof below runs the same dispatch.
        try std.testing.expect(!warm_stats.remask_batch.ran_inline);
    }

    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;

    for (proof_cells) |cell| {
        _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tree)) orelse return error.TestExpectedEqual;
        try test_support.recordTileEdits(&system, &world, &.{.{ .level = 0, .x = cell.x, .y = cell.y }});
    }
    const stats = try system.applyBufferedNavUpdates(&colliders, &world, &threads);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    // The stages threaded under the failing allocator and allocated nothing.
    try std.testing.expect(!stats.remask_batch.ran_inline);

    system.graph.allocator = original;
    system.allocator = original;
}

test "a nav whose every chunk is mixed, with links in separate chunks, stays within its storage bound after its build and a dense batch" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");
    var world = try test_support.abstractTestWorld(&meta, 1024, 1024);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);
    // Blocking diagonals every third cell: every chunk mixed, with many border runs.
    for (0..world.height) |y| for (0..world.width) |x| {
        if ((x + y) % 3 == 0) _ = try world.setDenseTile(obstacle, @intCast(x), @intCast(y), tree);
    };
    // One same-level link per pair of far chunks, each end alone in its chunk.
    const ct: u16 = world.chunk_size_tiles;
    const links: u16 = 4;
    const spacing = world.width / links;
    try std.testing.expect(spacing >= 2 * ct);
    for (0..links) |index| {
        const offset: u16 = @intCast(index * spacing + 1);
        try world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = offset, .y = 1 }, .level_b = 0, .cell_b = .{ .x = offset, .y = @intCast(world.height - 2) }, .traversal_cost = 1, .bidirectional = true });
    }
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    var colliders = try test_support.worldColliders(&data, &world);
    defer colliders.deinit();
    try system.rebuildNavFromColliders(&colliders, PathfindingSystem.worldNavExtent(&world), null);
    const graph = &system.graph;
    // The world's content: every chunk mixed, each link end alone in its chunk.
    const content = test_support.navStorageContentOf(&world);
    try std.testing.expectEqual(graph.chunkCount(), content.mixed_chunks);
    try std.testing.expectEqual(@as(usize, 0), content.open_chunks);
    try std.testing.expectEqual(@as(usize, 2 * links), content.endpoint_chunks);
    try std.testing.expectEqual(@as(usize, 1), content.max_chunk_endpoints);
    var shape = test_support.NavStorageShape{
        .chunks = graph.chunkCount(),
        .levels = graph.levelCount(),
        .chunk_tiles = graph.geometry.chunk_tiles,
        .links = links,
        .oneway_links = 0,
        .batch_mark_chunks = 0,
        .batch_links = 0,
        .batch_keys = 0,
        .content = content,
    };
    try std.testing.expect(graph.residentBytes() <= test_support.navStorageBytesBound(shape));
    // Every cell of a 2x2-chunk corner flips, one mark each.
    var flipped: usize = 0;
    for (0..2 * ct) |y| for (0..2 * ct) |x| {
        const tile = if (world.denseTile(obstacle, @intCast(x), @intCast(y)) == tree) grass else tree;
        _ = try world.setDenseTile(obstacle, @intCast(x), @intCast(y), tile);
        try test_support.recordTileEdits(&system, &world, &.{.{ .level = 0, .x = @intCast(x), .y = @intCast(y) }});
        flipped += 1;
    };
    const stats = try system.applyBufferedNavUpdates(&colliders, &world, &serial_threads);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    shape.batch_mark_chunks = flipped;
    shape.batch_keys = 2 * 2 + 4 * 2;
    try std.testing.expect(graph.residentBytes() <= test_support.navStorageBytesBound(shape));
    // The batch's staging is charged: a bound with no batch is short of it.
    var no_batch = shape;
    no_batch.batch_mark_chunks = 0;
    no_batch.batch_keys = 0;
    try std.testing.expect(test_support.navStorageBytesBound(shape) > test_support.navStorageBytesBound(no_batch));
    // Without the content every chunk is charged mixed and holding endpoints: never less.
    var structural = shape;
    structural.content = null;
    try std.testing.expect(test_support.navStorageBytesBound(structural) >= test_support.navStorageBytesBound(shape));
}

test "a nav over open and blocked levels is charged by the world's content and stays within its bound" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");
    const dirt = try requireTestTile(&meta, "dirt");
    var world = try test_support.abstractTestWorld(&meta, 1024, 1024);
    defer world.deinit();
    // Level 0 holds at least one mixed chunk; level 1 is blocked whole.
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);
    _ = try world.setDenseTile(obstacle, 1, 1, tree);
    const lower = try world.addLevel(-32);
    const lower_floor = try world.addDenseLayer(lower, 0, .floor, dirt);
    const content = test_support.navStorageContentOf(&world);
    const chunks = world.chunkCountPerLevel();
    try std.testing.expect(content.mixed_chunks >= 1);
    // Only level 0 holds open or mixed chunks.
    try std.testing.expect(content.open_chunks + content.mixed_chunks <= chunks);
    try std.testing.expectEqual(content.open_chunks, content.max_level_open);
    try std.testing.expectEqual(content.mixed_chunks, content.max_level_mixed);
    try std.testing.expectEqual(@as(usize, 0), content.endpoint_chunks);
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    var colliders = try test_support.worldColliders(&data, &world);
    defer colliders.deinit();
    try system.rebuildNavFromColliders(&colliders, PathfindingSystem.worldNavExtent(&world), null);
    var shape = test_support.NavStorageShape{
        .chunks = system.graph.chunkCount(),
        .levels = system.graph.levelCount(),
        .chunk_tiles = system.graph.geometry.chunk_tiles,
        .batch_mark_chunks = 1,
        .batch_links = 0,
        .batch_keys = 5,
        .content = content,
    };
    try std.testing.expectEqual(chunks, shape.chunks);
    try std.testing.expect(system.graph.residentBytes() <= test_support.navStorageBytesBound(shape));
    // A dig on the blocked level: its chunk turns mixed, within the batch's charge.
    const dug = try world.setDenseTile(lower_floor, 5, 5, grass);
    try std.testing.expect(dug != null);
    try test_support.recordTileEdits(&system, &world, &.{.{ .level = lower, .x = 5, .y = 5 }});
    _ = try system.applyBufferedNavUpdates(&colliders, &world, &serial_threads);
    try std.testing.expect(system.graph.residentBytes() <= test_support.navStorageBytesBound(shape));
    shape.content = null;
    try std.testing.expect(test_support.navStorageBytesBound(shape) > test_support.navStorageBytesBound(.{ .chunks = chunks, .levels = 2, .chunk_tiles = shape.chunk_tiles, .batch_mark_chunks = 1, .batch_links = 0, .batch_keys = 5, .content = content }));
}

// A path request on the next step from `start` on `start_level` to `goal` on `goal_level`
// (tile cells); returns whether it solved available.
fn routes(system: *PathfindingSystem, data: *DataSystem, world: *const WorldSystem, start_level: u16, start: [2]u16, goal_level: u16, goal: [2]u16) !bool {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    const tile = world.tile_size;
    const center = struct {
        fn of(cell: [2]u16, size: f32) math.Vec2 {
            return .{ .x = (@as(f32, @floatFromInt(cell[0])) + 0.5) * size, .y = (@as(f32, @floatFromInt(cell[1])) + 0.5) * size };
        }
    }.of;
    try appendPathRequest(&stream, .{
        .entity = try addNavBody(data, .{}, .{ .x = 4, .y = 4 }, false),
        .start_level = start_level,
        .goal_level = goal_level,
        .start = center(start, tile),
        .goal = center(goal, tile),
    });
    const stats = try updatePathfindingInline(system, &stream, 8, .{});
    return stats.available_results == 1;
}

// A 12x12 world in 4-tile chunks over two open levels with an obstacle band each.
const TwoLevelWorld = struct {
    world: WorldSystem,
    obstacle: [2]usize,
    grass: TileId,
    tree: TileId,
};

fn twoLevelWorld(meta: *const @import("../../../assets/world_tileset_meta.zig").WorldTilesetMeta) !TwoLevelWorld {
    const grass = try requireTestTile(meta, "grass");
    const tree = try requireTestTile(meta, "tree_0");
    var world = try test_support.abstractTestWorld(meta, 384, 384);
    errdefer world.deinit();
    _ = try world.addLevel(-16);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    const obstacle_0 = try world.addDenseLayer(0, 0, .obstacle, grass);
    const obstacle_1 = try world.addDenseLayer(1, 0, .obstacle, grass);
    return .{ .world = world, .obstacle = .{ obstacle_0, obstacle_1 }, .grass = grass, .tree = tree };
}

test "a record pool grow whose border windows fail to grow leaves every record, free id, and window as it was" {
    const allocator = std.testing.allocator;
    var level_graph = NavLevelGraph{ .border_stride = 4 };
    defer level_graph.deinit(allocator);
    var pool_grows: u64 = 0;
    try level_graph.record_dir.appendNTimes(allocator, no_record, 64);
    // Four records, then a fifth: the pool doubles to eight rows, room for three more.
    try level_graph.ensureFreeRecords(allocator, 4, &pool_grows);
    try level_graph.ensureFreeRecords(allocator, 5, &pool_grows);
    try std.testing.expect(level_graph.records.capacity > level_graph.records.len);
    try std.testing.expectEqual(level_graph.records.capacity, level_graph.record_free.capacity);
    // The windows hold exactly the rows, so one more record needs only the border to grow.
    level_graph.border.shrinkAndFree(allocator, level_graph.border.items.len);
    try std.testing.expectEqual(level_graph.border.items.len, level_graph.border.capacity);
    const rows = level_graph.records.len;
    const free = level_graph.record_free.items.len;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, level_graph.ensureFreeRecords(failing.allocator(), free + 1, &pool_grows));
    try std.testing.expectEqual(rows, level_graph.records.len);
    try std.testing.expectEqual(free, level_graph.record_free.items.len);
    try std.testing.expectEqual(rows * level_graph.border_stride, level_graph.border.items.len);
    // The retry grows the windows, then the pool.
    try level_graph.ensureFreeRecords(allocator, free + 1, &pool_grows);
    try std.testing.expectEqual(level_graph.records.len * level_graph.border_stride, level_graph.border.items.len);
}

test "a record or link-slot pool grow that fails after the pool moved keeps the column views on the live pool" {
    var level_graph = NavLevelGraph{ .border_stride = 4 };
    defer level_graph.deinit(std.testing.allocator);
    var pool_grows: u64 = 0;
    try level_graph.record_dir.appendNTimes(std.testing.allocator, no_record, 64);
    try level_graph.ensureFreeRecords(std.testing.allocator, 4, &pool_grows);
    try level_graph.ensureFreeLinkSlots(std.testing.allocator, 2, &pool_grows);
    const first = level_graph.claimRecord(0);
    level_graph.border_count[first] = 3;
    level_graph.claimLinkSlot(first);

    // Growing past each pool moves it (allocation 0); growing its next list (allocation 1,
    // after a refused in-place resize) fails. The record windows are reserved ahead, so the
    // record pool's move is allocation 0.
    const record_need = level_graph.records.capacity + 1;
    try level_graph.border.ensureTotalCapacity(std.testing.allocator, (level_graph.records.len + record_need - level_graph.record_free.items.len) * level_graph.border_stride);
    const rows_before = level_graph.border_count.ptr;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, level_graph.ensureFreeRecords(failing.allocator(), record_need, &pool_grows));
    const records = level_graph.records.slice();
    try std.testing.expect(records.items(.border_count).ptr != rows_before);
    try std.testing.expectEqual(records.items(.border_count).ptr, level_graph.border_count.ptr);
    try std.testing.expectEqual(records.items(.link_slot).ptr, level_graph.record_link_slot.ptr);
    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    // Past both the pool's and the free list's capacity, so both must grow.
    const slots_needed = 2 * @max(level_graph.link_slots.capacity, level_graph.link_free.capacity);
    try std.testing.expectError(error.OutOfMemory, level_graph.ensureFreeLinkSlots(failing.allocator(), slots_needed, &pool_grows));
    const slots = level_graph.link_slots.slice();
    try std.testing.expectEqual(slots.items(.extra).ptr, level_graph.slot_extra.ptr);
    try std.testing.expectEqual(slots.items(.links).ptr, level_graph.slot_links.ptr);

    // The retries grow both pools; the claimed record kept its fields.
    try level_graph.ensureFreeRecords(std.testing.allocator, level_graph.records.capacity + 1, &pool_grows);
    try level_graph.ensureFreeLinkSlots(std.testing.allocator, slots_needed, &pool_grows);
    try std.testing.expectEqual(@as(u8, 3), level_graph.border_count[first]);
    try std.testing.expect(level_graph.record_link_slot[first] != no_link_slot);
    const second = level_graph.claimRecord(1);
    level_graph.claimLinkSlot(second);
    try std.testing.expect(level_graph.record_link_slot[second] != level_graph.record_link_slot[first]);
}

// A dense one-step edit over cells 2..9 of both levels (every chunk): `tile` on each
// level's obstacle layer, grouped per (level, chunk) in order.
const DenseRegionEdit = struct {
    writes: [128]DenseCellWrite = undefined,
    chunks: [18]DenseChunkWrites = undefined,

    fn build(self: *DenseRegionEdit, fixture: *const TwoLevelWorld, tile: TileId) []const DenseChunkWrites {
        var write_count: usize = 0;
        var chunk_count: usize = 0;
        for (0..2) |level| for (0..3) |chunk_y| for (0..3) |chunk_x| {
            const first = write_count;
            for (chunk_y * 4..chunk_y * 4 + 4) |y| for (chunk_x * 4..chunk_x * 4 + 4) |x| {
                if (x < 2 or x > 9 or y < 2 or y > 9) continue;
                self.writes[write_count] = .{ .layer = @intCast(fixture.obstacle[level]), .x = @intCast(x), .y = @intCast(y), .tile = tile };
                write_count += 1;
            };
            self.chunks[chunk_count] = .{ .level = @intCast(level), .chunk_x = @intCast(chunk_x), .chunk_y = @intCast(chunk_y), .writes = self.writes[first..write_count] };
            chunk_count += 1;
        };
        return self.chunks[0..chunk_count];
    }
};

// A dense terrain writer's step: its nav record reserve, the world write, the step's
// published tile events, then the record.
fn denseWriterStep(system: *PathfindingSystem, world: *WorldSystem, frame: *SimulationFrame, chunks: []const DenseChunkWrites, events: *std.ArrayList(WorldTileChangedEvent)) !void {
    var write_count: usize = 0;
    for (chunks) |chunk| write_count += chunk.writes.len;
    try system.reserveTerrainNavRecord(write_count);
    events.clearRetainingCapacity();
    try events.ensureTotalCapacity(std.testing.allocator, write_count);
    try world.applyDenseCellWrites(chunks, null, events);
    frame.beginStep();
    try frame.events.ensureEventAppendCapacity(events.items.len);
    frame.publishWorldTileChangesAssumeCapacity(events.items);
    system.recordTerrainNavEvents(frame.events.mergedItems(), world, null);
}

test "a nav-record reserve OOM before a cave-in or explosion dense write leaves world and nav intact and the retry applies it" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    for ([_]enum { cave_in, explosion_fill }{ .cave_in, .explosion_fill }) |workload| {
        var fixture = try twoLevelWorld(&meta);
        defer fixture.world.deinit();
        var system = try fullRebuild(&data, &fixture.world, abstractCapacity());
        defer system.deinit();
        var frame = SimulationFrame.init(std.testing.allocator);
        defer frame.deinit();
        var events: std.ArrayList(WorldTileChangedEvent) = .empty;
        defer events.deinit(std.testing.allocator);
        var edit = DenseRegionEdit{};
        // A cave-in fills the region; an explosion clears a filled one.
        if (workload == .explosion_fill) {
            try denseWriterStep(&system, &fixture.world, &frame, edit.build(&fixture, fixture.tree), &events);
            _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
            system.nav_marks.shrinkAndFree(system.allocator, 0);
        }
        const tile = if (workload == .cave_in) fixture.tree else fixture.grass;
        const chunks = edit.build(&fixture, tile);
        const before_tile = fixture.world.denseTile(fixture.obstacle[1], 5, 5);
        // The record needs more room than the marks hold, and the reserve runs out of memory.
        try std.testing.expect(system.nav_marks.capacity < 128);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        system.allocator = failing.allocator();
        const failed = denseWriterStep(&system, &fixture.world, &frame, chunks, &events);
        system.allocator = std.testing.allocator;
        try std.testing.expectError(error.OutOfMemory, failed);
        try std.testing.expectEqual(before_tile, fixture.world.denseTile(fixture.obstacle[1], 5, 5));
        try std.testing.expectEqual(@as(usize, 0), system.nav_marks.items.len);
        var unchanged = try fullRebuild(&data, &fixture.world, abstractCapacity());
        defer unchanged.deinit();
        try expectGraphsEquivalent(&system.graph, &unchanged.graph);

        // The retried writer writes, records, and the apply equals a full rebuild.
        try denseWriterStep(&system, &fixture.world, &frame, chunks, &events);
        try std.testing.expect(fixture.world.denseTile(fixture.obstacle[1], 5, 5) != before_tile);
        const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
        try std.testing.expectEqual(@as(usize, 18), stats.dirty_chunks);
        var rebuilt = try fullRebuild(&data, &fixture.world, abstractCapacity());
        defer rebuilt.deinit();
        try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
    }
}

test "one chunk's change leaves every other chunk's record, connectivity nodes, and one-way terminals and rows untouched" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try twoLevelWorld(&meta);
    defer fixture.world.deinit();
    // A one-way link between corner chunks the change never patches.
    try fixture.world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 1, .y = 1 }, .level_b = 1, .cell_b = .{ .x = 10, .y = 10 }, .traversal_cost = 1, .bidirectional = false });
    var system = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer system.deinit();
    const closure = &system.graph.connectivity.closure;
    try std.testing.expectEqual(@as(usize, 2), test_support.closureTermCount(closure));
    const closure_words_before = try test_support.dupeClosureBlocks(std.testing.allocator, &system.graph);
    defer std.testing.allocator.free(closure_words_before);
    const term_index_before = try std.testing.allocator.dupe(u32, closure.term.index);
    defer std.testing.allocator.free(term_index_before);
    var before = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer before.deinit();
    const record_dir_before = try std.testing.allocator.dupe(u32, system.graph.levelGraph(0).?.record_dir.items);
    defer std.testing.allocator.free(record_dir_before);
    const node_comps_before = try std.testing.allocator.dupe(u32, system.graph.levelGraph(0).?.node_comp);
    defer std.testing.allocator.free(node_comps_before);
    const node_heads_before = try std.testing.allocator.dupe(u32, system.graph.levelGraph(0).?.record_node_head);
    defer std.testing.allocator.free(node_heads_before);

    // (5,5) lies in chunk (1,1) of the 3x3 chunk grid.
    const changed = (try fixture.world.setDenseTile(fixture.obstacle[0], 5, 5, fixture.tree)).?;
    const stats = try test_support.applyTileChange(&system, no_colliders, &fixture.world, changed);
    try std.testing.expectEqual(@as(usize, 5), stats.chunks_patched);
    const closure_words_after = try test_support.dupeClosureBlocks(std.testing.allocator, &system.graph);
    defer std.testing.allocator.free(closure_words_after);
    try std.testing.expectEqualSlices(u32, closure_words_before, closure_words_after);
    // The prepare may grow the terminal pool (the dig shares a root with a terminal); the
    // live terminals keep their indices.
    try std.testing.expectEqualSlices(u32, term_index_before, closure.term.index[0..term_index_before.len]);
    const patched = [_]u32{ 4, 3, 5, 1, 7 };
    const level_graph = system.graph.levelGraph(0).?;
    for (0..system.graph.chunkCount()) |chunk_index| {
        const chunk: u32 = @intCast(chunk_index);
        if (std.mem.indexOfScalar(u32, &patched, chunk) != null) continue;
        try std.testing.expectEqual(record_dir_before[chunk], level_graph.record_dir.items[chunk]);
        const now = system.graph.chunkPortals(0, chunk);
        const old = before.graph.chunkPortals(0, chunk);
        try std.testing.expect(portalsEqual(now.border, old.border) and portalsEqual(now.extra, old.extra));
        // The same node rows on the same comps.
        const record = level_graph.recordOf(chunk) orelse continue;
        try std.testing.expectEqual(node_heads_before[record], level_graph.record_node_head[record]);
        var row = level_graph.record_node_head[record];
        while (row != no_node) : (row = level_graph.node_sibling[row]) {
            try std.testing.expectEqual(node_comps_before[row], level_graph.node_comp[row]);
        }
    }
    try std.testing.expect(levelsEquivalent(&system.graph, &before.graph, 1));
    var after = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer after.deinit();
    try expectGraphsEquivalent(&system.graph, &after.graph);
}

test "a batch touching ten levels applies incrementally and never changes nav_version" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");
    var world = try test_support.abstractTestWorld(&meta, 256, 256);
    defer world.deinit();
    var obstacles: [10]usize = undefined;
    obstacles[0] = try world.addDenseLayer(0, 0, .obstacle, grass);
    for (1..obstacles.len) |level| {
        _ = try world.addLevel(-@as(i32, @intCast(level)) * 16);
        _ = try world.addDenseLayer(@intCast(level), 0, .floor, grass);
        obstacles[level] = try world.addDenseLayer(@intCast(level), 0, .obstacle, grass);
    }
    var system = try fullRebuild(&data, &world, abstractCapacity());
    defer system.deinit();
    const version = system.graph.version;

    var edits: [obstacles.len]test_support.TileEdit = undefined;
    for (obstacles, 0..) |layer, level| {
        const changed = (try world.setDenseTile(layer, 3, @intCast(level % 8), tree)).?;
        edits[level] = .{ .level = changed.level, .x = changed.x, .y = changed.y };
    }
    const stats = try test_support.applyTileEdits(&system, no_colliders, &world, &edits);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), stats.levels_built);
    try std.testing.expectEqual(version, system.graph.version);

    // A level add, a blocking layer, and a link in one update keep it too.
    const added = try world.addLevel(-160);
    _ = try world.addDenseLayer(added, 0, .floor, grass);
    _ = try world.addDenseLayer(2, 0, .obstacle, tree);
    try world.addLevelLink(.{ .kind = .stair, .level_a = 0, .cell_a = .{ .x = 1, .y = 1 }, .level_b = added, .cell_b = .{ .x = 1, .y = 1 }, .traversal_cost = 1, .bidirectional = true });
    const update = try system.applyBufferedNavUpdates(no_colliders, &world, &serial_threads);
    try std.testing.expectEqual(@as(usize, 2), update.levels_built);
    try std.testing.expectEqual(version, system.graph.version);

    var rebuilt = try fullRebuild(&data, &world, abstractCapacity());
    defer rebuilt.deinit();
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

// Nav changes the out-of-memory sweeps apply, each recorded with the real allocator.
const OomEdit = enum { dig, cave_in, ramp, static_add, level_add, blocking_layer, level_and_link, oneway };

// Three open levels in 4-tile chunks with an obstacle band each, a blocked ramp cell, and a
// one-way system: levels 0 to 1 to 2 and back to 0.
fn oomWorld(meta: *const @import("../../../assets/world_tileset_meta.zig").WorldTilesetMeta) !WorldSystem {
    const grass = try requireTestTile(meta, "grass");
    const tree = try requireTestTile(meta, "tree_0");
    var world = try test_support.abstractTestWorld(meta, 384, 384);
    errdefer world.deinit();
    _ = try world.addDenseLayer(0, 0, .obstacle, grass);
    for (1..3) |level| {
        _ = try world.addLevel(-@as(i32, @intCast(level)) * 16);
        _ = try world.addDenseLayer(@intCast(level), 0, .floor, grass);
        _ = try world.addDenseLayer(@intCast(level), 0, .obstacle, grass);
    }
    _ = try world.setDenseTile(oomObstacle(&world, 1), 5, 5, tree);
    // Level 2 is open everywhere, so its end shares one root with the next link's start.
    for ([_][4]u16{ .{ 0, 10, 1, 1 }, .{ 1, 10, 2, 9 }, .{ 2, 8, 0, 1 } }) |end| {
        try world.addLevelLink(.{ .kind = .teleport, .level_a = end[0], .cell_a = .{ .x = end[1], .y = end[1] }, .level_b = end[2], .cell_b = .{ .x = end[3], .y = end[3] }, .traversal_cost = 1, .bidirectional = false });
    }
    return world;
}

fn oomObstacle(world: *const WorldSystem, level: u16) usize {
    // Bands in add order: floor 0, obstacle 0, then floor and obstacle per level.
    _ = world;
    return if (level == 0) 1 else 2 * @as(usize, level) + 1;
}

fn applyOomEdit(edit: OomEdit, system: *PathfindingSystem, data: *DataSystem, colliders: *StaticColliderSystem, world: *WorldSystem, meta: *const @import("../../../assets/world_tileset_meta.zig").WorldTilesetMeta) !void {
    const grass = try requireTestTile(meta, "grass");
    const tree = try requireTestTile(meta, "tree_0");
    switch (edit) {
        .dig => {
            const changed = (try world.setDenseTile(oomObstacle(world, 0), 6, 6, tree)).?;
            try test_support.recordTileChange(system, world, changed);
        },
        .cave_in => for (0..3) |level| {
            for (3..6) |y| for (3..6) |x| {
                const changed = (try world.setDenseTile(oomObstacle(world, @intCast(level)), @intCast(x), @intCast(y), tree)) orelse continue;
                try test_support.recordTileChange(system, world, changed);
            };
        },
        .ramp => {
            const changed = (try world.setDenseTile(oomObstacle(world, 1), 5, 5, grass)).?;
            try test_support.recordTileChange(system, world, changed);
            try world.addLevelLink(.{ .kind = .ramp, .level_a = 1, .cell_a = .{ .x = 5, .y = 5 }, .level_b = 0, .cell_b = .{ .x = 5, .y = 5 }, .traversal_cost = 1, .bidirectional = true });
        },
        .static_add => {
            var frame = SimulationFrame.init(std.testing.allocator);
            defer frame.deinit();
            try test_support.commitWithColliders(&frame, data, colliders, system, &.{.{ .create_entity = staticTemplate(.{ .x = 200, .y = 200 }, .{ .x = 40, .y = 40 }) }});
        },
        .level_add => {
            const level = try world.addLevel(-48);
            _ = try world.addDenseLayer(level, 0, .floor, grass);
        },
        .blocking_layer => _ = try world.addDenseLayer(2, 0, .obstacle, tree),
        .level_and_link => {
            const level = try world.addLevel(-48);
            _ = try world.addDenseLayer(level, 0, .floor, grass);
            try world.addLevelLink(.{ .kind = .stair, .level_a = 0, .cell_a = .{ .x = 2, .y = 2 }, .level_b = level, .cell_b = .{ .x = 9, .y = 9 }, .traversal_cost = 3, .bidirectional = true });
        },
        // A one-way endpoint closed and a new one-way link joining another system.
        .oneway => {
            const changed = (try world.setDenseTile(oomObstacle(world, 1), 10, 10, tree)).?;
            try test_support.recordTileChange(system, world, changed);
            try world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 11, .y = 0 }, .level_b = 1, .cell_b = .{ .x = 0, .y = 11 }, .traversal_cost = 1, .bidirectional = false });
        },
    }
}

// Applies `edit` failing at every allocation in turn. Each failure leaves every level
// wholly as it was or wholly rebuilt (a committed step stays), and the retry with the real
// allocator equals a full rebuild of the edited world.
fn expectNavApplyOutOfMemorySafe(edit: OomEdit, thread_system: *ThreadSystem) !void {
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var capacity = abstractCapacity();
    capacity.worker_participant_count = thread_system.participantSlotCount();
    var fail_index: usize = 0;
    while (fail_index < 4096) : (fail_index += 1) {
        var data = DataSystem.init(std.testing.allocator);
        defer data.deinit();
        var world = try oomWorld(&meta);
        defer world.deinit();
        var system = try fullRebuild(&data, &world, capacity);
        defer system.deinit();
        system.nav_controls = .{ .adaptive = false, .items_per_range = 1 };
        var colliders = try test_support.worldColliders(&data, &world);
        defer colliders.deinit();
        var before = try fullRebuild(&data, &world, capacity);
        defer before.deinit();
        try applyOomEdit(edit, &system, &data, &colliders, &world, &meta);
        var after = try fullRebuild(&data, &world, capacity);
        defer after.deinit();

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = fail_index });
        system.allocator = failing.allocator();
        system.graph.allocator = failing.allocator();
        const result = system.applyBufferedNavUpdates(&colliders, &world, thread_system);
        system.allocator = std.testing.allocator;
        system.graph.allocator = std.testing.allocator;
        if (result) |_| {
            try expectGraphsEquivalent(&system.graph, &after.graph);
            if (!failing.has_induced_failure) return;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            // Links fold only in the infallible commit.
            try std.testing.expect(std.meta.eql(system.graph.link_bounds, before.graph.link_bounds));
            // A level an edit appended holds no crossing until a commit folds one.
            const kept_levels = @min(system.graph.level_crossings.items.len, before.graph.level_crossings.items.len);
            for (system.graph.level_crossings.items[0..kept_levels], before.graph.level_crossings.items[0..kept_levels]) |crossings, untouched| try std.testing.expect(std.meta.eql(crossings, untouched));
            for (system.graph.level_crossings.items[kept_levels..]) |crossings| try std.testing.expect(std.meta.eql(crossings, LevelCrossings{}));
            for (0..system.graph.levelCount()) |level| {
                try std.testing.expect(levelsEquivalent(&system.graph, &before.graph, @intCast(level)) or
                    levelsEquivalent(&system.graph, &after.graph, @intCast(level)));
            }
            try std.testing.expect(system.hasPendingNavUpdates(&world));
            _ = try system.applyBufferedNavUpdates(&colliders, &world, thread_system);
            try expectGraphsEquivalent(&system.graph, &after.graph);
        }
    }
    return error.TestUnexpectedResult;
}

test "nav apply runs out of memory at every allocation, leaves each level intact, and the retry equals a full rebuild" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    for (std.meta.tags(OomEdit)) |edit| try expectNavApplyOutOfMemorySafe(edit, &serial_threads);
}

test "threaded nav apply runs out of memory at every allocation on a multi-worker ThreadSystem and the retry equals a full rebuild" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    for (std.meta.tags(OomEdit)) |edit| try expectNavApplyOutOfMemorySafe(edit, &threads);
}

test "a runtime ramp is routable from both levels the same step, at an interior and a perimeter endpoint" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    // (5,5) is interior to its 4-tile chunk; (4,4) sits on the chunk's corner.
    for ([_][2]u16{ .{ 5, 5 }, .{ 4, 4 } }) |cell| {
        var data = DataSystem.init(std.testing.allocator);
        defer data.deinit();
        var fixture = try twoLevelWorld(&meta);
        defer fixture.world.deinit();
        var system = try fullRebuild(&data, &fixture.world, abstractCapacity());
        defer system.deinit();
        // No link yet: the levels do not connect.
        try std.testing.expect(!try routes(&system, &data, &fixture.world, 1, .{ 1, 1 }, 0, .{ 10, 10 }));

        try fixture.world.addLevelLink(.{ .kind = .ramp, .level_a = 1, .cell_a = .{ .x = cell[0], .y = cell[1] }, .level_b = 0, .cell_b = .{ .x = cell[0], .y = cell[1] }, .traversal_cost = 1, .bidirectional = true });
        const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
        try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
        try std.testing.expect(isPortal(&system.graph, 1, @as(usize, cell[1]) * system.graph.geometry.width + cell[0]));
        try std.testing.expect(try routes(&system, &data, &fixture.world, 1, .{ 1, 1 }, 0, .{ 10, 10 }));
        try std.testing.expect(try routes(&system, &data, &fixture.world, 0, .{ 10, 10 }, 1, .{ 1, 1 }));
        var rebuilt = try fullRebuild(&data, &fixture.world, abstractCapacity());
        defer rebuilt.deinit();
        try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
    }
}

test "a ramp into a blocked partner goes live when the partner opens, in that step's apply" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try twoLevelWorld(&meta);
    defer fixture.world.deinit();
    _ = try fixture.world.setDenseTile(fixture.obstacle[0], 6, 6, fixture.tree);
    try fixture.world.addLevelLink(.{ .kind = .ramp, .level_a = 1, .cell_a = .{ .x = 5, .y = 5 }, .level_b = 0, .cell_b = .{ .x = 6, .y = 6 }, .traversal_cost = 1, .bidirectional = true });
    var system = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer system.deinit();
    try std.testing.expect(!try routes(&system, &data, &fixture.world, 1, .{ 1, 1 }, 0, .{ 10, 10 }));

    const opened = (try fixture.world.setDenseTile(fixture.obstacle[0], 6, 6, fixture.grass)).?;
    _ = try test_support.applyTileChange(&system, no_colliders, &fixture.world, opened);
    try std.testing.expect(try routes(&system, &data, &fixture.world, 1, .{ 1, 1 }, 0, .{ 10, 10 }));
}

test "adding a blocking dense layer to a built level re-derives that level's nav" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try twoLevelWorld(&meta);
    defer fixture.world.deinit();
    var system = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer system.deinit();
    try std.testing.expect(system.graph.levelGraph(1).?.recordCount() > 0);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();

    // No event reports the fill: only the level's content revision moves.
    _ = try fixture.world.addDenseLayer(1, 0, .obstacle, fixture.tree);
    try std.testing.expect(system.navReactionMayEmit(&data, &frame, &fixture.world));
    const stats = try system.reactToPostCommitNavEvents(&frame, no_colliders, &fixture.world, &serial_threads);
    try std.testing.expectEqual(@as(usize, 1), stats.levels_built);
    try std.testing.expectEqual(@as(usize, 1), frame.events.stats.nav_region_invalidated);
    try std.testing.expect(!system.navReactionMayEmit(&data, &frame, &fixture.world));
    try std.testing.expectEqual(@as(usize, 0), system.graph.levelGraph(1).?.recordCount());
    var rebuilt = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer rebuilt.deinit();
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "a level added in play builds only its own chunks and leaves other levels and cached paths untouched" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try twoLevelWorld(&meta);
    defer fixture.world.deinit();
    var system = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer system.deinit();
    var before = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer before.deinit();
    const goal = math.Vec2{ .x = 10.5 * fixture.world.tile_size, .y = 10.5 * fixture.world.tile_size };
    const start = math.Vec2{ .x = 1.5 * fixture.world.tile_size, .y = 1.5 * fixture.world.tile_size };
    try std.testing.expect(try routes(&system, &data, &fixture.world, 0, .{ 1, 1 }, 0, .{ 10, 10 }));
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, start, 0, goal, .default, null).status);

    const level = try fixture.world.addLevel(-32);
    _ = try fixture.world.addDenseLayer(level, 0, .floor, fixture.grass);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try std.testing.expectEqual(@as(usize, 1), stats.levels_built);
    try std.testing.expectEqual(@as(usize, 0), stats.chunks_patched);
    try std.testing.expectEqual(@as(usize, 3), system.graph.levelCount());
    try std.testing.expect(levelsEquivalent(&system.graph, &before.graph, 0));
    try std.testing.expect(levelsEquivalent(&system.graph, &before.graph, 1));
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, start, 0, goal, .default, null).status);
    try std.testing.expect(try routes(&system, &data, &fixture.world, level, .{ 1, 1 }, level, .{ 10, 10 }));
}

test "a world build that runs out of memory leaves the previous graph intact; a replaced world releases its storage" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var first = try twoLevelWorld(&meta);
    defer first.world.deinit();
    var second = try oomWorld(&meta);
    defer second.deinit();
    var system = try fullRebuild(&data, &first.world, abstractCapacity());
    defer system.deinit();
    var reference = try fullRebuild(&data, &first.world, abstractCapacity());
    defer reference.deinit();

    var version = system.graph.version;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = fail_index });
        system.graph.allocator = failing.allocator();
        const result = system.graph.rebuild(no_colliders.view(), .{ .world = &second }, null);
        system.graph.allocator = std.testing.allocator;
        if (result) |_| {
            if (!failing.has_induced_failure) break;
            // Only a connectivity staging shrink absorbs a failure, keeping its larger buffer:
            // the build completed. Check it, then restore the first world for the next index.
            var fresh = try fullRebuild(&data, &second, abstractCapacity());
            defer fresh.deinit();
            try expectGraphsEquivalent(&system.graph, &fresh.graph);
            _ = try system.graph.rebuild(no_colliders.view(), .{ .world = &first.world }, null);
            try expectGraphsEquivalent(&system.graph, &reference.graph);
            version = system.graph.version;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(version, system.graph.version);
            try expectGraphsEquivalent(&system.graph, &reference.graph);
        }
    }
    // The replaced graph freed everything (the testing allocator checks for leaks), and the
    // new one holds exactly what a fresh build of the second world holds.
    var fresh = try fullRebuild(&data, &second, abstractCapacity());
    defer fresh.deinit();
    try expectGraphsEquivalent(&system.graph, &fresh.graph);
    try std.testing.expectEqual(fresh.graph.residentBytes(), system.graph.residentBytes());
}

test "a world build's growth log stays logged through the swap and a later rebuild, so the next change never logs it again" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try twoLevelWorld(&meta);
    defer fixture.world.deinit();
    var system = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer system.deinit();
    try std.testing.expect(system.graph.pool_grows != 0);
    try std.testing.expect(system.graph.pool_growth_logged);

    _ = try system.graph.rebuild(no_colliders.view(), .{ .world = &fixture.world }, null);
    try std.testing.expect(system.graph.pool_growth_logged);
}

test "nav over a zero-level world builds no level; the first added level routes" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 12,
        .height = 12,
        .tile_size = meta.tileSize(),
        .chunk_size_tiles = 4,
    };
    defer world.deinit();
    try world.buildCatalog(&meta);
    var system = try fullRebuild(&data, &world, abstractCapacity());
    defer system.deinit();
    try std.testing.expectEqual(@as(usize, 0), system.graph.levelCount());
    try std.testing.expect(!system.graph.valid());

    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(0, 0, .floor, grass);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &world, &serial_threads);
    try std.testing.expectEqual(@as(usize, 1), stats.levels_built);
    try std.testing.expect(try routes(&system, &data, &world, 0, .{ 1, 1 }, 0, .{ 10, 10 }));
}

test "the nav reaction runs when only the world gained a level, a link, or a content revision" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try twoLevelWorld(&meta);
    defer fixture.world.deinit();
    var system = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer system.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try std.testing.expect(!system.navReactionMayEmit(&data, &frame, &fixture.world));

    const Change = enum { level, link, revision };
    for (std.meta.tags(Change)) |change| {
        switch (change) {
            .level => _ = try fixture.world.addLevel(-32),
            .link => try fixture.world.addLevelLink(.{ .kind = .stair, .level_a = 0, .cell_a = .{ .x = 1, .y = 1 }, .level_b = 1, .cell_b = .{ .x = 2, .y = 2 }, .traversal_cost = 1, .bidirectional = true }),
            .revision => _ = try fixture.world.addDenseLayer(2, 0, .obstacle, fixture.tree),
        }
        frame.beginStep();
        try std.testing.expect(system.navReactionMayEmit(&data, &frame, &fixture.world));
        const stats = try system.reactToPostCommitNavEvents(&frame, no_colliders, &fixture.world, &serial_threads);
        try std.testing.expect(stats.levels_built + stats.incremental_rebuilds == 1);
        try std.testing.expectEqual(@as(usize, 1), frame.events.stats.nav_region_invalidated);
        try std.testing.expect(!system.navReactionMayEmit(&data, &frame, &fixture.world));
    }
    var rebuilt = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer rebuilt.deinit();
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "a patch reads only its chunk's link endpoints" {
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var fixture = try twoLevelWorld(&meta);
    defer fixture.world.deinit();
    try fixture.world.addLevelLink(.{ .kind = .ramp, .level_a = 1, .cell_a = .{ .x = 5, .y = 5 }, .level_b = 0, .cell_b = .{ .x = 5, .y = 5 }, .traversal_cost = 1, .bidirectional = true });
    // 1000 links in the same chunk id, (1,1), but between level-0 cells only: a patch of
    // level 1's chunk (1,1) that read endpoints by chunk id alone would see them.
    for (0..1000) |_| {
        try fixture.world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 6, .y = 6 }, .level_b = 0, .cell_b = .{ .x = 6, .y = 7 }, .traversal_cost = 1, .bidirectional = false });
    }
    var system = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer system.deinit();
    const changed = (try fixture.world.setDenseTile(fixture.obstacle[1], 6, 5, fixture.tree)).?;
    _ = try test_support.applyTileChange(&system, no_colliders, &fixture.world, changed);

    // The patched record holds exactly its level-local link: the batch planned one endpoint,
    // and the patch asserts its appends stay within the planned count.
    const chunk = system.graph.geometry.chunkOfCell(5 * system.graph.geometry.width + 5);
    const portals = system.graph.chunkPortals(1, chunk);
    try std.testing.expectEqual(@as(usize, 1), portals.links.len);
    try std.testing.expectEqual(@as(u16, 0), portals.links[0].to_level);
    var planned: u64 = 0;
    for (system.graph.patch_info.items) |info| planned += info.endpoints;
    try std.testing.expectEqual(@as(u64, 1), planned);
    const level_graph = system.graph.levelGraph(1).?;
    const slot = level_graph.record_link_slot[level_graph.record_dir.items[chunk]];
    try std.testing.expect(level_graph.slot_links[slot].capacity >= planned);
    var rebuilt = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer rebuilt.deinit();
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "a chunk gaining a link per batch grows its link slot geometrically, each growth counted" {
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var fixture = try twoLevelWorld(&meta);
    defer fixture.world.deinit();
    var system = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer system.deinit();
    const chunk = system.graph.geometry.chunkOfCell(6 * system.graph.geometry.width + 6);
    var capacity: usize = 0;
    var growths: u64 = 0;
    const batches = 32;
    for (0..batches) |_| {
        try fixture.world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 6, .y = 6 }, .level_b = 0, .cell_b = .{ .x = 6, .y = 7 }, .traversal_cost = 1, .bidirectional = false });
        const pool_grows = system.graph.pool_grows;
        _ = try test_support.applyTileEdits(&system, no_colliders, &fixture.world, &.{});
        const level_graph = system.graph.levelGraph(0).?;
        const slot = level_graph.record_link_slot[level_graph.record_dir.items[chunk]];
        if (level_graph.slot_links[slot].capacity != capacity) {
            capacity = level_graph.slot_links[slot].capacity;
            growths += 1;
            try std.testing.expect(system.graph.pool_grows > pool_grows);
        }
    }
    const portals = system.graph.chunkPortals(0, chunk);
    try std.testing.expectEqual(@as(usize, batches), portals.links.len);
    // 32 links over two cells keep one extra portal per distinct non-border cell.
    try std.testing.expect(portals.extra.len >= 1 and portals.extra.len <= 2);
    if (portals.extra.len == 2) try std.testing.expect(portals.extra[0].local != portals.extra[1].local);
    // Geometric: a handful of growths for 32 links (one per link if grown exactly).
    try std.testing.expect(growths <= 8);
    var rebuilt = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer rebuilt.deinit();
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "an aborted prepared batch leaves the graph and its pending work unchanged, and the retry equals a full rebuild" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try twoLevelWorld(&meta);
    defer fixture.world.deinit();
    var system = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer system.deinit();
    var before = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer before.deinit();

    const changed = (try fixture.world.setDenseTile(fixture.obstacle[1], 5, 5, fixture.tree)).?;
    try test_support.recordTileChange(&system, &fixture.world, changed);
    try fixture.world.addLevelLink(.{ .kind = .ramp, .level_a = 1, .cell_a = .{ .x = 9, .y = 9 }, .level_b = 0, .cell_b = .{ .x = 9, .y = 9 }, .traversal_cost = 1, .bidirectional = true });
    const links_applied = system.graph.links_applied;
    var stats = NavUpdateStats{};
    const prepared = (try system.graph.prepareMarks(&fixture.world, no_colliders.view(), system.nav_marks.items, null, &stats)).?;
    system.graph.abortMarks(prepared);
    try std.testing.expectEqual(links_applied, system.graph.links_applied);
    try expectGraphsEquivalent(&system.graph, &before.graph);
    try std.testing.expect(system.hasPendingNavUpdates(&fixture.world));

    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try std.testing.expectEqual(fixture.world.levelLinks().len, system.graph.links_applied);
    var after = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer after.deinit();
    try expectGraphsEquivalent(&system.graph, &after.graph);
}

// Prepares and commits `system`'s pending marks directly, and checks each changed key's mask
// against its chunk's bits read before and after the commit. Returns the keys whose mask
// is not empty.
fn expectChangedMasksAreFlips(system: *PathfindingSystem, world: *const WorldSystem) !usize {
    var stats = NavUpdateStats{};
    const prepared = (try system.graph.prepareMarks(world, no_colliders.view(), system.nav_marks.items, null, &stats)).?;
    var old: [32]ChunkBits = undefined;
    const keys = system.graph.changed_keys.items;
    try std.testing.expect(keys.len <= old.len);
    for (keys, old[0..keys.len]) |key, *bits| bits.* = system.graph.grid(keyLevel(key)).?.chunkBlockedBits(keyChunk(key));
    const batch = system.graph.commitMarks(prepared, no_colliders.view(), null, &stats);
    system.nav_marks.clearRetainingCapacity();
    try std.testing.expect(batch.changed);
    try std.testing.expectEqualSlices(u64, keys, batch.changed_keys);
    var flipped: usize = 0;
    for (batch.changed_keys, batch.changed_masks, old[0..keys.len]) |key, mask, before| {
        const after = system.graph.grid(keyLevel(key)).?.chunkBlockedBits(keyChunk(key));
        for (mask, before, after) |word, old_word, new_word| try std.testing.expectEqual(old_word ^ new_word, word);
        if (!std.mem.allEqual(u64, &mask, 0)) flipped += 1;
    }
    return flipped;
}

test "the remask changed mask equals old XOR new bits per changed key across open, blocked, and mixed forms" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try twoLevelWorld(&meta);
    defer fixture.world.deinit();
    var system = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer system.deinit();
    // Level 0 chunk (0, 0) open -> blocked; level 1 chunk (1, 1) open -> mixed; a mark on
    // level 1 chunk (2, 2) whose cell keeps its tile changes nothing.
    for (0..4) |y| for (0..4) |x| {
        const changed = (try fixture.world.setDenseTile(fixture.obstacle[0], @intCast(x), @intCast(y), fixture.tree)).?;
        try test_support.recordTileChange(&system, &fixture.world, changed);
    };
    const mixed = (try fixture.world.setDenseTile(fixture.obstacle[1], 5, 5, fixture.tree)).?;
    try test_support.recordTileChange(&system, &fixture.world, mixed);
    try test_support.recordTileEdits(&system, &fixture.world, &.{.{ .level = 1, .x = 9, .y = 9 }});
    try std.testing.expectEqual(@as(usize, 2), try expectChangedMasksAreFlips(&system, &fixture.world));
    try std.testing.expect(test_support.navChunkForm(system.graph.grid(0).?, 0) == .blocked);

    // Level 0 chunk (0, 0) blocked -> mixed; level 1 chunk (1, 1) mixed -> blocked.
    const opened = (try fixture.world.setDenseTile(fixture.obstacle[0], 1, 1, fixture.grass)).?;
    try test_support.recordTileChange(&system, &fixture.world, opened);
    for (4..8) |y| for (4..8) |x| {
        if (x == 5 and y == 5) continue;
        const changed = (try fixture.world.setDenseTile(fixture.obstacle[1], @intCast(x), @intCast(y), fixture.tree)).?;
        try test_support.recordTileChange(&system, &fixture.world, changed);
    };
    try std.testing.expectEqual(@as(usize, 2), try expectChangedMasksAreFlips(&system, &fixture.world));
    try std.testing.expect(test_support.navChunkForm(system.graph.grid(0).?, 0) == .mixed);
    try std.testing.expect(test_support.navChunkForm(system.graph.grid(1).?, 4) == .blocked);
}

test "a world build folds its authored links into the link bounds" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try twoLevelWorld(&meta);
    defer fixture.world.deinit();
    _ = try fixture.world.addLevel(-32);
    _ = try fixture.world.addDenseLayer(2, 0, .floor, fixture.grass);
    // A ramp (cost 41, span 0), a two-level stair (cost 43, span 14), a bidirectional long
    // teleport (cost 41, span 154), a one-way long teleport (cost 42, span 154), and a
    // same-level short link (cost 40, span 14).
    try fixture.world.addLevelLink(.{ .kind = .ramp, .level_a = 1, .cell_a = .{ .x = 5, .y = 5 }, .level_b = 0, .cell_b = .{ .x = 5, .y = 5 }, .traversal_cost = 1, .bidirectional = true });
    try fixture.world.addLevelLink(.{ .kind = .stair, .level_a = 0, .cell_a = .{ .x = 2, .y = 2 }, .level_b = 2, .cell_b = .{ .x = 3, .y = 3 }, .traversal_cost = 3, .bidirectional = false });
    try fixture.world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 0, .y = 0 }, .level_b = 1, .cell_b = .{ .x = 11, .y = 11 }, .traversal_cost = 1, .bidirectional = true });
    try fixture.world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 11, .y = 0 }, .level_b = 2, .cell_b = .{ .x = 0, .y = 11 }, .traversal_cost = 2, .bidirectional = false });
    try fixture.world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 8, .y = 8 }, .level_b = 0, .cell_b = .{ .x = 9, .y = 9 }, .traversal_cost = 0, .bidirectional = true });
    var system = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer system.deinit();
    const bounds = &system.graph.link_bounds;
    try std.testing.expectEqual(@as(u16, 2), bounds.short_span);
    try std.testing.expectEqual(@as(u32, 41), bounds.short_cost);
    try std.testing.expectEqual(@as(u32, 43 - 14), bounds.short_excess);
    try std.testing.expectEqual(@as(u32, 41), bounds.long_cost);
    // A link pairs side a with side b, and a bidirectional one also side b with side a; short
    // links fold no pair.
    const pairs = &bounds.pairs;
    try std.testing.expectEqual(@as(u32, 3), pairs.count);
    try expectLinkPair(pairs, 0, .{ 0, 0, 0 }, .{ 11, 11, 1 }, 41);
    try expectLinkPair(pairs, 1, .{ 11, 11, 1 }, .{ 0, 0, 0 }, 41);
    try expectLinkPair(pairs, 2, .{ 11, 0, 0 }, .{ 0, 11, 2 }, 42);
    for (3..long_link_pairs) |pad| try expectLinkPair(pairs, pad, .{ 0, 0, 0 }, .{ 11, 11, 1 }, 41);
    // The teleport's two directions chain into each other at its cost.
    try std.testing.expectEqual(@as(i32, 41), bounds.chains.to[1][0]);
    try std.testing.expectEqual(@as(i32, 41), bounds.chains.to[0][1]);
    try std.testing.expectEqual(@as(i32, 0), bounds.chains.to[2][2]);
    // Folding the same links again changes nothing.
    var refolded = bounds.*;
    refolded.foldLinks(fixture.world.levelLinks());
    try std.testing.expect(std.meta.eql(bounds.*, refolded));
    // The folded cost is the edge cost the ramp's record holds.
    const ramp_cell = 5 * system.graph.geometry.width + 5;
    const ramp_links = system.graph.chunkPortals(1, system.graph.geometry.chunkOfCell(ramp_cell)).linksAt(test_support.localOfCell(system.graph.geometry, ramp_cell));
    try std.testing.expectEqual(bounds.short_cost, ramp_links[0].cost);
}

test "border portals never exceed 4 * ceil(E / 2) and random digs match a full rebuild" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");
    var prng = std.Random.DefaultPrng.init(0x64a4);
    const random = prng.random();
    for ([_]u16{ 1, 2, 4, 8, 16 }) |edge| {
        var data = DataSystem.init(std.testing.allocator);
        defer data.deinit();
        const side: f32 = @as(f32, @floatFromInt(@as(u32, edge) * 3)) * meta.tileSize();
        var world = try WorldSystem.initDemoFromMetaWithChunkSize(std.testing.allocator, &meta, side, side, edge);
        defer world.deinit();
        const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);
        for (0..world.height) |y| for (0..world.width) |x| {
            if (random.boolean()) _ = try world.setDenseTile(obstacle, @intCast(x), @intCast(y), tree);
        };
        var capacity = abstractCapacity();
        capacity.nav_chunk_tiles = edge;
        var system = try fullRebuild(&data, &world, capacity);
        defer system.deinit();
        for (0..8) |_| {
            const x: u16 = random.uintLessThan(u16, world.width);
            const y: u16 = random.uintLessThan(u16, world.height);
            const changed = (try world.setDenseTile(obstacle, x, y, if (random.boolean()) tree else grass)) orelse continue;
            try test_support.recordTileChange(&system, &world, changed);
        }
        _ = try system.applyBufferedNavUpdates(no_colliders, &world, &serial_threads);
        const bound = 4 * @divCeil(@as(usize, edge), 2);
        // Each record's border window is sized from the level's own chunk edge.
        try std.testing.expectEqual(bound, system.graph.levelGraph(0).?.border_stride);
        for (0..system.graph.chunkCount()) |chunk| {
            try std.testing.expect(system.graph.chunkPortals(0, @intCast(chunk)).border.len <= bound);
        }
        var rebuilt = try fullRebuild(&data, &world, capacity);
        defer rebuilt.deinit();
        try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
    }
}

test "an all-solid level holds no records; an open level one per chunk" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");
    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(-16);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    _ = try world.addLevel(-32);
    _ = try world.addDenseLayer(2, 0, .floor, grass);
    _ = try world.addDenseLayer(2, 0, .obstacle, tree);
    var system = try fullRebuild(&data, &world, abstractCapacity());
    defer system.deinit();
    try std.testing.expectEqual(system.graph.chunkCount(), system.graph.levelGraph(1).?.recordCount());
    try std.testing.expectEqual(@as(usize, 0), system.graph.levelGraph(2).?.recordCount());
    try std.testing.expectEqual(@as(usize, 0), system.graph.levelGraph(2).?.records.len);
}

test "the threaded key plan equals the inline plan for marks across many chunks and levels" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try twoLevelWorld(&meta);
    defer fixture.world.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var capacity = abstractCapacity();
    capacity.worker_participant_count = threads.participantSlotCount();
    // The inline plan, then three fixed partitions; all built before the edits.
    const partitions = [_]?usize{ null, 1, 3, 7 };
    var systems: [partitions.len]PathfindingSystem = undefined;
    var built: usize = 0;
    defer for (systems[0..built]) |*system| system.deinit();
    for (partitions) |items_per_range| {
        systems[built] = try fullRebuild(&data, &fixture.world, capacity);
        systems[built].nav_controls = .{ .adaptive = false, .items_per_range = items_per_range };
        built += 1;
    }

    try fixture.world.addLevelLink(.{ .kind = .ramp, .level_a = 1, .cell_a = .{ .x = 9, .y = 2 }, .level_b = 0, .cell_b = .{ .x = 9, .y = 2 }, .traversal_cost = 1, .bidirectional = true });
    // Overlapping marks on both levels, in an order that spreads repeats across ranges.
    for (0..40) |cell| {
        const level: u16 = @intCast(cell % 2);
        const x: u16 = @intCast((cell * 7) % 12);
        const y: u16 = @intCast((cell * 5) % 12);
        const changed = (try fixture.world.setDenseTile(fixture.obstacle[level], x, y, fixture.tree)) orelse continue;
        for (&systems) |*system| try test_support.recordTileChange(system, &fixture.world, changed);
    }
    const obstacle_rect = SimulationEvent{ .stage = .structural_commit, .payload = .{ .world_obstacle_changed = .{ .level = 0, .min_x = 2, .min_y = 2, .max_x_exclusive = 11, .max_y_exclusive = 5 } } };
    for (&systems) |*system| try test_support.recordTerrainEvents(system, &.{obstacle_rect}, &fixture.world);
    _ = try systems[0].applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try std.testing.expectEqual(@as(usize, 1), systems[0].graph.plan_tallies.items.len);
    // The dirty keys are the union of the changed keys and the new link's endpoint chunks.
    {
        const graph = &systems[0].graph;
        var union_keys: std.ArrayList(u64) = .empty;
        defer union_keys.deinit(std.testing.allocator);
        try union_keys.appendSlice(std.testing.allocator, graph.changed_keys.items);
        const ramp_chunk = graph.geometry.chunkOfCell(2 * graph.geometry.width + 9);
        try union_keys.append(std.testing.allocator, chunkKey(1, ramp_chunk));
        try union_keys.append(std.testing.allocator, chunkKey(0, ramp_chunk));
        union_keys.items.len = sortUnique(union_keys.items);
        try std.testing.expectEqualSlices(u64, union_keys.items, graph.dirty_keys.items);
    }
    for (systems[1..]) |*system| {
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
        // Merged from several ranges that ran on workers.
        try std.testing.expect(system.graph.plan_tallies.items.len > 1);
        try std.testing.expect(system.graph.plan_levels.isEmpty());
        try std.testing.expectEqualSlices(u64, systems[0].graph.changed_keys.items, system.graph.changed_keys.items);
        try std.testing.expectEqualSlices(u64, systems[0].graph.patch_keys.items, system.graph.patch_keys.items);
        try std.testing.expectEqualSlices(u64, systems[0].graph.dirty_keys.items, system.graph.dirty_keys.items);
        try expectGraphsEquivalent(&systems[0].graph, &system.graph);
    }
}

test "the threaded plan merge equals the sorted unique keys of every stream for any partition of range windows" {
    const allocator = std.testing.allocator;
    // 72x72 chunks per level (three tiers) on 65 levels (two tiers): keys at each chunk word
    // and tier edge, and on both sides of the level set's first word.
    var graph = NavGraph{ .allocator = allocator, .geometry = .init(288, 288, 4) };
    defer graph.deinit();
    const level_count = 65;
    const chunk_count = graph.chunkCount();
    try std.testing.expectEqual(@as(usize, 5184), chunk_count);
    _ = try graph.plan_levels.reserve(allocator, level_count);
    try graph.level_graphs.ensureTotalCapacity(allocator, level_count);
    for (0..level_count) |_| {
        var level_graph = NavLevelGraph{};
        level_graph.plan = try .init(allocator, chunk_count);
        graph.level_graphs.appendAssumeCapacity(level_graph);
    }
    try std.testing.expectEqual(@as(usize, 3), graph.level_graphs.items[0].plan.order.tier_count);
    const edge_keys = [_]u64{ chunkKey(64, 5183), chunkKey(0, 63), chunkKey(63, 64), chunkKey(64, 4095), chunkKey(1, 4096), chunkKey(63, 0) };

    var range_keys: [plan_streams]std.ArrayList(u64) = @splat(.empty);
    defer for (&range_keys) |*list| list.deinit(allocator);
    var expected: [plan_streams]std.ArrayList(u64) = @splat(.empty);
    defer for (&expected) |*list| list.deinit(allocator);
    for ([_]usize{ 2, 3, 7, 16 }) |range_count| {
        var prng = std.Random.DefaultPrng.init(range_count);
        const random = prng.random();
        for (&expected) |*list| list.clearRetainingCapacity();
        for (&graph.plan_staging) |*list| list.clearRetainingCapacity();
        try graph.plan_windows.resize(allocator, range_count);
        try graph.plan_tallies.resize(allocator, range_count);
        for (graph.plan_windows.items, graph.plan_tallies.items, 0..) |*window, *tally, range_index| {
            // Changed keys, link keys (some also changed), and patch keys holding both plus
            // neighbours, with repeats across ranges; the last range is empty.
            for (&range_keys) |*list| list.clearRetainingCapacity();
            const key_count: usize = if (range_index + 1 == range_count) 0 else random.uintLessThan(usize, 40);
            for (0..key_count) |key_index| {
                const key = if (key_index < edge_keys.len and range_index % 2 == 0)
                    edge_keys[key_index]
                else
                    chunkKey(random.uintLessThan(u16, level_count), random.uintLessThan(u32, @intCast(chunk_count)));
                const kind = random.uintLessThan(usize, 4);
                if (kind == 0 or kind == 2) try range_keys[@backingInt(PlanStream.changed)].append(allocator, key);
                if (kind == 1 or kind == 2) try range_keys[@backingInt(PlanStream.dirty)].append(allocator, key);
                try range_keys[@backingInt(PlanStream.patch)].append(allocator, key);
            }
            for (&range_keys, &expected) |*list, *all| try all.appendSlice(allocator, list.items);
            // The dirty keys are the changed keys plus the link keys.
            try expected[@backingInt(PlanStream.dirty)].appendSlice(allocator, range_keys[@backingInt(PlanStream.changed)].items);
            window.* = .{ .start = undefined };
            for (&graph.plan_staging, &range_keys, &window.start, &window.end, &tally.counts) |*staging, *list, *start, *end, *count| {
                count.* = sortUnique(list.items);
                start.* = staging.items.len;
                try staging.appendSlice(allocator, list.items[0..count.*]);
                end.* = staging.items.len;
            }
        }
        for (std.meta.tags(PlanStream)) |stream| graph.keyList(stream).clearRetainingCapacity();
        try graph.mergePlanWindows();
        try std.testing.expect(graph.plan_levels.isEmpty());
        for (graph.level_graphs.items) |*level_graph| try std.testing.expect(level_graph.plan.isClear());
        for (std.meta.tags(PlanStream), &expected) |stream, *all| {
            all.items.len = sortUnique(all.items);
            try std.testing.expectEqualSlices(u64, all.items, graph.keyList(stream).items);
        }
    }
}

test "the threaded key plan equals the inline plan on 65 levels across the plan level set's word boundary" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var capacity = abstractCapacity();
    capacity.worker_participant_count = threads.participantSlotCount();
    const level_count = 65;
    const Cell = struct { level: u16, x: u16, y: u16 };
    // Level 64 lies past the level set's first word; a chunk set holds one chunk, or a full
    // word of 64 with keys at both ends. Marks go in descending key order, so ranges hold
    // keys out of range order. A new link adds dirty keys that are not changed keys.
    const shapes = [_]struct { bounds: f32, chunks: usize, link_levels: [2]u16, cells: []const Cell }{
        .{ .bounds = 128, .chunks = 1, .link_levels = .{ 2, 3 }, .cells = &.{ .{ .level = 64, .x = 2, .y = 2 }, .{ .level = 63, .x = 1, .y = 1 }, .{ .level = 62, .x = 2, .y = 1 }, .{ .level = 1, .x = 1, .y = 2 }, .{ .level = 0, .x = 1, .y = 1 } } },
        .{ .bounds = 1024, .chunks = 64, .link_levels = .{ 63, 64 }, .cells = &.{ .{ .level = 64, .x = 13, .y = 6 }, .{ .level = 64, .x = 1, .y = 1 }, .{ .level = 63, .x = 29, .y = 29 }, .{ .level = 1, .x = 29, .y = 1 }, .{ .level = 1, .x = 1, .y = 1 }, .{ .level = 0, .x = 29, .y = 29 } } },
    };
    for (shapes) |shape| {
        var world = try test_support.abstractTestWorld(&meta, shape.bounds, shape.bounds);
        defer world.deinit();
        var obstacles: [level_count]usize = undefined;
        obstacles[0] = try world.addDenseLayer(0, 0, .obstacle, grass);
        for (1..level_count) |level_index| {
            const level = try world.addLevel(-16 * @as(i32, @intCast(level_index)));
            _ = try world.addDenseLayer(level, 0, .floor, grass);
            obstacles[level_index] = try world.addDenseLayer(level, 0, .obstacle, grass);
        }
        // The inline plan, then fixed partitions; all built before the edits.
        const partitions = [_]?usize{ null, 1, 2 };
        var systems: [partitions.len]PathfindingSystem = undefined;
        var built: usize = 0;
        defer for (systems[0..built]) |*system| system.deinit();
        for (partitions) |items_per_range| {
            systems[built] = try fullRebuild(&data, &world, capacity);
            systems[built].nav_controls = .{ .adaptive = false, .items_per_range = items_per_range };
            built += 1;
        }
        try world.addLevelLink(.{ .kind = .ramp, .level_a = shape.link_levels[0], .cell_a = .{ .x = 3, .y = 3 }, .level_b = shape.link_levels[1], .cell_b = .{ .x = 3, .y = 3 }, .traversal_cost = 1, .bidirectional = true });
        for (shape.cells) |cell| {
            const changed = (try world.setDenseTile(obstacles[cell.level], cell.x, cell.y, tree)) orelse return error.TestExpectedEqual;
            for (&systems) |*system| try test_support.recordTileChange(system, &world, changed);
        }
        _ = try systems[0].applyBufferedNavUpdates(no_colliders, &world, &serial_threads);
        const inline_graph = &systems[0].graph;
        try std.testing.expectEqual(shape.chunks, inline_graph.chunkCount());
        try std.testing.expectEqual(@as(usize, level_count), inline_graph.levelCount());
        try std.testing.expectEqual(@as(usize, 1), inline_graph.plan_tallies.items.len);
        try std.testing.expect(inline_graph.dirty_keys.items.len > inline_graph.changed_keys.items.len);
        for (systems[1..]) |*system| {
            _ = try system.applyBufferedNavUpdates(no_colliders, &world, &threads);
            try std.testing.expect(system.graph.plan_tallies.items.len > 1);
            try std.testing.expect(system.graph.plan_levels.isEmpty());
            try std.testing.expectEqualSlices(u64, inline_graph.changed_keys.items, system.graph.changed_keys.items);
            try std.testing.expectEqualSlices(u64, inline_graph.dirty_keys.items, system.graph.dirty_keys.items);
            try std.testing.expectEqualSlices(u64, inline_graph.patch_keys.items, system.graph.patch_keys.items);
            try expectGraphsEquivalent(inline_graph, &system.graph);
        }
    }
}

// Every level's plan sets are clear and sized to its chunks, and the level set covers every
// level and is empty.
fn expectPlanSetsClear(graph: *const NavGraph) !void {
    try std.testing.expect(graph.plan_levels.isEmpty());
    try std.testing.expect(graph.plan_levels.capacity() >= graph.levelCount());
    for (graph.level_graphs.items) |*level_graph| {
        try std.testing.expect(level_graph.plan.isClear());
        try std.testing.expectEqual(graph.chunkCount(), level_graph.plan.order.capacity());
        try std.testing.expectEqual(graph.chunkCount(), level_graph.plan.changed.capacity());
        try std.testing.expectEqual(graph.chunkCount(), level_graph.plan.dirty.capacity());
    }
}

test "a threaded plan, a level replace, a level append, and a world rebuild each leave every level's plan sets clear and sized to its chunks" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try twoLevelWorld(&meta);
    defer fixture.world.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var capacity = abstractCapacity();
    capacity.worker_participant_count = threads.participantSlotCount();
    var system = try fullRebuild(&data, &fixture.world, capacity);
    defer system.deinit();
    system.nav_controls = .{ .adaptive = false, .items_per_range = 1 };
    try expectPlanSetsClear(&system.graph);

    // A multi-range plan over both levels.
    for ([_][3]u16{ .{ 0, 1, 1 }, .{ 1, 10, 10 }, .{ 0, 5, 9 } }) |cell| {
        const changed = (try fixture.world.setDenseTile(fixture.obstacle[cell[0]], cell[1], cell[2], fixture.tree)) orelse return error.TestExpectedEqual;
        try test_support.recordTileChange(&system, &fixture.world, changed);
    }
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    try std.testing.expect(system.graph.plan_tallies.items.len > 1);
    try expectPlanSetsClear(&system.graph);

    // Replace level 1 in place, then append a level through the apply.
    var stats = NavUpdateStats{};
    try system.graph.buildLevel(no_colliders.view(), &fixture.world, 1, null, &stats);
    try expectPlanSetsClear(&system.graph);
    _ = try fixture.world.addLevel(-32);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    try std.testing.expectEqual(@as(usize, 3), system.graph.levelCount());
    try expectPlanSetsClear(&system.graph);

    // A world rebuild sizes the level set to the world's levels up front.
    try system.rebuildStaticNavGridWithWorld(&data, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 3), system.graph.plan_levels.capacity());
    try expectPlanSetsClear(&system.graph);
}

test "every grid the create-time check accepts keeps a level's node rows below no_node, and one chunk more fails loudly" {
    const maxChunkLabels = @import("nav_grid.zig").maxChunkLabels;
    for ([_]u16{ 1, 2, 4, 8, 16 }) |edge| {
        const label_space_per_chunk: usize = @as(usize, edge) * edge + 1;
        // One chunk row of the most chunks whose label space stays below the u32 sentinel.
        const chunks = (std.math.maxInt(u32) - 1) / label_space_per_chunk;
        try validateChunkGrid(chunks * edge, edge, edge);
        // Live rows plus one batch's claims, each at most the chunks' label bound.
        try std.testing.expect(2 * chunks * maxChunkLabels(edge) < no_node);
        try std.testing.expectError(error.ChunkLabelOverflow, validateChunkGrid((chunks + 1) * edge, edge, edge));
    }
}

// The reference key plan of `marks` and `links` on `graph`: per stream the sorted unique keys
// by definition (changed: every chunk a mark spans; dirty: those plus each link's endpoint
// chunks; patch: those plus every in-level orthogonal neighbour of a changed chunk).
fn referencePlan(allocator: std.mem.Allocator, graph: *const NavGraph, world: *const WorldSystem, marks: []const NavMark, links: []const LevelLink) ![plan_streams]std.ArrayList(u64) {
    var lists: [plan_streams]std.ArrayList(u64) = @splat(.empty);
    errdefer for (&lists) |*list| list.deinit(allocator);
    const changed = &lists[@backingInt(PlanStream.changed)];
    const dirty = &lists[@backingInt(PlanStream.dirty)];
    const patch = &lists[@backingInt(PlanStream.patch)];
    const ct: usize = graph.geometry.chunk_tiles;
    const chunks_x = graph.chunkGeometry().chunks_x;
    const chunks_y = graph.chunkGeometry().chunks_y;
    for (marks) |mark| {
        const span = graph.markSpan(world, mark) orelse continue;
        for (span.min_y / ct..span.max_y / ct + 1) |cy| for (span.min_x / ct..span.max_x / ct + 1) |cx| {
            const key = chunkKey(mark.level, @intCast(cy * chunks_x + cx));
            try changed.append(allocator, key);
            try dirty.append(allocator, key);
            try patch.append(allocator, key);
            if (cx > 0) try patch.append(allocator, chunkKey(mark.level, @intCast(cy * chunks_x + cx - 1)));
            if (cx + 1 < chunks_x) try patch.append(allocator, chunkKey(mark.level, @intCast(cy * chunks_x + cx + 1)));
            if (cy > 0) try patch.append(allocator, chunkKey(mark.level, @intCast((cy - 1) * chunks_x + cx)));
            if (cy + 1 < chunks_y) try patch.append(allocator, chunkKey(mark.level, @intCast((cy + 1) * chunks_x + cx)));
        };
    }
    for (links) |link| {
        for ([_]u16{ link.level_a, link.level_b }, [_]CellCoord{ link.cell_a, link.cell_b }) |level, cell| {
            const key = chunkKey(level, @intCast((cell.y / ct) * chunks_x + cell.x / ct));
            try dirty.append(allocator, key);
            try patch.append(allocator, key);
        }
    }
    for (&lists) |*list| list.items.len = sortUnique(list.items);
    return lists;
}

test "the key plan equals the plan by definition for multi-chunk marks at level edges and new links, inline and threaded" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    // 24x24 tiles in 4-tile chunks: 6x6 chunks per level, on two levels.
    var world = try test_support.abstractTestWorld(&meta, 768, 768);
    defer world.deinit();
    _ = try world.addLevel(-16);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var capacity = abstractCapacity();
    capacity.worker_participant_count = threads.participantSlotCount();
    var systems = [_]PathfindingSystem{ try fullRebuild(&data, &world, capacity), try fullRebuild(&data, &world, capacity) };
    defer for (&systems) |*system| system.deinit();
    systems[1].nav_controls = .{ .adaptive = false, .items_per_range = 1 };
    try std.testing.expectEqual(@as(usize, 36), systems[0].graph.chunkCount());
    // A 3x2-chunk box in the level's middle (chunks 1..3 x 2..3) whose four flanking strips lie
    // inside the level and outside every other mark and its neighbours, its middle column
    // holding edge chunks that are no corners; a 2x1-chunk box on the level's east edge; one
    // corner cell on level 1; and a two-way link whose endpoints no mark touches.
    const marks = [_]NavMark{
        .{ .level = 0, .kind = .tile_box, .min_x = 5, .min_y = 9, .max_x = 14, .max_y = 14 },
        .{ .level = 0, .kind = .tile_box, .min_x = 17, .min_y = 0, .max_x = 23, .max_y = 1 },
        .{ .level = 1, .kind = .tile_box, .min_x = 23, .min_y = 23, .max_x = 23, .max_y = 23 },
    };
    try world.addLevelLink(.{ .kind = .stair, .level_a = 0, .cell_a = .{ .x = 1, .y = 23 }, .level_b = 1, .cell_b = .{ .x = 6, .y = 2 }, .traversal_cost = 1, .bidirectional = true });
    var expected = try referencePlan(allocator, &systems[0].graph, &world, &marks, systems[0].graph.newLinks(&world));
    defer for (&expected) |*list| list.deinit(allocator);
    // The box's flanks are patch keys only its own edge chunks emit.
    for ([_][2]u32{ .{ 0, 2 }, .{ 0, 3 }, .{ 4, 2 }, .{ 4, 3 }, .{ 1, 1 }, .{ 2, 1 }, .{ 3, 1 }, .{ 1, 4 }, .{ 2, 4 }, .{ 3, 4 } }) |flank| {
        const key = chunkKey(0, flank[1] * 6 + flank[0]);
        try std.testing.expect(sortedContains(expected[@backingInt(PlanStream.patch)].items, key));
        try std.testing.expect(!sortedContains(expected[@backingInt(PlanStream.changed)].items, key));
    }
    for (&systems, [_]?*ThreadSystem{ null, &threads }) |*system, thread_system| {
        var stats = NavUpdateStats{};
        const threads_for: ?NavUpdateThreads = if (thread_system) |ts| .{ .thread_system = ts, .tuners = &system.tuners.nav, .controls = system.nav_controls } else null;
        const prepared = (try system.graph.prepareMarks(&world, no_colliders.view(), &marks, threads_for, &stats)).?;
        defer system.graph.abortMarks(prepared);
        if (thread_system != null) try std.testing.expect(system.graph.plan_tallies.items.len > 1);
        for (std.meta.tags(PlanStream), &expected) |stream, *keys| try std.testing.expectEqualSlices(u64, keys.items, system.graph.keyList(stream).items);
    }
}

test "a step's stats fold the plan, remask, and patch stages of its level build and its marks batch" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try twoLevelWorld(&meta);
    defer fixture.world.deinit();
    var system = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer system.deinit();
    // One step: a level appended and one cell dug on level 0.
    _ = try fixture.world.addLevel(-32);
    const changed = (try fixture.world.setDenseTile(fixture.obstacle[0], 5, 5, fixture.tree)) orelse return error.TestExpectedEqual;
    try test_support.recordTileChange(&system, &fixture.world, changed);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    const chunks = system.graph.chunkCount();
    try std.testing.expectEqual(@as(usize, 1), stats.levels_built);
    try std.testing.expectEqual(chunks + stats.dirty_chunks, stats.remask_batch.item_count);
}
