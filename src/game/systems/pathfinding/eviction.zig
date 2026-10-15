// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! The scoped eviction of `PathfindingSystem`: a nav change drops the cached results and
//! group fields it can invalidate, and no others. A rebuilt level evicts every result with a
//! path run on it and empties its fields (`evictLevel`, a cold main-thread walk of the
//! level's registry keys). A marks batch evicts per changed key: before the commit
//! `nav_evict_count` gives each changed key its owned halo keys and sizes the hit windows;
//! after it `nav_evict` tests each owned key's runs and the group fields against the changed
//! cells dilated by one (both threaded per changed key), the main thread removes the hits in
//! item order, and the registry flush unlinks them. Free functions over
//! `*PathfindingSystem`; the system calls them directly.

const std = @import("std");
const PathfindingSystem = @import("system.zig").PathfindingSystem;
const navDispatch = @import("system.zig").navDispatch;
const EvictItem = @import("types.zig").EvictItem;
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const BatchStats = @import("../../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const runShaped = @import("../../../app/thread_system.zig").runShaped;
const stageShape = @import("../../../app/thread_system.zig").stageShape;
const thread_shared_record_alignment = @import("../../../app/thread_system.zig").thread_shared_record_alignment;
const dilateChanged3x3 = @import("nav_grid.zig").dilateChanged3x3;
const bitIsSet = @import("../../world/terrain.zig").bitIsSet;
const NavBatchResult = @import("nav_graph.zig").NavBatchResult;
const keyLevel = @import("../chunk_list_map.zig").keyLevel;
const keyChunk = @import("../chunk_list_map.zig").keyChunk;
const ChunkGeometry = @import("../../world/terrain.zig").ChunkGeometry;
const ChunkBits = @import("../../world/terrain.zig").ChunkBits;
const ChunkListMap = @import("../chunk_list_map.zig").ChunkListMap;
const chunkKey = @import("../chunk_list_map.zig").chunkKey;
const no_entry = @import("../chunk_list_map.zig").no_entry;
const GroupField = @import("group_field.zig").GroupField;
const ResultCache = @import("caches.zig").ResultCache;
const publish = @import("publish.zig");
const group_service = @import("group_service.zig");
const types = @import("types.zig");
const NavUpdateStats = @import("types.zig").NavUpdateStats;
const StageTimer = @import("../../../app/runtime_perf_log.zig").StageTimer;
const no_owner = @import("types.zig").no_owner;
const CellCursor = @import("types.zig").CellCursor;
const registry_shard_count = @import("types.zig").registry_shard_count;
const registryShard = @import("types.zig").registryShard;
const evict_range_alignment_items = @import("types.zig").evict_range_alignment_items;
const hit_window_alignment_items = @import("types.zig").hit_window_alignment_items;

/// Path eviction items, one per changed key, on thread-shared record alignment.
pub const EvictItemList = std.array_list.Aligned(EvictItem, .fromByteUnits(thread_shared_record_alignment));
/// Path eviction hit windows, on thread-shared record alignment.
pub const HitList = std.array_list.Aligned(u32, .fromByteUnits(thread_shared_record_alignment));

/// Evicts the cached results with a path run on rebuilt `level` and empties the level's
/// group fields: the level changed without per-cell changes. Walks the level's chunk keys
/// in the path registry, O(level chunks + their registrations) on the main thread, a cold
/// one-off beside the level build it follows; other levels' results, fields, and every
/// pending request stay. The removals' registrations go at the next flush.
pub fn evictLevel(self: *PathfindingSystem, level: u16, stats: *NavUpdateStats) void {
    for (0..self.graph.chunkCount()) |chunk| {
        // A level's chunk count stays below 2^31.
        const key = chunkKey(level, @intCast(chunk));
        var owners = self.path_index[registryShard(key)].iterator(key);
        while (owners.next()) |owner| {
            // Another run of the owner may have evicted it already.
            if (!self.completed.core.records.items[owner].live) continue;
            // A live record's key holds its probe slot.
            self.completed.removeAt(self.completed.slotIndex(self.completed.core.keyOf(owner)).?);
            stats.evicted_results += 1;
        }
    }
    for (self.group_fields.items, 0..) |field, slot| {
        if (field.state == .empty or field.key.goal_level != level) continue;
        group_service.emptyGroupField(self, slot);
        stats.dropped_fields += 1;
    }
}

/// The flush of the rebuilt levels' evictions: a level's worth of retires, a one-off the
/// flush tuner has no profile for, so a tuned dispatch runs at a fixed shape of about one
/// pair per range, outside the tuner (as a shrink's flush), and the marks batch's flush
/// stays the stage's one sample of the step.
pub fn flushRebuildEvictions(self: *PathfindingSystem, thread_system: ?*ThreadSystem) BatchStats {
    var dispatch = navDispatch(self, thread_system, &self.tuners.evict_flush);
    if (dispatch) |*stage| {
        // A flush with no publish weighs each pair at its ops plus one.
        if (stage.adaptive and stage.items_per_range == null) stage.items_per_range = self.completed.core.ownerLog().len + 1;
    }
    return publish.flushRegistry(self, dispatch, null);
}

/// Eviction before the batch commit, one item per changed key (a chunk with a changed
/// cell; a link-only key changes no cell, so it evicts nothing): `nav_evict_count` gives
/// each changed key the halo keys it owns (each key of a changed key's 3x3 block is owned
/// by exactly one of them) and their registrations; the main thread then sizes the hit
/// windows (paths, then a slot per group field) for the walk's selected shape and reserves
/// them, O(1) per key. Reads only the batch's keys and the registry. On error the graph,
/// cache, and registry are as they were.
pub fn prepareEviction(self: *PathfindingSystem, thread_system: ?*ThreadSystem, stats: *NavUpdateStats) !void {
    // Every update and reaction ends flushed, so every registration names a live entry.
    std.debug.assert(self.completed.core.ownerLog().len == 0 and self.publish_ranges == 0);
    var section = StageTimer.begin();
    defer stats.main.reserve_ns += section.lap();
    const keys = self.graph.changed_keys.items;
    self.evict_items.clearRetainingCapacity();
    self.evict_hits.clearRetainingCapacity();
    self.evict_shape = .{};
    if (keys.len == 0) return;
    if (keys.len > self.evict_items.capacity) {
        try self.evict_items.ensureTotalCapacity(self.allocator, keys.len);
        countEvictGrowth(self);
    }
    self.evict_items.items.len = keys.len;
    @memset(self.evict_items.items, .{});
    const count_dispatch = navDispatch(self, thread_system, &self.tuners.nav_evict_count);
    const count_shape = stageShape(count_dispatch, keys.len, evict_range_alignment_items);
    var job = EvictCountJob{
        .changed_keys = keys,
        .readers = registryReaders(self),
        .geometry = self.graph.chunkGeometry(),
        .items = self.evict_items.items,
        .range_count = count_shape.range_count,
    };
    stats.main.reserve_ns += section.lap();
    stats.evict_count_batch = runShaped(count_dispatch, count_shape, keys.len, evict_range_alignment_items, &job, evictCountJob);
    section = StageTimer.begin();
    // The walk's shape now, so each of its ranges' hit windows starts on a line.
    self.evict_shape = stageShape(navDispatch(self, thread_system, &self.tuners.nav_evict), keys.len, evict_range_alignment_items);
    const field_count = self.group_fields.items.len;
    var total: usize = 0;
    for (self.evict_items.items, 0..) |*item, index| {
        if (index % self.evict_shape.items_per_range == 0) total = std.mem.alignForward(usize, total, hit_window_alignment_items);
        // Hits are registrations of distinct keys and field slots, fewer than the
        // registries' u32 ids.
        item.base = @intCast(total);
        total += item.bound + field_count;
    }
    if (total > self.evict_hits.capacity) {
        try self.evict_hits.ensureTotalCapacity(self.allocator, total);
        countEvictGrowth(self);
    }
    self.evict_hits.items.len = total;
}

/// Eviction after the batch commit: `nav_evict` walks, per changed key, each owned halo
/// key's registrations, testing each run's cells from its start against the cells within
/// one cell of a changed cell, and each group field's costed cells within one cell of its
/// changed cells. It writes the hits into the item's window; the main thread removes them
/// in item order (paths, then fields), O(1) each, and the flush unlinks their
/// registrations.
pub fn evictScoped(self: *PathfindingSystem, batch: NavBatchResult, thread_system: ?*ThreadSystem, stats: *NavUpdateStats) void {
    const keys = batch.changed_keys;
    std.debug.assert(keys.len == self.evict_items.items.len and batch.changed_masks.len == keys.len);
    if (keys.len != 0) {
        var job = EvictJob{
            .cache = &self.completed,
            .changed_keys = keys,
            .masks = batch.changed_masks,
            .readers = registryReaders(self),
            .fields = self.group_fields.items,
            .geometry = self.graph.chunkGeometry(),
            .items = self.evict_items.items,
            .hits = self.evict_hits.items,
            .range_count = self.evict_shape.range_count,
        };
        stats.evict_batch = runShaped(navDispatch(self, thread_system, &self.tuners.nav_evict), self.evict_shape, keys.len, evict_range_alignment_items, &job, evictJob);
        const removal_timer = StageTimer.begin();
        defer stats.main.evict_ns += removal_timer.lap();
        for (self.evict_items.items) |item| {
            stats.evict_entries_visited += item.visited;
            const window = self.evict_hits.items[item.base..];
            for (window[0..item.hits]) |owner| {
                // Another halo key's run may have hit the owner already.
                if (!self.completed.core.records.items[owner].live) continue;
                // A live record's key holds its probe slot.
                self.completed.removeAt(self.completed.slotIndex(self.completed.core.keyOf(owner)).?);
                stats.evicted_results += 1;
            }
            for (window[item.bound..][0..item.field_hits]) |slot| {
                if (self.group_fields.items[slot].state == .empty) continue;
                group_service.emptyGroupField(self, slot);
                stats.dropped_fields += 1;
            }
        }
    }
    const flush_dispatch = navDispatch(self, thread_system, &self.tuners.evict_flush);
    const flush_timer = StageTimer.begin();
    stats.evict_flush_batch = publish.flushRegistry(self, flush_dispatch, null);
    // The flush's code outside its dispatch, inline or not.
    stats.main.evict_ns += flush_timer.lap() -| stats.evict_flush_batch.batch_duration_ns;
    stats.addStageTime(stats.evict_count_batch);
    stats.addStageTime(stats.evict_batch);
    stats.addStageTime(stats.evict_flush_batch);
}

fn countEvictGrowth(self: *PathfindingSystem) void {
    self.evict_growth.record(1, .info, "path eviction scratch grew to {d} keys and {d} hits", .{ self.evict_items.capacity, self.evict_hits.capacity });
}

// Lookups of every path registry shard, for readers on workers while nothing writes.
fn registryReaders(self: *const PathfindingSystem) [registry_shard_count]ChunkListMap.Reader {
    var readers: [registry_shard_count]ChunkListMap.Reader = undefined;
    for (&readers, &self.path_index) |*reader, *shard| reader.* = shard.reader();
    return readers;
}

fn orderKey(key: u64, item: u64) std.math.Order {
    return std.math.order(key, item);
}

// Bit of halo offset (dx, dy) in an `EvictItem.owned` mask.
fn haloBit(dx: isize, dy: isize) u16 {
    // Offsets are -1, 0, or 1: bits 0..8.
    return @as(u16, 1) << @intCast((dy + 1) * 3 + (dx + 1));
}

// A chunk of a level's grid: its key and coordinates.
const ChunkAt = struct {
    key: u64,
    x: usize,
    y: usize,
};

// The chunk at (x + dx, y + dy) on `level`, or null past the level's chunk grid.
fn chunkAround(geometry: ChunkGeometry, level: u16, x: usize, y: usize, dx: isize, dy: isize) ?ChunkAt {
    // Chunk coordinates stay below 2^31.
    const nx = @as(isize, @intCast(x)) + dx;
    const ny = @as(isize, @intCast(y)) + dy;
    if (nx < 0 or ny < 0 or nx >= @as(isize, @intCast(geometry.chunks_x)) or ny >= @as(isize, @intCast(geometry.chunks_y))) return null;
    const at_x: usize = @intCast(nx);
    const at_y: usize = @intCast(ny);
    return .{ .key = chunkKey(level, @intCast(at_y * geometry.chunks_x + at_x)), .x = at_x, .y = at_y };
}

// One range of `nav_evict_count`, per changed key: the registered halo keys it owns and
// their registration count (changed key K owns halo key H iff no changed key in H's 3x3
// block sorts before it). Every list is walked once whatever the partition.
const EvictCountJob = struct {
    // The batch's changed keys, sorted.
    changed_keys: []const u64,
    readers: [registry_shard_count]ChunkListMap.Reader,
    geometry: ChunkGeometry,
    items: []EvictItem,
    range_count: usize,
};

// SIMD verdict: scalar. Binary searches over sorted u64 keys and hash probes; simd.zig has
// no u64 lanes.
fn evictCountJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *EvictCountJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.items.len and range.end <= job.changed_keys.len);
    for (range.start..range.end) |index| {
        const key = job.changed_keys[index];
        const level = keyLevel(key);
        const x = keyChunk(key) % job.geometry.chunks_x;
        const y = keyChunk(key) / job.geometry.chunks_x;
        var item = EvictItem{};
        inline for (.{ -1, 0, 1 }) |dy| inline for (.{ -1, 0, 1 }) |dx| {
            if (chunkAround(job.geometry, level, x, y, dx, dy)) |halo| {
                // A halo key with no registration has nothing to walk.
                const registrations = job.readers[registryShard(halo.key)].keyCount(halo.key);
                if (registrations != 0 and ownsHalo(job.changed_keys[0..index], key, job.geometry, level, halo.x, halo.y)) {
                    item.owned |= haloBit(dx, dy);
                    item.bound += registrations;
                }
            }
        };
        job.items[index] = item;
    }
}

