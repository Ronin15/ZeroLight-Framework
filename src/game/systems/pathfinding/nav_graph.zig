// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Per-level nav cell grids plus per-chunk records: a record holds one chunk's border-run
//! portals, its open link-endpoint portals, and the links leaving them, and a chunk with no
//! portal holds none. One transactional batch (plan, reserve, commit) remasks the changed
//! chunks and re-derives every record whose portals can change; level and world builds are
//! the same batch over fresh storage.

const std = @import("std");
const builtin = @import("builtin");
const math = @import("../../../core/math.zig");
const simd = @import("../../../core/simd.zig");
const logging = @import("../../../core/logging.zig");
const WorldSystem = @import("../../world_system.zig").WorldSystem;
const validateChunkGrid = @import("../../world_system.zig").validateChunkGrid;
const max_chunk_size_tiles = @import("../../world_system.zig").max_chunk_size_tiles;
const LevelLink = @import("../../world_system.zig").LevelLink;
const CellCoord = @import("../../world_system.zig").CellCoord;
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const AdaptiveWorkTuner = @import("../../../app/thread_system.zig").AdaptiveWorkTuner;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const BatchStats = @import("../../../app/thread_system.zig").BatchStats;
const JobFn = @import("../../../app/thread_system.zig").JobFn;
const BatchSelection = @import("../../../app/thread_system.zig").BatchSelection;
const PathAgentClass = @import("../../simulation.zig").PathAgentClass;
const NavGrid = @import("nav_grid.zig").NavGrid;
const ChunkBits = @import("../../world_terrain.zig").ChunkBits;
const no_block = @import("nav_grid.zig").no_block;
const ColliderView = @import("../static_colliders.zig").ColliderView;
const ColliderGeometry = @import("../static_colliders.zig").ColliderGeometry;
const types = @import("types.zig");
const default_cell_size = types.default_cell_size;
const default_nav_chunk_tiles = types.default_nav_chunk_tiles;
const no_cell = types.no_cell;
const inter_level_penalty = types.inter_level_penalty;
const unreachable_cost = types.unreachable_cost;
const long_link_pairs = types.long_link_pairs;
const long_lane_cap = types.long_lane_cap;
const crossing_rate_cap = types.crossing_rate_cap;
const cardinal_cost = types.cardinal_cost;
const diagonal_cost = types.diagonal_cost;
const octileU32 = types.octileU32;
const PathQueryKey = types.PathQueryKey;
const NavMark = types.NavMark;
const NavSpan = types.NavSpan;
const NavUpdateStats = types.NavUpdateStats;
const StageTimer = @import("../../../app/runtime_perf_log.zig").StageTimer;
const setLen = types.setLen;
const Connectivity = @import("connectivity.zig").Connectivity;
const ConnectivityCounters = @import("connectivity.zig").ConnectivityCounters;
const ClosureCounters = @import("connectivity.zig").ClosureCounters;
const ClosureThreads = @import("connectivity.zig").ClosureThreads;
const NodeRow = @import("connectivity.zig").NodeRow;
const no_node = @import("connectivity.zig").no_node;
const no_comp = @import("connectivity.zig").no_comp;

/// Most border portals a chunk of edge `chunk_tiles` holds: one per open run on each of its
/// four sides.
pub fn borderPortalBound(chunk_tiles: u16) usize {
    return 4 * ((@as(usize, chunk_tiles) + 1) / 2);
}

/// Most border portals any chunk holds.
pub const max_border_portals: usize = borderPortalBound(max_chunk_size_tiles);
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
        for (self.border) |portal| {
            if (portal.local == local) return portal;
        }
        if (findLocal(self.extra, local)) |index| return self.extra[index];
        return null;
    }

    /// The links leaving chunk-local cell `local`, in link order. O(log links).
    pub fn linksAt(self: ChunkPortals, local: u8) []const NavLink {
        var lo: usize = 0;
        var hi: usize = self.links.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.links[mid].local < local) lo = mid + 1 else hi = mid;
        }
        var end = lo;
        while (end < self.links.len and self.links[end].local == local) end += 1;
        return self.links[lo..end];
    }

    pub fn portalCount(self: ChunkPortals) usize {
        return self.border.len + self.extra.len;
    }
};

fn findLocal(portals: []const NavPortal, local: u8) ?usize {
    var lo: usize = 0;
    var hi: usize = portals.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (portals[mid].local == local) return mid;
        if (portals[mid].local < local) lo = mid + 1 else hi = mid;
    }
    return null;
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

const LinkSlotRow = struct {
    extra: std.ArrayList(NavPortal),
    links: std.ArrayList(NavLink),
};

