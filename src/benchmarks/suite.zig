// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Non-interactive benchmark harness for runtime processors.
//! Rows are regression signals and scheduler diagnostics, not runtime policy:
//! production adaptive cases report what the measured tuner selected for this
//! workload, while fixed cases are controls for comparison.

const std = @import("std");
const AdaptiveWorkPhase = @import("../app/thread_system.zig").AdaptiveWorkPhase;
const AdaptiveWorkReport = @import("../app/thread_system.zig").AdaptiveWorkReport;
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const AdaptiveWorkTunerConfig = @import("../app/thread_system.zig").AdaptiveWorkTunerConfig;
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const DiagnosticCount = @import("../app/thread_system.zig").DiagnosticCount;
const ThreadSystemConfig = @import("../app/thread_system.zig").ThreadSystemConfig;
const diagnostics_enabled = @import("../app/runtime_perf_log.zig").enabled;
const AbstractSlot = @import("../game/systems/pathfinding/scratch.zig").AbstractSlot;
const SearchSlot = @import("../game/systems/pathfinding/scratch.zig").SearchSlot;
const OpenNode = @import("../game/systems/pathfinding/types.zig").OpenNode;
const StitchedCell = @import("../game/systems/pathfinding/types.zig").StitchedCell;
const hashTableSlots = @import("../game/systems/pathfinding/types.zig").hashTableSlots;
const resultBlockWords = @import("../game/systems/pathfinding/types.zig").resultBlockWords;
const registry_shard_count = @import("../game/systems/pathfinding/types.zig").registry_shard_count;
const RegRecord = @import("../game/systems/pathfinding/types.zig").RegRecord;
const NavMainPhases = @import("../game/systems/pathfinding/types.zig").NavMainPhases;
const NavUpdateStats = @import("../game/systems/pathfinding/types.zig").NavUpdateStats;
const ResultCache = @import("../game/systems/pathfinding/caches.zig").ResultCache;
const NavGraph = @import("../game/systems/pathfinding/nav_graph.zig").NavGraph;
const GroupField = @import("../game/systems/pathfinding/group_field.zig").GroupField;
const PathfindingSystem = @import("../game/systems/pathfinding/system.zig").PathfindingSystem;
const SolvedPath = @import("../game/systems/pathfinding/system.zig").PathfindingSystem.SolvedPath;
const ChunkListMap = @import("../game/systems/chunk_list_map.zig").ChunkListMap;

pub const default_items_per_range = (ThreadSystemConfig{}).items_per_range;

pub const Profile = enum {
    quick,
    standard,
    stress,
};

const event_scale_quick_counts = [_]usize{ 1_024, 4_096, 10_000 };
const event_scale_standard_counts = [_]usize{ 1_024, 4_096, 10_000, 25_000, 50_000 };
const event_scale_stress_counts = [_]usize{ 10_000, 25_000, 50_000 };

pub fn eventScaleCounts(profile: Profile) []const usize {
    return switch (profile) {
        .quick => &event_scale_quick_counts,
        .standard => &event_scale_standard_counts,
        .stress => &event_scale_stress_counts,
    };
}

pub const Options = struct {
    profile: Profile = .quick,
    warmup_iterations: usize = 5,
    iterations: usize = 30,
    case_filter: ?[]const u8 = null,
    group_filter: ?[]const u8 = null,
    /// Runs every group whose name starts with this prefix (a family such as `chunk-scale-`).
    group_prefix: ?[]const u8 = null,
    item_count_filter: ?usize = null,
    fallback_budget: ?usize = null,
    details: bool = false,
};

pub const BenchmarkGroup = struct {
    name: []const u8,
    defaultItemCounts: *const fn (Profile) []const usize,
    runCase: *const fn (std.mem.Allocator, std.Io, Options, BenchmarkCase, usize) anyerror!RunStats,
};

pub const BenchmarkCase = struct {
    // Cases are registered by subsystem modules. The suite owns selection,
    // warmup/measurement policy, and report formatting around the callback.
    name: []const u8,
    worker_mode: WorkerMode,
    adaptive: bool = false,
    adaptive_range_mode: AdaptiveRangeMode = .none,
    range_mode: RangeMode = .default,
    required_worker_count: usize = 0,

    pub fn maxWorkerThreads(self: BenchmarkCase) ?usize {
        return switch (self.worker_mode) {
            .serial_direct => 0,
            .fixed_1 => 1,
            .fixed_2 => 2,
            .fixed_auto => null,
        };
    }

    pub fn usesThreadSystem(self: BenchmarkCase) bool {
        return self.worker_mode != .serial_direct;
    }

    pub fn itemsPerRange(self: BenchmarkCase, range_alignment_items: usize) ?usize {
        const base = default_items_per_range;
        return switch (self.range_mode) {
            .default => null,
            .small => alignItemCount(@max(base / 2, @as(usize, 1)), range_alignment_items),
            .large => alignItemCount(base * 4, range_alignment_items),
        };
    }

    pub fn workerModeLabel(self: BenchmarkCase) []const u8 {
        return switch (self.worker_mode) {
            .serial_direct => "serial",
            .fixed_1 => "fixed-1",
            .fixed_2 => "fixed-2",
            .fixed_auto => "fixed-auto",
        };
    }
};

pub const WorkerMode = enum {
    serial_direct,
    fixed_1,
    fixed_2,
    fixed_auto,
};

pub const RangeMode = enum {
    default,
    small,
    large,
};

pub const AdaptiveRangeMode = enum {
    none,
    fixed,
    tuned,
};

pub const default_cases = [_]BenchmarkCase{
    .{
        .name = "serial-direct",
        .worker_mode = .serial_direct,
    },
    .{
        .name = "thread-fixed-1",
        .worker_mode = .fixed_1,
        .required_worker_count = 1,
    },
    .{
        .name = "thread-fixed-2",
        .worker_mode = .fixed_2,
        .required_worker_count = 2,
    },
    .{
        .name = "thread-fixed-auto",
        .worker_mode = .fixed_auto,
        .required_worker_count = 1,
    },
    .{
        .name = "thread-small-range",
        .worker_mode = .fixed_auto,
        .range_mode = .small,
        .required_worker_count = 1,
    },
    .{
        .name = "thread-large-range",
        .worker_mode = .fixed_auto,
        .range_mode = .large,
        .required_worker_count = 1,
    },
    .{
        .name = "thread-adaptive-fixed-range",
        .worker_mode = .fixed_auto,
        .adaptive = true,
        .adaptive_range_mode = .fixed,
        .required_worker_count = 1,
    },
    .{
        .name = "thread-adaptive-tuned-range",
        .worker_mode = .fixed_auto,
        .adaptive = true,
        .adaptive_range_mode = .tuned,
        .required_worker_count = 1,
    },
};

pub const RunStatus = enum {
    measured,
    skipped,
};

pub const RunStats = struct {
    // Plain scalar result surface shared by every benchmark group. Subsystem
    // counters are optional so the report formatter stays generic.
    status: RunStatus = .measured,
    skip_reason: []const u8 = "",
    item_count: usize = 0,
    candidate_pairs: usize = 0,
    sample_count: usize = 0,
    output_count: usize = 0,
    deferred_count: usize = 0,
    fallback_deferred_count: usize = 0,
    cache_evictions: usize = 0,
    // Multi-step samples: the mean over timed samples of each sample's longest step.
    max_step_ns: u64 = 0,
    iterations: usize = 0,
    mean_ns: u64 = 0,
    min_ns: u64 = 0,
    max_ns: u64 = 0,
    items_per_second: u64 = 0,
    batch: BatchSummary = .{},
    secondary_batch: ?BatchSummary = null,
    // Nav groups: the mark stage (null when the workload marks no events) and the key plan.
    nav_mark_batch: ?BatchSummary = null,
    nav_plan_batch: ?BatchSummary = null,
    // Static-collider groups: the chunk lists' and the query lists' splice stages.
    splice_batch: ?BatchSummary = null,
    query_splice_batch: ?BatchSummary = null,
    // Steering groups: the prepare stages ahead of the avoidance pass (`batch`).
    steering_stages: ?SteeringStageSummary = null,
    work_tuning: ?WorkTuningSummary = null,
    secondary_work_tuning: ?WorkTuningSummary = null,
    render_prep_phases: ?RenderPrepPhaseSummary = null,
    render_game_prep_phases: ?RenderGamePrepPhaseSummary = null,
    terrain_edit_phases: ?TerrainEditPhaseSummary = null,
    // Nav groups: the reaction's connectivity stages and flood (the removal reaction).
    nav_conn: ?NavConnSummary = null,
    // Nav groups: the reaction's main-thread time split by section.
    nav_main: ?NavMainSummary = null,
    render_game_prep_sparse_submitted: usize = 0,
    render_game_prep_dynamic_records: usize = 0,
    render_game_prep_static_groups: usize = 0,
    render_game_prep_merged_tilemap_groups: usize = 0,
    ai_behavior_histogram: ?AiBehaviorHistogramSummary = null,

    pub fn skipped(reason: []const u8) RunStats {
        return .{
            .status = .skipped,
            .skip_reason = reason,
        };
    }
};

/// One nav reaction's connectivity: the seed, gather, and flood stage shapes (the flood's
/// rounds folded into one), its families, rounds, the fewest and most searches a round
/// dispatched, the active sets the round builds walked on the main thread, nodes expanded,
/// components split off, and roots merged, the flood's summed
/// dispatch time and its share on workers, and the flood tuner's policy after the case
/// (null when the case runs no adaptive tuner; zero workers is inline). Then the one-way
/// closure's stage shapes (candidates, resolve, mask, plan, rows with round 0 and its rounds
/// folded, compaction) and counters: components touched, links resolved, terminals new and
/// left, rows recomputed, rounds, words written, blocks narrowed, the arena's live, dead, and
/// allocated words, and compactions; and the reserve of its busiest batch: the arena tail
/// words its bound reserved and its blocks took, the arena's word limit, its candidates' block
/// words, the live words at its prepare, and the terminals it could number.
pub const NavConnSummary = struct {
    seed: BatchSummary = .{},
    gather: BatchSummary = .{},
    flood: BatchSummary = .{},
    families: usize = 0,
    rounds: usize = 0,
    round_items_min: usize = 0,
    round_items_max: usize = 0,
    build_visits: usize = 0,
    flood_nodes: usize = 0,
    splits: usize = 0,
    merges: usize = 0,
    flood_off_main_ns: u64 = 0,
    flood_tuner_workers: ?usize = null,
    candidates: BatchSummary = .{},
    closure_resolve: BatchSummary = .{},
    closure_mask: BatchSummary = .{},
    closure_plan: BatchSummary = .{},
    closure_rows: BatchSummary = .{},
    closure_compact: BatchSummary = .{},
    closure_touched: usize = 0,
    closure_links: usize = 0,
    closure_terms_new: usize = 0,
    closure_terms_left: usize = 0,
    closure_a_rows: usize = 0,
    closure_rounds: usize = 0,
    closure_words_written: usize = 0,
    closure_shrinks: usize = 0,
    closure_live_words: usize = 0,
    closure_dead_words: usize = 0,
    closure_arena_capacity: usize = 0,
    closure_compactions: usize = 0,
    closure_tail_bound: usize = 0,
    closure_tail_used: usize = 0,
    closure_arena_limit: usize = 0,
    closure_candidate_words: usize = 0,
    closure_live_prepared: usize = 0,
    closure_kb: usize = 0,
};

/// Nav reaction main-thread time (wall time outside every worker dispatch), its stage time run
/// inline, and its ordered sections, summed over the reactions added and divided by `samples`
/// when printed. `rest` is the main time neither holds: untimed glue.
pub const NavMainSummary = struct {
    samples: u64 = 0,
    main_ns: u64 = 0,
    inline_ns: u64 = 0,
    sections: NavMainPhases = .{},

    /// Adds one reaction: its main time and its stats' inline stage time and sections.
    pub fn add(self: *NavMainSummary, main_ns: u64, stats: NavUpdateStats) void {
        self.main_ns += main_ns;
        self.inline_ns += stats.inline_stage_ns;
        addSections(&self.sections, stats.main);
    }

    /// Adds `other`'s reactions, its samples not counted.
    pub fn merge(self: *NavMainSummary, other: NavMainSummary) void {
        self.main_ns += other.main_ns;
        self.inline_ns += other.inline_ns;
        addSections(&self.sections, other.sections);
    }

    /// Counts one sample: a reaction, or an iteration whose reactions were added.
    pub fn endSample(self: *NavMainSummary) void {
        self.samples += 1;
    }

    fn addSections(total: *NavMainPhases, phases: NavMainPhases) void {
        inline for (@typeInfo(NavMainPhases).@"struct".field_names) |name| @field(total, name) += @field(phases, name);
    }
};

pub fn batchSummaryFromBatch(batch: BatchStats) BatchSummary {
    return .{
        .item_count = batch.item_count,
        .range_count = batch.range_count,
        .items_per_range = batch.items_per_range,
        .range_alignment_items = batch.range_alignment_items,
        .available_worker_threads = batch.available_worker_threads,
        .active_worker_threads = batch.active_worker_threads,
        .main_thread_ranges = batch.main_thread_ranges,
        .worker_thread_ranges = batch.worker_thread_ranges,
        .worker_utilization_percent = @intFromFloat(batch.worker_utilization * 100.0),
        .batch_duration_ns = batch.batch_duration_ns,
        .main_thread_wait_ns = batch.main_thread_wait_ns,
        .ran_inline = batch.ran_inline,
    };
}

const CaseResult = struct {
    case: BenchmarkCase,
    stats: RunStats,
};

pub const BatchSummary = struct {
    // Compact copy of ThreadSystem batch telemetry used after a case returns,
    // keeping report code independent from mutable tuner/batch state.
    item_count: usize = 0,
    range_count: usize = 0,
    items_per_range: usize = 0,
    range_alignment_items: usize = 0,
    available_worker_threads: usize = 0,
    active_worker_threads: usize = 0,
    main_thread_ranges: usize = 0,
    worker_thread_ranges: usize = 0,
    worker_utilization_percent: u32 = 0,
    batch_duration_ns: u64 = 0,
    main_thread_wait_ns: u64 = 0,
    ran_inline: bool = true,
};