// Whether `key` is the smallest changed key in the 3x3 block around chunk (x, y): no key
// of `earlier` (the changed keys below it, sorted) lies there.
fn ownsHalo(earlier: []const u64, key: u64, geometry: ChunkGeometry, level: u16, x: usize, y: usize) bool {
    inline for (.{ -1, 0, 1 }) |dy| inline for (.{ -1, 0, 1 }) |dx| {
        if (chunkAround(geometry, level, x, y, dx, dy)) |around| {
            if (around.key < key and std.sort.binarySearch(u64, earlier, around.key, orderKey) != null) return false;
        }
    };
    return true;
}

// One range of `nav_evict`, per changed key, into its hit window: the owners whose runs in
// its owned halo keys reach a cell within one cell of a changed cell, and the group fields
// with a costed cell within one cell of its changed cells.
const EvictJob = struct {
    cache: *const ResultCache,
    // The batch's changed keys, sorted, and each one's flipped cells.
    changed_keys: []const u64,
    masks: []const ChunkBits,
    readers: [registry_shard_count]ChunkListMap.Reader,
    fields: []const GroupField,
    geometry: ChunkGeometry,
    items: []EvictItem,
    hits: []u32,
    range_count: usize,
};

// SIMD verdict: the dilation is word-parallel scalar (`dilateChanged3x3`); the list walks
// are pointer chases and the cell and field tests one bit or word per cell.
fn evictJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *EvictJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.items.len and range.end <= job.changed_keys.len);
    for (job.items[range.start..range.end], job.changed_keys[range.start..range.end], job.masks[range.start..range.end]) |*item, key, *mask| {
        std.debug.assert(@as(usize, item.base) + item.bound + job.fields.len <= job.hits.len);
        evictFields(job, item, key, mask);
        const level = keyLevel(key);
        const x = keyChunk(key) % job.geometry.chunks_x;
        const y = keyChunk(key) / job.geometry.chunks_x;
        var hits: u32 = 0;
        var visited: u32 = 0;
        var last_hit: u32 = no_owner;
        inline for (.{ -1, 0, 1 }) |dy| inline for (.{ -1, 0, 1 }) |dx| {
            if (item.owned & haloBit(dx, dy) != 0) {
                // An owned halo key lies in the level's chunk grid.
                const halo = chunkAround(job.geometry, level, x, y, dx, dy).?;
                var around: [9]ChunkBits = undefined;
                inline for (.{ -1, 0, 1 }) |ny| inline for (.{ -1, 0, 1 }) |nx| {
                    around[(ny + 1) * 3 + (nx + 1)] = if (chunkAround(job.geometry, level, halo.x, halo.y, nx, ny)) |neighbour| changedMask(job.changed_keys, job.masks, neighbour.key) else @splat(0);
                };
                const dilated = dilateChanged3x3(job.geometry.chunk_tiles, &around);
                if (!std.mem.allEqual(u64, &dilated, 0)) {
                    const reader = job.readers[registryShard(halo.key)];
                    var entry = reader.head(halo.key);
                    while (entry != no_entry) : (entry = reader.next_entries[entry]) {
                        visited += 1;
                        const owner = reader.owners[entry];
                        if (owner == last_hit) continue;
                        if (!runHits(job.cache, job.geometry, owner, reader.orders[entry], level, halo.x, halo.y, &dilated)) continue;
                        // Each entry hits once, and the bound counts the owned lists' entries.
                        std.debug.assert(hits < item.bound);
                        job.hits[item.base + hits] = owner;
                        hits += 1;
                        last_hit = owner;
                    }
                }
            }
        };
        item.hits = hits;
        item.visited = visited;
    }
}

