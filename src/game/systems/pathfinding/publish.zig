// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! The publish and path registry of `PathfindingSystem`: the step's results are reserved for,
//! claimed in solve-ordinal order on the main thread (O(1) per result), copied into their cache
//! stripes or long blocks with their registry runs bucketed per flush pair (`publish_copy`,
//! threaded per result range). The main thread plans the owner log once and buckets it by
//! shard; `registry_flush_count` lists the chunks to grow or compact without mutating runs;
//! the main thread reallocates a chunk that is short of slack; a shrink's `registry_rename`
//! rewrites every registration's owner in one pass over the block pool; `registry_flush`
//! retires, moves heads, compacts, and appends. Count and apply thread per shard, the
//! rename per block range. Free functions over `*PathfindingSystem`; the system calls them
//! directly.

const std = @import("std");
const runtime_perf_log = @import("../../../app/runtime_perf_log.zig");
const PathfindingSystem = @import("system.zig").PathfindingSystem;
const BatchStats = @import("../../../app/thread_system.zig").BatchStats;
const Dispatch = @import("../../../app/thread_system.zig").Dispatch;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const maxRangeCount = @import("../../../app/thread_system.zig").maxRangeCount;
const runShaped = @import("../../../app/thread_system.zig").runShaped;
const StageShape = @import("../../../app/thread_system.zig").StageShape;
const thread_shared_record_alignment = @import("../../../app/thread_system.zig").thread_shared_record_alignment;
const ChunkGeometry = @import("../../world/terrain.zig").ChunkGeometry;
const chunk_list_map = @import("../chunk_list_map.zig");
const chunkKey = chunk_list_map.chunkKey;
const keyLevel = chunk_list_map.keyLevel;
const keyChunk = chunk_list_map.keyChunk;
const no_entry = chunk_list_map.no_entry;
const empty_block = chunk_list_map.empty_block;
const ChunkDirectory = chunk_list_map.ChunkDirectory;
const pdq = @import("../../../core/sort.zig").pdq;
const simd = @import("../../../core/simd.zig");
const PaddedSlot = @import("../../../app/thread_system.zig").PaddedSlot;
const AdaptiveWorkTuner = @import("../../../app/thread_system.zig").AdaptiveWorkTuner;
const types = @import("types.zig");
const PathfindingStats = @import("types.zig").PathfindingStats;
const RegRecord = @import("types.zig").RegRecord;
const OwnerOp = @import("types.zig").OwnerOp;
const no_owner = @import("types.zig").no_owner;
const registry_shard_count = @import("types.zig").registry_shard_count;
const registryShard = @import("types.zig").registryShard;
const reg_window_alignment_items = @import("types.zig").reg_window_alignment_items;
const ops_per_entry = @import("caches.zig").ops_per_entry;

/// The publish copy's registration windows, shard-ordered within each range.
pub const RegRecordList = std.array_list.Aligned(RegRecord, .fromByteUnits(thread_shared_record_alignment));
/// One band per publish copy range.
pub const PublishBandList = std.array_list.Aligned(PublishBand, .fromByteUnits(thread_shared_record_alignment));

/// `registry_flush` work pairs: one per path registry shard.
pub const flush_pair_count = registry_shard_count;

/// One `publish_copy` range's registrations per flush pair, padded to its own cache line.
pub const PublishBand = struct {
    counts: [flush_pair_count]u32 align(thread_shared_record_alignment) = @splat(0),
};

/// One `registry_flush` pair's entries removed and added, padded to its own cache line; kept
/// only with `runtime_perf_log.enabled` (`PathfindingStats.Perf`), zero-sized without it.
pub const FlushTally = if (runtime_perf_log.enabled) struct {
    removed: usize align(thread_shared_record_alignment) = 0,
    added: usize = 0,
} else struct {};

comptime {
    std.debug.assert(@sizeOf(PublishBand) % thread_shared_record_alignment == 0);
    std.debug.assert(@sizeOf(FlushTally) % thread_shared_record_alignment == 0);
    // A publish band counts each flush pair's registrations.
    std.debug.assert(@typeInfo(@FieldType(PublishBand, "counts")).array.len == flush_pair_count);
}

/// One chunk's registrations, append order: `owner[0..len]` and `order[0..len]`, each row's
/// inverse node id beside them. One allocation, split into the three columns.
pub const RegChunk = struct {
    len: u32 = 0,
    cap: u32 = 0,
    owner: []u32 = &.{},
    order: []u32 = &.{},
    inverse: []u32 = &.{},
};

/// One live registration's place in its owner's chain. `chunk` is the chunk key: a stitched
/// path's runs are not all on one level, and the level-local index alone does not name the slot.
const InverseNode = struct {
    next: u32 = no_entry,
    chunk: u64 = 0,
    index: u32 = 0,
};

/// The head of an owner's inverse chain and how many nodes it holds. The length is what a
/// flush's count weight reads, O(1) per retire.
const OwnerHead = struct {
    node: u32 = no_entry,
    len: u32 = 0,
};

/// One shard's inverse nodes. A retire walks this chain, not the directory.
pub const InversePool = struct {
    nodes: std.MultiArrayList(InverseNode) = .{},
    node_free: std.ArrayList(u32) = .empty,
    owner_heads: std.ArrayList(OwnerHead) = .empty,
    replacement: ?std.ArrayList(OwnerHead) = null,
    retired: std.ArrayList(OwnerHead) = .empty,
    node_next: []u32 = &.{},
    node_chunk: []u64 = &.{},
    node_index: []u32 = &.{},

    pub fn deinit(self: *InversePool, allocator: std.mem.Allocator) void {
        self.retired.deinit(allocator);
        if (self.replacement) |*replacement| replacement.deinit(allocator);
        self.owner_heads.deinit(allocator);
        self.node_free.deinit(allocator);
        self.nodes.deinit(allocator);
        self.* = .{};
    }

    fn refresh(self: *InversePool) void {
        const columns = self.nodes.slice();
        self.node_next = columns.items(.next);
        self.node_chunk = columns.items(.chunk);
        self.node_index = columns.items(.index);
    }

    /// `needed` more free nodes. Geometric. On error nothing observable changes. A node id
    /// would pass `no_entry` only at 2^32 live nodes, which fails as `OutOfMemory`.
    pub fn reserveNodes(self: *InversePool, allocator: std.mem.Allocator, needed: usize) error{OutOfMemory}!void {
        if (self.node_free.items.len >= needed) return;
        const added = needed - self.node_free.items.len;
        const total = self.nodes.len + added;
        if (total >= no_entry) return error.OutOfMemory;
        if (total > self.nodes.capacity) {
            try self.nodes.ensureTotalCapacity(allocator, @max(total, self.nodes.capacity *| 2));
            self.refresh();
        }
        try self.node_free.ensureTotalCapacity(allocator, self.nodes.capacity);
        std.debug.assert(self.node_free.capacity >= self.nodes.capacity);
        const first: u32 = @intCast(self.nodes.len);
        for (0..added) |_| self.nodes.appendAssumeCapacity(undefined);
        var id: u32 = @intCast(self.nodes.len);
        while (id > first) {
            id -= 1;
            self.node_free.appendAssumeCapacity(id);
        }
        self.refresh();
        std.debug.assert(self.nodes.capacity >= self.nodes.len);
        std.debug.assert(self.node_free.items.len >= needed);
    }

    /// Owner ids below `owner_count` have a head. Geometric. On error nothing changes.
    pub fn reserveOwners(self: *InversePool, allocator: std.mem.Allocator, owner_count: usize) error{OutOfMemory}!void {
        if (self.owner_heads.items.len >= owner_count) return;
        try self.owner_heads.ensureTotalCapacity(allocator, owner_count);
        self.owner_heads.appendNTimesAssumeCapacity(.{}, owner_count - self.owner_heads.items.len);
        std.debug.assert(self.owner_heads.capacity >= self.owner_heads.items.len);
    }

    pub fn holdsOwner(self: *const InversePool, owner: u32) bool {
        return owner < self.owner_heads.items.len and self.owner_heads.items[owner].node != no_entry;
    }

    pub fn prepareTruncate(self: *InversePool, allocator: std.mem.Allocator, count: usize) error{OutOfMemory}!void {
        var replacement: std.ArrayList(OwnerHead) = .empty;
        try replacement.ensureTotalCapacityPrecise(allocator, count);
        self.abortTruncate(allocator);
        self.replacement = replacement;
    }

    pub fn abortTruncate(self: *InversePool, allocator: std.mem.Allocator) void {
        if (self.replacement) |*replacement| replacement.deinit(allocator);
        self.replacement = null;
    }

    /// Installs the prepared heads. Heads at or past the new count hold no node. Allocates
    /// and frees nothing. Without a prepared truncation it does nothing.
    pub fn installTruncate(self: *InversePool) void {
        var replacement = self.replacement orelse return;
        const count = @min(replacement.capacity, self.owner_heads.items.len);
        if (std.debug.runtime_safety) {
            for (self.owner_heads.items[count..]) |head| std.debug.assert(head.node == no_entry);
        }
        replacement.appendSliceAssumeCapacity(self.owner_heads.items[0..count]);
        std.debug.assert(self.retired.capacity == 0);
        self.retired = self.owner_heads;
        self.owner_heads = replacement;
        self.replacement = null;
    }

    pub fn releaseTruncated(self: *InversePool, allocator: std.mem.Allocator) void {
        self.retired.deinit(allocator);
        self.retired = .empty;
    }

    /// Every node is free and every head is empty. Keeps the pools' storage.
    pub fn clearNodes(self: *InversePool) void {
        @memset(self.owner_heads.items, .{});
        self.node_free.clearRetainingCapacity();
        var id: u32 = @intCast(self.nodes.len);
        while (id > 0) {
            id -= 1;
            self.node_free.appendAssumeCapacity(id);
        }
    }
};

/// A directory slot the count pass listed: the level and its level-local chunk index.
pub const ChunkRef = struct {
    level: u16,
    chunk: u32,
};

const ShardCount = struct {
    growth: u32 = 0,
    compact: u32 = 0,
    compact_len: usize = 0,
};

const FreshPayload = struct {
    level: u16,
    chunk: u32,
    block: u32,
    bytes: []align(4) u8,
    columns: RegChunk,
    is_new: bool,
    old_bytes: []align(4) u8,
};

const ChunkRefList = std.array_list.Aligned(ChunkRef, .fromByteUnits(thread_shared_record_alignment));
const chunk_ref_align: usize = thread_shared_record_alignment / @sizeOf(ChunkRef);

comptime {
    std.debug.assert(@sizeOf(ChunkRef) * chunk_ref_align == thread_shared_record_alignment);
}

pub const RegistryDirectory = ChunkDirectory(RegChunk, true);

/// Bytes of one registration in a chunk payload: its owner, order, and inverse columns.
pub const reg_row_bytes = 3 * @sizeOf(u32);

comptime {
    std.debug.assert(reg_row_bytes == @sizeOf(@typeInfo(@FieldType(RegChunk, "owner")).pointer.child) +
        @sizeOf(@typeInfo(@FieldType(RegChunk, "order")).pointer.child) + @sizeOf(@typeInfo(@FieldType(RegChunk, "inverse")).pointer.child));
}

/// One bit per registry shard.
pub const ShardMask = @Int(.unsigned, registry_shard_count);

/// A logged op's chain: the owner id whose pre-flush chain the op's `old` holds at that
/// point of the log (`no_entry`: none), and the shards that chain has nodes in.
pub const OpPlan = struct {
    origin: u32 = no_entry,
    shards: ShardMask = 0,
};

