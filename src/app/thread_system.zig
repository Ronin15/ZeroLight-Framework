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
    index: usize = 0,
    start: usize,
    end: usize,

    pub fn len(self: ParallelRange) usize {
        return self.end - self.start;
    }
};

pub const BatchStats = struct {
    item_count: usize = 0,
    range_count: usize = 0,
    items_per_range: usize = 1,
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
    items_per_range: usize = 64,
};

pub const ParallelForOptions = struct {
    min_parallel_items: ?usize = null,
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    range_alignment_items: usize = 1,
    adaptive: bool = true,
    adaptive_thread_count: ?*AdaptiveThreadCount = null,
};

pub const AdaptiveRangeTunerConfig = struct {
    initial_items_per_range: usize = (ThreadSystemConfig{}).items_per_range,
    min_items_per_range: usize = 16,
    max_items_per_range: usize = (ThreadSystemConfig{}).items_per_range * 64,
    sample_window: usize = 8,
    improvement_threshold_percent: u8 = 8,
    item_count_reset_percent: u8 = 25,
    settle_after_failed_probes: usize = 2,
    retune_after_settled_windows: usize = 120,
};

pub const AdaptiveRangePhase = enum {
    learning,
    probing,
    settled,
};

pub const AdaptiveRangeReport = struct {
    phase: AdaptiveRangePhase = .learning,
    initial_items_per_range: usize = (ThreadSystemConfig{}).items_per_range,
    current_items_per_range: usize = (ThreadSystemConfig{}).items_per_range,
    best_items_per_range: usize = (ThreadSystemConfig{}).items_per_range,
    candidate_items_per_range: ?usize = null,
    sample_count: usize = 0,
    sample_window: usize = 1,
    failed_probe_count: usize = 0,
    settled_window_count: usize = 0,
    settle_after_failed_probes: usize = 1,
    retune_after_settled_windows: usize = 1,
    best_mean_batch_duration_ns: u64 = 0,
    baseline_mean_batch_duration_ns: u64 = 0,
    probing: bool = false,
};

