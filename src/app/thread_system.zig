// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");

pub const WorkerId = struct {
    index: usize,

    pub const main = WorkerId{ .index = 0 };
};

pub const ParallelRange = struct {
    start: usize,
    end: usize,

    pub fn len(self: ParallelRange) usize {
        return self.end - self.start;
    }
};

pub const BatchStats = struct {
    item_count: usize = 0,
    range_count: usize = 0,
    /// Number of background worker threads used for this batch. The main thread
    /// is not included and may also process ranges.
    background_worker_count: usize = 0,
    main_thread_ranges: usize = 0,
    background_worker_ranges: usize = 0,
    ran_inline: bool = true,
};

pub const ThreadSystemConfig = struct {
    /// Maximum background worker threads to pre-spawn. `null` uses
    /// `cpu_count - 1` so the main/render thread can be the final participant.
    /// Set to `0` to force serial execution.
    max_background_workers: ?usize = null,
    stack_size: usize = std.Thread.SpawnConfig.default_stack_size,
    /// Batches smaller than this item count run on the main thread only.
    min_parallel_items: usize = 256,
    /// Number of items assigned to each range before another participant takes
    /// more work.
    grain_size: usize = 64,
    /// Reserved for a future multi-batch queue; current implementation accepts
    /// one synchronous batch at a time.
    queue_capacity: usize = 1,
    /// Reserved for future spin-before-park tuning. Workers currently park on a
    /// condition variable when idle.
    short_spin_count: u32 = 64,
};

pub const JobFn = *const fn (*anyopaque, ParallelRange, WorkerId) void;

pub const ThreadSystem = struct {
    allocator: std.mem.Allocator,
    config: ThreadSystemConfig,
    shared: *Shared,
    workers: []WorkerRecord = &.{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: ThreadSystemConfig) !ThreadSystem {
        const background_worker_count = try resolveBackgroundWorkerCount(config.max_background_workers);
        const shared = try allocator.create(Shared);
        errdefer allocator.destroy(shared);
        shared.* = .{ .io = io };

        const workers = try allocator.alloc(WorkerRecord, background_worker_count);
        errdefer allocator.free(workers);

        var self = ThreadSystem{
            .allocator = allocator,
            .config = normalizeConfig(config),
            .shared = shared,
            .workers = workers,
        };
        @memset(self.workers, WorkerRecord{});

        var spawned: usize = 0;
        errdefer {
            self.shared.mutex.lockUncancelable(self.shared.io);
            self.shared.accepting_work = false;
            self.shared.work_available.broadcast(self.shared.io);
            self.shared.mutex.unlock(self.shared.io);
            for (self.workers[0..spawned]) |worker| {
                if (worker.thread) |thread| thread.join();
            }
        }

        for (self.workers, 0..) |*worker, index| {
            worker.id = .{ .index = index + 1 };
            worker.shared = self.shared;
            worker.thread = try std.Thread.spawn(.{
                .stack_size = self.config.stack_size,
                .allocator = allocator,
            }, workerMain, .{worker});
            spawned += 1;
        }

        return self;
    }

    pub fn deinit(self: *ThreadSystem) void {
        self.shared.mutex.lockUncancelable(self.shared.io);
        std.debug.assert(self.shared.batch.pending_workers == 0);
        self.shared.accepting_work = false;
        self.shared.work_available.broadcast(self.shared.io);
        self.shared.mutex.unlock(self.shared.io);

        for (self.workers) |worker| {
            if (worker.thread) |thread| thread.join();
        }
        self.allocator.free(self.workers);
        self.allocator.destroy(self.shared);
        self.* = undefined;
    }

    pub fn backgroundWorkerCount(self: *const ThreadSystem) usize {
        return self.workers.len;
    }

    pub fn parallelFor(
        self: *ThreadSystem,
        item_count: usize,
        context: *anyopaque,
        job_fn: JobFn,
    ) BatchStats {
        if (item_count == 0) return .{};

        const grain_size = @max(self.config.grain_size, @as(usize, 1));
        const range_count = rangeCount(item_count, grain_size);
        var stats = BatchStats{
            .item_count = item_count,
            .range_count = range_count,
            .background_worker_count = self.workers.len,
        };

        if (self.workers.len == 0 or item_count < self.config.min_parallel_items or range_count <= 1) {
            runInline(item_count, grain_size, context, job_fn, &stats);
            return stats;
        }

        self.shared.mutex.lockUncancelable(self.shared.io);
        std.debug.assert(self.shared.accepting_work);
        std.debug.assert(self.shared.batch.pending_workers == 0);

        const active_background_workers = @min(self.workers.len, range_count - 1);
        const batch_id = self.shared.next_batch_id;
        self.shared.next_batch_id += 1;
        self.shared.batch = .{
            .id = batch_id,
            .item_count = item_count,
            .grain_size = grain_size,
            .range_count = range_count,
            .next_range = active_background_workers,
            .active_background_worker_count = active_background_workers,
            .pending_workers = active_background_workers,
            .context = context,
            .job_fn = job_fn,
            .main_thread_ranges = 0,
            .background_worker_ranges = 0,
        };
        stats.background_worker_count = active_background_workers;
        stats.ran_inline = false;

        self.shared.work_available.broadcast(self.shared.io);
        self.shared.mutex.unlock(self.shared.io);

        self.shared.runBatchRanges(WorkerId.main);

        self.shared.mutex.lockUncancelable(self.shared.io);
        while (self.shared.batch.pending_workers != 0) {
            self.shared.batch_complete.waitUncancelable(self.shared.io, &self.shared.mutex);
        }
        stats.main_thread_ranges = self.shared.batch.main_thread_ranges;
        stats.background_worker_ranges = self.shared.batch.background_worker_ranges;
        self.shared.batch = .{};
        self.shared.mutex.unlock(self.shared.io);

        return stats;
    }
};