/// The owner log's plan for one flush, built once on the main thread for every shard, its
/// id columns sized to the owner ids. `at` maps an owner id to its place in `ids`
/// (`no_entry` outside a plan). Per listed id, `origin` is the id whose pre-flush chain it
/// holds after the log's head moves so far, and `shards` the shards its own pre-flush chain
/// has nodes in. `ops` is one plan per logged op. `rename_to` maps a pre-flush owner id to
/// the id its chain ends on: the identity outside a flush's rename pass.
pub const RetirePlan = struct {
    ids: std.ArrayList(u32) = .empty,
    at: std.ArrayList(u32) = .empty,
    origin: std.ArrayList(u32) = .empty,
    shards: std.ArrayList(ShardMask) = .empty,
    rename_to: std.ArrayList(u32) = .empty,
    ops: std.ArrayList(OpPlan) = .empty,

    pub fn deinit(self: *RetirePlan, allocator: std.mem.Allocator) void {
        self.ops.deinit(allocator);
        self.rename_to.deinit(allocator);
        self.shards.deinit(allocator);
        self.origin.deinit(allocator);
        self.at.deinit(allocator);
        self.ids.deinit(allocator);
        self.* = .{};
    }

    // Room for `owners` owner ids (`at` and `rename_to` cover them) and `log` logged ops,
    // geometric unless `exact`. Returns whether a list grew. On error every list keeps its
    // contents, `at` stays all `no_entry`, and `rename_to` the identity.
    fn reserve(self: *RetirePlan, allocator: std.mem.Allocator, owners: usize, log: usize, exact: bool) error{OutOfMemory}!bool {
        var grew = false;
        inline for (.{ &self.ids, &self.origin, &self.shards }) |list| grew = try reserveList(list, allocator, owners, exact) or grew;
        grew = try reserveList(&self.ops, allocator, log, exact) or grew;
        grew = try reserveList(&self.at, allocator, owners, exact) or grew;
        grew = try reserveList(&self.rename_to, allocator, owners, exact) or grew;
        if (owners > self.at.items.len) self.at.appendNTimesAssumeCapacity(no_entry, owners - self.at.items.len);
        while (self.rename_to.items.len < owners) {
            // Owner ids stay below the heads' count, a u32 width.
            self.rename_to.appendAssumeCapacity(@intCast(self.rename_to.items.len));
        }
        return grew;
    }

    fn reserveList(list: anytype, allocator: std.mem.Allocator, count: usize, exact: bool) error{OutOfMemory}!bool {
        if (count <= list.capacity) return false;
        if (exact) try list.ensureTotalCapacityPrecise(allocator, count) else try list.ensureTotalCapacity(allocator, count);
        return true;
    }
};

/// The path registry: one directory of registration runs (with a pending count per chunk),
/// and one inverse pool per shard.
pub const PathIndex = struct {
    directory: RegistryDirectory = .{},
    pools: [registry_shard_count]InversePool = @splat(.{}),
    growth: ChunkRefList = .empty,
    compact: ChunkRefList = .empty,
    growth_base: [registry_shard_count]usize = @splat(0),
    compact_base: [registry_shard_count]usize = @splat(0),
    counts: [registry_shard_count]PaddedSlot(ShardCount) = @splat(.{}),
    fresh: std.ArrayList(FreshPayload) = .empty,
    plan: RetirePlan = .{},
    // A shrink's plan sized to its new owner count, installed by the flush that installs
    // the owner heads' truncation.
    plan_replacement: ?RetirePlan = null,
    // The owner log bucketed by shard, each shard's op indices in log order at its base:
    // only ops on an id whose chain the shard holds at that point of the log.
    shard_ops: std.ArrayList(u32) = .empty,
    shard_op_base: [registry_shard_count]usize = @splat(0),
    shard_op_count: [registry_shard_count]usize = @splat(0),
    // Per shard, the nodes of the chains its ops retire.
    retire_node_count: [registry_shard_count]usize = @splat(0),
    // Chunks a retire emptied at a flush of step `emptied_step`, each once, each holding a
    // block (room for one per block of the pool). Each keeps its block and payload until a
    // flush of a later step finds it still empty, so a chunk published again a step after it
    // emptied reuses them.
    emptied: std.ArrayList(ChunkRef) = .empty,
    emptied_step: u32 = 0,

    pub fn deinit(self: *PathIndex, allocator: std.mem.Allocator) void {
        self.abortFresh(allocator);
        self.fresh.deinit(allocator);
        self.emptied.deinit(allocator);
        self.shard_ops.deinit(allocator);
        if (self.plan_replacement) |*replacement| replacement.deinit(allocator);
        self.plan.deinit(allocator);
        self.compact.deinit(allocator);
        self.growth.deinit(allocator);
        for (&self.pools) |*pool| pool.deinit(allocator);
        self.directory.deinit(allocator);
        self.* = .{};
    }

    fn abortFresh(self: *PathIndex, allocator: std.mem.Allocator) void {
        for (self.fresh.items) |item| {
            freePayload(allocator, item.bytes);
            if (item.is_new) self.directory.release(allocator, item.block);
        }
        self.fresh.clearRetainingCapacity();
    }
};

/// The publish reserve, before any claim: long-block pages for the step's results past
/// an inline stripe, each registry shard's room for this step's path runs in it, and the
/// registration windows. O(solves * shards) on the main thread; on error nothing is
/// claimed.
pub fn reservePublish(self: *PathfindingSystem) error{OutOfMemory}!void {
    var long_results: usize = 0;
    var registrations: usize = 0;
    var shard_registrations: [registry_shard_count]usize = @splat(0);
    for (self.solve_results.items, 0..) |result, ordinal| {
        switch (result) {
            .available, .partial => {},
            else => continue,
        }
        const solved = self.solved_paths.items[ordinal];
        if (types.storedPathWords(solved.len, solved.stitched_len) > self.completed.inline_words) long_results += 1;
        registrations += solved.run_count;
        for (&shard_registrations, solved.shard_counts) |*total, shard_count| total.* += shard_count;
    }
    var grows: u64 = @intFromBool(try reserveRegistryRuns(self, shard_registrations));
    // Each range window starts on a cache line.
    const padding = (reg_window_alignment_items - 1) * maxRangeCount(self.solve_results.items.len, 1);
    if (registrations + padding > self.reg_buckets.capacity) {
        try self.reg_buckets.ensureTotalCapacity(self.allocator, registrations + padding);
        grows += 1;
    }
    if (grows != 0) countRegistryGrowth(self, grows);
    const pages = try self.completed.reserveLongBlocks(self.allocator, long_results);
    if (pages != 0) self.long_block_growth.record(pages, .info, "path cache long-block pool grew to {d} blocks", .{self.completed.long_block_count});
}

/// Each shard's inverse pool has room for `shard_registrations` more runs and an owner head
/// per cache owner id, and the bucketed owner log room for any flush's ops on them. Returns
/// whether any of it grew; the caller counts the growth. On error nothing is claimed.
pub fn reserveRegistryRuns(self: *PathfindingSystem, shard_registrations: [registry_shard_count]usize) error{OutOfMemory}!bool {
    const capacity_before = registryCapacity(self);
    for (&self.path_index.pools, shard_registrations) |*pool, count| {
        try pool.reserveNodes(self.allocator, count);
        try pool.reserveOwners(self.allocator, self.completed.logicalCapacity());
    }
    try reserveShardOps(self);
    return registryCapacity(self) != capacity_before;
}

// Directory block storage, inverse-node pools, owner heads, and the count windows: a reserve
// that changed any of them grew.
fn registryCapacity(self: *const PathfindingSystem) usize {
    const index = &self.path_index;
    const plan = &index.plan;
    var capacity: usize = index.directory.levelCount() + index.directory.blocks.capacity + index.growth.capacity + index.compact.capacity + index.fresh.capacity +
        plan.ids.capacity + plan.at.capacity + plan.origin.capacity + plan.shards.capacity + plan.rename_to.capacity + plan.ops.capacity + index.shard_ops.capacity;
    for (0..index.directory.levelCount()) |level| capacity += index.directory.slotCount(@intCast(level));
    for (&index.pools) |*pool| {
        capacity += pool.nodes.capacity + pool.node_free.capacity + pool.owner_heads.capacity + pool.retired.capacity;
        if (pool.replacement) |replacement| capacity += replacement.capacity;
    }
    return capacity;
}

fn countRegistryGrowth(self: *PathfindingSystem, grows: u64) void {
    self.registry_growth.record(grows, .info, "path registry storage grew", .{});
}

/// Every inverse pool holds an owner head per cache owner id below `capacity`, and the
/// owner log's plan has room for those ids and a log of `ops_per_entry` ops per id.
pub fn reserveRegistryOwners(self: *PathfindingSystem, capacity: usize) !void {
    const capacity_before = registryCapacity(self);
    for (&self.path_index.pools) |*pool| try pool.reserveOwners(self.allocator, capacity);
    const owners = ownerIds(self);
    _ = try self.path_index.plan.reserve(self.allocator, owners, ops_per_entry *| owners, false);
    try reserveShardOps(self);
    if (registryCapacity(self) != capacity_before) countRegistryGrowth(self, 1);
}

// Room for any flush's log bucketed by shard, reserved where its bound grows (the node pools
// and the owner heads), so no flush allocates it. An op's entries are the shards its chain
// has nodes in, and a chain takes at most `ops_per_entry` ops between flushes (a shrink's
// rename, then a retire), so the entries stay below `ops_per_entry` per inverse node, and
// below `ops_per_entry` per owner id in each shard. Keyed on node capacity, not length, so a
// step that takes nodes from a pool's slack allocates nothing here either. Geometric. The
// plan still grows the list, counted, past this bound.
fn reserveShardOps(self: *PathfindingSystem) error{OutOfMemory}!void {
    var nodes: usize = 0;
    for (&self.path_index.pools) |*pool| nodes += pool.nodes.capacity;
    const bound = @min(ops_per_entry *| nodes, registry_shard_count *| ops_per_entry *| ownerIds(self));
    if (bound > self.path_index.shard_ops.capacity) try self.path_index.shard_ops.ensureTotalCapacity(self.allocator, bound);
}

// The plan names only owner ids below the heads' count.
fn ownerIds(self: *const PathfindingSystem) usize {
    var owners: usize = 0;
    for (&self.path_index.pools) |*pool| owners = @max(owners, pool.owner_heads.items.len);
    return owners;
}

/// A shrink to `capacity` owner ids: the plan its flush installs with the owner heads'
/// truncation, sized exactly to those ids, so the plan follows the owners down. On error
/// nothing changes.
pub fn prepareRetireTruncate(self: *PathfindingSystem, capacity: usize) error{OutOfMemory}!void {
    var replacement = RetirePlan{};
    errdefer replacement.deinit(self.allocator);
    _ = try replacement.reserve(self.allocator, capacity, ops_per_entry *| capacity, true);
    abortRetireTruncate(self);
    self.path_index.plan_replacement = replacement;
}

pub fn abortRetireTruncate(self: *PathfindingSystem) void {
    if (self.path_index.plan_replacement) |*replacement| replacement.deinit(self.allocator);
    self.path_index.plan_replacement = null;
}

/// Drops every path registration: every chunk's block and payload return to the pool, so
/// registry storage follows registrations, and inverse nodes return to their pools. The
/// directory columns and the node and owner-head storage stay. A prepared owner-head
/// truncation is left for the flush that installs it.
pub fn clearRegistry(self: *PathfindingSystem) void {
    const index = &self.path_index;
    index.directory.releaseAll(self.allocator);
    index.emptied.clearRetainingCapacity();
    for (&index.pools) |*pool| pool.clearNodes();
    self.publish_ranges = 0;
}

/// Opens one directory level per nav level, each with `graph.chunkCount` slots. The same
/// count keeps the runs (a level rebuild's eviction has not flushed yet). A different count
/// is a full rebuild, which has already cleared the runs: the old payloads are freed and the
/// slots reallocated.
pub fn openRegistryLevels(self: *PathfindingSystem, level_count: usize) error{OutOfMemory}!void {
    const levels: u32 = @intCast(level_count);
    const chunks = self.graph.chunkCount();
    const directory = &self.path_index.directory;
    // Held emptied chunks of a closed or emptied level leave the list while every reopened
    // slot is still empty, so the list never names a later chunk at the same place.
    var released = false;
    defer if (released) dropUnheldChunks(&self.path_index);
    var extra = directory.levelCount();
    while (extra > levels) {
        extra -= 1;
        directory.closeLevel(self.allocator, @intCast(extra));
        released = true;
    }
    var level: u32 = 0;
    while (level < levels) : (level += 1) {
        const current = directory.slotCount(level);
        if (current != chunks and current != 0) {
            directory.emptyLevel(self.allocator, level);
            released = true;
        }
        try directory.openLevel(self.allocator, level, chunks);
    }
}