pub const AdaptiveRangeTuner = struct {
    config: AdaptiveRangeTunerConfig,
    phase: AdaptiveRangePhase = .learning,
    initial_items_per_range: usize,
    current_items_per_range: usize,
    best_items_per_range: usize,
    best_mean_batch_duration_ns: u64 = 0,
    baseline_mean_batch_duration_ns: u64 = 0,
    sample_count: usize = 0,
    sample_total_ns: u128 = 0,
    candidate_items_per_range: ?usize = null,
    probe_direction: ProbeDirection = .grow,
    failed_probe_count: usize = 0,
    settled_window_count: usize = 0,
    last_item_count: usize = 0,
    last_range_alignment_items: usize = 1,
    sampled_active_worker_threads: ?usize = null,

    const ProbeDirection = enum { grow, shrink };

    pub fn init(config: AdaptiveRangeTunerConfig) AdaptiveRangeTuner {
        const normalized = normalizeTunerConfig(config);
        const initial = clampItemCount(normalized.initial_items_per_range, normalized.min_items_per_range, normalized.max_items_per_range);
        return .{
            .config = normalized,
            .initial_items_per_range = initial,
            .current_items_per_range = initial,
            .best_items_per_range = initial,
        };
    }

    pub fn itemsPerRange(self: *AdaptiveRangeTuner, item_count: usize, range_alignment_items: usize) usize {
        self.last_range_alignment_items = @max(range_alignment_items, @as(usize, 1));
        if (self.last_item_count != 0 and itemCountShifted(self.last_item_count, item_count, self.config.item_count_reset_percent)) {
            self.resetForLearning();
        }
        self.last_item_count = item_count;

        const selected = switch (self.phase) {
            .learning, .settled => self.current_items_per_range,
            .probing => self.candidate_items_per_range orelse self.current_items_per_range,
        };
        return self.normalizedItemsPerRange(selected);
    }

    pub fn record(self: *AdaptiveRangeTuner, stats: BatchStats) void {
        if (stats.item_count == 0) return;
        if (stats.ran_inline or stats.active_worker_threads == 0 or stats.batch_duration_ns == 0) {
            if (self.phase == .probing and stats.range_count <= 1) {
                self.rejectProbe();
                self.resetSamples();
            }
            return;
        }

        if (self.sampled_active_worker_threads) |sampled| {
            if (sampled != stats.active_worker_threads) {
                self.resetSamples();
            }
        }
        self.sampled_active_worker_threads = stats.active_worker_threads;

        self.sample_count += 1;
        self.sample_total_ns += stats.batch_duration_ns;
        if (self.sample_count < self.config.sample_window) return;

        const sample_mean_ns: u64 = @intCast(self.sample_total_ns / self.sample_count);
        switch (self.phase) {
            .learning => self.finishLearningWindow(sample_mean_ns),
            .probing => self.finishProbeWindow(sample_mean_ns),
            .settled => self.finishSettledWindow(sample_mean_ns),
        }
        self.resetSamples();
    }

    pub fn report(self: *const AdaptiveRangeTuner) AdaptiveRangeReport {
        return .{
            .phase = self.phase,
            .initial_items_per_range = self.initial_items_per_range,
            .current_items_per_range = self.current_items_per_range,
            .best_items_per_range = self.best_items_per_range,
            .candidate_items_per_range = self.candidate_items_per_range,
            .sample_count = self.sample_count,
            .sample_window = self.config.sample_window,
            .failed_probe_count = self.failed_probe_count,
            .settled_window_count = self.settled_window_count,
            .settle_after_failed_probes = self.config.settle_after_failed_probes,
            .retune_after_settled_windows = self.config.retune_after_settled_windows,
            .best_mean_batch_duration_ns = self.best_mean_batch_duration_ns,
            .baseline_mean_batch_duration_ns = self.baseline_mean_batch_duration_ns,
            .probing = self.phase == .probing,
        };
    }

    pub fn isSettled(self: *const AdaptiveRangeTuner) bool {
        return self.phase == .settled;
    }

    fn finishLearningWindow(self: *AdaptiveRangeTuner, sample_mean_ns: u64) void {
        self.baseline_mean_batch_duration_ns = sample_mean_ns;
        self.recordBest(self.current_items_per_range, sample_mean_ns);
        self.startProbe(.grow);
    }

    fn finishProbeWindow(self: *AdaptiveRangeTuner, sample_mean_ns: u64) void {
        const candidate = self.candidate_items_per_range orelse {
            self.settle();
            return;
        };

        if (isMeaningfullyFaster(sample_mean_ns, self.best_mean_batch_duration_ns, self.config.improvement_threshold_percent)) {
            self.current_items_per_range = candidate;
            self.baseline_mean_batch_duration_ns = sample_mean_ns;
            self.recordBest(candidate, sample_mean_ns);
            self.failed_probe_count = 0;
            self.startProbe(self.probe_direction);
            return;
        }

        self.rejectProbe();
    }

    fn finishSettledWindow(self: *AdaptiveRangeTuner, sample_mean_ns: u64) void {
        self.baseline_mean_batch_duration_ns = sample_mean_ns;
        self.recordBest(self.current_items_per_range, sample_mean_ns);
        self.settled_window_count += 1;
        if (self.settled_window_count >= self.config.retune_after_settled_windows) {
            self.startProbe(.grow);
        }
    }

    fn startProbe(self: *AdaptiveRangeTuner, direction: ProbeDirection) void {
        self.probe_direction = direction;
        self.candidate_items_per_range = self.nextCandidate(direction);
        if (self.candidate_items_per_range == null and direction == .grow) {
            self.probe_direction = .shrink;
            self.candidate_items_per_range = self.nextCandidate(.shrink);
        } else if (self.candidate_items_per_range == null and direction == .shrink) {
            self.probe_direction = .grow;
            self.candidate_items_per_range = self.nextCandidate(.grow);
        }
        if (self.candidate_items_per_range == null) {
            self.settle();
        } else {
            self.phase = .probing;
        }
    }

    fn settle(self: *AdaptiveRangeTuner) void {
        self.phase = .settled;
        self.current_items_per_range = self.best_items_per_range;
        self.candidate_items_per_range = null;
        self.failed_probe_count = 0;
        self.settled_window_count = 0;
    }

    fn resetForLearning(self: *AdaptiveRangeTuner) void {
        self.phase = .learning;
        self.current_items_per_range = self.initial_items_per_range;
        self.best_items_per_range = self.initial_items_per_range;
        self.best_mean_batch_duration_ns = 0;
        self.baseline_mean_batch_duration_ns = 0;
        self.candidate_items_per_range = null;
        self.probe_direction = .grow;
        self.failed_probe_count = 0;
        self.settled_window_count = 0;
        self.resetSamples();
    }

    fn normalizedItemsPerRange(self: *const AdaptiveRangeTuner, items_per_range: usize) usize {
        const clamped = clampItemCount(items_per_range, self.config.min_items_per_range, self.config.max_items_per_range);
        const aligned_up = alignItemCount(clamped, self.last_range_alignment_items);
        if (aligned_up <= self.config.max_items_per_range) return aligned_up;

        const aligned_max = alignItemCountDown(self.config.max_items_per_range, self.last_range_alignment_items);
        if (aligned_max >= self.config.min_items_per_range) return aligned_max;
        return clamped;
    }

    fn nextCandidate(self: *const AdaptiveRangeTuner, direction: ProbeDirection) ?usize {
        const candidate = switch (direction) {
            .grow => if (self.current_items_per_range >= self.config.max_items_per_range / 2)
                self.config.max_items_per_range
            else
                self.current_items_per_range * 2,
            .shrink => if (self.current_items_per_range <= self.config.min_items_per_range * 2)
                self.config.min_items_per_range
            else
                self.current_items_per_range / 2,
        };
        const normalized = self.normalizedItemsPerRange(candidate);
        const current = self.normalizedItemsPerRange(self.current_items_per_range);
        return if (normalized == current) null else normalized;
    }

    fn recordBest(self: *AdaptiveRangeTuner, items_per_range: usize, mean_ns: u64) void {
        if (self.best_mean_batch_duration_ns == 0 or mean_ns < self.best_mean_batch_duration_ns) {
            self.best_mean_batch_duration_ns = mean_ns;
            self.best_items_per_range = self.normalizedItemsPerRange(items_per_range);
        }
    }

    fn rejectProbe(self: *AdaptiveRangeTuner) void {
        self.failed_probe_count += 1;
        if (self.failed_probe_count >= self.config.settle_after_failed_probes) {
            self.settle();
            return;
        }

        self.startProbe(oppositeDirection(self.probe_direction));
    }

    fn resetSamples(self: *AdaptiveRangeTuner) void {
        self.sample_count = 0;
        self.sample_total_ns = 0;
        self.sampled_active_worker_threads = null;
    }
};

