// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Fixed worker pool plus adaptive range selection for hot CPU stages.
//! Callers own the data contract: worker jobs must write only their assigned
//! ranges or range-indexed scratch, and main-thread-only commits happen after
//! `parallelForWithOptions` returns.

const std = @import("std");
const logging = @import("../core/logging.zig");
const insertionSort = @import("../core/sort.zig").insertion;
const diagnostics_enabled = @import("runtime_perf_log.zig").enabled;
const StageTimer = @import("runtime_perf_log.zig").StageTimer;
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
    batch_duration_ns: u64 = 0,
    main_thread_wait_ns: u64 = 0,
    worker_utilization: f32 = 0,
    ran_inline: bool = true,
    /// The batch was dispatched from inside a batch of the same thread system and ran
    /// inline on its caller, with no tuner consulted or recorded.
    forced_inline: bool = false,
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

/// Inputs to `ThreadSystem.selectBatchProfile` — the single entry point every stage
/// (and `parallelForWithOptions`) uses to resolve a batch's shape. `available` and
/// the config fallback are filled from the ThreadSystem.
pub const BatchWorkRequest = struct {
    item_count: usize,
    /// Explicit range size opts out of the adaptive tuner (fixed shape).
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    range_alignment_items: usize = 1,
    adaptive: bool = true,
};

/// Fully resolved batch shape: worker count, range size, and the tuner (if any) the
/// caller must `record` this batch's `BatchStats` back to so it keeps learning.
/// `profile` mirrors `worker_threads`/`items_per_range` for callers that forward it
/// as a `selected_profile` after pre-sizing per-range output buffers.
pub const BatchSelection = struct {
    profile: AdaptiveWorkProfile,
    items_per_range: usize,
    worker_threads: usize,
    range_count: usize,
    active_tuner: ?*AdaptiveWorkTuner = null,
};

pub const AdaptiveWorkTunerConfig = struct {
    // Tuning is measurement-driven. These limits shape probing and settling, but
    // do not impose static item-count floors for threaded participation.
    initial_range_items: usize = (ThreadSystemConfig{}).items_per_range,
    smallest_range_items: usize = 1,
    largest_range_items: usize = std.math.maxInt(usize),
    /// Batches per decision window, at most `max_sample_window`.
    sample_window: usize = 3,
    threaded_commit_threshold_percent: u8 = 5,
    /// Threaded samples the throughput EMA settles over before each nudge comparison,
    /// and that a held tuner's EMA must stay beyond the band to resume stepping.
    /// `maxInt` holds the multiplier (a pinned shape).
    nudge_samples: usize = default_nudge_samples,
    /// Item-count shift that, sustained for a full sample window, relearns.
    item_count_reset_percent: u8 = 25,
    /// Window median below which an inline stage stays inline without probing, and the
    /// inline cost below which a settled threaded stage demotes (and above which a
    /// demoted one restores). Sized from the full-pool wake/join cost, not any stage.
    threaded_batch_ns: u64 = 60_000,
    /// Settled inline windows at or above the gate that pass before an inline stage
    /// probes again, after its first threaded probe lost or after a demotion.
    inline_probe_cooldown_windows: usize = 120,
    /// A fresh tuner's first selection; every later selection and record is unchanged.
    first_selection: AdaptiveFirstSelection = .learn_inline,
};

/// `learn_inline` runs a fresh tuner's first batch inline to measure its baseline;
/// `full_pool` dispatches it on every allowed worker, shaped by the cost model, for a
/// stage whose first batch is a one-off too large for main (a world-create build).
pub const AdaptiveFirstSelection = enum {
    learn_inline,
    full_pool,
};

pub const max_sample_window = 16;

// The batch-count nudge: the throughput EMA's smoothing; the samples it settles over,
// ceil(1 / alpha); the band a compared change must leave to step or flip; the
// multiplicative step; and the multiplier's clamp. The clamp spans the measured best
// shapes (about 0.5 to 4 x the pool), the step crosses it in about 29 steps, and the band
// sits above the EMA's settled noise.
const nudge_ema_alpha: f64 = 0.15;
const default_nudge_samples: usize = @intFromFloat(@ceil(1.0 / nudge_ema_alpha));
const nudge_band: f64 = 0.05;
// The band a stepped comparison judges: `nudge_samples` after a step the EMA still carries
// (1 - alpha)^N of the previous shape, so a true change r moves it by r (1 - (1 - alpha)^N).
const nudge_stepped_band: f64 = nudge_band * (1 - std.math.pow(f64, 1 - nudge_ema_alpha, @floatFromInt(default_nudge_samples)));
const nudge_step: f64 = 1.1;
const min_batch_multiplier: f64 = 0.25;
// The first step goes to fewer batches. Up from the whole pool, workers stay capped and
// only the batch size shrinks, which rarely moves throughput past the band, so a stage
// that wants fewer workers would hold at the pool; down, workers drop with the batches,
// and a loss flips the nudge up past the start (measured: light stages ran 9-16 workers
// on the old climb and held at the full pool when the nudge stepped up first).
const initial_nudge_direction: i8 = -1;
const max_batch_multiplier: f64 = 4.0;

const NudgeState = enum {
    // Before the first step: the EMA settles, then the first reference is taken.
    measuring,
    stepped,
    holding,
};

// Batches per participant of a fresh `full_pool` tuner's first selection, a one-off no
// nudge follows, so it carries load-balance headroom. Measured among 1, 2, and 4 on the
// static rebuild and world-create benches: 2 stayed within spread of the replaced shape on
// every size in both runs; 1 (rebuild 65,536) and 4 (world-create 2,048) each fell outside
// it in one.
const full_pool_batches_per_participant: usize = 2;

pub const AdaptiveWorkPhase = enum {
    learning,
    probing,
    settled,
};

// An unsustained jump's held profile and the counts it was predicted between. The held
// profile starts at the model's prediction; the jump's own skipped records judge it
// (`judgeJump`), final after at most two.
const JumpProfile = struct {
    learned_item_count: usize,
    item_count: usize,
    profile: AdaptiveWorkProfile,
    // The jump's threaded shape (`batchShape`); no workers when no two batches fit or no
    // worker may run.
    threaded_profile: AdaptiveWorkProfile,
    // The jump's measured inline and threaded batch durations; 0 is not measured.
    inline_ns: u64 = 0,
    threaded_ns: u64 = 0,
    // Set once the records decide `profile`; it then holds while the counts repeat.
    judged: bool = false,
};

// The default floors the learned participant overhead in the prediction;
// `min_participant_overhead_ns` floors each learned participant sample.
const default_participant_overhead_ns: f64 = 1_000;
const min_participant_overhead_ns: f64 = 100;

/// Cumulative tuner diagnostic count: `u64` where perf instrumentation is
/// compiled in, zero-sized (and never written) in ReleaseFast/ReleaseSmall.
pub const DiagnosticCount = if (diagnostics_enabled) u64 else void;
const zero_diagnostic_count: DiagnosticCount = if (diagnostics_enabled) 0 else {};

pub const AdaptiveWorkRequest = struct {
    item_count: usize,
    available_worker_threads: usize,
    max_worker_threads: usize,
    fallback_items_per_range: usize,
    range_alignment_items: usize,
};

pub const AdaptiveWorkTuner = struct {
    config: AdaptiveWorkTunerConfig,
    // The tuner starts with inline measurement and probes threading when the inline
    // window reaches the gate; a threaded stage then nudges its batch count by measured
    // throughput and never settles its shape for good.
    phase: AdaptiveWorkPhase = .learning,
    initial_profile: AdaptiveWorkProfile,
    // The threaded shape selection dispatches while `has_threaded_profile`; rewritten
    // only when the nudge steps, a probe commits, a restore lands, or a count shift
    // reshapes it.
    current_profile: AdaptiveWorkProfile,
    candidate_profile: ?AdaptiveWorkProfile = null,
    baseline_mean_batch_duration_ns: u64 = 0,
    has_threaded_profile: bool = false,
    sample_count: usize = 0,
    // Representative batch duration for phase decisions is the window MEDIAN: one
    // slow frame (cold start, contention) or one near-free batch in the window
    // never decides the profile alone. A window holds inline or threaded batches only;
    // threaded batches of different shapes share it.
    sample_durations_ns: [max_sample_window]u64 = undefined,
    // Each sampled batch's participants (workers + main), for the bound rule's
    // duration x participants upper bound on its inline cost.
    sample_participants: [max_sample_window]u16 = undefined,
    inline_probe_cooldown_windows: usize = 0,
    // Item count of the learned workload. A batch outside the reset band is
    // dispatched but not sampled; a full window of them in a row on the same side
    // is a sustained shift.
    learned_item_count: usize = 0,
    shifted_batch_count: usize = 0,
    shifted_up: bool = false,
    skip_next_record: bool = false,
    last_request: ?AdaptiveWorkRequest = null,
    // The last sampled batch's shape; the window resets when it switches between
    // inline and threaded.
    sampled_profile: ?AdaptiveWorkProfile = null,
    model_work_ns_per_item: f64 = 0,
    // Learned from threaded batches; decides with the per-item model whether threading
    // pays (`predictsThreaded`), never the shape.
    model_participant_overhead_ns: f64 = 0,
    // The batch count as a multiple of the pool's participants. The nudge moves it by
    // `nudge_step` against measured throughput; a relearn resets it.
    batch_multiplier: f64 = 1,
    // The nudge's throughput EMA (items per ns) over threaded batches, its reference (the
    // EMA and multiplier just before the last step, or at the hold), and its state.
    throughput_ema: f64 = 0,
    reference_ema: f64 = 0,
    reference_multiplier: f64 = 1,
    nudge_direction: i8 = initial_nudge_direction,
    nudge_state: NudgeState = .measuring,
    // Threaded samples since the last step (or, holding, in a row beyond the band).
    nudge_samples: usize = 0,
    // The threaded policy a settled demotion dropped, held until the first full
    // inline settled window judges it. Set only while settled and not threaded,
    // always with workers; cleared on entering probing or learning.
    restore_threaded_profile: ?AdaptiveWorkProfile = null,
    // Set by a restore: the measured inline window was over the gate, so the bound rule is
    // skipped until a changed workload (a sustained item-count shift or a relearn).
    // Implies `has_threaded_profile`.
    bound_rule_suppressed: bool = false,
    // Set by a sustained item-count shift on a threaded stage: the next threaded settled
    // window re-decides inline or threaded at the new count.
    retune_pending: bool = false,
    // The shape the last unsustained jump up holds, reused while its learned and requested
    // counts repeat, so the same jump dispatches alike under model jitter: the model's
    // prediction until the jump's own records judge it. A sustained shift changes the
    // learned count and so re-predicts it.
    jump_profile: ?JumpProfile = null,
    // Diagnostics only: cumulative over the tuner's life (no reset path clears
    // them) and never read by policy.
    probe_window_count: DiagnosticCount = zero_diagnostic_count,
    demotion_count: DiagnosticCount = zero_diagnostic_count,
    // Settled demotions undone by their judging window, and batches outside the reset
    // band whose record was skipped (an unsustained item-count shift).
    restore_count: DiagnosticCount = zero_diagnostic_count,
    shift_skip_count: DiagnosticCount = zero_diagnostic_count,
    // Batches with items handed to `record`, sampled or skipped (an unsustained shift):
    // cumulative, never read by policy.
    record_count: DiagnosticCount = zero_diagnostic_count,

    pub fn init(config: AdaptiveWorkTunerConfig) AdaptiveWorkTuner {
        const normalized = normalizeWorkTunerConfig(config);
        const initial = std.math.clamp(normalized.initial_range_items, normalized.smallest_range_items, normalized.largest_range_items);
        const profile = AdaptiveWorkProfile{
            .worker_threads = 1,
            .items_per_range = initial,
        };
        return .{
            .config = normalized,
            .initial_profile = profile,
            .current_profile = profile,
        };
    }

    pub fn selectProfile(self: *AdaptiveWorkTuner, request: AdaptiveWorkRequest) AdaptiveWorkProfile {
        const normalized_request = self.normalizeRequest(request);
        self.last_request = normalized_request;
        self.skip_next_record = false;
        const fresh_full_pool = self.learned_item_count == 0 and self.config.first_selection == .full_pool;
        if (self.learned_item_count == 0) {
            self.learned_item_count = normalized_request.item_count;
        } else if (outsideBand(self.learned_item_count, normalized_request.item_count, self.config.item_count_reset_percent)) {
            const up = normalized_request.item_count > self.learned_item_count;
            if (self.shifted_batch_count > 0 and up != self.shifted_up) self.shifted_batch_count = 0;
            self.shifted_up = up;
            self.shifted_batch_count += 1;
            if (self.shifted_batch_count >= self.config.sample_window) {
                if (self.has_threaded_profile) {
                    self.bound_rule_suppressed = false;
                    self.requestRetune(normalized_request);
                } else {
                    self.resetForLearning();
                }
                self.learned_item_count = normalized_request.item_count;
                self.shifted_batch_count = 0;
            } else {
                self.skip_next_record = true;
                if (comptime diagnostics_enabled) self.shift_skip_count += 1;
            }
        } else {
            self.shifted_batch_count = 0;
        }

        if (fresh_full_pool) return self.poolProfile(normalized_request, @floatFromInt(full_pool_batches_per_participant));
        // An unsustained jump up on a tuner without a threaded profile runs at the shape the
        // per-item model predicts for the new count, not inline; its record trains nothing,
        // it judges the held shape (`judgeJump`). A tuner with a threaded profile
        // re-normalizes that profile.
        if (self.jumpSelected()) {
            const repeated = if (self.jump_profile) |jump|
                jump.learned_item_count == self.learned_item_count and jump.item_count == normalized_request.item_count
            else
                false;
            if (!repeated) self.jump_profile = .{
                .learned_item_count = self.learned_item_count,
                .item_count = normalized_request.item_count,
                .profile = self.predictProfile(normalized_request),
                .threaded_profile = self.batchShape(normalized_request),
            };
            return self.normalizedProfile(self.jump_profile.?.profile, normalized_request);
        }

        const selected = switch (self.phase) {
            .learning, .settled => if (self.has_threaded_profile) self.current_profile else inlineProfile(normalized_request),
            .probing => self.candidate_profile orelse inlineProfile(normalized_request),
        };
        return self.normalizedProfile(selected, normalized_request);
    }

    pub fn record(self: *AdaptiveWorkTuner, stats: BatchStats) void {
        if (stats.item_count == 0) return;
        if (comptime diagnostics_enabled) self.record_count += 1;
        if (stats.batch_duration_ns == 0) return;
        if (self.skip_next_record) {
            if (self.jumpSelected()) self.judgeJump(stats);
            self.skip_next_record = false;
            return;
        }

        // Inline is one profile: a tuner-selected inline batch runs as one
        // item_count-wide range, so its range width says nothing about policy.
        const threaded = stats.active_worker_threads > 0;
        const profile = AdaptiveWorkProfile{
            .worker_threads = stats.active_worker_threads,
            .items_per_range = if (threaded) stats.items_per_range else 0,
        };
        if (self.sampled_profile) |sampled| {
            if ((sampled.worker_threads > 0) != threaded) self.resetSamples();
        }
        self.sampled_profile = profile;

        self.sample_durations_ns[self.sample_count] = stats.batch_duration_ns;
        self.sample_participants[self.sample_count] = @intCast(@min(stats.active_worker_threads + 1, std.math.maxInt(u16))); // saturated to the field's width
        self.sample_count += 1;
        self.updateCostModel(stats);
        if (threaded) self.nudge(stats);
        if (self.sample_count < self.config.sample_window) return;

        const sample_ns = self.sampleMedian();
        switch (self.phase) {
            .learning => self.finishLearningWindow(sample_ns),
            .probing => {
                if (comptime diagnostics_enabled) self.probe_window_count += 1;
                self.finishProfileWindow(sample_ns);
            },
            .settled => self.finishSettledWindow(sample_ns),
        }
        self.resetSamples();
    }

    // Whether the selection took the unsustained-jump branch. None of its inputs change
    // between a select and its record, so `record` reads the same answer.
    fn jumpSelected(self: *const AdaptiveWorkTuner) bool {
        return self.skip_next_record and self.shifted_up and !self.has_threaded_profile and self.model_work_ns_per_item > 0;
    }

    // A repeated jump's skipped record judges its held shape by the gate, the bound rule,
    // and the commit margin; final after at most two records. An inline record under the
    // gate holds inline; at or above it the repeat probes the threaded shape. A threaded
    // record whose bound is under the gate holds inline, one whose duration reaches the
    // gate holds threaded, and one under the gate whose bound is not runs inline once. With
    // one record of each shape the threaded one holds only if the inline one reached the
    // gate and it beats it by the commit margin. A second record of the shape already
    // measured (a threaded probe that ran inline) holds the shape it measured, so no held
    // shape is unmeasured.
    fn judgeJump(self: *AdaptiveWorkTuner, stats: BatchStats) void {
        const jump = &self.jump_profile.?; // the jump branch sets it at the select
        const request = self.last_request.?; // the select sets it before the jump branch
        std.debug.assert(jump.learned_item_count == self.learned_item_count and jump.item_count == request.item_count);
        if (jump.judged) return;
        const gate = self.config.threaded_batch_ns;
        const duration_ns = stats.batch_duration_ns;
        const threaded = stats.active_worker_threads > 0;
        const measured = if (threaded) &jump.threaded_ns else &jump.inline_ns;
        const repeat = measured.* != 0;
        measured.* = duration_ns;
        const inline_profile = inlineProfile(request);
        if (repeat) {
            // A repeated threaded record ran the held shape, so it keeps it.
            if (!threaded) jump.profile = inline_profile;
            jump.judged = true;
            return;
        }
        if (jump.inline_ns != 0 and jump.threaded_ns != 0) {
            const threaded_wins = jump.inline_ns >= gate and isMeaningfullyFaster(jump.threaded_ns, jump.inline_ns, self.config.threaded_commit_threshold_percent);
            jump.profile = if (threaded_wins) jump.threaded_profile else inline_profile;
            jump.judged = true;
        } else if (!threaded) {
            const probe = duration_ns >= gate and jump.threaded_profile.worker_threads > 0;
            jump.profile = if (probe) jump.threaded_profile else inline_profile;
            jump.judged = !probe;
        } else {
            // Participants >= 2, so a bound under the gate implies a duration under it.
            const bound_under_gate = @as(u128, duration_ns) * (stats.active_worker_threads + 1) < gate;
            if (duration_ns < gate) jump.profile = inline_profile;
            jump.judged = bound_under_gate or duration_ns >= gate;
        }
    }

    // Learning establishes the baseline for the sampled profile. Cheap inline work
    // settles at once; a threaded window (a full-pool first selection) is adopted.
    fn finishLearningWindow(self: *AdaptiveWorkTuner, sample_mean_ns: u64) void {
        const profile = self.sampled_profile orelse self.current_profile;
        self.baseline_mean_batch_duration_ns = sample_mean_ns;
        if (profile.worker_threads == 0 and sample_mean_ns < self.config.threaded_batch_ns) {
            self.settle();
            return;
        }
        if (profile.worker_threads > 0) self.adoptThreaded(profile);
        self.decideThreading();
    }

    // The first threaded probe becomes policy only when it beats the inline baseline by
    // the threaded commit margin; a loss stays inline and cools down before a retry.
    fn finishProfileWindow(self: *AdaptiveWorkTuner, sample_mean_ns: u64) void {
        std.debug.assert(!self.has_threaded_profile);
        const candidate = self.candidate_profile orelse {
            self.settle();
            return;
        };
        const sampled_threaded = if (self.sampled_profile) |sampled| sampled.worker_threads > 0 else false;
        if (sampled_threaded and isMeaningfullyFaster(sample_mean_ns, self.baseline_mean_batch_duration_ns, self.config.threaded_commit_threshold_percent)) {
            self.adoptThreaded(candidate);
            self.baseline_mean_batch_duration_ns = sample_mean_ns;
            self.inline_probe_cooldown_windows = 0;
        } else {
            self.inline_probe_cooldown_windows = self.config.inline_probe_cooldown_windows;
            // A threaded probe that lost to inline: the next probe tries half the batches.
            if (sampled_threaded) self.batch_multiplier = @max(self.batch_multiplier / 2, min_batch_multiplier);
            self.restartNudge();
        }
        self.settle();
    }

    // Settled profiles keep sampling. An inline stage probes threading when its window
    // reaches the gate; a threaded one demotes on the bound rule and re-decides inline or
    // threaded on the first window after a sustained item-count shift.
    fn finishSettledWindow(self: *AdaptiveWorkTuner, sample_mean_ns: u64) void {
        const profile = self.sampled_profile orelse self.current_profile;
        self.baseline_mean_batch_duration_ns = sample_mean_ns;

        if (profile.worker_threads == 0) {
            if (self.restore_threaded_profile) |restore_profile| {
                self.restore_threaded_profile = null;
                // A profile that normalizes to inline at the judging window's count
                // cannot dispatch threaded, so that demotion stands.
                const dispatches_threaded = if (self.last_request) |request|
                    self.normalizedProfile(restore_profile, request).worker_threads > 0
                else
                    false;
                if (!self.has_threaded_profile and dispatches_threaded and sample_mean_ns >= self.config.threaded_batch_ns) {
                    self.restoreThreadedProfile(restore_profile);
                    return;
                }
            }
            // A threaded profile whose shape normalizes to one range at an in-band count
            // runs this window inline and keeps its profile.
            if (!self.has_threaded_profile and sample_mean_ns >= self.config.threaded_batch_ns) {
                if (self.inline_probe_cooldown_windows > 0) {
                    self.inline_probe_cooldown_windows -= 1;
                    return;
                }
                self.decideThreading();
            }
            return;
        }
        if (sample_mean_ns >= self.config.threaded_batch_ns and !self.has_threaded_profile) {
            self.adoptThreaded(profile);
            self.decideThreading();
            return;
        }
        // Bound rule, with no inline backprobe: a settled threaded window whose median
        // batch duration x its participants, an upper bound on its inline cost, is below
        // the gate demotes. A wrong demotion is judged by the first inline window, which
        // restores it.
        std.debug.assert(!self.bound_rule_suppressed or self.has_threaded_profile);
        std.debug.assert(!(self.retune_pending and self.bound_rule_suppressed));
        if (!self.bound_rule_suppressed and self.windowInlineBoundNs() < self.config.threaded_batch_ns) {
            self.demoteToInline();
            return;
        }
        if (self.retune_pending) {
            self.retune_pending = false;
            self.decideThreading();
            return;
        }
        // A threaded window the tuner did not select is adopted as the threaded profile.
        if (!self.has_threaded_profile) self.adoptThreaded(profile);
    }

    // Inline or threaded, from the model: a threaded tuner that predicts inline demotes
    // and otherwise keeps its shape; an inline one probes the multiplier's shape.
    fn decideThreading(self: *AdaptiveWorkTuner) void {
        std.debug.assert(!self.bound_rule_suppressed);
        self.restore_threaded_profile = null;
        const request = self.last_request orelse {
            self.settle();
            return;
        };
        if (!self.predictsThreaded(request)) {
            if (self.has_threaded_profile) {
                self.demoteToInline();
            } else {
                self.settle();
            }
            return;
        }
        if (self.has_threaded_profile) {
            self.settle();
            return;
        }
        const candidate = self.batchShape(request);
        if (candidate.worker_threads == 0) {
            self.settle();
            return;
        }
        self.candidate_profile = candidate;
        self.phase = .probing;
    }

    fn adoptThreaded(self: *AdaptiveWorkTuner, profile: AdaptiveWorkProfile) void {
        std.debug.assert(profile.worker_threads > 0);
        self.has_threaded_profile = true;
        self.current_profile = profile;
    }

    // The median over the window of each batch's duration x its participants.
    fn windowInlineBoundNs(self: *const AdaptiveWorkTuner) u128 {
        std.debug.assert(self.sample_count > 0 and self.sample_count <= max_sample_window);
        if (self.sample_count == 3) return self.sampleBoundNs(medianIndexOfThree(u128, .{ self.sampleBoundNs(0), self.sampleBoundNs(1), self.sampleBoundNs(2) }));
        var order: [max_sample_window]u8 = undefined;
        for (order[0..self.sample_count], 0..) |*slot, index| slot.* = @intCast(index); // index < max_sample_window
        insertionSort(u8, order[0..self.sample_count], self, sampleBoundLess);
        return self.sampleBoundNs(order[(self.sample_count - 1) / 2]);
    }

    fn sampleBoundNs(self: *const AdaptiveWorkTuner, index: u8) u128 {
        return @as(u128, self.sample_durations_ns[index]) * self.sample_participants[index];
    }

    fn sampleBoundLess(self: *const AdaptiveWorkTuner, left: u8, right: u8) bool {
        return self.sampleBoundNs(left) < self.sampleBoundNs(right);
    }

    // One threaded batch: its throughput (items per ns), clipped to within twice the band
    // of the EMA so one outlier batch never decides a comparison, feeds the EMA.
    // `nudge_samples` threaded samples after each step, the EMA is compared with the
    // reference taken just before it: better by more than the band keeps the direction and
    // steps again, worse flips it and steps from the reference past it, inside the band
    // holds. A held tuner resumes stepping after `nudge_samples` samples in a row beyond the
    // band.
    fn nudge(self: *AdaptiveWorkTuner, stats: BatchStats) void {
        const throughput = @as(f64, @floatFromInt(stats.item_count)) / @as(f64, @floatFromInt(stats.batch_duration_ns));
        self.throughput_ema = if (self.throughput_ema <= 0)
            throughput
        else
            ewma(self.throughput_ema, std.math.clamp(throughput, self.throughput_ema * (1 - 2 * nudge_band), self.throughput_ema * (1 + 2 * nudge_band)), nudge_ema_alpha);
        self.nudge_samples +|= 1;
        switch (self.nudge_state) {
            .measuring => if (self.nudge_samples >= self.config.nudge_samples) self.stepMultiplier(self.batch_multiplier),
            .stepped => if (self.nudge_samples >= self.config.nudge_samples) {
                const change = (self.throughput_ema - self.reference_ema) / self.reference_ema;
                if (change > nudge_stepped_band) {
                    self.stepMultiplier(self.batch_multiplier);
                } else if (change < -nudge_stepped_band) {
                    self.nudge_direction = -self.nudge_direction;
                    self.stepMultiplier(self.reference_multiplier);
                } else {
                    self.nudge_state = .holding;
                    self.reference_ema = self.throughput_ema;
                    self.reference_multiplier = self.batch_multiplier;
                    self.nudge_samples = 0;
                }
            },
            .holding => {
                const departure = @abs(self.throughput_ema - self.reference_ema) / self.reference_ema;
                if (departure <= nudge_band) {
                    self.nudge_samples = 0;
                } else if (self.nudge_samples >= self.config.nudge_samples) {
                    self.stepMultiplier(self.batch_multiplier);
                }
            },
        }
    }

    // Takes the reference (the EMA and multiplier now), then steps from `from` in the
    // current direction until the batch shape differs from the dispatched one, so no
    // comparison measures a shape against itself; the threaded shape follows at the last
    // request's count. A clamp reached first reverses the direction and holds there; a
    // flip whose step back starts at the clamp holds at the reference's own shape, judged
    // against the EMA measured there.
    fn stepMultiplier(self: *AdaptiveWorkTuner, from: f64) void {
        const previous_reference_ema = self.reference_ema;
        self.reference_ema = self.throughput_ema;
        self.reference_multiplier = self.batch_multiplier;
        self.nudge_samples = 0;
        const factor = if (self.nudge_direction > 0) nudge_step else 1.0 / nudge_step;
        const request = self.last_request;
        const dispatched = if (self.has_threaded_profile) self.current_profile else self.candidate_profile;
        var multiplier = from;
        self.nudge_state = while (true) {
            const stepped = std.math.clamp(multiplier * factor, min_batch_multiplier, max_batch_multiplier);
            if (stepped == multiplier) {
                if (multiplier != self.batch_multiplier and multiplier == from) self.reference_ema = previous_reference_ema;
                self.reference_multiplier = multiplier;
                self.nudge_direction = -self.nudge_direction;
                break .holding;
            }
            multiplier = stepped;
            const shaped_request = request orelse break .stepped;
            const current = dispatched orelse break .stepped;
            if (!profilesEqual(self.poolProfile(shaped_request, multiplier), self.normalizedProfile(current, shaped_request))) break .stepped;
        };
        self.batch_multiplier = multiplier;
        const shaped_request = request orelse return;
        self.reshapeThreaded(shaped_request);
        // A stepped multiplier restates the shape it dispatches, so range clamps and
        // alignment never leave it far from that shape for a later count shift.
        if (self.nudge_state == .stepped) {
            const shape = self.batchShape(shaped_request);
            if (shape.worker_threads > 0) {
                const ranges: f64 = @floatFromInt(rangeCount(shaped_request.item_count, shape.items_per_range));
                const participants: f64 = @floatFromInt(shaped_request.max_worker_threads + 1);
                self.batch_multiplier = std.math.clamp(ranges / participants, min_batch_multiplier, max_batch_multiplier);
            }
        }
    }

    // Starts the nudge's measurement over: the next threaded batch reseeds the EMA, which
    // settles before the first step. The multiplier and direction are kept.
    fn restartNudge(self: *AdaptiveWorkTuner) void {
        self.throughput_ema = 0;
        self.reference_ema = 0;
        self.reference_multiplier = self.batch_multiplier;
        self.nudge_state = .measuring;
        self.nudge_samples = 0;
    }

    // The threaded shape (or the probe in flight) at the multiplier's batch count for
    // `request`.
    fn reshapeThreaded(self: *AdaptiveWorkTuner, request: AdaptiveWorkRequest) void {
        const shape = self.batchShape(request);
        if (shape.worker_threads == 0) return;
        if (self.has_threaded_profile) self.current_profile = shape;
        if (self.phase == .probing) self.candidate_profile = shape;
    }

    // The model's start shape: the multiplier's batch count when threading pays, else
    // inline.
    fn predictProfile(self: *const AdaptiveWorkTuner, request: AdaptiveWorkRequest) AdaptiveWorkProfile {
        if (!self.predictsThreaded(request)) return self.normalizedProfile(inlineProfile(request), request);
        return self.batchShape(request);
    }

    // The whole pool's participants x the multiplier, rounded, as batches; inline when
    // no two batches fit.
    fn batchShape(self: *const AdaptiveWorkTuner, request: AdaptiveWorkRequest) AdaptiveWorkProfile {
        return self.poolProfile(request, self.batch_multiplier);
    }

    fn estimatedWorkNs(self: *const AdaptiveWorkTuner, request: AdaptiveWorkRequest) f64 {
        const item_count_f: f64 = @floatFromInt(request.item_count);
        const work_ns_per_item = if (self.model_work_ns_per_item > 0)
            self.model_work_ns_per_item
        else if (self.baseline_mean_batch_duration_ns > 0)
            @as(f64, @floatFromInt(self.baseline_mean_batch_duration_ns)) / item_count_f
        else
            @as(f64, @floatFromInt(self.config.threaded_batch_ns)) / item_count_f;
        return @max(work_ns_per_item * item_count_f, 1);
    }

    // Whether the cost model predicts threading pays for the measured work: at or above
    // the gate, and its sqrt participant estimate beats inline after the per-participant
    // overhead. It decides inline or threaded only, never the shape. There is
    // deliberately NO item-count floor here: a static floor would fight the measurement.
    fn predictsThreaded(self: *const AdaptiveWorkTuner, request: AdaptiveWorkRequest) bool {
        if (request.max_worker_threads == 0) return false;
        const estimated_work_ns = self.estimatedWorkNs(request);
        if (estimated_work_ns < @as(f64, @floatFromInt(self.config.threaded_batch_ns))) return false;
        const participant_overhead_ns = @max(self.model_participant_overhead_ns, default_participant_overhead_ns);
        const ideal_participants_f = @sqrt(estimated_work_ns / participant_overhead_ns);
        const participants = std.math.clamp(roundedUsize(ideal_participants_f), 1, request.max_worker_threads + 1);
        if (participants <= 1) return false;
        const predicted_threaded_ns = estimated_work_ns / @as(f64, @floatFromInt(participants)) +
            participant_overhead_ns * @as(f64, @floatFromInt(participants - 1));
        return predicted_threaded_ns < estimated_work_ns;
    }

    // The whole pool's participants x `batches_per_participant`, rounded, as batches,
    // shaped by `profileForRangeCount` (workers follow the batches); inline when no two
    // batches fit or no worker may run.
    fn poolProfile(self: *const AdaptiveWorkTuner, request: AdaptiveWorkRequest, batches_per_participant: f64) AdaptiveWorkProfile {
        const participants: f64 = @floatFromInt(request.max_worker_threads + 1);
        return self.profileForRangeCount(request, roundedUsize(participants * batches_per_participant)) orelse
            self.normalizedProfile(inlineProfile(request), request);
    }

    // The threaded profile with `ranges` batches clamped to [2, maxRangeCount], each at
    // least one alignment unit, and a worker per batch beyond main's, up to the pool. Null
    // when no two aligned batches fit or no worker may run.
    fn profileForRangeCount(self: *const AdaptiveWorkTuner, request: AdaptiveWorkRequest, ranges: usize) ?AdaptiveWorkProfile {
        if (request.max_worker_threads == 0) return null;
        const max_ranges = maxRangeCount(request.item_count, request.range_alignment_items);
        if (max_ranges < 2) return null;
        const profile = self.normalizedProfile(.{
            .worker_threads = request.max_worker_threads,
            .items_per_range = targetRangeSizeForRangeCount(request.item_count, std.math.clamp(ranges, 2, max_ranges)),
        }, request);
        if (profile.worker_threads == 0) return null;
        return profile;
    }

    // Inline batches teach per-item work. Threaded batches add the participant overhead
    // estimate the threading decision reads.
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
        const participant_observed = non_tail_overhead_ns / @as(f64, @floatFromInt(@max(participants, @as(usize, 1))));
        self.model_participant_overhead_ns = ewma(
            self.model_participant_overhead_ns,
            @max(participant_observed, min_participant_overhead_ns),
            0.25,
        );

        // Per-item work is learned from inline batches (early return above); before
        // any inline batch, the first threaded batch seeds it with its duration x
        // participants upper bound. Later threaded batches never update it: their
        // participant overhead would inflate it, over-predicting workers and
        // defeating the prediction-driven demotion.
    }

    fn settle(self: *AdaptiveWorkTuner) void {
        self.phase = .settled;
        self.candidate_profile = null;
    }

    // The bound rule (or a threading decision predicting inline) says inline is cheap
    // enough: drop the threaded policy so selectProfile returns inline, WITHOUT ever
    // running an inline probe while threaded. The dropped policy is remembered: the first
    // inline window judges it, and one at or above the gate restores it at once with no
    // cooldown. The cooldown applies only after a confirmed demotion, blocking re-probing
    // off a stale slow sample. The multiplier is kept; its measurement restarts.
    fn demoteToInline(self: *AdaptiveWorkTuner) void {
        if (comptime diagnostics_enabled) self.demotion_count += 1;
        self.restore_threaded_profile = if (self.has_threaded_profile and self.current_profile.worker_threads > 0)
            self.current_profile
        else
            null;
        self.bound_rule_suppressed = false;
        self.retune_pending = false;
        self.phase = .settled;
        self.has_threaded_profile = false;
        self.current_profile = self.initial_profile;
        self.candidate_profile = null;
        self.inline_probe_cooldown_windows = self.config.inline_probe_cooldown_windows;
        self.restartNudge();
    }

    // The judging inline window measured at least the dispatch floor, so the demotion
    // was wrong: the threaded policy comes back without a probe, and the bound rule waits
    // for a changed workload (a sustained item-count shift or relearn).
    fn restoreThreadedProfile(self: *AdaptiveWorkTuner, profile: AdaptiveWorkProfile) void {
        std.debug.assert(self.phase == .settled and profile.worker_threads > 0);
        if (comptime diagnostics_enabled) self.restore_count += 1;
        self.adoptThreaded(profile);
        self.inline_probe_cooldown_windows = 0;
        self.bound_rule_suppressed = true;
        self.retune_pending = false;
    }

    // A sustained item-count shift keeps a won threaded profile, reshapes it from the
    // multiplier at the new count, and re-decides inline or threaded on the next window.
    fn requestRetune(self: *AdaptiveWorkTuner, request: AdaptiveWorkRequest) void {
        if (self.phase != .settled) self.settle();
        self.reshapeThreaded(request);
        self.retune_pending = true;
        self.resetSamples();
        self.restartNudge();
    }

    // Workload shifts clear learned policy and samples. The next selection starts from
    // inline learning against the new item-count regime, at a multiplier of one.
    fn resetForLearning(self: *AdaptiveWorkTuner) void {
        self.phase = .learning;
        self.current_profile = self.initial_profile;
        self.candidate_profile = null;
        self.restore_threaded_profile = null;
        self.bound_rule_suppressed = false;
        self.retune_pending = false;
        self.has_threaded_profile = false;
        self.baseline_mean_batch_duration_ns = 0;
        self.inline_probe_cooldown_windows = 0;
        self.batch_multiplier = 1;
        self.nudge_direction = initial_nudge_direction;
        self.restartNudge();
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
        const clamped = std.math.clamp(@max(items_per_range, @as(usize, 1)), self.config.smallest_range_items, self.config.largest_range_items);
        const aligned_up = std.mem.alignForwardAnyAlign(usize, clamped, alignment);
        if (aligned_up <= self.config.largest_range_items) return aligned_up;

        const aligned_max = std.mem.alignBackwardAnyAlign(usize, self.config.largest_range_items, alignment);
        if (aligned_max >= self.config.smallest_range_items) return aligned_max;
        return clamped;
    }

    fn resetSamples(self: *AdaptiveWorkTuner) void {
        self.sample_count = 0;
        self.sampled_profile = null;
    }

    // Window position of the lower median duration; `sample_count` is at most
    // `max_sample_window`, so the sort is a fixed small cost per window.
    fn sampleMedianIndex(self: *const AdaptiveWorkTuner) usize {
        std.debug.assert(self.sample_count > 0 and self.sample_count <= max_sample_window);
        if (self.sample_count == 3) return medianIndexOfThree(u64, self.sample_durations_ns[0..3].*);
        var order: [max_sample_window]u8 = undefined;
        for (order[0..self.sample_count], 0..) |*slot, index| slot.* = @intCast(index); // index < max_sample_window
        insertionSort(u8, order[0..self.sample_count], self, sampleDurationLess);
        return order[(self.sample_count - 1) / 2];
    }

    fn sampleDurationLess(self: *const AdaptiveWorkTuner, left: u8, right: u8) bool {
        return self.sample_durations_ns[left] < self.sample_durations_ns[right];
    }

    fn sampleMedian(self: *const AdaptiveWorkTuner) u64 {
        return self.sample_durations_ns[self.sampleMedianIndex()];
    }
};

