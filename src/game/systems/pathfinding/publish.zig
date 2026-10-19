// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! The publish and path registry of `PathfindingSystem`: the step's results are reserved for,
//! claimed in solve-ordinal order on the main thread (O(1) per result), copied into their cache
//! stripes or long blocks with their registry runs bucketed per flush pair (`publish_copy`,
//! threaded per result range). `registry_flush_count` lists the chunks to grow or compact
//! without mutating runs; the main thread reallocates a chunk that is short of slack;
//! `registry_flush` compacts, renames, and appends. Both thread per shard. Free functions
//! over `*PathfindingSystem`; the system calls them directly.

const std = @import("std");
const runtime_perf_log = @import("../../../app/runtime_perf_log.zig");
const PathfindingSystem = @import("system.zig").PathfindingSystem;
const BatchStats = @import("../../../app/thread_system.zig").BatchStats;
const Dispatch = @import("../../../app/thread_system.zig").Dispatch;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const maxRangeCount = @import("../../../app/thread_system.zig").maxRangeCount;
const runShaped = @import("../../../app/thread_system.zig").runShaped;
const stageShape = @import("../../../app/thread_system.zig").stageShape;
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

/// The path registry: one padded directory of registration runs, and one inverse pool per shard.
pub const PathIndex = struct {
    directory: RegistryDirectory = .{},
    pools: [registry_shard_count]InversePool = @splat(.{}),
    growth: ChunkRefList = .empty,
    compact: ChunkRefList = .empty,
    growth_base: [registry_shard_count]usize = @splat(0),
    compact_base: [registry_shard_count]usize = @splat(0),
    counts: [registry_shard_count]PaddedSlot(ShardCount) = @splat(.{}),
    fresh: std.ArrayList(FreshPayload) = .empty,
    // Retire plan for one flush. The ids and slot heads are the owners the log names;
    // `retire_heads` is each retire's chain start after the log's head moves, per shard.
    retire_ids: std.ArrayList(u32) = .empty,
    retire_slot_heads: std.ArrayList(OwnerHead) = .empty,
    retire_heads: std.ArrayList(u32) = .empty,
    retire_head_base: [registry_shard_count]usize = @splat(0),
    retire_head_count: [registry_shard_count]usize = @splat(0),
    retire_node_count: [registry_shard_count]usize = @splat(0),

    pub fn deinit(self: *PathIndex, allocator: std.mem.Allocator) void {
        self.abortFresh(allocator);
        self.fresh.deinit(allocator);
        self.retire_heads.deinit(allocator);
        self.retire_slot_heads.deinit(allocator);
        self.retire_ids.deinit(allocator);
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
    const capacity_before = registryCapacity(self);
    for (&self.path_index.pools, shard_registrations) |*pool, count| {
        try pool.reserveNodes(self.allocator, count);
        try pool.reserveOwners(self.allocator, self.completed.logicalCapacity());
    }
    var grows: u64 = @intFromBool(registryCapacity(self) != capacity_before);
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

// Directory block storage, inverse-node pools, owner heads, and the count windows: a reserve
// that changed any of them grew.
fn registryCapacity(self: *const PathfindingSystem) usize {
    const index = &self.path_index;
    var capacity: usize = index.directory.levelCount() + index.growth.capacity + index.compact.capacity + index.fresh.capacity + index.retire_ids.capacity + index.retire_slot_heads.capacity + index.retire_heads.capacity;
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

/// Every inverse pool holds an owner head per cache owner id below `capacity`.
pub fn reserveRegistryOwners(self: *PathfindingSystem, capacity: usize) !void {
    const capacity_before = registryCapacity(self);
    for (&self.path_index.pools) |*pool| try pool.reserveOwners(self.allocator, capacity);
    var owners: usize = 0;
    for (&self.path_index.pools) |*pool| owners = @max(owners, pool.owner_heads.items.len);
    try reserveRetireScratch(self, owners);
    if (registryCapacity(self) != capacity_before) countRegistryGrowth(self, 1);
}

// The retire plan names at most two ids per op, and one chain start per retire on each
// shard. A flush logs at most two ops per owner. Reserved with the heads so a warmed
// flush does not allocate it.
fn reserveRetireScratch(self: *PathfindingSystem, owners: usize) error{OutOfMemory}!void {
    const index = &self.path_index;
    const ids = owners *| 4;
    // One chain start per retire op per shard: a path's runs are spread across shards.
    const chains = owners *| 2 *| registry_shard_count;
    if (ids > index.retire_ids.capacity) try index.retire_ids.ensureTotalCapacity(self.allocator, ids);
    if (owners > index.retire_slot_heads.capacity) try index.retire_slot_heads.ensureTotalCapacity(self.allocator, owners);
    if (chains > index.retire_heads.capacity) try index.retire_heads.ensureTotalCapacity(self.allocator, chains);
}

/// Drops every path registration. Run lengths go to zero and inverse nodes return to their
/// pools; payload bytes, directories, and owner-head storage stay, so the same publish fits
/// again. A prepared owner-head truncation is left for the flush that installs it.
pub fn clearRegistry(self: *PathfindingSystem) void {
    const index = &self.path_index;
    var level: u32 = 0;
    while (level < index.directory.levelCount()) : (level += 1) {
        const slots = index.directory.slotCount(level);
        var slot: usize = 0;
        while (slot < slots) : (slot += 1) {
            const block = index.directory.slot(level, slot);
            if (block != empty_block) index.directory.payloadMut(block).len = 0;
            index.directory.pending(level, slot).* = 0;
        }
    }
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
    var extra = directory.levelCount();
    while (extra > levels) {
        extra -= 1;
        directory.closeLevel(self.allocator, @intCast(extra));
    }
    var level: u32 = 0;
    while (level < levels) : (level += 1) {
        const current = directory.slotCount(level);
        if (current != chunks and current != 0) releaseLevelBlocks(self, level);
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
    self.publish_ranges = 0;
    if (item_count == 0) return .{};
    const shape = stageShape(dispatch, item_count, 1);
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

/// `registry_flush`: shard by shard, compacts the chunks a retire touched (survivors keep
/// their order), renames along each inverse chain, then appends the last publish copy's
/// registrations of the shard in range order, and installs a shrink's prepared owner heads.
/// Count runs first and does not mutate runs. The main thread then reallocates a chunk
/// whose cap cannot hold its adds. On `OutOfMemory` the runs are unchanged and `pending`
/// is cleared. Each pair (shard) writes only its shard and its tally. Then the log is
/// emptied and the replaced owner heads are freed. `stats` (when given) takes the apply
/// batch; the count batch is `registry_flush_count_batch` and is not a perf-log key.
/// Count items: pair p weighs its adds + the inverse nodes its retires mark after the
/// log's head moves + 1. Apply items: the live lengths of the chunks it compacts + its
/// adds + 1. A range runs the pairs whose first unit lies in it. A shrink or a rebuild
/// flush runs both dispatches at a fixed shape of about one pair per range, outside the
/// tuners. A dispatch wakes at most one worker fewer than the pair count. Returns the
/// apply batch.
pub fn flushRegistry(self: *PathfindingSystem, dispatch: ?Dispatch, stats: ?*PathfindingStats) error{OutOfMemory}!BatchStats {
    var batch = BatchStats{};
    const truncate = self.registry_truncate_pending;
    const ops = self.completed.core.ownerLog();
    if (ops.len != 0 or self.publish_ranges != 0 or truncate) {
        var pair_adds: [flush_pair_count]usize = @splat(0);
        for (self.publish_bands.items[0..self.publish_ranges]) |band| {
            for (&pair_adds, band.counts) |*adds, count| adds.* += count;
        }
        const retire_nodes = try planRetireChains(self, ops);
        const fix = truncate or self.registry_flush_fixed;
        const count_batch = try runRegistryCount(self, dispatch, pair_adds, retire_nodes, fix);
        self.registry_flush_count_batch = count_batch;
        if (stats) |step| step.registry_flush_count_batch = count_batch;
        try reserveRegistryPayloads(self);
        var apply_units: [flush_pair_count]usize = undefined;
        for (&apply_units, &self.path_index.counts, pair_adds) |*units, *counted, adds| {
            units.* = counted.value.compact_len + adds + 1;
        }
        batch = runRegistryApply(self, dispatch, ops, apply_units, fix);
        if (comptime runtime_perf_log.enabled) {
            if (stats) |step| {
                for (self.flush_tallies) |tally| {
                    step.perf.registrations_removed += tally.removed;
                    step.perf.registrations_added += tally.added;
                }
            }
        }
    } else {
        self.registry_flush_count_batch = .{};
        if (stats) |step| step.registry_flush_count_batch = .{};
    }
    self.publish_ranges = 0;
    self.completed.core.finishOwnerLog(self.allocator);
    if (truncate) {
        for (&self.path_index.pools) |*pool| pool.releaseTruncated(self.allocator);
        self.registry_truncate_pending = false;
    }
    self.registry_flush_fixed = false;
    return batch;
}

fn lessU32(_: void, a: u32, b: u32) bool {
    return a < b;
}

fn orderU32(item: u32, key: u32) std.math.Order {
    return std.math.order(item, key);
}

fn retireHead(ids: []const u32, heads: []OwnerHead, owner: u32) ?*OwnerHead {
    const at = std.sort.lowerBound(u32, ids, owner, orderU32);
    if (at >= ids.len or ids[at] != owner) return null;
    return &heads[at];
}

// Head moves in log order, on the owners the log names. A retire records the chain it
// will mark and clears that head; a rename moves the head. Does not touch runs or the
// live heads. The count job walks the recorded chains, and that walk's node count is the
// compact window. O(logged ops) here.
fn planRetireChains(self: *PathfindingSystem, ops: []const OwnerOp) error{OutOfMemory}![flush_pair_count]usize {
    const index = &self.path_index;
    var owners: usize = 0;
    for (&index.pools) |*pool| owners = @max(owners, pool.owner_heads.items.len);
    try reserveRetireScratch(self, owners);
    const id_need = ops.len *| 2;
    const chain_need = ops.len *| registry_shard_count;
    if (id_need > index.retire_ids.capacity) try index.retire_ids.ensureTotalCapacity(self.allocator, id_need);
    if (chain_need > index.retire_heads.capacity) try index.retire_heads.ensureTotalCapacity(self.allocator, chain_need);
    index.retire_heads.clearRetainingCapacity();
    var nodes: [flush_pair_count]usize = @splat(0);
    for (&index.pools, 0..) |*pool, shard| {
        const base = index.retire_heads.items.len;
        const planned = planShardRetires(index, pool, ops);
        index.retire_head_base[shard] = base;
        index.retire_head_count[shard] = planned.chains;
        nodes[shard] = planned.nodes;
    }
    index.retire_node_count = nodes;
    return nodes;
}

fn planShardRetires(index: *PathIndex, pool: *const InversePool, ops: []const OwnerOp) struct { chains: usize, nodes: usize } {
    std.debug.assert(pool.owner_heads.items.len <= std.math.maxInt(u32));
    const limit: u32 = @intCast(pool.owner_heads.items.len);
    index.retire_ids.clearRetainingCapacity();
    for (ops) |op| {
        if (op.old < limit) index.retire_ids.appendAssumeCapacity(op.old);
        if (op.new != no_owner and op.new < limit) index.retire_ids.appendAssumeCapacity(op.new);
    }
    const gathered = index.retire_ids.items;
    pdq(u32, gathered, {}, lessU32);
    var unique: usize = 0;
    for (gathered) |owner| {
        if (unique != 0 and gathered[unique - 1] == owner) continue;
        gathered[unique] = owner;
        unique += 1;
    }
    index.retire_ids.items.len = unique;
    index.retire_slot_heads.clearRetainingCapacity();
    for (index.retire_ids.items) |owner| index.retire_slot_heads.appendAssumeCapacity(pool.owner_heads.items[owner]);
    const heads = index.retire_slot_heads.items;
    var chains: usize = 0;
    var node_count: usize = 0;
    for (ops) |op| {
        const old = retireHead(index.retire_ids.items, heads, op.old) orelse continue;
        if (old.node == no_entry) continue;
        if (op.new == no_owner) {
            index.retire_heads.appendAssumeCapacity(old.node);
            node_count += old.len;
            chains += 1;
            old.* = .{};
            continue;
        }
        // The renamed-to id is in this pool's heads: the log only renames onto one.
        std.debug.assert(op.new < limit);
        const dest = retireHead(index.retire_ids.items, heads, op.new).?;
        std.debug.assert(dest.node == no_entry);
        dest.* = old.*;
        old.* = .{};
    }
    return .{ .chains = chains, .nodes = node_count };
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
    dispatch: ?Dispatch,
    pair_adds: [flush_pair_count]usize,
    retire_nodes: [flush_pair_count]usize,
    fix: bool,
) error{OutOfMemory}!BatchStats {
    var weights: [flush_pair_count]usize = undefined;
    for (&weights, pair_adds, retire_nodes) |*weight, adds, nodes| weight.* = adds + nodes + 1;
    const counted = unitStarts(weights);
    try reserveCountWindows(self, pair_adds, retire_nodes);
    const count_dispatch: ?Dispatch = if (dispatch) |stage| shapedDispatch(stage, counted.total, fix, &self.tuners.registry_flush_count) else null;
    const shape = stageShape(count_dispatch, counted.total, 1);
    var job = RegistryCountJob{
        .system = self,
        .publish_ranges = self.publish_ranges,
        .range_count = shape.range_count,
        .unit_starts = counted.starts,
    };
    return runShaped(count_dispatch, shape, counted.total, 1, &job, registryCountJob);
}

fn reserveCountWindows(self: *PathfindingSystem, pair_adds: [flush_pair_count]usize, retire_nodes: [flush_pair_count]usize) error{OutOfMemory}!void {
    var cursor: usize = 0;
    var bases: [flush_pair_count]usize = undefined;
    for (&bases, pair_adds, retire_nodes) |*base, adds, nodes| {
        cursor = std.mem.alignForward(usize, cursor, chunk_ref_align);
        base.* = cursor;
        cursor += adds + nodes;
    }
    const index = &self.path_index;
    if (cursor > index.growth.capacity) try index.growth.ensureTotalCapacity(self.allocator, cursor);
    if (cursor > index.compact.capacity) try index.compact.ensureTotalCapacity(self.allocator, cursor);
    index.growth.items.len = cursor;
    index.compact.items.len = cursor;
    index.growth_base = bases;
    index.compact_base = bases;
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
    const shape = stageShape(apply_dispatch, counted.total, 1);
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

fn reserveRegistryPayloads(self: *PathfindingSystem) error{OutOfMemory}!void {
    const index = &self.path_index;
    var listed: usize = 0;
    for (&index.counts) |counted| listed += counted.value.growth;
    index.fresh.clearRetainingCapacity();
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
    for (index.fresh.items) |item| {
        if (item.old_bytes.len != 0) freePayload(self.allocator, item.old_bytes);
        index.directory.setPayload(item.block, item.bytes, item.columns);
        if (item.is_new) index.directory.setSlot(item.level, item.chunk, item.block);
        std.debug.assert(item.columns.cap >= item.columns.len);
    }
    index.fresh.clearRetainingCapacity();
    clearCountedPending(self);
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

fn clearCountedPending(self: *PathfindingSystem) void {
    const index = &self.path_index;
    for (&index.counts, index.growth_base) |counted, base| {
        for (index.growth.items[base..][0..counted.value.growth]) |ref| {
            index.directory.pending(ref.level, ref.chunk).* = 0;
        }
    }
}

fn releaseLevelBlocks(self: *PathfindingSystem, level: u32) void {
    const directory = &self.path_index.directory;
    const slots = directory.slotCount(level);
    var slot: usize = 0;
    while (slot < slots) : (slot += 1) {
        const block = directory.slot(level, slot);
        if (block == empty_block) continue;
        directory.release(self.allocator, block);
        directory.setSlot(level, slot, empty_block);
        directory.pending(level, slot).* = 0;
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
    return @as(usize, cap) * 3 * @sizeOf(u32);
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
        countShard(system, pair, job.publish_ranges);
    }
}

fn countShard(system: *PathfindingSystem, pair: usize, publish_ranges: usize) void {
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
    // The chains `planRetireChains` recorded: a rename onto an id, then a retire of that
    // id, lists the moved chain, which is what `markRetired` marks.
    var listed: u32 = 0;
    const head_base = index.retire_head_base[pair];
    const head_count = index.retire_head_count[pair];
    std.debug.assert(head_base + head_count <= index.retire_heads.items.len);
    for (index.retire_heads.items[head_base..][0..head_count]) |start| {
        var node = start;
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
    // Log order: a retire after a rename must see the chain on its new owner. Compact
    // follows, so every mark is in place and survivor indices are rewritten once.
    var removed: usize = 0;
    for (ops) |op| {
        if (!pool.holdsOwner(op.old)) continue;
        if (op.new == no_owner) {
            removed += pool.owner_heads.items[op.old].len;
            markRetired(pool, op.old);
        } else renameOwner(directory, pool, op.old, op.new);
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

fn renameOwner(directory: *RegistryDirectory, pool: *InversePool, old: u32, new: u32) void {
    std.debug.assert(new < pool.owner_heads.items.len);
    std.debug.assert(pool.owner_heads.items[new].node == no_entry);
    var node = pool.owner_heads.items[old].node;
    while (node != no_entry) {
        const key = pool.node_chunk[node];
        const at = pool.node_index[node];
        const block = directory.slot(keyLevel(key), keyChunk(key));
        directory.payloadMut(block).owner[at] = new;
        node = pool.node_next[node];
    }
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
const flushUnits = test_support.flushUnits;
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

    // Cleared (every block free again), the same results publish on a failing allocator.
    clearCompleted(&system);
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
    // One publish of the routes reserves the registry, its windows, and long pages; cleared,
    // the same publish fits them.
    try solveRegistryRoutes(&system, requester, 24, 0, 48, 64, &threads, fixed_threads_config);
    system.clearRuntimeState();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    for (0..48) |index| {
        const route = registryRoute(index, 24);
        try appendPathRequest(&stream, .{ .entity = requester, .start = route[0], .goal = route[1] });
    }
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    setSystemAllocators(&system, failing.allocator());
    const stats = system.update(&stream, 64, &threads, fixed_threads_config);
    setSystemAllocators(&system, std.testing.allocator);
    const published = try stats;
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try expectRoutesSolved(&system, 24, 0, 48);
    // One unit per shard and per registration added: each published path adds at least one.
    const units = published.registry_flush_batch.item_count;
    try std.testing.expect(units >= flushUnits(0, 48));
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