pub const JobFn = *const fn (*anyopaque, ParallelRange, WorkerId) void;

pub const ThreadSystem = struct {
    allocator: std.mem.Allocator,
    config: ThreadSystemConfig,
    shared: *Shared,
    workers: []WorkerRecord = &.{},
    adaptive_thread_count: AdaptiveThreadCount = .{},

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
            self.adaptive_thread_count.preferred_worker_threads = if (self.workers.len > 0) 1 else 0;
            spawned += 1;
        }

        log.debug(
            "ThreadSystem initialized: worker_threads={} min_parallel_items={} items_per_range={} stack_size={}",
            .{ self.workers.len, self.config.min_parallel_items, self.config.items_per_range, self.config.stack_size },
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
        const requested_items_per_range = @max(options.items_per_range orelse self.config.items_per_range, @as(usize, 1));
        const items_per_range = alignItemCount(requested_items_per_range, range_alignment_items);
        const min_parallel_items = options.min_parallel_items orelse self.config.min_parallel_items;
        const range_count = rangeCount(item_count, items_per_range);
        const max_worker_threads = @min(options.max_worker_threads orelse self.workers.len, self.workers.len);
        var stats = BatchStats{
            .item_count = item_count,
            .range_count = range_count,
            .items_per_range = items_per_range,
            .range_alignment_items = range_alignment_items,
            .available_worker_threads = self.workers.len,
            .active_worker_threads = max_worker_threads,
        };

        if (max_worker_threads == 0 or item_count < min_parallel_items or range_count <= 1) {
            stats.active_worker_threads = 0;
            const batch_start_ns = nowNs(self.shared.io);
            runInline(item_count, items_per_range, context, job_fn, &stats);
            const batch_end_ns = nowNs(self.shared.io);
            stats.batch_duration_ns = elapsedNs(batch_start_ns, batch_end_ns);
            return stats;
        }

        const adaptive_thread_count = options.adaptive_thread_count orelse &self.adaptive_thread_count;
        const active_worker_threads = adaptive_thread_count.chooseActiveWorkerThreads(
            max_worker_threads,
            range_count,
            options.adaptive,
        );
        if (active_worker_threads == 0) {
            stats.active_worker_threads = 0;
            const batch_start_ns = nowNs(self.shared.io);
            runInline(item_count, items_per_range, context, job_fn, &stats);
            const batch_end_ns = nowNs(self.shared.io);
            stats.batch_duration_ns = elapsedNs(batch_start_ns, batch_end_ns);
            if (options.adaptive) {
                adaptive_thread_count.record(stats);
            }
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
            .items_per_range = items_per_range,
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
        if (options.adaptive) {
            adaptive_thread_count.record(stats);
        }

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

            const range = rangeForIndex(self.batch.item_count, self.batch.items_per_range, range_index);
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
        const range = rangeForIndex(self.batch.item_count, self.batch.items_per_range, range_index);
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
    items_per_range: usize = 1,
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
    normalized.items_per_range = @max(normalized.items_per_range, @as(usize, 1));
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

pub fn rangeCount(item_count: usize, items_per_range: usize) usize {
    return (item_count + items_per_range - 1) / items_per_range;
}

pub fn alignItemCount(item_count: usize, alignment: usize) usize {
    std.debug.assert(alignment > 0);
    if (alignment == 1) return item_count;
    const remainder = item_count % alignment;
    if (remainder == 0) return item_count;
    return item_count + (alignment - remainder);
}

fn alignItemCountDown(item_count: usize, alignment: usize) usize {
    std.debug.assert(alignment > 0);
    if (alignment == 1) return item_count;
    return item_count - (item_count % alignment);
}

fn clampItemCount(value: usize, min_value: usize, max_value: usize) usize {
    return @min(@max(value, min_value), max_value);
}

fn normalizeTunerConfig(config: AdaptiveRangeTunerConfig) AdaptiveRangeTunerConfig {
    var normalized = config;
    normalized.min_items_per_range = @max(normalized.min_items_per_range, @as(usize, 1));
    normalized.max_items_per_range = @max(normalized.max_items_per_range, normalized.min_items_per_range);
    normalized.initial_items_per_range = clampItemCount(normalized.initial_items_per_range, normalized.min_items_per_range, normalized.max_items_per_range);
    normalized.sample_window = @max(normalized.sample_window, @as(usize, 1));
    normalized.improvement_threshold_percent = @min(normalized.improvement_threshold_percent, @as(u8, 100));
    normalized.item_count_reset_percent = @min(normalized.item_count_reset_percent, @as(u8, 100));
    normalized.settle_after_failed_probes = @max(normalized.settle_after_failed_probes, @as(usize, 1));
    normalized.retune_after_settled_windows = @max(normalized.retune_after_settled_windows, @as(usize, 1));
    return normalized;
}

fn oppositeDirection(direction: AdaptiveRangeTuner.ProbeDirection) AdaptiveRangeTuner.ProbeDirection {
    return switch (direction) {
        .grow => .shrink,
        .shrink => .grow,
    };
}

fn isMeaningfullyFaster(candidate_ns: u64, baseline_ns: u64, improvement_threshold_percent: u8) bool {
    if (baseline_ns == 0) return true;
    if (candidate_ns >= baseline_ns) return false;
    const improvement_ns: u64 = @intCast((@as(u128, baseline_ns) * improvement_threshold_percent) / 100);
    const required_ns = baseline_ns - improvement_ns;
    return candidate_ns <= required_ns;
}

fn itemCountShifted(previous: usize, current: usize, threshold_percent: u8) bool {
    if (previous == current) return false;
    const larger = @max(previous, current);
    const smaller = @min(previous, current);
    const delta = larger - smaller;
    const scaled_delta: u128 = @as(u128, delta) * 100;
    const threshold: u128 = @as(u128, previous) * threshold_percent;
    return scaled_delta >= threshold;
}

fn rangeForIndex(item_count: usize, items_per_range: usize, range_index: usize) ParallelRange {
    const start = range_index * items_per_range;
    return .{
        .index = range_index,
        .start = start,
        .end = @min(start + items_per_range, item_count),
    };
}

fn runInline(item_count: usize, items_per_range: usize, context: *anyopaque, job_fn: JobFn, stats: *BatchStats) void {
    for (0..rangeCount(item_count, items_per_range)) |range_index| {
        job_fn(context, rangeForIndex(item_count, items_per_range, range_index), WorkerId.main);
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

pub const AdaptiveThreadCount = struct {
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
        self: *AdaptiveThreadCount,
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
        if (self.last_active_worker_threads == 0) {
            if (self.last_batch_duration_ns < busy_batch_ns) return 0;
            return @min(range_target, @as(usize, 1));
        }

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

    fn record(self: *AdaptiveThreadCount, stats: BatchStats) void {
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

const RangeIndexContext = struct {
    starts: []usize,
    ends: []usize,
    items_per_range: usize,
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

fn recordRangeIndex(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const indices: *RangeIndexContext = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < indices.starts.len);
    std.debug.assert(range.start == range.index * indices.items_per_range);
    indices.starts[range.index] = range.start;
    indices.ends[range.index] = range.end;
}

test "inline parallel for covers every item exactly once" {
    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 8;
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 0,
        .min_parallel_items = 1,
        .items_per_range = 2,
    });
    defer threads.deinit();

    const stats = threads.parallelFor(hits.len, &context, markCoverage);

    try std.testing.expect(stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 4), stats.main_thread_ranges);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "inline parallel ranges expose stable range indices" {
    var starts = [_]usize{std.math.maxInt(usize)} ** 4;
    var ends = [_]usize{0} ** 4;
    var context = RangeIndexContext{
        .starts = starts[0..],
        .ends = ends[0..],
        .items_per_range = 3,
    };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 0,
        .min_parallel_items = 1,
        .items_per_range = 3,
    });
    defer threads.deinit();

    const stats = threads.parallelFor(10, &context, recordRangeIndex);

    try std.testing.expect(stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 4), stats.range_count);
    try std.testing.expectEqualSlices(usize, &.{ 0, 3, 6, 9 }, &starts);
    try std.testing.expectEqualSlices(usize, &.{ 3, 6, 9, 10 }, &ends);
}

test "forced inline batch does not train adaptive thread count" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 8;
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .min_parallel_items = 128,
        .items_per_range = 2,
    });
    defer threads.deinit();

    threads.adaptive_thread_count.record(.{
        .item_count = 1024,
        .range_count = 32,
        .items_per_range = 32,
        .available_worker_threads = 2,
        .active_worker_threads = 2,
        .worker_thread_ranges = 16,
        .batch_duration_ns = AdaptiveThreadCount.busy_batch_ns,
        .main_thread_wait_ns = 1,
        .worker_utilization = 0.5,
        .ran_inline = false,
    });

    const previous_duration_ns = threads.adaptive_thread_count.last_batch_duration_ns;
    const stats = threads.parallelFor(hits.len, &context, markCoverage);

    try std.testing.expect(stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 2), threads.adaptive_thread_count.last_active_worker_threads);
    try std.testing.expectEqual(previous_duration_ns, threads.adaptive_thread_count.last_batch_duration_ns);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "threaded parallel ranges expose stable range indices" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var starts = [_]usize{std.math.maxInt(usize)} ** 16;
    var ends = [_]usize{0} ** 16;
    var context = RangeIndexContext{
        .starts = starts[0..],
        .ends = ends[0..],
        .items_per_range = 8,
    };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .min_parallel_items = 1,
        .items_per_range = 8,
    });
    defer threads.deinit();

    const stats = threads.parallelForWithOptions(128, &context, recordRangeIndex, .{
        .adaptive = false,
    });

    try std.testing.expect(!stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 16), stats.range_count);
    for (0..16) |range_index| {
        try std.testing.expectEqual(range_index * 8, starts[range_index]);
        try std.testing.expectEqual(range_index * 8 + 8, ends[range_index]);
    }
}

