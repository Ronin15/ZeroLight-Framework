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
    /// Number of items assigned to each range before another participant takes
    /// more work.
    items_per_range: usize = 64,
};

pub const ParallelForOptions = struct {
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    range_alignment_items: usize = 1,
    adaptive: bool = true,
    adaptive_tuner: ?*AdaptiveWorkTuner = null,
    selected_profile: ?AdaptiveWorkProfile = null,
};

pub const AdaptiveWorkProfile = struct {
    /// `0` means the batch runs inline on the main thread.
    worker_threads: usize = 0,
    items_per_range: usize = (ThreadSystemConfig{}).items_per_range,
};

pub const AdaptiveWorkTunerConfig = struct {
    initial_range_items: usize = (ThreadSystemConfig{}).items_per_range,
    smallest_range_items: usize = 1,
    largest_range_items: usize = std.math.maxInt(usize),
    sample_window: usize = 3,
    improvement_threshold_percent: u8 = 1,
    threaded_commit_threshold_percent: u8 = 5,
    item_count_reset_percent: u8 = 25,
    threaded_batch_ns: u64 = 50_000,
    settle_after_failed_profiles: usize = 2,
    retune_after_settled_windows: usize = 120,
    min_ranges_per_participant: usize = 1,
    max_ranges_per_participant: usize = 16,
};

pub const AdaptiveWorkPhase = enum {
    learning,
    probing,
    settled,
};

const default_participant_overhead_ns: f64 = 1_000;
const min_participant_overhead_ns: f64 = 100;
const default_range_overhead_ns: f64 = 1_000;

pub const AdaptiveWorkRequest = struct {
    item_count: usize,
    available_worker_threads: usize,
    max_worker_threads: usize,
    fallback_items_per_range: usize,
    range_alignment_items: usize,
};

pub const AdaptiveWorkReport = struct {
    phase: AdaptiveWorkPhase = .learning,
    initial_profile: AdaptiveWorkProfile = .{},
    current_profile: AdaptiveWorkProfile = .{},
    best_profile: AdaptiveWorkProfile = .{},
    candidate_profile: ?AdaptiveWorkProfile = null,
    sample_count: usize = 0,
    sample_window: usize = 1,
    failed_profile_count: usize = 0,
    settle_after_failed_profiles: usize = 1,
    settled_window_count: usize = 0,
    retune_after_settled_windows: usize = 1,
    best_mean_batch_duration_ns: u64 = 0,
    baseline_mean_batch_duration_ns: u64 = 0,
    has_threaded_profile: bool = false,
    probing: bool = false,
};