// Writes the slot of every group field with a costed cell within one cell of `key`'s
// changed cells into `item`'s field hits: the changed cells dilated into each chunk of the
// 3x3 block around `key`, tested against the field's costed bits there.
fn evictFields(job: *const EvictJob, item: *EvictItem, key: u64, mask: *const ChunkBits) void {
    const window = job.hits[item.base + item.bound ..][0..job.fields.len];
    const level = keyLevel(key);
    var any_field = false;
    for (job.fields) |field| any_field = any_field or (field.state != .empty and field.key.goal_level == level);
    if (!any_field) return;
    const x = keyChunk(key) % job.geometry.chunks_x;
    const y = keyChunk(key) / job.geometry.chunks_x;
    var near: [9]ChunkBits = undefined;
    var near_chunks: [9]?u32 = @splat(null);
    inline for (.{ -1, 0, 1 }) |dy| inline for (.{ -1, 0, 1 }) |dx| {
        const at = (dy + 1) * 3 + (dx + 1);
        if (chunkAround(job.geometry, level, x, y, dx, dy)) |neighbour| {
            // This key's changed cells, seen from the neighbour at offset (-dx, -dy).
            var around: [9]ChunkBits = @splat(@splat(0));
            around[(1 - dy) * 3 + (1 - dx)] = mask.*;
            near[at] = dilateChanged3x3(job.geometry.chunk_tiles, &around);
            near_chunks[at] = keyChunk(neighbour.key);
        }
    };
    var hits: u32 = 0;
    for (job.fields, 0..) |*field, slot| {
        if (field.state == .empty or field.key.goal_level != level) continue;
        for (near_chunks, &near) |chunk, *cells| {
            const near_chunk = chunk orelse continue;
            if (!field.costedNear(near_chunk, cells)) continue;
            // Field slots are few.
            window[hits] = @intCast(slot);
            hits += 1;
            break;
        }
    }
    item.field_hits = hits;
}

// The changed mask of `key` in the batch, or none.
fn changedMask(keys: []const u64, masks: []const ChunkBits, key: u64) ChunkBits {
    const index = std.sort.binarySearch(u64, keys, key, orderKey) orelse return @splat(0);
    return masks[index];
}

// Whether `owner`'s stored path, from cell `start` while it stays on `level` in chunk
// (chunk_x, chunk_y), has a cell set in `dilated` (chunk-local bits).
fn runHits(cache: *const ResultCache, geometry: ChunkGeometry, owner: u32, start: u32, level: u16, chunk_x: usize, chunk_y: usize, dilated: *const ChunkBits) bool {
    const record = cache.core.records.items[owner];
    // The registry lists only live owners between flushes.
    std.debug.assert(record.live);
    const words = cache.storedWords(owner);
    const view = types.stitchedView(words, record.extra.stitched_len);
    const cells = if (record.extra.stitched_len != 0) view.cells else words[0..record.extra.path_len];
    const levels: ?[]const u16 = if (record.extra.stitched_len != 0) view.levels else null;
    std.debug.assert(start < cells.len);
    if (levels == null and record.extra.path_level != level) return false;
    var cursor = CellCursor.init(geometry.width, cells[start]);
    var index: usize = start;
    while (true) {
        if (levels) |column| {
            if (column[index] != level) return false;
        }
        if (cursor.x >> geometry.shift != chunk_x or cursor.y >> geometry.shift != chunk_y) return false;
        if (bitIsSet(dilated, geometry.localOf(cursor.x, cursor.y))) return true;
        index += 1;
        if (index == cells.len) return false;
        cursor.moveTo(cells[index]);
    }
}

// ----------------------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------------------

const test_support = @import("test_support.zig");
const PathStatus = @import("types.zig").PathStatus;
const GroupFieldState = @import("group_field.zig").GroupFieldState;
const WorldTilesetMeta = @import("../../../assets/world_tileset_meta.zig").WorldTilesetMeta;
const builtin = @import("builtin");
const math = @import("../../../core/math.zig");
const DataSystem = @import("../../data_system.zig").DataSystem;
const EntityId = @import("../../data_system.zig").EntityId;
const WorldSystem = @import("../../world/system.zig").WorldSystem;
const PathRequest = @import("../../simulation.zig").PathRequest;
const RangeOutputStream = @import("../../simulation.zig").RangeOutputStream;
const solve = @import("solve.zig");
const PathfindingStats = @import("types.zig").PathfindingStats;
const PathQueryKey = @import("types.zig").PathQueryKey;
const emptyKey = @import("types.zig").emptyKey;
const no_colliders = &test_support.no_colliders;
const abstractCapacity = test_support.abstractCapacity;
const appendPathRequest = test_support.appendPathRequest;
const cellWorld = test_support.cellWorld;
const expectRegistryMatchesCache = test_support.expectRegistryMatchesCache;
const expectSameCache = test_support.expectSameCache;
const expectSameRegistry = test_support.expectSameRegistry;
const loadTestWorldMeta = test_support.loadTestWorldMeta;
const navMarkTestEvents = test_support.navMarkTestEvents;
const pocket_cells = test_support.pocket_cells;
const pocket_world_side = test_support.pocket_world_side;
const pocketGoal = test_support.pocketGoal;
const pocketWorld = test_support.pocketWorld;
const publishTestPath = test_support.publishTestPath;
const registryRouteKey = test_support.registryRouteKey;
const registrySystem = test_support.registrySystem;
const registrySystemWith = test_support.registrySystemWith;
const RegistryWorld = test_support.RegistryWorld;
const registryWorld = test_support.registryWorld;
const requireTestTile = test_support.requireTestTile;
const setRegistryCells = test_support.setRegistryCells;
const setSystemAllocators = test_support.setSystemAllocators;
const solveFrom = test_support.solveFrom;
const solveRegistryRoutes = test_support.solveRegistryRoutes;
const storedPath = test_support.storedPath;
const tileCenter = test_support.tileCenter;

// Whether a stored cell of `owner`'s path lies within one cell (8-neighbour) of one of
// `changed` ((level, x, y) cells).
fn pathNearCells(system: *const PathfindingSystem, owner: u32, changed: []const [3]u16) bool {
    const path = storedPath(system, owner);
    const width = system.graph.geometry.width;
    for (path.cells, 0..) |cell, index| {
        const x: isize = @intCast(cell % width);
        const y: isize = @intCast(cell / width);
        for (changed) |change| {
            if (change[0] != path.levelAt(index)) continue;
            if (@abs(x - @as(isize, change[1])) <= 1 and @abs(y - @as(isize, change[2])) <= 1) return true;
        }
    }
    return false;
}