pub const JobFn = *const fn (*anyopaque, ParallelRange, WorkerId) void;

// How a thread calling into a `ThreadSystem` may run a batch: the owner outside any of
// its batches dispatches normally; a participant of one of its batches (the owner in its
// own ranges, or one of its workers) runs the nested batch inline on its own `WorkerId`.
const CallerRole = union(enum) {
    owner,
    nested: WorkerId,
};

/// Fork-join pool owned by the thread that calls `init`. Only the owner, or a job running
/// in one of this system's batches, may call `selectBatchProfile` or
/// `parallelForWithOptions`; any other thread panics in every build mode. A call from
/// inside a batch runs inline on its caller, never touching a tuner, over the selected
/// profile's ranges, or the untuned fixed shape when none is given.
pub const ThreadSystem = struct {
    allocator: std.mem.Allocator,
    config: ThreadSystemConfig,
    // Batch state shared with the workers; jobs run over caller-owned ranges.
    shared: *Shared,
    workers: []WorkerRecord = &.{},
    owner_thread_id: std.Thread.Id,
    // Owner-only: read only after the caller matched `owner_thread_id`. True while the
    // owner runs ranges of one of this system's batches.
    owner_in_batch: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: ThreadSystemConfig) !ThreadSystem {
        const worker_thread_count = try resolveWorkerThreadCount(config.max_worker_threads);
        const shared = try allocator.create(Shared);
        errdefer allocator.destroy(shared);
        shared.* = .{ .descriptor = .{ .io = io } };

        const workers = try allocator.alloc(WorkerRecord, worker_thread_count);
        errdefer allocator.free(workers);

        var self = ThreadSystem{
            .allocator = allocator,
            .config = normalizeConfig(config),
            .shared = shared,
            .workers = workers,
            .owner_thread_id = std.Thread.getCurrentId(),
        };
        @memset(self.workers, WorkerRecord{});

        var spawned: usize = 0;
        errdefer {
            self.shared.descriptor.accepting_work.store(false, .release);
            for (self.workers[0..spawned]) |*worker| {
                worker.wake.post(io);
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
            // Startup permit: the worker reads `worker.thread` only after taking it.
            worker.wake.post(io);
        }

        log.debug(
            "ThreadSystem initialized: worker_threads={} items_per_range={} stack_size={}",
            .{ self.workers.len, self.config.items_per_range, self.config.stack_size },
        );
        return self;
    }

    /// Owner only, outside any of its batches. Stops and joins every worker.
    pub fn deinit(self: *ThreadSystem) void {
        std.debug.assert(std.Thread.getCurrentId() == self.owner_thread_id and !self.owner_in_batch);
        const io = self.shared.descriptor.io;
        std.debug.assert(self.shared.completion.pending.load(.monotonic) == 0);
        // Shutdown permits are counted, so a pending startup permit never absorbs one.
        self.shared.descriptor.accepting_work.store(false, .release);
        for (self.workers) |*worker| {
            worker.wake.post(io);
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

    /// The one place batch shape is decided. Resolves whether the tuner is active
    /// (adaptive, no explicit range size, workers available), asks it for a profile
    /// (or uses the fixed profile otherwise), then applies the shared align/clamp/
    /// inline-collapse via `shapeBatch`. Both `parallelForWithOptions` and the
    /// pre-sizing stage helpers call this, so the tuner's decision — and the exact
    /// `(worker_threads, items_per_range)` it will later see in `record` — is
    /// computed identically everywhere. Divergence here would make the tuner see a
    /// "new" profile every frame and never settle. Called from inside one of this
    /// system's batches, it returns the untuned inline shape and never touches
    /// `adaptive_tuner`; called from a foreign thread, it panics.
    pub fn selectBatchProfile(
        self: *const ThreadSystem,
        adaptive_tuner: ?*AdaptiveWorkTuner,
        request: BatchWorkRequest,
    ) BatchSelection {
        return switch (self.requireCallerRole()) {
            .owner => self.resolveSelection(adaptive_tuner, request),
            .nested => self.untunedSelection(request),
        };
    }

    // O(1) for the owner; a non-owner scans the workers' ids, O(workers).
    fn callerRole(self: *const ThreadSystem) ?CallerRole {
        const current = std.Thread.getCurrentId();
        if (current == self.owner_thread_id) {
            return if (self.owner_in_batch) .{ .nested = WorkerId.main } else .owner;
        }
        for (self.workers) |*worker| {
            if (worker.thread_id.load(.monotonic) == current) return .{ .nested = worker.id };
        }
        return null;
    }

    // A foreign thread has no participant slot and no safe way to run a batch, so it
    // fails before any tuner or shared state is touched.
    fn requireCallerRole(self: *const ThreadSystem) CallerRole {
        return self.callerRole() orelse @panic("ThreadSystem called from a thread that neither owns nor serves it");
    }

    // The request's shape with no tuner: its fixed or default range size at its alignment,
    // inline. Reads no tuner, since one may be mid-record on another participant.
    fn untunedSelection(self: *const ThreadSystem, request: BatchWorkRequest) BatchSelection {
        var selection = self.resolveSelection(null, request);
        selection.worker_threads = 0;
        selection.profile.worker_threads = 0;
        return selection;
    }

    // The shape under `adaptive_tuner` when it is active (consulting and updating it), else
    // the fixed shape: the owner's `selectBatchProfile`.
    fn resolveSelection(
        self: *const ThreadSystem,
        adaptive_tuner: ?*AdaptiveWorkTuner,
        request: BatchWorkRequest,
    ) BatchSelection {
        const range_alignment_items = @max(request.range_alignment_items, @as(usize, 1));
        const max_worker_threads = @min(request.max_worker_threads orelse self.workers.len, self.workers.len);
        const requested_items_per_range = @max(request.items_per_range orelse self.config.items_per_range, @as(usize, 1));
        const active_tuner = if (request.adaptive and request.items_per_range == null and max_worker_threads > 0)
            adaptive_tuner
        else
            null;
        const profile = if (active_tuner) |tuner|
            tuner.selectProfile(.{
                .item_count = request.item_count,
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
        const shape = shapeBatch(request.item_count, profile, max_worker_threads, range_alignment_items, active_tuner != null);
        return .{
            .profile = .{ .worker_threads = shape.worker_threads, .items_per_range = shape.items_per_range },
            .items_per_range = shape.items_per_range,
            .worker_threads = shape.worker_threads,
            .range_count = shape.range_count,
            .active_tuner = active_tuner,
        };
    }

    /// Runs `job_fn` over `item_count` items in ranges. Called from inside one of this
    /// system's batches (a job on a worker or on the owner), it runs forced inline on the
    /// caller's `WorkerId` over the selected profile's ranges, or the untuned fixed shape
    /// when none is given, records no tuner, and returns `forced_inline` stats; called from
    /// a foreign thread, it panics. From the owner with no `adaptive_tuner`, it runs the
    /// untuned fixed shape: every stage owns its tuner, and none is shared.
    pub fn parallelForWithOptions(
        self: *ThreadSystem,
        item_count: usize,
        context: *anyopaque,
        job_fn: JobFn,
        options: ParallelForOptions,
    ) BatchStats {
        // Classified before the empty return so a foreign caller fails at any size.
        const role = self.requireCallerRole();
        // Selection happens before worker wake-up so every participant observes
        // one immutable batch shape: range size, count, job pointer, and context.
        if (item_count == 0) return .{};
        switch (role) {
            .owner => {},
            .nested => |caller| return self.runForcedInline(item_count, context, job_fn, options, caller),
        }

        const range_alignment_items = @max(options.range_alignment_items, @as(usize, 1));
        // Single selection path. A caller that pre-sized per-range output buffers
        // passes its already-resolved `selected_profile` (from selectBatchProfile);
        // everyone else selects here. Both routes shape the batch through the same
        // tuner-owned logic, so `record` always sees the profile that was selected.
        const selection = if (options.selected_profile) |selected|
            self.selectedProfileShape(item_count, selected, options.max_worker_threads, range_alignment_items, if (options.adaptive) options.adaptive_tuner else null)
        else
            self.resolveSelection(options.adaptive_tuner, .{
                .item_count = item_count,
                .items_per_range = options.items_per_range,
                .max_worker_threads = options.max_worker_threads,
                .range_alignment_items = range_alignment_items,
                .adaptive = options.adaptive,
            });
        const items_per_range = selection.items_per_range;
        const active_worker_threads = selection.worker_threads;
        const range_count = selection.range_count;
        const record_tuner = selection.active_tuner;
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
            const batch_start_ns = nowNs(self.shared.descriptor.io);
            self.owner_in_batch = true;
            runInline(item_count, items_per_range, context, job_fn, WorkerId.main, &stats);
            self.owner_in_batch = false;
            const batch_end_ns = nowNs(self.shared.descriptor.io);
            stats.batch_duration_ns = elapsedNs(batch_start_ns, batch_end_ns);
            if (record_tuner) |tuner| {
                tuner.record(stats);
            }
            return stats;
        }

        const shared = self.shared;
        const io = shared.descriptor.io;
        const batch_start_ns = nowNs(io);
        std.debug.assert(shared.descriptor.accepting_work.load(.monotonic));
        // The previous join returned only after every participant's decrement.
        std.debug.assert(shared.completion.pending.load(.monotonic) == 0);
        // Every woken worker has a first range of its own.
        std.debug.assert(range_count >= active_worker_threads + 1);

        // Publish: everything a worker reads is written before its generation's release
        // store, so the acquire load that admits it into the batch also makes them visible.
        const generation = shared.descriptor.generation + 1;
        shared.descriptor.generation = generation;
        shared.descriptor.batch = .{
            .item_count = item_count,
            .items_per_range = items_per_range,
            .range_count = range_count,
            .active_worker_thread_count = active_worker_threads,
            .context = context,
            .job_fn = job_fn,
        };
        shared.claim.next_range.store(active_worker_threads, .monotonic);
        shared.completion.worker_ranges.store(0, .monotonic);
        // The countdown includes main, so a main that finishes last never waits.
        shared.completion.pending.store(active_worker_threads + 1, .monotonic);
        // No waiter: main, the only one, waits only in its own join below.
        shared.completion.done.reset();
        stats.active_worker_threads = active_worker_threads;
        stats.ran_inline = false;

        for (self.workers[0..active_worker_threads]) |*worker| {
            worker.batch_generation.store(generation, .release);
            worker.wake.post(io);
        }

        // Worker 1 starts with range 0, worker N with range N-1, and the main
        // thread steals from `next_range`. That preserves deterministic range
        // ownership while allowing the main thread to help instead of only wait.
        const view = BatchView{
            .item_count = item_count,
            .items_per_range = items_per_range,
            .range_count = range_count,
            .context = context,
            .job_fn = job_fn,
        };
        self.owner_in_batch = true;
        const main_thread_ranges = view.runClaimedRanges(&shared.claim.next_range, WorkerId.main);
        self.owner_in_batch = false;

        const wait_start_ns = nowNs(io);
        // Join: the last decrement acquires every earlier participant's release, and a
        // worker that is last hands that to main through `done`'s release.
        if (shared.completion.pending.fetchSub(1, .acq_rel) != 1) {
            shared.completion.done.waitUncancelable(io);
        }
        const wait_end_ns = nowNs(io);
        stats.main_thread_ranges = main_thread_ranges;
        stats.worker_thread_ranges = shared.completion.worker_ranges.load(.monotonic);
        std.debug.assert(stats.main_thread_ranges + stats.worker_thread_ranges == range_count);

        const batch_end_ns = nowNs(io);
        stats.main_thread_wait_ns = elapsedNs(wait_start_ns, wait_end_ns);
        stats.batch_duration_ns = elapsedNs(batch_start_ns, batch_end_ns);
        stats.worker_utilization = workerUtilization(stats.worker_thread_ranges, active_worker_threads, range_count);
        if (record_tuner) |tuner| {
            tuner.record(stats);
        }

        return stats;
    }

    // The shape a caller's preselected profile dispatches at, as `selectBatchProfile`
    // returned it; `active_tuner` gates only the inline collapse.
    fn selectedProfileShape(
        self: *const ThreadSystem,
        item_count: usize,
        selected: AdaptiveWorkProfile,
        max_worker_threads_cap: ?usize,
        range_alignment_items: usize,
        active_tuner: ?*AdaptiveWorkTuner,
    ) BatchSelection {
        const max_worker_threads = @min(max_worker_threads_cap orelse self.workers.len, self.workers.len);
        const shape = shapeBatch(item_count, selected, max_worker_threads, range_alignment_items, active_tuner != null);
        return .{
            .profile = .{ .worker_threads = shape.worker_threads, .items_per_range = shape.items_per_range },
            .items_per_range = shape.items_per_range,
            .worker_threads = shape.worker_threads,
            .range_count = shape.range_count,
            .active_tuner = active_tuner,
        };
    }

    // A batch dispatched from inside a batch of this system: its ranges run in order on
    // the calling participant, which never writes this `ThreadSystem` or any tuner.
    fn runForcedInline(
        self: *const ThreadSystem,
        item_count: usize,
        context: *anyopaque,
        job_fn: JobFn,
        options: ParallelForOptions,
        caller: WorkerId,
    ) BatchStats {
        const range_alignment_items = @max(options.range_alignment_items, @as(usize, 1));
        // Shaped with no tuner: an owner's tuner-selected inline profile already spans every
        // item, so its range set is unchanged, and a passed tuner cannot collapse an untuned
        // profile to one range.
        const selection = if (options.selected_profile) |selected|
            self.selectedProfileShape(item_count, selected, options.max_worker_threads, range_alignment_items, null)
        else
            self.untunedSelection(.{
                .item_count = item_count,
                .items_per_range = options.items_per_range,
                .max_worker_threads = options.max_worker_threads,
                .range_alignment_items = range_alignment_items,
                .adaptive = options.adaptive,
            });
        var stats = BatchStats{
            .item_count = item_count,
            .range_count = selection.range_count,
            .items_per_range = selection.items_per_range,
            .range_alignment_items = range_alignment_items,
            .available_worker_threads = self.workers.len,
            .forced_inline = true,
        };
        const batch_start_ns = nowNs(self.shared.descriptor.io);
        runInline(item_count, selection.items_per_range, context, job_fn, caller, &stats);
        stats.batch_duration_ns = elapsedNs(batch_start_ns, nowNs(self.shared.descriptor.io));
        return stats;
    }
};

// Isolation unit of a contended singleton shared record: a whole `std.atomic.cache_line`
// (std's per-CPU interference size).
const shared_line = std.atomic.cache_line;

// One system's batch state, split into blocks that each own whole lines so a range claim
// invalidates only the claim line, never the descriptor every participant reads or the
// completion countdown.
const Shared = struct {
    descriptor: Descriptor align(shared_line),
    claim: Claim align(shared_line) = .{},
    completion: Completion align(shared_line) = .{},

    comptime {
        std.debug.assert(@alignOf(Shared) == shared_line);
        for (@typeInfo(Shared).@"struct".field_names) |name| {
            std.debug.assert(@offsetOf(Shared, name) % shared_line == 0);
            std.debug.assert(@sizeOf(@FieldType(Shared, name)) <= shared_line);
        }
    }

    // Each worker runs its deterministic first range by ID, then claims the rest from
    // `claim.next_range`, counting what it ran into `completion.worker_ranges` once. A
    // wake whose generation the worker already ran (a stale permit, or one for a batch
    // that did not count it) reads nothing else and never decrements.
    fn workerLoop(self: *Shared, worker: *WorkerRecord) void {
        const io = self.descriptor.io;
        const id = worker.id;
        var seen_generation: u64 = 0;
        while (true) {
            worker.wake.waitUncancelable(io);
            if (!self.descriptor.accepting_work.load(.acquire)) return;
            const generation = worker.batch_generation.load(.acquire);
            if (generation == seen_generation) continue;
            seen_generation = generation;

            // This batch counted this worker, so main rewrites none of it before this
            // worker's decrement below.
            const batch = &self.descriptor.batch;
            const assigned_range_index = id.index - 1;
            std.debug.assert(id.index <= batch.active_worker_thread_count and assigned_range_index < batch.range_count);
            const view = batch.view();
            view.runRange(id, assigned_range_index);
            const ran_ranges = 1 + view.runClaimedRanges(&self.claim.next_range, id);

            // After the decrement this worker touches no per-batch state: `done.set`
            // reads only `done` and the init-time `io`.
            _ = self.completion.worker_ranges.fetchAdd(ran_ranges, .monotonic);
            if (self.completion.pending.fetchSub(1, .acq_rel) == 1) self.completion.done.set(io);
        }
    }
};

// Written only by the main thread: `io` once at init, `batch` at publish, and
// `accepting_work` at shutdown. Workers read `batch` only after the acquire of a
// generation assigned to them.
const Descriptor = struct {
    io: std.Io,
    accepting_work: std.atomic.Value(bool) = .init(true),
    // Main-only: the generation of the last published batch.
    generation: u64 = 0,
    batch: PublishedBatch = .{},
};

const PublishedBatch = struct {
    // Optional context/job fields are valid for the last published batch, before main's
    // join returns.
    item_count: usize = 0,
    items_per_range: usize = 1,
    range_count: usize = 0,
    active_worker_thread_count: usize = 0,
    context: ?*anyopaque = null,
    job_fn: ?JobFn = null,

    fn view(batch: *const PublishedBatch) BatchView {
        // Published non-null before any generation store; the caller's generation acquire
        // is what guards against reading a previous batch's fields.
        std.debug.assert(batch.job_fn != null and batch.context != null);
        return .{
            .item_count = batch.item_count,
            .items_per_range = batch.items_per_range,
            .range_count = batch.range_count,
            .context = batch.context.?,
            .job_fn = batch.job_fn.?,
        };
    }
};

// One participant's private copy of the batch, taken once per batch, so its claim loop
// reads no shared line but the claim counter's.
const BatchView = struct {
    item_count: usize,
    items_per_range: usize,
    range_count: usize,
    context: *anyopaque,
    job_fn: JobFn,

    fn runRange(view: *const BatchView, id: WorkerId, range_index: usize) void {
        view.job_fn(view.context, rangeForIndex(view.item_count, view.items_per_range, range_index), id);
    }

    // Claims and runs ranges until none remain; returns how many ran. The claim is the
    // loop's only shared atomic; job functions provide their own range-local write
    // discipline.
    fn runClaimedRanges(view: *const BatchView, next_range: *std.atomic.Value(usize), id: WorkerId) usize {
        var ran_ranges: usize = 0;
        while (true) {
            const range_index = next_range.fetchAdd(1, .monotonic);
            if (range_index >= view.range_count) return ran_ranges;
            view.runRange(id, range_index);
            ran_ranges += 1;
        }
    }
};

const Claim = struct {
    next_range: std.atomic.Value(usize) = .init(0),
};

// Reset by main at publish; each participant ends its batch here.
const Completion = struct {
    // Participants (active workers plus main) yet to finish the batch.
    pending: std.atomic.Value(usize) = .init(0),
    // Ranges the active workers ran, each worker's count added once before its decrement.
    worker_ranges: std.atomic.Value(usize) = .init(0),
    // Set by a worker whose decrement ends the batch; main waits on it only when it
    // did not end the batch itself.
    done: std.Io.Event = .unset,
};

// One worker's record, written by main (`batch_generation`, `wake`) and by its worker
// (`wake`, `thread_id`) every batch: a per-worker record, so it starts its own
// `thread_shared_record_alignment` line and the next worker's record never shares one.
const WorkerRecord = struct {
    id: WorkerId align(thread_shared_record_alignment) = WorkerId.main,
    shared: *Shared = undefined,
    wake: std.Io.Semaphore = .{},
    thread: ?std.Thread = null,
    // Written once by the worker itself; 0 until then, which is no live thread's id on
    // Linux, Windows, or Darwin.
    thread_id: std.atomic.Value(std.Thread.Id) = .init(0),
    // Generation of the last batch that counted this worker, stored by main after that
    // batch is published; 0 before the first.
    batch_generation: std.atomic.Value(u64) = .init(0),

    comptime {
        std.debug.assert(@alignOf(WorkerRecord) == thread_shared_record_alignment);
        std.debug.assert(@sizeOf(WorkerRecord) % thread_shared_record_alignment == 0);
    }
};

fn workerMain(worker: *WorkerRecord) void {
    worker.thread_id.store(std.Thread.getCurrentId(), .monotonic);
    // The startup permit is posted after init stores `worker.thread`.
    worker.wake.waitUncancelable(worker.shared.descriptor.io);
    nameWorker(worker);
    worker.shared.workerLoop(worker);
}

// Names the calling worker `zl-worker-<WorkerId>`; Darwin can name only the calling
// thread, and naming the main thread would rename the process on Linux.
fn nameWorker(worker: *const WorkerRecord) void {
    if (std.Thread.max_name_len == 0) return;
    var buffer: [std.Thread.max_name_len]u8 = undefined;
    const name = std.mem.print(&buffer, "zl-worker-{d}", .{worker.id.index}) catch |err| {
        log.warn("ThreadSystem worker {d} left unnamed: {}", .{ worker.id.index, err });
        return;
    };
    // Set by init before the startup permit this worker already took.
    const thread = worker.thread.?;
    thread.setName(worker.shared.descriptor.io, name) catch |err| {
        log.warn("ThreadSystem worker {d} left unnamed: {}", .{ worker.id.index, err });
    };
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

// Callers normalize items_per_range before entering this helper.
pub fn rangeCount(item_count: usize, items_per_range: usize) usize {
    return @divCeil(item_count, items_per_range);
}

/// Upper bound on the range count of any batch over at most `item_count` items with
/// `range_alignment_items`: every shape (`shapeBatch`, the single shaping path for fixed,
/// selected, and tuner profiles) aligns its range size up to the alignment or collapses
/// to one full-width range, so no partition can produce more ranges than this. Callers
/// size per-range records (tallies, offsets) from it at their capacity seam so a
/// partition retune never allocates in-stage; data-dependent slots are `RangeSlots`.
pub fn maxRangeCount(item_count: usize, range_alignment_items: usize) usize {
    return rangeCount(item_count, @max(range_alignment_items, @as(usize, 1)));
}

/// Alignment and padding unit of records that concurrent ranges write, so no two
/// participants share a writable cache line. Fixed at 64 rather than
/// `std.atomic.cache_line` (128 on x86_64 and aarch64): the padded record layouts and
/// their comptime window asserts are built on 64.
pub const thread_shared_record_alignment: usize = 64;

/// Bytes that pad `T` to a whole number of `thread_shared_record_alignment` lines.
pub fn paddingForCacheLine(comptime T: type) usize {
    return std.mem.alignForward(usize, @sizeOf(T), thread_shared_record_alignment) - @sizeOf(T);
}

/// One range's record on its own cache lines: aligned to at least and padded to whole
/// `thread_shared_record_alignment` lines, so every array, list, or embedded field of slots
/// starts each slot on a line by construction. A zero-sized `T` stays zero-sized.
pub fn PaddedSlot(comptime T: type) type {
    return struct {
        value: T align(@max(@alignOf(T), thread_shared_record_alignment)) = .{},
        padding: [paddingForCacheLine(T)]u8 = @splat(0),
    };
}

/// Per-range padded slots on a `thread_shared_record_alignment` base.
pub fn SlotList(comptime T: type) type {
    return std.array_list.Aligned(PaddedSlot(T), .fromByteUnits(thread_shared_record_alignment));
}

/// Resets `slots` to `count` default slots within reserved capacity; never allocates.
pub fn setSlotCount(comptime T: type, slots: *SlotList(T), count: usize) void {
    slots.clearRetainingCapacity();
    slots.appendNTimesAssumeCapacity(.{}, count);
}

/// The final pass of a `RangeSlots.run`: its batch, which the caller records into its
/// stage's tuner, and whether an overflowing range made the dispatch replay.
pub const Replay = struct {
    batch: BatchStats = .{},
    replayed: bool = false,
};

/// Padded per-range slots for output whose size depends on the data. `prepare` sizes
/// each range of a stage's selection at the per-item bound times the items it covers;
/// `run` dispatches at that selection with no tuner record, grows every range that
/// overflowed to its counted need, and replays until every range fit. Grow-only: slots
/// past the prepared count keep their lists, and only `release` frees. Main thread, owner
/// only; `run` never resizes the list, so a job's `slots()` stays valid across passes.
///
/// `Slot` declares, all `pub`:
/// - `Context`: the caller's per-call value for `reserve` and `grow`;
/// - `max_passes`: the passes one run takes at most (one grow sizes the next pass's
///   counted need; a need a pass cannot count adds a pass);
/// - `reserve(*Slot, Allocator, records, Context) error{OutOfMemory}!bool`: geometric,
///   holds `records` primary records; whether it allocated;
/// - `clear(*Slot) void`;
/// - `grow(*Slot, Allocator, Context) error{OutOfMemory}!bool`: after a pass, grows to the
///   counted need when the slot overflowed; whether it did;
/// - `held(*const Slot) usize`: primary records held, read only by perf-log builds;
/// - `deinit(*Slot, Allocator) void`.
pub fn RangeSlots(comptime Slot: type) type {
    return struct {
        const Self = @This();
        pub const Context = Slot.Context;

        list: SlotList(Slot) = .empty,
        /// The range count `prepare` last sized; `run`'s shape must match it.
        range_count: usize = 0,
        /// Prepares that allocated, replay passes, and the primary records every slot
        /// holds (the set's memory, in `Slot.held` units).
        prepare_grows: DiagnosticCount = zero_diagnostic_count,
        replays: DiagnosticCount = zero_diagnostic_count,
        held_records: DiagnosticCount = zero_diagnostic_count,

        /// Sizes range r < `shape.range_count` of `item_count` items to `per_item_bound`
        /// records per item it covers. Call after the stage's `StageShape.select`, before
        /// `run`. O(range count); returns whether anything allocated.
        pub fn prepare(self: *Self, allocator: std.mem.Allocator, shape: StageShape, item_count: usize, per_item_bound: usize, context: Context) error{OutOfMemory}!bool {
            std.debug.assert(shape.range_count == rangeCount(item_count, shape.items_per_range));
            var grew = false;
            if (self.list.items.len < shape.range_count) {
                grew = self.list.capacity < shape.range_count;
                try self.list.ensureTotalCapacity(allocator, shape.range_count);
                self.list.appendNTimesAssumeCapacity(.{}, shape.range_count - self.list.items.len);
            }
            for (self.list.items[0..shape.range_count], 0..) |*slot, range_index| {
                const covered = rangeForIndex(item_count, shape.items_per_range, range_index).len();
                if (try slot.value.reserve(allocator, per_item_bound *| covered, context)) grew = true;
            }
            self.range_count = shape.range_count;
            if (comptime diagnostics_enabled) {
                if (grew) {
                    self.prepare_grows += 1;
                    self.recountHeld();
                }
            }
            return grew;
        }

        /// The prepared ranges' slots, for the job's context.
        pub fn slots(self: *Self) []PaddedSlot(Slot) {
            return self.list.items[0..self.range_count];
        }

        /// Runs `job` over `item_count` items at the prepared `shape` under `dispatch` (or
        /// inline as one range), recording no tuner, and replays after growing every range
        /// that overflowed. A replay dispatches the same ranges: the selection's profile is
        /// already shaped. Returns the final pass, for the caller to record.
        pub fn run(self: *Self, allocator: std.mem.Allocator, dispatch: ?Dispatch, shape: StageShape, item_count: usize, range_alignment_items: usize, context: Context, job_context: *anyopaque, job: JobFn) error{OutOfMemory}!Replay {
            std.debug.assert(shape.range_count == self.range_count);
            if (item_count == 0) return .{};
            var untuned = shape;
            if (untuned.selection) |*selection| selection.active_tuner = null;
            var replay = Replay{};
            var passes: usize = 0;
            while (true) {
                passes += 1;
                std.debug.assert(passes <= Slot.max_passes);
                for (self.slots()) |*slot| slot.value.clear();
                replay.batch = runShaped(dispatch, untuned, item_count, range_alignment_items, job_context, job);
                // The selection's profile is already shaped, so every pass dispatches its ranges.
                std.debug.assert(replay.batch.range_count == shape.range_count);
                var grew = false;
                for (self.slots()) |*slot| {
                    if (try slot.value.grow(allocator, context)) grew = true;
                }
                if (!grew) return replay;
                replay.replayed = true;
                if (comptime diagnostics_enabled) {
                    self.replays += 1;
                    self.recountHeld();
                }
            }
        }

        /// Frees every slot; the set prepares again afterwards.
        pub fn release(self: *Self, allocator: std.mem.Allocator) void {
            for (self.list.items) |*slot| slot.value.deinit(allocator);
            self.list.clearAndFree(allocator);
            self.range_count = 0;
            if (comptime diagnostics_enabled) self.held_records = 0;
        }

        // Sums every slot's held records, prepared or not, after a pass that grew one: lists
        // only grow, so a steady pass leaves the sum as it was.
        fn recountHeld(self: *Self) void {
            var held: usize = 0;
            for (self.list.items) |*slot| held += slot.value.held();
            self.held_records = held;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.release(allocator);
            self.* = undefined;
        }
    };
}

/// How many of a stage's scratch capacities differ between two snapshots taken in the same
/// order: each differing entry is one counted growth.
pub fn changedCapacities(before: []const usize, after: []const usize) usize {
    std.debug.assert(before.len == after.len);
    var changed: usize = 0;
    for (before, after) |old, new| changed += @intFromBool(old != new);
    return changed;
}

/// Sets a MAL's row count within reserved capacity, never allocating; rows past the old
/// count are undefined. Hand-written: `std.MultiArrayList` has no assume-capacity length
/// set (`resize` takes an allocator).
pub fn setRowCount(comptime Row: type, rows: *std.MultiArrayList(Row), count: usize) void {
    std.debug.assert(rows.capacity >= count);
    rows.len = count;
}

/// The main thread's merge after a windowed MAL gather: moves each range's `kept` rows from its
/// window at `range * items_per_range` to the running total in range order, column by column,
/// then cuts `rows` to the total. `Tally` has a `kept: usize` field. Windows ascend with the
/// range index, so each starts at or past the total; when no range skipped nothing moves.
pub fn compactRowWindows(comptime Row: type, comptime Tally: type, rows: *std.MultiArrayList(Row), tallies: []const PaddedSlot(Tally), items_per_range: usize) void {
    const columns = rows.slice();
    var total: usize = 0;
    for (tallies, 0..) |slot, range_index| {
        const kept = slot.value.kept;
        const window = range_index * items_per_range;
        std.debug.assert(total <= window and window + kept <= rows.len);
        if (total != window and kept != 0) {
            inline for (comptime std.meta.tags(std.MultiArrayList(Row).Field)) |field| {
                const column = columns.items(field);
                @memmove(column[total..][0..kept], column[window..][0..kept]);
            }
        }
        total += kept;
    }
    rows.shrinkRetainingCapacity(total);
}

/// `compactRowWindows` over one slice: moves each range's `kept` items from its window at
/// `range * items_per_range` to the running total in range order and returns the total; the
/// caller cuts its list to it. `Tally` has a `kept: usize` field. Hand-written: std has no
/// window compaction.
pub fn compactSliceWindows(comptime T: type, comptime Tally: type, items: []T, tallies: []const PaddedSlot(Tally), items_per_range: usize) usize {
    var total: usize = 0;
    for (tallies, 0..) |slot, range_index| {
        const kept = slot.value.kept;
        const window = range_index * items_per_range;
        std.debug.assert(total <= window and window + kept <= items.len);
        if (total != window and kept != 0) @memmove(items[total..][0..kept], items[window..][0..kept]);
        total += kept;
    }
    return total;
}

/// The partition of `row_count` rows into `band_count` bands of whole `block_rows` blocks:
/// band `b` owns blocks `[ceil(b * blocks / bands), ceil((b + 1) * blocks / bands))`. The
/// band count is `max_bands`, or one band per block when fewer, independent of any stage's
/// range partition.
pub fn BandPartition(comptime block_rows: usize, comptime max_bands: usize) type {
    comptime std.debug.assert(block_rows > 0 and max_bands > 0);
    return struct {
        const Self = @This();

        band_count: usize,
        block_count: usize,
        row_count: usize,

        pub fn init(row_count: usize) Self {
            const block_count = @max(@divCeil(row_count, block_rows), 1);
            return .{
                .band_count = @min(max_bands, block_count),
                .block_count = block_count,
                .row_count = row_count,
            };
        }

        pub fn bandOfRow(self: Self, row: usize) usize {
            return (row / block_rows) * self.band_count / self.block_count;
        }

        pub fn firstRow(self: Self, band: usize) usize {
            const block = @divCeil(band * self.block_count, self.band_count);
            return @min(block * block_rows, self.row_count);
        }
    };
}

/// Tuner config of a stage that dispatches one item per band.
pub const band_tuner_config = AdaptiveWorkTunerConfig{
    .initial_range_items = 1,
    .smallest_range_items = 1,
};

/// Tuner config of a world-create rebuild stage: the rebuild is a one-off, so a fresh
/// tuner's first rebuild dispatches on the full pool instead of inline on main.
pub const rebuild_tuner_config = AdaptiveWorkTunerConfig{ .first_selection = .full_pool };

/// Batch stats of a stage that ran on the calling thread as one range, with no thread
/// system or with work the inline path absorbed. An empty batch reports no range.
pub fn inlineBatch(item_count: usize, range_alignment_items: usize) BatchStats {
    return .{
        .item_count = item_count,
        .range_count = if (item_count == 0) 0 else 1,
        .items_per_range = if (item_count == 0) 1 else item_count,
        .range_alignment_items = range_alignment_items,
        .main_thread_ranges = if (item_count == 0) 0 else 1,
        .ran_inline = true,
    };
}

/// Folds one batch's shape into a running total: summed counts and times, the widest range
/// and worker use, and inline only when every batch ran inline. Empty batches are skipped.
pub fn accumulateBatch(total: *BatchStats, batch: BatchStats) void {
    if (batch.item_count == 0) return;
    total.item_count += batch.item_count;
    total.range_count += batch.range_count;
    total.items_per_range = @max(total.items_per_range, batch.items_per_range);
    total.range_alignment_items = @max(total.range_alignment_items, batch.range_alignment_items);
    total.available_worker_threads = @max(total.available_worker_threads, batch.available_worker_threads);
    total.active_worker_threads = @max(total.active_worker_threads, batch.active_worker_threads);
    total.main_thread_ranges += batch.main_thread_ranges;
    total.worker_thread_ranges += batch.worker_thread_ranges;
    total.batch_duration_ns += batch.batch_duration_ns;
    total.main_thread_wait_ns += batch.main_thread_wait_ns;
    total.ran_inline = total.ran_inline and batch.ran_inline;
    total.forced_inline = total.forced_inline or batch.forced_inline;
    total.worker_utilization = workerUtilization(total.worker_thread_ranges, total.active_worker_threads, total.range_count);
}

/// A stage's range controls. A fixed `items_per_range` opts the stage out of its tuner;
/// `max_worker_threads` caps participation; `adaptive = false` pins the fixed shape.
pub const StageControls = struct {
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
};

/// One stage's threading: the thread system, the stage's own tuner, and its range
/// controls. `select` pre-sizes the batch; `run` dispatches that selection, so the tuner
/// records exactly the profile it chose.
pub const Dispatch = struct {
    thread_system: *ThreadSystem,
    tuner: *AdaptiveWorkTuner,
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,

    pub fn init(thread_system: *ThreadSystem, tuner: *AdaptiveWorkTuner, controls: StageControls) Dispatch {
        return .{
            .thread_system = thread_system,
            .tuner = tuner,
            .items_per_range = controls.items_per_range,
            .max_worker_threads = controls.max_worker_threads,
            .adaptive = controls.adaptive,
        };
    }

    /// The batch shape of `item_count` items; the tuner drives an adaptive dispatch with
    /// no fixed range size.
    pub fn select(self: Dispatch, item_count: usize, range_alignment_items: usize) BatchSelection {
        const tuner: ?*AdaptiveWorkTuner = if (self.adaptive and self.items_per_range == null) self.tuner else null;
        return self.thread_system.selectBatchProfile(tuner, .{
            .item_count = item_count,
            .items_per_range = self.items_per_range,
            .max_worker_threads = self.max_worker_threads,
            .range_alignment_items = range_alignment_items,
            .adaptive = self.adaptive,
        });
    }

    /// Dispatches `item_count` items at `selection`, recording into its active tuner.
    pub fn run(self: Dispatch, selection: BatchSelection, item_count: usize, range_alignment_items: usize, context: *anyopaque, job: JobFn) BatchStats {
        return self.thread_system.parallelForWithOptions(item_count, context, job, .{
            .items_per_range = self.items_per_range,
            .max_worker_threads = self.max_worker_threads,
            .range_alignment_items = range_alignment_items,
            .adaptive = self.adaptive,
            .adaptive_tuner = selection.active_tuner,
            .selected_profile = selection.profile,
        });
    }
};

/// Threading for one update's stages: the thread system and the caller's control config,
/// whose `items_per_range`, `max_worker_threads`, and `adaptive` every stage shares.
pub fn StageThreads(comptime Config: type) type {
    return struct {
        const Self = @This();

        thread_system: *ThreadSystem,
        config: Config,

        /// One stage under its own tuner and the config's controls.
        pub fn stage(self: Self, tuner: *AdaptiveWorkTuner) Dispatch {
            return Dispatch.init(self.thread_system, tuner, .{
                .items_per_range = self.config.items_per_range,
                .max_worker_threads = self.config.max_worker_threads,
                .adaptive = self.config.adaptive,
            });
        }

        // False when the thread system has no workers or the config allows none, so every
        // stage runs inline whatever its tuner learns.
        fn mayUseWorkers(self: Self) bool {
            const workers = self.thread_system.workerThreadCount();
            return @min(self.config.max_worker_threads orelse workers, workers) > 0;
        }

        /// `threads` when a stage there can get a worker, else null.
        pub fn withWorkers(threads: Self) ?Self {
            return if (threads.mayUseWorkers()) threads else null;
        }
    };
}

/// The shape a stage runs at: a dispatch's pre-selected profile, or one inline range.
pub const StageShape = struct {
    selection: ?BatchSelection = null,
    items_per_range: usize = 1,
    range_count: usize = 0,

    /// Selects `item_count` items' shape under `dispatch`, or one inline range without one.
    pub fn select(dispatch: ?Dispatch, item_count: usize, range_alignment_items: usize) StageShape {
        const stage = dispatch orelse return .{ .items_per_range = @max(item_count, 1), .range_count = @intFromBool(item_count != 0) };
        const selection = stage.select(item_count, range_alignment_items);
        return .{ .selection = selection, .items_per_range = selection.items_per_range, .range_count = selection.range_count };
    }
};

/// Runs `job` over `item_count` items at `shape`: dispatched with its selection, or inline
/// as one timed range on the calling thread.
pub fn runShaped(dispatch: ?Dispatch, shape: StageShape, item_count: usize, range_alignment_items: usize, context: *anyopaque, job: JobFn) BatchStats {
    if (item_count == 0) return .{};
    const stage = dispatch orelse {
        // No thread system times the batch, so it is timed here.
        const stage_timer = StageTimer.begin();
        job(context, .{ .start = 0, .end = item_count, .index = 0 }, WorkerId.main);
        var batch = inlineBatch(item_count, range_alignment_items);
        batch.batch_duration_ns = stage_timer.lap();
        return batch;
    };
    // A shape selected under a dispatch holds its selection.
    return stage.run(shape.selection.?, item_count, range_alignment_items, context, job);
}

/// Runs one stage over `item_count` items under `dispatch`, or inline as one range.
/// `range_count` receives the job's dispatched range count before dispatch, so each range
/// can assert against it; an empty batch selects nothing and leaves it untouched.
pub fn runStage(dispatch: ?Dispatch, item_count: usize, range_alignment_items: usize, context: *anyopaque, range_count: *usize, job: JobFn) BatchStats {
    if (item_count == 0) return .{};
    const shape = StageShape.select(dispatch, item_count, range_alignment_items);
    range_count.* = shape.range_count;
    return runShaped(dispatch, shape, item_count, range_alignment_items, context, job);
}

/// Dispatch time of a batch that ran on workers; zero when it ran inline.
pub fn offMainNs(batch: BatchStats) u64 {
    return if (batch.ran_inline) 0 else batch.batch_duration_ns;
}

/// One stage step dispatched as rounds under one thread profile: `begin` selects it once
/// from the step's item count through the stage's tuner, `run` dispatches every round with it
/// (no per-round tuner record; a round of one range runs inline), and `finish` records the
/// summed rounds into the tuner once, at the step's item count and the selected profile, so
/// the tuner judges one sample per step. With no dispatch each round runs inline as one range.
/// Rounds use range alignment 1.
pub const RoundDispatch = struct {
    dispatch: ?Dispatch,
    selection: ?BatchSelection = null,
    // The rounds folded into one.
    total: BatchStats = .{},
    /// Dispatch time of the rounds that ran on workers, and of those that ran inline.
    off_main_ns: u64 = 0,
    inline_ns: u64 = 0,
    /// The fewest and most items a round dispatched (both zero with no round).
    round_items_min: usize = 0,
    round_items_max: usize = 0,

    pub fn begin(dispatch: ?Dispatch, step_items: usize) RoundDispatch {
        var rounds = RoundDispatch{ .dispatch = dispatch };
        if (dispatch) |stage| rounds.selection = stage.select(@max(step_items, 1), 1);
        return rounds;
    }

    /// Runs one round of `item_count` items. `range_count` is the job's dispatched range
    /// count, set before dispatch so each range can assert against it.
    pub fn run(self: *RoundDispatch, item_count: usize, context: *anyopaque, range_count: *usize, job: JobFn) void {
        std.debug.assert(item_count != 0);
        self.round_items_min = if (self.round_items_max == 0) item_count else @min(self.round_items_min, item_count);
        self.round_items_max = @max(self.round_items_max, item_count);
        const batch = if (self.selection) |selection| blk: {
            const stage = self.dispatch.?;
            range_count.* = rangeCount(item_count, @max(selection.profile.items_per_range, 1));
            break :blk stage.thread_system.parallelForWithOptions(item_count, context, job, .{
                .adaptive = stage.adaptive,
                .adaptive_tuner = null,
                .items_per_range = stage.items_per_range,
                .max_worker_threads = stage.max_worker_threads,
                .range_alignment_items = 1,
                .selected_profile = selection.profile,
            });
        } else blk: {
            range_count.* = 1;
            // No thread system times the round, so it is timed here.
            const round_timer = StageTimer.begin();
            job(context, .{ .start = 0, .end = item_count, .index = 0 }, WorkerId.main);
            var round = inlineBatch(item_count, 1);
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
        // A forced-inline round never trains the tuner.
        if (self.total.forced_inline) return self.total;
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

const BatchShape = struct {
    items_per_range: usize,
    worker_threads: usize,
    range_count: usize,
};

// The shared align/clamp/collapse applied to any chosen profile: align the range
// size to the caller's alignment, drop workers a single-range batch can't use, and
// collapse to one full-width range a batch no worker may take or one the tuner selected
// inline. A fixed inline batch with workers allowed keeps its requested range size.
fn shapeBatch(item_count: usize, profile: AdaptiveWorkProfile, max_worker_threads: usize, range_alignment_items: usize, tuner_active: bool) BatchShape {
    const aligned = std.mem.alignForwardAnyAlign(usize, @max(profile.items_per_range, @as(usize, 1)), range_alignment_items);
    const aligned_range_count = rangeCount(item_count, aligned);
    const worker_threads = if (aligned_range_count <= 1)
        @as(usize, 0)
    else
        @min(profile.worker_threads, @min(max_worker_threads, aligned_range_count - 1));
    // A batch no worker may take, or one the tuner selected inline, runs as one range.
    const items_per_range = if (worker_threads == 0 and (max_worker_threads == 0 or (tuner_active and profile.worker_threads == 0)))
        item_count
    else
        aligned;
    return .{
        .items_per_range = items_per_range,
        .worker_threads = worker_threads,
        .range_count = rangeCount(item_count, items_per_range),
    };
}

fn targetRangeSizeForRangeCount(item_count: usize, target_ranges: usize) usize {
    return @max(@as(usize, 1), @divCeil(item_count, @max(target_ranges, @as(usize, 1))));
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

fn normalizeWorkTunerConfig(config: AdaptiveWorkTunerConfig) AdaptiveWorkTunerConfig {
    var normalized = config;
    normalized.smallest_range_items = @max(normalized.smallest_range_items, @as(usize, 1));
    normalized.largest_range_items = @max(normalized.largest_range_items, normalized.smallest_range_items);
    normalized.initial_range_items = std.math.clamp(normalized.initial_range_items, normalized.smallest_range_items, normalized.largest_range_items);
    normalized.sample_window = std.math.clamp(normalized.sample_window, 1, max_sample_window);
    normalized.nudge_samples = @max(normalized.nudge_samples, @as(usize, 1));
    normalized.threaded_commit_threshold_percent = @min(normalized.threaded_commit_threshold_percent, @as(u8, 100));
    normalized.item_count_reset_percent = @min(normalized.item_count_reset_percent, @as(u8, 100));
    return normalized;
}

fn isMeaningfullyFaster(candidate_ns: u64, baseline_ns: u64, improvement_threshold_percent: u8) bool {
    if (baseline_ns == 0) return true;
    if (candidate_ns >= baseline_ns) return false;
    const improvement_ns: u64 = @intCast((@as(u128, baseline_ns) * improvement_threshold_percent) / 100);
    const required_ns = baseline_ns - improvement_ns;
    return candidate_ns <= required_ns;
}

// True when `current` differs from `previous` by at least `threshold_percent` of
// `previous`: the item-count band.
fn outsideBand(previous: usize, current: usize, threshold_percent: u8) bool {
    if (previous == current) return false;
    const larger = @max(previous, current);
    const smaller = @min(previous, current);
    return (larger - smaller) *| 100 >= previous *| threshold_percent;
}

// Index of the median of three keys: the default window's median without a sort.
fn medianIndexOfThree(comptime T: type, keys: [3]T) u8 {
    if (keys[0] < keys[1]) {
        if (keys[1] < keys[2]) return 1;
        return if (keys[0] < keys[2]) 2 else 0;
    }
    if (keys[0] < keys[2]) return 0;
    return if (keys[1] < keys[2]) 2 else 1;
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

/// Range `range_index` of `item_count` items at `items_per_range`; callers pass an index
/// below `rangeCount(item_count, items_per_range)`.
pub fn rangeForIndex(item_count: usize, items_per_range: usize, range_index: usize) ParallelRange {
    const start = range_index * items_per_range;
    return .{
        .index = range_index,
        .start = start,
        .end = @min(start + items_per_range, item_count),
    };
}

fn runInline(item_count: usize, items_per_range: usize, context: *anyopaque, job_fn: JobFn, id: WorkerId, stats: *BatchStats) void {
    const range_count = rangeCount(item_count, items_per_range);
    for (0..range_count) |range_index| {
        job_fn(context, rangeForIndex(item_count, items_per_range, range_index), id);
    }
    if (id.index == WorkerId.main.index) {
        stats.main_thread_ranges += range_count;
    } else {
        stats.worker_thread_ranges += range_count;
    }
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).toNanoseconds();
}

fn elapsedNs(start_ns: i96, end_ns: i96) u64 {
    return if (end_ns > start_ns) @intCast(end_ns - start_ns) else 0;
}

// Utilization is diagnostic telemetry for work distribution, not a scheduling
// input for the current batch.
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

test "batch stats stay lean scalar telemetry" {
    // Upper bound, not an exact contract: guards against telemetry growth while
    // tolerating target-specific layout/padding differences.
    try std.testing.expect(@sizeOf(BatchStats) <= 88);
    try std.testing.expect(@alignOf(BatchStats) <= @alignOf(usize));
}

test "inline parallel for covers every item exactly once" {
    var hits: [8]std.atomic.Value(u32) = @splat(.{ .raw = 0 });
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 0,
        .items_per_range = 2,
    });
    defer threads.deinit();

    const stats = threads.parallelForWithOptions(hits.len, &context, markCoverage, .{});

    // Zero workers collapse to one full-width range.
    try std.testing.expect(stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 1), stats.range_count);
    try std.testing.expectEqual(hits.len, stats.items_per_range);
    try std.testing.expectEqual(@as(usize, 1), stats.main_thread_ranges);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "adaptive inline runs as one direct main-thread range" {
    var hits: [128]std.atomic.Value(u32) = @splat(.{ .raw = 0 });
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
    var starts: [16]usize = @splat(std.math.maxInt(usize));
    var ends: [16]usize = @splat(0);
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
    var hits: [128]std.atomic.Value(u32) = @splat(.{ .raw = 0 });
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
    var hits: [128]std.atomic.Value(u32) = @splat(.{ .raw = 0 });
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

    const report = adaptive_tuner;
    try std.testing.expect(stats.item_count == hits.len);
    // The provided tuner recorded this batch (proving it drove selection). It does not
    // assert a threaded commit: ~128 trivial items is far below any threading benefit,
    // so correct policy keeps it inline.
    try std.testing.expect(report.sample_count > 0 or report.baseline_mean_batch_duration_ns > 0);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "parallel for options record selected adaptive profile" {
    var hits: [128]std.atomic.Value(u32) = @splat(.{ .raw = 0 });
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
    try std.testing.expect(adaptive_tuner.has_threaded_profile);
    try std.testing.expect(adaptive_tuner.baseline_mean_batch_duration_ns > 0);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "parallel for options record selected inline adaptive profile" {
    var hits: [128]std.atomic.Value(u32) = @splat(.{ .raw = 0 });
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

    const report = adaptive_tuner;
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
    var hits: [8]std.atomic.Value(u32) = @splat(.{ .raw = 0 });
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 1,
        .items_per_range = 2,
    });
    defer threads.deinit();

    var adaptive_tuner = AdaptiveWorkTuner.init(.{});
    const stats = threads.parallelForWithOptions(hits.len, &context, markCoverage, .{ .adaptive_tuner = &adaptive_tuner });

    try std.testing.expect(stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 1), stats.range_count);
    try std.testing.expectEqual(@as(usize, 0), stats.active_worker_threads);
    try std.testing.expectEqual(@as(usize, 0), stats.worker_thread_ranges);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "an adaptive batch with no tuner runs the untuned fixed shape on workers" {
    var hits: [128]std.atomic.Value(u32) = @splat(.{ .raw = 0 });
    var context = CoverageContext{ .hits = hits[0..] };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = 16,
    });
    defer threads.deinit();

    const stats = threads.parallelForWithOptions(hits.len, &context, markCoverage, .{});

    try std.testing.expect(!stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 16), stats.items_per_range);
    try std.testing.expectEqual(@as(usize, 8), stats.range_count);
    try std.testing.expectEqual(@as(usize, 2), stats.active_worker_threads);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "small measured-expensive batch can activate worker threads" {
    var hits: [8]std.atomic.Value(u32) = @splat(.{ .raw = 0 });
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
    var hits: [256]std.atomic.Value(u32) = @splat(.{ .raw = 0 });
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

test "every selectable batch shape stays within maxRangeCount" {
    const item_counts = [_]usize{ 1, 15, 16, 17, 131, 2053 };
    const alignments = [_]usize{ 1, 16 };
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    for (item_counts) |n| {
        for (alignments) |alignment| {
            const bound = maxRangeCount(n, alignment);
            // Fixed (explicit range size) selections through the single selection path.
            for ([_]usize{ 1, 16, 64, n }) |items_per_range| {
                for ([_]?usize{ 0, 1, 3, null }) |workers| {
                    const selection = threads.selectBatchProfile(null, .{
                        .item_count = n,
                        .items_per_range = items_per_range,
                        .max_worker_threads = workers,
                        .range_alignment_items = alignment,
                        .adaptive = false,
                    });
                    try std.testing.expect(selection.range_count <= bound);
                }
            }
            // Every profile a tuner (or a caller's selected profile) can hand the shaper,
            // with the tuner-inline collapse both on and off.
            var items_per_range: usize = 1;
            while (items_per_range <= n + 1) : (items_per_range += 1) {
                for ([_]usize{ 0, 1, 2, 3 }) |worker_threads| {
                    for ([_]bool{ false, true }) |tuner_active| {
                        const shape = shapeBatch(n, .{ .worker_threads = worker_threads, .items_per_range = items_per_range }, 3, alignment, tuner_active);
                        try std.testing.expect(shape.range_count <= bound);
                    }
                }
            }
            // A live tuner's own selections.
            var tuner = AdaptiveWorkTuner.init(.{});
            const selection = threads.selectBatchProfile(&tuner, .{ .item_count = n, .range_alignment_items = alignment });
            try std.testing.expect(selection.range_count <= bound);
        }
    }
}

test "inline batch reports one main-thread range, and none when empty" {
    const empty = inlineBatch(0, 16);
    try std.testing.expectEqual(@as(usize, 0), empty.item_count);
    try std.testing.expectEqual(@as(usize, 0), empty.range_count);
    try std.testing.expectEqual(@as(usize, 1), empty.items_per_range);
    try std.testing.expectEqual(@as(usize, 16), empty.range_alignment_items);
    try std.testing.expectEqual(@as(usize, 0), empty.main_thread_ranges);
    try std.testing.expect(empty.ran_inline);

    const batch = inlineBatch(37, 16);
    try std.testing.expectEqual(@as(usize, 37), batch.item_count);
    try std.testing.expectEqual(@as(usize, 1), batch.range_count);
    try std.testing.expectEqual(@as(usize, 37), batch.items_per_range);
    try std.testing.expectEqual(@as(usize, 16), batch.range_alignment_items);
    try std.testing.expectEqual(@as(usize, 1), batch.main_thread_ranges);
    try std.testing.expectEqual(@as(usize, 0), batch.worker_thread_ranges);
    try std.testing.expectEqual(@as(usize, 0), batch.active_worker_threads);
    try std.testing.expectEqual(@as(u64, 0), batch.batch_duration_ns);
    try std.testing.expect(batch.ran_inline);
}

test "accumulate batch sums counts, keeps widest shape, and skips empty batches" {
    var total = BatchStats{};
    accumulateBatch(&total, inlineBatch(10, 1));
    try std.testing.expect(total.ran_inline);
    accumulateBatch(&total, .{
        .item_count = 40,
        .range_count = 4,
        .items_per_range = 12,
        .available_worker_threads = 3,
        .active_worker_threads = 2,
        .main_thread_ranges = 1,
        .worker_thread_ranges = 3,
        .batch_duration_ns = 500,
        .main_thread_wait_ns = 70,
        .ran_inline = false,
    });
    // A second threaded batch with a narrower shape but nonzero times: sums and maxes
    // diverge on every field.
    accumulateBatch(&total, .{
        .item_count = 20,
        .range_count = 2,
        .items_per_range = 10,
        .range_alignment_items = 4,
        .available_worker_threads = 1,
        .active_worker_threads = 1,
        .main_thread_ranges = 1,
        .worker_thread_ranges = 1,
        .batch_duration_ns = 300,
        .main_thread_wait_ns = 40,
        .ran_inline = false,
    });
    const before_empty = total;
    accumulateBatch(&total, .{ .item_count = 0, .range_count = 9, .items_per_range = 99, .batch_duration_ns = 1_000, .ran_inline = false });
    try std.testing.expectEqual(before_empty, total);

    try std.testing.expectEqual(@as(usize, 70), total.item_count);
    try std.testing.expectEqual(@as(usize, 7), total.range_count);
    try std.testing.expectEqual(@as(usize, 12), total.items_per_range);
    try std.testing.expectEqual(@as(usize, 3), total.available_worker_threads);
    try std.testing.expectEqual(@as(usize, 2), total.active_worker_threads);
    try std.testing.expectEqual(@as(usize, 3), total.main_thread_ranges);
    try std.testing.expectEqual(@as(usize, 4), total.worker_thread_ranges);
    try std.testing.expectEqual(@as(u64, 800), total.batch_duration_ns);
    try std.testing.expectEqual(@as(u64, 110), total.main_thread_wait_ns);
    try std.testing.expectEqual(@as(usize, 4), total.range_alignment_items);
    // Recomputed over the summed ranges: 4 of 7 ranges ran on workers.
    try std.testing.expectApproxEqAbs(@as(f32, 4.0 / 7.0), total.worker_utilization, 1e-6);
    try std.testing.expect(!total.ran_inline);
}

test "padded slots fill whole cache lines on an aligned base and reset within capacity" {
    const Odd = struct { a: u32 = 0, b: u8 = 0 };
    const Line = struct { words: [8]u64 = @splat(0) };
    try std.testing.expectEqual(@as(usize, 0), paddingForCacheLine(Line));
    try std.testing.expectEqual(thread_shared_record_alignment - @sizeOf(Odd), paddingForCacheLine(Odd));
    try std.testing.expectEqual(thread_shared_record_alignment, @sizeOf(PaddedSlot(Odd)));
    try std.testing.expectEqual(thread_shared_record_alignment, @sizeOf(PaddedSlot(Line)));
    // Line-aligned by the type, so a fixed array or embedded field of slots is too; a
    // zero-sized record stays zero-sized.
    try std.testing.expectEqual(thread_shared_record_alignment, @alignOf(PaddedSlot(Odd)));
    try std.testing.expectEqual(thread_shared_record_alignment, @alignOf(PaddedSlot(Line)));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(PaddedSlot(struct {})));
    // A record aligned past a line keeps its own alignment.
    const Wide = struct { word: u64 align(2 * thread_shared_record_alignment) = 0 };
    try std.testing.expectEqual(@as(usize, 2 * thread_shared_record_alignment), @alignOf(PaddedSlot(Wide)));
    try std.testing.expectEqual(@as(usize, 2 * thread_shared_record_alignment), @sizeOf(PaddedSlot(Wide)));
    try std.testing.expectEqual(@as(usize, 2 * thread_shared_record_alignment), @sizeOf([2]PaddedSlot(Odd)));
    const Embedded = struct { flag: u8 = 0, slots: [2]PaddedSlot(Odd) = @splat(.{}) };
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Embedded, "slots") % thread_shared_record_alignment);

    var slots: SlotList(Odd) = .empty;
    defer slots.deinit(std.testing.allocator);
    try slots.ensureTotalCapacity(std.testing.allocator, 5);
    try std.testing.expectEqual(thread_shared_record_alignment, std.meta.alignment(@TypeOf(slots.items)));
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(slots.items.ptr) % thread_shared_record_alignment);
    setSlotCount(Odd, &slots, 5);
    for (slots.items) |*slot| slot.value = .{ .a = 7, .b = 3 };
    const base = slots.items.ptr;
    setSlotCount(Odd, &slots, 3);
    try std.testing.expectEqual(@as(usize, 3), slots.items.len);
    try std.testing.expectEqual(base, slots.items.ptr);
    for (slots.items) |slot| try std.testing.expectEqual(Odd{}, slot.value);
    setSlotCount(Odd, &slots, 0);
    try std.testing.expectEqual(@as(usize, 0), slots.items.len);
}

test "set row count moves a multi array list's length within capacity" {
    const Row = struct { x: u32, y: f32 };
    var rows: std.MultiArrayList(Row) = .{};
    defer rows.deinit(std.testing.allocator);
    try rows.ensureTotalCapacity(std.testing.allocator, 8);
    const capacity = rows.capacity;
    setRowCount(Row, &rows, 8);
    try std.testing.expectEqual(@as(usize, 8), rows.len);
    try std.testing.expectEqual(@as(usize, 8), rows.items(.x).len);
    try std.testing.expectEqual(@as(usize, 8), rows.items(.y).len);
    setRowCount(Row, &rows, 2);
    try std.testing.expectEqual(@as(usize, 2), rows.items(.x).len);
    try std.testing.expectEqual(capacity, rows.capacity);
}

test "band partition covers every row with whole blocks in band order" {
    const block_rows = 16;
    const max_bands = 4;
    const Bands = BandPartition(block_rows, max_bands);
    for ([_]usize{ 0, 1, 15, 16, 17, 47, 64, 65, 200, 1000 }) |row_count| {
        const bands = Bands.init(row_count);
        const block_count = @max(@divCeil(row_count, block_rows), 1);
        try std.testing.expectEqual(block_count, bands.block_count);
        try std.testing.expectEqual(@min(max_bands, block_count), bands.band_count);
        try std.testing.expectEqual(@as(usize, 0), bands.firstRow(0));
        try std.testing.expectEqual(row_count, bands.firstRow(bands.band_count));
        for (0..bands.band_count) |band| {
            const first = bands.firstRow(band);
            const end = bands.firstRow(band + 1);
            try std.testing.expect(first <= end);
            try std.testing.expectEqual(@as(usize, 0), first % block_rows);
            for (first..end) |row| try std.testing.expectEqual(band, bands.bandOfRow(row));
        }
    }
}

test "band tuner config starts at, and never shrinks below, one band per range" {
    const tuner = AdaptiveWorkTuner.init(band_tuner_config);
    try std.testing.expectEqual(@as(usize, 1), tuner.initial_profile.items_per_range);
    try std.testing.expectEqual(@as(usize, 1), tuner.config.smallest_range_items);
}

// A stage job that counts its items and ranges and checks its range index against the
// range count written before dispatch.
const StageTestContext = struct {
    range_count: usize = 0,
    items: std.atomic.Value(usize) = .init(0),
    ranges: std.atomic.Value(usize) = .init(0),
};

fn stageTestJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const stage: *StageTestContext = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < stage.range_count);
    _ = stage.items.fetchAdd(range.len(), .monotonic);
    _ = stage.ranges.fetchAdd(1, .monotonic);
}

