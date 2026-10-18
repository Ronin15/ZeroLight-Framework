// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! The publish and path registry of `PathfindingSystem`: the step's results are reserved for,
//! claimed in solve-ordinal order on the main thread (O(1) per result), copied into their cache
//! stripes or long blocks with their registry runs bucketed per flush pair (`publish_copy`,
//! threaded per result range), and flushed shard by shard into the per-chunk path registry
//! (`registry_flush`, threaded per shard). Free functions over `*PathfindingSystem`; the system
//! calls them directly.

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
const chunkKey = @import("../chunk_list_map.zig").chunkKey;
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
    const grows_before = registryGrowths(self);
    for (&self.path_index, shard_registrations) |*shard, count| try shard.reserve(count, count, self.completed.logicalCapacity());
    var grows = registryGrowths(self) - grows_before;
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

// Growths of every registry shard's table, entry pool, and owner heads so far.
fn registryGrowths(self: *const PathfindingSystem) u64 {
    var grows: u64 = 0;
    for (&self.path_index) |*shard| grows += shard.grows;
    return grows;
}

fn countRegistryGrowth(self: *PathfindingSystem, grows: u64) void {
    self.registry_growth.record(grows, .info, "path registry storage grew ({d} growths so far)", .{self.registry_growth.count + grows});
}

/// Every registry shard holds an owner head per cache owner id below `capacity`.
pub fn reserveRegistryOwners(self: *PathfindingSystem, capacity: usize) !void {
    const grows_before = registryGrowths(self);
    for (&self.path_index) |*shard| try shard.reserve(0, 0, capacity);
    const grows = registryGrowths(self) - grows_before;
    if (grows != 0) countRegistryGrowth(self, grows);
}

/// Drops every path registration, as when the result cache dropped every entry.
pub fn clearRegistry(self: *PathfindingSystem) void {
    for (&self.path_index) |*shard| shard.clear();
    self.publish_ranges = 0;
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
                stats.solved_requests += 1;
                if (result == .partial) stats.partial_results += 1 else stats.available_results += 1;
                if (comptime runtime_perf_log.enabled) {
                    if (solved.via_abstract) stats.perf.abstract_solves += 1;
                    if (solved.cross_level) stats.perf.cross_level_solves += 1;
                }
            },
            // Answered without a search and never cached: dropped in
            // compactPendingAfterSolve.
            .unavailable => stats.unavailable_results += 1,
            .budget_exhausted => {
                stats.budget_exhausted += 1;
            },
            // Start-side failure: dropped in compactPendingAfterSolve, never cached; the
            // next status query falls through to `.missing`.
            .start_invalid => {
                if (comptime runtime_perf_log.enabled) stats.perf.start_invalid_dropped += 1;
            },
            .deferred => continue,
        }
    }
    stats.solve_admissions = self.solve_indices.items.len;
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