pub const AdaptiveWorkTuner = struct {
    config: AdaptiveWorkTunerConfig,
    phase: AdaptiveWorkPhase = .learning,
    initial_profile: AdaptiveWorkProfile,
    current_profile: AdaptiveWorkProfile,
    best_profile: AdaptiveWorkProfile,
    candidate_profile: ?AdaptiveWorkProfile = null,
    best_mean_batch_duration_ns: u64 = 0,
    baseline_mean_batch_duration_ns: u64 = 0,
    has_threaded_profile: bool = false,
    sample_count: usize = 0,
    sample_total_ns: u128 = 0,
    failed_profile_count: usize = 0,
    settled_window_count: usize = 0,
    inline_probe_cooldown_windows: usize = 0,
    last_item_count: usize = 0,
    last_range_alignment_items: usize = 1,
    last_request: ?AdaptiveWorkRequest = null,
    sampled_profile: ?AdaptiveWorkProfile = null,
    model_work_ns_per_item: f64 = 0,
    model_participant_overhead_ns: f64 = 0,
    model_range_overhead_ns: f64 = 0,
    model_imbalance_work_ns: f64 = 0,
    last_predicted_profile: ?AdaptiveWorkProfile = null,

    pub fn init(config: AdaptiveWorkTunerConfig) AdaptiveWorkTuner {
        const normalized = normalizeWorkTunerConfig(config);
        const initial = clampItemCount(normalized.initial_range_items, normalized.smallest_range_items, normalized.largest_range_items);
        const profile = AdaptiveWorkProfile{
            .worker_threads = 1,
            .items_per_range = initial,
        };
        return .{
            .config = normalized,
            .initial_profile = profile,
            .current_profile = profile,
            .best_profile = profile,
        };
    }

    pub fn selectProfile(self: *AdaptiveWorkTuner, request: AdaptiveWorkRequest) AdaptiveWorkProfile {
        const normalized_request = self.normalizeRequest(request);
        self.last_request = normalized_request;
        self.last_range_alignment_items = normalized_request.range_alignment_items;
        if (self.last_item_count != 0 and itemCountShifted(self.last_item_count, normalized_request.item_count, self.config.item_count_reset_percent)) {
            self.resetForLearning();
        }
        self.last_item_count = normalized_request.item_count;

        const selected = switch (self.phase) {
            .learning => if (self.has_threaded_profile) self.current_profile else inlineProfile(normalized_request),
            .settled => if (self.has_threaded_profile) self.current_profile else inlineProfile(normalized_request),
            .probing => self.candidate_profile orelse self.current_profile,
        };
        return self.normalizedProfile(selected, normalized_request);
    }

    pub fn record(self: *AdaptiveWorkTuner, stats: BatchStats) void {
        if (stats.item_count == 0) return;
        if (stats.batch_duration_ns == 0) return;

        const profile = AdaptiveWorkProfile{
            .worker_threads = stats.active_worker_threads,
            .items_per_range = stats.items_per_range,
        };
        if (self.sampled_profile) |sampled| {
            if (!profilesEqual(sampled, profile)) {
                self.resetSamples();
            }
        }
        self.sampled_profile = profile;

        self.sample_count += 1;
        self.sample_total_ns += stats.batch_duration_ns;
        self.updateCostModel(stats);
        if (self.sample_count < self.config.sample_window) return;

        const sample_mean_ns: u64 = @intCast(self.sample_total_ns / self.sample_count);
        switch (self.phase) {
            .learning => self.finishLearningWindow(sample_mean_ns),
            .probing => self.finishProfileWindow(sample_mean_ns),
            .settled => self.finishSettledWindow(sample_mean_ns),
        }
        self.resetSamples();
    }

    pub fn report(self: *const AdaptiveWorkTuner) AdaptiveWorkReport {
        return .{
            .phase = self.phase,
            .initial_profile = self.initial_profile,
            .current_profile = self.current_profile,
            .best_profile = self.best_profile,
            .candidate_profile = self.candidate_profile,
            .sample_count = self.sample_count,
            .sample_window = self.config.sample_window,
            .failed_profile_count = self.failed_profile_count,
            .settle_after_failed_profiles = self.config.settle_after_failed_profiles,
            .settled_window_count = self.settled_window_count,
            .retune_after_settled_windows = self.config.retune_after_settled_windows,
            .best_mean_batch_duration_ns = self.best_mean_batch_duration_ns,
            .baseline_mean_batch_duration_ns = self.baseline_mean_batch_duration_ns,
            .has_threaded_profile = self.has_threaded_profile,
            .probing = self.phase == .probing,
        };
    }

    pub fn isSettled(self: *const AdaptiveWorkTuner) bool {
        return self.phase == .settled;
    }

    pub fn settleWarmupLimit(self: *const AdaptiveWorkTuner, request: AdaptiveWorkRequest) usize {
        const normalized_request = self.normalizeRequest(request);
        const max_range = self.effectiveMaxItemsPerRange(normalized_request);
        const alignment = @max(normalized_request.range_alignment_items, @as(usize, 1));
        const range_span_steps = @max(@as(usize, 1), (max_range - self.config.smallest_range_items) / alignment);
        const range_windows = saturatingMul(ceilLog2(range_span_steps) + 2, @as(usize, 2));
        const windows = saturatingAdd(@as(usize, 3), range_windows);
        return saturatingMul(windows, self.config.sample_window);
    }

    fn finishLearningWindow(self: *AdaptiveWorkTuner, sample_mean_ns: u64) void {
        const profile = self.sampled_profile orelse self.current_profile;
        self.baseline_mean_batch_duration_ns = sample_mean_ns;
        if (profile.worker_threads == 0 and sample_mean_ns < self.config.threaded_batch_ns) {
            self.settle();
            return;
        }
        self.recordBest(profile, sample_mean_ns);
        self.startPredictedProbe(profile, sample_mean_ns);
    }

    fn finishProfileWindow(self: *AdaptiveWorkTuner, sample_mean_ns: u64) void {
        const candidate = self.candidate_profile orelse {
            self.settle();
            return;
        };

        const commit_candidate = self.shouldCommitCandidate(candidate, sample_mean_ns);
        if (commit_candidate) {
            self.recordBest(candidate, sample_mean_ns);
            self.current_profile = candidate;
            self.baseline_mean_batch_duration_ns = sample_mean_ns;
            self.failed_profile_count = 0;
            self.inline_probe_cooldown_windows = 0;
            self.startPredictedProbe(candidate, sample_mean_ns);
            return;
        }

        self.failed_profile_count += 1;
        if (!self.has_threaded_profile) {
            self.inline_probe_cooldown_windows = self.config.retune_after_settled_windows;
            self.settle();
            return;
        }
        if (self.failed_profile_count >= self.config.settle_after_failed_profiles) {
            self.settle();
            return;
        }
        self.current_profile = self.best_profile;
        self.baseline_mean_batch_duration_ns = self.best_mean_batch_duration_ns;
        self.startPredictedProbe(self.best_profile, self.best_mean_batch_duration_ns);
    }

    fn finishSettledWindow(self: *AdaptiveWorkTuner, sample_mean_ns: u64) void {
        const profile = self.sampled_profile orelse self.current_profile;
        self.baseline_mean_batch_duration_ns = sample_mean_ns;
        self.settled_window_count += 1;

        if (profile.worker_threads == 0) {
            if (sample_mean_ns >= self.config.threaded_batch_ns) {
                if (self.inline_probe_cooldown_windows > 0) {
                    self.inline_probe_cooldown_windows -= 1;
                    return;
                }
                self.startPredictedProbe(profile, sample_mean_ns);
            }
            return;
        }
        if (sample_mean_ns >= self.config.threaded_batch_ns and !self.has_threaded_profile) {
            self.startPredictedProbe(profile, sample_mean_ns);
            return;
        }
        if (self.settled_window_count >= self.config.retune_after_settled_windows) {
            self.startPredictedProbe(profile, sample_mean_ns);
            return;
        }
        self.recordBest(profile, sample_mean_ns);
    }

    fn startPredictedProbe(self: *AdaptiveWorkTuner, baseline_profile: AdaptiveWorkProfile, baseline_mean_ns: u64) void {
        const request = self.last_request orelse {
            self.settle();
            return;
        };
        const normalized_baseline = self.normalizedProfile(baseline_profile, request);
        if (normalized_baseline.worker_threads > 0) {
            self.current_profile = normalized_baseline;
            self.recordBest(normalized_baseline, baseline_mean_ns);
        }
        self.baseline_mean_batch_duration_ns = baseline_mean_ns;

        const predicted = self.predictProfile(request);
        self.last_predicted_profile = predicted;
        if (predicted.worker_threads == 0 or (self.has_threaded_profile and profilesEqual(predicted, normalized_baseline))) {
            self.settle();
            return;
        }

        self.candidate_profile = predicted;
        self.phase = .probing;
    }

    fn predictProfile(self: *const AdaptiveWorkTuner, request: AdaptiveWorkRequest) AdaptiveWorkProfile {
        if (request.max_worker_threads == 0) {
            return self.normalizedProfile(.{
                .worker_threads = 0,
                .items_per_range = request.fallback_items_per_range,
            }, request);
        }

        const item_count_f: f64 = @floatFromInt(request.item_count);
        const work_ns_per_item = if (self.model_work_ns_per_item > 0)
            self.model_work_ns_per_item
        else if (self.baseline_mean_batch_duration_ns > 0)
            @as(f64, @floatFromInt(self.baseline_mean_batch_duration_ns)) / item_count_f
        else
            @as(f64, @floatFromInt(self.config.threaded_batch_ns)) / item_count_f;
        const estimated_work_ns = @max(work_ns_per_item * item_count_f, 1);
        if (estimated_work_ns < @as(f64, @floatFromInt(self.config.threaded_batch_ns))) {
            return self.normalizedProfile(.{
                .worker_threads = 0,
                .items_per_range = request.fallback_items_per_range,
            }, request);
        }

        const participant_overhead_ns = @max(self.model_participant_overhead_ns, default_participant_overhead_ns);
        const ideal_participants_f = @sqrt(estimated_work_ns / participant_overhead_ns);
        const max_participants = request.max_worker_threads + 1;
        const predicted_participants = clampUsize(
            roundedUsize(ideal_participants_f),
            1,
            max_participants,
        );
        const predicted_threaded_ns = estimated_work_ns / @as(f64, @floatFromInt(predicted_participants)) +
            participant_overhead_ns * @as(f64, @floatFromInt(predicted_participants - 1));
        if (predicted_participants <= 1 or predicted_threaded_ns >= estimated_work_ns) {
            return self.normalizedProfile(.{
                .worker_threads = 0,
                .items_per_range = request.fallback_items_per_range,
            }, request);
        }

        const range_overhead_ns = @max(self.model_range_overhead_ns, default_range_overhead_ns);
        const work_per_participant_ns = estimated_work_ns / @as(f64, @floatFromInt(predicted_participants));
        const ranges_per_participant_f = if (self.model_imbalance_work_ns > 0)
            @sqrt(self.model_imbalance_work_ns / (range_overhead_ns * @as(f64, @floatFromInt(predicted_participants))))
        else
            @sqrt(work_per_participant_ns / range_overhead_ns);
        const ranges_per_participant = clampUsize(
            roundedUsize(ranges_per_participant_f),
            self.config.min_ranges_per_participant,
            self.config.max_ranges_per_participant,
        );
        const target_ranges = saturatingMul(predicted_participants, ranges_per_participant);
        const predicted_items_per_range = self.normalizedItemsPerRange(
            targetRangeSizeForRangeCount(request.item_count, target_ranges),
            request.range_alignment_items,
        );
        const worker_threads = maxUsefulWorkersForRange(
            request.item_count,
            predicted_items_per_range,
            request.max_worker_threads,
        );
        if (worker_threads == 0) {
            return self.normalizedProfile(.{
                .worker_threads = 0,
                .items_per_range = request.fallback_items_per_range,
            }, request);
        }

        if (self.model_participant_overhead_ns > 0) {
            const actual_participants = worker_threads + 1;
            const actual_range_count = rangeCount(request.item_count, predicted_items_per_range);
            const actual_ranges_per_participant = @max(@as(usize, 1), ceilDiv(actual_range_count, actual_participants));
            const predicted_imbalance_ns = if (self.model_imbalance_work_ns > 0)
                self.model_imbalance_work_ns / @as(f64, @floatFromInt(actual_ranges_per_participant))
            else
                0;
            const full_threaded_ns = estimated_work_ns / @as(f64, @floatFromInt(actual_participants)) +
                participant_overhead_ns * @as(f64, @floatFromInt(worker_threads)) +
                range_overhead_ns * @as(f64, @floatFromInt(actual_range_count)) +
                predicted_imbalance_ns;
            if (full_threaded_ns >= estimated_work_ns) {
                return self.normalizedProfile(.{
                    .worker_threads = 0,
                    .items_per_range = request.fallback_items_per_range,
                }, request);
            }
        }

        return self.normalizedProfile(.{
            .worker_threads = worker_threads,
            .items_per_range = predicted_items_per_range,
        }, request);
    }

    fn updateCostModel(self: *AdaptiveWorkTuner, stats: BatchStats) void {
        const duration_ns: f64 = @floatFromInt(stats.batch_duration_ns);
        const item_count_f: f64 = @floatFromInt(stats.item_count);
        if (item_count_f <= 0 or duration_ns <= 0) return;

        const participants: usize = stats.active_worker_threads + 1;
        if (stats.active_worker_threads == 0 or stats.ran_inline) {
            self.model_work_ns_per_item = ewma(self.model_work_ns_per_item, duration_ns / item_count_f, 0.35);
            return;
        }

        if (self.model_work_ns_per_item == 0) {
            self.model_work_ns_per_item = duration_ns * @as(f64, @floatFromInt(participants)) / item_count_f;
        }

        const estimated_parallel_work_ns = (self.model_work_ns_per_item * item_count_f) /
            @as(f64, @floatFromInt(participants));
        const overhead_ns = @max(duration_ns - estimated_parallel_work_ns, 0);
        const main_thread_wait_ns: f64 = @floatFromInt(stats.main_thread_wait_ns);
        const non_tail_overhead_ns = @max(overhead_ns - main_thread_wait_ns, 0);
        if (stats.range_count > 0) {
            self.model_range_overhead_ns = ewma(
                self.model_range_overhead_ns,
                non_tail_overhead_ns / @as(f64, @floatFromInt(stats.range_count)),
                0.25,
            );
        }

        const participant_observed = non_tail_overhead_ns / @as(f64, @floatFromInt(@max(participants, @as(usize, 1))));
        self.model_participant_overhead_ns = ewma(
            self.model_participant_overhead_ns,
            @max(participant_observed, min_participant_overhead_ns),
            0.25,
        );

        if (stats.range_count > 0 and stats.main_thread_wait_ns > 0) {
            const ranges_per_participant = @max(@as(usize, 1), ceilDiv(stats.range_count, participants));
            self.model_imbalance_work_ns = ewma(
                self.model_imbalance_work_ns,
                main_thread_wait_ns * @as(f64, @floatFromInt(ranges_per_participant)),
                0.25,
            );
        }

        const threaded_work_per_item = duration_ns * @as(f64, @floatFromInt(participants)) / item_count_f;
        if (threaded_work_per_item < self.model_work_ns_per_item * 1.25) {
            self.model_work_ns_per_item = ewma(self.model_work_ns_per_item, threaded_work_per_item, 0.10);
        }
    }

    fn settle(self: *AdaptiveWorkTuner) void {
        self.phase = .settled;
        self.current_profile = self.best_profile;
        self.candidate_profile = null;
        self.last_predicted_profile = null;
        self.failed_profile_count = 0;
        self.settled_window_count = 0;
    }

    fn resetForLearning(self: *AdaptiveWorkTuner) void {
        self.phase = .learning;
        self.current_profile = self.initial_profile;
        self.best_profile = self.initial_profile;
        self.candidate_profile = null;
        self.last_predicted_profile = null;
        self.has_threaded_profile = false;
        self.best_mean_batch_duration_ns = 0;
        self.baseline_mean_batch_duration_ns = 0;
        self.failed_profile_count = 0;
        self.settled_window_count = 0;
        self.inline_probe_cooldown_windows = 0;
        self.resetSamples();
    }

    fn normalizeRequest(self: *const AdaptiveWorkTuner, request: AdaptiveWorkRequest) AdaptiveWorkRequest {
        const alignment = @max(request.range_alignment_items, @as(usize, 1));
        const max_workers = @min(request.max_worker_threads, request.available_worker_threads);
        return .{
            .item_count = request.item_count,
            .available_worker_threads = request.available_worker_threads,
            .max_worker_threads = max_workers,
            .fallback_items_per_range = self.normalizedItemsPerRange(request.fallback_items_per_range, alignment),
            .range_alignment_items = alignment,
        };
    }

    fn normalizedProfile(self: *const AdaptiveWorkTuner, profile: AdaptiveWorkProfile, request: AdaptiveWorkRequest) AdaptiveWorkProfile {
        const items_per_range = self.normalizedItemsPerRange(profile.items_per_range, request.range_alignment_items);
        const ranges = rangeCount(request.item_count, items_per_range);
        const range_limited_workers = if (ranges > 1) @min(request.max_worker_threads, ranges - 1) else 0;
        const workers = @min(profile.worker_threads, range_limited_workers);
        return .{
            .worker_threads = workers,
            .items_per_range = items_per_range,
        };
    }

    fn normalizedItemsPerRange(self: *const AdaptiveWorkTuner, items_per_range: usize, alignment: usize) usize {
        const clamped = clampItemCount(@max(items_per_range, @as(usize, 1)), self.config.smallest_range_items, self.config.largest_range_items);
        const aligned_up = alignItemCount(clamped, alignment);
        if (aligned_up <= self.config.largest_range_items) return aligned_up;

        const aligned_max = alignItemCountDown(self.config.largest_range_items, alignment);
        if (aligned_max >= self.config.smallest_range_items) return aligned_max;
        return clamped;
    }

    fn effectiveMaxItemsPerRange(self: *const AdaptiveWorkTuner, request: AdaptiveWorkRequest) usize {
        if (request.item_count == 0) return self.config.smallest_range_items;
        return @max(
            self.config.smallest_range_items,
            @min(self.config.largest_range_items, request.item_count),
        );
    }

    fn recordBest(self: *AdaptiveWorkTuner, profile: AdaptiveWorkProfile, mean_ns: u64) void {
        if (profile.worker_threads == 0) return;
        if (!self.has_threaded_profile and self.baseline_mean_batch_duration_ns == mean_ns) {
            self.best_mean_batch_duration_ns = mean_ns;
            self.best_profile = profile;
            self.has_threaded_profile = true;
            return;
        }
        if (self.shouldCommitCandidate(profile, mean_ns)) {
            self.best_mean_batch_duration_ns = mean_ns;
            self.best_profile = profile;
            self.has_threaded_profile = true;
        }
    }

    fn shouldCommitCandidate(self: *const AdaptiveWorkTuner, candidate: AdaptiveWorkProfile, mean_ns: u64) bool {
        if (candidate.worker_threads == 0) return false;
        if (!self.has_threaded_profile) {
            return isMeaningfullyFaster(mean_ns, self.baseline_mean_batch_duration_ns, self.config.threaded_commit_threshold_percent);
        }
        const best_ns = self.best_mean_batch_duration_ns;
        if (best_ns == 0) return true;
        return isMeaningfullyFaster(mean_ns, best_ns, self.config.improvement_threshold_percent);
    }

    fn resetSamples(self: *AdaptiveWorkTuner) void {
        self.sample_count = 0;
        self.sample_total_ns = 0;
        self.sampled_profile = null;
    }
};