test "eviction equals a brute-force reference: exactly the cached paths with a cell within one cell of a changed cell" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 64);
    defer system.deinit();
    const route_count = 60;
    // One cell; a block straddling chunk edges; a chunk corner; a cell keeping its tile.
    const changes = [_][]const [2]u16{
        &.{.{ 9, 13 }},
        &.{ .{ 7, 7 }, .{ 8, 7 }, .{ 7, 8 }, .{ 8, 8 }, .{ 9, 8 } },
        &.{.{ 15, 16 }},
        &.{.{ 3, 20 }},
    };
    for (changes) |cells| {
        try solveRegistryRoutes(&system, requester, 24, 0, route_count, 64, null, .{});
        try std.testing.expectEqual(@as(usize, route_count), system.completed.count());
        var flipped: [8][3]u16 = undefined;
        var flipped_count: usize = 0;
        for (cells) |cell| {
            if (cell[0] == 3 and cell[1] == 20) continue;
            flipped[flipped_count] = .{ 0, cell[0], cell[1] };
            flipped_count += 1;
        }
        var expected: [route_count]bool = undefined;
        for (&expected, 0..) |*evicted, index| evicted.* = pathNearCells(&system, system.completed.core.ownerOf(registryRouteKey(&system, index, 24)).?, flipped[0..flipped_count]);
        if (flipped_count == 0) {
            // The cell keeps its tile: marked, but no cell changed.
            try test_support.recordTileEdits(&system, &fixture.world, &.{.{ .level = 0, .x = cells[0][0], .y = cells[0][1] }});
        } else {
            try setRegistryCells(&system, &fixture, cells, fixture.tree);
        }
        _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        var evicted_any = false;
        for (expected, 0..) |evicted, index| {
            try std.testing.expectEqual(evicted, system.completed.slotIndex(registryRouteKey(&system, index, 24)) == null);
            evicted_any = evicted_any or evicted;
        }
        try std.testing.expectEqual(flipped_count != 0, evicted_any);
        try expectRegistryMatchesCache(&system);
        if (flipped_count != 0) {
            try setRegistryCells(&system, &fixture, cells, fixture.grass);
            _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        }
    }
}

test "a path that leaves and re-enters a chunk is evicted by a change on its second run" {
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
    key.goal = .{ .x = 3, .y = 2 };
    // (1,1) (2,1) (3,1) in chunk (0,0), (4,1) (5,1) (5,2) (4,2) in chunk (1,0), then (3,2)
    // back in chunk (0,0).
    const cell = struct {
        fn at(x: u32, y: u32) u32 {
            return y * 24 + x;
        }
    }.at;
    try publishTestPath(&system, key, &.{ cell(1, 1), cell(2, 1), cell(3, 1), cell(4, 1), cell(5, 1), cell(5, 2), cell(4, 2), cell(3, 2) }, 1, &stats);
    // (2,3) touches only the second run: two cells from every cell of the first.
    try setRegistryCells(&system, &fixture, &.{.{ 2, 3 }}, fixture.tree);
    const reaction = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), reaction.evicted_results);
    try std.testing.expect(system.completed.slotIndex(key) == null);
    try expectRegistryMatchesCache(&system);
}

test "a path whose diagonal step corners on a changed cell in a diagonal-neighbour chunk is evicted" {
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
    key.goal = .{ .x = 5, .y = 5 };
    const cell = struct {
        fn at(x: u32, y: u32) u32 {
            return y * 24 + x;
        }
    }.at;
    // (5,3) in chunk (1,0), then diagonal steps through (4,4) and on to (5,5) in chunk (1,1):
    // only (4,4) neighbours (3,3), in chunk (0,0), the diagonal neighbour of (1,1).
    try publishTestPath(&system, key, &.{ cell(5, 3), cell(4, 4), cell(5, 5) }, 1, &stats);
    try setRegistryCells(&system, &fixture, &.{.{ 3, 3 }}, fixture.tree);
    const reaction = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), reaction.evicted_results);
    try std.testing.expect(system.completed.slotIndex(key) == null);
    try expectRegistryMatchesCache(&system);
}

// Publishes `unrelated` one-cell paths in chunks two or more chunks from (1, 1), and three
// paths through chunk (1, 1) of a 64-tile registry world; digs (5, 5) and returns the
// registry entries the eviction visited.
fn visitedWithUnrelated(meta: *const WorldTilesetMeta, unrelated: usize) !usize {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var fixture = try registryWorld(meta, 64);
    defer fixture.world.deinit();
    var system = try registrySystem(&data, &fixture.world, 300);
    defer system.deinit();
    var stats = PathfindingStats{};
    var key = emptyKey(system.graph.version);
    for (0..unrelated) |index| {
        key.goal = .{ .x = @intCast(16 + index % 48), .y = @intCast(16 + index / 48) };
        const cell: u32 = @intCast(@as(usize, @intCast(key.goal.y)) * 64 + @as(usize, @intCast(key.goal.x)));
        try publishTestPath(&system, key, &.{cell}, 1, &stats);
    }
    for (0..3) |row| {
        key.goal = .{ .x = 0, .y = @intCast(row) };
        const y: u32 = @intCast(4 + row);
        try publishTestPath(&system, key, &.{ y * 64 + 4, y * 64 + 5, y * 64 + 6 }, 1, &stats);
    }
    try setRegistryCells(&system, &fixture, &.{.{ 5, 5 }}, fixture.tree);
    const reaction = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 3), reaction.evicted_results);
    try expectRegistryMatchesCache(&system);
    return reaction.evict_entries_visited;
}

test "path eviction visits only results registered in the changed chunks' halo (equal entries visited with 10 and 1000 unrelated results)" {
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const few = try visitedWithUnrelated(&meta, 10);
    try std.testing.expectEqual(few, try visitedWithUnrelated(&meta, 1000));
    try std.testing.expectEqual(@as(usize, 3), few);
}

test "a new link evicts no cached path" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    _ = try fixture.world.addLevel(-16);
    _ = try fixture.world.addDenseLayer(1, 0, .floor, fixture.grass);
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 64);
    defer system.deinit();
    try solveRegistryRoutes(&system, requester, 24, 0, 40, 64, null, .{});
    const cached = system.completed.count();
    // A ramp on a cell a cached path crosses, and its far end below.
    const first = storedPath(&system, system.completed.core.ownerOf(registryRouteKey(&system, 0, 24)).?);
    const on_path: u16 = @intCast(first.cells[first.cells.len / 2]);
    const ramp_cell = @import("../../world/system.zig").CellCoord{ .x = @intCast(on_path % 24), .y = @intCast(on_path / 24) };
    try fixture.world.addLevelLink(.{ .kind = .ramp, .level_a = 0, .cell_a = ramp_cell, .level_b = 1, .cell_b = ramp_cell, .traversal_cost = 1, .bidirectional = true });
    const reaction = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), reaction.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), reaction.evicted_results);
    try std.testing.expectEqual(cached, system.completed.count());
    try expectRegistryMatchesCache(&system);
}

test "a cached corridor is evicted only by a change on its own level's cells" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    _ = try fixture.world.addLevel(-16);
    _ = try fixture.world.addDenseLayer(1, 0, .floor, fixture.grass);
    var system = try registrySystem(&data, &fixture.world, 8);
    defer system.deinit();
    var stats = PathfindingStats{};
    // The same cells on level 0 and on level 1, and a corridor crossing (1, 0) on level 0
    // then dropping to level 1.
    var keys: [3]PathQueryKey = undefined;
    const corridors = [_][3]types.StitchedCell{
        .{ .{ .level = 0, .cell = 0 }, .{ .level = 0, .cell = 1 }, .{ .level = 0, .cell = 2 } },
        .{ .{ .level = 1, .cell = 0 }, .{ .level = 1, .cell = 1 }, .{ .level = 1, .cell = 2 } },
        .{ .{ .level = 0, .cell = 1 }, .{ .level = 1, .cell = 5 }, .{ .level = 1, .cell = 6 } },
    };
    for (&keys, corridors, 0..) |*key, corridor, index| {
        key.* = emptyKey(system.graph.version);
        key.goal = .{ .x = @intCast(10 + index), .y = 10 };
        try publishTestStitched(&system, key.*, &corridor, 1, &stats);
    }
    try expectRegistryMatchesCache(&system);
    // Level 0 cell (1, 1) neighbours level-0 cells 0..2 only.
    try setRegistryCells(&system, &fixture, &.{.{ 1, 1 }}, fixture.tree);
    const reaction = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 2), reaction.evicted_results);
    try std.testing.expect(system.completed.slotIndex(keys[0]) == null);
    try std.testing.expect(system.completed.slotIndex(keys[1]) != null);
    try std.testing.expect(system.completed.slotIndex(keys[2]) == null);
    try expectRegistryMatchesCache(&system);
}

