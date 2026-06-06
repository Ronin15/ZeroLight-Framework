// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const thread_mod = @import("../app/thread_system.zig");
const BatchStats = thread_mod.BatchStats;
const ThreadSystemConfig = thread_mod.ThreadSystemConfig;

pub const default_grain_size = (ThreadSystemConfig{}).grain_size;

pub const Profile = enum {
    quick,
    standard,
    stress,
};

pub const Options = struct {
    profile: Profile = .quick,
    warmup_iterations: usize = 5,
    iterations: usize = 30,
    case_filter: ?[]const u8 = null,
    details: bool = false,
};

pub const BenchmarkGroup = struct {
    name: []const u8,
    defaultItemCounts: *const fn (Profile) []const usize,
    runCase: *const fn (std.mem.Allocator, std.Io, Options, BenchmarkCase, usize) anyerror!RunStats,
};

pub const BenchmarkCase = struct {
    name: []const u8,
    worker_mode: WorkerMode,
    adaptive: bool = false,
    grain_mode: GrainMode = .default,
    tuned_grain: bool = false,
    required_worker_count: usize = 0,

    pub fn maxWorkerThreads(self: BenchmarkCase) ?usize {
        return switch (self.worker_mode) {
            .serial_direct => 0,
            .thread_inline => 0,
            .fixed_1 => 1,
            .fixed_2 => 2,
            .fixed_auto => null,
        };
    }

    pub fn usesThreadSystem(self: BenchmarkCase) bool {
        return self.worker_mode != .serial_direct;
    }

    pub fn grainSize(self: BenchmarkCase, range_alignment_items: usize) ?usize {
        const base = default_grain_size;
        return switch (self.grain_mode) {
            .default => null,
            .small => alignItemCount(@max(base / 2, @as(usize, 1)), range_alignment_items),
            .large => alignItemCount(base * 4, range_alignment_items),
        };
    }

    pub fn workerModeLabel(self: BenchmarkCase) []const u8 {
        return switch (self.worker_mode) {
            .serial_direct => "serial",
            .thread_inline => "inline",
            .fixed_1 => "fixed-1",
            .fixed_2 => "fixed-2",
            .fixed_auto => "fixed-auto",
        };
    }
};

pub const WorkerMode = enum {
    serial_direct,
    thread_inline,
    fixed_1,
    fixed_2,
    fixed_auto,
};

pub const GrainMode = enum {
    default,
    small,
    large,
};

pub const default_cases = [_]BenchmarkCase{
    .{
        .name = "serial-direct",
        .worker_mode = .serial_direct,
    },
    .{
        .name = "thread-inline",
        .worker_mode = .thread_inline,
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
        .name = "thread-adaptive",
        .worker_mode = .fixed_auto,
        .adaptive = true,
        .required_worker_count = 1,
    },
    .{
        .name = "thread-adaptive-tuned-grain",
        .worker_mode = .fixed_auto,
        .adaptive = true,
        .tuned_grain = true,
        .required_worker_count = 1,
    },
    .{
        .name = "thread-small-grain",
        .worker_mode = .fixed_auto,
        .grain_mode = .small,
        .required_worker_count = 1,
    },
    .{
        .name = "thread-large-grain",
        .worker_mode = .fixed_auto,
        .grain_mode = .large,
        .required_worker_count = 1,
    },
};

pub const RunStatus = enum {
    measured,
    skipped,
};

pub const RunStats = struct {
    status: RunStatus = .measured,
    skip_reason: []const u8 = "",
    item_count: usize = 0,
    iterations: usize = 0,
    mean_ns: u64 = 0,
    min_ns: u64 = 0,
    max_ns: u64 = 0,
    items_per_second: u64 = 0,
    batch: BatchSummary = .{},
    grain_tuning: ?GrainTuningSummary = null,

    pub fn skipped(reason: []const u8) RunStats {
        return .{
            .status = .skipped,
            .skip_reason = reason,
        };
    }
};

const CaseResult = struct {
    case: BenchmarkCase,
    stats: RunStats,
};