test "worker thread parallel for covers every item exactly once" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 128;
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .min_parallel_items = 1,
        .items_per_range = 1,
    });
    defer threads.deinit();

    const stats = threads.parallelForWithOptions(hits.len, &context, markCoverage, .{
        .adaptive = false,
    });

    try std.testing.expect(!stats.ran_inline);
    try std.testing.expect(stats.main_thread_ranges > 0);
    try std.testing.expect(stats.worker_thread_ranges > 0);
    try std.testing.expect(context.worker_hits.load(.monotonic) > 0);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "parallel for options use provided adaptive thread count" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 128;
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .min_parallel_items = 1,
        .items_per_range = 1,
    });
    defer threads.deinit();

    var adaptive_thread_count = AdaptiveThreadCount{
        .last_batch_duration_ns = AdaptiveThreadCount.busy_batch_ns,
    };
    const stats = threads.parallelForWithOptions(hits.len, &context, markCoverage, .{
        .adaptive_thread_count = &adaptive_thread_count,
    });

    try std.testing.expect(!stats.ran_inline);
    try std.testing.expect(adaptive_thread_count.last_batch_duration_ns > 0);
    try std.testing.expectEqual(@as(u64, 0), threads.adaptive_thread_count.last_batch_duration_ns);
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
        .items_per_range = 2,
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
        .items_per_range = 1,
    });
    defer threads.deinit();

    const stats = threads.parallelForWithOptions(hits.len, &context, markCoverage, .{
        .items_per_range = 17,
        .range_alignment_items = 16,
        .max_worker_threads = 1,
        .adaptive = false,
    });

    try std.testing.expect(!stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 32), stats.items_per_range);
    try std.testing.expectEqual(@as(usize, 16), stats.range_alignment_items);
    try std.testing.expectEqual(@as(usize, 3), stats.available_worker_threads);
    try std.testing.expectEqual(@as(usize, 1), stats.active_worker_threads);
    try std.testing.expect(stats.worker_thread_ranges > 0);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "adaptive thread count increases active workers after busy utilized batch" {
    var adaptive_thread_count = AdaptiveThreadCount{};

    adaptive_thread_count.preferred_worker_threads = 1;
    adaptive_thread_count.record(.{
        .item_count = 1024,
        .range_count = 32,
        .items_per_range = 32,
        .available_worker_threads = 4,
        .active_worker_threads = 1,
        .worker_thread_ranges = 18,
        .batch_duration_ns = AdaptiveThreadCount.busy_batch_ns,
        .main_thread_wait_ns = 1,
        .worker_utilization = 0.56,
        .ran_inline = false,
    });

    try std.testing.expectEqual(@as(usize, 2), adaptive_thread_count.chooseActiveWorkerThreads(4, 32, true));
}