pub const RenderPrepPhaseSummary = struct {
    ordered_submit_ns: u64 = 0,
    snapshot_ns: u64 = 0,
    vertex_emit_ns: u64 = 0,
    draw_group_ns: u64 = 0,
};

/// Steering's prepare stage batches, in stage order.
pub const SteeringStageSummary = struct {
    agents: BatchSummary = .{},
    select_resolve: BatchSummary = .{},
    select_claim: BatchSummary = .{},
    directions: BatchSummary = .{},
    grid_bucket: BatchSummary = .{},
    grid_sort: BatchSummary = .{},
    // Entries in the agent grid's largest band after the last step.
    band_max: usize = 0,
};

/// Mean per-iteration time of a batched terrain edit's plan and write stages, its nav
/// reaction (the nav groups only), and the rest of the iteration (the main thread's
/// serial share).
pub const TerrainEditPhaseSummary = struct {
    plan_ns: u64 = 0,
    write_ns: u64 = 0,
    nav_ns: u64 = 0,
    main_ns: u64 = 0,
};

pub const RenderGamePrepPhaseSummary = struct {
    entity_collect_ns: u64 = 0,
    merge_ns: u64 = 0,
    snapshot_ns: u64 = 0,
    vertex_emit_ns: u64 = 0,
};

/// Per-behavior selection counts after one measured `ai` run, read from
/// `AiAgentStore`'s hot `active_behavior` column post-update (the
/// arbitration output) -- proves the utility scorer actually spreads
/// selections across all five `AiBehavior` buckets at the measured fixture,
/// not just wander/pursue.
pub const AiBehaviorHistogramSummary = struct {
    wander: usize = 0,
    pursue: usize = 0,
    flee: usize = 0,
    investigate: usize = 0,
    cohere: usize = 0,
};

pub const WorkTuningSummary = struct {
    // Captures tuner state at the measurement boundary. Unsettled adaptive
    // results stay visible instead of being treated as final policy.
    phase: AdaptiveWorkPhase = .learning,
    initial_worker_threads: usize = 0,
    initial_range_items: usize = 0,
    final_worker_threads: usize = 0,
    final_items_per_range: usize = 0,
    best_worker_threads: usize = 0,
    best_items_per_range: usize = 0,
    candidate_worker_threads: ?usize = null,
    candidate_items_per_range: ?usize = null,
    sample_count: usize = 0,
    sample_window: usize = 0,
    failed_profile_count: usize = 0,
    settled_window_count: usize = 0,
    retune_after_settled_windows: usize = 0,
    settled_before_measurement: bool = false,
    best_mean_batch_duration_ns: u64 = 0,
    baseline_mean_batch_duration_ns: u64 = 0,
    has_threaded_profile: bool = false,
    probing: bool = false,
    probe_window_count: DiagnosticCount = if (diagnostics_enabled) 0 else {},
    demotion_count: DiagnosticCount = if (diagnostics_enabled) 0 else {},
};

pub const StatsAccumulator = struct {
    // Accumulates successful measurement iterations only. Skipped cases keep
    // their reason in RunStats and never affect timing means.
    item_count: usize,
    iterations: usize = 0,
    total_ns: u128 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    total_batch_duration_ns: u128 = 0,
    total_main_thread_wait_ns: u128 = 0,
    total_main_thread_ranges: u128 = 0,
    total_worker_thread_ranges: u128 = 0,
    total_worker_utilization: f64 = 0,
    last_batch: BatchStats = .{},

    pub fn init(item_count: usize) StatsAccumulator {
        return .{ .item_count = item_count };
    }

    pub fn record(self: *StatsAccumulator, elapsed_ns: u64, batch: BatchStats) void {
        self.iterations += 1;
        self.total_ns += elapsed_ns;
        self.min_ns = @min(self.min_ns, elapsed_ns);
        self.max_ns = @max(self.max_ns, elapsed_ns);
        self.total_batch_duration_ns += batch.batch_duration_ns;
        self.total_main_thread_wait_ns += batch.main_thread_wait_ns;
        self.total_main_thread_ranges += batch.main_thread_ranges;
        self.total_worker_thread_ranges += batch.worker_thread_ranges;
        self.total_worker_utilization += batch.worker_utilization;
        self.last_batch = batch;
    }

    pub fn finish(self: StatsAccumulator) RunStats {
        if (self.iterations == 0) return .{};

        const iteration_count: u128 = self.iterations;
        const total_items = @as(u128, self.item_count) * iteration_count;
        const items_per_second = if (self.total_ns == 0)
            @as(u64, 0)
        else
            u128ToU64Saturated((total_items * std.time.ns_per_s) / self.total_ns);

        return .{
            .item_count = self.item_count,
            .iterations = self.iterations,
            .mean_ns = u128ToU64Saturated(self.total_ns / iteration_count),
            .min_ns = self.min_ns,
            .max_ns = self.max_ns,
            .items_per_second = items_per_second,
            .batch = .{
                .item_count = self.last_batch.item_count,
                .range_count = self.last_batch.range_count,
                .items_per_range = self.last_batch.items_per_range,
                .range_alignment_items = self.last_batch.range_alignment_items,
                .available_worker_threads = self.last_batch.available_worker_threads,
                .active_worker_threads = self.last_batch.active_worker_threads,
                .main_thread_ranges = u128ToUsizeSaturated(self.total_main_thread_ranges / iteration_count),
                .worker_thread_ranges = u128ToUsizeSaturated(self.total_worker_thread_ranges / iteration_count),
                .worker_utilization_percent = @intFromFloat((self.total_worker_utilization / @as(f64, @floatFromInt(self.iterations))) * 100.0),
                .batch_duration_ns = u128ToU64Saturated(self.total_batch_duration_ns / iteration_count),
                .main_thread_wait_ns = u128ToU64Saturated(self.total_main_thread_wait_ns / iteration_count),
                .ran_inline = self.last_batch.ran_inline,
            },
        };
    }
};

pub fn workTuningSummary(report: AdaptiveWorkReport, settled_before_measurement: bool) WorkTuningSummary {
    return .{
        .phase = report.phase,
        .initial_worker_threads = report.initial_profile.worker_threads,
        .initial_range_items = report.initial_profile.items_per_range,
        .final_worker_threads = report.current_profile.worker_threads,
        .final_items_per_range = report.current_profile.items_per_range,
        .best_worker_threads = report.best_profile.worker_threads,
        .best_items_per_range = report.best_profile.items_per_range,
        .candidate_worker_threads = if (report.candidate_profile) |profile| profile.worker_threads else null,
        .candidate_items_per_range = if (report.candidate_profile) |profile| profile.items_per_range else null,
        .sample_count = report.sample_count,
        .sample_window = report.sample_window,
        .failed_profile_count = report.failed_profile_count,
        .settled_window_count = report.settled_window_count,
        .retune_after_settled_windows = report.retune_after_settled_windows,
        .settled_before_measurement = settled_before_measurement,
        .best_mean_batch_duration_ns = report.best_mean_batch_duration_ns,
        .baseline_mean_batch_duration_ns = report.baseline_mean_batch_duration_ns,
        .has_threaded_profile = report.has_threaded_profile,
        .probing = report.probing,
        .probe_window_count = report.probe_window_count,
        .demotion_count = report.demotion_count,
    };
}

pub fn adaptiveTunerForCase(case: BenchmarkCase, range_alignment_items: usize) ?AdaptiveWorkTuner {
    // Fixed-adaptive cases reuse tuner reporting but clamp range probing so they
    // can act as a stable control against fully adaptive policy.
    if (!case.adaptive) return null;
    return switch (case.adaptive_range_mode) {
        .none, .tuned => null,
        .fixed => fixed: {
            const fixed_range = alignItemCount(default_items_per_range, range_alignment_items);
            break :fixed AdaptiveWorkTuner.init(.{
                .initial_range_items = fixed_range,
                .smallest_range_items = fixed_range,
                .largest_range_items = fixed_range,
            });
        },
    };
}

pub fn adaptiveSettleIterationLimit(options: Options) usize {
    const default_tuner_config = AdaptiveWorkTunerConfig{};
    const settle_windows: usize = 16;
    const settle_iterations = default_tuner_config.sample_window * settle_windows;
    return @max(options.iterations, settle_iterations);
}

pub fn parseOptions(args: []const []const u8) !Options {
    var options = Options{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--profile")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.profile = try parseProfile(args[index]);
        } else if (stripPrefix(arg, "--profile=")) |value| {
            options.profile = try parseProfile(value);
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.warmup_iterations = try parsePositiveUsize(args[index]);
        } else if (stripPrefix(arg, "--warmup=")) |value| {
            options.warmup_iterations = try parsePositiveUsize(value);
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.iterations = try parsePositiveUsize(args[index]);
        } else if (stripPrefix(arg, "--iterations=")) |value| {
            options.iterations = try parsePositiveUsize(value);
        } else if (std.mem.eql(u8, arg, "--case")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.case_filter = args[index];
        } else if (stripPrefix(arg, "--case=")) |value| {
            options.case_filter = value;
        } else if (std.mem.eql(u8, arg, "--group")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.group_filter = args[index];
        } else if (stripPrefix(arg, "--group=")) |value| {
            options.group_filter = value;
        } else if (std.mem.eql(u8, arg, "--group-prefix")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.group_prefix = args[index];
        } else if (stripPrefix(arg, "--group-prefix=")) |value| {
            options.group_prefix = value;
        } else if (std.mem.eql(u8, arg, "--items")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.item_count_filter = try parsePositiveUsize(args[index]);
        } else if (stripPrefix(arg, "--items=")) |value| {
            options.item_count_filter = try parsePositiveUsize(value);
        } else if (std.mem.eql(u8, arg, "--fallback-budget")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.fallback_budget = try parsePositiveUsize(args[index]);
        } else if (stripPrefix(arg, "--fallback-budget=")) |value| {
            options.fallback_budget = try parsePositiveUsize(value);
        } else if (std.mem.eql(u8, arg, "--details")) {
            options.details = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else {
            return error.InvalidArgument;
        }
    }
    if (options.case_filter) |filter| {
        if (findBenchmarkCase(filter) == null) return error.InvalidArgument;
    }
    return options;
}

pub fn runAll(allocator: std.mem.Allocator, io: std.Io, groups: []const BenchmarkGroup, options: Options) !void {
    // Run order is deterministic and stdout-first. The benchmark is a regression
    // detector, so reporting favors comparable tables over machine-specific tuning.
    printHeader(options);
    const filtered = options.group_filter != null or options.group_prefix != null;
    var matched_group = !filtered;
    for (groups) |group| {
        if (!groupSelected(options, group.name)) continue;
        matched_group = true;
        var explicit_item_count: [1]usize = undefined;
        const item_counts = itemCountsForOptions(group, options, &explicit_item_count);
        for (item_counts) |item_count| {
            var results: [default_cases.len]CaseResult = undefined;
            var result_count: usize = 0;

            for (default_cases) |case| {
                if (options.case_filter) |filter| {
                    if (!std.mem.eql(u8, filter, case.name) and !shouldIncludeBaselineForFilter(filter, case)) continue;
                }
                const stats = try group.runCase(allocator, io, options, case, item_count);
                results[result_count] = .{ .case = case, .stats = stats };
                result_count += 1;
            }

            printGroupReport(group, results[0..result_count], options);
        }
    }
    if (!matched_group) {
        std.debug.print("unknown benchmark group: {s}\n", .{options.group_filter orelse options.group_prefix.?});
        return error.InvalidArgument;
    }
}

/// A group runs when it equals `--group` (if given) and starts with `--group-prefix` (if given).
pub fn groupSelected(options: Options, group_name: []const u8) bool {
    if (options.group_filter) |filter| {
        if (!std.mem.eql(u8, filter, group_name)) return false;
    }
    if (options.group_prefix) |prefix| {
        if (!std.mem.startsWith(u8, group_name, prefix)) return false;
    }
    return true;
}

fn itemCountsForOptions(group: BenchmarkGroup, options: Options, explicit_item_count: *[1]usize) []const usize {
    if (options.item_count_filter) |item_count| {
        explicit_item_count[0] = item_count;
        return explicit_item_count[0..1];
    }
    return group.defaultItemCounts(options.profile);
}

pub fn printUsage() void {
    std.debug.print(
        \\Usage: zig build bench -- [options]
        \\
        \\Options:
        \\  --profile quick|standard|stress
        \\  --warmup N
        \\  --iterations N
        \\  --case name
        \\  --group name
        \\  --group-prefix prefix
        \\  --items N
        \\  --fallback-budget N
        \\  --details
        \\
        \\Default runs every benchmark case for every registered workload.
        \\
    , .{});
}

pub fn availableWorkerThreads() usize {
    const cpu_count = std.Thread.getCpuCount() catch return 0;
    return if (cpu_count > 1) cpu_count - 1 else 0;
}

pub fn skipIfWorkersUnavailable(case: BenchmarkCase) ?RunStats {
    if (case.required_worker_count == 0) return null;
    if (availableWorkerThreads() >= case.required_worker_count) return null;
    return RunStats.skipped("not enough worker threads available");
}

pub fn serialBatch(item_count: usize, range_alignment_items: usize) BatchStats {
    return .{
        .item_count = item_count,
        .range_count = if (item_count > 0) 1 else 0,
        .items_per_range = item_count,
        .range_alignment_items = range_alignment_items,
        .main_thread_ranges = if (item_count > 0) 1 else 0,
        .ran_inline = true,
    };
}

pub fn nowNs(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).toNanoseconds();
}

pub fn elapsedNs(start_ns: i96, end_ns: i96) u64 {
    return if (end_ns > start_ns) @intCast(end_ns - start_ns) else 0;
}

pub fn alignItemCount(item_count: usize, alignment: usize) usize {
    std.debug.assert(alignment > 0);
    if (alignment == 1) return item_count;
    const remainder = item_count % alignment;
    if (remainder == 0) return item_count;
    return item_count + (alignment - remainder);
}

/// Ceiling division of `item_count` into ranges of `items_per_range`, shared by
/// the benchmark fixtures so each does not re-roll its own ceil-division.
pub fn rangeCount(item_count: usize, items_per_range: usize) usize {
    if (items_per_range == 0) return 0;
    return std.math.divCeil(usize, item_count, items_per_range) catch unreachable; // lint:allow catch-unreachable: divisor guarded non-zero above
}