test "run stage with no items selects nothing and leaves the range count untouched" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var tuner = AdaptiveWorkTuner.init(.{});
    var context = StageTestContext{ .range_count = 77 };
    const batch = runStage(Dispatch.init(&threads, &tuner, .{}), 0, 1, &context, &context.range_count, stageTestJob);
    try std.testing.expectEqual(BatchStats{}, batch);
    try std.testing.expectEqual(@as(usize, 77), context.range_count);
    try std.testing.expect(tuner.last_request == null);
    try std.testing.expectEqual(@as(usize, 0), context.ranges.load(.monotonic));
}

test "run stage with no dispatch runs one inline range on the calling thread" {
    var context = StageTestContext{};
    const batch = runStage(null, 10, 4, &context, &context.range_count, stageTestJob);
    try std.testing.expectEqual(@as(usize, 1), context.range_count);
    try std.testing.expectEqual(@as(usize, 1), context.ranges.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 10), context.items.load(.monotonic));
    try std.testing.expect(batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 10), batch.item_count);
    try std.testing.expectEqual(@as(usize, 1), batch.range_count);
    try std.testing.expectEqual(@as(usize, 1), batch.main_thread_ranges);
    try std.testing.expectEqual(@as(usize, 4), batch.range_alignment_items);
}

