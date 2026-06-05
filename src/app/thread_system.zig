// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const logging = @import("../core/logging.zig");
const log = logging.app;

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
    grain_size: usize = 1,
    range_alignment_items: usize = 1,
    /// Number of pre-spawned worker threads available to the thread system.
    available_worker_threads: usize = 0,
    /// Number of worker threads used for this batch. The main thread
    /// is not included and may also process ranges.
    active_worker_threads: usize = 0,
    main_thread_ranges: usize = 0,
    worker_thread_ranges: usize = 0,
    worker_utilization: f32 = 0,
    batch_duration_ns: u64 = 0,
    main_thread_wait_ns: u64 = 0,
    ran_inline: bool = true,
};

pub const ThreadSystemConfig = struct {
    /// Maximum worker threads to pre-spawn. `null` uses
    /// `cpu_count - 1` so the main/render thread can be the final participant.
    /// Set to `0` to force serial execution.
    max_worker_threads: ?usize = null,
    stack_size: usize = std.Thread.SpawnConfig.default_stack_size,
    /// Batches smaller than this item count run on the main thread only.
    min_parallel_items: usize = 256,
    /// Number of items assigned to each range before another participant takes
    /// more work.
    grain_size: usize = 64,
};

pub const ParallelForOptions = struct {
    min_parallel_items: ?usize = null,
    grain_size: ?usize = null,
    max_worker_threads: ?usize = null,
    range_alignment_items: usize = 1,
    adaptive: bool = true,
};

pub const JobFn = *const fn (*anyopaque, ParallelRange, WorkerId) void;