/// Empties the result cache, its owner log, and the registry.
pub fn clearCompleted(self: *PathfindingSystem) void {
    self.completed.clear();
    clearRegistry(self);
}

/// Claims every result of the step in solve-ordinal order, which is pending order
/// (ordinals increase with the pending index): its cache entry and, past the inline
/// stripe, a long block, logging the retire of a re-put or a victim. O(1) per result
/// on the main thread; the paths are copied by `publish_copy`. Allocates nothing after
/// `reservePublish`.
pub fn claimPublish(self: *PathfindingSystem, stats: *PathfindingStats) void {
    std.debug.assert(self.publish_records.capacity >= self.solve_results.items.len);
    self.publish_records.items.len = self.solve_results.items.len;
    self.completed.core.beginPublish();
    for (self.solve_results.items, self.publish_records.items, 0..) |result, *record, ordinal| {
        record.* = null;
        switch (result) {
            .available, .partial => |key| {
                const solved = self.solved_paths.items[ordinal];
                if (self.completed.canStore()) {
                    record.* = self.completed.claim(key, solved.len, solved.stitched_len, solved.path_level, solved.end, solved.goal_cell, self.step_counter, stats);
                }
                if (comptime runtime_perf_log.enabled) {
                    stats.perf.solved_requests += 1;
                    if (result == .partial) stats.perf.partial_results += 1 else stats.perf.available_results += 1;
                    if (solved.via_abstract) stats.perf.abstract_solves += 1;
                    if (solved.cross_level) stats.perf.cross_level_solves += 1;
                }
            },
            // Answered without a search and never cached: dropped in
            // compactPendingAfterSolve.
            .unavailable => if (comptime runtime_perf_log.enabled) {
                stats.perf.unavailable_results += 1;
            },
            .budget_exhausted => if (comptime runtime_perf_log.enabled) {
                stats.perf.budget_exhausted += 1;
            },
            // Start-side failure: dropped in compactPendingAfterSolve, never cached; the
            // next status query falls through to `.missing`.
            .start_invalid => {
                if (comptime runtime_perf_log.enabled) stats.perf.start_invalid_dropped += 1;
            },
            .deferred => continue,
        }
    }
    if (comptime runtime_perf_log.enabled) stats.perf.solve_admissions = self.solve_indices.items.len;
}

/// `publish_copy`: each range copies its claimed results' paths into their stripes or
/// blocks and buckets their path runs' registrations by flush pair into its window,
/// recording each pair's count in its band. The main thread sizes the windows from the
/// selected shape, O(1) per result; inline it is one range. Returns the stage's batch.
pub fn publishCopy(self: *PathfindingSystem, dispatch: Dispatch) BatchStats {
    const item_count = self.solve_results.items.len;
    // The last flush added the previous publish's registrations: a flush that failed is
    // finished at the next update's top (`recoverRegistry`) before any publish.
    std.debug.assert(self.publish_ranges == 0);
    if (item_count == 0) return .{};
    const shape = StageShape.select(dispatch, item_count, 1);
    std.debug.assert(self.publish_range_bases.capacity >= shape.range_count);
    std.debug.assert(self.publish_bands.capacity >= shape.range_count);
    self.publish_range_bases.items.len = shape.range_count;
    self.publish_bands.items.len = shape.range_count;
    var total: usize = 0;
    for (self.publish_range_bases.items, 0..) |*base, range_index| {
        total = std.mem.alignForward(usize, total, reg_window_alignment_items);
        base.* = total;
        const first = range_index * shape.items_per_range;
        for (first..@min(first + shape.items_per_range, item_count)) |ordinal| {
            if (self.publish_records.items[ordinal] != null) total += self.solved_paths.items[ordinal].run_count;
        }
    }
    std.debug.assert(total <= self.reg_buckets.capacity);
    self.reg_buckets.items.len = total;
    var job = PublishCopyJob{
        .system = self,
        .geometry = self.graph.chunkGeometry(),
        .stripe_words = self.stripe_words,
        .items_per_range = shape.items_per_range,
        .range_count = shape.range_count,
        .buckets = self.reg_buckets.items,
        .bands = self.publish_bands.items,
    };
    const batch = runShaped(dispatch, shape, item_count, 1, &job, publishCopyJob);
    self.publish_ranges = shape.range_count;
    return batch;
}

// One range of `publish_copy`: its ordinals' paths into their claimed stripes or blocks,
// and their registrations, shard by shard in (ordinal, run) order, into its window.
const PublishCopyJob = struct {
    system: *const PathfindingSystem,
    geometry: ChunkGeometry,
    stripe_words: usize,
    items_per_range: usize,
    range_count: usize,
    buckets: []RegRecord,
    bands: []PublishBand,
};

// SIMD verdict: the path copy is `@memcpy`; bucketing is a scalar counting-sort scatter
// with one division per run start.
fn publishCopyJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *PublishCopyJob = @ptrCast(@alignCast(context));
    const system = job.system;
    std.debug.assert(range.index < job.range_count and range.index < job.bands.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end and range.end <= system.publish_records.items.len and range.end <= system.solve_results.items.len);
    var counts: [flush_pair_count]u32 = @splat(0);
    for (range.start..range.end) |ordinal| {
        // Only available and partial results claim an entry.
        const claimed = system.publish_records.items[ordinal] orelse continue;
        const solved = system.solved_paths.items[ordinal];
        const words = types.storedPathWords(solved.len, solved.stitched_len);
        // Claims of one publish never share a stripe or a block.
        @memcpy(system.completed.destination(claimed)[0..words], system.worker_path_pool.items[solved.offset..][0..words]);
        for (&counts, solved.shard_counts) |*total, shard_count| total.* += shard_count;
    }
    var cursors: [flush_pair_count]usize = undefined;
    var next = system.publish_range_bases.items[range.index];
    for (&cursors, counts) |*cursor, pair_count| {
        cursor.* = next;
        next += pair_count;
    }
    std.debug.assert(next <= job.buckets.len);
    for (range.start..range.end) |ordinal| {
        const claimed = system.publish_records.items[ordinal] orelse continue;
        const solved = system.solved_paths.items[ordinal];
        const stripe = system.worker_path_pool.items[solved.offset..][0..job.stripe_words];
        const view = types.stitchedView(stripe, solved.stitched_len);
        for (system.worker_run_starts.items[solved.offset..][0..solved.run_count]) |start| {
            const key = if (solved.stitched_len != 0)
                chunkKey(view.levels[start], job.geometry.chunkOfCell(view.cells[start]))
            else
                chunkKey(solved.path_level, job.geometry.chunkOfCell(stripe[start]));
            const shard = registryShard(key);
            job.buckets[cursors[shard]] = .{ .key = key, .owner = claimed.owner, .order = start };
            cursors[shard] += 1;
        }
    }
    job.bands[range.index] = .{ .counts = counts };
}

/// A threaded flush's dispatches: the apply stage under its caller's tuner, and the count
/// dispatch's own tuner. The update's flush and the eviction's flush each own both: the
/// eviction's count items are all retired inverse nodes (a chain walk and a sort of the
/// listed chunks), the update's mostly publish adds (a bucket read and a pending increment).
pub const FlushDispatch = struct {
    apply: Dispatch,
    count_tuner: *AdaptiveWorkTuner,
};

/// True when a flush that ran out of memory left work for the next one: the last publish's
/// registrations, logged owner ops, or a shrink's prepared owner heads. Every update and
/// nav reaction otherwise ends flushed.
pub fn registryBehind(self: *const PathfindingSystem) bool {
    return self.publish_ranges != 0 or self.completed.core.ownerLog().len != 0 or self.registry_truncate_pending;
}

/// Finishes the work a failed flush left (`registryBehind`) before anything publishes, logs
/// more owner ops, resizes, or reads the registry: a later publish copy would overwrite the
/// pending registrations, and a retire logged after them would leave them naming a dead
/// owner. A one-off, so it runs at the fixed shape outside the tuners, as a shrink's flush.
/// Does nothing when the registry is current. On `OutOfMemory` it is still behind, for retry.
pub fn recoverRegistry(self: *PathfindingSystem, dispatch: ?FlushDispatch) error{OutOfMemory}!void {
    if (!registryBehind(self)) return;
    self.registry_flush_fixed = true;
    _ = try flushRegistry(self, dispatch, null);
}

/// `registry_flush`: shard by shard, applies the owner ops on the shard's chains in log
/// order (a retire marks its chain, a rename moves its head), compacts the chunks a retire
/// touched (survivors keep their order), then appends the last publish copy's
/// registrations of the shard in range order, and installs a shrink's prepared owner heads.
/// The plan buckets the log by shard once on the main thread. Count runs first and does not
/// mutate runs. The main thread then reallocates a chunk whose cap cannot hold its adds
/// (`reserveRegistryPayloads`, the flush's growth seam). A flush that renames rewrites every
/// registration's owner in one pass over the block pool (`registry_rename`) before the
/// apply. On `OutOfMemory` the runs are unchanged, `pending` is cleared, and the publish's
/// registrations, the log, and a prepared truncation stay for the retry
/// (`recoverRegistry`). Each pair (shard) writes only its shard and its tally. After the
/// apply join the main thread holds every compacted chunk left without registrations, and a
/// flush of a later step, with work or not, releases the block of each held chunk still
/// empty. Then the log is emptied and the replaced owner heads and plan are freed.
/// `stats` (when given) takes the apply batch; the count and rename batches are
/// perf-log-gated bench output (`PathfindingStats.Perf`).
/// Count items: pair p weighs its adds + its ops + the inverse nodes its retires mark + 1.
/// Apply items: the live lengths of the chunks it compacts + its adds + its ops + the
/// nodes its retires mark + 1. A range runs the pairs whose first unit lies in it. A
/// shrink, a rebuild, or a recovery flush runs both dispatches at a fixed shape of about
/// one pair per range, outside the tuners; the rename pass always does. A dispatch wakes at
/// most one worker fewer than the pair count. Returns the apply batch.
pub fn flushRegistry(self: *PathfindingSystem, dispatch: ?FlushDispatch, stats: ?*PathfindingStats) error{OutOfMemory}!BatchStats {
    // A failed flush leaves the fixed shape to the flush that finishes it, never a later one.
    defer self.registry_flush_fixed = false;
    var batch = BatchStats{};
    const truncate = self.registry_truncate_pending;
    const ops = self.completed.core.ownerLog();
    var count_batch = BatchStats{};
    var rename_batch = BatchStats{};
    if (ops.len != 0 or self.publish_ranges != 0 or truncate) {
        var pair_adds: [flush_pair_count]usize = @splat(0);
        // SIMD verdict: scalar. A 16-wide sum per publish range, a tiny fixed batch.
        for (self.publish_bands.items[0..self.publish_ranges]) |band| {
            for (&pair_adds, band.counts) |*adds, count| adds.* += count;
        }
        const planned = try planOwnerLog(self, ops);
        const fix = truncate or self.registry_flush_fixed;
        count_batch = try runRegistryCount(self, dispatch, ops, pair_adds, fix);
        try reserveRegistryPayloads(self);
        if (planned.renamed_nodes != 0) rename_batch = runRegistryRename(self, if (dispatch) |stage| stage.apply else null);
        var apply_units: [flush_pair_count]usize = undefined;
        for (&apply_units, &self.path_index.counts, pair_adds, self.path_index.shard_op_count, self.path_index.retire_node_count) |*units, *counted, adds, shard_ops, retired| {
            units.* = counted.value.compact_len + adds + shard_ops + retired + 1;
        }
        batch = runRegistryApply(self, if (dispatch) |stage| stage.apply else null, ops, apply_units, fix);
        releaseEmptiedChunks(self);
        holdEmptiedChunks(self);
        if (comptime runtime_perf_log.enabled) {
            if (stats) |step| {
                for (self.flush_tallies) |tally| {
                    step.perf.registrations_removed += tally.removed;
                    step.perf.registrations_added += tally.added;
                }
            }
        }
    } else if (self.path_index.emptied_step != self.step_counter) releaseEmptiedChunks(self);
    if (comptime runtime_perf_log.enabled) {
        self.perf.last_flush_count_batch = count_batch;
        self.perf.last_flush_rename_batch = rename_batch;
        if (stats) |step| {
            step.perf.registry_flush_count_batch = count_batch;
            step.perf.registry_rename_batch = rename_batch;
        }
    }
    self.publish_ranges = 0;
    self.completed.core.finishOwnerLog(self.allocator);
    if (truncate) {
        const index = &self.path_index;
        for (&index.pools) |*pool| pool.releaseTruncated(self.allocator);
        if (index.plan_replacement) |replacement| {
            index.plan.deinit(self.allocator);
            index.plan = replacement;
            index.plan_replacement = null;
        }
        self.registry_truncate_pending = false;
    }
    return batch;
}