const empty_portal = NavPortal{ .local = 0, .label = 0, .flags = .{} };

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

    pub fn deinit(self: *NavLevelGraph, allocator: std.mem.Allocator) void {
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
    /// allocating. Pool growth is geometric and counted; rows stay below `no_node`.
    pub fn ensureFreeNodes(self: *NavLevelGraph, allocator: std.mem.Allocator, needed: usize, pool_grows: *u64) !void {
        if (self.node_free.items.len >= needed) return;
        const added = needed - self.node_free.items.len;
        const total = self.nodes.len + added;
        if (total >= no_node) return error.NavConnectivityOverflow;
        if (total > self.nodes.capacity) {
            try self.nodes.ensureTotalCapacity(allocator, @max(total, self.nodes.capacity *| 2));
            // The pool moved: the column views follow it before anything else can fail.
            self.refreshColumns();
            pool_grows.* += 1;
        }
        try self.node_free.ensureTotalCapacity(allocator, self.nodes.capacity);
        self.appendFreeNodes(added);
    }

    /// Sizes an empty level's node pool to exactly `count` free rows.
    pub fn ensureNodesExact(self: *NavLevelGraph, allocator: std.mem.Allocator, count: usize) !void {
        std.debug.assert(self.nodes.len == 0);
        if (count >= no_node) return error.NavConnectivityOverflow;
        if (count > self.nodes.capacity) try self.nodes.setCapacity(allocator, count);
        self.refreshColumns();
        try self.node_free.ensureTotalCapacityPrecise(allocator, self.nodes.capacity);
        self.appendFreeNodes(count);
    }

    // Appends `count` free rows, pushed in descending order so claims hand out ascending rows.
    fn appendFreeNodes(self: *NavLevelGraph, count: usize) void {
        const first: u32 = @intCast(self.nodes.len);
        for (0..count) |_| self.nodes.appendAssumeCapacity(.{ .label = 0, .comp = no_comp, .sibling = no_node, .queue = 0, .queue_row = no_node });
        var row: u32 = @intCast(self.nodes.len);
        while (row > first) {
            row -= 1;
            self.node_free.appendAssumeCapacity(row);
        }
        self.refreshColumns();
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
            self.records.capacity * (2 * @sizeOf(u8) + 2 * @sizeOf(u32)) +
            self.nodes.capacity * @sizeOf(NodeRow) +
            self.node_free.capacity * @sizeOf(u32) +
            self.border.capacity * @sizeOf(NavPortal) +
            self.record_free.capacity * @sizeOf(u32) +
            self.link_slots.capacity * @sizeOf(LinkSlotRow) +
            self.link_free.capacity * @sizeOf(u32);
        for (self.slot_extra) |extra| bytes += extra.capacity * @sizeOf(NavPortal);
        for (self.slot_links) |links| bytes += links.capacity * @sizeOf(NavLink);
        return bytes;
    }

    // Grows the free record list to at least `needed` ids, so the next `needed` claims pop
    // without allocating. Pool growth is geometric and counted.
    fn ensureFreeRecords(self: *NavLevelGraph, allocator: std.mem.Allocator, needed: usize, pool_grows: *u64) !void {
        if (self.record_free.items.len >= needed) return;
        const added = needed - self.record_free.items.len;
        const total = self.records.len + added;
        // At most one record per chunk, and `validateChunkGrid` keeps a level's chunk count
        // below 2^31, so ids stay below the `no_record` sentinel.
        std.debug.assert(total < no_record);
        if (total > self.records.capacity) {
            try self.records.ensureTotalCapacity(allocator, @max(total, self.records.capacity *| 2));
            // The pool moved: the column views follow it before anything else can fail.
            self.refreshColumns();
            pool_grows.* += 1;
        }
        try self.border.ensureTotalCapacity(allocator, self.records.capacity * self.border_stride);
        try self.record_free.ensureTotalCapacity(allocator, self.records.capacity);
        for (0..added) |_| {
            const id: u32 = @intCast(self.records.len);
            self.records.appendAssumeCapacity(.{ .border_count = 0, .link_slot = no_link_slot, .node_head = no_node, .label_count = 0 });
            self.border.appendNTimesAssumeCapacity(empty_portal, self.border_stride);
            self.record_free.appendAssumeCapacity(id);
        }
        self.refreshColumns();
    }

    fn ensureFreeLinkSlots(self: *NavLevelGraph, allocator: std.mem.Allocator, needed: usize, pool_grows: *u64) !void {
        if (self.link_free.items.len >= needed) return;
        const added = needed - self.link_free.items.len;
        const total = self.link_slots.len + added;
        // At most one link slot per record.
        std.debug.assert(total < no_link_slot);
        if (total > self.link_slots.capacity) {
            try self.link_slots.ensureTotalCapacity(allocator, @max(total, self.link_slots.capacity *| 2));
            // The pool moved: the column views follow it before anything else can fail.
            self.refreshColumns();
            pool_grows.* += 1;
        }
        try self.link_free.ensureTotalCapacity(allocator, self.link_slots.capacity);
        for (0..added) |_| {
            const id: u32 = @intCast(self.link_slots.len);
            self.link_slots.appendAssumeCapacity(.{ .extra = .empty, .links = .empty });
            self.link_free.appendAssumeCapacity(id);
        }
        self.refreshColumns();
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

// Cache-line separation for per-participant scratch slots, same policy as collision.zig,
// simulation_scope.zig and spatial_index.zig.
const thread_shared_record_alignment: usize = 64;

// A changed key's remask slot before the commit claims it: the chunk may end mixed and
// holds no cell block yet.
const claim_pending: u32 = no_block - 1;

/// Threading for one batch stage: the shared thread system plus that stage's own tuner.
/// `adaptive`/`items_per_range` let a bench pin a fixed partition.
pub const NavStageThreads = struct {
    thread_system: *ThreadSystem,
    tuner: *AdaptiveWorkTuner,
    adaptive: bool = true,
    items_per_range: ?usize = null,
};

/// Threading for nav batches: the shared thread system plus one tuner per stage (key
/// plan, remask and component flood, record patch, connectivity seed, gather, and flood, and
/// the one-way closure's candidates, resolve, mask, plan, rows, and compaction).
/// Absent: every stage runs inline.
pub const NavUpdateThreads = struct {
    thread_system: *ThreadSystem,
    plan_tuner: *AdaptiveWorkTuner,
    remask_tuner: *AdaptiveWorkTuner,
    patch_tuner: *AdaptiveWorkTuner,
    conn_seed_tuner: *AdaptiveWorkTuner,
    conn_gather_tuner: *AdaptiveWorkTuner,
    conn_flood_tuner: *AdaptiveWorkTuner,
    conn_candidates_tuner: *AdaptiveWorkTuner,
    conn_closure_resolve_tuner: *AdaptiveWorkTuner,
    conn_closure_mask_tuner: *AdaptiveWorkTuner,
    conn_closure_plan_tuner: *AdaptiveWorkTuner,
    conn_closure_rows_tuner: *AdaptiveWorkTuner,
    conn_closure_compact_tuner: *AdaptiveWorkTuner,
    adaptive: bool = true,
    items_per_range: ?usize = null,

    fn stage(self: NavUpdateThreads, tuner: *AdaptiveWorkTuner) NavStageThreads {
        return .{ .thread_system = self.thread_system, .tuner = tuner, .adaptive = self.adaptive, .items_per_range = self.items_per_range };
    }

    fn plan(self: NavUpdateThreads) NavStageThreads {
        return .{ .thread_system = self.thread_system, .tuner = self.plan_tuner, .adaptive = self.adaptive, .items_per_range = self.items_per_range };
    }
    fn remask(self: NavUpdateThreads) NavStageThreads {
        return .{ .thread_system = self.thread_system, .tuner = self.remask_tuner, .adaptive = self.adaptive, .items_per_range = self.items_per_range };
    }
    fn patch(self: NavUpdateThreads) NavStageThreads {
        return .{ .thread_system = self.thread_system, .tuner = self.patch_tuner, .adaptive = self.adaptive, .items_per_range = self.items_per_range };
    }
};

fn planThreads(threads: ?NavUpdateThreads) ?NavStageThreads {
    return if (threads) |t| t.plan() else null;
}

fn remaskThreads(threads: ?NavUpdateThreads) ?NavStageThreads {
    return if (threads) |t| t.remask() else null;
}

fn patchThreads(threads: ?NavUpdateThreads) ?NavStageThreads {
    return if (threads) |t| t.patch() else null;
}

fn connSeedThreads(threads: ?NavUpdateThreads) ?NavStageThreads {
    return if (threads) |t| t.stage(t.conn_seed_tuner) else null;
}

fn connGatherThreads(threads: ?NavUpdateThreads) ?NavStageThreads {
    return if (threads) |t| t.stage(t.conn_gather_tuner) else null;
}

fn connFloodThreads(threads: ?NavUpdateThreads) ?NavStageThreads {
    return if (threads) |t| t.stage(t.conn_flood_tuner) else null;
}

fn closureThreads(threads: ?NavUpdateThreads) ClosureThreads {
    const t = threads orelse return .{};
    return .{
        .candidates = t.stage(t.conn_candidates_tuner),
        .resolve = t.stage(t.conn_closure_resolve_tuner),
        .mask = t.stage(t.conn_closure_mask_tuner),
        .plan = t.stage(t.conn_closure_plan_tuner),
        .rows = t.stage(t.conn_closure_rows_tuner),
        .compact = t.stage(t.conn_closure_compact_tuner),
    };
}

/// A batch key: the (level, chunk) pair, sorted level-major.
pub fn chunkKey(level: u16, chunk: u32) u64 {
    return (@as(u64, level) << 32) | chunk;
}

pub fn keyLevel(key: u64) u16 {
    return @intCast(key >> 32);
}

pub fn keyChunk(key: u64) u32 {
    return @truncate(key);
}

// Batch key lists. Plan windows start on cache lines, so the staging lists are aligned.
const KeyList = std.ArrayListAligned(u64, .fromByteUnits(thread_shared_record_alignment));
const key_window_alignment: usize = thread_shared_record_alignment / @sizeOf(u64);

// Sorts `keys` and drops repeats in place; returns the unique count. O(k log k).
fn sortUnique(keys: []u64) usize {
    std.sort.pdq(u64, keys, {}, std.sort.asc(u64));
    var write: usize = 0;
    for (keys) |key| {
        if (write != 0 and keys[write - 1] == key) continue;
        keys[write] = key;
        write += 1;
    }
    return write;
}

// The key lists a batch plans. `changed`: the chunks a mark touches (remasked). `dirty`:
// those plus both endpoint chunks of each new link (the batch result). `patch`: the dirty
// keys plus the changed keys' orthogonal neighbours (records re-derived).
const PlanStream = enum { changed, dirty, patch };
const plan_streams = std.meta.tags(PlanStream).len;

// One plan range's key windows in the staging lists, and its merge cursors.
const PlanWindow = struct {
    start: [plan_streams]usize,
    // Exclusive: the start plus the range's key bounds.
    end: [plan_streams]usize = @splat(0),
    next: [plan_streams]usize = @splat(0),
};

// One plan range's unique key counts, padded to its own cache line.
const PlanTally = struct {
    counts: [plan_streams]usize align(thread_shared_record_alignment) = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(PlanTally) % thread_shared_record_alignment == 0);
}

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

// A k-way merge head: the smallest unmerged key of one plan range.
const MergeHead = struct {
    key: u64,
    range: u32,

    fn lessThan(a: MergeHead, b: MergeHead) bool {
        return a.key < b.key or (a.key == b.key and a.range < b.range);
    }
};

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

// Grows a link slot's list to hold `limit` entries, geometrically and counted.
fn growSlotList(comptime T: type, list: *std.ArrayList(T), allocator: std.mem.Allocator, limit: usize, pool_grows: *u64) !void {
    if (list.capacity < limit) {
        try list.ensureTotalCapacity(allocator, limit);
        pool_grows.* += 1;
    }
    std.debug.assert(list.capacity >= limit);
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

// Dispatch time of a batch that ran on workers; zero when it ran inline.
fn offMainNs(batch: BatchStats) u64 {
    return if (batch.ran_inline) 0 else batch.batch_duration_ns;
}

/// Runs one stage over `item_count` items: through the stage's tuner when threaded, else
/// inline as one range on the main thread. `range_count` is the job's dispatched range
/// count, set before dispatch so each range can assert against it.
pub fn runStage(threads: ?NavStageThreads, item_count: usize, context: *anyopaque, range_count: *usize, job: JobFn) BatchStats {
    if (item_count == 0) return .{};
    if (threads) |stage| {
        const selection = stage.thread_system.selectBatchProfile(stage.tuner, .{
            .item_count = item_count,
            .items_per_range = stage.items_per_range,
            .range_alignment_items = 1,
            .adaptive = stage.adaptive,
        });
        range_count.* = selection.range_count;
        return stage.thread_system.parallelForWithOptions(item_count, context, job, .{
            .adaptive = stage.adaptive,
            .adaptive_tuner = selection.active_tuner,
            .items_per_range = stage.items_per_range,
            .range_alignment_items = 1,
            .selected_profile = selection.profile,
        });
    }
    range_count.* = 1;
    // No thread system times the batch, so it is timed here.
    const stage_timer = StageTimer.begin();
    job(context, .{ .start = 0, .end = item_count, .index = 0 }, WorkerId.main);
    var batch = inlineBatch(item_count);
    batch.batch_duration_ns = stage_timer.lap();
    return batch;
}

// The batch shape of a stage run inline as one range on the main thread.
fn inlineBatch(item_count: usize) BatchStats {
    return .{
        .item_count = item_count,
        .range_count = 1,
        .items_per_range = item_count,
        .range_alignment_items = 1,
        .main_thread_ranges = 1,
        .ran_inline = true,
    };
}

/// Folds one batch's shape into a running total: summed counts and times, the widest range
/// and worker use, and inline only when every batch ran inline.
pub fn accumulateBatch(total: *BatchStats, batch: BatchStats) void {
    if (batch.item_count == 0) return;
    total.item_count += batch.item_count;
    total.range_count += batch.range_count;
    total.items_per_range = @max(total.items_per_range, batch.items_per_range);
    total.available_worker_threads = @max(total.available_worker_threads, batch.available_worker_threads);
    total.active_worker_threads = @max(total.active_worker_threads, batch.active_worker_threads);
    total.main_thread_ranges += batch.main_thread_ranges;
    total.worker_thread_ranges += batch.worker_thread_ranges;
    total.batch_duration_ns += batch.batch_duration_ns;
    total.main_thread_wait_ns += batch.main_thread_wait_ns;
    total.ran_inline = total.ran_inline and batch.ran_inline;
}

/// One stage step dispatched as rounds under one thread profile: `begin` selects it once
/// from the step's item count through the stage's tuner, `run` dispatches every round with it
/// (no per-round tuner record; a round of one range runs inline), and `finish` records the
/// summed rounds into the tuner once, at the step's item count and the selected profile, so
/// the tuner judges one sample per step. With no threads each round runs inline as one range.
pub const RoundDispatch = struct {
    threads: ?NavStageThreads,
    selection: ?BatchSelection = null,
    // The rounds folded into one.
    total: BatchStats = .{},
    /// Dispatch time of the rounds that ran on workers, and of those that ran inline.
    off_main_ns: u64 = 0,
    inline_ns: u64 = 0,
    /// The fewest and most items a round dispatched (both zero with no round).
    round_items_min: usize = 0,
    round_items_max: usize = 0,

    pub fn begin(threads: ?NavStageThreads, step_items: usize) RoundDispatch {
        var dispatch = RoundDispatch{ .threads = threads };
        if (threads) |stage| {
            dispatch.selection = stage.thread_system.selectBatchProfile(stage.tuner, .{
                .item_count = @max(step_items, 1),
                .items_per_range = stage.items_per_range,
                .range_alignment_items = 1,
                .adaptive = stage.adaptive,
            });
        }
        return dispatch;
    }

    /// Runs one round of `item_count` items. `range_count` is the job's dispatched range
    /// count, set before dispatch so each range can assert against it.
    pub fn run(self: *RoundDispatch, item_count: usize, context: *anyopaque, range_count: *usize, job: JobFn) void {
        std.debug.assert(item_count != 0);
        self.round_items_min = if (self.round_items_max == 0) item_count else @min(self.round_items_min, item_count);
        self.round_items_max = @max(self.round_items_max, item_count);
        const batch = if (self.selection) |selection| blk: {
            const stage = self.threads.?;
            const per_range = @max(selection.profile.items_per_range, 1);
            range_count.* = (item_count + per_range - 1) / per_range;
            break :blk stage.thread_system.parallelForWithOptions(item_count, context, job, .{
                .adaptive = stage.adaptive,
                .adaptive_tuner = null,
                .items_per_range = stage.items_per_range,
                .range_alignment_items = 1,
                .selected_profile = selection.profile,
            });
        } else blk: {
            range_count.* = 1;
            // No thread system times the round, so it is timed here.
            const round_timer = StageTimer.begin();
            job(context, .{ .start = 0, .end = item_count, .index = 0 }, WorkerId.main);
            var round = inlineBatch(item_count);
            round.batch_duration_ns = round_timer.lap();
            break :blk round;
        };
        std.debug.assert(batch.range_count == range_count.*);
        self.off_main_ns += offMainNs(batch);
        if (batch.ran_inline) self.inline_ns += batch.batch_duration_ns;
        accumulateBatch(&self.total, batch);
    }

    /// Records the step into the stage's tuner once and returns the rounds folded into one.
    pub fn finish(self: *RoundDispatch, step_items: usize) BatchStats {
        const selection = self.selection orelse return self.total;
        const tuner = selection.active_tuner orelse return self.total;
        tuner.record(.{
            .item_count = @max(step_items, 1),
            .range_count = self.total.range_count,
            .items_per_range = selection.profile.items_per_range,
            .range_alignment_items = 1,
            .available_worker_threads = self.total.available_worker_threads,
            .active_worker_threads = selection.profile.worker_threads,
            .main_thread_ranges = self.total.main_thread_ranges,
            .worker_thread_ranges = self.total.worker_thread_ranges,
            .batch_duration_ns = self.total.batch_duration_ns,
            .main_thread_wait_ns = self.total.main_thread_wait_ns,
            .ran_inline = selection.profile.worker_threads == 0,
        });
        return self.total;
    }
};

// Folds one batch's connectivity counters and stage shapes into `stats`: level builds and the
// marks batch sum.
fn addConnectivityStats(stats: *NavUpdateStats, conn: *const Connectivity, counters: ConnectivityCounters) void {
    stats.conn_groups += counters.groups;
    stats.conn_families += counters.families;
    stats.conn_rounds += counters.rounds;
    stats.conn_build_visits += counters.build_visits;
    stats.conn_flood_nodes += counters.flood_nodes;
    stats.conn_splits += counters.splits;
    stats.conn_merges += counters.merges;
    if (counters.rounds != 0) {
        stats.conn_round_items_min = if (stats.conn_round_items_max == 0) counters.round_items_min else @min(stats.conn_round_items_min, counters.round_items_min);
        stats.conn_round_items_max = @max(stats.conn_round_items_max, counters.round_items_max);
    }
    stats.conn_flood_off_main_ns += counters.flood_off_main_ns;
    accumulateBatch(&stats.conn_seed_batch, conn.last_seed_batch);
    accumulateBatch(&stats.conn_gather_batch, conn.last_gather_batch);
    accumulateBatch(&stats.conn_flood_batch, conn.last_flood_batch);
    addClosureStats(stats, conn, counters.closure);
}

// Folds one batch's closure counters and commit-side stage shapes into `stats`; the prepare
// stages (candidates, compaction) fold where they run.
fn addClosureStats(stats: *NavUpdateStats, conn: *const Connectivity, counters: ClosureCounters) void {
    stats.closure_touched += counters.touched;
    stats.closure_links += counters.links;
    stats.closure_terms_new += counters.terms_new;
    stats.closure_terms_left += counters.terms_left;
    stats.closure_a_rows += counters.a_rows;
    stats.closure_rounds += counters.rounds;
    stats.closure_words_written += counters.words_written;
    stats.closure_shrinks += counters.shrinks;
    stats.closure_live_words = conn.closure.live_words;
    stats.closure_dead_words = conn.closure.dead_words;
    stats.closure_arena_capacity = conn.closure.words.capacity;
    if (conn.closure.active) {
        const limits = conn.closure.limits;
        stats.closure_tail_bound = @max(stats.closure_tail_bound, limits.arena_tail);
        stats.closure_tail_used = @max(stats.closure_tail_used, counters.tail_words);
        stats.closure_arena_limit = @max(stats.closure_arena_limit, conn.closure.arena_limit);
        stats.closure_candidate_words = @max(stats.closure_candidate_words, limits.candidate_words);
        stats.closure_live_prepared = @max(stats.closure_live_prepared, limits.live_prepared);
        stats.closure_kb = @max(stats.closure_kb, limits.k_b);
    }
    if (counters.links == 0) return;
    accumulateBatch(&stats.conn_closure_resolve_batch, conn.closure.last_resolve_batch);
    accumulateBatch(&stats.conn_closure_mask_batch, conn.closure.last_mask_batch);
    accumulateBatch(&stats.conn_closure_plan_batch, conn.closure.last_plan_batch);
    accumulateBatch(&stats.conn_closure_rows_batch, conn.closure.last_rows_batch);
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
    pub fn colliderGeometry(self: NavExtent) !ColliderGeometry {
        const cells = self.cellGrid();
        try validateChunkGrid(cells.width, cells.height, cells.chunk_tiles);
        // `validateChunkGrid` keeps the cell count below 2^32, so each side fits u32.
        return .{ .cell_size = cells.cell_size, .width = @intCast(cells.width), .height = @intCast(cells.height), .chunk_tiles = cells.chunk_tiles };
    }

    const CellGrid = struct { cell_size: f32, width: usize, height: usize, chunk_tiles: u16 };

    fn cellGrid(self: NavExtent) CellGrid {
        return switch (self) {
            // A nav cell is a tile and a nav chunk the world's chunk.
            .world => |world_system| blk: {
                std.debug.assert(std.math.isFinite(world_system.tile_size) and world_system.tile_size > 0);
                break :blk .{ .cell_size = world_system.tile_size, .width = world_system.width, .height = world_system.height, .chunk_tiles = world_system.chunk_size_tiles };
            },
            // A 0/negative/non-finite cell_size or bound would make @intFromFloat see
            // inf/NaN (illegal behavior); degenerate config collapses to a 1x1 grid.
            .bounds => |bounds| blk: {
                const cell_size: f32 = if (std.math.isFinite(bounds.cell_size) and bounds.cell_size > 0) bounds.cell_size else 1.0;
                const safe_w: f32 = if (std.math.isFinite(bounds.width) and bounds.width > 0) bounds.width else 0;
                const safe_h: f32 = if (std.math.isFinite(bounds.height) and bounds.height > 0) bounds.height else 0;
                break :blk .{
                    .cell_size = cell_size,
                    .width = @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(safe_w / cell_size)))),
                    .height = @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(safe_h / cell_size)))),
                    .chunk_tiles = bounds.chunk_tiles,
                };
            },
        };
    }
};

/// Per-level rates the long-link term charges for a level gap: the least excess and the least
/// cost of a level-crossing short link, per level it spans, capped at `crossing_rate_cap`.
/// With no such link no level gap is crossable short-only, so both take the cap.
pub const CrossingRates = struct {
    excess: i32,
    cost: i32,
};

// One box of a link pair's entrance or exit, for the cold fold.
const LinkBox = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    l0: i32,
    l1: i32,

    fn point(x: i32, y: i32, level: i32) LinkBox {
        return .{ .x0 = x, .y0 = y, .x1 = x, .y1 = y, .l0 = level, .l1 = level };
    }

    fn contains(self: LinkBox, cell: CellCoord, level: u16) bool {
        return cell.x >= self.x0 and cell.x <= self.x1 and cell.y >= self.y0 and cell.y <= self.y1 and level >= self.l0 and level <= self.l1;
    }

    fn unionWith(self: LinkBox, other: LinkBox) LinkBox {
        return .{
            .x0 = @min(self.x0, other.x0),
            .y0 = @min(self.y0, other.y0),
            .x1 = @max(self.x1, other.x1),
            .y1 = @max(self.y1, other.y1),
            .l0 = @min(self.l0, other.l0),
            .l1 = @max(self.l1, other.l1),
        };
    }

    // Cells times levels covered; below 2^48 for u16 coordinates and levels.
    fn volume(self: LinkBox) i64 {
        return @as(i64, self.x1 - self.x0 + 1) * (self.y1 - self.y0 + 1) * (self.l1 - self.l0 + 1);
    }

    // Volume the union with `other` adds over the two boxes alone.
    fn mergeGrowth(self: LinkBox, other: LinkBox) i64 {
        return self.unionWith(other).volume() - self.volume() - other.volume();
    }

    // The short-link lower bound between a point of this box and a point of `other`: the
    // box term at their per-axis separations. Below 2^31.
    fn termTo(self: LinkBox, other: LinkBox, rates: CrossingRates) i64 {
        const dx: u32 = @intCast(@max(@as(i64, other.x0) - self.x1, @as(i64, self.x0) - other.x1, 0));
        const dy: u32 = @intCast(@max(@as(i64, other.y0) - self.y1, @as(i64, self.y0) - other.y1, 0));
        const gap: i64 = @max(@as(i64, other.l0) - self.l1, @as(i64, self.l0) - other.l1, 0);
        return @max(@as(i64, octileU32(0, 0, dx, dy)) + gap * rates.excess, gap * rates.cost);
    }
};

