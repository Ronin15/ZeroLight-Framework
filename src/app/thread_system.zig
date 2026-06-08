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
    adaptive_tuner: ?*AdaptiveWorkTuner = null,
};

pub const AdaptiveWorkProfile = struct {
    /// `0` means the batch runs inline on the main thread.
    worker_threads: usize = 0,
    items_per_range: usize = (ThreadSystemConfig{}).items_per_range,
};

pub const AdaptiveWorkTunerConfig = struct {
    initial_items_per_range: usize = (ThreadSystemConfig{}).items_per_range,
    min_items_per_range: usize = 16,
    max_items_per_range: usize = std.math.maxInt(usize),
    sample_window: usize = 3,
    improvement_threshold_percent: u8 = 1,
    threaded_commit_threshold_percent: u8 = 10,
    item_count_reset_percent: u8 = 25,
    threaded_batch_ns: u64 = 50_000,
    settle_after_failed_profiles: usize = 2,
    retune_after_settled_windows: usize = 120,
};

pub const AdaptiveWorkPhase = enum {
    learning,
    probing,
    settled,
};

const AdaptiveWorkSearchStage = enum {
    workers,
    shrink,
    grow,
};

const max_work_candidates = 32;

pub const AdaptiveWorkRequest = struct {
    item_count: usize,
    available_worker_threads: usize,
    max_worker_threads: usize,
    min_parallel_items: usize,
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
    sample_count: usize = 0,
    sample_total_ns: u128 = 0,
    range_step_items: usize = 0,
    search_stage: AdaptiveWorkSearchStage = .shrink,
    probe_inline_candidate: bool = false,
    worker_search_exhausted: bool = false,
    rejected_shrink: bool = false,
    rejected_grow: bool = false,
    grow_exhausted: bool = false,
    work_candidates: [max_work_candidates]AdaptiveWorkProfile = [_]AdaptiveWorkProfile{.{}} ** max_work_candidates,
    work_candidate_count: usize = 0,
    work_candidate_index: usize = 0,
    failed_profile_count: usize = 0,
    settled_window_count: usize = 0,
    next_grow_items_per_range: usize = 0,
    last_item_count: usize = 0,
    last_range_alignment_items: usize = 1,
    last_request: ?AdaptiveWorkRequest = null,
    sampled_profile: ?AdaptiveWorkProfile = null,

    pub fn init(config: AdaptiveWorkTunerConfig) AdaptiveWorkTuner {
        const normalized = normalizeWorkTunerConfig(config);
        const initial = clampItemCount(normalized.initial_items_per_range, normalized.min_items_per_range, normalized.max_items_per_range);
        const profile = AdaptiveWorkProfile{
            .worker_threads = 0,
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
            .learning, .settled => self.current_profile,
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
        const range_span_steps = @max(@as(usize, 1), (max_range - self.config.min_items_per_range) / alignment);
        const range_windows = saturatingMul(ceilLog2(range_span_steps) + 2, @as(usize, 2));
        const windows = saturatingAdd(@as(usize, 3), range_windows);
        return saturatingMul(windows, self.config.sample_window);
    }

    fn finishLearningWindow(self: *AdaptiveWorkTuner, sample_mean_ns: u64) void {
        const profile = self.sampled_profile orelse self.current_profile;
        self.baseline_mean_batch_duration_ns = sample_mean_ns;
        self.recordBest(profile, sample_mean_ns);
        if (profile.worker_threads == 0 and sample_mean_ns < self.config.threaded_batch_ns) {
            self.settle();
            return;
        }
        self.startProfileSearch(profile, sample_mean_ns, false);
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
            self.rejected_shrink = false;
            self.rejected_grow = false;
            self.updateRangeStepAfterWin(candidate);
            self.startNextProfile();
            return;
        }

        self.rejectProfile();
    }

    fn finishSettledWindow(self: *AdaptiveWorkTuner, sample_mean_ns: u64) void {
        const profile = self.sampled_profile orelse self.current_profile;
        self.baseline_mean_batch_duration_ns = sample_mean_ns;
        self.settled_window_count += 1;

        if (profile.worker_threads == 0 and sample_mean_ns >= self.config.threaded_batch_ns) {
            self.startProfileSearch(profile, sample_mean_ns, false);
            return;
        }
        if (self.settled_window_count >= self.config.retune_after_settled_windows) {
            self.startProfileSearch(profile, sample_mean_ns, false);
            return;
        }
        self.recordBest(profile, sample_mean_ns);
    }

    fn startProfileSearch(self: *AdaptiveWorkTuner, baseline_profile: AdaptiveWorkProfile, baseline_mean_ns: u64, include_inline_candidate: bool) void {
        const request = self.last_request orelse {
            self.settle();
            return;
        };
        const normalized_baseline = self.normalizedProfile(baseline_profile, request);
        self.range_step_items = 0;
        self.search_stage = .workers;
        self.probe_inline_candidate = include_inline_candidate and normalized_baseline.worker_threads > 0;
        self.worker_search_exhausted = false;
        self.rejected_shrink = false;
        self.rejected_grow = false;
        self.grow_exhausted = false;
        self.failed_profile_count = 0;
        self.next_grow_items_per_range = 0;
        self.current_profile = normalized_baseline;
        self.best_profile = normalized_baseline;
        self.best_mean_batch_duration_ns = baseline_mean_ns;
        self.baseline_mean_batch_duration_ns = baseline_mean_ns;
        self.prepareWorkCandidates(request, normalized_baseline);
        self.startNextProfile();
    }

    fn startNextProfile(self: *AdaptiveWorkTuner) void {
        const request = self.last_request orelse {
            self.settle();
            return;
        };

        if (self.probe_inline_candidate) {
            self.probe_inline_candidate = false;
            const inline_candidate = self.normalizedProfile(.{
                .worker_threads = 0,
                .items_per_range = request.fallback_items_per_range,
            }, request);
            if (!profilesEqual(inline_candidate, self.current_profile) and !profilesEqual(inline_candidate, self.best_profile)) {
                self.candidate_profile = inline_candidate;
                self.phase = .probing;
                return;
            }
        }

        if (!self.worker_search_exhausted) {
            if (self.nextWorkCandidate(request)) |candidate| {
                self.candidate_profile = candidate;
                self.search_stage = .workers;
                self.phase = .probing;
                return;
            }
            self.worker_search_exhausted = true;
            self.search_stage = .shrink;
        }

        if (self.range_step_items == 0) {
            self.range_step_items = self.initialRangeStep(self.best_profile.items_per_range, request);
        }

        while (self.range_step_items >= request.range_alignment_items) {
            if (self.search_stage == .shrink and !self.rejected_shrink) {
                if (self.rangeCandidate(request, .shrink)) |candidate| {
                    self.candidate_profile = candidate;
                    self.phase = .probing;
                    return;
                }
                self.rejected_shrink = true;
                self.search_stage = .grow;
                continue;
            }
            if (self.search_stage == .grow and !self.grow_exhausted) {
                if (self.nextGrowRangeCandidate(request)) |candidate| {
                    self.candidate_profile = candidate;
                    self.phase = .probing;
                    return;
                }
                self.grow_exhausted = true;
                self.rejected_grow = true;
            }

            if (self.rejected_shrink and self.rejected_grow) {
                const next_step = alignItemCountDown(@max(self.range_step_items / 2, request.range_alignment_items), request.range_alignment_items);
                if (next_step >= self.range_step_items or next_step < request.range_alignment_items) break;
                self.range_step_items = next_step;
                self.rejected_shrink = false;
                self.rejected_grow = false;
                self.grow_exhausted = false;
                self.next_grow_items_per_range = 0;
                self.search_stage = .shrink;
                continue;
            }

            self.search_stage = .grow;
        }

        self.settle();
    }

    fn settle(self: *AdaptiveWorkTuner) void {
        self.phase = .settled;
        self.current_profile = self.best_profile;
        self.candidate_profile = null;
        self.failed_profile_count = 0;
        self.settled_window_count = 0;
    }

    fn resetForLearning(self: *AdaptiveWorkTuner) void {
        self.phase = .learning;
        self.current_profile = self.initial_profile;
        self.best_profile = self.initial_profile;
        self.candidate_profile = null;
        self.range_step_items = 0;
        self.search_stage = .workers;
        self.probe_inline_candidate = false;
        self.worker_search_exhausted = false;
        self.rejected_shrink = false;
        self.rejected_grow = false;
        self.grow_exhausted = false;
        self.work_candidates = [_]AdaptiveWorkProfile{.{}} ** max_work_candidates;
        self.work_candidate_count = 0;
        self.work_candidate_index = 0;
        self.best_mean_batch_duration_ns = 0;
        self.baseline_mean_batch_duration_ns = 0;
        self.failed_profile_count = 0;
        self.settled_window_count = 0;
        self.next_grow_items_per_range = 0;
        self.resetSamples();
    }

    fn normalizeRequest(self: *const AdaptiveWorkTuner, request: AdaptiveWorkRequest) AdaptiveWorkRequest {
        const alignment = @max(request.range_alignment_items, @as(usize, 1));
        const max_workers = @min(request.max_worker_threads, request.available_worker_threads);
        return .{
            .item_count = request.item_count,
            .available_worker_threads = request.available_worker_threads,
            .max_worker_threads = max_workers,
            .min_parallel_items = request.min_parallel_items,
            .fallback_items_per_range = self.normalizedItemsPerRange(request.fallback_items_per_range, alignment),
            .range_alignment_items = alignment,
        };
    }

    fn normalizedProfile(self: *const AdaptiveWorkTuner, profile: AdaptiveWorkProfile, request: AdaptiveWorkRequest) AdaptiveWorkProfile {
        const items_per_range = self.normalizedItemsPerRange(profile.items_per_range, request.range_alignment_items);
        const ranges = rangeCount(request.item_count, items_per_range);
        const range_limited_workers = if (ranges > 1) @min(request.max_worker_threads, ranges - 1) else 0;
        const workers = if (request.item_count < request.min_parallel_items)
            @as(usize, 0)
        else
            @min(profile.worker_threads, range_limited_workers);
        return .{
            .worker_threads = workers,
            .items_per_range = items_per_range,
        };
    }

    fn normalizedItemsPerRange(self: *const AdaptiveWorkTuner, items_per_range: usize, alignment: usize) usize {
        const clamped = clampItemCount(@max(items_per_range, @as(usize, 1)), self.config.min_items_per_range, self.config.max_items_per_range);
        const aligned_up = alignItemCount(clamped, alignment);
        if (aligned_up <= self.config.max_items_per_range) return aligned_up;

        const aligned_max = alignItemCountDown(self.config.max_items_per_range, alignment);
        if (aligned_max >= self.config.min_items_per_range) return aligned_max;
        return clamped;
    }

    fn initialRangeStep(self: *const AdaptiveWorkTuner, items_per_range: usize, request: AdaptiveWorkRequest) usize {
        const alignment = @max(request.range_alignment_items, @as(usize, 1));
        const raw = @max(items_per_range / 2, alignment);
        const aligned = alignItemCountDown(raw, alignment);
        _ = self;
        return @max(aligned, alignment);
    }

    fn prepareWorkCandidates(self: *AdaptiveWorkTuner, request: AdaptiveWorkRequest, baseline: AdaptiveWorkProfile) void {
        self.work_candidates = [_]AdaptiveWorkProfile{.{}} ** max_work_candidates;
        self.work_candidate_count = 0;
        self.work_candidate_index = 0;

        const max_threads = self.normalizedProfile(.{
            .worker_threads = request.max_worker_threads,
            .items_per_range = request.fallback_items_per_range,
        }, request).worker_threads;
        if (max_threads == 0) return;

        const half_threads = @max(@as(usize, 1), max_threads / 2);
        const conservative_threads = @min(max_threads, @as(usize, 2));
        const cheap_threaded_work = baseline.worker_threads == 0 and
            @as(u128, self.baseline_mean_batch_duration_ns) < @as(u128, self.config.threaded_batch_ns) * 3;

        const fallback_range = request.fallback_items_per_range;
        const small_range = self.normalizedItemsPerRange(@max(fallback_range / 2, request.range_alignment_items), request.range_alignment_items);
        const large_range = self.normalizedItemsPerRange(saturatingMul(fallback_range, @as(usize, 4)), request.range_alignment_items);
        const coarse_range = self.maxThreadedItemsPerRange(request);

        if (cheap_threaded_work) {
            self.appendWorkCandidatesForThreads(conservative_threads, fallback_range, small_range, large_range, coarse_range, request);
            self.appendWorkCandidatesForThreads(1, fallback_range, small_range, large_range, coarse_range, request);
            self.appendWorkCandidatesForThreads(half_threads, fallback_range, small_range, large_range, coarse_range, request);
            self.appendWorkCandidatesForThreads(max_threads, fallback_range, small_range, large_range, coarse_range, request);
        } else {
            self.appendWorkCandidatesForThreads(max_threads, fallback_range, small_range, large_range, coarse_range, request);
            self.appendWorkCandidatesForThreads(half_threads, fallback_range, small_range, large_range, coarse_range, request);
            self.appendWorkCandidatesForThreads(conservative_threads, fallback_range, small_range, large_range, coarse_range, request);
            self.appendWorkCandidatesForThreads(1, fallback_range, small_range, large_range, coarse_range, request);
        }
    }

    fn appendWorkCandidatesForThreads(
        self: *AdaptiveWorkTuner,
        worker_threads: usize,
        fallback_range: usize,
        small_range: usize,
        large_range: usize,
        coarse_range: usize,
        request: AdaptiveWorkRequest,
    ) void {
        if (worker_threads == 0) return;
        self.appendWorkCandidate(.{ .worker_threads = worker_threads, .items_per_range = fallback_range }, request);
        self.appendWorkCandidate(.{ .worker_threads = worker_threads, .items_per_range = small_range }, request);
        self.appendWorkCandidate(.{ .worker_threads = worker_threads, .items_per_range = large_range }, request);
        self.appendWorkCandidate(.{ .worker_threads = worker_threads, .items_per_range = coarse_range }, request);
    }

    fn appendWorkCandidate(self: *AdaptiveWorkTuner, profile: AdaptiveWorkProfile, request: AdaptiveWorkRequest) void {
        const candidate = self.normalizedProfile(profile, request);
        if (candidate.worker_threads == 0) return;
        if (profilesEqual(candidate, self.current_profile) or profilesEqual(candidate, self.best_profile)) return;
        for (self.work_candidates[0..self.work_candidate_count]) |existing| {
            if (profilesEqual(existing, candidate)) return;
        }
        if (self.work_candidate_count >= self.work_candidates.len) return;
        self.work_candidates[self.work_candidate_count] = candidate;
        self.work_candidate_count += 1;
    }

    fn nextWorkCandidate(self: *AdaptiveWorkTuner, request: AdaptiveWorkRequest) ?AdaptiveWorkProfile {
        while (self.work_candidate_index < self.work_candidate_count) {
            const candidate = self.normalizedProfile(self.work_candidates[self.work_candidate_index], request);
            self.work_candidate_index += 1;
            if (candidate.worker_threads == 0) continue;
            if (profilesEqual(candidate, self.current_profile) or profilesEqual(candidate, self.best_profile)) continue;
            return candidate;
        }
        return null;
    }

    fn rangeCandidate(self: *const AdaptiveWorkTuner, request: AdaptiveWorkRequest, direction: AdaptiveWorkSearchStage) ?AdaptiveWorkProfile {
        const best = self.best_profile;
        if (best.worker_threads == 0 or self.range_step_items == 0) return null;

        const min_items_per_range = self.normalizedItemsPerRange(self.config.min_items_per_range, request.range_alignment_items);
        const max_items_per_range = self.effectiveMaxItemsPerRange(request);
        const raw = switch (direction) {
            .workers => unreachable,
            .shrink => blk: {
                if (best.items_per_range <= min_items_per_range + self.range_step_items) return null;
                break :blk best.items_per_range - self.range_step_items;
            },
            .grow => blk: {
                if (best.items_per_range >= max_items_per_range - self.range_step_items) return null;
                break :blk best.items_per_range + self.range_step_items;
            },
        };

        const candidate = self.normalizedProfile(.{
            .worker_threads = best.worker_threads,
            .items_per_range = raw,
        }, request);
        if (profilesEqual(candidate, self.best_profile) or profilesEqual(candidate, self.current_profile)) return null;
        return candidate;
    }

    fn nextGrowRangeCandidate(self: *AdaptiveWorkTuner, request: AdaptiveWorkRequest) ?AdaptiveWorkProfile {
        const best = self.best_profile;
        if (best.worker_threads == 0) return null;

        if (self.next_grow_items_per_range == 0) {
            self.next_grow_items_per_range = self.nextLargerItemsPerRange(best.items_per_range, request) orelse return null;
        }

        while (true) {
            const raw = self.next_grow_items_per_range;
            const next = self.nextLargerItemsPerRange(raw, request);
            self.next_grow_items_per_range = next orelse 0;
            if (next == null) self.grow_exhausted = true;

            const candidate = self.normalizedProfile(.{
                .worker_threads = best.worker_threads,
                .items_per_range = raw,
            }, request);
            if (!profilesEqual(candidate, self.best_profile) and !profilesEqual(candidate, self.current_profile)) {
                return candidate;
            }
            if (next == null) return null;
        }
    }

    fn nextLargerItemsPerRange(self: *const AdaptiveWorkTuner, current_items_per_range: usize, request: AdaptiveWorkRequest) ?usize {
        const alignment = @max(request.range_alignment_items, @as(usize, 1));
        const current = self.normalizedItemsPerRange(current_items_per_range, alignment);
        const max_items_per_range = self.maxThreadedItemsPerRange(request);
        if (current >= max_items_per_range) return null;

        const doubled = saturatingMul(current, @as(usize, 2));
        const raw = if (doubled > current) @min(doubled, max_items_per_range) else max_items_per_range;
        const candidate = self.normalizedItemsPerRange(raw, alignment);
        if (candidate <= current) return null;
        return candidate;
    }

    fn maxThreadedItemsPerRange(self: *const AdaptiveWorkTuner, request: AdaptiveWorkRequest) usize {
        if (request.item_count <= 1) return self.config.min_items_per_range;

        const alignment = @max(request.range_alignment_items, @as(usize, 1));
        const max_raw = @min(self.config.max_items_per_range, request.item_count - 1);
        const aligned = alignItemCountDown(max_raw, alignment);
        if (aligned >= self.config.min_items_per_range) return aligned;
        return @min(max_raw, self.config.min_items_per_range);
    }

    fn updateRangeStepAfterWin(self: *AdaptiveWorkTuner, candidate: AdaptiveWorkProfile) void {
        const request = self.last_request orelse return;
        if (self.range_step_items == 0) {
            self.range_step_items = self.initialRangeStep(candidate.items_per_range, request);
        }
    }

    fn maxUsefulItemsPerRange(self: *const AdaptiveWorkTuner, request: AdaptiveWorkRequest, max_items_per_range: usize) usize {
        if (request.item_count == 0) return self.config.min_items_per_range;
        var target_ranges = @max(@as(usize, 2), saturatingAdd(request.max_worker_threads, 1));
        const max_target_ranges = @max(target_ranges, rangeCount(request.item_count, self.config.min_items_per_range));
        while (target_ranges < max_target_ranges) : (target_ranges += 1) {
            const candidate = self.normalizedItemsPerRange(
                @min(targetRangeSizeForRangeCount(request.item_count, target_ranges), max_items_per_range),
                request.range_alignment_items,
            );
            if (rangeCount(request.item_count, candidate) > request.max_worker_threads) return candidate;
        }
        return self.normalizedItemsPerRange(self.config.min_items_per_range, request.range_alignment_items);
    }

    fn effectiveMaxItemsPerRange(self: *const AdaptiveWorkTuner, request: AdaptiveWorkRequest) usize {
        if (request.item_count == 0) return self.config.min_items_per_range;
        return @max(
            self.config.min_items_per_range,
            @min(self.config.max_items_per_range, request.item_count),
        );
    }

    fn recordBest(self: *AdaptiveWorkTuner, profile: AdaptiveWorkProfile, mean_ns: u64) void {
        if (self.shouldCommitCandidate(profile, mean_ns)) {
            self.best_mean_batch_duration_ns = mean_ns;
            self.best_profile = profile;
        }
    }

    fn shouldCommitCandidate(self: *const AdaptiveWorkTuner, candidate: AdaptiveWorkProfile, mean_ns: u64) bool {
        const best_ns = self.best_mean_batch_duration_ns;
        if (best_ns == 0) return true;
        const threshold = if (self.best_profile.worker_threads == 0 and candidate.worker_threads > 0)
            self.config.threaded_commit_threshold_percent
        else
            self.config.improvement_threshold_percent;
        return isMeaningfullyFaster(mean_ns, best_ns, threshold);
    }

    fn rejectProfile(self: *AdaptiveWorkTuner) void {
        if (self.candidate_profile == null) {
            self.settle();
            return;
        }

        switch (self.search_stage) {
            .workers => {
                self.failed_profile_count = 0;
            },
            .shrink => {
                self.rejected_shrink = true;
                self.search_stage = .grow;
                self.failed_profile_count = 0;
            },
            .grow => {
                self.failed_profile_count += 1;
                if (self.failed_profile_count >= self.config.settle_after_failed_profiles) {
                    self.settle();
                    return;
                }
            },
        }
        self.startNextProfile();
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
        const min_parallel_items = options.min_parallel_items orelse self.config.min_parallel_items;
        const max_worker_threads = @min(options.max_worker_threads orelse self.workers.len, self.workers.len);
        const requested_items_per_range = @max(options.items_per_range orelse self.config.items_per_range, @as(usize, 1));
        const adaptive_tuner = if (options.adaptive and options.items_per_range == null and max_worker_threads > 0)
            options.adaptive_tuner orelse &self.adaptive_tuner
        else
            null;
        const profile = if (adaptive_tuner) |tuner|
            tuner.selectProfile(.{
                .item_count = item_count,
                .available_worker_threads = self.workers.len,
                .max_worker_threads = max_worker_threads,
                .min_parallel_items = min_parallel_items,
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
        const active_worker_threads = if (item_count < min_parallel_items or selected_range_count <= 1)
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

fn maxUsefulWorkersForRange(item_count: usize, items_per_range: usize, max_worker_threads: usize) usize {
    const ranges = rangeCount(item_count, @max(items_per_range, @as(usize, 1)));
    if (ranges <= 1) return 0;
    return @min(max_worker_threads, ranges - 1);
}

fn normalizeWorkTunerConfig(config: AdaptiveWorkTunerConfig) AdaptiveWorkTunerConfig {
    var normalized = config;
    normalized.min_items_per_range = @max(normalized.min_items_per_range, @as(usize, 1));
    normalized.max_items_per_range = @max(normalized.max_items_per_range, normalized.min_items_per_range);
    normalized.initial_items_per_range = clampItemCount(normalized.initial_items_per_range, normalized.min_items_per_range, normalized.max_items_per_range);
    normalized.sample_window = @max(normalized.sample_window, @as(usize, 1));
    normalized.improvement_threshold_percent = @min(normalized.improvement_threshold_percent, @as(u8, 100));
    normalized.threaded_commit_threshold_percent = @min(normalized.threaded_commit_threshold_percent, @as(u8, 100));
    normalized.item_count_reset_percent = @min(normalized.item_count_reset_percent, @as(u8, 100));
    normalized.settle_after_failed_profiles = @max(normalized.settle_after_failed_profiles, @as(usize, 1));
    normalized.retune_after_settled_windows = @max(normalized.retune_after_settled_windows, @as(usize, 1));
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

test "adaptive inline runs as one direct main-thread range" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 128;
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .min_parallel_items = 1,
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

test "parallel for options use provided adaptive work tuner" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var hits = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** 128;
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .min_parallel_items = 1,
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

    try std.testing.expect(!stats.ran_inline);
    try std.testing.expect(adaptive_tuner.report().best_mean_batch_duration_ns > 0);
    try std.testing.expectEqual(@as(u64, 0), threads.adaptive_tuner.report().best_mean_batch_duration_ns);
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

test "adaptive work tuner aligns and clamps selected items_per_range" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 17,
        .min_items_per_range = 16,
        .max_items_per_range = 256,
    });

    const profile = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 17));
    try std.testing.expectEqual(@as(usize, 32), profile.items_per_range);

    const report = tuner.report();
    try std.testing.expectEqual(@as(usize, 17), report.current_profile.items_per_range);
    try std.testing.expectEqual(@as(usize, 17), report.best_profile.items_per_range);
}