test "run stage on workers writes the dispatched range count before dispatch" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var tuner = AdaptiveWorkTuner.init(.{});
    var context = StageTestContext{};
    const batch = runStage(Dispatch.init(&threads, &tuner, .{ .items_per_range = 4, .adaptive = false }), 64, 1, &context, &context.range_count, stageTestJob);
    try std.testing.expectEqual(@as(usize, 16), context.range_count);
    try std.testing.expectEqual(context.range_count, batch.range_count);
    try std.testing.expectEqual(context.range_count, context.ranges.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 64), context.items.load(.monotonic));
    try std.testing.expect(!batch.ran_inline);
    try std.testing.expect(batch.worker_thread_ranges > 0);
}

test "a dispatch worker cap of zero runs inline with workers present, and a cap of one uses one worker" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var tuner = AdaptiveWorkTuner.init(.{});
    for ([_]usize{ 0, 1 }) |cap| {
        const dispatch = Dispatch.init(&threads, &tuner, .{ .items_per_range = 4, .max_worker_threads = cap, .adaptive = false });
        var context = StageTestContext{};
        const batch = runStage(dispatch, 64, 1, &context, &context.range_count, stageTestJob);
        try std.testing.expectEqual(@as(usize, 64), context.items.load(.monotonic));
        try std.testing.expectEqual(cap, batch.active_worker_threads);
        try std.testing.expectEqual(cap == 0, batch.ran_inline);

        var rounds = RoundDispatch.begin(dispatch, 64);
        var round_context = StageTestContext{};
        rounds.run(64, &round_context, &round_context.range_count, stageTestJob);
        const total = rounds.finish(64);
        try std.testing.expectEqual(cap, total.active_worker_threads);
        try std.testing.expectEqual(cap == 0, total.ran_inline);
    }
}

test "round dispatch records one tuner sample per step, and folds inline rounds with no dispatch" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    const round_items = [_]usize{ 10, 12, 8 };
    for ([_]bool{ true, false }) |dispatched| {
        var tuner = AdaptiveWorkTuner.init(.{});
        var rounds = RoundDispatch.begin(if (dispatched) Dispatch.init(&threads, &tuner, .{}) else null, 30);
        var context = StageTestContext{};
        for (round_items) |item_count| rounds.run(item_count, &context, &context.range_count, stageTestJob);
        try std.testing.expectEqual(@as(usize, 0), tuner.sample_count);
        const total = rounds.finish(30);
        try std.testing.expectEqual(@as(usize, 30), context.items.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 30), total.item_count);
        try std.testing.expectEqual(@as(usize, 3), total.range_count);
        try std.testing.expectEqual(@as(usize, 3), total.main_thread_ranges);
        try std.testing.expect(total.ran_inline);
        try std.testing.expectEqual(@as(usize, 8), rounds.round_items_min);
        try std.testing.expectEqual(@as(usize, 12), rounds.round_items_max);
        const expected_samples: usize = if (dispatched) @intFromBool(total.batch_duration_ns != 0) else 0;
        try std.testing.expectEqual(expected_samples, tuner.sample_count);
    }
}

test "stage threads with workers is null with no worker or a zero worker cap" {
    const Config = struct { items_per_range: ?usize = null, max_worker_threads: ?usize = null, adaptive: bool = true };
    const Threads = StageThreads(Config);
    var serial = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial.deinit();
    try std.testing.expect(Threads.withWorkers(.{ .thread_system = &serial, .config = .{} }) == null);
    if (@import("builtin").single_threaded) return;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    try std.testing.expect(Threads.withWorkers(.{ .thread_system = &threads, .config = .{ .max_worker_threads = 0 } }) == null);
    const held = Threads.withWorkers(.{ .thread_system = &threads, .config = .{ .items_per_range = 8, .max_worker_threads = 1, .adaptive = false } }).?;
    var tuner = AdaptiveWorkTuner.init(.{});
    const stage = held.stage(&tuner);
    try std.testing.expectEqual(@as(?usize, 8), stage.items_per_range);
    try std.testing.expectEqual(@as(?usize, 1), stage.max_worker_threads);
    try std.testing.expect(!stage.adaptive and stage.tuner == &tuner);
}

// A data-dependent range output: item i writes `copies[i]` copies of i, counting the ones
// past its capacity.
const CopySlot = struct {
    pub const Context = void;
    pub const max_passes = 2;

    out: std.ArrayList(u32) = .empty,
    need: usize = 0,

    pub fn reserve(self: *CopySlot, allocator: std.mem.Allocator, records: usize, _: void) error{OutOfMemory}!bool {
        if (self.out.capacity >= records) return false;
        try self.out.ensureTotalCapacity(allocator, records);
        return true;
    }

    pub fn clear(self: *CopySlot) void {
        self.out.clearRetainingCapacity();
        self.need = 0;
    }

    pub fn grow(self: *CopySlot, allocator: std.mem.Allocator, _: void) error{OutOfMemory}!bool {
        if (self.need <= self.out.capacity) return false;
        try self.out.ensureTotalCapacity(allocator, self.need);
        return true;
    }

    pub fn held(self: *const CopySlot) usize {
        return self.out.capacity;
    }

    pub fn deinit(self: *CopySlot, allocator: std.mem.Allocator) void {
        self.out.deinit(allocator);
    }

    fn append(self: *CopySlot, value: u32) void {
        self.need += 1;
        if (self.out.items.len < self.out.capacity) self.out.appendAssumeCapacity(value);
    }
};

const CopyJob = struct {
    copies: []const usize,
    slots: []PaddedSlot(CopySlot),
};

fn copyJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *CopyJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.slots.len);
    const slot = &job.slots[range.index].value;
    for (range.start..range.end) |item| {
        for (0..job.copies[item]) |_| slot.append(@intCast(item));
    }
}

// Every range's output in range order, as one inline range writes it.
fn expectCopiesInOrder(copies: []const usize, slots: []const PaddedSlot(CopySlot)) !void {
    var item: usize = 0;
    var written: usize = 0;
    for (slots) |slot| {
        for (slot.value.out.items) |value| {
            while (written == copies[item]) {
                item += 1;
                written = 0;
            }
            try std.testing.expectEqual(@as(u32, @intCast(item)), value);
            written += 1;
        }
    }
    while (item < copies.len and written == copies[item]) {
        item += 1;
        written = 0;
    }
    try std.testing.expectEqual(copies.len, item);
}

test "RangeSlots prepares each range at the per-item bound of its selection" {
    var set: RangeSlots(CopySlot) = .{};
    defer set.deinit(std.testing.allocator);
    const bound = 3;
    const inline_shape = StageShape.select(null, 10, 4);
    try std.testing.expect(try set.prepare(std.testing.allocator, inline_shape, 10, bound, {}));
    try std.testing.expectEqual(@as(usize, 1), set.slots().len);
    try std.testing.expect(set.slots()[0].value.out.capacity >= bound * 10);
    // Ranges of 4, 4, and 2 items.
    const split = StageShape{ .items_per_range = 4, .range_count = 3 };
    _ = try set.prepare(std.testing.allocator, split, 10, bound, {});
    for (set.slots(), [_]usize{ 4, 4, 2 }) |slot, covered| try std.testing.expect(slot.value.out.capacity >= bound * covered);
    try std.testing.expect(!try set.prepare(std.testing.allocator, split, 10, bound, {}));
    try std.testing.expect(!try set.prepare(std.testing.allocator, inline_shape, 10, bound, {}));
}

test "RangeSlots replays an overflowing range to the inline reference and records no tuner sample" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var copies: [16]usize = @splat(1);
    // The third range of four items writes far past one record per item.
    copies[9] = 400;
    var tuner = AdaptiveWorkTuner.init(.{});
    // Settled on two workers at 4-item ranges: a tuner-active threaded selection, the one
    // shape whose untuned replay shapes from different inputs than its selection.
    var threaded_tuner = AdaptiveWorkTuner.init(.{ .threaded_batch_ns = 0, .nudge_samples = std.math.maxInt(usize) });
    pinSettledThreadedProfile(&threaded_tuner, .{ .worker_threads = 2, .items_per_range = 4 });
    const stages = [_]Dispatch{
        Dispatch.init(&threads, &tuner, .{ .items_per_range = 4, .adaptive = false }),
        Dispatch.init(&threads, &tuner, .{}),
        Dispatch.init(&threads, &threaded_tuner, .{}),
    };
    for (stages, 0..) |stage, stage_index| {
        var set: RangeSlots(CopySlot) = .{};
        defer set.deinit(std.testing.allocator);
        const shape = StageShape.select(stage, copies.len, 4);
        if (stage_index == 2) {
            try std.testing.expect(shape.selection.?.active_tuner != null);
            try std.testing.expectEqual(@as(usize, 4), shape.range_count);
        }
        _ = try set.prepare(std.testing.allocator, shape, copies.len, 1, {});
        var job = CopyJob{ .copies = &copies, .slots = set.slots() };
        const samples = .{ tuner.sample_count, threaded_tuner.sample_count };
        const replay = try set.run(std.testing.allocator, stage, shape, copies.len, 4, {}, &job, copyJob);
        try std.testing.expectEqual(samples[0], tuner.sample_count);
        try std.testing.expectEqual(samples[1], threaded_tuner.sample_count);
        try std.testing.expect(replay.replayed);
        try std.testing.expectEqual(shape.range_count, replay.batch.range_count);
        try expectCopiesInOrder(&copies, set.slots());
    }
}