pub const JobFn = *const fn (*anyopaque, ParallelRange, WorkerId) void;

pub const ThreadSystem = struct {
    allocator: std.mem.Allocator,
    config: ThreadSystemConfig,
    shared: *Shared,
    workers: []WorkerRecord = &.{},
    adaptive_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),

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
            spawned += 1;
        }

        log.debug(
            "ThreadSystem initialized: worker_threads={} items_per_range={} stack_size={}",
            .{ self.workers.len, self.config.items_per_range, self.config.stack_size },
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
        const max_worker_threads = @min(options.max_worker_threads orelse self.workers.len, self.workers.len);
        const requested_items_per_range = @max(options.items_per_range orelse self.config.items_per_range, @as(usize, 1));
        const adaptive_tuner = if (options.adaptive and (max_worker_threads > 0 or options.selected_profile != null))
            if (options.selected_profile != null)
                options.adaptive_tuner
            else if (options.items_per_range == null)
                options.adaptive_tuner orelse &self.adaptive_tuner
            else
                null
        else
            null;
        const profile = options.selected_profile orelse if (adaptive_tuner) |tuner|
            tuner.selectProfile(.{
                .item_count = item_count,
                .available_worker_threads = self.workers.len,
                .max_worker_threads = max_worker_threads,
                .fallback_items_per_range = requested_items_per_range,
                .range_alignment_items = range_alignment_items,
            })
        else
            AdaptiveWorkProfile{
                .worker_threads = max_worker_threads,
                .items_per_range = requested_items_per_range,
            };
        const selected_items_per_range = alignItemCount(@max(profile.items_per_range, @as(usize, 1)), range_alignment_items);
        const selected_range_count = rangeCount(item_count, selected_items_per_range);
        const active_worker_threads = if (selected_range_count <= 1)
            @as(usize, 0)
        else
            @min(profile.worker_threads, @min(max_worker_threads, selected_range_count - 1));
        const items_per_range = if (active_worker_threads == 0 and adaptive_tuner != null and profile.worker_threads == 0)
            item_count
        else
            selected_items_per_range;
        const range_count = rangeCount(item_count, items_per_range);
        var stats = BatchStats{
            .item_count = item_count,
            .range_count = range_count,
            .items_per_range = items_per_range,
            .range_alignment_items = range_alignment_items,
            .available_worker_threads = self.workers.len,
            .active_worker_threads = active_worker_threads,
        };

        if (active_worker_threads == 0) {
            stats.active_worker_threads = 0;
            const batch_start_ns = nowNs(self.shared.io);
            runInline(item_count, items_per_range, context, job_fn, &stats);
            const batch_end_ns = nowNs(self.shared.io);
            stats.batch_duration_ns = elapsedNs(batch_start_ns, batch_end_ns);
            if (adaptive_tuner) |tuner| {
                tuner.record(stats);
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
        if (adaptive_tuner) |tuner| {
            tuner.record(stats);
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

fn ceilDiv(numerator: usize, denominator: usize) usize {
    std.debug.assert(denominator > 0);
    return (numerator + denominator - 1) / denominator;
}

fn saturatingMul(left: usize, right: usize) usize {
    if (right != 0 and left > std.math.maxInt(usize) / right) return std.math.maxInt(usize);
    return left * right;
}

fn saturatingAdd(left: usize, right: usize) usize {
    if (left > std.math.maxInt(usize) - right) return std.math.maxInt(usize);
    return left + right;
}

fn ceilLog2(value: usize) usize {
    if (value <= 1) return 0;
    var shifted = value - 1;
    var result: usize = 0;
    while (shifted > 0) : (shifted >>= 1) {
        result += 1;
    }
    return result;
}

fn targetRangeSizeForRangeCount(item_count: usize, target_ranges: usize) usize {
    return @max(@as(usize, 1), ceilDiv(item_count, @max(target_ranges, @as(usize, 1))));
}

fn clampUsize(value: usize, minimum: usize, maximum: usize) usize {
    return @min(@max(value, minimum), maximum);
}

fn roundedUsize(value: f64) usize {
    if (value <= 1) return 1;
    const max_f: f64 = @floatFromInt(std.math.maxInt(usize));
    if (value >= max_f) return std.math.maxInt(usize);
    return @intFromFloat(@floor(value + 0.5));
}

fn ewma(current: f64, observed: f64, alpha: f64) f64 {
    if (current <= 0) return observed;
    return current * (1.0 - alpha) + observed * alpha;
}

fn maxUsefulWorkersForRange(item_count: usize, items_per_range: usize, max_worker_threads: usize) usize {
    const ranges = rangeCount(item_count, @max(items_per_range, @as(usize, 1)));
    if (ranges <= 1) return 0;
    return @min(max_worker_threads, ranges - 1);
}

fn normalizeWorkTunerConfig(config: AdaptiveWorkTunerConfig) AdaptiveWorkTunerConfig {
    var normalized = config;
    normalized.smallest_range_items = @max(normalized.smallest_range_items, @as(usize, 1));
    normalized.largest_range_items = @max(normalized.largest_range_items, normalized.smallest_range_items);
    normalized.initial_range_items = clampItemCount(normalized.initial_range_items, normalized.smallest_range_items, normalized.largest_range_items);
    normalized.sample_window = @max(normalized.sample_window, @as(usize, 1));
    normalized.improvement_threshold_percent = @min(normalized.improvement_threshold_percent, @as(u8, 100));
    normalized.threaded_commit_threshold_percent = @min(normalized.threaded_commit_threshold_percent, @as(u8, 100));
    normalized.item_count_reset_percent = @min(normalized.item_count_reset_percent, @as(u8, 100));
    normalized.settle_after_failed_profiles = @max(normalized.settle_after_failed_profiles, @as(usize, 1));
    normalized.retune_after_settled_windows = @max(normalized.retune_after_settled_windows, @as(usize, 1));
    normalized.min_ranges_per_participant = @max(normalized.min_ranges_per_participant, @as(usize, 1));
    normalized.max_ranges_per_participant = @max(normalized.max_ranges_per_participant, normalized.min_ranges_per_participant);
    return normalized;
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

fn profilesEqual(left: AdaptiveWorkProfile, right: AdaptiveWorkProfile) bool {
    return left.worker_threads == right.worker_threads and left.items_per_range == right.items_per_range;
}

fn inlineProfile(request: AdaptiveWorkRequest) AdaptiveWorkProfile {
    return .{
        .worker_threads = 0,
        .items_per_range = request.fallback_items_per_range,
    };
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
        .items_per_range = 3,
    });
    defer threads.deinit();

    const stats = threads.parallelFor(10, &context, recordRangeIndex);

    try std.testing.expect(stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 4), stats.range_count);
    try std.testing.expectEqualSlices(usize, &.{ 0, 3, 6, 9 }, &starts);
    try std.testing.expectEqualSlices(usize, &.{ 3, 6, 9, 10 }, &ends);
}

test "adaptive inline runs as one direct main-thread range" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 128;
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = 1,
    });
    defer threads.deinit();

    var adaptive_tuner = AdaptiveWorkTuner.init(.{
        .sample_window = 1,
        .threaded_batch_ns = 1000,
    });
    const stats = threads.parallelForWithOptions(hits.len, &context, markCoverage, .{
        .adaptive_tuner = &adaptive_tuner,
    });

    try std.testing.expect(stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 1), stats.range_count);
    try std.testing.expectEqual(hits.len, stats.items_per_range);
    try std.testing.expectEqual(@as(usize, 1), stats.main_thread_ranges);
    try std.testing.expectEqual(@as(usize, 0), stats.worker_thread_ranges);
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