test "adaptive work tuner stays inline below threaded threshold" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .max_items_per_range = 256,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
    });

    const selected = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
    try std.testing.expectEqual(@as(usize, 0), selected.worker_threads);
    tuner.record(tunerTestBatchWithProfile(1024, selected, 500));

    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveWorkPhase.settled, report.phase);
    try std.testing.expectEqual(@as(usize, 0), report.current_profile.worker_threads);
    try std.testing.expect(tuner.isSettled());
}

test "adaptive work tuner default threshold requires full slow inline window" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .max_items_per_range = 256,
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
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .max_items_per_range = 256,
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
    try std.testing.expectEqual(@as(usize, 0), report.current_profile.worker_threads);
}

test "adaptive work tuner probes complete threaded profile after slow inline batch" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .max_items_per_range = 256,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
    });

    const inline_profile = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
    tuner.record(tunerTestBatchWithProfile(1024, inline_profile, 4000));
    try std.testing.expectEqual(AdaptiveWorkPhase.probing, tuner.report().phase);

    const candidate = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
    try std.testing.expectEqual(@as(usize, 4), candidate.worker_threads);
    try std.testing.expectEqual(@as(usize, 64), candidate.items_per_range);
}

test "adaptive work tuner commits faster threaded profile" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .max_items_per_range = 256,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
        .improvement_threshold_percent = 5,
    });

    const inline_profile = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
    tuner.record(tunerTestBatchWithProfile(1024, inline_profile, 4000));
    const candidate = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
    tuner.record(tunerTestBatchWithProfile(1024, candidate, 800));

    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveWorkPhase.probing, report.phase);
    try std.testing.expectEqual(@as(usize, 4), report.current_profile.worker_threads);
    try std.testing.expectEqual(@as(usize, 64), report.current_profile.items_per_range);
    try std.testing.expectEqual(@as(usize, 4), report.best_profile.worker_threads);
    try std.testing.expectEqual(@as(usize, 64), report.best_profile.items_per_range);
    try std.testing.expectEqual(@as(u64, 800), report.best_mean_batch_duration_ns);
}