pub const BatchSummary = struct {
    item_count: usize = 0,
    range_count: usize = 0,
    grain_size: usize = 0,
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

pub const GrainTuningSummary = struct {
    phase: thread_mod.AdaptiveGrainPhase = .learning,
    initial_grain_size: usize = 0,
    final_grain_size: usize = 0,
    best_grain_size: usize = 0,
    candidate_grain_size: ?usize = null,
    sample_count: usize = 0,
    sample_window: usize = 0,
    failed_probe_count: usize = 0,
    settled_window_count: usize = 0,
    settle_after_failed_probes: usize = 0,
    retune_after_settled_windows: usize = 0,
    settled_before_measurement: bool = false,
    best_mean_batch_duration_ns: u64 = 0,
    baseline_mean_batch_duration_ns: u64 = 0,
    probing: bool = false,
};

pub const StatsAccumulator = struct {
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
                .grain_size = self.last_batch.grain_size,
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

pub fn grainTuningSummary(report: thread_mod.AdaptiveGrainReport) GrainTuningSummary {
    return .{
        .phase = report.phase,
        .initial_grain_size = report.initial_grain_size,
        .final_grain_size = report.current_grain_size,
        .best_grain_size = report.best_grain_size,
        .candidate_grain_size = report.candidate_grain_size,
        .sample_count = report.sample_count,
        .sample_window = report.sample_window,
        .failed_probe_count = report.failed_probe_count,
        .settled_window_count = report.settled_window_count,
        .settle_after_failed_probes = report.settle_after_failed_probes,
        .retune_after_settled_windows = report.retune_after_settled_windows,
        .settled_before_measurement = report.phase == .settled,
        .best_mean_batch_duration_ns = report.best_mean_batch_duration_ns,
        .baseline_mean_batch_duration_ns = report.baseline_mean_batch_duration_ns,
        .probing = report.probing,
    };
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
    printHeader(options);
    for (groups) |group| {
        for (group.defaultItemCounts(options.profile)) |item_count| {
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
        .grain_size = item_count,
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
    std.debug.print("purpose: tune per-system threading thresholds, adaptive thread count, and batch grain size\n", .{});
}

fn printGroupReport(group: BenchmarkGroup, results: []const CaseResult, options: Options) void {
    const baseline = findResult(results, "serial-direct") orelse {
        std.debug.print("\n{s}\n", .{group.name});
        std.debug.print("  no serial baseline was run\n", .{});
        if (options.details) printCaseDetails(results, null);
        return;
    };
    if (baseline.stats.status == .skipped) {
        std.debug.print("\n{s}\n", .{group.name});
        std.debug.print("  serial baseline skipped: {s}\n", .{baseline.stats.skip_reason});
        if (options.details) printCaseDetails(results, null);
        return;
    }

    const item_count = baseline.stats.item_count;
    std.debug.print("\n{s}: {} {s}\n", .{ group.name, item_count, itemLabel(group.name) });
    const best = bestMeasured(results) orelse baseline;
    const inline_case = measured(findResult(results, "thread-inline"));
    const fixed_auto = measured(findResult(results, "thread-fixed-auto"));
    const adaptive = measured(findResult(results, "thread-adaptive"));
    const tuned_grain = measured(findResult(results, "thread-adaptive-tuned-grain"));
    const limited_best = bestOfMeasured(&.{ findResult(results, "thread-fixed-1"), findResult(results, "thread-fixed-2") });
    const best_grain = bestOfMeasured(&.{ findResult(results, "thread-fixed-auto"), findResult(results, "thread-adaptive-tuned-grain"), findResult(results, "thread-small-grain"), findResult(results, "thread-large-grain") });

    printVerdict(group, item_count, baseline, best, fixed_auto, limited_best);
    printTuning(baseline, best, fixed_auto, adaptive, tuned_grain, limited_best, best_grain);
    printEvidence(baseline, best, inline_case, fixed_auto, adaptive, tuned_grain, limited_best, best_grain);
    if (options.details) {
        printCaseDetails(results, baseline);
    } else {
        std.debug.print("  details: pass --details to show the full case breakdown\n", .{});
    }
}

fn printVerdict(
    group: BenchmarkGroup,
    item_count: usize,
    baseline: CaseResult,
    best: CaseResult,
    fixed_auto: ?CaseResult,
    limited_best: ?CaseResult,
) void {
    const speedup = speedupBasisPoints(baseline.stats, best.stats);
    if (std.mem.eql(u8, best.case.name, baseline.case.name)) {
        std.debug.print(
            "  verdict: {} {s} should stay serial for now; threading does not beat the direct path here.\n",
            .{ item_count, itemLabel(group.name) },
        );
        return;
    }

    const shape = if (speedup >= 300)
        "good threaded workload"
    else if (speedup >= 200)
        "threadable workload that needs tuning"
    else
        "threshold-boundary workload";

    std.debug.print(
        "  verdict: {} {s} are a {s}; best measured path is {s} ({d}.{d:0>2}x serial).\n",
        .{ item_count, itemLabel(group.name), shape, best.case.name, speedup / 100, speedup % 100 },
    );

    if (fixed_auto) |auto| {
        if (limited_best) |limited| {
            const delta = percentDelta(auto.stats.mean_ns, limited.stats.mean_ns);
            if (delta > 10) {
                std.debug.print("  verdict detail: full active worker-thread count is too aggressive at this size.\n", .{});
            } else if (delta < -10) {
                std.debug.print("  verdict detail: this size has enough work to use broad active worker-thread counts.\n", .{});
            }
        }
    }
}

fn printTuning(
    baseline: CaseResult,
    best: CaseResult,
    fixed_auto: ?CaseResult,
    adaptive: ?CaseResult,
    tuned_grain: ?CaseResult,
    limited_best: ?CaseResult,
    best_grain: ?CaseResult,
) void {
    std.debug.print("  tuning:\n", .{});

    const speedup = speedupBasisPoints(baseline.stats, best.stats);
    if (std.mem.eql(u8, best.case.name, baseline.case.name) or speedup < 110) {
        std.debug.print(
            "    - system threshold: raise min_parallel_items above {} for this processor class.\n",
            .{baseline.stats.item_count},
        );
    } else if (speedup < 200) {
        std.debug.print(
            "    - system threshold: treat this as boundary data; compare larger counts before lowering min_parallel_items.\n",
            .{},
        );
    } else {
        std.debug.print(
            "    - system threshold: this count is worth threaded processing; keep it above the inline cutoff.\n",
            .{},
        );
    }

    if (fixed_auto) |auto| {
        if (limited_best) |limited| {
            const delta = percentDelta(auto.stats.mean_ns, limited.stats.mean_ns);
            if (delta > 10) {
                std.debug.print(
                    "    - adaptive thread count: cap near {} active worker threads or rely on adaptive; auto used {}/{} and lost.\n",
                    .{ limited.stats.batch.active_worker_threads, auto.stats.batch.active_worker_threads, auto.stats.batch.available_worker_threads },
                );
            } else if (delta < -10) {
                std.debug.print(
                    "    - adaptive thread count: broad active worker-thread counts are useful; auto used {}/{} and beat limited-worker runs.\n",
                    .{ auto.stats.batch.active_worker_threads, auto.stats.batch.available_worker_threads },
                );
            } else {
                std.debug.print("    - adaptive thread count: limited and auto counts are close; keep measuring with steadier iteration counts.\n", .{});
            }
        }
    }

    if (adaptive) |adaptive_case| {
        if (fixed_auto) |auto| {
            const delta = percentDelta(adaptive_case.stats.mean_ns, auto.stats.mean_ns);
            if (delta < -10) {
                std.debug.print("    - adaptive thread count: adaptive selection is helping; keep adaptive enabled for this processor.\n", .{});
            } else if (delta > 10) {
                std.debug.print("    - adaptive thread count: adaptive selection is slower here; fixed worker selection may be better for this processor.\n", .{});
            } else {
                std.debug.print("    - adaptive thread count: adaptive and fixed-auto are close; no selection change from this run.\n", .{});
            }
        }
    }

    if (tuned_grain) |tuned| {
        if (tuned.stats.grain_tuning) |summary| {
            if (adaptive) |adaptive_case| {
                const delta = percentDelta(tuned.stats.mean_ns, adaptive_case.stats.mean_ns);
                if (delta < -10) {
                    std.debug.print(
                        "    - dynamic grain: adaptive+tuned beat adaptive-only by {f}; best grain_size={}.\n",
                        .{ signedPercent(delta), summary.best_grain_size },
                    );
                } else if (delta > 10) {
                    std.debug.print(
                        "    - dynamic grain: adaptive+tuned is slower than adaptive-only by {f}; do not adopt grain_size={} from this run.\n",
                        .{ signedPercent(delta), summary.best_grain_size },
                    );
                } else {
                    std.debug.print(
                        "    - dynamic grain: adaptive+tuned and adaptive-only are close ({f}); best grain_size={}.\n",
                        .{ signedPercent(delta), summary.best_grain_size },
                    );
                }
                if (!summary.settled_before_measurement) {
                    std.debug.print("    - dynamic grain warning: tuner did not settle before measurement; increase warmup before trusting this case.\n", .{});
                }
            } else if (fixed_auto) |auto| {
                const delta = percentDelta(tuned.stats.mean_ns, auto.stats.mean_ns);
                std.debug.print(
                    "    - dynamic grain: tuned vs fixed-auto {f}; best grain_size={}.\n",
                    .{ signedPercent(delta), summary.best_grain_size },
                );
            }
        }
    }

    if (best_grain) |grain| {
        if (std.mem.eql(u8, grain.case.name, "thread-fixed-auto")) {
            std.debug.print("    - batching: default grain_size={} is fine for this run.\n", .{grain.stats.batch.grain_size});
        } else if (std.mem.eql(u8, grain.case.name, "thread-adaptive-tuned-grain")) {
            if (grain.stats.grain_tuning) |summary| {
                std.debug.print(
                    "    - batching: dynamic tuner beat fixed grain probes; try starting near grain_size={} for this processor.\n",
                    .{summary.best_grain_size},
                );
            }
        } else {
            std.debug.print(
                "    - batching: test grain_size={} in the real processor config; this case beat the default grain test.\n",
                .{grain.stats.batch.grain_size},
            );
        }
    }
}

fn printEvidence(
    baseline: CaseResult,
    best: CaseResult,
    inline_case: ?CaseResult,
    fixed_auto: ?CaseResult,
    adaptive: ?CaseResult,
    tuned_grain: ?CaseResult,
    limited_best: ?CaseResult,
    best_grain: ?CaseResult,
) void {
    std.debug.print("  evidence:\n", .{});
    std.debug.print(
        "    - serial baseline {f}; best {s} {f} ({d}.{d:0>2}x).\n",
        .{
            formatDuration(baseline.stats.mean_ns),
            best.case.name,
            formatDuration(best.stats.mean_ns),
            speedupBasisPoints(baseline.stats, best.stats) / 100,
            speedupBasisPoints(baseline.stats, best.stats) % 100,
        },
    );
    if (inline_case) |inline_result| {
        std.debug.print(
            "    - inline ThreadSystem path {f} ({f} vs serial), so inline overhead is visible without active worker threads.\n",
            .{ formatDuration(inline_result.stats.mean_ns), signedPercent(percentDelta(inline_result.stats.mean_ns, baseline.stats.mean_ns)) },
        );
    }
    if (limited_best) |limited| {
        if (fixed_auto) |auto| {
            std.debug.print(
                "    - limited workers {s} {f}; auto workers {f} with {}/{} active.\n",
                .{ limited.case.name, formatDuration(limited.stats.mean_ns), formatDuration(auto.stats.mean_ns), auto.stats.batch.active_worker_threads, auto.stats.batch.available_worker_threads },
            );
        }
    }
    if (adaptive) |adaptive_result| {
        if (fixed_auto) |auto| {
            std.debug.print(
                "    - adaptive {f}; fixed-auto {f} ({f}).\n",
                .{ formatDuration(adaptive_result.stats.mean_ns), formatDuration(auto.stats.mean_ns), signedPercent(percentDelta(adaptive_result.stats.mean_ns, auto.stats.mean_ns)) },
            );
        }
    }
    if (tuned_grain) |tuned| {
        if (tuned.stats.grain_tuning) |summary| {
            std.debug.print(
                "    - tuned grain phase={s} settled_before_measurement={} initial={} final={} best={} candidate={?}; best window {f}.\n",
                .{
                    @tagName(summary.phase),
                    summary.settled_before_measurement,
                    summary.initial_grain_size,
                    summary.final_grain_size,
                    summary.best_grain_size,
                    summary.candidate_grain_size,
                    formatDuration(summary.best_mean_batch_duration_ns),
                },
            );
        }
    }
    if (best_grain) |grain| {
        if (grain.stats.grain_tuning) |summary| {
            std.debug.print(
                "    - best grain test: {s} with tuner best={} final={}.\n",
                .{ grain.case.name, summary.best_grain_size, summary.final_grain_size },
            );
        } else {
            std.debug.print("    - best grain test: {s} with grain_size={}.\n", .{ grain.case.name, grain.stats.batch.grain_size });
        }
    }
}

fn itemLabel(group_name: []const u8) []const u8 {
    if (std.mem.eql(u8, group_name, "movement")) return "movement bodies";
    if (std.mem.eql(u8, group_name, "particles")) return "particle rows";
    return "items";
}

fn printCaseDetails(results: []const CaseResult, baseline: ?CaseResult) void {
    std.debug.print("  case details:\n", .{});
    for (results) |result| {
        if (result.stats.status == .skipped) {
            std.debug.print("    {s}: skipped ({s})\n", .{ result.case.name, result.stats.skip_reason });
            continue;
        }

        const relative = if (baseline) |base|
            speedupBasisPoints(base.stats, result.stats)
        else
            100;
        std.debug.print(
            "    {s}: {f}, {d}.{d:0>2}x serial, workers {}/{}, ranges main/worker {}/{}, wait {f}",
            .{
                result.case.name,
                formatDuration(result.stats.mean_ns),
                relative / 100,
                relative % 100,
                result.stats.batch.active_worker_threads,
                result.stats.batch.available_worker_threads,
                result.stats.batch.main_thread_ranges,
                result.stats.batch.worker_thread_ranges,
                formatDuration(result.stats.batch.main_thread_wait_ns),
            },
        );
        if (result.stats.grain_tuning) |summary| {
            std.debug.print(
                ", tuned grain phase={s} settled={} {}/{} best {}",
                .{ @tagName(summary.phase), summary.settled_before_measurement, summary.initial_grain_size, summary.final_grain_size, summary.best_grain_size },
            );
        }
        std.debug.print("\n", .{});
    }
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

fn percentDelta(candidate_ns: u64, baseline_ns: u64) i64 {
    if (baseline_ns == 0) return 0;
    const candidate: i128 = candidate_ns;
    const baseline_value: i128 = baseline_ns;
    return @intCast(@divTrunc((candidate - baseline_value) * 100, baseline_value));
}

fn signedPercent(value: i64) SignedPercent {
    return .{ .value = value };
}

const SignedPercent = struct {
    value: i64,

    pub fn format(self: SignedPercent, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.value > 0) {
            try writer.print("+{}%", .{self.value});
        } else {
            try writer.print("{}%", .{self.value});
        }
    }
};

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

fn u128ToUsizeSaturated(value: u128) usize {
    return if (value > std.math.maxInt(usize)) std.math.maxInt(usize) else @intCast(value);
}

test "default benchmark cases cover required thread modes" {
    try std.testing.expectEqual(@as(usize, 9), default_cases.len);
    try std.testing.expectEqualStrings("serial-direct", default_cases[0].name);
    try std.testing.expectEqualStrings("thread-inline", default_cases[1].name);
    try std.testing.expectEqualStrings("thread-fixed-1", default_cases[2].name);
    try std.testing.expectEqualStrings("thread-fixed-2", default_cases[3].name);
    try std.testing.expectEqualStrings("thread-fixed-auto", default_cases[4].name);
    try std.testing.expectEqualStrings("thread-adaptive", default_cases[5].name);
    try std.testing.expectEqualStrings("thread-adaptive-tuned-grain", default_cases[6].name);
    try std.testing.expectEqualStrings("thread-small-grain", default_cases[7].name);
    try std.testing.expectEqualStrings("thread-large-grain", default_cases[8].name);
}

test "benchmark options parse scaling and filtering arguments" {
    const args = [_][]const u8{
        "--profile",
        "standard",
        "--warmup=2",
        "--iterations",
        "9",
        "--case",
        "thread-inline",
        "--details",
    };
    const options = try parseOptions(&args);
    try std.testing.expectEqual(Profile.standard, options.profile);
    try std.testing.expectEqual(@as(usize, 2), options.warmup_iterations);
    try std.testing.expectEqual(@as(usize, 9), options.iterations);
    try std.testing.expectEqualStrings("thread-inline", options.case_filter.?);
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
    try std.testing.expect(shouldIncludeBaselineForFilter("thread-adaptive", default_cases[0]));
    try std.testing.expect(!shouldIncludeBaselineForFilter("serial-direct", default_cases[0]));
    try std.testing.expect(!shouldIncludeBaselineForFilter("thread-adaptive", default_cases[5]));
}

test "grain tuning summary preserves settled phase" {
    var summary = grainTuningSummary(.{
        .phase = .settled,
        .initial_grain_size = 64,
        .current_grain_size = 256,
        .best_grain_size = 256,
        .sample_window = 2,
        .failed_probe_count = 0,
        .settled_window_count = 4,
        .settle_after_failed_probes = 2,
        .retune_after_settled_windows = 10_000,
        .best_mean_batch_duration_ns = 42,
    });
    summary.settled_before_measurement = summary.phase == .settled;

    try std.testing.expectEqual(thread_mod.AdaptiveGrainPhase.settled, summary.phase);
    try std.testing.expect(summary.settled_before_measurement);
    try std.testing.expectEqual(@as(usize, 256), summary.best_grain_size);
}

test "grain modes align to cache-line item boundaries" {
    const small = default_cases[7].grainSize(16).?;
    const large = default_cases[8].grainSize(16).?;
    try std.testing.expectEqual(@as(usize, 32), small);
    try std.testing.expectEqual(@as(usize, 256), large);
}