test "parallel for options use provided adaptive work tuner" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 128;
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = 1,
    });
    defer threads.deinit();

    var adaptive_tuner = AdaptiveWorkTuner.init(.{
        .sample_window = 1,
        .threaded_batch_ns = 1,
    });
    _ = adaptive_tuner.selectProfile(tunerTestRequest(128, 2, 1, 1));
    adaptive_tuner.record(tunerTestBatch(128, 1, 100));
    const stats = threads.parallelForWithOptions(hits.len, &context, markCoverage, .{
        .adaptive_tuner = &adaptive_tuner,
    });

    const report = adaptive_tuner.report();
    try std.testing.expect(stats.item_count == hits.len);
    try std.testing.expect(report.sample_count > 0 or report.baseline_mean_batch_duration_ns > 0);
    try std.testing.expect(report.has_threaded_profile);
    try std.testing.expectEqual(@as(u64, 0), threads.adaptive_tuner.report().best_mean_batch_duration_ns);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "parallel for options record selected adaptive profile" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 128;
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = 64,
    });
    defer threads.deinit();

    var adaptive_tuner = AdaptiveWorkTuner.init(.{
        .sample_window = 1,
        .threaded_batch_ns = 1,
    });
    const stats = threads.parallelForWithOptions(hits.len, &context, markCoverage, .{
        .adaptive_tuner = &adaptive_tuner,
        .selected_profile = .{
            .worker_threads = 1,
            .items_per_range = 16,
        },
    });

    try std.testing.expect(!stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 1), stats.active_worker_threads);
    try std.testing.expectEqual(@as(usize, 16), stats.items_per_range);
    try std.testing.expect(adaptive_tuner.report().has_threaded_profile);
    try std.testing.expect(adaptive_tuner.report().best_mean_batch_duration_ns > 0);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "parallel for options record selected inline adaptive profile" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 128;
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = 64,
    });
    defer threads.deinit();

    var adaptive_tuner = AdaptiveWorkTuner.init(.{
        .sample_window = 1,
        .threaded_batch_ns = std.math.maxInt(u64),
    });
    const stats = threads.parallelForWithOptions(hits.len, &context, markCoverage, .{
        .adaptive_tuner = &adaptive_tuner,
        .max_worker_threads = 0,
        .selected_profile = .{
            .worker_threads = 0,
            .items_per_range = hits.len,
        },
    });

    const report = adaptive_tuner.report();
    try std.testing.expect(stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 0), stats.active_worker_threads);
    try std.testing.expectEqual(AdaptiveWorkPhase.settled, report.phase);
    try std.testing.expect(!report.has_threaded_profile);
    try std.testing.expect(report.baseline_mean_batch_duration_ns > 0);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "single selected range runs inline even when worker threads exist" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 8;
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 1,
        .items_per_range = 2,
    });
    defer threads.deinit();

    const stats = threads.parallelFor(hits.len, &context, markCoverage);

    try std.testing.expect(stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 1), stats.range_count);
    try std.testing.expectEqual(@as(usize, 0), stats.active_worker_threads);
    try std.testing.expectEqual(@as(usize, 0), stats.worker_thread_ranges);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "small measured-expensive batch can activate worker threads" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 8;
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 1,
        .items_per_range = 2,
    });
    defer threads.deinit();

    var adaptive_tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 2,
        .smallest_range_items = 1,
        .largest_range_items = 8,
        .sample_window = 1,
        .threaded_batch_ns = 1,
    });
    const inline_profile = adaptive_tuner.selectProfile(tunerTestRequest(hits.len, 1, 1, 2));
    try std.testing.expectEqual(@as(usize, 0), inline_profile.worker_threads);
    adaptive_tuner.record(tunerTestBatchWithProfile(hits.len, inline_profile, 100_000));

    const stats = threads.parallelForWithOptions(hits.len, &context, markCoverage, .{
        .adaptive_tuner = &adaptive_tuner,
    });

    try std.testing.expect(!stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 1), stats.active_worker_threads);
    try std.testing.expect(stats.range_count > 1);
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