test "adaptive work tuner keeps best measured threaded profile through rejected probes" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .max_items_per_range = 256,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
        .improvement_threshold_percent = 5,
    });

    const request = tunerTestRequest(1024, 4, 16, 64);
    const inline_profile = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(1024, inline_profile, 1500));
    const candidate = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(1024, candidate, 1300));

    var guard: usize = 0;
    while (!tuner.isSettled() and guard < 512) : (guard += 1) {
        const rejected = tuner.selectProfile(request);
        tuner.record(tunerTestBatchWithProfile(1024, rejected, 1600));
    }

    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveWorkPhase.settled, report.phase);
    try std.testing.expectEqual(candidate.worker_threads, report.current_profile.worker_threads);
    try std.testing.expectEqual(candidate.items_per_range, report.current_profile.items_per_range);
    try std.testing.expectEqual(@as(u64, 1300), report.best_mean_batch_duration_ns);
}

test "adaptive work tuner starts threaded probing at fallback range" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
    });

    const inline_profile = tuner.selectProfile(tunerTestRequest(12_000, 4, 16, 64));
    tuner.record(tunerTestBatchWithProfile(12_000, inline_profile, 4000));

    const candidate = tuner.selectProfile(tunerTestRequest(12_000, 4, 16, 64));
    try std.testing.expectEqual(@as(usize, 4), candidate.worker_threads);
    try std.testing.expectEqual(@as(usize, 64), candidate.items_per_range);
}