/// What the plan found: the inverse nodes of the chains the log renames, over every shard.
const PlanTotals = struct {
    renamed_nodes: usize = 0,
};

// The id's place in the plan, listing it on first sight with the shards its pre-flush
// chain has nodes in: one head read per shard.
// SIMD verdict: scalar. Sixteen head reads from sixteen pools, a tiny fixed batch.
fn planSlot(index: *PathIndex, owner: u32) u32 {
    const plan = &index.plan;
    const at = &plan.at.items[owner];
    if (at.* == no_entry) {
        at.* = @intCast(plan.ids.items.len);
        var shards: ShardMask = 0;
        for (&index.pools, 0..) |*pool, shard| {
            const heads = pool.owner_heads.items;
            if (owner < heads.len and heads[owner].node != no_entry) shards |= @as(ShardMask, 1) << @intCast(shard);
        }
        plan.ids.appendAssumeCapacity(owner);
        plan.origin.appendAssumeCapacity(owner);
        plan.shards.appendAssumeCapacity(shards);
    }
    return at.*;
}

// The owner log's plan, once for every shard, on the main thread. Head moves in log order
// on the owner ids the log names (below the heads' count; ids past it hold no chain and
// receive none): each listed id tracks which id's pre-flush chain it holds, a rename moves
// that origin to the new id and a retire ends it. Every chain moves whole, so an op touches
// exactly the shards its origin's pre-flush chain has nodes in. Then the log is bucketed by
// shard (`shard_ops`, log order within a shard), each shard's retired nodes are summed for
// the count windows and both dispatches' weights, and the renamed nodes for the rename
// pass. Does not touch runs or the live heads. O(logged ops + 16 per listed id + the ops'
// shard entries): O(1) per item, no sort or search. On error `at` stays all `no_entry`.
// SIMD verdict: scalar. Sequential head moves, each depending on the ops before it, and a
// counting-sort scatter by shard bit.
fn planOwnerLog(self: *PathfindingSystem, ops: []const OwnerOp) error{OutOfMemory}!PlanTotals {
    const index = &self.path_index;
    const plan = &index.plan;
    const owners = ownerIds(self);
    if (try plan.reserve(self.allocator, owners, ops.len, false)) countRegistryGrowth(self, 1);
    std.debug.assert(owners <= std.math.maxInt(u32) and ops.len <= std.math.maxInt(u32));
    std.debug.assert(plan.at.items.len >= owners and plan.rename_to.items.len >= owners);
    const limit: u32 = @intCast(owners);
    plan.ids.clearRetainingCapacity();
    plan.origin.clearRetainingCapacity();
    plan.shards.clearRetainingCapacity();
    plan.ops.items.len = ops.len;
    var shard_ops: [flush_pair_count]usize = @splat(0);
    for (ops, plan.ops.items) |op, *planned| {
        planned.* = .{};
        if (op.old >= limit) continue;
        const old = planSlot(index, op.old);
        const origin = plan.origin.items[old];
        plan.origin.items[old] = no_entry;
        if (origin != no_entry) {
            planned.* = .{ .origin = origin, .shards = plan.shards.items[plan.at.items[origin]] };
            var bits = planned.shards;
            while (bits != 0) : (bits &= bits - 1) shard_ops[@ctz(bits)] += 1;
        }
        if (op.new == no_owner) continue;
        // The log only renames onto an id below the heads' count that holds no chain.
        std.debug.assert(op.new < limit);
        const dest = planSlot(index, op.new);
        if (std.debug.runtime_safety) {
            const held = plan.origin.items[dest];
            if (held == op.new) std.debug.assert(plan.shards.items[dest] == 0) else std.debug.assert(held == no_entry);
        }
        plan.origin.items[dest] = origin;
    }
    for (plan.ids.items) |owner| plan.at.items[owner] = no_entry;
    var total: usize = 0;
    var cursors: [flush_pair_count]usize = undefined;
    for (&cursors, shard_ops) |*cursor, count| {
        cursor.* = total;
        total += count;
    }
    if (total > index.shard_ops.capacity) {
        try index.shard_ops.ensureTotalCapacity(self.allocator, total);
        countRegistryGrowth(self, 1);
    }
    index.shard_ops.items.len = total;
    index.shard_op_base = cursors;
    index.shard_op_count = shard_ops;
    var retired: [flush_pair_count]usize = @splat(0);
    var totals = PlanTotals{};
    for (ops, plan.ops.items, 0..) |op, planned, op_index| {
        var bits = planned.shards;
        while (bits != 0) : (bits &= bits - 1) {
            const shard = @ctz(bits);
            index.shard_ops.items[cursors[shard]] = @intCast(op_index);
            cursors[shard] += 1;
            const nodes = index.pools[shard].owner_heads.items[planned.origin].len;
            if (op.new == no_owner) retired[shard] += nodes else totals.renamed_nodes += nodes;
        }
    }
    index.retire_node_count = retired;
    return totals;
}

fn shapedDispatch(stage: Dispatch, units: usize, fix: bool, tuner: *AdaptiveWorkTuner) Dispatch {
    var shaped = stage;
    shaped.tuner = tuner;
    shaped.max_worker_threads = @min(stage.max_worker_threads orelse flush_pair_count - 1, flush_pair_count - 1);
    if (fix and stage.adaptive and stage.items_per_range == null) {
        shaped.items_per_range = @divCeil(@max(units, 1), flush_pair_count);
    }
    return shaped;
}

// SIMD verdict: scalar. A 16-entry prefix sum, a tiny fixed batch.
fn unitStarts(weights: [flush_pair_count]usize) struct { starts: [flush_pair_count + 1]usize, total: usize } {
    var starts: [flush_pair_count + 1]usize = undefined;
    var total: usize = 0;
    for (starts[0..flush_pair_count], weights) |*start, weight| {
        start.* = total;
        total += weight;
    }
    starts[flush_pair_count] = total;
    return .{ .starts = starts, .total = total };
}

fn runRegistryCount(
    self: *PathfindingSystem,
    dispatch: ?FlushDispatch,
    ops: []const OwnerOp,
    pair_adds: [flush_pair_count]usize,
    fix: bool,
) error{OutOfMemory}!BatchStats {
    const index = &self.path_index;
    var weights: [flush_pair_count]usize = undefined;
    for (&weights, pair_adds, index.shard_op_count, index.retire_node_count) |*weight, adds, shard_ops, nodes| weight.* = adds + shard_ops + nodes + 1;
    const counted = unitStarts(weights);
    try reserveCountWindows(self, pair_adds, index.retire_node_count);
    const count_dispatch: ?Dispatch = if (dispatch) |stage| shapedDispatch(stage.apply, counted.total, fix, stage.count_tuner) else null;
    const shape = StageShape.select(count_dispatch, counted.total, 1);
    var job = RegistryCountJob{
        .system = self,
        .ops = ops,
        .publish_ranges = self.publish_ranges,
        .range_count = shape.range_count,
        .unit_starts = counted.starts,
    };
    return runShaped(count_dispatch, shape, counted.total, 1, &job, registryCountJob);
}

// SIMD verdict: scalar. A 16-entry aligned prefix, a tiny fixed batch.
fn reserveCountWindows(self: *PathfindingSystem, pair_adds: [flush_pair_count]usize, retire_nodes: [flush_pair_count]usize) error{OutOfMemory}!void {
    var cursor: usize = 0;
    var bases: [flush_pair_count]usize = undefined;
    for (&bases, pair_adds, retire_nodes) |*base, adds, nodes| {
        cursor = std.mem.alignForward(usize, cursor, chunk_ref_align);
        base.* = cursor;
        cursor += adds + nodes;
    }
    const index = &self.path_index;
    var grows: u64 = 0;
    if (cursor > index.growth.capacity) {
        try index.growth.ensureTotalCapacity(self.allocator, cursor);
        grows += 1;
    }
    if (cursor > index.compact.capacity) {
        try index.compact.ensureTotalCapacity(self.allocator, cursor);
        grows += 1;
    }
    if (grows != 0) countRegistryGrowth(self, grows);
    index.growth.items.len = cursor;
    index.compact.items.len = cursor;
    index.growth_base = bases;
    index.compact_base = bases;
}

// `registry_rename`, after the payload growth and before the apply: the plan's renames
// rewrite the owner of every registration in one pass over the block pool, one item per
// block (a chunk's run), instead of walking each renamed chain. `rename_to` maps each
// renamed chain's pre-flush owner to the id its chain ends on, set here on the main thread
// (O(listed ids)) and reset to the identity after the join. A one-off of a cache shrink, so
// it runs at a fixed shape of about a sixteenth of the pool per range, outside the tuners.
// Returns the stage's batch.
// SIMD verdict: scalar. The `rename_to` set and reset are sparse scatters over the listed
// ids.
fn runRegistryRename(self: *PathfindingSystem, dispatch: ?Dispatch) BatchStats {
    const index = &self.path_index;
    const plan = &index.plan;
    for (plan.ids.items, plan.origin.items) |id, origin| {
        if (origin != no_entry and origin != id) plan.rename_to.items[origin] = id;
    }
    const blocks = index.directory.blocks.items;
    const rename_dispatch: ?Dispatch = if (dispatch) |stage| shapedDispatch(stage, blocks.len, true, stage.tuner) else null;
    const shape = StageShape.select(rename_dispatch, blocks.len, 1);
    var job = RegistryRenameJob{
        .blocks = blocks,
        .rename_to = plan.rename_to.items,
        .range_count = shape.range_count,
    };
    const batch = runShaped(rename_dispatch, shape, blocks.len, 1, &job, registryRenameJob);
    for (plan.ids.items, plan.origin.items) |id, origin| {
        if (origin != no_entry and origin != id) plan.rename_to.items[origin] = origin;
    }
    return batch;
}

const RegistryRenameJob = struct {
    blocks: []const RegistryDirectory.Block,
    rename_to: []const u32,
    range_count: usize,
};

// SIMD verdict: SIMD. Each run's owner column streams through `rename_to` in u32 lane gathers,
// its tail the same gather on one masked lane batch. Ranges write only their own blocks'
// payloads, separate allocations.
fn registryRenameJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *RegistryRenameJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.blocks.len);
    const rename_to = job.rename_to;
    for (job.blocks[range.start..range.end]) |block| {
        const owners = block.payload.owner[0..block.payload.len];
        var row: usize = 0;
        while (row + simd.lane_count <= owners.len) : (row += simd.lane_count) {
            const renamed = simd.gatherUint4(rename_to, simd.loadUint4(owners[row..]));
            simd.storeUint4Slice(owners[row..], renamed);
        }
        const tail = owners.len - row;
        if (tail != 0) {
            const renamed = simd.gatherUint4Masked(rename_to, simd.loadUint4Prefix(owners[row..], tail), simd.lanesBelow(tail));
            simd.storeUint4Prefix(owners[row..], renamed, tail);
        }
    }
}

fn runRegistryApply(
    self: *PathfindingSystem,
    dispatch: ?Dispatch,
    ops: []const OwnerOp,
    weights: [flush_pair_count]usize,
    fix: bool,
) BatchStats {
    const counted = unitStarts(weights);
    const apply_dispatch: ?Dispatch = if (dispatch) |stage| shapedDispatch(stage, counted.total, fix, stage.tuner) else null;
    const shape = StageShape.select(apply_dispatch, counted.total, 1);
    var job = RegistryApplyJob{
        .system = self,
        .ops = ops,
        .publish_ranges = self.publish_ranges,
        .truncate = self.registry_truncate_pending,
        .range_count = shape.range_count,
        .unit_starts = counted.starts,
    };
    return runShaped(apply_dispatch, shape, counted.total, 1, &job, registryApplyJob);
}