pub const ThreadSystem = struct {
    allocator: std.mem.Allocator,
    config: ThreadSystemConfig,
    shared: *Shared,
    workers: []WorkerRecord = &.{},
    scheduler: SchedulerState = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: ThreadSystemConfig) !ThreadSystem {
        const worker_thread_count = try resolveWorkerThreadCount(config.max_worker_threads);
        const shared = try allocator.create(Shared);
        errdefer allocator.destroy(shared);
        shared.* = .{ .io = io };

        const workers = try allocator.alloc(WorkerRecord, worker_thread_count);
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
            self.shared.mutex.unlock(self.shared.io);
            for (self.workers[0..spawned]) |*worker| {
                worker.wake.post(self.shared.io);
                if (worker.thread) |thread| thread.join();
            }
        }

        for (self.workers, 0..) |*worker, index| {
            worker.id = .{ .index = index + 1 };
            worker.shared = self.shared;
            worker.thread = std.Thread.spawn(.{
                .stack_size = self.config.stack_size,
                .allocator = allocator,
            }, workerMain, .{worker}) catch |err| {
                log.err("failed to spawn ThreadSystem worker {}: {}", .{ worker.id.index, err });
                return err;
            };
            self.scheduler.preferred_worker_threads = if (self.workers.len > 0) 1 else 0;
            spawned += 1;
        }

        log.debug(
            "ThreadSystem initialized: worker_threads={} min_parallel_items={} grain_size={} stack_size={}",
            .{ self.workers.len, self.config.min_parallel_items, self.config.grain_size, self.config.stack_size },
        );
        return self;
    }

    pub fn deinit(self: *ThreadSystem) void {
        self.shared.mutex.lockUncancelable(self.shared.io);
        std.debug.assert(self.shared.batch.pending_workers == 0);
        self.shared.accepting_work = false;
        self.shared.mutex.unlock(self.shared.io);

        for (self.workers) |*worker| {
            worker.wake.post(self.shared.io);
            if (worker.thread) |thread| thread.join();
        }
        self.allocator.free(self.workers);
        self.allocator.destroy(self.shared);
        self.* = undefined;
    }

    pub fn workerThreadCount(self: *const ThreadSystem) usize {
        return self.workers.len;
    }

    pub fn participantSlotCount(self: *const ThreadSystem) usize {
        return self.workers.len + 1;
    }

    pub fn scratchSlotForWorker(_: *const ThreadSystem, id: WorkerId) usize {
        return id.index;
    }

    pub fn parallelFor(
        self: *ThreadSystem,
        item_count: usize,
        context: *anyopaque,
        job_fn: JobFn,
    ) BatchStats {
        return self.parallelForWithOptions(item_count, context, job_fn, .{});
    }

    pub fn parallelForWithOptions(
        self: *ThreadSystem,
        item_count: usize,
        context: *anyopaque,
        job_fn: JobFn,
        options: ParallelForOptions,
    ) BatchStats {
        if (item_count == 0) return .{};

        const range_alignment_items = @max(options.range_alignment_items, @as(usize, 1));
        const requested_grain_size = @max(options.grain_size orelse self.config.grain_size, @as(usize, 1));
        const grain_size = alignItemCount(requested_grain_size, range_alignment_items);
        const min_parallel_items = options.min_parallel_items orelse self.config.min_parallel_items;
        const range_count = rangeCount(item_count, grain_size);
        const max_worker_threads = @min(options.max_worker_threads orelse self.workers.len, self.workers.len);
        var stats = BatchStats{
            .item_count = item_count,
            .range_count = range_count,
            .grain_size = grain_size,
            .range_alignment_items = range_alignment_items,
            .available_worker_threads = self.workers.len,
            .active_worker_threads = max_worker_threads,
        };

        if (max_worker_threads == 0 or item_count < min_parallel_items or range_count <= 1) {
            stats.active_worker_threads = 0;
            runInline(item_count, grain_size, context, job_fn, &stats);
            self.scheduler.record(stats);
            return stats;
        }

        const active_worker_threads = self.scheduler.chooseActiveWorkerThreads(
            max_worker_threads,
            range_count,
            options.adaptive,
        );
        if (active_worker_threads == 0) {
            stats.active_worker_threads = 0;
            runInline(item_count, grain_size, context, job_fn, &stats);
            self.scheduler.record(stats);
            return stats;
        }

        const batch_start_ns = nowNs(self.shared.io);
        self.shared.mutex.lockUncancelable(self.shared.io);
        std.debug.assert(self.shared.accepting_work);
        std.debug.assert(self.shared.batch.pending_workers == 0);

        const batch_id = self.shared.next_batch_id;
        self.shared.next_batch_id += 1;
        self.shared.batch = .{
            .id = batch_id,
            .item_count = item_count,
            .grain_size = grain_size,
            .range_count = range_count,
            .next_range = .init(active_worker_threads),
            .active_worker_thread_count = active_worker_threads,
            .pending_workers = active_worker_threads,
            .context = context,
            .job_fn = job_fn,
            .main_thread_ranges = .init(0),
            .worker_thread_ranges = .init(0),
        };
        stats.active_worker_threads = active_worker_threads;
        stats.ran_inline = false;

        self.shared.mutex.unlock(self.shared.io);

        for (self.workers[0..active_worker_threads]) |*worker| {
            worker.wake.post(self.shared.io);
        }

        self.shared.runBatchRanges(WorkerId.main);

        const wait_start_ns = nowNs(self.shared.io);
        self.shared.mutex.lockUncancelable(self.shared.io);
        while (self.shared.batch.pending_workers != 0) {
            self.shared.batch_complete.waitUncancelable(self.shared.io, &self.shared.mutex);
        }
        const wait_end_ns = nowNs(self.shared.io);
        stats.main_thread_ranges = self.shared.batch.main_thread_ranges.load(.monotonic);
        stats.worker_thread_ranges = self.shared.batch.worker_thread_ranges.load(.monotonic);
        self.shared.batch = .{};
        self.shared.mutex.unlock(self.shared.io);

        const batch_end_ns = nowNs(self.shared.io);
        stats.main_thread_wait_ns = elapsedNs(wait_start_ns, wait_end_ns);
        stats.batch_duration_ns = elapsedNs(batch_start_ns, batch_end_ns);
        stats.worker_utilization = workerUtilization(stats.worker_thread_ranges, active_worker_threads, range_count);
        self.scheduler.record(stats);

        return stats;
    }
};