test "adaptive work tuner aligns and clamps selected items_per_range" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 17,
        .smallest_range_items = 16,
        .largest_range_items = 256,
    });

    const profile = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 17));
    try std.testing.expectEqual(@as(usize, 32), profile.items_per_range);

    const report = tuner.report();
    try std.testing.expectEqual(@as(usize, 17), report.current_profile.items_per_range);
    try std.testing.expectEqual(@as(usize, 17), report.best_profile.items_per_range);
}

test "adaptive work tuner stays inline below threaded threshold" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 64,
        .smallest_range_items = 16,
        .largest_range_items = 256,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
    });

    const request = tunerTestRequest(1024, 4, 16, 64);
    const selected = tuner.selectProfile(request);
    try std.testing.expectEqual(@as(usize, 0), selected.worker_threads);
    tuner.record(tunerTestBatchWithProfile(1024, selected, 500));

    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveWorkPhase.settled, report.phase);
    try std.testing.expect(!report.has_threaded_profile);
    try std.testing.expectEqual(@as(u64, 500), report.baseline_mean_batch_duration_ns);
    try std.testing.expectEqual(@as(usize, 0), tuner.selectProfile(request).worker_threads);
    try std.testing.expect(tuner.isSettled());
}

test "adaptive work tuner default threshold requires full slow inline window" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 64,
        .smallest_range_items = 16,
        .largest_range_items = 256,
    });
    const request = tunerTestRequest(1024, 4, 16, 64);

    var sample_index: usize = 0;
    while (sample_index < tuner.config.sample_window - 1) : (sample_index += 1) {
        const selected = tuner.selectProfile(request);
        try std.testing.expectEqual(@as(usize, 0), selected.worker_threads);
        tuner.record(tunerTestBatchWithProfile(1024, selected, 60_000));
        try std.testing.expectEqual(AdaptiveWorkPhase.learning, tuner.report().phase);
    }

    const final_inline = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(1024, final_inline, 60_000));
    try std.testing.expectEqual(AdaptiveWorkPhase.probing, tuner.report().phase);
}