/// One side (entrances or exits) of a `LinkPairs` summary: per pair a planar cell rect and
/// level range, inclusive, in SoA i32 columns so a scan covers `simd.lane_count` pairs per step.
/// The owning summary keeps slots past its count equal to pair 0.
pub const LinkBoxes = struct {
    x0: [long_link_pairs]i32 = @splat(0),
    y0: [long_link_pairs]i32 = @splat(0),
    x1: [long_link_pairs]i32 = @splat(0),
    y1: [long_link_pairs]i32 = @splat(0),
    l0: [long_link_pairs]i32 = @splat(0),
    l1: [long_link_pairs]i32 = @splat(0),

    fn boxAt(self: *const LinkBoxes, index: usize) LinkBox {
        return .{ .x0 = self.x0[index], .y0 = self.y0[index], .x1 = self.x1[index], .y1 = self.y1[index], .l0 = self.l0[index], .l1 = self.l1[index] };
    }

    fn setBox(self: *LinkBoxes, index: usize, box: LinkBox) void {
        self.x0[index] = box.x0;
        self.y0[index] = box.y0;
        self.x1[index] = box.x1;
        self.y1[index] = box.y1;
        self.l0[index] = box.l0;
        self.l1[index] = box.l1;
    }

    /// Per slot, the short-link lower bound from (x, y) on `level` to a point in its box,
    /// clamped to `long_lane_cap`: max(octile to the box + gap * `rates.excess`, gap *
    /// `rates.cost`), gap being the levels between `level` and the box's range. Coordinates
    /// at most `max_link_box_coord` (a world-backed grid). Fixed work: one `simd.zig` `Int4`
    /// step per `simd.lane_count` slots.
    pub fn laneTerms(self: *const LinkBoxes, x: u32, y: u32, level: u16, rates: CrossingRates) [long_link_pairs]i32 {
        const kernel = BoxTermKernel.init(x, y, level, rates);
        var terms: [long_link_pairs]i32 = undefined;
        var index: usize = 0;
        while (index < long_link_pairs) : (index += simd.lane_count) {
            simd.storeInt4(terms[index..][0..simd.lane_count], kernel.terms(self, index));
        }
        return terms;
    }

    /// The least over the first `pair_count` slots, rounded up to whole lane groups, of
    /// `offsets[slot]` plus its `laneTerms` value: one `Int4` step, one add, and one min per
    /// `simd.lane_count` slots. Offsets in [0, `long_lane_cap`].
    pub fn offsetLowerBound(self: *const LinkBoxes, offsets: *const [long_link_pairs]i32, pair_count: u32, x: u32, y: u32, level: u16, rates: CrossingRates) u32 {
        std.debug.assert(pair_count >= 1 and pair_count <= long_link_pairs);
        const kernel = BoxTermKernel.init(x, y, level, rates);
        const scanned = std.mem.alignForward(usize, pair_count, simd.lane_count);
        var nearest = simd.splatInt4(std.math.maxInt(i32));
        var index: usize = 0;
        while (index < scanned) : (index += simd.lane_count) {
            // At most 2 * long_lane_cap, inside an i32.
            nearest = simd.minInt4(nearest, simd.addInt4(simd.loadInt4(offsets[index..]), kernel.terms(self, index)));
        }
        var least = nearest[0];
        inline for (1..simd.lane_count) |lane| least = @min(least, nearest[lane]);
        // A min of non-negative lane sums.
        return @intCast(least);
    }
};

// The box term of one query point against `simd.lane_count` boxes per step, its splats built
// once per scan.
const BoxTermKernel = struct {
    px: simd.Int4,
    py: simd.Int4,
    pl: simd.Int4,
    excess: simd.Int4,
    cost: simd.Int4,
    zero: simd.Int4,
    cardinal: simd.Int4,
    diagonal_extra: simd.Int4,
    cap: simd.Int4,

    fn init(x: u32, y: u32, level: u16, rates: CrossingRates) BoxTermKernel {
        std.debug.assert(x <= max_link_box_coord and y <= max_link_box_coord);
        std.debug.assert(rates.excess >= 0 and rates.excess <= crossing_rate_cap and rates.cost >= 0 and rates.cost <= crossing_rate_cap);
        // In range per the asserts: x, y < 2^16.
        return .{
            .px = simd.splatInt4(@intCast(x)),
            .py = simd.splatInt4(@intCast(y)),
            .pl = simd.splatInt4(level),
            .excess = simd.splatInt4(rates.excess),
            .cost = simd.splatInt4(rates.cost),
            .zero = simd.splatInt4(0),
            .cardinal = simd.splatInt4(cardinal_cost),
            .diagonal_extra = simd.splatInt4(diagonal_cost - cardinal_cost),
            .cap = simd.splatInt4(long_lane_cap),
        };
    }

    // Terms of boxes [index, index + lane_count), clamped to `long_lane_cap`. Unclamped a term
    // is below 2^20 + 2^30, inside an i32.
    fn terms(self: *const BoxTermKernel, boxes: *const LinkBoxes, index: usize) simd.Int4 {
        const zero = self.zero;
        // Distance to a box per axis: max(under-min, over-max, 0).
        const dx = simd.maxInt4(simd.maxInt4(simd.subInt4(simd.loadInt4(boxes.x0[index..]), self.px), simd.subInt4(self.px, simd.loadInt4(boxes.x1[index..]))), zero);
        const dy = simd.maxInt4(simd.maxInt4(simd.subInt4(simd.loadInt4(boxes.y0[index..]), self.py), simd.subInt4(self.py, simd.loadInt4(boxes.y1[index..]))), zero);
        const gap = simd.maxInt4(simd.maxInt4(simd.subInt4(simd.loadInt4(boxes.l0[index..]), self.pl), simd.subInt4(self.pl, simd.loadInt4(boxes.l1[index..]))), zero);
        const planar = simd.addInt4(simd.mulInt4(simd.maxInt4(dx, dy), self.cardinal), simd.mulInt4(simd.minInt4(dx, dy), self.diagonal_extra));
        const term = simd.maxInt4(simd.addInt4(planar, simd.mulInt4(gap, self.excess)), simd.mulInt4(gap, self.cost));
        return simd.minInt4(term, self.cap);
    }
};

/// Largest cell coordinate a `LinkBoxes` scan accepts: a world-backed grid's (`u16` sides).
pub const max_link_box_coord: u32 = std.math.maxInt(u16);

/// Up to `long_link_pairs` link pairs covering every folded directed long link: a pair is an
/// entrance box, an exit box, and a cost at most that of each link it holds (from its entrance
/// box to its exit box). Exact until the cap; past it the two candidates (the pairs and the new
/// link's point pair) whose merge adds the least entrance plus exit volume merge, keeping the
/// lesser cost, so a far link opens a pair of its own. A link whose endpoints some pair already
/// holds only lowers a cost: the pairs are a pure function of insert order and inserting again
/// changes nothing; no link is ever dropped. Slots past
/// `count` copy pair 0, so a scan over every slot equals one over `count`. Costs and chain
/// bounds are clamped to `long_lane_cap`.
pub const LinkPairs = struct {
    entrances: LinkBoxes = .{},
    exits: LinkBoxes = .{},
    cost: [long_link_pairs]i32 = @splat(0),
    /// `chain_to[r][p]`: a lower bound on the cost from a point of pair p's exit box, along
    /// short links and the links of further pairs, to a landing point in pair r's exit box
    /// (0 for r == p): the min-plus closure of exit-to-entrance box terms plus pair costs,
    /// under the crossing rates of the last `close`. Stored by r so a query takes pair-p
    /// lanes per r.
    chain_to: [long_link_pairs][long_link_pairs]i32 = @splat(@splat(0)),
    count: u32 = 0,

    // A link some pair holds at no more than its cost changes nothing; one only pricier pairs
    // hold lowers the first of them. Merge ties take the lowest candidates (i, j). At most
    // C(long_link_pairs + 1, 2) merge checks. Returns whether the pairs changed.
    fn insert(self: *LinkPairs, from: CellCoord, from_level: u16, to: CellCoord, to_level: u16, cost: i32) bool {
        std.debug.assert(cost >= 0 and cost <= long_lane_cap);
        var pricier_holder: ?usize = null;
        for (0..self.count) |index| {
            if (!self.entrances.boxAt(index).contains(from, from_level) or !self.exits.boxAt(index).contains(to, to_level)) continue;
            if (self.cost[index] <= cost) return false;
            if (pricier_holder == null) pricier_holder = index;
        }
        if (pricier_holder) |index| {
            self.cost[index] = cost;
            self.padFromFirst();
            return true;
        }
        const entrance = LinkBox.point(from.x, from.y, from_level);
        const exit = LinkBox.point(to.x, to.y, to_level);
        if (self.count < long_link_pairs) {
            self.entrances.setBox(self.count, entrance);
            self.exits.setBox(self.count, exit);
            self.cost[self.count] = cost;
            self.count += 1;
        } else {
            // Candidate `long_link_pairs` is the new link's point pair.
            var best_i: usize = 0;
            var best_j: usize = 1;
            var best_added: i64 = std.math.maxInt(i64);
            for (0..long_link_pairs) |i| {
                const entrance_i = self.entrances.boxAt(i);
                const exit_i = self.exits.boxAt(i);
                for (i + 1..long_link_pairs + 1) |j| {
                    const entrance_j = if (j == long_link_pairs) entrance else self.entrances.boxAt(j);
                    const exit_j = if (j == long_link_pairs) exit else self.exits.boxAt(j);
                    const added = entrance_i.mergeGrowth(entrance_j) + exit_i.mergeGrowth(exit_j);
                    if (added < best_added) {
                        best_i = i;
                        best_j = j;
                        best_added = added;
                    }
                }
            }
            const new_pair = best_j == long_link_pairs;
            const entrance_j = if (new_pair) entrance else self.entrances.boxAt(best_j);
            const exit_j = if (new_pair) exit else self.exits.boxAt(best_j);
            const cost_j = if (new_pair) cost else self.cost[best_j];
            self.entrances.setBox(best_i, self.entrances.boxAt(best_i).unionWith(entrance_j));
            self.exits.setBox(best_i, self.exits.boxAt(best_i).unionWith(exit_j));
            self.cost[best_i] = @min(self.cost[best_i], cost_j);
            if (!new_pair) {
                self.entrances.setBox(best_j, entrance);
                self.exits.setBox(best_j, exit);
                self.cost[best_j] = cost;
            }
        }
        self.padFromFirst();
        return true;
    }

    fn padFromFirst(self: *LinkPairs) void {
        for (self.count..long_link_pairs) |index| {
            self.entrances.setBox(index, self.entrances.boxAt(0));
            self.exits.setBox(index, self.exits.boxAt(0));
            self.cost[index] = self.cost[0];
        }
    }

    // Rebuilds `chain_to` from the pairs: Floyd-Warshall over edges p -> q weighted by the
    // box term from p's exit box to q's entrance box plus q's cost, in i64, then clamped.
    // Slots past `count` take pair 0's rows and columns. Fixed work: count^3 relaxes.
    fn close(self: *LinkPairs, rates: CrossingRates) void {
        const count = self.count;
        if (count == 0) return;
        var chain: [long_link_pairs][long_link_pairs]i64 = undefined;
        for (0..count) |from| {
            const exit = self.exits.boxAt(from);
            for (0..count) |to| {
                chain[from][to] = if (from == to) 0 else exit.termTo(self.entrances.boxAt(to), rates) + self.cost[to];
            }
        }
        for (0..count) |via| {
            for (0..count) |from| {
                for (0..count) |to| chain[from][to] = @min(chain[from][to], chain[from][via] + chain[via][to]);
            }
        }
        for (0..long_link_pairs) |to| {
            const to_pair = if (to < count) to else 0;
            for (0..long_link_pairs) |from| {
                const from_pair = if (from < count) from else 0;
                self.chain_to[to][from] = @intCast(@min(chain[from_pair][to_pair], long_lane_cap));
            }
        }
    }
};

/// Lower bounds on the abstract cost of the world's links, read by every abstract query and
/// folded once per link where links enter the graph (world build, marks commit), never per
/// query. A link is short when its cost (`traversal_cost +| inter_level_penalty`, the edge
/// cost) covers the planar octile between its endpoints, else long. Same-level short links
/// never lower a path's cost below its planar octile, so they fold nothing. Every fold is a
/// min, a max, or a pair insert that ignores a covered link, and a batch that changes the
/// pairs or the crossing rates recloses the pair chains once: the bounds are a pure function
/// of link order, and folding a link again changes nothing. Fixed size; never allocates.
pub const LinkBounds = struct {
    /// Most levels one level-crossing short link spans; 0 when none exists.
    short_span: u16 = 0,
    /// Least cost of a level-crossing short link.
    short_cost: u32 = unreachable_cost,
    /// Least excess of a level-crossing short link's cost over its endpoints' planar octile.
    short_excess: u32 = unreachable_cost,
    /// Least cost of a long link.
    long_cost: u32 = unreachable_cost,
    /// Every directed long link (a to b, and b to a when bidirectional), its chains closed
    /// under `crossingRates()`.
    pairs: LinkPairs = .{},

    fn foldLinks(self: *LinkBounds, links: []const LevelLink) void {
        const rates = self.crossingRates();
        var pairs_changed = false;
        for (links) |link| {
            if (self.foldLink(link)) pairs_changed = true;
        }
        const folded_rates = self.crossingRates();
        if (pairs_changed or !std.meta.eql(rates, folded_rates)) self.pairs.close(folded_rates);
    }

    // Returns whether the pairs changed.
    fn foldLink(self: *LinkBounds, link: LevelLink) bool {
        const cost = link.traversal_cost +| inter_level_penalty;
        const planar = octileU32(link.cell_a.x, link.cell_a.y, link.cell_b.x, link.cell_b.y);
        if (planar > cost) {
            self.long_cost = @min(self.long_cost, cost);
            const lane_cost: i32 = @intCast(@min(cost, long_lane_cap));
            var changed = self.pairs.insert(link.cell_a, link.level_a, link.cell_b, link.level_b, lane_cost);
            if (link.bidirectional and self.pairs.insert(link.cell_b, link.level_b, link.cell_a, link.level_a, lane_cost)) changed = true;
            return changed;
        }
        if (link.level_a == link.level_b) return false;
        self.short_span = @max(self.short_span, @max(link.level_a, link.level_b) - @min(link.level_a, link.level_b));
        self.short_cost = @min(self.short_cost, cost);
        self.short_excess = @min(self.short_excess, cost - planar);
        return false;
    }

    /// The per-level crossing rates of the folded short links.
    pub fn crossingRates(self: *const LinkBounds) CrossingRates {
        if (self.short_span == 0) return .{ .excess = crossing_rate_cap, .cost = crossing_rate_cap };
        return .{
            .excess = @intCast(@min(self.short_excess / self.short_span, crossing_rate_cap)),
            .cost = @intCast(@min(self.short_cost / self.short_span, crossing_rate_cap)),
        };
    }
};