// Stores the stitched `corridor` for `key` at `step` as one publish would, its registry
// runs included, and flushes the registry.
fn publishTestStitched(system: *PathfindingSystem, key: PathQueryKey, corridor: []const types.StitchedCell, step: u32, stats: *PathfindingStats) !void {
    system.completed.core.beginPublish();
    const claimed = system.completed.claim(key, 0, corridor.len, corridor[0].level, corridor[corridor.len - 1], corridor[corridor.len - 1].cell, step, stats);
    types.writeStitched(system.completed.destination(claimed), corridor);
    _ = publish.flushRegistry(system, null, null);
    const view = types.stitchedView(system.completed.destination(claimed), corridor.len);
    var starts: [64]u16 = undefined;
    var counts: [registry_shard_count]u32 = @splat(0);
    const geometry = system.graph.chunkGeometry();
    const run_count = solve.splitRuns(geometry, view.cells, view.levels, 0, &starts, &counts);
    for (starts[0..run_count]) |start| {
        const run_key = chunkKey(view.levels[start], geometry.chunkOfCell(view.cells[start]));
        const shard = &system.path_index[registryShard(run_key)];
        try shard.reserve(1, 1, system.completed.logicalCapacity());
        shard.add(claimed.owner, run_key, start);
    }
}

// Flips one cell in each of 20 chunks (a 5 x 4 chunk block) of a 24-tile registry world.
const dense_change_cells = blk: {
    var cells: [20][2]u16 = undefined;
    for (&cells, 0..) |*cell, index| cell.* = .{ 2 + 4 * (index % 5), 2 + 4 * (index / 5) };
    break :blk cells;
};

test "eviction allocates nothing after its pre-commit reserve on a multi-worker ThreadSystem (FailingAllocator)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var system = try registrySystem(&data, &fixture.world, 64);
    defer system.deinit();
    system.nav_controls = .{ .adaptive = false, .items_per_range = 1 };
    // A warm cycle sizes the eviction scratch and the nav batch buffers.
    try solveRegistryRoutes(&system, requester, 24, 0, 60, 64, null, .{});
    try setRegistryCells(&system, &fixture, &dense_change_cells, fixture.tree);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    try setRegistryCells(&system, &fixture, &dense_change_cells, fixture.grass);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    try solveRegistryRoutes(&system, requester, 24, 0, 60, 64, null, .{});

    try setRegistryCells(&system, &fixture, &dense_change_cells, fixture.tree);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    setSystemAllocators(&system, failing.allocator());
    const reaction = system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    setSystemAllocators(&system, std.testing.allocator);
    const stats = try reaction;
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(stats.evicted_results != 0);
    try std.testing.expect(!stats.evict_count_batch.ran_inline and !stats.evict_batch.ran_inline);
    try expectRegistryMatchesCache(&system);
}

test "an eviction reserve out of memory leaves graph, cache, registry, and marks intact, and the retry equals an unfailed apply" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var reference = try registrySystem(&data, &fixture.world, 64);
    defer reference.deinit();
    var system = try registrySystem(&data, &fixture.world, 64);
    defer system.deinit();
    try solveRegistryRoutes(&reference, requester, 24, 0, 60, 64, null, .{});
    try solveRegistryRoutes(&system, requester, 24, 0, 60, 64, null, .{});
    const cached = system.completed.count();
    try setRegistryCells(&system, &fixture, &dense_change_cells, fixture.tree);
    for (dense_change_cells) |cell| try test_support.recordTileEdits(&reference, &fixture.world, &.{.{ .level = 0, .x = cell[0], .y = cell[1] }});
    _ = try reference.applyBufferedNavUpdates(no_colliders, &fixture.world, null);

    // Every allocation of the apply fails in turn; the eviction scratch grows here for the
    // first time, so some attempt fails at the eviction reserve after the graph's.
    const marks = system.nav_marks.items.len;
    var failed_at_eviction: usize = 0;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        const items_before = system.evict_items.capacity;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        system.allocator = failing.allocator();
        system.graph.allocator = failing.allocator();
        const result = system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
        system.allocator = std.testing.allocator;
        system.graph.allocator = std.testing.allocator;
        if (result) |_| break else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (system.evict_items.capacity != items_before or system.evict_hits.capacity == 0) failed_at_eviction += 1;
        // Nothing changed: the dug cells read open, every path is cached and registered,
        // and the marks wait for the retry.
        for (dense_change_cells) |cell| try std.testing.expect(!system.graph.grid(0).?.isBlockedCell(.{ .x = cell[0], .y = cell[1] }));
        try std.testing.expectEqual(cached, system.completed.count());
        try std.testing.expectEqual(marks, system.nav_marks.items.len);
        try expectRegistryMatchesCache(&system);
    }
    try std.testing.expect(failed_at_eviction != 0);
    try expectSameCache(&reference, &system);
    try expectSameRegistry(&reference, &system);
}

test "threaded eviction equals serial over a dense region (bounds, flags, hits, cache bytes), and the eviction stages run on workers" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try registryWorld(&meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var serial = try registrySystem(&data, &fixture.world, 64);
    defer serial.deinit();
    var threaded = try registrySystem(&data, &fixture.world, 64);
    defer threaded.deinit();
    threaded.nav_controls = .{ .adaptive = false, .items_per_range = 1 };
    try solveRegistryRoutes(&serial, requester, 24, 0, 60, 64, null, .{});
    try solveRegistryRoutes(&threaded, requester, 24, 0, 60, 64, null, .{});
    try setRegistryCells(&serial, &fixture, &dense_change_cells, fixture.tree);
    for (dense_change_cells) |cell| try test_support.recordTileEdits(&threaded, &fixture.world, &.{.{ .level = 0, .x = cell[0], .y = cell[1] }});
    const serial_stats = try serial.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    const stats = try threaded.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    try std.testing.expect(!stats.evict_count_batch.ran_inline and stats.evict_count_batch.range_count > 1);
    try std.testing.expect(!stats.evict_batch.ran_inline and stats.evict_batch.range_count > 1);
    try std.testing.expect(serial_stats.evicted_results != 0);
    try std.testing.expectEqual(serial_stats.evicted_results, stats.evicted_results);
    try std.testing.expectEqual(serial_stats.evict_entries_visited, stats.evict_entries_visited);
    try std.testing.expectEqual(serial.evict_items.items.len, threaded.evict_items.items.len);
    for (serial.evict_items.items, threaded.evict_items.items) |a, b| {
        try std.testing.expectEqual(a.bound, b.bound);
        try std.testing.expectEqual(a.owned, b.owned);
        try std.testing.expectEqual(a.hits, b.hits);
        try std.testing.expectEqual(a.visited, b.visited);
        try std.testing.expectEqualSlices(u32, serial.evict_hits.items[a.base..][0..a.hits], threaded.evict_hits.items[b.base..][0..b.hits]);
    }
    try expectSameCache(&serial, &threaded);
    try expectSameRegistry(&serial, &threaded);
    try expectRegistryMatchesCache(&threaded);
    try expectHaloOwnedOnce(&threaded);
}

// Every key in a changed key's 3x3 block that held registrations before the eviction is
// owned by exactly one changed key of the last batch.
fn expectHaloOwnedOnce(system: *const PathfindingSystem) !void {
    var owned = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer owned.deinit();
    const chunks = system.graph.chunkGeometry();
    const keys = system.graph.changed_keys.items;
    try std.testing.expectEqual(keys.len, system.evict_items.items.len);
    for (keys, system.evict_items.items) |key, item| {
        const x = keyChunk(key) % chunks.chunks_x;
        const y = keyChunk(key) / chunks.chunks_x;
        inline for (.{ -1, 0, 1 }) |dy| inline for (.{ -1, 0, 1 }) |dx| {
            if (item.owned & haloBit(dx, dy) != 0) {
                const halo = chunkAround(chunks, keyLevel(key), x, y, dx, dy).?;
                try std.testing.expect(!owned.contains(halo.key));
                try owned.put(halo.key, {});
            }
        };
    }
    // A walk visits at most its owned lists: a key no changed cell neighbours is skipped.
    for (system.evict_items.items) |item| try std.testing.expect(item.visited <= item.bound and item.hits <= item.bound);
    for (keys) |key| {
        const x = keyChunk(key) % chunks.chunks_x;
        const y = keyChunk(key) / chunks.chunks_x;
        inline for (.{ -1, 0, 1 }) |dy| inline for (.{ -1, 0, 1 }) |dx| {
            if (chunkAround(chunks, keyLevel(key), x, y, dx, dy)) |halo| {
                // A key whose runs were all evicted holds none now; it was owned if it held any.
                if (system.path_index[registryShard(halo.key)].keyCount(halo.key) != 0) try std.testing.expect(owned.contains(halo.key));
            }
        };
    }
}