test "adaptive work tuner default threshold keeps cheap inline work settled" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 64,
        .smallest_range_items = 16,
        .largest_range_items = 256,
    });
    const request = tunerTestRequest(1024, 4, 16, 64);

    var sample_index: usize = 0;
    while (sample_index < tuner.config.sample_window) : (sample_index += 1) {
        const selected = tuner.selectProfile(request);
        try std.testing.expectEqual(@as(usize, 0), selected.worker_threads);
        tuner.record(tunerTestBatchWithProfile(1024, selected, 49_000));
    }

    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveWorkPhase.settled, report.phase);
    try std.testing.expect(!report.has_threaded_profile);
    try std.testing.expectEqual(@as(u64, 49_000), report.baseline_mean_batch_duration_ns);
    try std.testing.expectEqual(@as(usize, 0), tuner.selectProfile(request).worker_threads);
}

test "adaptive work tuner predicts threaded profile from slow inline batch" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 64,
        .smallest_range_items = 16,
        .largest_range_items = 256,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
    });
    const request = tunerTestRequest(1024, 4, 16, 64);

    const inline_profile = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(1024, inline_profile, 100_000));
    try std.testing.expectEqual(AdaptiveWorkPhase.probing, tuner.report().phase);

    const candidate = tuner.selectProfile(request);
    try std.testing.expect(candidate.worker_threads > 0);
    try std.testing.expect(candidate.worker_threads <= request.max_worker_threads);
    try std.testing.expect(candidate.items_per_range >= 16);
    try std.testing.expect(candidate.items_per_range <= 256);
}

test "adaptive work tuner commits verified predicted profile" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 64,
        .smallest_range_items = 16,
        .largest_range_items = 256,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
        .improvement_threshold_percent = 5,
    });

    const request = tunerTestRequest(1024, 4, 16, 64);
    const inline_profile = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(1024, inline_profile, 4000));
    const candidate = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(1024, candidate, 800));

    const report = tuner.report();
    try std.testing.expectEqual(candidate.worker_threads, report.current_profile.worker_threads);
    try std.testing.expectEqual(candidate.items_per_range, report.current_profile.items_per_range);
    try std.testing.expectEqual(@as(u64, 800), report.best_mean_batch_duration_ns);
}

test "adaptive work tuner computes more workers for larger measured work" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 64,
        .smallest_range_items = 16,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
    });

    const request = tunerTestRequest(65_536, 64, 16, 64);
    const inline_profile = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(65_536, inline_profile, 1_000_000));

    const candidate = tuner.selectProfile(request);
    try std.testing.expect(candidate.worker_threads > 1);
    try std.testing.expect(candidate.worker_threads <= request.max_worker_threads);
}

test "adaptive work tuner derives range size from range overhead policy" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 64,
        .smallest_range_items = 16,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
        .min_ranges_per_participant = 2,
        .max_ranges_per_participant = 2,
    });
    const request = tunerTestRequest(16_384, 10, 16, 64);

    const inline_profile = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(16_384, inline_profile, 1_000_000));
    const candidate = tuner.selectProfile(request);
    const participants = candidate.worker_threads + 1;
    const target_ranges = participants * 2;
    const expected_items_per_range = alignItemCount(
        targetRangeSizeForRangeCount(request.item_count, target_ranges),
        request.range_alignment_items,
    );
    try std.testing.expectEqual(expected_items_per_range, candidate.items_per_range);
}