fn parseProfile(value: []const u8) !Profile {
    if (std.mem.eql(u8, value, "quick")) return .quick;
    if (std.mem.eql(u8, value, "standard")) return .standard;
    if (std.mem.eql(u8, value, "stress")) return .stress;
    return error.InvalidArgument;
}

fn parsePositiveUsize(value: []const u8) !usize {
    const parsed = try std.fmt.parseInt(usize, value, 10);
    if (parsed == 0) return error.InvalidArgument;
    return parsed;
}

fn stripPrefix(value: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    return value[prefix.len..];
}

fn findBenchmarkCase(name: []const u8) ?BenchmarkCase {
    for (default_cases) |case| {
        if (std.mem.eql(u8, name, case.name)) return case;
    }
    return null;
}

fn shouldIncludeBaselineForFilter(filter: []const u8, case: BenchmarkCase) bool {
    return !std.mem.eql(u8, filter, "serial-direct") and std.mem.eql(u8, case.name, "serial-direct");
}

fn printHeader(options: Options) void {
    std.debug.print(
        "\nbenchmark profile={s} warmup={} iterations={} default_cases={}\n",
        .{ @tagName(options.profile), options.warmup_iterations, options.iterations, default_cases.len },
    );
    std.debug.print("worker_threads_available={}\n", .{availableWorkerThreads()});
    std.debug.print("purpose: exercise benchmark flows, prove adaptive behavior, and catch regressions\n", .{});
    std.debug.print("case roles: serial-direct is baseline; thread-fixed-* rows are forced scheduler controls\n", .{});
    std.debug.print("case roles: thread-adaptive-* rows reflect production-style measured scheduling policy\n", .{});
}

fn printGroupReport(group: BenchmarkGroup, results: []const CaseResult, options: Options) void {
    // Compact mode keeps the key comparison visible in the terminal; detail mode
    // exposes the supporting batch/tuner telemetry.
    const baseline = findResult(results, "serial-direct") orelse {
        std.debug.print("\n{s}\n", .{group.name});
        std.debug.print("  no serial baseline was run\n", .{});
        if (options.details) printDetailTable(group.name, results, null);
        return;
    };
    if (baseline.stats.status == .skipped) {
        std.debug.print("\n{s}\n", .{group.name});
        std.debug.print("  serial baseline skipped: {s}\n", .{baseline.stats.skip_reason});
        if (options.details) printDetailTable(group.name, results, null);
        return;
    }

    const item_count = baseline.stats.item_count;
    std.debug.print("\n{s}  {} {s}\n\n", .{ group.name, item_count, itemLabel(group.name) });
    const best = bestMeasured(results) orelse baseline;
    const fixed_auto = measured(findResult(results, "thread-fixed-auto"));
    const adaptive = measured(findResult(results, "thread-adaptive-tuned-range")) orelse measured(findResult(results, "thread-adaptive-fixed-range"));

    printCompactTable(results, baseline);
    if (options.details) {
        std.debug.print("\n", .{});
        printDetailTable(group.name, results, baseline);
    } else {
        std.debug.print("\ndetails: pass --details for scheduler, range, and workload columns\n", .{});
    }
    printValidationSummary(group.name, baseline, best, fixed_auto, adaptive, results);
}

fn isRenderGamePrepGroup(group_name: []const u8) bool {
    return std.mem.eql(u8, group_name, "render-game-prep") or
        std.mem.startsWith(u8, group_name, "render-game-prep-");
}

// The steering groups timing one step over their agent count, one per agent layout.
fn isSteeringAgentGroup(group_name: []const u8) bool {
    return std.mem.eql(u8, group_name, "steering") or
        std.mem.eql(u8, group_name, "steering-shuffled") or
        std.mem.eql(u8, group_name, "steering-corridor") or
        std.mem.eql(u8, group_name, "steering-cluster-outlier");
}

fn itemLabel(group_name: []const u8) []const u8 {
    if (std.mem.eql(u8, group_name, "movement")) return "movement bodies";
    if (std.mem.startsWith(u8, group_name, "movement-apply-intents")) return "moving agents";
    if (std.mem.eql(u8, group_name, "particles")) return "particle rows";
    if (std.mem.eql(u8, group_name, "ai")) return "AI agents";
    if (std.mem.eql(u8, group_name, "ai-memory")) return "AI agents";
    if (std.mem.eql(u8, group_name, "ai-affect")) return "AI agents";
    if (std.mem.startsWith(u8, group_name, "plane-traversal")) return "AI agents";
    if (std.mem.eql(u8, group_name, "perception") or std.mem.startsWith(u8, group_name, "perception-")) return "perception agents";
    if (std.mem.eql(u8, group_name, "pathfinding")) return "path requests";
    if (std.mem.eql(u8, group_name, "pathfinding-cache-open")) return "cached open path requests";
    if (std.mem.eql(u8, group_name, "pathfinding-cache-detour")) return "cached detour path requests";
    if (std.mem.eql(u8, group_name, "pathfinding-cache-unreachable")) return "cached unreachable path requests";
    if (std.mem.eql(u8, group_name, "pathfinding-cold-unreachable")) return "uncached unreachable path requests";
    if (std.mem.eql(u8, group_name, "pathfinding-negative-steady")) return "fresh unreachable path requests per step";
    if (std.mem.eql(u8, group_name, "pathfinding-negative-dig")) return "(level side * 1000 + unreachable path requests)";
    if (std.mem.eql(u8, group_name, "pathfinding-negative-burst")) return "(variant * 10^6 + unreachable path requests in one burst)";
    if (std.mem.eql(u8, group_name, "pathfinding-connectivity-split")) return "(variant * 10^10 + edge chunks * 10^7 + level side * 1000 + levels)";
    if (std.mem.eql(u8, group_name, "pathfinding-connectivity-oneway")) return "(variant * 10^10 + terminals per system * 10^5 + one-way systems)";
    if (std.mem.eql(u8, group_name, "pathfinding-elastic-shrink")) return "agents before the drop";
    if (std.mem.startsWith(u8, group_name, "pathfinding-hard-fallback")) return "hard fallback path requests";
    if (isSteeringAgentGroup(group_name)) return "steering agents";
    if (std.mem.eql(u8, group_name, "steering-static-change")) return "static bodies";
    if (std.mem.eql(u8, group_name, "render-prep")) return "draw commands";
    if (isRenderGamePrepGroup(group_name)) return "render entities";
    if (std.mem.startsWith(u8, group_name, "render-sparse-window-")) return "sparse tiles in the world";
    if (std.mem.eql(u8, group_name, "collision")) return "collision bodies";
    if (std.mem.eql(u8, group_name, "collision-sparse")) return "collision bodies";
    if (std.mem.startsWith(u8, group_name, "collision-response")) return "contacts";
    if (std.mem.eql(u8, group_name, "chunk-scale-explosion-fill")) return "(sparse props * 10^10 + region chunks * 10^7 + level side * 1000 + levels)";
    if (std.mem.eql(u8, group_name, "chunk-scale-nav-enclose")) return "(variant * 10^10 + pockets, pocket edge, or tunnel chunks * 10^7 + level side * 1000 + levels)";
    if (isChunkScaleBatchGroup(group_name) or isChunkScaleNavBatchGroup(group_name)) return "(region chunks * 10^7 + level side * 1000 + levels)";
    if (std.mem.eql(u8, group_name, "chunk-scale-gpu-sync-dig")) return "(variant * 10^11 + resident layers * 10^9 + window edge chunks * 10^7 + level side * 1000 + levels)";
    if (std.mem.eql(u8, group_name, "chunk-scale-gpu-sync-pan")) return "(resident layers * 10^9 + window edge chunks * 10^7 + level side * 1000 + levels)";
    if (std.mem.eql(u8, group_name, "chunk-scale-gpu-sync-level-enter")) return "(resident layers * 10^9 + level side * 1000 + levels)";
    if (std.mem.eql(u8, group_name, "chunk-scale-nav-level-add")) return "(replace case * 10^7 + level side * 1000 + levels)";
    if (std.mem.eql(u8, group_name, "pathfinding-cross-level-teleport")) return "(layout * 10^12 + teleports * 10^7 + level side * 1000 + levels)";
    if (std.mem.eql(u8, group_name, "pathfinding-link-fold")) return "(axis * 10^9 + probe preload per chunk * 10^6 + random pads before the run)";
    if (std.mem.eql(u8, group_name, "pathfinding-level-size") or std.mem.startsWith(u8, group_name, "pathfinding-cross-level-")) return "(level side * 1000 + levels)";
    if (std.mem.startsWith(u8, group_name, "chunk-scale-")) return "(level side * 1000 + levels)";
    return "items";
}

// Chunk-scale groups timing one batched terrain edit across its chunks.
fn isChunkScaleBatchGroup(group_name: []const u8) bool {
    return std.mem.eql(u8, group_name, "chunk-scale-cave-in") or std.mem.eql(u8, group_name, "chunk-scale-explosion-fill");
}

// Chunk-scale groups timing one batched terrain edit plus its nav reaction.
fn isChunkScaleNavBatchGroup(group_name: []const u8) bool {
    return std.mem.eql(u8, group_name, "chunk-scale-nav-cave-in") or std.mem.eql(u8, group_name, "chunk-scale-nav-explosion-fill") or
        std.mem.eql(u8, group_name, "chunk-scale-nav-enclose");
}

fn printCompactTable(results: []const CaseResult, baseline: CaseResult) void {
    printCell("case", 30);
    printCell("mean", 11);
    printCell("vs_serial", 10);
    printCell("items_per_s", 13);
    printCell("worker_threads", 14);
    std.debug.print("status\n", .{});

    for (results) |result| {
        var mean_buffer: [32]u8 = undefined;
        var speedup_buffer: [24]u8 = undefined;
        var throughput_buffer: [32]u8 = undefined;
        var worker_buffer: [24]u8 = undefined;

        const mean = if (result.stats.status == .measured) formatDurationInto(&mean_buffer, result.stats.mean_ns) else "skipped";
        const speedup = if (result.stats.status == .measured) formatSpeedupInto(&speedup_buffer, speedupBasisPoints(baseline.stats, result.stats)) else "skipped";
        const throughput = if (result.stats.status == .measured) formatThroughputInto(&throughput_buffer, result.stats.items_per_second) else "skipped";
        const workers = if (result.stats.status == .measured) formatWorkerThreadsInto(&worker_buffer, result.stats) else "-";

        printCell(result.case.name, 30);
        printCell(mean, 11);
        printCell(speedup, 10);
        printCell(throughput, 13);
        printCell(workers, 14);
        std.debug.print("{s}\n", .{statusText(result.stats)});
    }
}

fn printDetailTable(group_name: []const u8, results: []const CaseResult, baseline: ?CaseResult) void {
    _ = baseline;
    printCell("case", 30);
    printCell("min", 11);
    printCell("max", 11);
    printCell("main_ranges", 12);
    printCell("worker_ranges", 14);
    printCell("wait", 11);
    printCell("items_per_range", 16);
    printCell("work_tuning", 72);
    std.debug.print("workload\n", .{});

    for (results) |result| {
        if (result.stats.status == .skipped) {
            printCell(result.case.name, 30);
            printCell("skipped", 11);
            printCell("skipped", 11);
            printCell("-", 12);
            printCell("-", 14);
            printCell("-", 11);
            printCell("-", 16);
            printCell("-", 72);
            std.debug.print("{s}\n", .{result.stats.skip_reason});
            continue;
        }

        var min_buffer: [32]u8 = undefined;
        var max_buffer: [32]u8 = undefined;
        var wait_buffer: [32]u8 = undefined;
        var main_ranges_buffer: [24]u8 = undefined;
        var worker_ranges_buffer: [24]u8 = undefined;
        var items_per_range_buffer: [24]u8 = undefined;
        var tuning_buffer: [96]u8 = undefined;
        var workload_buffer: [2560]u8 = undefined;

        printCell(result.case.name, 30);
        printCell(formatDurationInto(&min_buffer, result.stats.min_ns), 11);
        printCell(formatDurationInto(&max_buffer, result.stats.max_ns), 11);
        printCell(formatUsizeInto(&main_ranges_buffer, result.stats.batch.main_thread_ranges), 12);
        printCell(formatUsizeInto(&worker_ranges_buffer, result.stats.batch.worker_thread_ranges), 14);
        printCell(formatDurationInto(&wait_buffer, result.stats.batch.main_thread_wait_ns), 11);
        printCell(formatUsizeInto(&items_per_range_buffer, result.stats.batch.items_per_range), 16);
        printCell(formatWorkTuningInto(&tuning_buffer, result.stats.work_tuning), 72);
        std.debug.print("{s}\n", .{formatWorkloadInto(&workload_buffer, group_name, result.stats)});
    }
}