// Per-level cell grids and chunk records, built from a world (or bounds) and changed only
// through `commitMarks` and `buildLevel` on the main thread; read-only to queries between.
pub const NavGraph = struct {
    allocator: std.mem.Allocator,
    cell_size: f32 = default_cell_size,
    width: usize = 0,
    height: usize = 0,
    chunk_tiles: u16 = default_nav_chunk_tiles,
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
    /// Connectivity ids over every level's nodes, maintained by every batch.
    connectivity: Connectivity = .{},
    // The world-wide content revision every level was last checked against.
    built_world_revision: u32 = 0,
    // Batch buffers, reused across batches. `changed_masks` holds, per changed key of the
    // last marks batch, the cells it flipped, valid until the next batch.
    changed_keys: KeyList = .empty,
    changed_masks: std.ArrayList(ChunkBits) = .empty,
    // Per changed key: the block slot its remask may fill (`no_block` when it can only end
    // uniform) and its blocked-count delta.
    remask_slots: std.ArrayList(u32) = .empty,
    remask_deltas: std.ArrayList(i32) = .empty,
    patch_keys: KeyList = .empty,
    // The batch result's keys: the changed keys plus both endpoint chunks of each new link.
    dirty_keys: KeyList = .empty,
    // Plan stage staging (per-range key windows, one list per stream), tallies, and the
    // merge heap.
    plan_staging: [plan_streams]KeyList = @splat(.empty),
    plan_windows: std.ArrayList(PlanWindow) = .empty,
    plan_tallies: std.ArrayListAligned(PlanTally, .fromByteUnits(thread_shared_record_alignment)) = .empty,
    merge_heap: std.ArrayList(MergeHead) = .empty,
    patch_info: std.ArrayList(PatchInfo) = .empty,
    // Batch shape of the most recent patch / remask stage, for bench and diagnostic
    // reporting. Not part of the graph contract.
    last_plan_batch: BatchStats = .{},
    last_patch_batch: BatchStats = .{},
    last_remask_batch: BatchStats = .{},
    // Set between a prepared marks batch and its commit or abort.
    batch_prepared: bool = false,
    /// Telemetry: record and link-slot pool growths. The first logs once.
    pool_grows: u64 = 0,
    pool_growth_logged: bool = false,

    pub fn deinit(self: *NavGraph) void {
        self.connectivity.deinit(self.allocator);
        self.merge_heap.deinit(self.allocator);
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
        return self.width * self.height;
    }

    /// The portals and links of `level`'s `chunk`; empty for an unbuilt level or a chunk
    /// with no record.
    pub inline fn chunkPortals(self: *const NavGraph, level: u16, chunk: u32) ChunkPortals {
        if (@as(usize, level) >= self.level_graphs.items.len) return .{};
        return self.level_graphs.items[level].chunkPortals(chunk);
    }

    /// Portals across every record of every level (diagnostic and test helper).
    pub fn totalPortals(self: *const NavGraph) usize {
        var count: usize = 0;
        for (0..self.level_graphs.items.len) |level| count += self.levelLivePortalCount(@intCast(level));
        return count;
    }

    /// Portals across every record of one level (diagnostic and test helper).
    pub fn levelLivePortalCount(self: *const NavGraph, level: u16) usize {
        const level_graph = self.levelGraph(level) orelse return 0;
        var count: usize = 0;
        for (0..level_graph.record_dir.items.len) |chunk| count += level_graph.chunkPortals(@intCast(chunk)).portalCount();
        return count;
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
            self.merge_heap.capacity * @sizeOf(MergeHead);
        for (self.plan_staging) |staging| bytes += staging.capacity * @sizeOf(u64);
        for (self.levels.items) |*level_grid| bytes += level_grid.residentBytes();
        for (self.level_graphs.items) |*level_graph| bytes += level_graph.residentBytes();
        bytes += self.connectivity.residentBytes();
        return bytes;
    }

    // Chunk-tiling geometry for this graph; agrees with every level's NavGrid.
    fn chunkGeometry(self: *const NavGraph) types.ChunkGeometry {
        return .{ .width = self.width, .height = self.height, .chunk_tiles = self.chunk_tiles };
    }

    fn chunksX(self: *const NavGraph) usize {
        return self.chunkGeometry().chunksX();
    }

    fn chunksY(self: *const NavGraph) usize {
        return self.chunkGeometry().chunksY();
    }

    pub fn chunkCount(self: *const NavGraph) usize {
        return self.chunksX() * self.chunksY();
    }

    pub fn chunkOf(self: *const NavGraph, cell_index: usize) u32 {
        return self.chunkGeometry().chunkOf(cell_index);
    }

    /// Chunk-local index (`row * chunk_tiles + column`) of a cell within its chunk.
    pub fn localOf(self: *const NavGraph, cell_index: usize) u8 {
        const ct: usize = self.chunk_tiles;
        const x = (cell_index % self.width) % ct;
        const y = (cell_index / self.width) % ct;
        // A chunk holds at most max_chunk_size_tiles^2 <= 256 cells.
        return @intCast(y * ct + x);
    }

    /// The cell at chunk-local index `local` of `chunk`.
    pub fn cellOfLocal(self: *const NavGraph, chunk: u32, local: u8) u32 {
        const ct: usize = self.chunk_tiles;
        const bounds = self.chunkGeometry().chunkBounds(chunk);
        const x = bounds.x0 + @as(usize, local) % ct;
        const y = bounds.y0 + @as(usize, local) / ct;
        // Cells of a validated grid are below no_cell.
        return @intCast(y * self.width + x);
    }

    // Rebuilds every level into a fresh graph and swaps it in, folding every world link into
    // fresh link bounds. The previous graph stays intact until every level built, so an error
    // leaves it unchanged. Bumps `version`.
    // `colliders` must be placed on this extent's cell grid (`NavExtent.colliderGeometry`).
    pub fn rebuild(
        self: *NavGraph,
        colliders: ColliderView,
        extent: NavExtent,
        threads: ?NavUpdateThreads,
    ) !void {
        const world: ?*const WorldSystem = switch (extent) {
            .world => |world_system| world_system,
            .bounds => null,
        };
        const cells = extent.cellGrid();
        const safe_cell_size = cells.cell_size;
        const width = cells.width;
        const height = cells.height;
        const chunk_tiles = cells.chunk_tiles;
        // Cell indices and chunk labels are u32 below `no_cell`; fail loud before any
        // dimension is stored or array sized.
        try validateChunkGrid(width, height, chunk_tiles);
        if (colliders.geometry) |geometry| {
            std.debug.assert(geometry.cell_size == safe_cell_size and geometry.width == width and
                geometry.height == height and geometry.chunk_tiles == chunk_tiles);
        }

        var version = self.version +% 1;
        if (version == 0) version = 1;
        var fresh = NavGraph{
            .allocator = self.allocator,
            .cell_size = safe_cell_size,
            .width = width,
            .height = height,
            .chunk_tiles = chunk_tiles,
            .version = version,
            .world_backed = world != null,
        };
        errdefer fresh.deinit();
        // A world builds exactly its levels; bounds build one.
        const level_count: usize = if (world) |world_system| world_system.levelCount() else 1;
        try fresh.levels.ensureTotalCapacity(self.allocator, level_count);
        try fresh.level_graphs.ensureTotalCapacity(self.allocator, level_count);
        var stats = NavUpdateStats{};
        for (0..level_count) |level| try fresh.buildLevel(colliders, world, @intCast(level), threads, &stats);
        // The one-way closure over every level at once, after the levels and before the swap.
        const fresh_levels = BatchLevels{ .grids = fresh.levels.items, .graphs = fresh.level_graphs.items };
        const closure_counters = try fresh.connectivity.buildClosure(self.allocator, fresh_levels, world, closureThreads(threads), &fresh.pool_grows, &stats);
        addClosureStats(&stats, &fresh.connectivity, closure_counters);
        if (world) |world_system| {
            fresh.link_bounds.foldLinks(world_system.levelLinks());
            fresh.links_applied = world_system.levelLinks().len;
            fresh.built_world_revision = world_system.contentRevision();
        }
        fresh.pool_grows = self.pool_grows + fresh.pool_grows;
        fresh.pool_growth_logged = self.pool_growth_logged;
        self.deinit();
        self.* = fresh;
        if (comptime logging.enabled(.info) and !builtin.is_test)
            logging.game.info("nav built: {} levels, {} resident bytes", .{ self.levels.items.len, self.residentBytes() });
    }

    /// Builds level `level_index` from `world` (or bounds when null) into fresh storage and
    /// swaps it in: appended when `level_index == levelCount()`, else replacing that level and
    /// freeing the old one, with its connectivity nodes. An error leaves the graph unchanged.
    /// O(chunks of the level + its nodes and edges); the remask, patch, and connectivity
    /// stages thread over its chunks (the flood over its searches). Never touches
    /// `links_applied`.
    pub fn buildLevel(self: *NavGraph, colliders: ColliderView, world: ?*const WorldSystem, level_index: u16, threads: ?NavUpdateThreads, stats: *NavUpdateStats) !void {
        std.debug.assert(@as(usize, level_index) <= self.levels.items.len);
        const chunk_count = self.chunkCount();
        var section = StageTimer.begin();
        var fresh_grid = NavGrid{};
        errdefer fresh_grid.deinit(self.allocator);
        try fresh_grid.prepare(self.allocator, level_index, self.width, self.height, self.cell_size, self.chunk_tiles);
        var fresh_graph = NavLevelGraph{ .border_stride = borderPortalBound(self.chunk_tiles) };
        errdefer fresh_graph.deinit(self.allocator);
        try setLen(&fresh_graph.record_dir, self.allocator, chunk_count);
        @memset(fresh_graph.record_dir.items, no_record);
        stats.main.reserve_ns += section.lap();

        // Plan: every chunk of the level, in order.
        section = StageTimer.begin();
        try setLen(&self.changed_keys, self.allocator, chunk_count);
        try setLen(&self.patch_keys, self.allocator, chunk_count);
        // The marks batch's key lists share the build's one-level window high-water.
        try self.dirty_keys.ensureTotalCapacity(self.allocator, chunk_count);
        self.dirty_keys.clearRetainingCapacity();
        for (0..chunk_count) |chunk| {
            const key = chunkKey(level_index, @intCast(chunk));
            self.changed_keys.items[chunk] = key;
            self.patch_keys.items[chunk] = key;
        }
        stats.main.plan_ns += section.lap();
        // Reserve.
        section = StageTimer.begin();
        const appending = @as(usize, level_index) == self.levels.items.len;
        if (appending) {
            try self.levels.ensureUnusedCapacity(self.allocator, 1);
            try self.level_graphs.ensureUnusedCapacity(self.allocator, 1);
        }
        const levels = BatchLevels{
            .grids = self.levels.items,
            .graphs = self.level_graphs.items,
            .fresh = .{ .index = level_index, .grid = &fresh_grid, .graph = &fresh_graph },
        };
        try self.planPatchInfo(world);
        try self.reserveCellBlocks(levels, world, colliders);
        try self.reserveRecords(levels);
        stats.main.reserve_ns += section.lap();

        // Commit into the fresh storage.
        self.remaskKeys(levels, colliders, world, null, remaskThreads(threads), stats);
        section = StageTimer.begin();
        self.claimRecords(levels);
        stats.main.commit_ns += section.lap();
        self.patchKeys(levels, world, patchThreads(threads), stats);
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
            connSeedThreads(threads),
            connGatherThreads(threads),
            connFloodThreads(threads),
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
        } else {
            self.levels.items[level_index].deinit(self.allocator);
            self.level_graphs.items[level_index].deinit(self.allocator);
            self.levels.items[level_index] = fresh_grid;
            self.level_graphs.items[level_index] = fresh_graph;
        }
        stats.main.commit_ns += section.lap();
        stats.levels_built += 1;
        self.logPoolGrowth();
    }

    /// The links of `world` not yet folded into records.
    pub fn newLinks(self: *const NavGraph, world: *const WorldSystem) []const LevelLink {
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
    ) !?PreparedMarks {
        std.debug.assert(!self.batch_prepared);
        if (!self.valid()) return null;
        const new_links = self.newLinks(world);
        if (marks.len == 0 and new_links.len == 0) return null;
        const prepared = PreparedMarks{
            .marks = marks,
            .new_link_count = new_links.len,
            .world = if (self.world_backed) world else null,
        };
        try self.planKeys(world, marks, new_links, planThreads(threads), stats);
        var section = StageTimer.begin();
        try setLen(&self.changed_masks, self.allocator, self.changed_keys.items.len);
        if (self.patch_keys.items.len != 0) {
            const levels = BatchLevels{ .grids = self.levels.items, .graphs = self.level_graphs.items };
            try self.planPatchInfo(prepared.world);
            try self.reserveCellBlocks(levels, prepared.world, colliders);
            try self.reserveRecords(levels);
            stats.main.reserve_ns += section.lap();
            try self.connectivity.prepareMarks(
                self.allocator,
                levels,
                prepared.world,
                self.changed_keys.items,
                self.patch_keys.items,
                self.patch_info.items,
                new_links,
                connSeedThreads(threads),
                closureThreads(threads),
                &self.pool_grows,
                stats,
            );
            section = StageTimer.begin();
        }
        // The one-way registry rows the commit appends for the new links.
        try self.connectivity.reserveRegistry(self.allocator, new_links, &self.pool_grows);
        stats.main.reserve_ns += section.lap();
        self.batch_prepared = true;
        return prepared;
    }

    /// Commits a prepared batch, the infallible half: folds the batch's new links into
    /// `link_bounds` (O(1) each, a long one a fixed pair insert, then one fixed pair chain
    /// closure when the batch changed the pairs or crossing rates), remasks the changed chunks from
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
        self.link_bounds.foldLinks(new_links);
        self.links_applied += prepared.new_link_count;
        self.connectivity.appendRegistry(new_links);
        stats.main.commit_ns += section.lap();
        if (self.patch_keys.items.len == 0) return .{ .changed = false, .dirty_keys = &.{}, .changed_keys = &.{}, .changed_masks = &.{} };
        const levels = BatchLevels{ .grids = self.levels.items, .graphs = self.level_graphs.items };
        std.debug.assert(self.changed_masks.items.len == self.changed_keys.items.len);
        self.remaskKeys(levels, colliders, prepared.world, self.changed_masks.items, remaskThreads(threads), stats);
        section = StageTimer.begin();
        self.claimRecords(levels);
        stats.main.commit_ns += section.lap();
        self.patchKeys(levels, prepared.world, patchThreads(threads), stats);
        const counters = self.connectivity.commitMarks(levels, prepared.world, self.patch_keys.items, new_links, connGatherThreads(threads), connFloodThreads(threads), closureThreads(threads), stats);
        addConnectivityStats(stats, &self.connectivity, counters);
        section = StageTimer.begin();
        stats.records_patched += self.releaseRecords(levels);
        stats.main.commit_ns += section.lap();
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

    fn logPoolGrowth(self: *NavGraph) void {
        if (self.pool_grows == 0 or self.pool_growth_logged) return;
        self.pool_growth_logged = true;
        if (comptime logging.enabled(.info) and !builtin.is_test)
            logging.game.info("nav record pools grew ({} growths so far)", .{self.pool_grows});
    }

    // A mark's inclusive nav-cell span, or null when it misses every built level.
    fn markSpan(self: *const NavGraph, world: *const WorldSystem, mark: NavMark) ?NavSpan {
        if (@as(usize, mark.level) >= self.levels.items.len) return null;
        return switch (mark.kind) {
            .tile_box => self.levels.items[mark.level].cellSpanForTileBox(world, mark.min_x, mark.min_y, mark.max_x, mark.max_y),
            .static_span => .{ .min_x = mark.min_x, .min_y = mark.min_y, .max_x = mark.max_x, .max_y = mark.max_y },
        };
    }

    // Upper bounds of the keys item `item` (marks, then new links) writes per stream. O(1).
    fn itemKeyBounds(self: *const NavGraph, world: *const WorldSystem, marks: []const NavMark, item: usize) [plan_streams]usize {
        if (item < marks.len) {
            const span = self.markSpan(world, marks[item]) orelse return @splat(0);
            const ct: usize = self.chunk_tiles;
            const chunks = (span.max_x / ct - span.min_x / ct + 1) * (span.max_y / ct - span.min_y / ct + 1);
            return .{ chunks, chunks, chunks * 5 };
        }
        return .{ 0, 2, 2 };
    }

    // Writes item `item`'s keys at each stream's cursor. Reads only the graph's geometry and
    // the world, so plan ranges run in parallel.
    fn writeItemKeys(self: *const NavGraph, world: *const WorldSystem, marks: []const NavMark, links: []const LevelLink, item: usize, staging: [plan_streams][]u64, ends: *[plan_streams]usize) void {
        const changed = @backingInt(PlanStream.changed);
        const dirty = @backingInt(PlanStream.dirty);
        const patch = @backingInt(PlanStream.patch);
        const cx_count = self.chunksX();
        const cy_count = self.chunksY();
        if (item < marks.len) {
            const mark = marks[item];
            const span = self.markSpan(world, mark) orelse return;
            const ct: usize = self.chunk_tiles;
            var cy = span.min_y / ct;
            while (cy <= span.max_y / ct) : (cy += 1) {
                var cx = span.min_x / ct;
                while (cx <= span.max_x / ct) : (cx += 1) {
                    const chunk: u32 = @intCast(cy * cx_count + cx);
                    for ([_]usize{ changed, dirty, patch }) |stream| {
                        staging[stream][ends[stream]] = chunkKey(mark.level, chunk);
                        ends[stream] += 1;
                    }
                    const neighbours = [_]struct { present: bool, chunk: usize }{
                        .{ .present = cx > 0, .chunk = chunk -% 1 },
                        .{ .present = cx + 1 < cx_count, .chunk = chunk +% 1 },
                        .{ .present = cy > 0, .chunk = chunk -% cx_count },
                        .{ .present = cy + 1 < cy_count, .chunk = chunk +% cx_count },
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
                const key = chunkKey(end[0], self.chunkOf(@as(usize, end[1].y) * self.width + end[1].x));
                for ([_]usize{ dirty, patch }) |stream| {
                    staging[stream][ends[stream]] = key;
                    ends[stream] += 1;
                }
            }
        }
    }

    // Plans a marks batch: the changed, dirty, and patch keys (see `PlanStream`), each sorted
    // and deduped. Threaded over marks and new links: each
    // range writes, sorts, and dedupes its own key windows; the main thread sizes the windows
    // (O(1) per item) and merges them in range order, O(keys log ranges). Inline it is one
    // range: one sort and no merge.
    fn planKeys(self: *NavGraph, world: *const WorldSystem, marks: []const NavMark, new_links: []const LevelLink, threads: ?NavStageThreads, stats: *NavUpdateStats) !void {
        const item_count = marks.len + new_links.len;
        for (std.meta.tags(PlanStream)) |stream| self.keyList(stream).clearRetainingCapacity();
        self.last_plan_batch = .{};
        if (item_count == 0) return;
        var section = StageTimer.begin();
        const selection: BatchSelectionShape = if (threads) |stage| blk: {
            const selected = stage.thread_system.selectBatchProfile(stage.tuner, .{
                .item_count = item_count,
                .items_per_range = stage.items_per_range,
                .range_alignment_items = 1,
                .adaptive = stage.adaptive,
            });
            break :blk .{ .range_count = selected.range_count, .items_per_range = selected.items_per_range, .selection = selected };
        } else .{ .range_count = 1, .items_per_range = item_count, .selection = null };

        // Windows: each range's key bounds, starting on a cache line.
        try setLen(&self.plan_windows, self.allocator, selection.range_count);
        try setLen(&self.plan_tallies, self.allocator, selection.range_count);
        try self.merge_heap.ensureTotalCapacity(self.allocator, selection.range_count);
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
        for (&self.plan_staging, totals, &staging) |*list, total, *slice| {
            try setLen(list, self.allocator, total);
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
        stats.main.plan_ns += section.lap();
        if (threads) |stage| {
            const selected = selection.selection.?;
            self.last_plan_batch = stage.thread_system.parallelForWithOptions(item_count, &job, planJob, .{
                .adaptive = stage.adaptive,
                .adaptive_tuner = selected.active_tuner,
                .items_per_range = stage.items_per_range,
                .range_alignment_items = 1,
                .selected_profile = selected.profile,
            });
        } else {
            const stage_timer = StageTimer.begin();
            planJob(&job, .{ .start = 0, .end = item_count, .index = 0 }, WorkerId.main);
            self.last_plan_batch = inlineBatch(item_count);
            self.last_plan_batch.batch_duration_ns = stage_timer.lap();
        }
        stats.addStageTime(self.last_plan_batch);

        section = StageTimer.begin();
        defer stats.main.plan_ns += section.lap();
        for (std.meta.tags(PlanStream)) |stream| {
            const out = self.keyList(stream);
            if (selection.range_count == 1) {
                // One range: its windows start at 0 and hold the sorted unique keys.
                std.mem.swap(KeyList, out, &self.plan_staging[@backingInt(stream)]);
                out.items.len = self.plan_tallies.items[0].counts[@backingInt(stream)];
            } else {
                try self.mergeWindows(stream);
            }
        }
    }

    fn keyList(self: *NavGraph, stream: PlanStream) *KeyList {
        return switch (stream) {
            .changed => &self.changed_keys,
            .dirty => &self.dirty_keys,
            .patch => &self.patch_keys,
        };
    }

    const BatchSelectionShape = struct {
        range_count: usize,
        items_per_range: usize,
        selection: ?BatchSelection,
    };

    // Merges the plan ranges' sorted unique windows into one sorted unique key list, in
    // range order: a heap of one head per range, O(keys log ranges).
    fn mergeWindows(self: *NavGraph, stream_tag: PlanStream) !void {
        const stream = @backingInt(stream_tag);
        const out = self.keyList(stream_tag);
        const staging = self.plan_staging[stream].items;
        var total: usize = 0;
        for (self.plan_tallies.items) |tally| total += tally.counts[stream];
        try out.ensureTotalCapacity(self.allocator, total);
        out.clearRetainingCapacity();
        const heap = &self.merge_heap;
        heap.clearRetainingCapacity();
        for (self.plan_windows.items, self.plan_tallies.items, 0..) |*window, tally, range_index| {
            window.next[stream] = window.start[stream] + 1;
            if (tally.counts[stream] == 0) continue;
            heap.appendAssumeCapacity(.{ .key = staging[window.start[stream]], .range = @intCast(range_index) });
            siftMergeUp(heap.items, heap.items.len - 1);
        }
        while (heap.items.len != 0) {
            const head = heap.items[0];
            if (out.items.len == 0 or out.items[out.items.len - 1] != head.key) out.appendAssumeCapacity(head.key);
            const window = &self.plan_windows.items[head.range];
            const end = window.start[stream] + self.plan_tallies.items[head.range].counts[stream];
            if (window.next[stream] < end) {
                heap.items[0] = .{ .key = staging[window.next[stream]], .range = head.range };
                window.next[stream] += 1;
            } else {
                heap.items[0] = heap.items[heap.items.len - 1];
                heap.items.len -= 1;
            }
            if (heap.items.len != 0) siftMergeDown(heap.items, 0);
        }
    }

    // Per patch key: its link endpoints on the level (an O(1) count) and whether it may hold
    // portals. A chunk whose world form is BLOCKED holds none
    // (statics only add blocked cells), and one whose orthogonal neighbours are all BLOCKED
    // has no border run, so it needs a record only for an endpoint. O(keys + endpoints).
    fn planPatchInfo(self: *NavGraph, world: ?*const WorldSystem) !void {
        try setLen(&self.patch_info, self.allocator, self.patch_keys.items.len);
        const cx_count = self.chunksX();
        const cy_count = self.chunksY();
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
        var start: usize = 0;
        while (start < keys.len) {
            const level = keyLevel(keys[start]);
            var end = start + 1;
            while (end < keys.len and keyLevel(keys[end]) == level) end += 1;
            const level_graph = levels.graph(level);
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
                try growSlotList(NavPortal, &level_graph.slot_extra[slot], self.allocator, info.endpoints, &self.pool_grows);
                try growSlotList(NavLink, &level_graph.slot_links[slot], self.allocator, info.endpoints, &self.pool_grows);
            }
            start = end;
        }
    }

    // Per changed key, the block slot its remask may fill: the one its chunk holds, a claim
    // when the chunk may end mixed (`chunkMayMix`), or none. Grows each level's block pool
    // to cover the claims (worst case: every such key ends mixed). O(keys).
    fn reserveCellBlocks(self: *NavGraph, levels: BatchLevels, world: ?*const WorldSystem, colliders: ColliderView) !void {
        const keys = self.changed_keys.items;
        try setLen(&self.remask_slots, self.allocator, keys.len);
        try setLen(&self.remask_deltas, self.allocator, keys.len);
        var start: usize = 0;
        while (start < keys.len) {
            const level = keyLevel(keys[start]);
            var end = start + 1;
            while (end < keys.len and keyLevel(keys[end]) == level) end += 1;
            const level_grid = levels.grid(level);
            var claims: usize = 0;
            for (keys[start..end], self.remask_slots.items[start..end]) |key, *slot| {
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
            start = end;
        }
    }

    // Claims the planned block slots in key order and seeds each key's delta with its
    // chunk's old blocked count; then remasks every changed key (threaded over keys) and,
    // in key order, releases the slots whose chunk ended uniform and applies the deltas.
    fn remaskKeys(self: *NavGraph, levels: BatchLevels, colliders: ColliderView, world: ?*const WorldSystem, masks: ?[]ChunkBits, threads: ?NavStageThreads, stats: *NavUpdateStats) void {
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
        stats.main.commit_ns += section.lap();
        self.last_remask_batch = runStage(threads, keys.len, &job, &job.range_count, remaskJob);
        stats.addStageTime(self.last_remask_batch);
        section = StageTimer.begin();
        for (keys, self.remask_slots.items, self.remask_deltas.items) |key, slot, delta| {
            const level_grid = levels.grid(keyLevel(key));
            if (slot != no_block and level_grid.chunkBlock(keyChunk(key)) != slot) level_grid.releaseBlock(slot);
            const count: isize = @as(isize, @intCast(level_grid.blocked_count)) + delta;
            std.debug.assert(count >= 0);
            level_grid.blocked_count = @intCast(@max(count, 0));
        }
        stats.main.commit_ns += section.lap();
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

    fn patchKeys(self: *NavGraph, levels: BatchLevels, world: ?*const WorldSystem, threads: ?NavStageThreads, stats: *NavUpdateStats) void {
        var job = PatchJob{ .graph = self, .levels = levels, .world = world, .keys = self.patch_keys.items, .infos = self.patch_info.items };
        self.last_patch_batch = runStage(threads, self.patch_keys.items.len, &job, &job.range_count, patchJob);
        stats.addStageTime(self.last_patch_batch);
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
        const w = self.width;
        const cols = bounds.x1 - bounds.x0;
        const rows = bounds.y1 - bounds.y0;
        const shift: u4 = level_grid.chunk_shift;
        const chunks_x = self.chunksX();
        var portals: [max_border_portals]NavPortal = undefined;
        var count: usize = 0;
        const Side = NavGrid.ChunkSide;
        const sides = [_]struct { present: bool, side: Side, mirror: Side, neighbour: u32, length: usize, flags: PortalFlags }{
            .{ .present = bounds.x0 > 0, .side = .west, .mirror = .east, .neighbour = chunk -% 1, .length = rows, .flags = .{ .west = true } },
            .{ .present = bounds.x1 < w, .side = .east, .mirror = .west, .neighbour = chunk +% 1, .length = rows, .flags = .{ .east = true } },
            .{ .present = bounds.y0 > 0, .side = .north, .mirror = .south, .neighbour = chunk -% @as(u32, @intCast(chunks_x)), .length = cols, .flags = .{ .north = true } },
            .{ .present = bounds.y1 < self.height, .side = .south, .mirror = .north, .neighbour = chunk +% @as(u32, @intCast(chunks_x)), .length = cols, .flags = .{ .south = true } },
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
        std.sort.insertion(NavPortal, portals[0..count], {}, portalLessThan);

        const slot = level_graph.record_link_slot[record];
        if (slot != no_link_slot) {
            const extra = &level_graph.slot_extra[slot];
            const links = &level_graph.slot_links[slot];
            extra.clearRetainingCapacity();
            links.clearRetainingCapacity();
            if (world) |world_system| {
                var endpoints = world_system.levelChunkLinkEndpoints(level, chunk);
                while (endpoints.next()) |endpoint| {
                    const cell = @as(usize, endpoint.cell.y) * w + endpoint.cell.x;
                    if (level_grid.isBlockedIndex(cell)) continue;
                    const local = self.localOf(cell);
                    if (findLocal(portals[0..count], local)) |existing| {
                        portals[existing].flags.link = true;
                    } else if (findLocalLinear(extra.items, local) == null) {
                        // The reserve sized the slot's lists to the planned endpoint count.
                        std.debug.assert(extra.items.len < endpoint_limit);
                        extra.appendAssumeCapacity(.{ .local = local, .label = level_grid.labelAt(cell), .flags = .{ .link = true } });
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
            std.sort.pdq(NavPortal, extra.items, {}, portalLessThan);
            std.sort.pdq(NavLink, links.items, {}, linkLessThan);
        }
        const base = @as(usize, record) * level_graph.border_stride;
        @memcpy(level_graph.border.items[base .. base + count], portals[0..count]);
        // At most max_border_portals (32) border portals.
        level_graph.border_count[record] = @intCast(count);
        var labels: [4]u64 = @splat(0);
        for (portals[0..count]) |portal| labels[portal.label >> 6] |= @as(u64, 1) << @intCast(portal.label & 63);
        if (slot != no_link_slot) {
            for (level_graph.slot_extra[slot].items) |portal| labels[portal.label >> 6] |= @as(u64, 1) << @intCast(portal.label & 63);
        }
        var label_count: usize = 0;
        for (labels) |word| label_count += @popCount(word);
        // At most 128 labels fit a chunk.
        level_graph.record_label_count[record] = @intCast(label_count);
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

fn siftMergeUp(heap: []MergeHead, start: usize) void {
    var index = start;
    while (index != 0) {
        const parent = (index - 1) / 2;
        if (!heap[index].lessThan(heap[parent])) break;
        std.mem.swap(MergeHead, &heap[index], &heap[parent]);
        index = parent;
    }
}

fn siftMergeDown(heap: []MergeHead, start: usize) void {
    var index = start;
    while (true) {
        const left = index * 2 + 1;
        if (left >= heap.len) break;
        var best = left;
        if (left + 1 < heap.len and heap[left + 1].lessThan(heap[left])) best = left + 1;
        if (!heap[best].lessThan(heap[index])) break;
        std.mem.swap(MergeHead, &heap[index], &heap[best]);
        index = best;
    }
}

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
const abstractCapacity = test_support.abstractCapacity;
const baselineCapacity = test_support.baselineCapacity;
const addNavBody = test_support.addNavBody;
const loadTestWorldMeta = test_support.loadTestWorldMeta;
const requireTestTile = test_support.requireTestTile;
const NavCellEdit = types.NavCellEdit;
const no_component = types.no_component;
const PathStatus = types.PathStatus;
const appendPathRequest = test_support.appendPathRequest;
const RangeOutputStream = @import("../../simulation.zig").RangeOutputStream;
const StructuralCommand = @import("../../data_system.zig").StructuralCommand;
const EntityTemplate = @import("../../data_system.zig").EntityTemplate;
const PathRequest = @import("../../simulation.zig").PathRequest;
const TileId = @import("../../world_system.zig").TileId;
const DenseCellWrite = @import("../../world_system.zig").DenseCellWrite;
const DenseChunkWrites = @import("../../world_system.zig").DenseChunkWrites;
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
        if (ga.chunkForm(chunk) != gb.chunkForm(chunk)) return false;
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
    return graph.chunkPortals(level, graph.chunkOf(cell)).find(graph.localOf(cell)) != null;
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

    const edits = [_]NavCellEdit{
        .{ .level = 1, .x = 3, .y = 3 },
        .{ .level = 1, .x = 4, .y = 3 },
        .{ .level = 0, .x = 2, .y = 2 },
    };
    _ = try system.applyNavUpdates(no_colliders, &world, &edits);

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
    threaded.nav_thread_adaptive = false;
    threaded.nav_thread_items_per_range = 1;
    try threaded.rebuildStaticNavGridWithWorld(&data, &world, &threads);
    try std.testing.expect(!threaded.graph.last_remask_batch.ran_inline);
    try std.testing.expect(!threaded.graph.last_patch_batch.ran_inline);

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
    var edits = std.ArrayList(NavCellEdit).empty;
    defer edits.deinit(std.testing.allocator);
    var wy: u16 = 4;
    while (wy <= 7) : (wy += 1) {
        const changed = (try world.setDenseTile(wall_layer, 5, wy, tree)) orelse return error.TestExpectedEqual;
        try edits.append(std.testing.allocator, .{ .level = changed.level, .x = changed.x, .y = changed.y });
    }
    _ = try system.applyNavUpdates(no_colliders, &world, edits.items);

    // After: the chunk-local component split into two distinct labels.
    try std.testing.expect(grid.componentOf(left) != no_component);
    try std.testing.expect(grid.componentOf(right) != no_component);
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
    const neighbor_label_before = grid.componentOf(neighbor);

    // Block (3,5) on the chunk (0,1) side: the (3,5)|(4,5) portal pair disappears, so
    // the NEIGHBOR chunk (1,1)'s portal at (4,5) flips off even though only chunk (0,1)
    // is relabeled.
    const changed = (try world.setDenseTile(isolation_layer, 3, 5, tree)) orelse return error.TestExpectedEqual;
    _ = try system.applyNavUpdates(no_colliders, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});

    try std.testing.expect(!isPortal(&system.graph, 0, near));
    try std.testing.expect(!isPortal(&system.graph, 0, neighbor));
    // The neighbor chunk's component labels were NOT recomputed: (4,5) keeps its label.
    try std.testing.expectEqual(neighbor_label_before, grid.componentOf(neighbor));

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, null);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

// Regression guard for the border-run rule: an open chunk border must
// yield ONE portal per contiguous open run, not one per open cell — an obstacle-free area
// is the WORST case for portal density under the old per-cell scheme (a wall only ever
// removes boundary cells from candidacy), which made the abstract chunk-portal search
// needlessly expensive exactly where it should be cheapest. A fully-interior chunk with all four borders open has at most one live
// portal per side (4), never one per open boundary cell (up to chunk_tiles per side).
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
test "incremental nav update opening a ramp endpoint adds a live LevelLink edge" {
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
    _ = try system.applyNavUpdates(no_colliders, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
    // The bidirectional link is live both ways.
    try std.testing.expectEqual(@as(usize, 2), countLiveLinks(&system.graph));

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, null);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "incremental underground dig leaves the surface level abstract graph byte-identical" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    // Open 12x12 surface (level 0) spanning many 4-tile chunks, plus an underground
    // level 1 with a diggable obstacle. The surface graph is large (the regression the
    // per-level split targets); an underground dig must do ZERO work on it.
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
    try std.testing.expect(system.graph.levelLivePortalCount(0) > 0);
    const record_dir_before = try std.testing.allocator.dupe(u32, system.graph.levelGraph(0).?.record_dir.items);
    defer std.testing.allocator.free(record_dir_before);

    // Dig an UNDERGROUND-only cell open (level 1).
    const changed = (try world.setDenseTile(level1_obstacle, 5, 5, grass)) orelse return error.TestExpectedEqual;
    try std.testing.expect(changed.old_blocks_movement and !changed.new_blocks_movement);
    const stats = try system.applyNavUpdates(no_colliders, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
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
    _ = try system.applyNavUpdates(no_colliders, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});

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
    const edits = [_]NavCellEdit{ .{ .level = 0, .x = 5, .y = 5 }, .{ .level = 0, .x = 6, .y = 5 }, .{ .level = 0, .x = 5, .y = 6 } };
    _ = (try world.setDenseTile(obstacle, 5, 5, tree)) orelse return error.TestExpectedEqual;
    _ = (try world.setDenseTile(obstacle, 6, 5, tree)) orelse return error.TestExpectedEqual;
    _ = (try world.setDenseTile(obstacle, 5, 6, tree)) orelse return error.TestExpectedEqual;
    _ = try system.applyNavUpdates(no_colliders, &world, &edits);

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
        const stats = try system.applyNavUpdates(no_colliders, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
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
    var edits: [cells.len]NavCellEdit = undefined;
    for (cells, 0..) |cell, i| {
        _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tree)) orelse return error.TestExpectedEqual;
        edits[i] = .{ .level = 0, .x = cell.x, .y = cell.y };
    }
    _ = try system.applyNavUpdates(no_colliders, &world, &edits);

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
    system.nav_thread_adaptive = false;
    system.nav_thread_items_per_range = 1;

    // Five cells in five distinct nav_chunk_tiles=4 chunks, so both the remask changed-chunk set
    // and the patch dirty set exceed one chunk and actually fan out.
    const cells = [_]struct { x: u16, y: u16 }{
        .{ .x = 1, .y = 1 },  .{ .x = 13, .y = 1 },
        .{ .x = 1, .y = 13 }, .{ .x = 13, .y = 13 },
        .{ .x = 7, .y = 7 },
    };
    for (cells) |cell| {
        _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tree)) orelse return error.TestExpectedEqual;
        try system.markNavDirty(0, cell.x, cell.y);
    }
    _ = try system.applyBufferedNavUpdates(no_colliders, &world, &threads);

    // Both stages must have actually threaded, not fallen back to the inline slot-0 path.
    try std.testing.expect(!system.graph.last_remask_batch.ran_inline);
    try std.testing.expect(!system.graph.last_patch_batch.ran_inline);

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
        try system.markNavDirty(0, cell.x, cell.y);
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
    fn commitAndReact(self: *StaticNav, commands: []const StructuralCommand, thread_system: ?*ThreadSystem) !NavUpdateStats {
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
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var nav = try staticNav(&meta, 256, &.{.{ .{ .x = 100, .y = 100 }, .{ .x = 16, .y = 16 } }}, abstractCapacity());
    defer nav.deinit();
    const entity = nav.data.movementBodySliceConst().entities[0];
    const cell = nav.system.graph.grid(0).?.worldToCellClamped(.{ .x = 100, .y = 100 });
    try std.testing.expect(nav.system.graph.grid(0).?.isBlockedCell(cell));

    _ = try nav.commitAndReact(&.{.{ .destroy_entity = entity }}, null);
    try std.testing.expect(!nav.system.graph.grid(0).?.isBlockedCell(cell));
    var rebuilt = try nav.rebuilt();
    defer rebuilt.deinit();
    try expectGraphsEquivalent(&nav.system.graph, &rebuilt.graph);
}

test "entity obstacle create/destroy patches a constant chunk set independent of world size and matches a full rebuild" {
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
        const create_stats = try nav.commitAndReact(&.{.{ .create_entity = staticTemplate(.{ .x = 160, .y = 160 }, .{ .x = 8, .y = 8 }) }}, null);
        patched[i] = create_stats.chunks_patched;
        var rebuilt_created = try nav.rebuilt();
        defer rebuilt_created.deinit();
        try expectGraphsEquivalent(&nav.system.graph, &rebuilt_created.graph);

        const entity = nav.colliders.changesThisStep()[0].entity;
        _ = try nav.commitAndReact(&.{.{ .destroy_entity = entity }}, null);
        var rebuilt_destroyed = try nav.rebuilt();
        defer rebuilt_destroyed.deinit();
        try expectGraphsEquivalent(&nav.system.graph, &rebuilt_destroyed.graph);
    }
    try std.testing.expectEqual(@as(usize, 5), patched[0]);
    try std.testing.expectEqual(patched[0], patched[1]);
}

test "entity obstacle move marks both old and new spans dirty at a distance-independent patch cost" {
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

        const stats = try nav.commitAndReact(&.{moveCommand(entity, .{ .x = far_coord, .y = far_coord })}, null);
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

    _ = try nav.commitAndReact(&.{.{ .destroy_entity = a }}, null);
    try std.testing.expect(nav.system.graph.grid(0).?.isBlockedCell(cell));
    _ = try nav.commitAndReact(&.{.{ .destroy_entity = b }}, null);
    try std.testing.expect(!nav.system.graph.grid(0).?.isBlockedCell(cell));
}

test "static-to-dynamic-to-static toggle blocks and unblocks in place without moving" {
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var nav = try staticNav(&meta, 512, &.{.{ .{ .x = 160, .y = 160 }, .{ .x = 8, .y = 8 } }}, abstractCapacity());
    defer nav.deinit();
    const entity = nav.data.movementBodySliceConst().entities[0];
    const cell = nav.system.graph.grid(0).?.worldToCellClamped(.{ .x = 160, .y = 160 });
    try std.testing.expect(nav.system.graph.grid(0).?.isBlockedCell(cell));

    _ = try nav.commitAndReact(&.{.{ .set_collision_response = .{ .entity = entity, .response = .{ .mobility = .dynamic } } }}, null);
    try std.testing.expect(!nav.system.graph.grid(0).?.isBlockedCell(cell));
    _ = try nav.commitAndReact(&.{.{ .set_collision_response = .{ .entity = entity, .response = .{ .mobility = .static } } }}, null);
    try std.testing.expect(nav.system.graph.grid(0).?.isBlockedCell(cell));
}

test "a static on level 2 blocks level 2 only" {
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
    _ = try nav.commitAndReact(&.{.{ .create_entity = template }}, null);
    for (0..3) |level| {
        try std.testing.expectEqual(level == 2, nav.system.graph.grid(@intCast(level)).?.isBlockedCell(.{ .x = 5, .y = 5 }));
    }
    var rebuilt = try nav.rebuilt();
    defer rebuilt.deinit();
    try expectGraphsEquivalent(&nav.system.graph, &rebuilt.graph);
}

test "a static obstacle move costs the same at 10 and 10k statics" {
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
        try std.testing.expectEqual(other_count + 1, nav.colliders.rowCount());
        const moved = nav.data.movementBodySliceConst().entities[0];
        const stats = try nav.commitAndReact(&.{moveCommand(moved, .{ .x = 196, .y = 196 })}, null);
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
    _ = try nav.commitAndReact(&.{.{ .create_entity = staticTemplate(.{ .x = 164, .y = 164 }, .{ .x = 8, .y = 8 }) }}, null);
    const body = nav.colliders.changesThisStep()[0].entity;
    try nav.world.addLevelLink(.{ .kind = .ramp, .level_a = 1, .cell_a = .{ .x = 5, .y = 5 }, .level_b = 0, .cell_b = .{ .x = 5, .y = 5 }, .traversal_cost = 1, .bidirectional = true });
    _ = try nav.system.applyBufferedNavUpdates(&nav.colliders, &nav.world, null);
    try std.testing.expect(!try routes(&nav.system, &nav.data, &nav.world, 1, .{ 1, 1 }, 0, .{ 10, 10 }));

    _ = try nav.commitAndReact(&.{moveCommand(body, .{ .x = 292, .y = 36 })}, null);
    try std.testing.expect(try routes(&nav.system, &nav.data, &nav.world, 1, .{ 1, 1 }, 0, .{ 10, 10 }));
    var rebuilt = try nav.rebuilt();
    defer rebuilt.deinit();
    try expectGraphsEquivalent(&nav.system.graph, &rebuilt.graph);
}

test "incremental nav update threaded chunk patch matches a serial full rebuild with an entity-obstacle edit" {
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
    _ = try nav.system.applyBufferedNavUpdates(&nav.colliders, &nav.world, null);
    nav.system.nav_thread_adaptive = false;
    nav.system.nav_thread_items_per_range = 1;

    const entity = nav.data.movementBodySliceConst().entities[0];
    try test_support.commitWithColliders(&nav.frame, &nav.data, &nav.colliders, &nav.system, &.{.{ .destroy_entity = entity }});
    const cells = [_]struct { x: u16, y: u16 }{
        .{ .x = 1, .y = 1 },  .{ .x = 13, .y = 1 },
        .{ .x = 1, .y = 13 }, .{ .x = 13, .y = 13 },
    };
    for (cells) |cell| {
        _ = (try nav.world.setDenseTile(obstacle, cell.x, cell.y, tree)) orelse return error.TestExpectedEqual;
        try nav.system.markNavDirty(0, cell.x, cell.y);
    }
    _ = try nav.system.applyBufferedNavUpdates(&nav.colliders, &nav.world, &threads);
    try std.testing.expect(!nav.system.graph.last_remask_batch.ran_inline);

    var rebuilt = try nav.rebuilt();
    defer rebuilt.deinit();
    try expectGraphsEquivalent(&nav.system.graph, &rebuilt.graph);
}

test "a static obstacle commit and its nav reaction are allocation-free at steady state" {
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var nav = try staticNav(&meta, 512, &.{.{ .{ .x = 160, .y = 160 }, .{ .x = 8, .y = 8 } }}, abstractCapacity());
    defer nav.deinit();
    const entity = nav.data.movementBodySliceConst().entities[0];
    // Warmup: the body moves out and back through the seam, so the mark buffer, batch keys,
    // cell blocks, records, and the collider lists reach their high-water.
    _ = try nav.commitAndReact(&.{moveCommand(entity, .{ .x = 228, .y = 228 })}, null);
    _ = try nav.commitAndReact(&.{moveCommand(entity, .{ .x = 160, .y = 160 })}, null);

    const original = nav.system.allocator;
    nav.system.allocator = std.testing.failing_allocator;
    nav.system.graph.allocator = std.testing.failing_allocator;
    defer {
        nav.system.graph.allocator = original;
        nav.system.allocator = original;
    }
    // The same move again: the reaction allocates nothing.
    try test_support.commitWithColliders(&nav.frame, &nav.data, &nav.colliders, &nav.system, &.{moveCommand(entity, .{ .x = 228, .y = 228 })});
    const stats = try nav.system.reactToPostCommitNavEvents(&nav.frame, &nav.colliders, &nav.world, null);
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
    system.nav_thread_adaptive = false;
    system.nav_thread_items_per_range = 1;

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
            try system.markNavDirty(0, cell.x, cell.y);
        }
        const warm_stats = try system.applyBufferedNavUpdates(&colliders, &world, &threads);
        try std.testing.expectEqual(@as(usize, 1), warm_stats.incremental_rebuilds);
        // The warmup itself must have threaded, so the proof below runs the same dispatch.
        try std.testing.expect(!system.graph.last_remask_batch.ran_inline);
        try std.testing.expect(!system.graph.last_patch_batch.ran_inline);
    }

    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;

    for (proof_cells) |cell| {
        _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tree)) orelse return error.TestExpectedEqual;
        try system.markNavDirty(0, cell.x, cell.y);
    }
    const stats = try system.applyBufferedNavUpdates(&colliders, &world, &threads);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    // The stages threaded under the failing allocator and allocated nothing.
    try std.testing.expect(!system.graph.last_remask_batch.ran_inline);
    try std.testing.expect(!system.graph.last_patch_batch.ran_inline);
    try std.testing.expect(!stats.conn_seed_batch.ran_inline);
    try std.testing.expect(!stats.conn_gather_batch.ran_inline);

    system.graph.allocator = original;
    system.allocator = original;
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
    const stats = try system.updateSerial(&stream, 8, .{});
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
    // after a refused in-place resize) fails.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, level_graph.ensureFreeRecords(failing.allocator(), level_graph.records.capacity + 1, &pool_grows));
    const records = level_graph.records.slice();
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
    try frame.publishWorldTileChanges(events.items);
    system.recordTerrainNavEvents(frame.events.mergedItems(), world, null);
}