// Settles `tuner` on `profile` with no count shift able to reshape it.
fn pinSettledThreadedProfile(tuner: *AdaptiveWorkTuner, profile: AdaptiveWorkProfile) void {
    tuner.phase = .settled;
    tuner.has_threaded_profile = true;
    tuner.current_profile = profile;
    tuner.candidate_profile = null;
    tuner.learned_item_count = std.math.maxInt(usize) / 256;
    tuner.config.item_count_reset_percent = std.math.maxInt(u8);
}

test "RangeSlots with no dispatch runs one inline range" {
    var set: RangeSlots(CopySlot) = .{};
    defer set.deinit(std.testing.allocator);
    const copies = [_]usize{ 2, 0, 300, 1 };
    const shape = StageShape.select(null, copies.len, 1);
    _ = try set.prepare(std.testing.allocator, shape, copies.len, 1, {});
    var job = CopyJob{ .copies = &copies, .slots = set.slots() };
    const replay = try set.run(std.testing.allocator, null, shape, copies.len, 1, {}, &job, copyJob);
    try std.testing.expect(replay.batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 1), replay.batch.range_count);
    try std.testing.expect(replay.replayed);
    try expectCopiesInOrder(&copies, set.slots());
}

test "RangeSlots release frees every slot and the set prepares again" {
    var set: RangeSlots(CopySlot) = .{};
    defer set.deinit(std.testing.allocator);
    const split = StageShape{ .items_per_range = 4, .range_count = 3 };
    _ = try set.prepare(std.testing.allocator, split, 10, 2, {});
    set.release(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), set.list.capacity);
    try std.testing.expectEqual(@as(usize, 0), set.slots().len);
    try std.testing.expect(try set.prepare(std.testing.allocator, split, 10, 2, {}));
    try std.testing.expect(set.slots()[0].value.out.capacity >= 8);
}

test "adaptive work tuner aligns and clamps selected items_per_range" {
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 17,
        .smallest_range_items = 16,
        .largest_range_items = 256,
    });

    const profile = tuner.selectProfile(tunerTestRequest(1024, 4, 16, 17));
    try std.testing.expectEqual(@as(usize, 32), profile.items_per_range);
    try std.testing.expectEqual(@as(usize, 17), tuner.current_profile.items_per_range);
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

    try std.testing.expectEqual(AdaptiveWorkPhase.settled, tuner.phase);
    try std.testing.expect(!tuner.has_threaded_profile);
    try std.testing.expectEqual(@as(u64, 500), tuner.baseline_mean_batch_duration_ns);
    try std.testing.expectEqual(@as(usize, 0), tuner.selectProfile(request).worker_threads);
}

test "adaptive work tuner default threshold requires full slow inline window" {
    var tuner = AdaptiveWorkTuner.init(.{ .initial_range_items = 64, .smallest_range_items = 16, .largest_range_items = 256 });
    const request = tunerTestRequest(1024, 4, 16, 64);

    // Above the default gate so learning eventually probes threading.
    for (0..tuner.config.sample_window - 1) |_| {
        const selected = tuner.selectProfile(request);
        try std.testing.expectEqual(@as(usize, 0), selected.worker_threads);
        tuner.record(tunerTestBatchWithProfile(1024, selected, 300_000));
        try std.testing.expectEqual(AdaptiveWorkPhase.learning, tuner.phase);
    }
    tuner.record(tunerTestBatchWithProfile(1024, tuner.selectProfile(request), 300_000));
    try std.testing.expectEqual(AdaptiveWorkPhase.probing, tuner.phase);
}

test "adaptive work tuner default threshold keeps cheap inline work settled" {
    var tuner = AdaptiveWorkTuner.init(.{ .initial_range_items = 64, .smallest_range_items = 16, .largest_range_items = 256 });
    const request = tunerTestRequest(1024, 4, 16, 64);
    for (0..tuner.config.sample_window) |_| {
        const selected = tuner.selectProfile(request);
        try std.testing.expectEqual(@as(usize, 0), selected.worker_threads);
        tuner.record(tunerTestBatchWithProfile(1024, selected, 49_000));
    }
    try std.testing.expectEqual(AdaptiveWorkPhase.settled, tuner.phase);
    try std.testing.expect(!tuner.has_threaded_profile);
    try std.testing.expectEqual(@as(u64, 49_000), tuner.baseline_mean_batch_duration_ns);
    try std.testing.expectEqual(@as(usize, 0), tuner.selectProfile(request).worker_threads);
}

test "adaptive work tuner default gate keeps sub gate batches inline" {
    const request = tunerTestRequest(90, 9, 4, 64);
    for ([_]u64{ 8_000, 30_000, 59_999 }) |cheap_ns| {
        var tuner = AdaptiveWorkTuner.init(.{});
        try std.testing.expectEqual(@as(u64, 60_000), tuner.config.threaded_batch_ns);
        const inline_profile = tuner.selectProfile(request);
        for (0..tuner.config.sample_window) |_| tuner.record(tunerTestBatchWithProfile(90, inline_profile, cheap_ns));
        try std.testing.expectEqual(AdaptiveWorkPhase.settled, tuner.phase);
        try std.testing.expect(!tuner.has_threaded_profile);
        try std.testing.expectEqual(@as(usize, 0), tuner.selectProfile(request).worker_threads);
    }
}

test "adaptive work tuner default gate probes batches from the gate up" {
    const request = tunerTestRequest(1024, 4, 16, 64);
    for ([_]u64{ 60_000, 100_000, 249_000 }) |gated_ns| {
        var tuner = AdaptiveWorkTuner.init(.{});
        const inline_profile = tuner.selectProfile(request);
        for (0..tuner.config.sample_window) |_| tuner.record(tunerTestBatchWithProfile(1024, inline_profile, gated_ns));
        try std.testing.expectEqual(AdaptiveWorkPhase.probing, tuner.phase);
        try std.testing.expect(tuner.selectProfile(request).worker_threads > 0);
    }
}

test "adaptive work tuner ignores a cold-start spike and stays inline" {
    // The window MEDIAN gates threading, so one slow (cold-start/contention) frame
    // among cheap frames must not push a steady-state-cheap batch into threading.
    var tuner = AdaptiveWorkTuner.init(.{ .initial_range_items = 64, .smallest_range_items = 16, .largest_range_items = 256, .sample_window = 3, .threaded_batch_ns = 50_000 });
    const request = tunerTestRequest(1024, 4, 16, 64);
    const inline_profile = tuner.selectProfile(request);
    for ([_]u64{ 10_000, 200_000, 10_000 }) |duration_ns| tuner.record(tunerTestBatchWithProfile(1024, inline_profile, duration_ns));
    try std.testing.expectEqual(AdaptiveWorkPhase.settled, tuner.phase);
    try std.testing.expect(!tuner.has_threaded_profile);
    try std.testing.expectEqual(@as(usize, 0), tuner.selectProfile(request).worker_threads);
}

test "adaptive work tuner probes the whole pool and commits it only on the threaded margin" {
    // A 200 us inline window probes the pool's 5 batches on 4 workers.
    const request = tunerTestRequest(1024, 4, 16, 64);
    for ([_]struct { threaded_ns: u64, commits: bool }{ .{ .threaded_ns = 40_000, .commits = true }, .{ .threaded_ns = 192_000, .commits = false } }) |case| {
        var tuner = AdaptiveWorkTuner.init(.{ .sample_window = 1, .threaded_batch_ns = 1000 });
        tuner.record(tunerTestBatchWithProfile(1024, tuner.selectProfile(request), 200_000));
        try std.testing.expectEqual(AdaptiveWorkPhase.probing, tuner.phase);
        const candidate = tuner.selectProfile(request);
        try std.testing.expectEqual(AdaptiveWorkProfile{ .worker_threads = 4, .items_per_range = 208 }, candidate);
        // 192 us is 4% faster than inline: inside the 5% margin.
        tuner.record(tunerTestBatchWithProfile(1024, candidate, case.threaded_ns));
        try std.testing.expectEqual(AdaptiveWorkPhase.settled, tuner.phase);
        try std.testing.expectEqual(case.commits, tuner.has_threaded_profile);
        try std.testing.expectEqual(if (case.commits) candidate.worker_threads else 0, tuner.selectProfile(request).worker_threads);
    }
}

test "adaptive work tuner cools down after failed inline threaded probe" {
    var tuner = AdaptiveWorkTuner.init(.{ .sample_window = 1, .threaded_batch_ns = 1000, .inline_probe_cooldown_windows = 2 });
    const request = tunerTestRequest(1024, 4, 16, 64);
    tuner.record(tunerTestBatchWithProfile(1024, tuner.selectProfile(request), 1_000_000));
    tuner.record(tunerTestBatchWithProfile(1024, tuner.selectProfile(request), 960_000));
    try std.testing.expect(tuner.phase == .settled and !tuner.has_threaded_profile);

    // Two cooldown windows at or above the gate stay inline; the third probes.
    for (0..2) |_| {
        const selected = tuner.selectProfile(request);
        try std.testing.expectEqual(@as(usize, 0), selected.worker_threads);
        tuner.record(tunerTestBatchWithProfile(1024, selected, 1_000_000));
        try std.testing.expect(tuner.phase == .settled);
    }
    tuner.record(tunerTestBatchWithProfile(1024, tuner.selectProfile(request), 1_000_000));
    try std.testing.expectEqual(AdaptiveWorkPhase.probing, tuner.phase);
    try std.testing.expect(tuner.candidate_profile.?.worker_threads > 0);
}

// A pool of 15 at 4,096 items committed threaded against a 10 ms inline window: the
// whole pool's 16 batches on 15 workers.
fn threadedPoolTuner(sample_window: usize) !AdaptiveWorkTuner {
    var tuner = AdaptiveWorkTuner.init(.{ .smallest_range_items = 16, .sample_window = sample_window, .threaded_batch_ns = 1000 });
    _ = recordTunerWindow(&tuner, pool_request, 10_000_000);
    try std.testing.expectEqual(pool_shape, recordTunerWindow(&tuner, pool_request, 300_000));
    try std.testing.expect(tuner.phase == .settled and tuner.has_threaded_profile);
    try std.testing.expectEqual(pool_shape, tuner.selectProfile(pool_request));
    return tuner;
}

const pool_request = tunerTestRequest(4096, 15, 16, 64);
const pool_shape = AdaptiveWorkProfile{ .worker_threads = 15, .items_per_range = 256 };

// Records one full window of `duration_ns` batches at the tuner's selection.
fn recordTunerWindow(tuner: *AdaptiveWorkTuner, request: AdaptiveWorkRequest, duration_ns: u64) AdaptiveWorkProfile {
    const selected = tuner.selectProfile(request);
    for (0..tuner.config.sample_window) |_| {
        tuner.record(tunerTestBatchWithProfile(request.item_count, tuner.selectProfile(request), duration_ns));
    }
    return selected;
}

// Records `count` threaded batches of `duration_ns` at the tuner's selection.
fn recordThreadedBatches(tuner: *AdaptiveWorkTuner, count: usize, duration_ns: u64) void {
    for (0..count) |_| tuner.record(tunerTestBatchWithProfile(pool_request.item_count, tuner.selectProfile(pool_request), duration_ns));
}

test "median of three picks the middle key in every order, ties included" {
    for ([_]u64{ 1, 2, 3 }) |a| for ([_]u64{ 1, 2, 3 }) |b| for ([_]u64{ 1, 2, 3 }) |c| {
        var sorted = [3]u64{ a, b, c };
        std.mem.sort(u64, &sorted, {}, std.sort.asc(u64));
        const keys = [3]u64{ a, b, c };
        try std.testing.expectEqual(sorted[1], keys[medianIndexOfThree(u64, keys)]);
    };
}

test "adaptive work tuner seeds the throughput EMA on its first threaded batch and clips later ones to twice the band" {
    var tuner = AdaptiveWorkTuner.init(.{ .sample_window = 1, .threaded_batch_ns = 1000 });
    tuner.record(tunerTestBatchWithProfile(4096, pool_shape, 200_000));
    const seeded: f64 = 4096.0 / 200_000.0;
    try std.testing.expectEqual(seeded, tuner.throughput_ema);
    // Inside the clip the sample blends as it is; twice as fast blends at 1.1 x the EMA.
    tuner.record(tunerTestBatchWithProfile(4096, pool_shape, 190_000));
    const blended = seeded * 0.85 + 4096.0 / 190_000.0 * 0.15;
    try std.testing.expectEqual(blended, tuner.throughput_ema);
    tuner.record(tunerTestBatchWithProfile(4096, pool_shape, 95_000));
    try std.testing.expectEqual(blended * 0.85 + blended * 1.1 * 0.15, tuner.throughput_ema);
}

test "adaptive work tuner nudges the multiplier down once the EMA settles, and the threaded shape follows" {
    var tuner = try threadedPoolTuner(1);
    // The probe window was the EMA's first sample; six more settle it.
    recordThreadedBatches(&tuner, tuner.config.nudge_samples - 2, 300_000);
    try std.testing.expectEqual(@as(f64, 1), tuner.batch_multiplier);
    recordThreadedBatches(&tuner, 1, 300_000);
    try std.testing.expectApproxEqRel(pool_first_step, tuner.batch_multiplier, 1e-12);
    // round(16 / 1.1) = 15 batches: workers follow, 14 of them.
    try std.testing.expectEqual(AdaptiveWorkProfile{ .worker_threads = 14, .items_per_range = 288 }, tuner.selectProfile(pool_request));
}

// The pool tuner's multipliers after a step, restated as dispatched batches per
// participant: down from 1.0 dispatches 15 batches of 288, down again 14 of 304, and a flip
// up from 1.0 dispatches 18 of 240.
const pool_first_step: f64 = 15.0 / 16.0;
const pool_second_step: f64 = 14.0 / 16.0;
const pool_flip_step: f64 = 18.0 / 16.0;

// A pool tuner that has just taken its first step, down, from a 300 us reference.
fn steppedPoolTuner() !AdaptiveWorkTuner {
    var tuner = try threadedPoolTuner(1);
    recordThreadedBatches(&tuner, tuner.config.nudge_samples - 1, 300_000);
    try std.testing.expectApproxEqRel(pool_first_step, tuner.batch_multiplier, 1e-12);
    return tuner;
}

test "adaptive work tuner steps again on a gain beyond the band" {
    var tuner = try steppedPoolTuner();
    // 25% more throughput: the clipped EMA rises about 11% above the reference.
    recordThreadedBatches(&tuner, tuner.config.nudge_samples - 1, 240_000);
    try std.testing.expectApproxEqRel(pool_first_step, tuner.batch_multiplier, 1e-12);
    recordThreadedBatches(&tuner, 1, 240_000);
    try std.testing.expectApproxEqRel(pool_second_step, tuner.batch_multiplier, 1e-12);
    try std.testing.expectEqual(@as(i8, -1), tuner.nudge_direction);
}

test "adaptive work tuner flips and steps back past the reference on a loss beyond the band" {
    var tuner = try steppedPoolTuner();
    recordThreadedBatches(&tuner, tuner.config.nudge_samples, 375_000);
    try std.testing.expectEqual(@as(i8, 1), tuner.nudge_direction);
    try std.testing.expectApproxEqRel(pool_flip_step, tuner.batch_multiplier, 1e-12);
    // round(16 x 1.1) = 18 batches, on the whole pool.
    try std.testing.expectEqual(AdaptiveWorkProfile{ .worker_threads = 15, .items_per_range = 240 }, tuner.selectProfile(pool_request));
}

test "adaptive work tuner holds inside the band and resumes on a sustained departure" {
    var tuner = try steppedPoolTuner();
    recordThreadedBatches(&tuner, tuner.config.nudge_samples, 310_000);
    try std.testing.expectEqual(NudgeState.holding, tuner.nudge_state);
    try std.testing.expectApproxEqRel(pool_first_step, tuner.batch_multiplier, 1e-12);

    // A steady EMA holds; one beyond the band for a full count of samples in a row
    // resumes stepping in the current direction. The clipped EMA leaves the band on the
    // fourth faster sample, so the step comes on the tenth.
    recordThreadedBatches(&tuner, 20, 310_000);
    try std.testing.expectEqual(NudgeState.holding, tuner.nudge_state);
    recordThreadedBatches(&tuner, 3 + tuner.config.nudge_samples - 1, 248_000);
    try std.testing.expectEqual(NudgeState.holding, tuner.nudge_state);
    try std.testing.expectApproxEqRel(pool_first_step, tuner.batch_multiplier, 1e-12);
    recordThreadedBatches(&tuner, 1, 248_000);
    try std.testing.expectApproxEqRel(pool_second_step, tuner.batch_multiplier, 1e-12);
    try std.testing.expectEqual(NudgeState.stepped, tuner.nudge_state);
}

test "adaptive work tuner a stepped comparison judges a true 5% change, not 5% of the EMA" {
    // Just over a true 5% gain steps again; a true 3% holds; a true 6% loss flips.
    for ([_]struct { duration_ns: u64, multiplier: f64, state: NudgeState }{
        .{ .duration_ns = 285_000, .multiplier = pool_second_step, .state = .stepped },
        .{ .duration_ns = 291_000, .multiplier = pool_first_step, .state = .holding },
        .{ .duration_ns = 318_000, .multiplier = pool_flip_step, .state = .stepped },
    }) |case| {
        var tuner = try steppedPoolTuner();
        recordThreadedBatches(&tuner, tuner.config.nudge_samples, case.duration_ns);
        try std.testing.expectEqual(case.state, tuner.nudge_state);
        try std.testing.expectApproxEqRel(case.multiplier, tuner.batch_multiplier, 1e-12);
    }
}

test "adaptive work tuner a step restates the multiplier as the dispatched batches per participant" {
    // A pool of 24 at 1,024 items aligned to 64: 16 ranges at most. Down steps keep 16
    // until 1.1^-5, which aligns to 8 ranges of 128: a third of the pool.
    const request = tunerTestRequest(1024, 23, 64, 64);
    var tuner = AdaptiveWorkTuner.init(.{ .sample_window = 1, .threaded_batch_ns = 1000 });
    tuner.record(tunerTestBatchWithProfile(1024, tuner.selectProfile(request), 10_000_000));
    const probe = tuner.selectProfile(request);
    try std.testing.expectEqual(AdaptiveWorkProfile{ .worker_threads = 15, .items_per_range = 64 }, probe);
    for (0..tuner.config.nudge_samples) |_| tuner.record(tunerTestBatchWithProfile(1024, tuner.selectProfile(request), 300_000));
    try std.testing.expectEqual(AdaptiveWorkProfile{ .worker_threads = 7, .items_per_range = 128 }, tuner.selectProfile(request));
    try std.testing.expectApproxEqRel(@as(f64, 8.0 / 24.0), tuner.batch_multiplier, 1e-12);
}

test "adaptive work tuner one outlier batch never resumes a held nudge" {
    var tuner = try steppedPoolTuner();
    recordThreadedBatches(&tuner, tuner.config.nudge_samples, 310_000);
    try std.testing.expectEqual(NudgeState.holding, tuner.nudge_state);
    recordThreadedBatches(&tuner, 1, 3_100_000);
    recordThreadedBatches(&tuner, 2 * tuner.config.nudge_samples, 310_000);
    try std.testing.expectEqual(NudgeState.holding, tuner.nudge_state);
    try std.testing.expectApproxEqRel(pool_first_step, tuner.batch_multiplier, 1e-12);
}

test "adaptive work tuner one slow batch before a comparison never flips the nudge" {
    var tuner = try steppedPoolTuner();
    recordThreadedBatches(&tuner, tuner.config.nudge_samples - 1, 300_000);
    recordThreadedBatches(&tuner, 1, 600_000);
    try std.testing.expectEqual(NudgeState.holding, tuner.nudge_state);
    try std.testing.expectEqual(@as(i8, -1), tuner.nudge_direction);
    try std.testing.expectApproxEqRel(pool_first_step, tuner.batch_multiplier, 1e-12);
}

test "adaptive work tuner a step that leaves the batch shape unchanged keeps stepping until it changes" {
    // At the pool request, 1.1^5 and 1.1^6 x the pool both round to 160-item batches.
    var tuner = try steppedPoolTuner();
    tuner.nudge_direction = 1;
    tuner.batch_multiplier = std.math.pow(f64, 1.1, 5);
    tuner.current_profile = tuner.batchShape(pool_request);
    try std.testing.expectEqual(AdaptiveWorkProfile{ .worker_threads = 15, .items_per_range = 160 }, tuner.current_profile);
    recordThreadedBatches(&tuner, tuner.config.nudge_samples, 200_000);
    // Restated as its 29 batches of 144 per 16 participants.
    try std.testing.expectApproxEqRel(@as(f64, 29.0 / 16.0), tuner.batch_multiplier, 1e-12);
    try std.testing.expectEqual(AdaptiveWorkProfile{ .worker_threads = 15, .items_per_range = 144 }, tuner.selectProfile(pool_request));
}

// A pool tuner held at a steady 300 us EMA, then set at `multiplier` with its shape
// dispatched, stepped in `direction` from `reference_multiplier`, whose EMA was
// `reference_ratio` x the current one.
fn craftedSteppedTuner(multiplier: f64, direction: i8, reference_multiplier: f64, reference_ratio: f64) !AdaptiveWorkTuner {
    var tuner = try steppedPoolTuner();
    recordThreadedBatches(&tuner, 3 * tuner.config.nudge_samples, 300_000);
    tuner.batch_multiplier = multiplier;
    tuner.current_profile = tuner.batchShape(pool_request);
    tuner.nudge_direction = direction;
    tuner.nudge_state = .stepped;
    tuner.nudge_samples = 0;
    tuner.reference_multiplier = reference_multiplier;
    tuner.reference_ema = tuner.throughput_ema * reference_ratio;
    return tuner;
}

test "adaptive work tuner at the clamp reverses and holds without comparing a shape with itself" {
    // Stepped up to 4.0 and won: a further step cannot pass the clamp.
    var tuner = try craftedSteppedTuner(max_batch_multiplier, 1, max_batch_multiplier / 1.1, 0.9);
    recordThreadedBatches(&tuner, tuner.config.nudge_samples, 300_000);
    try std.testing.expectEqual(NudgeState.holding, tuner.nudge_state);
    try std.testing.expectEqual(@as(i8, -1), tuner.nudge_direction);
    try std.testing.expectEqual(max_batch_multiplier, tuner.batch_multiplier);
    // Steady batches at the clamp spend no further comparison.
    recordThreadedBatches(&tuner, 3 * tuner.config.nudge_samples, 300_000);
    try std.testing.expectEqual(NudgeState.holding, tuner.nudge_state);
    try std.testing.expectEqual(max_batch_multiplier, tuner.batch_multiplier);
}

test "adaptive work tuner a flip whose step back starts at the clamp holds at the reference shape" {
    // Stepped down from 4.0, which ran 20% faster, and lost: the step back cannot pass
    // 4.0, so the 4.0 shape returns and holds against the EMA measured there.
    var tuner = try craftedSteppedTuner(max_batch_multiplier / 1.1, -1, max_batch_multiplier, 1.2);
    const clamp_ema = tuner.reference_ema;
    recordThreadedBatches(&tuner, tuner.config.nudge_samples, 300_000);
    try std.testing.expectEqual(NudgeState.holding, tuner.nudge_state);
    try std.testing.expectEqual(max_batch_multiplier, tuner.batch_multiplier);
    try std.testing.expectEqual(clamp_ema, tuner.reference_ema);
    try std.testing.expectEqual(tuner.batchShape(pool_request), tuner.selectProfile(pool_request));
}

test "adaptive work tuner clamps the multiplier at 0.25 and 4.0" {
    var up = try steppedPoolTuner();
    up.nudge_direction = 1;
    up.batch_multiplier = 3.9;
    recordThreadedBatches(&up, up.config.nudge_samples, 200_000);
    try std.testing.expectEqual(@as(f64, 4.0), up.batch_multiplier);

    var down = try steppedPoolTuner();
    down.batch_multiplier = 0.26;
    recordThreadedBatches(&down, down.config.nudge_samples, 200_000);
    try std.testing.expectEqual(@as(f64, 0.25), down.batch_multiplier);
}

test "adaptive work tuner workers follow the multiplier's batch count" {
    var tuner = try threadedPoolTuner(1);
    for ([_]struct { multiplier: f64, shape: AdaptiveWorkProfile }{
        .{ .multiplier = 0.25, .shape = .{ .worker_threads = 3, .items_per_range = 1024 } },
        .{ .multiplier = 0.5, .shape = .{ .worker_threads = 7, .items_per_range = 512 } },
        .{ .multiplier = 2.0, .shape = .{ .worker_threads = 15, .items_per_range = 128 } },
    }) |case| {
        tuner.batch_multiplier = case.multiplier;
        try std.testing.expectEqual(case.shape, tuner.batchShape(pool_request));
    }
}

test "adaptive work tuner a pinned tuner never nudges" {
    var tuner = try threadedPoolTuner(1);
    const pinned = AdaptiveWorkProfile{ .worker_threads = 2, .items_per_range = 16 };
    tuner.config.nudge_samples = std.math.maxInt(usize);
    tuner.current_profile = pinned;
    recordThreadedBatches(&tuner, 64, 300_000);
    recordThreadedBatches(&tuner, 64, 100_000);
    try std.testing.expectEqual(@as(f64, 1), tuner.batch_multiplier);
    try std.testing.expectEqual(pinned, tuner.selectProfile(pool_request));
}

test "adaptive work tuner a count shift keeps the multiplier and reshapes from it at the new count" {
    var tuner = try threadedPoolTuner(1);
    tuner.batch_multiplier = 0.5;
    const shifted_request = tunerTestRequest(8192, 15, 16, 64);
    // At one-batch windows a single shifted selection is sustained: 8 batches of 1,024.
    try std.testing.expectEqual(AdaptiveWorkProfile{ .worker_threads = 7, .items_per_range = 1024 }, tuner.selectProfile(shifted_request));
    try std.testing.expect(tuner.retune_pending and tuner.has_threaded_profile);
    try std.testing.expectEqual(@as(f64, 0.5), tuner.batch_multiplier);
    // The next window re-decides threading at the new count and stays threaded.
    tuner.record(tunerTestBatchWithProfile(8192, tuner.selectProfile(shifted_request), 600_000));
    try std.testing.expect(!tuner.retune_pending and tuner.has_threaded_profile);
}

test "adaptive work tuner a relearn from inline resets the multiplier and the EMA" {
    var tuner = try threadedPoolTuner(1);
    tuner.batch_multiplier = 0.5;
    // A demotion keeps the multiplier; a sustained shift on the demoted tuner relearns.
    tuner.demoteToInline();
    try std.testing.expectEqual(@as(f64, 0.5), tuner.batch_multiplier);
    _ = tuner.selectProfile(tunerTestRequest(8192, 15, 16, 64));
    try std.testing.expectEqual(AdaptiveWorkPhase.learning, tuner.phase);
    try std.testing.expectEqual(@as(f64, 1), tuner.batch_multiplier);
    try std.testing.expectEqual(@as(f64, 0), tuner.throughput_ema);
    try std.testing.expectEqual(NudgeState.measuring, tuner.nudge_state);
}

test "adaptive work tuner a demotion and a count shift restart the nudge and keep the multiplier" {
    const Restart = enum { demotion, count_shift };
    for (std.enums.values(Restart)) |restart| {
        var tuner = try steppedPoolTuner();
        const multiplier = tuner.batch_multiplier;
        switch (restart) {
            .demotion => tuner.demoteToInline(),
            .count_shift => _ = tuner.selectProfile(tunerTestRequest(8192, 15, 16, 64)),
        }
        try std.testing.expectEqual(NudgeState.measuring, tuner.nudge_state);
        try std.testing.expectEqual(@as(f64, 0), tuner.throughput_ema);
        try std.testing.expectEqual(@as(usize, 0), tuner.nudge_samples);
        try std.testing.expectEqual(@as(i8, -1), tuner.nudge_direction);
        try std.testing.expectEqual(multiplier, tuner.batch_multiplier);
    }
}