const Shared = struct {
    io: std.Io,
    batch: Batch = .{},
    mutex: std.Io.Mutex = .init,
    batch_complete: std.Io.Condition = .init,
    next_batch_id: u64 = 1,
    accepting_work: bool = true,

    fn workerLoop(self: *Shared, id: WorkerId, wake: *std.Io.Semaphore) void {
        var seen_batch_id: u64 = 0;
        while (true) {
            wake.waitUncancelable(self.io);

            self.mutex.lockUncancelable(self.io);
            if (!self.accepting_work) {
                self.mutex.unlock(self.io);
                return;
            }
            if (self.batch.id == seen_batch_id) {
                self.mutex.unlock(self.io);
                continue;
            }

            seen_batch_id = self.batch.id;
            const assigned_range_index = id.index - 1;
            if (id.index > self.batch.active_worker_thread_count or assigned_range_index >= self.batch.range_count) {
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
            const range_index = self.batch.next_range.fetchAdd(1, .monotonic);
            if (range_index >= self.batch.range_count) return;

            const range = rangeForIndex(self.batch.item_count, self.batch.grain_size, range_index);
            const job_fn = self.batch.job_fn.?;
            const context = self.batch.context.?;
            if (id.index == 0) {
                _ = self.batch.main_thread_ranges.fetchAdd(1, .monotonic);
            } else {
                _ = self.batch.worker_thread_ranges.fetchAdd(1, .monotonic);
            }

            job_fn(context, range, id);
        }
    }

    fn runBatchRangeIndex(self: *Shared, id: WorkerId, range_index: usize) void {
        const range = rangeForIndex(self.batch.item_count, self.batch.grain_size, range_index);
        const job_fn = self.batch.job_fn.?;
        const context = self.batch.context.?;
        if (id.index == 0) {
            _ = self.batch.main_thread_ranges.fetchAdd(1, .monotonic);
        } else {
            _ = self.batch.worker_thread_ranges.fetchAdd(1, .monotonic);
        }

        job_fn(context, range, id);
    }
};

const WorkerRecord = struct {
    id: WorkerId = WorkerId.main,
    shared: *Shared = undefined,
    wake: std.Io.Semaphore = .{},
    thread: ?std.Thread = null,
};

const Batch = struct {
    id: u64 = 0,
    item_count: usize = 0,
    grain_size: usize = 1,
    range_count: usize = 0,
    next_range: std.atomic.Value(usize) = .init(0),
    active_worker_thread_count: usize = 0,
    pending_workers: usize = 0,
    context: ?*anyopaque = null,
    job_fn: ?JobFn = null,
    main_thread_ranges: std.atomic.Value(usize) = .init(0),
    worker_thread_ranges: std.atomic.Value(usize) = .init(0),
};

fn workerMain(worker: *WorkerRecord) void {
    worker.shared.workerLoop(worker.id, &worker.wake);
}

fn normalizeConfig(config: ThreadSystemConfig) ThreadSystemConfig {
    var normalized = config;
    normalized.grain_size = @max(normalized.grain_size, @as(usize, 1));
    return normalized;
}

fn resolveWorkerThreadCount(override_count: ?usize) !usize {
    if (override_count) |count| return count;
    const cpu_count = std.Thread.getCpuCount() catch |err| {
        log.warn("failed to query CPU count for ThreadSystem; using serial execution fallback: {}", .{err});
        return 0;
    };
    return if (cpu_count > 1) cpu_count - 1 else 0;
}

fn rangeCount(item_count: usize, grain_size: usize) usize {
    return (item_count + grain_size - 1) / grain_size;
}

fn alignItemCount(item_count: usize, alignment: usize) usize {
    std.debug.assert(alignment > 0);
    if (alignment == 1) return item_count;
    const remainder = item_count % alignment;
    if (remainder == 0) return item_count;
    return item_count + (alignment - remainder);
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

fn nowNs(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).toNanoseconds();
}

fn elapsedNs(start_ns: i96, end_ns: i96) u64 {
    return if (end_ns > start_ns) @intCast(end_ns - start_ns) else 0;
}

fn workerUtilization(worker_thread_ranges: usize, active_worker_threads: usize, range_count: usize) f32 {
    if (active_worker_threads == 0 or range_count == 0) return 0;
    const expected_worker_ranges = @min(range_count, active_worker_threads);
    if (expected_worker_ranges == 0) return 0;
    const actual: f32 = @floatFromInt(@min(worker_thread_ranges, range_count));
    const expected: f32 = @floatFromInt(range_count);
    return actual / expected;
}

const SchedulerState = struct {
    preferred_worker_threads: usize = 0,
    last_batch_duration_ns: u64 = 0,
    last_main_thread_wait_ns: u64 = 0,
    last_worker_utilization: f32 = 0,
    last_active_worker_threads: usize = 0,

    const busy_batch_ns: u64 = 100_000;
    const idle_batch_ns: u64 = 25_000;
    const high_utilization: f32 = 0.45;
    const low_utilization: f32 = 0.15;
    const ranges_per_participant: usize = 2;

    fn chooseActiveWorkerThreads(
        self: *SchedulerState,
        available_worker_threads: usize,
        range_count: usize,
        adaptive: bool,
    ) usize {
        if (available_worker_threads == 0 or range_count <= 1) return 0;

        const range_limited_workers = @min(available_worker_threads, range_count - 1);
        if (!adaptive) return range_limited_workers;

        const desired_participants = @max(
            @as(usize, 2),
            (range_count + ranges_per_participant - 1) / ranges_per_participant,
        );
        const range_target = @min(range_limited_workers, desired_participants - 1);
        if (self.last_active_worker_threads == 0) return range_target;

        var target = if (self.preferred_worker_threads == 0) range_target else @min(self.preferred_worker_threads, range_limited_workers);
        target = @max(@as(usize, 1), target);

        if (self.last_batch_duration_ns >= busy_batch_ns and
            self.last_worker_utilization >= high_utilization and
            self.last_active_worker_threads >= target)
        {
            target = @min(range_limited_workers, target + 1);
        } else if (self.last_batch_duration_ns <= idle_batch_ns or
            (self.last_main_thread_wait_ns == 0 and self.last_worker_utilization <= low_utilization))
        {
            target = if (target > 1) target - 1 else 1;
        }

        return @min(target, range_limited_workers);
    }

    fn record(self: *SchedulerState, stats: BatchStats) void {
        self.last_batch_duration_ns = stats.batch_duration_ns;
        self.last_main_thread_wait_ns = stats.main_thread_wait_ns;
        self.last_worker_utilization = stats.worker_utilization;
        self.last_active_worker_threads = stats.active_worker_threads;
        if (!stats.ran_inline) {
            self.preferred_worker_threads = stats.active_worker_threads;
        }
    }
};

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
        .max_worker_threads = 0,
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

test "worker thread parallel for covers every item exactly once" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 128;
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .min_parallel_items = 1,
        .grain_size = 1,
    });
    defer threads.deinit();

    const stats = threads.parallelFor(hits.len, &context, markCoverage);

    try std.testing.expect(!stats.ran_inline);
    try std.testing.expect(stats.main_thread_ranges > 0);
    try std.testing.expect(stats.worker_thread_ranges > 0);
    try std.testing.expect(context.worker_hits.load(.monotonic) > 0);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "small batches run inline even when worker threads exist" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 8;
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 1,
        .min_parallel_items = 64,
        .grain_size = 2,
    });
    defer threads.deinit();

    const stats = threads.parallelFor(hits.len, &context, markCoverage);

    try std.testing.expect(stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 0), stats.active_worker_threads);
    try std.testing.expectEqual(@as(usize, 0), stats.worker_thread_ranges);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "parallel for options cap active workers and align ranges" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 256;
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 3,
        .min_parallel_items = 1,
        .grain_size = 1,
    });
    defer threads.deinit();

    const stats = threads.parallelForWithOptions(hits.len, &context, markCoverage, .{
        .grain_size = 17,
        .range_alignment_items = 16,
        .max_worker_threads = 1,
        .adaptive = false,
    });

    try std.testing.expect(!stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 32), stats.grain_size);
    try std.testing.expectEqual(@as(usize, 16), stats.range_alignment_items);
    try std.testing.expectEqual(@as(usize, 3), stats.available_worker_threads);
    try std.testing.expectEqual(@as(usize, 1), stats.active_worker_threads);
    try std.testing.expect(stats.worker_thread_ranges > 0);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "scheduler increases active workers after busy utilized batch" {
    var scheduler = SchedulerState{};

    const first = scheduler.chooseActiveWorkerThreads(4, 32, true);
    try std.testing.expectEqual(@as(usize, 4), first);

    scheduler.preferred_worker_threads = 1;
    scheduler.record(.{
        .item_count = 1024,
        .range_count = 32,
        .grain_size = 32,
        .available_worker_threads = 4,
        .active_worker_threads = 1,
        .worker_thread_ranges = 18,
        .batch_duration_ns = SchedulerState.busy_batch_ns,
        .main_thread_wait_ns = 1,
        .worker_utilization = 0.56,
        .ran_inline = false,
    });

    try std.testing.expectEqual(@as(usize, 2), scheduler.chooseActiveWorkerThreads(4, 32, true));
}

test "scheduler reduces active workers after cheap underutilized batch" {
    var scheduler = SchedulerState{ .preferred_worker_threads = 3 };
    scheduler.record(.{
        .item_count = 256,
        .range_count = 8,
        .grain_size = 32,
        .available_worker_threads = 4,
        .active_worker_threads = 3,
        .batch_duration_ns = SchedulerState.idle_batch_ns,
        .worker_utilization = 0.05,
        .ran_inline = false,
    });

    try std.testing.expectEqual(@as(usize, 2), scheduler.chooseActiveWorkerThreads(4, 8, true));
    try std.testing.expectEqual(@as(usize, 4), scheduler.chooseActiveWorkerThreads(4, 8, false));
}

test "worker scratch slots include main thread and worker threads" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
    });
    defer threads.deinit();

    try std.testing.expectEqual(@as(usize, 3), threads.participantSlotCount());
    try std.testing.expectEqual(@as(usize, 0), threads.scratchSlotForWorker(WorkerId.main));
    try std.testing.expectEqual(@as(usize, 2), threads.scratchSlotForWorker(.{ .index = 2 }));
}

test "batch submission does not allocate after init" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 0,
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