test "one dig leaves unrelated pending requests, fields, tallies, and paths intact, and a request queued before it is solved after it" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = try registrySystem(&data, &fixture.world, 16);
    defer system.deinit();
    // A path along the top right, and a group field inside the pocket from its own agents.
    const path_goal = tileCenter(28, 2);
    try std.testing.expectEqual(@as(usize, 1), (try solveFrom(&system, requester, tileCenter(16, 2), path_goal, .{})).available_results);
    var group = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer group.deinit();
    for (0..3) |index| try appendPathRequest(&group, .{ .entity = requester, .kind = .group, .start = pocketGoal(70 + index), .goal = pocketGoal(33) });
    for (0..4) |_| _ = try system.updateSerial(&group, 16, .{});
    const field_key = system.graph.keyForWorld(0, pocketGoal(33), .default).?;
    const field_state = group_service.groupFieldOf(&system, field_key).?.state;
    try std.testing.expect(field_state != .empty);
    // A request left pending.
    const queued_goal = tileCenter(25, 28);
    try std.testing.expectEqual(@as(usize, 1), (try solveFrom(&system, requester, tileCenter(16, 20), queued_goal, .{ .max_solve_admissions_per_step = 0 })).pending_requests);
    const tallies = system.group_requests.items.len;
    try std.testing.expect(tallies != 0);

    // Dig a cell far from all of them.
    try setRegistryCells(&system, &fixture, &.{.{ 28, 26 }}, fixture.tree);
    const reaction = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expectEqual(@as(usize, 1), reaction.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), reaction.evicted_results + reaction.dropped_fields);
    try std.testing.expect(system.completed.slotIndex(system.graph.keyForWorld(0, path_goal, .default).?) != null);
    try std.testing.expectEqual(field_state, group_service.groupFieldOf(&system, field_key).?.state);
    try std.testing.expectEqual(tallies, system.group_requests.items.len);
    try std.testing.expectEqual(@as(usize, 1), system.pending.len);
    try std.testing.expect(system.pending_keys.contains(system.graph.keyForWorld(0, queued_goal, .default).?));
    try expectRegistryMatchesCache(&system);
    // The queued request is solved on the next update.
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    const after = try system.updateSerial(&empty, 16, .{});
    try std.testing.expectEqual(@as(usize, 1), after.available_results);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, tileCenter(16, 20), 0, queued_goal, .default, null).status);
}

// Whether the group field toward (9, 9), covering at most nine cells and given `budget`
// expansions a step, drops on a change at `cell`; checks the brute-force rule (a changed
// cell within one cell of a costed cell) against the field built before the change.
fn fieldDropMatchesReference(meta: *const WorldTilesetMeta, cell: [2]u16, budget: usize) !bool {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var fixture = try registryWorld(meta, 24);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = abstractCapacity();
    capacity.group_field_max_cells = 9;
    capacity.group_field_build_budget = budget;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &fixture.world, null);
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .kind = .group, .start = tileCenter(12, 12), .goal = tileCenter(9, 9) });
    _ = try system.updateSerial(&stream, 8, .{ .max_solve_admissions_per_step = 0 });
    const key = system.graph.keyForWorld(0, tileCenter(9, 9), .default).?;
    const field = group_service.groupFieldOf(&system, key) orelse return error.TestExpectedField;
    try std.testing.expectEqual(@as(GroupFieldState, if (budget == 1) .building else .ready), field.state);
    const grid = system.graph.grid(0).?;
    var near = false;
    for (0..grid.cellCount()) |index| {
        if (field.lookup(grid, index) == null) continue;
        const x: isize = @intCast(index % grid.geometry.width);
        const y: isize = @intCast(index / grid.geometry.width);
        if (@abs(x - @as(isize, cell[0])) <= 1 and @abs(y - @as(isize, cell[1])) <= 1) near = true;
    }
    try setRegistryCells(&system, &fixture, &.{cell}, fixture.tree);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    const dropped = group_service.groupFieldOf(&system, key) == null;
    try std.testing.expectEqual(near, dropped);
    try std.testing.expectEqual(@as(usize, @intFromBool(near)), stats.dropped_fields);
    return dropped;
}

test "a group field, ready or building, drops exactly when a changed cell lies within one cell of a costed cell, across chunk borders" {
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    // The field costs (8..10, 8..10), all of chunk (2, 2) but its far row and column.
    const cases = [_]struct { cell: [2]u16, drops: bool }{
        .{ .cell = .{ 7, 9 }, .drops = true },
        .{ .cell = .{ 6, 9 }, .drops = false },
        .{ .cell = .{ 7, 7 }, .drops = true },
        .{ .cell = .{ 11, 11 }, .drops = true },
        .{ .cell = .{ 12, 12 }, .drops = false },
        .{ .cell = .{ 9, 12 }, .drops = false },
        .{ .cell = .{ 10, 11 }, .drops = true },
    };
    for ([_]usize{ 8192, 1 }) |budget| {
        for (cases) |case| try std.testing.expectEqual(case.drops, try fieldDropMatchesReference(&meta, case.cell, budget));
    }
}

// A pocket-world system holding `routes` cached paths.
fn evictionFixture(data: *const DataSystem, fixture: *const RegistryWorld, requester: EntityId, participants: usize, routes: usize) !PathfindingSystem {
    var system = try registrySystemWith(data, &fixture.world, 16, .{ .participants = participants });
    errdefer system.deinit();
    var route: usize = 0;
    while (route < routes) : (route += 16) try solveRegistryRoutes(&system, requester, pocket_world_side, route, @min(16, routes - route), 16, null, .{});
    return system;
}

// A dense one-step change across the pocket wall and the open side.
const pocket_change_cells = blk: {
    var cells: [23][2]u16 = undefined;
    for (0..4) |row| cells[row] = .{ 13, 2 + 4 * row };
    for (0..3) |column| cells[4 + column] = .{ 2 + 4 * column, 13 };
    for (0..16) |index| cells[7 + index] = .{ 17 + 4 * (index % 4), 17 + 4 * (index / 4) };
    break :blk cells;
};

test "threaded eviction with paths and fields equals serial over a dense change (bounds, flags, hits), and runs on workers" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var systems: [2]PathfindingSystem = undefined;
    var built: usize = 0;
    defer for (systems[0..built]) |*system| system.deinit();
    for (&systems) |*system| {
        system.* = try evictionFixture(&data, &fixture, requester, threads.participantSlotCount(), 32);
        built += 1;
        // A group field toward the far corner.
        var group = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer group.deinit();
        try appendPathRequest(&group, .{ .entity = requester, .kind = .group, .start = tileCenter(20, 20), .goal = tileCenter(26, 26) });
        _ = try system.updateSerial(&group, 16, .{ .max_solve_admissions_per_step = 0 });
    }
    systems[1].nav_controls = .{ .adaptive = false, .items_per_range = 1 };
    try setRegistryCells(&systems[0], &fixture, &pocket_change_cells, fixture.tree);
    for (pocket_change_cells) |cell| try test_support.recordTileEdits(&systems[1], &fixture.world, &.{.{ .level = 0, .x = cell[0], .y = cell[1] }});
    const serial_stats = try systems[0].applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    const stats = try systems[1].applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    try std.testing.expect(!stats.evict_count_batch.ran_inline and stats.evict_count_batch.range_count > 1);
    try std.testing.expect(!stats.evict_batch.ran_inline and stats.evict_batch.range_count > 1);
    try std.testing.expect(serial_stats.evicted_results > 1 and serial_stats.dropped_fields == 1);
    try std.testing.expectEqual(serial_stats.evicted_results, stats.evicted_results);
    try std.testing.expectEqual(serial_stats.dropped_fields, stats.dropped_fields);
    for (systems[0].evict_items.items, systems[1].evict_items.items) |a, b| {
        // Window bases follow each run's range shape.
        var a_unplaced = a;
        a_unplaced.base = b.base;
        try std.testing.expectEqualDeep(a_unplaced, b);
        const field_bound = systems[0].group_fields.items.len;
        try std.testing.expectEqualSlices(u32, systems[0].evict_hits.items[a.base..][0 .. a.bound + field_bound], systems[1].evict_hits.items[b.base..][0 .. b.bound + field_bound]);
    }
    try expectSameCache(&systems[0], &systems[1]);
    try expectSameRegistry(&systems[0], &systems[1]);
    for (&systems) |*system| try expectRegistryMatchesCache(system);
}