test "a nav-record reserve OOM before a cave-in or explosion dense write leaves world and nav intact and the retry applies it" {
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
            _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
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
        const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
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
    try std.testing.expectEqual(@as(usize, 2), closure.termCount());
    const closure_words_before = try std.testing.allocator.dupe(u32, closure.words.items);
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
    const stats = try system.applyNavUpdates(no_colliders, &fixture.world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
    try std.testing.expectEqual(@as(usize, 5), stats.chunks_patched);
    try std.testing.expectEqual(@as(usize, 0), stats.conn_flood_nodes);
    try std.testing.expectEqual(@as(usize, 0), stats.closure_links);
    try std.testing.expectEqualSlices(u32, closure_words_before, closure.words.items);
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

test "a batch touching more than eight levels applies incrementally and never changes nav_version" {
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

    var edits: [obstacles.len]NavCellEdit = undefined;
    for (obstacles, 0..) |layer, level| {
        const changed = (try world.setDenseTile(layer, 3, @intCast(level % 8), tree)).?;
        edits[level] = .{ .level = changed.level, .x = changed.x, .y = changed.y };
    }
    const stats = try system.applyNavUpdates(no_colliders, &world, &edits);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), stats.levels_built);
    try std.testing.expectEqual(version, system.graph.version);

    // A level add, a blocking layer, and a link in one update keep it too.
    const added = try world.addLevel(-160);
    _ = try world.addDenseLayer(added, 0, .floor, grass);
    _ = try world.addDenseLayer(2, 0, .obstacle, tree);
    try world.addLevelLink(.{ .kind = .stair, .level_a = 0, .cell_a = .{ .x = 1, .y = 1 }, .level_b = added, .cell_b = .{ .x = 1, .y = 1 }, .traversal_cost = 1, .bidirectional = true });
    const update = try system.applyBufferedNavUpdates(no_colliders, &world, null);
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
            try system.markNavDirty(changed.level, changed.x, changed.y);
        },
        .cave_in => for (0..3) |level| {
            for (3..6) |y| for (3..6) |x| {
                const changed = (try world.setDenseTile(oomObstacle(world, @intCast(level)), @intCast(x), @intCast(y), tree)) orelse continue;
                try system.markNavDirty(changed.level, changed.x, changed.y);
            };
        },
        .ramp => {
            const changed = (try world.setDenseTile(oomObstacle(world, 1), 5, 5, grass)).?;
            try system.markNavDirty(changed.level, changed.x, changed.y);
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
            try system.markNavDirty(changed.level, changed.x, changed.y);
            try world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 11, .y = 0 }, .level_b = 1, .cell_b = .{ .x = 0, .y = 11 }, .traversal_cost = 1, .bidirectional = false });
        },
    }
}

