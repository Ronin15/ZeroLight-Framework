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
const PerfBatchStage = @import("../app/runtime_perf_log.zig").BatchStage;
const PerfMetric = @import("../app/runtime_perf_log.zig").Metric;
const PerfTiming = @import("../app/runtime_perf_log.zig").Timing;
const NavMainPhases = @import("../game/systems/pathfinding/types.zig").NavMainPhases;
const NavUpdateStats = @import("../game/systems/pathfinding/types.zig").NavUpdateStats;

pub const default_items_per_range = (ThreadSystemConfig{}).items_per_range;
/// The fixed partition of a chunk-partitioned stage: one chunk per range.
pub const chunk_partition_items: usize = 1;

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
    /// What one item count names: the unit counted, or an item code's layout
    /// (`ItemCode(...).label`).
    item_label: []const u8,
    defaultItemCounts: *const fn (Profile) []const usize,
    runCase: *const fn (std.mem.Allocator, std.Io, Options, BenchmarkCase, usize) anyerror!RunStats,
    /// Writes a case's workload: its counters in the group's own terms, and under
    /// `--details` its stage shapes too. Writing nothing prints no workload.
    write_workload: WorkloadWriter,
    /// The case the summary leads with.
    summary_focus: SummaryFocus = .fastest,
    /// Set only when every fixed-control stage of the group resolves its range from this
    /// one shape. A fixed case that resolves to an earlier case's configuration is then
    /// reported as that case's duplicate and not timed again; null keeps every case timed.
    /// Requires the default case list.
    fixed_range_shape: ?FixedRangeShape = null,
    /// The cases the group's workload runs (`casesNamed`), in default-case order and
    /// holding `serial-direct`; a case the workload has no path for is left out, never
    /// skipped.
    cases: []const BenchmarkCase = &default_cases,
};

/// The partition a group's fixed stages scale their range modes from, and the alignment
/// they share.
pub const FixedRangeShape = struct {
    partition_items: usize,
    range_alignment_items: usize,
};

/// Where a workload is printed: the one-line summary or the `--details` table.
pub const WorkloadView = enum { summary, details };

pub const WorkloadWriter = *const fn (*std.Io.Writer, RunStats, WorkloadView) std.Io.Writer.Error!void;

pub const SummaryFocus = enum {
    // The fastest measured case.
    fastest,
    // The production tuner's case, beside the fastest control.
    production_adaptive,
};