test "a nav worker cap of zero keeps the mark and eviction stages inline on a multi-worker ThreadSystem and changes no result" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    // Uncapped first, then capped: a fixed partition that runs every stage on workers
    // unless the cap holds it inline.
    const caps = [_]?usize{ null, 0 };

    // `nav_mark` over terrain events.
    {
        var world = try test_support.abstractTestWorld(&meta, 384, 384);
        defer world.deinit();
        _ = try world.addLevel(-16);
        var events = try navMarkTestEvents(std.testing.allocator, &world);
        defer events.deinit(std.testing.allocator);
        var systems = [_]PathfindingSystem{ PathfindingSystem.init(std.testing.allocator), PathfindingSystem.init(std.testing.allocator) };
        defer for (&systems) |*system| system.deinit();
        for (&systems, caps) |*system, cap| {
            try system.reserve(abstractCapacity());
            try system.rebuildStaticNavGridWithWorld(&data, &world, null);
            system.nav_controls = .{ .adaptive = false, .items_per_range = 8, .max_worker_threads = cap };
            try system.reserveTerrainNavRecord(events.items.len);
            system.recordTerrainNavEvents(events.items, &world, &threads);
        }
        try std.testing.expect(!systems[0].last_mark_batch.ran_inline and systems[0].last_mark_batch.range_count > 1);
        try std.testing.expect(systems[1].last_mark_batch.ran_inline);
        try std.testing.expectEqual(systems[0].last_mark_batch.item_count, systems[1].last_mark_batch.item_count);
        try std.testing.expectEqual(systems[0].nav_marks.items.len, systems[1].nav_marks.items.len);
        for (systems[0].nav_marks.items, systems[1].nav_marks.items) |a, b| try std.testing.expectEqual(a, b);
    }

    // `nav_evict_count`, `nav_evict`, and `evict_flush` over a dense change.
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var systems: [2]PathfindingSystem = undefined;
    var built: usize = 0;
    defer for (systems[0..built]) |*system| system.deinit();
    var stats: [2]NavUpdateStats = undefined;
    for (&systems, caps) |*system, cap| {
        system.* = try evictionFixture(&data, &fixture, requester, threads.participantSlotCount(), 32);
        built += 1;
        var group = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer group.deinit();
        try appendPathRequest(&group, .{ .entity = requester, .kind = .group, .start = tileCenter(20, 20), .goal = tileCenter(26, 26) });
        _ = try system.updateSerial(&group, 16, .{ .max_solve_admissions_per_step = 0 });
        system.nav_controls = .{ .adaptive = false, .items_per_range = 1, .max_worker_threads = cap };
    }
    try setRegistryCells(&systems[0], &fixture, &pocket_change_cells, fixture.tree);
    for (pocket_change_cells) |cell| try test_support.recordTileEdits(&systems[1], &fixture.world, &.{.{ .level = 0, .x = cell[0], .y = cell[1] }});
    for (&systems, &stats) |*system, *step| step.* = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    for ([_][2]BatchStats{
        .{ stats[0].evict_count_batch, stats[1].evict_count_batch },
        .{ stats[0].evict_batch, stats[1].evict_batch },
        .{ stats[0].evict_flush_batch, stats[1].evict_flush_batch },
    }) |pair| {
        try std.testing.expect(!pair[0].ran_inline and pair[0].range_count > 1);
        try std.testing.expect(pair[1].ran_inline);
        try std.testing.expectEqual(pair[0].item_count, pair[1].item_count);
    }
    try std.testing.expect(stats[0].evicted_results > 1);
    try std.testing.expectEqual(stats[0].evicted_results, stats[1].evicted_results);
    try std.testing.expectEqual(stats[0].dropped_fields, stats[1].dropped_fields);
    try expectSameCache(&systems[0], &systems[1]);
    try expectSameRegistry(&systems[0], &systems[1]);
}

test "eviction with paths and fields allocates nothing after its pre-commit reserve on a multi-worker ThreadSystem (FailingAllocator)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fixture = try pocketWorld(&meta, pocket_world_side, pocket_cells);
    defer fixture.world.deinit();
    const requester = try data.createEntity();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var system = try evictionFixture(&data, &fixture, requester, threads.participantSlotCount(), 32);
    defer system.deinit();
    system.nav_controls = .{ .adaptive = false, .items_per_range = 1 };
    var group = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer group.deinit();
    try appendPathRequest(&group, .{ .entity = requester, .kind = .group, .start = tileCenter(20, 20), .goal = tileCenter(26, 26) });
    // A warm cycle sizes the eviction scratch and the batch buffers.
    try setRegistryCells(&system, &fixture, &pocket_change_cells, fixture.tree);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    try setRegistryCells(&system, &fixture, &pocket_change_cells, fixture.grass);
    _ = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    var route: usize = 0;
    while (route < 32) : (route += 16) try solveRegistryRoutes(&system, requester, pocket_world_side, route, 16, 16, null, .{});
    _ = try system.updateSerial(&group, 16, .{ .max_solve_admissions_per_step = 0 });

    try setRegistryCells(&system, &fixture, &pocket_change_cells, fixture.tree);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    setSystemAllocators(&system, failing.allocator());
    const reaction = system.applyBufferedNavUpdates(no_colliders, &fixture.world, &threads);
    setSystemAllocators(&system, std.testing.allocator);
    const stats = try reaction;
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(stats.evicted_results != 0 and stats.dropped_fields == 1);
    try std.testing.expect(!stats.evict_batch.ran_inline and !stats.evict_flush_batch.ran_inline);
    try expectRegistryMatchesCache(&system);
}

test "a level rebuilt by a content revision evicts only its own results and fields, and every pending request stays" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");
    // Two open floors with no link: every result stays on its own level.
    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const requester = try data.createEntity();

    // A solved result and a group field on each level, then a deferred request on each.
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    for ([_]u16{ 0, 1 }) |level| {
        try appendPathRequest(&stream, .{ .entity = requester, .start_level = level, .goal_level = level, .start = cellWorld(1, 1), .goal = cellWorld(9, 9) });
        try appendPathRequest(&stream, .{ .entity = requester, .kind = .group, .start_level = level, .goal_level = level, .start = cellWorld(2, 1), .goal = cellWorld(5, 8) });
    }
    _ = try system.updateSerial(&stream, 8, .{});
    stream.clearRetainingCapacity();
    for ([_]u16{ 0, 1 }) |level| {
        try appendPathRequest(&stream, .{ .entity = requester, .start_level = level, .goal_level = level, .start = cellWorld(1, 1), .goal = cellWorld(10, 3) });
    }
    _ = try system.updateSerial(&stream, 8, .{ .max_solve_admissions_per_step = 0 });
    const solved = [_]PathQueryKey{ system.graph.keyForWorld(0, cellWorld(9, 9), .default).?, system.graph.keyForWorld(1, cellWorld(9, 9), .default).? };
    const fields = [_]PathQueryKey{ system.graph.keyForWorld(0, cellWorld(5, 8), .default).?, system.graph.keyForWorld(1, cellWorld(5, 8), .default).? };
    for (solved, fields) |result_key, field_key| {
        try std.testing.expect(system.completed.slotIndex(result_key) != null);
        try std.testing.expect(group_service.groupFieldOf(&system, field_key) != null);
    }
    try std.testing.expectEqual(@as(usize, 2), system.pending.len);

    // A blocking fill of level 1 moves its content revision with no per-cell event.
    _ = try world.addDenseLayer(1, 0, .obstacle, tree);
    const stats = try system.applyBufferedNavUpdates(no_colliders, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.levels_built);
    // Level 1's two results (the group goal solved individually before its field was ready).
    try std.testing.expectEqual(@as(usize, 2), stats.evicted_results);
    try std.testing.expectEqual(@as(usize, 1), stats.dropped_fields);
    try std.testing.expectEqual(@as(usize, 2), system.completed.count());
    for (solved[0..1] ++ fields[0..1]) |kept| try std.testing.expect(system.completed.slotIndex(kept) != null);
    for (solved[1..2] ++ fields[1..2]) |evicted| try std.testing.expect(system.completed.slotIndex(evicted) == null);
    try std.testing.expect(group_service.groupFieldOf(&system, fields[0]) != null);
    try std.testing.expect(group_service.groupFieldOf(&system, fields[1]) == null);
    // Both deferred requests stay queued and keyed; the solve re-checks their reach.
    try std.testing.expectEqual(@as(usize, 2), system.pending.len);
    for (0..system.pending.len) |index| try std.testing.expect(system.pending_keys.contains(system.pending.at(index).key));
    try expectRegistryMatchesCache(&system);
    const answered = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), answered.available_results);
    try std.testing.expectEqual(@as(usize, 1), answered.unavailable_results);
}