// The flush's growth seam, on the main thread between the count join and the apply
// dispatch: every chunk the count listed whose cap cannot hold its adds gets a geometric
// payload (and, when it held none, a block), all or nothing. Each payload allocation, block
// claim, and growth of the block pool or the fresh list is counted in `registry_growth`.
// SIMD verdict: scalar. One allocation and copy per grown chunk, allocator-bound.
fn reserveRegistryPayloads(self: *PathfindingSystem) error{OutOfMemory}!void {
    const index = &self.path_index;
    var listed: usize = 0;
    for (&index.counts) |counted| listed += counted.value.growth;
    index.fresh.clearRetainingCapacity();
    const fresh_capacity = index.fresh.capacity;
    const block_capacity = index.directory.blocks.capacity;
    const emptied_capacity = index.emptied.capacity;
    index.fresh.ensureTotalCapacity(self.allocator, listed) catch {
        clearCountedPending(self);
        return error.OutOfMemory;
    };
    var shard: usize = 0;
    while (shard < flush_pair_count) : (shard += 1) {
        const base = index.growth_base[shard];
        const count = index.counts[shard].value.growth;
        for (index.growth.items[base..][0..count]) |ref| {
            growChunk(self, ref) catch {
                index.abortFresh(self.allocator);
                clearCountedPending(self);
                return error.OutOfMemory;
            };
        }
    }
    // The held emptied chunks are distinct chunks holding blocks, so the list grows with the
    // block pool's storage, here: keyed on capacity, so blocks claimed from the pool's slack
    // allocate nothing.
    index.emptied.ensureTotalCapacity(self.allocator, index.directory.blocks.capacity) catch {
        index.abortFresh(self.allocator);
        clearCountedPending(self);
        return error.OutOfMemory;
    };
    var grows: u64 = @as(u64, @intFromBool(index.fresh.capacity != fresh_capacity)) + @intFromBool(index.directory.blocks.capacity != block_capacity) +
        @intFromBool(index.emptied.capacity != emptied_capacity);
    for (index.fresh.items) |item| {
        if (item.old_bytes.len != 0) freePayload(self.allocator, item.old_bytes);
        index.directory.setPayload(item.block, item.bytes, item.columns);
        if (item.is_new) index.directory.setSlot(item.level, item.chunk, item.block);
        std.debug.assert(item.columns.cap >= item.columns.len);
        grows += 1 + @as(u64, @intFromBool(item.is_new));
    }
    if (grows != 0) countRegistryGrowth(self, grows);
    index.fresh.clearRetainingCapacity();
    clearCountedPending(self);
}

// After a flush's apply join, or in a flush with no work: at a flush of a later step than
// the one that held them, every held chunk still without registrations returns its block and
// payload, so registry storage follows the chunks holding registrations with one step's lag,
// and the list empties. At a flush of the same step, a held chunk published again leaves the
// list, so every listed chunk holds a block and no registration after each flush, and the
// list never names a chunk twice. A held chunk whose level closed or emptied reads
// `empty_block`. O(held chunks) on the main thread, in list order, so block ids never depend
// on workers.
// SIMD verdict: scalar. A sparse walk of the held chunks with one free each,
// allocator-bound.
fn releaseEmptiedChunks(self: *PathfindingSystem) void {
    const index = &self.path_index;
    const directory = &index.directory;
    if (index.emptied_step == self.step_counter) return dropUnheldChunks(index);
    for (index.emptied.items) |ref| {
        const block = directory.slot(ref.level, ref.chunk);
        if (block == empty_block or directory.payload(block).len != 0) continue;
        directory.release(self.allocator, block);
        directory.setSlot(ref.level, ref.chunk, empty_block);
    }
    index.emptied.clearRetainingCapacity();
    index.emptied_step = self.step_counter;
}

// Drops every listed chunk that holds registrations again or no longer holds a block.
// SIMD verdict: scalar. An in-place filter of the sparse held list.
fn dropUnheldChunks(index: *PathIndex) void {
    var kept: usize = 0;
    for (index.emptied.items) |ref| {
        const block = index.directory.slot(ref.level, ref.chunk);
        if (block == empty_block or index.directory.payload(block).len != 0) continue;
        index.emptied.items[kept] = ref;
        kept += 1;
    }
    index.emptied.items.len = kept;
}

// After the apply join and `releaseEmptiedChunks`: every chunk a retire compacted that holds
// no registration now is held (`PathIndex.emptied`). A compacted chunk held registrations
// after the last flush, so it is not listed yet; room for one ref per block is reserved at
// the growth seam. O(compacted chunks) on the main thread, in shard order.
// SIMD verdict: scalar. A sparse walk of the compacted chunks.
fn holdEmptiedChunks(self: *PathfindingSystem) void {
    const index = &self.path_index;
    std.debug.assert(index.emptied_step == self.step_counter);
    for (&index.counts, index.compact_base) |counted, base| {
        for (index.compact.items[base..][0..counted.value.compact]) |ref| {
            const block = index.directory.slot(ref.level, ref.chunk);
            if (block == empty_block or index.directory.payload(block).len != 0) continue;
            std.debug.assert(index.emptied.items.len < index.emptied.capacity);
            index.emptied.appendAssumeCapacity(ref);
        }
    }
}

fn growChunk(self: *PathfindingSystem, ref: ChunkRef) error{OutOfMemory}!void {
    const directory = &self.path_index.directory;
    const block = directory.slot(ref.level, ref.chunk);
    const pending = directory.pending(ref.level, ref.chunk).*;
    const old = if (block == empty_block) RegChunk{} else directory.payload(block);
    if (old.len + pending <= old.cap) return;
    const new_cap = try geometricCap(old.cap, old.len, pending);
    const bytes = try allocPayload(self.allocator, regBytes(new_cap));
    var committed = false;
    errdefer if (!committed) freePayload(self.allocator, bytes);
    const is_new = block == empty_block;
    const installed = if (is_new) try directory.claim(self.allocator) else block;
    errdefer if (!committed and is_new) directory.release(self.allocator, installed);
    var columns = splitReg(bytes, new_cap);
    if (old.len != 0) {
        @memcpy(columns.owner[0..old.len], old.owner[0..old.len]);
        @memcpy(columns.order[0..old.len], old.order[0..old.len]);
        @memcpy(columns.inverse[0..old.len], old.inverse[0..old.len]);
        columns.len = old.len;
    }
    self.path_index.fresh.appendAssumeCapacity(.{
        .level = ref.level,
        .chunk = ref.chunk,
        .block = installed,
        .bytes = bytes,
        .columns = columns,
        .is_new = is_new,
        .old_bytes = if (is_new) &.{} else directory.blockBytes(block),
    });
    committed = true;
}

// SIMD verdict: scalar. A sparse scatter over the grown chunks.
fn clearCountedPending(self: *PathfindingSystem) void {
    const index = &self.path_index;
    for (&index.counts, index.growth_base) |counted, base| {
        for (index.growth.items[base..][0..counted.value.growth]) |ref| {
            index.directory.pending(ref.level, ref.chunk).* = 0;
        }
    }
}

fn geometricCap(cap: u32, len: u32, pending: u32) error{OutOfMemory}!u32 {
    // `cap * 2` is the doubling. When that does not already exceed the records the chunk
    // must hold, one spare slot keeps the next single add from allocating.
    const fit = @as(u64, len) + pending;
    var need = @max(@as(u64, cap) * 2, fit);
    if (need == fit) need += 1;
    if (need >= empty_block) return error.OutOfMemory;
    const shift: u6 = @intCast(std.math.log2_int_ceil(u64, need));
    const rounded = @as(u64, 1) << shift;
    if (rounded >= empty_block) return error.OutOfMemory;
    return @intCast(rounded);
}

fn regBytes(cap: u32) usize {
    return @as(usize, cap) * reg_row_bytes;
}

fn allocPayload(allocator: std.mem.Allocator, size: usize) error{OutOfMemory}![]align(4) u8 {
    if (size == 0) return &.{};
    return try allocator.alignedAlloc(u8, .@"4", size);
}

fn freePayload(allocator: std.mem.Allocator, bytes: []align(4) u8) void {
    if (bytes.len == 0) return;
    allocator.free(bytes);
}

fn splitReg(bytes: []align(4) u8, cap: u32) RegChunk {
    var offset: usize = 0;
    return .{
        .cap = cap,
        .owner = takeU32(bytes, &offset, cap),
        .order = takeU32(bytes, &offset, cap),
        .inverse = takeU32(bytes, &offset, cap),
    };
}

fn takeU32(bytes: []align(4) u8, offset: *usize, count: u32) []u32 {
    if (count == 0) return &.{};
    const start = offset.*;
    const byte_len = @as(usize, count) * @sizeOf(u32);
    offset.* = start + byte_len;
    const aligned: []align(@alignOf(u32)) u8 = @alignCast(bytes[start..][0..byte_len]);
    return std.mem.bytesAsSlice(u32, aligned);
}

fn chunkRefLess(_: void, a: ChunkRef, b: ChunkRef) bool {
    if (a.level != b.level) return a.level < b.level;
    return a.chunk < b.chunk;
}

/// Registrations on `key`, or zero when the chunk was never published.
pub fn registrationLen(directory: *const RegistryDirectory, key: u64) u32 {
    const block = directory.slot(keyLevel(key), keyChunk(key));
    if (block == empty_block) return 0;
    return directory.payload(block).len;
}

/// The chunk's registration columns, or an empty run.
pub fn registrationRun(directory: *const RegistryDirectory, key: u64) RegChunk {
    const block = directory.slot(keyLevel(key), keyChunk(key));
    if (block == empty_block) return .{};
    return directory.payload(block);
}

const RegistryCountJob = struct {
    system: *PathfindingSystem,
    ops: []const OwnerOp,
    publish_ranges: usize,
    range_count: usize,
    unit_starts: [flush_pair_count + 1]usize,
};

fn orderUnit(unit: usize, start: usize) std.math.Order {
    return std.math.order(unit, start);
}

// SIMD verdict: scalar. One pending increment per add and one node step per retire; one
// binary search over the pair starts per range.
fn registryCountJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *RegistryCountJob = @ptrCast(@alignCast(context));
    const system = job.system;
    const starts = job.unit_starts[0..flush_pair_count];
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.unit_starts[flush_pair_count]);
    var pair = std.sort.lowerBound(usize, starts, range.start, orderUnit);
    while (pair < flush_pair_count and starts[pair] < range.end) : (pair += 1) {
        countShard(system, pair, job.ops, job.publish_ranges);
    }
}

fn countShard(system: *PathfindingSystem, pair: usize, ops: []const OwnerOp, publish_ranges: usize) void {
    const index = &system.path_index;
    const pool = &index.pools[pair];
    const directory = &index.directory;
    var growth = index.growth.items[index.growth_base[pair]..];
    var compact = index.compact.items[index.compact_base[pair]..];
    var grown: u32 = 0;
    for (system.publish_bands.items[0..publish_ranges], system.publish_range_bases.items[0..publish_ranges]) |band, base| {
        var start = base;
        for (band.counts[0..pair]) |pair_count| start += pair_count;
        for (system.reg_buckets.items[start..][0..band.counts[pair]]) |record| {
            const level = keyLevel(record.key);
            const chunk = keyChunk(record.key);
            const pending = directory.pending(level, chunk);
            if (pending.* == 0) {
                growth[grown] = .{ .level = level, .chunk = chunk };
                grown += 1;
            }
            pending.* += 1;
        }
    }
    // The pre-flush chains the shard's retires mark, from the live heads of their origins:
    // a rename onto an id, then a retire of that id, marks the moved chain.
    var listed: u32 = 0;
    const heads = pool.owner_heads.items;
    const plans = index.plan.ops.items;
    for (index.shard_ops.items[index.shard_op_base[pair]..][0..index.shard_op_count[pair]]) |op_index| {
        if (ops[op_index].new != no_owner) continue;
        var node = heads[plans[op_index].origin].node;
        while (node != no_entry) : (node = pool.node_next[node]) {
            std.debug.assert(@as(usize, listed) < index.retire_node_count[pair]);
            const key = pool.node_chunk[node];
            compact[listed] = .{ .level = keyLevel(key), .chunk = keyChunk(key) };
            listed += 1;
        }
    }
    std.debug.assert(@as(usize, listed) == index.retire_node_count[pair]);
    const compact_slice = compact[0..listed];
    pdq(ChunkRef, compact_slice, {}, chunkRefLess);
    var unique: u32 = 0;
    var compact_len: usize = 0;
    for (compact_slice) |ref| {
        if (unique != 0 and compact_slice[unique - 1].level == ref.level and compact_slice[unique - 1].chunk == ref.chunk) continue;
        compact_slice[unique] = ref;
        compact_len += registrationLen(directory, chunkKey(ref.level, ref.chunk));
        unique += 1;
    }
    index.counts[pair].value = .{ .growth = grown, .compact = unique, .compact_len = compact_len };
}