const Shared = struct {
    io: std.Io,
    batch: Batch = .{},
    mutex: std.Io.Mutex = .init,
    work_available: std.Io.Condition = .init,
    batch_complete: std.Io.Condition = .init,
    next_batch_id: u64 = 1,
    accepting_work: bool = true,

    fn workerLoop(self: *Shared, id: WorkerId) void {
        var seen_batch_id: u64 = 0;
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.accepting_work and self.batch.id == seen_batch_id) {
                self.work_available.waitUncancelable(self.io, &self.mutex);
            }

            if (!self.accepting_work) {
                self.mutex.unlock(self.io);
                return;
            }

            seen_batch_id = self.batch.id;
            const assigned_range_index = id.index - 1;
            if (id.index > self.batch.active_background_worker_count or assigned_range_index >= self.batch.range_count) {
                self.mutex.unlock(self.io);
                continue;
            }
            self.mutex.unlock(self.io);

            self.runBatchRangeIndex(id, assigned_range_index);
            self.runBatchRanges(id);

            self.mutex.lockUncancelable(self.io);
            std.debug.assert(self.batch.pending_workers > 0);
            self.batch.pending_workers -= 1;
            if (self.batch.pending_workers == 0) {
                self.batch_complete.signal(self.io);
            }
            self.mutex.unlock(self.io);
        }
    }

    fn runBatchRanges(self: *Shared, id: WorkerId) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const range_index = self.batch.next_range;
            if (range_index >= self.batch.range_count) {
                self.mutex.unlock(self.io);
                return;
            }

            self.batch.next_range += 1;
            const range = rangeForIndex(self.batch.item_count, self.batch.grain_size, range_index);
            const job_fn = self.batch.job_fn.?;
            const context = self.batch.context.?;
            if (id.index == 0) {
                self.batch.main_thread_ranges += 1;
            } else {
                self.batch.background_worker_ranges += 1;
            }
            self.mutex.unlock(self.io);

            job_fn(context, range, id);
        }
    }

    fn runBatchRangeIndex(self: *Shared, id: WorkerId, range_index: usize) void {
        self.mutex.lockUncancelable(self.io);
        const range = rangeForIndex(self.batch.item_count, self.batch.grain_size, range_index);
        const job_fn = self.batch.job_fn.?;
        const context = self.batch.context.?;
        if (id.index == 0) {
            self.batch.main_thread_ranges += 1;
        } else {
            self.batch.background_worker_ranges += 1;
        }
        self.mutex.unlock(self.io);

        job_fn(context, range, id);
    }
};