fn printValidationSummary(
    group_name: []const u8,
    baseline: CaseResult,
    best: CaseResult,
    fixed_auto: ?CaseResult,
    adaptive: ?CaseResult,
    results: []const CaseResult,
) void {
    const is_render_prep = std.mem.eql(u8, group_name, "render-prep");
    const is_render_game_prep = isRenderGamePrepGroup(group_name);
    // Keep the summary terse and action-oriented: it should call out unusual
    // scheduler behavior or workload counters without pretending to choose
    // runtime tuning policy from one benchmark run.
    if (is_render_prep or is_render_game_prep) {
        const focus = adaptive orelse best;
        const focus_label = if (adaptive != null) "production_adaptive" else if (is_render_game_prep) "render_game_prep_focus" else "render_prep_focus";
        const focus_speedup = speedupBasisPoints(baseline.stats, focus.stats);
        std.debug.print(
            "summary: {s} {s} at {f} ({d}.{d:0>2}x serial). ",
            .{ focus_label, focus.case.name, formatDuration(focus.stats.mean_ns), focus_speedup / 100, focus_speedup % 100 },
        );
        if (!std.mem.eql(u8, focus.case.name, best.case.name)) {
            const best_speedup = speedupBasisPoints(baseline.stats, best.stats);
            std.debug.print(
                "best_control {s} at {f} ({d}.{d:0>2}x serial). ",
                .{ best.case.name, formatDuration(best.stats.mean_ns), best_speedup / 100, best_speedup % 100 },
            );
        }
    } else {
        const speedup = speedupBasisPoints(baseline.stats, best.stats);
        std.debug.print(
            "summary: best {s} at {f} ({d}.{d:0>2}x serial). ",
            .{ best.case.name, formatDuration(best.stats.mean_ns), speedup / 100, speedup % 100 },
        );
    }

    if (adaptive) |adaptive_result| {
        if (adaptive_result.stats.work_tuning) |summary| {
            if (summary.has_threaded_profile) {
                std.debug.print(
                    "adaptive phase={s} best_profile={}/{} final={}/{}. ",
                    .{ @tagName(summary.phase), summary.best_worker_threads, summary.best_items_per_range, summary.final_worker_threads, summary.final_items_per_range },
                );
            } else {
                std.debug.print("adaptive phase={s} threaded_profile=none. ", .{@tagName(summary.phase)});
            }
        }
        if (adaptive_result.stats.batch.active_worker_threads == 0) {
            std.debug.print(
                "adaptive stayed inline with {}/{} worker_threads. ",
                .{ adaptive_result.stats.batch.active_worker_threads, adaptive_result.stats.batch.available_worker_threads },
            );
        } else {
            std.debug.print(
                "adaptive used {}/{} worker_threads. ",
                .{ adaptive_result.stats.batch.active_worker_threads, adaptive_result.stats.batch.available_worker_threads },
            );
        }
    } else {
        std.debug.print("adaptive flow not selected in this run. ", .{});
    }

    if (best.stats.candidate_pairs != 0 or
        best.stats.output_count != 0 or
        best.stats.deferred_count != 0 or
        best.stats.fallback_deferred_count != 0 or
        best.stats.cache_evictions != 0)
    {
        if (std.mem.eql(u8, group_name, "ai")) {
            std.debug.print(
                "workload separation_checks={} intents={} agents={}. ",
                .{ best.stats.candidate_pairs, best.stats.output_count, best.stats.item_count },
            );
            if (best.stats.ai_behavior_histogram) |histogram| {
                std.debug.print(
                    "behaviors wander={} pursue={} flee={} investigate={} cohere={}. ",
                    .{ histogram.wander, histogram.pursue, histogram.flee, histogram.investigate, histogram.cohere },
                );
            }
        } else if (std.mem.eql(u8, group_name, "pathfinding")) {
            std.debug.print(
                "workload field_requests={} results={}. ",
                .{ best.stats.candidate_pairs, best.stats.output_count },
            );
        } else if (std.mem.eql(u8, group_name, "pathfinding-cold-unreachable")) {
            std.debug.print(
                "workload unavailable={} solves={} deferred={}. ",
                .{ best.stats.output_count, best.stats.candidate_pairs, best.stats.deferred_count },
            );
        } else if (std.mem.eql(u8, group_name, "pathfinding-negative-steady")) {
            std.debug.print(
                "workload unavailable={} victims={} hits={}. ",
                .{ best.stats.output_count, best.stats.cache_evictions, best.stats.candidate_pairs },
            );
        } else if (std.mem.eql(u8, group_name, "pathfinding-negative-dig")) {
            std.debug.print(
                "workload unavailable={} solves={} exhausted={} pending={}. ",
                .{ best.stats.candidate_pairs, best.stats.output_count, best.stats.sample_count, best.stats.deferred_count },
            );
        } else if (std.mem.eql(u8, group_name, "pathfinding-negative-burst")) {
            std.debug.print(
                "workload searches={} unavailable={} steps={} status_steps={} projections={} fallbacks={} max_step={f}. ",
                .{ best.stats.candidate_pairs, best.stats.output_count, best.stats.sample_count, best.stats.deferred_count, best.stats.cache_evictions, best.stats.fallback_deferred_count, formatDuration(best.stats.max_step_ns) },
            );
        } else if (std.mem.eql(u8, group_name, "pathfinding-connectivity-split")) {
            std.debug.print(
                "workload cells={} structure_chunks={}. ",
                .{ best.stats.output_count, best.stats.candidate_pairs },
            );
        } else if (std.mem.eql(u8, group_name, "pathfinding-connectivity-oneway")) {
            std.debug.print(
                "workload rooms={} oneway_links={}. ",
                .{ best.stats.candidate_pairs, best.stats.output_count },
            );
        } else if (std.mem.eql(u8, group_name, "pathfinding-elastic-shrink")) {
            std.debug.print(
                "workload evicted={} moved={} kept={}. ",
                .{ best.stats.cache_evictions, best.stats.candidate_pairs, best.stats.output_count },
            );
        } else if (std.mem.startsWith(u8, group_name, "pathfinding-cache")) {
            std.debug.print(
                "workload cache_hits={} results={}. ",
                .{ best.stats.candidate_pairs, best.stats.output_count },
            );
        } else if (std.mem.startsWith(u8, group_name, "pathfinding-hard-fallback")) {
            std.debug.print(
                "workload fallback_requests={} fallback_deferred={} deferred={} results={} evictions={}. ",
                .{ best.stats.candidate_pairs, best.stats.fallback_deferred_count, best.stats.deferred_count, best.stats.output_count, best.stats.cache_evictions },
            );
        } else if (std.mem.startsWith(u8, group_name, "collision-response")) {
            std.debug.print(
                "workload triggers={} intents={}. ",
                .{ best.stats.candidate_pairs, best.stats.output_count },
            );
        } else if (std.mem.eql(u8, group_name, "render-prep")) {
            const render_prep_focus = adaptive orelse best;
            const focus_label = if (adaptive != null) "production_adaptive" else "render_prep_focus";
            std.debug.print(
                "{s}={s} workload vertices={} sprites={} skipped={} groups={}. ",
                .{
                    focus_label,
                    render_prep_focus.case.name,
                    render_prep_focus.stats.candidate_pairs,
                    render_prep_focus.stats.output_count,
                    render_prep_focus.stats.deferred_count,
                    render_prep_focus.stats.sample_count,
                },
            );
            if (render_prep_focus.stats.render_prep_phases) |phases| {
                std.debug.print(
                    "phases ordered_submit={f} snapshot={f} vertex_emit={f} draw_groups={f}. ",
                    .{ formatDuration(phases.ordered_submit_ns), formatDuration(phases.snapshot_ns), formatDuration(phases.vertex_emit_ns), formatDuration(phases.draw_group_ns) },
                );
            }
        } else if (isRenderGamePrepGroup(group_name)) {
            const render_game_prep_focus = adaptive orelse best;
            const focus_label = if (adaptive != null) "production_adaptive" else "render_game_prep_focus";
            std.debug.print(
                "{s}={s} workload vertices={} sprites={} skipped={} merged_groups={} sparse={} dynamic_records={} static_groups={} merged_tilemap_groups={}. ",
                .{
                    focus_label,
                    render_game_prep_focus.case.name,
                    render_game_prep_focus.stats.candidate_pairs,
                    render_game_prep_focus.stats.output_count,
                    render_game_prep_focus.stats.deferred_count,
                    render_game_prep_focus.stats.sample_count,
                    render_game_prep_focus.stats.render_game_prep_sparse_submitted,
                    render_game_prep_focus.stats.render_game_prep_dynamic_records,
                    render_game_prep_focus.stats.render_game_prep_static_groups,
                    render_game_prep_focus.stats.render_game_prep_merged_tilemap_groups,
                },
            );
            if (render_game_prep_focus.stats.render_game_prep_phases) |phases| {
                std.debug.print(
                    "phases entity_collect={f} merge={f} snapshot={f} vertex_emit={f}. ",
                    .{ formatDuration(phases.entity_collect_ns), formatDuration(phases.merge_ns), formatDuration(phases.snapshot_ns), formatDuration(phases.vertex_emit_ns) },
                );
            }
        } else {
            std.debug.print(
                "workload candidates={} outputs={}. ",
                .{ best.stats.candidate_pairs, best.stats.output_count },
            );
        }
    }

    printFlowCoverage(results);

    if (validationAttention(fixed_auto, adaptive, bestFixedThreadedResult(results))) |attention| {
        std.debug.print(" attention: {s}.", .{attention});
    }
    std.debug.print("\n", .{});
}

fn bestFixedThreadedResult(results: []const CaseResult) ?CaseResult {
    return bestOfMeasured(&[_]?CaseResult{
        findResult(results, "thread-fixed-1"),
        findResult(results, "thread-fixed-2"),
        findResult(results, "thread-fixed-auto"),
        findResult(results, "thread-small-range"),
        findResult(results, "thread-large-range"),
    });
}

fn printFlowCoverage(results: []const CaseResult) void {
    var measured_count: usize = 0;
    var skipped_count: usize = 0;
    for (results) |result| {
        switch (result.stats.status) {
            .measured => measured_count += 1,
            .skipped => skipped_count += 1,
        }
    }
    std.debug.print("flow coverage {}/{} measured", .{ measured_count, results.len });
    if (skipped_count != 0) {
        std.debug.print(", {} skipped", .{skipped_count});
    }
    std.debug.print(".", .{});
}

fn validationAttention(fixed_auto: ?CaseResult, adaptive: ?CaseResult, threaded_control: ?CaseResult) ?[]const u8 {
    // Attention messages flag suspicious policy gaps against fixed controls. The
    // benchmark still exits successfully so timing noise can be reviewed.
    if (adaptive) |adaptive_result| {
        if (fixed_auto) |auto| {
            if (percentDelta(adaptive_result.stats.mean_ns, auto.stats.mean_ns) > 25) {
                return "adaptive is more than 25% slower than fixed-auto";
            }
        }
        if (adaptive_result.stats.batch.active_worker_threads > 0) {
            if (threaded_control) |fixed| {
                if (percentDelta(adaptive_result.stats.mean_ns, fixed.stats.mean_ns) > 25) {
                    return "adaptive is more than 25% slower than best fixed threaded control";
                }
            }
        }
    }

    return null;
}

fn printCell(value: []const u8, width: usize) void {
    // Table output stays plain text and width-based so diffs remain readable in
    // terminals and CI logs.
    std.debug.print("{s}", .{value});
    const padding = if (value.len < width) width - value.len else 1;
    for (0..padding + 2) |_| {
        std.debug.print(" ", .{});
    }
}

fn statusText(stats: RunStats) []const u8 {
    return switch (stats.status) {
        .measured => "measured",
        .skipped => stats.skip_reason,
    };
}

fn formatDurationInto(buffer: []u8, ns: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "{f}", .{formatDuration(ns)}) catch "duration";
}

fn formatSpeedupInto(buffer: []u8, basis_points: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}.{d:0>2}x", .{ basis_points / 100, basis_points % 100 }) catch "speedup";
}

fn formatThroughputInto(buffer: []u8, items_per_second: u64) []const u8 {
    const FormatUnit = struct {
        scale: u64,
        suffix: []const u8,
    };
    const unit = if (items_per_second >= 1_000_000_000)
        FormatUnit{ .scale = 1_000_000_000, .suffix = "G/s" }
    else if (items_per_second >= 1_000_000)
        FormatUnit{ .scale = 1_000_000, .suffix = "M/s" }
    else if (items_per_second >= 1_000)
        FormatUnit{ .scale = 1_000, .suffix = "K/s" }
    else
        FormatUnit{ .scale = 1, .suffix = "/s" };

    if (unit.scale == 1) {
        return std.fmt.bufPrint(buffer, "{}{s}", .{ items_per_second, unit.suffix }) catch "throughput";
    }

    const whole = items_per_second / unit.scale;
    const fraction = (items_per_second % unit.scale) / (unit.scale / 100);
    return std.fmt.bufPrint(buffer, "{}.{d:0>2}{s}", .{ whole, fraction, unit.suffix }) catch "throughput";
}

fn formatWorkerThreadsInto(buffer: []u8, stats: RunStats) []const u8 {
    return std.fmt.bufPrint(buffer, "{}/{}", .{ stats.batch.active_worker_threads, stats.batch.available_worker_threads }) catch "workers";
}

fn formatUsizeInto(buffer: []u8, value: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "{}", .{value}) catch "value";
}

fn formatWorkTuningInto(buffer: []u8, maybe_summary: ?WorkTuningSummary) []const u8 {
    // Keep tuner state compact enough for aligned tables; detailed conclusions
    // belong in validation text, not in every cell.
    const summary = maybe_summary orelse return "-";
    var writer: std.Io.Writer = .fixed(buffer);
    writeWorkTuning(&writer, summary) catch return "work";
    return writer.buffered();
}

fn writeWorkTuning(writer: *std.Io.Writer, summary: WorkTuningSummary) std.Io.Writer.Error!void {
    try writer.print("{s} settled={s}", .{ @tagName(summary.phase), yesNo(summary.settled_before_measurement) });
    if (summary.has_threaded_profile) {
        try writer.print(
            " best={}/{} final={}/{}",
            .{ summary.best_worker_threads, summary.best_items_per_range, summary.final_worker_threads, summary.final_items_per_range },
        );
    } else {
        try writer.writeAll(" threaded=none");
    }
    if (summary.candidate_items_per_range) |candidate| {
        try writer.print(" cand={}/{}", .{ summary.candidate_worker_threads orelse 0, candidate });
    }
    if (comptime diagnostics_enabled) {
        try writer.print(" probes={} demotes={}", .{ summary.probe_window_count, summary.demotion_count });
    }
}