test "adaptive work tuner starts cheap threaded work with conservative workers" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
    });

    const inline_profile = tuner.selectProfile(tunerTestRequest(4096, 10, 16, 64));
    tuner.record(tunerTestBatchWithProfile(4096, inline_profile, 1500));

    const candidate = tuner.selectProfile(tunerTestRequest(4096, 10, 16, 64));
    try std.testing.expectEqual(@as(usize, 2), candidate.worker_threads);
    try std.testing.expectEqual(@as(usize, 64), candidate.items_per_range);
}

test "adaptive work tuner scales worker candidates to request max" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
    });

    const inline_profile = tuner.selectProfile(tunerTestRequest(65_536, 64, 16, 64));
    tuner.record(tunerTestBatchWithProfile(65_536, inline_profile, 4000));

    const candidate = tuner.selectProfile(tunerTestRequest(65_536, 64, 16, 64));
    try std.testing.expectEqual(@as(usize, 64), candidate.worker_threads);
    try std.testing.expectEqual(@as(usize, 64), candidate.items_per_range);
}

test "adaptive work tuner measures worker threads and items_per_range together" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
    });
    const request = tunerTestRequest(16_384, 10, 16, 64);

    const inline_profile = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(16_384, inline_profile, 4000));
    const max_threads = tuner.selectProfile(request);
    try std.testing.expectEqual(@as(usize, 10), max_threads.worker_threads);
    try std.testing.expectEqual(@as(usize, 64), max_threads.items_per_range);
    tuner.record(tunerTestBatchWithProfile(16_384, max_threads, 1000));
    const smaller_range = tuner.selectProfile(request);
    try std.testing.expectEqual(@as(usize, 10), smaller_range.worker_threads);
    try std.testing.expectEqual(@as(usize, 32), smaller_range.items_per_range);
    tuner.record(tunerTestBatchWithProfile(16_384, smaller_range, 1100));
    const larger_range = tuner.selectProfile(request);
    try std.testing.expectEqual(@as(usize, 10), larger_range.worker_threads);
    try std.testing.expectEqual(@as(usize, 256), larger_range.items_per_range);
}