test "adaptive work tuner each threaded probe lost to inline halves the next probe's batches" {
    const request = tunerTestRequest(4096, 15, 16, 64);
    var tuner = AdaptiveWorkTuner.init(.{ .sample_window = 1, .threaded_batch_ns = 1000, .inline_probe_cooldown_windows = 0 });
    tuner.record(tunerTestBatchWithProfile(4096, tuner.selectProfile(request), 10_000_000));
    for ([_]AdaptiveWorkProfile{ pool_shape, .{ .worker_threads = 7, .items_per_range = 512 } }) |probe| {
        try std.testing.expectEqual(AdaptiveWorkPhase.probing, tuner.phase);
        try std.testing.expectEqual(probe, tuner.selectProfile(request));
        tuner.record(tunerTestBatchWithProfile(4096, probe, 9_800_000));
        try std.testing.expect(tuner.phase == .settled and !tuner.has_threaded_profile);
        // The lost probe's sample does not carry into the next probe's measurement.
        try std.testing.expect(tuner.nudge_state == .measuring and tuner.throughput_ema == 0);
        tuner.record(tunerTestBatchWithProfile(4096, tuner.selectProfile(request), 10_000_000));
    }
    try std.testing.expectEqual(@as(f64, 0.25), tuner.batch_multiplier);
}

test "adaptive work tuner keeps one window across threaded shape changes and resets it on an inline switch" {
    var tuner = AdaptiveWorkTuner.init(.{ .sample_window = 4 });
    tuner.record(tunerTestBatchWithProfile(1024, .{ .worker_threads = 1, .items_per_range = 64 }, 1000));
    tuner.record(tunerTestBatchWithProfile(1024, .{ .worker_threads = 2, .items_per_range = 32 }, 1000));
    try std.testing.expectEqual(@as(usize, 2), tuner.sample_count);
    tuner.record(tunerTestBatchWithProfile(1024, .{ .worker_threads = 0, .items_per_range = 1024 }, 1000));
    try std.testing.expectEqual(@as(usize, 1), tuner.sample_count);
}

// Bound-rule fixture: 200 us inline, settled threaded at 80 us; a cheap threaded
// window then has duration x participants below the 50 us gate.
fn boundRuleTestTuner() AdaptiveWorkTuner {
    return AdaptiveWorkTuner.init(.{ .initial_range_items = 64, .smallest_range_items = 16, .largest_range_items = 256, .sample_window = 1, .threaded_batch_ns = 50_000 });
}

fn boundRuleCheapNs(profile: AdaptiveWorkProfile) u64 {
    return (50_000 / (profile.worker_threads + 1)) / 2;
}

// Settles `tuner` on the threaded pool shape that beat a measured 200 us inline window at
// 80 us, for `request`.
fn settleTunerThreadedAgainstExpensiveInline(tuner: *AdaptiveWorkTuner, request: AdaptiveWorkRequest) !AdaptiveWorkProfile {
    try std.testing.expectEqual(@as(usize, 0), recordTunerWindow(tuner, request, 200_000).worker_threads);
    try std.testing.expectEqual(AdaptiveWorkPhase.probing, tuner.phase);
    try std.testing.expect(recordTunerWindow(tuner, request, 80_000).worker_threads > 0);
    try std.testing.expect(tuner.phase == .settled and tuner.has_threaded_profile);
    const settled_profile = tuner.selectProfile(request);
    try std.testing.expect(settled_profile.worker_threads > 0);
    return settled_profile;
}

// Settles threaded, then records one cheap threaded window, which the bound rule demotes.
fn demoteByBoundRule(tuner: *AdaptiveWorkTuner, request: AdaptiveWorkRequest) !AdaptiveWorkProfile {
    const settled_profile = try settleTunerThreadedAgainstExpensiveInline(tuner, request);
    tuner.record(tunerTestBatchWithProfile(request.item_count, settled_profile, boundRuleCheapNs(settled_profile)));
    try std.testing.expect(!tuner.has_threaded_profile);
    try std.testing.expectEqual(@as(usize, 0), tuner.selectProfile(request).worker_threads);
    return settled_profile;
}

// Demotes by the bound rule, then records an expensive inline window that restores.
fn restoreAfterWrongDemotion(tuner: *AdaptiveWorkTuner, request: AdaptiveWorkRequest) !AdaptiveWorkProfile {
    const settled_profile = try demoteByBoundRule(tuner, request);
    tuner.record(tunerTestBatchWithProfile(request.item_count, tuner.selectProfile(request), 200_000));
    try std.testing.expect(tuner.has_threaded_profile);
    try std.testing.expectEqual(settled_profile, tuner.selectProfile(request));
    return settled_profile;
}

test "adaptive work tuner demotes threaded to inline when duration x participants falls under the gate" {
    var tuner = boundRuleTestTuner();
    _ = try demoteByBoundRule(&tuner, tunerTestRequest(2048, 4, 16, 64));
    try std.testing.expect(tuner.restore_threaded_profile != null);
}

test "adaptive work tuner the bound rule judges the window median of each batch's duration x its own participants" {
    // Three threaded batches of 10 us: on 1, 15, and 15 participants. The median of
    // duration x participants is 150 us, over the 50 us gate; the latest batch's
    // participants alone would not decide it.
    var tuner = boundRuleTestTuner();
    tuner.config.sample_window = 3;
    tuner.has_threaded_profile = true;
    tuner.phase = .settled;
    tuner.current_profile = .{ .worker_threads = 14, .items_per_range = 16 };
    for ([_]usize{ 14, 14, 0 }) |workers| {
        if (workers == 0) {
            tuner.record(tunerTestBatchWithProfile(1024, .{ .worker_threads = 1, .items_per_range = 16 }, 10_000));
        } else {
            tuner.record(tunerTestBatchWithProfile(1024, .{ .worker_threads = workers, .items_per_range = 16 }, 10_000));
        }
    }
    try std.testing.expect(tuner.has_threaded_profile);

    // A window whose median product is under the gate demotes: 10 us on 2, 2, and 15.
    for ([_]usize{ 1, 1, 14 }) |workers| tuner.record(tunerTestBatchWithProfile(1024, .{ .worker_threads = workers, .items_per_range = 16 }, 10_000));
    try std.testing.expect(!tuner.has_threaded_profile);
}

test "adaptive work tuner a wrong bound demotion restores the threaded profile after one inline window" {
    var tuner = boundRuleTestTuner();
    const request = tunerTestRequest(90, 9, 4, 64);
    const settled_profile = try restoreAfterWrongDemotion(&tuner, request);
    // The restore suppresses the bound rule: a cheap threaded window keeps it threaded.
    tuner.record(tunerTestBatchWithProfile(90, settled_profile, boundRuleCheapNs(settled_profile)));
    try std.testing.expect(tuner.has_threaded_profile and tuner.bound_rule_suppressed);
    try std.testing.expectEqual(settled_profile, tuner.selectProfile(request));
}

test "adaptive work tuner a correct bound demotion stays inline" {
    var tuner = boundRuleTestTuner();
    const request = tunerTestRequest(90, 9, 4, 64);
    _ = try demoteByBoundRule(&tuner, request);
    tuner.record(tunerTestBatchWithProfile(90, tuner.selectProfile(request), 10_000));
    try std.testing.expect(!tuner.has_threaded_profile);
    // The cooldown from the confirmed demotion still holds off an expensive window.
    tuner.record(tunerTestBatchWithProfile(90, tuner.selectProfile(request), 200_000));
    try std.testing.expect(!tuner.has_threaded_profile);
    try std.testing.expectEqual(AdaptiveWorkPhase.settled, tuner.phase);
    try std.testing.expectEqual(@as(usize, 0), tuner.selectProfile(request).worker_threads);
}

test "adaptive work tuner a sustained item-count shift lifts the bound suppression" {
    var tuner = boundRuleTestTuner();
    _ = try restoreAfterWrongDemotion(&tuner, tunerTestRequest(90, 9, 4, 64));
    // At one-batch windows a single shifted selection is sustained. The model still
    // predicts threaded at the new count, so only the bound rule can demote here.
    const shifted_request = tunerTestRequest(60, 9, 4, 64);
    const shifted = tuner.selectProfile(shifted_request);
    try std.testing.expect(shifted.worker_threads > 0 and !tuner.bound_rule_suppressed);
    try std.testing.expect(tuner.predictsThreaded(tuner.normalizeRequest(shifted_request)));
    tuner.record(tunerTestBatchWithProfile(60, shifted, boundRuleCheapNs(shifted)));
    try std.testing.expect(!tuner.has_threaded_profile);
}

test "adaptive work tuner a demotion whose profile cannot dispatch at a shrunk count stays inline" {
    var tuner = boundRuleTestTuner();
    _ = try settleTunerThreadedAgainstExpensiveInline(&tuner, tunerTestRequest(90, 9, 4, 64));
    // Four items fit one range of any threaded profile, yet stay above the gate.
    const shrunk_request = tunerTestRequest(4, 9, 4, 64);
    var flips: usize = 0;
    var was_threaded = tuner.has_threaded_profile;
    for (0..8) |_| {
        const selected = tuner.selectProfile(shrunk_request);
        try std.testing.expectEqual(@as(usize, 0), selected.worker_threads);
        tuner.record(tunerTestBatchWithProfile(4, selected, 200_000));
        if (tuner.has_threaded_profile != was_threaded) flips += 1;
        was_threaded = tuner.has_threaded_profile;
    }
    try std.testing.expect(flips <= 1);
}

test "adaptive work tuner keeps a threaded profile learned while demoted over the remembered one" {
    var tuner = boundRuleTestTuner();
    const request = tunerTestRequest(90, 9, 4, 64);
    const settled_profile = try demoteByBoundRule(&tuner, request);
    // A threaded window the tuner did not select, below the gate but with duration x
    // participants above it, is adopted as the threaded profile.
    const learned_profile = AdaptiveWorkProfile{ .worker_threads = 1, .items_per_range = 48 };
    try std.testing.expect(!profilesEqual(learned_profile, settled_profile));
    tuner.record(tunerTestBatchWithProfile(90, learned_profile, 30_000));
    try std.testing.expect(tuner.has_threaded_profile);
    try std.testing.expectEqual(learned_profile, tuner.current_profile);
    tuner.record(tunerTestBatchWithProfile(90, AdaptiveWorkProfile{ .worker_threads = 0, .items_per_range = 64 }, 200_000));
    try std.testing.expectEqual(learned_profile, tuner.current_profile);
}

test "adaptive work tuner a predicted-inline shift demotion is also judged by the first inline window" {
    var tuner = boundRuleTestTuner();
    _ = try settleTunerThreadedAgainstExpensiveInline(&tuner, tunerTestRequest(90, 9, 4, 64));
    // A sub-gate per-item model makes the shift's threading decision predict inline; the
    // threaded window itself stays above the bound rule.
    tuner.model_work_ns_per_item = 500;
    const shifted_request = tunerTestRequest(60, 9, 4, 64);
    const shifted = tuner.selectProfile(shifted_request);
    try std.testing.expect(shifted.worker_threads > 0);
    tuner.record(tunerTestBatchWithProfile(60, shifted, 48_000));
    try std.testing.expect(!tuner.has_threaded_profile);

    tuner.record(tunerTestBatchWithProfile(60, tuner.selectProfile(shifted_request), 200_000));
    try std.testing.expect(tuner.has_threaded_profile);
    try std.testing.expectEqual(shifted, tuner.selectProfile(shifted_request));
}

test "adaptive work tuner a restored profile that collapses to one range at an in-band count stays threaded" {
    // Restored at 80 items on 64-item ranges; at 64 items (20% down, inside the band) the
    // profile is one range, so the window runs inline over the gate.
    var tuner = boundRuleTestTuner();
    const request = tunerTestRequest(80, 9, 64, 64);
    const restored = try restoreAfterWrongDemotion(&tuner, request);
    try std.testing.expectEqual(@as(usize, 64), restored.items_per_range);
    try std.testing.expect(tuner.bound_rule_suppressed);
    const shrunk = tunerTestRequest(64, 9, 64, 64);
    const selected = tuner.selectProfile(shrunk);
    try std.testing.expectEqual(@as(usize, 0), selected.worker_threads);
    tuner.record(tunerTestBatchWithProfile(64, selected, 200_000));
    try std.testing.expect(tuner.has_threaded_profile and tuner.bound_rule_suppressed);
}

test "adaptive work tuner a sustained shift while demoted drops the remembered profile" {
    var tuner = boundRuleTestTuner();
    _ = try demoteByBoundRule(&tuner, tunerTestRequest(90, 9, 4, 64));
    try std.testing.expect(tuner.restore_threaded_profile != null);
    _ = tuner.selectProfile(tunerTestRequest(60, 9, 4, 64));
    try std.testing.expectEqual(AdaptiveWorkPhase.learning, tuner.phase);
    try std.testing.expectEqual(@as(?AdaptiveWorkProfile, null), tuner.restore_threaded_profile);
}

test "adaptive work tuner keeps a stage threaded when its inline run absorbs work the threaded run does not" {
    var tuner = AdaptiveWorkTuner.init(.{ .initial_range_items = 64, .smallest_range_items = 16, .largest_range_items = 1024, .threaded_batch_ns = 250_000 });
    // Inline 270 us is above the 250 us gate; threaded 120 us / P + 20 us keeps
    // duration x participants below it for every reachable P. Windows: inline, the
    // committed probe, then the settled window the bound rule demotes.
    for (0..2 * tuner.config.sample_window) |_| _ = tunerScenarioStepInlineAbsorbs(&tuner, 1000, 120, 150);
    try std.testing.expect(tuner.has_threaded_profile and tuner.phase == .settled);
    for (0..tuner.config.sample_window) |_| _ = tunerScenarioStepInlineAbsorbs(&tuner, 1000, 120, 150);
    try std.testing.expect(tuner.restore_threaded_profile != null and !tuner.has_threaded_profile);

    // The judging inline window measures above the gate and restores the threaded profile.
    for (0..tuner.config.sample_window) |_| {
        try std.testing.expectEqual(@as(usize, 0), tunerScenarioStepInlineAbsorbs(&tuner, 1000, 120, 150));
    }
    try std.testing.expect(tuner.has_threaded_profile);

    // The restored profile skips the bound rule: its next window stays threaded.
    for (0..tuner.config.sample_window) |_| {
        try std.testing.expect(tunerScenarioStepInlineAbsorbs(&tuner, 1000, 120, 150) > 0);
    }
    try std.testing.expect(tuner.has_threaded_profile);
}

test "adaptive work tuner a faster threaded window over the gate never demotes" {
    // A 40% faster threaded window at an unchanged inline cost (a scheduling regime
    // change): window x participants stays far over the gate.
    var tuner = AdaptiveWorkTuner.init(.{ .smallest_range_items = 16, .sample_window = 1 });
    _ = recordTunerWindow(&tuner, pool_request, 10_000_000);
    _ = recordTunerWindow(&tuner, pool_request, 300_000);
    try std.testing.expect(tuner.has_threaded_profile);
    for (0..16) |_| {
        _ = recordTunerWindow(&tuner, pool_request, 180_000);
        try std.testing.expect(tuner.has_threaded_profile);
    }
}

test "adaptive work tuner demotes a wait dominated threaded batch whose work is tiny" {
    var tuner = boundRuleTestTuner();
    const req = tunerTestRequest(90, 9, 4, 64);
    const settled_profile = try settleTunerThreadedAgainstExpensiveInline(&tuner, req);
    // Parallel overhead without useful work: the whole batch, mostly main waiting, times
    // every participant is still below the gate, so inline is provably cheap.
    const tiny_duration_ns: u64 = (50_000 / (settled_profile.worker_threads + 1)) / 2;
    tuner.record(tunerTestBatchWithProfileEx(90, settled_profile, tiny_duration_ns, tiny_duration_ns * 9 / 10));
    try std.testing.expect(!tuner.has_threaded_profile);
    try std.testing.expectEqual(@as(usize, 0), tuner.selectProfile(req).worker_threads);
}

test "adaptive work tuner keeps a threaded profile through a wait dominated sub gate window" {
    var tuner = boundRuleTestTuner();
    // One worker: two participants, so main's busy share times them is below the gate.
    const req = tunerTestRequest(90, 1, 4, 64);
    const settled_profile = try settleTunerThreadedAgainstExpensiveInline(&tuner, req);
    // Main waiting on workers means the workers did the work: a sub-gate, wait-dominated
    // window says nothing about inline being cheap (it measured 200 us).
    try std.testing.expect((48_000 - 30_000) * (settled_profile.worker_threads + 1) < 50_000);
    tuner.record(tunerTestBatchWithProfileEx(90, settled_profile, 48_000, 30_000));
    try std.testing.expect(tuner.has_threaded_profile);
    try std.testing.expectEqual(settled_profile.worker_threads, tuner.selectProfile(req).worker_threads);
}

test "adaptive work tuner resets sample window after a sustained item count shift" {
    var tuner = AdaptiveWorkTuner.init(.{ .initial_range_items = 64, .sample_window = 4, .item_count_reset_percent = 25 });
    tuner.record(tunerTestBatchWithProfile(1024, tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64)), 1000));
    try std.testing.expectEqual(@as(usize, 1), tuner.sample_count);
    // One shifted batch is dispatched without touching the window; a full window
    // of shifted batches in a row is a new workload and relearns.
    for (0..tuner.config.sample_window - 1) |_| {
        _ = tuner.selectProfile(tunerTestRequest(2048, 4, 16, 64));
        try std.testing.expectEqual(@as(usize, 1), tuner.sample_count);
    }
    _ = tuner.selectProfile(tunerTestRequest(2048, 4, 16, 64));
    try std.testing.expectEqual(@as(usize, 0), tuner.sample_count);
    try std.testing.expectEqual(AdaptiveWorkPhase.learning, tuner.phase);
}

test "adaptive work tuner clears an in-progress probe after an item count shift" {
    var tuner = AdaptiveWorkTuner.init(.{ .initial_range_items = 64, .sample_window = 1, .item_count_reset_percent = 25, .threaded_batch_ns = 1 });
    tuner.record(tunerTestBatchWithProfile(1024, tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64)), 1_000_000));
    try std.testing.expectEqual(AdaptiveWorkPhase.probing, tuner.phase);
    _ = tuner.selectProfile(tunerTestRequest(2048, 4, 16, 64));
    try std.testing.expectEqual(AdaptiveWorkPhase.learning, tuner.phase);
    try std.testing.expect(!tuner.has_threaded_profile);
    try std.testing.expectEqual(@as(?AdaptiveWorkProfile, null), tuner.candidate_profile);
}

test "adaptive work tuner keeps aligned items_per_range within max when possible" {
    var tuner = AdaptiveWorkTuner.init(.{ .initial_range_items = 90, .smallest_range_items = 1, .largest_range_items = 100 });
    try std.testing.expectEqual(@as(usize, 64), tuner.selectProfile(tunerTestRequest(1024, 4, 64, 90)).items_per_range);
}

test "adaptive work tuner threads an expensive stage whose item count drifts every step" {
    var tuner = AdaptiveWorkTuner.init(.{ .initial_range_items = 64, .smallest_range_items = 16, .largest_range_items = 1024 });
    var inline_steps_after_warmup: usize = 0;
    for (0..240) |step| {
        const item_count = 4000 + (step % 7) * 40;
        const workers = tunerScenarioStep(&tuner, item_count, 150);
        if (step >= 120 and workers == 0) inline_steps_after_warmup += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), inline_steps_after_warmup);
}

test "adaptive work tuner keeps a threaded stage threaded across one-step small batches" {
    var tuner = AdaptiveWorkTuner.init(.{ .initial_range_items = 64, .smallest_range_items = 16, .largest_range_items = 1024 });
    var inline_large_steps_after_warmup: usize = 0;
    for (0..240) |step| {
        const item_count: usize = if (step % 10 == 9) 8 else 4000;
        const workers = tunerScenarioStep(&tuner, item_count, 150);
        if (step >= 120 and item_count == 4000 and workers == 0) inline_large_steps_after_warmup += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), inline_large_steps_after_warmup);
}

test "adaptive work tuner keeps an expensive stage threaded under random per-step load" {
    var tuner = AdaptiveWorkTuner.init(.{ .initial_range_items = 64, .smallest_range_items = 16, .largest_range_items = 1024 });
    var prng = std.Random.DefaultPrng.init(0x7531);
    const random = prng.random();
    var inline_steps_after_warmup: usize = 0;
    for (0..600) |step| {
        const item_count = random.intRangeAtMost(usize, 2000, 6000);
        const workers = tunerScenarioStep(&tuner, item_count, 150);
        if (step >= 300 and workers == 0) inline_steps_after_warmup += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), inline_steps_after_warmup);
}

test "adaptive work tuner does not sample a single out-of-band batch" {
    var tuner = AdaptiveWorkTuner.init(.{ .initial_range_items = 64, .sample_window = 3 });
    tuner.record(tunerTestBatchWithProfile(1024, tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64)), 1000));
    try std.testing.expectEqual(@as(usize, 1), tuner.sample_count);
    tuner.record(tunerTestBatchWithProfile(10240, tuner.selectProfile(tunerTestRequest(10240, 4, 16, 64)), 50_000_000));
    try std.testing.expectEqual(@as(usize, 1), tuner.sample_count);
    tuner.record(tunerTestBatchWithProfile(1024, tuner.selectProfile(tunerTestRequest(1024, 4, 16, 64)), 1000));
    try std.testing.expectEqual(@as(usize, 2), tuner.sample_count);
}

test "adaptive work tuner keeps a threaded stage threaded when main mostly waits on workers" {
    var tuner = AdaptiveWorkTuner.init(.{ .initial_range_items = 64, .smallest_range_items = 16, .largest_range_items = 1024, .threaded_batch_ns = 250_000 });
    // 600 us inline; threaded on 5 participants about 140 us, below the 250 us gate, with
    // main waiting four fifths of it: its busy time times participants is below the gate.
    var inline_steps_after_warmup: usize = 0;
    for (0..240) |step| {
        const workers = tunerScenarioStepWithWait(&tuner, 4000, 150);
        if (step >= 120 and workers == 0) inline_steps_after_warmup += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), inline_steps_after_warmup);
}

test "adaptive work tuner keeps threading when one batch in a window is near-zero cost" {
    var tuner = AdaptiveWorkTuner.init(.{ .initial_range_items = 64, .smallest_range_items = 16, .largest_range_items = 1024 });
    var inline_steps_after_warmup: usize = 0;
    for (0..240) |step| {
        const ns_per_item: u64 = if (step % 3 == 2) 1 else 150;
        const workers = tunerScenarioStep(&tuner, 4000, ns_per_item);
        if (step >= 120 and workers == 0) inline_steps_after_warmup += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), inline_steps_after_warmup);
}

test "adaptive work tuner a full-pool first selection dispatches workers and a default one runs inline" {
    const request = tunerTestRequest(4096, 4, 16, 64);
    var opted = AdaptiveWorkTuner.init(.{ .first_selection = .full_pool });
    const first = opted.selectProfile(request);
    try std.testing.expectEqual(@as(usize, 4), shapeBatch(4096, first, 4, 16, true).worker_threads);
    try std.testing.expectEqual(5 * full_pool_batches_per_participant, rangeCount(4096, first.items_per_range));

    var default = AdaptiveWorkTuner.init(.{});
    try std.testing.expectEqual(@as(usize, 0), shapeBatch(4096, default.selectProfile(request), 4, 16, true).worker_threads);
}

// A tuner settled inline at 16 items of 1 us each: its per-item model is learned.
fn inlineSettledTestTuner() !AdaptiveWorkTuner {
    var tuner = AdaptiveWorkTuner.init(.{});
    for (0..tuner.config.sample_window) |_| tuner.record(tunerTestBatchWithProfile(16, tuner.selectProfile(tunerTestRequest(16, 4, 16, 64)), 16_000));
    try std.testing.expectEqual(AdaptiveWorkPhase.settled, tuner.phase);
    try std.testing.expect(!tuner.has_threaded_profile and tuner.model_work_ns_per_item > 0);
    return tuner;
}

test "adaptive work tuner an inline-settled tuner with a per-item model threads a count jump" {
    var tuner = try inlineSettledTestTuner();
    const jump = tuner.selectProfile(tunerTestRequest(4096, 4, 16, 64));
    try std.testing.expect(shapeBatch(4096, jump, 4, 16, true).worker_threads > 0);
    // The jump is not sampled and the tuner stays settled inline.
    tuner.record(tunerTestBatchWithProfile(4096, jump, 1_000_000));
    try std.testing.expectEqual(@as(usize, 0), tuner.sample_count);
    try std.testing.expectEqual(AdaptiveWorkPhase.settled, tuner.phase);
    try std.testing.expectEqual(@as(usize, 0), tuner.selectProfile(tunerTestRequest(16, 4, 16, 64)).worker_threads);
}

test "adaptive work tuner without a per-item model selects a count jump inline" {
    var tuner = AdaptiveWorkTuner.init(.{});
    // A zero-duration batch teaches nothing, so the learned count is set but no model is.
    tuner.record(tunerTestBatchWithProfile(16, tuner.selectProfile(tunerTestRequest(16, 4, 16, 64)), 0));
    try std.testing.expectEqual(@as(f64, 0), tuner.model_work_ns_per_item);
    try std.testing.expectEqual(@as(usize, 0), tuner.selectProfile(tunerTestRequest(4096, 4, 16, 64)).worker_threads);
}

// A count jump from the inline-settled 16 items to 64: 64 us of modelled work, threaded.
const count_jump_request = tunerTestRequest(64, 64, 1, 64);

test "adaptive work tuner two jumps to the same count get the same shape" {
    var tuner = try inlineSettledTestTuner();
    const first = tuner.selectProfile(count_jump_request);
    try std.testing.expect(first.worker_threads > 0);
    tuner.record(tunerTestBatchWithProfile(64, first, 64_000));
    // A cheap in-band batch between the jumps moves the per-item model under the gate.
    tuner.record(tunerTestBatchWithProfile(16, tuner.selectProfile(tunerTestRequest(16, 4, 16, 64)), 16));
    try std.testing.expect(!profilesEqual(first, tuner.predictProfile(tuner.normalizeRequest(count_jump_request))));
    try std.testing.expectEqual(first, tuner.selectProfile(count_jump_request));
}

test "adaptive work tuner a jump keeps its held shape across a shifted window median" {
    var tuner = try inlineSettledTestTuner();
    const first = tuner.selectProfile(count_jump_request);
    try std.testing.expect(first.worker_threads > 0);
    tuner.record(tunerTestBatchWithProfile(64, first, 64_000));
    // A whole in-band window at 0.4x the per-item cost moves the median and the model
    // under the gate at the jump's count; it stays inline.
    const median_before = tuner.baseline_mean_batch_duration_ns;
    for (0..tuner.config.sample_window) |_| tuner.record(tunerTestBatchWithProfile(16, tuner.selectProfile(tunerTestRequest(16, 4, 16, 64)), 6_400));
    try std.testing.expect(outsideBand(median_before, tuner.baseline_mean_batch_duration_ns, tuner.config.item_count_reset_percent));
    try std.testing.expect(!tuner.has_threaded_profile);
    try std.testing.expect(!profilesEqual(first, tuner.predictProfile(tuner.normalizeRequest(count_jump_request))));
    try std.testing.expectEqual(first, tuner.selectProfile(count_jump_request));
}