test "adaptive work tuner keeps inline when first threaded probe loses" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 64,
        .smallest_range_items = 16,
        .largest_range_items = 256,
        .sample_window = 1,
        .improvement_threshold_percent = 5,
        .threaded_batch_ns = 1000,
    });

    const inline_profile = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
    tuner.record(tunerTestBatchWithProfile(1024, inline_profile, 1500));
    const first_candidate = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
    tuner.record(tunerTestBatchWithProfile(1024, first_candidate, 1700));
    var guard: usize = 0;
    while (!tuner.isSettled() and guard < 16) : (guard += 1) {
        const losing_candidate = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
        tuner.record(tunerTestBatchWithProfile(1024, losing_candidate, 1700));
    }

    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveWorkPhase.settled, report.phase);
    try std.testing.expect(!report.has_threaded_profile);
    try std.testing.expect(report.baseline_mean_batch_duration_ns > 0);
    try std.testing.expectEqual(@as(?AdaptiveWorkProfile, null), report.candidate_profile);
    try std.testing.expectEqual(@as(usize, 0), tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64)).worker_threads);
    try std.testing.expect(tuner.isSettled());
}

test "adaptive work tuner cools down after failed inline threaded probe" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 64,
        .smallest_range_items = 16,
        .largest_range_items = 256,
        .sample_window = 1,
        .improvement_threshold_percent = 5,
        .threaded_batch_ns = 1000,
        .retune_after_settled_windows = 2,
    });
    const request = tunerTestRequest(1024, 4, 16, 64);

    const inline_profile = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(1024, inline_profile, 1_000_000));
    const first_candidate = tuner.selectProfile(request);
    try std.testing.expect(first_candidate.worker_threads > 0);
    tuner.record(tunerTestBatchWithProfile(1024, first_candidate, 960_000));
    try std.testing.expect(tuner.isSettled());

    const first_cooldown_inline = tuner.selectProfile(request);
    try std.testing.expectEqual(@as(usize, 0), first_cooldown_inline.worker_threads);
    tuner.record(tunerTestBatchWithProfile(1024, first_cooldown_inline, 1_000_000));
    try std.testing.expect(tuner.isSettled());

    const second_cooldown_inline = tuner.selectProfile(request);
    try std.testing.expectEqual(@as(usize, 0), second_cooldown_inline.worker_threads);
    tuner.record(tunerTestBatchWithProfile(1024, second_cooldown_inline, 1_000_000));
    try std.testing.expect(tuner.isSettled());

    const retry_inline = tuner.selectProfile(request);
    try std.testing.expectEqual(@as(usize, 0), retry_inline.worker_threads);
    tuner.record(tunerTestBatchWithProfile(1024, retry_inline, 1_000_000));
    try std.testing.expectEqual(AdaptiveWorkPhase.probing, tuner.report().phase);
    try std.testing.expect(tuner.report().candidate_profile.?.worker_threads > 0);
}

test "adaptive work tuner resets sample window after item count shift" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 64,
        .sample_window = 4,
        .item_count_reset_percent = 25,
    });

    const profile = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
    tuner.record(tunerTestBatchWithProfile(1024, profile, 1000));
    try std.testing.expectEqual(@as(usize, 1), tuner.report().sample_count);

    _ = tuner.selectProfile(tunerTestRequest(2048, 4, 16, 64));
    try std.testing.expectEqual(@as(usize, 0), tuner.report().sample_count);
    try std.testing.expectEqual(AdaptiveWorkPhase.learning, tuner.report().phase);
}

test "adaptive work tuner clears in-progress profile after item count shift" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 64,
        .sample_window = 1,
        .item_count_reset_percent = 25,
        .threaded_batch_ns = 1,
    });

    const profile = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
    tuner.record(tunerTestBatchWithProfile(1024, profile, 1_000_000));
    try std.testing.expectEqual(AdaptiveWorkPhase.probing, tuner.report().phase);
    try std.testing.expect(!tuner.report().has_threaded_profile);
    try std.testing.expectEqual(@as(u64, 1_000_000), tuner.report().baseline_mean_batch_duration_ns);

    _ = tuner.selectProfile(tunerTestRequest(2048, 4, 16, 64));
    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveWorkPhase.learning, report.phase);
    try std.testing.expect(!report.has_threaded_profile);
    try std.testing.expectEqual(@as(u64, 0), report.best_mean_batch_duration_ns);
    try std.testing.expectEqual(@as(usize, 64), report.best_profile.items_per_range);
}

test "adaptive work tuner item count reset starts new workload inline" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 16,
        .smallest_range_items = 16,
        .largest_range_items = 64,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
        .improvement_threshold_percent = 5,
        .item_count_reset_percent = 25,
    });
    const request = tunerTestRequest(1024, 4, 16, 16);

    const inline_profile = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(1024, inline_profile, 1_000_000));
    const threaded = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(1024, threaded, 100_000));
    var settle_guard: usize = 0;
    while (!tuner.isSettled() and settle_guard < 64) : (settle_guard += 1) {
        const candidate = tuner.selectProfile(request);
        tuner.record(tunerTestBatchWithProfile(1024, candidate, 150_000));
    }
    try std.testing.expect(tuner.isSettled());
    try std.testing.expect(tuner.report().current_profile.worker_threads > 0);

    const shifted = tuner.selectProfile(tunerTestRequest(2048, 4, 16, 16));
    try std.testing.expectEqual(@as(usize, 0), shifted.worker_threads);
    try std.testing.expectEqual(AdaptiveWorkPhase.learning, tuner.report().phase);
}