fn formatWorkloadInto(buffer: []u8, group_name: []const u8, stats: RunStats) []const u8 {
    // Workload labels translate shared counters into subsystem language so the
    // report remains compact without hiding what was measured.
    if (std.mem.startsWith(u8, group_name, "nav-update-static-dense")) {
        var stage_buffer: [2048]u8 = undefined;
        var splice_buffer: [32]u8 = undefined;
        var query_splice_buffer: [32]u8 = undefined;
        const splice = stats.splice_batch orelse BatchSummary{};
        const query_splice = stats.query_splice_batch orelse BatchSummary{};
        const phases = stats.terrain_edit_phases orelse TerrainEditPhaseSummary{};
        const main_percent = if (stats.mean_ns == 0) 0 else phases.main_ns * 100 / stats.mean_ns;
        return std.fmt.bufPrint(
            buffer,
            "statics={} keys={} splice={s} qkeys={} qsplice={s} patched={} {s} commit_t={f} sync_t={f} nav_t={f} main={f} ({}%)",
            .{ stats.candidate_pairs, splice.item_count, formatStageShapeInto(&splice_buffer, splice), query_splice.item_count, formatStageShapeInto(&query_splice_buffer, query_splice), stats.output_count, formatNavStagesInto(&stage_buffer, stats), formatDuration(phases.plan_ns), formatDuration(phases.write_ns), formatDuration(phases.nav_ns), formatDuration(phases.main_ns), main_percent },
        ) catch "workload";
    }
    if (std.mem.startsWith(u8, group_name, "nav-update-")) {
        var stage_buffer: [2048]u8 = undefined;
        return std.fmt.bufPrint(buffer, "{s}", .{formatNavStagesInto(&stage_buffer, stats)}) catch "workload";
    }
    if (std.mem.startsWith(u8, group_name, "movement-apply-intents")) {
        var apply_buffer: [32]u8 = undefined;
        const phases = stats.terrain_edit_phases orelse TerrainEditPhaseSummary{};
        const main_percent = if (stats.mean_ns == 0) 0 else phases.main_ns * 100 / stats.mean_ns;
        return std.fmt.bufPrint(
            buffer,
            "intents={} apply={s} main={f} ({}%)",
            .{ stats.output_count, formatStageShapeInto(&apply_buffer, stats.batch), formatDuration(phases.main_ns), main_percent },
        ) catch "workload";
    }
    if (std.mem.eql(u8, group_name, "collision-response-stage")) {
        var gather_buffer: [32]u8 = undefined;
        var apply_buffer: [32]u8 = undefined;
        const phases = stats.terrain_edit_phases orelse TerrainEditPhaseSummary{};
        const main_percent = if (stats.mean_ns == 0) 0 else phases.main_ns * 100 / stats.mean_ns;
        return std.fmt.bufPrint(
            buffer,
            "intents={} triggers={} gather={s} apply={s} main_outside_stage_batches={f} ({}%)",
            .{ stats.output_count, stats.candidate_pairs, formatStageShapeInto(&gather_buffer, stats.batch), formatStageShapeInto(&apply_buffer, stats.secondary_batch orelse .{}), formatDuration(phases.main_ns), main_percent },
        ) catch "workload";
    }
    if (std.mem.startsWith(u8, group_name, "plane-traversal")) {
        var gather_buffer: [32]u8 = undefined;
        const phases = stats.terrain_edit_phases orelse TerrainEditPhaseSummary{};
        const main_percent = if (stats.mean_ns == 0) 0 else phases.main_ns * 100 / stats.mean_ns;
        return std.fmt.bufPrint(
            buffer,
            "agents={} entries={} gather={s} main={f} ({}%)",
            .{ stats.item_count, stats.output_count, formatStageShapeInto(&gather_buffer, stats.batch), formatDuration(phases.main_ns), main_percent },
        ) catch "workload";
    }
    if (std.mem.eql(u8, group_name, "chunk-scale-nav-level-add")) {
        var stage_buffer: [2048]u8 = undefined;
        return std.fmt.bufPrint(buffer, "levels={} {s}", .{ stats.output_count, formatNavStagesInto(&stage_buffer, stats) }) catch "workload";
    }
    if (stats.candidate_pairs == 0 and stats.output_count == 0 and stats.deferred_count == 0 and stats.fallback_deferred_count == 0 and stats.cache_evictions == 0) return "-";
    if (isChunkScaleBatchGroup(group_name)) {
        var plan_buffer: [32]u8 = undefined;
        var write_buffer: [32]u8 = undefined;
        const plan_stage = formatStageShapeInto(&plan_buffer, stats.secondary_batch orelse .{});
        const write_stage = formatStageShapeInto(&write_buffer, stats.batch);
        const phases = stats.terrain_edit_phases orelse TerrainEditPhaseSummary{};
        const main_percent = if (stats.mean_ns == 0) 0 else phases.main_ns * 100 / stats.mean_ns;
        return std.fmt.bufPrint(
            buffer,
            "cells={} chunks={} plan={s} write={s} plan_t={f} write_t={f} main={f} ({}%)",
            .{ stats.output_count, stats.batch.item_count, plan_stage, write_stage, formatDuration(phases.plan_ns), formatDuration(phases.write_ns), formatDuration(phases.main_ns), main_percent },
        ) catch "workload";
    }
    if (isChunkScaleNavBatchGroup(group_name)) {
        var stage_buffer: [2048]u8 = undefined;
        const stages = formatNavStagesInto(&stage_buffer, stats);
        const phases = stats.terrain_edit_phases orelse TerrainEditPhaseSummary{};
        const main_percent = if (stats.mean_ns == 0) 0 else phases.main_ns * 100 / stats.mean_ns;
        return std.fmt.bufPrint(
            buffer,
            "cells={} {s} plan_t={f} write_t={f} nav_t={f} main={f} ({}%)",
            .{ stats.output_count, stages, formatDuration(phases.plan_ns), formatDuration(phases.write_ns), formatDuration(phases.nav_ns), formatDuration(phases.main_ns), main_percent },
        ) catch "workload";
    }
    if (std.mem.eql(u8, group_name, "chunk-scale-nav-dig") or std.mem.eql(u8, group_name, "chunk-scale-nav-ramp")) {
        var stage_buffer: [2048]u8 = undefined;
        return std.fmt.bufPrint(buffer, "cells={} {s}", .{ stats.output_count, formatNavStagesInto(&stage_buffer, stats) }) catch "workload";
    }
    if (std.mem.eql(u8, group_name, "ai")) {
        if (stats.secondary_batch) |intent| {
            const tuning = stats.secondary_work_tuning;
            if (intent.active_worker_threads == 0 or intent.ran_inline) {
                if (tuning) |summary| {
                    const tuned = if (summary.has_threaded_profile) "threaded" else "none";
                    return std.fmt.bufPrint(
                        buffer,
                        "separation_checks={} intents={} intent=inline tuned={s}",
                        .{ stats.candidate_pairs, stats.output_count, tuned },
                    ) catch "workload";
                }
                return std.fmt.bufPrint(
                    buffer,
                    "separation_checks={} intents={} intent=inline",
                    .{ stats.candidate_pairs, stats.output_count },
                ) catch "workload";
            }
            return std.fmt.bufPrint(
                buffer,
                "separation_checks={} intents={} intent={}/{}",
                .{ stats.candidate_pairs, stats.output_count, intent.active_worker_threads, intent.items_per_range },
            ) catch "workload";
        }
        return std.fmt.bufPrint(buffer, "separation_checks={} intents={}", .{ stats.candidate_pairs, stats.output_count }) catch "workload";
    }
    if (std.mem.eql(u8, group_name, "pathfinding")) {
        return std.fmt.bufPrint(buffer, "field_requests={} results={}", .{ stats.candidate_pairs, stats.output_count }) catch "workload";
    }
    if (std.mem.eql(u8, group_name, "pathfinding-cold-unreachable")) {
        return std.fmt.bufPrint(buffer, "unavailable={} solves={} deferred={}", .{ stats.output_count, stats.candidate_pairs, stats.deferred_count }) catch "workload";
    }
    if (std.mem.eql(u8, group_name, "pathfinding-negative-steady")) {
        return std.fmt.bufPrint(buffer, "unavailable={} victims={} hits={}", .{ stats.output_count, stats.cache_evictions, stats.candidate_pairs }) catch "workload";
    }
    if (std.mem.eql(u8, group_name, "pathfinding-negative-dig")) {
        return std.fmt.bufPrint(buffer, "unavailable={} solves={} exhausted={} pending={}", .{ stats.candidate_pairs, stats.output_count, stats.sample_count, stats.deferred_count }) catch "workload";
    }
    if (std.mem.eql(u8, group_name, "pathfinding-negative-burst")) {
        return std.fmt.bufPrint(buffer, "searches={} unavailable={} steps={} status_steps={} projections={} fallbacks={} max_step={f}", .{ stats.candidate_pairs, stats.output_count, stats.sample_count, stats.deferred_count, stats.cache_evictions, stats.fallback_deferred_count, formatDuration(stats.max_step_ns) }) catch "workload";
    }
    if (std.mem.eql(u8, group_name, "pathfinding-connectivity-split")) {
        var stage_buffer: [2048]u8 = undefined;
        return std.fmt.bufPrint(buffer, "cells={} structure_chunks={} {s}", .{ stats.output_count, stats.candidate_pairs, formatNavStagesInto(&stage_buffer, stats) }) catch "workload";
    }
    if (std.mem.eql(u8, group_name, "pathfinding-connectivity-oneway")) {
        var stage_buffer: [2048]u8 = undefined;
        return std.fmt.bufPrint(buffer, "rooms={} oneway_links={} {s}", .{ stats.candidate_pairs, stats.output_count, formatNavStagesInto(&stage_buffer, stats) }) catch "workload";
    }
    if (std.mem.eql(u8, group_name, "pathfinding-elastic-shrink")) {
        return std.fmt.bufPrint(buffer, "evicted={} moved={} kept={}", .{ stats.cache_evictions, stats.candidate_pairs, stats.output_count }) catch "workload";
    }
    if (std.mem.startsWith(u8, group_name, "pathfinding-cache")) {
        return std.fmt.bufPrint(buffer, "cache_hits={} results={}", .{ stats.candidate_pairs, stats.output_count }) catch "workload";
    }
    if (std.mem.startsWith(u8, group_name, "pathfinding-hard-fallback")) {
        return std.fmt.bufPrint(
            buffer,
            "fallback_requests={} fallback_deferred={} deferred={} results={} evictions={}",
            .{ stats.candidate_pairs, stats.fallback_deferred_count, stats.deferred_count, stats.output_count, stats.cache_evictions },
        ) catch "workload";
    }
    if (std.mem.eql(u8, group_name, "steering-static-dense")) {
        var steer_buffer: [32]u8 = undefined;
        var stage_buffer: [160]u8 = undefined;
        const visits_per_agent_tenths = if (stats.output_count == 0) 0 else stats.candidate_pairs * 10 / stats.output_count;
        const main_ns = (stats.terrain_edit_phases orelse TerrainEditPhaseSummary{}).main_ns;
        const main_percent = if (stats.mean_ns == 0) 0 else main_ns * 100 / stats.mean_ns;
        return std.fmt.bufPrint(
            buffer,
            "obstacle_visits={} ({}.{}/agent) obstacle_samples={} intents={} {s} steer={s} main={f} ({}%)",
            .{ stats.candidate_pairs, visits_per_agent_tenths / 10, visits_per_agent_tenths % 10, stats.sample_count, stats.output_count, formatSteeringStagesInto(&stage_buffer, stats), formatStageShapeInto(&steer_buffer, stats.batch), formatDuration(main_ns), main_percent },
        ) catch "workload";
    }
    if (std.mem.eql(u8, group_name, "steering-static-change")) {
        var steer_buffer: [32]u8 = undefined;
        var stage_buffer: [160]u8 = undefined;
        const main_ns = (stats.terrain_edit_phases orelse TerrainEditPhaseSummary{}).main_ns;
        const main_percent = if (stats.mean_ns == 0) 0 else main_ns * 100 / stats.mean_ns;
        return std.fmt.bufPrint(
            buffer,
            "obstacle_checks={} obstacle_samples={} {s} steer={s} main={f} ({}%)",
            .{ stats.candidate_pairs, stats.sample_count, formatSteeringStagesInto(&stage_buffer, stats), formatStageShapeInto(&steer_buffer, stats.batch), formatDuration(main_ns), main_percent },
        ) catch "workload";
    }
    if (isSteeringAgentGroup(group_name)) {
        var steer_buffer: [32]u8 = undefined;
        var stage_buffer: [160]u8 = undefined;
        const band_max = (stats.steering_stages orelse SteeringStageSummary{}).band_max;
        const main_ns = (stats.terrain_edit_phases orelse TerrainEditPhaseSummary{}).main_ns;
        const main_percent = if (stats.mean_ns == 0) 0 else main_ns * 100 / stats.mean_ns;
        return std.fmt.bufPrint(
            buffer,
            "avoidance_checks={} samples={} intents={} {s} band_max={} steer={s} main={f} ({}%)",
            .{ stats.candidate_pairs, stats.sample_count, stats.output_count, formatSteeringStagesInto(&stage_buffer, stats), band_max, formatStageShapeInto(&steer_buffer, stats.batch), formatDuration(main_ns), main_percent },
        ) catch "workload";
    }
    if (std.mem.eql(u8, group_name, "perception") or std.mem.startsWith(u8, group_name, "perception-")) {
        return std.fmt.bufPrint(
            buffer,
            "sensed={} los_checks={} los_blocked={} found={} events={} dropped_events={}",
            .{ stats.sample_count, stats.candidate_pairs, stats.deferred_count, stats.output_count, stats.fallback_deferred_count, stats.cache_evictions },
        ) catch "workload";
    }
    if (std.mem.eql(u8, group_name, "render-prep")) {
        if (stats.render_prep_phases) |phases| {
            return std.fmt.bufPrint(
                buffer,
                "vertices={} sprites={} skipped={} groups={} phases ordered_submit={f} snapshot={f} vertex={f} groups={f}",
                .{
                    stats.candidate_pairs,
                    stats.output_count,
                    stats.deferred_count,
                    stats.sample_count,
                    formatDuration(phases.ordered_submit_ns),
                    formatDuration(phases.snapshot_ns),
                    formatDuration(phases.vertex_emit_ns),
                    formatDuration(phases.draw_group_ns),
                },
            ) catch "workload";
        }
        return std.fmt.bufPrint(buffer, "vertices={} sprites={} skipped={} groups={}", .{ stats.candidate_pairs, stats.output_count, stats.deferred_count, stats.sample_count }) catch "workload";
    }
    if (isRenderGamePrepGroup(group_name)) {
        if (stats.render_game_prep_phases) |phases| {
            return std.fmt.bufPrint(
                buffer,
                "vertices={} sprites={} skipped={} merged_groups={} sparse={} dynamic_records={} static_groups={} merged_tilemap_groups={} phases entity_collect={f} merge={f} snapshot={f} vertex={f}",
                .{
                    stats.candidate_pairs,
                    stats.output_count,
                    stats.deferred_count,
                    stats.sample_count,
                    stats.render_game_prep_sparse_submitted,
                    stats.render_game_prep_dynamic_records,
                    stats.render_game_prep_static_groups,
                    stats.render_game_prep_merged_tilemap_groups,
                    formatDuration(phases.entity_collect_ns),
                    formatDuration(phases.merge_ns),
                    formatDuration(phases.snapshot_ns),
                    formatDuration(phases.vertex_emit_ns),
                },
            ) catch "workload";
        }
        return std.fmt.bufPrint(
            buffer,
            "vertices={} sprites={} skipped={} merged_groups={} sparse={} dynamic_records={} static_groups={} merged_tilemap_groups={}",
            .{
                stats.candidate_pairs,
                stats.output_count,
                stats.deferred_count,
                stats.sample_count,
                stats.render_game_prep_sparse_submitted,
                stats.render_game_prep_dynamic_records,
                stats.render_game_prep_static_groups,
                stats.render_game_prep_merged_tilemap_groups,
            },
        ) catch "workload";
    }
    if (std.mem.startsWith(u8, group_name, "collision-response")) {
        return std.fmt.bufPrint(buffer, "triggers={} intents={}", .{ stats.candidate_pairs, stats.output_count }) catch "workload";
    }
    if (std.mem.startsWith(u8, group_name, "collision")) {
        if (stats.secondary_batch) |narrow| {
            const tuning = stats.secondary_work_tuning;
            if (narrow.active_worker_threads == 0 or narrow.ran_inline) {
                if (tuning) |summary| {
                    const tuned = if (summary.has_threaded_profile) "threaded" else "none";
                    return std.fmt.bufPrint(
                        buffer,
                        "candidates={} outputs={} narrow=inline tuned={s}",
                        .{ stats.candidate_pairs, stats.output_count, tuned },
                    ) catch "workload";
                }
                return std.fmt.bufPrint(
                    buffer,
                    "candidates={} outputs={} narrow=inline",
                    .{ stats.candidate_pairs, stats.output_count },
                ) catch "workload";
            }
            return std.fmt.bufPrint(
                buffer,
                "candidates={} outputs={} narrow={}/{}",
                .{ stats.candidate_pairs, stats.output_count, narrow.active_worker_threads, narrow.items_per_range },
            ) catch "workload";
        }
    }
    return std.fmt.bufPrint(buffer, "candidates={} outputs={}", .{ stats.candidate_pairs, stats.output_count }) catch "workload";
}