test "adaptive work tuner keeps faster high thread timing over slower low thread timing" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
    });
    const request = tunerTestRequest(16_384, 10, 16, 64);

    recordSyntheticTuningRun(&tuner, request, .{ .worker_threads = 10, .items_per_range = 64 }, 800, 1000);

    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveWorkPhase.settled, report.phase);
    try std.testing.expectEqual(@as(usize, 10), report.best_profile.worker_threads);
    try std.testing.expectEqual(@as(usize, 64), report.best_profile.items_per_range);
    try std.testing.expectEqual(@as(u64, 800), report.best_mean_batch_duration_ns);
}

test "adaptive work tuner can select lower thread count when timing wins" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
    });
    const request = tunerTestRequest(16_384, 10, 16, 64);

    recordSyntheticTuningRun(&tuner, request, .{ .worker_threads = 2, .items_per_range = 64 }, 700, 1000);

    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveWorkPhase.settled, report.phase);
    try std.testing.expectEqual(@as(usize, 2), report.best_profile.worker_threads);
    try std.testing.expectEqual(@as(usize, 64), report.best_profile.items_per_range);
    try std.testing.expectEqual(@as(u64, 700), report.best_mean_batch_duration_ns);
}

test "adaptive work tuner does not let one noisy low thread sample beat high thread timing" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .sample_window = 3,
        .threaded_batch_ns = 1000,
    });
    const request = tunerTestRequest(16_384, 10, 16, 64);

    recordSyntheticTuningRun(&tuner, request, .{ .worker_threads = 10, .items_per_range = 64 }, 1000, 1200);

    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveWorkPhase.settled, report.phase);
    try std.testing.expectEqual(@as(usize, 10), report.best_profile.worker_threads);
    try std.testing.expectEqual(@as(usize, 64), report.best_profile.items_per_range);
    try std.testing.expectEqual(@as(u64, 1000), report.best_mean_batch_duration_ns);
}