test "adaptive work tuner a threaded-settled tuner re-normalizes its profile for a count jump" {
    // A window above one sample, so a single jump stays unsustained.
    var tuner = AdaptiveWorkTuner.init(.{ .sample_window = 2 });
    _ = try settleTunerThreadedAgainstExpensiveInline(&tuner, tunerTestRequest(1024, 4, 16, 64));
    const jump_request = tuner.normalizeRequest(tunerTestRequest(1536, 4, 16, 64));
    const jump = tuner.selectProfile(jump_request);
    try std.testing.expect(tuner.skip_next_record and tuner.shifted_up);
    // The settled threaded profile, re-normalized to the jump's count; no prediction.
    try std.testing.expectEqual(tuner.normalizedProfile(tuner.current_profile, jump_request), jump);
    try std.testing.expect(tuner.jump_profile == null);
}

// A jump from the inline-settled 16 items to 32: 32 us of modelled work, predicted inline.
const inline_jump_request = tunerTestRequest(32, 64, 1, 64);

// One in-band batch at the settled count and cost, as play runs between two jumps (three
// jumps in a row would be a sustained shift).
fn recordInBandTestBatch(tuner: *AdaptiveWorkTuner) void {
    tuner.record(tunerTestBatchWithProfile(16, tuner.selectProfile(tunerTestRequest(16, 4, 16, 64)), 16_000));
}

// Selects `request` as a jump, records it at `duration_ns`, and checks the record trained
// nothing: no sample and no per-item model change. Returns the jump's selection.
fn recordTestJump(tuner: *AdaptiveWorkTuner, request: AdaptiveWorkRequest, duration_ns: u64) !AdaptiveWorkProfile {
    return recordTestJumpRanAs(tuner, request, null, duration_ns);
}

// `recordTestJump`, with the batch run at `ran` instead of the selection when set (a
// selection that normalized to another shape at dispatch).
fn recordTestJumpRanAs(tuner: *AdaptiveWorkTuner, request: AdaptiveWorkRequest, ran: ?AdaptiveWorkProfile, duration_ns: u64) !AdaptiveWorkProfile {
    recordInBandTestBatch(tuner);
    const selected = tuner.selectProfile(request);
    try std.testing.expect(tuner.skip_next_record and tuner.shifted_up);
    const samples = tuner.sample_count;
    const model = tuner.model_work_ns_per_item;
    tuner.record(tunerTestBatchWithProfile(request.item_count, ran orelse selected, duration_ns));
    try std.testing.expectEqual(samples, tuner.sample_count);
    try std.testing.expectEqual(model, tuner.model_work_ns_per_item);
    return selected;
}

// The selection a repeat of `request` jump gets, after an in-band batch.
fn selectTestJump(tuner: *AdaptiveWorkTuner, request: AdaptiveWorkRequest) AdaptiveWorkProfile {
    recordInBandTestBatch(tuner);
    return tuner.selectProfile(request);
}

test "adaptive work tuner a jump whose inline record reaches the gate repeats threaded" {
    var tuner = try inlineSettledTestTuner();
    try std.testing.expectEqual(@as(usize, 0), (try recordTestJump(&tuner, inline_jump_request, 100_000)).worker_threads);
    try std.testing.expect((try recordTestJump(&tuner, inline_jump_request, 40_000)).worker_threads > 0);
    // The threaded probe beat the inline record, so the shape holds threaded.
    try std.testing.expect(selectTestJump(&tuner, inline_jump_request).worker_threads > 0);
}

test "adaptive work tuner a probed jump that does not beat its inline record holds inline" {
    var tuner = try inlineSettledTestTuner();
    _ = try recordTestJump(&tuner, inline_jump_request, 100_000);
    try std.testing.expect((try recordTestJump(&tuner, inline_jump_request, 98_000)).worker_threads > 0);
    try std.testing.expectEqual(@as(usize, 0), selectTestJump(&tuner, inline_jump_request).worker_threads);
}

test "adaptive work tuner a threaded jump whose bound is under the gate repeats inline" {
    var tuner = try inlineSettledTestTuner();
    // 500 ns on 64 participants: a 32 us bound on its inline cost.
    const first = try recordTestJump(&tuner, count_jump_request, 500);
    try std.testing.expectEqual(@as(usize, 63), first.worker_threads);
    // The bound rule's verdict is final: an inline repeat at 100 us, which the 0.5 us threaded
    // record beats by the margin, does not reopen it.
    try std.testing.expectEqual(@as(usize, 0), (try recordTestJump(&tuner, count_jump_request, 100_000)).worker_threads);
    try std.testing.expectEqual(@as(usize, 0), selectTestJump(&tuner, count_jump_request).worker_threads);
}

test "adaptive work tuner a threaded jump under the gate runs inline once and its inline record decides" {
    // 30 us threaded: a 1.92 ms bound, so only an inline record can show inline is cheaper.
    var cheap = try inlineSettledTestTuner();
    const threaded = try recordTestJump(&cheap, count_jump_request, 30_000);
    try std.testing.expect(threaded.worker_threads > 0);
    try std.testing.expectEqual(@as(usize, 0), (try recordTestJump(&cheap, count_jump_request, 25_000)).worker_threads);
    try std.testing.expectEqual(@as(usize, 0), selectTestJump(&cheap, count_jump_request).worker_threads);

    var costly = try inlineSettledTestTuner();
    _ = try recordTestJump(&costly, count_jump_request, 30_000);
    try std.testing.expectEqual(@as(usize, 0), (try recordTestJump(&costly, count_jump_request, 80_000)).worker_threads);
    try std.testing.expectEqual(threaded, selectTestJump(&costly, count_jump_request));
}

test "adaptive work tuner a jump whose inline record is under the gate holds inline against a faster threaded record" {
    var tuner = try inlineSettledTestTuner();
    // 30 us threaded (a 1.92 ms bound) runs inline once; inline 50 us is under the 60 us gate,
    // so the threaded record's margin over it does not hold threaded.
    try std.testing.expect((try recordTestJump(&tuner, count_jump_request, 30_000)).worker_threads > 0);
    try std.testing.expectEqual(@as(usize, 0), (try recordTestJump(&tuner, count_jump_request, 50_000)).worker_threads);
    try std.testing.expectEqual(@as(usize, 0), selectTestJump(&tuner, count_jump_request).worker_threads);
}

test "adaptive work tuner a jump's probe that runs inline again holds the measured inline shape" {
    var tuner = try inlineSettledTestTuner();
    try std.testing.expectEqual(@as(usize, 0), (try recordTestJump(&tuner, inline_jump_request, 100_000)).worker_threads);
    // The threaded probe is selected but runs inline: a second inline record judges the entry
    // inline, the only shape measured.
    const probe = try recordTestJumpRanAs(&tuner, inline_jump_request, inlineProfile(inline_jump_request), 100_000);
    try std.testing.expect(probe.worker_threads > 0);
    try std.testing.expect(tuner.jump_profile.?.judged);
    try std.testing.expectEqual(@as(usize, 0), tuner.jump_profile.?.profile.worker_threads);
    // Judged after two records: a later fast threaded record changes nothing.
    _ = try recordTestJumpRanAs(&tuner, inline_jump_request, probe, 10_000);
    try std.testing.expectEqual(@as(usize, 0), selectTestJump(&tuner, inline_jump_request).worker_threads);
}

test "adaptive work tuner a non-repeated jump keeps the predicted shape" {
    var tuner = try inlineSettledTestTuner();
    _ = try recordTestJump(&tuner, inline_jump_request, 100_000);
    _ = try recordTestJump(&tuner, inline_jump_request, 40_000);
    const judged = selectTestJump(&tuner, inline_jump_request);
    try std.testing.expect(judged.worker_threads > 0);
    tuner.record(tunerTestBatchWithProfile(32, judged, 40_000));
    const other_request = tunerTestRequest(40, 64, 1, 64);
    const predicted = tuner.normalizedProfile(tuner.predictProfile(tuner.normalizeRequest(other_request)), tuner.normalizeRequest(other_request));
    try std.testing.expectEqual(predicted, selectTestJump(&tuner, other_request));
}

test "participant slots include main thread and worker threads" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
    });
    defer threads.deinit();

    try std.testing.expectEqual(@as(usize, 3), threads.participantSlotCount());
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

    var hits: [4]std.atomic.Value(u32) = @splat(.{ .raw = 0 });
    var context = CoverageContext{ .hits = hits[0..] };
    const stats = threads.parallelForWithOptions(hits.len, &context, markCoverage, .{});

    try std.testing.expect(stats.ran_inline);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "threaded batch submission does not allocate after init" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = 16,
    });
    defer threads.deinit();

    const original_allocator = threads.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    threads.allocator = failing_allocator.allocator();
    defer threads.allocator = original_allocator;

    var hits: [128]std.atomic.Value(u32) = @splat(.{ .raw = 0 });
    var context = CoverageContext{ .hits = hits[0..] };
    const stats = threads.parallelForWithOptions(hits.len, &context, markCoverage, .{
        .adaptive = false,
        .selected_profile = .{
            .worker_threads = 1,
            .items_per_range = 16,
        },
    });

    try std.testing.expect(!stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 1), stats.active_worker_threads);
    for (&hits) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "shared batch blocks each start a cache line of their own and fit in it" {
    try std.testing.expectEqual(@as(usize, shared_line), @alignOf(Shared));
    inline for (@typeInfo(Shared).@"struct".field_names) |name| {
        try std.testing.expectEqual(@as(usize, 0), @offsetOf(Shared, name) % shared_line);
        try std.testing.expect(@sizeOf(@FieldType(Shared, name)) <= shared_line);
    }
    try std.testing.expectEqual(@typeInfo(Shared).@"struct".field_names.len * shared_line, @sizeOf(Shared));
    try std.testing.expectEqual(@sizeOf(std.atomic.Value(usize)), @sizeOf(Claim));

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 1 });
    defer threads.deinit();
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(threads.shared) % shared_line);
}

test "worker records each start a line of their own and a batch still covers every item" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 16 });
    defer threads.deinit();
    for (threads.workers, 0..) |*worker, index| {
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(worker) % thread_shared_record_alignment);
        if (index > 0) try std.testing.expect(@intFromPtr(worker) - @intFromPtr(&threads.workers[index - 1]) >= thread_shared_record_alignment);
    }
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(WorkerRecord) % thread_shared_record_alignment);

    var hits: [256]std.atomic.Value(u32) = @splat(.{ .raw = 0 });
    var context = CoverageContext{ .hits = hits[0..] };
    const stats = threads.parallelForWithOptions(hits.len, &context, markCoverage, .{ .adaptive = false });
    try std.testing.expect(!stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 3), stats.active_worker_threads);
    for (&hits) |*hit| try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
}

const ParticipantRanges = struct {
    ranges: usize = 0,
    // The index of the first range this participant ran in the batch.
    first_range: usize = std.math.maxInt(usize),
};

const ParticipantCountContext = struct {
    hits: []std.atomic.Value(u32),
    // One padded slot per participant, written only by that participant.
    ranges_by_participant: []PaddedSlot(ParticipantRanges),
};

fn countParticipantRanges(context: *anyopaque, range: ParallelRange, id: WorkerId) void {
    const counts: *ParticipantCountContext = @ptrCast(@alignCast(context));
    std.debug.assert(range.start <= range.end and range.end <= counts.hits.len);
    std.debug.assert(id.index < counts.ranges_by_participant.len);
    for (range.start..range.end) |index| {
        _ = counts.hits[index].fetchAdd(1, .monotonic);
    }
    const slot = &counts.ranges_by_participant[id.index].value;
    if (slot.ranges == 0) slot.first_range = range.index;
    slot.ranges += 1;
}

test "per-participant range counts stay exact under heavy claiming" {
    const item_count = 4096;
    const worker_count = 7;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = worker_count,
        .items_per_range = 1,
    });
    defer threads.deinit();

    var slots: SlotList(ParticipantRanges) = .empty;
    defer slots.deinit(std.testing.allocator);
    try slots.ensureTotalCapacity(std.testing.allocator, threads.participantSlotCount());
    const hits = try std.testing.allocator.alloc(std.atomic.Value(u32), item_count);
    defer std.testing.allocator.free(hits);

    for (0..64) |_| {
        try expectExactFixedBatch(&threads, &slots, hits, item_count, worker_count);
    }
}

// Runs one fixed threaded batch over `range_count` one-item ranges capped at
// `worker_cap` workers, and checks coverage, every participant's range count, and that
// every counted worker woke and ran its own first range before any claim.
fn expectExactFixedBatch(
    threads: *ThreadSystem,
    slots: *SlotList(ParticipantRanges),
    hits: []std.atomic.Value(u32),
    range_count: usize,
    worker_cap: usize,
) !void {
    @memset(hits[0..range_count], .init(0));
    setSlotCount(ParticipantRanges, slots, threads.participantSlotCount());
    var context = ParticipantCountContext{ .hits = hits[0..range_count], .ranges_by_participant = slots.items };
    const stats = threads.parallelForWithOptions(range_count, &context, countParticipantRanges, .{
        .adaptive = false,
        .items_per_range = 1,
        .max_worker_threads = worker_cap,
    });

    const expected_workers = @min(worker_cap, range_count - 1);
    try std.testing.expect(!stats.ran_inline);
    try std.testing.expectEqual(expected_workers, stats.active_worker_threads);
    try std.testing.expectEqual(range_count, stats.range_count);
    try std.testing.expectEqual(slots.items[WorkerId.main.index].value.ranges, stats.main_thread_ranges);
    var worker_ranges: usize = 0;
    for (threads.workers, 0..) |*worker, index| {
        const ranges = slots.items[worker.id.index].value.ranges;
        if (index < expected_workers) {
            try std.testing.expect(ranges >= 1);
            try std.testing.expectEqual(worker.id.index - 1, slots.items[worker.id.index].value.first_range);
        } else {
            try std.testing.expectEqual(@as(usize, 0), ranges);
        }
        worker_ranges += ranges;
    }
    try std.testing.expectEqual(worker_ranges, stats.worker_thread_ranges);
    try std.testing.expectEqual(range_count, stats.main_thread_ranges + stats.worker_thread_ranges);
    for (hits[0..range_count]) |*hit| {
        try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    }
}

test "back-to-back threaded dispatches stay exact as worker and range counts cycle" {
    const worker_count = 7;
    const max_ranges = 64;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = worker_count });
    defer threads.deinit();

    var slots: SlotList(ParticipantRanges) = .empty;
    defer slots.deinit(std.testing.allocator);
    try slots.ensureTotalCapacity(std.testing.allocator, threads.participantSlotCount());
    var hits: [max_ranges]std.atomic.Value(u32) = @splat(.init(0));

    // A lost wake or a missed completion hangs here.
    for (0..10_000) |dispatch| {
        const worker_cap = 1 + dispatch % worker_count;
        const range_count = 2 + dispatch % (max_ranges - 1);
        try expectExactFixedBatch(&threads, &slots, &hits, range_count, worker_cap);
    }
}

test "every counted worker wakes once and runs its first range at every worker count" {
    const worker_count = 23;
    const max_ranges = 4 * (worker_count + 1);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = worker_count });
    defer threads.deinit();

    var slots: SlotList(ParticipantRanges) = .empty;
    defer slots.deinit(std.testing.allocator);
    try slots.ensureTotalCapacity(std.testing.allocator, threads.participantSlotCount());
    var hits: [max_ranges]std.atomic.Value(u32) = @splat(.init(0));

    for (1..worker_count + 1) |worker_cap| {
        // One range per participant, then enough that every participant claims.
        try expectExactFixedBatch(&threads, &slots, &hits, worker_cap + 1, worker_cap);
        try expectExactFixedBatch(&threads, &slots, &hits, 4 * (worker_cap + 1), worker_cap);
    }
}

test "back-to-back batches stay exact as the counted set changes out of order with stale permits" {
    const worker_count = 15;
    const max_ranges = 2 * (worker_count + 1);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = worker_count });
    defer threads.deinit();
    const io = threads.shared.descriptor.io;

    var slots: SlotList(ParticipantRanges) = .empty;
    defer slots.deinit(std.testing.allocator);
    try slots.ensureTotalCapacity(std.testing.allocator, threads.participantSlotCount());
    var hits: [max_ranges]std.atomic.Value(u32) = @splat(.init(0));

    // The counted set grows and shrinks out of order, and every other batch a stale permit
    // lets one worker, counted or not, wake before main publishes or posts it. A worker
    // that drops its batch's wake hangs here; one that runs a batch that did not count it
    // fails the range checks.
    for (0..5_000) |batch| {
        const worker_cap = 1 + (batch * 7) % worker_count;
        if (batch % 2 == 0) threads.workers[(batch / 2) % worker_count].wake.post(io);
        const range_count = worker_cap + 1 + batch % (worker_cap + 1);
        try expectExactFixedBatch(&threads, &slots, &hits, range_count, worker_cap);
    }
}

// One worker and two ranges: the worker's assigned range 0 and main's claimed range 1
// hold each other so one participant's decrement is forced to end the batch.
const CompletionOrderContext = struct {
    pending: *const std.atomic.Value(usize),
    done: *const std.Io.Event,
    worker_last: bool,
    main_ran: std.atomic.Value(bool) = .init(false),
    hits: [2]std.atomic.Value(u32) = @splat(.init(0)),
    // Written once per range by the participant that ran it.
    participant_by_range: [2]usize = @splat(std.math.maxInt(usize)),
};

fn completionOrderJob(context: *anyopaque, range: ParallelRange, id: WorkerId) void {
    const order: *CompletionOrderContext = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < order.hits.len);
    _ = order.hits[range.index].fetchAdd(1, .monotonic);
    order.participant_by_range[range.index] = id.index;
    if (range.index == 0) {
        // Worker-last: hold until main has decremented and committed to waiting, so the
        // worker's `set` must wake a sleeper. Main-last: hold until main has started its
        // range, which then outwaits this worker's decrement.
        if (order.worker_last) {
            while (@atomicLoad(std.Io.Event, order.done, .acquire) != .waiting) std.atomic.spinLoopHint();
        } else {
            while (!order.main_ran.load(.acquire)) std.atomic.spinLoopHint();
        }
    } else if (!order.worker_last) {
        order.main_ran.store(true, .release);
        while (order.pending.load(.acquire) != 1) std.atomic.spinLoopHint();
    }
}

fn runCompletionOrderBatch(threads: *ThreadSystem, worker_last: bool) !void {
    var order = CompletionOrderContext{
        .pending = &threads.shared.completion.pending,
        .done = &threads.shared.completion.done,
        .worker_last = worker_last,
    };
    const stats = threads.parallelForWithOptions(order.hits.len, &order, completionOrderJob, .{
        .adaptive = false,
        .items_per_range = 1,
    });
    try std.testing.expect(!stats.ran_inline);
    try std.testing.expectEqual(@as(usize, 1), stats.active_worker_threads);
    try std.testing.expectEqual(@as(usize, 1), stats.main_thread_ranges);
    try std.testing.expectEqual(@as(usize, 1), stats.worker_thread_ranges);
    for (&order.hits) |*hit| try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), order.participant_by_range[0]);
    try std.testing.expectEqual(WorkerId.main.index, order.participant_by_range[1]);
    try std.testing.expectEqual(@as(usize, 0), threads.shared.completion.pending.load(.monotonic));
}

test "a batch main finishes last joins without waiting on the completion event" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 1 });
    defer threads.deinit();

    for (0..8) |_| {
        try runCompletionOrderBatch(&threads, false);
        // No worker ended the batch, and main never waited.
        try std.testing.expectEqual(std.Io.Event.unset, @atomicLoad(std.Io.Event, &threads.shared.completion.done, .acquire));
    }
}

test "a batch a worker finishes last wakes main through the completion event" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 1 });
    defer threads.deinit();

    for (0..8) |_| {
        try runCompletionOrderBatch(&threads, true);
        try std.testing.expect(threads.shared.completion.done.isSet());
    }
    // Orders alternate on one system, so each publish resets the event the last set.
    try runCompletionOrderBatch(&threads, false);
    try std.testing.expectEqual(std.Io.Event.unset, @atomicLoad(std.Io.Event, &threads.shared.completion.done, .acquire));
    try runCompletionOrderBatch(&threads, true);
    try std.testing.expect(threads.shared.completion.done.isSet());
}

test "stale wake permits run no batch and decrement nothing, inside or outside a batch" {
    const worker_count = 4;
    const range_count = 32;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = worker_count });
    defer threads.deinit();
    const io = threads.shared.descriptor.io;

    var slots: SlotList(ParticipantRanges) = .empty;
    defer slots.deinit(std.testing.allocator);
    try slots.ensureTotalCapacity(std.testing.allocator, threads.participantSlotCount());
    var hits: [range_count]std.atomic.Value(u32) = @splat(.init(0));

    // Extra permits before the first publish; each is taken before or during an early
    // batch, depending on timing.
    for (threads.workers) |*worker| worker.wake.post(io);
    for (0..100) |batch| {
        // One stale permit per batch for the last worker, which no batch counts, so its
        // wake lands while main publishes and joins a batch without it.
        threads.workers[worker_count - 1].wake.post(io);
        try expectExactFixedBatch(&threads, &slots, &hits, range_count, 1 + batch % (worker_count - 1));
    }
}

test "deinit right after init joins workers with startup and shutdown permits pending" {
    for (0..32) |_| {
        var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 4 });
        threads.deinit();
    }

    // And after a batch, once every batch permit is consumed.
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 4 });
    defer threads.deinit();
    var slots: SlotList(ParticipantRanges) = .empty;
    defer slots.deinit(std.testing.allocator);
    try slots.ensureTotalCapacity(std.testing.allocator, threads.participantSlotCount());
    var hits: [16]std.atomic.Value(u32) = @splat(.init(0));
    try expectExactFixedBatch(&threads, &slots, &hits, hits.len, 4);
}

const nested_inner_items = 32;
const nested_inner_items_per_range = 4;

// One nested batch's job state. A nested batch runs only on its caller's thread, so the
// fields are plain.
const NestedInner = struct {
    hits: []u32,
    caller: WorkerId,
    range_count: usize,
    ranges: usize = 0,
    foreign_ranges: usize = 0,
    out_of_order_ranges: usize = 0,
};

fn nestedInnerJob(context: *anyopaque, range: ParallelRange, id: WorkerId) void {
    const inner: *NestedInner = @ptrCast(@alignCast(context));
    std.debug.assert(range.start <= range.end and range.end <= inner.hits.len);
    std.debug.assert(range.index < inner.range_count);
    for (inner.hits[range.start..range.end]) |*hit| hit.* += 1;
    if (id.index != inner.caller.index) inner.foreign_ranges += 1;
    if (range.index != inner.ranges) inner.out_of_order_ranges += 1;
    inner.ranges += 1;
}

// What one nested batch saw, kept in its outer range's slot.
const NestedRecord = struct {
    nested: bool = false,
    caller: WorkerId = WorkerId.main,
    hits: [nested_inner_items]u32 = @splat(0),
    batch: BatchStats = .{},
    ranges: usize = 0,
    foreign_ranges: usize = 0,
    out_of_order_ranges: usize = 0,

    fn run(record: *NestedRecord, threads: *ThreadSystem, caller: WorkerId, range_count: usize, item_count: usize, options: ParallelForOptions) void {
        var inner = NestedInner{ .hits = record.hits[0..item_count], .caller = caller, .range_count = range_count };
        record.batch = threads.parallelForWithOptions(item_count, &inner, nestedInnerJob, options);
        record.nested = true;
        record.caller = caller;
        record.ranges = inner.ranges;
        record.foreign_ranges = inner.foreign_ranges;
        record.out_of_order_ranges = inner.out_of_order_ranges;
    }

    fn expectRanInlineOnCaller(record: *const NestedRecord, item_count: usize, range_count: usize) !void {
        try std.testing.expect(record.nested);
        for (record.hits[0..item_count]) |hit| try std.testing.expectEqual(@as(u32, 1), hit);
        try std.testing.expectEqual(range_count, record.ranges);
        try std.testing.expectEqual(@as(usize, 0), record.foreign_ranges);
        try std.testing.expectEqual(@as(usize, 0), record.out_of_order_ranges);
        try std.testing.expect(record.batch.ran_inline and record.batch.forced_inline);
        try std.testing.expectEqual(@as(usize, 0), record.batch.active_worker_threads);
        try std.testing.expectEqual(item_count, record.batch.item_count);
        try std.testing.expectEqual(range_count, record.batch.range_count);
        const caller_ranges = if (record.caller.index == WorkerId.main.index) record.batch.main_thread_ranges else record.batch.worker_thread_ranges;
        try std.testing.expectEqual(range_count, caller_ranges);
        try std.testing.expectEqual(range_count, record.batch.main_thread_ranges + record.batch.worker_thread_ranges);
    }
};

// Outer job whose ranges each dispatch one fixed nested batch, on workers only or on
// every participant.
const NestingOuter = struct {
    threads: *ThreadSystem,
    records: []NestedRecord,
    nest_on_main: bool,
    nested_range_count: usize,
};

fn nestingOuterJob(context: *anyopaque, range: ParallelRange, id: WorkerId) void {
    const outer: *NestingOuter = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < outer.records.len);
    if (!outer.nest_on_main and id.index == WorkerId.main.index) return;
    outer.records[range.index].run(outer.threads, id, outer.nested_range_count, nested_inner_items, .{
        .adaptive = false,
        .items_per_range = nested_inner_items_per_range,
    });
}

// The range count a fixed nested request gets from the shared shaping path.
fn nestedFixedRangeCount(threads: *const ThreadSystem) usize {
    return shapeBatch(nested_inner_items, .{
        .worker_threads = threads.workerThreadCount(),
        .items_per_range = nested_inner_items_per_range,
    }, threads.workerThreadCount(), 1, false).range_count;
}

test "a nested batch from a worker job runs inline on that worker and covers every item once" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 8 });
    defer threads.deinit();

    var records: [16]NestedRecord = @splat(.{});
    var outer = NestingOuter{ .threads = &threads, .records = &records, .nest_on_main = false, .nested_range_count = nestedFixedRangeCount(&threads) };
    try std.testing.expectEqual(@as(usize, 8), outer.nested_range_count);
    const stats = threads.parallelForWithOptions(128, &outer, nestingOuterJob, .{ .adaptive = false });

    try std.testing.expect(!stats.ran_inline and !stats.forced_inline);
    try std.testing.expectEqual(@as(usize, 16), stats.range_count);
    // Each woken worker runs its first range by id: range 0 on worker 1, range 1 on worker 2.
    try std.testing.expect(records[0].nested and records[1].nested);
    try std.testing.expectEqual(@as(usize, 1), records[0].caller.index);
    try std.testing.expectEqual(@as(usize, 2), records[1].caller.index);
    for (&records) |*record| {
        if (!record.nested) continue;
        try std.testing.expect(record.caller.index != WorkerId.main.index);
        try record.expectRanInlineOnCaller(nested_inner_items, outer.nested_range_count);
    }
}

// Outer job for an inline owner batch: each range dispatches two nested batches.
const OwnerNestingOuter = struct {
    threads: *ThreadSystem,
    records: [][2]NestedRecord,
    nested_range_count: usize,
};

fn ownerNestingOuterJob(context: *anyopaque, range: ParallelRange, id: WorkerId) void {
    const outer: *OwnerNestingOuter = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < outer.records.len);
    for (&outer.records[range.index]) |*record| {
        record.run(outer.threads, id, outer.nested_range_count, nested_inner_items, .{
            .adaptive = false,
            .items_per_range = nested_inner_items_per_range,
        });
    }
}