test "adaptive thread count waits for meaningful inline completion time" {
    var adaptive_thread_count = AdaptiveThreadCount{};

    try std.testing.expectEqual(@as(usize, 0), adaptive_thread_count.chooseActiveWorkerThreads(4, 32, true));

    adaptive_thread_count.record(.{
        .item_count = 1024,
        .range_count = 32,
        .items_per_range = 32,
        .available_worker_threads = 4,
        .active_worker_threads = 0,
        .batch_duration_ns = AdaptiveThreadCount.idle_batch_ns,
        .ran_inline = true,
    });
    try std.testing.expectEqual(@as(usize, 0), adaptive_thread_count.chooseActiveWorkerThreads(4, 32, true));

    adaptive_thread_count.record(.{
        .item_count = 1024,
        .range_count = 32,
        .items_per_range = 32,
        .available_worker_threads = 4,
        .active_worker_threads = 0,
        .batch_duration_ns = AdaptiveThreadCount.busy_batch_ns,
        .ran_inline = true,
    });
    try std.testing.expectEqual(@as(usize, 1), adaptive_thread_count.chooseActiveWorkerThreads(4, 32, true));
}

test "adaptive thread count reduces active workers after cheap underutilized batch" {
    var adaptive_thread_count = AdaptiveThreadCount{ .preferred_worker_threads = 3 };
    adaptive_thread_count.record(.{
        .item_count = 256,
        .range_count = 8,
        .items_per_range = 32,
        .available_worker_threads = 4,
        .active_worker_threads = 3,
        .batch_duration_ns = AdaptiveThreadCount.idle_batch_ns,
        .worker_utilization = 0.05,
        .ran_inline = false,
    });

    try std.testing.expectEqual(@as(usize, 2), adaptive_thread_count.chooseActiveWorkerThreads(4, 8, true));
    try std.testing.expectEqual(@as(usize, 4), adaptive_thread_count.chooseActiveWorkerThreads(4, 8, false));
}