test "adaptive work tuner settled threaded retune does not fall back inline" {
    const inline_baseline_ns = 1_000_000;
    const first_threaded_win_ns = 100_000;
    const settled_threaded_ns = 110_000;
    const losing_threaded_challenger_ns = 150_000;

    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 16,
        .smallest_range_items = 16,
        .largest_range_items = 64,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
        .retune_after_settled_windows = 1,
        .improvement_threshold_percent = 5,
    });

    const request = tunerTestRequest(1024, 4, 16, 16);
    const inline_profile = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(1024, inline_profile, inline_baseline_ns));
    const threaded = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(1024, threaded, first_threaded_win_ns));
    var settle_guard: usize = 0;
    while (!tuner.isSettled() and settle_guard < 64) : (settle_guard += 1) {
        const candidate = tuner.selectProfile(request);
        tuner.record(tunerTestBatchWithProfile(1024, candidate, losing_threaded_challenger_ns));
    }
    try std.testing.expect(tuner.isSettled());
    try std.testing.expect(tuner.report().current_profile.worker_threads > 0);

    const settled = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(1024, settled, settled_threaded_ns));
    const after_retune = tuner.selectProfile(request);
    try std.testing.expect(after_retune.worker_threads > 0);
    tuner.record(tunerTestBatchWithProfile(1024, after_retune, losing_threaded_challenger_ns));

    const report = tuner.report();
    try std.testing.expect(report.current_profile.worker_threads > 0);
}

test "adaptive work tuner retune keeps threaded profile when inline loses" {
    const inline_baseline_ns = 1_000_000;
    const first_threaded_win_ns = 100_000;
    const settled_threaded_ns = 110_000;
    const losing_threaded_challenger_ns = 150_000;

    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 16,
        .smallest_range_items = 16,
        .largest_range_items = 64,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
        .retune_after_settled_windows = 1,
        .improvement_threshold_percent = 5,
    });

    const request = tunerTestRequest(1024, 4, 16, 16);
    const inline_profile = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(1024, inline_profile, inline_baseline_ns));
    const threaded = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(1024, threaded, first_threaded_win_ns));
    var settle_guard: usize = 0;
    while (!tuner.isSettled() and settle_guard < 64) : (settle_guard += 1) {
        const candidate = tuner.selectProfile(request);
        tuner.record(tunerTestBatchWithProfile(1024, candidate, losing_threaded_challenger_ns));
    }
    try std.testing.expect(tuner.isSettled());
    try std.testing.expect(tuner.report().current_profile.worker_threads > 0);

    const settled = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(1024, settled, settled_threaded_ns));
    const threaded_candidate = tuner.selectProfile(request);
    try std.testing.expect(threaded_candidate.worker_threads > 0);
    tuner.record(tunerTestBatchWithProfile(1024, threaded_candidate, losing_threaded_challenger_ns));
    var keep_guard: usize = 0;
    while (!tuner.isSettled() and keep_guard < 64) : (keep_guard += 1) {
        const candidate = tuner.selectProfile(request);
        tuner.record(tunerTestBatchWithProfile(1024, candidate, losing_threaded_challenger_ns));
    }
    try std.testing.expect(tuner.isSettled());

    const report = tuner.report();
    try std.testing.expect(report.current_profile.worker_threads > 0);
}

test "adaptive work tuner resets sample window when profile changes" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 64,
        .sample_window = 4,
    });

    tuner.record(tunerTestBatchWithProfile(1024, .{ .worker_threads = 1, .items_per_range = 64 }, 1000));
    try std.testing.expectEqual(@as(usize, 1), tuner.report().sample_count);

    tuner.record(tunerTestBatchWithProfile(1024, .{ .worker_threads = 2, .items_per_range = 64 }, 1000));
    try std.testing.expectEqual(@as(usize, 1), tuner.report().sample_count);
}

test "adaptive work tuner keeps aligned items_per_range within max when possible" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 90,
        .smallest_range_items = 1,
        .largest_range_items = 100,
    });

    const profile = tuner.selectProfile(tunerTestRequest(1024, 4, 64, 90));
    try std.testing.expectEqual(@as(usize, 64), profile.items_per_range);
}

test "adaptive work tuner settled cooldown keeps stable model settled" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 64,
        .smallest_range_items = 16,
        .largest_range_items = 256,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
        .retune_after_settled_windows = 2,
    });

    const inline_profile = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
    tuner.record(tunerTestBatchWithProfile(1024, inline_profile, 1_000_000));
    const candidate = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
    tuner.record(tunerTestBatchWithProfile(1024, candidate, 100_000));
    var guard: usize = 0;
    while (!tuner.isSettled() and guard < 512) : (guard += 1) {
        const rejected = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
        tuner.record(tunerTestBatchWithProfile(1024, rejected, 150_000));
    }
    try std.testing.expect(tuner.isSettled());

    const settled = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
    tuner.record(tunerTestBatchWithProfile(1024, settled, 110_000));
    try std.testing.expect(tuner.isSettled());

    tuner.record(tunerTestBatchWithProfile(1024, settled, 110_000));

    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveWorkPhase.settled, report.phase);
    try std.testing.expectEqual(@as(?AdaptiveWorkProfile, null), report.candidate_profile);
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

fn recordSyntheticTuningRun(
    tuner: *AdaptiveWorkTuner,
    request: AdaptiveWorkRequest,
    winning_profile: AdaptiveWorkProfile,
    winning_duration_ns: u64,
    default_duration_ns: u64,
) void {
    var guard: usize = 0;
    while (!tuner.isSettled() and guard < 128) : (guard += 1) {
        const selected = tuner.selectProfile(request);
        const duration_ns = if (profilesEqual(selected, winning_profile)) winning_duration_ns else default_duration_ns;
        tuner.record(tunerTestBatchWithProfile(request.item_count, selected, duration_ns));
    }
}

fn tunerTestRequest(item_count: usize, available_worker_threads: usize, range_alignment_items: usize, fallback_items_per_range: usize) AdaptiveWorkRequest {
    return .{
        .item_count = item_count,
        .available_worker_threads = available_worker_threads,
        .max_worker_threads = available_worker_threads,
        .fallback_items_per_range = fallback_items_per_range,
        .range_alignment_items = range_alignment_items,
    };
}

fn tunerTestBatch(item_count: usize, items_per_range: usize, duration_ns: u64) BatchStats {
    return tunerTestBatchWithProfile(item_count, .{
        .worker_threads = 1,
        .items_per_range = items_per_range,
    }, duration_ns);
}

fn tunerTestBatchWithProfile(item_count: usize, profile: AdaptiveWorkProfile, duration_ns: u64) BatchStats {
    return .{
        .item_count = item_count,
        .range_count = rangeCount(item_count, profile.items_per_range),
        .items_per_range = profile.items_per_range,
        .available_worker_threads = @max(profile.worker_threads, @as(usize, 1)),
        .active_worker_threads = profile.worker_threads,
        .main_thread_ranges = if (item_count > 0) 1 else 0,
        .worker_thread_ranges = if (profile.worker_threads > 0) 1 else 0,
        .worker_utilization = if (profile.worker_threads > 0) 0.5 else 0,
        .batch_duration_ns = duration_ns,
        .ran_inline = profile.worker_threads == 0,
    };
}