test "a nested batch from the owner's own range runs inline on the main id" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 8 });
    defer threads.deinit();

    var records: [2][2]NestedRecord = @splat(@splat(.{}));
    var outer = OwnerNestingOuter{ .threads = &threads, .records = &records, .nested_range_count = nestedFixedRangeCount(&threads) };
    // Inline with workers present, so every outer range runs on the owner.
    const stats = threads.parallelForWithOptions(2, &outer, ownerNestingOuterJob, .{
        .adaptive = false,
        .selected_profile = .{ .worker_threads = 0, .items_per_range = 1 },
    });

    try std.testing.expect(stats.ran_inline and !stats.forced_inline);
    try std.testing.expectEqual(@as(usize, 2), stats.main_thread_ranges);
    for (&records) |*pair| {
        for (pair) |*record| {
            try std.testing.expectEqual(WorkerId.main.index, record.caller.index);
            try record.expectRanInlineOnCaller(nested_inner_items, outer.nested_range_count);
        }
    }

    // The owner left its batch, so the next batch dispatches to workers again.
    try std.testing.expect(!threads.owner_in_batch);
    var hits: [128]std.atomic.Value(u32) = @splat(.{ .raw = 0 });
    var coverage = CoverageContext{ .hits = hits[0..] };
    const after = threads.parallelForWithOptions(hits.len, &coverage, markCoverage, .{ .adaptive = false });
    try std.testing.expect(!after.ran_inline and !after.forced_inline);
    for (&hits) |*hit| try std.testing.expectEqual(@as(u32, 1), hit.load(.monotonic));
}

// Outer job whose single range dispatches nested batches at a preselected profile and
// through a stage dispatch.
const ShapeNestingOuter = struct {
    threads: *ThreadSystem,
    stage_tuner: *AdaptiveWorkTuner,
    profile_hits: [128]u32 = @splat(0),
    profile_batch: BatchStats = .{},
    profile_inner_ranges: usize = 0,
    profile_out_of_order_ranges: usize = 0,
    stage_selection: ?BatchSelection = null,
    stage_record: NestedRecord = .{},
};

fn shapeNestingOuterJob(context: *anyopaque, range: ParallelRange, id: WorkerId) void {
    const outer: *ShapeNestingOuter = @ptrCast(@alignCast(context));
    std.debug.assert(range.index == 0);
    var inner = NestedInner{ .hits = &outer.profile_hits, .caller = id, .range_count = 8 };
    outer.profile_batch = outer.threads.parallelForWithOptions(outer.profile_hits.len, &inner, nestedInnerJob, .{
        .adaptive = false,
        .selected_profile = .{ .worker_threads = 2, .items_per_range = 16 },
    });
    outer.profile_inner_ranges = inner.ranges;
    outer.profile_out_of_order_ranges = inner.out_of_order_ranges + inner.foreign_ranges;

    const dispatch = Dispatch.init(outer.threads, outer.stage_tuner, .{});
    const selection = dispatch.select(nested_inner_items, 1);
    outer.stage_selection = selection;
    var stage_inner = NestedInner{ .hits = &outer.stage_record.hits, .caller = id, .range_count = selection.range_count };
    outer.stage_record.batch = dispatch.run(selection, nested_inner_items, 1, &stage_inner, nestedInnerJob);
    outer.stage_record.nested = true;
    outer.stage_record.caller = id;
    outer.stage_record.ranges = stage_inner.ranges;
    outer.stage_record.foreign_ranges = stage_inner.foreign_ranges;
    outer.stage_record.out_of_order_ranges = stage_inner.out_of_order_ranges;
}

test "a nested batch keeps a selected profile's range shape and a nested stage selects the untuned shape" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 8 });
    defer threads.deinit();

    var stage_tuner = AdaptiveWorkTuner.init(.{});
    var outer = ShapeNestingOuter{ .threads = &threads, .stage_tuner = &stage_tuner };
    _ = threads.parallelForWithOptions(1, &outer, shapeNestingOuterJob, .{ .adaptive = false });

    for (outer.profile_hits) |hit| try std.testing.expectEqual(@as(u32, 1), hit);
    try std.testing.expect(outer.profile_batch.forced_inline);
    try std.testing.expectEqual(@as(usize, 8), outer.profile_batch.range_count);
    try std.testing.expectEqual(@as(usize, 16), outer.profile_batch.items_per_range);
    try std.testing.expectEqual(@as(usize, 8), outer.profile_inner_ranges);
    try std.testing.expectEqual(@as(usize, 0), outer.profile_out_of_order_ranges);

    const selection = outer.stage_selection.?;
    const untuned = shapeBatch(nested_inner_items, .{ .worker_threads = 2, .items_per_range = 8 }, 2, 1, false);
    try std.testing.expectEqual(@as(usize, 0), selection.worker_threads);
    try std.testing.expectEqual(@as(usize, 0), selection.profile.worker_threads);
    try std.testing.expect(selection.active_tuner == null);
    try std.testing.expectEqual(untuned.range_count, selection.range_count);
    try std.testing.expectEqual(untuned.items_per_range, selection.items_per_range);
    try outer.stage_record.expectRanInlineOnCaller(nested_inner_items, untuned.range_count);
}

// The tuner policy state any selection or record would change. The perf-log diagnostic
// counters are excluded: tests never read counters.
const TunerSnapshot = struct {
    phase: AdaptiveWorkPhase,
    initial_profile: AdaptiveWorkProfile,
    current_profile: AdaptiveWorkProfile,
    candidate_profile: ?AdaptiveWorkProfile,
    sample_count: usize,
    baseline_mean_batch_duration_ns: u64,
    has_threaded_profile: bool,
    last_request: ?AdaptiveWorkRequest,
    learned_item_count: usize,
    shifted_batch_count: usize,
    skip_next_record: bool,
    batch_multiplier: f64,
    throughput_ema: f64,
    nudge_samples: usize,

    fn of(tuner: *const AdaptiveWorkTuner) TunerSnapshot {
        return .{
            .phase = tuner.phase,
            .initial_profile = tuner.initial_profile,
            .current_profile = tuner.current_profile,
            .candidate_profile = tuner.candidate_profile,
            .sample_count = tuner.sample_count,
            .baseline_mean_batch_duration_ns = tuner.baseline_mean_batch_duration_ns,
            .has_threaded_profile = tuner.has_threaded_profile,
            .last_request = tuner.last_request,
            .learned_item_count = tuner.learned_item_count,
            .shifted_batch_count = tuner.shifted_batch_count,
            .skip_next_record = tuner.skip_next_record,
            .batch_multiplier = tuner.batch_multiplier,
            .throughput_ema = tuner.throughput_ema,
            .nudge_samples = tuner.nudge_samples,
        };
    }
};

// Per outer range: a nested stage dispatch under the stage tuner, then a nested
// `parallelForWithOptions` that names no tuner.
const TunerNestRecord = struct {
    stage: NestedRecord = .{},
    untuned: NestedRecord = .{},
};

const TunerNestingOuter = struct {
    threads: *ThreadSystem,
    stage_tuner: *AdaptiveWorkTuner,
    records: []TunerNestRecord,
};

fn tunerNestingOuterJob(context: *anyopaque, range: ParallelRange, id: WorkerId) void {
    const outer: *TunerNestingOuter = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < outer.records.len);
    const record = &outer.records[range.index];

    const dispatch = Dispatch.init(outer.threads, outer.stage_tuner, .{});
    const selection = dispatch.select(nested_inner_items, 1);
    var stage_inner = NestedInner{ .hits = &record.stage.hits, .caller = id, .range_count = selection.range_count };
    record.stage.batch = dispatch.run(selection, nested_inner_items, 1, &stage_inner, nestedInnerJob);
    record.stage.nested = true;
    record.stage.caller = id;
    record.stage.ranges = stage_inner.ranges;
    record.stage.foreign_ranges = stage_inner.foreign_ranges;
    record.stage.out_of_order_ranges = stage_inner.out_of_order_ranges;

    var untuned_inner = NestedInner{ .hits = &record.untuned.hits, .caller = id, .range_count = rangeCount(nested_inner_items, outer.threads.config.items_per_range) };
    record.untuned.batch = outer.threads.parallelForWithOptions(nested_inner_items, &untuned_inner, nestedInnerJob, .{});
    record.untuned.nested = true;
    record.untuned.caller = id;
    record.untuned.ranges = untuned_inner.ranges;
    record.untuned.foreign_ranges = untuned_inner.foreign_ranges;
    record.untuned.out_of_order_ranges = untuned_inner.out_of_order_ranges;
}

test "a nested batch leaves the stage tuner untouched and runs the untuned shape" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 8 });
    defer threads.deinit();

    var stage_tuner = AdaptiveWorkTuner.init(.{});
    const stage_before = TunerSnapshot.of(&stage_tuner);

    var records: [16]TunerNestRecord = @splat(.{});
    var outer = TunerNestingOuter{ .threads = &threads, .stage_tuner = &stage_tuner, .records = &records };
    const stats = threads.parallelForWithOptions(128, &outer, tunerNestingOuterJob, .{ .adaptive = false });
    try std.testing.expect(!stats.ran_inline);

    try std.testing.expectEqual(stage_before, TunerSnapshot.of(&stage_tuner));
    try std.testing.expect(stage_tuner.last_request == null);
    // Both nested requests are adaptive with no fixed range size: untuned, they run the
    // thread system's default range size.
    const untuned_range_count = rangeCount(nested_inner_items, threads.config.items_per_range);
    for (&records) |*record| {
        try record.stage.expectRanInlineOnCaller(nested_inner_items, untuned_range_count);
        try record.untuned.expectRanInlineOnCaller(nested_inner_items, untuned_range_count);
    }
}

test "forced inline batches allocate nothing on a multi-worker system" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 8 });
    defer threads.deinit();

    const original_allocator = threads.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    threads.allocator = failing_allocator.allocator();
    defer threads.allocator = original_allocator;

    var records: [16]NestedRecord = @splat(.{});
    var outer = NestingOuter{ .threads = &threads, .records = &records, .nest_on_main = true, .nested_range_count = nestedFixedRangeCount(&threads) };
    const stats = threads.parallelForWithOptions(128, &outer, nestingOuterJob, .{ .adaptive = false });

    try std.testing.expect(!stats.ran_inline);
    for (&records) |*record| try record.expectRanInlineOnCaller(nested_inner_items, outer.nested_range_count);
    try std.testing.expectEqual(@as(usize, 0), failing_allocator.allocations);
    try std.testing.expect(!failing_allocator.has_induced_failure);
}

fn classifyCaller(threads: *const ThreadSystem, role: *?CallerRole) void {
    role.* = threads.callerRole();
}

// Per outer range: how the running participant classifies against its own system and
// against a second system it does not serve.
const ClassifyRecord = struct {
    ran: bool = false,
    id: WorkerId = WorkerId.main,
    own: ?CallerRole = null,
    other: ?CallerRole = null,
};

const ClassifyOuter = struct {
    own: *const ThreadSystem,
    other: *const ThreadSystem,
    records: []ClassifyRecord,
};

fn classifyOuterJob(context: *anyopaque, range: ParallelRange, id: WorkerId) void {
    const outer: *ClassifyOuter = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < outer.records.len);
    outer.records[range.index] = .{ .ran = true, .id = id, .own = outer.own.callerRole(), .other = outer.other.callerRole() };
}

// A foreign caller panics (`requireCallerRole`); the panic itself cannot run in-process,
// so this covers the classification that triggers it.
test "callers classify as owner, nested participant, or foreign" {
    var own = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer own.deinit();
    var other = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer other.deinit();

    try std.testing.expectEqual(@as(?CallerRole, .owner), own.callerRole());

    var spawned_role: ?CallerRole = .owner;
    const spawned = try std.Thread.spawn(.{ .allocator = std.testing.allocator }, classifyCaller, .{ &own, &spawned_role });
    spawned.join();
    try std.testing.expectEqual(@as(?CallerRole, null), spawned_role);

    var records: [16]ClassifyRecord = @splat(.{});
    var outer = ClassifyOuter{ .own = &own, .other = &other, .records = &records };
    const stats = own.parallelForWithOptions(records.len, &outer, classifyOuterJob, .{ .adaptive = false });
    try std.testing.expect(!stats.ran_inline);
    try std.testing.expect(records[0].ran and records[0].id.index == 1);
    for (&records) |*record| {
        try std.testing.expect(record.ran);
        try std.testing.expectEqual(@as(?CallerRole, .{ .nested = record.id }), record.own);
        // The test thread owns both systems, so only a worker is foreign to the other.
        const other_expected: ?CallerRole = if (record.id.index == WorkerId.main.index) .owner else null;
        try std.testing.expectEqual(other_expected, record.other);
    }
    try std.testing.expectEqual(@as(?CallerRole, .owner), own.callerRole());
}

// Outer job for a threaded batch where only the owner's ranges nest: worker ranges hold
// until the owner has started one, so the owner must claim a range past the workers'
// first ranges.
const OwnerThreadedNestingOuter = struct {
    threads: *ThreadSystem,
    records: []NestedRecord,
    nested_range_count: usize,
    owner_started: std.atomic.Value(bool) = .init(false),
};

fn ownerThreadedNestingOuterJob(context: *anyopaque, range: ParallelRange, id: WorkerId) void {
    const outer: *OwnerThreadedNestingOuter = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < outer.records.len);
    if (id.index != WorkerId.main.index) {
        while (!outer.owner_started.load(.acquire)) std.atomic.spinLoopHint();
        return;
    }
    outer.owner_started.store(true, .release);
    outer.records[range.index].run(outer.threads, id, outer.nested_range_count, nested_inner_items, .{
        .adaptive = false,
        .items_per_range = nested_inner_items_per_range,
    });
}

test "a nested batch from the owner's range of a threaded batch runs inline on the main id" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 8 });
    defer threads.deinit();

    var records: [16]NestedRecord = @splat(.{});
    var outer = OwnerThreadedNestingOuter{ .threads = &threads, .records = &records, .nested_range_count = nestedFixedRangeCount(&threads) };
    const stats = threads.parallelForWithOptions(128, &outer, ownerThreadedNestingOuterJob, .{ .adaptive = false });

    try std.testing.expect(!stats.ran_inline and !stats.forced_inline);
    try std.testing.expect(stats.main_thread_ranges > 0);
    var owner_records: u64 = 0;
    for (&records) |*record| {
        if (!record.nested) continue;
        owner_records += 1;
        try std.testing.expectEqual(WorkerId.main.index, record.caller.index);
        try record.expectRanInlineOnCaller(nested_inner_items, outer.nested_range_count);
    }
    try std.testing.expectEqual(@as(u64, stats.main_thread_ranges), owner_records);
    try std.testing.expect(!threads.owner_in_batch);
}

// Outer job for an inline owner batch whose one range runs an owner-made tuned selection,
// and an untuned profile passed with a tuner.
const SelectedNestingOuter = struct {
    dispatch: Dispatch,
    selection: BatchSelection,
    indices: *RangeIndexContext,
    batch: BatchStats = .{},
    untuned_tuner: *AdaptiveWorkTuner,
    untuned_inner: NestedInner,
    untuned_batch: BatchStats = .{},
};

fn selectedNestingOuterJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const outer: *SelectedNestingOuter = @ptrCast(@alignCast(context));
    std.debug.assert(range.index == 0);
    outer.batch = outer.dispatch.run(outer.selection, 1024, 16, outer.indices, recordRangeIndex);
    outer.untuned_batch = outer.dispatch.thread_system.parallelForWithOptions(outer.untuned_inner.hits.len, &outer.untuned_inner, nestedInnerJob, .{
        .adaptive_tuner = outer.untuned_tuner,
        .selected_profile = .{ .worker_threads = 0, .items_per_range = 16 },
    });
}

test "a nested run of an owner's tuned selection keeps its aligned range set" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 64 });
    defer threads.deinit();

    // The largest batch size caps the predicted three batches at 96 items, so the range
    // set ends in a short tail.
    var tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = 64,
        .smallest_range_items = 16,
        .largest_range_items = 96,
        .sample_window = 1,
        .threaded_batch_ns = 1000,
    });
    // One slow inline sample moves the tuner to probing a threaded candidate.
    tuner.record(tunerTestBatchWithProfile(1024, tuner.selectProfile(tunerTestRequest(1024, 2, 16, 64)), 200_000));
    const dispatch = Dispatch.init(&threads, &tuner, .{});
    const selection = dispatch.select(1024, 16);
    try std.testing.expect(selection.active_tuner == &tuner);
    try std.testing.expectEqual(@as(usize, 2), selection.worker_threads);
    try std.testing.expectEqual(@as(usize, 96), selection.items_per_range);
    try std.testing.expectEqual(@as(usize, 11), selection.range_count);

    const expected_starts = [_]usize{ 0, 96, 192, 288, 384, 480, 576, 672, 768, 864, 960 };
    const expected_ends = [_]usize{ 96, 192, 288, 384, 480, 576, 672, 768, 864, 960, 1024 };

    var nested_starts: [11]usize = @splat(std.math.maxInt(usize));
    var nested_ends: [11]usize = @splat(0);
    var nested_indices = RangeIndexContext{ .starts = &nested_starts, .ends = &nested_ends, .items_per_range = 96 };
    var untuned_tuner = AdaptiveWorkTuner.init(.{});
    var untuned_hits: [64]u32 = @splat(0);
    var outer = SelectedNestingOuter{
        .dispatch = dispatch,
        .selection = selection,
        .indices = &nested_indices,
        .untuned_tuner = &untuned_tuner,
        .untuned_inner = .{ .hits = &untuned_hits, .caller = WorkerId.main, .range_count = 4 },
    };
    _ = threads.parallelForWithOptions(1, &outer, selectedNestingOuterJob, .{ .adaptive = false });

    try std.testing.expect(outer.batch.forced_inline);
    try std.testing.expectEqual(@as(usize, 11), outer.batch.range_count);
    try std.testing.expectEqual(@as(usize, 96), outer.batch.items_per_range);
    try std.testing.expectEqual(@as(usize, 11), outer.batch.main_thread_ranges);
    try std.testing.expectEqualSlices(usize, &expected_starts, &nested_starts);
    try std.testing.expectEqualSlices(usize, &expected_ends, &nested_ends);

    // A passed tuner does not collapse an untuned profile's ranges.
    try std.testing.expect(outer.untuned_batch.forced_inline);
    try std.testing.expectEqual(@as(usize, 4), outer.untuned_batch.range_count);
    try std.testing.expectEqual(@as(usize, 4), outer.untuned_inner.ranges);
    try std.testing.expectEqual(@as(usize, 0), outer.untuned_inner.out_of_order_ranges);
    for (untuned_hits) |hit| try std.testing.expectEqual(@as(u32, 1), hit);
    try std.testing.expect(untuned_tuner.last_request == null);

    var owner_starts: [11]usize = @splat(std.math.maxInt(usize));
    var owner_ends: [11]usize = @splat(0);
    var owner_indices = RangeIndexContext{ .starts = &owner_starts, .ends = &owner_ends, .items_per_range = 96 };
    const owner_batch = dispatch.run(selection, 1024, 16, &owner_indices, recordRangeIndex);
    try std.testing.expect(!owner_batch.ran_inline and !owner_batch.forced_inline);
    try std.testing.expectEqual(@as(usize, 11), owner_batch.range_count);
    try std.testing.expectEqual(@as(usize, 96), owner_batch.items_per_range);
    try std.testing.expectEqualSlices(usize, &expected_starts, &owner_starts);
    try std.testing.expectEqualSlices(usize, &expected_ends, &owner_ends);
}

// Outer job for an inline owner batch whose one range runs a step's rounds.
const RoundNestingOuter = struct {
    rounds: *RoundDispatch,
    context: StageTestContext = .{},
};

fn roundNestingOuterJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const outer: *RoundNestingOuter = @ptrCast(@alignCast(context));
    std.debug.assert(range.index == 0);
    for ([_]usize{ 10, 12, 8 }) |item_count| outer.rounds.run(item_count, &outer.context, &outer.context.range_count, stageTestJob);
}

test "rounds run inside a batch leave the stage tuner unsampled" {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();

    var tuner = AdaptiveWorkTuner.init(.{});
    var rounds = RoundDispatch.begin(Dispatch.init(&threads, &tuner, .{}), 30);
    try std.testing.expect(rounds.selection.?.active_tuner == &tuner);
    const before = TunerSnapshot.of(&tuner);
    const sampled_before = tuner.sampled_profile;

    var outer = RoundNestingOuter{ .rounds = &rounds };
    _ = threads.parallelForWithOptions(1, &outer, roundNestingOuterJob, .{ .adaptive = false });
    const total = rounds.finish(30);

    try std.testing.expect(total.forced_inline);
    try std.testing.expectEqual(@as(usize, 30), outer.context.items.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), tuner.sample_count);
    try std.testing.expectEqual(sampled_before, tuner.sampled_profile);
    try std.testing.expectEqual(before, TunerSnapshot.of(&tuner));
}

test "accumulate batch marks the total forced inline when any batch was" {
    var total = BatchStats{};
    accumulateBatch(&total, inlineBatch(4, 1));
    try std.testing.expect(!total.forced_inline);
    var forced = inlineBatch(4, 1);
    forced.forced_inline = true;
    accumulateBatch(&total, forced);
    accumulateBatch(&total, inlineBatch(4, 1));
    try std.testing.expect(total.forced_inline);
}

test "every woken worker carries its worker name on linux" {
    const builtin = @import("builtin");
    // Darwin names only the calling thread, so the worker-name check is Linux.
    if (comptime builtin.os.tag != .linux) return;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();

    var hits: [16]std.atomic.Value(u32) = @splat(.{ .raw = 0 });
    var coverage = CoverageContext{ .hits = hits[0..] };
    const stats = threads.parallelForWithOptions(hits.len, &coverage, markCoverage, .{ .adaptive = false });
    try std.testing.expectEqual(threads.workerThreadCount(), stats.active_worker_threads);

    for (threads.workers) |*worker| {
        var expected_buffer: [std.Thread.max_name_len]u8 = undefined;
        const expected = try std.mem.print(&expected_buffer, "zl-worker-{d}", .{worker.id.index});
        var name_buffer: [std.Thread.max_name_len:0]u8 = undefined;
        const name = (try worker.thread.?.getName(&name_buffer)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected, name);
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

// One engine step as the dispatch path records it: the tuner's selection shaped by
// `shapeBatch` (an inline batch collapses to one item_count-wide range), with a
// synthetic duration of item_count * ns_per_item split across participants plus a
// fixed wake/join cost. Returns the active worker count.
fn tunerScenarioStep(tuner: *AdaptiveWorkTuner, item_count: usize, ns_per_item: u64) usize {
    return tunerScenarioStepShaped(tuner, item_count, ns_per_item, 0, 0);
}

// `tunerScenarioStep` where a threaded batch's main thread waits on workers for four
// fifths of the batch (wake and join latency dominate its share).
fn tunerScenarioStepWithWait(tuner: *AdaptiveWorkTuner, item_count: usize, ns_per_item: u64) usize {
    return tunerScenarioStepShaped(tuner, item_count, ns_per_item, 4, 0);
}

// `tunerScenarioStep` where an inline batch also does `inline_extra_ns_per_item` of
// work the threaded batch leaves to a later pass.
fn tunerScenarioStepInlineAbsorbs(tuner: *AdaptiveWorkTuner, item_count: usize, ns_per_item: u64, inline_extra_ns_per_item: u64) usize {
    return tunerScenarioStepShaped(tuner, item_count, ns_per_item, 0, inline_extra_ns_per_item);
}

fn tunerScenarioStepShaped(
    tuner: *AdaptiveWorkTuner,
    item_count: usize,
    ns_per_item: u64,
    threaded_wait_fifths: u64,
    inline_extra_ns_per_item: u64,
) usize {
    const max_workers = 4;
    const shape = shapeBatch(item_count, tuner.selectProfile(tunerTestRequest(item_count, max_workers, 16, 64)), max_workers, 16, true);
    const work_ns = @as(u64, item_count) * ns_per_item;
    const inline_extra_ns = @as(u64, item_count) * inline_extra_ns_per_item;
    const duration_ns = if (shape.worker_threads == 0) work_ns + inline_extra_ns else work_ns / (shape.worker_threads + 1) + 20_000;
    const wait_ns = if (shape.worker_threads == 0) 0 else duration_ns * threaded_wait_fifths / 5;
    tuner.record(tunerTestBatchWithProfileEx(item_count, .{
        .worker_threads = shape.worker_threads,
        .items_per_range = shape.items_per_range,
    }, duration_ns, wait_ns));
    return shape.worker_threads;
}

fn tunerTestBatchWithProfile(
    item_count: usize,
    profile: AdaptiveWorkProfile,
    duration_ns: u64,
) BatchStats {
    return tunerTestBatchWithProfileEx(item_count, profile, duration_ns, 0);
}

fn tunerTestBatchWithProfileEx(
    item_count: usize,
    profile: AdaptiveWorkProfile,
    duration_ns: u64,
    main_thread_wait_ns: u64,
) BatchStats {
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
        .main_thread_wait_ns = main_thread_wait_ns,
        .ran_inline = profile.worker_threads == 0,
    };
}

test "compactRowWindows moves each range's kept rows together in range order, column by column" {
    const Row = struct { id: u32, weight: f32, flag: bool };
    const Tally = struct { kept: usize = 0 };
    var rows: std.MultiArrayList(Row) = .{};
    defer rows.deinit(std.testing.allocator);
    // Three windows of four: ranges keep 2, 0, and 3 rows; the rest of each window is stale.
    try rows.ensureTotalCapacity(std.testing.allocator, 12);
    setRowCount(Row, &rows, 11);
    for (0..11) |slot| rows.set(slot, .{ .id = @intCast(100 + slot), .weight = @floatFromInt(slot), .flag = slot % 2 == 0 });
    const tallies = [_]PaddedSlot(Tally){ .{ .value = .{ .kept = 2 } }, .{ .value = .{ .kept = 0 } }, .{ .value = .{ .kept = 3 } } };
    compactRowWindows(Row, Tally, &rows, &tallies, 4);
    try std.testing.expectEqual(@as(usize, 5), rows.len);
    try std.testing.expectEqualSlices(u32, &.{ 100, 101, 108, 109, 110 }, rows.items(.id));
    try std.testing.expectEqualSlices(f32, &.{ 0, 1, 8, 9, 10 }, rows.items(.weight));
    try std.testing.expectEqualSlices(bool, &.{ true, false, true, false, true }, rows.items(.flag));
    // Full windows move nothing.
    const full = [_]PaddedSlot(Tally){ .{ .value = .{ .kept = 4 } }, .{ .value = .{ .kept = 1 } } };
    compactRowWindows(Row, Tally, &rows, &full, 4);
    try std.testing.expectEqualSlices(u32, &.{ 100, 101, 108, 109, 110 }, rows.items(.id));
}

test "compactSliceWindows moves each range's kept items together in range order" {
    const Tally = struct { kept: usize = 0 };
    // Three windows of four: ranges keep 2, 0, and 3 items; the rest of each window is stale.
    var items: [11]u32 = undefined;
    for (&items, 0..) |*item, slot| item.* = @intCast(100 + slot);
    const tallies = [_]PaddedSlot(Tally){ .{ .value = .{ .kept = 2 } }, .{ .value = .{ .kept = 0 } }, .{ .value = .{ .kept = 3 } } };
    const total = compactSliceWindows(u32, Tally, &items, &tallies, 4);
    try std.testing.expectEqual(@as(usize, 5), total);
    try std.testing.expectEqualSlices(u32, &.{ 100, 101, 108, 109, 110 }, items[0..total]);
    // Full windows move nothing.
    const full = [_]PaddedSlot(Tally){ .{ .value = .{ .kept = 4 } }, .{ .value = .{ .kept = 1 } } };
    try std.testing.expectEqual(@as(usize, 5), compactSliceWindows(u32, Tally, &items, &full, 4));
    try std.testing.expectEqualSlices(u32, &.{ 100, 101, 108, 109, 110 }, items[0..5]);
    // Empty windows keep nothing.
    const empty = [_]PaddedSlot(Tally){ .{}, .{} };
    try std.testing.expectEqual(@as(usize, 0), compactSliceWindows(u32, Tally, &items, &empty, 4));
}