const WorkerRecord = struct {
    id: WorkerId = WorkerId.main,
    shared: *Shared = undefined,
    thread: ?std.Thread = null,
};

const Batch = struct {
    id: u64 = 0,
    item_count: usize = 0,
    grain_size: usize = 1,
    range_count: usize = 0,
    next_range: usize = 0,
    active_background_worker_count: usize = 0,
    pending_workers: usize = 0,
    context: ?*anyopaque = null,
    job_fn: ?JobFn = null,
    main_thread_ranges: usize = 0,
    background_worker_ranges: usize = 0,
};

fn workerMain(worker: *WorkerRecord) void {
    worker.shared.workerLoop(worker.id);
}

fn normalizeConfig(config: ThreadSystemConfig) ThreadSystemConfig {
    var normalized = config;
    normalized.grain_size = @max(normalized.grain_size, @as(usize, 1));
    normalized.queue_capacity = @max(normalized.queue_capacity, @as(usize, 1));
    return normalized;
}

fn resolveBackgroundWorkerCount(override_count: ?usize) !usize {
    if (override_count) |count| return count;
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return if (cpu_count > 1) cpu_count - 1 else 0;
}

fn rangeCount(item_count: usize, grain_size: usize) usize {
    return (item_count + grain_size - 1) / grain_size;
}

fn rangeForIndex(item_count: usize, grain_size: usize, range_index: usize) ParallelRange {
    const start = range_index * grain_size;
    return .{
        .start = start,
        .end = @min(start + grain_size, item_count),
    };
}

fn runInline(item_count: usize, grain_size: usize, context: *anyopaque, job_fn: JobFn, stats: *BatchStats) void {
    for (0..rangeCount(item_count, grain_size)) |range_index| {
        job_fn(context, rangeForIndex(item_count, grain_size, range_index), WorkerId.main);
        stats.main_thread_ranges += 1;
    }
}

const CoverageContext = struct {
    hits: []std.atomic.Value(u32),
    worker_hits: std.atomic.Value(u32) = .init(0),
    main_hits: std.atomic.Value(u32) = .init(0),
};

fn markCoverage(context: *anyopaque, range: ParallelRange, id: WorkerId) void {
    const coverage: *CoverageContext = @ptrCast(@alignCast(context));
    for (range.start..range.end) |index| {
        _ = coverage.hits[index].fetchAdd(1, .monotonic);
    }
    if (id.index == 0) {
        _ = coverage.main_hits.fetchAdd(1, .monotonic);
    } else {
        _ = coverage.worker_hits.fetchAdd(1, .monotonic);
    }
}

test "inline parallel for covers every item exactly once" {
    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 8;
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_background_workers = 0,
        .min_parallel_items = 1,
        .grain_size = 2,
    });
    defer threads.deinit();

    const stats = threads.parallelFor(hits.len, &context, markCoverage);

    try std.testing.expect(stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 4), stats.main_thread_ranges);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "background worker parallel for covers every item exactly once" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 128;
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_background_workers = 2,
        .min_parallel_items = 1,
        .grain_size = 1,
    });
    defer threads.deinit();

    const stats = threads.parallelFor(hits.len, &context, markCoverage);

    try std.testing.expect(!stats.ran_inline);
    try std.testing.expect(stats.main_thread_ranges > 0);
    try std.testing.expect(stats.background_worker_ranges > 0);
    try std.testing.expect(context.worker_hits.load(.monotonic) > 0);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "small batches run inline even when background workers exist" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 8;
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_background_workers = 1,
        .min_parallel_items = 64,
        .grain_size = 2,
    });
    defer threads.deinit();

    const stats = threads.parallelFor(hits.len, &context, markCoverage);

    try std.testing.expect(stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 0), stats.background_worker_ranges);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "batch submission does not allocate after init" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_background_workers = 0,
        .min_parallel_items = 1,
        .grain_size = 2,
    });
    defer threads.deinit();

    const original_allocator = threads.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    threads.allocator = failing_allocator.allocator();
    defer threads.allocator = original_allocator;

    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 4;
    var context = CoverageContext{ .hits = hits[0..] };
    const stats = threads.parallelFor(hits.len, &context, markCoverage);

    try std.testing.expect(stats.ran_inline);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}