// Applies `edit` failing at every allocation in turn. Each failure leaves every level
// wholly as it was or wholly rebuilt (a committed step stays), and the retry with the real
// allocator equals a full rebuild of the edited world.
fn expectNavApplyOutOfMemorySafe(edit: OomEdit, thread_system: ?*ThreadSystem) !void {
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var capacity = abstractCapacity();
    if (thread_system) |threads| capacity.worker_participant_count = threads.participantSlotCount();
    var fail_index: usize = 0;
    while (fail_index < 4096) : (fail_index += 1) {
        var data = DataSystem.init(std.testing.allocator);
        defer data.deinit();
        var world = try oomWorld(&meta);
        defer world.deinit();
        var system = try fullRebuild(&data, &world, capacity);
        defer system.deinit();
        system.nav_thread_adaptive = false;
        system.nav_thread_items_per_range = 1;
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
    for (std.meta.tags(OomEdit)) |edit| try expectNavApplyOutOfMemorySafe(edit, null);
}

test "threaded nav apply runs out of memory at every allocation on a multi-worker ThreadSystem and the retry equals a full rebuild" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    for (std.meta.tags(OomEdit)) |edit| try expectNavApplyOutOfMemorySafe(edit, &threads);
}

test "a runtime ramp is routable from both levels the same step, at an interior and a perimeter endpoint" {
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
        const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
        try std.testing.expect(isPortal(&system.graph, 1, @as(usize, cell[1]) * system.graph.width + cell[0]));
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
    _ = try system.applyNavUpdates(no_colliders, &fixture.world, &.{.{ .level = opened.level, .x = opened.x, .y = opened.y }});
    try std.testing.expect(try routes(&system, &data, &fixture.world, 1, .{ 1, 1 }, 0, .{ 10, 10 }));
}