// Three open 12x12 floors in 4-tile chunks: stairs link level 0 (10, 10) to level 1 (2, 2)
// and level 1 (10, 10) to level 2 (2, 2).
fn linkedLevelsWorld(meta: *const WorldTilesetMeta) !WorldSystem {
    const grass = try requireTestTile(meta, "grass");
    var world = try test_support.abstractTestWorld(meta, 384, 384);
    errdefer world.deinit();
    for (1..3) |level| {
        _ = try world.addLevel(0);
        _ = try world.addDenseLayer(@intCast(level), 0, .floor, grass);
    }
    for ([_]u16{ 0, 1 }) |upper| {
        try world.addLevelLink(.{ .kind = .stair, .level_a = upper, .cell_a = .{ .x = 10, .y = 10 }, .level_b = upper + 1, .cell_b = .{ .x = 2, .y = 2 }, .traversal_cost = 5, .bidirectional = true });
    }
    return world;
}

const LinkedRoute = struct {
    start_level: u16,
    start: math.Vec2,
    goal_level: u16,
    goal: math.Vec2,
};

const linked_routes = [_]LinkedRoute{
    // Level 0 to a goal on level 2, through level 1.
    .{ .start_level = 0, .start = cellWorld(1, 1), .goal_level = 2, .goal = cellWorld(9, 9) },
    // On level 0 only, and on level 2 only.
    .{ .start_level = 0, .start = cellWorld(1, 1), .goal_level = 0, .goal = cellWorld(6, 1) },
    .{ .start_level = 2, .start = cellWorld(3, 3), .goal_level = 2, .goal = cellWorld(8, 4) },
    // Level 0 to a goal on level 1.
    .{ .start_level = 0, .start = cellWorld(1, 2), .goal_level = 1, .goal = cellWorld(6, 6) },
    // Level 2 to a goal on level 0, through level 1.
    .{ .start_level = 2, .start = cellWorld(5, 5), .goal_level = 0, .goal = cellWorld(5, 10) },
};

// A system over `world` with every linked route solved and cached; returns the routes' keys.
fn solveLinkedRoutes(system: *PathfindingSystem, data: *DataSystem, world: *const WorldSystem) ![linked_routes.len]PathQueryKey {
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(data, world, null);
    const requester = try data.createEntity();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    var keys: [linked_routes.len]PathQueryKey = undefined;
    for (linked_routes, &keys) |route, *key| {
        try appendPathRequest(&stream, .{ .entity = requester, .start_level = route.start_level, .goal_level = route.goal_level, .start = route.start, .goal = route.goal });
        key.* = system.graph.keyForWorld(route.goal_level, route.goal, .default).?;
    }
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    _ = try system.updateSerial(&stream, 8, .{});
    for (0..16) |_| {
        if (system.pending.len == 0) break;
        _ = try system.updateSerial(&empty, 8, .{});
    }
    for (keys) |key| try std.testing.expect(system.completed.slotIndex(key) != null);
    return keys;
}

// Moves the content revision of each of `levels` with no per-cell event: a blocking fill.
fn blockLevels(world: *WorldSystem, meta: *const WorldTilesetMeta, levels: []const u16) !void {
    const tree = try requireTestTile(meta, "tree_0");
    for (levels) |level| _ = try world.addDenseLayer(level, 0, .obstacle, tree);
}

// Whether route `index`'s result is still cached, for each route.
fn expectLinkedCached(system: *const PathfindingSystem, keys: [linked_routes.len]PathQueryKey, kept: [linked_routes.len]bool) !void {
    for (keys, kept) |key, keep| try std.testing.expectEqual(keep, system.completed.slotIndex(key) != null);
    try std.testing.expectEqual(@as(usize, 0), system.completed.core.ownerLog().len);
    try expectRegistryMatchesCache(system);
}

test "a rebuilt level evicts every result whose path crosses it, the goal level's or not, and keeps the results that never touch it" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var world = try linkedLevelsWorld(&meta);
    defer world.deinit();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    const keys = try solveLinkedRoutes(&system, &data, &world);
    try blockLevels(&world, &meta, &.{1});
    const stats = try system.applyBufferedNavUpdates(no_colliders, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.levels_built);
    // The pass-throughs (goals on levels 2 and 0) and the goal on level 1 go.
    try expectLinkedCached(&system, keys, .{ false, true, true, false, false });
    try std.testing.expectEqual(@as(usize, 3), stats.evicted_results);
}

test "a rebuilt start level evicts the results that leave it for a goal on another level" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var world = try linkedLevelsWorld(&meta);
    defer world.deinit();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    const keys = try solveLinkedRoutes(&system, &data, &world);
    try blockLevels(&world, &meta, &.{0});
    const stats = try system.applyBufferedNavUpdates(no_colliders, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.levels_built);
    // Every route with a run on level 0 goes, its goal on level 2, 1, or 0.
    try expectLinkedCached(&system, keys, .{ false, false, true, false, false });
    try std.testing.expectEqual(@as(usize, 4), stats.evicted_results);
}

test "two levels rebuilt in one step evict each result through either once and flush once, outside the flush tuner" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var world = try linkedLevelsWorld(&meta);
    defer world.deinit();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    const keys = try solveLinkedRoutes(&system, &data, &world);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    try blockLevels(&world, &meta, &.{ 1, 2 });
    const stats = try system.applyBufferedNavUpdates(no_colliders, &world, &threads);
    try std.testing.expectEqual(@as(usize, 2), stats.levels_built);
    // Routes 0 and 4 have runs on both levels: each is evicted once.
    try expectLinkedCached(&system, keys, .{ false, true, false, false, false });
    try std.testing.expectEqual(@as(usize, 4), stats.evicted_results);
    // The one-off flush ran at its fixed shape, so the flush tuner selected nothing.
    try std.testing.expect(system.tuners.evict_flush.last_request == null);
}

test "a level build that fails after an earlier level was evicted still flushes its evictions, and the retry finishes the rest" {
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var fail_index: usize = 0;
    while (fail_index < 4096) : (fail_index += 1) {
        var data = DataSystem.init(std.testing.allocator);
        defer data.deinit();
        var world = try linkedLevelsWorld(&meta);
        defer world.deinit();
        var system = PathfindingSystem.init(std.testing.allocator);
        defer system.deinit();
        const keys = try solveLinkedRoutes(&system, &data, &world);
        try blockLevels(&world, &meta, &.{ 1, 2 });
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        setSystemAllocators(&system, failing.allocator());
        const result = system.applyBufferedNavUpdates(no_colliders, &world, null);
        setSystemAllocators(&system, std.testing.allocator);
        _ = result catch {
            const graphs = system.graph.level_graphs.items;
            // Fail inside level 2's build, after level 1's was built and evicted.
            if (graphs[1].built_revision != world.levelContentRevision(1) or graphs[2].built_revision == world.levelContentRevision(2)) continue;
            try std.testing.expect(system.completed.slotIndex(keys[0]) == null);
            try expectLinkedCached(&system, keys, .{ false, true, true, false, false });
            _ = try system.applyBufferedNavUpdates(no_colliders, &world, null);
            try expectLinkedCached(&system, keys, .{ false, true, false, false, false });
            return;
        };
        // Past every allocation of the apply: no index failed inside level 2's build.
        return error.TestLevelBuildNeverFailed;
    }
    return error.TestLevelBuildNeverFailed;
}