test "adaptive range tuner aligns and clamps selected items_per_range" {
    var tuner = AdaptiveRangeTuner.init(.{
        .initial_items_per_range = 17,
        .min_items_per_range = 16,
        .max_items_per_range = 256,
    });

    try std.testing.expectEqual(@as(usize, 32), tuner.itemsPerRange(1024, 16));

    const report = tuner.report();
    try std.testing.expectEqual(@as(usize, 17), report.current_items_per_range);
    try std.testing.expectEqual(@as(usize, 17), report.best_items_per_range);
}

test "adaptive range tuner commits faster candidate" {
    var tuner = AdaptiveRangeTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .max_items_per_range = 256,
        .sample_window = 1,
        .improvement_threshold_percent = 5,
    });

    try std.testing.expectEqual(@as(usize, 64), tuner.itemsPerRange(1024, 16));
    tuner.record(tunerTestBatch(1024, 64, 1000));
    try std.testing.expectEqual(AdaptiveRangePhase.probing, tuner.report().phase);
    try std.testing.expectEqual(@as(?usize, 128), tuner.report().candidate_items_per_range);
    try std.testing.expectEqual(@as(usize, 128), tuner.itemsPerRange(1024, 16));

    tuner.record(tunerTestBatch(1024, 128, 800));

    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveRangePhase.probing, report.phase);
    try std.testing.expectEqual(@as(usize, 128), report.current_items_per_range);
    try std.testing.expectEqual(@as(usize, 128), report.best_items_per_range);
    try std.testing.expectEqual(@as(?usize, 256), report.candidate_items_per_range);
    try std.testing.expectEqual(@as(u64, 800), report.best_mean_batch_duration_ns);
}