const RegistryApplyJob = struct {
    system: *PathfindingSystem,
    ops: []const OwnerOp,
    publish_ranges: usize,
    truncate: bool,
    range_count: usize,
    unit_starts: [flush_pair_count + 1]usize,
};

// SIMD verdict: scalar. In-place compact and append; not a float stream. One binary search
// over the pair starts per range.
fn registryApplyJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *RegistryApplyJob = @ptrCast(@alignCast(context));
    const system = job.system;
    const starts = job.unit_starts[0..flush_pair_count];
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.unit_starts[flush_pair_count]);
    var pair = std.sort.lowerBound(usize, starts, range.start, orderUnit);
    while (pair < flush_pair_count and starts[pair] < range.end) : (pair += 1) {
        applyShard(system, pair, job.ops, job.publish_ranges, job.truncate);
    }
}

fn applyShard(system: *PathfindingSystem, pair: usize, ops: []const OwnerOp, publish_ranges: usize, truncate: bool) void {
    const index = &system.path_index;
    const pool = &index.pools[pair];
    const directory = &index.directory;
    // The shard's ops in log order: a retire after a rename must see the chain on its new
    // owner. The rename pass already rewrote the registrations' owners, so a rename moves
    // the head alone. Compact follows, so every mark is in place and survivor indices are
    // rewritten once.
    var removed: usize = 0;
    for (index.shard_ops.items[index.shard_op_base[pair]..][0..index.shard_op_count[pair]]) |op_index| {
        const op = ops[op_index];
        std.debug.assert(pool.holdsOwner(op.old));
        if (op.new == no_owner) {
            removed += pool.owner_heads.items[op.old].len;
            markRetired(pool, op.old);
        } else moveChain(pool, op.old, op.new);
    }
    const compact_base = index.compact_base[pair];
    const compact_count = index.counts[pair].value.compact;
    for (index.compact.items[compact_base..][0..compact_count]) |ref| compactChunk(directory, pool, ref);
    var added: usize = 0;
    for (system.publish_bands.items[0..publish_ranges], system.publish_range_bases.items[0..publish_ranges]) |band, base| {
        var start = base;
        for (band.counts[0..pair]) |pair_count| start += pair_count;
        const records = system.reg_buckets.items[start..][0..band.counts[pair]];
        appendRecords(directory, pool, records);
        added += records.len;
    }
    if (truncate) pool.installTruncate();
    if (comptime runtime_perf_log.enabled) system.flush_tallies[pair] = .{ .removed = removed, .added = added };
}

fn markRetired(pool: *InversePool, owner: u32) void {
    var node = pool.owner_heads.items[owner].node;
    while (node != no_entry) {
        const next = pool.node_next[node];
        pool.node_index[node] = no_entry;
        node = next;
    }
    pool.owner_heads.items[owner] = .{};
}

fn compactChunk(directory: *RegistryDirectory, pool: *InversePool, ref: ChunkRef) void {
    const block = directory.slot(ref.level, ref.chunk);
    if (block == empty_block) return;
    const run = directory.payloadMut(block);
    var write: u32 = 0;
    var index: u32 = 0;
    while (index < run.len) : (index += 1) {
        const node = run.inverse[index];
        if (pool.node_index[node] == no_entry) {
            std.debug.assert(pool.node_free.items.len < pool.node_free.capacity);
            pool.node_free.appendAssumeCapacity(node);
            continue;
        }
        run.owner[write] = run.owner[index];
        run.order[write] = run.order[index];
        run.inverse[write] = node;
        pool.node_index[node] = write;
        write += 1;
    }
    run.len = write;
    std.debug.assert(run.cap >= run.len);
}

// A rename's head move; its registrations' owners were rewritten by the rename pass.
fn moveChain(pool: *InversePool, old: u32, new: u32) void {
    std.debug.assert(new < pool.owner_heads.items.len);
    std.debug.assert(pool.owner_heads.items[new].node == no_entry);
    pool.owner_heads.items[new] = pool.owner_heads.items[old];
    pool.owner_heads.items[old] = .{};
}

fn appendRecords(directory: *RegistryDirectory, pool: *InversePool, records: []const RegRecord) void {
    std.debug.assert(pool.node_free.items.len >= records.len);
    for (records) |record| {
        const block = directory.slot(keyLevel(record.key), keyChunk(record.key));
        const run = directory.payloadMut(block);
        std.debug.assert(run.len < run.cap);
        const at = run.len;
        run.owner[at] = record.owner;
        run.order[at] = record.order;
        std.debug.assert(pool.node_free.items.len != 0);
        std.debug.assert(record.owner < pool.owner_heads.items.len);
        const node = pool.node_free.pop().?;
        const head = &pool.owner_heads.items[record.owner];
        pool.node_next[node] = head.node;
        pool.node_chunk[node] = record.key;
        pool.node_index[node] = at;
        head.node = node;
        head.len += 1;
        run.inverse[at] = node;
        run.len = at + 1;
    }
}

// ----------------------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------------------

const test_support = @import("test_support.zig");
const updatePathfindingInline = @import("test_support.zig").updatePathfindingInline;
const math = @import("../../../core/math.zig");
const DataSystem = @import("../../data_system.zig").DataSystem;
const RangeOutputStream = @import("../../simulation.zig").RangeOutputStream;
const PathRequest = @import("../../simulation.zig").PathRequest;
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const PathfindingConfig = @import("types.zig").PathfindingConfig;
const PathQueryKey = @import("types.zig").PathQueryKey;
const PathStatus = @import("types.zig").PathStatus;
const emptyKey = @import("types.zig").emptyKey;
const no_colliders = &test_support.no_colliders;
const appendIndividual = test_support.appendIndividual;
const appendPathRequest = test_support.appendPathRequest;
const baselineCapacity = test_support.baselineCapacity;
const cachedPathCells = test_support.cachedPathCells;
const cellWorld = test_support.cellWorld;
const expectGoalsSolved = test_support.expectGoalsSolved;
const expectRegistryMatchesCache = test_support.expectRegistryMatchesCache;
const expectSameCache = test_support.expectSameCache;
const expectSameRegistry = test_support.expectSameRegistry;
const fixed_threads_config = test_support.fixed_threads_config;
const loadTestWorldMeta = test_support.loadTestWorldMeta;
const publishTestPath = test_support.publishTestPath;
const registryRoute = test_support.registryRoute;
const registryRouteKey = test_support.registryRouteKey;
const registrySystem = test_support.registrySystem;
const registrySystemWith = test_support.registrySystemWith;
const registryWorld = test_support.registryWorld;
const setRegistryCells = test_support.setRegistryCells;
const setSystemAllocators = test_support.setSystemAllocators;
const shrinkFixture = test_support.shrinkFixture;
const solveIndividualGoals = test_support.solveIndividualGoals;
const solveRegistryRoutes = test_support.solveRegistryRoutes;
const cachedStep = test_support.cachedStep;

// Work units of a registry flush that adds `adds` registrations and applies no op: one per
// pair and one per add.
fn flushUnits(adds: usize) usize {
    return flush_pair_count + adds;
}

// The last update published routes `[first, first + count)` of a registry world `side` tiles
// a side.
fn expectRoutesSolved(system: *const PathfindingSystem, side: u16, first: usize, count: usize) !void {
    for (first..first + count) |index| {
        try std.testing.expectEqual(@as(?u32, system.step_counter), cachedStep(system, registryRouteKey(system, index, side)));
    }
}

test "solve results land at their solve ordinal and publish in pending order" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    const goals = [_]math.Vec2{ cellWorld(6, 1), cellWorld(6, 3), cellWorld(6, 5), cellWorld(6, 7) };
    for (goals) |goal| try appendIndividual(&stream, requester, goal);
    _ = try updatePathfindingInline(&system, &stream, 8, .{ .max_solve_admissions_per_step = 0 });
    try std.testing.expectEqual(goals.len, system.pending.len);
    // Pending 0 and 1 are escalated: the one-per-step tier-1 cap admits 0 and defers 1,
    // so ordinals 0, 1, 2 hold pending 0, 2, 3.
    system.pending.atPtr(0).tier = 1;
    system.pending.atPtr(1).tier = 1;
    var keys: [goals.len]PathQueryKey = undefined;
    for (&keys, 0..) |*key, index| key.* = system.pending.at(index).key;

    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    _ = try updatePathfindingInline(&system, &empty, 8, .{});
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 3 }, system.solve_indices.items);
    try std.testing.expectEqual(@as(usize, 3), system.solve_results.items.len);
    const stride = system.stripe_words;
    for (system.solve_results.items, system.solved_paths.items, 0..) |result, solved, ordinal| {
        const key = keys[system.solve_indices.items[ordinal]];
        try std.testing.expectEqualDeep(key, result.available);
        try std.testing.expectEqual(ordinal * stride, solved.offset);
    }
    // Published results serve their own goals; the deferred one stays pending first.
    for ([_]usize{ 0, 2, 3 }) |index| {
        const view = system.statusForWorld(0, cellWorld(1, 2), 0, goals[index], .default, null);
        try std.testing.expectEqual(PathStatus.available, view.status);
        const path = system.completed.pathSlice(system.completed.slotIndex(keys[index]).?, system.completed.resultAt(system.completed.slotIndex(keys[index]).?).path_len);
        try std.testing.expectEqual(@as(u32, @intCast(system.graph.grid(0).?.indexForCell(keys[index].goal).?)), path[path.len - 1]);
    }
    try std.testing.expectEqual(@as(usize, 1), system.pending.len);
    try std.testing.expectEqualDeep(keys[1], system.pending.at(0).key);
    try std.testing.expectEqual(@as(u8, 1), system.pending.at(0).tier);
}

test "pathfinding result publish after its reserve allocates nothing (FailingAllocator)" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    // Two-word inline stripes: every multi-cell path is a long result.
    var capacity = baselineCapacity();
    capacity.max_stored_path_cells = 2;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);
    const goals = [_]math.Vec2{ cellWorld(6, 1), cellWorld(6, 9), cellWorld(12, 4), cellWorld(3, 13) };

    // Warm: the first publish grows the long pool at its reserve.
    _ = try solveIndividualGoals(&system, requester, &goals, 8);
    try expectGoalsSolved(&system, &goals);
    try std.testing.expect(system.completed.long_block_count >= goals.len);
    try std.testing.expect(system.long_block_growth.logged);
    const long_blocks = system.completed.long_block_count;

    // Expired and solved again, the same results publish in place; expired once more, they
    // publish on a failing allocator.
    test_support.expireCachedResults(&system);
    _ = try solveIndividualGoals(&system, requester, &goals, 8);
    try expectGoalsSolved(&system, &goals);
    test_support.expireCachedResults(&system);
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;
    defer {
        system.allocator = original;
        system.graph.allocator = original;
    }
    _ = try solveIndividualGoals(&system, requester, &goals, 8);
    try expectGoalsSolved(&system, &goals);
    try std.testing.expectEqual(long_blocks, system.completed.long_block_count);
    for (goals) |goal| {
        var cells = try cachedPathCells(&system, goal);
        defer cells.deinit(std.testing.allocator);
        // Stored whole: the path runs from the start cell to the goal cell, past the stripe.
        const grid = system.graph.grid(0).?;
        try std.testing.expect(cells.items.len > capacity.max_stored_path_cells);
        try std.testing.expectEqual(@as(u32, @intCast(grid.indexForCell(grid.worldToCellClamped(cellWorld(1, 2))).?)), cells.items[0]);
        try std.testing.expectEqual(@as(u32, @intCast(grid.indexForCell(grid.worldToCellClamped(goal)).?)), cells.items[cells.items.len - 1]);
    }
}