/// A group with no workload counters.
pub fn writeNoWorkload(_: *std.Io.Writer, _: RunStats, _: WorkloadView) std.Io.Writer.Error!void {}

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

    /// The range size a fixed control runs: this case's range mode, or the default size
    /// aligned to the stage's range alignment.
    pub fn fixedItemsPerRange(self: BenchmarkCase, range_alignment_items: usize) usize {
        return self.fixedItemsPerRangeForPartition(default_items_per_range, range_alignment_items);
    }

    /// A stage's `items_per_range` control: null for adaptive cases so the stage's tuner
    /// picks the range, otherwise `fixedItemsPerRange`.
    pub fn stageItemsPerRange(self: BenchmarkCase, range_alignment_items: usize) ?usize {
        return self.stageItemsPerRangeForPartition(default_items_per_range, range_alignment_items);
    }

    /// `stageItemsPerRange` for a group whose fixed partition is `partition_items` (one
    /// chunk for chunk-partitioned stages) instead of the element default: the range modes
    /// scale from that partition.
    pub fn stageItemsPerRangeForPartition(self: BenchmarkCase, partition_items: usize, range_alignment_items: usize) ?usize {
        if (self.adaptive) return null;
        return self.fixedItemsPerRangeForPartition(partition_items, range_alignment_items);
    }

    fn fixedItemsPerRangeForPartition(self: BenchmarkCase, partition_items: usize, range_alignment_items: usize) usize {
        return self.itemsPerRangeForPartition(partition_items, range_alignment_items) orelse
            std.mem.alignForwardAnyAlign(usize, partition_items, range_alignment_items);
    }

    // Null in the default range mode; small halves the partition and large quadruples it.
    fn itemsPerRangeForPartition(self: BenchmarkCase, partition_items: usize, range_alignment_items: usize) ?usize {
        return switch (self.range_mode) {
            .default => null,
            .small => std.mem.alignForwardAnyAlign(usize, @max(partition_items / 2, @as(usize, 1)), range_alignment_items),
            .large => std.mem.alignForwardAnyAlign(usize, partition_items * 4, range_alignment_items),
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

/// The default cases named by `names`, in default-case order; a name that is no default
/// case fails the build.
pub fn casesNamed(comptime names: []const []const u8) [names.len]BenchmarkCase {
    return comptime blk: {
        var cases: [names.len]BenchmarkCase = undefined;
        var count: usize = 0;
        for (default_cases) |case| {
            for (names) |name| {
                if (std.mem.eql(u8, name, case.name)) {
                    cases[count] = case;
                    count += 1;
                }
            }
        }
        if (count != names.len) @compileError("a case name names no default case, or repeats");
        break :blk cases;
    };
}

/// The serial case alone: a workload with only a main-thread path.
pub const serial_cases = casesNamed(&.{"serial-direct"});
/// The serial case and the production tuner's case: a workload whose stages run their own
/// tuners, with no fixed-control path of its own.
pub const serial_and_tuned_cases = casesNamed(&.{ "serial-direct", "thread-adaptive-tuned-range" });

pub const RunStatus = enum {
    measured,
    skipped,
    // Resolves to an earlier case's configuration under the group's `fixed_range_shape`;
    // not timed.
    duplicate,
};

// Per default case, the status text of a later case that duplicates it.
const same_shape_notes = blk: {
    var notes: [default_cases.len][]const u8 = undefined;
    for (default_cases, &notes) |case, *note| note.* = "same shape as " ++ case.name;
    break :blk notes;
};

pub const RunStats = struct {
    // Plain scalar result surface shared by every benchmark group; each group's
    // `write_workload` names what its counters hold.
    status: RunStatus = .measured,
    skip_reason: []const u8 = "",
    duplicate_note: []const u8 = "",
    item_count: usize = 0,
    candidate_pairs: usize = 0,
    sample_count: usize = 0,
    output_count: usize = 0,
    deferred_count: usize = 0,
    fallback_deferred_count: usize = 0,
    cache_evictions: usize = 0,
    // Neighbor-block fills of a group whose queries share `NeighborBlock`s, and of its second
    // query kind when it has two.
    neighbor_block_fills: usize = 0,
    secondary_neighbor_block_fills: usize = 0,
    iterations: usize = 0,
    mean_ns: u64 = 0,
    min_ns: u64 = 0,
    max_ns: u64 = 0,
    items_per_second: u64 = 0,
    batch: BatchSummary = .{},
    /// False when a sample spans many stages and `batch` holds none of them: the worker
    /// and range cells print `-` and the summary names no worker use.
    batch_carried: bool = true,
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
    /// Mean main-thread time per iteration: wall time minus the dispatch time of the
    /// stages that ran on workers.
    main_ns: ?u64 = null,
    collision_phases: ?CollisionPhaseSummary = null,
    render_capacities: ?RenderCapacitySummary = null,
    production_step: ?ProductionStepSummary = null,
    world_create: ?WorldCreateSummary = null,

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
/// root-groups, components split off, and roots merged, the flood's summed dispatch time and
/// its share on workers, the flood tuner's policy after the case (null when the case runs no
/// adaptive tuner; zero workers is inline), the chunks and records patched, and a toggle's
/// reopen flood nodes (null without a reopen). Then the one-way
/// closure's stage shapes (candidates, resolve, mask, plan, rows with round 0 and its rounds
/// folded, landing) and counters: components touched, links resolved, terminals new and left,
/// rows recomputed, rounds, words written, blocks narrowed, blocks allocated and freed, words
/// landed, landings deferred, the live block words, the batch tail's capacity, and the rows
/// stage's time on workers; and the
/// reserve of its busiest batch: the tail words its bound reserved and its blocks took, its
/// candidates' block words, and the terminals it could number.
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
    groups: usize = 0,
    splits: usize = 0,
    merges: usize = 0,
    flood_off_main_ns: u64 = 0,
    flood_tuner_workers: ?usize = null,
    chunks_patched: usize = 0,
    records_patched: usize = 0,
    reopen_flood_nodes: ?usize = null,
    candidates: BatchSummary = .{},
    closure_resolve: BatchSummary = .{},
    closure_mask: BatchSummary = .{},
    closure_plan: BatchSummary = .{},
    closure_rows: BatchSummary = .{},
    closure_land: BatchSummary = .{},
    closure_touched: usize = 0,
    closure_links: usize = 0,
    closure_terms_new: usize = 0,
    closure_terms_left: usize = 0,
    closure_a_rows: usize = 0,
    closure_rounds: usize = 0,
    closure_words_written: usize = 0,
    closure_shrinks: usize = 0,
    closure_block_allocs: usize = 0,
    closure_block_frees: usize = 0,
    closure_landed_words: usize = 0,
    closure_land_deferrals: usize = 0,
    closure_live_words: usize = 0,
    closure_tail_capacity: usize = 0,
    closure_rows_off_main_ns: u64 = 0,
    closure_tail_bound: usize = 0,
    closure_tail_used: usize = 0,
    closure_candidate_words: usize = 0,
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

/// Mean per-iteration time of collision's main-thread gather and sort, ahead of the
/// broadphase batch.
pub const CollisionPhaseSummary = struct {
    gather_ns: u64 = 0,
    sort_ns: u64 = 0,
};

/// Render-prep capacities after a collect: the dynamic record reserve and the sprite
/// command reserve the scene asks for.
pub const RenderCapacitySummary = struct {
    record_capacity: usize = 0,
    command_capacity: usize = 0,
};

/// One production fixed step's census, means per measured step. `main_ns` is the step's
/// wall time minus the off-main time of every perf-log batch stage that ran on workers: an
/// upper bound, since batches the log does not carry count as main. `untimed_ns` is the
/// wall time no top-level stage timer holds. Stage wall times are every perf-log timer the
/// step records, nested ones included; batch off-main time counts a step only when every
/// call of the stage that step ran on workers. `shared_tuner` is the thread system's
/// shared tuner after the run.
pub const ProductionStepSummary = struct {
    population: usize = 0,
    measured_steps: usize = 0,
    main_ns: u64 = 0,
    untimed_ns: u64 = 0,
    stage_wall_ns: std.enums.EnumArray(PerfTiming, u64) = .initFill(0),
    batch_off_main_ns: std.enums.EnumArray(PerfBatchStage, u64) = .initFill(0),
    batch_threaded_steps: std.enums.EnumArray(PerfBatchStage, usize) = .initFill(0),
    batch_recorded_steps: std.enums.EnumArray(PerfBatchStage, usize) = .initFill(0),
    metrics: std.enums.EnumArray(PerfMetric, u64) = .initFill(0),
    shared_tuner: AdaptiveWorkReport = .{},
};

/// One world's create and destroy: each phase's mean time, the live bytes after each
/// create phase, and the live bytes left after destroy (from one counted pass).
pub const WorldCreateSummary = struct {
    surface_ns: u64 = 0,
    stack_ns: u64 = 0,
    nav_ns: u64 = 0,
    destroy_ns: u64 = 0,
    surface_bytes: usize = 0,
    stack_bytes: usize = 0,
    nav_bytes: usize = 0,
    destroyed_bytes: usize = 0,
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
            std.math.lossyCast(u64, (total_items * std.time.ns_per_s) / self.total_ns);

        return .{
            .item_count = self.item_count,
            .iterations = self.iterations,
            .mean_ns = std.math.lossyCast(u64, self.total_ns / iteration_count),
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
                .main_thread_ranges = std.math.lossyCast(usize, self.total_main_thread_ranges / iteration_count),
                .worker_thread_ranges = std.math.lossyCast(usize, self.total_worker_thread_ranges / iteration_count),
                .worker_utilization_percent = @intFromFloat((self.total_worker_utilization / @as(f64, @floatFromInt(self.iterations))) * 100.0),
                .batch_duration_ns = std.math.lossyCast(u64, self.total_batch_duration_ns / iteration_count),
                .main_thread_wait_ns = std.math.lossyCast(u64, self.total_main_thread_wait_ns / iteration_count),
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
    return adaptiveTunerForPartition(case, default_items_per_range, range_alignment_items);
}

/// `adaptiveTunerForCase` for a group whose fixed partition is `partition_items`: the
/// fixed-adaptive case clamps its range to that partition, aligned.
pub fn adaptiveTunerForPartition(case: BenchmarkCase, partition_items: usize, range_alignment_items: usize) ?AdaptiveWorkTuner {
    // Fixed-adaptive cases reuse tuner reporting but clamp range probing so they
    // can act as a stable control against fully adaptive policy.
    if (!case.adaptive) return null;
    return switch (case.adaptive_range_mode) {
        .none, .tuned => null,
        .fixed => fixed: {
            const fixed_range = std.mem.alignForwardAnyAlign(usize, partition_items, range_alignment_items);
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

            std.debug.assert(group.fixed_range_shape == null or group.cases.len == default_cases.len);
            for (group.cases, 0..) |case, case_index| {
                if (options.case_filter) |filter| {
                    if (!std.mem.eql(u8, filter, case.name) and !shouldIncludeBaselineForFilter(filter, case)) continue;
                }
                const duplicate_of = if (group.fixed_range_shape) |shape| sameShapeCaseIndex(shape, case_index) else null;
                const stats: RunStats = if (duplicate_of) |earlier|
                    .{ .status = .duplicate, .duplicate_note = same_shape_notes[earlier] }
                else
                    try group.runCase(allocator, io, options, case, item_count);
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

// The earliest default case that `default_cases[case_index]` runs the same configuration as
// under `shape`: the same fixed (non-adaptive) threaded worker mode and the same resolved range.
fn sameShapeCaseIndex(shape: FixedRangeShape, case_index: usize) ?usize {
    const case = default_cases[case_index];
    if (case.adaptive or !case.usesThreadSystem()) return null;
    const range = case.fixedItemsPerRangeForPartition(shape.partition_items, shape.range_alignment_items);
    for (default_cases[0..case_index], 0..) |earlier, earlier_index| {
        if (earlier.adaptive or earlier.worker_mode != case.worker_mode) continue;
        if (earlier.fixedItemsPerRangeForPartition(shape.partition_items, shape.range_alignment_items) == range) return earlier_index;
    }
    return null;
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
        \\  --profile quick|standard|stress   (count groups; item-code groups run fixed configs)
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

pub fn nowNs(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).toNanoseconds();
}

pub fn elapsedNs(start_ns: i96, end_ns: i96) u64 {
    return if (end_ns > start_ns) @intCast(end_ns - start_ns) else 0;
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
        if (options.details) printDetailTable(group, results);
        return;
    };
    if (baseline.stats.status == .skipped) {
        std.debug.print("\n{s}\n", .{group.name});
        std.debug.print("  serial baseline skipped: {s}\n", .{baseline.stats.skip_reason});
        if (options.details) printDetailTable(group, results);
        return;
    }

    std.debug.print("\n{s}  {} {s}\n\n", .{ group.name, baseline.stats.item_count, group.item_label });
    const best = bestMeasured(results) orelse baseline;
    const fixed_auto = measured(findResult(results, "thread-fixed-auto"));
    const adaptive = measured(findResult(results, "thread-adaptive-tuned-range")) orelse measured(findResult(results, "thread-adaptive-fixed-range"));

    printCompactTable(results, baseline);
    if (options.details) {
        std.debug.print("\n", .{});
        printDetailTable(group, results);
    } else {
        std.debug.print("\ndetails: pass --details for scheduler, range, and workload columns\n", .{});
    }
    printValidationSummary(group, baseline, best, fixed_auto, adaptive, results);
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

        const unmeasured = @tagName(result.stats.status);
        const mean = if (result.stats.status == .measured) formatDurationInto(&mean_buffer, result.stats.mean_ns) else unmeasured;
        const speedup = if (result.stats.status == .measured) formatSpeedupInto(&speedup_buffer, speedupBasisPoints(baseline.stats, result.stats)) else unmeasured;
        const throughput = if (result.stats.status == .measured) formatThroughputInto(&throughput_buffer, result.stats.items_per_second) else unmeasured;
        const workers = if (result.stats.status == .measured) formatWorkerThreadsInto(&worker_buffer, result.stats) else "-";

        printCell(result.case.name, 30);
        printCell(mean, 11);
        printCell(speedup, 10);
        printCell(throughput, 13);
        printCell(workers, 14);
        std.debug.print("{s}\n", .{statusText(result.stats)});
    }
}

fn printDetailTable(group: BenchmarkGroup, results: []const CaseResult) void {
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
        if (result.stats.status != .measured) {
            printCell(result.case.name, 30);
            printCell(@tagName(result.stats.status), 11);
            printCell(@tagName(result.stats.status), 11);
            printCell("-", 12);
            printCell("-", 14);
            printCell("-", 11);
            printCell("-", 16);
            printCell("-", 72);
            std.debug.print("{s}\n", .{statusText(result.stats)});
            continue;
        }

        var min_buffer: [32]u8 = undefined;
        var max_buffer: [32]u8 = undefined;
        var wait_buffer: [32]u8 = undefined;
        var main_ranges_buffer: [24]u8 = undefined;
        var worker_ranges_buffer: [24]u8 = undefined;
        var items_per_range_buffer: [24]u8 = undefined;
        var tuning_buffer: [96]u8 = undefined;
        var workload_buffer: [8192]u8 = undefined;

        const batch = result.stats.batch;
        const carried = result.stats.batch_carried;
        printCell(result.case.name, 30);
        printCell(formatDurationInto(&min_buffer, result.stats.min_ns), 11);
        printCell(formatDurationInto(&max_buffer, result.stats.max_ns), 11);
        printCell(if (carried) formatRangeCellInto(&main_ranges_buffer, batch, batch.main_thread_ranges) else "-", 12);
        printCell(if (carried) formatRangeCellInto(&worker_ranges_buffer, batch, batch.worker_thread_ranges) else "-", 14);
        printCell(if (carried) formatDurationInto(&wait_buffer, batch.main_thread_wait_ns) else "-", 11);
        printCell(if (carried) formatRangeCellInto(&items_per_range_buffer, batch, batch.items_per_range) else "-", 16);
        printCell(formatWorkTuningInto(&tuning_buffer, result.stats.work_tuning), 72);
        const workload = formatWorkloadInto(&workload_buffer, group, result.stats, .details);
        std.debug.print("{s}\n", .{if (workload.len == 0) "-" else workload});
    }
}

// `group`'s workload text for `stats`; empty when it writes none.
fn formatWorkloadInto(buffer: []u8, group: BenchmarkGroup, stats: RunStats, view: WorkloadView) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    group.write_workload(&writer, stats, view) catch return "workload";
    return writer.buffered();
}

fn printValidationSummary(
    group: BenchmarkGroup,
    baseline: CaseResult,
    best: CaseResult,
    fixed_auto: ?CaseResult,
    adaptive: ?CaseResult,
    results: []const CaseResult,
) void {
    // Keep the summary terse and action-oriented: it should call out unusual
    // scheduler behavior or workload counters without pretending to choose
    // runtime tuning policy from one benchmark run.
    const focus = switch (group.summary_focus) {
        .fastest => best,
        .production_adaptive => adaptive orelse best,
    };
    const focus_label = if (group.summary_focus == .production_adaptive and adaptive != null) "production_adaptive" else "best";
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
        // A sample that carries no batch has no one stage to name worker use from.
        if (adaptive_result.stats.batch_carried) {
            const batch = adaptive_result.stats.batch;
            if (batch.active_worker_threads == 0) {
                std.debug.print("adaptive stayed inline with {}/{} worker_threads. ", .{ batch.active_worker_threads, batch.available_worker_threads });
            } else {
                std.debug.print("adaptive used {}/{} worker_threads. ", .{ batch.active_worker_threads, batch.available_worker_threads });
            }
        }
    } else {
        std.debug.print("adaptive flow not selected in this run. ", .{});
    }

    var workload_buffer: [1024]u8 = undefined;
    const workload = formatWorkloadInto(&workload_buffer, group, focus.stats, .summary);
    if (workload.len != 0) std.debug.print("workload {s}. ", .{workload});

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
    var duplicate_count: usize = 0;
    for (results) |result| {
        switch (result.stats.status) {
            .measured => measured_count += 1,
            .skipped => skipped_count += 1,
            .duplicate => duplicate_count += 1,
        }
    }
    std.debug.print("flow coverage {}/{} measured", .{ measured_count, results.len });
    if (skipped_count != 0) {
        std.debug.print(", {} skipped", .{skipped_count});
    }
    if (duplicate_count != 0) {
        std.debug.print(", {} duplicate", .{duplicate_count});
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
        .duplicate => stats.duplicate_note,
    };
}

fn formatDurationInto(buffer: []u8, ns: u64) []const u8 {
    return std.mem.print(buffer, "{f}", .{formatDuration(ns)}) catch "duration";
}

fn formatSpeedupInto(buffer: []u8, basis_points: u64) []const u8 {
    return std.mem.print(buffer, "{d}.{d:0>2}x", .{ basis_points / 100, basis_points % 100 }) catch "speedup";
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
        return std.mem.print(buffer, "{}{s}", .{ items_per_second, unit.suffix }) catch "throughput";
    }

    const whole = items_per_second / unit.scale;
    const fraction = (items_per_second % unit.scale) / (unit.scale / 100);
    return std.mem.print(buffer, "{}.{d:0>2}{s}", .{ whole, fraction, unit.suffix }) catch "throughput";
}

fn formatWorkerThreadsInto(buffer: []u8, stats: RunStats) []const u8 {
    if (!stats.batch_carried) return "-";
    return std.mem.print(buffer, "{}/{}", .{ stats.batch.active_worker_threads, stats.batch.available_worker_threads }) catch "workers";
}

// A range column of `batch`: `inline` when it ran inline (no range split), else `value`.
fn formatRangeCellInto(buffer: []u8, batch: BatchSummary, value: usize) []const u8 {
    if (batch.ran_inline or batch.active_worker_threads == 0) return "inline";
    return formatUsizeInto(buffer, value);
}

fn formatUsizeInto(buffer: []u8, value: usize) []const u8 {
    return std.mem.print(buffer, "{}", .{value}) catch "value";
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

/// ` <label>=<time> (<percent>%)`: `part_ns` beside its share of `mean_ns`.
pub fn writeShare(writer: *std.Io.Writer, label: []const u8, part_ns: u64, mean_ns: u64) std.Io.Writer.Error!void {
    const percent = if (mean_ns == 0) 0 else part_ns * 100 / mean_ns;
    try writer.print(" {s}={f} ({}%)", .{ label, formatDuration(part_ns), percent });
}

/// The main thread's share of the mean (`main_ns`, when set) and its time per one of `items`.
pub fn writeMainShare(writer: *std.Io.Writer, stats: RunStats, items: usize) std.Io.Writer.Error!void {
    const main_ns = stats.main_ns orelse return;
    try writeShare(writer, "main", main_ns, stats.mean_ns);
    try writer.print(" main_per_item={f}", .{formatDuration(main_ns / @max(items, 1))});
}

/// A stage's batch shape: `inline`, or active workers and ranges.
pub fn writeStageShape(writer: *std.Io.Writer, batch: BatchSummary) std.Io.Writer.Error!void {
    if (batch.ran_inline or batch.active_worker_threads == 0) return writer.writeAll("inline");
    try writer.print("{}w/{}r", .{ batch.active_worker_threads, batch.range_count });
}

// `writeStageShape`, or `-` for a stage that covered no items.
fn writeRunStageShape(writer: *std.Io.Writer, batch: BatchSummary) std.Io.Writer.Error!void {
    if (batch.item_count == 0) return writer.writeByte('-');
    try writeStageShape(writer, batch);
}

/// A nav reaction's stage shapes: `mark=` (when the workload marks events), `plan=`, then
/// `remask=` (the primary batch) and `patch=` (the secondary batch), then the connectivity
/// block and main-thread split when the group reports them.
pub fn writeNavStages(writer: *std.Io.Writer, stats: RunStats) std.Io.Writer.Error!void {
    if (stats.nav_mark_batch) |mark| {
        try writer.writeAll("mark=");
        try writeStageShape(writer, mark);
        try writer.writeByte(' ');
    }
    try writer.writeAll("plan=");
    try writeStageShape(writer, stats.nav_plan_batch orelse .{});
    try writer.writeAll(" remask=");
    try writeStageShape(writer, stats.batch);
    try writer.writeAll(" patch=");
    try writeStageShape(writer, stats.secondary_batch orelse .{});
    try writeNavConn(writer, stats.nav_conn);
    try writeNavMain(writer, stats.nav_main);
}

/// The ` main_split=` block of a nav reaction's main-thread sections, inline stage time, and
/// rest, per sample, or nothing.
pub fn writeNavMain(writer: *std.Io.Writer, summary: ?NavMainSummary) std.Io.Writer.Error!void {
    const main = summary orelse return;
    if (main.samples == 0) return;
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

/// `writeNavMain` into `buffer`, for a report line.
pub fn formatNavMainInto(buffer: []u8, summary: ?NavMainSummary) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    writeNavMain(&writer, summary) catch return " main_split";
    return writer.buffered();
}

// The connectivity block of a nav reaction, its one-way closure block when the reaction ran
// a closure stage, or nothing.
fn writeNavConn(writer: *std.Io.Writer, summary: ?NavConnSummary) std.Io.Writer.Error!void {
    const conn = summary orelse return;
    try writer.writeAll(" conn_seed=");
    try writeRunStageShape(writer, conn.seed);
    try writer.writeAll(" conn_gather=");
    try writeRunStageShape(writer, conn.gather);
    try writer.writeAll(" conn_flood=");
    try writeRunStageShape(writer, conn.flood);
    try writer.print(" families={} rounds={} round_items={}-{} build_visits={} flood_nodes={} groups={} splits={} merges={} flood_dispatch={f} flood_off_main={f} flood_tuner=", .{
        conn.families,
        conn.rounds,
        conn.round_items_min,
        conn.round_items_max,
        conn.build_visits,
        conn.flood_nodes,
        conn.groups,
        conn.splits,
        conn.merges,
        formatDuration(conn.flood.batch_duration_ns),
        formatDuration(conn.flood_off_main_ns),
    });
    if (conn.flood_tuner_workers) |workers| {
        if (workers == 0) try writer.writeAll("inline") else try writer.print("{}w", .{workers});
    } else try writer.writeByte('-');
    try writer.print(" chunks_patched={} records_patched={}", .{ conn.chunks_patched, conn.records_patched });
    if (conn.reopen_flood_nodes) |nodes| try writer.print(" reopen_flood_nodes={}", .{nodes});
    if (conn.candidates.item_count == 0 and conn.closure_links == 0 and conn.closure_land.item_count == 0) return;
    const stages = [_]struct { []const u8, BatchSummary }{
        .{ " conn_candidates=", conn.candidates },
        .{ " closure_resolve=", conn.closure_resolve },
        .{ " closure_mask=", conn.closure_mask },
        .{ " closure_plan=", conn.closure_plan },
        .{ " closure_rows=", conn.closure_rows },
        .{ " closure_land=", conn.closure_land },
    };
    for (stages) |stage| {
        try writer.writeAll(stage[0]);
        try writeRunStageShape(writer, stage[1]);
    }
    try writer.print(" touched={} links={} terms_new={} terms_left={} a_rows={} closure_rounds={} words_written={} shrinks={} block_allocs={} block_frees={} landed_words={} land_deferrals={} live_words={} tail_capacity={} closure_rows_off_main={f} tail_bound={} tail_used={} cand_words={} kb={} reserve_ratio={d:.2}", .{
        conn.closure_touched,
        conn.closure_links,
        conn.closure_terms_new,
        conn.closure_terms_left,
        conn.closure_a_rows,
        conn.closure_rounds,
        conn.closure_words_written,
        conn.closure_shrinks,
        conn.closure_block_allocs,
        conn.closure_block_frees,
        conn.closure_landed_words,
        conn.closure_land_deferrals,
        conn.closure_live_words,
        conn.closure_tail_capacity,
        formatDuration(conn.closure_rows_off_main_ns),
        conn.closure_tail_bound,
        conn.closure_tail_used,
        conn.closure_candidate_words,
        conn.closure_kb,
        // The tail bound over the candidates' block words.
        if (conn.closure_candidate_words == 0) 0.0 else @as(f64, @floatFromInt(conn.closure_tail_bound)) / @as(f64, @floatFromInt(conn.closure_candidate_words)),
    });
}

/// One nav reaction's connectivity and closure summary from its stats, with the flood
/// tuner's workers when the case runs it adaptive (null otherwise; zero is inline).
pub fn navConnSummary(stats: NavUpdateStats, flood_tuner_workers: ?usize) NavConnSummary {
    return .{
        .seed = batchSummaryFromBatch(stats.conn_seed_batch),
        .gather = batchSummaryFromBatch(stats.conn_gather_batch),
        .flood = batchSummaryFromBatch(stats.conn_flood_batch),
        .families = stats.conn_families,
        .rounds = stats.conn_rounds,
        .round_items_min = stats.conn_round_items_min,
        .round_items_max = stats.conn_round_items_max,
        .build_visits = stats.conn_build_visits,
        .flood_nodes = stats.conn_flood_nodes,
        .groups = stats.conn_groups,
        .splits = stats.conn_splits,
        .merges = stats.conn_merges,
        .flood_off_main_ns = stats.conn_flood_off_main_ns,
        .flood_tuner_workers = flood_tuner_workers,
        .chunks_patched = stats.chunks_patched,
        .records_patched = stats.records_patched,
        .candidates = batchSummaryFromBatch(stats.conn_closure_candidates_batch),
        .closure_resolve = batchSummaryFromBatch(stats.conn_closure_resolve_batch),
        .closure_mask = batchSummaryFromBatch(stats.conn_closure_mask_batch),
        .closure_plan = batchSummaryFromBatch(stats.conn_closure_plan_batch),
        .closure_rows = batchSummaryFromBatch(stats.conn_closure_rows_batch),
        .closure_land = batchSummaryFromBatch(stats.conn_closure_land_batch),
        .closure_touched = stats.closure_touched,
        .closure_links = stats.closure_links,
        .closure_terms_new = stats.closure_terms_new,
        .closure_terms_left = stats.closure_terms_left,
        .closure_a_rows = stats.closure_a_rows,
        .closure_rounds = stats.closure_rounds,
        .closure_words_written = stats.closure_words_written,
        .closure_shrinks = stats.closure_shrinks,
        .closure_block_allocs = stats.closure_block_allocs,
        .closure_block_frees = stats.closure_block_frees,
        .closure_landed_words = stats.closure_landed_words,
        .closure_land_deferrals = stats.closure_land_deferrals,
        .closure_live_words = stats.closure_live_words,
        .closure_tail_capacity = stats.closure_tail_capacity,
        .closure_rows_off_main_ns = if (stats.conn_closure_rows_batch.ran_inline) 0 else stats.conn_closure_rows_batch.batch_duration_ns,
        .closure_tail_bound = stats.closure_tail_bound,
        .closure_tail_used = stats.closure_tail_used,
        .closure_candidate_words = stats.closure_candidate_words,
        .closure_kb = stats.closure_kb,
    };
}

/// Steering's prepare stage shapes, in stage order; `-` for a stage that did not run (the
/// claim and the grid sort on the serial path).
pub fn writeSteeringStages(writer: *std.Io.Writer, stats: RunStats) std.Io.Writer.Error!void {
    const stages = stats.steering_stages orelse SteeringStageSummary{};
    const shapes = [_]struct { []const u8, BatchSummary }{
        .{ "agents=", stages.agents },
        .{ " resolve=", stages.select_resolve },
        .{ " claim=", stages.select_claim },
        .{ " dir=", stages.directions },
        .{ " bucket=", stages.grid_bucket },
        .{ " sort=", stages.grid_sort },
    };
    for (shapes) |shape| {
        try writer.writeAll(shape[0]);
        try writeRunStageShape(writer, shape[1]);
    }
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
    return std.math.lossyCast(u64, (@as(u128, baseline.mean_ns) * 100) / candidate.mean_ns);
}

fn percentDelta(candidate_ns: u64, baseline_ns: u64) i64 {
    if (baseline_ns == 0) return 0;
    const candidate: i128 = candidate_ns;
    const baseline_value: i128 = baseline_ns;
    return @intCast(@divTrunc((candidate - baseline_value) * 100, baseline_value));
}

/// `ns` printed with `{f}` as ns, us, or ms.
pub fn formatDuration(ns: u64) Duration {
    return .{ .ns = ns };
}

pub const Duration = struct {
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

/// The smallest grid side, at least 1, whose square holds `count` cells.
pub fn ceilSqrt(count: usize) usize {
    const floor_side: usize = std.math.sqrt(count);
    return @max(if (floor_side * floor_side < count) floor_side + 1 else floor_side, 1);
}

/// Items per second over one mean duration, for a group whose throughput numerator is not
/// its item count (items serviced, cells written, an item code).
pub fn itemsPerSecond(items: usize, mean_ns: u64) u64 {
    if (mean_ns == 0) return 0;
    return std.math.lossyCast(u64, (@as(u128, items) * std.time.ns_per_s) / mean_ns);
}

/// Per stage of `n`, the busiest batch over the samples added (most items; on a tie, one
/// that ran on workers), and how many non-empty batches ran on workers.
pub fn StageShapes(comptime n: usize) type {
    return struct {
        const Self = @This();

        busiest: [n]BatchStats = @splat(.{}),
        threaded: [n]usize = @splat(0),
        dispatched: [n]usize = @splat(0),

        pub fn add(self: *Self, batches: [n]BatchStats) void {
            for (batches, &self.busiest, &self.threaded, &self.dispatched) |batch, *busiest, *threaded, *dispatched| {
                if (batch.item_count == 0) continue;
                dispatched.* += 1;
                const on_workers = !batch.ran_inline and batch.active_worker_threads != 0;
                if (on_workers) threaded.* += 1;
                const busiest_on_workers = !busiest.ran_inline and busiest.active_worker_threads != 0;
                if (batch.item_count > busiest.item_count or (batch.item_count == busiest.item_count and on_workers and !busiest_on_workers)) busiest.* = batch;
            }
        }

        /// Stage `index`'s shape: `inline(items)` or `Ww/Rr(items)`, then threaded/non-empty
        /// batches.
        pub fn label(self: *const Self, index: usize, buffer: []u8) []const u8 {
            const batch = self.busiest[index];
            if (batch.ran_inline or batch.active_worker_threads == 0) {
                return std.mem.print(buffer, "inline({})[{}/{}]", .{ batch.item_count, self.threaded[index], self.dispatched[index] }) catch "inline";
            }
            return std.mem.print(buffer, "{}w/{}r({})[{}/{}]", .{ batch.active_worker_threads, batch.range_count, batch.item_count, self.threaded[index], self.dispatched[index] }) catch "stage";
        }
    };
}

/// One field of an `ItemCode`: unsigned ints, bools, and enums with an int backing.
fn itemFieldValue(value: anytype) usize {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => @intFromBool(value),
        .@"enum" => @backingInt(value),
        else => value,
    };
}

fn itemFieldFrom(comptime T: type, raw: usize) ?T {
    return switch (@typeInfo(T)) {
        .bool => if (raw > 1) null else raw == 1,
        .@"enum" => std.enums.fromInt(T, raw),
        else => std.math.cast(T, raw),
    };
}

fn powerOfTen(comptime exponent: usize) usize {
    return comptime std.math.powi(usize, 10, exponent) catch @compileError("item code wider than a usize");
}

/// A bench item code: the fields of `Fields` packed in decimal, most significant first, each
/// field after the first `digits[i - 1]` digits wide (the first takes the rest), so every
/// config of a group has one code. `label` names the layout for the report header.
pub fn ItemCode(comptime Fields: type, comptime digits: []const usize) type {
    const names = @typeInfo(Fields).@"struct".field_names;
    const field_types = @typeInfo(Fields).@"struct".field_types;
    comptime std.debug.assert(digits.len + 1 == names.len);
    return struct {
        pub const label: []const u8 = blk: {
            @setEvalBranchQuota(10_000);
            var text: []const u8 = "(";
            for (names, 0..) |name, index| {
                var exponent: usize = 0;
                for (digits[index..]) |width| exponent += width;
                var words: [name.len]u8 = name[0..name.len].*;
                std.mem.replaceScalar(u8, &words, '_', ' ');
                const scale: []const u8 = switch (exponent) {
                    0 => "",
                    1, 2, 3 => std.fmt.comptimePrint(" * {}", .{powerOfTen(exponent)}),
                    else => std.fmt.comptimePrint(" * 10^{}", .{exponent}),
                };
                text = text ++ (if (index == 0) "" else " + ") ++ words ++ scale;
            }
            break :blk text ++ ")";
        };

        /// Fails when a field after the first is past its digits.
        pub fn encode(fields: Fields) error{ItemCodeFieldTooWide}!usize {
            var code: usize = 0;
            inline for (names, 0..) |name, index| {
                const raw = itemFieldValue(@field(fields, name));
                if (index == 0) {
                    code = raw;
                } else {
                    const scale = comptime powerOfTen(digits[index - 1]);
                    if (raw >= scale) return error.ItemCodeFieldTooWide;
                    code = code * scale + raw;
                }
            }
            return code;
        }

        /// `encode` at comptime, for a group's config list.
        pub fn of(comptime fields: Fields) usize {
            @setEvalBranchQuota(100_000);
            return comptime encode(fields) catch @compileError("item code field past its digits");
        }

        /// Fails when a field does not fit its type (or names no tag of its enum).
        pub fn decode(code: usize) error{ItemCodeFieldOutOfRange}!Fields {
            var fields: Fields = undefined;
            var rest = code;
            comptime var index = names.len;
            inline while (index > 0) {
                index -= 1;
                const raw = if (index == 0) rest else rest % comptime powerOfTen(digits[index - 1]);
                if (index != 0) rest /= comptime powerOfTen(digits[index - 1]);
                @field(fields, names[index]) = itemFieldFrom(field_types[index], raw) orelse return error.ItemCodeFieldOutOfRange;
            }
            return fields;
        }
    };
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

test "a group's named cases keep default-case order, and the default list is every case" {
    const named = casesNamed(&.{ "thread-adaptive-tuned-range", "serial-direct" });
    try std.testing.expectEqual(@as(usize, 2), named.len);
    try std.testing.expectEqualStrings("serial-direct", named[0].name);
    try std.testing.expectEqualStrings("thread-adaptive-tuned-range", named[1].name);
    try std.testing.expect(named[1].adaptive);
    const group = BenchmarkGroup{ .name = "test", .item_label = "items", .defaultItemCounts = testItemCounts, .runCase = testRunCase, .write_workload = writeNoWorkload };
    try std.testing.expectEqual(default_cases.len, group.cases.len);
}

test "a grid side covers its count with the fewest cells" {
    const cases = [_][2]usize{ .{ 0, 1 }, .{ 1, 1 }, .{ 2, 2 }, .{ 4, 2 }, .{ 5, 3 }, .{ 16_384, 128 }, .{ 16_385, 129 } };
    for (cases) |case| try std.testing.expectEqual(case[1], ceilSqrt(case[0]));
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

test "benchmark fixed and stage range sizes align the range and null out adaptive cases" {
    const cases = struct {
        fn named(name: []const u8) BenchmarkCase {
            for (default_cases) |case| {
                if (std.mem.eql(u8, case.name, name)) return case;
            }
            std.debug.panic("no default benchmark case named {s}", .{name});
        }
    };
    // An alignment above the default size moves the default up to it.
    const wide_alignment = default_items_per_range + 1;

    const fixed_auto = cases.named("thread-fixed-auto");
    try std.testing.expectEqual(wide_alignment, fixed_auto.fixedItemsPerRange(wide_alignment));
    try std.testing.expectEqual(@as(?usize, wide_alignment), fixed_auto.stageItemsPerRange(wide_alignment));

    const small = cases.named("thread-small-range");
    try std.testing.expectEqual(@as(?usize, small.fixedItemsPerRange(16)), small.stageItemsPerRange(16));

    for ([_][]const u8{ "thread-adaptive-fixed-range", "thread-adaptive-tuned-range" }) |name| {
        const adaptive = cases.named(name);
        try std.testing.expect(adaptive.adaptive);
        try std.testing.expectEqual(@as(?usize, null), adaptive.stageItemsPerRange(16));
        try std.testing.expectEqual(wide_alignment, adaptive.fixedItemsPerRange(wide_alignment));
    }
}

test "benchmark range modes and the fixed-adaptive range scale from the group's partition" {
    const RangeCase = struct { name: []const u8, element: ?usize, chunk: ?usize, chunk_aligned: ?usize };
    // Element partition (the default) at alignment 16; one-chunk partition at alignment 1
    // and at an alignment above the partition.
    const expected = [_]RangeCase{
        .{ .name = "thread-fixed-auto", .element = 64, .chunk = 1, .chunk_aligned = 16 },
        .{ .name = "thread-small-range", .element = 32, .chunk = 1, .chunk_aligned = 16 },
        .{ .name = "thread-large-range", .element = 256, .chunk = 4, .chunk_aligned = 16 },
        .{ .name = "thread-adaptive-fixed-range", .element = null, .chunk = null, .chunk_aligned = null },
        .{ .name = "thread-adaptive-tuned-range", .element = null, .chunk = null, .chunk_aligned = null },
    };
    for (expected) |row| {
        const case = findBenchmarkCase(row.name).?;
        try std.testing.expectEqual(row.element, case.stageItemsPerRange(16));
        try std.testing.expectEqual(row.element, case.stageItemsPerRangeForPartition(default_items_per_range, 16));
        try std.testing.expectEqual(row.chunk, case.stageItemsPerRangeForPartition(1, 1));
        try std.testing.expectEqual(row.chunk_aligned, case.stageItemsPerRangeForPartition(1, 16));
    }

    const fixed_adaptive = findBenchmarkCase("thread-adaptive-fixed-range").?;
    try std.testing.expectEqual(AdaptiveRangeMode.fixed, fixed_adaptive.adaptive_range_mode);
    const ClampCase = struct { partition: usize, alignment: usize, range: usize };
    const clamps = [_]ClampCase{
        .{ .partition = default_items_per_range, .alignment = 16, .range = 64 },
        .{ .partition = 1, .alignment = 1, .range = 1 },
        .{ .partition = 1, .alignment = 16, .range = 16 },
    };
    for (clamps) |clamp| {
        const config = adaptiveTunerForPartition(fixed_adaptive, clamp.partition, clamp.alignment).?.config;
        try std.testing.expectEqual(clamp.range, config.initial_range_items);
        try std.testing.expectEqual(clamp.range, config.smallest_range_items);
        try std.testing.expectEqual(clamp.range, config.largest_range_items);
    }
    const tuned = findBenchmarkCase("thread-adaptive-tuned-range").?;
    try std.testing.expectEqual(AdaptiveRangeMode.tuned, tuned.adaptive_range_mode);
    try std.testing.expect(adaptiveTunerForPartition(tuned, 1, 1) == null);
    const fixed_auto = findBenchmarkCase("thread-fixed-auto").?;
    try std.testing.expect(!fixed_auto.adaptive);
    try std.testing.expect(adaptiveTunerForPartition(fixed_auto, 1, 1) == null);
}

test "benchmark fixed case resolving to an earlier case's configuration is reported as its duplicate" {
    const lookup = struct {
        fn index(name: []const u8) usize {
            for (default_cases, 0..) |case, case_index| {
                if (std.mem.eql(u8, case.name, name)) return case_index;
            }
            std.debug.panic("no default benchmark case named {s}", .{name});
        }
    };
    const DuplicateCase = struct { name: []const u8, chunk: ?[]const u8, chunk_aligned: ?[]const u8 };
    // One-chunk partition at alignment 1 (small collapses onto the default) and at an
    // alignment above the partition (large collapses too).
    const expected = [_]DuplicateCase{
        .{ .name = "serial-direct", .chunk = null, .chunk_aligned = null },
        .{ .name = "thread-fixed-1", .chunk = null, .chunk_aligned = null },
        .{ .name = "thread-fixed-2", .chunk = null, .chunk_aligned = null },
        .{ .name = "thread-fixed-auto", .chunk = null, .chunk_aligned = null },
        .{ .name = "thread-small-range", .chunk = "thread-fixed-auto", .chunk_aligned = "thread-fixed-auto" },
        .{ .name = "thread-large-range", .chunk = null, .chunk_aligned = "thread-fixed-auto" },
        .{ .name = "thread-adaptive-fixed-range", .chunk = null, .chunk_aligned = null },
        .{ .name = "thread-adaptive-tuned-range", .chunk = null, .chunk_aligned = null },
    };
    try std.testing.expectEqual(default_cases.len, expected.len);
    const element: FixedRangeShape = .{ .partition_items = default_items_per_range, .range_alignment_items = 16 };
    const chunk: FixedRangeShape = .{ .partition_items = chunk_partition_items, .range_alignment_items = 1 };
    const chunk_aligned: FixedRangeShape = .{ .partition_items = chunk_partition_items, .range_alignment_items = 16 };
    for (expected) |row| {
        const case_index = lookup.index(row.name);
        try std.testing.expectEqual(@as(?usize, null), sameShapeCaseIndex(element, case_index));
        try std.testing.expectEqual(if (row.chunk) |name| lookup.index(name) else null, sameShapeCaseIndex(chunk, case_index));
        try std.testing.expectEqual(if (row.chunk_aligned) |name| lookup.index(name) else null, sameShapeCaseIndex(chunk_aligned, case_index));
    }

    const duplicate: RunStats = .{ .status = .duplicate, .duplicate_note = same_shape_notes[lookup.index("thread-fixed-auto")] };
    try std.testing.expectEqualStrings("same shape as thread-fixed-auto", statusText(duplicate));
    // An untimed duplicate (mean 0) never wins the best-control pick.
    const results = [_]CaseResult{
        .{ .case = findBenchmarkCase("thread-fixed-auto").?, .stats = .{ .mean_ns = 100 } },
        .{ .case = findBenchmarkCase("thread-small-range").?, .stats = duplicate },
    };
    try std.testing.expectEqualStrings("thread-fixed-auto", bestFixedThreadedResult(&results).?.case.name);
    try std.testing.expectEqualStrings("thread-fixed-auto", bestMeasured(&results).?.case.name);
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

fn writeTestWorkload(writer: *std.Io.Writer, stats: RunStats, view: WorkloadView) std.Io.Writer.Error!void {
    try writer.print("hits={}", .{stats.output_count});
    if (view == .details) try writeShare(writer, "main", 250, 1000);
}

test "benchmark items option overrides registered counts" {
    const group = BenchmarkGroup{
        .name = "test",
        .item_label = "test items",
        .defaultItemCounts = testItemCounts,
        .runCase = testRunCase,
        .write_workload = writeNoWorkload,
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
    try std.testing.expectEqualStrings("-", formatWorkerThreadsInto(&worker_buffer, .{ .batch_carried = false }));
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
    const group = BenchmarkGroup{
        .name = "test",
        .item_label = "test items",
        .defaultItemCounts = testItemCounts,
        .runCase = testRunCase,
        .write_workload = writeTestWorkload,
    };
    var workload_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hits=4", formatWorkloadInto(&workload_buffer, group, .{ .output_count = 4 }, .summary));
    try std.testing.expectEqualStrings("hits=4 main=250 ns (25%)", formatWorkloadInto(&workload_buffer, group, .{ .output_count = 4 }, .details));
    const silent = BenchmarkGroup{ .name = "silent", .item_label = "items", .defaultItemCounts = testItemCounts, .runCase = testRunCase, .write_workload = writeNoWorkload };
    try std.testing.expectEqualStrings("", formatWorkloadInto(&workload_buffer, silent, .{ .output_count = 4 }, .details));
}

test "the details table's range columns read inline for an inline batch, never a range size" {
    var buffer: [24]u8 = undefined;
    const inline_batch = BatchSummary{ .item_count = 64, .range_count = 1, .items_per_range = 64, .main_thread_ranges = 1, .ran_inline = true };
    try std.testing.expectEqualStrings("inline", formatRangeCellInto(&buffer, inline_batch, inline_batch.items_per_range));
    try std.testing.expectEqualStrings("inline", formatRangeCellInto(&buffer, inline_batch, inline_batch.main_thread_ranges));
    // A dispatched batch that kept no worker active ran inline too.
    const idle = BatchSummary{ .item_count = 64, .range_count = 2, .items_per_range = 32, .ran_inline = false };
    try std.testing.expectEqualStrings("inline", formatRangeCellInto(&buffer, idle, idle.items_per_range));
    const threaded = BatchSummary{ .item_count = 64, .range_count = 4, .items_per_range = 16, .active_worker_threads = 3, .worker_thread_ranges = 3, .ran_inline = false };
    try std.testing.expectEqualStrings("16", formatRangeCellInto(&buffer, threaded, threaded.items_per_range));
    try std.testing.expectEqualStrings("3", formatRangeCellInto(&buffer, threaded, threaded.worker_thread_ranges));
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

const TestVariant = enum(u8) { plain, packed_pads };
const TestCode = ItemCode(struct { variant: TestVariant, edge_chunks: u16, level_side: u16, levels: u16 }, &.{ 3, 4, 3 });

test "an item code packs its fields in decimal, round-trips them, and names its layout" {
    try std.testing.expectEqualStrings("(variant * 10^10 + edge chunks * 10^7 + level side * 1000 + levels)", TestCode.label);
    const code = TestCode.of(.{ .variant = .packed_pads, .edge_chunks = 8, .level_side = 1024, .levels = 1 });
    try std.testing.expectEqual(@as(usize, 10_081_024_001), code);
    const fields = try TestCode.decode(code);
    try std.testing.expectEqual(TestVariant.packed_pads, fields.variant);
    try std.testing.expectEqual(@as(u16, 8), fields.edge_chunks);
    try std.testing.expectEqual(@as(u16, 1024), fields.level_side);
    try std.testing.expectEqual(@as(u16, 1), fields.levels);
    // A plain count is its own code under a one-field layout's lowest digits.
    const Plain = ItemCode(struct { level_side: u16, levels: u16 }, &.{3});
    try std.testing.expectEqualStrings("(level side * 1000 + levels)", Plain.label);
    try std.testing.expectEqual(@as(usize, 256_008), Plain.of(.{ .level_side = 256, .levels = 8 }));
}

test "an item code rejects a field past its digits, its type, or its enum's tags" {
    try std.testing.expectError(error.ItemCodeFieldTooWide, TestCode.encode(.{ .variant = .plain, .edge_chunks = 1000, .level_side = 256, .levels = 1 }));
    // Variant 2 names no tag.
    try std.testing.expectError(error.ItemCodeFieldOutOfRange, TestCode.decode(20_081_024_001));
    // A level side of 70,000 passes u16.
    const Wide = ItemCode(struct { level_side: u16, requests: u16 }, &.{3});
    try std.testing.expectError(error.ItemCodeFieldOutOfRange, Wide.decode(70_000_064));
}

test "the stage-shape accumulator keeps each stage's busiest batch, preferring one on workers at a tie" {
    var shapes = StageShapes(2){};
    shapes.add(.{ .{ .item_count = 8, .range_count = 1, .ran_inline = true }, .{} });
    shapes.add(.{ .{ .item_count = 8, .range_count = 4, .active_worker_threads = 3, .ran_inline = false }, .{ .item_count = 2, .range_count = 1, .ran_inline = true } });
    shapes.add(.{ .{ .item_count = 4, .range_count = 1, .ran_inline = true }, .{} });
    var buffer: [48]u8 = undefined;
    try std.testing.expectEqualStrings("3w/4r(8)[1/3]", shapes.label(0, &buffer));
    try std.testing.expectEqualStrings("inline(2)[0/1]", shapes.label(1, &buffer));
}

fn formatSteeringStagesInto(buffer: []u8, stats: RunStats) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    writeSteeringStages(&writer, stats) catch return "stages";
    return writer.buffered();
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