/// `registry_flush`: shard by shard, removes and renames the owners of the result
/// cache's owner log in log order, then adds the last publish copy's registrations of the
/// shard in range order, so every list holds its adds in (op, ordinal, run) order for any
/// partition, and installs a shrink's prepared owner heads. Each pair (shard) writes only
/// its shard and its tally. Then the log is emptied, the replaced owner heads are freed,
/// and `stats` (when given) takes the counts. Allocates nothing; every add was reserved
/// by the publish.
/// Items are work units: pair p weighs the log's ops + its adds + 1, and a range runs
/// the pairs whose first unit lies in it, so each pair runs in exactly one range. The
/// main thread sums the weights, O(publish ranges * pairs). A shrink's flush carries ops
/// for most cache entries, a one-off the stage's tuner has no threaded profile for, so
/// with a tuned dispatch it runs at a fixed shape of about one pair per range, outside
/// the tuner. A dispatch wakes at most one worker fewer than the pair count. Returns the
/// stage's batch.
pub fn flushRegistry(self: *PathfindingSystem, dispatch: ?Dispatch, stats: ?*PathfindingStats) BatchStats {
    var batch = BatchStats{};
    const truncate = self.registry_truncate_pending;
    const ops = self.completed.core.ownerLog();
    if (ops.len != 0 or self.publish_ranges != 0 or truncate) {
        var pair_adds: [flush_pair_count]usize = @splat(0);
        for (self.publish_bands.items[0..self.publish_ranges]) |band| {
            for (&pair_adds, band.counts) |*adds, count| adds.* += count;
        }
        var unit_starts: [flush_pair_count + 1]usize = undefined;
        var units: usize = 0;
        for (unit_starts[0..flush_pair_count], pair_adds) |*start, adds| {
            start.* = units;
            units += ops.len + adds + 1;
        }
        unit_starts[flush_pair_count] = units;
        const flush_dispatch: ?Dispatch = if (dispatch) |stage| pairs: {
            var flush_stage = stage;
            // At most one participant per pair: a worker past that takes only ranges
            // where no pair starts.
            flush_stage.max_worker_threads = @min(stage.max_worker_threads orelse flush_pair_count - 1, flush_pair_count - 1);
            // Only a tuned dispatch's shrink shape is replaced; a configured range size
            // keeps its shape. The explicit range size opts the batch out of the tuner:
            // nothing is recorded.
            if (truncate and stage.adaptive and stage.items_per_range == null) {
                flush_stage.items_per_range = @divCeil(units, flush_pair_count);
            }
            break :pairs flush_stage;
        } else null;
        const shape = stageShape(flush_dispatch, units, 1);
        var job = RegistryFlushJob{
            .system = self,
            .ops = ops,
            .publish_ranges = self.publish_ranges,
            .truncate = truncate,
            .range_count = shape.range_count,
            .unit_starts = unit_starts,
        };
        batch = runShaped(flush_dispatch, shape, units, 1, &job, registryFlushJob);
        if (comptime runtime_perf_log.enabled) {
            if (stats) |step| {
                for (self.flush_tallies) |tally| {
                    step.perf.registrations_removed += tally.removed;
                    step.perf.registrations_added += tally.added;
                }
            }
        }
    }
    self.publish_ranges = 0;
    self.completed.core.finishOwnerLog(self.allocator);
    if (truncate) {
        for (&self.path_index) |*shard| shard.releaseTruncated();
        self.registry_truncate_pending = false;
    }
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

// One range of `registry_flush`: the pairs (shards) whose first work unit lies in the
// range, each applying the owner log in order and then its segment of every publish range
// in range order.
const RegistryFlushJob = struct {
    system: *PathfindingSystem,
    // The result cache's owner log.
    ops: []const OwnerOp,
    publish_ranges: usize,
    // Install each pair's prepared owner heads after its ops and adds.
    truncate: bool,
    range_count: usize,
    // Per pair, its first work unit, increasing; the last entry is the unit total.
    unit_starts: [flush_pair_count + 1]usize,
};

fn orderUnit(unit: usize, start: usize) std.math.Order {
    return std.math.order(unit, start);
}

// SIMD verdict: scalar. Hash probes and list links per op and add; one binary search over
// the pair starts per range.
fn registryFlushJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *RegistryFlushJob = @ptrCast(@alignCast(context));
    const system = job.system;
    const starts = job.unit_starts[0..flush_pair_count];
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.unit_starts[flush_pair_count]);
    var pair = std.sort.lowerBound(usize, starts, range.start, orderUnit);
    while (pair < flush_pair_count and starts[pair] < range.end) : (pair += 1) {
        std.debug.assert(pair < system.flush_tallies.len);
        const map = &system.path_index[pair];
        var removed: usize = 0;
        for (job.ops) |op| {
            // Most owners hold runs in few shards.
            if (!map.holdsOwner(op.old)) continue;
            if (op.new == no_owner) {
                const count = map.removeOwner(op.old);
                if (comptime runtime_perf_log.enabled) removed += count;
            } else map.renameOwner(op.old, op.new);
        }
        var added: usize = 0;
        for (system.publish_bands.items[0..job.publish_ranges], system.publish_range_bases.items[0..job.publish_ranges]) |band, base| {
            var start = base;
            for (band.counts[0..pair]) |pair_count| start += pair_count;
            map.addAll(system.reg_buckets.items[start..][0..band.counts[pair]]);
            if (comptime runtime_perf_log.enabled) added += band.counts[pair];
        }
        if (job.truncate) map.installTruncate();
        if (comptime runtime_perf_log.enabled) system.flush_tallies[pair] = .{ .removed = removed, .added = added };
    }
}