test "adaptive range tuner settles after rejected probes" {
    var tuner = AdaptiveRangeTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .max_items_per_range = 256,
        .sample_window = 1,
        .improvement_threshold_percent = 5,
        .settle_after_failed_probes = 2,
    });

    _ = tuner.itemsPerRange(1024, 16);
    tuner.record(tunerTestBatch(1024, 64, 1000));
    try std.testing.expectEqual(@as(usize, 128), tuner.itemsPerRange(1024, 16));

    tuner.record(tunerTestBatch(1024, 128, 1200));
    try std.testing.expectEqual(AdaptiveRangePhase.probing, tuner.report().phase);
    try std.testing.expectEqual(@as(?usize, 32), tuner.report().candidate_items_per_range);
    try std.testing.expectEqual(@as(usize, 32), tuner.itemsPerRange(1024, 16));
    tuner.record(tunerTestBatch(1024, 32, 1200));

    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveRangePhase.settled, report.phase);
    try std.testing.expectEqual(@as(usize, 64), report.current_items_per_range);
    try std.testing.expectEqual(@as(usize, 64), report.best_items_per_range);
    try std.testing.expectEqual(@as(?usize, null), report.candidate_items_per_range);
    try std.testing.expect(tuner.isSettled());
}

test "adaptive range tuner resets sample window after item count shift" {
    var tuner = AdaptiveRangeTuner.init(.{
        .initial_items_per_range = 64,
        .sample_window = 4,
        .item_count_reset_percent = 25,
    });

    _ = tuner.itemsPerRange(1024, 16);
    tuner.record(tunerTestBatch(1024, 64, 1000));
    try std.testing.expectEqual(@as(usize, 1), tuner.report().sample_count);

    _ = tuner.itemsPerRange(2048, 16);
    try std.testing.expectEqual(@as(usize, 0), tuner.report().sample_count);
    try std.testing.expectEqual(AdaptiveRangePhase.learning, tuner.report().phase);
}

test "adaptive range tuner clears stale best after item count shift" {
    var tuner = AdaptiveRangeTuner.init(.{
        .initial_items_per_range = 64,
        .sample_window = 1,
        .item_count_reset_percent = 25,
    });

    _ = tuner.itemsPerRange(1024, 16);
    tuner.record(tunerTestBatch(1024, 64, 1000));
    try std.testing.expect(tuner.report().best_mean_batch_duration_ns > 0);

    _ = tuner.itemsPerRange(2048, 16);
    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveRangePhase.learning, report.phase);
    try std.testing.expectEqual(@as(u64, 0), report.best_mean_batch_duration_ns);
    try std.testing.expectEqual(@as(usize, 64), report.best_items_per_range);
}