test "adding a blocking dense layer to a built level re-derives that level's nav" {
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
    const stats = try system.reactToPostCommitNavEvents(&frame, no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.levels_built);
    try std.testing.expectEqual(@as(usize, 1), frame.events.stats.nav_region_invalidated);
    try std.testing.expect(!system.navReactionMayEmit(&data, &frame, &fixture.world));
    try std.testing.expectEqual(@as(usize, 0), system.graph.levelGraph(1).?.recordCount());
    var rebuilt = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer rebuilt.deinit();
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "a level added in play builds only its own chunks and leaves other levels and cached paths untouched" {
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
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
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
            try system.graph.rebuild(no_colliders.view(), .{ .world = &first.world }, null);
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

test "nav over a zero-level world builds no level; the first added level routes" {
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
    const stats = try system.applyBufferedNavUpdates(no_colliders, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.levels_built);
    try std.testing.expect(try routes(&system, &data, &world, 0, .{ 1, 1 }, 0, .{ 10, 10 }));
}

test "the nav reaction runs when only the world gained a level, a link, or a content revision" {
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
        const stats = try system.reactToPostCommitNavEvents(&frame, no_colliders, &fixture.world, null);
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
    _ = try system.applyNavUpdates(no_colliders, &fixture.world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});

    // The patched record holds exactly its level-local link: the batch planned one endpoint,
    // and the patch asserts its appends stay within the planned count.
    const chunk = system.graph.chunkOf(5 * system.graph.width + 5);
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
    const chunk = system.graph.chunkOf(6 * system.graph.width + 6);
    var capacity: usize = 0;
    var growths: u64 = 0;
    const batches = 32;
    for (0..batches) |_| {
        try fixture.world.addLevelLink(.{ .kind = .teleport, .level_a = 0, .cell_a = .{ .x = 6, .y = 6 }, .level_b = 0, .cell_b = .{ .x = 6, .y = 7 }, .traversal_cost = 1, .bidirectional = false });
        const pool_grows = system.graph.pool_grows;
        _ = try system.applyNavUpdates(no_colliders, &fixture.world, &.{});
        const level_graph = system.graph.levelGraph(0).?;
        const slot = level_graph.record_link_slot[level_graph.record_dir.items[chunk]];
        if (level_graph.slot_links[slot].capacity != capacity) {
            capacity = level_graph.slot_links[slot].capacity;
            growths += 1;
            try std.testing.expect(system.graph.pool_grows > pool_grows);
        }
    }
    try std.testing.expectEqual(@as(usize, batches), system.graph.chunkPortals(0, chunk).links.len);
    // Geometric: a handful of growths for 32 links (one per link if grown exactly).
    try std.testing.expect(growths <= 8);
    var rebuilt = try fullRebuild(&data, &fixture.world, abstractCapacity());
    defer rebuilt.deinit();
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "an aborted prepared batch leaves the graph and its pending work unchanged, and the retry equals a full rebuild" {
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
    try system.markNavDirty(changed.level, changed.x, changed.y);
    try fixture.world.addLevelLink(.{ .kind = .ramp, .level_a = 1, .cell_a = .{ .x = 9, .y = 9 }, .level_b = 0, .cell_b = .{ .x = 9, .y = 9 }, .traversal_cost = 1, .bidirectional = true });
    const links_applied = system.graph.links_applied;
    var stats = NavUpdateStats{};
    const prepared = (try system.graph.prepareMarks(&fixture.world, no_colliders.view(), system.nav_marks.items, null, &stats)).?;
    system.graph.abortMarks(prepared);
    try std.testing.expectEqual(links_applied, system.graph.links_applied);
    try expectGraphsEquivalent(&system.graph, &before.graph);
    try std.testing.expect(system.hasPendingNavUpdates(&fixture.world));

    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
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
        try system.markNavDirty(changed.level, changed.x, changed.y);
    };
    const mixed = (try fixture.world.setDenseTile(fixture.obstacle[1], 5, 5, fixture.tree)).?;
    try system.markNavDirty(mixed.level, mixed.x, mixed.y);
    try system.markNavDirty(1, 9, 9);
    try std.testing.expectEqual(@as(usize, 2), try expectChangedMasksAreFlips(&system, &fixture.world));
    try std.testing.expect(system.graph.grid(0).?.chunkForm(0) == .blocked);

    // Level 0 chunk (0, 0) blocked -> mixed; level 1 chunk (1, 1) mixed -> blocked.
    const opened = (try fixture.world.setDenseTile(fixture.obstacle[0], 1, 1, fixture.grass)).?;
    try system.markNavDirty(opened.level, opened.x, opened.y);
    for (4..8) |y| for (4..8) |x| {
        if (x == 5 and y == 5) continue;
        const changed = (try fixture.world.setDenseTile(fixture.obstacle[1], @intCast(x), @intCast(y), fixture.tree)).?;
        try system.markNavDirty(changed.level, changed.x, changed.y);
    };
    try std.testing.expectEqual(@as(usize, 2), try expectChangedMasksAreFlips(&system, &fixture.world));
    try std.testing.expect(system.graph.grid(0).?.chunkForm(0) == .mixed);
    try std.testing.expect(system.graph.grid(1).?.chunkForm(4) == .blocked);
}

fn expectLinkPair(pairs: *const LinkPairs, index: usize, from: [3]i32, to: [3]i32, cost: i32) !void {
    try std.testing.expectEqual(LinkBox.point(from[0], from[1], from[2]), pairs.entrances.boxAt(index));
    try std.testing.expectEqual(LinkBox.point(to[0], to[1], to[2]), pairs.exits.boxAt(index));
    try std.testing.expectEqual(cost, pairs.cost[index]);
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
    try std.testing.expectEqual(@as(i32, 41), pairs.chain_to[1][0]);
    try std.testing.expectEqual(@as(i32, 41), pairs.chain_to[0][1]);
    try std.testing.expectEqual(@as(i32, 0), pairs.chain_to[2][2]);
    // Folding the same links again changes nothing.
    var refolded = bounds.*;
    refolded.foldLinks(fixture.world.levelLinks());
    try std.testing.expect(std.meta.eql(bounds.*, refolded));
    // The folded cost is the edge cost the ramp's record holds.
    const ramp_cell = 5 * system.graph.width + 5;
    const ramp_links = system.graph.chunkPortals(1, system.graph.chunkOf(ramp_cell)).linksAt(system.graph.localOf(ramp_cell));
    try std.testing.expectEqual(bounds.short_cost, ramp_links[0].cost);
}

// A directed long link for the pair tests.
const PairLink = struct {
    from: CellCoord,
    from_level: u16,
    to: CellCoord,
    to_level: u16,
    cost: i32,

    fn insertInto(self: PairLink, pairs: *LinkPairs) bool {
        return pairs.insert(self.from, self.from_level, self.to, self.to_level, self.cost);
    }
};

// Whether some pair holds both of `link`'s endpoints at no more than its cost.
fn pairHolds(pairs: *const LinkPairs, link: PairLink) bool {
    for (0..pairs.count) |index| {
        if (pairs.entrances.boxAt(index).contains(link.from, link.from_level) and pairs.exits.boxAt(index).contains(link.to, link.to_level) and pairs.cost[index] <= link.cost) return true;
    }
    return false;
}

fn expectPadsCopyFirst(pairs: *const LinkPairs) !void {
    for (pairs.count..long_link_pairs) |pad| {
        try std.testing.expectEqual(pairs.entrances.boxAt(0), pairs.entrances.boxAt(pad));
        try std.testing.expectEqual(pairs.exits.boxAt(0), pairs.exits.boxAt(pad));
        try std.testing.expectEqual(pairs.cost[0], pairs.cost[pad]);
    }
}

test "a link pair summary holds every folded link in one pair at most its cost, is exact to its cap, ignores a covered link, and keeps far pairs, mirrored strips, and split exits apart" {
    var prng = std.Random.DefaultPrng.init(0x6e67_0000);
    const random = prng.random();
    var pairs = LinkPairs{};
    var links: [200]PairLink = undefined;
    for (&links, 0..) |*link, index| {
        link.* = .{
            .from = .{ .x = random.uintLessThan(u16, 512), .y = random.uintLessThan(u16, 512) },
            .from_level = random.uintLessThan(u16, 8),
            .to = .{ .x = random.uintLessThan(u16, 512), .y = random.uintLessThan(u16, 512) },
            .to_level = random.uintLessThan(u16, 8),
            .cost = random.intRangeAtMost(i32, 0, 200),
        };
        // Past the cap a merged pair may already hold a new link.
        const changed = link.insertInto(&pairs);
        try std.testing.expect(changed or index >= long_link_pairs);
        try std.testing.expectEqual(@min(index + 1, long_link_pairs), pairs.count);
        for (links[0 .. index + 1]) |folded| try std.testing.expect(pairHolds(&pairs, folded));
        try expectPadsCopyFirst(&pairs);
        if (index < long_link_pairs) {
            for (links[0 .. index + 1], 0..) |folded, pair| {
                try expectLinkPair(&pairs, pair, .{ folded.from.x, folded.from.y, folded.from_level }, .{ folded.to.x, folded.to.y, folded.to_level }, folded.cost);
            }
        }
        // A covered link at its cost or more changes nothing; a cheaper one lowers a cost only.
        const before = pairs;
        var again = links[random.uintLessThan(usize, index + 1)];
        try std.testing.expect(!again.insertInto(&pairs));
        try std.testing.expect(std.meta.eql(before, pairs));
        again.cost = 0;
        _ = again.insertInto(&pairs);
        try std.testing.expect(std.meta.eql(before.entrances, pairs.entrances) and std.meta.eql(before.exits, pairs.exits));
        pairs = before;
    }

    // A merged pair 0 covers a link at 50 that pair 1 holds at 5: inserting it again at 10
    // changes nothing, since a holder already bounds it.
    var shadowed = LinkPairs{ .count = 2 };
    shadowed.entrances.setBox(0, .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 0, .l0 = 0, .l1 = 0 });
    shadowed.exits.setBox(0, .{ .x0 = 100, .y0 = 0, .x1 = 110, .y1 = 0, .l0 = 0, .l1 = 0 });
    shadowed.cost[0] = 50;
    shadowed.entrances.setBox(1, LinkBox.point(5, 0, 0));
    shadowed.exits.setBox(1, LinkBox.point(105, 0, 0));
    shadowed.cost[1] = 5;
    shadowed.padFromFirst();
    const shadowed_before = shadowed;
    try std.testing.expect(!(PairLink{ .from = .{ .x = 5, .y = 0 }, .from_level = 0, .to = .{ .x = 105, .y = 0 }, .to_level = 0, .cost = 10 }).insertInto(&shadowed));
    try std.testing.expect(std.meta.eql(shadowed_before, shadowed));

    // A full row of nearby pairs, then one far away: the far link keeps a pair of its own.
    var row = LinkPairs{};
    for (0..long_link_pairs) |column| {
        const x: u16 = @intCast(column * 4);
        _ = (PairLink{ .from = .{ .x = x, .y = 0 }, .from_level = 0, .to = .{ .x = x, .y = 10 }, .to_level = 0, .cost = 5 }).insertInto(&row);
    }
    _ = (PairLink{ .from = .{ .x = 200, .y = 200 }, .from_level = 0, .to = .{ .x = 210, .y = 210 }, .to_level = 0, .cost = 5 }).insertInto(&row);
    var own_pair = false;
    for (0..long_link_pairs) |index| {
        own_pair = own_pair or (std.meta.eql(row.entrances.boxAt(index), LinkBox.point(200, 200, 0)) and std.meta.eql(row.exits.boxAt(index), LinkBox.point(210, 210, 0)));
    }
    try std.testing.expect(own_pair);

    // Bidirectional links between a west strip on level 0 and its mirror on level 7: no box
    // spans both strips, so no pair enters on one and exits beside the same strip.
    var strips = LinkPairs{};
    for (0..32) |_| {
        const west = CellCoord{ .x = random.uintLessThan(u16, 4), .y = random.uintLessThan(u16, 256) };
        const east = CellCoord{ .x = 255 - west.x, .y = 255 - west.y };
        _ = (PairLink{ .from = west, .from_level = 0, .to = east, .to_level = 7, .cost = 41 }).insertInto(&strips);
        _ = (PairLink{ .from = east, .from_level = 7, .to = west, .to_level = 0, .cost = 41 }).insertInto(&strips);
    }
    try std.testing.expectEqual(@as(u32, long_link_pairs), strips.count);
    for (0..long_link_pairs) |index| {
        for ([_]LinkBox{ strips.entrances.boxAt(index), strips.exits.boxAt(index) }) |box| try std.testing.expect(box.x1 < 128 or box.x0 >= 128);
    }

    // Adjacent entrances whose exits alternate between two far regions: merges follow the
    // exits, so no exit box spans both regions.
    var split = LinkPairs{};
    for (0..48) |index| {
        const x: u16 = @intCast(index);
        const exit_x: u16 = if (index % 2 == 0) 400 + x else x;
        _ = (PairLink{ .from = .{ .x = x, .y = 0 }, .from_level = 0, .to = .{ .x = exit_x, .y = 300 }, .to_level = 0, .cost = 5 }).insertInto(&split);
    }
    for (0..long_link_pairs) |index| {
        const box = split.exits.boxAt(index);
        try std.testing.expect(box.x1 < 200 or box.x0 >= 200);
    }
}