// ----------------------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------------------

const test_support = @import("test_support.zig");
const updatePathfindingInline = @import("test_support.zig").updatePathfindingInline;
const builtin = @import("builtin");
const stamped_table = @import("../../stamped_table.zig");
const math = @import("../../../core/math.zig");
const DataSystem = @import("../../data_system.zig").DataSystem;
const RangeOutputStream = @import("../../simulation.zig").RangeOutputStream;
const PathRequest = @import("../../simulation.zig").PathRequest;
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const ChunkListMap = @import("../chunk_list_map.zig").ChunkListMap;
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
    const stats = try updatePathfindingInline(&system, &empty, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.escalated_deferred);
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
    try std.testing.expectEqual(goals.len, (try solveIndividualGoals(&system, requester, &goals, 8)).available_results);
    try std.testing.expect(system.completed.long_block_count >= goals.len);
    const grows = system.long_block_growth.count;
    try std.testing.expect(grows >= 1);

    // Cleared (every block free again), the same results publish on a failing allocator.
    clearCompleted(&system);
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;
    defer {
        system.allocator = original;
        system.graph.allocator = original;
    }
    const stats = try solveIndividualGoals(&system, requester, &goals, 8);
    try std.testing.expectEqual(goals.len, stats.available_results);
    try std.testing.expectEqual(grows, system.long_block_growth.count);
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
    try std.testing.expectEqual(@as(usize, 1), (try solveIndividualGoals(&system, requester, &.{aged_goal}, 8)).available_results);
    clearCompleted(&system);
    try std.testing.expectEqual(@as(usize, 0), system.completed.long_block_count);
    try std.testing.expectEqual(@as(usize, 1), (try solveIndividualGoals(&system, requester, &.{aged_goal}, 8)).available_results);
    const aged_owner = test_support.cacheOwnerOf(system.completed.core, system.graph.keyForWorld(0, aged_goal, .default).?).?;
    system.completed.core.records.items[aged_owner].stamp -%= types.default_cache_ttl_steps + 1;
    var aged_registrations: usize = 0;
    for (&system.path_index) |*shard| aged_registrations += shard.entries.len - shard.entry_free.items.len;
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
    for (&system.path_index) |*shard| try std.testing.expectEqual(shard.entries.len, shard.entry_free.items.len);
    try std.testing.expectEqual(goals.len + 1, system.pending.len);
    for (goals) |goal| {
        try std.testing.expect(system.pending_keys.contains(system.graph.keyForWorld(0, goal, .default).?));
        try std.testing.expectEqual(PathStatus.pending, system.statusForWorld(0, cellWorld(1, 2), 0, goal, .default, null).status);
    }

    // With memory back, the next step publishes the same requests without new intake.
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    const retry = try updatePathfindingInline(&system, &empty, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), retry.accepted_requests);
    try std.testing.expectEqual(goals.len + 1, retry.available_results);
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);
    try std.testing.expect(system.long_block_growth.count >= 1);
    for (goals) |goal| {
        try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, cellWorld(1, 2), 0, goal, .default, null).status);
    }
}

test "the path registry holds every run of every published path, and the incremental registry equals one rebuilt from the live cache after victims, TTL expiry, evictions, re-puts, and a shrink with renames" {
    if (!runtime_perf_log.enabled) return error.SkipZigTest;
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
    const reaction = try system.applyBufferedNavUpdates(no_colliders, &fixture.world, null);
    try std.testing.expect(reaction.perf.evicted_results != 0);
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
    for (&system.path_index) |*shard| registrations += shard.entries.len - shard.entry_free.items.len;
    try std.testing.expectEqual(@as(usize, 2), registrations);
}