test "adaptive range tuner rejects probe that collapses to inline" {
    var tuner = AdaptiveRangeTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .max_items_per_range = 256,
        .sample_window = 1,
        .settle_after_failed_probes = 1,
    });

    _ = tuner.itemsPerRange(128, 16);
    tuner.record(tunerTestBatch(128, 64, 1000));
    try std.testing.expectEqual(AdaptiveRangePhase.probing, tuner.report().phase);
    try std.testing.expectEqual(@as(usize, 128), tuner.itemsPerRange(128, 16));

    tuner.record(.{
        .item_count = 128,
        .range_count = 1,
        .items_per_range = 128,
        .range_alignment_items = 16,
        .available_worker_threads = 1,
        .active_worker_threads = 0,
        .main_thread_ranges = 1,
        .ran_inline = true,
    });

    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveRangePhase.settled, report.phase);
    try std.testing.expectEqual(@as(usize, 64), report.current_items_per_range);
    try std.testing.expectEqual(@as(?usize, null), report.candidate_items_per_range);
}

test "adaptive range tuner resets sample window when worker count changes" {
    var tuner = AdaptiveRangeTuner.init(.{
        .initial_items_per_range = 64,
        .sample_window = 4,
    });

    _ = tuner.itemsPerRange(1024, 16);
    tuner.record(tunerTestBatchWithWorkers(1024, 64, 1000, 1));
    try std.testing.expectEqual(@as(usize, 1), tuner.report().sample_count);

    tuner.record(tunerTestBatchWithWorkers(1024, 64, 1000, 2));
    try std.testing.expectEqual(@as(usize, 1), tuner.report().sample_count);
}

test "adaptive range tuner keeps aligned items_per_range within max when possible" {
    var tuner = AdaptiveRangeTuner.init(.{
        .initial_items_per_range = 90,
        .min_items_per_range = 1,
        .max_items_per_range = 100,
    });

    try std.testing.expectEqual(@as(usize, 64), tuner.itemsPerRange(1024, 64));
}

test "adaptive range tuner reopens probing after settled cooldown" {
    var tuner = AdaptiveRangeTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .max_items_per_range = 256,
        .sample_window = 1,
        .settle_after_failed_probes = 1,
        .retune_after_settled_windows = 2,
    });

    _ = tuner.itemsPerRange(1024, 16);
    tuner.record(tunerTestBatch(1024, 64, 1000));
    try std.testing.expectEqual(@as(usize, 128), tuner.itemsPerRange(1024, 16));
    tuner.record(tunerTestBatch(1024, 128, 1200));
    try std.testing.expect(tuner.isSettled());

    try std.testing.expectEqual(@as(usize, 64), tuner.itemsPerRange(1024, 16));
    tuner.record(tunerTestBatch(1024, 64, 1000));
    try std.testing.expect(tuner.isSettled());

    try std.testing.expectEqual(@as(usize, 64), tuner.itemsPerRange(1024, 16));
    tuner.record(tunerTestBatch(1024, 64, 1000));

    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveRangePhase.probing, report.phase);
    try std.testing.expectEqual(@as(?usize, 128), report.candidate_items_per_range);
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
        .items_per_range = 2,
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

fn tunerTestBatch(item_count: usize, items_per_range: usize, duration_ns: u64) BatchStats {
    return tunerTestBatchWithWorkers(item_count, items_per_range, duration_ns, 1);
}

fn tunerTestBatchWithWorkers(item_count: usize, items_per_range: usize, duration_ns: u64, active_worker_threads: usize) BatchStats {
    return .{
        .item_count = item_count,
        .range_count = rangeCount(item_count, items_per_range),
        .items_per_range = items_per_range,
        .available_worker_threads = active_worker_threads,
        .active_worker_threads = active_worker_threads,
        .main_thread_ranges = 1,
        .worker_thread_ranges = 1,
        .worker_utilization = 0.5,
        .batch_duration_ns = duration_ns,
        .ran_inline = false,
    };
}