test "pathfinding a publish reserve out of memory claims nothing, leaves pending for retry, and still flushes logged ops (FailingAllocator)" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    // Two-word inline stripes: every multi-cell path is a long result.
    var capacity = baselineCapacity();
    capacity.max_stored_path_cells = 2;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);

    // Warm the step on a one-cell (inline) result, then clear: the long pool stays empty.
    // The result is published again and aged past the TTL, so the failing step's intake
    // removes it and logs its retire.
    const aged_goal = cellWorld(1, 2);
    _ = try solveIndividualGoals(&system, requester, &.{aged_goal}, 8);
    try expectGoalsSolved(&system, &.{aged_goal});
    clearCompleted(&system);
    try std.testing.expectEqual(@as(usize, 0), system.completed.long_block_count);
    _ = try solveIndividualGoals(&system, requester, &.{aged_goal}, 8);
    try expectGoalsSolved(&system, &.{aged_goal});
    const aged_owner = test_support.cacheOwnerOf(system.completed.core, system.graph.keyForWorld(0, aged_goal, .default).?).?;
    system.completed.core.records.items[aged_owner].stamp -%= types.default_cache_ttl_steps + 1;
    var aged_registrations: usize = 0;
    for (&system.path_index.pools) |*pool| aged_registrations += pool.nodes.len - pool.node_free.items.len;
    try std.testing.expect(aged_registrations != 0);

    const goals = [_]math.Vec2{ cellWorld(6, 1), cellWorld(6, 9), cellWorld(12, 4) };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const original = system.allocator;
    system.allocator = failing.allocator();
    system.graph.allocator = failing.allocator();
    const failed = solveIndividualGoals(&system, requester, &(goals ++ [_]math.Vec2{aged_goal}), 8);
    system.allocator = original;
    system.graph.allocator = original;
    try std.testing.expectError(error.OutOfMemory, failed);

    try std.testing.expectEqual(@as(usize, 0), system.completed.count());
    try std.testing.expectEqual(@as(usize, 0), system.completed.long_block_count);
    // The expired result's retire was flushed: no owner op waits and no registration remains.
    try std.testing.expectEqual(@as(usize, 0), system.completed.core.ownerLog().len);
    for (&system.path_index.pools) |*pool| try std.testing.expectEqual(pool.nodes.len, pool.node_free.items.len);
    try std.testing.expectEqual(goals.len + 1, system.pending.len);
    for (goals) |goal| {
        try std.testing.expect(system.pending_keys.contains(system.graph.keyForWorld(0, goal, .default).?));
        try std.testing.expectEqual(PathStatus.pending, system.statusForWorld(0, cellWorld(1, 2), 0, goal, .default, null).status);
    }

    // With memory back, the next step publishes the same requests without new intake.
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    _ = try updatePathfindingInline(&system, &empty, 8, .{});
    try expectGoalsSolved(&system, &(goals ++ [_]math.Vec2{aged_goal}));
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);
    try std.testing.expect(system.completed.long_block_count >= goals.len);
    for (goals) |goal| {
        try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, cellWorld(1, 2), 0, goal, .default, null).status);
    }
}

test "the path registry holds every run of every published path, and the incremental registry equals one rebuilt from the live cache after victims, TTL expiry, evictions, re-puts, and a shrink with renames" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    try std.testing.expectEqual(@as(usize, 64), system.completed.logicalCapacity());

    // Published paths, then victims: more routes than the 64 entries hold.
    try solveRegistryRoutes(&system, requester, 24, 0, 16, 16, null, .{});
    try expectRegistryMatchesCache(&system);
    for (1..6) |batch| try solveRegistryRoutes(&system, requester, 24, batch * 16, 16, 16, null, .{});
    try std.testing.expect(system.completed.count() == 64);
    try expectRegistryMatchesCache(&system);

    // TTL expiry: an aged entry removed at intake.
    const aged = test_support.cacheOwnerOf(system.completed.core, registryRouteKey(&system, 90, 24)).?;
    system.completed.core.records.items[aged].stamp -%= types.default_cache_ttl_steps + 1;
    try solveRegistryRoutes(&system, requester, 24, 90, 1, 16, null, .{});
    try expectRegistryMatchesCache(&system);

    // Evictions: a dig across the middle of the map.
    try setRegistryCells(&system, &fixture, &.{ .{ 11, 11 }, .{ 12, 11 }, .{ 12, 12 } }, fixture.tree);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &serial_threads);
    try expectRegistryMatchesCache(&system);

    // A re-put: the same key published with a different path.
    var put_stats = PathfindingStats{};
    var reput_key = emptyKey(system.graph.version);
    for (system.completed.core.records.items, 0..) |record, owner| {
        if (record.live) reput_key = system.completed.core.keyOf(@intCast(owner));
    }
    try publishTestPath(&system, reput_key, &.{ 30, 31, 55, 79 }, system.step_counter, &put_stats);
    try expectRegistryMatchesCache(&system);

    // A shrink with renames: sustained low load drops the capacity to the floor's 32.
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    for (0..system.capacity.capacity_shrink_window) |_| _ = try updatePathfindingInline(&system, &empty, 1, .{});
    try std.testing.expectEqual(@as(usize, 32), system.completed.logicalCapacity());
    try expectRegistryMatchesCache(&system);
}

test "re-putting a key replaces its registrations" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    var system = try registrySystem(&data, &fixture.world, 8);
    defer system.deinit();
    var stats = PathfindingStats{};
    var key = emptyKey(system.graph.version);
    key.goal = .{ .x = 20, .y = 20 };
    // Row 1 across three chunks, then column 22 across two others.
    try publishTestPath(&system, key, &.{ 25, 26, 27, 28, 29, 30, 31, 32, 33 }, 1, &stats);
    try expectRegistryMatchesCache(&system);
    try publishTestPath(&system, key, &.{ 22 + 24 * 10, 22 + 24 * 11, 22 + 24 * 12 }, 2, &stats);
    try expectRegistryMatchesCache(&system);
    // Only the second path's two runs remain.
    var registrations: usize = 0;
    for (&system.path_index.pools) |*pool| registrations += pool.nodes.len - pool.node_free.items.len;
    try std.testing.expectEqual(@as(usize, 2), registrations);
}

// `cells` of a 24-tile registry world's row `y`, from column `first` on.
fn rowCells(cells: []u32, y: u32, first: u32) []const u32 {
    for (cells, 0..) |*cell, x| cell.* = y * 24 + first + @as(u32, @intCast(x));
    return cells;
}

test "a registry flush out of memory partway through its payload growth releases every claimed block and payload and clears pending, and the retry matches the cache (FailingAllocator)" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    // Row 1 from column 1 to 22: one run on each of six unregistered 4-tile chunks.
    var cells: [22]u32 = undefined;
    const path = rowCells(&cells, 1, 1);
    var failures: usize = 0;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var system = try registrySystem(&data, &fixture.world, 8);
        defer system.deinit();
        var key = emptyKey(system.graph.version);
        key.goal = .{ .x = 22, .y = 1 };
        var stats = PathfindingStats{};
        try test_support.stageTestPath(&system, key, path, 1, &stats);
        const directory = &system.path_index.directory;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        test_support.setSystemAllocators(&system, failing.allocator());
        const flushed = flushRegistry(&system, null, null);
        test_support.setSystemAllocators(&system, std.testing.allocator);
        if (flushed) |_| {
            try expectRegistryMatchesCache(&system);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        failures += 1;
        // Rolled back: no chunk holds a block or a pending count, every block is free and
        // holds no bytes, and the publish's registrations wait for the retry.
        try std.testing.expect(registryBehind(&system));
        var level: u32 = 0;
        while (level < directory.levelCount()) : (level += 1) {
            for (0..directory.slotCount(level)) |slot| {
                try std.testing.expectEqual(empty_block, directory.slot(level, slot));
                try std.testing.expectEqual(@as(u32, 0), directory.pending(level, slot).*);
            }
        }
        try std.testing.expectEqual(directory.blocks.items.len, directory.block_free.items.len);
        for (directory.blocks.items) |block| try std.testing.expectEqual(@as(usize, 0), block.bytes.len);
        _ = try flushRegistry(&system, null, null);
        try expectRegistryMatchesCache(&system);
    }
    // Every allocation of the flush failed in turn, the six payloads' included: the last
    // ones fail with earlier chunks' payloads and blocks already claimed.
    try std.testing.expect(failures >= 6);
}

test "a chunk whose registrations all retire keeps its block through its step's flushes and returns it at a later step's flush that finds it still empty, and a chunk still holding registrations keeps its payload" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    var system = try registrySystem(&data, &fixture.world, 8);
    defer system.deinit();
    const geometry = system.graph.chunkGeometry();
    const directory = &system.path_index.directory;
    var stats = PathfindingStats{};
    // Row 1 across three chunks, and row 2 inside the third only.
    var long_cells: [10]u32 = undefined;
    var short_cells: [3]u32 = undefined;
    var long_key = emptyKey(system.graph.version);
    long_key.goal = .{ .x = 10, .y = 1 };
    var short_key = emptyKey(system.graph.version);
    short_key.goal = .{ .x = 10, .y = 2 };
    const long_path = rowCells(&long_cells, 1, 1);
    try publishTestPath(&system, long_key, long_path, 1, &stats);
    try publishTestPath(&system, short_key, rowCells(&short_cells, 2, 8), 1, &stats);
    const left = geometry.chunkOfCell(long_path[0]);
    const middle = geometry.chunkOfCell(long_path[4]);
    const shared = geometry.chunkOfCell(long_path[9]);
    try std.testing.expect(left != middle and middle != shared and shared == geometry.chunkOfCell(short_cells[0]));
    for ([_]u32{ left, middle, shared }) |chunk| try std.testing.expect(directory.slot(0, chunk) != empty_block);
    const free_before = directory.block_free.items.len;
    const shared_cap = registrationRun(directory, chunkKey(0, shared)).cap;

    system.completed.removeAt(system.completed.slotIndex(long_key).?);
    // Emptied, the two chunks hold their blocks and payloads through every flush of the step.
    for (0..2) |_| {
        _ = try flushRegistry(&system, null, null);
        for ([_]u32{ left, middle }) |chunk| {
            const block = directory.slot(0, chunk);
            try std.testing.expect(block != empty_block and directory.blockBytes(block).len != 0);
            try std.testing.expectEqual(@as(u32, 0), directory.payload(block).len);
        }
        try std.testing.expectEqual(free_before, directory.block_free.items.len);
        try expectRegistryMatchesCache(&system);
    }
    // The next step's flush, with no work, finds them still empty and releases them.
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    _ = try updatePathfindingInline(&system, &empty, 8, .{});
    try std.testing.expectEqual(empty_block, directory.slot(0, left));
    try std.testing.expectEqual(empty_block, directory.slot(0, middle));
    try std.testing.expectEqual(free_before + 2, directory.block_free.items.len);
    const kept = registrationRun(directory, chunkKey(0, shared));
    try std.testing.expectEqual(@as(u32, 1), kept.len);
    try std.testing.expectEqual(shared_cap, kept.cap);
    try expectRegistryMatchesCache(&system);

    // Published again, the released chunks claim blocks again.
    try publishTestPath(&system, long_key, long_path, 2, &stats);
    for ([_]u32{ left, middle }) |chunk| try std.testing.expect(directory.slot(0, chunk) != empty_block);
    try expectRegistryMatchesCache(&system);
}