// A nav reaction's stage shapes: `mark=` (when the workload marks events), `plan=`, then
// `remask=` (the primary batch) and `patch=` (the secondary batch), then the connectivity
// block when the group reports one.
fn formatNavStagesInto(buffer: []u8, stats: RunStats) []const u8 {
    var mark_buffer: [32]u8 = undefined;
    var plan_buffer: [32]u8 = undefined;
    var remask_buffer: [32]u8 = undefined;
    var patch_buffer: [32]u8 = undefined;
    var conn_buffer: [1280]u8 = undefined;
    const plan = formatStageShapeInto(&plan_buffer, stats.nav_plan_batch orelse .{});
    const remask = formatStageShapeInto(&remask_buffer, stats.batch);
    const patch = formatStageShapeInto(&patch_buffer, stats.secondary_batch orelse .{});
    const conn = formatNavConnInto(&conn_buffer, stats.nav_conn);
    var main_buffer: [320]u8 = undefined;
    const main_split = formatNavMainInto(&main_buffer, stats.nav_main);
    if (stats.nav_mark_batch) |mark| {
        return std.fmt.bufPrint(buffer, "mark={s} plan={s} remask={s} patch={s}{s}{s}", .{ formatStageShapeInto(&mark_buffer, mark), plan, remask, patch, conn, main_split }) catch "stages";
    }
    return std.fmt.bufPrint(buffer, "plan={s} remask={s} patch={s}{s}{s}", .{ plan, remask, patch, conn, main_split }) catch "stages";
}

/// The ` main_split=` block of a nav reaction's main-thread sections, inline stage time, and
/// rest, per sample, or nothing.
pub fn formatNavMainInto(buffer: []u8, summary: ?NavMainSummary) []const u8 {
    const main = summary orelse return "";
    if (main.samples == 0) return "";
    var writer: std.Io.Writer = .fixed(buffer);
    writeNavMain(&writer, main) catch return " main_split";
    return writer.buffered();
}

fn writeNavMain(writer: *std.Io.Writer, main: NavMainSummary) std.Io.Writer.Error!void {
    const samples = main.samples;
    var held = main.inline_ns;
    try writer.writeAll(" main_split=");
    inline for (@typeInfo(NavMainPhases).@"struct".field_names, 0..) |name, index| {
        comptime std.debug.assert(std.mem.endsWith(u8, name, "_ns"));
        const section_ns = @field(main.sections, name);
        held += section_ns;
        if (index != 0) try writer.writeByte(' ');
        try writer.print("{s}:{f}", .{ name[0 .. name.len - "_ns".len], formatDuration(section_ns / samples) });
    }
    try writer.print(" inline:{f} rest:{f}", .{ formatDuration(main.inline_ns / samples), formatDuration((main.main_ns -| held) / samples) });
}

// The connectivity block of a nav reaction, or nothing.
fn formatNavConnInto(buffer: []u8, summary: ?NavConnSummary) []const u8 {
    const conn = summary orelse return "";
    var seed_buffer: [32]u8 = undefined;
    var gather_buffer: [32]u8 = undefined;
    var flood_buffer: [32]u8 = undefined;
    var tuner_buffer: [24]u8 = undefined;
    const tuner: []const u8 = if (conn.flood_tuner_workers) |workers|
        (if (workers == 0) "inline" else std.fmt.bufPrint(&tuner_buffer, "{}w", .{workers}) catch "tuner")
    else
        "-";
    var closure_buffer: [768]u8 = undefined;
    return std.fmt.bufPrint(buffer, " conn_seed={s} conn_gather={s} conn_flood={s} families={} rounds={} round_items={}-{} build_visits={} flood_nodes={} splits={} merges={} flood_dispatch={f} flood_off_main={f} flood_tuner={s}{s}", .{
        formatRunStageShapeInto(&seed_buffer, conn.seed),
        formatRunStageShapeInto(&gather_buffer, conn.gather),
        formatRunStageShapeInto(&flood_buffer, conn.flood),
        conn.families,
        conn.rounds,
        conn.round_items_min,
        conn.round_items_max,
        conn.build_visits,
        conn.flood_nodes,
        conn.splits,
        conn.merges,
        formatDuration(conn.flood.batch_duration_ns),
        formatDuration(conn.flood_off_main_ns),
        tuner,
        formatClosureInto(&closure_buffer, conn),
    }) catch " conn";
}

// The one-way closure block of a nav reaction, or nothing when the reaction ran no closure
// stage.
fn formatClosureInto(buffer: []u8, conn: NavConnSummary) []const u8 {
    if (conn.candidates.item_count == 0 and conn.closure_links == 0 and conn.closure_compact.item_count == 0) return "";
    var shape_buffers: [6][32]u8 = undefined;
    return std.fmt.bufPrint(buffer, " conn_candidates={s} closure_resolve={s} closure_mask={s} closure_plan={s} closure_rows={s} closure_compact={s} touched={} links={} terms_new={} terms_left={} a_rows={} closure_rounds={} words_written={} shrinks={} live_words={} dead_words={} arena_capacity={} compactions={} tail_bound={} tail_used={} arena_limit={} cand_words={} live_prepared={} kb={}", .{
        formatRunStageShapeInto(&shape_buffers[0], conn.candidates),
        formatRunStageShapeInto(&shape_buffers[1], conn.closure_resolve),
        formatRunStageShapeInto(&shape_buffers[2], conn.closure_mask),
        formatRunStageShapeInto(&shape_buffers[3], conn.closure_plan),
        formatRunStageShapeInto(&shape_buffers[4], conn.closure_rows),
        formatRunStageShapeInto(&shape_buffers[5], conn.closure_compact),
        conn.closure_touched,
        conn.closure_links,
        conn.closure_terms_new,
        conn.closure_terms_left,
        conn.closure_a_rows,
        conn.closure_rounds,
        conn.closure_words_written,
        conn.closure_shrinks,
        conn.closure_live_words,
        conn.closure_dead_words,
        conn.closure_arena_capacity,
        conn.closure_compactions,
        conn.closure_tail_bound,
        conn.closure_tail_used,
        conn.closure_arena_limit,
        conn.closure_candidate_words,
        conn.closure_live_prepared,
        conn.closure_kb,
    }) catch " closure";
}

/// The one-way closure fields of `stats` copied into `summary`.
pub fn fillClosureSummary(summary: *NavConnSummary, stats: anytype) void {
    summary.candidates = batchSummaryFromBatch(stats.conn_candidates_batch);
    summary.closure_resolve = batchSummaryFromBatch(stats.conn_closure_resolve_batch);
    summary.closure_mask = batchSummaryFromBatch(stats.conn_closure_mask_batch);
    summary.closure_plan = batchSummaryFromBatch(stats.conn_closure_plan_batch);
    summary.closure_rows = batchSummaryFromBatch(stats.conn_closure_rows_batch);
    summary.closure_compact = batchSummaryFromBatch(stats.conn_closure_compact_batch);
    summary.closure_touched = stats.closure_touched;
    summary.closure_links = stats.closure_links;
    summary.closure_terms_new = stats.closure_terms_new;
    summary.closure_terms_left = stats.closure_terms_left;
    summary.closure_a_rows = stats.closure_a_rows;
    summary.closure_rounds = stats.closure_rounds;
    summary.closure_words_written = stats.closure_words_written;
    summary.closure_shrinks = stats.closure_shrinks;
    summary.closure_live_words = stats.closure_live_words;
    summary.closure_dead_words = stats.closure_dead_words;
    summary.closure_arena_capacity = stats.closure_arena_capacity;
    summary.closure_compactions = stats.closure_compactions;
    summary.closure_tail_bound = stats.closure_tail_bound;
    summary.closure_tail_used = stats.closure_tail_used;
    summary.closure_arena_limit = stats.closure_arena_limit;
    summary.closure_candidate_words = stats.closure_candidate_words;
    summary.closure_live_prepared = stats.closure_live_prepared;
    summary.closure_kb = stats.closure_kb;
}

// Steering's prepare stage shapes, in stage order; `-` for a stage that did not run (the
// claim and the grid sort on the serial path).
fn formatSteeringStagesInto(buffer: []u8, stats: RunStats) []const u8 {
    const stages = stats.steering_stages orelse SteeringStageSummary{};
    var agents_buffer: [32]u8 = undefined;
    var resolve_buffer: [32]u8 = undefined;
    var claim_buffer: [32]u8 = undefined;
    var directions_buffer: [32]u8 = undefined;
    var bucket_buffer: [32]u8 = undefined;
    var sort_buffer: [32]u8 = undefined;
    return std.fmt.bufPrint(buffer, "agents={s} resolve={s} claim={s} dir={s} bucket={s} sort={s}", .{
        formatRunStageShapeInto(&agents_buffer, stages.agents),
        formatRunStageShapeInto(&resolve_buffer, stages.select_resolve),
        formatRunStageShapeInto(&claim_buffer, stages.select_claim),
        formatRunStageShapeInto(&directions_buffer, stages.directions),
        formatRunStageShapeInto(&bucket_buffer, stages.grid_bucket),
        formatRunStageShapeInto(&sort_buffer, stages.grid_sort),
    }) catch "stages";
}

// A stage's batch shape, or `-` when it covered no items.
fn formatRunStageShapeInto(buffer: []u8, batch: BatchSummary) []const u8 {
    if (batch.item_count == 0) return "-";
    return formatStageShapeInto(buffer, batch);
}

// A stage's batch shape as `inline` or workers/ranges.
fn formatStageShapeInto(buffer: []u8, batch: BatchSummary) []const u8 {
    if (batch.ran_inline or batch.active_worker_threads == 0) return "inline";
    return std.fmt.bufPrint(buffer, "{}w/{}r", .{ batch.active_worker_threads, batch.range_count }) catch "stage";
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn findResult(results: []const CaseResult, name: []const u8) ?CaseResult {
    for (results) |result| {
        if (std.mem.eql(u8, result.case.name, name)) return result;
    }
    return null;
}

fn bestMeasured(results: []const CaseResult) ?CaseResult {
    var best: ?CaseResult = null;
    for (results) |result| {
        if (result.stats.status != .measured) continue;
        if (best == null or result.stats.mean_ns < best.?.stats.mean_ns) {
            best = result;
        }
    }
    return best;
}

fn bestOfMeasured(results: []const ?CaseResult) ?CaseResult {
    var best: ?CaseResult = null;
    for (results) |maybe_result| {
        const result = measured(maybe_result) orelse continue;
        if (best == null or result.stats.mean_ns < best.?.stats.mean_ns) {
            best = result;
        }
    }
    return best;
}

fn measured(result: ?CaseResult) ?CaseResult {
    if (result == null) return null;
    if (result.?.stats.status != .measured) return null;
    return result.?;
}

fn speedupBasisPoints(baseline: RunStats, candidate: RunStats) u64 {
    if (candidate.mean_ns == 0) return 0;
    return @intCast((@as(u128, baseline.mean_ns) * 100) / candidate.mean_ns);
}

fn outputsPerItemBasisPoints(stats: RunStats) u64 {
    if (stats.item_count == 0) return 0;
    return @intCast((@as(u128, stats.output_count) * 100) / stats.item_count);
}

fn percentDelta(candidate_ns: u64, baseline_ns: u64) i64 {
    if (baseline_ns == 0) return 0;
    const candidate: i128 = candidate_ns;
    const baseline_value: i128 = baseline_ns;
    return @intCast(@divTrunc((candidate - baseline_value) * 100, baseline_value));
}

fn formatDuration(ns: u64) Duration {
    return .{ .ns = ns };
}

const Duration = struct {
    ns: u64,

    pub fn format(self: Duration, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.ns >= std.time.ns_per_ms) {
            const whole = self.ns / std.time.ns_per_ms;
            const fraction = (self.ns % std.time.ns_per_ms) / 10_000;
            try writer.print("{}.{d:0>2} ms", .{ whole, fraction });
        } else if (self.ns >= std.time.ns_per_us) {
            const whole = self.ns / std.time.ns_per_us;
            const fraction = (self.ns % std.time.ns_per_us) / 10;
            try writer.print("{}.{d:0>2} us", .{ whole, fraction });
        } else {
            try writer.print("{} ns", .{self.ns});
        }
    }
};