test "adaptive work tuner searches smaller ranges around best threaded profile" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
        .improvement_threshold_percent = 5,
    });

    const inline_profile = tuner.selectProfile(tunerTestRequest(8192, 1, 16, 64));
    tuner.record(tunerTestBatchWithProfile(8192, inline_profile, 1500));
    const first_candidate = tuner.selectProfile(tunerTestRequest(8192, 1, 16, 64));
    try std.testing.expectEqual(@as(usize, 1), first_candidate.worker_threads);
    try std.testing.expectEqual(@as(usize, 64), first_candidate.items_per_range);

    tuner.record(tunerTestBatchWithProfile(8192, first_candidate, 800));
    const second_candidate = tuner.selectProfile(tunerTestRequest(8192, 1, 16, 64));
    try std.testing.expectEqual(@as(usize, 1), second_candidate.worker_threads);
    try std.testing.expect(second_candidate.items_per_range < first_candidate.items_per_range);
    try std.testing.expect(second_candidate.items_per_range > 16);
}

test "adaptive work tuner shrink search reaches high range counts" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
    });

    const request = tunerTestRequest(65_536, 10, 16, 64);
    const inline_profile = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(65_536, inline_profile, 4000));

    var found_large_range_shape = false;
    var guard: usize = 0;
    while (!tuner.isSettled() and guard < 64) : (guard += 1) {
        const candidate = tuner.selectProfile(request);
        if (candidate.worker_threads == 10 and candidate.items_per_range <= 320) {
            found_large_range_shape = true;
            break;
        }
        tuner.record(tunerTestBatchWithProfile(65_536, candidate, @intCast(candidate.items_per_range)));
    }

    try std.testing.expect(found_large_range_shape);
}