// Scalar reference for one box term, unclamped.
fn boxTermScalar(box: LinkBox, x: i64, y: i64, level: i64, rates: CrossingRates) i64 {
    const dx: i64 = @max(box.x0 - x, x - box.x1, 0);
    const dy: i64 = @max(box.y0 - y, y - box.y1, 0);
    const gap: i64 = @max(box.l0 - level, level - box.l1, 0);
    const planar: i64 = octileU32(0, 0, @intCast(dx), @intCast(dy));
    return @max(planar + gap * rates.excess, gap * rates.cost);
}

// Scalar reference for the box term between two boxes, unclamped.
fn boxPairTermScalar(from: LinkBox, to: LinkBox, rates: CrossingRates) i64 {
    const dx: i64 = @max(@as(i64, to.x0) - from.x1, @as(i64, from.x0) - to.x1, 0);
    const dy: i64 = @max(@as(i64, to.y0) - from.y1, @as(i64, from.y0) - to.y1, 0);
    const gap: i64 = @max(@as(i64, to.l0) - from.l1, @as(i64, from.l0) - to.l1, 0);
    return @max(octileU32(0, 0, @intCast(dx), @intCast(dy)) + gap * rates.excess, gap * rates.cost);
}

fn randomExtreme(random: std.Random) u16 {
    const extremes = [_]u16{ 0, std.math.maxInt(u16) };
    return if (random.boolean()) extremes[random.uintLessThan(usize, 2)] else random.int(u16);
}

fn randomRates(random: std.Random) CrossingRates {
    const choices = [_]i32{ 0, crossing_rate_cap, random.intRangeAtMost(i32, 0, crossing_rate_cap) };
    return .{ .excess = choices[random.uintLessThan(usize, 3)], .cost = choices[random.uintLessThan(usize, 3)] };
}

// Pairs from 1 to 24 random links with coordinates, levels, and costs at their extremes.
fn randomLinkPairs(random: std.Random) LinkPairs {
    var pairs = LinkPairs{};
    const links = 1 + random.uintLessThan(usize, long_link_pairs + 8);
    for (0..links) |_| {
        const cost_choices = [_]i32{ 0, long_lane_cap, random.intRangeAtMost(i32, 0, long_lane_cap) };
        _ = pairs.insert(.{ .x = randomExtreme(random), .y = randomExtreme(random) }, randomExtreme(random), .{ .x = randomExtreme(random), .y = randomExtreme(random) }, randomExtreme(random), cost_choices[random.uintLessThan(usize, 3)]);
    }
    return pairs;
}

test "the box lane terms and offset scan equal a scalar scan" {
    var prng = std.Random.DefaultPrng.init(0x6e68_0000);
    const random = prng.random();
    var checked: usize = 0;
    var clamped: usize = 0;
    for (0..64) |_| {
        const pairs = randomLinkPairs(random);
        for (0..32) |_| {
            const rates = randomRates(random);
            const x: u32 = randomExtreme(random);
            const y: u32 = randomExtreme(random);
            const level = randomExtreme(random);
            var offsets: [long_link_pairs]i32 = undefined;
            const offset_kind = random.uintLessThan(usize, 3);
            for (&offsets) |*offset| offset.* = switch (offset_kind) {
                0 => 0,
                1 => long_lane_cap,
                else => random.intRangeAtMost(i32, 0, long_lane_cap),
            };
            const terms = pairs.entrances.laneTerms(x, y, level, rates);
            // The scan covers the pairs' whole lane groups.
            const scanned = std.mem.alignForward(usize, pairs.count, simd.lane_count);
            var least: i64 = std.math.maxInt(i64);
            for (0..long_link_pairs) |slot| {
                const raw = boxTermScalar(pairs.entrances.boxAt(slot), x, y, level, rates);
                clamped += @intFromBool(raw > long_lane_cap);
                const term = @min(raw, long_lane_cap);
                try std.testing.expectEqual(term, terms[slot]);
                if (slot < scanned) least = @min(least, offsets[slot] + term);
            }
            try std.testing.expectEqual(least, pairs.entrances.offsetLowerBound(&offsets, pairs.count, x, y, level, rates));
            checked += 1;
        }
    }
    try std.testing.expect(checked > 1000);
    try std.testing.expect(clamped > 0);
}

test "the pair chain closure equals a scalar shortest-chain reference and keeps every triangle bound" {
    var prng = std.Random.DefaultPrng.init(0x6e69_0000);
    const random = prng.random();
    var chained: usize = 0;
    var clamped: usize = 0;
    for (0..96) |round| {
        var pairs = randomLinkPairs(random);
        // Every few rounds a small world, where chains through further pairs win.
        if (round % 3 == 0) {
            pairs = .{};
            for (0..1 + random.uintLessThan(usize, long_link_pairs + 8)) |_| {
                _ = pairs.insert(.{ .x = random.uintLessThan(u16, 64), .y = random.uintLessThan(u16, 64) }, random.uintLessThan(u16, 4), .{ .x = random.uintLessThan(u16, 64), .y = random.uintLessThan(u16, 64) }, random.uintLessThan(u16, 4), random.intRangeAtMost(i32, 0, 50));
            }
        }
        const rates = if (round % 3 == 0) CrossingRates{ .excess = 41, .cost = 41 } else randomRates(random);
        pairs.close(rates);
        const count = pairs.count;
        // Bellman-Ford from every pair over edges p -> q weighted by the exit-to-entrance box
        // term plus q's cost.
        var reference: [long_link_pairs][long_link_pairs]i64 = undefined;
        for (0..count) |from| {
            var dist: [long_link_pairs]i64 = @splat(std.math.maxInt(i64));
            dist[from] = 0;
            for (0..count) |_| {
                for (0..count) |via| {
                    if (dist[via] == std.math.maxInt(i64)) continue;
                    for (0..count) |to| {
                        if (to == via) continue;
                        dist[to] = @min(dist[to], dist[via] + boxPairTermScalar(pairs.exits.boxAt(via), pairs.entrances.boxAt(to), rates) + pairs.cost[to]);
                    }
                }
            }
            for (0..count) |to| {
                reference[from][to] = @min(dist[to], long_lane_cap);
                const direct = if (from == to) 0 else boxPairTermScalar(pairs.exits.boxAt(from), pairs.entrances.boxAt(to), rates) + pairs.cost[to];
                chained += @intFromBool(dist[to] < direct);
                clamped += @intFromBool(dist[to] > long_lane_cap);
            }
        }
        for (0..long_link_pairs) |to| {
            for (0..long_link_pairs) |from| {
                const expected = reference[if (from < count) from else 0][if (to < count) to else 0];
                try std.testing.expectEqual(expected, pairs.chain_to[to][from]);
            }
        }
        for (0..count) |from| {
            try std.testing.expectEqual(@as(i32, 0), pairs.chain_to[from][from]);
            for (0..count) |via| {
                const step = boxPairTermScalar(pairs.exits.boxAt(from), pairs.entrances.boxAt(via), rates) + pairs.cost[via];
                for (0..count) |to| try std.testing.expect(pairs.chain_to[to][from] <= step + pairs.chain_to[to][via]);
            }
        }
    }
    try std.testing.expect(chained > 0);
    try std.testing.expect(clamped > 0);
}

test "border portals never exceed 4 * ceil(E / 2) and random digs match a full rebuild" {
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
        var world = try @import("../../world_test_support.zig").demoWorldWithChunkSize(std.testing.allocator, &meta, side, side, edge);
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
            try system.markNavDirty(changed.level, changed.x, changed.y);
        }
        _ = try system.applyBufferedNavUpdates(no_colliders, &world, null);
        const bound = 4 * ((@as(usize, edge) + 1) / 2);
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
        systems[built].nav_thread_adaptive = false;
        systems[built].nav_thread_items_per_range = items_per_range;
        built += 1;
    }

    try fixture.world.addLevelLink(.{ .kind = .ramp, .level_a = 1, .cell_a = .{ .x = 9, .y = 2 }, .level_b = 0, .cell_b = .{ .x = 9, .y = 2 }, .traversal_cost = 1, .bidirectional = true });
    // Overlapping marks on both levels, in an order that spreads repeats across ranges.
    for (0..40) |cell| {
        const level: u16 = @intCast(cell % 2);
        const x: u16 = @intCast((cell * 7) % 12);
        const y: u16 = @intCast((cell * 5) % 12);
        const changed = (try fixture.world.setDenseTile(fixture.obstacle[level], x, y, fixture.tree)) orelse continue;
        for (&systems) |*system| try system.markNavDirty(changed.level, changed.x, changed.y);
    }
    const obstacle_rect = SimulationEvent{ .stage = .structural_commit, .payload = .{ .world_obstacle_changed = .{ .level = 0, .min_x = 2, .min_y = 2, .max_x_exclusive = 11, .max_y_exclusive = 5 } } };
    for (&systems) |*system| try test_support.recordTerrainEvents(system, &.{obstacle_rect}, &fixture.world);
    _ = try systems[0].applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), systems[0].graph.plan_tallies.items.len);
    // The dirty keys are the union of the changed keys and the new link's endpoint chunks.
    {
        const graph = &systems[0].graph;
        var union_keys: std.ArrayList(u64) = .empty;
        defer union_keys.deinit(std.testing.allocator);
        try union_keys.appendSlice(std.testing.allocator, graph.changed_keys.items);
        const ramp_chunk = graph.chunkOf(2 * graph.width + 9);
        try union_keys.append(std.testing.allocator, chunkKey(1, ramp_chunk));
        try union_keys.append(std.testing.allocator, chunkKey(0, ramp_chunk));
        union_keys.items.len = sortUnique(union_keys.items);
        try std.testing.expectEqualSlices(u64, union_keys.items, graph.dirty_keys.items);
    }
    for (systems[1..]) |*system| {
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
        try std.testing.expect(system.graph.plan_tallies.items.len > 1);
        try std.testing.expectEqualSlices(u64, systems[0].graph.changed_keys.items, system.graph.changed_keys.items);
        try std.testing.expectEqualSlices(u64, systems[0].graph.patch_keys.items, system.graph.patch_keys.items);
        try std.testing.expectEqualSlices(u64, systems[0].graph.dirty_keys.items, system.graph.dirty_keys.items);
        try expectGraphsEquivalent(&systems[0].graph, &system.graph);
    }
}