fn u128ToU64Saturated(value: u128) u64 {
    return if (value > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(value);
}

// Items-per-second from a single mean duration. Lets a group override the throughput
// numerator (e.g. items actually serviced vs requested) without re-deriving total_ns.
const mib: usize = 1024 * 1024;

/// The nav scaling groups' size limit: a config whose `navStorageBytes` exceeds it is
/// skipped, so every later build of these groups runs the same configs.
pub const nav_size_limit_bytes: usize = 512 * mib;

/// What sizes the nav a nav scaling config builds: a square world of `side` cells per
/// level in 16-cell chunks, its level links, the nav's threaded participants, and its
/// path-request capacity (agent budget and group fields; library defaults elsewhere).
pub const NavSizeConfig = struct {
    side: usize,
    levels: usize,
    links: usize = 0,
    participant_count: usize,
    agent_budget: usize,
    group_fields: usize,
    /// Cached results whose path can outgrow the inline stripe. The long-block pool grows
    /// in whole pages, so they are charged the pages holding one block each, clamped to one
    /// per cached result; the default charges every cached result. A fixture whose paths
    /// all fit inline passes 0 and checks that no long block was taken.
    long_results: usize = std.math.maxInt(usize),
    /// One-way links among `links`, clamped to it: the one-way closure is charged for these
    /// only, since a bidirectional link joins its endpoints both ways and holds no closure
    /// row; every link keeps its one-way registry entry. The default charges every link as
    /// one-way.
    oneway_links: usize = std.math.maxInt(usize),
    /// The most terminals one one-way system holds. The default charges one system holding
    /// every terminal.
    oneway_system_terminals: usize = std.math.maxInt(usize),
    /// The largest marks batch the workload runs; the default charges the worst.
    batch: NavBatch = .{},
    /// The built world's chunk forms and link endpoints (`NavGraph.storageContentOf`), plus
    /// what the workload adds; null charges every chunk mixed.
    content: ?NavGraph.StorageContent = null,
};

/// The largest marks batch of a nav scaling workload: the chunks its marks span (each mark
/// counted, at most one per changed cell or obstacle rect), its new links, and its distinct
/// chunk keys (its changed chunks with their four neighbours and both endpoint chunks of
/// each new link, over every level it touches). A batch reserves the graph's and
/// connectivity's staging per key, and the staging keeps the largest batch's size. The
/// defaults charge a mark per cell, every link, and every chunk.
pub const NavBatch = struct {
    mark_chunks: usize = std.math.maxInt(usize),
    links: usize = std.math.maxInt(usize),
    keys: usize = std.math.maxInt(usize),

    /// A nav that runs no marks batch after its build.
    pub const none: NavBatch = .{ .mark_chunks = 0, .links = 0, .keys = 0 };
};

// `navStorageBytes` by what reports it at run time: the graph (`NavGraph.residentBytes`),
// the group fields (`GroupField.residentBytes`), and the rest of the nav, which reports no
// bytes.
const NavStorageParts = struct {
    graph: usize,
    group_fields: usize,
    rest: usize,

    fn total(self: NavStorageParts) usize {
        return self.graph +| self.group_fields +| self.rest;
    }
};

/// An over-estimate of the bytes the per-chunk nav takes for `config` at its agent-budget
/// ceiling: the graph (`NavGraph.storageBytesBound`), group fields
/// (`GroupField.storageBytesBound`), per-participant search scratch, the tier-1 corridor
/// pool, the result cache with the long-block pages of `long_results`, the path registry,
/// and the goal table. Search scratch and group fields are sized by their node and cell
/// budgets, never by level cells.
pub fn navStorageBytes(config: NavSizeConfig) usize {
    return navStorageParts(config).total();
}

// `navStorageBytes` split by what reports it at run time.
fn navStorageParts(config: NavSizeConfig) NavStorageParts {
    // Library capacity defaults: explored nodes, stored path cells, the tier-0 and tier-1
    // abstract node and stitched cell caps, escalated solves per step, group field cells,
    // results cached per agent, and the per-step solve ceiling.
    const explored_nodes: usize = 4096;
    const stored_path_cells: usize = 512;
    const tier0_abstract_nodes: usize = 4096;
    const tier0_stitched_cells: usize = 512;
    const abstract_nodes: usize = 16384;
    const stitched_path_cells: usize = 2048;
    const escalated_solves: usize = 1;
    const group_field_cells: usize = 131072;
    const agents: usize = @max(8, config.agent_budget);
    const cached_results: usize = agents * 4;
    const block_words = resultBlockWords(explored_nodes, stitched_path_cells);
    const long_page_blocks = ResultCache.longBlocksPerPage(block_words);
    const long_blocks: usize = (@min(config.long_results, cached_results) + long_page_blocks - 1) / long_page_blocks * long_page_blocks;
    const solves_per_step: usize = @min(512, agents);
    const chunk_tiles: usize = 16;
    const participants: usize = @max(1, config.participant_count);
    const levels: usize = @max(1, config.levels);
    const chunks_per_side = (config.side + chunk_tiles - 1) / chunk_tiles;
    const chunks = chunks_per_side * chunks_per_side;
    // Per participant: the search table, the open heap (four entries per node), the path
    // buffer, and the tier-0 corridor scratch.
    const explored_heap_entries: usize = @max(16, explored_nodes * 4);
    const search = participants * (tableRows(explored_nodes) * @sizeOf(SearchSlot) + explored_heap_entries * @sizeOf(OpenNode) +
        explored_nodes * @sizeOf(u32) + corridorBytes(tier0_abstract_nodes, tier0_stitched_cells));
    // Per escalated solve a step admits: one tier-1 corridor scratch.
    const tier1_pool = escalated_solves * corridorBytes(abstract_nodes, stitched_path_cells);
    // Result cache, per entry: its probe slots, record, free index, owner-log room, and
    // inline stripe. A block holds the longest plain or stitched path: per solve slot one
    // worker stripe, its run-start window (2 B per block word), its solved-path record, and
    // its claim; and the long-pool blocks with their free indices.
    const result_block_bytes = block_words * @sizeOf(u32);
    const results = cached_results * ResultCache.bytesPerEntry(stored_path_cells) +
        solves_per_step * (result_block_bytes + block_words * @sizeOf(u16) + @sizeOf(SolvedPath) + @sizeOf(?ResultCache.Claimed)) +
        long_blocks * ResultCache.longBlockBytes(block_words);
    // Path registry, per cached result: an owner head per shard, and one run per chunk edge
    // of its stored cells, each an entry with its free id and, at most, a key of its own in
    // two table slots; a step's registration windows hold every solve's runs.
    const runs_per_result = stored_path_cells / chunk_tiles;
    const registry = cached_results * (registry_shard_count * @sizeOf(u32) + runs_per_result * (ChunkListMap.bytes_per_entry + 2 * ChunkListMap.bytes_per_key_slot)) +
        solves_per_step * runs_per_result * @sizeOf(RegRecord);
    // Goal table, per intent (one per agent): four map slots of key, value, and stamp, an
    // entry's ref and live cell, its scan slot, and a scan tally per aligned range.
    const goal_table = agents * (4 * (@sizeOf(u64) + 2 * @sizeOf(u32)) + @sizeOf(u64) + @sizeOf(u32) + @sizeOf(u64) + 2 * @sizeOf(usize));
    const graph = NavGraph.storageBytesBound(.{
        .chunks = chunks,
        .levels = levels,
        .links = config.links,
        .oneway_links = config.oneway_links,
        .oneway_system_terminals = config.oneway_system_terminals,
        .participants = participants,
        .batch_mark_chunks = config.batch.mark_chunks,
        .batch_links = config.batch.links,
        .batch_keys = config.batch.keys,
        .content = config.content,
    });
    return .{
        .graph = graph,
        .group_fields = config.group_fields *| GroupField.storageBytesBound(group_field_cells, chunks),
        .rest = search + tier1_pool + results + registry + goal_table,
    };
}

/// Fails when a built nav's measured graph or group-field bytes exceed what
/// `navStorageParts(config)` charges for them, printing both.
pub fn checkNavBytes(group_name: []const u8, item_count: usize, config: NavSizeConfig, system: *const PathfindingSystem) !void {
    const parts = navStorageParts(config);
    const graph_bytes = system.graph.residentBytes();
    var field_bytes: usize = 0;
    for (system.group_fields.items) |*field| field_bytes += field.residentBytes();
    if (graph_bytes <= parts.graph and field_bytes <= parts.group_fields) return;
    std.debug.print("  {s} {}: nav graph holds {} B against {} B charged, group fields {} B against {} B\n", .{
        group_name, item_count, graph_bytes, parts.graph, field_bytes, parts.group_fields,
    });
    return error.NavBytesPastEstimate;
}
// Rows the pathfinding tables reserve for `keys` keys; the library defaults sized here
// always fit, so an unbuildable table fails the build.
fn tableRows(comptime keys: usize) usize {
    return comptime hashTableSlots(keys) catch @compileError("nav table too wide");
}

// One corridor scratch: the abstract table, open heap, corridor refs and link flags, claim
// list, and the stitched path (one spare cell).
fn corridorBytes(comptime abstract_nodes: usize, comptime stitched_cells: usize) usize {
    const heap_entries: usize = @max(16, abstract_nodes * 4);
    return tableRows(abstract_nodes) * @sizeOf(AbstractSlot) + heap_entries * @sizeOf(OpenNode) +
        abstract_nodes * (@sizeOf(usize) + @sizeOf(bool) + @sizeOf(u32)) + (stitched_cells + 1) * @sizeOf(StitchedCell);
}

fn ceilMib(bytes: usize) usize {
    return (bytes + mib - 1) / mib;
}

/// Skip for a config whose `navStorageBytes` exceeds `nav_size_limit_bytes`. Prints the
/// figure once per config: on the serial case, and on a threaded case only when the
/// serial config fits (more participants need more scratch). A skip reason cannot carry
/// a formatted value past its case.
pub fn navSizeSkip(group_name: []const u8, item_count: usize, case: BenchmarkCase, config: NavSizeConfig) ?RunStats {
    const bytes = navStorageBytes(config);
    if (bytes <= nav_size_limit_bytes) return null;
    var serial = config;
    serial.participant_count = 1;
    if (!case.usesThreadSystem() or navStorageBytes(serial) <= nav_size_limit_bytes) {
        std.debug.print("  {s} {} {s}: nav needs {} MiB against the {} MiB bench nav-size limit\n", .{
            group_name,
            item_count,
            case.name,
            ceilMib(bytes),
            nav_size_limit_bytes / mib,
        });
    }
    return RunStats.skipped("nav exceeds the bench nav-size limit (figure above)");
}

pub fn itemsPerSecond(items: usize, mean_ns: u64) u64 {
    if (mean_ns == 0) return 0;
    return u128ToU64Saturated((@as(u128, items) * std.time.ns_per_s) / mean_ns);
}

fn u128ToUsizeSaturated(value: u128) usize {
    return if (value > std.math.maxInt(usize)) std.math.maxInt(usize) else @intCast(value);
}

test "default benchmark cases cover required thread modes" {
    try std.testing.expectEqual(@as(usize, 8), default_cases.len);
    try std.testing.expectEqualStrings("serial-direct", default_cases[0].name);
    try std.testing.expectEqualStrings("thread-fixed-1", default_cases[1].name);
    try std.testing.expectEqualStrings("thread-fixed-2", default_cases[2].name);
    try std.testing.expectEqualStrings("thread-fixed-auto", default_cases[3].name);
    try std.testing.expectEqualStrings("thread-small-range", default_cases[4].name);
    try std.testing.expectEqualStrings("thread-large-range", default_cases[5].name);
    try std.testing.expectEqualStrings("thread-adaptive-fixed-range", default_cases[6].name);
    try std.testing.expectEqualStrings("thread-adaptive-tuned-range", default_cases[7].name);
}

test "benchmark options parse scaling and filtering arguments" {
    const args = [_][]const u8{
        "--profile",
        "standard",
        "--warmup=2",
        "--iterations",
        "9",
        "--case",
        "thread-fixed-1",
        "--group=movement",
        "--items",
        "65536",
        "--fallback-budget=64",
        "--details",
    };
    const options = try parseOptions(&args);
    try std.testing.expectEqual(Profile.standard, options.profile);
    try std.testing.expectEqual(@as(usize, 2), options.warmup_iterations);
    try std.testing.expectEqual(@as(usize, 9), options.iterations);
    try std.testing.expectEqualStrings("thread-fixed-1", options.case_filter.?);
    try std.testing.expectEqualStrings("movement", options.group_filter.?);
    try std.testing.expectEqual(@as(usize, 65_536), options.item_count_filter.?);
    try std.testing.expectEqual(@as(usize, 64), options.fallback_budget.?);
    try std.testing.expect(options.details);
}

test "benchmark group prefix selects a family and combines with an exact group" {
    const prefix_args = [_][]const u8{ "--group-prefix", "chunk-scale-" };
    const prefix = try parseOptions(&prefix_args);
    try std.testing.expectEqualStrings("chunk-scale-", prefix.group_prefix.?);
    try std.testing.expect(groupSelected(prefix, "chunk-scale-dig"));
    try std.testing.expect(groupSelected(prefix, "chunk-scale-cave-in"));
    try std.testing.expect(!groupSelected(prefix, "nav-update"));

    const both_args = [_][]const u8{ "--group-prefix=chunk-scale-", "--group=chunk-scale-dig" };
    const both = try parseOptions(&both_args);
    try std.testing.expect(groupSelected(both, "chunk-scale-dig"));
    try std.testing.expect(!groupSelected(both, "chunk-scale-cave-in"));
    try std.testing.expect(groupSelected(.{}, "movement"));
    try std.testing.expectError(error.MissingArgument, parseOptions(&[_][]const u8{"--group-prefix"}));
}

test "benchmark options reject zero iterations" {
    const args = [_][]const u8{ "--iterations", "0" };
    try std.testing.expectError(error.InvalidArgument, parseOptions(&args));
}

test "benchmark options reject unknown case filter" {
    const args = [_][]const u8{ "--case", "does-not-exist" };
    try std.testing.expectError(error.InvalidArgument, parseOptions(&args));
}

test "benchmark case filter includes serial baseline for non-serial cases" {
    try std.testing.expect(shouldIncludeBaselineForFilter("thread-adaptive-tuned-range", default_cases[0]));
    try std.testing.expect(!shouldIncludeBaselineForFilter("serial-direct", default_cases[0]));
    try std.testing.expect(!shouldIncludeBaselineForFilter("thread-adaptive-tuned-range", default_cases[7]));
}

test "work tuning summary preserves settled phase" {
    const summary = workTuningSummary(.{
        .phase = .settled,
        .initial_profile = .{ .worker_threads = 0, .items_per_range = 64 },
        .current_profile = .{ .worker_threads = 4, .items_per_range = 256 },
        .best_profile = .{ .worker_threads = 4, .items_per_range = 256 },
        .sample_window = 2,
        .failed_profile_count = 0,
        .settled_window_count = 4,
        .retune_after_settled_windows = 10_000,
        .best_mean_batch_duration_ns = 42,
        .has_threaded_profile = true,
        .probe_window_count = if (diagnostics_enabled) 7 else {},
        .demotion_count = if (diagnostics_enabled) 2 else {},
    }, true);

    try std.testing.expectEqual(AdaptiveWorkPhase.settled, summary.phase);
    try std.testing.expect(summary.settled_before_measurement);
    try std.testing.expectEqual(@as(usize, 4), summary.best_worker_threads);
    try std.testing.expectEqual(@as(usize, 256), summary.best_items_per_range);
    if (comptime diagnostics_enabled) {
        try std.testing.expectEqual(@as(u64, 7), summary.probe_window_count);
        try std.testing.expectEqual(@as(u64, 2), summary.demotion_count);
        var tuning_buffer: [96]u8 = undefined;
        try std.testing.expectEqualStrings(
            "settled settled=yes best=4/256 final=4/256 probes=7 demotes=2",
            formatWorkTuningInto(&tuning_buffer, summary),
        );
    }
}

test "fixed adaptive benchmark case disables range probing" {
    const tuner = adaptiveTunerForCase(default_cases[6], 16).?;
    const report = tuner.report();

    try std.testing.expectEqual(@as(usize, 64), report.initial_profile.items_per_range);
    try std.testing.expectEqual(@as(usize, 64), report.current_profile.items_per_range);
    try std.testing.expect(adaptiveTunerForCase(default_cases[7], 16) == null);
}

test "adaptive settle budget covers multiple tuner windows" {
    try std.testing.expectEqual(@as(usize, 48), adaptiveSettleIterationLimit(.{}));
    try std.testing.expectEqual(@as(usize, 100), adaptiveSettleIterationLimit(.{ .iterations = 100 }));
}

test "event scale profiles cover low through high signal counts" {
    try std.testing.expectEqualSlices(usize, &[_]usize{ 1_024, 4_096, 10_000 }, eventScaleCounts(.quick));
    try std.testing.expectEqualSlices(usize, &[_]usize{ 1_024, 4_096, 10_000, 25_000, 50_000 }, eventScaleCounts(.standard));
    try std.testing.expectEqualSlices(usize, &[_]usize{ 10_000, 25_000, 50_000 }, eventScaleCounts(.stress));
}

const test_item_counts = [_]usize{ 4, 8 };

fn testItemCounts(_: Profile) []const usize {
    return &test_item_counts;
}

fn testRunCase(_: std.mem.Allocator, _: std.Io, _: Options, _: BenchmarkCase, _: usize) anyerror!RunStats {
    return .{};
}

test "benchmark items option overrides registered counts" {
    const group = BenchmarkGroup{
        .name = "test",
        .defaultItemCounts = testItemCounts,
        .runCase = testRunCase,
    };
    var explicit_item_count: [1]usize = undefined;

    try std.testing.expectEqualSlices(
        usize,
        &test_item_counts,
        itemCountsForOptions(group, .{}, &explicit_item_count),
    );
    try std.testing.expectEqualSlices(
        usize,
        &[_]usize{256},
        itemCountsForOptions(group, .{ .item_count_filter = 256 }, &explicit_item_count),
    );
}

test "benchmark table formatters keep compact text" {
    var throughput_buffer: [32]u8 = undefined;
    var speedup_buffer: [16]u8 = undefined;
    var worker_buffer: [16]u8 = undefined;
    var range_buffer: [96]u8 = undefined;

    try std.testing.expectEqualStrings("1.23M/s", formatThroughputInto(&throughput_buffer, 1_234_567));
    try std.testing.expectEqualStrings("3.25x", formatSpeedupInto(&speedup_buffer, 325));
    try std.testing.expectEqualStrings("4/10", formatWorkerThreadsInto(&worker_buffer, .{
        .batch = .{
            .active_worker_threads = 4,
            .available_worker_threads = 10,
        },
    }));
    const counters_text = if (diagnostics_enabled) " probes=0 demotes=0" else "";
    try std.testing.expectEqualStrings(
        "settled settled=yes best=4/256 final=4/256" ++ counters_text,
        formatWorkTuningInto(&range_buffer, .{
            .phase = .settled,
            .best_worker_threads = 4,
            .best_items_per_range = 256,
            .final_worker_threads = 4,
            .final_items_per_range = 256,
            .settled_before_measurement = true,
            .has_threaded_profile = true,
        }),
    );
    try std.testing.expectEqualStrings(
        "fallback_requests=4 fallback_deferred=2 deferred=2 results=4 evictions=1",
        formatWorkloadInto(&range_buffer, "pathfinding-hard-fallback-budget", .{
            .candidate_pairs = 4,
            .fallback_deferred_count = 2,
            .deferred_count = 2,
            .output_count = 4,
            .cache_evictions = 1,
        }),
    );
}

test "nav main split prints each section, the inline stage time, and the rest per sample" {
    var buffer: [320]u8 = undefined;
    try std.testing.expectEqualStrings("", formatNavMainInto(&buffer, null));
    try std.testing.expectEqualStrings("", formatNavMainInto(&buffer, NavMainSummary{}));
    const stats = NavUpdateStats{
        .inline_stage_ns = 20_000,
        .main = .{
            .mark_ns = 1_000,
            .plan_ns = 2_000,
            .reserve_ns = 3_000,
            .commit_ns = 4_000,
            .conn_merge_ns = 5_000,
            .conn_layout_ns = 6_000,
            .flood_ns = 7_000,
            .closure_ns = 8_000,
            .evict_ns = 9_000,
        },
    };
    // Two samples: one reaction, then an iteration of a reaction merged from another summary.
    var summary = NavMainSummary{};
    summary.add(70_000, stats);
    summary.endSample();
    var other = NavMainSummary{};
    other.add(70_000, stats);
    summary.merge(other);
    summary.endSample();
    try std.testing.expectEqualStrings(
        " main_split=mark:1.00 us plan:2.00 us reserve:3.00 us commit:4.00 us conn_merge:5.00 us conn_layout:6.00 us flood:7.00 us closure:8.00 us evict:9.00 us inline:20.00 us rest:5.00 us",
        formatNavMainInto(&buffer, summary),
    );
}

test "steering layout groups share the steering agent label" {
    for ([_][]const u8{ "steering", "steering-shuffled", "steering-corridor", "steering-cluster-outlier" }) |group_name| {
        try std.testing.expectEqualStrings("steering agents", itemLabel(group_name));
    }
    try std.testing.expect(!isSteeringAgentGroup("steering-static-dense"));
}

test "steering stage label tells a stage that did not run from an inline one" {
    var buffer: [160]u8 = undefined;
    // The serial path: the claim and the grid sort never ran.
    try std.testing.expectEqualStrings("agents=inline resolve=inline claim=- dir=inline bucket=inline sort=-", formatSteeringStagesInto(&buffer, .{
        .steering_stages = .{
            .agents = .{ .item_count = 64, .range_count = 1, .ran_inline = true },
            .select_resolve = .{ .item_count = 48, .range_count = 1, .ran_inline = true },
            .directions = .{ .item_count = 48, .range_count = 1, .ran_inline = true },
            .grid_bucket = .{ .item_count = 64, .range_count = 1, .ran_inline = true },
        },
    }));
    // Threaded: the claim inline by its tuner, the grid sort on workers.
    try std.testing.expectEqualStrings("agents=2w/4r resolve=inline claim=inline dir=2w/3r bucket=2w/4r sort=3w/64r", formatSteeringStagesInto(&buffer, .{
        .steering_stages = .{
            .agents = .{ .item_count = 64, .range_count = 4, .active_worker_threads = 2, .ran_inline = false },
            .select_resolve = .{ .item_count = 48, .range_count = 1, .ran_inline = true },
            .select_claim = .{ .item_count = 4, .range_count = 1, .ran_inline = true },
            .directions = .{ .item_count = 48, .range_count = 3, .active_worker_threads = 2, .ran_inline = false },
            .grid_bucket = .{ .item_count = 64, .range_count = 4, .active_worker_threads = 2, .ran_inline = false },
            .grid_sort = .{ .item_count = 64, .range_count = 64, .active_worker_threads = 3, .ran_inline = false },
        },
    }));
}

test "benchmark skipped status keeps skip reason visible" {
    const skipped = RunStats.skipped("not enough worker threads available");
    try std.testing.expectEqualStrings("not enough worker threads available", statusText(skipped));
}

test "benchmark validation attention flags adaptive regressions against controls" {
    const fixed_auto = CaseResult{
        .case = default_cases[3],
        .stats = .{ .mean_ns = 100 },
    };
    const adaptive = CaseResult{
        .case = default_cases[6],
        .stats = .{
            .mean_ns = 130,
            .batch = .{ .active_worker_threads = 1 },
        },
    };
    const threaded_control = CaseResult{
        .case = default_cases[5],
        .stats = .{ .mean_ns = 100 },
    };

    try std.testing.expectEqualStrings(
        "adaptive is more than 25% slower than fixed-auto",
        validationAttention(fixed_auto, adaptive, null).?,
    );
    try std.testing.expectEqualStrings(
        "adaptive is more than 25% slower than best fixed threaded control",
        validationAttention(null, adaptive, threaded_control).?,
    );
    try std.testing.expect(validationAttention(fixed_auto, .{
        .case = default_cases[6],
        .stats = .{ .mean_ns = 110 },
    }, threaded_control) == null);
}

test "batch modes align to cache-line item boundaries" {
    const small = default_cases[4].itemsPerRange(16).?;
    const large = default_cases[5].itemsPerRange(16).?;
    try std.testing.expectEqual(@as(usize, 32), small);
    try std.testing.expectEqual(@as(usize, 256), large);
}

test "nav storage charges the one-way closure for one-way links only, every link by default" {
    const base = NavSizeConfig{ .side = 256, .levels = 2, .links = 4096, .participant_count = 1, .agent_budget = 8, .group_fields = 1, .batch = .{ .mark_chunks = 1, .links = 0, .keys = 5 } };
    var two_way = base;
    two_way.oneway_links = 0;
    var all_oneway = base;
    all_oneway.oneway_links = base.links;
    var past_all = base;
    past_all.oneway_links = 2 * base.links;
    try std.testing.expectEqual(navStorageBytes(base), navStorageBytes(all_oneway));
    try std.testing.expectEqual(navStorageBytes(base), navStorageBytes(past_all));
    try std.testing.expect(navStorageBytes(two_way) < navStorageBytes(base));
    // Systems of a few terminals each hold narrower blocks than one holding every terminal.
    var small_systems = base;
    small_systems.oneway_system_terminals = 8;
    try std.testing.expect(navStorageBytes(small_systems) < navStorageBytes(base));
    try std.testing.expect(navStorageBytes(two_way) < navStorageBytes(small_systems));
}

test "nav storage parts pass the config's shape to the graph and field bounds, and a batch moves only the graph" {
    const base = NavSizeConfig{ .side = 256, .levels = 2, .links = 64, .oneway_links = 0, .participant_count = 3, .agent_budget = 8, .group_fields = 2, .batch = NavBatch.none };
    var batch = base;
    batch.batch = .{ .mark_chunks = 300, .links = 10, .keys = 400 };
    for ([_]NavSizeConfig{ base, batch }) |config| {
        try std.testing.expectEqual(NavGraph.storageBytesBound(.{
            .chunks = 256,
            .levels = 2,
            .links = 64,
            .oneway_links = 0,
            .participants = 3,
            .batch_mark_chunks = config.batch.mark_chunks,
            .batch_links = config.batch.links,
            .batch_keys = config.batch.keys,
        }), navStorageParts(config).graph);
        try std.testing.expectEqual(2 * GroupField.storageBytesBound(131072, 256), navStorageParts(config).group_fields);
    }
    try std.testing.expect(navStorageParts(batch).graph > navStorageParts(base).graph);
    try std.testing.expectEqual(navStorageParts(base).rest, navStorageParts(batch).rest);
    try std.testing.expectEqual(navStorageBytes(batch) - navStorageBytes(base), navStorageParts(batch).graph - navStorageParts(base).graph);
}

test "nav storage charges the long-block pages of the long results, at most the pages of one per cached result" {
    const base = NavSizeConfig{ .side = 256, .levels = 1, .participant_count = 1, .agent_budget = 100, .group_fields = 1 };
    var inline_only = base;
    inline_only.long_results = 0;
    var one_long = base;
    one_long.long_results = 1;
    var ten_long = base;
    ten_long.long_results = 10;
    var past_all = base;
    past_all.long_results = 1000;
    // A long block holds 4096 words, plus its 4 B free index; eight fill a 128 KiB page.
    const per_block: usize = 4096 * 4 + 4;
    try std.testing.expectEqual(@as(usize, 8), ResultCache.longBlocksPerPage(4096));
    try std.testing.expectEqual(8 * per_block, navStorageBytes(one_long) - navStorageBytes(inline_only));
    try std.testing.expectEqual(16 * per_block, navStorageBytes(ten_long) - navStorageBytes(inline_only));
    // 100 agents cache 400 results, 50 pages; the default charges them, as do more long
    // results than cached ones.
    try std.testing.expectEqual(400 * per_block, navStorageBytes(base) - navStorageBytes(inline_only));
    try std.testing.expectEqual(navStorageBytes(base), navStorageBytes(past_all));
}