test "adaptive work tuner keeps inline when first threaded probe loses" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .max_items_per_range = 256,
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
    try std.testing.expectEqual(@as(usize, 0), report.current_profile.worker_threads);
    try std.testing.expectEqual(@as(usize, 64), report.current_profile.items_per_range);
    try std.testing.expectEqual(@as(?AdaptiveWorkProfile, null), report.candidate_profile);
    try std.testing.expect(tuner.isSettled());
}

test "adaptive work tuner resets sample window after item count shift" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 64,
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
        .initial_items_per_range = 64,
        .sample_window = 1,
        .item_count_reset_percent = 25,
        .threaded_batch_ns = 1,
    });

    const profile = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
    tuner.record(tunerTestBatchWithProfile(1024, profile, 1000));
    try std.testing.expectEqual(AdaptiveWorkPhase.probing, tuner.report().phase);
    try std.testing.expectEqual(@as(u64, 1000), tuner.report().best_mean_batch_duration_ns);

    _ = tuner.selectProfile(tunerTestRequest(2048, 4, 16, 64));
    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveWorkPhase.learning, report.phase);
    try std.testing.expectEqual(@as(u64, 0), report.best_mean_batch_duration_ns);
    try std.testing.expectEqual(@as(usize, 64), report.best_profile.items_per_range);
}