test "threaded publish equals serial across range sizes and worker counts (cache bytes, per-shard lists, stats), and publish_copy and registry_flush run on workers" {
    if (!runtime_perf_log.enabled) return error.SkipZigTest;
    if (builtin.single_threaded) return error.SkipZigTest;
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
    const serial_stats = try updatePathfindingInline(&serial, &stream, 64, .{});
    try std.testing.expectEqual(@as(usize, 48), serial_stats.available_results);
    try std.testing.expect(serial_stats.perf.registrations_added > 48);
    try std.testing.expect(serial.completed.long_block_count != 0);
    try expectRegistryMatchesCache(&serial);
    for ([_]usize{ 1, 3 }) |workers| {
        var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = workers, .items_per_range = 1 });
        defer threads.deinit();
        if (threads.workerThreadCount() == 0) return error.SkipZigTest;
        for ([_]usize{ 1, 3, 8 }) |items_per_range| {
            var threaded = try registrySystemWith(&data, &fixture.world, 64, .{ .stored_path_cells = 8, .participants = threads.participantSlotCount() });
            defer threaded.deinit();
            const stats = try threaded.update(&stream, 64, &threads, .{ .adaptive = false, .items_per_range = items_per_range });
            try expectSameCache(&serial, &threaded);
            try expectSameRegistry(&serial, &threaded);
            try std.testing.expectEqual(serial_stats.available_results, stats.available_results);
            try std.testing.expectEqual(serial_stats.perf.registrations_added, stats.perf.registrations_added);
            try std.testing.expectEqual(serial_stats.perf.registrations_removed, stats.perf.registrations_removed);
            try std.testing.expectEqual(serial_stats.cache_evictions, stats.cache_evictions);
            if (items_per_range == 1) {
                try std.testing.expect(!stats.perf.publish_copy_batch.ran_inline and stats.perf.publish_copy_batch.range_count > 1);
                try std.testing.expect(!stats.registry_flush_batch.ran_inline and stats.registry_flush_batch.range_count > 1);
            }
        }
    }
}

test "publish after its reserve allocates nothing on a multi-worker ThreadSystem (FailingAllocator)" {
    if (!runtime_perf_log.enabled) return error.SkipZigTest;
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
    try std.testing.expectEqual(@as(usize, 48), published.available_results);
    try std.testing.expect(!published.perf.publish_copy_batch.ran_inline and !published.registry_flush_batch.ran_inline);
    const units = flushUnits(0, published.perf.registrations_added);
    try std.testing.expectEqual(units, published.registry_flush_batch.item_count);
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
    for (&threaded.path_index) |*shard| try std.testing.expectEqual(@as(usize, 32), shard.owner_heads.items.len);
}

test "a shrink's registry flush keeps a configured range size and equals the serial flush" {
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

test "keys of one shard spread over its table (bounded probe length for a dense chunk block)" {
    // A 64 x 64 chunk block of one level: one shard's keys in a registry table.
    var map = ChunkListMap.init(std.testing.allocator, "test registry");
    defer map.deinit();
    const shard = 5;
    var keys: std.ArrayList(u64) = .empty;
    defer keys.deinit(std.testing.allocator);
    for (0..64 * 64) |chunk| {
        const key = chunkKey(3, @intCast(chunk));
        if (registryShard(key) == shard) try keys.append(std.testing.allocator, key);
    }
    try std.testing.expect(keys.items.len > 128);
    try map.reserve(keys.items.len, keys.items.len, keys.items.len);
    for (keys.items, 0..) |key, owner| map.add(@intCast(owner), key, 0);
    const reader = map.reader();
    const mask = reader.keys.len - 1;
    var total: usize = 0;
    var longest: usize = 0;
    for (keys.items) |key| {
        const home = stamped_table.fibonacciSlot(key, reader.shift);
        var distance: usize = 0;
        while (reader.keys[(home + distance) & mask] != key) distance += 1;
        total += distance;
        longest = @max(longest, distance);
    }
    // Linear probing at load <= 1/2 averages under one slot past home.
    try std.testing.expect(total <= keys.items.len);
    try std.testing.expect(longest <= 24);
}
