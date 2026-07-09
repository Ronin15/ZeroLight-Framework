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
const ThreadSystemConfig = @import("../app/thread_system.zig").ThreadSystemConfig;

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
    iterations: usize = 0,
    mean_ns: u64 = 0,
    min_ns: u64 = 0,
    max_ns: u64 = 0,
    items_per_second: u64 = 0,
    batch: BatchSummary = .{},
    secondary_batch: ?BatchSummary = null,
    work_tuning: ?WorkTuningSummary = null,
    secondary_work_tuning: ?WorkTuningSummary = null,
    render_prep_phases: ?RenderPrepPhaseSummary = null,
    render_game_prep_phases: ?RenderGamePrepPhaseSummary = null,
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

pub const RenderGamePrepPhaseSummary = struct {
    entity_collect_ns: u64 = 0,
    merge_ns: u64 = 0,
    snapshot_ns: u64 = 0,
    vertex_emit_ns: u64 = 0,
};

/// Per-behavior selection counts after one measured `ai` run, read from
/// `AiAgentStore`'s hot `active_behavior` column post-update (Slice 32
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
    var matched_group = options.group_filter == null;
    for (groups) |group| {
        if (options.group_filter) |filter| {
            if (!std.mem.eql(u8, filter, group.name)) continue;
            matched_group = true;
        }
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
        std.debug.print("unknown benchmark group: {s}\n", .{options.group_filter.?});
        return error.InvalidArgument;
    }
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
    return std.math.divCeil(usize, item_count, items_per_range) catch unreachable;
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

fn itemLabel(group_name: []const u8) []const u8 {
    if (std.mem.eql(u8, group_name, "movement")) return "movement bodies";
    if (std.mem.eql(u8, group_name, "particles")) return "particle rows";
    if (std.mem.eql(u8, group_name, "ai")) return "AI agents";
    if (std.mem.eql(u8, group_name, "ai-memory")) return "AI agents";
    if (std.mem.eql(u8, group_name, "ai-affect")) return "AI agents";
    if (std.mem.eql(u8, group_name, "perception") or std.mem.startsWith(u8, group_name, "perception-")) return "perception agents";
    if (std.mem.eql(u8, group_name, "pathfinding")) return "path requests";
    if (std.mem.eql(u8, group_name, "pathfinding-cache-open")) return "cached open path requests";
    if (std.mem.eql(u8, group_name, "pathfinding-cache-detour")) return "cached detour path requests";
    if (std.mem.eql(u8, group_name, "pathfinding-cache-unreachable")) return "cached unreachable path requests";
    if (std.mem.startsWith(u8, group_name, "pathfinding-hard-fallback")) return "hard fallback path requests";
    if (std.mem.eql(u8, group_name, "steering")) return "steering agents";
    if (std.mem.eql(u8, group_name, "render-prep")) return "draw commands";
    if (isRenderGamePrepGroup(group_name)) return "render entities";
    if (std.mem.eql(u8, group_name, "collision")) return "collision bodies";
    if (std.mem.eql(u8, group_name, "collision-sparse")) return "collision bodies";
    if (std.mem.startsWith(u8, group_name, "collision-response")) return "contacts";
    return "items";
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
    printCell("work_tuning", 56);
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
            printCell("-", 56);
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
        var workload_buffer: [256]u8 = undefined;

        printCell(result.case.name, 30);
        printCell(formatDurationInto(&min_buffer, result.stats.min_ns), 11);
        printCell(formatDurationInto(&max_buffer, result.stats.max_ns), 11);
        printCell(formatUsizeInto(&main_ranges_buffer, result.stats.batch.main_thread_ranges), 12);
        printCell(formatUsizeInto(&worker_ranges_buffer, result.stats.batch.worker_thread_ranges), 14);
        printCell(formatDurationInto(&wait_buffer, result.stats.batch.main_thread_wait_ns), 11);
        printCell(formatUsizeInto(&items_per_range_buffer, result.stats.batch.items_per_range), 16);
        printCell(formatWorkTuningInto(&tuning_buffer, result.stats.work_tuning), 56);
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
    if (!summary.has_threaded_profile) {
        if (summary.candidate_items_per_range) |candidate| {
            const candidate_workers = summary.candidate_worker_threads orelse 0;
            return std.fmt.bufPrint(
                buffer,
                "{s} settled={s} threaded=none cand={}/{}",
                .{ @tagName(summary.phase), yesNo(summary.settled_before_measurement), candidate_workers, candidate },
            ) catch "work";
        }
        return std.fmt.bufPrint(
            buffer,
            "{s} settled={s} threaded=none",
            .{ @tagName(summary.phase), yesNo(summary.settled_before_measurement) },
        ) catch "work";
    }
    if (summary.candidate_items_per_range) |candidate| {
        const candidate_workers = summary.candidate_worker_threads orelse 0;
        return std.fmt.bufPrint(
            buffer,
            "{s} settled={s} best={}/{} final={}/{} cand={}/{}",
            .{ @tagName(summary.phase), yesNo(summary.settled_before_measurement), summary.best_worker_threads, summary.best_items_per_range, summary.final_worker_threads, summary.final_items_per_range, candidate_workers, candidate },
        ) catch "work";
    }
    return std.fmt.bufPrint(
        buffer,
        "{s} settled={s} best={}/{} final={}/{}",
        .{ @tagName(summary.phase), yesNo(summary.settled_before_measurement), summary.best_worker_threads, summary.best_items_per_range, summary.final_worker_threads, summary.final_items_per_range },
    ) catch "work";
}

fn formatWorkloadInto(buffer: []u8, group_name: []const u8, stats: RunStats) []const u8 {
    // Workload labels translate shared counters into subsystem language so the
    // report remains compact without hiding what was measured.
    if (stats.candidate_pairs == 0 and stats.output_count == 0 and stats.deferred_count == 0 and stats.fallback_deferred_count == 0 and stats.cache_evictions == 0) return "-";
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
    if (std.mem.eql(u8, group_name, "steering")) {
        return std.fmt.bufPrint(buffer, "avoidance_checks={} samples={} intents={}", .{ stats.candidate_pairs, stats.sample_count, stats.output_count }) catch "workload";
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
    }, true);

    try std.testing.expectEqual(AdaptiveWorkPhase.settled, summary.phase);
    try std.testing.expect(summary.settled_before_measurement);
    try std.testing.expectEqual(@as(usize, 4), summary.best_worker_threads);
    try std.testing.expectEqual(@as(usize, 256), summary.best_items_per_range);
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
    try std.testing.expectEqualStrings(
        "settled settled=yes best=4/256 final=4/256",
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