test "adaptive work tuner item count reset starts new workload inline" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 16,
        .min_items_per_range = 16,
        .max_items_per_range = 64,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
        .improvement_threshold_percent = 5,
        .item_count_reset_percent = 25,
    });
    const request = tunerTestRequest(1024, 4, 16, 16);

    const inline_profile = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(1024, inline_profile, 1500));
    const threaded = tuner.selectProfile(request);
    tuner.record(tunerTestBatchWithProfile(1024, threaded, 800));
    var settle_guard: usize = 0;
    while (!tuner.isSettled() and settle_guard < 64) : (settle_guard += 1) {
        const candidate = tuner.selectProfile(request);
        tuner.record(tunerTestBatchWithProfile(1024, candidate, 1200));
    }
    try std.testing.expect(tuner.isSettled());
    try std.testing.expect(tuner.report().current_profile.worker_threads > 0);

    const shifted = tuner.selectProfile(tunerTestRequest(2048, 4, 16, 16));
    try std.testing.expectEqual(@as(usize, 0), shifted.worker_threads);
    try std.testing.expectEqual(AdaptiveWorkPhase.learning, tuner.report().phase);
}

test "adaptive work tuner settled threaded retune does not probe inline" {
    const inline_baseline_ns = 1500;
    const first_threaded_win_ns = 800;
    const settled_threaded_ns = 900;
    const losing_threaded_challenger_ns = 1200;
    const rejected_threaded_candidate_ns = 1000;

    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 16,
        .min_items_per_range = 16,
        .max_items_per_range = 64,
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
    try std.testing.expectEqual(AdaptiveWorkPhase.probing, tuner.report().phase);

    const threaded_candidate = tuner.selectProfile(request);
    try std.testing.expect(threaded_candidate.worker_threads > 0);
    tuner.record(tunerTestBatchWithProfile(1024, threaded_candidate, losing_threaded_challenger_ns));
    var return_guard: usize = 0;
    while (!tuner.isSettled() and return_guard < 64) : (return_guard += 1) {
        const candidate = tuner.selectProfile(request);
        tuner.record(tunerTestBatchWithProfile(1024, candidate, rejected_threaded_candidate_ns));
    }
    try std.testing.expect(tuner.isSettled());

    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveWorkPhase.settled, report.phase);
    try std.testing.expect(report.current_profile.worker_threads > 0);
}

test "adaptive work tuner retune keeps threaded profile when inline loses" {
    const inline_baseline_ns = 1500;
    const first_threaded_win_ns = 800;
    const settled_threaded_ns = 900;
    const losing_threaded_challenger_ns = 1200;

    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 16,
        .min_items_per_range = 16,
        .max_items_per_range = 64,
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
    try std.testing.expectEqual(AdaptiveWorkPhase.probing, tuner.report().phase);
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
    try std.testing.expectEqual(AdaptiveWorkPhase.settled, report.phase);
    try std.testing.expect(report.current_profile.worker_threads > 0);
}

test "adaptive work tuner resets sample window when profile changes" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 64,
        .sample_window = 4,
    });

    tuner.record(tunerTestBatchWithProfile(1024, .{ .worker_threads = 1, .items_per_range = 64 }, 1000));
    try std.testing.expectEqual(@as(usize, 1), tuner.report().sample_count);

    tuner.record(tunerTestBatchWithProfile(1024, .{ .worker_threads = 2, .items_per_range = 64 }, 1000));
    try std.testing.expectEqual(@as(usize, 1), tuner.report().sample_count);
}

test "adaptive work tuner keeps aligned items_per_range within max when possible" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 90,
        .min_items_per_range = 1,
        .max_items_per_range = 100,
    });

    const profile = tuner.selectProfile(tunerTestRequest(1024, 4, 64, 90));
    try std.testing.expectEqual(@as(usize, 64), profile.items_per_range);
}

test "adaptive work tuner reopens probing after settled cooldown" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_items_per_range = 64,
        .min_items_per_range = 16,
        .max_items_per_range = 256,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
        .retune_after_settled_windows = 2,
    });

    const inline_profile = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
    tuner.record(tunerTestBatchWithProfile(1024, inline_profile, 1500));
    const candidate = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
    tuner.record(tunerTestBatchWithProfile(1024, candidate, 1000));
    var guard: usize = 0;
    while (!tuner.isSettled() and guard < 512) : (guard += 1) {
        const rejected = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
        tuner.record(tunerTestBatchWithProfile(1024, rejected, 1500));
    }
    try std.testing.expect(tuner.isSettled());

    const settled = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64));
    tuner.record(tunerTestBatchWithProfile(1024, settled, 1500));
    try std.testing.expect(tuner.isSettled());

    tuner.record(tunerTestBatchWithProfile(1024, settled, 1500));

    const report = tuner.report();
    try std.testing.expectEqual(AdaptiveWorkPhase.probing, report.phase);
    try std.testing.expect(report.candidate_profile != null);
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
        .min_parallel_items = 1,
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