test "chunks emptied at one step's flush and published again at the next step's keep their blocks and payloads, so that publish allocates nothing (FailingAllocator)" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try data.createEntity();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);
    const goals = [_]math.Vec2{ cellWorld(6, 1), cellWorld(6, 9), cellWorld(12, 4), cellWorld(3, 13) };
    _ = try solveIndividualGoals(&system, requester, &goals, 8);
    try expectGoalsSolved(&system, &goals);

    // Dropped from the cache, every result retires at a flush of the step, as an eviction's
    // does, which empties every chunk they ran through.
    for (goals) |goal| system.completed.removeAt(system.completed.slotIndex(system.graph.keyForWorld(0, goal, .default).?).?);
    _ = try flushRegistry(&system, null, null);
    const directory = &system.path_index.directory;
    var held: usize = 0;
    for (directory.blocks.items) |block| {
        if (block.bytes.len == 0) continue;
        try std.testing.expectEqual(@as(u32, 0), block.payload.len);
        held += 1;
    }
    try std.testing.expect(held != 0);

    // Requested again the step after, they publish into the held blocks on a failing allocator.
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;
    defer {
        system.allocator = original;
        system.graph.allocator = original;
    }
    _ = try solveIndividualGoals(&system, requester, &goals, 8);
    try expectGoalsSolved(&system, &goals);
    system.allocator = original;
    system.graph.allocator = original;
    try expectRegistryMatchesCache(&system);
}

test "a registry clear returns every chunk's block and payload to the pool, and the next publish claims them again" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    try solveRegistryRoutes(&system, requester, 24, 0, 16, 16, null, .{});
    const directory = &system.path_index.directory;
    try std.testing.expect(directory.block_free.items.len < directory.blocks.items.len);

    clearCompleted(&system);
    var level: u32 = 0;
    while (level < directory.levelCount()) : (level += 1) {
        for (0..directory.slotCount(level)) |slot| {
            try std.testing.expectEqual(empty_block, directory.slot(level, slot));
            try std.testing.expectEqual(@as(u32, 0), directory.pending(level, slot).*);
        }
    }
    try std.testing.expectEqual(directory.blocks.items.len, directory.block_free.items.len);
    for (directory.blocks.items) |block| try std.testing.expectEqual(@as(usize, 0), block.bytes.len);
    try expectRegistryMatchesCache(&system);

    try solveRegistryRoutes(&system, requester, 24, 0, 16, 16, null, .{});
    try std.testing.expect(directory.block_free.items.len < directory.blocks.items.len);
    try expectRegistryMatchesCache(&system);
}

test "an update after a registry flush that ran out of memory past its publish finishes that flush first, so every claimed path keeps its registrations (FailingAllocator)" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var first = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer first.deinit();
    var later = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer later.deinit();
    for (0..24) |index| {
        const route = registryRoute(index, 24);
        try appendPathRequest(if (index < 16) &first else &later, .{ .entity = requester, .start = route[0], .goal = route[1] });
    }
    var behind: usize = 0;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var system = try registrySystem(&data, &fixture.world, 32);
        defer system.deinit();
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        test_support.setSystemAllocators(&system, failing.allocator());
        const failed = updatePathfindingInline(&system, &first, 32, .{});
        test_support.setSystemAllocators(&system, std.testing.allocator);
        if (failed) |_| break else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        // A failure before the claims leaves no publish behind.
        if (system.publish_ranges == 0) continue;
        behind += 1;
        // The next update publishes other routes, whose publish copy reuses the windows the
        // pending registrations sit in.
        _ = try updatePathfindingInline(&system, &later, 32, .{});
        try expectRoutesSolved(&system, 24, 16, 8);
        try std.testing.expect(!registryBehind(&system));
        try expectRegistryMatchesCache(&system);
    }
    try std.testing.expect(behind != 0);
}

test "threaded publish equals serial across range sizes and worker counts (cache bytes and per-shard lists), and publish_copy and registry_flush run on workers" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    // Eight-cell stripes: most routes are long results.
    var serial = try registrySystemWith(&data, &fixture.world, 64, .{ .stored_path_cells = 8 });
    defer serial.deinit();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    for (0..48) |index| {
        const route = registryRoute(index, 24);
        try appendPathRequest(&stream, .{ .entity = requester, .start = route[0], .goal = route[1] });
    }
    _ = try updatePathfindingInline(&serial, &stream, 64, .{});
    try expectRoutesSolved(&serial, 24, 0, 48);
    try std.testing.expect(serial.completed.long_block_count != 0);
    try expectRegistryMatchesCache(&serial);
    for ([_]usize{ 1, 3 }) |workers| {
        var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = workers, .items_per_range = 1 });
        defer threads.deinit();
        for ([_]usize{ 1, 3, 8 }) |items_per_range| {
            var threaded = try registrySystemWith(&data, &fixture.world, 64, .{ .stored_path_cells = 8, .participants = threads.participantSlotCount() });
            defer threaded.deinit();
            const stats = try threaded.update(&stream, 64, &threads, .{ .adaptive = false, .items_per_range = items_per_range });
            try expectSameCache(&serial, &threaded);
            try expectSameRegistry(&serial, &threaded);
            if (items_per_range == 1) {
                try std.testing.expect(!stats.registry_flush_batch.ran_inline and stats.registry_flush_batch.range_count > 1);
            }
        }
    }
}

test "publish after its reserve allocates nothing on a multi-worker ThreadSystem (FailingAllocator)" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    var system = try registrySystemWith(&data, &fixture.world, 64, .{ .stored_path_cells = 8, .participants = threads.participantSlotCount() });
    defer system.deinit();
    // One publish of the routes reserves the registry, its windows, and long pages, and one
    // re-solve of the expired routes grows the payloads for a re-solve in place; expired
    // again, the same publish fits them.
    try solveRegistryRoutes(&system, requester, 24, 0, 48, 64, &threads, fixed_threads_config);
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    for (0..48) |index| {
        const route = registryRoute(index, 24);
        try appendPathRequest(&stream, .{ .entity = requester, .start = route[0], .goal = route[1] });
    }
    test_support.expireCachedResults(&system);
    _ = try system.update(&stream, 64, &threads, fixed_threads_config);
    try expectRoutesSolved(&system, 24, 0, 48);
    test_support.expireCachedResults(&system);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    setSystemAllocators(&system, failing.allocator());
    const stats = system.update(&stream, 64, &threads, fixed_threads_config);
    setSystemAllocators(&system, std.testing.allocator);
    const published = try stats;
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try expectRoutesSolved(&system, 24, 0, 48);
    // At least one unit per shard and per registration added: each published path adds at
    // least one, and its expired result's retire adds its own.
    const units = published.registry_flush_batch.item_count;
    try std.testing.expect(units >= flushUnits(48));
    try std.testing.expectEqual(units, published.registry_flush_batch.range_count);
    try expectRegistryMatchesCache(&system);
}

const ShrinkFlushes = struct {
    serial: BatchStats = .{},
    threaded: BatchStats = .{},
};

// Two registry systems over one world, filled alike, then shrunk by sustained low load:
// one serial, one on `threads` under `config`. Returns each shrink step's flush batch.
fn shrinkThroughUpdates(serial: *PathfindingSystem, threaded: *PathfindingSystem, threads: *ThreadSystem, config: PathfindingConfig) !ShrinkFlushes {
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    var flushes = ShrinkFlushes{};
    for (0..serial.capacity.capacity_shrink_window) |_| {
        const serial_capacity = serial.completed.logicalCapacity();
        const serial_stats = try updatePathfindingInline(serial, &empty, 1, .{});
        if (serial.completed.logicalCapacity() < serial_capacity) flushes.serial = serial_stats.registry_flush_batch;
        const capacity = threaded.completed.logicalCapacity();
        const stats = try threaded.update(&empty, 1, threads, config);
        if (threaded.completed.logicalCapacity() < capacity) flushes.threaded = stats.registry_flush_batch;
    }
    return flushes;
}

test "a shrink's registry flush runs on workers at about one pair per range under the adaptive control, renames included, and equals the serial flush" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    var serial = try shrinkFixture(&data, &fixture, requester, 1);
    defer serial.deinit();
    var threaded = try shrinkFixture(&data, &fixture, requester, threads.participantSlotCount());
    defer threaded.deinit();
    // The shrink's fixed-shape flush leaves the flush tuner untouched.
    const tuner_before = threaded.tuners.registry_flush;
    const flushes = try shrinkThroughUpdates(&serial, &threaded, &threads, .{});
    const flush = flushes.threaded;
    const tuner_after = threaded.tuners.registry_flush;
    try std.testing.expectEqual(tuner_before.sample_count, tuner_after.sample_count);
    try std.testing.expectEqual(tuner_before.phase, tuner_after.phase);
    try std.testing.expectEqual(tuner_before.current_profile, tuner_after.current_profile);
    try std.testing.expectEqual(@as(usize, 32), threaded.completed.logicalCapacity());
    try std.testing.expect(!flush.ran_inline and flush.active_worker_threads != 0 and flush.worker_thread_ranges != 0);
    // The fixed shape is ceil(units / pairs) units per range; at a pair count's square of
    // units or more that is exactly one range per pair.
    try std.testing.expectEqual(flushes.serial.item_count, flush.item_count);
    try std.testing.expect(flush.item_count >= flush_pair_count * flush_pair_count);
    try std.testing.expectEqual(@divCeil(flush.item_count, flush_pair_count), flush.items_per_range);
    try std.testing.expectEqual(flush_pair_count, flush.range_count);
    try expectSameCache(&serial, &threaded);
    try expectSameRegistry(&serial, &threaded);
    try expectRegistryMatchesCache(&threaded);
    for (&threaded.path_index.pools) |*pool| try std.testing.expectEqual(@as(usize, 32), pool.owner_heads.items.len);
}

test "a shrink step whose claims retire victims among the renamed results flushes the renames and then the retires in log order, threaded as serially, and matches the cache" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    var serial = try shrinkFixture(&data, &fixture, requester, 1);
    defer serial.deinit();
    var threaded = try shrinkFixture(&data, &fixture, requester, threads.participantSlotCount());
    defer threaded.deinit();
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    // New routes in the step that shrinks: its claims follow the shrink's renames into a
    // full cache, so each retires a victim, some of them renamed in the same log.
    var fresh = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer fresh.deinit();
    for (64..72) |index| {
        const route = registryRoute(index, 24);
        try appendPathRequest(&fresh, .{ .entity = requester, .start = route[0], .goal = route[1] });
    }
    const window = serial.capacity.capacity_shrink_window;
    for (0..window) |step| {
        const requests = if (step + 1 == window) &fresh else &empty;
        _ = try updatePathfindingInline(&serial, requests, 1, .{});
        _ = try threaded.update(requests, 1, &threads, .{});
    }
    try std.testing.expectEqual(@as(usize, 32), threaded.completed.logicalCapacity());
    try std.testing.expectEqual(@as(usize, 32), threaded.completed.count());
    try expectRoutesSolved(&threaded, 24, 64, 8);
    try expectSameCache(&serial, &threaded);
    try expectSameRegistry(&serial, &threaded);
    try expectRegistryMatchesCache(&serial);
    try expectRegistryMatchesCache(&threaded);
}

test "a shrink's registry flush keeps a configured range size and equals the serial flush" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    var serial = try shrinkFixture(&data, &fixture, requester, 1);
    defer serial.deinit();
    var threaded = try shrinkFixture(&data, &fixture, requester, threads.participantSlotCount());
    defer threaded.deinit();
    const units_per_range = 4;
    const flushes = try shrinkThroughUpdates(&serial, &threaded, &threads, .{ .items_per_range = units_per_range });
    const flush = flushes.threaded;
    try std.testing.expectEqual(@as(usize, 32), threaded.completed.logicalCapacity());
    try std.testing.expect(!flush.ran_inline);
    try std.testing.expectEqual(flushes.serial.item_count, flush.item_count);
    try std.testing.expect(flush.item_count > flush_pair_count * units_per_range);
    try std.testing.expectEqual(units_per_range, flush.items_per_range);
    try std.testing.expectEqual(@divCeil(flush.item_count, units_per_range), flush.range_count);
    try expectSameCache(&serial, &threaded);
    try expectSameRegistry(&serial, &threaded);
    try expectRegistryMatchesCache(&threaded);
}
